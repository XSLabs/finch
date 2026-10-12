/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * QuickLookUI: the Quick Look panel and preview view, Finch's own. A QLPreviewView shows
 * an item (anything answering previewItemURL): an image or a PDF's pages scaled to fit,
 * text and rich text in a read-only text view, and anything else as its large icon with
 * its name, kind and size. The shared QLPreviewPanel shows its data source's items one at
 * a time (the arrow keys move between them; space or Escape closes it); as on macOS, the
 * data source is the first object up the key window's responder chain that accepts
 * control of the panel. The private classes some of Apple's apps link (documents,
 * seamless opening, window effects) are here as the panel has none of their behaviour.
 */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define QL_EXPORT __attribute__((visibility("default")))

CGImageRef FinchQuickLookThumbnail(NSURL *url, size_t maxPixels, BOOL iconMode, BOOL *isIcon);

@protocol QLPreviewItem <NSObject>
@property (readonly) NSURL *previewItemURL;
@optional
@property (readonly) NSString *previewItemTitle;
@property (readonly) id previewItemDisplayState;
@end

/* (NSURL is a preview item of itself, as on macOS) */
@interface NSURL (QLPreviewConvenienceAdditions) <QLPreviewItem>
@end

@implementation NSURL (QLPreviewConvenienceAdditions)
- (NSURL *)previewItemURL { return self; }
- (NSString *)previewItemTitle { return self.lastPathComponent; }
@end

typedef NS_ENUM(NSUInteger, QLPreviewViewStyle) { QLPreviewViewStyleNormal = 0, QLPreviewViewStyleCompact = 1 };

#pragma mark - Preview view

QL_EXPORT
@interface QLPreviewView : NSView
- (instancetype)initWithFrame:(NSRect)frame style:(QLPreviewViewStyle)style;
@property (nonatomic, strong) id<QLPreviewItem> previewItem;
@property BOOL shouldCloseWithWindow;
@property BOOL autostarts;
@property (strong) id displayState;
- (void)refreshPreviewItem;
- (void)close;
@end

@implementation QLPreviewView {
    QLPreviewViewStyle _style;
    NSView *_content;
}

- (instancetype)initWithFrame:(NSRect)frame style:(QLPreviewViewStyle)style
{
    if ((self = [super initWithFrame:frame])) {
        _style = style;
        _shouldCloseWithWindow = YES;
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    return [self initWithFrame:frame style:QLPreviewViewStyleNormal];
}

- (void)setPreviewItem:(id<QLPreviewItem>)item
{
    _previewItem = item;
    [self refreshPreviewItem];
}

static NSString *
size_string(NSURL *u)
{
    NSNumber *n = nil;
    [u getResourceValue:&n forKey:NSURLFileSizeKey error:NULL];
    return n ? [NSByteCountFormatter stringFromByteCount:n.longLongValue countStyle:NSByteCountFormatterCountStyleFile] : @"";
}

/* The large icon, the name and what it is. */
- (NSView *)_genericViewFor:(NSURL *)url title:(NSString *)title
{
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:url.path];
    icon.size = NSMakeSize(128, 128);
    NSImageView *iv = [NSImageView imageViewWithImage:icon];
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [iv.widthAnchor constraintEqualToConstant:128].active = YES;
    [iv.heightAnchor constraintEqualToConstant:128].active = YES;
    NSTextField *name = [NSTextField labelWithString:title ?: url.lastPathComponent ?: @""];
    name.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
    NSString *kind = t.localizedDescription ?: @"Document";
    NSString *size = size_string(url);
    NSTextField *info = [NSTextField labelWithString:size.length ? [NSString stringWithFormat:@"%@ · %@", kind, size] : kind];
    info.textColor = [NSColor secondaryLabelColor];
    NSStackView *s = [NSStackView stackViewWithViews:@[ iv, name, info ]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.spacing = 8;
    return s;
}

- (void)refreshPreviewItem
{
    [_content removeFromSuperview];
    _content = nil;
    NSURL *url = [_previewItem respondsToSelector:@selector(previewItemURL)] ? _previewItem.previewItemURL : nil;
    if (!url)
        return;
    NSString *title = [_previewItem respondsToSelector:@selector(previewItemTitle)] ? _previewItem.previewItemTitle : nil;
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
    if (!t)
        t = [UTType typeWithFilenameExtension:url.pathExtension];
    NSView *v = nil;
    if ([t conformsToType:UTTypeImage] || [t conformsToType:UTTypePDF]) {
        NSImage *im = [[NSImage alloc] initWithContentsOfURL:url];
        if (im.representations.count) {
            NSImageView *iv = [NSImageView imageViewWithImage:im];
            iv.imageScaling = NSImageScaleProportionallyDown;
            v = iv;
        }
    } else if ([t conformsToType:UTTypeText] || [t conformsToType:UTTypeRTF] || [t conformsToType:UTTypeSourceCode]) {
        NSAttributedString *as = [[NSAttributedString alloc] initWithURL:url options:@{} documentAttributes:NULL error:NULL];
        if (as) {
            NSScrollView *sv = [NSTextView scrollableTextView];
            NSTextView *tv = sv.documentView;
            tv.editable = NO;
            tv.textContainerInset = NSMakeSize(12, 12);
            [tv.textStorage setAttributedString:as];
            v = sv;
        }
    }
    if (!v)
        v = [self _genericViewFor:url title:title];
    _content = v;
    [self addSubview:v];
    [self setNeedsLayout:YES];
}

- (void)layout
{
    [super layout];
    if ([_content isKindOfClass:[NSStackView class]]) {
        NSSize s = _content.fittingSize;
        _content.frame = NSMakeRect(floor((self.bounds.size.width - s.width) / 2), floor((self.bounds.size.height - s.height) / 2), s.width, s.height);
    } else {
        _content.frame = self.bounds;
    }
}

- (void)close
{
    self.previewItem = nil;
}

- (void)viewWillMoveToWindow:(NSWindow *)w
{
    if (!w && self.window && _shouldCloseWithWindow)
        [_content removeFromSuperview];
}

@end

#pragma mark - Panel

@protocol QLPreviewPanelDataSource
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(id)panel;
- (id<QLPreviewItem>)previewPanel:(id)panel previewItemAtIndex:(NSInteger)index;
@end

@protocol QLPreviewPanelDelegate <NSWindowDelegate>
@optional
- (BOOL)previewPanel:(id)panel handleEvent:(NSEvent *)event;
@end

/* The informal protocol a panel controller answers. */
@interface NSObject (QLPreviewPanelController)
- (BOOL)acceptsPreviewPanelControl:(id)panel;
- (void)beginPreviewPanelControl:(id)panel;
- (void)endPreviewPanelControl:(id)panel;
@end

QL_EXPORT
@interface QLPreviewPanel : NSPanel
+ (QLPreviewPanel *)sharedPreviewPanel;
+ (BOOL)sharedPreviewPanelExists;
@property (weak) id<QLPreviewPanelDataSource> dataSource;
@property (readonly, weak) id currentController;
@property NSInteger currentPreviewItemIndex;
@property (readonly) id<QLPreviewItem> currentPreviewItem;
@property (strong) id displayState;
@property (readonly) BOOL inFullScreenMode;
@end

static QLPreviewPanel *sharedPanel;

@implementation QLPreviewPanel {
    QLPreviewView *_preview;
    __weak id _controller;
    NSInteger _index;
    NSString *_noItemsTitle;
}

+ (QLPreviewPanel *)sharedPreviewPanel
{
    if (!sharedPanel)
        sharedPanel = [[self alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskUtilityWindow
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    return sharedPanel;
}

+ (BOOL)sharedPreviewPanelExists { return sharedPanel != nil; }

- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer
{
    if ((self = [super initWithContentRect:rect styleMask:style backing:backing defer:defer])) {
        _preview = [[QLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, rect.size.width, rect.size.height)];
        _preview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.contentView = _preview;
        self.floatingPanel = YES;
        self.hidesOnDeactivate = NO;
        self.releasedWhenClosed = NO;
        _noItemsTitle = @"No Items";
        [self center];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)worksWhenModal { return YES; }
- (BOOL)isOpen { return self.isVisible; }
- (BOOL)isClosing { return NO; }
- (BOOL)isTransient { return NO; }
- (BOOL)inFullScreenMode { return NO; }
- (id)currentController { return _controller; }
- (void)setNoItemsTitle:(NSString *)t { _noItemsTitle = [t copy]; }

/* The panel's controller: up the key window's responder chain (skipping the panel), the
   first that accepts. */
- (void)updateController
{
    id found = nil;
    for (NSWindow *w in @[ [NSApp mainWindow] ?: (id)[NSNull null], [NSApp keyWindow] ?: (id)[NSNull null] ]) {
        if (![w isKindOfClass:[NSWindow class]] || w == self)
            continue;
        for (NSResponder *r = w.firstResponder; r && !found; r = r.nextResponder)
            if ([r respondsToSelector:@selector(acceptsPreviewPanelControl:)] && [r acceptsPreviewPanelControl:self])
                found = r;
        if (!found && [w.delegate respondsToSelector:@selector(acceptsPreviewPanelControl:)] &&
            [(id)w.delegate acceptsPreviewPanelControl:self])
            found = w.delegate;
        if (!found && [NSApp.delegate respondsToSelector:@selector(acceptsPreviewPanelControl:)] &&
            [(id)NSApp.delegate acceptsPreviewPanelControl:self])
            found = NSApp.delegate;
        if (found)
            break;
    }
    if (found == _controller)
        return;
    id old = _controller;
    _controller = found;
    if ([old respondsToSelector:@selector(endPreviewPanelControl:)])
        [old endPreviewPanelControl:self];
    if ([found respondsToSelector:@selector(beginPreviewPanelControl:)])
        [found beginPreviewPanelControl:self];
    [self reloadData];
}

- (NSInteger)_count
{
    id ds = self.dataSource;
    return [ds respondsToSelector:@selector(numberOfPreviewItemsInPreviewPanel:)] ? [ds numberOfPreviewItemsInPreviewPanel:self] : 0;
}

- (id<QLPreviewItem>)currentPreviewItem
{
    id ds = self.dataSource;
    NSInteger n = [self _count];
    if (!n || _index < 0 || _index >= n || ![ds respondsToSelector:@selector(previewPanel:previewItemAtIndex:)])
        return nil;
    return [ds previewPanel:self previewItemAtIndex:_index];
}

- (NSInteger)currentPreviewItemIndex { return _index; }

- (void)setCurrentPreviewItemIndex:(NSInteger)i
{
    _index = i;
    [self refreshCurrentPreviewItem];
}

- (void)refreshCurrentPreviewItem
{
    id<QLPreviewItem> item = self.currentPreviewItem;
    _preview.previewItem = item;
    NSString *title = [item respondsToSelector:@selector(previewItemTitle)] ? item.previewItemTitle : item.previewItemURL.lastPathComponent;
    NSInteger n = [self _count];
    self.title = item ? (n > 1 ? [NSString stringWithFormat:@"%@ (%ld of %ld)", title ?: @"", (long)_index + 1, (long)n] : title ?: @"")
                      : _noItemsTitle;
}

- (void)reloadData
{
    NSInteger n = [self _count];
    if (_index >= n)
        _index = MAX(0, n - 1);
    [self refreshCurrentPreviewItem];
}

- (void)makeKeyAndOrderFront:(id)sender
{
    [self updateController];
    [super makeKeyAndOrderFront:sender];
}

- (void)orderFront:(id)sender
{
    [self updateController];
    [super orderFront:sender];
}

- (void)orderOut:(id)sender
{
    [super orderOut:sender];
    id c = _controller;
    _controller = nil;
    if ([c respondsToSelector:@selector(endPreviewPanelControl:)])
        [c endPreviewPanelControl:self];
}

- (void)close
{
    [self orderOut:nil];
}

- (void)_close:(id)sender { [self close]; }

- (void)keyDown:(NSEvent *)e
{
    id d = self.delegate;
    if ([d respondsToSelector:@selector(previewPanel:handleEvent:)] && [(id)d previewPanel:self handleEvent:e])
        return;
    NSString *c = e.charactersIgnoringModifiers;
    unichar ch = c.length ? [c characterAtIndex:0] : 0;
    NSInteger n = [self _count];
    if (ch == NSRightArrowFunctionKey || ch == NSDownArrowFunctionKey) {
        if (n)
            self.currentPreviewItemIndex = (_index + 1) % n;
    } else if (ch == NSLeftArrowFunctionKey || ch == NSUpArrowFunctionKey) {
        if (n)
            self.currentPreviewItemIndex = (_index + n - 1) % n;
    } else if (ch == ' ' || ch == 27) {
        [self close];
    } else {
        [super keyDown:e];
    }
}

- (BOOL)enterFullScreenMode:(NSScreen *)screen withOptions:(NSDictionary *)options { return NO; }
- (void)exitFullScreenModeWithOptions:(NSDictionary *)options {}
- (NSURL *)appURLForOpening { return nil; }

@end

/* AppKit's toggle (the Quick Look menu item and the space bar in many apps). */
@implementation NSResponder (QLPreviewPanelToggle)
- (void)quickLookPreviewItems:(id)sender
{
    QLPreviewPanel *p = [QLPreviewPanel sharedPreviewPanel];
    if (p.isVisible)
        [p orderOut:sender];
    else
        [p makeKeyAndOrderFront:sender];
}
@end

#pragma mark - Private classes apps link

QL_EXPORT
@interface QLPreviewDocument : NSObject
@property (strong) id previewView;
@property (copy) NSString *password;
@property NSUInteger state;
@end

@implementation QLPreviewDocument {
    id _item;
}
- (instancetype)initWithPreviewItem:(id)item forPreviewView:(id)view
{
    if ((self = [super init])) {
        _item = item;
        _previewView = view;
    }
    return self;
}
- (NSURL *)currentURL { return [_item respondsToSelector:@selector(previewItemURL)] ? [_item previewItemURL] : nil; }
- (id)preview { return _item; }
- (BOOL)isLoaded { return YES; }
- (BOOL)isRemote { return NO; }
- (BOOL)isSaving { return NO; }
- (BOOL)isGeneric { return YES; }
- (BOOL)canShare { return NO; }
- (NSUInteger)numberOfPages { return 1; }
- (void)startLoading {}
- (void)invalidate {}
- (id)displayState { return nil; }
@end

/* (seamless opening animates a preview into the app that opens it: Finch opens without) */
QL_EXPORT
@interface QLSeamlessOpener : NSObject
@end
@implementation QLSeamlessOpener
@end

QL_EXPORT
@interface QLSeamlessDocumentOpener : NSObject
@end
@implementation QLSeamlessDocumentOpener
+ (instancetype)sharedOpener { return nil; }
@end

QL_EXPORT
@interface QLSeamlessDocumentCloser : NSObject
@end
@implementation QLSeamlessDocumentCloser
@end

QL_EXPORT
@interface QLAnimationWindowEffect : NSObject
@end
@implementation QLAnimationWindowEffect
@end

QL_EXPORT
@interface QLWarpingWindowEffect : QLAnimationWindowEffect
@end
@implementation QLWarpingWindowEffect
@end

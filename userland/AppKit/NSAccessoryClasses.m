/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Smaller AppKit classes apps link, as Apple's behave: the menu, separator and
 * tracking-separator toolbar items; titlebar and split-view item accessory view
 * controllers; table view row actions; text attachment cells (and the token field's);
 * text attachment view providers; activity items with previews; the speech synthesizer
 * (silent: Finch has no voices or audio output yet; speaking ends at once, and the
 * delegate hears it finished); and the constants and functions they come with.
 */
#import "AppKit_Finch.h"
#import "FinchTheme.h"
#import <objc/runtime.h>

/* (macOS 26.1's scroll-edge styles are kept as objects, whatever the deployment target) */
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

NSAppearanceName const NSAppearanceNameTouchBar = @"NSAppearanceNameFunctionRow";
NSString *const NSFlowLayoutRowVerticalAlignmentKey = @"UIFlowLayoutRowVerticalAlignmentKey";
const NSDirectionalEdgeInsets NSDirectionalEdgeInsetsZero = {0, 0, 0, 0};

/* --- toolbar items --- */

@implementation NSMenuToolbarItem {
    NSMenu *_menu;
    BOOL _showsIndicator;
}

- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
{
    if ((self = [super initWithItemIdentifier:itemIdentifier])) {
        _menu = [[NSMenu alloc] initWithTitle:@""];
        _showsIndicator = YES;
    }
    return self;
}

- (void)dealloc
{
    [_menu release];
    [super dealloc];
}

- (NSMenu *)menu { return _menu; }
- (void)setMenu:(NSMenu *)menu { [_menu autorelease]; _menu = [menu retain]; }
- (BOOL)showsIndicator { return _showsIndicator; }
- (void)setShowsIndicator:(BOOL)shows { _showsIndicator = shows; }

@end

@implementation NSTrackingSeparatorToolbarItem {
    NSSplitView *_splitView;
    NSInteger _dividerIndex;
}

+ (instancetype)trackingSeparatorToolbarItemWithIdentifier:(NSToolbarItemIdentifier)identifier splitView:(NSSplitView *)splitView
                                              dividerIndex:(NSInteger)dividerIndex
{
    NSTrackingSeparatorToolbarItem *item = [[[self alloc] initWithItemIdentifier:identifier] autorelease];
    item.splitView = splitView;
    item.dividerIndex = dividerIndex;
    return item;
}

- (void)dealloc
{
    [_splitView release];
    [super dealloc];
}

- (NSSplitView *)splitView { return _splitView; }
- (void)setSplitView:(NSSplitView *)v { [_splitView autorelease]; _splitView = [v retain]; }
- (NSInteger)dividerIndex { return _dividerIndex; }
- (void)setDividerIndex:(NSInteger)i { _dividerIndex = i; }

@end

/* (the toolbar's separator, by its older class name) */
@interface NSSeparatorToolbarItem : NSToolbarItem
@end

@implementation NSSeparatorToolbarItem
@end

/* --- accessory view controllers --- */

@implementation NSTitlebarAccessoryViewController {
    NSLayoutAttribute _layoutAttribute;
    CGFloat _fullScreenMinHeight;
    BOOL _hidden, _adjustsSize;
    NSWindow *_accessoryWindow; /* (weak: the window keeps its accessories) */
    NSScrollEdgeEffectStyle *_edgeStyle;
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        _layoutAttribute = NSLayoutAttributeBottom;
        _adjustsSize = YES;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _layoutAttribute = [coder containsValueForKey:@"NSLayoutAttribute"] ? (NSLayoutAttribute)[coder decodeIntegerForKey:@"NSLayoutAttribute"]
                                                                             : NSLayoutAttributeBottom;
        _fullScreenMinHeight = [coder decodeDoubleForKey:@"NSFullScreenMinimumHeight"];
        _adjustsSize = YES;
    }
    return self;
}

- (void)dealloc
{
    [_edgeStyle release];
    [super dealloc];
}

/* A side accessory is as tall as the title bar with its toolbar row, as Apple's. */
- (void)_finchFitHeight
{
    if (!_adjustsSize || ![self isViewLoaded])
        return;
    if (_layoutAttribute == NSLayoutAttributeLeft || _layoutAttribute == NSLayoutAttributeRight ||
        _layoutAttribute == NSLayoutAttributeLeading || _layoutAttribute == NSLayoutAttributeTrailing) {
        NSRect f = self.view.frame;
        f.size.height = 36;
        self.view.frame = f;
    }
}

- (NSLayoutAttribute)layoutAttribute { return _layoutAttribute; }

- (void)setLayoutAttribute:(NSLayoutAttribute)attribute
{
    _layoutAttribute = attribute;
    [self _finchFitHeight];
}

- (CGFloat)fullScreenMinHeight { return _fullScreenMinHeight; }
- (void)setFullScreenMinHeight:(CGFloat)h { _fullScreenMinHeight = h; }
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)hidden
{
    _hidden = hidden;
    if ([self isViewLoaded])
        self.view.hidden = hidden;
}
- (BOOL)automaticallyAdjustsSize { return _adjustsSize; }
- (void)setAutomaticallyAdjustsSize:(BOOL)adjusts { _adjustsSize = adjusts; }
- (NSScrollEdgeEffectStyle *)preferredScrollEdgeEffectStyle { return _edgeStyle; }
- (void)setPreferredScrollEdgeEffectStyle:(NSScrollEdgeEffectStyle *)s { [_edgeStyle autorelease]; _edgeStyle = [s retain]; }

- (void)_finchSetAccessoryWindow:(NSWindow *)window
{
    _accessoryWindow = window;
}

/* (an accessory's parent is its window) */
- (void)removeFromParentViewController
{
    NSWindow *w = _accessoryWindow;
    if (w) {
        NSUInteger i = [w.titlebarAccessoryViewControllers indexOfObjectIdenticalTo:self];
        if (i != NSNotFound)
            [w removeTitlebarAccessoryViewControllerAtIndex:(NSInteger)i];
        return;
    }
    [super removeFromParentViewController];
}

- (void)viewWillAppear { [super viewWillAppear]; }
- (void)viewDidAppear { [super viewDidAppear]; }
- (void)viewDidDisappear { [super viewDidDisappear]; }

@end

@implementation NSSplitViewItemAccessoryViewController {
    BOOL _hidden, _appliesInsets;
    NSScrollEdgeEffectStyle *_edgeStyle;
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]))
        _appliesInsets = YES;
    return self;
}

- (void)dealloc
{
    [_edgeStyle release];
    [super dealloc];
}

- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)hidden
{
    _hidden = hidden;
    if ([self isViewLoaded])
        self.view.hidden = hidden;
}
- (BOOL)automaticallyAppliesContentInsets { return _appliesInsets; }
- (void)setAutomaticallyAppliesContentInsets:(BOOL)applies { _appliesInsets = applies; }
- (NSScrollEdgeEffectStyle *)preferredScrollEdgeEffectStyle { return _edgeStyle; }
- (void)setPreferredScrollEdgeEffectStyle:(NSScrollEdgeEffectStyle *)s { [_edgeStyle autorelease]; _edgeStyle = [s retain]; }
- (void)viewWillAppear { [super viewWillAppear]; }
- (void)viewDidAppear { [super viewDidAppear]; }
- (void)viewWillDisappear { [super viewWillDisappear]; }
- (void)viewDidDisappear { [super viewDidDisappear]; }

@end

/* --- row actions --- */

@implementation NSTableViewRowAction {
    NSTableViewRowActionStyle _style;
    NSString *_title;
    NSColor *_background;
    NSImage *_image;
    void (^_handler)(NSTableViewRowAction *, NSInteger);
}

+ (instancetype)rowActionWithStyle:(NSTableViewRowActionStyle)style title:(NSString *)title
                           handler:(void (^)(NSTableViewRowAction *, NSInteger))handler
{
    NSTableViewRowAction *a = [[[self alloc] init] autorelease];
    a->_style = style;
    a->_title = [title copy];
    a->_handler = [handler copy];
    return a;
}

- (void)dealloc
{
    [_title release];
    [_background release];
    [_image release];
    [_handler release];
    [super dealloc];
}

- (NSTableViewRowActionStyle)style { return _style; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t { [_title autorelease]; _title = [t copy]; }
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)i { [_image autorelease]; _image = [i retain]; }

/* (the theme's red for destructive actions; for the rest, its accent in Fieldwork, which
   doesn't use Apple's blue, and system blue in Classic, as Apple's) */
- (NSColor *)backgroundColor
{
    if (_background)
        return _background;
    if (_style == NSTableViewRowActionStyleDestructive)
        return [NSColor systemRedColor];
    return FinchThemeIsClassic() ? [NSColor systemBlueColor] : [NSColor controlAccentColor];
}

- (void)setBackgroundColor:(NSColor *)c { [_background autorelease]; _background = [c copy]; }

- (void)_finchPerformForRow:(NSInteger)row
{
    if (_handler)
        _handler(self, row);
}

- (id)copyWithZone:(NSZone *)zone
{
    NSTableViewRowAction *c = [[[self class] allocWithZone:zone] init];
    c->_style = _style;
    c->_title = [_title copy];
    c->_background = [_background copy];
    c->_image = [_image retain];
    c->_handler = [_handler copy];
    return c;
}

@end

/* --- text attachment cells --- */

@implementation NSTextAttachmentCell {
    NSTextAttachment *_attachment; /* (assign, as Apple's) */
}

- (NSSize)cellSize
{
    NSImage *image = self.image;
    return image ? image.size : NSZeroSize;
}

- (NSPoint)cellBaselineOffset { return NSZeroPoint; }
- (NSTextAttachment *)attachment { return _attachment; }
- (void)setAttachment:(NSTextAttachment *)attachment { _attachment = attachment; }
- (BOOL)wantsToTrackMouse { return YES; }

- (BOOL)wantsToTrackMouseForEvent:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView atCharacterIndex:(NSUInteger)charIndex
{
    return [self wantsToTrackMouse];
}

- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView atCharacterIndex:(NSUInteger)charIndex
      untilMouseUp:(BOOL)flag
{
    return [self trackMouse:event inRect:cellFrame ofView:controlView untilMouseUp:flag];
}

- (NSRect)cellFrameForTextContainer:(NSTextContainer *)textContainer proposedLineFragment:(NSRect)lineFrag
                      glyphPosition:(NSPoint)position characterIndex:(NSUInteger)charIndex
{
    NSSize size = [self cellSize];
    NSPoint offset = [self cellBaselineOffset];
    return NSMakeRect(offset.x, offset.y, size.width, size.height);
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSImage *image = self.image;
    if (image)
        [image drawInRect:cellFrame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView characterIndex:(NSUInteger)charIndex
{
    [self drawWithFrame:cellFrame inView:controlView];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView characterIndex:(NSUInteger)charIndex
        layoutManager:(NSLayoutManager *)layoutManager
{
    [self drawWithFrame:cellFrame inView:controlView];
}

- (void)highlight:(BOOL)flag withFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
}

@end

/* (the token field's attachment cell, private, by Apple's name) */
@interface NSTokenAttachmentCell : NSTextAttachmentCell
@end

@implementation NSTokenAttachmentCell
@end

/* --- text attachment view providers --- */

@implementation NSTextAttachmentViewProvider {
    NSTextAttachment *_attachment;   /* (weak) */
    NSTextLayoutManager *_layout;    /* (weak) */
    NSView *_parent;                 /* (weak) */
    id<NSTextLocation> _location;
    NSView *_view;
    BOOL _tracks;
}

- (instancetype)initWithTextAttachment:(NSTextAttachment *)textAttachment parentView:(NSView *)parentView
                     textLayoutManager:(NSTextLayoutManager *)textLayoutManager location:(id<NSTextLocation>)location
{
    if ((self = [super init])) {
        _attachment = textAttachment;
        _parent = parentView;
        _layout = textLayoutManager;
        _location = [(id)location retain];
    }
    return self;
}

- (void)dealloc
{
    [(id)_location release];
    [_view release];
    [super dealloc];
}

- (NSTextAttachment *)textAttachment { return _attachment; }
- (NSTextLayoutManager *)textLayoutManager { return _layout; }
- (id<NSTextLocation>)location { return _location; }
- (NSView *)view { return _view; }
- (void)setView:(NSView *)view { [_view autorelease]; _view = [view retain]; }
- (BOOL)tracksTextAttachmentViewBounds { return _tracks; }
- (void)setTracksTextAttachmentViewBounds:(BOOL)tracks { _tracks = tracks; }

/* (subclasses make the view; this one makes none, as Apple's) */
- (void)loadView
{
}

- (CGRect)attachmentBoundsForAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes location:(id<NSTextLocation>)location
                          textContainer:(NSTextContainer *)textContainer proposedLineFragment:(CGRect)proposedLineFragment
                          position:(CGPoint)position
{
    return _view ? (CGRect){CGPointZero, _view.frame.size} : CGRectZero;
}

@end

/* --- activity items --- */

@implementation NSPreviewRepresentingActivityItem {
    id _item;
    NSString *_title;
    NSItemProvider *_imageProvider, *_iconProvider;
}

static NSItemProvider *
provider_for(NSImage *image)
{
    /* (made for a missing image too, as Apple's are; it then provides nothing) */
    NSItemProvider *p = [[[NSItemProvider alloc] init] autorelease];
    if (image) {
        NSImage *held = [[image retain] autorelease];
        [p registerDataRepresentationForTypeIdentifier:@"public.tiff" visibility:NSItemProviderRepresentationVisibilityAll
                                           loadHandler:^NSProgress *(void (^completion)(NSData *, NSError *)) {
                                             completion([held TIFFRepresentation], nil);
                                             return nil;
                                           }];
    }
    return p;
}

- (instancetype)initWithItem:(id)item title:(NSString *)title image:(NSImage *)image icon:(NSImage *)icon
{
    return [self initWithItem:item title:title imageProvider:provider_for(image) iconProvider:provider_for(icon)];
}

- (instancetype)initWithItem:(id)item title:(NSString *)title imageProvider:(NSItemProvider *)imageProvider iconProvider:(NSItemProvider *)iconProvider
{
    if ((self = [super init])) {
        _item = [item retain];
        _title = [title copy];
        _imageProvider = [imageProvider retain];
        _iconProvider = [iconProvider retain];
    }
    return self;
}

- (void)dealloc
{
    [_item release];
    [_title release];
    [_imageProvider release];
    [_iconProvider release];
    [super dealloc];
}

- (id)item { return _item; }
- (NSString *)title { return _title; }
- (NSItemProvider *)imageProvider { return _imageProvider; }
- (NSItemProvider *)iconProvider { return _iconProvider; }

@end

/* --- the speech synthesizer --- */

@implementation NSSpeechSynthesizer {
    NSSpeechSynthesizerVoiceName _voice;
    id<NSSpeechSynthesizerDelegate> _delegate; /* (weak) */
    float _rate, _volume;
    BOOL _usesFeedbackWindow;
}

- (instancetype)init
{
    return [self initWithVoice:nil];
}

- (instancetype)initWithVoice:(NSSpeechSynthesizerVoiceName)voice
{
    if ((self = [super init])) {
        _voice = [(voice ?: [NSSpeechSynthesizer defaultVoice]) copy];
        _rate = 175;
        _volume = 1;
    }
    return self;
}

- (void)dealloc
{
    [_voice release];
    [super dealloc];
}

+ (NSSpeechSynthesizerVoiceName)defaultVoice { return @"com.apple.voice.compact.en-US.Samantha"; }
+ (NSArray<NSSpeechSynthesizerVoiceName> *)availableVoices { return @[]; }
+ (NSDictionary<NSVoiceAttributeKey, id> *)attributesForVoice:(NSSpeechSynthesizerVoiceName)voice { return @{}; }
+ (BOOL)isAnyApplicationSpeaking { return NO; }

- (id<NSSpeechSynthesizerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSpeechSynthesizerDelegate>)d { _delegate = d; }
- (NSSpeechSynthesizerVoiceName)voice { return _voice; }
- (BOOL)setVoice:(NSSpeechSynthesizerVoiceName)voice
{
    [_voice autorelease];
    _voice = [(voice ?: [NSSpeechSynthesizer defaultVoice]) copy];
    return YES;
}
- (float)rate { return _rate; }
- (void)setRate:(float)r { _rate = r; }
- (float)volume { return _volume; }
- (void)setVolume:(float)v { _volume = v < 0 ? 0 : v > 1 ? 1 : v; }
- (BOOL)usesFeedbackWindow { return _usesFeedbackWindow; }
- (void)setUsesFeedbackWindow:(BOOL)u { _usesFeedbackWindow = u; }
- (BOOL)isSpeaking { return NO; }

/* (no voices: the speech ends at once, and the delegate hears it finished) */
- (BOOL)startSpeakingString:(NSString *)string
{
    id<NSSpeechSynthesizerDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:didFinishSpeaking:)]) {
        [self retain];
        dispatch_async(dispatch_get_main_queue(), ^{
          [d speechSynthesizer:self didFinishSpeaking:YES];
          [self release];
        });
    }
    return YES;
}

- (BOOL)startSpeakingString:(NSString *)string toURL:(NSURL *)url
{
    return NO;
}

- (void)stopSpeaking {}
- (void)stopSpeakingAtBoundary:(NSSpeechBoundary)boundary {}
- (void)pauseSpeakingAtBoundary:(NSSpeechBoundary)boundary {}
- (void)continueSpeaking {}
- (id)objectForProperty:(NSSpeechPropertyKey)property error:(NSError **)outError { return nil; }
- (BOOL)setObject:(id)object forProperty:(NSSpeechPropertyKey)property error:(NSError **)outError { return NO; }
- (NSString *)phonemesFromText:(NSString *)text { return @""; }
- (void)addSpeechDictionary:(NSDictionary<NSSpeechDictionaryKey, id> *)speechDictionary {}

@end

/* --- functions apps call --- */

/* (the old NSPreferences support's start: nothing to set up) */
void _nsBeginNSPSupport(void);
void
_nsBeginNSPSupport(void)
{
}

/* (accessibility unique ids are Finch's accessibility server's, when there is one) */
void NSAccessibilityUnregisterUniqueIdForUIElement(id element);
void
NSAccessibilityUnregisterUniqueIdForUIElement(id element)
{
    (void)element;
}

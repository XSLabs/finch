/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSStatusBar and NSStatusItem: an app's items at the right of the menu bar. As on
 * macOS, each item is its own small window at the status level, above the menu bar,
 * holding the item's button (or its custom view); a click shows the item's menu under
 * it, or sends the button's action. Items line up from the right, left of the
 * Instrument Bar's workbench and clock and of the items other apps already show
 * there, newest leftmost.
 */
#import "AppKit_Finch.h"
#import "NSMenu_Finch.h"

@interface NSStatusItem ()
- (instancetype)_finchInitWithBar:(NSStatusBar *)bar length:(CGFloat)length;
- (void)_finchPlaceAtRight:(CGFloat)right;
- (CGFloat)_finchWidth;
- (void)_finchClose;
- (void)_finchButtonClicked:(NSEvent *)event;
@end

@interface FinchStatusWindow : NSPanel
@end

@implementation FinchStatusWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)worksWhenModal { return YES; }
@end

@implementation NSStatusBarButton {
    BOOL _appearsDisabled;
    __unsafe_unretained NSStatusItem *_item;
}

- (BOOL)appearsDisabled { return _appearsDisabled; }
- (void)setAppearsDisabled:(BOOL)v
{
    _appearsDisabled = v;
    [self setNeedsDisplay:YES];
}

- (void)_finchSetItem:(NSStatusItem *)item { _item = item; }

/* The bar's windows never become key: a click acts at once, as in the menu bar. */
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

/* An item with a menu shows it; otherwise the button acts as buttons do. */
- (void)mouseDown:(NSEvent *)event
{
    if (_item.menu) {
        [self highlight:YES];
        [_item _finchButtonClicked:event];
        [self highlight:NO];
        return;
    }
    [super mouseDown:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    if (_item.menu)
        [self mouseDown:event];
    else
        [super rightMouseDown:event];
}

- (void)drawRect:(NSRect)dirty
{
    if ([[self cell] isHighlighted]) {
        [[NSColor selectedContentBackgroundColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect([self bounds], 1, 2) xRadius:4 yRadius:4] fill];
    }
    NSRect b = [self bounds];
    CGFloat alpha = _appearsDisabled ? 0.5 : 1;
    NSImage *image = [self image];
    NSString *title = [self title];
    CGFloat x = 6;
    if (image) {
        NSSize s = [image size];
        if (s.height > b.size.height - 4) {
            s.width *= (b.size.height - 4) / s.height;
            s.height = b.size.height - 4;
        }
        NSRect r = NSMakeRect(title.length ? x : floor((b.size.width - s.width) / 2), floor((b.size.height - s.height) / 2), s.width,
                              s.height);
        [image drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES hints:nil];
        x = NSMaxX(r) + 4;
    }
    if (title.length) {
        NSDictionary *a = @{
            NSFontAttributeName : [NSFont menuBarFontOfSize:0],
            NSForegroundColorAttributeName : [[NSColor labelColor] colorWithAlphaComponent:alpha],
        };
        NSAttributedString *t = [[self attributedTitle] length] ? [self attributedTitle] : [[[NSAttributedString alloc] initWithString:title attributes:a] autorelease];
        NSSize s = [t size];
        [t drawAtPoint:NSMakePoint(image ? x : floor((b.size.width - s.width) / 2), floor((b.size.height - s.height) / 2))];
    }
}

@end

@implementation NSStatusBar {
    NSMutableArray<NSStatusItem *> *_items;
}

+ (NSStatusBar *)systemStatusBar
{
    static NSStatusBar *bar;
    if (!bar)
        bar = [[NSStatusBar alloc] init];
    return bar;
}

- (instancetype)init
{
    if ((self = [super init]))
        _items = [NSMutableArray new];
    return self;
}

- (void)dealloc
{
    [_items release];
    [super dealloc];
}

- (BOOL)isVertical { return NO; }
- (CGFloat)thickness { return FinchMenuBarHeight(); }

- (NSStatusItem *)statusItemWithLength:(CGFloat)length
{
    NSStatusItem *item = [[[NSStatusItem alloc] _finchInitWithBar:self length:length] autorelease];
    [_items addObject:item];
    [self _finchLayout];
    return item;
}

- (void)removeStatusItem:(NSStatusItem *)item
{
    [item retain];
    [item _finchClose];
    [_items removeObject:item];
    [item release];
    [self _finchLayout];
}

/* Where this app's items end on the right: left of the bar's instruments, and of the
   status windows other apps show. */
static CGFloat
right_edge(void)
{
    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat right = NSMaxX(screen) - FinchMenuBarInstrumentsWidth();
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    pid_t me = getpid();
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        NSDictionary *w = (NSDictionary *)CFArrayGetValueAtIndex(list, i);
        if ([w[(NSString *)kCGWindowLayer] integerValue] != NSStatusWindowLevel || [w[(NSString *)kCGWindowOwnerPID] intValue] == me)
            continue;
        CGRect r;
        if (CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(NSString *)kCGWindowBounds], &r) && r.origin.x < right &&
            r.origin.y < FinchMenuBarHeight())
            right = r.origin.x;
    }
    if (list)
        CFRelease(list);
    return right;
}

- (void)_finchLayout
{
    CGFloat right = right_edge();
    for (NSStatusItem *item in _items) {
        if (![item isVisible])
            continue;
        [item _finchPlaceAtRight:right];
        right -= [item _finchWidth];
    }
}

@end

@implementation NSStatusItem {
    NSStatusBar *_bar; /* not retained */
    CGFloat _length;
    NSMenu *_menu;
    NSStatusBarButton *_button;
    NSView *_view;
    FinchStatusWindow *_window;
    NSStatusItemBehavior _behavior;
    BOOL _visible;
    NSString *_autosaveName;
    BOOL _highlightMode;
    SEL _doubleAction;
}

- (instancetype)_finchInitWithBar:(NSStatusBar *)bar length:(CGFloat)length
{
    if (!(self = [super init]))
        return nil;
    _bar = bar;
    _length = length;
    _visible = YES;
    CGFloat h = FinchMenuBarHeight();
    _window = [[FinchStatusWindow alloc] initWithContentRect:NSMakeRect(0, 0, 24, h) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    [_window setLevel:NSStatusWindowLevel];
    [_window setOpaque:NO];
    [_window setBackgroundColor:[NSColor clearColor]];
    [_window setHasShadow:NO];
    [_window setHidesOnDeactivate:NO];
    [_window setExcludedFromWindowsMenu:YES];
    [_window setIgnoresMouseEvents:NO];
    _button = [[NSStatusBarButton alloc] initWithFrame:NSMakeRect(0, 0, 24, h)];
    [_button setBordered:NO];
    [_button setButtonType:NSButtonTypeMomentaryChange];
    [_button _finchSetItem:self];
    [_window setContentView:_button];
    return self;
}

- (void)dealloc
{
    [_button _finchSetItem:nil];
    [_window close];
    [_window release];
    [_menu release];
    [_button release];
    [_view release];
    [_autosaveName release];
    [super dealloc];
}

- (void)_finchClose
{
    [_window orderOut:nil];
}

- (CGFloat)_finchWidth
{
    if (_length >= 0)
        return _length;
    if (_length == NSSquareStatusItemLength)
        return FinchMenuBarHeight();
    if (_view)
        return NSWidth([_view frame]);
    /* variable: what the button needs */
    CGFloat w = 12;
    if ([_button image])
        w += [[_button image] size].width;
    if ([[_button title] length])
        w += ceil([[_button title] sizeWithAttributes:@{NSFontAttributeName : [NSFont menuBarFontOfSize:0]}].width) +
             ([_button image] ? 4 : 0);
    return MAX(w, 22);
}

- (void)_finchPlaceAtRight:(CGFloat)right
{
    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat w = [self _finchWidth], h = FinchMenuBarHeight();
    [_window setFrame:NSMakeRect(right - w, NSMaxY(screen) - h, w, h) display:YES];
    if (_visible)
        [_window orderFront:nil];
}

- (void)_finchRelayout
{
    [_bar _finchLayout];
    [[_window contentView] setNeedsDisplay:YES];
}

- (void)_finchButtonClicked:(NSEvent *)event
{
    NSRect f = [_window frame];
    [_menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(f), NSMinY(f)) inView:nil];
}

- (NSStatusBar *)statusBar { return _bar; }
- (CGFloat)length { return _length; }
- (void)setLength:(CGFloat)length
{
    _length = length;
    [self _finchRelayout];
}
- (NSMenu *)menu { return _menu; }
- (void)setMenu:(NSMenu *)menu
{
    [_menu autorelease];
    _menu = [menu retain];
}
- (NSStatusBarButton *)button { return _view ? nil : _button; }
- (NSStatusItemBehavior)behavior { return _behavior; }
- (void)setBehavior:(NSStatusItemBehavior)b { _behavior = b; }
- (BOOL)isVisible { return _visible; }
- (void)setVisible:(BOOL)visible
{
    _visible = visible;
    if (!visible)
        [_window orderOut:nil];
    [self _finchRelayout];
}
- (NSStatusItemAutosaveName)autosaveName { return _autosaveName; }
- (void)setAutosaveName:(NSStatusItemAutosaveName)name
{
    [_autosaveName autorelease];
    _autosaveName = [name copy];
}

/* The older interface, through the button. */
- (SEL)action { return [_button action]; }
- (void)setAction:(SEL)action { [_button setAction:action]; }
- (SEL)doubleAction { return _doubleAction; }
- (void)setDoubleAction:(SEL)action { _doubleAction = action; }
- (id)target { return [_button target]; }
- (void)setTarget:(id)target { [_button setTarget:target]; }
- (NSString *)title { return [_button title]; }
- (void)setTitle:(NSString *)title
{
    [_button setTitle:title ?: @""];
    [self _finchRelayout];
}
- (NSAttributedString *)attributedTitle { return [_button attributedTitle]; }
- (void)setAttributedTitle:(NSAttributedString *)title
{
    [_button setAttributedTitle:title];
    [self _finchRelayout];
}
- (NSImage *)image { return [_button image]; }
- (void)setImage:(NSImage *)image
{
    [_button setImage:image];
    [self _finchRelayout];
}
- (NSImage *)alternateImage { return [_button alternateImage]; }
- (void)setAlternateImage:(NSImage *)image { [_button setAlternateImage:image]; }
- (BOOL)isEnabled { return [_button isEnabled]; }
- (void)setEnabled:(BOOL)enabled { [_button setEnabled:enabled]; }
- (BOOL)highlightMode { return _highlightMode; }
- (void)setHighlightMode:(BOOL)mode { _highlightMode = mode; }
- (NSString *)toolTip { return [_button toolTip]; }
- (void)setToolTip:(NSString *)toolTip { [_button setToolTip:toolTip]; }
- (NSInteger)sendActionOn:(NSEventMask)mask { return [_button sendActionOn:mask]; }
- (NSView *)view { return _view; }
- (void)setView:(NSView *)view
{
    [_view autorelease];
    _view = [view retain];
    [_window setContentView:view ?: _button];
    [self _finchRelayout];
}
- (void)drawStatusBarBackgroundInRect:(NSRect)rect withHighlight:(BOOL)highlight
{
    if (highlight) {
        [[NSColor selectedContentBackgroundColor] setFill];
        NSRectFill(rect);
    }
}
- (void)popUpStatusItemMenu:(NSMenu *)menu
{
    NSRect f = [_window frame];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(f), NSMinY(f)) inView:nil];
}

@end

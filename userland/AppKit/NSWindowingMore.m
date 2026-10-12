/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Window, view and controller API beyond the basics, as measured against Apple's
 * (windowing-more-test.m): view-controller presentation through animators (sheets,
 * modal windows and popovers are animators too, as Apple's), transitions between
 * child controllers, safe areas and layout guides, full-screen views, window content
 * borders and title-bar queries, PDF of a window's contents, cursor rects, the newer
 * cursors, mnemonics, table grids, cell settings, the Core Data settings object
 * controllers keep, application helpers, event touches, split-view accessories and the
 * deprecated leftovers apps still call.
 */
#import "NSView_Finch.h"
#import <QuartzCore/QuartzCore.h>

/* (CADisplayLink's maker is iOS's in the SDK; Finch's QuartzCore has it) */
static CADisplayLink *
display_link(id target, SEL selector)
{
    return ((CADisplayLink * (*)(id, SEL, id, SEL)) objc_msgSend)([CADisplayLink class], @selector(displayLinkWithTarget:selector:), target, selector);
}

#pragma mark - View controller presentation

static char presenting_key, presented_key, animator_key;

/* Sheets: the presented controller's window as a sheet on the presenter's. */
@interface _FinchSheetAnimator : NSObject <NSViewControllerPresentationAnimator>
@end
@implementation _FinchSheetAnimator
- (void)animatePresentationOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    NSWindow *sheet = [NSWindow windowWithContentViewController:vc];
    NSWindow *parent = [[from view] window];
    if (parent)
        [parent beginSheet:sheet completionHandler:nil];
    else
        [sheet makeKeyAndOrderFront:nil];
}
- (void)animateDismissalOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    NSWindow *sheet = [[vc view] window];
    if ([sheet sheetParent])
        [[sheet sheetParent] endSheet:sheet];
    else
        [sheet close];
}
@end

/* Modal windows: centred, above the others, closed on dismissal. */
@interface _FinchModalWindowAnimator : NSObject <NSViewControllerPresentationAnimator>
@end
@implementation _FinchModalWindowAnimator
- (void)animatePresentationOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    NSWindow *w = [NSWindow windowWithContentViewController:vc];
    [w center];
    [w setLevel:NSModalPanelWindowLevel];
    [w makeKeyAndOrderFront:nil];
}
- (void)animateDismissalOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    [[[vc view] window] close];
}
@end

/* Popovers: shown against a view's rectangle; closed on dismissal. */
@interface _FinchPopoverAnimator : NSObject <NSViewControllerPresentationAnimator> {
@public
    NSRect _rect;
    NSView *_view;
    NSRectEdge _edge;
    NSPopoverBehavior _behavior;
    NSPopover *_popover;
}
@end
@implementation _FinchPopoverAnimator
- (void)dealloc
{
    [_view release];
    [_popover release];
    [super dealloc];
}
- (void)animatePresentationOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    _popover = [[NSPopover alloc] init];
    [_popover setContentViewController:vc];
    [_popover setBehavior:_behavior];
    [_popover showRelativeToRect:_rect ofView:_view preferredEdge:_edge];
}
- (void)animateDismissalOfViewController:(NSViewController *)vc fromViewController:(NSViewController *)from
{
    [_popover close];
}
@end

@implementation NSViewController (FinchPresentation)

- (NSViewController *)presentingViewController { return objc_getAssociatedObject(self, &presenting_key); }

- (NSArray<__kindof NSViewController *> *)presentedViewControllers
{
    NSArray *a = objc_getAssociatedObject(self, &presented_key);
    return [a count] ? [[a copy] autorelease] : nil;
}

- (void)presentViewController:(NSViewController *)viewController animator:(id<NSViewControllerPresentationAnimator>)animator
{
    if (!viewController)
        return;
    NSMutableArray *presented = objc_getAssociatedObject(self, &presented_key);
    if (!presented) {
        presented = [NSMutableArray array];
        objc_setAssociatedObject(self, &presented_key, presented, OBJC_ASSOCIATION_RETAIN);
    }
    [presented addObject:viewController];
    objc_setAssociatedObject(viewController, &presenting_key, self, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(viewController, &animator_key, animator, OBJC_ASSOCIATION_RETAIN);
    [animator animatePresentationOfViewController:viewController fromViewController:self];
}

- (void)presentViewControllerAsSheet:(NSViewController *)viewController
{
    [self presentViewController:viewController animator:[[[_FinchSheetAnimator alloc] init] autorelease]];
}

- (void)presentViewControllerAsModalWindow:(NSViewController *)viewController
{
    [self presentViewController:viewController animator:[[[_FinchModalWindowAnimator alloc] init] autorelease]];
}

- (void)presentViewController:(NSViewController *)viewController asPopoverRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView
                preferredEdge:(NSRectEdge)preferredEdge behavior:(NSPopoverBehavior)behavior
{
    _FinchPopoverAnimator *a = [[[_FinchPopoverAnimator alloc] init] autorelease];
    a->_rect = positioningRect;
    a->_view = [positioningView retain];
    a->_edge = preferredEdge;
    a->_behavior = behavior;
    [self presentViewController:viewController animator:a];
}

- (void)presentViewController:(NSViewController *)viewController asPopoverRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView
                preferredEdge:(NSRectEdge)preferredEdge behavior:(NSPopoverBehavior)behavior hasFullSizeContent:(BOOL)hasFullSizeContent
{
    [self presentViewController:viewController asPopoverRelativeToRect:positioningRect ofView:positioningView preferredEdge:preferredEdge
                       behavior:behavior];
}

- (void)presentViewController:(NSViewController *)controller relativeToRect:(NSRect)rect ofView:(NSView *)view
               preferredEdge:(NSRectEdge)edge behavior:(NSPopoverBehavior)behavior
{
    [self presentViewController:controller asPopoverRelativeToRect:rect ofView:view preferredEdge:edge behavior:behavior];
}

/* By the animator that presented it (its presenter's, when asked of another). */
- (void)dismissViewController:(NSViewController *)viewController
{
    NSViewController *presenter = [viewController presentingViewController];
    id<NSViewControllerPresentationAnimator> animator = objc_getAssociatedObject(viewController, &animator_key);
    if (!presenter || !animator) {
        extern BOOL FinchDismissPopoverController(NSViewController *);
        if (!FinchDismissPopoverController(viewController))
            [[[viewController view] window] close];
        return;
    }
    [[viewController retain] autorelease];
    [[animator retain] autorelease];
    [animator animateDismissalOfViewController:viewController fromViewController:presenter];
    [objc_getAssociatedObject(presenter, &presented_key) removeObjectIdenticalTo:viewController];
    objc_setAssociatedObject(viewController, &presenting_key, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(viewController, &animator_key, nil, OBJC_ASSOCIATION_RETAIN);
}

- (IBAction)dismissController:(id)sender
{
    NSViewController *presenter = [self presentingViewController];
    if (presenter)
        [presenter dismissViewController:self];
    else
        [self dismissViewController:self];
}

/* The child controllers' views swapped in their superview (the transition's animation
   is the swap itself); the completion handler runs on the next turn. */
- (void)transitionFromViewController:(NSViewController *)fromViewController toViewController:(NSViewController *)toViewController
                             options:(NSViewControllerTransitionOptions)options completionHandler:(void (^)(void))completion
{
    NSView *from = [fromViewController view], *to = [toViewController view];
    NSView *container = [from superview];
    if (container && to) {
        [to setFrame:[from frame]];
        [container replaceSubview:from with:to];
    }
    if (completion)
        dispatch_async(dispatch_get_main_queue(), completion);
}

- (void)viewWillTransitionToSize:(NSSize)newSize {}
- (void)preferredContentSizeDidChangeForViewController:(NSViewController *)viewController {}

static char screen_origin_key, source_view_key;
- (NSPoint)preferredScreenOrigin
{
    NSValue *v = objc_getAssociatedObject(self, &screen_origin_key);
    return v ? [v pointValue] : NSZeroPoint;
}
- (void)setPreferredScreenOrigin:(NSPoint)p { objc_setAssociatedObject(self, &screen_origin_key, [NSValue valueWithPoint:p], OBJC_ASSOCIATION_RETAIN); }
- (NSView *)sourceItemView { return objc_getAssociatedObject(self, &source_view_key); }
- (void)setSourceItemView:(NSView *)v { objc_setAssociatedObject(self, &source_view_key, v, OBJC_ASSOCIATION_ASSIGN); }
- (NSExtensionContext *)extensionContext { return nil; }

- (void)commitEditingWithDelegate:(id)delegate didCommitSelector:(SEL)didCommitSelector contextInfo:(void *)contextInfo
{
    BOOL ok = [self commitEditing];
    if (delegate && didCommitSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didCommitSelector, self, ok, contextInfo);
}

@end

#pragma mark - Views

NSViewFullScreenModeOptionKey const NSFullScreenModeAllScreens = @"NSFullScreenModeAllScreens";
NSViewFullScreenModeOptionKey const NSFullScreenModeSetting = @"NSFullScreenModeSetting";
NSViewFullScreenModeOptionKey const NSFullScreenModeWindowLevel = @"NSFullScreenModeWindowLevel";
NSViewFullScreenModeOptionKey const NSFullScreenModeApplicationPresentationOptions = @"NSFullScreenModeApplicationPresentationOptions";

static char full_screen_key, compact_key, safe_guide_key, margins_guide_key;

@implementation NSView (FinchWindowingMore)

- (void)updateLayer {}
- (void)prepareForReuse {}
+ (BOOL)isCompatibleWithResponsiveScrolling { return YES; }

static char additional_safe_key;

- (NSEdgeInsets)additionalSafeAreaInsets
{
    NSValue *v = objc_getAssociatedObject(self, &additional_safe_key);
    NSEdgeInsets i = {0, 0, 0, 0};
    if (v)
        [v getValue:&i size:sizeof i];
    return i;
}

- (void)setAdditionalSafeAreaInsets:(NSEdgeInsets)insets
{
    objc_setAssociatedObject(self, &additional_safe_key, [NSValue valueWithBytes:&insets objCType:@encode(NSEdgeInsets)], OBJC_ASSOCIATION_RETAIN);
    [self setNeedsLayout:YES];
}

/* The view's own additional insets, plus the title bar where a full-size content view
   runs under it. */
- (NSEdgeInsets)safeAreaInsets
{
    NSEdgeInsets i = [self additionalSafeAreaInsets];
    NSWindow *w = [self window];
    if (w && ([w styleMask] & NSWindowStyleMaskFullSizeContentView) && self == [w contentView]) {
        CGFloat titlebar = NSHeight([w frame]) - NSHeight([w contentLayoutRect]);
        i.top += MAX(0, titlebar);
    }
    return i;
}

- (NSRect)safeAreaRect
{
    NSEdgeInsets i = [self safeAreaInsets];
    NSRect b = [self bounds];
    return NSMakeRect(NSMinX(b) + i.left, NSMinY(b) + ([self isFlipped] ? i.top : i.bottom), NSWidth(b) - i.left - i.right,
                      NSHeight(b) - i.top - i.bottom);
}

/* A guide pinned to the view's edges, inset by `insets`. */
static NSLayoutGuide *
edge_guide(NSView *view, void *key, NSEdgeInsets insets)
{
    NSLayoutGuide *g = objc_getAssociatedObject(view, key);
    if (g)
        return g;
    g = [[[NSLayoutGuide alloc] init] autorelease];
    [view addLayoutGuide:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:insets.left],
        [g.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-insets.right],
        [g.topAnchor constraintEqualToAnchor:view.topAnchor constant:insets.top],
        [g.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-insets.bottom],
    ]];
    objc_setAssociatedObject(view, key, g, OBJC_ASSOCIATION_RETAIN);
    return g;
}

- (NSLayoutGuide *)safeAreaLayoutGuide { return edge_guide(self, &safe_guide_key, [self safeAreaInsets]); }
- (NSLayoutGuide *)layoutMarginsGuide { return edge_guide(self, &margins_guide_key, NSEdgeInsetsMake(0, 0, 0, 0)); }

/* (macOS 26's regions: the safe area for every region but the view's whole bounds) */
- (NSEdgeInsets)edgeInsetsForLayoutRegion:(NSViewLayoutRegion *)layoutRegion { return [self safeAreaInsets]; }
- (NSRect)rectForLayoutRegion:(NSViewLayoutRegion *)layoutRegion { return [self safeAreaRect]; }
- (NSLayoutGuide *)layoutGuideForLayoutRegion:(NSViewLayoutRegion *)layoutRegion { return [self safeAreaLayoutGuide]; }

- (NSRect)rectForSmartMagnificationAtPoint:(NSPoint)location inRect:(NSRect)visibleRect { return NSZeroRect; }

- (BOOL)prefersCompactControlSizeMetrics { return [objc_getAssociatedObject(self, &compact_key) boolValue]; }
- (void)setPrefersCompactControlSizeMetrics:(BOOL)flag { objc_setAssociatedObject(self, &compact_key, @(flag), OBJC_ASSOCIATION_RETAIN); }

/* Full screen: the view alone in a borderless window covering the screen, put back
   where it was on exit. */
- (BOOL)enterFullScreenMode:(NSScreen *)screen withOptions:(NSDictionary<NSViewFullScreenModeOptionKey, id> *)options
{
    if ([self isInFullScreenMode])
        return YES;
    NSScreen *s = screen ?: [[self window] screen] ?: [NSScreen mainScreen];
    NSDictionary *saved = @{
        @"superview" : [self superview] ?: [NSNull null],
        @"frame" : [NSValue valueWithRect:[self frame]],
        @"index" : @([[[self superview] subviews] indexOfObjectIdenticalTo:self]),
    };
    NSWindow *full = [[[NSWindow alloc] initWithContentRect:[s frame] styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered
                                                      defer:NO] autorelease];
    [full setLevel:[options[NSFullScreenModeWindowLevel] integerValue] ?: NSMainMenuWindowLevel + 1];
    [full setReleasedWhenClosed:NO];
    [self retain];
    [self removeFromSuperview];
    [full setContentView:self];
    [self release];
    [full makeKeyAndOrderFront:nil];
    objc_setAssociatedObject(self, &full_screen_key, @{@"window" : full, @"saved" : saved}, OBJC_ASSOCIATION_RETAIN);
    return YES;
}

- (void)exitFullScreenModeWithOptions:(NSDictionary<NSViewFullScreenModeOptionKey, id> *)options
{
    NSDictionary *state = objc_getAssociatedObject(self, &full_screen_key);
    if (!state)
        return;
    NSWindow *full = state[@"window"];
    NSDictionary *saved = state[@"saved"];
    [self retain];
    [full setContentView:[[[NSView alloc] init] autorelease]];
    id superview = saved[@"superview"];
    if (superview != [NSNull null]) {
        [self setFrame:[saved[@"frame"] rectValue]];
        [superview addSubview:self];
    }
    [self release];
    [full orderOut:nil];
    objc_setAssociatedObject(self, &full_screen_key, nil, OBJC_ASSOCIATION_RETAIN);
}

- (BOOL)isInFullScreenMode { return objc_getAssociatedObject(self, &full_screen_key) != nil; }

- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector
{
    return display_link(target, selector);
}

/* (graphics states and focus-ring masks from older AppKit: nothing to keep) */
- (void)allocateGState {}
- (void)releaseGState {}
- (void)renewGState {}
- (void)setUpGState {}
- (NSInteger)gState { return 0; }
- (BOOL)shouldDrawColor { return YES; }
- (void)drawFocusRingMask {}
- (NSRect)focusRingMaskBounds { return NSZeroRect; }
- (void)noteFocusRingMaskChanged {}
- (void)setKeyboardFocusRingNeedsDisplayInRect:(NSRect)rect { [self setNeedsDisplayInRect:NSInsetRect(rect, -4, -4)]; }
- (void)prepareContentInRect:(NSRect)rect {}
- (BOOL)lockFocusIfCanDrawInContext:(NSGraphicsContext *)context
{
    if (!context)
        return NO;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    return YES;
}
- (void)drawPageBorderWithSize:(NSSize)borderSize {}
- (void)drawSheetBorderWithSize:(NSSize)borderSize {}
- (NSCandidateListTouchBarItem *)candidateListTouchBarItem { return nil; }

static char pressure_key, writing_coordinator_key;
- (NSPressureConfiguration *)pressureConfiguration { return objc_getAssociatedObject(self, &pressure_key); }
- (void)setPressureConfiguration:(NSPressureConfiguration *)c { objc_setAssociatedObject(self, &pressure_key, c, OBJC_ASSOCIATION_RETAIN); }
- (NSWritingToolsCoordinator *)writingToolsCoordinator { return objc_getAssociatedObject(self, &writing_coordinator_key); }
- (void)setWritingToolsCoordinator:(NSWritingToolsCoordinator *)c
{
    objc_setAssociatedObject(self, &writing_coordinator_key, c, OBJC_ASSOCIATION_RETAIN);
}

- (void)writeEPSInsideRect:(NSRect)rect toPasteboard:(NSPasteboard *)pasteboard
{
    [pasteboard declareTypes:@[ NSPasteboardTypePDF ] owner:nil];
    [pasteboard setData:[self dataWithPDFInsideRect:rect] forType:NSPasteboardTypePDF];
}

- (void)writePDFInsideRect:(NSRect)rect toPasteboard:(NSPasteboard *)pasteboard
{
    [pasteboard declareTypes:@[ NSPasteboardTypePDF ] owner:nil];
    [pasteboard setData:[self dataWithPDFInsideRect:rect] forType:NSPasteboardTypePDF];
}

@end

#pragma mark - Windows

static char border_key, auto_border_key, cursor_rects_key, backing_key, cached_key;

@implementation NSWindow (FinchWindowingMore)

- (BOOL)hasTitleBar { return ([self styleMask] & NSWindowStyleMaskTitled) != 0; }
- (BOOL)hasCloseBox { return ([self styleMask] & NSWindowStyleMaskClosable) != 0; }
- (CGFloat)userSpaceScaleFactor { return 1; }

static NSString *
edge_key(NSRectEdge edge)
{
    return [NSString stringWithFormat:@"%lu", (unsigned long)edge];
}

- (CGFloat)contentBorderThicknessForEdge:(NSRectEdge)edge
{
    return [objc_getAssociatedObject(self, &border_key)[edge_key(edge)] doubleValue];
}

- (void)setContentBorderThickness:(CGFloat)thickness forEdge:(NSRectEdge)edge
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &border_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &border_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    d[edge_key(edge)] = @(thickness);
    [[[self contentView] superview] setNeedsDisplay:YES];
}

- (BOOL)autorecalculatesContentBorderThicknessForEdge:(NSRectEdge)edge
{
    NSNumber *n = objc_getAssociatedObject(self, &auto_border_key)[edge_key(edge)];
    return n ? [n boolValue] : YES;
}

- (void)setAutorecalculatesContentBorderThickness:(BOOL)flag forEdge:(NSRectEdge)edge
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &auto_border_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &auto_border_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    d[edge_key(edge)] = @(flag);
}

- (BOOL)areCursorRectsEnabled
{
    NSNumber *n = objc_getAssociatedObject(self, &cursor_rects_key);
    return n ? [n boolValue] : YES;
}
- (void)enableCursorRects { objc_setAssociatedObject(self, &cursor_rects_key, @YES, OBJC_ASSOCIATION_RETAIN); }
- (void)disableCursorRects { objc_setAssociatedObject(self, &cursor_rects_key, @NO, OBJC_ASSOCIATION_RETAIN); }

static void
each_view(NSView *v, void (^block)(NSView *))
{
    block(v);
    for (NSView *s in [v subviews])
        each_view(s, block);
}

- (void)discardCursorRects
{
    NSView *top = [[self contentView] superview] ?: [self contentView];
    if (top)
        each_view(top, ^(NSView *v) { [v discardCursorRects]; });
}

- (void)resetCursorRects
{
    [self discardCursorRects];
    NSView *top = [[self contentView] superview] ?: [self contentView];
    if (top)
        each_view(top, ^(NSView *v) { [v resetCursorRects]; });
}

/* (Finch keeps every window in main memory) */
- (NSWindowBackingLocation)backingLocation { return NSWindowBackingLocationMainMemory; }
- (NSWindowBackingLocation)preferredBackingLocation { return [objc_getAssociatedObject(self, &backing_key) integerValue]; }
- (void)setPreferredBackingLocation:(NSWindowBackingLocation)l { objc_setAssociatedObject(self, &backing_key, @(l), OBJC_ASSOCIATION_RETAIN); }

/* (Finch's displays are sRGB) */
- (BOOL)canRepresentDisplayGamut:(NSDisplayGamut)gamut { return gamut == NSDisplayGamutSRGB; }

- (NSData *)dataWithPDFInsideRect:(NSRect)rect
{
    NSView *top = [[self contentView] superview] ?: [self contentView];
    return [top dataWithPDFInsideRect:[top convertRect:rect fromView:nil]];
}

- (NSData *)dataWithEPSInsideRect:(NSRect)rect { return [self dataWithPDFInsideRect:rect]; }

- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector
{
    return display_link(target, selector);
}

/* Printing a window: its content view, through a print operation. */
- (IBAction)print:(id)sender
{
    NSView *v = [self contentView];
    if (v)
        [[NSPrintOperation printOperationWithView:v] runOperationModalForWindow:self delegate:nil didRunSelector:NULL contextInfo:NULL];
}

/* (an image of the window kept to restore later, as older apps animated with) */
- (void)cacheImageInRect:(NSRect)rect
{
    NSView *top = [[self contentView] superview] ?: [self contentView];
    NSBitmapImageRep *rep = [top bitmapImageRepForCachingDisplayInRect:rect];
    [top cacheDisplayInRect:rect toBitmapImageRep:rep];
    objc_setAssociatedObject(self, &cached_key, @[ rep, [NSValue valueWithRect:rect] ], OBJC_ASSOCIATION_RETAIN);
}
- (void)restoreCachedImage { [[[self contentView] superview] setNeedsDisplay:YES]; }
- (void)discardCachedImage { objc_setAssociatedObject(self, &cached_key, nil, OBJC_ASSOCIATION_RETAIN); }

- (NSInteger)orderedIndex { return (NSInteger)[[NSApp orderedWindows] indexOfObjectIdenticalTo:self]; }
- (void)setOrderedIndex:(NSInteger)index
{
    NSArray *ordered = [NSApp orderedWindows];
    if (index <= 0 || ![ordered count])
        [self orderFront:nil];
    else if ((NSUInteger)index - 1 < [ordered count])
        [self orderWindow:NSWindowBelow relativeTo:[ordered[(NSUInteger)index - 1] windowNumber]];
}

- (void)setIsVisible:(BOOL)flag
{
    if (flag)
        [self orderFront:nil];
    else
        [self orderOut:nil];
}
- (void)setIsMiniaturized:(BOOL)flag
{
    if (flag)
        [self miniaturize:nil];
    else
        [self deminiaturize:nil];
}
- (void)setIsZoomed:(BOOL)flag
{
    if (flag != [self isZoomed])
        [self zoom:nil];
}

- (void)setDynamicDepthLimit:(BOOL)flag {}
- (NSInteger)gState { return 0; }
- (void *)windowRef { return NULL; }
- (NSWindow *)initWithWindowRef:(void *)windowRef
{
    [self release];
    return nil;
}
- (void)disableSnapshotRestoration {}
- (void)enableSnapshotRestoration {}

/* (no window sharing: nothing to share with) */
- (void)requestSharingOfWindow:(NSWindow *)window completionHandler:(void (^)(NSError *))completionHandler
{
    if (completionHandler)
        completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}
- (void)requestSharingOfWindowUsingPreview:(NSImage *)image title:(NSString *)title completionHandler:(void (^)(NSError *))completionHandler
{
    [self requestSharingOfWindow:self completionHandler:completionHandler];
}
- (void)transferWindowSharingToWindow:(NSWindow *)window completionHandler:(void (^)(NSError *))completionHandler
{
    [self requestSharingOfWindow:window completionHandler:completionHandler];
}

/* Scripting: the window's document handles save and print; close closes. */
- (id)handleCloseScriptCommand:(NSCloseCommand *)command
{
    NSDocument *doc = [[self windowController] document];
    if (doc)
        return [doc handleCloseScriptCommand:command];
    [self performClose:nil];
    return nil;
}
- (id)handlePrintScriptCommand:(NSScriptCommand *)command
{
    NSDocument *doc = [[self windowController] document];
    if (doc)
        return [doc handlePrintScriptCommand:command];
    [self print:nil];
    return nil;
}
- (id)handleSaveScriptCommand:(NSScriptCommand *)command { return [[[self windowController] document] handleSaveScriptCommand:command]; }

@end

@implementation NSScreen (FinchWindowingMore)
- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector
{
    return display_link(target, selector);
}
@end

#pragma mark - Cursors

@implementation NSCursor (FinchWindowingMore)
+ (NSCursor *)zoomInCursor { return [NSCursor crosshairCursor]; }
+ (NSCursor *)zoomOutCursor { return [NSCursor crosshairCursor]; }
+ (NSCursor *)columnResizeCursor { return [NSCursor resizeLeftRightCursor]; }
+ (NSCursor *)rowResizeCursor { return [NSCursor resizeUpDownCursor]; }
+ (NSCursor *)columnResizeCursorInDirections:(NSHorizontalDirections)directions
{
    if (directions == NSHorizontalDirectionsLeft)
        return [NSCursor resizeLeftCursor];
    if (directions == NSHorizontalDirectionsRight)
        return [NSCursor resizeRightCursor];
    return [NSCursor resizeLeftRightCursor];
}
+ (NSCursor *)rowResizeCursorInDirections:(NSVerticalDirections)directions
{
    if (directions == NSVerticalDirectionsUp)
        return [NSCursor resizeUpCursor];
    if (directions == NSVerticalDirectionsDown)
        return [NSCursor resizeDownCursor];
    return [NSCursor resizeUpDownCursor];
}
+ (NSCursor *)frameResizeCursorFromPosition:(NSCursorFrameResizePosition)position inDirections:(NSCursorFrameResizeDirections)directions
{
    BOOL horizontal = position == NSCursorFrameResizePositionLeft || position == NSCursorFrameResizePositionRight;
    BOOL vertical = position == NSCursorFrameResizePositionTop || position == NSCursorFrameResizePositionBottom;
    if (horizontal)
        return [NSCursor resizeLeftRightCursor];
    if (vertical)
        return [NSCursor resizeUpDownCursor];
    return [NSCursor crosshairCursor];
}
@end

#pragma mark - Menus and toolbars

@implementation NSMenu (FinchWindowingMore)
+ (void)setMenuZone:(NSZone *)zone {}
+ (NSZone *)menuZone { return NULL; }
- (NSPoint)locationForSubmenu:(NSMenu *)submenu { return NSZeroPoint; }
- (id)menuRepresentation { return nil; }
- (void)setMenuRepresentation:(id)menuRep {}
- (id)contextMenuRepresentation { return nil; }
- (void)setContextMenuRepresentation:(id)menuRep {}
- (id)tearOffMenuRepresentation { return nil; }
- (void)setTearOffMenuRepresentation:(id)menuRep {}
@end

static char accessory_view_key, accessory_min_key, accessory_max_key;

@implementation NSToolbar (FinchWindowingMore)
- (void)removeItemWithItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
{
    NSArray *items = [self items];
    for (NSUInteger i = [items count]; i > 0; i--)
        if ([[items[i - 1] itemIdentifier] isEqualToString:itemIdentifier])
            [self removeItemAtIndex:(NSInteger)i - 1];
}
- (NSView *)fullScreenAccessoryView { return objc_getAssociatedObject(self, &accessory_view_key); }
- (void)setFullScreenAccessoryView:(NSView *)v { objc_setAssociatedObject(self, &accessory_view_key, v, OBJC_ASSOCIATION_RETAIN); }
- (CGFloat)fullScreenAccessoryViewMinHeight { return [objc_getAssociatedObject(self, &accessory_min_key) doubleValue]; }
- (void)setFullScreenAccessoryViewMinHeight:(CGFloat)h { objc_setAssociatedObject(self, &accessory_min_key, @(h), OBJC_ASSOCIATION_RETAIN); }
- (CGFloat)fullScreenAccessoryViewMaxHeight { return [objc_getAssociatedObject(self, &accessory_max_key) doubleValue]; }
- (void)setFullScreenAccessoryViewMaxHeight:(CGFloat)h { objc_setAssociatedObject(self, &accessory_max_key, @(h), OBJC_ASSOCIATION_RETAIN); }
@end

#pragma mark - Mnemonics

/* A button's title without its first "&" marker ("&&" stays, as Apple's leaves it);
   text fields and boxes take the string as it is. */
static NSString *
strip_mnemonic(NSString *s)
{
    NSRange amp = [s rangeOfString:@"&"];
    return amp.location == NSNotFound ? s : [s stringByReplacingCharactersInRange:amp withString:@""];
}

@implementation NSButton (FinchMnemonic)
- (void)setTitleWithMnemonic:(NSString *)stringWithAmpersand { [self setTitle:strip_mnemonic(stringWithAmpersand ?: @"")]; }
@end
@implementation NSTextField (FinchMnemonic)
- (void)setTitleWithMnemonic:(NSString *)stringWithAmpersand { [self setStringValue:stringWithAmpersand ?: @""]; }
@end
@implementation NSBox (FinchMnemonic)
- (void)setTitleWithMnemonic:(NSString *)stringWithAmpersand { [self setTitle:stringWithAmpersand ?: @""]; }
@end

static char alt_mnemonic_key, gradient_key;
@implementation NSButtonCell (FinchMnemonic)
- (void)setAlternateTitleWithMnemonic:(NSString *)s { [self setAlternateTitle:strip_mnemonic(s ?: @"")]; }
- (NSString *)alternateMnemonic { return @""; }
- (NSUInteger)alternateMnemonicLocation { return [objc_getAssociatedObject(self, &alt_mnemonic_key) unsignedIntegerValue] ?: NSNotFound; }
- (void)setAlternateMnemonicLocation:(NSUInteger)location
{
    objc_setAssociatedObject(self, &alt_mnemonic_key, @(location), OBJC_ASSOCIATION_RETAIN);
}
- (NSGradientType)gradientType { return [objc_getAssociatedObject(self, &gradient_key) unsignedIntegerValue]; }
- (void)setGradientType:(NSGradientType)t { objc_setAssociatedObject(self, &gradient_key, @(t), OBJC_ASSOCIATION_RETAIN); }
@end

#pragma mark - Cells and controls

static char entry_key, tint_key;
@implementation NSCell (FinchWindowingMore)
- (NSInteger)entryType { return [objc_getAssociatedObject(self, &entry_key) integerValue]; }
- (void)setEntryType:(NSInteger)type { objc_setAssociatedObject(self, &entry_key, @(type), OBJC_ASSOCIATION_RETAIN); }
- (BOOL)isEntryAcceptable:(NSString *)string { return YES; }
- (NSControlTint)controlTint { return [objc_getAssociatedObject(self, &tint_key) unsignedIntegerValue]; }
- (void)setControlTint:(NSControlTint)tint { objc_setAssociatedObject(self, &tint_key, @(tint), OBJC_ASSOCIATION_RETAIN); }

/* A number format with digits left and right of the point (old cells: a formatter). */
- (void)setFloatingPointFormat:(BOOL)autoRange left:(NSUInteger)leftDigits right:(NSUInteger)rightDigits
{
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    [f setNumberStyle:NSNumberFormatterDecimalStyle];
    [f setMaximumIntegerDigits:leftDigits];
    [f setMinimumFractionDigits:autoRange ? 0 : rightDigits];
    [f setMaximumFractionDigits:rightDigits];
    [self setFormatter:f];
}
@end

@implementation NSControl (FinchWindowingMore)
- (void)calcSize {}
- (void)setNeedsDisplay { [self setNeedsDisplay:YES]; }
- (void)setFloatingPointFormat:(BOOL)autoRange left:(NSUInteger)leftDigits right:(NSUInteger)rightDigits
{
    [[self cell] setFloatingPointFormat:autoRange left:leftDigits right:rightDigits];
}
@end

#pragma mark - Tables, browsers, collection views

@implementation NSTableView (FinchWindowingMore)
- (BOOL)drawsGrid { return [self gridStyleMask] != NSTableViewGridNone; }
- (void)setDrawsGrid:(BOOL)flag
{
    [self setGridStyleMask:flag ? (NSTableViewSolidVerticalGridLineMask | NSTableViewSolidHorizontalGridLineMask) : NSTableViewGridNone];
}
- (NSEnumerator *)selectedRowEnumerator
{
    NSMutableArray *rows = [NSMutableArray array];
    [[self selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { [rows addObject:@(i)]; }];
    return [rows objectEnumerator];
}
- (NSEnumerator *)selectedColumnEnumerator
{
    NSMutableArray *cols = [NSMutableArray array];
    [[self selectedColumnIndexes] enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { [cols addObject:@(i)]; }];
    return [cols objectEnumerator];
}
- (void)didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(tableView:didAddRowView:forRow:)])
        [d tableView:self didAddRowView:rowView forRow:row];
}
- (void)didRemoveRowView:(NSTableRowView *)rowView forRow:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(tableView:didRemoveRowView:forRow:)])
        [d tableView:self didRemoveRowView:rowView forRow:row];
}
- (void)performClickOnCellAtColumn:(NSInteger)column row:(NSInteger)row
{
    NSCell *cell = [self preparedCellAtColumn:column row:row];
    [cell performClick:self];
}
/* The rows drawn into an image, for dragging. */
- (NSImage *)dragImageForRowsWithIndexes:(NSIndexSet *)dragRows tableColumns:(NSArray<NSTableColumn *> *)tableColumns event:(NSEvent *)dragEvent
                                  offset:(NSPointPointer)dragImageOffset
{
    NSRect r = NSZeroRect;
    for (NSUInteger i = [dragRows firstIndex]; i != NSNotFound; i = [dragRows indexGreaterThanIndex:i])
        r = NSUnionRect(r, [self rectOfRow:(NSInteger)i]);
    if (NSIsEmptyRect(r))
        return nil;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:r];
    [self cacheDisplayInRect:r toBitmapImageRep:rep];
    NSImage *image = [[[NSImage alloc] initWithSize:r.size] autorelease];
    [image addRepresentation:rep];
    if (dragImageOffset)
        *dragImageOffset = NSZeroPoint;
    return image;
}
- (NSImage *)dragImageForRows:(NSArray *)dragRows event:(NSEvent *)dragEvent dragImageOffset:(NSPointPointer)dragImageOffset
{
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSNumber *n in dragRows)
        [rows addIndex:[n unsignedIntegerValue]];
    return [self dragImageForRowsWithIndexes:rows tableColumns:[self tableColumns] event:dragEvent offset:dragImageOffset];
}
@end

@implementation NSBrowser (FinchWindowingMore)
- (BOOL)canDragRowsWithIndexes:(NSIndexSet *)rowIndexes inColumn:(NSInteger)column withEvent:(NSEvent *)event
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(browser:canDragRowsWithIndexes:inColumn:withEvent:)])
        return [d browser:self canDragRowsWithIndexes:rowIndexes inColumn:column withEvent:event];
    return YES;
}
- (NSImage *)draggingImageForRowsWithIndexes:(NSIndexSet *)rowIndexes inColumn:(NSInteger)column withEvent:(NSEvent *)event
                                      offset:(NSPointPointer)dragImageOffset
{
    if (dragImageOffset)
        *dragImageOffset = NSZeroPoint;
    NSMatrix *m = [self matrixInColumn:column];
    return [m respondsToSelector:@selector(dataWithPDFInsideRect:)] ? [[[NSImage alloc] initWithData:[m dataWithPDFInsideRect:[m bounds]]] autorelease]
                                                                   : nil;
}
static char browser_mask_key;
- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)isLocal
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &browser_mask_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &browser_mask_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    d[@(isLocal)] = @(mask);
}
- (void)editItemAtIndexPath:(NSIndexPath *)indexPath withEvent:(NSEvent *)event select:(BOOL)select
{
    if ([indexPath length] < 1)
        return;
    NSInteger column = (NSInteger)[indexPath length] - 1;
    NSInteger row = (NSInteger)[indexPath indexAtPosition:[indexPath length] - 1];
    [self selectRow:row inColumn:column];
    NSMatrix *m = [self matrixInColumn:column];
    [m selectText:self];
}
@end

@implementation NSCollectionView (FinchWindowingMore)
- (NSImage *)draggingImageForItemsAtIndexes:(NSIndexSet *)indexes withEvent:(NSEvent *)event offset:(NSPointPointer)dragImageOffset
{
    NSRect r = NSZeroRect;
    for (NSUInteger i = [indexes firstIndex]; i != NSNotFound; i = [indexes indexGreaterThanIndex:i])
        r = NSUnionRect(r, [self frameForItemAtIndex:i]);
    if (NSIsEmptyRect(r))
        return nil;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:r];
    [self cacheDisplayInRect:r toBitmapImageRep:rep];
    NSImage *image = [[[NSImage alloc] initWithSize:r.size] autorelease];
    [image addRepresentation:rep];
    if (dragImageOffset)
        *dragImageOffset = NSZeroPoint;
    return image;
}
@end

/* (no appearing and disappearing animations: elements take their final attributes) */
@implementation NSCollectionViewLayout (FinchWindowingMore)
- (NSCollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingItemAtIndexPath:(NSIndexPath *)itemIndexPath { return nil; }
- (NSCollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingItemAtIndexPath:(NSIndexPath *)itemIndexPath { return nil; }
- (NSCollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingSupplementaryElementOfKind:(NSCollectionViewSupplementaryElementKind)kind
                                                                                        atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}
- (NSCollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingSupplementaryElementOfKind:(NSCollectionViewSupplementaryElementKind)kind
                                                                                          atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}
- (NSCollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingDecorationElementOfKind:(NSCollectionViewDecorationElementKind)kind
                                                                                      atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}
- (NSCollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingDecorationElementOfKind:(NSCollectionViewDecorationElementKind)kind
                                                                                        atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}
- (NSSet<NSIndexPath *> *)indexPathsToDeleteForSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)kind { return [NSSet set]; }
- (NSSet<NSIndexPath *> *)indexPathsToDeleteForDecorationViewOfKind:(NSCollectionViewDecorationElementKind)kind { return [NSSet set]; }
- (NSSet<NSIndexPath *> *)indexPathsToInsertForSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)kind { return [NSSet set]; }
- (NSSet<NSIndexPath *> *)indexPathsToInsertForDecorationViewOfKind:(NSCollectionViewDecorationElementKind)kind { return [NSSet set]; }
- (BOOL)shouldInvalidateLayoutForPreferredLayoutAttributes:(NSCollectionViewLayoutAttributes *)preferredAttributes
                                    withOriginalAttributes:(NSCollectionViewLayoutAttributes *)originalAttributes
{
    return NO;
}
- (NSCollectionViewLayoutInvalidationContext *)invalidationContextForPreferredLayoutAttributes:(NSCollectionViewLayoutAttributes *)preferredAttributes
                                                                      withOriginalAttributes:(NSCollectionViewLayoutAttributes *)originalAttributes
{
    return [[[[[self class] invalidationContextClass] alloc] init] autorelease];
}
@end

#pragma mark - Split views and tab view controllers

static char top_accessories_key, bottom_accessories_key;

@implementation NSSplitViewItem (FinchWindowingMore)
static NSMutableArray *
accessories(NSSplitViewItem *item, void *key)
{
    NSMutableArray *a = objc_getAssociatedObject(item, key);
    if (!a) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(item, key, a, OBJC_ASSOCIATION_RETAIN);
    }
    return a;
}
- (void)addTopAlignedAccessoryViewController:(NSSplitViewItemAccessoryViewController *)c { [accessories(self, &top_accessories_key) addObject:c]; }
- (void)insertTopAlignedAccessoryViewController:(NSSplitViewItemAccessoryViewController *)c atIndex:(NSInteger)index
{
    [accessories(self, &top_accessories_key) insertObject:c atIndex:(NSUInteger)index];
}
- (void)removeTopAlignedAccessoryViewControllerAtIndex:(NSInteger)index
{
    [accessories(self, &top_accessories_key) removeObjectAtIndex:(NSUInteger)index];
}
- (void)addBottomAlignedAccessoryViewController:(NSSplitViewItemAccessoryViewController *)c
{
    [accessories(self, &bottom_accessories_key) addObject:c];
}
- (void)insertBottomAlignedAccessoryViewController:(NSSplitViewItemAccessoryViewController *)c atIndex:(NSInteger)index
{
    [accessories(self, &bottom_accessories_key) insertObject:c atIndex:(NSUInteger)index];
}
- (void)removeBottomAlignedAccessoryViewControllerAtIndex:(NSInteger)index
{
    [accessories(self, &bottom_accessories_key) removeObjectAtIndex:(NSUInteger)index];
}
@end

@implementation NSSplitViewController (FinchWindowingMore)
/* A collapsible item collapses on a divider double-click, as Apple's. */
- (BOOL)splitView:(NSSplitView *)splitView shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex
{
    for (NSSplitViewItem *item in [self splitViewItems])
        if ([[item viewController] view] == subview)
            return [item canCollapse];
    return NO;
}
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    if ([item action] == @selector(toggleSidebar:)) {
        for (NSSplitViewItem *i in [self splitViewItems])
            if ([i behavior] == NSSplitViewItemBehaviorSidebar)
                return YES;
        return NO;
    }
    return YES;
}
@end

@implementation NSSplitView (FinchWindowingMore)
- (BOOL)isPaneSplitter { return [self dividerStyle] == NSSplitViewDividerStylePaneSplitter; }
- (void)setIsPaneSplitter:(BOOL)flag { [self setDividerStyle:flag ? NSSplitViewDividerStylePaneSplitter : NSSplitViewDividerStyleThick]; }
@end

/* A toolbar of the tabs, each an item selecting its tab (the toolbar tab style). */
@implementation NSTabViewController (FinchWindowingMore)
- (NSArray<NSToolbarItemIdentifier> *)_finchTabIdentifiers
{
    NSMutableArray *ids = [NSMutableArray array];
    for (NSUInteger i = 0; i < [[self tabViewItems] count]; i++)
        [ids addObject:[NSString stringWithFormat:@"NSTabViewController.tab.%lu", (unsigned long)i]];
    return ids;
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    NSMutableArray *ids = [NSMutableArray arrayWithObject:NSToolbarFlexibleSpaceItemIdentifier];
    [ids addObjectsFromArray:[self _finchTabIdentifiers]];
    [ids addObject:NSToolbarFlexibleSpaceItemIdentifier];
    return ids;
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar { return [self _finchTabIdentifiers]; }
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag
{
    NSUInteger i = [[self _finchTabIdentifiers] indexOfObject:itemIdentifier];
    if (i == NSNotFound)
        return nil;
    NSTabViewItem *tab = [self tabViewItems][i];
    NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];
    [item setLabel:[tab label] ?: @""];
    [item setImage:[tab image]];
    [item setTarget:self];
    [item setAction:@selector(_finchSelectTabFromToolbar:)];
    [item setTag:(NSInteger)i];
    return item;
}
- (void)_finchSelectTabFromToolbar:(NSToolbarItem *)sender { [self setSelectedTabViewItemIndex:[sender tag]]; }
@end

#pragma mark - Object controllers' Core Data settings

/* (no Core Data: the settings are kept for when there is; fetching finds nothing) */
static char moc_key, entity_key, fetch_predicate_key, lazy_key;

@implementation NSObjectController (FinchCoreData)
- (NSManagedObjectContext *)managedObjectContext { return objc_getAssociatedObject(self, &moc_key); }
- (void)setManagedObjectContext:(NSManagedObjectContext *)c { objc_setAssociatedObject(self, &moc_key, c, OBJC_ASSOCIATION_RETAIN); }
- (NSString *)entityName { return objc_getAssociatedObject(self, &entity_key); }
- (void)setEntityName:(NSString *)name { objc_setAssociatedObject(self, &entity_key, [[name copy] autorelease], OBJC_ASSOCIATION_RETAIN); }
- (NSPredicate *)fetchPredicate { return objc_getAssociatedObject(self, &fetch_predicate_key); }
- (void)setFetchPredicate:(NSPredicate *)p { objc_setAssociatedObject(self, &fetch_predicate_key, p, OBJC_ASSOCIATION_RETAIN); }
- (BOOL)usesLazyFetching { return [objc_getAssociatedObject(self, &lazy_key) boolValue]; }
- (void)setUsesLazyFetching:(BOOL)flag { objc_setAssociatedObject(self, &lazy_key, @(flag), OBJC_ASSOCIATION_RETAIN); }
- (NSFetchRequest *)defaultFetchRequest { return nil; }
- (IBAction)fetch:(id)sender {}
- (BOOL)fetchWithRequest:(NSFetchRequest *)fetchRequest merge:(BOOL)merge error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
    return NO;
}
@end

#pragma mark - Application, responders, events

@implementation NSApplication (FinchWindowingMore)

/* As Apple's: a case- and diacritic-insensitive match, reported as the whole word it's in. */
- (BOOL)searchString:(NSString *)searchString inUserInterfaceItemString:(NSString *)stringToSearch searchRange:(NSRange)searchRange
          foundRange:(NSRange *)foundRange
{
    NSRange r = [stringToSearch rangeOfString:searchString options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch range:searchRange];
    if (r.location == NSNotFound) {
        if (foundRange)
            *foundRange = NSMakeRange(NSNotFound, 0);
        return NO;
    }
    __block NSRange word = r;
    [stringToSearch enumerateSubstringsInRange:searchRange options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                                    usingBlock:^(NSString *s, NSRange wr, NSRange enclosing, BOOL *stop) {
                                        if (NSLocationInRange(r.location, wr)) {
                                            word = NSUnionRange(wr, r);
                                            *stop = YES;
                                        }
                                    }];
    if (foundRange)
        *foundRange = word;
    return YES;
}

/* The documents in their windows' front-to-back order. */
- (NSArray *)orderedDocuments
{
    NSMutableArray *docs = [NSMutableArray array];
    for (NSWindow *w in [self orderedWindows]) {
        NSDocument *d = [[w windowController] document];
        if (d && ![docs containsObject:d])
            [docs addObject:d];
    }
    return docs;
}

- (BOOL)isFullKeyboardAccessEnabled { return ([[NSUserDefaults standardUserDefaults] integerForKey:@"AppleKeyboardUIMode"] & 2) != 0; }
- (NSGraphicsContext *)context { return nil; }
- (void)reportException:(NSException *)exception { NSLog(@"%@", exception); }
- (NSRemoteNotificationType)enabledRemoteNotificationTypes { return NSRemoteNotificationTypeNone; }
- (void)registerForRemoteNotificationTypes:(NSRemoteNotificationType)types {}
- (void)extendStateRestoration {}
- (void)completeStateRestoration {}
- (NSModalSession)beginModalSessionForWindow:(NSWindow *)theWindow relativeToWindow:(NSWindow *)docWindow
{
    return [self beginModalSessionForWindow:theWindow];
}
+ (void)detachDrawingThread:(SEL)selector toTarget:(id)target withObject:(id)argument
{
    [NSThread detachNewThreadSelector:selector toTarget:target withObject:argument];
}
@end

static char responder_activity_key, interface_style_key;
@implementation NSResponder (FinchWindowingMore)
- (NSUserActivity *)userActivity { return objc_getAssociatedObject(self, &responder_activity_key); }
- (void)setUserActivity:(NSUserActivity *)a { objc_setAssociatedObject(self, &responder_activity_key, a, OBJC_ASSOCIATION_RETAIN); }
- (void)updateUserActivityState:(NSUserActivity *)userActivity {}
- (NSInterfaceStyle)interfaceStyle { return [objc_getAssociatedObject(self, &interface_style_key) unsignedIntegerValue]; }
- (void)setInterfaceStyle:(NSInterfaceStyle)s { objc_setAssociatedObject(self, &interface_style_key, @(s), OBJC_ASSOCIATION_RETAIN); }
- (void)encodeRestorableStateWithCoder:(NSCoder *)coder backgroundQueue:(NSOperationQueue *)queue { [self encodeRestorableStateWithCoder:coder]; }
+ (NSArray<Class> *)allowedClassesForRestorableStateKeyPath:(NSString *)keyPath { return @[]; }
@end

/* Touches belong to gesture events; asking another event raises, as Apple's. */
@implementation NSEvent (FinchTouches)
static void
require_touches(NSEvent *e)
{
    NSEventType t = [e type];
    if (t != NSEventTypeGesture && t != NSEventTypeMagnify && t != NSEventTypeSwipe && t != NSEventTypeRotate &&
        t != NSEventTypeBeginGesture && t != NSEventTypeEndGesture && t != NSEventTypeDirectTouch && t != NSEventTypePressure)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid message sent to event \"%@\"", e];
}
- (NSSet<NSTouch *> *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view
{
    require_touches(self);
    return [NSSet set];
}
- (NSSet<NSTouch *> *)allTouches
{
    require_touches(self);
    return [NSSet set];
}
- (NSSet<NSTouch *> *)touchesForView:(NSView *)view
{
    require_touches(self);
    return [NSSet set];
}
- (NSArray<NSTouch *> *)coalescedTouchesForTouch:(NSTouch *)touch
{
    require_touches(self);
    return @[];
}
/* (no tracking swipes yet: the swipe ends at once, unmoved) */
- (void)trackSwipeEventWithOptions:(NSEventSwipeTrackingOptions)options dampenAmountThresholdMin:(CGFloat)minDampenThreshold
                               max:(CGFloat)maxDampenThreshold
                      usingHandler:(void (^)(CGFloat, NSEventPhase, BOOL, BOOL *))trackingHandler
{
    BOOL stop = NO;
    if (trackingHandler)
        trackingHandler(0, NSEventPhaseEnded, YES, &stop);
}
@end

#pragma mark - Image views' symbol effects

/* (no Symbols framework yet: effects are kept, images change at once) */
static char effects_key;
@implementation NSImageView (FinchSymbolEffects)
static NSMutableArray *
effects(NSImageView *v)
{
    NSMutableArray *a = objc_getAssociatedObject(v, &effects_key);
    if (!a) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(v, &effects_key, a, OBJC_ASSOCIATION_RETAIN);
    }
    return a;
}
- (void)addSymbolEffect:(NSSymbolEffect *)symbolEffect
{
    NSSymbolEffectOptions *none = nil;
    [self addSymbolEffect:symbolEffect options:none animated:YES];
}
- (void)addSymbolEffect:(NSSymbolEffect *)symbolEffect options:(NSSymbolEffectOptions *)options
{
    [self addSymbolEffect:symbolEffect options:options animated:YES];
}
- (void)addSymbolEffect:(NSSymbolEffect *)symbolEffect options:(NSSymbolEffectOptions *)options animated:(BOOL)animated
{
    if (symbolEffect)
        [effects(self) addObject:symbolEffect];
}
- (void)removeSymbolEffectOfType:(NSSymbolEffect *)symbolEffect
{
    NSSymbolEffectOptions *none = nil;
    [self removeSymbolEffectOfType:symbolEffect options:none animated:YES];
}
- (void)removeSymbolEffectOfType:(NSSymbolEffect *)symbolEffect options:(NSSymbolEffectOptions *)options
{
    [self removeSymbolEffectOfType:symbolEffect options:options animated:YES];
}
- (void)removeSymbolEffectOfType:(NSSymbolEffect *)symbolEffect options:(NSSymbolEffectOptions *)options animated:(BOOL)animated
{
    NSMutableArray *a = effects(self);
    for (NSUInteger i = [a count]; i > 0; i--)
        if ([a[i - 1] isKindOfClass:[symbolEffect class]])
            [a removeObjectAtIndex:i - 1];
}
- (void)removeAllSymbolEffects { [effects(self) removeAllObjects]; }
- (void)removeAllSymbolEffectsWithOptions:(NSSymbolEffectOptions *)options { [effects(self) removeAllObjects]; }
- (void)removeAllSymbolEffectsWithOptions:(NSSymbolEffectOptions *)options animated:(BOOL)animated { [effects(self) removeAllObjects]; }
- (void)setSymbolImage:(NSImage *)image withContentTransition:(NSSymbolContentTransition *)transition { [self setImage:image]; }
- (void)setSymbolImage:(NSImage *)image withContentTransition:(NSSymbolContentTransition *)transition options:(NSSymbolEffectOptions *)options
{
    [self setImage:image];
}
@end

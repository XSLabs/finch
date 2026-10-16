/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSplitView, NSSplitViewItem and NSSplitViewController. Subviews share
 * the split view's length along its axis, separated by dividers: thick
 * (9 points) by default, thin (1) or pane splitters (10). Adjusting shares
 * the space out in proportion to the subviews' sizes, to the half point,
 * with the last subview taking what is left, as Apple's does. Dividers are
 * dragged with the mouse; the delegate constrains them as on macOS.
 */
#import "NSView_Finch.h"
#include <float.h>

NSNotificationName NSSplitViewWillResizeSubviewsNotification = @"NSSplitViewWillResizeSubviewsNotification";
NSNotificationName NSSplitViewDidResizeSubviewsNotification = @"NSSplitViewDidResizeSubviewsNotification";
const CGFloat NSSplitViewControllerAutomaticDimension = -FLT_MAX;
const CGFloat NSSplitViewItemUnspecifiedDimension = -1;

@implementation NSSplitView {
    BOOL _vertical, _arrangesAll;
    NSSplitViewDividerStyle _style;
    NSString *_autosaveName;
    id<NSSplitViewDelegate> _delegate;  /* not retained */
    NSMutableArray<NSView *> *_arranged;
    NSMutableDictionary<NSNumber *, NSNumber *> *_holding;
    NSInteger _dragging;  /* the divider being dragged, or -1 */
    NSSize _laidOutSize;  /* the size the subviews were last fitted to */
    NSMapTable *_natural; /* subview -> its length when it was added */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _style = NSSplitViewDividerStyleThick;
        _arrangesAll = YES;
        _arranged = [[NSMutableArray alloc] init];
        _holding = [[NSMutableDictionary alloc] init];
        _dragging = -1;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _vertical = [coder decodeBoolForKey:@"NSIsVertical"];
        _style = [coder containsValueForKey:@"NSDividerStyle"] ? [coder decodeIntegerForKey:@"NSDividerStyle"]
                                                                : NSSplitViewDividerStyleThick;
        _autosaveName = [[coder decodeObjectForKey:@"NSAutosaveName"] copy];
        _arrangesAll = YES;
        _arranged = [[NSMutableArray alloc] initWithArray:[self subviews]];
        _holding = [[NSMutableDictionary alloc] init];
        _dragging = -1;
    }
    return self;
}

- (void)dealloc
{
    [_autosaveName release];
    [_arranged release];
    [_holding release];
    [_natural release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isVertical { return _vertical; }
- (void)setVertical:(BOOL)flag
{
    if (flag != _vertical)
        _laidOutSize = NSZeroSize; /* refit along the new axis */
    _vertical = flag;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (NSSplitViewDividerStyle)dividerStyle { return _style; }
- (void)setDividerStyle:(NSSplitViewDividerStyle)style { _style = style; [self setNeedsDisplay:YES]; }
- (NSSplitViewAutosaveName)autosaveName { return _autosaveName; }
- (void)setAutosaveName:(NSSplitViewAutosaveName)name { [_autosaveName autorelease]; _autosaveName = [name copy]; }
- (id<NSSplitViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSplitViewDelegate>)delegate { _delegate = delegate; }
- (BOOL)arrangesAllSubviews { return _arrangesAll; }
- (void)setArrangesAllSubviews:(BOOL)flag { _arrangesAll = flag; }
- (NSArray<NSView *> *)arrangedSubviews { return _arrangesAll ? [self subviews] : [[_arranged copy] autorelease]; }

- (CGFloat)dividerThickness
{
    switch (_style) {
    case NSSplitViewDividerStyleThin: return 1;
    case NSSplitViewDividerStylePaneSplitter: return 10;
    default: return 9;
    }
}

- (NSColor *)dividerColor
{
    return [NSColor separatorColor];
}

- (void)addArrangedSubview:(NSView *)view
{
    [self insertArrangedSubview:view atIndex:(NSInteger)[_arranged count]];
}

/* A split view places its panes by frame: a pane that uses Auto Layout for its own
   placement gets constraints from its frame instead (Apple's wraps each pane in a container
   it pins the pane to, to the same effect). */
static void
frame_placed(NSView *view)
{
    if (![view translatesAutoresizingMaskIntoConstraints]) {
        [view setTranslatesAutoresizingMaskIntoConstraints:YES];
        [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    }
}

- (void)insertArrangedSubview:(NSView *)view atIndex:(NSInteger)index
{
    frame_placed(view);
    [self _finchRememberLength:view];
    if ([view superview] != self)
        [self addSubview:view];
    [_arranged removeObjectIdenticalTo:view];
    [_arranged insertObject:view atIndex:(NSUInteger)MIN(index, (NSInteger)[_arranged count])];
}

- (void)removeArrangedSubview:(NSView *)view
{
    [_arranged removeObjectIdenticalTo:view];
}

- (void)didAddSubview:(NSView *)subview
{
    [super didAddSubview:subview];
    if (_arrangesAll && [_arranged indexOfObjectIdenticalTo:subview] == NSNotFound) {
        frame_placed(subview);
        [self _finchRememberLength:subview];
        [_arranged addObject:subview];
    }
}

- (void)willRemoveSubview:(NSView *)subview
{
    [_arranged removeObjectIdenticalTo:subview];
    [super willRemoveSubview:subview];
}

static CGFloat length_of(NSSplitView *s, NSRect r) { return s->_vertical ? r.size.width : r.size.height; }

/* A subview's own length, from when it was added: what it goes back to when the panes
   holding on would otherwise leave no room for the others. */
- (void)_finchRememberLength:(NSView *)view
{
    if (!_natural)
        _natural = [[NSMapTable weakToStrongObjectsMapTable] retain];
    if ([_natural objectForKey:view])
        return;
    NSSize sz = [view frame].size;
    [_natural setObject:@[ @(sz.width), @(sz.height) ] forKey:view];
}

- (CGFloat)_finchNaturalLength:(NSView *)view
{
    NSArray *n = [_natural objectForKey:view];
    return n ? [n[_vertical ? 0 : 1] doubleValue] : 0;
}
static CGFloat start_of(NSSplitView *s, NSRect r) { return s->_vertical ? NSMinX(r) : NSMinY(r); }

static NSRect
along(NSSplitView *s, CGFloat start, CGFloat length)
{
    NSRect b = [s bounds];
    return s->_vertical ? NSMakeRect(start, NSMinY(b), length, b.size.height)
                        : NSMakeRect(NSMinX(b), start, b.size.width, length);
}

static CGFloat
half(CGFloat v)
{
    return floor(v * 2 + 0.5) / 2;
}

/* Share the length out in proportion to the subviews' current sizes, to the half point. */
- (void)adjustSubviews
{
    NSArray<NSView *> *views = [self arrangedSubviews];
    NSUInteger n = [views count];
    if (!n)
        return;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewWillResizeSubviewsNotification object:self];
    CGFloat available = length_of(self, [self bounds]) - [self dividerThickness] * (n - 1);
    CGFloat total = 0;
    for (NSView *v in views)
        total += [self isSubviewCollapsed:v] ? 0 : length_of(self, [v frame]);
    CGFloat pos = start_of(self, [self bounds]);
    for (NSUInteger i = 0; i < n; i++) {
        NSView *v = views[i];
        CGFloat len;
        if (i == n - 1)
            len = MAX(0, start_of(self, [self bounds]) + length_of(self, [self bounds]) - pos);
        else if (total > 0)
            len = MAX(0, half(length_of(self, [v frame]) * available / total));
        else
            len = half(available / n);
        [v setFrame:along(self, pos, len)];
        pos += len + [self dividerThickness];
    }
    _laidOutSize = [self bounds].size;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:self];
    [self setNeedsDisplay:YES];
}

/* A change of size goes to the subviews holding on least (the lowest holding priority),
   as Apple's does: a sidebar keeps its width while the content beside it grows. When
   every subview holds on equally, they all change in proportion. */
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    if ([(id)_delegate respondsToSelector:@selector(splitView:resizeSubviewsWithOldSize:)]) {
        [_delegate splitView:self resizeSubviewsWithOldSize:oldSize];
        _laidOutSize = [self bounds].size;
        return;
    }
    NSArray<NSView *> *views = [self arrangedSubviews];
    NSUInteger n = [views count];
    if (n < 2) {
        [self adjustSubviews];
        return;
    }
    NSLayoutPriority lowest = NSLayoutPriorityRequired, highest = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if ([self isSubviewCollapsed:views[i]])
            continue;
        NSLayoutPriority p = [self holdingPriorityForSubviewAtIndex:(NSInteger)i];
        lowest = MIN(lowest, p);
        highest = MAX(highest, p);
    }
    if (lowest == highest) {
        [self adjustSubviews];
        return;
    }
    CGFloat available = length_of(self, [self bounds]) - [self dividerThickness] * (n - 1);
    CGFloat held = 0;
    NSUInteger flexible = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if ([self isSubviewCollapsed:views[i]])
            continue;
        if ([self holdingPriorityForSubviewAtIndex:(NSInteger)i] > lowest)
            held += length_of(self, [views[i] frame]);
        else
            flexible++;
    }
    /* the panes holding on take their own lengths back when they'd crowd the others out */
    BOOL natural = flexible && held >= available - flexible;
    if (natural) {
        held = 0;
        for (NSUInteger i = 0; i < n; i++)
            if (![self isSubviewCollapsed:views[i]] && [self holdingPriorityForSubviewAtIndex:(NSInteger)i] > lowest) {
                CGFloat own = [self _finchNaturalLength:views[i]];
                held += own > 0 ? own : length_of(self, [views[i] frame]);
            }
    }
    CGFloat share = flexible ? MAX(0, half((available - held) / flexible)) : 0;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewWillResizeSubviewsNotification object:self];
    CGFloat pos = start_of(self, [self bounds]);
    for (NSUInteger i = 0; i < n; i++) {
        NSView *v = views[i];
        CGFloat len;
        if ([self isSubviewCollapsed:v])
            len = 0;
        else if (i == n - 1)
            len = MAX(0, start_of(self, [self bounds]) + length_of(self, [self bounds]) - pos);
        else if ([self holdingPriorityForSubviewAtIndex:(NSInteger)i] > lowest) {
            CGFloat own = natural ? [self _finchNaturalLength:v] : 0;
            len = own > 0 ? own : length_of(self, [v frame]);
        }
        else
            len = share;
        [v setFrame:along(self, pos, len)];
        pos += len + [self dividerThickness];
    }
    _laidOutSize = [self bounds].size;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:self];
    [self setNeedsDisplay:YES];
}

/* However its size is set (by Auto Layout too), a split view refits its subviews. */
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (!NSEqualSizes([self bounds].size, _laidOutSize) && [[self arrangedSubviews] count])
        [self resizeSubviewsWithOldSize:_laidOutSize];
}

- (void)layout
{
    [super layout];
    /* (after the engine's pass, which may still hold the subviews' earlier frames) */
    if ([[self arrangedSubviews] count])
        [self resizeSubviewsWithOldSize:_laidOutSize];
}

- (BOOL)isSubviewCollapsed:(NSView *)subview
{
    return [subview isHidden];
}

- (CGFloat)minPossiblePositionOfDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i >= [views count])
        return 0;
    return start_of(self, [views[(NSUInteger)i] frame]) - (i > 0 ? 0 : 0);
}

- (CGFloat)maxPossiblePositionOfDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i + 1 >= [views count])
        return 0;
    NSView *next = views[(NSUInteger)i + 1];
    return start_of(self, [next frame]) + length_of(self, [next frame]) - [self dividerThickness];
}

/* Move a divider: the views on either side give and take, within their neighbours. */
- (void)setPosition:(CGFloat)position ofDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i + 1 >= [views count])
        return;
    CGFloat lo = [self minPossiblePositionOfDividerAtIndex:i], hi = [self maxPossiblePositionOfDividerAtIndex:i];
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainSplitPosition:ofSubviewAt:)])
        position = [_delegate splitView:self constrainSplitPosition:position ofSubviewAt:i];
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainMinCoordinate:ofSubviewAt:)])
        lo = MAX(lo, [_delegate splitView:self constrainMinCoordinate:lo ofSubviewAt:i]);
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainMaxCoordinate:ofSubviewAt:)])
        hi = MIN(hi, [_delegate splitView:self constrainMaxCoordinate:hi ofSubviewAt:i]);
    position = MAX(lo, MIN(hi, position));
    NSView *a = views[(NSUInteger)i], *b = views[(NSUInteger)i + 1];
    CGFloat aStart = start_of(self, [a frame]);
    CGFloat bEnd = start_of(self, [b frame]) + length_of(self, [b frame]);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewWillResizeSubviewsNotification object:self];
    [a setFrame:along(self, aStart, position - aStart)];
    CGFloat bStart = position + [self dividerThickness];
    [b setFrame:along(self, bStart, MAX(0, bEnd - bStart))];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:self];
    [self setNeedsDisplay:YES];
}

- (NSLayoutPriority)holdingPriorityForSubviewAtIndex:(NSInteger)i
{
    NSNumber *p = _holding[@(i)];
    return p ? [p floatValue] : NSLayoutPriorityDefaultLow;
}

- (void)setHoldingPriority:(NSLayoutPriority)priority forSubviewAtIndex:(NSInteger)i
{
    _holding[@(i)] = @(priority);
}

- (NSRect)_finchDividerRect:(NSUInteger)i
{
    NSView *v = [self arrangedSubviews][i];
    CGFloat end = start_of(self, [v frame]) + length_of(self, [v frame]);
    return along(self, end, [self dividerThickness]);
}

- (void)drawDividerInRect:(NSRect)rect
{
    [[self dividerColor] setFill];
    if (_style == NSSplitViewDividerStyleThin) {
        NSRectFill(rect);
        return;
    }
    /* Finch's divider: a hairline centred in the gap */
    NSRect line = _vertical ? NSMakeRect(NSMidX(rect) - 0.5, NSMinY(rect), 1, rect.size.height)
                            : NSMakeRect(NSMinX(rect), NSMidY(rect) - 0.5, rect.size.width, 1);
    NSRectFill(line);
}

- (void)drawRect:(NSRect)dirty
{
    NSArray *views = [self arrangedSubviews];
    for (NSUInteger i = 0; i + 1 < [views count]; i++) {
        NSRect r = [self _finchDividerRect:i];
        if (NSIntersectsRect(r, dirty))
            [self drawDividerInRect:r];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSArray *views = [self arrangedSubviews];
    _dragging = -1;
    for (NSUInteger i = 0; i + 1 < [views count]; i++)
        if (NSMouseInRect(p, NSInsetRect([self _finchDividerRect:i], _vertical ? -2 : 0, _vertical ? 0 : -2), YES))
            _dragging = (NSInteger)i;
    if (_dragging < 0) {
        [super mouseDown:event];
        return;
    }
    CGFloat offset = (_vertical ? p.x : p.y) - start_of(self, [self _finchDividerRect:(NSUInteger)_dragging]);
    NSEvent *e;
    while ((e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp])) {
        NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
        [self setPosition:(_vertical ? q.x : q.y) - offset ofDividerAtIndex:_dragging];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
    _dragging = -1;
}

@end

#pragma mark - NSSplitViewItem and NSSplitViewController

@interface NSSplitViewController (FinchItems)
- (void)_finchItem:(NSSplitViewItem *)item replacedViewController:(NSViewController *)old;
@end

@implementation NSSplitViewItem {
    NSViewController *_viewController;
    NSSplitViewController *_owner; /* not retained */
    BOOL _collapsed, _canCollapse;
    NSSplitViewItemBehavior _behavior;
    NSLayoutPriority _holding;
    CGFloat _minimumThickness, _maximumThickness, _preferredFraction;
}

+ (instancetype)splitViewItemWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [[[self alloc] init] autorelease];
    item->_viewController = [viewController retain];
    item->_holding = NSLayoutPriorityDefaultLow;
    item->_minimumThickness = NSSplitViewItemUnspecifiedDimension;
    item->_maximumThickness = NSSplitViewItemUnspecifiedDimension;
    item->_preferredFraction = NSSplitViewItemUnspecifiedDimension;
    return item;
}

+ (instancetype)sidebarWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorSidebar;
    item->_canCollapse = YES;
    item->_holding = 260;
    return item;
}

+ (instancetype)contentListWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorContentList;
    item->_holding = 260; /* a content list keeps its width, as a sidebar does */
    return item;
}

+ (instancetype)inspectorWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorInspector;
    item->_canCollapse = YES;
    return item;
}

- (void)dealloc
{
    [_viewController release];
    [super dealloc];
}

- (NSViewController *)viewController { return _viewController; }
/* A new view controller takes its predecessor's place in the split view, as Apple's does. */
- (void)setViewController:(NSViewController *)c
{
    if (c == _viewController)
        return;
    NSViewController *old = [_viewController autorelease];
    _viewController = [c retain];
    [_owner _finchItem:self replacedViewController:old];
}

- (void)_finchSetOwner:(NSSplitViewController *)owner { _owner = owner; }
- (NSSplitViewItemBehavior)behavior { return _behavior; }
- (BOOL)isCollapsed { return _collapsed; }
- (void)setCollapsed:(BOOL)flag
{
    _collapsed = flag;
    [[_viewController view] setHidden:flag];
}
- (BOOL)canCollapse { return _canCollapse; }
- (void)setCanCollapse:(BOOL)flag { _canCollapse = flag; }
- (NSLayoutPriority)holdingPriority { return _holding; }
- (void)setHoldingPriority:(NSLayoutPriority)p { _holding = p; }
- (CGFloat)minimumThickness { return _minimumThickness; }
- (void)setMinimumThickness:(CGFloat)v { _minimumThickness = v; }
- (CGFloat)maximumThickness { return _maximumThickness; }
- (void)setMaximumThickness:(CGFloat)v { _maximumThickness = v; }
- (CGFloat)preferredThicknessFraction { return _preferredFraction; }
- (void)setPreferredThicknessFraction:(CGFloat)v { _preferredFraction = v; }

/* From a nib or storyboard: Apple's keys, each present only when not the behavior's default. */
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSplitViewItemBehavior behavior = [coder decodeIntegerForKey:@"NSSplitViewItemBehavior"];
    NSViewController *vc = [coder decodeObjectForKey:@"NSSplitViewItemViewController"];
    NSSplitViewItem *made = behavior == NSSplitViewItemBehaviorSidebar ? [NSSplitViewItem sidebarWithViewController:vc]
                            : behavior == NSSplitViewItemBehaviorContentList
                                ? [NSSplitViewItem contentListWithViewController:vc]
                            : behavior == NSSplitViewItemBehaviorInspector ? [NSSplitViewItem inspectorWithViewController:vc]
                                                                           : [NSSplitViewItem splitViewItemWithViewController:vc];
    [self release];
    self = [made retain];
#define DECODE(key, ivar, how) \
    if ([coder containsValueForKey:@"NSSplitViewItem" key]) \
        ivar = [coder how:@"NSSplitViewItem" key];
    DECODE("HoldingCollapsed", _collapsed, decodeBoolForKey)
    DECODE("CanCollapseFromDrag", _canCollapse, decodeBoolForKey)
    DECODE("HoldingPriority", _holding, decodeFloatForKey)
    DECODE("MinimumThickness", _minimumThickness, decodeDoubleForKey)
    DECODE("MaximumThickness", _maximumThickness, decodeDoubleForKey)
    DECODE("PreferredThicknessFraction", _preferredFraction, decodeDoubleForKey)
#undef DECODE
    return self;
}

@end

@implementation NSSplitViewController {
    NSSplitView *_splitView;
    NSMutableArray<NSSplitViewItem *> *_items;
    CGFloat _minimumThicknessForInlineSidebars;
}

- (instancetype)initWithNibName:(NSNibName)name bundle:(NSBundle *)bundle
{
    self = [super initWithNibName:name bundle:bundle];
    if (self)
        _items = [[NSMutableArray alloc] init];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _items = [[NSMutableArray alloc] initWithArray:[coder decodeObjectForKey:@"NSSplitViewItems"] ?: @[]];
        NSSplitView *sv = [coder decodeObjectForKey:@"NSSplitView"];
        if (sv)
            [self setSplitView:sv];
    }
    return self;
}

- (void)dealloc
{
    [_splitView release];
    [_items release];
    [super dealloc];
}

- (NSSplitView *)splitView
{
    if (!_splitView) {
        NSSplitView *sv = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        [sv setVertical:YES];
        [sv setDividerStyle:NSSplitViewDividerStyleThin];
        [self setSplitView:sv];
        [sv release];
    }
    return _splitView;
}

- (void)setSplitView:(NSSplitView *)sv
{
    [_splitView autorelease];
    _splitView = [sv retain];
    [sv setDelegate:self];
}

/* The split view holds each subview as its item asks. */
- (void)_finchApplyHoldingPriorities
{
    NSUInteger i = 0;
    for (NSSplitViewItem *item in _items)
        [_splitView setHoldingPriority:[item holdingPriority] forSubviewAtIndex:(NSInteger)i++];
}

- (void)loadView
{
    NSSplitView *sv = [self splitView];
    for (NSSplitViewItem *item in _items)
        [sv addArrangedSubview:[[item viewController] view]];
    [self setView:sv];
    [self _finchApplyHoldingPriorities];
    [sv resizeSubviewsWithOldSize:[sv bounds].size];
}

- (void)viewDidLoad {}

- (NSArray<NSSplitViewItem *> *)splitViewItems { return [[_items copy] autorelease]; }

- (void)setSplitViewItems:(NSArray<NSSplitViewItem *> *)items
{
    for (NSSplitViewItem *i in [self splitViewItems])
        [self removeSplitViewItem:i];
    for (NSSplitViewItem *i in items)
        [self addSplitViewItem:i];
}

- (void)addSplitViewItem:(NSSplitViewItem *)item
{
    [self insertSplitViewItem:item atIndex:(NSInteger)[_items count]];
}

- (void)insertSplitViewItem:(NSSplitViewItem *)item atIndex:(NSInteger)index
{
    [_items insertObject:item atIndex:(NSUInteger)index];
    [item _finchSetOwner:self];
    [self addChildViewController:[item viewController]];
    if ([self isViewLoaded]) {
        [_splitView insertArrangedSubview:[[item viewController] view] atIndex:index];
        [self _finchApplyHoldingPriorities];
        [_splitView resizeSubviewsWithOldSize:[_splitView bounds].size];
    }
}

- (void)removeSplitViewItem:(NSSplitViewItem *)item
{
    [[item retain] autorelease];
    if ([self isViewLoaded])
        [[[item viewController] view] removeFromSuperview];
    [item _finchSetOwner:nil];
    [_items removeObjectIdenticalTo:item];
    if ([[item viewController] parentViewController] == self)
        [[item viewController] removeFromParentViewController];
    if ([self isViewLoaded])
        [_splitView resizeSubviewsWithOldSize:[_splitView bounds].size];
}

/* As Apple's: a child view controller added to a split view controller becomes a split
   view item (with the default behavior), and removing the child removes its item. */
- (void)insertChildViewController:(NSViewController *)child atIndex:(NSInteger)index
{
    if ([self splitViewItemForViewController:child]) {
        [super insertChildViewController:child atIndex:index];
        return;
    }
    [self insertSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:child]
                      atIndex:MAX(0, MIN(index, (NSInteger)[_items count]))];
}

- (void)removeChildViewControllerAtIndex:(NSInteger)index
{
    NSViewController *child = [self childViewControllers][(NSUInteger)index];
    NSSplitViewItem *item = [self splitViewItemForViewController:child];
    [super removeChildViewControllerAtIndex:index];
    if (item)
        [self removeSplitViewItem:item];
}

- (void)_finchItem:(NSSplitViewItem *)item replacedViewController:(NSViewController *)old
{
    [old removeFromParentViewController];
    if ([item viewController])
        [self addChildViewController:[item viewController]];
    if (![self isViewLoaded])
        return;
    NSView *oldView = [old isViewLoaded] ? [old view] : nil;
    NSUInteger index = [_items indexOfObjectIdenticalTo:item];
    NSRect frame = oldView ? [oldView frame] : NSZeroRect;
    [oldView removeFromSuperview];
    NSView *v = [[item viewController] view];
    if (v) {
        if (oldView)
            [v setFrame:frame];
        [_splitView insertArrangedSubview:v atIndex:(NSInteger)MIN(index, [[_splitView arrangedSubviews] count])];
        [_splitView resizeSubviewsWithOldSize:[_splitView bounds].size];
    }
}

- (NSSplitViewItem *)splitViewItemForViewController:(NSViewController *)viewController
{
    for (NSSplitViewItem *i in _items)
        if ([i viewController] == viewController)
            return i;
    return nil;
}

- (CGFloat)minimumThicknessForInlineSidebars { return _minimumThicknessForInlineSidebars; }
- (void)setMinimumThicknessForInlineSidebars:(CGFloat)v { _minimumThicknessForInlineSidebars = v; }

- (IBAction)toggleSidebar:(id)sender
{
    for (NSSplitViewItem *i in _items)
        if ([i behavior] == NSSplitViewItemBehaviorSidebar) {
            [i setCollapsed:![i isCollapsed]];
            [_splitView adjustSubviews];
            return;
        }
}

- (IBAction)toggleInspector:(id)sender
{
    for (NSSplitViewItem *i in _items)
        if ([i behavior] == NSSplitViewItemBehaviorInspector) {
            [i setCollapsed:![i isCollapsed]];
            [_splitView adjustSubviews];
            return;
        }
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview
{
    for (NSSplitViewItem *i in _items)
        if ([[i viewController] view] == subview)
            return [i canCollapse];
    return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
    return NO;
}

- (NSRect)splitView:(NSSplitView *)splitView effectiveRect:(NSRect)proposedEffectiveRect
       forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
    return proposedEffectiveRect;
}

- (NSRect)splitView:(NSSplitView *)splitView additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
    return NSZeroRect;
}

@end

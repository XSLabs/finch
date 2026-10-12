/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSScrubber, the Touch Bar's scrolling list, with its layouts, attributes, selection
 * styles and item views. Finch has no Touch Bar, but apps make scrubbers anyway: they
 * keep their data, ask their data source for items, lay them out in a row (flow or
 * proportional) and report selection to their delegate, as Apple's do.
 */
#import "AppKit_Finch.h"

/* --- layout attributes and layouts --- */

@implementation NSScrubberLayoutAttributes {
    NSInteger _index;
    NSRect _frame;
    CGFloat _alpha;
}

+ (instancetype)layoutAttributesForItemAtIndex:(NSInteger)index
{
    NSScrubberLayoutAttributes *a = [[[self alloc] init] autorelease];
    a->_index = index;
    return a;
}

- (instancetype)init
{
    if ((self = [super init]))
        _alpha = 1;
    return self;
}

- (NSInteger)itemIndex { return _index; }
- (void)setItemIndex:(NSInteger)i { _index = i; }
- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)f { _frame = f; }
- (CGFloat)alpha { return _alpha; }
- (void)setAlpha:(CGFloat)a { _alpha = a; }

- (id)copyWithZone:(NSZone *)zone
{
    NSScrubberLayoutAttributes *c = [[[self class] allocWithZone:zone] init];
    c->_index = _index;
    c->_frame = _frame;
    c->_alpha = _alpha;
    return c;
}

@end

@interface NSScrubberLayout ()
- (void)_finchSetScrubber:(NSScrubber *)scrubber;
@end

@implementation NSScrubberLayout {
    NSScrubber *_scrubber; /* (weak) */
}

+ (Class)layoutAttributesClass { return [NSScrubberLayoutAttributes class]; }
- (instancetype)init { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (NSScrubber *)scrubber { return _scrubber; }
- (void)_finchSetScrubber:(NSScrubber *)scrubber { _scrubber = scrubber; }
- (NSRect)visibleRect { return _scrubber ? _scrubber.bounds : NSZeroRect; }
- (void)invalidateLayout {}
- (void)prepareLayout {}
- (NSSize)scrubberContentSize { return NSZeroSize; }
- (NSScrubberLayoutAttributes *)layoutAttributesForItemAtIndex:(NSInteger)index { return nil; }

- (NSSet<NSScrubberLayoutAttributes *> *)layoutAttributesForItemsInRect:(NSRect)rect
{
    NSMutableSet *set = [NSMutableSet set];
    for (NSInteger i = 0; i < _scrubber.numberOfItems; i++) {
        NSScrubberLayoutAttributes *a = [self layoutAttributesForItemAtIndex:i];
        if (a && NSIntersectsRect(a.frame, rect))
            [set addObject:a];
    }
    return set;
}

- (BOOL)shouldInvalidateLayoutForSelectionChange { return NO; }
- (BOOL)shouldInvalidateLayoutForHighlightChange { return NO; }
- (BOOL)shouldInvalidateLayoutForChangeFromVisibleRect:(NSRect)from toVisibleRect:(NSRect)to { return NO; }
- (BOOL)automaticallyMirrorsInRightToLeftLayout { return YES; }

@end

@implementation NSScrubberFlowLayout {
    CGFloat _spacing;
    NSSize _itemSize;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _itemSize = NSMakeSize(50, 30);
    }
    return self;
}

- (CGFloat)itemSpacing { return _spacing; }
- (void)setItemSpacing:(CGFloat)s { _spacing = s; }
- (NSSize)itemSize { return _itemSize; }
- (void)setItemSize:(NSSize)s { _itemSize = s; }
- (void)invalidateLayoutForItemsAtIndexes:(NSIndexSet *)indexes {}

- (NSSize)_sizeOf:(NSInteger)i
{
    id d = self.scrubber.delegate;
    if ([d respondsToSelector:@selector(scrubber:layout:sizeForItemAtIndex:)])
        return [(id<NSScrubberFlowLayoutDelegate>)d scrubber:self.scrubber layout:self sizeForItemAtIndex:i];
    return _itemSize;
}

- (NSScrubberLayoutAttributes *)layoutAttributesForItemAtIndex:(NSInteger)index
{
    if (index < 0 || index >= self.scrubber.numberOfItems)
        return nil;
    CGFloat x = 0;
    for (NSInteger i = 0; i < index; i++)
        x += [self _sizeOf:i].width + _spacing;
    NSScrubberLayoutAttributes *a = [[[self class] layoutAttributesClass] layoutAttributesForItemAtIndex:index];
    NSSize s = [self _sizeOf:index];
    a.frame = NSMakeRect(x, 0, s.width, s.height);
    return a;
}

- (NSSize)scrubberContentSize
{
    NSInteger n = self.scrubber.numberOfItems;
    CGFloat w = 0, h = 0;
    for (NSInteger i = 0; i < n; i++) {
        NSSize s = [self _sizeOf:i];
        w += s.width + (i ? _spacing : 0);
        h = MAX(h, s.height);
    }
    return NSMakeSize(w, h);
}

@end

@implementation NSScrubberProportionalLayout {
    NSInteger _visible;
}

- (instancetype)init { return [self initWithNumberOfVisibleItems:1]; }

- (instancetype)initWithNumberOfVisibleItems:(NSInteger)numberOfVisibleItems
{
    if ((self = [super init]))
        _visible = numberOfVisibleItems;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithNumberOfVisibleItems:1]; }
- (NSInteger)numberOfVisibleItems { return _visible; }
- (void)setNumberOfVisibleItems:(NSInteger)n { _visible = n; }

- (NSScrubberLayoutAttributes *)layoutAttributesForItemAtIndex:(NSInteger)index
{
    if (index < 0 || index >= self.scrubber.numberOfItems || _visible <= 0)
        return nil;
    NSRect r = self.visibleRect;
    CGFloat w = NSWidth(r) / _visible;
    NSScrubberLayoutAttributes *a = [[[self class] layoutAttributesClass] layoutAttributesForItemAtIndex:index];
    a.frame = NSMakeRect(w * index, 0, w, NSHeight(r));
    return a;
}

- (NSSize)scrubberContentSize
{
    NSRect r = self.visibleRect;
    return _visible > 0 ? NSMakeSize(NSWidth(r) / _visible * self.scrubber.numberOfItems, NSHeight(r)) : NSZeroSize;
}

@end

/* --- views --- */

@implementation NSScrubberArrangedView {
    BOOL _selected, _highlighted;
}

- (BOOL)isSelected { return _selected; }
- (void)setSelected:(BOOL)s { _selected = s; [self setNeedsDisplay:YES]; }
- (BOOL)isHighlighted { return _highlighted; }
- (void)setHighlighted:(BOOL)h { _highlighted = h; [self setNeedsDisplay:YES]; }

- (void)applyLayoutAttributes:(NSScrubberLayoutAttributes *)attributes
{
    self.frame = attributes.frame;
    self.alphaValue = attributes.alpha;
}

@end

@implementation NSScrubberSelectionView
@end

@implementation NSScrubberItemView
@end

@implementation NSScrubberTextItemView {
    NSTextField *_textField;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _textField = [[NSTextField labelWithString:@""] retain];
        _textField.alignment = NSTextAlignmentCenter;
        _textField.frame = self.bounds;
        _textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_textField];
    }
    return self;
}

- (void)dealloc
{
    [_textField release];
    [super dealloc];
}

- (NSTextField *)textField { return _textField; }
- (NSString *)title { return _textField.stringValue; }
- (void)setTitle:(NSString *)title { _textField.stringValue = title ?: @""; }

@end

@implementation NSScrubberImageItemView {
    NSImageView *_imageView;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_imageView];
    }
    return self;
}

- (void)dealloc
{
    [_imageView release];
    [super dealloc];
}

- (NSImageView *)imageView { return _imageView; }
- (NSImage *)image { return _imageView.image; }
- (void)setImage:(NSImage *)image { _imageView.image = image; }
- (NSImageAlignment)imageAlignment { return _imageView.imageAlignment; }
- (void)setImageAlignment:(NSImageAlignment)a { _imageView.imageAlignment = a; }

@end

/* --- selection styles --- */

@implementation NSScrubberSelectionStyle

+ (NSScrubberSelectionStyle *)outlineOverlayStyle
{
    static NSScrubberSelectionStyle *style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      style = [NSScrubberSelectionStyle new];
    });
    return style;
}

+ (NSScrubberSelectionStyle *)roundedBackgroundStyle
{
    static NSScrubberSelectionStyle *style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      style = [NSScrubberSelectionStyle new];
    });
    return style;
}

- (instancetype)init { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (NSScrubberSelectionView *)makeSelectionView { return [[[NSScrubberSelectionView alloc] initWithFrame:NSZeroRect] autorelease]; }

@end

/* --- the scrubber --- */

@implementation NSScrubber {
    id<NSScrubberDataSource> _dataSource; /* (weak) */
    id<NSScrubberDelegate> _delegate;     /* (weak) */
    NSScrubberLayout *_layout;
    NSInteger _selected, _highlighted, _count;
    NSScrubberMode _mode;
    NSScrubberAlignment _alignment;
    BOOL _continuous, _floats, _arrows, _indicators, _counted;
    NSScrubberSelectionStyle *_background, *_overlay;
    NSColor *_backgroundColor;
    NSView *_backgroundView;
    NSMutableDictionary *_classes, *_nibs;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        _selected = _highlighted = -1;
        self.scrubberLayout = [[NSScrubberFlowLayout new] autorelease];
        _classes = [NSMutableDictionary new];
        _nibs = [NSMutableDictionary new];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithFrame:NSZeroRect];
}

- (void)dealloc
{
    [_layout release];
    [_background release];
    [_overlay release];
    [_backgroundColor release];
    [_backgroundView release];
    [_classes release];
    [_nibs release];
    [super dealloc];
}

- (id<NSScrubberDataSource>)dataSource { return _dataSource; }
- (void)setDataSource:(id<NSScrubberDataSource>)d { _dataSource = d; _counted = NO; }
- (id<NSScrubberDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSScrubberDelegate>)d { _delegate = d; }
- (NSScrubberLayout *)scrubberLayout { return _layout; }

- (void)setScrubberLayout:(NSScrubberLayout *)layout
{
    [_layout _finchSetScrubber:nil];
    [_layout autorelease];
    _layout = [layout retain];
    [_layout _finchSetScrubber:self];
}

- (NSInteger)numberOfItems
{
    if (!_counted) {
        _count = [_dataSource respondsToSelector:@selector(numberOfItemsForScrubber:)] ? [_dataSource numberOfItemsForScrubber:self] : 0;
        _counted = YES;
    }
    return _count;
}

- (NSInteger)highlightedIndex { return _highlighted; }
- (NSInteger)selectedIndex { return _selected; }

- (void)setSelectedIndex:(NSInteger)index
{
    _selected = index >= 0 && index < self.numberOfItems ? index : -1;
}

- (NSScrubberMode)mode { return _mode; }
- (void)setMode:(NSScrubberMode)m { _mode = m; }
- (NSScrubberAlignment)itemAlignment { return _alignment; }
- (void)setItemAlignment:(NSScrubberAlignment)a { _alignment = a; }
- (BOOL)isContinuous { return _continuous; }
- (void)setContinuous:(BOOL)c { _continuous = c; }
- (BOOL)floatsSelectionViews { return _floats; }
- (void)setFloatsSelectionViews:(BOOL)f { _floats = f; }
- (NSScrubberSelectionStyle *)selectionBackgroundStyle { return _background; }
- (void)setSelectionBackgroundStyle:(NSScrubberSelectionStyle *)s { [_background autorelease]; _background = [s retain]; }
- (NSScrubberSelectionStyle *)selectionOverlayStyle { return _overlay; }
- (void)setSelectionOverlayStyle:(NSScrubberSelectionStyle *)s { [_overlay autorelease]; _overlay = [s retain]; }
- (BOOL)showsArrowButtons { return _arrows; }
- (void)setShowsArrowButtons:(BOOL)s { _arrows = s; }
- (BOOL)showsAdditionalContentIndicators { return _indicators; }
- (void)setShowsAdditionalContentIndicators:(BOOL)s { _indicators = s; }
- (NSColor *)backgroundColor { return _backgroundColor; }
- (void)setBackgroundColor:(NSColor *)c { [_backgroundColor autorelease]; _backgroundColor = [c copy]; }
- (NSView *)backgroundView { return _backgroundView; }
- (void)setBackgroundView:(NSView *)v { [_backgroundView autorelease]; _backgroundView = [v retain]; }

- (void)reloadData
{
    _counted = NO;
    [_layout invalidateLayout];
    [self setNeedsDisplay:YES];
}

- (void)performSequentialBatchUpdates:(void (NS_NOESCAPE ^)(void))updateBlock
{
    updateBlock();
    [self reloadData];
}

- (void)insertItemsAtIndexes:(NSIndexSet *)indexes { [self reloadData]; }
- (void)removeItemsAtIndexes:(NSIndexSet *)indexes { [self reloadData]; }
- (void)reloadItemsAtIndexes:(NSIndexSet *)indexes { [self reloadData]; }
- (void)moveItemAtIndex:(NSInteger)oldIndex toIndex:(NSInteger)newIndex { [self reloadData]; }
- (void)scrollItemAtIndex:(NSInteger)index toAlignment:(NSScrubberAlignment)alignment {}

- (NSScrubberItemView *)itemViewForItemAtIndex:(NSInteger)index
{
    if (index < 0 || index >= self.numberOfItems || ![_dataSource respondsToSelector:@selector(scrubber:viewForItemAtIndex:)])
        return nil;
    NSScrubberItemView *v = [_dataSource scrubber:self viewForItemAtIndex:index];
    NSScrubberLayoutAttributes *a = [_layout layoutAttributesForItemAtIndex:index];
    if (v && a)
        [v applyLayoutAttributes:a];
    v.selected = index == _selected;
    return v;
}

- (void)registerClass:(Class)itemViewClass forItemIdentifier:(NSUserInterfaceItemIdentifier)itemIdentifier
{
    if (itemViewClass)
        _classes[itemIdentifier] = itemViewClass;
    else
        [_classes removeObjectForKey:itemIdentifier];
}

- (void)registerNib:(NSNib *)nib forItemIdentifier:(NSUserInterfaceItemIdentifier)itemIdentifier
{
    if (nib)
        _nibs[itemIdentifier] = nib;
    else
        [_nibs removeObjectForKey:itemIdentifier];
}

- (NSScrubberItemView *)makeItemWithIdentifier:(NSUserInterfaceItemIdentifier)itemIdentifier owner:(id)owner
{
    NSNib *nib = _nibs[itemIdentifier];
    if (nib) {
        NSArray *objects = nil;
        [nib instantiateWithOwner:owner topLevelObjects:&objects];
        for (id o in objects)
            if ([o isKindOfClass:[NSScrubberItemView class]])
                return o;
        return nil;
    }
    Class cls = _classes[itemIdentifier];
    if (!cls)
        return nil;
    NSScrubberItemView *v = [[[cls alloc] initWithFrame:NSZeroRect] autorelease];
    v.identifier = itemIdentifier;
    return v;
}

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCollectionViewCompositionalLayout and the descriptions it's built from, Finch's.
 *
 * A layout is a section (or a section for each index, from a provider) of groups of
 * items. Sizes are absolute, estimated (taken as absolute: items don't size themselves
 * yet) or fractions of the enclosing container: an item's of its group, a group's or a
 * boundary item's of the section's content (the collection view's size less the
 * section's insets). A group of subitems repeats them while they fit along its axis; a
 * group of a counted subitem divides its length among that many. Fixed spacing goes
 * between neighbours; flexible spacing spreads the room left over among the gaps of as
 * many items as the group could hold. Sections stack along the scroll direction: each
 * header before the section's leading inset, its groups spaced by the section's
 * inter-group spacing, each footer after its trailing inset; sections are spaced by the
 * configuration. Frames are rounded to half points, as Apple's are on a 2x screen.
 * Orthogonally scrolling sections lay their groups along the other axis. Pinned
 * headers, items' anchored supplementary items and custom groups' item providers are
 * kept but not laid out yet.
 */
#import "AppKit_Finch.h"
#import <objc/message.h>

/* (these classes' -init is unavailable to apps; the layout makes them through it) */
#define MAKE(cls) ((cls *)((id(*)(id, SEL))objc_msgSend)([cls alloc], @selector(init)))
#pragma clang diagnostic ignored "-Wnonnull"

@interface NSCollectionView (FinchLayout)
- (NSSize)_finchLayoutSize;
@end

/* --- descriptions --- */

typedef NS_ENUM(NSInteger, DimensionKind) { DimFractionalWidth, DimFractionalHeight, DimAbsolute, DimEstimated };

@implementation NSCollectionLayoutDimension {
@public
    DimensionKind _kind;
    CGFloat _value;
}

static NSCollectionLayoutDimension *
dimension(DimensionKind kind, CGFloat value)
{
    NSCollectionLayoutDimension *d = [MAKE(NSCollectionLayoutDimension) autorelease];
    d->_kind = kind;
    d->_value = value;
    return d;
}

+ (instancetype)fractionalWidthDimension:(CGFloat)f { return dimension(DimFractionalWidth, f); }
+ (instancetype)fractionalHeightDimension:(CGFloat)f { return dimension(DimFractionalHeight, f); }
+ (instancetype)absoluteDimension:(CGFloat)a { return dimension(DimAbsolute, a); }
+ (instancetype)estimatedDimension:(CGFloat)e { return dimension(DimEstimated, e); }
- (BOOL)isFractionalWidth { return _kind == DimFractionalWidth; }
- (BOOL)isFractionalHeight { return _kind == DimFractionalHeight; }
- (BOOL)isAbsolute { return _kind == DimAbsolute; }
- (BOOL)isEstimated { return _kind == DimEstimated; }
- (CGFloat)dimension { return _value; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* The length it stands for in a container of that size. */
- (CGFloat)_finchResolveIn:(NSSize)container
{
    switch (_kind) {
    case DimFractionalWidth:
        return _value * container.width;
    case DimFractionalHeight:
        return _value * container.height;
    default:
        return _value;
    }
}

@end

@implementation NSCollectionLayoutSize {
    NSCollectionLayoutDimension *_width, *_height;
}

+ (instancetype)sizeWithWidthDimension:(NSCollectionLayoutDimension *)width heightDimension:(NSCollectionLayoutDimension *)height
{
    NSCollectionLayoutSize *s = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    s->_width = [width retain];
    s->_height = [height retain];
    return s;
}

- (void)dealloc
{
    [_width release];
    [_height release];
    [super dealloc];
}

- (NSCollectionLayoutDimension *)widthDimension { return _width; }
- (NSCollectionLayoutDimension *)heightDimension { return _height; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (NSSize)_finchResolveIn:(NSSize)container
{
    return NSMakeSize([_width _finchResolveIn:container], [_height _finchResolveIn:container]);
}

@end

@implementation NSCollectionLayoutSpacing {
    CGFloat _spacing;
    BOOL _flexible;
}

+ (instancetype)flexibleSpacing:(CGFloat)flexibleSpacing
{
    NSCollectionLayoutSpacing *s = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    s->_spacing = flexibleSpacing;
    s->_flexible = YES;
    return s;
}

+ (instancetype)fixedSpacing:(CGFloat)fixedSpacing
{
    NSCollectionLayoutSpacing *s = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    s->_spacing = fixedSpacing;
    return s;
}

- (CGFloat)spacing { return _spacing; }
- (BOOL)isFlexibleSpacing { return _flexible; }
- (BOOL)isFixedSpacing { return !_flexible; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSCollectionLayoutEdgeSpacing {
    NSCollectionLayoutSpacing *_leading, *_top, *_trailing, *_bottom;
}

+ (instancetype)spacingForLeading:(NSCollectionLayoutSpacing *)leading top:(NSCollectionLayoutSpacing *)top
                         trailing:(NSCollectionLayoutSpacing *)trailing bottom:(NSCollectionLayoutSpacing *)bottom
{
    NSCollectionLayoutEdgeSpacing *e = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    e->_leading = [leading retain];
    e->_top = [top retain];
    e->_trailing = [trailing retain];
    e->_bottom = [bottom retain];
    return e;
}

- (void)dealloc
{
    [_leading release];
    [_top release];
    [_trailing release];
    [_bottom release];
    [super dealloc];
}

- (NSCollectionLayoutSpacing *)leading { return _leading; }
- (NSCollectionLayoutSpacing *)top { return _top; }
- (NSCollectionLayoutSpacing *)trailing { return _trailing; }
- (NSCollectionLayoutSpacing *)bottom { return _bottom; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSCollectionLayoutAnchor {
    NSDirectionalRectEdge _edges;
    CGPoint _offset;
    BOOL _fractional, _absolute;
}

+ (instancetype)layoutAnchorWithEdges:(NSDirectionalRectEdge)edges
{
    NSCollectionLayoutAnchor *a = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    a->_edges = edges;
    return a;
}

+ (instancetype)layoutAnchorWithEdges:(NSDirectionalRectEdge)edges absoluteOffset:(NSPoint)absoluteOffset
{
    NSCollectionLayoutAnchor *a = [self layoutAnchorWithEdges:edges];
    a->_offset = absoluteOffset;
    a->_absolute = YES;
    return a;
}

+ (instancetype)layoutAnchorWithEdges:(NSDirectionalRectEdge)edges fractionalOffset:(NSPoint)fractionalOffset
{
    NSCollectionLayoutAnchor *a = [self layoutAnchorWithEdges:edges];
    a->_offset = fractionalOffset;
    a->_fractional = YES;
    return a;
}

- (NSDirectionalRectEdge)edges { return _edges; }
- (NSPoint)offset { return _offset; }
- (BOOL)isAbsoluteOffset { return _absolute; }
- (BOOL)isFractionalOffset { return _fractional; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSCollectionLayoutItem {
@protected
    NSCollectionLayoutSize *_size;
    NSArray *_supplementaries;
    NSDirectionalEdgeInsets _insets;
    NSCollectionLayoutEdgeSpacing *_edgeSpacing;
}

+ (instancetype)itemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize
{
    return [self itemWithLayoutSize:layoutSize supplementaryItems:@[]];
}

+ (instancetype)itemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize supplementaryItems:(NSArray<NSCollectionLayoutSupplementaryItem *> *)items
{
    NSCollectionLayoutItem *i = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    i->_size = [layoutSize retain];
    i->_supplementaries = [items copy];
    /* (an edge spacing with no spacings, as Apple's has) */
    i->_edgeSpacing = [[NSCollectionLayoutEdgeSpacing spacingForLeading:nil top:nil trailing:nil bottom:nil] retain];
    return i;
}

- (void)dealloc
{
    [_size release];
    [_supplementaries release];
    [_edgeSpacing release];
    [super dealloc];
}

- (NSCollectionLayoutSize *)layoutSize { return _size; }
- (NSArray<NSCollectionLayoutSupplementaryItem *> *)supplementaryItems { return _supplementaries ?: @[]; }
- (NSDirectionalEdgeInsets)contentInsets { return _insets; }
- (void)setContentInsets:(NSDirectionalEdgeInsets)insets { _insets = insets; }
- (NSCollectionLayoutEdgeSpacing *)edgeSpacing { return _edgeSpacing; }
- (void)setEdgeSpacing:(NSCollectionLayoutEdgeSpacing *)e { [_edgeSpacing autorelease]; _edgeSpacing = [e retain]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSCollectionLayoutGroupCustomItem {
    NSRect _frame;
    NSInteger _zIndex;
}

+ (instancetype)customItemWithFrame:(NSRect)frame { return [self customItemWithFrame:frame zIndex:0]; }

+ (instancetype)customItemWithFrame:(NSRect)frame zIndex:(NSInteger)zIndex
{
    NSCollectionLayoutGroupCustomItem *c = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    c->_frame = frame;
    c->_zIndex = zIndex;
    return c;
}

- (NSRect)frame { return _frame; }
- (NSInteger)zIndex { return _zIndex; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

typedef NS_ENUM(NSInteger, GroupAxis) { AxisHorizontal, AxisVertical, AxisCustom };

@implementation NSCollectionLayoutGroup {
    GroupAxis _axis;
    NSArray<NSCollectionLayoutItem *> *_subitems;
    NSInteger _count; /* (0: subitems repeat) */
    NSCollectionLayoutSpacing *_interItemSpacing;
    NSCollectionLayoutGroupCustomItemProvider _provider;
}

static NSCollectionLayoutGroup *
group(GroupAxis axis, NSCollectionLayoutSize *size, NSArray *subitems, NSInteger count)
{
    NSCollectionLayoutGroup *g = [NSCollectionLayoutGroup itemWithLayoutSize:size supplementaryItems:@[]];
    g->_axis = axis;
    g->_subitems = [subitems copy];
    g->_count = count;
    return g;
}

+ (instancetype)horizontalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize subitem:(NSCollectionLayoutItem *)subitem count:(NSInteger)count
{
    return group(AxisHorizontal, layoutSize, @[ subitem ], MAX(count, 1));
}

+ (instancetype)horizontalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize repeatingSubitem:(NSCollectionLayoutItem *)subitem
                                        count:(NSInteger)count
{
    return group(AxisHorizontal, layoutSize, @[ subitem ], MAX(count, 1));
}

+ (instancetype)horizontalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize subitems:(NSArray<NSCollectionLayoutItem *> *)subitems
{
    return group(AxisHorizontal, layoutSize, subitems, 0);
}

+ (instancetype)verticalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize subitem:(NSCollectionLayoutItem *)subitem count:(NSInteger)count
{
    return group(AxisVertical, layoutSize, @[ subitem ], MAX(count, 1));
}

+ (instancetype)verticalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize repeatingSubitem:(NSCollectionLayoutItem *)subitem
                                      count:(NSInteger)count
{
    return group(AxisVertical, layoutSize, @[ subitem ], MAX(count, 1));
}

+ (instancetype)verticalGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize subitems:(NSArray<NSCollectionLayoutItem *> *)subitems
{
    return group(AxisVertical, layoutSize, subitems, 0);
}

+ (instancetype)customGroupWithLayoutSize:(NSCollectionLayoutSize *)layoutSize itemProvider:(NSCollectionLayoutGroupCustomItemProvider)itemProvider
{
    NSCollectionLayoutGroup *g = group(AxisCustom, layoutSize, @[], 0);
    g->_provider = [itemProvider copy];
    return g;
}

- (void)dealloc
{
    [_subitems release];
    [_interItemSpacing release];
    [_provider release];
    [super dealloc];
}

- (NSArray<NSCollectionLayoutItem *> *)subitems { return _subitems; }
- (NSCollectionLayoutSpacing *)interItemSpacing { return _interItemSpacing; }
- (void)setInterItemSpacing:(NSCollectionLayoutSpacing *)s { [_interItemSpacing autorelease]; _interItemSpacing = [s retain]; }
- (void)setSupplementaryItems:(NSArray<NSCollectionLayoutSupplementaryItem *> *)items { [_supplementaries autorelease]; _supplementaries = [items copy]; }
- (NSString *)visualDescription { return [NSString stringWithFormat:@"<%@: %ld subitems>", [self class], (long)_subitems.count]; }

/* Lays the group out in a box, returning item frames (leaves) in order; *capacity is how
   many items the group holds. */
- (NSArray<NSValue *> *)_finchFramesIn:(NSRect)box
{
    NSMutableArray *frames = [NSMutableArray array];
    if (_axis == AxisCustom) {
        id env = nil;
        for (NSCollectionLayoutGroupCustomItem *c in _provider ? _provider(env) : @[]) {
            NSRect f = c.frame;
            f.origin.x += box.origin.x;
            f.origin.y += box.origin.y;
            [frames addObject:[NSValue valueWithRect:f]];
        }
        return frames;
    }
    BOOL horizontal = _axis == AxisHorizontal;
    CGFloat length = horizontal ? NSWidth(box) : NSHeight(box);
    CGFloat spacing = _interItemSpacing ? _interItemSpacing.spacing : 0;
    BOOL flexible = _interItemSpacing.isFlexibleSpacing;

    /* the slots: each subitem's size, in order, as many as fit (or the count) */
    NSMutableArray<NSCollectionLayoutItem *> *slots = [NSMutableArray array];
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    if (_count > 0) {
        NSCollectionLayoutItem *item = _subitems.firstObject;
        CGFloat each = (length - spacing * (_count - 1)) / _count;
        for (NSInteger i = 0; i < _count; i++) {
            NSSize s = [item.layoutSize _finchResolveIn:box.size];
            if (horizontal)
                s.width = each;
            else
                s.height = each;
            [slots addObject:item];
            [sizes addObject:[NSValue valueWithSize:s]];
        }
    } else if (_subitems.count) {
        CGFloat used = 0;
        for (NSUInteger i = 0; i < 100000; i++) {
            NSCollectionLayoutItem *item = _subitems[i % _subitems.count];
            NSSize s = [item.layoutSize _finchResolveIn:box.size];
            CGFloat along = horizontal ? s.width : s.height;
            CGFloat next = used + (slots.count ? spacing : 0) + along;
            if (along <= 0 || next > length + 0.001)
                break;
            used = next;
            [slots addObject:item];
            [sizes addObject:[NSValue valueWithSize:s]];
        }
    }
    CGFloat gap = spacing;
    if (flexible && slots.count > 1) {
        CGFloat total = 0;
        for (NSValue *v in sizes)
            total += horizontal ? v.sizeValue.width : v.sizeValue.height;
        gap = (length - total) / (CGFloat)(slots.count - 1);
    }
    CGFloat at = 0;
    for (NSUInteger i = 0; i < slots.count; i++) {
        NSSize s = sizes[i].sizeValue;
        NSRect slot = horizontal ? NSMakeRect(box.origin.x + at, box.origin.y, s.width, s.height)
                                 : NSMakeRect(box.origin.x, box.origin.y + at, s.width, s.height);
        at += (horizontal ? s.width : s.height) + gap;
        NSCollectionLayoutItem *item = slots[i];
        if ([item isKindOfClass:[NSCollectionLayoutGroup class]]) {
            [frames addObjectsFromArray:[(NSCollectionLayoutGroup *)item _finchFramesIn:slot]];
            continue;
        }
        NSDirectionalEdgeInsets in = item.contentInsets;
        slot.origin.x += in.leading;
        slot.origin.y += in.top;
        slot.size.width -= in.leading + in.trailing;
        slot.size.height -= in.top + in.bottom;
        [frames addObject:[NSValue valueWithRect:slot]];
    }
    return frames;
}

@end

@implementation NSCollectionLayoutSupplementaryItem {
@protected
    NSString *_kind;
    NSInteger _zIndex;
    NSCollectionLayoutAnchor *_containerAnchor, *_itemAnchor;
}

+ (instancetype)supplementaryItemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize elementKind:(NSString *)elementKind
                                containerAnchor:(NSCollectionLayoutAnchor *)containerAnchor
{
    return [self supplementaryItemWithLayoutSize:layoutSize elementKind:elementKind containerAnchor:containerAnchor itemAnchor:nil];
}

+ (instancetype)supplementaryItemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize elementKind:(NSString *)elementKind
                                containerAnchor:(NSCollectionLayoutAnchor *)containerAnchor itemAnchor:(NSCollectionLayoutAnchor *)itemAnchor
{
    NSCollectionLayoutSupplementaryItem *s = [self itemWithLayoutSize:layoutSize supplementaryItems:@[]];
    s->_kind = [elementKind copy];
    s->_containerAnchor = [containerAnchor retain];
    s->_itemAnchor = [itemAnchor retain];
    s->_zIndex = 1;
    return s;
}

- (void)dealloc
{
    [_kind release];
    [_containerAnchor release];
    [_itemAnchor release];
    [super dealloc];
}

- (NSString *)elementKind { return _kind; }
- (NSInteger)zIndex { return _zIndex; }
- (void)setZIndex:(NSInteger)z { _zIndex = z; }
- (NSCollectionLayoutAnchor *)containerAnchor { return _containerAnchor; }
- (NSCollectionLayoutAnchor *)itemAnchor { return _itemAnchor; }

@end

@implementation NSCollectionLayoutBoundarySupplementaryItem {
    NSRectAlignment _alignment;
    NSPoint _offset;
    BOOL _extends, _pins;
}

+ (instancetype)boundarySupplementaryItemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize elementKind:(NSString *)elementKind
                                              alignment:(NSRectAlignment)alignment
{
    return [self boundarySupplementaryItemWithLayoutSize:layoutSize elementKind:elementKind alignment:alignment absoluteOffset:NSZeroPoint];
}

+ (instancetype)boundarySupplementaryItemWithLayoutSize:(NSCollectionLayoutSize *)layoutSize elementKind:(NSString *)elementKind
                                              alignment:(NSRectAlignment)alignment absoluteOffset:(NSPoint)absoluteOffset
{
    NSCollectionLayoutBoundarySupplementaryItem *b = [self supplementaryItemWithLayoutSize:layoutSize elementKind:elementKind containerAnchor:nil];
    b->_alignment = alignment;
    b->_offset = absoluteOffset;
    b->_extends = YES;
    return b;
}

- (NSRectAlignment)alignment { return _alignment; }
- (NSPoint)offset { return _offset; }
- (BOOL)extendsBoundary { return _extends; }
- (void)setExtendsBoundary:(BOOL)e { _extends = e; }
- (BOOL)pinToVisibleBounds { return _pins; }
- (void)setPinToVisibleBounds:(BOOL)p { _pins = p; }

@end

@implementation NSCollectionLayoutDecorationItem {
    NSString *_kind;
    NSInteger _zIndex;
}

- (void)dealloc
{
    [_kind release];
    [super dealloc];
}

+ (instancetype)backgroundDecorationItemWithElementKind:(NSString *)elementKind
{
    NSCollectionLayoutSize *full = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                  heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]];
    NSCollectionLayoutDecorationItem *d = [self itemWithLayoutSize:full supplementaryItems:@[]];
    d->_kind = [elementKind copy];
    d->_zIndex = -1;
    return d;
}

- (NSString *)elementKind { return _kind; }
- (NSInteger)zIndex { return _zIndex; }
- (void)setZIndex:(NSInteger)z { _zIndex = z; }

@end

@implementation NSCollectionLayoutSection {
    NSCollectionLayoutGroup *_group;
    NSDirectionalEdgeInsets _insets;
    CGFloat _interGroupSpacing;
    NSCollectionLayoutSectionOrthogonalScrollingBehavior _orthogonal;
    NSArray *_boundary, *_decorations;
    BOOL _followInsets;
    NSCollectionLayoutSectionVisibleItemsInvalidationHandler _handler;
}

+ (instancetype)sectionWithGroup:(NSCollectionLayoutGroup *)group
{
    NSCollectionLayoutSection *s = [((id(*)(id, SEL))objc_msgSend)([self alloc], @selector(init)) autorelease];
    s->_group = [group retain];
    s->_followInsets = YES;
    return s;
}

- (void)dealloc
{
    [_group release];
    [_boundary release];
    [_decorations release];
    [_handler release];
    [super dealloc];
}

- (NSCollectionLayoutGroup *)_finchGroup { return _group; }
- (NSDirectionalEdgeInsets)contentInsets { return _insets; }
- (void)setContentInsets:(NSDirectionalEdgeInsets)i { _insets = i; }
- (CGFloat)interGroupSpacing { return _interGroupSpacing; }
- (void)setInterGroupSpacing:(CGFloat)s { _interGroupSpacing = s; }
- (NSCollectionLayoutSectionOrthogonalScrollingBehavior)orthogonalScrollingBehavior { return _orthogonal; }
- (void)setOrthogonalScrollingBehavior:(NSCollectionLayoutSectionOrthogonalScrollingBehavior)o { _orthogonal = o; }
- (NSArray<NSCollectionLayoutBoundarySupplementaryItem *> *)boundarySupplementaryItems { return _boundary ?: @[]; }
- (void)setBoundarySupplementaryItems:(NSArray *)a { [_boundary autorelease]; _boundary = [a copy]; }
- (NSArray<NSCollectionLayoutDecorationItem *> *)decorationItems { return _decorations ?: @[]; }
- (void)setDecorationItems:(NSArray *)a { [_decorations autorelease]; _decorations = [a copy]; }
- (BOOL)supplementariesFollowContentInsets { return _followInsets; }
- (void)setSupplementariesFollowContentInsets:(BOOL)f { _followInsets = f; }
- (NSCollectionLayoutSectionVisibleItemsInvalidationHandler)visibleItemsInvalidationHandler { return _handler; }
- (void)setVisibleItemsInvalidationHandler:(NSCollectionLayoutSectionVisibleItemsInvalidationHandler)h
{
    [_handler autorelease];
    _handler = [h copy];
}
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation NSCollectionViewCompositionalLayoutConfiguration {
    NSCollectionViewScrollDirection _direction;
    CGFloat _spacing;
    NSArray *_boundary;
}

- (void)dealloc
{
    [_boundary release];
    [super dealloc];
}

- (NSCollectionViewScrollDirection)scrollDirection { return _direction; }
- (void)setScrollDirection:(NSCollectionViewScrollDirection)d { _direction = d; }
- (CGFloat)interSectionSpacing { return _spacing; }
- (void)setInterSectionSpacing:(CGFloat)s { _spacing = s; }
- (NSArray<NSCollectionLayoutBoundarySupplementaryItem *> *)boundarySupplementaryItems { return _boundary ?: @[]; }
- (void)setBoundarySupplementaryItems:(NSArray *)a { [_boundary autorelease]; _boundary = [a copy]; }

- (id)copyWithZone:(NSZone *)zone
{
    NSCollectionViewCompositionalLayoutConfiguration *c = [[[self class] allocWithZone:zone] init];
    c->_direction = _direction;
    c->_spacing = _spacing;
    c->_boundary = [_boundary copy];
    return c;
}

@end

/* --- the environment handed to section providers --- */

@interface FinchLayoutContainer : NSObject <NSCollectionLayoutContainer> {
@public
    NSSize _size;
}
@end

@implementation FinchLayoutContainer
- (NSSize)contentSize { return _size; }
- (NSDirectionalEdgeInsets)contentInsets { return (NSDirectionalEdgeInsets){0, 0, 0, 0}; }
- (NSSize)effectiveContentSize { return _size; }
- (NSDirectionalEdgeInsets)effectiveContentInsets { return (NSDirectionalEdgeInsets){0, 0, 0, 0}; }
@end

@interface FinchLayoutEnvironment : NSObject <NSCollectionLayoutEnvironment> {
@public
    FinchLayoutContainer *_container;
}
@end

@implementation FinchLayoutEnvironment
- (void)dealloc { [_container release]; [super dealloc]; }
- (id<NSCollectionLayoutContainer>)container { return _container; }
@end

/* --- the layout --- */

@implementation NSCollectionViewCompositionalLayout {
    NSCollectionLayoutSection *_section;
    NSCollectionViewCompositionalLayoutSectionProvider _provider;
    NSCollectionViewCompositionalLayoutConfiguration *_configuration;
    NSMutableArray<NSCollectionViewLayoutAttributes *> *_all;
    NSMutableDictionary<NSIndexPath *, NSCollectionViewLayoutAttributes *> *_items;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_supplementaries, *_decorations;
    NSSize _content;
}

- (instancetype)initWithSection:(NSCollectionLayoutSection *)section
{
    return [self initWithSection:section configuration:[[NSCollectionViewCompositionalLayoutConfiguration new] autorelease]];
}

- (instancetype)initWithSection:(NSCollectionLayoutSection *)section configuration:(NSCollectionViewCompositionalLayoutConfiguration *)configuration
{
    if ((self = [super init])) {
        _section = [section retain];
        _configuration = [configuration copy];
    }
    return self;
}

- (instancetype)initWithSectionProvider:(NSCollectionViewCompositionalLayoutSectionProvider)sectionProvider
{
    return [self initWithSectionProvider:sectionProvider configuration:[[NSCollectionViewCompositionalLayoutConfiguration new] autorelease]];
}

- (instancetype)initWithSectionProvider:(NSCollectionViewCompositionalLayoutSectionProvider)sectionProvider
                          configuration:(NSCollectionViewCompositionalLayoutConfiguration *)configuration
{
    if ((self = [super init])) {
        _provider = [sectionProvider copy];
        _configuration = [configuration copy];
    }
    return self;
}

- (void)dealloc
{
    [_section release];
    [_provider release];
    [_configuration release];
    [_all release];
    [_items release];
    [_supplementaries release];
    [_decorations release];
    [super dealloc];
}

- (NSCollectionViewCompositionalLayoutConfiguration *)configuration { return [[_configuration copy] autorelease]; }

- (void)setConfiguration:(NSCollectionViewCompositionalLayoutConfiguration *)configuration
{
    [_configuration autorelease];
    _configuration = [configuration copy];
    [self invalidateLayout];
}

static CGFloat
half(CGFloat v)
{
    return round(v * 2) / 2;
}

static NSRect
rounded(NSRect r)
{
    return NSMakeRect(half(r.origin.x), half(r.origin.y), half(r.size.width), half(r.size.height));
}

- (void)_finchAdd:(NSCollectionViewLayoutAttributes *)a
{
    a.frame = rounded(a.frame);
    [_all addObject:a];
}

- (void)_finchAddSupplementary:(NSString *)kind at:(NSIndexPath *)path frame:(NSRect)frame zIndex:(NSInteger)z decoration:(BOOL)decoration
{
    NSCollectionViewLayoutAttributes *a = decoration
                                              ? [NSCollectionViewLayoutAttributes layoutAttributesForDecorationViewOfKind:kind withIndexPath:path]
                                              : [NSCollectionViewLayoutAttributes layoutAttributesForSupplementaryViewOfKind:kind
                                                                                                                      withIndexPath:path];
    a.frame = frame;
    a.zIndex = z;
    [self _finchAdd:a];
    NSMutableDictionary *byKind = decoration ? _decorations : _supplementaries;
    if (!byKind[kind])
        byKind[kind] = [NSMutableDictionary dictionary];
    byKind[kind][path] = a;
}

- (void)prepareLayout
{
    [super prepareLayout];
    [_all release];
    [_items release];
    [_supplementaries release];
    [_decorations release];
    _all = [NSMutableArray new];
    _items = [NSMutableDictionary new];
    _supplementaries = [NSMutableDictionary new];
    _decorations = [NSMutableDictionary new];
    NSCollectionView *cv = self.collectionView;
    NSSize container = cv ? [cv _finchLayoutSize] : NSZeroSize;
    BOOL vertical = _configuration.scrollDirection == NSCollectionViewScrollDirectionVertical;
    FinchLayoutEnvironment *env = [[FinchLayoutEnvironment new] autorelease];
    env->_container = [FinchLayoutContainer new];
    env->_container->_size = container;
    NSInteger sections = cv ? cv.numberOfSections : 0;
    CGFloat at = 0; /* (along the scroll direction) */
    for (NSInteger s = 0; s < sections; s++) {
        NSCollectionLayoutSection *section = _provider ? _provider(s, env) : _section;
        if (!section)
            continue;
        if (s > 0)
            at += _configuration.interSectionSpacing;
        NSDirectionalEdgeInsets in = section.contentInsets;
        /* the section's content box across, and the container its fractions are of */
        CGFloat crossStart = vertical ? in.leading : in.top;
        CGFloat crossLength = (vertical ? container.width - in.leading - in.trailing : container.height - in.top - in.bottom);
        NSSize sectionContainer = vertical ? NSMakeSize(crossLength, container.height) : NSMakeSize(container.width, crossLength);
        NSIndexPath *sectionPath = [NSIndexPath indexPathForItem:0 inSection:s];
        CGFloat sectionStart = at;
        /* headers (leading boundary items) */
        for (NSCollectionLayoutBoundarySupplementaryItem *b in section.boundarySupplementaryItems) {
            BOOL leading = vertical ? (b.alignment == NSRectAlignmentTop || b.alignment == NSRectAlignmentTopLeading ||
                                          b.alignment == NSRectAlignmentTopTrailing)
                                    : (b.alignment == NSRectAlignmentLeading || b.alignment == NSRectAlignmentTopLeading ||
                                          b.alignment == NSRectAlignmentBottomLeading);
            if (!leading)
                continue;
            NSSize size = [b.layoutSize _finchResolveIn:sectionContainer];
            NSRect f = vertical ? NSMakeRect(crossStart + b.offset.x, at + b.offset.y, size.width, size.height)
                                : NSMakeRect(at + b.offset.x, crossStart + b.offset.y, size.width, size.height);
            [self _finchAddSupplementary:b.elementKind at:sectionPath frame:f zIndex:b.zIndex decoration:NO];
            at += vertical ? size.height : size.width;
        }
        at += vertical ? in.top : in.leading;
        CGFloat contentStart = at;
        NSCollectionLayoutGroup *g = [section _finchGroup];
        NSInteger count = [cv numberOfItemsInSection:s], item = 0;
        BOOL orthogonal = section.orthogonalScrollingBehavior != NSCollectionLayoutSectionOrthogonalScrollingBehaviorNone;
        CGFloat across = crossStart, extent = 0;
        while (item < count && g) {
            NSSize gs = [g.layoutSize _finchResolveIn:sectionContainer];
            NSRect box;
            if (orthogonal)
                box = vertical ? NSMakeRect(across, at, gs.width, gs.height) : NSMakeRect(at, across, gs.width, gs.height);
            else
                box = vertical ? NSMakeRect(crossStart, at, gs.width, gs.height) : NSMakeRect(at, crossStart, gs.width, gs.height);
            NSArray<NSValue *> *frames = [g _finchFramesIn:box];
            if (!frames.count)
                break;
            for (NSValue *v in frames) {
                if (item >= count)
                    break;
                NSIndexPath *path = [NSIndexPath indexPathForItem:item++ inSection:s];
                NSCollectionViewLayoutAttributes *a = [NSCollectionViewLayoutAttributes layoutAttributesForItemWithIndexPath:path];
                a.frame = v.rectValue;
                [self _finchAdd:a];
                _items[path] = a;
            }
            if (orthogonal) {
                across += (vertical ? gs.width : gs.height) + section.interGroupSpacing;
                extent = MAX(extent, vertical ? gs.height : gs.width);
            } else {
                at += vertical ? gs.height : gs.width;
                if (item < count)
                    at += section.interGroupSpacing;
            }
        }
        if (orthogonal)
            at += extent;
        CGFloat contentEnd = at;
        at += vertical ? in.bottom : in.trailing;
        /* footers (trailing boundary items) */
        for (NSCollectionLayoutBoundarySupplementaryItem *b in section.boundarySupplementaryItems) {
            BOOL trailing = vertical ? (b.alignment == NSRectAlignmentBottom || b.alignment == NSRectAlignmentBottomLeading ||
                                           b.alignment == NSRectAlignmentBottomTrailing)
                                     : (b.alignment == NSRectAlignmentTrailing || b.alignment == NSRectAlignmentTopTrailing ||
                                           b.alignment == NSRectAlignmentBottomTrailing);
            if (!trailing)
                continue;
            NSSize size = [b.layoutSize _finchResolveIn:sectionContainer];
            NSRect f = vertical ? NSMakeRect(crossStart + b.offset.x, at + b.offset.y, size.width, size.height)
                                : NSMakeRect(at + b.offset.x, crossStart + b.offset.y, size.width, size.height);
            [self _finchAddSupplementary:b.elementKind at:sectionPath frame:f zIndex:b.zIndex decoration:NO];
            at += vertical ? size.height : size.width;
        }
        /* backgrounds: the section's content, inset by the decoration's own insets */
        for (NSCollectionLayoutDecorationItem *d in section.decorationItems) {
            NSRect f = vertical ? NSMakeRect(crossStart, contentStart, crossLength, contentEnd - contentStart)
                                : NSMakeRect(contentStart, crossStart, contentEnd - contentStart, crossLength);
            NSDirectionalEdgeInsets di = d.contentInsets;
            f = NSMakeRect(f.origin.x + di.leading, f.origin.y + di.top, f.size.width - di.leading - di.trailing,
                f.size.height - di.top - di.bottom);
            [self _finchAddSupplementary:d.elementKind at:sectionPath frame:f zIndex:d.zIndex decoration:YES];
        }
        (void)sectionStart;
    }
    _content = vertical ? NSMakeSize(container.width, at) : NSMakeSize(at, container.height);
}

- (NSSize)collectionViewContentSize { return _content; }

- (NSArray<NSCollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(NSRect)rect
{
    NSMutableArray *found = [NSMutableArray array];
    for (NSCollectionViewLayoutAttributes *a in _all)
        if (NSIntersectsRect(a.frame, rect) || NSIsEmptyRect(a.frame))
            [found addObject:a];
    return found;
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return _items[indexPath];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)elementKind
                                                                    atIndexPath:(NSIndexPath *)indexPath
{
    return _supplementaries[elementKind][[NSIndexPath indexPathForItem:0 inSection:indexPath.section]];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForDecorationViewOfKind:(NSCollectionViewDecorationElementKind)elementKind
                                                                 atIndexPath:(NSIndexPath *)indexPath
{
    return _decorations[elementKind][[NSIndexPath indexPathForItem:0 inSection:indexPath.section]];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds
{
    NSSize old = self.collectionView ? [self.collectionView _finchLayoutSize] : NSZeroSize;
    return _configuration.scrollDirection == NSCollectionViewScrollDirectionVertical ? newBounds.size.width != old.width
                                                                                     : newBounds.size.height != old.height;
}

@end

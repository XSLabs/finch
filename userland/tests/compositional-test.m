/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCollectionViewCompositionalLayout and its descriptions (dimensions, sizes, items,
 * groups, spacing, sections, boundary supplementary and decoration items): the frames
 * a collection view gets from a few layouts, compared with Apple's.
 */
#import <AppKit/AppKit.h>

@interface Source : NSObject <NSCollectionViewDataSource>
@property NSArray<NSNumber *> *counts;
@end

@implementation Source
- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)cv { return (NSInteger)self.counts.count; }
- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)section { return self.counts[(NSUInteger)section].integerValue; }
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath
{
    return [cv makeItemWithIdentifier:@"item" forIndexPath:indexPath];
}
- (NSView *)collectionView:(NSCollectionView *)cv viewForSupplementaryElementOfKind:(NSCollectionViewSupplementaryElementKind)kind
               atIndexPath:(NSIndexPath *)indexPath
{
    return [cv makeSupplementaryViewOfKind:kind withIdentifier:@"supp" forIndexPath:indexPath];
}
@end

@interface Item : NSCollectionViewItem
@end
@implementation Item
- (void)loadView { self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)]; }
@end

@interface Supp : NSView <NSCollectionViewElement>
@end
@implementation Supp
@end

static void
show(const char *label, NSCollectionViewLayout *layout, NSArray *counts, CGFloat width)
{
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, 600)];
    NSCollectionView *cv = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, width, 600)];
    [cv registerClass:[Item class] forItemWithIdentifier:@"item"];
    for (NSString *kind in @[ @"header", @"footer", @"badge" ])
        [cv registerClass:[Supp class] forSupplementaryViewOfKind:kind withIdentifier:@"supp"];
    Source *src = [Source new];
    src.counts = counts;
    cv.dataSource = src;
    cv.collectionViewLayout = layout;
    scroll.documentView = cv;
    [cv reloadData];
    [layout prepareLayout];
    NSArray *attrs = [layout layoutAttributesForElementsInRect:NSMakeRect(-10000, -10000, 30000, 30000)];
    attrs = [attrs sortedArrayUsingComparator:^NSComparisonResult(NSCollectionViewLayoutAttributes *a, NSCollectionViewLayoutAttributes *b) {
      if (a.representedElementCategory != b.representedElementCategory)
          return a.representedElementCategory < b.representedElementCategory ? NSOrderedAscending : NSOrderedDescending;
      NSComparisonResult r = [(a.representedElementKind ?: @"") compare:(b.representedElementKind ?: @"")];
      return r != NSOrderedSame ? r : [a.indexPath compare:b.indexPath];
    }];
    printf("%s: content %s\n", label, NSStringFromSize(layout.collectionViewContentSize).UTF8String);
    for (NSCollectionViewLayoutAttributes *a in attrs)
        printf("  %ld %s %ld.%ld %s z %ld\n", (long)a.representedElementCategory, (a.representedElementKind ?: @"-").UTF8String,
            (long)a.indexPath.section, (long)a.indexPath.item, NSStringFromRect(a.frame).UTF8String, (long)a.zIndex);
    NSCollectionViewLayoutAttributes *one = [layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
    printf("  item 0.1 directly: %s\n", one ? NSStringFromRect(one.frame).UTF8String : "nil");
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        /* descriptions themselves */
        NSCollectionLayoutDimension *d = [NSCollectionLayoutDimension fractionalWidthDimension:0.5];
        printf("dimension: fw %d fh %d abs %d est %d value %g\n", d.isFractionalWidth, d.isFractionalHeight, d.isAbsolute, d.isEstimated,
            d.dimension);
        NSCollectionLayoutDimension *e = [NSCollectionLayoutDimension estimatedDimension:44];
        printf("estimated: %d %g; absolute %d\n", e.isEstimated, e.dimension, [NSCollectionLayoutDimension absoluteDimension:3].isAbsolute);
        NSCollectionLayoutSpacing *sp = [NSCollectionLayoutSpacing fixedSpacing:8];
        printf("spacing: fixed %d flexible %d %g\n", sp.isFixedSpacing, sp.isFlexibleSpacing, sp.spacing);
        NSCollectionLayoutSize *size = [NSCollectionLayoutSize sizeWithWidthDimension:d heightDimension:e];
        NSCollectionLayoutItem *it = [NSCollectionLayoutItem itemWithLayoutSize:size];
        printf("item: width fw %d insets %g edge %s\n", it.layoutSize.widthDimension.isFractionalWidth, it.contentInsets.top,
            it.edgeSpacing ? "set" : "nil");
        NSCollectionLayoutSection *sec = [NSCollectionLayoutSection sectionWithGroup:[NSCollectionLayoutGroup
                                                                                         horizontalGroupWithLayoutSize:size
                                                                                                              subitems:@[ it ]]];
        printf("section: spacing %g orthogonal %ld supplementaries %lu\n", sec.interGroupSpacing, (long)sec.orthogonalScrollingBehavior,
            (unsigned long)sec.boundarySupplementaryItems.count);
        NSCollectionViewCompositionalLayoutConfiguration *conf = [NSCollectionViewCompositionalLayoutConfiguration new];
        printf("configuration: direction %ld spacing %g\n", (long)conf.scrollDirection, conf.interSectionSpacing);

        /* a list with headers */
        NSCollectionLayoutItem *row = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                              heightDimension:[NSCollectionLayoutDimension absoluteDimension:44]]];
        NSCollectionLayoutGroup *rowGroup = [NSCollectionLayoutGroup
            verticalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:44]]
                               subitems:@[ row ]];
        NSCollectionLayoutSection *list = [NSCollectionLayoutSection sectionWithGroup:rowGroup];
        list.interGroupSpacing = 5;
        list.contentInsets = NSDirectionalEdgeInsetsMake(10, 20, 10, 20);
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem
            boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                                   heightDimension:[NSCollectionLayoutDimension absoluteDimension:30]]
                                        elementKind:@"header"
                                          alignment:NSRectAlignmentTop];
        NSCollectionLayoutBoundarySupplementaryItem *footer = [NSCollectionLayoutBoundarySupplementaryItem
            boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                                   heightDimension:[NSCollectionLayoutDimension absoluteDimension:20]]
                                        elementKind:@"footer"
                                          alignment:NSRectAlignmentBottom];
        printf("header: pins %d extends %d alignment %ld offset %s z %ld\n", header.pinToVisibleBounds, header.extendsBoundary,
            (long)header.alignment, NSStringFromPoint(header.offset).UTF8String, (long)header.zIndex);
        list.boundarySupplementaryItems = @[ header, footer ];
        show("list", [[NSCollectionViewCompositionalLayout alloc] initWithSection:list], @[ @3, @2 ], 400);

        /* a grid */
        NSCollectionLayoutItem *cell = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.25]
                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]];
        cell.contentInsets = NSDirectionalEdgeInsetsMake(2, 2, 2, 2);
        NSCollectionLayoutGroup *gridRow = [NSCollectionLayoutGroup
            horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                         heightDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.25]]
                                 subitems:@[ cell ]];
        show("grid", [[NSCollectionViewCompositionalLayout alloc] initWithSection:[NSCollectionLayoutSection sectionWithGroup:gridRow]], @[ @10 ],
            400);

        /* a counted group with spacing */
        NSCollectionLayoutItem *tile = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]];
        NSCollectionLayoutGroup *three = [NSCollectionLayoutGroup
            horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                         heightDimension:[NSCollectionLayoutDimension absoluteDimension:100]]
                                  subitem:tile
                                    count:3];
        three.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:8];
        NSCollectionLayoutSection *threes = [NSCollectionLayoutSection sectionWithGroup:three];
        threes.interGroupSpacing = 8;
        show("counted", [[NSCollectionViewCompositionalLayout alloc] initWithSection:threes], @[ @7 ], 300);

        /* nested groups: a big item beside two stacked */
        NSCollectionLayoutItem *big = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.6]
                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]];
        NSCollectionLayoutItem *small = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:0.5]]];
        NSCollectionLayoutGroup *stack = [NSCollectionLayoutGroup
            verticalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.4]
                                                                       heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]
                                  subitem:small
                                    count:2];
        NSCollectionLayoutGroup *nest = [NSCollectionLayoutGroup
            horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                         heightDimension:[NSCollectionLayoutDimension absoluteDimension:200]]
                                 subitems:@[ big, stack ]];
        show("nested", [[NSCollectionViewCompositionalLayout alloc] initWithSection:[NSCollectionLayoutSection sectionWithGroup:nest]], @[ @7 ],
            500);

        /* sections from a provider, with configuration spacing */
        NSCollectionViewCompositionalLayoutConfiguration *c2 = [NSCollectionViewCompositionalLayoutConfiguration new];
        c2.interSectionSpacing = 20;
        NSCollectionViewCompositionalLayout *provided = [[NSCollectionViewCompositionalLayout alloc]
            initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> env) {
              printf("  provider: section %ld container %s effective %s\n", (long)section,
                  NSStringFromSize(env.container.contentSize).UTF8String, NSStringFromSize(env.container.effectiveContentSize).UTF8String);
              NSCollectionLayoutItem *i = [NSCollectionLayoutItem
                  itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:section ? 50 : 80]
                                                                    heightDimension:[NSCollectionLayoutDimension absoluteDimension:40]]];
              NSCollectionLayoutGroup *g = [NSCollectionLayoutGroup
                  horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:40]]
                                       subitems:@[ i ]];
              g.interItemSpacing = [NSCollectionLayoutSpacing flexibleSpacing:4];
              return [NSCollectionLayoutSection sectionWithGroup:g];
            }
                      configuration:c2];
        show("provided", provided, @[ @5, @4 ], 300);
        printf("configuration kept: %g\n", provided.configuration.interSectionSpacing);

        /* a horizontally scrolling layout */
        NSCollectionViewCompositionalLayoutConfiguration *h = [NSCollectionViewCompositionalLayoutConfiguration new];
        h.scrollDirection = NSCollectionViewScrollDirectionHorizontal;
        NSCollectionLayoutItem *col = [NSCollectionLayoutItem
            itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:120]
                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:0.5]]];
        NSCollectionLayoutGroup *colGroup = [NSCollectionLayoutGroup
            verticalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:120]
                                                                       heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]
                               subitems:@[ col ]];
        NSCollectionViewCompositionalLayout *horizontal = [[NSCollectionViewCompositionalLayout alloc]
            initWithSection:[NSCollectionLayoutSection sectionWithGroup:colGroup]
              configuration:h];
        show("horizontal", horizontal, @[ @5 ], 300);
    }
    return 0;
}

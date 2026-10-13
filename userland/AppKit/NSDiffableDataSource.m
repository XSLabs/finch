/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSDiffableDataSourceSnapshot and NSCollectionViewDiffableDataSource, the Objective-C
 * diffable data sources (Swift apps have the overlay's, AppKitOverlayModern.swift).
 * A snapshot is its sections in order, each with its items; identifiers are unique
 * across the snapshot. As Apple's: appending an item that's already there moves it to
 * the end; a missing section, a duplicate section, a move onto itself or reloading what
 * isn't there raises NSInternalInconsistencyException with Apple's reasons.
 *
 * The data source answers its collection view from the applied snapshot and reloads
 * the view when a snapshot is applied (without animation).
 */
#import <AppKit/AppKit.h>

static void
inconsistent(NSString *reason)
{
    [NSException raise:NSInternalInconsistencyException format:@"%@", reason];
}

@implementation NSDiffableDataSourceSnapshot {
    NSMutableArray *_sections;     /* section identifiers, in order */
    NSMutableDictionary *_items;   /* section identifier -> NSMutableArray of items */
    NSMutableDictionary *_sectionOf; /* item -> section identifier */
    NSMutableSet *_reloadedItems, *_reloadedSections;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _sections = [NSMutableArray new];
        _items = [NSMutableDictionary new];
        _sectionOf = [NSMutableDictionary new];
        _reloadedItems = [NSMutableSet new];
        _reloadedSections = [NSMutableSet new];
    }
    return self;
}

- (void)dealloc
{
    [_sections release];
    [_items release];
    [_sectionOf release];
    [_reloadedItems release];
    [_reloadedSections release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSDiffableDataSourceSnapshot *c = [[NSDiffableDataSourceSnapshot alloc] init];
    [c->_sections addObjectsFromArray:_sections];
    for (id s in _items)
        c->_items[s] = [[_items[s] mutableCopy] autorelease];
    [c->_sectionOf addEntriesFromDictionary:_sectionOf];
    return c;
}

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[NSDiffableDataSourceSnapshot class]])
        return NO;
    NSDiffableDataSourceSnapshot *s = o;
    return [_sections isEqual:s->_sections] && [_items isEqual:s->_items];
}

- (NSUInteger)hash { return _sections.hash ^ _sectionOf.count; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p: sections %@, %ld items>", self.class, self, _sections, (long)self.numberOfItems];
}

/* ---- reading ---- */

- (NSInteger)numberOfItems { return (NSInteger)_sectionOf.count; }
- (NSInteger)numberOfSections { return (NSInteger)_sections.count; }
- (NSArray *)sectionIdentifiers { return [[_sections copy] autorelease]; }

- (NSArray *)itemIdentifiers
{
    NSMutableArray *a = [NSMutableArray array];
    for (id s in _sections)
        [a addObjectsFromArray:_items[s]];
    return a;
}

- (NSMutableArray *)itemsOf:(id)section
{
    NSMutableArray *a = section ? _items[section] : nil;
    if (!a)
        inconsistent(@"Invalid parameter not satisfying: section != NSNotFound");
    return a;
}

- (NSInteger)numberOfItemsInSection:(id)section
{
    NSMutableArray *a = section ? _items[section] : nil;
    if (!a)
        inconsistent(@"Section identifier was not found. You can verify the section exists by calling the indexOfSectionIdentifier "
                     @"API (which has O(1) performance)");
    return (NSInteger)a.count;
}

- (NSArray *)itemIdentifiersInSectionWithIdentifier:(id)section
{
    NSMutableArray *a = section ? _items[section] : nil;
    if (!a)
        inconsistent(@"Section identifier was not found. You can verify the section exists by calling the indexOfSectionIdentifier "
                     @"API (which has O(1) performance)");
    return [[a copy] autorelease];
}

- (id)sectionIdentifierForSectionContainingItemIdentifier:(id)item { return item ? _sectionOf[item] : nil; }

- (NSInteger)indexOfItemIdentifier:(id)item
{
    id section = item ? _sectionOf[item] : nil;
    if (!section)
        return NSNotFound;
    NSInteger index = 0;
    for (id s in _sections) {
        if ([s isEqual:section])
            return index + (NSInteger)[_items[s] indexOfObject:item];
        index += (NSInteger)[_items[s] count];
    }
    return NSNotFound;
}

- (NSInteger)indexOfSectionIdentifier:(id)section
{
    NSUInteger i = section ? [_sections indexOfObject:section] : NSNotFound;
    return i == NSNotFound ? NSNotFound : (NSInteger)i;
}

/* ---- items ---- */

- (void)removeItem:(id)item
{
    id section = _sectionOf[item];
    if (section) {
        [_items[section] removeObject:item];
        [_sectionOf removeObjectForKey:item];
    }
}

- (void)put:(NSArray *)items inSection:(id)section at:(NSUInteger)index
{
    NSMutableArray *a = [self itemsOf:section];
    for (id item in items) {
        if ([_sectionOf[item] isEqual:section] && [a indexOfObject:item] < index)
            index--;
        [self removeItem:item];
    }
    index = MIN(index, a.count);
    for (id item in items) {
        [a insertObject:item atIndex:index++];
        _sectionOf[item] = section;
    }
}

- (void)appendItemsWithIdentifiers:(NSArray *)items
{
    if (!_sections.count)
        inconsistent(@"There are currently no sections in the data source. Please add a section first.");
    [self appendItemsWithIdentifiers:items intoSectionWithIdentifier:_sections.lastObject];
}

- (void)appendItemsWithIdentifiers:(NSArray *)items intoSectionWithIdentifier:(id)section
{
    NSMutableArray *a = [self itemsOf:section];
    [self put:items inSection:section at:a.count];
}

- (void)insertItemsWithIdentifiers:(NSArray *)items nextTo:(id)anchor after:(BOOL)after
{
    id section = anchor ? _sectionOf[anchor] : nil;
    NSMutableArray *a = [self itemsOf:section];
    if ([items containsObject:anchor])
        inconsistent([NSString stringWithFormat:@"Invalid update: destination for item move is the same as the source [%@]", anchor]);
    NSUInteger i = [a indexOfObject:anchor];
    /* where the anchor ends up once the items have left their places */
    for (id item in items)
        if ([_sectionOf[item] isEqual:section] && [a indexOfObject:item] < i)
            i--;
    for (id item in items)
        [self removeItem:item];
    i += after ? 1 : 0;
    for (id item in items) {
        [a insertObject:item atIndex:i++];
        _sectionOf[item] = section;
    }
}

- (void)insertItemsWithIdentifiers:(NSArray *)items beforeItemWithIdentifier:(id)anchor
{
    [self insertItemsWithIdentifiers:items nextTo:anchor after:NO];
}

- (void)insertItemsWithIdentifiers:(NSArray *)items afterItemWithIdentifier:(id)anchor
{
    [self insertItemsWithIdentifiers:items nextTo:anchor after:YES];
}

- (void)deleteItemsWithIdentifiers:(NSArray *)items
{
    for (id item in items)
        [self removeItem:item];
}

- (void)deleteAllItems
{
    [_sections removeAllObjects];
    [_items removeAllObjects];
    [_sectionOf removeAllObjects];
}

- (void)moveItemWithIdentifier:(id)item beforeItemWithIdentifier:(id)anchor
{
    if ([item isEqual:anchor])
        inconsistent([NSString stringWithFormat:@"Invalid update: destination for item move is the same as the source [%@]", item]);
    [self insertItemsWithIdentifiers:@[ item ] nextTo:anchor after:NO];
}

- (void)moveItemWithIdentifier:(id)item afterItemWithIdentifier:(id)anchor
{
    if ([item isEqual:anchor])
        inconsistent([NSString stringWithFormat:@"Invalid update: destination for item move is the same as the source [%@]", item]);
    [self insertItemsWithIdentifiers:@[ item ] nextTo:anchor after:YES];
}

- (void)reloadItemsWithIdentifiers:(NSArray *)items
{
    for (id item in items)
        if (!_sectionOf[item])
            inconsistent([NSString stringWithFormat:@"Attempted to reload item identifier that does not exist in the snapshot: %@", item]);
    [_reloadedItems addObjectsFromArray:items];
}

/* ---- sections ---- */

- (void)checkNewSections:(NSArray *)sections
{
    for (id s in sections)
        if (_items[s])
            inconsistent([NSString stringWithFormat:@"Diffable data source detected an attempt to insert or append %lu section identifier "
                                                    @"that already exists in the snapshot. Identifiers in a snapshot must be unique. "
                                                    @"Section identifier that already exists: %@",
                                                    (unsigned long)1, s]);
}

- (void)addSections:(NSArray *)sections at:(NSUInteger)index
{
    for (id s in sections) {
        [_sections insertObject:s atIndex:index++];
        _items[s] = [NSMutableArray array];
    }
}

- (void)appendSectionsWithIdentifiers:(NSArray *)sections
{
    [self checkNewSections:sections];
    [self addSections:sections at:_sections.count];
}

- (NSUInteger)indexOfExistingSection:(id)section
{
    NSUInteger i = section ? [_sections indexOfObject:section] : NSNotFound;
    if (i == NSNotFound)
        inconsistent(@"Invalid parameter not satisfying: section != NSNotFound");
    return i;
}

- (void)insertSectionsWithIdentifiers:(NSArray *)sections beforeSectionWithIdentifier:(id)anchor
{
    [self checkNewSections:sections];
    [self addSections:sections at:[self indexOfExistingSection:anchor]];
}

- (void)insertSectionsWithIdentifiers:(NSArray *)sections afterSectionWithIdentifier:(id)anchor
{
    [self checkNewSections:sections];
    [self addSections:sections at:[self indexOfExistingSection:anchor] + 1];
}

- (void)deleteSectionsWithIdentifiers:(NSArray *)sections
{
    for (id s in sections) {
        NSMutableArray *a = _items[s];
        if (!a)
            continue;
        for (id item in a)
            [_sectionOf removeObjectForKey:item];
        [_items removeObjectForKey:s];
        [_sections removeObject:s];
    }
}

- (void)moveSection:(id)section nextTo:(id)anchor after:(BOOL)after
{
    if ([section isEqual:anchor])
        inconsistent([NSString stringWithFormat:@"Invalid update: destination for section move is the same as the source [%@]", section]);
    [self indexOfExistingSection:section];
    [self indexOfExistingSection:anchor];
    [[section retain] autorelease];
    [_sections removeObject:section];
    [_sections insertObject:section atIndex:[_sections indexOfObject:anchor] + (after ? 1 : 0)];
}

- (void)moveSectionWithIdentifier:(id)section beforeSectionWithIdentifier:(id)anchor { [self moveSection:section nextTo:anchor after:NO]; }
- (void)moveSectionWithIdentifier:(id)section afterSectionWithIdentifier:(id)anchor { [self moveSection:section nextTo:anchor after:YES]; }

- (void)reloadSectionsWithIdentifiers:(NSArray *)sections
{
    for (id s in sections)
        [self indexOfExistingSection:s];
    [_reloadedSections addObjectsFromArray:sections];
}

@end

/* ---- NSCollectionViewDiffableDataSource ---- */

@implementation NSCollectionViewDiffableDataSource {
    NSCollectionView *_collectionView; /* weak, as Apple's */
    NSCollectionViewDiffableDataSourceItemProvider _itemProvider;
    NSCollectionViewDiffableDataSourceSupplementaryViewProvider _supplementaryViewProvider;
    NSDiffableDataSourceSnapshot *_snapshot;
}

- (instancetype)initWithCollectionView:(NSCollectionView *)collectionView itemProvider:(NSCollectionViewDiffableDataSourceItemProvider)itemProvider
{
    if ((self = [super init])) {
        _collectionView = collectionView;
        _itemProvider = [itemProvider copy];
        _snapshot = [NSDiffableDataSourceSnapshot new];
        collectionView.dataSource = self;
    }
    return self;
}

- (void)dealloc
{
    [_itemProvider release];
    [_supplementaryViewProvider release];
    [_snapshot release];
    [super dealloc];
}

- (NSCollectionViewDiffableDataSourceSupplementaryViewProvider)supplementaryViewProvider { return _supplementaryViewProvider; }

- (void)setSupplementaryViewProvider:(NSCollectionViewDiffableDataSourceSupplementaryViewProvider)p
{
    [_supplementaryViewProvider autorelease];
    _supplementaryViewProvider = [p copy];
}

- (NSDiffableDataSourceSnapshot *)snapshot { return [[_snapshot copy] autorelease]; }

- (void)applySnapshot:(NSDiffableDataSourceSnapshot *)snapshot animatingDifferences:(BOOL)animatingDifferences
{
    NSDiffableDataSourceSnapshot *s = [snapshot copy];
    [_snapshot release];
    _snapshot = s;
    [_collectionView reloadData];
}

- (id)itemIdentifierForIndexPath:(NSIndexPath *)indexPath
{
    NSArray *sections = _snapshot.sectionIdentifiers;
    if ((NSUInteger)indexPath.section >= sections.count)
        return nil;
    NSArray *items = [_snapshot itemIdentifiersInSectionWithIdentifier:sections[indexPath.section]];
    return (NSUInteger)indexPath.item < items.count ? items[indexPath.item] : nil;
}

- (NSIndexPath *)indexPathForItemIdentifier:(id)identifier
{
    id section = [_snapshot sectionIdentifierForSectionContainingItemIdentifier:identifier];
    if (!section)
        return nil;
    NSInteger s = [_snapshot indexOfSectionIdentifier:section];
    NSInteger i = (NSInteger)[[_snapshot itemIdentifiersInSectionWithIdentifier:section] indexOfObject:identifier];
    return [NSIndexPath indexPathForItem:i inSection:s];
}

- (id)sectionIdentifierForIndex:(NSInteger)index
{
    NSArray *sections = _snapshot.sectionIdentifiers;
    return index >= 0 && (NSUInteger)index < sections.count ? sections[index] : nil;
}

- (NSInteger)indexForSectionIdentifier:(id)section { return [_snapshot indexOfSectionIdentifier:section]; }

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView { return _snapshot.numberOfSections; }

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    id s = [self sectionIdentifierForIndex:section];
    return s ? [_snapshot numberOfItemsInSection:s] : 0;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath
{
    NSCollectionViewItem *item = _itemProvider(collectionView, indexPath, [self itemIdentifierForIndexPath:indexPath]);
    if (!item)
        inconsistent([NSString stringWithFormat:@"NSCollectionViewDiffableDataSource: the item provider returned nil for %@", indexPath]);
    return item;
}

- (NSView *)collectionView:(NSCollectionView *)collectionView viewForSupplementaryElementOfKind:(NSCollectionViewSupplementaryElementKind)kind
               atIndexPath:(NSIndexPath *)indexPath
{
    NSView *v = _supplementaryViewProvider ? _supplementaryViewProvider(collectionView, kind, indexPath) : nil;
    return v ?: [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
}

@end

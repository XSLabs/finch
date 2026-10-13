/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's value classes apps import: diffable data source snapshots (and the
 * collection view data source's lookups), menu item badges, pressure and tint
 * configurations, compression options, scroll edge effect styles, PDF info and panel,
 * Core Image representations and font collections (what's shown for the process, the
 * change notification, matching by family). Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>

#define TRY(x)                                                                                                         \
    @try {                                                                                                             \
        x;                                                                                                             \
    } @catch (NSException *e) {                                                                                        \
        printf("  raised %s: %s\n", e.name.UTF8String, [[e.reason componentsSeparatedByString:@" for update:"][0] UTF8String]); \
    }

static void
show(NSDiffableDataSourceSnapshot *s)
{
    printf("  sections %s items %s (%ld/%ld)\n", [s.sectionIdentifiers componentsJoinedByString:@","].UTF8String,
           [s.itemIdentifiers componentsJoinedByString:@","].UTF8String, (long)s.numberOfSections, (long)s.numberOfItems);
}

static void
snapshots(void)
{
    printf("snapshot:\n");
    NSDiffableDataSourceSnapshot *s = [NSDiffableDataSourceSnapshot new];
    show(s);
    TRY([s appendItemsWithIdentifiers:@[ @"a" ]]);
    [s appendSectionsWithIdentifiers:@[ @"S1", @"S2" ]];
    [s appendItemsWithIdentifiers:@[ @"a", @"b" ]];
    [s appendItemsWithIdentifiers:@[ @"c" ] intoSectionWithIdentifier:@"S1"];
    show(s);
    TRY([s appendItemsWithIdentifiers:@[ @"a" ]]);
    TRY([s appendSectionsWithIdentifiers:@[ @"S1" ]]);
    [s insertItemsWithIdentifiers:@[ @"x" ] beforeItemWithIdentifier:@"c"];
    [s insertItemsWithIdentifiers:@[ @"y" ] afterItemWithIdentifier:@"a"];
    show(s);
    printf("  in S1 %s count %ld S2 %ld; section of c %s; index of c %ld, of S2 %ld, missing %ld\n",
           [[s itemIdentifiersInSectionWithIdentifier:@"S1"] componentsJoinedByString:@","].UTF8String, (long)[s numberOfItemsInSection:@"S1"],
           (long)[s numberOfItemsInSection:@"S2"], [[s sectionIdentifierForSectionContainingItemIdentifier:@"c"] UTF8String],
           (long)[s indexOfItemIdentifier:@"c"], (long)[s indexOfSectionIdentifier:@"S2"], (long)[s indexOfItemIdentifier:@"zz"]);
    [s moveItemWithIdentifier:@"a" afterItemWithIdentifier:@"c"];
    show(s);
    [s moveItemWithIdentifier:@"c" beforeItemWithIdentifier:@"y"];
    show(s);
    [s appendItemsWithIdentifiers:@[ @"d" ] intoSectionWithIdentifier:@"S2"];
    [s moveSectionWithIdentifier:@"S2" beforeSectionWithIdentifier:@"S1"];
    show(s);
    [s insertSectionsWithIdentifiers:@[ @"S0" ] beforeSectionWithIdentifier:@"S1"];
    [s insertSectionsWithIdentifiers:@[ @"S9" ] afterSectionWithIdentifier:@"S1"];
    show(s);
    [s deleteItemsWithIdentifiers:@[ @"y", @"nope" ]];
    show(s);
    [s deleteSectionsWithIdentifiers:@[ @"S2" ]];
    show(s);
    TRY([s numberOfItemsInSection:@"S2"]);
    TRY([s insertItemsWithIdentifiers:@[ @"q" ] beforeItemWithIdentifier:@"nope"]);
    TRY([s moveItemWithIdentifier:@"x" afterItemWithIdentifier:@"x"]);
    TRY([s reloadItemsWithIdentifiers:@[ @"x" ]]);
    TRY([s reloadSectionsWithIdentifiers:@[ @"S1" ]]);
    TRY([s reloadItemsWithIdentifiers:@[ @"nope" ]]);
    NSDiffableDataSourceSnapshot *c = [s copy];
    [c deleteAllItems];
    show(c);
    show(s);
    printf("  equal %d %d\n", [s isEqual:[s copy]], [s isEqual:c]);
    TRY([s appendItemsWithIdentifiers:@[ @"m" ] intoSectionWithIdentifier:@"nope"]);

    NSCollectionView *cv = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    NSCollectionViewDiffableDataSource *ds = [[NSCollectionViewDiffableDataSource alloc]
        initWithCollectionView:cv
                  itemProvider:^NSCollectionViewItem *(NSCollectionView *v, NSIndexPath *ip, id item) { return [NSCollectionViewItem new]; }];
    [ds applySnapshot:s animatingDifferences:NO];
    NSIndexPath *ip = [ds indexPathForItemIdentifier:@"a"];
    printf("  data source: a at %ld.%ld, 1.0 is %s, sections %ld, items in 1 %ld, own data source %d, snapshot equal %d\n", (long)ip.section,
           (long)ip.item, [[ds itemIdentifierForIndexPath:[NSIndexPath indexPathForItem:0 inSection:1]] UTF8String],
           (long)[ds numberOfSectionsInCollectionView:cv], (long)[ds collectionView:cv numberOfItemsInSection:1], cv.dataSource == ds,
           [ds.snapshot isEqual:s]);
}

static void
values(void)
{
    printf("badges:\n");
    for (int n = 0; n < 3; n++)
        printf("  %s | %s | %s\n", [NSMenuItemBadge updatesWithCount:n].stringValue.UTF8String,
               [NSMenuItemBadge newItemsWithCount:n].stringValue.UTF8String, [NSMenuItemBadge alertsWithCount:n].stringValue.UTF8String);
    for (NSMenuItemBadge *b in @[ [NSMenuItemBadge alertsWithCount:1234], [[NSMenuItemBadge alloc] initWithCount:5],
                                  [[NSMenuItemBadge alloc] initWithString:@"Beta"] ])
        printf("  count %ld type %ld string %s\n", (long)b.itemCount, (long)b.type, b.stringValue.UTF8String);
    printf("pressure: default %ld, deep click %ld\n", (long)[NSPressureConfiguration new].pressureBehavior,
           (long)[[NSPressureConfiguration alloc] initWithPressureBehavior:NSPressureBehaviorPrimaryDeepClick].pressureBehavior);
    printf("tint:\n");
    for (NSTintConfiguration *t in @[ NSTintConfiguration.defaultTintConfiguration, NSTintConfiguration.monochromeTintConfiguration,
                                      [NSTintConfiguration tintConfigurationWithPreferredColor:NSColor.systemRedColor],
                                      [NSTintConfiguration tintConfigurationWithFixedColor:NSColor.systemGreenColor] ])
        printf("  base %s equivalent %s adapts %d\n", t.baseTintColor.description.UTF8String, t.equivalentContentTintColor.description.UTF8String,
               t.adaptsToUserAccentColor);
    printf("  shared %d\n", NSTintConfiguration.defaultTintConfiguration == NSTintConfiguration.defaultTintConfiguration);
    printf("compression:\n");
    NSUserInterfaceCompressionOptions *o = NSUserInterfaceCompressionOptions.hideImagesOption;
    NSUserInterfaceCompressionOptions *u = [o optionsByAddingOptions:NSUserInterfaceCompressionOptions.reduceMetricsOption];
    printf("  shared %d equal %d empty %d %d\n", o == NSUserInterfaceCompressionOptions.hideImagesOption,
           [o isEqual:[[NSUserInterfaceCompressionOptions alloc] initWithIdentifier:@"NSUserInterfaceCompressionOptionHideImages"]], o.isEmpty,
           [NSUserInterfaceCompressionOptions new].isEmpty);
    printf("  union contains %d intersects text %d; standard contains union %d; minus equals reduce %d\n", [u containsOptions:o],
           [u intersectsOptions:NSUserInterfaceCompressionOptions.hideTextOption], [NSUserInterfaceCompressionOptions.standardOptions containsOptions:u],
           [[u optionsByRemovingOptions:o] isEqual:NSUserInterfaceCompressionOptions.reduceMetricsOption]);
    if (@available(macOS 26.1, *))
        printf("edge styles: shared %d distinct %d\n", NSScrollEdgeEffectStyle.softStyle == NSScrollEdgeEffectStyle.softStyle,
               NSScrollEdgeEffectStyle.softStyle != NSScrollEdgeEffectStyle.hardStyle);
    NSPDFInfo *pi = [NSPDFInfo new];
    printf("pdf info: url %s hidden %d tags %lu orientation %ld size %s attributes %lu\n", pi.URL.path.UTF8String, pi.fileExtensionHidden,
           (unsigned long)pi.tagNames.count, (long)pi.orientation, NSStringFromSize(pi.paperSize).UTF8String, (unsigned long)pi.attributes.count);
    NSPDFPanel *pp = [NSPDFPanel panel];
    printf("pdf panel: options %ld default name %s\n", (long)pp.options, pp.defaultFileName.UTF8String);
    CIImage *red = [CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0]];
    NSCIImageRep *r = [NSCIImageRep imageRepWithCIImage:red];
    printf("ci rep: infinite %s\n", NSStringFromSize(r.size).UTF8String);
    r = [NSCIImageRep imageRepWithCIImage:[red imageByCroppingToRect:CGRectMake(0, 0, 20, 10)]];
    printf("ci rep: %s pixels %ldx%ld opaque %d same image %d\n", NSStringFromSize(r.size).UTF8String, (long)r.pixelsWide, (long)r.pixelsHigh,
           r.opaque, r.CIImage.extent.size.width == 20);
    NSBitmapImageRep *bm = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:20 pixelsHigh:10 bitsPerSample:8 samplesPerPixel:4
                                                                     hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0
                                                                 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bm];
    [r drawInRect:NSMakeRect(0, 0, 20, 10)];
    [NSGraphicsContext restoreGraphicsState];
    NSColor *px = [bm colorAtX:5 y:5];
    printf("ci rep drawn: red %.0f green %.0f\n", px.redComponent * 255, px.greenComponent * 255);
}

static void
collections(void)
{
    printf("font collections:\n");
    NSArray *names = [NSFontCollection allFontCollectionNames];
    for (NSString *n in @[ NSFontCollectionAllFonts, NSFontCollectionUser, NSFontCollectionFavorites, NSFontCollectionRecentlyUsed, @"Fixed Width" ])
        printf("  has %s: %d\n", n.UTF8String, [names containsObject:n]);
    printf("  all has fonts %d, fixed width has fonts %d, unknown %s\n",
           [NSFontCollection fontCollectionWithAllAvailableDescriptors].matchingDescriptors.count > 10,
           [NSFontCollection fontCollectionWithName:@"Fixed Width"].matchingDescriptors.count > 0,
           [NSFontCollection fontCollectionWithName:@"No Such Collection"] ? "found" : "nil");
    __block NSDictionary *info = nil;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSFontCollectionDidChangeNotification object:nil queue:nil
                                                           usingBlock:^(NSNotification *n) { info = n.userInfo; }];
    NSString *family = [NSFont userFixedPitchFontOfSize:12].familyName;
    NSFontDescriptor *helvetica = [NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute : family}];
    NSFontCollection *mine = [NSFontCollection fontCollectionWithDescriptors:@[ helvetica ]];
    NSError *err = nil;
    BOOL ok = [NSFontCollection showFontCollection:mine withName:@"Finch Test" visibility:NSFontCollectionVisibilityProcess error:&err];
    printf("  shown %d: action %s name %s visibility %s\n", ok, [info[NSFontCollectionActionKey] UTF8String], [info[NSFontCollectionNameKey] UTF8String],
           [[info[NSFontCollectionVisibilityKey] description] UTF8String]);
    NSFontCollection *back = [NSFontCollection fontCollectionWithName:@"Finch Test" visibility:NSFontCollectionVisibilityProcess];
    printf("  back: %lu query, listed %d, matches family %d\n", (unsigned long)back.queryDescriptors.count,
           [[NSFontCollection allFontCollectionNames] containsObject:@"Finch Test"],
           [[back.matchingDescriptors.firstObject objectForKey:NSFontFamilyAttribute] isEqual:family]);
    ok = [NSFontCollection renameFontCollectionWithName:@"Finch Test" visibility:NSFontCollectionVisibilityProcess toName:@"Finch Test 2" error:&err];
    printf("  renamed %d: action %s old %s new %s\n", ok, [info[NSFontCollectionActionKey] UTF8String], [info[NSFontCollectionOldNameKey] UTF8String],
           [info[NSFontCollectionNameKey] UTF8String]);
    ok = [NSFontCollection hideFontCollectionWithName:@"Finch Test 2" visibility:NSFontCollectionVisibilityProcess error:&err];
    printf("  hidden %d: action %s; gone %d\n", ok, [info[NSFontCollectionActionKey] UTF8String],
           [NSFontCollection fontCollectionWithName:@"Finch Test 2" visibility:NSFontCollectionVisibilityProcess] == nil);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
    NSMutableFontCollection *m = [NSMutableFontCollection fontCollectionWithDescriptors:@[ helvetica ]];
    NSFontDescriptor *courier = [NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute : @"Courier"}];
    [m addQueryForDescriptors:@[ courier ]];
    printf("  mutable: %lu query", (unsigned long)m.queryDescriptors.count);
    [m removeQueryForDescriptors:@[ helvetica ]];
    printf(", %lu after removing, class %s copy %s\n", (unsigned long)m.queryDescriptors.count, [m isKindOfClass:[NSMutableFontCollection class]] ? "mutable" : "plain",
           [[m copy] isKindOfClass:[NSMutableFontCollection class]] ? "mutable" : "plain");
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        snapshots();
        values();
        collections();
    }
    return 0;
}

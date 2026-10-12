/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Foundation methods found missing by tools/api-audit.sh, first batch: collections
 * (ranges, tests with options, sorted keys, removals, shared key sets), KVC's set and
 * ordered-set proxies and its deprecated names, dependent keys, strings (transforms,
 * folding, validated formats, encodings, completion, property lists), data
 * (compression, searching) and dates (string forms, NSCalendarDate). Compared with
 * Apple's.
 */
#import <Foundation/Foundation.h>

@interface Item : NSObject
@property (copy) NSString *name;
@property NSSet *tags;
@property NSOrderedSet *steps;
@property NSString *first, *last;
@property (readonly) NSString *full;
@end
@implementation Item
- (NSString *)full { return [NSString stringWithFormat:@"%@ %@", self.first, self.last]; }
@end

@interface Counted : NSObject {
@public
    NSMutableSet *_members;
}
@end
@implementation Counted
- (instancetype)init { if ((self = [super init])) _members = [NSMutableSet new]; return self; }
- (NSSet *)members { return _members; }
- (void)addMembersObject:(id)o { [_members addObject:[o stringByAppendingString:@"!"]]; }
- (void)removeMembersObject:(id)o { [_members removeObject:o]; }
@end

@interface Log : NSObject
@property NSMutableArray *entries;
@end
@implementation Log
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    NSNumber *kind = change[NSKeyValueChangeKindKey];
    NSArray *items = change[NSKeyValueChangeNewKey] ?: change[NSKeyValueChangeOldKey];
    NSString *list = [items isKindOfClass:[NSSet class]] ? [[[(NSSet *)items allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]
                     : [items isKindOfClass:[NSArray class]] ? [(NSArray *)items componentsJoinedByString:@","] : @"-";
    [self.entries addObject:[NSString stringWithFormat:@"%@:%@:%@", keyPath, kind, list]];
}
@end

/* (index sets by their ranges: descriptions carry addresses) */
static NSString *
ranges(NSIndexSet *s)
{
    NSMutableArray *parts = [NSMutableArray array];
    [s enumerateRangesUsingBlock:^(NSRange r, BOOL *stop) {
        [parts addObject:r.length == 1 ? [NSString stringWithFormat:@"%lu", (unsigned long)r.location]
                                       : [NSString stringWithFormat:@"%lu-%lu", (unsigned long)r.location, (unsigned long)NSMaxRange(r) - 1]];
    }];
    return [NSString stringWithFormat:@"%s(%@)", [s isKindOfClass:[NSMutableIndexSet class]] ? "mutable" : "", [parts componentsJoinedByString:@" "]];
}

static NSString *
sorted_set(id set)
{
    return [[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("Foundation audit\n");
        NSArray *a = @[ @"pear", @"apple", @"fig", @"apple", @"kiwi" ];

        /* NSArray */
        printf("in range: %lu %lu %lu\n", (unsigned long)[a indexOfObject:@"apple" inRange:NSMakeRange(2, 3)],
            (unsigned long)[a indexOfObject:@"pear" inRange:NSMakeRange(1, 4)], (unsigned long)[a indexOfObjectIdenticalTo:a[2] inRange:NSMakeRange(0, 5)]);
        @try {
            [a indexOfObject:@"x" inRange:NSMakeRange(3, 9)];
        } @catch (NSException *e) {
            printf("  past the end: %s\n", e.name.UTF8String);
        }
        BOOL (^longWord)(id, NSUInteger, BOOL *) = ^BOOL(id o, NSUInteger i, BOOL *stop) { return [o length] > 3; };
        printf("tests: first %lu last %lu all %s at odd %s\n", (unsigned long)[a indexOfObjectWithOptions:0 passingTest:longWord],
            (unsigned long)[a indexOfObjectWithOptions:NSEnumerationReverse passingTest:longWord],
            ranges([a indexesOfObjectsWithOptions:NSEnumerationConcurrent passingTest:longWord]).UTF8String,
            ranges([a indexesOfObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 3)] options:0 passingTest:longWord]).UTF8String);
        printf("common %s, paths %s\n", [[a firstObjectCommonWithArray:@[ @"kiwi", @"fig" ]] UTF8String],
            [[@[ @"a.txt", @"b.png", @"c.TXT", @"d" ] pathsMatchingExtensions:@[ @"txt", @"png" ]] componentsJoinedByString:@" "].UTF8String);

        /* NSMutableArray */
        NSMutableArray *m = [a mutableCopy];
        [m removeObject:@"apple" inRange:NSMakeRange(0, 2)];
        printf("remove in range: %s\n", [m componentsJoinedByString:@" "].UTF8String);
        [m removeObjectsInArray:@[ @"fig", @"none" ]];
        printf("remove array: %s\n", [m componentsJoinedByString:@" "].UTF8String);
        [m replaceObjectsInRange:NSMakeRange(0, 1) withObjectsFromArray:@[ @"x", @"y", @"z" ] range:NSMakeRange(1, 2)];
        printf("replace: %s\n", [m componentsJoinedByString:@" "].UTF8String);
        NSUInteger idx[] = {0, 2};
        [m removeObjectsFromIndices:idx numIndices:2];
        [m removeObjectIdenticalTo:m.lastObject inRange:NSMakeRange(0, m.count)];
        printf("from indices, identical: %s\n", [m componentsJoinedByString:@" "].UTF8String);

        /* NSDictionary */
        NSDictionary *d = @{@"b" : @3, @"a" : @1, @"c" : @2, @"q\"uote" : @"line\nbreak"};
        printf("sorted by value: %s / %s\n", [[[d dictionaryWithValuesForKeys:@[ @"a", @"b", @"c" ]] keysSortedByValueUsingSelector:@selector(compare:)] componentsJoinedByString:@" "].UTF8String,
            [[[d dictionaryWithValuesForKeys:@[ @"a", @"b", @"c" ]] keysSortedByValueUsingComparator:^(id x, id y) { return [y compare:x]; }] componentsJoinedByString:@" "].UTF8String);
        printf("entries: %s, for keys %s\n", sorted_set([d keysOfEntriesPassingTest:^BOOL(id k, id v, BOOL *s) { return [v isKindOfClass:[NSNumber class]] && [v intValue] > 1; }]).UTF8String,
            [[d objectsForKeys:@[ @"a", @"zz", @"c" ] notFoundMarker:@"-"] componentsJoinedByString:@" "].UTF8String);
        printf("strings file:\n%s", [d descriptionInStringsFileFormat].UTF8String);
        id keyset = [NSDictionary sharedKeySetForKeys:@[ @"x", @"y" ]];
        NSMutableDictionary *shared = [NSMutableDictionary dictionaryWithSharedKeySet:keyset];
        shared[@"x"] = @1;
        shared[@"other"] = @2;
        printf("shared key set: %lu entries, mutable %d\n", (unsigned long)shared.count, [shared isKindOfClass:[NSMutableDictionary class]]);
        NSString *plistPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-audit.plist"];
        [@{@"k" : @[ @1, @2 ]} writeToFile:plistPath atomically:YES];
        NSError *err = nil;
        printf("by URL: %s, array from dictionary file %s (%ld)\n",
            [[[NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:plistPath] error:&err][@"k"] description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String,
            [NSArray arrayWithContentsOfURL:[NSURL fileURLWithPath:plistPath] error:&err] ? "array" : "nil", (long)err.code);

        /* NSSet, NSIndexSet */
        NSSet *s = [NSSet setWithArray:a];
        printf("set test: %s\n", sorted_set([s objectsPassingTest:^BOOL(id o, BOOL *stop) { return [o hasPrefix:@"p"] || [o hasPrefix:@"k"]; }]).UTF8String);
        NSMutableIndexSet *is = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 6)];
        [is addIndex:20];
        BOOL (^even)(NSUInteger, BOOL *) = ^BOOL(NSUInteger i, BOOL *stop) { return i % 2 == 0; };
        printf("index tests: %lu %lu %s %s\n", (unsigned long)[is indexWithOptions:NSEnumerationReverse passingTest:even],
            (unsigned long)[is indexInRange:NSMakeRange(3, 4) options:0 passingTest:even],
            ranges([is indexesWithOptions:0 passingTest:even]).UTF8String,
            ranges([is indexesInRange:NSMakeRange(0, 6) options:NSEnumerationReverse passingTest:even]).UTF8String);

        /* KVC proxies and deprecated names */
        Item *item = [Item new];
        item.tags = [NSSet setWithObjects:@"red", nil];
        item.steps = [NSOrderedSet orderedSetWithObjects:@"one", @"two", nil];
        Log *log = [Log new];
        log.entries = [NSMutableArray array];
        [item addObserver:log forKeyPath:@"tags" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
        [item addObserver:log forKeyPath:@"steps" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
        NSMutableSet *tags = [item mutableSetValueForKey:@"tags"];
        [tags addObject:@"blue"];
        [tags removeObject:@"red"];
        [tags unionSet:[NSSet setWithObjects:@"green", @"gold", nil]];
        printf("set proxy: %s (count %lu), item %s\n", sorted_set(tags).UTF8String, (unsigned long)tags.count, sorted_set(item.tags).UTF8String);
        NSMutableOrderedSet *steps = [item mutableOrderedSetValueForKey:@"steps"];
        [steps insertObject:@"zero" atIndex:0];
        [steps removeObjectAtIndex:2];
        printf("ordered proxy: %s\n", [item.steps.array componentsJoinedByString:@" "].UTF8String);
        printf("kvo: %s\n", [log.entries componentsJoinedByString:@" "].UTF8String);
        [item removeObserver:log forKeyPath:@"tags"];
        [item removeObserver:log forKeyPath:@"steps"];
        Counted *c = [Counted new];
        [[c mutableSetValueForKey:@"members"] addObject:@"x"];
        printf("set accessors used: %s\n", sorted_set(c->_members).UTF8String);
        [item takeValue:@"old" forKey:@"name"];
        [item takeValuesFromDictionary:@{@"first" : @"Ada", @"last" : @"L"}];
        printf("deprecated: %s %s %s, values %s\n", item.name.UTF8String, [[item storedValueForKey:@"first"] UTF8String],
            [Item useStoredAccessor] ? "stored" : "-", [[[item valuesForKeys:@[ @"first", @"last" ]] description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String);
        [Item setKeys:@[ @"first", @"last" ] triggerChangeNotificationsForDependentKey:@"full"];
        printf("dependent keys: %s\n", sorted_set([Item keyPathsForValuesAffectingValueForKey:@"full"]).UTF8String);
        @try {
            [item handleQueryWithUnboundKey:@"nothing"];
        } @catch (NSException *e) {
            printf("unbound: %s\n", e.name.UTF8String);
        }

        /* NSString */
        NSString *str = @"Ça va? Ｗｉｄｅ façade";
        printf("transform: %s / %s\n", [str stringByApplyingTransform:NSStringTransformStripDiacritics reverse:NO].UTF8String,
            [@"Привет" stringByApplyingTransform:NSStringTransformToLatin reverse:NO].UTF8String);
        printf("fold: %s\n", [str stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                                      locale:[NSLocale localeWithLocaleIdentifier:@"en_US"]].UTF8String);
        printf("standard: %d %s %d\n", [str localizedStandardContainsString:@"FACADE"], NSStringFromRange([str localizedStandardRangeOfString:@"wide"]).UTF8String,
            [str localizedStandardContainsString:@"xyz"]);
        NSMutableString *ms = [NSMutableString stringWithString:@"Hello café world"];
        NSRange updated;
        BOOL changed = [ms applyTransform:NSStringTransformToUnicodeName reverse:NO range:NSMakeRange(6, 4) updatedRange:&updated];
        printf("apply transform: %d %s %s\n", changed, ms.UTF8String, NSStringFromRange(updated).UTF8String);
        NSError *ferr = nil;
        NSString *v1 = [NSString stringWithValidatedFormat:@"%d items for %@" validFormatSpecifiers:@"%d %@" error:&ferr, 3, @"you"];
        printf("validated value: %s\n", v1.UTF8String);
        printf("validated: %s\n", v1 ? "accepted" : "rejected");
        NSString *v2 = [[NSString alloc] initWithValidatedFormat:@"%@ items" validFormatSpecifiers:@"%d" error:&ferr, @"x"];
        printf("  mismatch: %s, error %s %ld\n", v2 ? "accepted" : "rejected", ferr.domain.UTF8String, (long)ferr.code);
        NSString *v3 = [NSString stringWithValidatedFormat:@"%ld of %ld" validFormatSpecifiers:@"%ld of %ld" error:NULL, 1L, 2L];
        printf("  same: %s\n", v3 ? "accepted" : "rejected");
        printf("format locale: %s\n", [[NSString alloc] initWithFormat:@"%.2f" locale:[NSLocale localeWithLocaleIdentifier:@"fr_FR"], 3.5].UTF8String);
        printf("paths: %s\n", [[@"/tmp" stringsByAppendingPaths:@[ @"a", @"b/c" ]] componentsJoinedByString:@" "].UTF8String);
        printf("plist: %s, strings: %s\n", [[[@"{ a = (1, 2); b = \"x y\"; }" propertyList] description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String,
            [[[@"\"k\" = \"v\";\n\"n\" = \"m\";" propertyListFromStringsFileFormat] description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String);
        printf("variant: %s\n", [@"plain" variantFittingPresentationWidth:10].UTF8String);
        NSString *conv = nil;
        BOOL lossy = NO;
        NSData *utf16 = [@"héllo" dataUsingEncoding:NSUTF16StringEncoding];
        NSStringEncoding enc = [NSString stringEncodingForData:utf16 encodingOptions:nil convertedString:&conv usedLossyConversion:&lossy];
        printf("encoding detect: utf16 %d %s lossy %d", enc == NSUTF16StringEncoding || enc == NSUnicodeStringEncoding, conv.UTF8String, lossy);
        enc = [NSString stringEncodingForData:[@"plain ascii" dataUsingEncoding:NSASCIIStringEncoding] encodingOptions:nil convertedString:&conv usedLossyConversion:&lossy];
        printf(", ascii %lu %s", (unsigned long)enc, conv.UTF8String);
        enc = [NSString stringEncodingForData:[@"naïve" dataUsingEncoding:NSUTF8StringEncoding] encodingOptions:@{NSStringEncodingDetectionSuggestedEncodingsKey : @[ @(NSUTF8StringEncoding) ]} convertedString:&conv usedLossyConversion:&lossy];
        printf(", utf8 %lu %s\n", (unsigned long)enc, conv.UTF8String);
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-complete"];
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *f in @[ @"report.txt", @"report.pdf", @"readme.md", @"Rex.txt" ])
            [@"x" writeToFile:[dir stringByAppendingPathComponent:f] atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSString *out = nil;
        NSArray *matches = nil;
        NSUInteger n = [[dir stringByAppendingPathComponent:@"rep"] completePathIntoString:&out caseSensitive:YES matchesIntoArray:&matches filterTypes:nil];
        printf("complete: %lu %s [%s]\n", (unsigned long)n, out.lastPathComponent.UTF8String,
            [[matches valueForKey:@"lastPathComponent"] componentsJoinedByString:@" "].UTF8String);
        n = [[dir stringByAppendingPathComponent:@"re"] completePathIntoString:&out caseSensitive:NO matchesIntoArray:&matches filterTypes:@[ @"txt" ]];
        printf("  insensitive txt: %lu %s [%s]\n", (unsigned long)n, out.lastPathComponent.UTF8String,
            [[[matches valueForKey:@"lastPathComponent"] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "].UTF8String);
        NSStringEncoding used = 0;
        NSString *fromFile = [[NSString alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:@"readme.md"] usedEncoding:&used error:nil];
        printf("used encoding: %s %lu\n", fromFile.UTF8String, (unsigned long)used);
        unichar chars[] = {'n', 'o', ' ', 'c', 'o', 'p', 'y'};
        NSString *nc = [[NSString alloc] initWithCharactersNoCopy:chars length:7 deallocator:nil];
        printf("no copy: %s\n", nc.UTF8String);

        /* NSData */
        NSMutableData *big = [NSMutableData data];
        for (int i = 0; i < 200; i++)
            [big appendData:[@"compress me please " dataUsingEncoding:NSUTF8StringEncoding]];
        NSDataCompressionAlgorithm algs[] = {NSDataCompressionAlgorithmLZFSE, NSDataCompressionAlgorithmLZ4, NSDataCompressionAlgorithmLZMA,
                                             NSDataCompressionAlgorithmZlib};
        for (int i = 0; i < 4; i++) {
            NSError *e = nil;
            NSData *z = [big compressedDataUsingAlgorithm:algs[i] error:&e];
            NSData *back = [z decompressedDataUsingAlgorithm:algs[i] error:&e];
            printf("compress %d: smaller %d round trip %d\n", i, z.length < big.length, [back isEqualToData:big]);
        }
        NSMutableData *md = [big mutableCopy];
        [md compressUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        [md decompressUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        NSError *bad = nil;
        printf("in place: %d, garbage %s %ld\n", [md isEqualToData:big],
            [[@"garbage" dataUsingEncoding:NSUTF8StringEncoding] decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZFSE error:&bad] ? "data" : "nil", (long)bad.code);
        NSData *hay = [@"abcabcXabc" dataUsingEncoding:NSUTF8StringEncoding], *needle = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
        printf("search: %s %s %s %s\n", NSStringFromRange([hay rangeOfData:needle options:0 range:NSMakeRange(1, 9)]).UTF8String,
            NSStringFromRange([hay rangeOfData:needle options:NSDataSearchBackwards range:NSMakeRange(0, 10)]).UTF8String,
            NSStringFromRange([hay rangeOfData:needle options:NSDataSearchAnchored range:NSMakeRange(1, 9)]).UTF8String,
            NSStringFromRange([hay rangeOfData:needle options:NSDataSearchAnchored | NSDataSearchBackwards range:NSMakeRange(0, 10)]).UTF8String);

        /* NSDate */
        NSDate *date = [NSDate dateWithString:@"2026-03-04 05:06:07 +0000"];
        printf("date string: %.0f, %s\n", date.timeIntervalSinceReferenceDate, [[[NSDate alloc] initWithString:@"bad"] description].UTF8String ?: "nil");
        printf("add: %.0f\n", [(NSDate *)[date addTimeInterval:60] timeIntervalSinceReferenceDate]);
        NSTimeZone *utc = [NSTimeZone timeZoneWithName:@"UTC"];
        printf("calendar format: %s\n", [date descriptionWithCalendarFormat:@"%Y-%m-%d %H:%M:%S %z %a %b %j %%" timeZone:utc locale:nil].UTF8String);
        NSCalendarDate *cd = [date dateWithCalendarFormat:@"%d/%m/%Y" timeZone:utc];
        printf("calendar date: %s, %ld %ld %ld %ld\n", cd.description.UTF8String, (long)cd.yearOfCommonEra, (long)cd.monthOfYear,
            (long)cd.dayOfMonth, (long)cd.dayOfWeek);
        NSCalendarDate *later = [cd dateByAddingYears:0 months:1 days:30 hours:1 minutes:0 seconds:0];
        printf("  later: %s, format %s\n", later.description.UTF8String, cd.calendarFormat.UTF8String);
        NSCalendarDate *parsed = [NSCalendarDate dateWithString:@"25/12/2026 10:30" calendarFormat:@"%d/%m/%Y %H:%M"];
        printf("  parsed: %ld-%ld-%ld %ld:%ld\n", (long)parsed.yearOfCommonEra, (long)parsed.monthOfYear, (long)parsed.dayOfMonth,
            (long)parsed.hourOfDay, (long)parsed.minuteOfHour);
        printf("description with locale: %s\n", [date descriptionWithLocale:nil].UTF8String);
        NSDate *nl = [NSDate dateWithNaturalLanguageString:@"2026-01-15"];
        printf("natural: %s\n", nl ? "date" : "nil");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
    }
    return 0;
}

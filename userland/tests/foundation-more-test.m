/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Foundation's date interval formats, orthographies, linguistic tagging (token types,
 * sentences, languages and scripts), file versions, metadata items, AppleScript objects
 * and background activity schedulers. Compared with Apple's.
 *
 * With --local, what can't be compared with Apple's (its key-value store needs an iCloud
 * entitlement, its queries Spotlight's index, its scheduler an idle machine): a store
 * round trip, a query over a directory, and a scheduled activity.
 */
#import <Foundation/Foundation.h>

static void
intervals(void)
{
    NSDateIntervalFormatter *f = [NSDateIntervalFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSDate *a = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *b = [a dateByAddingTimeInterval:3600 * 5], *c = [a dateByAddingTimeInterval:86400 * 40];
    printf("defaults: date %ld time %ld template '%s'\n", (long)f.dateStyle, (long)f.timeStyle, f.dateTemplate.UTF8String);
    for (int ds = 0; ds <= 4; ds++)
        for (int ts = 0; ts <= 4; ts += 2) {
            f.dateStyle = ds;
            f.timeStyle = ts;
            printf("%d/%d: [%s] [%s] [%s]\n", ds, ts, [f stringFromDate:a toDate:b].UTF8String, [f stringFromDate:a toDate:c].UTF8String,
                   [f stringFromDate:a toDate:a].UTF8String);
        }
    f.dateTemplate = @"yMMMd";
    printf("template: [%s] [%s]\n", [f stringFromDate:a toDate:c].UTF8String, [f stringFromDate:a toDate:b].UTF8String);
    f.dateTemplate = @"MMMMyyyy";
    printf("months: [%s]\n", [f stringFromDate:a toDate:[a dateByAddingTimeInterval:86400 * 100]].UTF8String);
    f.dateTemplate = @"yMMMd";
    for (NSString *l in @[ @"fr_FR", @"de_DE", @"ja_JP" ]) {
        f.locale = [NSLocale localeWithLocaleIdentifier:l];
        printf("%s: [%s]\n", l.UTF8String, [f stringFromDateInterval:[[NSDateInterval alloc] initWithStartDate:a endDate:c]].UTF8String);
    }
    f.timeZone = [NSTimeZone timeZoneWithName:@"America/Toronto"];
    f.dateTemplate = @"jm";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    printf("en_GB Toronto: [%s]\n", [f stringFromDate:a toDate:b].UTF8String);
    for (NSString *n in @[ @"UTC", @"GMT", @"UTC+5:30", @"Etc/UTC" ])
        printf("zone %s: %s\n", n.UTF8String, [NSTimeZone timeZoneWithName:n].name.UTF8String);
}

static void
orthographies(void)
{
    NSOrthography *o = [NSOrthography defaultOrthographyForLanguage:@"ru"];
    printf("ru: script %s language %s all %s\n", o.dominantScript.UTF8String, o.dominantLanguage.UTF8String,
           [o.allLanguages componentsJoinedByString:@","].UTF8String);
    o = [NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn" : @[ @"fr", @"en" ], @"Grek" : @[ @"el" ]}];
    printf("map: %s %s %s %d\n", o.dominantLanguage.UTF8String, [o dominantLanguageForScript:@"Grek"].UTF8String,
           [[o languagesForScript:@"Latn"] componentsJoinedByString:@","].UTF8String,
           [o isEqual:[NSOrthography orthographyWithDominantScript:@"Latn" languageMap:@{@"Latn" : @[ @"fr", @"en" ], @"Grek" : @[ @"el" ]}]]);
}

static void
tag(NSString *s)
{
    NSLinguisticTagger *t = [[NSLinguisticTagger alloc] initWithTagSchemes:@[ NSLinguisticTagSchemeTokenType, NSLinguisticTagSchemeLanguage ]
                                                                   options:0];
    t.string = s;
    printf("%s\n", [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String);
    for (int o = 0; o < 2; o++) {
        NSLinguisticTaggerOptions opts = o ? NSLinguisticTaggerOmitWhitespace | NSLinguisticTaggerOmitPunctuation : 0;
        [t enumerateTagsInRange:NSMakeRange(0, s.length) scheme:NSLinguisticTagSchemeTokenType options:opts
                     usingBlock:^(NSString *tag, NSRange tr, NSRange sr, BOOL *stop) {
                         printf(" [%s]%s@%lu", [[s substringWithRange:tr] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String,
                                tag.UTF8String, (unsigned long)sr.location);
                     }];
        printf("\n");
    }
    NSArray *ranges;
    [t tagsInRange:NSMakeRange(0, s.length) unit:NSLinguisticTaggerUnitSentence scheme:NSLinguisticTagSchemeTokenType
                           options:0 tokenRanges:&ranges];
    printf(" sentences:");
    for (NSUInteger i = 0; i < ranges.count; i++)
        printf(" %s", NSStringFromRange([ranges[i] rangeValue]).UTF8String);
    NSRange r;
    NSString *w = [t tagAtIndex:s.length - 1 unit:NSLinguisticTaggerUnitWord scheme:NSLinguisticTagSchemeTokenType tokenRange:&r];
    printf("\n last %s %s; sentence of {2,1} %s\n", w.UTF8String, NSStringFromRange(r).UTF8String,
           NSStringFromRange([t sentenceRangeForRange:NSMakeRange(2, 1)]).UTF8String);
}

static void
tagging(void)
{
    tag(@"Hello, world! It's 3 o'clock.");
    tag(@"Wait...  what?! Dr. Smith  paid $3.14 -- don't you'll we've.");
    tag(@"e-mail: a@b.com, 1,000 items; (yes)");
    tag(@"Привет мир. Это тест!");
    tag(@"one\n\ntwo");
    for (NSString *s in @[ @"The quick brown fox jumps over the lazy dog.", @"Bonjour tout le monde, comment allez-vous?",
                           @"Guten Tag, wie geht es Ihnen heute?", @"Hola, ¿cómo estás? Estoy bien.", @"Ciao, come stai oggi?",
                           @"Olá, como você está hoje?", @"Hallo, hoe gaat het met je vandaag?", @"Сегодня хорошая погода, и мы идём гулять в парк.",
                           @"これは日本語のテキストです。", @"한국어 텍스트입니다", @"שלום עולם", @"مرحبا بالعالم", @"Γεια σου κόσμε",
                           @"สวัสดีชาวโลก", @"नमस्ते दुनिया", @"" ])
        printf("language %s: %s\n", s.UTF8String, [NSLinguisticTagger dominantLanguageForString:s].UTF8String ?: "(none)");
    NSLinguisticTagger *t = [[NSLinguisticTagger alloc] initWithTagSchemes:@[ NSLinguisticTagSchemeScript ] options:0];
    t.string = @"Привет мир";
    printf("script %s\n", [t tagAtIndex:0 scheme:NSLinguisticTagSchemeScript tokenRange:NULL sentenceRange:NULL].UTF8String);
    t.string = @"Hello there";
    [t setOrthography:[NSOrthography defaultOrthographyForLanguage:@"de"] range:NSMakeRange(0, 11)];
    printf("set orthography: %s, dominant %s\n", [t orthographyAtIndex:0 effectiveRange:NULL].dominantLanguage.UTF8String, t.dominantLanguage.UTF8String);
    NSArray *tr;
    printf("string tags: %s\n", [[@"Hi, you." linguisticTagsInRange:NSMakeRange(0, 8) scheme:NSLinguisticTagSchemeTokenType options:0
                                                         orthography:nil tokenRanges:&tr] componentsJoinedByString:@","].UTF8String);
}

static void
versions(NSString *dir)
{
    NSString *p = [dir stringByAppendingPathComponent:@"v.txt"];
    [@"x" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    NSURL *u = [NSURL fileURLWithPath:p];
    NSFileVersion *v = [NSFileVersion currentVersionOfItemAtURL:u];
    printf("version: name %s same url %d others %lu conflicts %lu conflict %d resolved %d discardable %d local %d thumbnail %d recent %d\n",
           v.localizedName.UTF8String, [v.URL isEqual:u], (unsigned long)[NSFileVersion otherVersionsOfItemAtURL:u].count,
           (unsigned long)[NSFileVersion unresolvedConflictVersionsOfItemAtURL:u].count, v.conflict, v.resolved, v.discardable,
           v.hasLocalContents, v.hasThumbnail, fabs(v.modificationDate.timeIntervalSinceNow) < 60);
    printf("missing: %s\n", [NSFileVersion currentVersionOfItemAtURL:[NSURL fileURLWithPath:@"/nonexistent"]] ? "yes" : "nil");
}

static void
item(NSString *path)
{
    NSMetadataItem *mi = [[NSMetadataItem alloc] initWithURL:[NSURL fileURLWithPath:path]];
    if (!mi) {
        printf("item %s: nil\n", path.lastPathComponent.UTF8String);
        return;
    }
    printf("item %s: %lu attributes\n", path.lastPathComponent.UTF8String, (unsigned long)mi.attributes.count);
    for (NSString *a in @[ @"kMDItemFSName", @"kMDItemFSSize", @"kMDItemFSNodeCount", @"kMDItemFSInvisible", @"kMDItemFSIsExtensionHidden",
                           @"kMDItemFSLabel", @"kMDItemFSTypeCode", @"kMDItemDisplayName", @"kMDItemContentType", @"kMDItemKind" ]) {
        id x = [mi valueForAttribute:a];
        printf("  %s = %s\n", a.UTF8String, [x description].UTF8String);
    }
    NSArray *tree = [mi valueForAttribute:@"kMDItemContentTypeTree"];
    printf("  tree %s\n", [[tree sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
    printf("  path ends %d; by key %s; values %lu\n", [[mi valueForAttribute:NSMetadataItemPathKey] hasSuffix:path.lastPathComponent],
           [[mi valueForKey:@"kMDItemFSName"] UTF8String], (unsigned long)[mi valuesForAttributes:@[ @"kMDItemFSName", @"bogus" ]].count);
}

static void
scripts(void)
{
    NSAppleScript *s = [[NSAppleScript alloc] initWithSource:@"return 1 + 2"];
    printf("script: compiled %d source %s\n", s.isCompiled, s.source.UTF8String);
    NSBackgroundActivityScheduler *b = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:@"org.finch.test.activity"];
    printf("activity: %s interval %g tolerance %g repeats %d qos %ld\n", b.identifier.UTF8String, b.interval, b.tolerance, b.repeats,
           (long)b.qualityOfService);
    @try {
        [b shouldDefer];
        printf("shouldDefer outside: no exception\n");
    } @catch (NSException *e) {
        printf("shouldDefer outside: %s\n", e.name.UTF8String);
    }
    NSMetadataQuery *q = [NSMetadataQuery new];
    printf("query: gathering %d started %d stopped %d count %lu scopes %lu batching %g\n", q.isGathering, q.isStarted, q.isStopped,
           (unsigned long)q.resultCount, (unsigned long)q.searchScopes.count, q.notificationBatchingInterval);
}

static void
local(NSString *dir)
{
    NSUbiquitousKeyValueStore *s = [NSUbiquitousKeyValueStore defaultStore];
    [s setString:@"hello" forKey:@"greeting"];
    [s setLongLong:42 forKey:@"n"];
    [s setBool:YES forKey:@"b"];
    [s setObject:[@"" stringByPaddingToLength:2 * 1024 * 1024 withString:@"x" startingAtIndex:0] forKey:@"huge"];
    printf("store: %s %lld %d huge %d sync %d\n", [s stringForKey:@"greeting"].UTF8String, [s longLongForKey:@"n"], [s boolForKey:@"b"],
           [s objectForKey:@"huge"] != nil, [s synchronize]);
    [s removeObjectForKey:@"greeting"];
    printf("store after remove: %lu keys\n", (unsigned long)s.dictionaryRepresentation.count);
    [[NSFileManager defaultManager] removeItemAtPath:[NSHomeDirectory() stringByAppendingFormat:@"/Library/SyncedPreferences/%@.plist",
                                                                                         [NSProcessInfo processInfo].processName]
                                               error:NULL];

    for (NSString *n in @[ @"a.txt", @"b.txt", @"c.png" ])
        [@"data" writeToFile:[dir stringByAppendingPathComponent:n] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    NSMetadataQuery *q = [NSMetadataQuery new];
    q.searchScopes = @[ [NSURL fileURLWithPath:dir] ];
    q.predicate = [NSPredicate predicateWithFormat:@"kMDItemFSName LIKE '*.txt'"];
    q.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"kMDItemFSName" ascending:NO] ];
    q.valueListAttributes = @[ @"kMDItemContentType" ];
    __block BOOL done = NO;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:q queue:nil
                                                           usingBlock:^(NSNotification *n) { done = YES; }];
    printf("query start %d\n", [q startQuery]);
    while (!done)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("query: %lu results, gathering %d:", (unsigned long)q.resultCount, q.isGathering);
    for (NSMetadataItem *i in q.results)
        printf(" %s", [[i valueForAttribute:NSMetadataItemFSNameKey] UTF8String]);
    NSMetadataQueryAttributeValueTuple *tuple = [q.valueLists[@"kMDItemContentType"] firstObject];
    printf("; %s x%lu\n", [tuple.value UTF8String], (unsigned long)tuple.count);
    [q stopQuery];
    [[NSNotificationCenter defaultCenter] removeObserver:obs];

    NSBackgroundActivityScheduler *b = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:@"org.finch.test.activity"];
    b.interval = 0.2;
    b.repeats = YES;
    __block int runs = 0;
    [b scheduleWithBlock:^(NSBackgroundActivityCompletionHandler finished) {
        runs++;
        printf("activity ran %d, defer %d\n", runs, b.shouldDefer);
        finished(NSBackgroundActivityResultFinished);
    }];
    while (runs < 2)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [b invalidate];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-foundation-more"];
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        if (argc > 1 && !strcmp(argv[1], "--local")) {
            local(dir);
            return 0;
        }
        intervals();
        orthographies();
        tagging();
        versions(dir);
        item([dir stringByAppendingPathComponent:@"v.txt"]);
        item(dir);
        item(@"/nonexistent");
        scripts();
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
    return 0;
}

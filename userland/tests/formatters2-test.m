/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSListFormatter, NSRelativeDateTimeFormatter, NSPersonNameComponentsFormatter and
 * NSLocalizedFileSizeDescription, in a few locales, compared with Apple's.
 */
#import <Foundation/Foundation.h>

extern NSString *NSLocalizedFileSizeDescription(unsigned long long size, long unused, unsigned long flags);

static NSArray *locales;

static void
lists(void)
{
    NSArray *sets = @[ @[], @[ @"a" ], @[ @"a", @"b" ], @[ @"apples", @"pears", @"plums" ], @[ @"1", @"2", @"3", @"4" ] ];
    for (NSString *l in locales) {
        NSListFormatter *f = [NSListFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:l];
        printf("list %s:", l.UTF8String);
        for (NSArray *s in sets)
            printf(" [%s]", [f stringFromItems:s].UTF8String);
        printf("\n");
    }
    NSListFormatter *f = [NSListFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSNumberFormatter *n = [NSNumberFormatter new];
    n.numberStyle = NSNumberFormatterSpellOutStyle;
    n.locale = f.locale;
    f.itemFormatter = n;
    printf("list items formatted: %s\n", [f stringFromItems:@[ @1, @2, @3 ]].UTF8String);
    printf("list class method: %s\n", [NSListFormatter localizedStringByJoiningStrings:@[ @"x", @"y" ]].UTF8String);
    printf("list stringForObjectValue: %s / %s\n", [f stringForObjectValue:@[ @4, @5 ]].UTF8String, [f stringForObjectValue:@"no"].UTF8String);
}

static void
relative(void)
{
    NSDate *base = [NSDate dateWithTimeIntervalSinceReferenceDate:700000000];
    double offsets[] = {0, 30, -30, 3600, -7200, 86400, -86400, 172800, -604800, 2592000, -31536000, 1e9};
    NSRelativeDateTimeFormatterUnitsStyle styles[] = {NSRelativeDateTimeFormatterUnitsStyleFull, NSRelativeDateTimeFormatterUnitsStyleSpellOut,
        NSRelativeDateTimeFormatterUnitsStyleShort, NSRelativeDateTimeFormatterUnitsStyleAbbreviated};
    for (NSString *l in locales) {
        for (int st = 0; st < 4; st++) {
            for (int dt = 0; dt < 2; dt++) {
                NSRelativeDateTimeFormatter *f = [NSRelativeDateTimeFormatter new];
                f.locale = [NSLocale localeWithLocaleIdentifier:l];
                f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
                f.calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                f.unitsStyle = styles[st];
                f.dateTimeStyle = dt ? NSRelativeDateTimeFormatterStyleNamed : NSRelativeDateTimeFormatterStyleNumeric;
                printf("relative %s style %d %s:", l.UTF8String, st, dt ? "named" : "numeric");
                for (int i = 0; i < 12; i++)
                    printf(" [%s]", [f localizedStringForDate:[base dateByAddingTimeInterval:offsets[i]] relativeToDate:base].UTF8String);
                printf("\n");
            }
        }
    }
    NSRelativeDateTimeFormatter *f = [NSRelativeDateTimeFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSDateComponents *c = [NSDateComponents new];
    c.day = -3;
    printf("components -3 days: %s\n", [f localizedStringFromDateComponents:c].UTF8String);
    c = [NSDateComponents new];
    c.hour = 2;
    c.minute = 30;
    printf("components 2h30m: %s\n", [f localizedStringFromDateComponents:c].UTF8String);
    printf("interval -90: %s, 5400: %s\n", [f localizedStringFromTimeInterval:-90].UTF8String, [f localizedStringFromTimeInterval:5400].UTF8String);
    f.formattingContext = NSFormattingContextBeginningOfSentence;
    f.dateTimeStyle = NSRelativeDateTimeFormatterStyleNamed;
    printf("beginning of sentence: %s\n", [f localizedStringFromTimeInterval:-86400].UTF8String);
    printf("defaults: style %ld units %ld context %ld\n", (long)[NSRelativeDateTimeFormatter new].dateTimeStyle,
        (long)[NSRelativeDateTimeFormatter new].unitsStyle, (long)[NSRelativeDateTimeFormatter new].formattingContext);
}

static void
names(void)
{
    NSPersonNameComponents *p = [NSPersonNameComponents new];
    p.namePrefix = @"Dr.";
    p.givenName = @"Ada";
    p.middleName = @"King";
    p.familyName = @"Lovelace";
    p.nameSuffix = @"Jr.";
    p.nickname = @"Countess";
    NSPersonNameComponents *jp = [NSPersonNameComponents new];
    jp.givenName = @"太郎";
    jp.familyName = @"山田";
    NSPersonNameComponents *one = [NSPersonNameComponents new];
    one.givenName = @"Cher";
    NSPersonNameComponentsFormatterStyle styles[] = {NSPersonNameComponentsFormatterStyleDefault, NSPersonNameComponentsFormatterStyleShort,
        NSPersonNameComponentsFormatterStyleMedium, NSPersonNameComponentsFormatterStyleLong, NSPersonNameComponentsFormatterStyleAbbreviated};
    for (NSString *l in locales) {
        NSPersonNameComponentsFormatter *f = [NSPersonNameComponentsFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:l];
        printf("names %s:", l.UTF8String);
        for (int s = 0; s < 5; s++) {
            f.style = styles[s];
            printf(" [%s|%s|%s]", [f stringFromPersonNameComponents:p].UTF8String, [f stringFromPersonNameComponents:jp].UTF8String,
                [f stringFromPersonNameComponents:one].UTF8String);
        }
        printf("\n");
    }
    NSPersonNameComponentsFormatter *f = [NSPersonNameComponentsFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    for (NSString *s in @[ @"Ada Lovelace", @"Dr. Ada King Lovelace Jr.", @"Lovelace, Ada", @"Cher", @"山田太郎", @"" ]) {
        NSPersonNameComponents *c = [f personNameComponentsFromString:s];
        printf("parse '%s': prefix %s given %s middle %s family %s suffix %s\n", s.UTF8String, c.namePrefix.UTF8String, c.givenName.UTF8String,
            c.middleName.UTF8String, c.familyName.UTF8String, c.nameSuffix.UTF8String);
    }
    printf("class method: %s\n", [NSPersonNameComponentsFormatter localizedStringFromPersonNameComponents:p
                                                                                                  style:NSPersonNameComponentsFormatterStyleShort
                                                                                                options:0]
                                     .UTF8String);
    NSAttributedString *a = [f annotatedStringFromPersonNameComponents:p];
    printf("annotated: %s\n", a.string.UTF8String);
    [a enumerateAttribute:NSPersonNameComponentKey inRange:NSMakeRange(0, a.length) options:0
               usingBlock:^(id value, NSRange range, BOOL *stop) {
                 if (value)
                     printf("  %s: %s\n", [value UTF8String], [a.string substringWithRange:range].UTF8String);
               }];
}

static void
file_sizes(void)
{
    unsigned long long sizes[] = {0, 1, 999, 1000, 1536, 1000000, 1500000, 123456789, 5368709120ULL};
    unsigned long flags[] = {0, 1, 2, 4, 8, 0x100000, 0x1000000, 0x4000000};
    for (int i = 0; i < 9; i++) {
        printf("file size %llu:", sizes[i]);
        for (int f = 0; f < 8; f++)
            printf(" [%s]", NSLocalizedFileSizeDescription(sizes[i], 0, flags[f]).UTF8String);
        printf("\n");
    }
}

int
main(void)
{
    @autoreleasepool {
        locales = @[ @"en_US", @"en_GB", @"fr_FR", @"de_DE", @"ja_JP", @"es_ES" ];
        lists();
        relative();
        names();
        file_sizes();
    }
    return 0;
}

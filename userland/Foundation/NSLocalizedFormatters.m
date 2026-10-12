/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSListFormatter and NSRelativeDateTimeFormatter (over ICU's list and relative
 * date-time formatters, as Apple's are), NSPersonNameComponentsFormatter, and the
 * private NSLocalizedFileSizeDescription that apps call.
 *
 * A relative date is said in the largest calendar unit by which the two dates differ
 * (years, months, weeks, days, hours, minutes, seconds), as Apple's is. Names are put
 * in the locale's order (family first in Japanese, Chinese, Korean, Vietnamese and
 * Hungarian); names written in CJK scripts are always family first and unspaced.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

/* --- Apple's ICU (libicucore), declared as CF declares what it uses --- */

typedef uint16_t UChar;
typedef int UErrorCode;
typedef void UListFormatter;
typedef void URelativeDateTimeFormatter;
typedef void UNumberFormat;
#define U_FAILURE(e) ((e) > 0)
extern UListFormatter *ulistfmt_open(const char *locale, UErrorCode *status);
extern int32_t ulistfmt_format(const UListFormatter *f, const UChar *const strings[], const int32_t *lengths, int32_t count,
    UChar *result, int32_t capacity, UErrorCode *status);
extern void ulistfmt_close(UListFormatter *f);
extern URelativeDateTimeFormatter *ureldatefmt_open(const char *locale, UNumberFormat *nfToAdopt, int width, int capitalization,
    UErrorCode *status);
extern int32_t ureldatefmt_format(const URelativeDateTimeFormatter *f, double offset, int unit, UChar *result, int32_t capacity,
    UErrorCode *status);
extern int32_t ureldatefmt_formatNumeric(const URelativeDateTimeFormatter *f, double offset, int unit, UChar *result,
    int32_t capacity, UErrorCode *status);
extern void ureldatefmt_close(URelativeDateTimeFormatter *f);
extern UNumberFormat *unum_open(int style, const UChar *pattern, int32_t patternLength, const char *locale, void *parseError,
    UErrorCode *status);

enum { UDAT_REL_UNIT_YEAR = 0, UDAT_REL_UNIT_MONTH = 2, UDAT_REL_UNIT_WEEK, UDAT_REL_UNIT_DAY, UDAT_REL_UNIT_HOUR, UDAT_REL_UNIT_MINUTE,
    UDAT_REL_UNIT_SECOND };
enum { UNUM_SPELLOUT = 5 };

static NSString *
uchars(const UChar *s, int32_t n)
{
    return n > 0 ? [NSString stringWithCharacters:s length:(NSUInteger)n] : @"";
}

static const char *
icu_locale(NSLocale *locale)
{
    return [(locale ?: [NSLocale currentLocale]).localeIdentifier UTF8String];
}

/* --- NSListFormatter --- */

@implementation NSListFormatter {
    NSLocale *_locale;
    NSFormatter *_itemFormatter;
}

- (void)dealloc
{
    [_locale release];
    [_itemFormatter release];
    [super dealloc];
}

- (NSLocale *)locale { return _locale ?: [NSLocale autoupdatingCurrentLocale]; }
- (void)setLocale:(NSLocale *)locale { [_locale autorelease]; _locale = [locale copy]; }
- (NSFormatter *)itemFormatter { return _itemFormatter; }
- (void)setItemFormatter:(NSFormatter *)f { [_itemFormatter autorelease]; _itemFormatter = [f copy]; }

static NSString *
join(NSArray<NSString *> *strings, NSLocale *locale)
{
    if (!strings.count)
        return @"";
    UErrorCode status = 0;
    UListFormatter *f = ulistfmt_open(icu_locale(locale), &status);
    if (U_FAILURE(status) || !f)
        return [strings componentsJoinedByString:@", "];
    NSUInteger n = strings.count;
    const UChar **items = calloc(n, sizeof *items);
    int32_t *lengths = calloc(n, sizeof *lengths);
    NSMutableArray *keep = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        NSData *d = [strings[i] dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        [keep addObject:d];
        items[i] = d.bytes;
        lengths[i] = (int32_t)(d.length / 2);
    }
    UChar buffer[1024];
    int32_t len = ulistfmt_format(f, items, lengths, (int32_t)n, buffer, 1024, &status);
    NSString *result = nil;
    if (!U_FAILURE(status))
        result = uchars(buffer, len);
    else if (len > 1024) {
        UChar *big = malloc((size_t)len * sizeof(UChar));
        status = 0;
        len = ulistfmt_format(f, items, lengths, (int32_t)n, big, len, &status);
        result = U_FAILURE(status) ? nil : uchars(big, len);
        free(big);
    }
    ulistfmt_close(f);
    free(items);
    free(lengths);
    return result ?: [strings componentsJoinedByString:@", "];
}

+ (NSString *)localizedStringByJoiningStrings:(NSArray<NSString *> *)strings
{
    return join(strings, [NSLocale currentLocale]);
}

- (NSString *)stringFromItems:(NSArray *)items
{
    NSMutableArray *strings = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *s = _itemFormatter ? [_itemFormatter stringForObjectValue:item] : nil;
        if (!s)
            s = [item isKindOfClass:[NSString class]] ? item : [item description];
        [strings addObject:s];
    }
    return join(strings, self.locale);
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[NSArray class]] ? [self stringFromItems:obj] : nil;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSListFormatter *c = [[[self class] allocWithZone:zone] init];
    c.locale = _locale;
    c.itemFormatter = _itemFormatter;
    return c;
}

@end

/* --- NSRelativeDateTimeFormatter --- */

@implementation NSRelativeDateTimeFormatter {
    NSLocale *_locale;
    NSCalendar *_calendar;
    NSRelativeDateTimeFormatterStyle _dateTimeStyle;
    NSRelativeDateTimeFormatterUnitsStyle _unitsStyle;
    NSFormattingContext _context;
}

- (void)dealloc
{
    [_locale release];
    [_calendar release];
    [super dealloc];
}

- (NSLocale *)locale { return _locale ?: [NSLocale autoupdatingCurrentLocale]; }
- (void)setLocale:(NSLocale *)locale { [_locale autorelease]; _locale = [locale copy]; }
- (NSCalendar *)calendar { return _calendar ?: [NSCalendar autoupdatingCurrentCalendar]; }
- (void)setCalendar:(NSCalendar *)calendar { [_calendar autorelease]; _calendar = [calendar copy]; }
- (NSRelativeDateTimeFormatterStyle)dateTimeStyle { return _dateTimeStyle; }
- (void)setDateTimeStyle:(NSRelativeDateTimeFormatterStyle)s { _dateTimeStyle = s; }
- (NSRelativeDateTimeFormatterUnitsStyle)unitsStyle { return _unitsStyle; }
- (void)setUnitsStyle:(NSRelativeDateTimeFormatterUnitsStyle)s { _unitsStyle = s; }
- (NSFormattingContext)formattingContext { return _context; }
- (void)setFormattingContext:(NSFormattingContext)c { _context = c; }

/* An offset in a unit, said in the formatter's style. */
- (NSString *)_say:(double)value unit:(int)unit
{
    int width = _unitsStyle == NSRelativeDateTimeFormatterUnitsStyleShort         ? 1
                : _unitsStyle == NSRelativeDateTimeFormatterUnitsStyleAbbreviated ? 2
                                                                                  : 0;
    int capitalization = _context == NSFormattingContextBeginningOfSentence ? 0x102
                         : _context == NSFormattingContextStandalone        ? 0x104
                         : _context == NSFormattingContextListItem          ? 0x103
                         : _context == NSFormattingContextMiddleOfSentence  ? 0x101
                                                                            : 0x100;
    UErrorCode status = 0;
    const char *locale = icu_locale(self.locale);
    UNumberFormat *spell = _unitsStyle == NSRelativeDateTimeFormatterUnitsStyleSpellOut ? unum_open(UNUM_SPELLOUT, NULL, 0, locale, NULL, &status)
                                                                                        : NULL;
    status = 0;
    URelativeDateTimeFormatter *f = ureldatefmt_open(locale, spell, width, capitalization, &status);
    if (U_FAILURE(status) || !f)
        return nil;
    UChar buffer[256];
    int32_t len = _dateTimeStyle == NSRelativeDateTimeFormatterStyleNamed ? ureldatefmt_format(f, value, unit, buffer, 256, &status)
                                                                          : ureldatefmt_formatNumeric(f, value, unit, buffer, 256, &status);
    ureldatefmt_close(f);
    return U_FAILURE(status) ? nil : uchars(buffer, len);
}

/* The largest unit set in the components, and its value. */
- (NSString *)localizedStringFromDateComponents:(NSDateComponents *)c
{
    struct {
        NSInteger value;
        int unit;
    } order[] = {{c.year, UDAT_REL_UNIT_YEAR}, {c.month, UDAT_REL_UNIT_MONTH}, {c.weekOfMonth, UDAT_REL_UNIT_WEEK},
        {c.weekOfYear, UDAT_REL_UNIT_WEEK}, {c.day, UDAT_REL_UNIT_DAY}, {c.hour, UDAT_REL_UNIT_HOUR}, {c.minute, UDAT_REL_UNIT_MINUTE},
        {c.second, UDAT_REL_UNIT_SECOND}};
    for (size_t i = 0; i < sizeof order / sizeof order[0]; i++)
        if (order[i].value != NSDateComponentUndefined && order[i].value != 0)
            return [self _say:(double)order[i].value unit:order[i].unit];
    return [self _say:0 unit:UDAT_REL_UNIT_SECOND];
}

- (NSString *)localizedStringForDate:(NSDate *)date relativeToDate:(NSDate *)referenceDate
{
    NSCalendarUnit units = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute |
                           NSCalendarUnitSecond;
    NSDateComponents *c = [self.calendar components:units fromDate:referenceDate toDate:date options:0];
    /* (whole weeks within a month are said in weeks) */
    if (!c.year && !c.month && labs(c.day) >= 7) {
        c.weekOfMonth = c.day / 7;
        c.day = 0;
    }
    return [self localizedStringFromDateComponents:c];
}

- (NSString *)localizedStringFromTimeInterval:(NSTimeInterval)timeInterval
{
    NSDate *now = [NSDate date];
    return [self localizedStringForDate:[now dateByAddingTimeInterval:timeInterval] relativeToDate:now];
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[NSDate class]] ? [self localizedStringForDate:obj relativeToDate:[NSDate date]] : nil;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSRelativeDateTimeFormatter *c = [[[self class] allocWithZone:zone] init];
    c.locale = _locale;
    c.calendar = _calendar;
    c.dateTimeStyle = _dateTimeStyle;
    c.unitsStyle = _unitsStyle;
    c.formattingContext = _context;
    return c;
}

@end

/* --- NSPersonNameComponentsFormatter --- */

NSString *const NSPersonNameComponentKey = @"NSPersonNameComponentKey";
NSString *const NSPersonNameComponentGivenName = @"givenName";
NSString *const NSPersonNameComponentFamilyName = @"familyName";
NSString *const NSPersonNameComponentMiddleName = @"middleName";
NSString *const NSPersonNameComponentPrefix = @"namePrefix";
NSString *const NSPersonNameComponentSuffix = @"nameSuffix";
NSString *const NSPersonNameComponentNickname = @"nickname";
NSString *const NSPersonNameComponentDelimiter = @"delimiter";

static BOOL
is_cjk(NSString *s)
{
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF))
            return YES;
    }
    return NO;
}

static BOOL
family_first(NSLocale *locale)
{
    NSString *language = [locale objectForKey:NSLocaleLanguageCode];
    return [@[ @"ja", @"zh", @"ko", @"vi", @"hu" ] containsObject:language ?: @""];
}

/* A name as pieces (text, component key), for both strings and annotated strings. */
typedef struct {
    NSMutableArray *texts, *keys;
} Pieces;

static void
add(Pieces *p, NSString *text, NSString *key)
{
    if (!text.length)
        return;
    if (p->texts.count && key) {
        [p->texts addObject:@" "];
        [p->keys addObject:NSPersonNameComponentDelimiter];
    }
    [p->texts addObject:text];
    [p->keys addObject:key];
}

static NSString *
initial(NSString *s)
{
    return s.length ? [[s substringToIndex:[s rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString] : @"";
}

@implementation NSPersonNameComponentsFormatter {
    NSPersonNameComponentsFormatterStyle _style;
    BOOL _phonetic;
    NSLocale *_locale;
}

- (void)dealloc
{
    [_locale release];
    [super dealloc];
}

- (NSPersonNameComponentsFormatterStyle)style { return _style; }
- (void)setStyle:(NSPersonNameComponentsFormatterStyle)style { _style = style; }
- (BOOL)isPhonetic { return _phonetic; }
- (void)setPhonetic:(BOOL)phonetic { _phonetic = phonetic; }
- (NSLocale *)locale { return _locale ?: [NSLocale autoupdatingCurrentLocale]; }
- (void)setLocale:(NSLocale *)locale { [_locale autorelease]; _locale = [locale copy]; }

- (Pieces)_pieces:(NSPersonNameComponents *)c
{
    Pieces p = {[NSMutableArray array], [NSMutableArray array]};
    if (_phonetic && c.phoneticRepresentation)
        c = c.phoneticRepresentation;
    NSString *given = c.givenName, *family = c.familyName;
    if (is_cjk(given) || is_cjk(family)) {
        /* (family name first, no space between) */
        if (_style == NSPersonNameComponentsFormatterStyleAbbreviated) {
            [p.texts addObject:family.length ? family : given ?: @""];
            [p.keys addObject:family.length ? NSPersonNameComponentFamilyName : NSPersonNameComponentGivenName];
            return p;
        }
        if (family.length) {
            [p.texts addObject:family];
            [p.keys addObject:NSPersonNameComponentFamilyName];
        }
        if (given.length) {
            [p.texts addObject:given];
            [p.keys addObject:NSPersonNameComponentGivenName];
        }
        return p;
    }
    BOOL reversed = family_first(self.locale);
    switch (_style) {
    case NSPersonNameComponentsFormatterStyleShort:
        if (c.nickname.length)
            add(&p, c.nickname, NSPersonNameComponentNickname);
        else
            add(&p, given.length ? given : family, given.length ? NSPersonNameComponentGivenName : NSPersonNameComponentFamilyName);
        break;
    case NSPersonNameComponentsFormatterStyleLong:
        add(&p, c.namePrefix, NSPersonNameComponentPrefix);
        if (reversed) {
            add(&p, family, NSPersonNameComponentFamilyName);
            add(&p, given, NSPersonNameComponentGivenName);
            add(&p, c.middleName, NSPersonNameComponentMiddleName);
        } else {
            add(&p, given, NSPersonNameComponentGivenName);
            add(&p, c.middleName, NSPersonNameComponentMiddleName);
            add(&p, family, NSPersonNameComponentFamilyName);
        }
        add(&p, c.nameSuffix, NSPersonNameComponentSuffix);
        break;
    case NSPersonNameComponentsFormatterStyleAbbreviated: {
        NSString *a = initial(given), *b = initial(family);
        NSString *s = reversed ? [b stringByAppendingString:a] : [a stringByAppendingString:b];
        if (s.length) {
            [p.texts addObject:s];
            [p.keys addObject:NSPersonNameComponentGivenName];
        }
        break;
    }
    default:
        if (reversed) {
            add(&p, family, NSPersonNameComponentFamilyName);
            add(&p, given, NSPersonNameComponentGivenName);
        } else {
            add(&p, given, NSPersonNameComponentGivenName);
            add(&p, family, NSPersonNameComponentFamilyName);
        }
        break;
    }
    return p;
}

- (NSString *)stringFromPersonNameComponents:(NSPersonNameComponents *)components
{
    return [[self _pieces:components].texts componentsJoinedByString:@""];
}

- (NSAttributedString *)annotatedStringFromPersonNameComponents:(NSPersonNameComponents *)components
{
    Pieces p = [self _pieces:components];
    NSMutableAttributedString *s = [[[NSMutableAttributedString alloc] init] autorelease];
    for (NSUInteger i = 0; i < p.texts.count; i++)
        [s appendAttributedString:[[[NSAttributedString alloc] initWithString:p.texts[i] attributes:@{NSPersonNameComponentKey : p.keys[i]}]
                                      autorelease]];
    return s;
}

+ (NSString *)localizedStringFromPersonNameComponents:(NSPersonNameComponents *)components
                                                style:(NSPersonNameComponentsFormatterStyle)nameFormatStyle
                                              options:(NSPersonNameComponentsFormatterOptions)nameOptions
{
    NSPersonNameComponentsFormatter *f = [[self new] autorelease];
    f.style = nameFormatStyle;
    f.phonetic = (nameOptions & NSPersonNameComponentsFormatterPhonetic) != 0;
    return [f stringFromPersonNameComponents:components];
}

/* "Given Family", "Family, Given", with a title before and a suffix after; a name in
   CJK script as a given name. */
- (NSPersonNameComponents *)personNameComponentsFromString:(NSString *)string
{
    NSPersonNameComponents *c = [[NSPersonNameComponents new] autorelease];
    NSString *s = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length)
        return c;
    if (is_cjk(s)) {
        c.givenName = s;
        return c;
    }
    NSRange comma = [s rangeOfString:@","];
    if (comma.location != NSNotFound) {
        c.familyName = [[s substringToIndex:comma.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        c.givenName = [[s substringFromIndex:NSMaxRange(comma)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return c;
    }
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *w in [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
        if (w.length)
            [words addObject:w];
    NSArray *prefixes = @[ @"Dr.", @"Dr", @"Mr.", @"Mr", @"Mrs.", @"Mrs", @"Ms.", @"Ms", @"Miss", @"Prof.", @"Sir", @"Dame" ];
    NSArray *suffixes = @[ @"Jr.", @"Jr", @"Sr.", @"Sr", @"II", @"III", @"IV", @"PhD", @"Ph.D.", @"MD", @"M.D.", @"Esq." ];
    if (words.count > 1 && [prefixes containsObject:words.firstObject]) {
        c.namePrefix = words.firstObject;
        [words removeObjectAtIndex:0];
    }
    if (words.count > 1 && [suffixes containsObject:words.lastObject]) {
        c.nameSuffix = words.lastObject;
        [words removeLastObject];
    }
    if (words.count) {
        c.givenName = words.firstObject;
        if (words.count > 1)
            c.familyName = [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "];
    }
    return c;
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[NSPersonNameComponents class]] ? [self stringFromPersonNameComponents:obj] : nil;
}

- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error
{
    if (obj)
        *obj = [self personNameComponentsFromString:string];
    return YES;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSPersonNameComponentsFormatter *c = [[[self class] allocWithZone:zone] init];
    c.style = _style;
    c.phonetic = _phonetic;
    c.locale = _locale;
    return c;
}

@end

/* --- NSLocalizedFileSizeDescription --- */

/* (Apple's private SPI: flags carry NSByteCountFormatter's units in the low 16 bits,
   then binary counting, zero-padded fractions and the actual byte count) */
NSString *NSLocalizedFileSizeDescription(unsigned long long size, long unused, unsigned long flags);
NSString *_NSLocalizedFileSizeDescription(unsigned long long size, long unused, unsigned long flags);

NSString *
NSLocalizedFileSizeDescription(unsigned long long size, long unused, unsigned long flags)
{
    (void)unused;
    NSByteCountFormatter *f = [[NSByteCountFormatter new] autorelease];
    if (flags & 0xFFFF)
        f.allowedUnits = flags & 0xFFFF;
    f.countStyle = (flags & 0x100000) ? NSByteCountFormatterCountStyleBinary : NSByteCountFormatterCountStyleFile;
    f.zeroPadsFractionDigits = (flags & 0x1000000) != 0;
    f.includesActualByteCount = (flags & 0x4000000) != 0;
    return [f stringFromByteCount:(long long)size];
}

NSString *
_NSLocalizedFileSizeDescription(unsigned long long size, long unused, unsigned long flags)
{
    return NSLocalizedFileSizeDescription(size, unused, flags);
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSDateIntervalFormatter: "Nov 14 – Dec 24, 2023", through ICU's date interval formats
 * as Apple's. The skeleton ICU is asked for is the date template, or else the skeleton
 * of the pattern a date formatter has for the date and time styles ("M/d/yy, h:mm a"
 * gives "yyMdhmma"), so the interval reads as the formatter's single dates do.
 */
#import <Foundation/Foundation.h>

/* Apple's ICU (libicucore), declared here as CF declares what it uses. */
typedef uint16_t UChar;
typedef int UErrorCode;
typedef struct UDateIntervalFormat UDateIntervalFormat;
extern UDateIntervalFormat *udtitvfmt_open(const char *locale, const UChar *skeleton, int32_t skeletonLength, const UChar *tzID,
                                           int32_t tzIDLength, UErrorCode *status);
extern void udtitvfmt_close(UDateIntervalFormat *f);
extern int32_t udtitvfmt_format(const UDateIntervalFormat *f, double from, double to, UChar *result, int32_t capacity, void *position,
                                UErrorCode *status);
extern int32_t udatpg_getSkeleton(void *unused, const UChar *pattern, int32_t length, UChar *skeleton, int32_t capacity, UErrorCode *status);
#define U_FAILURE(e) ((e) > 0)

@implementation NSDateIntervalFormatter {
    NSLocale *_locale;
    NSCalendar *_calendar;
    NSTimeZone *_timeZone;
    NSString *_dateTemplate;
    NSDateIntervalFormatterStyle _dateStyle, _timeStyle;
    UDateIntervalFormat *_icu;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _dateStyle = NSDateIntervalFormatterShortStyle;
        _timeStyle = NSDateIntervalFormatterShortStyle;
    }
    return self;
}

- (void)forget
{
    if (_icu)
        udtitvfmt_close(_icu);
    _icu = NULL;
}

- (void)dealloc
{
    [self forget];
    [_locale release];
    [_calendar release];
    [_timeZone release];
    [_dateTemplate release];
    [super dealloc];
}

- (NSLocale *)locale { return _locale ?: [NSLocale currentLocale]; }
- (void)setLocale:(NSLocale *)l { [_locale autorelease]; _locale = [l retain]; [self forget]; }
- (NSCalendar *)calendar { return _calendar ?: [self.locale objectForKey:NSLocaleCalendar] ?: [NSCalendar currentCalendar]; }
- (void)setCalendar:(NSCalendar *)c { [_calendar autorelease]; _calendar = [c copy]; [self forget]; }
- (NSTimeZone *)timeZone { return _timeZone ?: [NSTimeZone defaultTimeZone]; }
- (void)setTimeZone:(NSTimeZone *)tz { [_timeZone autorelease]; _timeZone = [tz retain]; [self forget]; }
- (NSDateIntervalFormatterStyle)dateStyle { return _dateStyle; }
- (void)setDateStyle:(NSDateIntervalFormatterStyle)s { _dateStyle = s; [_dateTemplate release]; _dateTemplate = nil; [self forget]; }
- (NSDateIntervalFormatterStyle)timeStyle { return _timeStyle; }
- (void)setTimeStyle:(NSDateIntervalFormatterStyle)s { _timeStyle = s; [_dateTemplate release]; _dateTemplate = nil; [self forget]; }
- (void)setDateTemplate:(NSString *)t { [_dateTemplate autorelease]; _dateTemplate = [t copy]; [self forget]; }

/* The pattern a date formatter has for the styles. */
- (NSString *)stylePattern
{
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    f.locale = self.locale;
    f.calendar = self.calendar;
    f.dateStyle = (NSDateFormatterStyle)_dateStyle;
    f.timeStyle = (NSDateFormatterStyle)_timeStyle;
    return f.dateFormat;
}

- (NSString *)dateTemplate
{
    return _dateTemplate ?: [self stylePattern];
}

- (NSString *)skeleton
{
    if (_dateTemplate)
        return _dateTemplate;
    NSString *pattern = [self stylePattern];
    if (!pattern.length)
        return @"";
    NSUInteger n = pattern.length;
    UChar *p = malloc(n * sizeof(UChar)), out[128];
    [pattern getCharacters:p range:NSMakeRange(0, n)];
    UErrorCode e = 0;
    int32_t len = udatpg_getSkeleton(NULL, p, (int32_t)n, out, 128, &e);
    free(p);
    return U_FAILURE(e) ? @"" : [NSString stringWithCharacters:out length:len];
}

- (UDateIntervalFormat *)icu
{
    if (_icu)
        return _icu;
    NSString *skeleton = [self skeleton];
    if (!skeleton.length)
        return NULL;
    NSString *localeID = self.locale.localeIdentifier;
    NSString *cal = self.calendar.calendarIdentifier;
    if (cal && ![localeID containsString:@"@"])
        localeID = [localeID stringByAppendingFormat:@"@calendar=%@", cal];
    NSString *tz = self.timeZone.name;
    UChar sk[128], z[128];
    NSUInteger sl = MIN(skeleton.length, (NSUInteger)128), zl = MIN(tz.length, (NSUInteger)128);
    [skeleton getCharacters:sk range:NSMakeRange(0, sl)];
    [tz getCharacters:z range:NSMakeRange(0, zl)];
    UErrorCode e = 0;
    _icu = udtitvfmt_open(localeID.UTF8String, sk, (int32_t)sl, z, (int32_t)zl, &e);
    if (U_FAILURE(e))
        _icu = NULL;
    return _icu;
}

- (NSString *)stringFromDate:(NSDate *)fromDate toDate:(NSDate *)toDate
{
    if (!fromDate || !toDate)
        return nil;
    UDateIntervalFormat *f = [self icu];
    if (!f)
        return @"";
    UChar buf[512];
    UErrorCode e = 0;
    int32_t n = udtitvfmt_format(f, fromDate.timeIntervalSince1970 * 1000.0, toDate.timeIntervalSince1970 * 1000.0, buf, 512, NULL, &e);
    if (U_FAILURE(e))
        return @"";
    return [NSString stringWithCharacters:buf length:MIN(n, 512)];
}

- (NSString *)stringFromDateInterval:(NSDateInterval *)interval
{
    return [self stringFromDate:interval.startDate toDate:interval.endDate];
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[NSDateInterval class]] ? [self stringFromDateInterval:obj] : nil;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSDateIntervalFormatter *c = [[[self class] alloc] init];
    c->_locale = [_locale retain];
    c->_calendar = [_calendar copy];
    c->_timeZone = [_timeZone retain];
    c->_dateTemplate = [_dateTemplate copy];
    c->_dateStyle = _dateStyle;
    c->_timeStyle = _timeStyle;
    return c;
}

- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [self init])) {
        _locale = [[c decodeObjectOfClass:[NSLocale class] forKey:@"NS.locale"] retain];
        _calendar = [[c decodeObjectOfClass:[NSCalendar class] forKey:@"NS.calendar"] retain];
        _timeZone = [[c decodeObjectOfClass:[NSTimeZone class] forKey:@"NS.timeZone"] retain];
        _dateTemplate = [[c decodeObjectOfClass:[NSString class] forKey:@"NS.dateTemplate"] retain];
        if ([c containsValueForKey:@"NS.dateStyle"])
            _dateStyle = [c decodeIntegerForKey:@"NS.dateStyle"];
        if ([c containsValueForKey:@"NS.timeStyle"])
            _timeStyle = [c decodeIntegerForKey:@"NS.timeStyle"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_locale forKey:@"NS.locale"];
    [c encodeObject:_calendar forKey:@"NS.calendar"];
    [c encodeObject:_timeZone forKey:@"NS.timeZone"];
    [c encodeObject:_dateTemplate forKey:@"NS.dateTemplate"];
    [c encodeInteger:_dateStyle forKey:@"NS.dateStyle"];
    [c encodeInteger:_timeStyle forKey:@"NS.timeStyle"];
}

@end

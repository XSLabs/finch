/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * String, data and date methods Foundation's headers declare that Finch's classes
 * didn't have yet (tools/api-audit.sh): ICU transforms and folding, the localized
 * standard search, validated formats, encoding detection, path completion, property
 * lists from strings, data compression (libcompression's algorithms, as Apple's) and
 * search, and the calendar-format date strings, with NSCalendarDate.
 */
#import <Foundation/Foundation.h>
#include <compression.h>
#import <objc/message.h>

NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionSuggestedEncodingsKey = @"NSStringEncodingDetectionSuggestedEncodingsKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionUseOnlySuggestedEncodingsKey = @"NSStringEncodingDetectionUseOnlySuggestedEncodingsKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionAllowLossyKey = @"NSStringEncodingDetectionAllowLossyKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionFromWindowsKey = @"NSStringEncodingDetectionFromWindowsKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionLossySubstitutionKey = @"NSStringEncodingDetectionLossySubstitutionKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionDisallowedEncodingsKey = @"NSStringEncodingDetectionDisallowedEncodingsKey";
NSStringEncodingDetectionOptionsKey const NSStringEncodingDetectionLikelyLanguageKey = @"NSStringEncodingDetectionLikelyLanguageKey";

#pragma mark - Format specifiers

/* A format's conversions, in argument order, as kinds that must agree: an object, a C
   string, a pointer, a double, and integers by their length. */
static NSArray *
format_kinds(NSString *format)
{
    NSMutableArray *kinds = [NSMutableArray array];
    NSMutableDictionary *positional = [NSMutableDictionary dictionary];
    NSUInteger n = [format length], next = 1;
    for (NSUInteger i = 0; i < n; i++) {
        if ([format characterAtIndex:i] != '%')
            continue;
        if (++i >= n)
            return nil;
        unichar c = [format characterAtIndex:i];
        if (c == '%')
            continue;
        /* a position: digits then '$' */
        NSUInteger start = i, pos = 0;
        while (i < n && [format characterAtIndex:i] >= '0' && [format characterAtIndex:i] <= '9')
            pos = pos * 10 + ([format characterAtIndex:i++] - '0');
        if (!(i < n && [format characterAtIndex:i] == '$')) {
            i = start;
            pos = 0;
        } else
            i++;
        NSMutableString *length = [NSMutableString string];
        for (; i < n; i++) {
            c = [format characterAtIndex:i];
            if (strchr("-+ #0'123456789.*", c))
                continue;
            if (strchr("hlqLzjt", c)) {
                [length appendFormat:@"%C", c];
                continue;
            }
            break;
        }
        if (i >= n)
            return nil;
        NSString *kind;
        switch (c) {
        case '@': kind = @"object"; break;
        case 's': kind = [length isEqualToString:@"l"] ? @"wide string" : @"string"; break;
        case 'S': kind = @"wide string"; break;
        case 'p': kind = @"pointer"; break;
        case 'c': kind = @"char"; break;
        case 'C': kind = @"unichar"; break;
        case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A':
            kind = [length isEqualToString:@"L"] ? @"long double" : @"double";
            break;
        case 'd': case 'i': case 'o': case 'u': case 'x': case 'X': case 'D': case 'U': case 'O':
            kind = [NSString stringWithFormat:@"int%@", [length isEqualToString:@"q"] ? @"ll" : length];
            break;
        default: return nil;
        }
        [positional setObject:kind forKey:@(pos ?: next++)];
    }
    for (NSUInteger p = 1; p <= [positional count]; p++) {
        NSString *k = positional[@(p)];
        if (!k)
            return nil;
        [kinds addObject:k];
    }
    return kinds;
}

static BOOL
format_valid(NSString *format, NSString *valid, NSError **error)
{
    NSArray *a = format ? format_kinds(format) : nil, *b = valid ? format_kinds(valid) : nil;
    if (a && b && [a isEqualToArray:b])
        return YES;
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFormattingError
                                 userInfo:@{NSDebugDescriptionErrorKey : [NSString stringWithFormat:@"Format specifier types in '%@' don't match '%@'", format, valid]}];
    return NO;
}

#pragma mark - NSString

@implementation NSString (FinchAuditMethods)

- (instancetype)initWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid locale:(id)locale
                              arguments:(va_list)args error:(NSError **)error
{
    if (!format_valid(format, valid, error)) {
        [self release];
        return nil;
    }
    return [self initWithFormat:format locale:locale arguments:args];
}

- (instancetype)initWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid arguments:(va_list)args error:(NSError **)error
{
    return [self initWithValidatedFormat:format validFormatSpecifiers:valid locale:nil arguments:args error:error];
}

- (instancetype)initWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid locale:(id)locale error:(NSError **)error, ...
{
    va_list ap;
    va_start(ap, error);
    self = [self initWithValidatedFormat:format validFormatSpecifiers:valid locale:locale arguments:ap error:error];
    va_end(ap);
    return self;
}

- (instancetype)initWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid error:(NSError **)error, ...
{
    va_list ap;
    va_start(ap, error);
    self = [self initWithValidatedFormat:format validFormatSpecifiers:valid locale:nil arguments:ap error:error];
    va_end(ap);
    return self;
}

+ (instancetype)stringWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid error:(NSError **)error, ...
{
    va_list ap;
    va_start(ap, error);
    id s = [[self alloc] initWithValidatedFormat:format validFormatSpecifiers:valid locale:nil arguments:ap error:error];
    va_end(ap);
    return [s autorelease];
}

+ (instancetype)localizedStringWithValidatedFormat:(NSString *)format validFormatSpecifiers:(NSString *)valid error:(NSError **)error, ...
{
    va_list ap;
    va_start(ap, error);
    id s = [[self alloc] initWithValidatedFormat:format validFormatSpecifiers:valid locale:[NSLocale currentLocale] arguments:ap error:error];
    va_end(ap);
    return [s autorelease];
}

- (instancetype)initWithFormat:(NSString *)format locale:(id)locale, ...
{
    va_list ap;
    va_start(ap, locale);
    self = [self initWithFormat:format locale:locale arguments:ap];
    va_end(ap);
    return self;
}

/* (the bytes are copied; the deallocator is called once they're no longer needed: now) */
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)len encoding:(NSStringEncoding)encoding
                        deallocator:(void (^)(void *, NSUInteger))deallocator
{
    self = [self initWithBytes:bytes length:len encoding:encoding];
    if (deallocator)
        deallocator(bytes, len);
    return self;
}

- (instancetype)initWithCharactersNoCopy:(unichar *)chars length:(NSUInteger)len deallocator:(void (^)(unichar *, NSUInteger))deallocator
{
    self = [self initWithCharacters:chars length:len];
    if (deallocator)
        deallocator(chars, len);
    return self;
}

- (instancetype)initWithContentsOfFile:(NSString *)path usedEncoding:(NSStringEncoding *)enc error:(NSError **)error
{
    NSString *s = [NSString stringWithContentsOfFile:path usedEncoding:enc error:error];
    if (!s) {
        [self release];
        return nil;
    }
    return [self initWithString:s];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url usedEncoding:(NSStringEncoding *)enc error:(NSError **)error
{
    return [self initWithContentsOfFile:[url path] usedEncoding:enc error:error];
}

+ (instancetype)stringWithContentsOfURL:(NSURL *)url usedEncoding:(NSStringEncoding *)enc error:(NSError **)error
{
    return [[[self alloc] initWithContentsOfURL:url usedEncoding:enc error:error] autorelease];
}

/* ICU's transforms, by name or by Apple's NSStringTransform constants. */
- (NSString *)stringByApplyingTransform:(NSStringTransform)transform reverse:(BOOL)reverse
{
    NSMutableString *m = [[self mutableCopy] autorelease];
    if (!CFStringTransform((CFMutableStringRef)m, NULL, (CFStringRef)transform, reverse))
        return nil;
    return [[m copy] autorelease];
}

- (NSString *)stringByFoldingWithOptions:(NSStringCompareOptions)options locale:(NSLocale *)locale
{
    NSMutableString *m = [[self mutableCopy] autorelease];
    CFStringFold((CFMutableStringRef)m, (CFStringCompareFlags)options, (CFLocaleRef)locale);
    return [[m copy] autorelease];
}

/* As Apple's: case and diacritic insensitive, in the current locale. */
- (NSRange)localizedStandardRangeOfString:(NSString *)str
{
    return [self rangeOfString:str options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch range:NSMakeRange(0, [self length])
                        locale:[NSLocale currentLocale]];
}

- (BOOL)localizedStandardContainsString:(NSString *)str
{
    return [self localizedStandardRangeOfString:str].location != NSNotFound;
}

- (NSArray<NSString *> *)stringsByAppendingPaths:(NSArray<NSString *> *)paths
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[paths count]];
    for (NSString *p in paths)
        [out addObject:[self stringByAppendingPathComponent:p]];
    return out;
}

/* (only strings made from localized variants have others; this one is the only one) */
- (NSString *)variantFittingPresentationWidth:(NSInteger)width { return self; }

/* An old-style (OpenStep) or XML property list in the string. */
- (id)propertyList
{
    NSData *d = [self dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:NULL error:&error];
    if (!plist)
        [NSException raise:NSParseErrorException format:@"%@", [error localizedDescription] ?: @"bad property list"];
    return plist;
}

- (NSDictionary *)propertyListFromStringsFileFormat
{
    NSString *wrapped = [self hasPrefix:@"{"] ? self : [NSString stringWithFormat:@"{%@\n}", self];
    id plist = nil;
    @try {
        plist = [wrapped propertyList];
    } @catch (NSException *e) {
        return nil;
    }
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

/* The files in the path's directory whose names start with its last component (and
   have one of the extensions, when given); the completed path is their longest common
   prefix. The count of matches is returned. */
- (NSUInteger)completePathIntoString:(NSString **)outputName caseSensitive:(BOOL)flag
                    matchesIntoArray:(NSArray<NSString *> **)outputArray filterTypes:(NSArray<NSString *> *)filterTypes
{
    NSString *path = [self stringByExpandingTildeInPath];
    BOOL endsInSlash = [path hasSuffix:@"/"];
    NSString *dir = endsInSlash ? path : [path stringByDeletingLastPathComponent];
    NSString *prefix = endsInSlash ? @"" : [path lastPathComponent];
    if (![dir length])
        dir = @".";
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSStringCompareOptions opts = flag ? 0 : NSCaseInsensitiveSearch;
    for (NSString *name in names) {
        if ([prefix length] && [name rangeOfString:prefix options:opts | NSAnchoredSearch].location == NSNotFound)
            continue;
        if (filterTypes && ![filterTypes containsObject:[name pathExtension]])
            continue;
        [matches addObject:[dir stringByAppendingPathComponent:name]];
    }
    if (outputArray && [matches count])
        *outputArray = matches;
    if (outputName && [matches count]) {
        NSString *common = [[matches[0] lastPathComponent] copy];
        for (NSString *m in matches) {
            NSString *name = [m lastPathComponent];
            NSUInteger i = 0, n = MIN([common length], [name length]);
            while (i < n && [[common substringWithRange:NSMakeRange(i, 1)] compare:[name substringWithRange:NSMakeRange(i, 1)] options:opts] == NSOrderedSame)
                i++;
            NSString *shorter = [common substringToIndex:i];
            [common release];
            common = [shorter copy];
        }
        NSString *completed = [dir stringByAppendingPathComponent:common];
        [common release];
        BOOL isDir = NO;
        if ([matches count] == 1 && [[NSFileManager defaultManager] fileExistsAtPath:completed isDirectory:&isDir] && isDir)
            completed = [completed stringByAppendingString:@"/"];
        *outputName = completed;
    }
    return [matches count];
}

static BOOL
decodes(NSData *data, NSStringEncoding enc, NSString **out)
{
    NSString *s = [[[NSString alloc] initWithData:data encoding:enc] autorelease];
    if (s && out)
        *out = s;
    return s != nil;
}

/* The data's encoding: a byte-order mark's, the suggested encodings that decode it, then
   ASCII, UTF-8, and (when lossy conversion is allowed, as it is unless said otherwise)
   Windows Latin 1. 0 when none fits. */
+ (NSStringEncoding)stringEncodingForData:(NSData *)data encodingOptions:(NSDictionary<NSStringEncodingDetectionOptionsKey, id> *)opts
                          convertedString:(NSString **)string usedLossyConversion:(BOOL *)usedLossyConversion
{
    if (usedLossyConversion)
        *usedLossyConversion = NO;
    const uint8_t *b = [data bytes];
    NSUInteger n = [data length];
    NSStringEncoding found = 0;
    if (n >= 4 && ((b[0] == 0xFF && b[1] == 0xFE && b[2] == 0 && b[3] == 0) || (b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF)))
        found = NSUTF32StringEncoding;
    else if (n >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF)))
        found = NSUnicodeStringEncoding;
    else if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
        found = NSUTF8StringEncoding;
    if (found && decodes(data, found, string))
        return found;
    NSArray *disallowed = opts[NSStringEncodingDetectionDisallowedEncodingsKey];
    NSMutableArray *tries = [NSMutableArray arrayWithArray:opts[NSStringEncodingDetectionSuggestedEncodingsKey] ?: @[]];
    if (![opts[NSStringEncodingDetectionUseOnlySuggestedEncodingsKey] boolValue]) {
        BOOL ascii = YES;
        for (NSUInteger i = 0; i < n && ascii; i++)
            ascii = b[i] < 0x80;
        if (ascii)
            [tries insertObject:@(NSASCIIStringEncoding) atIndex:0];
        [tries addObject:@(NSUTF8StringEncoding)];
    }
    for (NSNumber *e in tries) {
        if ([disallowed containsObject:e])
            continue;
        if (decodes(data, [e unsignedIntegerValue], string))
            return [e unsignedIntegerValue];
    }
    NSNumber *lossy = opts[NSStringEncodingDetectionAllowLossyKey];
    if (!lossy || [lossy boolValue]) {
        NSStringEncoding fallback = [opts[NSStringEncodingDetectionFromWindowsKey] boolValue] ? NSWindowsCP1252StringEncoding
                                                                                                : NSMacOSRomanStringEncoding;
        if (decodes(data, fallback, string)) {
            if (usedLossyConversion)
                *usedLossyConversion = YES;
            return fallback;
        }
    }
    return 0;
}

@end

@implementation NSMutableString (FinchAuditMethods)

- (BOOL)applyTransform:(NSStringTransform)transform reverse:(BOOL)reverse range:(NSRange)range updatedRange:(NSRangePointer)resultingRange
{
    CFRange r = CFRangeMake((CFIndex)range.location, (CFIndex)range.length);
    BOOL ok = CFStringTransform((CFMutableStringRef)self, &r, (CFStringRef)transform, reverse);
    if (resultingRange)
        *resultingRange = ok ? NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length) : NSMakeRange(NSNotFound, 0);
    return ok;
}

@end

#pragma mark - NSData

static compression_algorithm
algorithm(NSDataCompressionAlgorithm a)
{
    switch (a) {
    case NSDataCompressionAlgorithmLZFSE: return COMPRESSION_LZFSE;
    case NSDataCompressionAlgorithmLZ4: return COMPRESSION_LZ4;
    case NSDataCompressionAlgorithmLZMA: return COMPRESSION_LZMA;
    case NSDataCompressionAlgorithmZlib: return COMPRESSION_ZLIB;
    }
    return COMPRESSION_LZFSE;
}

/* The whole input through a compression stream, the output grown as it fills. */
static NSData *
run_stream(NSData *input, compression_stream_operation op, NSDataCompressionAlgorithm alg, NSError **error)
{
    compression_stream s;
    if (compression_stream_init(&s, op, algorithm(alg)) != COMPRESSION_STATUS_OK)
        goto fail;
    {
        NSMutableData *out = [NSMutableData data];
        uint8_t buf[65536];
        s.src_ptr = [input bytes];
        s.src_size = [input length];
        compression_status st;
        do {
            s.dst_ptr = buf;
            s.dst_size = sizeof buf;
            st = compression_stream_process(&s, COMPRESSION_STREAM_FINALIZE);
            if (st == COMPRESSION_STATUS_ERROR)
                break;
            [out appendBytes:buf length:sizeof buf - s.dst_size];
        } while (st == COMPRESSION_STATUS_OK);
        compression_stream_destroy(&s);
        if (st == COMPRESSION_STATUS_END && !(op == COMPRESSION_STREAM_DECODE && [input length] && ![out length]))
            return out;
    }
fail:
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:op == COMPRESSION_STREAM_ENCODE ? NSCompressionFailedError : NSDecompressionFailedError
                                 userInfo:nil];
    return nil;
}

@implementation NSData (FinchAuditMethods)

- (instancetype)compressedDataUsingAlgorithm:(NSDataCompressionAlgorithm)alg error:(NSError **)error
{
    return (id)run_stream(self, COMPRESSION_STREAM_ENCODE, alg, error);
}

- (instancetype)decompressedDataUsingAlgorithm:(NSDataCompressionAlgorithm)alg error:(NSError **)error
{
    return (id)run_stream(self, COMPRESSION_STREAM_DECODE, alg, error);
}

- (NSRange)rangeOfData:(NSData *)dataToFind options:(NSDataSearchOptions)mask range:(NSRange)searchRange
{
    if (NSMaxRange(searchRange) > [self length])
        [NSException raise:NSRangeException format:@"*** -[NSData rangeOfData:options:range:]: range %@ exceeds data length %lu",
                                                   NSStringFromRange(searchRange), (unsigned long)[self length]];
    NSUInteger n = [dataToFind length];
    if (!n || n > searchRange.length)
        return NSMakeRange(NSNotFound, 0);
    const uint8_t *hay = [self bytes], *needle = [dataToFind bytes];
    BOOL back = (mask & NSDataSearchBackwards) != 0, anchored = (mask & NSDataSearchAnchored) != 0;
    NSUInteger first = searchRange.location, last = NSMaxRange(searchRange) - n;
    if (anchored) {
        NSUInteger at = back ? last : first;
        return memcmp(hay + at, needle, n) ? NSMakeRange(NSNotFound, 0) : NSMakeRange(at, n);
    }
    for (NSUInteger k = 0; k <= last - first; k++) {
        NSUInteger at = back ? last - k : first + k;
        if (!memcmp(hay + at, needle, n))
            return NSMakeRange(at, n);
    }
    return NSMakeRange(NSNotFound, 0);
}

@end

@implementation NSMutableData (FinchAuditMethods)

- (BOOL)compressUsingAlgorithm:(NSDataCompressionAlgorithm)alg error:(NSError **)error
{
    NSData *z = run_stream(self, COMPRESSION_STREAM_ENCODE, alg, error);
    if (z)
        [self setData:z];
    return z != nil;
}

- (BOOL)decompressUsingAlgorithm:(NSDataCompressionAlgorithm)alg error:(NSError **)error
{
    NSData *z = run_stream(self, COMPRESSION_STREAM_DECODE, alg, error);
    if (z)
        [self setData:z];
    return z != nil;
}

@end

#pragma mark - Calendar formats

static NSCalendar *
gregorian_in(NSTimeZone *tz)
{
    NSCalendar *c = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    [c setTimeZone:tz ?: [NSTimeZone defaultTimeZone]];
    return c;
}

/* A date in an NSCalendarDate format (strftime's conversions, %F milliseconds). */
static NSString *
format_date(NSDate *date, NSString *format, NSTimeZone *tz, id locale)
{
    tz = tz ?: [NSTimeZone defaultTimeZone];
    NSDateComponents *c = [gregorian_in(tz) components:NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                          NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond |
                                                          NSCalendarUnitWeekday | NSCalendarUnitNanosecond
                                              fromDate:date];
    NSLocale *loc = [locale isKindOfClass:[NSLocale class]] ? locale : [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *names = [[[NSDateFormatter alloc] init] autorelease];
    [names setLocale:loc];
    NSInteger dayOfYear = [gregorian_in(tz) ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:date];
    NSMutableString *out = [NSMutableString string];
    NSUInteger n = [format length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar ch = [format characterAtIndex:i];
        if (ch != '%' || i + 1 >= n) {
            [out appendFormat:@"%C", ch];
            continue;
        }
        unichar f = [format characterAtIndex:++i];
        NSInteger offset = [tz secondsFromGMTForDate:date];
        switch (f) {
        case '%': [out appendString:@"%"]; break;
        case 'a': [out appendString:[names shortWeekdaySymbols][c.weekday - 1]]; break;
        case 'A': [out appendString:[names weekdaySymbols][c.weekday - 1]]; break;
        case 'b': [out appendString:[names shortMonthSymbols][c.month - 1]]; break;
        case 'B': [out appendString:[names monthSymbols][c.month - 1]]; break;
        case 'c': [out appendString:format_date(date, @"%a %b %d %H:%M:%S %Z %Y", tz, locale)]; break;
        case 'd': [out appendFormat:@"%02ld", (long)c.day]; break;
        case 'e': [out appendFormat:@"%ld", (long)c.day]; break;
        case 'F': [out appendFormat:@"%03ld", (long)(c.nanosecond / 1000000)]; break;
        case 'H': [out appendFormat:@"%02ld", (long)c.hour]; break;
        case 'I': [out appendFormat:@"%02ld", (long)(c.hour % 12 ?: 12)]; break;
        case 'j': [out appendFormat:@"%03ld", (long)dayOfYear]; break;
        case 'm': [out appendFormat:@"%02ld", (long)c.month]; break;
        case 'M': [out appendFormat:@"%02ld", (long)c.minute]; break;
        case 'p': [out appendString:c.hour < 12 ? [names AMSymbol] : [names PMSymbol]]; break;
        case 'S': [out appendFormat:@"%02ld", (long)c.second]; break;
        case 'w': [out appendFormat:@"%ld", (long)(c.weekday - 1)]; break;
        case 'x': [out appendString:format_date(date, @"%m/%d/%y", tz, locale)]; break;
        case 'X': [out appendString:format_date(date, @"%H:%M:%S", tz, locale)]; break;
        case 'y': [out appendFormat:@"%02ld", (long)(c.year % 100)]; break;
        case 'Y': [out appendFormat:@"%ld", (long)c.year]; break;
        case 'Z': [out appendString:[tz abbreviationForDate:date] ?: [tz name]]; break;
        case 'z':
            [out appendFormat:@"%c%02ld%02ld", offset < 0 ? '-' : '+', (long)(labs(offset) / 3600), (long)(labs(offset) / 60 % 60)];
            break;
        default: [out appendFormat:@"%%%C", f]; break;
        }
    }
    return out;
}

/* A string read by an NSCalendarDate format; nil when it doesn't fit. */
static NSDate *
parse_date(NSString *string, NSString *format, id locale, NSTimeZone **zoneOut)
{
    NSDateFormatter *names = [[[NSDateFormatter alloc] init] autorelease];
    [names setLocale:[locale isKindOfClass:[NSLocale class]] ? locale : [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSScanner *sc = [NSScanner scannerWithString:string];
    [sc setCharactersToBeSkipped:nil];
    [sc setCaseSensitive:NO];
    NSInteger year = 2001, month = 1, day = 1, hour = 0, minute = 0, second = 0, ms = 0;
    BOOL pm = NO, ampm = NO;
    NSTimeZone *tz = nil;
    NSUInteger n = [format length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar ch = [format characterAtIndex:i];
        if (ch != '%' || i + 1 >= n) {
            if (ch == ' ') {
                [sc scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
                continue;
            }
            if (![sc scanString:[NSString stringWithCharacters:&ch length:1] intoString:NULL])
                return nil;
            continue;
        }
        unichar f = [format characterAtIndex:++i];
        NSInteger v = 0;
        switch (f) {
        case 'Y': case 'y': case 'm': case 'd': case 'e': case 'H': case 'I': case 'M': case 'S': case 'j': case 'F':
            if (![sc scanInteger:&v])
                return nil;
            if (f == 'Y') year = v;
            else if (f == 'y') year = v < 70 ? 2000 + v : 1900 + v;
            else if (f == 'm') month = v;
            else if (f == 'd' || f == 'e') day = v;
            else if (f == 'H' || f == 'I') hour = v;
            else if (f == 'M') minute = v;
            else if (f == 'S') second = v;
            else if (f == 'F') ms = v;
            else if (f == 'j') { month = 1; day = v; }
            break;
        case 'b': case 'B': {
            BOOL found = NO;
            for (NSArray *list in @[ [names monthSymbols], [names shortMonthSymbols] ])
                for (NSUInteger k = 0; k < [list count] && !found; k++)
                    if ([sc scanString:list[k] intoString:NULL]) {
                        month = (NSInteger)k + 1;
                        found = YES;
                    }
            if (!found)
                return nil;
            break;
        }
        case 'a': case 'A': {
            BOOL found = NO;
            for (NSArray *list in @[ [names weekdaySymbols], [names shortWeekdaySymbols] ])
                for (NSString *w in list)
                    if (!found && [sc scanString:w intoString:NULL])
                        found = YES;
            if (!found)
                return nil;
            break;
        }
        case 'p':
            ampm = YES;
            if ([sc scanString:[names PMSymbol] intoString:NULL])
                pm = YES;
            else if (![sc scanString:[names AMSymbol] intoString:NULL])
                return nil;
            break;
        case 'z': {
            NSString *sign = nil;
            if (![sc scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-"] intoString:&sign] || ![sc scanInteger:&v])
                return nil;
            NSInteger secs = (v / 100) * 3600 + (v % 100) * 60;
            tz = [NSTimeZone timeZoneForSecondsFromGMT:[sign isEqualToString:@"-"] ? -secs : secs];
            break;
        }
        case 'Z': {
            NSString *name = nil;
            if (![sc scanCharactersFromSet:[[NSCharacterSet whitespaceCharacterSet] invertedSet] intoString:&name])
                return nil;
            tz = [NSTimeZone timeZoneWithAbbreviation:name] ?: [NSTimeZone timeZoneWithName:name];
            break;
        }
        case '%':
            if (![sc scanString:@"%" intoString:NULL])
                return nil;
            break;
        default: return nil;
        }
    }
    if (ampm && pm && hour < 12)
        hour += 12;
    else if (ampm && !pm && hour == 12)
        hour = 0;
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    c.year = year, c.month = month, c.day = day, c.hour = hour, c.minute = minute, c.second = second;
    c.nanosecond = ms * 1000000;
    if (zoneOut)
        *zoneOut = tz;
    return [gregorian_in(tz) dateFromComponents:c];
}

#pragma mark - NSDate

@implementation NSDate (FinchAuditMethods)

+ (instancetype)dateWithString:(NSString *)aString
{
    return [[[self alloc] initWithString:aString] autorelease];
}

/* "YYYY-MM-DD HH:MM:SS ±HHMM", as -description writes it. */
- (instancetype)initWithString:(NSString *)description
{
    NSDate *d = description ? parse_date(description, @"%Y-%m-%d %H:%M:%S %z", nil, NULL) : nil;
    if (!d) {
        [self release];
        return nil;
    }
    return [self initWithTimeIntervalSinceReferenceDate:[d timeIntervalSinceReferenceDate]];
}

- (id)addTimeInterval:(NSTimeInterval)seconds { return [self dateByAddingTimeInterval:seconds]; }

/* As Apple's: the description without a locale, the full date and time with one. */
- (NSString *)descriptionWithLocale:(id)locale
{
    if (!locale)
        return [self description];
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    [f setLocale:[locale isKindOfClass:[NSLocale class]] ? locale : [NSLocale currentLocale]];
    [f setDateStyle:NSDateFormatterFullStyle];
    [f setTimeStyle:NSDateFormatterFullStyle];
    return [f stringFromDate:self];
}

- (NSString *)descriptionWithCalendarFormat:(NSString *)format timeZone:(NSTimeZone *)aTimeZone locale:(id)locale
{
    return format_date(self, format ?: @"%Y-%m-%d %H:%M:%S %z", aTimeZone, locale);
}

- (NSCalendarDate *)dateWithCalendarFormat:(NSString *)format timeZone:(NSTimeZone *)aTimeZone
{
    NSCalendarDate *c = [[[NSCalendarDate alloc] initWithTimeIntervalSinceReferenceDate:[self timeIntervalSinceReferenceDate]] autorelease];
    [c setCalendarFormat:format];
    [c setTimeZone:aTimeZone];
    return c;
}

/* Dates as people write them: the formats -description and ISO 8601 use, "today",
   "tomorrow", "yesterday" and "now", and whatever a data detector finds. */
+ (id)dateWithNaturalLanguageString:(NSString *)string locale:(id)locale
{
    NSString *s = [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (![s length])
        return nil;
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDictionary *words = @{@"now" : @0, @"today" : @0, @"tomorrow" : @1, @"yesterday" : @-1};
    if (words[s]) {
        if ([s isEqualToString:@"now"])
            return now;
        NSDate *noon = [cal dateBySettingHour:12 minute:0 second:0 ofDate:now options:0];
        return [cal dateByAddingUnit:NSCalendarUnitDay value:[words[s] integerValue] toDate:noon options:0];
    }
    for (NSString *f in @[ @"%Y-%m-%d %H:%M:%S %z", @"%Y-%m-%d %H:%M:%S", @"%Y-%m-%d %H:%M", @"%Y-%m-%d", @"%m/%d/%Y", @"%d %B %Y", @"%B %d, %Y" ]) {
        NSDate *d = parse_date(string, f, locale, NULL);
        if (d)
            return d;
    }
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:NULL];
    NSTextCheckingResult *r = [detector firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    return [r date];
}

+ (id)dateWithNaturalLanguageString:(NSString *)string
{
    return [self dateWithNaturalLanguageString:string locale:nil];
}

@end

#pragma mark - NSCalendarDate

/* A date with its own time zone and format (deprecated, as Apple's, but still declared). */
@implementation NSCalendarDate {
    NSTimeInterval _interval;
    NSTimeZone *_finchZone;
    NSString *_finchFormat;
}

+ (id)calendarDate { return [[[self alloc] init] autorelease]; }

- (instancetype)init
{
    return [self initWithTimeIntervalSinceReferenceDate:[NSDate timeIntervalSinceReferenceDate]];
}

/* (NSDate's -init comes back here, so the object is set up as NSObject's) */
- (instancetype)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti
{
    struct objc_super root = {self, [NSObject class]};
    if ((self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&root, @selector(init))))
        _interval = ti;
    return self;
}

- (void)dealloc
{
    [_finchZone release];
    [_finchFormat release];
    [super dealloc];
}

- (NSTimeInterval)timeIntervalSinceReferenceDate { return _interval; }

+ (id)dateWithString:(NSString *)description calendarFormat:(NSString *)format locale:(id)locale
{
    return [[[self alloc] initWithString:description calendarFormat:format locale:locale] autorelease];
}

+ (id)dateWithString:(NSString *)description calendarFormat:(NSString *)format
{
    return [self dateWithString:description calendarFormat:format locale:nil];
}

+ (id)dateWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute
            second:(NSUInteger)second timeZone:(NSTimeZone *)aTimeZone
{
    return [[[self alloc] initWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:aTimeZone] autorelease];
}

- (id)initWithString:(NSString *)description calendarFormat:(NSString *)format locale:(id)locale
{
    NSTimeZone *tz = nil;
    NSDate *d = description && format ? parse_date(description, format, locale, &tz) : nil;
    if (!d) {
        [self release];
        return nil;
    }
    self = [self initWithTimeIntervalSinceReferenceDate:[d timeIntervalSinceReferenceDate]];
    [self setCalendarFormat:format];
    [self setTimeZone:tz];
    return self;
}

- (id)initWithString:(NSString *)description calendarFormat:(NSString *)format
{
    return [self initWithString:description calendarFormat:format locale:nil];
}

- (id)initWithString:(NSString *)description
{
    return [self initWithString:description calendarFormat:@"%Y-%m-%d %H:%M:%S %z" locale:nil];
}

- (id)initWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute
            second:(NSUInteger)second timeZone:(NSTimeZone *)aTimeZone
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    c.year = year, c.month = (NSInteger)month, c.day = (NSInteger)day, c.hour = (NSInteger)hour, c.minute = (NSInteger)minute,
    c.second = (NSInteger)second;
    self = [self initWithTimeIntervalSinceReferenceDate:[[gregorian_in(aTimeZone) dateFromComponents:c] timeIntervalSinceReferenceDate]];
    [self setTimeZone:aTimeZone];
    return self;
}

- (NSString *)calendarFormat { return _finchFormat ?: @"%Y-%m-%d %H:%M:%S %z"; }

- (void)setCalendarFormat:(NSString *)format
{
    [_finchFormat autorelease];
    _finchFormat = [format copy];
}

- (NSTimeZone *)timeZone { return _finchZone ?: [NSTimeZone defaultTimeZone]; }

- (void)setTimeZone:(NSTimeZone *)aTimeZone
{
    [_finchZone autorelease];
    _finchZone = [aTimeZone retain];
}

- (NSDateComponents *)_finchComponents
{
    return [gregorian_in([self timeZone]) components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
                                                     NSCalendarUnitMinute | NSCalendarUnitSecond | NSCalendarUnitWeekday
                                            fromDate:self];
}

- (NSInteger)yearOfCommonEra { return [[self _finchComponents] year]; }
- (NSInteger)monthOfYear { return [[self _finchComponents] month]; }
- (NSInteger)dayOfMonth { return [[self _finchComponents] day]; }
- (NSInteger)dayOfWeek { return [[self _finchComponents] weekday] - 1; }
- (NSInteger)hourOfDay { return [[self _finchComponents] hour]; }
- (NSInteger)minuteOfHour { return [[self _finchComponents] minute]; }
- (NSInteger)secondOfMinute { return [[self _finchComponents] second]; }
- (NSInteger)dayOfYear { return [gregorian_in([self timeZone]) ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:self]; }
- (NSInteger)dayOfCommonEra { return [gregorian_in([self timeZone]) ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitEra forDate:self]; }

- (NSCalendarDate *)dateByAddingYears:(NSInteger)year months:(NSInteger)month days:(NSInteger)day hours:(NSInteger)hour
                              minutes:(NSInteger)minute seconds:(NSInteger)second
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    c.year = year, c.month = month, c.day = day, c.hour = hour, c.minute = minute, c.second = second;
    NSDate *d = [gregorian_in([self timeZone]) dateByAddingComponents:c toDate:self options:0];
    NSCalendarDate *out = [[[NSCalendarDate alloc] initWithTimeIntervalSinceReferenceDate:[d timeIntervalSinceReferenceDate]] autorelease];
    [out setCalendarFormat:_finchFormat];
    [out setTimeZone:_finchZone];
    return out;
}

- (void)years:(NSInteger *)yp months:(NSInteger *)mop days:(NSInteger *)dp hours:(NSInteger *)hp minutes:(NSInteger *)mip
      seconds:(NSInteger *)sp sinceDate:(NSCalendarDate *)date
{
    NSCalendarUnit units = 0;
    if (yp) units |= NSCalendarUnitYear;
    if (mop) units |= NSCalendarUnitMonth;
    if (dp) units |= NSCalendarUnitDay;
    if (hp) units |= NSCalendarUnitHour;
    if (mip) units |= NSCalendarUnitMinute;
    if (sp) units |= NSCalendarUnitSecond;
    NSDateComponents *c = [gregorian_in([self timeZone]) components:units fromDate:date toDate:self options:0];
    if (yp) *yp = c.year;
    if (mop) *mop = c.month;
    if (dp) *dp = c.day;
    if (hp) *hp = c.hour;
    if (mip) *mip = c.minute;
    if (sp) *sp = c.second;
}

- (NSString *)description { return [self descriptionWithCalendarFormat:[self calendarFormat] timeZone:[self timeZone] locale:nil]; }
- (NSString *)descriptionWithLocale:(id)locale { return [self descriptionWithCalendarFormat:[self calendarFormat] timeZone:[self timeZone] locale:locale]; }
- (NSString *)descriptionWithCalendarFormat:(NSString *)format locale:(id)locale
{
    return [self descriptionWithCalendarFormat:format timeZone:[self timeZone] locale:locale];
}
- (NSString *)descriptionWithCalendarFormat:(NSString *)format
{
    return [self descriptionWithCalendarFormat:format timeZone:[self timeZone] locale:nil];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSCalendarDate *c = [[NSCalendarDate allocWithZone:zone] initWithTimeIntervalSinceReferenceDate:_interval];
    [c setCalendarFormat:_finchFormat];
    [c setTimeZone:_finchZone];
    return c;
}

@end

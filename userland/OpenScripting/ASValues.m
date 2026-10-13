/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's AppleScript: values, coercions, comparison and the display form, as AppleScript
 * shows them (osascript -s s, Script Editor's result): integers within AppleScript's range,
 * reals to 12 significant digits with E notation outside 0.01..10000, text quoted, lists
 * and records in braces, dates as date "Wednesday, January 1, 2020 at 12:00:00 AM".
 */
#import "ASValues.h"
#include <math.h>

NSArray *ASTextItemDelimiters;
BOOL ASConsiderCase;

@implementation ASError
+ (instancetype)errorWithNumber:(NSInteger)number message:(NSString *)message
{
    ASError *e = [[ASError alloc] initWithName:@"ASError" reason:message userInfo:nil];
    e.number = number;
    return e;
}
@end

@implementation ASList
+ (instancetype)listWithArray:(NSArray *)a
{
    ASList *l = [ASList new];
    l.items = [a mutableCopy] ?: [NSMutableArray array];
    return l;
}
- (instancetype)init
{
    if ((self = [super init]))
        _items = [NSMutableArray array];
    return self;
}
- (NSUInteger)count { return _items.count; }
- (id)objectAtIndex:(NSUInteger)i { return _items[i]; }
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained[])buffer count:(NSUInteger)len
{
    return [_items countByEnumeratingWithState:state objects:buffer count:len];
}
@end

@implementation ASRecord
- (instancetype)init
{
    if ((self = [super init])) {
        _keys = [NSMutableArray array];
        _values = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)setValue:(id)v forField:(NSString *)k
{
    NSString *key = k.lowercaseString;
    if (!_values[key])
        [_keys addObject:k];
    _values[key] = v;
}
- (id)valueForField:(NSString *)k { return _values[k.lowercaseString]; }
@end

@implementation ASConstant
+ (instancetype)constant:(NSString *)name
{
    static NSMutableDictionary *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ all = [NSMutableDictionary dictionary]; });
    @synchronized(all) {
        ASConstant *c = all[name];
        if (!c) {
            c = [ASConstant new];
            c.name = name;
            all[name] = c;
        }
        return c;
    }
}
+ (instancetype)classNamed:(NSString *)name
{
    ASConstant *c = [self constant:name];
    c.isClass = YES;
    return c;
}
+ (instancetype)missingValue { return [self constant:@"missing value"]; }
@end

@implementation ASFile
@end
@implementation ASApplication
@end
@implementation ASHandler
@end

/* ---- kinds ---- */

/* booleans: the CFBoolean singletons, or a number made from a BOOL */
BOOL
ASIsBoolean(id v)
{
    if (![v isKindOfClass:[NSNumber class]])
        return NO;
    if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
        return YES;
    const char *t = [v objCType];
    return t[0] == 'c' || t[0] == 'B';
}

BOOL
ASIsReal(id v)
{
    if (![v isKindOfClass:[NSNumber class]] || ASIsBoolean(v))
        return NO;
    const char *t = [v objCType];
    return t[0] == 'd' || t[0] == 'f';
}

BOOL ASIsInteger(id v) { return [v isKindOfClass:[NSNumber class]] && !ASIsBoolean(v) && !ASIsReal(v); }
BOOL ASIsNumber(id v) { return ASIsInteger(v) || ASIsReal(v); }

NSString *
ASClassName(id v)
{
    if (ASIsBoolean(v)) return @"boolean";
    if (ASIsInteger(v)) return @"integer";
    if (ASIsReal(v)) return @"real";
    if ([v isKindOfClass:[NSString class]]) return @"text";
    if ([v isKindOfClass:[ASList class]]) return @"list";
    if ([v isKindOfClass:[ASRecord class]]) return @"record";
    if ([v isKindOfClass:[NSDate class]]) return @"date";
    if ([v isKindOfClass:[ASFile class]]) return ((ASFile *)v).isAlias ? @"alias" : @"«class furl»";
    if ([v isKindOfClass:[ASApplication class]]) return @"application";
    if ([v isKindOfClass:[ASHandler class]]) return @"handler";
    if ([v isKindOfClass:[ASConstant class]])
        return ((ASConstant *)v).isClass ? @"class" : v == [ASConstant missingValue] ? @"class" : @"constant";
    return @"item";
}

id
ASMakeInteger(long long n)
{
    if (n > INT32_MAX || n < INT32_MIN)
        return @((double)n);
    return @(n);
}

id ASMakeReal(double d) { return [NSNumber numberWithDouble:d]; }

static ASError *
cant_make(id v, NSString *cls)
{
    ASError *e = [ASError errorWithNumber:-1700
                                  message:[NSString stringWithFormat:@"Can’t make %@ into type %@.", ASDisplay(v), cls]];
    e.offendingObject = v;
    e.expectedType = cls;
    return e;
}

/* ---- formatting ---- */

NSString *
ASFormatReal(double d)
{
    if (isinf(d))
        return d > 0 ? @"1.79769313486E+308" : @"-1.79769313486E+308";
    double a = fabs(d);
    if (a != 0 && (a >= 1e4 || a < 0.01)) {
        int exp = (int)floor(log10(a));
        double mant = d / pow(10, exp);
        /* rounding can carry the mantissa to 10 */
        NSString *m = [NSString stringWithFormat:@"%.11g", mant];
        if ([m hasPrefix:@"10"] || [m hasPrefix:@"-10"]) {
            exp++;
            m = [NSString stringWithFormat:@"%.11g", d / pow(10, exp)];
        }
        if ([m rangeOfString:@"."].location == NSNotFound)
            m = [m stringByAppendingString:@".0"];
        return [NSString stringWithFormat:@"%@E%@%d", m, exp >= 0 ? @"+" : @"-", abs(exp)];
    }
    NSString *s = [NSString stringWithFormat:@"%.12g", d];
    if ([s rangeOfString:@"."].location == NSNotFound && [s rangeOfString:@"e"].location == NSNotFound)
        s = [s stringByAppendingString:@".0"];
    return s;
}

static NSString *
date_text(NSDate *d)
{
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"EEEE, MMMM d, y 'at' h:mm:ss\u202Fa";
    });
    return [f stringFromDate:d];
}

NSString *
ASHFSPath(NSString *posix)
{
    NSString *volume = @"Macintosh HD";
    NSString *p = [posix stringByResolvingSymlinksInPath];
    if ([p isEqualToString:@"/tmp"] || [p hasPrefix:@"/tmp/"])
        p = [@"/private" stringByAppendingString:p];
    NSArray *parts = [p componentsSeparatedByString:@"/"];
    NSMutableArray *out = [NSMutableArray arrayWithObject:volume];
    for (NSString *c in parts)
        if (c.length)
            [out addObject:[c stringByReplacingOccurrencesOfString:@":" withString:@"/"]];
    NSString *h = [out componentsJoinedByString:@":"];
    if ([posix hasSuffix:@"/"] || out.count == 1)
        h = [h stringByAppendingString:@":"];
    return h;
}

static NSString *
quote(NSString *s)
{
    NSMutableString *m = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '"' || c == '\\')
            [m appendFormat:@"\\%C", c];
        else
            [m appendFormat:@"%C", c];
    }
    [m appendString:@"\""];
    return m;
}

NSString *
ASDisplay(id v)
{
    if (!v)
        return @"";
    if (ASIsBoolean(v))
        return [v boolValue] ? @"true" : @"false";
    if (ASIsInteger(v))
        return [NSString stringWithFormat:@"%lld", [v longLongValue]];
    if (ASIsReal(v))
        return ASFormatReal([v doubleValue]);
    if ([v isKindOfClass:[NSString class]])
        return quote(v);
    if ([v isKindOfClass:[ASList class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id x in v)
            [parts addObject:ASDisplay(x)];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    if ([v isKindOfClass:[ASRecord class]]) {
        ASRecord *r = v;
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in r.keys)
            [parts addObject:[NSString stringWithFormat:@"%@:%@", k, ASDisplay([r valueForField:k])]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    if ([v isKindOfClass:[NSDate class]])
        return [NSString stringWithFormat:@"date \"%@\"", date_text(v)];
    if ([v isKindOfClass:[ASFile class]])
        return [NSString stringWithFormat:@"%@ \"%@\"", ((ASFile *)v).isAlias ? @"alias" : @"file", ASHFSPath(((ASFile *)v).path)];
    if ([v isKindOfClass:[ASApplication class]])
        return [NSString stringWithFormat:@"application \"%@\"", ((ASApplication *)v).name];
    if ([v isKindOfClass:[ASConstant class]])
        return ((ASConstant *)v).name;
    if ([v isKindOfClass:[ASHandler class]])
        return [NSString stringWithFormat:@"«handler %@»", ((ASHandler *)v).name];
    return [v description];
}

/* ---- coercions ---- */

NSString *
ASText(id v)
{
    if ([v isKindOfClass:[NSString class]])
        return v;
    if (ASIsBoolean(v))
        return [v boolValue] ? @"true" : @"false";
    if (ASIsInteger(v))
        return [NSString stringWithFormat:@"%lld", [v longLongValue]];
    if (ASIsReal(v))
        return ASFormatReal([v doubleValue]);
    if ([v isKindOfClass:[ASList class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id x in v)
            [parts addObject:ASText(x)];
        NSString *d = ASTextItemDelimiters.count ? ASText(ASTextItemDelimiters[0]) : @"";
        return [parts componentsJoinedByString:d];
    }
    if ([v isKindOfClass:[NSDate class]])
        return date_text(v);
    if ([v isKindOfClass:[ASFile class]])
        return ASHFSPath(((ASFile *)v).path);
    if ([v isKindOfClass:[ASConstant class]] && v != [ASConstant missingValue])
        return ((ASConstant *)v).name;
    @throw cant_make(v, @"text");
}

id
ASNumberValue(id v)
{
    if (ASIsNumber(v))
        return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSScanner *sc = [NSScanner scannerWithString:s];
        long long i;
        if ([sc scanLongLong:&i] && sc.isAtEnd)
            return ASMakeInteger(i);
        sc = [NSScanner scannerWithString:s];
        double d;
        if ([sc scanDouble:&d] && sc.isAtEnd)
            return ASMakeReal(d);
    }
    if ([v isKindOfClass:[ASList class]] && [v count] == 1)
        return ASNumberValue([v objectAtIndex:0]);
    @throw cant_make(v, @"number");
}

long long
ASInteger(id v)
{
    id n = ASNumberValue(v);
    if (ASIsReal(n)) {
        double d = [n doubleValue];
        /* AppleScript rounds to the nearest integer, halves to even */
        return (long long)nearbyint(d);
    }
    return [n longLongValue];
}

double ASReal(id v) { return [ASNumberValue(v) doubleValue]; }

BOOL
ASBool(id v)
{
    if (ASIsBoolean(v))
        return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        if ([v caseInsensitiveCompare:@"true"] == NSOrderedSame)
            return YES;
        if ([v caseInsensitiveCompare:@"false"] == NSOrderedSame)
            return NO;
    }
    if ([v isKindOfClass:[ASList class]] && [v count] == 1)
        return ASBool([v objectAtIndex:0]);
    @throw cant_make(v, @"boolean");
}

ASList *
ASListValue(id v)
{
    if ([v isKindOfClass:[ASList class]])
        return v;
    if ([v isKindOfClass:[ASRecord class]]) {
        ASRecord *r = v;
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *k in r.keys)
            [a addObject:[r valueForField:k]];
        return [ASList listWithArray:a];
    }
    return [ASList listWithArray:@[ v ]];
}

id
ASCoerce(id v, NSString *cls)
{
    cls = cls.lowercaseString;
    if ([cls isEqualToString:@"text"] || [cls isEqualToString:@"string"] || [cls isEqualToString:@"unicode text"])
        return ASText(v);
    if ([cls isEqualToString:@"integer"])
        return ASMakeInteger(ASInteger(v));
    if ([cls isEqualToString:@"real"])
        return ASMakeReal(ASReal(v));
    if ([cls isEqualToString:@"number"])
        return ASNumberValue(v);
    if ([cls isEqualToString:@"boolean"])
        return ASBoolean(ASBool(v));
    if ([cls isEqualToString:@"list"])
        return ASListValue(v);
    if ([cls isEqualToString:@"date"]) {
        if ([v isKindOfClass:[NSDate class]])
            return v;
        @throw cant_make(v, @"date");
    }
    if ([cls isEqualToString:@"record"]) {
        if ([v isKindOfClass:[ASRecord class]])
            return v;
        @throw cant_make(v, @"record");
    }
    if ([cls isEqualToString:@"alias"] || [cls isEqualToString:@"file"] || [cls isEqualToString:@"posix file"]) {
        if ([v isKindOfClass:[ASFile class]])
            return v;
        NSString *t = ASText(v);
        ASFile *f = [ASFile new];
        /* HFS path text: Volume:a:b */
        if ([t rangeOfString:@":"].location != NSNotFound && ![t hasPrefix:@"/"]) {
            NSArray *parts = [t componentsSeparatedByString:@":"];
            NSMutableArray *p = [NSMutableArray array];
            for (NSUInteger i = 1; i < parts.count; i++)
                if ([parts[i] length])
                    [p addObject:parts[i]];
            t = [@"/" stringByAppendingString:[p componentsJoinedByString:@"/"]];
        }
        f.path = t;
        f.isAlias = [cls isEqualToString:@"alias"];
        if (f.isAlias && ![[NSFileManager defaultManager] fileExistsAtPath:t])
            @throw cant_make(v, @"alias");
        return f;
    }
    @throw cant_make(v, cls);
}

/* ---- comparison ---- */

BOOL
ASEqual(id a, id b)
{
    if (ASIsNumber(a) && ASIsNumber(b))
        return [a doubleValue] == [b doubleValue];
    if (ASIsBoolean(a) && ASIsBoolean(b))
        return [a boolValue] == [b boolValue];
    if ([a isKindOfClass:[NSString class]] && [b isKindOfClass:[NSString class]])
        return ASConsiderCase ? [a isEqualToString:b] : [a caseInsensitiveCompare:b] == NSOrderedSame;
    if ([a isKindOfClass:[ASList class]] && [b isKindOfClass:[ASList class]]) {
        if ([a count] != [b count])
            return NO;
        for (NSUInteger i = 0; i < [a count]; i++)
            if (!ASEqual([a objectAtIndex:i], [b objectAtIndex:i]))
                return NO;
        return YES;
    }
    if ([a isKindOfClass:[ASRecord class]] && [b isKindOfClass:[ASRecord class]]) {
        ASRecord *x = a, *y = b;
        if (x.keys.count != y.keys.count)
            return NO;
        for (NSString *k in x.keys)
            if (![y valueForField:k] || !ASEqual([x valueForField:k], [y valueForField:k]))
                return NO;
        return YES;
    }
    if ([a isKindOfClass:[NSDate class]] && [b isKindOfClass:[NSDate class]])
        return [a isEqualToDate:b];
    if ([a isKindOfClass:[ASFile class]] && [b isKindOfClass:[ASFile class]])
        return [((ASFile *)a).path isEqualToString:((ASFile *)b).path];
    if ([a isKindOfClass:[ASApplication class]] && [b isKindOfClass:[ASApplication class]])
        return [((ASApplication *)a).name caseInsensitiveCompare:((ASApplication *)b).name] == NSOrderedSame;
    return a == b;
}

NSComparisonResult
ASCompare(id a, id b)
{
    if (ASIsNumber(a)) {
        double x = [a doubleValue], y = ASReal(b);
        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }
    if ([a isKindOfClass:[NSString class]])
        return ASConsiderCase ? [a localizedCompare:ASText(b)] : [a localizedCaseInsensitiveCompare:ASText(b)];
    if ([a isKindOfClass:[NSDate class]] && [b isKindOfClass:[NSDate class]])
        return [a compare:b];
    @throw [ASError errorWithNumber:-1703
                            message:[NSString stringWithFormat:@"Can’t compare %@ with %@.", ASDisplay(a), ASDisplay(b)]];
}

id
ASDeepCopy(id v)
{
    if ([v isKindOfClass:[ASList class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in v)
            [a addObject:ASDeepCopy(x)];
        return [ASList listWithArray:a];
    }
    if ([v isKindOfClass:[ASRecord class]]) {
        ASRecord *r = v, *c = [ASRecord new];
        for (NSString *k in r.keys)
            [c setValue:ASDeepCopy([r valueForField:k]) forField:k];
        return c;
    }
    return v;
}

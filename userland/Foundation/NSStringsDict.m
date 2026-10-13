// SPDX-License-Identifier: MIT OR Apache-2.0
/*
 * Strings with plural (stringsdict) rules. A localized string whose table entry is a
 * dictionary comes back as __NSLocalizedString, as Apple's does: its text is the entry's
 * NSStringLocalizedFormatKey ("%#@files@ in %#@folders@"), and it carries the entry, so
 * formatting it picks each variable's variant ("one": "%d file", "other": "%d files") by
 * the language's plural rules (ICU's) for the variable's argument.
 *
 * The expansion is a plain format CF formats: every specifier made positional, and each
 * %#@variable@ replaced by its variant, whose specifiers take the variable's argument.
 */
#import "Foundation_Finch.h"
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdarg.h>

/* Apple's ICU (libicucore), declared as CF declares what it uses */
typedef uint16_t UChar;
typedef int UErrorCode;
typedef void UPluralRules;
#define U_FAILURE(e) ((e) > 0)
extern UPluralRules *uplrules_open(const char *locale, UErrorCode *status);
extern int32_t uplrules_select(const UPluralRules *rules, double number, UChar *keyword, int32_t capacity,
                               UErrorCode *status);
extern void uplrules_close(UPluralRules *rules);

@interface __NSLocalizedString : NSString {
    NSString *_string;
    NSDictionary *_config;
    NSString *_language;
}
- (instancetype)_finchInitWithString:(NSString *)string config:(NSDictionary *)config language:(NSString *)language;
- (NSDictionary *)_finchConfig;
- (NSString *)_finchLanguage;
- (NSString *)_finchString;
@end

@implementation __NSLocalizedString
- (instancetype)_finchInitWithString:(NSString *)string config:(NSDictionary *)config language:(NSString *)language
{
    if ((self = [super init])) {
        _string = [string copy];
        _config = [config copy];
        _language = [language copy];
    }
    return self;
}
- (void)dealloc
{
    [_string release];
    [_config release];
    [_language release];
    [super dealloc];
}
- (NSUInteger)length { return [_string length]; }
- (unichar)characterAtIndex:(NSUInteger)index { return [_string characterAtIndex:index]; }
- (void)getCharacters:(unichar *)buffer range:(NSRange)range { [_string getCharacters:buffer range:range]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSDictionary *)_finchConfig { return _config; }
- (NSString *)_finchLanguage { return _language; }
- (NSString *)_finchString { return _string; }
@end

/* A table entry as a string: a plural entry as __NSLocalizedString; anything else not a
   string, nil. */
NSString *
FinchLocalizedStringFromEntry(id entry, NSString *language)
{
    if ([entry isKindOfClass:[NSString class]])
        return entry;
    if (![entry isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *format = [entry objectForKey:@"NSStringLocalizedFormatKey"];
    if (![format isKindOfClass:[NSString class]])
        return nil;
    return [[[__NSLocalizedString alloc] _finchInitWithString:format config:entry language:language] autorelease];
}

/* MARK: - Specifiers */

enum { ARG_INT, ARG_LONG, ARG_LLONG, ARG_DOUBLE, ARG_LDOUBLE, ARG_PTR };

typedef struct {
    NSRange range;       /* the whole specifier, % included */
    int arg;             /* its value's argument (1-based), 0 for %% */
    int widthArg, precisionArg; /* a * width's or precision's argument, or 0 */
    int type;
    NSString *variable;  /* %#@variable@ */
    NSString *rewritten; /* positional */
} Spec;

/* The argument type of a length and conversion ("lld"; "f") */
static int
arg_type(NSString *length, unichar conversion)
{
    switch (conversion) {
    case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A':
        return [length isEqualToString:@"L"] ? ARG_LDOUBLE : ARG_DOUBLE;
    case 's': case 'S': case 'p': case '@': case 'n':
        return ARG_PTR;
    default:
        if ([length isEqualToString:@"ll"] || [length isEqualToString:@"q"])
            return ARG_LLONG;
        if ([length isEqualToString:@"l"] || [length isEqualToString:@"z"] || [length isEqualToString:@"t"] ||
            [length isEqualToString:@"j"])
            return ARG_LONG;
        return ARG_INT;
    }
}

/* The specifiers of a format, their arguments numbered from *next (sequential ones). */
static NSArray *
parse_specs(NSString *format, int *next)
{
    NSMutableArray *specs = [NSMutableArray array];
    NSUInteger n = [format length];
    for (NSUInteger i = 0; i < n; i++) {
        if ([format characterAtIndex:i] != '%')
            continue;
        NSUInteger start = i++;
        if (i < n && [format characterAtIndex:i] == '%') {
            continue;
        }
        Spec s = {0};
        /* N$ */
        NSUInteger j = i;
        int number = 0;
        while (j < n && [format characterAtIndex:j] >= '0' && [format characterAtIndex:j] <= '9')
            number = number * 10 + ([format characterAtIndex:j++] - '0');
        int explicitArg = 0;
        if (j < n && j > i && [format characterAtIndex:j] == '$') {
            explicitArg = number;
            i = j + 1;
        }
        NSMutableString *body = [NSMutableString string]; /* the specifier after % and N$ */
        BOOL hash = NO;
        while (i < n && strchr("-+ #0'", (char)[format characterAtIndex:i]) && [format characterAtIndex:i] < 128) {
            if ([format characterAtIndex:i] == '#')
                hash = YES;
            [body appendFormat:@"%C", [format characterAtIndex:i++]];
        }
        if (hash && i < n && [format characterAtIndex:i] == '@') {
            NSRange close = [format rangeOfString:@"@" options:0 range:NSMakeRange(i + 1, n - i - 1)];
            if (close.location == NSNotFound)
                break;
            s.variable = [format substringWithRange:NSMakeRange(i + 1, close.location - i - 1)];
            s.arg = explicitArg ?: (*next)++;
            s.range = NSMakeRange(start, close.location + 1 - start);
            [specs addObject:[NSValue valueWithBytes:&s objCType:@encode(Spec)]];
            i = close.location;
            continue;
        }
        /* width */
        NSString *width = @"", *precision = nil;
        if (i < n && [format characterAtIndex:i] == '*') {
            i++;
            int w = 0;
            NSUInteger k = i;
            while (k < n && [format characterAtIndex:k] >= '0' && [format characterAtIndex:k] <= '9')
                w = w * 10 + ([format characterAtIndex:k++] - '0');
            if (k < n && k > i && [format characterAtIndex:k] == '$')
                i = k + 1;
            else
                w = (*next)++;
            s.widthArg = w;
            width = [NSString stringWithFormat:@"*%d$", w];
        } else {
            NSUInteger k = i;
            while (k < n && [format characterAtIndex:k] >= '0' && [format characterAtIndex:k] <= '9')
                k++;
            width = [format substringWithRange:NSMakeRange(i, k - i)];
            i = k;
        }
        /* precision */
        if (i < n && [format characterAtIndex:i] == '.') {
            i++;
            if (i < n && [format characterAtIndex:i] == '*') {
                i++;
                int p = 0;
                NSUInteger k = i;
                while (k < n && [format characterAtIndex:k] >= '0' && [format characterAtIndex:k] <= '9')
                    p = p * 10 + ([format characterAtIndex:k++] - '0');
                if (k < n && k > i && [format characterAtIndex:k] == '$')
                    i = k + 1;
                else
                    p = (*next)++;
                s.precisionArg = p;
                precision = [NSString stringWithFormat:@".*%d$", p];
            } else {
                NSUInteger k = i;
                while (k < n && [format characterAtIndex:k] >= '0' && [format characterAtIndex:k] <= '9')
                    k++;
                precision = [NSString stringWithFormat:@".%@", [format substringWithRange:NSMakeRange(i, k - i)]];
                i = k;
            }
        }
        /* length and conversion */
        NSUInteger k = i;
        while (k < n && strchr("hlqLztj", (char)[format characterAtIndex:k]) && [format characterAtIndex:k] < 128)
            k++;
        if (k >= n)
            break;
        NSString *length = [format substringWithRange:NSMakeRange(i, k - i)];
        unichar conversion = [format characterAtIndex:k];
        s.arg = explicitArg ?: (*next)++;
        s.type = arg_type(length, conversion);
        s.range = NSMakeRange(start, k + 1 - start);
        s.rewritten = [NSString stringWithFormat:@"%%%d$%@%@%@%@%C", s.arg, body, width, precision ?: @"", length, conversion];
        [specs addObject:[NSValue valueWithBytes:&s objCType:@encode(Spec)]];
        i = k;
    }
    return specs;
}

static Spec
spec_at(NSArray *specs, NSUInteger i)
{
    Spec s;
    [[specs objectAtIndex:i] getValue:&s];
    return s;
}

/* A variable's value type, from its NSStringFormatValueTypeKey ("lld", "d", "f") */
static int
variable_type(NSDictionary *variable)
{
    NSString *t = [variable objectForKey:@"NSStringFormatValueTypeKey"];
    if (![t isKindOfClass:[NSString class]] || ![t length])
        return ARG_INT;
    return arg_type([t substringToIndex:[t length] - 1], [t characterAtIndex:[t length] - 1]);
}

/* The plural category of a number in a language: ICU's ("one", "few", "other"). */
static NSString *
plural_category(double number, NSString *language)
{
    UErrorCode status = 0;
    UPluralRules *rules = uplrules_open([language ?: @"en" UTF8String], &status);
    if (!rules || U_FAILURE(status)) {
        if (rules)
            uplrules_close(rules);
        return number == 1 ? @"one" : @"other";
    }
    UChar keyword[32];
    int32_t len = uplrules_select(rules, number, keyword, 32, &status);
    uplrules_close(rules);
    if (U_FAILURE(status) || len <= 0)
        return @"other";
    return [NSString stringWithCharacters:keyword length:(NSUInteger)len];
}

/* The format with each variable replaced by its variant, every specifier positional; nil
   when there's nothing to expand. */
static NSString *
expand(NSString *format, NSDictionary *config, NSString *language, va_list args)
{
    int next = 1;
    NSArray *specs = parse_specs(format, &next);
    BOOL any = NO;
    int maxArg = 0;
    int types[64];
    for (int i = 0; i < 64; i++)
        types[i] = ARG_INT;
    for (NSUInteger i = 0; i < [specs count]; i++) {
        Spec s = spec_at(specs, i);
        if (s.variable) {
            any = YES;
            NSDictionary *v = [config objectForKey:s.variable];
            if (s.arg < 64)
                types[s.arg] = [v isKindOfClass:[NSDictionary class]] ? variable_type(v) : ARG_INT;
        } else if (s.arg < 64) {
            types[s.arg] = s.type;
        }
        maxArg = MAX(maxArg, MAX(s.arg, MAX(s.widthArg, s.precisionArg)));
    }
    if (!any || maxArg >= 64)
        return nil;
    /* the arguments' values, as numbers for the plural rules */
    double values[64] = {0};
    va_list walk;
    va_copy(walk, args);
    for (int a = 1; a <= maxArg; a++) {
        switch (types[a]) {
        case ARG_INT: values[a] = va_arg(walk, int); break;
        case ARG_LONG: values[a] = (double)va_arg(walk, long); break;
        case ARG_LLONG: values[a] = (double)va_arg(walk, long long); break;
        case ARG_DOUBLE: values[a] = va_arg(walk, double); break;
        case ARG_LDOUBLE: values[a] = (double)va_arg(walk, long double); break;
        default: (void)va_arg(walk, void *); break;
        }
    }
    va_end(walk);
    NSMutableString *out = [NSMutableString string];
    NSUInteger at = 0;
    for (NSUInteger i = 0; i < [specs count]; i++) {
        Spec s = spec_at(specs, i);
        [out appendString:[format substringWithRange:NSMakeRange(at, s.range.location - at)]];
        at = NSMaxRange(s.range);
        if (!s.variable) {
            [out appendString:s.rewritten];
            continue;
        }
        NSDictionary *v = [config objectForKey:s.variable];
        NSString *variant = nil;
        if ([v isKindOfClass:[NSDictionary class]]) {
            double number = values[s.arg];
            if (number == 0)
                variant = [v objectForKey:@"zero"];
            if (!variant)
                variant = [v objectForKey:plural_category(number, language)];
            if (!variant)
                variant = [v objectForKey:@"other"];
        }
        if (![variant isKindOfClass:[NSString class]])
            continue;
        /* the variant's specifiers take the variable's argument */
        int unused = s.arg;
        NSArray *inner = parse_specs(variant, &unused);
        NSUInteger vat = 0;
        for (NSUInteger k = 0; k < [inner count]; k++) {
            Spec t = spec_at(inner, k);
            [out appendString:[variant substringWithRange:NSMakeRange(vat, t.range.location - vat)]];
            vat = NSMaxRange(t.range);
            if (t.variable)
                continue; /* nested variables aren't expanded */
            NSString *spec = t.rewritten;
            /* positional on the variable's argument */
            NSRange dollar = [spec rangeOfString:@"$"];
            if (dollar.location != NSNotFound)
                spec = [NSString stringWithFormat:@"%%%d%@", s.arg, [spec substringFromIndex:dollar.location]];
            [out appendString:spec];
        }
        [out appendString:[variant substringFromIndex:vat]];
    }
    [out appendString:[format substringFromIndex:at]];
    return out;
}

/* A format to give CF: a localized plural format expanded for its arguments, or itself. */
CFStringRef
FinchExpandLocalizedFormat(CFStringRef format, va_list args)
{
    id f = (id)format;
    if (![f isKindOfClass:[__NSLocalizedString class]])
        return format;
    NSString *expanded = expand([f _finchString], [f _finchConfig], [f _finchLanguage], args);
    return expanded ? (CFStringRef)expanded : format;
}

/* An attributed string made from a plural format keeps the format, for formatting it. */
static const char k_localized_format;

void
FinchAttachLocalizedFormat(NSAttributedString *attributed, NSString *format)
{
    if (attributed && [format isKindOfClass:[__NSLocalizedString class]] && [[attributed string] isEqualToString:format])
        objc_setAssociatedObject(attributed, &k_localized_format, format, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NSString *
FinchLocalizedFormatOf(NSAttributedString *attributed)
{
    NSString *format = objc_getAssociatedObject(attributed, &k_localized_format);
    return format ?: [attributed string];
}

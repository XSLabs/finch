/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSMeasurementFormatter (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSMeasurementFormatter.h>, and NSUnitFormatter, Apple's
 * private class that does the work. As Apple's, it formats through ICU's
 * measure formats (Apple's uameasfmt API in libicucore), so the strings are
 * ICU's: each unit carries the ICU measure unit it stands for (its
 * specifier, NSUnit.m). Without NSMeasurementFormatterUnitOptionsProvidedUnit
 * a value is converted to the unit ICU prefers for the locale and the
 * unit's usage (road distances, body weight, food energy, weather...);
 * natural scale then picks the unit within that unit's measurement system
 * (+[NSDimension _measurementWithNaturalScale:system:]).
 *
 * The number formatter's settings reach ICU as Apple's clone of its ICU
 * formatter does: a decimal format made from its pattern and rounding mode.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"
#include <math.h>

/* Apple's ICU (libicucore), declared here as CF declares what it uses. */
typedef uint16_t UChar;
typedef int UErrorCode;
typedef struct UAMeasureFormat UAMeasureFormat;
typedef struct {
    double value;
    int unit;
} UAMeasure;
typedef struct UNumberFormat UNumberFormat;
extern UNumberFormat *unum_open(int style, const UChar *pattern, int32_t patternLength, const char *locale, void *parseError, UErrorCode *status);
extern void unum_setAttribute(UNumberFormat *fmt, int attr, int32_t value);
extern void unum_close(UNumberFormat *fmt);
extern UAMeasureFormat *uameasfmt_open(const char *locale, int width, UNumberFormat *nfToAdopt, UErrorCode *status);
extern void uameasfmt_close(UAMeasureFormat *fmt);
extern int32_t uameasfmt_format(const UAMeasureFormat *fmt, double value, int unit, UChar *result, int32_t capacity, UErrorCode *status);
extern int32_t uameasfmt_formatMultiple(const UAMeasureFormat *fmt, const UAMeasure *measures, int32_t measureCount, UChar *result, int32_t capacity, UErrorCode *status);
extern int32_t uameasfmt_getUnitName(const UAMeasureFormat *fmt, int unit, UChar *result, int32_t capacity, UErrorCode *status);
extern int32_t uameasfmt_getUnitsForUsage(const char *locale, const char *category, const char *usage, int *units, int32_t capacity, UErrorCode *status);
enum { UNUM_PATTERN_DECIMAL = 0, UNUM_ROUNDING_MODE = 11 };
enum { UAMEASFMT_WIDTH_WIDE = 0, UAMEASFMT_WIDTH_SHORT = 1, UAMEASFMT_WIDTH_NARROW = 2 };
#define U_FAILURE(e) ((e) > 0)

/* ICU measure units Foundation names. */
enum {
    TEMPERATURE_CELSIUS = 0xa00, TEMPERATURE_FAHRENHEIT = 0xa01, TEMPERATURE_KELVIN = 0xa02, TEMPERATURE_GENERIC = 0xa03,
};

@interface NSDimension (FinchPrivate)
- (NSInteger)specifier;
+ (NSString *)icuType;
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)measurement system:(NSInteger)system;
@end

@interface NSNumberFormatter (FinchPrivate)
- (CFNumberFormatterRef)_finchFormatter;
@end

@interface NSUnitFormatter : NSFormatter <NSSecureCoding> {
    NSNumberFormatter *_numberFormatter;
    NSMeasurementFormatterUnitOptions _unitOptions;
    NSFormattingUnitStyle _unitStyle;
    UAMeasureFormat *_formatter;
    NSString *_formatterKey;   /* what _formatter was made from */
    NSLocale *_locale;
    NSString *_usageOverride;
    BOOL _hasUsageOverride;
    BOOL _allowsMultipleUnits;
}
@property NSMeasurementFormatterUnitOptions unitOptions;
@property NSFormattingUnitStyle unitStyle;
@property (copy) NSLocale *locale;
@property (copy) NSNumberFormatter *numberFormatter;
- (NSString *)stringFromUnit:(NSUnit *)unit;
- (NSString *)stringForValue:(double)value unit:(NSInteger)unit;
- (NSString *)stringForMeasurements:(const UAMeasure *)measures count:(int32_t)count;
- (NSString *)usageOverride;
- (void)setUsageOverride:(NSString *)usage;
- (BOOL)hasUsageOverride;
- (void)setHasUsageOverride:(BOOL)hasOverride;
- (BOOL)allowsMultipleUnits;
- (void)setAllowsMultipleUnits:(BOOL)allows;
- (int)determineUnitsToFormat:(int *)units fromMeasurement:(NSMeasurement *)measurement;
@end

static BOOL
has_specifier(NSUnit *unit)
{
    return [unit isKindOfClass:[NSDimension class]] && [(NSDimension *)unit specifier] != -1;
}

/* The measurement system of an ICU unit (0 metric, 1 UK, 2 US), as
 * Apple's table has it; 3 for the units it doesn't list. */
static NSInteger
system_of(int unit)
{
    switch (unit) {
    case 0x200: case 0x201: case 0x205: case 0x206: return 0;
    case 0x202: case 0x203: case 0x204: case 0x207: case 0x208: return 2;
    case 0x500: case 0x501: case 0x502: case 0x503: case 0x504: case 0x50a: case 0x50b: case 0x50c: return 0;
    case 0x505: case 0x506: case 0x507: case 0x508: case 0x50d: case 0x50e: case 0x50f: return 2;
    case 0x600: case 0x601: case 0x605: case 0x606: case 0x607: case 0x609: return 0;
    case 0x602: case 0x603: case 0x608: return 2;
    case 0x604: case 0x60a: return 1;
    case 0x700: case 0x701: case 0x703: case 0x704: case 0x705: return 0;
    case 0x702: return 2;
    case 0x800: case 0x802: case 0x806: case 0x807: case 0x809: return 0;
    case 0x801: case 0x804: return 2;
    case 0x900: case 0x901: return 0;
    case 0x902: return 2;
    case 0xb18: return 1;
    case 0xc02: case 0xc04: return 0;
    case 0xc00: case 0xc01: case 0xc03: return 2;
    case 0xd00: return 0;
    case 0xd01: return 2;
    case 0xd03: return 1;
    case 0xf00: case 0xf01: case 0xf02: case 0xf03: return 0;
    case 0x1000: case 0x1001: case 0x1002: case 0x1003: case 0x1100: case 0x1202: return 0;
    }
    if (unit >= 0xb00 && unit <= 0xb09) return 0;
    if (unit >= 0xb0a && unit <= 0xb15) return 2;
    return 3;
}

/* The temperature unit the user chose in System Settings (Apple's
 * +[NSLocale _preferredTemperatureUnit]), or nil. */
static NSString *
preferred_temperature_unit(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("AppleTemperatureUnit"), kCFPreferencesAnyApplication);
    if (v && CFGetTypeID(v) != CFStringGetTypeID()) {
        CFRelease(v);
        v = NULL;
    }
    return [(NSString *)v autorelease];
}

/* What ICU's usage preferences are asked for, by unit (Apple's choices). */
static const char *
usage_for(int spec)
{
    if (spec == 0x1201 || spec == 0x1202 || spec == 0x1209) return "blood-glucose";
    if ((spec & ~3) == 0xd00) return "vehicle-fuel";
    if (spec >= 0x400 && spec < 0x40a) return "";
    if (spec >= 0xc00 && spec < 0xc06) return "food";
    if (spec >= 0x500 && spec < 0x513) return "road";
    if (spec >= 0x600 && spec < 0x60b) return "person";
    if (spec >= 0x800 && spec <= 0x809 && ((0x2df >> (spec - 0x800)) & 1)) return "baromtrc";
    if ((spec & ~3) == 0x900) return "road-travel";
    if (spec >= 0xa00 && spec < 0xa03) return "weather";
    if (spec >= 0xb00 && spec <= 0xb18 && ((0x17fffbf >> (spec - 0xb00)) & 1)) return "vehicle-fuel";
    return NULL;
}

@implementation NSUnitFormatter

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) _unitStyle = NSFormattingUnitStyleMedium;
    return self;
}

- (void)dealloc
{
    if (_formatter) uameasfmt_close(_formatter);
    [_formatterKey release];
    [_numberFormatter release];
    [_locale release];
    [_usageOverride release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSUnitFormatter *c = [[[self class] alloc] init];
    c->_unitOptions = _unitOptions;
    c->_unitStyle = _unitStyle;
    c->_locale = [_locale copy];
    c->_numberFormatter = [_numberFormatter copy];
    c->_usageOverride = [_usageOverride copy];
    c->_hasUsageOverride = _hasUsageOverride;
    c->_allowsMultipleUnits = _allowsMultipleUnits;
    return c;
}

- (NSMeasurementFormatterUnitOptions)unitOptions { return _unitOptions; }
- (void)setUnitOptions:(NSMeasurementFormatterUnitOptions)o { _unitOptions = o; }
- (NSFormattingUnitStyle)unitStyle { return _unitStyle; }
- (void)setUnitStyle:(NSFormattingUnitStyle)s { _unitStyle = s; }
- (NSLocale *)locale { return _locale ? _locale : [NSLocale currentLocale]; }
- (NSString *)usageOverride { return _usageOverride; }
- (void)setUsageOverride:(NSString *)usage
{
    NSString *old = _usageOverride;
    _usageOverride = [usage copy];
    [old release];
}
- (BOOL)hasUsageOverride { return _hasUsageOverride; }
- (void)setHasUsageOverride:(BOOL)hasOverride { _hasUsageOverride = hasOverride; }
- (BOOL)allowsMultipleUnits { return _allowsMultipleUnits; }
- (void)setAllowsMultipleUnits:(BOOL)allows { _allowsMultipleUnits = allows; }

- (void)setLocale:(NSLocale *)locale
{
    NSLocale *o = _locale;
    _locale = [locale copy];
    [o release];
    [_numberFormatter setLocale:[self locale]];
}

/* A copy, as Apple's: changing it doesn't change the formatter. */
- (NSNumberFormatter *)numberFormatter { return [[[self _numberFormatter] copy] autorelease]; }

- (NSNumberFormatter *)_numberFormatter
{
    if (!_numberFormatter) {
        _numberFormatter = [[NSNumberFormatter alloc] init];
        [_numberFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
        [_numberFormatter setLocale:[self locale]];
    }
    return _numberFormatter;
}

- (void)setNumberFormatter:(NSNumberFormatter *)nf
{
    NSNumberFormatter *o = _numberFormatter;
    _numberFormatter = [nf copy];
    [o release];
}

/* The ICU measure format for the current settings, made again when they
 * change. */
- (UAMeasureFormat *)_measureFormat
{
    NSNumberFormatter *nf = [self _numberFormatter];
    NSString *pattern = (NSString *)CFNumberFormatterGetFormat([nf _finchFormatter]);
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu|%ld", [[self locale] localeIdentifier], [[nf locale] localeIdentifier],
        pattern, (unsigned long)[nf roundingMode], (long)_unitStyle];
    if (_formatter && [key isEqualToString:_formatterKey]) return _formatter;
    if (_formatter) uameasfmt_close(_formatter);
    _formatter = NULL;
    [_formatterKey release];
    _formatterKey = [key retain];

    UErrorCode err = 0;
    NSUInteger n = [pattern length];
    UChar *chars = malloc((n + 1) * sizeof(UChar));
    [pattern getCharacters:chars range:NSMakeRange(0, n)];
    UNumberFormat *unf = unum_open(UNUM_PATTERN_DECIMAL, chars, (int32_t)n, [[[nf locale] localeIdentifier] UTF8String], NULL, &err);
    free(chars);
    if (U_FAILURE(err)) return NULL;
    unum_setAttribute(unf, UNUM_ROUNDING_MODE, (int32_t)[nf roundingMode]);
    int width = _unitStyle == NSFormattingUnitStyleShort ? UAMEASFMT_WIDTH_NARROW
              : _unitStyle == NSFormattingUnitStyleLong ? UAMEASFMT_WIDTH_WIDE : UAMEASFMT_WIDTH_SHORT;
    _formatter = uameasfmt_open([[[self locale] localeIdentifier] UTF8String], width, unf, &err);
    if (U_FAILURE(err)) _formatter = NULL;
    return _formatter;
}

- (NSString *)stringForValue:(double)value unit:(NSInteger)unit
{
    UAMeasureFormat *f = [self _measureFormat];
    if (!f) return nil;
    UChar buf[100];
    UErrorCode err = 0;
    int32_t n = uameasfmt_format(f, value, (int)unit, buf, 100, &err);
    if (n > 100) {
        UChar *big = malloc(n * sizeof(UChar));
        err = 0;
        uameasfmt_format(f, value, (int)unit, big, n, &err);
        NSString *s = U_FAILURE(err) ? nil : [NSString stringWithCharacters:big length:n];
        free(big);
        return s;
    }
    return U_FAILURE(err) ? nil : [NSString stringWithCharacters:buf length:n];
}

- (NSString *)stringForMeasurements:(const UAMeasure *)measures count:(int32_t)count
{
    UAMeasureFormat *f = [self _measureFormat];
    if (!f || count < 1) return nil;
    UChar buf[128];
    UErrorCode err = 0;
    int32_t n = uameasfmt_formatMultiple(f, measures, count, buf, 128, &err);
    if (n > 128) {
        UChar *large = malloc((size_t)(n + 1) * sizeof(UChar));
        if (!large) return nil;
        err = 0;
        n = uameasfmt_formatMultiple(f, measures, count, large, n + 1, &err);
        NSString *s = U_FAILURE(err) ? nil : [NSString stringWithCharacters:large length:n];
        free(large);
        return s;
    }
    return U_FAILURE(err) ? nil : [NSString stringWithCharacters:buf length:n];
}

- (NSString *)stringFromUnit:(NSUnit *)unit
{
    if (!has_specifier(unit)) return [unit symbol];
    UAMeasureFormat *f = [self _measureFormat];
    if (!f) return nil;
    UChar buf[100];
    UErrorCode err = 0;
    int32_t n = uameasfmt_getUnitName(f, (int)[(NSDimension *)unit specifier], buf, 100, &err);
    if (U_FAILURE(err) || n < 1 || n > 100) return nil;
    return [NSString stringWithCharacters:buf length:n];
}

- (NSString *)_plainStringForValue:(double)value unit:(NSUnit *)unit
{
    return [NSString stringWithFormat:@"%@ %@", [[self _numberFormatter] stringFromNumber:[NSNumber numberWithDouble:value]], [unit symbol]];
}

/* The units to format `m` in: its own, or the ones ICU prefers. */
- (int)_determineUnitsToFormat:(int *)units fromMeasurement:(NSMeasurement *)m
{
    NSDimension *unit = (NSDimension *)[m unit];
    if (!has_specifier(unit)) return 0;
    int spec = (int)[unit specifier];
    units[0] = spec;
    if (spec >= TEMPERATURE_CELSIUS && spec <= TEMPERATURE_KELVIN) {
        if (_unitOptions & (NSMeasurementFormatterUnitOptionsProvidedUnit | NSMeasurementFormatterUnitOptionsTemperatureWithoutUnit)) {
            if (_unitOptions & NSMeasurementFormatterUnitOptionsTemperatureWithoutUnit) units[0] = TEMPERATURE_GENERIC;
            return 1;
        }
        NSString *pref = preferred_temperature_unit();
        if ([pref isEqualToString:@"Celsius"]) { units[0] = TEMPERATURE_CELSIUS; return 1; }
        if ([pref isEqualToString:@"Fahrenheit"]) { units[0] = TEMPERATURE_FAHRENHEIT; return 1; }
    } else if (_unitOptions & NSMeasurementFormatterUnitOptionsProvidedUnit) {
        return 1;
    }
    const char *usage = _hasUsageOverride ? [_usageOverride UTF8String] : usage_for(spec);
    NSString *type = [[unit class] icuType];
    if (!usage || ![type length]) return 1;
    UErrorCode err = 0;
    int found[8];
    int32_t n = uameasfmt_getUnitsForUsage([[[self locale] localeIdentifier] UTF8String], [type UTF8String], usage, found, 8, &err);
    if (U_FAILURE(err) || n < 1) return 1;
    memcpy(units, found, n * sizeof(int));
    return n;
}

- (int)determineUnitsToFormat:(int *)units fromMeasurement:(NSMeasurement *)measurement
{
    return [self _determineUnitsToFormat:units fromMeasurement:measurement];
}

- (NSString *)stringForObjectValue:(id)obj
{
    if (![obj isKindOfClass:[NSMeasurement class]]) return nil;
    NSMeasurement *m = obj;
    double value = [m doubleValue];
    NSUnit *unit = [m unit];
    if (!has_specifier(unit)) {
        /* A unit ICU doesn't know: its dimension's base unit, or as it is. */
        if ([unit isKindOfClass:[NSDimension class]] && !(_unitOptions & NSMeasurementFormatterUnitOptionsProvidedUnit)) {
            NSDimension *base = [[unit class] baseUnit];
            if (!has_specifier(base)) return nil;
            return [self stringForObjectValue:[m measurementByConvertingToUnit:base]];
        }
        return [self _plainStringForValue:value unit:unit];
    }
    int units[8];
    int unitCount = [self _determineUnitsToFormat:units fromMeasurement:m];
    if (unitCount > 1) {
        if (!_allowsMultipleUnits || unitCount > 8) return [self _plainStringForValue:value unit:unit];
        UAMeasure measures[8];
        NSMeasurement *remaining = m;
        for (int i = 0; i < unitCount && i < 8; i++) {
            NSDimension *target = FinchUnitForSpecifier(units[i]);
            if (!target) return [self _plainStringForValue:value unit:unit];
            NSMeasurement *converted = [remaining measurementByConvertingToUnit:target];
            double convertedValue = [converted doubleValue];
            measures[i].unit = units[i];
            if (i + 1 < unitCount) {
                double wholeValue = trunc(convertedValue);
                measures[i].value = wholeValue;
                NSMeasurement *whole = [[[NSMeasurement alloc] initWithDoubleValue:wholeValue unit:target] autorelease];
                remaining = [converted measurementBySubtractingMeasurement:whole];
            } else {
                measures[i].value = convertedValue;
            }
        }
        NSString *formatted = [self stringForMeasurements:measures count:unitCount];
        return formatted ?: [self _plainStringForValue:value unit:unit];
    }
    if (unitCount != 1) return [self _plainStringForValue:value unit:unit];
    if (units[0] == -1) return nil;
    if (units[0] == TEMPERATURE_GENERIC) {
        if (!(_unitOptions & NSMeasurementFormatterUnitOptionsProvidedUnit)) {
            NSInteger spec = [(NSDimension *)unit specifier];
            NSString *pref = preferred_temperature_unit();
            NSInteger to = spec == TEMPERATURE_FAHRENHEIT && [pref isEqualToString:@"Celsius"] ? TEMPERATURE_CELSIUS
                         : spec == TEMPERATURE_CELSIUS && [pref isEqualToString:@"Fahrenheit"] ? TEMPERATURE_FAHRENHEIT : 0;
            if (to) value = [[m measurementByConvertingToUnit:FinchUnitForSpecifier(to)] doubleValue];
        }
        return [self stringForValue:value unit:TEMPERATURE_GENERIC];
    }
    NSDimension *target = FinchUnitForSpecifier(units[0]);
    if (target) m = [m measurementByConvertingToUnit:target];
    if (_unitOptions & NSMeasurementFormatterUnitOptionsNaturalScale && [[m unit] isKindOfClass:[NSDimension class]])
        m = [[[m unit] class] _measurementWithNaturalScale:m system:system_of(units[0])];
    if (has_specifier([m unit])) return [self stringForValue:[m doubleValue] unit:[(NSDimension *)[m unit] specifier]];
    return [self _plainStringForValue:[m doubleValue] unit:[m unit]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_unitOptions forKey:@"NS.unitOptions"];
    [coder encodeInteger:_unitStyle forKey:@"NS.unitStyle"];
    [coder encodeObject:_locale forKey:@"NS.locale"];
    [coder encodeObject:_numberFormatter forKey:@"NS.numberFormatter"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _unitOptions = [coder decodeIntegerForKey:@"NS.unitOptions"];
        if ([coder containsValueForKey:@"NS.unitStyle"]) _unitStyle = [coder decodeIntegerForKey:@"NS.unitStyle"];
        _locale = [[coder decodeObjectOfClass:[NSLocale class] forKey:@"NS.locale"] retain];
        _numberFormatter = [[coder decodeObjectOfClass:[NSNumberFormatter class] forKey:@"NS.numberFormatter"] retain];
    }
    return self;
}

@end

/* MARK: - NSMeasurementFormatter */

/* Apple's keeps its NSUnitFormatter in the header's _formatter. */
#define UNIT_FORMATTER ((NSUnitFormatter *)_formatter)

@implementation NSMeasurementFormatter

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _formatter = [[NSUnitFormatter alloc] init];
        [UNIT_FORMATTER setUnitOptions:0];
        [UNIT_FORMATTER setUnitStyle:NSFormattingUnitStyleMedium];
        [UNIT_FORMATTER setLocale:[NSLocale currentLocale]];
    }
    return self;
}

- (void)dealloc
{
    [UNIT_FORMATTER release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMeasurementFormatter *c = [[[self class] alloc] init];
    [(NSUnitFormatter *)c->_formatter release];
    c->_formatter = [UNIT_FORMATTER copy];
    return c;
}

- (NSMeasurementFormatterUnitOptions)unitOptions { return [UNIT_FORMATTER unitOptions]; }
- (void)setUnitOptions:(NSMeasurementFormatterUnitOptions)o { [UNIT_FORMATTER setUnitOptions:o]; }
- (NSFormattingUnitStyle)unitStyle { return [UNIT_FORMATTER unitStyle]; }
- (void)setUnitStyle:(NSFormattingUnitStyle)s { [UNIT_FORMATTER setUnitStyle:s]; }
- (NSLocale *)locale { return [UNIT_FORMATTER locale]; }
- (void)setLocale:(NSLocale *)l { [UNIT_FORMATTER setLocale:l ? l : [NSLocale currentLocale]]; }
- (NSNumberFormatter *)numberFormatter { return [UNIT_FORMATTER numberFormatter]; }
- (void)setNumberFormatter:(NSNumberFormatter *)nf { [UNIT_FORMATTER setNumberFormatter:nf]; }

- (void)_setFinchUsageOverride:(NSString *)usage
{
    [UNIT_FORMATTER setUsageOverride:usage];
    [UNIT_FORMATTER setHasUsageOverride:usage != nil];
}

- (void)_setFinchAllowsMultipleUnits:(BOOL)allows
{
    [UNIT_FORMATTER setAllowsMultipleUnits:allows];
}

- (NSString *)stringFromMeasurement:(NSMeasurement *)measurement
{
    NSString *s = [UNIT_FORMATTER stringForObjectValue:measurement];
    return s ? s : @"";
}
- (NSString *)stringFromUnit:(NSUnit *)unit { return [UNIT_FORMATTER stringFromUnit:unit]; }
- (NSString *)stringForObjectValue:(id)obj { return [UNIT_FORMATTER stringForObjectValue:obj]; }

- (void)encodeWithCoder:(NSCoder *)coder { [UNIT_FORMATTER encodeWithCoder:coder]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) _formatter = [[NSUnitFormatter alloc] initWithCoder:coder];
    return self;
}

@end

static NSString *
unit_name_for_value(NSUnitFormatter *formatter, double value, NSInteger specifier)
{
    double pluralityValue = value == 1.0 ? 1.0 : 2.0;
    NSString *formatted = [formatter stringForValue:pluralityValue unit:specifier];
    NSNumberFormatter *numberFormatter = [formatter numberFormatter];
    NSString *number = [numberFormatter stringFromNumber:[NSNumber numberWithDouble:pluralityValue]];
    if ([formatted hasPrefix:number]) {
        NSString *unit = [formatted substringFromIndex:[number length]];
        return [unit stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return [formatter stringFromUnit:FinchUnitForSpecifier(specifier)];
}

static NSString *
string_for_measurement(NSUnitFormatter *formatter, double value, NSDimension *unit, NSString *usage)
{
    formatter.hasUsageOverride = YES;
    formatter.usageOverride = usage;
    NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:value unit:unit] autorelease];
    return [formatter stringForObjectValue:measurement];
}

static NSInteger
first_unit_for_measurement(NSUnitFormatter *formatter, NSMeasurement *measurement, NSString *usage)
{
    formatter.hasUsageOverride = YES;
    formatter.usageOverride = usage;
    int units[8];
    int count = [formatter determineUnitsToFormat:units fromMeasurement:measurement];
    NSInteger specifier = count > 0 ? units[0] : [(NSDimension *)[measurement unit] specifier];
    NSDimension *unit = FinchUnitForSpecifier(specifier);
    if (unit && (formatter.unitOptions & NSMeasurementFormatterUnitOptionsNaturalScale)) {
        NSMeasurement *converted = [measurement measurementByConvertingToUnit:unit];
        converted = [[unit class] _measurementWithNaturalScale:converted system:system_of(specifier)];
        if ([converted unit] != nil)
            specifier = [(NSDimension *)[converted unit] specifier];
    }
    return specifier;
}

static NSInteger
length_specifier(NSLengthFormatterUnit unit)
{
    switch (unit) {
    case NSLengthFormatterUnitMillimeter: return 0x503;
    case NSLengthFormatterUnitCentimeter: return 0x501;
    case NSLengthFormatterUnitMeter: return 0x500;
    case NSLengthFormatterUnitKilometer: return 0x502;
    case NSLengthFormatterUnitInch: return 0x506;
    case NSLengthFormatterUnitFoot: return 0x505;
    case NSLengthFormatterUnitYard: return 0x508;
    case NSLengthFormatterUnitMile: return 0x507;
    }
    return -1;
}

static NSLengthFormatterUnit
length_unit_for_specifier(NSInteger specifier)
{
    switch (specifier) {
    case 0x503: return NSLengthFormatterUnitMillimeter;
    case 0x501: return NSLengthFormatterUnitCentimeter;
    case 0x500: return NSLengthFormatterUnitMeter;
    case 0x502: return NSLengthFormatterUnitKilometer;
    case 0x506: return NSLengthFormatterUnitInch;
    case 0x505: return NSLengthFormatterUnitFoot;
    case 0x508: return NSLengthFormatterUnitYard;
    case 0x507: return NSLengthFormatterUnitMile;
    }
    return NSLengthFormatterUnitMeter;
}

static NSInteger
length_formatter_specifier(NSUnitFormatter *formatter, double meters, BOOL forPersonHeight)
{
    if ([[formatter locale] usesMetricSystem]) {
        if (forPersonHeight) return 0x501;
        return fabs(meters) >= 1000 ? 0x502 : 0x500;
    }
    if (forPersonHeight) return 0x505;
    return fabs(meters / 0.9144) > 2000 ? 0x507 : 0x508;
}

static NSString *
string_for_person_height(NSUnitFormatter *formatter, double meters)
{
    if ([[formatter locale] usesMetricSystem])
        return [formatter stringForValue:meters * 100 unit:0x501];

    double inches = fabs(meters) / 0.0254;
    NSInteger feet = (NSInteger)floor(inches / 12);
    NSInteger remainingInches = (NSInteger)llround(inches - feet * 12);
    if (remainingInches == 12) {
        feet++;
        remainingInches = 0;
    }
    if (meters < 0) {
        if (feet) feet = -feet;
        else remainingInches = -remainingInches;
    }
    NSString *feetText = [formatter stringForValue:(double)feet unit:0x505];
    NSString *inchesText = [formatter stringForValue:(double)remainingInches unit:0x506];
    NSString *separator = formatter.unitStyle == NSFormattingUnitStyleLong ? @", " : @" ";
    return [NSString stringWithFormat:@"%@%@%@", feetText, separator, inchesText];
}

static NSInteger
mass_specifier(NSMassFormatterUnit unit)
{
    switch (unit) {
    case NSMassFormatterUnitGram: return 0x600;
    case NSMassFormatterUnitKilogram: return 0x601;
    case NSMassFormatterUnitOunce: return 0x602;
    case NSMassFormatterUnitPound: return 0x603;
    case NSMassFormatterUnitStone: return 0x604;
    }
    return -1;
}

static NSMassFormatterUnit
mass_unit_for_specifier(NSInteger specifier)
{
    switch (specifier) {
    case 0x600: return NSMassFormatterUnitGram;
    case 0x601: return NSMassFormatterUnitKilogram;
    case 0x602: return NSMassFormatterUnitOunce;
    case 0x603: return NSMassFormatterUnitPound;
    case 0x604: return NSMassFormatterUnitStone;
    }
    return NSMassFormatterUnitKilogram;
}

static NSInteger
energy_specifier(NSEnergyFormatterUnit unit, BOOL food)
{
    switch (unit) {
    case NSEnergyFormatterUnitJoule: return 0xc02;
    case NSEnergyFormatterUnitKilojoule: return 0xc04;
    case NSEnergyFormatterUnitCalorie: return 0xc00;
    case NSEnergyFormatterUnitKilocalorie: return food ? 0xc01 : 0xc03;
    }
    return -1;
}

static NSEnergyFormatterUnit
energy_unit_for_specifier(NSInteger specifier)
{
    switch (specifier) {
    case 0xc02: return NSEnergyFormatterUnitJoule;
    case 0xc04: return NSEnergyFormatterUnitKilojoule;
    case 0xc00: return NSEnergyFormatterUnitCalorie;
    case 0xc01: case 0xc03: return NSEnergyFormatterUnitKilocalorie;
    }
    return NSEnergyFormatterUnitJoule;
}

@interface NSLengthFormatter () {
    NSUnitFormatter *_formatter;
    BOOL _forPersonHeightUse;
}
@end

@implementation NSLengthFormatter

- (instancetype)init
{
    if ((self = [super init])) {
        _formatter = [[NSUnitFormatter alloc] init];
        _formatter.unitStyle = NSFormattingUnitStyleMedium;
        _formatter.locale = [NSLocale currentLocale];
    }
    return self;
}

- (void)dealloc { [_formatter release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSLengthFormatter *copy = [[[self class] allocWithZone:zone] init];
    [copy->_formatter release];
    copy->_formatter = [_formatter copy];
    copy->_forPersonHeightUse = _forPersonHeightUse;
    return copy;
}
- (NSNumberFormatter *)numberFormatter { return [_formatter numberFormatter]; }
- (void)setNumberFormatter:(NSNumberFormatter *)numberFormatter
{
    _formatter.numberFormatter = numberFormatter;
    _formatter.locale = numberFormatter ? numberFormatter.locale : [NSLocale currentLocale];
}
- (NSFormattingUnitStyle)unitStyle { return _formatter.unitStyle; }
- (void)setUnitStyle:(NSFormattingUnitStyle)style { _formatter.unitStyle = style; }
- (BOOL)isForPersonHeightUse { return _forPersonHeightUse; }
- (void)setForPersonHeightUse:(BOOL)value { _forPersonHeightUse = value; }

- (NSString *)stringFromValue:(double)value unit:(NSLengthFormatterUnit)unit
{
    NSInteger specifier = length_specifier(unit);
    return specifier < 0 ? nil : [_formatter stringForValue:value unit:specifier];
}
- (NSString *)unitStringFromValue:(double)value unit:(NSLengthFormatterUnit)unit
{
    NSInteger specifier = length_specifier(unit);
    return specifier < 0 ? nil : unit_name_for_value(_formatter, value, specifier);
}
- (NSString *)stringFromMeters:(double)meters
{
    if (_forPersonHeightUse && ![[_formatter locale] usesMetricSystem])
        return string_for_person_height(_formatter, meters);
    NSInteger specifier = length_formatter_specifier(_formatter, meters, _forPersonHeightUse);
    NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:meters unit:[NSUnitLength meters]] autorelease];
    NSMeasurement *converted = [measurement measurementByConvertingToUnit:FinchUnitForSpecifier(specifier)];
    return [_formatter stringForValue:[converted doubleValue] unit:specifier];
}
- (NSString *)unitStringFromMeters:(double)meters usedUnit:(NSLengthFormatterUnit *)unit
{
    NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:meters unit:[NSUnitLength meters]] autorelease];
    NSInteger specifier = length_formatter_specifier(_formatter, meters, _forPersonHeightUse);
    NSMeasurement *converted = [measurement measurementByConvertingToUnit:FinchUnitForSpecifier(specifier)];
    if (unit) *unit = length_unit_for_specifier(specifier);
    return unit_name_for_value(_formatter, [converted doubleValue], specifier);
}
- (NSString *)stringForObjectValue:(id)object
{
    return [object isKindOfClass:[NSNumber class]] ? [self stringFromMeters:[object doubleValue]] : nil;
}
- (BOOL)getObjectValue:(id *)object forString:(NSString *)string errorDescription:(NSString **)error
{
    if (object) *object = nil;
    if (error) *error = nil;
    return NO;
}

@end

@interface NSMassFormatter () {
    NSUnitFormatter *_formatter;
    BOOL _forPersonMassUse;
}
@end

@implementation NSMassFormatter

- (instancetype)init
{
    if ((self = [super init])) {
        _formatter = [[NSUnitFormatter alloc] init];
        _formatter.unitStyle = NSFormattingUnitStyleMedium;
        _formatter.locale = [NSLocale currentLocale];
        _formatter.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale;
    }
    return self;
}
- (void)dealloc { [_formatter release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSMassFormatter *copy = [[[self class] allocWithZone:zone] init];
    [copy->_formatter release];
    copy->_formatter = [_formatter copy];
    copy->_forPersonMassUse = _forPersonMassUse;
    return copy;
}
- (NSNumberFormatter *)numberFormatter { return [_formatter numberFormatter]; }
- (void)setNumberFormatter:(NSNumberFormatter *)numberFormatter
{
    _formatter.numberFormatter = numberFormatter;
    _formatter.locale = numberFormatter ? numberFormatter.locale : [NSLocale currentLocale];
}
- (NSFormattingUnitStyle)unitStyle { return _formatter.unitStyle; }
- (void)setUnitStyle:(NSFormattingUnitStyle)style { _formatter.unitStyle = style; }
- (BOOL)isForPersonMassUse { return _forPersonMassUse; }
- (void)setForPersonMassUse:(BOOL)value { _forPersonMassUse = value; }
- (NSString *)stringFromValue:(double)value unit:(NSMassFormatterUnit)unit
{
    NSInteger specifier = mass_specifier(unit);
    return specifier < 0 ? nil : [_formatter stringForValue:value unit:specifier];
}
- (NSString *)unitStringFromValue:(double)value unit:(NSMassFormatterUnit)unit
{
    NSInteger specifier = mass_specifier(unit);
    return specifier < 0 ? nil : unit_name_for_value(_formatter, value, specifier);
}
- (NSString *)stringFromKilograms:(double)kilograms
{
    return string_for_measurement(_formatter, kilograms, [NSUnitMass kilograms], _forPersonMassUse ? @"person" : @"default");
}
- (NSString *)unitStringFromKilograms:(double)kilograms usedUnit:(NSMassFormatterUnit *)unit
{
    NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:kilograms unit:[NSUnitMass kilograms]] autorelease];
    NSInteger specifier = first_unit_for_measurement(_formatter, measurement, _forPersonMassUse ? @"person" : @"default");
    NSMeasurement *converted = [measurement measurementByConvertingToUnit:FinchUnitForSpecifier(specifier)];
    if (unit) *unit = mass_unit_for_specifier(specifier);
    return unit_name_for_value(_formatter, [converted doubleValue], specifier);
}
- (NSString *)stringForObjectValue:(id)object
{
    return [object isKindOfClass:[NSNumber class]] ? [self stringFromKilograms:[object doubleValue]] : nil;
}
- (BOOL)getObjectValue:(id *)object forString:(NSString *)string errorDescription:(NSString **)error
{
    if (object) *object = nil;
    if (error) *error = nil;
    return NO;
}

@end

@interface NSEnergyFormatter () {
    NSUnitFormatter *_formatter;
    BOOL _forFoodEnergyUse;
}
@end

@implementation NSEnergyFormatter

- (instancetype)init
{
    if ((self = [super init])) {
        _formatter = [[NSUnitFormatter alloc] init];
        _formatter.unitStyle = NSFormattingUnitStyleMedium;
        _formatter.locale = [NSLocale currentLocale];
        _formatter.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale;
    }
    return self;
}
- (void)dealloc { [_formatter release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSEnergyFormatter *copy = [[[self class] allocWithZone:zone] init];
    [copy->_formatter release];
    copy->_formatter = [_formatter copy];
    copy->_forFoodEnergyUse = _forFoodEnergyUse;
    return copy;
}
- (NSNumberFormatter *)numberFormatter { return [_formatter numberFormatter]; }
- (void)setNumberFormatter:(NSNumberFormatter *)numberFormatter
{
    _formatter.numberFormatter = numberFormatter;
    _formatter.locale = numberFormatter ? numberFormatter.locale : [NSLocale currentLocale];
}
- (NSFormattingUnitStyle)unitStyle { return _formatter.unitStyle; }
- (void)setUnitStyle:(NSFormattingUnitStyle)style { _formatter.unitStyle = style; }
- (BOOL)isForFoodEnergyUse { return _forFoodEnergyUse; }
- (void)setForFoodEnergyUse:(BOOL)value { _forFoodEnergyUse = value; }
- (NSString *)stringFromValue:(double)value unit:(NSEnergyFormatterUnit)unit
{
    NSInteger specifier = energy_specifier(unit, _forFoodEnergyUse);
    return specifier < 0 ? nil : [_formatter stringForValue:value unit:specifier];
}
- (NSString *)unitStringFromValue:(double)value unit:(NSEnergyFormatterUnit)unit
{
    NSInteger specifier = energy_specifier(unit, _forFoodEnergyUse);
    return specifier < 0 ? nil : unit_name_for_value(_formatter, value, specifier);
}
- (NSString *)stringFromJoules:(double)joules
{
    if (_forFoodEnergyUse) {
        NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:joules unit:[NSUnitEnergy joules]] autorelease];
        NSMeasurement *foodCalories = [measurement measurementByConvertingToUnit:[NSUnitEnergy foodcalories]];
        return [_formatter stringForValue:[foodCalories doubleValue] unit:0xc01];
    }
    return string_for_measurement(_formatter, joules, [NSUnitEnergy joules], @"food");
}
- (NSString *)unitStringFromJoules:(double)joules usedUnit:(NSEnergyFormatterUnit *)unit
{
    NSMeasurement *measurement = [[[NSMeasurement alloc] initWithDoubleValue:joules unit:[NSUnitEnergy joules]] autorelease];
    if (_forFoodEnergyUse) {
        NSMeasurement *foodCalories = [measurement measurementByConvertingToUnit:[NSUnitEnergy foodcalories]];
        if (unit) *unit = NSEnergyFormatterUnitKilocalorie;
        return unit_name_for_value(_formatter, [foodCalories doubleValue], 0xc01);
    }
    NSInteger specifier = first_unit_for_measurement(_formatter, measurement, @"food");
    NSMeasurement *converted = [measurement measurementByConvertingToUnit:FinchUnitForSpecifier(specifier)];
    if (unit) *unit = energy_unit_for_specifier(specifier);
    return unit_name_for_value(_formatter, [converted doubleValue], specifier);
}
- (NSString *)stringForObjectValue:(id)object
{
    return [object isKindOfClass:[NSNumber class]] ? [self stringFromJoules:[object doubleValue]] : nil;
}
- (BOOL)getObjectValue:(id *)object forString:(NSString *)string errorDescription:(NSString **)error
{
    if (object) *object = nil;
    if (error) *error = nil;
    return NO;
}

@end

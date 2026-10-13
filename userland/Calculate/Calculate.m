// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Calculate's Objective-C half: options keys, results (a value, how it reads, its unit and
// its conversions), the unit collection a converter offers, and an exchange-rate cache that
// stays empty (Finch has no rate service, so currencies list but don't convert).

#import "Calculate.h"
#import <math.h>

CalculateKey const CalculateKeyAllowConversions = @"CalculateKeyAllowConversions";
CalculateKey const CalculateKeyAllowCurrencyConversions = @"CalculateKeyAllowCurrencyConversions";
CalculateKey const CalculateKeyAllowEqualSign = @"CalculateKeyAllowEqualSign";
CalculateKey const CalculateKeyAllowPartialExpressions = @"CalculateKeyAllowPartialExpressions";
CalculateKey const CalculateKeyAllowStaleCurrencyConversions = @"CalculateKeyAllowStaleCurrencyConversions";
CalculateKey const CalculateKeyAllowUnits = @"CalculateKeyAllowUnits";
CalculateKey const CalculateKeyAssumeDegrees = @"CalculateKeyAssumeDegrees";
CalculateKey const CalculateKeyAutoScientificNotation = @"CalculateKeyAutoScientificNotation";
CalculateKey const CalculateKeyConvertTrivial = @"CalculateKeyConvertTrivial";
CalculateKey const CalculateKeyEngine = @"CalculateKeyEngine";
CalculateKey const CalculateKeyExpectedUnitTypes = @"CalculateKeyExpectedUnitTypes";
CalculateKey const CalculateKeyFlexibleFractionDigits = @"CalculateKeyFlexibleFractionDigits";
CalculateKey const CalculateKeyForceResult = @"CalculateKeyForceResult";
CalculateKey const CalculateKeyFormat = @"CalculateKeyFormat";
CalculateKey const CalculateKeyIgnoreProbableSearches = @"CalculateKeyIgnoreProbableSearches";
CalculateKey const CalculateKeyLocales = @"CalculateKeyLocales";
CalculateKey const CalculateKeyLocalizeUnit = @"CalculateKeyLocalizeUnit";
CalculateKey const CalculateKeyMatchLocale = @"CalculateKeyMatchLocale";
CalculateKey const CalculateKeyMaximumConversions = @"CalculateKeyMaximumConversions";
CalculateKey const CalculateKeyNumberFormatter = @"CalculateKeyNumberFormatter";
CalculateKey const CalculateKeyPreferMixedUnits = @"CalculateKeyPreferMixedUnits";
CalculateKey const CalculateKeyScientificNotationFormat = @"CalculateKeyScientificNotationFormat";
CalculateKey const CalculateKeyUnitFormat = @"CalculateKeyUnitFormat";
CalculateKey const CalculateKeyVariables = @"CalculateKeyVariables";

NSErrorDomain const CalculateErrorDomain = @"com.apple.calculateframework";
NSString *const CalculateErrorKeySuggestions = @"CalculateErrorKeySuggestions";

// MARK: - The units

/// How a unit's value becomes its category's base unit's.
typedef NS_ENUM(NSInteger, FinchUnitScale) {
    FinchUnitScaleLinear,      // base = value * factor
    FinchUnitScaleOffset,      // base = (value + offset) * factor (temperatures)
    FinchUnitScaleReciprocal,  // base = factor / value (fuel per distance)
};

typedef struct {
    const char *name, *displayName, *shortName;
    double factor, offset;
    FinchUnitScale scale;
} FinchUnitSpec;

typedef struct {
    const char *name;
    NSUInteger unitType;
    const char *from, *to;
    const FinchUnitSpec *units;
} FinchCategorySpec;

#define L(n, d, s, f) {n, d, s, f, 0, FinchUnitScaleLinear}
#define END {NULL, NULL, NULL, 0, 0, 0}

static const FinchUnitSpec angleUnits[] = {
    L("radian", "Radian", "rad", 180 / M_PI), L("milliradian", "Milliradian", "mrad", 0.18 / M_PI),
    L("microarcsecond", "Microarcsecond", "μasec", 1 / 3600e6), L("arcminute", "Arcminute", "amin", 1 / 60.0),
    L("microradian", "Microradian", "µrad", 1.8e-4 / M_PI), L("milliarcsecond", "Milliarcsecond", "masec", 1 / 3600e3),
    L("degree", "Degree", "deg", 1), L("arcsecond", "Arcsecond", "asec", 1 / 3600.0), END,
};

static const FinchUnitSpec areaUnits[] = {
    L("square mile", "Square Mile", "mi²", 2589988.110336), L("decare", "Decare", "daa", 1000),
    L("square millimeter", "Square Millimeter", "mm²", 1e-6), L("square meter", "Square Meter", "m²", 1),
    L("are", "Are", "are", 100), L("acre", "Acre", "acre", 4046.8564224),
    L("square kilometer", "Square Kilometer", "km²", 1e6), L("hectare", "Hectare", "ha", 1e4),
    L("square centimeter", "Square Centimeter", "cm²", 1e-4), L("square yard", "Square Yard", "yd²", 0.83612736),
    L("square foot", "Square Foot", "ft²", 0.09290304), L("stremma", "Stremma", "str", 1000),
    L("square inch", "Square Inch", "in²", 0.00064516), END,
};

static const FinchUnitSpec dataUnits[] = {
    L("byte", "Byte", "byte", 1), L("pebibyte", "Pebibyte", "PiB", 1125899906842624.0), L("bit", "Bit", "bit", 0.125),
    L("tebibyte", "Tebibyte", "TiB", 1099511627776.0), L("gibibyte", "Gibibyte", "GiB", 1073741824.0),
    L("mebibyte", "Mebibyte", "MiB", 1048576.0), L("gigabyte", "Gigabyte", "GB", 1e9),
    L("terabyte", "Terabyte", "TB", 1e12), L("kibibyte", "Kibibyte", "KiB", 1024),
    L("megabyte", "Megabyte", "MB", 1e6), L("kilobyte", "Kilobyte", "kB", 1e3), L("petabyte", "Petabyte", "PB", 1e15), END,
};

static const FinchUnitSpec energyUnits[] = {
    L("newton meter", "Newton Meter", "N⋅m", 1), L("kilojoule", "Kilojoule", "kJ", 1e3),
    L("kilowatt hour", "Kilowatt Hour", "kWh", 3.6e6), L("foot pound", "Foot Pound", "ft lb", 1.3558179483314004),
    L("british thermal unit", "British Thermal Unit", "BTU", 1055.05585262), L("calorie", "Calorie", "cal", 4.184),
    L("erg", "Erg", "erg", 1e-7), L("joule", "Joule", "J", 1), L("kilocalorie", "Kilocalorie", "kcal", 4184), END,
};

static const FinchUnitSpec forceUnits[] = {
    L("poundal", "Poundal", "pdl", 0.138254954376), L("dyne", "Dyne", "dyn", 1e-5),
    L("kilogram-force", "Kilogram-Force", "kgf", 9.80665), L("pound-force", "Pound-Force", "lbf", 4.4482216152605),
    L("newton", "Newton", "N", 1), END,
};

// kilometres per litre; a US gallon is 3.785411784 L, a mile 1.609344 km
#define KPL_PER_MPG (1.609344 / 3.785411784)
static const FinchUnitSpec fuelUnits[] = {
    L("kilometer per liter", "Kilometer per Liter", "km/L", 1),
    {"gallon per 100 miles", "Gallon per 100 Miles", "gal/100mi", 100 * KPL_PER_MPG, 0, FinchUnitScaleReciprocal},
    {"liter per 100 kilometers", "Liter per 100 Kilometers", "L/100km", 100, 0, FinchUnitScaleReciprocal},
    L("mile per gallon", "Mile per Gallon", "mi/gal", KPL_PER_MPG), END,
};

static const FinchUnitSpec lengthUnits[] = {
    L("foot", "Foot", "ft", 0.3048), L("mile", "Mile", "mi", 1609.344), L("yard", "Yard", "yd", 0.9144),
    L("light year", "Light Year", "ly", 9460730472580800.0), L("centimeter", "Centimeter", "cm", 0.01),
    L("decimeter", "Decimeter", "dm", 0.1), L("kilometer", "Kilometer", "km", 1000), L("meter", "Meter", "m", 1),
    L("parsec", "Parsec", "pc", 3.0856775814913673e16), L("nautical mile", "Nautical Mile", "nmi", 1852),
    L("astronomical unit", "Astronomical Unit", "AU", 149597870700.0), L("inch", "Inch", "in", 0.0254),
    L("millimeter", "Millimeter", "mm", 0.001), END,
};

static const FinchUnitSpec powerUnits[] = {
    L("BTU per minute", "BTU per Minute", "BTU/min", 1055.05585262 / 60), L("watt", "Watt", "W", 1),
    L("HP", "Horsepower", "HP", 745.69987158227022), L("kilowatt", "Kilowatt", "kW", 1000), END,
};

static const FinchUnitSpec pressureUnits[] = {
    L("Pascal", "Pascal", "Pa", 1), L("bar", "Bar", "bar", 1e5), L("Torr", "Torr", "Torr", 101325 / 760.0),
    L("inch of mercury", "Inch of Mercury", "inHg", 3386.389), L("kilopascal", "Kilopascal", "kPa", 1000),
    L("atmosphere", "Atmosphere", "atm", 101325), L("PSI", "Pound per Square Inch", "PSI", 6894.757293168361), END,
};

static const FinchUnitSpec speedUnits[] = {
    L("meter per second", "Meter per Second", "m/s", 1), L("foot per second", "Foot per Second", "ft/s", 0.3048),
    L("kilometer per hour", "Kilometer per Hour", "km/h", 1 / 3.6), L("mile per hour", "Mile per Hour", "mi/hr", 0.44704),
    L("knot", "Knot", "kt", 1852 / 3600.0), END,
};

static const FinchUnitSpec temperatureUnits[] = {
    L("kelvin", "Kelvin", "K", 1),
    {"celsius", "Celsius", "°C", 1, 273.15, FinchUnitScaleOffset},
    {"fahrenheit", "Fahrenheit", "°F", 5 / 9.0, 459.67, FinchUnitScaleOffset}, END,
};

static const FinchUnitSpec timeUnits[] = {
    L("second", "Second", "sec", 1), L("hour", "Hour", "hr", 3600), L("minute", "Minute", "min", 60),
    L("day", "Day", "day", 86400), L("week", "Week", "wk", 604800), L("millisecond", "Millisecond", "msec", 1e-3),
    L("year", "Year", "yr", 31557600), L("microsecond", "Microsecond", "μsec", 1e-6),
    L("nanosecond", "Nanosecond", "nsec", 1e-9), END,
};

static const FinchUnitSpec volumeUnits[] = {
    L("UK fluid ounce", "UK Fluid Ounce", "UK fl oz", 0.0284130625), L("fluid dram", "Fluid Dram", "fl dr", 0.0036966911953125),
    L("teaspoon", "Teaspoon", "tsp", 0.00492892159375), L("pint", "Pint", "pt", 0.473176473),
    L("quart", "Quart", "qt", 0.946352946), L("centiliter", "Centiliter", "cL", 0.01),
    L("UK gallon", "UK Gallon", "UK gal", 4.54609), L("liter", "Liter", "L", 1), L("cubic meter", "Cubic Meter", "m³", 1000),
    L("tablespoon", "Tablespoon", "tbsp", 0.01478676478125), L("cubic foot", "Cubic Foot", "ft³", 28.316846592),
    L("cubic centimeter", "Cubic Centimeter", "cm³", 0.001), L("gallon", "Gallon", "gal", 3.785411784),
    L("UK pint", "UK Pint", "UK pt", 0.56826125), L("UK quart", "UK Quart", "UK qt", 1.1365225),
    L("milliliter", "Milliliter", "mL", 0.001), L("cup", "Cup", "cup", 0.2365882365),
    L("fluid ounce", "Fluid Ounce", "fl oz", 0.0295735295625), END,
};

static const FinchUnitSpec weightUnits[] = {
    L("slug", "Slug", "slug", 14.593902937206364), L("milligram", "Milligram", "mg", 1e-6),
    L("ounce", "Ounce", "oz", 0.028349523125), L("long ton", "Long Ton", "lt", 1016.0469088),
    L("kilogram", "Kilogram", "kg", 1), L("dram", "Dram", "dram", 0.0017718451953125), L("gram", "Gram", "g", 1e-3),
    L("short ton", "Short Ton", "ton", 907.18474), L("pound", "Pound", "lb", 0.45359237),
    L("metric tonne", "Metric Ton", "t", 1000), L("stone", "Stone", "st", 6.35029318), END,
};

static const FinchCategorySpec categorySpecs[] = {
    {"Angle", 2, "degree", "radian", angleUnits},
    {"Area", 15, "square foot", "square meter", areaUnits},
    {"Currency", 16, "USD", "EUR", NULL},
    {"Data", 7, "byte", "kilobyte", dataUnits},
    {"Energy", 8, "calorie", "joule", energyUnits},
    {"Force", 10, "newton", "pound-force", forceUnits},
    {"Fuel", 13, "mile per gallon", "liter per 100 kilometers", fuelUnits},
    {"Length", 4, "foot", "meter", lengthUnits},
    {"Power", 14, "HP", "watt", powerUnits},
    {"Pressure", 6, "PSI", "Pascal", pressureUnits},
    {"Speed", 9, "mile per hour", "kilometer per hour", speedUnits},
    {"Temperature", 12, "fahrenheit", "celsius", temperatureUnits},
    {"Time", 11, "second", "hour", timeUnits},
    {"Volume", 5, "gallon", "liter", volumeUnits},
    {"Weight", 3, "pound", "kilogram", weightUnits},
};

static NSLocale *FinchFirstLocale(NSArray<NSLocale *> *locales) {
    return locales.firstObject ?: NSLocale.currentLocale;
}

@interface CalculateUnit ()
@property (readwrite, copy) NSString *name;
@property (readwrite) NSUInteger unitType;
@property (readwrite) BOOL isBaseUnit;
@property double finchFactor;
@property double finchOffset;
@property FinchUnitScale finchScale;
@property BOOL finchCurrency;
@end

@implementation CalculateUnit

- (NSLocale *)locale {
    return FinchFirstLocale(self.category.collection.locales);
}

- (BOOL)contains:(NSString *)query {
    if (query.length == 0) return YES;
    NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    return [self.name rangeOfString:query options:o].location != NSNotFound ||
           [self.displayName rangeOfString:query options:o].location != NSNotFound ||
           [self.shortName rangeOfString:query options:o].location != NSNotFound;
}

/// A value in this unit, in the category's base unit (NAN when it has none: a currency).
- (double)finchToBase:(double)v {
    if (self.finchCurrency) return NAN;
    switch (self.finchScale) {
    case FinchUnitScaleLinear: return v * self.finchFactor;
    case FinchUnitScaleOffset: return (v + self.finchOffset) * self.finchFactor;
    case FinchUnitScaleReciprocal: return v == 0 ? INFINITY : self.finchFactor / v;
    }
}

- (double)finchFromBase:(double)v {
    if (self.finchCurrency) return NAN;
    switch (self.finchScale) {
    case FinchUnitScaleLinear: return v / self.finchFactor;
    case FinchUnitScaleOffset: return v / self.finchFactor - self.finchOffset;
    case FinchUnitScaleReciprocal: return v == 0 ? INFINITY : self.finchFactor / v;
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CalculateUnit %@>", self.name];
}

@end

@interface CalculateUnitCategory ()
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *displayName;
@property (readwrite) NSUInteger unitType;
@property (copy) NSString *finchFrom;
@property (copy) NSString *finchTo;
@end

@implementation CalculateUnitCategory

- (NSLocale *)locale {
    return FinchFirstLocale(self.collection.locales);
}

- (BOOL)contains:(CalculateUnit *)unit {
    return [self.units containsObject:unit];
}

- (CalculateUnit *)findUnitWithName:(NSString *)name {
    for (CalculateUnit *u in self.units) {
        if ([u.name caseInsensitiveCompare:name] == NSOrderedSame) return u;
    }
    for (CalculateUnit *u in self.units) {
        if ([u.shortName isEqualToString:name] || [u.displayName caseInsensitiveCompare:name] == NSOrderedSame) return u;
    }
    return nil;
}

- (CalculateUnit *)preferredFromUnit {
    return [self findUnitWithName:self.finchFrom];
}

- (CalculateUnit *)preferredToUnit {
    return [self findUnitWithName:self.finchTo];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CalculateUnitCategory %@ (%lu units)>", self.name, (unsigned long)self.units.count];
}

@end

@implementation CalculateUnitCollection

+ (instancetype)collectionWithLocales:(NSArray<NSLocale *> *)locales {
    return [[self alloc] initWithLocales:locales];
}

- (instancetype)init {
    return [self initWithLocales:nil];
}

- (instancetype)initWithLocales:(NSArray<NSLocale *> *)locales {
    if (!(self = [super init])) return nil;
    _locales = [(locales ?: @[NSLocale.currentLocale]) copy];
    NSLocale *display = FinchFirstLocale(_locales);
    NSMutableArray *categories = [NSMutableArray array];
    for (size_t c = 0; c < sizeof categorySpecs / sizeof *categorySpecs; c++) {
        const FinchCategorySpec *spec = &categorySpecs[c];
        CalculateUnitCategory *category = [CalculateUnitCategory new];
        category.name = @(spec->name);
        category.displayName = @(spec->name);
        category.unitType = spec->unitType;
        category.finchFrom = @(spec->from);
        category.finchTo = @(spec->to);
        category.collection = self;
        NSMutableArray *units = [NSMutableArray array];
        if (spec->units) {
            for (const FinchUnitSpec *u = spec->units; u->name; u++) {
                CalculateUnit *unit = [CalculateUnit new];
                unit.name = @(u->name);
                unit.displayName = @(u->displayName);
                unit.shortName = @(u->shortName);
                unit.unitType = spec->unitType;
                unit.finchFactor = u->factor;
                unit.finchOffset = u->offset;
                unit.finchScale = u->scale;
                unit.isBaseUnit = u->factor == 1 && u->offset == 0 && u->scale == FinchUnitScaleLinear;
                unit.category = category;
                [units addObject:unit];
            }
        } else {
            for (NSString *code in NSLocale.commonISOCurrencyCodes) {
                NSString *name = [display localizedStringForCurrencyCode:code];
                if (!name) continue;
                CalculateUnit *unit = [CalculateUnit new];
                unit.name = code;
                unit.displayName = name;
                unit.shortName = code;
                unit.unitType = spec->unitType;
                unit.finchCurrency = YES;
                unit.category = category;
                [units addObject:unit];
            }
        }
        category.units = units;
        [categories addObject:category];
    }
    _categories = [categories copy];
    return self;
}

- (CalculateUnitCategory *)findCategoryWithName:(NSString *)name {
    for (CalculateUnitCategory *c in self.categories) {
        if ([c.name caseInsensitiveCompare:name] == NSOrderedSame) return c;
    }
    return nil;
}

- (CalculateUnit *)findUnitWithName:(NSString *)name {
    for (CalculateUnitCategory *c in self.categories) {
        CalculateUnit *u = [c findUnitWithName:name];
        if (u) return u;
    }
    return nil;
}

@end

// MARK: - Results

@interface CalculateResult ()
@property (readwrite, copy, nullable) NSString *expression;
@property (readwrite) BOOL assumeDegrees;
@property (readwrite, copy) NSArray<CalculateResult *> *conversions;
@property (readwrite, nullable) CalculateResult *inputValueAndUnit;
@property double finchValue;
@property NSInteger finchBase;
@property BOOL finchInteger;
@property (nullable) CalculateUnit *finchUnit;
@property BOOL finchTrivial;
@property BOOL finchFlexible;
@property (copy, nullable) NSString *finchUnitText;
@property BOOL finchTrivialSet;
- (NSString *)finchFormat:(double)v;
@end

@interface CalculateTerm ()
@property (readwrite, copy) NSArray<CalculateUnit *> *units;
@end

@implementation CalculateTerm

+ (instancetype)termWithValue:(NSNumber *)value units:(NSArray<CalculateUnit *> *)units result:(CalculateResult *)result {
    CalculateTerm *term = [self new];
    term.value = value;
    term.units = units ?: @[];
    term.result = result;
    return term;
}

- (CalculateUnit *)primaryUnit {
    return self.units.firstObject;
}

- (NSLocale *)locale {
    return FinchFirstLocale(self.result.locales);
}

- (NSString *)formattedValue {
    return [self.result finchFormat:self.value.doubleValue];
}

- (NSString *)formattedUnit {
    return self.result.finchUnitText ?: self.primaryUnit.shortName ?: @"";
}

- (NSString *)formattedResult {
    NSString *unit = self.formattedUnit;
    return unit.length ? [NSString stringWithFormat:@"%@ %@", self.formattedValue, unit] : self.formattedValue;
}

@end

@implementation CalculateResult

- (instancetype)init {
    return [self initWithDouble:0];
}

- (instancetype)initWithDouble:(double)value {
    if (!(self = [super init])) return nil;
    _finchValue = value;
    _finchBase = 10;
    _conversions = @[];
    return self;
}

- (double)doubleValue {
    return self.finchValue;
}

- (void)finchSetExpression:(NSString *)expression base:(NSInteger)base integer:(BOOL)integer {
    self.expression = expression;
    self.finchBase = base;
    self.finchInteger = integer;
}

- (BOOL)isNaN {
    return isnan(self.finchValue);
}

- (void)finchSetFlexibleFractionDigits:(BOOL)flexible {
    self.finchFlexible = flexible;
}

- (void)finchSetUnitText:(NSString *)text {
    self.finchUnitText = text;
}

- (void)finchSetTrivial:(BOOL)trivial {
    self.finchTrivial = trivial;
    self.finchTrivialSet = YES;
}

- (BOOL)isTrivial {
    if (self.finchTrivialSet) return self.finchTrivial;
    // a number on its own: nothing was calculated
    NSString *e = [self.expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (e.length == 0) return YES;
    NSCharacterSet *number = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,-ABCDEFabcdef"];
    return [e rangeOfCharacterFromSet:number.invertedSet].location == NSNotFound;
}

- (BOOL)isPartialExpression {
    NSString *e = [self.expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (e.length == 0) return NO;
    unichar last = [e characterAtIndex:e.length - 1];
    if ([[NSCharacterSet characterSetWithCharactersInString:@"+-*/^(×÷−"] characterIsMember:last]) return YES;
    NSInteger depth = 0;
    for (NSUInteger i = 0; i < e.length; i++) {
        unichar c = [e characterAtIndex:i];
        if (c == '(') depth++;
        else if (c == ')') depth--;
    }
    return depth > 0;
}

- (BOOL)hasStaleCurrencyData {
    return NO;
}

- (NSUInteger)unitType {
    return self.finchUnit.unitType;
}

- (NSArray<CalculateTerm *> *)terms {
    return @[[CalculateTerm termWithValue:@(self.finchValue) units:self.finchUnit ? @[self.finchUnit] : @[] result:self]];
}

- (NSString *)formattedResult {
    return self.terms.firstObject.formattedResult;
}

- (NSString *)formattedExpression {
    return self.expression;
}

- (CalculateResult *)convertedTo:(CalculateUnit *)unit {
    return [self convertedTo:unit from:nil];
}

- (CalculateResult *)convertedTo:(CalculateUnit *)unit from:(CalculateUnit *)from {
    CalculateUnit *source = from ?: self.finchUnit;
    if (!source || !unit || source.unitType != unit.unitType) return nil;
    double base = [source finchToBase:self.finchValue];
    double value = [unit finchFromBase:base];
    if (isnan(value)) return nil;
    // to the digits a decimal calculator keeps (32 °F is 0 °C, not 5.7e-14)
    if (fabs(value) < 1e-9 * MAX(1.0, fabs(base))) value = 0;
    value = [[NSString stringWithFormat:@"%.12g", value] doubleValue];
    CalculateResult *converted = [[CalculateResult alloc] initWithDouble:value];
    converted.finchUnit = unit;
    converted.numberFormatter = self.numberFormatter;
    converted.locales = self.locales;
    converted.autoScientificNotation = self.autoScientificNotation;
    converted.minimumFractionDigits = self.minimumFractionDigits;
    converted.expression = self.expression;
    converted.parent = self;
    CalculateResult *input = [[CalculateResult alloc] initWithDouble:self.finchValue];
    input.finchUnit = source;
    input.numberFormatter = self.numberFormatter;
    input.locales = self.locales;
    converted.inputValueAndUnit = input;
    return converted;
}

- (NSComparisonResult)compare:(CalculateResult *)other {
    if (self.finchValue < other.finchValue) return NSOrderedAscending;
    if (self.finchValue > other.finchValue) return NSOrderedDescending;
    return NSOrderedSame;
}

/// A value as this result writes it: in the programmer's base, with the number formatter, or
/// in a few significant digits (scientific when large, or small with auto scientific).
- (NSString *)finchFormat:(double)v {
    if (isnan(v)) return @"NaN";
    if (isinf(v)) return v < 0 ? @"-∞" : @"∞";
    NSNumberFormatter *formatter = self.numberFormatter;
    if (formatter) return [formatter stringFromNumber:@(v)] ?: @"";
    double magnitude = fabs(v);
    BOOL roundsToZero = magnitude != 0 && magnitude < 0.0005;
    // flexible fraction digits: small fractions to three significant digits (1.0002, 0.000000123)
    BOOL flexibleSmall = self.finchFlexible && magnitude >= 1e-9;
    if (magnitude >= 1e10 || (roundsToZero && self.autoScientificNotation && !flexibleSmall)) {
        int exponent = (int)floor(log10(magnitude));
        double mantissa = v / pow(10, exponent);
        if (fabs(round(mantissa * 1000) / 1000) >= 10) {
            mantissa /= 10;
            exponent++;
        }
        NSNumberFormatter *m = [NSNumberFormatter new];
        m.locale = FinchFirstLocale(self.locales);
        m.numberStyle = NSNumberFormatterDecimalStyle;
        m.maximumFractionDigits = 3;
        NSString *digits = [m stringFromNumber:@(mantissa)];
        NSString *power = [NSString stringWithFormat:@"%d", exponent];
        switch (self.scientificNotationFormat) {
        case 0: return [NSString stringWithFormat:@"%@e%@", digits, power];
        case 2: return [NSString stringWithFormat:@"%@*10^%@", digits, power];
        default: {
            // ×10 with the exponent in superscript
            NSDictionary *sup = @{@"0": @"⁰", @"1": @"¹", @"2": @"²", @"3": @"³", @"4": @"⁴", @"5": @"⁵",
                                  @"6": @"⁶", @"7": @"⁷", @"8": @"⁸", @"9": @"⁹", @"-": @"⁻"};
            NSMutableString *s = [NSMutableString stringWithFormat:@"%@×10", digits];
            for (NSUInteger i = 0; i < power.length; i++) {
                [s appendString:sup[[power substringWithRange:NSMakeRange(i, 1)]]];
            }
            return s;
        }
        }
    }
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.locale = FinchFirstLocale(self.locales);
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.maximumFractionDigits = 3;
    if (self.finchFlexible && magnitude != 0) {
        // past the fraction's leading zeros
        double fraction = magnitude - floor(magnitude);
        if (fraction > 0) {
            int zeros = (int)floor(-log10(fraction));
            f.maximumFractionDigits = MIN(15, MAX(3, zeros + 3));
        }
    }
    f.minimumFractionDigits = MAX(0, self.minimumFractionDigits);
    NSString *s = [f stringFromNumber:@(v)] ?: @"";
    if (roundsToZero && v < 0 && ![s hasPrefix:@"-"]) s = [@"-" stringByAppendingString:s];
    return s;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CalculateResult %@ = %@>", self.expression, self.formattedResult];
}

@end

// MARK: - Exchange rates

@implementation CalculateCurrencyCache

+ (CalculateCurrencyCache *)shared {
    static CalculateCurrencyCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [CalculateCurrencyCache new];
    });
    return shared;
}

- (NSDate *)lastRefreshDate {
    return nil;
}

- (BOOL)needsRefresh {
    return NO;
}

- (NSDictionary *)currencyData {
    return nil;
}

- (BOOL)refresh {
    return NO;
}

- (BOOL)refreshIfNeeded {
    return NO;
}

@end

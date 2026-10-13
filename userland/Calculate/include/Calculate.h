// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Calculate: Finch's calculation engine, to the interface of Apple's private framework
// (Calculator links it): options keys, results with their terms and unit conversions, the
// unit collection, the currency cache. The Swift half (CalculateExpression, the expression
// a calculator edits) imports this module.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *CalculateKey NS_TYPED_EXTENSIBLE_ENUM;

extern CalculateKey const CalculateKeyAllowConversions;
extern CalculateKey const CalculateKeyAllowCurrencyConversions;
extern CalculateKey const CalculateKeyAllowEqualSign;
extern CalculateKey const CalculateKeyAllowPartialExpressions;
extern CalculateKey const CalculateKeyAllowStaleCurrencyConversions;
extern CalculateKey const CalculateKeyAllowUnits;
extern CalculateKey const CalculateKeyAssumeDegrees;
extern CalculateKey const CalculateKeyAutoScientificNotation;
extern CalculateKey const CalculateKeyConvertTrivial;
extern CalculateKey const CalculateKeyEngine;
extern CalculateKey const CalculateKeyExpectedUnitTypes;
extern CalculateKey const CalculateKeyFlexibleFractionDigits;
extern CalculateKey const CalculateKeyForceResult;
extern CalculateKey const CalculateKeyFormat;
extern CalculateKey const CalculateKeyIgnoreProbableSearches;
extern CalculateKey const CalculateKeyLocales;
extern CalculateKey const CalculateKeyLocalizeUnit;
extern CalculateKey const CalculateKeyMatchLocale;
extern CalculateKey const CalculateKeyMaximumConversions;
extern CalculateKey const CalculateKeyNumberFormatter;
extern CalculateKey const CalculateKeyPreferMixedUnits;
extern CalculateKey const CalculateKeyScientificNotationFormat;
extern CalculateKey const CalculateKeyUnitFormat;
extern CalculateKey const CalculateKeyVariables;

extern NSErrorDomain const CalculateErrorDomain;
extern NSString *const CalculateErrorKeySuggestions;

/// How an expression is evaluated (options; Finch evaluates in decimal).
typedef NS_OPTIONS(NSUInteger, CalculateEngine) {
    CalculateEngineDefault = 0,
};

/// How a result is written (options).
typedef NS_OPTIONS(NSUInteger, CalculateFormat) {
    CalculateFormatDefault = 0,
};

@class CalculateResult, CalculateTerm, CalculateUnit, CalculateUnitCategory, CalculateUnitCollection;

/// A unit of a category (metres of length).
@interface CalculateUnit : NSObject
@property (readonly, copy) NSString *name;
@property (copy) NSString *displayName;
@property (copy) NSString *shortName;
@property (weak, nullable) CalculateUnitCategory *category;
@property (readonly) NSUInteger unitType;
@property (readonly) BOOL isBaseUnit;
@property (readonly) NSLocale *locale;
- (BOOL)contains:(NSString *)query;
@end

/// The units of one kind of quantity.
@interface CalculateUnitCategory : NSObject
@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *displayName;
@property (copy) NSArray<CalculateUnit *> *units;
@property (weak, nullable) CalculateUnitCollection *collection;
@property (readonly) NSUInteger unitType;
@property (readonly, nullable) CalculateUnit *preferredFromUnit;
@property (readonly, nullable) CalculateUnit *preferredToUnit;
@property (readonly) NSLocale *locale;
- (BOOL)contains:(CalculateUnit *)unit;
- (nullable CalculateUnit *)findUnitWithName:(NSString *)name;
@end

/// Every category, for some locales.
@interface CalculateUnitCollection : NSObject
@property (copy) NSArray<CalculateUnitCategory *> *categories;
@property (copy) NSArray<NSLocale *> *locales;
+ (instancetype)collectionWithLocales:(nullable NSArray<NSLocale *> *)locales;
- (instancetype)initWithLocales:(nullable NSArray<NSLocale *> *)locales;
- (nullable CalculateUnitCategory *)findCategoryWithName:(NSString *)name;
- (nullable CalculateUnit *)findUnitWithName:(NSString *)name;
@end

/// A value with its units (a result's part: "3 ft" of "3 ft 4 in").
@interface CalculateTerm : NSObject
@property (strong, nullable) NSNumber *value;
@property (readonly, copy) NSArray<CalculateUnit *> *units;
@property (weak, nullable) CalculateResult *result;
@property (readonly, copy) NSString *formattedResult;
@property (readonly, copy) NSString *formattedValue;
@property (readonly, copy) NSString *formattedUnit;
@property (readonly, nullable) CalculateUnit *primaryUnit;
@property (readonly) NSLocale *locale;
+ (instancetype)termWithValue:(nullable NSNumber *)value units:(nullable NSArray<CalculateUnit *> *)units
                       result:(nullable CalculateResult *)result;
@end

/// An evaluated expression: its value, its unit, how it reads.
@interface CalculateResult : NSObject
@property (readonly, copy, nullable) NSString *expression;
@property (readonly, copy) NSString *formattedResult;
@property (readonly, copy, nullable) NSString *formattedExpression;
@property (strong, nullable) NSNumberFormatter *numberFormatter;
@property (copy, nullable) NSArray<NSLocale *> *locales;
@property int minimumFractionDigits;
@property BOOL autoScientificNotation;
@property NSUInteger scientificNotationFormat;
@property BOOL synchronous;
@property (readonly) BOOL assumeDegrees;
@property (readonly) BOOL isTrivial;
@property (readonly) BOOL isPartialExpression;
@property (readonly) BOOL isNaN;
@property (readonly) BOOL hasStaleCurrencyData;
@property (readonly) NSUInteger unitType;
@property (readonly, copy) NSArray<CalculateTerm *> *terms;
@property (readonly, nullable) CalculateResult *inputValueAndUnit;
@property (readonly, copy) NSArray<CalculateResult *> *conversions;
@property (weak, nullable) CalculateResult *parent;
- (instancetype)initWithDouble:(double)value;
/// Finch: the value, and what the result was evaluated from.
@property (readonly) double doubleValue;
- (void)finchSetExpression:(nullable NSString *)expression base:(NSInteger)base integer:(BOOL)integer;
- (void)finchSetTrivial:(BOOL)trivial;
- (void)finchSetFlexibleFractionDigits:(BOOL)flexible;
- (void)finchSetUnitText:(NSString *)text;
- (nullable CalculateResult *)convertedTo:(CalculateUnit *)unit;
- (nullable CalculateResult *)convertedTo:(CalculateUnit *)unit from:(nullable CalculateUnit *)from NS_REFINED_FOR_SWIFT;
- (NSComparisonResult)compare:(CalculateResult *)other;
@end

/// Exchange rates (Finch has no rate service: the cache stays empty).
@interface CalculateCurrencyCache : NSObject
@property (class, readonly) CalculateCurrencyCache *shared;
@property (readonly, nullable) NSDate *lastRefreshDate;
@property (readonly) BOOL needsRefresh;
@property (readonly, copy, nullable) NSDictionary *currencyData;
- (BOOL)refresh;
- (BOOL)refreshIfNeeded;
@end

NS_ASSUME_NONNULL_END

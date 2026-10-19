/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AVTimeFormatter is a small duration formatter used by AVFoundation clients. */
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

@interface AVTimeFormatter : NSFormatter <NSCopying, NSCoding>
@property(nonatomic) NSInteger style;
@property(nonatomic) double formatTemplate;
@property(nonatomic, getter=isFullWidth) BOOL fullWidth;
@property(nonatomic, readonly) BOOL isRightToLeft;
@property(nonatomic, readonly) NSLocale *locale;
@property(nonatomic, readonly) NSString *cachedDateFormatterFormat;
@property(nonatomic, readonly) NSString *cachedDateFormatterTemplate;
- (void)setLocale:(NSLocale *)locale;
- (void)setIsRightToLeft:(BOOL)value;
- (void)setCachedDateFormatterFormat:(NSString *)format;
- (void)setCachedDateFormatterTemplate:(NSString *)template;
- (NSNumberFormatter *)numberFormatterWithOneMinimumIntegerDigits;
- (void)setNumberFormatterWithOneMinimumIntegerDigits:(NSNumberFormatter *)formatter;
- (NSNumberFormatter *)numberFormatterWithTwoMinimumIntegerDigits;
- (void)setNumberFormatterWithTwoMinimumIntegerDigits:(NSNumberFormatter *)formatter;
- (NSString *)stringFromSeconds:(double)seconds;
- (NSString *)stringFromCMTime:(CMTime)time;
- (NSString *)stringFromTimeInterval:(NSTimeInterval)timeInterval;
@end

static BOOL
AVTimeHundredths(double seconds, uint64_t *outValue)
{
    uint64_t bits;
    memcpy(&bits, &seconds, sizeof(bits));
    uint64_t exponent = (bits >> 52) & 0x7FF;
    uint64_t significand = bits & ((1ULL << 52) - 1);
    int power;
    if (exponent == 0) {
        power = -1074;
    } else {
        significand |= 1ULL << 52;
        power = (int)exponent - 1023 - 52;
    }
    uint64_t scaled = significand * 100;
    if (power >= 0) {
        if (power >= 64 || scaled > (UINT64_MAX >> power))
            return NO;
        *outValue = scaled << power;
    } else {
        unsigned shift = (unsigned)-power;
        *outValue = shift >= 64 ? 0 : scaled >> shift;
    }
    return YES;
}

@implementation AVTimeFormatter {
    NSInteger _style;
    double _formatTemplate;
    BOOL _fullWidth;
    BOOL _rightToLeft;
    NSLocale *_locale;
    NSString *_cachedDateFormatterFormat;
    NSString *_cachedDateFormatterTemplate;
    NSNumberFormatter *_oneDigitFormatter;
    NSNumberFormatter *_twoDigitFormatter;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _style = 0;
        _formatTemplate = 0;
    }
    return self;
}

- (NSInteger)style { return _style; }
- (void)setStyle:(NSInteger)style
{
    if (style < 0 || style > 3)
        [NSException raise:NSInvalidArgumentException format:@"-[AVTimeFormatter setStyle:]: unsupported style"];
    _style = style;
}
- (double)formatTemplate { return _formatTemplate; }
- (void)setFormatTemplate:(double)value { _formatTemplate = value; }
- (BOOL)isFullWidth { return _fullWidth; }
- (void)setFullWidth:(BOOL)value { _fullWidth = value; }
- (BOOL)isRightToLeft { return _rightToLeft; }
- (void)setIsRightToLeft:(BOOL)value { _rightToLeft = value; }
- (NSLocale *)locale { return _locale; }
- (void)setLocale:(NSLocale *)locale { _locale = [locale copy]; }
- (NSString *)cachedDateFormatterFormat { return _cachedDateFormatterFormat; }
- (void)setCachedDateFormatterFormat:(NSString *)format { _cachedDateFormatterFormat = [format copy]; }
- (NSString *)cachedDateFormatterTemplate { return _cachedDateFormatterTemplate; }
- (void)setCachedDateFormatterTemplate:(NSString *)template { _cachedDateFormatterTemplate = [template copy]; }

- (NSNumberFormatter *)_numberFormatterWithMinimumDigits:(NSUInteger)digits
{
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.minimumIntegerDigits = digits;
    if (_locale)
        formatter.locale = _locale;
    return formatter;
}

- (NSNumberFormatter *)numberFormatterWithOneMinimumIntegerDigits
{
    if (!_oneDigitFormatter)
        _oneDigitFormatter = [self _numberFormatterWithMinimumDigits:1];
    return _oneDigitFormatter;
}
- (void)setNumberFormatterWithOneMinimumIntegerDigits:(NSNumberFormatter *)formatter
{
    _oneDigitFormatter = formatter;
}
- (NSNumberFormatter *)numberFormatterWithTwoMinimumIntegerDigits
{
    if (!_twoDigitFormatter)
        _twoDigitFormatter = [self _numberFormatterWithMinimumDigits:2];
    return _twoDigitFormatter;
}
- (void)setNumberFormatterWithTwoMinimumIntegerDigits:(NSNumberFormatter *)formatter
{
    _twoDigitFormatter = formatter;
}

- (NSString *)_integerString:(uint64_t)value minimumDigits:(NSUInteger)digits
{
    NSNumberFormatter *formatter = digits == 2 ? self.numberFormatterWithTwoMinimumIntegerDigits : self.numberFormatterWithOneMinimumIntegerDigits;
    NSString *string = [formatter stringFromNumber:@(value)];
    if (string)
        return string;
    return digits == 2 ? [NSString stringWithFormat:@"%02llu", (unsigned long long)value] :
                         [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

- (NSString *)_stringForSeconds:(double)seconds centiseconds:(BOOL)centiseconds
{
    if (!isfinite(seconds))
        return centiseconds ? @"−−:−−:−−.−−" : @"−−:−−:−−";

    BOOL negative = seconds < 0;
    double magnitude = fabs(seconds);
    if (centiseconds) {
        uint64_t hundredths;
        if (!AVTimeHundredths(magnitude, &hundredths))
            return @"−−:−−:−−.−−";
        uint64_t whole = hundredths / 100;
        uint64_t hours = whole / 3600;
        uint64_t minutes = (whole / 60) % 60;
        uint64_t secondsPart = whole % 60;
        uint64_t fraction = hundredths % 100;
        NSString *hour = [self _integerString:hours minimumDigits:_fullWidth ? 2 : 1];
        NSString *minute = [self _integerString:minutes minimumDigits:2];
        NSString *second = [self _integerString:secondsPart minimumDigits:2];
        NSString *prefix = hours ? [NSString stringWithFormat:@"%@:%@:%@", hour, minute, second] :
                                   [NSString stringWithFormat:@"%@:%@", [self _integerString:whole / 60 minimumDigits:1], second];
        NSString *result = [prefix stringByAppendingFormat:@".%@", [self _integerString:fraction minimumDigits:2]];
        if (negative)
            return [@"\u200e−" stringByAppendingString:result];
        return result;
    }

    if (magnitude >= (double)INT64_MAX - 1)
        return @"−−:−−:−−";
    uint64_t whole = (uint64_t)floor(magnitude + 0.5);
    uint64_t hours = whole / 3600;
    uint64_t minutes = (whole / 60) % 60;
    uint64_t secondsPart = whole % 60;
    BOOL showNegative = _style == 2 ? !negative : negative;
    NSString *hour = [self _integerString:hours minimumDigits:_fullWidth ? 2 : 1];
    NSString *minute = [self _integerString:minutes minimumDigits:2];
    NSString *second = [self _integerString:secondsPart minimumDigits:2];
    NSString *result = hours ? [NSString stringWithFormat:@"%@:%@:%@", hour, minute, second] :
                               [NSString stringWithFormat:@"%@:%@", [self _integerString:whole / 60 minimumDigits:1], second];
    if (showNegative)
        return [@"\u200e−" stringByAppendingString:result];
    if (_style == 2)
        return [@"\u200e+" stringByAppendingString:result];
    return result;
}

- (NSString *)stringFromSeconds:(double)seconds
{
    return [self _stringForSeconds:seconds centiseconds:_style == 3];
}
- (NSString *)stringFromTimeInterval:(NSTimeInterval)timeInterval
{
    return [self stringFromSeconds:timeInterval];
}
- (NSString *)stringFromCMTime:(CMTime)time
{
    if (!CMTIME_IS_VALID(time) || CMTIME_IS_INDEFINITE(time))
        return _style == 3 ? @"−−:−−.−−" : @"−−:−−";
    return [self stringFromSeconds:CMTimeGetSeconds(time)];
}

- (NSString *)stringForObjectValue:(id)object
{
    if (![object isKindOfClass:[NSNumber class]])
        return nil;
    return [self stringFromTimeInterval:[object doubleValue]];
}

- (BOOL)getObjectValue:(out id *)object forString:(NSString *)string errorDescription:(out NSString **)error
{
    if (object)
        *object = nil;
    if (error)
        *error = nil;
    return NO;
}

- (id)copyWithZone:(NSZone *)zone
{
    AVTimeFormatter *copy = [[[self class] allocWithZone:zone] init];
    copy->_style = _style;
    copy->_formatTemplate = _formatTemplate;
    copy->_fullWidth = _fullWidth;
    copy->_rightToLeft = _rightToLeft;
    copy->_locale = [_locale copy];
    copy->_cachedDateFormatterFormat = [_cachedDateFormatterFormat copy];
    copy->_cachedDateFormatterTemplate = [_cachedDateFormatterTemplate copy];
    copy->_oneDigitFormatter = [_oneDigitFormatter copy];
    copy->_twoDigitFormatter = [_twoDigitFormatter copy];
    return copy;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_style forKey:@"style"];
    [coder encodeDouble:_formatTemplate forKey:@"formatTemplate"];
    [coder encodeBool:_fullWidth forKey:@"fullWidth"];
    [coder encodeBool:_rightToLeft forKey:@"isRightToLeft"];
    [coder encodeObject:_locale forKey:@"locale"];
    [coder encodeObject:_cachedDateFormatterFormat forKey:@"cachedDateFormatterFormat"];
    [coder encodeObject:_cachedDateFormatterTemplate forKey:@"cachedDateFormatterTemplate"];
    [coder encodeObject:_oneDigitFormatter forKey:@"numberFormatterWithOneMinimumIntegerDigits"];
    [coder encodeObject:_twoDigitFormatter forKey:@"numberFormatterWithTwoMinimumIntegerDigits"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (self) {
        NSInteger style = [coder decodeIntegerForKey:@"style"];
        if (style >= 0 && style <= 3)
            _style = style;
        _formatTemplate = [coder decodeDoubleForKey:@"formatTemplate"];
        _fullWidth = [coder decodeBoolForKey:@"fullWidth"];
        _rightToLeft = [coder decodeBoolForKey:@"isRightToLeft"];
        _locale = [coder decodeObjectForKey:@"locale"];
        _cachedDateFormatterFormat = [coder decodeObjectForKey:@"cachedDateFormatterFormat"];
        _cachedDateFormatterTemplate = [coder decodeObjectForKey:@"cachedDateFormatterTemplate"];
        _oneDigitFormatter = [coder decodeObjectForKey:@"numberFormatterWithOneMinimumIntegerDigits"];
        _twoDigitFormatter = [coder decodeObjectForKey:@"numberFormatterWithTwoMinimumIntegerDigits"];
    }
    return self;
}
@end

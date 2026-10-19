/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Caption values keep their text, timing, region, and per-character styles. */
#import "AVFInternal.h"
#import <AVFoundation/AVCaption.h>
#import <AVFoundation/AVCaptionGroup.h>
#import <AVFoundation/AVCaptionGrouper.h>
#include <math.h>

static NSString * const AVFCaptionTextColorKey = @"FinchCaptionTextColor";
static NSString * const AVFCaptionBackgroundColorKey = @"FinchCaptionBackgroundColor";
static NSString * const AVFCaptionFontWeightKey = @"FinchCaptionFontWeight";
static NSString * const AVFCaptionFontStyleKey = @"FinchCaptionFontStyle";
static NSString * const AVFCaptionDecorationKey = @"FinchCaptionDecoration";
static NSString * const AVFCaptionTextCombineKey = @"FinchCaptionTextCombine";
static NSString * const AVFCaptionRubyKey = @"FinchCaptionRuby";

@interface AVCaptionRegion (FinchCaptionRegion)
- (instancetype)initWithFinchIdentifier:(NSString *)identifier origin:(AVCaptionPoint)origin size:(AVCaptionSize)size scroll:(AVCaptionRegionScroll)scroll alignment:(AVCaptionRegionDisplayAlignment)alignment writingMode:(AVCaptionRegionWritingMode)writingMode;
- (void)_finchSetOrigin:(AVCaptionPoint)origin;
- (void)_finchSetSize:(AVCaptionSize)size;
- (void)_finchSetScroll:(AVCaptionRegionScroll)scroll;
- (void)_finchSetAlignment:(AVCaptionRegionDisplayAlignment)alignment;
- (void)_finchSetWritingMode:(AVCaptionRegionWritingMode)writingMode;
+ (AVCaptionRegion *)_finchPreset:(NSString *)identifier origin:(AVCaptionPoint)origin size:(AVCaptionSize)size scroll:(AVCaptionRegionScroll)scroll alignment:(AVCaptionRegionDisplayAlignment)alignment writingMode:(AVCaptionRegionWritingMode)writingMode;
@end

@interface AVCaption (FinchCaption)
- (void)_finchConfigureWithAttributedText:(NSAttributedString *)text timeRange:(CMTimeRange)timeRange region:(AVCaptionRegion *)region alignment:(AVCaptionTextAlignment)alignment animation:(AVCaptionAnimation)animation;
- (NSMutableAttributedString *)_finchAttributedText;
- (void)_finchSetAttributedText:(NSAttributedString *)text;
- (void)_finchSetRegion:(AVCaptionRegion *)region;
- (void)_finchSetAlignment:(AVCaptionTextAlignment)alignment;
- (void)_finchSetAnimation:(AVCaptionAnimation)animation;
- (void)_finchSetTimeRange:(CMTimeRange)timeRange;
@end

@interface AVCaptionGroup (FinchCaptionGroup)
- (instancetype)initWithFinchCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange;
@end

@implementation AVCaptionRegion {
    NSString *_finchIdentifier;
    AVCaptionPoint _finchOrigin;
    AVCaptionSize _finchSize;
    AVCaptionRegionScroll _finchScroll;
    AVCaptionRegionDisplayAlignment _finchAlignment;
    AVCaptionRegionWritingMode _finchWritingMode;
}

@dynamic appleITTTopRegion, appleITTBottomRegion, appleITTLeftRegion, appleITTRightRegion, subRipTextBottomRegion;

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithFinchIdentifier:(NSString *)identifier origin:(AVCaptionPoint)origin size:(AVCaptionSize)size scroll:(AVCaptionRegionScroll)scroll alignment:(AVCaptionRegionDisplayAlignment)alignment writingMode:(AVCaptionRegionWritingMode)writingMode
{
    if ((self = [super init])) {
        _finchIdentifier = [identifier copy];
        _finchOrigin = origin;
        _finchSize = size;
        _finchScroll = scroll;
        _finchAlignment = alignment;
        _finchWritingMode = writingMode;
    }
    return self;
}

- (NSString *)identifier { return _finchIdentifier; }
- (AVCaptionPoint)origin { return _finchOrigin; }
- (AVCaptionSize)size { return _finchSize; }
- (AVCaptionRegionScroll)scroll { return _finchScroll; }
- (AVCaptionRegionDisplayAlignment)displayAlignment { return _finchAlignment; }
- (AVCaptionRegionWritingMode)writingMode { return _finchWritingMode; }
- (void)_finchSetOrigin:(AVCaptionPoint)value { _finchOrigin = value; }
- (void)_finchSetSize:(AVCaptionSize)value { _finchSize = value; }
- (void)_finchSetScroll:(AVCaptionRegionScroll)value { _finchScroll = value; }
- (void)_finchSetAlignment:(AVCaptionRegionDisplayAlignment)value { _finchAlignment = value; }
- (void)_finchSetWritingMode:(AVCaptionRegionWritingMode)value { _finchWritingMode = value; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_finchIdentifier forKey:@"identifier"];
    [coder encodeDouble:_finchOrigin.x.value forKey:@"originX"];
    [coder encodeInteger:_finchOrigin.x.units forKey:@"originXUnits"];
    [coder encodeDouble:_finchOrigin.y.value forKey:@"originY"];
    [coder encodeInteger:_finchOrigin.y.units forKey:@"originYUnits"];
    [coder encodeDouble:_finchSize.width.value forKey:@"width"];
    [coder encodeInteger:_finchSize.width.units forKey:@"widthUnits"];
    [coder encodeDouble:_finchSize.height.value forKey:@"height"];
    [coder encodeInteger:_finchSize.height.units forKey:@"heightUnits"];
    [coder encodeInteger:_finchScroll forKey:@"scroll"];
    [coder encodeInteger:_finchAlignment forKey:@"alignment"];
    [coder encodeInteger:_finchWritingMode forKey:@"writingMode"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    AVCaptionPoint origin = {
        { [coder decodeDoubleForKey:@"originX"], [coder decodeIntegerForKey:@"originXUnits"] },
        { [coder decodeDoubleForKey:@"originY"], [coder decodeIntegerForKey:@"originYUnits"] }
    };
    AVCaptionSize size = {
        { [coder decodeDoubleForKey:@"width"], [coder decodeIntegerForKey:@"widthUnits"] },
        { [coder decodeDoubleForKey:@"height"], [coder decodeIntegerForKey:@"heightUnits"] }
    };
    return [self initWithFinchIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"]
        origin:origin size:size scroll:[coder decodeIntegerForKey:@"scroll"]
        alignment:[coder decodeIntegerForKey:@"alignment"] writingMode:[coder decodeIntegerForKey:@"writingMode"]];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[AVCaptionRegion allocWithZone:zone] initWithFinchIdentifier:_finchIdentifier origin:_finchOrigin size:_finchSize scroll:_finchScroll alignment:_finchAlignment writingMode:_finchWritingMode];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    if (_finchIdentifier)
        [NSException raise:NSInvalidArgumentException format:@"A caption region with an identifier cannot be mutably copied"];
    AVMutableCaptionRegion *copy = [[AVMutableCaptionRegion allocWithZone:zone] init];
    [copy _finchSetOrigin:_finchOrigin];
    [copy _finchSetSize:_finchSize];
    [copy _finchSetScroll:_finchScroll];
    [copy _finchSetAlignment:_finchAlignment];
    [copy _finchSetWritingMode:_finchWritingMode];
    return copy;
}

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[AVCaptionRegion class]]) return NO;
    AVCaptionRegion *other = object;
    if (_finchIdentifier || other.identifier)
        return _finchIdentifier && other.identifier && [_finchIdentifier isEqualToString:other.identifier];
    AVCaptionPoint origin = other.origin;
    AVCaptionSize size = other.size;
    return _finchOrigin.x.value == origin.x.value && _finchOrigin.x.units == origin.x.units &&
        _finchOrigin.y.value == origin.y.value && _finchOrigin.y.units == origin.y.units &&
        _finchSize.width.value == size.width.value && _finchSize.width.units == size.width.units &&
        _finchSize.height.value == size.height.value && _finchSize.height.units == size.height.units;
}

- (NSUInteger)hash
{
    if (_finchIdentifier) return _finchIdentifier.hash;
    return (NSUInteger)(_finchOrigin.x.value * 31 + _finchOrigin.y.value * 17 + _finchSize.width.value * 7 + _finchSize.height.value);
}

@end

@implementation AVMutableCaptionRegion

- (instancetype)init { return [self initWithFinchIdentifier:nil origin:(AVCaptionPoint){0} size:(AVCaptionSize){0} scroll:AVCaptionRegionScrollNone alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeLeftToRightAndTopToBottom]; }
- (instancetype)initWithIdentifier:(NSString *)identifier { return [self initWithFinchIdentifier:identifier origin:(AVCaptionPoint){0} size:(AVCaptionSize){0} scroll:AVCaptionRegionScrollNone alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeLeftToRightAndTopToBottom]; }
- (void)setOrigin:(AVCaptionPoint)value { [self _finchSetOrigin:value]; }
- (void)setSize:(AVCaptionSize)value { [self _finchSetSize:value]; }
- (void)setScroll:(AVCaptionRegionScroll)value { [self _finchSetScroll:value]; }
- (void)setDisplayAlignment:(AVCaptionRegionDisplayAlignment)value { [self _finchSetAlignment:value]; }
- (void)setWritingMode:(AVCaptionRegionWritingMode)value { [self _finchSetWritingMode:value]; }

@end

@implementation AVCaptionRegion (PresetRegions)

+ (AVCaptionRegion *)_finchPreset:(NSString *)identifier origin:(AVCaptionPoint)origin size:(AVCaptionSize)size scroll:(AVCaptionRegionScroll)scroll alignment:(AVCaptionRegionDisplayAlignment)alignment writingMode:(AVCaptionRegionWritingMode)writingMode
{
    static NSMutableDictionary<NSString *, AVCaptionRegion *> *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ presets = [NSMutableDictionary dictionary]; });
    @synchronized (presets) {
        AVCaptionRegion *region = presets[identifier];
        if (!region) {
            region = [[AVCaptionRegion alloc] initWithFinchIdentifier:identifier origin:origin size:size scroll:scroll alignment:alignment writingMode:writingMode];
            presets[identifier] = region;
        }
        return region;
    }
}

+ (AVCaptionRegion *)appleITTTopRegion
{
    AVCaptionDimension zero = AVCaptionDimensionMake(0, AVCaptionUnitsTypePercent);
    AVCaptionDimension full = AVCaptionDimensionMake(100, AVCaptionUnitsTypePercent);
    AVCaptionDimension height = AVCaptionDimensionMake(15, AVCaptionUnitsTypePercent);
    return [self _finchPreset:@"top" origin:AVCaptionPointMake(zero, zero) size:AVCaptionSizeMake(full, height) scroll:AVCaptionRegionScrollRollUp alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeLeftToRightAndTopToBottom];
}
+ (AVCaptionRegion *)appleITTBottomRegion
{
    AVCaptionDimension zero = AVCaptionDimensionMake(0, AVCaptionUnitsTypePercent);
    AVCaptionDimension y = AVCaptionDimensionMake(85, AVCaptionUnitsTypePercent);
    AVCaptionDimension full = AVCaptionDimensionMake(100, AVCaptionUnitsTypePercent);
    AVCaptionDimension height = AVCaptionDimensionMake(15, AVCaptionUnitsTypePercent);
    return [self _finchPreset:@"bottom" origin:AVCaptionPointMake(zero, y) size:AVCaptionSizeMake(full, height) scroll:AVCaptionRegionScrollRollUp alignment:AVCaptionRegionDisplayAlignmentAfter writingMode:AVCaptionRegionWritingModeLeftToRightAndTopToBottom];
}
+ (AVCaptionRegion *)appleITTLeftRegion
{
    AVCaptionDimension zero = AVCaptionDimensionMake(0, AVCaptionUnitsTypePercent);
    AVCaptionDimension full = AVCaptionDimensionMake(100, AVCaptionUnitsTypePercent);
    AVCaptionDimension width = AVCaptionDimensionMake(15, AVCaptionUnitsTypePercent);
    return [self _finchPreset:@"left" origin:AVCaptionPointMake(zero, zero) size:AVCaptionSizeMake(width, full) scroll:AVCaptionRegionScrollRollUp alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeTopToBottomAndRightToLeft];
}
+ (AVCaptionRegion *)appleITTRightRegion
{
    AVCaptionDimension x = AVCaptionDimensionMake(85, AVCaptionUnitsTypePercent);
    AVCaptionDimension zero = AVCaptionDimensionMake(0, AVCaptionUnitsTypePercent);
    AVCaptionDimension full = AVCaptionDimensionMake(100, AVCaptionUnitsTypePercent);
    AVCaptionDimension width = AVCaptionDimensionMake(15, AVCaptionUnitsTypePercent);
    return [self _finchPreset:@"right" origin:AVCaptionPointMake(x, zero) size:AVCaptionSizeMake(width, full) scroll:AVCaptionRegionScrollRollUp alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeTopToBottomAndRightToLeft];
}
+ (AVCaptionRegion *)subRipTextBottomRegion
{
    AVCaptionDimension zero = AVCaptionDimensionMake(0, AVCaptionUnitsTypeUnspecified);
    AVCaptionDimension cellZero = AVCaptionDimensionMake(0, AVCaptionUnitsTypeCells);
    return [self _finchPreset:@"subRipText_Bottom" origin:AVCaptionPointMake(cellZero, cellZero) size:AVCaptionSizeMake(zero, cellZero) scroll:AVCaptionRegionScrollNone alignment:AVCaptionRegionDisplayAlignmentBefore writingMode:AVCaptionRegionWritingModeLeftToRightAndTopToBottom];
}

@end

@implementation AVCaptionRuby {
    NSString *_finchText;
    AVCaptionRubyPosition _finchPosition;
    AVCaptionRubyAlignment _finchAlignment;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithText:(NSString *)text
{
    if ((self = [super init])) { _finchText = [text copy] ?: @""; _finchPosition = AVCaptionRubyPositionBefore; _finchAlignment = AVCaptionRubyAlignmentDistributeSpaceBetween; }
    return self;
}
- (instancetype)initWithText:(NSString *)text position:(AVCaptionRubyPosition)position alignment:(AVCaptionRubyAlignment)alignment
{
    if ((self = [self initWithText:text])) { _finchPosition = position; _finchAlignment = alignment; }
    return self;
}
- (NSString *)text { return _finchText; }
- (AVCaptionRubyPosition)position { return _finchPosition; }
- (AVCaptionRubyAlignment)alignment { return _finchAlignment; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_finchText forKey:@"text"]; [coder encodeInteger:_finchPosition forKey:@"position"]; [coder encodeInteger:_finchAlignment forKey:@"alignment"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithText:[coder decodeObjectOfClass:[NSString class] forKey:@"text"] ?: @"" position:[coder decodeIntegerForKey:@"position"] alignment:[coder decodeIntegerForKey:@"alignment"]]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)object { AVCaptionRuby *other = object; return object == self || ([object isKindOfClass:[AVCaptionRuby class]] && [_finchText isEqualToString:other.text] && _finchPosition == other.position && _finchAlignment == other.alignment); }
- (NSUInteger)hash { return _finchText.hash ^ (NSUInteger)_finchPosition ^ ((NSUInteger)_finchAlignment << 8); }
@end

@implementation AVCaption {
    NSMutableAttributedString *_finchContent;
    CMTimeRange _finchTimeRange;
    AVCaptionRegion *_finchRegion;
    AVCaptionTextAlignment _finchTextAlignment;
    AVCaptionAnimation _finchAnimation;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithText:(NSString *)text timeRange:(CMTimeRange)timeRange
{
    if ((self = [super init]))
        [self _finchConfigureWithAttributedText:[[NSAttributedString alloc] initWithString:text ?: @""] timeRange:timeRange region:nil alignment:AVCaptionTextAlignmentCenter animation:AVCaptionAnimationNone];
    return self;
}
- (void)_finchConfigureWithAttributedText:(NSAttributedString *)text timeRange:(CMTimeRange)timeRange region:(AVCaptionRegion *)region alignment:(AVCaptionTextAlignment)alignment animation:(AVCaptionAnimation)animation
{
    _finchContent = [text mutableCopy] ?: [[NSMutableAttributedString alloc] initWithString:@""];
    _finchTimeRange = timeRange;
    _finchRegion = [region copy];
    _finchTextAlignment = alignment;
    _finchAnimation = animation;
}
- (NSString *)text { return _finchContent.string; }
- (CMTimeRange)timeRange { return _finchTimeRange; }
- (AVCaptionRegion *)region { return _finchRegion; }
- (AVCaptionTextAlignment)textAlignment { return _finchTextAlignment; }
- (AVCaptionAnimation)animation { return _finchAnimation; }
- (NSMutableAttributedString *)_finchAttributedText { return _finchContent; }
- (void)_finchSetAttributedText:(NSAttributedString *)text { _finchContent = [text mutableCopy] ?: [[NSMutableAttributedString alloc] initWithString:@""]; }
- (void)_finchSetRegion:(AVCaptionRegion *)region { _finchRegion = [region copy]; }
- (void)_finchSetAlignment:(AVCaptionTextAlignment)alignment { if (alignment > AVCaptionTextAlignmentRight) [NSException raise:NSInvalidArgumentException format:@"Invalid caption alignment"]; _finchTextAlignment = alignment; }
- (void)_finchSetAnimation:(AVCaptionAnimation)animation { _finchAnimation = animation; }
- (void)_finchSetTimeRange:(CMTimeRange)timeRange { _finchTimeRange = timeRange; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_finchContent forKey:@"content"];
    [coder encodeObject:[NSValue valueWithCMTimeRange:_finchTimeRange] forKey:@"timeRange"];
    [coder encodeObject:_finchRegion forKey:@"region"];
    [coder encodeInteger:_finchTextAlignment forKey:@"alignment"];
    [coder encodeInteger:_finchAnimation forKey:@"animation"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSAttributedString *content = [coder decodeObjectOfClass:[NSAttributedString class] forKey:@"content"] ?: [[NSAttributedString alloc] initWithString:@""];
    NSValue *time = [coder decodeObjectOfClass:[NSValue class] forKey:@"timeRange"];
    AVCaptionRegion *region = [coder decodeObjectOfClass:[AVCaptionRegion class] forKey:@"region"];
    if ((self = [self initWithText:content.string timeRange:time ? time.CMTimeRangeValue : kCMTimeRangeInvalid]))
        [self _finchConfigureWithAttributedText:content timeRange:time ? time.CMTimeRangeValue : kCMTimeRangeInvalid region:region alignment:[coder decodeIntegerForKey:@"alignment"] animation:[coder decodeIntegerForKey:@"animation"]];
    return self;
}
- (id)copyWithZone:(NSZone *)zone
{
    if (![self isKindOfClass:[AVMutableCaption class]])
        return self;
    AVCaption *copy = [[AVCaption allocWithZone:zone] initWithText:self.text timeRange:_finchTimeRange];
    [copy _finchConfigureWithAttributedText:_finchContent timeRange:_finchTimeRange region:_finchRegion alignment:_finchTextAlignment animation:_finchAnimation];
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone { AVMutableCaption *copy = [[AVMutableCaption allocWithZone:zone] initWithText:self.text timeRange:_finchTimeRange]; [copy _finchConfigureWithAttributedText:_finchContent timeRange:_finchTimeRange region:_finchRegion alignment:_finchTextAlignment animation:_finchAnimation]; return copy; }

- (id)_finchAttribute:(NSString *)key atIndex:(NSInteger)index range:(NSRange *)range defaultValue:(id)value
{
    if (index < 0 || (NSUInteger)index >= _finchContent.length) {
        if (range) *range = NSMakeRange(index < 0 ? 0 : _finchContent.length, 0);
        return value;
    }
    NSRange effective;
    id found = [_finchContent attribute:key atIndex:(NSUInteger)index longestEffectiveRange:&effective inRange:NSMakeRange(0, _finchContent.length)];
    if (range) *range = effective;
    return found ?: value;
}
- (CGColorRef)textColorAtIndex:(NSInteger)index range:(NSRange *)range
{
    id color = [self _finchAttribute:AVFCaptionTextColorKey atIndex:index range:range defaultValue:nil];
    return color ? CGColorCreateCopy((__bridge CGColorRef)color) : NULL;
}
- (CGColorRef)backgroundColorAtIndex:(NSInteger)index range:(NSRange *)range
{
    id color = [self _finchAttribute:AVFCaptionBackgroundColorKey atIndex:index range:range defaultValue:nil];
    return color ? CGColorCreateCopy((__bridge CGColorRef)color) : NULL;
}
- (AVCaptionFontWeight)fontWeightAtIndex:(NSInteger)index range:(NSRange *)range { return [[self _finchAttribute:AVFCaptionFontWeightKey atIndex:index range:range defaultValue:@(AVCaptionFontWeightUnknown)] integerValue]; }
- (AVCaptionFontStyle)fontStyleAtIndex:(NSInteger)index range:(NSRange *)range { return [[self _finchAttribute:AVFCaptionFontStyleKey atIndex:index range:range defaultValue:@(AVCaptionFontStyleUnknown)] integerValue]; }
- (AVCaptionDecoration)decorationAtIndex:(NSInteger)index range:(NSRange *)range { return [[self _finchAttribute:AVFCaptionDecorationKey atIndex:index range:range defaultValue:@(AVCaptionDecorationNone)] unsignedIntegerValue]; }
- (AVCaptionTextCombine)textCombineAtIndex:(NSInteger)index range:(NSRange *)range { return [[self _finchAttribute:AVFCaptionTextCombineKey atIndex:index range:range defaultValue:@(AVCaptionTextCombineNone)] integerValue]; }
- (AVCaptionRuby *)rubyAtIndex:(NSInteger)index range:(NSRange *)range { return [self _finchAttribute:AVFCaptionRubyKey atIndex:index range:range defaultValue:nil]; }
@end

@implementation AVMutableCaption
- (void)setText:(NSString *)text { [self _finchSetAttributedText:[[NSAttributedString alloc] initWithString:text ?: @""]]; }
- (void)setTimeRange:(CMTimeRange)range { [self _finchSetTimeRange:range]; }
- (void)setRegion:(AVCaptionRegion *)region { [self _finchSetRegion:region]; }
- (void)setTextAlignment:(AVCaptionTextAlignment)alignment { [self _finchSetAlignment:alignment]; }
- (void)setAnimation:(AVCaptionAnimation)animation { [self _finchSetAnimation:animation]; }
- (void)_finchSetAttribute:(NSString *)key value:(id)value range:(NSRange)range
{
    if (range.location > self.text.length || range.length > self.text.length - range.location)
        [NSException raise:NSRangeException format:@"Caption style range is outside the text"];
    if (range.length) [[self _finchAttributedText] addAttribute:key value:value range:range];
}
- (void)_finchRemoveAttribute:(NSString *)key range:(NSRange)range
{
    if (range.location > self.text.length || range.length > self.text.length - range.location)
        [NSException raise:NSRangeException format:@"Caption style range is outside the text"];
    if (range.length) [[self _finchAttributedText] removeAttribute:key range:range];
}
- (void)setTextColor:(CGColorRef)color inRange:(NSRange)range { if (color) [self _finchSetAttribute:AVFCaptionTextColorKey value:(__bridge id)color range:range]; }
- (void)setBackgroundColor:(CGColorRef)color inRange:(NSRange)range { if (color) [self _finchSetAttribute:AVFCaptionBackgroundColorKey value:(__bridge id)color range:range]; }
- (void)setFontWeight:(AVCaptionFontWeight)value inRange:(NSRange)range { [self _finchSetAttribute:AVFCaptionFontWeightKey value:@(value) range:range]; }
- (void)setFontStyle:(AVCaptionFontStyle)value inRange:(NSRange)range { [self _finchSetAttribute:AVFCaptionFontStyleKey value:@(value) range:range]; }
- (void)setDecoration:(AVCaptionDecoration)value inRange:(NSRange)range { [self _finchSetAttribute:AVFCaptionDecorationKey value:@(value) range:range]; }
- (void)setTextCombine:(AVCaptionTextCombine)value inRange:(NSRange)range { [self _finchSetAttribute:AVFCaptionTextCombineKey value:@(value) range:range]; }
- (void)setRuby:(AVCaptionRuby *)value inRange:(NSRange)range { if (value) [self _finchSetAttribute:AVFCaptionRubyKey value:value range:range]; }
- (void)removeTextColorInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionTextColorKey range:range]; }
- (void)removeBackgroundColorInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionBackgroundColorKey range:range]; }
- (void)removeFontWeightInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionFontWeightKey range:range]; }
- (void)removeFontStyleInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionFontStyleKey range:range]; }
- (void)removeDecorationInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionDecorationKey range:range]; }
- (void)removeTextCombineInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionTextCombineKey range:range]; }
- (void)removeRubyInRange:(NSRange)range { [self _finchRemoveAttribute:AVFCaptionRubyKey range:range]; }
@end

AVCaptionDimension AVCaptionDimensionMake(CGFloat value, AVCaptionUnitsType units) { return (AVCaptionDimension){ value, units }; }
AVCaptionPoint AVCaptionPointMake(AVCaptionDimension x, AVCaptionDimension y) { return (AVCaptionPoint){ x, y }; }
AVCaptionSize AVCaptionSizeMake(AVCaptionDimension width, AVCaptionDimension height) { return (AVCaptionSize){ width, height }; }

@implementation AVCaptionGroup {
    NSArray<AVCaption *> *_finchCaptions;
    CMTimeRange _finchTimeRange;
}

- (instancetype)initWithFinchCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange
{
    if ((self = [super init])) {
        _finchCaptions = [captions copy] ?: @[];
        _finchTimeRange = timeRange;
    }
    return self;
}

- (instancetype)initWithCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange
{
    if (!CMTIME_IS_NUMERIC(timeRange.start) || !CMTIME_IS_NUMERIC(timeRange.duration) || CMTimeCompare(timeRange.duration, kCMTimeZero) < 0)
        [NSException raise:NSInvalidArgumentException format:@"Invalid caption group time range"];
    for (AVCaption *caption in captions)
        if (![caption isKindOfClass:[AVCaption class]] || !CMTimeRangeContainsTimeRange(timeRange, caption.timeRange))
            [NSException raise:NSInvalidArgumentException format:@"Caption is outside the caption group time range"];
    if ((self = [super init])) {
        _finchCaptions = [captions copy] ?: @[];
        _finchTimeRange = timeRange;
    }
    return self;
}

- (instancetype)initWithTimeRange:(CMTimeRange)timeRange
{
    return [self initWithCaptions:@[] timeRange:timeRange];
}

- (CMTimeRange)timeRange { return _finchTimeRange; }
- (NSArray<AVCaption *> *)captions { return _finchCaptions ?: @[]; }

@end

@implementation AVCaptionGrouper {
    NSMutableArray<AVCaption *> *_finchPendingCaptions;
    CMTime _finchPosition;
    BOOL _finchHasPosition;
}

- (instancetype)init
{
    if ((self = [super init]))
        _finchPendingCaptions = [NSMutableArray array];
    return self;
}

- (void)addCaption:(AVCaption *)caption
{
    if (![caption isKindOfClass:[AVCaption class]])
        [NSException raise:NSInvalidArgumentException format:@"Expected an AVCaption"];
    if (!_finchHasPosition || CMTimeCompare(caption.timeRange.start, _finchPosition) >= 0)
        [_finchPendingCaptions addObject:caption];
}

- (NSArray<AVCaptionGroup *> *)flushAddedCaptionsIntoGroupsUpToTime:(CMTime)upToTime
{
    if (!CMTIME_IS_NUMERIC(upToTime))
        [NSException raise:NSInvalidArgumentException format:@"The flush time must be numeric"];
    if (!_finchPendingCaptions.count)
        return @[];

    CMTime start = _finchPosition;
    if (!_finchHasPosition) {
        start = ((AVCaption *)_finchPendingCaptions.firstObject).timeRange.start;
        for (AVCaption *caption in _finchPendingCaptions)
            if (CMTimeCompare(caption.timeRange.start, start) < 0)
                start = caption.timeRange.start;
    }
    CMTime timelineEnd = ((AVCaption *)_finchPendingCaptions.firstObject).timeRange.duration;
    timelineEnd = CMTimeAdd(((AVCaption *)_finchPendingCaptions.firstObject).timeRange.start, timelineEnd);
    for (AVCaption *caption in _finchPendingCaptions) {
        CMTime end = CMTimeRangeGetEnd(caption.timeRange);
        if (CMTimeCompare(end, timelineEnd) > 0)
            timelineEnd = end;
    }
    if (CMTimeCompare(timelineEnd, upToTime) > 0)
        timelineEnd = upToTime;
    if (CMTimeCompare(timelineEnd, start) <= 0)
        return @[];

    NSMutableArray<NSValue *> *boundaries = [NSMutableArray arrayWithObject:[NSValue valueWithCMTime:start]];
    [boundaries addObject:[NSValue valueWithCMTime:timelineEnd]];
    for (AVCaption *caption in _finchPendingCaptions) {
        CMTime points[] = { caption.timeRange.start, CMTimeRangeGetEnd(caption.timeRange) };
        for (NSUInteger i = 0; i < 2; i++)
            if (CMTimeCompare(points[i], start) > 0 && CMTimeCompare(points[i], timelineEnd) < 0)
                [boundaries addObject:[NSValue valueWithCMTime:points[i]]];
    }
    [boundaries sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return CMTimeCompare(a.CMTimeValue, b.CMTimeValue);
    }];

    NSMutableArray<AVCaptionGroup *> *groups = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < boundaries.count; i++) {
        CMTime from = boundaries[i].CMTimeValue;
        CMTime to = boundaries[i + 1].CMTimeValue;
        if (CMTimeCompare(to, from) <= 0)
            continue;
        NSMutableArray<AVCaption *> *active = [NSMutableArray array];
        for (AVCaption *caption in _finchPendingCaptions) {
            CMTime end = CMTimeRangeGetEnd(caption.timeRange);
            if (CMTimeCompare(caption.timeRange.start, from) <= 0 && CMTimeCompare(end, from) > 0)
                [active addObject:caption];
        }
        AVCaptionGroup *group = [[AVCaptionGroup alloc] initWithFinchCaptions:active timeRange:CMTimeRangeFromTimeToTime(from, to)];
        [groups addObject:group];
    }

    NSIndexSet *expired = [_finchPendingCaptions indexesOfObjectsPassingTest:^BOOL(AVCaption *caption, NSUInteger idx, BOOL *stop) {
        return CMTimeCompare(CMTimeRangeGetEnd(caption.timeRange), upToTime) <= 0;
    }];
    [_finchPendingCaptions removeObjectsAtIndexes:expired];
    _finchPosition = upToTime;
    _finchHasPosition = YES;
    return groups;
}

@end

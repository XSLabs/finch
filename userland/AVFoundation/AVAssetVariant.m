/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Immutable values used by Finch's asset variant reader and download qualifiers. */
#import "AVFInternal.h"

@interface AVAssetVariantVideoAttributes ()
- (instancetype)initWithFinchVideoRange:(AVVideoRange)range codecTypes:(NSArray<NSNumber *> *)codecTypes
                          presentationSize:(CGSize)size nominalFrameRate:(double)frameRate
                     videoLayoutAttributes:(NSArray<AVAssetVariantVideoLayoutAttributes *> *)layouts;
@end

@interface AVAssetVariantVideoLayoutAttributes ()
- (instancetype)initWithFinchStereoComponents:(CMStereoViewComponents)components projection:(CMProjectionType)projection;
@end

@interface AVAssetVariantAudioRenditionSpecificAttributes ()
- (instancetype)initWithFinchChannelCount:(NSInteger)channelCount binaural:(BOOL)binaural immersive:(BOOL)immersive downmix:(BOOL)downmix;
@end

@interface AVAssetVariantAudioAttributes ()
- (instancetype)initWithFinchFormatIDs:(NSArray<NSNumber *> *)formatIDs renditions:(NSDictionary<AVMediaSelectionOption *, AVAssetVariantAudioRenditionSpecificAttributes *> *)renditions;
@end

@interface AVAssetVariant ()
- (instancetype)initWithFinchURL:(NSURL *)URL peakBitRate:(double)peakBitRate averageBitRate:(double)averageBitRate
                   videoAttributes:(AVAssetVariantVideoAttributes *)video audioAttributes:(AVAssetVariantAudioAttributes *)audio;
@end

@interface AVAssetVariantQualifier ()
- (instancetype)initWithFinchPredicate:(NSPredicate *)predicate variant:(AVAssetVariant *)variant;
@end

/* Foundation's parser removes whitespace before the comma in FUNCTION(). Apple
 * keeps it in this public formatting, so preserve that spelling while handing
 * evaluation to the normal predicate parser. */
@interface AVAssetVariantPredicate : NSPredicate {
    NSString *_fFormat;
    NSPredicate *_fParsedPredicate;
}
- (instancetype)initWithFormat:(NSString *)format parsedPredicate:(NSPredicate *)predicate;
@end

@implementation AVAssetVariantPredicate
- (instancetype)initWithFormat:(NSString *)format parsedPredicate:(NSPredicate *)predicate
{
    if ((self = [super init])) {
        _fFormat = [format copy];
        _fParsedPredicate = predicate;
    }
    return self;
}
- (NSString *)predicateFormat { return _fFormat; }
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings
{
    return [_fParsedPredicate evaluateWithObject:object substitutionVariables:bindings];
}
- (instancetype)predicateWithSubstitutionVariables:(NSDictionary *)variables
{
    NSPredicate *substituted = [_fParsedPredicate predicateWithSubstitutionVariables:variables];
    return [[[self class] alloc] initWithFormat:[substituted predicateFormat] parsedPredicate:substituted];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation AVAssetVariant {
    NSURL *_fURL;
    double _fPeakBitRate, _fAverageBitRate;
    AVAssetVariantVideoAttributes *_fVideoAttributes;
    AVAssetVariantAudioAttributes *_fAudioAttributes;
}
- (instancetype)initWithFinchURL:(NSURL *)URL peakBitRate:(double)peakBitRate averageBitRate:(double)averageBitRate
                   videoAttributes:(AVAssetVariantVideoAttributes *)video audioAttributes:(AVAssetVariantAudioAttributes *)audio
{
    if ((self = [super init])) {
        _fURL = [URL copy];
        _fPeakBitRate = peakBitRate;
        _fAverageBitRate = averageBitRate;
        _fVideoAttributes = video;
        _fAudioAttributes = audio;
    }
    return self;
}
- (double)peakBitRate { return _fPeakBitRate; }
- (double)averageBitRate { return _fAverageBitRate; }
- (AVAssetVariantVideoAttributes *)videoAttributes { return _fVideoAttributes; }
- (AVAssetVariantAudioAttributes *)audioAttributes { return _fAudioAttributes; }
- (NSURL *)URL { return _fURL; }
@end

@implementation AVAssetVariantVideoAttributes {
    AVVideoRange _fVideoRange;
    NSArray<NSNumber *> *_fCodecTypes;
    CGSize _fPresentationSize;
    double _fNominalFrameRate;
    NSArray<AVAssetVariantVideoLayoutAttributes *> *_fLayouts;
}
- (instancetype)initWithFinchVideoRange:(AVVideoRange)range codecTypes:(NSArray<NSNumber *> *)codecTypes
                          presentationSize:(CGSize)size nominalFrameRate:(double)frameRate
                     videoLayoutAttributes:(NSArray<AVAssetVariantVideoLayoutAttributes *> *)layouts
{
    if ((self = [super init])) {
        _fVideoRange = [range copy] ?: AVVideoRangeSDR;
        _fCodecTypes = [codecTypes copy] ?: @[];
        _fPresentationSize = size;
        _fNominalFrameRate = frameRate;
        _fLayouts = [layouts copy] ?: @[];
    }
    return self;
}
- (AVVideoRange)videoRange { return _fVideoRange ?: AVVideoRangeSDR; }
- (NSArray<NSNumber *> *)codecTypes { return _fCodecTypes ?: @[]; }
- (CGSize)presentationSize { return _fPresentationSize; }
- (double)nominalFrameRate { return _fNominalFrameRate; }
- (NSArray<AVAssetVariantVideoLayoutAttributes *> *)videoLayoutAttributes { return _fLayouts ?: @[]; }
@end

@implementation AVAssetVariantVideoLayoutAttributes {
    CMStereoViewComponents _fStereoComponents;
    CMProjectionType _fProjectionType;
}
- (instancetype)initWithFinchStereoComponents:(CMStereoViewComponents)components projection:(CMProjectionType)projection
{
    if ((self = [super init])) {
        _fStereoComponents = components;
        _fProjectionType = projection;
    }
    return self;
}
- (CMStereoViewComponents)stereoViewComponents { return _fStereoComponents; }
- (CMProjectionType)projectionType { return _fProjectionType; }
@end

@implementation AVAssetVariantAudioRenditionSpecificAttributes {
    NSInteger _fChannelCount;
    BOOL _fBinaural, _fImmersive, _fDownmix;
}
- (instancetype)initWithFinchChannelCount:(NSInteger)channelCount binaural:(BOOL)binaural immersive:(BOOL)immersive downmix:(BOOL)downmix
{
    if ((self = [super init])) {
        _fChannelCount = channelCount;
        _fBinaural = binaural;
        _fImmersive = immersive;
        _fDownmix = downmix;
    }
    return self;
}
- (NSInteger)channelCount { return _fChannelCount; }
- (BOOL)isBinaural { return _fBinaural; }
- (BOOL)isImmersive { return _fImmersive; }
- (BOOL)isDownmix { return _fDownmix; }
@end

@implementation AVAssetVariantAudioAttributes {
    NSArray<NSNumber *> *_fFormatIDs;
    NSMapTable<AVMediaSelectionOption *, AVAssetVariantAudioRenditionSpecificAttributes *> *_fRenditions;
}
- (instancetype)initWithFinchFormatIDs:(NSArray<NSNumber *> *)formatIDs renditions:(NSDictionary<AVMediaSelectionOption *,AVAssetVariantAudioRenditionSpecificAttributes *> *)renditions
{
    if ((self = [super init])) {
        _fFormatIDs = [formatIDs copy] ?: @[];
        _fRenditions = [NSMapTable strongToStrongObjectsMapTable];
        [renditions enumerateKeysAndObjectsUsingBlock:^(AVMediaSelectionOption *option, AVAssetVariantAudioRenditionSpecificAttributes *attributes, BOOL *stop) {
            [self->_fRenditions setObject:attributes forKey:option];
        }];
    }
    return self;
}
- (NSArray<NSNumber *> *)formatIDs { return _fFormatIDs ?: @[]; }
- (AVAssetVariantAudioRenditionSpecificAttributes *)renditionSpecificAttributesForMediaOption:(AVMediaSelectionOption *)mediaSelectionOption
{
    return mediaSelectionOption ? [_fRenditions objectForKey:mediaSelectionOption] : nil;
}
@end

static NSString *
predicate_operator(NSPredicateOperatorType type)
{
    switch (type) {
    case NSLessThanPredicateOperatorType: return @"<";
    case NSLessThanOrEqualToPredicateOperatorType: return @"<=";
    case NSGreaterThanPredicateOperatorType: return @">";
    case NSGreaterThanOrEqualToPredicateOperatorType: return @">=";
    case NSEqualToPredicateOperatorType: return @"==";
    case NSNotEqualToPredicateOperatorType: return @"!=";
    default:
        [NSException raise:NSInvalidArgumentException format:@"operatorType is not a comparison operator"];
        return nil;
    }
}

static NSPredicate *
comparison_predicate(NSString *keyPath, NSPredicateOperatorType type, double value)
{
    NSString *format = [NSString stringWithFormat:@"%@ %@ %.17g", keyPath, predicate_operator(type), value];
    NSPredicate *parsed = [NSPredicate predicateWithFormat:format];
    return [[AVAssetVariantPredicate alloc] initWithFormat:[parsed predicateFormat] parsedPredicate:parsed];
}

static NSPredicate *
function_predicate(NSString *selector, NSPredicateOperatorType type, double value)
{
    NSString *format = [NSString stringWithFormat:@"FUNCTION(audioAttributes, \"%@\" , $audioMediaSelection) %@ %.17g", selector,
                        predicate_operator(type), value];
    NSString *parserFormat = [format stringByReplacingOccurrencesOfString:@"\" ," withString:@"\","];
    NSPredicate *parsed = [NSPredicate predicateWithFormat:parserFormat];
    return [[AVAssetVariantPredicate alloc] initWithFormat:format parsedPredicate:parsed];
}

static NSPredicate *
boolean_function_predicate(NSString *selector, BOOL value)
{
    NSString *format = [NSString stringWithFormat:@"FUNCTION(audioAttributes, \"%@\" , $audioMediaSelection) == %d", selector, value];
    NSString *parserFormat = [format stringByReplacingOccurrencesOfString:@"\" ," withString:@"\","];
    NSPredicate *parsed = [NSPredicate predicateWithFormat:parserFormat];
    return [[AVAssetVariantPredicate alloc] initWithFormat:format parsedPredicate:parsed];
}

@implementation AVAssetVariantQualifier {
    NSPredicate *_fPredicate;
    AVAssetVariant *_fVariant;
}
+ (instancetype)assetVariantQualifierWithPredicate:(NSPredicate *)predicate
{
    if (!predicate)
        [NSException raise:NSInvalidArgumentException format:@"predicate must not be nil"];
    return [[self alloc] initWithFinchPredicate:predicate variant:nil];
}
+ (instancetype)assetVariantQualifierWithVariant:(AVAssetVariant *)variant
{
    if (!variant)
        [NSException raise:NSInvalidArgumentException format:@"variant must not be nil"];
    return [[self alloc] initWithFinchPredicate:nil variant:variant];
}
- (instancetype)initWithFinchPredicate:(NSPredicate *)predicate variant:(AVAssetVariant *)variant
{
    if ((self = [super init])) {
        _fPredicate = [predicate copy];
        _fVariant = variant;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithFinchPredicate:_fPredicate variant:_fVariant];
}
+ (NSPredicate *)predicateForChannelCount:(NSInteger)channelCount mediaSelectionOption:(AVMediaSelectionOption *)mediaSelectionOption operatorType:(NSPredicateOperatorType)operatorType
{
    return function_predicate(@"channelCountForMediaOption:", operatorType, channelCount);
}
+ (NSPredicate *)predicateForBinauralAudio:(BOOL)isBinauralAudio mediaSelectionOption:(AVMediaSelectionOption *)mediaSelectionOption
{
    return boolean_function_predicate(@"isBinauralMediaOption:", isBinauralAudio);
}
+ (NSPredicate *)predicateForImmersiveAudio:(BOOL)isImmersiveAudio mediaSelectionOption:(AVMediaSelectionOption *)mediaSelectionOption
{
    return boolean_function_predicate(@"isImmersiveMediaOption:", isImmersiveAudio);
}
+ (NSPredicate *)predicateForDownmixAudio:(BOOL)isDownmixAudio mediaSelectionOption:(AVMediaSelectionOption *)mediaSelectionOption
{
    return boolean_function_predicate(@"isDownmixMediaOption:", isDownmixAudio);
}
+ (NSPredicate *)predicateForPresentationWidth:(CGFloat)width operatorType:(NSPredicateOperatorType)operatorType
{
    return comparison_predicate(@"videoAttributes.presentationWidth", operatorType, width);
}
+ (NSPredicate *)predicateForPresentationHeight:(CGFloat)height operatorType:(NSPredicateOperatorType)operatorType
{
    return comparison_predicate(@"videoAttributes.presentationHeight", operatorType, height);
}
+ (NSPredicate *)predicateForAudioSampleRate:(double)sampleRate mediaSelectionOption:(AVMediaSelectionOption *)mediaSelectionOption operatorType:(NSPredicateOperatorType)operatorType
{
    return function_predicate(@"sampleRateForMediaOption:", operatorType, sampleRate);
}
+ (NSPredicate *)predicateForChannelCount:(NSInteger)channelCount operatorType:(NSPredicateOperatorType)operatorType
{
    return [self predicateForChannelCount:channelCount mediaSelectionOption:nil operatorType:operatorType];
}
+ (NSPredicate *)predicateForBinauralAudio:(BOOL)isBinauralAudio
{
    return [self predicateForBinauralAudio:isBinauralAudio mediaSelectionOption:nil];
}
+ (NSPredicate *)predicateForImmersiveAudio:(BOOL)isImmersiveAudio
{
    return [self predicateForImmersiveAudio:isImmersiveAudio mediaSelectionOption:nil];
}
+ (NSPredicate *)predicateForDownmixAudio:(BOOL)isDownmixAudio
{
    return [self predicateForDownmixAudio:isDownmixAudio mediaSelectionOption:nil];
}
+ (NSPredicate *)predicateForAudioSampleRate:(double)sampleRate operatorType:(NSPredicateOperatorType)operatorType
{
    return [self predicateForAudioSampleRate:sampleRate mediaSelectionOption:nil operatorType:operatorType];
}
@end

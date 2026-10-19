/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Convert canonical caption values to the timing rules used by CEA-608. */
#import "AVFInternal.h"
#import <AVFoundation/AVCaptionFormatConformer.h>
#import <AVFoundation/AVCaptionSettings.h>
#import <AVFoundation/AVCaptionConversionValidator.h>
#import <AVFoundation/AVMediaFormat.h>
#include <math.h>

@interface AVCaption (FinchCaptionConversion)
- (void)_finchSetTimeRange:(CMTimeRange)timeRange;
@end

static BOOL AVCaptionIsCEA608(NSDictionary *settings);
static int64_t AVFCeilDivision(int64_t value, int64_t divisor);

@interface AVCaptionConversionAdjustment (FinchCaptionConversion)
- (instancetype)initWithFinchType:(AVCaptionConversionAdjustmentType)type;
@end

@interface AVCaptionConversionTimeRangeAdjustment (FinchCaptionConversion)
- (instancetype)initWithFinchStartOffset:(CMTime)startOffset durationOffset:(CMTime)durationOffset;
@end

@interface AVCaptionConversionWarning (FinchCaptionConversion)
- (instancetype)initWithFinchType:(AVCaptionConversionWarningType)type range:(NSRange)range adjustment:(AVCaptionConversionAdjustment *)adjustment;
@end

@interface AVCaptionConversionValidator (FinchCaptionConversion)
- (instancetype)initWithCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange conversionSettings:(NSDictionary<AVCaptionSettingsKey, id> *)conversionSettings;
@end

@implementation AVCaptionConversionAdjustment {
    AVCaptionConversionAdjustmentType _finchType;
}

- (instancetype)initWithFinchType:(AVCaptionConversionAdjustmentType)type
{
    if ((self = [super init]))
        _finchType = [type copy];
    return self;
}

- (AVCaptionConversionAdjustmentType)adjustmentType { return _finchType; }

@end

@implementation AVCaptionConversionTimeRangeAdjustment {
    CMTime _finchStartOffset;
    CMTime _finchDurationOffset;
}

- (instancetype)initWithFinchStartOffset:(CMTime)startOffset durationOffset:(CMTime)durationOffset
{
    if ((self = [super initWithFinchType:AVCaptionConversionAdjustmentTypeTimeRange])) {
        _finchStartOffset = startOffset;
        _finchDurationOffset = durationOffset;
    }
    return self;
}

- (CMTime)startTimeOffset { return _finchStartOffset; }
- (CMTime)durationOffset { return _finchDurationOffset; }

@end

@implementation AVCaptionConversionWarning {
    AVCaptionConversionWarningType _finchType;
    NSRange _finchRange;
    AVCaptionConversionAdjustment *_finchAdjustment;
}

- (instancetype)initWithFinchType:(AVCaptionConversionWarningType)type range:(NSRange)range adjustment:(AVCaptionConversionAdjustment *)adjustment
{
    if ((self = [super init])) {
        _finchType = [type copy];
        _finchRange = range;
        _finchAdjustment = adjustment;
    }
    return self;
}

- (AVCaptionConversionWarningType)warningType { return _finchType; }
- (NSRange)rangeOfCaptions { return _finchRange; }
- (AVCaptionConversionAdjustment *)adjustment { return _finchAdjustment; }

@end

@implementation AVCaptionConversionValidator {
    NSArray<AVCaption *> *_finchCaptions;
    CMTimeRange _finchTimeRange;
    NSMutableArray<AVCaptionConversionWarning *> *_finchWarnings;
    AVCaptionConversionValidatorStatus _finchStatus;
    NSLock *_finchLock;
}

+ (instancetype)captionConversionValidatorWithCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange conversionSettings:(NSDictionary<AVCaptionSettingsKey,id> *)conversionSettings
{
    return [[self alloc] initWithCaptions:captions timeRange:timeRange conversionSettings:conversionSettings];
}

- (instancetype)initWithCaptions:(NSArray<AVCaption *> *)captions timeRange:(CMTimeRange)timeRange conversionSettings:(NSDictionary<AVCaptionSettingsKey,id> *)conversionSettings
{
    if (!AVCaptionIsCEA608(conversionSettings))
        [NSException raise:NSInvalidArgumentException format:@"Finch can validate closed captions for CEA-608"];
    if (!CMTIME_IS_NUMERIC(timeRange.start) || (!CMTIME_IS_NUMERIC(timeRange.duration) && !CMTIME_IS_POSITIVE_INFINITY(timeRange.duration)))
        [NSException raise:NSInvalidArgumentException format:@"Invalid caption validation time range"];
    for (id caption in captions)
        if (![caption isKindOfClass:[AVCaption class]])
            [NSException raise:NSInvalidArgumentException format:@"Expected AVCaption objects"];
    if ((self = [super init])) {
        _finchCaptions = [captions copy] ?: @[];
        _finchTimeRange = timeRange;
        _finchWarnings = [NSMutableArray array];
        _finchLock = [[NSLock alloc] init];
        _finchStatus = AVCaptionConversionValidatorStatusUnknown;
    }
    return self;
}

- (AVCaptionConversionValidatorStatus)status
{
    [_finchLock lock];
    AVCaptionConversionValidatorStatus value = _finchStatus;
    [_finchLock unlock];
    return value;
}

- (NSArray<AVCaption *> *)captions { return _finchCaptions; }
- (CMTimeRange)timeRange { return _finchTimeRange; }

- (NSArray<AVCaptionConversionWarning *> *)warnings
{
    [_finchLock lock];
    NSArray *value = [_finchWarnings copy];
    [_finchLock unlock];
    return value;
}

- (void)validateCaptionConversionWithWarningHandler:(void (^)(AVCaptionConversionWarning *))handler
{
    [_finchLock lock];
    if (_finchStatus != AVCaptionConversionValidatorStatusUnknown) {
        [_finchLock unlock];
        [NSException raise:NSInvalidArgumentException format:@"Caption validation can only start once"];
    }
    _finchStatus = AVCaptionConversionValidatorStatusValidating;
    [_finchLock unlock];

    void (^completion)(AVCaptionConversionWarning *) = [handler copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (NSUInteger index = 0; index < _finchCaptions.count; index++) {
            [_finchLock lock];
            BOOL stopped = _finchStatus == AVCaptionConversionValidatorStatusStopped;
            [_finchLock unlock];
            if (stopped)
                return;

            AVCaption *caption = _finchCaptions[index];
            CMTime elapsed = CMTimeSubtract(caption.timeRange.start, _finchTimeRange.start);
            CMTime available = CMTIME_IS_NUMERIC(elapsed) ? CMTimeConvertScale(elapsed, 30000, kCMTimeRoundingMethod_RoundHalfAwayFromZero) : kCMTimeZero;
            int64_t neededTicks = (int64_t)caption.text.length * 1001;
            if (neededTicks <= available.value)
                continue;

            CMTime startOffset = CMTimeMake(neededTicks - available.value, 30000);
            AVCaptionConversionTimeRangeAdjustment *adjustment = [[AVCaptionConversionTimeRangeAdjustment alloc]
                initWithFinchStartOffset:startOffset durationOffset:kCMTimeZero];
            AVCaptionConversionWarning *warning = [[AVCaptionConversionWarning alloc]
                initWithFinchType:AVCaptionConversionWarningTypeExcessMediaData range:NSMakeRange(index, 1) adjustment:adjustment];
            [_finchLock lock];
            [_finchWarnings addObject:warning];
            [_finchLock unlock];
            if (completion)
                completion(warning);
        }

        [_finchLock lock];
        BOOL stopped = _finchStatus == AVCaptionConversionValidatorStatusStopped;
        if (!stopped)
            _finchStatus = AVCaptionConversionValidatorStatusCompleted;
        [_finchLock unlock];
        if (!stopped && completion)
            completion(nil);
    });
}

- (void)stopValidating
{
    [_finchLock lock];
    if (_finchStatus == AVCaptionConversionValidatorStatusValidating)
        _finchStatus = AVCaptionConversionValidatorStatusStopped;
    [_finchLock unlock];
}

@end

static BOOL
AVCaptionIsCEA608(NSDictionary *settings)
{
    id mediaType = settings[AVCaptionMediaTypeKey];
    id subtype = settings[AVCaptionMediaSubTypeKey];
    BOOL is608 = [subtype respondsToSelector:@selector(intValue)] && [subtype intValue] == kCMClosedCaptionFormatType_CEA608;
    if ([subtype isKindOfClass:[NSString class]])
        is608 = [subtype isEqualToString:@"c608"] || [subtype isEqualToString:@"CEA608"];
    return [mediaType isEqual:AVMediaTypeClosedCaption] && is608;
}

static int64_t
AVFCeilDivision(int64_t value, int64_t divisor)
{
    int64_t quotient = value / divisor;
    int64_t remainder = value % divisor;
    return quotient + (remainder > 0);
}

@implementation AVCaptionFormatConformer {
    NSDictionary *_finchSettings;
    BOOL _finchConformsTimeRange;
}

+ (instancetype)captionFormatConformerWithConversionSettings:(NSDictionary<AVCaptionSettingsKey,id> *)conversionSettings
{
    return [[self alloc] initWithConversionSettings:conversionSettings];
}

- (instancetype)initWithConversionSettings:(NSDictionary<AVCaptionSettingsKey,id> *)conversionSettings
{
    if (!AVCaptionIsCEA608(conversionSettings))
        [NSException raise:NSInvalidArgumentException format:@"Finch can convert closed captions to CEA-608"];
    if ((self = [super init]))
        _finchSettings = [conversionSettings copy];
    return self;
}

- (BOOL)conformsCaptionsToTimeRange { return _finchConformsTimeRange; }
- (void)setConformsCaptionsToTimeRange:(BOOL)value { _finchConformsTimeRange = value; }

- (AVCaption *)conformedCaptionForCaption:(AVCaption *)caption error:(NSError **)outError
{
    if (outError)
        *outError = nil;
    if (![caption isKindOfClass:[AVCaption class]] || !caption.text.length || !CMTIME_IS_NUMERIC(caption.timeRange.start) || !CMTIME_IS_NUMERIC(caption.timeRange.duration) || CMTimeCompare(caption.timeRange.duration, kCMTimeZero) <= 0) {
        return nil;
    }

    AVMutableCaption *result = [caption mutableCopy];
    if (_finchConformsTimeRange) {
        const CMTime frameDuration = CMTimeMake(1001, 30000);
        CMTime end = CMTimeRangeGetEnd(caption.timeRange);
        CMTime startTicks = CMTimeConvertScale(caption.timeRange.start, frameDuration.timescale, kCMTimeRoundingMethod_RoundTowardPositiveInfinity);
        CMTime endTicks = CMTimeConvertScale(end, frameDuration.timescale, kCMTimeRoundingMethod_RoundTowardPositiveInfinity);
        int64_t startFrame = AVFCeilDivision(startTicks.value, frameDuration.value);
        int64_t endFrame = AVFCeilDivision(endTicks.value, frameDuration.value);
        CMTime start = CMTimeMake(startFrame * frameDuration.value, frameDuration.timescale);
        CMTime finish = CMTimeMake(endFrame * frameDuration.value, frameDuration.timescale);
        result.timeRange = CMTimeRangeFromTimeToTime(start, finish);
    }
    return [result copy];
}

@end

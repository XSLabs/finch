/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Time ranges and layer settings used by AVFoundation's video compositor. */
#import "AVFInternal.h"
#import <AVFoundation/AVVideoComposition.h>
#import <AVFoundation/AVVideoCompositing.h>
#import <AVFoundation/AVError.h>
#import <math.h>

typedef NS_ENUM(NSUInteger, AVFVideoRampKind) {
    AVFVideoRampTransform,
    AVFVideoRampOpacity,
    AVFVideoRampCrop
};

@interface AVFVideoRamp : NSObject <NSCopying, NSSecureCoding>
@property AVFVideoRampKind kind;
@property CMTimeRange timeRange;
@property (copy) NSValue *startValue;
@property (copy) NSValue *endValue;
@end

@implementation AVFVideoRamp
+ (BOOL)supportsSecureCoding { return YES; }
- (id)copyWithZone:(NSZone *)zone
{
    AVFVideoRamp *copy = [[[self class] allocWithZone:zone] init];
    copy.kind = _kind;
    copy.timeRange = _timeRange;
    copy.startValue = _startValue;
    copy.endValue = _endValue;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_kind forKey:@"kind"];
    [coder encodeInt64:_timeRange.start.value forKey:@"startValue"];
    [coder encodeInt32:_timeRange.start.timescale forKey:@"startScale"];
    [coder encodeInt32:_timeRange.start.flags forKey:@"startFlags"];
    [coder encodeInt64:_timeRange.start.epoch forKey:@"startEpoch"];
    [coder encodeInt64:_timeRange.duration.value forKey:@"durationValue"];
    [coder encodeInt32:_timeRange.duration.timescale forKey:@"durationScale"];
    [coder encodeInt32:_timeRange.duration.flags forKey:@"durationFlags"];
    [coder encodeInt64:_timeRange.duration.epoch forKey:@"durationEpoch"];
    [coder encodeObject:_startValue forKey:@"start"];
    [coder encodeObject:_endValue forKey:@"end"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _kind = [coder decodeIntegerForKey:@"kind"];
        CMTime start = CMTimeMakeWithEpoch([coder decodeInt64ForKey:@"startValue"],
            [coder decodeInt32ForKey:@"startScale"], [coder decodeInt64ForKey:@"startEpoch"]);
        start.flags = [coder decodeInt32ForKey:@"startFlags"];
        CMTime duration = CMTimeMakeWithEpoch([coder decodeInt64ForKey:@"durationValue"],
            [coder decodeInt32ForKey:@"durationScale"], [coder decodeInt64ForKey:@"durationEpoch"]);
        duration.flags = [coder decodeInt32ForKey:@"durationFlags"];
        _timeRange = CMTimeRangeMake(start, duration);
        _startValue = [coder decodeObjectOfClass:NSValue.class forKey:@"start"];
        _endValue = [coder decodeObjectOfClass:NSValue.class forKey:@"end"];
    }
    return self;
}
@end

@interface AVVideoCompositionLayerInstruction (FinchVideoComposition)
- (instancetype)initWithFinchTrackID:(CMPersistentTrackID)trackID;
- (void)_finchSetTrackID:(CMPersistentTrackID)trackID;
- (void)_finchSetRamps:(NSArray<AVFVideoRamp *> *)ramps kind:(AVFVideoRampKind)kind;
- (NSArray<AVFVideoRamp *> *)_finchRampsOfKind:(AVFVideoRampKind)kind;
- (BOOL)_finchSetRampOfKind:(AVFVideoRampKind)kind start:(NSValue *)start end:(NSValue *)end range:(CMTimeRange)range;
- (BOOL)_finchContainsTweening;
@end

@interface AVVideoCompositionInstruction (FinchVideoComposition)
- (void)_finchSetTimeRange:(CMTimeRange)timeRange;
- (void)_finchSetBackgroundColor:(CGColorRef)color;
- (void)_finchSetLayerInstructions:(NSArray<AVVideoCompositionLayerInstruction *> *)instructions;
- (void)_finchSetEnablePostProcessing:(BOOL)enabled;
- (void)_finchSetRequiredSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)trackIDs;
@end

@interface AVVideoComposition (FinchVideoComposition)
- (id)_finchImmutableCopy;
- (void)_finchSetFrameDuration:(CMTime)time;
- (void)_finchSetSourceTrackIDForFrameTiming:(CMPersistentTrackID)trackID;
- (void)_finchSetRenderSize:(CGSize)size;
- (void)_finchSetRenderScale:(float)scale;
- (void)_finchSetInstructions:(NSArray<id<AVVideoCompositionInstruction>> *)instructions;
- (void)_finchSetAnimationTool:(AVVideoCompositionCoreAnimationTool *)tool;
- (void)_finchSetCustomVideoCompositorClass:(Class<AVVideoCompositing>)compositorClass;
- (void)_finchSetSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)trackIDs;
- (void)_finchSetColorPrimaries:(NSString *)value;
- (void)_finchSetColorYCbCrMatrix:(NSString *)value;
- (void)_finchSetColorTransferFunction:(NSString *)value;
- (void)_finchSetHDRPolicy:(AVVideoCompositionPerFrameHDRDisplayMetadataPolicy)value;
@end

static BOOL
AVFVideoRangeIsNumeric(CMTimeRange range)
{
    return CMTIMERANGE_IS_VALID(range) && CMTIME_IS_NUMERIC(range.start) && CMTIME_IS_NUMERIC(range.duration);
}

static BOOL
AVFVideoValidationRangeIsValid(CMTimeRange range)
{
    return CMTIMERANGE_IS_VALID(range) && CMTIME_IS_NUMERIC(range.start) &&
           (CMTIME_IS_NUMERIC(range.duration) || CMTIME_IS_POSITIVE_INFINITY(range.duration));
}

static NSValue *
AVFTransformValue(CGAffineTransform value)
{
    return [NSValue valueWithBytes:&value objCType:@encode(CGAffineTransform)];
}

static NSValue *
AVFRectValue(CGRect value)
{
    return [NSValue valueWithBytes:&value objCType:@encode(CGRect)];
}

static BOOL
AVFVideoValuesEqual(AVFVideoRampKind kind, NSValue *a, NSValue *b)
{
    if (kind == AVFVideoRampOpacity)
        return [(NSNumber *)a floatValue] == [(NSNumber *)b floatValue];
    if (kind == AVFVideoRampTransform) {
        CGAffineTransform av, bv;
        [a getValue:&av]; [b getValue:&bv];
        return CGAffineTransformEqualToTransform(av, bv);
    }
    CGRect av, bv;
    [a getValue:&av]; [b getValue:&bv];
    return CGRectEqualToRect(av, bv);
}

static BOOL
AVFVideoRangesOverlap(CMTimeRange a, CMTimeRange b)
{
    if (!AVFVideoRangeIsNumeric(a) || !AVFVideoRangeIsNumeric(b) ||
        CMTimeCompare(a.duration, kCMTimeZero) == 0 || CMTimeCompare(b.duration, kCMTimeZero) == 0)
        return NO;
    return CMTimeCompare(a.start, CMTimeRangeGetEnd(b)) < 0 &&
           CMTimeCompare(b.start, CMTimeRangeGetEnd(a)) < 0;
}

@implementation AVVideoCompositionLayerInstruction {
    CMPersistentTrackID _finchTrackID;
    NSMutableArray<AVFVideoRamp *> *_finchTransformRamps;
    NSMutableArray<AVFVideoRamp *> *_finchOpacityRamps;
    NSMutableArray<AVFVideoRamp *> *_finchCropRamps;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (AVVideoCompositionLayerInstruction *)videoCompositionLayerInstructionWithLayerInstruction:(AVVideoCompositionLayerInstruction *)instruction
{
    return [instruction copy];
}
- (instancetype)init { return [self initWithFinchTrackID:kCMPersistentTrackID_Invalid]; }
- (instancetype)initWithFinchTrackID:(CMPersistentTrackID)trackID
{
    if ((self = [super init])) {
        _finchTrackID = trackID;
        _finchTransformRamps = [NSMutableArray array];
        _finchOpacityRamps = [NSMutableArray array];
        _finchCropRamps = [NSMutableArray array];
    }
    return self;
}
- (CMPersistentTrackID)trackID { return _finchTrackID; }
- (void)_finchSetTrackID:(CMPersistentTrackID)trackID { _finchTrackID = trackID; }
- (NSMutableArray<AVFVideoRamp *> *)_finchMutableRampsOfKind:(AVFVideoRampKind)kind
{
    if (kind == AVFVideoRampTransform) return _finchTransformRamps;
    if (kind == AVFVideoRampOpacity) return _finchOpacityRamps;
    return _finchCropRamps;
}
- (NSArray<AVFVideoRamp *> *)_finchRampsOfKind:(AVFVideoRampKind)kind
{
    return [[self _finchMutableRampsOfKind:kind] copy];
}
- (void)_finchSetRamps:(NSArray<AVFVideoRamp *> *)ramps kind:(AVFVideoRampKind)kind
{
    NSMutableArray *copy = [[NSMutableArray alloc] initWithArray:ramps ?: @[] copyItems:YES];
    if (kind == AVFVideoRampTransform) _finchTransformRamps = copy;
    else if (kind == AVFVideoRampOpacity) _finchOpacityRamps = copy;
    else _finchCropRamps = copy;
}
- (BOOL)_finchContainsTweening
{
    for (AVFVideoRampKind kind = AVFVideoRampTransform; kind <= AVFVideoRampCrop; kind++)
        for (AVFVideoRamp *ramp in [self _finchMutableRampsOfKind:kind])
            if (!AVFVideoValuesEqual(kind, ramp.startValue, ramp.endValue))
                return YES;
    return NO;
}
- (BOOL)_finchGetRampForTime:(CMTime)time kind:(AVFVideoRampKind)kind start:(NSValue **)start end:(NSValue **)end range:(CMTimeRange *)timeRange
{
    if (!CMTIME_IS_NUMERIC(time)) return NO;
    NSArray<AVFVideoRamp *> *ramps = [self _finchMutableRampsOfKind:kind];
    for (NSUInteger index = 0; index < ramps.count; index++) {
        AVFVideoRamp *ramp = ramps[index];
        CMTimeRange range = ramp.timeRange;
        CMTime endTime = CMTimeRangeGetEnd(range);
        if (CMTimeCompare(range.duration, kCMTimeZero) > 0 && CMTimeCompare(time, range.start) >= 0 && CMTimeCompare(time, endTime) < 0) {
            if (start) *start = ramp.startValue;
            if (end) *end = ramp.endValue;
            if (timeRange) *timeRange = range;
            return YES;
        }
        if (CMTimeCompare(time, range.start) < 0) {
            if (index > 0) {
                AVFVideoRamp *previous = ramps[index - 1];
                if (CMTimeCompare(previous.timeRange.duration, kCMTimeZero) == 0) {
                    if (start) *start = previous.endValue;
                    if (end) *end = previous.endValue;
                    if (timeRange) *timeRange = CMTimeRangeFromTimeToTime(previous.timeRange.start, range.start);
                    return YES;
                }
            }
            if (start) *start = ramp.startValue;
            if (end) *end = ramp.endValue;
            if (timeRange) *timeRange = range;
            return YES;
        }
        if (CMTimeCompare(range.duration, kCMTimeZero) == 0 && CMTimeCompare(time, range.start) >= 0) {
            AVFVideoRamp *next = index + 1 < ramps.count ? ramps[index + 1] : nil;
            if (next && CMTimeCompare(time, next.timeRange.start) < 0) {
                if (start) *start = ramp.endValue;
                if (end) *end = ramp.endValue;
                if (timeRange) *timeRange = CMTimeRangeFromTimeToTime(range.start, next.timeRange.start);
                return YES;
            }
            if (CMTimeCompare(time, range.start) == 0) {
                if (start) *start = ramp.startValue;
                if (end) *end = ramp.endValue;
                if (timeRange) *timeRange = range;
                return YES;
            }
        }
    }
    return NO;
}
- (BOOL)getTransformRampForTime:(CMTime)time startTransform:(CGAffineTransform *)startTransform endTransform:(CGAffineTransform *)endTransform timeRange:(CMTimeRange *)timeRange
{
    NSValue *start = nil, *end = nil;
    if (![self _finchGetRampForTime:time kind:AVFVideoRampTransform start:&start end:&end range:timeRange]) return NO;
    if (startTransform) [start getValue:startTransform];
    if (endTransform) [end getValue:endTransform];
    return YES;
}
- (BOOL)getOpacityRampForTime:(CMTime)time startOpacity:(float *)startOpacity endOpacity:(float *)endOpacity timeRange:(CMTimeRange *)timeRange
{
    NSValue *start = nil, *end = nil;
    if (![self _finchGetRampForTime:time kind:AVFVideoRampOpacity start:&start end:&end range:timeRange]) return NO;
    if (startOpacity) *startOpacity = [(NSNumber *)start floatValue];
    if (endOpacity) *endOpacity = [(NSNumber *)end floatValue];
    return YES;
}
- (BOOL)getCropRectangleRampForTime:(CMTime)time startCropRectangle:(CGRect *)startCropRectangle endCropRectangle:(CGRect *)endCropRectangle timeRange:(CMTimeRange *)timeRange
{
    NSValue *start = nil, *end = nil;
    if (![self _finchGetRampForTime:time kind:AVFVideoRampCrop start:&start end:&end range:timeRange]) return NO;
    if (startCropRectangle) [start getValue:startCropRectangle];
    if (endCropRectangle) [end getValue:endCropRectangle];
    return YES;
}
- (BOOL)_finchSetRampOfKind:(AVFVideoRampKind)kind start:(NSValue *)start end:(NSValue *)end range:(CMTimeRange)range
{
    if (!AVFVideoRangeIsNumeric(range))
        [NSException raise:NSInvalidArgumentException format:@"The ramp time range must contain numeric times"];
    NSMutableArray<AVFVideoRamp *> *ramps = [self _finchMutableRampsOfKind:kind];
    for (AVFVideoRamp *ramp in ramps)
        if (AVFVideoRangesOverlap(ramp.timeRange, range))
            [NSException raise:NSInvalidArgumentException format:@"The ramp time range overlaps an existing ramp"];
    AVFVideoRamp *ramp = [AVFVideoRamp new];
    ramp.kind = kind;
    ramp.timeRange = range;
    ramp.startValue = start;
    ramp.endValue = end;
    [ramps addObject:ramp];
    [ramps sortUsingComparator:^NSComparisonResult(AVFVideoRamp *a, AVFVideoRamp *b) {
        int comparison = CMTimeCompare(a.timeRange.start, b.timeRange.start);
        return comparison < 0 ? NSOrderedAscending : comparison > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    return YES;
}
- (id)copyWithZone:(NSZone *)zone
{
    AVVideoCompositionLayerInstruction *copy = [[AVVideoCompositionLayerInstruction allocWithZone:zone] initWithFinchTrackID:_finchTrackID];
    [copy _finchSetRamps:_finchTransformRamps kind:AVFVideoRampTransform];
    [copy _finchSetRamps:_finchOpacityRamps kind:AVFVideoRampOpacity];
    [copy _finchSetRamps:_finchCropRamps kind:AVFVideoRampCrop];
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableVideoCompositionLayerInstruction *copy = [[AVMutableVideoCompositionLayerInstruction allocWithZone:zone] initWithFinchTrackID:_finchTrackID];
    [copy _finchSetRamps:_finchTransformRamps kind:AVFVideoRampTransform];
    [copy _finchSetRamps:_finchOpacityRamps kind:AVFVideoRampOpacity];
    [copy _finchSetRamps:_finchCropRamps kind:AVFVideoRampCrop];
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt32:_finchTrackID forKey:@"trackID"];
    [coder encodeObject:_finchTransformRamps forKey:@"transformRamps"];
    [coder encodeObject:_finchOpacityRamps forKey:@"opacityRamps"];
    [coder encodeObject:_finchCropRamps forKey:@"cropRamps"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self initWithFinchTrackID:[coder decodeInt32ForKey:@"trackID"]])) {
        NSSet *classes = [NSSet setWithObjects:NSArray.class, AVFVideoRamp.class, NSValue.class, NSNumber.class, nil];
        [self _finchSetRamps:[coder decodeObjectOfClasses:classes forKey:@"transformRamps"] kind:AVFVideoRampTransform];
        [self _finchSetRamps:[coder decodeObjectOfClasses:classes forKey:@"opacityRamps"] kind:AVFVideoRampOpacity];
        [self _finchSetRamps:[coder decodeObjectOfClasses:classes forKey:@"cropRamps"] kind:AVFVideoRampCrop];
    }
    return self;
}
@end

@implementation AVMutableVideoCompositionLayerInstruction
@dynamic trackID;
+ (instancetype)videoCompositionLayerInstructionWithAssetTrack:(AVAssetTrack *)track
{
    return [[self alloc] initWithFinchTrackID:track ? track.trackID : kCMPersistentTrackID_Invalid];
}
+ (instancetype)videoCompositionLayerInstruction { return [[self alloc] initWithFinchTrackID:kCMPersistentTrackID_Invalid]; }
- (void)setTrackID:(CMPersistentTrackID)value { [self _finchSetTrackID:value]; }
- (void)setTransformRampFromStartTransform:(CGAffineTransform)startTransform toEndTransform:(CGAffineTransform)endTransform timeRange:(CMTimeRange)timeRange
{
    [self _finchSetRampOfKind:AVFVideoRampTransform start:AVFTransformValue(startTransform) end:AVFTransformValue(endTransform) range:timeRange];
}
- (void)setTransform:(CGAffineTransform)transform atTime:(CMTime)time
{
    if (!CMTIME_IS_NUMERIC(time)) [NSException raise:NSInvalidArgumentException format:@"The transform time must be numeric"];
    [self setTransformRampFromStartTransform:transform toEndTransform:transform timeRange:CMTimeRangeMake(time, kCMTimeZero)];
}
- (void)setOpacityRampFromStartOpacity:(float)startOpacity toEndOpacity:(float)endOpacity timeRange:(CMTimeRange)timeRange
{
    if (startOpacity < 0 || startOpacity > 1 || endOpacity < 0 || endOpacity > 1 || !isfinite(startOpacity) || !isfinite(endOpacity))
        [NSException raise:NSInvalidArgumentException format:@"Opacity values must be between zero and one"];
    [self _finchSetRampOfKind:AVFVideoRampOpacity start:@(startOpacity) end:@(endOpacity) range:timeRange];
}
- (void)setOpacity:(float)opacity atTime:(CMTime)time
{
    if (!CMTIME_IS_NUMERIC(time)) [NSException raise:NSInvalidArgumentException format:@"The opacity time must be numeric"];
    [self setOpacityRampFromStartOpacity:opacity toEndOpacity:opacity timeRange:CMTimeRangeMake(time, kCMTimeZero)];
}
- (void)setCropRectangleRampFromStartCropRectangle:(CGRect)startCropRectangle toEndCropRectangle:(CGRect)endCropRectangle timeRange:(CMTimeRange)timeRange
{
    [self _finchSetRampOfKind:AVFVideoRampCrop start:AVFRectValue(startCropRectangle) end:AVFRectValue(endCropRectangle) range:timeRange];
}
- (void)setCropRectangle:(CGRect)cropRectangle atTime:(CMTime)time
{
    if (!CMTIME_IS_NUMERIC(time)) [NSException raise:NSInvalidArgumentException format:@"The crop time must be numeric"];
    [self setCropRectangleRampFromStartCropRectangle:cropRectangle toEndCropRectangle:cropRectangle timeRange:CMTimeRangeMake(time, kCMTimeZero)];
}
@end

@implementation AVVideoCompositionInstruction {
    CMTimeRange _finchTimeRange;
    CGColorRef _finchBackgroundColor;
    NSArray<AVVideoCompositionLayerInstruction *> *_finchLayerInstructions;
    NSArray<NSNumber *> *_finchRequiredSourceSampleDataTrackIDs;
    BOOL _finchEnablePostProcessing;
}
+ (BOOL)supportsSecureCoding { return YES; }
+ (AVVideoCompositionInstruction *)videoCompositionInstructionWithInstruction:(AVVideoCompositionInstruction *)instruction
{
    return [instruction copy];
}
- (instancetype)init
{
    if ((self = [super init])) {
        _finchTimeRange = CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid);
        _finchEnablePostProcessing = YES;
    }
    return self;
}
- (void)dealloc { if (_finchBackgroundColor) CGColorRelease(_finchBackgroundColor); }
- (CMTimeRange)timeRange { return _finchTimeRange; }
- (CGColorRef)backgroundColor { return _finchBackgroundColor; }
- (NSArray *)layerInstructions { return _finchLayerInstructions; }
- (BOOL)enablePostProcessing { return _finchEnablePostProcessing; }
- (NSArray<NSNumber *> *)requiredSourceSampleDataTrackIDs { return _finchRequiredSourceSampleDataTrackIDs ?: @[]; }
- (void)_finchSetTimeRange:(CMTimeRange)timeRange { _finchTimeRange = timeRange; }
- (void)_finchSetBackgroundColor:(CGColorRef)color
{
    if (color == _finchBackgroundColor) return;
    if (color) CGColorRetain(color);
    if (_finchBackgroundColor) CGColorRelease(_finchBackgroundColor);
    _finchBackgroundColor = color;
}
- (void)_finchSetLayerInstructions:(NSArray<AVVideoCompositionLayerInstruction *> *)instructions
{
    _finchLayerInstructions = [instructions copy];
}
- (void)_finchSetEnablePostProcessing:(BOOL)enabled { _finchEnablePostProcessing = enabled; }
- (void)_finchSetRequiredSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)trackIDs { _finchRequiredSourceSampleDataTrackIDs = [trackIDs copy]; }
- (BOOL)containsTweening
{
    for (AVVideoCompositionLayerInstruction *instruction in _finchLayerInstructions)
        if ([instruction _finchContainsTweening]) return YES;
    return NO;
}
- (NSArray<NSValue *> *)requiredSourceTrackIDs
{
    if (!_finchLayerInstructions) return nil;
    NSMutableArray *ids = [NSMutableArray array];
    for (AVVideoCompositionLayerInstruction *instruction in _finchLayerInstructions) {
        CMPersistentTrackID trackID = instruction.trackID;
        BOOL found = NO;
        for (NSValue *value in ids) {
            CMPersistentTrackID existing;
            [value getValue:&existing];
            if (existing == trackID) { found = YES; break; }
        }
        if (!found) [ids addObject:[NSValue valueWithBytes:&trackID objCType:@encode(CMPersistentTrackID)]];
    }
    return ids;
}
- (CMPersistentTrackID)passthroughTrackID
{
    if (_finchLayerInstructions.count != 1) return kCMPersistentTrackID_Invalid;
    AVVideoCompositionLayerInstruction *instruction = _finchLayerInstructions.firstObject;
    if ([[instruction _finchRampsOfKind:AVFVideoRampTransform] count] ||
        [[instruction _finchRampsOfKind:AVFVideoRampOpacity] count] ||
        [[instruction _finchRampsOfKind:AVFVideoRampCrop] count])
        return kCMPersistentTrackID_Invalid;
    return instruction.trackID;
}
- (id)copyWithZone:(NSZone *)zone
{
    AVVideoCompositionInstruction *copy = [[AVVideoCompositionInstruction allocWithZone:zone] init];
    [copy _finchSetTimeRange:_finchTimeRange];
    [copy _finchSetBackgroundColor:_finchBackgroundColor];
    [copy _finchSetLayerInstructions:_finchLayerInstructions];
    [copy _finchSetEnablePostProcessing:_finchEnablePostProcessing];
    [copy _finchSetRequiredSourceSampleDataTrackIDs:_finchRequiredSourceSampleDataTrackIDs];
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableVideoCompositionInstruction *copy = [[AVMutableVideoCompositionInstruction allocWithZone:zone] init];
    [copy _finchSetTimeRange:_finchTimeRange];
    [copy _finchSetBackgroundColor:_finchBackgroundColor];
    [copy _finchSetLayerInstructions:_finchLayerInstructions];
    [copy _finchSetEnablePostProcessing:_finchEnablePostProcessing];
    [copy _finchSetRequiredSourceSampleDataTrackIDs:_finchRequiredSourceSampleDataTrackIDs];
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt64:_finchTimeRange.start.value forKey:@"startValue"];
    [coder encodeInt32:_finchTimeRange.start.timescale forKey:@"startScale"];
    [coder encodeInt32:_finchTimeRange.start.flags forKey:@"startFlags"];
    [coder encodeInt64:_finchTimeRange.start.epoch forKey:@"startEpoch"];
    [coder encodeInt64:_finchTimeRange.duration.value forKey:@"durationValue"];
    [coder encodeInt32:_finchTimeRange.duration.timescale forKey:@"durationScale"];
    [coder encodeInt32:_finchTimeRange.duration.flags forKey:@"durationFlags"];
    [coder encodeInt64:_finchTimeRange.duration.epoch forKey:@"durationEpoch"];
    [coder encodeObject:_finchLayerInstructions forKey:@"layers"];
    [coder encodeObject:_finchRequiredSourceSampleDataTrackIDs forKey:@"sampleTrackIDs"];
    [coder encodeBool:_finchEnablePostProcessing forKey:@"postProcessing"];
    if (_finchBackgroundColor) {
        CGColorSpaceRef space = CGColorGetColorSpace(_finchBackgroundColor);
        CFStringRef name = space ? CGColorSpaceCopyName(space) : NULL;
        const CGFloat *components = CGColorGetComponents(_finchBackgroundColor);
        size_t count = CGColorGetNumberOfComponents(_finchBackgroundColor);
        if (name && components && count <= 16) {
            NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
            for (size_t index = 0; index < count; index++) [values addObject:@(components[index])];
            [coder encodeObject:(__bridge NSString *)name forKey:@"colorSpace"];
            [coder encodeObject:values forKey:@"colorComponents"];
        }
        if (name) CFRelease(name);
    }
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        CMTime start = CMTimeMakeWithEpoch([coder decodeInt64ForKey:@"startValue"], [coder decodeInt32ForKey:@"startScale"], [coder decodeInt64ForKey:@"startEpoch"]);
        start.flags = [coder decodeInt32ForKey:@"startFlags"];
        CMTime duration = CMTimeMakeWithEpoch([coder decodeInt64ForKey:@"durationValue"], [coder decodeInt32ForKey:@"durationScale"], [coder decodeInt64ForKey:@"durationEpoch"]);
        duration.flags = [coder decodeInt32ForKey:@"durationFlags"];
        _finchTimeRange = CMTimeRangeMake(start, duration);
        NSSet *classes = [NSSet setWithObjects:NSArray.class, AVVideoCompositionLayerInstruction.class, AVMutableVideoCompositionLayerInstruction.class, NSNumber.class, nil];
        _finchLayerInstructions = [coder decodeObjectOfClasses:classes forKey:@"layers"];
        _finchRequiredSourceSampleDataTrackIDs = [coder decodeObjectOfClasses:classes forKey:@"sampleTrackIDs"];
        _finchEnablePostProcessing = [coder decodeBoolForKey:@"postProcessing"];
        NSString *spaceName = [coder decodeObjectOfClass:NSString.class forKey:@"colorSpace"];
        NSArray<NSNumber *> *components = [coder decodeObjectOfClasses:[NSSet setWithObjects:NSArray.class, NSNumber.class, nil] forKey:@"colorComponents"];
        if (spaceName && components.count) {
            CGColorSpaceRef space = CGColorSpaceCreateWithName((__bridge CFStringRef)spaceName);
            CGFloat values[16];
            for (NSUInteger index = 0; index < components.count && index < 16; index++) values[index] = components[index].doubleValue;
            if (space && components.count == CGColorSpaceGetNumberOfComponents(space) + 1)
                _finchBackgroundColor = CGColorCreate(space, values);
            if (space) CGColorSpaceRelease(space);
        }
    }
    return self;
}
@end

@implementation AVMutableVideoCompositionInstruction
@dynamic timeRange, backgroundColor, layerInstructions, enablePostProcessing, requiredSourceSampleDataTrackIDs;
+ (instancetype)videoCompositionInstruction { return [[self alloc] init]; }
- (void)setTimeRange:(CMTimeRange)value { [self _finchSetTimeRange:value]; }
- (void)setBackgroundColor:(CGColorRef)value { [self _finchSetBackgroundColor:value]; }
- (void)setLayerInstructions:(NSArray<AVVideoCompositionLayerInstruction *> *)value { [self _finchSetLayerInstructions:value]; }
- (void)setEnablePostProcessing:(BOOL)value { [self _finchSetEnablePostProcessing:value]; }
- (void)setRequiredSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)value { [self _finchSetRequiredSourceSampleDataTrackIDs:value]; }
@end

@implementation AVVideoComposition {
    CMTime _finchFrameDuration;
    CMPersistentTrackID _finchSourceTrackIDForFrameTiming;
    CGSize _finchRenderSize;
    float _finchRenderScale;
    NSArray<id<AVVideoCompositionInstruction>> *_finchInstructions;
    AVVideoCompositionCoreAnimationTool *_finchAnimationTool;
    Class<AVVideoCompositing> _finchCustomCompositorClass;
    NSArray<NSNumber *> *_finchSourceSampleDataTrackIDs;
    NSString *_finchColorPrimaries, *_finchColorYCbCrMatrix, *_finchColorTransferFunction;
    AVVideoCompositionPerFrameHDRDisplayMetadataPolicy _finchHDRPolicy;
}
+ (AVVideoComposition *)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset
{
    return [[AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset] _finchImmutableCopy];
}
+ (void)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset completionHandler:(void (^)(AVVideoComposition *, NSError *))completionHandler
{
    if (completionHandler) completionHandler([self videoCompositionWithPropertiesOfAsset:asset], nil);
}
- (instancetype)init
{
    if ((self = [super init])) {
        _finchFrameDuration = kCMTimeInvalid;
        _finchSourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid;
        _finchRenderScale = 1.0f;
        _finchHDRPolicy = AVVideoCompositionPerFrameHDRDisplayMetadataPolicyPropagate;
    }
    return self;
}
- (CMTime)frameDuration { return _finchFrameDuration; }
- (CMPersistentTrackID)sourceTrackIDForFrameTiming { return _finchSourceTrackIDForFrameTiming; }
- (CGSize)renderSize { return _finchRenderSize; }
- (float)renderScale { return _finchRenderScale; }
- (NSArray *)instructions { return _finchInstructions; }
- (AVVideoCompositionCoreAnimationTool *)animationTool { return _finchAnimationTool; }
- (Class<AVVideoCompositing>)customVideoCompositorClass { return _finchCustomCompositorClass; }
- (NSArray<NSNumber *> *)sourceSampleDataTrackIDs
{
    return _finchSourceSampleDataTrackIDs ?: @[];
}
- (NSArray *)outputBufferDescription { return nil; }
- (NSArray *)spatialVideoConfigurations { return @[]; }
- (NSString *)colorPrimaries { return _finchColorPrimaries; }
- (NSString *)colorYCbCrMatrix { return _finchColorYCbCrMatrix; }
- (NSString *)colorTransferFunction { return _finchColorTransferFunction; }
- (AVVideoCompositionPerFrameHDRDisplayMetadataPolicy)perFrameHDRDisplayMetadataPolicy { return _finchHDRPolicy; }
- (void)_finchSetFrameDuration:(CMTime)time { _finchFrameDuration = time; }
- (void)_finchSetSourceTrackIDForFrameTiming:(CMPersistentTrackID)trackID { _finchSourceTrackIDForFrameTiming = trackID; }
- (void)_finchSetRenderSize:(CGSize)size { _finchRenderSize = size; }
- (void)_finchSetRenderScale:(float)scale { _finchRenderScale = scale; }
- (void)_finchSetInstructions:(NSArray<id<AVVideoCompositionInstruction>> *)instructions { _finchInstructions = [instructions copy]; }
- (void)_finchSetAnimationTool:(AVVideoCompositionCoreAnimationTool *)tool { _finchAnimationTool = tool; }
- (void)_finchSetCustomVideoCompositorClass:(Class<AVVideoCompositing>)compositorClass { _finchCustomCompositorClass = compositorClass; }
- (void)_finchSetSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)trackIDs { _finchSourceSampleDataTrackIDs = [trackIDs copy]; }
- (void)_finchSetColorPrimaries:(NSString *)value { _finchColorPrimaries = [value copy]; }
- (void)_finchSetColorYCbCrMatrix:(NSString *)value { _finchColorYCbCrMatrix = [value copy]; }
- (void)_finchSetColorTransferFunction:(NSString *)value { _finchColorTransferFunction = [value copy]; }
- (void)_finchSetHDRPolicy:(AVVideoCompositionPerFrameHDRDisplayMetadataPolicy)value { _finchHDRPolicy = [value copy]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableVideoComposition *copy = [[AVMutableVideoComposition allocWithZone:zone] init];
    [copy _finchSetFrameDuration:_finchFrameDuration];
    [copy _finchSetSourceTrackIDForFrameTiming:_finchSourceTrackIDForFrameTiming];
    [copy _finchSetRenderSize:_finchRenderSize];
    [copy _finchSetRenderScale:_finchRenderScale];
    [copy _finchSetInstructions:_finchInstructions];
    [copy _finchSetAnimationTool:_finchAnimationTool];
    [copy _finchSetCustomVideoCompositorClass:_finchCustomCompositorClass];
    [copy _finchSetSourceSampleDataTrackIDs:_finchSourceSampleDataTrackIDs];
    [copy _finchSetColorPrimaries:_finchColorPrimaries];
    [copy _finchSetColorYCbCrMatrix:_finchColorYCbCrMatrix];
    [copy _finchSetColorTransferFunction:_finchColorTransferFunction];
    [copy _finchSetHDRPolicy:_finchHDRPolicy];
    return copy;
}
- (id)_finchImmutableCopy
{
    AVVideoComposition *copy = [[AVVideoComposition alloc] init];
    [copy _finchSetFrameDuration:_finchFrameDuration];
    [copy _finchSetSourceTrackIDForFrameTiming:_finchSourceTrackIDForFrameTiming];
    [copy _finchSetRenderSize:_finchRenderSize];
    [copy _finchSetRenderScale:_finchRenderScale];
    [copy _finchSetInstructions:_finchInstructions];
    [copy _finchSetAnimationTool:_finchAnimationTool];
    [copy _finchSetCustomVideoCompositorClass:_finchCustomCompositorClass];
    [copy _finchSetSourceSampleDataTrackIDs:_finchSourceSampleDataTrackIDs];
    [copy _finchSetColorPrimaries:_finchColorPrimaries];
    [copy _finchSetColorYCbCrMatrix:_finchColorYCbCrMatrix];
    [copy _finchSetColorTransferFunction:_finchColorTransferFunction];
    [copy _finchSetHDRPolicy:_finchHDRPolicy];
    return copy;
}
- (BOOL)isValidForAsset:(AVAsset *)asset timeRange:(CMTimeRange)timeRange validationDelegate:(id<AVVideoCompositionValidationHandling>)delegate
{
    return [self isValidForTracks:asset.tracks assetDuration:asset ? asset.duration : kCMTimeInvalid timeRange:timeRange validationDelegate:delegate];
}
- (void)determineValidityForAsset:(AVAsset *)asset timeRange:(CMTimeRange)timeRange validationDelegate:(id<AVVideoCompositionValidationHandling>)delegate completionHandler:(void (^)(BOOL, NSError *))handler
{
    if (handler) handler([self isValidForAsset:asset timeRange:timeRange validationDelegate:delegate], nil);
}
- (BOOL)isValidForTracks:(NSArray<AVAssetTrack *> *)tracks assetDuration:(CMTime)duration timeRange:(CMTimeRange)timeRange validationDelegate:(id<AVVideoCompositionValidationHandling>)delegate
{
    if (!AVFVideoValidationRangeIsValid(timeRange)) return NO;
    NSArray *instructions = _finchInstructions ?: @[];
    CMTime cursor = timeRange.start;
    CMTime requestedEnd = CMTimeRangeGetEnd(timeRange);
    NSSet *trackIDs = [NSSet setWithArray:[(tracks ?: @[]) valueForKey:@"trackID"]];
    for (id<AVVideoCompositionInstruction> instruction in instructions) {
        CMTimeRange range = instruction.timeRange;
        if (!AVFVideoValidationRangeIsValid(range)) {
            if ([delegate respondsToSelector:@selector(videoComposition:shouldContinueValidatingAfterFindingInvalidTimeRangeInInstruction:)])
                [delegate videoComposition:self shouldContinueValidatingAfterFindingInvalidTimeRangeInInstruction:instruction];
            return NO;
        }
        if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(CMTimeRangeGetEnd(range), duration) > 0) return NO;
        if (CMTimeCompare(CMTimeRangeGetEnd(range), cursor) <= 0 || CMTimeCompare(range.start, requestedEnd) >= 0) continue;
        CMTime effectiveStart = CMTimeCompare(range.start, cursor) > 0 ? range.start : cursor;
        if (CMTimeCompare(effectiveStart, cursor) > 0) {
            CMTimeRange gap = CMTimeRangeFromTimeToTime(cursor, effectiveStart);
            if ([delegate respondsToSelector:@selector(videoComposition:shouldContinueValidatingAfterFindingEmptyTimeRange:)])
                [delegate videoComposition:self shouldContinueValidatingAfterFindingEmptyTimeRange:gap];
            return NO;
        }
        if (CMTimeCompare(range.start, cursor) < 0) {
            if ([delegate respondsToSelector:@selector(videoComposition:shouldContinueValidatingAfterFindingInvalidTimeRangeInInstruction:)])
                [delegate videoComposition:self shouldContinueValidatingAfterFindingInvalidTimeRangeInInstruction:instruction];
            return NO;
        }
        AVVideoCompositionInstruction *concreteInstruction = (AVVideoCompositionInstruction *)instruction;
        for (AVVideoCompositionLayerInstruction *layer in concreteInstruction.layerInstructions) {
            NSNumber *trackID = @((int32_t)layer.trackID);
            if (tracks && ![trackIDs containsObject:trackID]) {
                if ([delegate respondsToSelector:@selector(videoComposition:shouldContinueValidatingAfterFindingInvalidTrackIDInInstruction:layerInstruction:asset:)])
                    [delegate videoComposition:self shouldContinueValidatingAfterFindingInvalidTrackIDInInstruction:instruction layerInstruction:layer asset:tracks.firstObject.asset];
                return NO;
            }
        }
        cursor = CMTimeCompare(CMTimeRangeGetEnd(range), requestedEnd) < 0 ? CMTimeRangeGetEnd(range) : requestedEnd;
        if (CMTimeCompare(cursor, requestedEnd) >= 0) return YES;
    }
    if (CMTimeCompare(cursor, requestedEnd) < 0) {
        CMTimeRange gap = CMTimeRangeFromTimeToTime(cursor, requestedEnd);
        if ([delegate respondsToSelector:@selector(videoComposition:shouldContinueValidatingAfterFindingEmptyTimeRange:)])
            [delegate videoComposition:self shouldContinueValidatingAfterFindingEmptyTimeRange:gap];
        return NO;
    }
    return YES;
}
@end

@implementation AVMutableVideoComposition
@dynamic customVideoCompositorClass, frameDuration, sourceTrackIDForFrameTiming, renderSize, renderScale, instructions, animationTool;
+ (AVMutableVideoComposition *)videoComposition { return [[self alloc] init]; }
+ (AVMutableVideoComposition *)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset
{
    AVMutableVideoComposition *composition = [self videoComposition];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    CMTime duration = asset.duration;
    if (!tracks.count) {
        composition.instructions = @[];
        return composition;
    }
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0)
        return composition;

    CGFloat minX = 0, minY = 0, maxX = 0, maxY = 0;
    BOOL hasBounds = NO;
    NSMutableArray *boundaries = [NSMutableArray arrayWithObjects:[NSValue valueWithBytes:&(CMTime){0, 1, kCMTimeFlags_Valid, 0} objCType:@encode(CMTime)], [NSValue valueWithBytes:&duration objCType:@encode(CMTime)], nil];
    CMTime frameDuration = kCMTimeInvalid;
    for (AVAssetTrack *track in tracks) {
        CGSize size = track.naturalSize;
        CGAffineTransform transform = track.preferredTransform;
        CGRect bounds = CGRectStandardize(CGRectApplyAffineTransform(CGRectMake(0, 0, size.width, size.height), transform));
        if (isfinite(bounds.origin.x) && isfinite(bounds.origin.y) && isfinite(bounds.size.width) && isfinite(bounds.size.height) && bounds.size.width > 0 && bounds.size.height > 0) {
            if (!hasBounds) { minX = CGRectGetMinX(bounds); minY = CGRectGetMinY(bounds); maxX = CGRectGetMaxX(bounds); maxY = CGRectGetMaxY(bounds); hasBounds = YES; }
            else { minX = MIN(minX, CGRectGetMinX(bounds)); minY = MIN(minY, CGRectGetMinY(bounds)); maxX = MAX(maxX, CGRectGetMaxX(bounds)); maxY = MAX(maxY, CGRectGetMaxY(bounds)); }
        }
        CMTime minFrame = track.minFrameDuration;
        if (CMTIME_IS_NUMERIC(minFrame) && CMTimeCompare(minFrame, kCMTimeZero) > 0 &&
            (!CMTIME_IS_NUMERIC(frameDuration) || CMTimeCompare(minFrame, frameDuration) < 0))
            frameDuration = minFrame;
        CMTimeRange range = track.timeRange;
        if (AVFVideoRangeIsNumeric(range)) {
            CMTime start = range.start;
            CMTime end = CMTimeRangeGetEnd(range);
            if (CMTimeCompare(start, kCMTimeZero) > 0 && CMTimeCompare(start, duration) < 0)
                [boundaries addObject:[NSValue valueWithBytes:&start objCType:@encode(CMTime)]];
            if (CMTimeCompare(end, kCMTimeZero) > 0 && CMTimeCompare(end, duration) < 0)
                [boundaries addObject:[NSValue valueWithBytes:&end objCType:@encode(CMTime)]];
        }
    }
    [boundaries sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CMTime av, bv; [a getValue:&av]; [b getValue:&bv];
        int comparison = CMTimeCompare(av, bv);
        return comparison < 0 ? NSOrderedAscending : comparison > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *unique = [NSMutableArray array];
    for (NSValue *value in boundaries) {
        CMTime current; [value getValue:&current];
        if (!unique.count) [unique addObject:value];
        else { CMTime previous; [unique.lastObject getValue:&previous]; if (CMTimeCompare(previous, current) != 0) [unique addObject:value]; }
    }
    NSMutableArray<AVMutableVideoCompositionInstruction *> *instructions = [NSMutableArray array];
    for (NSUInteger index = 0; index + 1 < unique.count; index++) {
        CMTime start, end; [unique[index] getValue:&start]; [unique[index + 1] getValue:&end];
        if (CMTimeCompare(end, start) <= 0) continue;
        CMTime midpoint = CMTimeAdd(start, CMTimeMultiplyByFloat64(CMTimeSubtract(end, start), 0.5));
        NSMutableArray *layers = [NSMutableArray array];
        for (AVAssetTrack *track in tracks) {
            CMTimeRange trackRange = track.timeRange;
            if (!AVFVideoRangeIsNumeric(trackRange) || CMTimeCompare(midpoint, trackRange.start) < 0 || CMTimeCompare(midpoint, CMTimeRangeGetEnd(trackRange)) >= 0)
                continue;
            AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
            CGAffineTransform transform = track.preferredTransform;
            transform.tx -= minX;
            transform.ty -= minY;
            [layer setTransform:transform atTime:start];
            [layers addObject:layer];
        }
        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeFromTimeToTime(start, end);
        instruction.layerInstructions = layers;
        [instructions addObject:instruction];
    }
    composition.instructions = instructions;
    composition.renderSize = hasBounds ? CGSizeMake(ceil(maxX - minX), ceil(maxY - minY)) : CGSizeZero;
    composition.frameDuration = CMTIME_IS_NUMERIC(frameDuration) ? frameDuration : CMTimeMake(1, 30);
    return composition;
}
+ (AVMutableVideoComposition *)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset prototypeInstruction:(AVVideoCompositionInstruction *)prototypeInstruction
{
    AVMutableVideoComposition *composition = [self videoCompositionWithPropertiesOfAsset:asset];
    if (!prototypeInstruction) return composition;
    NSMutableArray *instructions = [NSMutableArray arrayWithCapacity:composition.instructions.count];
    for (AVMutableVideoCompositionInstruction *instruction in composition.instructions) {
        AVMutableVideoCompositionInstruction *copy = [instruction mutableCopy];
        if (prototypeInstruction.backgroundColor) copy.backgroundColor = prototypeInstruction.backgroundColor;
        copy.enablePostProcessing = prototypeInstruction.enablePostProcessing;
        [instructions addObject:copy];
    }
    composition.instructions = instructions;
    return composition;
}
+ (void)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset completionHandler:(void (^)(AVMutableVideoComposition *, NSError *))completionHandler
{
    if (completionHandler) completionHandler([self videoCompositionWithPropertiesOfAsset:asset], nil);
}
+ (void)videoCompositionWithPropertiesOfAsset:(AVAsset *)asset prototypeInstruction:(AVVideoCompositionInstruction *)prototypeInstruction completionHandler:(void (^)(AVMutableVideoComposition *, NSError *))completionHandler
{
    if (completionHandler) completionHandler([self videoCompositionWithPropertiesOfAsset:asset prototypeInstruction:prototypeInstruction], nil);
}
- (void)setCustomVideoCompositorClass:(Class<AVVideoCompositing>)value { [self _finchSetCustomVideoCompositorClass:value]; }
- (void)setFrameDuration:(CMTime)value { [self _finchSetFrameDuration:value]; }
- (void)setSourceTrackIDForFrameTiming:(CMPersistentTrackID)value { [self _finchSetSourceTrackIDForFrameTiming:value]; }
- (void)setRenderSize:(CGSize)value { [self _finchSetRenderSize:value]; }
- (void)setRenderScale:(float)value { [self _finchSetRenderScale:value]; }
- (void)setInstructions:(NSArray<id<AVVideoCompositionInstruction>> *)value { [self _finchSetInstructions:value]; }
- (void)setAnimationTool:(AVVideoCompositionCoreAnimationTool *)value { [self _finchSetAnimationTool:value]; }
- (void)setSourceSampleDataTrackIDs:(NSArray<NSNumber *> *)value { [self _finchSetSourceSampleDataTrackIDs:value]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation AVMutableVideoComposition (AVMutableVideoCompositionColorimetery)
- (void)setColorPrimaries:(NSString *)value { [self _finchSetColorPrimaries:value]; }
- (void)setColorYCbCrMatrix:(NSString *)value { [self _finchSetColorYCbCrMatrix:value]; }
- (void)setColorTransferFunction:(NSString *)value { [self _finchSetColorTransferFunction:value]; }
- (void)setPerFrameHDRDisplayMetadataPolicy:(AVVideoCompositionPerFrameHDRDisplayMetadataPolicy)value { [self _finchSetHDRPolicy:value]; }
@end

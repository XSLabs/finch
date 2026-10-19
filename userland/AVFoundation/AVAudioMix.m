/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Time-based audio mix settings. The volume ramps are kept as media-time ranges. */
#import "AVFInternal.h"
#import <AVFoundation/AVAudioMix.h>

@class AVFAudioVolumeRamp;

@interface AVAudioMixInputParameters (FinchAudioMix)
- (instancetype)initWithFinchTrackID:(CMPersistentTrackID)trackID;
- (void)_finchSetTrackID:(CMPersistentTrackID)trackID;
- (void)_finchSetAudioTimePitchAlgorithm:(nullable AVAudioTimePitchAlgorithm)algorithm;
- (void)_finchSetAudioTapProcessor:(nullable MTAudioProcessingTapRef)tap;
- (void)_finchSetRamps:(NSArray<AVFAudioVolumeRamp *> *)ramps;
- (float)_finchVolumeAtTime:(CMTime)time;
- (void)_finchSetVolume:(float)volume atTime:(CMTime)time;
- (void)_finchSetVolumeRampFrom:(float)startVolume to:(float)endVolume timeRange:(CMTimeRange)timeRange;
@end

@interface AVAudioMix (FinchAudioMix)
- (instancetype)initWithFinchInputParameters:(NSArray<AVAudioMixInputParameters *> *)inputParameters;
- (void)_finchSetInputParameters:(NSArray<AVAudioMixInputParameters *> *)inputParameters;
@end

@interface AVMutableAudioMixInputParameters (FinchAudioMix)
- (void)setTrackID:(CMPersistentTrackID)trackID;
- (void)setAudioTimePitchAlgorithm:(nullable AVAudioTimePitchAlgorithm)algorithm;
- (void)setAudioTapProcessor:(nullable MTAudioProcessingTapRef)tap;
@end

@interface AVFAudioVolumeRamp : NSObject <NSCopying>
@property CMTimeRange timeRange;
@property float startVolume;
@property float endVolume;
@end

@implementation AVFAudioVolumeRamp
- (id)copyWithZone:(NSZone *)zone
{
    AVFAudioVolumeRamp *copy = [[[self class] allocWithZone:zone] init];
    copy.timeRange = self.timeRange;
    copy.startVolume = self.startVolume;
    copy.endVolume = self.endVolume;
    return copy;
}
@end

@implementation AVAudioMixInputParameters {
    CMPersistentTrackID _finchTrackID;
    AVAudioTimePitchAlgorithm _finchPitchAlgorithm;
    MTAudioProcessingTapRef _finchTapProcessor;
    NSMutableArray<AVFAudioVolumeRamp *> *_finchRamps;
}

- (instancetype)initWithFinchTrackID:(CMPersistentTrackID)trackID
{
    if ((self = [super init])) {
        _finchTrackID = trackID;
        _finchRamps = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc
{
    if (_finchTapProcessor)
        CFRelease(_finchTapProcessor);
}

- (CMPersistentTrackID)trackID { return _finchTrackID; }
- (AVAudioTimePitchAlgorithm)audioTimePitchAlgorithm { return _finchPitchAlgorithm; }
- (MTAudioProcessingTapRef)audioTapProcessor { return _finchTapProcessor; }

- (void)_finchSetTrackID:(CMPersistentTrackID)trackID { _finchTrackID = trackID; }
- (void)_finchSetAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm { _finchPitchAlgorithm = [algorithm copy]; }
- (void)_finchSetAudioTapProcessor:(MTAudioProcessingTapRef)tap
{
    if (tap == _finchTapProcessor)
        return;
    if (tap)
        CFRetain(tap);
    if (_finchTapProcessor)
        CFRelease(_finchTapProcessor);
    _finchTapProcessor = tap;
}
- (void)_finchSetRamps:(NSArray<AVFAudioVolumeRamp *> *)ramps
{
    _finchRamps = [[NSMutableArray alloc] initWithArray:ramps ?: @[] copyItems:YES];
}

- (float)_finchVolumeAtTime:(CMTime)time
{
    float volume = 1.0f;
    if (!CMTIME_IS_NUMERIC(time))
        return volume;
    for (AVFAudioVolumeRamp *ramp in _finchRamps) {
        CMTime start = ramp.timeRange.start;
        CMTime end = CMTimeRangeGetEnd(ramp.timeRange);
        if (CMTimeCompare(time, start) < 0)
            break;
        if (CMTimeCompare(ramp.timeRange.duration, kCMTimeZero) <= 0 || CMTimeCompare(time, end) >= 0) {
            volume = ramp.endVolume;
            continue;
        }
        return [self _finchVolumeForRamp:ramp atTime:time];
    }
    return volume;
}

- (void)_finchSetVolume:(float)volume atTime:(CMTime)time
{
    [self _finchSetVolumeRampFrom:volume to:volume timeRange:CMTimeRangeMake(time, kCMTimeZero)];
}

- (float)_finchVolumeForRamp:(AVFAudioVolumeRamp *)ramp atTime:(CMTime)time
{
    if (CMTimeCompare(ramp.timeRange.duration, kCMTimeZero) <= 0)
        return ramp.endVolume;
    double amount = CMTimeGetSeconds(CMTimeSubtract(time, ramp.timeRange.start)) /
                    CMTimeGetSeconds(ramp.timeRange.duration);
    amount = fmin(1.0, fmax(0.0, amount));
    return ramp.startVolume + (ramp.endVolume - ramp.startVolume) * (float)amount;
}

- (void)_finchSetVolumeRampFrom:(float)startVolume to:(float)endVolume timeRange:(CMTimeRange)timeRange
{
    if (!CMTIMERANGE_IS_VALID(timeRange) || CMTimeCompare(timeRange.start, kCMTimeZero) < 0 ||
        CMTimeCompare(timeRange.duration, kCMTimeZero) < 0)
        return;
    CMTime endTime = CMTimeRangeGetEnd(timeRange);
    NSMutableArray<AVFAudioVolumeRamp *> *updated = [NSMutableArray array];
    for (AVFAudioVolumeRamp *ramp in _finchRamps) {
        CMTimeRange old = ramp.timeRange;
        CMTime oldEnd = CMTimeRangeGetEnd(old);
        if (CMTimeCompare(oldEnd, timeRange.start) <= 0 || CMTimeCompare(old.start, endTime) >= 0) {
            [updated addObject:ramp];
            continue;
        }
        if (CMTimeCompare(old.start, timeRange.start) < 0) {
            AVFAudioVolumeRamp *left = [AVFAudioVolumeRamp new];
            left.timeRange = CMTimeRangeFromTimeToTime(old.start, timeRange.start);
            left.startVolume = ramp.startVolume;
            left.endVolume = [self _finchVolumeForRamp:ramp atTime:timeRange.start];
            [updated addObject:left];
        }
        if (CMTimeCompare(oldEnd, endTime) > 0) {
            AVFAudioVolumeRamp *right = [AVFAudioVolumeRamp new];
            right.timeRange = CMTimeRangeFromTimeToTime(endTime, oldEnd);
            right.startVolume = [self _finchVolumeForRamp:ramp atTime:endTime];
            right.endVolume = ramp.endVolume;
            [updated addObject:right];
        }
    }
    AVFAudioVolumeRamp *newRamp = [AVFAudioVolumeRamp new];
    newRamp.timeRange = timeRange;
    newRamp.startVolume = startVolume;
    newRamp.endVolume = endVolume;
    [updated addObject:newRamp];
    [updated sortUsingComparator:^NSComparisonResult(AVFAudioVolumeRamp *a, AVFAudioVolumeRamp *b) {
        return CMTimeCompare(a.timeRange.start, b.timeRange.start) < 0 ? NSOrderedAscending
             : CMTimeCompare(a.timeRange.start, b.timeRange.start) > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    _finchRamps = updated;
}

- (BOOL)getVolumeRampForTime:(CMTime)time startVolume:(float *)startVolume endVolume:(float *)endVolume timeRange:(CMTimeRange *)timeRange
{
    if (!CMTIME_IS_NUMERIC(time) || !_finchRamps.count)
        return NO;
    AVFAudioVolumeRamp *found = nil;
    for (NSUInteger index = 0; index < _finchRamps.count; index++) {
        AVFAudioVolumeRamp *ramp = _finchRamps[index];
        CMTimeRange range = ramp.timeRange;
        CMTime end = CMTimeRangeGetEnd(range);
        if (CMTimeCompare(range.duration, kCMTimeZero) > 0 &&
            CMTimeCompare(time, range.start) >= 0 && CMTimeCompare(time, end) < 0) {
            found = ramp;
            break;
        }
        if (CMTimeCompare(range.duration, kCMTimeZero) == 0 && CMTimeCompare(time, range.start) >= 0) {
            AVFAudioVolumeRamp *next = index + 1 < _finchRamps.count ? _finchRamps[index + 1] : nil;
            if (next && CMTimeCompare(time, next.timeRange.start) < 0) {
                AVFAudioVolumeRamp *hold = [AVFAudioVolumeRamp new];
                hold.timeRange = CMTimeRangeFromTimeToTime(range.start, next.timeRange.start);
                hold.startVolume = hold.endVolume = ramp.endVolume;
                found = hold;
                break;
            }
            if (CMTimeCompare(time, range.start) == 0) {
                found = ramp;
                break;
            }
        }
        if (CMTimeCompare(range.start, time) > 0) {
            found = ramp;
            break;
        }
    }
    if (!found)
        return NO;
    if (startVolume)
        *startVolume = found.startVolume;
    if (endVolume)
        *endVolume = found.endVolume;
    if (timeRange) {
        if (CMTimeCompare(found.timeRange.duration, kCMTimeZero) != 0)
            *timeRange = found.timeRange;
        else
            timeRange->start = found.timeRange.start;
    }
    return YES;
}

- (id)copyWithZone:(NSZone *)zone
{
    AVAudioMixInputParameters *copy = [[AVAudioMixInputParameters alloc] initWithFinchTrackID:_finchTrackID];
    [copy _finchSetAudioTimePitchAlgorithm:_finchPitchAlgorithm];
    [copy _finchSetAudioTapProcessor:_finchTapProcessor];
    [copy _finchSetRamps:_finchRamps];
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableAudioMixInputParameters *copy = [[AVMutableAudioMixInputParameters alloc] initWithFinchTrackID:_finchTrackID];
    [copy _finchSetAudioTimePitchAlgorithm:_finchPitchAlgorithm];
    [copy _finchSetAudioTapProcessor:_finchTapProcessor];
    [copy _finchSetRamps:_finchRamps];
    return copy;
}
@end

@implementation AVMutableAudioMixInputParameters
@dynamic trackID, audioTimePitchAlgorithm, audioTapProcessor;

+ (instancetype)audioMixInputParameters { return [[self alloc] initWithFinchTrackID:kCMPersistentTrackID_Invalid]; }
+ (instancetype)audioMixInputParametersWithTrack:(AVAssetTrack *)track
{
    return [[self alloc] initWithFinchTrackID:track ? track.trackID : kCMPersistentTrackID_Invalid];
}
- (void)setTrackID:(CMPersistentTrackID)value { [self _finchSetTrackID:value]; }
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)value { [self _finchSetAudioTimePitchAlgorithm:value]; }
- (void)setAudioTapProcessor:(MTAudioProcessingTapRef)value { [self _finchSetAudioTapProcessor:value]; }
- (void)setVolumeRampFromStartVolume:(float)startVolume toEndVolume:(float)endVolume timeRange:(CMTimeRange)timeRange
{
    [self _finchSetVolumeRampFrom:startVolume to:endVolume timeRange:timeRange];
}
- (void)setVolume:(float)volume atTime:(CMTime)time { [self _finchSetVolume:volume atTime:time]; }
@end

@implementation AVAudioMix {
    NSArray<AVAudioMixInputParameters *> *_finchInputParameters;
}
- (instancetype)init { return [self initWithFinchInputParameters:@[]]; }
- (instancetype)initWithFinchInputParameters:(NSArray<AVAudioMixInputParameters *> *)inputParameters
{
    if ((self = [super init]))
        [self _finchSetInputParameters:inputParameters];
    return self;
}
- (NSArray<AVAudioMixInputParameters *> *)inputParameters { return _finchInputParameters; }
- (void)_finchSetInputParameters:(NSArray<AVAudioMixInputParameters *> *)inputParameters
{
    _finchInputParameters = [inputParameters copy] ?: @[];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableAudioMix *copy = [AVMutableAudioMix audioMix];
    copy.inputParameters = _finchInputParameters;
    return copy;
}
@end

@implementation AVMutableAudioMix
@dynamic inputParameters;
+ (instancetype)audioMix { return [[self alloc] init]; }
- (void)setInputParameters:(NSArray<AVAudioMixInputParameters *> *)inputParameters
{
    [self _finchSetInputParameters:inputParameters];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[AVAudioMix alloc] initWithFinchInputParameters:self.inputParameters];
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableAudioMix *copy = [[self class] audioMix];
    copy.inputParameters = self.inputParameters;
    return copy;
}
@end

BOOL
AVFAudioMixProcessSampleBuffer(AVAudioMix *mix, CMPersistentTrackID trackID, CMSampleBufferRef sampleBuffer)
{
    if (!sampleBuffer || !CMSampleBufferGetNumSamples(sampleBuffer))
        return YES;
    CMAudioFormatDescriptionRef description = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *format = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!format || !block || format->mFormatID != kAudioFormatLinearPCM || !format->mSampleRate ||
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) || !format->mBytesPerFrame ||
        (format->mBitsPerChannel != 16 && format->mBitsPerChannel != 32) ||
        !(format->mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger)) ||
        (format->mBitsPerChannel == 16 && (format->mFormatFlags & kAudioFormatFlagIsFloat)))
        return NO;
    size_t length = CMBlockBufferGetDataLength(block);
    size_t bytesPerSample = format->mBitsPerChannel / 8;
    size_t samplesPerFrame = format->mChannelsPerFrame;
    size_t frames = MIN((size_t)CMSampleBufferGetNumSamples(sampleBuffer), length / format->mBytesPerFrame);
    if (!samplesPerFrame || samplesPerFrame * bytesPerSample > format->mBytesPerFrame)
        return NO;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_NUMERIC(pts))
        return NO;
    int32_t timeScale = (int32_t)llround(format->mSampleRate);
    if (timeScale <= 0)
        return NO;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (CMBlockBufferCopyDataBytes(block, 0, length, data.mutableBytes) != noErr)
        return NO;
    uint8_t *bytes = data.mutableBytes;
    BOOL floating = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL bigEndian = (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    for (size_t frame = 0; frame < frames; frame++) {
        CMTime at = CMTimeAdd(pts, CMTimeMake((int64_t)frame, timeScale));
        float volume = 1.0f;
        if (mix)
            for (AVAudioMixInputParameters *parameters in mix.inputParameters)
                if (parameters.trackID == trackID) {
                    volume = [parameters _finchVolumeAtTime:at];
                    break;
                }
        if (volume == 1.0f)
            continue;
        for (size_t channel = 0; channel < samplesPerFrame; channel++) {
            uint8_t *sample = bytes + frame * format->mBytesPerFrame + channel * bytesPerSample;
            if (floating && bytesPerSample == 4) {
                uint32_t bits;
                memcpy(&bits, sample, sizeof(bits));
                if (bigEndian)
                    bits = CFSwapInt32BigToHost(bits);
                float value;
                memcpy(&value, &bits, sizeof(value));
                value *= volume;
                memcpy(&bits, &value, sizeof(bits));
                if (bigEndian)
                    bits = CFSwapInt32HostToBig(bits);
                memcpy(sample, &bits, sizeof(bits));
            } else if (!floating && bytesPerSample == 2) {
                uint16_t bits;
                memcpy(&bits, sample, sizeof(bits));
                if (bigEndian)
                    bits = CFSwapInt16BigToHost(bits);
                int16_t value = (int16_t)bits;
                int32_t scaled = (int32_t)lrintf((float)value * volume);
                if (scaled > INT16_MAX) scaled = INT16_MAX;
                if (scaled < INT16_MIN) scaled = INT16_MIN;
                uint16_t output = (uint16_t)(int16_t)scaled;
                if (bigEndian)
                    output = CFSwapInt16HostToBig(output);
                memcpy(sample, &output, sizeof(output));
            } else if (!floating && bytesPerSample == 4) {
                uint32_t bits;
                memcpy(&bits, sample, sizeof(bits));
                if (bigEndian)
                    bits = CFSwapInt32BigToHost(bits);
                int32_t value = (int32_t)bits;
                double scaled = (double)value * volume;
                if (scaled > INT32_MAX) scaled = INT32_MAX;
                if (scaled < INT32_MIN) scaled = INT32_MIN;
                uint32_t output = (uint32_t)(int32_t)llround(scaled);
                if (bigEndian)
                    output = CFSwapInt32HostToBig(output);
                memcpy(sample, &output, sizeof(output));
            }
        }
    }
    return CMBlockBufferReplaceDataBytes(data.bytes, block, 0, length) == noErr;
}

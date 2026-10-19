/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Read PCM tracks as float audio and apply their AVAudioMix volume ramps. */
#import "AVFInternal.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVAssetReaderOutput.h>

@interface AVAssetReaderOutput (FinchAudioMixOutput)
- (void)_finchStartWithReader:(AVAssetReader *)reader movie:(AVFMovie *)movie range:(CMTimeRange)range;
- (BOOL)_finchFill;
- (BOOL)_finchHasStarted;
- (AVAssetReader *)_finchReader;
- (void)_finchQueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface AVAssetReader (FinchAudioMixOutput)
- (void)_finchFailWithError:(NSError *)error;
@end

@interface AVAssetTrack (FinchAudioMixOutput)
- (AVFTrack *)_finchTrack;
@end

@interface AVAssetReaderTrackOutput (FinchAudioMixOutput)
- (instancetype)initWithTrack:(AVAssetTrack *)track outputSettings:(NSDictionary *)outputSettings;
@end

@interface AVAudioMixInputParameters (FinchAudioMixOutput)
@end

static NSDictionary *
float_audio_settings(AVAssetTrack *track)
{
    CMAudioFormatDescriptionRef description = (__bridge CMAudioFormatDescriptionRef)track.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *source = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
    if (!source || !source->mSampleRate || !source->mChannelsPerFrame)
        return nil;
    return @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVSampleRateKey : @(source->mSampleRate),
        AVNumberOfChannelsKey : @(source->mChannelsPerFrame),
        AVLinearPCMBitDepthKey : @32,
        AVLinearPCMIsFloatKey : @YES,
        AVLinearPCMIsBigEndianKey : @NO,
        AVLinearPCMIsNonInterleaved : @NO
    };
}

static BOOL
matching_audio_samples(NSArray *samples)
{
    CMSampleBufferRef first = (__bridge CMSampleBufferRef)samples.firstObject;
    if (!first)
        return NO;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(first);
    CMItemCount count = CMSampleBufferGetNumSamples(first);
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(first));
    if (!CMTIME_IS_NUMERIC(pts) || !format)
        return NO;
    for (id value in samples) {
        if (value == [NSNull null])
            continue;
        CMSampleBufferRef sample = (__bridge CMSampleBufferRef)value;
        const AudioStreamBasicDescription *other = CMAudioFormatDescriptionGetStreamBasicDescription(
            (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sample));
        if (CMSampleBufferGetNumSamples(sample) != count ||
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) != 0 || !other ||
            other->mFormatID != format->mFormatID || other->mSampleRate != format->mSampleRate ||
            other->mChannelsPerFrame != format->mChannelsPerFrame || other->mBitsPerChannel != format->mBitsPerChannel ||
            other->mFormatFlags != format->mFormatFlags || other->mBytesPerFrame != format->mBytesPerFrame)
            return NO;
    }
    return YES;
}

static BOOL
add_audio_samples(CMSampleBufferRef destination, CMSampleBufferRef source)
{
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(destination));
    CMBlockBufferRef dstBlock = CMSampleBufferGetDataBuffer(destination);
    CMBlockBufferRef srcBlock = CMSampleBufferGetDataBuffer(source);
    if (!format || !dstBlock || !srcBlock || format->mFormatID != kAudioFormatLinearPCM ||
        (format->mBitsPerChannel != 16 && format->mBitsPerChannel != 32) ||
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved))
        return NO;
    size_t length = CMBlockBufferGetDataLength(dstBlock);
    if (length != CMBlockBufferGetDataLength(srcBlock) || format->mBitsPerChannel == 8)
        return NO;
    NSMutableData *dst = [NSMutableData dataWithLength:length];
    NSMutableData *src = [NSMutableData dataWithLength:length];
    if (CMBlockBufferCopyDataBytes(dstBlock, 0, length, dst.mutableBytes) != noErr ||
        CMBlockBufferCopyDataBytes(srcBlock, 0, length, src.mutableBytes) != noErr)
        return NO;
    size_t sampleCount = length / (format->mBitsPerChannel / 8);
    if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (format->mBitsPerChannel != 32)
            return NO;
        float *a = dst.mutableBytes;
        const float *b = src.bytes;
        for (size_t i = 0; i < sampleCount; i++)
            a[i] += b[i];
    } else if (format->mBitsPerChannel == 16) {
        int16_t *a = dst.mutableBytes;
        const int16_t *b = src.bytes;
        for (size_t i = 0; i < sampleCount; i++) {
            int32_t value = (int32_t)a[i] + (int32_t)b[i];
            a[i] = (int16_t)MAX(INT16_MIN, MIN(INT16_MAX, value));
        }
    } else {
        int32_t *a = dst.mutableBytes;
        const int32_t *b = src.bytes;
        for (size_t i = 0; i < sampleCount; i++) {
            int64_t value = (int64_t)a[i] + (int64_t)b[i];
            a[i] = (int32_t)MAX(INT32_MIN, MIN(INT32_MAX, value));
        }
    }
    return CMBlockBufferReplaceDataBytes(dst.bytes, dstBlock, 0, length) == noErr;
}

@implementation AVAssetReaderAudioMixOutput {
    NSArray<AVAssetTrack *> *_finchAudioTracks;
    NSDictionary *_finchAudioSettings;
    NSDictionary *_finchProcessingSettings;
    AVAudioMix *_finchAudioMix;
    AVAudioTimePitchAlgorithm _finchPitchAlgorithm;
    NSMutableArray<AVAssetReaderTrackOutput *> *_finchTrackOutputs;
    NSMutableArray *_finchHeldSamples;
    NSMutableIndexSet *_finchFinishedTracks;
}

+ (instancetype)assetReaderAudioMixOutputWithAudioTracks:(NSArray<AVAssetTrack *> *)audioTracks audioSettings:(NSDictionary<NSString *,id> *)audioSettings
{
    return [[self alloc] initWithAudioTracks:audioTracks audioSettings:audioSettings];
}

- (instancetype)initWithAudioTracks:(NSArray<AVAssetTrack *> *)audioTracks audioSettings:(NSDictionary<NSString *,id> *)audioSettings
{
    if (!audioTracks.count)
        [NSException raise:NSInvalidArgumentException format:@"At least one audio track is required"];
    for (AVAssetTrack *track in audioTracks)
        if (![track.mediaType isEqualToString:AVMediaTypeAudio])
            [NSException raise:NSInvalidArgumentException format:@"Every track must be an audio track"];
    if (audioSettings && [audioSettings[AVFormatIDKey] unsignedIntValue] != kAudioFormatLinearPCM)
        [NSException raise:NSInvalidArgumentException format:@"Audio mix output supports linear PCM only"];
    if ((self = [super init])) {
        _finchAudioTracks = [audioTracks copy];
        _finchAudioSettings = [audioSettings copy];
        _finchPitchAlgorithm = [AVAudioTimePitchAlgorithmSpectral copy];
    }
    return self;
}

- (NSArray<AVAssetTrack *> *)audioTracks { return _finchAudioTracks; }
- (NSDictionary<NSString *,id> *)audioSettings { return _finchAudioSettings; }
- (AVAudioMix *)audioMix { return _finchAudioMix; }
- (AVAudioTimePitchAlgorithm)audioTimePitchAlgorithm { return _finchPitchAlgorithm; }
- (NSString *)mediaType { return AVMediaTypeAudio; }

- (void)setAudioMix:(AVAudioMix *)audioMix
{
    AVAssetReader *reader = [self _finchReader];
    if ([self _finchHasStarted] || (reader && reader.status != AVAssetReaderStatusUnknown))
        [NSException raise:NSInvalidArgumentException format:@"The audio mix cannot be set after reading starts"];
    for (AVAudioMixInputParameters *parameters in audioMix.inputParameters) {
        BOOL found = NO;
        for (AVAssetTrack *track in _finchAudioTracks)
            if (parameters.trackID == track.trackID) {
                found = YES;
                break;
            }
        if (!found)
            [NSException raise:NSInvalidArgumentException format:@"The audio mix contains a track not used by this output"];
        AVAudioTimePitchAlgorithm algorithm = parameters.audioTimePitchAlgorithm;
        if (algorithm && ![@[AVAudioTimePitchAlgorithmTimeDomain, AVAudioTimePitchAlgorithmSpectral,
                             AVAudioTimePitchAlgorithmVarispeed] containsObject:algorithm])
            [NSException raise:NSInvalidArgumentException format:@"The audio mix contains an invalid pitch algorithm"];
    }
    _finchAudioMix = [audioMix copy];
}

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm
{
    if (![@[AVAudioTimePitchAlgorithmTimeDomain, AVAudioTimePitchAlgorithmSpectral,
            AVAudioTimePitchAlgorithmVarispeed] containsObject:algorithm])
        [NSException raise:NSInvalidArgumentException format:@"The audio time pitch algorithm is invalid"];
    _finchPitchAlgorithm = [algorithm copy];
}

- (void)_finchStartWithReader:(AVAssetReader *)reader movie:(AVFMovie *)movie range:(CMTimeRange)range
{
    [super _finchStartWithReader:reader movie:movie range:range];
    _finchTrackOutputs = [NSMutableArray arrayWithCapacity:_finchAudioTracks.count];
    _finchHeldSamples = [NSMutableArray arrayWithCapacity:_finchAudioTracks.count];
    _finchFinishedTracks = [NSMutableIndexSet indexSet];
    _finchProcessingSettings = _finchAudioSettings ?: float_audio_settings(_finchAudioTracks.firstObject);
    if (!_finchProcessingSettings) {
        [reader _finchFailWithError:AVFError(AVErrorDecoderNotFound, nil)];
        return;
    }
    for (AVAssetTrack *track in _finchAudioTracks) {
        CMAudioFormatDescriptionRef description = (__bridge CMAudioFormatDescriptionRef)track.formatDescriptions.firstObject;
        const AudioStreamBasicDescription *source = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
        if (!source || source->mFormatID != kAudioFormatLinearPCM) {
            [reader _finchFailWithError:AVFError(AVErrorDecoderNotFound, nil)];
            [_finchTrackOutputs removeAllObjects];
            return;
        }
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:_finchProcessingSettings];
        [output _finchStartWithReader:reader movie:movie range:range];
        [_finchTrackOutputs addObject:output];
        [_finchHeldSamples addObject:[NSNull null]];
    }
}

- (BOOL)_finchFill
{
    AVAssetReader *reader = [self _finchReader];
    if (!_finchTrackOutputs.count || !reader || reader.status != AVAssetReaderStatusReading)
        return NO;
    for (NSUInteger index = 0; index < _finchTrackOutputs.count; index++) {
        if ([_finchFinishedTracks containsIndex:index] || _finchHeldSamples[index] != [NSNull null])
            continue;
        AVAssetReaderTrackOutput *output = _finchTrackOutputs[index];
        CMSampleBufferRef sample = NULL;
        while ((sample = [output copyNextSampleBuffer])) {
            if (CMSampleBufferGetNumSamples(sample)) {
                _finchHeldSamples[index] = (__bridge_transfer id)sample;
                break;
            }
            CFRelease(sample);
        }
        if (!sample)
            [_finchFinishedTracks addIndex:index];
    }
    NSMutableArray *active = [NSMutableArray array];
    NSMutableArray<NSNumber *> *activeIndexes = [NSMutableArray array];
    for (NSUInteger index = 0; index < _finchHeldSamples.count; index++)
        if (_finchHeldSamples[index] != [NSNull null]) {
            [active addObject:_finchHeldSamples[index]];
            [activeIndexes addObject:@(index)];
        }
    if (!active.count)
        return NO;
    if (!matching_audio_samples(active)) {
        [reader _finchFailWithError:AVFError(AVErrorOperationNotSupportedForAsset, nil)];
        return NO;
    }
    CMSampleBufferRef result = (__bridge CMSampleBufferRef)active.firstObject;
    NSUInteger resultIndex = activeIndexes.firstObject.unsignedIntegerValue;
    for (NSUInteger i = 0; i < active.count; i++) {
        CMSampleBufferRef sample = (__bridge CMSampleBufferRef)active[i];
        NSUInteger trackIndex = activeIndexes[i].unsignedIntegerValue;
        if (!AVFAudioMixProcessSampleBuffer(_finchAudioMix, _finchAudioTracks[trackIndex].trackID, sample)) {
            [reader _finchFailWithError:AVFError(AVErrorOperationNotSupportedForAsset, nil)];
            return NO;
        }
        if (i > 0 && !add_audio_samples(result, sample)) {
            [reader _finchFailWithError:AVFError(AVErrorOperationNotSupportedForAsset, nil)];
            return NO;
        }
    }
    [self _finchQueueSampleBuffer:(__bridge CMSampleBufferRef)_finchHeldSamples[resultIndex]];
    for (NSNumber *value in activeIndexes)
        _finchHeldSamples[value.unsignedIntegerValue] = [NSNull null];
    return YES;
}
@end

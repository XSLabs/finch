/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Walk a QuickTime track's parsed sample table in decode or presentation order. */
#import "AVFMovie.h"
#import <AVFoundation/AVAsset.h>
#import <AVFoundation/AVAssetTrack.h>
#import <AVFoundation/AVSampleCursor.h>
#include <limits.h>

@interface AVAssetTrack (FinchSampleCursor)
- (AVFTrack *)_finchTrack;
@end

@interface AVSampleCursor (FinchSampleCursor)
- (instancetype)initWithFinchTrack:(AVAssetTrack *)owner index:(NSUInteger)index presentationOrder:(NSArray<NSNumber *> *)order;
- (NSUInteger)_finchPresentationPosition;
- (CMTime)_finchTimeForIndex:(NSUInteger)index presentation:(BOOL)presentation;
@end

static CMTime
AVFTimeForSample(AVFTrack *track, NSUInteger index, BOOL presentation)
{
    if (!track || index >= track->sampleCount || !track->timescale)
        return kCMTimeInvalid;
    AVFSample sample = track->samples[index];
    CMTime time = CMTimeMake(sample.decodeTime, (int32_t)track->timescale);
    if (presentation && sample.compositionOffset)
        time = CMTimeAdd(time, CMTimeMake(sample.compositionOffset, (int32_t)track->timescale));
    return time;
}

static NSArray<NSNumber *> *
AVFPresentationOrder(AVFTrack *track)
{
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:track->sampleCount];
    for (NSUInteger i = 0; i < track->sampleCount; i++)
        [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSComparisonResult result = CMTimeCompare(AVFTimeForSample(track, a.unsignedIntegerValue, YES),
                                                  AVFTimeForSample(track, b.unsignedIntegerValue, YES));
        if (result != NSOrderedSame)
            return result;
        if (a.unsignedIntegerValue < b.unsignedIntegerValue) return NSOrderedAscending;
        if (a.unsignedIntegerValue > b.unsignedIntegerValue) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return order;
}

@implementation AVSampleCursor {
    AVAssetTrack *_finchOwner;
    AVFTrack *_finchTrack;
    NSArray<NSNumber *> *_finchPresentationOrder;
    NSUInteger _finchIndex;
}

- (instancetype)initWithFinchTrack:(AVAssetTrack *)owner index:(NSUInteger)index presentationOrder:(NSArray<NSNumber *> *)order
{
    if ((self = [super init])) {
        _finchOwner = owner;
        _finchTrack = [owner _finchTrack];
        _finchPresentationOrder = order;
        _finchIndex = index;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithFinchTrack:_finchOwner index:_finchIndex presentationOrder:_finchPresentationOrder];
}

- (NSUInteger)_finchPresentationPosition
{
    return [_finchPresentationOrder indexOfObject:@(_finchIndex)];
}

- (AVAssetTrack *)_finchOwner { return _finchOwner; }
- (AVFTrack *)_finchTrack { return _finchTrack; }
- (NSUInteger)_finchIndex { return _finchIndex; }

- (CMTime)_finchTimeForIndex:(NSUInteger)index presentation:(BOOL)presentation
{
    return AVFTimeForSample(_finchTrack, index, presentation);
}

- (int64_t)stepInDecodeOrderByCount:(int64_t)stepCount
{
    if (!_finchTrack->sampleCount || !stepCount)
        return 0;
    __int128 proposed = (__int128)_finchIndex + stepCount;
    NSUInteger next = proposed < 0 ? 0 : proposed >= _finchTrack->sampleCount ? _finchTrack->sampleCount - 1 : (NSUInteger)proposed;
    int64_t moved = (int64_t)next - (int64_t)_finchIndex;
    _finchIndex = next;
    return moved;
}

- (int64_t)stepInPresentationOrderByCount:(int64_t)stepCount
{
    if (!_finchTrack->sampleCount || !stepCount)
        return 0;
    NSUInteger oldPosition = [self _finchPresentationPosition];
    __int128 proposed = (__int128)oldPosition + stepCount;
    NSUInteger nextPosition = proposed < 0 ? 0 : proposed >= _finchPresentationOrder.count ? _finchPresentationOrder.count - 1 : (NSUInteger)proposed;
    _finchIndex = _finchPresentationOrder[nextPosition].unsignedIntegerValue;
    return (int64_t)nextPosition - (int64_t)oldPosition;
}

- (CMTime)_finchStepByTime:(CMTime)delta presentation:(BOOL)presentation wasPinned:(BOOL *)outWasPinned
{
    if (outWasPinned)
        *outWasPinned = NO;
    if (!CMTIME_IS_NUMERIC(delta))
        return kCMTimeInvalid;

    NSArray<NSNumber *> *order = presentation ? _finchPresentationOrder : nil;
    NSUInteger oldIndex = _finchIndex;
    NSUInteger oldPosition = presentation ? [self _finchPresentationPosition] : oldIndex;
    CMTime oldTime = [self _finchTimeForIndex:oldIndex presentation:presentation];
    CMTime target = CMTimeAdd(oldTime, delta);
    NSUInteger firstIndex = presentation ? order.firstObject.unsignedIntegerValue : 0;
    NSUInteger lastIndex = presentation ? order.lastObject.unsignedIntegerValue : _finchTrack->sampleCount - 1;
    CMTime firstTime = [self _finchTimeForIndex:firstIndex presentation:presentation];
    CMTime lastTime = [self _finchTimeForIndex:lastIndex presentation:presentation];
    BOOL backwards = CMTimeCompare(delta, kCMTimeZero) < 0;
    if (CMTimeCompare(target, firstTime) < 0) {
        _finchIndex = firstIndex;
        if (outWasPinned) *outWasPinned = YES;
    } else if (CMTimeCompare(target, lastTime) > 0) {
        _finchIndex = lastIndex;
        if (outWasPinned) *outWasPinned = YES;
    } else {
        for (NSUInteger p = 0; p < _finchTrack->sampleCount; p++) {
            NSUInteger index = presentation ? order[p].unsignedIntegerValue : p;
            CMTime candidate = [self _finchTimeForIndex:index presentation:presentation];
            if ((!backwards && CMTimeCompare(candidate, target) >= 0) || (backwards && CMTimeCompare(candidate, target) > 0))
                continue;
            _finchIndex = index;
        }
        /* A backward move to an exact sample time chooses that sample. */
        if (backwards) {
            for (NSUInteger p = 0; p < _finchTrack->sampleCount; p++) {
                NSUInteger index = presentation ? order[p].unsignedIntegerValue : p;
                if (CMTimeCompare([self _finchTimeForIndex:index presentation:presentation], target) == 0) {
                    _finchIndex = index;
                    break;
                }
            }
        }
    }
    (void)oldPosition;
    return CMTimeSubtract([self _finchTimeForIndex:_finchIndex presentation:presentation], oldTime);
}

- (CMTime)stepByDecodeTime:(CMTime)deltaDecodeTime wasPinned:(BOOL *)outWasPinned
{
    return [self _finchStepByTime:deltaDecodeTime presentation:NO wasPinned:outWasPinned];
}

- (CMTime)stepByPresentationTime:(CMTime)deltaPresentationTime wasPinned:(BOOL *)outWasPinned
{
    return [self _finchStepByTime:deltaPresentationTime presentation:YES wasPinned:outWasPinned];
}

- (CMTime)presentationTimeStamp { return [self _finchTimeForIndex:_finchIndex presentation:YES]; }
- (CMTime)decodeTimeStamp { return [self _finchTimeForIndex:_finchIndex presentation:NO]; }
- (CMTime)currentSampleDuration
{
    return _finchTrack->timescale ? CMTimeMake(_finchTrack->samples[_finchIndex].duration, (int32_t)_finchTrack->timescale) : kCMTimeInvalid;
}

- (NSComparisonResult)comparePositionInDecodeOrderWithPositionOfCursor:(AVSampleCursor *)cursor
{
    if (_finchIndex < cursor->_finchIndex) return NSOrderedAscending;
    if (_finchIndex > cursor->_finchIndex) return NSOrderedDescending;
    return NSOrderedSame;
}

- (BOOL)samplesWithEarlierDecodeTimeStampsMayHaveLaterPresentationTimeStampsThanCursor:(AVSampleCursor *)cursor
{
    CMTime target = cursor.presentationTimeStamp;
    for (NSUInteger i = 0; i < _finchIndex; i++)
        if (CMTimeCompare([self _finchTimeForIndex:i presentation:YES], target) > 0)
            return YES;
    return NO;
}

- (BOOL)samplesWithLaterDecodeTimeStampsMayHaveEarlierPresentationTimeStampsThanCursor:(AVSampleCursor *)cursor
{
    CMTime target = cursor.presentationTimeStamp;
    for (NSUInteger i = _finchIndex + 1; i < _finchTrack->sampleCount; i++)
        if (CMTimeCompare([self _finchTimeForIndex:i presentation:YES], target) < 0)
            return YES;
    return NO;
}

- (CMFormatDescriptionRef)copyCurrentSampleFormatDescription
{
    AVFSample sample = _finchTrack->samples[_finchIndex];
    if (sample.description >= _finchTrack->formatDescriptions.count)
        return NULL;
    return (CMFormatDescriptionRef)CFRetain((__bridge CFTypeRef)_finchTrack->formatDescriptions[sample.description]);
}

- (AVSampleCursorSyncInfo)currentSampleSyncInfo
{
    AVSampleCursorSyncInfo value = { _finchTrack->samples[_finchIndex].sync, NO, NO };
    return value;
}

- (AVSampleCursorDependencyInfo)currentSampleDependencyInfo
{
    return (AVSampleCursorDependencyInfo){ NO, NO, NO, NO, NO, NO };
}

- (NSDictionary *)currentSampleDependencyAttachments { return nil; }

- (AVSampleCursorAudioDependencyInfo)currentSampleAudioDependencyInfo
{
    AVSampleCursorAudioDependencyInfo value = { NO, 0 };
    AVFSample sample = _finchTrack->samples[_finchIndex];
    if (_finchTrack->handler == 'soun' && sample.description < _finchTrack->formatDescriptions.count) {
        CMAudioFormatDescriptionRef format = (__bridge CMAudioFormatDescriptionRef)_finchTrack->formatDescriptions[sample.description];
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
        if (asbd && asbd->mFormatID == 'lpcm')
            value.audioSampleIsIndependentlyDecodable = YES;
    }
    return value;
}

- (NSInteger)samplesRequiredForDecoderRefresh
{
    NSInteger count = 0;
    for (NSInteger i = (NSInteger)_finchIndex - 1; i >= 0; i--) {
        if (_finchTrack->samples[i].sync)
            return count;
        count++;
    }
    return count;
}

- (NSURL *)currentChunkStorageURL
{
    AVAsset *asset = _finchOwner.asset;
    return [asset isKindOfClass:[AVURLAsset class]] ? ((AVURLAsset *)asset).URL : nil;
}

- (AVSampleCursorStorageRange)currentChunkStorageRange
{
    AVFSample sample = _finchTrack->samples[_finchIndex];
    if (sample.chunkLength > INT64_MAX || sample.chunkOffset > INT64_MAX)
        return (AVSampleCursorStorageRange){ -1, -1 };
    return (AVSampleCursorStorageRange){ (int64_t)sample.chunkOffset, (int64_t)sample.chunkLength };
}

- (AVSampleCursorChunkInfo)currentChunkInfo
{
    AVFSample current = _finchTrack->samples[_finchIndex];
    NSUInteger first = _finchIndex - MIN(_finchIndex, current.chunkSampleIndex);
    NSUInteger count = current.chunkSampleCount ?: 1;
    if (first + count > _finchTrack->sampleCount)
        count = _finchTrack->sampleCount - first;
    BOOL uniformSizes = current.chunkHasUniformSampleSizes, uniformDurations = YES, uniformFormats = YES;
    for (NSUInteger i = first + 1; i < first + count; i++) {
        AVFSample sample = _finchTrack->samples[i];
        uniformSizes &= sample.size == current.size;
        uniformDurations &= sample.duration == current.duration;
        uniformFormats &= sample.description == current.description;
    }
    return (AVSampleCursorChunkInfo){ (int64_t)count, uniformSizes, uniformDurations, uniformFormats };
}

- (int64_t)currentSampleIndexInChunk { return _finchTrack->samples[_finchIndex].chunkSampleIndex; }

- (AVSampleCursorStorageRange)currentSampleStorageRange
{
    AVFSample sample = _finchTrack->samples[_finchIndex];
    if (sample.offset > INT64_MAX)
        return (AVSampleCursorStorageRange){ -1, -1 };
    return (AVSampleCursorStorageRange){ (int64_t)sample.offset, sample.size };
}

@end

@implementation AVAssetTrack (FinchSampleCursorProvision)

- (AVSampleCursor *)makeSampleCursorAtFirstSampleInDecodeOrder
{
    AVFTrack *track = [self _finchTrack];
    if (!track || !track->sampleCount || !track->timescale)
        return nil;
    return [[AVSampleCursor alloc] initWithFinchTrack:self index:0 presentationOrder:AVFPresentationOrder(track)];
}

- (AVSampleCursor *)makeSampleCursorAtLastSampleInDecodeOrder
{
    AVFTrack *track = [self _finchTrack];
    if (!track || !track->sampleCount || !track->timescale)
        return nil;
    return [[AVSampleCursor alloc] initWithFinchTrack:self index:track->sampleCount - 1 presentationOrder:AVFPresentationOrder(track)];
}

- (AVSampleCursor *)makeSampleCursorWithPresentationTimeStamp:(CMTime)presentationTimeStamp
{
    AVFTrack *track = [self _finchTrack];
    if (!track || !track->sampleCount || !track->timescale || !CMTIME_IS_NUMERIC(presentationTimeStamp))
        return nil;
    NSArray<NSNumber *> *order = AVFPresentationOrder(track);
    NSUInteger selected = order.firstObject.unsignedIntegerValue;
    for (NSNumber *number in order) {
        NSUInteger index = number.unsignedIntegerValue;
        if (CMTimeCompare(AVFTimeForSample(track, index, YES), presentationTimeStamp) > 0)
            break;
        selected = index;
    }
    return [[AVSampleCursor alloc] initWithFinchTrack:self index:selected presentationOrder:order];
}

@end

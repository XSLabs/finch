/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Audio renderer settings are stored; enqueueing fails until Finch has audio output. */
#import "AVFInternal.h"
#import <AVFoundation/AVQueuedSampleBufferRendering.h>
#import <AVFoundation/AVSampleBufferAudioRenderer.h>
#import <AVFoundation/AVSampleBufferRenderSynchronizer.h>

@interface AVSampleBufferAudioRenderer ()
- (void)_finchSetRenderSynchronizer:(AVSampleBufferRenderSynchronizer *)synchronizer;
@end

@implementation AVSampleBufferAudioRenderer {
    CMTimebaseRef _finchTimebase;
    __weak AVSampleBufferRenderSynchronizer *_finchSynchronizer;
    NSError *_finchError;
    AVQueuedSampleBufferRenderingStatus _finchStatus;
    NSString *_finchOutputDeviceID;
    AVAudioTimePitchAlgorithm _finchPitchAlgorithm;
    AVAudioSpatializationFormats _finchSpatializationFormats;
    float _finchVolume;
    BOOL _finchMuted;
    dispatch_queue_t _finchRequestQueue;
    dispatch_block_t _finchRequestBlock;
}

- (instancetype)init
{
    if ((self = [super init])) {
        if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_finchTimebase) != noErr)
            return nil;
        _finchStatus = AVQueuedSampleBufferRenderingStatusUnknown;
        _finchVolume = 1.0f;
        _finchPitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
        _finchSpatializationFormats = AVAudioSpatializationFormatMultichannel;
    }
    return self;
}

- (void)dealloc
{
    [self stopRequestingMediaData];
    if (_finchTimebase)
        CFRelease(_finchTimebase);
}

- (AVQueuedSampleBufferRenderingStatus)status { return _finchStatus; }
- (NSError *)error { return _finchError; }
- (NSString *)audioOutputDeviceUniqueID { return _finchOutputDeviceID; }
- (void)setAudioOutputDeviceUniqueID:(NSString *)identifier { _finchOutputDeviceID = [identifier copy]; }
- (AVAudioTimePitchAlgorithm)audioTimePitchAlgorithm { return _finchPitchAlgorithm; }
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm { _finchPitchAlgorithm = [algorithm copy]; }
- (AVAudioSpatializationFormats)allowedAudioSpatializationFormats { return _finchSpatializationFormats; }
- (void)setAllowedAudioSpatializationFormats:(AVAudioSpatializationFormats)formats { _finchSpatializationFormats = formats; }
- (float)volume { return _finchVolume; }
- (void)setVolume:(float)volume { _finchVolume = volume; }
- (BOOL)isMuted { return _finchMuted; }
- (void)setMuted:(BOOL)muted { _finchMuted = muted; }
- (CMTimebaseRef)timebase { return _finchSynchronizer.timebase ?: _finchTimebase; }
- (BOOL)isReadyForMoreMediaData { return _finchStatus != AVQueuedSampleBufferRenderingStatusFailed; }
- (BOOL)hasSufficientMediaDataForReliablePlaybackStart { return NO; }

- (void)_finchSetRenderSynchronizer:(AVSampleBufferRenderSynchronizer *)synchronizer
{
    _finchSynchronizer = synchronizer;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (!sampleBuffer)
        [NSException raise:NSInvalidArgumentException format:@"sampleBuffer must not be NULL"];
    if (_finchStatus == AVQueuedSampleBufferRenderingStatusFailed)
        return;
    _finchError = AVFError(AVErrorDeviceNotConnected, nil);
    _finchStatus = AVQueuedSampleBufferRenderingStatusFailed;
    [self stopRequestingMediaData];
}

- (void)flush
{
    /* A failed renderer has no queued audio to recover. */
}

- (void)flushFromSourceTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler
{
    BOOL success = _finchStatus != AVQueuedSampleBufferRenderingStatusFailed &&
        CMTIME_IS_NUMERIC(time) && CMTimeCompare(time, self.timebase ? CMTimebaseGetTime(self.timebase) : kCMTimeZero) >= 0;
    if (completionHandler)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completionHandler(success); });
}

- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)block
{
    [self stopRequestingMediaData];
    if (!queue || !block)
        [NSException raise:NSInvalidArgumentException format:@"queue and block must not be nil"];
    if (!self.isReadyForMoreMediaData)
        return;
    _finchRequestQueue = queue;
    _finchRequestBlock = [block copy];
    dispatch_async(queue, _finchRequestBlock);
}

- (void)stopRequestingMediaData
{
    _finchRequestBlock = nil;
    _finchRequestQueue = nil;
}

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Playback: AVPlayerItem, AVPlayerItemTrack, AVPlayer, AVQueuePlayer, AVPlayerLooper,
 * AVPlayerItemVideoOutput and AVPlayerLayer. A player's clock is the host time clock; a
 * main-thread timer at 60 Hz moves the current item, runs time observers and stops at
 * the end. Frames are decoded from the asset when asked for (JPEG through ImageIO).
 * Finch has no audio device yet, so audio isn't heard. As Apple's (macOS 26.4,
 * avplayer-test.m):
 *   - An item's duration is indefinite and its status unknown until its asset has
 *     loaded (asynchronously); then it's ready (a player becomes ready with it) or failed
 *     with the asset's error. The player is ready either way.
 *   - Playing goes waiting, then playing (timeControlStatus, observable); at the end the
 *     item's time is its duration, AVPlayerItemDidPlayToEndTimeNotification is posted
 *     once, and by default the player pauses.
 *   - A seek ends at the time asked for (with zero tolerance, or none given) and calls
 *     its completion with YES; seeking to zero gives kCMTimeZero.
 *   - A video output has a frame once the item's time has moved (a seek or playing).
 *   - A layer fits the presentation size into its bounds by its gravity (aspect by
 *     default); an empty layer's video rect is empty.
 */
#import "AVFInternal.h"

/* (the initialisers chain as Apple's headers allow, not as they mark them) */
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

@interface AVURLAsset (FinchPlayback)
- (AVFMovie *)_finchMovie;
- (NSError *)_finchError;
@end

@interface AVAssetTrack (FinchPlayback)
- (AVFTrack *)_finchTrack;
@end

@interface AVPlayerItem ()
- (void)_finchAttachPlayer:(AVPlayer *)player;
- (void)_finchSetTime:(CMTime)time;
- (CGImageRef)_finchCopyImageAtTime:(CMTime)time sampleIndex:(size_t *)indexOut;
@end

@interface AVPlayerItemOutput ()
- (void)_finchItemTimeMoved;
@end

#pragma mark - Item tracks

@implementation AVPlayerItemTrack {
    AVAssetTrack *_fassetTrack;
    BOOL _fenabled;
}

- (instancetype)initWithFinchAssetTrack:(AVAssetTrack *)track
{
    if ((self = [super init])) {
        _fassetTrack = track;
        _fenabled = YES;
    }
    return self;
}

- (AVAssetTrack *)assetTrack { return _fassetTrack; }
- (BOOL)isEnabled { return _fenabled; }
- (void)setEnabled:(BOOL)enabled { _fenabled = enabled; }
- (float)currentVideoFrameRate { return _fassetTrack.nominalFrameRate; }

@end

#pragma mark - Items

@implementation AVPlayerItem {
    AVAsset *_fasset;
    AVPlayerItemStatus _fstatus;
    NSError *_ferror;
    NSArray *_ftracks;
    NSMutableArray *_foutputs;
    __weak AVPlayer *_fplayer;
    CMTime _ftime, _fforwardEnd, _freverseEnd;
    BOOL _floaded;
    AVAudioMix *_faudioMix;
    AVVideoComposition *_fvideoComposition;
    NSTimeInterval _fbufferDuration;
    double _fpeakBitRate;
    CGSize _fmaxResolution;
}

+ (instancetype)playerItemWithURL:(NSURL *)URL { return [[self alloc] initWithURL:URL]; }
+ (instancetype)playerItemWithAsset:(AVAsset *)asset { return [[self alloc] initWithAsset:asset]; }
+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys
{
    return [[self alloc] initWithAsset:asset automaticallyLoadedAssetKeys:keys];
}

- (instancetype)initWithURL:(NSURL *)URL { return [self initWithAsset:[AVURLAsset URLAssetWithURL:URL options:nil]]; }
- (instancetype)initWithAsset:(AVAsset *)asset { return [self initWithAsset:asset automaticallyLoadedAssetKeys:nil]; }

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys
{
    if ((self = [super init])) {
        _fasset = asset;
        _ftime = kCMTimeZero;
        _fforwardEnd = kCMTimeInvalid;
        _freverseEnd = kCMTimeInvalid;
        _foutputs = [NSMutableArray array];
        _ftracks = @[];
        __weak AVPlayerItem *weakSelf = self;
        [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration", @"playable" ] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf _finchAssetLoaded];
            });
        }];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return [[AVPlayerItem alloc] initWithAsset:_fasset]; }
- (id)copy { return [self copyWithZone:nil]; }

- (void)_finchAssetLoaded
{
    NSError *e = nil;
    AVKeyValueStatus s = [_fasset statusOfValueForKey:@"tracks" error:&e];
    NSMutableArray *tracks = [NSMutableArray array];
    if (s == AVKeyValueStatusLoaded)
        for (AVAssetTrack *t in _fasset.tracks)
            [tracks addObject:[[AVPlayerItemTrack alloc] initWithFinchAssetTrack:t]];
    [self willChangeValueForKey:@"tracks"];
    [self willChangeValueForKey:@"duration"];
    [self willChangeValueForKey:@"presentationSize"];
    _ftracks = tracks;
    _floaded = YES;
    [self didChangeValueForKey:@"presentationSize"];
    [self didChangeValueForKey:@"duration"];
    [self didChangeValueForKey:@"tracks"];
    [self willChangeValueForKey:@"status"];
    if (s == AVKeyValueStatusLoaded && _fasset.playable) {
        _fstatus = AVPlayerItemStatusReadyToPlay;
    } else {
        _fstatus = AVPlayerItemStatusFailed;
        _ferror = e ?: AVFError(AVErrorUnknown, nil);
    }
    [self didChangeValueForKey:@"status"];
    [_fplayer performSelector:@selector(_finchItemLoaded:) withObject:self];
}

- (AVAsset *)asset { return _fasset; }
- (AVPlayerItemStatus)status { return _fstatus; }
- (NSError *)error { return _ferror; }
- (NSArray<AVPlayerItemTrack *> *)tracks { return _ftracks; }
- (NSArray<NSString *> *)automaticallyLoadedAssetKeys { return @[]; }
- (CMTime)duration { return _floaded && _fstatus == AVPlayerItemStatusReadyToPlay ? _fasset.duration : kCMTimeIndefinite; }

- (CGSize)presentationSize
{
    if (!_floaded)
        return CGSizeZero;
    for (AVPlayerItemTrack *t in _ftracks)
        if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) {
            CGSize s = CGSizeApplyAffineTransform(t.assetTrack.naturalSize, t.assetTrack.preferredTransform);
            return CGSizeMake(fabs(s.width), fabs(s.height));
        }
    return CGSizeZero;
}

- (CMTime)currentTime
{
    AVPlayer *p = _fplayer;
    if (p && p.currentItem == self)
        return p.currentTime;
    return _ftime;
}

- (NSDate *)currentDate { return nil; }
- (CMTime)_finchStoredTime { return _ftime; }
- (void)_finchSetTime:(CMTime)time
{
    _ftime = time;
    for (AVPlayerItemOutput *o in _foutputs)
        [o _finchItemTimeMoved];
}
- (void)_finchAttachPlayer:(AVPlayer *)player { _fplayer = player; }

- (CMTime)forwardPlaybackEndTime { return _fforwardEnd; }
- (void)setForwardPlaybackEndTime:(CMTime)t { _fforwardEnd = t; }
- (CMTime)reversePlaybackEndTime { return _freverseEnd; }
- (void)setReversePlaybackEndTime:(CMTime)t { _freverseEnd = t; }
- (BOOL)canPlayFastForward { return _floaded; }
- (BOOL)canPlaySlowForward { return _floaded; }
- (BOOL)canPlayReverse { return _floaded; }
- (BOOL)canPlaySlowReverse { return _floaded; }
- (BOOL)canPlayFastReverse { return _floaded; }
- (BOOL)canStepForward { return _floaded; }
- (BOOL)canStepBackward { return _floaded; }
- (BOOL)isPlaybackLikelyToKeepUp { return _fstatus == AVPlayerItemStatusReadyToPlay; }
- (BOOL)isPlaybackBufferFull { return _fstatus == AVPlayerItemStatusReadyToPlay; }
- (BOOL)isPlaybackBufferEmpty { return NO; }
- (NSTimeInterval)preferredForwardBufferDuration { return _fbufferDuration; }
- (void)setPreferredForwardBufferDuration:(NSTimeInterval)d { _fbufferDuration = d; }
- (double)preferredPeakBitRate { return _fpeakBitRate; }
- (void)setPreferredPeakBitRate:(double)r { _fpeakBitRate = r; }
- (CGSize)preferredMaximumResolution { return _fmaxResolution; }
- (void)setPreferredMaximumResolution:(CGSize)s { _fmaxResolution = s; }
- (AVAudioMix *)audioMix { return _faudioMix; }
- (void)setAudioMix:(AVAudioMix *)mix { _faudioMix = mix; }
- (AVVideoComposition *)videoComposition { return _fvideoComposition; }
- (void)setVideoComposition:(AVVideoComposition *)c { _fvideoComposition = c; }
- (BOOL)seekingWaitsForVideoCompositionRendering { return NO; }
- (void)setSeekingWaitsForVideoCompositionRendering:(BOOL)flag {}
- (AVAudioTimePitchAlgorithm)audioTimePitchAlgorithm { return AVAudioTimePitchAlgorithmTimeDomain; }
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)a {}
- (AVPlayerItemAccessLog *)accessLog { return nil; }
- (AVPlayerItemErrorLog *)errorLog { return nil; }
- (NSArray<AVMetadataItem *> *)externalMetadata { return @[]; }
- (void)setExternalMetadata:(NSArray<AVMetadataItem *> *)m {}
- (NSArray<AVTimedMetadataGroup *> *)navigationMarkerGroups { return @[]; }
- (void)setNavigationMarkerGroups:(NSArray<AVTimedMetadataGroup *> *)g {}

- (NSArray<NSValue *> *)loadedTimeRanges
{
    return _floaded ? @[ [NSValue valueWithCMTimeRange:CMTimeRangeMake(kCMTimeZero, _fasset.duration)] ] : @[];
}

- (NSArray<NSValue *> *)seekableTimeRanges
{
    return _floaded ? @[ [NSValue valueWithCMTimeRange:CMTimeRangeMake(kCMTimeZero, _fasset.duration)] ] : @[];
}

- (NSArray<AVPlayerItemOutput *> *)outputs { return [_foutputs copy]; }

- (void)addOutput:(AVPlayerItemOutput *)output
{
    if (output && ![_foutputs containsObject:output]) {
        [_foutputs addObject:output];
        [output setValue:self forKey:@"_finchItem"];
    }
}

- (void)removeOutput:(AVPlayerItemOutput *)output { [_foutputs removeObject:output]; }

- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:completionHandler];
}

- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after completionHandler:(void (^)(BOOL))handler
{
    AVPlayer *p = _fplayer;
    if (p && p.currentItem == self) {
        [p seekToTime:time toleranceBefore:before toleranceAfter:after completionHandler:handler];
        return;
    }
    [self _finchSetTime:time];
    if (handler) {
        void (^h)(BOOL) = [handler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            h(YES);
        });
    }
}

- (void)seekToTime:(CMTime)time { [self seekToTime:time completionHandler:nil]; }
- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after
{
    [self seekToTime:time toleranceBefore:before toleranceAfter:after completionHandler:nil];
}
- (BOOL)seekToDate:(NSDate *)date { return NO; }
- (BOOL)seekToDate:(NSDate *)date completionHandler:(void (^)(BOOL))handler { return NO; }
- (void)cancelPendingSeeks {}

- (void)stepByCount:(NSInteger)stepCount
{
    AVAssetTrack *v = [_fasset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    float rate = v.nominalFrameRate;
    if (rate <= 0)
        return;
    CMTime step = CMTimeMultiplyByRatio(CMTimeMake(1, (int32_t)lroundf(rate * 600)), 600 * (int32_t)stepCount, 1);
    [self seekToTime:CMTimeAdd(self.currentTime, step) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:nil];
}

/* The frame on screen at a time (the last one past the end). */
- (CGImageRef)_finchCopyImageAtTime:(CMTime)time sampleIndex:(size_t *)indexOut
{
    AVAssetTrack *track = [_fasset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVFMovie *movie = [_fasset respondsToSelector:@selector(_finchMovie)] ? [(AVURLAsset *)_fasset _finchMovie] : nil;
    AVFTrack *t = [track _finchTrack];
    if (!t || !movie || !t->sampleCount)
        return NULL;
    CMTime at = CMTimeConvertScale(time, (int32_t)t->timescale, kCMTimeRoundingMethod_RoundTowardNegativeInfinity);
    size_t index = t->sampleCount - 1;
    for (size_t i = 0; i < t->sampleCount; i++) {
        int64_t pts = t->samples[i].decodeTime + t->samples[i].compositionOffset;
        if (at.value < pts) {
            index = i ? i - 1 : 0;
            break;
        }
    }
    if (indexOut)
        *indexOut = index;
    return AVFCopySampleImage(t, movie->data, index);
}

@end

#pragma mark - Outputs

@implementation AVPlayerItemOutput {
@protected
    __weak AVPlayerItem *_fitem;
    BOOL _fsuppresses;
}
- (void)set_finchItem:(AVPlayerItem *)item { _fitem = item; }
- (void)_finchItemTimeMoved {}
- (BOOL)suppressesPlayerRendering { return _fsuppresses; }
- (void)setSuppressesPlayerRendering:(BOOL)flag { _fsuppresses = flag; }
- (CMTime)itemTimeForHostTime:(CFTimeInterval)hostTimeInSeconds
{
    AVPlayerItem *i = _fitem;
    return i ? i.currentTime : kCMTimeInvalid;
}
- (CMTime)itemTimeForMachAbsoluteTime:(int64_t)machAbsoluteTime
{
    AVPlayerItem *i = _fitem;
    return i ? i.currentTime : kCMTimeInvalid;
}
- (CMTime)itemTimeForCVTimeStamp:(CVTimeStamp)timestamp
{
    AVPlayerItem *i = _fitem;
    return i ? i.currentTime : kCMTimeInvalid;
}
@end

@implementation AVPlayerItemVideoOutput {
    NSDictionary *_fattributes;
    BOOL _fmoved;
    size_t _flastIndex;
    BOOL _fcopiedAny;
    __weak id<AVPlayerItemOutputPullDelegate> _fdelegate;
    dispatch_queue_t _fdelegateQueue;
}

- (instancetype)initWithPixelBufferAttributes:(NSDictionary<NSString *, id> *)pixelBufferAttributes
{
    if ((self = [super init]))
        _fattributes = [pixelBufferAttributes copy];
    return self;
}

- (instancetype)initWithOutputSettings:(NSDictionary<NSString *, id> *)outputSettings
{
    return [self initWithPixelBufferAttributes:outputSettings];
}

- (void)_finchItemTimeMoved { _fmoved = YES; }
- (id<AVPlayerItemOutputPullDelegate>)delegate { return _fdelegate; }
- (dispatch_queue_t)delegateQueue { return _fdelegateQueue; }
- (void)setDelegate:(id<AVPlayerItemOutputPullDelegate>)delegate queue:(dispatch_queue_t)queue
{
    _fdelegate = delegate;
    _fdelegateQueue = queue;
}
- (void)requestNotificationOfMediaDataChangeWithAdvanceInterval:(NSTimeInterval)interval
{
    id<AVPlayerItemOutputPullDelegate> d = _fdelegate;
    dispatch_queue_t q = _fdelegateQueue ?: dispatch_get_main_queue();
    if ([d respondsToSelector:@selector(outputMediaDataWillChange:)])
        dispatch_async(q, ^{
            [d outputMediaDataWillChange:self];
        });
}

- (BOOL)hasNewPixelBufferForItemTime:(CMTime)itemTime
{
    AVPlayerItem *item = _fitem;
    if (!item || !_fmoved)
        return NO;
    size_t index = 0;
    CGImageRef im = [item _finchCopyImageAtTime:itemTime sampleIndex:&index];
    if (!im)
        return NO;
    CGImageRelease(im);
    return !_fcopiedAny || index != _flastIndex;
}

- (CVPixelBufferRef)copyPixelBufferForItemTime:(CMTime)itemTime itemTimeForDisplay:(CMTime *)outItemTimeForDisplay
{
    AVPlayerItem *item = _fitem;
    if (!item || !_fmoved)
        return NULL;
    size_t index = 0;
    CGImageRef im = [item _finchCopyImageAtTime:itemTime sampleIndex:&index];
    if (!im)
        return NULL;
    OSType format = _fattributes[(id)kCVPixelBufferPixelFormatTypeKey] ? [_fattributes[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue]
                                                                         : kCVPixelFormatType_32BGRA;
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im);
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    if (format != kCVPixelFormatType_32ARGB)
        format = kCVPixelFormatType_32BGRA;
    if (!CVPixelBufferCreate(NULL, w, h, format, (__bridge CFDictionaryRef)attrs, &pb)) {
        CVPixelBufferLockBaseAddress(pb, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        uint32_t info = format == kCVPixelFormatType_32ARGB ? (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Big
                                                             : (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little;
        CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb), cs, info);
        CGColorSpaceRelease(cs);
        if (c) {
            CGContextDrawImage(c, CGRectMake(0, 0, w, h), im);
            CGContextRelease(c);
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    CGImageRelease(im);
    _flastIndex = index;
    _fcopiedAny = YES;
    if (outItemTimeForDisplay)
        *outItemTimeForDisplay = itemTime;
    return pb;
}

@end

#pragma mark - Players

@interface AVFTimeObserver : NSObject {
@public
    CMTime interval;
    NSArray<NSValue *> *times;
    dispatch_queue_t queue;
    void (^periodic)(CMTime);
    void (^boundary)(void);
    double lastFired;
}
@end
@implementation AVFTimeObserver
@end

@implementation AVPlayer {
@protected
    AVPlayerItem *_fitem;
    float _frate, _fvolume, _fdefaultRate;
    BOOL _fmuted, _fwaits, _fprevents;
    AVPlayerStatus _fstatus;
    AVPlayerTimeControlStatus _fcontrol;
    AVPlayerActionAtItemEnd _faction;
    NSMutableArray<AVFTimeObserver *> *_fobservers;
    NSTimer *_ftimer;
    CMTime _fanchorTime;   /* item time when the clock started */
    double _fanchorHost;   /* host seconds then */
}

+ (instancetype)playerWithURL:(NSURL *)URL { return [[self alloc] initWithURL:URL]; }
+ (instancetype)playerWithPlayerItem:(AVPlayerItem *)item { return [[self alloc] initWithPlayerItem:item]; }
- (instancetype)init { return [self initWithPlayerItem:nil]; }
- (instancetype)initWithURL:(NSURL *)URL { return [self initWithPlayerItem:[AVPlayerItem playerItemWithURL:URL]]; }

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
{
    if ((self = [super init])) {
        _fvolume = 1;
        _fdefaultRate = 1;
        _fwaits = YES;
        _faction = AVPlayerActionAtItemEndPause;
        _fobservers = [NSMutableArray array];
        [self _finchSetItem:item];
    }
    return self;
}

- (void)dealloc { [_ftimer invalidate]; }

static double
host_seconds(void)
{
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

- (void)_finchSetItem:(AVPlayerItem *)item
{
    [self willChangeValueForKey:@"currentItem"];
    _fitem = item;
    [self didChangeValueForKey:@"currentItem"];
    [item _finchAttachPlayer:self];
    if (item && item.status != AVPlayerItemStatusUnknown)
        [self _finchItemLoaded:item];
}

- (void)_finchItemLoaded:(AVPlayerItem *)item
{
    if (item != _fitem)
        return;
    if (_fstatus == AVPlayerStatusUnknown) {
        [self willChangeValueForKey:@"status"];
        _fstatus = AVPlayerStatusReadyToPlay;
        [self didChangeValueForKey:@"status"];
    }
    if (_frate > 0 && item.status == AVPlayerItemStatusReadyToPlay)
        [self _finchStartClock];
}

- (AVPlayerStatus)status { return _fstatus; }
- (NSError *)error { return nil; }
- (AVPlayerItem *)currentItem { return _fitem; }
- (float)rate { return _frate; }
- (float)defaultRate { return _fdefaultRate; }
- (void)setDefaultRate:(float)r { _fdefaultRate = r; }
- (float)volume { return _fvolume; }
- (void)setVolume:(float)v { _fvolume = v; }
- (BOOL)isMuted { return _fmuted; }
- (void)setMuted:(BOOL)m { _fmuted = m; }
- (AVPlayerTimeControlStatus)timeControlStatus { return _fcontrol; }
- (AVPlayerWaitingReason)reasonForWaitingToPlay
{
    return _fcontrol == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate ? AVPlayerWaitingToMinimizeStallsReason : nil;
}
- (AVPlayerActionAtItemEnd)actionAtItemEnd { return _faction; }
- (void)setActionAtItemEnd:(AVPlayerActionAtItemEnd)a { _faction = a; }
- (BOOL)automaticallyWaitsToMinimizeStalling { return _fwaits; }
- (void)setAutomaticallyWaitsToMinimizeStalling:(BOOL)w { _fwaits = w; }
- (BOOL)preventsDisplaySleepDuringVideoPlayback { return _fprevents; }
- (void)setPreventsDisplaySleepDuringVideoPlayback:(BOOL)p { _fprevents = p; }
- (BOOL)isExternalPlaybackActive { return NO; }
- (BOOL)allowsExternalPlayback { return NO; }
- (void)setAllowsExternalPlayback:(BOOL)a {}
- (NSString *)audioOutputDeviceUniqueID { return nil; }
- (void)setAudioOutputDeviceUniqueID:(NSString *)uid {}
- (BOOL)appliesMediaSelectionCriteriaAutomatically { return YES; }
- (void)setAppliesMediaSelectionCriteriaAutomatically:(BOOL)flag {}
+ (BOOL)eligibleForHDRPlayback { return NO; }

- (void)_finchSetControl:(AVPlayerTimeControlStatus)c
{
    if (c == _fcontrol)
        return;
    [self willChangeValueForKey:@"timeControlStatus"];
    [self willChangeValueForKey:@"reasonForWaitingToPlay"];
    _fcontrol = c;
    [self didChangeValueForKey:@"reasonForWaitingToPlay"];
    [self didChangeValueForKey:@"timeControlStatus"];
}

- (CMTime)currentTime
{
    if (!_fitem)
        return kCMTimeZero;
    if (!_ftimer)
        return [_fitem _finchStoredTime];
    double elapsed = (host_seconds() - _fanchorHost) * _frate;
    CMTime t = CMTimeAdd(_fanchorTime, CMTimeMakeWithSeconds(elapsed, 600));
    CMTime d = _fitem.duration;
    if (CMTIME_IS_NUMERIC(d) && CMTimeCompare(t, d) > 0)
        t = d;
    return t;
}

- (void)_finchStartClock
{
    if (_ftimer || !_fitem || _fitem.status != AVPlayerItemStatusReadyToPlay || _frate == 0)
        return;
    CMTime d = _fitem.duration;
    if (_frate > 0 && CMTIME_IS_NUMERIC(d) && CMTimeCompare([_fitem _finchStoredTime], d) >= 0)
        return;
    _fanchorTime = [_fitem _finchStoredTime];
    _fanchorHost = host_seconds();
    __weak AVPlayer *weakSelf = self;
    _ftimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf _finchTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_ftimer forMode:NSRunLoopCommonModes];
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayer *s = weakSelf;
        if (s && s->_frate > 0 && s->_ftimer)
            [s _finchSetControl:AVPlayerTimeControlStatusPlaying];
    });
}

- (void)_finchStopClock
{
    if (!_ftimer)
        return;
    CMTime now = [self currentTime];
    [_ftimer invalidate];
    _ftimer = nil;
    [_fitem _finchSetTime:now];
}

- (void)_finchFireObserversFrom:(double)from to:(double)to
{
    for (AVFTimeObserver *o in [_fobservers copy]) {
        if (o->periodic) {
            double step = CMTimeGetSeconds(o->interval);
            if (step > 0 && to - o->lastFired >= step - 1e-6) {
                o->lastFired = to;
                CMTime t = CMTimeMakeWithSeconds(to, 600);
                void (^b)(CMTime) = o->periodic;
                dispatch_async(o->queue, ^{
                    b(t);
                });
            }
        } else if (o->boundary) {
            for (NSValue *v in o->times) {
                double b = CMTimeGetSeconds(v.CMTimeValue);
                if (b > from && b <= to) {
                    void (^blk)(void) = o->boundary;
                    dispatch_async(o->queue, ^{
                        blk();
                    });
                    break;
                }
            }
        }
    }
}

- (void)_finchTick
{
    double before = CMTimeGetSeconds([_fitem _finchStoredTime]);
    CMTime now = [self currentTime];
    [_fitem _finchSetTime:now];
    double after = CMTimeGetSeconds(now);
    [self _finchFireObserversFrom:before to:after];
    CMTime d = _fitem.duration;
    if (_frate > 0 && CMTIME_IS_NUMERIC(d) && CMTimeCompare(now, d) >= 0)
        [self _finchReachedEnd];
}

- (void)_finchReachedEnd
{
    AVPlayerItem *item = _fitem;
    [_ftimer invalidate];
    _ftimer = nil;
    [item _finchSetTime:item.duration];
    [[NSNotificationCenter defaultCenter] postNotificationName:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [self _finchItemEnded:item];
}

/* What happens at an item's end (AVQueuePlayer advances). */
- (void)_finchItemEnded:(AVPlayerItem *)item
{
    if (_faction == AVPlayerActionAtItemEndPause) {
        [self willChangeValueForKey:@"rate"];
        _frate = 0;
        [self didChangeValueForKey:@"rate"];
        [self _finchSetControl:AVPlayerTimeControlStatusPaused];
    }
}

- (void)setRate:(float)rate
{
    if (rate == _frate)
        return;
    [self _finchStopClock];
    [self willChangeValueForKey:@"rate"];
    _frate = rate;
    [self didChangeValueForKey:@"rate"];
    if (rate == 0) {
        [self _finchSetControl:AVPlayerTimeControlStatusPaused];
        return;
    }
    CMTime d = _fitem.duration;
    if (rate > 0 && CMTIME_IS_NUMERIC(d) && CMTimeCompare([_fitem _finchStoredTime], d) >= 0)
        return;
    [self _finchSetControl:AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate];
    [self _finchStartClock];
}

- (void)play { [self setRate:_fdefaultRate > 0 ? _fdefaultRate : 1]; }
- (void)pause { [self setRate:0]; }
- (void)playImmediatelyAtRate:(float)rate { [self setRate:rate]; }
- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime
{
    if (CMTIME_IS_NUMERIC(itemTime))
        [_fitem _finchSetTime:itemTime];
    [self setRate:rate];
}
- (void)prerollAtRate:(float)rate completionHandler:(void (^)(BOOL))handler
{
    if (handler)
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(YES);
        });
}
- (void)cancelPendingPrerolls {}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item
{
    [self _finchStopClock];
    [self _finchSetItem:item];
    if (_frate > 0)
        [self _finchStartClock];
}

- (void)seekToTime:(CMTime)time { [self seekToTime:time completionHandler:^(BOOL f){}]; }
- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after
{
    [self seekToTime:time toleranceBefore:before toleranceAfter:after completionHandler:^(BOOL f){}];
}
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))handler
{
    [self seekToTime:time toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:handler];
}
- (void)seekToDate:(NSDate *)date {}
- (void)seekToDate:(NSDate *)date completionHandler:(void (^)(BOOL))handler
{
    if (handler)
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(NO);
        });
}

- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after completionHandler:(void (^)(BOOL))handler
{
    BOOL playing = _ftimer != nil;
    [self _finchStopClock];
    CMTime d = _fitem.duration;
    CMTime t = time;
    if (CMTIME_IS_NUMERIC(d) && CMTimeCompare(t, d) > 0)
        t = d;
    if (CMTimeCompare(t, kCMTimeZero) < 0)
        t = kCMTimeZero;
    [_fitem _finchSetTime:t];
    if (playing)
        [self _finchStartClock];
    if (handler) {
        void (^h)(BOOL) = [handler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            h(YES);
        });
    }
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime))block
{
    AVFTimeObserver *o = [AVFTimeObserver new];
    o->interval = interval;
    o->queue = queue ?: dispatch_get_main_queue();
    o->periodic = [block copy];
    o->lastFired = CMTimeGetSeconds([self currentTime]);
    [_fobservers addObject:o];
    CMTime now = [self currentTime];
    void (^b)(CMTime) = o->periodic;
    dispatch_async(o->queue, ^{
        b(now);
    });
    return o;
}

- (id)addBoundaryTimeObserverForTimes:(NSArray<NSValue *> *)times queue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    AVFTimeObserver *o = [AVFTimeObserver new];
    o->times = [times copy];
    o->queue = queue ?: dispatch_get_main_queue();
    o->boundary = [block copy];
    [_fobservers addObject:o];
    return o;
}

- (void)removeTimeObserver:(id)observer { [_fobservers removeObject:observer]; }

@end

@implementation AVQueuePlayer {
    NSMutableArray<AVPlayerItem *> *_fitems;
}

+ (instancetype)queuePlayerWithItems:(NSArray<AVPlayerItem *> *)items { return [[self alloc] initWithItems:items]; }

- (instancetype)initWithItems:(NSArray<AVPlayerItem *> *)items
{
    if ((self = [super initWithPlayerItem:items.firstObject])) {
        _fitems = [items mutableCopy] ?: [NSMutableArray array];
        _faction = AVPlayerActionAtItemEndAdvance;
    }
    return self;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
{
    if ((self = [super initWithPlayerItem:item])) {
        _fitems = item ? [NSMutableArray arrayWithObject:item] : [NSMutableArray array];
        _faction = AVPlayerActionAtItemEndAdvance;
    }
    return self;
}

- (NSArray<AVPlayerItem *> *)items { return [_fitems copy]; }

- (void)advanceToNextItem
{
    if (_fitems.count)
        [_fitems removeObjectAtIndex:0];
    [self replaceCurrentItemWithPlayerItem:_fitems.firstObject];
}

- (BOOL)canInsertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem
{
    return item && ![_fitems containsObject:item];
}

- (void)insertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem
{
    if (![self canInsertItem:item afterItem:afterItem])
        return;
    NSUInteger i = afterItem ? [_fitems indexOfObject:afterItem] : NSNotFound;
    if (i == NSNotFound)
        [_fitems addObject:item];
    else
        [_fitems insertObject:item atIndex:i + 1];
    if (!_fitem)
        [self replaceCurrentItemWithPlayerItem:item];
}

- (void)removeItem:(AVPlayerItem *)item
{
    BOOL current = item == _fitem;
    [_fitems removeObject:item];
    if (current)
        [self replaceCurrentItemWithPlayerItem:_fitems.firstObject];
}

- (void)removeAllItems
{
    [_fitems removeAllObjects];
    [self replaceCurrentItemWithPlayerItem:nil];
}

- (void)_finchItemEnded:(AVPlayerItem *)item
{
    if (_faction == AVPlayerActionAtItemEndAdvance) {
        [self advanceToNextItem];
        if (!_fitem) {
            [self willChangeValueForKey:@"rate"];
            _frate = 0;
            [self didChangeValueForKey:@"rate"];
            [self _finchSetControl:AVPlayerTimeControlStatusPaused];
        }
        return;
    }
    [super _finchItemEnded:item];
}

@end

@implementation AVPlayerLooper {
    AVQueuePlayer *_fplayer;
    AVPlayerItem *_ftemplate;
    AVPlayerLooperStatus _fstatus;
    NSInteger _floops;
    id _fobserver;
}

+ (instancetype)playerLooperWithPlayer:(AVQueuePlayer *)player templateItem:(AVPlayerItem *)itemToLoop
{
    return [[self alloc] initWithPlayer:player templateItem:itemToLoop timeRange:kCMTimeRangeInvalid];
}

+ (instancetype)playerLooperWithPlayer:(AVQueuePlayer *)player templateItem:(AVPlayerItem *)itemToLoop timeRange:(CMTimeRange)loopRange
{
    return [[self alloc] initWithPlayer:player templateItem:itemToLoop timeRange:loopRange];
}

- (instancetype)initWithPlayer:(AVQueuePlayer *)player templateItem:(AVPlayerItem *)itemToLoop timeRange:(CMTimeRange)loopRange
{
    if ((self = [super init])) {
        _fplayer = player;
        _ftemplate = itemToLoop;
        [player removeAllItems];
        [player insertItem:[itemToLoop copy] afterItem:nil];
        [player insertItem:[itemToLoop copy] afterItem:nil];
        __weak AVPlayerLooper *weakSelf = self;
        _fobserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:nil
                                                                   usingBlock:^(NSNotification *n) {
                                                                       AVPlayerLooper *s = weakSelf;
                                                                       if (!s || ![s->_fplayer.items containsObject:n.object])
                                                                           return;
                                                                       s->_floops++;
                                                                       [s->_fplayer insertItem:[s->_ftemplate copy] afterItem:nil];
                                                                   }];
        _fstatus = AVPlayerLooperStatusReady;
    }
    return self;
}

- (instancetype)initWithPlayer:(AVQueuePlayer *)player
                  templateItem:(AVPlayerItem *)itemToLoop
                     timeRange:(CMTimeRange)loopRange
            existingItemsOrdering:(AVPlayerLooperItemOrdering)itemOrdering
{
    return [self initWithPlayer:player templateItem:itemToLoop timeRange:loopRange];
}

- (void)dealloc
{
    if (_fobserver)
        [[NSNotificationCenter defaultCenter] removeObserver:_fobserver];
}

- (AVPlayerLooperStatus)status { return _fstatus; }
- (NSError *)error { return nil; }
- (NSInteger)loopCount { return _floops; }
- (NSArray<AVPlayerItem *> *)loopingPlayerItems { return _fplayer.items; }
- (void)disableLooping
{
    [[NSNotificationCenter defaultCenter] removeObserver:_fobserver];
    _fobserver = nil;
}

@end

#pragma mark - The layer

@implementation AVPlayerLayer {
    AVPlayer *_fplayer;
    AVLayerVideoGravity _fgravity;
    BOOL _fready;
    NSTimer *_ftimer;
    size_t _fshown;
    BOOL _fshownAny;
    NSDictionary *_fattributes;
}

+ (AVPlayerLayer *)playerLayerWithPlayer:(AVPlayer *)player
{
    AVPlayerLayer *l = [self layer];
    l.player = player;
    return l;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _fgravity = AVLayerVideoGravityResizeAspect;
        self.contentsGravity = kCAGravityResizeAspect;
    }
    return self;
}

- (instancetype)initWithLayer:(id)layer
{
    if ((self = [super initWithLayer:layer])) {
        AVPlayerLayer *o = layer;
        _fgravity = [layer isKindOfClass:[AVPlayerLayer class]] ? o->_fgravity : AVLayerVideoGravityResizeAspect;
    }
    return self;
}

- (void)dealloc { [_ftimer invalidate]; }

- (AVPlayer *)player { return _fplayer; }

- (void)setPlayer:(AVPlayer *)player
{
    _fplayer = player;
    [_ftimer invalidate];
    _ftimer = nil;
    if (player) {
        __weak AVPlayerLayer *weakSelf = self;
        _ftimer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
            [weakSelf _finchShowFrame];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_ftimer forMode:NSRunLoopCommonModes];
    }
}

- (AVLayerVideoGravity)videoGravity { return _fgravity; }

- (void)setVideoGravity:(AVLayerVideoGravity)gravity
{
    _fgravity = [gravity copy];
    self.contentsGravity = [gravity isEqualToString:AVLayerVideoGravityResize]           ? kCAGravityResize
                           : [gravity isEqualToString:AVLayerVideoGravityResizeAspectFill] ? kCAGravityResizeAspectFill
                                                                                         : kCAGravityResizeAspect;
}

- (BOOL)isReadyForDisplay { return _fready; }
- (NSDictionary *)pixelBufferAttributes { return _fattributes; }
- (void)setPixelBufferAttributes:(NSDictionary *)attributes { _fattributes = [attributes copy]; }

- (CGRect)videoRect
{
    CGSize p = _fplayer.currentItem.presentationSize;
    CGRect b = self.bounds;
    if (p.width <= 0 || p.height <= 0 || CGRectIsEmpty(b))
        return CGRectZero;
    if ([_fgravity isEqualToString:AVLayerVideoGravityResize])
        return b;
    if ([_fgravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        double scale = MAX(b.size.width / p.width, b.size.height / p.height);
        CGSize s = CGSizeMake(p.width * scale, p.height * scale);
        return CGRectMake(CGRectGetMidX(b) - s.width / 2, CGRectGetMidY(b) - s.height / 2, s.width, s.height);
    }
    return AVMakeRectWithAspectRatioInsideRect(p, b);
}

- (void)_finchShowFrame
{
    AVPlayerItem *item = _fplayer.currentItem;
    if (!item || item.status != AVPlayerItemStatusReadyToPlay || !self.superlayer)
        return;
    size_t index = 0;
    CGImageRef im = [item _finchCopyImageAtTime:item.currentTime sampleIndex:&index];
    if (!im)
        return;
    if (!_fshownAny || index != _fshown) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.contents = (__bridge id)im;
        [CATransaction commit];
        _fshown = index;
        _fshownAny = YES;
        if (!_fready) {
            [self willChangeValueForKey:@"readyForDisplay"];
            _fready = YES;
            [self didChangeValueForKey:@"readyForDisplay"];
        }
    }
    CGImageRelease(im);
}

- (CVPixelBufferRef)copyDisplayedPixelBuffer { return NULL; }
- (void)setCaptionPreviewProfileID:(NSString *)profileID position:(CGPoint)position text:(NSString *)text {}
- (void)stopShowingCaptionPreview {}

@end

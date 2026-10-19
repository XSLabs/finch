/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A CoreMedia timebase with renderer and time-observer management. */
#import "AVFInternal.h"
#import <objc/message.h>

@interface AVFRenderTimeObserver : NSObject
@property dispatch_queue_t queue;
@property (copy) void (^periodicBlock)(CMTime time);
@property (copy) void (^boundaryBlock)(void);
@property CMTime interval;
@property CMTime lastTime;
@property NSArray<NSValue *> *times;
@property NSUInteger nextTimeIndex;
@end

@implementation AVFRenderTimeObserver
@end

@interface AVFRendererRemoval : NSObject
@property (strong) id<AVQueuedSampleBufferRendering> renderer;
@property CMTime time;
@property (copy) void (^completion)(BOOL didRemoveRenderer);
@end

@implementation AVFRendererRemoval
@end

@implementation AVSampleBufferRenderSynchronizer {
    CMTimebaseRef _finchTimebase;
    dispatch_queue_t _finchQueue;
    dispatch_source_t _finchTimer;
    NSMutableArray<id<AVQueuedSampleBufferRendering>> *_finchRenderers;
    NSMutableArray<AVFRenderTimeObserver *> *_finchObservers;
    NSMutableArray<AVFRendererRemoval *> *_finchRemovals;
    BOOL _finchDelaysRateChange;
}

- (instancetype)init
{
    if ((self = [super init])) {
        OSStatus status = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_finchTimebase);
        if (status != noErr) {
            self = nil;
            return nil;
        }
        _finchQueue = dispatch_queue_create("com.apple.avfoundation.render-synchronizer", DISPATCH_QUEUE_SERIAL);
        _finchRenderers = [NSMutableArray array];
        _finchObservers = [NSMutableArray array];
        _finchRemovals = [NSMutableArray array];
        _finchDelaysRateChange = YES;
    }
    return self;
}

- (void)dealloc
{
    if (_finchTimer)
        dispatch_source_cancel(_finchTimer);
    if (_finchTimebase)
        CFRelease(_finchTimebase);
}

- (CMTimebaseRef)timebase { return _finchTimebase; }
- (CMTime)currentTime { return CMTimebaseGetTime(_finchTimebase); }
- (float)rate { return (float)CMTimebaseGetRate(_finchTimebase); }

- (void)setRate:(float)rate
{
    if (rate < 0)
        [NSException raise:NSInvalidArgumentException format:@"rate must be greater than or equal to zero"];
    CMTimebaseSetRate(_finchTimebase, rate);
}

- (void)setRate:(float)rate time:(CMTime)time
{
    [self setRate:rate time:time atHostTime:CMClockGetTime(CMClockGetHostTimeClock())];
}

- (void)setRate:(float)rate time:(CMTime)time atHostTime:(CMTime)hostTime
{
    if (rate < 0 || (CMTIME_IS_NUMERIC(time) && CMTimeCompare(time, kCMTimeZero) < 0) ||
        (CMTIME_IS_NUMERIC(hostTime) && CMTimeCompare(hostTime, kCMTimeZero) < 0))
        [NSException raise:NSInvalidArgumentException format:@"rate, time, or host time is out of range"];
    if (!CMTIME_IS_NUMERIC(hostTime))
        hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTimebaseSetRateAndAnchorTime(_finchTimebase, rate, time, hostTime);
}

- (BOOL)delaysRateChangeUntilHasSufficientMediaData { return _finchDelaysRateChange; }
- (void)setDelaysRateChangeUntilHasSufficientMediaData:(BOOL)delays { _finchDelaysRateChange = delays; }

- (NSArray<id<AVQueuedSampleBufferRendering>> *)renderers
{
    @synchronized (_finchRenderers) {
        return [_finchRenderers copy];
    }
}

- (void)addRenderer:(id<AVQueuedSampleBufferRendering>)renderer
{
    if (!renderer || ![renderer conformsToProtocol:@protocol(AVQueuedSampleBufferRendering)])
        [NSException raise:NSInvalidArgumentException format:@"renderer must implement AVQueuedSampleBufferRendering"];
    @synchronized (_finchRenderers) {
        if ([_finchRenderers containsObject:renderer])
            return;
        [_finchRenderers addObject:renderer];
    }
    SEL selector = NSSelectorFromString(@"_finchSetRenderSynchronizer:");
    if ([renderer respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(renderer, selector, self);
}

- (void)removeRenderer:(id<AVQueuedSampleBufferRendering>)renderer atTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler
{
    if (!renderer)
        [NSException raise:NSInvalidArgumentException format:@"renderer must not be nil"];
    @synchronized (_finchRenderers) {
        if (![_finchRenderers containsObject:renderer]) {
            if (completionHandler)
                dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(NO); });
            return;
        }
    }
    AVFRendererRemoval *removal = [[AVFRendererRemoval alloc] init];
    removal.renderer = renderer;
    removal.time = time;
    removal.completion = completionHandler;
    dispatch_async(_finchQueue, ^{
        for (AVFRendererRemoval *old in [self->_finchRemovals copy]) {
            if (old.renderer == renderer) {
                [self->_finchRemovals removeObject:old];
                if (old.completion)
                    dispatch_async(dispatch_get_main_queue(), ^{ old.completion(NO); });
            }
        }
        [self->_finchRemovals addObject:removal];
        [self _finchStartTimer];
    });
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime))block
{
    if (!CMTIME_IS_NUMERIC(interval) || CMTimeCompare(interval, kCMTimeZero) <= 0 || !block)
        [NSException raise:NSInvalidArgumentException format:@"interval and block must be valid"];
    AVFRenderTimeObserver *observer = [[AVFRenderTimeObserver alloc] init];
    observer.queue = queue ?: dispatch_get_main_queue();
    observer.periodicBlock = block;
    observer.interval = interval;
    observer.lastTime = self.currentTime;
    dispatch_async(_finchQueue, ^{
        [self->_finchObservers addObject:observer];
        [self _finchStartTimer];
    });
    return observer;
}

- (id)addBoundaryTimeObserverForTimes:(NSArray<NSValue *> *)times queue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    if (!times || !block)
        [NSException raise:NSInvalidArgumentException format:@"times and block must not be nil"];
    NSMutableArray<NSValue *> *validTimes = [NSMutableArray array];
    for (NSValue *value in times) {
        CMTime time = value.CMTimeValue;
        if (!CMTIME_IS_NUMERIC(time) || CMTimeCompare(time, kCMTimeZero) < 0)
            [NSException raise:NSInvalidArgumentException format:@"each boundary time must be nonnegative and numeric"];
        [validTimes addObject:value];
    }
    [validTimes sortUsingComparator:^NSComparisonResult(NSValue *left, NSValue *right) {
        return CMTimeCompare(left.CMTimeValue, right.CMTimeValue);
    }];
    AVFRenderTimeObserver *observer = [[AVFRenderTimeObserver alloc] init];
    observer.queue = queue ?: dispatch_get_main_queue();
    observer.boundaryBlock = block;
    observer.times = [validTimes copy];
    dispatch_async(_finchQueue, ^{
        [self->_finchObservers addObject:observer];
        [self _finchStartTimer];
    });
    return observer;
}

- (void)removeTimeObserver:(id)observer
{
    dispatch_sync(_finchQueue, ^{
        AVFRenderTimeObserver *found = nil;
        for (AVFRenderTimeObserver *candidate in self->_finchObservers)
            if (candidate == observer) { found = candidate; break; }
        if (!found)
            [NSException raise:NSInvalidArgumentException format:@"observer was not created by this synchronizer"];
        [self->_finchObservers removeObject:found];
        [self _finchStopTimerIfIdle];
    });
}

- (void)_finchStartTimer
{
    if (_finchTimer)
        return;
    _finchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _finchQueue);
    dispatch_source_set_timer(_finchTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak AVSampleBufferRenderSynchronizer *weakSelf = self;
    dispatch_source_set_event_handler(_finchTimer, ^{ [weakSelf _finchTick]; });
    dispatch_resume(_finchTimer);
}

- (void)_finchStopTimerIfIdle
{
    if (_finchObservers.count || _finchRemovals.count || !_finchTimer)
        return;
    dispatch_source_cancel(_finchTimer);
    _finchTimer = nil;
}

- (void)_finchTick
{
    CMTime now = self.currentTime;
    for (AVFRenderTimeObserver *observer in [_finchObservers copy]) {
        if (observer.periodicBlock) {
            CMTime elapsed = CMTimeSubtract(now, observer.lastTime);
            if (CMTIME_IS_NUMERIC(elapsed) && CMTimeCompare(elapsed, observer.interval) >= 0) {
                observer.lastTime = now;
                void (^callback)(CMTime) = observer.periodicBlock;
                dispatch_async(observer.queue, ^{ callback(now); });
            }
        } else {
            while (observer.nextTimeIndex < observer.times.count &&
                   CMTimeCompare(now, observer.times[observer.nextTimeIndex].CMTimeValue) >= 0) {
                observer.nextTimeIndex++;
                void (^callback)(void) = observer.boundaryBlock;
                dispatch_async(observer.queue, callback);
            }
            if (observer.nextTimeIndex >= observer.times.count)
                [_finchObservers removeObject:observer];
        }
    }
    for (AVFRendererRemoval *removal in [_finchRemovals copy]) {
        if (!CMTIME_IS_NUMERIC(removal.time) || CMTimeCompare(now, removal.time) >= 0) {
            [_finchRemovals removeObject:removal];
            @synchronized (_finchRenderers) { [_finchRenderers removeObject:removal.renderer]; }
            SEL selector = NSSelectorFromString(@"_finchSetRenderSynchronizer:");
            if ([removal.renderer respondsToSelector:selector])
                ((void (*)(id, SEL, id))objc_msgSend)(removal.renderer, selector, nil);
            if (removal.completion)
                dispatch_async(dispatch_get_main_queue(), ^{ removal.completion(YES); });
        }
    }
    [self _finchStopTimerIfIdle];
}

@end

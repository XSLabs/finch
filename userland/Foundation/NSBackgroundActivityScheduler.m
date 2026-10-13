/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSBackgroundActivityScheduler: runs a block when its interval has passed (within its
 * tolerance), again and again if it repeats. Apple's asks the Duet activity scheduler
 * when the machine is idle enough; Finch's has no one to ask, so it runs on time, at
 * the activity's quality of service, and -shouldDefer says NO. As Apple's, -shouldDefer
 * raises outside the activity's block.
 */
#import <Foundation/Foundation.h>

static __thread NSBackgroundActivityScheduler *running;

@implementation NSBackgroundActivityScheduler {
    NSString *_identifier;
    NSQualityOfService _qos;
    BOOL _repeats;
    NSTimeInterval _interval, _tolerance;
    dispatch_source_t _timer;
    void (^_block)(NSBackgroundActivityCompletionHandler);
}

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _qos = NSQualityOfServiceBackground;
    }
    return self;
}

- (void)dealloc
{
    [self invalidate];
    [_identifier release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }
- (NSQualityOfService)qualityOfService { return _qos; }
- (void)setQualityOfService:(NSQualityOfService)q { _qos = q; }
- (BOOL)repeats { return _repeats; }
- (void)setRepeats:(BOOL)r { _repeats = r; }
- (NSTimeInterval)interval { return _interval; }
- (void)setInterval:(NSTimeInterval)i { _interval = i; }
- (NSTimeInterval)tolerance { return _tolerance; }
- (void)setTolerance:(NSTimeInterval)t { _tolerance = t; }

- (BOOL)shouldDefer
{
    if (running != self)
        [NSException raise:NSRangeException format:@"*** -[NSBackgroundActivityScheduler shouldDefer]: This method may only be called during the invocation of the activity block or asynchronous activity"];
    return NO;
}

- (void)arm:(NSTimeInterval)delay
{
    @synchronized(self) {
        if (!_block)
            return;
        if (!_timer) {
            dispatch_queue_t q = dispatch_get_global_queue((dispatch_qos_class_t)_qos, 0);
            _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_event_handler(_timer, ^{ [self fire]; });
            dispatch_resume(_timer);
        }
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER,
                                  (uint64_t)(_tolerance * NSEC_PER_SEC));
    }
}

- (void)fire
{
    void (^block)(NSBackgroundActivityCompletionHandler);
    @synchronized(self) {
        block = [[_block retain] autorelease];
    }
    if (!block)
        return;
    [self retain];
    running = self;
    block(^(NSBackgroundActivityResult result) {
        if (result == NSBackgroundActivityResultDeferred)
            [self arm:MAX(_tolerance, 60)];
        else if (_repeats)
            [self arm:_interval];
        [self release];
    });
    running = nil;
}

- (void)scheduleWithBlock:(void (^)(NSBackgroundActivityCompletionHandler))block
{
    @synchronized(self) {
        [_block release];
        _block = [block copy];
    }
    [self arm:_interval];
}

- (void)invalidate
{
    @synchronized(self) {
        if (_timer) {
            dispatch_source_cancel(_timer);
            dispatch_release(_timer);
            _timer = NULL;
        }
        [_block release];
        _block = nil;
    }
}

@end

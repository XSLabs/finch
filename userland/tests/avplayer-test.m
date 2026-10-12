/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVPlayer, AVPlayerItem, AVPlayerItemVideoOutput and AVPlayerLayer over a movie the
 * test writes itself (six JPEG frames at 6 fps, red and blue in turn, and a second of
 * PCM): the item's status and properties once loaded, playing (rate, control status,
 * the end notification and where it stops), seeking with completions, time observers,
 * frames from the video output, a queue player, and a layer's defaults. Times that
 * depend on the clock are printed coarsely. Compared with Apple's.
 */
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include "avmovie.h"
#include "avframes.h"

static void
pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void
wait_until(BOOL (^cond)(void), double seconds)
{
    for (int i = 0; i < seconds * 100 && !cond(); i++)
        pump(0.01);
}

static NSString *
time_string(CMTime t)
{
    if (CMTIME_IS_INVALID(t))
        return @"invalid";
    if (CMTIME_IS_INDEFINITE(t))
        return @"indefinite";
    return [NSString stringWithFormat:@"%lld/%d", t.value, t.timescale];
}

static NSString *
colour(CVPixelBufferRef pb)
{
    if (!pb)
        return @"none";
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *p = (const uint8_t *)CVPixelBufferGetBaseAddress(pb) + 24 * CVPixelBufferGetBytesPerRow(pb) + 32 * 4;
    NSString *c = p[2] > p[0] ? @"red" : @"blue";
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return c;
}

@interface Watcher : NSObject
@property NSMutableArray *events;
@end

@implementation Watcher
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    @synchronized(self.events) {
        [self.events addObject:[NSString stringWithFormat:@"%@ %@ = %@", NSStringFromClass([object class]), keyPath, [object valueForKey:keyPath]]];
    }
}
@end

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avplayer-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        Watcher *w = [Watcher new];
        w.events = [NSMutableArray array];
        [item addObserver:w forKeyPath:@"status" options:0 context:NULL];
        printf("item before: status %ld duration %s presentation %s time %s\n", (long)item.status, time_string(item.duration).UTF8String,
            NSStringFromSize(item.presentationSize).UTF8String, time_string(item.currentTime).UTF8String);
        AVPlayer *p = [AVPlayer playerWithPlayerItem:item];
        [p addObserver:w forKeyPath:@"timeControlStatus" options:0 context:NULL];
        printf("player: status %ld rate %.1f control %ld action at end %ld volume %.1f muted %d waits %d default rate %.1f\n",
            (long)p.status, p.rate, (long)p.timeControlStatus, (long)p.actionAtItemEnd, p.volume, p.muted,
            p.automaticallyWaitsToMinimizeStalling, p.defaultRate);
        AVPlayerItemVideoOutput *out = [[AVPlayerItemVideoOutput alloc]
            initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
        [item addOutput:out];
        wait_until(^{
            return (BOOL)(item.status != AVPlayerItemStatusUnknown);
        }, 5);
        printf("item ready: status %ld duration %s presentation %s tracks %lu outputs %lu\n", (long)item.status,
            time_string(item.duration).UTF8String, NSStringFromSize(item.presentationSize).UTF8String, (unsigned long)item.tracks.count,
            (unsigned long)item.outputs.count);
        printf("  can fast forward %d reverse %d step forward %d backward %d\n", item.canPlayFastForward, item.canPlayReverse,
            item.canStepForward, item.canStepBackward);
        AVPlayerItemTrack *it = item.tracks.firstObject;
        printf("  item track: enabled %d type %s\n", it.enabled, it.assetTrack.mediaType.UTF8String);
        printf("  seekable %lu loaded %lu, player status %ld\n", (unsigned long)item.seekableTimeRanges.count,
            (unsigned long)item.loadedTimeRanges.count, (long)p.status);

        /* (a video output has frames once the item's time has moved: checked after seeking) */
        /* seeking */
        __block BOOL finished = NO, called = NO;
        [p seekToTime:CMTimeMake(300, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL f) {
            finished = f;
            called = YES;
        }];
        wait_until(^{
            return called;
        }, 5);
        printf("seek: finished %d time %s item %s\n", finished, time_string(p.currentTime).UTF8String,
            time_string(item.currentTime).UTF8String);
        pump(0.3);
        CVPixelBufferRef pb = NULL;
        for (int k = 0; k < 100 && !pb; k++) {
            if ([out hasNewPixelBufferForItemTime:item.currentTime])
                pb = [out copyPixelBufferForItemTime:item.currentTime itemTimeForDisplay:NULL];
            else
                pump(0.01);
        }
        printf("  output after the seek: %zux%zu %s\n", pb ? CVPixelBufferGetWidth(pb) : 0, pb ? CVPixelBufferGetHeight(pb) : 0,
            colour(pb).UTF8String);
        CVPixelBufferRelease(pb);
        [p seekToTime:kCMTimeZero];
        pump(0.2);
        printf("seek to zero: %s\n", time_string(p.currentTime).UTF8String);

        /* playing to the end */
        __block int periodic = 0, boundary = 0, ended = 0;
        id po = [p addPeriodicTimeObserverForInterval:CMTimeMake(1, 4) queue:dispatch_get_main_queue() usingBlock:^(CMTime t) {
            periodic++;
        }];
        id bo = [p addBoundaryTimeObserverForTimes:@[ [NSValue valueWithCMTime:CMTimeMake(1, 2)] ] queue:dispatch_get_main_queue() usingBlock:^{
            boundary++;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:nil
                                                      usingBlock:^(NSNotification *n) {
                                                          ended++;
                                                      }];
        [p play];
        pump(0.1);
        printf("playing: rate %.1f control %ld\n", p.rate, (long)p.timeControlStatus);
        pump(0.4);
        double mid = CMTimeGetSeconds(p.currentTime);
        printf("  after 0.5 s: between 0.3 and 0.7 %d\n", mid > 0.3 && mid < 0.7);
        wait_until(^{
            return (BOOL)(ended > 0);
        }, 3);
        pump(0.2);
        printf("ended: notifications %d rate %.1f control %ld time %s boundary %d periodic at least 4 %d\n", ended, p.rate,
            (long)p.timeControlStatus, time_string(p.currentTime).UTF8String, boundary, periodic >= 4);
        [p removeTimeObserver:po];
        [p removeTimeObserver:bo];
        [p pause];
        p.rate = 2;
        printf("rate 2 at end: rate %.1f\n", p.rate);
        p.rate = 0;

        /* queue player */
        AVQueuePlayer *q = [AVQueuePlayer queuePlayerWithItems:@[ [AVPlayerItem playerItemWithURL:url], [AVPlayerItem playerItemWithURL:url] ]];
        printf("queue: items %lu, current is first %d\n", (unsigned long)q.items.count, q.currentItem == q.items.firstObject);
        [q advanceToNextItem];
        printf("  advanced: items %lu\n", (unsigned long)q.items.count);
        [q removeAllItems];
        printf("  removed: items %lu current %p\n", (unsigned long)q.items.count, q.currentItem);

        /* the layer */
        AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:p];
        printf("layer: gravity %s player %d ready %d rect %s\n", layer.videoGravity.UTF8String, layer.player == p,
            layer.readyForDisplay, NSStringFromRect(layer.videoRect).UTF8String);
        layer.frame = CGRectMake(0, 0, 200, 100);
        printf("  in 200x100: rect %s\n", NSStringFromRect(layer.videoRect).UTF8String);

        /* a missing file */
        AVPlayerItem *bad = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:@"/nonexistent.mov"]];
        AVPlayer *bp = [AVPlayer playerWithPlayerItem:bad];
        wait_until(^{
            return (BOOL)(bad.status != AVPlayerItemStatusUnknown);
        }, 5);
        printf("missing: item status %ld error %s %ld player status %ld\n", (long)bad.status, bad.error.domain.UTF8String,
            (long)bad.error.code, (long)bp.status);

        [item removeObserver:w forKeyPath:@"status"];
        [p removeObserver:w forKeyPath:@"timeControlStatus"];
        NSMutableArray *seen = [NSMutableArray array];
        for (NSString *e in w.events)
            if (![seen containsObject:e])
                [seen addObject:e];
        printf("observed: %s\n", [seen componentsJoinedByString:@"; "].UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

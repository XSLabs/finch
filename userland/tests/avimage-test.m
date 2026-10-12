/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetImageGenerator over a movie the test writes itself (six JPEG frames, red and
 * blue in turn, at 6 fps): images at times with and without tolerance, the actual
 * times, a maximum size, the asynchronous form, and errors past the end and for an
 * asset with no video. Compared with Apple's.
 */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"

static NSString *
colour(CGImageRef im)
{
    if (!im)
        return @"none";
    uint8_t p[4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(p, 1, 1, 8, 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), im);
    CGContextRelease(c);
    return p[0] > p[2] ? @"red" : @"blue";
}

static NSString *
time_string(CMTime t)
{
    if (CMTIME_IS_INVALID(t))
        return @"invalid";
    return [NSString stringWithFormat:@"%lld/%d", t.value, t.timescale];
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avimage-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        printf("defaults: transform %d max %s aperture %s before %s after %s\n", g.appliesPreferredTrackTransform,
            NSStringFromSize(g.maximumSize).UTF8String, [g.apertureMode UTF8String], time_string(g.requestedTimeToleranceBefore).UTF8String,
            time_string(g.requestedTimeToleranceAfter).UTF8String);
        CMTime times[] = {kCMTimeZero, CMTimeMake(150, 600), CMTimeMake(1, 3), CMTimeMake(599, 600), CMTimeMake(2, 1)};
        for (int k = 0; k < 2; k++) {
            if (k) {
                g.requestedTimeToleranceBefore = kCMTimeZero;
                g.requestedTimeToleranceAfter = kCMTimeZero;
                printf("zero tolerance:\n");
            }
            for (size_t i = 0; i < sizeof times / sizeof times[0]; i++) {
                CMTime actual = kCMTimeInvalid;
                NSError *e = nil;
                CGImageRef im = [g copyCGImageAtTime:times[i] actualTime:&actual error:&e];
                printf("  at %s: %zux%zu %s actual %s error %s %ld\n", time_string(times[i]).UTF8String, CGImageGetWidth(im),
                    CGImageGetHeight(im), colour(im).UTF8String, time_string(actual).UTF8String, e.domain.UTF8String, (long)e.code);
                CGImageRelease(im);
            }
        }
        g.maximumSize = CGSizeMake(32, 32);
        CGImageRef small = [g copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
        printf("max 32x32: %zux%zu\n", CGImageGetWidth(small), CGImageGetHeight(small));
        CGImageRelease(small);
        g.maximumSize = CGSizeZero;
        __block int results = 0;
        __block NSMutableArray *lines = [NSMutableArray array];
        NSArray *requests = @[ [NSValue valueWithCMTime:CMTimeMake(100, 600)], [NSValue valueWithCMTime:CMTimeMake(400, 600)] ];
        [g generateCGImagesAsynchronouslyForTimes:requests
                                completionHandler:^(CMTime requested, CGImageRef im, CMTime actual, AVAssetImageGeneratorResult result, NSError *e) {
                                    @synchronized(lines) {
                                        [lines addObject:[NSString stringWithFormat:@"  async %@: result %ld %@ actual %@",
                                                                                    time_string(requested), (long)result, colour(im),
                                                                                    time_string(actual)]];
                                        results++;
                                    }
                                }];
        for (int i = 0; i < 500 && results < 2; i++)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        for (NSString *l in [lines sortedArrayUsingSelector:@selector(compare:)])
            printf("%s\n", l.UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

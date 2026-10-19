/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare real asset insertion and timeline edits using the same small movie on both systems. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "avmovie.h"

static NSData *
frame(void)
{
    uint8_t bytes[16] = {0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xFF, 0xD9};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *
time_text(CMTime time)
{
    if (CMTIME_IS_NUMERIC(time))
        time = CMTimeConvertScale(time, 600, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    return [NSString stringWithFormat:@"%lld/%d", time.value, time.timescale];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avcomposition-%d.mov", getpid()]];
        [build_movie_with_frames(@[frame(), frame(), frame(), frame(), frame(), frame()]) writeToFile:path atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
        AVMutableComposition *composition = [AVMutableComposition composition];
        NSError *error = nil;
        BOOL inserted = [composition insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration)
                                             ofAsset:asset atTime:CMTimeMake(1, 1) error:&error];
        CGSize size = composition.naturalSize;
        printf("insert %d error %ld duration %s tracks %lu size %.0fx%.0f\n", inserted, (long)error.code,
               time_text(composition.duration).UTF8String, (unsigned long)composition.tracks.count, size.width, size.height);
        for (AVCompositionTrack *track in composition.tracks) {
            AVCompositionTrackSegment *first = track.segments.firstObject;
            AVCompositionTrackSegment *last = track.segments.lastObject;
            printf("track %d %s range %s segments %lu endpoints %d/%d\n", track.trackID, track.mediaType.UTF8String,
                   time_text(track.timeRange.duration).UTF8String, (unsigned long)track.segments.count,
                   first.empty, last.empty);
        }
        AVMutableCompositionTrack *video = [composition tracksWithMediaType:AVMediaTypeVideo].firstObject;
        [video scaleTimeRange:CMTimeRangeMake(CMTimeMake(1, 1), CMTimeMake(1, 1)) toDuration:CMTimeMake(2, 1)];
        printf("scale duration %s video %s\n", time_text(composition.duration).UTF8String,
               time_text(video.timeRange.duration).UTF8String);
        [composition removeTimeRange:CMTimeRangeMake(CMTimeMake(1, 2), CMTimeMake(1, 2))];
        printf("remove duration %s video %s segment-count %lu\n", time_text(composition.duration).UTF8String,
               time_text(video.timeRange.duration).UTF8String, (unsigned long)video.segments.count);
        NSError *validation = nil;
        BOOL valid = [video validateTrackSegments:video.segments error:&validation];
        printf("segments valid %d error %ld snapshot %d\n", valid, (long)validation.code,
               [[composition copy] isKindOfClass:[AVComposition class]]);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check the read-only AVMovie view against the same real QuickTime movie on both systems. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
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
        NSData *data = build_movie_with_frames(@[frame(), frame(), frame(), frame(), frame(), frame()]);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avmovie-%d.mov", getpid()]];
        [data writeToFile:path atomically:YES];
        AVMovie *movie = [AVMovie movieWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVMovieTrack *track = movie.tracks.firstObject;
        puts("AVMovie read-only checks");
        printf("movie %d url %d data %d storage %d duration %s tracks %lu fragments %d/%d\n",
               movie != nil, movie.URL.isFileURL, movie.data != nil, movie.defaultMediaDataStorage != nil,
               time_text(movie.duration).UTF8String, (unsigned long)movie.tracks.count,
               movie.canContainMovieFragments, movie.containsMovieFragments);
        printf("track %d lookup %d media %s alternate %ld size %.0fx%.0f decode %s presentation %s\n",
               track.trackID, [movie trackWithTrackID:track.trackID] == track, track.mediaType.UTF8String,
               (long)track.alternateGroupID, track.naturalSize.width, track.naturalSize.height,
               time_text(track.mediaDecodeTimeRange.duration).UTF8String,
               time_text(track.mediaPresentationTimeRange.duration).UTF8String);
        AVMediaDataStorage *storage = [[AVMediaDataStorage alloc] initWithURL:movie.URL options:nil];
        AVMediaDataStorage *emptyStorage = ((id (*)(id, SEL, id, id))objc_msgSend)([AVMediaDataStorage alloc],
            @selector(initWithURL:options:), nil, nil);
        printf("media data storage %d %d %d\n", storage.URL.isFileURL,
               [storage.URL isEqual:movie.URL], emptyStorage.URL == nil);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}

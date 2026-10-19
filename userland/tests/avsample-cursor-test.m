/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare sample cursor timing and storage details on a small QuickTime movie. */
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVSampleCursor.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "avmovie.h"

static NSData *
frame(void)
{
    uint8_t bytes[] = { 0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 0xFF, 0xD9 };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static void
print_time(const char *name, CMTime time)
{
    printf("%s %lld/%d\n", name, time.value, time.timescale);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVSampleCursor class]));
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avsample-cursor-%d.mov", getpid()]];
        [build_movie_with_frames(@[frame(), frame(), frame(), frame(), frame(), frame()]) writeToFile:path atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVSampleCursor *first = [track makeSampleCursorAtFirstSampleInDecodeOrder];
        AVSampleCursor *copy = [first copy];
        CMFormatDescriptionRef format = [first copyCurrentSampleFormatDescription];
        AVSampleCursorSyncInfo sync = first.currentSampleSyncInfo;
        AVSampleCursorChunkInfo chunk = first.currentChunkInfo;
        AVSampleCursorStorageRange current = first.currentSampleStorageRange;
        AVSampleCursorStorageRange chunkRange = first.currentChunkStorageRange;
        printf("initial %d %d %d copy=%d compare=%ld format=%d url=%d\n",
            track.canProvideSampleCursors, CMTimeCompare(first.presentationTimeStamp, kCMTimeZero) == 0,
            CMTimeCompare(first.decodeTimeStamp, kCMTimeZero) == 0, copy != first,
            (long)[first comparePositionInDecodeOrderWithPositionOfCursor:copy], format != NULL,
            first.currentChunkStorageURL != nil);
        print_time("duration", first.currentSampleDuration);
        printf("sample %lld/%lld chunk %lld/%lld index=%lld count=%lld uniform=%d/%d/%d sync=%d\n",
            (long long)current.offset, (long long)current.length, (long long)chunkRange.offset, (long long)chunkRange.length,
            (long long)first.currentSampleIndexInChunk, (long long)chunk.chunkSampleCount,
            chunk.chunkHasUniformSampleSizes, chunk.chunkHasUniformSampleDurations,
            chunk.chunkHasUniformFormatDescriptions, sync.sampleIsFullSync);
        printf("step decode %lld\n", (long long)[first stepInDecodeOrderByCount:2]);
        print_time("decode after", first.decodeTimeStamp);
        print_time("presentation after", first.presentationTimeStamp);
        AVSampleCursor *last = [track makeSampleCursorAtLastSampleInDecodeOrder];
        print_time("last", last.presentationTimeStamp);
        BOOL pinned = NO;
        CMTime moved = [copy stepByPresentationTime:CMTimeMake(1, 4) wasPinned:&pinned];
        print_time("time step", moved);
        printf("time position %lld/%d pinned=%d compare=%ld\n", copy.presentationTimeStamp.value,
            copy.presentationTimeStamp.timescale, pinned,
            (long)[copy comparePositionInDecodeOrderWithPositionOfCursor:last]);
        AVSampleCursor *at = [track makeSampleCursorWithPresentationTimeStamp:CMTimeMake(1, 4)];
        print_time("at", at.presentationTimeStamp);
        if (format) CFRelease(format);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}

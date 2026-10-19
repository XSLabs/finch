/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Single-track JPEG composition output uses Finch's real JPEG decoder. */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avvc-reader-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
        AVAssetReaderVideoCompositionOutput *output = [AVAssetReaderVideoCompositionOutput
            assetReaderVideoCompositionOutputWithVideoTracks:@[track] videoSettings:nil];
        output.videoComposition = [AVVideoComposition videoCompositionWithPropertiesOfAsset:asset];
        printf("tracks %lu settings %d canAdd %d ", (unsigned long)output.videoTracks.count, output.videoSettings != nil, [reader canAddOutput:output]);
        [reader addOutput:output];
        printf("start %d\n", [reader startReading]);
        CMSampleBufferRef sample;
        int count = 0;
        while ((sample = [output copyNextSampleBuffer])) {
            CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
            printf("%d pts %.3f image %d %zux%zu format %08x\n", count++,
                   CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                   image != NULL, image ? CVPixelBufferGetWidth(image) : 0, image ? CVPixelBufferGetHeight(image) : 0,
                   image ? (unsigned)CVPixelBufferGetPixelFormatType(image) : 0);
            CFRelease(sample);
        }
        printf("count %d status %ld\n", count, (long)reader.status);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

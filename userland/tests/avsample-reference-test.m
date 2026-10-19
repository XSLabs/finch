/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Sample locations from a movie written by this test. Compared with Apple's reader. */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"

static NSString *
tm(CMTime t)
{
    return CMTIME_IS_VALID(t) ? [NSString stringWithFormat:@"%lld/%d", t.value, t.timescale] : @"invalid";
}

static void
read_track(AVURLAsset *asset, AVAssetTrack *track, const char *name)
{
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    AVAssetReaderSampleReferenceOutput *output = [[AVAssetReaderSampleReferenceOutput alloc] initWithTrack:track];
    BOOL canAdd = [reader canAddOutput:output];
    [reader addOutput:output];
    BOOL started = [reader startReading];
    printf("%s canAdd %d start %d\n", name, canAdd, started);
    int index = 0;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        CFTypeRef url = CMGetAttachment(sample, kCMSampleBufferAttachmentKey_SampleReferenceURL, NULL);
        CFTypeRef offset = CMGetAttachment(sample, kCMSampleBufferAttachmentKey_SampleReferenceByteOffset, NULL);
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
        printf("  %d pts %s dts %s dur %s samples %ld size %zu data %d format %08x url %s offset %s\n", index++,
               tm(CMSampleBufferGetPresentationTimeStamp(sample)).UTF8String,
               tm(CMSampleBufferGetDecodeTimeStamp(sample)).UTF8String,
               tm(CMSampleBufferGetDuration(sample)).UTF8String,
               (long)CMSampleBufferGetNumSamples(sample), CMSampleBufferGetTotalSampleSize(sample),
               CMSampleBufferGetDataBuffer(sample) != NULL,
               format ? (unsigned)CMFormatDescriptionGetMediaSubType(format) : 0,
               url ? [[(__bridge NSURL *)url lastPathComponent] UTF8String] : "nil",
               offset ? [((__bridge NSNumber *)offset).stringValue UTF8String] : "nil");
        CFRelease(sample);
    }
    printf("  count %d status %ld\n", index, (long)reader.status);
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avsample-ref-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        read_track(asset, [asset tracksWithMediaType:AVMediaTypeVideo].firstObject, "video");
        read_track(asset, [asset tracksWithMediaType:AVMediaTypeAudio].firstObject, "audio");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

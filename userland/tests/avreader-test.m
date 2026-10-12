/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetReader over a movie the test writes itself (six JPEG frames, red and blue in
 * turn, and a second of PCM): the video and audio as they are stored (passthrough),
 * the video decoded to BGRA pixel buffers, the audio converted to float, a time range,
 * and the reader's states and errors. Compared with Apple's.
 */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"

static NSString *
time_string(CMTime t)
{
    if (CMTIME_IS_INVALID(t))
        return @"invalid";
    return [NSString stringWithFormat:@"%lld/%d", t.value, t.timescale];
}

static NSString *
fcc_string(FourCharCode c)
{
    char s[5] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
    return @(s);
}

static void
describe(CMSampleBufferRef sb, int index)
{
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    /* (an image's size is its pixel buffer's allocation: not compared) */
    printf("  #%d: pts %s dur %s samples %ld size %zu format %s", index,
        time_string(CMSampleBufferGetPresentationTimeStamp(sb)).UTF8String,
        time_string(CMSampleBufferGetDuration(sb)).UTF8String, (long)CMSampleBufferGetNumSamples(sb),
        CMSampleBufferGetImageBuffer(sb) ? 0 : CMSampleBufferGetTotalSampleSize(sb),
        fd ? fcc_string(CMFormatDescriptionGetMediaSubType(fd)).UTF8String : "none");
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts)) {
        CFDictionaryRef a = CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync);
        printf(" notSync %s", notSync ? (CFBooleanGetValue(notSync) ? "yes" : "no") : "absent");
    }
    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (ib) {
        CVPixelBufferLockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);
        const uint8_t *p = CVPixelBufferGetBaseAddress(ib);
        size_t bpr = CVPixelBufferGetBytesPerRow(ib);
        const uint8_t *c = p + 24 * bpr + 32 * 4;
        printf(" image %zux%zu bpr %zu %s primaries %s centre ~%d,%d,%d,%d", CVPixelBufferGetWidth(ib), CVPixelBufferGetHeight(ib),
            CVPixelBufferGetBytesPerRow(ib), fcc_string(CVPixelBufferGetPixelFormatType(ib)).UTF8String,
            [(__bridge NSString *)CVBufferGetAttachment(ib, kCVImageBufferColorPrimariesKey, NULL) UTF8String], c[2] / 32, c[1] / 32, c[0] / 32, c[3] / 32);
        CVPixelBufferUnlockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);
    }
    printf("\n");
}

/* Reads every buffer of an output; prints the first few and totals. */
static void
drain(AVAssetReader *r, AVAssetReaderOutput *o, const char *label, int show)
{
    int n = 0;
    long samples = 0;
    CMTime last = kCMTimeInvalid;
    CMSampleBufferRef sb;
    printf("%s:\n", label);
    while ((sb = [o copyNextSampleBuffer])) {
        if (n < show)
            describe(sb, n);
        samples += CMSampleBufferGetNumSamples(sb);
        last = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), CMSampleBufferGetDuration(sb));
        n++;
        CFRelease(sb);
    }
    printf("  %d buffers, %ld samples, ends %.3f s, status %ld\n", n, samples, CMTimeGetSeconds(last), (long)r.status);
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avreader-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        NSError *err = nil;

        /* stored */
        AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
        printf("reader: error %ld status %ld range %s+%s\n", (long)err.code, (long)r.status, time_string(r.timeRange.start).UTF8String,
            time_string(r.timeRange.duration).UTF8String);
        AVAssetReaderTrackOutput *vp = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video outputSettings:nil];
        AVAssetReaderTrackOutput *ap = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audio outputSettings:nil];
        printf("can add %d %d; media types %s %s; copies %d\n", [r canAddOutput:vp], [r canAddOutput:ap], vp.mediaType.UTF8String,
            ap.mediaType.UTF8String, vp.alwaysCopiesSampleData);
        [r addOutput:vp];
        [r addOutput:ap];
        printf("start %d status %ld outputs %lu\n", [r startReading], (long)r.status, (unsigned long)r.outputs.count);
        drain(r, vp, "video as stored", 3);
        drain(r, ap, "audio as stored", 3);
        printf("after: status %ld\n", (long)r.status);

        /* decoded */
        AVAssetReader *d = [AVAssetReader assetReaderWithAsset:asset error:&err];
        AVAssetReaderTrackOutput *vd = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:video
                             outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
        AVAssetReaderTrackOutput *ad = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:audio
                             outputSettings:@{
                                 AVFormatIDKey : @(kAudioFormatLinearPCM),
                                 AVLinearPCMBitDepthKey : @32,
                                 AVLinearPCMIsFloatKey : @YES,
                                 AVLinearPCMIsNonInterleaved : @NO,
                                 AVLinearPCMIsBigEndianKey : @NO
                             }];
        [d addOutput:vd];
        [d addOutput:ad];
        [d startReading];
        drain(d, vd, "video as BGRA", 6);
        CMSampleBufferRef first = [ad copyNextSampleBuffer];
        if (first) {
            const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(first));
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(first);
            float f[4] = {0};
            CMBlockBufferCopyDataBytes(bb, 0, sizeof f, f);
            printf("audio as float: %.0f Hz %u ch flags %u bits %u, first frames %.4f %.4f %.4f %.4f\n", a->mSampleRate,
                a->mChannelsPerFrame, a->mFormatFlags, a->mBitsPerChannel, f[0], f[1], f[2], f[3]);
            CFRelease(first);
        }
        drain(d, ad, "rest of the audio", 0);

        /* a time range */
        AVAssetReader *t = [AVAssetReader assetReaderWithAsset:asset error:&err];
        t.timeRange = CMTimeRangeMake(CMTimeMake(200, 600), CMTimeMake(200, 600));
        AVAssetReaderTrackOutput *vt = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video outputSettings:nil];
        [t addOutput:vt];
        [t startReading];
        drain(t, vt, "video from 1/3 s for 1/3 s", 4);

        /* states and errors */
        AVAssetReader *c = [AVAssetReader assetReaderWithAsset:asset error:&err];
        AVAssetReaderTrackOutput *vc = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video outputSettings:nil];
        [c addOutput:vc];
        [c startReading];
        CMSampleBufferRef one = [vc copyNextSampleBuffer];
        if (one)
            CFRelease(one);
        [c cancelReading];
        printf("cancelled: status %ld next %p\n", (long)c.status, [vc copyNextSampleBuffer]);
        @try {
            [c addOutput:[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audio outputSettings:nil]];
            printf("add after start: no exception\n");
        } @catch (NSException *e) {
            printf("add after start: %s\n", e.name.UTF8String);
        }
        AVAssetReader *none = [AVAssetReader assetReaderWithAsset:asset error:&err];
        @try {
            printf("start with no outputs: %d\n", [none startReading]);
        } @catch (NSException *e) {
            printf("start with no outputs: %s\n", e.name.UTF8String);
        }
        AVURLAsset *missing = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@"/nonexistent.mov"] options:nil];
        NSError *me = nil;
        AVAssetReader *mr = [AVAssetReader assetReaderWithAsset:missing error:&me];
        printf("missing file: reader %d error %s %ld\n", mr != nil, me.domain.UTF8String, (long)me.code);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

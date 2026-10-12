/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetWriter: a QuickTime movie written from BGRA pixel buffers (JPEG, through a
 * pixel buffer adaptor) and 16-bit PCM sample buffers, with metadata; the writer's
 * states, what it accepts, and errors; then the movie read back as an asset (tracks,
 * durations, formats, sample counts, metadata), and an MPEG-4 file with stored samples
 * copied across. Compared with Apple's (encoders differ, so byte sizes aren't).
 */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"

static NSString *
fcc_string(FourCharCode c)
{
    char s[5] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
    return @(s);
}

static CVPixelBufferRef
frame(int i)
{
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, 64, 48, kCVPixelFormatType_32BGRA, NULL, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *p = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (int y = 0; y < 48; y++)
        for (int x = 0; x < 64; x++) {
            uint8_t *q = p + y * bpr + x * 4;
            q[0] = i % 2 ? 220 : 30, q[1] = 60, q[2] = i % 2 ? 30 : 220, q[3] = 255;
        }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static CMSampleBufferRef
pcm(int64_t start, int frames)
{
    AudioStreamBasicDescription a = {44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef fd = NULL;
    CMAudioFormatDescriptionCreate(NULL, &a, 0, NULL, 0, NULL, NULL, &fd);
    size_t n = (size_t)frames * 4;
    int16_t *s = malloc(n);
    for (int i = 0; i < frames; i++)
        s[i * 2] = s[i * 2 + 1] = (int16_t)(sin((start + i) * 2 * M_PI * 440 / 44100) * 8000);
    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, NULL, n, NULL, NULL, 0, n, kCMBlockBufferAssureMemoryNowFlag, &bb);
    CMBlockBufferReplaceDataBytes(s, bb, 0, n);
    free(s);
    CMSampleBufferRef sb = NULL;
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, fd, frames, CMTimeMake(start, 44100), NULL, &sb);
    CFRelease(bb), CFRelease(fd);
    return sb;
}

static void
wait_for(BOOL *done)
{
    for (int i = 0; i < 500 && !*done; i++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

/* (inputs take data when they're ready for it) */
static void
wait_ready(AVAssetWriterInput *input)
{
    for (int i = 0; i < 500 && !input.readyForMoreMediaData; i++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static void
read_back(NSURL *url)
{
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:url options:nil];
    printf("  read back: duration %.3f s, tracks %lu, formats %s\n", CMTimeGetSeconds(a.duration), (unsigned long)a.tracks.count,
        [a.availableMetadataFormats componentsJoinedByString:@" "].UTF8String);
    for (AVAssetTrack *t in a.tracks) {
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
        printf("  track %d %s: %s range %.3f+%.3f size %s rate %.2f timescale %d", t.trackID, t.mediaType.UTF8String,
            fcc_string(CMFormatDescriptionGetMediaSubType(fd)).UTF8String, CMTimeGetSeconds(t.timeRange.start),
            CMTimeGetSeconds(t.timeRange.duration), NSStringFromSize(t.naturalSize).UTF8String, t.nominalFrameRate, t.naturalTimeScale);
        if ([t.mediaType isEqualToString:AVMediaTypeAudio]) {
            const AudioStreamBasicDescription *s = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            printf(" %.0f Hz %u ch %u bits flags %u", s->mSampleRate, s->mChannelsPerFrame, s->mBitsPerChannel, s->mFormatFlags);
        }
        printf("\n");
    }
    for (AVMetadataItem *m in a.metadata)
        printf("  metadata %s = %s\n", m.identifier.UTF8String, [m.stringValue UTF8String]);
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avwriter-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"out.mov"]];
        NSError *err = nil;
        AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&err];
        printf("writer: error %ld status %ld type %s timescale %d optimize %d types %lu\n", (long)err.code, (long)w.status,
            w.outputFileType.UTF8String, w.movieTimeScale, w.shouldOptimizeForNetworkUse, (unsigned long)w.availableMediaTypes.count);
        NSDictionary *videoSettings = @{AVVideoCodecKey : AVVideoCodecTypeJPEG, AVVideoWidthKey : @64, AVVideoHeightKey : @48};
        NSDictionary *audioSettings = @{
            AVFormatIDKey : @(kAudioFormatLinearPCM),
            AVSampleRateKey : @44100,
            AVNumberOfChannelsKey : @2,
            AVLinearPCMBitDepthKey : @16,
            AVLinearPCMIsFloatKey : @NO,
            AVLinearPCMIsBigEndianKey : @NO,
            AVLinearPCMIsNonInterleaved : @NO
        };
        /* (H.264 isn't compared: Finch has no encoder for it yet) */
        printf("can apply: video %d audio %d\n", [w canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo],
            [w canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]);
        AVAssetWriterInput *vi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        vi.expectsMediaDataInRealTime = NO;
        AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vi
                                       sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
        AVAssetWriterInput *ai = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        printf("can add %d %d; input type %s ready %d timescale %d\n", [w canAddInput:vi], [w canAddInput:ai], vi.mediaType.UTF8String,
            vi.readyForMoreMediaData, vi.mediaTimeScale);
        [w addInput:vi];
        [w addInput:ai];
        AVMutableMetadataItem *title = [AVMutableMetadataItem metadataItem];
        title.identifier = AVMetadataIdentifierQuickTimeMetadataTitle;
        title.value = @"Written by the test";
        w.metadata = @[ title ];
        printf("pool before start %p\n", ad.pixelBufferPool);
        printf("start %d status %ld\n", [w startWriting], (long)w.status);
        printf("pool after start %d\n", ad.pixelBufferPool != NULL);
        [w startSessionAtSourceTime:kCMTimeZero];
        for (int i = 0; i < 6; i++) {
            CVPixelBufferRef pb = frame(i);
            wait_ready(vi);
            BOOL ok = [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(i * 100, 600)];
            if (!ok)
                printf("append %d failed: %ld\n", i, (long)w.error.code);
            CVPixelBufferRelease(pb);
        }
        for (int i = 0; i < 44100; i += 11025) {
            CMSampleBufferRef sb = pcm(i, 11025);
            wait_ready(ai);
            if (![ai appendSampleBuffer:sb])
                printf("audio append failed: %ld\n", (long)w.error.code);
            CFRelease(sb);
        }
        [vi markAsFinished];
        [ai markAsFinished];
        [w endSessionAtSourceTime:CMTimeMake(600, 600)];
        __block BOOL done = NO;
        [w finishWritingWithCompletionHandler:^{
            done = YES;
        }];
        wait_for(&done);
        printf("finished: status %ld error %ld\n", (long)w.status, (long)w.error.code);
        @try {
            [w addInput:[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil]];
            printf("add after finish: no exception\n");
        } @catch (NSException *e) {
            printf("add after finish: %s\n", e.name.UTF8String);
        }
        read_back(url);

        /* stored samples into MPEG-4 */
        NSURL *src = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"src.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:src atomically:YES];
        AVURLAsset *srcAsset = [AVURLAsset URLAssetWithURL:src options:nil];
        AVAssetReader *r = [AVAssetReader assetReaderWithAsset:srcAsset error:&err];
        AVAssetTrack *sv = [srcAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetReaderTrackOutput *ro = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:sv outputSettings:nil];
        [r addOutput:ro];
        [r startReading];
        NSURL *mp4 = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"copy.mp4"]];
        AVAssetWriter *w2 = [AVAssetWriter assetWriterWithURL:mp4 fileType:AVFileTypeMPEG4 error:&err];
        AVAssetWriterInput *pi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
                                                                  sourceFormatHint:(__bridge CMFormatDescriptionRef)sv.formatDescriptions[0]];
        printf("mp4: can add passthrough %d\n", [w2 canAddInput:pi]);
        [w2 addInput:pi];
        [w2 startWriting];
        [w2 startSessionAtSourceTime:kCMTimeZero];
        CMSampleBufferRef sb;
        int copied = 0;
        while ((sb = [ro copyNextSampleBuffer])) {
            if (CMSampleBufferGetNumSamples(sb)) {
                wait_ready(pi);
                [pi appendSampleBuffer:sb];
                copied++;
            }
            CFRelease(sb);
        }
        [pi markAsFinished];
        done = NO;
        [w2 finishWritingWithCompletionHandler:^{
            done = YES;
        }];
        wait_for(&done);
        printf("mp4: copied %d, status %ld error %ld\n", copied, (long)w2.status, (long)w2.error.code);
        read_back(mp4);
        NSData *head = [[NSData dataWithContentsOfURL:mp4] subdataWithRange:NSMakeRange(4, 8)];
        printf("mp4 begins %.8s\n", (const char *)head.bytes);

        /* errors */
        NSURL *existing = mp4;
        AVAssetWriter *w3 = [AVAssetWriter assetWriterWithURL:existing fileType:AVFileTypeMPEG4 error:&err];
        [w3 addInput:[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings]];
        BOOL started = [w3 startWriting];
        printf("existing file: start %d status %ld error %s %ld\n", started, (long)w3.status, w3.error.domain.UTF8String, (long)w3.error.code);
        if (getenv("AVWRITER_KEEP"))
            printf("kept %s\n", dir.UTF8String);
        else
            [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Immediate sample-buffer creation from a file-backed sample cursor. */
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVSampleCursor.h>
#import <AVFoundation/AVSampleBufferGenerator.h>
#include "avmovie.h"
#include "avframes.h"

int
main(void)
{
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"avsample-generator-%d.mov", getpid()]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToFile:path atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVSampleCursor *cursor = [track makeSampleCursorAtFirstSampleInDecodeOrder];
        AVSampleBufferRequest *request = [[AVSampleBufferRequest alloc] initWithStartCursor:cursor];
        AVSampleBufferGenerator *generator = [[AVSampleBufferGenerator alloc] initWithAsset:asset timebase:NULL];
        NSError *error = nil;
        CMSampleBufferRef sample = [generator createSampleBufferForRequest:request error:&error];
        CMFormatDescriptionRef format = sample ? CMSampleBufferGetFormatDescription(sample) : NULL;
        CMBlockBufferRef data = sample ? CMSampleBufferGetDataBuffer(sample) : NULL;
        printf("request %ld %ld %ld mode %ld overrideValid %d; sample %d error %s %ld\n", (long)request.direction,
               (long)request.preferredMinSampleCount, (long)request.maxSampleCount, (long)request.mode,
               CMTIME_IS_VALID(request.overrideTime),
               sample != NULL, error.domain.UTF8String ?: "-", (long)error.code);
        printf("pts %lld/%d dts %lld/%d dur %lld/%d samples %ld size %zu ready %d format %08x block %zu\n",
               sample ? CMSampleBufferGetPresentationTimeStamp(sample).value : -1,
               sample ? CMSampleBufferGetPresentationTimeStamp(sample).timescale : 0,
               sample ? CMSampleBufferGetDecodeTimeStamp(sample).value : -1,
               sample ? CMSampleBufferGetDecodeTimeStamp(sample).timescale : 0,
               sample ? CMSampleBufferGetDuration(sample).value : -1,
               sample ? CMSampleBufferGetDuration(sample).timescale : 0,
               sample ? (long)CMSampleBufferGetNumSamples(sample) : 0,
               sample ? CMSampleBufferGetTotalSampleSize(sample) : 0,
               sample ? CMSampleBufferDataIsReady(sample) : 0,
               format ? (unsigned)CMFormatDescriptionGetMediaSubType(format) : 0,
               data ? CMBlockBufferGetDataLength(data) : 0);
        __block BOOL notifiedReady = NO;
        __block BOOL notifiedError = NO;
        dispatch_semaphore_t notification = dispatch_semaphore_create(0);
        [AVSampleBufferGenerator notifyOfDataReadyForSampleBuffer:sample completionHandler:^(BOOL dataReady, NSError *notifyError) {
            notifiedReady = dataReady;
            notifiedError = notifyError != nil;
            dispatch_semaphore_signal(notification);
        }];
        dispatch_semaphore_wait(notification, DISPATCH_TIME_FOREVER);
        AVSampleBufferGeneratorBatch *batch = [generator makeBatch];
        NSError *batchError = nil;
        CMSampleBufferRef batched = [generator createSampleBufferForRequest:request addingToBatch:batch error:&batchError];
        __block BOOL batchReady = NO;
        __block BOOL batchFailed = NO;
        dispatch_semaphore_t batchNotification = dispatch_semaphore_create(0);
        [batch makeDataReadyWithCompletionHandler:^(NSError *batchResult) {
            batchReady = YES;
            batchFailed = batchResult != nil;
            dispatch_semaphore_signal(batchNotification);
        }];
        dispatch_semaphore_wait(batchNotification, DISPATCH_TIME_FOREVER);
        printf("notify %d %d batch %d %d %d\n", notifiedReady, notifiedError, batched != NULL, batchReady, batchFailed || batchError != nil);
        if (batched) CFRelease(batched);
        if (sample) CFRelease(sample);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}

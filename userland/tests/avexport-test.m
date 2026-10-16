/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A passthrough export of video and audio samples, compared with Apple's AVFoundation. */
#import <AVFoundation/AVFoundation.h>
#include "avmovie.h"
#include "avframes.h"
#include <stdio.h>
#include <unistd.h>

static void
wait_for(BOOL *done)
{
    for (int i = 0; i < 1000 && !*done; i++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

int
main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"avexport-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *source = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"source.mov"]];
        NSURL *destination = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"export.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1]
                                   : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:source atomically:YES];

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
        AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset
            presetName:AVAssetExportPresetPassthrough];
        session.outputFileType = AVFileTypeQuickTimeMovie;
        session.outputURL = destination;
        printf("session: created=%d status=%ld preset=%d quicktime=%d\n", session != nil,
               (long)session.status, [session.presetName isEqualToString:AVAssetExportPresetPassthrough],
               [session.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]);

        __block BOOL done = NO;
        __block int callbacks = 0;
        [session exportAsynchronouslyWithCompletionHandler:^{ done = YES; callbacks++; }];
        wait_for(&done);
        printf("export: callbacks=%d status=%ld progress=%.1f error=%ld\n", callbacks,
               (long)session.status, session.progress, (long)session.error.code);
        AVURLAsset *exported = [AVURLAsset URLAssetWithURL:destination options:nil];
        printf("result: opened=%d duration=%.3f tracks=%lu\n", exported.isPlayable,
               CMTimeGetSeconds(exported.duration), (unsigned long)exported.tracks.count);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

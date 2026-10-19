/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare protected-content status when a normal movie has no DRM authorization. */
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVPlayerItemProtectedContentAdditions.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "avmovie.h"
#include <stdio.h>

static NSData *frame(void)
{
    const uint8_t bytes[] = {0xff, 0xd8, 1, 2, 3, 4, 5, 6, 0xff, 0xd9};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

int main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("%s\n", class_getImageName([AVPlayerItem class]));
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"avcontent-auth-%d.mov", getpid()]];
        [build_movie_with_frames(@[frame()]) writeToFile:path atomically:YES];
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
        printf("authorization %d application %d content %d status %ld\n",
            item.isAuthorizationRequiredForPlayback, item.isApplicationAuthorizedForPlayback,
            item.isContentAuthorizedForPlayback, (long)item.contentAuthorizationRequestStatus);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block AVContentAuthorizationStatus completed = AVContentAuthorizationUnknown;
        [item requestContentAuthorizationAsynchronouslyWithTimeoutInterval:0 completionHandler:^{
            completed = item.contentAuthorizationRequestStatus;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        [item cancelContentAuthorizationRequest];
        printf("completion %ld status %ld\n", (long)completed, (long)item.contentAuthorizationRequestStatus);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return 0;
}

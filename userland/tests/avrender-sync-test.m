/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare the sample-buffer synchronizer's real CoreMedia timebase behavior. */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

static NSString *
time_text(CMTime time)
{
    if (!CMTIME_IS_NUMERIC(time))
        return @"invalid";
    time = CMTimeConvertScale(time, 600, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    return [NSString stringWithFormat:@"%lld/%d", time.value, time.timescale];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        AVSampleBufferRenderSynchronizer *synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init];
        puts("AVSampleBufferRenderSynchronizer timebase checks");
        printf("initial timebase %d rate %.2f time %s delayed %d\n", synchronizer.timebase != NULL,
               synchronizer.rate, time_text(synchronizer.currentTime).UTF8String,
               synchronizer.delaysRateChangeUntilHasSufficientMediaData);
        [synchronizer setRate:0 time:CMTimeMake(5, 1)];
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = NO;
        printf("stopped time %s rate %.2f delayed %d\n", time_text(synchronizer.currentTime).UTF8String,
               synchronizer.rate, synchronizer.delaysRateChangeUntilHasSufficientMediaData);
    }
    return 0;
}

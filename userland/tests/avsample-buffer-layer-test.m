/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare device-independent sample-buffer layer state and timebase behavior. */
#import <AVFoundation/AVSampleBufferDisplayLayer.h>
#import <AVFoundation/AVAnimation.h>
#import <CoreMedia/CMSync.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
        printf("%s\n", class_getImageName([layer class]));
        printf("default status=%ld error=%d timebase=%d control=%d ready=%d more=%d enough=%d flush=%d gravity=%s\n",
            (long)layer.status, layer.error != nil, layer.timebase != NULL, layer.controlTimebase != NULL,
            layer.readyForDisplay, layer.readyForMoreMediaData, layer.hasSufficientMediaDataForReliablePlaybackStart,
            layer.requiresFlushToResumeDecoding, layer.videoGravity.UTF8String);
        printf("protection capture=%d sleep=%d obscured=%d\n", layer.preventsCapture,
            layer.preventsDisplaySleepDuringVideoPlayback, layer.outputObscuredDueToInsufficientExternalProtection);
        CMTimebaseRef control = NULL;
        CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &control);
        layer.controlTimebase = control;
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        printf("set control=%d gravity=%s\n", layer.controlTimebase == control, layer.videoGravity.UTF8String);
        layer.controlTimebase = NULL;
        if (control) CFRelease(control);
        [layer flush];
        printf("flushed status=%ld error=%d ready=%d\n", (long)layer.status, layer.error != nil, layer.readyForDisplay);
        [layer flushAndRemoveImage];
    }
    return 0;
}

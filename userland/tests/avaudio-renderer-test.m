/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Compare default sample-buffer audio renderer settings, before hardware playback. */
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        AVSampleBufferAudioRenderer *renderer = [[AVSampleBufferAudioRenderer alloc] init];
        printf("%s\n", class_getImageName([AVSampleBufferAudioRenderer class]));
        printf("state %ld ready %d enough %d error %d timebase %d\n", (long)renderer.status,
            renderer.readyForMoreMediaData, renderer.hasSufficientMediaDataForReliablePlaybackStart,
            renderer.error != nil, renderer.timebase != NULL);
        printf("settings %.2f muted %d device %d algorithm %s spatial %lu\n", renderer.volume, renderer.muted,
            renderer.audioOutputDeviceUniqueID != nil, renderer.audioTimePitchAlgorithm.UTF8String,
            (unsigned long)renderer.allowedAudioSpatializationFormats);
    }
    return 0;
}

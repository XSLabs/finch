/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check that the no-device recorder keeps its public ABI visible. */
#import <AVFAudio/AVAudioRecorder.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        puts("AVAudioRecorder no-device ABI checks");
        printf("AVAudioRecorder methods %d %d %d %d %d\n",
               [AVAudioRecorder instancesRespondToSelector:@selector(initWithURL:settings:error:)],
               [AVAudioRecorder instancesRespondToSelector:@selector(prepareToRecord)],
               [AVAudioRecorder instancesRespondToSelector:@selector(recordAtTime:forDuration:)],
               [AVAudioRecorder instancesRespondToSelector:@selector(averagePowerForChannel:)],
               [AVAudioRecorder instancesRespondToSelector:@selector(setDelegate:)]);
    }
    return 0;
}

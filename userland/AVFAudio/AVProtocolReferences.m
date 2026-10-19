/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Keep the public audio delegate contracts visible in Finch's Objective-C runtime. */
#import <AVFAudio/AVFAudio.h>

__attribute__((constructor)) static void
FinchRetainAVAudioProtocolMetadata(void)
{
    volatile Protocol *protocol;
    protocol = @protocol(AVAudioPlayerDelegate);
    protocol = @protocol(AVAudioRecorderDelegate);
    protocol = @protocol(AVSpeechSynthesizerDelegate);
    (void)protocol;
}

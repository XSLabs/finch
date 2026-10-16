/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Variable- and fixed-size compressed packet buffers, compared with Apple's AVFAudio. */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdio.h>

int
main(void)
{
    @autoreleasepool {
        AudioStreamBasicDescription variableASBD = {48000, kAudioFormatMPEG4AAC, 0, 0, 0, 1024, 2, 0, 0};
        AVAudioFormat *variableFormat = [[AVAudioFormat alloc] initWithStreamDescription:&variableASBD];
        AVAudioCompressedBuffer *variable = [[AVAudioCompressedBuffer alloc]
            initWithFormat:variableFormat packetCapacity:3 maximumPacketSize:40];
        printf("variable: format=%u packets=%u/%u max=%ld bytes=%u/%u buffers=%u channels=%u descriptions=%d dependencies=%d list=%u capacity-list=%u\n",
               (unsigned)variable.format.streamDescription->mFormatID,
               (unsigned)variable.packetCount, (unsigned)variable.packetCapacity,
               (long)variable.maximumPacketSize, (unsigned)variable.byteLength,
               (unsigned)variable.byteCapacity, (unsigned)variable.audioBufferList->mNumberBuffers,
               (unsigned)variable.audioBufferList->mBuffers[0].mNumberChannels,
               variable.packetDescriptions != NULL, variable.packetDependencies != NULL,
               (unsigned)variable.audioBufferList->mBuffers[0].mDataByteSize,
               (unsigned)variable.mutableAudioBufferList->mBuffers[0].mDataByteSize);

        variable.packetDescriptions[0].mStartOffset = 0;
        variable.packetDescriptions[0].mVariableFramesInPacket = 1024;
        variable.packetDescriptions[0].mDataByteSize = 11;
        variable.packetCount = 1;
        variable.byteLength = 11;
        ((uint8_t *)variable.data)[0] = 0x5a;
        printf("variable-used: packets=%u bytes=%u list=%u capacity-list=%u sample=%u description=%lld,%u,%u\n",
               (unsigned)variable.packetCount, (unsigned)variable.byteLength,
               (unsigned)variable.audioBufferList->mBuffers[0].mDataByteSize,
               (unsigned)variable.mutableAudioBufferList->mBuffers[0].mDataByteSize,
               (unsigned)((uint8_t *)variable.data)[0],
               (long long)variable.packetDescriptions[0].mStartOffset,
               variable.packetDescriptions[0].mVariableFramesInPacket,
               variable.packetDescriptions[0].mDataByteSize);

        AudioStreamBasicDescription fixedASBD = {44100, kAudioFormatAppleIMA4, 0, 34, 0, 64, 2, 0, 0};
        AVAudioFormat *fixedFormat = [[AVAudioFormat alloc] initWithStreamDescription:&fixedASBD];
        AVAudioCompressedBuffer *fixed = [[AVAudioCompressedBuffer alloc] initWithFormat:fixedFormat packetCapacity:4];
        printf("fixed: packets=%u/%u max=%ld bytes=%u/%u descriptions=%d\n",
               (unsigned)fixed.packetCount, (unsigned)fixed.packetCapacity,
               (long)fixed.maximumPacketSize, (unsigned)fixed.byteLength,
               (unsigned)fixed.byteCapacity, fixed.packetDescriptions != NULL);

        [fixed release]; [fixedFormat release]; [variable release]; [variableFormat release];
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Ordinary values follow Apple's output. Finch's expected file also requires
 * rejection of truncated layouts and PCM frames too short for their channels. */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <stdlib.h>

static void
print_format(NSString *name, AVAudioFormat *format)
{
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    printf("%s: %u %.0f %u %u %u %u %u standard=%d interleaved=%d\n",
           name.UTF8String, (unsigned)format.commonFormat, format.sampleRate,
           (unsigned)format.channelCount, (unsigned)asbd->mFormatFlags,
           (unsigned)asbd->mBytesPerFrame, (unsigned)asbd->mFramesPerPacket,
           (unsigned)asbd->mBitsPerChannel, format.isStandard, format.isInterleaved);
}

int
main(void)
{
    @autoreleasepool {
        AVAudioFormat *standard = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        AVAudioFormat *interleaved = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:48000 channels:2 interleaved:YES];
        AVAudioFormat *monoA = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100 channels:1 interleaved:NO];
        AVAudioFormat *monoB = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100 channels:1 interleaved:YES];
        AudioStreamBasicDescription shortFrameASBD = *interleaved.streamDescription;
        shortFrameASBD.mBytesPerFrame = 2;
        shortFrameASBD.mBytesPerPacket = 2;
        AVAudioFormat *shortFrameFormat = [[AVAudioFormat alloc] initWithStreamDescription:&shortFrameASBD];
        AVAudioPCMBuffer *shortFrameBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:shortFrameFormat frameCapacity:2];
        __block UInt32 shortFrameCallbacks = 0;
        void *shortFrameData = malloc(8);
        struct { UInt32 count; AudioBuffer buffers[1]; } shortFrameList = {1, {{2, 8, shortFrameData}}};
        AVAudioPCMBuffer *shortFrameNoCopy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:shortFrameFormat
            bufferListNoCopy:(AudioBufferList *)&shortFrameList deallocator:^(const AudioBufferList *passed) {
                (void)passed;
                shortFrameCallbacks++;
            }];
        [shortFrameNoCopy release];
        print_format(@"standard", standard);
        print_format(@"int16-stereo", interleaved);
        printf("mono-equal-ignores-interleaving=%d\n", [monoA isEqual:monoB]);
        printf("short-pcm-frame-rejected=%d,%d\n", shortFrameFormat != nil, shortFrameBuffer == nil);
        printf("short-no-copy-frame-unaccepted=%d,%u\n", shortFrameNoCopy == nil, (unsigned)shortFrameCallbacks);

        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:interleaved frameCapacity:4];
        printf("initial: capacity=%u length=%u lengthBytes=%u capacityBytes=%u stride=%lu\n",
               (unsigned)buffer.frameCapacity, (unsigned)buffer.frameLength,
               (unsigned)buffer.audioBufferList->mBuffers[0].mDataByteSize,
               (unsigned)buffer.mutableAudioBufferList->mBuffers[0].mDataByteSize,
               (unsigned long)buffer.stride);
        int16_t *const *samples = buffer.int16ChannelData;
        samples[0][0] = 101; samples[1][0] = 202;
        samples[0][2] = 303; samples[1][2] = 404;
        buffer.frameLength = 2;
        AVAudioPCMBuffer *copy = [buffer copy];
        printf("after-write: length=%u lengthBytes=%u samples=%d,%d,%d,%d copyLength=%u copyBytes=%u copySamples=%d,%d\n",
               (unsigned)buffer.frameLength, (unsigned)buffer.audioBufferList->mBuffers[0].mDataByteSize,
               samples[0][0], samples[1][0], samples[0][2], samples[1][2],
               (unsigned)copy.frameLength, (unsigned)copy.audioBufferList->mBuffers[0].mDataByteSize,
               copy.int16ChannelData[0][0], copy.int16ChannelData[1][0]);
        copy.int16ChannelData[0][0] = -9;
        printf("copy-is-independent=%d\n", samples[0][0] == 101 && copy.int16ChannelData[0][0] == -9);
        printf("after-length-capacityBytes=%u\n", (unsigned)buffer.mutableAudioBufferList->mBuffers[0].mDataByteSize);

        AVAudioPCMBuffer *planar = [[AVAudioPCMBuffer alloc] initWithPCMFormat:standard frameCapacity:3];
        planar.floatChannelData[0][0] = 0.25f;
        planar.floatChannelData[1][0] = -0.5f;
        planar.frameLength = 1;
        printf("planar: buffers=%u bytes=%u,%u stride=%lu data=%g,%g distinct=%d\n",
               (unsigned)planar.audioBufferList->mNumberBuffers,
               (unsigned)planar.audioBufferList->mBuffers[0].mDataByteSize,
               (unsigned)planar.audioBufferList->mBuffers[1].mDataByteSize,
               (unsigned long)planar.stride, planar.floatChannelData[0][0], planar.floatChannelData[1][0],
               planar.floatChannelData[0] != planar.floatChannelData[1]);

        NSDictionary *settings = standard.settings;
        AVAudioFormat *fromSettings = [[AVAudioFormat alloc] initWithSettings:settings];
        printf("settings-round-trip=%d settings-count=%lu\n", [standard isEqual:fromSettings], (unsigned long)settings.count);

        AudioChannelLayout truncatedLayout = {0};
        truncatedLayout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        truncatedLayout.mNumberChannelDescriptions = 1;
        NSData *truncatedLayoutData = [NSData dataWithBytes:&truncatedLayout
                                                     length:offsetof(AudioChannelLayout, mChannelDescriptions)];
        NSMutableDictionary *badSettings = [NSMutableDictionary dictionaryWithDictionary:settings];
        badSettings[AVChannelLayoutKey] = truncatedLayoutData;
        AVAudioFormat *badFormat = [[AVAudioFormat alloc] initWithSettings:badSettings];
        AudioChannelLayout describedLayout = {0};
        describedLayout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        describedLayout.mNumberChannelDescriptions = 1;
        describedLayout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Center;
        AVAudioChannelLayout *validDescribedLayout = [[AVAudioChannelLayout alloc] initWithLayout:&describedLayout];
        NSError *layoutArchiveError = nil;
        NSData *layoutArchive = [NSKeyedArchiver archivedDataWithRootObject:validDescribedLayout
                                                     requiringSecureCoding:YES error:&layoutArchiveError];
        NSMutableDictionary *archivePlist = layoutArchive ? [NSPropertyListSerialization
            propertyListWithData:layoutArchive options:NSPropertyListMutableContainersAndLeaves
            format:NULL error:&layoutArchiveError] : nil;
        NSMutableArray *archiveObjects = archivePlist[@"$objects"];
        BOOL replacedLayoutBytes = NO;
        for (NSUInteger i = 0; i < archiveObjects.count; i++) {
            id object = archiveObjects[i];
            if (![object isKindOfClass:[NSData class]]) continue;
            NSData *bytes = object;
            if (bytes.length < offsetof(AudioChannelLayout, mChannelDescriptions)) continue;
            const AudioChannelLayout *candidate = bytes.bytes;
            if (candidate->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions &&
                candidate->mNumberChannelDescriptions == 1) {
                archiveObjects[i] = truncatedLayoutData;
                replacedLayoutBytes = YES;
                break;
            }
        }
        NSData *truncatedArchive = replacedLayoutBytes ? [NSPropertyListSerialization
            dataWithPropertyList:archivePlist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&layoutArchiveError] : nil;
        BOOL truncatedArchiveRejected = NO;
        if (truncatedArchive) {
            @try {
                AVAudioChannelLayout *badArchivedLayout = [NSKeyedUnarchiver
                    unarchivedObjectOfClass:[AVAudioChannelLayout class] fromData:truncatedArchive error:&layoutArchiveError];
                truncatedArchiveRejected = badArchivedLayout == nil;
            } @catch (NSException *exception) {
                (void)exception;
                truncatedArchiveRejected = YES;
            }
        }
        printf("truncated-layout-rejected=%d,%d\n", badFormat == nil,
               replacedLayoutBytes && truncatedArchiveRejected);
        [validDescribedLayout release]; [badFormat release];

        NSError *archiveError = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:standard requiringSecureCoding:YES error:&archiveError];
        AVAudioFormat *decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[AVAudioFormat class] fromData:archive error:&archiveError] : nil;
        printf("secure-coding=%d\n", decoded && [decoded isEqual:standard]);
        printf("core-media-description=%d\n", standard.formatDescription != NULL);

        AVAudioChannelLayout *stereoLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Stereo];
        AVAudioFormat *layoutFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100 interleaved:NO channelLayout:stereoLayout];
        printf("stereo-layout=%u format-layout=%u\n", (unsigned)stereoLayout.channelCount, (unsigned)layoutFormat.channelLayout.channelCount);
        AVAudioChannelLayout *threeLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_3_0_A];
        AVAudioFormat *threeFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channelLayout:threeLayout];
        AVAudioPCMBuffer *threeBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:threeFormat frameCapacity:2];
        AVAudioFormat *threeSettings = [[AVAudioFormat alloc] initWithSettings:threeFormat.settings];
        printf("explicit-three-channel=%u buffers=%u settings-equal=%d\n", (unsigned)threeFormat.channelCount,
               (unsigned)threeBuffer.audioBufferList->mNumberBuffers, [threeFormat isEqual:threeSettings]);

        __block int callbacks = 0;
        int16_t *external = malloc(4 * sizeof(int16_t));
        external[0] = 7; external[1] = 8; external[2] = 9; external[3] = 10;
        struct { UInt32 count; AudioBuffer buffers[1]; } raw = {1, {{1, 4 * sizeof(int16_t), external}}};
        AVAudioFormat *monoInt16 = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:1 interleaved:YES];
        AVAudioPCMBuffer *noCopy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:monoInt16 bufferListNoCopy:(AudioBufferList *)&raw deallocator:^(const AudioBufferList *passed) {
            callbacks++;
            printf("deallocator-list=%u,%u,%d\n", (unsigned)passed->mNumberBuffers,
                   (unsigned)passed->mBuffers[0].mDataByteSize,
                   ((int16_t *)passed->mBuffers[0].mData)[0]);
            free(passed->mBuffers[0].mData);
        }];
        AVAudioPCMBuffer *noCopyClone = [noCopy copy];
        [noCopy release];
        printf("no-copy: callback-count=%d frame-length=%u capacity-bytes=%u clone-first=%d\n", callbacks,
               (unsigned)noCopyClone.frameLength, (unsigned)noCopyClone.mutableAudioBufferList->mBuffers[0].mDataByteSize,
               noCopyClone.int16ChannelData[0][0]);
        [noCopyClone release];
        printf("no-copy-final-callback-count=%d\n", callbacks);

        __block UInt32 rejectedCallbacks = 0;
        void *rejectedData = malloc(4);
        struct { UInt32 count; AudioBuffer buffers[1]; } emptyList = {0, {{1, 4, rejectedData}}};
        AVAudioPCMBuffer *rejected = [[AVAudioPCMBuffer alloc] initWithPCMFormat:monoInt16
            bufferListNoCopy:(AudioBufferList *)&emptyList deallocator:^(const AudioBufferList *passed) {
                (void)passed;
                rejectedCallbacks++;
            }];
        [rejected release];
        printf("no-copy-failure-unaccepted=%d\n", rejected == nil && rejectedCallbacks == 0);
        free(rejectedData);

        __block UInt32 partialCallbacks = 0;
        void *partialData = malloc(3);
        struct { UInt32 count; AudioBuffer buffers[1]; } partialList = {1, {{1, 3, partialData}}};
        AVAudioPCMBuffer *partial = [[AVAudioPCMBuffer alloc] initWithPCMFormat:monoInt16
            bufferListNoCopy:(AudioBufferList *)&partialList deallocator:^(const AudioBufferList *passed) {
                partialCallbacks++;
                printf("partial-deallocator-bytes=%u\n", (unsigned)passed->mBuffers[0].mDataByteSize);
            }];
        printf("partial-byte-no-copy=%d,%u,%u,%u\n", partial != nil,
               (unsigned)partial.frameCapacity, (unsigned)partial.frameLength,
               partial ? (unsigned)partial.audioBufferList->mBuffers[0].mDataByteSize : 0);
        [partial release];
        printf("partial-no-copy-callback=%u\n", (unsigned)partialCallbacks);
        free(partialData);

        [monoInt16 release]; [threeSettings release]; [threeBuffer release]; [threeFormat release]; [layoutFormat release]; [fromSettings release]; [planar release]; [copy release];
        [shortFrameBuffer release]; [shortFrameFormat release];
        free(shortFrameData);
        [buffer release]; [monoB release]; [monoA release]; [interleaved release]; [standard release];
    }
    return 0;
}

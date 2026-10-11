/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AVAudioBuffer's storage and the typed views of AVAudioPCMBuffer. */
#import <AVFAudio/AVAudioBuffer.h>
#import <AVFAudio/AVAudioFormat.h>
#include <AudioToolbox/AudioToolbox.h>
#include <Block.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AVAUDIO_BUFFER_INIT_FAIL() do { [self release]; return nil; } while (0)

struct AVAudioBufferStorage {
    AVAudioFormat *format;
    AudioBufferList *lengthList;
    AudioBufferList *capacityList;
    AudioBufferList *deallocatorList;
    void (^deallocator)(const AudioBufferList *);
    void **data;
    void **channels;
    uint32_t dataCount;
    uint32_t channelCount;
    uint32_t byteCapacity;
    AVAudioFrameCount frameCapacity;
    AVAudioFrameCount frameLength;
    uint32_t bytesPerFrame;
    uint32_t bytesPerSample;
    BOOL interleaved;
    BOOL ownsData;
};

static AudioBufferList *
new_buffer_list(UInt32 count)
{
    if (!count)
        return NULL;
    return calloc(1, offsetof(AudioBufferList, mBuffers) + (size_t)count * sizeof(AudioBuffer));
}

static BOOL
pcm_buffer_layout(AVAudioFormat *format, UInt32 *channelsOut, UInt32 *bytesPerFrameOut,
                  UInt32 *bytesPerSampleOut, BOOL *interleavedOut)
{
    if (!format || !format.streamDescription ||
        format.streamDescription->mFormatID != kAudioFormatLinearPCM)
        return NO;
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    UInt64 channels = asbd->mChannelsPerFrame;
    UInt64 bits = asbd->mBitsPerChannel;
    UInt64 bytesPerSample = (bits + 7) / 8;
    BOOL interleaved = format.interleaved;
    UInt64 minimumBytesPerFrame = bytesPerSample * (interleaved ? channels : 1);
    if (!channels || !asbd->mBytesPerFrame || !bytesPerSample ||
        bytesPerSample > UINT32_MAX || minimumBytesPerFrame > asbd->mBytesPerFrame)
        return NO;

    /* Typed channel pointers advance by one sample per channel per frame. */
    if (format.commonFormat != AVAudioOtherFormat && minimumBytesPerFrame != asbd->mBytesPerFrame)
        return NO;

    if (channelsOut) *channelsOut = (UInt32)channels;
    if (bytesPerFrameOut) *bytesPerFrameOut = asbd->mBytesPerFrame;
    if (bytesPerSampleOut) *bytesPerSampleOut = (UInt32)bytesPerSample;
    if (interleavedOut) *interleavedOut = interleaved;
    return YES;
}

static void
fill_channel_views(struct AVAudioBufferStorage *s)
{
    if (!s->frameCapacity) {
        for (UInt32 i = 0; i < s->channelCount; i++)
            s->channels[i] = NULL;
        return;
    }
    for (UInt32 i = 0; i < s->channelCount; i++)
        s->channels[i] = (char *)s->data[s->interleaved ? 0 : i] + (s->interleaved ? (size_t)i * s->bytesPerSample : 0);
}

static void
set_frame_length(struct AVAudioBufferStorage *s, AVAudioFrameCount length)
{
    s->frameLength = length;
    UInt32 bytes = length * s->bytesPerFrame;
    for (UInt32 i = 0; i < s->lengthList->mNumberBuffers; i++)
        s->lengthList->mBuffers[i].mDataByteSize = bytes;
    for (UInt32 i = 0; i < s->capacityList->mNumberBuffers; i++)
        s->capacityList->mBuffers[i].mDataByteSize = bytes;
}

static void
free_storage(struct AVAudioBufferStorage *s)
{
    if (!s) return;
    if (s->deallocator) {
        s->deallocator(s->deallocatorList);
        Block_release(s->deallocator);
    }
    if (s->ownsData && s->data)
        for (UInt32 i = 0; i < s->dataCount; i++) free(s->data[i]);
    [s->format release];
    free(s->lengthList);
    free(s->capacityList);
    free(s->deallocatorList);
    free(s->channels);
    free(s->data);
    free(s);
}

@implementation AVAudioBuffer

- (AVAudioFormat *)format { return ((struct AVAudioBufferStorage *)_impl)->format; }
- (const AudioBufferList *)audioBufferList { return ((struct AVAudioBufferStorage *)_impl)->lengthList; }
- (AudioBufferList *)mutableAudioBufferList { return ((struct AVAudioBufferStorage *)_impl)->capacityList; }

- (id)copyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }
- (id)mutableCopyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }

- (void)dealloc
{
    free_storage(_impl);
    [super dealloc];
}

@end

@implementation AVAudioPCMBuffer

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
- (instancetype)init
{
    return [self initWithPCMFormat:nil frameCapacity:0];
}
#pragma clang diagnostic pop

- (instancetype)initWithPCMFormat:(AVAudioFormat *)format frameCapacity:(AVAudioFrameCount)capacity
{
    if (!format || format.streamDescription->mFormatID != kAudioFormatLinearPCM) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"AVAudioPCMBuffer requires a linear PCM format"];
        return nil;
    }
    UInt32 channels, bytesPerFrame, bytesPerSample;
    BOOL interleaved;
    if (!pcm_buffer_layout(format, &channels, &bytesPerFrame, &bytesPerSample, &interleaved) ||
        capacity > UINT32_MAX / bytesPerFrame)
        AVAUDIO_BUFFER_INIT_FAIL();
    UInt32 buffers = interleaved ? 1 : channels;
    uint32_t bytes = capacity * bytesPerFrame;
    struct AVAudioBufferStorage *s = calloc(1, sizeof(*s));
    if (!s) AVAUDIO_BUFFER_INIT_FAIL();
    s->format = [format retain];
    s->lengthList = new_buffer_list(buffers);
    s->capacityList = new_buffer_list(buffers);
    s->dataCount = buffers;
    s->channelCount = channels;
    s->bytesPerFrame = bytesPerFrame;
    s->bytesPerSample = bytesPerSample;
    s->byteCapacity = bytes;
    s->frameCapacity = capacity;
    s->interleaved = interleaved;
    s->ownsData = YES;
    s->data = calloc(buffers, sizeof(void *));
    s->channels = calloc(channels, sizeof(void *));
    if (!s->lengthList || !s->capacityList || !s->data || !s->channels) { free_storage(s); AVAUDIO_BUFFER_INIT_FAIL(); }
    for (UInt32 i = 0; i < buffers; i++) {
        s->data[i] = calloc(1, bytes ? bytes : 1);
        if (!s->data[i]) { free_storage(s); AVAUDIO_BUFFER_INIT_FAIL(); }
        s->lengthList->mBuffers[i] = (AudioBuffer){interleaved ? channels : 1, 0, s->data[i]};
        s->capacityList->mBuffers[i] = (AudioBuffer){interleaved ? channels : 1, 0, s->data[i]};
    }
    s->lengthList->mNumberBuffers = buffers;
    s->capacityList->mNumberBuffers = buffers;
    fill_channel_views(s);
    self = [super init];
    if (!self) { free_storage(s); return nil; }
    _impl = s;
    return self;
}

- (instancetype)initWithPCMFormat:(AVAudioFormat *)format bufferListNoCopy:(const AudioBufferList *)list deallocator:(void (^)(const AudioBufferList *))deallocator
{
    if (!format || format.streamDescription->mFormatID != kAudioFormatLinearPCM) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"AVAudioPCMBuffer requires a linear PCM format"];
        return nil;
    }
    UInt32 channels, bytesPerFrame, bytesPerSample;
    BOOL interleaved;
    if (!pcm_buffer_layout(format, &channels, &bytesPerFrame, &bytesPerSample, &interleaved))
        AVAUDIO_BUFFER_INIT_FAIL();
    UInt32 expected = interleaved ? 1 : channels;
    if (!list || !list->mNumberBuffers || list->mNumberBuffers != expected)
        AVAUDIO_BUFFER_INIT_FAIL();
    UInt32 bytes = list->mBuffers[0].mDataByteSize;
    if (!bytes) AVAUDIO_BUFFER_INIT_FAIL();
    for (UInt32 i = 0; i < expected; i++)
        if (!list->mBuffers[i].mData || !list->mBuffers[i].mDataByteSize || list->mBuffers[i].mDataByteSize != bytes)
            AVAUDIO_BUFFER_INIT_FAIL();

    struct AVAudioBufferStorage *s = calloc(1, sizeof(*s));
    if (!s) AVAUDIO_BUFFER_INIT_FAIL();
    s->format = [format retain];
    s->lengthList = new_buffer_list(expected);
    s->capacityList = new_buffer_list(expected);
    s->deallocatorList = new_buffer_list(expected);
    s->dataCount = expected;
    s->channelCount = channels;
    s->bytesPerFrame = bytesPerFrame;
    s->bytesPerSample = bytesPerSample;
    s->byteCapacity = bytes;
    s->frameCapacity = bytes / bytesPerFrame;
    s->frameLength = s->frameCapacity;
    s->interleaved = interleaved;
    s->ownsData = NO;
    s->data = calloc(expected, sizeof(void *));
    s->channels = calloc(channels, sizeof(void *));
    if (!s->lengthList || !s->capacityList || !s->deallocatorList || !s->data || !s->channels) { free_storage(s); AVAUDIO_BUFFER_INIT_FAIL(); }
    s->lengthList->mNumberBuffers = expected;
    s->capacityList->mNumberBuffers = expected;
    s->deallocatorList->mNumberBuffers = expected;
    for (UInt32 i = 0; i < expected; i++) {
        s->data[i] = list->mBuffers[i].mData;
        s->lengthList->mBuffers[i] = list->mBuffers[i];
        s->capacityList->mBuffers[i] = list->mBuffers[i];
        s->deallocatorList->mBuffers[i] = list->mBuffers[i];
    }
    fill_channel_views(s);
    self = [super init];
    if (!self) { free_storage(s); return nil; }
    s->deallocator = deallocator ? Block_copy(deallocator) : NULL;
    if (deallocator && !s->deallocator) { free_storage(s); [self release]; return nil; }
    _impl = s;
    return self;
}

- (AVAudioFrameCount)frameCapacity { return ((struct AVAudioBufferStorage *)_impl)->frameCapacity; }
- (AVAudioFrameCount)frameLength { return ((struct AVAudioBufferStorage *)_impl)->frameLength; }

- (void)setFrameLength:(AVAudioFrameCount)length
{
    struct AVAudioBufferStorage *s = _impl;
    if (length > s->frameCapacity)
        [NSException raise:NSInvalidArgumentException format:@"frameLength cannot exceed frameCapacity"];
    set_frame_length(s, length);
}

- (NSUInteger)stride
{
    struct AVAudioBufferStorage *s = _impl;
    return s->interleaved ? s->channelCount : 1;
}

- (float *const *)floatChannelData
{
    struct AVAudioBufferStorage *s = _impl;
    return s->format.commonFormat == AVAudioPCMFormatFloat32 ? (float *const *)s->channels : NULL;
}

- (int16_t *const *)int16ChannelData
{
    struct AVAudioBufferStorage *s = _impl;
    return s->format.commonFormat == AVAudioPCMFormatInt16 ? (int16_t *const *)s->channels : NULL;
}

- (int32_t *const *)int32ChannelData
{
    struct AVAudioBufferStorage *s = _impl;
    return s->format.commonFormat == AVAudioPCMFormatInt32 ? (int32_t *const *)s->channels : NULL;
}

- (id)copyWithZone:(NSZone *)zone
{
    struct AVAudioBufferStorage *s = _impl;
    AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer allocWithZone:zone] initWithPCMFormat:s->format frameCapacity:s->frameCapacity];
    if (!copy) return nil;
    struct AVAudioBufferStorage *to = copy->_impl;
    for (UInt32 i = 0; i < s->dataCount; i++)
        memcpy(to->data[i], s->data[i], (size_t)s->frameLength * s->bytesPerFrame);
    copy.frameLength = s->frameLength;
    return copy;
}

- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* High-level audio-file reads and writes over Finch's AudioFile and AudioConverter. */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreServices/CoreServices.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct OpaqueExtAudioFile {
    AudioFileID file;
    AudioConverterRef converter;
    AudioStreamBasicDescription fileFormat, clientFormat;
    AudioChannelLayout *fileLayout, *clientLayout;
    UInt32 fileLayoutSize, clientLayoutSize;
    void *ioBuffer;
    UInt32 ioBufferSize;
    SInt64 position, seekPosition, fileReadPosition;
    UInt64 clientFramesSinceSeek;
    void *writeQueue;
    UInt32 writeQueueCapacity, writeQueueFrames, writeQueueReadFrame;
    UInt64 writeInputFrames, writeOutputFrames;
    OSStatus writeError;
    bool ownsFile, writing, clientSet, ioStarted;
};

#define kExtAudioFileInputQueueEmpty ((OSStatus)-70001)

static OSStatus
copy_property(void *out, UInt32 *size, const void *value, UInt32 valueSize)
{
    if (!out || !size)
        return kAudio_ParamError;
    if (*size < valueSize)
        return -1;
    memcpy(out, value, valueSize);
    *size = valueSize;
    return noErr;
}

static bool
same_format(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b)
{
    return a->mSampleRate == b->mSampleRate && a->mFormatID == b->mFormatID && a->mFormatFlags == b->mFormatFlags &&
        a->mBytesPerPacket == b->mBytesPerPacket && a->mFramesPerPacket == b->mFramesPerPacket &&
        a->mBytesPerFrame == b->mBytesPerFrame && a->mChannelsPerFrame == b->mChannelsPerFrame &&
        a->mBitsPerChannel == b->mBitsPerChannel;
}

static bool
usable_file_format(const AudioStreamBasicDescription *a)
{
    return (a->mFormatID == kAudioFormatLinearPCM || a->mFormatID == kAudioFormatULaw || a->mFormatID == kAudioFormatALaw) &&
        isfinite(a->mSampleRate) && a->mSampleRate > 0 && a->mChannelsPerFrame > 0 && a->mBytesPerFrame > 0 && a->mBytesPerPacket > 0 &&
        a->mFramesPerPacket == 1 && a->mBytesPerFrame == a->mBytesPerPacket &&
        !(a->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
}

static OSStatus
file_length_frames(ExtAudioFileRef f, SInt64 *frames)
{
    UInt64 bytes = 0;
    UInt32 size = sizeof(bytes);
    OSStatus e = AudioFileGetProperty(f->file, kAudioFilePropertyAudioDataByteCount, &size, &bytes);
    if (e)
        return e;
    if (!f->fileFormat.mBytesPerPacket || !f->fileFormat.mFramesPerPacket)
        return kExtAudioFileError_InvalidDataFormat;
    uint64_t packets = bytes / f->fileFormat.mBytesPerPacket;
    if (packets > (uint64_t)INT64_MAX / f->fileFormat.mFramesPerPacket)
        return kExtAudioFileError_InvalidDataFormat;
    *frames = (SInt64)(packets * f->fileFormat.mFramesPerPacket);
    return noErr;
}

static OSStatus
read_file_format(AudioFileID file, AudioStreamBasicDescription *format)
{
    UInt32 size = sizeof(*format);
    return AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, format);
}

static OSStatus flush_sample_rate_write(ExtAudioFileRef f);

static OSStatus
configure_converter(ExtAudioFileRef f, const AudioStreamBasicDescription *client, AudioConverterRef *result)
{
    *result = NULL;
    if (client->mFormatID != kAudioFormatLinearPCM)
        return kExtAudioFileError_NonPCMClientFormat;
    AudioConverterRef check = NULL;
    const AudioStreamBasicDescription *input = f->writing ? client : &f->fileFormat;
    const AudioStreamBasicDescription *output = f->writing ? &f->fileFormat : client;
    OSStatus e = AudioConverterNew(input, output, &check);
    if (e)
        return e;
    if (same_format(input, output)) {
        AudioConverterDispose(check);
        return noErr;
    }
    *result = check;
    return noErr;
}

static OSStatus
new_extended_file(AudioFileID file, bool writing, bool owns, ExtAudioFileRef *result)
{
    *result = NULL;
    ExtAudioFileRef f = calloc(1, sizeof(*f));
    if (!f)
        return -108;
    f->file = file;
    f->writing = writing;
    f->ownsFile = owns;
    OSStatus e = read_file_format(file, &f->fileFormat);
    if (e) {
        free(f);
        return e;
    }
    if (!usable_file_format(&f->fileFormat)) {
        free(f);
        return kExtAudioFileError_InvalidDataFormat;
    }
    *result = f;
    return noErr;
}

static OSStatus
open_url(CFURLRef url, ExtAudioFileRef *result)
{
    if (!url || !result)
        return kAudio_ParamError;
    *result = NULL;
    AudioFileID file = NULL;
    OSStatus e = AudioFileOpenURL(url, kAudioFileReadPermission, 0, &file);
    if (e)
        return e;
    e = new_extended_file(file, false, true, result);
    if (e)
        AudioFileClose(file);
    return e;
}

OSStatus
ExtAudioFileOpenURL(CFURLRef inURL, ExtAudioFileRef *outExtAudioFile)
{
    if (!inURL || !outExtAudioFile)
        return kAudio_ParamError;
    return open_url(inURL, outExtAudioFile);
}

OSStatus
ExtAudioFileOpen(const FSRef *inFSRef, ExtAudioFileRef *outExtAudioFile)
{
    if (!inFSRef || !outExtAudioFile)
        return kAudio_ParamError;
    CFURLRef url = CFURLCreateFromFSRef(NULL, inFSRef);
    if (!url) {
        *outExtAudioFile = NULL;
        return kAudioFileInvalidFileError;
    }
    OSStatus status = ExtAudioFileOpenURL(url, outExtAudioFile);
    CFRelease(url);
    return status;
}

OSStatus
ExtAudioFileWrapAudioFileID(AudioFileID inFileID, Boolean inForWriting, ExtAudioFileRef *outExtAudioFile)
{
    if (!inFileID || !outExtAudioFile)
        return kAudio_ParamError;
    return new_extended_file(inFileID, inForWriting, false, outExtAudioFile);
}

OSStatus
ExtAudioFileCreateWithURL(CFURLRef inURL, AudioFileTypeID inFileType, const AudioStreamBasicDescription *inStreamDesc,
    const AudioChannelLayout *inChannelLayout, UInt32 inFlags, ExtAudioFileRef *outExtAudioFile)
{
    if (!inURL || !inStreamDesc || !outExtAudioFile)
        return kAudio_ParamError;
    *outExtAudioFile = NULL;
    AudioFileID file = NULL;
    OSStatus e = AudioFileCreateWithURL(inURL, inFileType, inStreamDesc, (AudioFileFlags)inFlags, &file);
    if (e)
        return e;
    if (inChannelLayout) {
        UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions);
        if (inChannelLayout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
            size += inChannelLayout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
        e = AudioFileSetProperty(file, kAudioFilePropertyChannelLayout, size, inChannelLayout);
        if (e) {
            AudioFileClose(file);
            return e;
        }
    }
    e = new_extended_file(file, true, true, outExtAudioFile);
    if (e)
        AudioFileClose(file);
    return e;
}

OSStatus
ExtAudioFileCreateNew(const FSRef *inParentDir, CFStringRef inFileName, AudioFileTypeID inFileType,
    const AudioStreamBasicDescription *inStreamDesc, const AudioChannelLayout *inChannelLayout,
    ExtAudioFileRef *outExtAudioFile)
{
    if (!inParentDir || !inFileName || !inStreamDesc || !outExtAudioFile)
        return kAudio_ParamError;
    CFURLRef parent = CFURLCreateFromFSRef(NULL, inParentDir);
    if (!parent) {
        *outExtAudioFile = NULL;
        return kAudioFileInvalidFileError;
    }
    CFURLRef url = CFURLCreateCopyAppendingPathComponent(NULL, parent, inFileName, false);
    CFRelease(parent);
    if (!url) {
        *outExtAudioFile = NULL;
        return kAudioFileInvalidFileError;
    }
    OSStatus status = ExtAudioFileCreateWithURL(url, inFileType, inStreamDesc, inChannelLayout,
        0, outExtAudioFile);
    CFRelease(url);
    return status;
}

OSStatus
ExtAudioFileDispose(ExtAudioFileRef inExtAudioFile)
{
    if (!inExtAudioFile)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    OSStatus e = noErr;
    if (f->writing && !f->writeError)
        e = flush_sample_rate_write(f);
    if (f->converter)
        AudioConverterDispose(f->converter);
    if (f->writing) {
        OSStatus optimizeError = AudioFileOptimize(f->file);
        if (!e)
            e = optimizeError;
    }
    if (f->ownsFile) {
        OSStatus closeError = AudioFileClose(f->file);
        if (!e)
            e = closeError;
    }
    free(f->fileLayout);
    free(f->clientLayout);
    free(f->writeQueue);
    free(f);
    return e;
}

static UInt32
buffer_count(const AudioStreamBasicDescription *format)
{
    return (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? format->mChannelsPerFrame : 1;
}

static UInt32
buffer_channels(const AudioStreamBasicDescription *format)
{
    return (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : format->mChannelsPerFrame;
}

static UInt32
frames_in_buffers(const AudioStreamBasicDescription *format, const AudioBufferList *data, UInt32 requested)
{
    if (!data || data->mNumberBuffers != buffer_count(format))
        return UINT32_MAX;
    UInt32 frames = requested;
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
        const AudioBuffer *b = &data->mBuffers[i];
        if (b->mNumberChannels != buffer_channels(format))
            return UINT32_MAX;
        if (requested && !b->mData)
            return UINT32_MAX;
        UInt32 available = format->mBytesPerFrame ? b->mDataByteSize / format->mBytesPerFrame : 0;
        if (available < frames)
            frames = available;
    }
    return frames;
}

static void
set_buffer_sizes(const AudioStreamBasicDescription *format, AudioBufferList *data, UInt32 frames)
{
    UInt32 bytes = frames * format->mBytesPerFrame;
    for (UInt32 i = 0; i < data->mNumberBuffers; i++)
        data->mBuffers[i].mDataByteSize = bytes;
}

struct ExtAudioFileReadContext {
    ExtAudioFileRef file;
    void *buffer;
    size_t capacity;
};

struct ExtAudioFileWriteContext {
    ExtAudioFileRef file;
    bool flushing;
};

static OSStatus
read_converter_input(AudioConverterRef converter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData,
    AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    (void)converter;
    (void)outDataPacketDescription;
    struct ExtAudioFileReadContext *context = inUserData;
    ExtAudioFileRef f = context->file;
    UInt32 requested = *ioNumberDataPackets;
    if (!requested)
        return noErr;
    if (requested > UINT32_MAX / f->fileFormat.mBytesPerFrame)
        return kExtAudioFileError_InvalidPropertySize;
    UInt32 capacity = requested * f->fileFormat.mBytesPerFrame;
    if (context->capacity < capacity) {
        void *buffer = realloc(context->buffer, capacity);
        if (!buffer)
            return -108;
        context->buffer = buffer;
        context->capacity = capacity;
    }
    UInt32 packets = requested;
    UInt32 bytes = capacity;
    OSStatus e = AudioFileReadPackets(f->file, false, &bytes, NULL, f->fileReadPosition, &packets, context->buffer);
    if (e)
        return e;
    if (packets > requested || bytes > capacity)
        return kAudioFileUnspecifiedError;
    f->fileReadPosition += packets;
    *ioNumberDataPackets = packets;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = (AudioBuffer){f->fileFormat.mChannelsPerFrame, bytes, context->buffer};
    return noErr;
}

static OSStatus
append_write_queue(ExtAudioFileRef f, const AudioBufferList *data, UInt32 frames)
{
    if (!frames)
        return noErr;
    if (frames > UINT32_MAX - f->writeQueueFrames)
        return kExtAudioFileError_InvalidPropertySize;
    UInt32 needed = f->writeQueueFrames + frames;
    const AudioStreamBasicDescription *client = &f->clientFormat;
    UInt32 buffers = buffer_count(client);
    size_t frameBytes = client->mBytesPerFrame;
    UInt32 capacity = f->writeQueueCapacity;
    if (capacity < needed) {
        UInt32 newCapacity = capacity ? capacity : 128;
        while (newCapacity < needed) {
            if (newCapacity > UINT32_MAX / 2) {
                newCapacity = needed;
                break;
            }
            newCapacity *= 2;
        }
        if (newCapacity > SIZE_MAX / frameBytes || (size_t)newCapacity * frameBytes > SIZE_MAX / buffers)
            return kExtAudioFileError_InvalidPropertySize;
        size_t planeBytes = (size_t)newCapacity * frameBytes;
        void *queue = malloc(planeBytes * buffers);
        if (!queue)
            return -108;
        if (f->writeQueue) {
            size_t activeBytes = (size_t)f->writeQueueFrames * frameBytes;
            size_t oldPlaneBytes = (size_t)f->writeQueueCapacity * frameBytes;
            for (UInt32 i = 0; i < buffers; i++)
                memcpy((UInt8 *)queue + (size_t)i * planeBytes,
                    (UInt8 *)f->writeQueue + (size_t)i * oldPlaneBytes, activeBytes);
            free(f->writeQueue);
        }
        f->writeQueue = queue;
        f->writeQueueCapacity = newCapacity;
        capacity = newCapacity;
    }
    size_t planeBytes = (size_t)capacity * frameBytes;
    size_t activeBytes = (size_t)f->writeQueueFrames * frameBytes;
    size_t appendBytes = (size_t)frames * frameBytes;
    for (UInt32 i = 0; i < buffers; i++)
        memcpy((UInt8 *)f->writeQueue + (size_t)i * planeBytes + activeBytes,
            data->mBuffers[i].mData, appendBytes);
    f->writeQueueFrames = needed;
    return noErr;
}

static void
compact_write_queue(ExtAudioFileRef f)
{
    if (!f->writeQueueReadFrame)
        return;
    UInt32 remaining = f->writeQueueFrames - f->writeQueueReadFrame;
    UInt32 buffers = buffer_count(&f->clientFormat);
    size_t frameBytes = f->clientFormat.mBytesPerFrame;
    size_t planeBytes = (size_t)f->writeQueueCapacity * frameBytes;
    size_t remainingBytes = (size_t)remaining * frameBytes;
    size_t offsetBytes = (size_t)f->writeQueueReadFrame * frameBytes;
    for (UInt32 i = 0; i < buffers; i++)
        memmove((UInt8 *)f->writeQueue + (size_t)i * planeBytes,
            (UInt8 *)f->writeQueue + (size_t)i * planeBytes + offsetBytes, remainingBytes);
    f->writeQueueFrames = remaining;
    f->writeQueueReadFrame = 0;
}

static OSStatus
write_converter_input(AudioConverterRef converter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData,
    AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    (void)outDataPacketDescription;
    struct ExtAudioFileWriteContext *context = inUserData;
    ExtAudioFileRef f = context->file;
    const AudioStreamBasicDescription *client = &f->clientFormat;
    UInt32 buffers = buffer_count(client);
    UInt32 available = f->writeQueueFrames - f->writeQueueReadFrame;
    UInt32 frames = *ioNumberDataPackets < available ? *ioNumberDataPackets : available;
    if (!frames) {
        *ioNumberDataPackets = 0;
        return context->flushing ? noErr : kExtAudioFileInputQueueEmpty;
    }
    if (frames > UINT32_MAX / client->mBytesPerFrame)
        return kExtAudioFileError_InvalidPropertySize;
    UInt32 bytes = frames * client->mBytesPerFrame;
    size_t planeBytes = (size_t)f->writeQueueCapacity * client->mBytesPerFrame;
    size_t offsetBytes = (size_t)f->writeQueueReadFrame * client->mBytesPerFrame;
    ioData->mNumberBuffers = buffers;
    for (UInt32 i = 0; i < buffers; i++)
        ioData->mBuffers[i] = (AudioBuffer){buffer_channels(client), bytes,
            (UInt8 *)f->writeQueue + (size_t)i * planeBytes + offsetBytes};
    f->writeQueueReadFrame += frames;
    *ioNumberDataPackets = frames;
    (void)converter;
    return noErr;
}

static OSStatus
write_converted_packets(ExtAudioFileRef f, UInt32 frames, const void *data)
{
    if (!frames)
        return noErr;
    if (frames > UINT32_MAX / f->fileFormat.mBytesPerFrame)
        return kExtAudioFileError_InvalidPropertySize;
    UInt32 bytes = frames * f->fileFormat.mBytesPerFrame;
    UInt32 packets = frames;
    OSStatus e = AudioFileWritePackets(f->file, false, bytes, NULL, f->position, &packets, data);
    f->position += packets;
    f->writeOutputFrames += packets;
    if (e)
        return e;
    return packets == frames ? noErr : kAudioFileUnspecifiedError;
}

static OSStatus
convert_queued_write(ExtAudioFileRef f, UInt64 requested, bool flushing)
{
    if (!requested && !flushing)
        return noErr;
    bool forceEOFProbe = flushing && requested == 0;
    while (requested || forceEOFProbe) {
        bool eofProbe = forceEOFProbe;
        UInt32 frames = requested > 4096 ? 4096 : (UInt32)requested;
        if (!frames)
            frames = 1;
        if (frames > UINT32_MAX / f->fileFormat.mBytesPerFrame)
            return kExtAudioFileError_InvalidPropertySize;
        UInt32 bytes = frames * f->fileFormat.mBytesPerFrame;
        void *buffer = malloc(bytes);
        if (!buffer)
            return -108;
        AudioBufferList output = {1, {{f->fileFormat.mChannelsPerFrame, bytes, buffer}}};
        UInt32 produced = frames;
        struct ExtAudioFileWriteContext context = {f, flushing};
        OSStatus e = AudioConverterFillComplexBuffer(f->converter, write_converter_input, &context,
            &produced, &output, NULL);
        OSStatus writeError = write_converted_packets(f, produced, buffer);
        free(buffer);
        if (writeError)
            return writeError;
        if (e == kExtAudioFileInputQueueEmpty)
            return noErr;
        if (e)
            return e;
        if (!produced)
            return flushing ? noErr : kAudioConverterErr_InvalidInputSize;
        forceEOFProbe = false;
        if (requested > produced)
            requested -= produced;
        else
            requested = 0;
        if (produced < frames)
            return flushing ? noErr : kAudioConverterErr_InvalidInputSize;
        if (flushing && !eofProbe && !requested)
            forceEOFProbe = true;
    }
    return noErr;
}

static OSStatus
flush_sample_rate_write(ExtAudioFileRef f)
{
    if (!f->writing || !f->clientSet || !f->converter ||
        f->clientFormat.mSampleRate == f->fileFormat.mSampleRate || !f->writeInputFrames)
        return noErr;
    long double targetValue = (long double)f->writeInputFrames * f->fileFormat.mSampleRate / f->clientFormat.mSampleRate;
    if (targetValue >= (long double)UINT64_MAX)
        return kExtAudioFileError_InvalidPropertySize;
    UInt64 target = (UInt64)targetValue;
    UInt64 remaining = target > f->writeOutputFrames ? target - f->writeOutputFrames : 0;
    OSStatus e = convert_queued_write(f, remaining, true);
    compact_write_queue(f);
    if (!e && f->writeQueueFrames)
        e = kAudioConverterErr_InvalidInputSize;
    if (!e) {
        f->writeInputFrames = 0;
        f->writeOutputFrames = 0;
        f->writeQueueReadFrame = 0;
        f->ioStarted = true;
    }
    return e;
}

OSStatus
ExtAudioFileRead(ExtAudioFileRef inExtAudioFile, UInt32 *ioNumberFrames, AudioBufferList *ioData)
{
    if (!inExtAudioFile || !ioNumberFrames || !ioData)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    if (f->writing)
        return kExtAudioFileError_InvalidOperationOrder;
    if (f->fileFormat.mFramesPerPacket != 1 || !f->fileFormat.mBytesPerFrame)
        return kExtAudioFileError_InvalidDataFormat;
    if (f->clientSet && f->clientFormat.mFormatID != kAudioFormatLinearPCM)
        return kExtAudioFileError_NonPCMClientFormat;
    const AudioStreamBasicDescription *client = f->clientSet ? &f->clientFormat : &f->fileFormat;
    UInt32 requested = *ioNumberFrames;
    UInt32 actual = frames_in_buffers(client, ioData, requested);
    if (actual == UINT32_MAX) {
        *ioNumberFrames = 0;
        return -1;
    }
    if (!actual) {
        *ioNumberFrames = 0;
        set_buffer_sizes(client, ioData, 0);
        return noErr;
    }
    if (f->converter && f->fileFormat.mSampleRate != client->mSampleRate) {
        struct ExtAudioFileReadContext context = {f, NULL, 0};
        UInt32 converted = actual;
        OSStatus e = AudioConverterFillComplexBuffer(f->converter, read_converter_input, &context,
            &converted, ioData, NULL);
        free(context.buffer);
        if (UINT64_MAX - f->clientFramesSinceSeek < converted)
            f->clientFramesSinceSeek = UINT64_MAX;
        else
            f->clientFramesSinceSeek += converted;
        long double offset = (long double)f->clientFramesSinceSeek * f->fileFormat.mSampleRate / client->mSampleRate;
        f->position = offset >= (long double)(INT64_MAX - f->seekPosition) ? INT64_MAX :
            f->seekPosition + (SInt64)offset;
        *ioNumberFrames = converted;
        if (e)
            return e;
        f->ioStarted = true;
        return noErr;
    }
    if (actual > UINT32_MAX / f->fileFormat.mBytesPerFrame) {
        *ioNumberFrames = 0;
        return kExtAudioFileError_InvalidPropertySize;
    }
    UInt32 bytes = actual * f->fileFormat.mBytesPerFrame;
    void *temporary = NULL;
    AudioBufferList input = {1, {{f->fileFormat.mChannelsPerFrame, bytes, NULL}}};
    if (f->converter) {
        temporary = malloc(bytes);
        if (!temporary) {
            *ioNumberFrames = 0;
            return -108;
        }
        input.mBuffers[0].mData = temporary;
    } else {
        input.mBuffers[0] = ioData->mBuffers[0];
    }
    UInt32 packets = actual;
    UInt32 readBytes = bytes;
    OSStatus e = AudioFileReadPackets(f->file, false, &readBytes, NULL, f->position, &packets, input.mBuffers[0].mData);
    if (e) {
        free(temporary);
        *ioNumberFrames = 0;
        return e;
    }
    if (f->converter && packets) {
        input.mBuffers[0].mDataByteSize = readBytes;
        e = AudioConverterConvertComplexBuffer(f->converter, packets, &input, ioData);
    } else if (!f->converter) {
        ioData->mBuffers[0].mDataByteSize = readBytes;
    }
    free(temporary);
    if (e) {
        *ioNumberFrames = 0;
        return e;
    }
    f->fileReadPosition += packets;
    f->position += packets;
    f->seekPosition = f->position;
    f->ioStarted = true;
    *ioNumberFrames = packets;
    if (f->converter)
        set_buffer_sizes(client, ioData, packets);
    return noErr;
}

OSStatus
ExtAudioFileWrite(ExtAudioFileRef inExtAudioFile, UInt32 inNumberFrames, const AudioBufferList *ioData)
{
    if (!inExtAudioFile || !ioData)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    if (!f->writing)
        return kAudioFilePermissionsError;
    if (f->writeError)
        return f->writeError;
    if (f->fileFormat.mFramesPerPacket != 1 || !f->fileFormat.mBytesPerFrame)
        return kExtAudioFileError_InvalidDataFormat;
    if (!inNumberFrames)
        return noErr;
    const AudioStreamBasicDescription *client = f->clientSet ? &f->clientFormat : &f->fileFormat;
    if (f->clientSet && client->mFormatID != kAudioFormatLinearPCM)
        return kExtAudioFileError_NonPCMClientFormat;
    UInt32 actual = frames_in_buffers(client, ioData, inNumberFrames);
    if (actual != inNumberFrames)
        return kAudioConverterErr_InvalidInputSize;
    if (f->converter && client->mSampleRate != f->fileFormat.mSampleRate) {
        if (UINT64_MAX - f->writeInputFrames < inNumberFrames)
            return kExtAudioFileError_InvalidPropertySize;
        UInt64 totalInput = f->writeInputFrames + inNumberFrames;
        long double targetValue = (long double)totalInput * f->fileFormat.mSampleRate / client->mSampleRate;
        if (targetValue >= (long double)UINT64_MAX)
            return kExtAudioFileError_InvalidPropertySize;
        OSStatus e = append_write_queue(f, ioData, inNumberFrames);
        if (e)
            return e;
        f->writeInputFrames = totalInput;
        f->ioStarted = true;
        UInt64 target = (UInt64)targetValue;
        UInt64 remaining = target > f->writeOutputFrames ? target - f->writeOutputFrames : 0;
        e = convert_queued_write(f, remaining, false);
        compact_write_queue(f);
        if (e)
            f->writeError = e;
        return e;
    }
    if (inNumberFrames > UINT32_MAX / f->fileFormat.mBytesPerFrame)
        return kExtAudioFileError_InvalidPropertySize;
    const void *data = ioData->mBuffers[0].mData;
    UInt32 bytes = inNumberFrames * f->fileFormat.mBytesPerFrame;
    void *temporary = NULL;
    AudioBufferList output = {1, {{f->fileFormat.mChannelsPerFrame, bytes, NULL}}};
    if (f->converter) {
        temporary = malloc(bytes);
        if (!temporary)
            return -108;
        output.mBuffers[0].mData = temporary;
        OSStatus e = AudioConverterConvertComplexBuffer(f->converter, inNumberFrames, ioData, &output);
        if (e) {
            free(temporary);
            f->writeError = e;
            return e;
        }
        bytes = output.mBuffers[0].mDataByteSize;
        data = temporary;
    }
    UInt32 packets = inNumberFrames;
    OSStatus e = AudioFileWritePackets(f->file, false, bytes, NULL, f->position, &packets, data);
    free(temporary);
    if (e) {
        f->writeError = e;
        return e;
    }
    f->position += packets;
    f->ioStarted = true;
    if (packets != inNumberFrames) {
        f->writeError = kAudioFileUnspecifiedError;
        return f->writeError;
    }
    return noErr;
}

OSStatus
ExtAudioFileWriteAsync(ExtAudioFileRef inExtAudioFile, UInt32 inNumberFrames, const AudioBufferList *ioData)
{
    (void)inExtAudioFile;
    (void)inNumberFrames;
    (void)ioData;
    return kAudioConverterErr_OperationNotSupported;
}

OSStatus
ExtAudioFileSeek(ExtAudioFileRef inExtAudioFile, SInt64 inFrameOffset)
{
    if (!inExtAudioFile)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    SInt64 length = 0;
    OSStatus e = file_length_frames(f, &length);
    if (e)
        return e;
    if (f->writing || inFrameOffset < 0 || inFrameOffset > length)
        return kExtAudioFileError_InvalidSeek;
    f->position = inFrameOffset;
    f->seekPosition = inFrameOffset;
    f->fileReadPosition = inFrameOffset;
    f->clientFramesSinceSeek = 0;
    if (f->converter)
        AudioConverterReset(f->converter);
    return noErr;
}

OSStatus
ExtAudioFileTell(ExtAudioFileRef inExtAudioFile, SInt64 *outFrameOffset)
{
    if (!inExtAudioFile || !outFrameOffset)
        return kAudio_ParamError;
    *outFrameOffset = inExtAudioFile->position;
    return noErr;
}

static UInt32
layout_channel_count(const AudioChannelLayout *layout)
{
    if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        return layout->mNumberChannelDescriptions;
    if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap)
        return (UInt32)__builtin_popcount(layout->mChannelBitmap);
    UInt32 size = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, sizeof(layout->mChannelLayoutTag),
            &layout->mChannelLayoutTag, &size) || size < offsetof(AudioChannelLayout, mChannelDescriptions))
        return 0;
    AudioChannelLayout *full = malloc(size);
    if (!full)
        return 0;
    OSStatus e = AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, sizeof(layout->mChannelLayoutTag),
        &layout->mChannelLayoutTag, &size, full);
    UInt32 count = e ? 0 : full->mNumberChannelDescriptions;
    free(full);
    return count;
}

static OSStatus
layout_property(ExtAudioFileRef f, ExtAudioFilePropertyID property, UInt32 *size, void *data)
{
    AudioChannelLayout *layout = property == kExtAudioFileProperty_FileChannelLayout ? f->fileLayout : f->clientLayout;
    UInt32 layoutSize = property == kExtAudioFileProperty_FileChannelLayout ? f->fileLayoutSize : f->clientLayoutSize;
    if (!layout && property == kExtAudioFileProperty_FileChannelLayout)
        return AudioFileGetProperty(f->file, kAudioFilePropertyChannelLayout, size, data);
    if (!layout)
        return kExtAudioFileError_InvalidOperationOrder;
    return copy_property(data, size, layout, layoutSize);
}

OSStatus
ExtAudioFileGetPropertyInfo(ExtAudioFileRef inExtAudioFile, ExtAudioFilePropertyID inPropertyID, UInt32 *outSize, Boolean *outWritable)
{
    if (!inExtAudioFile)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    UInt32 size = 0;
    Boolean writable = false;
    switch (inPropertyID) {
    case kExtAudioFileProperty_FileDataFormat: size = sizeof(f->fileFormat); break;
    case kExtAudioFileProperty_FileChannelLayout:
        size = f->fileLayout ? f->fileLayoutSize : offsetof(AudioChannelLayout, mChannelDescriptions);
        writable = true;
        break;
    case kExtAudioFileProperty_ClientDataFormat: size = sizeof(f->clientFormat); writable = true; break;
    case kExtAudioFileProperty_ClientChannelLayout:
        size = f->clientLayout ? f->clientLayoutSize : offsetof(AudioChannelLayout, mChannelDescriptions);
        writable = true;
        break;
    case kExtAudioFileProperty_CodecManufacturer: size = sizeof(UInt32); writable = true; break;
    case kExtAudioFileProperty_AudioConverter: size = sizeof(AudioConverterRef); break;
    case kExtAudioFileProperty_AudioFile: size = sizeof(AudioFileID); break;
    case kExtAudioFileProperty_FileMaxPacketSize:
    case kExtAudioFileProperty_ClientMaxPacketSize:
    case kExtAudioFileProperty_IOBufferSizeBytes: size = sizeof(UInt32); writable = inPropertyID == kExtAudioFileProperty_IOBufferSizeBytes; break;
    case kExtAudioFileProperty_FileLengthFrames:
        size = sizeof(SInt64);
        writable = f->fileFormat.mFormatID == kAudioFormatLinearPCM;
        break;
    case kExtAudioFileProperty_ConverterConfig: size = sizeof(CFArrayRef); writable = true; break;
    case kExtAudioFileProperty_IOBuffer: size = sizeof(void *); writable = true; break;
    case kExtAudioFileProperty_PacketTable: size = sizeof(AudioFilePacketTableInfo); break;
    default: return kExtAudioFileError_InvalidProperty;
    }
    if (outSize)
        *outSize = size;
    if (outWritable)
        *outWritable = writable;
    return noErr;
}

OSStatus
ExtAudioFileGetProperty(ExtAudioFileRef inExtAudioFile, ExtAudioFilePropertyID inPropertyID, UInt32 *ioPropertyDataSize, void *outPropertyData)
{
    if (!inExtAudioFile || !ioPropertyDataSize || !outPropertyData)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    switch (inPropertyID) {
    case kExtAudioFileProperty_FileDataFormat:
        return copy_property(outPropertyData, ioPropertyDataSize, &f->fileFormat, sizeof(f->fileFormat));
    case kExtAudioFileProperty_FileChannelLayout:
    case kExtAudioFileProperty_ClientChannelLayout:
        return layout_property(f, inPropertyID, ioPropertyDataSize, outPropertyData);
    case kExtAudioFileProperty_ClientDataFormat:
        return copy_property(outPropertyData, ioPropertyDataSize, f->clientSet ? &f->clientFormat : &(AudioStreamBasicDescription){0}, sizeof(f->clientFormat));
    case kExtAudioFileProperty_CodecManufacturer: {
        UInt32 manufacturer = 0;
        return copy_property(outPropertyData, ioPropertyDataSize, &manufacturer, sizeof(manufacturer));
    }
    case kExtAudioFileProperty_AudioConverter:
        return copy_property(outPropertyData, ioPropertyDataSize, &f->converter, sizeof(f->converter));
    case kExtAudioFileProperty_AudioFile:
        return copy_property(outPropertyData, ioPropertyDataSize, &f->file, sizeof(f->file));
    case kExtAudioFileProperty_FileMaxPacketSize: {
        UInt32 value = 0, size = sizeof(value);
        OSStatus e = AudioFileGetProperty(f->file, kAudioFilePropertyMaximumPacketSize, &size, &value);
        return e ? e : copy_property(outPropertyData, ioPropertyDataSize, &value, sizeof(value));
    }
    case kExtAudioFileProperty_ClientMaxPacketSize: {
        UInt32 value = f->clientSet ? f->clientFormat.mBytesPerPacket : 0;
        return copy_property(outPropertyData, ioPropertyDataSize, &value, sizeof(value));
    }
    case kExtAudioFileProperty_FileLengthFrames: {
        SInt64 value = 0;
        OSStatus e = file_length_frames(f, &value);
        return e ? e : copy_property(outPropertyData, ioPropertyDataSize, &value, sizeof(value));
    }
    case kExtAudioFileProperty_IOBufferSizeBytes:
        return copy_property(outPropertyData, ioPropertyDataSize, &f->ioBufferSize, sizeof(f->ioBufferSize));
    case kExtAudioFileProperty_IOBuffer:
        return copy_property(outPropertyData, ioPropertyDataSize, &f->ioBuffer, sizeof(f->ioBuffer));
    case kExtAudioFileProperty_ConverterConfig:
        if (*ioPropertyDataSize < sizeof(CFArrayRef))
            return -1;
        *(CFArrayRef *)outPropertyData = NULL;
        *ioPropertyDataSize = sizeof(CFArrayRef);
        return noErr;
    case kExtAudioFileProperty_PacketTable: {
        if (*ioPropertyDataSize < sizeof(AudioFilePacketTableInfo))
            return -1;
        UInt32 size = *ioPropertyDataSize;
        OSStatus e = AudioFileGetProperty(f->file, kAudioFilePropertyPacketTableInfo, &size, outPropertyData);
        if (!e)
            *ioPropertyDataSize = size;
        return e;
    }
    default:
        return kExtAudioFileError_InvalidProperty;
    }
}

static OSStatus
copy_layout(const void *data, UInt32 size, UInt32 expectedChannels, AudioChannelLayout **result)
{
    if (!data || size < offsetof(AudioChannelLayout, mChannelDescriptions))
        return -1;
    const AudioChannelLayout *layout = data;
    UInt32 required = offsetof(AudioChannelLayout, mChannelDescriptions);
    if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        if (layout->mNumberChannelDescriptions > (UINT32_MAX - required) / sizeof(AudioChannelDescription))
            return -1;
        required += layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription);
    }
    if (size < required || !layout_channel_count(layout) || layout_channel_count(layout) != expectedChannels)
        return kExtAudioFileError_InvalidChannelMap;
    AudioChannelLayout *copy = malloc(size);
    if (!copy)
        return -108;
    memcpy(copy, data, size);
    *result = copy;
    return noErr;
}

OSStatus
ExtAudioFileSetProperty(ExtAudioFileRef inExtAudioFile, ExtAudioFilePropertyID inPropertyID, UInt32 inPropertyDataSize, const void *inPropertyData)
{
    if (!inExtAudioFile || !inPropertyData)
        return kAudio_ParamError;
    ExtAudioFileRef f = inExtAudioFile;
    switch (inPropertyID) {
    case kExtAudioFileProperty_FileChannelLayout: {
        if (f->clientSet || f->clientLayout || f->ioStarted)
            return kExtAudioFileError_InvalidOperationOrder;
        AudioChannelLayout *copy = NULL;
        OSStatus e = copy_layout(inPropertyData, inPropertyDataSize, f->fileFormat.mChannelsPerFrame, &copy);
        if (e)
            return e;
        if (f->writing)
            e = AudioFileSetProperty(f->file, kAudioFilePropertyChannelLayout, inPropertyDataSize, inPropertyData);
        if (e) {
            free(copy);
            return e;
        }
        free(f->fileLayout);
        f->fileLayout = copy;
        f->fileLayoutSize = inPropertyDataSize;
        return noErr;
    }
    case kExtAudioFileProperty_ClientDataFormat: {
        if (inPropertyDataSize != sizeof(AudioStreamBasicDescription))
            return -1;
        const AudioStreamBasicDescription *client = inPropertyData;
        if (f->clientLayout && layout_channel_count(f->clientLayout) != client->mChannelsPerFrame)
            return kExtAudioFileError_InvalidChannelMap;
        AudioConverterRef converter = NULL;
        OSStatus e = configure_converter(f, client, &converter);
        if (e)
            return e;
        if (f->writing) {
            e = flush_sample_rate_write(f);
            if (e) {
                if (converter)
                    AudioConverterDispose(converter);
                return e;
            }
        }
        if (f->converter)
            AudioConverterDispose(f->converter);
        free(f->writeQueue);
        f->writeQueue = NULL;
        f->writeQueueCapacity = f->writeQueueFrames = f->writeQueueReadFrame = 0;
        f->writeInputFrames = f->writeOutputFrames = 0;
        f->seekPosition = f->position;
        f->fileReadPosition = f->position;
        f->clientFramesSinceSeek = 0;
        f->clientFormat = *client;
        f->clientSet = true;
        f->converter = converter;
        return noErr;
    }
    case kExtAudioFileProperty_ClientChannelLayout: {
        if (!f->clientSet)
            return kExtAudioFileError_InvalidOperationOrder;
        AudioChannelLayout *copy = NULL;
        OSStatus e = copy_layout(inPropertyData, inPropertyDataSize, f->clientFormat.mChannelsPerFrame, &copy);
        if (e)
            return e;
        free(f->clientLayout);
        f->clientLayout = copy;
        f->clientLayoutSize = inPropertyDataSize;
        return noErr;
    }
    case kExtAudioFileProperty_CodecManufacturer:
        if (inPropertyDataSize != sizeof(UInt32))
            return -1;
        return kExtAudioFileError_InvalidDataFormat;
    case kExtAudioFileProperty_ConverterConfig: {
        if (inPropertyDataSize != sizeof(CFArrayRef))
            return -1;
        if (*(CFArrayRef const *)inPropertyData)
            return kExtAudioFileError_InvalidProperty;
        if (!f->clientSet)
            return noErr;
        AudioConverterRef converter = NULL;
        OSStatus e = configure_converter(f, &f->clientFormat, &converter);
        if (e)
            return e;
        if (f->writing) {
            e = flush_sample_rate_write(f);
            if (e) {
                if (converter)
                    AudioConverterDispose(converter);
                return e;
            }
        }
        if (f->converter)
            AudioConverterDispose(f->converter);
        free(f->writeQueue);
        f->writeQueue = NULL;
        f->writeQueueCapacity = f->writeQueueFrames = f->writeQueueReadFrame = 0;
        f->writeInputFrames = f->writeOutputFrames = 0;
        f->seekPosition = f->position;
        f->fileReadPosition = f->position;
        f->clientFramesSinceSeek = 0;
        f->converter = converter;
        return noErr;
    }
    case kExtAudioFileProperty_IOBufferSizeBytes:
        if (inPropertyDataSize != sizeof(UInt32))
            return -1;
        f->ioBufferSize = *(const UInt32 *)inPropertyData;
        return noErr;
    case kExtAudioFileProperty_IOBuffer:
        if (inPropertyDataSize != sizeof(void *))
            return -1;
        f->ioBuffer = *(void *const *)inPropertyData;
        return noErr;
    case kExtAudioFileProperty_FileLengthFrames: {
        if (inPropertyDataSize != sizeof(SInt64))
            return -1;
        if (f->fileFormat.mFormatID != kAudioFormatLinearPCM)
            return kExtAudioFileError_InvalidProperty;
        SInt64 frames = *(const SInt64 *)inPropertyData;
        if (frames < 0)
            return kExtAudioFileError_InvalidSeek;
        SInt64 current = 0;
        OSStatus e = file_length_frames(f, &current);
        if (e)
            return e;
        if (frames == current)
            return noErr;
        UInt64 bytes = (UInt64)frames * f->fileFormat.mBytesPerPacket / f->fileFormat.mFramesPerPacket;
        return AudioFileSetProperty(f->file, kAudioFilePropertyAudioDataByteCount, sizeof(bytes), &bytes);
    }
    case kExtAudioFileProperty_PacketTable:
        if (inPropertyDataSize != sizeof(AudioFilePacketTableInfo))
            return -1;
        return AudioFileSetProperty(f->file, kAudioFilePropertyPacketTableInfo, inPropertyDataSize, inPropertyData);
    default:
        return kExtAudioFileError_InvalidProperty;
    }
}

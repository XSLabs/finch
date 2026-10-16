/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's sample buffers, Finch's: samples in a block buffer (or one image in an
 * image buffer) with their format, timing and sizes, each given once for all samples
 * or once per sample; readiness, failure and invalidation; sample and buffer
 * attachments; output timing (trims and speed, as Apple's computes it); audio buffer
 * lists and packet descriptions.
 */
#include "CMInternal.h"
#include <Block.h>
#include <CoreVideo/CoreVideo.h>
#include <string.h>

struct opaqueCMSampleBuffer {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    CMBlockBufferRef data;
    CVImageBufferRef image;
    CMTaggedBufferGroupRef group;
    CMFormatDescriptionRef format;
    CMItemCount numSamples;
    CMItemCount timingCount;
    CMSampleTimingInfo *timing;
    CMItemCount sizeCount;
    size_t *sizes;
    AudioStreamPacketDescription *packets;
    CMItemCount packetCount;
    bool ready, valid;
    OSStatus failed;
    CMSampleBufferMakeDataReadyCallback readyCallback;
    void *readyRefcon;
    CMSampleBufferMakeDataReadyHandler readyHandler;
    CMSampleBufferRef tracking;
    bool invalidateSet;
    CMSampleBufferInvalidateCallback invalidateCallback;
    uint64_t invalidateRefcon;
    CMSampleBufferInvalidateHandler invalidateHandler;
    CFMutableArrayRef sampleAttachments;
    CFMutableDictionaryRef attachments[2];
    CMTime outputPTS;
};

typedef struct opaqueCMSampleBuffer *Mutable;

const CMSampleTimingInfo kCMTimingInfoInvalid = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}};

static void
finalize(CFTypeRef cf)
{
    Mutable sb = (Mutable)cf;
    if (sb->data)
        CFRelease(sb->data);
    if (sb->image)
        CFRelease(sb->image);
    if (sb->group)
        CFRelease(sb->group);
    if (sb->format)
        CFRelease(sb->format);
    if (sb->tracking)
        CFRelease(sb->tracking);
    if (sb->sampleAttachments)
        CFRelease(sb->sampleAttachments);
    for (int i = 0; i < 2; i++)
        if (sb->attachments[i])
            CFRelease(sb->attachments[i]);
    if (sb->readyHandler)
        Block_release(sb->readyHandler);
    if (sb->invalidateHandler)
        Block_release(sb->invalidateHandler);
    free(sb->timing);
    free(sb->sizes);
    free(sb->packets);
    pthread_mutex_destroy(&sb->lock);
}

static CFStringRef copy_description(CFTypeRef cf);

CM_DEFINE_TYPE(CMSampleBufferGetTypeID, "CMSampleBuffer", finalize, NULL, NULL, copy_description)

bool
_FinchCMSampleBufferAttachments(CFTypeRef target, CFMutableDictionaryRef **attachments, pthread_mutex_t **lock)
{
    if (!target || CFGetTypeID(target) != CMSampleBufferGetTypeID())
        return false;
    *attachments = ((Mutable)target)->attachments;
    *lock = &((Mutable)target)->lock;
    return true;
}

static Mutable
make(CFAllocatorRef allocator)
{
    Mutable sb = (Mutable)cm_create(allocator, CMSampleBufferGetTypeID(), sizeof(struct opaqueCMSampleBuffer));
    if (!sb)
        return NULL;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&sb->lock, &attr);
    pthread_mutexattr_destroy(&attr);
    sb->valid = true;
    sb->outputPTS = kCMTimeInvalid;
    return sb;
}

static OSStatus
set_timing(Mutable sb, CMItemCount count, const CMSampleTimingInfo *timing)
{
    if (count && !timing)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (count != 0 && count != 1 && count != sb->numSamples)
        return kCMSampleBufferError_InvalidEntryCount;
    free(sb->timing);
    sb->timing = NULL;
    sb->timingCount = 0;
    sb->timing = count ? malloc(sizeof *timing * (size_t)count) : NULL;
    if (count && !sb->timing)
        return kCMSampleBufferError_AllocationFailed;
    if (count)
        memcpy(sb->timing, timing, sizeof *timing * (size_t)count);
    sb->timingCount = count;
    return noErr;
}

static OSStatus
set_sizes(Mutable sb, CMItemCount count, const size_t *sizes)
{
    if (count && !sizes)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (count != 0 && count != 1 && count != sb->numSamples)
        return kCMSampleBufferError_InvalidEntryCount;
    free(sb->sizes);
    sb->sizes = count ? malloc(sizeof *sizes * (size_t)count) : NULL;
    if (count)
        memcpy(sb->sizes, sizes, sizeof *sizes * (size_t)count);
    sb->sizeCount = count;
    return noErr;
}

static OSStatus
create(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, CVImageBufferRef image, Boolean dataReady,
       CMSampleBufferMakeDataReadyCallback callback, void *refcon, CMSampleBufferMakeDataReadyHandler handler,
       CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMItemCount numSampleTimingEntries,
       const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray, Mutable *out)
{
    *out = NULL;
    if (numSamples < 0 || numSampleTimingEntries < 0 || numSampleSizeEntries < 0)
        return kCMSampleBufferError_InvalidEntryCount;
    Mutable sb = make(allocator);
    if (!sb)
        return kCMSampleBufferError_AllocationFailed;
    sb->numSamples = numSamples;
    OSStatus e = set_timing(sb, numSampleTimingEntries, sampleTimingArray);
    if (!e)
        e = set_sizes(sb, numSampleSizeEntries, sampleSizeArray);
    if (e) {
        CFRelease(sb);
        return e;
    }
    if (dataBuffer)
        sb->data = (CMBlockBufferRef)CFRetain(dataBuffer);
    if (image)
        sb->image = (CVImageBufferRef)CFRetain(image);
    if (formatDescription)
        sb->format = (CMFormatDescriptionRef)CFRetain(formatDescription);
    sb->ready = dataReady;
    sb->readyCallback = callback;
    sb->readyRefcon = refcon;
    if (handler)
        sb->readyHandler = Block_copy(handler);
    *out = sb;
    return noErr;
}

OSStatus
CMSampleBufferCreate(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback makeDataReadyCallback,
                     void *makeDataReadyRefcon, CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMItemCount numSampleTimingEntries,
                     const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray,
                     CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb;
    OSStatus e = create(allocator, dataBuffer, NULL, dataReady, makeDataReadyCallback, makeDataReadyRefcon, NULL, formatDescription, numSamples,
                        numSampleTimingEntries, sampleTimingArray, numSampleSizeEntries, sampleSizeArray, &sb);
    *sampleBufferOut = sb;
    return e;
}

OSStatus
CMSampleBufferCreateWithMakeDataReadyHandler(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMFormatDescriptionRef formatDescription,
                                             CMItemCount numSamples, CMItemCount numSampleTimingEntries, const CMSampleTimingInfo *sampleTimingArray,
                                             CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray, CMSampleBufferRef *sampleBufferOut,
                                             CMSampleBufferMakeDataReadyHandler makeDataReadyHandler)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb;
    OSStatus e = create(allocator, dataBuffer, NULL, dataReady, NULL, NULL, makeDataReadyHandler, formatDescription, numSamples, numSampleTimingEntries,
                        sampleTimingArray, numSampleSizeEntries, sampleSizeArray, &sb);
    *sampleBufferOut = sb;
    return e;
}

OSStatus
CMSampleBufferCreateReady(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, CMFormatDescriptionRef formatDescription, CMItemCount numSamples,
                          CMItemCount numSampleTimingEntries, const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries,
                          const size_t *sampleSizeArray, CMSampleBufferRef *sampleBufferOut)
{
    return CMSampleBufferCreate(allocator, dataBuffer, true, NULL, NULL, formatDescription, numSamples, numSampleTimingEntries, sampleTimingArray,
                                numSampleSizeEntries, sampleSizeArray, sampleBufferOut);
}

/* --- image buffers --- */

static OSStatus
create_image(CFAllocatorRef allocator, CVImageBufferRef imageBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback callback, void *refcon,
             CMSampleBufferMakeDataReadyHandler handler, CMVideoFormatDescriptionRef formatDescription, const CMSampleTimingInfo *sampleTiming,
             CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sampleBufferOut = NULL;
    if (!imageBuffer || !formatDescription || !sampleTiming)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!CMVideoFormatDescriptionMatchesImageBuffer(formatDescription, imageBuffer))
        return kCMSampleBufferError_InvalidMediaFormat;
    Mutable sb;
    OSStatus e = create(allocator, NULL, imageBuffer, dataReady, callback, refcon, handler, formatDescription, 1, 1, sampleTiming, 0, NULL, &sb);
    *sampleBufferOut = sb;
    return e;
}

OSStatus
CMSampleBufferCreateForImageBuffer(CFAllocatorRef allocator, CVImageBufferRef imageBuffer, Boolean dataReady,
                                   CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon,
                                   CMVideoFormatDescriptionRef formatDescription, const CMSampleTimingInfo *sampleTiming, CMSampleBufferRef *sampleBufferOut)
{
    return create_image(allocator, imageBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, NULL, formatDescription, sampleTiming,
                        sampleBufferOut);
}

OSStatus
CMSampleBufferCreateForImageBufferWithMakeDataReadyHandler(CFAllocatorRef allocator, CVImageBufferRef imageBuffer, Boolean dataReady,
                                                           CMVideoFormatDescriptionRef formatDescription, const CMSampleTimingInfo *sampleTiming,
                                                           CMSampleBufferRef *sampleBufferOut, CMSampleBufferMakeDataReadyHandler makeDataReadyHandler)
{
    return create_image(allocator, imageBuffer, dataReady, NULL, NULL, makeDataReadyHandler, formatDescription, sampleTiming, sampleBufferOut);
}

OSStatus
CMSampleBufferCreateReadyWithImageBuffer(CFAllocatorRef allocator, CVImageBufferRef imageBuffer, CMVideoFormatDescriptionRef formatDescription,
                                         const CMSampleTimingInfo *sampleTiming, CMSampleBufferRef *sampleBufferOut)
{
    return create_image(allocator, imageBuffer, true, NULL, NULL, NULL, formatDescription, sampleTiming, sampleBufferOut);
}

CVImageBufferRef
CMSampleBufferGetImageBuffer(CMSampleBufferRef sbuf)
{
    return sbuf ? sbuf->image : NULL;
}

/* --- tagged buffer groups --- */

OSStatus
CMSampleBufferCreateForTaggedBufferGroup(CFAllocatorRef allocator, CMTaggedBufferGroupRef taggedBufferGroup, CMTime sbufPTS, CMTime sbufDuration,
                                         CMTaggedBufferGroupFormatDescriptionRef formatDescription, CMSampleBufferRef *sBufOut)
{
    if (!sBufOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sBufOut = NULL;
    if (!taggedBufferGroup || !formatDescription)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!CMTaggedBufferGroupFormatDescriptionMatchesTaggedBufferGroup(formatDescription, taggedBufferGroup))
        return kCMSampleBufferError_InvalidMediaFormat;
    CMSampleTimingInfo t = {sbufDuration, sbufPTS, kCMTimeInvalid};
    Mutable sb;
    OSStatus e = create(allocator, NULL, NULL, true, NULL, NULL, NULL, formatDescription, 1, 1, &t, 0, NULL, &sb);
    if (!e)
        sb->group = (CMTaggedBufferGroupRef)CFRetain(taggedBufferGroup);
    *sBufOut = sb;
    return e;
}

CMTaggedBufferGroupRef
CMSampleBufferGetTaggedBufferGroup(CMSampleBufferRef sbuf)
{
    return sbuf ? sbuf->group : NULL;
}

/* --- audio --- */

static OSStatus
create_audio(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback callback, void *refcon,
             CMSampleBufferMakeDataReadyHandler handler, CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMTime presentationTimeStamp,
             const AudioStreamPacketDescription *packetDescriptions, CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sampleBufferOut = NULL;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd || numSamples <= 0)
        return kCMSampleBufferError_RequiredParameterMissing;
    int32_t rate = (int32_t)asbd->mSampleRate;
    bool constant = asbd->mBytesPerPacket && asbd->mFramesPerPacket;
    if (!constant && !packetDescriptions)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb;
    OSStatus e;
    if (constant && !packetDescriptions) {
        /* (PCM and the like: one sample a packet, its duration its frames over the rate) */
        CMSampleTimingInfo t = {CMTimeMake(asbd->mFramesPerPacket, rate), presentationTimeStamp, kCMTimeInvalid};
        size_t size = asbd->mBytesPerPacket;
        e = create(allocator, dataBuffer, NULL, dataReady, callback, refcon, handler, formatDescription, numSamples, 1, &t, 1, &size, &sb);
    } else if (asbd->mFramesPerPacket) {
        CMSampleTimingInfo t = {CMTimeMake(asbd->mFramesPerPacket, rate), presentationTimeStamp, kCMTimeInvalid};
        size_t *sizes = malloc(sizeof *sizes * (size_t)numSamples);
        for (CMItemCount i = 0; i < numSamples; i++)
            sizes[i] = packetDescriptions[i].mDataByteSize;
        e = create(allocator, dataBuffer, NULL, dataReady, callback, refcon, handler, formatDescription, numSamples, 1, &t, numSamples, sizes, &sb);
        free(sizes);
    } else {
        /* (frames per packet varying: each packet's own duration) */
        CMSampleTimingInfo *t = malloc(sizeof *t * (size_t)numSamples);
        size_t *sizes = malloc(sizeof *sizes * (size_t)numSamples);
        CMTime at = presentationTimeStamp;
        for (CMItemCount i = 0; i < numSamples; i++) {
            t[i] = (CMSampleTimingInfo){CMTimeMake(packetDescriptions[i].mVariableFramesInPacket, rate), at, kCMTimeInvalid};
            at = CMTimeAdd(at, t[i].duration);
            sizes[i] = packetDescriptions[i].mDataByteSize;
        }
        e = create(allocator, dataBuffer, NULL, dataReady, callback, refcon, handler, formatDescription, numSamples, numSamples, t, numSamples, sizes,
                   &sb);
        free(t);
        free(sizes);
    }
    if (!e && packetDescriptions) {
        sb->packetCount = numSamples;
        sb->packets = malloc(sizeof *packetDescriptions * (size_t)numSamples);
        memcpy(sb->packets, packetDescriptions, sizeof *packetDescriptions * (size_t)numSamples);
    }
    *sampleBufferOut = sb;
    return e;
}

OSStatus
CMAudioSampleBufferCreateWithPacketDescriptions(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady,
                                                CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon,
                                                CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMTime presentationTimeStamp,
                                                const AudioStreamPacketDescription *packetDescriptions, CMSampleBufferRef *sampleBufferOut)
{
    return create_audio(allocator, dataBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, NULL, formatDescription, numSamples,
                        presentationTimeStamp, packetDescriptions, sampleBufferOut);
}

OSStatus
CMAudioSampleBufferCreateWithPacketDescriptionsAndMakeDataReadyHandler(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady,
                                                                       CMFormatDescriptionRef formatDescription, CMItemCount numSamples,
                                                                       CMTime presentationTimeStamp,
                                                                       const AudioStreamPacketDescription *packetDescriptions,
                                                                       CMSampleBufferRef *sampleBufferOut,
                                                                       CMSampleBufferMakeDataReadyHandler makeDataReadyHandler)
{
    return create_audio(allocator, dataBuffer, dataReady, NULL, NULL, makeDataReadyHandler, formatDescription, numSamples, presentationTimeStamp,
                        packetDescriptions, sampleBufferOut);
}

OSStatus
CMAudioSampleBufferCreateReadyWithPacketDescriptions(CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, CMFormatDescriptionRef formatDescription,
                                                     CMItemCount numSamples, CMTime presentationTimeStamp,
                                                     const AudioStreamPacketDescription *packetDescriptions, CMSampleBufferRef *sampleBufferOut)
{
    return create_audio(allocator, dataBuffer, true, NULL, NULL, NULL, formatDescription, numSamples, presentationTimeStamp, packetDescriptions,
                        sampleBufferOut);
}

OSStatus
CMSampleBufferGetAudioStreamPacketDescriptions(CMSampleBufferRef sbuf, size_t packetDescriptionsSize, AudioStreamPacketDescription *packetDescriptionsOut,
                                               size_t *packetDescriptionsSizeNeededOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    size_t needed = sizeof(AudioStreamPacketDescription) * (size_t)sbuf->packetCount;
    if (packetDescriptionsSizeNeededOut)
        *packetDescriptionsSizeNeededOut = needed;
    if (packetDescriptionsOut) {
        if (packetDescriptionsSize < needed)
            return kCMSampleBufferError_ArrayTooSmall;
        memcpy(packetDescriptionsOut, sbuf->packets, needed);
    }
    return noErr;
}

OSStatus
CMSampleBufferGetAudioStreamPacketDescriptionsPtr(CMSampleBufferRef sbuf, const AudioStreamPacketDescription **packetDescriptionsPointerOut,
                                                  size_t *packetDescriptionsSizeOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (packetDescriptionsPointerOut)
        *packetDescriptionsPointerOut = sbuf->packets;
    if (packetDescriptionsSizeOut)
        *packetDescriptionsSizeOut = sizeof(AudioStreamPacketDescription) * (size_t)sbuf->packetCount;
    return noErr;
}

static const AudioStreamBasicDescription *
pcm_of(CMSampleBufferRef sbuf)
{
    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(sbuf->format);
    return a && a->mFormatID == kAudioFormatLinearPCM && a->mBytesPerFrame ? a : NULL;
}

OSStatus
CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(CMSampleBufferRef sbuf, size_t *bufferListSizeNeededOut, AudioBufferList *bufferListOut,
                                                        size_t bufferListSize, CFAllocatorRef blockBufferStructureAllocator,
                                                        CFAllocatorRef blockBufferBlockAllocator, uint32_t flags, CMBlockBufferRef *blockBufferOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(sbuf->format);
    if (!a)
        return kCMSampleBufferError_InvalidMediaTypeForOperation;
    bool planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && a->mChannelsPerFrame > 1;
    UInt32 buffers = planar ? a->mChannelsPerFrame : 1;
    size_t needed = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * buffers;
    if (bufferListSizeNeededOut)
        *bufferListSizeNeededOut = needed;
    if (!bufferListOut)
        return noErr;
    if (bufferListSize < needed)
        return kCMSampleBufferError_ArrayTooSmall;
    if (!sbuf->ready)
        return kCMSampleBufferError_BufferNotReady;
    if (!sbuf->data)
        return kCMSampleBufferError_RequiredParameterMissing;
    CMBlockBufferRef contiguous = NULL;
    OSStatus e = CMBlockBufferCreateContiguous(blockBufferStructureAllocator, sbuf->data, blockBufferBlockAllocator, NULL, 0, 0,
                                               (flags & kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment) ? 0 : 0, &contiguous);
    if (e)
        return e;
    char *p = NULL;
    size_t total = 0;
    CMBlockBufferGetDataPointer(contiguous, 0, NULL, &total, &p);
    bufferListOut->mNumberBuffers = buffers;
    for (UInt32 i = 0; i < buffers; i++) {
        size_t each = total / buffers;
        bufferListOut->mBuffers[i].mNumberChannels = planar ? 1 : a->mChannelsPerFrame;
        bufferListOut->mBuffers[i].mDataByteSize = (UInt32)each;
        bufferListOut->mBuffers[i].mData = p + each * i;
    }
    if (blockBufferOut)
        *blockBufferOut = contiguous;
    else
        CFRelease(contiguous);
    return noErr;
}

OSStatus
CMSampleBufferCopyPCMDataIntoAudioBufferList(CMSampleBufferRef sbuf, int32_t frameOffset, int32_t numFrames, AudioBufferList *bufferList)
{
    if (!sbuf || !bufferList)
        return kCMSampleBufferError_RequiredParameterMissing;
    const AudioStreamBasicDescription *a = pcm_of(sbuf);
    if (!a)
        return kCMSampleBufferError_InvalidMediaTypeForOperation;
    if (frameOffset < 0 || numFrames < 0 || frameOffset + numFrames > sbuf->numSamples)
        return kCMSampleBufferError_SampleIndexOutOfRange;
    if (!sbuf->data)
        return kCMSampleBufferError_RequiredParameterMissing;
    bool planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && a->mChannelsPerFrame > 1;
    UInt32 buffers = planar ? a->mChannelsPerFrame : 1;
    if (bufferList->mNumberBuffers != buffers)
        return kCMSampleBufferError_InvalidEntryCount;
    size_t frame = a->mBytesPerFrame, length = frame * (size_t)numFrames;
    for (UInt32 i = 0; i < buffers; i++) {
        if (bufferList->mBuffers[i].mDataByteSize < length)
            return kCMSampleBufferError_ArrayTooSmall;
        size_t channelStart = planar ? frame * (size_t)sbuf->numSamples * i : 0;
        OSStatus e = CMBlockBufferCopyDataBytes(sbuf->data, channelStart + frame * (size_t)frameOffset, length, bufferList->mBuffers[i].mData);
        if (e)
            return e;
        bufferList->mBuffers[i].mDataByteSize = (UInt32)length;
    }
    return noErr;
}

OSStatus
CMSampleBufferSetDataBufferFromAudioBufferList(CMSampleBufferRef sbuf, CFAllocatorRef blockBufferStructureAllocator,
                                               CFAllocatorRef blockBufferBlockAllocator, uint32_t flags, const AudioBufferList *bufferList)
{
    if (!sbuf || !bufferList)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (sbuf->data)
        return kCMSampleBufferError_AlreadyHasDataBuffer;
    size_t total = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++)
        total += bufferList->mBuffers[i].mDataByteSize;
    CMBlockBufferRef bb = NULL;
    OSStatus e = CMBlockBufferCreateWithMemoryBlock(blockBufferStructureAllocator, NULL, total, blockBufferBlockAllocator, NULL, 0, total,
                                                    kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (e)
        return e;
    size_t at = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        if (bufferList->mBuffers[i].mDataByteSize)
            CMBlockBufferReplaceDataBytes(bufferList->mBuffers[i].mData, bb, at, bufferList->mBuffers[i].mDataByteSize);
        at += bufferList->mBuffers[i].mDataByteSize;
    }
    e = CMSampleBufferSetDataBuffer(sbuf, bb);
    CFRelease(bb);
    return e;
}

/* --- data and readiness --- */

OSStatus
CMSampleBufferSetDataBuffer(CMSampleBufferRef sbuf, CMBlockBufferRef dataBuffer)
{
    if (!sbuf || !dataBuffer)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    OSStatus e = noErr;
    if (sb->data || sb->image)
        e = kCMSampleBufferError_AlreadyHasDataBuffer;
    else
        sb->data = (CMBlockBufferRef)CFRetain(dataBuffer);
    pthread_mutex_unlock(&sb->lock);
    return e;
}

CMBlockBufferRef
CMSampleBufferGetDataBuffer(CMSampleBufferRef sbuf)
{
    return sbuf ? sbuf->data : NULL;
}

CMFormatDescriptionRef
CMSampleBufferGetFormatDescription(CMSampleBufferRef sbuf)
{
    return sbuf ? sbuf->format : NULL;
}

static void post_ready(CMSampleBufferRef sbuf);

OSStatus
CMSampleBufferSetDataReady(CMSampleBufferRef sbuf)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    OSStatus failed = sb->failed;
    bool was = sb->ready;
    if (!failed)
        sb->ready = true;
    pthread_mutex_unlock(&sb->lock);
    if (failed)
        return failed;
    if (!was)
        post_ready(sbuf);
    return noErr;
}

Boolean
CMSampleBufferDataIsReady(CMSampleBufferRef sbuf)
{
    if (!sbuf)
        return false;
    Mutable sb = (Mutable)sbuf;
    if (!sb->ready && sb->tracking && CMSampleBufferDataIsReady(sb->tracking))
        sb->ready = true;
    return sb->ready;
}

OSStatus
CMSampleBufferSetDataFailed(CMSampleBufferRef sbuf, OSStatus status)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (sbuf->data && sbuf->ready)
        return kCMSampleBufferError_AlreadyHasDataBuffer;
    ((Mutable)sbuf)->failed = status;
    return noErr;
}

Boolean
CMSampleBufferHasDataFailed(CMSampleBufferRef sbuf, OSStatus *statusOut)
{
    OSStatus f = sbuf ? sbuf->failed : 0;
    if (statusOut)
        *statusOut = f;
    return f != 0;
}

OSStatus
CMSampleBufferMakeDataReady(CMSampleBufferRef sbuf)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    if (CMSampleBufferDataIsReady(sbuf))
        return noErr;
    if (sb->failed)
        return sb->failed;
    OSStatus e;
    if (sb->readyCallback)
        e = sb->readyCallback(sbuf, sb->readyRefcon);
    else if (sb->readyHandler)
        e = sb->readyHandler(sbuf);
    else
        return kCMSampleBufferError_BufferNotReady;
    if (!e)
        CMSampleBufferSetDataReady(sbuf);
    return e;
}

OSStatus
CMSampleBufferTrackDataReadiness(CMSampleBufferRef sbuf, CMSampleBufferRef sampleBufferToTrack)
{
    if (!sbuf || !sampleBufferToTrack)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid || !sampleBufferToTrack->valid)
        return kCMSampleBufferError_Invalidated;
    if (sbuf->data || sbuf->image)
        return kCMSampleBufferError_AlreadyHasDataBuffer;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    if (sb->tracking)
        CFRelease(sb->tracking);
    sb->tracking = (CMSampleBufferRef)CFRetain(sampleBufferToTrack);
    pthread_mutex_unlock(&sb->lock);
    return noErr;
}

/* --- validity --- */

OSStatus
CMSampleBufferSetInvalidateCallback(CMSampleBufferRef sbuf, CMSampleBufferInvalidateCallback invalidateCallback, uint64_t invalidateRefCon)
{
    if (!sbuf || !invalidateCallback)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    OSStatus e = noErr;
    if (!sb->valid)
        e = kCMSampleBufferError_Invalidated;
    else if (sb->invalidateSet)
        e = kCMSampleBufferError_RequiredParameterMissing;
    else {
        sb->invalidateSet = true;
        sb->invalidateCallback = invalidateCallback;
        sb->invalidateRefcon = invalidateRefCon;
    }
    pthread_mutex_unlock(&sb->lock);
    return e;
}

OSStatus
CMSampleBufferSetInvalidateHandler(CMSampleBufferRef sbuf, CMSampleBufferInvalidateHandler invalidateHandler)
{
    if (!sbuf || !invalidateHandler)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    OSStatus e = noErr;
    if (!sb->valid)
        e = kCMSampleBufferError_Invalidated;
    else if (sb->invalidateSet)
        e = kCMSampleBufferError_RequiredParameterMissing;
    else {
        sb->invalidateSet = true;
        sb->invalidateHandler = Block_copy(invalidateHandler);
    }
    pthread_mutex_unlock(&sb->lock);
    return e;
}

OSStatus
CMSampleBufferInvalidate(CMSampleBufferRef sbuf)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    if (!sb->valid) {
        pthread_mutex_unlock(&sb->lock);
        return kCMSampleBufferError_Invalidated;
    }
    sb->valid = false;
    pthread_mutex_unlock(&sb->lock);
    if (sb->invalidateCallback)
        sb->invalidateCallback(sbuf, sb->invalidateRefcon);
    if (sb->invalidateHandler)
        sb->invalidateHandler(sbuf);
    return noErr;
}

Boolean
CMSampleBufferIsValid(CMSampleBufferRef sbuf)
{
    return sbuf && sbuf->valid;
}

/* --- samples, sizes, timing --- */

CMItemCount
CMSampleBufferGetNumSamples(CMSampleBufferRef sbuf)
{
    return sbuf && sbuf->valid ? sbuf->numSamples : 0;
}

/* One sample's timing, from one entry for all (laid end to end) or its own. */
static CMSampleTimingInfo
timing_of(CMSampleBufferRef sb, CMItemIndex i)
{
    if (sb->timingCount != 1 || sb->numSamples <= 1)
        return sb->timing[sb->timingCount == 1 ? 0 : i];
    CMSampleTimingInfo t = sb->timing[0];
    if (!CMTIME_IS_NUMERIC(t.duration)) {
        t.presentationTimeStamp = t.decodeTimeStamp = kCMTimeInvalid;
        return t;
    }
    CMTime offset = CMTimeMultiply(t.duration, (int32_t)i);
    if (i && CMTIME_IS_VALID(t.presentationTimeStamp))
        t.presentationTimeStamp = CMTimeAdd(t.presentationTimeStamp, offset);
    if (i && CMTIME_IS_VALID(t.decodeTimeStamp))
        t.decodeTimeStamp = CMTimeAdd(t.decodeTimeStamp, offset);
    return t;
}

CMTime
CMSampleBufferGetDuration(CMSampleBufferRef sbuf)
{
    if (!sbuf || !sbuf->valid)
        return kCMTimeInvalid;
    if (!sbuf->timingCount)
        return sbuf->numSamples ? kCMTimeInvalid : kCMTimeZero;
    if (sbuf->timingCount == 1)
        return CMTIME_IS_NUMERIC(sbuf->timing[0].duration) ? CMTimeMultiply(sbuf->timing[0].duration, (int32_t)sbuf->numSamples) : kCMTimeInvalid;
    CMTime total = kCMTimeZero;
    for (CMItemCount i = 0; i < sbuf->timingCount; i++) {
        if (!CMTIME_IS_NUMERIC(sbuf->timing[i].duration))
            return kCMTimeInvalid;
        total = i ? CMTimeAdd(total, sbuf->timing[i].duration) : sbuf->timing[i].duration;
    }
    return total;
}

/* The earliest of the samples' times (presentation, or decode). */
static CMTime
earliest(CMSampleBufferRef sbuf, bool decode)
{
    if (!sbuf || !sbuf->valid || !sbuf->timingCount)
        return kCMTimeInvalid;
    CMTime best = kCMTimeInvalid;
    for (CMItemCount i = 0; i < sbuf->timingCount; i++) {
        CMTime t = decode ? sbuf->timing[i].decodeTimeStamp : sbuf->timing[i].presentationTimeStamp;
        if (CMTIME_IS_VALID(t) && (!CMTIME_IS_VALID(best) || CMTimeCompare(t, best) < 0))
            best = t;
    }
    return best;
}

CMTime
CMSampleBufferGetPresentationTimeStamp(CMSampleBufferRef sbuf)
{
    return earliest(sbuf, false);
}

CMTime
CMSampleBufferGetDecodeTimeStamp(CMSampleBufferRef sbuf)
{
    return earliest(sbuf, true);
}

static CMTime
trim(CMSampleBufferRef sbuf, CFStringRef key)
{
    CFTypeRef d = CMGetAttachment(sbuf, key, NULL);
    return d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? CMTimeMakeFromDictionary(d) : kCMTimeInvalid;
}

static double
speed(CMSampleBufferRef sbuf)
{
    CFTypeRef n = CMGetAttachment(sbuf, kCMSampleBufferAttachmentKey_SpeedMultiplier, NULL);
    double v = 1;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v > 0 ? v : 1;
}

/* A duration less the trims, at the speed. */
static CMTime
output_duration(CMSampleBufferRef sbuf, CMTime d, bool first, bool last)
{
    if (!CMTIME_IS_NUMERIC(d))
        return d;
    CMTime start = trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtStart), end = trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtEnd);
    if (first && CMTIME_IS_NUMERIC(start))
        d = CMTimeSubtract(d, start);
    if (last && CMTIME_IS_NUMERIC(end))
        d = CMTimeSubtract(d, end);
    double s = speed(sbuf);
    return s != 1 ? CMTimeMultiplyByFloat64(d, 1 / s) : d;
}

CMTime
CMSampleBufferGetOutputPresentationTimeStamp(CMSampleBufferRef sbuf)
{
    if (!sbuf || !sbuf->valid)
        return kCMTimeInvalid;
    if (CMTIME_IS_VALID(sbuf->outputPTS))
        return sbuf->outputPTS;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sbuf), start = trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtStart);
    return CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(start) ? CMTimeAdd(pts, start) : pts;
}

OSStatus
CMSampleBufferSetOutputPresentationTimeStamp(CMSampleBufferRef sbuf, CMTime outputPresentationTimeStamp)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    ((Mutable)sbuf)->outputPTS = outputPresentationTimeStamp;
    return noErr;
}

CMTime
CMSampleBufferGetOutputDuration(CMSampleBufferRef sbuf)
{
    if (!sbuf || !sbuf->valid)
        return kCMTimeInvalid;
    return output_duration(sbuf, CMSampleBufferGetDuration(sbuf), true, true);
}

CMTime
CMSampleBufferGetOutputDecodeTimeStamp(CMSampleBufferRef sbuf)
{
    CMTime dts = CMSampleBufferGetDecodeTimeStamp(sbuf);
    if (!CMTIME_IS_NUMERIC(dts))
        return dts;
    CMTime shift = CMTimeSubtract(CMSampleBufferGetOutputPresentationTimeStamp(sbuf), CMSampleBufferGetPresentationTimeStamp(sbuf));
    return CMTIME_IS_NUMERIC(shift) ? CMTimeAdd(dts, shift) : dts;
}

OSStatus
CMSampleBufferGetSampleTimingInfoArray(CMSampleBufferRef sbuf, CMItemCount numSampleTimingEntries, CMSampleTimingInfo *timingArrayOut,
                                       CMItemCount *timingArrayEntriesNeededOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (timingArrayEntriesNeededOut)
        *timingArrayEntriesNeededOut = sbuf->timingCount;
    if (!sbuf->timingCount)
        return kCMSampleBufferError_BufferHasNoSampleTimingInfo;
    if (timingArrayOut) {
        if (numSampleTimingEntries < sbuf->timingCount)
            return kCMSampleBufferError_ArrayTooSmall;
        memcpy(timingArrayOut, sbuf->timing, sizeof *timingArrayOut * (size_t)sbuf->timingCount);
    }
    return noErr;
}

OSStatus
CMSampleBufferGetOutputSampleTimingInfoArray(CMSampleBufferRef sbuf, CMItemCount timingArrayEntries, CMSampleTimingInfo *timingArrayOut,
                                             CMItemCount *timingArrayEntriesNeededOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (!sbuf->timingCount)
        return kCMSampleBufferError_BufferHasNoSampleTimingInfo;
    if (sbuf->timingCount == 1 && CMTIME_IS_NUMERIC(sbuf->timing[0].duration) &&
        !CMTIME_IS_NUMERIC(trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtStart)) &&
        !CMTIME_IS_NUMERIC(trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtEnd)) &&
        speed(sbuf) == 1 && !CMTIME_IS_VALID(sbuf->outputPTS)) {
        if (timingArrayEntriesNeededOut)
            *timingArrayEntriesNeededOut = 1;
        if (!timingArrayOut)
            return noErr;
        if (timingArrayEntries < 1)
            return kCMSampleBufferError_ArrayTooSmall;
        timingArrayOut[0] = sbuf->timing[0];
        return noErr;
    }
    CMItemCount n = sbuf->numSamples;
    if (timingArrayEntriesNeededOut)
        *timingArrayEntriesNeededOut = n;
    if (!timingArrayOut)
        return noErr;
    if (timingArrayEntries < n)
        return kCMSampleBufferError_ArrayTooSmall;
    /* (each sample at the output time plus its own offset from the first, less the start
       trim, at the speed) */
    CMTime out = CMSampleBufferGetOutputPresentationTimeStamp(sbuf), first = CMSampleBufferGetPresentationTimeStamp(sbuf);
    CMTime start = trim(sbuf, kCMSampleBufferAttachmentKey_TrimDurationAtStart);
    CMTime dtsShift = CMTimeSubtract(out, first);
    double s = speed(sbuf);
    for (CMItemCount i = 0; i < n; i++) {
        CMSampleTimingInfo t = timing_of(sbuf, i);
        CMSampleTimingInfo o;
        o.duration = output_duration(sbuf, t.duration, i == 0, i == n - 1);
        if (i == 0 || !CMTIME_IS_NUMERIC(t.presentationTimeStamp))
            o.presentationTimeStamp = i == 0 ? out : kCMTimeInvalid;
        else {
            CMTime offset = CMTimeSubtract(t.presentationTimeStamp, first);
            if (CMTIME_IS_NUMERIC(start))
                offset = CMTimeSubtract(offset, start);
            o.presentationTimeStamp = CMTimeAdd(out, s != 1 ? CMTimeMultiplyByFloat64(offset, 1 / s) : offset);
        }
        o.decodeTimeStamp = CMTIME_IS_NUMERIC(t.decodeTimeStamp) && CMTIME_IS_NUMERIC(dtsShift) ? CMTimeAdd(t.decodeTimeStamp, dtsShift) : kCMTimeInvalid;
        timingArrayOut[i] = o;
    }
    return noErr;
}

OSStatus
CMSampleBufferGetSampleTimingInfo(CMSampleBufferRef sbuf, CMItemIndex sampleIndex, CMSampleTimingInfo *timingInfoOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (!sbuf->timingCount)
        return kCMSampleBufferError_BufferHasNoSampleTimingInfo;
    if (sampleIndex < 0 || sampleIndex >= sbuf->numSamples)
        return kCMSampleBufferError_SampleIndexOutOfRange;
    if (timingInfoOut)
        *timingInfoOut = timing_of(sbuf, sampleIndex);
    return noErr;
}

OSStatus
CMSampleBufferGetSampleSizeArray(CMSampleBufferRef sbuf, CMItemCount sizeArrayEntries, size_t *sizeArrayOut, CMItemCount *sizeArrayEntriesNeededOut)
{
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (sizeArrayEntriesNeededOut)
        *sizeArrayEntriesNeededOut = sbuf->sizeCount;
    if (!sbuf->sizeCount)
        return kCMSampleBufferError_BufferHasNoSampleSizes;
    if (sizeArrayOut) {
        if (sizeArrayEntries < sbuf->sizeCount)
            return kCMSampleBufferError_ArrayTooSmall;
        memcpy(sizeArrayOut, sbuf->sizes, sizeof *sizeArrayOut * (size_t)sbuf->sizeCount);
    }
    return noErr;
}

size_t
CMSampleBufferGetSampleSize(CMSampleBufferRef sbuf, CMItemIndex sampleIndex)
{
    if (!sbuf || !sbuf->valid || !sbuf->sizeCount || sampleIndex < 0 || sampleIndex >= sbuf->numSamples)
        return 0;
    return sbuf->sizes[sbuf->sizeCount == 1 ? 0 : sampleIndex];
}

size_t
CMSampleBufferGetTotalSampleSize(CMSampleBufferRef sbuf)
{
    if (!sbuf || !sbuf->valid)
        return 0;
    if (sbuf->image)
        return CVPixelBufferGetDataSize(sbuf->image);
    if (sbuf->sizeCount == 1)
        return sbuf->sizes[0] * (size_t)sbuf->numSamples;
    size_t total = 0;
    for (CMItemCount i = 0; i < sbuf->sizeCount; i++)
        total += sbuf->sizes[i];
    return total;
}

/* --- copies --- */

static void
copy_attachments(Mutable to, CMSampleBufferRef from)
{
    CMPropagateAttachments(from, to);
}

OSStatus
CMSampleBufferCreateCopy(CFAllocatorRef allocator, CMSampleBufferRef sbuf, CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sampleBufferOut = NULL;
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    Mutable sb;
    OSStatus e = create(allocator, sbuf->data, sbuf->image, sbuf->ready, sbuf->readyCallback, sbuf->readyRefcon, sbuf->readyHandler, sbuf->format,
                        sbuf->numSamples, sbuf->timingCount, sbuf->timing, sbuf->sizeCount, sbuf->sizes, &sb);
    if (e)
        return e;
    if (sbuf->packetCount) {
        sb->packetCount = sbuf->packetCount;
        sb->packets = malloc(sizeof *sb->packets * (size_t)sb->packetCount);
        memcpy(sb->packets, sbuf->packets, sizeof *sb->packets * (size_t)sb->packetCount);
    }
    sb->failed = sbuf->failed;
    sb->outputPTS = sbuf->outputPTS;
    copy_attachments(sb, sbuf);
    *sampleBufferOut = sb;
    return noErr;
}

OSStatus
CMSampleBufferCreateCopyWithNewTiming(CFAllocatorRef allocator, CMSampleBufferRef originalSBuf, CMItemCount numSampleTimingEntries,
                                      const CMSampleTimingInfo *sampleTimingArray, CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sampleBufferOut = NULL;
    if (!originalSBuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (numSampleTimingEntries != 0 && numSampleTimingEntries != 1 && numSampleTimingEntries != originalSBuf->numSamples)
        return kCMSampleBufferError_InvalidEntryCount;
    CMSampleBufferRef copy = NULL;
    OSStatus e = CMSampleBufferCreateCopy(allocator, originalSBuf, &copy);
    if (e)
        return e;
    if ((e = set_timing((Mutable)copy, numSampleTimingEntries, sampleTimingArray))) {
        CFRelease(copy);
        return e;
    }
    ((Mutable)copy)->outputPTS = kCMTimeInvalid;
    *sampleBufferOut = copy;
    return noErr;
}

OSStatus
CMSampleBufferCopySampleBufferForRange(CFAllocatorRef allocator, CMSampleBufferRef sbuf, CFRange sampleRange, CMSampleBufferRef *sampleBufferOut)
{
    if (!sampleBufferOut)
        return kCMSampleBufferError_RequiredParameterMissing;
    *sampleBufferOut = NULL;
    if (!sbuf)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!sbuf->valid)
        return kCMSampleBufferError_Invalidated;
    if (sampleRange.location < 0 || sampleRange.length <= 0 || sampleRange.location + sampleRange.length > sbuf->numSamples)
        return kCMSampleBufferError_SampleIndexOutOfRange;
    if (sbuf->numSamples > 1 && !sbuf->sizeCount && sbuf->data)
        return kCMSampleBufferError_CannotSubdivide;
    CFIndex from = sampleRange.location, n = sampleRange.length;
    /* (the bytes of those samples, by reference) */
    CMBlockBufferRef data = NULL;
    if (sbuf->data && sbuf->sizeCount) {
        size_t offset = 0, length = 0;
        for (CFIndex i = 0; i < from + n; i++) {
            if (i < from)
                offset += CMSampleBufferGetSampleSize(sbuf, i);
            else
                length += CMSampleBufferGetSampleSize(sbuf, i);
        }
        OSStatus e = length ? CMBlockBufferCreateWithBufferReference(allocator, sbuf->data, offset, length, 0, &data) : noErr;
        if (e)
            return e;
    } else if (sbuf->data)
        data = (CMBlockBufferRef)CFRetain(sbuf->data);
    CMSampleTimingInfo *timing = NULL;
    CMItemCount timingCount = 0;
    if (sbuf->timingCount == 1) {
        timing = malloc(sizeof *timing);
        timing[0] = timing_of(sbuf, from);
        if (!CMTIME_IS_NUMERIC(sbuf->timing[0].duration))
            timing[0] = sbuf->timing[0];
        timingCount = 1;
    } else if (sbuf->timingCount) {
        timing = malloc(sizeof *timing * (size_t)n);
        memcpy(timing, sbuf->timing + from, sizeof *timing * (size_t)n);
        timingCount = n;
    }
    CMItemCount sizeCount = sbuf->sizeCount == 1 ? 1 : sbuf->sizeCount ? n : 0;
    const size_t *sizes = sbuf->sizeCount == 1 ? sbuf->sizes : sbuf->sizes ? sbuf->sizes + from : NULL;
    Mutable sb;
    OSStatus e = create(allocator, data, sbuf->image, sbuf->ready, sbuf->readyCallback, sbuf->readyRefcon, sbuf->readyHandler, sbuf->format, n,
                        timingCount, timing, sizeCount, sizes, &sb);
    free(timing);
    if (data)
        CFRelease(data);
    if (e)
        return e;
    if (sbuf->packetCount) {
        sb->packetCount = n;
        sb->packets = malloc(sizeof *sb->packets * (size_t)n);
        long long base = sbuf->packets[from].mStartOffset;
        for (CFIndex i = 0; i < n; i++) {
            sb->packets[i] = sbuf->packets[from + i];
            sb->packets[i].mStartOffset -= base;
        }
    }
    if (sbuf->sampleAttachments) {
        sb->sampleAttachments = CFArrayCreateMutable(allocator, n, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(sbuf->sampleAttachments, from + i);
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(allocator, 0, d);
            CFArrayAppendValue(sb->sampleAttachments, m);
            CFRelease(m);
        }
    }
    copy_attachments(sb, sbuf);
    *sampleBufferOut = sb;
    return noErr;
}

OSStatus
CMSampleBufferCallForEachSample(CMSampleBufferRef sbuf, OSStatus (*callback)(CMSampleBufferRef sampleBuffer, CMItemCount index, void *refcon),
                                void *refcon)
{
    if (!sbuf || !callback)
        return kCMSampleBufferError_RequiredParameterMissing;
    for (CMItemCount i = 0; i < CMSampleBufferGetNumSamples(sbuf); i++) {
        CMSampleBufferRef one = NULL;
        OSStatus e = CMSampleBufferCopySampleBufferForRange(NULL, sbuf, CFRangeMake(i, 1), &one);
        if (e)
            return e;
        e = callback(one, i, refcon);
        CFRelease(one);
        if (e)
            return e;
    }
    return noErr;
}

OSStatus
CMSampleBufferCallBlockForEachSample(CMSampleBufferRef sbuf, OSStatus (^handler)(CMSampleBufferRef, CMItemCount))
{
    if (!sbuf || !handler)
        return kCMSampleBufferError_RequiredParameterMissing;
    for (CMItemCount i = 0; i < CMSampleBufferGetNumSamples(sbuf); i++) {
        CMSampleBufferRef one = NULL;
        OSStatus e = CMSampleBufferCopySampleBufferForRange(NULL, sbuf, CFRangeMake(i, 1), &one);
        if (e)
            return e;
        e = handler(one, i);
        CFRelease(one);
        if (e)
            return e;
    }
    return noErr;
}

/* --- sample attachments --- */

CFArrayRef
CMSampleBufferGetSampleAttachmentsArray(CMSampleBufferRef sbuf, Boolean createIfNecessary)
{
    if (!sbuf || !sbuf->valid)
        return NULL;
    Mutable sb = (Mutable)sbuf;
    pthread_mutex_lock(&sb->lock);
    if (!sb->sampleAttachments && createIfNecessary && sb->numSamples > 0) {
        sb->sampleAttachments = CFArrayCreateMutable(NULL, sb->numSamples, &kCFTypeArrayCallBacks);
        for (CMItemCount i = 0; i < sb->numSamples; i++) {
            CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(sb->sampleAttachments, d);
            CFRelease(d);
        }
    }
    CFArrayRef a = sb->sampleAttachments;
    pthread_mutex_unlock(&sb->lock);
    return a;
}

/* --- notifications and description --- */

extern void _FinchCMPostDataBecameReady(CMSampleBufferRef sbuf);

static void
post_ready(CMSampleBufferRef sbuf)
{
    _FinchCMPostDataBecameReady(sbuf);
}

static CFStringRef
copy_description(CFTypeRef cf)
{
    CMSampleBufferRef sb = (CMSampleBufferRef)cf;
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("CMSampleBuffer %p retainCount: %ld allocator: %p\n\tinvalid = %s\n\tdataReady = %s\n"), cf,
                         (long)CFGetRetainCount(cf), CFGetAllocator(cf), sb->valid ? "NO" : "YES", sb->ready ? "YES" : "NO");
    CFDictionaryRef p = CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldPropagate);
    CFDictionaryRef n = CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldNotPropagate);
    CFStringAppendFormat(s, NULL, CFSTR("\tpropagate attachments = %@\n\tnon-propagate attachments = %@\n"), p, n);
    if (p)
        CFRelease(p);
    if (n)
        CFRelease(n);
    if (sb->format)
        CFStringAppendFormat(s, NULL, CFSTR("\tformatDescription = %@\n"), sb->format);
    CFStringAppendFormat(s, NULL, CFSTR("\tsbufToTrackReadiness = %p\n\tnumSamples = %ld\n"), sb->tracking, (long)sb->numSamples);
    for (CMItemCount i = 0; i < sb->timingCount; i++) {
        CFStringRef d = CMTimeCopyDescription(NULL, sb->timing[i].duration), pt = CMTimeCopyDescription(NULL, sb->timing[i].presentationTimeStamp),
                    dt = CMTimeCopyDescription(NULL, sb->timing[i].decodeTimeStamp);
        CFStringAppendFormat(s, NULL, CFSTR("\tsampleTimingArray[%ld] = {\n\t\tPTS = %@, DTS = %@, duration = %@\n\t}\n"), (long)i, pt, dt, d);
        CFRelease(d);
        CFRelease(pt);
        CFRelease(dt);
    }
    for (CMItemCount i = 0; i < sb->sizeCount; i++)
        CFStringAppendFormat(s, NULL, CFSTR("\tsampleSizeArray[%ld] = {\n\t\tsampleSize = %zu,\n\t}\n"), (long)i, sb->sizes[i]);
    if (sb->data)
        CFStringAppendFormat(s, NULL, CFSTR("\tdataBuffer = %@\n"), sb->data);
    if (sb->image)
        CFStringAppendFormat(s, NULL, CFSTR("\timageBuffer = %@\n"), sb->image);
    return s;
}

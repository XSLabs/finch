/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Device-free PCM queues and explicit offline output for Finch. */
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FINCH_QUEUE_COUNT 64
#define FINCH_QUEUE_BUFFER_COUNT 32
#define FINCH_QUEUE_BUFFER_BYTES (8U * 1024U * 1024U)
#define FINCH_QUEUE_TOTAL_BYTES (64U * 1024U * 1024U)
#define FINCH_QUEUE_MAX_FRAMES 65536U
#define FINCH_QUEUE_SIGNATURE UINT32_C(0x46415131)
#define FINCH_PARAM_ERROR (-50)
#define FINCH_MEMORY_ERROR (-108)

struct BufferRecord {
    AudioQueueBufferRef buffer;
    struct BufferRecord *allNext;
    struct BufferRecord *queueNext;
    UInt32 offsetFrames;
    Boolean queued;
    Boolean callbackPending;
};

struct ListenerRecord {
    AudioQueuePropertyID property;
    AudioQueuePropertyListenerProc callback;
    void *userData;
    struct ListenerRecord *next;
};

struct OpaqueAudioQueueTimeline {
    AudioQueueRef owner;
    UInt64 discontinuityGeneration;
    struct OpaqueAudioQueueTimeline *next;
};

struct OpaqueAudioQueue {
    UInt32 signature;
    pthread_mutex_t lock;
    Boolean isInput;
    Boolean running;
    Boolean resetting;
    Boolean offlineActive;
    Boolean notifying;
    AudioQueueOutputCallback outputCallback;
    AudioQueueInputCallback inputCallback;
    void *userData;
    AudioStreamBasicDescription format;
    AudioStreamBasicDescription offlineFormat;
    AudioConverterRef converter;
    Boolean offlineConfigured;
    UInt32 decodeBufferFrames;
    UInt32 converterError;
    UInt32 bufferCount;
    UInt32 queuedCount;
    UInt64 allocatedBytes;
    struct BufferRecord *buffers;
    struct BufferRecord *queueHead;
    struct BufferRecord *queueTail;
    struct ListenerRecord *listeners;
    struct OpaqueAudioQueueTimeline *timelines;
    Float64 sampleTime;
    Boolean sampleTimeValid;
    UInt64 discontinuityGeneration;
    Boolean rendered;
};

static _Atomic(AudioQueueRef) queues[FINCH_QUEUE_COUNT];
static pthread_mutex_t registryLock = PTHREAD_MUTEX_INITIALIZER;

static Boolean
valid_pcm_format(const AudioStreamBasicDescription *format)
{
    if (!format || format->mFormatID != kAudioFormatLinearPCM ||
        !isfinite(format->mSampleRate) || format->mSampleRate <= 0.0 ||
        !format->mChannelsPerFrame || format->mChannelsPerFrame > 32 ||
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ||
        format->mFramesPerPacket != 1 || !format->mBytesPerFrame ||
        format->mBytesPerPacket != format->mBytesPerFrame)
        return false;

    Boolean floating = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bits = format->mBitsPerChannel;
    if (floating ? (bits != 32 && bits != 64) :
        (bits != 8 && bits != 16 && bits != 20 && bits != 24 && bits != 32))
        return false;
    UInt32 bytes = (bits + 7) / 8;
    if (!(format->mFormatFlags & kAudioFormatFlagIsPacked) && bits < 32)
        bytes = 4;
    if (format->mBytesPerFrame != bytes * format->mChannelsPerFrame)
        return false;
    if ((format->mFormatFlags & kAudioFormatFlagIsPacked) && bits % 8)
        return false;
    return true;
}

/* Locking the registry while taking the queue lock keeps dispose from racing a call. */
static AudioQueueRef
lock_queue(AudioQueueRef handle)
{
    if (!handle)
        return NULL;
    pthread_mutex_lock(&registryLock);
    AudioQueueRef found = NULL;
    for (UInt32 i = 0; i < FINCH_QUEUE_COUNT; i++) {
        AudioQueueRef candidate = atomic_load_explicit(&queues[i], memory_order_acquire);
        if (candidate == handle) {
            found = candidate;
            pthread_mutex_lock(&found->lock);
            break;
        }
    }
    pthread_mutex_unlock(&registryLock);
    if (found && found->signature != FINCH_QUEUE_SIGNATURE) {
        pthread_mutex_unlock(&found->lock);
        return NULL;
    }
    return found;
}

static void
unlock_queue(AudioQueueRef queue)
{
    pthread_mutex_unlock(&queue->lock);
}

static OSStatus
create_queue(const AudioStreamBasicDescription *format, Boolean isInput,
    AudioQueueOutputCallback outputCallback, AudioQueueInputCallback inputCallback,
    void *userData, UInt32 flags, AudioQueueRef *outQueue)
{
    if (outQueue)
        *outQueue = NULL;
    if (!outQueue || flags || !valid_pcm_format(format))
        return kAudioQueueErr_InvalidPropertyValue;
    AudioQueueRef queue = calloc(1, sizeof(*queue));
    if (!queue)
        return FINCH_MEMORY_ERROR;
    queue->signature = FINCH_QUEUE_SIGNATURE;
    queue->isInput = isInput;
    queue->outputCallback = outputCallback;
    queue->inputCallback = inputCallback;
    queue->userData = userData;
    queue->format = *format;
    queue->decodeBufferFrames = 4096;
    pthread_mutex_init(&queue->lock, NULL);

    pthread_mutex_lock(&registryLock);
    UInt32 slot;
    for (slot = 0; slot < FINCH_QUEUE_COUNT; slot++)
        if (!atomic_load_explicit(&queues[slot], memory_order_relaxed))
            break;
    if (slot < FINCH_QUEUE_COUNT)
        atomic_store_explicit(&queues[slot], queue, memory_order_release);
    pthread_mutex_unlock(&registryLock);
    if (slot == FINCH_QUEUE_COUNT) {
        pthread_mutex_destroy(&queue->lock);
        free(queue);
        return kAudioQueueErr_CannotStart;
    }
    *outQueue = queue;
    return noErr;
}

OSStatus
AudioQueueNewOutput(const AudioStreamBasicDescription *format, AudioQueueOutputCallback callback,
    void *userData, CFRunLoopRef runLoop, CFStringRef runLoopMode, UInt32 flags,
    AudioQueueRef *outQueue)
{
    (void)runLoop;
    (void)runLoopMode;
    return create_queue(format, false, callback, NULL, userData, flags, outQueue);
}

OSStatus
AudioQueueNewInput(const AudioStreamBasicDescription *format, AudioQueueInputCallback callback,
    void *userData, CFRunLoopRef runLoop, CFStringRef runLoopMode, UInt32 flags,
    AudioQueueRef *outQueue)
{
    (void)runLoop;
    (void)runLoopMode;
    return create_queue(format, true, NULL, callback, userData, flags, outQueue);
}

#if defined(__BLOCKS__)
OSStatus
AudioQueueNewOutputWithDispatchQueue(AudioQueueRef *outQueue, const AudioStreamBasicDescription *format,
    UInt32 flags, dispatch_queue_t dispatchQueue, AudioQueueOutputCallbackBlock callback)
{
    (void)format; (void)flags; (void)dispatchQueue; (void)callback;
    if (outQueue)
        *outQueue = NULL;
    return kAudioQueueErr_InvalidPropertyValue;
}

OSStatus
AudioQueueNewInputWithDispatchQueue(AudioQueueRef *outQueue, const AudioStreamBasicDescription *format,
    UInt32 flags, dispatch_queue_t dispatchQueue, AudioQueueInputCallbackBlock callback)
{
    (void)format; (void)flags; (void)dispatchQueue; (void)callback;
    if (outQueue)
        *outQueue = NULL;
    return kAudioQueueErr_InvalidPropertyValue;
}
#endif

static struct BufferRecord *
find_buffer(AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    for (struct BufferRecord *record = queue->buffers; record; record = record->allNext)
        if (record->buffer == buffer)
            return record;
    return NULL;
}

OSStatus
AudioQueueAllocateBuffer(AudioQueueRef handle, UInt32 capacity, AudioQueueBufferRef *outBuffer)
{
    if (outBuffer)
        *outBuffer = NULL;
    if (!outBuffer || !capacity)
        return kAudioQueueErr_InvalidPropertyValue;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (queue->resetting || queue->offlineActive) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidRunState;
    }
    if (queue->bufferCount >= FINCH_QUEUE_BUFFER_COUNT || capacity > FINCH_QUEUE_BUFFER_BYTES ||
        capacity > FINCH_QUEUE_TOTAL_BYTES - queue->allocatedBytes) {
        unlock_queue(queue);
        return kAudioQueueErr_CannotStart;
    }
    void *data = calloc(1, capacity);
    AudioQueueBufferRef buffer = malloc(sizeof(*buffer));
    struct BufferRecord *record = calloc(1, sizeof(*record));
    if (!data || !buffer || !record) {
        free(data); free(buffer); free(record);
        unlock_queue(queue);
        return FINCH_MEMORY_ERROR;
    }
    AudioQueueBuffer initial = {capacity, data, 0, NULL, 0, NULL, 0};
    memcpy(buffer, &initial, sizeof(initial));
    record->buffer = buffer;
    record->allNext = queue->buffers;
    queue->buffers = record;
    queue->bufferCount++;
    queue->allocatedBytes += capacity;
    *outBuffer = buffer;
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueAllocateBufferWithPacketDescriptions(AudioQueueRef queue, UInt32 bytes,
    UInt32 descriptions, AudioQueueBufferRef *outBuffer)
{
    (void)queue; (void)bytes; (void)descriptions;
    if (outBuffer)
        *outBuffer = NULL;
    return kAudioQueueErr_InvalidPropertyValue;
}

OSStatus
AudioQueueFreeBuffer(AudioQueueRef handle, AudioQueueBufferRef buffer)
{
    if (!buffer)
        return kAudioQueueErr_InvalidBuffer;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    struct BufferRecord **link = &queue->buffers;
    while (*link && (*link)->buffer != buffer)
        link = &(*link)->allNext;
    struct BufferRecord *record = *link;
    if (!record) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidBuffer;
    }
    if (record->queued || record->callbackPending) {
        unlock_queue(queue);
        return kAudioQueueErr_BufferInQueue;
    }
    *link = record->allNext;
    queue->bufferCount--;
    queue->allocatedBytes -= buffer->mAudioDataBytesCapacity;
    free(buffer->mAudioData);
    free(buffer);
    free(record);
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueEnqueueBuffer(AudioQueueRef handle, AudioQueueBufferRef buffer, UInt32 packetCount,
    const AudioStreamPacketDescription *packetDescriptions)
{
    if (packetCount || packetDescriptions)
        return kAudioQueueErr_InvalidPropertyValue;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (queue->resetting) {
        unlock_queue(queue);
        return kAudioQueueErr_EnqueueDuringReset;
    }
    struct BufferRecord *record = find_buffer(queue, buffer);
    if (!record) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidBuffer;
    }
    if (record->queued) {
        OSStatus status = queue->isInput ? kAudioQueueErr_BufferEnqueuedTwice : kAudioQueueErr_BufferInQueue;
        unlock_queue(queue);
        return status;
    }
    if (queue->isInput) {
        if (buffer->mAudioDataByteSize != 0) {
            unlock_queue(queue);
            return kAudioQueueErr_InvalidPropertyValue;
        }
    } else if (!buffer->mAudioDataByteSize) {
        unlock_queue(queue);
        return kAudioQueueErr_BufferEmpty;
    }
    if (buffer->mAudioDataByteSize > buffer->mAudioDataBytesCapacity ||
        buffer->mAudioDataByteSize % queue->format.mBytesPerFrame) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidPropertyValue;
    }
    record->queued = true;
    record->offsetFrames = 0;
    record->queueNext = NULL;
    if (queue->queueTail)
        queue->queueTail->queueNext = record;
    else
        queue->queueHead = record;
    queue->queueTail = record;
    queue->queuedCount++;
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueEnqueueBufferWithParameters(AudioQueueRef queue, AudioQueueBufferRef buffer, UInt32 count,
    const AudioStreamPacketDescription *descriptions, UInt32 trimStart, UInt32 trimEnd,
    UInt32 eventCount, const AudioQueueParameterEvent *events, const AudioTimeStamp *startTime,
    AudioTimeStamp *actualStartTime)
{
    (void)queue; (void)buffer; (void)count; (void)descriptions;
    (void)trimStart; (void)trimEnd; (void)eventCount; (void)events; (void)startTime;
    (void)actualStartTime;
    return kAudioQueueErr_InvalidPropertyValue;
}

OSStatus
AudioQueueStart(AudioQueueRef handle, const AudioTimeStamp *time)
{
    (void)time;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidDevice;
}

static void
call_completion(AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    AudioQueueOutputCallback outputCallback;
    AudioQueueInputCallback inputCallback;
    void *userData;
    pthread_mutex_lock(&queue->lock);
    struct BufferRecord *record = find_buffer(queue, buffer);
    if (record)
        record->callbackPending = false;
    outputCallback = queue->outputCallback;
    inputCallback = queue->inputCallback;
    userData = queue->userData;
    pthread_mutex_unlock(&queue->lock);
    if (queue->isInput) {
        if (inputCallback) {
            AudioTimeStamp time = {0};
            inputCallback(userData, queue, buffer, &time, 0, NULL);
        }
    } else if (outputCallback) {
        outputCallback(userData, queue, buffer);
    }
}

/* Called with the queue lock held. Returns with it held after callbacks run unlocked. */
static OSStatus
reset_queue_locked(AudioQueueRef queue)
{
    AudioQueueBufferRef completed[FINCH_QUEUE_BUFFER_COUNT];
    UInt32 completedCount = 0;
    if (queue->offlineActive || queue->resetting || queue->notifying) {
        return kAudioQueueErr_InvalidRunState;
    }
    queue->resetting = true;
    struct BufferRecord *record = queue->queueHead;
    queue->queueHead = queue->queueTail = NULL;
    queue->queuedCount = 0;
    while (record) {
        struct BufferRecord *next = record->queueNext;
        record->queueNext = NULL;
        record->queued = false;
        record->offsetFrames = 0;
        if (queue->outputCallback || queue->inputCallback) {
            record->callbackPending = true;
            completed[completedCount++] = record->buffer;
        }
        record = next;
    }
    if (queue->converter)
        AudioConverterReset(queue->converter);
    queue->sampleTimeValid = false;
    queue->rendered = false;
    queue->discontinuityGeneration++;
    pthread_mutex_unlock(&queue->lock);

    for (UInt32 i = 0; i < completedCount; i++)
        call_completion(queue, completed[i]);

    pthread_mutex_lock(&queue->lock);
    queue->resetting = false;
    return noErr;
}

OSStatus
AudioQueueStop(AudioQueueRef handle, Boolean immediate)
{
    (void)immediate;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    queue->running = false;
    OSStatus status = reset_queue_locked(queue);
    unlock_queue(queue);
    return status;
}

OSStatus
AudioQueueReset(AudioQueueRef handle)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    OSStatus status = reset_queue_locked(queue);
    unlock_queue(queue);
    return status;
}

OSStatus
AudioQueuePause(AudioQueueRef handle)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidRunState;
}

OSStatus
AudioQueueFlush(AudioQueueRef handle)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    OSStatus status = queue->running ? kAudioQueueErr_InvalidRunState : noErr;
    unlock_queue(queue);
    return status;
}

OSStatus
AudioQueuePrime(AudioQueueRef handle, UInt32 requestedFrames, UInt32 *preparedFrames)
{
    if (preparedFrames)
        *preparedFrames = 0;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (queue->isInput) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidQueueType;
    }
    UInt64 frames = 0;
    for (struct BufferRecord *record = queue->queueHead; record; record = record->queueNext)
        frames += record->buffer->mAudioDataByteSize / queue->format.mBytesPerFrame - record->offsetFrames;
    if (requestedFrames && frames > requestedFrames)
        frames = requestedFrames;
    if (frames > UINT32_MAX)
        frames = UINT32_MAX;
    if (preparedFrames)
        *preparedFrames = (UInt32)frames;
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueGetParameter(AudioQueueRef handle, AudioQueueParameterID parameter, AudioQueueParameterValue *value)
{
    (void)parameter;
    if (value)
        *value = 0;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidParameter;
}

OSStatus
AudioQueueSetParameter(AudioQueueRef handle, AudioQueueParameterID parameter, AudioQueueParameterValue value)
{
    (void)parameter; (void)value;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidParameter;
}

static OSStatus
property_size(AudioQueueRef queue, AudioQueuePropertyID property, UInt32 *size)
{
    switch (property) {
        case kAudioQueueProperty_IsRunning:
        case kAudioQueueProperty_ConverterError: *size = sizeof(UInt32); return noErr;
        case kAudioQueueProperty_StreamDescription: *size = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioQueueProperty_MaximumOutputPacketSize:
            if (queue->isInput) return kAudioQueueErr_InvalidQueueType;
            *size = sizeof(UInt32); return noErr;
        case kAudioQueueProperty_DecodeBufferSizeFrames:
            if (queue->isInput) return kAudioQueueErr_InvalidQueueType;
            *size = sizeof(UInt32); return noErr;
        case kAudioQueueDeviceProperty_SampleRate:
        case kAudioQueueDeviceProperty_NumberChannels:
        case kAudioQueueProperty_CurrentDevice: return kAudioQueueErr_InvalidDevice;
        default: return kAudioQueueErr_InvalidProperty;
    }
}

OSStatus
AudioQueueGetPropertySize(AudioQueueRef handle, AudioQueuePropertyID property, UInt32 *size)
{
    if (!size)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    OSStatus status = property_size(queue, property, size);
    unlock_queue(queue);
    return status;
}

OSStatus
AudioQueueGetProperty(AudioQueueRef handle, AudioQueuePropertyID property, void *data, UInt32 *size)
{
    if (!data || !size)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    UInt32 need = 0;
    OSStatus status = property_size(queue, property, &need);
    if (status) {
        unlock_queue(queue);
        return status;
    }
    if (*size < need) {
        *size = need;
        unlock_queue(queue);
        return kAudioQueueErr_InvalidPropertySize;
    }
    switch (property) {
        case kAudioQueueProperty_IsRunning: {
            UInt32 value = queue->running;
            memcpy(data, &value, sizeof(value));
            break;
        }
        case kAudioQueueProperty_StreamDescription:
            memcpy(data, &queue->format, sizeof(queue->format));
            break;
        case kAudioQueueProperty_MaximumOutputPacketSize:
            memcpy(data, &queue->format.mBytesPerPacket, sizeof(UInt32));
            break;
        case kAudioQueueProperty_DecodeBufferSizeFrames:
            memcpy(data, &queue->decodeBufferFrames, sizeof(UInt32));
            break;
        case kAudioQueueProperty_ConverterError:
            memcpy(data, &queue->converterError, sizeof(UInt32));
            break;
        default:
            unlock_queue(queue);
            return kAudioQueueErr_InvalidProperty;
    }
    *size = need;
    unlock_queue(queue);
    return noErr;
}

struct ListenerCall { AudioQueuePropertyListenerProc callback; void *userData; };

/* Called with the queue lock held; listeners always run with it released. */
static void
notify_property_locked(AudioQueueRef queue, AudioQueuePropertyID property)
{
    struct ListenerCall calls[FINCH_QUEUE_BUFFER_COUNT];
    UInt32 count = 0;
    if (queue->notifying) {
        return;
    }
    queue->notifying = true;
    for (struct ListenerRecord *item = queue->listeners; item && count < FINCH_QUEUE_BUFFER_COUNT; item = item->next)
        if (item->property == property)
            calls[count++] = (struct ListenerCall){item->callback, item->userData};
    pthread_mutex_unlock(&queue->lock);
    for (UInt32 i = 0; i < count; i++)
        calls[i].callback(calls[i].userData, queue, property);
    pthread_mutex_lock(&queue->lock);
    queue->notifying = false;
}

OSStatus
AudioQueueSetProperty(AudioQueueRef handle, AudioQueuePropertyID property, const void *data, UInt32 size)
{
    if (!data)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (property == kAudioQueueProperty_DecodeBufferSizeFrames && !queue->isInput) {
        if (size != sizeof(UInt32)) {
            unlock_queue(queue);
            return kAudioQueueErr_InvalidPropertySize;
        }
        UInt32 value;
        memcpy(&value, data, sizeof(value));
        if (!value || value > FINCH_QUEUE_MAX_FRAMES) {
            unlock_queue(queue);
            return kAudioQueueErr_InvalidPropertyValue;
        }
        queue->decodeBufferFrames = value;
        notify_property_locked(queue, property);
        unlock_queue(queue);
        return noErr;
    }
    if (property == kAudioQueueDeviceProperty_SampleRate || property == kAudioQueueDeviceProperty_NumberChannels ||
        property == kAudioQueueProperty_CurrentDevice) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidDevice;
    }
    unlock_queue(queue);
    return kAudioQueueErr_InvalidProperty;
}

OSStatus
AudioQueueAddPropertyListener(AudioQueueRef handle, AudioQueuePropertyID property,
    AudioQueuePropertyListenerProc callback, void *userData)
{
    if (!callback)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (property != kAudioQueueProperty_IsRunning && property != kAudioQueueProperty_DecodeBufferSizeFrames) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidProperty;
    }
    UInt32 count = 0;
    for (struct ListenerRecord *item = queue->listeners; item; item = item->next)
        count++;
    if (count >= FINCH_QUEUE_BUFFER_COUNT) {
        unlock_queue(queue);
        return kAudioQueueErr_CannotStart;
    }
    struct ListenerRecord *item = malloc(sizeof(*item));
    if (!item) {
        unlock_queue(queue);
        return FINCH_MEMORY_ERROR;
    }
    *item = (struct ListenerRecord){property, callback, userData, queue->listeners};
    queue->listeners = item;
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueRemovePropertyListener(AudioQueueRef handle, AudioQueuePropertyID property,
    AudioQueuePropertyListenerProc callback, void *userData)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    struct ListenerRecord **link = &queue->listeners;
    while (*link && ((*link)->property != property || (*link)->callback != callback || (*link)->userData != userData))
        link = &(*link)->next;
    if (*link) {
        struct ListenerRecord *found = *link;
        *link = found->next;
        free(found);
    }
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueCreateTimeline(AudioQueueRef handle, AudioQueueTimelineRef *outTimeline)
{
    if (outTimeline)
        *outTimeline = NULL;
    if (!outTimeline)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    struct OpaqueAudioQueueTimeline *timeline = calloc(1, sizeof(*timeline));
    if (!timeline) {
        unlock_queue(queue);
        return FINCH_MEMORY_ERROR;
    }
    timeline->owner = queue;
    timeline->next = queue->timelines;
    queue->timelines = timeline;
    *outTimeline = timeline;
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueDisposeTimeline(AudioQueueRef handle, AudioQueueTimelineRef timeline)
{
    if (!timeline)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    struct OpaqueAudioQueueTimeline **link = &queue->timelines;
    while (*link && *link != timeline)
        link = &(*link)->next;
    if (!*link) {
        unlock_queue(queue);
        return FINCH_PARAM_ERROR;
    }
    *link = timeline->next;
    free(timeline);
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueGetCurrentTime(AudioQueueRef handle, AudioQueueTimelineRef timeline,
    AudioTimeStamp *time, Boolean *discontinuity)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (timeline) {
        Boolean found = false;
        for (struct OpaqueAudioQueueTimeline *item = queue->timelines; item; item = item->next)
            found |= item == timeline;
        if (!found) {
            unlock_queue(queue);
            return FINCH_PARAM_ERROR;
        }
    }
    if (time) {
        memset(time, 0, sizeof(*time));
        if (queue->sampleTimeValid) {
            time->mSampleTime = queue->sampleTime;
            time->mFlags = kAudioTimeStampSampleTimeValid;
        }
    }
    if (timeline && discontinuity) {
        *discontinuity = timeline->discontinuityGeneration != queue->discontinuityGeneration;
        timeline->discontinuityGeneration = queue->discontinuityGeneration;
    }
    unlock_queue(queue);
    return noErr;
}

OSStatus
AudioQueueDeviceGetCurrentTime(AudioQueueRef handle, AudioTimeStamp *time)
{
    (void)time;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue) return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidDevice;
}

OSStatus
AudioQueueDeviceTranslateTime(AudioQueueRef handle, const AudioTimeStamp *time, AudioTimeStamp *outTime)
{
    (void)time; (void)outTime;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue) return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidDevice;
}

OSStatus
AudioQueueDeviceGetNearestStartTime(AudioQueueRef handle, AudioTimeStamp *time, UInt32 flags)
{
    (void)time; (void)flags;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue) return FINCH_PARAM_ERROR;
    unlock_queue(queue);
    return kAudioQueueErr_InvalidDevice;
}

OSStatus
AudioQueueSetOfflineRenderFormat(AudioQueueRef handle, const AudioStreamBasicDescription *format,
    const AudioChannelLayout *layout)
{
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (queue->isInput) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidQueueType;
    }
    if (queue->offlineActive || queue->resetting || queue->running) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidRunState;
    }
    if (!format) {
        if (layout) {
            unlock_queue(queue);
            return kAudioQueueErr_InvalidPropertyValue;
        }
        AudioConverterRef old = queue->converter;
        queue->converter = NULL;
        queue->offlineConfigured = false;
        unlock_queue(queue);
        if (old)
            AudioConverterDispose(old);
        return noErr;
    }
    if (layout || !valid_pcm_format(format) || format->mSampleRate != queue->format.mSampleRate ||
        format->mChannelsPerFrame != queue->format.mChannelsPerFrame) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidPropertyValue;
    }
    AudioConverterRef converter = NULL;
    OSStatus status = AudioConverterNew(&queue->format, format, &converter);
    if (status) {
        unlock_queue(queue);
        return status;
    }
    AudioConverterRef old = queue->converter;
    queue->converter = converter;
    queue->offlineFormat = *format;
    queue->offlineConfigured = true;
    queue->sampleTimeValid = false;
    queue->rendered = false;
    unlock_queue(queue);
    if (old)
        AudioConverterDispose(old);
    return noErr;
}

struct OfflineInput {
    AudioQueueRef queue;
    UInt32 eligibleBuffers;
    AudioQueueBufferRef completed[FINCH_QUEUE_BUFFER_COUNT];
    UInt32 completedCount;
};

/* Separate callback entry keeps the converter's requested count before writing the result. */
static OSStatus
provide_offline_input(AudioConverterRef converter, UInt32 *packetCount, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *userData)
{
    (void)converter;
    struct OfflineInput *input = userData;
    AudioQueueRef queue = input->queue;
    UInt32 requested = *packetCount;
    *packetCount = 0;
    if (descriptions)
        *descriptions = NULL;
    if (!requested || !input->eligibleBuffers || !queue->queueHead)
        return noErr;
    struct BufferRecord *record = queue->queueHead;
    UInt32 totalFrames = record->buffer->mAudioDataByteSize / queue->format.mBytesPerFrame;
    UInt32 available = totalFrames - record->offsetFrames;
    UInt32 frames = requested < available ? requested : available;
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = queue->format.mChannelsPerFrame;
    data->mBuffers[0].mDataByteSize = frames * queue->format.mBytesPerFrame;
    data->mBuffers[0].mData = (UInt8 *)record->buffer->mAudioData +
        (size_t)record->offsetFrames * queue->format.mBytesPerFrame;
    record->offsetFrames += frames;
    *packetCount = frames;
    if (record->offsetFrames == totalFrames) {
        queue->queueHead = record->queueNext;
        if (!queue->queueHead)
            queue->queueTail = NULL;
        record->queueNext = NULL;
        record->queued = false;
        record->offsetFrames = 0;
        queue->queuedCount--;
        input->eligibleBuffers--;
        if (input->completedCount < FINCH_QUEUE_BUFFER_COUNT) {
            record->callbackPending = queue->outputCallback != NULL;
            input->completed[input->completedCount++] = record->buffer;
        }
    }
    return noErr;
}

OSStatus
AudioQueueOfflineRender(AudioQueueRef handle, const AudioTimeStamp *time,
    AudioQueueBufferRef outputBuffer, UInt32 frames)
{
    if (!time || !(time->mFlags & kAudioTimeStampSampleTimeValid) || !isfinite(time->mSampleTime) ||
        time->mSampleTime < 0.0 || !outputBuffer || !frames || frames > FINCH_QUEUE_MAX_FRAMES)
        return FINCH_PARAM_ERROR;
    AudioQueueRef queue = lock_queue(handle);
    if (!queue)
        return FINCH_PARAM_ERROR;
    if (queue->isInput) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidQueueType;
    }
    if (!queue->offlineConfigured || !queue->converter) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidOfflineMode;
    }
    if (queue->offlineActive || queue->resetting || queue->running) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidRunState;
    }
    struct BufferRecord *renderRecord = find_buffer(queue, outputBuffer);
    if (!renderRecord || renderRecord->queued || renderRecord->callbackPending) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidBuffer;
    }
    UInt32 frameBytes = queue->offlineFormat.mBytesPerFrame;
    if (frames > UINT32_MAX / frameBytes || frames * frameBytes > outputBuffer->mAudioDataBytesCapacity) {
        unlock_queue(queue);
        return kAudioQueueErr_InvalidBuffer;
    }
    queue->offlineActive = true;
    struct OfflineInput input = {queue, queue->queuedCount, {0}, 0};
    AudioBufferList output = {1, {{queue->offlineFormat.mChannelsPerFrame,
        frames * frameBytes, outputBuffer->mAudioData}}};
    UInt32 renderedFrames = frames;
    OSStatus status = AudioConverterFillComplexBuffer(queue->converter, provide_offline_input, &input,
        &renderedFrames, &output, NULL);
    outputBuffer->mAudioDataByteSize = renderedFrames * frameBytes;
    if (status) {
        queue->converterError = (UInt32)status;
    } else {
        queue->converterError = 0;
    }
    if (!queue->rendered) {
        queue->sampleTime = time->mSampleTime;
        queue->rendered = true;
    } else if (time->mSampleTime != queue->sampleTime) {
        queue->discontinuityGeneration++;
        queue->sampleTime = time->mSampleTime;
    }
    queue->sampleTime += renderedFrames;
    queue->sampleTimeValid = true;
    unlock_queue(queue);

    for (UInt32 i = 0; i < input.completedCount; i++)
        call_completion(queue, input.completed[i]);

    pthread_mutex_lock(&queue->lock);
    queue->offlineActive = false;
    pthread_mutex_unlock(&queue->lock);
    return status;
}

OSStatus
AudioQueueDispose(AudioQueueRef handle, Boolean immediate)
{
    (void)immediate;
    if (!handle)
        return FINCH_PARAM_ERROR;
    pthread_mutex_lock(&registryLock);
    UInt32 slot;
    AudioQueueRef queue = NULL;
    for (slot = 0; slot < FINCH_QUEUE_COUNT; slot++) {
        AudioQueueRef candidate = atomic_load_explicit(&queues[slot], memory_order_acquire);
        if (candidate == handle) {
            queue = candidate;
            pthread_mutex_lock(&queue->lock);
            break;
        }
    }
    if (!queue) {
        pthread_mutex_unlock(&registryLock);
        return FINCH_PARAM_ERROR;
    }
    if (queue->offlineActive || queue->resetting || queue->notifying) {
        pthread_mutex_unlock(&queue->lock);
        pthread_mutex_unlock(&registryLock);
        return kAudioQueueErr_DisposalPending;
    }
    atomic_store_explicit(&queues[slot], NULL, memory_order_release);
    queue->signature = 0;
    pthread_mutex_unlock(&registryLock);

    struct BufferRecord *record = queue->buffers;
    while (record) {
        struct BufferRecord *next = record->allNext;
        free(record->buffer->mAudioData);
        free(record->buffer);
        free(record);
        record = next;
    }
    struct ListenerRecord *listener = queue->listeners;
    while (listener) {
        struct ListenerRecord *next = listener->next;
        free(listener);
        listener = next;
    }
    struct OpaqueAudioQueueTimeline *timeline = queue->timelines;
    while (timeline) {
        struct OpaqueAudioQueueTimeline *next = timeline->next;
        free(timeline);
        timeline = next;
    }
    AudioConverterRef converter = queue->converter;
    pthread_mutex_unlock(&queue->lock);
    pthread_mutex_destroy(&queue->lock);
    if (converter)
        AudioConverterDispose(converter);
    free(queue);
    return noErr;
}

OSStatus
AudioQueueProcessingTapNew(AudioQueueRef queue, AudioQueueProcessingTapCallback callback,
    void *clientData, AudioQueueProcessingTapFlags flags, UInt32 *maxFrames,
    AudioStreamBasicDescription *format, AudioQueueProcessingTapRef *tap)
{
    (void)queue; (void)callback; (void)clientData; (void)flags; (void)maxFrames; (void)format;
    if (tap) *tap = NULL;
    return kAudioQueueErr_InvalidTapType;
}

OSStatus
AudioQueueProcessingTapDispose(AudioQueueProcessingTapRef tap)
{
    (void)tap;
    return kAudioQueueErr_InvalidTapContext;
}

OSStatus
AudioQueueProcessingTapGetSourceAudio(AudioQueueProcessingTapRef tap, UInt32 frames,
    AudioTimeStamp *time, AudioQueueProcessingTapFlags *flags, UInt32 *outFrames,
    AudioBufferList *data)
{
    (void)tap; (void)frames; (void)time; (void)flags; (void)outFrames; (void)data;
    return kAudioQueueErr_InvalidTapContext;
}

OSStatus
AudioQueueProcessingTapGetQueueTime(AudioQueueProcessingTapRef tap, Float64 *sampleTime, UInt32 *frames)
{
    (void)tap; (void)sampleTime; (void)frames;
    return kAudioQueueErr_InvalidTapContext;
}

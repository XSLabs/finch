/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check PCM queue ownership, offline output and callback behavior. */
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
expect(OSStatus actual, OSStatus wanted, const char *what)
{
    if (actual != wanted) {
        fprintf(stderr, "%s: got %d, wanted %d\n", what, (int)actual, (int)wanted);
        exit(1);
    }
}

static void
check(OSStatus status, const char *what)
{
    expect(status, noErr, what);
}

static AudioStreamBasicDescription
pcm32(void)
{
    return (AudioStreamBasicDescription){44100.0, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0};
}

static AudioStreamBasicDescription
pcm16(void)
{
    return (AudioStreamBasicDescription){44100.0, kAudioFormatLinearPCM,
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0};
}

struct OutputState {
    UInt32 callbacks;
    UInt32 requeues;
    OSStatus enqueueStatus;
    OSStatus nestedStatus;
    AudioQueueBufferRef renderBuffer;
};

static void
output_done(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    struct OutputState *state = context;
    state->callbacks++;
    Boolean didRequeue = false;
    if (state->requeues < 4) {
        Float32 *samples = buffer->mAudioData;
        samples[0] = 0.125f;
        samples[1] = 0.125f;
        buffer->mAudioDataByteSize = 2 * sizeof(*samples);
        state->enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        didRequeue = state->enqueueStatus == noErr;
    }
    AudioTimeStamp time = {0};
    time.mFlags = kAudioTimeStampSampleTimeValid;
    state->nestedStatus = AudioQueueOfflineRender(queue, &time, state->renderBuffer, 1);
    if (didRequeue)
        state->requeues++;
}

struct InputState {
    UInt32 callbacks;
    OSStatus enqueueStatus;
    Boolean hadTime;
};

static void
input_done(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
    const AudioTimeStamp *time, UInt32 packetCount, const AudioStreamPacketDescription *descriptions)
{
    struct InputState *state = context;
    state->callbacks++;
    state->hadTime = time != NULL;
    if (packetCount || descriptions || buffer->mAudioDataByteSize)
        state->enqueueStatus = -999;
    else
        state->enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

struct PropertyState {
    UInt32 calls;
    UInt32 valueSeen;
};

static void
property_changed(void *context, AudioQueueRef queue, AudioQueuePropertyID property)
{
    struct PropertyState *state = context;
    UInt32 size = sizeof(state->valueSeen);
    if (property == kAudioQueueProperty_DecodeBufferSizeFrames &&
        AudioQueueGetProperty(queue, property, &state->valueSeen, &size) == noErr)
        state->calls++;
}

static void
test_offline_output(void)
{
    AudioStreamBasicDescription format = pcm32();
    struct OutputState state = {0};
    AudioQueueRef queue = NULL;
    check(AudioQueueNewOutput(&format, output_done, &state, NULL, NULL, 0, &queue), "create output queue");
    if (!queue) {
        fprintf(stderr, "output queue was not returned\n");
        exit(1);
    }

    UInt32 size = 0;
    check(AudioQueueGetPropertySize(queue, kAudioQueueProperty_StreamDescription, &size), "format size");
    if (size != sizeof(format)) {
        fprintf(stderr, "wrong stream description size\n");
        exit(1);
    }
    AudioStreamBasicDescription readFormat = {0};
    size = sizeof(readFormat);
    check(AudioQueueGetProperty(queue, kAudioQueueProperty_StreamDescription, &readFormat, &size), "read format");
    if (memcmp(&format, &readFormat, sizeof(format)) != 0) {
        fprintf(stderr, "queue changed its PCM format\n");
        exit(1);
    }
    UInt32 running = 1;
    size = sizeof(running);
    check(AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size), "read running state");
    if (running) {
        fprintf(stderr, "device-free queue claimed to be running\n");
        exit(1);
    }
    expect(AudioQueueStart(queue, NULL), kAudioQueueErr_InvalidDevice, "start without an audio device");

    struct PropertyState propertyState = {0};
    check(AudioQueueAddPropertyListener(queue, kAudioQueueProperty_DecodeBufferSizeFrames,
        property_changed, &propertyState), "add property listener");
    UInt32 decodeFrames = 2048;
    check(AudioQueueSetProperty(queue, kAudioQueueProperty_DecodeBufferSizeFrames,
        &decodeFrames, sizeof(decodeFrames)), "set decode buffer size");
    if (propertyState.calls != 1 || propertyState.valueSeen != decodeFrames) {
        fprintf(stderr, "property listener did not read the new value\n");
        exit(1);
    }
    check(AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_DecodeBufferSizeFrames,
        property_changed, &propertyState), "remove property listener");
    expect(AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &running, &size),
        kAudioQueueErr_InvalidDevice, "current device is unavailable");

    AudioQueueTimelineRef timeline = NULL;
    check(AudioQueueCreateTimeline(queue, &timeline), "create timeline");
    AudioStreamBasicDescription wrongRate = format;
    wrongRate.mSampleRate = 48000.0;
    expect(AudioQueueSetOfflineRenderFormat(queue, &wrongRate, NULL),
        kAudioQueueErr_InvalidPropertyValue, "reject a different offline rate");
    AudioStreamBasicDescription planar = format;
    planar.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    expect(AudioQueueSetOfflineRenderFormat(queue, &planar, NULL),
        kAudioQueueErr_InvalidPropertyValue, "reject non-interleaved offline output");
    AudioTimeStamp time = {0};
    time.mFlags = kAudioTimeStampSampleTimeValid;
    AudioQueueBufferRef renderBuffer = NULL;
    check(AudioQueueAllocateBuffer(queue, 8 * sizeof(Float32), &renderBuffer), "allocate render buffer");
    time.mFlags = 0;
    expect(AudioQueueOfflineRender(queue, &time, renderBuffer, 1), -50, "require a sample timestamp");
    time.mFlags = kAudioTimeStampSampleTimeValid;
    expect(AudioQueueOfflineRender(queue, &time, renderBuffer, 8),
        kAudioQueueErr_InvalidOfflineMode, "require offline mode");
    AudioStreamBasicDescription outputFormat = pcm16();
    check(AudioQueueSetOfflineRenderFormat(queue, &outputFormat, NULL), "enable format conversion");

    AudioQueueBufferRef first = NULL, second = NULL;
    check(AudioQueueAllocateBuffer(queue, 2 * sizeof(Float32), &first), "allocate first source buffer");
    check(AudioQueueAllocateBuffer(queue, 2 * sizeof(Float32), &second), "allocate second source buffer");
    ((Float32 *)first->mAudioData)[0] = 0.25f;
    ((Float32 *)first->mAudioData)[1] = -0.5f;
    first->mAudioDataByteSize = 2 * sizeof(Float32);
    ((Float32 *)second->mAudioData)[0] = 0.75f;
    ((Float32 *)second->mAudioData)[1] = -1.0f;
    second->mAudioDataByteSize = 2 * sizeof(Float32);
    check(AudioQueueEnqueueBuffer(queue, first, 0, NULL), "enqueue first source");
    expect(AudioQueueFreeBuffer(queue, first), kAudioQueueErr_BufferInQueue, "keep queued buffer owned");
    expect(AudioQueueEnqueueBuffer(queue, first, 0, NULL), kAudioQueueErr_BufferInQueue, "reject duplicate output buffer");
    check(AudioQueueEnqueueBuffer(queue, second, 0, NULL), "enqueue second source");
    state.renderBuffer = renderBuffer;

    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 8), "render queued PCM");
    if (renderBuffer->mAudioDataByteSize != 4 * sizeof(SInt16) || state.callbacks != 2 ||
        state.requeues != 2 || state.nestedStatus != kAudioQueueErr_InvalidRunState ||
        state.enqueueStatus != noErr) {
        fprintf(stderr, "offline callbacks were not bounded or ran under the queue lock\n");
        exit(1);
    }
    SInt16 *rendered = renderBuffer->mAudioData;
    const SInt16 expected[] = {8192, -16384, 24576, -32768};
    for (UInt32 i = 0; i < 4; i++)
        if (abs((int)rendered[i] - expected[i]) > 1) {
            fprintf(stderr, "offline PCM sample %u was %d, wanted %d\n", i, rendered[i], expected[i]);
            exit(1);
        }
    UInt32 prepared = 0;
    check(AudioQueuePrime(queue, 0, &prepared), "count requeued frames");
    if (prepared != 4) {
        fprintf(stderr, "requeued buffers were consumed in the same render call\n");
        exit(1);
    }

    time.mSampleTime = 4;
    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 8), "render requeued PCM");
    if (renderBuffer->mAudioDataByteSize != 4 * sizeof(SInt16) || state.callbacks != 4) {
        fprintf(stderr, "second render did not process only its starting buffers\n");
        exit(1);
    }
    for (UInt32 i = 0; i < 4; i++)
        if (abs((int)rendered[i] - 4096) > 1) {
            fprintf(stderr, "requeued PCM sample was not rendered\n");
            exit(1);
        }
    time.mSampleTime = 8;
    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 8), "render final requeued PCM");
    if (state.callbacks != 6 || renderBuffer->mAudioDataByteSize != 4 * sizeof(SInt16)) {
        fprintf(stderr, "final buffers were not returned once\n");
        exit(1);
    }
    time.mSampleTime = 12;
    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 8), "render empty queue");
    if (renderBuffer->mAudioDataByteSize != 0) {
        fprintf(stderr, "empty queue returned stale samples\n");
        exit(1);
    }
    AudioTimeStamp current = {0};
    Boolean discontinuity = true;
    check(AudioQueueGetCurrentTime(queue, timeline, &current, &discontinuity), "read offline timeline");
    if (!(current.mFlags & kAudioTimeStampSampleTimeValid) || current.mSampleTime != 12 || discontinuity) {
        fprintf(stderr, "queue timeline did not track offline renders\n");
        exit(1);
    }

    AudioQueueBufferRef chunkBuffer = NULL;
    check(AudioQueueAllocateBuffer(queue, 4 * sizeof(Float32), &chunkBuffer), "allocate chunked source");
    Float32 *chunkSamples = chunkBuffer->mAudioData;
    for (UInt32 i = 0; i < 4; i++)
        chunkSamples[i] = (Float32)(i + 1) / 10.0f;
    chunkBuffer->mAudioDataByteSize = 4 * sizeof(Float32);
    check(AudioQueueEnqueueBuffer(queue, chunkBuffer, 0, NULL), "enqueue chunked source");
    time.mSampleTime = 12;
    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 2), "render first source chunk");
    if (renderBuffer->mAudioDataByteSize != 2 * sizeof(SInt16) || state.callbacks != 6) {
        fprintf(stderr, "partial source buffer was returned too soon\n");
        exit(1);
    }
    time.mSampleTime = 14;
    check(AudioQueueOfflineRender(queue, &time, renderBuffer, 2), "render second source chunk");
    if (renderBuffer->mAudioDataByteSize != 2 * sizeof(SInt16) || state.callbacks != 7 ||
        abs((int)rendered[0] - 9830) > 2 || abs((int)rendered[1] - 13107) > 2) {
        fprintf(stderr, "partial source buffer did not resume at the right sample\n");
        exit(1);
    }

    AudioQueueBufferRef resetBuffer = NULL;
    check(AudioQueueAllocateBuffer(queue, 2 * sizeof(Float32), &resetBuffer), "allocate reset buffer");
    ((Float32 *)resetBuffer->mAudioData)[0] = 0.5f;
    ((Float32 *)resetBuffer->mAudioData)[1] = 0.5f;
    resetBuffer->mAudioDataByteSize = 2 * sizeof(Float32);
    check(AudioQueueEnqueueBuffer(queue, resetBuffer, 0, NULL), "enqueue reset buffer");
    check(AudioQueueReset(queue), "reset output queue");
    if (state.callbacks != 8)
        exit(1);
    check(AudioQueueDisposeTimeline(queue, timeline), "dispose timeline");
    check(AudioQueueSetOfflineRenderFormat(queue, NULL, NULL), "disable offline mode");
    check(AudioQueueFreeBuffer(queue, first), "free returned first buffer");
    check(AudioQueueFreeBuffer(queue, second), "free returned second buffer");
    check(AudioQueueFreeBuffer(queue, chunkBuffer), "free returned chunked buffer");
    check(AudioQueueFreeBuffer(queue, resetBuffer), "free reset buffer");
    check(AudioQueueFreeBuffer(queue, renderBuffer), "free render buffer");
    check(AudioQueueDispose(queue, true), "dispose output queue");
}

static void
test_input_queue(void)
{
    AudioStreamBasicDescription format = pcm32();
    struct InputState state = {0};
    AudioQueueRef queue = NULL;
    check(AudioQueueNewInput(&format, input_done, &state, NULL, NULL, 0, &queue), "create input queue");
    AudioQueueBufferRef buffer = NULL;
    check(AudioQueueAllocateBuffer(queue, 2 * sizeof(Float32), &buffer), "allocate input buffer");
    check(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "enqueue empty input buffer");
    expect(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), kAudioQueueErr_BufferEnqueuedTwice,
        "reject duplicate input buffer");
    expect(AudioQueueStart(queue, NULL), kAudioQueueErr_InvalidDevice, "do not claim recording");
    if (state.callbacks)
        exit(1);
    AudioTimeStamp time = {0};
    time.mFlags = kAudioTimeStampSampleTimeValid;
    expect(AudioQueueOfflineRender(queue, &time, buffer, 1), kAudioQueueErr_InvalidQueueType,
        "reject input queue offline render");
    check(AudioQueueStop(queue, true), "stop input queue");
    if (state.callbacks != 1 || !state.hadTime || state.enqueueStatus != kAudioQueueErr_EnqueueDuringReset) {
        fprintf(stderr, "input queue callback claimed data or allowed enqueue during reset\n");
        exit(1);
    }
    check(AudioQueueFreeBuffer(queue, buffer), "free returned input buffer");
    check(AudioQueueDispose(queue, true), "dispose input queue");
}

int
main(void)
{
    AudioStreamBasicDescription bad = pcm32();
    bad.mFormatID = kAudioFormatMPEG4AAC;
    AudioQueueRef queue = (AudioQueueRef)(uintptr_t)1;
    expect(AudioQueueNewOutput(&bad, output_done, NULL, NULL, NULL, 0, &queue),
        kAudioQueueErr_InvalidPropertyValue, "reject compressed queue format");
    if (queue) {
        fprintf(stderr, "failed queue creation returned a handle\n");
        return 1;
    }
    bad = pcm32();
    bad.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    expect(AudioQueueNewOutput(&bad, output_done, NULL, NULL, NULL, 0, &queue),
        kAudioQueueErr_InvalidPropertyValue, "reject planar queue format");
    test_offline_output();
    test_input_queue();
    puts("AudioQueue PCM, ownership and offline render checks passed");
    return 0;
}

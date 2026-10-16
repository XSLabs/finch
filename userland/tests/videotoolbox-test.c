/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define FRAME_COUNT 4
#define FRAME_WIDTH 64
#define FRAME_HEIGHT 48

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    CMSampleBufferRef samples[FRAME_COUNT];
    size_t count;
    OSStatus callbackError;
} EncodeOutput;

typedef struct {
    uint64_t red, green, blue, pixels;
    size_t frames;
    OSStatus error;
} DecodeStats;

static void
encode_output(void *refCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags flags,
              CMSampleBufferRef sampleBuffer)
{
    (void)flags;
    EncodeOutput *output = refCon;
    uintptr_t index = (uintptr_t)sourceFrameRefCon;
    pthread_mutex_lock(&output->lock);
    if (status != noErr) {
        output->callbackError = status;
    } else if (sampleBuffer && index > 0 && index <= FRAME_COUNT && !output->samples[index - 1]) {
        output->samples[index - 1] = (CMSampleBufferRef)CFRetain(sampleBuffer);
        output->count++;
    } else if (!sampleBuffer || index == 0 || index > FRAME_COUNT) {
        output->callbackError = kVTVideoEncoderMalfunctionErr;
    }
    pthread_cond_broadcast(&output->changed);
    pthread_mutex_unlock(&output->lock);
}

static Boolean
wait_for_encoded_frames(EncodeOutput *output)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 10;
    pthread_mutex_lock(&output->lock);
    while (output->count < FRAME_COUNT && output->callbackError == noErr) {
        int result = pthread_cond_timedwait(&output->changed, &output->lock, &deadline);
        if (result != 0)
            break;
    }
    Boolean complete = output->count == FRAME_COUNT && output->callbackError == noErr;
    pthread_mutex_unlock(&output->lock);
    return complete;
}

static void
decode_output(void *refCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags flags,
              CVImageBufferRef imageBuffer, CMTime pts, CMTime duration)
{
    (void)sourceFrameRefCon;
    (void)flags;
    (void)pts;
    (void)duration;
    DecodeStats *stats = refCon;
    if (status != noErr || !imageBuffer) {
        stats->error = status == noErr ? kVTVideoDecoderMalfunctionErr : status;
        return;
    }
    CVPixelBufferRef buffer = (CVPixelBufferRef)imageBuffer;
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        stats->error = kVTVideoDecoderUnsupportedDataFormatErr;
        return;
    }
    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    if (!base) {
        stats->error = kVTVideoDecoderMalfunctionErr;
    } else {
        for (size_t y = 0; y < height; y++) {
            const uint8_t *row = base + y * rowBytes;
            for (size_t x = 0; x < width; x++) {
                const uint8_t *pixel = row + 4 * x;
                stats->blue += pixel[0];
                stats->green += pixel[1];
                stats->red += pixel[2];
                stats->pixels++;
            }
        }
        stats->frames++;
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

static CVPixelBufferRef
make_frame(size_t frameIndex)
{
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(NULL, FRAME_WIDTH, FRAME_HEIGHT, kCVPixelFormatType_32BGRA, NULL, &buffer) != kCVReturnSuccess)
        return NULL;
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CFRelease(buffer);
        return NULL;
    }
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        CFRelease(buffer);
        return NULL;
    }
    for (size_t y = 0; y < FRAME_HEIGHT; y++) {
        uint8_t *row = base + y * rowBytes;
        for (size_t x = 0; x < FRAME_WIDTH; x++) {
            uint8_t *pixel = row + 4 * x;
            uint8_t shade = (uint8_t)(48 + frameIndex * 20 + x / 2 + y / 2);
            pixel[0] = shade;
            pixel[1] = shade;
            pixel[2] = shade;
            pixel[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static Boolean
fill_solid(CVPixelBufferRef buffer, const uint8_t color[4])
{
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess)
        return false;
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    Boolean good = base != NULL;
    for (size_t y = 0; good && y < height; y++) {
        uint8_t *row = base + y * rowBytes;
        for (size_t x = 0; x < width; x++)
            for (size_t c = 0; c < 4; c++) row[4 * x + c] = color[c];
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return good;
}

static Boolean
matches_solid(CVPixelBufferRef buffer, const uint8_t color[4])
{
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return false;
    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    Boolean matches = base != NULL;
    for (size_t y = 0; matches && y < height; y++) {
        const uint8_t *row = base + y * rowBytes;
        for (size_t x = 0; x < width; x++) {
            for (size_t c = 0; c < 4; c++) {
                if (row[4 * x + c] != color[c]) {
                    matches = false;
                    break;
                }
            }
            if (!matches) break;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return matches;
}

static Boolean
pixel_transfer_test(void)
{
    const uint8_t color[4] = {31, 79, 143, 255};
    CVPixelBufferRef source = NULL, destination = NULL;
    VTPixelTransferSessionRef session = NULL;
    Boolean okay = CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA, NULL, &source) == kCVReturnSuccess &&
        CVPixelBufferCreate(NULL, 4, 4, kCVPixelFormatType_32BGRA, NULL, &destination) == kCVReturnSuccess &&
        source && destination && fill_solid(source, color) &&
        VTPixelTransferSessionCreate(NULL, &session) == noErr && session &&
        VTPixelTransferSessionTransferImage(session, source, destination) == noErr &&
        matches_solid(destination, color);
    if (session) CFRelease(session);
    if (source) CFRelease(source);
    if (destination) CFRelease(destination);
    return okay;
}

static Boolean
pixel_rotation_test(void)
{
    const uint8_t colors[4][4] = {
        {0, 0, 255, 255}, {0, 255, 0, 255},
        {255, 0, 0, 255}, {255, 255, 255, 255}
    };
    CVPixelBufferRef source = NULL, destination = NULL;
    VTPixelRotationSessionRef session = NULL;
    Boolean okay = CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA, NULL, &source) == kCVReturnSuccess &&
        CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA, NULL, &destination) == kCVReturnSuccess &&
        source && destination && VTPixelRotationSessionCreate(NULL, &session) == noErr && session;
    if (okay) {
        okay = CVPixelBufferLockBaseAddress(source, 0) == kCVReturnSuccess;
        if (okay) {
            uint8_t *base = CVPixelBufferGetBaseAddress(source);
            size_t rowBytes = CVPixelBufferGetBytesPerRow(source);
            if (!base) {
                okay = false;
            } else {
                for (size_t i = 0; i < 4; i++)
                    memcpy(base + (i / 2) * rowBytes + (i % 2) * 4, colors[i], 4);
            }
            CVPixelBufferUnlockBaseAddress(source, 0);
        }
    }
    if (okay)
        okay = VTSessionSetProperty((VTSessionRef)session, kVTPixelRotationPropertyKey_Rotation, kVTRotation_180) == noErr &&
            VTPixelRotationSessionRotateImage(session, source, destination) == noErr;
    if (okay) {
        okay = CVPixelBufferLockBaseAddress(destination, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess;
        if (okay) {
            const uint8_t *base = CVPixelBufferGetBaseAddress(destination);
            size_t rowBytes = CVPixelBufferGetBytesPerRow(destination);
            if (!base) {
                okay = false;
            } else {
                for (size_t i = 0; i < 4; i++) {
                    if (memcmp(base + (i / 2) * rowBytes + (i % 2) * 4, colors[3 - i], 4) != 0) {
                        okay = false;
                        break;
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(destination, kCVPixelBufferLock_ReadOnly);
        }
    }
    if (session) CFRelease(session);
    if (source) CFRelease(source);
    if (destination) CFRelease(destination);
    return okay;
}

static Boolean
property_query_test(void)
{
    CFArrayRef encoders = NULL;
    CFStringRef encoderID = NULL;
    CFDictionaryRef properties = NULL;
    OSStatus listStatus = VTCopyVideoEncoderList(NULL, &encoders);
    OSStatus propertyStatus = VTCopySupportedPropertyDictionaryForEncoder(FRAME_WIDTH, FRAME_HEIGHT,
        kCMVideoCodecType_H264, NULL, &encoderID, &properties);
    Boolean okay = listStatus == noErr && encoders && CFArrayGetCount(encoders) > 0 &&
        propertyStatus == noErr && encoderID && properties &&
        CFDictionaryContainsKey(properties, kVTCompressionPropertyKey_AverageBitRate);
    if (encoders) CFRelease(encoders);
    if (encoderID) CFRelease(encoderID);
    if (properties) CFRelease(properties);
    return okay;
}

static Boolean
encode_and_decode_test(DecodeStats *stats, Boolean *sessionPropertyOkay)
{
    *sessionPropertyOkay = false;
    EncodeOutput output = {0};
    pthread_mutex_init(&output.lock, NULL);
    pthread_cond_init(&output.changed, NULL);
    DecodeStats result = {0};
    VTCompressionSessionRef encoder = NULL;
    VTDecompressionSessionRef decoder = NULL;
    CFNumberRef bitrate = NULL;
    CFTypeRef copiedBitrate = NULL;
    const char *failedAt = "compression session create";
    OSStatus status = VTCompressionSessionCreate(NULL, FRAME_WIDTH, FRAME_HEIGHT, kCMVideoCodecType_H264,
        NULL, NULL, NULL, encode_output, &output, &encoder);
    if (status != noErr || !encoder)
        goto fail;
    int32_t bitrateValue = 300000;
    bitrate = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitrateValue);
    failedAt = "set average bitrate";
    if (!bitrate)
        goto fail;
    status = VTSessionSetProperty((VTSessionRef)encoder, kVTCompressionPropertyKey_AverageBitRate, bitrate);
    if (status != noErr)
        goto fail;
    failedAt = "read average bitrate";
    status = VTSessionCopyProperty((VTSessionRef)encoder, kVTCompressionPropertyKey_AverageBitRate, NULL, &copiedBitrate);
    int32_t copiedBitrateValue = 0;
    Boolean copiedBitrateOkay = status == noErr && copiedBitrate &&
        CFGetTypeID(copiedBitrate) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)copiedBitrate, kCFNumberSInt32Type, &copiedBitrateValue) &&
        copiedBitrateValue == bitrateValue;
    if (copiedBitrate) {
        CFRelease(copiedBitrate);
        copiedBitrate = NULL;
    }
    if (!copiedBitrateOkay) {
        if (status == noErr) status = kVTPropertyNotSupportedErr;
        goto fail;
    }
    *sessionPropertyOkay = true;
    failedAt = "prepare encoder";
    status = VTCompressionSessionPrepareToEncodeFrames(encoder);
    if (status != noErr)
        goto fail;
    for (size_t i = 0; i < FRAME_COUNT; i++) {
        CVPixelBufferRef frame = make_frame(i);
        failedAt = "create input frame";
        if (!frame) {
            status = kVTAllocationFailedErr;
            goto fail;
        }
        VTEncodeInfoFlags flags = 0;
        failedAt = "encode input frame";
        status = VTCompressionSessionEncodeFrame(encoder, frame, CMTimeMake((int64_t)i, 30), CMTimeMake(1, 30),
            NULL, (void *)(uintptr_t)(i + 1), &flags);
        CFRelease(frame);
        if (status != noErr)
            goto fail;
    }
    failedAt = "finish encoded frames";
    status = VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
    if (status != noErr || !wait_for_encoded_frames(&output)) {
        if (status == noErr) status = output.callbackError ? output.callbackError : kVTVideoEncoderMalfunctionErr;
        goto fail;
    }
    VTDecompressionOutputCallbackRecord callback = {decode_output, &result};
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef formatValue = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixelFormat);
    if (!attributes || !formatValue) {
        failedAt = "make decoder attributes";
        status = kVTAllocationFailedErr;
        if (attributes) CFRelease(attributes);
        if (formatValue) CFRelease(formatValue);
        goto fail;
    }
    CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, formatValue);
    CFRelease(formatValue);
    failedAt = "decompression session create";
    status = VTDecompressionSessionCreate(NULL,
        CMSampleBufferGetFormatDescription(output.samples[0]), NULL, attributes, &callback, &decoder);
    CFRelease(attributes);
    if (status != noErr || !decoder)
        goto fail;
    for (size_t i = 0; i < FRAME_COUNT; i++) {
        VTDecodeInfoFlags flags = 0;
        failedAt = "decode compressed frame";
        status = VTDecompressionSessionDecodeFrame(decoder, output.samples[i], 0, NULL, &flags);
        if (status != noErr || result.error != noErr)
            goto fail;
    }
    failedAt = "finish decoded frames";
    status = VTDecompressionSessionWaitForAsynchronousFrames(decoder);
    if (status != noErr || result.error != noErr || result.frames != FRAME_COUNT || !result.pixels) {
        if (status == noErr) status = result.error ? result.error : kVTVideoDecoderMalfunctionErr;
        goto fail;
    }
    *stats = result;
    if (decoder) CFRelease(decoder);
    if (encoder) CFRelease(encoder);
    if (bitrate) CFRelease(bitrate);
    if (copiedBitrate) CFRelease(copiedBitrate);
    for (size_t i = 0; i < FRAME_COUNT; i++) if (output.samples[i]) CFRelease(output.samples[i]);
    pthread_cond_destroy(&output.changed);
    pthread_mutex_destroy(&output.lock);
    return true;

fail:
    fprintf(stderr, "VideoToolbox test: %s failed (status %d, encoder callback %d, decoded %zu frames, decoder callback %d)\n",
        failedAt, status, output.callbackError, result.frames, result.error);
    if (decoder) CFRelease(decoder);
    if (encoder) CFRelease(encoder);
    if (bitrate) CFRelease(bitrate);
    if (copiedBitrate) CFRelease(copiedBitrate);
    for (size_t i = 0; i < FRAME_COUNT; i++) if (output.samples[i]) CFRelease(output.samples[i]);
    pthread_cond_destroy(&output.changed);
    pthread_mutex_destroy(&output.lock);
    return false;
}

static void
print_mean(const char *name, uint64_t sum, uint64_t pixels)
{
    uint64_t hundredths = pixels ? (sum * 100 + pixels / 2) / pixels : 0;
    printf(" %s=%llu.%02llu", name, (unsigned long long)(hundredths / 100),
           (unsigned long long)(hundredths % 100));
}

int
main(void)
{
    Dl_info image = {0};
    dladdr((void *)VTCompressionSessionCreate, &image);
    printf("loaded from %s\n", image.dli_fname ? image.dli_fname : "unknown");

    Boolean propertiesOkay = property_query_test();
    Boolean transferOkay = pixel_transfer_test();
    Boolean rotationOkay = pixel_rotation_test();
    DecodeStats stats = {0};
    Boolean sessionPropertyOkay = false;
    Boolean codecOkay = encode_and_decode_test(&stats, &sessionPropertyOkay);
    printf("encoder property queries %d\n", propertiesOkay);
    printf("session property readback %d\n", sessionPropertyOkay);
    printf("pixel transfer exact %d\n", transferOkay);
    printf("pixel rotation exact %d\n", rotationOkay);
    printf("H.264 encode and decode %d\n", codecOkay);
    if (codecOkay) {
        printf("decoded frames %zu pixels %llu\n", stats.frames, (unsigned long long)stats.pixels);
        printf("decoded RGB means");
        print_mean("r", stats.red, stats.pixels);
        print_mean("g", stats.green, stats.pixels);
        print_mean("b", stats.blue, stats.pixels);
        putchar('\n');
    }
    return propertiesOkay && sessionPropertyOkay && transferOkay && rotationOkay && codecOkay ? 0 : 1;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <dav1d/dav1d.h>
#include <vpx/vpx_decoder.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static Boolean
requires_hardware(CFDictionaryRef specification)
{
    CFTypeRef value = specification ? CFDictionaryGetValue(specification, kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder) : NULL;
    return value == kCFBooleanTrue;
}

static CFDictionaryRef
pixel_buffer_attributes(CFDictionaryRef input, int32_t width, int32_t height)
{
    CFMutableDictionaryRef attributes = input ? CFDictionaryCreateMutableCopy(NULL, 0, input) :
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes)
        return NULL;
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberSInt32Type, &width);
    CFNumberRef h = CFNumberCreate(NULL, kCFNumberSInt32Type, &height);
    OSType format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFTypeRef existingFormat = CFDictionaryGetValue(attributes, kCVPixelBufferPixelFormatTypeKey);
    if (existingFormat && CFGetTypeID(existingFormat) == CFNumberGetTypeID())
        CFNumberGetValue(existingFormat, kCFNumberSInt32Type, &format);
    CFNumberRef f = CFNumberCreate(NULL, kCFNumberSInt32Type, &format);
    if (w && h && f) {
        CFDictionarySetValue(attributes, kCVPixelBufferWidthKey, w);
        CFDictionarySetValue(attributes, kCVPixelBufferHeightKey, h);
        CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, f);
    }
    if (w) CFRelease(w);
    if (h) CFRelease(h);
    if (f) CFRelease(f);
    return attributes;
}

static void
destroy_decoder(struct OpaqueVTDecompressionSession *session)
{
    if (session->codec) {
        if (session->codecType == kCMVideoCodecType_H264)
            _VTH264DecoderDestroy(session->codec);
        else if (session->codecType == VTCodecTypeVP8 || session->codecType == kCMVideoCodecType_VP9)
            _VTVpxDecoderDestroy(session->codec);
        else if (session->codecType == kCMVideoCodecType_AV1)
            _VTDav1dDecoderDestroy(session->codec);
        session->codec = NULL;
    }
}

void
_VTDecompressionSessionFinalize(VTSessionBase *base)
{
    struct OpaqueVTDecompressionSession *session = (struct OpaqueVTDecompressionSession *)base;
    destroy_decoder(session);
    if (session->formatDescription) CFRelease(session->formatDescription);
    if (session->outputAttributes) CFRelease(session->outputAttributes);
    if (session->pixelBufferPool) CFRelease(session->pixelBufferPool);
    _VTSessionBaseFinalize(base);
}

OSStatus
VTDecompressionSessionCreate(CFAllocatorRef allocator, CMVideoFormatDescriptionRef formatDescription,
                             CFDictionaryRef decoderSpecification, CFDictionaryRef destinationImageBufferAttributes,
                             const VTDecompressionOutputCallbackRecord *outputCallback,
                             VTDecompressionSessionRef *sessionOut)
{
    if (!sessionOut)
        return kVTParameterErr;
    *sessionOut = NULL;
    if (!formatDescription || !outputCallback || !outputCallback->decompressionOutputCallback)
        return kVTParameterErr;
    if (requires_hardware(decoderSpecification))
        return kVTVideoDecoderNotAvailableNowErr;
    CMVideoCodecType codecType = CMFormatDescriptionGetMediaSubType(formatDescription);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    if (dimensions.width <= 0 || dimensions.height <= 0)
        return kVTParameterErr;
    struct OpaqueVTDecompressionSession *session = (struct OpaqueVTDecompressionSession *)
        _VTCreateSession(allocator, VTKindDecompression, sizeof(struct OpaqueVTDecompressionSession));
    if (!session)
        return kVTAllocationFailedErr;
    session->codecType = codecType;
    session->width = dimensions.width;
    session->height = dimensions.height;
    session->formatDescription = CFRetain(formatDescription);
    session->callback = *outputCallback;
    if (destinationImageBufferAttributes)
        session->outputAttributes = CFRetain(destinationImageBufferAttributes);
    CFDictionaryRef attributes = pixel_buffer_attributes(destinationImageBufferAttributes, session->width, session->height);
    if (attributes) {
        CVReturn result = CVPixelBufferPoolCreate(allocator, NULL, attributes, &session->pixelBufferPool);
        CFRelease(attributes);
        if (result != kCVReturnSuccess) {
            CFRelease(session);
            return kVTAllocationFailedErr;
        }
    }
    if (codecType == kCMVideoCodecType_H264)
        session->codec = _VTH264DecoderCreate();
    else if (codecType == VTCodecTypeVP8 || codecType == kCMVideoCodecType_VP9)
        session->codec = _VTVpxDecoderCreate(codecType, 1);
    else if (codecType == kCMVideoCodecType_AV1)
        session->codec = _VTDav1dDecoderCreate(1);
    else {
        CFRelease(session);
        return kVTCouldNotFindVideoDecoderErr;
    }
    if (!session->codec) {
        CFRelease(session);
        return kVTCouldNotCreateInstanceErr;
    }
    *sessionOut = session;
    return noErr;
}

void
VTDecompressionSessionInvalidate(VTDecompressionSessionRef sessionRef)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindDecompression) return;
    struct OpaqueVTDecompressionSession *session = (struct OpaqueVTDecompressionSession *)base;
    pthread_mutex_lock(&base->lock);
    if (!base->invalidated) {
        base->invalidated = true;
        destroy_decoder(session);
    }
    pthread_mutex_unlock(&base->lock);
}

Boolean
VTDecompressionSessionCanAcceptFormatDescription(VTDecompressionSessionRef sessionRef, CMVideoFormatDescriptionRef formatDescription)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindDecompression || !formatDescription)
        return false;
    struct OpaqueVTDecompressionSession *session = (struct OpaqueVTDecompressionSession *)base;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    return !base->invalidated && CMFormatDescriptionGetMediaSubType(formatDescription) == session->codecType &&
        dimensions.width == session->width && dimensions.height == session->height;
}

static Boolean
has_start_code(const uint8_t *data, size_t length)
{
    return length >= 3 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (length >= 4 && data[2] == 0 && data[3] == 1));
}

static Boolean
append_h264_parameter_sets(struct OpaqueVTDecompressionSession *session, uint8_t **bytes, size_t *length, size_t *capacity)
{
    size_t parameterSetCount = 0;
    int nalLengthSize = 0;
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(session->formatDescription, 0, NULL, NULL,
                                                                           &parameterSetCount, &nalLengthSize);
    if (status != noErr || parameterSetCount == 0)
        return false;
    for (size_t i = 0; i < parameterSetCount; i++) {
        const uint8_t *parameterSet = NULL;
        size_t parameterSetSize = 0;
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(session->formatDescription, i, &parameterSet,
                                                                     &parameterSetSize, NULL, NULL);
        if (status != noErr || !parameterSet || !parameterSetSize)
            return false;
        if (*length + 4 + parameterSetSize > *capacity) {
            size_t need = *length + 4 + parameterSetSize;
            size_t next = *capacity ? *capacity : 64;
            while (next < need) next *= 2;
            uint8_t *larger = realloc(*bytes, next);
            if (!larger) return false;
            *bytes = larger; *capacity = next;
        }
        (*bytes)[(*length)++] = 0; (*bytes)[(*length)++] = 0; (*bytes)[(*length)++] = 0; (*bytes)[(*length)++] = 1;
        memcpy(*bytes + *length, parameterSet, parameterSetSize);
        *length += parameterSetSize;
    }
    (void)nalLengthSize;
    return true;
}

static OSStatus
h264_annex_b(struct OpaqueVTDecompressionSession *session, const uint8_t *source, size_t sourceLength,
             uint8_t **bytesOut, size_t *lengthOut)
{
    size_t capacity = sourceLength + 256, length = 0;
    uint8_t *bytes = malloc(capacity);
    if (!bytes) return kVTAllocationFailedErr;
    if (!has_start_code(source, sourceLength)) {
        int nalLengthSize = 0;
        OSStatus result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(session->formatDescription, 0, NULL, NULL, NULL, &nalLengthSize);
        if (result != noErr || nalLengthSize == 0 || nalLengthSize > 4) { free(bytes); return kVTVideoDecoderBadDataErr; }
        size_t cursor = 0;
        while (cursor + nalLengthSize <= sourceLength) {
            size_t nalLength = 0;
            for (size_t i = 0; i < (size_t)nalLengthSize; i++) nalLength = (nalLength << 8) | source[cursor++];
            if (!nalLength || nalLength > sourceLength - cursor) { free(bytes); return kVTVideoDecoderBadDataErr; }
            if (length + 4 + nalLength > capacity) {
                size_t next = capacity;
                while (next < length + 4 + nalLength) next *= 2;
                uint8_t *larger = realloc(bytes, next);
                if (!larger) { free(bytes); return kVTAllocationFailedErr; }
                bytes = larger; capacity = next;
            }
            bytes[length++] = 0; bytes[length++] = 0; bytes[length++] = 0; bytes[length++] = 1;
            memcpy(bytes + length, source + cursor, nalLength);
            length += nalLength; cursor += nalLength;
        }
        if (cursor != sourceLength) { free(bytes); return kVTVideoDecoderBadDataErr; }
    } else {
        memcpy(bytes, source, sourceLength);
        length = sourceLength;
    }
    if (!session->h264HeadersSent) {
        uint8_t *withSets = NULL;
        size_t withSetsCapacity = length + 256, withSetsLength = 0;
        withSets = malloc(withSetsCapacity);
        if (!withSets) { free(bytes); return kVTAllocationFailedErr; }
        if (!append_h264_parameter_sets(session, &withSets, &withSetsLength, &withSetsCapacity)) {
            free(withSets); free(bytes); return kVTVideoDecoderBadDataErr;
        }
        if (withSetsLength + length > withSetsCapacity) {
            uint8_t *larger = realloc(withSets, withSetsLength + length);
            if (!larger) { free(withSets); free(bytes); return kVTAllocationFailedErr; }
            withSets = larger;
        }
        memcpy(withSets + withSetsLength, bytes, length);
        withSetsLength += length;
        free(bytes);
        bytes = withSets;
        length = withSetsLength;
    }
    *bytesOut = bytes;
    *lengthOut = length;
    return noErr;
}

OSStatus
_VTCreatePixelBufferFromDecodedFrame(VTDecodedFrame *frame, CFDictionaryRef inputAttributes, CVPixelBufferRef *bufferOut)
{
    if (!frame || !frame->data || !frame->width || !frame->height || !bufferOut)
        return kVTVideoDecoderBadDataErr;
    *bufferOut = NULL;
    OSType format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFTypeRef value = inputAttributes ? CFDictionaryGetValue(inputAttributes, kCVPixelBufferPixelFormatTypeKey) : NULL;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberSInt32Type, &format);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        format != kCVPixelFormatType_420YpCbCr8Planar && format != kCVPixelFormatType_32BGRA &&
        format != kCVPixelFormatType_32ARGB && format != kCVPixelFormatType_32RGBA)
        return kVTVideoDecoderUnsupportedDataFormatErr;
    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(NULL, (size_t)frame->width, (size_t)frame->height, format, inputAttributes, &buffer);
    if (result != kCVReturnSuccess || !buffer)
        return kVTAllocationFailedErr;
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CFRelease(buffer);
        return kVTVideoDecoderMalfunctionErr;
    }
    size_t width = (size_t)frame->width, height = (size_t)frame->height;
    size_t chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2;
    size_t ySize = frame->yStride * height, chromaSize = frame->uStride * chromaHeight;
    if (format == kCVPixelFormatType_420YpCbCr8Planar) {
        if (CVPixelBufferGetPlaneCount(buffer) < 3) result = kCVReturnInvalidPixelFormat;
        else {
            for (size_t y = 0; y < height; y++) memcpy((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), frame->data + y * frame->yStride, width);
            for (size_t y = 0; y < chromaHeight; y++) {
                memcpy((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), frame->data + ySize + y * frame->uStride, chromaWidth);
                memcpy((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 2) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 2), frame->data + ySize + chromaSize + y * frame->vStride, chromaWidth);
            }
        }
    } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        if (CVPixelBufferGetPlaneCount(buffer) < 2) result = kCVReturnInvalidPixelFormat;
        else {
            for (size_t y = 0; y < height; y++) memcpy((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), frame->data + y * frame->yStride, width);
            for (size_t y = 0; y < chromaHeight; y++) {
                uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
                for (size_t x = 0; x < chromaWidth; x++) {
                    uv[2 * x] = frame->data[ySize + y * frame->uStride + x];
                    uv[2 * x + 1] = frame->data[ySize + chromaSize + y * frame->vStride + x];
                }
            }
        }
    } else {
        uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        if (!base) result = kCVReturnInvalidArgument;
        else for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
            int yy = frame->data[y * frame->yStride + x];
            int uu = frame->data[ySize + (y / 2) * frame->uStride + x / 2] - 128;
            int vv = frame->data[ySize + chromaSize + (y / 2) * frame->vStride + x / 2] - 128;
            int c = yy - 16;
            uint8_t r = (uint8_t)(fmin(255, fmax(0, (298 * c + 409 * vv + 128) >> 8)));
            uint8_t g = (uint8_t)(fmin(255, fmax(0, (298 * c - 100 * uu - 208 * vv + 128) >> 8)));
            uint8_t b = (uint8_t)(fmin(255, fmax(0, (298 * c + 516 * uu + 128) >> 8)));
            uint8_t *pixel = base + y * rowBytes + 4 * x;
            if (format == kCVPixelFormatType_32BGRA) { pixel[0] = b; pixel[1] = g; pixel[2] = r; pixel[3] = 255; }
            else if (format == kCVPixelFormatType_32ARGB) { pixel[0] = 255; pixel[1] = r; pixel[2] = g; pixel[3] = b; }
            else { pixel[0] = r; pixel[1] = g; pixel[2] = b; pixel[3] = 255; }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (result != kCVReturnSuccess) {
        CFRelease(buffer);
        return kVTVideoDecoderMalfunctionErr;
    }
    *bufferOut = buffer;
    return noErr;
}

OSStatus
VTDecompressionSessionDecodeFrame(VTDecompressionSessionRef sessionRef, CMSampleBufferRef sampleBuffer,
                                  VTDecodeFrameFlags decodeFlags, void *sourceFrameRefCon, VTDecodeInfoFlags *infoFlagsOut)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindDecompression || !sampleBuffer)
        return kVTParameterErr;
    if (CMSampleBufferGetNumSamples(sampleBuffer) != 1)
        return kVTVideoDecoderBadDataErr;
    if (infoFlagsOut) *infoFlagsOut = 0;
    struct OpaqueVTDecompressionSession *session = (struct OpaqueVTDecompressionSession *)base;
    pthread_mutex_lock(&base->lock);
    if (base->invalidated || !session->codec) {
        pthread_mutex_unlock(&base->lock);
        return kVTInvalidSessionErr;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
    if (!length || !CMSampleBufferDataIsReady(sampleBuffer)) {
        pthread_mutex_unlock(&base->lock);
        return kVTVideoDecoderBadDataErr;
    }
    uint8_t *copied = NULL;
    char *dataPointer = NULL;
    size_t lengthAtOffset = 0, totalLength = 0;
    OSStatus status = CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, &totalLength, &dataPointer);
    const uint8_t *bytes = (const uint8_t *)dataPointer;
    if (status != noErr || !bytes || totalLength < length || lengthAtOffset < length) {
        copied = malloc(length);
        if (!copied) { pthread_mutex_unlock(&base->lock); return kVTAllocationFailedErr; }
        if (CMBlockBufferCopyDataBytes(block, 0, length, copied) != noErr) {
            free(copied); pthread_mutex_unlock(&base->lock); return kVTVideoDecoderBadDataErr;
        }
        bytes = copied;
    }
    uint8_t *annexB = NULL;
    size_t inputLength = length;
    if (session->codecType == kCMVideoCodecType_H264) {
        status = h264_annex_b(session, bytes, length, &annexB, &inputLength);
        if (status != noErr) {
            free(copied); pthread_mutex_unlock(&base->lock); return status;
        }
        bytes = annexB;
    }
    VTDecodedFrame frame = {0};
    if (session->codecType == kCMVideoCodecType_H264)
        status = _VTH264DecoderDecode(session->codec, bytes, inputLength, &frame);
    else if (session->codecType == VTCodecTypeVP8 || session->codecType == kCMVideoCodecType_VP9)
        status = _VTVpxDecoderDecode(session->codec, bytes, inputLength, &frame);
    else
        status = _VTDav1dDecoderDecode(session->codec, bytes, inputLength, &frame);
    if (session->codecType == kCMVideoCodecType_H264 && status == noErr)
        session->h264HeadersSent = true;
    free(annexB); free(copied);
    pthread_mutex_unlock(&base->lock);
    if (status != noErr) {
        _VTDecodedFrameFree(&frame);
        return status;
    }
    if (frame.data && (frame.width != session->width || frame.height != session->height)) {
        _VTDecodedFrameFree(&frame);
        return kVTVideoDecoderUnsupportedDataFormatErr;
    }
    if ((decodeFlags & kVTDecodeFrame_DoNotOutputFrame) || !frame.data) {
        session->callback.decompressionOutputCallback(session->callback.decompressionOutputRefCon, sourceFrameRefCon, noErr,
                                                       0, NULL, CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                                       CMSampleBufferGetDuration(sampleBuffer));
        _VTDecodedFrameFree(&frame);
        return noErr;
    }
    CVPixelBufferRef output = NULL;
    status = _VTCreatePixelBufferFromDecodedFrame(&frame, session->outputAttributes, &output);
    _VTDecodedFrameFree(&frame);
    if (status != noErr) {
        session->callback.decompressionOutputCallback(session->callback.decompressionOutputRefCon, sourceFrameRefCon, status,
                                                       0, NULL, CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                                       CMSampleBufferGetDuration(sampleBuffer));
        return noErr;
    }
    if (infoFlagsOut) *infoFlagsOut = kVTDecodeInfo_ImageBufferModifiable;
    session->callback.decompressionOutputCallback(session->callback.decompressionOutputRefCon, sourceFrameRefCon, noErr,
                                                   kVTDecodeInfo_ImageBufferModifiable, output,
                                                   CMSampleBufferGetPresentationTimeStamp(sampleBuffer), CMSampleBufferGetDuration(sampleBuffer));
    CFRelease(output);
    return noErr;
}

OSStatus
VTDecompressionSessionFinishDelayedFrames(VTDecompressionSessionRef sessionRef)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    return session && session->kind == VTKindDecompression && !session->invalidated ? noErr : kVTInvalidSessionErr;
}

OSStatus
VTDecompressionSessionWaitForAsynchronousFrames(VTDecompressionSessionRef sessionRef)
{
    return VTDecompressionSessionFinishDelayedFrames(sessionRef);
}

Boolean
VTIsHardwareDecodeSupported(CMVideoCodecType codecType)
{
    (void)codecType;
    return false;
}

Boolean
VTIsStereoMVHEVCDecodeSupported(void)
{
    return false;
}

void
VTRegisterSupplementalVideoDecoderIfAvailable(CMVideoCodecType codecType)
{
    (void)codecType;
    /* Finch has no downloadable or extension-provided decoders to register. */
}

OSStatus
VTCopyVideoDecoderExtensionProperties(CMFormatDescriptionRef formatDescription, CFDictionaryRef *propertiesOut)
{
    if (!formatDescription || !propertiesOut)
        return kVTParameterErr;
    *propertiesOut = NULL;
    return kVTCouldNotFindExtensionErr;
}

void
VTRegisterProfessionalVideoWorkflowVideoDecoders(void)
{
    /* Finch has no Media Extension decoders to register. */
}

void
VTRegisterProfessionalVideoWorkflowVideoEncoders(void)
{
    /* Finch has no Media Extension encoders to register. */
}

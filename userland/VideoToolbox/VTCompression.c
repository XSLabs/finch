/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static CFStringRef const kFinchH264EncoderID = CFSTR("org.finch.openh264");

static Boolean
specification_requires_hardware(CFDictionaryRef specification)
{
    CFTypeRef value = specification ? CFDictionaryGetValue(specification,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder) : NULL;
    return value == kCFBooleanTrue;
}

static OSStatus
make_pixel_buffer_attributes(CFDictionaryRef input, int32_t width, int32_t height, CFMutableDictionaryRef *out)
{
    CFMutableDictionaryRef attributes = input ? CFDictionaryCreateMutableCopy(NULL, 0, input) :
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes)
        return kVTAllocationFailedErr;
    int32_t pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFTypeRef value = CFDictionaryGetValue(attributes, kCVPixelBufferPixelFormatTypeKey);
    if (value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        !CFNumberGetValue(value, kCFNumberSInt32Type, &pixelFormat)) {
        CFRelease(attributes);
        return kVTParameterErr;
    }
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberSInt32Type, &width);
    CFNumberRef h = CFNumberCreate(NULL, kCFNumberSInt32Type, &height);
    CFNumberRef f = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixelFormat);
    if (!w || !h || !f) {
        if (w) CFRelease(w);
        if (h) CFRelease(h);
        if (f) CFRelease(f);
        CFRelease(attributes);
        return kVTAllocationFailedErr;
    }
    CFDictionarySetValue(attributes, kCVPixelBufferWidthKey, w);
    CFDictionarySetValue(attributes, kCVPixelBufferHeightKey, h);
    CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, f);
    CFRelease(w);
    CFRelease(h);
    CFRelease(f);
    *out = attributes;
    return noErr;
}

static Boolean
number_as_double(CFTypeRef value, double *result)
{
    if (!_VTIsCFNumber(value) || !CFNumberGetValue(value, kCFNumberDoubleType, result) || !isfinite(*result))
        return false;
    return true;
}

static int32_t
default_bitrate(int32_t width, int32_t height)
{
    int64_t value = (int64_t)width * height * 4;
    return value > INT32_MAX ? INT32_MAX : (int32_t)value;
}

static void
destroy_compressor(struct OpaqueVTCompressionSession *session)
{
    if (session->codec) {
        _VTH264EncoderDestroy(session->codec);
        session->codec = NULL;
    }
}

void
_VTCompressionSessionFinalize(VTSessionBase *base)
{
    struct OpaqueVTCompressionSession *session = (struct OpaqueVTCompressionSession *)base;
    destroy_compressor(session);
    if (session->pixelBufferPool) CFRelease(session->pixelBufferPool);
    if (session->formatDescription) CFRelease(session->formatDescription);
    if (session->profile) CFRelease(session->profile);
    _VTSessionBaseFinalize(base);
}

static size_t
find_start_code(const uint8_t *bytes, size_t length, size_t from, size_t *codeLength)
{
    for (size_t i = from; i + 3 <= length; i++) {
        if (bytes[i] || bytes[i + 1])
            continue;
        if (bytes[i + 2] == 1) {
            *codeLength = 3;
            return i;
        }
        if (i + 4 <= length && bytes[i + 2] == 0 && bytes[i + 3] == 1) {
            *codeLength = 4;
            return i;
        }
    }
    return SIZE_MAX;
}

static OSStatus
make_h264_sample(struct OpaqueVTCompressionSession *session, const uint8_t *bytes, size_t length,
                 CMTime pts, CMTime duration, Boolean keyFrame, CMSampleBufferRef *sampleOut)
{
    *sampleOut = NULL;
    if (!bytes || !length)
        return kVTVideoEncoderMalfunctionErr;
    const uint8_t *sps = NULL, *pps = NULL;
    size_t spsLength = 0, ppsLength = 0;
    if (length > SIZE_MAX - 128)
        return kVTAllocationFailedErr;
    size_t avccCapacity = length + 128;
    uint8_t *avcc = malloc(avccCapacity);
    if (!avcc)
        return kVTAllocationFailedErr;
    size_t avccLength = 0, prefixLength = 0;
    size_t start = find_start_code(bytes, length, 0, &prefixLength);
    if (start == SIZE_MAX) {
        free(avcc);
        return kVTVideoEncoderMalfunctionErr;
    }
    while (start != SIZE_MAX) {
        size_t nalStart = start + prefixLength;
        size_t nextPrefix = 0;
        size_t nextStart = find_start_code(bytes, length, nalStart, &nextPrefix);
        size_t nalEnd = nextStart == SIZE_MAX ? length : nextStart;
        while (nalEnd > nalStart && bytes[nalEnd - 1] == 0)
            nalEnd--;
        size_t nalLength = nalEnd - nalStart;
        if (nalLength) {
            uint8_t type = bytes[nalStart] & 0x1f;
            if (type == 7 && !sps) {
                sps = bytes + nalStart;
                spsLength = nalLength;
            } else if (type == 8 && !pps) {
                pps = bytes + nalStart;
                ppsLength = nalLength;
            } else if (type != 7 && type != 8) {
                if (nalLength > UINT32_MAX || avccLength > SIZE_MAX - nalLength - 4) {
                    free(avcc);
                    return kVTAllocationFailedErr;
                }
                size_t needed = avccLength + nalLength + 4;
                if (needed > avccCapacity) {
                    size_t nextCapacity = avccCapacity;
                    while (nextCapacity < needed) {
                        if (nextCapacity > SIZE_MAX / 2) { nextCapacity = needed; break; }
                        nextCapacity *= 2;
                    }
                    uint8_t *larger = realloc(avcc, nextCapacity);
                    if (!larger) { free(avcc); return kVTAllocationFailedErr; }
                    avcc = larger;
                    avccCapacity = nextCapacity;
                }
                avcc[avccLength++] = (uint8_t)(nalLength >> 24);
                avcc[avccLength++] = (uint8_t)(nalLength >> 16);
                avcc[avccLength++] = (uint8_t)(nalLength >> 8);
                avcc[avccLength++] = (uint8_t)nalLength;
                memcpy(avcc + avccLength, bytes + nalStart, nalLength);
                avccLength += nalLength;
            }
        }
        if (nextStart == SIZE_MAX)
            break;
        start = nextStart;
        prefixLength = nextPrefix;
    }
    if (sps && pps) {
        const uint8_t *sets[] = {sps, pps};
        size_t sizes[] = {spsLength, ppsLength};
        CMVideoFormatDescriptionRef format = NULL;
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &format);
        if (status != noErr || !format) {
            free(avcc);
            return status == noErr ? kVTVideoEncoderMalfunctionErr : status;
        }
        if (session->formatDescription) CFRelease(session->formatDescription);
        session->formatDescription = format;
    }
    if (!session->formatDescription || !avccLength) {
        free(avcc);
        return kVTVideoEncoderMalfunctionErr;
    }
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, avcc, avccLength, kCFAllocatorMalloc,
        NULL, 0, avccLength, 0, &block);
    if (status != noErr || !block) {
        free(avcc);
        return status == noErr ? kVTAllocationFailedErr : status;
    }
    CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
    size_t sampleSize = avccLength;
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreate(NULL, block, true, NULL, NULL, session->formatDescription, 1, 1,
                                  &timing, 1, &sampleSize, &sample);
    CFRelease(block);
    if (status != noErr || !sample)
        return status == noErr ? kVTAllocationFailedErr : status;
    CMSetAttachment(sample, kCMSampleAttachmentKey_NotSync,
                    keyFrame ? kCFBooleanFalse : kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    *sampleOut = sample;
    return noErr;
}

OSStatus
VTCompressionSessionCreate(CFAllocatorRef allocator, int32_t width, int32_t height, CMVideoCodecType codecType,
                           CFDictionaryRef encoderSpecification, CFDictionaryRef sourceImageBufferAttributes,
                           CFAllocatorRef compressedDataAllocator, VTCompressionOutputCallback outputCallback,
                           void *outputCallbackRefCon, VTCompressionSessionRef *sessionOut)
{
    (void)compressedDataAllocator;
    if (!sessionOut)
        return kVTParameterErr;
    *sessionOut = NULL;
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        return kVTParameterErr;
    if (codecType != kCMVideoCodecType_H264)
        return kVTCouldNotFindVideoEncoderErr;
    if (!outputCallback)
        return kVTParameterErr;
    if (specification_requires_hardware(encoderSpecification))
        return kVTVideoEncoderNotAvailableNowErr;
    CFTypeRef requestedID = encoderSpecification ? CFDictionaryGetValue(encoderSpecification,
        kVTVideoEncoderSpecification_EncoderID) : NULL;
    if (requestedID && (!CFGetTypeID(requestedID) || CFGetTypeID(requestedID) != CFStringGetTypeID() ||
        !CFEqual(requestedID, kFinchH264EncoderID)))
        return kVTCouldNotFindVideoEncoderErr;

    struct OpaqueVTCompressionSession *session = (struct OpaqueVTCompressionSession *)
        _VTCreateSession(allocator, VTKindCompression, sizeof(struct OpaqueVTCompressionSession));
    if (!session)
        return kVTAllocationFailedErr;
    session->width = width;
    session->height = height;
    session->codecType = codecType;
    session->callback = outputCallback;
    session->callbackRefCon = outputCallbackRefCon;
    session->frameRate = 30;
    session->bitrate = default_bitrate(width, height);
    session->keyFrameInterval = 30;
    session->profile = CFRetain(kVTProfileLevel_H264_Baseline_AutoLevel);
    session->codec = _VTH264EncoderCreate(width, height, session->frameRate, session->bitrate, session->profile);
    if (!session->codec) {
        CFRelease(session);
        return kVTCouldNotCreateInstanceErr;
    }
    CFMutableDictionaryRef attributes = NULL;
    OSStatus status = make_pixel_buffer_attributes(sourceImageBufferAttributes, width, height, &attributes);
    if (status != noErr) {
        CFRelease(session);
        return status;
    }
    CVReturn result = CVPixelBufferPoolCreate(allocator, NULL, attributes, &session->pixelBufferPool);
    CFRelease(attributes);
    if (result != kCVReturnSuccess || !session->pixelBufferPool) {
        CFRelease(session);
        return kVTAllocationFailedErr;
    }
    *sessionOut = session;
    return noErr;
}

void
VTCompressionSessionInvalidate(VTCompressionSessionRef sessionRef)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindCompression)
        return;
    pthread_mutex_lock(&base->lock);
    if (!base->invalidated) {
        base->invalidated = true;
        destroy_compressor((struct OpaqueVTCompressionSession *)base);
    }
    pthread_mutex_unlock(&base->lock);
}

CVPixelBufferPoolRef
VTCompressionSessionGetPixelBufferPool(VTCompressionSessionRef sessionRef)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindCompression || base->invalidated)
        return NULL;
    return ((struct OpaqueVTCompressionSession *)base)->pixelBufferPool;
}

OSStatus
VTCompressionSessionPrepareToEncodeFrames(VTCompressionSessionRef sessionRef)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindCompression)
        return kVTParameterErr;
    struct OpaqueVTCompressionSession *session = (struct OpaqueVTCompressionSession *)base;
    pthread_mutex_lock(&base->lock);
    Boolean live = !base->invalidated && session->codec != NULL;
    pthread_mutex_unlock(&base->lock);
    return live ? noErr : kVTInvalidSessionErr;
}

OSStatus
VTCompressionSessionEncodeFrame(VTCompressionSessionRef sessionRef, CVImageBufferRef imageBuffer,
                                CMTime presentationTimeStamp, CMTime duration, CFDictionaryRef frameProperties,
                                void *sourceFrameRefCon, VTEncodeInfoFlags *infoFlagsOut)
{
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindCompression || !imageBuffer)
        return kVTParameterErr;
    if (infoFlagsOut) *infoFlagsOut = 0;
    CVPixelBufferRef sourceBuffer = (CVPixelBufferRef)imageBuffer;
    if (CVPixelBufferGetWidth(sourceBuffer) != (size_t)((struct OpaqueVTCompressionSession *)base)->width ||
        CVPixelBufferGetHeight(sourceBuffer) != (size_t)((struct OpaqueVTCompressionSession *)base)->height)
        return kVTParameterErr;
    CFTypeRef forceKey = frameProperties ? CFDictionaryGetValue(frameProperties, kVTEncodeFrameOptionKey_ForceKeyFrame) : NULL;
    if (forceKey && !_VTIsCFBoolean(forceKey))
        return kVTParameterErr;
    struct OpaqueVTCompressionSession *session = (struct OpaqueVTCompressionSession *)base;
    pthread_mutex_lock(&base->lock);
    if (base->invalidated || !session->codec) {
        pthread_mutex_unlock(&base->lock);
        return kVTInvalidSessionErr;
    }
    if (session->hasPresentationTime && CMTIME_IS_NUMERIC(presentationTimeStamp) &&
        CMTIME_IS_NUMERIC(session->lastPresentationTime) && CMTimeCompare(presentationTimeStamp, session->lastPresentationTime) <= 0) {
        pthread_mutex_unlock(&base->lock);
        return kVTParameterErr;
    }
    CVPixelBufferRef converted = NULL;
    CVReturn cv = CVPixelBufferCreate(NULL, (size_t)session->width, (size_t)session->height,
        kCVPixelFormatType_420YpCbCr8Planar, NULL, &converted);
    if (cv != kCVReturnSuccess || !converted) {
        pthread_mutex_unlock(&base->lock);
        return kVTAllocationFailedErr;
    }
    VTPixelTransferSessionRef transfer = NULL;
    OSStatus status = VTPixelTransferSessionCreate(NULL, &transfer);
    if (status == noErr)
        status = VTPixelTransferSessionTransferImage(transfer, sourceBuffer, converted);
    if (transfer) CFRelease(transfer);
    uint8_t *encoded = NULL;
    size_t encodedLength = 0;
    Boolean keyFrame = false;
    CMTime pts = presentationTimeStamp;
    if (!CMTIME_IS_NUMERIC(pts))
        pts = CMTimeMake(session->nextTimestamp++, 1000);
    int64_t timestamp = CMTimeConvertScale(pts, 1000, kCMTimeRoundingMethod_QuickTime).value;
    if (status == noErr && forceKey == kCFBooleanTrue)
        status = _VTH264EncoderForceKeyFrame(session->codec);
    if (status == noErr && CVPixelBufferLockBaseAddress(converted, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        status = kVTVideoEncoderMalfunctionErr;
    if (status == noErr) {
        if (CVPixelBufferGetPlaneCount(converted) < 3)
            status = kVTVideoEncoderMalfunctionErr;
        else {
            const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(converted, 0);
            const uint8_t *u = CVPixelBufferGetBaseAddressOfPlane(converted, 1);
            const uint8_t *v = CVPixelBufferGetBaseAddressOfPlane(converted, 2);
            if (!y || !u || !v)
                status = kVTVideoEncoderMalfunctionErr;
            else
                status = _VTH264EncoderEncode(session->codec, y, u, v,
                    CVPixelBufferGetBytesPerRowOfPlane(converted, 0), CVPixelBufferGetBytesPerRowOfPlane(converted, 1),
                    CVPixelBufferGetBytesPerRowOfPlane(converted, 2), timestamp, &encoded, &encodedLength, &keyFrame);
        }
        CVPixelBufferUnlockBaseAddress(converted, kCVPixelBufferLock_ReadOnly);
    }
    CFRelease(converted);
    CMSampleBufferRef sample = NULL;
    if (status == noErr && encodedLength)
        status = make_h264_sample(session, encoded, encodedLength, pts, duration, keyFrame, &sample);
    free(encoded);
    if (status == noErr && !encodedLength)
        status = kVTVideoEncoderMalfunctionErr;
    if (status == noErr) {
        session->lastPresentationTime = presentationTimeStamp;
        session->hasPresentationTime = CMTIME_IS_NUMERIC(presentationTimeStamp);
        session->nextTimestamp += session->frameRate > 0 ? 1000 / session->frameRate : 33;
    }
    VTCompressionOutputCallback callback = session->callback;
    void *callbackRefCon = session->callbackRefCon;
    pthread_mutex_unlock(&base->lock);
    if (status == noErr && sample && callback)
        callback(callbackRefCon, sourceFrameRefCon, noErr, 0, sample);
    if (sample) CFRelease(sample);
    return status;
}

OSStatus
VTCompressionSessionCompleteFrames(VTCompressionSessionRef sessionRef, CMTime completeUntilPresentationTimeStamp)
{
    (void)completeUntilPresentationTimeStamp;
    VTSessionBase *base = _VTGetSession(sessionRef);
    if (!base || base->kind != VTKindCompression)
        return kVTParameterErr;
    pthread_mutex_lock(&base->lock);
    Boolean live = !base->invalidated;
    pthread_mutex_unlock(&base->lock);
    return live ? noErr : kVTInvalidSessionErr;
}

static CFNumberRef
number_i32(int32_t value)
{
    return CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
}

OSStatus
VTCopyVideoEncoderList(CFDictionaryRef options, CFArrayRef *listOut)
{
    (void)options;
    if (!listOut)
        return kVTParameterErr;
    *listOut = NULL;
    const void *keys[] = {kVTVideoEncoderList_CodecType, kVTVideoEncoderList_EncoderID,
        kVTVideoEncoderList_CodecName, kVTVideoEncoderList_EncoderName, kVTVideoEncoderList_DisplayName,
        kVTVideoEncoderList_IsHardwareAccelerated, kVTVideoEncoderList_SupportsFrameReordering};
    int32_t codec = kCMVideoCodecType_H264;
    CFNumberRef codecValue = number_i32(codec);
    CFStringRef codecName = CFSTR("H.264");
    CFStringRef encoderName = CFSTR("Finch OpenH264");
    const void *values[] = {codecValue, kFinchH264EncoderID, codecName, encoderName, encoderName,
        kCFBooleanFalse, kCFBooleanFalse};
    CFDictionaryRef encoder = codecValue ? CFDictionaryCreate(NULL, keys, values, 7,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    if (codecValue) CFRelease(codecValue);
    if (!encoder)
        return kVTAllocationFailedErr;
    const void *items[] = {encoder};
    CFArrayRef list = CFArrayCreate(NULL, items, 1, &kCFTypeArrayCallBacks);
    CFRelease(encoder);
    if (!list)
        return kVTAllocationFailedErr;
    *listOut = list;
    return noErr;
}

OSStatus
VTCopySupportedPropertyDictionaryForEncoder(int32_t width, int32_t height, CMVideoCodecType codecType,
                                            CFDictionaryRef encoderSpecification, CFStringRef *encoderIDOut,
                                            CFDictionaryRef *supportedPropertiesOut)
{
    if (encoderIDOut) *encoderIDOut = NULL;
    if (supportedPropertiesOut) *supportedPropertiesOut = NULL;
    if (width <= 0 || height <= 0 || (!encoderIDOut && !supportedPropertiesOut))
        return kVTParameterErr;
    if (codecType != kCMVideoCodecType_H264)
        return kVTCouldNotFindVideoEncoderErr;
    if (specification_requires_hardware(encoderSpecification))
        return kVTVideoEncoderNotAvailableNowErr;
    CFTypeRef requestedID = encoderSpecification ? CFDictionaryGetValue(encoderSpecification,
        kVTVideoEncoderSpecification_EncoderID) : NULL;
    if (requestedID && (!_VTIsCFString(requestedID) || !CFEqual(requestedID, kFinchH264EncoderID)))
        return kVTCouldNotFindVideoEncoderErr;
    if (encoderIDOut)
        *encoderIDOut = CFRetain(kFinchH264EncoderID);
    if (supportedPropertiesOut) {
        *supportedPropertiesOut = _VTCreateSupportedProperties(VTKindCompression, codecType);
        if (!*supportedPropertiesOut) {
            if (encoderIDOut && *encoderIDOut) { CFRelease(*encoderIDOut); *encoderIDOut = NULL; }
            return kVTAllocationFailedErr;
        }
    }
    return noErr;
}

OSStatus
_VTCompressionPropertyChanged(struct OpaqueVTCompressionSession *session, CFStringRef key, CFTypeRef value)
{
    if (!session || !key)
        return kVTParameterErr;
    int32_t bitrate = session->bitrate;
    int32_t frameRate = session->frameRate;
    int32_t keyInterval = session->keyFrameInterval;
    CFStringRef profile = session->profile;
    if (CFEqual(key, kVTCompressionPropertyKey_AverageBitRate)) {
        double number = 0;
        if (value && (!number_as_double(value, &number) || number < 1 || number > INT32_MAX))
            return kVTParameterErr;
        bitrate = value ? (int32_t)number : default_bitrate(session->width, session->height);
    } else if (CFEqual(key, kVTCompressionPropertyKey_ExpectedFrameRate)) {
        double number = 0;
        if (value && (!number_as_double(value, &number) || number < 1 || number > 240))
            return kVTParameterErr;
        frameRate = value ? (int32_t)lrint(number) : 30;
    } else if (CFEqual(key, kVTCompressionPropertyKey_MaxKeyFrameInterval)) {
        double number = 0;
        if (value && (!number_as_double(value, &number) || number < 1 || number > INT32_MAX))
            return kVTParameterErr;
        keyInterval = value ? (int32_t)number : 30;
    } else if (CFEqual(key, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration)) {
        double seconds = 0;
        if (value && (!number_as_double(value, &seconds) || seconds <= 0 || seconds > 86400))
            return kVTParameterErr;
        keyInterval = value ? (int32_t)fmin(INT32_MAX, ceil(seconds * frameRate)) : 30;
    } else if (CFEqual(key, kVTCompressionPropertyKey_ProfileLevel)) {
        if (value && (!_VTIsCFString(value) || !(CFEqual(value, kVTProfileLevel_H264_Baseline_AutoLevel) ||
            CFEqual(value, kVTProfileLevel_H264_Main_AutoLevel) || CFEqual(value, kVTProfileLevel_H264_High_AutoLevel))))
            return kVTPropertyNotSupportedErr;
        profile = value ? (CFStringRef)value : kVTProfileLevel_H264_Baseline_AutoLevel;
    } else if (CFEqual(key, kVTCompressionPropertyKey_AllowFrameReordering) ||
               CFEqual(key, kVTCompressionPropertyKey_RealTime)) {
        /* The encoder is synchronous and does not reorder frames; both flags are informational. */
        return noErr;
    } else {
        return noErr;
    }
    if (!session->codec)
        return kVTInvalidSessionErr;
    if (!CFEqual(profile, session->profile)) {
        void *replacement = _VTH264EncoderCreate(session->width, session->height, frameRate, bitrate, profile);
        if (!replacement)
            return kVTPropertyNotSupportedErr;
        OSStatus status = _VTH264EncoderSetKeyFrameInterval(replacement, keyInterval);
        if (status != noErr) {
            _VTH264EncoderDestroy(replacement);
            return status;
        }
        destroy_compressor(session);
        session->codec = replacement;
        CFRelease(session->profile);
        session->profile = CFRetain(profile);
    } else {
        OSStatus status = _VTH264EncoderSetBitrate(session->codec, bitrate);
        if (status == noErr) status = _VTH264EncoderSetFrameRate(session->codec, frameRate);
        if (status == noErr) status = _VTH264EncoderSetKeyFrameInterval(session->codec, keyInterval);
        if (status != noErr)
            return status;
    }
    session->bitrate = bitrate;
    session->frameRate = frameRate;
    session->keyFrameInterval = keyInterval;
    return noErr;
}

Boolean
VTIsStereoMVHEVCEncodeSupported(void)
{
    return false;
}

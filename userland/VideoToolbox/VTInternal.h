/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_VIDEOTOOLBOX_INTERNAL_H
#define FINCH_VIDEOTOOLBOX_INTERNAL_H

#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#ifndef __cplusplus
#include <stdatomic.h>
#endif

#define VTCodecTypeVP8 ((CMVideoCodecType)0x76703038u) /* 'vp08' */

typedef struct {
    uintptr_t isa;
#ifdef __cplusplus
    uint64_t info;
#else
    _Atomic(uint64_t) info;
#endif
} VTCFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} VTCFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const VTCFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

typedef enum {
    VTKindPixelTransfer,
    VTKindPixelRotation,
    VTKindDecompression,
    VTKindCompression
} VTKind;

typedef struct {
    VTCFRuntimeBase base;
    VTKind kind;
    pthread_mutex_t lock;
    Boolean lockInitialized;
    Boolean invalidated;
    CFMutableDictionaryRef properties;
    CFDictionaryRef supportedProperties;
} VTSessionBase;

struct OpaqueVTPixelTransferSession {
    VTSessionBase session;
};

struct OpaqueVTPixelRotationSession {
    VTSessionBase session;
};

struct OpaqueVTDecompressionSession {
    VTSessionBase session;
    CMVideoFormatDescriptionRef formatDescription;
    CMVideoCodecType codecType;
    int32_t width, height;
    CFDictionaryRef outputAttributes;
    CVPixelBufferPoolRef pixelBufferPool;
    VTDecompressionOutputCallbackRecord callback;
    void *codec;
    Boolean h264HeadersSent;
};

struct OpaqueVTCompressionSession {
    VTSessionBase session;
    int32_t width, height;
    CMVideoCodecType codecType;
    VTCompressionOutputCallback callback;
    void *callbackRefCon;
    void *codec;
    CVPixelBufferPoolRef pixelBufferPool;
    CMVideoFormatDescriptionRef formatDescription;
    CMTime lastPresentationTime;
    Boolean hasPresentationTime;
    int32_t frameRate;
    int32_t bitrate;
    int32_t keyFrameInterval;
    CFStringRef profile;
    int64_t nextTimestamp;
};

CFTypeID _VTTypeID(VTKind kind);
CFTypeRef _VTCreateSession(CFAllocatorRef allocator, VTKind kind, size_t size);
VTSessionBase *_VTGetSession(CFTypeRef object);
CFDictionaryRef _VTCreateSupportedProperties(VTKind kind, CMVideoCodecType codecType);
OSStatus _VTSetSessionProperty(VTSessionBase *session, CFStringRef key, CFTypeRef value);
CFTypeRef _VTCopySessionProperty(VTSessionBase *session, CFStringRef key);
void _VTSessionPropertyChanged(VTSessionBase *session, CFStringRef key, CFTypeRef value);
void _VTSessionBaseFinalize(VTSessionBase *session);
void _VTCompressionSessionFinalize(VTSessionBase *session);
void _VTDecompressionSessionFinalize(VTSessionBase *session);
OSStatus _VTCompressionPropertyChanged(struct OpaqueVTCompressionSession *session, CFStringRef key, CFTypeRef value);
Boolean _VTIsCFBoolean(CFTypeRef value);
Boolean _VTIsCFNumber(CFTypeRef value);
Boolean _VTIsCFString(CFTypeRef value);

typedef struct {
    int32_t width, height;
    size_t size;
    uint8_t *data;
    size_t yStride, uStride, vStride;
    int bitsPerComponent;
} VTDecodedFrame;

#ifdef __cplusplus
extern "C" {
#endif
void *_VTH264EncoderCreate(int width, int height, int frameRate, int bitrate, CFStringRef profile);
void _VTH264EncoderDestroy(void *codec);
OSStatus _VTH264EncoderSetBitrate(void *codec, int32_t bitrate);
OSStatus _VTH264EncoderSetFrameRate(void *codec, int32_t frameRate);
OSStatus _VTH264EncoderSetKeyFrameInterval(void *codec, int32_t interval);
OSStatus _VTH264EncoderSetProfile(void *codec, CFStringRef profile);
OSStatus _VTH264EncoderForceKeyFrame(void *codec);
OSStatus _VTH264EncoderEncode(void *codec, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                              size_t yStride, size_t uStride, size_t vStride, int64_t timestamp,
                              uint8_t **bytes, size_t *length, Boolean *keyFrame);
void *_VTH264DecoderCreate(void);
void _VTH264DecoderDestroy(void *codec);
OSStatus _VTH264DecoderDecode(void *codec, const uint8_t *bytes, size_t length, VTDecodedFrame *frame);
#ifdef __cplusplus
}
#endif

void *_VTVpxDecoderCreate(CMVideoCodecType codecType, int threads);
void _VTVpxDecoderDestroy(void *codec);
OSStatus _VTVpxDecoderDecode(void *codec, const uint8_t *bytes, size_t length, VTDecodedFrame *frame);
void *_VTDav1dDecoderCreate(int threads);
void _VTDav1dDecoderDestroy(void *codec);
OSStatus _VTDav1dDecoderDecode(void *codec, const uint8_t *bytes, size_t length, VTDecodedFrame *frame);
void _VTDecodedFrameFree(VTDecodedFrame *frame);

OSStatus _VTCreatePixelBufferFromDecodedFrame(VTDecodedFrame *frame, CFDictionaryRef attributes, CVPixelBufferRef *bufferOut);

#endif

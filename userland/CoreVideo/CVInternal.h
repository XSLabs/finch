/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreVideo, Finch's: what its files share. */
#ifndef FINCH_CV_INTERNAL_H
#define FINCH_CV_INTERNAL_H
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdbool.h>

/* CoreFoundation's runtime, as Finch's frameworks register their CF types. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;
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
} CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

/* A CF type's ID, registered once. */
#define CV_DEFINE_TYPE(func, name, finalize, desc)                                                                \
    static CFTypeID func##_id;                                                                                  \
    static const CFRuntimeClass func##_cls = {0, name, NULL, NULL, finalize, NULL, NULL, NULL, desc, NULL, NULL, 0}; \
    static void func##_reg(void) { func##_id = _CFRuntimeRegisterClass(&func##_cls); }                          \
    CFTypeID func(void)                                                                                         \
    {                                                                                                           \
        static pthread_once_t once = PTHREAD_ONCE_INIT;                                                         \
        pthread_once(&once, func##_reg);                                                                        \
        return func##_id;                                                                                       \
    }

static inline CFTypeRef
cv_create(CFAllocatorRef allocator, CFTypeID type, size_t size)
{
    return _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

/* What every CoreVideo buffer starts with: its attachments, in the two modes. */
typedef struct {
    CFRuntimeBase base;
    pthread_mutex_t attachmentLock;
    CFMutableDictionaryRef attachments[2]; /* [kCVAttachmentMode_ShouldNotPropagate], [..._ShouldPropagate] */
} FinchCVBuffer;

void _FinchCVBufferInit(FinchCVBuffer *b);
void _FinchCVBufferFinalize(FinchCVBuffer *b);
bool _FinchCVIsBuffer(CFTypeRef cf);

/* Pixel buffers: their size, for image buffer geometry. */
bool _FinchCVPixelBufferGetSize(CFTypeRef cf, size_t *width, size_t *height);

/* The pixel format descriptions (CVPixelFormatDescription.c). */
CFDictionaryRef _FinchCVCopyPixelFormatDescription(OSType format);

/* Pools: give a pixel buffer's memory back (CVPixelBufferPool.c). */
typedef struct __CVPixelBufferPool *FinchCVPool;
void _FinchCVPoolReturn(CVPixelBufferPoolRef pool, void *memory, size_t size, CFTypeRef surface);

#endif

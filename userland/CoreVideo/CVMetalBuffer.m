/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A Metal buffer cache that keeps each copied pixel buffer alive with its MTLBuffer. */
#include "CVInternal.h"
#import <CoreVideo/CVMetalBuffer.h>
#import <CoreVideo/CVMetalBufferCache.h>
#import <Metal/Metal.h>
#include <stdlib.h>

typedef struct {
    CFRuntimeBase base;
    __strong id<MTLBuffer> buffer;
} FinchMetalBuffer;

typedef struct {
    CFRuntimeBase base;
    __strong id<MTLDevice> device;
    CFDictionaryRef attributes;
} FinchMetalBufferCache;

static void
metal_buffer_finalize(CFTypeRef object)
{
    FinchMetalBuffer *buffer = (FinchMetalBuffer *)object;
    buffer->buffer = nil;
}

static void
metal_cache_finalize(CFTypeRef object)
{
    FinchMetalBufferCache *cache = (FinchMetalBufferCache *)object;
    cache->device = nil;
    if (cache->attributes) CFRelease(cache->attributes);
}

CV_DEFINE_TYPE(CVMetalBufferGetTypeID, "CVMetalBuffer", metal_buffer_finalize, NULL)
CV_DEFINE_TYPE(CVMetalBufferCacheGetTypeID, "CVMetalBufferCache", metal_cache_finalize, NULL)

CVReturn
CVMetalBufferCacheCreate(CFAllocatorRef allocator, CFDictionaryRef attributes, id<MTLDevice> device,
                         CVMetalBufferCacheRef *cacheOut)
{
    if (cacheOut) *cacheOut = NULL;
    if (!cacheOut || !device || ![device respondsToSelector:@selector(newBufferWithBytes:length:options:)])
        return kCVReturnInvalidArgument;
    FinchMetalBufferCache *cache = (FinchMetalBufferCache *)cv_create(allocator,
        CVMetalBufferCacheGetTypeID(), sizeof(*cache));
    if (!cache)
        return kCVReturnAllocationFailed;
    cache->device = device;
    cache->attributes = attributes ? CFDictionaryCreateCopy(allocator, attributes) : NULL;
    *cacheOut = (CVMetalBufferCacheRef)cache;
    return kCVReturnSuccess;
}

CVReturn
CVMetalBufferCacheCreateBufferFromImage(CFAllocatorRef allocator, CVMetalBufferCacheRef object,
                                        CVImageBufferRef image, CVMetalBufferRef *bufferOut)
{
    if (bufferOut) *bufferOut = NULL;
    if (!object || CFGetTypeID(object) != CVMetalBufferCacheGetTypeID() || !image || !bufferOut)
        return kCVReturnInvalidArgument;
    if (CFGetTypeID(image) != CVPixelBufferGetTypeID())
        return kCVReturnUnsupported;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)image;
    CVReturn result = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (result != kCVReturnSuccess)
        return result;
    size_t size = CVPixelBufferGetDataSize(pixelBuffer);
    void *bytes = CVPixelBufferGetBaseAddress(pixelBuffer);
    id<MTLBuffer> metalBuffer = nil;
    if (bytes && size)
        metalBuffer = [((FinchMetalBufferCache *)object)->device newBufferWithBytes:bytes length:size options:MTLResourceStorageModeShared];
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (!metalBuffer)
        return kCVReturnAllocationFailed;
    FinchMetalBuffer *buffer = (FinchMetalBuffer *)cv_create(allocator, CVMetalBufferGetTypeID(), sizeof(*buffer));
    if (!buffer)
        return kCVReturnAllocationFailed;
    buffer->buffer = metalBuffer;
    *bufferOut = (CVMetalBufferRef)buffer;
    return kCVReturnSuccess;
}

void
CVMetalBufferCacheFlush(CVMetalBufferCacheRef object, CVOptionFlags options)
{
    (void)options;
    if (!object || CFGetTypeID(object) != CVMetalBufferCacheGetTypeID())
        return;
}

id<MTLBuffer>
CVMetalBufferGetBuffer(CVMetalBufferRef object)
{
    return object && CFGetTypeID(object) == CVMetalBufferGetTypeID() ? ((FinchMetalBuffer *)object)->buffer : nil;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreVideo's pixel buffer pools, Finch's: buffers of one size and format whose
 * memory (or IOSurface) goes back to the pool when they're released, to be handed
 * out again; memory left unused longer than the maximum age (a second unless asked)
 * is freed when the pool is next used or flushed.
 */
#include "CVInternal.h"
#include <IOSurface/IOSurface.h>
#include <stdlib.h>
#include <time.h>

typedef struct {
    void *memory;
    size_t size;
    CFTypeRef surface;
    double freed;
} Free;

struct __CVPixelBufferPool {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    CFDictionaryRef poolAttributes, bufferAttributes;
    size_t width, height;
    OSType format;
    double maxAge;
    Free *free;
    size_t freeCount, freeCapacity;
    size_t inUse;
};

static double
now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void
drop(Free *f)
{
    if (f->surface)
        CFRelease(f->surface);
    else
        free(f->memory);
}

static void
finalize(CFTypeRef cf)
{
    CVPixelBufferPoolRef p = (CVPixelBufferPoolRef)cf;
    for (size_t i = 0; i < p->freeCount; i++)
        drop(&p->free[i]);
    free(p->free);
    if (p->poolAttributes)
        CFRelease(p->poolAttributes);
    if (p->bufferAttributes)
        CFRelease(p->bufferAttributes);
    pthread_mutex_destroy(&p->lock);
}

static CFStringRef
copy_description(CFTypeRef cf)
{
    CVPixelBufferPoolRef p = (CVPixelBufferPoolRef)cf;
    pthread_mutex_lock(&p->lock);
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL, CFSTR("< CVPixelBufferPoolRef %p poolAttributes=%@ pixelBufferAttributes=%@ inUse=%zu free=%zu>"),
                                             cf, p->poolAttributes, p->bufferAttributes, p->inUse, p->freeCount);
    pthread_mutex_unlock(&p->lock);
    return s;
}

CV_DEFINE_TYPE(CVPixelBufferPoolGetTypeID, "CVPixelBufferPool", finalize, copy_description)

static bool
get_size(CFDictionaryRef d, CFStringRef key, size_t *out)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    long long n;
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID() || !CFNumberGetValue(v, kCFNumberLongLongType, &n) || n <= 0)
        return false;
    *out = (size_t)n;
    return true;
}

static CFDictionaryRef
copy_pixel_buffer_attributes(CFAllocatorRef allocator, CFDictionaryRef attributes)
{
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(allocator, 0, attributes);
    if (!copy)
        return NULL;
    CFTypeRef surface = CFDictionaryGetValue(copy, kCVPixelBufferIOSurfacePropertiesKey);
    if (surface && CFGetTypeID(surface) == CFDictionaryGetTypeID()) {
        CFMutableDictionaryRef properties = CFDictionaryCreateMutableCopy(allocator, 0, surface);
        if (properties && !CFDictionaryContainsKey(properties, CFSTR("IOSurfacePurgeWhenNotInUse"))) {
            CFDictionarySetValue(properties, CFSTR("IOSurfacePurgeWhenNotInUse"), kCFBooleanTrue);
            CFDictionarySetValue(copy, kCVPixelBufferIOSurfacePropertiesKey, properties);
        }
        if (properties)
            CFRelease(properties);
    }
    CFDictionaryRef result = CFDictionaryCreateCopy(allocator, copy);
    CFRelease(copy);
    return result;
}

CVReturn
CVPixelBufferPoolCreate(CFAllocatorRef allocator, CFDictionaryRef poolAttributes, CFDictionaryRef pixelBufferAttributes,
                        CVPixelBufferPoolRef *poolOut)
{
    if (!poolOut)
        return kCVReturnInvalidArgument;
    *poolOut = NULL;
    size_t w, h, f;
    CFTypeRef format = pixelBufferAttributes ? CFDictionaryGetValue(pixelBufferAttributes, kCVPixelBufferPixelFormatTypeKey) : NULL;
    if (format && CFGetTypeID(format) == CFArrayGetTypeID() && CFArrayGetCount(format))
        format = CFArrayGetValueAtIndex(format, 0);
    if (!get_size(pixelBufferAttributes, kCVPixelBufferWidthKey, &w) || !get_size(pixelBufferAttributes, kCVPixelBufferHeightKey, &h) || !format ||
        CFGetTypeID(format) != CFNumberGetTypeID())
        return kCVReturnInvalidPixelBufferAttributes;
    CFNumberGetValue(format, kCFNumberLongLongType, &f);
    CVPixelBufferPoolRef p = (CVPixelBufferPoolRef)cv_create(allocator, CVPixelBufferPoolGetTypeID(), sizeof(struct __CVPixelBufferPool));
    if (!p)
        return kCVReturnAllocationFailed;
    pthread_mutex_init(&p->lock, NULL);
    p->width = w, p->height = h, p->format = (OSType)f;
    p->bufferAttributes = copy_pixel_buffer_attributes(allocator, pixelBufferAttributes);
    p->poolAttributes = poolAttributes ? CFDictionaryCreateCopy(allocator, poolAttributes)
                                       : CFDictionaryCreate(allocator, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef age = CFDictionaryGetValue(p->poolAttributes, kCVPixelBufferPoolMaximumBufferAgeKey);
    p->maxAge = 1;
    if (age && CFGetTypeID(age) == CFNumberGetTypeID())
        CFNumberGetValue(age, kCFNumberDoubleType, &p->maxAge);
    *poolOut = p;
    return kCVReturnSuccess;
}

CVPixelBufferPoolRef
CVPixelBufferPoolRetain(CVPixelBufferPoolRef pixelBufferPool)
{
    return pixelBufferPool ? (CVPixelBufferPoolRef)CFRetain(pixelBufferPool) : NULL;
}

void
CVPixelBufferPoolRelease(CVPixelBufferPoolRef pixelBufferPool)
{
    if (pixelBufferPool)
        CFRelease(pixelBufferPool);
}

CFDictionaryRef
CVPixelBufferPoolGetAttributes(CVPixelBufferPoolRef pool)
{
    return pool ? pool->poolAttributes : NULL;
}

CFDictionaryRef
CVPixelBufferPoolGetPixelBufferAttributes(CVPixelBufferPoolRef pool)
{
    return pool ? pool->bufferAttributes : NULL;
}

/* Frees what's been unused longer than the maximum age (or everything, when asked). */
static void
age_out(CVPixelBufferPoolRef p, bool all)
{
    double t = now();
    size_t kept = 0;
    for (size_t i = 0; i < p->freeCount; i++) {
        if (all || (p->maxAge > 0 && t - p->free[i].freed > p->maxAge))
            drop(&p->free[i]);
        else
            p->free[kept++] = p->free[i];
    }
    p->freeCount = kept;
}

void
CVPixelBufferPoolFlush(CVPixelBufferPoolRef pool, CVPixelBufferPoolFlushFlags options)
{
    if (!pool)
        return;
    pthread_mutex_lock(&pool->lock);
    age_out(pool, (options & kCVPixelBufferPoolFlushExcessBuffers) != 0);
    pthread_mutex_unlock(&pool->lock);
}

bool
_FinchCVPoolTake(CVPixelBufferPoolRef pool, size_t size, bool surface, void **memory, CFTypeRef *surfaceOut)
{
    bool found = false;
    pthread_mutex_lock(&pool->lock);
    age_out(pool, false);
    for (size_t i = pool->freeCount; i-- > 0;)
        if (pool->free[i].size == size && (pool->free[i].surface != NULL) == surface) {
            *memory = pool->free[i].memory;
            *surfaceOut = pool->free[i].surface;
            pool->free[i] = pool->free[--pool->freeCount];
            found = true;
            break;
        }
    pthread_mutex_unlock(&pool->lock);
    return found;
}

void
_FinchCVPoolReturn(CVPixelBufferPoolRef pool, void *memory, size_t size, CFTypeRef surface)
{
    pthread_mutex_lock(&pool->lock);
    if (pool->inUse)
        pool->inUse--;
    if (memory || surface) {
        if (pool->freeCount == pool->freeCapacity) {
            size_t c = pool->freeCapacity ? pool->freeCapacity * 2 : 4;
            Free *f = realloc(pool->free, c * sizeof *f);
            if (f)
                pool->free = f, pool->freeCapacity = c;
        }
        if (pool->freeCount < pool->freeCapacity)
            pool->free[pool->freeCount++] = (Free){memory, size, surface ? CFRetain(surface) : NULL, now()};
        else if (!surface)
            free(memory);
    }
    pthread_mutex_unlock(&pool->lock);
}

extern CVReturn _FinchCVPixelBufferCreate(CFAllocatorRef allocator, size_t width, size_t height, OSType pixelFormatType,
                                          CFDictionaryRef pixelBufferAttributes, CVPixelBufferPoolRef pool, CVPixelBufferRef *pixelBufferOut);

CVReturn
CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(CFAllocatorRef allocator, CVPixelBufferPoolRef pixelBufferPool, CFDictionaryRef auxAttributes,
                                                    CVPixelBufferRef *pixelBufferOut)
{
    if (!pixelBufferOut)
        return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if (!pixelBufferPool)
        return kCVReturnInvalidArgument;
    CFTypeRef threshold = auxAttributes ? CFDictionaryGetValue(auxAttributes, kCVPixelBufferPoolAllocationThresholdKey) : NULL;
    long long limit = 0;
    if (threshold && CFGetTypeID(threshold) == CFNumberGetTypeID())
        CFNumberGetValue(threshold, kCFNumberLongLongType, &limit);
    pthread_mutex_lock(&pixelBufferPool->lock);
    if (limit > 0 && (long long)pixelBufferPool->inUse >= limit) {
        pthread_mutex_unlock(&pixelBufferPool->lock);
        return kCVReturnWouldExceedAllocationThreshold;
    }
    pixelBufferPool->inUse++;
    pthread_mutex_unlock(&pixelBufferPool->lock);
    CVReturn e = _FinchCVPixelBufferCreate(allocator, pixelBufferPool->width, pixelBufferPool->height, pixelBufferPool->format,
                                           pixelBufferPool->bufferAttributes, pixelBufferPool, pixelBufferOut);
    if (e) {
        pthread_mutex_lock(&pixelBufferPool->lock);
        pixelBufferPool->inUse--;
        pthread_mutex_unlock(&pixelBufferPool->lock);
    }
    return e;
}

CVReturn
CVPixelBufferPoolCreatePixelBuffer(CFAllocatorRef allocator, CVPixelBufferPoolRef pixelBufferPool, CVPixelBufferRef *pixelBufferOut)
{
    return CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(allocator, pixelBufferPool, NULL, pixelBufferOut);
}

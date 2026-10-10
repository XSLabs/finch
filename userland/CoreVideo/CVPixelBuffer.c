/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreVideo's pixel buffers, Finch's: memory of their own (or an IOSurface's, or the
 * caller's) laid out as Apple's are, so row bytes and plane offsets come out the same:
 *
 *  - a row is the width (with any extended pixels) rounded up to 16 pixels, in blocks,
 *    then to a multiple of the least common multiple of 64, the block's bytes and any
 *    alignment asked for;
 *  - a planar buffer starts with a 512-byte header (Apple's CVPlanarPixelBufferInfo:
 *    each plane's offset and row bytes, big-endian), its planes 512-byte aligned, the
 *    luma height rounded up to 8 and the others' heights that divided by their
 *    subsampling; its "bytes per row" is the whole size over the height, rounded up to
 *    4, and its data size that times the height.
 */
#include "CVInternal.h"
#include <IOSurface/IOSurface.h>
#include <libkern/OSByteOrder.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PLANES 4

typedef struct {
    size_t width, height; /* (as reported) */
    size_t rows;          /* (allocated) */
    size_t bytesPerRow, offset;
    size_t bitsPerBlock, blockWidth, blockHeight;
} Plane;

struct __CVBuffer {
    FinchCVBuffer cv;
    size_t width, height;
    OSType format;
    size_t bytesPerRow, dataSize;
    size_t extended[4]; /* left, right, top, bottom */
    char *memory;       /* (where the layout starts: base address less any extended pixels) */
    void *block;        /* (the allocation, when the buffer's own) */
    size_t allocSize;
    char *base;
    Plane planes[MAX_PLANES];
    size_t planeCount; /* (0: not planar) */
    IOSurfaceRef surface;
    CVPixelBufferReleaseBytesCallback releaseBytes;
    CVPixelBufferReleasePlanarBytesCallback releasePlanar;
    void *releaseRefCon;
    const void *planarData;
    size_t planarDataSize;
    const void *planeBases[MAX_PLANES];
    bool ownsMemory;
    CFDictionaryRef attributes;
    _Atomic int locks;
    CVPixelBufferPoolRef pool;
};

static void
finalize(CFTypeRef cf)
{
    CVPixelBufferRef b = (CVPixelBufferRef)cf;
    if (b->pool) {
        _FinchCVPoolReturn(b->pool, b->ownsMemory ? b->block : NULL, b->allocSize, b->surface);
        CFRelease(b->pool);
    } else if (b->ownsMemory)
        free(b->block);
    if (b->surface)
        CFRelease(b->surface);
    if (b->releaseBytes)
        b->releaseBytes(b->releaseRefCon, b->base);
    if (b->releasePlanar)
        b->releasePlanar(b->releaseRefCon, b->planarData, b->planarDataSize, b->planeCount, b->planeBases);
    if (b->attributes)
        CFRelease(b->attributes);
    _FinchCVBufferFinalize(&b->cv);
}

static void
append_dictionary(CFMutableStringRef s, CFDictionaryRef d)
{
    CFStringRef x = CFCopyDescription(d);
    CFStringAppend(s, x);
    CFRelease(x);
}

static CFStringRef
copy_description(CFTypeRef cf)
{
    CVPixelBufferRef b = (CVPixelBufferRef)cf;
    char f[5] = {(char)(b->format >> 24), (char)(b->format >> 16), (char)(b->format >> 8), (char)b->format, 0};
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("<CVPixelBuffer %p width=%zu height=%zu bytesPerRow=%zu pixelFormat=%s iosurface=%p surfaceid=%u "), cf,
                         b->width, b->height, b->bytesPerRow, f, b->surface, b->surface ? IOSurfaceGetID(b->surface) : 0);
    if (b->planeCount) {
        CFStringAppendFormat(s, NULL, CFSTR("planes=%zu "), b->planeCount);
        for (size_t i = 0; i < b->planeCount; i++)
            CFStringAppendFormat(s, NULL, CFSTR("plane %zu width=%zu height=%zu bytesPerRow=%zu "), i, b->planes[i].width, b->planes[i].height,
                                 b->planes[i].bytesPerRow);
    }
    CFStringAppend(s, CFSTR("attributes="));
    append_dictionary(s, b->attributes);
    CFStringAppend(s, CFSTR(" propagatedAttachments="));
    append_dictionary(s, b->cv.attachments[1]);
    CFStringAppend(s, CFSTR(" nonPropagatedAttachments="));
    append_dictionary(s, b->cv.attachments[0]);
    CFStringAppend(s, CFSTR(">"));
    return s;
}

CV_DEFINE_TYPE(CVPixelBufferGetTypeID, "CVPixelBuffer", finalize, copy_description)

bool
_FinchCVIsBuffer(CFTypeRef cf)
{
    return cf && CFGetTypeID(cf) == CVPixelBufferGetTypeID();
}

bool
_FinchCVPixelBufferGetSize(CFTypeRef cf, size_t *width, size_t *height)
{
    if (!_FinchCVIsBuffer(cf))
        return false;
    *width = ((CVPixelBufferRef)cf)->width;
    *height = ((CVPixelBufferRef)cf)->height;
    return true;
}

/* --- layout --- */

static size_t
dict_size(CFDictionaryRef d, CFStringRef key, size_t otherwise)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    long long n;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberLongLongType, &n) && n >= 0)
        return (size_t)n;
    return otherwise;
}

static size_t
gcd(size_t a, size_t b)
{
    while (b) {
        size_t t = a % b;
        a = b, b = t;
    }
    return a;
}

static size_t
lcm(size_t a, size_t b)
{
    return a && b ? a / gcd(a, b) * b : (a ? a : b);
}

static size_t
round_up(size_t n, size_t to)
{
    return to ? (n + to - 1) / to * to : n;
}

static size_t
row_bytes(size_t width, size_t bitsPerBlock, size_t blockWidth, size_t alignment)
{
    size_t blockBytes = (bitsPerBlock + 7) / 8;
    size_t blocks = (round_up(width, 16) + blockWidth - 1) / blockWidth;
    return round_up(blocks * blockBytes, lcm(lcm(64, alignment), blockBytes));
}

/* The planes of a format at a size (none for a chunky one); false if it has no description. */
static bool
describe(OSType format, CFDictionaryRef *descOut)
{
    *descOut = _FinchCVCopyPixelFormatDescription(format);
    return *descOut != NULL;
}

static void
plane_from(CFDictionaryRef d, Plane *p, size_t width, size_t height, size_t *hsub, size_t *vsub)
{
    p->bitsPerBlock = dict_size(d, kCVPixelFormatBitsPerBlock, 8);
    p->blockWidth = dict_size(d, kCVPixelFormatBlockWidth, 1) ?: 1;
    p->blockHeight = dict_size(d, kCVPixelFormatBlockHeight, 1) ?: 1;
    *hsub = dict_size(d, kCVPixelFormatHorizontalSubsampling, 1) ?: 1;
    *vsub = dict_size(d, kCVPixelFormatVerticalSubsampling, 1) ?: 1;
    p->width = (width + *hsub - 1) / *hsub;
    p->height = (height + *vsub - 1) / *vsub;
}

#define PLANAR_HEADER 512

/* Lays b out for its format, size and attributes: planes, row bytes, sizes. */
static CVReturn
lay_out(CVPixelBufferRef b, CFDictionaryRef desc, CFDictionaryRef attributes)
{
    size_t alignment = dict_size(attributes, kCVPixelBufferBytesPerRowAlignmentKey, 0);
    CFArrayRef planes = CFDictionaryGetValue(desc, kCVPixelFormatPlanes);
    if (planes && CFGetTypeID(planes) == CFArrayGetTypeID() && CFArrayGetCount(planes) > 0) {
        size_t n = (size_t)CFArrayGetCount(planes);
        if (n > MAX_PLANES)
            return kCVReturnInvalidPixelFormat;
        /* (planes, and so the header, aligned to 512 and any row alignment asked for) */
        size_t planeAlign = lcm(PLANAR_HEADER, alignment), paddedHeight = round_up(b->height, 8), at = planeAlign;
        for (size_t i = 0; i < n; i++) {
            Plane *p = &b->planes[i];
            size_t hsub, vsub;
            plane_from(CFArrayGetValueAtIndex(planes, (CFIndex)i), p, b->width, b->height, &hsub, &vsub);
            p->bytesPerRow = row_bytes(p->width, p->bitsPerBlock, p->blockWidth, alignment);
            p->rows = paddedHeight / vsub;
            at = round_up(at, planeAlign);
            p->offset = at;
            at += p->rows * p->bytesPerRow;
        }
        b->planeCount = n;
        b->allocSize = at;
        b->bytesPerRow = round_up((at + b->height - 1) / b->height, 4);
        b->dataSize = b->bytesPerRow * b->height;
        return kCVReturnSuccess;
    }
    for (int i = 0; i < 4; i++)
        b->extended[i] = dict_size(attributes, (CFStringRef[]){kCVPixelBufferExtendedPixelsLeftKey, kCVPixelBufferExtendedPixelsRightKey,
                                                                kCVPixelBufferExtendedPixelsTopKey, kCVPixelBufferExtendedPixelsBottomKey}[i],
                                   0);
    Plane p;
    size_t hsub, vsub;
    plane_from(desc, &p, b->width, b->height, &hsub, &vsub);
    size_t width = b->width + b->extended[0] + b->extended[1], height = b->height + b->extended[2] + b->extended[3];
    b->bytesPerRow = row_bytes(width, p.bitsPerBlock, p.blockWidth, alignment);
    b->allocSize = b->bytesPerRow * ((height + p.blockHeight - 1) / p.blockHeight);
    size_t leftBytes = b->extended[0] / p.blockWidth * ((p.bitsPerBlock + 7) / 8);
    b->dataSize = b->bytesPerRow * b->height - leftBytes;
    return kCVReturnSuccess;
}

/* The bytes of extended pixels on the left of a chunky buffer. */
static size_t
lead_bytes(CVPixelBufferRef b)
{
    if (b->planeCount || !b->extended[0])
        return 0;
    CFDictionaryRef desc = _FinchCVCopyPixelFormatDescription(b->format);
    size_t bits = desc ? dict_size(desc, kCVPixelFormatBitsPerBlock, 8) : 8, bw = desc ? (dict_size(desc, kCVPixelFormatBlockWidth, 1) ?: 1) : 1;
    if (desc)
        CFRelease(desc);
    return b->extended[0] / bw * ((bits + 7) / 8);
}

/* Points base and the planes into memory, and writes a planar buffer's header. */
static void
place(CVPixelBufferRef b, char *memory)
{
    b->memory = memory;
    if (b->planeCount) {
        b->base = memory;
        for (size_t i = 0; i < b->planeCount; i++) {
            uint32_t *info = (uint32_t *)(memory + 8 * i);
            info[0] = OSSwapHostToBigInt32((uint32_t)b->planes[i].offset);
            info[1] = OSSwapHostToBigInt32((uint32_t)b->planes[i].bytesPerRow);
        }
        return;
    }
    b->base = memory + b->extended[2] * b->bytesPerRow + lead_bytes(b);
}

static CFDictionaryRef
creation_attributes(CFDictionaryRef attributes, CFDictionaryRef desc)
{
    CFMutableDictionaryRef a = attributes ? CFDictionaryCreateMutableCopy(NULL, 0, attributes)
                                          : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (desc)
        CFDictionarySetValue(a, CFSTR("PixelFormatDescription"), desc);
    return a;
}

static CVPixelBufferRef
new_buffer(CFAllocatorRef allocator, size_t width, size_t height, OSType format)
{
    CVPixelBufferRef b = (CVPixelBufferRef)cv_create(allocator, CVPixelBufferGetTypeID(), sizeof(struct __CVBuffer));
    if (!b)
        return NULL;
    _FinchCVBufferInit(&b->cv);
    b->width = width;
    b->height = height;
    b->format = format;
    return b;
}

/* Attachments the attributes carry (kCVBufferPropagatedAttachmentsKey and the other). */
static void
attach_from(CVPixelBufferRef b, CFDictionaryRef attributes)
{
    if (!attributes)
        return;
    CFDictionaryRef p = CFDictionaryGetValue(attributes, kCVBufferPropagatedAttachmentsKey);
    CFDictionaryRef n = CFDictionaryGetValue(attributes, kCVBufferNonPropagatedAttachmentsKey);
    if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
        CVBufferSetAttachments(b, p, kCVAttachmentMode_ShouldPropagate);
    if (n && CFGetTypeID(n) == CFDictionaryGetTypeID())
        CVBufferSetAttachments(b, n, kCVAttachmentMode_ShouldNotPropagate);
}

static IOSurfaceRef
make_surface(CVPixelBufferRef b, CFDictionaryRef surfaceProperties)
{
    CFMutableDictionaryRef p = surfaceProperties && CFGetTypeID(surfaceProperties) == CFDictionaryGetTypeID()
                                   ? CFDictionaryCreateMutableCopy(NULL, 0, surfaceProperties)
                                   : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
#define SET(key, value)                                                       \
    do {                                                                      \
        long long v_ = (long long)(value);                                    \
        CFNumberRef n_ = CFNumberCreate(NULL, kCFNumberLongLongType, &v_);    \
        CFDictionarySetValue(p, key, n_);                                     \
        CFRelease(n_);                                                        \
    } while (0)
    SET(kIOSurfaceWidth, b->width);
    SET(kIOSurfaceHeight, b->height);
    SET(kIOSurfacePixelFormat, b->format);
    if (b->planeCount) {
        CFMutableArrayRef planes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (size_t i = 0; i < b->planeCount; i++) {
            CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFMutableDictionaryRef saved = p;
            p = q;
            SET(kIOSurfacePlaneWidth, b->planes[i].width);
            SET(kIOSurfacePlaneHeight, b->planes[i].height);
            SET(kIOSurfacePlaneBytesPerRow, b->planes[i].bytesPerRow);
            SET(kIOSurfacePlaneOffset, b->planes[i].offset);
            SET(kIOSurfacePlaneSize, b->planes[i].rows * b->planes[i].bytesPerRow);
            SET(kIOSurfacePlaneBytesPerElement, (b->planes[i].bitsPerBlock + 7) / 8);
            SET(kIOSurfacePlaneElementWidth, b->planes[i].blockWidth);
            p = saved;
            CFArrayAppendValue(planes, q);
            CFRelease(q);
        }
        CFDictionarySetValue(p, kIOSurfacePlaneInfo, planes);
        CFRelease(planes);
        SET(kIOSurfaceBytesPerRow, b->planes[0].bytesPerRow);
    } else {
        CFDictionaryRef desc = _FinchCVCopyPixelFormatDescription(b->format);
        size_t bits = dict_size(desc, kCVPixelFormatBitsPerBlock, 8), bw = dict_size(desc, kCVPixelFormatBlockWidth, 1) ?: 1;
        if (desc)
            CFRelease(desc);
        SET(kIOSurfaceBytesPerRow, b->bytesPerRow);
        SET(kIOSurfaceBytesPerElement, (bits + 7) / 8);
        SET(kIOSurfaceElementWidth, bw);
    }
#undef SET
    IOSurfaceRef s = IOSurfaceCreate(p);
    CFRelease(p);
    return s;
}

/* Memory for a buffer laid out: a pool's, or the heap's, or an IOSurface's. */
extern bool _FinchCVPoolTake(CVPixelBufferPoolRef pool, size_t size, bool surface, void **memory, CFTypeRef *surfaceOut);

static CVReturn
allocate(CVPixelBufferRef b, CFDictionaryRef attributes, CVPixelBufferPoolRef pool)
{
    CFDictionaryRef surfaceProperties = attributes ? CFDictionaryGetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey) : NULL;
    void *memory = NULL;
    CFTypeRef surface = NULL;
    if (pool && _FinchCVPoolTake(pool, b->allocSize, surfaceProperties != NULL, &memory, &surface)) {
        b->surface = (IOSurfaceRef)surface;
        b->ownsMemory = !surface;
    } else if (surfaceProperties) {
        b->surface = make_surface(b, surfaceProperties);
        if (!b->surface)
            return kCVReturnAllocationFailed;
    } else {
        if (posix_memalign(&memory, 64, b->allocSize + 64))
            return kCVReturnAllocationFailed;
        memset(memory, 0, b->allocSize + 64);
        b->ownsMemory = true;
    }
    b->block = memory;
    if (b->surface)
        memory = IOSurfaceGetBaseAddress(b->surface);
    else {
        /* (the allocation moved on so the first visible pixel is 64-byte aligned, as Apple's is) */
        size_t lead = b->extended[2] * b->bytesPerRow + lead_bytes(b);
        memory = (char *)memory + (64 - lead % 64) % 64;
    }
    place(b, memory);
    return kCVReturnSuccess;
}

CVReturn
_FinchCVPixelBufferCreate(CFAllocatorRef allocator, size_t width, size_t height, OSType pixelFormatType, CFDictionaryRef pixelBufferAttributes,
                          CVPixelBufferPoolRef pool, CVPixelBufferRef *pixelBufferOut)
{
    if (!pixelBufferOut)
        return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if (!width || !height)
        return kCVReturnInvalidArgument;
    CFDictionaryRef desc;
    if (!describe(pixelFormatType, &desc))
        return kCVReturnInvalidPixelFormat;
    CVPixelBufferRef b = new_buffer(allocator, width, height, pixelFormatType);
    CVReturn e = b ? lay_out(b, desc, pixelBufferAttributes) : kCVReturnAllocationFailed;
    if (!e)
        e = allocate(b, pixelBufferAttributes, pool);
    if (e) {
        CFRelease(desc);
        if (b)
            CFRelease(b);
        return e;
    }
    /* (a pool's buffers carry the pool's attributes as they are) */
    b->attributes = pool ? CFDictionaryCreateCopy(NULL, pixelBufferAttributes) : creation_attributes(pixelBufferAttributes, desc);
    CFRelease(desc);
    if (pool) {
        b->pool = (CVPixelBufferPoolRef)CFRetain(pool);
        attach_from(b, pixelBufferAttributes);
    }
    *pixelBufferOut = b;
    return kCVReturnSuccess;
}

CVReturn
CVPixelBufferCreate(CFAllocatorRef allocator, size_t width, size_t height, OSType pixelFormatType, CFDictionaryRef pixelBufferAttributes,
                    CVPixelBufferRef *pixelBufferOut)
{
    return _FinchCVPixelBufferCreate(allocator, width, height, pixelFormatType, pixelBufferAttributes, NULL, pixelBufferOut);
}

CVReturn
CVPixelBufferCreateWithBytes(CFAllocatorRef allocator, size_t width, size_t height, OSType pixelFormatType, void *baseAddress, size_t bytesPerRow,
                             CVPixelBufferReleaseBytesCallback releaseCallback, void *releaseRefCon, CFDictionaryRef pixelBufferAttributes,
                             CVPixelBufferRef *pixelBufferOut)
{
    if (!pixelBufferOut)
        return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if (!width || !height || !baseAddress)
        return kCVReturnInvalidArgument;
    CFDictionaryRef desc;
    if (!describe(pixelFormatType, &desc))
        return kCVReturnInvalidPixelFormat;
    CVPixelBufferRef b = new_buffer(allocator, width, height, pixelFormatType);
    if (!b) {
        CFRelease(desc);
        return kCVReturnAllocationFailed;
    }
    b->bytesPerRow = bytesPerRow;
    b->dataSize = bytesPerRow * height;
    b->allocSize = b->dataSize;
    b->memory = b->base = baseAddress;
    b->releaseBytes = releaseCallback;
    b->releaseRefCon = releaseRefCon;
    b->attributes = creation_attributes(pixelBufferAttributes, desc);
    CFRelease(desc);
    *pixelBufferOut = b;
    return kCVReturnSuccess;
}

CVReturn
CVPixelBufferCreateWithPlanarBytes(CFAllocatorRef allocator, size_t width, size_t height, OSType pixelFormatType, void *dataPtr, size_t dataSize,
                                   size_t numberOfPlanes, void *planeBaseAddress[], size_t planeWidth[], size_t planeHeight[],
                                   size_t planeBytesPerRow[], CVPixelBufferReleasePlanarBytesCallback releaseCallback, void *releaseRefCon,
                                   CFDictionaryRef pixelBufferAttributes, CVPixelBufferRef *pixelBufferOut)
{
    if (!pixelBufferOut)
        return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if (!width || !height || !numberOfPlanes || numberOfPlanes > MAX_PLANES || !planeBaseAddress)
        return kCVReturnInvalidArgument;
    CFDictionaryRef desc;
    if (!describe(pixelFormatType, &desc))
        return kCVReturnInvalidPixelFormat;
    CVPixelBufferRef b = new_buffer(allocator, width, height, pixelFormatType);
    if (!b) {
        CFRelease(desc);
        return kCVReturnAllocationFailed;
    }
    b->planeCount = numberOfPlanes;
    for (size_t i = 0; i < numberOfPlanes; i++) {
        b->planes[i].width = planeWidth[i];
        b->planes[i].height = planeHeight[i];
        b->planes[i].bytesPerRow = planeBytesPerRow[i];
        b->planes[i].offset = (size_t)((char *)planeBaseAddress[i] - (char *)planeBaseAddress[0]);
        b->planeBases[i] = planeBaseAddress[i];
    }
    b->memory = dataPtr ? dataPtr : planeBaseAddress[0];
    b->base = dataPtr;
    b->dataSize = dataSize;
    b->bytesPerRow = dataSize / height;
    b->releasePlanar = releaseCallback;
    b->releaseRefCon = releaseRefCon;
    b->planarData = dataPtr;
    b->planarDataSize = dataSize;
    b->attributes = creation_attributes(pixelBufferAttributes, desc);
    CFRelease(desc);
    *pixelBufferOut = b;
    return kCVReturnSuccess;
}

CVReturn
CVPixelBufferCreateWithIOSurface(CFAllocatorRef allocator, IOSurfaceRef surface, CFDictionaryRef pixelBufferAttributes,
                                 CVPixelBufferRef *pixelBufferOut)
{
    if (!pixelBufferOut)
        return kCVReturnInvalidArgument;
    *pixelBufferOut = NULL;
    if (!surface)
        return kCVReturnInvalidArgument;
    OSType format = IOSurfaceGetPixelFormat(surface);
    CFDictionaryRef desc;
    if (!describe(format, &desc))
        return kCVReturnInvalidPixelFormat;
    CVPixelBufferRef b = new_buffer(allocator, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), format);
    if (!b) {
        CFRelease(desc);
        return kCVReturnAllocationFailed;
    }
    b->surface = (IOSurfaceRef)CFRetain(surface);
    b->allocSize = IOSurfaceGetAllocSize(surface);
    char *memory = IOSurfaceGetBaseAddress(surface);
    size_t planes = IOSurfaceGetPlaneCount(surface);
    if (planes) {
        b->planeCount = planes > MAX_PLANES ? MAX_PLANES : planes;
        for (size_t i = 0; i < b->planeCount; i++) {
            b->planes[i].width = IOSurfaceGetWidthOfPlane(surface, i);
            b->planes[i].height = IOSurfaceGetHeightOfPlane(surface, i);
            b->planes[i].bytesPerRow = IOSurfaceGetBytesPerRowOfPlane(surface, i);
            b->planes[i].offset = (size_t)((char *)IOSurfaceGetBaseAddressOfPlane(surface, i) - memory);
        }
        b->bytesPerRow = round_up((b->allocSize + b->height - 1) / b->height, 4);
        b->dataSize = b->bytesPerRow * b->height;
        b->memory = b->base = memory;
    } else {
        b->bytesPerRow = IOSurfaceGetBytesPerRow(surface);
        b->dataSize = b->allocSize;
        b->memory = b->base = memory;
    }
    b->attributes = creation_attributes(pixelBufferAttributes, desc);
    CFRelease(desc);
    *pixelBufferOut = b;
    return kCVReturnSuccess;
}

/* --- reading them --- */

static CVPixelBufferRef
as_pixel(CVPixelBufferRef b)
{
    return _FinchCVIsBuffer(b) ? b : NULL;
}

CVPixelBufferRef
CVPixelBufferRetain(CVPixelBufferRef texture)
{
    return texture ? (CVPixelBufferRef)CFRetain(texture) : NULL;
}

void
CVPixelBufferRelease(CVPixelBufferRef texture)
{
    if (texture)
        CFRelease(texture);
}

size_t
CVPixelBufferGetWidth(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->width : 0;
}

size_t
CVPixelBufferGetHeight(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->height : 0;
}

OSType
CVPixelBufferGetPixelFormatType(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->format : 0;
}

/* (addresses are only given while the buffer is locked, as Apple's are) */
void *
CVPixelBufferGetBaseAddress(CVPixelBufferRef b)
{
    return as_pixel(b) && b->locks > 0 ? b->base : NULL;
}

size_t
CVPixelBufferGetBytesPerRow(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->bytesPerRow : 0;
}

size_t
CVPixelBufferGetDataSize(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->dataSize : 0;
}

Boolean
CVPixelBufferIsPlanar(CVPixelBufferRef b)
{
    return as_pixel(b) && b->planeCount > 0;
}

size_t
CVPixelBufferGetPlaneCount(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->planeCount : 0;
}

size_t
CVPixelBufferGetWidthOfPlane(CVPixelBufferRef b, size_t planeIndex)
{
    return as_pixel(b) && planeIndex < b->planeCount ? b->planes[planeIndex].width : 0;
}

size_t
CVPixelBufferGetHeightOfPlane(CVPixelBufferRef b, size_t planeIndex)
{
    return as_pixel(b) && planeIndex < b->planeCount ? b->planes[planeIndex].height : 0;
}

void *
CVPixelBufferGetBaseAddressOfPlane(CVPixelBufferRef b, size_t planeIndex)
{
    if (!as_pixel(b) || planeIndex >= b->planeCount || b->locks <= 0)
        return NULL;
    if (b->planeBases[0])
        return (void *)b->planeBases[planeIndex];
    return b->memory + b->planes[planeIndex].offset;
}

size_t
CVPixelBufferGetBytesPerRowOfPlane(CVPixelBufferRef b, size_t planeIndex)
{
    return as_pixel(b) && planeIndex < b->planeCount ? b->planes[planeIndex].bytesPerRow : 0;
}

void
CVPixelBufferGetExtendedPixels(CVPixelBufferRef b, size_t *extraColumnsOnLeft, size_t *extraColumnsOnRight, size_t *extraRowsOnTop,
                               size_t *extraRowsOnBottom)
{
    size_t *out[] = {extraColumnsOnLeft, extraColumnsOnRight, extraRowsOnTop, extraRowsOnBottom};
    for (int i = 0; i < 4; i++)
        if (out[i])
            *out[i] = as_pixel(b) ? b->extended[i] : 0;
}

IOSurfaceRef
CVPixelBufferGetIOSurface(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->surface : NULL;
}

CFDictionaryRef
CVPixelBufferCopyCreationAttributes(CVPixelBufferRef b)
{
    return as_pixel(b) && b->attributes ? CFRetain(b->attributes) : NULL;
}

CFDictionaryRef
CVPixelBufferGetAttributes(CVPixelBufferRef b)
{
    return as_pixel(b) ? b->attributes : NULL;
}

CVReturn
CVPixelBufferLockBaseAddress(CVPixelBufferRef b, CVPixelBufferLockFlags lockFlags)
{
    if (!as_pixel(b))
        return kCVReturnInvalidArgument;
    if (b->surface)
        IOSurfaceLock(b->surface, (lockFlags & kCVPixelBufferLock_ReadOnly) ? kIOSurfaceLockReadOnly : 0, NULL);
    b->locks++;
    return kCVReturnSuccess;
}

CVReturn
CVPixelBufferUnlockBaseAddress(CVPixelBufferRef b, CVPixelBufferLockFlags unlockFlags)
{
    if (!as_pixel(b))
        return kCVReturnInvalidArgument;
    int n = b->locks;
    while (n > 0 && !atomic_compare_exchange_weak(&b->locks, &n, n - 1))
        ;
    if (n <= 0)
        return kCVReturnError;
    if (b->surface)
        IOSurfaceUnlock(b->surface, (unlockFlags & kCVPixelBufferLock_ReadOnly) ? kIOSurfaceLockReadOnly : 0, NULL);
    return kCVReturnSuccess;
}

CVReturn
CVPixelBufferFillExtendedPixels(CVPixelBufferRef b)
{
    if (!as_pixel(b))
        return kCVReturnInvalidArgument;
    if (b->planeCount || !(b->extended[0] | b->extended[1] | b->extended[2] | b->extended[3]))
        return kCVReturnSuccess;
    CFDictionaryRef desc = _FinchCVCopyPixelFormatDescription(b->format);
    size_t bits = dict_size(desc, kCVPixelFormatBitsPerBlock, 8), bw = dict_size(desc, kCVPixelFormatBlockWidth, 1) ?: 1;
    if (desc)
        CFRelease(desc);
    size_t px = (bits + 7) / 8;
    if (bw != 1 || !px)
        return kCVReturnSuccess;
    size_t left = b->extended[0], right = b->extended[1], top = b->extended[2], bottom = b->extended[3];
    /* (each visible row's ends copied outwards, then the first and last rows up and down) */
    for (size_t y = 0; y < b->height; y++) {
        char *row = b->base + y * b->bytesPerRow;
        for (size_t x = 1; x <= left; x++)
            memcpy(row - x * px, row, px);
        for (size_t x = 0; x < right; x++)
            memcpy(row + (b->width + x) * px, row + (b->width - 1) * px, px);
    }
    size_t span = (left + b->width + right) * px;
    char *first = b->base - left * px, *last = first + (b->height - 1) * b->bytesPerRow;
    for (size_t y = 1; y <= top; y++)
        memcpy(first - y * b->bytesPerRow, first, span);
    for (size_t y = 1; y <= bottom; y++)
        memcpy(last + y * b->bytesPerRow, last, span);
    return kCVReturnSuccess;
}

Boolean
CVPixelBufferIsCompatibleWithAttributes(CVPixelBufferRef b, CFDictionaryRef attributes)
{
    if (!as_pixel(b))
        return false;
    if (!attributes)
        return true;
    size_t w = dict_size(attributes, kCVPixelBufferWidthKey, b->width), h = dict_size(attributes, kCVPixelBufferHeightKey, b->height);
    if (w != b->width || h != b->height)
        return false;
    CFTypeRef f = CFDictionaryGetValue(attributes, kCVPixelBufferPixelFormatTypeKey);
    if (f && CFGetTypeID(f) == CFNumberGetTypeID()) {
        OSType t;
        CFNumberGetValue(f, kCFNumberSInt32Type, &t);
        return t == b->format;
    }
    if (f && CFGetTypeID(f) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(f); i++) {
            OSType t;
            if (CFNumberGetValue(CFArrayGetValueAtIndex(f, i), kCFNumberSInt32Type, &t) && t == b->format)
                return true;
        }
        return false;
    }
    if (CFDictionaryContainsKey(attributes, kCVPixelBufferIOSurfacePropertiesKey) && !b->surface)
        return false;
    return true;
}

Boolean
CVPixelBufferWasAllocatedFromPool(CVPixelBufferRef b)
{
    return as_pixel(b) && b->pool;
}

/* Several attribute dictionaries made one: formats gathered into an array, the rest the later's. */
CVReturn
CVPixelBufferCreateResolvedAttributesDictionary(CFAllocatorRef allocator, CFArrayRef attributes, CFDictionaryRef *resolvedDictionaryOut)
{
    if (!resolvedDictionaryOut)
        return kCVReturnInvalidArgument;
    CFMutableDictionaryRef out = CFDictionaryCreateMutable(allocator, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableArrayRef formats = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; attributes && i < CFArrayGetCount(attributes); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(attributes, i);
        if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID())
            continue;
        CFIndex n = CFDictionaryGetCount(d);
        const void **keys = malloc(sizeof(void *) * (size_t)n * 2), **values = keys + n;
        CFDictionaryGetKeysAndValues(d, keys, values);
        for (CFIndex k = 0; k < n; k++) {
            if (CFEqual(keys[k], kCVPixelBufferPixelFormatTypeKey)) {
                CFTypeRef v = values[k];
                if (CFGetTypeID(v) == CFArrayGetTypeID()) {
                    for (CFIndex j = 0; j < CFArrayGetCount(v); j++)
                        if (!CFArrayContainsValue(formats, CFRangeMake(0, CFArrayGetCount(formats)), CFArrayGetValueAtIndex(v, j)))
                            CFArrayAppendValue(formats, CFArrayGetValueAtIndex(v, j));
                } else if (!CFArrayContainsValue(formats, CFRangeMake(0, CFArrayGetCount(formats)), v))
                    CFArrayAppendValue(formats, v);
            } else
                CFDictionarySetValue(out, keys[k], values[k]);
        }
        free(keys);
    }
    if (CFArrayGetCount(formats) == 1)
        CFDictionarySetValue(out, kCVPixelBufferPixelFormatTypeKey, CFArrayGetValueAtIndex(formats, 0));
    else if (CFArrayGetCount(formats) > 1)
        CFDictionarySetValue(out, kCVPixelBufferPixelFormatTypeKey, formats);
    CFRelease(formats);
    *resolvedDictionaryOut = out;
    return kCVReturnSuccess;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "VTInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    OSType format;
    size_t width, height;
    size_t planeCount;
    uint8_t *planes[3];
    size_t strides[3];
    size_t widths[3], heights[3], bytesPerPixel[3];
} VTPixelView;

typedef struct { uint8_t r, g, b, a; } VTRGBA;

static Boolean
pixel_view(CVPixelBufferRef buffer, VTPixelView *view)
{
    memset(view, 0, sizeof(*view));
    view->format = CVPixelBufferGetPixelFormatType(buffer);
    view->width = CVPixelBufferGetWidth(buffer);
    view->height = CVPixelBufferGetHeight(buffer);
    if (!view->width || !view->height)
        return false;
    if (view->format == kCVPixelFormatType_32BGRA || view->format == kCVPixelFormatType_32ARGB || view->format == kCVPixelFormatType_32RGBA) {
        view->planeCount = 1;
        view->widths[0] = view->width;
        view->heights[0] = view->height;
        view->bytesPerPixel[0] = 4;
        view->strides[0] = CVPixelBufferGetBytesPerRow(buffer);
        view->planes[0] = CVPixelBufferGetBaseAddress(buffer);
        return view->planes[0] != NULL;
    }
    if (view->format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        view->format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        if (CVPixelBufferGetPlaneCount(buffer) < 2)
            return false;
        view->planeCount = 2;
        view->widths[0] = view->width; view->heights[0] = view->height; view->bytesPerPixel[0] = 1;
        view->widths[1] = (view->width + 1) / 2; view->heights[1] = (view->height + 1) / 2; view->bytesPerPixel[1] = 2;
        for (size_t i = 0; i < 2; i++) {
            view->strides[i] = CVPixelBufferGetBytesPerRowOfPlane(buffer, i);
            view->planes[i] = CVPixelBufferGetBaseAddressOfPlane(buffer, i);
        }
        return view->planes[0] && view->planes[1];
    }
    if (view->format == kCVPixelFormatType_420YpCbCr8Planar) {
        if (CVPixelBufferGetPlaneCount(buffer) < 3)
            return false;
        view->planeCount = 3;
        view->widths[0] = view->width; view->heights[0] = view->height;
        view->widths[1] = view->widths[2] = (view->width + 1) / 2;
        view->heights[1] = view->heights[2] = (view->height + 1) / 2;
        for (size_t i = 0; i < 3; i++) {
            view->bytesPerPixel[i] = 1;
            view->strides[i] = CVPixelBufferGetBytesPerRowOfPlane(buffer, i);
            view->planes[i] = CVPixelBufferGetBaseAddressOfPlane(buffer, i);
        }
        return view->planes[0] && view->planes[1] && view->planes[2];
    }
    return false;
}

static uint8_t
clamp_byte(int value)
{
    return (uint8_t)(value < 0 ? 0 : value > 255 ? 255 : value);
}

static VTRGBA
read_rgb(const VTPixelView *view, size_t x, size_t y)
{
    VTRGBA p = {0, 0, 0, 255};
    if (view->format == kCVPixelFormatType_32BGRA) {
        const uint8_t *s = view->planes[0] + y * view->strides[0] + 4 * x;
        p.b = s[0]; p.g = s[1]; p.r = s[2]; p.a = s[3];
        return p;
    }
    if (view->format == kCVPixelFormatType_32ARGB) {
        const uint8_t *s = view->planes[0] + y * view->strides[0] + 4 * x;
        p.a = s[0]; p.r = s[1]; p.g = s[2]; p.b = s[3];
        return p;
    }
    if (view->format == kCVPixelFormatType_32RGBA) {
        const uint8_t *s = view->planes[0] + y * view->strides[0] + 4 * x;
        p.r = s[0]; p.g = s[1]; p.b = s[2]; p.a = s[3];
        return p;
    }
    int yy = view->planes[0][y * view->strides[0] + x];
    int uu, vv;
    if (view->planeCount == 2) {
        const uint8_t *uv = view->planes[1] + (y / 2) * view->strides[1] + (x / 2) * 2;
        uu = uv[0]; vv = uv[1];
    } else {
        uu = view->planes[1][(y / 2) * view->strides[1] + x / 2];
        vv = view->planes[2][(y / 2) * view->strides[2] + x / 2];
    }
    int c = yy, d = uu - 128, e = vv - 128;
    if (view->format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        p.r = clamp_byte((int)lrint(c + 1.402 * e));
        p.g = clamp_byte((int)lrint(c - 0.344136 * d - 0.714136 * e));
        p.b = clamp_byte((int)lrint(c + 1.772 * d));
    } else {
        c -= 16;
        p.r = clamp_byte((298 * c + 409 * e + 128) >> 8);
        p.g = clamp_byte((298 * c - 100 * d - 208 * e + 128) >> 8);
        p.b = clamp_byte((298 * c + 516 * d + 128) >> 8);
    }
    return p;
}

static VTRGBA
sample_rgb(const VTPixelView *view, double x, double y)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > (double)view->width - 1) x = (double)view->width - 1;
    if (y > (double)view->height - 1) y = (double)view->height - 1;
    size_t x0 = (size_t)x, y0 = (size_t)y;
    size_t x1 = x0 + 1 < view->width ? x0 + 1 : x0;
    size_t y1 = y0 + 1 < view->height ? y0 + 1 : y0;
    double fx = x - (double)x0, fy = y - (double)y0;
    VTRGBA a = read_rgb(view, x0, y0), b = read_rgb(view, x1, y0);
    VTRGBA c = read_rgb(view, x0, y1), d = read_rgb(view, x1, y1);
    VTRGBA out;
#define BLEND(field) out.field = clamp_byte((int)lrint((1 - fy) * ((1 - fx) * a.field + fx * b.field) + fy * ((1 - fx) * c.field + fx * d.field)))
    BLEND(r); BLEND(g); BLEND(b); BLEND(a);
#undef BLEND
    return out;
}

static void
write_rgb(const VTPixelView *view, size_t x, size_t y, VTRGBA p)
{
    uint8_t *d = view->planes[0] + y * view->strides[0] + 4 * x;
    if (view->format == kCVPixelFormatType_32BGRA) {
        d[0] = p.b; d[1] = p.g; d[2] = p.r; d[3] = p.a;
    } else if (view->format == kCVPixelFormatType_32ARGB) {
        d[0] = p.a; d[1] = p.r; d[2] = p.g; d[3] = p.b;
    } else {
        d[0] = p.r; d[1] = p.g; d[2] = p.b; d[3] = p.a;
    }
}

static void
rgb_to_yuv(VTRGBA p, Boolean fullRange, int *y, int *u, int *v)
{
    if (fullRange) {
        *y = (77 * p.r + 150 * p.g + 29 * p.b + 128) >> 8;
        *u = ((-43 * p.r - 85 * p.g + 128 * p.b + 128) >> 8) + 128;
        *v = ((128 * p.r - 107 * p.g - 21 * p.b + 128) >> 8) + 128;
    } else {
        *y = ((66 * p.r + 129 * p.g + 25 * p.b + 128) >> 8) + 16;
        *u = ((-38 * p.r - 74 * p.g + 112 * p.b + 128) >> 8) + 128;
        *v = ((112 * p.r - 94 * p.g - 18 * p.b + 128) >> 8) + 128;
    }
}

static void
copy_same_format(const VTPixelView *source, const VTPixelView *destination)
{
    for (size_t plane = 0; plane < source->planeCount; plane++) {
        size_t bytes = source->widths[plane] * source->bytesPerPixel[plane];
        if (destination->widths[plane] < source->widths[plane] || destination->heights[plane] < source->heights[plane])
            continue;
        for (size_t y = 0; y < source->heights[plane]; y++)
            memcpy(destination->planes[plane] + y * destination->strides[plane], source->planes[plane] + y * source->strides[plane], bytes);
    }
}

static CFStringRef
scaling_mode(VTSessionBase *session)
{
    pthread_mutex_lock(&session->lock);
    CFTypeRef value = CFDictionaryGetValue(session->properties, kVTPixelTransferPropertyKey_ScalingMode);
    if (value) CFRetain(value);
    pthread_mutex_unlock(&session->lock);
    return value ? value : CFRetain(kVTScalingMode_Normal);
}

static void
copy_attachments(CVPixelBufferRef source, CVPixelBufferRef destination)
{
    CVBufferRemoveAllAttachments(destination);
    CVBufferPropagateAttachments(source, destination);
}

static void
transfer_pixels(const VTPixelView *source, const VTPixelView *destination, CFStringRef mode, CFStringRef downsamplingMode)
{
    double srcX = 0, srcY = 0, srcW = (double)source->width, srcH = (double)source->height;
    double dstX = 0, dstY = 0, dstW = (double)destination->width, dstH = (double)destination->height;
    double srcAspect = srcW / srcH, dstAspect = dstW / dstH;
    if ((CFEqual(mode, kVTScalingMode_Trim) || CFEqual(mode, kVTScalingMode_CropSourceToCleanAperture)) && srcAspect != dstAspect) {
        if (srcAspect > dstAspect) {
            srcW = srcH * dstAspect;
            srcX = ((double)source->width - srcW) / 2;
        } else {
            srcH = srcW / dstAspect;
            srcY = ((double)source->height - srcH) / 2;
        }
    } else if (CFEqual(mode, kVTScalingMode_Letterbox) && srcAspect != dstAspect) {
        if (srcAspect > dstAspect) {
            dstH = dstW / srcAspect;
            dstY = ((double)destination->height - dstH) / 2;
        } else {
            dstW = dstH * srcAspect;
            dstX = ((double)destination->width - dstW) / 2;
        }
    }
    if (CFEqual(mode, kVTScalingMode_Letterbox)) {
        uint8_t y = destination->format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 0 : 16;
        for (size_t plane = 0; plane < destination->planeCount; plane++) {
            uint8_t fill = plane == 0 ? y : 128;
            for (size_t row = 0; row < destination->heights[plane]; row++)
                memset(destination->planes[plane] + row * destination->strides[plane], fill,
                       destination->widths[plane] * destination->bytesPerPixel[plane]);
        }
    }
    for (size_t y = 0; y < destination->height; y++) {
        for (size_t x = 0; x < destination->width; x++) {
            if ((double)x < dstX || (double)x >= dstX + dstW || (double)y < dstY || (double)y >= dstY + dstH) {
                if (destination->planeCount == 1) {
                    VTRGBA black = {0, 0, 0, 255};
                    write_rgb(destination, x, y, black);
                }
                continue;
            }
            double sx = srcX + (((double)x + 0.5 - dstX) * srcW / dstW) - 0.5;
            double sy = srcY + (((double)y + 0.5 - dstY) * srcH / dstH) - 0.5;
            VTRGBA pixel = sample_rgb(source, sx, sy);
            if (destination->format == kCVPixelFormatType_32BGRA || destination->format == kCVPixelFormatType_32ARGB ||
                destination->format == kCVPixelFormatType_32RGBA) {
                write_rgb(destination, x, y, pixel);
            } else {
                int yy, uu, vv;
                rgb_to_yuv(pixel, destination->format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, &yy, &uu, &vv);
                destination->planes[0][y * destination->strides[0] + x] = clamp_byte(yy);
            }
        }
    }
    if (destination->planeCount > 1) {
        for (size_t y = 0; y < destination->heights[1]; y++) {
            for (size_t x = 0; x < destination->widths[1]; x++) {
                int totalU = 0, totalV = 0, count = 0;
                size_t samples = CFEqual(downsamplingMode, kVTDownsamplingMode_Decimate) ? 1 : 4;
                for (size_t sample = 0; sample < samples; sample++) {
                    size_t dy = samples == 1 ? 0 : sample / 2;
                    size_t dx = samples == 1 ? 0 : sample % 2;
                    size_t px = x * 2 + dx, py = y * 2 + dy;
                    if (px >= destination->width || py >= destination->height) continue;
                    double sx = srcX + (((double)px + 0.5 - dstX) * srcW / dstW) - 0.5;
                    double sy = srcY + (((double)py + 0.5 - dstY) * srcH / dstH) - 0.5;
                    VTRGBA pixel = sample_rgb(source, sx, sy);
                    int yy, uu, vv;
                    rgb_to_yuv(pixel, destination->format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, &yy, &uu, &vv);
                    totalU += uu; totalV += vv; count++;
                }
                int u = (totalU + count / 2) / count, v = (totalV + count / 2) / count;
                if (destination->planeCount == 2) {
                    uint8_t *uv = destination->planes[1] + y * destination->strides[1] + 2 * x;
                    uv[0] = clamp_byte(u); uv[1] = clamp_byte(v);
                } else {
                    destination->planes[1][y * destination->strides[1] + x] = clamp_byte(u);
                    destination->planes[2][y * destination->strides[2] + x] = clamp_byte(v);
                }
            }
        }
    }
}

OSStatus
VTPixelTransferSessionCreate(CFAllocatorRef allocator, VTPixelTransferSessionRef *sessionOut)
{
    if (!sessionOut)
        return kVTParameterErr;
    *sessionOut = NULL;
    *sessionOut = (VTPixelTransferSessionRef)_VTCreateSession(allocator, VTKindPixelTransfer, sizeof(struct OpaqueVTPixelTransferSession));
    return *sessionOut ? noErr : kVTAllocationFailedErr;
}

void
VTPixelTransferSessionInvalidate(VTPixelTransferSessionRef sessionRef)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || session->kind != VTKindPixelTransfer) return;
    pthread_mutex_lock(&session->lock);
    session->invalidated = true;
    pthread_mutex_unlock(&session->lock);
}

OSStatus
VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef sessionRef, CVPixelBufferRef sourceBuffer, CVPixelBufferRef destinationBuffer)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || session->kind != VTKindPixelTransfer || !sourceBuffer || !destinationBuffer)
        return kVTParameterErr;
    pthread_mutex_lock(&session->lock);
    Boolean invalidated = session->invalidated;
    pthread_mutex_unlock(&session->lock);
    if (invalidated)
        return kVTInvalidSessionErr;
    if (sourceBuffer == destinationBuffer)
        return kVTParameterErr;
    if (CVPixelBufferLockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return kVTPixelTransferNotSupportedErr;
    if (CVPixelBufferLockBaseAddress(destinationBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return kVTPixelTransferNotSupportedErr;
    }
    VTPixelView source, destination;
    if (!pixel_view(sourceBuffer, &source) || !pixel_view(destinationBuffer, &destination)) {
        CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
        CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return kVTPixelTransferNotSupportedErr;
    }
    CFStringRef mode = scaling_mode(session);
    pthread_mutex_lock(&session->lock);
    CFTypeRef downsampling = CFDictionaryGetValue(session->properties, kVTPixelTransferPropertyKey_DownsamplingMode);
    if (downsampling) CFRetain(downsampling);
    pthread_mutex_unlock(&session->lock);
    if (!downsampling) downsampling = CFRetain(kVTDownsamplingMode_Average);
    if (source.format == destination.format && source.width == destination.width && source.height == destination.height &&
        CFEqual(mode, kVTScalingMode_Normal))
        copy_same_format(&source, &destination);
    else
        transfer_pixels(&source, &destination, mode, downsampling);
    CFRelease(mode);
    CFRelease(downsampling);
    CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
    CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
    copy_attachments(sourceBuffer, destinationBuffer);
    return noErr;
}

__attribute__((visibility("default")))
OSStatus
VTPixelTransferSessionSetProperty(VTPixelTransferSessionRef sessionRef, CFStringRef key, CFTypeRef value)
{
    return VTSessionSetProperty(sessionRef, key, value);
}

OSStatus
VTPixelRotationSessionCreate(CFAllocatorRef allocator, VTPixelRotationSessionRef *sessionOut)
{
    if (!sessionOut)
        return kVTParameterErr;
    *sessionOut = NULL;
    *sessionOut = (VTPixelRotationSessionRef)_VTCreateSession(allocator, VTKindPixelRotation, sizeof(struct OpaqueVTPixelRotationSession));
    return *sessionOut ? noErr : kVTAllocationFailedErr;
}

void
VTPixelRotationSessionInvalidate(VTPixelRotationSessionRef sessionRef)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || session->kind != VTKindPixelRotation) return;
    pthread_mutex_lock(&session->lock);
    session->invalidated = true;
    pthread_mutex_unlock(&session->lock);
}

static size_t
rotation_degrees(CFStringRef value)
{
    if (CFEqual(value, kVTRotation_CW90)) return 90;
    if (CFEqual(value, kVTRotation_180)) return 180;
    if (CFEqual(value, kVTRotation_CCW90)) return 270;
    return 0;
}

OSStatus
VTPixelRotationSessionRotateImage(VTPixelRotationSessionRef sessionRef, CVPixelBufferRef sourceBuffer, CVPixelBufferRef destinationBuffer)
{
    VTSessionBase *session = _VTGetSession(sessionRef);
    if (!session || session->kind != VTKindPixelRotation || !sourceBuffer || !destinationBuffer)
        return kVTParameterErr;
    pthread_mutex_lock(&session->lock);
    Boolean invalidated = session->invalidated;
    CFTypeRef rotation = CFDictionaryGetValue(session->properties, kVTPixelRotationPropertyKey_Rotation);
    if (rotation) CFRetain(rotation);
    CFTypeRef flipH = CFDictionaryGetValue(session->properties, kVTPixelRotationPropertyKey_FlipHorizontalOrientation);
    if (flipH) CFRetain(flipH);
    CFTypeRef flipV = CFDictionaryGetValue(session->properties, kVTPixelRotationPropertyKey_FlipVerticalOrientation);
    if (flipV) CFRetain(flipV);
    pthread_mutex_unlock(&session->lock);
    if (invalidated) {
        if (rotation) CFRelease(rotation); if (flipH) CFRelease(flipH); if (flipV) CFRelease(flipV);
        return kVTInvalidSessionErr;
    }
    if (!rotation) rotation = CFRetain(kVTRotation_0);
    size_t degrees = rotation_degrees(rotation);
    if (rotation) CFRelease(rotation);
    Boolean horizontal = flipH && CFEqual(flipH, kCFBooleanTrue);
    Boolean vertical = flipV && CFEqual(flipV, kCFBooleanTrue);
    if (flipH) CFRelease(flipH); if (flipV) CFRelease(flipV);
    if (sourceBuffer == destinationBuffer)
        return kVTParameterErr;
    if (CVPixelBufferLockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return kVTPixelRotationNotSupportedErr;
    if (CVPixelBufferLockBaseAddress(destinationBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return kVTPixelRotationNotSupportedErr;
    }
    VTPixelView source, destination;
    if (!pixel_view(sourceBuffer, &source) || !pixel_view(destinationBuffer, &destination) || source.format != destination.format) {
        CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
        CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return kVTPixelRotationNotSupportedErr;
    }
    size_t requiredWidth = (degrees == 90 || degrees == 270) ? source.height : source.width;
    size_t requiredHeight = (degrees == 90 || degrees == 270) ? source.width : source.height;
    if (destination.width != requiredWidth || destination.height != requiredHeight) {
        CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
        CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return kVTParameterErr;
    }
    for (size_t plane = 0; plane < source.planeCount; plane++) {
        size_t sourceWidth = source.widths[plane], sourceHeight = source.heights[plane];
        size_t destinationWidth = destination.widths[plane], destinationHeight = destination.heights[plane];
        size_t pixelSize = source.bytesPerPixel[plane];
        if (destinationWidth != ((degrees == 90 || degrees == 270) ? sourceHeight : sourceWidth) ||
            destinationHeight != ((degrees == 90 || degrees == 270) ? sourceWidth : sourceHeight)) {
            CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
            CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
            return kVTParameterErr;
        }
        for (size_t y = 0; y < sourceHeight; y++) for (size_t x = 0; x < sourceWidth; x++) {
            size_t dx, dy;
            if (degrees == 90) { dx = sourceHeight - 1 - y; dy = x; }
            else if (degrees == 180) { dx = sourceWidth - 1 - x; dy = sourceHeight - 1 - y; }
            else if (degrees == 270) { dx = y; dy = sourceWidth - 1 - x; }
            else { dx = x; dy = y; }
            if (horizontal) dx = destinationWidth - 1 - dx;
            if (vertical) dy = destinationHeight - 1 - dy;
            memcpy(destination.planes[plane] + dy * destination.strides[plane] + dx * pixelSize,
                   source.planes[plane] + y * source.strides[plane] + x * pixelSize, pixelSize);
        }
    }
    CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
    CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
    copy_attachments(sourceBuffer, destinationBuffer);
    return noErr;
}

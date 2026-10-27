/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "common.h"
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int buffer_ok(const vImage_Buffer *buffer, size_t pixelBytes)
{
    return buffer && buffer->data && buffer->width && buffer->height &&
           buffer->width <= SIZE_MAX / pixelBytes &&
           buffer->rowBytes >= buffer->width * pixelBytes &&
           buffer->height <= SIZE_MAX / buffer->rowBytes;
}

static int has_only(vImage_Flags flags, uint32_t allowed)
{
    return (((uint32_t)flags) & ~allowed) == 0;
}











vImage_Error vImageBuffer_InitWithCGImage(vImage_Buffer *buf, vImage_CGImageFormat *format,
                                          const CGFloat *backgroundColor, CGImageRef image,
                                          vImage_Flags flags)
{
    size_t width, height, pixelBytes, minimumRow, rowBytes;
    void *data;
    CGColorSpaceRef colorSpace;
    CGContextRef context;
    if (!buf || !format || !image) return kvImageNullPointerArgument;
    if (format->version > 1 || format->decode || !format->bitsPerComponent ||
        !format->bitsPerPixel || (format->bitsPerPixel & 7) ||
        !has_only(flags, kvImageNoAllocate | kvImageDoNotTile | kvImagePrintDiagnosticsToConsole))
        return kvImageInvalidParameter;
    width = CGImageGetWidth(image);
    height = CGImageGetHeight(image);
    pixelBytes = format->bitsPerPixel / 8;
    if (!width || !height || width > SIZE_MAX / pixelBytes) return kvImageInvalidParameter;
    minimumRow = width * pixelBytes;
    if (flags & kvImageNoAllocate) {
        if (!buf->data || buf->rowBytes < minimumRow) return kvImageInvalidParameter;
        data = buf->data;
        rowBytes = buf->rowBytes;
    } else {
        if (height > SIZE_MAX / minimumRow)
            return kvImageInvalidParameter;
        rowBytes = minimumRow;
        data = calloc(height, rowBytes);
        if (!data) return kvImageMemoryAllocationError;
    }
    colorSpace = format->colorSpace;
    if (!colorSpace) colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else CFRetain(colorSpace);
    if (!colorSpace) {
        if (!(flags & kvImageNoAllocate)) free(data);
        return kvImageMemoryAllocationError;
    }
    context = CGBitmapContextCreate(data, width, height, format->bitsPerComponent, rowBytes,
                                    colorSpace, format->bitmapInfo);
    if (!context) {
        CGColorSpaceRelease(colorSpace);
        if (!(flags & kvImageNoAllocate)) free(data);
        return kvImageInvalidImageFormat;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextClearRect(context, CGRectMake(0, 0, width, height));
    if (backgroundColor) {
        size_t components = CGColorSpaceGetNumberOfComponents(colorSpace);
        CGFloat values[5] = {0, 0, 0, 0, 1};
        size_t i;
        for (i = 0; i < components && i < 4; ++i) values[i] = backgroundColor[i];
        values[components < 4 ? components : 4] = 1.0;
        CGContextSetFillColor(context, values);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    buf->data = data;
    buf->width = width;
    buf->height = height;
    buf->rowBytes = rowBytes;
    return kvImageNoError;
}

typedef struct {
    void (*callback)(void *, void *);
    void *userData;
    int armed;
} FinchImageRelease;

static void release_image_bytes(void *info, const void *data, size_t size)
{
    FinchImageRelease *release = info;
    (void)size;
    if (release->armed) {
        if (release->callback) release->callback(release->userData, (void *)data);
        else free((void *)data);
    }
    free(release);
}

CGImageRef vImageCreateCGImageFromBuffer(const vImage_Buffer *buf,
                                        const vImage_CGImageFormat *format,
                                        void (*callback)(void *userData, void *buf_data),
                                        void *userData, vImage_Flags flags, vImage_Error *error)
{
    size_t pixelBytes, length;
    CGColorSpaceRef colorSpace;
    CGDataProviderRef provider = NULL;
    CGImageRef image = NULL;
    FinchImageRelease *release = NULL;
    int noAllocate = (flags & kvImageNoAllocate) != 0;
    if (error) *error = kvImageNoError;
    if (!buf || !format) {
        if (error) *error = kvImageNullPointerArgument;
        return NULL;
    }
    if (!format->bitsPerPixel || (format->bitsPerPixel & 7) || format->decode ||
        !has_only(flags, kvImageNoAllocate | kvImageDoNotTile | kvImageHighQualityResampling |
                         kvImagePrintDiagnosticsToConsole)) {
        if (error) *error = kvImageInvalidParameter;
        return NULL;
    }
    pixelBytes = format->bitsPerPixel / 8;
    if (!buffer_ok(buf, pixelBytes) || buf->height > SIZE_MAX / buf->rowBytes) {
        if (error) *error = kvImageInvalidParameter;
        return NULL;
    }
    length = buf->height * buf->rowBytes;
    if (length > LONG_MAX) {
        if (error) *error = kvImageInvalidParameter;
        return NULL;
    }
    colorSpace = format->colorSpace;
    if (!colorSpace) colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else CFRetain(colorSpace);
    if (!colorSpace) {
        if (error) *error = kvImageMemoryAllocationError;
        return NULL;
    }
    if (noAllocate) {
        release = calloc(1, sizeof(*release));
        if (!release) {
            CGColorSpaceRelease(colorSpace);
            if (error) *error = kvImageMemoryAllocationError;
            return NULL;
        }
        release->callback = callback;
        release->userData = userData;
        provider = CGDataProviderCreateWithData(release, buf->data, length, release_image_bytes);
    } else {
        CFDataRef bytes = CFDataCreate(kCFAllocatorDefault, buf->data, (CFIndex)length);
        if (bytes) {
            provider = CGDataProviderCreateWithCFData(bytes);
            CFRelease(bytes);
        }
    }
    if (provider) {
        image = CGImageCreate(buf->width, buf->height, format->bitsPerComponent,
                              format->bitsPerPixel, buf->rowBytes, colorSpace,
                              format->bitmapInfo, provider, format->decode, false,
                              format->renderingIntent);
    }
    if (release) release->armed = image != NULL;
    if (provider) CGDataProviderRelease(provider);
    else if (release) free(release);
    CGColorSpaceRelease(colorSpace);
    if (!image && error) *error = provider ? kvImageInvalidImageFormat : kvImageMemoryAllocationError;
    return image;
}

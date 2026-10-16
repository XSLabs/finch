/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <Accelerate/Accelerate.h>
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

static double sinc(double x)
{
    if (fabs(x) < 1.0e-12) return 1.0;
    x *= M_PI;
    return sin(x) / x;
}

static double lanczos(double distance, double scale, unsigned int lobes)
{
    double x = distance / scale;
    if (fabs(x) >= lobes) return 0.0;
    return sinc(x) * sinc(x / lobes);
}

static vImage_Error scale_image(const vImage_Buffer *src, const vImage_Buffer *dst,
                                unsigned int channels, vImage_Flags flags)
{
    unsigned int lobes = (flags & kvImageHighQualityResampling) ? 5 : 3;
    double scaleX, scaleY, filterX, filterY;
    size_t x, y;
    if (!src || !dst) return kvImageNullPointerArgument;
    if (!buffer_ok(src, channels) || !buffer_ok(dst, channels)) return kvImageInvalidParameter;
    if (!has_only(flags, kvImageHighQualityResampling | kvImageDoNotTile))
        return kvImageUnknownFlagsBit;
    if (flags & kvImageGetTempBufferSize) return 0;
    scaleX = (double)src->width / (double)dst->width;
    scaleY = (double)src->height / (double)dst->height;
    filterX = scaleX > 1.0 ? scaleX : 1.0;
    filterY = scaleY > 1.0 ? scaleY : 1.0;

    for (y = 0; y < dst->height; ++y) {
        double centerY = ((double)y + 0.5) * scaleY - 0.5;
        int64_t firstY = (int64_t)floor(centerY - lobes * filterY + 1.0);
        int64_t lastY = (int64_t)floor(centerY + lobes * filterY);
        for (x = 0; x < dst->width; ++x) {
            double centerX = ((double)x + 0.5) * scaleX - 0.5;
            int64_t firstX = (int64_t)floor(centerX - lobes * filterX + 1.0);
            int64_t lastX = (int64_t)floor(centerX + lobes * filterX);
            double sums[4] = {0, 0, 0, 0}, weightSum = 0.0;
            int64_t sy, sx;
            unsigned int c;
            for (sy = firstY; sy <= lastY; ++sy) {
                double wy = lanczos((double)sy - centerY, filterY, lobes);
                size_t iy = sy < 0 ? 0 : (size_t)sy >= src->height ? src->height - 1 : (size_t)sy;
                for (sx = firstX; sx <= lastX; ++sx) {
                    double wx = lanczos((double)sx - centerX, filterX, lobes);
                    double weight = wx * wy;
                    size_t ix = sx < 0 ? 0 : (size_t)sx >= src->width ? src->width - 1 : (size_t)sx;
                    const uint8_t *in = (const uint8_t *)src->data + iy * src->rowBytes + ix * channels;
                    for (c = 0; c < channels; ++c)
                        sums[c] += in[c] * weight;
                    weightSum += weight;
                }
            }
            {
                uint8_t *out = (uint8_t *)dst->data + y * dst->rowBytes + x * channels;
                    for (c = 0; c < channels; ++c) {
                    double value = weightSum == 0.0 ? 0.0 : sums[c] / weightSum;
                    if (value < 0.0) value = 0.0;
                    if (value > 255.0) value = 255.0;
                    out[c] = (uint8_t)floor(value + 0.5);
                }
            }
        }
    }
    return kvImageNoError;
}

vImage_Error vImageScale_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                  void *tempBuffer, vImage_Flags flags)
{
    (void)tempBuffer;
    return scale_image(src, dest, 4, flags);
}

vImage_Error vImageScale_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                 void *tempBuffer, vImage_Flags flags)
{
    (void)tempBuffer;
    return scale_image(src, dest, 1, flags);
}

static uint8_t clamp_byte(int64_t value)
{
    if (value < 0) return 0;
    if (value > 255) return 255;
    return (uint8_t)value;
}

static unsigned int edge_mode(vImage_Flags flags)
{
    return (uint32_t)flags & (kvImageCopyInPlace | kvImageBackgroundColorFill |
                              kvImageEdgeExtend | kvImageTruncateKernel);
}

static vImage_Error convolve_8888(const vImage_Buffer *src, const vImage_Buffer *dst,
                                  vImagePixelCount offsetX, vImagePixelCount offsetY,
                                  uint32_t kernelHeight, uint32_t kernelWidth,
                                  const Pixel_8888 background, vImage_Flags flags,
                                  int tent)
{
    unsigned int mode = edge_mode(flags), channel;
    size_t x, y;
    if (!src || !dst) return kvImageNullPointerArgument;
    if (!buffer_ok(src, 4) || !buffer_ok(dst, 4)) return kvImageInvalidParameter;
    if (!background && mode == kvImageBackgroundColorFill) return kvImageNullPointerArgument;
    if (!kernelHeight || !kernelWidth || !(kernelHeight & 1) || !(kernelWidth & 1))
        return kvImageInvalidKernelSize;
    if (offsetX > src->width || offsetY > src->height ||
        dst->width > src->width - offsetX || dst->height > src->height - offsetY)
        return kvImageInvalidParameter;
    if (!mode || (mode & (mode - 1))) return kvImageInvalidEdgeStyle;
    if (!has_only(flags, kvImageCopyInPlace | kvImageBackgroundColorFill | kvImageEdgeExtend |
                         kvImageTruncateKernel | kvImageLeaveAlphaUnchanged | kvImageDoNotTile |
                         kvImageGetTempBufferSize))
        return kvImageUnknownFlagsBit;
    if (flags & kvImageGetTempBufferSize) return 0;

    for (y = 0; y < dst->height; ++y) {
        for (x = 0; x < dst->width; ++x) {
            uint64_t sums[4] = {0, 0, 0, 0}, divisor = 0;
            int missing = 0;
            int64_t ky, kx;
            for (ky = 0; ky < kernelHeight; ++ky) {
                int64_t dy = ky - (int64_t)(kernelHeight / 2);
                int64_t sy = (int64_t)offsetY + (int64_t)y + dy;
                uint64_t wy = tent ? kernelHeight / 2 + 1 - (uint64_t)llabs(dy) : 1;
                for (kx = 0; kx < kernelWidth; ++kx) {
                    int64_t dx = kx - (int64_t)(kernelWidth / 2);
                    int64_t sx = (int64_t)offsetX + (int64_t)x + dx;
                    uint64_t wx = tent ? kernelWidth / 2 + 1 - (uint64_t)llabs(dx) : 1;
                    uint64_t weight = wx * wy;
                    const Pixel_8888 *pixel;
                    Pixel_8888 fill;
                    unsigned int c;
                    int outside = sx < 0 || sy < 0 || (uint64_t)sx >= src->width || (uint64_t)sy >= src->height;
                    if (outside && mode == kvImageCopyInPlace) {
                        missing = 1;
                        continue;
                    }
                    if (outside && mode == kvImageTruncateKernel)
                        continue;
                    if (outside && mode == kvImageEdgeExtend) {
                        if (sx < 0) sx = 0;
                        if (sy < 0) sy = 0;
                        if ((uint64_t)sx >= src->width) sx = (int64_t)src->width - 1;
                        if ((uint64_t)sy >= src->height) sy = (int64_t)src->height - 1;
                    }
                    if (outside && mode == kvImageBackgroundColorFill) {
                        memcpy(fill, background, sizeof(fill));
                        pixel = &fill;
                    } else {
                        pixel = (const Pixel_8888 *)((const uint8_t *)src->data + (size_t)sy * src->rowBytes) + (size_t)sx;
                    }
                    for (c = 0; c < 4; ++c)
                        sums[c] += (uint64_t)pixel[0][c] * weight;
                    divisor += weight;
                }
            }
            {
                const Pixel_8888 *center = (const Pixel_8888 *)((const uint8_t *)src->data + (offsetY + y) * src->rowBytes) + offsetX + x;
                Pixel_8888 *out = (Pixel_8888 *)((uint8_t *)dst->data + y * dst->rowBytes) + x;
                if (missing) {
                    memcpy(out, center, sizeof(*out));
                    continue;
                }
                if (!divisor) return kvImageInvalidParameter;
                for (channel = 0; channel < 4; ++channel) {
                    if (channel == 0 && (flags & kvImageLeaveAlphaUnchanged)) {
                        out[0][channel] = center[0][channel];
                        continue;
                    }
                    out[0][channel] = clamp_byte((int64_t)((sums[channel] + divisor / 2) / divisor));
                }
            }
        }
    }
    return kvImageNoError;
}

vImage_Error vImageBoxConvolve_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                        void *tempBuffer, vImagePixelCount srcOffsetToROI_X,
                                        vImagePixelCount srcOffsetToROI_Y, uint32_t kernel_height,
                                        uint32_t kernel_width, const Pixel_8888 backgroundColor,
                                        vImage_Flags flags)
{
    (void)tempBuffer;
    return convolve_8888(src, dest, srcOffsetToROI_X, srcOffsetToROI_Y, kernel_height,
                         kernel_width, backgroundColor, flags, 0);
}

vImage_Error vImageTentConvolve_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                         void *tempBuffer, vImagePixelCount srcOffsetToROI_X,
                                         vImagePixelCount srcOffsetToROI_Y, uint32_t kernel_height,
                                         uint32_t kernel_width, const Pixel_8888 backgroundColor,
                                         vImage_Flags flags)
{
    (void)tempBuffer;
    return convolve_8888(src, dest, srcOffsetToROI_X, srcOffsetToROI_Y, kernel_height,
                         kernel_width, backgroundColor, flags, 1);
}

vImage_Error vImageTableLookUp_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                       const Pixel_8 table[256], vImage_Flags flags)
{
    size_t x, y;
    if (!src || !dest || !table) return kvImageNullPointerArgument;
        if (!buffer_ok(src, 1) || !buffer_ok(dest, 1) ||
        src->width != dest->width || src->height != dest->height)
        return kvImageInvalidParameter;
    if (!has_only(flags, kvImageDoNotTile)) return kvImageUnknownFlagsBit;
    for (y = 0; y < src->height; ++y) {
        const uint8_t *in = (const uint8_t *)src->data + y * src->rowBytes;
        uint8_t *out = (uint8_t *)dest->data + y * dest->rowBytes;
        for (x = 0; x < src->width; ++x)
            out[x] = table[in[x]];
    }
    return kvImageNoError;
}

vImage_Error vImageMatrixMultiply_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                           const int16_t matrix[16], int32_t divisor,
                                           const int16_t *preBias, const int32_t *postBias,
                                           vImage_Flags flags)
{
    size_t x, y;
    unsigned int row, col;
    if (!src || !dest || !matrix) return kvImageNullPointerArgument;
    if (!buffer_ok(src, 4) || !buffer_ok(dest, 4) ||
        src->width != dest->width || src->height != dest->height)
        return kvImageInvalidParameter;
    if (!has_only(flags, kvImageLeaveAlphaUnchanged | kvImageDoNotTile))
        return kvImageUnknownFlagsBit;
    if (!divisor) divisor = 1;
    for (y = 0; y < src->height; ++y) {
        const Pixel_8888 *in = (const Pixel_8888 *)((const uint8_t *)src->data + y * src->rowBytes);
        Pixel_8888 *out = (Pixel_8888 *)((uint8_t *)dest->data + y * dest->rowBytes);
        for (x = 0; x < src->width; ++x) {
            for (row = 0; row < 4; ++row) {
                int64_t total = postBias ? postBias[row] : 0;
                if (row == 0 && (flags & kvImageLeaveAlphaUnchanged)) {
                    out[x][row] = in[x][row];
                    continue;
                }
                for (col = 0; col < 4; ++col) {
                    int64_t value = (int64_t)in[x][col] + (preBias ? preBias[col] : 0);
                    total += value * matrix[row * 4 + col];
                }
                if (total >= 0) total = (total + divisor / 2) / divisor;
                else total = (total - divisor / 2) / divisor;
                out[x][row] = clamp_byte(total);
            }
        }
    }
    return kvImageNoError;
}

vImage_Error vImageHistogramCalculation_ARGB8888(const vImage_Buffer *src,
                                                  vImagePixelCount *histogram[4],
                                                  vImage_Flags flags)
{
    size_t x, y;
    unsigned int c;
    if (!src || !histogram) return kvImageNullPointerArgument;
    if (!buffer_ok(src, 4)) return kvImageInvalidParameter;
    if (!has_only(flags, kvImageLeaveAlphaUnchanged | kvImageDoNotTile))
        return kvImageUnknownFlagsBit;
    for (c = 0; c < 4; ++c) {
        if (!histogram[c]) return kvImageNullPointerArgument;
        if (c != 0 || !(flags & kvImageLeaveAlphaUnchanged))
            memset(histogram[c], 0, 256 * sizeof(**histogram));
    }
    for (y = 0; y < src->height; ++y) {
        const Pixel_8888 *row = (const Pixel_8888 *)((const uint8_t *)src->data + y * src->rowBytes);
        for (x = 0; x < src->width; ++x)
            for (c = 0; c < 4; ++c)
                if (c != 0 || !(flags & kvImageLeaveAlphaUnchanged))
                    ++histogram[c][row[x][c]];
    }
    return kvImageNoError;
}

vImage_Error vImageHistogramCalculation_ARGBFFFF(const vImage_Buffer *src,
                                                  vImagePixelCount *histogram[4],
                                                  unsigned int entries, Pixel_F minVal,
                                                  Pixel_F maxVal, vImage_Flags flags)
{
    size_t x, y;
    unsigned int c;
    if (!src || !histogram) return kvImageNullPointerArgument;
    if (!buffer_ok(src, 4 * sizeof(float))) return kvImageInvalidParameter;
    if (!entries || !(maxVal > minVal)) return kvImageInvalidParameter;
    if (!has_only(flags, kvImageLeaveAlphaUnchanged | kvImageDoNotTile))
        return kvImageUnknownFlagsBit;
    for (c = 0; c < 4; ++c) {
        if (!histogram[c]) return kvImageNullPointerArgument;
        if (c != 0 || !(flags & kvImageLeaveAlphaUnchanged))
            memset(histogram[c], 0, entries * sizeof(**histogram));
    }
    for (y = 0; y < src->height; ++y) {
        const float *row = (const float *)((const uint8_t *)src->data + y * src->rowBytes);
        for (x = 0; x < src->width; ++x) {
            for (c = 0; c < 4; ++c) {
                double position;
                unsigned int bin;
                if (c == 0 && (flags & kvImageLeaveAlphaUnchanged)) continue;
                position = entries * ((double)row[4 * x + c] - minVal) / ((double)maxVal - minVal);
                if (isnan(position) || position <= 0.0) bin = 0;
                else if (position >= entries) bin = entries - 1;
                else bin = (unsigned int)position;
                ++histogram[c][bin];
            }
        }
    }
    return kvImageNoError;
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

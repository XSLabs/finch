/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's conversions between channel layouts (Conversion.h): interleaving and
 * de-interleaving, packed 16-bit formats (ARGB1555, RGBA5551, RGB565), adding and
 * dropping alpha, permutes, overwrites, selects and fills, flattening against a
 * background, 16Q12 interleaving, 12-bit packing and 1-, 2- and 4-bit pixels. The
 * arithmetic is the header's, formula for formula.
 */
#include "common.h"

/* MARK: - 12-bit packing */

vImage_Error vImageConvert_12UTo16U(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint16_t *out = (uint16_t *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; x += 2) {
            uint32_t t0 = ((uint32_t)in[0] << 16) | ((uint32_t)in[1] << 8) | in[2], t1 = t0 & 0xfff;
            in += 3;
            t0 >>= 12;
            out[x] = (uint16_t)((t0 * 65535U + (t0 << 4) + 2055U) >> 12);
            if (x + 1 < dest->width)
                out[x + 1] = (uint16_t)((t1 * 65535U + (t1 << 4) + 2055U) >> 12);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_16UTo12U(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint16_t *in = (const uint16_t *)CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; x += 2) {
            uint32_t t0 = in[x], t1 = x + 1 < dest->width ? in[x + 1] : 0;
            t0 = (t0 * 4095 + 32767 + (t0 >> 4)) >> 16;
            t1 = (t1 * 4095 + 32767 + (t1 >> 4)) >> 16;
            t0 = (t0 << 12) | t1;
            out[0] = (uint8_t)(t0 >> 16);
            out[1] = (uint8_t)(t0 >> 8);
            if (x + 1 < dest->width)
                out[2] = (uint8_t)t0;
            out += 3;
        }
    }
    return kvImageNoError;
}

/* MARK: - Interleaving and de-interleaving */

/* channel c of src to planes[c] (NULL planes skipped); the planes share a size */
static vImage_Error deinterleave(const vImage_Buffer *src, const vImage_Buffer *const *planes, int n, size_t size)
{
    const vImage_Buffer *first = NULL;
    for (int c = 0; c < n; ++c)
        if (planes[c]) {
            if (!first)
                first = planes[c];
            CHECK(same_size(first, planes[c]));
        }
    if (!first)
        return kvImageNullPointerArgument;
    CHECK(fits(first, src));
    for (vImagePixelCount y = 0; y < first->height; ++y) {
        const uint8_t *in = CROW(src, y);
        for (int c = 0; c < n; ++c)
            if (planes[c]) {
                uint8_t *out = ROW(planes[c], y);
                for (vImagePixelCount x = 0; x < first->width; ++x)
                    memcpy(out + x * size, in + (x * (size_t)n + (size_t)c) * size, size);
            }
    }
    return kvImageNoError;
}

/* planes[c] (or the constant fill, for a NULL plane) to channel c of dest */
static vImage_Error interleave(const vImage_Buffer *const *planes, int n, size_t size, const void *fill,
                               const vImage_Buffer *dest)
{
    for (int c = 0; c < n; ++c)
        if (planes[c])
            CHECK(fits(dest, planes[c]));
    if (!dest || !dest->data)
        return kvImageNullPointerArgument;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        uint8_t *out = ROW(dest, y);
        for (int c = 0; c < n; ++c) {
            const uint8_t *in = planes[c] ? CROW(planes[c], y) : NULL;
            for (vImagePixelCount x = 0; x < dest->width; ++x)
                memcpy(out + (x * (size_t)n + (size_t)c) * size, in ? in + x * size : (const uint8_t *)fill, size);
        }
    }
    return kvImageNoError;
}

#define DEINTERLEAVE4(name, size, A, B, C, D)                                                            \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *p0, const vImage_Buffer *p1,        \
                      const vImage_Buffer *p2, const vImage_Buffer *p3, vImage_Flags flags)              \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        const vImage_Buffer *planes[4] = {A, B, C, D};                                                   \
        return deinterleave(src, planes, 4, size);                                                       \
    }
#define DEINTERLEAVE3(name, size, A, B, C, D)                                                            \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *p0, const vImage_Buffer *p1,        \
                      const vImage_Buffer *p2, vImage_Flags flags)                                       \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        const vImage_Buffer *planes[4] = {A, B, C, D};                                                   \
        return deinterleave(src, planes, D ? 4 : 3, size);                                               \
    }
DEINTERLEAVE4(vImageConvert_ARGB8888toPlanar8, 1, p0, p1, p2, p3)
DEINTERLEAVE4(vImageConvert_ARGBFFFFtoPlanarF, 4, p0, p1, p2, p3)
DEINTERLEAVE4(vImageConvert_ARGB16UtoPlanar16U, 2, p0, p1, p2, p3)
DEINTERLEAVE3(vImageConvert_RGB888toPlanar8, 1, p0, p1, p2, NULL)
DEINTERLEAVE3(vImageConvert_RGBFFFtoPlanarF, 4, p0, p1, p2, NULL)
DEINTERLEAVE3(vImageConvert_RGB16UtoPlanar16U, 2, p0, p1, p2, NULL)

vImage_Error vImageConvert_BGRX8888ToPlanar8(const vImage_Buffer *src, const vImage_Buffer *b, const vImage_Buffer *g,
                                             const vImage_Buffer *r, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return deinterleave(src, planes, 4, 1);
}
vImage_Error vImageConvert_BGRXFFFFToPlanarF(const vImage_Buffer *src, const vImage_Buffer *b, const vImage_Buffer *g,
                                             const vImage_Buffer *r, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return deinterleave(src, planes, 4, 4);
}

#define INTERLEAVE4(name, size)                                                                          \
    vImage_Error name(const vImage_Buffer *p0, const vImage_Buffer *p1, const vImage_Buffer *p2,         \
                      const vImage_Buffer *p3, const vImage_Buffer *dest, vImage_Flags flags)            \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        const vImage_Buffer *planes[4] = {p0, p1, p2, p3};                                               \
        for (int c = 0; c < 4; ++c)                                                                      \
            if (!planes[c])                                                                              \
                return kvImageNullPointerArgument;                                                       \
        return interleave(planes, 4, size, NULL, dest);                                                  \
    }
#define INTERLEAVE3(name, size)                                                                          \
    vImage_Error name(const vImage_Buffer *p0, const vImage_Buffer *p1, const vImage_Buffer *p2,         \
                      const vImage_Buffer *dest, vImage_Flags flags)                                     \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        const vImage_Buffer *planes[3] = {p0, p1, p2};                                                   \
        for (int c = 0; c < 3; ++c)                                                                      \
            if (!planes[c])                                                                              \
                return kvImageNullPointerArgument;                                                       \
        return interleave(planes, 3, size, NULL, dest);                                                  \
    }
INTERLEAVE4(vImageConvert_Planar8toARGB8888, 1)
INTERLEAVE4(vImageConvert_PlanarFtoARGBFFFF, 4)
INTERLEAVE4(vImageConvert_Planar16UtoARGB16U, 2)
INTERLEAVE3(vImageConvert_Planar8toRGB888, 1)
INTERLEAVE3(vImageConvert_PlanarFtoRGBFFF, 4)
INTERLEAVE3(vImageConvert_Planar16UtoRGB16U, 2)

vImage_Error vImageConvert_Planar8ToXRGB8888(Pixel_8 alpha, const vImage_Buffer *r, const vImage_Buffer *g,
                                             const vImage_Buffer *b, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {NULL, r, g, b};
    return interleave(planes, 4, 1, &alpha, dest);
}
vImage_Error vImageConvert_Planar8ToBGRX8888(const vImage_Buffer *b, const vImage_Buffer *g, const vImage_Buffer *r,
                                             Pixel_8 alpha, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return interleave(planes, 4, 1, &alpha, dest);
}
vImage_Error vImageConvert_PlanarFToXRGBFFFF(Pixel_F alpha, const vImage_Buffer *r, const vImage_Buffer *g,
                                             const vImage_Buffer *b, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {NULL, r, g, b};
    return interleave(planes, 4, 4, &alpha, dest);
}
vImage_Error vImageConvert_PlanarFToBGRXFFFF(const vImage_Buffer *b, const vImage_Buffer *g, const vImage_Buffer *r,
                                             Pixel_F alpha, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return interleave(planes, 4, 4, &alpha, dest);
}

/* interleaving with conversion between 8-bit and float */
static vImage_Error interleave_8_to_f(const vImage_Buffer *const *planes, float fill, const vImage_Buffer *dest,
                                      const float *maxF, const float *minF)
{
    for (int c = 0; c < 4; ++c)
        if (planes[c])
            CHECK(fits(dest, planes[c]));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        float *out = (float *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int c = 0; c < 4; ++c)
                out[4 * x + c] = planes[c] ? fmaf((float)SAMPLE(uint8_t, planes[c], y, x), (maxF[c] - minF[c]) / 255.0f, minF[c])
                                           : fill;
    }
    return kvImageNoError;
}

static vImage_Error interleave_f_to_8(const vImage_Buffer *const *planes, uint8_t fill, const vImage_Buffer *dest,
                                      const float *maxF, const float *minF)
{
    for (int c = 0; c < 4; ++c)
        if (planes[c])
            CHECK(fits(dest, planes[c]));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int c = 0; c < 4; ++c)
                out[4 * x + c] = planes[c] ? f_to_8(SAMPLE(float, planes[c], y, x), maxF[c], minF[c]) : fill;
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_Planar8ToXRGBFFFF(Pixel_F alpha, const vImage_Buffer *r, const vImage_Buffer *g,
                                             const vImage_Buffer *b, const vImage_Buffer *dest,
                                             const Pixel_FFFF maxFloat, const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {NULL, r, g, b};
    return interleave_8_to_f(planes, alpha, dest, maxFloat, minFloat);
}
vImage_Error vImageConvert_Planar8ToBGRXFFFF(const vImage_Buffer *b, const vImage_Buffer *g, const vImage_Buffer *r,
                                             Pixel_F alpha, const vImage_Buffer *dest, const Pixel_FFFF maxFloat,
                                             const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return interleave_8_to_f(planes, alpha, dest, maxFloat, minFloat);
}
vImage_Error vImageConvert_PlanarFToXRGB8888(Pixel_8 alpha, const vImage_Buffer *r, const vImage_Buffer *g,
                                             const vImage_Buffer *b, const vImage_Buffer *dest,
                                             const Pixel_FFFF maxFloat, const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {NULL, r, g, b};
    return interleave_f_to_8(planes, alpha, dest, maxFloat, minFloat);
}
vImage_Error vImageConvert_PlanarFToBGRX8888(const vImage_Buffer *b, const vImage_Buffer *g, const vImage_Buffer *r,
                                             Pixel_8 alpha, const vImage_Buffer *dest, const Pixel_FFFF maxFloat,
                                             const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {b, g, r, NULL};
    return interleave_f_to_8(planes, alpha, dest, maxFloat, minFloat);
}

vImage_Error vImageConvert_ARGB8888toPlanarF(const vImage_Buffer *src, const vImage_Buffer *a, const vImage_Buffer *r,
                                             const vImage_Buffer *g, const vImage_Buffer *b,
                                             const Pixel_FFFF maxFloat, const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    for (int c = 0; c < 4; ++c)
        CHECK(same_size(a, planes[c]));
    CHECK(fits(a, src));
    for (vImagePixelCount y = 0; y < a->height; ++y) {
        const uint8_t *in = CROW(src, y);
        for (int c = 0; c < 4; ++c) {
            float *out = (float *)ROW(planes[c], y);
            for (vImagePixelCount x = 0; x < a->width; ++x)
                out[x] = fmaf((float)in[4 * x + c], (maxFloat[c] - minFloat[c]) / 255.0f, minFloat[c]);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_ARGBFFFFtoPlanar8(const vImage_Buffer *src, const vImage_Buffer *a, const vImage_Buffer *r,
                                             const vImage_Buffer *g, const vImage_Buffer *b,
                                             const Pixel_FFFF maxFloat, const Pixel_FFFF minFloat, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    for (int c = 0; c < 4; ++c)
        CHECK(same_size(a, planes[c]));
    CHECK(fits(a, src));
    for (vImagePixelCount y = 0; y < a->height; ++y) {
        const float *in = (const float *)CROW(src, y);
        for (int c = 0; c < 4; ++c) {
            uint8_t *out = ROW(planes[c], y);
            for (vImagePixelCount x = 0; x < a->width; ++x)
                out[x] = f_to_8(in[4 * x + c], maxFloat[c], minFloat[c]);
        }
    }
    return kvImageNoError;
}

/* MARK: - Chunky <-> planar, any channel count */

static vImage_Error chunky(const vImage_Buffer *const *planes, void *const *channels, unsigned count, size_t stride,
                           vImagePixelCount width, vImagePixelCount height, size_t rowBytes, size_t size, int toPlanar)
{
    for (unsigned c = 0; c < count; ++c) {
        if (!planes[c] || !channels[c])
            return kvImageNullPointerArgument;
        if (planes[c]->width < width || planes[c]->height < height)
            return kvImageRoiLargerThanInputBuffer;
    }
    for (vImagePixelCount y = 0; y < height; ++y)
        for (unsigned c = 0; c < count; ++c) {
            uint8_t *ch = (uint8_t *)channels[c] + y * rowBytes;
            uint8_t *pl = ROW(planes[c], y);
            for (vImagePixelCount x = 0; x < width; ++x) {
                if (toPlanar)
                    memcpy(pl + x * size, ch + x * stride, size);
                else
                    memcpy(ch + x * stride, pl + x * size, size);
            }
        }
    return kvImageNoError;
}

vImage_Error vImageConvert_PlanarToChunky8(const vImage_Buffer *srcPlanarBuffers[], void *destChannels[],
                                           unsigned int channelCount, size_t destStrideBytes, vImagePixelCount destWidth,
                                           vImagePixelCount destHeight, size_t destRowBytes, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    return chunky(srcPlanarBuffers, destChannels, channelCount, destStrideBytes, destWidth, destHeight, destRowBytes,
                  1, 0);
}
vImage_Error vImageConvert_PlanarToChunkyF(const vImage_Buffer *srcPlanarBuffers[], void *destChannels[],
                                           unsigned int channelCount, size_t destStrideBytes, vImagePixelCount destWidth,
                                           vImagePixelCount destHeight, size_t destRowBytes, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    return chunky(srcPlanarBuffers, destChannels, channelCount, destStrideBytes, destWidth, destHeight, destRowBytes,
                  4, 0);
}
vImage_Error vImageConvert_ChunkyToPlanar8(const void *srcChannels[], const vImage_Buffer *destPlanarBuffers[],
                                           unsigned int channelCount, size_t srcStrideBytes, vImagePixelCount srcWidth,
                                           vImagePixelCount srcHeight, size_t srcRowBytes, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    return chunky(destPlanarBuffers, (void *const *)srcChannels, channelCount, srcStrideBytes, srcWidth, srcHeight,
                  srcRowBytes, 1, 1);
}
vImage_Error vImageConvert_ChunkyToPlanarF(const void *srcChannels[], const vImage_Buffer *destPlanarBuffers[],
                                           unsigned int channelCount, size_t srcStrideBytes, vImagePixelCount srcWidth,
                                           vImagePixelCount srcHeight, size_t srcRowBytes, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    return chunky(destPlanarBuffers, (void *const *)srcChannels, channelCount, srcStrideBytes, srcWidth, srcHeight,
                  srcRowBytes, 4, 1);
}

/* MARK: - Packed 16-bit formats */

static inline uint8_t up5(uint32_t v) { return (uint8_t)((v * 255 + 15) / 31); }
static inline uint8_t up6(uint32_t v) { return (uint8_t)((v * 255 + 31) / 63); }
static inline uint32_t down5(uint32_t v) { return (v * 31 + 127) / 255; }
static inline uint32_t down6(uint32_t v) { return (v * 63 + 127) / 255; }

vImage_Error vImageConvert_ARGB1555toARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, uint32_t p = in[x]; out[4 * x] = (uint8_t)((p >> 15) * 255);
           out[4 * x + 1] = up5((p >> 10) & 31); out[4 * x + 2] = up5((p >> 5) & 31); out[4 * x + 3] = up5(p & 31));
}
vImage_Error vImageConvert_ARGB8888toARGB1555(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, const uint8_t *p = in + 4 * x;
           out[x] = (uint16_t)((((p[0] + 127u) / 255u) << 15) | (down5(p[1]) << 10) | (down5(p[2]) << 5) |
                               down5(p[3])));
}
vImage_Error vImageConvert_RGBA5551toRGBA8888(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, uint32_t p = in[x]; out[4 * x] = up5(p >> 11); out[4 * x + 1] = up5((p >> 6) & 31);
           out[4 * x + 2] = up5((p >> 1) & 31); out[4 * x + 3] = (uint8_t)((p & 1) * 255));
}
vImage_Error vImageConvert_RGBA8888toRGBA5551(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, const uint8_t *p = in + 4 * x;
           out[x] = (uint16_t)((down5(p[0]) << 11) | (down5(p[1]) << 6) | (down5(p[2]) << 1) |
                               ((p[3] + 127u) / 255u)));
}
vImage_Error vImageConvert_Planar8toARGB1555(const vImage_Buffer *a, const vImage_Buffer *r, const vImage_Buffer *g,
                                             const vImage_Buffer *b, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    for (int c = 0; c < 4; ++c)
        CHECK(fits(dest, planes[c]));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        uint16_t *out = (uint16_t *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            out[x] = (uint16_t)((((SAMPLE(uint8_t, a, y, x) + 127u) / 255u) << 15) |
                                (down5(SAMPLE(uint8_t, r, y, x)) << 10) | (down5(SAMPLE(uint8_t, g, y, x)) << 5) |
                                down5(SAMPLE(uint8_t, b, y, x)));
    }
    return kvImageNoError;
}

static inline void from565(uint32_t p, uint8_t *rgb)
{
    rgb[0] = up5(p >> 11);
    rgb[1] = up6((p >> 5) & 63);
    rgb[2] = up5(p & 31);
}
static inline uint16_t to565(uint32_t r, uint32_t g, uint32_t b)
{
    return (uint16_t)((down5(r) << 11) | (down6(g) << 5) | down5(b));
}

vImage_Error vImageConvert_RGB565toRGBA8888(Pixel_8 alpha, const vImage_Buffer *src, const vImage_Buffer *dest,
                                            vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, from565(in[x], out + 4 * x); out[4 * x + 3] = alpha);
}
vImage_Error vImageConvert_RGB565toBGRA8888(Pixel_8 alpha, const vImage_Buffer *src, const vImage_Buffer *dest,
                                            vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, uint8_t rgb[3]; from565(in[x], rgb); out[4 * x] = rgb[2]; out[4 * x + 1] = rgb[1];
           out[4 * x + 2] = rgb[0]; out[4 * x + 3] = alpha);
}
vImage_Error vImageConvert_RGB565toARGB8888(Pixel_8 alpha, const vImage_Buffer *src, const vImage_Buffer *dest,
                                            vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, from565(in[x], out + 4 * x + 1); out[4 * x] = alpha);
}
vImage_Error vImageConvert_RGB565toRGB888(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t, from565(in[x], out + 3 * x));
}
vImage_Error vImageConvert_ARGB8888toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, out[x] = to565(in[4 * x + 1], in[4 * x + 2], in[4 * x + 3]));
}
vImage_Error vImageConvert_RGBA8888toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, out[x] = to565(in[4 * x], in[4 * x + 1], in[4 * x + 2]));
}
vImage_Error vImageConvert_BGRA8888toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, out[x] = to565(in[4 * x + 2], in[4 * x + 1], in[4 * x]));
}
vImage_Error vImageConvert_RGB888toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t, out[x] = to565(in[3 * x], in[3 * x + 1], in[3 * x + 2]));
}
vImage_Error vImageConvert_RGB565toPlanar8(const vImage_Buffer *src, const vImage_Buffer *r, const vImage_Buffer *g,
                                           const vImage_Buffer *b, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(same_size(r, g));
    CHECK(same_size(r, b));
    CHECK(fits(r, src));
    for (vImagePixelCount y = 0; y < r->height; ++y) {
        const uint16_t *in = (const uint16_t *)CROW(src, y);
        for (vImagePixelCount x = 0; x < r->width; ++x) {
            uint8_t rgb[3];
            from565(in[x], rgb);
            ROW(r, y)[x] = rgb[0];
            ROW(g, y)[x] = rgb[1];
            ROW(b, y)[x] = rgb[2];
        }
    }
    return kvImageNoError;
}
vImage_Error vImageConvert_Planar8toRGB565(const vImage_Buffer *r, const vImage_Buffer *g, const vImage_Buffer *b,
                                           const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, r));
    CHECK(fits(dest, g));
    CHECK(fits(dest, b));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        uint16_t *out = (uint16_t *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            out[x] = to565(SAMPLE(uint8_t, r, y, x), SAMPLE(uint8_t, g, y, x), SAMPLE(uint8_t, b, y, x));
    }
    return kvImageNoError;
}
/* green between 5 and 6 bits goes through 8 bits, as the header's formulas do */
vImage_Error vImageConvert_RGBA5551toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint16_t, uint16_t, uint32_t p = in[x];
           out[x] = (uint16_t)(((p >> 11) << 11) | (down6(up5((p >> 6) & 31)) << 5) | ((p >> 1) & 31)));
}
vImage_Error vImageConvert_ARGB1555toRGB565(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    PIXELS(uint16_t, uint16_t, uint32_t p = in[x];
           out[x] = (uint16_t)((((p >> 10) & 31) << 11) | (down6(up5((p >> 5) & 31)) << 5) | (p & 31)));
}
vImage_Error vImageConvert_RGB565toRGBA5551(const vImage_Buffer *src, const vImage_Buffer *dest, int dither,
                                            vImage_Flags flags)
{
    PIXELS(uint16_t, uint16_t, uint32_t p = in[x];
           out[x] = (uint16_t)(((p >> 11) << 11) | (down5(up6((p >> 5) & 63)) << 6) | ((p & 31) << 1) | 1));
}
vImage_Error vImageConvert_RGB565toARGB1555(const vImage_Buffer *src, const vImage_Buffer *dest, int dither,
                                            vImage_Flags flags)
{
    PIXELS(uint16_t, uint16_t, uint32_t p = in[x];
           out[x] = (uint16_t)(0x8000 | ((p >> 11) << 10) | (down5(up6((p >> 5) & 63)) << 5) | (p & 31)));
}

/* MARK: - Dropping alpha */

#define DROP(name, T, i0, i1, i2)                                                                        \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)           \
    {                                                                                                    \
        PIXELS(T, T, out[3 * x] = in[4 * x + i0]; out[3 * x + 1] = in[4 * x + i1]; out[3 * x + 2] = in[4 * x + i2]); \
    }
DROP(vImageConvert_ARGBFFFFtoRGBFFF, float, 1, 2, 3)
DROP(vImageConvert_RGBAFFFFtoRGBFFF, float, 0, 1, 2)
DROP(vImageConvert_BGRAFFFFtoRGBFFF, float, 2, 1, 0)
DROP(vImageConvert_ARGB8888toRGB888, uint8_t, 1, 2, 3)
DROP(vImageConvert_RGBA8888toRGB888, uint8_t, 0, 1, 2)
DROP(vImageConvert_BGRA8888toRGB888, uint8_t, 2, 1, 0)
DROP(vImageConvert_ARGB16UtoRGB16U, uint16_t, 1, 2, 3)
DROP(vImageConvert_RGBA16UtoRGB16U, uint16_t, 0, 1, 2)
DROP(vImageConvert_BGRA16UtoRGB16U, uint16_t, 2, 1, 0)

/* MARK: - Adding alpha */

#define PREMUL_uint8_t(v, a) (uint8_t)(((uint32_t)(v) * (a) + 127) / 255)
#define PREMUL_uint16_t(v, a) (uint16_t)(((uint32_t)(v) * (a) + 32767) / 65535)
#define PREMUL_float(v, a) ((v) * (a))

/* RGB plus alpha (from aSrc, or the constant) to four channels at ai, ri, gi, bi */
#define ADD_ALPHA(name, T, AT, ai, ri, gi, bi)                                                           \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *aSrc, AT alpha, const vImage_Buffer *dest, \
                      bool premultiply, vImage_Flags flags)                                              \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, src));                                                                          \
        if (aSrc)                                                                                        \
            CHECK(fits(dest, aSrc));                                                                     \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const T *in = (const T *)CROW(src, y);                                                       \
            const T *ain = aSrc ? (const T *)CROW(aSrc, y) : NULL;                                       \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                T a = ain ? ain[x] : (T)alpha, rgb[3] = {in[3 * x], in[3 * x + 1], in[3 * x + 2]};        \
                if (premultiply)                                                                         \
                    for (int c = 0; c < 3; ++c)                                                          \
                        rgb[c] = PREMUL_##T(rgb[c], a);                                                  \
                out[4 * x + ai] = a;                                                                     \
                out[4 * x + ri] = rgb[0];                                                                \
                out[4 * x + gi] = rgb[1];                                                                \
                out[4 * x + bi] = rgb[2];                                                                \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }

ADD_ALPHA(vImageConvert_RGB888toARGB8888, uint8_t, Pixel_8, 0, 1, 2, 3)
ADD_ALPHA(vImageConvert_RGB888toRGBA8888, uint8_t, Pixel_8, 3, 0, 1, 2)
ADD_ALPHA(vImageConvert_RGB888toBGRA8888, uint8_t, Pixel_8, 3, 2, 1, 0)
ADD_ALPHA(vImageConvert_RGBFFFtoARGBFFFF, float, Pixel_F, 0, 1, 2, 3)
ADD_ALPHA(vImageConvert_RGBFFFtoRGBAFFFF, float, Pixel_F, 3, 0, 1, 2)
ADD_ALPHA(vImageConvert_RGBFFFtoBGRAFFFF, float, Pixel_F, 3, 2, 1, 0)
ADD_ALPHA(vImageConvert_RGB16UtoRGBA16U, uint16_t, Pixel_16U, 3, 0, 1, 2)
ADD_ALPHA(vImageConvert_RGB16UtoBGRA16U, uint16_t, Pixel_16U, 3, 2, 1, 0)

/* MARK: - Permutes, overwrites, selects and fills */

#define PERMUTE(name, T, n)                                                                              \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const uint8_t permuteMap[n],  \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        PIXELS(T, T, T p[n]; for (int c = 0; c < (n); ++c) p[c] = in[(n) * x + permuteMap[c]];           \
               for (int c = 0; c < (n); ++c) out[(n) * x + c] = p[c]);                                   \
    }
PERMUTE(vImagePermuteChannels_ARGB8888, uint8_t, 4)
PERMUTE(vImagePermuteChannels_ARGB16U, uint16_t, 4)
PERMUTE(vImagePermuteChannels_ARGBFFFF, float, 4)
PERMUTE(vImagePermuteChannels_ARGB16F, uint16_t, 4)
PERMUTE(vImagePermuteChannels_RGB888, uint8_t, 3)

#define PERMUTE_INSERT(name, T, PT)                                                                      \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const uint8_t permuteMap[4],  \
                      uint8_t copyMask, const PT backgroundColor, vImage_Flags flags)                    \
    {                                                                                                    \
        PIXELS(T, T, T p[4];                                                                             \
               for (int c = 0; c < 4; ++c) p[c] = (copyMask & (8 >> c)) ? backgroundColor[c] : in[4 * x + permuteMap[c]]; \
               for (int c = 0; c < 4; ++c) out[4 * x + c] = p[c]);                                       \
    }
PERMUTE_INSERT(vImagePermuteChannelsWithMaskedInsert_ARGB8888, uint8_t, Pixel_8888)
PERMUTE_INSERT(vImagePermuteChannelsWithMaskedInsert_ARGB16U, uint16_t, Pixel_ARGB_16U)
PERMUTE_INSERT(vImagePermuteChannelsWithMaskedInsert_ARGBFFFF, float, Pixel_FFFF)

/* channels whose copyMask bit is set (0x8 = channel 0) come from newSrc (planar for
   Overwrite, four channels for Select), the rest from origSrc */
#define OVERWRITE(name, T, planar)                                                                       \
    vImage_Error name(const vImage_Buffer *newSrc, const vImage_Buffer *origSrc, const vImage_Buffer *dest, \
                      uint8_t copyMask, vImage_Flags flags)                                              \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, newSrc));                                                                       \
        CHECK(fits(dest, origSrc));                                                                      \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const T *n = (const T *)CROW(newSrc, y), *o = (const T *)CROW(origSrc, y);                   \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x)                                           \
                for (int c = 0; c < 4; ++c)                                                              \
                    out[4 * x + c] = (copyMask & (8 >> c)) ? n[(planar) ? x : 4 * x + c] : o[4 * x + c]; \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }
OVERWRITE(vImageOverwriteChannels_ARGB8888, uint8_t, 1)
OVERWRITE(vImageOverwriteChannels_ARGBFFFF, float, 1)
OVERWRITE(vImageSelectChannels_ARGB8888, uint8_t, 0)
OVERWRITE(vImageSelectChannels_ARGBFFFF, float, 0)

#define OVERWRITE_SCALAR(name, T, ST)                                                                    \
    vImage_Error name(ST scalar, const vImage_Buffer *src, const vImage_Buffer *dest, uint8_t copyMask,  \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        PIXELS(T, T, for (int c = 0; c < 4; ++c) out[4 * x + c] = (copyMask & (8 >> c)) ? scalar : in[4 * x + c]); \
    }
OVERWRITE_SCALAR(vImageOverwriteChannelsWithScalar_ARGB8888, uint8_t, Pixel_8)
OVERWRITE_SCALAR(vImageOverwriteChannelsWithScalar_ARGBFFFF, float, Pixel_F)

#define OVERWRITE_PIXEL(name, T, PT)                                                                     \
    vImage_Error name(const PT the_pixel, const vImage_Buffer *src, const vImage_Buffer *dest, uint8_t copyMask, \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        PIXELS(T, T, for (int c = 0; c < 4; ++c) out[4 * x + c] = (copyMask & (8 >> c)) ? the_pixel[c] : in[4 * x + c]); \
    }
OVERWRITE_PIXEL(vImageOverwriteChannelsWithPixel_ARGB8888, uint8_t, Pixel_8888)
OVERWRITE_PIXEL(vImageOverwriteChannelsWithPixel_ARGB16U, uint16_t, Pixel_ARGB_16U)
OVERWRITE_PIXEL(vImageOverwriteChannelsWithPixel_ARGBFFFF, float, Pixel_FFFF)

#define FILL_PLANAR(name, T, VT)                                                                         \
    vImage_Error name(VT value, const vImage_Buffer *dest, vImage_Flags flags)                           \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        if (!dest || !dest->data)                                                                        \
            return kvImageNullPointerArgument;                                                           \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x)                                           \
                out[x] = value;                                                                          \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }
FILL_PLANAR(vImageOverwriteChannelsWithScalar_Planar8, uint8_t, Pixel_8)
FILL_PLANAR(vImageOverwriteChannelsWithScalar_PlanarF, float, Pixel_F)
FILL_PLANAR(vImageOverwriteChannelsWithScalar_Planar16S, int16_t, Pixel_16S)
FILL_PLANAR(vImageOverwriteChannelsWithScalar_Planar16U, uint16_t, Pixel_16U)
FILL_PLANAR(vImageOverwriteChannelsWithScalar_Planar16F, uint16_t, Pixel_16F)

#define BUFFER_FILL(name, T, n, VT)                                                                      \
    vImage_Error name(const vImage_Buffer *dest, const VT color, vImage_Flags flags)                     \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        if (!dest || !dest->data || !color)                                                              \
            return kvImageNullPointerArgument;                                                           \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x)                                           \
                for (int c = 0; c < (n); ++c)                                                            \
                    out[(n) * x + c] = color[c];                                                         \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }
BUFFER_FILL(vImageBufferFill_ARGB8888, uint8_t, 4, Pixel_8888)
BUFFER_FILL(vImageBufferFill_ARGB16U, uint16_t, 4, Pixel_ARGB_16U)
BUFFER_FILL(vImageBufferFill_ARGB16S, int16_t, 4, Pixel_ARGB_16S)
BUFFER_FILL(vImageBufferFill_ARGBFFFF, float, 4, Pixel_FFFF)
BUFFER_FILL(vImageBufferFill_ARGB16F, uint16_t, 4, Pixel_ARGB_16F)
BUFFER_FILL(vImageBufferFill_CbCr8, uint8_t, 2, Pixel_88)
BUFFER_FILL(vImageBufferFill_CbCr16U, uint16_t, 2, Pixel_16U16U)
BUFFER_FILL(vImageBufferFill_CbCr16S, int16_t, 2, Pixel_16S16S)

#define EXTRACT(name, T)                                                                                 \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, long channelIndex, vImage_Flags flags) \
    {                                                                                                    \
        if (channelIndex < 0 || channelIndex > 3)                                                        \
            return kvImageInvalidParameter;                                                              \
        PIXELS(T, T, out[x] = in[4 * x + channelIndex]);                                                 \
    }
EXTRACT(vImageExtractChannel_ARGB8888, uint8_t)
EXTRACT(vImageExtractChannel_ARGB16U, uint16_t)
EXTRACT(vImageExtractChannel_ARGBFFFF, float)

vImage_Error vImageTableLookUp_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                        const Pixel_8 alphaTable[256], const Pixel_8 redTable[256],
                                        const Pixel_8 greenTable[256], const Pixel_8 blueTable[256], vImage_Flags flags)
{
    const Pixel_8 *tables[4] = {alphaTable, redTable, greenTable, blueTable};
    PIXELS(uint8_t, uint8_t,
           for (int c = 0; c < 4; ++c) out[4 * x + c] = tables[c] ? tables[c][in[4 * x + c]] : in[4 * x + c]);
}

vImage_Error vImageCopyBuffer(const vImage_Buffer *src, const vImage_Buffer *dest, size_t pixelSize, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        memmove(ROW(dest, y), CROW(src, y), dest->width * pixelSize);
    return kvImageNoError;
}

/* MARK: - 8-bit and 16-bit ARGB with permutes and backgrounds */

vImage_Error vImageConvert_ARGB16UToARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                             const uint8_t permuteMap[4], uint8_t copyMask,
                                             const Pixel_8888 backgroundColor, vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t,
           for (int c = 0; c < 4; ++c) out[4 * x + c] =
               (copyMask & (8 >> c)) ? backgroundColor[c]
                                     : (uint8_t)((in[4 * x + permuteMap[c]] * 255U + 32767U) / 65535U));
}
vImage_Error vImageConvert_ARGB8888ToARGB16U(const vImage_Buffer *src, const vImage_Buffer *dest,
                                             const uint8_t permuteMap[4], uint8_t copyMask,
                                             const Pixel_ARGB_16U backgroundColor, vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t,
           for (int c = 0; c < 4; ++c) out[4 * x + c] =
               (copyMask & (8 >> c)) ? backgroundColor[c]
                                     : (uint16_t)((in[4 * x + permuteMap[c]] * 65535U + 127U) / 255U));
}
vImage_Error vImageConvert_RGB16UToARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                            const uint8_t permuteMap[4], uint8_t copyMask,
                                            const Pixel_8888 backgroundColor, vImage_Flags flags)
{
    PIXELS(uint16_t, uint8_t,
           uint8_t v[4] = {255, (uint8_t)((in[3 * x] * 255U + 32767U) / 65535U),
                           (uint8_t)((in[3 * x + 1] * 255U + 32767U) / 65535U),
                           (uint8_t)((in[3 * x + 2] * 255U + 32767U) / 65535U)};
           for (int c = 0; c < 4; ++c) out[4 * x + c] = (copyMask & (8 >> c)) ? backgroundColor[c] : v[permuteMap[c]]);
}
vImage_Error vImageConvert_ARGB8888ToRGB16U(const vImage_Buffer *src, const vImage_Buffer *dest,
                                            const uint8_t permuteMap[3], uint8_t copyMask,
                                            const Pixel_16U backgroundColor[3], vImage_Flags flags)
{
    PIXELS(uint8_t, uint16_t,
           for (int c = 0; c < 3; ++c) out[3 * x + c] =
               (copyMask & (4 >> c)) ? backgroundColor[c]
                                     : (uint16_t)((in[4 * x + permuteMap[c]] * 65535U + 127U) / 255U));
}

/* MARK: - Flattening against a background */

/* the result's channels, in source order, keeping n of them in the order given by map;
   the three-channel forms clamp premultiplied colours to alpha first, as Apple's do */
#define FLATTEN(name, T, n, ai, PT, MAXV, ROUND, ...)                                                    \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const PT background,          \
                      bool premultiplied, vImage_Flags flags)                                            \
    {                                                                                                    \
        static const int map[] = {__VA_ARGS__};                                                          \
        PIXELS(T, T, const T *p = in + 4 * x; long a = p[ai], r[4];                                      \
               for (int c = 0; c < 4; ++c) {                                                             \
                   long v = (n) == 3 && premultiplied && p[c] > a ? a : p[c], bg = background[c];        \
                   r[c] = c == (ai) ? (a * (MAXV) + ((MAXV) - a) * bg + (ROUND)) / (MAXV)                \
                                    : ((premultiplied ? v * (MAXV) : v * a) + ((MAXV) - a) * bg + (ROUND)) / (MAXV); \
               } for (int k = 0; k < (n); ++k) out[(n) * x + k] = (T)(r[map[k]] > (MAXV) ? (MAXV) : r[map[k]])); \
    }

FLATTEN(vImageFlatten_ARGB8888, uint8_t, 4, 0, Pixel_8888, 255, 127, 0, 1, 2, 3)
FLATTEN(vImageFlatten_RGBA8888, uint8_t, 4, 3, Pixel_8888, 255, 127, 0, 1, 2, 3)
FLATTEN(vImageFlatten_ARGB16U, uint16_t, 4, 0, Pixel_ARGB_16U, 65535, 32767, 0, 1, 2, 3)
FLATTEN(vImageFlatten_RGBA16U, uint16_t, 4, 3, Pixel_ARGB_16U, 65535, 32767, 0, 1, 2, 3)
FLATTEN(vImageFlatten_RGBA8888ToRGB888, uint8_t, 3, 3, Pixel_8888, 255, 127, 0, 1, 2)
FLATTEN(vImageFlatten_BGRA8888ToRGB888, uint8_t, 3, 3, Pixel_8888, 255, 127, 2, 1, 0)

/* 16Q12: 4096 is 1.0 */
#define FLATTEN_Q12(name, ai)                                                                            \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const Pixel_ARGB_16S background, \
                      bool premultiplied, vImage_Flags flags)                                            \
    {                                                                                                    \
        PIXELS(int16_t, int16_t, const int16_t *p = in + 4 * x; long a = p[ai] < 0 ? 0 : p[ai] > 4096 ? 4096 : p[ai]; \
               for (int c = 0; c < 4; ++c) {                                                             \
                   long bg = background[c], v = p[c];                                                    \
                   long r = c == (ai) ? (a * 4096 + (4096 - a) * bg + 2048) >> 12                        \
                                      : ((premultiplied ? v * 4096 : v * a) + (4096 - a) * bg + 2048) >> 12; \
                   out[4 * x + c] = sat16s(r);                                                           \
               });                                                                                       \
    }
FLATTEN_Q12(vImageFlatten_ARGB16Q12, 0)
FLATTEN_Q12(vImageFlatten_RGBA16Q12, 3)

#define FLATTEN_F(name, n, ai, ...)                                                                      \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const Pixel_FFFF background,  \
                      bool premultiplied, vImage_Flags flags)                                            \
    {                                                                                                    \
        static const int map[] = {__VA_ARGS__};                                                          \
        PIXELS(float, float, const float *p = in + 4 * x; float a = p[ai], r[4];                         \
               for (int c = 0; c < 4; ++c) r[c] = c == (ai) ? a + (1 - a) * background[c]                \
                                                            : (premultiplied ? ((n) == 3 ? fminf(p[c], a) : p[c]) : p[c] * a) + (1 - a) * background[c]; \
               for (int k = 0; k < (n); ++k) out[(n) * x + k] = r[map[k]]);                              \
    }
FLATTEN_F(vImageFlatten_ARGBFFFF, 4, 0, 0, 1, 2, 3)
FLATTEN_F(vImageFlatten_RGBAFFFF, 4, 3, 0, 1, 2, 3)
FLATTEN_F(vImageFlatten_ARGBFFFFToRGBFFF, 3, 0, 1, 2, 3)
FLATTEN_F(vImageFlatten_RGBAFFFFToRGBFFF, 3, 3, 0, 1, 2)
FLATTEN_F(vImageFlatten_BGRAFFFFToRGBFFF, 3, 3, 2, 1, 0)

/* MARK: - 16Q12 interleaving */

static vImage_Error q12_planes_from(const vImage_Buffer *src, const vImage_Buffer *const *planes, int n, int stride)
{
    for (int c = 0; c < n; ++c)
        CHECK(same_size(planes[0], planes[c]));
    CHECK(fits(planes[0], src));
    for (vImagePixelCount y = 0; y < planes[0]->height; ++y) {
        const uint8_t *in = CROW(src, y);
        for (int c = 0; c < n; ++c) {
            int16_t *out = (int16_t *)ROW(planes[c], y);
            for (vImagePixelCount x = 0; x < planes[0]->width; ++x)
                out[x] = (int16_t)((in[stride * x + c] * 4096U + 127U) / 255U);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_RGB888toPlanar16Q12(const vImage_Buffer *src, const vImage_Buffer *r, const vImage_Buffer *g,
                                               const vImage_Buffer *b, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[3] = {r, g, b};
    return q12_planes_from(src, planes, 3, 3);
}
vImage_Error vImageConvert_ARGB8888toPlanar16Q12(const vImage_Buffer *src, const vImage_Buffer *a,
                                                 const vImage_Buffer *r, const vImage_Buffer *g, const vImage_Buffer *b,
                                                 vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    return q12_planes_from(src, planes, 4, 4);
}

static uint8_t q12_8(int16_t v) { return (uint8_t)(((uint32_t)(v < 0 ? 0 : v > 4096 ? 4096 : v) * 255 + 2048) >> 12); }

static vImage_Error q12_interleave(const vImage_Buffer *const *planes, int n, const vImage_Buffer *dest, int half)
{
    for (int c = 0; c < n; ++c)
        CHECK(fits(dest, planes[c]));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int c = 0; c < n; ++c) {
                int16_t v = SAMPLE(int16_t, planes[c], y, x);
                if (half)
                    ((uint16_t *)ROW(dest, y))[n * x + c] = float_to_half((float)v / 4096.0f);
                else
                    ROW(dest, y)[n * x + c] = q12_8(v);
            }
    return kvImageNoError;
}

vImage_Error vImageConvert_Planar16Q12toRGB888(const vImage_Buffer *r, const vImage_Buffer *g, const vImage_Buffer *b,
                                               const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[3] = {r, g, b};
    return q12_interleave(planes, 3, dest, 0);
}
vImage_Error vImageConvert_Planar16Q12toARGB8888(const vImage_Buffer *a, const vImage_Buffer *r,
                                                 const vImage_Buffer *g, const vImage_Buffer *b,
                                                 const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    return q12_interleave(planes, 4, dest, 0);
}
vImage_Error vImageConvert_Planar16Q12toRGB16F(const vImage_Buffer *r, const vImage_Buffer *g, const vImage_Buffer *b,
                                               const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[3] = {r, g, b};
    return q12_interleave(planes, 3, dest, 1);
}
vImage_Error vImageConvert_Planar16Q12toARGB16F(const vImage_Buffer *a, const vImage_Buffer *r,
                                                const vImage_Buffer *g, const vImage_Buffer *b,
                                                const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *planes[4] = {a, r, g, b};
    return q12_interleave(planes, 4, dest, 1);
}

/* MARK: - 1, 2 and 4 bits per pixel (big-endian within each byte) */

static vImage_Error unpack_bits(const vImage_Buffer *src, const vImage_Buffer *dest, int bits, const uint8_t *colors,
                                vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    int per = 8 / bits, mask = (1 << bits) - 1, scale = 255 / mask;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            int v = (in[x / (unsigned)per] >> ((per - 1 - (int)(x % (unsigned)per)) * bits)) & mask;
            out[x] = colors ? colors[v] : (uint8_t)(v * scale);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_Planar1toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_Flags flags)
{
    return unpack_bits(src, dest, 1, NULL, flags);
}
vImage_Error vImageConvert_Planar2toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_Flags flags)
{
    return unpack_bits(src, dest, 2, NULL, flags);
}
vImage_Error vImageConvert_Planar4toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_Flags flags)
{
    return unpack_bits(src, dest, 4, NULL, flags);
}
vImage_Error vImageConvert_Indexed1toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                             const Pixel_8 colors[2], const vImage_Flags flags)
{
    return unpack_bits(src, dest, 1, colors, flags);
}
vImage_Error vImageConvert_Indexed2toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                             const Pixel_8 colors[4], const vImage_Flags flags)
{
    return unpack_bits(src, dest, 2, colors, flags);
}
vImage_Error vImageConvert_Indexed4toPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                             const Pixel_8 colors[16], const vImage_Flags flags)
{
    return unpack_bits(src, dest, 4, colors, flags);
}

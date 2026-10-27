/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's format conversions (Conversion.h): between 8-bit, 16-bit, half and float
 * samples, packed 16-bit formats, channel orders and counts, 16Q12 fixed point and
 * sub-byte planar and indexed formats; channel permutes, overwrites and fills; and
 * flattening against a background. The arithmetic is the header's, formula for formula.
 */
#include "common.h"

/* MARK: - One sample to one sample */

/* dest[x] = EXPR(v), v the source sample, over width samples (the planar functions also
   serve interleaved data with the width multiplied by the channel count) */
#define MAP(name, ST, DT, EXPR, ...)                                                                     \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, __VA_ARGS__ vImage_Flags flags) \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, src));                                                                          \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const ST *in = (const ST *)CROW(src, y);                                                     \
            DT *out = (DT *)ROW(dest, y);                                                                \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                ST v = in[x];                                                                            \
                out[x] = (DT)(EXPR);                                                                     \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }

static inline uint8_t half_8(uint16_t h)
{
    float f = half_to_float(h) * 255.0f;
    if (!(f > 0))
        return 0;
    return f >= 255 ? 255 : (uint8_t)rintf(f);
}

static inline uint16_t half_16u(uint16_t h)
{
    float f = half_to_float(h) * 65535.0f;
    if (!(f > 0))
        return 0;
    return f >= 65535 ? 65535 : (uint16_t)rintf(f);
}

MAP(vImageConvert_Planar8toPlanarF, uint8_t, float, fmaf((float)v, (maxFloat - minFloat) / 255.0f, minFloat),
    Pixel_F maxFloat, Pixel_F minFloat, )
MAP(vImageConvert_PlanarFtoPlanar8, float, uint8_t, f_to_8(v, maxFloat, minFloat), Pixel_F maxFloat,
    Pixel_F minFloat, )
MAP(vImageClip_PlanarF, float, float, v > maxFloat ? maxFloat : v < minFloat ? minFloat : v, Pixel_F maxFloat,
    Pixel_F minFloat, )
MAP(vImageConvert_16SToF, int16_t, float, fmaf((float)v, scale, offset), float offset, float scale, )
MAP(vImageConvert_16UToF, uint16_t, float, fmaf((float)v, scale, offset), float offset, float scale, )
MAP(vImageConvert_FTo16S, float, int16_t, sat16s(lrintf(floorf((v - offset) / scale + 0.5f))), float offset,
    float scale, )
MAP(vImageConvert_FTo16U, float, uint16_t, sat16u(lrintf(floorf((v - offset) / scale + 0.5f))), float offset,
    float scale, )
MAP(vImageConvert_16Uto16F, uint16_t, uint16_t, float_to_half((float)v / 65535.0f))
MAP(vImageConvert_16Fto16U, uint16_t, uint16_t, half_16u(v))
MAP(vImageConvert_Planar16FtoPlanarF, uint16_t, float, half_to_float(v))
MAP(vImageConvert_PlanarFtoPlanar16F, float, uint16_t, float_to_half(v))
MAP(vImageConvert_Planar8toPlanar16F, uint8_t, uint16_t, float_to_half((float)v / 255.0f))
MAP(vImageConvert_Planar16FtoPlanar8, uint16_t, uint8_t, half_8(v))
MAP(vImageConvert_16UToPlanar8, uint16_t, uint8_t, ((uint32_t)v * 255 + 32767) / 65535)
MAP(vImageConvert_Planar8To16U, uint8_t, uint16_t, ((uint32_t)v * 65535 + 127) / 255)
MAP(vImageConvert_8to16Q12, uint8_t, int16_t, ((uint32_t)v * 4096 + 127) / 255)
MAP(vImageConvert_16Q12to8, int16_t, uint8_t, ((uint32_t)(v < 0 ? 0 : v > 4096 ? 4096 : v) * 255 + 2048) >> 12)
MAP(vImageConvert_16Q12toF, int16_t, float, (float)v / 4096.0f)
MAP(vImageConvert_Fto16Q12, float, int16_t, sat16s(lrintf(v * 4096.0f)))
MAP(vImageConvert_16Q12to16U, int16_t, uint16_t, sat16u(((long)v * 65535 + 2048) >> 12))
MAP(vImageConvert_16Uto16Q12, uint16_t, int16_t, ((uint32_t)v * 4096 + 32767) / 65535)
MAP(vImageConvert_16Q12to16F, int16_t, uint16_t, float_to_half((float)v / 4096.0f))
MAP(vImageConvert_16Fto16Q12, uint16_t, int16_t, sat16s(lrintf(half_to_float(v) * 4096.0f)))
MAP(vImageByteSwap_Planar16U, uint16_t, uint16_t, (uint16_t)((v >> 8) | (v << 8)))
MAP(vImageTableLookUp_Planar8, uint8_t, uint8_t, table[v], const Pixel_8 table[256], )

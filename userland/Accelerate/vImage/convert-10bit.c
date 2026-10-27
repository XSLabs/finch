/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's 10-bit RGB conversions (Conversion.h): RGBA1010102 (big-endian, alpha in the
 * low 2 bits), XRGB2101010 and ARGB2101010 (alpha in the top 2 bits) to and from
 * ARGB8888, ARGB16U, ARGB16Q12, ARGBFFFF and ARGB16F, with the header's formulas: a
 * video or full range [RangeMin, RangeMax] for the 10-bit samples, and a permutation of
 * the 4-channel side.
 */
#include "common.h"

/* MARK: - Packing */

enum Layout { RGBA1010102, XRGB2101010, ARGB2101010 };

static inline uint32_t load(const uint8_t *row, vImagePixelCount x, enum Layout l)
{
    uint32_t p;
    memcpy(&p, row + 4 * x, 4);
    return l == RGBA1010102 ? __builtin_bswap32(p) : p;
}

static inline void unpack(uint32_t p, enum Layout l, int32_t rgb[3], int32_t *a2)
{
    int shift = l == RGBA1010102 ? 2 : 0;
    rgb[0] = (int32_t)(p >> (20 + shift)) & 0x3ff;
    rgb[1] = (int32_t)(p >> (10 + shift)) & 0x3ff;
    rgb[2] = (int32_t)(p >> shift) & 0x3ff;
    *a2 = l == RGBA1010102 ? (int32_t)(p & 3) : (int32_t)(p >> 30);
}

static inline void store(uint8_t *row, vImagePixelCount x, enum Layout l, const int32_t rgb[3], int32_t a2)
{
    uint32_t p;
    if (l == RGBA1010102)
        p = __builtin_bswap32((uint32_t)(rgb[0] & 0x3ff) << 22 | (uint32_t)(rgb[1] & 0x3ff) << 12 |
                              (uint32_t)(rgb[2] & 0x3ff) << 2 | (uint32_t)(a2 & 3));
    else
        p = (l == ARGB2101010 ? (uint32_t)(a2 & 3) << 30 : 0) | (uint32_t)(rgb[0] & 0x3ff) << 20 |
            (uint32_t)(rgb[1] & 0x3ff) << 10 | (uint32_t)(rgb[2] & 0x3ff);
    memcpy(row + 4 * x, &p, 4);
}

static const uint8_t identity[4] = {0, 1, 2, 3};

static inline vImage_Error check(const vImage_Buffer *src, const vImage_Buffer *dest, int32_t min, int32_t max,
                                 vImage_Flags flags)
{
    if (flags & ~(vImage_Flags)(kvImageDoNotTile | kvImageDoNotClamp | kvImageGetTempBufferSize |
                                kvImagePrintDiagnosticsToConsole))
        return kvImageUnknownFlagsBit;
    CHECK(fits(dest, src));
    return min > max || max > 1023 ? kvImageInvalidParameter : kvImageNoError;
}

/* MARK: - From 10 bits */

enum Target { T8, T16U, TQ12, TF, T16F };

/* one channel of 10-bit sample s in [min, max], as Apple computes it: its vector loops
   (groups of 8 pixels) work in fixed point, (s - min) times round(scale 2^15 / range),
   rounded; the scalar tail follows the header's formulas for RGBA1010102 and, for the
   other layouts, rounds (s - min) (scale / range) in single precision for 8 bits and
   16Q12. 16Q12 results wrap rather than saturate. Floats are (s - min) (1 / range),
   with s clamped to the range first unless kvImageDoNotClamp. */
enum Path { VECTOR, HEADER, FLOAT };

static inline int32_t scaled(enum Path path, int32_t x, int32_t range, int32_t scale)
{
    switch (path) {
    case VECTOR:
        return (int32_t)(((int64_t)x * llround((double)scale * 32768.0 / range) + (1 << 14)) >> 15);
    case HEADER:
        return (x * scale + (range >> 1)) / range;
    default:
        return (int32_t)floorf((float)x * ((float)scale / (float)range) + 0.5f);
    }
}

static inline float widen(enum Target t, int32_t s, int32_t min, int32_t range, enum Path path, vImage_Flags flags)
{
    switch (t) {
    case T8: {
        int32_t v = scaled(path, s - min, range, 255);
        return v < 0 ? 0 : v > 255 ? 255 : v;
    }
    case T16U: {
        int32_t v = scaled(path == FLOAT ? HEADER : path, s - min, range, 65535);
        return v < 0 ? 0 : v > 65535 ? 65535 : v;
    }
    case TQ12:
        return (int16_t)scaled(path, s - min, range, 4096);
    default: {
        int32_t x = s - min;
        if (!(flags & kvImageDoNotClamp))
            x = x < 0 ? 0 : x > range ? range : x;
        return (float)x * (1.0f / (float)range);
    }
    }
}

/* (Apple's vector loops' 16Q12 alpha from ARGB2101010 in the standard video range, 64
   to 940, is 4095 a2 / 3, not the header's (4096 a2 + 1) / 3) */
static inline float widen_alpha(enum Target t, bool video, int32_t a2)
{
    switch (t) {
    case T8:
        return (a2 * 255 + 1) / 3;
    case T16U:
        return (a2 * 65535 + 1) / 3;
    case TQ12:
        return video ? a2 * 1365 : (a2 * 4096 + 1) / 3;
    default:
        return (float)a2 / 3.0f;
    }
}

static vImage_Error from10(const vImage_Buffer *src, const vImage_Buffer *dest, enum Layout l, enum Target t,
                           float alpha, int32_t min, int32_t max, const uint8_t permuteMap[4], vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(check(src, dest, min, max, flags));
    const uint8_t *perm = permuteMap ? permuteMap : identity;
    int32_t range = max - min;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            int32_t rgb[3], a2;
            unpack(load(in, x, l), l, rgb, &a2);
            enum Path path = x < (dest->width & ~(vImagePixelCount)7) ? VECTOR : l == RGBA1010102 ? HEADER : FLOAT;
            float argb[4] = {l == XRGB2101010 ? alpha : widen_alpha(t, l == ARGB2101010 && min == 64 && max == 940 && path == VECTOR, a2), widen(t, rgb[0], min, range, path, flags),
                             widen(t, rgb[1], min, range, path, flags), widen(t, rgb[2], min, range, path, flags)};
            for (int c = 0; c < 4; ++c) {
                float v = argb[perm[c]];
                switch (t) {
                case T8:
                    out[4 * x + c] = (uint8_t)v;
                    break;
                case T16U:
                    ((uint16_t *)out)[4 * x + c] = (uint16_t)v;
                    break;
                case TQ12:
                    ((int16_t *)out)[4 * x + c] = (int16_t)v;
                    break;
                case TF:
                    ((float *)out)[4 * x + c] = v;
                    break;
                default:
                    ((uint16_t *)out)[4 * x + c] = float_to_half(v);
                    break;
                }
            }
        }
    }
    return kvImageNoError;
}

/* MARK: - To 10 bits */

enum Source { S8, S16U, SQ12, SF };

static vImage_Error to10(const vImage_Buffer *src, const vImage_Buffer *dest, enum Layout l, enum Source s,
                         int32_t min, int32_t max, int32_t clipMin, int32_t clipMax, const uint8_t permuteMap[4],
                         vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(check(src, dest, min, max, flags));
    if (clipMin > clipMax)
        return kvImageInvalidParameter;
    const uint8_t *perm = permuteMap ? permuteMap : identity;
    int32_t range = max - min;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            int32_t rgb[3], a2;
            switch (s) {
            case S8: {
                const uint8_t *p = in + 4 * x;
                for (int c = 0; c < 3; ++c)
                    rgb[c] = (p[perm[c + 1]] * range + 127) / 255 + min;
                a2 = (p[perm[0]] * 3 + 127) / 255;
                break;
            }
            case S16U: {
                const uint16_t *p = (const uint16_t *)in + 4 * x;
                for (int c = 0; c < 3; ++c)
                    rgb[c] = (int32_t)(((int64_t)p[perm[c + 1]] * range + 32767) / 65535) + min;
                a2 = (p[perm[0]] * 3 + 32767) / 65535;
                break;
            }
            case SQ12: {
                const int16_t *p = (const int16_t *)in + 4 * x;
                for (int c = 0; c < 3; ++c) {
                    int32_t v = ((p[perm[c + 1]] * range + 2048) >> 12) + min;
                    rgb[c] = v < clipMin ? clipMin : v > clipMax ? clipMax : v;
                }
                a2 = (p[perm[0]] * 3 + 2048) >> 12;
                a2 = a2 < 0 ? 0 : a2 > 3 ? 3 : a2;
                break;
            }
            default: {
                /* (rounded to nearest even; out of range samples saturate) */
                const float *p = (const float *)in + 4 * x;
                for (int c = 0; c < 3; ++c) {
                    float v = p[perm[c + 1]];
                    if (!(flags & kvImageDoNotClamp))
                        v = v < 0 ? 0 : v > 1 ? 1 : v;
                    long q = lrintf(v * (float)range) + min;
                    rgb[c] = q < 0 ? 0 : q > 1023 ? 1023 : (int32_t)q;
                }
                long q = lrintf(p[perm[0]] * 3.0f);
                a2 = q < 0 ? 0 : q > 3 ? 3 : (int32_t)q;
                break;
            }
            }
            store(out, x, l, rgb, a2);
        }
    }
    return kvImageNoError;
}

/* MARK: - Entry points */

#define FROM10(layout, Layout, target, Target, ...)                                                   \
    vImage_Error vImageConvert_##layout##To##target(const vImage_Buffer *src, __VA_ARGS__ const vImage_Buffer *dest, \
                                                    int32_t RGB101010RangeMin, int32_t RGB101010RangeMax, \
                                                    const uint8_t permuteMap[4], vImage_Flags flags)    \
    {                                                                                                    \
        return from10(src, dest, Layout, Target, ALPHA, RGB101010RangeMin, RGB101010RangeMax, permuteMap, flags); \
    }

#define ALPHA 0
FROM10(RGBA1010102, RGBA1010102, ARGB8888, T8, )
FROM10(RGBA1010102, RGBA1010102, ARGB16U, T16U, )
FROM10(RGBA1010102, RGBA1010102, ARGB16Q12, TQ12, )
FROM10(ARGB2101010, ARGB2101010, ARGB8888, T8, )
FROM10(ARGB2101010, ARGB2101010, ARGB16U, T16U, )
FROM10(ARGB2101010, ARGB2101010, ARGB16Q12, TQ12, )
FROM10(ARGB2101010, ARGB2101010, ARGBFFFF, TF, )
FROM10(ARGB2101010, ARGB2101010, ARGB16F, T16F, )
#undef ALPHA
#define ALPHA alpha
FROM10(XRGB2101010, XRGB2101010, ARGB8888, T8, Pixel_8 alpha, )
FROM10(XRGB2101010, XRGB2101010, ARGB16U, T16U, uint16_t alpha, )
FROM10(XRGB2101010, XRGB2101010, ARGB16Q12, TQ12, Pixel_16Q12 alpha, )
FROM10(XRGB2101010, XRGB2101010, ARGBFFFF, TF, Pixel_F alpha, )
FROM10(XRGB2101010, XRGB2101010, ARGB16F, T16F, Pixel_F alpha, )
#undef ALPHA

#define TO10(source, Source, layout, Layout)                                                             \
    vImage_Error vImageConvert_##source##To##layout(const vImage_Buffer *src, const vImage_Buffer *dest, \
                                                    int32_t RGB101010RangeMin, int32_t RGB101010RangeMax, \
                                                    const uint8_t permuteMap[4], vImage_Flags flags)    \
    {                                                                                                    \
        return to10(src, dest, Layout, Source, RGB101010RangeMin, RGB101010RangeMax, INT32_MIN, INT32_MAX, \
                    permuteMap, flags);                                                                  \
    }
#define TO10_CLIPPED(source, Source, layout, Layout)                                                     \
    vImage_Error vImageConvert_##source##To##layout(const vImage_Buffer *src, const vImage_Buffer *dest, \
                                                    int32_t RGB101010RangeMin, int32_t RGB101010RangeMax, \
                                                    int32_t RGB101010Min, int32_t RGB101010Max,         \
                                                    const uint8_t permuteMap[4], vImage_Flags flags)    \
    {                                                                                                    \
        return to10(src, dest, Layout, Source, RGB101010RangeMin, RGB101010RangeMax, RGB101010Min, RGB101010Max, \
                    permuteMap, flags);                                                                  \
    }

TO10(ARGB8888, S8, RGBA1010102, RGBA1010102)
TO10(ARGB16U, S16U, RGBA1010102, RGBA1010102)
TO10_CLIPPED(ARGB16Q12, SQ12, RGBA1010102, RGBA1010102)
TO10(ARGB8888, S8, XRGB2101010, XRGB2101010)
TO10(ARGB16U, S16U, XRGB2101010, XRGB2101010)
TO10_CLIPPED(ARGB16Q12, SQ12, XRGB2101010, XRGB2101010)
TO10(ARGBFFFF, SF, XRGB2101010, XRGB2101010)
TO10(ARGB8888, S8, ARGB2101010, ARGB2101010)
TO10(ARGB16U, S16U, ARGB2101010, ARGB2101010)
TO10_CLIPPED(ARGB16Q12, SQ12, ARGB2101010, ARGB2101010)
TO10(ARGBFFFF, SF, ARGB2101010, ARGB2101010)

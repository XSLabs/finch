/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Shared by Finch's vImage: row access, argument checks and the small numeric helpers
 * the filters use.
 */
#ifndef FINCH_VIMAGE_COMMON_H
#define FINCH_VIMAGE_COMMON_H

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Apple's formulas round each operation (no fused multiply-adds unless written as fmaf) */
#pragma STDC FP_CONTRACT OFF

#define ROW(buf, y) ((uint8_t *)(buf)->data + (size_t)(y) * (buf)->rowBytes)
#define CROW(buf, y) ((const uint8_t *)(buf)->data + (size_t)(y) * (buf)->rowBytes)

/* the start of every filter: a temp-buffer-size query does no work */
#define TEMP_QUERY(flags)                                                                                \
    do {                                                                                                 \
        if ((flags) & kvImageGetTempBufferSize)                                                          \
            return 0;                                                                                    \
    } while (0)

/* dest must fit in each source */
static inline vImage_Error fits(const vImage_Buffer *dest, const vImage_Buffer *src)
{
    if (!dest || !src || !dest->data || !src->data)
        return kvImageNullPointerArgument;
    if (src->height < dest->height || src->width < dest->width)
        return kvImageRoiLargerThanInputBuffer;
    return kvImageNoError;
}

/* buffers that must have dest's size exactly (planar sets) */
static inline vImage_Error same_size(const vImage_Buffer *a, const vImage_Buffer *b)
{
    if (!a || !b || !a->data || !b->data)
        return kvImageNullPointerArgument;
    if (a->height != b->height || a->width != b->width)
        return kvImageBufferSizeMismatch;
    return kvImageNoError;
}

#define CHECK(expr)                                                                                      \
    do {                                                                                                 \
        vImage_Error check_ = (expr);                                                                    \
        if (check_ != kvImageNoError)                                                                    \
            return check_;                                                                               \
    } while (0)

static inline uint8_t sat8(long v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }
static inline uint16_t sat16u(long v) { return v < 0 ? 0 : v > 65535 ? 65535 : (uint16_t)v; }
static inline int16_t sat16s(long v) { return v < -32768 ? -32768 : v > 32767 ? 32767 : (int16_t)v; }

/* half precision */
static inline float half_to_float(uint16_t h)
{
    _Float16 f;
    memcpy(&f, &h, 2);
    return (float)f;
}
static inline uint16_t float_to_half(float v)
{
    _Float16 f = (_Float16)v;
    uint16_t h;
    memcpy(&h, &f, 2);
    return h;
}

/* float to 8 bits as the conversions round: SATURATED_CLIP(255 (v - min) / (max - min) + 0.5) */
static inline uint8_t f_to_8(float v, float max, float min)
{
    float r = 255.0f * (v - min) / (max - min) + 0.5f;
    if (!(r > 0))
        return 0;
    return r >= 255 ? 255 : (uint8_t)r;
}

/* one sample of a planar buffer */
#define SAMPLE(T, buf, y, x) (((const T *)CROW(buf, y))[x])

/* a loop over dest's pixels with in and out the src and dest rows */
#define PIXELS(ST, DT, ...)                                                                               \
    do {                                                                                                 \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, src));                                                                          \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const ST *in = (const ST *)CROW(src, y);                                                     \
            DT *out = (DT *)ROW(dest, y);                                                                \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                __VA_ARGS__;                                                                                 \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    } while (0)

#endif

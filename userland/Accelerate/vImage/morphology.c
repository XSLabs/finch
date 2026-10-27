/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's morphology (Morphology.h): dilate and erode with a shaped kernel, and max and
 * min over a rectangle, for Planar8, PlanarF, ARGB8888 and ARGBFFFF. The kernel is
 * centred on each destination pixel (offset into the source by the ROI); samples that
 * fall outside the source are left out.
 */
#include "common.h"

/* channels samples per pixel of type T; kernel KT (NULL for max/min); dilate or erode */
#define MORPHOLOGY(fn, T, KT, channels, IS_FLOAT)                                                        \
    static vImage_Error fn(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox,    \
                           vImagePixelCount oy, const KT *kernel, vImagePixelCount kh, vImagePixelCount kw, \
                           int dilate, vImage_Flags flags)                                               \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        if (!src || !dest || !src->data || !dest->data)                                                  \
            return kvImageNullPointerArgument;                                                           \
        if (!(kh & 1) || !(kw & 1))                                                                      \
            return kvImageInvalidKernelSize;                                                             \
        if (ox + dest->width > src->width || oy + dest->height > src->height)                            \
            return kvImageInvalidOffset_X;                                                               \
        long cy = (long)kh / 2, cx = (long)kw / 2;                                                       \
        double center = kernel ? (double)kernel[cy * (long)kw + cx] : 0;                                 \
        for (vImagePixelCount y = 0; y < dest->height; ++y)                                              \
            for (vImagePixelCount x = 0; x < dest->width; ++x)                                           \
                for (int c = 0; c < (channels); ++c) {                                                   \
                    double r = dilate ? -INFINITY : INFINITY;                                            \
                    for (long ky = 0; ky < (long)kh; ++ky) {                                             \
                        long sy = (long)(y + oy) + ky - cy;                                              \
                        if (sy < 0 || sy >= (long)src->height)                                           \
                            continue;                                                                    \
                        const T *row = (const T *)CROW(src, sy);                                         \
                        for (long kx = 0; kx < (long)kw; ++kx) {                                         \
                            long sx = (long)(x + ox) + kx - cx;                                          \
                            if (sx < 0 || sx >= (long)src->width)                                        \
                                continue;                                                                \
                            double v = (double)row[sx * (channels) + c] - (kernel ? (double)kernel[ky * (long)kw + kx] : 0); \
                            r = dilate ? (v > r ? v : r) : (v < r ? v : r);                              \
                        }                                                                                \
                    }                                                                                    \
                    r += center;                                                                         \
                    T *out = (T *)ROW(dest, y);                                                          \
                    out[x * (channels) + c] = IS_FLOAT ? (T)r : (T)(r < 0 ? 0 : r > 255 ? 255 : r);       \
                }                                                                                        \
        return kvImageNoError;                                                                           \
    }

MORPHOLOGY(morph8, uint8_t, unsigned char, 1, 0)
MORPHOLOGY(morphF, float, float, 1, 1)
MORPHOLOGY(morph8888, uint8_t, unsigned char, 4, 0)
MORPHOLOGY(morphFFFF, float, float, 4, 1)

#define SHAPED(name, fn, KT, dilate)                                                                     \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox,          \
                      vImagePixelCount oy, const KT *kernel, vImagePixelCount kh, vImagePixelCount kw,   \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        if (!kernel)                                                                                     \
            return kvImageNullPointerArgument;                                                           \
        return fn(src, dest, ox, oy, kernel, kh, kw, dilate, flags);                                     \
    }
SHAPED(vImageDilate_Planar8, morph8, unsigned char, 1)
SHAPED(vImageDilate_PlanarF, morphF, float, 1)
SHAPED(vImageDilate_ARGB8888, morph8888, unsigned char, 1)
SHAPED(vImageDilate_ARGBFFFF, morphFFFF, float, 1)
SHAPED(vImageErode_Planar8, morph8, unsigned char, 0)
SHAPED(vImageErode_PlanarF, morphF, float, 0)
SHAPED(vImageErode_ARGB8888, morph8888, unsigned char, 0)
SHAPED(vImageErode_ARGBFFFF, morphFFFF, float, 0)

#define RECT(name, fn, KT, dilate)                                                                       \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImagePixelCount ox, \
                      vImagePixelCount oy, vImagePixelCount kh, vImagePixelCount kw, vImage_Flags flags)  \
    {                                                                                                    \
        return fn(src, dest, ox, oy, (const KT *)NULL, kh, kw, dilate, flags);                           \
    }
RECT(vImageMax_Planar8, morph8, unsigned char, 1)
RECT(vImageMax_PlanarF, morphF, float, 1)
RECT(vImageMax_ARGB8888, morph8888, unsigned char, 1)
RECT(vImageMax_ARGBFFFF, morphFFFF, float, 1)
RECT(vImageMin_Planar8, morph8, unsigned char, 0)
RECT(vImageMin_PlanarF, morphF, float, 0)
RECT(vImageMin_ARGB8888, morph8888, unsigned char, 0)
RECT(vImageMin_ARGBFFFF, morphFFFF, float, 0)

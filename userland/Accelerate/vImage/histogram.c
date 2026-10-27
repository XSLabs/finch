/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's histogram operations (Histogram.h): calculation, equalization, histogram
 * specification, contrast stretch and ends-in contrast stretch, for Planar8, PlanarF,
 * ARGB8888 and ARGBFFFF (four channels independently). The lookup tables are built as
 * Apple's build them: equalization rounds cumulative fractions to 255, the stretches
 * map the chosen range linearly with truncation, and ends-in cuts at the first value
 * with the low share of pixels at or below it and the last with the high share at or
 * above it. Float images are binned into histogram_entries bins over [minVal, maxVal]
 * (float ends-in gives the bin's fraction of the cut range, in [0, 1]). Histogram
 * specification maps each value to the one whose desired cumulative share is nearest;
 * Apple's picks a neighbouring value for a few percent of them.
 */
#include "common.h"

/* MARK: - Histograms */

static void histogram8(const vImage_Buffer *src, int channels, int c, vImagePixelCount *h)
{
    memset(h, 0, 256 * sizeof(*h));
    for (vImagePixelCount y = 0; y < src->height; ++y) {
        const uint8_t *row = CROW(src, y);
        for (vImagePixelCount x = 0; x < src->width; ++x)
            h[row[x * channels + c]]++;
    }
}

static inline long bin_of(float v, unsigned entries, float minVal, float maxVal)
{
    float f = (float)entries * (v - minVal) / (maxVal - minVal);
    if (!(f > 0))
        return 0;
    return f >= (float)entries - 1 ? (long)entries - 1 : (long)f;
}

static void histogramF(const vImage_Buffer *src, int channels, int c, vImagePixelCount *h, unsigned entries,
                       float minVal, float maxVal)
{
    memset(h, 0, entries * sizeof(*h));
    for (vImagePixelCount y = 0; y < src->height; ++y) {
        const float *row = (const float *)CROW(src, y);
        for (vImagePixelCount x = 0; x < src->width; ++x)
            h[bin_of(row[x * channels + c], entries, minVal, maxVal)]++;
    }
}

vImage_Error vImageHistogramCalculation_Planar8(const vImage_Buffer *src, vImagePixelCount *histogram,
                                                vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !src->data || !histogram)
        return kvImageNullPointerArgument;
    histogram8(src, 1, 0, histogram);
    return kvImageNoError;
}

vImage_Error vImageHistogramCalculation_ARGB8888(const vImage_Buffer *src, vImagePixelCount *histogram[4],
                                                 vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !src->data || !histogram)
        return kvImageNullPointerArgument;
    for (int c = 0; c < 4; ++c)
        if (histogram[c])
            histogram8(src, 4, c, histogram[c]);
    return kvImageNoError;
}

vImage_Error vImageHistogramCalculation_PlanarF(const vImage_Buffer *src, vImagePixelCount *histogram,
                                                unsigned int entries, Pixel_F minVal, Pixel_F maxVal,
                                                vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !src->data || !histogram)
        return kvImageNullPointerArgument;
    if (!entries || !(maxVal > minVal))
        return kvImageInvalidParameter;
    histogramF(src, 1, 0, histogram, entries, minVal, maxVal);
    return kvImageNoError;
}

vImage_Error vImageHistogramCalculation_ARGBFFFF(const vImage_Buffer *src, vImagePixelCount *histogram[4],
                                                 unsigned int entries, Pixel_F minVal, Pixel_F maxVal,
                                                 vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !src->data || !histogram)
        return kvImageNullPointerArgument;
    if (!entries || !(maxVal > minVal))
        return kvImageInvalidParameter;
    for (int c = 0; c < 4; ++c)
        if (histogram[c])
            histogramF(src, 4, c, histogram[c], entries, minVal, maxVal);
    return kvImageNoError;
}

/* MARK: - Lookup tables from histograms (n bins, total samples) */

static void equalize_table(const vImagePixelCount *h, unsigned n, double total, double *out)
{
    double cum = 0;
    for (unsigned i = 0; i < n; ++i) {
        cum += (double)h[i];
        out[i] = cum / total;
    }
}

/* the bins of a stretch from lo to hi: 0 at or below lo, 1 at or above hi */
static void stretch_range(const vImagePixelCount *h, unsigned n, double total, unsigned pl, unsigned ph,
                          unsigned *lo, unsigned *hi)
{
    double cum = 0;
    *lo = 0;
    for (unsigned i = 0; i < n; ++i) {
        cum += (double)h[i];
        if (cum * 100 >= (double)pl * total) {
            *lo = i;
            break;
        }
    }
    cum = 0;
    *hi = n - 1;
    for (unsigned i = n; i-- > 0;) {
        cum += (double)h[i];
        if (cum * 100 >= (double)ph * total) {
            *hi = i;
            break;
        }
    }
}

/* the bin of the desired histogram whose cumulative fraction is nearest each source bin's */
static void specify_table(const vImagePixelCount *h, const vImagePixelCount *want, unsigned n, double total,
                          unsigned *out)
{
    double *src = malloc(n * sizeof(double)), *des = malloc(n * sizeof(double)), wantTotal = 0;
    if (!src || !des) {
        free(src);
        free(des);
        return;
    }
    for (unsigned i = 0; i < n; ++i)
        wantTotal += (double)want[i];
    equalize_table(h, n, total, src);
    equalize_table(want, n, wantTotal ? wantTotal : 1, des);
    for (unsigned i = 0; i < n; ++i) {
        unsigned best = 0;
        double bestDiff = INFINITY;
        for (unsigned t = 0; t < n; ++t) {
            double d = fabs(des[t] - src[i]);
            if (d < bestDiff) {
                bestDiff = d;
                best = t;
            }
        }
        out[i] = best;
    }
    free(src);
    free(des);
}

/* MARK: - 8-bit operations through a table per channel */

enum { EQUALIZE, SPECIFY, STRETCH, ENDS_IN };

static vImage_Error transform8(const vImage_Buffer *src, const vImage_Buffer *dest, int channels, int op,
                               const vImagePixelCount *const *want, const unsigned *pl, const unsigned *ph,
                               vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    double total = (double)src->width * src->height;
    uint8_t table[4][256];
    for (int c = 0; c < channels; ++c) {
        vImagePixelCount h[256];
        histogram8(src, channels, c, h);
        if (op == EQUALIZE) {
            double f[256];
            equalize_table(h, 256, total, f);
            for (int i = 0; i < 256; ++i)
                table[c][i] = (uint8_t)lround(f[i] * 255);
        } else if (op == SPECIFY) {
            unsigned t[256];
            specify_table(h, want[c], 256, total, t);
            for (int i = 0; i < 256; ++i)
                table[c][i] = (uint8_t)t[i];
        } else {
            unsigned lo = 0, hi = 255;
            if (op == STRETCH) {
                while (lo < 255 && !h[lo])
                    ++lo;
                while (hi > 0 && !h[hi])
                    --hi;
            } else
                stretch_range(h, 256, total, pl[c], ph[c], &lo, &hi);
            for (unsigned i = 0; i < 256; ++i)
                table[c][i] = i <= lo ? 0 : i >= hi ? 255 : (uint8_t)((i - lo) * 255 / (hi - lo));
            if (op == STRETCH && lo >= hi)
                for (unsigned i = 0; i < 256; ++i)
                    table[c][i] = (uint8_t)i;
        }
    }
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width * (vImagePixelCount)channels; ++x)
            out[x] = table[x % (vImagePixelCount)channels][in[x]];
    }
    return kvImageNoError;
}

vImage_Error vImageEqualization_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    return transform8(src, dest, 1, EQUALIZE, NULL, NULL, NULL, flags);
}
vImage_Error vImageEqualization_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    return transform8(src, dest, 4, EQUALIZE, NULL, NULL, NULL, flags);
}
vImage_Error vImageHistogramSpecification_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                  const vImagePixelCount *desired, vImage_Flags flags)
{
    if (!desired)
        return kvImageNullPointerArgument;
    return transform8(src, dest, 1, SPECIFY, &desired, NULL, NULL, flags);
}
vImage_Error vImageHistogramSpecification_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                   const vImagePixelCount *desired[4], vImage_Flags flags)
{
    if (!desired)
        return kvImageNullPointerArgument;
    return transform8(src, dest, 4, SPECIFY, desired, NULL, NULL, flags);
}
vImage_Error vImageContrastStretch_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    return transform8(src, dest, 1, STRETCH, NULL, NULL, NULL, flags);
}
vImage_Error vImageContrastStretch_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)
{
    return transform8(src, dest, 4, STRETCH, NULL, NULL, NULL, flags);
}
vImage_Error vImageEndsInContrastStretch_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                 unsigned int percent_low, unsigned int percent_high,
                                                 vImage_Flags flags)
{
    if (percent_low + percent_high > 100)
        return kvImageInvalidParameter;
    return transform8(src, dest, 1, ENDS_IN, NULL, &percent_low, &percent_high, flags);
}
vImage_Error vImageEndsInContrastStretch_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                  const unsigned int percent_low[4],
                                                  const unsigned int percent_high[4], vImage_Flags flags)
{
    if (!percent_low || !percent_high)
        return kvImageNullPointerArgument;
    return transform8(src, dest, 4, ENDS_IN, NULL, percent_low, percent_high, flags);
}

/* MARK: - Float operations, binned */

static vImage_Error transformF(const vImage_Buffer *src, const vImage_Buffer *dest, int channels, int op,
                               const vImagePixelCount *const *want, const unsigned *pl, const unsigned *ph,
                               unsigned entries, float minVal, float maxVal, vImage_Flags flags)
{
    if (flags & kvImageGetTempBufferSize)
        return (vImage_Error)(entries * sizeof(vImagePixelCount));
    CHECK(fits(dest, src));
    if (!entries || !(maxVal > minVal))
        return kvImageInvalidParameter;
    double total = (double)src->width * src->height, range = (double)maxVal - minVal;
    float *table = malloc((size_t)channels * entries * sizeof(float));
    vImagePixelCount *h = malloc(entries * sizeof(vImagePixelCount));
    double *f = malloc(entries * sizeof(double));
    unsigned *t = malloc(entries * sizeof(unsigned));
    float lo[4] = {0}, hi[4] = {0};
    if (!table || !h || !f || !t) {
        free(table);
        free(h);
        free(f);
        free(t);
        return kvImageMemoryAllocationError;
    }
    for (int c = 0; c < channels; ++c) {
        if (op == STRETCH) {
            /* the image's own extremes */
            lo[c] = INFINITY;
            hi[c] = -INFINITY;
            for (vImagePixelCount y = 0; y < src->height; ++y) {
                const float *row = (const float *)CROW(src, y);
                for (vImagePixelCount x = 0; x < src->width; ++x) {
                    float v = row[x * channels + c];
                    lo[c] = v < lo[c] ? v : lo[c];
                    hi[c] = v > hi[c] ? v : hi[c];
                }
            }
            continue;
        }
        histogramF(src, channels, c, h, entries, minVal, maxVal);
        float *tab = table + (size_t)c * entries;
        if (op == EQUALIZE) {
            /* (as Apple's computes it, then held to the range) */
            float step = (maxVal - minVal) / (float)total, cum = 0;
            for (unsigned i = 0; i < entries; ++i) {
                cum += (float)h[i];
                float v = fmaf(cum, step, minVal);
                tab[i] = v > maxVal ? maxVal : v;
            }
        } else if (op == SPECIFY) {
            specify_table(h, want[c], entries, total, t);
            for (unsigned i = 0; i < entries; ++i)
                tab[i] = (float)(minVal + range * t[i] / (entries > 1 ? entries - 1 : 1));
        } else {
            /* ends-in works on bins and gives fractions in [0, 1] */
            unsigned l, u;
            stretch_range(h, entries, total, pl[c], ph[c], &l, &u);
            float inv = 1.0f / (float)(u - l);
            for (unsigned i = 0; i < entries; ++i)
                tab[i] = (float)((i < l ? l : i > u ? u : i) - l) * inv;
        }
    }
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const float *in = (const float *)CROW(src, y);
        float *out = (float *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width * (vImagePixelCount)channels; ++x) {
            int c = (int)(x % (vImagePixelCount)channels);
            float v = in[x];
            if (op == STRETCH) {
                float scale = (maxVal - minVal) / (hi[c] - lo[c]);
                out[x] = hi[c] > lo[c] ? (v - lo[c]) * scale + minVal : v;
            } else
                out[x] = table[(size_t)c * entries + (size_t)bin_of(v, entries, minVal, maxVal)];
        }
    }
    free(table);
    free(h);
    free(f);
    free(t);
    return kvImageNoError;
}

vImage_Error vImageEqualization_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                        unsigned int entries, Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    return transformF(src, dest, 1, EQUALIZE, NULL, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageEqualization_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                         unsigned int entries, Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    return transformF(src, dest, 4, EQUALIZE, NULL, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageHistogramSpecification_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                  const vImagePixelCount *desired, unsigned int entries,
                                                  Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    if (!desired)
        return kvImageNullPointerArgument;
    return transformF(src, dest, 1, SPECIFY, &desired, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageHistogramSpecification_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                   const vImagePixelCount *desired[4], unsigned int entries,
                                                   Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    if (!desired)
        return kvImageNullPointerArgument;
    return transformF(src, dest, 4, SPECIFY, desired, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageContrastStretch_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                           unsigned int entries, Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    return transformF(src, dest, 1, STRETCH, NULL, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageContrastStretch_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                            unsigned int entries, Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    return transformF(src, dest, 4, STRETCH, NULL, NULL, NULL, entries, minVal, maxVal, flags);
}
vImage_Error vImageEndsInContrastStretch_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                 unsigned int percent_low, unsigned int percent_high,
                                                 unsigned int entries, Pixel_F minVal, Pixel_F maxVal,
                                                 vImage_Flags flags)
{
    if (percent_low + percent_high > 100)
        return kvImageInvalidParameter;
    return transformF(src, dest, 1, ENDS_IN, NULL, &percent_low, &percent_high, entries, minVal, maxVal, flags);
}
vImage_Error vImageEndsInContrastStretch_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                  const unsigned int percent_low[4],
                                                  const unsigned int percent_high[4], unsigned int entries,
                                                  Pixel_F minVal, Pixel_F maxVal, vImage_Flags flags)
{
    if (!percent_low || !percent_high)
        return kvImageNullPointerArgument;
    return transformF(src, dest, 4, ENDS_IN, NULL, percent_low, percent_high, entries, minVal, maxVal, flags);
}

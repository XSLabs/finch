/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's dithered conversions (Conversion.h): float and 16-bit samples to 8 bits, 8-bit
 * colour to the packed 16-bit formats, and 8-bit planes to 1-, 2- and 4-bit planes and
 * indexed (palette) images.
 *
 * kvImageConvert_DitherNone rounds to nearest. The ordered dithers add blue noise: Finch's
 * own 64 x 64 pattern, made at first use by the void-and-cluster method, with uniform or
 * (the default) Gaussian amplitudes; kvImageConvert_DitherOrdered starts each call at a
 * random offset into it, the reproducible form at the origin. Apple's pattern is its own,
 * so ordered results differ from Apple's in detail but not in kind. Floyd-Steinberg and
 * Atkinson diffuse the error left to right, row by row, in floating point: Atkinson's
 * 1-bit results match Apple's, the others differ near the right edge and in rounding.
 */
#include "common.h"
#include <pthread.h>

/* the dither mode, without the ordered dithers' noise shape */
#define DITHER_MODE(d) ((int)((unsigned)(d) & ~(unsigned)kvImageConvert_OrderedNoiseShapeMask))
/* (the SDK's dither constants are unsigned) */
enum { NONE = 0, ORDERED_RANDOM = 1, ORDERED_FIXED = 2, FLOYD_STEINBERG = 3, ATKINSON = 4 };
#define DITHER_SHAPE(d) ((unsigned)(d) & (unsigned)kvImageConvert_OrderedNoiseShapeMask)

/* MARK: - Blue noise */

#define NOISE 64

static float uniform_noise[NOISE * NOISE], gaussian_noise[NOISE * NOISE];

/* energy of the pattern's set pixels at each pixel, a Gaussian (sigma 1.5) on the torus */
static void add_energy(float *energy, int x0, int y0, float sign)
{
    for (int dy = -6; dy <= 6; ++dy)
        for (int dx = -6; dx <= 6; ++dx)
            energy[((y0 + dy) & (NOISE - 1)) * NOISE + ((x0 + dx) & (NOISE - 1))] +=
                sign * expf(-(float)(dx * dx + dy * dy) / (2 * 1.5f * 1.5f));
}

/* the set (or unset) pixel of highest (or lowest) energy */
static int extreme(const float *energy, const uint8_t *set, int want, int highest)
{
    int best = -1;
    for (int i = 0; i < NOISE * NOISE; ++i)
        if (set[i] == want && (best < 0 || (highest ? energy[i] > energy[best] : energy[i] < energy[best])))
            best = i;
    return best;
}

/* the inverse of the standard normal distribution function (Acklam's rational approximation) */
static double probit(double p)
{
    static const double a[] = {-39.69683028665376, 220.9460984245205, -275.9285104469687, 138.3577518672690,
                               -30.66479806614716, 2.506628274631000};
    static const double b[] = {-54.47609879822406, 161.5858368580409, -155.6989798598866, 66.80131188771972,
                               -13.28068155288572};
    static const double c[] = {-7.784894002430293e-03, -0.3223964580411365, -2.400758277161838, -2.549732539343734,
                               4.374664141464968, 2.938163982698783};
    static const double d[] = {7.784695709041462e-03, 0.3224671290700398, 2.445134137142996, 3.754408661907416};
    if (p < 0.02425 || p > 1 - 0.02425) {
        double q = sqrt(-2 * log(p < 0.5 ? p : 1 - p));
        double v = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                   ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
        return p < 0.5 ? v : -v;
    }
    double q = p - 0.5, r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
           (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
}

static void make_noise(void)
{
    static float energy[NOISE * NOISE];
    static uint8_t set[NOISE * NOISE];
    static int rank[NOISE * NOISE];
    uint32_t seed = 0x9e3779b9;
    int ones = 0;
    /* a tenth of the pixels at random, then relaxed: the tightest cluster's pixel moves to
       the largest void until that is where it came from */
    while (ones < NOISE * NOISE / 10) {
        seed = seed * 1664525u + 1013904223u;
        int i = (int)(seed >> 20);
        if (!set[i]) {
            set[i] = 1;
            add_energy(energy, i % NOISE, i / NOISE, 1);
            ++ones;
        }
    }
    for (;;) {
        int cluster = extreme(energy, set, 1, 1);
        set[cluster] = 0;
        add_energy(energy, cluster % NOISE, cluster / NOISE, -1);
        int void_ = extreme(energy, set, 0, 0);
        set[void_] = 1;
        add_energy(energy, void_ % NOISE, void_ / NOISE, 1);
        if (void_ == cluster)
            break;
    }
    /* ranks: the initial pixels from their tightest cluster down, the rest from the
       largest void up */
    static uint8_t initial[NOISE * NOISE];
    static float initial_energy[NOISE * NOISE];
    memcpy(initial, set, sizeof(set));
    memcpy(initial_energy, energy, sizeof(energy));
    for (int r = ones - 1; r >= 0; --r) {
        int i = extreme(energy, set, 1, 1);
        set[i] = 0;
        add_energy(energy, i % NOISE, i / NOISE, -1);
        rank[i] = r;
    }
    memcpy(set, initial, sizeof(set));
    memcpy(energy, initial_energy, sizeof(energy));
    for (int r = ones; r < NOISE * NOISE; ++r) {
        int i = extreme(energy, set, 0, 0);
        set[i] = 1;
        add_energy(energy, i % NOISE, i / NOISE, 1);
        rank[i] = r;
    }
    /* amplitudes in (-1/2, 1/2): uniform, or Gaussian (sigma 1/6) */
    for (int i = 0; i < NOISE * NOISE; ++i) {
        double p = (rank[i] + 0.5) / (NOISE * NOISE);
        uniform_noise[i] = (float)(p - 0.5);
        double g = probit(p) / 6;
        gaussian_noise[i] = (float)(g < -0.4999 ? -0.4999 : g > 0.4999 ? 0.4999 : g);
    }
}

static pthread_once_t noise_once = PTHREAD_ONCE_INIT;

typedef struct {
    const float *table; /* NULL: no noise */
    unsigned ox, oy;
} Noise;

static Noise noise_for(int dither)
{
    Noise n = {NULL, 0, 0};
    int mode = DITHER_MODE(dither);
    if (mode != ORDERED_RANDOM && mode != ORDERED_FIXED)
        return n;
    pthread_once(&noise_once, make_noise);
    n.table = DITHER_SHAPE(dither) == (unsigned)kvImageConvert_OrderedUniformBlue ? uniform_noise
                                                                                                    : gaussian_noise;
    if (mode == ORDERED_RANDOM) {
        uint32_t r = arc4random();
        n.ox = r & (NOISE - 1);
        n.oy = (r >> 8) & (NOISE - 1);
    }
    return n;
}

/* the noise at a pixel, in (-1/2, 1/2) */
static inline float noise_at(const Noise *n, vImagePixelCount x, vImagePixelCount y)
{
    return n->table ? n->table[((y + n->oy) & (NOISE - 1)) * NOISE + ((x + n->ox) & (NOISE - 1))] : 0;
}

/* MARK: - Checks */

static const vImage_Flags allowed = kvImageDoNotTile | kvImageGetTempBufferSize | kvImagePrintDiagnosticsToConsole;

/* the modes a function accepts, by dither & ~shape: none and ordered, ordered only, or all */
enum Modes { NONE_OR_ORDERED, ORDERED, ANY };

static vImage_Error check(const vImage_Buffer *src, const vImage_Buffer *dest, int dither, enum Modes modes,
                          vImage_Flags flags)
{
    if (flags & ~allowed)
        return kvImageUnknownFlagsBit;
    CHECK(fits(dest, src));
    int mode = DITHER_MODE(dither);
    bool ok = modes == ANY ? mode >= NONE && mode <= ATKINSON
              : modes == ORDERED ? mode == ORDERED_RANDOM || mode == ORDERED_FIXED
                                 : mode >= NONE && mode <= ORDERED_FIXED;
    return ok ? kvImageNoError : kvImageInvalidParameter;
}

static inline uint8_t round8(float v)
{
    float r = v + 0.5f;
    if (!(r > 0))
        return 0;
    return r >= 255 ? 255 : (uint8_t)r;
}

/* MARK: - Float and 16 bits to 8 */

/* n channels of src (float or 16-bit) to n of dest, through the permutation */
static vImage_Error to8(const vImage_Buffer *src, const vImage_Buffer *dest, int n, bool isFloat, const float *maxF,
                        const float *minF, int dither, const uint8_t *perm, vImage_Flags flags)
{
    if (flags & kvImageGetTempBufferSize)
        return (flags & ~allowed) ? kvImageUnknownFlagsBit : 0;
    CHECK(check(src, dest, dither, NONE_OR_ORDERED, flags));
    if (perm)
        for (int c = 0; c < n; ++c)
            if (perm[c] > 3)
                return kvImageInvalidParameter;
    Noise noise = noise_for(dither);
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            float d = noise_at(&noise, x, y);
            uint8_t v[4];
            for (int c = 0; c < n; ++c) {
                if (isFloat) {
                    float f = ((const float *)in)[n * x + c];
                    v[c] = noise.table ? round8(255.0f * (f - minF[c]) / (maxF[c] - minF[c]) + d)
                                       : f_to_8(f, maxF[c], minF[c]);
                } else {
                    uint16_t s = ((const uint16_t *)in)[n * x + c];
                    v[c] = noise.table ? round8((float)s * (255.0f / 65535.0f) + d)
                                       : (uint8_t)((s * 255u + 32767u) / 65535u);
                }
            }
            for (int c = 0; c < n; ++c)
                out[n * x + c] = v[perm ? perm[c] : c];
        }
    }
    return kvImageNoError;
}

vImage_Error vImageConvert_PlanarFtoPlanar8_dithered(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                     Pixel_F maxFloat, Pixel_F minFloat, int dither, vImage_Flags flags)
{
    return to8(src, dest, 1, true, &maxFloat, &minFloat, dither, NULL, flags);
}
vImage_Error vImageConvert_RGBFFFtoRGB888_dithered(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                   const Pixel_F maxFloat[3], const Pixel_F minFloat[3], int dither,
                                                   vImage_Flags flags)
{
    return to8(src, dest, 3, true, maxFloat, minFloat, dither, NULL, flags);
}
vImage_Error vImageConvert_ARGBFFFFtoARGB8888_dithered(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                       const Pixel_FFFF maxFloat, const Pixel_FFFF minFloat, int dither,
                                                       const uint8_t permuteMap[4], vImage_Flags flags)
{
    return to8(src, dest, 4, true, maxFloat, minFloat, dither, permuteMap, flags);
}
vImage_Error vImageConvert_Planar16UtoPlanar8_dithered(const vImage_Buffer *src, const vImage_Buffer *dest, int dither,
                                                       vImage_Flags flags)
{
    return to8(src, dest, 1, false, NULL, NULL, dither, NULL, flags);
}
vImage_Error vImageConvert_RGB16UtoRGB888_dithered(const vImage_Buffer *src, const vImage_Buffer *dest, int dither,
                                                   vImage_Flags flags)
{
    return to8(src, dest, 3, false, NULL, NULL, dither, NULL, flags);
}
vImage_Error vImageConvert_ARGB16UtoARGB8888_dithered(const vImage_Buffer *src, const vImage_Buffer *dest, int dither,
                                                      const uint8_t permuteMap[4], vImage_Flags flags)
{
    return to8(src, dest, 4, false, NULL, NULL, dither, permuteMap, flags);
}

/* MARK: - 8 bits to the packed 16-bit formats */

/* channel v (8 bits) to `bits` bits, with the header's 8.8 fixed point and a noise in
   (-128, 128) */
static inline uint32_t pack_channel(uint32_t v, int bits, int noise)
{
    int32_t scaled = (int32_t)((v * (((1u << bits) - 1) << 8) + 127) / 255) + noise + 128;
    int32_t r = scaled < 0 ? 0 : scaled >> 8;
    int32_t top = (1 << bits) - 1;
    return (uint32_t)(r > top ? top : r);
}

enum Packed { RGB565, ARGB1555, RGBA5551 };

static vImage_Error to_packed(const vImage_Buffer *src, const vImage_Buffer *dest, int n, int ri, int gi, int bi, int ai,
                              enum Packed format, int dither, vImage_Flags flags)
{
    if (flags & kvImageGetTempBufferSize)
        return (flags & ~allowed) ? kvImageUnknownFlagsBit : 0;
    CHECK(check(src, dest, dither, ORDERED, flags));
    Noise noise = noise_for(dither);
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint16_t *out = (uint16_t *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            const uint8_t *p = in + (size_t)n * x;
            int d = (int)lrintf(noise_at(&noise, x, y) * 256);
            d = d > 127 ? 127 : d;
            switch (format) {
            case RGB565:
                out[x] = (uint16_t)(pack_channel(p[ri], 5, d) << 11 | pack_channel(p[gi], 6, d) << 5 |
                                    pack_channel(p[bi], 5, d));
                break;
            case ARGB1555:
                out[x] = (uint16_t)(((p[ai] + 127u) / 255u) << 15 | pack_channel(p[ri], 5, d) << 10 |
                                    pack_channel(p[gi], 5, d) << 5 | pack_channel(p[bi], 5, d));
                break;
            default:
                out[x] = (uint16_t)(pack_channel(p[ri], 5, d) << 11 | pack_channel(p[gi], 5, d) << 6 |
                                    pack_channel(p[bi], 5, d) << 1 | (p[ai] + 127u) / 255u);
                break;
            }
        }
    }
    return kvImageNoError;
}

#define PACKED(name, n, ri, gi, bi, ai, format)                                                          \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer, int dither, \
                      const vImage_Flags flags)                                                          \
    {                                                                                                    \
        return to_packed(src, dest, n, ri, gi, bi, ai, format, dither, flags);                           \
    }
PACKED(vImageConvert_RGB888toRGB565_dithered, 3, 0, 1, 2, 0, RGB565)
PACKED(vImageConvert_ARGB8888toRGB565_dithered, 4, 1, 2, 3, 0, RGB565)
PACKED(vImageConvert_RGBA8888toRGB565_dithered, 4, 0, 1, 2, 3, RGB565)
PACKED(vImageConvert_BGRA8888toRGB565_dithered, 4, 2, 1, 0, 3, RGB565)
PACKED(vImageConvert_ARGB8888toARGB1555_dithered, 4, 1, 2, 3, 0, ARGB1555)
PACKED(vImageConvert_RGBA8888toRGBA5551_dithered, 4, 0, 1, 2, 3, RGBA5551)

/* MARK: - 1, 2 and 4 bits a pixel */

/* the palette entry nearest v (the lower of two equally near); entries in increasing order */
static inline int nearest(const uint8_t *palette, int n, float v)
{
    int best = 0;
    for (int i = 1; i < n; ++i)
        if (fabsf(v - palette[i]) < fabsf(v - palette[best]))
            best = i;
    return best;
}

/* an automatic palette: the means (rounded down) of n runs of equal pixel count through the
   sorted samples, a run never splitting one value; fewer distinct values than entries are
   used as they are, and spare entries are 255 */
static void make_palette(const vImage_Buffer *src, const vImage_Buffer *dest, uint8_t *palette, int n)
{
    uint64_t histogram[256] = {0}, total;
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ++histogram[CROW(src, y)[x]];
    total = (uint64_t)dest->width * dest->height;
    int distinct = 0;
    for (int v = 0; v < 256; ++v)
        distinct += histogram[v] != 0;
    int k = 0;
    if (distinct <= n) {
        for (int v = 0; v < 256; ++v)
            if (histogram[v])
                palette[k++] = (uint8_t)v;
    } else {
        /* each run closes once it holds its share of the pixels left, or when the distinct
           values left are only enough for one a run */
        uint64_t seen = 0, count = 0, sum = 0;
        int left = distinct;
        for (int v = 0; v < 256 && k < n; ++v) {
            if (!histogram[v])
                continue;
            count += histogram[v];
            sum += histogram[v] * (uint64_t)v;
            --left;
            if (count >= (total - seen) / (uint64_t)(n - k) || left <= n - k - 1 || !left) {
                palette[k++] = (uint8_t)(sum / count);
                seen += count;
                count = sum = 0;
            }
        }
    }
    for (; k < n; ++k)
        palette[k] = 255;
}

static vImage_Error to_bits(const vImage_Buffer *src, const vImage_Buffer *dest, int bits, uint8_t *colors, int dither,
                            vImage_Flags flags)
{
    if (flags & kvImageGetTempBufferSize)
        return (flags & ~allowed) ? kvImageUnknownFlagsBit : 0;
    CHECK(check(src, dest, dither, ANY, flags));
    int n = 1 << bits, mode = DITHER_MODE(dither);
    uint8_t palette[16];
    if (colors) {
        bool zero = true;
        for (int i = 0; i < n; ++i)
            zero = zero && !colors[i];
        if (zero)
            make_palette(src, dest, colors, n);
        memcpy(palette, colors, (size_t)n);
    } else
        for (int i = 0; i < n; ++i)
            palette[i] = (uint8_t)(i * 255 / (n - 1));
    Noise noise = noise_for(dither);
    vImagePixelCount w = dest->width;
    /* error rows for the diffusing dithers: this row and the next two, two pixels of margin */
    float *err = NULL;
    if (mode == FLOYD_STEINBERG || mode == ATKINSON) {
        err = calloc(3 * (w + 4), sizeof(float));
        if (!err)
            return kvImageMemoryAllocationError;
    }
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *out = ROW(dest, y);
        memset(out, 0, (w * (vImagePixelCount)bits + 7) / 8);
        for (vImagePixelCount x = 0; x < w; ++x) {
            float v = in[x];
            if (err)
                v += err[x + 2];
            else if (noise.table) {
                /* noise of the spacing between the palette entries around v */
                int i = nearest(palette, n, v);
                int j = v >= palette[i] ? (i + 1 < n ? i + 1 : i) : (i > 0 ? i - 1 : i);
                float gap = fabsf((float)palette[j] - (float)palette[i]);
                v += noise_at(&noise, x, y) * (gap ? gap : 255.0f / (n - 1));
            }
            int q = nearest(palette, n, v);
            out[x * bits / 8] |= (uint8_t)(q << (8 - bits - (x * bits) % 8));
            if (err) {
                float e = v - palette[q];
                float *row0 = err + 2, *row1 = row0 + (w + 4), *row2 = row1 + (w + 4);
                if (mode == FLOYD_STEINBERG) {
                    row0[x + 1] += e * 7 / 16;
                    row1[x - 1] += e * 3 / 16;
                    row1[x] += e * 5 / 16;
                    row1[x + 1] += e * 1 / 16;
                } else {
                    row0[x + 1] += e / 8;
                    row0[x + 2] += e / 8;
                    row1[x - 1] += e / 8;
                    row1[x] += e / 8;
                    row1[x + 1] += e / 8;
                    row2[x] += e / 8;
                }
            }
        }
        if (err) {
            memmove(err, err + (w + 4), 2 * (w + 4) * sizeof(float));
            memset(err + 2 * (w + 4), 0, (w + 4) * sizeof(float));
        }
    }
    free(err);
    return kvImageNoError;
}

vImage_Error vImageConvert_Planar8toPlanar1(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                            int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 1, NULL, dither, flags);
}
vImage_Error vImageConvert_Planar8toPlanar2(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                            int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 2, NULL, dither, flags);
}
vImage_Error vImageConvert_Planar8toPlanar4(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                            int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 4, NULL, dither, flags);
}
vImage_Error vImageConvert_Planar8toIndexed1(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                             Pixel_8 colors[2], int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 1, colors, dither, flags);
}
vImage_Error vImageConvert_Planar8toIndexed2(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                             Pixel_8 colors[4], int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 2, colors, dither, flags);
}
vImage_Error vImageConvert_Planar8toIndexed4(const vImage_Buffer *src, const vImage_Buffer *dest, void *tempBuffer,
                                             Pixel_8 colors[16], int dither, const vImage_Flags flags)
{
    return to_bits(src, dest, 4, colors, dither, flags);
}

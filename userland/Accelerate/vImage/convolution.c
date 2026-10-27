/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's convolutions (Convolution.h): general convolution with integer or float
 * kernels (with bias and divisor), per-channel kernels, box and tent blurs, separable
 * convolution, and Richardson-Lucy deconvolution, in the formats the header lists.
 *
 * One engine serves them all. Each destination sample is a weighted sum over the kernel
 * centred on the corresponding source sample (offset by the ROI), with samples off the
 * source's edge handled by the edging flag: copied through unconvolved
 * (kvImageCopyInPlace), replaced by the background colour (kvImageBackgroundColorFill),
 * replaced by the nearest edge sample (kvImageEdgeExtend), or left out with the result
 * rescaled by the share of the kernel used (kvImageTruncateKernel).
 */
#include "common.h"

#define EDGES (kvImageCopyInPlace | kvImageBackgroundColorFill | kvImageEdgeExtend | kvImageTruncateKernel)

enum Format { F8, FF, F16F, F16U };

static inline double load(const void *row, enum Format f, size_t i)
{
    switch (f) {
    case F8:
        return ((const uint8_t *)row)[i];
    case FF:
        return ((const float *)row)[i];
    case F16F:
        return half_to_float(((const uint16_t *)row)[i]);
    default:
        return ((const uint16_t *)row)[i];
    }
}

typedef struct {
    const vImage_Buffer *src, *dest;
    vImagePixelCount ox, oy;
    int channels;
    enum Format in, out;
    vImage_Flags flags;
    const double *background; /* per channel */
    double copyScale;
} Job;

static vImage_Error check_job(const Job *j, uint32_t kh, uint32_t kw)
{
    if (!j->src || !j->dest || !j->src->data || !j->dest->data)
        return kvImageNullPointerArgument;
    if (!(kh & 1) || !(kw & 1) || !kh || !kw)
        return kvImageInvalidKernelSize;
    vImage_Flags edges = j->flags & EDGES;
    if (!edges || (edges & (edges - 1)))
        return kvImageInvalidEdgeStyle;
    if (j->ox + j->dest->width > j->src->width)
        return kvImageInvalidOffset_X;
    if (j->oy + j->dest->height > j->src->height)
        return kvImageInvalidOffset_Y;
    return kvImageNoError;
}

/* sample c of source pixel (sx, sy) under the edging mode; returns 0 (and sets *missing)
   for a sample to leave out */
static inline double sample(const Job *j, long sx, long sy, int c, int *missing)
{
    long w = (long)j->src->width, h = (long)j->src->height;
    if (sx < 0 || sy < 0 || sx >= w || sy >= h) {
        if (j->flags & kvImageEdgeExtend) {
            sx = sx < 0 ? 0 : sx >= w ? w - 1 : sx;
            sy = sy < 0 ? 0 : sy >= h ? h - 1 : sy;
        } else if (j->flags & kvImageBackgroundColorFill)
            return j->background[c];
        else {
            *missing = 1;
            return 0;
        }
    }
    return load(CROW(j->src, sy), j->in, (size_t)sx * j->channels + c);
}

/* the weighted sum for dest sample (x, y, c) with kernel K (kh x kw, weights as doubles);
   returns 0 when kvImageCopyInPlace applies and *copy is set, and the share of the
   kernel's weight that was used in *share */
static double weighted(const Job *j, const double *K, uint32_t kh, uint32_t kw, vImagePixelCount x,
                       vImagePixelCount y, int c, int *copy, double *usedWeight)
{
    long cx = (long)x + (long)j->ox - (long)kw / 2, cy = (long)y + (long)j->oy - (long)kh / 2;
    double sum = 0, used = 0;
    for (uint32_t i = 0; i < kh; ++i)
        for (uint32_t k = 0; k < kw; ++k) {
            int missing = 0;
            double v = sample(j, cx + (long)k, cy + (long)i, c, &missing);
            if (missing) {
                if (j->flags & kvImageCopyInPlace || !(j->flags & EDGES)) {
                    *copy = 1;
                    return 0;
                }
                continue;
            }
            sum += K[i * kw + k] * v;
            used += K[i * kw + k];
        }
    *usedWeight = used;
    return sum;
}

static void store(const Job *j, vImagePixelCount x, vImagePixelCount y, int c, double v)
{
    uint8_t *row = ROW(j->dest, y);
    size_t i = (size_t)x * j->channels + c;
    switch (j->out) {
    case F8:
        row[i] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        break;
    case FF:
        ((float *)row)[i] = (float)v;
        break;
    case F16F:
        ((uint16_t *)row)[i] = float_to_half((float)v);
        break;
    default:
        ((uint16_t *)row)[i] = (uint16_t)(v < 0 ? 0 : v > 65535 ? 65535 : v);
        break;
    }
}

/* (an 8-bit source copied into 16-bit results takes the separable conversion's scale) */
static void copy_through(const Job *j, vImagePixelCount x, vImagePixelCount y, int c)
{
    double v = load(CROW(j->src, y + j->oy), j->in, (size_t)(x + j->ox) * j->channels + c);
    store(j, x, y, c, j->in == F8 && j->out == F16U ? v * j->copyScale : v);
}

/* MARK: - Integer kernels (sum + bias) / divisor, truncating as C does */

static vImage_Error convolve_int(Job *j, const int16_t *const *kernels, uint32_t kh, uint32_t kw,
                                 const int32_t *divisors, const int32_t *biases, int box)
{
    TEMP_QUERY(j->flags);
    CHECK(check_job(j, kh, kw));
    double *K = malloc((size_t)kh * kw * sizeof(double) * (size_t)j->channels);
    if (!K)
        return kvImageMemoryAllocationError;
    double full[4] = {0};
    for (int c = 0; c < j->channels; ++c)
        for (uint32_t i = 0; i < kh * kw; ++i) {
            K[(size_t)c * kh * kw + i] = kernels[c][i];
            full[c] += kernels[c][i];
        }
    for (vImagePixelCount y = 0; y < j->dest->height; ++y)
        for (vImagePixelCount x = 0; x < j->dest->width; ++x)
            for (int c = 0; c < j->channels; ++c) {
                int copy = 0;
                double used = 0, sum = weighted(j, K + (size_t)c * kh * kw, kh, kw, x, y, c, &copy, &used);
                if (copy) {
                    copy_through(j, x, y, c);
                    continue;
                }
                long divisor = divisors[c] ? divisors[c] : 1;
                if (box && (j->flags & kvImageTruncateKernel) && used != full[c] && used != 0) {
                    /* a truncated box averages the pixels it covers */
                    long u = (long)used;
                    store(j, x, y, c, (double)(((long)sum + u / 2) / u));
                    continue;
                }
                double t = (j->flags & kvImageTruncateKernel) && used != full[c] && used != 0 ? sum * full[c] / used
                                                                                              : sum;
                store(j, x, y, c, trunc((t + biases[c]) / (double)divisor));
            }
    free(K);
    return kvImageNoError;
}

/* MARK: - Float kernels: sum + bias (8-bit results rounded) */

static vImage_Error convolve_float(Job *j, const float *const *kernels, uint32_t kh, uint32_t kw, const float *biases)
{
    TEMP_QUERY(j->flags);
    CHECK(check_job(j, kh, kw));
    double *K = malloc((size_t)kh * kw * sizeof(double) * (size_t)j->channels);
    if (!K)
        return kvImageMemoryAllocationError;
    double full[4] = {0};
    for (int c = 0; c < j->channels; ++c)
        for (uint32_t i = 0; i < kh * kw; ++i) {
            K[(size_t)c * kh * kw + i] = kernels[c][i];
            full[c] += kernels[c][i];
        }
    for (vImagePixelCount y = 0; y < j->dest->height; ++y)
        for (vImagePixelCount x = 0; x < j->dest->width; ++x)
            for (int c = 0; c < j->channels; ++c) {
                int copy = 0;
                double used = 0, sum = weighted(j, K + (size_t)c * kh * kw, kh, kw, x, y, c, &copy, &used);
                if (copy) {
                    copy_through(j, x, y, c);
                    continue;
                }
                double v = sum + biases[c];
                if ((j->flags & kvImageTruncateKernel) && used != full[c] && used != 0)
                    v = fmaf((float)sum, (float)full[c] / (float)used, biases[c]);
                store(j, x, y, c, j->out == F8 || j->out == F16U ? floor(v + 0.5) : v);
            }
    free(K);
    return kvImageNoError;
}

/* MARK: - Entry points */

static void backgrounds8(const uint8_t *bg, int n, double *out)
{
    for (int c = 0; c < n; ++c)
        out[c] = bg ? bg[c] : 0;
}

static void backgroundsF(const float *bg, int n, double *out)
{
    for (int c = 0; c < n; ++c)
        out[c] = bg ? bg[c] : 0;
}

static void backgrounds16F(const uint16_t *bg, int n, double *out)
{
    for (int c = 0; c < n; ++c)
        out[c] = bg ? half_to_float(bg[c]) : 0;
}

#define JOB(n, IN, OUT)                                                                                  \
    Job j = {src, dest, ox, oy, n, IN, OUT, flags, bg, 1}

vImage_Error vImageConvolveWithBias_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                            vImagePixelCount ox, vImagePixelCount oy, const int16_t *kernel,
                                            uint32_t kh, uint32_t kw, int32_t divisor, int32_t bias,
                                            Pixel_8 background, vImage_Flags flags)
{
    double bg[1];
    backgrounds8(&background, 1, bg);
    JOB(1, F8, F8);
    const int16_t *k[1] = {kernel};
    return convolve_int(&j, k, kh, kw, &divisor, &bias, 0);
}

vImage_Error vImageConvolve_Planar8(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                    vImagePixelCount ox, vImagePixelCount oy, const int16_t *kernel, uint32_t kh,
                                    uint32_t kw, int32_t divisor, Pixel_8 background, vImage_Flags flags)
{
    /* (rounded to nearest: the bias is half the divisor) */
    int32_t d = divisor ? divisor : 1;
    return vImageConvolveWithBias_Planar8(src, dest, temp, ox, oy, kernel, kh, kw, divisor, d / 2, background, flags);
}

vImage_Error vImageConvolveWithBias_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                             vImagePixelCount ox, vImagePixelCount oy, const int16_t *kernel,
                                             uint32_t kh, uint32_t kw, int32_t divisor, int32_t bias,
                                             const Pixel_8888 background, vImage_Flags flags)
{
    double bg[4];
    backgrounds8(background, 4, bg);
    JOB(4, F8, F8);
    const int16_t *k[4] = {kernel, kernel, kernel, kernel};
    const int32_t d[4] = {divisor, divisor, divisor, divisor}, b[4] = {bias, bias, bias, bias};
    return convolve_int(&j, k, kh, kw, d, b, 0);
}

vImage_Error vImageConvolve_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                     vImagePixelCount ox, vImagePixelCount oy, const int16_t *kernel, uint32_t kh,
                                     uint32_t kw, int32_t divisor, const Pixel_8888 background, vImage_Flags flags)
{
    int32_t d = divisor ? divisor : 1;
    return vImageConvolveWithBias_ARGB8888(src, dest, temp, ox, oy, kernel, kh, kw, divisor, d / 2, background, flags);
}

vImage_Error vImageConvolveMultiKernel_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                vImagePixelCount ox, vImagePixelCount oy, const int16_t *kernels[4],
                                                uint32_t kh, uint32_t kw, const int32_t divisors[4],
                                                const int32_t biases[4], const Pixel_8888 background,
                                                vImage_Flags flags)
{
    double bg[4];
    backgrounds8(background, 4, bg);
    JOB(4, F8, F8);
    return convolve_int(&j, kernels, kh, kw, divisors, biases, 0);
}

#define FLOAT_CONVOLVE(name, n, IN, OUT, BGT, BGFN)                                                      \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImagePixelCount ox, \
                      vImagePixelCount oy, const float *kernel, uint32_t kh, uint32_t kw, float bias, BGT background, \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        double bg[4];                                                                                    \
        BGFN(BG_PTR(background), n, bg);                                                                 \
        JOB(n, IN, OUT);                                                                                 \
        const float *k[4] = {kernel, kernel, kernel, kernel};                                            \
        const float b[4] = {bias, bias, bias, bias};                                                     \
        return convolve_float(&j, k, kh, kw, b);                                                         \
    }
#define BG_PTR(b) _Generic((b), Pixel_F: &(b), Pixel_16F: &(b), default: (b))

FLOAT_CONVOLVE(vImageConvolveWithBias_PlanarF, 1, FF, FF, Pixel_F, backgroundsF)
FLOAT_CONVOLVE(vImageConvolveWithBias_Planar16F, 1, F16F, F16F, Pixel_16F, backgrounds16F)
FLOAT_CONVOLVE(vImageConvolveWithBias_ARGBFFFF, 4, FF, FF, const Pixel_FFFF, backgroundsF)
FLOAT_CONVOLVE(vImageConvolveWithBias_ARGB16F, 4, F16F, F16F, const Pixel_ARGB_16F, backgrounds16F)
FLOAT_CONVOLVE(vImageConvolveFloatKernel_ARGB8888, 4, F8, F8, const Pixel_8888, backgrounds8)

vImage_Error vImageConvolve_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                    vImagePixelCount ox, vImagePixelCount oy, const float *kernel, uint32_t kh,
                                    uint32_t kw, Pixel_F background, vImage_Flags flags)
{
    return vImageConvolveWithBias_PlanarF(src, dest, temp, ox, oy, kernel, kh, kw, 0, background, flags);
}
vImage_Error vImageConvolve_Planar16F(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                      vImagePixelCount ox, vImagePixelCount oy, const float *kernel, uint32_t kh,
                                      uint32_t kw, Pixel_16F background, vImage_Flags flags)
{
    return vImageConvolveWithBias_Planar16F(src, dest, temp, ox, oy, kernel, kh, kw, 0, background, flags);
}
vImage_Error vImageConvolve_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                     vImagePixelCount ox, vImagePixelCount oy, const float *kernel, uint32_t kh,
                                     uint32_t kw, const Pixel_FFFF background, vImage_Flags flags)
{
    return vImageConvolveWithBias_ARGBFFFF(src, dest, temp, ox, oy, kernel, kh, kw, 0, background, flags);
}
vImage_Error vImageConvolve_ARGB16F(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                    vImagePixelCount ox, vImagePixelCount oy, const float *kernel, uint32_t kh,
                                    uint32_t kw, const Pixel_ARGB_16F background, vImage_Flags flags)
{
    return vImageConvolveWithBias_ARGB16F(src, dest, temp, ox, oy, kernel, kh, kw, 0, background, flags);
}

vImage_Error vImageConvolveMultiKernel_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                vImagePixelCount ox, vImagePixelCount oy, const float *kernels[4],
                                                uint32_t kh, uint32_t kw, const float biases[4],
                                                const Pixel_FFFF background, vImage_Flags flags)
{
    double bg[4];
    backgroundsF(background, 4, bg);
    JOB(4, FF, FF);
    return convolve_float(&j, kernels, kh, kw, biases);
}

/* MARK: - Box and tent */

static vImage_Error box_or_tent(Job *j, uint32_t kh, uint32_t kw, int tent)
{
    TEMP_QUERY(j->flags);
    CHECK(check_job(j, kh, kw));
    int16_t *k = malloc((size_t)kh * kw * sizeof(int16_t));
    if (!k)
        return kvImageMemoryAllocationError;
    int32_t sum = 0;
    for (uint32_t i = 0; i < kh; ++i)
        for (uint32_t x = 0; x < kw; ++x) {
            int32_t wy = tent ? (int32_t)(i <= kh / 2 ? i + 1 : kh - i) : 1;
            int32_t wx = tent ? (int32_t)(x <= kw / 2 ? x + 1 : kw - x) : 1;
            k[i * kw + x] = (int16_t)(wy * wx);
            sum += wy * wx;
        }
    const int16_t *ks[4] = {k, k, k, k};
    const int32_t d[4] = {sum, sum, sum, sum}, b[4] = {sum / 2, sum / 2, sum / 2, sum / 2};
    vImage_Error e = convolve_int(j, ks, kh, kw, d, b, !tent);
    free(k);
    return e;
}

#define BOX_TENT(name, n, BGT, tent)                                                                     \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImagePixelCount ox, \
                      vImagePixelCount oy, uint32_t kh, uint32_t kw, BGT background, vImage_Flags flags) \
    {                                                                                                    \
        double bg[4];                                                                                    \
        backgrounds8(BG8(background), n, bg);                                                            \
        JOB(n, F8, F8);                                                                                  \
        return box_or_tent(&j, kh, kw, tent);                                                            \
    }
#define BG8(b) _Generic((b), Pixel_8: &(b), default: (b))
BOX_TENT(vImageBoxConvolve_Planar8, 1, Pixel_8, 0)
BOX_TENT(vImageBoxConvolve_ARGB8888, 4, const Pixel_8888, 0)
BOX_TENT(vImageTentConvolve_Planar8, 1, Pixel_8, 1)
BOX_TENT(vImageTentConvolve_ARGB8888, 4, const Pixel_8888, 1)

/* MARK: - Separable */

static vImage_Error separable(Job *j, const float *kx, uint32_t nx, const float *ky, uint32_t ny, float scale, float bias)
{
    TEMP_QUERY(j->flags);
    CHECK(check_job(j, ny, nx));
    float *k = malloc((size_t)nx * ny * sizeof(float));
    if (!k)
        return kvImageMemoryAllocationError;
    for (uint32_t i = 0; i < ny; ++i)
        for (uint32_t x = 0; x < nx; ++x)
            k[i * nx + x] = ky[i] * kx[x] * scale;
    const float *ks[4] = {k, k, k, k};
    const float b[4] = {bias, bias, bias, bias};
    vImage_Error e = convolve_float(j, ks, ny, nx, b);
    free(k);
    return e;
}

#define SEPARABLE(name, n, IN, OUT, BGT, BGFN)                                                           \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImagePixelCount ox, \
                      vImagePixelCount oy, const float *kx, uint32_t nx, const float *ky, uint32_t ny, float bias, \
                      BGT background, vImage_Flags flags)                                                 \
    {                                                                                                    \
        double bg[4];                                                                                    \
        BGFN(n, background, bg);                                                                         \
        JOB(n, IN, OUT);                                                                                 \
        return separable(&j, kx, nx, ky, ny, 1, bias);                                                   \
    }
#define BG_ONE(n, v, out) ((out)[0] = (double)(v))
#define BG_HALF(n, v, out) ((out)[0] = half_to_float(v))
#define BG_8888(n, v, out) backgrounds8((v), (n), (out))
SEPARABLE(vImageSepConvolve_Planar8, 1, F8, F8, Pixel_16U, BG_ONE)
SEPARABLE(vImageSepConvolve_PlanarF, 1, FF, FF, Pixel_F, BG_ONE)
SEPARABLE(vImageSepConvolve_Planar16F, 1, F16F, F16F, Pixel_16F, BG_HALF)
SEPARABLE(vImageSepConvolve_Planar16U, 1, F16U, F16U, Pixel_16U, BG_ONE)
SEPARABLE(impl_SepConvolve_ARGB8888, 4, F8, F8, const Pixel_8888, BG_8888)

/* (Apple's four-channel separable convolution has no truncated-kernel mode) */
vImage_Error vImageSepConvolve_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                        vImagePixelCount ox, vImagePixelCount oy, const float *kx, uint32_t nx,
                                        const float *ky, uint32_t ny, float bias, const Pixel_8888 background,
                                        vImage_Flags flags)
{
    if (flags & kvImageTruncateKernel)
        return kvImageUnknownFlagsBit;
    return impl_SepConvolve_ARGB8888(src, dest, temp, ox, oy, kx, nx, ky, ny, bias, background, flags);
}

vImage_Error vImageSepConvolve_Planar8to16U(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                            vImagePixelCount ox, vImagePixelCount oy, const float *kx, uint32_t nx,
                                            const float *ky, uint32_t ny, float scale, float bias, Pixel_8 background,
                                            vImage_Flags flags)
{
    double bg[1] = {background};
    JOB(1, F8, F16U);
    j.copyScale = scale;
    return separable(&j, kx, nx, ky, ny, scale, bias);
}

/* MARK: - Richardson-Lucy deconvolution */

/* e[i+1] = e[i] x (psf0 * (e[0] / (psf1 * e[i]))), in float; each convolution uses the
   edging mode on the whole image */
static vImage_Error richardson_lucy(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox,
                                    vImagePixelCount oy, const float *k0, const float *k1, uint32_t kh, uint32_t kw,
                                    uint32_t kh2, uint32_t kw2, uint32_t iterations, int channels, enum Format f,
                                    const double *bg, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !dest || !src->data || !dest->data || !k0)
        return kvImageNullPointerArgument;
    if (!k1) {
        k1 = k0;
        kh2 = kh;
        kw2 = kw;
    }
    size_t w = src->width, h = src->height, n = w * h * (size_t)channels;
    float *e0 = malloc(n * sizeof(float)), *e = malloc(n * sizeof(float)), *t = malloc(n * sizeof(float));
    if (!e0 || !e || !t) {
        free(e0);
        free(e);
        free(t);
        return kvImageMemoryAllocationError;
    }
    for (size_t y = 0; y < h; ++y)
        for (size_t x = 0; x < w * (size_t)channels; ++x)
            e0[y * w * channels + x] = (float)load(CROW(src, y), f, x);
    memcpy(e, e0, n * sizeof(float));
    vImage_Buffer eb = {e, h, w, w * channels * sizeof(float)}, tb = {t, h, w, w * channels * sizeof(float)};
    vImage_Flags edge = flags & EDGES;
    for (uint32_t it = 0; it < iterations; ++it) {
        /* t = psf1 * e */
        Job j1 = {&eb, &tb, 0, 0, channels, FF, FF, edge, bg, 1};
        const float *ks1[4] = {k1, k1, k1, k1}, *ks0[4] = {k0, k0, k0, k0};
        const float zero[4] = {0};
        CHECK(convolve_float(&j1, ks1, kh2, kw2, zero));
        for (size_t i = 0; i < n; ++i)
            t[i] = t[i] != 0 ? e0[i] / t[i] : 0;
        /* e *= psf0 * t */
        float *u = malloc(n * sizeof(float));
        if (!u)
            break;
        vImage_Buffer ub = {u, h, w, w * channels * sizeof(float)};
        Job j0 = {&tb, &ub, 0, 0, channels, FF, FF, edge, bg, 1};
        CHECK(convolve_float(&j0, ks0, kh, kw, zero));
        for (size_t i = 0; i < n; ++i)
            e[i] *= u[i];
        free(u);
    }
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int c = 0; c < channels; ++c) {
                float v = e[((y + oy) * w + x + ox) * (size_t)channels + c];
                uint8_t *row = ROW(dest, y);
                if (f == F8)
                    row[x * channels + c] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5f);
                else
                    ((float *)row)[x * channels + c] = v;
            }
    free(e0);
    free(e);
    free(t);
    return kvImageNoError;
}

static float *float_kernel(const int16_t *k, uint32_t n, int32_t divisor)
{
    float *f = malloc(n * sizeof(float));
    if (f)
        for (uint32_t i = 0; i < n; ++i)
            f[i] = (float)k[i] / (float)(divisor ? divisor : 1);
    return f;
}

vImage_Error vImageRichardsonLucyDeConvolve_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                    vImagePixelCount ox, vImagePixelCount oy, const float *kernel,
                                                    const float *kernel2, uint32_t kh, uint32_t kw, uint32_t kh2,
                                                    uint32_t kw2, Pixel_F background, uint32_t iterations,
                                                    vImage_Flags flags)
{
    double bg[1] = {background};
    return richardson_lucy(src, dest, ox, oy, kernel, kernel2, kh, kw, kh2, kw2, iterations, 1, FF, bg, flags);
}

vImage_Error vImageRichardsonLucyDeConvolve_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp,
                                                     vImagePixelCount ox, vImagePixelCount oy, const float *kernel,
                                                     const float *kernel2, uint32_t kh, uint32_t kw, uint32_t kh2,
                                                     uint32_t kw2, const Pixel_FFFF background, uint32_t iterations,
                                                     vImage_Flags flags)
{
    double bg[4];
    backgroundsF(background, 4, bg);
    return richardson_lucy(src, dest, ox, oy, kernel, kernel2, kh, kw, kh2, kw2, iterations, 4, FF, bg, flags);
}

#define RL8(name, n, BGT)                                                                                \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImagePixelCount ox, \
                      vImagePixelCount oy, const int16_t *kernel, const int16_t *kernel2, uint32_t kh, uint32_t kw, \
                      uint32_t kh2, uint32_t kw2, int32_t divisor, int32_t divisor2, BGT background,       \
                      uint32_t iterations, vImage_Flags flags)                                           \
    {                                                                                                    \
        double bg[4];                                                                                    \
        backgrounds8(BG8(background), n, bg);                                                            \
        if (!kernel)                                                                                     \
            return kvImageNullPointerArgument;                                                           \
        float *k0 = float_kernel(kernel, kh * kw, divisor),                                              \
              *k1 = kernel2 ? float_kernel(kernel2, kh2 * kw2, divisor2) : NULL;                         \
        vImage_Error e = richardson_lucy(src, dest, ox, oy, k0, k1, kh, kw, kh2, kw2, iterations, n, F8, bg, flags); \
        free(k0);                                                                                        \
        free(k1);                                                                                        \
        return e;                                                                                        \
    }
RL8(vImageRichardsonLucyDeConvolve_Planar8, 1, Pixel_8)
RL8(vImageRichardsonLucyDeConvolve_ARGB8888, 4, const Pixel_8888)

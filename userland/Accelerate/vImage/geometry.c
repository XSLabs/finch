/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's geometry (Geometry.h): reflection and 90-degree rotation (exact copies),
 * shears, scaling, rotation, affine and perspective warps, and resampling filters, in
 * every format the header lists.
 *
 * The shears are the resampling core, as in Apple's vImage, and match it: each line is
 * resampled with a normalized Lanczos kernel (3 lobes, or 5 with
 * kvImageHighQualityResampling), widened when shrinking, at sample positions rounded
 * to 64 phases a pixel (32 below half scale, and so on), nearest for horizontal lines
 * and downward for vertical ones. Scaling is two shears without slope, edges extended;
 * rotation is Apple's exact quarter turn then three shears. Those agree with Apple's in
 * floating point to rounding; Apple's 8- and 16-bit paths use fixed-point weights and
 * may differ from Finch's by one. The perspective warp (pixel centres on integers)
 * matches Apple's; the affine warp samples the inverse map with the 2D kernel, within
 * about a level of Apple's, which decomposes it into shears. Coordinates follow the
 * header: the origin is at the bottom left of each image.
 */
#include "common.h"

/* MARK: - Formats */

enum Sample { U8, U16, S16, F32, F16, X10 };

typedef struct {
    int channels;
    enum Sample sample;
} Format;

static const Format P8 = {1, U8}, P16S = {1, S16}, P16U = {1, U16}, PF = {1, F32}, A8888 = {4, U8}, A16U = {4, U16},
                    A16S = {4, S16}, AFFFF = {4, F32}, P16F = {1, F16}, C16F = {2, F16}, A16F = {4, F16},
                    C8 = {2, U8}, C16U = {2, U16}, C16S = {2, S16}, X2101010 = {3, X10};

static inline size_t pixel_size(Format f)
{
    switch (f.sample) {
    case U8:
        return (size_t)f.channels;
    case U16:
    case S16:
    case F16:
        return 2 * (size_t)f.channels;
    case F32:
        return 4 * (size_t)f.channels;
    default:
        return 4;
    }
}

static inline float get(const vImage_Buffer *b, Format f, long x, long y, int c)
{
    const uint8_t *row = CROW(b, y);
    switch (f.sample) {
    case U8:
        return row[x * f.channels + c];
    case U16:
        return ((const uint16_t *)row)[x * f.channels + c];
    case S16:
        return ((const int16_t *)row)[x * f.channels + c];
    case F32:
        return ((const float *)row)[x * f.channels + c];
    case F16:
        return half_to_float(((const uint16_t *)row)[x * f.channels + c]);
    default:
        return (float)((((const uint32_t *)row)[x] >> (20 - 10 * c)) & 0x3ff);
    }
}

static inline void put(const vImage_Buffer *b, Format f, long x, long y, const float *v)
{
    uint8_t *row = ROW(b, y);
    if (f.sample == X10) {
        uint32_t p = 0;
        for (int c = 0; c < 3; ++c) {
            long q = lrintf(v[c]);
            p |= (uint32_t)(q < 0 ? 0 : q > 1023 ? 1023 : q) << (20 - 10 * c);
        }
        ((uint32_t *)row)[x] = p;
        return;
    }
    for (int c = 0; c < f.channels; ++c) {
        size_t i = (size_t)x * f.channels + c;
        switch (f.sample) {
        case U8:
            row[i] = sat8(lrintf(v[c]));
            break;
        case U16:
            ((uint16_t *)row)[i] = sat16u(lrintf(v[c]));
            break;
        case S16:
            ((int16_t *)row)[i] = sat16s(lrintf(v[c]));
            break;
        case F32:
            ((float *)row)[i] = v[c];
            break;
        default:
            ((uint16_t *)row)[i] = float_to_half(v[c]);
            break;
        }
    }
}

/* background colours, as floats per channel */
static void bg_u8(const uint8_t *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? p[c] : 0;
}
static void bg_u16(const uint16_t *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? p[c] : 0;
}
static void bg_s16(const int16_t *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? p[c] : 0;
}
static void bg_f32(const float *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? p[c] : 0;
}
static void bg_f16(const uint16_t *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? half_to_float(p[c]) : 0;
}
static void bg_x10(const uint32_t *p, int n, float *o)
{
    for (int c = 0; c < n; ++c)
        o[c] = p ? (float)((*p >> (20 - 10 * c)) & 0x3ff) : 0;
}

/* MARK: - Reflection and 90-degree rotation */

static vImage_Error reflect(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, int horizontal,
                            vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    size_t ps = pixel_size(f);
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, horizontal ? y : dest->height - 1 - y);
        uint8_t *out = ROW(dest, y);
        if (!horizontal)
            memcpy(out, in, dest->width * ps);
        else
            for (vImagePixelCount x = 0; x < dest->width; ++x)
                memcpy(out + x * ps, in + (dest->width - 1 - x) * ps, ps);
    }
    return kvImageNoError;
}

static vImage_Error rotate90(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, uint8_t rotation,
                             const float *bg, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !dest || !src->data || !dest->data)
        return kvImageNullPointerArgument;
    if (rotation > 3)
        return kvImageInvalidParameter;
    long sw = (long)src->width, sh = (long)src->height, dw = (long)dest->width, dh = (long)dest->height;
    size_t ps = pixel_size(f);
    uint8_t fill[16];
    vImage_Buffer one = {fill, 1, 1, sizeof(fill)};
    put(&one, f, 0, 0, bg);
    /* about integer centres, as Apple's: (w / 2, h / 2) rounded down, except where noted */
    long hx = sw / 2, hy = sh / 2, lx = (sw - 1) / 2, ly = (sh - 1) / 2, cx = dw / 2, cy = dh / 2;
    for (long y = 0; y < dh; ++y)
        for (long x = 0; x < dw; ++x) {
            long u = x - cx, v = y - cy, sx, sy;
            switch (rotation) {
            case 0: /* the corners' offset, halved and rounded down */
                sx = x + (long)floor((sw - dw) / 2.0);
                sy = y + (long)floor((sh - dh) / 2.0);
                break;
            case 1: /* 90 degrees counterclockwise */
                sx = hx - v, sy = ly + u;
                break;
            case 2:
                sx = hx - u, sy = ly - v;
                break;
            default:
                sx = lx + v, sy = hy - u;
                break;
            }
            uint8_t *out = ROW(dest, y) + (size_t)x * ps;
            if (sx < 0 || sy < 0 || sx >= sw || sy >= sh)
                memcpy(out, fill, ps);
            else
                memcpy(out, CROW(src, sy) + (size_t)sx * ps, ps);
        }
    return kvImageNoError;
}

/* MARK: - Resampling kernels */

#define FILTER_MAGIC 0x76524631u

typedef void (*KernelFunc)(const float *x, float *y, unsigned long count, void *userData);

typedef struct {
    uint32_t magic;
    float scale, width;
    KernelFunc func;
    void *userData;
    int highQuality;
} Filter;

static inline double sinc(double x) { return fabs(x) < 1e-9 ? 1 : sin(M_PI * x) / (M_PI * x); }

/* the kernel weight at distance d (in destination pixels) */
static double kernel_weight(const Filter *k, double d)
{
    if (k && k->func) {
        float xv = (float)d, yv = 0;
        if (fabs(d) > k->width)
            return 0;
        k->func(&xv, &yv, 1, k->userData);
        return yv;
    }
    double lobes = k && k->highQuality ? 5 : 3;
    if (fabs(d) >= lobes)
        return 0;
    return sinc(d) * sinc(d / lobes);
}

ResamplingFilter vImageNewResamplingFilter(float scale, vImage_Flags flags)
{
    Filter *k = calloc(1, sizeof(*k));
    if (!k)
        return NULL;
    k->magic = FILTER_MAGIC;
    k->scale = scale;
    k->highQuality = (flags & kvImageHighQualityResampling) != 0;
    k->width = k->highQuality ? 5 : 3;
    return k;
}

void vImageDestroyResamplingFilter(ResamplingFilter filter) { free(filter); }

size_t vImageGetResamplingFilterSize(float scale, KernelFunc kernelFunc, float kernelWidth, vImage_Flags flags)
{
    return sizeof(Filter);
}

vImage_Error vImageNewResamplingFilterForFunctionUsingBuffer(ResamplingFilter filter, float scale, KernelFunc kernelFunc,
                                                             float kernelWidth, void *userData, vImage_Flags flags)
{
    if (!filter)
        return kvImageNullPointerArgument;
    Filter *k = (Filter *)filter;
    memset(k, 0, sizeof(*k));
    k->magic = FILTER_MAGIC;
    k->scale = scale;
    k->func = kernelFunc;
    k->userData = userData;
    k->highQuality = (flags & kvImageHighQualityResampling) != 0;
    k->width = kernelFunc ? kernelWidth : (k->highQuality ? 5 : 3);
    return kvImageNoError;
}

vImagePixelCount vImageGetResamplingFilterExtent(ResamplingFilter filter, vImage_Flags flags)
{
    const Filter *k = filter;
    if (!k)
        return 0;
    float s = fabsf(k->scale);
    return (vImagePixelCount)floorf(k->width / (s < 1 && s > 0 ? s : 1));
}

/* MARK: - 1D resampling */

/* out[i] for i in [0, n): the source line sampled at position p0 + i * step (in source
   pixels), filtered for a scale (dest per source) below 1; get(j) reads source sample j,
   and returns 0 with *outside set beyond the line */
typedef float (*LineGet)(void *ctx, long j, int c, int *outside);

static void resample_line(LineGet getter, void *ctx, int channels, double p0, double step, long n, double scale,
                          double qbias, const Filter *k, const float *bg, int extend, long len, float *out)
{
    double widen = fabs(scale) < 1 && scale != 0 ? 1 / fabs(scale) : 1;
    /* Apple's kernels come in 64 phases a pixel, halved for each halving of a scale below 1 */
    double phases = 64;
    if (widen > 1) {
        int e;
        double m = frexp(1 / widen, &e);
        phases = ldexp(64, m > 0.5 ? e : e - 1);
    }
    double radius = (k && k->func ? k->width : k && k->highQuality ? 5 : 3) * widen;
    for (long i = 0; i < n; ++i) {
        double p = p0 + step * (double)i;
        p = floor(p * phases + qbias) / phases;
        long first = (long)floor(p - radius) + 1, last = (long)floor(p + radius);
        double sum[4] = {0}, wsum = 0;
        for (long j = first; j <= last; ++j) {
            double w = kernel_weight(k, ((double)j - p) / widen);
            if (w == 0)
                continue;
            long jj = j;
            int bgSample = 0;
            if (jj < 0 || jj >= len) {
                if (extend)
                    jj = jj < 0 ? 0 : len - 1;
                else
                    bgSample = 1;
            }
            for (int c = 0; c < channels; ++c) {
                int outside = 0;
                sum[c] += w * (bgSample ? bg[c] : getter(ctx, jj, c, &outside));
            }
            wsum += w;
        }
        for (int c = 0; c < channels; ++c)
            out[i * channels + c] = wsum != 0 ? (float)(sum[c] / wsum) : (extend ? 0 : bg[c]);
    }
}

typedef struct {
    const vImage_Buffer *b;
    Format f;
    long fixed; /* the row (horizontal lines) or column (vertical lines) */
    const float *plane; /* a float intermediate: rows of width*channels */
    long planeWidth;
    int vertical;
} LineCtx;

static float line_get(void *v, long j, int c, int *outside)
{
    LineCtx *l = v;
    if (l->plane)
        return l->vertical ? l->plane[(size_t)j * l->planeWidth * l->f.channels + (size_t)l->fixed * l->f.channels + c]
                           : l->plane[(size_t)l->fixed * l->planeWidth * l->f.channels + (size_t)j * l->f.channels + c];
    return l->vertical ? get(l->b, l->f, l->fixed, j, c) : get(l->b, l->f, j, l->fixed, c);
}

/* MARK: - Shears: each line resampled at a scale, translated and sheared */

static vImage_Error shear(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, vImagePixelCount ox,
                          vImagePixelCount oy, double translate, double slope, ResamplingFilter filter,
                          const float *bg, int vertical, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !dest || !src->data || !dest->data || !filter)
        return kvImageNullPointerArgument;
    if (vertical ? ox + dest->width > src->width : oy + dest->height > src->height)
        return kvImageBufferSizeMismatch;
    const Filter *k = filter;
    double s = k->scale ? k->scale : 1;
    int ch = f.channels, extend = (flags & kvImageEdgeExtend) != 0;
    long lines = vertical ? (long)dest->width : (long)dest->height, n = vertical ? (long)dest->height : (long)dest->width;
    float *line = malloc((size_t)n * ch * sizeof(float));
    if (!line)
        return kvImageMemoryAllocationError;
    for (long i = 0; i < lines; ++i) {
        /* the line's distance from the bottom (horizontal) or left (vertical) edge of the
           region of interest; destination position d along the line (plus the ROI start)
           maps to source position (d - offset) / s, in y-up coordinates when vertical */
        double across = vertical ? (double)i + 0.5 : (double)dest->height - ((double)i + 0.5);
        double offset = translate + slope * across;
        long len = vertical ? (long)src->height : (long)src->width;
        double p0, step = 1 / s;
        if (vertical)
            p0 = (double)(oy + dest->height) - ((double)dest->height - 0.5 - offset) / s - 0.5;
        else
            p0 = (double)ox + (0.5 - offset) / s - 0.5;
        LineCtx l = {src, f, vertical ? i + (long)ox : i + (long)oy, NULL, 0, vertical};
        resample_line(line_get, &l, ch, p0, step, n, s, vertical ? 0 : 0.5, k, bg, extend, len, line);
        for (long j = 0; j < n; ++j)
            put(dest, f, vertical ? i : j, vertical ? j : i, line + (size_t)j * ch);
    }
    free(line);
    return kvImageNoError;
}

/* MARK: - Scale: Apple's, as two shears without slope, edges extended */

static vImage_Error scale(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, vImage_Flags flags)
{
    if (!dest || !dest->height || !dest->width)
        return 0;
    if (!src || !src->height || !src->width)
        return kvImageBufferSizeMismatch;
    size_t ps = pixel_size(f);
    double sx = (double)dest->width / src->width, sy = (double)dest->height / src->height;
    /* the smaller intermediate: horizontal pass first (src height x dest width) or vertical */
    int horizontalFirst = src->height * dest->width < src->width * dest->height;
    vImage_Buffer t = horizontalFirst ? (vImage_Buffer){NULL, src->height, dest->width, dest->width * ps}
                                      : (vImage_Buffer){NULL, dest->height, src->width, src->width * ps};
    if (flags & kvImageGetTempBufferSize)
        return (vImage_Error)(sizeof(Filter) + t.height * t.rowBytes + 32);
    if (!src->data || !dest->data)
        return kvImageNullPointerArgument;
    float one[4] = {1, 1, 1, 1};
    vImage_Flags edge = flags | kvImageEdgeExtend;
    int hq = (flags & kvImageHighQualityResampling) != 0;
    Filter kx = {FILTER_MAGIC, (float)sx, hq ? 5 : 3, NULL, NULL, hq}, ky = {FILTER_MAGIC, (float)sy, hq ? 5 : 3, NULL, NULL, hq};
    double down = (float)(sy * ((double)src->height - (double)dest->height));
    if (src->height == dest->height && src->width == dest->width) {
        for (vImagePixelCount y = 0; y < dest->height; ++y)
            memmove(ROW(dest, y), CROW(src, y), dest->width * ps);
        return kvImageNoError;
    }
    if (src->height == dest->height)
        return shear(src, dest, f, 0, 0, 0, 0, &kx, one, 0, edge);
    if (src->width == dest->width)
        return shear(src, dest, f, 0, 0, down, 0, &ky, one, 1, edge);
    t.data = malloc(t.height * t.rowBytes + 1);
    if (!t.data)
        return kvImageMemoryAllocationError;
    vImage_Error e = horizontalFirst ? shear(src, &t, f, 0, 0, 0, 0, &kx, one, 0, edge)
                                     : shear(src, &t, f, 0, 0, down, 0, &ky, one, 1, edge);
    if (!e)
        e = horizontalFirst ? shear(&t, dest, f, 0, 0, down, 0, &ky, one, 1, edge)
                            : shear(&t, dest, f, 0, 0, 0, 0, &kx, one, 0, edge);
    free(t.data);
    return e;
}

/* MARK: - Affine and perspective warps */

/* dest (x', y') = (x, y) M + t, bottom-left origins; each dest pixel centre is mapped back
   and the source sampled with the separable kernel there */
static vImage_Error affine(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, double a, double b,
                           double c, double d, double tx, double ty, const float *bg, vImage_Flags flags)
{
    if (flags & kvImageGetTempBufferSize)
        return 0;
    if (!src || !dest || !src->data || !dest->data)
        return kvImageNullPointerArgument;
    double det = a * d - b * c;
    if (det == 0)
        return kvImageInvalidParameter;
    double ia = d / det, ib = -b / det, ic = -c / det, id = a / det;
    double sxScale = sqrt(a * a + b * b), syScale = sqrt(c * c + d * d);
    double wx = sxScale < 1 && sxScale > 0 ? 1 / sxScale : 1, wy = syScale < 1 && syScale > 0 ? 1 / syScale : 1;
    double lobes = (flags & kvImageHighQualityResampling) ? 5 : 3;
    Filter k = {FILTER_MAGIC, 1, (float)lobes, NULL, NULL, (flags & kvImageHighQualityResampling) != 0};
    int ch = f.channels, extend = (flags & kvImageEdgeExtend) != 0;
    long sw = (long)src->width, sh = (long)src->height;
    for (long y = 0; y < (long)dest->height; ++y)
        for (long x = 0; x < (long)dest->width; ++x) {
            double xp = x + 0.5 - tx, yp = ((double)dest->height - y - 0.5) - ty;
            double sxc = xp * ia + yp * ic, syc = xp * ib + yp * id; /* source, bottom-left */
            double px = sxc - 0.5, py = (double)sh - syc - 0.5;      /* source pixel coordinates */
            long x0 = (long)floor(px - lobes * wx) + 1, x1 = (long)floor(px + lobes * wx);
            long y0 = (long)floor(py - lobes * wy) + 1, y1 = (long)floor(py + lobes * wy);
            double sum[4] = {0}, wsum = 0;
            for (long j = y0; j <= y1; ++j) {
                double wyv = kernel_weight(&k, ((double)j - py) / wy);
                if (wyv == 0)
                    continue;
                for (long i = x0; i <= x1; ++i) {
                    double w = wyv * kernel_weight(&k, ((double)i - px) / wx);
                    if (w == 0)
                        continue;
                    long ii = i, jj = j;
                    int outside = ii < 0 || jj < 0 || ii >= sw || jj >= sh;
                    if (outside && extend) {
                        ii = ii < 0 ? 0 : ii >= sw ? sw - 1 : ii;
                        jj = jj < 0 ? 0 : jj >= sh ? sh - 1 : jj;
                        outside = 0;
                    }
                    for (int cc = 0; cc < ch; ++cc)
                        sum[cc] += w * (outside ? bg[cc] : get(src, f, ii, jj, cc));
                    wsum += w;
                }
            }
            float v[4];
            for (int cc = 0; cc < ch; ++cc)
                v[cc] = wsum != 0 ? (float)(sum[cc] / wsum) : bg[cc];
            put(dest, f, x, y, v);
        }
    return kvImageNoError;
}

/* rotation (counterclockwise, about the centres) is Apple's: the nearest quarter turn
   exactly, then the rest (within 45 degrees) as three shears through two canvases,
   x += -tan(angle / 2) y, y += sin(angle) x, x += -tan(angle / 2) y */
static vImage_Error rotate(const vImage_Buffer *src, const vImage_Buffer *dest, Format f, float angle, const float *bg,
                           vImage_Flags flags)
{
    if (!dest || !dest->height || !dest->width)
        return 0;
    if (!src || !src->height)
        return (flags & kvImageEdgeExtend) ? kvImageBufferSizeMismatch : 0;
    size_t ps = pixel_size(f);
    double turns = (double)angle / (2 * M_PI), frac = turns - floor(turns);
    int n = (int)(frac * 4 + 0.5), quarter = n & 3;
    vImagePixelCount hr = src->height, wr = src->width;
    if (quarter) {
        frac -= quarter * 0.25;
        angle = (float)(frac * 2 * M_PI);
        if (quarter & 1)
            hr = src->width, wr = src->height;
    }
    double t = tan((double)(angle * 0.5f)), wa = hr * fabs(t) + wr, b = sin((double)angle);
    vImagePixelCount wai = (vImagePixelCount)ceil(wa);
    if (flags & kvImageGetTempBufferSize)
        return (vImage_Error)(sizeof(Filter) + (quarter ? hr * wr * ps : 0) + (hr + dest->height) * wai * ps);
    if (!src->data || !dest->data)
        return kvImageNullPointerArgument;
    Filter k = {FILTER_MAGIC, 1, (flags & kvImageHighQualityResampling) ? 5 : 3, NULL, NULL,
                (flags & kvImageHighQualityResampling) != 0};
    uint8_t *mem = malloc((quarter ? hr * wr * ps : 0) + (hr + dest->height) * wai * ps + 1);
    if (!mem)
        return kvImageMemoryAllocationError;
    vImage_Buffer r = *src, a = {mem, hr, wai, wai * ps}, bb = {mem + hr * wai * ps, dest->height, wai, wai * ps};
    vImage_Error e = kvImageNoError;
    if (quarter) {
        r = (vImage_Buffer){mem + (hr + dest->height) * wai * ps, hr, wr, wr * ps};
        e = rotate90(src, &r, f, (uint8_t)quarter, bg, flags);
    }
    if (!e)
        e = shear(&r, &a, f, 0, 0, t > 0 ? t * hr : 0, -t, &k, bg, 0, flags);
    if (!e)
        e = shear(&a, &bb, f, 0, 0, 0.5 * (((double)hr - (double)dest->height) - b * wa), b, &k, bg, 1, flags);
    if (!e)
        e = shear(&bb, dest, f, 0, 0, -0.5 * (((double)wai - (double)dest->width) - t * (double)dest->height), -t, &k, bg,
                  0, flags);
    free(mem);
    return e;
}

vImage_Error vImageGetPerspectiveWarp(const float srcPoints[4][2], const float destPoints[4][2],
                                      vImage_PerpsectiveTransform *transform, vImage_Flags flags)
{
    if (!srcPoints || !destPoints || !transform)
        return kvImageNullPointerArgument;
    /* x' = (a x + c y + tx) / (vx x + vy y + v), y' = (b x + d y + ty) / (...), v = 1 */
    double m[8][9];
    for (int i = 0; i < 4; ++i) {
        double x = srcPoints[i][0], y = srcPoints[i][1], X = destPoints[i][0], Y = destPoints[i][1];
        double r0[9] = {x, y, 1, 0, 0, 0, -X * x, -X * y, X}, r1[9] = {0, 0, 0, x, y, 1, -Y * x, -Y * y, Y};
        memcpy(m[2 * i], r0, sizeof(r0));
        memcpy(m[2 * i + 1], r1, sizeof(r1));
    }
    for (int col = 0; col < 8; ++col) {
        int pivot = col;
        for (int r = col + 1; r < 8; ++r)
            if (fabs(m[r][col]) > fabs(m[pivot][col]))
                pivot = r;
        if (fabs(m[pivot][col]) < 1e-12)
            return kvImageInvalidParameter;
        for (int k = 0; k < 9; ++k) {
            double t = m[col][k];
            m[col][k] = m[pivot][k];
            m[pivot][k] = t;
        }
        for (int r = 0; r < 8; ++r)
            if (r != col) {
                double fct = m[r][col] / m[col][col];
                for (int k = col; k < 9; ++k)
                    m[r][k] -= fct * m[col][k];
            }
    }
    double h[8];
    for (int i = 0; i < 8; ++i)
        h[i] = m[i][8] / m[i][i];
    /* h = {a', c', tx, b', d', ty, vx, vy} in column-vector form */
    transform->a = (float)h[0];
    transform->c = (float)h[1];
    transform->tx = (float)h[2];
    transform->b = (float)h[3];
    transform->d = (float)h[4];
    transform->ty = (float)h[5];
    transform->vx = (float)h[6];
    transform->vy = (float)h[7];
    transform->v = 1;
    return kvImageNoError;
}

static vImage_Error perspective(const vImage_Buffer *src, const vImage_Buffer *dest, Format f,
                                const vImage_PerpsectiveTransform *t, vImage_WarpInterpolation interp, const float *bg,
                                vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!src || !dest || !src->data || !dest->data || !t)
        return kvImageNullPointerArgument;
    vImage_Flags edges = flags & (kvImageEdgeExtend | kvImageBackgroundColorFill);
    if (!edges || edges == (kvImageEdgeExtend | kvImageBackgroundColorFill))
        return kvImageInvalidParameter;
    /* the inverse of [[a b vx][c d vy][tx ty v]] */
    double M[3][3] = {{t->a, t->b, t->vx}, {t->c, t->d, t->vy}, {t->tx, t->ty, t->v}}, I[3][3];
    double det = M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0]) +
                 M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0]);
    if (det == 0)
        return kvImageInvalidParameter;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            int r1 = (c + 1) % 3, r2 = (c + 2) % 3, c1 = (r + 1) % 3, c2 = (r + 2) % 3;
            I[r][c] = (M[r1][c1] * M[r2][c2] - M[r1][c2] * M[r2][c1]) / det;
        }
    int ch = f.channels, extend = (flags & kvImageEdgeExtend) != 0;
    long sw = (long)src->width, sh = (long)src->height;
    for (long y = 0; y < (long)dest->height; ++y)
        for (long x = 0; x < (long)dest->width; ++x) {
            /* (the perspective warp puts pixel centres on integers) */
            double X = x, Y = (double)dest->height - y - 1;
            double hx = X * I[0][0] + Y * I[1][0] + I[2][0], hy = X * I[0][1] + Y * I[1][1] + I[2][1],
                   hw = X * I[0][2] + Y * I[1][2] + I[2][2];
            double px = hx / hw, py = (double)sh - 1 - hy / hw;
            float v[4];
            long x0 = (long)floor(px), y0 = (long)floor(py);
            double fx = px - x0, fy = py - y0;
            if (interp == kvImageInterpolationNearest) {
                x0 = lround(px);
                y0 = lround(py);
                fx = fy = 0;
            }
            for (int cc = 0; cc < ch; ++cc) {
                double sum = 0;
                for (int j = 0; j < 2; ++j)
                    for (int i = 0; i < 2; ++i) {
                        double w = (i ? fx : 1 - fx) * (j ? fy : 1 - fy);
                        if (w == 0)
                            continue;
                        long ii = x0 + i, jj = y0 + j;
                        if (ii < 0 || jj < 0 || ii >= sw || jj >= sh) {
                            if (!extend) {
                                sum += w * bg[cc];
                                continue;
                            }
                            ii = ii < 0 ? 0 : ii >= sw ? sw - 1 : ii;
                            jj = jj < 0 ? 0 : jj >= sh ? sh - 1 : jj;
                        }
                        sum += w * get(src, f, ii, jj, cc);
                    }
                v[cc] = (float)sum;
            }
            put(dest, f, x, y, v);
        }
    return kvImageNoError;
}

/* MARK: - Entry points */

/* BG(name) declares float bg[4] from the parameter backColor */
#define BG_SCALAR8 float bg[4] = {backColor}
#define BG_SCALAR16 float bg[4] = {backColor}
#define BG_SCALARF float bg[4] = {backColor}
#define BG_SCALAR16F float bg[4] = {half_to_float(backColor)}
#define BG_P8(n)                                                                                         \
    float bg[4];                                                                                         \
    bg_u8(backColor, n, bg)
#define BG_P16U(n)                                                                                       \
    float bg[4];                                                                                         \
    bg_u16(backColor, n, bg)
#define BG_P16S(n)                                                                                       \
    float bg[4];                                                                                         \
    bg_s16(backColor, n, bg)
#define BG_PF(n)                                                                                         \
    float bg[4];                                                                                         \
    bg_f32(backColor, n, bg)
#define BG_P16F(n)                                                                                       \
    float bg[4];                                                                                         \
    bg_f16(backColor, n, bg)
#define BG_X10                                                                                           \
    float bg[4];                                                                                         \
    bg_x10(&backColor, 3, bg)

/* each format: its name, Format, and the background type and declaration */
#define FORMATS(X)                                                                                       \
    X(Planar8, P8, Pixel_8, BG_SCALAR8)                                                                  \
    X(Planar16S, P16S, Pixel_16S, BG_SCALAR16)                                                           \
    X(Planar16U, P16U, Pixel_16U, BG_SCALAR16)                                                           \
    X(PlanarF, PF, Pixel_F, BG_SCALARF)                                                                  \
    X(ARGB8888, A8888, const Pixel_8888, BG_P8(4))                                                       \
    X(ARGB16U, A16U, const Pixel_ARGB_16U, BG_P16U(4))                                                   \
    X(ARGB16S, A16S, const Pixel_ARGB_16S, BG_P16S(4))                                                   \
    X(ARGBFFFF, AFFFF, const Pixel_FFFF, BG_PF(4))                                                       \
    X(Planar16F, P16F, const Pixel_16F, BG_SCALAR16F)                                                    \
    X(CbCr16F, C16F, const Pixel_16F16F, BG_P16F(2))                                                     \
    X(ARGB16F, A16F, const Pixel_ARGB_16F, BG_P16F(4))                                                   \
    X(CbCr8, C8, const Pixel_88, BG_P8(2))                                                               \
    X(CbCr16U, C16U, const Pixel_16U16U, BG_P16U(2))                                                     \
    X(CbCr16S, C16S, const Pixel_16S16S, BG_P16S(2))                                                     \
    X(XRGB2101010W, X2101010, const Pixel_32U, BG_X10)

#define REFLECTS(name, F, BGT, BGDECL)                                                                   \
    vImage_Error vImageHorizontalReflect_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags) \
    {                                                                                                    \
        return reflect(src, dest, F, 1, flags);                                                          \
    }                                                                                                    \
    vImage_Error vImageVerticalReflect_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags) \
    {                                                                                                    \
        return reflect(src, dest, F, 0, flags);                                                          \
    }
#define ROTATE90S(name, F, BGT, BGDECL)                                                                  \
    vImage_Error vImageRotate90_##name(const vImage_Buffer *src, const vImage_Buffer *dest, uint8_t rotation, BGT backColor, \
                                       vImage_Flags flags)                                               \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return rotate90(src, dest, F, rotation, bg, flags);                                              \
    }
#define SCALES(name, F, BGT, BGDECL)                                                                     \
    vImage_Error vImageScale_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, vImage_Flags flags) \
    {                                                                                                    \
        return scale(src, dest, F, flags);                                                               \
    }
#define SHEARS(name, F, BGT, BGDECL)                                                                     \
    vImage_Error vImageHorizontalShear_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox, \
                                              vImagePixelCount oy, float translate, float slope,         \
                                              ResamplingFilter filter, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return shear(src, dest, F, ox, oy, translate, slope, filter, bg, 0, flags);                      \
    }                                                                                                    \
    vImage_Error vImageVerticalShear_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox, \
                                            vImagePixelCount oy, float translate, float slope, ResamplingFilter filter, \
                                            BGT backColor, vImage_Flags flags)                            \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return shear(src, dest, F, ox, oy, translate, slope, filter, bg, 1, flags);                      \
    }                                                                                                    \
    vImage_Error vImageHorizontalShearD_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox, \
                                               vImagePixelCount oy, double translate, double slope,      \
                                               ResamplingFilter filter, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return shear(src, dest, F, ox, oy, translate, slope, filter, bg, 0, flags);                      \
    }                                                                                                    \
    vImage_Error vImageVerticalShearD_##name(const vImage_Buffer *src, const vImage_Buffer *dest, vImagePixelCount ox, \
                                             vImagePixelCount oy, double translate, double slope,        \
                                             ResamplingFilter filter, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return shear(src, dest, F, ox, oy, translate, slope, filter, bg, 1, flags);                      \
    }
#define WARPS(name, F, BGT, BGDECL)                                                                      \
    vImage_Error vImageRotate_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, float angle, \
                                     BGT backColor, vImage_Flags flags)                                  \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return rotate(src, dest, F, angle, bg, flags);                                                   \
    }                                                                                                    \
    vImage_Error vImageAffineWarp_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, \
                                         const vImage_AffineTransform *t, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        if (!t)                                                                                          \
            return kvImageNullPointerArgument;                                                           \
        BGDECL;                                                                                          \
        return affine(src, dest, F, t->a, t->b, t->c, t->d, t->tx, t->ty, bg, flags);                    \
    }                                                                                                    \
    vImage_Error vImageAffineWarpD_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, \
                                          const vImage_AffineTransform_Double *t, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        if (!t)                                                                                          \
            return kvImageNullPointerArgument;                                                           \
        BGDECL;                                                                                          \
        return affine(src, dest, F, t->a, t->b, t->c, t->d, t->tx, t->ty, bg, flags);                    \
    }                                                                                                    \
    vImage_Error vImageAffineWarpCG_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, \
                                           const vImage_CGAffineTransform *t, BGT backColor, vImage_Flags flags) \
    {                                                                                                    \
        if (!t)                                                                                          \
            return kvImageNullPointerArgument;                                                           \
        BGDECL;                                                                                          \
        return affine(src, dest, F, t->a, t->b, t->c, t->d, t->tx, t->ty, bg, flags);                    \
    }
#define PERSPECTIVES(name, F, BGT, BGDECL)                                                               \
    vImage_Error vImagePerspectiveWarp_##name(const vImage_Buffer *src, const vImage_Buffer *dest, void *temp, \
                                              const vImage_PerpsectiveTransform *t, vImage_WarpInterpolation interp, \
                                              BGT backColor, vImage_Flags flags)                          \
    {                                                                                                    \
        BGDECL;                                                                                          \
        return perspective(src, dest, F, t, interp, bg, flags);                                          \
    }

FORMATS(REFLECTS)
FORMATS(ROTATE90S)
FORMATS(SCALES)
FORMATS(SHEARS)
FORMATS(WARPS)
PERSPECTIVES(Planar8, P8, Pixel_8, BG_SCALAR8)
PERSPECTIVES(ARGB8888, A8888, Pixel_8888, BG_P8(4))
PERSPECTIVES(Planar16U, P16U, Pixel_16U, BG_SCALAR16)
PERSPECTIVES(ARGB16U, A16U, Pixel_ARGB_16U, BG_P16U(4))
PERSPECTIVES(Planar16F, P16F, Pixel_16F, BG_SCALAR16F)
PERSPECTIVES(ARGB16F, A16F, Pixel_ARGB_16F, BG_P16F(4))

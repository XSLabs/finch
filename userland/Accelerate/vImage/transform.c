/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's transforms (Transform.h): matrix multiplication across channels, gamma
 * (plain and piecewise), piecewise polynomials and rationals, lookup tables (direct,
 * interpolated and multidimensional) and flood fill.
 */
#include "common.h"

/* MARK: - Matrix multiply */

/* dest[j] = (sum_i (src[i] + pre[i]) * m[i * nd + j] + post[j]) / divisor, clamped to the type */
static vImage_Error matrix_multiply(const vImage_Buffer *const *srcs, const int *srcChannel, const vImage_Buffer *const *dests,
                                    const int *destChannel, int ns, int nd, int sampleSize, int isFloat,
                                    const double *m, double divisor, const double *pre, const double *post,
                                    int isSigned16, int preStride, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    for (int i = 0; i < ns; ++i)
        if (!srcs[i] || !srcs[i]->data)
            return kvImageNullPointerArgument;
    for (int j = 0; j < nd; ++j) {
        if (!dests[j] || !dests[j]->data)
            return kvImageNullPointerArgument;
        for (int i = 0; i < ns; ++i)
            CHECK(fits(dests[j], srcs[i]));
    }
    const vImage_Buffer *d0 = dests[0];
    double in[64], out[64];
    if (ns > 64 || nd > 64)
        return kvImageInvalidParameter;
    for (vImagePixelCount y = 0; y < d0->height; ++y)
        for (vImagePixelCount x = 0; x < d0->width; ++x) {
            for (int i = 0; i < ns; ++i) {
                const uint8_t *row = CROW(srcs[i], y);
                size_t at = (size_t)x * (srcChannel ? 4 : 1) + (srcChannel ? (size_t)srcChannel[i] : 0);
                double v = isFloat ? ((const float *)row)[at]
                           : sampleSize == 1 ? row[at]
                                             : ((const int16_t *)row)[at];
                in[i] = v;
            }
            for (int j = 0; j < nd; ++j) {
                /* (Apple's PlanarF and Planar16S apply the pre-bias down the matrix with a
                   stride of the source count, which is the same for square matrices) */
                double bias = 0;
                if (pre)
                    for (int i = 0; i < ns; ++i)
                        bias += pre[i] * (i * preStride + j < ns * nd ? m[i * preStride + j] : 0);
                if (isFloat) {
                    float sum = 0;
                    for (int i = 0; i < ns; ++i)
                        sum += (float)in[i] * (float)m[i * nd + j];
                    out[j] = sum + (float)bias + (post ? (float)post[j] : 0);
                } else {
                    long sum = (long)bias;
                    for (int i = 0; i < ns; ++i)
                        sum += (long)in[i] * (long)m[i * nd + j];
                    sum += post ? (long)post[j] : (long)divisor / 2;
                    /* (dividing with flooring) */
                    long q = sum / (long)divisor;
                    if ((sum % (long)divisor) && ((sum < 0) != (divisor < 0)))
                        q -= 1;
                    out[j] = (double)q;
                }
            }
            for (int j = 0; j < nd; ++j) {
                uint8_t *row = ROW(dests[j], y);
                size_t at = (size_t)x * (destChannel ? 4 : 1) + (destChannel ? (size_t)destChannel[j] : 0);
                if (isFloat)
                    ((float *)row)[at] = (float)out[j];
                else if (sampleSize == 1)
                    row[at] = sat8((long)out[j]);
                else
                    ((int16_t *)row)[at] = isSigned16 ? sat16s((long)out[j]) : (int16_t)out[j];
            }
        }
    return kvImageNoError;
}

#define TO_DOUBLES(dst, srcp, n)                                                                         \
    double dst##_v[64];                                                                                  \
    const double *dst = NULL;                                                                            \
    if (srcp) {                                                                                          \
        for (int i_ = 0; i_ < (n); ++i_)                                                                 \
            dst##_v[i_] = (double)(srcp)[i_];                                                            \
        dst = dst##_v;                                                                                   \
    }

static vImage_Error planar_matrix(const vImage_Buffer *srcs[], const vImage_Buffer *dests[], uint32_t ns, uint32_t nd,
                                  const double *m, double divisor, const double *pre, const double *post, int size,
                                  int isFloat, vImage_Flags flags)
{
    if (!srcs || !dests || !m)
        return kvImageNullPointerArgument;
    return matrix_multiply(srcs, NULL, dests, NULL, (int)ns, (int)nd, size, isFloat, m, divisor, pre, post, size == 2,
                           size == 1 ? (int)nd : (int)ns, flags);
}

vImage_Error vImageMatrixMultiply_Planar8(const vImage_Buffer *srcs[], const vImage_Buffer *dests[], uint32_t ns,
                                          uint32_t nd, const int16_t matrix[], int32_t divisor, const int16_t *pre_bias,
                                          const int32_t *post_bias, vImage_Flags flags)
{
    if (!matrix || ns > 64 || nd > 64)
        return kvImageNullPointerArgument;
    double m[64 * 64];
    for (uint32_t i = 0; i < ns * nd; ++i)
        m[i] = matrix[i];
    TO_DOUBLES(pre, pre_bias, (int)ns)
    TO_DOUBLES(post, post_bias, (int)nd)
    return planar_matrix(srcs, dests, ns, nd, m, divisor ? divisor : 1, pre, post, 1, 0, flags);
}

vImage_Error vImageMatrixMultiply_Planar16S(const vImage_Buffer *srcs[], const vImage_Buffer *dests[], uint32_t ns,
                                            uint32_t nd, const int16_t matrix[], int32_t divisor,
                                            const int16_t *pre_bias, const int32_t *post_bias, vImage_Flags flags)
{
    if (!matrix || ns > 64 || nd > 64)
        return kvImageNullPointerArgument;
    double m[64 * 64];
    for (uint32_t i = 0; i < ns * nd; ++i)
        m[i] = matrix[i];
    TO_DOUBLES(pre, pre_bias, (int)ns)
    TO_DOUBLES(post, post_bias, (int)nd)
    return planar_matrix(srcs, dests, ns, nd, m, divisor ? divisor : 1, pre, post, 2, 0, flags);
}

vImage_Error vImageMatrixMultiply_PlanarF(const vImage_Buffer *srcs[], const vImage_Buffer *dests[], uint32_t ns,
                                          uint32_t nd, const float matrix[], const float *pre_bias,
                                          const float *post_bias, vImage_Flags flags)
{
    if (!matrix || ns > 64 || nd > 64)
        return kvImageNullPointerArgument;
    double m[64 * 64];
    for (uint32_t i = 0; i < ns * nd; ++i)
        m[i] = matrix[i];
    TO_DOUBLES(pre, pre_bias, (int)ns)
    TO_DOUBLES(post, post_bias, (int)nd)
    return planar_matrix(srcs, dests, ns, nd, m, 1, pre, post, 4, 1, flags);
}

static const int channel_index[4] = {0, 1, 2, 3};

vImage_Error vImageMatrixMultiply_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                           const int16_t matrix[4 * 4], int32_t divisor, const int16_t *pre_bias,
                                           const int32_t *post_bias, vImage_Flags flags)
{
    if (!matrix)
        return kvImageNullPointerArgument;
    double m[16];
    for (int i = 0; i < 16; ++i)
        m[i] = matrix[i];
    TO_DOUBLES(pre, pre_bias, 4)
    TO_DOUBLES(post, post_bias, 4)
    const vImage_Buffer *s[4] = {src, src, src, src}, *d[4] = {dest, dest, dest, dest};
    return matrix_multiply(s, channel_index, d, channel_index, 4, 4, 1, 0, m, divisor ? divisor : 1, pre, post, 0, 4,
                           flags);
}

vImage_Error vImageMatrixMultiply_ARGBFFFF(const vImage_Buffer *src, const vImage_Buffer *dest,
                                           const float matrix[4 * 4], const float *pre_bias, const float *post_bias,
                                           vImage_Flags flags)
{
    if (!matrix)
        return kvImageNullPointerArgument;
    double m[16];
    for (int i = 0; i < 16; ++i)
        m[i] = matrix[i];
    TO_DOUBLES(pre, pre_bias, 4)
    TO_DOUBLES(post, post_bias, 4)
    const vImage_Buffer *s[4] = {src, src, src, src}, *d[4] = {dest, dest, dest, dest};
    return matrix_multiply(s, channel_index, d, channel_index, 4, 4, 4, 1, m, 1, pre, post, 0, 4, flags);
}

vImage_Error vImageMatrixMultiply_ARGB8888ToPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                    const int16_t matrix[4], int32_t divisor, const int16_t pre_bias[4],
                                                    int32_t post_bias, vImage_Flags flags)
{
    if (!matrix)
        return kvImageNullPointerArgument;
    double m[4] = {matrix[0], matrix[1], matrix[2], matrix[3]}, post[1] = {post_bias};
    TO_DOUBLES(pre, pre_bias, 4)
    const vImage_Buffer *s[4] = {src, src, src, src}, *d[1] = {dest};
    return matrix_multiply(s, channel_index, d, NULL, 4, 1, 1, 0, m, divisor ? divisor : 1, pre, post, 0, 1, flags);
}

vImage_Error vImageMatrixMultiply_ARGBFFFFToPlanarF(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                    const float matrix[4], const float pre_bias[4], float post_bias,
                                                    vImage_Flags flags)
{
    if (!matrix)
        return kvImageNullPointerArgument;
    double m[4] = {matrix[0], matrix[1], matrix[2], matrix[3]}, post[1] = {post_bias};
    TO_DOUBLES(pre, pre_bias, 4)
    const vImage_Buffer *s[4] = {src, src, src, src}, *d[1] = {dest};
    return matrix_multiply(s, channel_index, d, NULL, 4, 1, 4, 1, m, 1, pre, post, 0, 1, flags);
}

/* MARK: - Gamma */

typedef struct {
    float gamma;
    int type;
} Gamma;

GammaFunction vImageCreateGammaFunction(float gamma, int type, vImage_Flags flags)
{
    Gamma *g = malloc(sizeof(*g));
    if (!g)
        return NULL;
    static const float fixed[] = {0, 0, 5.f / 9, 9.f / 5, 5.f / 11, 11.f / 5, 0, 0, 11.f / 9, 9.f / 11, 0, 0};
    g->gamma = type >= 2 && type < 12 && fixed[type] ? fixed[type] : gamma;
    g->type = type;
    return g;
}

void vImageDestroyGammaFunction(GammaFunction f) { free(f); }

static float gamma_of(const Gamma *g, float v)
{
    switch (g->type) {
    case kvImageGamma_sRGB_forward_half_precision:
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        return v < 0.03928f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f);
    case kvImageGamma_sRGB_reverse_half_precision:
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        return v < 0.00304f ? 12.92f * v : 1.055f * powf(v, 1 / 2.4f) - 0.055f;
    case kvImageGamma_BT709_forward_half_precision:
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        return v < 0.081f ? v / 4.5f : powf((v + 0.099f) / 1.099f, 1 / 0.45f);
    case kvImageGamma_BT709_reverse_half_precision:
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        return v < 0.018f ? 4.5f * v : 1.099f * powf(v, 0.45f) - 0.099f;
    case kvImageGamma_UseGammaValue:
    case kvImageGamma_UseGammaValue_half_precision:
        return copysignf(powf(fabsf(v), g->gamma), v);
    default: /* the half-precision forms clamp to [0, 1] */
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        return powf(v, g->gamma);
    }
}

#define GAMMA(name, ST, DT, IN, OUT)                                                                     \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const GammaFunction gamma,    \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        if (!gamma)                                                                                      \
            return kvImageNullPointerArgument;                                                           \
        const Gamma *g = gamma;                                                                          \
        PIXELS(ST, DT, float r = gamma_of(g, IN(in[x])); out[x] = OUT(r));                               \
    }
#define FROM8(v) ((float)(v) * (1.0f / 255.0f))
#define TO8(r) (uint8_t)(!((r) > 0) ? 0 : (r) >= 1 ? 255 : lrintf((r) * 255.0f))
#define SAME(v) (v)
GAMMA(vImageGamma_Planar8toPlanarF, uint8_t, float, FROM8, SAME)
GAMMA(vImageGamma_PlanarFtoPlanar8, float, uint8_t, SAME, TO8)
GAMMA(vImageGamma_PlanarF, float, float, SAME, SAME)

/* MARK: - Piecewise gamma: linear below the boundary, exponential above */

static inline float piecewise(float x, const float *e, float gamma, const float *l, float boundary)
{
    if (x < boundary)
        return l[0] * x + l[1];
    return powf(e[0] * x + e[1], gamma) + e[2];
}

static inline int16_t to_q12(float r)
{
    r = r < -8 ? -8 : r >= 8 ? 32767.0f / 4096 : r;
    return sat16s(lrintf(r * 4096));
}

#define PIECEWISE(name, ST, DT, BT, IN, BOUND, OUT)                                                      \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const float e[3], const float gamma, \
                      const float l[2], const BT boundary, vImage_Flags flags)                           \
    {                                                                                                    \
        if (!e || !l)                                                                                    \
            return kvImageNullPointerArgument;                                                           \
        PIXELS(ST, DT, float r = piecewise(IN(in[x]), e, gamma, l, BOUND(boundary)); out[x] = OUT(r));   \
    }
#define FROMQ12(v) ((float)(v) * (1.0f / 4096.0f))
#define TOQ12(r) to_q12(r)
PIECEWISE(vImagePiecewiseGamma_Planar8, uint8_t, uint8_t, Pixel_8, FROM8, FROM8, TO8)
PIECEWISE(vImagePiecewiseGamma_Planar8toPlanar16Q12, uint8_t, int16_t, Pixel_8, FROM8, FROM8, TOQ12)
PIECEWISE(vImagePiecewiseGamma_Planar8toPlanarF, uint8_t, float, Pixel_8, FROM8, FROM8, SAME)
PIECEWISE(vImagePiecewiseGamma_Planar16Q12, int16_t, int16_t, Pixel_16S, FROMQ12, FROMQ12, TOQ12)
PIECEWISE(vImagePiecewiseGamma_Planar16Q12toPlanar8, int16_t, uint8_t, Pixel_16S, FROMQ12, FROMQ12, TO8)
PIECEWISE(vImagePiecewiseGamma_PlanarF, float, float, float, SAME, SAME, SAME)
PIECEWISE(vImagePiecewiseGamma_PlanarFtoPlanar8, float, uint8_t, float, SAME, SAME, TO8)

/* symmetric: applied to |x| and given x's sign */
static inline float symmetric(float x, const float *e, float gamma, const float *l, float boundary)
{
    return copysignf(piecewise(fabsf(x), e, gamma, l, boundary), x);
}

vImage_Error vImageSymmetricPiecewiseGamma_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                   const float e[3], const float gamma, const float l[2],
                                                   const float boundary, vImage_Flags flags)
{
    if (!e || !l)
        return kvImageNullPointerArgument;
    PIXELS(float, float, out[x] = symmetric(in[x], e, gamma, l, boundary));
}

vImage_Error vImageSymmetricPiecewiseGamma_Planar16Q12(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                       const float e[3], const float gamma, const float l[2],
                                                       const Pixel_16S boundary, vImage_Flags flags)
{
    if (!e || !l)
        return kvImageNullPointerArgument;
    PIXELS(int16_t, int16_t, out[x] = to_q12(symmetric(FROMQ12(in[x]), e, gamma, l, FROMQ12(boundary))));
}

/* MARK: - Piecewise polynomials and rationals */

static inline float poly(const float *c, uint32_t order, float x)
{
    float r = c[order];
    for (uint32_t i = order; i-- > 0;)
        r = fmaf(r, x, c[i]);
    return r;
}

static inline uint32_t segment(const float *b, uint32_t n, float *x)
{
    if (*x < b[0])
        *x = b[0];
    if (*x > b[n])
        *x = b[n];
    uint32_t s = 0;
    while (s + 1 < n && *x >= b[s + 1])
        ++s;
    return s;
}

#define POLYNOMIAL(name, ST, DT, IN, OUT, SYM)                                                           \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const float **coefficients,   \
                      const float *boundaries, uint32_t order, uint32_t log2segments, vImage_Flags flags) \
    {                                                                                                    \
        if (!coefficients || !boundaries)                                                                \
            return kvImageNullPointerArgument;                                                           \
        uint32_t n = 1u << log2segments;                                                                 \
        PIXELS(ST, DT, float v = IN(in[x]); float a = SYM ? fabsf(v) : v; uint32_t s = segment(boundaries, n, &a); \
               float r = poly(coefficients[s], order, a); out[x] = OUT(SYM ? copysignf(r, v) : r));      \
    }
#define IDENT8(v) ((float)(v) / 255.0f)
#define SAT8(r) (uint8_t)(!((r) > 0) ? 0 : (r) >= 255 ? 255 : (r))
POLYNOMIAL(vImagePiecewisePolynomial_PlanarF, float, float, SAME, SAME, 0)
POLYNOMIAL(vImagePiecewisePolynomial_Planar8toPlanarF, uint8_t, float, IDENT8, SAME, 0)
POLYNOMIAL(vImagePiecewisePolynomial_PlanarFtoPlanar8, float, uint8_t, SAME, SAT8, 0)
POLYNOMIAL(vImageSymmetricPiecewisePolynomial_PlanarF, float, float, SAME, SAME, 1)

vImage_Error vImagePiecewiseRational_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest, const float **top,
                                             const float **bottom, const float *boundaries, uint32_t topOrder,
                                             uint32_t bottomOrder, uint32_t log2segments, vImage_Flags flags)
{
    if (!top || !bottom || !boundaries)
        return kvImageNullPointerArgument;
    uint32_t n = 1u << log2segments;
    PIXELS(float, float, float v = in[x]; uint32_t s = segment(boundaries, n, &v);
           out[x] = poly(top[s], topOrder, v) / poly(bottom[s], bottomOrder, v));
}

/* MARK: - Lookup tables */

#define LOOKUP(name, ST, DT, TT, EXPR)                                                                   \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const TT table, vImage_Flags flags) \
    {                                                                                                    \
        if (!table)                                                                                      \
            return kvImageNullPointerArgument;                                                           \
        PIXELS(ST, DT, EXPR);                                                                            \
    }
LOOKUP(vImageLookupTable_Planar8toPlanar16, uint8_t, uint16_t, Pixel_16U *, out[x] = table[in[x]])
LOOKUP(vImageLookupTable_Planar8toPlanarF, uint8_t, float, Pixel_F *, out[x] = table[in[x]])
LOOKUP(vImageLookupTable_8to64U, uint8_t, uint64_t, uint64_t *, out[x] = table[in[x]])
LOOKUP(vImageLookupTable_Planar16, uint16_t, uint16_t, Pixel_16U *, out[x] = table[in[x]])
LOOKUP(vImageLookupTable_Planar8toPlanar24, uint8_t, uint8_t, uint32_t *,
       const uint8_t *t = (const uint8_t *)(table + in[x]);
       memcpy(out + 3 * x, t + 1, 3))
LOOKUP(vImageLookupTable_Planar8toPlanar48, uint8_t, uint16_t, uint64_t *,
       const uint16_t *t = (const uint16_t *)(table + in[x]);
       memcpy(out + 3 * x, t + 1, 6))
LOOKUP(vImageLookupTable_Planar8toPlanar96, uint8_t, float, Pixel_FFFF *, memcpy(out + 3 * x, table[in[x]] + 1, 12))
LOOKUP(vImageLookupTable_Planar8toPlanar128, uint8_t, float, Pixel_FFFF *, memcpy(out + 4 * x, table[in[x]], 16))

vImage_Error vImageLookupTable_PlanarFtoPlanar8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                const Pixel_8 table[4096], vImage_Flags flags)
{
    if (!table)
        return kvImageNullPointerArgument;
    PIXELS(float, uint8_t, float f = in[x] * 4096.0f; f = !(f > 0) ? 0 : f > 4095 ? 4095 : f;
           out[x] = table[(uint32_t)f]);
}

vImage_Error vImageInterpolatedLookupTable_PlanarF(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                   const Pixel_F *table, vImagePixelCount entries, float maxFloat,
                                                   float minFloat, vImage_Flags flags)
{
    if (!table)
        return kvImageNullPointerArgument;
    PIXELS(float, float, float c = fmaxf(fminf(in[x], maxFloat), minFloat);
           float fi = (c - minFloat) * ((float)(entries - 1) / (maxFloat - minFloat)); float fr = fi - floorf(fi);
           unsigned long i = (unsigned long)fi; out[x] = fmaf(table[i + 1] - table[i], fr, table[i]));
}

/* MARK: - Multidimensional tables */

typedef struct {
    long retain;
    uint32_t ns, nd;
    uint32_t entries[16];
    size_t stride[16];
    float *data; /* samples / 65535 */
} MDTable;

vImage_MultidimensionalTable vImageMultidimensionalTable_Create(const uint16_t *tableData, uint32_t ns, uint32_t nd,
                                                                const uint8_t entries[], vImageMDTableUsageHint hint,
                                                                vImage_Flags flags, vImage_Error *err)
{
    int tooFew = 0;
    for (uint32_t d = 0; entries && d < ns; ++d)
        tooFew |= entries[d] < 2;
    if (!tableData || !entries || !ns || !nd || ns > 16 || tooFew) {
        if (err)
            *err = !tableData || !entries ? kvImageNullPointerArgument : kvImageInvalidParameter;
        return NULL;
    }
    MDTable *t = calloc(1, sizeof(*t));
    size_t count = nd;
    for (uint32_t d = ns; d-- > 0;) {
        t->entries[d] = entries[d];
        t->stride[d] = count;
        count *= entries[d];
    }
    t->data = t ? malloc(count * sizeof(float)) : NULL;
    if (!t || !t->data) {
        free(t);
        if (err)
            *err = kvImageMemoryAllocationError;
        return NULL;
    }
    for (size_t i = 0; i < count; ++i)
        t->data[i] = tableData[i] / 65535.0f;
    t->retain = 1;
    t->ns = ns;
    t->nd = nd;
    if (err)
        *err = kvImageNoError;
    return (vImage_MultidimensionalTable)t;
}

vImage_Error vImageMultidimensionalTable_Retain(vImage_MultidimensionalTable table)
{
    if (table)
        __atomic_add_fetch(&((MDTable *)table)->retain, 1, __ATOMIC_RELAXED);
    return kvImageNoError;
}

vImage_Error vImageMultidimensionalTable_Release(vImage_MultidimensionalTable table)
{
    MDTable *t = (MDTable *)table;
    if (t && __atomic_sub_fetch(&t->retain, 1, __ATOMIC_ACQ_REL) == 0) {
        free(t->data);
        free(t);
    }
    return kvImageNoError;
}

/* one pixel: in[] in [0, 1] per source channel, out[] per destination channel */
static void md_lookup(const MDTable *t, const float *in, float *out, vImage_InterpolationMethod method, int clampHigh)
{
    uint32_t base[16];
    float frac[16];
    size_t at = 0;
    for (uint32_t d = 0; d < t->ns; ++d) {
        /* (inputs below 0 clamp; above 1, float inputs extrapolate from the last cell, as
           Apple's do, and 16Q12 ones clamp) */
        float v = (clampHigh ? fminf(fmaxf(in[d], 0), 1) : fmaxf(in[d], 0)) * (float)(t->entries[d] - 1);
        uint32_t b = v >= (float)(t->entries[d] - 2) ? t->entries[d] - 2 : (uint32_t)v;
        base[d] = b;
        frac[d] = v - (float)b;
        at += b * t->stride[d];
    }
    for (uint32_t c = 0; c < t->nd; ++c)
        out[c] = 0;
    /* (Apple's interpolates fully whichever method is asked for) */
    method = kvImageFullInterpolation;
    if (method == kvImageFullInterpolation) {
        /* all 2**N corners */
        for (uint32_t corner = 0; corner < (1u << t->ns); ++corner) {
            float w = 1;
            size_t off = at;
            for (uint32_t d = 0; d < t->ns; ++d) {
                int hi = (corner >> d) & 1;
                w *= hi ? frac[d] : 1 - frac[d];
                off += hi ? t->stride[d] : 0;
            }
            if (w != 0)
                for (uint32_t c = 0; c < t->nd; ++c)
                    out[c] += w * t->data[off + c];
        }
        return;
    }
    if (method == kvImageNoInterpolation) {
        for (uint32_t d = 0; d < t->ns; ++d)
            if (frac[d] >= 1)
                at += t->stride[d];
        for (uint32_t c = 0; c < t->nd; ++c)
            out[c] = t->data[at + c];
        return;
    }
    /* half: the simplex from the low corner through the axes in decreasing order of fraction
       to the high corner (the gray axis and N-1 other vertices) */
    uint32_t order[16];
    for (uint32_t d = 0; d < t->ns; ++d)
        order[d] = d;
    for (uint32_t i = 1; i < t->ns; ++i)
        for (uint32_t k = i; k > 0 && frac[order[k]] > frac[order[k - 1]]; --k) {
            uint32_t s = order[k];
            order[k] = order[k - 1];
            order[k - 1] = s;
        }
    float prev = 1;
    size_t off = at;
    for (uint32_t i = 0; i <= t->ns; ++i) {
        float f = i < t->ns ? frac[order[i]] : 0, w = prev - f;
        for (uint32_t c = 0; c < t->nd; ++c)
            out[c] += w * t->data[off + c];
        if (i < t->ns) {
            off += t->stride[order[i]];
            prev = f;
        }
    }
}

static vImage_Error md_apply(const vImage_Buffer srcs[], const vImage_Buffer dests[], const MDTable *t,
                             vImage_InterpolationMethod method, int q12, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!srcs || !dests || !t)
        return kvImageNullPointerArgument;
    if (method > kvImageHalfInterpolation)
        return kvImageInvalidParameter;
    for (uint32_t d = 1; d < t->ns; ++d)
        CHECK(same_size(&srcs[0], &srcs[d]));
    for (uint32_t c = 0; c < t->nd; ++c) {
        CHECK(same_size(&dests[0], &dests[c]));
    }
    if (srcs[0].width < dests[0].width || srcs[0].height < dests[0].height)
        return kvImageBufferSizeMismatch;
    float in[16], out[64];
    for (vImagePixelCount y = 0; y < dests[0].height; ++y)
        for (vImagePixelCount x = 0; x < dests[0].width; ++x) {
            for (uint32_t d = 0; d < t->ns; ++d)
                in[d] = q12 ? SAMPLE(int16_t, &srcs[d], y, x) / 4096.0f : SAMPLE(float, &srcs[d], y, x);
            md_lookup(t, in, out, method, q12);
            for (uint32_t c = 0; c < t->nd && c < 64; ++c) {
                uint8_t *row = ROW(&dests[c], y);
                if (q12)
                    ((int16_t *)row)[x] = sat16s(lrintf(out[c] * 4096));
                else
                    ((float *)row)[x] = out[c];
            }
        }
    return kvImageNoError;
}

vImage_Error vImageMultiDimensionalInterpolatedLookupTable_PlanarF(const vImage_Buffer srcs[],
                                                                   const vImage_Buffer dests[], void *temp,
                                                                   vImage_MultidimensionalTable table,
                                                                   vImage_InterpolationMethod method,
                                                                   vImage_Flags flags)
{
    return md_apply(srcs, dests, (const MDTable *)table, method, 0, flags);
}

vImage_Error vImageMultiDimensionalInterpolatedLookupTable_Planar16Q12(const vImage_Buffer srcs[],
                                                                       const vImage_Buffer dests[], void *temp,
                                                                       vImage_MultidimensionalTable table,
                                                                       vImage_InterpolationMethod method,
                                                                       vImage_Flags flags)
{
    return md_apply(srcs, dests, (const MDTable *)table, method, 1, flags);
}

/* MARK: - Flood fill */

static vImage_Error flood(const vImage_Buffer *buf, vImagePixelCount sx, vImagePixelCount sy, const void *value,
                          size_t size, int connectivity, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    if (!buf || !buf->data || !value)
        return kvImageNullPointerArgument;
    if (connectivity != 4 && connectivity != 8)
        return kvImageInvalidParameter;
    if (sx >= buf->width || sy >= buf->height)
        return kvImageInvalidParameter;
    uint8_t seed[16];
    memcpy(seed, ROW(buf, sy) + sx * size, size);
    if (!memcmp(seed, value, size))
        return kvImageNoError;
    size_t cap = 1024, n = 0;
    vImagePixelCount *stack = malloc(cap * 2 * sizeof(*stack));
    if (!stack)
        return kvImageMemoryAllocationError;
    stack[n * 2] = sx;
    stack[n * 2 + 1] = sy;
    ++n;
    memcpy(ROW(buf, sy) + sx * size, value, size);
    while (n) {
        --n;
        vImagePixelCount x = stack[n * 2], y = stack[n * 2 + 1];
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
                if ((!dx && !dy) || (connectivity == 4 && dx && dy))
                    continue;
                long nx = (long)x + dx, ny = (long)y + dy;
                if (nx < 0 || ny < 0 || nx >= (long)buf->width || ny >= (long)buf->height)
                    continue;
                uint8_t *p = ROW(buf, ny) + (size_t)nx * size;
                if (memcmp(p, seed, size))
                    continue;
                memcpy(p, value, size);
                if (n == cap) {
                    cap *= 2;
                    vImagePixelCount *grown = realloc(stack, cap * 2 * sizeof(*stack));
                    if (!grown) {
                        free(stack);
                        return kvImageMemoryAllocationError;
                    }
                    stack = grown;
                }
                stack[n * 2] = (vImagePixelCount)nx;
                stack[n * 2 + 1] = (vImagePixelCount)ny;
                ++n;
            }
    }
    free(stack);
    return kvImageNoError;
}

vImage_Error vImageFloodFill_Planar8(const vImage_Buffer *srcDest, void *temp, vImagePixelCount seedX,
                                     vImagePixelCount seedY, Pixel_8 newValue, int connectivity, vImage_Flags flags)
{
    return flood(srcDest, seedX, seedY, &newValue, 1, connectivity, flags);
}
vImage_Error vImageFloodFill_Planar16U(const vImage_Buffer *srcDest, void *temp, vImagePixelCount seedX,
                                       vImagePixelCount seedY, Pixel_16U newValue, int connectivity, vImage_Flags flags)
{
    return flood(srcDest, seedX, seedY, &newValue, 2, connectivity, flags);
}
vImage_Error vImageFloodFill_ARGB8888(const vImage_Buffer *srcDest, void *temp, vImagePixelCount seedX,
                                      vImagePixelCount seedY, Pixel_8888 newValue, int connectivity,
                                      vImage_Flags flags)
{
    return flood(srcDest, seedX, seedY, newValue, 4, connectivity, flags);
}
vImage_Error vImageFloodFill_ARGB16U(const vImage_Buffer *srcDest, void *temp, vImagePixelCount seedX,
                                     vImagePixelCount seedY, Pixel_ARGB_16U newValue, int connectivity,
                                     vImage_Flags flags)
{
    return flood(srcDest, seedX, seedY, newValue, 8, connectivity, flags);
}

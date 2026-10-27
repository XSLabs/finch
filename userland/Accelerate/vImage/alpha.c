/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's alpha operations (Alpha.h): premultiplying and unpremultiplying, alpha
 * blending (non-premultiplied, premultiplied, with a constant alpha, into a
 * premultiplied bottom, and the Multiply, Screen, Darken and Lighten modes), and
 * clipping colour to alpha. The arithmetic is the header's.
 */
#include "common.h"

/* MARK: - Premultiply and unpremultiply */

static inline uint8_t pre8(uint32_t c, uint32_t a) { return (uint8_t)((c * a + 127) / 255); }
static inline uint16_t pre16(uint32_t c, uint32_t a) { return (uint16_t)(((uint64_t)c * a + 32767) / 65535); }
/* 16Q12: alpha clamped to [0, 4096]; an arithmetic shift rounds premultiplication */
static inline int32_t q12_alpha(int32_t a) { return a < 0 ? 0 : a > 4096 ? 4096 : a; }
static inline int16_t preq12(int32_t c, int32_t a) { return sat16s(((long)c * q12_alpha(a) + 2048) >> 12); }
static inline uint8_t un8(uint32_t c, uint32_t a) { return a ? (uint8_t)(((c < a ? c : a) * 255 + a / 2) / a) : 0; }
static inline uint16_t un16(uint32_t c, uint32_t a)
{
    return a ? (uint16_t)(((uint64_t)(c < a ? c : a) * 65535 + a / 2) / a) : 0;
}
/* (Apple's divides with flooring and keeps the low 16 bits, without clamping to alpha) */
static inline int16_t unq12(int32_t c, int32_t a)
{
    a = q12_alpha(a);
    if (!a)
        return 0;
    long n = (long)c * 4096 + a / 2, q = n / a;
    if (n % a && n < 0)
        q -= 1;
    return (int16_t)(uint16_t)q;
}

#define PLANAR_ALPHA(name, T, EXPR)                                                                      \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *alpha, const vImage_Buffer *dest,   \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, src));                                                                          \
        CHECK(fits(dest, alpha));                                                                        \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const T *in = (const T *)CROW(src, y), *al = (const T *)CROW(alpha, y);                      \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                T c = in[x], a = al[x];                                                                  \
                out[x] = EXPR;                                                                           \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }

PLANAR_ALPHA(vImagePremultiplyData_Planar8, uint8_t, pre8(c, a))
PLANAR_ALPHA(vImagePremultiplyData_PlanarF, float, c *a)
PLANAR_ALPHA(vImageUnpremultiplyData_Planar8, uint8_t, un8(c, a))
PLANAR_ALPHA(vImageUnpremultiplyData_PlanarF, float, a == 0 ? 0 : VECTOR(x, dest->width) ? c * recip(a) : c / a)
PLANAR_ALPHA(vImageClipToAlpha_Planar8, uint8_t, c < a ? c : a)
PLANAR_ALPHA(vImageClipToAlpha_PlanarF, float, c < a ? c : a)

/* four channels with alpha at ai: colour channels become EXPR(c, a), alpha stays */
#define CHANNELS_ALPHA(name, T, ai, EXPR)                                                                \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)           \
    {                                                                                                    \
        PIXELS(T, T, const T *p = in + 4 * x; T a = p[ai]; for (int k = 0; k < 4; ++k) {                 \
            T c = p[k];                                                                                  \
            out[4 * x + k] = k == (ai) ? a : (T)(EXPR);                                                  \
        });                                                                                              \
    }

/* 16Q12 also writes the clamped alpha */
#define CHANNELS_Q12(name, ai, EXPR)                                                                     \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, vImage_Flags flags)           \
    {                                                                                                    \
        PIXELS(int16_t, int16_t, const int16_t *p = in + 4 * x; int16_t a = p[ai]; for (int k = 0; k < 4; ++k) { \
            int16_t c = p[k];                                                                            \
            out[4 * x + k] = k == (ai) ? (int16_t)q12_alpha(a) : (EXPR);                                 \
        });                                                                                              \
    }

CHANNELS_ALPHA(vImagePremultiplyData_ARGB8888, uint8_t, 0, pre8(c, a))
CHANNELS_ALPHA(vImagePremultiplyData_RGBA8888, uint8_t, 3, pre8(c, a))
CHANNELS_ALPHA(vImagePremultiplyData_ARGBFFFF, float, 0, c *a)
CHANNELS_ALPHA(vImagePremultiplyData_RGBAFFFF, float, 3, c *a)
CHANNELS_ALPHA(vImagePremultiplyData_ARGB16U, uint16_t, 0, pre16(c, a))
CHANNELS_ALPHA(vImagePremultiplyData_RGBA16U, uint16_t, 3, pre16(c, a))
CHANNELS_Q12(vImagePremultiplyData_ARGB16Q12, 0, preq12(c, a))
CHANNELS_Q12(vImagePremultiplyData_RGBA16Q12, 3, preq12(c, a))
CHANNELS_ALPHA(vImagePremultiplyData_RGBA16F, uint16_t, 3, float_to_half(half_to_float(c) * half_to_float(a)))
CHANNELS_ALPHA(vImageUnpremultiplyData_ARGB8888, uint8_t, 0, un8(c, a))
CHANNELS_ALPHA(vImageUnpremultiplyData_RGBA8888, uint8_t, 3, un8(c, a))
CHANNELS_ALPHA(vImageUnpremultiplyData_ARGBFFFF, float, 0, a == 0 ? 0 : VECTOR(x, dest->width) ? c * recip(a) : c / a)
CHANNELS_ALPHA(vImageUnpremultiplyData_RGBAFFFF, float, 3, a == 0 ? 0 : VECTOR(x, dest->width) ? c * recip(a) : c / a)
CHANNELS_ALPHA(vImageUnpremultiplyData_ARGB16U, uint16_t, 0, un16(c, a))
CHANNELS_ALPHA(vImageUnpremultiplyData_RGBA16U, uint16_t, 3, un16(c, a))
CHANNELS_Q12(vImageUnpremultiplyData_ARGB16Q12, 0, unq12(c, a))
CHANNELS_Q12(vImageUnpremultiplyData_RGBA16Q12, 3, unq12(c, a))
CHANNELS_ALPHA(vImageUnpremultiplyData_RGBA16F, uint16_t, 3,
               half_to_float(a) == 0 ? 0 : float_to_half(half_to_float(c) / half_to_float(a)))
CHANNELS_ALPHA(vImageClipToAlpha_ARGB8888, uint8_t, 0, c < a ? c : a)
CHANNELS_ALPHA(vImageClipToAlpha_RGBA8888, uint8_t, 3, c < a ? c : a)
CHANNELS_ALPHA(vImageClipToAlpha_ARGBFFFF, float, 0, c < a ? c : a)
CHANNELS_ALPHA(vImageClipToAlpha_RGBAFFFF, float, 3, c < a ? c : a)

/* MARK: - Blends */

/* one blended channel of two non-premultiplied 8-bit pixels, given the result alpha */
static inline uint8_t blend8(uint32_t tc, uint32_t ta, uint32_t bc, uint32_t ba, uint32_t na)
{
    if (!na)
        return 0;
    uint32_t num = 255 * tc * ta + (255 - ta) * bc * ba;
    return sat8((long)((num + 255 * na / 2) / (255 * na)));
}

/* the same in float, as Apple's ARGB8888 blend computes it (Apple's rounds a few exact
   halves the other way) */
static inline uint8_t blend8f(uint32_t tc, uint32_t ta, uint32_t bc, uint32_t ba, uint32_t na)
{
    if (!na)
        return 0;
    float fa = ta * (1 / 255.f), fb = ba * (1 / 255.f), fn = fa + (1 - fa) * fb;
    float v = (tc * fa + (1 - fa) * fb * bc) / fn;
    return !(v > 0) ? 0 : v >= 255 ? 255 : (uint8_t)(v + 0.5f);
}

static inline uint8_t blend_alpha8(uint32_t ta, uint32_t ba) { return (uint8_t)(ta + ((255 - ta) * ba + 127) / 255); }

vImage_Error vImageAlphaBlend_Planar8(const vImage_Buffer *top, const vImage_Buffer *topAlpha,
                                      const vImage_Buffer *bottom, const vImage_Buffer *bottomAlpha,
                                      const vImage_Buffer *alpha, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *in[5] = {top, topAlpha, bottom, bottomAlpha, alpha};
    for (int i = 0; i < 5; ++i)
        CHECK(fits(dest, in[i]));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ROW(dest, y)[x] = blend8(SAMPLE(uint8_t, top, y, x), SAMPLE(uint8_t, topAlpha, y, x),
                                     SAMPLE(uint8_t, bottom, y, x), SAMPLE(uint8_t, bottomAlpha, y, x),
                                     SAMPLE(uint8_t, alpha, y, x));
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_PlanarF(const vImage_Buffer *top, const vImage_Buffer *topAlpha,
                                      const vImage_Buffer *bottom, const vImage_Buffer *bottomAlpha,
                                      const vImage_Buffer *alpha, const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    const vImage_Buffer *in[5] = {top, topAlpha, bottom, bottomAlpha, alpha};
    for (int i = 0; i < 5; ++i)
        CHECK(fits(dest, in[i]));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            float ta = SAMPLE(float, topAlpha, y, x), na = SAMPLE(float, alpha, y, x);
            float v = SAMPLE(float, top, y, x) * ta + (1.0f - ta) * SAMPLE(float, bottomAlpha, y, x) *
                                                          SAMPLE(float, bottom, y, x);
            ((float *)ROW(dest, y))[x] = VECTOR(x, dest->width) ? v * recip(na) : v / na;
        }
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_ARGB8888(const vImage_Buffer *top, const vImage_Buffer *bottom,
                                       const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *t = CROW(top, y), *b = CROW(bottom, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            const uint8_t *tp = t + 4 * x, *bp = b + 4 * x;
            uint8_t na = blend_alpha8(tp[0], bp[0]);
            out[4 * x] = na;
            for (int c = 1; c < 4; ++c)
                out[4 * x + c] = blend8f(tp[c], tp[0], bp[c], bp[0], na);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_ARGBFFFF(const vImage_Buffer *top, const vImage_Buffer *bottom,
                                       const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const float *t = (const float *)CROW(top, y), *b = (const float *)CROW(bottom, y);
        float *out = (float *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            const float *tp = t + 4 * x, *bp = b + 4 * x;
            float na = tp[0] + (1.0f - tp[0]) * bp[0];
            out[4 * x] = na;
            for (int c = 1; c < 4; ++c)
                out[4 * x + c] = VECTOR(x, dest->width) ? (tp[c] * tp[0] + (1.0f - tp[0]) * bp[0] * bp[c]) * recip(na)
                                                        : (tp[c] * tp[0] + (1.0f - tp[0]) * bp[0] * bp[c]) / na;
        }
    }
    return kvImageNoError;
}

/* premultiplied: colour = top + (1 - topAlpha) bottom */
static inline uint8_t over8(uint32_t tc, uint32_t ta, uint32_t bc) { return sat8((long)(tc + ((255 - ta) * bc + 127) / 255)); }

vImage_Error vImagePremultipliedAlphaBlend_Planar8(const vImage_Buffer *top, const vImage_Buffer *topAlpha,
                                                   const vImage_Buffer *bottom, const vImage_Buffer *dest,
                                                   vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ROW(dest, y)[x] = over8(SAMPLE(uint8_t, top, y, x), SAMPLE(uint8_t, topAlpha, y, x),
                                    SAMPLE(uint8_t, bottom, y, x));
    return kvImageNoError;
}

vImage_Error vImagePremultipliedAlphaBlend_PlanarF(const vImage_Buffer *top, const vImage_Buffer *topAlpha,
                                                   const vImage_Buffer *bottom, const vImage_Buffer *dest,
                                                   vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ((float *)ROW(dest, y))[x] =
                SAMPLE(float, top, y, x) + (1.0f - SAMPLE(float, topAlpha, y, x)) * SAMPLE(float, bottom, y, x);
    return kvImageNoError;
}

/* a blend of four-channel images with alpha at ai; MODE gives each colour channel from
   the top and bottom colours and alphas */
#define BLEND4(name, T, ai, COLOR, ALPHA)                                                                \
    vImage_Error name(const vImage_Buffer *top, const vImage_Buffer *bottom, const vImage_Buffer *dest,  \
                      vImage_Flags flags)                                                                \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, top));                                                                          \
        CHECK(fits(dest, bottom));                                                                       \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const T *t = (const T *)CROW(top, y), *b = (const T *)CROW(bottom, y);                       \
            T *out = (T *)ROW(dest, y);                                                                  \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                T ta = t[4 * x + (ai)], ba = b[4 * x + (ai)];                                            \
                for (int k = 0; k < 4; ++k) {                                                            \
                    T tc = t[4 * x + k], bc = b[4 * x + k];                                              \
                    out[4 * x + k] = k == (ai) ? (T)(ALPHA) : (T)(COLOR);                                \
                }                                                                                        \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }

#define OVER_ALPHA8 blend_alpha8(ta, ba)
#define OVER_COLOR8 over8(tc, ta, bc)
#define OVER_F(tc, ta, bc) ((tc) + (1.0f - (ta)) * (bc))

BLEND4(vImagePremultipliedAlphaBlend_ARGB8888, uint8_t, 0, OVER_COLOR8, OVER_ALPHA8)
BLEND4(vImagePremultipliedAlphaBlend_BGRA8888, uint8_t, 3, OVER_COLOR8, OVER_ALPHA8)
BLEND4(vImagePremultipliedAlphaBlend_ARGBFFFF, float, 0, OVER_F(tc, ta, bc), OVER_F(ta, ta, ba))
BLEND4(vImagePremultipliedAlphaBlend_BGRAFFFF, float, 3, OVER_F(tc, ta, bc), OVER_F(ta, ta, ba))

static inline uint8_t multiply8(uint32_t tc, uint32_t ta, uint32_t bc, uint32_t ba)
{
    return sat8((long)(((255 - ta) * bc + (255 - ba) * tc + tc * bc + 127) / 255));
}
static inline uint8_t screen8(uint32_t tc, uint32_t bc) { return sat8((long)tc + bc - (tc * bc + 127) / 255); }
static inline uint8_t darken8(uint32_t tc, uint32_t ta, uint32_t bc, uint32_t ba)
{
    long t = tc + ((255 - ta) * bc + 127) / 255, b = bc + ((255 - ba) * tc + 127) / 255;
    return sat8(t < b ? t : b);
}
static inline uint8_t lighten8(uint32_t tc, uint32_t ta, uint32_t bc, uint32_t ba)
{
    long t = tc + ((255 - ta) * bc + 127) / 255, b = bc + ((255 - ba) * tc + 127) / 255;
    return sat8(t > b ? t : b);
}

BLEND4(vImagePremultipliedAlphaBlendMultiply_RGBA8888, uint8_t, 3, multiply8(tc, ta, bc, ba), OVER_ALPHA8)
BLEND4(vImagePremultipliedAlphaBlendScreen_RGBA8888, uint8_t, 3, screen8(tc, bc), OVER_ALPHA8)
BLEND4(vImagePremultipliedAlphaBlendDarken_RGBA8888, uint8_t, 3, darken8(tc, ta, bc, ba), OVER_ALPHA8)
BLEND4(vImagePremultipliedAlphaBlendLighten_RGBA8888, uint8_t, 3, lighten8(tc, ta, bc, ba), OVER_ALPHA8)

/* the top permuted first; optionally an opaque result alpha */
#define BLEND_PERMUTE(name, ai)                                                                          \
    vImage_Error name(const vImage_Buffer *top, const vImage_Buffer *bottom, const vImage_Buffer *dest,  \
                      const uint8_t permuteMap[4], bool makeDestAlphaOpaque, vImage_Flags flags)         \
    {                                                                                                    \
        TEMP_QUERY(flags);                                                                               \
        CHECK(fits(dest, top));                                                                          \
        CHECK(fits(dest, bottom));                                                                       \
        for (vImagePixelCount y = 0; y < dest->height; ++y) {                                            \
            const uint8_t *t = CROW(top, y), *b = CROW(bottom, y);                                       \
            uint8_t *out = ROW(dest, y);                                                                 \
            for (vImagePixelCount x = 0; x < dest->width; ++x) {                                         \
                uint8_t tp[4];                                                                           \
                for (int k = 0; k < 4; ++k) /* the permuted top is ARGB in either form */               \
                    tp[(ai) == 0 ? k : (k + 3) % 4] = t[4 * x + permuteMap[k]];                          \
                uint8_t ta = tp[ai], ba = b[4 * x + (ai)];                                               \
                for (int k = 0; k < 4; ++k)                                                              \
                    out[4 * x + k] = k == (ai) ? (makeDestAlphaOpaque ? 255 : blend_alpha8(ta, ba))       \
                                               : over8(tp[k], ta, b[4 * x + k]);                         \
            }                                                                                            \
        }                                                                                                \
        return kvImageNoError;                                                                           \
    }
BLEND_PERMUTE(vImagePremultipliedAlphaBlendWithPermute_ARGB8888, 0)
BLEND_PERMUTE(vImagePremultipliedAlphaBlendWithPermute_RGBA8888, 3)

/* constant alpha: top scaled by constAlpha, with one rounding */
static inline uint8_t const8(uint32_t tc, uint32_t ta, uint32_t k, uint32_t bc)
{
    return sat8((long)((tc * k * 255 + (255 * 255 - ta * k) * bc + 127 * 255) / (255 * 255)));
}

vImage_Error vImagePremultipliedConstAlphaBlend_Planar8(const vImage_Buffer *top, Pixel_8 constAlpha,
                                                        const vImage_Buffer *topAlpha, const vImage_Buffer *bottom,
                                                        const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ROW(dest, y)[x] = const8(SAMPLE(uint8_t, top, y, x), SAMPLE(uint8_t, topAlpha, y, x), constAlpha,
                                     SAMPLE(uint8_t, bottom, y, x));
    return kvImageNoError;
}

vImage_Error vImagePremultipliedConstAlphaBlend_PlanarF(const vImage_Buffer *top, Pixel_F constAlpha,
                                                        const vImage_Buffer *topAlpha, const vImage_Buffer *bottom,
                                                        const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ((float *)ROW(dest, y))[x] = SAMPLE(float, top, y, x) * constAlpha +
                                         (1.0f - SAMPLE(float, topAlpha, y, x) * constAlpha) *
                                             SAMPLE(float, bottom, y, x);
    return kvImageNoError;
}


vImage_Error vImagePremultipliedConstAlphaBlend_ARGB8888(const vImage_Buffer *top, Pixel_8 constAlpha,
                                                         const vImage_Buffer *bottom, const vImage_Buffer *dest,
                                                         vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *t = CROW(top, y), *b = CROW(bottom, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int k = 0; k < 4; ++k)
                out[4 * x + k] =
                    VECTOR(x, dest->width) /* (Apple's vector loop truncates) */
                        ? (uint8_t)((t[4 * x + k] * constAlpha * 255u + (255u * 255u - t[4 * x] * constAlpha) * b[4 * x + k]) /
                                    (255u * 255u))
                        : const8(t[4 * x + k], t[4 * x], constAlpha, b[4 * x + k]);
    }
    return kvImageNoError;
}

vImage_Error vImagePremultipliedConstAlphaBlend_ARGBFFFF(const vImage_Buffer *top, Pixel_F constAlpha,
                                                         const vImage_Buffer *bottom, const vImage_Buffer *dest,
                                                         vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const float *t = (const float *)CROW(top, y), *b = (const float *)CROW(bottom, y);
        float *out = (float *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            for (int k = 0; k < 4; ++k)
                out[4 * x + k] = t[4 * x + k] * constAlpha + (1.0f - t[4 * x] * constAlpha) * b[4 * x + k];
    }
    return kvImageNoError;
}

/* a non-premultiplied top over a premultiplied bottom */
static inline uint8_t nonpre8(uint32_t tc, uint32_t ta, uint32_t bc) { return sat8((long)((tc * ta + (255 - ta) * bc + 127) / 255)); }

vImage_Error vImageAlphaBlend_NonpremultipliedToPremultiplied_Planar8(const vImage_Buffer *top,
                                                                      const vImage_Buffer *topAlpha,
                                                                      const vImage_Buffer *bottom,
                                                                      const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x)
            ROW(dest, y)[x] = nonpre8(SAMPLE(uint8_t, top, y, x), SAMPLE(uint8_t, topAlpha, y, x),
                                      SAMPLE(uint8_t, bottom, y, x));
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_NonpremultipliedToPremultiplied_PlanarF(const vImage_Buffer *top,
                                                                      const vImage_Buffer *topAlpha,
                                                                      const vImage_Buffer *bottom,
                                                                      const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, topAlpha));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            float ta = SAMPLE(float, topAlpha, y, x);
            ((float *)ROW(dest, y))[x] = SAMPLE(float, top, y, x) * ta + (1.0f - ta) * SAMPLE(float, bottom, y, x);
        }
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_NonpremultipliedToPremultiplied_ARGB8888(const vImage_Buffer *top,
                                                                       const vImage_Buffer *bottom,
                                                                       const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *t = CROW(top, y), *b = CROW(bottom, y);
        uint8_t *out = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            uint32_t ta = t[4 * x];
            out[4 * x] = blend_alpha8(ta, b[4 * x]);
            for (int k = 1; k < 4; ++k)
                out[4 * x + k] = nonpre8(t[4 * x + k], ta, b[4 * x + k]);
        }
    }
    return kvImageNoError;
}

vImage_Error vImageAlphaBlend_NonpremultipliedToPremultiplied_ARGBFFFF(const vImage_Buffer *top,
                                                                       const vImage_Buffer *bottom,
                                                                       const vImage_Buffer *dest, vImage_Flags flags)
{
    TEMP_QUERY(flags);
    CHECK(fits(dest, top));
    CHECK(fits(dest, bottom));
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const float *t = (const float *)CROW(top, y), *b = (const float *)CROW(bottom, y);
        float *out = (float *)ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            float ta = t[4 * x];
            out[4 * x] = ta + (1.0f - ta) * b[4 * x];
            for (int k = 1; k < 4; ++k)
                out[4 * x + k] = t[4 * x + k] * ta + (1.0f - ta) * b[4 * x + k];
        }
    }
    return kvImageNoError;
}

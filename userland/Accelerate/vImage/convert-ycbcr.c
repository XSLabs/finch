/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's Y'CbCr conversions (Conversion.h): the generated conversions (a matrix and a
 * pixel range, for one Y'CbCr format and one RGB format) and the 4:4:4, 4:2:2 and 4:2:0
 * formats, 8, 10 and 16 bits, to and from ARGB8888, ARGB16U and ARGB16Q12.
 *
 * The arithmetic is Apple's, found by matching its results. Y'CbCr to 8-bit RGB is fixed
 * point: from 8 and 10 bits each product of a sample with a coefficient (Q13, per 8-bit
 * unit) is rounded to Q5 and the sum rounded; from 16 bits the products (Q13 or Q14) are
 * summed exactly and rounded once. 8-bit RGB to 8-bit 4:4:4 computes full-range luma in
 * Q5, scales it to the range, and takes chroma as gains on B - Y' and R - Y'; to 4:2:2
 * and 4:2:0 it uses the range-scaled matrix, chroma from each pair's (Q6) or 2 x 2
 * block's (Q7) summed RGB. The rest (16Q12 and 16-bit RGB, 10- and 16-bit Y'CbCr from
 * RGB) is single precision, which matches Apple's but for one in a few samples.
 */
#include "common.h"

/* MARK: - The standard matrices */

static const vImage_YpCbCrToARGBMatrix to_rgb_601 = {1, 1.402f, -0.714136302f, -0.344136298f, 1.772f};
static const vImage_YpCbCrToARGBMatrix to_rgb_709 = {1, 1.5748f, -0.46812427f, -0.187324271f, 1.8556f};
static const vImage_ARGBToYpCbCrMatrix to_ycbcr_601 = {0.299f, 0.587f, 0.114f, -0.168735892f, -0.331264108f, 0.5f,
                                                      -0.418687582f, -0.0813124105f};
static const vImage_ARGBToYpCbCrMatrix to_ycbcr_709 = {0.2126f, 0.7152f, 0.0722f, -0.114572108f, -0.385427892f, 0.5f,
                                                      -0.454152912f, -0.0458470918f};
const vImage_YpCbCrToARGBMatrix *kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 = &to_rgb_601;
const vImage_YpCbCrToARGBMatrix *kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 = &to_rgb_709;
const vImage_ARGBToYpCbCrMatrix *kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4 = &to_ycbcr_601;
const vImage_ARGBToYpCbCrMatrix *kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2 = &to_ycbcr_709;

/* MARK: - Generated conversions */

#define TO_RGB_MAGIC 0x59325247u   /* "GR2Y" */
#define TO_YCBCR_MAGIC 0x52325947u /* "GY2R" */

/* Finch's layout of the opaque vImage_YpCbCrToARGB and vImage_ARGBToYpCbCr */
typedef struct {
    uint32_t magic;
    int32_t ycbcrType, argbType, depth; /* depth: bits a Y'CbCr sample */
    vImage_YpCbCrPixelRange range;
    union {
        struct { /* to RGB */
            float y, crR, crG, cbG, cbB; /* per unit of sample, to the RGB scale */
            int16_t q[5];                /* to 8-bit RGB: y, crR, cbB, crG, cbG in Q13 */
            int16_t q16[5];              /* the same from 16-bit samples, in Q(q16Bits) */
            int32_t q16Bits;
        };
        struct { /* to Y'CbCr */
            float rY, gY, bY, rCb, gCb, bCbRCr, gCr, bCr; /* per RGB unit, to samples */
            /* from 8-bit RGB, Q15: the full-range luma weights, the luma range scale and the
               chroma gains of B - Y' and R - Y' (4:4:4), and the range-scaled matrix (4:2:2) */
            int32_t lumaR, lumaG, lumaB, lumaScale, gainB, gainR;
            int16_t m[8];
        };
    };
} Info;
_Static_assert(sizeof(Info) <= 128, "fits vImage's opaque conversion");

static int depth_of(vImageYpCbCrType t)
{
    switch (t) {
    case kvImage444CrYpCb10:
    case kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10:
        return 10;
    case kvImage422CbYpCrYp16:
    case kvImage444AYpCbCr16:
        return 16;
    default:
        return 8;
    }
}

/* the conversions vImage has: 8-bit Y'CbCr only with 8-bit RGB, 10 bits with 8 bits or
   16Q12, 16 bits with 8 or 16 */
static bool supported(vImageYpCbCrType t, vImageARGBType a)
{
    int d = depth_of(t);
    if ((int)t < 0 || t > kvImage444AYpCbCr16 || (t > kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10 && d == 8))
        return false;
    return a == kvImageARGB8888 || (d == 10 && a == kvImageARGB16Q12) || (d == 16 && a == kvImageARGB16U);
}

static float rgb_scale(vImageARGBType a) { return a == kvImageARGB8888 ? 255.0f : a == kvImageARGB16U ? 65535.0f : 4096.0f; }

vImage_Error vImageConvert_YpCbCrToARGB_GenerateConversion(const vImage_YpCbCrToARGBMatrix *matrix,
                                                           const vImage_YpCbCrPixelRange *pixelRange,
                                                           vImage_YpCbCrToARGB *outInfo, vImageYpCbCrType inYpCbCrType,
                                                           vImageARGBType outARGBType, vImage_Flags flags)
{
    if (!matrix || !pixelRange || !outInfo)
        return kvImageNullPointerArgument;
    if (flags & ~(vImage_Flags)kvImagePrintDiagnosticsToConsole)
        return kvImageUnknownFlagsBit;
    if (!supported(inYpCbCrType, outARGBType))
        return kvImageUnsupportedConversion;
    Info *info = (Info *)outInfo;
    memset(info, 0, sizeof(*info));
    info->magic = TO_RGB_MAGIC;
    info->ycbcrType = inYpCbCrType;
    info->argbType = outARGBType;
    info->depth = depth_of(inYpCbCrType);
    info->range = *pixelRange;
    float out = rgb_scale(outARGBType);
    float ys = out / (float)(pixelRange->YpRangeMax - pixelRange->Yp_bias);
    float cs = out / (2.0f * (float)(pixelRange->CbCrRangeMax - pixelRange->CbCr_bias));
    info->y = matrix->Yp * ys;
    info->crR = matrix->Cr_R * cs;
    info->crG = matrix->Cr_G * cs;
    info->cbG = matrix->Cb_G * cs;
    info->cbB = matrix->Cb_B * cs;
    /* the 8-bit RGB path's coefficients are per 8-bit unit of sample */
    float down = (float)(1 << (info->depth - 8));
    const float c[5] = {info->y, info->crR, info->cbB, info->crG, info->cbG};
    for (int i = 0; i < 5; ++i)
        info->q[i] = (int16_t)lrintf(c[i] * down * 8192.0f);
    /* from 16 bits, Q14 when every coefficient fits 16 bits so, else Q13 */
    info->q16Bits = 14;
    for (int i = 0; i < 5; ++i)
        if (fabsf(c[i] * down) * 16384.0f >= 32767.5f)
            info->q16Bits = 13;
    for (int i = 0; i < 5; ++i)
        info->q16[i] = (int16_t)lrintf(c[i] * down * (float)(1 << info->q16Bits));
    return kvImageNoError;
}

vImage_Error vImageConvert_ARGBToYpCbCr_GenerateConversion(const vImage_ARGBToYpCbCrMatrix *matrix,
                                                           const vImage_YpCbCrPixelRange *pixelRange,
                                                           vImage_ARGBToYpCbCr *outInfo, vImageARGBType inARGBType,
                                                           vImageYpCbCrType outYpCbCrType, vImage_Flags flags)
{
    if (!matrix || !pixelRange || !outInfo)
        return kvImageNullPointerArgument;
    if (flags & ~(vImage_Flags)kvImagePrintDiagnosticsToConsole)
        return kvImageUnknownFlagsBit;
    if (!supported(outYpCbCrType, inARGBType))
        return kvImageUnsupportedConversion;
    Info *info = (Info *)outInfo;
    memset(info, 0, sizeof(*info));
    info->magic = TO_YCBCR_MAGIC;
    info->ycbcrType = outYpCbCrType;
    info->argbType = inARGBType;
    info->depth = depth_of(outYpCbCrType);
    info->range = *pixelRange;
    float in = rgb_scale(inARGBType);
    float ys = (float)(pixelRange->YpRangeMax - pixelRange->Yp_bias) / in;
    float cs = 2.0f * (float)(pixelRange->CbCrRangeMax - pixelRange->CbCr_bias) / in;
    info->rY = matrix->R_Yp * ys;
    info->gY = matrix->G_Yp * ys;
    info->bY = matrix->B_Yp * ys;
    info->rCb = matrix->R_Cb * cs;
    info->gCb = matrix->G_Cb * cs;
    info->bCbRCr = matrix->B_Cb_R_Cr * cs;
    info->gCr = matrix->G_Cr * cs;
    info->bCr = matrix->B_Cr * cs;
    if (inARGBType == kvImageARGB8888) {
        float ys8 = (float)(pixelRange->YpRangeMax - pixelRange->Yp_bias) / 255.0f;
        float cs8 = 2.0f * (float)(pixelRange->CbCrRangeMax - pixelRange->CbCr_bias) / 255.0f;
        info->lumaR = (int32_t)lrintf(matrix->R_Yp * 32768.0f);
        info->lumaG = (int32_t)lrintf(matrix->G_Yp * 32768.0f);
        info->lumaB = (int32_t)lrintf(matrix->B_Yp * 32768.0f);
        info->lumaScale = (int32_t)lrintf(ys8 * 32768.0f);
        info->gainB = (int32_t)lrintf(matrix->B_Cb_R_Cr / (1.0f - matrix->B_Yp) * cs8 * 32768.0f);
        info->gainR = (int32_t)lrintf(matrix->B_Cb_R_Cr / (1.0f - matrix->R_Yp) * cs8 * 32768.0f);
        const float m8[8] = {matrix->R_Yp * ys8, matrix->G_Yp * ys8, matrix->B_Yp * ys8, matrix->R_Cb * cs8,
                             matrix->G_Cb * cs8, matrix->B_Cb_R_Cr * cs8, matrix->G_Cr * cs8, matrix->B_Cr * cs8};
        for (int i = 0; i < 8; ++i)
            info->m[i] = (int16_t)lrintf(m8[i] * 32768.0f);
    }
    return kvImageNoError;
}

/* MARK: - Y'CbCr to RGB, one pixel */

typedef struct {
    const Info *info;
    vImageARGBType out;
    const uint8_t *perm;
    float alpha; /* in the output's units */
} ToRGB;

static const uint8_t identity[4] = {0, 1, 2, 3};

static inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) { return v < lo ? lo : v > hi ? hi : v; }

/* y, cb, cr samples of the info's depth to the four output channels (alpha first) */
static void to_rgb(const ToRGB *t, int32_t y, int32_t cb, int32_t cr, float alpha, void *dest)
{
    const Info *in = t->info;
    const vImage_YpCbCrPixelRange *r = &in->range;
    y = clampi(y, r->YpMin, r->YpMax);
    cb = clampi(cb, r->CbCrMin, r->CbCrMax);
    cr = clampi(cr, r->CbCrMin, r->CbCrMax);
    float argb[4];
    argb[0] = alpha;
    if (t->out == kvImageARGB8888) {
        int32_t yy = y - r->Yp_bias, u = cb - r->CbCr_bias, v = cr - r->CbCr_bias;
        if (in->depth == 16) {
            /* from 16 bits, the exact sum of the products, rounded once */
            int shift = in->q16Bits + 8;
            int64_t half = (int64_t)1 << (shift - 1), ty = (int64_t)yy * in->q16[0];
            argb[1] = (float)clampi((int32_t)((ty + (int64_t)v * in->q16[1] + half) >> shift), 0, 255);
            argb[2] = (float)clampi((int32_t)((ty + (int64_t)u * in->q16[4] + (int64_t)v * in->q16[3] + half) >> shift), 0, 255);
            argb[3] = (float)clampi((int32_t)((ty + (int64_t)u * in->q16[2] + half) >> shift), 0, 255);
            goto store;
        }
        /* each product rounded to Q5 (the coefficients are per 8-bit unit, so deeper
           samples shift further), then the sum rounded */
        int shift = 8 + in->depth - 8;
        int64_t half = (int64_t)1 << (shift - 1);
#define TERM(x, c) ((int32_t)(((int64_t)(x) * (c) + half) >> shift))
        int32_t ty = TERM(yy, in->q[0]);
        argb[1] = clampi((ty + TERM(v, in->q[1]) + 16) >> 5, 0, 255);
        argb[2] = clampi((ty + TERM(u, in->q[4]) + TERM(v, in->q[3]) + 16) >> 5, 0, 255);
        argb[3] = clampi((ty + TERM(u, in->q[2]) + 16) >> 5, 0, 255);
#undef TERM
    } else {
        float yy = (float)(y - r->Yp_bias) * in->y, u = (float)(cb - r->CbCr_bias), v = (float)(cr - r->CbCr_bias);
        float rgb[3] = {yy + v * in->crR, yy + u * in->cbG + v * in->crG, yy + u * in->cbB};
        for (int c = 0; c < 3; ++c) {
            long q = lrintf(rgb[c]);
            argb[c + 1] = t->out == kvImageARGB16U ? (float)(q < 0 ? 0 : q > 65535 ? 65535 : q)
                                                   : (float)(q < -32768 ? -32768 : q > 32767 ? 32767 : q);
        }
    }
store:
    for (int c = 0; c < 4; ++c) {
        float v = argb[t->perm[c]];
        if (t->out == kvImageARGB8888)
            ((uint8_t *)dest)[c] = (uint8_t)v;
        else if (t->out == kvImageARGB16U)
            ((uint16_t *)dest)[c] = (uint16_t)v;
        else
            ((int16_t *)dest)[c] = (int16_t)v;
    }
}

static vImage_Error to_rgb_check(const vImage_YpCbCrToARGB *info, const uint8_t *perm, vImage_Flags flags, ToRGB *t,
                                 vImageYpCbCrType type, vImageARGBType out, float alpha)
{
    if (!info)
        return kvImageNullPointerArgument;
    if (flags & ~(vImage_Flags)(kvImageDoNotTile | kvImageGetTempBufferSize | kvImagePrintDiagnosticsToConsole))
        return kvImageUnknownFlagsBit;
    const Info *in = (const Info *)info;
    if (in->magic != TO_RGB_MAGIC || in->argbType != (int32_t)out)
        return kvImageInvalidParameter;
    (void)type;
    if (perm)
        for (int c = 0; c < 4; ++c)
            if (perm[c] > 3)
                return kvImageInvalidParameter;
    *t = (ToRGB){in, out, perm ? perm : identity, alpha};
    return kvImageNoError;
}

static inline size_t out_size(vImageARGBType out) { return out == kvImageARGB8888 ? 4 : 8; }

/* MARK: - Y'CbCr formats to RGB */

/* 4:2:2 and 4:4:4 interleaved formats: each pixel's (or pair's) samples by offsets */
typedef enum { YUVS, TWO_VUY, R408, V408, V308, V410, V210, V216, Y416 } Packing;

static inline uint32_t le32(const uint8_t *p)
{
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

/* the samples of pixel x in row in: y, cb, cr, and alpha (8888 scale for 8-bit sources;
   the source's for 16-bit ones; -1 when the format has none) */
static void samples(Packing p, const uint8_t *in, vImagePixelCount x, int32_t *y, int32_t *cb, int32_t *cr, int32_t *a)
{
    *a = -1;
    switch (p) {
    case YUVS: {
        const uint8_t *q = in + 4 * (x / 2);
        *y = q[(x & 1) * 2], *cb = q[1], *cr = q[3];
        break;
    }
    case TWO_VUY: {
        const uint8_t *q = in + 4 * (x / 2);
        *y = q[1 + (x & 1) * 2], *cb = q[0], *cr = q[2];
        break;
    }
    case R408: {
        const uint8_t *q = in + 4 * x;
        *a = q[0], *y = q[1], *cb = q[2], *cr = q[3];
        break;
    }
    case V408: {
        const uint8_t *q = in + 4 * x;
        *cb = q[0], *y = q[1], *cr = q[2], *a = q[3];
        break;
    }
    case V308: {
        const uint8_t *q = in + 3 * x;
        *cr = q[0], *y = q[1], *cb = q[2];
        break;
    }
    case V410: {
        uint32_t w = le32(in + 4 * x);
        *cr = (int32_t)(w >> 22), *y = (int32_t)(w >> 12) & 0x3ff, *cb = (int32_t)(w >> 2) & 0x3ff;
        break;
    }
    case V210: {
        /* 6 pixels in 4 words: Cb0 Y0 Cr0 | Y1 Cb1 Y2 | Cr1 Y3 Cb2 | Y4 Cr2 Y5 */
        const uint8_t *q = in + 16 * (x / 6);
        int32_t s[12];
        for (int w = 0; w < 4; ++w) {
            uint32_t v = le32(q + 4 * w);
            s[3 * w] = (int32_t)v & 0x3ff, s[3 * w + 1] = (int32_t)(v >> 10) & 0x3ff, s[3 * w + 2] = (int32_t)(v >> 20) & 0x3ff;
        }
        static const int ys[6] = {1, 3, 5, 7, 9, 11}, cbs[3] = {0, 4, 8}, crs[3] = {2, 6, 10};
        int i = (int)(x % 6);
        *y = s[ys[i]], *cb = s[cbs[i / 2]], *cr = s[crs[i / 2]];
        break;
    }
    case V216: {
        const uint16_t *q = (const uint16_t *)in + 4 * (x / 2);
        *y = q[1 + (x & 1) * 2], *cb = q[0], *cr = q[2];
        break;
    }
    default: { /* Y416: A Y' Cb Cr, 16 bits each */
        const uint16_t *q = (const uint16_t *)in + 4 * x;
        *a = q[0], *y = q[1], *cb = q[2], *cr = q[3];
        break;
    }
    }
}

static vImage_Error packed_to_rgb(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info,
                                  const uint8_t *perm, Packing p, vImageYpCbCrType type, vImageARGBType out,
                                  float alpha, vImage_Flags flags)
{
    ToRGB t;
    CHECK(to_rgb_check(info, perm, flags, &t, type, out, alpha));
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    size_t os = out_size(out);
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *in = CROW(src, y);
        uint8_t *o = ROW(dest, y);
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            int32_t yy, cb, cr, a;
            samples(p, in, x, &yy, &cb, &cr, &a);
            float av = alpha;
            if (a >= 0)
                av = (p == Y416 && out == kvImageARGB8888) ? (float)(((uint32_t)a * 255u + 32768u) >> 16) : (float)a;
            to_rgb(&t, yy, cb, cr, av, o + os * x);
        }
    }
    return kvImageNoError;
}

#define PACKED_TO(name, P, TYPE, OUT, ALPHA_T)                                                           \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info, \
                      const uint8_t permuteMap[4], const ALPHA_T alpha, vImage_Flags flags)              \
    {                                                                                                    \
        return packed_to_rgb(src, dest, info, permuteMap, P, TYPE, OUT, (float)alpha, flags);            \
    }
#define PACKED_TO_A(name, P, TYPE, OUT)                                                                  \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info, \
                      const uint8_t permuteMap[4], vImage_Flags flags)                                   \
    {                                                                                                    \
        return packed_to_rgb(src, dest, info, permuteMap, P, TYPE, OUT, 0, flags);                       \
    }

PACKED_TO(vImageConvert_422YpCbYpCr8ToARGB8888, YUVS, kvImage422YpCbYpCr8, kvImageARGB8888, uint8_t)
PACKED_TO(vImageConvert_422CbYpCrYp8ToARGB8888, TWO_VUY, kvImage422CbYpCrYp8, kvImageARGB8888, uint8_t)
PACKED_TO_A(vImageConvert_444AYpCbCr8ToARGB8888, R408, kvImage444AYpCbCr8, kvImageARGB8888)
PACKED_TO_A(vImageConvert_444CbYpCrA8ToARGB8888, V408, kvImage444CbYpCrA8, kvImageARGB8888)
PACKED_TO(vImageConvert_444CrYpCb8ToARGB8888, V308, kvImage444CrYpCb8, kvImageARGB8888, uint8_t)
PACKED_TO(vImageConvert_444CrYpCb10ToARGB8888, V410, kvImage444CrYpCb10, kvImageARGB8888, uint8_t)
PACKED_TO(vImageConvert_444CrYpCb10ToARGB16Q12, V410, kvImage444CrYpCb10, kvImageARGB16Q12, Pixel_16Q12)
PACKED_TO(vImageConvert_422CrYpCbYpCbYpCbYpCrYpCrYp10ToARGB8888, V210, kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10,
          kvImageARGB8888, uint8_t)
PACKED_TO(vImageConvert_422CrYpCbYpCbYpCbYpCrYpCrYp10ToARGB16Q12, V210, kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10,
          kvImageARGB16Q12, Pixel_16Q12)
PACKED_TO(vImageConvert_422CbYpCrYp16ToARGB8888, V216, kvImage422CbYpCrYp16, kvImageARGB8888, uint8_t)
PACKED_TO(vImageConvert_422CbYpCrYp16ToARGB16U, V216, kvImage422CbYpCrYp16, kvImageARGB16U, uint16_t)
PACKED_TO_A(vImageConvert_444AYpCbCr16ToARGB8888, Y416, kvImage444AYpCbCr16, kvImageARGB8888)
PACKED_TO_A(vImageConvert_444AYpCbCr16ToARGB16U, Y416, kvImage444AYpCbCr16, kvImageARGB16U)

vImage_Error vImageConvert_422CbYpCrYp8_AA8ToARGB8888(const vImage_Buffer *src, const vImage_Buffer *srcA,
                                                       const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info,
                                                       const uint8_t permuteMap[4], vImage_Flags flags)
{
    ToRGB t;
    CHECK(to_rgb_check(info, permuteMap, flags, &t, kvImage422CbYpCrYp8_AA8, kvImageARGB8888, 0));
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    CHECK(fits(dest, srcA));
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            int32_t yy, cb, cr, a;
            samples(TWO_VUY, CROW(src, y), x, &yy, &cb, &cr, &a);
            to_rgb(&t, yy, cb, cr, CROW(srcA, y)[x], ROW(dest, y) + 4 * x);
        }
    return kvImageNoError;
}

/* 4:2:0: a Y' plane and the chroma, a plane each or interleaved, at half resolution */
static vImage_Error planar_to_rgb(const vImage_Buffer *srcY, const vImage_Buffer *srcCb, const vImage_Buffer *srcCr,
                                  const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info, const uint8_t *perm,
                                  vImageYpCbCrType type, uint8_t alpha, vImage_Flags flags)
{
    ToRGB t;
    CHECK(to_rgb_check(info, perm, flags, &t, type, kvImageARGB8888, alpha));
    TEMP_QUERY(flags);
    CHECK(fits(dest, srcY));
    if (!srcCb || !srcCb->data || (srcCr && !srcCr->data))
        return kvImageNullPointerArgument;
    for (vImagePixelCount y = 0; y < dest->height; ++y)
        for (vImagePixelCount x = 0; x < dest->width; ++x) {
            const uint8_t *c = CROW(srcCb, y / 2);
            int32_t cb = srcCr ? c[x / 2] : c[2 * (x / 2)], cr = srcCr ? CROW(srcCr, y / 2)[x / 2] : c[2 * (x / 2) + 1];
            to_rgb(&t, CROW(srcY, y)[x], cb, cr, alpha, ROW(dest, y) + 4 * x);
        }
    return kvImageNoError;
}

vImage_Error vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(const vImage_Buffer *srcYp, const vImage_Buffer *srcCb,
                                                     const vImage_Buffer *srcCr, const vImage_Buffer *dest,
                                                     const vImage_YpCbCrToARGB *info, const uint8_t permuteMap[4],
                                                     const uint8_t alpha, vImage_Flags flags)
{
    if (!srcCr)
        return kvImageNullPointerArgument;
    return planar_to_rgb(srcYp, srcCb, srcCr, dest, info, permuteMap, kvImage420Yp8_Cb8_Cr8, alpha, flags);
}
vImage_Error vImageConvert_420Yp8_CbCr8ToARGB8888(const vImage_Buffer *srcYp, const vImage_Buffer *srcCbCr,
                                                   const vImage_Buffer *dest, const vImage_YpCbCrToARGB *info,
                                                   const uint8_t permuteMap[4], const uint8_t alpha, vImage_Flags flags)
{
    return planar_to_rgb(srcYp, srcCbCr, NULL, dest, info, permuteMap, kvImage420Yp8_CbCr8, alpha, flags);
}

/* MARK: - RGB to Y'CbCr */

typedef struct {
    const Info *info;
    vImageARGBType in;
    const uint8_t *perm;
} ToYCbCr;

static vImage_Error to_ycbcr_check(const vImage_ARGBToYpCbCr *info, const uint8_t *perm, vImage_Flags flags,
                                   ToYCbCr *t, vImageARGBType in)
{
    if (!info)
        return kvImageNullPointerArgument;
    if (flags & ~(vImage_Flags)(kvImageDoNotTile | kvImageGetTempBufferSize | kvImagePrintDiagnosticsToConsole))
        return kvImageUnknownFlagsBit;
    const Info *i = (const Info *)info;
    if (i->magic != TO_YCBCR_MAGIC || i->argbType != (int32_t)in)
        return kvImageInvalidParameter;
    if (perm)
        for (int c = 0; c < 4; ++c)
            if (perm[c] > 3)
                return kvImageInvalidParameter;
    *t = (ToYCbCr){i, in, perm ? perm : identity};
    return kvImageNoError;
}

/* the ARGB of pixel x (alpha first), in the input's units */
static inline void argb_of(const ToYCbCr *t, const uint8_t *row, vImagePixelCount x, float *argb)
{
    for (int c = 0; c < 4; ++c) {
        int k = t->perm[c];
        argb[c] = t->in == kvImageARGB8888 ? (float)row[4 * x + k]
                  : t->in == kvImageARGB16U ? (float)((const uint16_t *)row)[4 * x + k]
                                             : (float)((const int16_t *)row)[4 * x + k];
    }
}

static inline int32_t y_of(const Info *i, const float *argb)
{
    long v = lrintf((float)i->range.Yp_bias + argb[1] * i->rY + argb[2] * i->gY + argb[3] * i->bY);
    return clampi((int32_t)v, i->range.YpMin, i->range.YpMax);
}

/* Cb and Cr of the mean of n pixels */
static inline void chroma_of(const Info *i, const float (*argb)[4], int n, int32_t *cb, int32_t *cr)
{
    float u = 0, v = 0;
    for (int k = 0; k < n; ++k) {
        u += argb[k][1] * i->rCb + argb[k][2] * i->gCb + argb[k][3] * i->bCbRCr;
        v += argb[k][1] * i->bCbRCr + argb[k][2] * i->gCr + argb[k][3] * i->bCr;
    }
    *cb = clampi((int32_t)lrintf((float)i->range.CbCr_bias + u / (float)n), i->range.CbCrMin, i->range.CbCrMax);
    *cr = clampi((int32_t)lrintf((float)i->range.CbCr_bias + v / (float)n), i->range.CbCrMin, i->range.CbCrMax);
}

/* Apple's 8-bit fixed point. 4:4:4: full-range luma in Q5 (each Q15 product rounded),
   scaled to the range; chroma the gain times B - Y' or R - Y'. */
static inline int32_t q15(int32_t x, int32_t c, int shift) { return (x * c + (1 << (shift - 1))) >> shift; }

static void fixed444(const Info *i, const float *argb, int32_t *y, int32_t *cb, int32_t *cr)
{
    int32_t r = (int32_t)argb[1], g = (int32_t)argb[2], b = (int32_t)argb[3];
    int32_t l = q15(r, i->lumaR, 10) + q15(g, i->lumaG, 10) + q15(b, i->lumaB, 10);
    const vImage_YpCbCrPixelRange *pr = &i->range;
    *y = clampi(((pr->Yp_bias << 5) + q15(l, i->lumaScale, 15) + 16) >> 5, pr->YpMin, pr->YpMax);
    *cb = clampi(((pr->CbCr_bias << 5) + q15((b << 5) - l, i->gainB, 15) + 16) >> 5, pr->CbCrMin, pr->CbCrMax);
    *cr = clampi(((pr->CbCr_bias << 5) + q15((r << 5) - l, i->gainR, 15) + 16) >> 5, pr->CbCrMin, pr->CbCrMax);
}

/* 4:2:2: the range-scaled matrix, luma in Q5 a pixel, chroma in Q6 from the pair's sums */
static inline int32_t fixed422_y(const Info *i, const float *argb)
{
    int32_t v = q15((int32_t)argb[1], i->m[0], 10) + q15((int32_t)argb[2], i->m[1], 10) + q15((int32_t)argb[3], i->m[2], 10);
    return clampi(((i->range.Yp_bias << 5) + v + 16) >> 5, i->range.YpMin, i->range.YpMax);
}

/* 4:2:0: chroma in Q7 from the 2 x 2 block's sums */
static void fixed420_c(const Info *i, const float (*a)[4], int32_t *cb, int32_t *cr)
{
    int32_t r = (int32_t)(a[0][1] + a[1][1] + a[2][1] + a[3][1]), g = (int32_t)(a[0][2] + a[1][2] + a[2][2] + a[3][2]),
            b = (int32_t)(a[0][3] + a[1][3] + a[2][3] + a[3][3]);
    int32_t u = q15(r, i->m[3], 10) + q15(g, i->m[4], 10) + q15(b, i->m[5], 10);
    int32_t v = q15(r, i->m[5], 10) + q15(g, i->m[6], 10) + q15(b, i->m[7], 10);
    *cb = clampi(((i->range.CbCr_bias << 7) + u + 64) >> 7, i->range.CbCrMin, i->range.CbCrMax);
    *cr = clampi(((i->range.CbCr_bias << 7) + v + 64) >> 7, i->range.CbCrMin, i->range.CbCrMax);
}

static void fixed422_c(const Info *i, const float *a0, const float *a1, int32_t *cb, int32_t *cr)
{
    int32_t r = (int32_t)(a0[1] + a1[1]), g = (int32_t)(a0[2] + a1[2]), b = (int32_t)(a0[3] + a1[3]);
    int32_t u = q15(r, i->m[3], 10) + q15(g, i->m[4], 10) + q15(b, i->m[5], 10);
    int32_t v = q15(r, i->m[5], 10) + q15(g, i->m[6], 10) + q15(b, i->m[7], 10);
    *cb = clampi(((i->range.CbCr_bias << 6) + u + 32) >> 6, i->range.CbCrMin, i->range.CbCrMax);
    *cr = clampi(((i->range.CbCr_bias << 6) + v + 32) >> 6, i->range.CbCrMin, i->range.CbCrMax);
}

static inline void put_le32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

static vImage_Error rgb_to_packed(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_ARGBToYpCbCr *info,
                                  const uint8_t *perm, Packing p, vImageARGBType in, vImage_Flags flags)
{
    ToYCbCr t;
    CHECK(to_ycbcr_check(info, perm, flags, &t, in));
    TEMP_QUERY(flags);
    CHECK(fits(dest, src));
    int group = p == V210 ? 6 : (p == YUVS || p == TWO_VUY || p == V216) ? 2 : 1;
    for (vImagePixelCount y = 0; y < dest->height; ++y) {
        const uint8_t *row = CROW(src, y);
        uint8_t *o = ROW(dest, y);
        for (vImagePixelCount x0 = 0; x0 < dest->width; x0 += (vImagePixelCount)group) {
            float argb[6][4];
            int32_t ys[6], cbs[3], crs[3];
            int n = (int)(dest->width - x0 < (vImagePixelCount)group ? dest->width - x0 : (vImagePixelCount)group);
            /* 8-bit 4:4:4 and 4:2:2 as Apple's fixed point, the rest in single precision */
            bool fixed = in == kvImageARGB8888 && t.info->depth == 8;
            for (int k = 0; k < group; ++k) {
                argb_of(&t, row, x0 + (vImagePixelCount)(k < n ? k : n - 1), argb[k]);
                ys[k] = fixed && group == 2 ? fixed422_y(t.info, argb[k]) : y_of(t.info, argb[k]);
            }
            for (int k = 0; k < (group == 1 ? 1 : group / 2); ++k) {
                if (fixed && group == 1)
                    fixed444(t.info, argb[0], &ys[0], &cbs[0], &crs[0]);
                else if (fixed)
                    fixed422_c(t.info, argb[2 * k], argb[2 * k + 1], &cbs[k], &crs[k]);
                else
                    chroma_of(t.info, (const float(*)[4])argb + (group == 1 ? 0 : 2 * k), group == 1 ? 1 : 2, &cbs[k],
                              &crs[k]);
            }
            switch (p) {
            case YUVS: {
                uint8_t *q = o + 2 * x0;
                q[0] = (uint8_t)ys[0], q[1] = (uint8_t)cbs[0], q[2] = (uint8_t)ys[1], q[3] = (uint8_t)crs[0];
                break;
            }
            case TWO_VUY: {
                uint8_t *q = o + 2 * x0;
                q[0] = (uint8_t)cbs[0], q[1] = (uint8_t)ys[0], q[2] = (uint8_t)crs[0], q[3] = (uint8_t)ys[1];
                break;
            }
            case R408: {
                uint8_t *q = o + 4 * x0;
                q[0] = (uint8_t)argb[0][0], q[1] = (uint8_t)ys[0], q[2] = (uint8_t)cbs[0], q[3] = (uint8_t)crs[0];
                break;
            }
            case V408: {
                uint8_t *q = o + 4 * x0;
                q[0] = (uint8_t)cbs[0], q[1] = (uint8_t)ys[0], q[2] = (uint8_t)crs[0], q[3] = (uint8_t)argb[0][0];
                break;
            }
            case V308: {
                uint8_t *q = o + 3 * x0;
                q[0] = (uint8_t)crs[0], q[1] = (uint8_t)ys[0], q[2] = (uint8_t)cbs[0];
                break;
            }
            case V410:
                put_le32(o + 4 * x0, (uint32_t)crs[0] << 22 | (uint32_t)ys[0] << 12 | (uint32_t)cbs[0] << 2);
                break;
            case V210: {
                uint8_t *q = o + 16 * (x0 / 6);
                const int32_t s[12] = {cbs[0], ys[0], crs[0], ys[1], cbs[1], ys[2], crs[1], ys[3], cbs[2], ys[4], crs[2], ys[5]};
                for (int w = 0; w < 4; ++w)
                    put_le32(q + 4 * w, (uint32_t)s[3 * w] | (uint32_t)s[3 * w + 1] << 10 | (uint32_t)s[3 * w + 2] << 20);
                break;
            }
            case V216: {
                uint16_t *q = (uint16_t *)o + 2 * x0;
                q[0] = (uint16_t)cbs[0], q[1] = (uint16_t)ys[0], q[2] = (uint16_t)crs[0], q[3] = (uint16_t)ys[1];
                break;
            }
            default: { /* Y416 */
                uint16_t *q = (uint16_t *)o + 4 * x0;
                float a = argb[0][0];
                q[0] = (uint16_t)(in == kvImageARGB8888 ? a * 257 : a), q[1] = (uint16_t)ys[0], q[2] = (uint16_t)cbs[0],
                q[3] = (uint16_t)crs[0];
                break;
            }
            }
        }
    }
    return kvImageNoError;
}

#define TO_PACKED(name, P, IN)                                                                           \
    vImage_Error name(const vImage_Buffer *src, const vImage_Buffer *dest, const vImage_ARGBToYpCbCr *info, \
                      const uint8_t permuteMap[4], vImage_Flags flags)                                   \
    {                                                                                                    \
        return rgb_to_packed(src, dest, info, permuteMap, P, IN, flags);                                 \
    }
TO_PACKED(vImageConvert_ARGB8888To422YpCbYpCr8, YUVS, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB8888To422CbYpCrYp8, TWO_VUY, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB8888To444AYpCbCr8, R408, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB8888To444CbYpCrA8, V408, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB8888To444CrYpCb8, V308, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB8888To444CrYpCb10, V410, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB16Q12To444CrYpCb10, V410, kvImageARGB16Q12)
TO_PACKED(vImageConvert_ARGB8888To422CrYpCbYpCbYpCbYpCrYpCrYp10, V210, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB16Q12To422CrYpCbYpCbYpCbYpCrYpCrYp10, V210, kvImageARGB16Q12)
TO_PACKED(vImageConvert_ARGB8888To422CbYpCrYp16, V216, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB16UTo422CbYpCrYp16, V216, kvImageARGB16U)
TO_PACKED(vImageConvert_ARGB8888To444AYpCbCr16, Y416, kvImageARGB8888)
TO_PACKED(vImageConvert_ARGB16UTo444AYpCbCr16, Y416, kvImageARGB16U)

vImage_Error vImageConvert_ARGB8888To422CbYpCrYp8_AA8(const vImage_Buffer *src, const vImage_Buffer *dest,
                                                       const vImage_Buffer *destA, const vImage_ARGBToYpCbCr *info,
                                                       const uint8_t permuteMap[4], vImage_Flags flags)
{
    CHECK(rgb_to_packed(src, dest, info, permuteMap, TWO_VUY, kvImageARGB8888, flags));
    if (flags & kvImageGetTempBufferSize)
        return 0;
    CHECK(fits(destA, src));
    const uint8_t *perm = permuteMap ? permuteMap : identity;
    for (vImagePixelCount y = 0; y < destA->height; ++y)
        for (vImagePixelCount x = 0; x < destA->width; ++x)
            ROW(destA, y)[x] = CROW(src, y)[4 * x + perm[0]];
    return kvImageNoError;
}

static vImage_Error rgb_to_420(const vImage_Buffer *src, const vImage_Buffer *destY, const vImage_Buffer *destCb,
                               const vImage_Buffer *destCr, const vImage_ARGBToYpCbCr *info, const uint8_t *perm,
                               vImage_Flags flags)
{
    ToYCbCr t;
    CHECK(to_ycbcr_check(info, perm, flags, &t, kvImageARGB8888));
    TEMP_QUERY(flags);
    CHECK(fits(destY, src));
    if (!destCb || !destCb->data || (destCr && !destCr->data))
        return kvImageNullPointerArgument;
    for (vImagePixelCount y = 0; y < destY->height; y += 2)
        for (vImagePixelCount x = 0; x < destY->width; x += 2) {
            float argb[4][4];
            int n = 0;
            for (vImagePixelCount dy = 0; dy < 2; ++dy)
                for (vImagePixelCount dx = 0; dx < 2; ++dx) {
                    vImagePixelCount yy = y + dy < destY->height ? y + dy : y, xx = x + dx < destY->width ? x + dx : x;
                    argb_of(&t, CROW(src, yy), xx, argb[n]);
                    if (y + dy < destY->height && x + dx < destY->width)
                        ROW(destY, y + dy)[x + dx] = (uint8_t)fixed422_y(t.info, argb[n]);
                    ++n;
                }
            int32_t cb, cr;
            fixed420_c(t.info, (const float(*)[4])argb, &cb, &cr);
            if (destCr) {
                ROW(destCb, y / 2)[x / 2] = (uint8_t)cb;
                ROW(destCr, y / 2)[x / 2] = (uint8_t)cr;
            } else {
                ROW(destCb, y / 2)[x] = (uint8_t)cb;
                ROW(destCb, y / 2)[x + 1] = (uint8_t)cr;
            }
        }
    return kvImageNoError;
}

vImage_Error vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(const vImage_Buffer *src, const vImage_Buffer *destYp,
                                                     const vImage_Buffer *destCb, const vImage_Buffer *destCr,
                                                     const vImage_ARGBToYpCbCr *info, const uint8_t permuteMap[4],
                                                     vImage_Flags flags)
{
    if (!destCr)
        return kvImageNullPointerArgument;
    return rgb_to_420(src, destYp, destCb, destCr, info, permuteMap, flags);
}
vImage_Error vImageConvert_ARGB8888To420Yp8_CbCr8(const vImage_Buffer *src, const vImage_Buffer *destYp,
                                                   const vImage_Buffer *destCbCr, const vImage_ARGBToYpCbCr *info,
                                                   const uint8_t permuteMap[4], vImage_Flags flags)
{
    return rgb_to_420(src, destYp, destCbCr, NULL, info, permuteMap, flags);
}

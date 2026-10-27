/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP's conversions between floating point and integers: vfix (toward zero), vfixr
 * (to nearest), their unsigned forms, vflt, 24-bit packed integers with scaling, and
 * single to double precision and back. The scaled 24-bit conversions clamp to the
 * destination's range, as vDSP.h says.
 */
#include <Accelerate/Accelerate.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>

#define AT(p, s, i) ((p)[(ptrdiff_t)(s) * (ptrdiff_t)(i)])

static inline double clampd(double v, double low, double high)
{
    if (isnan(v))
        return 0;
    return v < low ? low : v > high ? high : v;
}

/* Out-of-range values come out as Apple's vector units produce them: through a
   saturating 32- or 64-bit conversion (NaN giving 0) and then the low bits. */
static inline int64_t s64(double v) { return (int64_t)clampd(v, -0x1p63, 0x1.fffffffffffffp62); }
static inline uint64_t u64(double v) { return v >= 0x1p64 ? UINT64_MAX : (uint64_t)clampd(v, 0, 0x1p64); }
static inline int32_t s32(double v) { return (int32_t)clampd(v, INT32_MIN, INT32_MAX); }
static inline uint32_t u32(double v) { return (uint32_t)clampd(v, 0, UINT32_MAX); }
/* unsigned saturation of a 32-bit pattern to 16 bits */
static inline uint16_t usat16(int32_t v) { return (uint32_t)v > UINT16_MAX ? UINT16_MAX : (uint16_t)v; }

#define FIX(name, S, DT, EXPR)                                                                           \
    void name(const S *A, vDSP_Stride IA, DT *C, vDSP_Stride IC, vDSP_Length N)                         \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            double x = (double)AT(A, IA, n);                                                             \
            AT(C, IC, n) = (DT)(EXPR);                                                                   \
        }                                                                                                \
    }

FIX(vDSP_vfix8, float, char, s32(trunc(x)))
FIX(vDSP_vfix16, float, short, s32(trunc(x)))
FIX(vDSP_vfix32, float, int, s32(trunc(x)))
FIX(vDSP_vfixr8, float, char, s32(rint(x)))
FIX(vDSP_vfixr16, float, short, s32(rint(x)))
FIX(vDSP_vfixr32, float, int, s32(rint(x)))
FIX(vDSP_vfixu8, float, unsigned char, s32(trunc(x)))
FIX(vDSP_vfixu16, float, unsigned short, usat16(s32(trunc(x))))
FIX(vDSP_vfixu32, float, unsigned int, u32(trunc(x)))
FIX(vDSP_vfixru8, float, unsigned char, u32(rint(x)))
FIX(vDSP_vfixru16, float, unsigned short, s64(rint(x)))
FIX(vDSP_vfixru32, float, unsigned int, s64(rint(x)))
FIX(vDSP_vfix8D, double, char, s64(trunc(x)))
FIX(vDSP_vfix16D, double, short, s64(trunc(x)))
FIX(vDSP_vfix32D, double, int, s64(trunc(x)))
FIX(vDSP_vfixr8D, double, char, s64(rint(x)))
FIX(vDSP_vfixr16D, double, short, s64(rint(x)))
FIX(vDSP_vfixr32D, double, int, s64(rint(x)))
FIX(vDSP_vfixu8D, double, unsigned char, s64(trunc(x)))
FIX(vDSP_vfixu16D, double, unsigned short, s64(trunc(x)))
FIX(vDSP_vfixu32D, double, unsigned int, u64(trunc(x)))
FIX(vDSP_vfixru8D, double, unsigned char, s64(rint(x)))
FIX(vDSP_vfixru16D, double, unsigned short, s64(rint(x)))
FIX(vDSP_vfixru32D, double, unsigned int, s64(rint(x)))

#define FLT(name, S, DT)                                                                                 \
    void name(const S *A, vDSP_Stride IA, DT *C, vDSP_Stride IC, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = (DT)AT(A, IA, n);                                                              \
    }
#define FLT_BOTH(base, S)                                                                                \
    FLT(base, S, float)                                                                                  \
    FLT(base##D, S, double)

FLT_BOTH(vDSP_vflt8, char)
FLT_BOTH(vDSP_vflt16, short)
FLT_BOTH(vDSP_vflt32, int)
FLT_BOTH(vDSP_vfltu8, unsigned char)
FLT_BOTH(vDSP_vfltu16, unsigned short)
FLT_BOTH(vDSP_vfltu32, unsigned int)
FLT(vDSP_vspdp, float, double)
FLT(vDSP_vdpsp, double, float)

/* 24-bit integers: three bytes, least significant first. */
static inline int32_t int24(const vDSP_int24 *v)
{
    int32_t x = (int32_t)v->bytes[0] | ((int32_t)v->bytes[1] << 8) | ((int32_t)v->bytes[2] << 16);
    return (x ^ 0x800000) - 0x800000;
}

static inline uint32_t uint24(const vDSP_uint24 *v)
{
    return (uint32_t)v->bytes[0] | ((uint32_t)v->bytes[1] << 8) | ((uint32_t)v->bytes[2] << 16);
}

static inline void store24(uint8_t *bytes, uint32_t x)
{
    bytes[0] = (uint8_t)x;
    bytes[1] = (uint8_t)(x >> 8);
    bytes[2] = (uint8_t)(x >> 16);
}

void vDSP_vflt24(const vDSP_int24 *A, vDSP_Stride IA, float *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = (float)int24(&AT(A, IA, n));
}

void vDSP_vfltu24(const vDSP_uint24 *A, vDSP_Stride IA, float *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = (float)uint24(&AT(A, IA, n));
}

void vDSP_vfltsm24(const vDSP_int24 *A, vDSP_Stride IA, const float *B, float *C, vDSP_Stride IC, vDSP_Length N)
{
    float b = *B;
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = b * (float)int24(&AT(A, IA, n));
}

void vDSP_vfltsmu24(const vDSP_uint24 *A, vDSP_Stride IA, const float *B, float *C, vDSP_Stride IC, vDSP_Length N)
{
    float b = *B;
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = b * (float)uint24(&AT(A, IA, n));
}

void vDSP_vsmfix24(const float *A, vDSP_Stride IA, const float *B, vDSP_int24 *C, vDSP_Stride IC, vDSP_Length N)
{
    float b = *B;
    for (vDSP_Length n = 0; n < N; ++n) {
        double v = clampd(trunc((double)AT(A, IA, n) * b), -8388608.0, 8388607.0);
        store24(AT(C, IC, n).bytes, (uint32_t)(int32_t)v);
    }
}

void vDSP_vsmfixu24(const float *A, vDSP_Stride IA, const float *B, vDSP_uint24 *C, vDSP_Stride IC, vDSP_Length N)
{
    float b = *B;
    for (vDSP_Length n = 0; n < N; ++n) {
        double v = clampd(trunc((double)AT(A, IA, n) * b), 0.0, 16777215.0);
        store24(AT(C, IC, n).bytes, (uint32_t)v);
    }
}

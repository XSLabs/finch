/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vfp.h: libm's single-precision functions over the four lanes of a vFloat.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>

#define LANES 4

/* Apple's give +0 at the integers */
static float sinpi_f(float v) { return v == rintf(v) ? 0.0f : __sinpif(v); }
static float tanpi_f(float v) { return v == rintf(v) ? 0.0f : __tanpif(v); }

#define UNARY(name, EXPR)                                                                                \
    vFloat name(vFloat x)                                                                                \
    {                                                                                                    \
        vFloat r;                                                                                        \
        for (int i = 0; i < LANES; ++i) {                                                                \
            float v = x[i];                                                                              \
            r[i] = (EXPR);                                                                               \
        }                                                                                                \
        return r;                                                                                        \
    }
#define BINARY(name, EXPR)                                                                               \
    vFloat name(vFloat x, vFloat y)                                                                      \
    {                                                                                                    \
        vFloat r;                                                                                        \
        for (int i = 0; i < LANES; ++i) {                                                                \
            float a = x[i], b = y[i];                                                                    \
            r[i] = (EXPR);                                                                               \
        }                                                                                                \
        return r;                                                                                        \
    }

UNARY(vceilf, ceilf(v))
UNARY(vfloorf, floorf(v))
UNARY(vtruncf, truncf(v))
UNARY(vintf, truncf(v))
UNARY(vnintf, rintf(v))
UNARY(vexpf, expf(v))
UNARY(vexp2f, exp2f(v))
UNARY(vexpm1f, expm1f(v))
UNARY(vlogf, logf(v))
UNARY(vlog2f, log2f(v))
UNARY(vlog10f, log10f(v))
UNARY(vlog1pf, log1pf(v))
UNARY(vlogbf, logbf(v))
UNARY(vsinf, sinf(v))
UNARY(vcosf, cosf(v))
UNARY(vtanf, tanf(v))
UNARY(vsinpif, sinpi_f(v))
UNARY(vcospif, __cospif(v))
UNARY(vtanpif, tanpi_f(v))
UNARY(vasinf, asinf(v))
UNARY(vacosf, acosf(v))
UNARY(vatanf, atanf(v))
UNARY(vsinhf, sinhf(v))
UNARY(vcoshf, coshf(v))
UNARY(vtanhf, tanhf(v))
UNARY(vasinhf, asinhf(v))
UNARY(vacoshf, acoshf(v))
UNARY(vatanhf, atanhf(v))
UNARY(vrecf, 1 / v)
UNARY(vsqrtf, sqrtf(v))
UNARY(vrsqrtf, 1 / sqrtf(v))
UNARY(vfabsf, fabsf(v))
UNARY(vfabf, fabsf(v))
BINARY(vatan2f, atan2f(a, b))
BINARY(vpowf, powf(a, b))
BINARY(vdivf, a / b)
BINARY(vfmodf, fmodf(a, b))
BINARY(vremainderf, remainderf(a, b) + 0.0f)
BINARY(vcopysignf, copysignf(a, b))
BINARY(vnextafterf, nextafterf(a, b))

vFloat vscalbf(vFloat x, vSInt32 n)
{
    vFloat r;
    for (int i = 0; i < LANES; ++i)
        r[i] = scalbnf(x[i], n[i]);
    return r;
}

vFloat vipowf(vFloat x, vSInt32 n)
{
    vFloat r;
    for (int i = 0; i < LANES; ++i)
        r[i] = powf(x[i], (float)n[i]);
    return r;
}

/* returns the cosines, and stores the sines */
vFloat vsincosf(vFloat x, vFloat *sine)
{
    vFloat c;
    for (int i = 0; i < LANES; ++i) {
        c[i] = cosf(x[i]);
        (*sine)[i] = sinf(x[i]);
    }
    return c;
}

vFloat vremquof(vFloat x, vFloat y, vUInt32 *quotient)
{
    vFloat r;
    for (int i = 0; i < LANES; ++i) {
        int q;
        r[i] = remquof(x[i], y[i], &q);
        (*quotient)[i] = (uint32_t)q;
    }
    return r;
}

vUInt32 vsignbitf(vFloat x)
{
    vUInt32 r;
    for (int i = 0; i < LANES; ++i)
        r[i] = signbit(x[i]) ? 1 : 0;
    return r;
}

vUInt32 vclassifyf(vFloat x)
{
    vUInt32 r;
    for (int i = 0; i < LANES; ++i)
        r[i] = (uint32_t)fpclassify(x[i]);
    return r;
}

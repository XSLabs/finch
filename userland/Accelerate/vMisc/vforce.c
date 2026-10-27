/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vForce: libm's functions over arrays, in single and double precision, as vForce.h
 * describes them. Each is also exported under the Fortran names (vvexpf_, VVEXPF and
 * VVEXPF_), which take the same arguments.
 */
#include <Accelerate/Accelerate.h>
#include <complex.h>
#include <math.h>

#define FORTRAN(name, UPPER, PARAMS, ARGS)                                                               \
    void name##_ PARAMS { name ARGS; }                                                                   \
    void UPPER PARAMS { name ARGS; }                                                                     \
    void UPPER##_ PARAMS { name ARGS; }

/* At the integers Apple's sinpi and tanpi give +0, except double sinpi, whose zero
   takes the sign of x times (-1)**x; remainders of zero are +0. */
static float sinpi_f(float v) { return v == rintf(v) ? 0.0f : __sinpif(v); }
static float tanpi_f(float v) { return v == rintf(v) ? 0.0f : __tanpif(v); }
static double tanpi_d(double v) { return v == rint(v) ? 0.0 : __tanpi(v); }
static double sinpi_d(double v)
{
    if (v != rint(v))
        return __sinpi(v);
    return fmod(v, 2) != 0 ? copysign(0.0, -v) : copysign(0.0, v);
}

/* y[i] = f(x[i]) */
#define UNARY1(name, UPPER, T, EXPR)                                                                     \
    void name(T *y, const T *x, const int *n)                                                            \
    {                                                                                                    \
        for (int i = 0; i < *n; ++i) {                                                                   \
            T v = x[i];                                                                                  \
            y[i] = (EXPR);                                                                               \
        }                                                                                                \
    }                                                                                                    \
    FORTRAN(name, UPPER, (T * y, const T *x, const int *n), (y, x, n))
#define UNARY(base, UPPER, FEXPR, DEXPR)                                                                 \
    UNARY1(base##f, UPPER##F, float, FEXPR)                                                              \
    UNARY1(base, UPPER, double, DEXPR)

/* z[i] = f(y[i], x[i]) */
#define BINARY1(name, UPPER, T, EXPR)                                                                    \
    void name(T *z, const T *y, const T *x, const int *n)                                                \
    {                                                                                                    \
        for (int i = 0; i < *n; ++i) {                                                                   \
            T a = y[i], b = x[i];                                                                        \
            z[i] = (EXPR);                                                                               \
        }                                                                                                \
    }                                                                                                    \
    FORTRAN(name, UPPER, (T * z, const T *y, const T *x, const int *n), (z, y, x, n))
#define BINARY(base, UPPER, FEXPR, DEXPR)                                                                \
    BINARY1(base##f, UPPER##F, float, FEXPR)                                                             \
    BINARY1(base, UPPER, double, DEXPR)

UNARY(vvrec, VVREC, 1 / v, 1 / v)
UNARY(vvsqrt, VVSQRT, sqrtf(v), sqrt(v))
UNARY(vvcbrt, VVCBRT, cbrtf(v), cbrt(v))
UNARY(vvrsqrt, VVRSQRT, 1 / sqrtf(v), 1 / sqrt(v))
UNARY(vvexp, VVEXP, expf(v), exp(v))
UNARY(vvexp2, VVEXP2, exp2f(v), exp2(v))
UNARY(vvexpm1, VVEXPM1, expm1f(v), expm1(v))
UNARY(vvlog, VVLOG, logf(v), log(v))
UNARY(vvlog10, VVLOG10, log10f(v), log10(v))
UNARY(vvlog1p, VVLOG1P, log1pf(v), log1p(v))
UNARY(vvlog2, VVLOG2, log2f(v), log2(v))
UNARY(vvlogb, VVLOGB, logbf(v), logb(v))
UNARY(vvfabs, VVFABS, fabsf(v), fabs(v))
UNARY(vvsin, VVSIN, sinf(v), sin(v))
UNARY(vvcos, VVCOS, cosf(v), cos(v))
UNARY(vvtan, VVTAN, tanf(v), tan(v))
UNARY(vvasin, VVASIN, asinf(v), asin(v))
UNARY(vvacos, VVACOS, acosf(v), acos(v))
UNARY(vvatan, VVATAN, atanf(v), atan(v))
UNARY(vvsinh, VVSINH, sinhf(v), sinh(v))
UNARY(vvcosh, VVCOSH, coshf(v), cosh(v))
UNARY(vvtanh, VVTANH, tanhf(v), tanh(v))
UNARY(vvasinh, VVASINH, asinhf(v), asinh(v))
UNARY(vvacosh, VVACOSH, acoshf(v), acosh(v))
UNARY(vvatanh, VVATANH, atanhf(v), atanh(v))
UNARY(vvint, VVINT, truncf(v), trunc(v))
UNARY(vvnint, VVNINT, rintf(v), rint(v))
UNARY(vvceil, VVCEIL, ceilf(v), ceil(v))
UNARY(vvfloor, VVFLOOR, floorf(v), floor(v))
UNARY(vvsinpi, VVSINPI, sinpi_f(v), sinpi_d(v))
UNARY(vvcospi, VVCOSPI, __cospif(v), __cospi(v))
UNARY(vvtanpi, VVTANPI, tanpi_f(v), tanpi_d(v))

BINARY(vvdiv, VVDIV, a / b, a / b)
BINARY(vvpow, VVPOW, powf(b, a), pow(b, a))
BINARY(vvatan2, VVATAN2, atan2f(a, b), atan2(a, b))
BINARY(vvfmod, VVFMOD, fmodf(a, b), fmod(a, b))
BINARY(vvremainder, VVREMAINDER, remainderf(a, b) + 0.0f, remainder(a, b) + 0.0)
BINARY(vvcopysign, VVCOPYSIGN, copysignf(a, b), copysign(a, b))
BINARY(vvnextafter, VVNEXTAFTER, nextafterf(a, b), nextafter(a, b))

/* z[i] = x[i] ** y[0] */
#define POWS(name, UPPER, T, POW)                                                                        \
    void name(T *z, const T *y, const T *x, const int *n)                                                \
    {                                                                                                    \
        for (int i = 0; i < *n; ++i)                                                                     \
            z[i] = POW(x[i], *y);                                                                        \
    }                                                                                                    \
    FORTRAN(name, UPPER, (T * z, const T *y, const T *x, const int *n), (z, y, x, n))
POWS(vvpowsf, VVPOWSF, float, powf)
POWS(vvpows, VVPOWS, double, pow)

/* z[i] = sin(x[i]), y[i] = cos(x[i]) */
#define SINCOS(name, UPPER, T, SIN, COS)                                                                 \
    void name(T *z, T *y, const T *x, const int *n)                                                      \
    {                                                                                                    \
        for (int i = 0; i < *n; ++i) {                                                                   \
            T v = x[i];                                                                                  \
            z[i] = SIN(v);                                                                               \
            y[i] = COS(v);                                                                               \
        }                                                                                                \
    }                                                                                                    \
    FORTRAN(name, UPPER, (T * z, T * y, const T *x, const int *n), (z, y, x, n))
SINCOS(vvsincosf, VVSINCOSF, float, sinf, cosf)
SINCOS(vvsincos, VVSINCOS, double, sin, cos)

/* C[i] = cos(x[i]) + i sin(x[i]) */
#define COSISIN(name, UPPER, T, C, SIN, COS)                                                             \
    void name(C *c, const T *x, const int *n)                                                            \
    {                                                                                                    \
        T *out = (T *)c;                                                                                 \
        for (int i = 0; i < *n; ++i) {                                                                   \
            T v = x[i];                                                                                  \
            out[2 * i] = COS(v);                                                                         \
            out[2 * i + 1] = SIN(v);                                                                     \
        }                                                                                                \
    }                                                                                                    \
    FORTRAN(name, UPPER, (C * c, const T *x, const int *n), (c, x, n))
COSISIN(vvcosisinf, VVCOSISINF, float, __float_complex_t, sinf, cosf)
COSISIN(vvcosisin, VVCOSISIN, double, __double_complex_t, sin, cos)

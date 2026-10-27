/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP's vector routines: arithmetic, reductions, conversions, generators,
 * interpolation, clipping and thresholds, sorting and gathering, as vDSP.h's
 * pseudocode defines them. Each is written once for float and double (the
 * double-precision names end in D); strides count elements.
 */
#include <Accelerate/Accelerate.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AT(p, s, i) ((p)[(ptrdiff_t)(s) * (ptrdiff_t)(i)])

/* MARK: - Arithmetic: one to four vectors and scalars */

#define BINARY(name, T, expr)                                                                            \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N) \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), b = AT(B, IB, n);                                                        \
            AT(C, IC, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* (vsub and vdiv take B first: C = A - B, C = A / B) */
#define BINARY_BA(name, T, expr)                                                                         \
    void name(const T *B, vDSP_Stride IB, const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N) \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), b = AT(B, IB, n);                                                        \
            AT(C, IC, n) = (expr);                                                                       \
        }                                                                                                \
    }
#define VECTOR_SCALAR(name, T, expr)                                                                     \
    void name(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T b = *B;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            AT(C, IC, n) = (expr);                                                                       \
        }                                                                                                \
    }
#define UNARY(name, T, expr)                                                                             \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            AT(C, IC, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* D = f(A, B, C) for three vectors */
#define TERNARY(name, T, expr)                                                                           \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const T *C, vDSP_Stride IC, T *D, \
              vDSP_Stride ID, vDSP_Length N)                                                             \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), b = AT(B, IB, n), c = AT(C, IC, n);                                      \
            AT(D, ID, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* D = f(A, B, c) with c a scalar */
#define TWO_VECTORS_SCALAR(name, T, expr)                                                                \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const T *C, T *D, vDSP_Stride ID,  \
              vDSP_Length N)                                                                             \
    {                                                                                                    \
        T c = *C;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), b = AT(B, IB, n);                                                        \
            AT(D, ID, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* D = f(A, b, C) with b a scalar */
#define VECTOR_SCALAR_VECTOR(name, T, expr)                                                              \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, vDSP_Stride IC, T *D, vDSP_Stride ID,  \
              vDSP_Length N)                                                                             \
    {                                                                                                    \
        T b = *B;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), c = AT(C, IC, n);                                                        \
            AT(D, ID, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* D = f(A, b, c) with b and c scalars */
#define VECTOR_TWO_SCALARS(name, T, expr)                                                                \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, T *D, vDSP_Stride ID, vDSP_Length N)   \
    {                                                                                                    \
        T b = *B, c = *C;                                                                                \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            AT(D, ID, n) = (expr);                                                                       \
        }                                                                                                \
    }
/* E = f(A, B, C, D) for four vectors */
#define QUATERNARY(name, T, expr)                                                                        \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const T *C, vDSP_Stride IC,        \
              const T *D, vDSP_Stride ID, T *E, vDSP_Stride IE, vDSP_Length N)                           \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n), b = AT(B, IB, n), c = AT(C, IC, n), d = AT(D, ID, n);                    \
            AT(E, IE, n) = (expr);                                                                       \
        }                                                                                                \
    }

#define BOTH(macro, name, expr) macro(name, float, expr) macro(name##D, double, expr)

BOTH(BINARY, vDSP_vadd, a + b)
BOTH(BINARY, vDSP_vmul, a * b)
BOTH(BINARY_BA, vDSP_vsub, a - b)
BOTH(BINARY_BA, vDSP_vdiv, a / b)
BOTH(BINARY, vDSP_vmax, a > b ? a : b)
BOTH(BINARY, vDSP_vmin, a < b ? a : b)
BINARY(vDSP_vmaxmg, float, fabsf(a) > fabsf(b) ? fabsf(a) : fabsf(b))
BINARY(vDSP_vmaxmgD, double, fabs(a) > fabs(b) ? fabs(a) : fabs(b))
BINARY(vDSP_vminmg, float, fabsf(a) < fabsf(b) ? fabsf(a) : fabsf(b))
BINARY(vDSP_vminmgD, double, fabs(a) < fabs(b) ? fabs(a) : fabs(b))
BINARY(vDSP_vdist, float, sqrtf(a * a + b * b))
BINARY(vDSP_vdistD, double, sqrt(a * a + b * b))

BOTH(VECTOR_SCALAR, vDSP_vsadd, a + b)
BOTH(VECTOR_SCALAR, vDSP_vsmul, a * b)
BOTH(VECTOR_SCALAR, vDSP_vsdiv, a / b)
BOTH(VECTOR_SCALAR, vDSP_vthr, b <= a ? a : b)
BOTH(VECTOR_SCALAR, vDSP_vthres, b <= a ? a : 0)

BOTH(UNARY, vDSP_vneg, -a)
BOTH(UNARY, vDSP_vsq, a * a)
UNARY(vDSP_vabs, float, fabsf(a))
UNARY(vDSP_vabsD, double, fabs(a))
UNARY(vDSP_vnabs, float, -fabsf(a))
UNARY(vDSP_vnabsD, double, -fabs(a))
UNARY(vDSP_vssq, float, a * fabsf(a))
UNARY(vDSP_vssqD, double, a * fabs(a))
UNARY(vDSP_vfrac, float, a - truncf(a))
UNARY(vDSP_vfracD, double, a - trunc(a))

BOTH(TERNARY, vDSP_vma, a * b + c)
BOTH(TERNARY, vDSP_vmsb, a * b - c)
BOTH(TERNARY, vDSP_vam, (a + b) * c)
BOTH(TERNARY, vDSP_vsbm, (a - b) * c)
BOTH(TWO_VECTORS_SCALAR, vDSP_vmsa, a * b + c)
BOTH(TWO_VECTORS_SCALAR, vDSP_vasm, (a + b) * c)
BOTH(TWO_VECTORS_SCALAR, vDSP_vsbsm, (a - b) * c)
BOTH(TWO_VECTORS_SCALAR, vDSP_vintb, a + c * (b - a))
BOTH(VECTOR_SCALAR_VECTOR, vDSP_vsma, a * b + c)
BOTH(VECTOR_SCALAR_VECTOR, vDSP_vsmsb, a * b - c)
BOTH(VECTOR_TWO_SCALARS, vDSP_vsmsa, a * b + c)
BOTH(VECTOR_TWO_SCALARS, vDSP_vlim, b <= a ? c : -c)
BOTH(VECTOR_TWO_SCALARS, vDSP_vthrsc, b <= a ? c : -c)
BOTH(QUATERNARY, vDSP_vaam, (a + b) * (c + d))
BOTH(QUATERNARY, vDSP_vasbm, (a + b) * (c - d))
BOTH(QUATERNARY, vDSP_vsbsbm, (a - b) * (c - d))
BOTH(QUATERNARY, vDSP_vmma, a * b + c * d)
BOTH(QUATERNARY, vDSP_vmmsb, a * b - c * d)
QUATERNARY(vDSP_vpythg, float, sqrtf((a - c) * (a - c) + (b - d) * (b - d)))
QUATERNARY(vDSP_vpythgD, double, sqrt((a - c) * (a - c) + (b - d) * (b - d)))

#define VSMSMA(name, T)                                                                                  \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, vDSP_Stride IC, const T *D, T *E,     \
              vDSP_Stride IE, vDSP_Length N)                                                             \
    {                                                                                                    \
        T b = *B, d = *D;                                                                                \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(E, IE, n) = AT(A, IA, n) * b + AT(C, IC, n) * d;                                          \
    }
VSMSMA(vDSP_vsmsma, float)
VSMSMA(vDSP_vsmsmaD, double)

#define SVDIV(name, T)                                                                                   \
    void name(const T *A, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T a = *A;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = a / AT(B, IB, n);                                                             \
    }
SVDIV(vDSP_svdiv, float)
SVDIV(vDSP_svdivD, double)

#define VADDSUB(name, T)                                                                                 \
    void name(const T *I0, vDSP_Stride I0S, const T *I1, vDSP_Stride I1S, T *O0, vDSP_Stride O0S, T *O1, \
              vDSP_Stride O1S, vDSP_Length N)                                                            \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T i1 = AT(I1, I1S, n), i0 = AT(I0, I0S, n);                                                  \
            AT(O0, O0S, n) = i1 + i0;                                                                    \
            AT(O1, O1S, n) = i1 - i0;                                                                    \
        }                                                                                                \
    }
VADDSUB(vDSP_vaddsub, float)
VADDSUB(vDSP_vaddsubD, double)

/* Integer vectors */
void vDSP_vaddi(const int *A, vDSP_Stride IA, const int *B, vDSP_Stride IB, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = (int)((unsigned)AT(A, IA, n) + (unsigned)AT(B, IB, n));
}
void vDSP_vdivi(const int *B, vDSP_Stride IB, const int *A, vDSP_Stride IA, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n) {
        int b = AT(B, IB, n), a = AT(A, IA, n);
        AT(C, IC, n) = b == 0 ? 0 : (b == -1 && a == INT_MIN) ? INT_MIN : a / b;
    }
}
void vDSP_vsaddi(const int *A, vDSP_Stride IA, const int *B, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = (int)((unsigned)AT(A, IA, n) + (unsigned)*B);
}
void vDSP_vsdivi(const int *A, vDSP_Stride IA, const int *B, int *C, vDSP_Stride IC, vDSP_Length N)
{
    int b = *B;
    for (vDSP_Length n = 0; n < N; ++n) {
        int a = AT(A, IA, n);
        AT(C, IC, n) = b == 0 ? 0 : (b == -1 && a == INT_MIN) ? INT_MIN : a / b;
    }
}
void vDSP_vabsi(const int *A, vDSP_Stride IA, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n) {
        int a = AT(A, IA, n);
        AT(C, IC, n) = a < 0 ? (int)(0u - (unsigned)a) : a;
    }
}
/* (bitwise equivalence: the complement of exclusive or) */
void vDSP_veqvi(const int *A, vDSP_Stride IA, const int *B, vDSP_Stride IB, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = ~(AT(A, IA, n) ^ AT(B, IB, n));
}
void vDSP_vfilli(const int *A, int *C, vDSP_Stride IC, vDSP_Length N)
{
    for (vDSP_Length n = 0; n < N; ++n)
        AT(C, IC, n) = *A;
}

/* MARK: - Fill, clear, generate, ramp */

#define FILL(name, T)                                                                                    \
    void name(const T *A, T *C, vDSP_Stride IC, vDSP_Length N)                                          \
    {                                                                                                    \
        T a = *A;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = a;                                                                            \
    }
FILL(vDSP_vfill, float)
FILL(vDSP_vfillD, double)

#define CLEAR(name, T)                                                                                   \
    void name(T *C, vDSP_Stride IC, vDSP_Length N)                                                      \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = 0;                                                                            \
    }
CLEAR(vDSP_vclr, float)
CLEAR(vDSP_vclrD, double)

#define RAMP(name, T)                                                                                    \
    void name(const T *A, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)                              \
    {                                                                                                    \
        T a = *A, b = *B;                                                                                \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = a + (T)n * b;                                                                 \
    }
RAMP(vDSP_vramp, float)
RAMP(vDSP_vrampD, double)

#define GEN(name, T)                                                                                     \
    void name(const T *A, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)                              \
    {                                                                                                    \
        T a = *A, b = *B;                                                                                \
        if (N == 1) {                                                                                    \
            AT(C, IC, 0) = a;                                                                            \
            return;                                                                                      \
        }                                                                                                \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = a + (b - a) * (T)n / (T)(N - 1);                                              \
    }
GEN(vDSP_vgen, float)
GEN(vDSP_vgenD, double)

#define GENP(name, T)                                                                                    \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N, \
              vDSP_Length M)                                                                             \
    {                                                                                                    \
        if (M == 0)                                                                                      \
            return;                                                                                      \
        vDSP_Length m = 0;                                                                               \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T x = (T)n;                                                                                  \
            if (x <= AT(B, IB, 0))                                                                       \
                AT(C, IC, n) = AT(A, IA, 0);                                                             \
            else if (AT(B, IB, M - 1) < x)                                                               \
                AT(C, IC, n) = AT(A, IA, M - 1);                                                         \
            else {                                                                                       \
                while (m + 1 < M && AT(B, IB, m + 1) < x)                                                \
                    ++m;                                                                                 \
                T b0 = AT(B, IB, m), b1 = AT(B, IB, m + 1), a0 = AT(A, IA, m), a1 = AT(A, IA, m + 1);    \
                AT(C, IC, n) = a0 + (a1 - a0) * (x - b0) / (b1 - b0);                                    \
            }                                                                                            \
        }                                                                                                \
    }
GENP(vDSP_vgenp, float)
GENP(vDSP_vgenpD, double)

/* Ramps that multiply (and add): *Start advances by *Step for each element. */
#define RAMPMUL(name, T, op)                                                                             \
    void name(const T *I, vDSP_Stride IS, T *Start, const T *Step, T *O, vDSP_Stride OS, vDSP_Length N) \
    {                                                                                                    \
        T s = *Start, step = *Step;                                                                      \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            AT(O, OS, n) op s * AT(I, IS, n);                                                            \
            s += step;                                                                                   \
        }                                                                                                \
        *Start = s;                                                                                      \
    }
RAMPMUL(vDSP_vrampmul, float, =)
RAMPMUL(vDSP_vrampmulD, double, =)
RAMPMUL(vDSP_vrampmuladd, float, +=)
RAMPMUL(vDSP_vrampmuladdD, double, +=)

#define RAMPMUL2(name, T, op)                                                                            \
    void name(const T *I0, const T *I1, vDSP_Stride IS, T *Start, const T *Step, T *O0, T *O1,          \
              vDSP_Stride OS, vDSP_Length N)                                                             \
    {                                                                                                    \
        T s = *Start, step = *Step;                                                                      \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            AT(O0, OS, n) op s * AT(I0, IS, n);                                                          \
            AT(O1, OS, n) op s * AT(I1, IS, n);                                                          \
            s += step;                                                                                   \
        }                                                                                                \
        *Start = s;                                                                                      \
    }
RAMPMUL2(vDSP_vrampmul2, float, =)
RAMPMUL2(vDSP_vrampmul2D, double, =)
RAMPMUL2(vDSP_vrampmuladd2, float, +=)
RAMPMUL2(vDSP_vrampmuladd2D, double, +=)

/* Fixed-point ramps: 1.15 (short, x/32768) and 8.24 (int, x/16777216), saturating. */
static inline short sat16(int64_t v) { return (short)(v > SHRT_MAX ? SHRT_MAX : v < SHRT_MIN ? SHRT_MIN : v); }
static inline int sat32(int64_t v) { return (int)(v > INT_MAX ? INT_MAX : v < INT_MIN ? INT_MIN : v); }

#define RAMPMUL_FIXED(name, T, wide, shift, sat, add)                                                    \
    void name(const T *I, vDSP_Stride IS, T *Start, const T *Step, T *O, vDSP_Stride OS, vDSP_Length N) \
    {                                                                                                    \
        wide s = *Start, step = *Step;                                                                   \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            int64_t product = ((int64_t)s * AT(I, IS, n)) >> shift;                                      \
            AT(O, OS, n) = sat((add ? (int64_t)AT(O, OS, n) : 0) + product);                             \
            s = sat(s + step);                                                                           \
        }                                                                                                \
        *Start = (T)s;                                                                                   \
    }
RAMPMUL_FIXED(vDSP_vrampmul_s1_15, short, int64_t, 15, sat16, 0)
RAMPMUL_FIXED(vDSP_vrampmuladd_s1_15, short, int64_t, 15, sat16, 1)
RAMPMUL_FIXED(vDSP_vrampmul_s8_24, int, int64_t, 24, sat32, 0)
RAMPMUL_FIXED(vDSP_vrampmuladd_s8_24, int, int64_t, 24, sat32, 1)

#define RAMPMUL2_FIXED(name, T, shift, sat, add)                                                         \
    void name(const T *I0, const T *I1, vDSP_Stride IS, T *Start, const T *Step, T *O0, T *O1,          \
              vDSP_Stride OS, vDSP_Length N)                                                             \
    {                                                                                                    \
        int64_t s = *Start, step = *Step;                                                                \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            AT(O0, OS, n) = sat((add ? (int64_t)AT(O0, OS, n) : 0) + ((s * AT(I0, IS, n)) >> shift));    \
            AT(O1, OS, n) = sat((add ? (int64_t)AT(O1, OS, n) : 0) + ((s * AT(I1, IS, n)) >> shift));    \
            s = sat(s + step);                                                                           \
        }                                                                                                \
        *Start = (T)s;                                                                                   \
    }
RAMPMUL2_FIXED(vDSP_vrampmul2_s1_15, short, 15, sat16, 0)
RAMPMUL2_FIXED(vDSP_vrampmuladd2_s1_15, short, 15, sat16, 1)
RAMPMUL2_FIXED(vDSP_vrampmul2_s8_24, int, 24, sat32, 0)
RAMPMUL2_FIXED(vDSP_vrampmuladd2_s8_24, int, 24, sat32, 1)

/* MARK: - Clipping, limits and envelopes */

#define CLIP(name, T)                                                                                    \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, T *D, vDSP_Stride ID, vDSP_Length N)   \
    {                                                                                                    \
        T low = *B, high = *C;                                                                           \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T d = AT(A, IA, n);                                                                          \
            if (d < low)                                                                                 \
                d = low;                                                                                 \
            if (high < d)                                                                                \
                d = high;                                                                                \
            AT(D, ID, n) = d;                                                                            \
        }                                                                                                \
    }
CLIP(vDSP_vclip, float)
CLIP(vDSP_vclipD, double)

#define CLIPC(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, T *D, vDSP_Stride ID, vDSP_Length N,   \
              vDSP_Length *NLow, vDSP_Length *NHigh)                                                     \
    {                                                                                                    \
        T low = *B, high = *C;                                                                           \
        vDSP_Length lows = 0, highs = 0;                                                                 \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T d = AT(A, IA, n);                                                                          \
            if (d < low) {                                                                               \
                d = low;                                                                                 \
                ++lows;                                                                                  \
            }                                                                                            \
            if (high < d) {                                                                              \
                d = high;                                                                                \
                ++highs;                                                                                 \
            }                                                                                            \
            AT(D, ID, n) = d;                                                                            \
        }                                                                                                \
        *NLow = lows;                                                                                    \
        *NHigh = highs;                                                                                  \
    }
CLIPC(vDSP_vclipc, float)
CLIPC(vDSP_vclipcD, double)

#define ICLIP(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, const T *C, T *D, vDSP_Stride ID, vDSP_Length N)   \
    {                                                                                                    \
        T low = *B, high = *C;                                                                           \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            AT(D, ID, n) = (a <= low || high <= a) ? a : (a < 0 ? low : high);                           \
        }                                                                                                \
    }
ICLIP(vDSP_viclip, float)
ICLIP(vDSP_viclipD, double)

#define ENVLP(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const T *C, vDSP_Stride IC, T *D,  \
              vDSP_Stride ID, vDSP_Length N)                                                             \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T c = AT(C, IC, n);                                                                          \
            AT(D, ID, n) = (c < AT(B, IB, n) || AT(A, IA, n) < c) ? c : 0;                               \
        }                                                                                                \
    }
ENVLP(vDSP_venvlp, float)
ENVLP(vDSP_venvlpD, double)

/* MARK: - Reductions */

#define REDUCE(name, T, init, step, finish)                                                              \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Length N)                                          \
    {                                                                                                    \
        T acc = init;                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            step;                                                                                        \
        }                                                                                                \
        *C = finish;                                                                                     \
    }
#define SAFE_MEAN(acc, T) (N ? acc / (T)N : (T)NAN)

REDUCE(vDSP_sve, float, 0, acc += a, acc)
REDUCE(vDSP_sveD, double, 0, acc += a, acc)
REDUCE(vDSP_svemg, float, 0, acc += fabsf(a), acc)
REDUCE(vDSP_svemgD, double, 0, acc += fabs(a), acc)
REDUCE(vDSP_svesq, float, 0, acc += a * a, acc)
REDUCE(vDSP_svesqD, double, 0, acc += a * a, acc)
REDUCE(vDSP_svs, float, 0, acc += a * fabsf(a), acc)
REDUCE(vDSP_svsD, double, 0, acc += a * fabs(a), acc)
REDUCE(vDSP_meanv, float, 0, acc += a, SAFE_MEAN(acc, float))
REDUCE(vDSP_meanvD, double, 0, acc += a, SAFE_MEAN(acc, double))
REDUCE(vDSP_meamgv, float, 0, acc += fabsf(a), SAFE_MEAN(acc, float))
REDUCE(vDSP_meamgvD, double, 0, acc += fabs(a), SAFE_MEAN(acc, double))
REDUCE(vDSP_measqv, float, 0, acc += a * a, SAFE_MEAN(acc, float))
REDUCE(vDSP_measqvD, double, 0, acc += a * a, SAFE_MEAN(acc, double))
REDUCE(vDSP_mvessq, float, 0, acc += a * fabsf(a), SAFE_MEAN(acc, float))
REDUCE(vDSP_mvessqD, double, 0, acc += a * fabs(a), SAFE_MEAN(acc, double))
REDUCE(vDSP_rmsqv, float, 0, acc += a * a, sqrtf(SAFE_MEAN(acc, float)))
REDUCE(vDSP_rmsqvD, double, 0, acc += a * a, sqrt(SAFE_MEAN(acc, double)))
REDUCE(vDSP_maxv, float, -INFINITY, acc = a > acc ? a : acc, acc)
REDUCE(vDSP_maxvD, double, -INFINITY, acc = a > acc ? a : acc, acc)
REDUCE(vDSP_minv, float, INFINITY, acc = a < acc ? a : acc, acc)
REDUCE(vDSP_minvD, double, INFINITY, acc = a < acc ? a : acc, acc)
REDUCE(vDSP_maxmgv, float, 0, acc = fabsf(a) > acc ? fabsf(a) : acc, acc)
REDUCE(vDSP_maxmgvD, double, 0, acc = fabs(a) > acc ? fabs(a) : acc, acc)
REDUCE(vDSP_minmgv, float, INFINITY, acc = fabsf(a) < acc ? fabsf(a) : acc, acc)
REDUCE(vDSP_minmgvD, double, INFINITY, acc = fabs(a) < acc ? fabs(a) : acc, acc)

/* (the index is of the first element with the value, times the stride) */
#define REDUCE_INDEX(name, T, init, better, value)                                                       \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Length *I, vDSP_Length N)                          \
    {                                                                                                    \
        T best = init;                                                                                   \
        vDSP_Length index = 0;                                                                           \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T v = value(AT(A, IA, n));                                                                   \
            if (v better best || (n == 0 && !(best better v))) {                                         \
                best = v;                                                                                \
                index = n * (vDSP_Length)IA;                                                             \
            }                                                                                            \
        }                                                                                                \
        *C = best;                                                                                       \
        *I = index;                                                                                      \
    }
#define IDENTITY(x) (x)
REDUCE_INDEX(vDSP_maxvi, float, -INFINITY, >, IDENTITY)
REDUCE_INDEX(vDSP_maxviD, double, -INFINITY, >, IDENTITY)
REDUCE_INDEX(vDSP_minvi, float, INFINITY, <, IDENTITY)
REDUCE_INDEX(vDSP_minviD, double, INFINITY, <, IDENTITY)
REDUCE_INDEX(vDSP_maxmgvi, float, 0, >, fabsf)
REDUCE_INDEX(vDSP_maxmgviD, double, 0, >, fabs)
REDUCE_INDEX(vDSP_minmgvi, float, INFINITY, <, fabsf)
REDUCE_INDEX(vDSP_minmgviD, double, INFINITY, <, fabs)

#define SVE_SVESQ(name, T)                                                                               \
    void name(const T *A, vDSP_Stride IA, T *Sum, T *SumOfSquares, vDSP_Length N)                       \
    {                                                                                                    \
        T s = 0, q = 0;                                                                                  \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            s += a;                                                                                      \
            q += a * a;                                                                                  \
        }                                                                                                \
        *Sum = s;                                                                                        \
        *SumOfSquares = q;                                                                               \
    }
SVE_SVESQ(vDSP_sve_svesq, float)
SVE_SVESQ(vDSP_sve_svesqD, double)

#define NORMALIZE(name, T, SQRT)                                                                         \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, T *Mean, T *StandardDeviation,           \
              vDSP_Length N)                                                                             \
    {                                                                                                    \
        T s = 0, q = 0;                                                                                  \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            s += a;                                                                                      \
            q += a * a;                                                                                  \
        }                                                                                                \
        T m = s / (T)N, d = SQRT(q / (T)N - m * m);                                                      \
        *Mean = m;                                                                                       \
        *StandardDeviation = d;                                                                          \
        if (C)                                                                                           \
            for (vDSP_Length n = 0; n < N; ++n)                                                          \
                AT(C, IC, n) = (AT(A, IA, n) - m) / d;                                                   \
    }
NORMALIZE(vDSP_normalize, float, sqrtf)
NORMALIZE(vDSP_normalizeD, double, sqrt)

#define DOTPR(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Length N)              \
    {                                                                                                    \
        T sum = 0;                                                                                       \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            sum += AT(A, IA, n) * AT(B, IB, n);                                                          \
        *C = sum;                                                                                        \
    }
DOTPR(vDSP_dotpr, float)
DOTPR(vDSP_dotprD, double)

#define DISTANCESQ(name, T)                                                                              \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Length N)              \
    {                                                                                                    \
        T sum = 0;                                                                                       \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T d = AT(A, IA, n) - AT(B, IB, n);                                                           \
            sum += d * d;                                                                                \
        }                                                                                                \
        *C = sum;                                                                                        \
    }
DISTANCESQ(vDSP_distancesq, float)
DISTANCESQ(vDSP_distancesqD, double)

#define DOTPR2(name, T)                                                                                  \
    void name(const T *A0, vDSP_Stride IA0, const T *A1, vDSP_Stride IA1, const T *B, vDSP_Stride IB,    \
              T *C0, T *C1, vDSP_Length N)                                                               \
    {                                                                                                    \
        T s0 = 0, s1 = 0;                                                                                \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T b = AT(B, IB, n);                                                                          \
            s0 += AT(A0, IA0, n) * b;                                                                    \
            s1 += AT(A1, IA1, n) * b;                                                                    \
        }                                                                                                \
        *C0 = s0;                                                                                        \
        *C1 = s1;                                                                                        \
    }
DOTPR2(vDSP_dotpr2, float)
DOTPR2(vDSP_dotpr2D, double)

void vDSP_dotpr_s1_15(const short *A, vDSP_Stride IA, const short *B, vDSP_Stride IB, short *C, vDSP_Length N)
{
    int64_t sum = 0;
    for (vDSP_Length n = 0; n < N; ++n)
        sum += (int64_t)AT(A, IA, n) * AT(B, IB, n);
    *C = sat16(sum >> 15);
}
void vDSP_dotpr_s8_24(const int *A, vDSP_Stride IA, const int *B, vDSP_Stride IB, int *C, vDSP_Length N)
{
    __int128 sum = 0;
    for (vDSP_Length n = 0; n < N; ++n)
        sum += (__int128)AT(A, IA, n) * AT(B, IB, n);
    sum >>= 24;
    *C = sum > INT_MAX ? INT_MAX : sum < INT_MIN ? INT_MIN : (int)sum;
}
void vDSP_dotpr2_s1_15(const short *A0, vDSP_Stride IA0, const short *A1, vDSP_Stride IA1, const short *B, vDSP_Stride IB,
                       short *C0, short *C1, vDSP_Length N)
{
    vDSP_dotpr_s1_15(A0, IA0, B, IB, C0, N);
    vDSP_dotpr_s1_15(A1, IA1, B, IB, C1, N);
}
void vDSP_dotpr2_s8_24(const int *A0, vDSP_Stride IA0, const int *A1, vDSP_Stride IA1, const int *B, vDSP_Stride IB,
                       int *C0, int *C1, vDSP_Length N)
{
    vDSP_dotpr_s8_24(A0, IA0, B, IB, C0, N);
    vDSP_dotpr_s8_24(A1, IA1, B, IB, C1, N);
}

/* Zero crossings: the B-th sign change's position, and how many were found. */
#define NZCROS(name, T)                                                                                  \
    void name(const T *A, vDSP_Stride IA, vDSP_Length B, vDSP_Length *C, vDSP_Length *D, vDSP_Length N)  \
    {                                                                                                    \
        vDSP_Length found = 0;                                                                           \
        for (vDSP_Length n = 1; n < N; ++n) {                                                            \
            if (signbit(AT(A, IA, n - 1)) != signbit(AT(A, IA, n))) {                                    \
                if (++found == B) {                                                                      \
                    *C = n * (vDSP_Length)IA;                                                            \
                    *D = B;                                                                              \
                    return;                                                                              \
                }                                                                                        \
            }                                                                                            \
        }                                                                                                \
        *C = 0;                                                                                          \
        *D = found;                                                                                      \
    }
NZCROS(vDSP_nzcros, float)
NZCROS(vDSP_nzcrosD, double)

/* MARK: - Running sums, windows and integration */

#define RSUM(name, T)                                                                                    \
    void name(const T *A, vDSP_Stride IA, const T *S, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T scale = *S, sum = 0;                                                                           \
        if (N)                                                                                           \
            AT(C, IC, 0) = 0;                                                                            \
        for (vDSP_Length n = 1; n < N; ++n) {                                                            \
            sum += AT(A, IA, n);                                                                         \
            AT(C, IC, n) = scale * sum;                                                                  \
        }                                                                                                \
    }
RSUM(vDSP_vrsum, float)
RSUM(vDSP_vrsumD, double)

#define SWSUM(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N, vDSP_Length P)           \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T sum = 0;                                                                                   \
            for (vDSP_Length p = 0; p < P; ++p)                                                          \
                sum += AT(A, IA, n + p);                                                                 \
            AT(C, IC, n) = sum;                                                                          \
        }                                                                                                \
    }
SWSUM(vDSP_vswsum, float)
SWSUM(vDSP_vswsumD, double)

#define SWMAX(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N, vDSP_Length W)           \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T best = AT(A, IA, n);                                                                       \
            for (vDSP_Length w = 1; w < W; ++w)                                                          \
                if (AT(A, IA, n + w) > best)                                                             \
                    best = AT(A, IA, n + w);                                                             \
            AT(C, IC, n) = best;                                                                         \
        }                                                                                                \
    }
SWMAX(vDSP_vswmax, float)
SWMAX(vDSP_vswmaxD, double)

#define TRAPZ(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T step = *B, c = 0;                                                                              \
        if (N)                                                                                           \
            AT(C, IC, 0) = 0;                                                                            \
        for (vDSP_Length n = 1; n < N; ++n) {                                                            \
            c += step * (AT(A, IA, n - 1) + AT(A, IA, n)) / 2;                                           \
            AT(C, IC, n) = c;                                                                            \
        }                                                                                                \
    }
TRAPZ(vDSP_vtrapz, float)
TRAPZ(vDSP_vtrapzD, double)

#define SIMPS(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T step = *B;                                                                                     \
        if (N > 0)                                                                                       \
            AT(C, IC, 0) = 0;                                                                            \
        if (N > 1)                                                                                       \
            AT(C, IC, 1) = step * (AT(A, IA, 0) + AT(A, IA, 1)) / 2;                                     \
        for (vDSP_Length n = 2; n < N; ++n)                                                              \
            AT(C, IC, n) = AT(C, IC, n - 2) + step * (AT(A, IA, n - 2) + 4 * AT(A, IA, n - 1) + AT(A, IA, n)) / 3; \
    }
SIMPS(vDSP_vsimps, float)
SIMPS(vDSP_vsimpsD, double)

#define AVLIN(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        T b = *B;                                                                                        \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = (AT(C, IC, n) * b + AT(A, IA, n)) / (b + 1);                                  \
    }
AVLIN(vDSP_vavlin, float)
AVLIN(vDSP_vavlinD, double)

#define TMERG(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N) \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T a = AT(A, IA, n);                                                                          \
            AT(C, IC, n) = N == 1 ? a : a + (AT(B, IB, n) - a) * (T)n / (T)(N - 1);                      \
        }                                                                                                \
    }
TMERG(vDSP_vtmerg, float)
TMERG(vDSP_vtmergD, double)

/* MARK: - Polynomials, interpolation and tables */

#define POLY(name, T)                                                                                    \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N, \
              vDSP_Length P)                                                                             \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T x = AT(B, IB, n), sum = AT(A, IA, 0);                                                      \
            for (vDSP_Length p = 1; p <= P; ++p)                                                         \
                sum = sum * x + AT(A, IA, p);                                                            \
            AT(C, IC, n) = sum;                                                                          \
        }                                                                                                \
    }
POLY(vDSP_vpoly, float)
POLY(vDSP_vpolyD, double)

#define LINT(name, T, TRUNC)                                                                             \
    void name(const T *A, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N, vDSP_Length M) \
    {                                                                                                    \
        (void)M;                                                                                         \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T bn = AT(B, IB, n), b = TRUNC(bn), a = bn - b;                                              \
            ptrdiff_t i = (ptrdiff_t)b;                                                                  \
            AT(C, IC, n) = A[i] + a * (A[i + 1] - A[i]);                                                 \
        }                                                                                                \
    }
LINT(vDSP_vlint, float, truncf)
LINT(vDSP_vlintD, double, trunc)

#define QINT(name, T, TRUNC)                                                                             \
    void name(const T *A, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N, vDSP_Length M) \
    {                                                                                                    \
        (void)M;                                                                                         \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T bn = AT(B, IB, n), t = TRUNC(bn), b = t < 1 ? 1 : t, a = bn - b;                           \
            ptrdiff_t i = (ptrdiff_t)b;                                                                  \
            AT(C, IC, n) = (A[i - 1] * (a * a - a) + A[i] * (2 - 2 * a * a) + A[i + 1] * (a * a + a)) / 2; \
        }                                                                                                \
    }
QINT(vDSP_vqint, float, truncf)
QINT(vDSP_vqintD, double, trunc)

#define INDEX(name, T, TRUNC)                                                                            \
    void name(const T *A, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N)              \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = A[(ptrdiff_t)TRUNC(AT(B, IB, n))];                                            \
    }
INDEX(vDSP_vindex, float, truncf)
INDEX(vDSP_vindexD, double, trunc)

#define TABI(name, T, TRUNC)                                                                             \
    void name(const T *A, vDSP_Stride IA, const T *S1, const T *S2, const T *C, vDSP_Length M, T *D,     \
              vDSP_Stride ID, vDSP_Length N)                                                             \
    {                                                                                                    \
        T s1 = *S1, s2 = *S2;                                                                            \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T p = s1 * AT(A, IA, n) + s2;                                                                \
            if (p < 0)                                                                                   \
                AT(D, ID, n) = C[0];                                                                     \
            else if (p < (T)M - 1) {                                                                     \
                T q = TRUNC(p), r = p - q;                                                               \
                ptrdiff_t i = (ptrdiff_t)q;                                                              \
                AT(D, ID, n) = (1 - r) * C[i] + r * C[i + 1];                                            \
            } else                                                                                       \
                AT(D, ID, n) = C[M - 1];                                                                 \
        }                                                                                                \
    }
TABI(vDSP_vtabi, float, truncf)
TABI(vDSP_vtabiD, double, trunc)

/* MARK: - Gathering, compressing, reversing, swapping, sorting */

#define GATHR(name, T)                                                                                   \
    void name(const T *A, const vDSP_Length *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N)    \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = A[AT(B, IB, n) - 1];                                                          \
    }
GATHR(vDSP_vgathr, float)
GATHR(vDSP_vgathrD, double)

#define GATHRA(name, T)                                                                                  \
    void name(const T *const *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)                   \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = *AT(A, IA, n);                                                                \
    }
GATHRA(vDSP_vgathra, float)
GATHRA(vDSP_vgathraD, double)

#define CMPRS(name, T)                                                                                   \
    void name(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, vDSP_Length N) \
    {                                                                                                    \
        vDSP_Length p = 0;                                                                               \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            if (AT(B, IB, n) != 0)                                                                       \
                AT(C, IC, p++) = AT(A, IA, n);                                                           \
    }
CMPRS(vDSP_vcmprs, float)
CMPRS(vDSP_vcmprsD, double)

#define RVRS(name, T)                                                                                    \
    void name(T *C, vDSP_Stride IC, vDSP_Length N)                                                      \
    {                                                                                                    \
        for (vDSP_Length i = 0, j = N ? N - 1 : 0; i < j; ++i, --j) {                                    \
            T t = AT(C, IC, i);                                                                          \
            AT(C, IC, i) = AT(C, IC, j);                                                                 \
            AT(C, IC, j) = t;                                                                            \
        }                                                                                                \
    }
RVRS(vDSP_vrvrs, float)
RVRS(vDSP_vrvrsD, double)

#define SWAP(name, T)                                                                                    \
    void name(T *A, vDSP_Stride IA, T *B, vDSP_Stride IB, vDSP_Length N)                                \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T t = AT(A, IA, n);                                                                          \
            AT(A, IA, n) = AT(B, IB, n);                                                                 \
            AT(B, IB, n) = t;                                                                            \
        }                                                                                                \
    }
SWAP(vDSP_vswap, float)
SWAP(vDSP_vswapD, double)

#define SORT(name, T)                                                                                    \
    static int name##_up(const void *x, const void *y)                                                   \
    {                                                                                                    \
        T a = *(const T *)x, b = *(const T *)y;                                                          \
        return a < b ? -1 : a > b ? 1 : 0;                                                               \
    }                                                                                                    \
    static int name##_down(const void *x, const void *y) { return name##_up(y, x); }                     \
    void name(T *C, vDSP_Length N, int Order)                                                           \
    {                                                                                                    \
        qsort(C, N, sizeof(T), Order < 0 ? name##_down : name##_up);                                     \
    }
SORT(vDSP_vsort, float)
SORT(vDSP_vsortD, double)

/* The indices sorted by the values they name (a stable merge, so equal values keep their order). */
#define SORTI(name, T)                                                                                   \
    void name(const T *C, vDSP_Length *I, vDSP_Length *Temporary, vDSP_Length N, int Order)             \
    {                                                                                                    \
        (void)Temporary;                                                                                 \
        vDSP_Length *scratch = malloc(N * sizeof(vDSP_Length));                                          \
        if (!scratch)                                                                                    \
            return;                                                                                      \
        for (vDSP_Length width = 1; width < N; width *= 2) {                                             \
            for (vDSP_Length lo = 0; lo < N; lo += 2 * width) {                                          \
                vDSP_Length mid = lo + width < N ? lo + width : N, hi = lo + 2 * width < N ? lo + 2 * width : N; \
                vDSP_Length i = lo, j = mid, k = lo;                                                     \
                while (i < mid && j < hi) {                                                              \
                    T a = C[I[i]], b = C[I[j]];                                                          \
                    int takeRight = Order < 0 ? (b > a) : (b < a);                                       \
                    scratch[k++] = takeRight ? I[j++] : I[i++];                                          \
                }                                                                                        \
                while (i < mid)                                                                          \
                    scratch[k++] = I[i++];                                                               \
                while (j < hi)                                                                           \
                    scratch[k++] = I[j++];                                                               \
            }                                                                                            \
            memcpy(I, scratch, N * sizeof(vDSP_Length));                                                 \
        }                                                                                                \
        free(scratch);                                                                                   \
    }
SORTI(vDSP_vsorti, float)
SORTI(vDSP_vsortiD, double)

/* MARK: - Decibels */

#define DBCON(name, T, LOG10)                                                                            \
    void name(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N, unsigned int F) \
    {                                                                                                    \
        T alpha = F ? 20 : 10, b = *B;                                                                   \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = alpha * LOG10(AT(A, IA, n) / b);                                              \
    }
DBCON(vDSP_vdbcon, float, log10f)
DBCON(vDSP_vdbconD, double, log10)

/* MARK: - Polar and rectangular coordinates (pairs; strides count elements) */

#define POLAR(name, T, SQRT, ATAN2)                                                                      \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T x = A[(ptrdiff_t)n * IA], y = A[(ptrdiff_t)n * IA + 1];                                    \
            C[(ptrdiff_t)n * IC] = SQRT(x * x + y * y);                                                  \
            C[(ptrdiff_t)n * IC + 1] = ATAN2(y, x);                                                      \
        }                                                                                                \
    }
POLAR(vDSP_polar, float, sqrtf, atan2f)
POLAR(vDSP_polarD, double, sqrt, atan2)

#define RECT(name, T, COS, SIN)                                                                          \
    void name(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = A[(ptrdiff_t)n * IA], theta = A[(ptrdiff_t)n * IA + 1];                                \
            C[(ptrdiff_t)n * IC] = r * COS(theta);                                                       \
            C[(ptrdiff_t)n * IC + 1] = r * SIN(theta);                                                   \
        }                                                                                                \
    }
RECT(vDSP_rect, float, cosf, sinf)
RECT(vDSP_rectD, double, cos, sin)

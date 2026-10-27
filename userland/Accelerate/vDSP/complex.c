/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP's split-complex routines (the z* family): arithmetic, magnitudes and phases,
 * dot products, mixed complex and real vectors, spectra, correlation, decimation,
 * matrix products, and conversion to and from interleaved complex. Written once
 * for float and double.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stddef.h>

#define AT(p, s, i) ((p)[(ptrdiff_t)(s) * (ptrdiff_t)(i)])
#define RE(z, s, i) AT((z)->realp, s, i)
#define IM(z, s, i) AT((z)->imagp, s, i)

#define FOR_BOTH(macro)                                                                                  \
    macro(, float, DSPSplitComplex, DSPComplex, sqrtf, atan2f)                                           \
    macro(D, double, DSPDoubleSplitComplex, DSPDoubleComplex, sqrt, atan2)

/* C = f(A, B) elementwise; ar, ai, br, bi name the parts */
#define Z2(suffix, T, Z, ZC, SQRT, ATAN2, name, re, im)                                                  \
    void name##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C, vDSP_Stride IC, \
                      vDSP_Length N)                                                                     \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);                \
            T r = (re), i = (im);                                                                        \
            RE(C, IC, n) = r;                                                                            \
            IM(C, IC, n) = i;                                                                            \
        }                                                                                                \
    }

#define DEFINE_ARITHMETIC(suffix, T, Z, ZC, SQRT, ATAN2)                                                 \
    Z2(suffix, T, Z, ZC, SQRT, ATAN2, vDSP_zvadd, ar + br, ai + bi)                                      \
    Z2(suffix, T, Z, ZC, SQRT, ATAN2, vDSP_zvsub, ar - br, ai - bi)                                      \
    Z2(suffix, T, Z, ZC, SQRT, ATAN2, vDSP_zvcmul, ar * br + ai * bi, ar * bi - ai * br)                 \
                                                                                                         \
    void vDSP_zvmul##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,          \
                            vDSP_Stride IC, vDSP_Length N, int Conjugate)                                \
    {                                                                                                    \
        T sign = Conjugate == -1 ? -1 : 1;                                                               \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = sign * IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);         \
            RE(C, IC, n) = ar * br - ai * bi;                                                            \
            IM(C, IC, n) = ar * bi + ai * br;                                                            \
        }                                                                                                \
    }                                                                                                    \
                                                                                                         \
    /* (B first: C = A / B) */                                                                           \
    void vDSP_zvdiv##suffix(const Z *B, vDSP_Stride IB, const Z *A, vDSP_Stride IA, const Z *C,          \
                            vDSP_Stride IC, vDSP_Length N)                                               \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);                \
            T d = br * br + bi * bi;                                                                     \
            RE(C, IC, n) = (ar * br + ai * bi) / d;                                                      \
            IM(C, IC, n) = (ai * br - ar * bi) / d;                                                      \
        }                                                                                                \
    }                                                                                                    \
                                                                                                         \
    void vDSP_zvconj##suffix(const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC, vDSP_Length N)      \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            RE(C, IC, n) = RE(A, IA, n);                                                                 \
            IM(C, IC, n) = -IM(A, IA, n);                                                                \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvneg##suffix(const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC, vDSP_Length N)       \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            RE(C, IC, n) = -RE(A, IA, n);                                                                \
            IM(C, IC, n) = -IM(A, IA, n);                                                                \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvmov##suffix(const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC, vDSP_Length N)       \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            RE(C, IC, n) = RE(A, IA, n);                                                                 \
            IM(C, IC, n) = IM(A, IA, n);                                                                 \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvfill##suffix(const Z *A, const Z *C, vDSP_Stride IC, vDSP_Length N)                      \
    {                                                                                                    \
        T r = A->realp[0], i = A->imagp[0];                                                              \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            RE(C, IC, n) = r;                                                                            \
            IM(C, IC, n) = i;                                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvabs##suffix(const Z *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)             \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = RE(A, IA, n), i = IM(A, IA, n);                                                        \
            AT(C, IC, n) = SQRT(r * r + i * i);                                                          \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvmags##suffix(const Z *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)            \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = RE(A, IA, n), i = IM(A, IA, n);                                                        \
            AT(C, IC, n) = r * r + i * i;                                                                \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvmgsa##suffix(const Z *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, \
                             vDSP_Length N)                                                              \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = RE(A, IA, n), i = IM(A, IA, n);                                                        \
            AT(C, IC, n) = r * r + i * i + AT(B, IB, n);                                                 \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvphas##suffix(const Z *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length N)            \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(C, IC, n) = ATAN2(IM(A, IA, n), RE(A, IA, n));                                            \
    }                                                                                                    \
                                                                                                         \
    /* D = A * B + C, and with A conjugated */                                                           \
    void vDSP_zvma##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,           \
                           vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length N)                    \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);                \
            T r = ar * br - ai * bi + RE(C, IC, n), i = ar * bi + ai * br + IM(C, IC, n);                \
            RE(D, ID, n) = r;                                                                            \
            IM(D, ID, n) = i;                                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvcma##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,          \
                            vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length N)                   \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = -IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);               \
            T r = ar * br - ai * bi + RE(C, IC, n), i = ar * bi + ai * br + IM(C, IC, n);                \
            RE(D, ID, n) = r;                                                                            \
            IM(D, ID, n) = i;                                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvsma##suffix(const Z *A, vDSP_Stride IA, const Z *B, const Z *C, vDSP_Stride IC,          \
                            const Z *D, vDSP_Stride ID, vDSP_Length N)                                   \
    {                                                                                                    \
        T br = B->realp[0], bi = B->imagp[0];                                                            \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n);                                                      \
            T r = ar * br - ai * bi + RE(C, IC, n), i = ar * bi + ai * br + IM(C, IC, n);                \
            RE(D, ID, n) = r;                                                                            \
            IM(D, ID, n) = i;                                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvzsml##suffix(const Z *A, vDSP_Stride IA, const Z *B, const Z *C, vDSP_Stride IC,         \
                             vDSP_Length N)                                                              \
    {                                                                                                    \
        T br = B->realp[0], bi = B->imagp[0];                                                            \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n);                                                      \
            RE(C, IC, n) = ar * br - ai * bi;                                                            \
            IM(C, IC, n) = ar * bi + ai * br;                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zvmmaa##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,         \
                             vDSP_Stride IC, const Z *D, vDSP_Stride ID, const Z *E, vDSP_Stride IE,     \
                             const Z *F, vDSP_Stride IF, vDSP_Length N)                                  \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);                \
            T cr = RE(C, IC, n), ci = IM(C, IC, n), dr = RE(D, ID, n), di = IM(D, ID, n);                \
            T r = ar * br - ai * bi + cr * dr - ci * di + RE(E, IE, n);                                  \
            T i = ar * bi + ai * br + cr * di + ci * dr + IM(E, IE, n);                                  \
            RE(F, IF, n) = r;                                                                            \
            IM(F, IF, n) = i;                                                                            \
        }                                                                                                \
    }
FOR_BOTH(DEFINE_ARITHMETIC)

/* Complex and real vectors: C = A op B with B real */
#define ZR(suffix, T, Z, name, re, im)                                                                   \
    void name##suffix(const Z *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const Z *C, vDSP_Stride IC, \
                      vDSP_Length N)                                                                     \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), b = AT(B, IB, n);                                    \
            RE(C, IC, n) = (re);                                                                         \
            IM(C, IC, n) = (im);                                                                         \
        }                                                                                                \
    }
#define DEFINE_REAL(suffix, T, Z, ZC, SQRT, ATAN2)                                                       \
    ZR(suffix, T, Z, vDSP_zrvadd, ar + b, ai)                                                            \
    ZR(suffix, T, Z, vDSP_zrvsub, ar - b, ai)                                                            \
    ZR(suffix, T, Z, vDSP_zrvmul, ar * b, ai * b)                                                        \
    ZR(suffix, T, Z, vDSP_zrvdiv, ar / b, ai / b)
FOR_BOTH(DEFINE_REAL)

/* Dot products */
#define DEFINE_DOT(suffix, T, Z, ZC, SQRT, ATAN2)                                                        \
    void vDSP_zdotpr##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,         \
                             vDSP_Length N)                                                              \
    {                                                                                                    \
        T r = 0, i = 0;                                                                                  \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);                \
            r += ar * br - ai * bi;                                                                      \
            i += ar * bi + ai * br;                                                                      \
        }                                                                                                \
        C->realp[0] = r;                                                                                 \
        C->imagp[0] = i;                                                                                 \
    }                                                                                                    \
    void vDSP_zidotpr##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,        \
                              vDSP_Length N)                                                             \
    {                                                                                                    \
        T r = 0, i = 0;                                                                                  \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = RE(A, IA, n), ai = -IM(A, IA, n), br = RE(B, IB, n), bi = IM(B, IB, n);               \
            r += ar * br - ai * bi;                                                                      \
            i += ar * bi + ai * br;                                                                      \
        }                                                                                                \
        C->realp[0] = r;                                                                                 \
        C->imagp[0] = i;                                                                                 \
    }                                                                                                    \
    void vDSP_zrdotpr##suffix(const Z *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, const Z *C,        \
                              vDSP_Length N)                                                             \
    {                                                                                                    \
        T r = 0, i = 0;                                                                                  \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T b = AT(B, IB, n);                                                                          \
            r += RE(A, IA, n) * b;                                                                       \
            i += IM(A, IA, n) * b;                                                                       \
        }                                                                                                \
        C->realp[0] = r;                                                                                 \
        C->imagp[0] = i;                                                                                 \
    }
FOR_BOTH(DEFINE_DOT)

/* Spectra (no strides) */
#define DEFINE_SPECTRA(suffix, T, Z, ZC, SQRT, ATAN2)                                                    \
    void vDSP_zaspec##suffix(const Z *A, T *C, vDSP_Length N)                                            \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            C[n] += A->realp[n] * A->realp[n] + A->imagp[n] * A->imagp[n];                               \
    }                                                                                                    \
    void vDSP_zcspec##suffix(const Z *A, const Z *B, const Z *C, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T ar = A->realp[n], ai = -A->imagp[n], br = B->realp[n], bi = B->imagp[n];                   \
            C->realp[n] += ar * br - ai * bi;                                                            \
            C->imagp[n] += ar * bi + ai * br;                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zcoher##suffix(const T *A, const T *B, const Z *C, T *D, vDSP_Length N)                    \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = C->realp[n], i = C->imagp[n];                                                          \
            D[n] = (r * r + i * i) / (A[n] * B[n]);                                                      \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_ztrans##suffix(const T *A, const Z *B, const Z *C, vDSP_Length N)                          \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            C->realp[n] = B->realp[n] / A[n];                                                            \
            C->imagp[n] = B->imagp[n] / A[n];                                                            \
        }                                                                                                \
    }
FOR_BOTH(DEFINE_SPECTRA)

/* Correlation and decimation */
#define DEFINE_FILTERS(suffix, T, Z, ZC, SQRT, ATAN2)                                                    \
    void vDSP_zconv##suffix(const Z *A, vDSP_Stride IA, const Z *F, vDSP_Stride IF, const Z *C,          \
                            vDSP_Stride IC, vDSP_Length N, vDSP_Length P)                                \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = 0, i = 0;                                                                              \
            for (vDSP_Length p = 0; p < P; ++p) {                                                        \
                T ar = RE(A, IA, n + p), ai = IM(A, IA, n + p), fr = RE(F, IF, p), fi = IM(F, IF, p);    \
                r += ar * fr - ai * fi;                                                                  \
                i += ar * fi + ai * fr;                                                                  \
            }                                                                                            \
            RE(C, IC, n) = r;                                                                            \
            IM(C, IC, n) = i;                                                                            \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_zrdesamp##suffix(const Z *A, vDSP_Stride DF, const T *F, const Z *C, vDSP_Length N,        \
                               vDSP_Length P)                                                            \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            T r = 0, i = 0;                                                                              \
            for (vDSP_Length p = 0; p < P; ++p) {                                                        \
                ptrdiff_t k = (ptrdiff_t)n * DF + (ptrdiff_t)p;                                          \
                r += A->realp[k] * F[p];                                                                 \
                i += A->imagp[k] * F[p];                                                                 \
            }                                                                                            \
            C->realp[n] = r;                                                                             \
            C->imagp[n] = i;                                                                             \
        }                                                                                                \
    }
FOR_BOTH(DEFINE_FILTERS)

/* Matrix products: A [M][P], B [P][N], C and D [M][N] */
#define MAT(z, s, row, col, cols) ((ptrdiff_t)((row) * (cols) + (col)) * (s))
#define DEFINE_MATRIX(suffix, T, Z, ZC, SQRT, ATAN2)                                                     \
    static void zmatrix##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,      \
                                vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length M, vDSP_Length N, \
                                vDSP_Length P, T productSign, T addSign)                                 \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m)                                                              \
            for (vDSP_Length n = 0; n < N; ++n) {                                                        \
                T r = 0, i = 0;                                                                          \
                for (vDSP_Length p = 0; p < P; ++p) {                                                    \
                    ptrdiff_t a = MAT(A, IA, m, p, P), b = MAT(B, IB, p, n, N);                          \
                    T ar = A->realp[a], ai = A->imagp[a], br = B->realp[b], bi = B->imagp[b];            \
                    r += ar * br - ai * bi;                                                              \
                    i += ar * bi + ai * br;                                                              \
                }                                                                                        \
                r *= productSign;                                                                        \
                i *= productSign;                                                                        \
                if (C) {                                                                                 \
                    ptrdiff_t c = MAT(C, IC, m, n, N);                                                   \
                    r += addSign * C->realp[c];                                                          \
                    i += addSign * C->imagp[c];                                                          \
                }                                                                                        \
                ptrdiff_t d = MAT(D, ID, m, n, N);                                                       \
                D->realp[d] = r;                                                                         \
                D->imagp[d] = i;                                                                         \
            }                                                                                            \
    }                                                                                                    \
    void vDSP_zmma##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,           \
                           vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length M, vDSP_Length N,     \
                           vDSP_Length P)                                                                \
    {                                                                                                    \
        zmatrix##suffix(A, IA, B, IB, C, IC, D, ID, M, N, P, 1, 1);                                      \
    }                                                                                                    \
    void vDSP_zmms##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,           \
                           vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length M, vDSP_Length N,     \
                           vDSP_Length P)                                                                \
    {                                                                                                    \
        zmatrix##suffix(A, IA, B, IB, C, IC, D, ID, M, N, P, 1, -1);                                     \
    }                                                                                                    \
    void vDSP_zmsm##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,           \
                           vDSP_Stride IC, const Z *D, vDSP_Stride ID, vDSP_Length M, vDSP_Length N,     \
                           vDSP_Length P)                                                                \
    {                                                                                                    \
        zmatrix##suffix(A, IA, B, IB, C, IC, D, ID, M, N, P, -1, 1);                                     \
    }                                                                                                    \
    void vDSP_zmmul##suffix(const Z *A, vDSP_Stride IA, const Z *B, vDSP_Stride IB, const Z *C,          \
                            vDSP_Stride IC, vDSP_Length M, vDSP_Length N, vDSP_Length P)                 \
    {                                                                                                    \
        zmatrix##suffix(A, IA, B, IB, NULL, 0, C, IC, M, N, P, 1, 0);                                    \
    }
FOR_BOTH(DEFINE_MATRIX)

/* Interleaved and split complex: the interleaved stride counts scalars, so 2 is
   contiguous, as vDSP's has it. */
#define DEFINE_INTERLEAVE(suffix, T, Z, ZC, SQRT, ATAN2)                                                 \
    void vDSP_ctoz##suffix(const ZC *C, vDSP_Stride IC, const Z *Z_, vDSP_Stride IZ, vDSP_Length N)      \
    {                                                                                                    \
        const T *c = (const T *)C;                                                                       \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            RE(Z_, IZ, n) = c[(ptrdiff_t)n * IC];                                                        \
            IM(Z_, IZ, n) = c[(ptrdiff_t)n * IC + 1];                                                    \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_ztoc##suffix(const Z *Z_, vDSP_Stride IZ, ZC *C, vDSP_Stride IC, vDSP_Length N)            \
    {                                                                                                    \
        T *c = (T *)C;                                                                                   \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            c[(ptrdiff_t)n * IC] = RE(Z_, IZ, n);                                                        \
            c[(ptrdiff_t)n * IC + 1] = IM(Z_, IZ, n);                                                    \
        }                                                                                                \
    }
FOR_BOTH(DEFINE_INTERLEAVE)

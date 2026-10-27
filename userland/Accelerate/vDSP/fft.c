/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP's Fourier transforms: the FFT setups and the complex, real, multiple and
 * two-dimensional FFTs (in place, out of place, with or without a temporary buffer),
 * the radix-3 and radix-5 FFTs, the DFT and DCT setups and execution routines
 * (planar, strided and interleaved), and the fixed 16- and 32-point FFTs.
 *
 * Conventions, as Apple's routines behave: forward transforms use e**(-2*pi*i*j*k/N);
 * complex transforms are unscaled in both directions; real-to-complex transforms
 * take N real values as N/2 complex ones (even elements in the real parts), return
 * twice the DFT with the DC and Nyquist terms packed into element 0, and their
 * complex-to-real inverses are unscaled. A DFT setup accepts only the lengths
 * Apple's does. Arithmetic is done in double precision for both precisions.
 */
#include <Accelerate/Accelerate.h>
#include <complex.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef double complex cplx;

#define AT(p, s, i) ((p)[(ptrdiff_t)(s) * (ptrdiff_t)(i)])

/* MARK: - The transform */

static int is_pow2(size_t n) { return n && !(n & (n - 1)); }

/* In-place radix-2 transform of a power-of-two length; sign is -1 forward, +1 inverse. */
static void fft_pow2(cplx *x, size_t n, int sign)
{
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j) {
            cplx t = x[i];
            x[i] = x[j];
            x[j] = t;
        }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        double angle = sign * 2.0 * M_PI / (double)len;
        for (size_t base = 0; base < n; base += len)
            for (size_t k = 0; k < len / 2; ++k) {
                cplx w = cexp(I * angle * (double)k);
                cplx even = x[base + k], odd = w * x[base + k + len / 2];
                x[base + k] = even + odd;
                x[base + k + len / 2] = even - odd;
            }
    }
}

/* Any length: f interleaved power-of-two transforms combined by an f-point DFT when
   n = f * 2**m, or a direct DFT otherwise. */
static void transform(cplx *x, size_t n, int sign)
{
    if (n < 2)
        return;
    if (is_pow2(n)) {
        fft_pow2(x, n, sign);
        return;
    }
    size_t f = n, m = 1;
    while (!(f & 1)) {
        f >>= 1;
        m <<= 1;
    }
    cplx *out = malloc(n * sizeof(cplx));
    if (!out)
        return;
    if (m == 1) {
        for (size_t k = 0; k < n; ++k) {
            cplx sum = 0;
            for (size_t j = 0; j < n; ++j)
                sum += x[j] * cexp(I * sign * 2.0 * M_PI * (double)((j * k) % n) / (double)n);
            out[k] = sum;
        }
    } else {
        cplx *sub = malloc(n * sizeof(cplx));
        if (!sub) {
            free(out);
            return;
        }
        /* sub[r*m + q] = transform of x[r], x[r+f], ... (length m) */
        for (size_t r = 0; r < f; ++r) {
            for (size_t q = 0; q < m; ++q)
                sub[r * m + q] = x[r + q * f];
            fft_pow2(sub + r * m, m, sign);
        }
        for (size_t k = 0; k < n; ++k) {
            cplx sum = 0;
            for (size_t r = 0; r < f; ++r)
                sum += sub[r * m + (k % m)] * cexp(I * sign * 2.0 * M_PI * (double)((r * k) % n) / (double)n);
            out[k] = sum;
        }
        free(sub);
    }
    memcpy(x, out, n * sizeof(cplx));
    free(out);
}

/* Real-to-complex: N real values packed as N/2 complex (re, im) pairs; returns twice
   the DFT packed with DC and Nyquist in element 0. */
static void real_forward(const double *re, const double *im, double *outRe, double *outIm, size_t n)
{
    size_t half = n / 2;
    cplx *h = malloc(n * sizeof(cplx));
    if (!h)
        return;
    for (size_t j = 0; j < half; ++j) {
        h[2 * j] = re[j];
        h[2 * j + 1] = im[j];
    }
    transform(h, n, -1);
    outRe[0] = 2 * creal(h[0]);
    outIm[0] = 2 * creal(h[half]);
    for (size_t k = 1; k < half; ++k) {
        outRe[k] = 2 * creal(h[k]);
        outIm[k] = 2 * cimag(h[k]);
    }
    free(h);
}

/* Complex-to-real: the packed form back to N real values (unscaled). */
static void real_inverse(const double *re, const double *im, double *outRe, double *outIm, size_t n)
{
    size_t half = n / 2;
    cplx *h = malloc(n * sizeof(cplx));
    if (!h)
        return;
    h[0] = re[0];
    if (half)
        h[half] = im[0];
    for (size_t j = 1; j < half; ++j) {
        h[j] = re[j] + I * im[j];
        h[n - j] = conj(h[j]);
    }
    transform(h, n, +1);
    for (size_t k = 0; k < half; ++k) {
        outRe[k] = creal(h[2 * k]);
        outIm[k] = creal(h[2 * k + 1]);
    }
    free(h);
}

/* MARK: - FFT setups */

typedef struct {
    unsigned magic;
    vDSP_Length log2n;
    FFTRadix radix;
} FinchFFTSetup;

#define FFT_MAGIC 0x46465431u

static void *make_fft_setup(vDSP_Length log2n, FFTRadix radix)
{
    if (log2n > 24 || (radix != kFFTRadix2 && radix != kFFTRadix3 && radix != kFFTRadix5))
        return NULL;
    FinchFFTSetup *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->magic = FFT_MAGIC;
    s->log2n = log2n;
    s->radix = radix;
    return s;
}

FFTSetup vDSP_create_fftsetup(vDSP_Length log2n, FFTRadix radix) { return (FFTSetup)make_fft_setup(log2n, radix); }
FFTSetupD vDSP_create_fftsetupD(vDSP_Length log2n, FFTRadix radix) { return (FFTSetupD)make_fft_setup(log2n, radix); }
void vDSP_destroy_fftsetup(FFTSetup setup) { free(setup); }
void vDSP_destroy_fftsetupD(FFTSetupD setup) { free(setup); }

/* MARK: - Split-complex FFTs, in both precisions */

#define DEFINE_FFTS(suffix, T, Z, SETUP)                                                                 \
    static void complex_##suffix(const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC, size_t n,       \
                                 FFTDirection dir)                                                       \
    {                                                                                                    \
        cplx *x = malloc((n ? n : 1) * sizeof(cplx));                                                    \
        if (!x)                                                                                          \
            return;                                                                                      \
        for (size_t j = 0; j < n; ++j)                                                                   \
            x[j] = AT(A->realp, IA, j) + I * AT(A->imagp, IA, j);                                        \
        transform(x, n, dir == FFT_FORWARD ? -1 : 1);                                                    \
        for (size_t k = 0; k < n; ++k) {                                                                 \
            AT(C->realp, IC, k) = (T)creal(x[k]);                                                        \
            AT(C->imagp, IC, k) = (T)cimag(x[k]);                                                        \
        }                                                                                                \
        free(x);                                                                                         \
    }                                                                                                    \
    static void real_##suffix(const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC, size_t n,          \
                              FFTDirection dir)                                                          \
    {                                                                                                    \
        size_t half = n / 2 ? n / 2 : 1;                                                                 \
        double *in = malloc(4 * half * sizeof(double));                                                  \
        if (!in)                                                                                         \
            return;                                                                                      \
        double *im = in + half, *outRe = im + half, *outIm = outRe + half;                               \
        for (size_t j = 0; j < half; ++j) {                                                              \
            in[j] = AT(A->realp, IA, j);                                                                 \
            im[j] = AT(A->imagp, IA, j);                                                                 \
        }                                                                                                \
        if (n < 2) {                                                                                     \
            outRe[0] = dir == FFT_FORWARD ? 2 * in[0] : in[0];                                           \
            outIm[0] = 0;                                                                                \
        } else if (dir == FFT_FORWARD)                                                                   \
            real_forward(in, im, outRe, outIm, n);                                                       \
        else                                                                                             \
            real_inverse(in, im, outRe, outIm, n);                                                       \
        for (size_t k = 0; k < half; ++k) {                                                              \
            AT(C->realp, IC, k) = (T)outRe[k];                                                           \
            AT(C->imagp, IC, k) = (T)outIm[k];                                                           \
        }                                                                                                \
        free(in);                                                                                        \
    }                                                                                                    \
                                                                                                         \
    void vDSP_fft_zip##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Length log2n, FFTDirection dir) \
    {                                                                                                    \
        complex_##suffix(C, IC, C, IC, (size_t)1 << log2n, dir);                                         \
    }                                                                                                    \
    void vDSP_fft_zipt##suffix(SETUP setup, const Z *C, vDSP_Stride IC, const Z *buffer, vDSP_Length log2n, \
                               FFTDirection dir)                                                         \
    {                                                                                                    \
        complex_##suffix(C, IC, C, IC, (size_t)1 << log2n, dir);                                         \
    }                                                                                                    \
    void vDSP_fft_zop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,       \
                              vDSP_Length log2n, FFTDirection dir)                                       \
    {                                                                                                    \
        complex_##suffix(A, IA, C, IC, (size_t)1 << log2n, dir);                                         \
    }                                                                                                    \
    void vDSP_fft_zopt##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,      \
                               const Z *buffer, vDSP_Length log2n, FFTDirection dir)                     \
    {                                                                                                    \
        complex_##suffix(A, IA, C, IC, (size_t)1 << log2n, dir);                                         \
    }                                                                                                    \
    void vDSP_fft_zrip##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Length log2n, FFTDirection dir) \
    {                                                                                                    \
        real_##suffix(C, IC, C, IC, (size_t)1 << log2n, dir);                                            \
    }                                                                                                    \
    void vDSP_fft_zript##suffix(SETUP setup, const Z *C, vDSP_Stride IC, const Z *buffer,                \
                                vDSP_Length log2n, FFTDirection dir)                                     \
    {                                                                                                    \
        real_##suffix(C, IC, C, IC, (size_t)1 << log2n, dir);                                            \
    }                                                                                                    \
    void vDSP_fft_zrop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,      \
                               vDSP_Length log2n, FFTDirection dir)                                      \
    {                                                                                                    \
        real_##suffix(A, IA, C, IC, (size_t)1 << log2n, dir);                                            \
    }                                                                                                    \
    void vDSP_fft_zropt##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,     \
                                const Z *buffer, vDSP_Length log2n, FFTDirection dir)                    \
    {                                                                                                    \
        real_##suffix(A, IA, C, IC, (size_t)1 << log2n, dir);                                            \
    }                                                                                                    \
                                                                                                         \
    /* M transforms, IM (or IMA, IMC) apart */                                                           \
    static Z offset_##suffix(const Z *z, ptrdiff_t by)                                                   \
    {                                                                                                    \
        Z moved = {z->realp + by, z->imagp + by};                                                        \
        return moved;                                                                                    \
    }                                                                                                    \
    void vDSP_fftm_zip##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Stride IM, vDSP_Length log2n, \
                               vDSP_Length M, FFTDirection dir)                                          \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m) {                                                            \
            Z c = offset_##suffix(C, (ptrdiff_t)m * IM);                                                 \
            complex_##suffix(&c, IC, &c, IC, (size_t)1 << log2n, dir);                                   \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_fftm_zipt##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Stride IM, const Z *buffer, \
                                vDSP_Length log2n, vDSP_Length M, FFTDirection dir)                      \
    {                                                                                                    \
        vDSP_fftm_zip##suffix(setup, C, IC, IM, log2n, M, dir);                                          \
    }                                                                                                    \
    void vDSP_fftm_zop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, vDSP_Stride IMA, const Z *C,     \
                               vDSP_Stride IC, vDSP_Stride IMC, vDSP_Length log2n, vDSP_Length M,        \
                               FFTDirection dir)                                                         \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m) {                                                            \
            Z a = offset_##suffix(A, (ptrdiff_t)m * IMA), c = offset_##suffix(C, (ptrdiff_t)m * IMC);   \
            complex_##suffix(&a, IA, &c, IC, (size_t)1 << log2n, dir);                                   \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_fftm_zopt##suffix(SETUP setup, const Z *A, vDSP_Stride IA, vDSP_Stride IMA, const Z *C,    \
                                vDSP_Stride IC, vDSP_Stride IMC, const Z *buffer, vDSP_Length log2n,     \
                                vDSP_Length M, FFTDirection dir)                                         \
    {                                                                                                    \
        vDSP_fftm_zop##suffix(setup, A, IA, IMA, C, IC, IMC, log2n, M, dir);                             \
    }                                                                                                    \
    void vDSP_fftm_zrip##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Stride IM,                 \
                                vDSP_Length log2n, vDSP_Length M, FFTDirection dir)                      \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m) {                                                            \
            Z c = offset_##suffix(C, (ptrdiff_t)m * IM);                                                 \
            real_##suffix(&c, IC, &c, IC, (size_t)1 << log2n, dir);                                      \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_fftm_zript##suffix(SETUP setup, const Z *C, vDSP_Stride IC, vDSP_Stride IM, const Z *buffer, \
                                 vDSP_Length log2n, vDSP_Length M, FFTDirection dir)                     \
    {                                                                                                    \
        vDSP_fftm_zrip##suffix(setup, C, IC, IM, log2n, M, dir);                                         \
    }                                                                                                    \
    void vDSP_fftm_zrop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, vDSP_Stride IMA, const Z *C,    \
                                vDSP_Stride IC, vDSP_Stride IMC, vDSP_Length log2n, vDSP_Length M,       \
                                FFTDirection dir)                                                        \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m) {                                                            \
            Z a = offset_##suffix(A, (ptrdiff_t)m * IMA), c = offset_##suffix(C, (ptrdiff_t)m * IMC);   \
            real_##suffix(&a, IA, &c, IC, (size_t)1 << log2n, dir);                                      \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_fftm_zropt##suffix(SETUP setup, const Z *A, vDSP_Stride IA, vDSP_Stride IMA, const Z *C,   \
                                 vDSP_Stride IC, vDSP_Stride IMC, const Z *buffer, vDSP_Length log2n,    \
                                 vDSP_Length M, FFTDirection dir)                                        \
    {                                                                                                    \
        vDSP_fftm_zrop##suffix(setup, A, IA, IMA, C, IC, IMC, log2n, M, dir);                            \
    }                                                                                                    \
                                                                                                         \
    /* Radix-3 and radix-5 lengths: 3 * 2**log2n and 5 * 2**log2n */                                    \
    void vDSP_fft3_zop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,      \
                               vDSP_Length log2n, FFTDirection dir)                                      \
    {                                                                                                    \
        complex_##suffix(A, IA, C, IC, (size_t)3 << log2n, dir);                                         \
    }                                                                                                    \
    void vDSP_fft5_zop##suffix(SETUP setup, const Z *A, vDSP_Stride IA, const Z *C, vDSP_Stride IC,      \
                               vDSP_Length log2n, FFTDirection dir)                                      \
    {                                                                                                    \
        complex_##suffix(A, IA, C, IC, (size_t)5 << log2n, dir);                                         \
    }                                                                                                    \
                                                                                                         \
    /* Two-dimensional transforms: N0 elements IC0 apart along a row, N1 rows IC1 apart */               \
    static void complex2d_##suffix(const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C,             \
                                   vDSP_Stride IC0, vDSP_Stride IC1, vDSP_Length log2n0,                 \
                                   vDSP_Length log2n1, FFTDirection dir)                                 \
    {                                                                                                    \
        size_t n0 = (size_t)1 << log2n0, n1 = (size_t)1 << log2n1;                                      \
        if (IA1 == 0)                                                                                    \
            IA1 = IA0 * (vDSP_Stride)n0;                                                                 \
        if (IC1 == 0)                                                                                    \
            IC1 = IC0 * (vDSP_Stride)n0;                                                                 \
        int sign = dir == FFT_FORWARD ? -1 : 1;                                                          \
        cplx *x = malloc(n0 * n1 * sizeof(cplx)), *col = malloc(n1 * sizeof(cplx));                      \
        if (!x || !col) {                                                                                \
            free(x);                                                                                     \
            free(col);                                                                                   \
            return;                                                                                      \
        }                                                                                                \
        for (size_t j1 = 0; j1 < n1; ++j1)                                                               \
            for (size_t j0 = 0; j0 < n0; ++j0) {                                                         \
                ptrdiff_t at = (ptrdiff_t)j1 * IA1 + (ptrdiff_t)j0 * IA0;                                \
                x[j1 * n0 + j0] = A->realp[at] + I * A->imagp[at];                                       \
            }                                                                                            \
        for (size_t j1 = 0; j1 < n1; ++j1)                                                               \
            transform(x + j1 * n0, n0, sign);                                                            \
        for (size_t k0 = 0; k0 < n0; ++k0) {                                                             \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                col[j1] = x[j1 * n0 + k0];                                                               \
            transform(col, n1, sign);                                                                    \
            for (size_t k1 = 0; k1 < n1; ++k1)                                                           \
                x[k1 * n0 + k0] = col[k1];                                                               \
        }                                                                                                \
        for (size_t k1 = 0; k1 < n1; ++k1)                                                               \
            for (size_t k0 = 0; k0 < n0; ++k0) {                                                         \
                ptrdiff_t at = (ptrdiff_t)k1 * IC1 + (ptrdiff_t)k0 * IC0;                                \
                C->realp[at] = (T)creal(x[k1 * n0 + k0]);                                                \
                C->imagp[at] = (T)cimag(x[k1 * n0 + k0]);                                                \
            }                                                                                            \
        free(x);                                                                                         \
        free(col);                                                                                       \
    }                                                                                                    \
    void vDSP_fft2d_zip##suffix(SETUP setup, const Z *C, vDSP_Stride IC0, vDSP_Stride IC1,               \
                                vDSP_Length log2n0, vDSP_Length log2n1, FFTDirection dir)                \
    {                                                                                                    \
        complex2d_##suffix(C, IC0, IC1, C, IC0, IC1, log2n0, log2n1, dir);                               \
    }                                                                                                    \
    void vDSP_fft2d_zipt##suffix(SETUP setup, const Z *C, vDSP_Stride IC0, vDSP_Stride IC1,              \
                                 const Z *buffer, vDSP_Length log2n0, vDSP_Length log2n1, FFTDirection dir) \
    {                                                                                                    \
        complex2d_##suffix(C, IC0, IC1, C, IC0, IC1, log2n0, log2n1, dir);                               \
    }                                                                                                    \
    void vDSP_fft2d_zop##suffix(SETUP setup, const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C,   \
                                vDSP_Stride IC0, vDSP_Stride IC1, vDSP_Length log2n0, vDSP_Length log2n1, \
                                FFTDirection dir)                                                        \
    {                                                                                                    \
        complex2d_##suffix(A, IA0, IA1, C, IC0, IC1, log2n0, log2n1, dir);                               \
    }                                                                                                    \
    void vDSP_fft2d_zopt##suffix(SETUP setup, const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C,  \
                                 vDSP_Stride IC0, vDSP_Stride IC1, const Z *buffer, vDSP_Length log2n0,  \
                                 vDSP_Length log2n1, FFTDirection dir)                                   \
    {                                                                                                    \
        complex2d_##suffix(A, IA0, IA1, C, IC0, IC1, log2n0, log2n1, dir);                               \
    }                                                                                                    \
                                                                                                         \
    /* Real two-dimensional transforms, packed as vDSP.h describes (row 1's column 0 holds the          \
       Nyquist row's DC and Nyquist terms; rows 2k and 2k+1 of column 0 hold row k's) */                \
    static void real2d_##suffix(const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C,                \
                                vDSP_Stride IC0, vDSP_Stride IC1, vDSP_Length log2n0, vDSP_Length log2n1, \
                                FFTDirection dir)                                                        \
    {                                                                                                    \
        size_t n0 = (size_t)1 << log2n0, n1 = (size_t)1 << log2n1, h0 = n0 / 2;                         \
        if (IA1 == 0)                                                                                    \
            IA1 = IA0 * (vDSP_Stride)h0;                                                                 \
        if (IC1 == 0)                                                                                    \
            IC1 = IC0 * (vDSP_Stride)h0;                                                                 \
        cplx *x = malloc(n0 * n1 * sizeof(cplx)), *col = malloc(n1 * sizeof(cplx));                      \
        if (!x || !col || n0 < 2 || n1 < 2) {                                                            \
            free(x);                                                                                     \
            free(col);                                                                                   \
            return;                                                                                      \
        }                                                                                                \
        _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wshadow\"")                \
        if (dir == FFT_FORWARD) {                                                                        \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                for (size_t j0 = 0; j0 < h0; ++j0) {                                                     \
                    ptrdiff_t at = (ptrdiff_t)j1 * IA1 + (ptrdiff_t)j0 * IA0;                            \
                    x[j1 * n0 + 2 * j0] = A->realp[at];                                                  \
                    x[j1 * n0 + 2 * j0 + 1] = A->imagp[at];                                              \
                }                                                                                        \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                transform(x + j1 * n0, n0, -1);                                                          \
            for (size_t k0 = 0; k0 < n0; ++k0) {                                                         \
                for (size_t j1 = 0; j1 < n1; ++j1)                                                       \
                    col[j1] = x[j1 * n0 + k0];                                                           \
                transform(col, n1, -1);                                                                  \
                for (size_t k1 = 0; k1 < n1; ++k1)                                                       \
                    x[k1 * n0 + k0] = 2 * col[k1];                                                       \
            }                                                                                            \
            for (size_t k1 = 0; k1 < n1; ++k1)                                                           \
                for (size_t k0 = 1; k0 < h0; ++k0) {                                                     \
                    ptrdiff_t at = (ptrdiff_t)k1 * IC1 + (ptrdiff_t)k0 * IC0;                            \
                    C->realp[at] = (T)creal(x[k1 * n0 + k0]);                                            \
                    C->imagp[at] = (T)cimag(x[k1 * n0 + k0]);                                            \
                }                                                                                        \
            C->realp[0] = (T)creal(x[0]);                                                                \
            C->imagp[0] = (T)creal(x[h0]);                                                               \
            C->realp[IC1] = (T)creal(x[(n1 / 2) * n0]);                                                  \
            C->imagp[IC1] = (T)creal(x[(n1 / 2) * n0 + h0]);                                             \
            for (size_t k1 = 1; k1 < n1 / 2; ++k1) {                                                     \
                C->realp[(ptrdiff_t)(2 * k1) * IC1] = (T)creal(x[k1 * n0]);                              \
                C->realp[(ptrdiff_t)(2 * k1 + 1) * IC1] = (T)cimag(x[k1 * n0]);                          \
                C->imagp[(ptrdiff_t)(2 * k1) * IC1] = (T)creal(x[k1 * n0 + h0]);                         \
                C->imagp[(ptrdiff_t)(2 * k1 + 1) * IC1] = (T)cimag(x[k1 * n0 + h0]);                     \
            }                                                                                            \
        } else {                                                                                         \
            memset(x, 0, n0 * n1 * sizeof(cplx));                                                        \
            x[0] = A->realp[0];                                                                          \
            x[h0] = A->imagp[0];                                                                         \
            x[(n1 / 2) * n0] = A->realp[IA1];                                                            \
            x[(n1 / 2) * n0 + h0] = A->imagp[IA1];                                                       \
            for (size_t j1 = 1; j1 < n1 / 2; ++j1) {                                                     \
                x[j1 * n0] = A->realp[(ptrdiff_t)(2 * j1) * IA1] + I * A->realp[(ptrdiff_t)(2 * j1 + 1) * IA1]; \
                x[j1 * n0 + h0] = A->imagp[(ptrdiff_t)(2 * j1) * IA1] + I * A->imagp[(ptrdiff_t)(2 * j1 + 1) * IA1]; \
                x[(n1 - j1) * n0] = conj(x[j1 * n0]);                                                    \
                x[(n1 - j1) * n0 + h0] = conj(x[j1 * n0 + h0]);                                          \
            }                                                                                            \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                for (size_t j0 = 1; j0 < h0; ++j0) {                                                     \
                    ptrdiff_t at = (ptrdiff_t)j1 * IA1 + (ptrdiff_t)j0 * IA0;                            \
                    x[j1 * n0 + j0] = A->realp[at] + I * A->imagp[at];                                   \
                }                                                                                        \
            /* the remaining half from the conjugate symmetry of a real matrix's transform */           \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                for (size_t j0 = 1; j0 < h0; ++j0)                                                       \
                    x[((n1 - j1) % n1) * n0 + (n0 - j0)] = conj(x[j1 * n0 + j0]);                        \
            for (size_t k0 = 0; k0 < n0; ++k0) {                                                         \
                for (size_t j1 = 0; j1 < n1; ++j1)                                                       \
                    col[j1] = x[j1 * n0 + k0];                                                           \
                transform(col, n1, +1);                                                                  \
                for (size_t k1 = 0; k1 < n1; ++k1)                                                       \
                    x[k1 * n0 + k0] = col[k1];                                                           \
            }                                                                                            \
            for (size_t j1 = 0; j1 < n1; ++j1)                                                           \
                transform(x + j1 * n0, n0, +1);                                                          \
            for (size_t k1 = 0; k1 < n1; ++k1)                                                           \
                for (size_t k0 = 0; k0 < h0; ++k0) {                                                     \
                    ptrdiff_t at = (ptrdiff_t)k1 * IC1 + (ptrdiff_t)k0 * IC0;                            \
                    C->realp[at] = (T)creal(x[k1 * n0 + 2 * k0]);                                        \
                    C->imagp[at] = (T)creal(x[k1 * n0 + 2 * k0 + 1]);                                    \
                }                                                                                        \
        }                                                                                                \
        _Pragma("clang diagnostic pop")                                                                  \
        free(x);                                                                                         \
        free(col);                                                                                       \
    }                                                                                                    \
    void vDSP_fft2d_zrip##suffix(SETUP setup, const Z *C, vDSP_Stride IC0, vDSP_Stride IC1,              \
                                 vDSP_Length log2n0, vDSP_Length log2n1, FFTDirection dir)               \
    {                                                                                                    \
        real2d_##suffix(C, IC0, IC1, C, IC0, IC1, log2n0, log2n1, dir);                                  \
    }                                                                                                    \
    void vDSP_fft2d_zript##suffix(SETUP setup, const Z *C, vDSP_Stride IC0, vDSP_Stride IC1,             \
                                  const Z *buffer, vDSP_Length log2n0, vDSP_Length log2n1,               \
                                  FFTDirection dir)                                                      \
    {                                                                                                    \
        real2d_##suffix(C, IC0, IC1, C, IC0, IC1, log2n0, log2n1, dir);                                  \
    }                                                                                                    \
    void vDSP_fft2d_zrop##suffix(SETUP setup, const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C,  \
                                 vDSP_Stride IC0, vDSP_Stride IC1, vDSP_Length log2n0, vDSP_Length log2n1, \
                                 FFTDirection dir)                                                       \
    {                                                                                                    \
        real2d_##suffix(A, IA0, IA1, C, IC0, IC1, log2n0, log2n1, dir);                                  \
    }                                                                                                    \
    void vDSP_fft2d_zropt##suffix(SETUP setup, const Z *A, vDSP_Stride IA0, vDSP_Stride IA1, const Z *C, \
                                  vDSP_Stride IC0, vDSP_Stride IC1, const Z *buffer, vDSP_Length log2n0, \
                                  vDSP_Length log2n1, FFTDirection dir)                                  \
    {                                                                                                    \
        real2d_##suffix(A, IA0, IA1, C, IC0, IC1, log2n0, log2n1, dir);                                  \
    }

DEFINE_FFTS(, float, DSPSplitComplex, FFTSetup)
DEFINE_FFTS(D, double, DSPDoubleSplitComplex, FFTSetupD)

/* MARK: - DFT and DCT setups */

enum { DFT_ZOP = 1, DFT_ZROP, DFT_LEGACY, DFT_DCT, DFT_INTERLEAVED, DFT_INTERLEAVED_REAL };

typedef struct {
    unsigned magic;
    int kind;
    size_t length;
    int sign;
    int dctType;
} FinchDFTSetup;

#define DFT_MAGIC 0x44465431u

/* f * 2**n: the odd factor f and n */
static void factor(size_t length, size_t *f, unsigned *n)
{
    *f = length;
    *n = 0;
    while (*f && !(*f & 1)) {
        *f >>= 1;
        ++*n;
    }
}

/* The lengths Apple's setups accept (checked against its routines). */
static int accepted(int kind, size_t length)
{
    size_t f;
    unsigned n;
    factor(length, &f, &n);
    switch (kind) {
    case DFT_ZOP:
        return f == 1 || ((f == 3 || f == 5) && n >= 3) || (f == 15 && n >= 2) || (f == 45 && (n == 1 || n == 2));
    case DFT_ZROP:
        return (f == 1 && n >= 1) || ((f == 3 || f == 5) && n >= 4) || (f == 15 && n >= 3) ||
               (f == 45 && (n == 2 || n == 3));
    case DFT_DCT:
        return ((f == 1 || f == 3 || f == 5) && n >= 4) || (f == 15 && n >= 3);
    case DFT_INTERLEAVED:
    case DFT_INTERLEAVED_REAL:
        return (f == 1 && n >= 3) || ((f == 3 || f == 5 || f == 9 || f == 15) && n >= 2);
    default:
        return length > 0;
    }
}

static void *make_dft(int kind, size_t length, int sign, int dctType)
{
    if (!accepted(kind, length))
        return NULL;
    FinchDFTSetup *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->magic = DFT_MAGIC;
    s->kind = kind;
    s->length = length;
    s->sign = sign;
    s->dctType = dctType;
    return s;
}

static int sign_of(vDSP_DFT_Direction direction) { return direction == vDSP_DFT_INVERSE ? +1 : -1; }

vDSP_DFT_Setup vDSP_DFT_zop_CreateSetup(vDSP_DFT_Setup previous, vDSP_Length length, vDSP_DFT_Direction direction)
{
    return make_dft(DFT_ZOP, length, sign_of(direction), 0);
}
vDSP_DFT_SetupD vDSP_DFT_zop_CreateSetupD(vDSP_DFT_SetupD previous, vDSP_Length length, vDSP_DFT_Direction direction)
{
    return make_dft(DFT_ZOP, length, sign_of(direction), 0);
}
vDSP_DFT_Setup vDSP_DFT_zrop_CreateSetup(vDSP_DFT_Setup previous, vDSP_Length length, vDSP_DFT_Direction direction)
{
    return make_dft(DFT_ZROP, length, sign_of(direction), 0);
}
vDSP_DFT_SetupD vDSP_DFT_zrop_CreateSetupD(vDSP_DFT_SetupD previous, vDSP_Length length, vDSP_DFT_Direction direction)
{
    return make_dft(DFT_ZROP, length, sign_of(direction), 0);
}
vDSP_DFT_Setup vDSP_DFT_CreateSetup(vDSP_DFT_Setup previous, vDSP_Length length)
{
    return make_dft(DFT_LEGACY, length, -1, 0);
}
vDSP_DFT_Setup vDSP_DCT_CreateSetup(vDSP_DFT_Setup previous, vDSP_Length length, vDSP_DCT_Type type)
{
    if (type != vDSP_DCT_II && type != vDSP_DCT_III && type != vDSP_DCT_IV)
        return NULL;
    return make_dft(DFT_DCT, length, -1, type);
}
vDSP_DFT_Interleaved_Setup vDSP_DFT_Interleaved_CreateSetup(vDSP_DFT_Interleaved_Setup previous, vDSP_Length length,
                                                            vDSP_DFT_Direction direction, vDSP_DFT_RealtoComplex real)
{
    return make_dft(real == vDSP_DFT_Interleaved_RealtoComplex ? DFT_INTERLEAVED_REAL : DFT_INTERLEAVED, length,
                    sign_of(direction), 0);
}
vDSP_DFT_Interleaved_SetupD vDSP_DFT_Interleaved_CreateSetupD(vDSP_DFT_Interleaved_SetupD previous, vDSP_Length length,
                                                              vDSP_DFT_Direction direction, vDSP_DFT_RealtoComplex real)
{
    return make_dft(real == vDSP_DFT_Interleaved_RealtoComplex ? DFT_INTERLEAVED_REAL : DFT_INTERLEAVED, length,
                    sign_of(direction), 0);
}
void vDSP_DFT_DestroySetup(vDSP_DFT_Setup setup) { free(setup); }
void vDSP_DFT_DestroySetupD(vDSP_DFT_SetupD setup) { free(setup); }
void vDSP_DFT_Interleaved_DestroySetup(vDSP_DFT_Interleaved_Setup setup) { free(setup); }
void vDSP_DFT_Interleaved_DestroySetupD(vDSP_DFT_Interleaved_SetupD setup) { free(setup); }

/* MARK: - DFT execution */

#define DEFINE_DFT(suffix, T, SETUPSTRUCT, ZC, ISETUP)                                                           \
    static void dft_planar##suffix(const FinchDFTSetup *s, const T *ir, const T *ii, vDSP_Stride is,     \
                                   T *or_, T *oi, vDSP_Stride os, int sign)                              \
    {                                                                                                    \
        size_t n = s->length;                                                                            \
        if (s->kind == DFT_ZROP) {                                                                       \
            size_t half = n / 2;                                                                         \
            double *buf = malloc(4 * (half ? half : 1) * sizeof(double));                                \
            if (!buf)                                                                                    \
                return;                                                                                  \
            double *re = buf, *im = buf + half, *outRe = im + half, *outIm = outRe + half;               \
            for (size_t j = 0; j < half; ++j) {                                                          \
                re[j] = ir[(ptrdiff_t)j * is];                                                           \
                im[j] = ii[(ptrdiff_t)j * is];                                                           \
            }                                                                                            \
            if (sign < 0)                                                                                \
                real_forward(re, im, outRe, outIm, n);                                                   \
            else                                                                                         \
                real_inverse(re, im, outRe, outIm, n);                                                   \
            for (size_t k = 0; k < half; ++k) {                                                          \
                or_[(ptrdiff_t)k * os] = (T)outRe[k];                                                    \
                oi[(ptrdiff_t)k * os] = (T)outIm[k];                                                     \
            }                                                                                            \
            free(buf);                                                                                   \
            return;                                                                                      \
        }                                                                                                \
        cplx *x = malloc((n ? n : 1) * sizeof(cplx));                                                    \
        if (!x)                                                                                          \
            return;                                                                                      \
        for (size_t j = 0; j < n; ++j)                                                                   \
            x[j] = ir[(ptrdiff_t)j * is] + I * ii[(ptrdiff_t)j * is];                                    \
        transform(x, n, sign);                                                                           \
        for (size_t k = 0; k < n; ++k) {                                                                 \
            or_[(ptrdiff_t)k * os] = (T)creal(x[k]);                                                     \
            oi[(ptrdiff_t)k * os] = (T)cimag(x[k]);                                                      \
        }                                                                                                \
        free(x);                                                                                         \
    }                                                                                                    \
    void vDSP_DFT_Execute##suffix(const struct SETUPSTRUCT *setup, const T *ir, const T *ii, T *or_,     \
                                  T *oi)                                                                 \
    {                                                                                                    \
        const FinchDFTSetup *s = (const FinchDFTSetup *)setup;                                           \
        if (s && s->magic == DFT_MAGIC)                                                                  \
            dft_planar##suffix(s, ir, ii, 1, or_, oi, 1, s->sign);                                       \
    }                                                                                                    \
    void vDSP_DFT_Interleaved_Execute##suffix(const ISETUP setup, const ZC *iri, ZC *ori)               \
    {                                                                                                    \
        const FinchDFTSetup *s = (const FinchDFTSetup *)setup;                                           \
        if (!s || s->magic != DFT_MAGIC)                                                                 \
            return;                                                                                      \
        const T *in = (const T *)iri;                                                                    \
        T *out = (T *)ori;                                                                               \
        FinchDFTSetup planar = *s;                                                                       \
        if (s->kind == DFT_INTERLEAVED_REAL) {                                                           \
            /* (Length complex elements hold 2*Length real values) */                                    \
            planar.kind = DFT_ZROP;                                                                      \
            planar.length = 2 * s->length;                                                               \
        }                                                                                                \
        dft_planar##suffix(&planar, in, in + 1, 2, out, out + 1, 2, s->sign);                            \
    }

DEFINE_DFT(, float, vDSP_DFT_SetupStruct, DSPComplex, vDSP_DFT_Interleaved_Setup)
DEFINE_DFT(D, double, vDSP_DFT_SetupStructD, DSPDoubleComplex, vDSP_DFT_Interleaved_SetupD)

void vDSP_DFT_zop(const struct vDSP_DFT_SetupStruct *setup, const float *ir, const float *ii, vDSP_Stride is, float *or_,
                  float *oi, vDSP_Stride os, vDSP_DFT_Direction direction)
{
    const FinchDFTSetup *s = (const FinchDFTSetup *)setup;
    if (s && s->magic == DFT_MAGIC)
        dft_planar(s, ir, ii, is, or_, oi, os, sign_of(direction));
}

void vDSP_DCT_Execute(const struct vDSP_DFT_SetupStruct *setup, const float *input, float *output)
{
    const FinchDFTSetup *s = (const FinchDFTSetup *)setup;
    if (!s || s->magic != DFT_MAGIC || s->kind != DFT_DCT)
        return;
    size_t n = s->length;
    double *out = malloc(n * sizeof(double));
    if (!out)
        return;
    for (size_t k = 0; k < n; ++k) {
        double sum = 0;
        for (size_t j = 0; j < n; ++j) {
            double angle;
            if (s->dctType == vDSP_DCT_II)
                angle = (double)k * ((double)j + 0.5) * M_PI / (double)n;
            else if (s->dctType == vDSP_DCT_III)
                angle = ((double)k + 0.5) * (double)j * M_PI / (double)n;
            else
                angle = ((double)k + 0.5) * ((double)j + 0.5) * M_PI / (double)n;
            double term = input[j] * cos(angle);
            sum += (s->dctType == vDSP_DCT_III && j == 0) ? input[0] / 2 : term;
        }
        out[k] = sum;
    }
    for (size_t k = 0; k < n; ++k)
        output[k] = (float)out[k];
    free(out);
}

/* MARK: - Fixed 16- and 32-point FFTs (unit stride) */

static void fixed_fft(float *outRe, float *outIm, ptrdiff_t ostride, const float *inRe, const float *inIm,
                      ptrdiff_t istride, size_t n, FFTDirection direction)
{
    cplx x[32];
    for (size_t j = 0; j < n; ++j)
        x[j] = inRe[(ptrdiff_t)j * istride] + I * inIm[(ptrdiff_t)j * istride];
    fft_pow2(x, n, direction == FFT_FORWARD ? -1 : 1);
    for (size_t k = 0; k < n; ++k) {
        outRe[(ptrdiff_t)k * ostride] = (float)creal(x[k]);
        outIm[(ptrdiff_t)k * ostride] = (float)cimag(x[k]);
    }
}

void vDSP_FFT16_copv(float *output, const float *input, FFTDirection direction)
{
    fixed_fft(output, output + 1, 2, input, input + 1, 2, 16, direction);
}
void vDSP_FFT32_copv(float *output, const float *input, FFTDirection direction)
{
    fixed_fft(output, output + 1, 2, input, input + 1, 2, 32, direction);
}
void vDSP_FFT16_zopv(float *outRe, float *outIm, const float *inRe, const float *inIm, FFTDirection direction)
{
    fixed_fft(outRe, outIm, 1, inRe, inIm, 1, 16, direction);
}
void vDSP_FFT32_zopv(float *outRe, float *outIm, const float *inRe, const float *inIm, FFTDirection direction)
{
    fixed_fft(outRe, outIm, 1, inRe, inIm, 1, 32, direction);
}

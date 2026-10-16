/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    vDSP_Length maxLog2;
    FFTRadix radix;
} FinchFFTSetup;

typedef struct {
    double real;
    double imag;
} FinchComplex;

static ptrdiff_t step(vDSP_Stride stride, vDSP_Length index)
{
    return (ptrdiff_t)stride * (ptrdiff_t)index;
}

static int transform(FinchComplex *values, size_t count, FFTDirection direction)
{
    size_t i, j, length;
    double sign = direction == FFT_FORWARD ? -1.0 : 1.0;

    if (count < 2)
        return 1;
    for (i = 1, j = 0; i < count; ++i) {
        size_t bit = count >> 1;
        while (j & bit) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            FinchComplex swap = values[i];
            values[i] = values[j];
            values[j] = swap;
        }
    }
    for (length = 2; length <= count; length <<= 1) {
        size_t half = length >> 1;
        double angle = sign * (2.0 * M_PI / (double)length);
        double stepReal = cos(angle), stepImag = sin(angle);
        size_t base;
        for (base = 0; base < count; base += length) {
            double wr = 1.0, wi = 0.0;
            for (j = 0; j < half; ++j) {
                FinchComplex even = values[base + j];
                FinchComplex odd = values[base + j + half];
                double tr = wr * odd.real - wi * odd.imag;
                double ti = wr * odd.imag + wi * odd.real;
                values[base + j].real = even.real + tr;
                values[base + j].imag = even.imag + ti;
                values[base + j + half].real = even.real - tr;
                values[base + j + half].imag = even.imag - ti;
                {
                    double nextReal = wr * stepReal - wi * stepImag;
                    wi = wr * stepImag + wi * stepReal;
                    wr = nextReal;
                }
            }
        }
        if (length == count)
            break;
    }
    return 1;
}

static void direct_transform(FinchComplex *values, size_t count, FFTDirection direction)
{
    FinchComplex *result = calloc(count, sizeof(*result));
    size_t k, n;
    double sign = direction == FFT_FORWARD ? -1.0 : 1.0;
    if (!result)
        return;
    for (k = 0; k < count; ++k) {
        double real = 0.0, imag = 0.0;
        for (n = 0; n < count; ++n) {
            double angle = sign * 2.0 * M_PI * (double)k * (double)n / (double)count;
            double c = cos(angle), s = sin(angle);
            real += values[n].real * c - values[n].imag * s;
            imag += values[n].real * s + values[n].imag * c;
        }
        result[k].real = real;
        result[k].imag = imag;
    }
    memcpy(values, result, count * sizeof(*result));
    free(result);
}

static size_t power_of_two_length(vDSP_Length log2n)
{
    if (log2n >= sizeof(size_t) * 8 || log2n > 24)
        return 0;
    return (size_t)1 << log2n;
}

void vDSP_vadd(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib,
               float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = a[step(ia, i)] + b[step(ib, i)];
}

void vDSP_vsub(const float *b, vDSP_Stride ib, const float *a, vDSP_Stride ia,
               float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = a[step(ia, i)] - b[step(ib, i)];
}

void vDSP_vmul(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib,
               float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = a[step(ia, i)] * b[step(ib, i)];
}

void vDSP_vclip(const float *a, vDSP_Stride ia, const float *low, const float *high,
                float *out, vDSP_Stride io, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        float value = a[step(ia, i)];
        if (value < low[0]) value = low[0];
        if (high[0] < value) value = high[0];
        out[step(io, i)] = value;
    }
}

void vDSP_vsma(const float *a, vDSP_Stride ia, const float *b, const float *c,
               vDSP_Stride ic, float *d, vDSP_Stride id, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        d[step(id, i)] = a[step(ia, i)] * b[0] + c[step(ic, i)];
}

void vDSP_vma(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib,
              const float *c, vDSP_Stride ic, float *d, vDSP_Stride id, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        d[step(id, i)] = a[step(ia, i)] * b[step(ib, i)] + c[step(ic, i)];
}

void vDSP_vsmul(const float *a, vDSP_Stride ia, const float *b, float *c,
                vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = a[step(ia, i)] * b[0];
}

void vDSP_vsadd(const float *a, vDSP_Stride ia, const float *b, float *c,
                vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = a[step(ia, i)] + b[0];
}

void vDSP_vsq(const float *a, vDSP_Stride ia, float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        float value = a[step(ia, i)];
        c[step(ic, i)] = value * value;
    }
}

void vDSP_vabs(const float *a, vDSP_Stride ia, float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = fabsf(a[step(ia, i)]);
}

void vDSP_vmax(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib,
               float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        float x = a[step(ia, i)], y = b[step(ib, i)];
        c[step(ic, i)] = x > y ? x : y;
    }
}

void vDSP_vclr(float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i)
        c[step(ic, i)] = 0.0f;
}

void vDSP_maxv(const float *a, vDSP_Stride ia, float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = n ? a[0] : -INFINITY;
    for (i = 1; i < n; ++i)
        if (a[step(ia, i)] > value) value = a[step(ia, i)];
    c[0] = value;
}

void vDSP_maxmgv(const float *a, vDSP_Stride ia, float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = 0.0f;
    for (i = 0; i < n; ++i) {
        float magnitude = fabsf(a[step(ia, i)]);
        if (magnitude > value) value = magnitude;
    }
    c[0] = value;
}

void vDSP_meanv(const float *a, vDSP_Stride ia, float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = 0.0f;
    for (i = 0; i < n; ++i)
        value += a[step(ia, i)];
    c[0] = n ? value / (float)n : NAN;
}

void vDSP_sve(const float *a, vDSP_Stride ia, float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = 0.0f;
    for (i = 0; i < n; ++i)
        value += a[step(ia, i)];
    c[0] = value;
}

void vDSP_svesq(const float *a, vDSP_Stride ia, float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = 0.0f;
    for (i = 0; i < n; ++i) {
        float x = a[step(ia, i)];
        value += x * x;
    }
    c[0] = value;
}

void vDSP_dotpr(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib,
                float *c, vDSP_Length n)
{
    vDSP_Length i;
    float value = 0.0f;
    for (i = 0; i < n; ++i)
        value += a[step(ia, i)] * b[step(ib, i)];
    c[0] = value;
}

void vDSP_conv(const float *a, vDSP_Stride ia, const float *f, vDSP_Stride iff,
               float *c, vDSP_Stride ic, vDSP_Length n, vDSP_Length p)
{
    vDSP_Length i, j;
    for (i = 0; i < n; ++i) {
        float value = 0.0f;
        for (j = 0; j < p; ++j)
            value += a[step(ia, i + j)] * f[step(iff, j)];
        c[step(ic, i)] = value;
    }
}

void vDSP_desamp(const float *a, vDSP_Stride factor, const float *f,
                 float *c, vDSP_Length n, vDSP_Length p)
{
    vDSP_Length i, j;
    for (i = 0; i < n; ++i) {
        float value = 0.0f;
        for (j = 0; j < p; ++j)
            value += a[(ptrdiff_t)i * factor + (ptrdiff_t)j] * f[j];
        c[i] = value;
    }
}

void vDSP_deq22(const float *a, vDSP_Stride ia, const float *b,
                float *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        vDSP_Length out = i + 2;
        c[step(ic, out)] = a[step(ia, out)] * b[0] + a[step(ia, out - 1)] * b[1] +
                           a[step(ia, out - 2)] * b[2] - c[step(ic, out - 1)] * b[3] -
                           c[step(ic, out - 2)] * b[4];
    }
}

void vDSP_deq22D(const double *a, vDSP_Stride ia, const double *b,
                 double *c, vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        vDSP_Length out = i + 2;
        c[step(ic, out)] = a[step(ia, out)] * b[0] + a[step(ia, out - 1)] * b[1] +
                           a[step(ia, out - 2)] * b[2] - c[step(ic, out - 1)] * b[3] -
                           c[step(ic, out - 2)] * b[4];
    }
}

void vDSP_zvmul(const DSPSplitComplex *a, vDSP_Stride ia, const DSPSplitComplex *b,
                vDSP_Stride ib, const DSPSplitComplex *c, vDSP_Stride ic,
                vDSP_Length n, int conjugate)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        ptrdiff_t ai = step(ia, i), bi = step(ib, i), ci = step(ic, i);
        float ar = a->realp[ai], av = a->imagp[ai];
        float br = b->realp[bi], bv = b->imagp[bi];
        if (conjugate) av = -av;
        c->realp[ci] = ar * br - av * bv;
        c->imagp[ci] = ar * bv + av * br;
    }
}

void vDSP_ctoz(const DSPComplex *c, vDSP_Stride ic, const DSPSplitComplex *z,
               vDSP_Stride iz, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        ptrdiff_t source = step(ic, i) / 2;
        z->realp[step(iz, i)] = c[source].real;
        z->imagp[step(iz, i)] = c[source].imag;
    }
}

void vDSP_ztoc(const DSPSplitComplex *z, vDSP_Stride iz, DSPComplex *c,
               vDSP_Stride ic, vDSP_Length n)
{
    vDSP_Length i;
    for (i = 0; i < n; ++i) {
        ptrdiff_t destination = step(ic, i) / 2;
        c[destination].real = z->realp[step(iz, i)];
        c[destination].imag = z->imagp[step(iz, i)];
    }
}

FFTSetup vDSP_create_fftsetup(vDSP_Length log2n, FFTRadix radix)
{
    FinchFFTSetup *setup;
    if (!power_of_two_length(log2n) ||
        (radix != kFFTRadix2 && radix != kFFTRadix3 && radix != kFFTRadix5))
        return NULL;
    setup = malloc(sizeof(*setup));
    if (!setup) return NULL;
    setup->maxLog2 = log2n;
    setup->radix = radix;
    return (FFTSetup)setup;
}

void vDSP_destroy_fftsetup(FFTSetup setup)
{
    free((void *)setup);
}

static void fft_out_of_place(FFTSetup opaque, const DSPSplitComplex *input,
                             vDSP_Stride inputStride, const DSPSplitComplex *output,
                             vDSP_Stride outputStride, vDSP_Length log2n,
                             FFTDirection direction, unsigned int extraRadix)
{
    FinchFFTSetup *setup = (FinchFFTSetup *)opaque;
    size_t n = power_of_two_length(log2n), i;
    FinchComplex *values;
    if (!setup || !n || log2n > setup->maxLog2 || n > SIZE_MAX / extraRadix)
        return;
    n *= extraRadix;
    if (n > 262144) return;
    values = malloc(n * sizeof(*values));
    if (!values) return;
    for (i = 0; i < n; ++i) {
        values[i].real = input->realp[step(inputStride, i)];
        values[i].imag = input->imagp[step(inputStride, i)];
    }
    if (extraRadix == 1) transform(values, n, direction);
    else direct_transform(values, n, direction);
    for (i = 0; i < n; ++i) {
        output->realp[step(outputStride, i)] = (float)values[i].real;
        output->imagp[step(outputStride, i)] = (float)values[i].imag;
    }
    free(values);
}

void vDSP_fft_zop(FFTSetup setup, const DSPSplitComplex *a, vDSP_Stride ia,
                  const DSPSplitComplex *c, vDSP_Stride ic, vDSP_Length log2n,
                  FFTDirection direction)
{
    fft_out_of_place(setup, a, ia, c, ic, log2n, direction, 1);
}

void vDSP_fft3_zop(FFTSetup setup, const DSPSplitComplex *a, vDSP_Stride ia,
                   const DSPSplitComplex *c, vDSP_Stride ic, vDSP_Length log2n,
                   FFTDirection direction)
{
    fft_out_of_place(setup, a, ia, c, ic, log2n, direction, 3);
}

void vDSP_fft5_zop(FFTSetup setup, const DSPSplitComplex *a, vDSP_Stride ia,
                   const DSPSplitComplex *c, vDSP_Stride ic, vDSP_Length log2n,
                   FFTDirection direction)
{
    fft_out_of_place(setup, a, ia, c, ic, log2n, direction, 5);
}

void vDSP_fft_zrip(FFTSetup opaque, const DSPSplitComplex *data, vDSP_Stride stride,
                   vDSP_Length log2n, FFTDirection direction)
{
    FinchFFTSetup *setup = (FinchFFTSetup *)opaque;
    size_t n = power_of_two_length(log2n), i;
    FinchComplex *values;
    if (!setup || !n || log2n > setup->maxLog2 || n < 2)
        return;
    values = calloc(n, sizeof(*values));
    if (!values) return;
    if (direction == FFT_FORWARD) {
        for (i = 0; i < n / 2; ++i) {
            values[2 * i].real = data->realp[step(stride, i)];
            values[2 * i + 1].real = data->imagp[step(stride, i)];
        }
        transform(values, n, direction);
        data->realp[0] = (float)(2.0 * values[0].real);
        data->imagp[0] = (float)(2.0 * values[n / 2].real);
        for (i = 1; i < n / 2; ++i) {
            data->realp[step(stride, i)] = (float)(2.0 * values[i].real);
            data->imagp[step(stride, i)] = (float)(2.0 * values[i].imag);
        }
    } else {
        values[0].real = data->realp[0];
        values[n / 2].real = data->imagp[0];
        for (i = 1; i < n / 2; ++i) {
            values[i].real = data->realp[step(stride, i)];
            values[i].imag = data->imagp[step(stride, i)];
            values[n - i].real = values[i].real;
            values[n - i].imag = -values[i].imag;
        }
        transform(values, n, direction);
        for (i = 0; i < n / 2; ++i) {
            data->realp[step(stride, i)] = (float)values[2 * i].real;
            data->imagp[step(stride, i)] = (float)values[2 * i + 1].real;
        }
    }
    free(values);
}

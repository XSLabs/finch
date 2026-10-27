/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vectorOps.h: vecLib's original BLAS over arrays of vFloats (counts in floats,
 * matrices row by row), as the header describes them.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define F(p) ((float *)(p))
#define CF(p) ((const float *)(p))

static int32_t find(int32_t count, const vFloat *x, int magnitude, int largest)
{
    const float *v = CF(x);
    int32_t best = 0;
    for (int32_t i = 1; i < count; ++i) {
        float a = magnitude ? fabsf(v[i]) : v[i], b = magnitude ? fabsf(v[best]) : v[best];
        if (largest ? a > b : a < b)
            best = i;
    }
    return best;
}

int32_t vIsamax(int32_t count, const vFloat *x) { return find(count, x, 1, 1); }
int32_t vIsamin(int32_t count, const vFloat *x) { return find(count, x, 1, 0); }
int32_t vIsmax(int32_t count, const vFloat *x) { return find(count, x, 0, 1); }
int32_t vIsmin(int32_t count, const vFloat *x) { return find(count, x, 0, 0); }

float vSasum(int32_t count, const vFloat *x)
{
    float sum = 0;
    for (int32_t i = 0; i < count; ++i)
        sum += fabsf(CF(x)[i]);
    return sum;
}

float vSsum(int32_t count, const vFloat *x)
{
    float sum = 0;
    for (int32_t i = 0; i < count; ++i)
        sum += CF(x)[i];
    return sum;
}

void vSaxpy(int32_t n, float alpha, const vFloat *x, vFloat *y)
{
    for (int32_t i = 0; i < n; ++i)
        F(y)[i] += alpha * CF(x)[i];
}

void vScopy(int32_t n, const vFloat *x, vFloat *y) { memmove(y, x, (size_t)n * sizeof(float)); }

float vSdot(int32_t n, const vFloat *x, const vFloat *y)
{
    float sum = 0;
    for (int32_t i = 0; i < n; ++i)
        sum += CF(x)[i] * CF(y)[i];
    return sum;
}

/* y(i) += a(i) * x(i), for n vectors of m floats */
void vSnaxpy(int32_t n, int32_t m, const vFloat *a, const vFloat *x, vFloat *y)
{
    for (int32_t i = 0; i < n; ++i)
        for (int32_t j = 0; j < m; ++j)
            F(y)[i * m + j] += CF(a)[i] * CF(x)[i * m + j];
}

void vSndot(int32_t n, int32_t m, float *s, int32_t isw, const vFloat *x, const vFloat *y)
{
    for (int32_t i = 0; i < n; ++i) {
        float dot = vSdot(m, (const vFloat *)(CF(x) + i * m), (const vFloat *)(CF(y) + i * m));
        switch (isw) {
        case 1: s[i] = dot; break;
        case 2: s[i] = -dot; break;
        case 3: s[i] += dot; break;
        case 4: s[i] -= dot; break;
        default: break;
        }
    }
}

/* scaled, so that squares neither overflow nor underflow */
float vSnrm2(int32_t count, const vFloat *x)
{
    float scale = 0;
    for (int32_t i = 0; i < count; ++i)
        scale = fmaxf(scale, fabsf(CF(x)[i]));
    if (scale == 0 || isinf(scale))
        return scale;
    double sum = 0;
    for (int32_t i = 0; i < count; ++i) {
        double v = CF(x)[i] / scale;
        sum += v * v;
    }
    return (float)(scale * sqrt(sum));
}

float vSnorm2(int32_t count, const vFloat *x) { return sqrtf(vSdot(count, x, x)); }

void vSrot(int32_t n, vFloat *x, vFloat *y, float c, float s)
{
    for (int32_t i = 0; i < n; ++i) {
        float a = F(x)[i], b = F(y)[i];
        F(x)[i] = c * a + s * b;
        F(y)[i] = c * b - s * a;
    }
}

void vSscal(int32_t n, float alpha, vFloat *x)
{
    for (int32_t i = 0; i < n; ++i)
        F(x)[i] *= alpha;
}

void vSswap(int32_t n, vFloat *x, vFloat *y)
{
    for (int32_t i = 0; i < n; ++i) {
        float t = F(x)[i];
        F(x)[i] = F(y)[i];
        F(y)[i] = t;
    }
}

void vSyax(int32_t n, float alpha, const vFloat *x, vFloat *y)
{
    for (int32_t i = 0; i < n; ++i)
        F(y)[i] = alpha * CF(x)[i];
}

void vSzaxpy(int32_t n, float alpha, const vFloat *x, const vFloat *y, vFloat *z)
{
    for (int32_t i = 0; i < n; ++i)
        F(z)[i] = alpha * CF(x)[i] + CF(y)[i];
}

static int transposed(char form) { return form == 'T' || form == 't'; }

/* y = alpha * op(A) * x + beta * y, A being m by n */
void vSgemv(char forma, int32_t m, int32_t n, float alpha, const vFloat *a, const vFloat *x, float beta, vFloat *y)
{
    int t = transposed(forma);
    int32_t rows = t ? n : m, inner = t ? m : n;
    float *out = calloc((size_t)(rows ? rows : 1), sizeof(float));
    if (!out)
        return;
    for (int32_t i = 0; i < rows; ++i) {
        float sum = 0;
        for (int32_t j = 0; j < inner; ++j)
            sum += (t ? CF(a)[j * n + i] : CF(a)[i * n + j]) * CF(x)[j];
        out[i] = alpha * sum + beta * F(y)[i];
    }
    memcpy(y, out, (size_t)rows * sizeof(float));
    free(out);
}

void vSgemx(int32_t m, int32_t n, float alpha, const vFloat *a, const vFloat *x, vFloat *y)
{
    vSgemv('N', m, n, alpha, a, x, 1, y);
}

void vSgemtx(int32_t m, int32_t n, float alpha, const vFloat *a, const vFloat *x, vFloat *y)
{
    vSgemv('T', m, n, alpha, a, x, 1, y);
}

/* element (i, j) of op(A), op(A) having the given width */
static float at(const vFloat *a, char form, int32_t i, int32_t j, int32_t rows, int32_t cols)
{
    return transposed(form) ? CF(a)[j * rows + i] : CF(a)[i * cols + j];
}

static void geadd(int32_t height, int32_t width, const vFloat *a, char forma, const vFloat *b, char formb, vFloat *c,
                  float sign)
{
    float *out = malloc((size_t)(height * width ? height * width : 1) * sizeof(float));
    if (!out)
        return;
    for (int32_t i = 0; i < height; ++i)
        for (int32_t j = 0; j < width; ++j)
            out[i * width + j] =
                at(a, forma, i, j, height, width) + sign * at(b, formb, i, j, height, width);
    memcpy(c, out, (size_t)(height * width) * sizeof(float));
    free(out);
}

void vSgeadd(int32_t height, int32_t width, const vFloat *a, char forma, const vFloat *b, char formb, vFloat *c)
{
    geadd(height, width, a, forma, b, formb, c, 1);
}

void vSgesub(int32_t height, int32_t width, const vFloat *a, char forma, const vFloat *b, char formb, vFloat *c)
{
    geadd(height, width, a, forma, b, formb, c, -1);
}

/* matrix (l by n) = alpha * op(A) (l by m) * op(B) (m by n) + beta * C */
void vSgemm(int32_t l, int32_t m, int32_t n, const vFloat *a, char forma, const vFloat *b, char formb, vFloat *c,
            float alpha, float beta, vFloat *matrix)
{
    float *out = malloc((size_t)(l * n ? l * n : 1) * sizeof(float));
    if (!out)
        return;
    for (int32_t i = 0; i < l; ++i)
        for (int32_t j = 0; j < n; ++j) {
            float sum = 0;
            for (int32_t k = 0; k < m; ++k)
                sum += at(a, forma, i, k, l, m) * at(b, formb, k, j, m, n);
            out[i * n + j] = alpha * sum + (c ? beta * CF(c)[i * n + j] : 0);
        }
    memcpy(matrix, out, (size_t)(l * n) * sizeof(float));
    free(out);
}

void vSgemul(int32_t l, int32_t m, int32_t n, const vFloat *a, char forma, const vFloat *b, char formb,
             vFloat *matrix)
{
    vSgemm(l, m, n, a, forma, b, formb, NULL, 1, 0, matrix);
}

void vSgetmi(int32_t size, vFloat *x)
{
    for (int32_t i = 0; i < size; ++i)
        for (int32_t j = i + 1; j < size; ++j) {
            float t = F(x)[i * size + j];
            F(x)[i * size + j] = F(x)[j * size + i];
            F(x)[j * size + i] = t;
        }
}

/* y (width by height) = x (height by width) transposed */
void vSgetmo(int32_t height, int32_t width, const vFloat *x, vFloat *y)
{
    for (int32_t i = 0; i < height; ++i)
        for (int32_t j = 0; j < width; ++j)
            F(y)[j * height + i] = CF(x)[i * width + j];
}

/* M (l by n) = A (l) times B (n) transposed */
void vSgevv(int32_t l, int32_t n, const vFloat *A, const vFloat *B, vFloat *M)
{
    for (int32_t i = 0; i < l; ++i)
        for (int32_t j = 0; j < n; ++j)
            F(M)[i * n + j] = CF(A)[i] * CF(B)[j];
}

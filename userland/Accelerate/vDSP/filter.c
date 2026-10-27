/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP's filters and matrices: correlation and convolution, decimation, the
 * two-pole two-zero difference equation, cascaded biquad IIR filters (single and
 * multi-channel, with coefficient ramps), 3x3, 5x5 and general image convolution,
 * Wiener-Levinson, the Hann, Hamming and Blackman windows, and matrix multiply,
 * transpose and copy, each as vDSP.h describes it.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define AT(p, s, i) ((p)[(ptrdiff_t)(s) * (ptrdiff_t)(i)])

/* MARK: - Biquad setups (shared by both precisions; arithmetic in double) */

typedef struct {
    double b0, b1, b2, a1, a2;
} Section;

struct vDSP_biquad_SetupStruct {
    vDSP_Length sections;
    Section s[];
};

static struct vDSP_biquad_SetupStruct *biquad_create(const double *coefficients, vDSP_Length M)
{
    if (!coefficients || !M)
        return NULL;
    struct vDSP_biquad_SetupStruct *setup = malloc(sizeof(*setup) + M * sizeof(Section));
    if (!setup)
        return NULL;
    setup->sections = M;
    memcpy(setup->s, coefficients, M * sizeof(Section));
    return setup;
}

vDSP_biquad_Setup vDSP_biquad_CreateSetup(const double *coefficients, vDSP_Length M)
{
    return biquad_create(coefficients, M);
}
vDSP_biquad_SetupD vDSP_biquad_CreateSetupD(const double *coefficients, vDSP_Length M)
{
    return (vDSP_biquad_SetupD)biquad_create(coefficients, M);
}
void vDSP_biquad_DestroySetup(vDSP_biquad_Setup setup) { free(setup); }
void vDSP_biquad_DestroySetupD(vDSP_biquad_SetupD setup) { free(setup); }

void vDSP_biquad_SetCoefficientsDouble(vDSP_biquad_Setup setup, const double *coeffs, vDSP_Length start, vDSP_Length n)
{
    if (setup && start + n <= setup->sections)
        memcpy(setup->s + start, coeffs, n * sizeof(Section));
}

void vDSP_biquad_SetCoefficientsSingle(vDSP_biquad_Setup setup, const float *coeffs, vDSP_Length start, vDSP_Length n)
{
    if (!setup || start + n > setup->sections)
        return;
    for (vDSP_Length i = 0; i < n; ++i) {
        const float *c = coeffs + 5 * i;
        setup->s[start + i] = (Section){c[0], c[1], c[2], c[3], c[4]};
    }
}

/* Delay holds x[s][-2], x[s][-1] for each of the S+1 rows, and is updated. */
#define BIQUAD(name, T, SETUP)                                                                           \
    void name(const SETUP *setup_, T *delay, const T *X, vDSP_Stride IX, T *Y, vDSP_Stride IY,          \
              vDSP_Length N)                                                                             \
    {                                                                                                    \
        const struct vDSP_biquad_SetupStruct *setup = (const struct vDSP_biquad_SetupStruct *)setup_;    \
        vDSP_Length S = setup->sections;                                                                 \
        double *row = malloc((N + 2) * sizeof(double)), *next = malloc((N + 2) * sizeof(double));        \
        if (!row || !next) {                                                                             \
            free(row);                                                                                   \
            free(next);                                                                                  \
            return;                                                                                      \
        }                                                                                                \
        row[0] = delay[0];                                                                               \
        row[1] = delay[1];                                                                               \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            row[n + 2] = AT(X, IX, n);                                                                   \
        delay[0] = (T)row[N];                                                                            \
        delay[1] = (T)row[N + 1];                                                                        \
        for (vDSP_Length s = 1; s <= S; ++s) {                                                           \
            const Section *c = &setup->s[s - 1];                                                         \
            next[0] = delay[2 * s];                                                                      \
            next[1] = delay[2 * s + 1];                                                                  \
            for (vDSP_Length n = 0; n < N; ++n)                                                          \
                next[n + 2] = c->b0 * row[n + 2] + c->b1 * row[n + 1] + c->b2 * row[n] -                 \
                              c->a1 * next[n + 1] - c->a2 * next[n];                                     \
            delay[2 * s] = (T)next[N];                                                                   \
            delay[2 * s + 1] = (T)next[N + 1];                                                           \
            double *swap = row;                                                                          \
            row = next;                                                                                  \
            next = swap;                                                                                 \
        }                                                                                                \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            AT(Y, IY, n) = (T)row[n + 2];                                                                \
        free(row);                                                                                       \
        free(next);                                                                                      \
    }

BIQUAD(vDSP_biquad, float, struct vDSP_biquad_SetupStruct)
BIQUAD(vDSP_biquadD, double, struct vDSP_biquad_SetupStructD)

/* MARK: - Multi-channel biquads: M sections by N channels, coefficients section by section */

typedef struct {
    vDSP_Length sections, channels;
    Section *coeffs;  /* [section * channels + channel] */
    Section *targets; /* ramp targets, when ramping */
    double rate, threshold;
    bool ramping;
    double *state; /* per channel, (sections + 1) * 2 delays */
    bool *active;  /* per section: an inactive one passes its input through */
} Biquadm;

struct vDSP_biquadm_SetupStruct {
    Biquadm m;
};

static Biquadm *biquadm_create(const double *coeffs, vDSP_Length M, vDSP_Length N)
{
    if (!coeffs || !M || !N)
        return NULL;
    Biquadm *b = calloc(1, sizeof(*b));
    if (!b)
        return NULL;
    b->sections = M;
    b->channels = N;
    b->coeffs = malloc(M * N * sizeof(Section));
    b->targets = malloc(M * N * sizeof(Section));
    b->state = calloc(N * (M + 1) * 2, sizeof(double));
    b->active = malloc(M * sizeof(bool));
    if (!b->coeffs || !b->targets || !b->state || !b->active) {
        free(b->coeffs);
        free(b->targets);
        free(b->state);
        free(b->active);
        free(b);
        return NULL;
    }
    memcpy(b->coeffs, coeffs, M * N * sizeof(Section));
    for (vDSP_Length m = 0; m < M; ++m)
        b->active[m] = true;
    return b;
}

static void biquadm_destroy(Biquadm *b)
{
    if (!b)
        return;
    free(b->coeffs);
    free(b->targets);
    free(b->state);
    free(b->active);
    free(b);
}

vDSP_biquadm_Setup vDSP_biquadm_CreateSetup(const double *coeffs, vDSP_Length M, vDSP_Length N)
{
    return (vDSP_biquadm_Setup)biquadm_create(coeffs, M, N);
}
vDSP_biquadm_SetupD vDSP_biquadm_CreateSetupD(const double *coeffs, vDSP_Length M, vDSP_Length N)
{
    return (vDSP_biquadm_SetupD)biquadm_create(coeffs, M, N);
}
void vDSP_biquadm_DestroySetup(vDSP_biquadm_Setup setup) { biquadm_destroy((Biquadm *)setup); }
void vDSP_biquadm_DestroySetupD(vDSP_biquadm_SetupD setup) { biquadm_destroy((Biquadm *)setup); }

static void biquadm_copy_state(Biquadm *dest, const Biquadm *src)
{
    if (dest && src && dest->sections == src->sections && dest->channels == src->channels)
        memcpy(dest->state, src->state, dest->channels * (dest->sections + 1) * 2 * sizeof(double));
}
void vDSP_biquadm_CopyState(vDSP_biquadm_Setup dest, const struct vDSP_biquadm_SetupStruct *src)
{
    biquadm_copy_state((Biquadm *)dest, (const Biquadm *)src);
}
void vDSP_biquadm_CopyStateD(vDSP_biquadm_SetupD dest, const struct vDSP_biquadm_SetupStructD *src)
{
    biquadm_copy_state((Biquadm *)dest, (const Biquadm *)src);
}

static void biquadm_reset(Biquadm *b)
{
    if (b)
        memset(b->state, 0, b->channels * (b->sections + 1) * 2 * sizeof(double));
}
void vDSP_biquadm_ResetState(vDSP_biquadm_Setup setup) { biquadm_reset((Biquadm *)setup); }
void vDSP_biquadm_ResetStateD(vDSP_biquadm_SetupD setup) { biquadm_reset((Biquadm *)setup); }

static void biquadm_set_active(Biquadm *b, const bool *states)
{
    if (b && states)
        memcpy(b->active, states, b->sections * sizeof(bool));
}
void vDSP_biquadm_SetActiveFilters(vDSP_biquadm_Setup setup, const bool *states)
{
    biquadm_set_active((Biquadm *)setup, states);
}
void vDSP_biquadm_SetActiveFiltersD(vDSP_biquadm_SetupD setup, const bool *states)
{
    biquadm_set_active((Biquadm *)setup, states);
}

/* Coefficients for nsec sections of nchn channels, starting at (start_sec, start_chn). */
#define SET_SECTIONS(dest, T, coeffs)                                                                    \
    do {                                                                                                 \
        if (!b || start_sec + nsec > b->sections || start_chn + nchn > b->channels)                      \
            return;                                                                                      \
        const T *c = (coeffs);                                                                           \
        for (vDSP_Length s = 0; s < nsec; ++s)                                                           \
            for (vDSP_Length ch = 0; ch < nchn; ++ch, c += 5)                                            \
                (dest)[(start_sec + s) * b->channels + start_chn + ch] =                                 \
                    (Section){c[0], c[1], c[2], c[3], c[4]};                                             \
    } while (0)

#define BIQUADM_SETTERS(suffix, SETUP, R)                                                                  \
    void vDSP_biquadm_SetCoefficientsDouble##suffix(SETUP setup, const double *coeffs,                   \
                                                     vDSP_Length start_sec, vDSP_Length start_chn,       \
                                                     vDSP_Length nsec, vDSP_Length nchn)                 \
    {                                                                                                    \
        Biquadm *b = (Biquadm *)setup;                                                                   \
        SET_SECTIONS(b->coeffs, double, coeffs);                                                         \
        b->ramping = false;                                                                              \
    }                                                                                                    \
    void vDSP_biquadm_SetCoefficientsSingle##suffix(SETUP setup, const float *coeffs,                    \
                                                     vDSP_Length start_sec, vDSP_Length start_chn,       \
                                                     vDSP_Length nsec, vDSP_Length nchn)                 \
    {                                                                                                    \
        Biquadm *b = (Biquadm *)setup;                                                                   \
        SET_SECTIONS(b->coeffs, float, coeffs);                                                          \
        b->ramping = false;                                                                              \
    }                                                                                                    \
    void vDSP_biquadm_SetTargetsDouble##suffix(SETUP setup, const double *targets, R rate,              \
                                                R threshold, vDSP_Length start_sec,                      \
                                                vDSP_Length start_chn, vDSP_Length nsec, vDSP_Length nchn) \
    {                                                                                                    \
        Biquadm *b = (Biquadm *)setup;                                                                   \
        if (b && !b->ramping)                                                                            \
            memcpy(b->targets, b->coeffs, b->sections * b->channels * sizeof(Section));                  \
        SET_SECTIONS(b->targets, double, targets);                                                       \
        b->rate = rate;                                                                                  \
        b->threshold = threshold;                                                                        \
        b->ramping = true;                                                                               \
    }                                                                                                    \
    void vDSP_biquadm_SetTargetsSingle##suffix(SETUP setup, const float *targets, R rate,               \
                                                R threshold, vDSP_Length start_sec,                      \
                                                vDSP_Length start_chn, vDSP_Length nsec, vDSP_Length nchn) \
    {                                                                                                    \
        Biquadm *b = (Biquadm *)setup;                                                                   \
        if (b && !b->ramping)                                                                            \
            memcpy(b->targets, b->coeffs, b->sections * b->channels * sizeof(Section));                  \
        SET_SECTIONS(b->targets, float, targets);                                                        \
        b->rate = rate;                                                                                  \
        b->threshold = threshold;                                                                        \
        b->ramping = true;                                                                               \
    }

/* The names without a D suffix take a vDSP_biquadm_Setup (and float ramp parameters);
   the D forms a vDSP_biquadm_SetupD. */
BIQUADM_SETTERS(, vDSP_biquadm_Setup, float)
BIQUADM_SETTERS(D, vDSP_biquadm_SetupD, double)

/* One ramp step per sample: each coefficient moves rate of the way to its target and
   lands on it once within threshold. */
static void biquadm_ramp(Biquadm *b)
{
    bool done = true;
    double *c = (double *)b->coeffs, *t = (double *)b->targets;
    for (size_t i = 0; i < b->sections * b->channels * 5; ++i) {
        double diff = t[i] - c[i];
        if (fabs(diff) <= b->threshold)
            c[i] = t[i];
        else {
            c[i] += b->rate * diff;
            done = false;
        }
    }
    if (done)
        b->ramping = false;
}

/* Each channel keeps, per row s (0 = input), the last two values x[s][n-2], x[s][n-1]. */
#define BIQUADM(name, T, SETUP)                                                                          \
    void name(SETUP setup, const T **X, vDSP_Stride IX, T **Y, vDSP_Stride IY, vDSP_Length N)            \
    {                                                                                                    \
        Biquadm *b = (Biquadm *)setup;                                                                   \
        vDSP_Length S = b->sections, C = b->channels;                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            if (b->ramping)                                                                              \
                biquadm_ramp(b);                                                                         \
            for (vDSP_Length ch = 0; ch < C; ++ch) {                                                     \
                double *d = b->state + ch * (S + 1) * 2;                                                 \
                double v = AT(X[ch], IX, n); /* x[s-1][n] */                                             \
                double prev1 = d[1], prev2 = d[0];                                                       \
                d[0] = d[1];                                                                             \
                d[1] = v;                                                                                \
                for (vDSP_Length s = 1; s <= S; ++s) {                                                   \
                    const Section *c = &b->coeffs[(s - 1) * C + ch];                                     \
                    double y1 = d[2 * s + 1], y2 = d[2 * s];                                             \
                    double y = b->active[s - 1]                                                          \
                                   ? c->b0 * v + c->b1 * prev1 + c->b2 * prev2 - c->a1 * y1 - c->a2 * y2 \
                                   : v;                                                                  \
                    d[2 * s] = y1;                                                                       \
                    d[2 * s + 1] = y;                                                                    \
                    v = y;                                                                               \
                    prev1 = y1;                                                                          \
                    prev2 = y2;                                                                          \
                }                                                                                        \
                AT(Y[ch], IY, n) = (T)v;                                                                 \
            }                                                                                            \
        }                                                                                                \
    }

BIQUADM(vDSP_biquadm, float, vDSP_biquadm_Setup)
BIQUADM(vDSP_biquadmD, double, vDSP_biquadm_SetupD)

/* MARK: - Filters, windows and matrices in both precisions */

#define FILTERS(suffix, T, CAST)                                                                         \
    void vDSP_conv##suffix(const T *A, vDSP_Stride IA, const T *F, vDSP_Stride IF, T *C, vDSP_Stride IC, \
                           vDSP_Length N, vDSP_Length P)                                                 \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            double sum = 0;                                                                              \
            for (vDSP_Length p = 0; p < P; ++p)                                                          \
                sum += (double)AT(A, IA, n + p) * AT(F, IF, p);                                          \
            AT(C, IC, n) = (T)sum;                                                                       \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_desamp##suffix(const T *A, vDSP_Stride DF, const T *F, T *C, vDSP_Length N, vDSP_Length P) \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n) {                                                            \
            double sum = 0;                                                                              \
            for (vDSP_Length p = 0; p < P; ++p)                                                          \
                sum += (double)A[(ptrdiff_t)n * DF + (ptrdiff_t)p] * F[p];                               \
            C[n] = (T)sum;                                                                               \
        }                                                                                                \
    }                                                                                                    \
    void vDSP_deq22##suffix(const T *A, vDSP_Stride IA, const T *B, T *C, vDSP_Stride IC, vDSP_Length N) \
    {                                                                                                    \
        for (vDSP_Length n = 2; n < N + 2; ++n)                                                          \
            AT(C, IC, n) = (T)((double)AT(A, IA, n) * B[0] + (double)AT(A, IA, n - 1) * B[1] +           \
                               (double)AT(A, IA, n - 2) * B[2] - (double)AT(C, IC, n - 1) * B[3] -       \
                               (double)AT(C, IC, n - 2) * B[4]);                                         \
    }                                                                                                    \
    void vDSP_imgfir##suffix(const T *A, vDSP_Length NR, vDSP_Length NC, const T *F, T *C, vDSP_Length P, \
                             vDSP_Length Q)                                                              \
    {                                                                                                    \
        vDSP_Length hp = P / 2, hq = Q / 2;                                                              \
        T *out = malloc((NR * NC ? NR * NC : 1) * sizeof(T));                                            \
        if (!out)                                                                                        \
            return;                                                                                      \
        for (vDSP_Length r = 0; r < NR; ++r)                                                             \
            for (vDSP_Length c = 0; c < NC; ++c) {                                                       \
                if (r < hp || r + hp >= NR || c < hq || c + hq >= NC) {                                  \
                    out[r * NC + c] = 0;                                                                 \
                    continue;                                                                            \
                }                                                                                        \
                double sum = 0;                                                                          \
                for (vDSP_Length j = 0; j < P; ++j)                                                      \
                    for (vDSP_Length k = 0; k < Q; ++k)                                                  \
                        sum += (double)A[(r + j - hp) * NC + (c + k - hq)] * F[j * Q + k];               \
                out[r * NC + c] = (T)sum;                                                                \
            }                                                                                            \
        memcpy(C, out, NR * NC * sizeof(T));                                                             \
        free(out);                                                                                       \
    }                                                                                                    \
    void vDSP_f3x3##suffix(const T *A, vDSP_Length NR, vDSP_Length NC, const T *F, T *C)                 \
    {                                                                                                    \
        vDSP_imgfir##suffix(A, NR, NC, F, C, 3, 3);                                                      \
    }                                                                                                    \
    void vDSP_f5x5##suffix(const T *A, vDSP_Length NR, vDSP_Length NC, const T *F, T *C)                 \
    {                                                                                                    \
        vDSP_imgfir##suffix(A, NR, NC, F, C, 5, 5);                                                      \
    }                                                                                                    \
                                                                                                         \
    /* Solves the Toeplitz system with autocorrelation A for right side C (Levinson's                    \
       recursion); P gets the prediction-error filter 1, a1, a2, ... */                                  \
    void vDSP_wiener##suffix(vDSP_Length L, const T *A, const T *C, T *F, T *P, int flag, int *error)    \
    {                                                                                                    \
        double *f = calloc(L + 1, sizeof(double)), *a = calloc(L + 1, sizeof(double)),                   \
               *tmp = calloc(L + 1, sizeof(double));                                                     \
        if (error)                                                                                       \
            *error = 0;                                                                                  \
        if (!f || !a || !tmp || !L) {                                                                    \
            free(f);                                                                                     \
            free(a);                                                                                     \
            free(tmp);                                                                                   \
            return;                                                                                      \
        }                                                                                                \
        double e = A[0];                                                                                 \
        a[0] = 1;                                                                                        \
        f[0] = C[0] / A[0];                                                                              \
        for (vDSP_Length m = 1; m < L; ++m) {                                                            \
            double acc = 0;                                                                              \
            for (vDSP_Length i = 0; i < m; ++i)                                                          \
                acc += a[i] * A[m - i];                                                                  \
            double k = -acc / e;                                                                         \
            tmp[0] = 1;                                                                                  \
            tmp[m] = k;                                                                                  \
            for (vDSP_Length i = 1; i < m; ++i)                                                          \
                tmp[i] = a[i] + k * a[m - i];                                                            \
            memcpy(a, tmp, (m + 1) * sizeof(double));                                                    \
            e *= 1 - k * k;                                                                              \
            double g = 0;                                                                                \
            for (vDSP_Length i = 0; i < m; ++i)                                                          \
                g += f[i] * A[m - i];                                                                    \
            double q = (C[m] - g) / e;                                                                   \
            for (vDSP_Length i = 0; i <= m; ++i)                                                         \
                f[i] += q * a[m - i];                                                                    \
        }                                                                                                \
        for (vDSP_Length i = 0; i < L; ++i) {                                                            \
            F[i] = (T)f[i];                                                                              \
            P[i] = (T)a[i];                                                                              \
        }                                                                                                \
        free(f);                                                                                         \
        free(a);                                                                                         \
        free(tmp);                                                                                       \
    }                                                                                                    \
                                                                                                         \
    static vDSP_Length window_length##suffix(vDSP_Length N, int flag)                                    \
    {                                                                                                    \
        return (flag & vDSP_HALF_WINDOW) ? (N + 1) / 2 : N;                                              \
    }                                                                                                    \
    void vDSP_hann_window##suffix(T *C, vDSP_Length N, int flag)                                         \
    {                                                                                                    \
        double w = (flag & vDSP_HANN_NORM) ? .816496580927726 : .5;                                      \
        for (vDSP_Length n = 0, length = window_length##suffix(N, flag); n < length; ++n)                \
            C[n] = (T)(w * (1 - cos(2 * M_PI * (double)n / (double)N)));                                 \
    }                                                                                                    \
    void vDSP_hamm_window##suffix(T *C, vDSP_Length N, int flag)                                         \
    {                                                                                                    \
        for (vDSP_Length n = 0, length = window_length##suffix(N, flag); n < length; ++n)                \
            C[n] = (T)(.54 - .46 * cos(2 * M_PI * (double)n / (double)N));                               \
    }                                                                                                    \
    void vDSP_blkman_window##suffix(T *C, vDSP_Length N, int flag)                                       \
    {                                                                                                    \
        for (vDSP_Length n = 0, length = window_length##suffix(N, flag); n < length; ++n) {              \
            double angle = 2 * M_PI * (double)n / (double)N;                                             \
            C[n] = (T)(.42 - .5 * cos(angle) + .08 * cos(2 * angle));                                    \
        }                                                                                                \
    }                                                                                                    \
                                                                                                         \
    void vDSP_mmul##suffix(const T *A, vDSP_Stride IA, const T *B, vDSP_Stride IB, T *C, vDSP_Stride IC, \
                           vDSP_Length M, vDSP_Length N, vDSP_Length P)                                  \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m)                                                              \
            for (vDSP_Length n = 0; n < N; ++n) {                                                        \
                CAST sum = 0;                                                                            \
                for (vDSP_Length p = 0; p < P; ++p)                                                      \
                    sum += (CAST)AT(A, IA, m * P + p) * AT(B, IB, p * N + n);                            \
                AT(C, IC, m * N + n) = (T)sum;                                                           \
            }                                                                                            \
    }                                                                                                    \
    void vDSP_mtrans##suffix(const T *A, vDSP_Stride IA, T *C, vDSP_Stride IC, vDSP_Length M,            \
                             vDSP_Length N)                                                              \
    {                                                                                                    \
        for (vDSP_Length m = 0; m < M; ++m)                                                              \
            for (vDSP_Length n = 0; n < N; ++n)                                                          \
                AT(C, IC, m * N + n) = AT(A, IA, n * M + m);                                             \
    }                                                                                                    \
    void vDSP_mmov##suffix(const T *A, T *C, vDSP_Length M, vDSP_Length N, vDSP_Length TA, vDSP_Length TC) \
    {                                                                                                    \
        for (vDSP_Length n = 0; n < N; ++n)                                                              \
            memmove(C + n * TC, A + n * TA, M * sizeof(T));                                              \
    }

FILTERS(, float, float)
FILTERS(D, double, double)

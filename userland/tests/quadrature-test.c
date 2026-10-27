/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Quadrature: quadrature_integrate with each integrator on smooth, singular, oscillating,
 * discontinuous and infinite-range integrands, run on Apple's Accelerate and Finch's and
 * compared (tools/host-tests.sh). QNG and QAG are QUADPACK's, so their evaluation counts
 * and statuses match exactly; results print to 12 digits. Apple's QAGS is its own
 * adaptive scheme, so only its results and statuses are compared.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdio.h>

static int calls;
#define F(name, expr)                                                                                    \
    static void name(void *arg, size_t n, const double *x, double *y)                                    \
    {                                                                                                    \
        (void)arg;                                                                                       \
        calls += (int)n;                                                                                 \
        for (size_t i = 0; i < n; ++i) {                                                                 \
            double t = x[i];                                                                             \
            y[i] = (expr);                                                                               \
        }                                                                                                \
    }
F(f_exp, exp(t))
F(f_sqrt, 1 / sqrt(t))
F(f_log, log(t) / sqrt(t))
F(f_osc, cos(50 * t) * t)
F(f_gauss, exp(-t * t))
F(f_inv2, 1 / (1 + t * t))
F(f_step, t < 0.3 ? 1 : 2)
F(f_poly, t * t * t - 2 * t)
F(f_scaled, *(const double *)arg * t)

int main(void)
{
    struct {
        const char *name;
        quadrature_function_array f;
        double a, b;
    } cases[] = {{"exp", f_exp, 0, 1},          {"1/sqrt", f_sqrt, 0, 1},       {"log/sqrt", f_log, 0, 1},
                 {"cos 50x", f_osc, 0, 3},      {"gauss", f_gauss, -INFINITY, INFINITY},
                 {"gauss+", f_gauss, 0, INFINITY}, {"1/(1+x^2)", f_inv2, -INFINITY, 2}, {"step", f_step, 0, 1},
                 {"poly reversed", f_poly, 2, -1}};
    const quadrature_integrator its[] = {QUADRATURE_INTEGRATE_QNG, QUADRATURE_INTEGRATE_QAG, QUADRATURE_INTEGRATE_QAGS};
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c)
        for (int k = 0; k < 3; ++k) {
            quadrature_integrate_function fn = {cases[c].f, NULL};
            quadrature_integrate_options o = {its[k], 1e-10, 1e-10, 0, 100};
            quadrature_status st;
            double err;
            calls = 0;
            double r = quadrature_integrate(&fn, cases[c].a, cases[c].b, &o, &st, &err, 0, NULL);
            if (k < 2)
                printf("%s %d: %.12g status %d calls %d\n", cases[c].name, k, r, st, calls);
            else
                printf("%s %d: %.12g status %d\n", cases[c].name, k, r, st);
        }
    quadrature_integrate_function fexp = {f_exp, NULL}, fsqrt = {f_sqrt, NULL};
    const size_t points[] = {15, 21, 31, 41, 51, 61};
    for (int i = 0; i < 6; ++i) {
        quadrature_integrate_options o = {QUADRATURE_INTEGRATE_QAG, 1e-12, 0, points[i], 10};
        quadrature_status st;
        calls = 0;
        double r = quadrature_integrate(&fexp, 0, 5, &o, &st, NULL, 0, NULL);
        printf("QAG %zu points: %.12g status %d calls %d\n", points[i], r, st, calls);
    }
    double scale = 3;
    quadrature_integrate_function fscaled = {f_scaled, &scale};
    quadrature_integrate_options qng = {QUADRATURE_INTEGRATE_QNG, 1e-10, 0, 0, 0};
    quadrature_status st;
    printf("argument: %.12g\n", quadrature_integrate(&fscaled, 0, 2, &qng, &st, NULL, 0, NULL));
    quadrature_integrate_options bad = {QUADRATURE_INTEGRATE_QAG, 1e-10, 0, 17, 10};
    quadrature_integrate(&fexp, 0, 1, &bad, &st, NULL, 0, NULL);
    printf("QAG 17 points: %d\n", st);
    quadrature_integrate_options none = {QUADRATURE_INTEGRATE_QNG, 0, 0, 0, 10};
    quadrature_integrate(&fexp, 0, 1, &none, &st, NULL, 0, NULL);
    printf("no tolerance: %d\n", st);
    quadrature_integrate_options few = {QUADRATURE_INTEGRATE_QAG, 1e-14, 0, 15, 2};
    double r = quadrature_integrate(&fsqrt, 0, 1, &few, &st, NULL, 0, NULL);
    printf("2 intervals: %d %.10g\n", st, r);
    char workspace[3 * QUADRATURE_INTEGRATE_QAG_WORKSPACE_PER_INTERVAL];
    quadrature_integrate_options ws = {QUADRATURE_INTEGRATE_QAG, 1e-14, 0, 15, 1000};
    r = quadrature_integrate(&fsqrt, 0, 1, &ws, &st, NULL, sizeof workspace, workspace);
    printf("workspace of 3 intervals: %d %.10g\n", st, r);
    quadrature_integrate(&fexp, 0, INFINITY, &qng, &st, NULL, 0, NULL);
    printf("QNG to infinity: %d\n", st);
    printf("empty interval: %g\n", quadrature_integrate(&fexp, 2, 2, &qng, &st, NULL, 0, NULL));
    return 0;
}

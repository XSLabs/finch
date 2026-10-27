/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Quadrature (libQuadrature): quadrature_integrate, with QUADPACK's integrators as the
 * header describes them. QNG applies the Gauss-Kronrod-Patterson rules of 21, 43 and 87
 * points until one meets the tolerance. QAG bisects the interval of largest error,
 * integrating each part with a Gauss-Kronrod rule of 15 to 61 points. QAGS does the same
 * with the 21-point rule and accelerates the sequence of results with Wynn's epsilon
 * algorithm; with an infinite bound it integrates over (0, 1] after the substitution
 * x = a + (1 - t) / t (QAGI), with the 15-point rule. The error estimates, roundoff and
 * divergence tests follow QUADPACK (Piessens et al., 1983). The rules are computed by
 * gen-rules.py.
 */
#include <Accelerate/Accelerate.h>
#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "rules.h"

#define EPMACH DBL_EPSILON
#define UFLOW DBL_MIN
#define OFLOW DBL_MAX

/* MARK: - The integrand */

typedef struct {
    const quadrature_integrate_function *f;
    /* QAGI: integrate over (0, 1] the substitution of the infinite interval */
    int inf; /* 0 finite, 1 [bound, inf), -1 (-inf, bound], 2 (-inf, inf) */
    double bound;
} Integrand;

/* f at n points (n <= 128) */
static void eval(const Integrand *g, size_t n, const double *x, double *y)
{
    if (!g->inf) {
        g->f->fun(g->f->fun_arg, n, x, y);
        return;
    }
    /* x = bound + sign (1 - t) / t, dx = dt / t^2; both tails for the whole line */
    double tx[256], ty[256];
    for (size_t i = 0; i < n; ++i) {
        double t = x[i], u = (1 - t) / t;
        tx[i] = g->inf == -1 ? g->bound - u : g->bound + u;
        if (g->inf == 2)
            tx[n + i] = -u;
    }
    g->f->fun(g->f->fun_arg, g->inf == 2 ? 2 * n : n, tx, ty);
    for (size_t i = 0; i < n; ++i) {
        double t = x[i], v = ty[i] + (g->inf == 2 ? ty[n + i] : 0);
        y[i] = v / (t * t);
    }
}

/* MARK: - Gauss-Kronrod rules */

typedef struct {
    int points;          /* 2n + 1 */
    const double *xgk, *wgk, *wg;
} Rule;

static const Rule rules[] = {
    {15, xgk15, wgk15, wg15}, {21, xgk21, wgk21, wg21}, {31, xgk31, wgk31, wg31},
    {41, xgk41, wgk41, wg41}, {51, xgk51, wgk51, wg51}, {61, xgk61, wgk61, wg61},
};

/* QUADPACK's error estimate from the Kronrod-Gauss difference */
static double rescale_error(double err, double resabs, double resasc)
{
    err = fabs(err);
    if (resasc != 0 && err != 0)
        err = resasc * fmin(1.0, pow(200 * err / resasc, 1.5));
    if (resabs > UFLOW / (50 * EPMACH))
        err = fmax(EPMACH * 50 * resabs, err);
    return err;
}

/* the rule over [a, b]: the result, its error, and the integrals of |f| and |f - mean| */
static double qk(const Rule *r, const Integrand *g, double a, double b, double *abserr, double *resabs, double *resasc)
{
    int half = (r->points - 1) / 2, n = half + 1; /* nodes xgk[0..half], the last the centre */
    double centr = 0.5 * (a + b), hlgth = 0.5 * (b - a), dhlgth = fabs(hlgth);
    double x[128], y[128];
    for (int j = 0; j < half; ++j) {
        x[2 * j] = centr - hlgth * r->xgk[j];
        x[2 * j + 1] = centr + hlgth * r->xgk[j];
    }
    x[2 * half] = centr;
    eval(g, (size_t)r->points, x, y);
    double fc = y[2 * half];
    /* the Gauss rule has the centre when its point count (half of half... ) is odd */
    bool gaussCentre = ((r->points - 1) / 2) % 2 == 1;
    double resg = gaussCentre ? fc * r->wg[(half - 1) / 2] : 0;
    double resk = fc * r->wgk[half];
    *resabs = fabs(resk);
    for (int j = 0; j < half; ++j) {
        double s = y[2 * j] + y[2 * j + 1];
        resk += r->wgk[j] * s;
        *resabs += r->wgk[j] * (fabs(y[2 * j]) + fabs(y[2 * j + 1]));
        if (j % 2 == 1)
            resg += r->wg[j / 2] * s;
    }
    double reskh = resk * 0.5;
    *resasc = r->wgk[half] * fabs(fc - reskh);
    for (int j = 0; j < half; ++j)
        *resasc += r->wgk[j] * (fabs(y[2 * j] - reskh) + fabs(y[2 * j + 1] - reskh));
    double result = resk * hlgth;
    *resabs *= dhlgth;
    *resasc *= dhlgth;
    *abserr = rescale_error((resk - resg) * hlgth, *resabs, *resasc);
    (void)n;
    return result;
}

/* MARK: - QNG */

/* the weight of node x in a Patterson rule (non-negative nodes, largest first) */
static double weight_of(const double *xs, const double *ws, int n, double x)
{
    for (int i = 0; i < n; ++i)
        if (fabs(xs[i] - x) < 1e-14)
            return ws[i];
    return 0;
}

/* QUADPACK's qng, its sums in its order: the 10-point Gauss and 21-point Kronrod nodes,
   then each Patterson rule's new nodes, the earlier nodes' values reused */
static double qng(const Integrand *g, double a, double b, double epsabs, double epsrel, double *abserr,
                  quadrature_status *ier)
{
    double hlgth = 0.5 * (b - a), dhlgth = fabs(hlgth), centr = 0.5 * (b + a);
    double x1[5], x2[5], x3[11], x4[22];
    for (int k = 0; k < 5; ++k)
        x1[k] = xp21[2 * k + 1], x2[k] = xp21[2 * k];
    /* the new nodes of the 43- and 87-point rules, largest first */
    int n3 = 0, n4 = 0;
    for (int i = 0; i < 21; ++i) {
        bool old = false;
        for (int j = 0; j < 10; ++j)
            old = old || fabs(xp43[i] - xp21[j]) < 1e-14;
        if (!old && xp43[i] > 0)
            x3[n3++] = xp43[i];
    }
    for (int i = 0; i < 43; ++i) {
        bool old = false;
        for (int j = 0; j < 21; ++j)
            old = old || fabs(xp87[i] - xp43[j]) < 1e-14;
        if (!old && xp87[i] > 0)
            x4[n4++] = xp87[i];
    }
    /* f at the centre and the 21-point rule's nodes */
    double x[44], y[44];
    x[0] = centr;
    for (int k = 0; k < 5; ++k) {
        x[1 + 2 * k] = centr + hlgth * x1[k], x[2 + 2 * k] = centr - hlgth * x1[k];
        x[11 + 2 * k] = centr + hlgth * x2[k], x[12 + 2 * k] = centr - hlgth * x2[k];
    }
    eval(g, 21, x, y);
    double fcentr = y[0], savfun[21], fv1[5], fv2[5], fv3[5], fv4[5];
    double res10 = 0, res21 = weight_of(xp21, wp21, 11, 0) * fcentr, resabs = weight_of(xp21, wp21, 11, 0) * fabs(fcentr);
    for (int k = 0; k < 5; ++k) {
        double fval1 = y[1 + 2 * k], fval2 = y[2 + 2 * k], fval = fval1 + fval2, w = weight_of(xp21, wp21, 11, x1[k]);
        res10 += wg10[k] * fval;
        res21 += w * fval;
        resabs += w * (fabs(fval1) + fabs(fval2));
        savfun[k] = fval, fv1[k] = fval1, fv2[k] = fval2;
    }
    for (int k = 0; k < 5; ++k) {
        double fval1 = y[11 + 2 * k], fval2 = y[12 + 2 * k], fval = fval1 + fval2, w = weight_of(xp21, wp21, 11, x2[k]);
        res21 += w * fval;
        resabs += w * (fabs(fval1) + fabs(fval2));
        savfun[5 + k] = fval, fv3[k] = fval1, fv4[k] = fval2;
    }
    double result = res21 * hlgth, reskh = 0.5 * res21;
    resabs *= dhlgth;
    double resasc = weight_of(xp21, wp21, 11, 0) * fabs(fcentr - reskh);
    for (int k = 0; k < 5; ++k)
        resasc += weight_of(xp21, wp21, 11, x1[k]) * (fabs(fv1[k] - reskh) + fabs(fv2[k] - reskh)) +
                  weight_of(xp21, wp21, 11, x2[k]) * (fabs(fv3[k] - reskh) + fabs(fv4[k] - reskh));
    resasc *= dhlgth;
    double err = fabs((res21 - res10) * hlgth), previous = res21;
    for (int stage = 0; stage < 3; ++stage) {
        if (stage > 0) {
            /* the next Patterson rule */
            const double *xs = stage == 1 ? xp43 : xp87, *ws = stage == 1 ? wp43 : wp87, *xn = stage == 1 ? x3 : x4;
            int nOld = stage == 1 ? 10 : 21, nNew = stage == 1 ? n3 : n4, nx = stage == 1 ? 22 : 44;
            const double *oldNodes[21];
            for (int k = 0; k < 5; ++k)
                oldNodes[k] = &x1[k], oldNodes[5 + k] = &x2[k];
            for (int k = 0; k < n3; ++k)
                oldNodes[10 + k] = &x3[k];
            double res = weight_of(xs, ws, nx, 0) * fcentr;
            for (int k = 0; k < nOld; ++k)
                res += savfun[k] * weight_of(xs, ws, nx, *oldNodes[k]);
            for (int k = 0; k < nNew; ++k) {
                x[2 * k] = xn[k] * hlgth + centr, x[2 * k + 1] = centr - xn[k] * hlgth;
            }
            eval(g, (size_t)(2 * nNew), x, y);
            for (int k = 0; k < nNew; ++k) {
                double fval = y[2 * k] + y[2 * k + 1];
                res += fval * weight_of(xs, ws, nx, xn[k]);
                if (stage == 1)
                    savfun[10 + k] = fval;
            }
            result = res * hlgth;
            err = fabs((res - previous) * hlgth);
            previous = res;
        }
        *abserr = rescale_error(err, resabs, resasc);
        if (*abserr <= fmax(epsabs, epsrel * fabs(result))) {
            *ier = QUADRATURE_SUCCESS;
            return result;
        }
    }
    *ier = QUADRATURE_INTEGRATE_MAX_EVAL_ERROR;
    return result;
}

/* MARK: - Adaptive integration */

typedef struct {
    double a, b, r, e;
    int level;
} Interval;

/* the interval of largest error (QUADPACK keeps them sorted; a scan finds the same one) */
static int largest(const Interval *iv, int n, int maxLevel, bool skipDeep)
{
    int best = -1;
    for (int i = 0; i < n; ++i) {
        if (skipDeep && iv[i].level > maxLevel)
            continue;
        if (best < 0 || iv[i].e > iv[best].e)
            best = i;
    }
    return best;
}

static double qag(const Integrand *g, const Rule *rule, double a, double b, double epsabs, double epsrel, int limit,
                  Interval *iv, double *abserr, quadrature_status *ier)
{
    double resabs, resasc;
    double result = qk(rule, g, a, b, abserr, &resabs, &resasc);
    iv[0] = (Interval){a, b, result, *abserr, 0};
    int n = 1;
    double errbnd = fmax(epsabs, epsrel * fabs(result));
    if (*abserr <= 50 * EPMACH * resabs && *abserr > errbnd) {
        *ier = QUADRATURE_INTEGRATE_BAD_BEHAVIOUR_ERROR;
        return result;
    }
    if (limit == 1 && *abserr > errbnd) {
        *ier = QUADRATURE_INTEGRATE_MAX_EVAL_ERROR;
        return result;
    }
    if ((*abserr <= errbnd && *abserr != resasc) || *abserr == 0) {
        *ier = QUADRATURE_SUCCESS;
        return result;
    }
    double area = result, errsum = *abserr;
    int iroff1 = 0, iroff2 = 0;
    *ier = QUADRATURE_SUCCESS;
    while (n < limit) {
        int i = largest(iv, n, 0, false);
        double a1 = iv[i].a, b2 = iv[i].b, b1 = 0.5 * (a1 + b2), a2 = b1;
        double e1, e2, ra1, rc1, ra2, rc2;
        double r1 = qk(rule, g, a1, b1, &e1, &ra1, &rc1), r2 = qk(rule, g, a2, b2, &e2, &ra2, &rc2);
        double area12 = r1 + r2, erro12 = e1 + e2;
        errsum += erro12 - iv[i].e;
        area += area12 - iv[i].r;
        if (rc1 != e1 && rc2 != e2) {
            if (fabs(iv[i].r - area12) <= 1e-5 * fabs(area12) && erro12 >= 0.99 * iv[i].e)
                ++iroff1;
            if (n > 10 && erro12 > iv[i].e)
                ++iroff2;
        }
        iv[i] = (Interval){a1, b1, r1, e1, iv[i].level + 1};
        iv[n++] = (Interval){a2, b2, r2, e2, iv[i].level};
        errbnd = fmax(epsabs, epsrel * fabs(area));
        if (errsum <= errbnd)
            break;
        if (iroff1 >= 6 || iroff2 >= 20) {
            *ier = QUADRATURE_INTEGRATE_BAD_BEHAVIOUR_ERROR;
            break;
        }
        if (n == limit) {
            *ier = QUADRATURE_INTEGRATE_MAX_EVAL_ERROR;
            break;
        }
        if (fmax(fabs(a1), fabs(b2)) <= (1 + 100 * EPMACH) * (fabs(a2) + 1000 * UFLOW)) {
            *ier = QUADRATURE_INTEGRATE_BAD_BEHAVIOUR_ERROR;
            break;
        }
    }
    result = 0;
    for (int i = 0; i < n; ++i)
        result += iv[i].r;
    *abserr = errsum;
    return result;
}

/* Wynn's epsilon algorithm (QUADPACK's qelg): the extrapolated limit of the sequence of
   results in epstab[0..*n-1] (with room for 52 + 2), and its error */
typedef struct {
    double epstab[52 + 2], res3la[3];
    int nres;
} Epsilon;

static double qelg(Epsilon *s, int *n, double *abserr)
{
    double *epstab = s->epstab, result = epstab[*n - 1];
    ++s->nres;
    *abserr = OFLOW;
    if (*n < 3) {
        *abserr = fmax(*abserr, 5 * EPMACH * fabs(result));
        return result;
    }
    const int limexp = 50;
    epstab[*n + 1] = epstab[*n - 1];
    int newelm = (*n - 1) / 2, num = *n, k1 = *n;
    epstab[*n - 1] = OFLOW;
    for (int i = 1; i <= newelm; ++i) {
        int k2 = k1 - 1, k3 = k1 - 2;
        double res = epstab[k1 + 1], e0 = epstab[k3 - 1], e1 = epstab[k2 - 1], e2 = res;
        double e1abs = fabs(e1), delta2 = e2 - e1, err2 = fabs(delta2), tol2 = fmax(fabs(e2), e1abs) * EPMACH;
        double delta3 = e1 - e0, err3 = fabs(delta3), tol3 = fmax(e1abs, fabs(e0)) * EPMACH;
        if (err2 <= tol2 && err3 <= tol3) {
            /* e0, e1 and e2 are equal to within machine accuracy: convergence */
            result = res;
            *abserr = fmax(err2 + err3, 5 * EPMACH * fabs(result));
            return result;
        }
        double e3 = epstab[k1 - 1];
        epstab[k1 - 1] = e1;
        double delta1 = e1 - e3, err1 = fabs(delta1), tol1 = fmax(e1abs, fabs(e3)) * EPMACH;
        if (err1 <= tol1 || err2 <= tol2 || err3 <= tol3) {
            *n = i + i - 1;
            break;
        }
        double ss = 1 / delta1 + 1 / delta2 - 1 / delta3, epsinf = fabs(ss * e1);
        if (epsinf <= 1e-4) {
            *n = i + i - 1;
            break;
        }
        res = e1 + 1 / ss;
        epstab[k1 - 1] = res;
        k1 -= 2;
        double error = err2 + fabs(res - e2) + err3;
        if (error <= *abserr) {
            *abserr = error;
            result = res;
        }
    }
    if (*n == limexp)
        *n = 2 * (limexp / 2) - 1;
    int ib = num % 2 == 0 ? 2 : 1, ie = newelm + 1;
    for (int i = 1; i <= ie; ++i) {
        epstab[ib - 1] = epstab[ib + 1];
        ib += 2;
    }
    if (num != *n) {
        int indx = num - *n + 1;
        for (int i = 1; i <= *n; ++i) {
            epstab[i - 1] = epstab[indx - 1];
            ++indx;
        }
    }
    if (s->nres < 4) {
        s->res3la[s->nres - 1] = result;
        *abserr = OFLOW;
    } else {
        *abserr = fabs(result - s->res3la[2]) + fabs(result - s->res3la[1]) + fabs(result - s->res3la[0]);
        s->res3la[0] = s->res3la[1];
        s->res3la[1] = s->res3la[2];
        s->res3la[2] = result;
    }
    *abserr = fmax(*abserr, 5 * EPMACH * fabs(result));
    return result;
}

/* QUADPACK's qpsrt: keeps iord (1-based interval numbers) in decreasing order of error,
   down to the depth that can still matter, and returns the next interval to bisect */
static void qpsrt(int limit, int last, int *maxerr, double *ermax, const double *elist, int *iord, int *nrmax)
{
    /* (1-based, as QUADPACK's: elist[i - 1], iord[i - 1]) */
#define E(i) elist[(i) - 1]
#define O(i) iord[(i) - 1]
    if (last <= 2) {
        O(1) = 1;
        O(2) = 2;
    } else {
        double errmax = E(*maxerr);
        if (*nrmax != 1) {
            int ido = *nrmax - 1;
            for (int i = 1; i <= ido; ++i) {
                int isucc = O(*nrmax - 1);
                if (errmax <= E(isucc))
                    break;
                O(*nrmax) = isucc;
                --*nrmax;
            }
        }
        int jupbn = last > limit / 2 + 2 ? limit + 3 - last : last;
        double errmin = E(last);
        int jbnd = jupbn - 1, ibeg = *nrmax + 1, i;
        bool placed = false;
        for (i = ibeg; i <= jbnd; ++i) {
            int isucc = O(i);
            if (errmax >= E(isucc)) {
                placed = true;
                break;
            }
            O(i - 1) = isucc;
        }
        if (!placed) {
            O(jbnd) = *maxerr;
            O(jupbn) = last;
        } else {
            O(i - 1) = *maxerr;
            int k = jbnd;
            bool inserted = false;
            for (int j = i; j <= jbnd; ++j) {
                int isucc = O(k);
                if (errmin < E(isucc)) {
                    O(k + 1) = last;
                    inserted = true;
                    break;
                }
                O(k + 1) = isucc;
                --k;
            }
            if (!inserted)
                O(i) = last;
        }
    }
    *maxerr = O(*nrmax);
    *ermax = E(*maxerr);
#undef E
#undef O
}

/* QAGS (QUADPACK's qagse; and qagie, after the substitution) */
static double qags(const Integrand *g, const Rule *rule, double a, double b, double epsabs, double epsrel, int limit,
                   double *abserr, quadrature_status *status)
{
    double *alist = malloc((size_t)limit * 4 * sizeof(double)), *blist = alist + limit, *rlist = blist + limit,
           *elist = rlist + limit;
    int *iord = malloc((size_t)limit * sizeof(int));
    if (!alist || !iord) {
        free(alist);
        free(iord);
        *status = QUADRATURE_ALLOC_ERROR;
        return 0;
    }
#define A(i) alist[(i) - 1]
#define B(i) blist[(i) - 1]
#define R(i) rlist[(i) - 1]
#define EL(i) elist[(i) - 1]
    int ier = 0, ierro = 0, last = 1;
    double defabs, resabs;
    double result = qk(rule, g, a, b, abserr, &defabs, &resabs);
    A(1) = a, B(1) = b, R(1) = result, EL(1) = *abserr, iord[0] = 1;
    double dres = fabs(result), errbnd = fmax(epsabs, epsrel * dres);
    if (*abserr <= 100 * EPMACH * defabs && *abserr > errbnd)
        ier = 2;
    if (limit == 1)
        ier = 1;
    if (ier || (*abserr <= errbnd && *abserr != resabs) || *abserr == 0)
        goto done;
    Epsilon eps = {{0}, {0}, 0};
    eps.epstab[0] = result;
    double errmax = *abserr, area = result, errsum = *abserr, small = 0, erlarg = 0, ertest = 0, correc = 0;
    int maxerr = 1, nrmax = 1, numrl2 = 2, ktmin = 0, iroff1 = 0, iroff2 = 0, iroff3 = 0;
    bool extrap = false, noext = false;
    *abserr = OFLOW;
    int ksgn = dres >= (1 - 50 * EPMACH) * defabs ? 1 : -1;
    for (last = 2; last <= limit; ++last) {
        double a1 = A(maxerr), b1 = 0.5 * (A(maxerr) + B(maxerr)), a2 = b1, b2 = B(maxerr), erlast = errmax;
        double error1, error2, ra1, defab1, ra2, defab2;
        double area1 = qk(rule, g, a1, b1, &error1, &ra1, &defab1), area2 = qk(rule, g, a2, b2, &error2, &ra2, &defab2);
        double area12 = area1 + area2, erro12 = error1 + error2;
        errsum = errsum + erro12 - errmax;
        area = area + area12 - R(maxerr);
        if (defab1 != error1 && defab2 != error2) {
            if (fabs(R(maxerr) - area12) <= 1e-5 * fabs(area12) && erro12 >= 0.99 * errmax) {
                if (extrap)
                    ++iroff2;
                else
                    ++iroff1;
            }
            if (last > 10 && erro12 > errmax)
                ++iroff3;
        }
        R(maxerr) = area1;
        R(last) = area2;
        errbnd = fmax(epsabs, epsrel * fabs(area));
        if (iroff1 + iroff2 >= 10 || iroff3 >= 20)
            ier = 2;
        if (iroff2 >= 5)
            ierro = 3;
        if (last == limit)
            ier = 1;
        if (fmax(fabs(a1), fabs(b2)) <= (1 + 100 * EPMACH) * (fabs(a2) + 1000 * UFLOW))
            ier = 4;
        if (error2 > error1) {
            A(maxerr) = a2, A(last) = a1, B(last) = b1, R(maxerr) = area2, R(last) = area1, EL(maxerr) = error2,
            EL(last) = error1;
        } else {
            A(last) = a2, B(maxerr) = b1, B(last) = b2, EL(maxerr) = error1, EL(last) = error2;
        }
        qpsrt(limit, last, &maxerr, &errmax, elist, iord, &nrmax);
        if (errsum <= errbnd)
            goto sum;
        if (ier)
            break;
        if (last == 2) {
            small = fabs(b - a) * 0.375;
            erlarg = errsum;
            ertest = errbnd;
            eps.epstab[1] = area;
            continue;
        }
        if (noext)
            continue;
        erlarg -= erlast;
        if (fabs(b1 - a1) > small)
            erlarg += erro12;
        if (!extrap) {
            /* is the interval to bisect next the smallest? */
            if (fabs(B(maxerr) - A(maxerr)) > small)
                continue;
            extrap = true;
            nrmax = 2;
        }
        if (ierro != 3 && erlarg > ertest) {
            /* bisect the larger intervals with large errors first */
            int id = nrmax, jupbnd = last > 2 + limit / 2 ? limit + 3 - last : last;
            bool large = false;
            for (int k = id; k <= jupbnd; ++k) {
                maxerr = iord[nrmax - 1];
                errmax = EL(maxerr);
                if (fabs(B(maxerr) - A(maxerr)) > small) {
                    large = true;
                    break;
                }
                ++nrmax;
            }
            if (large)
                continue;
        }
        /* extrapolate */
        ++numrl2;
        eps.epstab[numrl2 - 1] = area;
        double abseps, reseps = qelg(&eps, &numrl2, &abseps);
        ++ktmin;
        if (ktmin > 5 && *abserr < 1e-3 * errsum)
            ier = 5;
        if (abseps < *abserr) {
            ktmin = 0;
            *abserr = abseps;
            result = reseps;
            correc = erlarg;
            ertest = fmax(epsabs, epsrel * fabs(reseps));
            if (*abserr <= ertest)
                break;
        }
        if (numrl2 == 1)
            noext = true;
        if (ier == 5)
            break;
        maxerr = iord[0];
        errmax = EL(maxerr);
        nrmax = 1;
        extrap = false;
        small *= 0.5;
        erlarg = errsum;
    }
    if (last > limit)
        last = limit;
    /* the result: extrapolated, or the sum */
    if (*abserr == OFLOW)
        goto sum;
    if (ier + ierro != 0) {
        if (ierro == 3)
            *abserr += correc;
        if (ier == 0)
            ier = 3;
        if (result != 0 && area != 0) {
            if (*abserr / fabs(result) > errsum / fabs(area))
                goto sum;
        } else if (*abserr > errsum)
            goto sum;
        else if (area == 0)
            goto done;
    }
    /* divergence */
    if (!(ksgn == -1 && fmax(fabs(result), fabs(area)) <= defabs * 0.01) &&
        (0.01 > result / area || result / area > 100 || errsum > fabs(area)))
        ier = 6;
    goto done;
sum:
    result = 0;
    for (int k = 1; k <= last; ++k)
        result += R(k);
    *abserr = errsum;
done:
    if (ier > 2)
        --ier;
    *status = ier == 0 ? QUADRATURE_SUCCESS : ier == 1 ? QUADRATURE_INTEGRATE_MAX_EVAL_ERROR
                                                       : QUADRATURE_INTEGRATE_BAD_BEHAVIOUR_ERROR;
    free(alist);
    free(iord);
    return result;
#undef A
#undef B
#undef R
#undef EL
}

/* MARK: - Entry point */

double quadrature_integrate(const quadrature_integrate_function *f, double a, double b,
                            const quadrature_integrate_options *options, quadrature_status *status, double *abs_error,
                            size_t workspace_size, void *workspace)
{
    quadrature_status st = QUADRATURE_SUCCESS, *ier = status ? status : &st;
    double err = 0, *abserr = abs_error ? abs_error : &err, result = 0;
    *abserr = 0;
    if (!f || !f->fun || !options || isnan(a) || isnan(b) ||
        (options->abs_tolerance <= 0 && options->rel_tolerance < fmax(50 * EPMACH, 0.5e-28))) {
        *ier = QUADRATURE_INVALID_ARG_ERROR;
        return 0;
    }
    if (a == b) {
        *ier = QUADRATURE_SUCCESS;
        return 0;
    }
    bool infinite = isinf(a) || isinf(b);
    Integrand g = {f, 0, 0};
    int limit = options->max_intervals ? (int)options->max_intervals : 50;
    size_t per = options->integrator == QUADRATURE_INTEGRATE_QAGS ? QUADRATURE_INTEGRATE_QAGS_WORKSPACE_PER_INTERVAL
                                                                 : QUADRATURE_INTEGRATE_QAG_WORKSPACE_PER_INTERVAL;
    if (workspace)
        limit = (int)(workspace_size / per);
    switch (options->integrator) {
    case QUADRATURE_INTEGRATE_QNG:
        if (infinite) {
            *ier = QUADRATURE_INVALID_ARG_ERROR;
            return 0;
        }
        return qng(&g, a, b, options->abs_tolerance, options->rel_tolerance, abserr, ier);
    case QUADRATURE_INTEGRATE_QAG:
    case QUADRATURE_INTEGRATE_QAGS: {
        if (limit < 1) {
            *ier = QUADRATURE_INVALID_ARG_ERROR;
            return 0;
        }
        const Rule *rule = &rules[1];
        if (options->integrator == QUADRATURE_INTEGRATE_QAG) {
            size_t p = options->qag_points_per_interval ? options->qag_points_per_interval : 21;
            rule = NULL;
            for (size_t i = 0; i < sizeof(rules) / sizeof(rules[0]); ++i)
                if ((size_t)rules[i].points == p)
                    rule = &rules[i];
            if (!rule) {
                *ier = QUADRATURE_INVALID_ARG_ERROR;
                return 0;
            }
        }
        Interval *iv = malloc((size_t)limit * sizeof(Interval));
        if (!iv) {
            *ier = QUADRATURE_ALLOC_ERROR;
            return 0;
        }
        double sign = 1, lo = a, hi = b;
        /* (QAG takes infinite bounds as they are, as Apple's does, and finds no finite result) */
        if (infinite && options->integrator == QUADRATURE_INTEGRATE_QAGS) {
            /* QAGI: over (0, 1] after the substitution, with the 15-point rule */
            if (a > b) {
                double t = lo;
                lo = hi, hi = t, sign = -1;
            }
            if (isinf(lo) && isinf(hi))
                g.inf = 2, g.bound = 0;
            else if (isinf(hi))
                g.inf = 1, g.bound = lo;
            else
                g.inf = -1, g.bound = hi;
            rule = &rules[0];
            lo = 0, hi = 1;
        }
        result = options->integrator == QUADRATURE_INTEGRATE_QAG
                     ? qag(&g, rule, lo, hi, options->abs_tolerance, options->rel_tolerance, limit, iv, abserr, ier)
                     : qags(&g, rule, lo, hi, options->abs_tolerance, options->rel_tolerance, limit, abserr, ier);
        free(iv);
        return sign * result;
    }
    default:
        *ier = QUADRATURE_INVALID_ARG_ERROR;
        return 0;
    }
}

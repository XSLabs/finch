/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * BLAS levels 1-3 in all four precisions, through CBLAS in both storage orders with
 * every transpose, triangle, side and diagonal, through the Fortran interface, and
 * through the legacy and ILP64 ABIs. Built against the SDK; run on Apple's Accelerate
 * and on Finch's and diffed (tools/host-tests.sh). Values are printed to five
 * significant digits
 * (single precision to four).
 */
#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>
#include <complex.h>
#include <stdio.h>
#include <string.h>

/* the legacy and ILP64 ABIs, declared by hand (the headers pick one per translation unit) */
extern double legacy_sdot(const int *, const float *, const int *, const float *, const int *) __asm("_sdot_");
extern double legacy_snrm2(const int *, const float *, const int *) __asm("_snrm2");
extern int legacy_isamax(const int *, const float *, const int *) __asm("_ISAMAX");
extern void legacy_cblas_dgemv(int, int, int, int, double, const double *, int, const double *, int, double,
                               double *, int) __asm("_cblas_dgemv");
extern void ilp64_dgemm(const char *, const char *, const long *, const long *, const long *, const double *,
                        const double *, const long *, const double *, const long *, const double *, double *,
                        const long *) __asm("_dgemm$NEWLAPACK$ILP64");
extern long ilp64_cblas_idamax(long, const double *, long) __asm("_cblas_idamax$NEWLAPACK$ILP64");

#define NN 4

static double clean(double v) { return (v < 5e-5 && v > -5e-5) ? 0 : v; }

static void showd(const char *label, const double *v, int n)
{
    printf("%s:", label);
    for (int i = 0; i < n; ++i)
        printf(" %.5g", clean(v[i]));
    printf("\n");
}

static void shows(const char *label, const float *v, int n)
{
    printf("%s:", label);
    for (int i = 0; i < n; ++i)
        printf(" %.4g", clean(v[i]));
    printf("\n");
}

/* inputs: A general 4x4 (also used as band, packed and triangular storage), x, y vectors */
static double Ad[32], Bd[32], Cd[32], xd[8], yd[8];
static float As[32], Bs[32], Cs[32], xs[8], ys[8];
static __LAPACK_float_complex Ac[32], Bc[32], Cc[32], xc[8], yc[8];
static __LAPACK_double_complex Az[32], Bz[32], Cz[32], xz[8], yz[8];

static void reset(void)
{
    for (int i = 0; i < 32; ++i) {
        double a = ((i * 7) % 11) - 4.5 + (i % 3) * 0.25, b = ((i * 5) % 9) * 0.5 - 1.75;
        Ad[i] = a;
        Bd[i] = b;
        Cd[i] = (i % 5) - 2;
        As[i] = (float)a;
        Bs[i] = (float)b;
        Cs[i] = (float)Cd[i];
        Ac[i] = (float)a + (float)b * I;
        Bc[i] = (float)b - 0.5f * I;
        Cc[i] = (float)Cd[i] + 1.0f * I;
        Az[i] = a + b * I;
        Bz[i] = b - 0.5 * I;
        Cz[i] = Cd[i] + 1.0 * I;
    }
    for (int i = 0; i < 8; ++i) {
        xd[i] = 1.5 - i * 0.75;
        yd[i] = (i % 3) - 0.5;
        xs[i] = (float)xd[i];
        ys[i] = (float)yd[i];
        xc[i] = (float)xd[i] + (float)yd[i] * I;
        yc[i] = (float)yd[i] - 0.25f * I;
        xz[i] = xd[i] + yd[i] * I;
        yz[i] = yd[i] - 0.25 * I;
    }
}

static const enum CBLAS_ORDER orders[2] = {CblasRowMajor, CblasColMajor};
static const enum CBLAS_TRANSPOSE transes[3] = {CblasNoTrans, CblasTrans, CblasConjTrans};
static const enum CBLAS_UPLO uplos[2] = {CblasUpper, CblasLower};
static const enum CBLAS_DIAG diags[2] = {CblasNonUnit, CblasUnit};
static const enum CBLAS_SIDE sides[2] = {CblasLeft, CblasRight};

static char label[128];

#define L(...) (snprintf(label, sizeof(label), __VA_ARGS__), label)

static void level1(void)
{
    reset();
    printf("iamax: %d %d %d %d\n", cblas_isamax(8, xs, 1), cblas_idamax(4, xd, 2), cblas_icamax(8, xc, 1),
           cblas_izamax(8, xz, 1));
    printf("asum: %.5g %.5g %.5g %.5g\n", cblas_sasum(8, xs, 1), cblas_dasum(8, xd, 1), cblas_scasum(8, xc, 1),
           cblas_dzasum(4, xz, 2));
    printf("nrm2: %.5g %.5g %.5g %.5g\n", cblas_snrm2(8, xs, 1), cblas_dnrm2(8, xd, 1), cblas_scnrm2(8, xc, 1),
           cblas_dznrm2(8, xz, 1));
    printf("dot: %.5g %.5g %.5g %.5g\n", cblas_sdot(8, xs, 1, ys, -1), cblas_ddot(4, xd, 2, yd, 1),
           cblas_sdsdot(8, 0.5f, xs, 1, ys, 1), cblas_dsdot(8, xs, 1, ys, 1));
    __LAPACK_float_complex dc;
    __LAPACK_double_complex dz;
    cblas_cdotu_sub(8, xc, 1, yc, 1, &dc);
    cblas_zdotc_sub(8, xz, 1, yz, -1, &dz);
    printf("dotu/dotc: %.5g %.5g %.5g %.5g\n", crealf(dc), cimagf(dc), creal(dz), cimag(dz));
    cblas_cdotc_sub(8, xc, 1, yc, 1, &dc);
    cblas_zdotu_sub(8, xz, 1, yz, 1, &dz);
    printf("dotc/dotu: %.5g %.5g %.5g %.5g\n", crealf(dc), cimagf(dc), creal(dz), cimag(dz));
    cblas_daxpy(8, 2.5, xd, 1, yd, -1);
    showd("daxpy", yd, 8);
    __LAPACK_float_complex ca = 0.5f - 1.5f * I, cb = 2 + I;
    cblas_caxpy(4, &ca, xc, 2, yc, 1);
    shows("caxpy", (float *)yc, 8);
    catlas_daxpby(8, 0.5, xd, 1, -2, yd, 1);
    showd("daxpby", yd, 8);
    catlas_caxpby(8, &ca, xc, 1, &cb, yc, 1);
    shows("caxpby", (float *)yc, 16);
    catlas_sset(4, 3.5f, ys, 2);
    shows("sset", ys, 8);
    cblas_dscal(4, -1.5, xd, 2);
    showd("dscal", xd, 8);
    cblas_zdscal(8, 0.5, xz, 1);
    showd("zdscal", (double *)xz, 16);
    cblas_cscal(8, &ca, xc, 1);
    shows("cscal", (float *)xc, 16);
    cblas_dswap(4, xd, 1, yd, -2);
    showd("dswap", xd, 8);
    cblas_scopy(4, xs, -1, ys, 2);
    shows("scopy", ys, 8);
    reset();
    cblas_drot(8, xd, 1, yd, 1, 0.6, 0.8);
    showd("drot.x", xd, 8);
    showd("drot.y", yd, 8);
    cblas_csrot(8, xc, 1, yc, 1, 0.6f, -0.8f);
    shows("csrot", (float *)xc, 16);
    double a = 3, b = -4, c, s;
    cblas_drotg(&a, &b, &c, &s);
    printf("drotg: %.5g %.5g %.5g %.5g\n", a, b, c, s);
    float fa = 0.5f, fb = 2, fc, fs;
    cblas_srotg(&fa, &fb, &fc, &fs);
    printf("srotg: %.5g %.5g %.5g %.5g\n", fa, fb, fc, fs);
    __LAPACK_double_complex za = 3 + 4 * I, zb = 1 - 2 * I, zs;
    double zc;
    cblas_zrotg(&za, &zb, &zc, &zs);
    printf("zrotg: %.5g %.5g %.5g %.5g %.5g\n", creal(za), cimag(za), zc, creal(zs), cimag(zs));
    for (int f = -1; f <= 1; ++f) {
        double param[5] = {f, 0.5, -0.25, 0.75, 1.5};
        reset();
        cblas_drotm(8, xd, 1, yd, -1, param);
        showd(L("drotm %d", f), xd, 8);
    }
    double d1 = 2, d2 = 3, b1 = 1.5, param[5] = {0};
    cblas_drotmg(&d1, &d2, &b1, 0.75, param);
    printf("drotmg: %.5g %.5g %.5g | %.5g %.5g %.5g %.5g %.5g\n", d1, d2, b1, param[0], param[1], param[2],
           param[3], param[4]);
    d1 = 1e-9;
    d2 = 5;
    b1 = 2;
    cblas_drotmg(&d1, &d2, &b1, 3, param);
    printf("drotmg2: %.5g %.5g %.5g | %.5g %.5g %.5g %.5g %.5g\n", d1, d2, b1, param[0], param[1], param[2],
           param[3], param[4]);
}

static void level2(void)
{
    for (int o = 0; o < 2; ++o)
        for (int t = 0; t < 3; ++t) {
            reset();
            cblas_dgemv(orders[o], transes[t], 3, 4, 1.5, Ad, 4, xd, 1, -0.5, yd, 2);
            showd(L("dgemv %d %d", o, t), yd, 8);
            __LAPACK_float_complex al = 1 - I, be = 0.5f;
            cblas_cgemv(orders[o], transes[t], 3, 4, &al, Ac, 5, xc, -1, &be, yc, 1);
            shows(L("cgemv %d %d", o, t), (float *)yc, 8);
            reset();
            cblas_sgbmv(orders[o], transes[t], 4, 4, 1, 2, 2, As, 4, xs, 1, 0, ys, 1);
            shows(L("sgbmv %d %d", o, t), ys, 4);
            __LAPACK_double_complex zal = 2 + I, zbe = 0;
            cblas_zgbmv(orders[o], transes[t], 4, 3, 2, 1, &zal, Az, 4, xz, 1, &zbe, yz, 1);
            showd(L("zgbmv %d %d", o, t), (double *)yz, 8);
        }
    for (int o = 0; o < 2; ++o)
        for (int u = 0; u < 2; ++u) {
            reset();
            cblas_dsymv(orders[o], uplos[u], 4, 2, Ad, 4, xd, 1, 1, yd, 1);
            showd(L("dsymv %d %d", o, u), yd, 4);
            __LAPACK_float_complex al = 0.5f + I, be = 1;
            cblas_chemv(orders[o], uplos[u], 4, &al, Ac, 4, xc, 1, &be, yc, 1);
            shows(L("chemv %d %d", o, u), (float *)yc, 8);
            reset();
            cblas_ssbmv(orders[o], uplos[u], 4, 1, 1, As, 3, xs, 1, 0, ys, 1);
            shows(L("ssbmv %d %d", o, u), ys, 4);
            __LAPACK_double_complex zal = 1, zbe = 0;
            cblas_zhbmv(orders[o], uplos[u], 4, 2, &zal, Az, 3, xz, 1, &zbe, yz, 1);
            showd(L("zhbmv %d %d", o, u), (double *)yz, 8);
            reset();
            cblas_dspmv(orders[o], uplos[u], 4, -1, Ad, xd, 1, 0.5, yd, 1);
            showd(L("dspmv %d %d", o, u), yd, 4);
            cblas_chpmv(orders[o], uplos[u], 4, &al, Ac, xc, 1, &be, yc, 1);
            shows(L("chpmv %d %d", o, u), (float *)yc, 8);
            for (int t = 0; t < 3; ++t)
                for (int d = 0; d < 2; ++d) {
                    reset();
                    cblas_dtrmv(orders[o], uplos[u], transes[t], diags[d], 4, Ad, 4, xd, 1);
                    showd(L("dtrmv %d %d %d %d", o, u, t, d), xd, 4);
                    cblas_ztrmv(orders[o], uplos[u], transes[t], diags[d], 4, Az, 4, xz, 1);
                    showd(L("ztrmv %d %d %d %d", o, u, t, d), (double *)xz, 8);
                    reset();
                    cblas_stbmv(orders[o], uplos[u], transes[t], diags[d], 4, 1, As, 2, xs, 1);
                    shows(L("stbmv %d %d %d %d", o, u, t, d), xs, 4);
                    cblas_ctpmv(orders[o], uplos[u], transes[t], diags[d], 4, Ac, xc, 1);
                    shows(L("ctpmv %d %d %d %d", o, u, t, d), (float *)xc, 8);
                    reset();
                    for (int i = 0; i < 4; ++i) {
                        Ad[i * 5] += 6;
                        Az[i * 5] += 6;
                        As[i * 5] += 6;
                        Ac[i * 5] += 6;
                    }
                    cblas_dtrsv(orders[o], uplos[u], transes[t], diags[d], 4, Ad, 4, xd, -1);
                    showd(L("dtrsv %d %d %d %d", o, u, t, d), xd, 4);
                    cblas_ztrsv(orders[o], uplos[u], transes[t], diags[d], 4, Az, 4, xz, 1);
                    showd(L("ztrsv %d %d %d %d", o, u, t, d), (double *)xz, 8);
                    cblas_stbsv(orders[o], uplos[u], transes[t], diags[d], 4, 1, As, 2, xs, 1);
                    shows(L("stbsv %d %d %d %d", o, u, t, d), xs, 4);
                    reset();
                    for (int i = 0; i < 10; ++i)
                        Ac[i] += 4;
                    cblas_ctpsv(orders[o], uplos[u], transes[t], diags[d], 4, Ac, xc, 1);
                    shows(L("ctpsv %d %d %d %d", o, u, t, d), (float *)xc, 8);
                }
            reset();
            cblas_dsyr(orders[o], uplos[u], 4, 1.5, xd, 1, Ad, 4);
            showd(L("dsyr %d %d", o, u), Ad, 16);
            cblas_cher(orders[o], uplos[u], 4, 0.5f, xc, 1, Ac, 4);
            shows(L("cher %d %d", o, u), (float *)Ac, 32);
            reset();
            cblas_ssyr2(orders[o], uplos[u], 4, -1, xs, 1, ys, 2, As, 4);
            shows(L("ssyr2 %d %d", o, u), As, 16);
            zal = 1 - 2 * I;
            cblas_zher2(orders[o], uplos[u], 4, &zal, xz, 1, yz, 1, Az, 4);
            showd(L("zher2 %d %d", o, u), (double *)Az, 32);
            reset();
            cblas_dspr(orders[o], uplos[u], 4, 2, xd, 1, Ad);
            showd(L("dspr %d %d", o, u), Ad, 10);
            cblas_zhpr(orders[o], uplos[u], 4, 2, xz, 1, Az);
            showd(L("zhpr %d %d", o, u), (double *)Az, 20);
            reset();
            cblas_sspr2(orders[o], uplos[u], 4, 2, xs, 1, ys, 1, As);
            shows(L("sspr2 %d %d", o, u), As, 10);
            al = 2 + I;
            cblas_chpr2(orders[o], uplos[u], 4, &al, xc, 1, yc, 1, Ac);
            shows(L("chpr2 %d %d", o, u), (float *)Ac, 20);
        }
    for (int o = 0; o < 2; ++o) {
        reset();
        cblas_dger(orders[o], 3, 4, 2, xd, 1, yd, 1, Ad, 4);
        showd(L("dger %d", o), Ad, 16);
        __LAPACK_float_complex al = 1 + I;
        cblas_cgeru(orders[o], 3, 4, &al, xc, 1, yc, 1, Ac, 4);
        shows(L("cgeru %d", o), (float *)Ac, 32);
        reset();
        cblas_cgerc(orders[o], 3, 4, &al, xc, 1, yc, -1, Ac, 4);
        shows(L("cgerc %d", o), (float *)Ac, 32);
    }
}

static void level3(void)
{
    for (int o = 0; o < 2; ++o)
        for (int ta = 0; ta < 3; ++ta)
            for (int tb = 0; tb < 3; ++tb) {
                reset();
                cblas_dgemm(orders[o], transes[ta], transes[tb], 3, 2, 4, 1.5, Ad, 4, Bd, 4, -1, Cd, 4);
                showd(L("dgemm %d %d %d", o, ta, tb), Cd, 12);
                __LAPACK_double_complex al = 1 - I, be = 0.5 * I;
                cblas_zgemm(orders[o], transes[ta], transes[tb], 2, 3, 4, &al, Az, 4, Bz, 5, &be, Cz, 4);
                showd(L("zgemm %d %d %d", o, ta, tb), (double *)Cz, 24);
            }
    for (int o = 0; o < 2; ++o)
        for (int s = 0; s < 2; ++s)
            for (int u = 0; u < 2; ++u) {
                reset();
                cblas_ssymm(orders[o], sides[s], uplos[u], 3, 4, 2, As, 4, Bs, 4, 0.5f, Cs, 4);
                shows(L("ssymm %d %d %d", o, s, u), Cs, 16);
                __LAPACK_float_complex al = 1 + 0.5f * I, be = 0;
                cblas_chemm(orders[o], sides[s], uplos[u], 3, 4, &al, Ac, 4, Bc, 4, &be, Cc, 4);
                shows(L("chemm %d %d %d", o, s, u), (float *)Cc, 32);
                reset();
                cblas_zsymm(orders[o], sides[s], uplos[u], 4, 3, (__LAPACK_double_complex[]){2}, Az, 4, Bz, 4,
                            (__LAPACK_double_complex[]){1}, Cz, 4);
                showd(L("zsymm %d %d %d", o, s, u), (double *)Cz, 32);
                for (int t = 0; t < 3; ++t)
                    for (int d = 0; d < 2; ++d) {
                        reset();
                        cblas_dtrmm(orders[o], sides[s], uplos[u], transes[t], diags[d], 3, 4, 2, Ad, 4, Bd, 4);
                        showd(L("dtrmm %d %d %d %d %d", o, s, u, t, d), Bd, 16);
                        __LAPACK_float_complex al = 1 - I;
                        cblas_ctrmm(orders[o], sides[s], uplos[u], transes[t], diags[d], 4, 3, &al, Ac, 4, Bc, 4);
                        shows(L("ctrmm %d %d %d %d %d", o, s, u, t, d), (float *)Bc, 32);
                        reset();
                        for (int i = 0; i < 4; ++i) {
                            Ad[i * 5] += 8;
                            Az[i * 5] += 8;
                        }
                        cblas_dtrsm(orders[o], sides[s], uplos[u], transes[t], diags[d], 4, 3, 1.5, Ad, 4, Bd, 4);
                        showd(L("dtrsm %d %d %d %d %d", o, s, u, t, d), Bd, 16);
                        __LAPACK_double_complex zal = 0.5 + I;
                        cblas_ztrsm(orders[o], sides[s], uplos[u], transes[t], diags[d], 3, 4, &zal, Az, 4, Bz, 4);
                        showd(L("ztrsm %d %d %d %d %d", o, s, u, t, d), (double *)Bz, 32);
                    }
            }
    for (int o = 0; o < 2; ++o)
        for (int u = 0; u < 2; ++u)
            for (int t = 0; t < 2; ++t) {
                reset();
                cblas_dsyrk(orders[o], uplos[u], transes[t], 4, 3, 1.5, Ad, 4, -1, Cd, 4);
                showd(L("dsyrk %d %d %d", o, u, t), Cd, 16);
                cblas_cherk(orders[o], uplos[u], t ? CblasConjTrans : CblasNoTrans, 4, 3, 0.5f, Ac, 4, 2, Cc, 4);
                shows(L("cherk %d %d %d", o, u, t), (float *)Cc, 32);
                reset();
                cblas_ssyr2k(orders[o], uplos[u], transes[t], 4, 3, 1, As, 4, Bs, 4, 0.5f, Cs, 4);
                shows(L("ssyr2k %d %d %d", o, u, t), Cs, 16);
                __LAPACK_double_complex al = 1 + 2 * I;
                cblas_zher2k(orders[o], uplos[u], t ? CblasConjTrans : CblasNoTrans, 4, 3, &al, Az, 4, Bz, 4, 0.5,
                             Cz, 4);
                showd(L("zher2k %d %d %d", o, u, t), (double *)Cz, 32);
                reset();
                cblas_csyrk(orders[o], uplos[u], transes[t], 4, 3, (__LAPACK_float_complex[]){1 + I}, Ac, 4,
                            (__LAPACK_float_complex[]){1}, Cc, 4);
                shows(L("csyrk %d %d %d", o, u, t), (float *)Cc, 32);
                cblas_zsyr2k(orders[o], uplos[u], transes[t], 4, 3, (__LAPACK_double_complex[]){2}, Az, 4, Bz, 4,
                             (__LAPACK_double_complex[]){0}, Cz, 4);
                showd(L("zsyr2k %d %d %d", o, u, t), (double *)Cz, 32);
            }
    reset();
    appleblas_dgeadd(CblasRowMajor, CblasTrans, CblasNoTrans, 3, 3, 2, Ad, 4, -1, Bd, 4, Cd, 4);
    showd("dgeadd", Cd, 12);
}

static void fortran(void)
{
    reset();
    __LAPACK_int n = 8, one = 1, m = 3, k = 4, four = 4;
    printf("sdot_: %.5g\n", sdot_(&n, xs, &one, ys, &one));
    int ni = 8, onei = 1;
    printf("legacy: %.5g %.5g %d\n", legacy_sdot(&ni, xs, &onei, ys, &onei), legacy_snrm2(&ni, xs, &onei),
           legacy_isamax(&ni, xs, &onei));
    double alpha = 2, beta = 0.5;
    dgemm_("T", "N", &m, &m, &k, &alpha, Ad, &four, Bd, &four, &beta, Cd, &four);
    showd("dgemm_", Cd, 12);
    reset();
    long lm = 3, lk = 4, l4 = 4;
    ilp64_dgemm("N", "C", &lm, &lm, &lk, &alpha, Ad, &l4, Bd, &l4, &beta, Cd, &l4);
    showd("dgemm ilp64", Cd, 12);
    printf("idamax ilp64: %ld\n", ilp64_cblas_idamax(8, xd, 1));
    reset();
    legacy_cblas_dgemv(CblasColMajor, CblasNoTrans, 4, 4, 1, Ad, 4, xd, 1, 0, yd, 1);
    showd("legacy cblas_dgemv", yd, 4);
    __LAPACK_double_complex ret;
    zdotc_(&ret, &n, xz, &one, yz, &one);
    printf("zdotc_: %.5g %.5g\n", creal(ret), cimag(ret));
    char uplo = 'L';
    float salpha = 1.5f;
    ssyr_(&uplo, &four, &salpha, xs, &one, As, &four);
    shows("ssyr_", As, 16);
}

int main(void)
{
    level1();
    level2();
    level3();
    fortran();
    return 0;
}

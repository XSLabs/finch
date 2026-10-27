/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vecLib's libvMisc: vForce, vfp, vBasicOps, vBigNum and vectorOps. Built against the
 * SDK; run on Apple's Accelerate and on Finch's and diffed (tools/host-tests.sh).
 * Floating-point values are printed to five significant digits.
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdio.h>

#define N 8

static const float X[N] = {0.25f, -0.5f, 0.75f, 1.5f, -2.25f, 3.0f, 0.1f, -0.9f};
static const float Y[N] = {2.0f, 1.5f, -0.5f, 0.25f, 3.0f, -1.25f, 0.5f, 2.5f};
static const float P[N] = {0.25f, 0.5f, 0.75f, 1.5f, 2.25f, 3.0f, 0.1f, 4.0f};

static void show(const char *label, const float *v, int n)
{
    printf("%s:", label);
    for (int i = 0; i < n; ++i)
        printf(" %.5g", v[i]);
    printf("\n");
}

static void showd(const char *label, const double *v, int n)
{
    printf("%s:", label);
    for (int i = 0; i < n; ++i)
        printf(" %.5g", v[i]);
    printf("\n");
}

#define UN(FN, IN)                                                                                        \
    do {                                                                                                 \
        float out[N];                                                                                    \
        double ind[N], outd[N];                                                                          \
        int n = N;                                                                                       \
        for (int i = 0; i < N; ++i)                                                                      \
            ind[i] = IN[i];                                                                              \
        FN##f(out, IN, &n);                                                                               \
        show(#FN "f", out, N);                                                                            \
        FN(outd, ind, &n);                                                                                \
        showd(#FN, outd, N);                                                                              \
    } while (0)
#define BI(FN, A, B)                                                                                      \
    do {                                                                                                 \
        float out[N];                                                                                    \
        double ad[N], bd[N], outd[N];                                                                    \
        int n = N;                                                                                       \
        for (int i = 0; i < N; ++i) {                                                                    \
            ad[i] = A[i];                                                                                \
            bd[i] = B[i];                                                                                \
        }                                                                                                \
        FN##f(out, A, B, &n);                                                                             \
        show(#FN "f", out, N);                                                                            \
        FN(outd, ad, bd, &n);                                                                             \
        showd(#FN, outd, N);                                                                              \
    } while (0)

static void vforce(void)
{
    UN(vvrec, X);
    UN(vvsqrt, P);
    UN(vvcbrt, X);
    UN(vvrsqrt, P);
    UN(vvexp, X);
    UN(vvexp2, X);
    UN(vvexpm1, X);
    UN(vvlog, P);
    UN(vvlog10, P);
    UN(vvlog1p, P);
    UN(vvlog2, P);
    UN(vvlogb, X);
    UN(vvfabs, X);
    UN(vvsin, X);
    UN(vvcos, X);
    UN(vvtan, X);
    UN(vvasin, X);
    UN(vvacos, X);
    UN(vvatan, X);
    UN(vvsinh, X);
    UN(vvcosh, X);
    UN(vvtanh, X);
    UN(vvasinh, X);
    UN(vvacosh, P);
    UN(vvatanh, X);
    UN(vvint, X);
    UN(vvnint, X);
    UN(vvceil, X);
    UN(vvfloor, X);
    UN(vvsinpi, X);
    UN(vvcospi, X);
    UN(vvtanpi, X);
    BI(vvdiv, X, Y);
    BI(vvpow, Y, P);
    BI(vvatan2, X, Y);
    BI(vvfmod, X, Y);
    BI(vvremainder, X, Y);
    BI(vvcopysign, X, Y);
    BI(vvnextafter, X, Y);
    float out[N], cosines[N], e = 2;
    int n = N;
    vvpowsf(out, &e, P, &n);
    show("vvpowsf", out, N);
    vvsincosf(out, cosines, X, &n);
    show("vvsincosf.sin", out, N);
    show("vvsincosf.cos", cosines, N);
    __float_complex_t c[N];
    vvcosisinf(c, X, &n);
    show("vvcosisinf", (const float *)c, 2 * N);
}

static void vfp(void)
{
    vFloat x = {0.25f, -1.5f, 2.5f, -3.75f}, y = {2, 0.5f, -1, 3};
    vFloat r;
#define V1(f)                                                                                            \
    r = f(x);                                                                                            \
    printf("%s: %.5g %.5g %.5g %.5g\n", #f, r[0], r[1], r[2], r[3]);
#define V2(f)                                                                                            \
    r = f(x, y);                                                                                         \
    printf("%s: %.5g %.5g %.5g %.5g\n", #f, r[0], r[1], r[2], r[3]);
    V1(vceilf) V1(vfloorf) V1(vtruncf) V1(vnintf) V1(vexpf) V1(vexp2f) V1(vexpm1f) V1(vlogbf) V1(vsinf) V1(vcosf)
    V1(vtanf) V1(vsinpif) V1(vcospif) V1(vtanpif) V1(vatanf) V1(vsinhf) V1(vcoshf) V1(vtanhf) V1(vasinhf)
    V1(vrecf) V1(vfabsf) V2(vatan2f) V2(vpowf) V2(vdivf) V2(vfmodf) V2(vremainderf) V2(vcopysignf)
    V2(vnextafterf)
    vFloat p = vfabsf(x);
    r = vsqrtf(p);
    printf("vsqrtf: %.5g %.5g %.5g %.5g\n", r[0], r[1], r[2], r[3]);
    r = vlogf(p);
    printf("vlogf: %.5g %.5g %.5g %.5g\n", r[0], r[1], r[2], r[3]);
    r = vscalbf(x, (vSInt32){1, -2, 3, 0});
    printf("vscalbf: %.5g %.5g %.5g %.5g\n", r[0], r[1], r[2], r[3]);
    r = vipowf(x, (vSInt32){2, 3, -1, 0});
    printf("vipowf: %.5g %.5g %.5g %.5g\n", r[0], r[1], r[2], r[3]);
    vFloat cosine;
    r = vsincosf(x, &cosine);
    printf("vsincosf: %.5g %.5g | %.5g %.5g\n", r[0], r[1], cosine[0], cosine[1]);
    vUInt32 q;
    r = vremquof((vFloat){7, -7, 9.5f, 1}, (vFloat){2, 2, -3, 4}, &q);
    printf("vremquof: %.5g %.5g %.5g %.5g | %d %d %d %d\n", r[0], r[1], r[2], r[3], (int)q[0] & 7, (int)q[1] & 7,
           (int)q[2] & 7, (int)q[3] & 7);
    vUInt32 s = vsignbitf((vFloat){-0.0f, 1, -2, 0});
    printf("vsignbitf: %d %d %d %d\n", s[0] != 0, s[1] != 0, s[2] != 0, s[3] != 0);
}

static void showq(const char *label, vUInt32 v) { printf("%s: %08x %08x %08x %08x\n", label, v[0], v[1], v[2], v[3]); }

static void basicops(void)
{
    vUInt32 a = {0x89abcdef, 0x01234567, 0xfedcba98, 0x76543210}, b = {3, 0, 5, 0}, r;
    vUInt32 m = {0xffffffff, 0x7fffffff, 1, 0}, one = {1, 0, 1, 0};
    showq("vU64Add", vU64Add(a, a));
    showq("vU64AddS", vU64AddS(a, (vUInt32){0xffffffff, 0xffffffff, 0, 0}));
    showq("vS64AddS", (vUInt32)vS64AddS((vSInt32)m, (vSInt32)one));
    showq("vU64Sub", vU64Sub(b, a));
    showq("vU64SubS", vU64SubS((vUInt32){1, 0, 5, 0}, (vUInt32){2, 0, 1, 0}));
    showq("vS64SubS", (vUInt32)vS64SubS((vSInt32){0, 0x80000000, 5, 0}, (vSInt32){1, 0, 1, 0}));
    showq("vU128Add", vU128Add(a, a));
    showq("vU128AddS", vU128AddS(a, a));
    showq("vS128AddS", (vUInt32)vS128AddS((vSInt32){-1, -1, -1, 0x7fffffff}, (vSInt32){1, 0, 0, 0}));
    showq("vU128Sub", vU128Sub(b, a));
    showq("vU128SubS", vU128SubS(b, a));
    showq("vS128SubS", (vUInt32)vS128SubS((vSInt32){0, 0, 0, (int)0x80000000}, (vSInt32){1, 0, 0, 0}));
    showq("vU64Neg", vU64Neg(a));
    showq("vS128Neg", (vUInt32)vS128Neg((vSInt32)a));
    showq("vU32FullMulEven", vU32FullMulEven((vUInt32){0x10000, 2, 0x30000, 4}, (vUInt32){0x10000, 5, 0x10000, 7}));
    showq("vU32FullMulOdd", vU32FullMulOdd((vUInt32){0x10000, 2, 0x30000, 4}, (vUInt32){0x10000, 5, 0x10000, 7}));
    showq("vS32FullMulOdd", (vUInt32)vS32FullMulOdd((vSInt32){-2, 3, -4, 5}, (vSInt32){3, 3, 5, 5}));
    showq("vU64FullMulEven", vU64FullMulEven((vUInt32){0, 1, 2, 3}, (vUInt32){0, 1, 5, 7}));
    showq("vS64FullMulOdd", (vUInt32)vS64FullMulOdd((vSInt32){-3, -1, 2, 3}, (vSInt32){7, 0, 5, 7}));
    showq("vU64HalfMultiply", vU64HalfMultiply(a, b));
    showq("vS64HalfMultiply", (vUInt32)vS64HalfMultiply((vSInt32)a, (vSInt32){-3, -1, 2, 0}));
    showq("vU128HalfMultiply", vU128HalfMultiply(a, b));
    showq("vU32Divide", vU32Divide((vUInt32){100, 7, 9, 0xffffffff}, (vUInt32){7, 0, 3, 2}, &r));
    showq(" remainder", r);
    vSInt32 sr;
    showq("vS32Divide", (vUInt32)vS32Divide((vSInt32){-100, 7, -9, 11}, (vSInt32){7, -2, 3, -4}, &sr));
    showq(" remainder", (vUInt32)sr);
    vUInt16 r16;
    vUInt16 q16 = vU16Divide((vUInt16){100, 200, 300, 400, 500, 600, 700, 65535}, (vUInt16){3, 7, 9, 11, 13, 1, 2, 4},
                             &r16);
    printf("vU16Divide: %u %u %u %u | %u %u\n", q16[0], q16[1], q16[6], q16[7], r16[0], r16[1]);
    vSInt8 r8;
    vSInt8 q8 = vS8Divide((vSInt8){-100, 50, -7, 9}, (vSInt8){7, -3, 2, 4}, &r8);
    printf("vS8Divide: %d %d %d %d | %d %d %d %d\n", q8[0], q8[1], q8[2], q8[3], r8[0], r8[1], r8[2], r8[3]);
    vUInt8 h8 = vU8HalfMultiply((vUInt8){200, 3, 17, 255}, (vUInt8){2, 5, 16, 255});
    printf("vU8HalfMultiply: %u %u %u %u\n", h8[0], h8[1], h8[2], h8[3]);
    vSInt32 h32 = vS32HalfMultiply((vSInt32){-70000, 3, 65536, 7}, (vSInt32){70000, -5, 65536, 9});
    printf("vS32HalfMultiply: %d %d %d %d\n", h32[0], h32[1], h32[2], h32[3]);
    showq("vU64Divide", vU64Divide(a, (vUInt32){0x10, 0, 3, 1}, &r));
    showq(" remainder", r);
    showq("vU128Divide", vU128Divide(a, (vUInt32){0x10, 0, 0, 0}, &r));
    showq(" remainder", r);
    showq("vS128Divide", (vUInt32)vS128Divide((vSInt32){-7, -1, -1, -1}, (vSInt32){2, 0, 0, 0}, &sr));
    showq(" remainder", (vUInt32)sr);
    vUInt8 s1 = {4, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0}, s2 = {36, 0, 0, 0, 0, 0, 0, 0, 1};
    showq("vLL64Shift", vLL64Shift(a, s1));
    showq("vLR64Shift", vLR64Shift(a, s2));
    showq("vA64Shift", vA64Shift(a, s1));
    showq("vLL64Shift2", vLL64Shift2(a, s1));
    showq("vLR64Shift2", vLR64Shift2(a, s2));
    showq("vA64Shift2", vA64Shift2(a, s2));
    showq("vLL128Shift", vLL128Shift(a, s2));
    showq("vLR128Shift", vLR128Shift(a, s1));
    showq("vA128Shift", vA128Shift((vUInt32){0, 0, 0, 0x80000000}, s2));
    showq("vL64Rotate", vL64Rotate(a, s2));
    showq("vR64Rotate", vR64Rotate(a, s1));
    showq("vL64Rotate2", vL64Rotate2(a, s1));
    showq("vR64Rotate2", vR64Rotate2(a, s2));
    showq("vL128Rotate", vL128Rotate(a, s1));
    showq("vR128Rotate", vR128Rotate(a, s2));
}

static void showbig(const char *label, const void *v, int words)
{
    const uint32_t *w = v;
    printf("%s:", label);
    for (int i = words - 1; i >= 0; --i)
        printf(" %08x", w[i]);
    printf("\n");
}

static void bignum(void)
{
    vU256 a, b, r, rem;
    vU512 wide, a5, b5, r5;
    uint32_t *wa = (uint32_t *)&a, *wb = (uint32_t *)&b;
    for (int i = 0; i < 8; ++i) {
        wa[i] = 0x9e3779b9u * (uint32_t)(i + 1);
        wb[i] = i < 3 ? 0x7f4a7c15u * (uint32_t)(i + 3) : 0;
    }
    vU256Add(&a, &a, &r);
    showbig("vU256Add", &r, 8);
    vU256AddS(&a, &a, &r);
    showbig("vU256AddS", &r, 8);
    vS256AddS((const vS256 *)&a, (const vS256 *)&a, (vS256 *)&r);
    showbig("vS256AddS", &r, 8);
    vU256Sub(&b, &a, &r);
    showbig("vU256Sub", &r, 8);
    vU256SubS(&b, &a, &r);
    showbig("vU256SubS", &r, 8);
    vS256Sub((const vS256 *)&b, (const vS256 *)&a, (vS256 *)&r);
    showbig("vS256Sub", &r, 8);
    vU256Neg(&a, &r);
    showbig("vU256Neg", &r, 8);
    vU256HalfMultiply(&a, &b, &r);
    showbig("vU256HalfMultiply", &r, 8);
    vS256HalfMultiply((const vS256 *)&a, (const vS256 *)&b, (vS256 *)&r);
    showbig("vS256HalfMultiply", &r, 8);
    vU256FullMultiply(&a, &b, &wide);
    showbig("vU256FullMultiply", &wide, 16);
    vS256FullMultiply((const vS256 *)&a, (const vS256 *)&b, (vS512 *)&wide);
    showbig("vS256FullMultiply", &wide, 16);
    vU256Divide(&a, &b, &r, &rem);
    showbig("vU256Divide", &r, 8);
    showbig(" remainder", &rem, 8);
    vS256Divide((const vS256 *)&a, (const vS256 *)&b, (vS256 *)&r, (vS256 *)&rem);
    showbig("vS256Divide", &r, 8);
    showbig(" remainder", &rem, 8);
    vU256Mod(&a, &b, &rem);
    showbig("vU256Mod", &rem, 8);
    vLL256Shift(&a, 37, &r);
    showbig("vLL256Shift", &r, 8);
    vLR256Shift(&a, 70, &r);
    showbig("vLR256Shift", &r, 8);
    vA256Shift((const vS256 *)&a, 33, (vS256 *)&r);
    showbig("vA256Shift", &r, 8);
    vL256Rotate(&a, 100, &r);
    showbig("vL256Rotate", &r, 8);
    vR256Rotate(&a, 9, &r);
    showbig("vR256Rotate", &r, 8);
    uint32_t *w5 = (uint32_t *)&a5, *x5 = (uint32_t *)&b5;
    for (int i = 0; i < 16; ++i) {
        w5[i] = 0x2545f491u * (uint32_t)(i + 7);
        x5[i] = i < 9 ? 0x6c8e9cf5u * (uint32_t)(i + 1) : 0;
    }
    vU512 rem5;
    vU512Divide(&a5, &b5, &r5, &rem5);
    showbig("vU512Divide", &r5, 16);
    showbig(" remainder", &rem5, 16);
    vS512Mod((const vS512 *)&a5, (const vS512 *)&b5, (vS512 *)&r5);
    showbig("vS512Mod", &r5, 16);
    vU1024 big, bigr;
    vU512FullMultiply(&a5, &b5, &big);
    showbig("vU512FullMultiply", &big, 32);
    vR1024Rotate(&big, 515, &bigr);
    showbig("vR1024Rotate", &bigr, 32);
    vU128 x = {.v = {0x89abcdef, 0x01234567, 0xfedcba98, 0x76543210}}, y = {.v = {3, 0, 5, 0}};
    vU128FullMultiply(&x, &y, &a);
    showbig("vU128FullMultiply", &a, 8);
}

static void vectorops(void)
{
    vFloat a[4] = {{1, -2, 3, -4}, {5, -6, 7, -8}, {9, 10, -11, 12}, {-13, 14, 15, 16}};
    vFloat b[4] = {{0.5f, 1, 1.5f, 2}, {2.5f, 3, 3.5f, 4}, {-1, -2, -3, -4}, {1, 0, 1, 0}};
    vFloat c[4], d[4];
    /* (Apple's arm64 vIsamax, vIsamin, vIsmax, vIsmin, vSnrm2, vSgevv, vSndot and vSnaxpy do
       not compute what vectorOps.h describes, so they are left out) */
    printf("vSasum: %.5g vSsum: %.5g vSdot: %.5g vSnorm2: %.5g\n", vSasum(16, a), vSsum(16, a), vSdot(8, a, b),
           vSnorm2(16, a));
    for (int i = 0; i < 4; ++i)
        c[i] = b[i];
    vSaxpy(8, 2, a, c);
    show("vSaxpy", (const float *)c, 8);
    vSzaxpy(8, -1, a, b, c);
    show("vSzaxpy", (const float *)c, 8);
    vSgemv('N', 4, 4, 2, a, b, 0.5f, c);
    show("vSgemv-N", (const float *)c, 4);
    vSgemv('T', 4, 4, 1, a, b, 0, c);
    show("vSgemv-T", (const float *)c, 4);
    vSgemul(4, 4, 4, a, 'N', b, 'T', c);
    show("vSgemul-NT", (const float *)c, 16);
    vSgemm(4, 4, 4, a, 'T', b, 'N', b, 1, 2, d);
    show("vSgemm-TN", (const float *)d, 16);
    vSgeadd(4, 4, a, 'N', b, 'T', c);
    show("vSgeadd", (const float *)c, 16);
    vSgesub(4, 4, a, 'T', b, 'N', c);
    show("vSgesub", (const float *)c, 16);
    vSgetmo(4, 4, a, c);
    show("vSgetmo", (const float *)c, 16);
    vSgetmi(4, c);
    show("vSgetmi", (const float *)c, 16);
    for (int i = 0; i < 4; ++i)
        c[i] = b[i];
    vSrot(4, c, c + 1, 0.6f, 0.8f);
    show("vSrot", (const float *)c, 8);
}

int main(void)
{
    vforce();
    vfp();
    basicops();
    bignum();
    vectorops();
    return 0;
}

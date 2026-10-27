/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vDSP across its families, in both precisions where vDSP has them: vector arithmetic,
 * reductions, conversions, complex vectors, FFTs, DFTs and DCTs, filters, windows and
 * matrices. Built against the SDK; run on Apple's Accelerate and on Finch's and diffed
 * (tools/host-tests.sh). Values are printed to four significant digits.
 */
#include <Accelerate/Accelerate.h>
#include <stdio.h>
#include <string.h>

#define N 8

static void show(const char *label, const float *v, size_t n)
{
    printf("%s:", label);
    for (size_t i = 0; i < n; ++i) {
        float x = v[i];
        printf(" %.4g", (x < 5e-5f && x > -5e-5f) ? 0.0f : x);
    }
    printf("\n");
}

static void showd(const char *label, const double *v, size_t n)
{
    printf("%s:", label);
    for (size_t i = 0; i < n; ++i) {
        double x = v[i];
        printf(" %.4g", (x < 5e-9 && x > -5e-9) ? 0.0 : x);
    }
    printf("\n");
}

static float A[64], B[64], C[64], D[64];
static double AD[64], BD[64], CD[64], DD[64];

static void reset(void)
{
    for (int i = 0; i < 64; ++i) {
        A[i] = (float)((i * 7) % 11) - 4.5f;
        B[i] = (float)((i * 5) % 9) + 0.25f;
        C[i] = 0;
        D[i] = 0;
        AD[i] = A[i];
        BD[i] = B[i];
        CD[i] = 0;
        DD[i] = 0;
    }
}

#define BIN(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        vDSP_##f(A, 1, B, 1, C, 1, N);                                                                   \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 2, BD, 1, CD, 1, N);                                                             \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define UN(f)                                                                                            \
    do {                                                                                                 \
        reset();                                                                                         \
        vDSP_##f(A, 1, C, 1, N);                                                                         \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 3, CD, 1, N);                                                                    \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define VS(f)                                                                                            \
    do {                                                                                                 \
        reset();                                                                                         \
        float s = 1.5f;                                                                                  \
        double sd = 1.5;                                                                                 \
        vDSP_##f(A, 1, &s, C, 1, N);                                                                     \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, &sd, CD, 2, N);                                                               \
        showd(#f "D", CD, 2 * N);                                                                        \
    } while (0)
#define RED(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        float r = 0;                                                                                     \
        double rd = 0;                                                                                   \
        vDSP_##f(A, 1, &r, N);                                                                           \
        vDSP_##f##D(AD, 2, &rd, N);                                                                      \
        printf("%s: %.4g %.4g\n", #f, r, rd);                                                            \
    } while (0)
#define REDI(f)                                                                                          \
    do {                                                                                                 \
        reset();                                                                                         \
        float r = 0;                                                                                     \
        double rd = 0;                                                                                   \
        vDSP_Length i = 99, id = 99;                                                                     \
        vDSP_##f(A, 1, &r, &i, N);                                                                       \
        vDSP_##f##D(AD, 2, &rd, &id, N);                                                                 \
        printf("%s: %.4g %lu %.4g %lu\n", #f, r, (unsigned long)i, rd, (unsigned long)id);               \
    } while (0)
#define TER(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        vDSP_##f(A, 1, B, 1, A + 16, 1, C, 1, N);                                                        \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, BD, 1, AD + 16, 1, CD, 1, N);                                                 \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define VSV(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        float s = -2;                                                                                    \
        double sd = -2;                                                                                  \
        vDSP_##f(A, 1, &s, B, 1, C, 1, N);                                                               \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, &sd, BD, 1, CD, 1, N);                                                        \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define VVS(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        float s = -2;                                                                                    \
        double sd = -2;                                                                                  \
        vDSP_##f(A, 1, B, 1, &s, C, 1, N);                                                               \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, BD, 1, &sd, CD, 1, N);                                                        \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define V2S(f)                                                                                           \
    do {                                                                                                 \
        reset();                                                                                         \
        float lo = -2, hi = 3;                                                                           \
        double lod = -2, hid = 3;                                                                        \
        vDSP_##f(A, 1, &lo, &hi, C, 1, N);                                                               \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, &lod, &hid, CD, 1, N);                                                        \
        showd(#f "D", CD, N);                                                                            \
    } while (0)
#define QUAD(f)                                                                                          \
    do {                                                                                                 \
        reset();                                                                                         \
        vDSP_##f(A, 1, B, 1, A + 16, 1, B + 16, 1, C, 1, N);                                             \
        show(#f, C, N);                                                                                  \
        vDSP_##f##D(AD, 1, BD, 1, AD + 16, 1, BD + 16, 1, CD, 1, N);                                     \
        showd(#f "D", CD, N);                                                                            \
    } while (0)

#define RUN_D(stmt_f, stmt_d, label, out, outd, n)                                                       \
    do {                                                                                                 \
        reset();                                                                                         \
        stmt_f;                                                                                          \
        show(label, out, n);                                                                             \
        stmt_d;                                                                                          \
        showd(label "D", outd, n);                                                                       \
    } while (0)

static void vectors(void)
{
    BIN(vadd);
    BIN(vsub);
    BIN(vmul);
    BIN(vdiv);
    BIN(vmax);
    BIN(vmin);
    BIN(vmaxmg);
    BIN(vminmg);
    BIN(vdist);
    UN(vneg);
    UN(vsq);
    UN(vabs);
    UN(vnabs);
    UN(vssq);
    UN(vfrac);
    VS(vsadd);
    VS(vsmul);
    VS(vsdiv);
    VS(vthr);
    VS(vthres);
    VS(vtrapz);
    VS(vsimps);
    VS(vrsum);
    VS(vavlin);
    TER(vma);
    TER(vmsb);
    TER(vam);
    TER(vsbm);
    TER(venvlp);
    VSV(vsma);
    VSV(vsmsb);
    VVS(vmsa);
    VVS(vasm);
    VVS(vsbsm);
    VVS(vintb);
    V2S(vclip);
    V2S(viclip);
    V2S(vlim);
    V2S(vthrsc);
    QUAD(vaam);
    QUAD(vasbm);
    QUAD(vsbsbm);
    QUAD(vmma);
    QUAD(vmmsb);
    QUAD(vpythg);
    RED(sve);
    RED(svemg);
    RED(svesq);
    RED(svs);
    RED(meanv);
    RED(meamgv);
    RED(measqv);
    RED(mvessq);
    RED(rmsqv);
    RED(maxv);
    RED(minv);
    RED(maxmgv);
    RED(minmgv);
    REDI(maxvi);
    REDI(minvi);
    REDI(maxmgvi);
    REDI(minmgvi);

    float s1 = 2, s2 = -0.5f, mean, sd;
    double s1d = 2, s2d = -0.5, meand, sdd;
    RUN_D(vDSP_vsmsma(A, 1, &s1, B, 1, &s2, C, 1, N), vDSP_vsmsmaD(AD, 1, &s1d, BD, 1, &s2d, CD, 1, N), "vsmsma",
          C, CD, N);
    RUN_D(vDSP_svdiv(&s1, A, 1, C, 1, N), vDSP_svdivD(&s1d, AD, 1, CD, 1, N), "svdiv", C, CD, N);
    RUN_D(vDSP_vsmsa(A, 1, &s1, &s2, C, 1, N), vDSP_vsmsaD(AD, 1, &s1d, &s2d, CD, 1, N), "vsmsa", C, CD, N);
    RUN_D(vDSP_vfill(&s1, C, 2, N), vDSP_vfillD(&s1d, CD, 2, N), "vfill", C, CD, 2 * N);
    RUN_D(vDSP_vramp(&s1, &s2, C, 1, N), vDSP_vrampD(&s1d, &s2d, CD, 1, N), "vramp", C, CD, N);
    RUN_D(vDSP_vgen(&s1, &s2, C, 1, N), vDSP_vgenD(&s1d, &s2d, CD, 1, N), "vgen", C, CD, N);
    RUN_D((vDSP_normalize(A, 1, C, 1, &mean, &sd, N), C[N] = mean, C[N + 1] = sd),
          (vDSP_normalizeD(AD, 1, CD, 1, &meand, &sdd, N), CD[N] = meand, CD[N + 1] = sdd), "normalize", C, CD,
          N + 2);
    RUN_D(vDSP_dotpr(A, 1, B, 2, C, N), vDSP_dotprD(AD, 1, BD, 2, CD, N), "dotpr", C, CD, 1);
    RUN_D(vDSP_distancesq(A, 1, B, 1, C, N), vDSP_distancesqD(AD, 1, BD, 1, CD, N), "distancesq", C, CD, 1);
    RUN_D(vDSP_dotpr2(A, 1, A + 8, 1, B, 1, C, C + 1, N), vDSP_dotpr2D(AD, 1, AD + 8, 1, BD, 1, CD, CD + 1, N),
          "dotpr2", C, CD, 2);
    RUN_D(vDSP_sve_svesq(A, 1, C, C + 1, N), vDSP_sve_svesqD(AD, 1, CD, CD + 1, N), "sve_svesq", C, CD, 2);
    RUN_D(vDSP_vswsum(A, 1, C, 1, N - 2, 3), vDSP_vswsumD(AD, 1, CD, 1, N - 2, 3), "vswsum", C, CD, N - 2);
    RUN_D(vDSP_vswmax(A, 1, C, 1, N - 2, 3), vDSP_vswmaxD(AD, 1, CD, 1, N - 2, 3), "vswmax", C, CD, N - 2);
    RUN_D(vDSP_vtmerg(A, 1, B, 1, C, 1, N), vDSP_vtmergD(AD, 1, BD, 1, CD, 1, N), "vtmerg", C, CD, N);
    RUN_D(vDSP_vpoly(B, 1, A, 1, C, 1, N, 3), vDSP_vpolyD(BD, 1, AD, 1, CD, 1, N, 3), "vpoly", C, CD, N);
    RUN_D(vDSP_vcmprs(A, 1, B, 1, C, 1, N), vDSP_vcmprsD(AD, 1, BD, 1, CD, 1, N), "vcmprs", C, CD, N);
    RUN_D(vDSP_vdbcon(B, 1, &s1, C, 1, N, 1), vDSP_vdbconD(BD, 1, &s1d, CD, 1, N, 0), "vdbcon", C, CD, N);
    RUN_D(vDSP_polar(A, 2, C, 2, N / 2), vDSP_polarD(AD, 2, CD, 2, N / 2), "polar", C, CD, N);
    RUN_D(vDSP_rect(B, 2, C, 2, N / 2), vDSP_rectD(BD, 2, CD, 2, N / 2), "rect", C, CD, N);
    RUN_D((memcpy(C, A, sizeof(A)), vDSP_vrvrs(C, 1, N)), (memcpy(CD, AD, sizeof(AD)), vDSP_vrvrsD(CD, 1, N)),
          "vrvrs", C, CD, N);
    RUN_D((memcpy(C, A, sizeof(A)), vDSP_vsort(C, N, -1)), (memcpy(CD, AD, sizeof(AD)), vDSP_vsortD(CD, N, 1)),
          "vsort", C, CD, N);
    RUN_D(vDSP_vindex(B, A + 20, 0, C, 1, N), vDSP_vindexD(BD, AD + 20, 0, CD, 1, N), "vindex-zero-stride", C, CD,
          N);
    float idx[N] = {0, 1.5f, 2.25f, 6.9f, 3, 0.5f, 5, 1};
    double idxd[N] = {0, 1.5, 2.25, 6.9, 3, 0.5, 5, 1};
    RUN_D(vDSP_vindex(A, idx, 1, C, 1, N), vDSP_vindexD(AD, idxd, 1, CD, 1, N), "vindex", C, CD, N);
    RUN_D(vDSP_vlint(A, idx, 1, C, 1, N, 8), vDSP_vlintD(AD, idxd, 1, CD, 1, N, 8), "vlint", C, CD, N);
    RUN_D(vDSP_vqint(A, idx, 1, C, 1, N, 8), vDSP_vqintD(AD, idxd, 1, CD, 1, N, 8), "vqint", C, CD, N);
    RUN_D(vDSP_vtabi(A, 1, &s1, &s2, B, 8, C, 1, N), vDSP_vtabiD(AD, 1, &s1d, &s2d, BD, 8, CD, 1, N), "vtabi", C,
          CD, N);
    vDSP_Length g[N] = {1, 3, 5, 7, 2, 4, 6, 8}, sorti[N], tmp[N];
    RUN_D(vDSP_vgathr(A, g, 1, C, 1, N), vDSP_vgathrD(AD, g, 1, CD, 1, N), "vgathr", C, CD, N);
    RUN_D(vDSP_vgenp(A, 1, idx, 1, C, 1, N, 4), vDSP_vgenpD(AD, 1, idxd, 1, CD, 1, N, 4), "vgenp", C, CD, N);
    reset();
    for (int i = 0; i < N; ++i)
        sorti[i] = (vDSP_Length)i;
    vDSP_vsorti(A, sorti, tmp, N, 1);
    printf("vsorti:");
    for (int i = 0; i < N; ++i)
        printf(" %lu", (unsigned long)sorti[i]);
    printf("\n");
    vDSP_Length last = 99, count = 99;
    vDSP_nzcros(A, 1, 3, &last, &count, N);
    printf("nzcros: %lu %lu\n", (unsigned long)last, (unsigned long)count);
    vDSP_Length low = 9, high = 9;
    float lo = -2, hi = 3;
    vDSP_vclipc(A, 1, &lo, &hi, C, 1, N, &low, &high);
    show("vclipc", C, N);
    printf("vclipc-counts: %lu %lu\n", (unsigned long)low, (unsigned long)high);
    float start = 1, step = 0.25f;
    reset();
    vDSP_vrampmul(A, 1, &start, &step, C, 1, N);
    printf("vrampmul-start: %.4g\n", start);
    show("vrampmul", C, N);
    start = 1;
    vDSP_vrampmuladd2(A, B, 1, &start, &step, C, D, 1, N);
    show("vrampmuladd2", C, N);
    vDSP_vaddsub(A, 1, B, 1, C, 1, D, 1, N);
    show("vaddsub0", C, N);
    show("vaddsub1", D, N);
    reset();
    memcpy(C, A, sizeof(A));
    memcpy(D, B, sizeof(B));
    vDSP_vswap(C, 1, D, 2, 4);
    show("vswap", C, N);
    int ia[N] = {5, -3, 7, 0, -9, 2, 4, 1}, ib[N] = {2, 2, -2, 3, 3, 1, 4, -1}, ic[N];
    vDSP_vaddi(ia, 1, ib, 1, ic, 1, N);
    printf("vaddi: %d %d %d %d\n", ic[0], ic[1], ic[4], ic[7]);
    vDSP_vdivi(ib, 1, ia, 1, ic, 1, N);
    printf("vdivi: %d %d %d %d\n", ic[0], ic[1], ic[4], ic[7]);
    short s15[4] = {16384, -16384, 8192, 32767}, s15b[4] = {16384, 16384, -32768, 32767}, s15c = 0;
    vDSP_dotpr_s1_15(s15, 1, s15b, 1, &s15c, 4);
    printf("dotpr_s1_15: %d\n", s15c);
}

static void conversions(void)
{
    float v[N] = {-200.7f, -1.5f, -0.5f, 0.5f, 1.5f, 2.5f, 70000.f, 3e9f};
    char c8[N];
    short c16[N];
    int c32[N];
    unsigned char u8[N];
    unsigned short u16[N];
    unsigned int u32[N];
    vDSP_vfix8(v, 1, c8, 1, N);
    vDSP_vfixr16(v, 1, c16, 1, N);
    vDSP_vfixr32(v, 1, c32, 1, 6);
    vDSP_vfixru8(v, 1, u8, 1, N);
    vDSP_vfixu16(v, 1, u16, 1, N);
    vDSP_vfixru32(v, 3, u32, 1, 2);
    printf("vfix:");
    for (int i = 0; i < N; ++i)
        printf(" %d/%d/%u/%u", c8[i], c16[i], u8[i], u16[i]);
    printf(" | %d %d %d %d %u %u\n", c32[0], c32[1], c32[2], c32[3], u32[0], u32[1]);
    vDSP_vflt16(c16, 1, A, 1, N);
    show("vflt16", A, N);
    vDSP_vfltu8(u8, 1, A, 1, N);
    show("vfltu8", A, N);
    double dv[N];
    vDSP_vspdp(v, 1, dv, 1, N);
    vDSP_vdpsp(dv, 1, A, 1, N);
    show("vspdp-vdpsp", A, N);
    vDSP_int24 i24[3] = {{{0x01, 0x00, 0x80}}, {{0xff, 0xff, 0x7f}}, {{0x10, 0x20, 0x30}}};
    vDSP_vflt24(i24, 1, A, 1, 3);
    show("vflt24", A, 3);
    float scale = 1.0f / 8388608;
    vDSP_vfltsm24(i24, 1, &scale, A, 1, 3);
    show("vfltsm24", A, 3);
    float back[3] = {0.5f, -1.5f, 0.25f}, k = 8388607;
    vDSP_vsmfix24(back, 1, &k, i24, 1, 3);
    printf("vsmfix24: %02x%02x%02x %02x%02x%02x %02x%02x%02x\n", i24[0].bytes[0], i24[0].bytes[1], i24[0].bytes[2],
           i24[1].bytes[0], i24[1].bytes[1], i24[1].bytes[2], i24[2].bytes[0], i24[2].bytes[1], i24[2].bytes[2]);
}

static void complexes(void)
{
    reset();
    DSPSplitComplex a = {A, A + 16}, b = {B, B + 16}, c = {C, C + 16}, d = {D, D + 16};
    DSPDoubleSplitComplex ad = {AD, AD + 16}, bd = {BD, BD + 16}, cd = {CD, CD + 16};
#define ZSHOW(label)                                                                                     \
    do {                                                                                                 \
        show(label ".re", C, N);                                                                         \
        show(label ".im", C + 16, N);                                                                    \
    } while (0)
    vDSP_zvadd(&a, 1, &b, 1, &c, 1, N);
    ZSHOW("zvadd");
    vDSP_zvsub(&a, 1, &b, 1, &c, 1, N);
    ZSHOW("zvsub");
    vDSP_zvmul(&a, 1, &b, 1, &c, 1, N, 1);
    ZSHOW("zvmul");
    vDSP_zvmul(&a, 1, &b, 1, &c, 1, N, -1);
    ZSHOW("zvmul-conj");
    vDSP_zvcmul(&a, 1, &b, 1, &c, 1, N);
    ZSHOW("zvcmul");
    vDSP_zvdiv(&b, 1, &a, 1, &c, 1, N);
    ZSHOW("zvdiv");
    vDSP_zvconj(&a, 1, &c, 1, N);
    ZSHOW("zvconj");
    vDSP_zvabs(&a, 1, C, 1, N);
    show("zvabs", C, N);
    vDSP_zvmags(&a, 1, C, 1, N);
    show("zvmags", C, N);
    vDSP_zvphas(&a, 1, C, 1, N);
    show("zvphas", C, N);
    vDSP_zvmgsa(&a, 1, B, 1, C, 1, N);
    show("zvmgsa", C, N);
    vDSP_zrvmul(&a, 1, B, 1, &c, 1, N);
    ZSHOW("zrvmul");
    vDSP_zrvdiv(&a, 1, B, 1, &c, 1, N);
    ZSHOW("zrvdiv");
    vDSP_zvma(&a, 1, &b, 1, &a, 1, &c, 1, N);
    ZSHOW("zvma");
    vDSP_zvcma(&a, 1, &b, 1, &a, 1, &c, 1, N);
    ZSHOW("zvcma");
    vDSP_zvsma(&a, 1, &b, &a, 1, &c, 1, N);
    ZSHOW("zvsma");
    vDSP_zvzsml(&a, 1, &b, &c, 1, N);
    ZSHOW("zvzsml");
    vDSP_zdotpr(&a, 1, &b, 1, &c, N);
    printf("zdotpr: %.4g %.4g\n", C[0], C[16]);
    vDSP_zidotpr(&a, 1, &b, 1, &c, N);
    printf("zidotpr: %.4g %.4g\n", C[0], C[16]);
    vDSP_zrdotpr(&a, 1, B, 1, &c, N);
    printf("zrdotpr: %.4g %.4g\n", C[0], C[16]);
    vDSP_zaspec(&a, C, N);
    show("zaspec", C, N);
    vDSP_zcspec(&a, &b, &c, N);
    ZSHOW("zcspec");
    vDSP_zcoher(B, B + 8, &a, C, N);
    show("zcoher", C, N);
    vDSP_ztrans(B, &a, &c, N);
    ZSHOW("ztrans");
    vDSP_zconv(&a, 1, &b, 1, &c, 1, 4, 3);
    show("zconv.re", C, 4);
    show("zconv.im", C + 16, 4);
    vDSP_zrdesamp(&a, 2, B, &c, 3, 2);
    show("zrdesamp.re", C, 3);
    show("zrdesamp.im", C + 16, 3);
    vDSP_zmmul(&a, 1, &b, 1, &c, 1, 2, 2, 3);
    show("zmmul.re", C, 4);
    show("zmmul.im", C + 16, 4);
    vDSP_zmma(&a, 1, &b, 1, &a, 1, &d, 1, 2, 2, 2);
    show("zmma.re", D, 4);
    show("zmma.im", D + 16, 4);
    vDSP_zvmovD(&ad, 1, &cd, 1, N);
    vDSP_zvdivD(&bd, 1, &ad, 1, &cd, 1, N);
    showd("zvdivD.re", CD, N);
    showd("zvdivD.im", CD + 16, N);
    float inter[2 * N];
    vDSP_ztoc(&a, 1, (DSPComplex *)inter, 2, N);
    show("ztoc", inter, 2 * N);
    reset();
    vDSP_ctoz((const DSPComplex *)B, 2, &c, 1, N);
    ZSHOW("ctoz");
}

static void ffts(void)
{
    FFTSetup setup = vDSP_create_fftsetup(5, kFFTRadix2);
    FFTSetupD setupd = vDSP_create_fftsetupD(5, kFFTRadix5);
    printf("fftsetup: %d %d %d\n", setup != NULL, setupd != NULL, vDSP_create_fftsetup(0, kFFTRadix2) != NULL);
    reset();
    DSPSplitComplex a = {A, A + 32}, c = {C, C + 32};
    DSPDoubleSplitComplex ad = {AD, AD + 32}, cd = {CD, CD + 32};
    vDSP_fft_zop(setup, &a, 1, &c, 1, 3, FFT_FORWARD);
    show("fft_zop.re", C, N);
    show("fft_zop.im", C + 32, N);
    vDSP_fft_zip(setup, &c, 1, 3, FFT_INVERSE);
    show("fft_zip-inverse.re", C, N);
    vDSP_fft_zopD(setupd, &ad, 2, &cd, 1, 3, FFT_FORWARD);
    showd("fft_zopD.re", CD, N);
    reset();
    vDSP_fft_zrop(setup, &a, 1, &c, 1, 4, FFT_FORWARD);
    show("fft_zrop.re", C, N);
    show("fft_zrop.im", C + 32, N);
    vDSP_fft_zrip(setup, &c, 1, 4, FFT_INVERSE);
    show("fft_zrip-inverse.re", C, N);
    show("fft_zrip-inverse.im", C + 32, N);
    reset();
    vDSP_fft_zripD(setupd, &ad, 1, 3, FFT_FORWARD);
    showd("fft_zripD.re", AD, 4);
    showd("fft_zripD.im", AD + 32, 4);
    reset();
    vDSP_fftm_zop(setup, &a, 1, 8, &c, 1, 8, 2, 2, FFT_FORWARD);
    show("fftm_zop.re", C, N);
    reset();
    vDSP_fftm_zrip(setup, &a, 1, 4, 3, 2, FFT_FORWARD);
    show("fftm_zrip.re", A, N);
    reset();
    vDSP_fft2d_zop(setup, &a, 1, 0, &c, 1, 0, 2, 2, FFT_FORWARD);
    show("fft2d_zop.re", C, 16);
    show("fft2d_zop.im", C + 32, 16);
    reset();
    vDSP_fft2d_zrop(setup, &a, 1, 0, &c, 1, 0, 3, 2, FFT_FORWARD);
    show("fft2d_zrop.re", C, 16);
    show("fft2d_zrop.im", C + 32, 16);
    vDSP_fft2d_zrip(setup, &c, 1, 0, 3, 2, FFT_INVERSE);
    show("fft2d_zrip-inverse.re", C, 16);
    show("fft2d_zrip-inverse.im", C + 32, 16);
    reset();
    FFTSetup setup3 = vDSP_create_fftsetup(3, kFFTRadix3);
    vDSP_fft3_zop(setup3, &a, 1, &c, 1, 3, FFT_FORWARD);
    show("fft3_zop.re", C, N);
    show("fft3_zop.im", C + 32, N);
    vDSP_fft5_zopD(setupd, &ad, 1, &cd, 1, 2, FFT_INVERSE);
    showd("fft5_zopD.re", CD, N);
    vDSP_destroy_fftsetup(setup);
    vDSP_destroy_fftsetup(setup3);
    vDSP_destroy_fftsetupD(setupd);
}

static void dfts(void)
{
    static const int lengths[] = {2, 4, 6, 8, 12, 16, 32, 48, 64, 80, 96, 160, 192, 240, 256};
    printf("dft-lengths:");
    for (size_t i = 0; i < sizeof(lengths) / sizeof(*lengths); ++i) {
        vDSP_Length n = (vDSP_Length)lengths[i];
        vDSP_DFT_Setup zop = vDSP_DFT_zop_CreateSetup(NULL, n, vDSP_DFT_FORWARD);
        vDSP_DFT_Setup zrop = vDSP_DFT_zrop_CreateSetup(NULL, n, vDSP_DFT_FORWARD);
        vDSP_DFT_Setup dct = vDSP_DCT_CreateSetup(NULL, n, vDSP_DCT_II);
        vDSP_DFT_Interleaved_Setup il =
            vDSP_DFT_Interleaved_CreateSetup(NULL, n, vDSP_DFT_FORWARD, vDSP_DFT_Interleaved_ComplextoComplex);
        printf(" %d:%d%d%d%d", lengths[i], zop != NULL, zrop != NULL, dct != NULL, il != NULL);
        vDSP_DFT_DestroySetup(zop);
        vDSP_DFT_DestroySetup(zrop);
        vDSP_DFT_DestroySetup(dct);
        vDSP_DFT_Interleaved_DestroySetup(il);
    }
    printf("\n");
    reset();
    vDSP_DFT_Setup fwd = vDSP_DFT_zop_CreateSetup(NULL, 24, vDSP_DFT_FORWARD);
    vDSP_DFT_Execute(fwd, A, B, C, D);
    show("dft-zop24.re", C, N);
    show("dft-zop24.im", D, N);
    vDSP_DFT_Setup inv = vDSP_DFT_zop_CreateSetup(fwd, 24, vDSP_DFT_INVERSE);
    vDSP_DFT_Execute(inv, C, D, C, D);
    show("dft-zop24-roundtrip", C, N);
    reset();
    vDSP_DFT_SetupD rop = vDSP_DFT_zrop_CreateSetupD(NULL, 16, vDSP_DFT_FORWARD);
    vDSP_DFT_ExecuteD(rop, AD, AD + 8, CD, DD);
    showd("dft-zropD.re", CD, N);
    showd("dft-zropD.im", DD, N);
    vDSP_DFT_SetupD ropi = vDSP_DFT_zrop_CreateSetupD(NULL, 16, vDSP_DFT_INVERSE);
    vDSP_DFT_ExecuteD(ropi, CD, DD, CD, DD);
    showd("dft-zropD-roundtrip", CD, N);
    vDSP_DFT_Setup legacy = vDSP_DFT_CreateSetup(NULL, 7);
    reset();
    vDSP_DFT_zop(legacy, A, B, 1, C, D, 1, vDSP_DFT_FORWARD);
    show("dft-legacy7.re", C, 7);
    vDSP_DFT_zop(legacy, A, B, 2, C, D, 1, vDSP_DFT_INVERSE);
    show("dft-legacy7-inverse.im", D, 7);
    static const vDSP_DCT_Type types[] = {vDSP_DCT_II, vDSP_DCT_III, vDSP_DCT_IV};
    for (int t = 0; t < 3; ++t) {
        vDSP_DFT_Setup dct = vDSP_DCT_CreateSetup(NULL, 16, types[t]);
        reset();
        vDSP_DCT_Execute(dct, A, C);
        char label[16];
        snprintf(label, sizeof(label), "dct-%d", (int)types[t]);
        show(label, C, N);
        vDSP_DFT_DestroySetup(dct);
    }
    reset();
    vDSP_DFT_Interleaved_Setup il =
        vDSP_DFT_Interleaved_CreateSetup(NULL, 12, vDSP_DFT_FORWARD, vDSP_DFT_Interleaved_ComplextoComplex);
    vDSP_DFT_Interleaved_Execute(il, (const DSPComplex *)A, (DSPComplex *)C);
    show("dft-interleaved12", C, 2 * N);
    vDSP_DFT_Interleaved_Setup ilr =
        vDSP_DFT_Interleaved_CreateSetup(NULL, 8, vDSP_DFT_FORWARD, vDSP_DFT_Interleaved_RealtoComplex);
    vDSP_DFT_Interleaved_Execute(ilr, (const DSPComplex *)A, (DSPComplex *)C);
    show("dft-interleaved-real8", C, 2 * N);
    vDSP_DFT_Interleaved_SetupD ild =
        vDSP_DFT_Interleaved_CreateSetupD(NULL, 8, vDSP_DFT_INVERSE, vDSP_DFT_Interleaved_ComplextoComplex);
    vDSP_DFT_Interleaved_ExecuteD(ild, (const DSPDoubleComplex *)AD, (DSPDoubleComplex *)CD);
    showd("dft-interleavedD-inverse8", CD, 2 * N);
    reset();
    float in32[64];
    for (int i = 0; i < 64; ++i)
        in32[i] = (float)((i * 3) % 7) - 2;
    vDSP_FFT16_copv(C, in32, FFT_FORWARD);
    show("fft16-copv", C, 2 * N);
    vDSP_FFT32_zopv(C, D, in32, in32 + 32, FFT_INVERSE);
    show("fft32-zopv.re", C, N);
    show("fft32-zopv.im", D, N);
}

static void filters(void)
{
    reset();
    vDSP_conv(A, 1, B + 2, -1, C, 1, N, 3);
    show("conv", C, N);
    vDSP_convD(AD, 1, BD, 1, CD, 1, N, 4);
    showd("convD", CD, N);
    vDSP_desamp(A, 3, B, C, 4, 3);
    show("desamp", C, 4);
    float coefficients[5] = {0.5f, 0.25f, 0.125f, -0.2f, 0.1f};
    reset();
    C[0] = 1;
    C[1] = -1;
    vDSP_deq22(A, 1, coefficients, C, 1, N);
    show("deq22", C, N + 2);
    double sections[10] = {1, 0.5, 0.25, -0.5, 0.1, 0.8, -0.2, 0.05, 0.3, -0.1};
    vDSP_biquad_Setup bq = vDSP_biquad_CreateSetup(sections, 2);
    float delay[6] = {0.1f, 0.2f, 0.3f, 0.4f, -0.5f, 0.6f};
    reset();
    vDSP_biquad(bq, delay, A, 1, C, 1, N);
    show("biquad", C, N);
    show("biquad-delay", delay, 6);
    vDSP_biquad_DestroySetup(bq);
    double multi[20] = {1, 0.5, 0.25, -0.5, 0.1, 2, 0, 0, 0.5, 0, 0.5, 0.5, 0, 0, 0, 1, 0, 1, 0.1, 0.2};
    vDSP_biquadm_Setup bqm = vDSP_biquadm_CreateSetup(multi, 2, 2);
    reset();
    const float *xs[2] = {A, B};
    float *ys[2] = {C, D};
    vDSP_biquadm(bqm, xs, 1, ys, 1, N);
    show("biquadm0", C, N);
    show("biquadm1", D, N);
    vDSP_biquadm(bqm, xs, 1, ys, 1, 2);
    show("biquadm-continued", C, 2);
    vDSP_biquadm_ResetState(bqm);
    vDSP_biquadm(bqm, xs, 1, ys, 1, 2);
    show("biquadm-reset", C, 2);
    bool active[2] = {false, true};
    vDSP_biquadm_SetActiveFilters(bqm, active);
    vDSP_biquadm(bqm, xs, 1, ys, 1, 3);
    show("biquadm-inactive", C, 3);
    vDSP_biquadm_DestroySetup(bqm);
    float image[36], filter[25];
    for (int i = 0; i < 36; ++i)
        image[i] = (float)((i * 5) % 13);
    for (int i = 0; i < 25; ++i)
        filter[i] = (float)(i % 4) - 1;
    vDSP_f3x3(image, 6, 6, filter, C);
    show("f3x3", C, 18);
    vDSP_f5x5(image, 6, 6, filter, C);
    show("f5x5", C, 18);
    vDSP_imgfir(image, 6, 6, filter, C, 3, 5);
    show("imgfir", C, 18);
    float auto_[3] = {4, 2, 1}, rhs[3] = {1, 2, 3}, f[3], p[3];
    int error = -1;
    vDSP_wiener(3, auto_, rhs, f, p, 0, &error);
    show("wiener-f", f, 3);
    show("wiener-p", p, 3);
    printf("wiener-error: %d\n", error);
    vDSP_hann_window(C, 9, 0);
    show("hann", C, 9);
    vDSP_hann_window(C, 9, vDSP_HANN_NORM | vDSP_HALF_WINDOW);
    show("hann-norm-half", C, 5);
    vDSP_hamm_windowD(CD, 8, 0);
    showd("hammD", CD, 8);
    vDSP_blkman_window(C, 7, vDSP_HALF_WINDOW);
    show("blkman-half", C, 4);
}

static void matrices(void)
{
    reset();
    vDSP_mmul(A, 1, B, 1, C, 1, 2, 3, 4);
    show("mmul", C, 6);
    vDSP_mmulD(AD, 2, BD, 1, CD, 1, 3, 2, 2);
    showd("mmulD", CD, 6);
    vDSP_mtrans(A, 1, C, 1, 3, 4);
    show("mtrans", C, 12);
    vDSP_mmov(A, C, 3, 2, 5, 4);
    show("mmov", C, 8);
}

int main(void)
{
    vectors();
    conversions();
    complexes();
    ffts();
    dfts();
    filters();
    matrices();
    return 0;
}

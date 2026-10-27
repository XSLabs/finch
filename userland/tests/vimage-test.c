/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage function by function: each call runs on the same pseudorandom images and
 * prints its return value and a hash of each output buffer. Built against the SDK;
 * run on Apple's Accelerate and on Finch's and diffed (tools/host-tests.sh).
 * VIMAGE_DUMP=<function> also prints that function's output bytes.
 */
#include <Accelerate/Accelerate.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define W 13
#define H 5

static uint32_t seed = 12345;
static uint32_t rnd(void)
{
    seed = seed * 1664525u + 1013904223u;
    return seed >> 8;
}

enum Kind { K8, KF, K16U, K16S, KHALF, KQ12, KZERO, KALPHA8 };

/* a W x H buffer of bpp-byte pixels (rows padded), filled by kind */
static vImage_Buffer make(size_t bpp, enum Kind kind)
{
    vImage_Buffer b;
    b.width = W;
    b.height = H;
    b.rowBytes = W * bpp + 8;
    b.data = malloc(b.rowBytes * H);
    uint8_t *p = b.data;
    for (size_t i = 0; i < b.rowBytes * H; ++i)
        p[i] = (uint8_t)rnd();
    size_t samples = b.rowBytes * H;
    switch (kind) {
    case KF:
        for (size_t i = 0; i < samples / 4; ++i)
            ((float *)p)[i] = (float)((int)(rnd() % 360) - 50) / 256.0f; /* exact products */
        break;
    case KHALF:
        for (size_t i = 0; i < samples / 2; ++i) {
            _Float16 h = (_Float16)((float)(rnd() % 1400) / 1000.0f - 0.2f);
            memcpy(p + 2 * i, &h, 2);
        }
        break;
    case KQ12:
        for (size_t i = 0; i < samples / 2; ++i)
            ((int16_t *)p)[i] = (int16_t)((int)(rnd() % 6000) - 1000);
        break;
    case KZERO:
        memset(p, 0, samples);
        break;
    default:
        break;
    }
    return b;
}

static uint32_t hash(const vImage_Buffer *b, size_t bpp)
{
    uint32_t h = 2166136261u;
    for (vImagePixelCount y = 0; y < b->height; ++y) {
        const uint8_t *row = (const uint8_t *)b->data + y * b->rowBytes;
        for (size_t i = 0; i < b->width * bpp; ++i)
            h = (h ^ row[i]) * 16777619u;
    }
    return h;
}

/* a coarse checksum for the few functions whose internal rounding Apple's differs from
   Finch's by one in a small fraction of samples: the sum of the output samples (8 or
   16 bits, or float) in units of 64 */
static long coarse(const vImage_Buffer *b, size_t bpp, int kind)
{
    double sum = 0;
    for (vImagePixelCount y = 0; y < b->height; ++y) {
        const uint8_t *row = (const uint8_t *)b->data + y * b->rowBytes;
        for (size_t i = 0; i < b->width * bpp; i += kind)
            sum += kind == 1 ? row[i] : kind == 2 ? *(const int16_t *)(row + i) : *(const float *)(row + i) * 1024;
    }
    return lround(sum / 64);
}

#define TOLERANT(name, BPP, kind, call)                                                                  \
    do {                                                                                                 \
        vImage_Buffer d = make(BPP, KZERO);                                                              \
        vImage_Error e = call;                                                                           \
        printf("%s (coarse): %ld %ld\n", #name, (long)e, coarse(&d, BPP, kind));                         \
        free(d.data);                                                                                    \
    } while (0)

static const char *dump_name;

static void report(const char *name, vImage_Error e, int n, const vImage_Buffer *bufs, const size_t *bpps)
{
    printf("%s: %ld", name, (long)e);
    for (int i = 0; i < n; ++i)
        printf(" %08x", hash(&bufs[i], bpps[i]));
    printf("\n");
    if (dump_name && !strcmp(dump_name, name))
        for (int i = 0; i < n; ++i)
            for (vImagePixelCount y = 0; y < bufs[i].height; ++y) {
                const uint8_t *row = (const uint8_t *)bufs[i].data + y * bufs[i].rowBytes;
                printf("  [%d] row %lu:", i, (unsigned long)y);
                for (size_t k = 0; k < bufs[i].width * bpps[i]; ++k)
                    printf(" %02x", row[k]);
                printf("\n");
            }
}

/* one output buffer */
#define T1(name, D, BPP, call)                                                                           \
    do {                                                                                                 \
        vImage_Buffer D = make(BPP, KZERO);                                                              \
        vImage_Error e = call;                                                                           \
        size_t bpp = BPP;                                                                                \
        report(#name, e, 1, &D, &bpp);                                                                   \
        free(D.data);                                                                                    \
    } while (0)

/* several output buffers of one pixel size */
#define TN(name, n, BPP, call)                                                                           \
    do {                                                                                                 \
        vImage_Buffer o[4];                                                                              \
        size_t bpp[4] = {BPP, BPP, BPP, BPP};                                                            \
        for (int i = 0; i < 4; ++i)                                                                      \
            o[i] = make(BPP, KZERO);                                                                     \
        vImage_Error e = call;                                                                           \
        report(#name, e, n, o, bpp);                                                                     \
        for (int i = 0; i < 4; ++i)                                                                      \
            free(o[i].data);                                                                             \
    } while (0)

static vImage_Buffer s8, s8b, s8c, s8d, sF, sFb, sFc, sFd, s16U, s16S, sHalf, sQ12, sQ12b, sQ12c, sQ12d;

static void conversions(void)
{
    const uint8_t perm[4] = {2, 0, 3, 1}, perm3[3] = {2, 0, 1};
    const Pixel_8888 bg8 = {200, 10, 128, 250};
    const Pixel_ARGB_16U bg16 = {60000, 1000, 30000, 65535};
    const Pixel_ARGB_16S bgQ = {4096, 100, 2000, 3500};
    const Pixel_FFFF bgF = {0.75f, 0.125f, 0.5f, 0.875f}, maxF = {1, 1, 2, 0.5f}, minF = {0, -1, 0.5f, 0};
    const Pixel_16U bg3[3] = {1, 40000, 65535};
    Pixel_8 table[256];
    for (int i = 0; i < 256; ++i)
        table[i] = (Pixel_8)(255 - i / 2);

    T1(Planar8toPlanarF, d, 4, vImageConvert_Planar8toPlanarF(&s8, &d, 2.5f, -1.0f, 0));
    T1(PlanarFtoPlanar8, d, 1, vImageConvert_PlanarFtoPlanar8(&sF, &d, 1.0f, 0.0f, 0));
    T1(PlanarFtoPlanar8-range, d, 1, vImageConvert_PlanarFtoPlanar8(&sF, &d, 0.8f, 0.1f, 0));
    T1(Clip_PlanarF, d, 4, vImageClip_PlanarF(&sF, &d, 0.9f, 0.05f, 0));
    T1(16SToF, d, 4, vImageConvert_16SToF(&s16S, &d, 0.5f, 1.0f / 32768, 0));
    T1(16UToF, d, 4, vImageConvert_16UToF(&s16U, &d, -0.25f, 1.0f / 65535, 0));
    T1(FTo16S, d, 2, vImageConvert_FTo16S(&sF, &d, 0.5f, 1.0f / 32768, 0));
    T1(FTo16U, d, 2, vImageConvert_FTo16U(&sF, &d, -0.1f, 1.0f / 65535, 0));
    T1(16Uto16F, d, 2, vImageConvert_16Uto16F(&s16U, &d, 0));
    T1(16Fto16U, d, 2, vImageConvert_16Fto16U(&sHalf, &d, 0));
    T1(Planar16FtoPlanarF, d, 4, vImageConvert_Planar16FtoPlanarF(&sHalf, &d, 0));
    T1(PlanarFtoPlanar16F, d, 2, vImageConvert_PlanarFtoPlanar16F(&sF, &d, 0));
    T1(Planar8toPlanar16F, d, 2, vImageConvert_Planar8toPlanar16F(&s8, &d, 0));
    T1(Planar16FtoPlanar8, d, 1, vImageConvert_Planar16FtoPlanar8(&sHalf, &d, 0));
    T1(16UToPlanar8, d, 1, vImageConvert_16UToPlanar8(&s16U, &d, 0));
    T1(Planar8To16U, d, 2, vImageConvert_Planar8To16U(&s8, &d, 0));
    T1(8to16Q12, d, 2, vImageConvert_8to16Q12(&s8, &d, 0));
    T1(16Q12to8, d, 1, vImageConvert_16Q12to8(&sQ12, &d, 0));
    T1(16Q12toF, d, 4, vImageConvert_16Q12toF(&sQ12, &d, 0));
    T1(Fto16Q12, d, 2, vImageConvert_Fto16Q12(&sF, &d, 0));
    T1(16Q12to16U, d, 2, vImageConvert_16Q12to16U(&sQ12, &d, 0));
    T1(16Uto16Q12, d, 2, vImageConvert_16Uto16Q12(&s16U, &d, 0));
    T1(16Q12to16F, d, 2, vImageConvert_16Q12to16F(&sQ12, &d, 0));
    T1(16Fto16Q12, d, 2, vImageConvert_16Fto16Q12(&sHalf, &d, 0));
    T1(ByteSwap_Planar16U, d, 2, vImageByteSwap_Planar16U(&s16U, &d, 0));
    T1(TableLookUp_Planar8, d, 1, vImageTableLookUp_Planar8(&s8, &d, table, 0));
    T1(TableLookUp_ARGB8888, d, 4, vImageTableLookUp_ARGB8888(&s8, &d, table, NULL, table, table, 0));
    {
        vImage_Buffer half = s16U;
        half.width = 12;
        vImage_Buffer d = make(2, KZERO);
        d.width = 12;
        size_t bpp = 2;
        vImage_Error e = vImageConvert_12UTo16U(&s8, &d, 0);
        report("12UTo16U", e, 1, &d, &bpp);
        vImage_Buffer d12 = make(1, KZERO);
        d12.width = 12;
        e = vImageConvert_16UTo12U(&half, &d12, 0);
        bpp = 1;
        d12.width = 18;
        report("16UTo12U", e, 1, &d12, &bpp);
        free(d.data);
        free(d12.data);
    }

    T1(Planar8toARGB8888, d, 4, vImageConvert_Planar8toARGB8888(&s8, &s8b, &s8c, &s8d, &d, 0));
    T1(PlanarFtoARGBFFFF, d, 16, vImageConvert_PlanarFtoARGBFFFF(&sF, &sFb, &sFc, &sFd, &d, 0));
    T1(Planar16UtoARGB16U, d, 8, vImageConvert_Planar16UtoARGB16U(&s16U, &s16S, &s16U, &s16S, &d, 0));
    T1(Planar8toRGB888, d, 3, vImageConvert_Planar8toRGB888(&s8, &s8b, &s8c, &d, 0));
    T1(PlanarFtoRGBFFF, d, 12, vImageConvert_PlanarFtoRGBFFF(&sF, &sFb, &sFc, &d, 0));
    T1(Planar16UtoRGB16U, d, 6, vImageConvert_Planar16UtoRGB16U(&s16U, &s16S, &s16U, &d, 0));
    TN(ARGB8888toPlanar8, 4, 1, vImageConvert_ARGB8888toPlanar8(&s8, &o[0], &o[1], &o[2], &o[3], 0));
    TN(ARGBFFFFtoPlanarF, 4, 4, vImageConvert_ARGBFFFFtoPlanarF(&sF, &o[0], &o[1], &o[2], &o[3], 0));
    TN(ARGB16UtoPlanar16U, 4, 2, vImageConvert_ARGB16UtoPlanar16U(&s16U, &o[0], &o[1], &o[2], &o[3], 0));
    TN(RGB888toPlanar8, 3, 1, vImageConvert_RGB888toPlanar8(&s8, &o[0], &o[1], &o[2], 0));
    TN(RGBFFFtoPlanarF, 3, 4, vImageConvert_RGBFFFtoPlanarF(&sF, &o[0], &o[1], &o[2], 0));
    TN(RGB16UtoPlanar16U, 3, 2, vImageConvert_RGB16UtoPlanar16U(&s16U, &o[0], &o[1], &o[2], 0));
    TN(BGRX8888ToPlanar8, 3, 1, vImageConvert_BGRX8888ToPlanar8(&s8, &o[0], &o[1], &o[2], 0));
    TN(BGRXFFFFToPlanarF, 3, 4, vImageConvert_BGRXFFFFToPlanarF(&sF, &o[0], &o[1], &o[2], 0));
    T1(Planar8ToXRGB8888, d, 4, vImageConvert_Planar8ToXRGB8888(77, &s8, &s8b, &s8c, &d, 0));
    T1(Planar8ToBGRX8888, d, 4, vImageConvert_Planar8ToBGRX8888(&s8, &s8b, &s8c, 99, &d, 0));
    T1(PlanarFToXRGBFFFF, d, 16, vImageConvert_PlanarFToXRGBFFFF(0.25f, &sF, &sFb, &sFc, &d, 0));
    T1(PlanarFToBGRXFFFF, d, 16, vImageConvert_PlanarFToBGRXFFFF(&sF, &sFb, &sFc, 0.5f, &d, 0));
    T1(Planar8ToXRGBFFFF, d, 16, vImageConvert_Planar8ToXRGBFFFF(0.25f, &s8, &s8b, &s8c, &d, maxF, minF, 0));
    T1(Planar8ToBGRXFFFF, d, 16, vImageConvert_Planar8ToBGRXFFFF(&s8, &s8b, &s8c, 0.5f, &d, maxF, minF, 0));
    T1(PlanarFToXRGB8888, d, 4, vImageConvert_PlanarFToXRGB8888(7, &sF, &sFb, &sFc, &d, maxF, minF, 0));
    T1(PlanarFToBGRX8888, d, 4, vImageConvert_PlanarFToBGRX8888(&sF, &sFb, &sFc, 9, &d, maxF, minF, 0));
    TN(ARGB8888toPlanarF, 4, 4, vImageConvert_ARGB8888toPlanarF(&s8, &o[0], &o[1], &o[2], &o[3], maxF, minF, 0));
    TN(ARGBFFFFtoPlanar8, 4, 1, vImageConvert_ARGBFFFFtoPlanar8(&sF, &o[0], &o[1], &o[2], &o[3], maxF, minF, 0));
    {
        const vImage_Buffer *planes[3] = {&s8, &s8b, &s8c};
        vImage_Buffer d = make(5, KZERO);
        void *channels[3] = {d.data, (uint8_t *)d.data + 2, (uint8_t *)d.data + 4};
        vImage_Error e = vImageConvert_PlanarToChunky8(planes, channels, 3, 5, W, H, d.rowBytes, 0);
        size_t bpp = 5;
        report("PlanarToChunky8", e, 1, &d, &bpp);
        vImage_Buffer o[3] = {make(1, KZERO), make(1, KZERO), make(1, KZERO)};
        const vImage_Buffer *outs[3] = {&o[0], &o[1], &o[2]};
        const void *in[3] = {s8.data, (uint8_t *)s8.data + 1, (uint8_t *)s8.data + 3};
        e = vImageConvert_ChunkyToPlanar8(in, outs, 3, 4, W, H, s8.rowBytes, 0);
        size_t bpps[3] = {1, 1, 1};
        report("ChunkyToPlanar8", e, 3, o, bpps);
        const vImage_Buffer *fplanes[2] = {&sF, &sFb};
        vImage_Buffer fd = make(12, KZERO);
        void *fch[2] = {fd.data, (uint8_t *)fd.data + 8};
        e = vImageConvert_PlanarToChunkyF(fplanes, fch, 2, 12, W, H, fd.rowBytes, 0);
        bpp = 12;
        report("PlanarToChunkyF", e, 1, &fd, &bpp);
        const void *fin[2] = {sF.data, (uint8_t *)sF.data + 4};
        vImage_Buffer fo[2] = {make(4, KZERO), make(4, KZERO)};
        const vImage_Buffer *fouts[2] = {&fo[0], &fo[1]};
        e = vImageConvert_ChunkyToPlanarF(fin, fouts, 2, 8, W, H, sF.rowBytes, 0);
        size_t fb[2] = {4, 4};
        report("ChunkyToPlanarF", e, 2, fo, fb);
    }

    T1(ARGB1555toARGB8888, d, 4, vImageConvert_ARGB1555toARGB8888(&s16U, &d, 0));
    T1(ARGB8888toARGB1555, d, 2, vImageConvert_ARGB8888toARGB1555(&s8, &d, 0));
    T1(RGBA5551toRGBA8888, d, 4, vImageConvert_RGBA5551toRGBA8888(&s16U, &d, 0));
    T1(RGBA8888toRGBA5551, d, 2, vImageConvert_RGBA8888toRGBA5551(&s8, &d, 0));
    T1(Planar8toARGB1555, d, 2, vImageConvert_Planar8toARGB1555(&s8, &s8b, &s8c, &s8d, &d, 0));
    T1(RGB565toRGBA8888, d, 4, vImageConvert_RGB565toRGBA8888(200, &s16U, &d, 0));
    T1(RGB565toBGRA8888, d, 4, vImageConvert_RGB565toBGRA8888(201, &s16U, &d, 0));
    T1(RGB565toARGB8888, d, 4, vImageConvert_RGB565toARGB8888(202, &s16U, &d, 0));
    T1(RGB565toRGB888, d, 3, vImageConvert_RGB565toRGB888(&s16U, &d, 0));
    T1(ARGB8888toRGB565, d, 2, vImageConvert_ARGB8888toRGB565(&s8, &d, 0));
    T1(RGBA8888toRGB565, d, 2, vImageConvert_RGBA8888toRGB565(&s8, &d, 0));
    T1(BGRA8888toRGB565, d, 2, vImageConvert_BGRA8888toRGB565(&s8, &d, 0));
    TN(RGB565toPlanar8, 3, 1, vImageConvert_RGB565toPlanar8(&s16U, &o[0], &o[1], &o[2], 0));
    T1(Planar8toRGB565, d, 2, vImageConvert_Planar8toRGB565(&s8, &s8b, &s8c, &d, 0));
    T1(RGBA5551toRGB565, d, 2, vImageConvert_RGBA5551toRGB565(&s16U, &d, 0));
    T1(ARGB1555toRGB565, d, 2, vImageConvert_ARGB1555toRGB565(&s16U, &d, 0));
    T1(RGB565toRGBA5551, d, 2, vImageConvert_RGB565toRGBA5551(&s16U, &d, kvImageConvert_DitherNone, 0));
    T1(RGB565toARGB1555, d, 2, vImageConvert_RGB565toARGB1555(&s16U, &d, kvImageConvert_DitherNone, 0));

    T1(ARGBFFFFtoRGBFFF, d, 12, vImageConvert_ARGBFFFFtoRGBFFF(&sF, &d, 0));
    T1(RGBAFFFFtoRGBFFF, d, 12, vImageConvert_RGBAFFFFtoRGBFFF(&sF, &d, 0));
    T1(BGRAFFFFtoRGBFFF, d, 12, vImageConvert_BGRAFFFFtoRGBFFF(&sF, &d, 0));
    T1(ARGB8888toRGB888, d, 3, vImageConvert_ARGB8888toRGB888(&s8, &d, 0));
    T1(RGBA8888toRGB888, d, 3, vImageConvert_RGBA8888toRGB888(&s8, &d, 0));
    T1(BGRA8888toRGB888, d, 3, vImageConvert_BGRA8888toRGB888(&s8, &d, 0));
    T1(ARGB16UtoRGB16U, d, 6, vImageConvert_ARGB16UtoRGB16U(&s16U, &d, 0));
    T1(RGBA16UtoRGB16U, d, 6, vImageConvert_RGBA16UtoRGB16U(&s16U, &d, 0));
    T1(BGRA16UtoRGB16U, d, 6, vImageConvert_BGRA16UtoRGB16U(&s16U, &d, 0));
    for (int pm = 0; pm < 2; ++pm) {
        printf("premultiply %d\n", pm);
        T1(RGB888toARGB8888, d, 4, vImageConvert_RGB888toARGB8888(&s8, &s8b, 0, &d, pm, 0));
        T1(RGB888toRGBA8888, d, 4, vImageConvert_RGB888toRGBA8888(&s8, NULL, 180, &d, pm, 0));
        T1(RGB888toBGRA8888, d, 4, vImageConvert_RGB888toBGRA8888(&s8, &s8c, 0, &d, pm, 0));
        T1(RGBFFFtoARGBFFFF, d, 16, vImageConvert_RGBFFFtoARGBFFFF(&sF, &sFb, 0, &d, pm, 0));
        T1(RGBFFFtoRGBAFFFF, d, 16, vImageConvert_RGBFFFtoRGBAFFFF(&sF, NULL, 0.5f, &d, pm, 0));
        T1(RGBFFFtoBGRAFFFF, d, 16, vImageConvert_RGBFFFtoBGRAFFFF(&sF, &sFc, 0, &d, pm, 0));
        T1(RGB16UtoRGBA16U, d, 8, vImageConvert_RGB16UtoRGBA16U(&s16U, &s16S, 0, &d, pm, 0));
        T1(RGB16UtoBGRA16U, d, 8, vImageConvert_RGB16UtoBGRA16U(&s16U, NULL, 30000, &d, pm, 0));
        T1(Flatten_ARGB8888, d, 4, vImageFlatten_ARGB8888(&s8, &d, bg8, pm, 0));
        T1(Flatten_RGBA8888, d, 4, vImageFlatten_RGBA8888(&s8, &d, bg8, pm, 0));
        T1(Flatten_ARGB16U, d, 8, vImageFlatten_ARGB16U(&s16U, &d, bg16, pm, 0));
        T1(Flatten_RGBA16U, d, 8, vImageFlatten_RGBA16U(&s16U, &d, bg16, pm, 0));
        T1(Flatten_ARGB16Q12, d, 8, vImageFlatten_ARGB16Q12(&sQ12, &d, bgQ, pm, 0));
        T1(Flatten_RGBA16Q12, d, 8, vImageFlatten_RGBA16Q12(&sQ12, &d, bgQ, pm, 0));
        T1(Flatten_ARGBFFFF, d, 16, vImageFlatten_ARGBFFFF(&sF, &d, bgF, pm, 0));
        T1(Flatten_RGBAFFFF, d, 16, vImageFlatten_RGBAFFFF(&sF, &d, bgF, pm, 0));
        T1(Flatten_RGBA8888ToRGB888, d, 3, vImageFlatten_RGBA8888ToRGB888(&s8, &d, bg8, pm, 0));
        T1(Flatten_BGRA8888ToRGB888, d, 3, vImageFlatten_BGRA8888ToRGB888(&s8, &d, bg8, pm, 0));
        T1(Flatten_ARGBFFFFToRGBFFF, d, 12, vImageFlatten_ARGBFFFFToRGBFFF(&sF, &d, bgF, pm, 0));
        T1(Flatten_RGBAFFFFToRGBFFF, d, 12, vImageFlatten_RGBAFFFFToRGBFFF(&sF, &d, bgF, pm, 0));
        T1(Flatten_BGRAFFFFToRGBFFF, d, 12, vImageFlatten_BGRAFFFFToRGBFFF(&sF, &d, bgF, pm, 0));
    }

    T1(PermuteChannels_ARGB8888, d, 4, vImagePermuteChannels_ARGB8888(&s8, &d, perm, 0));
    T1(PermuteChannels_ARGB16U, d, 8, vImagePermuteChannels_ARGB16U(&s16U, &d, perm, 0));
    T1(PermuteChannels_ARGBFFFF, d, 16, vImagePermuteChannels_ARGBFFFF(&sF, &d, perm, 0));
    T1(PermuteChannels_ARGB16F, d, 8, vImagePermuteChannels_ARGB16F(&sHalf, &d, perm, 0));
    T1(PermuteChannels_RGB888, d, 3, vImagePermuteChannels_RGB888(&s8, &d, perm3, 0));
    T1(PermuteMaskedInsert_ARGB8888, d, 4, vImagePermuteChannelsWithMaskedInsert_ARGB8888(&s8, &d, perm, 0x5, bg8, 0));
    T1(PermuteMaskedInsert_ARGB16U, d, 8,
       vImagePermuteChannelsWithMaskedInsert_ARGB16U(&s16U, &d, perm, 0xa, bg16, 0));
    T1(PermuteMaskedInsert_ARGBFFFF, d, 16,
       vImagePermuteChannelsWithMaskedInsert_ARGBFFFF(&sF, &d, perm, 0x3, bgF, 0));
    T1(OverwriteChannels_ARGB8888, d, 4, vImageOverwriteChannels_ARGB8888(&s8b, &s8, &d, 0x9, 0));
    T1(OverwriteChannels_ARGBFFFF, d, 16, vImageOverwriteChannels_ARGBFFFF(&sFb, &sF, &d, 0x6, 0));
    T1(SelectChannels_ARGB8888, d, 4, vImageSelectChannels_ARGB8888(&s8b, &s8, &d, 0x5, 0));
    T1(SelectChannels_ARGBFFFF, d, 16, vImageSelectChannels_ARGBFFFF(&sFb, &sF, &d, 0xa, 0));
    T1(OverwriteScalar_ARGB8888, d, 4, vImageOverwriteChannelsWithScalar_ARGB8888(42, &s8, &d, 0x3, 0));
    T1(OverwriteScalar_ARGBFFFF, d, 16, vImageOverwriteChannelsWithScalar_ARGBFFFF(0.125f, &sF, &d, 0xc, 0));
    T1(OverwritePixel_ARGB8888, d, 4, vImageOverwriteChannelsWithPixel_ARGB8888(bg8, &s8, &d, 0x6, 0));
    T1(OverwritePixel_ARGB16U, d, 8, vImageOverwriteChannelsWithPixel_ARGB16U(bg16, &s16U, &d, 0x9, 0));
    T1(OverwritePixel_ARGBFFFF, d, 16, vImageOverwriteChannelsWithPixel_ARGBFFFF(bgF, &sF, &d, 0x5, 0));
    T1(OverwriteScalar_Planar8, d, 1, vImageOverwriteChannelsWithScalar_Planar8(17, &d, 0));
    T1(OverwriteScalar_PlanarF, d, 4, vImageOverwriteChannelsWithScalar_PlanarF(0.3f, &d, 0));
    T1(OverwriteScalar_Planar16S, d, 2, vImageOverwriteChannelsWithScalar_Planar16S(-5, &d, 0));
    T1(OverwriteScalar_Planar16U, d, 2, vImageOverwriteChannelsWithScalar_Planar16U(50000, &d, 0));
    T1(OverwriteScalar_Planar16F, d, 2, vImageOverwriteChannelsWithScalar_Planar16F(0x3c00, &d, 0));
    T1(BufferFill_ARGB8888, d, 4, vImageBufferFill_ARGB8888(&d, bg8, 0));
    T1(BufferFill_ARGB16U, d, 8, vImageBufferFill_ARGB16U(&d, bg16, 0));
    T1(BufferFill_ARGB16S, d, 8, vImageBufferFill_ARGB16S(&d, bgQ, 0));
    T1(BufferFill_ARGBFFFF, d, 16, vImageBufferFill_ARGBFFFF(&d, bgF, 0));
    T1(BufferFill_ARGB16F, d, 8, vImageBufferFill_ARGB16F(&d, (Pixel_ARGB_16F){0x3c00, 0x3800, 0, 0xbc00}, 0));
    T1(BufferFill_CbCr8, d, 2, vImageBufferFill_CbCr8(&d, (Pixel_88){10, 240}, 0));
    T1(BufferFill_CbCr16U, d, 4, vImageBufferFill_CbCr16U(&d, (Pixel_16U16U){1000, 64000}, 0));
    T1(BufferFill_CbCr16S, d, 4, vImageBufferFill_CbCr16S(&d, (Pixel_16S16S){-1000, 2000}, 0));
    T1(ExtractChannel_ARGB8888, d, 1, vImageExtractChannel_ARGB8888(&s8, &d, 2, 0));
    T1(ExtractChannel_ARGB16U, d, 2, vImageExtractChannel_ARGB16U(&s16U, &d, 1, 0));
    T1(ExtractChannel_ARGBFFFF, d, 4, vImageExtractChannel_ARGBFFFF(&sF, &d, 3, 0));
    T1(CopyBuffer, d, 6, vImageCopyBuffer(&s8, &d, 6, 0));
    T1(ARGB16UToARGB8888, d, 4, vImageConvert_ARGB16UToARGB8888(&s16U, &d, perm, 0x2, bg8, 0));
    T1(ARGB8888ToARGB16U, d, 8, vImageConvert_ARGB8888ToARGB16U(&s8, &d, perm, 0x8, bg16, 0));
    T1(RGB16UToARGB8888, d, 4, vImageConvert_RGB16UToARGB8888(&s16U, &d, (uint8_t[]){0, 3, 1, 2}, 0x1, bg8, 0));
    T1(ARGB8888ToRGB16U, d, 6, vImageConvert_ARGB8888ToRGB16U(&s8, &d, perm3, 0x2, bg3, 0));

    TN(RGB888toPlanar16Q12, 3, 2, vImageConvert_RGB888toPlanar16Q12(&s8, &o[0], &o[1], &o[2], 0));
    TN(ARGB8888toPlanar16Q12, 4, 2, vImageConvert_ARGB8888toPlanar16Q12(&s8, &o[0], &o[1], &o[2], &o[3], 0));
    T1(Planar16Q12toRGB888, d, 3, vImageConvert_Planar16Q12toRGB888(&sQ12, &sQ12b, &sQ12c, &d, 0));
    T1(Planar16Q12toARGB8888, d, 4, vImageConvert_Planar16Q12toARGB8888(&sQ12, &sQ12b, &sQ12c, &sQ12d, &d, 0));
    T1(Planar16Q12toRGB16F, d, 6, vImageConvert_Planar16Q12toRGB16F(&sQ12, &sQ12b, &sQ12c, &d, 0));
    T1(Planar16Q12toARGB16F, d, 8, vImageConvert_Planar16Q12toARGB16F(&sQ12, &sQ12b, &sQ12c, &sQ12d, &d, 0));

    const Pixel_8 colors[16] = {3, 30, 60, 90, 120, 150, 180, 210, 240, 1, 2, 4, 8, 16, 32, 64};
    T1(Planar1toPlanar8, d, 1, vImageConvert_Planar1toPlanar8(&s8, &d, 0));
    T1(Planar2toPlanar8, d, 1, vImageConvert_Planar2toPlanar8(&s8, &d, 0));
    T1(Planar4toPlanar8, d, 1, vImageConvert_Planar4toPlanar8(&s8, &d, 0));
    T1(Indexed1toPlanar8, d, 1, vImageConvert_Indexed1toPlanar8(&s8, &d, colors, 0));
    T1(Indexed2toPlanar8, d, 1, vImageConvert_Indexed2toPlanar8(&s8, &d, colors, 0));
    T1(Indexed4toPlanar8, d, 1, vImageConvert_Indexed4toPlanar8(&s8, &d, colors, 0));
}

static void alpha(void)
{
    const uint8_t perm[4] = {1, 2, 3, 0};
    /* premultiplied inputs for the premultiplied blends (colour at most alpha): Apple's
       saturate invalid sums in their vector loops but wrap them in their scalar ones */
    vImage_Buffer pA = make(4, KZERO), pB = make(4, KZERO), pR = make(4, KZERO), pS = make(4, KZERO),
                  p8 = make(1, KZERO), p8c = make(1, KZERO);
    vImagePremultiplyData_ARGB8888(&s8, &pA, 0);
    vImagePremultiplyData_ARGB8888(&s8b, &pB, 0);
    vImagePremultiplyData_RGBA8888(&s8, &pR, 0);
    vImagePremultiplyData_RGBA8888(&s8b, &pS, 0);
    vImagePremultiplyData_Planar8(&s8, &s8b, &p8, 0);
    vImagePremultiplyData_Planar8(&s8c, &s8d, &p8c, 0);
    T1(PremultiplyData_Planar8, d, 1, vImagePremultiplyData_Planar8(&s8, &s8b, &d, 0));
    T1(PremultiplyData_PlanarF, d, 4, vImagePremultiplyData_PlanarF(&sF, &sFb, &d, 0));
    T1(UnpremultiplyData_Planar8, d, 1, vImageUnpremultiplyData_Planar8(&s8, &s8b, &d, 0));
    T1(UnpremultiplyData_PlanarF, d, 4, vImageUnpremultiplyData_PlanarF(&sF, &sFb, &d, 0));
    T1(ClipToAlpha_Planar8, d, 1, vImageClipToAlpha_Planar8(&s8, &s8b, &d, 0));
    T1(ClipToAlpha_PlanarF, d, 4, vImageClipToAlpha_PlanarF(&sF, &sFb, &d, 0));
    T1(PremultiplyData_ARGB8888, d, 4, vImagePremultiplyData_ARGB8888(&s8, &d, 0));
    T1(PremultiplyData_RGBA8888, d, 4, vImagePremultiplyData_RGBA8888(&s8, &d, 0));
    T1(PremultiplyData_ARGBFFFF, d, 16, vImagePremultiplyData_ARGBFFFF(&sF, &d, 0));
    T1(PremultiplyData_RGBAFFFF, d, 16, vImagePremultiplyData_RGBAFFFF(&sF, &d, 0));
    T1(PremultiplyData_ARGB16U, d, 8, vImagePremultiplyData_ARGB16U(&s16U, &d, 0));
    T1(PremultiplyData_RGBA16U, d, 8, vImagePremultiplyData_RGBA16U(&s16U, &d, 0));
    T1(PremultiplyData_ARGB16Q12, d, 8, vImagePremultiplyData_ARGB16Q12(&sQ12, &d, 0));
    T1(PremultiplyData_RGBA16Q12, d, 8, vImagePremultiplyData_RGBA16Q12(&sQ12, &d, 0));
    T1(PremultiplyData_RGBA16F, d, 8, vImagePremultiplyData_RGBA16F(&sHalf, &d, 0));
    T1(UnpremultiplyData_ARGB8888, d, 4, vImageUnpremultiplyData_ARGB8888(&s8, &d, 0));
    T1(UnpremultiplyData_RGBA8888, d, 4, vImageUnpremultiplyData_RGBA8888(&s8, &d, 0));
    T1(UnpremultiplyData_ARGBFFFF, d, 16, vImageUnpremultiplyData_ARGBFFFF(&sF, &d, 0));
    T1(UnpremultiplyData_RGBAFFFF, d, 16, vImageUnpremultiplyData_RGBAFFFF(&sF, &d, 0));
    T1(UnpremultiplyData_ARGB16U, d, 8, vImageUnpremultiplyData_ARGB16U(&s16U, &d, 0));
    T1(UnpremultiplyData_RGBA16U, d, 8, vImageUnpremultiplyData_RGBA16U(&s16U, &d, 0));
    TOLERANT(UnpremultiplyData_ARGB16Q12, 8, 2, vImageUnpremultiplyData_ARGB16Q12(&sQ12, &d, 0));
    TOLERANT(UnpremultiplyData_RGBA16Q12, 8, 2, vImageUnpremultiplyData_RGBA16Q12(&sQ12, &d, 0));
    T1(UnpremultiplyData_RGBA16F, d, 8, vImageUnpremultiplyData_RGBA16F(&sHalf, &d, 0));
    T1(ClipToAlpha_ARGB8888, d, 4, vImageClipToAlpha_ARGB8888(&s8, &d, 0));
    T1(ClipToAlpha_RGBA8888, d, 4, vImageClipToAlpha_RGBA8888(&s8, &d, 0));
    T1(ClipToAlpha_ARGBFFFF, d, 16, vImageClipToAlpha_ARGBFFFF(&sF, &d, 0));
    T1(ClipToAlpha_RGBAFFFF, d, 16, vImageClipToAlpha_RGBAFFFF(&sF, &d, 0));
    {
        /* the result alpha the planar non-premultiplied blends divide by */
        vImage_Buffer na = make(1, KZERO), naF = make(4, KZERO);
        for (vImagePixelCount y = 0; y < H; ++y)
            for (vImagePixelCount x = 0; x < W; ++x) {
                unsigned ta = ((uint8_t *)s8b.data)[y * s8b.rowBytes + x], ba = ((uint8_t *)s8d.data)[y * s8d.rowBytes + x];
                ((uint8_t *)na.data)[y * na.rowBytes + x] = (uint8_t)(ta + ((255 - ta) * ba + 127) / 255);
                float fta = ((float *)((uint8_t *)sFb.data + y * sFb.rowBytes))[x],
                      fba = ((float *)((uint8_t *)sFd.data + y * sFd.rowBytes))[x];
                ((float *)((uint8_t *)naF.data + y * naF.rowBytes))[x] = fta + (1 - fta) * fba;
            }
        T1(AlphaBlend_Planar8, d, 1, vImageAlphaBlend_Planar8(&s8, &s8b, &s8c, &s8d, &na, &d, 0));
        T1(AlphaBlend_PlanarF, d, 4, vImageAlphaBlend_PlanarF(&sF, &sFb, &sFc, &sFd, &naF, &d, 0));
        free(na.data);
        free(naF.data);
    }
    TOLERANT(AlphaBlend_ARGB8888, 4, 1, vImageAlphaBlend_ARGB8888(&s8, &s8b, &d, 0));
    T1(AlphaBlend_ARGBFFFF, d, 16, vImageAlphaBlend_ARGBFFFF(&sF, &sFb, &d, 0));
    T1(PremultipliedAlphaBlend_Planar8, d, 1, vImagePremultipliedAlphaBlend_Planar8(&p8, &s8b, &p8c, &d, 0));
    T1(PremultipliedAlphaBlend_PlanarF, d, 4, vImagePremultipliedAlphaBlend_PlanarF(&sF, &sFb, &sFc, &d, 0));
    T1(PremultipliedAlphaBlend_ARGB8888, d, 4, vImagePremultipliedAlphaBlend_ARGB8888(&pA, &pB, &d, 0));
    T1(PremultipliedAlphaBlend_BGRA8888, d, 4, vImagePremultipliedAlphaBlend_BGRA8888(&pR, &pS, &d, 0));
    T1(PremultipliedAlphaBlend_ARGBFFFF, d, 16, vImagePremultipliedAlphaBlend_ARGBFFFF(&sF, &sFb, &d, 0));
    T1(PremultipliedAlphaBlend_BGRAFFFF, d, 16, vImagePremultipliedAlphaBlend_BGRAFFFF(&sF, &sFb, &d, 0));
    T1(PremultipliedAlphaBlendMultiply, d, 4, vImagePremultipliedAlphaBlendMultiply_RGBA8888(&pR, &pS, &d, 0));
    T1(PremultipliedAlphaBlendScreen, d, 4, vImagePremultipliedAlphaBlendScreen_RGBA8888(&pR, &pS, &d, 0));
    T1(PremultipliedAlphaBlendDarken, d, 4, vImagePremultipliedAlphaBlendDarken_RGBA8888(&pR, &pS, &d, 0));
    T1(PremultipliedAlphaBlendLighten, d, 4, vImagePremultipliedAlphaBlendLighten_RGBA8888(&pR, &pS, &d, 0));
    T1(PremultipliedAlphaBlendWithPermute_ARGB8888, d, 4,
       vImagePremultipliedAlphaBlendWithPermute_ARGB8888(&pR, &pB, &d, perm, false, 0));
    T1(PremultipliedAlphaBlendWithPermute_RGBA8888, d, 4,
       vImagePremultipliedAlphaBlendWithPermute_RGBA8888(&pA, &pS, &d, perm, true, 0));
    T1(PremultipliedConstAlphaBlend_Planar8, d, 1,
       vImagePremultipliedConstAlphaBlend_Planar8(&p8, 200, &s8b, &p8c, &d, 0));
    T1(PremultipliedConstAlphaBlend_PlanarF, d, 4,
       vImagePremultipliedConstAlphaBlend_PlanarF(&sF, 0.75f, &sFb, &sFc, &d, 0));
    T1(PremultipliedConstAlphaBlend_ARGB8888, d, 4, vImagePremultipliedConstAlphaBlend_ARGB8888(&pA, 77, &pB, &d, 0));
    T1(PremultipliedConstAlphaBlend_ARGBFFFF, d, 16,
       vImagePremultipliedConstAlphaBlend_ARGBFFFF(&sF, 0.5f, &sFb, &d, 0));
    T1(NonpremultipliedToPremultiplied_Planar8, d, 1,
       vImageAlphaBlend_NonpremultipliedToPremultiplied_Planar8(&s8, &s8b, &p8c, &d, 0));
    T1(NonpremultipliedToPremultiplied_PlanarF, d, 4,
       vImageAlphaBlend_NonpremultipliedToPremultiplied_PlanarF(&sF, &sFb, &sFc, &d, 0));
    T1(NonpremultipliedToPremultiplied_ARGB8888, d, 4,
       vImageAlphaBlend_NonpremultipliedToPremultiplied_ARGB8888(&s8, &pB, &d, 0));
    T1(NonpremultipliedToPremultiplied_ARGBFFFF, d, 16,
       vImageAlphaBlend_NonpremultipliedToPremultiplied_ARGBFFFF(&sF, &sFb, &d, 0));
    free(pA.data);
    free(pB.data);
    free(pR.data);
    free(pS.data);
    free(p8.data);
    free(p8c.data);
}

int main(void)
{
    dump_name = getenv("VIMAGE_DUMP");
    s8 = make(16, K8);
    s8b = make(16, K8);
    s8c = make(16, K8);
    s8d = make(16, K8);
    sF = make(16, KF);
    sFb = make(16, KF);
    sFc = make(16, KF);
    sFd = make(16, KF);
    s16U = make(16, K16U);
    s16S = make(16, K16S);
    sHalf = make(16, KHALF);
    sQ12 = make(16, KQ12);
    sQ12b = make(16, KQ12);
    sQ12c = make(16, KQ12);
    sQ12d = make(16, KQ12);
    conversions();
    alpha();
    return 0;
}

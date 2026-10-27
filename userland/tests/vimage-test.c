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

static void show_histogram(const char *name, const vImagePixelCount *h, unsigned n)
{
    uint32_t hash = 2166136261u;
    for (unsigned i = 0; i < n; ++i)
        hash = (hash ^ (uint32_t)h[i]) * 16777619u;
    printf("%s: %08x\n", name, hash);
}

static void histograms_and_morphology(void)
{
    vImagePixelCount h[4][256];
    vImagePixelCount *hp[4] = {h[0], h[1], h[2], h[3]};
    vImageHistogramCalculation_Planar8(&s8, h[0], 0);
    show_histogram("HistogramCalculation_Planar8", h[0], 256);
    vImageHistogramCalculation_ARGB8888(&s8, hp, 0);
    for (int c = 0; c < 4; ++c)
        show_histogram("HistogramCalculation_ARGB8888", h[c], 256);
    vImageHistogramCalculation_PlanarF(&sF, h[0], 37, -0.1f, 1.1f, 0);
    show_histogram("HistogramCalculation_PlanarF", h[0], 37);
    vImageHistogramCalculation_ARGBFFFF(&sF, hp, 20, 0, 1, 0);
    for (int c = 0; c < 4; ++c)
        show_histogram("HistogramCalculation_ARGBFFFF", h[c], 20);
    vImagePixelCount want[4][256];
    const vImagePixelCount *wp[4] = {want[0], want[1], want[2], want[3]};
    for (int c = 0; c < 4; ++c)
        for (int i = 0; i < 256; ++i)
            want[c][i] = (vImagePixelCount)((i * (c + 3)) % 7 + (i > 128 ? 3 : 0));
    const unsigned pl[4] = {5, 0, 10, 30}, ph[4] = {5, 20, 0, 10};
    T1(Equalization_Planar8, d, 1, vImageEqualization_Planar8(&s8, &d, 0));
    T1(Equalization_ARGB8888, d, 4, vImageEqualization_ARGB8888(&s8, &d, 0));
    TOLERANT(HistogramSpecification_Planar8, 1, 1, vImageHistogramSpecification_Planar8(&s8, &d, want[0], 0));
    TOLERANT(HistogramSpecification_ARGB8888, 4, 1, vImageHistogramSpecification_ARGB8888(&s8, &d, wp, 0));
    T1(ContrastStretch_Planar8, d, 1, vImageContrastStretch_Planar8(&s8, &d, 0));
    T1(ContrastStretch_ARGB8888, d, 4, vImageContrastStretch_ARGB8888(&s8, &d, 0));
    T1(EndsInContrastStretch_Planar8, d, 1, vImageEndsInContrastStretch_Planar8(&s8, &d, 10, 20, 0));
    T1(EndsInContrastStretch_ARGB8888, d, 4, vImageEndsInContrastStretch_ARGB8888(&s8, &d, pl, ph, 0));
    T1(Equalization_PlanarF, d, 4, vImageEqualization_PlanarF(&sF, &d, NULL, 64, -0.2f, 1.2f, 0));
    T1(Equalization_ARGBFFFF, d, 16, vImageEqualization_ARGBFFFF(&sF, &d, NULL, 32, 0, 1, 0));
    /* (Apple's float specification picks a neighbouring bin for a few values; only the
       result code is compared) */
    {
        vImage_Buffer d = make(16, KZERO);
        printf("HistogramSpecification_PlanarF: %ld\n",
               (long)vImageHistogramSpecification_PlanarF(&sF, &d, NULL, want[1], 256, -0.2f, 1.2f, 0));
        printf("HistogramSpecification_ARGBFFFF: %ld\n",
               (long)vImageHistogramSpecification_ARGBFFFF(&sF, &d, NULL, wp, 256, 0, 1, 0));
        free(d.data);
    }
    T1(ContrastStretch_PlanarF, d, 4, vImageContrastStretch_PlanarF(&sF, &d, NULL, 64, 0, 1, 0));
    TOLERANT(ContrastStretch_ARGBFFFF, 16, 4, vImageContrastStretch_ARGBFFFF(&sF, &d, NULL, 64, -1, 2, 0));
    TOLERANT(EndsInContrastStretch_PlanarF, 4, 4,
             vImageEndsInContrastStretch_PlanarF(&sF, &d, NULL, 10, 20, 64, -0.2f, 1.2f, 0));
    TOLERANT(EndsInContrastStretch_ARGBFFFF, 16, 4,
             vImageEndsInContrastStretch_ARGBFFFF(&sF, &d, NULL, pl, ph, 50, 0, 1, 0));

    const unsigned char k8[15] = {0, 3, 9, 1, 0, 4, 2, 5, 0, 7, 0, 1, 2, 3, 4};
    const float kF[15] = {0, 0.25f, 0.5f, 0.125f, 0, 0.75f, 0.0625f, 0.375f, 0, 0.5f, 0, 0.125f, 0.25f, 0.375f, 0.5f};
    vImage_Buffer small8 = s8, smallF = sF;
    T1(Dilate_Planar8, d, 1, vImageDilate_Planar8(&small8, &d, 0, 0, k8, 3, 5, 0));
    T1(Dilate_PlanarF, d, 4, vImageDilate_PlanarF(&smallF, &d, 0, 0, kF, 5, 3, 0));
    T1(Dilate_ARGB8888, d, 4, vImageDilate_ARGB8888(&small8, &d, 0, 0, k8, 3, 5, 0));
    /* (Apple's ARGBFFFF dilate and erode read past the source's right edge, so these keep
       the kernel inside it) */
    {
        vImage_Buffer d = make(16, KZERO);
        d.width = W - 4;
        size_t bpp = 16;
        vImage_Error e = vImageDilate_ARGBFFFF(&smallF, &d, 2, 0, kF, 3, 5, 0);
        report("Dilate_ARGBFFFF", e, 1, &d, &bpp);
        e = vImageErode_ARGBFFFF(&smallF, &d, 2, 0, kF, 5, 3, 0);
        report("Erode_ARGBFFFF", e, 1, &d, &bpp);
        free(d.data);
    }
    T1(Erode_Planar8, d, 1, vImageErode_Planar8(&small8, &d, 0, 0, k8, 5, 3, 0));
    T1(Erode_PlanarF, d, 4, vImageErode_PlanarF(&smallF, &d, 0, 0, kF, 3, 5, 0));
    T1(Erode_ARGB8888, d, 4, vImageErode_ARGB8888(&small8, &d, 0, 0, k8, 5, 3, 0));
    T1(Max_Planar8, d, 1, vImageMax_Planar8(&small8, &d, NULL, 0, 0, 3, 5, 0));
    T1(Max_PlanarF, d, 4, vImageMax_PlanarF(&smallF, &d, NULL, 0, 0, 5, 3, 0));
    T1(Max_ARGB8888, d, 4, vImageMax_ARGB8888(&small8, &d, NULL, 0, 0, 3, 3, 0));
    T1(Max_ARGBFFFF, d, 16, vImageMax_ARGBFFFF(&smallF, &d, NULL, 0, 0, 1, 5, 0));
    T1(Min_Planar8, d, 1, vImageMin_Planar8(&small8, &d, NULL, 0, 0, 3, 5, 0));
    T1(Min_PlanarF, d, 4, vImageMin_PlanarF(&smallF, &d, NULL, 0, 0, 5, 3, 0));
    T1(Min_ARGB8888, d, 4, vImageMin_ARGB8888(&small8, &d, NULL, 0, 0, 3, 3, 0));
    T1(Min_ARGBFFFF, d, 16, vImageMin_ARGBFFFF(&smallF, &d, NULL, 0, 0, 5, 1, 0));
    {
        /* a tile: the ROI offset into a larger source */
        vImage_Buffer d = make(1, KZERO);
        d.width = 6;
        d.height = 3;
        size_t bpp = 1;
        vImage_Error e = vImageMax_Planar8(&s8, &d, NULL, 4, 1, 3, 3, 0);
        report("Max_Planar8-tile", e, 1, &d, &bpp);
        e = vImageDilate_Planar8(&s8, &d, 5, 2, k8, 3, 5, 0);
        report("Dilate_Planar8-tile", e, 1, &d, &bpp);
        free(d.data);
    }
}

static void convolutions(void)
{
    static const vImage_Flags edges[4] = {kvImageCopyInPlace, kvImageBackgroundColorFill, kvImageEdgeExtend,
                                          kvImageTruncateKernel};
    static const char *edgeNames[4] = {"copy", "background", "extend", "truncate"};
    const int16_t k8[15] = {1, 2, 3, 2, 1, 2, -4, 9, -4, 2, 1, 2, 3, 2, 1};
    const float kF[15] = {0.0625f, 0.125f, 0.1875f, 0.125f, 0.0625f, 0.125f, -0.25f, 0.5625f,
                          -0.25f, 0.125f, 0.0625f, 0.125f, 0.1875f, 0.125f, 0.0625f};
    const int16_t *k8s[4] = {k8, k8, k8, k8};
    const float *kFs[4] = {kF, kF, kF, kF};
    const int32_t divs[4] = {21, 7, 1, 30}, biases[4] = {10, -50, 0, 300};
    const float fbiases[4] = {0.125f, -0.25f, 0, 0.5f};
    const Pixel_8888 bg8 = {9, 99, 199, 255};
    const Pixel_FFFF bgF = {0.25f, 0.5f, 0.75f, 1};
    const Pixel_ARGB_16F bgH = {0x3400, 0x3800, 0x3a00, 0x3c00};
    const float kx[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f}, ky[3] = {0.25f, 0.5f, 0.25f};
    for (int m = 0; m < 4; ++m) {
        vImage_Flags f = edges[m];
        printf("edges: %s\n", edgeNames[m]);
        T1(Convolve_Planar8, d, 1, vImageConvolve_Planar8(&s8, &d, NULL, 0, 0, k8, 3, 5, 21, 7, f));
        T1(ConvolveWithBias_Planar8, d, 1, vImageConvolveWithBias_Planar8(&s8, &d, NULL, 0, 0, k8, 5, 3, 21, 100, 7, f));
        T1(Convolve_ARGB8888, d, 4, vImageConvolve_ARGB8888(&s8, &d, NULL, 0, 0, k8, 3, 5, 21, bg8, f));
        T1(ConvolveWithBias_ARGB8888, d, 4, vImageConvolveWithBias_ARGB8888(&s8, &d, NULL, 0, 0, k8, 5, 3, 21, -300, bg8, f));
        T1(ConvolveMultiKernel_ARGB8888, d, 4,
           vImageConvolveMultiKernel_ARGB8888(&s8, &d, NULL, 0, 0, k8s, 3, 5, divs, biases, bg8, f));
        T1(Convolve_PlanarF, d, 4, vImageConvolve_PlanarF(&sF, &d, NULL, 0, 0, kF, 3, 5, 0.5f, f));
        T1(ConvolveWithBias_PlanarF, d, 4, vImageConvolveWithBias_PlanarF(&sF, &d, NULL, 0, 0, kF, 5, 3, 0.25f, 0.5f, f));
        T1(Convolve_ARGBFFFF, d, 16, vImageConvolve_ARGBFFFF(&sF, &d, NULL, 0, 0, kF, 3, 5, bgF, f));
        T1(ConvolveWithBias_ARGBFFFF, d, 16, vImageConvolveWithBias_ARGBFFFF(&sF, &d, NULL, 0, 0, kF, 5, 3, -0.125f, bgF, f));
        T1(ConvolveMultiKernel_ARGBFFFF, d, 16,
           vImageConvolveMultiKernel_ARGBFFFF(&sF, &d, NULL, 0, 0, kFs, 3, 5, fbiases, bgF, f));
        T1(Convolve_Planar16F, d, 2, vImageConvolve_Planar16F(&sHalf, &d, NULL, 0, 0, kF, 3, 5, 0x3800, f));
        T1(ConvolveWithBias_Planar16F, d, 2, vImageConvolveWithBias_Planar16F(&sHalf, &d, NULL, 0, 0, kF, 5, 3, 0.25f, 0, f));
        T1(Convolve_ARGB16F, d, 8, vImageConvolve_ARGB16F(&sHalf, &d, NULL, 0, 0, kF, 3, 5, bgH, f));
        T1(ConvolveWithBias_ARGB16F, d, 8, vImageConvolveWithBias_ARGB16F(&sHalf, &d, NULL, 0, 0, kF, 5, 3, 0.5f, bgH, f));
        T1(ConvolveFloatKernel_ARGB8888, d, 4, vImageConvolveFloatKernel_ARGB8888(&s8, &d, NULL, 0, 0, kF, 3, 5, 3.5f, bg8, f));
        T1(BoxConvolve_Planar8, d, 1, vImageBoxConvolve_Planar8(&s8, &d, NULL, 0, 0, 3, 5, 77, f));
        T1(BoxConvolve_ARGB8888, d, 4, vImageBoxConvolve_ARGB8888(&s8, &d, NULL, 0, 0, 5, 3, bg8, f));
        T1(TentConvolve_Planar8, d, 1, vImageTentConvolve_Planar8(&s8, &d, NULL, 0, 0, 3, 5, 77, f));
        T1(TentConvolve_ARGB8888, d, 4, vImageTentConvolve_ARGB8888(&s8, &d, NULL, 0, 0, 5, 3, bg8, f));
        T1(SepConvolve_Planar8, d, 1, vImageSepConvolve_Planar8(&s8, &d, NULL, 0, 0, kx, 5, ky, 3, 0.25f, 50, f));
        T1(SepConvolve_PlanarF, d, 4, vImageSepConvolve_PlanarF(&sF, &d, NULL, 0, 0, kx, 5, ky, 3, 0.125f, 0.5f, f));
        T1(SepConvolve_Planar16F, d, 2, vImageSepConvolve_Planar16F(&sHalf, &d, NULL, 0, 0, kx, 5, ky, 3, 0, 0x3800, f));
        T1(SepConvolve_Planar16U, d, 2, vImageSepConvolve_Planar16U(&s16U, &d, NULL, 0, 0, kx, 5, ky, 3, 100, 1000, f));
        T1(SepConvolve_Planar8to16U, d, 2,
           vImageSepConvolve_Planar8to16U(&s8, &d, NULL, 0, 0, kx, 5, ky, 3, 257, 0.5f, 20, f));
        T1(SepConvolve_ARGB8888, d, 4, vImageSepConvolve_ARGB8888(&s8, &d, NULL, 0, 0, kx, 5, ky, 3, -2, bg8, f));
    }
    {
        /* a tile, offset into the source */
        vImage_Buffer d = make(1, KZERO);
        d.width = 7;
        d.height = 3;
        size_t bpp = 1;
        vImage_Error e = vImageConvolve_Planar8(&s8, &d, NULL, 3, 1, k8, 3, 5, 21, 0, kvImageEdgeExtend);
        report("Convolve_Planar8-tile", e, 1, &d, &bpp);
        printf("Convolve no edge flag: %ld\n", (long)vImageConvolve_Planar8(&s8, &d, NULL, 0, 0, k8, 3, 5, 21, 0, 0));
        printf("Convolve two edge flags: %ld\n",
               (long)vImageConvolve_Planar8(&s8, &d, NULL, 0, 0, k8, 3, 5, 21, 0, kvImageEdgeExtend | kvImageCopyInPlace));
        printf("Convolve even kernel: %ld\n", (long)vImageConvolve_Planar8(&s8, &d, NULL, 0, 0, k8, 2, 5, 21, 0, kvImageEdgeExtend));
        free(d.data);
    }
    const float psf[9] = {0.0625f, 0.125f, 0.0625f, 0.125f, 0.25f, 0.125f, 0.0625f, 0.125f, 0.0625f};
    const int16_t psf8[9] = {1, 2, 1, 2, 4, 2, 1, 2, 1};
    TOLERANT(RichardsonLucy_PlanarF, 4, 4,
             vImageRichardsonLucyDeConvolve_PlanarF(&sF, &d, NULL, 0, 0, psf, NULL, 3, 3, 0, 0, 0, 3, kvImageEdgeExtend));
    TOLERANT(RichardsonLucy_ARGBFFFF, 16, 4,
             vImageRichardsonLucyDeConvolve_ARGBFFFF(&sF, &d, NULL, 0, 0, psf, psf, 3, 3, 3, 3, bgF, 2, kvImageEdgeExtend));
    TOLERANT(RichardsonLucy_Planar8, 1, 1,
             vImageRichardsonLucyDeConvolve_Planar8(&s8, &d, NULL, 0, 0, psf8, NULL, 3, 3, 0, 0, 16, 0, 0, 2, kvImageEdgeExtend));
    TOLERANT(RichardsonLucy_ARGB8888, 4, 1,
             vImageRichardsonLucyDeConvolve_ARGB8888(&s8, &d, NULL, 0, 0, psf8, psf8, 3, 3, 3, 3, 16, 16, bg8, 1, kvImageEdgeExtend));
}

static void transforms(void)
{
    const int16_t m16[16] = {256, 0, 30, -40, 10, 200, -60, 70, 0, 25, 180, 90, -20, 15, 5, 300};
    const float mF[16] = {1, 0, 0.25f, -0.5f, 0.125f, 0.75f, -0.25f, 0.5f, 0, 0.25f, 0.5f, 0.375f, -0.125f, 0.125f, 0.0625f, 1};
    const int16_t pre16[4] = {0, -16, -128, 5};
    const int32_t post32[4] = {128, 4224, -500, 32896};
    const float preF[4] = {0, -0.125f, 0.25f, 0}, postF[4] = {0.5f, 0, -0.25f, 0.125f};
    T1(MatrixMultiply_ARGB8888, d, 4, vImageMatrixMultiply_ARGB8888(&s8, &d, m16, 256, pre16, post32, 0));
    T1(MatrixMultiply_ARGB8888-nullbias, d, 4, vImageMatrixMultiply_ARGB8888(&s8, &d, m16, 300, NULL, NULL, 0));
    T1(MatrixMultiply_ARGBFFFF, d, 16, vImageMatrixMultiply_ARGBFFFF(&sF, &d, mF, preF, postF, 0));
    T1(MatrixMultiply_ARGB8888ToPlanar8, d, 1,
       vImageMatrixMultiply_ARGB8888ToPlanar8(&s8, &d, m16, 300, pre16, 150, 0));
    T1(MatrixMultiply_ARGBFFFFToPlanarF, d, 4, vImageMatrixMultiply_ARGBFFFFToPlanarF(&sF, &d, mF, preF, 0.5f, 0));
    {
        const vImage_Buffer *srcs8[3] = {&s8, &s8b, &s8c}, *srcsF[3] = {&sF, &sFb, &sFc}, *srcs16[3] = {&sQ12, &sQ12b, &sQ12c};
        /* (Apple's PlanarF and Planar16S read the pre-bias's matrix terms past a non-square
           matrix; a zero last pre-bias keeps those terms out) */
        const int16_t pre3[3] = {7, -16, 0};
        const float preF3[3] = {0.125f, -0.25f, 0};
        TN(MatrixMultiply_Planar8, 2, 1, vImageMatrixMultiply_Planar8(srcs8, (const vImage_Buffer *[]){&o[0], &o[1]}, 3, 2, m16, 100, pre16, NULL, 0));
        TN(MatrixMultiply_PlanarF, 2, 4, vImageMatrixMultiply_PlanarF(srcsF, (const vImage_Buffer *[]){&o[0], &o[1]}, 3, 2, mF, preF3, postF, 0));
        TN(MatrixMultiply_Planar16S, 2, 2, vImageMatrixMultiply_Planar16S(srcs16, (const vImage_Buffer *[]){&o[0], &o[1]}, 3, 2, m16, 64, pre3, post32, 0));
    }

    for (int t = 0; t < 12; ++t) {
        GammaFunction g = vImageCreateGammaFunction(t < 2 ? 1.7f : 0, t, 0);
        char name[64];
        snprintf(name, sizeof(name), "Gamma type %d", t);
        vImage_Buffer d1 = make(4, KZERO), d2 = make(1, KZERO), d3 = make(4, KZERO);
        vImage_Error e1 = vImageGamma_Planar8toPlanarF(&s8, &d1, g, 0), e2 = vImageGamma_PlanarFtoPlanar8(&sF, &d2, g, 0),
                     e3 = vImageGamma_PlanarF(&sF, &d3, g, 0);
        /* (the fixed-exponent half-precision gammas are Apple's polynomial approximations;
           only their result codes are compared) */
        if (t < 2)
            printf("%s (coarse): %ld %ld %ld %ld %ld %ld\n", name, (long)e1, coarse(&d1, 4, 4), (long)e2,
                   coarse(&d2, 1, 1), (long)e3, coarse(&d3, 4, 4));
        else
            printf("%s: %ld %ld %ld\n", name, (long)e1, (long)e2, (long)e3);
        vImageDestroyGammaFunction(g);
        free(d1.data);
        free(d2.data);
        free(d3.data);
    }

    const float ec[3] = {1.0f / 1.055f, 0.055f / 1.055f, 0}, lc[2] = {1.0f / 12.92f, 0};
    TOLERANT(PiecewiseGamma_Planar8, 1, 1, vImagePiecewiseGamma_Planar8(&s8, &d, ec, 2.4f, lc, 10, 0));
    TOLERANT(PiecewiseGamma_Planar8toPlanar16Q12, 2, 2, vImagePiecewiseGamma_Planar8toPlanar16Q12(&s8, &d, ec, 2.4f, lc, 10, 0));
    TOLERANT(PiecewiseGamma_Planar8toPlanarF, 4, 4, vImagePiecewiseGamma_Planar8toPlanarF(&s8, &d, ec, 2.4f, lc, 10, 0));
    TOLERANT(PiecewiseGamma_Planar16Q12, 2, 2, vImagePiecewiseGamma_Planar16Q12(&sQ12, &d, ec, 2.4f, lc, 160, 0));
    TOLERANT(PiecewiseGamma_Planar16Q12toPlanar8, 1, 1, vImagePiecewiseGamma_Planar16Q12toPlanar8(&sQ12, &d, ec, 2.4f, lc, 160, 0));
    TOLERANT(PiecewiseGamma_PlanarF, 4, 4, vImagePiecewiseGamma_PlanarF(&sF, &d, ec, 2.4f, lc, 0.04f, 0));
    TOLERANT(PiecewiseGamma_PlanarFtoPlanar8, 1, 1, vImagePiecewiseGamma_PlanarFtoPlanar8(&sF, &d, ec, 2.4f, lc, 0.04f, 0));
    TOLERANT(SymmetricPiecewiseGamma_PlanarF, 4, 4, vImageSymmetricPiecewiseGamma_PlanarF(&sF, &d, ec, 2.4f, lc, 0.04f, 0));
    TOLERANT(SymmetricPiecewiseGamma_Planar16Q12, 2, 2,
             vImageSymmetricPiecewiseGamma_Planar16Q12(&sQ12, &d, ec, 2.4f, lc, 160, 0));

    const float c0[3] = {0.5f, 0.25f, 0.125f}, c1[3] = {-0.25f, 1, 0.5f}, c2[3] = {1, -0.5f, 0.25f}, c3[3] = {0, 0.125f, 1};
    const float *coefs[4] = {c0, c1, c2, c3};
    const float bounds[5] = {-0.125f, 0.25f, 0.5f, 0.75f, 1.125f}, bounds8[5] = {0, 64, 128, 192, 255};
    T1(PiecewisePolynomial_PlanarF, d, 4, vImagePiecewisePolynomial_PlanarF(&sF, &d, coefs, bounds, 2, 2, 0));
    T1(PiecewisePolynomial_Planar8toPlanarF, d, 4, vImagePiecewisePolynomial_Planar8toPlanarF(&s8, &d, coefs, bounds8, 2, 2, 0));
    TOLERANT(PiecewisePolynomial_PlanarFtoPlanar8, 1, 1, vImagePiecewisePolynomial_PlanarFtoPlanar8(&sF, &d, coefs, bounds, 2, 2, 0));
    T1(SymmetricPiecewisePolynomial_PlanarF, d, 4, vImageSymmetricPiecewisePolynomial_PlanarF(&sF, &d, coefs, bounds, 2, 2, 0));
    const float t0[2] = {1, 0.5f}, b0[2] = {2, 0.25f};
    const float *tops[1] = {t0}, *bots[1] = {b0};
    const float bounds1[2] = {-0.5f, 1.5f};
    TOLERANT(PiecewiseRational_PlanarF, 4, 4, vImagePiecewiseRational_PlanarF(&sF, &d, tops, bots, bounds1, 1, 1, 0, 0));

    Pixel_16U t16[256];
    Pixel_F tF[257];
    uint32_t t24[256];
    uint64_t t64[256];
    Pixel_FFFF t128[256];
    static Pixel_8 t4096[4096];
    static Pixel_16U t65536[65536];
    for (int i = 0; i < 256; ++i) {
        t16[i] = (Pixel_16U)(i * 251);
        tF[i] = (float)i / 64 - 1;
        t24[i] = 0x01020304u * (uint32_t)i;
        t64[i] = 0x0001000200030004ull * (uint64_t)(i + 1);
        for (int c = 0; c < 4; ++c)
            t128[i][c] = (float)(i * (c + 1)) / 8;
    }
    tF[256] = 3;
    for (int i = 0; i < 4096; ++i)
        t4096[i] = (Pixel_8)(i * 7 / 16);
    for (int i = 0; i < 65536; ++i)
        t65536[i] = (Pixel_16U)(65535 - i);
    T1(LookupTable_Planar8toPlanar16, d, 2, vImageLookupTable_Planar8toPlanar16(&s8, &d, t16, 0));
    T1(LookupTable_Planar8toPlanarF, d, 4, vImageLookupTable_Planar8toPlanarF(&s8, &d, tF, 0));
    T1(LookupTable_Planar8toPlanar24, d, 3, vImageLookupTable_Planar8toPlanar24(&s8, &d, t24, 0));
    T1(LookupTable_Planar8toPlanar48, d, 6, vImageLookupTable_Planar8toPlanar48(&s8, &d, t64, 0));
    T1(LookupTable_Planar8toPlanar96, d, 12, vImageLookupTable_Planar8toPlanar96(&s8, &d, t128, 0));
    T1(LookupTable_Planar8toPlanar128, d, 16, vImageLookupTable_Planar8toPlanar128(&s8, &d, t128, 0));
    T1(LookupTable_8to64U, d, 8, vImageLookupTable_8to64U(&s8, &d, t64, 0));
    T1(LookupTable_PlanarFtoPlanar8, d, 1, vImageLookupTable_PlanarFtoPlanar8(&sF, &d, t4096, 0));
    T1(LookupTable_Planar16, d, 2, vImageLookupTable_Planar16(&s16U, &d, t65536, 0));
    T1(InterpolatedLookupTable_PlanarF, d, 4, vImageInterpolatedLookupTable_PlanarF(&sF, &d, tF, 256, 1.0f, -0.125f, 0));

    {
        /* a 3D table of 5x5x5 with two outputs */
        static uint16_t table[5 * 5 * 5 * 2];
        for (int i = 0; i < 5 * 5 * 5 * 2; ++i)
            table[i] = (uint16_t)((i * 7919) % 65536);
        const uint8_t dims[3] = {5, 5, 5};
        vImage_Error err = 1;
        vImage_MultidimensionalTable mt = vImageMultidimensionalTable_Create(table, 3, 2, dims,
                                                                             kvImageMDTableHint_Float | kvImageMDTableHint_16Q12, 0, &err);
        printf("MultidimensionalTable_Create: %ld %d\n", (long)err, mt != NULL);
        const vImage_Buffer srcs[3] = {sF, sFb, sFc}, q12[3] = {sQ12, sQ12b, sQ12c};
        for (int m = 0; m < 3 && mt; ++m) {
            vImage_Buffer outs[2] = {make(4, KZERO), make(4, KZERO)}, outq[2] = {make(2, KZERO), make(2, KZERO)};
            vImage_Error e1 = vImageMultiDimensionalInterpolatedLookupTable_PlanarF(srcs, outs, NULL, mt, (vImage_InterpolationMethod)m, 0);
            vImage_Error e2 = vImageMultiDimensionalInterpolatedLookupTable_Planar16Q12(q12, outq, NULL, mt, (vImage_InterpolationMethod)m, 0);
            printf("MDLookup method %d (coarse): %ld %ld %ld %ld %ld %ld\n", m, (long)e1, coarse(&outs[0], 4, 4),
                   coarse(&outs[1], 4, 4), (long)e2, coarse(&outq[0], 2, 2), coarse(&outq[1], 2, 2));
            for (int i = 0; i < 2; ++i) {
                free(outs[i].data);
                free(outq[i].data);
            }
        }
        vImageMultidimensionalTable_Retain(mt);
        vImageMultidimensionalTable_Release(mt);
        vImageMultidimensionalTable_Release(mt);
    }

    {
        /* flood fill a coarse image with regions */
        vImage_Buffer img8 = make(1, KZERO), img16 = make(2, KZERO), img32 = make(4, KZERO), img64 = make(8, KZERO);
        for (vImagePixelCount y = 0; y < H; ++y)
            for (vImagePixelCount x = 0; x < W; ++x) {
                uint8_t v = (uint8_t)(((x / 3) + (y / 2)) % 3 == 0 || (x == y) ? 1 : 0);
                ((uint8_t *)img8.data)[y * img8.rowBytes + x] = v;
                ((uint16_t *)((uint8_t *)img16.data + y * img16.rowBytes))[x] = v;
                memset((uint8_t *)img32.data + y * img32.rowBytes + 4 * x, v, 4);
                memset((uint8_t *)img64.data + y * img64.rowBytes + 8 * x, v, 8);
            }
        size_t b1 = 1, b2 = 2, b4 = 4, b8 = 8;
        vImage_Error e = vImageFloodFill_Planar8(&img8, NULL, 0, 0, 9, 4, 0);
        report("FloodFill_Planar8", e, 1, &img8, &b1);
        /* (Apple's Planar16U fill writes the value's low byte twice in its 4-pixel vector
           stores, so only the result code is compared) */
        e = vImageFloodFill_Planar16U(&img16, NULL, 4, 2, 999, 8, 0);
        printf("FloodFill_Planar16U: %ld\n", (long)e);
        (void)b2;
        e = vImageFloodFill_ARGB8888(&img32, NULL, 12, 4, (Pixel_8888){1, 2, 3, 4}, 8, 0);
        report("FloodFill_ARGB8888", e, 1, &img32, &b4);
        e = vImageFloodFill_ARGB16U(&img64, NULL, 6, 1, (Pixel_ARGB_16U){5, 6, 7, 8}, 4, 0);
        report("FloodFill_ARGB16U", e, 1, &img64, &b8);
        printf("FloodFill connectivity 6: %ld\n", (long)vImageFloodFill_Planar8(&img8, NULL, 0, 0, 9, 6, 0));
        free(img8.data);
        free(img16.data);
        free(img32.data);
        free(img64.data);
    }
}

/* a w x h output, for the geometry functions */
static vImage_Buffer make_size(vImagePixelCount w, vImagePixelCount h, size_t bpp)
{
    vImage_Buffer b = {calloc(h * (w * bpp + 8), 1), h, w, w * bpp + 8};
    return b;
}

#define TD(name, w, h, BPP, call)                                                                        \
    do {                                                                                                 \
        vImage_Buffer d = make_size(w, h, BPP);                                                          \
        vImage_Error e = call;                                                                           \
        size_t bpp = BPP;                                                                                \
        report(name, e, 1, &d, &bpp);                                                                    \
        free(d.data);                                                                                    \
    } while (0)

/* Apple's 8- and 16-bit resamplers round their own way (fixed-point weights); their
   outputs are compared coarsely (16-bit ones in units of 1024) */
#define TDC(name, w, h, BPP, kind, call)                                                                 \
    do {                                                                                                 \
        vImage_Buffer d = make_size(w, h, BPP);                                                          \
        vImage_Error e = call;                                                                           \
        long c = coarse(&d, BPP, kind);                                                                  \
        printf("%s (coarse): %ld %ld\n", name, (long)e, kind == 2 ? lround(c / 16.0) : c);              \
        free(d.data);                                                                                    \
    } while (0)

/* resampled float outputs: Apple's arithmetic orders differ from Finch's in the last
   bits, so these print the sums of the samples, unweighted and weighted by column and
   by row (scaled by 7.3, so that sums of the dyadic test data never round from a tie) */
#define TDF(name, w, h, BPP, call)                                                                       \
    do {                                                                                                 \
        vImage_Buffer d = make_size(w, h, BPP);                                                          \
        vImage_Error e = call;                                                                           \
        double sum[3] = {0};                                                                             \
        for (vImagePixelCount y = 0; y < d.height; ++y)                                                  \
            for (size_t i = 0; i < d.width * (BPP) / 4; ++i) {                                           \
                double v = ((const float *)((const uint8_t *)d.data + y * d.rowBytes))[i];               \
                sum[0] += v, sum[1] += v * (double)(i * 4 / (BPP) + 1), sum[2] += v * (double)(y + 1);   \
            }                                                                                            \
        printf("%s (sums): %ld %ld %ld %ld\n", name, (long)e, lround(sum[0] * 7.3), lround(sum[1] * 7.3), \
               lround(sum[2] * 7.3));                                                                     \
        free(d.data);                                                                                    \
    } while (0)

static void geometry(void)
{
    char n[96];
    /* exact copies: reflections and quarter turns, in every format that has them */
#define EXACT(F, BPP, SRC, BG)                                                                           \
    TD("HorizontalReflect_" #F, W, H, BPP, vImageHorizontalReflect_##F(&SRC, &d, 0));                   \
    TD("VerticalReflect_" #F, W, H, BPP, vImageVerticalReflect_##F(&SRC, &d, 0));                       \
    for (uint8_t r = 0; r < 5; ++r) {                                                                    \
        snprintf(n, sizeof(n), "Rotate90_" #F " %d", r);                                                 \
        TD(n, W, H, BPP, vImageRotate90_##F(&SRC, &d, r, BG, 0));                                        \
        snprintf(n, sizeof(n), "Rotate90_" #F " %d turned", r);                                          \
        TD(n, H + 1, W - 2, BPP, vImageRotate90_##F(&SRC, &d, r, BG, 0));                                \
    }
    EXACT(Planar8, 1, s8, 7)
    EXACT(Planar16U, 2, s16U, 999)
    EXACT(PlanarF, 4, sF, 0.25f)
    EXACT(ARGB8888, 4, s8, ((Pixel_8888){1, 2, 3, 4}))
    EXACT(ARGB16U, 8, s16U, ((Pixel_ARGB_16U){1, 2, 3, 4}))
    EXACT(ARGB16S, 8, s16S, ((Pixel_ARGB_16S){1, -2, 3, -4}))
    EXACT(ARGBFFFF, 16, sF, ((Pixel_FFFF){0.5f, 0.25f, 0, 1}))
    EXACT(Planar16F, 2, sHalf, 0x3c00)
    EXACT(CbCr16F, 4, sHalf, ((Pixel_16F16F){0x3c00, 0x3800}))
    EXACT(ARGB16F, 8, sHalf, ((Pixel_ARGB_16F){0x3c00, 0x3800, 0, 0x3c00}))
#undef EXACT
    TD("Rotate90 bad constant", W, H, 1, vImageRotate90_Planar8(&s8, &d, 9, 0, 0));

    /* resampling filters */
    for (int i = 0; i < 6; ++i) {
        const float scales[6] = {2, 1, 0.75f, 0.45f, 0.3f, 0.1f};
        ResamplingFilter k = vImageNewResamplingFilter(scales[i], 0), hq = vImageNewResamplingFilter(scales[i], kvImageHighQualityResampling);
        printf("ResamplingFilterExtent %g: %lu %lu\n", scales[i], (unsigned long)vImageGetResamplingFilterExtent(k, 0),
               (unsigned long)vImageGetResamplingFilterExtent(hq, 0));
        vImageDestroyResamplingFilter(k);
        vImageDestroyResamplingFilter(hq);
    }

    /* shears: float exactly, the integer formats coarsely */
    const float filterScales[3] = {1, 0.6f, 1.7f};
    for (int i = 0; i < 3; ++i) {
        ResamplingFilter k = vImageNewResamplingFilter(filterScales[i], 0);
        ResamplingFilter hq = vImageNewResamplingFilter(filterScales[i], kvImageHighQualityResampling);
        vImage_Flags bg = kvImageBackgroundColorFill, ex = kvImageEdgeExtend;
        snprintf(n, sizeof(n), "HorizontalShear_PlanarF %d", i);
        TDF(n, W - 2, H - 1, 4, vImageHorizontalShear_PlanarF(&sF, &d, 1, 1, 1.25f, 0.3f, k, 0.5f, bg));
        snprintf(n, sizeof(n), "HorizontalShearD_PlanarF %d", i);
        TDF(n, W + 4, H, 4, vImageHorizontalShearD_PlanarF(&sF, &d, 0, 0, -0.7, -0.45, hq, 0.5f, ex));
        snprintf(n, sizeof(n), "VerticalShear_PlanarF %d", i);
        TDF(n, W - 3, H + 3, 4, vImageVerticalShear_PlanarF(&sF, &d, 2, 1, 0.75f, 0.2f, k, 0.5f, bg));
        snprintf(n, sizeof(n), "VerticalShearD_PlanarF %d", i);
        TDF(n, W, H - 2, 4, vImageVerticalShearD_PlanarF(&sF, &d, 0, 2, -1.1, -0.15, hq, 0.5f, ex));
        snprintf(n, sizeof(n), "HorizontalShear_ARGBFFFF %d", i);
        TDF(n, W, H, 16, vImageHorizontalShear_ARGBFFFF(&sF, &d, 0, 0, 0.6f, 0.4f, k, (Pixel_FFFF){1, 0, 0.5f, 0.25f}, bg));
        snprintf(n, sizeof(n), "VerticalShearD_ARGBFFFF %d", i);
        TDF(n, W, H, 16, vImageVerticalShearD_ARGBFFFF(&sF, &d, 0, 0, 0.6, -0.4, k, (Pixel_FFFF){1, 0, 0.5f, 0.25f}, ex));
        snprintf(n, sizeof(n), "HorizontalShear_Planar8 %d", i);
        TDC(n, W, H, 1, 1, vImageHorizontalShear_Planar8(&s8, &d, 0, 0, 1.25f, 0.3f, k, 7, bg));
        snprintf(n, sizeof(n), "VerticalShear_ARGB8888 %d", i);
        TDC(n, W, H, 4, 1, vImageVerticalShear_ARGB8888(&s8, &d, 0, 0, 0.75f, 0.2f, k, (Pixel_8888){1, 2, 3, 4}, ex));
        snprintf(n, sizeof(n), "HorizontalShearD_ARGB16S %d", i);
        TDC(n, W, H, 8, 2, vImageHorizontalShearD_ARGB16S(&sQ12, &d, 0, 0, 0.4, 0.1, k, (Pixel_ARGB_16S){1, 2, 3, 4}, bg));
        vImageDestroyResamplingFilter(k);
        vImageDestroyResamplingFilter(hq);
    }
    {
        ResamplingFilter k = vImageNewResamplingFilter(1, 0);
        TDF("HorizontalShear both edges", W, H, 4, vImageHorizontalShear_PlanarF(&sF, &d, 0, 0, 0, 0, k, 0, kvImageEdgeExtend | kvImageBackgroundColorFill));
        TDF("HorizontalShear ROI too tall", W, H, 4, vImageHorizontalShear_PlanarF(&sF, &d, 0, 1, 0, 0, k, 0, kvImageEdgeExtend));
        TDF("VerticalShear ROI too wide", W, H, 4, vImageVerticalShear_PlanarF(&sF, &d, 1, 0, 0, 0, k, 0, kvImageEdgeExtend));
        vImageDestroyResamplingFilter(k);
    }

    /* scaling */
    const int sizes[5][2] = {{7, 9}, {20, 3}, {W, H}, {26, 10}, {5, 2}};
    for (int i = 0; i < 5; ++i) {
        int w = sizes[i][0], h = sizes[i][1];
        snprintf(n, sizeof(n), "Scale_PlanarF %dx%d", w, h);
        TDF(n, w, h, 4, vImageScale_PlanarF(&sF, &d, NULL, 0));
        snprintf(n, sizeof(n), "Scale_PlanarF HQ %dx%d", w, h);
        TDF(n, w, h, 4, vImageScale_PlanarF(&sF, &d, NULL, kvImageHighQualityResampling));
        snprintf(n, sizeof(n), "Scale_ARGBFFFF %dx%d", w, h);
        TDF(n, w, h, 16, vImageScale_ARGBFFFF(&sF, &d, NULL, 0));
        snprintf(n, sizeof(n), "Scale_Planar8 %dx%d", w, h);
        TDC(n, w, h, 1, 1, vImageScale_Planar8(&s8, &d, NULL, 0));
        snprintf(n, sizeof(n), "Scale_ARGB8888 %dx%d", w, h);
        TDC(n, w, h, 4, 1, vImageScale_ARGB8888(&s8, &d, NULL, 0));
        snprintf(n, sizeof(n), "Scale_ARGB16S %dx%d", w, h);
        TDC(n, w, h, 8, 2, vImageScale_ARGB16S(&sQ12, &d, NULL, 0));
    }

    /* rotation */
    /* (not exact quarter turns: in single precision those leave Apple a residual turn of
       about 1e-8 radians, where its rounding of sample positions is its own) */
    const float angles[6] = {0, 0.4f, 1.2f, 2.0f, 3.0f, -1.0f};
    for (int i = 0; i < 6; ++i) {
        snprintf(n, sizeof(n), "Rotate_PlanarF %g", angles[i]);
        TDF(n, W, H, 4, vImageRotate_PlanarF(&sF, &d, NULL, angles[i], 0.5f, kvImageBackgroundColorFill));
        snprintf(n, sizeof(n), "Rotate_PlanarF %g extend", angles[i]);
        TDF(n, H + 2, W, 4, vImageRotate_PlanarF(&sF, &d, NULL, angles[i], 0.5f, kvImageEdgeExtend));
        snprintf(n, sizeof(n), "Rotate_ARGBFFFF %g", angles[i]);
        TDF(n, W, H, 16, vImageRotate_ARGBFFFF(&sF, &d, NULL, angles[i], (Pixel_FFFF){0, 1, 0.5f, 0}, kvImageBackgroundColorFill));
        snprintf(n, sizeof(n), "Rotate_Planar8 %g", angles[i]);
        TDC(n, W, H, 1, 1, vImageRotate_Planar8(&s8, &d, NULL, angles[i], 7, kvImageBackgroundColorFill));
        snprintf(n, sizeof(n), "Rotate_ARGB16U %g", angles[i]);
        TDC(n, W, H, 8, 2, vImageRotate_ARGB16U(&s16U, &d, NULL, angles[i], (Pixel_ARGB_16U){0, 9, 99, 999}, kvImageBackgroundColorFill));
    }

    /* perspective warps (Finch's affine warps agree with Apple's to about a level, so only
       their result codes are compared) */
    const vImage_PerpsectiveTransform warps[3] = {{1, 0, 0, 1, 2, 1, 0, 0, 1}, {1.3f, 0.2f, 0.1f, 0.7f, 0.5f, 0.3f, 0.01f, 0.02f, 1},
                                                  {1, 0, 0, 1, 0, 0, 0.02f, 0, 1}};
    for (int i = 0; i < 3; ++i)
        for (int interp = 0; interp < 2; ++interp) {
            snprintf(n, sizeof(n), "PerspectiveWarp_Planar8 %d %d", i, interp);
            TDC(n, W, H, 1, 1, vImagePerspectiveWarp_Planar8(&s8, &d, NULL, &warps[i], interp, 7, kvImageBackgroundColorFill));
            snprintf(n, sizeof(n), "PerspectiveWarp_ARGB8888 %d %d", i, interp);
            TDC(n, W, H, 4, 1, vImagePerspectiveWarp_ARGB8888(&s8, &d, NULL, &warps[i], interp, (Pixel_8888){1, 2, 3, 4}, kvImageEdgeExtend));
        }
    TD("PerspectiveWarp no edge flag", W, H, 1, vImagePerspectiveWarp_Planar8(&s8, &d, NULL, &warps[0], 0, 7, 0));
    {
        const vImage_AffineTransform t = {1, 0.2f, 0.1f, 1, 0.5f, -0.25f};
        vImage_Buffer d = make(4, KZERO);
        printf("AffineWarp_PlanarF: %ld\n", (long)vImageAffineWarp_PlanarF(&sF, &d, NULL, &t, 0, kvImageBackgroundColorFill));
        printf("AffineWarp both edges: %ld\n",
               (long)vImageAffineWarp_PlanarF(&sF, &d, NULL, &t, 0, kvImageBackgroundColorFill | kvImageEdgeExtend));
        free(d.data);
    }
    {
        const float from[4][2] = {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, to[4][2] = {{1, 2}, {12, 1}, {11, 9}, {2, 12}};
        vImage_PerpsectiveTransform t;
        vImage_Error e = vImageGetPerspectiveWarp(from, to, &t, 0);
        printf("GetPerspectiveWarp: %ld %.5g %.5g %.5g %.5g %.5g %.5g %.5g %.5g %.5g\n", (long)e, t.a, t.b, t.c, t.d, t.tx, t.ty,
               t.vx, t.vy, t.v);
    }
}

static void conversions_10bit(void)
{
    const uint8_t bgra[4] = {3, 2, 1, 0};
    const int32_t ranges[2][2] = {{0, 1023}, {64, 940}};
    char n[96];
    for (int r = 0; r < 2; ++r)
        for (int p = 0; p < 2; ++p) {
            int32_t lo = ranges[r][0], hi = ranges[r][1];
            const uint8_t *perm = p ? bgra : NULL;
#define C10(name, BPP, call)                                                                             \
    snprintf(n, sizeof(n), #name " %d %d", r, p);                                                        \
    TD(n, W, H, BPP, call)
            C10(RGBA1010102ToARGB8888, 4, vImageConvert_RGBA1010102ToARGB8888(&s8, &d, lo, hi, perm, 0));
            C10(RGBA1010102ToARGB16U, 8, vImageConvert_RGBA1010102ToARGB16U(&s8, &d, lo, hi, perm, 0));
            C10(RGBA1010102ToARGB16Q12, 8, vImageConvert_RGBA1010102ToARGB16Q12(&s8, &d, lo, hi, perm, 0));
            C10(ARGB8888ToRGBA1010102, 4, vImageConvert_ARGB8888ToRGBA1010102(&s8, &d, lo, hi, perm, 0));
            C10(ARGB16UToRGBA1010102, 4, vImageConvert_ARGB16UToRGBA1010102(&s16U, &d, lo, hi, perm, 0));
            C10(ARGB16Q12ToRGBA1010102, 4, vImageConvert_ARGB16Q12ToRGBA1010102(&sQ12, &d, lo, hi, 0, 1023, perm, 0));
            C10(ARGB16Q12ToRGBA1010102 clipped, 4, vImageConvert_ARGB16Q12ToRGBA1010102(&sQ12, &d, lo, hi, 16, 1000, perm, 0));
            C10(XRGB2101010ToARGB8888, 4, vImageConvert_XRGB2101010ToARGB8888(&s8, 200, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGB8888, 4, vImageConvert_ARGB2101010ToARGB8888(&s8, &d, lo, hi, perm, 0));
            C10(XRGB2101010ToARGB16U, 8, vImageConvert_XRGB2101010ToARGB16U(&s8, 40000, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGB16U, 8, vImageConvert_ARGB2101010ToARGB16U(&s8, &d, lo, hi, perm, 0));
            C10(XRGB2101010ToARGB16Q12, 8, vImageConvert_XRGB2101010ToARGB16Q12(&s8, 3000, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGB16Q12, 8, vImageConvert_ARGB2101010ToARGB16Q12(&s8, &d, lo, hi, perm, 0));
            C10(XRGB2101010ToARGBFFFF, 16, vImageConvert_XRGB2101010ToARGBFFFF(&s8, 0.75f, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGBFFFF, 16, vImageConvert_ARGB2101010ToARGBFFFF(&s8, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGBFFFF unclamped, 16, vImageConvert_ARGB2101010ToARGBFFFF(&s8, &d, lo, hi, perm, kvImageDoNotClamp));
            C10(XRGB2101010ToARGB16F, 8, vImageConvert_XRGB2101010ToARGB16F(&s8, 0.75f, &d, lo, hi, perm, 0));
            C10(ARGB2101010ToARGB16F, 8, vImageConvert_ARGB2101010ToARGB16F(&s8, &d, lo, hi, perm, 0));
            C10(ARGB8888ToXRGB2101010, 4, vImageConvert_ARGB8888ToXRGB2101010(&s8, &d, lo, hi, perm, 0));
            C10(ARGB8888ToARGB2101010, 4, vImageConvert_ARGB8888ToARGB2101010(&s8, &d, lo, hi, perm, 0));
            C10(ARGB16UToXRGB2101010, 4, vImageConvert_ARGB16UToXRGB2101010(&s16U, &d, lo, hi, perm, 0));
            C10(ARGB16UToARGB2101010, 4, vImageConvert_ARGB16UToARGB2101010(&s16U, &d, lo, hi, perm, 0));
            C10(ARGB16Q12ToXRGB2101010, 4, vImageConvert_ARGB16Q12ToXRGB2101010(&sQ12, &d, lo, hi, 0, 1023, perm, 0));
            C10(ARGB16Q12ToARGB2101010, 4, vImageConvert_ARGB16Q12ToARGB2101010(&sQ12, &d, lo, hi, 16, 1000, perm, 0));
            C10(ARGBFFFFToXRGB2101010, 4, vImageConvert_ARGBFFFFToXRGB2101010(&sF, &d, lo, hi, perm, 0));
            C10(ARGBFFFFToARGB2101010, 4, vImageConvert_ARGBFFFFToARGB2101010(&sF, &d, lo, hi, perm, 0));
            /* (out of range floats in video range: Apple's scalar tail rounds its own way) */
            if (r == 0) {
                C10(ARGBFFFFToARGB2101010 unclamped, 4, vImageConvert_ARGBFFFFToARGB2101010(&sF, &d, lo, hi, perm, kvImageDoNotClamp));
            }
#undef C10
        }
    TD("RGBA1010102ToARGB8888 inverted range", W, H, 4, vImageConvert_RGBA1010102ToARGB8888(&s8, &d, 900, 100, NULL, 0));
    TD("ARGB16Q12ToRGBA1010102 inverted clip", W, H, 4, vImageConvert_ARGB16Q12ToRGBA1010102(&sQ12, &d, 0, 1023, 900, 100, NULL, 0));
    TD("ARGB2101010ToARGB8888 range past 10 bits", W, H, 4, vImageConvert_ARGB2101010ToARGB8888(&s8, &d, 0, 2047, NULL, 0));
    TD("ARGB8888ToRGBA1010102 unknown flag", W, H, 4, vImageConvert_ARGB8888ToRGBA1010102(&s8, &d, 0, 1023, NULL, 0x100000));
}

/* the rest of Conversion.h's packing, dithering and sub-byte formats; ordered dithering
   adds each implementation's own blue noise, so only its result codes are compared */
static void conversions_dithered(void)
{
    const Pixel_FFFF maxF = {1, 1.25f, 0.75f, 1}, minF = {0, -0.25f, 0.125f, 0};
    TN(ARGB1555toPlanar8, 4, 1, vImageConvert_ARGB1555toPlanar8(&s8, &o[0], &o[1], &o[2], &o[3], 0));
    TN(XRGB8888ToPlanar8, 3, 1, vImageConvert_XRGB8888ToPlanar8(&s8, &o[0], &o[1], &o[2], 0));
    TN(XRGBFFFFToPlanarF, 3, 4, vImageConvert_XRGBFFFFToPlanarF(&sF, &o[0], &o[1], &o[2], 0));
    T1(Planar8ToARGBFFFF, d, 16, vImageConvert_Planar8ToARGBFFFF(&s8, &s8b, &s8c, &s8d, &d, maxF, minF, 0));
    T1(PlanarFToARGB8888, d, 4, vImageConvert_PlanarFToARGB8888(&sF, &sFb, &sFc, &sFd, &d, maxF, minF, 0));
    T1(RGB16UtoARGB16U, d, 8, vImageConvert_RGB16UtoARGB16U(&s16U, NULL, 40000, &d, false, 0));
    T1(RGB16UtoARGB16U alpha plane, d, 8, vImageConvert_RGB16UtoARGB16U(&s16U, &s16S, 0, &d, true, 0));
    T1(Flatten_ARGB8888ToRGB888, d, 3, vImageFlatten_ARGB8888ToRGB888(&s8, &d, (Pixel_8888){255, 10, 128, 240}, false, 0));
    T1(Flatten_ARGB8888ToRGB888 premultiplied, d, 3,
       vImageFlatten_ARGB8888ToRGB888(&s8, &d, (Pixel_8888){255, 10, 128, 240}, true, 0));

    const uint8_t bgra[4] = {3, 2, 1, 0};
    const Pixel_F max3[3] = {1, 1.25f, 0.75f}, min3[3] = {0, -0.25f, 0.125f};
    const int modes[4] = {kvImageConvert_DitherNone, kvImageConvert_DitherOrderedReproducible, kvImageConvert_DitherOrdered,
                          kvImageConvert_DitherFloydSteinberg};
    char n[96];
    for (int i = 0; i < 4; ++i) {
        int m = modes[i];
#define DITHER(name, BPP, call)                                                                          \
    snprintf(n, sizeof(n), #name " %d", m);                                                              \
    if (m == kvImageConvert_DitherNone) {                                                                \
        TD(n, W, H, BPP, call);                                                                          \
    } else {                                                                                             \
        vImage_Buffer d = make(BPP, KZERO);                                                              \
        printf("%s: %ld\n", n, (long)(call));                                                            \
        free(d.data);                                                                                    \
    }
        DITHER(PlanarFtoPlanar8_dithered, 1, vImageConvert_PlanarFtoPlanar8_dithered(&sF, &d, 1.25f, -0.25f, m, 0));
        DITHER(RGBFFFtoRGB888_dithered, 3, vImageConvert_RGBFFFtoRGB888_dithered(&sF, &d, max3, min3, m, 0));
        DITHER(ARGBFFFFtoARGB8888_dithered, 4, vImageConvert_ARGBFFFFtoARGB8888_dithered(&sF, &d, maxF, minF, m, bgra, 0));
        DITHER(Planar16UtoPlanar8_dithered, 1, vImageConvert_Planar16UtoPlanar8_dithered(&s16U, &d, m, 0));
        DITHER(RGB16UtoRGB888_dithered, 3, vImageConvert_RGB16UtoRGB888_dithered(&s16U, &d, m, 0));
        DITHER(ARGB16UtoARGB8888_dithered, 4, vImageConvert_ARGB16UtoARGB8888_dithered(&s16U, &d, m, bgra, 0));
        DITHER(RGB888toRGB565_dithered, 2, vImageConvert_RGB888toRGB565_dithered(&s8, &d, NULL, m, 0));
        DITHER(ARGB8888toRGB565_dithered, 2, vImageConvert_ARGB8888toRGB565_dithered(&s8, &d, NULL, m, 0));
        DITHER(RGBA8888toRGB565_dithered, 2, vImageConvert_RGBA8888toRGB565_dithered(&s8, &d, NULL, m, 0));
        DITHER(BGRA8888toRGB565_dithered, 2, vImageConvert_BGRA8888toRGB565_dithered(&s8, &d, NULL, m, 0));
        DITHER(ARGB8888toARGB1555_dithered, 2, vImageConvert_ARGB8888toARGB1555_dithered(&s8, &d, NULL, m, 0));
        DITHER(RGBA8888toRGBA5551_dithered, 2, vImageConvert_RGBA8888toRGBA5551_dithered(&s8, &d, NULL, m, 0));
#undef DITHER
    }
    printf("ARGB16UtoARGB8888_dithered bad permutation: %ld\n",
           (long)vImageConvert_ARGB16UtoARGB8888_dithered(&s16U, &s8, kvImageConvert_DitherNone, (uint8_t[]){4, 0, 1, 2}, 0));
    printf("PlanarFtoPlanar8_dithered unknown flag: %ld\n",
           (long)vImageConvert_PlanarFtoPlanar8_dithered(&sF, &s8, 1, 0, kvImageConvert_DitherNone, 0x100000));

    /* 1, 2 and 4 bits a pixel, with a palette or computing one: no dither exactly, and
       Atkinson's at 1 bit (Apple's other diffusion rounds its own way) */
    Pixel_8 p2[2] = {30, 220}, p4[4] = {10, 60, 200, 250}, p16[16];
    for (int i = 0; i < 16; ++i)
        p16[i] = (Pixel_8)(i * i);
    for (int m = 0; m <= 5; ++m) {
        /* (Apple's 2- and 4-bit forms step dest by src's rowBytes when not diffusing, so
           dest gets src's rowBytes here; its Floyd-Steinberg treats the right edge its own
           way) */
        bool exact = m == kvImageConvert_DitherNone || (m == kvImageConvert_DitherAtkinson);
#define BITS(name, bits, call)                                                                           \
    snprintf(n, sizeof(n), #name " %d", m);                                                              \
    if (exact && (bits == 1 || m == kvImageConvert_DitherNone)) {                                        \
        vImage_Buffer d = make(16, KZERO);                                                               \
        memset(d.data, 0, d.rowBytes * d.height);                                                        \
        vImage_Error e = call;                                                                           \
        size_t one = 1;                                                                                  \
        report(n, e, 1, &d, &one);                                                                       \
        free(d.data);                                                                                    \
    } else {                                                                                             \
        vImage_Buffer d = make(1, KZERO);                                                                \
        printf("%s: %ld\n", n, (long)(call));                                                            \
        free(d.data);                                                                                    \
    }
        BITS(Planar8toPlanar1, 1, vImageConvert_Planar8toPlanar1(&s8, &d, NULL, m, 0));
        BITS(Planar8toPlanar2, 2, vImageConvert_Planar8toPlanar2(&s8, &d, NULL, m, 0));
        BITS(Planar8toPlanar4, 4, vImageConvert_Planar8toPlanar4(&s8, &d, NULL, m, 0));
        BITS(Planar8toIndexed1, 1, vImageConvert_Planar8toIndexed1(&s8, &d, NULL, p2, m, 0));
        BITS(Planar8toIndexed2, 2, vImageConvert_Planar8toIndexed2(&s8, &d, NULL, p4, m, 0));
        BITS(Planar8toIndexed4, 4, vImageConvert_Planar8toIndexed4(&s8, &d, NULL, p16, m, 0));
#undef BITS
    }
    {
        Pixel_8 auto4[4] = {0};
        vImage_Buffer d = make(1, KZERO);
        printf("Planar8toIndexed2 computed palette: %ld\n",
               (long)vImageConvert_Planar8toIndexed2(&s8, &d, NULL, auto4, kvImageConvert_DitherNone, 0));
        free(d.data);
    }
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
    histograms_and_morphology();
    convolutions();
    transforms();
    geometry();
    conversions_10bit();
    conversions_dithered();
    return 0;
}

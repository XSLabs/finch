/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int testFailures;

static double rounded(double value)
{
    return fabs(value) < 0.0005 ? 0.0 : value;
}

extern void old_sscal(const int *, const float *, float *, const int *) __asm("_sscal_");
extern void old_sgemv(const char *, const int *, const int *, const float *, const float *,
                      const int *, const float *, const int *, const float *, float *,
                      const int *) __asm("_sgemv_");

static void floats(const char *name, const float *values, size_t count)
{
    size_t i;
    printf("%s:", name);
    for (i = 0; i < count; ++i) printf(" %.3f", rounded(values[i]));
    putchar('\n');
}

static void doubles(const char *name, const double *values, size_t count)
{
    size_t i;
    printf("%s:", name);
    for (i = 0; i < count; ++i) printf(" %.3f", rounded(values[i]));
    putchar('\n');
}

static void bytes(const char *name, const uint8_t *values, size_t count)
{
    size_t i;
    printf("%s:", name);
    for (i = 0; i < count; ++i) printf(" %u", values[i]);
    putchar('\n');
}

static void bytes_within_one(const char *name, const uint8_t *values,
                             const uint8_t *expected, size_t count)
{
    size_t i;
    for (i = 0; i < count; ++i) {
        int difference = (int)values[i] - (int)expected[i];
        if (difference < -1 || difference > 1) {
            ++testFailures;
            printf("%s: outside 1 byte\n", name);
            return;
        }
    }
    printf("%s: within 1 byte\n", name);
}

static void release_count(void *userData, void *data)
{
    ++*(int *)userData;
    free(data);
}

static void test_vdsp(void)
{
    float a[] = {1.0f, -2.0f, 3.5f, 4.0f};
    float b[] = {3.0f, 5.0f, -1.0f, 2.0f};
    float out[8] = {0}, scalar = 2.0f, low = -1.0f, high = 3.0f;
    float total, maxValue, maxMagnitude, mean;
    float filter[] = {0.25f, 0.5f, 0.25f};
    float signal[] = {1, 2, 3, 4, 5, 6, 7, 8};
    float filterOut[4] = {0}, downsampled[3] = {0};
    float realA[] = {1, 2, 3}, imagA[] = {2, -1, 4};
    float realB[] = {3, 1, -2}, imagB[] = {1, 2, 1};
    float realC[3] = {0}, imagC[3] = {0};
    DSPSplitComplex za = {realA, imagA}, zb = {realB, imagB}, zc = {realC, imagC};
    DSPComplex packed[] = {{1, 2}, {3, 4}, {-1, 0}};
    float splitReal[3] = {0}, splitImag[3] = {0};
    DSPSplitComplex split = {splitReal, splitImag};
    DSPComplex unpacked[3] = {{0, 0}, {0, 0}, {0, 0}};
    double da[] = {1, -2, 4, 3, -1, 0};
    double dc[] = {0, 0, 0, 0, 0, 0};
    double db[] = {0.5, 0.25, 0.125, -0.2, 0.1};
    DSPSplitComplex realFFT;
    float fftReal[4] = {1, 3, 5, 7}, fftImag[4] = {2, 4, 6, 8};
    float complexReal[8] = {1, 2, 3, 4, 0, 0, 0, 0};
    float complexImag[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    float resultReal[8] = {0}, resultImag[8] = {0};
    float radix3Real[24], radix3Imag[24], radix3OutReal[24], radix3OutImag[24];
    float radix5Real[40], radix5Imag[40], radix5OutReal[40], radix5OutImag[40];
    DSPSplitComplex radix3In, radix3Out, radix5In, radix5Out, complexIn, complexOut;
    FFTSetup setup, setup3, setup5;
    size_t i;

    vDSP_vadd(a, 1, b, 1, out, 1, 4); floats("vadd", out, 4);
    vDSP_vsub(b, 1, a, 1, out, 1, 4); floats("vsub", out, 4);
    vDSP_vmul(a, 1, b, 1, out, 1, 4); floats("vmul", out, 4);
    vDSP_vclip(a, 1, &low, &high, out, 1, 4); floats("vclip", out, 4);
    vDSP_vsma(a, 1, &scalar, b, 1, out, 1, 4); floats("vsma", out, 4);
    vDSP_vma(a, 1, b, 1, a, 1, out, 1, 4); floats("vma", out, 4);
    vDSP_vsmul(a, 1, &scalar, out, 1, 4); floats("vsmul", out, 4);
    vDSP_vsadd(a, 1, &scalar, out, 1, 4); floats("vsadd", out, 4);
    vDSP_vabs(a, 1, out, 1, 4); floats("vabs", out, 4);
    vDSP_vsq(a, 1, out, 1, 4); floats("vsq", out, 4);
    vDSP_vmax(a, 1, b, 1, out, 1, 4); floats("vmax", out, 4);
    vDSP_sve(a, 1, &total, 4); printf("sve: %.3f\n", total);
    vDSP_svesq(a, 1, &total, 4); printf("svesq: %.3f\n", total);
    vDSP_dotpr(a, 1, b, 1, &total, 4); printf("dotpr: %.3f\n", total);
    vDSP_maxv(a, 1, &maxValue, 4); printf("maxv: %.3f\n", maxValue);
    vDSP_maxmgv(a, 1, &maxMagnitude, 4); printf("maxmgv: %.3f\n", maxMagnitude);
    vDSP_meanv(a, 1, &mean, 4); printf("meanv: %.3f\n", mean);
    vDSP_vclr(out, 1, 4); floats("vclr", out, 4);
    vDSP_conv(signal, 1, filter, 1, filterOut, 1, 4, 3); floats("conv", filterOut, 4);
    vDSP_desamp(signal, 2, filter, downsampled, 3, 3); floats("desamp", downsampled, 3);
    vDSP_deq22D(da, 1, db, dc, 1, 4); doubles("deq22D", dc + 2, 4);
    vDSP_zvmul(&za, 1, &zb, 1, &zc, 1, 3, 0);
    floats("zvmul.real", realC, 3); floats("zvmul.imag", imagC, 3);
    vDSP_ctoz(packed, 2, &split, 1, 3);
    vDSP_ztoc(&split, 1, unpacked, 2, 3);
    floats("ctoz", splitReal, 3); floats("ztoc.real", (float *)&unpacked[0], 6);

    setup = vDSP_create_fftsetup(3, kFFTRadix2);
    if (!setup) { puts("fftsetup: failed"); return; }
    realFFT.realp = fftReal; realFFT.imagp = fftImag;
    vDSP_fft_zrip(setup, &realFFT, 1, 3, FFT_FORWARD);
    floats("fft_zrip.real", fftReal, 4); floats("fft_zrip.imag", fftImag, 4);
    vDSP_fft_zrip(setup, &realFFT, 1, 3, FFT_INVERSE);
    floats("fft_zrip.inverse", fftReal, 4); floats("fft_zrip.inverse-imag", fftImag, 4);
    complexIn.realp = complexReal; complexIn.imagp = complexImag;
    complexOut.realp = resultReal; complexOut.imagp = resultImag;
    vDSP_fft_zop(setup, &complexIn, 1, &complexOut, 1, 3, FFT_FORWARD);
    floats("fft_zop.real", resultReal, 8); floats("fft_zop.imag", resultImag, 8);
    vDSP_destroy_fftsetup(setup);
    setup3 = vDSP_create_fftsetup(3, kFFTRadix3);
    if (!setup3) { puts("fftsetup3: failed"); return; }
    for (i = 0; i < 24; ++i) { radix3Real[i] = (float)(i % 5); radix3Imag[i] = 0; }
    radix3In.realp = radix3Real; radix3In.imagp = radix3Imag;
    radix3Out.realp = radix3OutReal; radix3Out.imagp = radix3OutImag;
    vDSP_fft3_zop(setup3, &radix3In, 1, &radix3Out, 1, 3, FFT_FORWARD);
    floats("fft3.first", radix3OutReal, 3);
    vDSP_destroy_fftsetup(setup3);
    setup5 = vDSP_create_fftsetup(3, kFFTRadix5);
    if (!setup5) { puts("fftsetup5: failed"); return; }
    for (i = 0; i < 40; ++i) { radix5Real[i] = (float)(i % 7); radix5Imag[i] = 0; }
    radix5In.realp = radix5Real; radix5In.imagp = radix5Imag;
    radix5Out.realp = radix5OutReal; radix5Out.imagp = radix5OutImag;
    vDSP_fft5_zop(setup5, &radix5In, 1, &radix5Out, 1, 3, FFT_FORWARD);
    floats("fft5.first", radix5OutReal, 3);
    vDSP_destroy_fftsetup(setup5);
}

static void test_vforce(void)
{
    vFloat y = {0.5f, -1.0f, 2.0f, -0.5f};
    vFloat x = {1.0f, 2.0f, -1.0f, -0.5f};
    vFloat angles = {0.0f, 0.5f, 1.0f, 1.5f};
    vFloat sine;
    vFloat atan = vatan2f(y, x);
    vFloat cosine = vsincosf(angles, &sine);
    vFloat roots = vsqrtf((vFloat){1.0f, 2.0f, 4.0f, 9.0f});
    floats("vatan2f", (const float *)&atan, 4);
    floats("vsincosf.cos", (const float *)&cosine, 4);
    floats("vsincosf.sin", (const float *)&sine, 4);
    floats("vsqrtf", (const float *)&roots, 4);
}

static void test_vimage(void)
{
    Pixel_8888 sourcePixels[6] = {
        {255, 0, 0, 0}, {255, 80, 10, 20}, {255, 160, 20, 40},
        {255, 40, 80, 120}, {255, 120, 100, 80}, {255, 200, 120, 40}
    };
    Pixel_8888 destinationPixels[6] = {{0}};
    uint8_t plane[] = {0, 20, 40, 60, 80, 100, 120, 140, 160, 180, 200, 220, 240, 250, 255, 10};
    uint8_t scaledPlane[4] = {0};
    Pixel_8888 boxPixels[6] = {{0}}, tentPixels[6] = {{0}}, matrixPixels[6] = {{0}};
    uint8_t lookup[256], lookupOut[16] = {0};
    vImage_Buffer source = {sourcePixels, 2, 3, 3 * sizeof(Pixel_8888)};
    vImage_Buffer scaled = {destinationPixels, 2, 2, 2 * sizeof(Pixel_8888)};
    vImage_Buffer box = {boxPixels, 2, 3, 3 * sizeof(Pixel_8888)};
    vImage_Buffer tent = {tentPixels, 2, 3, 3 * sizeof(Pixel_8888)};
    vImage_Buffer matrix = {matrixPixels, 2, 3, 3 * sizeof(Pixel_8888)};
    vImage_Buffer planeSource = {plane, 4, 4, 4};
    vImage_Buffer planeScaled = {scaledPlane, 2, 2, 2};
    vImage_Buffer lookupSource = {plane, 4, 4, 4};
    vImage_Buffer lookupDest = {lookupOut, 4, 4, 4};
    Pixel_8888 background = {0, 0, 0, 0};
    int16_t identity[16] = {16384, 0, 0, 0, 0, 16384, 0, 0,
                            0, 0, 16384, 0, 0, 0, 0, 16384};
    vImagePixelCount histogramStorage[4][256] = {{0}};
    vImagePixelCount *histogram[4] = {
        histogramStorage[0], histogramStorage[1], histogramStorage[2], histogramStorage[3]
    };
    float floatPixels[] = {0.0f, 0.25f, 0.5f, 1.0f, 1.0f, 0.75f, 0.5f, 0.0f};
    vImagePixelCount floatHistogramStorage[4][4] = {{0}};
    vImagePixelCount *floatHistogram[4] = {
        floatHistogramStorage[0], floatHistogramStorage[1], floatHistogramStorage[2], floatHistogramStorage[3]
    };
    vImage_Buffer floatSource = {floatPixels, 1, 2, 8 * sizeof(float)};
    vImage_CGImageFormat format;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider;
    CGImageRef sourceImage, outputImage;
    uint8_t cgPixels[] = {20, 40, 60, 255, 80, 100, 120, 255,
                          140, 160, 180, 255, 200, 220, 240, 255};
    vImage_Buffer decoded = {0};
    vImage_Error error = 0;
    size_t i;
    int releaseCount = 0;
    uint8_t *owned;
    vImage_Buffer ownedBuffer;

    printf("scale-argb: %ld\n", (long)vImageScale_ARGB8888(&source, &scaled, NULL, kvImageNoFlags));
    bytes("scale-argb.first", (const uint8_t *)destinationPixels, 8);
    printf("scale-planar: %ld\n", (long)vImageScale_Planar8(&planeSource, &planeScaled, NULL, kvImageNoFlags));
    {
        static const uint8_t appleScaledPlane[] = {46, 101, 219, 174};
        bytes_within_one("scale-planar", scaledPlane, appleScaledPlane, 4);
    }
    printf("box-convolve: %ld\n", (long)vImageBoxConvolve_ARGB8888(&source, &box, NULL, 0, 0, 3, 3,
          background, kvImageEdgeExtend | kvImageDoNotTile));
    bytes("box.first", (const uint8_t *)boxPixels, 8);
    printf("tent-convolve: %ld\n", (long)vImageTentConvolve_ARGB8888(&source, &tent, NULL, 0, 0, 3, 3,
          background, kvImageEdgeExtend | kvImageDoNotTile));
    bytes("tent.first", (const uint8_t *)tentPixels, 8);
    printf("matrix-multiply: %ld\n", (long)vImageMatrixMultiply_ARGB8888(&source, &matrix, identity,
          16384, NULL, NULL, kvImageNoFlags));
    bytes("matrix.first", (const uint8_t *)matrixPixels, 8);
    for (i = 0; i < 256; ++i) lookup[i] = (uint8_t)(255 - i);
    printf("table-lookup: %ld\n", (long)vImageTableLookUp_Planar8(&lookupSource, &lookupDest, lookup, kvImageNoFlags));
    bytes("table-lookup", lookupOut, 8);
    printf("histogram-8888: %ld\n", (long)vImageHistogramCalculation_ARGB8888(&source, histogram, kvImageNoFlags));
    printf("histogram-8888: %llu %llu %llu %llu\n",
           (unsigned long long)histogramStorage[0][255], (unsigned long long)histogramStorage[1][0],
           (unsigned long long)histogramStorage[2][10], (unsigned long long)histogramStorage[3][40]);
    printf("histogram-float: %ld\n", (long)vImageHistogramCalculation_ARGBFFFF(&floatSource, floatHistogram,
          4, 0.0f, 1.0f, kvImageNoFlags));
    printf("histogram-float: %llu %llu %llu %llu\n",
           (unsigned long long)floatHistogramStorage[0][0], (unsigned long long)floatHistogramStorage[1][1],
           (unsigned long long)floatHistogramStorage[2][2], (unsigned long long)floatHistogramStorage[3][3]);

    memset(&format, 0, sizeof(format));
    format.bitsPerComponent = 8;
    format.bitsPerPixel = 32;
    format.colorSpace = space;
    format.bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast;
    format.version = 0;
    format.renderingIntent = kCGRenderingIntentDefault;
    provider = CGDataProviderCreateWithData(NULL, cgPixels, sizeof(cgPixels), NULL);
    sourceImage = CGImageCreate(2, 2, 8, 32, 8, space, format.bitmapInfo, provider, NULL, false,
                                kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    printf("buffer-init: %ld\n", (long)vImageBuffer_InitWithCGImage(&decoded, &format, NULL, sourceImage, kvImageNoFlags));
    printf("buffer-init-size: %llu %llu %zu\n", (unsigned long long)decoded.width,
           (unsigned long long)decoded.height, decoded.rowBytes);
    bytes("buffer-init.first", decoded.data, 4);
    outputImage = vImageCreateCGImageFromBuffer(&decoded, &format, NULL, NULL, kvImageNoFlags, &error);
    printf("image-from-buffer: %ld %llu %llu\n", (long)error,
           (unsigned long long)(outputImage ? CGImageGetWidth(outputImage) : 0),
           (unsigned long long)(outputImage ? CGImageGetHeight(outputImage) : 0));
    CGImageRelease(outputImage);
    free(decoded.data);

    owned = malloc(sizeof(cgPixels));
    memcpy(owned, cgPixels, sizeof(cgPixels));
    ownedBuffer = (vImage_Buffer){owned, 2, 2, 8};
    outputImage = vImageCreateCGImageFromBuffer(&ownedBuffer, &format, release_count,
                                               &releaseCount, kvImageNoAllocate, &error);
    printf("image-no-copy: %ld %d\n", (long)error, outputImage != NULL);
    if (outputImage) CGImageRelease(outputImage);
    printf("image-release-callback: %d\n", releaseCount);
    CGImageRelease(sourceImage);
    CGColorSpaceRelease(space);
}

static void test_blas(void)
{
    double x[] = {1, 2, 3}, y[] = {4, 5, 6};
    double a[] = {1, 2, 3, 4}, b[] = {2, 0, 1, 2};
    int n = 3, inc = 1, m = 2, cols = 2, lda = 2;
    float fs[] = {1, 2, 3};
    float alphaF = 2.0f, betaF = 0.0f, fy[] = {0, 0};
    float fm[] = {1, 2, 3, 4}, fx[] = {2, 1};
    double triLower[] = {1, 1}, triDiag[] = {4, 4, 3}, triUpper[] = {1, 1};
    double triRhs[] = {6, 12, 11};
    double lu[] = {4, 2, 7, 6}, inverseWork[64];
    double lsA[] = {1, 1, 1, 0, 1, 2};
    double lsB[] = {1, 3, 5};
    __LAPACK_int pivots[2] = {0}, info = 0, nLapack = 2, ldaLapack = 2, lwork = 64;
    __LAPACK_int triN = 3, nrhs = 1, ldb = 3, lsM = 3, lsN = 2, lsRhs = 1, lsLda = 3, lsLdb = 3;
    double product[4] = {0};
    char noTranspose = 'N';

    cblas_daxpy(3, 2.0, x, 1, y, 1); doubles("cblas-daxpy", y, 3);
    printf("cblas-ddot: %.3f\n", cblas_ddot(3, x, 1, y, 1));
    cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1.0,
                a, 2, b, 2, 0.0, product, 2);
    doubles("cblas-dgemm", product, 4);
    old_sscal(&n, &alphaF, fs, &inc); floats("sscal", fs, 3);
    old_sgemv(&noTranspose, &m, &cols, &alphaF, fm, &lda, fx, &inc,
              &betaF, fy, &inc); floats("sgemv", fy, 2);

    dgtsv_(&triN, &nrhs, triLower, triDiag, triUpper, triRhs, &ldb, &info);
    printf("dgtsv: %d ", info); doubles("solution", triRhs, 3);
    dgetrf_(&nLapack, &nLapack, lu, &ldaLapack, pivots, &info);
    printf("dgetrf: %d %d %d\n", info, (int)pivots[0], (int)pivots[1]);
    dgetri_(&nLapack, lu, &ldaLapack, pivots, inverseWork, &lwork, &info);
    printf("dgetri: %d ", info); doubles("inverse", lu, 4);
    dgels_(&noTranspose, &lsM, &lsN, &lsRhs, lsA, &lsLda, lsB, &lsLdb,
           inverseWork, &lwork, &info);
    printf("dgels: %d ", info); doubles("least-squares", lsB, 3);
}

int main(void)
{
    Dl_info info;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("Accelerate: %s\n", dladdr((void *)vDSP_vadd, &info) ? info.dli_fname : "?");
    test_vdsp();
    test_vforce();
    test_vimage();
    test_blas();
    return testFailures ? 1 : 0;
}

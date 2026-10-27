/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * vImage's CoreVideo utilities (vImage_CVUtilities.h): vImageCVImageFormat (a CoreVideo
 * pixel format with its matrix, chroma siting, colour space and channel ranges), converters
 * between CoreGraphics and CoreVideo formats, CVPixelBuffer import and export, and colour
 * spaces from primaries and transfer functions.
 *
 * The formats are those Apple's vImage knows, with its channel names and ranges. RGB, gray
 * and indexed CoreVideo formats convert as the equivalent vImage_CGImageFormat. Y'CbCr ones
 * convert through vImage's Y'CbCr functions to ARGB8888 (or ARGB16U from 16 bits) in the
 * format's colour space, then as CoreGraphics formats; subsampled chroma is replicated (and
 * averaged the other way) whatever the siting. CoreVideo is loaded when first needed, as it
 * is built after Accelerate.
 */
#include "utilities.h"
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>

/* MARK: - CoreVideo, loaded at run time */

static struct {
    OSType (*GetPixelFormatType)(CVPixelBufferRef);
    size_t (*GetWidth)(CVPixelBufferRef), (*GetHeight)(CVPixelBufferRef), (*GetPlaneCount)(CVPixelBufferRef);
    Boolean (*IsPlanar)(CVPixelBufferRef);
    CVReturn (*Lock)(CVPixelBufferRef, CVPixelBufferLockFlags), (*Unlock)(CVPixelBufferRef, CVPixelBufferLockFlags);
    void *(*GetBaseAddress)(CVPixelBufferRef), *(*GetBaseAddressOfPlane)(CVPixelBufferRef, size_t);
    size_t (*GetBytesPerRow)(CVPixelBufferRef), (*GetBytesPerRowOfPlane)(CVPixelBufferRef, size_t);
    CFTypeRef (*GetAttachment)(CVBufferRef, CFStringRef, CVAttachmentMode *);
    CFDictionaryRef (*CopyAttachments)(CVBufferRef, CVAttachmentMode);
    CGColorSpaceRef (*CreateColorSpaceFromAttachments)(CFDictionaryRef);
    CGColorSpaceRef (*GetColorSpace)(CVImageBufferRef);
    const CFStringRef *matrixKey, *matrix601, *matrix709, *chromaKey;
    bool loaded;
} cv;

static void load_cv(void)
{
    void *h = dlopen("/System/Library/Frameworks/CoreVideo.framework/CoreVideo", RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
        return;
#define SYM(field, name) *(void **)&cv.field = dlsym(h, name)
    SYM(GetPixelFormatType, "CVPixelBufferGetPixelFormatType");
    SYM(GetWidth, "CVPixelBufferGetWidth");
    SYM(GetHeight, "CVPixelBufferGetHeight");
    SYM(GetPlaneCount, "CVPixelBufferGetPlaneCount");
    SYM(IsPlanar, "CVPixelBufferIsPlanar");
    SYM(Lock, "CVPixelBufferLockBaseAddress");
    SYM(Unlock, "CVPixelBufferUnlockBaseAddress");
    SYM(GetBaseAddress, "CVPixelBufferGetBaseAddress");
    SYM(GetBaseAddressOfPlane, "CVPixelBufferGetBaseAddressOfPlane");
    SYM(GetBytesPerRow, "CVPixelBufferGetBytesPerRow");
    SYM(GetBytesPerRowOfPlane, "CVPixelBufferGetBytesPerRowOfPlane");
    SYM(GetAttachment, "CVBufferGetAttachment");
    SYM(CopyAttachments, "CVBufferCopyAttachments");
    SYM(CreateColorSpaceFromAttachments, "CVImageBufferCreateColorSpaceFromAttachments");
    SYM(GetColorSpace, "CVImageBufferGetColorSpace");
    SYM(matrixKey, "kCVImageBufferYCbCrMatrixKey");
    SYM(matrix601, "kCVImageBufferYCbCrMatrix_ITU_R_601_4");
    SYM(matrix709, "kCVImageBufferYCbCrMatrix_ITU_R_709_2");
    SYM(chromaKey, "kCVImageBufferChromaLocationTopFieldKey");
#undef SYM
    cv.loaded = cv.GetPixelFormatType && cv.GetWidth && cv.GetHeight && cv.Lock && cv.Unlock && cv.GetBaseAddress &&
                cv.GetBytesPerRow;
}

static bool have_cv(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_cv);
    return cv.loaded;
}

/* MARK: - The formats */

#define L kvImageBufferTypeCode_Luminance
#define CB kvImageBufferTypeCode_Cb
#define CR kvImageBufferTypeCode_Cr
#define A kvImageBufferTypeCode_Alpha
#define C1 kvImageBufferTypeCode_ColorSpaceChannel1
#define C2 kvImageBufferTypeCode_ColorSpaceChannel2
#define C3 kvImageBufferTypeCode_ColorSpaceChannel3
#define IX kvImageBufferTypeCode_Indexed

/* how a format's samples are laid out */
typedef enum { CG, BGR24, YUV, TWO } Kind;

typedef struct {
    uint32_t code;
    vImageBufferTypeCode names[5];
    int alphaHint; /* the default: 0 with alpha, 2 without, 1 for 30-bit RGB */
    Kind kind;
    /* CG: the equivalent format (colour model: 0 RGB, 1 gray, 2 indexed) */
    uint32_t bpc, bpp;
    CGBitmapInfo info;
    int model;
    bool whiteIsZero;
    /* YUV: the vImage type, and ranges: {min, zero, full, max} of Y', chroma and alpha */
    vImageYpCbCrType ycbcr;
    CGFloat y[4], c[4], a[4];
    /* Y'CbCr buffers: the converters' buffer order */
    vImageBufferTypeCode order[3];
} CVFormat;

#define VIDEO8 {0, 16, 235, 255}, {0, 128, 240, 255}
#define FULL8 {0, 0, 255, 255}, {0, 128, 255, 255}
#define VIDEO10 {0, 64, 940, 1023}, {0, 512, 960, 1023}
#define VIDEO16 {0, 4096, 60160, 65535}, {0, 32768, 61440, 65535}
#define RGBN(n, ...) .names = {__VA_ARGS__}, .alphaHint = n
#define YUVT(type, ...) .kind = YUV, .ycbcr = type, .order = {__VA_ARGS__}

static const CVFormat formats[] = {
    {1, RGBN(2, C1), CG, 1, 1, kCGImageAlphaNone, 1},
    {2, RGBN(2, IX), CG, 2, 2, kCGImageAlphaNone, 2},
    {4, RGBN(2, IX), CG, 4, 4, kCGImageAlphaNone, 2},
    {8, RGBN(2, IX), CG, 8, 8, kCGImageAlphaNone, 2},
    {33, RGBN(2, IX), CG, 1, 1, kCGImageAlphaNone, 2, true},
    {34, RGBN(2, IX), CG, 2, 2, kCGImageAlphaNone, 2, true},
    {36, RGBN(2, IX), CG, 4, 4, kCGImageAlphaNone, 2, true},
    {40, RGBN(2, IX), CG, 8, 8, kCGImageAlphaNone, 2, true},
    {kCVPixelFormatType_16BE555, RGBN(0, C1, C2, C3), CG, 5, 16, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Big},
    {kCVPixelFormatType_16LE555, RGBN(0, C1, C2, C3), CG, 5, 16, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Little},
    {kCVPixelFormatType_16LE5551, RGBN(0, C1, C2, C3, A), CG, 5, 16, kCGImageAlphaLast | kCGBitmapByteOrder16Little},
    {kCVPixelFormatType_16BE565, RGBN(2, C1, C2, C3), CG, 5, 16, kCGImageAlphaNone | kCGBitmapByteOrder16Big},
    {kCVPixelFormatType_16LE565, RGBN(2, C1, C2, C3), CG, 5, 16, kCGImageAlphaNone | kCGBitmapByteOrder16Little},
    {kCVPixelFormatType_24RGB, RGBN(2, C1, C2, C3), CG, 8, 24, kCGImageAlphaNone},
    {kCVPixelFormatType_24BGR, RGBN(2, C3, C2, C1), BGR24, 8, 24, kCGImageAlphaNone},
    {kCVPixelFormatType_32ARGB, RGBN(0, A, C1, C2, C3), CG, 8, 32, kCGImageAlphaFirst},
    {kCVPixelFormatType_32BGRA, RGBN(0, C3, C2, C1, A), CG, 8, 32, kCGImageAlphaFirst | kCGBitmapByteOrder32Little},
    {kCVPixelFormatType_32ABGR, RGBN(0, A, C3, C2, C1), CG, 8, 32, kCGImageAlphaLast | kCGBitmapByteOrder32Little},
    {kCVPixelFormatType_32RGBA, RGBN(0, C1, C2, C3, A), CG, 8, 32, kCGImageAlphaLast},
    {kCVPixelFormatType_48RGB, RGBN(2, C1, C2, C3), CG, 16, 48, kCGImageAlphaNone | kCGBitmapByteOrder16Big},
    {kCVPixelFormatType_32AlphaGray, RGBN(0, A, C1), CG, 16, 32, kCGImageAlphaFirst | kCGBitmapByteOrder16Big, 1},
    {kCVPixelFormatType_16Gray, RGBN(2, C1), CG, 16, 16, kCGImageAlphaNone | kCGBitmapByteOrder16Big, 1},
    {kCVPixelFormatType_30RGB, RGBN(1, C1, C2, C3, A), CG, 10, 32,
     kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big | kCGImagePixelFormatRGB101010},
    {kCVPixelFormatType_OneComponent8, RGBN(2, C1), CG, 8, 8, kCGImageAlphaNone, 1},
    {kCVPixelFormatType_TwoComponent8, RGBN(2, C1, C2), TWO, 8, 16},
    {kCVPixelFormatType_OneComponent16Half, RGBN(2, C1), CG, 16, 16,
     kCGImageAlphaNone | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little, 1},
    {kCVPixelFormatType_OneComponent32Float, RGBN(2, C1), CG, 32, 32,
     kCGImageAlphaNone | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little, 1},
    {kCVPixelFormatType_TwoComponent16Half, RGBN(0, C1, C2), TWO, 16, 32, kCGBitmapFloatComponents},
    {kCVPixelFormatType_TwoComponent32Float, RGBN(0, C1, C2), TWO, 32, 64, kCGBitmapFloatComponents},
    {kCVPixelFormatType_64RGBAHalf, RGBN(0, C1, C2, C3, A), CG, 16, 64,
     kCGImageAlphaLast | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little},
    {kCVPixelFormatType_128RGBAFloat, RGBN(0, C1, C2, C3, A), CG, 32, 128,
     kCGImageAlphaLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little},
    {kCVPixelFormatType_422YpCbCr8, RGBN(2, CB, L, CR), YUVT(kvImage422CbYpCrYp8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}},
    {kCVPixelFormatType_422YpCbCr8_yuvs, RGBN(2, L, CB, CR), YUVT(kvImage422YpCbYpCr8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}},
    {kCVPixelFormatType_422YpCbCr8FullRange, RGBN(2, L, CB, CR), YUVT(kvImage422YpCbYpCr8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 0, 255, 255}, .c = {0, 128, 255, 255}},
    {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, RGBN(2, L, CB, CR), YUVT(kvImage420Yp8_CbCr8, L, kvImageBufferTypeCode_Chroma),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}},
    {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, RGBN(2, L, CB, CR), YUVT(kvImage420Yp8_CbCr8, L, kvImageBufferTypeCode_Chroma),
     .y = {0, 0, 255, 255}, .c = {0, 128, 255, 255}},
    {kCVPixelFormatType_420YpCbCr8Planar, RGBN(2, L, CB, CR), YUVT(kvImage420Yp8_Cb8_Cr8, L, CB, CR), .y = {0, 16, 235, 255},
     .c = {0, 128, 240, 255}},
    {kCVPixelFormatType_420YpCbCr8PlanarFullRange, RGBN(2, L, CB, CR), YUVT(kvImage420Yp8_Cb8_Cr8, L, CB, CR),
     .y = {0, 0, 255, 255}, .c = {0, 128, 255, 255}},
    {kCVPixelFormatType_444YpCbCr8, RGBN(2, CR, L, CB), YUVT(kvImage444CrYpCb8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}},
    {kCVPixelFormatType_4444YpCbCrA8, RGBN(0, CB, L, CR, A), YUVT(kvImage444CbYpCrA8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}, .a = {0, 16, 235, 255}},
    {kCVPixelFormatType_4444YpCbCrA8R, RGBN(0, A, L, CB, CR), YUVT(kvImage444AYpCbCr8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 0, 219, 255}, .c = {0, 128, 240, 255}, .a = {0, 0, 255, 255}},
    {kCVPixelFormatType_4444AYpCbCr8, RGBN(0, A, L, CB, CR), YUVT(kvImage444AYpCbCr8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 16, 235, 255}, .c = {0, 128, 240, 255}, .a = {0, 0, 255, 255}},
    {kCVPixelFormatType_422YpCbCr_4A_8BiPlanar, RGBN(0, CB, L, CR, A),
     YUVT(kvImage422CbYpCrYp8_AA8, kvImageBufferTypeCode_CVPixelBuffer_YCbCr, A), .y = {0, 16, 235, 255},
     .c = {0, 128, 240, 255}, .a = {0, 0, 255, 255}},
    {kCVPixelFormatType_422YpCbCr10, RGBN(2, CR, L, CB),
     YUVT(kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10, kvImageBufferTypeCode_CVPixelBuffer_YCbCr), .y = {0, 64, 940, 1023},
     .c = {0, 512, 960, 1023}},
    {kCVPixelFormatType_444YpCbCr10, RGBN(2, CR, L, CB), YUVT(kvImage444CrYpCb10, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 64, 940, 1023}, .c = {0, 512, 960, 1023}},
    {kCVPixelFormatType_422YpCbCr16, RGBN(2, CB, L, CR), YUVT(kvImage422CbYpCrYp16, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 4096, 60160, 65535}, .c = {0, 32768, 61440, 65535}},
    {kCVPixelFormatType_4444AYpCbCr16, RGBN(0, A, L, CB, CR), YUVT(kvImage444AYpCbCr16, kvImageBufferTypeCode_CVPixelBuffer_YCbCr),
     .y = {0, 4096, 60160, 65535}, .c = {0, 32768, 61440, 65535}, .a = {0, 0, 65535, 65535}},
};

static const CVFormat *format_for(uint32_t code)
{
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); ++i)
        if (formats[i].code == code)
            return &formats[i];
    return NULL;
}

static bool subsampled(const CVFormat *f)
{
    return f->kind == YUV && f->ycbcr != kvImage444CrYpCb8 && f->ycbcr != kvImage444CbYpCrA8 && f->ycbcr != kvImage444AYpCbCr8 &&
           f->ycbcr != kvImage444CrYpCb10 && f->ycbcr != kvImage444AYpCbCr16;
}

/* MARK: - vImageCVImageFormat */

#define FORMAT_MAGIC 0x46564356u /* "VCVF" */

struct vImageCVImageFormat {
    uint32_t magic;
    _Atomic long refs;
    const CVFormat *f;
    uint32_t count;
    vImageBufferTypeCode names[6];
    vImageChannelDescription desc[32]; /* by vImageBufferTypeCode */
    bool hasDesc[32];
    CGColorSpaceRef space;
    CFStringRef siting;
    const vImage_ARGBToYpCbCrMatrix *matrix; /* a predefined one, or &ownMatrix */
    vImage_ARGBToYpCbCrMatrix ownMatrix;
    int alphaHint;
    void *userData;
    void (*userRelease)(vImageCVImageFormatRef, void *);
};

static bool valid(vImageConstCVImageFormatRef f) { return f && f->magic == FORMAT_MAGIC; }

static void set_desc(struct vImageCVImageFormat *fmt, vImageBufferTypeCode t, const CGFloat *d)
{
    if (t >= 32)
        return;
    fmt->desc[t] = (vImageChannelDescription){d[0], d[1], d[2], d[3]};
    fmt->hasDesc[t] = true;
}

static bool known_siting(CFStringRef s)
{
    static const char *const names[] = {"Left", "Center", "TopLeft", "Top", "BottomLeft", "Bottom", "DV 4:2:0"};
    char buf[32];
    if (!s || CFGetTypeID(s) != CFStringGetTypeID() || !CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8))
        return false;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i)
        if (!strcmp(buf, names[i]))
            return true;
    return false;
}

static bool predefined(const vImage_ARGBToYpCbCrMatrix *m)
{
    return m == kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4 || m == kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2;
}

static bool invertible(const vImage_ARGBToYpCbCrMatrix *m)
{
    double a = m->R_Yp, b = m->G_Yp, c = m->B_Yp, d = m->R_Cb, e = m->G_Cb, f = m->B_Cb_R_Cr, g = m->B_Cb_R_Cr,
           h = m->G_Cr, i = m->B_Cr;
    double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    return fabs(det) > 1e-9;
}

static bool space_fits(const CVFormat *f, CGColorSpaceRef space)
{
    if (!space)
        return true;
    CGColorSpaceModel m = CGColorSpaceGetModel(space);
    if (f->kind == YUV || (f->kind == CG && f->model == 0) || f->kind == BGR24)
        return m == kCGColorSpaceModelRGB;
    if (f->kind == CG && f->model == 1)
        return m == kCGColorSpaceModelMonochrome;
    if (f->kind == CG && f->model == 2)
        return m == kCGColorSpaceModelIndexed;
    return true;
}

vImageCVImageFormatRef vImageCVImageFormat_Create(uint32_t imageFormatType, const vImage_ARGBToYpCbCrMatrix *matrix,
                                                  CFStringRef cvImageBufferChromaLocation, CGColorSpaceRef baseColorspace,
                                                  int alphaIsOneHint)
{
    const CVFormat *f = format_for(imageFormatType);
    if (!f || !space_fits(f, baseColorspace))
        return NULL;
    struct vImageCVImageFormat *fmt = calloc(1, sizeof(*fmt));
    if (!fmt)
        return NULL;
    fmt->magic = FORMAT_MAGIC;
    atomic_store(&fmt->refs, 1);
    fmt->f = f;
    for (int i = 0; i < 5 && f->names[i]; ++i)
        fmt->names[fmt->count++] = f->names[i];
    if (f->kind == YUV) {
        set_desc(fmt, L, f->y);
        set_desc(fmt, CB, f->c);
        set_desc(fmt, CR, f->c);
        if (f->a[2])
            set_desc(fmt, A, f->a);
        if (matrix && invertible(matrix)) {
            if (predefined(matrix))
                fmt->matrix = matrix;
            else {
                fmt->ownMatrix = *matrix;
                fmt->matrix = &fmt->ownMatrix;
            }
        }
        /* (siting only matters, and is only kept, with subsampled chroma) */
        if (cvImageBufferChromaLocation && known_siting(cvImageBufferChromaLocation) && subsampled(f))
            fmt->siting = CFRetain(cvImageBufferChromaLocation);
    } else if (f->model != 2) {
        /* RGB and gray: 0 to the format's largest integer (or [0, 1] floats) */
        bool isFloat = (f->info & kCGBitmapFloatComponents) != 0;
        CGFloat top = f->bpc >= 16 && !isFloat ? 65535 : (CGFloat)((1u << (f->bpc > 8 ? f->bpc : f->bpc)) - 1);
        CGFloat d[4] = {isFloat ? -INFINITY : 0, 0, isFloat ? 1 : top, isFloat ? INFINITY : top};
        for (uint32_t i = 0; i < fmt->count; ++i) {
            if (fmt->names[i] == A && imageFormatType == kCVPixelFormatType_30RGB) {
                const CGFloat a2[4] = {0, 0, 3, 3};
                set_desc(fmt, A, a2);
            } else if (fmt->names[i] == A && imageFormatType == kCVPixelFormatType_16LE5551) {
                const CGFloat a1[4] = {0, 0, 1, 1};
                set_desc(fmt, A, a1);
            } else
                set_desc(fmt, fmt->names[i], d);
        }
    }
    if (baseColorspace)
        fmt->space = CGColorSpaceRetain(baseColorspace);
    fmt->alphaHint = f->alphaHint ? f->alphaHint : (alphaIsOneHint ? 1 : 0);
    return fmt;
}

vImageCVImageFormatRef vImageCVImageFormat_Copy(vImageConstCVImageFormatRef format)
{
    if (!valid(format))
        return NULL;
    struct vImageCVImageFormat *copy = malloc(sizeof(*copy));
    if (!copy)
        return NULL;
    *copy = *format;
    atomic_store(&copy->refs, 1);
    if (copy->matrix == &format->ownMatrix)
        copy->matrix = &copy->ownMatrix;
    if (copy->space)
        CGColorSpaceRetain(copy->space);
    if (copy->siting)
        CFRetain(copy->siting);
    copy->userData = NULL;
    copy->userRelease = NULL;
    return copy;
}

void vImageCVImageFormat_Retain(vImageCVImageFormatRef fmt)
{
    if (valid(fmt))
        atomic_fetch_add(&fmt->refs, 1);
}

void vImageCVImageFormat_Release(vImageCVImageFormatRef fmt)
{
    if (!valid(fmt) || atomic_fetch_sub(&fmt->refs, 1) != 1)
        return;
    if (fmt->userRelease)
        fmt->userRelease(fmt, fmt->userData);
    if (fmt->space)
        CGColorSpaceRelease(fmt->space);
    if (fmt->siting)
        CFRelease(fmt->siting);
    fmt->magic = 0;
    free(fmt);
}

uint32_t vImageCVImageFormat_GetFormatCode(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->f->code : 0;
}

uint32_t vImageCVImageFormat_GetChannelCount(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->count : 0;
}

const vImageBufferTypeCode *vImageCVImageFormat_GetChannelNames(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->names : NULL;
}

CGColorSpaceRef vImageCVImageFormat_GetColorSpace(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->space : NULL;
}

vImage_Error vImageCVImageFormat_SetColorSpace(vImageCVImageFormatRef format, CGColorSpaceRef colorspace)
{
    if (!valid(format))
        return kvImageInvalidParameter;
    if (!space_fits(format->f, colorspace))
        return kvImageInvalidImageFormat;
    if (colorspace)
        CGColorSpaceRetain(colorspace);
    if (format->space)
        CGColorSpaceRelease(format->space);
    format->space = colorspace;
    return kvImageNoError;
}

CFStringRef vImageCVImageFormat_GetChromaSiting(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->siting : NULL;
}

vImage_Error vImageCVImageFormat_SetChromaSiting(vImageCVImageFormatRef format, CFStringRef siting)
{
    if (!valid(format))
        return kvImageInvalidImageFormat;
    if (siting && !known_siting(siting))
        return kvImageInvalidParameter;
    if (!subsampled(format->f))
        return kvImageNoError;
    if (siting)
        CFRetain(siting);
    if (format->siting)
        CFRelease(format->siting);
    format->siting = siting;
    return kvImageNoError;
}

const void *vImageCVImageFormat_GetConversionMatrix(vImageConstCVImageFormatRef format, vImageMatrixType *outType)
{
    if (!valid(format))
        return NULL;
    if (outType)
        *outType = format->f->kind == YUV ? kvImageMatrixType_ARGBToYpCbCrMatrix : kvImageMatrixType_None;
    return format->f->kind == YUV ? format->matrix : NULL;
}

vImage_Error vImageCVImageFormat_CopyConversionMatrix(vImageCVImageFormatRef format, const void *matrix,
                                                      vImageMatrixType inType)
{
    if (!valid(format))
        return kvImageInvalidParameter;
    if (format->f->kind != YUV)
        return kvImageNoError;
    if (inType != kvImageMatrixType_ARGBToYpCbCrMatrix)
        return kvImageInvalidParameter;
    const vImage_ARGBToYpCbCrMatrix *m = matrix;
    if (!m) {
        format->matrix = NULL;
        return kvImageNoError;
    }
    if (!invertible(m))
        return kvImageInvalidParameter;
    if (predefined(m))
        format->matrix = m;
    else {
        format->ownMatrix = *m;
        format->matrix = &format->ownMatrix;
    }
    return kvImageNoError;
}

int vImageCVImageFormat_GetAlphaHint(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->alphaHint : 0;
}

/* (formats without alpha keep their hint) */
vImage_Error vImageCVImageFormat_SetAlphaHint(vImageCVImageFormatRef format, int alphaIsOne)
{
    if (!valid(format))
        return kvImageInvalidParameter;
    if (format->f->alphaHint == 0)
        format->alphaHint = alphaIsOne;
    return kvImageNoError;
}

/* (chroma's description is Cb's) */
const vImageChannelDescription *vImageCVImageFormat_GetChannelDescription(vImageConstCVImageFormatRef format,
                                                                          vImageBufferTypeCode type)
{
    if (!valid(format))
        return NULL;
    if (type == kvImageBufferTypeCode_Chroma)
        type = CB;
    return type < 32 && format->hasDesc[type] ? &format->desc[type] : NULL;
}

vImage_Error vImageCVImageFormat_CopyChannelDescription(vImageCVImageFormatRef format, const vImageChannelDescription *desc,
                                                        vImageBufferTypeCode type)
{
    if (!valid(format) || !desc)
        return kvImageInvalidParameter;
    if (type == kvImageBufferTypeCode_Chroma)
        type = CB;
    if (type >= 32 || !format->hasDesc[type])
        return kvImageInvalidParameter;
    format->desc[type] = *desc;
    if (type == CB && format->hasDesc[CR])
        format->desc[CR] = *desc;
    return kvImageNoError;
}

void *vImageCVImageFormat_GetUserData(vImageConstCVImageFormatRef format)
{
    return valid(format) ? format->userData : NULL;
}

vImage_Error vImageCVImageFormat_SetUserData(vImageCVImageFormatRef format, void *userData,
                                             void (*userDataReleaseCallback)(vImageCVImageFormatRef, void *))
{
    if (!valid(format))
        return kvImageInvalidImageFormat;
    if (format->userRelease)
        format->userRelease(format, format->userData);
    format->userData = userData;
    format->userRelease = userDataReleaseCallback;
    return kvImageNoError;
}

vImageCVImageFormatRef vImageCVImageFormat_CreateWithCVPixelBuffer(CVPixelBufferRef buffer)
{
    if (!buffer || !have_cv())
        return NULL;
    uint32_t code = cv.GetPixelFormatType(buffer);
    const vImage_ARGBToYpCbCrMatrix *matrix = NULL;
    CFStringRef siting = NULL;
    if (cv.GetAttachment && cv.matrixKey) {
        CFTypeRef m = cv.GetAttachment(buffer, *cv.matrixKey, NULL);
        if (m && cv.matrix601 && CFEqual(m, *cv.matrix601))
            matrix = kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4;
        else if (m && cv.matrix709 && CFEqual(m, *cv.matrix709))
            matrix = kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2;
        if (cv.chromaKey)
            siting = cv.GetAttachment(buffer, *cv.chromaKey, NULL);
    }
    CGColorSpaceRef space = NULL;
    if (cv.GetColorSpace && cv.GetColorSpace(buffer))
        space = CGColorSpaceRetain(cv.GetColorSpace(buffer));
    else if (cv.CopyAttachments && cv.CreateColorSpaceFromAttachments) {
        CFDictionaryRef attachments = cv.CopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
        if (attachments) {
            space = cv.CreateColorSpaceFromAttachments(attachments);
            CFRelease(attachments);
        }
    }
    vImageCVImageFormatRef fmt = vImageCVImageFormat_Create(code, matrix, siting, space, 0);
    if (space)
        CGColorSpaceRelease(space);
    return fmt;
}

/* MARK: - Colour spaces from primaries and transfer functions */

/* a minimal ICC v4 display profile: description, white point, chromatic adaptation,
   colorants adapted to D50, and parametric curves */
static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24), p[1] = (uint8_t)(v >> 16), p[2] = (uint8_t)(v >> 8), p[3] = (uint8_t)v;
}
static void put_s15(uint8_t *p, double v) { put32(p, (uint32_t)(int32_t)lround(v * 65536)); }

static void mat3_mul(const double a[3][3], const double b[3][3], double out[3][3])
{
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            out[r][c] = a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c];
}

static bool mat3_inv(const double m[3][3], double out[3][3])
{
    double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
                 m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if (fabs(det) < 1e-12)
        return false;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            int r1 = (c + 1) % 3, r2 = (c + 2) % 3, c1 = (r + 1) % 3, c2 = (r + 2) % 3;
            out[r][c] = (m[r1][c1] * m[r2][c2] - m[r1][c2] * m[r2][c1]) / det;
        }
    return true;
}

/* Bradford adaptation from white (X, Y = 1, Z) to D50 */
static void bradford(const double white[3], double out[3][3])
{
    static const double B[3][3] = {{0.8951, 0.2664, -0.1614}, {-0.7502, 1.7135, 0.0367}, {0.0389, -0.0685, 1.0296}};
    static const double d50[3] = {0.9642, 1.0, 0.8249};
    double Bi[3][3], cone[3], coneD50[3], diag[3][3] = {{0}}, t[3][3];
    mat3_inv(B, Bi);
    for (int i = 0; i < 3; ++i) {
        cone[i] = B[i][0] * white[0] + B[i][1] * white[1] + B[i][2] * white[2];
        coneD50[i] = B[i][0] * d50[0] + B[i][1] * d50[1] + B[i][2] * d50[2];
        diag[i][i] = coneD50[i] / cone[i];
    }
    mat3_mul(diag, B, t);
    mat3_mul(Bi, t, out);
}

/* the decoding curve (non-linear to linear) of an encoding transfer function, as an ICC
   parametric curve of type 4: Y = (aX + b)^g + e for X >= d, cX + f below */
static size_t write_curve(uint8_t *p, const vImageTransferFunction *tf)
{
    double gamma = 1.0 / tf->gamma, c1g = pow(tf->c1, -tf->gamma ? -1.0 / gamma : 0);
    (void)c1g;
    /* R = (((R' - c3) / c0)^(1/gamma) - c2) / c1 = (a R' + b)^g + e */
    double g = 1.0 / tf->gamma, scale = pow(1.0 / tf->c1, 1.0 / g);
    double a = scale / tf->c0, b = -scale * tf->c3 / tf->c0, e = -tf->c2 / tf->c1;
    double d = isfinite(tf->cutoff) ? tf->c4 * tf->cutoff + tf->c5 : -1e9;
    double c = tf->c4 ? 1.0 / tf->c4 : 0, f = tf->c4 ? -tf->c5 / tf->c4 : 0;
    memcpy(p, "para", 4);
    put32(p + 4, 0);
    p[8] = 0, p[9] = 4, p[10] = 0, p[11] = 0;
    const double params[7] = {g, a, b, c, d < -32767 ? -32767 : d, e, f};
    for (int i = 0; i < 7; ++i)
        put_s15(p + 12 + 4 * i, params[i]);
    return 12 + 28;
}

static CGColorSpaceRef make_icc(const double xyz[3][3], bool gray, const double white[3], const vImageTransferFunction *tf,
                                vImage_Error *error)
{
    uint8_t profile[1024] = {0};
    size_t n = 128;
    const char *tags[] = {"desc", "wtpt", "chad", "rXYZ", "gXYZ", "bXYZ", "rTRC"};
    int count = gray ? 4 : 9;
    uint8_t *table = profile + 128;
    put32(table, (uint32_t)count);
    n += 4 + 12 * (size_t)count;
    uint32_t offsets[10], sizes[10];
    int t = 0;
    /* desc */
    offsets[t] = (uint32_t)n;
    memcpy(profile + n, "mluc", 4);
    put32(profile + n + 8, 1);
    put32(profile + n + 12, 12);
    memcpy(profile + n + 16, "enUS", 4);
    const char *name = gray ? "vImage gray" : "vImage RGB";
    size_t len = strlen(name);
    put32(profile + n + 20, (uint32_t)(len * 2));
    put32(profile + n + 24, 28);
    for (size_t i = 0; i < len; ++i)
        profile[n + 28 + 2 * i + 1] = (uint8_t)name[i];
    sizes[t] = (uint32_t)(28 + 2 * len);
    n += (sizes[t] + 3) & ~3u;
    ++t;
    /* wtpt: D50 (v4) */
    offsets[t] = (uint32_t)n;
    memcpy(profile + n, "XYZ ", 4);
    put_s15(profile + n + 8, 0.9642), put_s15(profile + n + 12, 1.0), put_s15(profile + n + 16, 0.8249);
    sizes[t] = 20, n += 20, ++t;
    /* chad */
    double adapt[3][3];
    bradford(white, adapt);
    offsets[t] = (uint32_t)n;
    memcpy(profile + n, "sf32", 4);
    for (int i = 0; i < 9; ++i)
        put_s15(profile + n + 8 + 4 * i, adapt[i / 3][i % 3]);
    sizes[t] = 44, n += 44, ++t;
    if (!gray)
        for (int k = 0; k < 3; ++k) {
            /* colorant k: column k of the RGB to XYZ matrix, adapted to D50 */
            double col[3] = {xyz[0][k], xyz[1][k], xyz[2][k]}, a[3];
            for (int i = 0; i < 3; ++i)
                a[i] = adapt[i][0] * col[0] + adapt[i][1] * col[1] + adapt[i][2] * col[2];
            offsets[t] = (uint32_t)n;
            memcpy(profile + n, "XYZ ", 4);
            put_s15(profile + n + 8, a[0]), put_s15(profile + n + 12, a[1]), put_s15(profile + n + 16, a[2]);
            sizes[t] = 20, n += 20, ++t;
        }
    offsets[t] = (uint32_t)n;
    sizes[t] = (uint32_t)write_curve(profile + n, tf);
    n += sizes[t];
    int curve = t++;
    /* the tag table: the TRCs share one curve */
    const char *order[9] = {"desc", "wtpt", "chad", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"};
    const char *grayOrder[4] = {"desc", "wtpt", "chad", "kTRC"};
    for (int i = 0; i < count; ++i) {
        const char *sig = gray ? grayOrder[i] : order[i];
        int which = gray ? (i < 3 ? i : curve) : (i < 6 ? i : curve);
        memcpy(table + 4 + 12 * i, sig, 4);
        put32(table + 8 + 12 * i, offsets[which]);
        put32(table + 12 + 12 * i, sizes[which]);
    }
    (void)tags;
    /* the header */
    put32(profile, (uint32_t)n);
    put32(profile + 8, 0x04300000);
    memcpy(profile + 12, "mntr", 4);
    memcpy(profile + 16, gray ? "GRAY" : "RGB ", 4);
    memcpy(profile + 20, "XYZ ", 4);
    memcpy(profile + 36, "acsp", 4);
    put_s15(profile + 68, 0.9642), put_s15(profile + 72, 1.0), put_s15(profile + 76, 0.8249);
    CFDataRef data = CFDataCreate(NULL, profile, (CFIndex)n);
    CGColorSpaceRef space = data ? CGColorSpaceCreateWithICCData(data) : NULL;
    if (data)
        CFRelease(data);
    if (error)
        *error = space ? kvImageNoError : kvImageInternalError;
    return space;
}

CGColorSpaceRef vImageCreateRGBColorSpaceWithPrimariesAndTransferFunction(const vImageRGBPrimaries *primaries,
                                                                          const vImageTransferFunction *tf,
                                                                          CGColorRenderingIntent intent, vImage_Flags flags,
                                                                          vImage_Error *error)
{
    if (!primaries || !tf) {
        if (error)
            *error = kvImageNullPointerArgument;
        return NULL;
    }
    if (tf->gamma == 0 || tf->c0 == 0 || tf->c1 == 0) {
        if (error)
            *error = kvImageInvalidParameter;
        return NULL;
    }
    /* RGB to XYZ: the primaries' xyz scaled so that RGB (1, 1, 1) is the white point */
    const double px[3] = {primaries->red_x, primaries->green_x, primaries->blue_x},
                 py[3] = {primaries->red_y, primaries->green_y, primaries->blue_y};
    double P[3][3], Pi[3][3], white[3] = {primaries->white_x / primaries->white_y, 1,
                                          (1 - primaries->white_x - primaries->white_y) / primaries->white_y};
    for (int k = 0; k < 3; ++k)
        P[0][k] = px[k] / py[k], P[1][k] = 1, P[2][k] = (1 - px[k] - py[k]) / py[k];
    if (!mat3_inv(P, Pi)) {
        if (error)
            *error = kvImageInvalidParameter;
        return NULL;
    }
    double s[3], M[3][3];
    for (int i = 0; i < 3; ++i)
        s[i] = Pi[i][0] * white[0] + Pi[i][1] * white[1] + Pi[i][2] * white[2];
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            M[r][c] = P[r][c] * s[c];
    return make_icc(M, false, white, tf, error);
}

CGColorSpaceRef vImageCreateMonochromeColorSpaceWithWhitePointAndTransferFunction(const vImageWhitePoint *whitePoint,
                                                                                  const vImageTransferFunction *tf,
                                                                                  CGColorRenderingIntent intent,
                                                                                  vImage_Flags flags, vImage_Error *error)
{
    if (!whitePoint || !tf) {
        if (error)
            *error = kvImageNullPointerArgument;
        return NULL;
    }
    if (tf->gamma == 0 || tf->c0 == 0 || tf->c1 == 0 || whitePoint->white_y == 0) {
        if (error)
            *error = kvImageInvalidParameter;
        return NULL;
    }
    double white[3] = {whitePoint->white_x / whitePoint->white_y, 1,
                       (1 - whitePoint->white_x - whitePoint->white_y) / whitePoint->white_y};
    const double none[3][3] = {{0}};
    return make_icc(none, true, white, tf, error);
}

/* MARK: - Converters */

struct vImageCVConversion {
    vImageBufferTypeCode srcOrder[4], dstOrder[4];
    bool toCV;
    vImageCVImageFormatRef format;
    vImageConverterRef cg;            /* between the user's CG format and the CV side's */
    vImage_YpCbCrToARGB toRGB;        /* Y'CbCr formats */
    vImage_ARGBToYpCbCr toYUV;
    vImageARGBType rgbType;           /* the intermediate's */
    size_t rgbBytes;
};

void vimage_cv_release(const struct vImageCVConversion *c)
{
    if (!c)
        return;
    if (c->cg)
        vImageConverter_Release(c->cg);
    vImageCVImageFormat_Release(c->format);
    free((void *)c);
}

const vImageBufferTypeCode *vimage_cv_source_order(const struct vImageCVConversion *c) { return c->srcOrder; }

const vImageBufferTypeCode *vimage_cv_destination_order(const struct vImageCVConversion *c) { return c->dstOrder; }

/* the CG format a CV format's samples (or a Y'CbCr format's intermediate RGB) are in */
static vImage_Error cg_side(vImageCVImageFormatRef fmt, vImage_CGImageFormat *out, CGColorSpaceRef *owned)
{
    const CVFormat *f = fmt->f;
    *owned = NULL;
    if (!fmt->space)
        return kvImageCVImageFormat_ColorSpace;
    memset(out, 0, sizeof(*out));
    out->colorSpace = fmt->space;
    if (f->kind == YUV) {
        bool deep = f->ycbcr == kvImage422CbYpCrYp16 || f->ycbcr == kvImage444AYpCbCr16;
        out->bitsPerComponent = deep ? 16 : 8;
        out->bitsPerPixel = deep ? 64 : 32;
        out->bitmapInfo = kCGImageAlphaFirst | (deep ? kCGBitmapByteOrder16Little : 0);
        if (f->a[2] == 0 || fmt->alphaHint)
            out->bitmapInfo = (out->bitmapInfo & ~kCGBitmapAlphaInfoMask) | kCGImageAlphaNoneSkipFirst;
        return kvImageNoError;
    }
    if (f->kind == TWO)
        return kvImageInvalidCVImageFormat;
    out->bitsPerComponent = f->bpc;
    out->bitsPerPixel = f->bpp;
    out->bitmapInfo = f->info;
    if (f->kind == BGR24)
        out->bitmapInfo = kCGImageAlphaNone; /* read through a permutation */
    if (fmt->alphaHint == 1 && (f->info & kCGBitmapAlphaInfoMask) == kCGImageAlphaFirst)
        out->bitmapInfo = (out->bitmapInfo & ~kCGBitmapAlphaInfoMask) | kCGImageAlphaNoneSkipFirst;
    else if (fmt->alphaHint == 1 && (f->info & kCGBitmapAlphaInfoMask) == kCGImageAlphaLast)
        out->bitmapInfo = (out->bitmapInfo & ~kCGBitmapAlphaInfoMask) | kCGImageAlphaNoneSkipLast;
    if (f->whiteIsZero && f->model == 2) {
        /* indexed gray, white at zero: an inverted gray ramp */
        static const CGFloat inverted[2] = {1, 0};
        out->decode = inverted;
    }
    return kvImageNoError;
}

/* (the colour space is checked first, as Apple's does) */
static vImage_Error ycbcr_ready(vImageCVImageFormatRef fmt)
{
    if (!fmt->space)
        return kvImageCVImageFormat_ColorSpace;
    if (fmt->f->kind != YUV)
        return kvImageNoError;
    if (!fmt->matrix)
        return kvImageCVImageFormat_ConversionMatrix;
    if (subsampled(fmt->f) && !fmt->siting)
        return kvImageCVImageFormat_ChromaSiting;
    return kvImageNoError;
}

static vImage_YpCbCrPixelRange range_of(vImageCVImageFormatRef fmt)
{
    const vImageChannelDescription *y = &fmt->desc[L], *c = &fmt->desc[CB];
    return (vImage_YpCbCrPixelRange){(int32_t)y->zero, (int32_t)c->zero, (int32_t)y->full, (int32_t)c->full,
                                     (int32_t)fmin(y->max, 65535), (int32_t)fmax(y->min, 0), (int32_t)fmin(c->max, 65535),
                                     (int32_t)fmax(c->min, 0)};
}

/* the inverse of an RGB to Y'CbCr matrix, in vImage's Y'CbCr to RGB form */
static vImage_YpCbCrToARGBMatrix inverse(const vImage_ARGBToYpCbCrMatrix *m)
{
    const double M[3][3] = {{m->R_Yp, m->G_Yp, m->B_Yp}, {m->R_Cb, m->G_Cb, m->B_Cb_R_Cr}, {m->B_Cb_R_Cr, m->G_Cr, m->B_Cr}};
    double N[3][3];
    mat3_inv(M, N);
    return (vImage_YpCbCrToARGBMatrix){(float)N[0][0], (float)N[0][2], (float)N[1][2], (float)N[1][1], (float)N[2][1]};
}

static vImageConverterRef cv_converter(const vImage_CGImageFormat *cgFormat, vImageCVImageFormatRef cvFormat,
                                       const CGFloat *backgroundColor, vImage_Flags flags, vImage_Error *error, bool toCV)
{
    vImage_Error e;
#define FAIL(code)                                                                                       \
    do {                                                                                                 \
        if (error)                                                                                       \
            *error = (code);                                                                             \
        return NULL;                                                                                     \
    } while (0)
    if (!cgFormat || !valid(cvFormat))
        FAIL(kvImageNullPointerArgument);
    if (flags & ~(vImage_Flags)(kvImagePrintDiagnosticsToConsole | kvImageDoNotTile | kvImageHighQualityResampling))
        FAIL(kvImageUnknownFlagsBit);
    if ((e = ycbcr_ready(cvFormat)))
        FAIL(e);
    vImage_CGImageFormat side;
    CGColorSpaceRef owned;
    if ((e = cg_side(cvFormat, &side, &owned)))
        FAIL(e);
    struct vImageCVConversion *c = calloc(1, sizeof(*c));
    if (!c)
        FAIL(kvImageMemoryAllocationError);
    c->toCV = toCV;
    c->format = vImageCVImageFormat_Copy(cvFormat);
    c->cg = toCV ? vImageConverter_CreateWithCGImageFormat(cgFormat, &side, backgroundColor, flags & ~kvImageHighQualityResampling, &e)
                 : vImageConverter_CreateWithCGImageFormat(&side, cgFormat, backgroundColor, flags & ~kvImageHighQualityResampling, &e);
    if (!c->cg) {
        vimage_cv_release(c);
        FAIL(e);
    }
    const CVFormat *f = cvFormat->f;
    vImageBufferTypeCode cgOrder[2] = {kvImageBufferTypeCode_CGFormat, 0}, chunky[2] = {kvImageBufferTypeCode_Chunky, 0};
    const vImageBufferTypeCode *cvOrder = f->kind == YUV ? f->order : f->kind == CG ? cgOrder : chunky;
    memcpy(toCV ? c->srcOrder : c->dstOrder, cgOrder, sizeof(cgOrder));
    for (int i = 0; i < 3 && cvOrder[i]; ++i)
        (toCV ? c->dstOrder : c->srcOrder)[i] = cvOrder[i];
    if (f->kind == YUV) {
        bool deep = side.bitsPerComponent == 16;
        c->rgbType = deep ? kvImageARGB16U : kvImageARGB8888;
        c->rgbBytes = deep ? 8 : 4;
        vImage_YpCbCrPixelRange range = range_of(cvFormat);
        vImageYpCbCrType t = f->ycbcr;
        if (toCV)
            e = vImageConvert_ARGBToYpCbCr_GenerateConversion(cvFormat->matrix, &range, &c->toYUV, c->rgbType, t, 0);
        else {
            vImage_YpCbCrToARGBMatrix inv = inverse(cvFormat->matrix);
            e = vImageConvert_YpCbCrToARGB_GenerateConversion(&inv, &range, &c->toRGB, t, c->rgbType, 0);
        }
        if (e) {
            vimage_cv_release(c);
            FAIL(e);
        }
    }
    vImageConverterRef conv = vimage_converter_alloc();
    if (!conv) {
        vimage_cv_release(c);
        FAIL(kvImageMemoryAllocationError);
    }
    vimage_converter_set_cv(conv, c);
    if (error)
        *error = kvImageNoError;
    return conv;
#undef FAIL
}

vImageConverterRef vImageConverter_CreateForCGToCVImageFormat(const vImage_CGImageFormat *srcFormat,
                                                              vImageCVImageFormatRef destFormat,
                                                              const CGFloat *backgroundColor, vImage_Flags flags,
                                                              vImage_Error *error)
{
    return cv_converter(srcFormat, destFormat, backgroundColor, flags, error, true);
}

vImageConverterRef vImageConverter_CreateForCVToCGImageFormat(vImageCVImageFormatRef srcFormat,
                                                              const vImage_CGImageFormat *destFormat,
                                                              const CGFloat *backgroundColor, vImage_Flags flags,
                                                              vImage_Error *error)
{
    return cv_converter(destFormat, srcFormat, backgroundColor, flags, error, false);
}

/* 24-bit BGR, as RGB in a copy */
static vImage_Error swap24(const vImage_Buffer *in, vImage_Buffer *out)
{
    out->height = in->height;
    out->width = in->width;
    out->rowBytes = in->width * 3;
    out->data = malloc(out->rowBytes * out->height + 1);
    if (!out->data)
        return kvImageMemoryAllocationError;
    for (vImagePixelCount y = 0; y < in->height; ++y)
        for (vImagePixelCount x = 0; x < in->width; ++x)
            for (int k = 0; k < 3; ++k)
                ROW(out, y)[3 * x + k] = CROW(in, y)[3 * x + 2 - k];
    return kvImageNoError;
}

vImage_Error vimage_cv_convert(vImageConverterRef converter, const struct vImageCVConversion *c, const vImage_Buffer *srcs,
                               const vImage_Buffer *dests, vImage_Flags flags)
{
    (void)converter;
    const CVFormat *f = c->format->f;
    const vImage_Buffer *cgBuf = c->toCV ? &srcs[0] : &dests[0];
    if (flags & kvImageGetTempBufferSize)
        return (vImage_Error)(cgBuf->width * 64 + 1024);
    if (f->kind != YUV) {
        vImage_Buffer swapped = {0};
        vImage_Error e;
        if (f->kind == BGR24 && !c->toCV) {
            if ((e = swap24(&srcs[0], &swapped)))
                return e;
            e = vimage_convert_cg(c->cg, &swapped, &dests[0]);
        } else if (f->kind == BGR24) {
            vImage_Buffer tmp = {malloc(dests[0].width * 3 * dests[0].height + 1), dests[0].height, dests[0].width,
                                 dests[0].width * 3};
            if (!tmp.data)
                return kvImageMemoryAllocationError;
            e = vimage_convert_cg(c->cg, &srcs[0], &tmp);
            if (!e && !(e = swap24(&tmp, &swapped)))
                for (vImagePixelCount y = 0; y < dests[0].height; ++y)
                    memcpy(ROW(&dests[0], y), CROW(&swapped, y), dests[0].width * 3);
            free(tmp.data);
        } else
            e = vimage_convert_cg(c->cg, &srcs[0], &dests[0]);
        free(swapped.data);
        return e;
    }
    vImage_Buffer rgb = {NULL, cgBuf->height, cgBuf->width, cgBuf->width * c->rgbBytes};
    rgb.data = malloc(rgb.rowBytes * rgb.height + 1);
    if (!rgb.data)
        return kvImageMemoryAllocationError;
    vImage_Error e = kvImageNoError;
    if (!c->toCV) {
        const vImage_YpCbCrToARGB *info = &c->toRGB;
        switch (f->ycbcr) {
        case kvImage422CbYpCrYp8:
            e = vImageConvert_422CbYpCrYp8ToARGB8888(&srcs[0], &rgb, info, NULL, 255, 0);
            break;
        case kvImage422YpCbYpCr8:
            e = vImageConvert_422YpCbYpCr8ToARGB8888(&srcs[0], &rgb, info, NULL, 255, 0);
            break;
        case kvImage420Yp8_CbCr8:
            e = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcs[0], &srcs[1], &rgb, info, NULL, 255, 0);
            break;
        case kvImage420Yp8_Cb8_Cr8:
            e = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&srcs[0], &srcs[1], &srcs[2], &rgb, info, NULL, 255, 0);
            break;
        case kvImage444CrYpCb8:
            e = vImageConvert_444CrYpCb8ToARGB8888(&srcs[0], &rgb, info, NULL, 255, 0);
            break;
        case kvImage444CbYpCrA8:
            e = vImageConvert_444CbYpCrA8ToARGB8888(&srcs[0], &rgb, info, NULL, 0);
            break;
        case kvImage444AYpCbCr8:
            e = vImageConvert_444AYpCbCr8ToARGB8888(&srcs[0], &rgb, info, NULL, 0);
            break;
        case kvImage422CbYpCrYp8_AA8:
            e = vImageConvert_422CbYpCrYp8_AA8ToARGB8888(&srcs[0], &srcs[1], &rgb, info, NULL, 0);
            break;
        case kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10:
            e = vImageConvert_422CrYpCbYpCbYpCbYpCrYpCrYp10ToARGB8888(&srcs[0], &rgb, info, NULL, 255, 0);
            break;
        case kvImage444CrYpCb10:
            e = vImageConvert_444CrYpCb10ToARGB8888(&srcs[0], &rgb, info, NULL, 255, 0);
            break;
        case kvImage422CbYpCrYp16:
            e = vImageConvert_422CbYpCrYp16ToARGB16U(&srcs[0], &rgb, info, NULL, 65535, 0);
            break;
        default:
            e = vImageConvert_444AYpCbCr16ToARGB16U(&srcs[0], &rgb, info, NULL, 0);
            break;
        }
        if (!e)
            e = vimage_convert_cg(c->cg, &rgb, &dests[0]);
    } else {
        e = vimage_convert_cg(c->cg, &srcs[0], &rgb);
        if (!e) {
            /* (alpha is copied as it is, whatever its channel description says, as Apple's) */
            const vImage_ARGBToYpCbCr *info = &c->toYUV;
            switch (f->ycbcr) {
            case kvImage422CbYpCrYp8:
                e = vImageConvert_ARGB8888To422CbYpCrYp8(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage422YpCbYpCr8:
                e = vImageConvert_ARGB8888To422YpCbYpCr8(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage420Yp8_CbCr8:
                e = vImageConvert_ARGB8888To420Yp8_CbCr8(&rgb, &dests[0], &dests[1], info, NULL, 0);
                break;
            case kvImage420Yp8_Cb8_Cr8:
                e = vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&rgb, &dests[0], &dests[1], &dests[2], info, NULL, 0);
                break;
            case kvImage444CrYpCb8:
                e = vImageConvert_ARGB8888To444CrYpCb8(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage444CbYpCrA8:
                e = vImageConvert_ARGB8888To444CbYpCrA8(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage444AYpCbCr8:
                e = vImageConvert_ARGB8888To444AYpCbCr8(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage422CbYpCrYp8_AA8:
                e = vImageConvert_ARGB8888To422CbYpCrYp8_AA8(&rgb, &dests[0], &dests[1], info, NULL, 0);
                break;
            case kvImage422CrYpCbYpCbYpCbYpCrYpCrYp10:
                e = vImageConvert_ARGB8888To422CrYpCbYpCbYpCbYpCrYpCrYp10(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage444CrYpCb10:
                e = vImageConvert_ARGB8888To444CrYpCb10(&rgb, &dests[0], info, NULL, 0);
                break;
            case kvImage422CbYpCrYp16:
                e = vImageConvert_ARGB16UTo422CbYpCrYp16(&rgb, &dests[0], info, NULL, 0);
                break;
            default:
                e = vImageConvert_ARGB16UTo444AYpCbCr16(&rgb, &dests[0], info, NULL, 0);
                break;
            }
        }
    }
    free(rgb.data);
    return e;
}

/* MARK: - CVPixelBuffer import and export */

/* the planes of a locked pixel buffer as vImage_Buffers, in the converter's order */
static int planes_of(CVPixelBufferRef pb, vImage_Buffer *planes)
{
    size_t w = cv.GetWidth(pb), h = cv.GetHeight(pb);
    if (cv.IsPlanar && cv.IsPlanar(pb) && cv.GetPlaneCount) {
        size_t n = cv.GetPlaneCount(pb);
        for (size_t i = 0; i < n && i < 3; ++i)
            planes[i] = (vImage_Buffer){cv.GetBaseAddressOfPlane(pb, i), h, w, cv.GetBytesPerRowOfPlane(pb, i)};
        /* (the vImage functions read chroma planes at half the luminance's position) */
        return (int)n;
    }
    planes[0] = (vImage_Buffer){cv.GetBaseAddress(pb), h, w, cv.GetBytesPerRow(pb)};
    return 1;
}

vImage_Error vImageBuffer_InitForCopyToCVPixelBuffer(vImage_Buffer *buffers, const vImageConverterRef converter,
                                                     const CVPixelBufferRef pixelBuffer, vImage_Flags flags)
{
    if (!buffers || !converter || !pixelBuffer)
        return kvImageNullPointerArgument;
    if (!have_cv())
        return kvImageInternalError;
    unsigned long n = vImageConverter_GetNumberOfDestinationBuffers(converter);
    size_t w = cv.GetWidth(pixelBuffer), h = cv.GetHeight(pixelBuffer);
    for (unsigned long i = 0; i < n; ++i)
        buffers[i] = (vImage_Buffer){NULL, h, w, 0};
    if (flags & kvImageNoAllocate)
        return kvImageNoError;
    /* buffers for the planes, sized as the pixel buffer's */
    if (cv.Lock(pixelBuffer, kCVPixelBufferLock_ReadOnly))
        return kvImageInvalidImageObject;
    vImage_Buffer planes[3];
    int count = planes_of(pixelBuffer, planes);
    for (int i = 0; i < count && (unsigned long)i < n; ++i) {
        buffers[i].rowBytes = planes[i].rowBytes;
        buffers[i].data = malloc(planes[i].rowBytes * h + 1);
        if (!buffers[i].data) {
            cv.Unlock(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            return kvImageMemoryAllocationError;
        }
    }
    cv.Unlock(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return kvImageNoError;
}

vImage_Error vImageBuffer_InitForCopyFromCVPixelBuffer(vImage_Buffer *buffers, const vImageConverterRef converter,
                                                       const CVPixelBufferRef pixelBuffer, vImage_Flags flags)
{
    if (!buffers || !converter || !pixelBuffer)
        return kvImageNullPointerArgument;
    if (!have_cv())
        return kvImageInternalError;
    if (cv.Lock(pixelBuffer, kCVPixelBufferLock_ReadOnly))
        return kvImageInvalidImageObject;
    vImage_Buffer planes[3];
    int count = planes_of(pixelBuffer, planes);
    unsigned long n = vImageConverter_GetNumberOfSourceBuffers(converter);
    for (unsigned long i = 0; i < n; ++i)
        buffers[i] = (int)i < count ? planes[i] : (vImage_Buffer){0};
    if (!(flags & kvImageNoAllocate))
        for (unsigned long i = 0; i < n && (int)i < count; ++i) {
            size_t bytes = planes[i].rowBytes * planes[i].height;
            void *copy = malloc(bytes + 1);
            if (!copy) {
                cv.Unlock(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                return kvImageMemoryAllocationError;
            }
            memcpy(copy, planes[i].data, bytes);
            buffers[i].data = copy;
        }
    cv.Unlock(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return kvImageNoError;
}

vImage_Error vImageBuffer_InitWithCVPixelBuffer(vImage_Buffer *buffer, vImage_CGImageFormat *desiredFormat,
                                                CVPixelBufferRef cvPixelBuffer, vImageCVImageFormatRef cvImageFormat,
                                                const CGFloat *backgroundColor, vImage_Flags flags)
{
    if (!buffer)
        return kvImageInvalidParameter;
    if (!cvPixelBuffer)
        return kvImageInvalidImageObject;
    if (!desiredFormat)
        return kvImageInvalidImageFormat;
    if (!have_cv())
        return kvImageInternalError;
    vImageCVImageFormatRef fmt = cvImageFormat ? cvImageFormat : vImageCVImageFormat_CreateWithCVPixelBuffer(cvPixelBuffer);
    if (!fmt)
        return kvImageInvalidCVImageFormat;
    vImage_Error e;
    vImageConverterRef conv = vImageConverter_CreateForCVToCGImageFormat(fmt, desiredFormat, backgroundColor,
                                                                         flags & (kvImageDoNotTile | kvImagePrintDiagnosticsToConsole | kvImageHighQualityResampling), &e);
    if (fmt != cvImageFormat)
        vImageCVImageFormat_Release(fmt);
    if (!conv)
        return e;
    size_t w = cv.GetWidth(cvPixelBuffer), h = cv.GetHeight(cvPixelBuffer);
    if (!(flags & kvImageNoAllocate)) {
        e = vImageBuffer_Init(buffer, h, w, desiredFormat->bitsPerPixel, 0);
        if (e) {
            vImageConverter_Release(conv);
            return e;
        }
    } else if (buffer->height != h || buffer->width != w) {
        vImageConverter_Release(conv);
        return kvImageBufferSizeMismatch;
    }
    if (cv.Lock(cvPixelBuffer, kCVPixelBufferLock_ReadOnly)) {
        vImageConverter_Release(conv);
        return kvImageInvalidImageObject;
    }
    vImage_Buffer planes[3];
    planes_of(cvPixelBuffer, planes);
    e = vImageConvert_AnyToAny(conv, planes, buffer, NULL, flags & kvImageDoNotTile);
    cv.Unlock(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
    vImageConverter_Release(conv);
    return e;
}

vImage_Error vImageBuffer_CopyToCVPixelBuffer(const vImage_Buffer *buffer, const vImage_CGImageFormat *bufferFormat,
                                              CVPixelBufferRef cvPixelBuffer, vImageCVImageFormatRef cvImageFormat,
                                              const CGFloat *backgroundColor, vImage_Flags flags)
{
    if (!buffer)
        return kvImageInvalidParameter;
    if (!cvPixelBuffer)
        return kvImageInvalidImageObject;
    if (!bufferFormat)
        return kvImageInvalidImageFormat;
    if (!have_cv())
        return kvImageInternalError;
    vImageCVImageFormatRef fmt = cvImageFormat ? cvImageFormat : vImageCVImageFormat_CreateWithCVPixelBuffer(cvPixelBuffer);
    if (!fmt)
        return kvImageInvalidCVImageFormat;
    vImage_Error e;
    vImageConverterRef conv = vImageConverter_CreateForCGToCVImageFormat(bufferFormat, fmt, backgroundColor,
                                                                         flags & (kvImageDoNotTile | kvImagePrintDiagnosticsToConsole | kvImageHighQualityResampling), &e);
    if (fmt != cvImageFormat)
        vImageCVImageFormat_Release(fmt);
    if (!conv)
        return e;
    if (buffer->height != cv.GetHeight(cvPixelBuffer) || buffer->width != cv.GetWidth(cvPixelBuffer)) {
        vImageConverter_Release(conv);
        return kvImageBufferSizeMismatch;
    }
    if (cv.Lock(cvPixelBuffer, 0)) {
        vImageConverter_Release(conv);
        return kvImageInvalidImageObject;
    }
    vImage_Buffer planes[3];
    planes_of(cvPixelBuffer, planes);
    e = vImageConvert_AnyToAny(conv, buffer, planes, NULL, flags & kvImageDoNotTile);
    cv.Unlock(cvPixelBuffer, 0);
    vImageConverter_Release(conv);
    return e;
}

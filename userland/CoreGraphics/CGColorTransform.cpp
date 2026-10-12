/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Private CoreGraphics calls about colour that ColorSync Utility and others make
 * (signatures read from Apple's binary): colour transforms that convert images to a
 * colour space, ColorSync profiles of colour spaces (through ColorSync, looked up when
 * first needed, since ColorSync sits on CoreFoundation alone), a colour space's process
 * model and equality, a context's type and interpolation-quality range, image copies
 * with a rendering intent, and the PDF/X keys. GPU code fragments for transforms and
 * PostScript contexts aren't made on Finch.
 */
#include "CGInternal.h"
#include "CGContextInternal.h"
#include "CGColorSpaceInternal.h"
#include "CGImageInternal.h"
#include <dlfcn.h>

#define CG_EXTERN_C extern "C" __attribute__((visibility("default")))

CG_EXTERN_C const CFStringRef kCGColorTransformBlackPointCompensation = CFSTR("kCGColorTransformBlackPointCompensation");
CG_EXTERN_C const CFStringRef kCGPDFXTrapped = CFSTR("Trapped");
CG_EXTERN_C const CFStringRef kCGPDFXVersion = CFSTR("GTS_PDFXVersion");

/* MARK: - Colour transforms */

struct CGColorTransform {
    CGColorSpaceRef space;
    CFDictionaryRef options;
};
typedef struct CGColorTransform *CGColorTransformRef;

CG_EXTERN_C CGColorTransformRef
CGColorTransformCreate(CGColorSpaceRef space, CFDictionaryRef options)
{
    if (!space)
        return NULL;
    CGColorTransformRef t = (CGColorTransformRef)calloc(1, sizeof *t);
    t->space = CGColorSpaceRetain(space);
    t->options = options ? (CFDictionaryRef)CFRetain(options) : NULL;
    return t;
}

CG_EXTERN_C CGColorSpaceRef
CGColorTransformGetColorSpace(CGColorTransformRef t)
{
    return t ? t->space : NULL;
}

CG_EXTERN_C void
CGColorTransformRelease(CGColorTransformRef t)
{
    if (!t)
        return;
    CGColorSpaceRelease(t->space);
    if (t->options)
        CFRelease(t->options);
    free(t);
}

/* The image redrawn in the transform's space, 8 bits a component and without alpha, as
   Apple's converts it. */
CG_EXTERN_C CGImageRef
CGColorTransformConvertImage(CGColorTransformRef t, CGImageRef image, CGColorRenderingIntent intent, CFDictionaryRef options)
{
    if (!t || !image)
        return NULL;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    size_t n = CGColorSpaceGetNumberOfComponents(t->space);
    CGColorSpaceModel model = CGColorSpaceGetModel(t->space);
    if (!w || !h || (model != kCGColorSpaceModelMonochrome && model != kCGColorSpaceModelRGB && model != kCGColorSpaceModelCMYK))
        return NULL;
    size_t bpp = model == kCGColorSpaceModelRGB ? 32 : 8 * n;
    CGBitmapInfo info = model == kCGColorSpaceModelRGB ? (CGBitmapInfo)kCGImageAlphaNoneSkipLast : (CGBitmapInfo)kCGImageAlphaNone;
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, bpp / 8 * w, t->space, info);
    if (!c)
        return NULL;
    CGContextSetRenderingIntent(c, intent);
    CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), image);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

/* (code fragments are for GPU colour matching, which Finch doesn't do) */
CG_EXTERN_C void *
CGColorTransformCreateCodeFragment(CGColorTransformRef t, void *a, void *b, int kind, void *c, void *d)
{
    return NULL;
}

CG_EXTERN_C bool
CGColorCodeFragmentGetTextureData(void *fragment, void *a, void *b, void *c, void *d, void *e, void *f, void *g)
{
    return false;
}

CG_EXTERN_C void
CGColorCodeFragmentRelease(void *fragment)
{
}

/* MARK: - Colour spaces */

/* ColorSync, found when first needed. */
static void *
colorsync(const char *name)
{
    static void *lib;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lib = dlopen("/System/Library/Frameworks/ColorSync.framework/ColorSync", RTLD_LAZY | RTLD_LOCAL); });
    return lib ? dlsym(lib, name) : NULL;
}

CG_EXTERN_C CFTypeRef
CGColorSpaceCopyColorSyncProfile(CGColorSpaceRef space)
{
    CFDataRef icc = space ? CGColorSpaceCopyICCData(space) : NULL;
    if (!icc)
        return NULL;
    auto create = (CFTypeRef(*)(CFDataRef, CFErrorRef *))colorsync("ColorSyncProfileCreate");
    CFTypeRef p = create ? create(icc, NULL) : NULL;
    CFRelease(icc);
    return p;
}

/* (CGColorSpaceCreateWithColorSyncProfile, public, through the profile's ICC data) */
CG_PRIVATE CGColorSpaceRef
CGColorSpaceCreateFromColorSyncProfile(CFTypeRef profile)
{
    auto copy = (CFDataRef(*)(CFTypeRef, CFErrorRef *))colorsync("ColorSyncProfileCopyData");
    CFDataRef icc = profile && copy ? copy(profile, NULL) : NULL;
    if (!icc)
        return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithICCData(icc);
    CFRelease(icc);
    return cs;
}

CG_EXTERN_C bool
CGColorSpaceEqualToColorSpace(CGColorSpaceRef a, CGColorSpaceRef b)
{
    if (a == b)
        return true;
    return a && b && CFEqual(a, b);
}

/* The model a colour space's colours are processed in: an indexed space's base's, -1
   for one with none (a pattern space's) */
CG_EXTERN_C int
CGColorSpaceGetProcessColorModel(CGColorSpaceRef space)
{
    if (!space)
        return -1;
    CGColorSpaceModel m = CGColorSpaceGetModel(space);
    if (m == kCGColorSpaceModelIndexed || m == kCGColorSpaceModelPattern)
        return CGColorSpaceGetProcessColorModel(CGColorSpaceGetBaseColorSpace(space));
    return (int)m;
}

/* (a space concatenating others: device links, which Finch doesn't build) */
CG_EXTERN_C CGColorSpaceRef
CGColorSpaceConcatenate(CGColorSpaceRef space, void *spaces, size_t count)
{
    return NULL;
}

/* MARK: - Contexts */

/* The context's kind, by Apple's numbers: bitmap 4, PDF 1, layer 14. */
CG_EXTERN_C int
CGContextGetType(CGContextRef c)
{
    if (!c)
        return 0;
    if (c->for_layer)
        return 14;
    switch (c->type) {
    case CG_CONTEXT_BITMAP: return 4;
    case CG_CONTEXT_PDF: return 1;
    case CG_CONTEXT_LAYER: return 14;
    }
    return 0;
}

CG_EXTERN_C void
CGContextGetInterpolationQualityRange(CGContextRef c, int *min, int *max)
{
    if (!c)
        return;
    if (min)
        *min = c->interpolation_min;
    if (max)
        *max = c->interpolation_max;
}

CG_EXTERN_C void
CGContextSetInterpolationQualityRange(CGContextRef c, int min, int max)
{
    if (!c)
        return;
    c->interpolation_min = min;
    c->interpolation_max = max;
}

CG_EXTERN_C CGContextRef
CGBitmapContextCreateWithAlpha(void *data, size_t w, size_t h, size_t bpc, size_t bpr, CGColorSpaceRef space, CGBitmapInfo info,
                               void *alpha)
{
    return CGBitmapContextCreate(data, w, h, bpc, bpr, space, info);
}

/* A bitmap context described by a dictionary: its colour space and bitmap info, sRGB
   with premultiplied alpha first when they're missing. */
CG_EXTERN_C CGContextRef
CGBitmapContextCreateWithDictionary(void *data, size_t w, size_t h, size_t bpc, size_t bpr, CFDictionaryRef options)
{
    CGColorSpaceRef space = options ? (CGColorSpaceRef)CFDictionaryGetValue(options, CFSTR("kCGBitmapContextColorSpace")) : NULL;
    CFNumberRef infoNumber = options ? (CFNumberRef)CFDictionaryGetValue(options, CFSTR("kCGBitmapContextBitmapInfo")) : NULL;
    uint32_t info = (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Host;
    if (infoNumber && CFGetTypeID(infoNumber) == CFNumberGetTypeID())
        CFNumberGetValue(infoNumber, kCFNumberSInt32Type, &info);
    CGColorSpaceRef owned = NULL;
    if (!space || CFGetTypeID(space) != CGColorSpaceGetTypeID())
        space = owned = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(data, w, h, bpc, bpr, space, (CGBitmapInfo)info);
    if (owned)
        CGColorSpaceRelease(owned);
    return c;
}

/* (the page drawn into the context, options aside) */
CG_EXTERN_C void
CGContextDrawPDFPageInRect2(CGContextRef c, CGPDFPageRef page, CFDictionaryRef options)
{
    CGContextDrawPDFPage(c, page);
}

/* MARK: - Images */

CG_EXTERN_C CGImageRef
CGImageCreateCopyWithRenderingIntent(CGImageRef image, CGColorRenderingIntent intent)
{
    if (!image || intent > kCGRenderingIntentSaturation)
        return NULL;
    CGImageRef copy = CGImageCreateCopy(image);
    if (copy)
        ((struct CGImage *)copy)->intent = intent;
    return copy;
}

CG_EXTERN_C bool
CGImageHasAlpha(CGImageRef image)
{
    if (!image)
        return false;
    CGImageAlphaInfo a = CGImageGetAlphaInfo(image);
    return a != kCGImageAlphaNone && a != kCGImageAlphaNoneSkipFirst && a != kCGImageAlphaNoneSkipLast;
}

CG_EXTERN_C CGImageRef
CGImageGetMask(CGImageRef image)
{
    return image ? image->mask : NULL;
}

/* (Apple's hands back the decoded pixels through its own buffers: Finch gives none) */
CG_EXTERN_C void *
CGImageGetData(CGImageRef image, void *a, void *b, void *c, void *d, void *e)
{
    return NULL;
}

/* MARK: - PostScript (not on Finch) */

CG_EXTERN_C CGContextRef
CGPSContextCreate(CGDataConsumerRef consumer, const CGRect *mediaBox, CFDictionaryRef auxiliaryInfo)
{
    return NULL;
}

CG_EXTERN_C bool
CGPSConverterConvertFromURLToURL(void *converter, CFURLRef from, CFURLRef to, CFDictionaryRef options)
{
    return false;
}

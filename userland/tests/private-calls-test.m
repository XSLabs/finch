/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Private CoreGraphics, Core Animation and CoreFoundation calls and constants Apple's
 * apps use: the ones whose results are defined (regions, colour spaces by ID, row
 * alignment, dash and transform state, interpolation, XML entities, bidi levels, keys),
 * and the colour ones ColorSync Utility makes (colour transforms converting images,
 * process models, space equality, context types, interpolation ranges, intents, the PDF/X
 * keys); compared with Apple's.
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct CGSRegion *CGSRegionRef;
extern CGError CGSNewRegionWithRect(const CGRect *, CGSRegionRef *);
extern CGError CGSUnionRegion(CGSRegionRef, CGSRegionRef, CGSRegionRef *);
extern CGError CGSOffsetRegion(CGSRegionRef, float, float, CGSRegionRef *);  // (the offsets are floats)
extern CGError CGSGetRegionBounds(CGSRegionRef, CGRect *);
extern CGError CGSReleaseRegion(CGSRegionRef);
extern CGDirectDisplayID CGSMainDisplayID(void);
extern bool CGFloatIsValid(CGFloat);
extern CGColorSpaceRef CGColorSpaceCreateWithID(int);
extern int CGColorSpaceGetType(CGColorSpaceRef);
extern CFStringRef CGColorSpaceCopyICCProfileDescription(CGColorSpaceRef);
extern size_t CGBitmapGetAlignedBytesPerRow(size_t);
extern size_t CGContextGetLineDashCount(CGContextRef);
extern void CGContextGetLineDashPattern(CGContextRef, CGFloat *, CGFloat *);
extern void CGContextSetCTM(CGContextRef, CGAffineTransform);
extern void CATransform3DInterpolate(CATransform3D *, const CATransform3D *, const CATransform3D *, double);
extern NSString *const CADynamicRangeHigh, *const CADynamicRangeConstrainedHigh, *const kCAOnOrderIn, *const kCAOnOrderOut,
    *const kCAAnimationAbsolute, *const kCAFilterMultiply, *const kCAPackageTypeArchive, *const kCASnapshotMode;
extern Boolean CFPreferencesAppValueIsForced(CFStringRef, CFStringRef);
extern CFStringRef CFXMLCreateStringByEscapingEntities(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern CFStringRef CFXMLCreateStringByUnescapingEntities(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern Boolean _NSIsNSArray(id), _NSIsNSDictionary(id), _NSIsNSNumber(id);
extern const CFStringRef _kCFURLFinderInfoKey, kCFNumberFormatterMinGroupingDigits;

extern int CGContextGetType(CGContextRef);
extern void CGContextGetInterpolationQualityRange(CGContextRef, int *, int *);
extern void CGContextSetInterpolationQualityRange(CGContextRef, int, int);
extern bool CGImageHasAlpha(CGImageRef);
extern bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef, CGColorSpaceRef);
extern int CGColorSpaceGetProcessColorModel(CGColorSpaceRef);
extern CFStringRef kCGColorTransformBlackPointCompensation, kCGPDFXTrapped, kCGPDFXVersion;
typedef struct CGColorTransform *CGColorTransformRef;
extern CGColorTransformRef CGColorTransformCreate(CGColorSpaceRef, CFDictionaryRef);
extern CGColorSpaceRef CGColorTransformGetColorSpace(CGColorTransformRef);
extern CGImageRef CGColorTransformConvertImage(CGColorTransformRef, CGImageRef, int, CFDictionaryRef);
extern void CGColorTransformRelease(CGColorTransformRef);
extern CGImageRef CGImageCreateCopyWithRenderingIntent(CGImageRef, CGColorRenderingIntent);
extern CGImageRef CGImageGetMask(CGImageRef);

static void
colour_calls(void)
{
    printf("keys: %s %s %s\n", [(__bridge NSString *)kCGColorTransformBlackPointCompensation UTF8String],
           [(__bridge NSString *)kCGPDFXTrapped UTF8String], [(__bridge NSString *)kCGPDFXVersion UTF8String]);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB), gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    CGContextRef bm = CGBitmapContextCreate(NULL, 4, 4, 8, 16, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    NSMutableData *d = [NSMutableData data];
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)d);
    CGContextRef pdf = CGPDFContextCreate(cons, NULL, NULL);
    CGLayerRef layer = CGLayerCreateWithContext(bm, CGSizeMake(2, 2), NULL);
    printf("context types: bitmap %d pdf %d layer %d none %d\n", CGContextGetType(bm), CGContextGetType(pdf), CGContextGetType(CGLayerGetContext(layer)),
           CGContextGetType(NULL));
    int mn = -1, mx = -1;
    CGContextGetInterpolationQualityRange(bm, &mn, &mx);
    printf("interpolation range %d %d", mn, mx);
    CGContextSetInterpolationQualityRange(bm, 1, 3);
    CGContextGetInterpolationQualityRange(bm, &mn, &mx);
    printf(", set %d %d, quality %d\n", mn, mx, CGContextGetInterpolationQuality(bm));
    CGContextSetRGBFillColor(bm, 1, 0, 0, 1);
    CGContextFillRect(bm, CGRectMake(0, 0, 4, 4));
    CGImageRef im = CGBitmapContextCreateImage(bm);
    CGContextRef opaque = CGBitmapContextCreate(NULL, 4, 4, 8, 16, srgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef im2 = CGBitmapContextCreateImage(opaque);
    printf("has alpha %d %d, mask %d\n", CGImageHasAlpha(im), CGImageHasAlpha(im2), CGImageGetMask(im) != NULL);
    printf("equal spaces %d %d %d\n", CGColorSpaceEqualToColorSpace(srgb, srgb),
           CGColorSpaceEqualToColorSpace(srgb, CGColorSpaceCreateWithName(kCGColorSpaceSRGB)), CGColorSpaceEqualToColorSpace(srgb, gray));
    const CFStringRef names[] = {kCGColorSpaceSRGB, kCGColorSpaceGenericGrayGamma2_2, kCGColorSpaceGenericCMYK, kCGColorSpaceGenericLab,
                                 kCGColorSpaceDisplayP3, kCGColorSpaceGenericXYZ};
    printf("process models:");
    for (int i = 0; i < 6; i++)
        printf(" %d", CGColorSpaceGetProcessColorModel(CGColorSpaceCreateWithName(names[i])));
    const unsigned char table[] = {0, 0, 0, 255, 255, 255};
    printf(", indexed %d, pattern %d\n", CGColorSpaceGetProcessColorModel(CGColorSpaceCreateIndexed(srgb, 1, table)),
           CGColorSpaceGetProcessColorModel(CGColorSpaceCreatePattern(NULL)));
    CGColorTransformRef t = CGColorTransformCreate(gray, NULL);
    printf("transform %d, its space gray %d\n", t != NULL, t && CFEqual(CGColorTransformGetColorSpace(t), gray));
    CGImageRef g = CGColorTransformConvertImage(t, im, kCGRenderingIntentDefault, NULL);
    CFDataRef px = g ? CGDataProviderCopyData(CGImageGetDataProvider(g)) : NULL;
    printf("converted: model %d bpc %zu bpp %zu alpha %d, red is gray %d\n", g ? CGColorSpaceGetModel(CGImageGetColorSpace(g)) : -1,
           g ? CGImageGetBitsPerComponent(g) : 0, g ? CGImageGetBitsPerPixel(g) : 0, g ? CGImageGetAlphaInfo(g) : -1,
           px ? abs(CFDataGetBytePtr(px)[0] - 128) < 12 : 0);
    CGColorTransformRelease(t);
    CGImageRef ri = CGImageCreateCopyWithRenderingIntent(im, kCGRenderingIntentPerceptual);
    printf("intent copy %d intent %d\n", ri != NULL, ri ? CGImageGetRenderingIntent(ri) : -1);
}

int
main(void)
{
    @autoreleasepool {
        /* regions */
        CGRect a = CGRectMake(0, 0, 10, 10), b = CGRectMake(20, 5, 5, 30), bounds;
        CGSRegionRef ra, rb, ru, ro;
        CGSNewRegionWithRect(&a, &ra);
        CGSNewRegionWithRect(&b, &rb);
        CGSUnionRegion(ra, rb, &ru);
        CGSOffsetRegion(ru, 3, -2, &ro);
        CGSGetRegionBounds(ru, &bounds);
        printf("union bounds %s", NSStringFromRect(bounds).UTF8String);
        CGSGetRegionBounds(ro, &bounds);
        printf(", offset %s\n", NSStringFromRect(bounds).UTF8String);
        CGSReleaseRegion(ra), CGSReleaseRegion(rb), CGSReleaseRegion(ru), CGSReleaseRegion(ro);
        printf("main display matches: %d\n", CGSMainDisplayID() == CGMainDisplayID());

        /* colour spaces and bitmaps */
        printf("valid: %d %d %d\n", CGFloatIsValid(1), CGFloatIsValid(NAN), CGFloatIsValid(INFINITY));
        for (int id = 0; id < 34; id += 3) {
            CGColorSpaceRef c = CGColorSpaceCreateWithID(id);
            printf("space %d: %s type %d\n", id, c ? [(__bridge_transfer NSString *)CGColorSpaceCopyName(c) UTF8String] : "-",
                c ? CGColorSpaceGetType(c) : -1);
        }
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        printf("sRGB description %s, device RGB type %d gray %d\n",
            [(__bridge_transfer NSString *)CGColorSpaceCopyICCProfileDescription(srgb) UTF8String],
            CGColorSpaceGetType(CGColorSpaceCreateDeviceRGB()), CGColorSpaceGetType(CGColorSpaceCreateDeviceGray()));
        size_t rows[] = {1, 32, 33, 100, 1000};
        printf("aligned rows:");
        for (int i = 0; i < 5; i++)
            printf(" %zu", CGBitmapGetAlignedBytesPerRow(rows[i]));
        printf("\n");

        /* context state */
        CGContextRef ctx = CGBitmapContextCreate(NULL, 20, 20, 8, 0, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGFloat dashes[] = {4, 2, 1};
        CGContextSetLineDash(ctx, 1.5, dashes, 3);
        CGFloat phase = 0, got[3] = {0};
        CGContextGetLineDashPattern(ctx, &phase, got);
        printf("dash: count %zu phase %g lengths %g %g %g\n", CGContextGetLineDashCount(ctx), phase, got[0], got[1], got[2]);
        CGContextSetCTM(ctx, CGAffineTransformMake(2, 0, 0, 3, 5, 7));
        CGAffineTransform t = CGContextGetCTM(ctx);
        printf("ctm set: %g %g %g %g %g %g\n", t.a, t.b, t.c, t.d, t.tx, t.ty);
        CGContextRelease(ctx);

        /* Core Animation */
        printf("constants: %s %s %s %s %s %s %s %s\n", CADynamicRangeHigh.UTF8String, CADynamicRangeConstrainedHigh.UTF8String,
            kCAOnOrderIn.UTF8String, kCAOnOrderOut.UTF8String, kCAAnimationAbsolute.UTF8String, kCAFilterMultiply.UTF8String,
            kCAPackageTypeArchive.UTF8String, kCASnapshotMode.UTF8String);
        CATransform3D x = CATransform3DMakeScale(2, 2, 1), y = CATransform3DMakeTranslation(10, 0, 0), m;
        CATransform3DInterpolate(&m, &x, &y, 0.25);
        printf("interpolate: %g %g %g %g\n", m.m11, m.m22, m.m41, m.m44);
        printf("classes: %d %d %d %d %d\n", NSClassFromString(@"CAPortalLayer") != nil, NSClassFromString(@"CAPackage") != nil,
            NSClassFromString(@"CAState") != nil, NSClassFromString(@"CAStateController") != nil, NSClassFromString(@"CAContext") != nil);
        printf("portal is a layer: %d\n", [NSClassFromString(@"CAPortalLayer") isSubclassOfClass:[CALayer class]]);

        /* CoreFoundation */
        printf("version >= 4000: %d\n", kCFCoreFoundationVersionNumber >= 4000);
        printf("forced: %d\n", CFPreferencesAppValueIsForced(CFSTR("AppleLanguages"), kCFPreferencesCurrentApplication));
        CFStringRef esc = CFXMLCreateStringByEscapingEntities(NULL, CFSTR("a<b & \"c\" 'd' >"), NULL);
        CFStringRef unesc = CFXMLCreateStringByUnescapingEntities(NULL, CFSTR("&lt;x&gt; &amp;amp; &#65;&#x42; &unknown; &copy;"),
            (__bridge CFDictionaryRef) @{@"copy" : @"(c)"});
        printf("escaped: %s\nunescaped: %s\n", [(__bridge NSString *)esc UTF8String], [(__bridge NSString *)unesc UTF8String]);
        NSAttributedString *mixed = [[NSAttributedString alloc] initWithString:@"abc שלום def"];
        for (int base = -1; base <= 1; base++) {
            uint8_t levels[32] = {0}, dirs[32] = {0};
            bool bidi = CFAttributedStringGetBidiLevelsAndResolvedDirections((__bridge CFAttributedStringRef)mixed,
                CFRangeMake(0, (CFIndex)mixed.length), (int8_t)base, levels, dirs);
            printf("bidi base %d: %d levels", base, bidi);
            for (NSUInteger i = 0; i < mixed.length; i++)
                printf(" %d", levels[i]);
            printf(" directions %d %d\n", dirs[0], dirs[mixed.length - 1]);
        }
        NSAttributedString *hebrew = [[NSAttributedString alloc] initWithString:@"שלום עולם abc"];
        uint8_t hl[32] = {0}, hd[32] = {0};
        bool h = CFAttributedStringGetStatisticalWritingDirections((__bridge CFAttributedStringRef)hebrew,
            CFRangeMake(0, (CFIndex)hebrew.length), -1, hl, hd);
        printf("statistical: %d direction %d first level %d\n", h, hd[0], hl[0]);
        uint8_t ll[8] = {0};
        printf("plain LTR: %d\n", CFAttributedStringGetBidiLevelsAndResolvedDirections(
                                       (__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:@"hello"], CFRangeMake(0, 5), -1, ll, NULL));
        printf("checks: %d %d %d %d\n", _NSIsNSArray(@[]), _NSIsNSArray(@{}), _NSIsNSDictionary(@{}), _NSIsNSNumber(@1));
        printf("keys: %s %s\n", [(__bridge NSString *)_kCFURLFinderInfoKey UTF8String],
            [(__bridge NSString *)kCFNumberFormatterMinGroupingDigits UTF8String]);
    }
    colour_calls();
    return 0;
}

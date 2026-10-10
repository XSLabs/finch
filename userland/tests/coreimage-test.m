/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coreimage-test: CoreImage's colors, vectors, images, contexts and filters, one
 * result per line so runs against Apple's CoreImage and Finch's can be diffed. Each
 * filter is applied to a small test image and its pixels printed as 8-bit sRGB
 * (premultiplied, as CIContext writes them), rounded to steps of 8 (Apple's renders in
 * half floats on the GPU, so an 8-bit value can differ by one).
 */
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>

static CIContext *ctx;

static NSString *
rect_string(CGRect r)
{
    if (CGRectIsInfinite(r))
        return @"infinite";
    if (CGRectIsNull(r))
        return @"null";
    return [NSString stringWithFormat:@"[%g %g %g %g]", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

/* The pixels of r, top row first. coarse: rounded to steps of 8. */
static void
pixels(const char *label, CIImage *image, CGRect r, BOOL coarse)
{
    if (!image) {
        printf("%s: nil\n", label);
        return;
    }
    size_t w = (size_t)r.size.width, h = (size_t)r.size.height;
    uint8_t *b = calloc(w * h, 4);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ctx render:image toBitmap:b rowBytes:(ptrdiff_t)(w * 4) bounds:r format:kCIFormatRGBA8 colorSpace:srgb];
    CGColorSpaceRelease(srgb);
    printf("%s: extent %s |", label, rect_string(image.extent).UTF8String);
    for (size_t i = 0; i < w * h * 4; i++) {
        int v = b[i];
        if (coarse)
            v = (v + 4) / 8 * 8;
        printf("%s%d", i % 4 ? "," : " ", v);
    }
    printf("\n");
    free(b);
}

/* A 4x2 test image: red, green, blue, white (opaque); half-transparent orange,
   grey, clear and dark teal. */
static CIImage *
test_image(void)
{
    static const uint8_t px[8][4] = {
        {255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255},
        {128, 64, 0, 128}, {128, 128, 128, 255}, {0, 0, 0, 0}, {0, 51, 51, 102},
    };
    NSData *d = [NSData dataWithBytes:px length:sizeof px];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIImage *im = [CIImage imageWithBitmapData:d bytesPerRow:16 size:CGSizeMake(4, 2) format:kCIFormatRGBA8 colorSpace:srgb];
    CGColorSpaceRelease(srgb);
    return im;
}

static CIImage *
background(void)
{
    return [[CIImage imageWithColor:[CIColor colorWithRed:0.25 green:0.5 blue:0.75 alpha:0.75]]
        imageByCroppingToRect:CGRectMake(0, 0, 4, 2)];
}

static void
filter(NSString *name, NSDictionary *params, BOOL coarse, CGRect r)
{
    coarse = YES; /* Apple's renders in half floats on the GPU: values can differ by one */
    CIFilter *f = [CIFilter filterWithName:name];
    if (!f) {
        printf("%s: no filter\n", name.UTF8String);
        return;
    }
    if ([f.inputKeys containsObject:kCIInputImageKey])
        [f setValue:test_image() forKey:kCIInputImageKey];
    if ([f.inputKeys containsObject:kCIInputBackgroundImageKey])
        [f setValue:background() forKey:kCIInputBackgroundImageKey];
    [f setValuesForKeysWithDictionary:params ?: @{}];
    pixels(name.UTF8String, f.outputImage, r, coarse);
}

static void
describe_filter(NSString *name)
{
    CIFilter *f = [CIFilter filterWithName:name];
    NSDictionary *a = f.attributes;
    printf("%s: class %s inputs %s outputs %s\n", name.UTF8String, NSStringFromClass([f class]).UTF8String,
           [[f.inputKeys componentsJoinedByString:@","] UTF8String], [[f.outputKeys componentsJoinedByString:@","] UTF8String]);
    printf("  %s | %s\n", [a[kCIAttributeFilterDisplayName] UTF8String],
           [[a[kCIAttributeFilterCategories] componentsJoinedByString:@","] UTF8String]);
    for (NSString *k in f.inputKeys) {
        NSDictionary *d = a[k];
        NSMutableString *s = [NSMutableString stringWithFormat:@"  %@: %@ %@", k, d[kCIAttributeClass], d[kCIAttributeType] ?: @"-"];
        for (NSString *kk in @[ kCIAttributeDefault, kCIAttributeMin, kCIAttributeMax, kCIAttributeSliderMin,
                                kCIAttributeSliderMax, kCIAttributeIdentity ]) {
            id v = d[kk];
            if ([v isKindOfClass:[NSNumber class]])
                [s appendFormat:@" %@=%g", [kk substringFromIndex:11], [v doubleValue]];
            else if ([v isKindOfClass:[CIVector class]] || [v isKindOfClass:[CIColor class]])
                [s appendFormat:@" %@=%@", [kk substringFromIndex:11], [v stringRepresentation]];
        }
        printf("%s\n", s.UTF8String);
    }
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge void *)[CIImage class], &info);
        printf("CoreImage: %s\n", info.dli_fname);
        ctx = [CIContext contextWithOptions:nil];

        printf("== colors and vectors\n");
        CIColor *c = [CIColor colorWithRed:0.2 green:0.4 blue:0.6 alpha:0.8];
        printf("%s | %zu | %g %g %g %g\n", c.stringRepresentation.UTF8String, c.numberOfComponents, c.red, c.green, c.blue, c.alpha);
        CIColor *parsed = [CIColor colorWithString:@"0.1 0.2 0.3"];
        printf("parsed %s equal %d\n", parsed.stringRepresentation.UTF8String,
               [parsed isEqual:[CIColor colorWithRed:0.1 green:0.2 blue:0.3]]);
        printf("red %s clear %s\n", [CIColor redColor].stringRepresentation.UTF8String, [CIColor clearColor].stringRepresentation.UTF8String);
        CGColorRef gray = CGColorCreateGenericGray(0.5, 1);
        printf("from gray %s\n", [CIColor colorWithCGColor:gray].stringRepresentation.UTF8String);
        CGColorRelease(gray);
        CIVector *v = [CIVector vectorWithX:1 Y:2.5 Z:3];
        printf("%s | %zu | %s | %s\n", v.stringRepresentation.UTF8String, v.count,
               [CIVector vectorWithCGRect:CGRectMake(1, 2, 3, 4)].stringRepresentation.UTF8String,
               [CIVector vectorWithString:@"[5 6]"].stringRepresentation.UTF8String);
        CGAffineTransform t = [[CIVector vectorWithCGAffineTransform:CGAffineTransformMakeScale(2, 3)] CGAffineTransformValue];
        printf("transform %g %g %g %g %g %g\n", t.a, t.b, t.c, t.d, t.tx, t.ty);
        NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:c requiringSecureCoding:YES error:nil];
        CIColor *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[CIColor class] fromData:archived error:nil];
        printf("archived %s\n", back.stringRepresentation.UTF8String);

        printf("== images\n");
        CIImage *color = [CIImage imageWithColor:c];
        printf("color extent %s\n", rect_string(color.extent).UTF8String);
        CIImage *crop = [color imageByCroppingToRect:CGRectMake(0, 0, 2, 2)];
        printf("crop extent %s empty %s\n", rect_string(crop.extent).UTF8String, rect_string([CIImage emptyImage].extent).UTF8String);
        pixels("color", crop, CGRectMake(0, 0, 2, 1), NO);
        CIImage *im = test_image();
        printf("test extent %s opaque %d\n", rect_string(im.extent).UTF8String, im.opaque);
        pixels("test", im, CGRectMake(0, 0, 4, 2), NO);
        pixels("around", im, CGRectMake(-1, -1, 6, 4), NO);
        pixels("translated", [im imageByApplyingTransform:CGAffineTransformMakeTranslation(1, 0)], CGRectMake(0, 0, 5, 2), NO);
        pixels("flipped", [im imageByApplyingOrientation:2], CGRectMake(0, 0, 4, 2), NO);
        pixels("rotated", [im imageByApplyingOrientation:6], CGRectMake(0, 0, 2, 4), NO);
        printf("orientation 6 extent %s\n", rect_string([im imageByApplyingOrientation:6].extent).UTF8String);
        pixels("scaled", [im imageByApplyingTransform:CGAffineTransformMakeScale(2, 2)], CGRectMake(0, 0, 8, 4), YES);
        pixels("clamped", [im imageByClampingToExtent], CGRectMake(-1, 0, 6, 1), NO);
        printf("clamped extent %s\n", rect_string([im imageByClampingToExtent].extent).UTF8String);
        pixels("over", [im imageByCompositingOverImage:background()], CGRectMake(0, 0, 4, 2), NO);
        pixels("unpremultiplied", [[im imageByUnpremultiplyingAlpha] imageByPremultiplyingAlpha], CGRectMake(0, 0, 4, 2), NO);
        pixels("alpha one", [im imageBySettingAlphaOneInExtent:im.extent], CGRectMake(0, 0, 4, 2), NO);

        printf("== context\n");
        CGImageRef cg = [ctx createCGImage:im fromRect:im.extent];
        printf("cgimage %zux%zu bpc %zu bpp %zu alpha %d\n", CGImageGetWidth(cg), CGImageGetHeight(cg),
               CGImageGetBitsPerComponent(cg), CGImageGetBitsPerPixel(cg), (int)CGImageGetAlphaInfo(cg));
        CIImage *again = [CIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        pixels("round trip", again, CGRectMake(0, 0, 4, 2), NO);
        float fl[4] = {0};
        [ctx render:crop toBitmap:fl rowBytes:16 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBAf colorSpace:nil];
        printf("float, unmatched %.3f %.3f %.3f %.3f\n", fl[0], fl[1], fl[2], fl[3]);
        CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
        [ctx render:crop toBitmap:fl rowBytes:16 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBAf colorSpace:linear];
        printf("float, linear %.3f %.3f %.3f %.3f\n", fl[0], fl[1], fl[2], fl[3]);
        CGColorSpaceRelease(linear);
        uint8_t bgra[4];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        [ctx render:crop toBitmap:bgra rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatBGRA8 colorSpace:srgb];
        printf("BGRA8 %d %d %d %d\n", bgra[0], bgra[1], bgra[2], bgra[3]);
        uint8_t a8;
        [ctx render:crop toBitmap:&a8 rowBytes:1 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatA8 colorSpace:srgb];
        printf("A8 %d\n", a8);
        NSData *png = [ctx PNGRepresentationOfImage:im format:kCIFormatRGBA8 colorSpace:srgb options:@{}];
        CIImage *fromPNG = [CIImage imageWithData:png];
        pixels("png", fromPNG, CGRectMake(0, 0, 4, 2), NO);
        CGColorSpaceRelease(srgb);

        printf("== filters\n");
        NSArray *names = @[
            @"CIColorControls", @"CIExposureAdjust", @"CIGammaAdjust", @"CIColorMatrix", @"CIColorInvert",
            @"CIColorMonochrome", @"CISepiaTone", @"CIColorClamp", @"CIMaximumComponent", @"CIMinimumComponent",
            @"CIFalseColor", @"CIHueAdjust", @"CIWhitePointAdjust", @"CILinearToSRGBToneCurve", @"CISRGBToneCurveToLinear",
            @"CIColorPolynomial", @"CIColorCrossPolynomial", @"CIColorThreshold", @"CIMaskToAlpha",
            @"CISourceOverCompositing", @"CISourceInCompositing", @"CISourceOutCompositing", @"CISourceAtopCompositing",
            @"CIMultiplyCompositing", @"CIAdditionCompositing", @"CIMinimumCompositing", @"CIMaximumCompositing",
            @"CIScreenBlendMode", @"CIOverlayBlendMode", @"CIDarkenBlendMode", @"CILightenBlendMode",
            @"CIColorDodgeBlendMode", @"CIColorBurnBlendMode", @"CISoftLightBlendMode", @"CIHardLightBlendMode",
            @"CIDifferenceBlendMode", @"CIExclusionBlendMode", @"CIMultiplyBlendMode", @"CISubtractBlendMode",
            @"CIDivideBlendMode", @"CIHueBlendMode", @"CISaturationBlendMode", @"CIColorBlendMode",
            @"CILuminosityBlendMode", @"CILinearBurnBlendMode", @"CILinearDodgeBlendMode", @"CIBlendWithMask",
            @"CIBlendWithAlphaMask", @"CIGaussianBlur", @"CIBoxBlur", @"CIDiscBlur", @"CIMotionBlur", @"CIUnsharpMask",
            @"CIMorphologyMaximum", @"CIMorphologyMinimum", @"CIAffineTransform", @"CICrop", @"CILanczosScaleTransform",
            @"CIStraightenFilter", @"CIAffineClamp", @"CIConstantColorGenerator", @"CICheckerboardGenerator",
            @"CIStripesGenerator", @"CILinearGradient", @"CISmoothLinearGradient", @"CIRadialGradient", @"CIPixellate",
            @"CIAreaAverage", @"CIAreaMaximum", @"CIAreaMinimum"
        ];
        NSArray *builtIn = [CIFilter filterNamesInCategory:kCICategoryBuiltIn];
        for (NSString *n in names)
            if (![builtIn containsObject:n])
                printf("not built in: %s\n", n.UTF8String);
        for (NSString *n in names)
            describe_filter(n);

        CGRect r = CGRectMake(0, 0, 4, 2);
        filter(@"CIColorControls", @{@"inputSaturation" : @0}, NO, r);
        filter(@"CIColorControls", @{@"inputBrightness" : @0.2, @"inputContrast" : @1.5}, NO, r);
        filter(@"CIExposureAdjust", @{@"inputEV" : @1}, NO, r);
        filter(@"CIGammaAdjust", @{@"inputPower" : @2}, NO, r);
        filter(@"CIColorMatrix", @{@"inputRVector" : [CIVector vectorWithX:0 Y:1 Z:0 W:0],
                                   @"inputBiasVector" : [CIVector vectorWithX:0.1 Y:0 Z:0 W:0]}, NO, r);
        filter(@"CIColorInvert", nil, NO, r);
        filter(@"CIColorMonochrome", nil, NO, r);
        filter(@"CISepiaTone", nil, NO, r);
        filter(@"CIColorClamp", @{@"inputMaxComponents" : [CIVector vectorWithX:0.5 Y:0.5 Z:0.5 W:1]}, NO, r);
        filter(@"CIMaximumComponent", nil, NO, r);
        filter(@"CIMinimumComponent", nil, NO, r);
        filter(@"CIFalseColor", nil, NO, r);
        filter(@"CIHueAdjust", @{@"inputAngle" : @1}, NO, r);
        filter(@"CIWhitePointAdjust", @{@"inputColor" : [CIColor colorWithRed:1 green:0.5 blue:0.25]}, NO, r);
        filter(@"CILinearToSRGBToneCurve", nil, NO, r);
        filter(@"CISRGBToneCurveToLinear", nil, NO, r);
        filter(@"CIColorPolynomial", @{@"inputRedCoefficients" : [CIVector vectorWithX:0.1 Y:0.5 Z:0.2 W:0]}, NO, r);
        filter(@"CIColorThreshold", nil, NO, r);
        filter(@"CIMaskToAlpha", nil, NO, r);
        for (NSString *n in [names subarrayWithRange:NSMakeRange(19, 29)])
            filter(n, nil, NO, r);
        filter(@"CIGaussianBlur", @{@"inputRadius" : @1}, YES, CGRectMake(-1, -1, 6, 4));
        filter(@"CIBoxBlur", @{@"inputRadius" : @1}, YES, CGRectMake(-1, -1, 6, 4));
        filter(@"CIBoxBlur", @{@"inputRadius" : @3}, YES, CGRectMake(-1, -1, 6, 4));
        filter(@"CIUnsharpMask", nil, YES, r);
        filter(@"CIMorphologyMaximum", @{@"inputRadius" : @1}, YES, CGRectMake(-1, -1, 6, 4));
        filter(@"CIAffineTransform", @{@"inputTransform" : [NSValue valueWithBytes:&(CGAffineTransform){1, 0, 0, 1, 2, 1}
                                                                           objCType:@encode(CGAffineTransform)]},
               NO, CGRectMake(0, 0, 6, 3));
        filter(@"CICrop", @{@"inputRectangle" : [CIVector vectorWithCGRect:CGRectMake(1, 0, 2, 1)]}, NO, r);
        filter(@"CILanczosScaleTransform", @{@"inputScale" : @0.5}, YES, CGRectMake(0, 0, 2, 1));
        filter(@"CIConstantColorGenerator", @{@"inputColor" : c}, NO, CGRectMake(0, 0, 1, 1));
        filter(@"CICheckerboardGenerator", @{@"inputWidth" : @2, @"inputCenter" : [CIVector vectorWithX:0 Y:0]}, NO,
               CGRectMake(0, 0, 4, 4));
        filter(@"CIStripesGenerator", @{@"inputWidth" : @2, @"inputCenter" : [CIVector vectorWithX:0 Y:0]}, NO,
               CGRectMake(0, 0, 4, 1));
        filter(@"CILinearGradient", @{@"inputPoint0" : [CIVector vectorWithX:0 Y:0], @"inputPoint1" : [CIVector vectorWithX:4 Y:0]},
               YES, CGRectMake(0, 0, 4, 1));
        filter(@"CIRadialGradient", @{@"inputCenter" : [CIVector vectorWithX:0 Y:0], @"inputRadius0" : @0,
                                      @"inputRadius1" : @4}, YES, CGRectMake(0, 0, 4, 1));
        filter(@"CIPixellate", @{@"inputScale" : @2, @"inputCenter" : [CIVector vectorWithX:0 Y:0]}, NO, r);
        filter(@"CIAreaAverage", @{@"inputExtent" : [CIVector vectorWithCGRect:CGRectMake(0, 0, 4, 2)]}, YES, CGRectMake(0, 0, 1, 1));
        filter(@"CIAreaMaximum", @{@"inputExtent" : [CIVector vectorWithCGRect:CGRectMake(0, 0, 4, 2)]}, NO, CGRectMake(0, 0, 1, 1));
        filter(@"CIAreaMinimum", @{@"inputExtent" : [CIVector vectorWithCGRect:CGRectMake(0, 0, 4, 2)]}, NO, CGRectMake(0, 0, 1, 1));

        printf("== builtins and kernels\n");
        CIFilter *blur = ((id (*)(id, SEL))objc_msgSend)([CIFilter class], NSSelectorFromString(@"gaussianBlurFilter"));
        [(id)blur setValue:@3 forKey:@"inputRadius"];
        printf("radius %g\n", ((float (*)(id, SEL))objc_msgSend)(blur, NSSelectorFromString(@"radius")));
        ((void (*)(id, SEL, float))objc_msgSend)(blur, NSSelectorFromString(@"setRadius:"), 4.5f);
        printf("inputRadius %s\n", [[blur valueForKey:@"inputRadius"] description].UTF8String);
        CIFilter *made = ((id (*)(id, SEL))objc_msgSend)([CIFilter class], NSSelectorFromString(@"sepiaToneFilter"));
        printf("factory %s\n", made.name.UTF8String);
        pixels("blend kernel", [[CIBlendKernel multiply] applyWithForeground:im background:background()], r, NO);
        pixels("blend kernel xor", [[CIBlendKernel exclusiveOr] applyWithForeground:im background:background()], r, NO);
        CIImageAccumulator *acc = [CIImageAccumulator imageAccumulatorWithExtent:r format:kCIFormatRGBA8];
        [acc setImage:im];
        pixels("accumulator", acc.image, r, NO);
    }
    return 0;
}

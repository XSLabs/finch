/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-quartzcore-test: QuartzCore's CATransform3D functions and string
 * constants. Prints everything; run it against Apple's QuartzCore and
 * Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAEDRMetadata.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/runtime.h>
#include <stdio.h>

static void
show(const char *label, CATransform3D t)
{
    const CGFloat *m = &t.m11;
    printf("%s:", label);
    for (int i = 0; i < 16; i++)
        printf(" %.6f", fabs(m[i]) < 5e-7 ? 0.0 : m[i]);
    printf("\n");
}

static void
show_rect(const char *label, CGRect r)
{
    printf("%s: %.3f %.3f %.3f %.3f\n", label, r.origin.x, r.origin.y, r.size.width, r.size.height);
}

@interface GLProbeLayer : CAOpenGLLayer {
@public
    unsigned _drawCount;
}
@end

@implementation GLProbeLayer
- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
            forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime
{
    _drawCount++;
    [super drawInCGLContext:ctx pixelFormat:pf forLayerTime:time displayTime:displayTime];
}
@end

int
main(void)
{
    Dl_info info;
    dladdr((void *)CATransform3DConcat, &info);
    printf("%s\n", info.dli_fname);
    CATransform3D t = CATransform3DMakeTranslation(1, 2, 3);
    show("identity", CATransform3DIdentity);
    show("translation", t);
    show("scale", CATransform3DMakeScale(2, 3, 4));
    show("rotation z", CATransform3DMakeRotation(M_PI / 3, 0, 0, 1));
    show("rotation axis", CATransform3DMakeRotation(0.7, 1, 2, 3));
    show("rotation zero axis", CATransform3DMakeRotation(0.7, 0, 0, 0));
    show("translate", CATransform3DTranslate(CATransform3DMakeScale(2, 2, 2), 1, 1, 1));
    show("scale t", CATransform3DScale(t, 2, 3, 4));
    show("rotate t", CATransform3DRotate(t, 0.5, 0, 1, 0));
    show("concat", CATransform3DConcat(t, CATransform3DMakeRotation(0.3, 1, 0, 0)));
    show("invert", CATransform3DInvert(CATransform3DRotate(CATransform3DMakeScale(2, 3, 4), 0.5, 1, 1, 0)));
    show("invert singular", CATransform3DInvert(CATransform3DMakeScale(0, 1, 1)));
    CATransform3D p = CATransform3DIdentity;
    p.m34 = -1.0 / 500;
    show("perspective rotate", CATransform3DRotate(p, 0.4, 0, 1, 0));
    CGAffineTransform a = CGAffineTransformMake(1, 2, 3, 4, 5, 6);
    show("from affine", CATransform3DMakeAffineTransform(a));
    CGAffineTransform back = CATransform3DGetAffineTransform(CATransform3DMakeAffineTransform(a));
    printf("affine back: %g %g %g %g %g %g\n", back.a, back.b, back.c, back.d, back.tx, back.ty);
    printf("is identity %d %d affine %d %d equal %d %d\n", CATransform3DIsIdentity(CATransform3DIdentity),
           CATransform3DIsIdentity(t), CATransform3DIsAffine(t), CATransform3DIsAffine(p),
           CATransform3DEqualToTransform(t, CATransform3DMakeTranslation(1, 2, 3)),
           CATransform3DEqualToTransform(t, p));
    printf("media time positive %d\n", CACurrentMediaTime() > 0);
    printf("constants: %s %s %s %s %s %s %s\n", kCAFillModeForwards.UTF8String,
           kCAMediaTimingFunctionEaseInEaseOut.UTF8String, kCATransitionFade.UTF8String,
           kCAGravityResizeAspect.UTF8String, kCAFilterLinear.UTF8String, kCAAlignmentCenter.UTF8String,
           kCAAnimationCubic.UTF8String);
    CAFrameRateRange rate = CAFrameRateRangeMake(24, 60, 30);
    printf("frame rate: %.0f %.0f %.0f equal %d unequal %d default %d\n", rate.minimum, rate.maximum, rate.preferred,
           CAFrameRateRangeIsEqualToRange(rate, (CAFrameRateRange){24, 60, 30}),
           CAFrameRateRangeIsEqualToRange(rate, CAFrameRateRangeMake(24, 60, 29)),
           CAFrameRateRangeIsEqualToRange(CAFrameRateRangeDefault, (CAFrameRateRange){0, 0, 0}));
    NSValue *transformValue = [NSValue valueWithCATransform3D:t];
    printf("NSValue CATransform3D round trip %d\n", CATransform3DEqualToTransform(transformValue.CATransform3DValue, t));
    printf("corner expansion %.6f %.6f %.6f\n", [CALayer cornerCurveExpansionFactor:kCACornerCurveCircular],
           [CALayer cornerCurveExpansionFactor:kCACornerCurveContinuous], [CALayer cornerCurveExpansionFactor:@"unknown"]);
    Protocol *animationDelegate = @protocol(CAAnimationDelegate);
    Protocol *layerDelegate = @protocol(CALayerDelegate);
    BOOL animationCallback = protocol_getMethodDescription(animationDelegate, @selector(animationDidStop:finished:), NO, YES).name != NULL;
    BOOL layerCallback = protocol_getMethodDescription(layerDelegate, @selector(drawLayer:inContext:), NO, YES).name != NULL;
    printf("delegate protocols %d %d callbacks %d %d\n", animationDelegate != NULL, layerDelegate != NULL,
           animationCallback, layerCallback);
    printf("renderer color key: %s\n", kCARendererColorSpace.UTF8String);
    printf("renderer queue key %s dynamic range %s\n", kCARendererMetalCommandQueue.UTF8String,
           CADynamicRangeAutomatic.UTF8String);

    GLProbeLayer *glLayer = [GLProbeLayer layer];
    CGLPixelFormatObj pf = [glLayer copyCGLPixelFormatForDisplayMask:1];
    CGLContextObj ctx = pf ? [glLayer copyCGLContextForPixelFormat:pf] : NULL;
    CGLContextObj previous = CGLGetCurrentContext();
    if (ctx)
        CGLSetCurrentContext(ctx);
    BOOL canDraw = ctx && [glLayer canDrawInCGLContext:ctx pixelFormat:pf forLayerTime:0 displayTime:NULL];
    if (canDraw)
        [glLayer drawInCGLContext:ctx pixelFormat:pf forLayerTime:0 displayTime:NULL];
    if (previous != ctx)
        CGLSetCurrentContext(previous);
    printf("OpenGL layer: async %d EDR %d colorspace %s format %d context %d can draw %d callbacks %u\n",
           glLayer.isAsynchronous, glLayer.wantsExtendedDynamicRangeContent, glLayer.colorspace ? "set" : "nil",
           pf != NULL, ctx != NULL, canDraw, glLayer->_drawCount);

    CARenderer *renderer = ctx ? [CARenderer rendererWithCGLContext:(void *)ctx options:nil] : nil;
    CALayer *renderRoot = [CALayer layer];
    renderRoot.bounds = CGRectMake(0, 0, 20, 12);
    CGColorRef renderColor = CGColorCreateSRGB(0.2, 0.4, 0.6, 1);
    renderRoot.backgroundColor = renderColor;
    CGColorRelease(renderColor);
    renderer.layer = renderRoot;
    renderer.bounds = CGRectMake(0, 0, 20, 12);
    [renderer beginFrameAtTime:1 timeStamp:NULL];
    printf("renderer object %d layer %d\n", renderer != nil, renderer.layer == renderRoot);
    show_rect("renderer update", [renderer updateBounds]);
    [renderer addUpdateRect:CGRectMake(2, 3, 5, 4)];
    show_rect("renderer requested", [renderer updateBounds]);
    [renderer render];
    [renderer endFrame];
    printf("renderer next frame infinite %d\n", isinf([renderer nextFrameTime]));
    if (ctx)
        [glLayer releaseCGLContext:ctx];
    if (pf)
        [glLayer releaseCGLPixelFormat:pf];

    NSData *ambient = [NSData dataWithBytes:(const UInt8[]){0x00, 0x2f, 0xef, 0xe0, 0x3d, 0x13, 0x40, 0x42} length:8];
    CAEDRMetadata *hdr = [CAEDRMetadata HDR10MetadataWithDisplayInfo:nil contentInfo:nil opticalOutputScale:100];
    CAEDRMetadata *luminance = [CAEDRMetadata HDR10MetadataWithMinLuminance:0.05 maxLuminance:1000 opticalOutputScale:100];
    CAEDRMetadata *hlg = [CAEDRMetadata HLGMetadataWithAmbientViewingEnvironment:ambient];
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:hlg requiringSecureCoding:YES error:nil];
    CAEDRMetadata *roundTrip = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[CAEDRMetadata class] fromData:archive error:nil] : nil;
    printf("EDR metadata: HDR10 %d luminance %d HLG %d default %d bad data %d archive %d\n", [hdr isKindOfClass:[CAEDRMetadata class]],
           [luminance isKindOfClass:[CAEDRMetadata class]], [hlg isKindOfClass:[CAEDRMetadata class]],
           [[CAEDRMetadata HLGMetadata] isKindOfClass:[CAEDRMetadata class]],
           [CAEDRMetadata HLGMetadataWithAmbientViewingEnvironment:[NSData data]] != nil,
           [roundTrip isKindOfClass:[CAEDRMetadata class]]);
    return 0;
}

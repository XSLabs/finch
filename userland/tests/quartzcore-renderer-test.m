/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Exercise QuartzCore's software OpenGL layer and manual renderer. */
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#include <dlfcn.h>
#include <stdio.h>

typedef CGLError (*SetDrawableFunction)(CGLContextObj, GLsizei, GLsizei, void (*)(CGLContextObj, void *), void *);

@interface SolidColorLayer : CAOpenGLLayer
@end

@implementation SolidColorLayer
- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
            forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime
{
    glClearColor(1, 0.5, 0.25, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    [super drawInCGLContext:ctx pixelFormat:pf forLayerTime:time displayTime:displayTime];
}
@end

static void
pixel(const char *label, const uint8_t *p)
{
    printf("%s: %u %u %u %u\n", label, p[2], p[1], p[0], p[3]);
}

static CGColorRef
rgb(CGFloat r, CGFloat g, CGFloat b)
{
    return CGColorCreateSRGB(r, g, b, 1);
}

int
main(void)
{
    SetDrawableFunction setDrawable = NULL;
    *(void **)(&setDrawable) = dlsym(RTLD_DEFAULT, "FinchCGLSetDrawable");
    if (!setDrawable) {
        fprintf(stderr, "Finch's software CGL drawable hook is missing\n");
        return 2;
    }

    const size_t width = 32, height = 24;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!bitmap)
        return 2;

    SolidColorLayer *openGL = [SolidColorLayer layer];
    openGL.bounds = CGRectMake(0, 0, width, height);
    [openGL renderInContext:bitmap];
    const uint8_t *data = CGBitmapContextGetData(bitmap);
    size_t rowBytes = CGBitmapContextGetBytesPerRow(bitmap);
    const uint8_t *glPixel = data + (height / 2) * rowBytes + (width / 2) * 4;
    pixel("CAOpenGLLayer", glPixel);

    CGLPixelFormatObj format = [openGL copyCGLPixelFormatForDisplayMask:1];
    CGLContextObj context = format ? [openGL copyCGLContextForPixelFormat:format] : NULL;
    if (!context || setDrawable(context, width, height, NULL, NULL) != kCGLNoError)
        return 2;
    CGLSetCurrentContext(context);
    glViewport(0, 0, width, height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, width, 0, height, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    CALayer *root = [CALayer layer];
    root.bounds = CGRectMake(0, 0, width, height);
    CGColorRef blue = rgb(0.125, 0.375, 0.75);
    root.backgroundColor = blue;
    CGColorRelease(blue);
    CARenderer *renderer = [CARenderer rendererWithCGLContext:(void *)context options:nil];
    renderer.layer = root;
    renderer.bounds = CGRectMake(0, 0, width, height);
    [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
    [renderer addUpdateRect:renderer.bounds];
    [renderer render];
    uint8_t result[4] = {0};
    glReadPixels(width / 2, height / 2, 1, 1, GL_BGRA, GL_UNSIGNED_BYTE, result);
    pixel("CARenderer", result);

    BOOL matches = glPixel[2] == 255 && glPixel[1] >= 127 && glPixel[1] <= 128 && glPixel[0] >= 63 && glPixel[0] <= 64 &&
                   result[2] >= 31 && result[2] <= 32 && result[1] >= 95 && result[1] <= 96 &&
                   result[0] >= 191 && result[0] <= 192;

    CGLSetCurrentContext(NULL);
    [openGL releaseCGLContext:context];
    [openGL releaseCGLPixelFormat:format];
    CGContextRelease(bitmap);
    return matches ? 0 : 1;
}

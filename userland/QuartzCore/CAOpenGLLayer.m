/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OpenGL-backed Core Animation layers and the manual layer-tree renderer.
 * Finch uses Mesa's software CGL context, then hands its pixels to the same
 * CoreGraphics path as other layer contents.
 */
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

@interface CALayer (FinchOpenGLLayer)
- (void)_finchDrawContent:(CGContextRef)cg;
@end

/* These are Finch's private software-CGL hooks. Apple CGL has no such exports. */
extern CGLError FinchCGLSetDrawable(CGLContextObj ctx, GLsizei width, GLsizei height,
                                    void (*flush)(CGLContextObj, void *), void *info) __attribute__((weak_import));
extern const void *FinchCGLGetPixels(CGLContextObj ctx, GLsizei *width, GLsizei *height,
                                     GLint *rowBytes) __attribute__((weak_import));

static void
release_pixels(void *info, const void *data, size_t size)
{
    free((void *)data);
}

@implementation CAOpenGLLayer {
    CGLPixelFormatObj _pixelFormat;
    CGLContextObj _context;
    CGSize _contextSize;
    CGColorSpaceRef _colorspace;
    CGImageRef _renderedImage;
    BOOL _asynchronous, _wantsEDR;
}

- (void)dealloc
{
    if (_context)
        [self releaseCGLContext:_context];
    if (_pixelFormat)
        [self releaseCGLPixelFormat:_pixelFormat];
    CGColorSpaceRelease(_colorspace);
    CGImageRelease(_renderedImage);
    [super dealloc];
}

- (BOOL)isAsynchronous { return _asynchronous; }
- (void)setAsynchronous:(BOOL)value { _asynchronous = value; }
- (CGColorSpaceRef)colorspace { return _colorspace; }
- (void)setColorspace:(CGColorSpaceRef)value
{
    CGColorSpaceRetain(value);
    CGColorSpaceRelease(_colorspace);
    _colorspace = value;
}
- (BOOL)wantsExtendedDynamicRangeContent { return _wantsEDR; }
- (void)setWantsExtendedDynamicRangeContent:(BOOL)value { _wantsEDR = value; }

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
               forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime
{
    return YES;
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
            forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime
{
    glFlush();
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAColorSize, 32,
        kCGLPFAAlphaSize, 8,
        kCGLPFANoRecovery,
        0,
    };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || count == 0) {
        if (format)
            CGLDestroyPixelFormat(format);
        return NULL;
    }
    return format;
}

- (void)releaseCGLPixelFormat:(CGLPixelFormatObj)format
{
    CGLDestroyPixelFormat(format);
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)format
{
    CGLContextObj context = NULL;
    if (CGLCreateContext(format, NULL, &context) != kCGLNoError)
        return NULL;
    return context;
}

- (void)releaseCGLContext:(CGLContextObj)context
{
    CGLDestroyContext(context);
}

- (BOOL)_finchEnsureContext
{
    if (_context)
        return YES;
    _pixelFormat = [self copyCGLPixelFormatForDisplayMask:1];
    if (!_pixelFormat)
        return NO;
    _context = [self copyCGLContextForPixelFormat:_pixelFormat];
    if (!_context) {
        [self releaseCGLPixelFormat:_pixelFormat];
        _pixelFormat = NULL;
        return NO;
    }
    return YES;
}

- (CGImageRef)_finchCopyRenderedImageWithWidth:(size_t)width height:(size_t)height rowBytes:(size_t)rowBytes
{
    if (!FinchCGLGetPixels)
        return NULL;
    GLsizei pixelWidth = 0, pixelHeight = 0;
    GLint pixelRowBytes = 0;
    const uint8_t *pixels = FinchCGLGetPixels(_context, &pixelWidth, &pixelHeight, &pixelRowBytes);
    if (!pixels || pixelWidth != (GLsizei)width || pixelHeight != (GLsizei)height || pixelRowBytes < 0)
        return NULL;

    size_t bytes = (size_t)pixelRowBytes * height;
    uint8_t *copy = malloc(bytes);
    if (!copy)
        return NULL;
    memcpy(copy, pixels, bytes);
    /* CGL stores straight alpha; CoreGraphics layer contents are premultiplied. */
    for (size_t i = 0; i < bytes; i += 4) {
        unsigned alpha = copy[i + 3];
        copy[i] = (uint8_t)((copy[i] * alpha + 127) / 255);
        copy[i + 1] = (uint8_t)((copy[i + 1] * alpha + 127) / 255);
        copy[i + 2] = (uint8_t)((copy[i + 2] * alpha + 127) / 255);
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, bytes, release_pixels);
    if (!provider) {
        free(copy);
        return NULL;
    }
    CGColorSpaceRef space = _colorspace ? CGColorSpaceRetain(_colorspace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(width, height, 8, 32, (size_t)pixelRowBytes, space,
                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, YES, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

- (void)_finchDrawContent:(CGContextRef)cg
{
    if (![self _finchEnsureContext])
        return;
    CGRect bounds = [self bounds];
    size_t width = (size_t)ceil(bounds.size.width * [self contentsScale]);
    size_t height = (size_t)ceil(bounds.size.height * [self contentsScale]);
    if (!width || !height || !FinchCGLSetDrawable || !FinchCGLGetPixels)
        return;

    CGLContextObj previous = CGLGetCurrentContext();
    if (CGLSetCurrentContext(_context) != kCGLNoError)
        return;
    if (FinchCGLSetDrawable(_context, (GLsizei)width, (GLsizei)height, NULL, NULL) != kCGLNoError) {
        CGLSetCurrentContext(previous);
        return;
    }
    _contextSize = CGSizeMake(width, height);
    glViewport(0, 0, (GLsizei)width, (GLsizei)height);
    CFTimeInterval time = CACurrentMediaTime();
    if ([self canDrawInCGLContext:_context pixelFormat:_pixelFormat forLayerTime:time displayTime:NULL]) {
        [self drawInCGLContext:_context pixelFormat:_pixelFormat forLayerTime:time displayTime:NULL];
        glFinish();
        CGImageRef image = [self _finchCopyRenderedImageWithWidth:width height:height rowBytes:width * 4];
        if (image) {
            CGImageRelease(_renderedImage);
            _renderedImage = image;
        }
    }
    if (previous != _context)
        CGLSetCurrentContext(previous);
    if (_renderedImage)
        CGContextDrawImage(cg, bounds, _renderedImage);
}

@end

@implementation CARenderer {
    CGLContextObj _context;
    CALayer *_layer;
    CGRect _bounds, _updates;
    CFTimeInterval _frameTime;
    BOOL _frameOpen;
    CGColorSpaceRef _colorspace;
}

+ (CARenderer *)rendererWithCGLContext:(void *)context options:(NSDictionary *)options
{
    if (!context)
        return nil;
    CARenderer *renderer = [[[self alloc] init] autorelease];
    renderer->_context = CGLRetainContext((CGLContextObj)context);
    renderer->_updates = CGRectNull;
    id colorSpace = options[@"kCARendererColorSpace"];
    if (colorSpace && CFGetTypeID((CFTypeRef)colorSpace) == CGColorSpaceGetTypeID())
        renderer->_colorspace = CGColorSpaceRetain((CGColorSpaceRef)colorSpace);
    return renderer;
}

- (void)dealloc
{
    [_layer release];
    CGLReleaseContext(_context);
    CGColorSpaceRelease(_colorspace);
    [super dealloc];
}

- (CALayer *)layer { return _layer; }
- (void)setLayer:(CALayer *)layer
{
    [layer retain];
    [_layer release];
    _layer = layer;
    _updates = CGRectNull;
}

- (CGRect)bounds { return _bounds; }
- (void)setBounds:(CGRect)bounds
{
    _bounds = bounds;
    _updates = CGRectNull;
}

- (void)beginFrameAtTime:(CFTimeInterval)time timeStamp:(CVTimeStamp *)timeStamp
{
    _frameTime = time;
    _frameOpen = YES;
}

- (CGRect)updateBounds
{
    return CGRectIsNull(_updates) ? CGRectNull : CGRectIntersection(_updates, _bounds);
}

- (void)addUpdateRect:(CGRect)rect
{
    CGRect clipped = CGRectIntersection(rect, _bounds);
    if (CGRectIsNull(_updates))
        _updates = clipped;
    else
        _updates = CGRectUnion(_updates, clipped);
}

- (void)render
{
    if (!_frameOpen || !_context || !_layer || CGRectIsNull(_updates) || CGRectIsEmpty(_updates) || CGRectIsEmpty(_bounds))
        return;
    size_t width = (size_t)ceil(_bounds.size.width), height = (size_t)ceil(_bounds.size.height);
    if (!width || !height)
        return;
    CGColorSpaceRef space = _colorspace ? CGColorSpaceRetain(_colorspace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!cg)
        return;
    CGContextClearRect(cg, CGRectMake(0, 0, width, height));
    CGContextTranslateCTM(cg, -_bounds.origin.x, -_bounds.origin.y);
    [_layer renderInContext:cg];

    const void *pixels = CGBitmapContextGetData(cg);
    size_t rowBytes = CGBitmapContextGetBytesPerRow(cg);
    CGLContextObj previous = CGLGetCurrentContext();
    if (pixels && CGLSetCurrentContext(_context) == kCGLNoError) {
        GLint alignment = 4, rowLength = 0;
        GLfloat zoomX = 1, zoomY = 1;
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
        glGetIntegerv(GL_UNPACK_ROW_LENGTH, &rowLength);
        glGetFloatv(GL_ZOOM_X, &zoomX);
        glGetFloatv(GL_ZOOM_Y, &zoomY);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(rowBytes / 4));
        glPixelZoom(1, -1);
        glRasterPos2f((GLfloat)_bounds.origin.x, (GLfloat)CGRectGetMaxY(_bounds));
        glDrawPixels((GLsizei)width, (GLsizei)height, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
        glPixelZoom(zoomX, zoomY);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, rowLength);
        glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
        glRasterPos2f(0, 0);
        glFlush();
        if (previous != _context)
            CGLSetCurrentContext(previous);
    }
    CGContextRelease(cg);
    _updates = CGRectNull;
}

- (CFTimeInterval)nextFrameTime { return INFINITY; }
- (void)endFrame { _frameOpen = NO; }

@end

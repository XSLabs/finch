/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CIContext: where an image's recipe becomes pixels, in memory, a CGImage, a CGContext
 * or an encoded file. Finch's renders on the CPU (no Metal yet), in Apple's default
 * working space, extended linear sRGB; output is matched to sRGB unless the caller
 * names a linear space (or none).
 */
#import "CoreImage_Finch.h"
#import <ImageIO/ImageIO.h>

@implementation CIContext {
    NSDictionary *_options;
    CGContextRef _cg;
    CGColorSpaceRef _working, _output;
    CIFormat _workingFormat;
}

/* Finch's CoreImage renderer has no GPU path. */
+ (unsigned int)offlineGPUCount { return 0; }

+ (CIContext *)context { return [[[self alloc] initWithOptions:nil] autorelease]; }
+ (CIContext *)contextWithOptions:(NSDictionary<CIContextOption, id> *)options
{
    return [[[self alloc] initWithOptions:options] autorelease];
}
+ (CIContext *)contextWithCGContext:(CGContextRef)cgctx options:(NSDictionary<CIContextOption, id> *)options
{
    CIContext *c = [[[self alloc] initWithOptions:options] autorelease];
    c->_cg = CGContextRetain(cgctx);
    return c;
}

/* Metal, OpenGL and CGL contexts: Finch has no GPU path yet, so these render on the CPU. */
+ (CIContext *)contextWithMTLDevice:(id)device { return [self contextWithOptions:nil]; }
+ (CIContext *)contextWithMTLDevice:(id)device options:(NSDictionary *)options { return [self contextWithOptions:options]; }
+ (CIContext *)contextWithMTLCommandQueue:(id)commandQueue { return [self contextWithOptions:nil]; }
+ (CIContext *)contextWithMTLCommandQueue:(id)commandQueue options:(NSDictionary *)options { return [self contextWithOptions:options]; }
+ (CIContext *)contextWithCGLContext:(CGLContextObj)cglctx pixelFormat:(CGLPixelFormatObj)pixelFormat colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options
{
    return [self contextWithOptions:options];
}
+ (CIContext *)contextWithCGLContext:(CGLContextObj)cglctx pixelFormat:(CGLPixelFormatObj)pixelFormat options:(NSDictionary *)options
{
    return [self contextWithOptions:options];
}

static CGColorSpaceRef
space_option(id value, CFStringRef fallback)
{
    if (value == (id)[NSNull null])
        return NULL;
    if (value && CFGetTypeID((CFTypeRef)value) == CGColorSpaceGetTypeID())
        return CGColorSpaceRetain((CGColorSpaceRef)value);
    return CGColorSpaceCreateWithName(fallback);
}

- (instancetype)initWithOptions:(NSDictionary<CIContextOption, id> *)options
{
    if ((self = [super init])) {
        _options = [options copy] ?: [@{} retain];
        _working = space_option(options[kCIContextWorkingColorSpace], kCGColorSpaceExtendedLinearSRGB);
        _output = space_option(options[kCIContextOutputColorSpace], kCGColorSpaceSRGB);
        _workingFormat = options[kCIContextWorkingFormat] ? [options[kCIContextWorkingFormat] intValue] : kCIFormatRGBAh;
    }
    return self;
}

- (instancetype)init { return [self initWithOptions:nil]; }

- (void)dealloc
{
    [_options release];
    CGContextRelease(_cg);
    CGColorSpaceRelease(_working);
    CGColorSpaceRelease(_output);
    [super dealloc];
}

- (CGColorSpaceRef)workingColorSpace { return _working; }
- (CIFormat)workingFormat { return _workingFormat; }
- (CGSize)inputImageMaximumSize { return CGSizeMake(16384, 16384); }
- (CGSize)outputImageMaximumSize { return CGSizeMake(16384, 16384); }
- (void)reclaimResources {}
- (void)clearCaches {}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<CIContext: %p (cpu)>\n    workingSpace: %@\n    workingFormat: %@", self,
                                      _working ? @"ExtendedLinearSRGB" : @"(none)",
                                      _workingFormat == kCIFormatRGBAf ? @"RGBAf" : @"RGBAh"];
}

- (CGImageRef)createCGImage:(CIImage *)image fromRect:(CGRect)fromRect
{
    return ci_create_cgimage(image, fromRect, kCIFormatRGBA8, _output);
}

- (CGImageRef)createCGImage:(CIImage *)image fromRect:(CGRect)fromRect format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
{
    return ci_create_cgimage(image, fromRect, format, colorSpace ?: _output);
}

- (CGImageRef)createCGImage:(CIImage *)image fromRect:(CGRect)fromRect format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
                   deferred:(BOOL)deferred
{
    return [self createCGImage:image fromRect:fromRect format:format colorSpace:colorSpace];
}

- (CGImageRef)createCGImage:(CIImage *)image fromRect:(CGRect)fromRect format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
                   deferred:(BOOL)deferred calculateHDRStats:(BOOL)calculateHDRStats
{
    return [self createCGImage:image fromRect:fromRect format:format colorSpace:colorSpace];
}

- (void)render:(CIImage *)image toBitmap:(void *)data rowBytes:(ptrdiff_t)rowBytes bounds:(CGRect)bounds format:(CIFormat)format
    colorSpace:(CGColorSpaceRef)colorSpace
{
    if (!data || !image)
        return;
    ci_write(image, data, (size_t)rowBytes, bounds, format, colorSpace);
}

- (void)render:(CIImage *)image toCVPixelBuffer:(CVPixelBufferRef)buffer {}
- (void)render:(CIImage *)image toCVPixelBuffer:(CVPixelBufferRef)buffer bounds:(CGRect)bounds colorSpace:(CGColorSpaceRef)colorSpace {}
- (void)render:(CIImage *)image toIOSurface:(IOSurfaceRef)surface bounds:(CGRect)bounds colorSpace:(CGColorSpaceRef)colorSpace {}

/* Into the context's CGContext (one made with contextWithCGContext:). */
- (void)drawImage:(CIImage *)image inRect:(CGRect)inRect fromRect:(CGRect)fromRect
{
    if (!_cg || !image)
        return;
    if (CGRectIsInfinite(fromRect))
        fromRect = image.extent;
    CGImageRef cg = [self createCGImage:image fromRect:fromRect];
    if (!cg)
        return;
    CGContextDrawImage(_cg, inRect, cg);
    CGImageRelease(cg);
}

- (void)drawImage:(CIImage *)image atPoint:(CGPoint)atPoint fromRect:(CGRect)fromRect
{
    [self drawImage:image inRect:CGRectMake(atPoint.x, atPoint.y, fromRect.size.width, fromRect.size.height) fromRect:fromRect];
}

/* --- encoded files --- */

static NSData *
encode(CIContext *ctx, CIImage *image, CFStringRef type, CIFormat format, CGColorSpaceRef space, NSDictionary *options)
{
    if (CGRectIsInfinite(image.extent) || CGRectIsEmpty(image.extent))
        return nil;
    CGImageRef cg = ci_create_cgimage(image, image.extent, format ?: kCIFormatRGBA8, space);
    if (!cg)
        return nil;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((CFMutableDataRef)data, type, 1, NULL);
    NSMutableDictionary *props = [NSMutableDictionary dictionaryWithDictionary:image.properties];
    id quality = options[(NSString *)kCGImageDestinationLossyCompressionQuality];
    if (quality)
        props[(NSString *)kCGImageDestinationLossyCompressionQuality] = quality;
    CGImageDestinationAddImage(d, cg, (CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    CGImageRelease(cg);
    return ok ? data : nil;
}

- (NSData *)TIFFRepresentationOfImage:(CIImage *)image format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options
{
    return encode(self, image, CFSTR("public.tiff"), format, colorSpace, options);
}

- (NSData *)JPEGRepresentationOfImage:(CIImage *)image colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options
{
    return encode(self, image, CFSTR("public.jpeg"), kCIFormatRGBA8, colorSpace, options);
}

- (NSData *)PNGRepresentationOfImage:(CIImage *)image format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options
{
    return encode(self, image, CFSTR("public.png"), format, colorSpace, options);
}

- (NSData *)HEIFRepresentationOfImage:(CIImage *)image format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options
{
    return nil; /* no HEIF writer yet (ImageIO) */
}

- (NSData *)HEIF10RepresentationOfImage:(CIImage *)image colorSpace:(CGColorSpaceRef)colorSpace options:(NSDictionary *)options error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnsupportedSchemeError userInfo:nil];
    return nil;
}

static BOOL
write_data(NSData *data, NSURL *url, NSError **error)
{
    if (!data) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
        return NO;
    }
    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (BOOL)writeTIFFRepresentationOfImage:(CIImage *)image toURL:(NSURL *)url format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
                               options:(NSDictionary *)options error:(NSError **)error
{
    return write_data([self TIFFRepresentationOfImage:image format:format colorSpace:colorSpace options:options], url, error);
}

- (BOOL)writePNGRepresentationOfImage:(CIImage *)image toURL:(NSURL *)url format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
                              options:(NSDictionary *)options error:(NSError **)error
{
    return write_data([self PNGRepresentationOfImage:image format:format colorSpace:colorSpace options:options], url, error);
}

- (BOOL)writeJPEGRepresentationOfImage:(CIImage *)image toURL:(NSURL *)url colorSpace:(CGColorSpaceRef)colorSpace
                               options:(NSDictionary *)options error:(NSError **)error
{
    return write_data([self JPEGRepresentationOfImage:image colorSpace:colorSpace options:options], url, error);
}

- (BOOL)writeHEIFRepresentationOfImage:(CIImage *)image toURL:(NSURL *)url format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
                               options:(NSDictionary *)options error:(NSError **)error
{
    return write_data(nil, url, error);
}

@end

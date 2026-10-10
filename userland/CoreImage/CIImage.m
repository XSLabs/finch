/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CIImage: an image as a recipe (its extent and how to render any part of it), and
 * the rendering under it. Sources (CGImages, bitmaps, files through ImageIO) come
 * into the working space, extended linear sRGB with premultiplied alpha, as with
 * Apple's; transforms sample bilinearly between pixel centres; nothing is computed
 * until a CIContext asks for pixels.
 */
#import "CoreImage_Finch.h"
#import <ImageIO/ImageIO.h>

CIBuf
ci_buf_alloc(CGRect r)
{
    CIBuf b;
    b.r = r;
    b.w = r.size.width > 0 ? (size_t)r.size.width : 0;
    b.h = r.size.height > 0 ? (size_t)r.size.height : 0;
    b.px = calloc(b.w * b.h * 4 + 4, sizeof(float));
    return b;
}

void
ci_buf_free(CIBuf b)
{
    free(b.px);
}

BOOL
ci_space_is_linear(CGColorSpaceRef space)
{
    if (!space)
        return YES;
    CFStringRef name = CGColorSpaceCopyName(space);
    BOOL linear = NO;
    if (name) {
        linear = CFEqual(name, kCGColorSpaceLinearSRGB) || CFEqual(name, kCGColorSpaceExtendedLinearSRGB) ||
                 CFEqual(name, kCGColorSpaceGenericRGBLinear) || CFEqual(name, kCGColorSpaceLinearGray) ||
                 CFEqual(name, kCGColorSpaceExtendedLinearGray) || CFEqual(name, kCGColorSpaceGenericXYZ);
        CFRelease(name);
    }
    return linear;
}

/* --- the image recipe --- */

@implementation CIImage {
    CGRect _extent;
    CIRenderBlock _render;
    NSDictionary *_properties;
    NSURL *_url;
    CGImageRef _cgImage; /* the source, for -CGImage */
    CGColorSpaceRef _space;
    BOOL _opaque;
    BOOL _encodedSource; /* sampled in its own (sRGB) encoding, before matching, as Apple's */
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_finchInitWithExtent:(CGRect)extent render:(CIRenderBlock)render
{
    if ((self = [super init])) {
        _extent = extent;
        _render = [render copy];
    }
    return self;
}

- (void)dealloc
{
    [_render release];
    [_properties release];
    [_url release];
    CGImageRelease(_cgImage);
    CGColorSpaceRelease(_space);
    [super dealloc];
}

CIImage *
ci_image(CGRect extent, CIRenderBlock render)
{
    return [[[CIImage alloc] _finchInitWithExtent:extent render:render] autorelease];
}

- (CIBuf)_finchRender:(CGRect)r
{
    r = CGRectIntegral(r);
    CGRect inside = CGRectIntersection(r, _extent);
    if (CGRectIsEmpty(inside) || !_render)
        return ci_buf_alloc(r);
    inside = CGRectIntegral(inside);
    if (CGRectEqualToRect(inside, r))
        return _render(r);
    /* render what's inside the extent, transparent around it */
    CIBuf part = _render(inside);
    CIBuf out = ci_buf_alloc(r);
    size_t dx = (size_t)(inside.origin.x - r.origin.x), dy = (size_t)(inside.origin.y - r.origin.y);
    for (size_t y = 0; y < part.h && y + dy < out.h; y++)
        memcpy(ci_buf_at(out, dx, y + dy), ci_buf_at(part, 0, y), MIN(part.w, out.w - dx) * 4 * sizeof(float));
    ci_buf_free(part);
    return out;
}

CIBuf
ci_render(CIImage *image, CGRect r)
{
    if (!image)
        return ci_buf_alloc(CGRectIntegral(r));
    return [image _finchRender:r];
}

CIImage *
ci_map_premultiplied(CIImage *input, CGRect extent, void (^fn)(float *rgba))
{
    void (^f)(float *) = [[fn copy] autorelease];
    return ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf b = ci_render(input, r);
      for (size_t i = 0; i < b.w * b.h; i++)
          f(b.px + i * 4);
      return b;
    });
}

CIImage *
ci_map(CIImage *input, CGRect extent, void (^fn)(float *rgba))
{
    void (^f)(float *) = [[fn copy] autorelease];
    return ci_map_premultiplied(input, extent, ^(float *p) {
      float a = p[3];
      if (a > 0)
          for (int c = 0; c < 3; c++)
              p[c] /= a;
      f(p);
      for (int c = 0; c < 3; c++)
          p[c] *= p[3];
    });
}

/* --- sources --- */

/* A CGImage, drawn into premultiplied sRGB and brought into the working space. */
static CIBuf
render_cgimage(CGImageRef image, CGRect r)
{
    CIBuf b = ci_buf_alloc(r);
    if (!b.w || !b.h)
        return b;
    static CGColorSpaceRef srgb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    uint8_t *bytes = calloc(b.w * b.h, 4);
    CGContextRef ctx = CGBitmapContextCreate(bytes, b.w, b.h, 8, b.w * 4, srgb,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(-r.origin.x, -r.origin.y, CGImageGetWidth(image), CGImageGetHeight(image)), image);
    CGContextRelease(ctx);
    /* rows from the bottom; the context's memory is top row first */
    for (size_t y = 0; y < b.h; y++) {
        const uint8_t *row = bytes + (b.h - 1 - y) * b.w * 4;
        for (size_t x = 0; x < b.w; x++) {
            float *p = ci_buf_at(b, x, y);
            float a = row[x * 4 + 3] / 255.0f;
            for (int c = 0; c < 3; c++) {
                float v = a > 0 ? row[x * 4 + c] / 255.0f / a : 0;
                p[c] = ci_linear_from_srgb(v) * a;
            }
            p[3] = a;
        }
    }
    free(bytes);
    return b;
}

- (instancetype)initWithCGImage:(CGImageRef)image options:(NSDictionary<CIImageOption, id> *)options
{
    if (!image) {
        [self release];
        return nil;
    }
    CGImageRetain(image);
    self = [self _finchInitWithExtent:CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image))
                               render:^CIBuf(CGRect r) { return render_cgimage(image, r); }];
    _cgImage = image;
    _encodedSource = YES;
    _space = CGColorSpaceRetain(CGImageGetColorSpace(image));
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    _opaque = alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipLast || alpha == kCGImageAlphaNoneSkipFirst;
    id props = options[kCIImageProperties];
    _properties = [props isKindOfClass:[NSDictionary class]] ? [props copy] : [@{} retain];
    return self;
}

- (instancetype)initWithCGImage:(CGImageRef)image { return [self initWithCGImage:image options:nil]; }

+ (CIImage *)imageWithCGImage:(CGImageRef)image { return [[[self alloc] initWithCGImage:image] autorelease]; }
+ (CIImage *)imageWithCGImage:(CGImageRef)image options:(NSDictionary *)options
{
    return [[[self alloc] initWithCGImage:image options:options] autorelease];
}

- (instancetype)initWithCGImageSource:(CGImageSourceRef)source index:(size_t)index options:(NSDictionary *)options
{
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, index, NULL) : NULL;
    if (!image) {
        [self release];
        return nil;
    }
    NSDictionary *props = [(NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, index, NULL) autorelease];
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithDictionary:options ?: @{}];
    if (props && !o[kCIImageProperties])
        o[kCIImageProperties] = props;
    self = [self initWithCGImage:image options:o];
    CGImageRelease(image);
    /* kCIImageApplyOrientationProperty: turned upright as its EXIF orientation says */
    if ([options[kCIImageApplyOrientationProperty] boolValue]) {
        int orientation = [props[(NSString *)kCGImagePropertyOrientation] intValue];
        if (orientation > 1) {
            CIImage *turned = [[self imageByApplyingOrientation:orientation] retain];
            [self release];
            return turned;
        }
    }
    return self;
}

+ (CIImage *)imageWithCGImageSource:(CGImageSourceRef)source index:(size_t)index options:(NSDictionary *)options
{
    return [[[self alloc] initWithCGImageSource:source index:index options:options] autorelease];
}

- (instancetype)initWithData:(NSData *)data options:(NSDictionary *)options
{
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    self = [self initWithCGImageSource:source index:0 options:options];
    if (source)
        CFRelease(source);
    return self;
}

- (instancetype)initWithData:(NSData *)data { return [self initWithData:data options:nil]; }
+ (CIImage *)imageWithData:(NSData *)data { return [[[self alloc] initWithData:data] autorelease]; }
+ (CIImage *)imageWithData:(NSData *)data options:(NSDictionary *)options
{
    return [[[self alloc] initWithData:data options:options] autorelease];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url options:(NSDictionary *)options
{
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
    self = [self initWithCGImageSource:source index:0 options:options];
    if (source)
        CFRelease(source);
    if (self)
        _url = [url copy];
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url { return [self initWithContentsOfURL:url options:nil]; }
+ (CIImage *)imageWithContentsOfURL:(NSURL *)url { return [[[self alloc] initWithContentsOfURL:url] autorelease]; }
+ (CIImage *)imageWithContentsOfURL:(NSURL *)url options:(NSDictionary *)options
{
    return [[[self alloc] initWithContentsOfURL:url options:options] autorelease];
}

/* Bitmap data in a CoreImage format: wrapped as a CGImage where CoreGraphics can read it. */
- (instancetype)initWithBitmapData:(NSData *)data bytesPerRow:(size_t)bytesPerRow size:(CGSize)size format:(CIFormat)format
                        colorSpace:(CGColorSpaceRef)colorSpace
{
    size_t bpc = 8, bpp = 32;
    CGBitmapInfo info;
    if (format == kCIFormatRGBA8)
        info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    else if (format == kCIFormatBGRA8)
        info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    else if (format == kCIFormatARGB8)
        info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big;
    else if (format == kCIFormatRGBAf) {
        info = kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little;
        bpc = 32;
        bpp = 128;
    } else if (format == kCIFormatRGBAh) {
        info = kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little;
        bpc = 16;
        bpp = 64;
    } else if (format == kCIFormatL8 || format == kCIFormatR8) {
        info = (CGBitmapInfo)kCGImageAlphaNone;
        bpp = 8;
    } else {
        [self release];
        return nil;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    CGColorSpaceRef space = colorSpace;
    CGColorSpaceRef made = NULL;
    if (!space || (bpp == 8 && CGColorSpaceGetModel(space) != kCGColorSpaceModelMonochrome))
        space = made = bpp == 8 ? CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2)
                                : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate((size_t)size.width, (size_t)size.height, bpc, bpp, bytesPerRow, space, info, provider,
                                     NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (made)
        CGColorSpaceRelease(made);
    self = [self initWithCGImage:image];
    CGImageRelease(image);
    return self;
}

+ (CIImage *)imageWithBitmapData:(NSData *)data bytesPerRow:(size_t)bytesPerRow size:(CGSize)size format:(CIFormat)format
                      colorSpace:(CGColorSpaceRef)colorSpace
{
    return [[[self alloc] initWithBitmapData:data bytesPerRow:bytesPerRow size:size format:format colorSpace:colorSpace] autorelease];
}

/* A color, everywhere. */
- (instancetype)initWithColor:(CIColor *)color
{
    struct {
        float v[4];
    } c;
    [color _finchWorkingComponents:c.v];
    self = [self _finchInitWithExtent:CGRectInfinite
                               render:^CIBuf(CGRect r) {
                                 CIBuf b = ci_buf_alloc(r);
                                 for (size_t i = 0; i < b.w * b.h; i++)
                                     memcpy(b.px + i * 4, c.v, sizeof c.v);
                                 return b;
                               }];
    _opaque = c.v[3] >= 1;
    return self;
}

+ (CIImage *)imageWithColor:(CIColor *)color { return [[[self alloc] initWithColor:color] autorelease]; }

+ (CIImage *)emptyImage
{
    static CIImage *empty;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ empty = [[CIImage alloc] _finchInitWithExtent:CGRectNull render:nil]; });
    return empty;
}

#define CONSTANT_IMAGE(name, colorName)                                                                        \
    +(CIImage *)name { return [self imageWithColor:[CIColor colorName]]; }
CONSTANT_IMAGE(blackImage, blackColor)
CONSTANT_IMAGE(whiteImage, whiteColor)
CONSTANT_IMAGE(grayImage, grayColor)
CONSTANT_IMAGE(redImage, redColor)
CONSTANT_IMAGE(greenImage, greenColor)
CONSTANT_IMAGE(blueImage, blueColor)
CONSTANT_IMAGE(cyanImage, cyanColor)
CONSTANT_IMAGE(magentaImage, magentaColor)
CONSTANT_IMAGE(yellowImage, yellowColor)
CONSTANT_IMAGE(clearImage, clearColor)

/* No Metal, OpenGL or IOSurface on Finch yet. */
+ (CIImage *)imageWithIOSurface:(IOSurfaceRef)surface { return nil; }
+ (CIImage *)imageWithIOSurface:(IOSurfaceRef)surface options:(NSDictionary *)options { return nil; }
+ (CIImage *)imageWithCVImageBuffer:(CVImageBufferRef)imageBuffer { return nil; }
+ (CIImage *)imageWithCVImageBuffer:(CVImageBufferRef)imageBuffer options:(NSDictionary *)options { return nil; }
+ (CIImage *)imageWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer { return nil; }
+ (CIImage *)imageWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer options:(NSDictionary *)options { return nil; }

/* --- what an image is --- */

- (CGRect)extent { return _extent; }
- (BOOL)_finchIsEncodedSource { return _encodedSource; }
- (NSDictionary *)properties { return _properties ?: @{}; }
- (NSURL *)url { return _url; }
- (CGColorSpaceRef)colorSpace { return _space; }
- (CGImageRef)CGImage { return _cgImage; }
- (CVPixelBufferRef)pixelBuffer { return NULL; }
- (BOOL)isOpaque { return _opaque; }
- (CIFilterShape *)definition { return nil; }

- (NSString *)description
{
    if (CGRectIsInfinite(_extent))
        return [NSString stringWithFormat:@"<CIImage: %p extent [infinite]>", self];
    if (CGRectIsNull(_extent))
        return [NSString stringWithFormat:@"<CIImage: %p extent [empty]>", self];
    return [NSString stringWithFormat:@"<CIImage: %p extent [%g %g %g %g]>", self, _extent.origin.x, _extent.origin.y,
                                      _extent.size.width, _extent.size.height];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (CGRect)regionOfInterestForImage:(CIImage *)image inRect:(CGRect)rect { return rect; }

/* Archived as a PNG of its pixels (an infinite image can't be). */
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (CGRectIsInfinite(_extent) || CGRectIsEmpty(_extent))
        return;
    CGImageRef image = ci_create_cgimage(self, _extent, kCIFormatRGBA8, NULL);
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, image, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d);
    CGImageRelease(image);
    [coder encodeObject:png forKey:@"CIImagePNG"];
    [coder encodeDouble:_extent.origin.x forKey:@"CIImageX"];
    [coder encodeDouble:_extent.origin.y forKey:@"CIImageY"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *png = [coder decodeObjectOfClass:[NSData class] forKey:@"CIImagePNG"];
    if (!png) {
        [self release];
        return [[CIImage emptyImage] retain];
    }
    CIImage *image = [[CIImage imageWithData:png] imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                                                             [coder decodeDoubleForKey:@"CIImageX"],
                                                                             [coder decodeDoubleForKey:@"CIImageY"])];
    [self release];
    return [image retain];
}

/* --- making images from images --- */

/* Bilinear sampling of a buffer at a point (pixel centres at .5), transparent outside. */
static void
sample(CIBuf b, double x, double y, float *out, BOOL clamp)
{
    double fx = x - b.r.origin.x - 0.5, fy = y - b.r.origin.y - 0.5;
    long x0 = (long)floor(fx), y0 = (long)floor(fy);
    float tx = (float)(fx - x0), ty = (float)(fy - y0);
    out[0] = out[1] = out[2] = out[3] = 0;
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++) {
            long px = x0 + i, py = y0 + j;
            float w = (i ? tx : 1 - tx) * (j ? ty : 1 - ty);
            if (w == 0)
                continue;
            if (clamp) {
                px = px < 0 ? 0 : px >= (long)b.w ? (long)b.w - 1 : px;
                py = py < 0 ? 0 : py >= (long)b.h ? (long)b.h - 1 : py;
            } else if (px < 0 || py < 0 || px >= (long)b.w || py >= (long)b.h) {
                continue;
            }
            const float *p = ci_buf_at(b, (size_t)px, (size_t)py);
            for (int c = 0; c < 4; c++)
                out[c] += p[c] * w;
        }
}

- (CIImage *)imageByApplyingTransform:(CGAffineTransform)t
{
    if (CGAffineTransformIsIdentity(t))
        return self;
    CIImage *input = self;
    CGRect extent = CGRectIsInfinite(_extent) ? CGRectInfinite : CGRectApplyAffineTransform(_extent, t);
    /* a whole-pixel translation is a copy */
    if (t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 && t.tx == floor(t.tx) && t.ty == floor(t.ty)) {
        double tx = t.tx, ty = t.ty;
        return ci_image(extent, ^CIBuf(CGRect r) {
          CIBuf b = ci_render(input, CGRectOffset(r, -tx, -ty));
          b.r = r;
          return b;
        });
    }
    CGAffineTransform inverse = CGAffineTransformInvert(t);
    BOOL encoded = _encodedSource;
    return ci_image(extent, ^CIBuf(CGRect r) {
      CGRect source = CGRectIntegral(CGRectInset(CGRectApplyAffineTransform(r, inverse), -2, -2));
      if (!CGRectIsInfinite(input.extent))
          source = CGRectIntegral(CGRectIntersection(source, input.extent));
      CIBuf in = ci_render(input, source);
      if (encoded)
          for (size_t i = 0; i < in.w * in.h; i++) {
              float *p = in.px + i * 4;
              for (int c = 0; c < 3; c++)
                  p[c] = p[3] > 0 ? ci_srgb_from_linear(p[c] / p[3]) * p[3] : 0;
          }
      CIBuf out = ci_buf_alloc(r);
      /* bilinear, the edges of the source extended (as Apple's samples); the output is
         limited to the transformed extent by the caller */
      BOOL edge = !CGRectIsInfinite(input.extent);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              CGPoint p = CGPointApplyAffineTransform(CGPointMake(r.origin.x + x + 0.5, r.origin.y + y + 0.5), inverse);
              float *o = ci_buf_at(out, x, y);
              sample(in, p.x, p.y, o, edge);
              if (encoded)
                  for (int c = 0; c < 3; c++)
                      o[c] = o[3] > 0 ? ci_linear_from_srgb(o[c] / o[3]) * o[3] : 0;
          }
      ci_buf_free(in);
      return out;
    });
}

- (CIImage *)imageByApplyingTransform:(CGAffineTransform)matrix highQualityDownsample:(BOOL)highQualityDownsample
{
    return [self imageByApplyingTransform:matrix];
}

/* EXIF orientations 1-8, mapped back to the image's extent. */
- (CGAffineTransform)imageTransformForOrientation:(int)orientation
{
    CGFloat w = _extent.size.width, h = _extent.size.height, x = _extent.origin.x, y = _extent.origin.y;
    CGAffineTransform t;
    switch (orientation) {
    case 2: t = CGAffineTransformMake(-1, 0, 0, 1, w, 0); break;
    case 3: t = CGAffineTransformMake(-1, 0, 0, -1, w, h); break;
    case 4: t = CGAffineTransformMake(1, 0, 0, -1, 0, h); break;
    case 5: t = CGAffineTransformMake(0, -1, -1, 0, h, w); break;
    case 6: t = CGAffineTransformMake(0, -1, 1, 0, 0, w); break;
    case 7: t = CGAffineTransformMake(0, 1, 1, 0, 0, 0); break;
    case 8: t = CGAffineTransformMake(0, 1, -1, 0, h, 0); break;
    default: return CGAffineTransformIdentity;
    }
    /* about the extent's origin */
    t = CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformMakeTranslation(-x, -y), t),
                                CGAffineTransformMakeTranslation(x, y));
    return t;
}

- (CIImage *)imageByApplyingOrientation:(int)orientation
{
    return [self imageByApplyingTransform:[self imageTransformForOrientation:orientation]];
}

- (CGAffineTransform)imageTransformForCGOrientation:(CGImagePropertyOrientation)orientation
{
    return [self imageTransformForOrientation:(int)orientation];
}

- (CIImage *)imageByApplyingCGOrientation:(CGImagePropertyOrientation)orientation
{
    return [self imageByApplyingOrientation:(int)orientation];
}

- (CIImage *)imageByCroppingToRect:(CGRect)rect
{
    CGRect extent = CGRectIntersection(_extent, rect);
    if (CGRectIsNull(extent) || CGRectIsEmpty(extent))
        return [CIImage emptyImage];
    if (CGRectEqualToRect(extent, _extent))
        return self;
    CIImage *input = self;
    CIImage *out = ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf b = ci_render(input, r);
      /* pixels partly inside a fractional crop keep their covered fraction */
      for (size_t y = 0; y < b.h; y++)
          for (size_t x = 0; x < b.w; x++) {
              double x0 = b.r.origin.x + x, y0 = b.r.origin.y + y;
              double cx = fmax(0, fmin(x0 + 1, CGRectGetMaxX(extent)) - fmax(x0, CGRectGetMinX(extent)));
              double cy = fmax(0, fmin(y0 + 1, CGRectGetMaxY(extent)) - fmax(y0, CGRectGetMinY(extent)));
              float cover = (float)(cx * cy);
              if (cover < 1) {
                  float *p = ci_buf_at(b, x, y);
                  for (int c = 0; c < 4; c++)
                      p[c] *= cover;
              }
          }
      return b;
    });
    out->_opaque = _opaque;
    return out;
}

- (CIImage *)imageByClampingToRect:(CGRect)rect
{
    CIImage *input = self;
    CGRect area = CGRectIntegral(CGRectIntersection(rect, _extent));
    if (CGRectIsEmpty(area))
        return [CIImage emptyImage];
    return ci_image(CGRectInfinite, ^CIBuf(CGRect r) {
      CIBuf in = ci_render(input, area);
      CIBuf out = ci_buf_alloc(r);
      for (size_t y = 0; y < out.h; y++)
          for (size_t x = 0; x < out.w; x++) {
              long sx = (long)(r.origin.x + x - area.origin.x), sy = (long)(r.origin.y + y - area.origin.y);
              sx = sx < 0 ? 0 : sx >= (long)in.w ? (long)in.w - 1 : sx;
              sy = sy < 0 ? 0 : sy >= (long)in.h ? (long)in.h - 1 : sy;
              memcpy(ci_buf_at(out, x, y), ci_buf_at(in, (size_t)sx, (size_t)sy), 4 * sizeof(float));
          }
      ci_buf_free(in);
      return out;
    });
}

- (CIImage *)imageByClampingToExtent
{
    if (CGRectIsInfinite(_extent))
        return self;
    return [self imageByClampingToRect:_extent];
}

- (CIImage *)imageByCompositingOverImage:(CIImage *)dest
{
    return [self imageByApplyingFilter:@"CISourceOverCompositing" withInputParameters:@{kCIInputBackgroundImageKey : dest}];
}

- (CIImage *)imageByApplyingFilter:(NSString *)filterName withInputParameters:(NSDictionary *)params
{
    CIFilter *f = [CIFilter filterWithName:filterName];
    if (!f)
        return nil;
    [f setValue:self forKey:kCIInputImageKey];
    [f setValuesForKeysWithDictionary:params ?: @{}];
    return f.outputImage;
}

- (CIImage *)imageByApplyingFilter:(NSString *)filterName
{
    return [self imageByApplyingFilter:filterName withInputParameters:nil];
}

- (CIImage *)imageByApplyingGaussianBlurWithSigma:(double)sigma
{
    return [self imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey : @(sigma)}];
}

- (CIImage *)imageByColorMatchingColorSpaceToWorkingSpace:(CGColorSpaceRef)colorSpace
{
    if (ci_space_is_linear(colorSpace))
        return self;
    return ci_map(self, _extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = ci_linear_from_srgb(p[c]);
    });
}

- (CIImage *)imageByColorMatchingWorkingSpaceToColorSpace:(CGColorSpaceRef)colorSpace
{
    if (ci_space_is_linear(colorSpace))
        return self;
    return ci_map(self, _extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] = ci_srgb_from_linear(p[c]);
    });
}

- (CIImage *)imageByPremultiplyingAlpha
{
    return ci_map_premultiplied(self, _extent, ^(float *p) {
      for (int c = 0; c < 3; c++)
          p[c] *= p[3];
    });
}

- (CIImage *)imageByUnpremultiplyingAlpha
{
    return ci_map_premultiplied(self, _extent, ^(float *p) {
      if (p[3] > 0)
          for (int c = 0; c < 3; c++)
              p[c] /= p[3];
    });
}

- (CIImage *)imageBySettingAlphaOneInExtent:(CGRect)extent
{
    return ci_map_premultiplied(self, _extent, ^(float *p) { p[3] = 1; });
}

- (CIImage *)imageBySettingProperties:(NSDictionary *)properties
{
    CIImage *copy = ci_image(_extent, _render);
    copy->_properties = [properties copy];
    copy->_cgImage = CGImageRetain(_cgImage);
    copy->_space = CGColorSpaceRetain(_space);
    copy->_url = [_url copy];
    copy->_opaque = _opaque;
    return copy;
}

- (CIImage *)imageBySamplingLinear { return self; }
- (CIImage *)imageBySamplingNearest { return self; }
- (CIImage *)imageByInsertingIntermediate { return self; }
- (CIImage *)imageByInsertingIntermediate:(BOOL)cache { return self; }

@end

/* --- output --- */

static inline float
clamp01(float v)
{
    return v < 0 ? 0 : v > 1 ? 1 : v;
}

/* To 8 bits, halves rounded up (as Apple's). */
static inline uint8_t
to8(float v)
{
    return (uint8_t)floorf(clamp01(v) * 255 + 0.5f);
}

void
ci_write(CIImage *image, void *data, size_t rowBytes, CGRect r, CIFormat format, CGColorSpaceRef space)
{
    r = CGRectIntegral(r);
    CIBuf b = ci_render(image, r);
    BOOL linear = ci_space_is_linear(space);
    BOOL gray = space && CGColorSpaceGetModel(space) == kCGColorSpaceModelMonochrome;
    for (size_t y = 0; y < b.h; y++) {
        uint8_t *row = (uint8_t *)data + (b.h - 1 - y) * rowBytes; /* top row first */
        for (size_t x = 0; x < b.w; x++) {
            const float *p = ci_buf_at(b, x, y);
            /* the working format is half floats, as Apple's (RGBAh) */
            float h[4];
            for (int i = 0; i < 4; i++)
                h[i] = (float)(_Float16)p[i];
            p = h;
            float a = p[3], c[3];
            /* integer formats hold 0...1: the encoded colour is clamped, then premultiplied by the
               alpha as it is (the product is clamped as it's written) */
            BOOL clamp = format != kCIFormatRGBAf && format != kCIFormatRGBAh && format != kCIFormatAf &&
                         format != kCIFormatLf && format != kCIFormatRf;
            for (int i = 0; i < 3; i++) {
                float v = p[3] > 0 ? p[i] / p[3] : 0;
                c[i] = linear ? v : ci_srgb_from_linear(v);
                if (clamp)
                    c[i] = clamp01(c[i]);
            }
            if (gray || format == kCIFormatL8 || format == kCIFormatLf || format == kCIFormatL16 || format == kCIFormatLh) {
                float l = 0.2126f * (a > 0 ? p[0] / a : 0) + 0.7152f * (a > 0 ? p[1] / a : 0) + 0.0722f * (a > 0 ? p[2] / a : 0);
                c[0] = c[1] = c[2] = linear ? l : ci_srgb_from_linear(l);
            }
            /* premultiplied in the output encoding */
            float pr = c[0] * a, pg = c[1] * a, pb = c[2] * a;
            if (format == kCIFormatRGBA8 || format == kCIFormatBGRA8 || format == kCIFormatARGB8 || format == kCIFormatABGR8 ||
                format == kCIFormatRGBX8 || format == kCIFormatXRGB8 || format == kCIFormatBGRX8 || format == kCIFormatXBGR8) {
                uint8_t v[4] = {to8(pr), to8(pg), to8(pb), to8(a)};
                uint8_t *o = row + x * 4;
                if (format == kCIFormatRGBA8 || format == kCIFormatRGBX8) {
                    o[0] = v[0], o[1] = v[1], o[2] = v[2], o[3] = format == kCIFormatRGBX8 ? 255 : v[3];
                } else if (format == kCIFormatBGRA8 || format == kCIFormatBGRX8) {
                    o[0] = v[2], o[1] = v[1], o[2] = v[0], o[3] = format == kCIFormatBGRX8 ? 255 : v[3];
                } else if (format == kCIFormatARGB8 || format == kCIFormatXRGB8) {
                    o[0] = format == kCIFormatXRGB8 ? 255 : v[3], o[1] = v[0], o[2] = v[1], o[3] = v[2];
                } else {
                    o[0] = format == kCIFormatXBGR8 ? 255 : v[3], o[1] = v[2], o[2] = v[1], o[3] = v[0];
                }
            } else if (format == kCIFormatA8) {
                row[x] = to8(a);
            } else if (format == kCIFormatL8 || format == kCIFormatR8) {
                row[x] = to8(format == kCIFormatL8 ? c[0] * a : pr);
            } else if (format == kCIFormatRGBAf) {
                float *o = (float *)(row + x * 16);
                o[0] = pr, o[1] = pg, o[2] = pb, o[3] = a;
            } else if (format == kCIFormatRGBAh) {
                _Float16 *o = (_Float16 *)(row + x * 8);
                o[0] = (_Float16)pr, o[1] = (_Float16)pg, o[2] = (_Float16)pb, o[3] = (_Float16)a;
            } else if (format == kCIFormatRGBA16) {
                uint16_t *o = (uint16_t *)(row + x * 8);
                o[0] = (uint16_t)lrintf(clamp01(pr) * 65535), o[1] = (uint16_t)lrintf(clamp01(pg) * 65535);
                o[2] = (uint16_t)lrintf(clamp01(pb) * 65535), o[3] = (uint16_t)lrintf(clamp01(a) * 65535);
            } else if (format == kCIFormatAf) {
                ((float *)row)[x] = a;
            } else if (format == kCIFormatLf || format == kCIFormatRf) {
                ((float *)row)[x] = format == kCIFormatLf ? c[0] * a : pr;
            }
        }
    }
    ci_buf_free(b);
}

static size_t
bytes_per_pixel(CIFormat format)
{
    if (format == kCIFormatRGBAf)
        return 16;
    if (format == kCIFormatRGBAh || format == kCIFormatRGBA16)
        return 8;
    if (format == kCIFormatA8 || format == kCIFormatL8 || format == kCIFormatR8)
        return 1;
    if (format == kCIFormatAf || format == kCIFormatLf || format == kCIFormatRf)
        return 4;
    return 4;
}

static void
release_data(void *info, const void *data, size_t size)
{
    free((void *)data);
}

CGImageRef
ci_create_cgimage(CIImage *image, CGRect r, CIFormat format, CGColorSpaceRef space)
{
    r = CGRectIntegral(r);
    if (CGRectIsEmpty(r) || CGRectIsInfinite(r))
        return NULL;
    if (!format)
        format = kCIFormatRGBA8;
    size_t w = (size_t)r.size.width, h = (size_t)r.size.height, bpp = bytes_per_pixel(format);
    void *data = calloc(w * h, bpp);
    CGColorSpaceRef out = space ? CGColorSpaceRetain(space) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ci_write(image, data, w * bpp, r, format, out);
    CGBitmapInfo info;
    size_t bpc = 8;
    if (format == kCIFormatBGRA8)
        info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    else if (format == kCIFormatARGB8)
        info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big;
    else if (format == kCIFormatRGBAf)
        info = kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little, bpc = 32;
    else if (format == kCIFormatRGBAh)
        info = kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little, bpc = 16;
    else if (format == kCIFormatRGBA16)
        info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little, bpc = 16;
    else if (bpp == 1)
        info = (CGBitmapInfo)(format == kCIFormatA8 ? kCGImageAlphaOnly : kCGImageAlphaNone);
    else
        info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    if (bpp == 1 && format != kCIFormatA8 && CGColorSpaceGetModel(out) != kCGColorSpaceModelMonochrome) {
        CGColorSpaceRelease(out);
        out = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, data, w * h * bpp, release_data);
    CGImageRef result = CGImageCreate(w, h, bpc, bpp * 8, w * bpp, format == kCIFormatA8 ? NULL : out, info, provider, NULL,
                                      false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(out);
    return result;
}

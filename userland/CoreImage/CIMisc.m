/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The rest of CoreImage's classes. Kernels written in Core Image's kernel language or
 * Metal need a compiler Finch doesn't have yet, so making one fails as Apple's does for
 * a bad kernel (nil, and an error where the API has one); CIBlendKernel's built-in
 * kernels work. Detectors find no features yet. Samplers, filter shapes, image
 * accumulators and bitmap render destinations work.
 */
#import "CoreImage_Finch.h"

/* --- kernels --- */

@implementation CIKernel {
    @protected
    NSString *_name;
}

+ (NSArray<CIKernel *> *)kernelsWithString:(NSString *)string { return nil; }

+ (NSArray<CIKernel *> *)kernelsWithMetalString:(NSString *)source error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:@"CIKernel" code:1
                                 userInfo:@{NSLocalizedDescriptionKey : @"Metal kernels aren't available on Finch yet."}];
    return nil;
}

+ (instancetype)kernelWithString:(NSString *)string { return nil; }

+ (instancetype)kernelWithFunctionName:(NSString *)name fromMetalLibraryData:(NSData *)data error:(NSError **)error
{
    return [self kernelsWithMetalString:@"" error:error].firstObject;
}

+ (instancetype)kernelWithFunctionName:(NSString *)name fromMetalLibraryData:(NSData *)data
                     outputPixelFormat:(CIFormat)format error:(NSError **)error
{
    return [self kernelWithFunctionName:name fromMetalLibraryData:data error:error];
}

+ (NSArray<NSString *> *)kernelNamesFromMetalLibraryData:(NSData *)data { return @[]; }

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (NSString *)name { return _name ?: @""; }
- (void)setROISelector:(SEL)method {}

- (CIImage *)applyWithExtent:(CGRect)extent roiCallback:(CIKernelROICallback)callback arguments:(NSArray *)args
{
    return nil;
}

@end

@implementation CIColorKernel
- (CIImage *)applyWithExtent:(CGRect)extent arguments:(NSArray *)args { return nil; }
@end

@implementation CIWarpKernel
- (CIImage *)applyWithExtent:(CGRect)extent roiCallback:(CIKernelROICallback)callback inputImage:(CIImage *)image
                   arguments:(NSArray *)args
{
    return nil;
}
@end

@implementation CIBlendKernel

static CIBlendKernel *
named_blend(NSString *name)
{
    static NSMutableDictionary *kernels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kernels = [NSMutableDictionary new]; });
    @synchronized(kernels) {
        CIBlendKernel *k = kernels[name];
        if (!k) {
            k = [[CIBlendKernel new] autorelease];
            k->_name = [name copy];
            kernels[name] = k;
        }
        return k;
    }
}

- (CIImage *)applyWithForeground:(CIImage *)foreground background:(CIImage *)background
{
    return ci_blend_named(_name, foreground ?: [CIImage emptyImage], background ?: [CIImage emptyImage]);
}

- (CIImage *)applyWithForeground:(CIImage *)foreground background:(CIImage *)background colorSpace:(CGColorSpaceRef)colorSpace
{
    return [self applyWithForeground:foreground background:background];
}

#define BLEND(sel)                                                                                              \
    +(CIBlendKernel *)sel { return named_blend(@ #sel); }
BLEND(componentAdd) BLEND(componentMultiply) BLEND(componentMin) BLEND(componentMax) BLEND(clear) BLEND(source)
BLEND(destination) BLEND(sourceOver) BLEND(destinationOver) BLEND(sourceIn) BLEND(destinationIn) BLEND(sourceOut)
BLEND(destinationOut) BLEND(sourceAtop) BLEND(destinationAtop) BLEND(exclusiveOr) BLEND(multiply) BLEND(screen)
BLEND(overlay) BLEND(darken) BLEND(lighten) BLEND(colorDodge) BLEND(colorBurn) BLEND(hardLight) BLEND(softLight)
BLEND(difference) BLEND(exclusion) BLEND(hue) BLEND(saturation) BLEND(color) BLEND(luminosity) BLEND(subtract)
BLEND(divide) BLEND(linearBurn) BLEND(linearDodge) BLEND(vividLight) BLEND(linearLight) BLEND(pinLight)
BLEND(hardMix) BLEND(darkerColor) BLEND(lighterColor)

@end

@implementation CIImageProcessorKernel

+ (CIImage *)applyWithExtent:(CGRect)extent inputs:(NSArray<CIImage *> *)inputs arguments:(NSDictionary *)args error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:@"CIImageProcessorKernel" code:1 userInfo:nil];
    return nil;
}

+ (BOOL)processWithInputs:(NSArray *)inputs arguments:(NSDictionary *)arguments output:(id)output error:(NSError **)error
{
    return NO;
}

+ (CGRect)roiForInput:(int)input arguments:(NSDictionary *)arguments outputRect:(CGRect)outputRect { return outputRect; }
+ (CIFormat)formatForInputAtIndex:(int)input { return kCIFormatRGBAh; }
+ (CIFormat)outputFormat { return kCIFormatRGBAh; }
+ (BOOL)synchronizeInputs { return YES; }
+ (BOOL)outputIsOpaque { return NO; }

@end

/* --- samplers and shapes --- */

@implementation CISampler {
    CIImage *_image;
    NSDictionary *_options;
}

+ (instancetype)samplerWithImage:(CIImage *)im { return [[[self alloc] initWithImage:im] autorelease]; }
+ (instancetype)samplerWithImage:(CIImage *)im options:(NSDictionary *)dict
{
    return [[[self alloc] initWithImage:im options:dict] autorelease];
}
+ (instancetype)samplerWithImage:(CIImage *)im keysAndValues:(id)key0, ...
{
    return [[[self alloc] initWithImage:im] autorelease];
}

- (instancetype)initWithImage:(CIImage *)im { return [self initWithImage:im options:nil]; }
- (instancetype)initWithImage:(CIImage *)im keysAndValues:(id)key0, ... { return [self initWithImage:im options:nil]; }

- (instancetype)initWithImage:(CIImage *)im options:(NSDictionary *)dict
{
    if ((self = [super init])) {
        _image = [im retain];
        _options = [dict copy];
    }
    return self;
}

- (void)dealloc
{
    [_image release];
    [_options release];
    [super dealloc];
}

- (CIFilterShape *)definition { return [CIFilterShape shapeWithRect:_image.extent]; }
- (CGRect)extent { return _image.extent; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

@implementation CIFilterShape {
    CGRect _extent;
}

+ (instancetype)shapeWithRect:(CGRect)r { return [[[self alloc] initWithRect:r] autorelease]; }

- (instancetype)initWithRect:(CGRect)r
{
    if ((self = [super init]))
        _extent = r;
    return self;
}

- (CGRect)extent { return _extent; }
- (CIFilterShape *)transformBy:(CGAffineTransform)m interior:(BOOL)flag
{
    return [CIFilterShape shapeWithRect:CGRectApplyAffineTransform(_extent, m)];
}
- (CIFilterShape *)insetByX:(int)dx Y:(int)dy { return [CIFilterShape shapeWithRect:CGRectInset(_extent, dx, dy)]; }
- (CIFilterShape *)unionWith:(CIFilterShape *)s2 { return [CIFilterShape shapeWithRect:CGRectUnion(_extent, s2.extent)]; }
- (CIFilterShape *)unionWithRect:(CGRect)r { return [CIFilterShape shapeWithRect:CGRectUnion(_extent, r)]; }
- (CIFilterShape *)intersectWith:(CIFilterShape *)s2 { return [CIFilterShape shapeWithRect:CGRectIntersection(_extent, s2.extent)]; }
- (CIFilterShape *)intersectWithRect:(CGRect)r { return [CIFilterShape shapeWithRect:CGRectIntersection(_extent, r)]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

@end

/* --- an accumulator: an image built up by successive draws --- */

@implementation CIImageAccumulator {
    CGRect _extent;
    CIFormat _format;
    CIBuf _buf;
}

+ (instancetype)imageAccumulatorWithExtent:(CGRect)extent format:(CIFormat)format
{
    return [[[self alloc] initWithExtent:extent format:format] autorelease];
}

+ (instancetype)imageAccumulatorWithExtent:(CGRect)extent format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
{
    return [[[self alloc] initWithExtent:extent format:format colorSpace:colorSpace] autorelease];
}

- (instancetype)initWithExtent:(CGRect)extent format:(CIFormat)format
{
    if ((self = [super init])) {
        _extent = CGRectIntegral(extent);
        _format = format;
        _buf = ci_buf_alloc(_extent);
    }
    return self;
}

- (instancetype)initWithExtent:(CGRect)extent format:(CIFormat)format colorSpace:(CGColorSpaceRef)colorSpace
{
    return [self initWithExtent:extent format:format];
}

- (void)dealloc
{
    ci_buf_free(_buf);
    [super dealloc];
}

- (CGRect)extent { return _extent; }
- (CIFormat)format { return _format; }

- (CIImage *)image
{
    CIBuf snapshot = ci_buf_alloc(_extent);
    memcpy(snapshot.px, _buf.px, _buf.w * _buf.h * 4 * sizeof(float));
    NSData *keep = [NSData dataWithBytesNoCopy:snapshot.px length:snapshot.w * snapshot.h * 4 * sizeof(float) freeWhenDone:YES];
    CGRect extent = _extent;
    size_t w = snapshot.w;
    return ci_image(extent, ^CIBuf(CGRect r) {
      CIBuf out = ci_buf_alloc(r);
      const float *px = keep.bytes;
      for (size_t y = 0; y < out.h; y++)
          memcpy(ci_buf_at(out, 0, y), px + ((size_t)(r.origin.y - extent.origin.y + y) * w + (size_t)(r.origin.x - extent.origin.x)) * 4,
                 out.w * 4 * sizeof(float));
      return out;
    });
}

- (void)setImage:(CIImage *)image dirtyRect:(CGRect)dirtyRect
{
    CGRect r = CGRectIntegral(CGRectIntersection(dirtyRect, _extent));
    if (CGRectIsEmpty(r))
        return;
    CIBuf part = ci_render(image, r);
    for (size_t y = 0; y < part.h; y++)
        memcpy(ci_buf_at(_buf, (size_t)(r.origin.x - _extent.origin.x), (size_t)(r.origin.y - _extent.origin.y) + y),
               ci_buf_at(part, 0, y), part.w * 4 * sizeof(float));
    ci_buf_free(part);
}

- (void)setImage:(CIImage *)image { [self setImage:image dirtyRect:_extent]; }

- (void)clear { memset(_buf.px, 0, _buf.w * _buf.h * 4 * sizeof(float)); }

@end

/* --- render destinations and tasks --- */

@implementation CIRenderDestination {
    void *_data;
    size_t _width, _height, _rowBytes;
    CIFormat _format;
    CGColorSpaceRef _space;
    BOOL _flipped, _dithered, _clamped, _blendsInDestinationColorSpace;
    CIRenderDestinationAlphaMode _alphaMode;
    CIBlendKernel *_blendKernel;
}

- (instancetype)initWithBitmapData:(void *)data width:(NSUInteger)width height:(NSUInteger)height bytesPerRow:(NSUInteger)bytesPerRow
                            format:(CIFormat)format
{
    if ((self = [super init])) {
        _data = data;
        _width = width;
        _height = height;
        _rowBytes = bytesPerRow;
        _format = format;
        _space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _alphaMode = CIRenderDestinationAlphaPremultiplied;
        _clamped = YES;
    }
    return self;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer { [self release]; return nil; }
- (instancetype)initWithIOSurface:(IOSurface *)surface { [self release]; return nil; }
- (instancetype)initWithMTLTexture:(id)texture commandBuffer:(id)commandBuffer { [self release]; return nil; }
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height pixelFormat:(MTLPixelFormat)pixelFormat
                commandBuffer:(id)commandBuffer mtlTextureProvider:(id<MTLTexture> (^)(void))block
{
    [self release];
    return nil;
}
- (instancetype)initWithGLTexture:(unsigned int)texture target:(unsigned int)target width:(NSUInteger)width height:(NSUInteger)height
{
    [self release];
    return nil;
}

- (void)dealloc
{
    CGColorSpaceRelease(_space);
    [_blendKernel release];
    [super dealloc];
}

- (NSUInteger)width { return _width; }
- (NSUInteger)height { return _height; }
- (CIRenderDestinationAlphaMode)alphaMode { return _alphaMode; }
- (void)setAlphaMode:(CIRenderDestinationAlphaMode)mode { _alphaMode = mode; }
- (BOOL)isFlipped { return _flipped; }
- (void)setFlipped:(BOOL)flipped { _flipped = flipped; }
- (BOOL)isDithered { return _dithered; }
- (void)setDithered:(BOOL)dithered { _dithered = dithered; }
- (BOOL)isClamped { return _clamped; }
- (void)setClamped:(BOOL)clamped { _clamped = clamped; }
- (CGColorSpaceRef)colorSpace { return _space; }
- (void)setColorSpace:(CGColorSpaceRef)space
{
    CGColorSpaceRetain(space);
    CGColorSpaceRelease(_space);
    _space = space;
}
- (CIBlendKernel *)blendKernel { return _blendKernel; }
- (void)setBlendKernel:(CIBlendKernel *)k
{
    [_blendKernel autorelease];
    _blendKernel = [k retain];
}
- (BOOL)blendsInDestinationColorSpace { return _blendsInDestinationColorSpace; }
- (void)setBlendsInDestinationColorSpace:(BOOL)b { _blendsInDestinationColorSpace = b; }

- (void)_finchRender:(CIImage *)image from:(CGRect)fromRect at:(CGPoint)atPoint
{
    if (!_data)
        return;
    CGRect r = CGRectMake(fromRect.origin.x, fromRect.origin.y, _width, _height);
    (void)atPoint;
    if (!_flipped) {
        ci_write(image, _data, _rowBytes, r, _format, _space);
        return;
    }
    /* flipped: the first row in memory is the bottom one */
    size_t n = _rowBytes * _height;
    uint8_t *tmp = malloc(n);
    ci_write(image, tmp, _rowBytes, r, _format, _space);
    for (size_t y = 0; y < _height; y++)
        memcpy((uint8_t *)_data + y * _rowBytes, tmp + (_height - 1 - y) * _rowBytes, _rowBytes);
    free(tmp);
}

@end

@implementation CIRenderInfo
- (NSTimeInterval)kernelExecutionTime { return 0; }
- (NSTimeInterval)kernelCompileTime { return 0; }
- (NSInteger)passCount { return 1; }
- (NSInteger)pixelsProcessed { return 0; }
@end

@implementation CIRenderTask
- (CIRenderInfo *)waitUntilCompletedAndReturnError:(NSError **)error { return [[CIRenderInfo new] autorelease]; }
@end

@implementation CIContext (CIRenderDestination)

- (CIRenderTask *)startTaskToRender:(CIImage *)image fromRect:(CGRect)fromRect toDestination:(CIRenderDestination *)destination
                            atPoint:(CGPoint)atPoint error:(NSError **)error
{
    [destination _finchRender:image from:fromRect at:atPoint];
    return [[CIRenderTask new] autorelease];
}

- (CIRenderTask *)startTaskToRender:(CIImage *)image toDestination:(CIRenderDestination *)destination error:(NSError **)error
{
    return [self startTaskToRender:image fromRect:CGRectMake(0, 0, destination.width, destination.height)
                     toDestination:destination atPoint:CGPointZero error:error];
}

- (BOOL)prepareRender:(CIImage *)image fromRect:(CGRect)fromRect toDestination:(CIRenderDestination *)destination
              atPoint:(CGPoint)atPoint error:(NSError **)error
{
    return YES;
}

- (CIRenderTask *)startTaskToClear:(CIRenderDestination *)destination error:(NSError **)error
{
    [destination _finchRender:[CIImage emptyImage] from:CGRectMake(0, 0, destination.width, destination.height) at:CGPointZero];
    return [[CIRenderTask new] autorelease];
}

@end

/* --- detectors and features --- */

@implementation CIDetector {
    NSString *_type;
}

+ (CIDetector *)detectorOfType:(NSString *)type context:(CIContext *)context options:(NSDictionary<NSString *, id> *)options
{
    NSArray *known = @[ CIDetectorTypeFace, CIDetectorTypeRectangle, CIDetectorTypeQRCode, CIDetectorTypeText ];
    if (![known containsObject:type])
        return nil;
    CIDetector *d = [[self new] autorelease];
    d->_type = [type copy];
    return d;
}

- (void)dealloc
{
    [_type release];
    [super dealloc];
}

/* No detection models on Finch yet: nothing is found. */
- (NSArray<CIFeature *> *)featuresInImage:(CIImage *)image { return @[]; }
- (NSArray<CIFeature *> *)featuresInImage:(CIImage *)image options:(NSDictionary *)options { return @[]; }

@end

@implementation CIFeature
- (NSString *)type { return @""; }
- (CGRect)bounds { return CGRectZero; }
@end

@implementation CIFaceFeature
- (NSString *)type { return CIFeatureTypeFace; }
@end

@implementation CIRectangleFeature
- (NSString *)type { return CIFeatureTypeRectangle; }
@end

@implementation CIQRCodeFeature
+ (BOOL)supportsSecureCoding { return YES; }
- (NSString *)type { return CIFeatureTypeQRCode; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation CITextFeature
- (NSString *)type { return CIFeatureTypeText; }
@end

/* --- barcode descriptors --- */

@implementation CIBarcodeDescriptor
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation CIQRCodeDescriptor
@end
@implementation CIAztecCodeDescriptor
@end
@implementation CIPDF417CodeDescriptor
@end
@implementation CIDataMatrixCodeDescriptor
@end

/* --- plug-ins: Image Units are executable code Finch doesn't load yet --- */

@implementation CIPlugIn
+ (void)loadAllPlugIns {}
+ (void)loadNonExecutablePlugIns {}
+ (void)loadNonExecutablePlugIn:(NSURL *)url {}
+ (void)loadPlugIn:(NSURL *)url allowNonExecutable:(BOOL)allowNonExecutable {}
+ (void)loadPlugIn:(NSURL *)url allowExecutableCode:(BOOL)allowExecutableCode {}
@end

/* --- filter generators (chains of filters saved as one) --- */

@implementation CIFilterGenerator {
    NSMutableArray *_connections;
    NSMutableDictionary *_exported;
    NSDictionary *_classAttributes;
}

+ (CIFilterGenerator *)filterGenerator { return [[self new] autorelease]; }
+ (CIFilterGenerator *)filterGeneratorWithContentsOfURL:(NSURL *)aURL { return nil; }
- (instancetype)initWithContentsOfURL:(NSURL *)aURL { [self release]; return nil; }

- (instancetype)init
{
    if ((self = [super init])) {
        _connections = [NSMutableArray new];
        _exported = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_connections release];
    [_exported release];
    [_classAttributes release];
    [super dealloc];
}

- (void)connectObject:(id)sourceObject withKey:(NSString *)sourceKey toObject:(id)targetObject withKey:(NSString *)targetKey
{
    [_connections addObject:@[ sourceObject ?: [NSNull null], sourceKey ?: @"", targetObject ?: [NSNull null], targetKey ?: @"" ]];
}

- (void)disconnectObject:(id)sourceObject withKey:(NSString *)key toObject:(id)targetObject withKey:(NSString *)targetKey {}
- (void)exportKey:(NSString *)key fromObject:(id)targetObject withName:(NSString *)exportedKeyName
{
    _exported[exportedKeyName ?: key] = @[ targetObject, key ];
}
- (void)removeExportedKey:(NSString *)exportedKeyName { [_exported removeObjectForKey:exportedKeyName]; }
- (NSDictionary *)exportedKeys { return _exported; }
- (void)setAttributes:(NSDictionary *)attributes forExportedKey:(NSString *)key {}
- (NSDictionary *)classAttributes { return _classAttributes; }
- (void)setClassAttributes:(NSDictionary *)attributes
{
    [_classAttributes autorelease];
    _classAttributes = [attributes copy];
}
- (CIFilter *)filter { return nil; }
- (void)registerFilterName:(NSString *)name {}
- (BOOL)writeToURL:(NSURL *)aURL atomically:(BOOL)flag { return NO; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }

@end

/* --- RAW: no camera RAW decoders on Finch yet --- */

@implementation CIRAWFilter
+ (NSArray<NSString *> *)supportedCameraModels { return @[]; }
+ (instancetype)filterWithImageURL:(NSURL *)url { return nil; }
+ (instancetype)filterWithImageData:(NSData *)data identifierHint:(NSString *)identifierHint { return nil; }
+ (instancetype)filterWithCVPixelBuffer:(CVPixelBufferRef)buffer properties:(NSDictionary *)properties { return nil; }
@end

@interface CIDualRedEyeRepairSession : NSObject
@end
@implementation CIDualRedEyeRepairSession
@end

/* Private context classes Apple's CoreImage also exports. */
@interface CIBitmapContext : CIContext
@end
@implementation CIBitmapContext
@end
@interface CICGContext : CIContext
@end
@implementation CICGContext
@end
@interface CIOpenGLContext : CIContext
@end
@implementation CIOpenGLContext
@end
@interface CIContextCache : NSObject
@end
@implementation CIContextCache
@end
@interface CICGSFilter : NSObject
@end
@implementation CICGSFilter
@end
@interface CIFilterGeneratorConnection : NSObject
@end
@implementation CIFilterGeneratorConnection
@end

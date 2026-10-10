/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The descriptor methods that aren't properties: the texture descriptor's factories,
 * resets back to the defaults, sample positions, function constant values, the
 * rasterization rate descriptors, function stitching nodes, and the capture manager
 * (which can't capture: there's no device).
 */
#import "Metal_Finch.h"
#import <objc/runtime.h>

/* (Apple's headers name designated initializers these categories add to) */
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#pragma clang diagnostic ignored "-Wnonnull"

/* Every property back to what a new descriptor has. */
static void
reset(id object)
{
    id fresh = [[[object class] alloc] init];
    for (Class c = [object class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            char *ivar = property_copyAttributeValue(props[i], "V");
            if (ivar) {
                NSString *k = @(property_getName(props[i]));
                [object setValue:[fresh valueForKey:k] forKey:k];
                free(ivar);
            }
        }
        free(props);
    }
}

#define RESETS(cls) \
    @implementation cls (FinchReset) \
    -(void)reset { reset(self); } \
    @end
RESETS(MTLRenderPipelineDescriptor)
RESETS(MTLComputePipelineDescriptor)
RESETS(MTLTileRenderPipelineDescriptor)
RESETS(MTLMeshRenderPipelineDescriptor)
RESETS(MTLVertexDescriptor)
RESETS(MTLStageInputOutputDescriptor)
RESETS(MTLFunctionConstantValues)
RESETS(MTL4ComputePipelineDescriptor)
RESETS(MTL4MeshRenderPipelineDescriptor)
RESETS(MTL4RenderPipelineColorAttachmentDescriptor)
RESETS(MTL4RenderPipelineBinaryFunctionsDescriptor)
RESETS(MTL4RenderPipelineDescriptor)
RESETS(MTL4TileRenderPipelineDescriptor)

@implementation MTLTextureDescriptor (FinchFactories)

static NSUInteger
mip_levels(NSUInteger w, NSUInteger h)
{
    NSUInteger m = MAX(w, h), levels = 1;
    while (m > 1) {
        m >>= 1;
        levels++;
    }
    return levels;
}

+ (MTLTextureDescriptor *)texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat width:(NSUInteger)width
                                                       height:(NSUInteger)height mipmapped:(BOOL)mipmapped
{
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    d.textureType = MTLTextureType2D;
    d.pixelFormat = pixelFormat;
    d.width = width;
    d.height = height;
    d.mipmapLevelCount = mipmapped ? mip_levels(width, height) : 1;
    return d;
}

+ (MTLTextureDescriptor *)textureCubeDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat size:(NSUInteger)size
                                                      mipmapped:(BOOL)mipmapped
{
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    d.textureType = MTLTextureTypeCube;
    d.pixelFormat = pixelFormat;
    d.width = size;
    d.height = size;
    d.mipmapLevelCount = mipmapped ? mip_levels(size, size) : 1;
    return d;
}

+ (MTLTextureDescriptor *)textureBufferDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat width:(NSUInteger)width
                                                  resourceOptions:(MTLResourceOptions)resourceOptions
                                                            usage:(MTLTextureUsage)usage
{
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    d.textureType = MTLTextureTypeTextureBuffer;
    d.pixelFormat = pixelFormat;
    d.width = width;
    d.resourceOptions = resourceOptions;
    d.cpuCacheMode = (MTLCPUCacheMode)(resourceOptions & 0xF);
    d.storageMode = (MTLStorageMode)((resourceOptions >> MTLResourceStorageModeShift) & 0xF);
    d.hazardTrackingMode = (MTLHazardTrackingMode)((resourceOptions >> MTLResourceHazardTrackingModeShift) & 0x3);
    d.usage = usage;
    return d;
}

@end

/* Sample positions, kept with the descriptor. */
static const void *kPositions = &kPositions;

static void
set_positions(id object, const MTLSamplePosition *positions, NSUInteger count)
{
    objc_setAssociatedObject(object, kPositions,
                             positions && count ? [NSData dataWithBytes:positions length:count * sizeof *positions] : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSUInteger
get_positions(id object, MTLSamplePosition *positions, NSUInteger count)
{
    NSData *d = objc_getAssociatedObject(object, kPositions);
    NSUInteger have = d.length / sizeof(MTLSamplePosition);
    if (positions)
        memcpy(positions, d.bytes, MIN(count, have) * sizeof *positions);
    return have;
}

@implementation MTLRenderPassDescriptor (FinchSamplePositions)
- (void)setSamplePositions:(const MTLSamplePosition *)positions count:(NSUInteger)count { set_positions(self, positions, count); }
- (NSUInteger)getSamplePositions:(MTLSamplePosition *)positions count:(NSUInteger)count { return get_positions(self, positions, count); }
@end

@implementation MTL4RenderPassDescriptor (FinchSamplePositions)
- (void)setSamplePositions:(const MTLSamplePosition *)positions count:(NSUInteger)count { set_positions(self, positions, count); }
- (NSUInteger)getSamplePositions:(MTLSamplePosition *)positions count:(NSUInteger)count { return get_positions(self, positions, count); }
@end

/* --- function constant values: by index and by name, each its type and bytes --- */

static size_t
data_type_size(MTLDataType t)
{
    switch (t) {
    case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
    case MTLDataTypeBool2: case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort:
    case MTLDataTypeHalf: return 2;
    case MTLDataTypeBool3: case MTLDataTypeChar3: case MTLDataTypeUChar3: return 3;
    case MTLDataTypeBool4: case MTLDataTypeChar4: case MTLDataTypeUChar4: case MTLDataTypeShort2: case MTLDataTypeUShort2:
    case MTLDataTypeHalf2: case MTLDataTypeInt: case MTLDataTypeUInt: case MTLDataTypeFloat: return 4;
    case MTLDataTypeShort3: case MTLDataTypeUShort3: case MTLDataTypeHalf3: return 6;
    case MTLDataTypeShort4: case MTLDataTypeUShort4: case MTLDataTypeHalf4: case MTLDataTypeInt2: case MTLDataTypeUInt2:
    case MTLDataTypeFloat2: case MTLDataTypeLong: case MTLDataTypeULong: return 8;
    case MTLDataTypeInt3: case MTLDataTypeUInt3: case MTLDataTypeFloat3: return 12;
    case MTLDataTypeInt4: case MTLDataTypeUInt4: case MTLDataTypeFloat4: case MTLDataTypeLong2: case MTLDataTypeULong2: return 16;
    default: return 0;
    }
}

static const void *kConstants = &kConstants;

static NSMutableDictionary *
constants(id object)
{
    NSMutableDictionary *d = objc_getAssociatedObject(object, kConstants);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(object, kConstants, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return d;
}

@implementation MTLFunctionConstantValues (FinchValues)
- (void)setConstantValue:(const void *)value type:(MTLDataType)type atIndex:(NSUInteger)index
{
    constants(self)[@(index)] = @[ @(type), [NSData dataWithBytes:value length:data_type_size(type)] ];
}
- (void)setConstantValues:(const void *)values type:(MTLDataType)type withRange:(NSRange)range
{
    size_t size = data_type_size(type);
    for (NSUInteger i = 0; i < range.length; i++)
        [self setConstantValue:(const uint8_t *)values + i * size type:type atIndex:range.location + i];
}
- (void)setConstantValue:(const void *)value type:(MTLDataType)type withName:(NSString *)name
{
    constants(self)[name] = @[ @(type), [NSData dataWithBytes:value length:data_type_size(type)] ];
}
@end

/* --- rasterization rates --- */

@implementation MTLRasterizationRateLayerDescriptor (FinchInit)
- (instancetype)initWithSampleCount:(MTLSize)sampleCount
{
    return [self initWithSampleCount:sampleCount horizontal:NULL vertical:NULL];
}
- (instancetype)initWithSampleCount:(MTLSize)sampleCount horizontal:(const float *)horizontal vertical:(const float *)vertical
{
    if (!(self = [super init]))
        return nil;
    [self setValue:[NSValue valueWithBytes:&sampleCount objCType:@encode(MTLSize)] forKey:@"sampleCount"];
    for (NSUInteger i = 0; i < sampleCount.width; i++)
        self.horizontal[i] = @(horizontal ? horizontal[i] : 1.0f);
    for (NSUInteger i = 0; i < sampleCount.height; i++)
        self.vertical[i] = @(vertical ? vertical[i] : 1.0f);
    return self;
}
@end

@implementation MTLRasterizationRateMapDescriptor (FinchFactories)
+ (MTLRasterizationRateMapDescriptor *)rasterizationRateMapDescriptorWithScreenSize:(MTLSize)screenSize
{
    MTLRasterizationRateMapDescriptor *d = [[self alloc] init];
    d.screenSize = screenSize;
    return d;
}
+ (MTLRasterizationRateMapDescriptor *)rasterizationRateMapDescriptorWithScreenSize:(MTLSize)screenSize
                                                                               layer:(MTLRasterizationRateLayerDescriptor *)layer
{
    MTLRasterizationRateMapDescriptor *d = [self rasterizationRateMapDescriptorWithScreenSize:screenSize];
    [d setLayer:layer atIndex:0];
    return d;
}
+ (MTLRasterizationRateMapDescriptor *)rasterizationRateMapDescriptorWithScreenSize:(MTLSize)screenSize layerCount:(NSUInteger)layerCount
                                                                              layers:(MTLRasterizationRateLayerDescriptor *const *)layers
{
    MTLRasterizationRateMapDescriptor *d = [self rasterizationRateMapDescriptorWithScreenSize:screenSize];
    for (NSUInteger i = 0; i < layerCount; i++)
        [d setLayer:layers[i] atIndex:i];
    return d;
}
- (NSUInteger)layerCount { return FinchMTLArrayCount(self.layers); }
- (MTLRasterizationRateLayerDescriptor *)layerAtIndex:(NSUInteger)layerIndex
{
    return layerIndex < self.layerCount ? self.layers[layerIndex] : nil;
}
- (void)setLayer:(MTLRasterizationRateLayerDescriptor *)layer atIndex:(NSUInteger)layerIndex { self.layers[layerIndex] = layer; }
@end

/* --- function stitching graphs (values) --- */

@implementation MTLFunctionStitchingInputNode (FinchInit)
- (instancetype)initWithArgumentIndex:(NSUInteger)argument
{
    if ((self = [self init]))
        self.argumentIndex = argument;
    return self;
}
@end

@implementation MTLFunctionStitchingFunctionNode (FinchInit)
- (instancetype)initWithName:(NSString *)name arguments:(NSArray *)arguments controlDependencies:(NSArray *)controlDependencies
{
    if ((self = [self init])) {
        self.name = name;
        self.arguments = arguments;
        self.controlDependencies = controlDependencies;
    }
    return self;
}
@end

@implementation MTLFunctionStitchingGraph (FinchInit)
- (instancetype)initWithFunctionName:(NSString *)functionName nodes:(NSArray *)nodes outputNode:(MTLFunctionStitchingFunctionNode *)outputNode
                          attributes:(NSArray *)attributes
{
    if ((self = [self init])) {
        self.functionName = functionName;
        self.nodes = nodes;
        self.outputNode = outputNode;
        self.attributes = attributes;
    }
    return self;
}
@end

@implementation MTLSharedEventListener (FinchInit)
- (instancetype)initWithDispatchQueue:(dispatch_queue_t)dispatchQueue
{
    if ((self = [self init]))
        [self setValue:dispatchQueue forKey:@"dispatchQueue"];
    return self;
}
@end

/* --- capture: nothing to capture without a device --- */

@implementation MTLCaptureManager (FinchCapture)

+ (MTLCaptureManager *)sharedCaptureManager
{
    static MTLCaptureManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[MTLCaptureManager alloc] init];
    });
    return shared;
}

- (id<MTLCaptureScope>)newCaptureScopeWithDevice:(id<MTLDevice>)device { return nil; }
- (id<MTLCaptureScope>)newCaptureScopeWithCommandQueue:(id<MTLCommandQueue>)commandQueue { return nil; }
- (id<MTLCaptureScope>)newCaptureScopeWithMTL4CommandQueue:(id<MTL4CommandQueue>)commandQueue { return nil; }
- (BOOL)supportsDestination:(MTLCaptureDestination)destination { return NO; }

- (BOOL)startCaptureWithDescriptor:(MTLCaptureDescriptor *)descriptor error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:MTLCaptureErrorDomain code:MTLCaptureErrorNotSupported
                                 userInfo:@{NSLocalizedDescriptionKey : @"Capturing is not supported."}];
    return NO;
}

- (void)startCaptureWithDevice:(id<MTLDevice>)device {}
- (void)startCaptureWithCommandQueue:(id<MTLCommandQueue>)commandQueue {}
- (void)startCaptureWithScope:(id<MTLCaptureScope>)captureScope {}
- (void)stopCapture {}

@end

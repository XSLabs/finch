/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Metal's descriptor and value classes, with the defaults Apple's have (generated from
   Apple's classes' declared properties and their values, taken as data). */
#import "Metal_Finch.h"

@implementation MTL4AccelerationStructureBoundingBoxGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(24) forKey:@"boundingBoxStride"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureCurveGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"controlPointFormat"];
    [self setValue:@(28) forKey:@"radiusFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureMotionBoundingBoxGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(24) forKey:@"boundingBoxStride"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureMotionCurveGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"controlPointFormat"];
    [self setValue:@(28) forKey:@"radiusFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureMotionTriangleGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"vertexFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4AccelerationStructureTriangleGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"vertexFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4ArgumentTableDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4BinaryFunctionDescriptor ()
@property (nonatomic, copy) MTL4PipelineOptions *pipelineOptions;
@end
@implementation MTL4BinaryFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4CommandAllocatorDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4CommandBufferOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4CommandQueueDescriptor ()
@property (nonatomic) BOOL lockParameterBufferSizeToMax;
@property (nonatomic) BOOL supportMTLEvent;
@end
@implementation MTL4CommandQueueDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"supportMTLEvent"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4CommitOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4CompilerDescriptor ()
@property (nonatomic) BOOL shouldMaximizeConcurrentCompilation;
@end
@implementation MTL4CompilerDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4CompilerTaskOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4ComputePipelineDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"staticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4CounterHeapDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4FunctionDescriptor ()
@property (nonatomic) MTL4PipelineOptions *pipelineOptions;
@end
@implementation MTL4FunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4IndirectInstanceAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(3) forKey:@"instanceDescriptorType"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4InstanceAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(3) forKey:@"instanceDescriptorType"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4LibraryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4LibraryFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4MachineLearningPipelineDescriptor ()
@property (nonatomic) NSInteger deviceSelection;
@end
@implementation MTL4MachineLearningPipelineDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4MachineLearningPipelineReflection
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4MeshRenderPipelineDescriptor ()
@property (nonatomic) NSUInteger colorSampleCount;
@end
@implementation MTL4MeshRenderPipelineDescriptor
- (void)setObjectStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor*)value { _objectStaticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (void)setMeshStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor*)value { _meshStaticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (void)setFragmentStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor*)value { _fragmentStaticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    [self setValue:@(1) forKey:@"rasterizationEnabled"];
    [self setValue:@(1) forKey:@"maxVertexAmplificationCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTL4RenderPipelineColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"objectStaticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    FinchMTLSetNew(self, @"meshStaticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    FinchMTLSetNew(self, @"fragmentStaticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4PipelineDataSetSerializerDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4PipelineDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTL4PipelineDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4PipelineOptions ()
@property (nonatomic) NSDictionary *pluginData;
@property (nonatomic, readonly) id shaderValidationConfig;
@property (nonatomic) BOOL enablePerformanceStatistics;
@property (nonatomic) BOOL enablePostVertexDump;
@property (nonatomic) BOOL enablePostMeshDump;
@property (nonatomic) BOOL enableAccelerationStructureViewerInstrumentation;
@property (nonatomic) BOOL enableResourcePatchingInstrumentation;
@property (nonatomic) BOOL enableResourceUsageInstrumentation;
@property (nonatomic) NSUInteger maxNumRegisters;
@property (nonatomic) NSUInteger postVertexDumpBufferIndex;
@end
@implementation MTL4PipelineOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"shaderValidationConfig", @"MTLShaderValidationConfiguration");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4PipelineStageDynamicLinkingDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"maxCallStackDepth"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4PrimitiveAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"motionEndTime"];
    [self setValue:@(1) forKey:@"motionKeyframeCount"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4RenderPassDescriptor
- (void)setDepthAttachment:(MTLRenderPassDepthAttachmentDescriptor *)value { _depthAttachment = value ?: [[MTLRenderPassDepthAttachmentDescriptor alloc] init]; }
- (void)setStencilAttachment:(MTLRenderPassStencilAttachmentDescriptor *)value { _stencilAttachment = value ?: [[MTLRenderPassStencilAttachmentDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"colorAttachments", @"MTLRenderPassColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"depthAttachment", @"MTLRenderPassDepthAttachmentDescriptor");
    FinchMTLSetNew(self, @"stencilAttachment", @"MTLRenderPassStencilAttachmentDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4RenderPipelineBinaryFunctionsDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4RenderPipelineColorAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"sourceRGBBlendFactor"];
    [self setValue:@(1) forKey:@"sourceAlphaBlendFactor"];
    [self setValue:@(15) forKey:@"writeMask"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4RenderPipelineColorAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTL4RenderPipelineColorAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTL4RenderPipelineDescriptor ()
@property (nonatomic) NSUInteger colorSampleCount;
@end
@implementation MTL4RenderPipelineDescriptor
- (void)setVertexStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor *)value { _vertexStaticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (void)setFragmentStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor *)value { _fragmentStaticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"vertexDescriptor", @"MTLVertexDescriptor");
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    [self setValue:@(1) forKey:@"rasterizationEnabled"];
    [self setValue:@(1) forKey:@"maxVertexAmplificationCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTL4RenderPipelineColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"vertexStaticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    FinchMTLSetNew(self, @"fragmentStaticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4RenderPipelineDynamicLinkingDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"vertexLinkingDescriptor", @"MTL4PipelineStageDynamicLinkingDescriptor");
    FinchMTLSetNew(self, @"fragmentLinkingDescriptor", @"MTL4PipelineStageDynamicLinkingDescriptor");
    FinchMTLSetNew(self, @"tileLinkingDescriptor", @"MTL4PipelineStageDynamicLinkingDescriptor");
    FinchMTLSetNew(self, @"objectLinkingDescriptor", @"MTL4PipelineStageDynamicLinkingDescriptor");
    FinchMTLSetNew(self, @"meshLinkingDescriptor", @"MTL4PipelineStageDynamicLinkingDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4SpecializedFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4StaticLinkingDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4StitchedFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTL4TileRenderPipelineDescriptor
- (void)setStaticLinkingDescriptor:(MTL4StaticLinkingDescriptor*)value { _staticLinkingDescriptor = value ?: [[MTL4StaticLinkingDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTLTileRenderPipelineColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"staticLinkingDescriptor", @"MTL4StaticLinkingDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureBoundingBoxGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(24) forKey:@"boundingBoxStride"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLAccelerationStructureCurveGeometryDescriptor ()
@property (nonatomic) NSInteger endCaps;
@end
@implementation MTLAccelerationStructureCurveGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"controlPointFormat"];
    [self setValue:@(28) forKey:@"radiusFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureMotionBoundingBoxGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"boundingBoxBuffers"];
    [self setValue:@(24) forKey:@"boundingBoxStride"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLAccelerationStructureMotionCurveGeometryDescriptor ()
@property (nonatomic) NSInteger endCaps;
@end
@implementation MTLAccelerationStructureMotionCurveGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"controlPointBuffers"];
    [self setValue:@(30) forKey:@"controlPointFormat"];
    [self setValue:@[] forKey:@"radiusBuffers"];
    [self setValue:@(28) forKey:@"radiusFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureMotionTriangleGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"vertexBuffers"];
    [self setValue:@(30) forKey:@"vertexFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructurePassDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"sampleBufferAttachments", @"MTLAccelerationStructurePassSampleBufferAttachmentDescriptorArray");
    return self;
}
+ (instancetype)accelerationStructurePassDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructurePassSampleBufferAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfEncoderSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfEncoderSampleIndex"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructurePassSampleBufferAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLAccelerationStructurePassSampleBufferAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAccelerationStructureTriangleGeometryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(30) forKey:@"vertexFormat"];
    [self setValue:@(1) forKey:@"indexType"];
    [self setValue:@(1) forKey:@"allowDuplicateIntersectionFunctionInvocation"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLArchitecture ()
@property (nonatomic, readonly) NSString *revision;
@property (nonatomic, readonly) int cpuType;
@property (nonatomic, readonly) int cpuSubtype;
@end
@implementation MTLArchitecture
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLArgument
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLArgumentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(2) forKey:@"textureType"];
    return self;
}
+ (instancetype)argumentDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLArrayType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAttribute
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAttributeDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLAttributeDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLAttributeDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLBinaryArchiveDescriptor ()
@property (nonatomic) NSUInteger options;
@property (nonatomic) NSUInteger writingOptions;
@end
@implementation MTLBinaryArchiveDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(2) forKey:@"options"];
    [self setValue:@(2) forKey:@"writingOptions"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLBlitPassDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"sampleBufferAttachments", @"MTLBlitPassSampleBufferAttachmentDescriptorArray");
    return self;
}
+ (instancetype)blitPassDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLBlitPassSampleBufferAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfEncoderSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfEncoderSampleIndex"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLBlitPassSampleBufferAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLBlitPassSampleBufferAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLBufferLayoutDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"stepFunction"];
    [self setValue:@(1) forKey:@"stepRate"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLBufferLayoutDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLBufferLayoutDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLCaptureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"destination"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLCaptureManager
+ (instancetype)sharedCaptureManager { return [[self alloc] init]; }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLCommandBufferDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"retainedReferences"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLCommandQueueDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(64) forKey:@"maxCommandBufferCount"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLCompileOptions ()
@property (nonatomic) BOOL tracingEnabled;
@property (nonatomic) BOOL framebufferReadEnabled;
@property (nonatomic) BOOL debuggingEnabled;
@property (nonatomic) BOOL compileTimeStatisticsEnabled;
@property (nonatomic, copy) NSString *additionalCompilerArguments;
@property (nonatomic) unsigned char sourceLanguage;
@end
@implementation MTLCompileOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"fastMathEnabled"];
    [self setValue:@(2) forKey:@"mathMode"];
    [self setValue:@(262144) forKey:@"languageVersion"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLComputePassDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"sampleBufferAttachments", @"MTLComputePassSampleBufferAttachmentDescriptorArray");
    return self;
}
+ (instancetype)computePassDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLComputePassSampleBufferAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfEncoderSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfEncoderSampleIndex"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLComputePassSampleBufferAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLComputePassSampleBufferAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLComputePipelineDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLComputePipelineDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"stageInputDescriptor", @"MTLStageInputOutputDescriptor");
    FinchMTLSetNew(self, @"buffers", @"MTLPipelineBufferDescriptorArray");
    [self setValue:@[] forKey:@"insertLibraries"];
    [self setValue:@[] forKey:@"preloadedLibraries"];
    FinchMTLSetNew(self, @"linkedFunctions", @"MTLLinkedFunctions");
    [self setValue:@(1) forKey:@"maxCallStackDepth"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLComputePipelineReflection
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"bindings"];
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLCounterSampleBufferDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLDepthStencilDescriptor ()
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLDepthStencilDescriptor
- (void)setFrontFaceStencil:(MTLStencilDescriptor *)value { _frontFaceStencil = value ?: [[MTLStencilDescriptor alloc] init]; }
- (void)setBackFaceStencil:(MTLStencilDescriptor *)value { _backFaceStencil = value ?: [[MTLStencilDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(7) forKey:@"depthCompareFunction"];
    FinchMTLSetNew(self, @"frontFaceStencil", @"MTLStencilDescriptor");
    FinchMTLSetNew(self, @"backFaceStencil", @"MTLStencilDescriptor");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionConstant
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionConstantValues
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLFunctionReflection ()
@property (nonatomic, readonly) NSArray *arguments;
@property (nonatomic, readonly) NSUInteger primitiveKind;
@property (nonatomic, readonly) NSArray *tags;
@property (nonatomic, readonly) MTLType *returnType;
@property (nonatomic, readonly) NSArray *attributes;
@end
@implementation MTLFunctionReflection
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionStitchingAttributeAlwaysInline
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionStitchingFunctionNode
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"controlDependencies"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionStitchingGraph
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"nodes"];
    [self setValue:@[] forKey:@"attributes"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLFunctionStitchingInputNode
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLHeapDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(2) forKey:@"storageMode"];
    [self setValue:@(101) forKey:@"sparsePageSize"];
    [self setValue:@(32) forKey:@"resourceOptions"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLIndirectCommandBufferDescriptor ()
@property (nonatomic) NSUInteger resourceIndex;
@property (nonatomic) NSUInteger maxScissorRectCount;
@property (nonatomic) NSUInteger maxViewportCount;
@property (nonatomic) BOOL inheritStencilReferenceValues;
@property (nonatomic) BOOL inheritDepthTestBounds;
@property (nonatomic) BOOL inheritScissorRects;
@property (nonatomic) BOOL inheritViewports;
@property (nonatomic) BOOL inheritBlendColor;
@property (nonatomic) NSInteger allowOverrideRenderStates;
@property (nonatomic) NSUInteger maxToolsDispatchBindings;
@end
@implementation MTLIndirectCommandBufferDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"maxScissorRectCount"];
    [self setValue:@(1) forKey:@"maxViewportCount"];
    [self setValue:@(1) forKey:@"inheritStencilReferenceValues"];
    [self setValue:@(1) forKey:@"inheritDepthTestBounds"];
    [self setValue:@(1) forKey:@"inheritScissorRects"];
    [self setValue:@(1) forKey:@"inheritViewports"];
    [self setValue:@(1) forKey:@"inheritBlendColor"];
    [self setValue:@(1) forKey:@"inheritDepthStencilState"];
    [self setValue:@(1) forKey:@"inheritDepthBias"];
    [self setValue:@(1) forKey:@"inheritDepthClipMode"];
    [self setValue:@(1) forKey:@"inheritCullMode"];
    [self setValue:@(1) forKey:@"inheritFrontFacingWinding"];
    [self setValue:@(1) forKey:@"inheritTriangleFillMode"];
    [self setValue:@(31) forKey:@"maxKernelThreadgroupMemoryBindCount"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLIndirectInstanceAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(72) forKey:@"instanceDescriptorStride"];
    [self setValue:@(3) forKey:@"instanceDescriptorType"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLInstanceAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(64) forKey:@"instanceDescriptorStride"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLIntersectionFunctionDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLIntersectionFunctionTableDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLIntersectionFunctionTableDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLIOCommandQueueDescriptor ()
@property (nonatomic) NSUInteger maxWorkerThreads;
@end
@implementation MTLIOCommandQueueDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(64) forKey:@"maxCommandBufferCount"];
    [self setValue:@(1) forKey:@"priority"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLLinkedFunctions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLLogicalToPhysicalColorAttachmentMap
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLLogStateDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"level"];
    [self setValue:@(1048576) forKey:@"bufferSize"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLMeshRenderPipelineDescriptor
- (void)setObjectLinkedFunctions:(MTLLinkedFunctions *)value { _objectLinkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (void)setMeshLinkedFunctions:(MTLLinkedFunctions *)value { _meshLinkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (void)setFragmentLinkedFunctions:(MTLLinkedFunctions *)value { _fragmentLinkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"objectBuffers", @"MTLPipelineBufferDescriptorArray");
    FinchMTLSetNew(self, @"meshBuffers", @"MTLPipelineBufferDescriptorArray");
    FinchMTLSetNew(self, @"fragmentBuffers", @"MTLPipelineBufferDescriptorArray");
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    [self setValue:@(1) forKey:@"rasterizationEnabled"];
    [self setValue:@(1) forKey:@"maxVertexAmplificationCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTLRenderPipelineColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"objectLinkedFunctions", @"MTLLinkedFunctions");
    FinchMTLSetNew(self, @"meshLinkedFunctions", @"MTLLinkedFunctions");
    FinchMTLSetNew(self, @"fragmentLinkedFunctions", @"MTLLinkedFunctions");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLMotionKeyframeData
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
+ (instancetype)data { return [[self alloc] init]; }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLPipelineBufferDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLPipelineBufferDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLPipelineBufferDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLPointerType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLPrimitiveAccelerationStructureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"motionEndTime"];
    [self setValue:@(1) forKey:@"motionKeyframeCount"];
    return self;
}
+ (instancetype)descriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRasterizationRateLayerArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLRasterizationRateLayerDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArrayStore(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRasterizationRateLayerDescriptor
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRasterizationRateMapDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"layers", @"MTLRasterizationRateLayerArray");
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRasterizationRateSampleArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"NSNumber"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArrayStore(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassColorAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    { static const unsigned char b[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f}; [self setValue:[NSValue valueWithBytes:b objCType:"{?=dddd}"] forKey:@"clearColor"]; }
    [self setValue:@(1) forKey:@"storeAction"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassColorAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLRenderPassColorAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassDepthAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"clearDepth"];
    [self setValue:@(2) forKey:@"loadAction"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassDescriptor
- (void)setDepthAttachment:(MTLRenderPassDepthAttachmentDescriptor *)value { _depthAttachment = value ?: [[MTLRenderPassDepthAttachmentDescriptor alloc] init]; }
- (void)setStencilAttachment:(MTLRenderPassStencilAttachmentDescriptor *)value { _stencilAttachment = value ?: [[MTLRenderPassStencilAttachmentDescriptor alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"colorAttachments", @"MTLRenderPassColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"depthAttachment", @"MTLRenderPassDepthAttachmentDescriptor");
    FinchMTLSetNew(self, @"stencilAttachment", @"MTLRenderPassStencilAttachmentDescriptor");
    FinchMTLSetNew(self, @"sampleBufferAttachments", @"MTLRenderPassSampleBufferAttachmentDescriptorArray");
    return self;
}
+ (instancetype)renderPassDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassSampleBufferAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfVertexSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfVertexSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfFragmentSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfFragmentSampleIndex"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassSampleBufferAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLRenderPassSampleBufferAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPassStencilAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(2) forKey:@"loadAction"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPipelineColorAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"sourceRGBBlendFactor"];
    [self setValue:@(1) forKey:@"sourceAlphaBlendFactor"];
    [self setValue:@(15) forKey:@"writeMask"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPipelineColorAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLRenderPipelineColorAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPipelineDescriptor
- (void)setVertexLinkedFunctions:(MTLLinkedFunctions *)value { _vertexLinkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (void)setFragmentLinkedFunctions:(MTLLinkedFunctions *)value { _fragmentLinkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"vertexDescriptor", @"MTLVertexDescriptor");
    [self setValue:@(1) forKey:@"sampleCount"];
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    [self setValue:@(1) forKey:@"rasterizationEnabled"];
    [self setValue:@(1) forKey:@"maxVertexAmplificationCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTLRenderPipelineColorAttachmentDescriptorArray");
    [self setValue:@(16) forKey:@"maxTessellationFactor"];
    FinchMTLSetNew(self, @"vertexBuffers", @"MTLPipelineBufferDescriptorArray");
    FinchMTLSetNew(self, @"fragmentBuffers", @"MTLPipelineBufferDescriptorArray");
    [self setValue:@[] forKey:@"vertexPreloadedLibraries"];
    [self setValue:@[] forKey:@"fragmentPreloadedLibraries"];
    FinchMTLSetNew(self, @"vertexLinkedFunctions", @"MTLLinkedFunctions");
    FinchMTLSetNew(self, @"fragmentLinkedFunctions", @"MTLLinkedFunctions");
    [self setValue:@(1) forKey:@"maxVertexCallStackDepth"];
    [self setValue:@(1) forKey:@"maxFragmentCallStackDepth"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLRenderPipelineFunctionsDescriptor ()
@property (nonatomic, copy) NSArray *objectAdditionalBinaryFunctions;
@property (nonatomic, copy) NSArray *meshAdditionalBinaryFunctions;
@end
@implementation MTLRenderPipelineFunctionsDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"objectAdditionalBinaryFunctions"];
    [self setValue:@[] forKey:@"meshAdditionalBinaryFunctions"];
    [self setValue:@[] forKey:@"vertexAdditionalBinaryFunctions"];
    [self setValue:@[] forKey:@"fragmentAdditionalBinaryFunctions"];
    [self setValue:@[] forKey:@"tileAdditionalBinaryFunctions"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLRenderPipelineReflection
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"vertexBindings"];
    [self setValue:@[] forKey:@"fragmentBindings"];
    [self setValue:@[] forKey:@"tileBindings"];
    [self setValue:@[] forKey:@"objectBindings"];
    [self setValue:@[] forKey:@"meshBindings"];
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLResidencySetDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLResourceStatePassDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"sampleBufferAttachments", @"MTLResourceStatePassSampleBufferAttachmentDescriptorArray");
    return self;
}
+ (instancetype)resourceStatePassDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLResourceStatePassSampleBufferAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(18446744073709551615ULL) forKey:@"startOfEncoderSampleIndex"];
    [self setValue:@(18446744073709551615ULL) forKey:@"endOfEncoderSampleIndex"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLResourceStatePassSampleBufferAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLResourceStatePassSampleBufferAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLResourceViewPoolDescriptor ()
@property (nonatomic) BOOL forceBaseResourceID;
@property (nonatomic) NSUInteger baseResourceID;
@end
@implementation MTLResourceViewPoolDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLSamplerDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@property (nonatomic) NSUInteger pixelFormat;
@end
@implementation MTLSamplerDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"maxAnisotropy"];
    [self setValue:@(1) forKey:@"normalizedCoordinates"];
    [self setValue:@(3.402823e+38) forKey:@"lodMaxClamp"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLSharedEventHandle
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLSharedEventListener
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"dispatchQueue", @"OS_dispatch_queue_serial");
    return self;
}
+ (instancetype)sharedListener { return [[self alloc] init]; }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLSharedTextureHandle
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLStageInputOutputDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"layouts", @"MTLBufferLayoutDescriptorArray");
    FinchMTLSetNew(self, @"attributes", @"MTLAttributeDescriptorArray");
    return self;
}
+ (instancetype)stageInputOutputDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLStencilDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(7) forKey:@"stencilCompareFunction"];
    [self setValue:@(4294967295) forKey:@"readMask"];
    [self setValue:@(4294967295) forKey:@"writeMask"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLStitchedLibraryDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@[] forKey:@"binaryArchives"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLStructMember
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLStructType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"dataType"];
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLTensorDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLTensorDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"dimensions", @"MTLTensorExtents");
    [self setValue:@(3) forKey:@"dataType"];
    [self setValue:@(3) forKey:@"usage"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTensorExtents
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTensorReferenceType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLTextureDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLTextureDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(2) forKey:@"textureType"];
    [self setValue:@(70) forKey:@"pixelFormat"];
    [self setValue:@(1) forKey:@"width"];
    [self setValue:@(1) forKey:@"height"];
    [self setValue:@(1) forKey:@"depth"];
    [self setValue:@(1) forKey:@"mipmapLevelCount"];
    [self setValue:@(1) forKey:@"sampleCount"];
    [self setValue:@(1) forKey:@"arrayLength"];
    [self setValue:@(16) forKey:@"resourceOptions"];
    [self setValue:@(1) forKey:@"storageMode"];
    [self setValue:@(1) forKey:@"usage"];
    [self setValue:@(1) forKey:@"allowGPUOptimizedContents"];
    { static const unsigned char b[] = {0x02, 0x03, 0x04, 0x05}; [self setValue:[NSValue valueWithBytes:b objCType:"{?=CCCC}"] forKey:@"swizzle"]; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTextureReferenceType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLTextureViewDescriptor ()
@property (nonatomic) NSUInteger resourceIndex;
@property (nonatomic) NSInteger writeAccessPattern;
@end
@implementation MTLTextureViewDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(70) forKey:@"pixelFormat"];
    [self setValue:@(2) forKey:@"textureType"];
    { static const unsigned char b[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}; [self setValue:[NSValue valueWithBytes:b objCType:"{_NSRange=QQ}"] forKey:@"levelRange"]; }
    { static const unsigned char b[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}; [self setValue:[NSValue valueWithBytes:b objCType:"{_NSRange=QQ}"] forKey:@"sliceRange"]; }
    { static const unsigned char b[] = {0x02, 0x03, 0x04, 0x05}; [self setValue:[NSValue valueWithBytes:b objCType:"{?=CCCC}"] forKey:@"swizzle"]; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTileRenderPipelineColorAttachmentDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTileRenderPipelineColorAttachmentDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLTileRenderPipelineColorAttachmentDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLTileRenderPipelineDescriptor
- (void)setLinkedFunctions:(MTLLinkedFunctions *)value { _linkedFunctions = value ?: [[MTLLinkedFunctions alloc] init]; }
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"rasterSampleCount"];
    FinchMTLSetNew(self, @"colorAttachments", @"MTLTileRenderPipelineColorAttachmentDescriptorArray");
    FinchMTLSetNew(self, @"tileBuffers", @"MTLPipelineBufferDescriptorArray");
    [self setValue:@[] forKey:@"preloadedLibraries"];
    FinchMTLSetNew(self, @"linkedFunctions", @"MTLLinkedFunctions");
    [self setValue:@(1) forKey:@"maxCallStackDepth"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLType
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexAttribute
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexAttributeDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexAttributeDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLVertexAttributeDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexBufferLayoutDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    [self setValue:@(1) forKey:@"stepFunction"];
    [self setValue:@(1) forKey:@"stepRate"];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexBufferLayoutDescriptorArray
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)objectAtIndexedSubscript:(NSUInteger)i { return FinchMTLArrayGet(self, i, @"MTLVertexBufferLayoutDescriptor"); }
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)i { FinchMTLArraySet(self, i, obj); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@implementation MTLVertexDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    FinchMTLSetNew(self, @"layouts", @"MTLVertexBufferLayoutDescriptorArray");
    FinchMTLSetNew(self, @"attributes", @"MTLVertexAttributeDescriptorArray");
    return self;
}
+ (instancetype)vertexDescriptor { return [[self alloc] init]; }
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end

@interface MTLVisibleFunctionTableDescriptor ()
@property (nonatomic) BOOL forceResourceIndex;
@property (nonatomic) NSUInteger resourceIndex;
@end
@implementation MTLVisibleFunctionTableDescriptor
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return FinchMTLCopy(self); }
- (BOOL)isEqual:(id)other { return FinchMTLEqual(self, other); }
- (NSUInteger)hash { return FinchMTLHash(self); }
@end


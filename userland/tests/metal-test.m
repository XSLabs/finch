/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-metal-test: Metal's descriptors as values, run against Apple's Metal and
 * Finch's to compare (tools/host-tests.sh): defaults, the texture factories, attachment
 * and buffer arrays, copies and equality, resets, rasterization rates, the capture
 * manager. (Devices aren't compared: Finch has none yet; with "devices" it prints them.)
 */
#import <Metal/Metal.h>
#import <objc/runtime.h>

static void
props(NSString *title, id o)
{
    NSMutableArray *parts = [NSMutableArray array];
    /* (the public class's properties: Apple's objects are of private subclasses) */
    Class pub = [o class];
    while (pub && ([NSStringFromClass(pub) hasSuffix:@"Internal"] || [NSStringFromClass(pub) hasSuffix:@"SPI"] || [NSStringFromClass(pub) hasPrefix:@"_"]))
        pub = class_getSuperclass(pub);
    for (Class c = pub; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n = 0;
        objc_property_t *p = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *k = @(property_getName(p[i]));
            if ([k isEqualToString:@"hash"] || [k isEqualToString:@"description"] || [k isEqualToString:@"debugDescription"] ||
                [k isEqualToString:@"superclass"])
                continue;
            id v = nil;
            @try {
                v = [o valueForKey:k];
            } @catch (NSException *e) {
                continue;
            }
            NSString *s = !v ? @"nil" : [v isKindOfClass:[NSNumber class]] ? [v stringValue]
                                      : [v isKindOfClass:[NSValue class]] ? @"(struct)"
                                      : [v isKindOfClass:[NSString class]] ? v
                                      : [v isKindOfClass:[NSArray class]] ? [NSString stringWithFormat:@"[%lu]", (unsigned long)[v count]]
                                                                          : @"(object)";
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, s]];
        }
        free(p);
    }
    [parts sortUsingSelector:@selector(compare:)];
    printf("%s: %s\n", title.UTF8String, [parts componentsJoinedByString:@" "].UTF8String);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", [[NSBundle bundleForClass:[MTLTextureDescriptor class]] executablePath].UTF8String);
        if (argc > 1 && !strcmp(argv[1], "devices")) {
            NSArray *all = MTLCopyAllDevices();
            printf("default %s, devices %lu\n", [MTLCreateSystemDefaultDevice() name].UTF8String, (unsigned long)all.count);
            id<NSObject> observer = nil;
            NSArray *watched = MTLCopyAllDevicesWithObserver(&observer, ^(id<MTLDevice> d, MTLDeviceNotificationName n) {});
            printf("with observer %lu, observer %d\n", (unsigned long)watched.count, observer != nil);
            MTLRemoveDeviceObserver(observer);
            return 0;
        }
        for (NSString *name in @[ @"MTLTextureDescriptor", @"MTLSamplerDescriptor", @"MTLRenderPipelineDescriptor",
                                  @"MTLRenderPipelineColorAttachmentDescriptor", @"MTLRenderPassColorAttachmentDescriptor",
                                  @"MTLRenderPassDepthAttachmentDescriptor", @"MTLRenderPassStencilAttachmentDescriptor",
                                  @"MTLRenderPassDescriptor", @"MTLDepthStencilDescriptor", @"MTLStencilDescriptor", @"MTLVertexDescriptor",
                                  @"MTLVertexAttributeDescriptor", @"MTLVertexBufferLayoutDescriptor", @"MTLComputePipelineDescriptor",
                                  @"MTLHeapDescriptor", @"MTLCompileOptions", @"MTLArgumentDescriptor", @"MTLCommandBufferDescriptor",
                                  @"MTLCaptureDescriptor", @"MTLIndirectCommandBufferDescriptor", @"MTLCounterSampleBufferDescriptor",
                                  @"MTLBinaryArchiveDescriptor", @"MTLFunctionDescriptor", @"MTLStageInputOutputDescriptor",
                                  @"MTLPrimitiveAccelerationStructureDescriptor", @"MTLAccelerationStructureTriangleGeometryDescriptor",
                                  @"MTLComputePassDescriptor", @"MTLBlitPassDescriptor", @"MTLTileRenderPipelineDescriptor" ])
            props(name, [[NSClassFromString(name) alloc] init]);

        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:640 height:480
                                                                                  mipmapped:YES];
        props(@"2D mipmapped", t);
        props(@"cube", [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float size:64 mipmapped:NO]);
        props(@"buffer", [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Float width:100
                                                                       resourceOptions:MTLResourceStorageModePrivate |
                                                                                       MTLResourceCPUCacheModeWriteCombined
                                                                                 usage:MTLTextureUsageShaderRead]);
        MTLTextureDescriptor *tc = [t copy];
        printf("texture copy: equal %d same %d; changed equal %d\n", [tc isEqual:t], tc == t, (tc.width = 1, [tc isEqual:t]));

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0.5, 0.25, 1);
        rp.colorAttachments[2].storeAction = MTLStoreActionDontCare;
        MTLClearColor cc = rp.colorAttachments[0].clearColor;
        printf("render pass: load %lu clear %g %g %g %g; attachment 2 store %lu; 1 load %lu; same object %d\n",
               (unsigned long)rp.colorAttachments[0].loadAction, cc.red, cc.green, cc.blue, cc.alpha,
               (unsigned long)rp.colorAttachments[2].storeAction, (unsigned long)rp.colorAttachments[1].loadAction,
               rp.colorAttachments[0] == rp.colorAttachments[0]);
        MTLRenderPassColorAttachmentDescriptor *mine = [MTLRenderPassColorAttachmentDescriptor new];
        mine.level = 3;
        rp.colorAttachments[1] = mine;
        printf("set attachment: level %lu, copied %d\n", (unsigned long)rp.colorAttachments[1].level, rp.colorAttachments[1] != mine);
        MTLRenderPassDescriptor *rpc = [rp copy];
        printf("render pass copy: level %lu clear red %g, attachments shared %d\n", (unsigned long)rpc.colorAttachments[1].level,
               rpc.colorAttachments[0].clearColor.red, rpc.colorAttachments[0] == rp.colorAttachments[0]);
        MTLSamplePosition pos[2] = {{0.25, 0.25}, {0.75, 0.75}}, got[2];
        [rp setSamplePositions:pos count:2];
        NSUInteger np = [rp getSamplePositions:NULL count:0];
        [rp getSamplePositions:got count:np];
        printf("sample positions %lu: %g %g\n", (unsigned long)np, got[1].x, got[1].y);
        rp.depthAttachment = nil;
        printf("nil depth attachment resets: %d clear depth %g\n", rp.depthAttachment != nil, rp.depthAttachment.clearDepth);

        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0;
        vd.attributes[1].format = MTLVertexFormatFloat2;
        vd.attributes[1].offset = 12;
        vd.attributes[1].bufferIndex = 1;
        vd.layouts[0].stride = 20;
        printf("vertex: %lu %lu %lu, layout stride %lu step %lu rate %lu\n", (unsigned long)vd.attributes[0].format,
               (unsigned long)vd.attributes[1].offset, (unsigned long)vd.attributes[1].bufferIndex, (unsigned long)vd.layouts[0].stride,
               (unsigned long)vd.layouts[0].stepFunction, (unsigned long)vd.layouts[0].stepRate);
        MTLVertexDescriptor *vdc = [vd copy];
        printf("vertex copy: equal %d stride %lu\n", [vdc isEqual:vd], (unsigned long)vdc.layouts[0].stride);
        [vd reset];
        printf("vertex reset: format %lu stride %lu\n", (unsigned long)vd.attributes[0].format, (unsigned long)vd.layouts[0].stride);

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.label = @"pipe";
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.rasterSampleCount = 4;
        MTLRenderPipelineDescriptor *pdc = [pd copy];
        printf("pipeline: copy label %s format %lu blending %d count %lu, equal %d\n", pdc.label.UTF8String,
               (unsigned long)pdc.colorAttachments[0].pixelFormat, pdc.colorAttachments[0].blendingEnabled,
               (unsigned long)pdc.rasterSampleCount, [pdc isEqual:pd]);
        [pd reset];
        printf("pipeline reset: label %s count %lu format %lu\n", pd.label.UTF8String, (unsigned long)pd.rasterSampleCount,
               (unsigned long)pd.colorAttachments[0].pixelFormat);

        MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
        ds.depthCompareFunction = MTLCompareFunctionLess;
        ds.depthWriteEnabled = YES;
        ds.frontFaceStencil.stencilFailureOperation = MTLStencilOperationReplace;
        printf("depth stencil: compare %lu write %d front fail %lu back fail %lu\n", (unsigned long)ds.depthCompareFunction,
               ds.depthWriteEnabled, (unsigned long)ds.frontFaceStencil.stencilFailureOperation,
               (unsigned long)ds.backFaceStencil.stencilFailureOperation);

        MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
        float f = 2;
        [fcv setConstantValue:&f type:MTLDataTypeFloat atIndex:0];
        [fcv reset];
        printf("function constants: ok\n");

        MTLRasterizationRateLayerDescriptor *layer = [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(2, 3, 0)];
        printf("rate layer: %lu x %lu, h0 %g v2 %g\n", (unsigned long)layer.sampleCount.width, (unsigned long)layer.sampleCount.height,
               layer.horizontal[0].floatValue, layer.vertical[2].floatValue);
        MTLRasterizationRateMapDescriptor *map = [MTLRasterizationRateMapDescriptor
            rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(800, 600, 0)
                                                   layer:layer];
        printf("rate map: %lu x %lu, layer count %lu, layer 0 same %d\n", (unsigned long)map.screenSize.width,
               (unsigned long)map.screenSize.height, (unsigned long)map.layerCount, [map layerAtIndex:0] == layer);

        MTLCaptureManager *cm = [MTLCaptureManager sharedCaptureManager];
        printf("capture: shared same %d capturing %d\n", cm == [MTLCaptureManager sharedCaptureManager], cm.isCapturing);
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* MTKView state and the real no-device errors from MetalKit's resource helpers. */
#import <MetalKit/MetalKit.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#include <stdio.h>

static const char *
image_for(const void *address)
{
    Dl_info info = {0};
    return dladdr(address, &info) ? info.dli_fname : "?";
}

static const char *
error_domain(NSError *error)
{
    return error ? error.domain.UTF8String : "(null)";
}

int
main(void)
{
    @autoreleasepool {
        printf("MetalKit: %s\n", image_for((__bridge const void *)objc_getClass("MTKView")));

        MTKView *view = [[MTKView alloc] initWithFrame:CGRectMake(0, 0, 64, 32) device:nil];
        printf("view %d deviceNil %d drawableNil %d paused %d fps %ld resize %d framebuffer %d sample %lu depth %u color %u clear %.1f %.1f %.1f %.1f\n",
               view != nil, view.device == nil, view.currentDrawable == nil, view.paused,
               (long)view.preferredFramesPerSecond, view.autoResizeDrawable, view.framebufferOnly,
               (unsigned long)view.sampleCount, (unsigned)view.depthStencilPixelFormat, (unsigned)view.colorPixelFormat,
               view.clearColor.red, view.clearColor.green, view.clearColor.blue, view.clearColor.alpha);
        view.framebufferOnly = NO;
        view.presentsWithTransaction = YES;
        view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
        view.sampleCount = 4;
        view.clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
        view.clearDepth = 0.5;
        view.clearStencil = 7;
        view.preferredFramesPerSecond = 30;
        view.autoResizeDrawable = NO;
        view.drawableSize = CGSizeMake(320, 240);
        printf("view set framebuffer %d transaction %d sample %lu depth %u size %.0f %.0f clear %.2f %.2f %.2f %.1f depthClear %.1f stencil %u fps %ld resize %d\n",
               view.framebufferOnly, view.presentsWithTransaction, (unsigned long)view.sampleCount,
               (unsigned)view.depthStencilPixelFormat, view.drawableSize.width, view.drawableSize.height,
               view.clearColor.red, view.clearColor.green, view.clearColor.blue, view.clearColor.alpha,
               view.clearDepth, view.clearStencil, (long)view.preferredFramesPerSecond, view.autoResizeDrawable);

        MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:(id<MTLDevice>)nil];
        NSError *error = nil;
        id<MTLTexture> texture = [loader newTextureWithData:[NSData data] options:nil error:&error];
        printf("texture %d deviceNil %d error %ld %s\n", texture != nil, loader.device == nil,
               (long)error.code, error_domain(error));

        error = nil;
        NSArray *emptyTextures = [loader newTexturesWithContentsOfURLs:@[] options:nil error:&error];
        printf("empty textures %d count %lu errorNil %d\n", emptyTextures != nil,
               (unsigned long)emptyTextures.count, error == nil);

        dispatch_semaphore_t callbackDone = dispatch_semaphore_create(0);
        __block BOOL callbackTexture = NO, callbackOnMain = YES;
        __block NSInteger callbackErrorCode = -1;
        __block NSString *callbackErrorDomain = nil;
        [loader newTextureWithData:[NSData data] options:nil completionHandler:^(id<MTLTexture> result, NSError *callbackError) {
            callbackTexture = result != nil;
            callbackOnMain = [NSThread isMainThread];
            callbackErrorCode = callbackError.code;
            callbackErrorDomain = callbackError.domain;
            dispatch_semaphore_signal(callbackDone);
        }];
        BOOL callbackFinished = dispatch_semaphore_wait(callbackDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
        printf("texture async %d texture %d main %d error %ld %s\n", callbackFinished, callbackTexture,
               callbackOnMain, (long)callbackErrorCode, callbackErrorDomain.UTF8String ?: "(null)");

        error = nil;
        /* Keep ModelIO optional so the test also runs in Finch's VM. */
        void *modelIO = dlopen("/System/Library/Frameworks/ModelIO.framework/Versions/A/ModelIO", RTLD_LAZY | RTLD_LOCAL);
        Class meshClass = objc_getClass("MDLMesh");
        if (modelIO && meshClass) {
            typedef id (*MeshFactory)(id, SEL, vector_float3, vector_uint3, MDLGeometryType, BOOL, id);
            MeshFactory makeBox = (MeshFactory)objc_msgSend;
            MDLMesh *modelMesh = makeBox(meshClass, sel_registerName("newBoxWithDimensions:segments:geometryType:inwardNormals:allocator:"),
                                         (vector_float3){1, 1, 1}, (vector_uint3){1, 1, 1}, MDLGeometryTypeTriangles, NO, nil);
            MTKMesh *mesh = [[MTKMesh alloc] initWithMesh:modelMesh device:(id<MTLDevice>)nil error:&error];
            printf("mesh %d error %ld %s\n", mesh != nil, (long)error.code, error_domain(error));
            if (modelMesh)
                CFRelease((__bridge CFTypeRef)modelMesh);
        } else {
            printf("mesh class %d modelIO %d\n", objc_getClass("MTKMesh") != Nil, modelIO != NULL);
        }
    }
}

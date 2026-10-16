/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Mesh buffers need a Metal device, so construction fails instead of returning empty data. */
#import <MetalKit/MetalKit.h>

NSString *const MTKModelErrorDomain = @"MTKModelErrorDomain";
NSString *const MTKModelErrorKey = @"MTKModelErrorKey";

@implementation MTKMesh

- (instancetype)initWithMesh:(MDLMesh *)mesh device:(id<MTLDevice>)device error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:MTKModelErrorDomain code:0 userInfo:nil];
    return nil;
}

+ (NSArray<MTKMesh *> *)newMeshesFromAsset:(MDLAsset *)asset device:(id<MTLDevice>)device
                             sourceMeshes:(NSArray<MDLMesh *> **)sourceMeshes error:(NSError **)error
{
    if (sourceMeshes)
        *sourceMeshes = nil;
    if (error)
        *error = [NSError errorWithDomain:MTKModelErrorDomain code:0 userInfo:nil];
    return nil;
}

@end

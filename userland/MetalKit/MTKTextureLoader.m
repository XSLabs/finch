/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Texture data needs a Metal device; Finch reports that resource limit as an error. */
#import <MetalKit/MetalKit.h>
#import <dispatch/dispatch.h>

NSString *const MTKTextureLoaderErrorDomain = @"MTKTextureLoaderErrorDomain";
NSString *const MTKTextureLoaderErrorKey = @"MTKTextureLoaderErrorKey";
NSString *const MTKTextureLoaderOptionAllocateMipmaps = @"MTKTextureLoaderOptionAllocateMipmaps";
NSString *const MTKTextureLoaderOptionGenerateMipmaps = @"MTKTextureLoaderOptionGenerateMipmaps";
NSString *const MTKTextureLoaderOptionSRGB = @"MTKTextureLoaderOptionSRGB";
NSString *const MTKTextureLoaderOptionTextureUsage = @"MTKTextureLoaderOptionTextureUsage";
NSString *const MTKTextureLoaderOptionTextureCPUCacheMode = @"MTKTextureLoaderOptionTextureCPUCacheMode";
NSString *const MTKTextureLoaderOptionTextureStorageMode = @"MTKTextureLoaderOptionTextureStorageMode";
NSString *const MTKTextureLoaderOptionCubeLayout = @"MTKTextureLoaderOptionCubeLayout";
NSString *const MTKTextureLoaderCubeLayoutVertical = @"MTKTextureLoaderCubeLayoutVertical";
NSString *const MTKTextureLoaderOptionOrigin = @"MTKTextureLoaderOptionOrigin";
NSString *const MTKTextureLoaderOriginTopLeft = @"MTKTextureLoaderOriginTopLeft";
NSString *const MTKTextureLoaderOriginBottomLeft = @"MTKTextureLoaderOriginBottomLeft";
NSString *const MTKTextureLoaderOriginFlippedVertically = @"MTKTextureLoaderOriginFlippedVertically";
NSString *const MTKTextureLoaderOptionLoadAsArray = @"MTKTextureLoaderOptionLoadAsArray";

static NSError *
unavailable_error(void)
{
    return [NSError errorWithDomain:MTKTextureLoaderErrorDomain code:0 userInfo:nil];
}

static NSArray *
unavailable_textures(NSUInteger count, NSError **error)
{
    if (!count) {
        if (error)
            *error = nil;
        return @[];
    }
    if (error)
        *error = unavailable_error();
    NSMutableArray *textures = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++)
        [textures addObject:[NSNull null]];
    return textures;
}

static void
complete_texture(MTKTextureLoaderCallback callback)
{
    NSError *error = unavailable_error();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_async(queue, ^{ callback(nil, error); });
}

static void
complete_textures(MTKTextureLoaderArrayCallback callback, NSUInteger count)
{
    NSError *error = count ? unavailable_error() : nil;
    NSArray *textures = unavailable_textures(count, NULL);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_async(queue, ^{ callback(textures, error); });
}

@interface MTKTextureLoader ()
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@end

@implementation MTKTextureLoader

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    if ((self = [super init]))
        _device = device;
    return self;
}

- (id<MTLTexture>)newTextureWithContentsOfURL:(NSURL *)URL options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (NSArray *)newTexturesWithContentsOfURLs:(NSArray<NSURL *> *)URLs options:(NSDictionary *)options error:(NSError **)error
{
    return unavailable_textures(URLs.count, error);
}

- (id<MTLTexture>)newTextureWithData:(NSData *)data options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (id<MTLTexture>)newTextureWithCGImage:(CGImageRef)cgImage options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (id<MTLTexture>)newTextureWithMDLTexture:(MDLTexture *)texture options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (id<MTLTexture>)newTextureWithName:(NSString *)name scaleFactor:(CGFloat)scaleFactor bundle:(NSBundle *)bundle
                             options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (id<MTLTexture>)newTextureWithName:(NSString *)name scaleFactor:(CGFloat)scaleFactor displayGamut:(NSDisplayGamut)displayGamut
                              bundle:(NSBundle *)bundle options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = unavailable_error();
    return nil;
}

- (void)newTextureWithContentsOfURL:(NSURL *)URL options:(NSDictionary *)options completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTextureWithData:(NSData *)data options:(NSDictionary *)options completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTextureWithCGImage:(CGImageRef)cgImage options:(NSDictionary *)options completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTextureWithMDLTexture:(MDLTexture *)texture options:(NSDictionary *)options completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTextureWithName:(NSString *)name scaleFactor:(CGFloat)scaleFactor bundle:(NSBundle *)bundle options:(NSDictionary *)options
         completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTextureWithName:(NSString *)name scaleFactor:(CGFloat)scaleFactor displayGamut:(NSDisplayGamut)displayGamut
                    bundle:(NSBundle *)bundle options:(NSDictionary *)options completionHandler:(MTKTextureLoaderCallback)completionHandler
{
    complete_texture(completionHandler);
}

- (void)newTexturesWithContentsOfURLs:(NSArray<NSURL *> *)URLs options:(NSDictionary *)options
                    completionHandler:(MTKTextureLoaderArrayCallback)completionHandler
{
    complete_textures(completionHandler, URLs.count);
}

- (void)newTexturesWithNames:(NSArray<NSString *> *)names scaleFactor:(CGFloat)scaleFactor bundle:(NSBundle *)bundle
                     options:(NSDictionary *)options completionHandler:(MTKTextureLoaderArrayCallback)completionHandler
{
    complete_textures(completionHandler, names.count);
}

- (void)newTexturesWithNames:(NSArray<NSString *> *)names scaleFactor:(CGFloat)scaleFactor displayGamut:(NSDisplayGamut)displayGamut
                      bundle:(NSBundle *)bundle options:(NSDictionary *)options completionHandler:(MTKTextureLoaderArrayCallback)completionHandler
{
    complete_textures(completionHandler, names.count);
}

@end

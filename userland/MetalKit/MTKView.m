/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* MTKView's state can be used without a GPU; its CAMetalLayer has no drawables. */
#import <MetalKit/MetalKit.h>

@implementation MTKView {
    __weak id<MTKViewDelegate> _delegate;
    CAMetalLayer *_metalLayer;
    MTLTextureUsage _depthStencilAttachmentTextureUsage;
    MTLTextureUsage _multisampleColorAttachmentTextureUsage;
    MTLStorageMode _depthStencilStorageMode;
    MTLPixelFormat _depthStencilPixelFormat;
    NSUInteger _sampleCount;
    MTLClearColor _clearColor;
    double _clearDepth;
    uint32_t _clearStencil;
    NSInteger _preferredFramesPerSecond;
    BOOL _enableSetNeedsDisplay;
    BOOL _autoResizeDrawable;
    BOOL _paused;
}

- (void)finishInitializationWithDevice:(id<MTLDevice>)device
{
    _metalLayer = [[CAMetalLayer alloc] init];
    _metalLayer.device = device;
    self.wantsLayer = YES;
    self.layer = _metalLayer;
    _depthStencilAttachmentTextureUsage = MTLTextureUsageRenderTarget;
    _multisampleColorAttachmentTextureUsage = MTLTextureUsageRenderTarget;
    _depthStencilStorageMode = MTLStorageModePrivate;
    _depthStencilPixelFormat = MTLPixelFormatInvalid;
    _sampleCount = 1;
    _clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    _clearDepth = 1.0;
    _preferredFramesPerSecond = 60;
    _autoResizeDrawable = YES;
    [self updateDrawableSize];
}

- (instancetype)initWithFrame:(CGRect)frameRect device:(id<MTLDevice>)device
{
    if ((self = [super initWithFrame:frameRect]))
        [self finishInitializationWithDevice:device];
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    return [self initWithFrame:frameRect device:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self finishInitializationWithDevice:nil];
    return self;
}

- (void)updateDrawableSize
{
    if (_autoResizeDrawable)
        _metalLayer.drawableSize = [self convertSizeToBacking:self.bounds.size];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    CGSize drawableSize = [self convertSizeToBacking:self.bounds.size];
    if (_autoResizeDrawable)
        _metalLayer.drawableSize = drawableSize;
    if ([_delegate respondsToSelector:@selector(mtkView:drawableSizeWillChange:)])
        [_delegate mtkView:self drawableSizeWillChange:drawableSize];
}

- (id<MTKViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<MTKViewDelegate>)delegate { _delegate = delegate; }

- (id<MTLDevice>)device { return _metalLayer.device; }
- (void)setDevice:(id<MTLDevice>)device { _metalLayer.device = device; }

- (id<CAMetalDrawable>)currentDrawable { return [_metalLayer nextDrawable]; }
- (MTLRenderPassDescriptor *)currentRenderPassDescriptor { return nil; }
- (MTL4RenderPassDescriptor *)currentMTL4RenderPassDescriptor { return nil; }
- (id<MTLTexture>)depthStencilTexture { return nil; }
- (id<MTLTexture>)multisampleColorTexture { return nil; }
- (id<MTLResidencySet>)residencySet { return nil; }
- (id<MTLDevice>)preferredDevice { return _metalLayer.preferredDevice; }
- (CGSize)preferredDrawableSize { return [self convertSizeToBacking:self.bounds.size]; }
- (void)releaseDrawables {}

- (BOOL)framebufferOnly { return _metalLayer.framebufferOnly; }
- (void)setFramebufferOnly:(BOOL)value { _metalLayer.framebufferOnly = value; }
- (BOOL)presentsWithTransaction { return _metalLayer.presentsWithTransaction; }
- (void)setPresentsWithTransaction:(BOOL)value { _metalLayer.presentsWithTransaction = value; }
- (MTLPixelFormat)colorPixelFormat { return _metalLayer.pixelFormat; }
- (void)setColorPixelFormat:(MTLPixelFormat)value { _metalLayer.pixelFormat = value; }
- (CGColorSpaceRef)colorspace { return _metalLayer.colorspace; }
- (void)setColorspace:(CGColorSpaceRef)value { _metalLayer.colorspace = value; }
- (CGSize)drawableSize { return _metalLayer.drawableSize; }
- (void)setDrawableSize:(CGSize)value { _metalLayer.drawableSize = value; }

- (MTLTextureUsage)depthStencilAttachmentTextureUsage { return _depthStencilAttachmentTextureUsage; }
- (void)setDepthStencilAttachmentTextureUsage:(MTLTextureUsage)value { _depthStencilAttachmentTextureUsage = value; }
- (MTLTextureUsage)multisampleColorAttachmentTextureUsage { return _multisampleColorAttachmentTextureUsage; }
- (void)setMultisampleColorAttachmentTextureUsage:(MTLTextureUsage)value { _multisampleColorAttachmentTextureUsage = value; }
- (MTLStorageMode)depthStencilStorageMode { return _depthStencilStorageMode; }
- (void)setDepthStencilStorageMode:(MTLStorageMode)value { _depthStencilStorageMode = value; }
- (MTLPixelFormat)depthStencilPixelFormat { return _depthStencilPixelFormat; }
- (void)setDepthStencilPixelFormat:(MTLPixelFormat)value { _depthStencilPixelFormat = value; }
- (NSUInteger)sampleCount { return _sampleCount; }
- (void)setSampleCount:(NSUInteger)value { _sampleCount = value; }
- (MTLClearColor)clearColor { return _clearColor; }
- (void)setClearColor:(MTLClearColor)value { _clearColor = value; }
- (double)clearDepth { return _clearDepth; }
- (void)setClearDepth:(double)value { _clearDepth = value; }
- (uint32_t)clearStencil { return _clearStencil; }
- (void)setClearStencil:(uint32_t)value { _clearStencil = value; }
- (NSInteger)preferredFramesPerSecond { return _preferredFramesPerSecond; }
- (void)setPreferredFramesPerSecond:(NSInteger)value { _preferredFramesPerSecond = value; }
- (BOOL)enableSetNeedsDisplay { return _enableSetNeedsDisplay; }
- (void)setEnableSetNeedsDisplay:(BOOL)value { _enableSetNeedsDisplay = value; }
- (BOOL)autoResizeDrawable { return _autoResizeDrawable; }
- (void)setAutoResizeDrawable:(BOOL)value
{
    _autoResizeDrawable = value;
    [self updateDrawableSize];
}
- (BOOL)isPaused { return _paused; }
- (void)setPaused:(BOOL)value { _paused = value; }

- (void)draw
{
    [_delegate drawInMTKView:self];
}

@end

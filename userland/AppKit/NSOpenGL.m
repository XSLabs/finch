/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSOpenGLPixelFormat, NSOpenGLContext and NSOpenGLView over Finch's CGL (OpenGL.framework,
 * Mesa's software renderer), loaded when first used, so apps without OpenGL don't map it.
 * A context with a view draws into a buffer the view's size (in pixels when the view
 * wants its best resolution); flushBuffer copies the frame to the view, which draws it
 * over its own drawing. An NSOpenGLView makes its context current before -drawRect:,
 * calling -prepareOpenGL once and -reshape when its size changes, as Apple's does.
 * Attribute values are CGL's (NSOpenGLPFA* are the same numbers).
 */
#import "AppKit_Finch.h"
#import <OpenGL/OpenGL.h>
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

/* FINCH_DEBUG_GL=1 traces the contexts' drawables and calls (for apps whose GL views come
   out wrong) */
static BOOL
gl_trace(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("FINCH_DEBUG_GL") != NULL;
    return on;
}
#define GLTRACE(...)                                     \
    do {                                                 \
        if (gl_trace())                                  \
            fprintf(stderr, "finch-gl: " __VA_ARGS__);   \
    } while (0)

CGImageRef FinchViewOpenGLImage(NSView *view);
void FinchViewSetOpenGLImage(NSView *view, CGImageRef image);
void FinchViewSetOpenGLBelow(NSView *view, BOOL below);
BOOL FinchViewIsBeingDrawn(NSView *view);

#pragma mark - CGL, when it's needed

static struct {
    CGLError (*choose)(const CGLPixelFormatAttribute *, CGLPixelFormatObj *, GLint *);
    CGLError (*describe)(CGLPixelFormatObj, GLint, CGLPixelFormatAttribute, GLint *);
    CGLPixelFormatObj (*retainFormat)(CGLPixelFormatObj);
    void (*releaseFormat)(CGLPixelFormatObj);
    CGLError (*create)(CGLPixelFormatObj, CGLContextObj, CGLContextObj *);
    CGLContextObj (*retainContext)(CGLContextObj);
    void (*releaseContext)(CGLContextObj);
    CGLPixelFormatObj (*getFormat)(CGLContextObj);
    CGLError (*setCurrent)(CGLContextObj);
    CGLContextObj (*getCurrent)(void);
    CGLError (*flush)(CGLContextObj);
    CGLError (*clearDrawable)(CGLContextObj);
    CGLError (*setParameter)(CGLContextObj, CGLContextParameter, const GLint *);
    CGLError (*getParameter)(CGLContextObj, CGLContextParameter, GLint *);
    CGLError (*lock)(CGLContextObj);
    CGLError (*unlock)(CGLContextObj);
    CGLError (*setDrawable)(CGLContextObj, GLsizei, GLsizei, void (*)(CGLContextObj, void *), void *);
    const void *(*getPixels)(CGLContextObj, GLsizei *, GLsizei *, GLint *);
} cgl;

static BOOL
load_cgl(void)
{
    static BOOL loaded, ok;
    if (loaded)
        return ok;
    loaded = YES;
    void *h = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
        return NO;
#define SYM(field, name) cgl.field = dlsym(h, name)
    SYM(choose, "CGLChoosePixelFormat");
    SYM(describe, "CGLDescribePixelFormat");
    SYM(retainFormat, "CGLRetainPixelFormat");
    SYM(releaseFormat, "CGLReleasePixelFormat");
    SYM(create, "CGLCreateContext");
    SYM(retainContext, "CGLRetainContext");
    SYM(releaseContext, "CGLReleaseContext");
    SYM(getFormat, "CGLGetPixelFormat");
    SYM(setCurrent, "CGLSetCurrentContext");
    SYM(getCurrent, "CGLGetCurrentContext");
    SYM(flush, "CGLFlushDrawable");
    SYM(clearDrawable, "CGLClearDrawable");
    SYM(setParameter, "CGLSetParameter");
    SYM(getParameter, "CGLGetParameter");
    SYM(lock, "CGLLockContext");
    SYM(unlock, "CGLUnlockContext");
    SYM(setDrawable, "FinchCGLSetDrawable");
    SYM(getPixels, "FinchCGLGetPixels");
#undef SYM
    ok = cgl.choose && cgl.create && cgl.setCurrent && cgl.setDrawable && cgl.getPixels;
    return ok;
}

#pragma mark - Pixel formats

@implementation NSOpenGLPixelFormat {
    CGLPixelFormatObj _format;
    GLint _screens;
    NSData *_attributes;
}

- (instancetype)initWithAttributes:(const NSOpenGLPixelFormatAttribute *)attribs
{
    if (!(self = [super init]))
        return nil;
    if (gl_trace() && attribs) {
        fprintf(stderr, "finch-gl: pixel format");
        for (const NSOpenGLPixelFormatAttribute *a = attribs; *a && a - attribs < 64; a++)
            fprintf(stderr, " %u", (unsigned)*a);
        fprintf(stderr, "\n");
    }
    if (!load_cgl()) {
        [self release];
        return nil;
    }
    size_t n = 0;
    if (attribs)
        while (attribs[n])
            n++;
    _attributes = [[NSData alloc] initWithBytes:attribs ?: (const NSOpenGLPixelFormatAttribute[]){0}
                                         length:(n + 1) * sizeof(NSOpenGLPixelFormatAttribute)];
    if (cgl.choose((const CGLPixelFormatAttribute *)[_attributes bytes], &_format, &_screens) != kCGLNoError || !_format) {
        [self release];
        return nil;
    }
    return self;
}

- (instancetype)initWithCGLPixelFormatObj:(CGLPixelFormatObj)format
{
    if (!(self = [super init]))
        return nil;
    if (!format || !load_cgl()) {
        [self release];
        return nil;
    }
    _format = cgl.retainFormat(format);
    _screens = 1;
    return self;
}

- (instancetype)initWithData:(NSData *)attribs
{
    return [self initWithAttributes:(const NSOpenGLPixelFormatAttribute *)[attribs bytes]];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *d = [coder allowsKeyedCoding] ? [coder decodeObjectForKey:@"NSPixelAttributes"] : nil;
    NSMutableData *attrs = [NSMutableData dataWithData:d ?: [NSData data]];
    NSOpenGLPixelFormatAttribute zero = 0;
    [attrs appendBytes:&zero length:sizeof zero];
    return [self initWithAttributes:(const NSOpenGLPixelFormatAttribute *)[attrs bytes]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding] && _attributes)
        [coder encodeObject:[_attributes subdataWithRange:NSMakeRange(0, [_attributes length] - sizeof(NSOpenGLPixelFormatAttribute))]
                     forKey:@"NSPixelAttributes"];
}

- (void)dealloc
{
    if (_format)
        cgl.releaseFormat(_format);
    [_attributes release];
    [super dealloc];
}

- (CGLPixelFormatObj)CGLPixelFormatObj { return _format; }
- (GLint)numberOfVirtualScreens { return _screens; }
- (NSData *)attributes { return _attributes; }
- (void)setAttributes:(NSData *)attribs {}

- (void)getValues:(GLint *)vals forAttribute:(NSOpenGLPixelFormatAttribute)attrib forVirtualScreen:(GLint)screen
{
    if (vals && cgl.describe)
        cgl.describe(_format, screen, (CGLPixelFormatAttribute)attrib, vals);
}

@end

#pragma mark - Contexts

@interface NSOpenGLContext ()
- (void)_finchFlushed;
@end

static void
context_flushed(CGLContextObj ctx, void *info)
{
    [(NSOpenGLContext *)info _finchFlushed];
}

static char current_key;

@implementation NSOpenGLContext {
    CGLContextObj _context;
    NSOpenGLPixelFormat *_format;
    NSView *_view; /* not retained, as Apple's (a weak reference) */
}

- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share
{
    if (!(self = [super init]))
        return nil;
    if (!format || !load_cgl() || cgl.create([format CGLPixelFormatObj], [share CGLContextObj], &_context) != kCGLNoError) {
        [self release];
        return nil;
    }
    _format = [format retain];
    return self;
}

- (instancetype)initWithCGLContextObj:(CGLContextObj)context
{
    if (!(self = [super init]))
        return nil;
    if (!context || !load_cgl()) {
        [self release];
        return nil;
    }
    _context = cgl.retainContext(context);
    _format = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:cgl.getFormat(context)];
    return self;
}

- (void)dealloc
{
    if (_context) {
        if (cgl.getCurrent && cgl.getCurrent() == _context)
            cgl.setCurrent(NULL);
        cgl.releaseContext(_context);
    }
    [_format release];
    [super dealloc];
}

- (CGLContextObj)CGLContextObj { return _context; }
- (NSOpenGLPixelFormat *)pixelFormat { return _format; }
- (NSView *)view { return _view; }

/* The drawable's size: the view's, in pixels when it wants its best resolution. */
- (void)_finchSizeDrawable
{
    NSView *v = _view;
    if (!v || !_context)
        return;
    NSRect b = [v bounds];
    if ([v wantsBestResolutionOpenGLSurface])
        b = [v convertRectToBacking:b];
    GLTRACE("drawable %ldx%ld for %s %s (best resolution %d)\n", lround(NSWidth(b)), lround(NSHeight(b)), object_getClassName(v),
            NSStringFromRect([v bounds]).UTF8String, [v wantsBestResolutionOpenGLSurface]);
    cgl.setDrawable(_context, (GLsizei)lround(NSWidth(b)), (GLsizei)lround(NSHeight(b)), context_flushed, self);
}

- (void)setView:(NSView *)view
{
    if (_view && _view != view)
        FinchViewSetOpenGLImage(_view, NULL);
    _view = view;
    if (view)
        [self _finchSizeDrawable];
    else if (_context)
        cgl.clearDrawable(_context);
}

- (void)update { [self _finchSizeDrawable]; }

- (void)clearDrawable
{
    if (_view)
        FinchViewSetOpenGLImage(_view, NULL);
    _view = nil;
    if (_context)
        cgl.clearDrawable(_context);
}

- (void)makeCurrentContext
{
    GLTRACE("make current (view %s)\n", _view ? object_getClassName(_view) : "none");
    cgl.setCurrent(_context);
    [[[NSThread currentThread] threadDictionary] setObject:self forKey:[NSValue valueWithPointer:&current_key]];
}

+ (NSOpenGLContext *)currentContext
{
    if (!load_cgl())
        return nil;
    NSOpenGLContext *c = [[[NSThread currentThread] threadDictionary] objectForKey:[NSValue valueWithPointer:&current_key]];
    return c && cgl.getCurrent() == [c CGLContextObj] ? c : nil;
}

+ (void)clearCurrentContext
{
    if (!load_cgl())
        return;
    cgl.setCurrent(NULL);
    [[[NSThread currentThread] threadDictionary] removeObjectForKey:[NSValue valueWithPointer:&current_key]];
}

- (void)flushBuffer
{
    if (_context)
        cgl.flush(_context);
}

/* The frame to the view, which shows it when it next draws (now, if it isn't drawing). */
- (void)_finchFlushed
{
    NSView *v = _view;
    if (!v)
        return;
    GLsizei w = 0, h = 0;
    GLint rowBytes = 0;
    const void *pixels = cgl.getPixels(_context, &w, &h, &rowBytes);
    GLTRACE("flush %dx%d into %s %s\n", (int)w, (int)h, object_getClassName(v), NSStringFromRect([v bounds]).UTF8String);
    if (gl_trace()) {
        /* the viewport and projection the app left, to compare with the drawable */
        void (*getIntegerv)(GLenum, GLint *) = dlsym(RTLD_DEFAULT, "glGetIntegerv");
        void (*getFloatv)(GLenum, GLfloat *) = dlsym(RTLD_DEFAULT, "glGetFloatv");
        GLint vp[4] = {0};
        GLfloat pm[16] = {0};
        if (getIntegerv)
            getIntegerv(0x0BA2 /* GL_VIEWPORT */, vp);
        if (getFloatv)
            getFloatv(0x0BA7 /* GL_PROJECTION_MATRIX */, pm);
        GLTRACE("viewport %d %d %d %d projection %g %g %g %g\n", vp[0], vp[1], vp[2], vp[3], pm[0], pm[5], pm[10], pm[14]);
    }
    if (!pixels || w <= 0 || h <= 0)
        return;
    CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)rowBytes * h);
    CGDataProviderRef p = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    GLint opacity = 1;
    if (cgl.getParameter)
        cgl.getParameter(_context, kCGLCPSurfaceOpacity, &opacity);
    /* a view that says it isn't opaque shows what's behind where GL left alpha, as its
       layer does on macOS */
    if (![v isOpaque])
        opacity = 0;
    CGImageRef im = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)rowBytes, cs,
                                  (opacity ? (uint32_t)kCGImageAlphaNoneSkipFirst : (uint32_t)kCGImageAlphaFirst) |
                                      (uint32_t)kCGBitmapByteOrder32Little,
                                  p, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(p);
    CFRelease(data);
    GLint order = 1;
    if (cgl.getParameter)
        cgl.getParameter(_context, kCGLCPSurfaceOrder, &order);
    FinchViewSetOpenGLBelow(v, order < 0);
    FinchViewSetOpenGLImage(v, im);
    if (gl_trace()) {
        /* the frame as GL drew it, to look at */
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/finch-gl-last.png"), kCFURLPOSIXPathStyle, false);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
        if (d) {
            CGImageDestinationAddImage(d, im, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
        }
        CFRelease(url);
        GLTRACE("frame opacity %d saved\n", (int)opacity);
    }
    CGImageRelease(im);
    if (!FinchViewIsBeingDrawn(v))
        [v setNeedsDisplay:YES];
}

- (void)setValues:(const GLint *)vals forParameter:(NSOpenGLContextParameter)param
{
    GLTRACE("set parameter %d to %d\n", (int)param, vals ? (int)vals[0] : 0);
    if (_context && cgl.setParameter)
        cgl.setParameter(_context, (CGLContextParameter)param, vals);
}

- (void)getValues:(GLint *)vals forParameter:(NSOpenGLContextParameter)param
{
    if (_context && cgl.getParameter)
        cgl.getParameter(_context, (CGLContextParameter)param, vals);
}

- (GLint)currentVirtualScreen { return 0; }
- (void)setCurrentVirtualScreen:(GLint)screen {}
- (void)setFullScreen {}
- (void)setOffScreen:(void *)baseaddr width:(GLsizei)width height:(GLsizei)height rowbytes:(GLint)rowbytes {}
- (void)copyAttributesFromContext:(NSOpenGLContext *)context withMask:(GLbitfield)mask {}
- (void *)CGLContextObjForThread { return _context; }
- (void)createTexture:(GLenum)target fromView:(NSView *)view internalFormat:(GLenum)format {}
- (void)setPixelBuffer:(id)pixelBuffer cubeMapFace:(GLenum)face mipMapLevel:(GLint)level currentVirtualScreen:(GLint)screen {}
- (id)pixelBuffer { return nil; }
- (GLenum)pixelBufferCubeMapFace { return 0; }
- (GLint)pixelBufferMipMapLevel { return 0; }
- (void)setTextureImageToPixelBuffer:(id)pixelBuffer colorBuffer:(GLenum)source {}

@end

#pragma mark - Views

@implementation NSOpenGLView {
    NSOpenGLPixelFormat *_pixelFormat;
    NSOpenGLContext *_context;
    BOOL _prepared;
    NSSize _drawnSize;
}

+ (NSOpenGLPixelFormat *)defaultPixelFormat
{
    NSOpenGLPixelFormatAttribute attrs[] = {NSOpenGLPFAColorSize, 24, NSOpenGLPFADepthSize, 16, 0};
    return [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];
}

- (instancetype)initWithFrame:(NSRect)frameRect pixelFormat:(NSOpenGLPixelFormat *)format
{
    if ((self = [super initWithFrame:frameRect]))
        _pixelFormat = [format retain];
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    return [self initWithFrame:frameRect pixelFormat:[[self class] defaultPixelFormat]];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _pixelFormat = [[coder decodeObjectForKey:@"NSPixelFormat"] retain];
        if (!_pixelFormat)
            _pixelFormat = [[[self class] defaultPixelFormat] retain];
    }
    return self;
}

- (void)dealloc
{
    [_context clearDrawable];
    [_context release];
    [_pixelFormat release];
    [super dealloc];
}

- (NSOpenGLPixelFormat *)pixelFormat { return _pixelFormat; }
- (void)setPixelFormat:(NSOpenGLPixelFormat *)f
{
    [_pixelFormat autorelease];
    _pixelFormat = [f retain];
}

- (NSOpenGLContext *)openGLContext
{
    if (!_context && _pixelFormat) {
        _context = [[NSOpenGLContext alloc] initWithFormat:_pixelFormat shareContext:nil];
        [_context setView:self];
    }
    return _context;
}

- (void)setOpenGLContext:(NSOpenGLContext *)context
{
    if (context == _context)
        return;
    [_context clearDrawable];
    [_context release];
    _context = [context retain];
    [_context setView:self];
    _prepared = NO;
}

- (void)clearGLContext
{
    [_context clearDrawable];
    [_context release];
    _context = nil;
    _prepared = NO;
}

- (void)update { [_context update]; }
- (void)reshape {}
- (void)prepareOpenGL {}
- (BOOL)isOpaque { return YES; }

/* (before each -drawRect:, as Apple's lockFocus does: the context current on the view's
   drawable, prepared once, reshaped when the size changes) */
- (void)_finchPrepareToDraw
{
    NSOpenGLContext *c = [self openGLContext];
    if (!c)
        return;
    if ([c view] != self)
        [c setView:self];
    [c makeCurrentContext];
    if (!_prepared) {
        _prepared = YES;
        [self prepareOpenGL];
    }
    NSSize size = [self bounds].size;
    if (!NSEqualSizes(size, _drawnSize)) {
        _drawnSize = size;
        [c update];
        [self reshape];
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    if (_context)
        [_context update];
}

- (void)lockFocus
{
    [super lockFocus];
    [self _finchPrepareToDraw];
}

@end

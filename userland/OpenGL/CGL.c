/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGL, Finch's: pixel formats, renderers and contexts over Mesa's software renderer
 * (OSMesa with softpipe, in Libraries/libGL.dylib). One renderer is offered, the
 * software one (SOFTWARE_RENDERER, as Apple's software renderer reports
 * itself). A context draws into its own memory buffer, top row first, 8-bit BGRA, sized
 * by its drawable (a view, through AppKit's NSOpenGLContext, which reads the pixels on
 * CGLFlushDrawable); without one, apps draw into framebuffer objects. As Apple's on
 * Apple silicon, CGLSetOffScreen isn't offered. The context made current per thread is
 * the one gl* calls go to. CGLMacro's direct dispatch through the context isn't
 * supported: apps calling gl* functions work.
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* (Mesa's OSMesa interface, declared here: its header expects GL/gl.h) */
typedef struct osmesa_context *OSMesaContext;
#define OSMESA_BGRA 0x1
#define OSMESA_ROW_LENGTH 0x10
#define OSMESA_Y_UP 0x11
#define OSMESA_DEPTH_BITS 0x30
#define OSMESA_STENCIL_BITS 0x31
#define OSMESA_ACCUM_BITS 0x32
#define OSMESA_PROFILE 0x33
#define OSMESA_CORE_PROFILE 0x34
#define OSMESA_COMPAT_PROFILE 0x35
#define OSMESA_CONTEXT_MAJOR_VERSION 0x36
#define OSMESA_CONTEXT_MINOR_VERSION 0x37
#define OSMESA_FORMAT 0x22
extern OSMesaContext OSMesaCreateContextAttribs(const int *attribList, OSMesaContext sharelist);
extern void OSMesaDestroyContext(OSMesaContext ctx);
extern GLboolean OSMesaMakeCurrent(OSMesaContext ctx, void *buffer, GLenum type, GLsizei width, GLsizei height);
extern void OSMesaPixelStore(GLint pname, GLint value);

#define FINCH_EXPORT __attribute__((visibility("default")))

/* Apple's software renderer's ID, as its CGL reports it */
#define SOFTWARE_RENDERER 0x1020400

struct _CGLPixelFormatObject {
    unsigned refs;
    GLint colorSize, alphaSize, depthSize, stencilSize, accumSize, samples, profile;
    bool doubleBuffer, accelerated, offScreen, stereo;
};

struct _CGLContextObject {
    unsigned refs;
    pthread_mutex_t lock;
    CGLPixelFormatObj pixelFormat;
    OSMesaContext mesa;
    uint8_t *pixels;
    GLsizei width, height;
    GLint rowBytes;
    bool external; /* pixels the app gave (CGLSetOffScreen) */
    GLint swapInterval, surfaceOpacity, surfaceOrder, virtualScreen;
    GLint backingSize[2];
    bool backingSizeEnabled;
    void (*flush)(CGLContextObj ctx, void *info);
    void *flushInfo;
};

static pthread_key_t current_key;
static pthread_once_t current_once = PTHREAD_ONCE_INIT;

static void
make_key(void)
{
    pthread_key_create(&current_key, NULL);
}

#pragma mark - Pixel formats

FINCH_EXPORT CGLError
CGLChoosePixelFormat(const CGLPixelFormatAttribute *attribs, CGLPixelFormatObj *pix, GLint *npix)
{
    if (!pix)
        return kCGLBadAddress;
    *pix = NULL;
    if (npix)
        *npix = 0;
    struct _CGLPixelFormatObject f = {1, 24, 8, 0, 0, 0, 0, kCGLOGLPVersion_Legacy, false, true, false, false};
    for (const CGLPixelFormatAttribute *a = attribs; a && *a; a++) {
        switch (*a) {
        case kCGLPFADoubleBuffer: f.doubleBuffer = true; break;
        case kCGLPFAStereo: f.stereo = true; break;
        case kCGLPFAAccelerated: f.accelerated = true; break;
        case kCGLPFAOffScreen: f.offScreen = true; break;
        case kCGLPFAColorSize: f.colorSize = *++a; break;
        case kCGLPFAAlphaSize: f.alphaSize = *++a; break;
        case kCGLPFADepthSize: f.depthSize = *++a; break;
        case kCGLPFAStencilSize: f.stencilSize = *++a; break;
        case kCGLPFAAccumSize: f.accumSize = *++a; break;
        case kCGLPFASamples: f.samples = *++a; break;
        case kCGLPFAOpenGLProfile: f.profile = *++a; break;
        /* (attributes with a value Finch doesn't use) */
        case kCGLPFAAuxBuffers:
        case kCGLPFAMinimumPolicy:
        case kCGLPFAMaximumPolicy:
        case kCGLPFASampleBuffers:
        case kCGLPFARendererID:
        case kCGLPFADisplayMask:
        case kCGLPFAVirtualScreenCount:
        case kCGLPFASampleAlpha:
            a++;
            break;
        default: break;
        }
    }
    if (f.stereo)
        return kCGLBadAttribute;
    struct _CGLPixelFormatObject *p = malloc(sizeof *p);
    *p = f;
    *pix = p;
    if (npix)
        *npix = 1;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLDestroyPixelFormat(CGLPixelFormatObj pix)
{
    if (pix)
        CGLReleasePixelFormat(pix);
    return kCGLNoError;
}

FINCH_EXPORT CGLPixelFormatObj
CGLRetainPixelFormat(CGLPixelFormatObj pix)
{
    if (pix)
        __atomic_add_fetch(&pix->refs, 1, __ATOMIC_RELAXED);
    return pix;
}

FINCH_EXPORT void
CGLReleasePixelFormat(CGLPixelFormatObj pix)
{
    if (pix && __atomic_sub_fetch(&pix->refs, 1, __ATOMIC_ACQ_REL) == 0)
        free(pix);
}

FINCH_EXPORT GLuint
CGLGetPixelFormatRetainCount(CGLPixelFormatObj pix)
{
    return pix ? pix->refs : 0;
}

FINCH_EXPORT CGLError
CGLDescribePixelFormat(CGLPixelFormatObj pix, GLint pix_num, CGLPixelFormatAttribute attrib, GLint *value)
{
    if (!pix || !value)
        return kCGLBadAddress;
    if (pix_num != 0)
        return kCGLBadPixelFormat;
    switch (attrib) {
    case kCGLPFADoubleBuffer: *value = pix->doubleBuffer; break;
    case kCGLPFAStereo: *value = 0; break;
    case kCGLPFAColorSize: *value = pix->colorSize ? pix->colorSize : 24; break;
    case kCGLPFAAlphaSize: *value = pix->alphaSize; break;
    case kCGLPFADepthSize: *value = pix->depthSize; break;
    case kCGLPFAStencilSize: *value = pix->stencilSize; break;
    case kCGLPFAAccumSize: *value = pix->accumSize; break;
    case kCGLPFASamples: *value = pix->samples; break;
    case kCGLPFASampleBuffers: *value = pix->samples > 0; break;
    case kCGLPFAAccelerated: *value = 0; break;
    case kCGLPFAOffScreen: *value = pix->offScreen; break;
    case kCGLPFAOpenGLProfile: *value = pix->profile; break;
    case kCGLPFARendererID: *value = SOFTWARE_RENDERER; break;
    case kCGLPFAVirtualScreenCount: *value = 1; break;
    case kCGLPFADisplayMask: *value = 1; break;
    case kCGLPFANoRecovery: *value = 1; break;
    case kCGLPFAWindow: *value = !pix->offScreen; break;
    default: *value = 0; break;
    }
    return kCGLNoError;
}

#pragma mark - Renderers

struct _CGLRendererInfoObject {
    int unused;
};

FINCH_EXPORT CGLError
CGLQueryRendererInfo(GLuint display_mask, CGLRendererInfoObj *rend, GLint *nrend)
{
    if (!rend || !nrend)
        return kCGLBadAddress;
    *rend = calloc(1, sizeof(struct _CGLRendererInfoObject));
    *nrend = 1;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLDestroyRendererInfo(CGLRendererInfoObj rend)
{
    free(rend);
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLDescribeRenderer(CGLRendererInfoObj rend, GLint rend_num, CGLRendererProperty prop, GLint *value)
{
    if (!rend || !value)
        return kCGLBadAddress;
    if (rend_num != 0)
        return kCGLBadRendererInfo;
    switch (prop) {
    case kCGLRPRendererID: *value = SOFTWARE_RENDERER; break;
    case kCGLRPDisplayMask: *value = 1; break;
    case kCGLRPOnline: *value = 1; break;
    case kCGLRPAccelerated: *value = 0; break;
    case kCGLRPCompliant: *value = 1; break;
    case kCGLRPWindow: *value = 1; break;
    case kCGLRPOffScreen: *value = 1; break;
    case kCGLRPBufferModes: *value = kCGLSingleBufferBit | kCGLDoubleBufferBit; break;
    case kCGLRPColorModes: *value = kCGLARGB8888Bit | kCGLRGB888Bit; break;
    case kCGLRPDepthModes: *value = kCGL0Bit | kCGL16Bit | kCGL24Bit | kCGL32Bit; break;
    case kCGLRPStencilModes: *value = kCGL0Bit | kCGL8Bit; break;
    case kCGLRPMaxAuxBuffers: *value = 0; break;
    case kCGLRPMaxSampleBuffers: *value = 0; break;
    case kCGLRPMaxSamples: *value = 0; break;
    case kCGLRPVideoMemoryMegabytes:
    case kCGLRPTextureMemoryMegabytes: *value = 512; break;
    case kCGLRPMajorGLVersion: *value = 3; break;
    default: *value = 0; break;
    }
    return kCGLNoError;
}

#pragma mark - Contexts

FINCH_EXPORT CGLError
CGLCreateContext(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *ctx)
{
    if (!pix || !ctx)
        return kCGLBadAddress;
    *ctx = NULL;
    bool core = pix->profile == kCGLOGLPVersion_3_2_Core || pix->profile == kCGLOGLPVersion_GL3_Core ||
                pix->profile == kCGLOGLPVersion_GL4_Core;
    int attribs[] = {OSMESA_FORMAT,       OSMESA_BGRA,
                     OSMESA_DEPTH_BITS,   pix->depthSize > 0 ? (pix->depthSize > 24 ? 32 : 24) : 0,
                     OSMESA_STENCIL_BITS, pix->stencilSize > 0 ? 8 : 0,
                     OSMESA_ACCUM_BITS,   pix->accumSize > 0 ? 16 : 0,
                     OSMESA_PROFILE,      core ? OSMESA_CORE_PROFILE : OSMESA_COMPAT_PROFILE,
                     OSMESA_CONTEXT_MAJOR_VERSION, core ? (pix->profile == kCGLOGLPVersion_3_2_Core ? 3 : 4) : 2,
                     OSMESA_CONTEXT_MINOR_VERSION, core ? (pix->profile == kCGLOGLPVersion_3_2_Core ? 2 : 1) : 1,
                     0};
    OSMesaContext m = OSMesaCreateContextAttribs(attribs, share ? share->mesa : NULL);
    if (!m && core) {
        attribs[11] = 3, attribs[13] = 3;
        m = OSMesaCreateContextAttribs(attribs, share ? share->mesa : NULL);
    }
    if (!m)
        return kCGLBadPixelFormat;
    struct _CGLContextObject *c = calloc(1, sizeof *c);
    c->refs = 1;
    pthread_mutex_init(&c->lock, NULL);
    c->pixelFormat = CGLRetainPixelFormat(pix);
    c->mesa = m;
    c->surfaceOpacity = 1;
    *ctx = c;
    return kCGLNoError;
}

static void
destroy_context(CGLContextObj ctx)
{
    if (CGLGetCurrentContext() == ctx)
        CGLSetCurrentContext(NULL);
    OSMesaDestroyContext(ctx->mesa);
    if (!ctx->external)
        free(ctx->pixels);
    CGLReleasePixelFormat(ctx->pixelFormat);
    pthread_mutex_destroy(&ctx->lock);
    free(ctx);
}

FINCH_EXPORT CGLError
CGLDestroyContext(CGLContextObj ctx)
{
    if (ctx)
        CGLReleaseContext(ctx);
    return kCGLNoError;
}

FINCH_EXPORT CGLContextObj
CGLRetainContext(CGLContextObj ctx)
{
    if (ctx)
        __atomic_add_fetch(&ctx->refs, 1, __ATOMIC_RELAXED);
    return ctx;
}

FINCH_EXPORT void
CGLReleaseContext(CGLContextObj ctx)
{
    if (ctx && __atomic_sub_fetch(&ctx->refs, 1, __ATOMIC_ACQ_REL) == 0)
        destroy_context(ctx);
}

FINCH_EXPORT GLuint
CGLGetContextRetainCount(CGLContextObj ctx)
{
    return ctx ? ctx->refs : 0;
}

FINCH_EXPORT CGLPixelFormatObj
CGLGetPixelFormat(CGLContextObj ctx)
{
    return ctx ? ctx->pixelFormat : NULL;
}

/* (bind the context to its pixels; a context with none yet has a 1x1 buffer) */
static void
bind(CGLContextObj ctx)
{
    if (!ctx->pixels) {
        ctx->width = ctx->height = 1;
        ctx->rowBytes = 4;
        ctx->pixels = calloc(1, 4);
    }
    OSMesaMakeCurrent(ctx->mesa, ctx->pixels, GL_UNSIGNED_BYTE, ctx->width, ctx->height);
    OSMesaPixelStore(OSMESA_ROW_LENGTH, ctx->rowBytes / 4);
    OSMesaPixelStore(OSMESA_Y_UP, 0);
}

FINCH_EXPORT CGLError
CGLSetCurrentContext(CGLContextObj ctx)
{
    pthread_once(&current_once, make_key);
    pthread_setspecific(current_key, ctx);
    if (ctx)
        bind(ctx);
    else
        OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
    return kCGLNoError;
}

FINCH_EXPORT CGLContextObj
CGLGetCurrentContext(void)
{
    pthread_once(&current_once, make_key);
    return pthread_getspecific(current_key);
}

FINCH_EXPORT CGLError
CGLCopyContext(CGLContextObj src, CGLContextObj dst, GLbitfield mask)
{
    return src && dst ? kCGLNoError : kCGLBadContext;
}

FINCH_EXPORT CGLError
CGLLockContext(CGLContextObj ctx)
{
    if (!ctx)
        return kCGLBadContext;
    pthread_mutex_lock(&ctx->lock);
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLUnlockContext(CGLContextObj ctx)
{
    if (!ctx)
        return kCGLBadContext;
    pthread_mutex_unlock(&ctx->lock);
    return kCGLNoError;
}

#pragma mark - Drawables

/* (Finch's: a drawable of a size, the pixels it owns, and who to tell when it's flushed;
   AppKit's NSOpenGLContext uses it for a view) */
FINCH_EXPORT CGLError
FinchCGLSetDrawable(CGLContextObj ctx, GLsizei width, GLsizei height, void (*flush)(CGLContextObj, void *), void *info)
{
    if (!ctx)
        return kCGLBadContext;
    if (width < 1)
        width = 1;
    if (height < 1)
        height = 1;
    if (ctx->external || width != ctx->width || height != ctx->height || !ctx->pixels) {
        if (!ctx->external)
            free(ctx->pixels);
        ctx->pixels = calloc((size_t)width * height, 4);
        ctx->width = width, ctx->height = height;
        ctx->rowBytes = width * 4;
        ctx->external = false;
    }
    ctx->flush = flush;
    ctx->flushInfo = info;
    if (CGLGetCurrentContext() == ctx)
        bind(ctx);
    return kCGLNoError;
}

/* (the drawable's pixels: 8-bit BGRA, top row first) */
FINCH_EXPORT const void *
FinchCGLGetPixels(CGLContextObj ctx, GLsizei *width, GLsizei *height, GLint *rowBytes)
{
    if (!ctx)
        return NULL;
    if (width)
        *width = ctx->width;
    if (height)
        *height = ctx->height;
    if (rowBytes)
        *rowBytes = ctx->rowBytes;
    return ctx->pixels;
}

/* (as Apple's on Apple silicon: off-screen contexts in app memory aren't offered; apps use
   framebuffer objects) */
FINCH_EXPORT CGLError
CGLSetOffScreen(CGLContextObj ctx, GLsizei width, GLsizei height, GLint rowbytes, void *baseaddr)
{
    return ctx ? kCGLBadOffScreen : kCGLBadContext;
}

FINCH_EXPORT CGLError
CGLGetOffScreen(CGLContextObj ctx, GLsizei *width, GLsizei *height, GLint *rowbytes, void **baseaddr)
{
    if (!ctx)
        return kCGLBadContext;
    if (width)
        *width = ctx->external ? ctx->width : 0;
    if (height)
        *height = ctx->external ? ctx->height : 0;
    if (rowbytes)
        *rowbytes = ctx->external ? ctx->rowBytes : 0;
    if (baseaddr)
        *baseaddr = ctx->external ? ctx->pixels : NULL;
    return kCGLNoError;
}

FINCH_EXPORT CGLError CGLSetFullScreen(CGLContextObj ctx) { return kCGLBadMatch; }
FINCH_EXPORT CGLError CGLSetFullScreenOnDisplay(CGLContextObj ctx, GLuint display_mask) { return kCGLBadMatch; }

FINCH_EXPORT CGLError
CGLClearDrawable(CGLContextObj ctx)
{
    if (!ctx)
        return kCGLBadContext;
    ctx->flush = NULL;
    ctx->flushInfo = NULL;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLFlushDrawable(CGLContextObj ctx)
{
    if (!ctx)
        return kCGLBadContext;
    if (CGLGetCurrentContext() == ctx)
        glFinish();
    if (ctx->flush)
        ctx->flush(ctx, ctx->flushInfo);
    return kCGLNoError;
}

FINCH_EXPORT CGLError CGLUpdateContext(CGLContextObj ctx) { return ctx ? kCGLNoError : kCGLBadContext; }

#pragma mark - Options

FINCH_EXPORT CGLError
CGLEnable(CGLContextObj ctx, CGLContextEnable pname)
{
    if (!ctx)
        return kCGLBadContext;
    if (pname == kCGLCESurfaceBackingSize)
        ctx->backingSizeEnabled = true;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLDisable(CGLContextObj ctx, CGLContextEnable pname)
{
    if (!ctx)
        return kCGLBadContext;
    if (pname == kCGLCESurfaceBackingSize)
        ctx->backingSizeEnabled = false;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLIsEnabled(CGLContextObj ctx, CGLContextEnable pname, GLint *enable)
{
    if (!ctx || !enable)
        return kCGLBadAddress;
    *enable = pname == kCGLCESurfaceBackingSize ? ctx->backingSizeEnabled : 0;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLSetParameter(CGLContextObj ctx, CGLContextParameter pname, const GLint *params)
{
    if (!ctx)
        return kCGLBadContext;
    if (!params)
        return kCGLBadAddress;
    switch (pname) {
    case kCGLCPSwapInterval: ctx->swapInterval = params[0]; break;
    case kCGLCPSurfaceOpacity: ctx->surfaceOpacity = params[0]; break;
    case kCGLCPSurfaceOrder: ctx->surfaceOrder = params[0]; break;
    case kCGLCPSurfaceBackingSize: ctx->backingSize[0] = params[0], ctx->backingSize[1] = params[1]; break;
    default: break;
    }
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLGetParameter(CGLContextObj ctx, CGLContextParameter pname, GLint *params)
{
    if (!ctx)
        return kCGLBadContext;
    if (!params)
        return kCGLBadAddress;
    switch (pname) {
    case kCGLCPSwapInterval: params[0] = ctx->swapInterval; break;
    case kCGLCPSurfaceOpacity: params[0] = ctx->surfaceOpacity; break;
    case kCGLCPSurfaceOrder: params[0] = ctx->surfaceOrder; break;
    case kCGLCPSurfaceBackingSize: params[0] = ctx->backingSize[0], params[1] = ctx->backingSize[1]; break;
    case kCGLCPCurrentRendererID: params[0] = SOFTWARE_RENDERER; break;
    case kCGLCPGPUVertexProcessing:
    case kCGLCPGPUFragmentProcessing: params[0] = 0; break;
    case kCGLCPHasDrawable: params[0] = ctx->flush != NULL; break;
    default: params[0] = 0; break;
    }
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLSetVirtualScreen(CGLContextObj ctx, GLint screen)
{
    if (!ctx)
        return kCGLBadContext;
    if (screen != 0)
        return kCGLBadValue;
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLGetVirtualScreen(CGLContextObj ctx, GLint *screen)
{
    if (!ctx || !screen)
        return kCGLBadAddress;
    *screen = 0;
    return kCGLNoError;
}

static GLint global_options[16];

FINCH_EXPORT CGLError
CGLSetGlobalOption(CGLGlobalOption pname, const GLint *params)
{
    if ((unsigned)pname < 16 && params)
        global_options[pname] = params[0];
    return kCGLNoError;
}

FINCH_EXPORT CGLError
CGLGetGlobalOption(CGLGlobalOption pname, GLint *params)
{
    if (!params)
        return kCGLBadAddress;
    params[0] = (unsigned)pname < 16 ? global_options[pname] : 0;
    return kCGLNoError;
}

FINCH_EXPORT CGLError CGLSetOption(CGLGlobalOption pname, GLint param) { return CGLSetGlobalOption(pname, &param); }
FINCH_EXPORT CGLError CGLGetOption(CGLGlobalOption pname, GLint *param) { return CGLGetGlobalOption(pname, param); }

FINCH_EXPORT void
CGLGetVersion(GLint *majorvers, GLint *minorvers)
{
    if (majorvers)
        *majorvers = 1;
    if (minorvers)
        *minorvers = 2;
}

FINCH_EXPORT const char *
CGLErrorString(CGLError error)
{
    switch (error) {
    case kCGLNoError: return "no error";
    case kCGLBadAttribute: return "invalid pixel format attribute";
    case kCGLBadProperty: return "invalid renderer property";
    case kCGLBadPixelFormat: return "invalid pixel format";
    case kCGLBadRendererInfo: return "invalid renderer info";
    case kCGLBadContext: return "invalid context";
    case kCGLBadDrawable: return "invalid drawable";
    case kCGLBadDisplay: return "invalid graphics device";
    case kCGLBadState: return "invalid context state";
    case kCGLBadValue: return "invalid numerical value";
    case kCGLBadMatch: return "invalid share context";
    case kCGLBadEnumeration: return "invalid enumerant";
    case kCGLBadOffScreen: return "invalid offscreen drawable";
    case kCGLBadFullScreen: return "invalid fullscreen drawable";
    case kCGLBadWindow: return "invalid window";
    case kCGLBadAddress: return "invalid pointer";
    case kCGLBadCodeModule: return "invalid code module";
    case kCGLBadAlloc: return "invalid memory allocation";
    case kCGLBadConnection: return "invalid CoreGraphics connection";
    default: return "unknown error";
    }
}

#pragma mark - Pixel buffers and share groups (not offered)

FINCH_EXPORT CGLError
CGLCreatePBuffer(GLsizei width, GLsizei height, GLenum target, GLenum internalFormat, GLint max_level, CGLPBufferObj *pbuffer)
{
    if (pbuffer)
        *pbuffer = NULL;
    return kCGLBadAlloc;
}
FINCH_EXPORT CGLError CGLDestroyPBuffer(CGLPBufferObj pbuffer) { return kCGLNoError; }
FINCH_EXPORT CGLError
CGLDescribePBuffer(CGLPBufferObj obj, GLsizei *width, GLsizei *height, GLenum *target, GLenum *internalFormat, GLint *mipmap)
{
    return kCGLBadAddress;
}
FINCH_EXPORT CGLError CGLTexImagePBuffer(CGLContextObj ctx, CGLPBufferObj pbuffer, GLenum source) { return kCGLBadAddress; }
FINCH_EXPORT CGLPBufferObj CGLRetainPBuffer(CGLPBufferObj pbuffer) { return pbuffer; }
FINCH_EXPORT void CGLReleasePBuffer(CGLPBufferObj pbuffer) {}
FINCH_EXPORT GLuint CGLGetPBufferRetainCount(CGLPBufferObj pbuffer) { return 0; }
FINCH_EXPORT CGLError CGLSetPBuffer(CGLContextObj ctx, CGLPBufferObj pbuffer, GLenum face, GLint level, GLint screen) { return kCGLBadAddress; }
FINCH_EXPORT CGLError
CGLGetPBuffer(CGLContextObj ctx, CGLPBufferObj *pbuffer, GLenum *face, GLint *level, GLint *screen)
{
    if (pbuffer)
        *pbuffer = NULL;
    return kCGLNoError;
}
FINCH_EXPORT CGLShareGroupObj CGLGetShareGroup(CGLContextObj ctx) { return (CGLShareGroupObj)ctx; }

FINCH_EXPORT CGLError
CGLTexImageIOSurface2D(CGLContextObj ctx, GLenum target, GLenum internal_format, GLsizei width, GLsizei height, GLenum format,
                       GLenum type, IOSurfaceRef ioSurface, GLuint plane)
{
    return kCGLBadValue;
}

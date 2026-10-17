/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreVideo's legacy OpenGL buffers and textures, backed by IOSurface and CGL. */
#include "CVInternal.h"
#include <CoreVideo/CVOpenGLBuffer.h>
#include <CoreVideo/CVOpenGLBufferPool.h>
#include <CoreVideo/CVOpenGLTexture.h>
#include <CoreVideo/CVOpenGLTextureCache.h>
#include <IOSurface/IOSurface.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <limits.h>

typedef struct {
    FinchCVBuffer cv;
    size_t width, height;
    CFDictionaryRef attributes;
    IOSurfaceRef surface;
} GLBuffer;

typedef struct {
    CFRuntimeBase base;
    CFDictionaryRef attributes;
    CFDictionaryRef bufferAttributes;
} GLBufferPool;

typedef struct {
    CFRuntimeBase base;
    CGLContextObj context;
    CGLPixelFormatObj pixelFormat;
    CFDictionaryRef attributes;
    CFDictionaryRef textureAttributes;
} GLTextureCache;

typedef struct {
    FinchCVBuffer cv;
    CGLContextObj context;
    IOSurfaceRef surface;
    CVImageBufferRef source;
    size_t width, height;
    GLuint name;
    GLenum target;
    Boolean flipped;
} GLTexture;

static void
buffer_finalize(CFTypeRef object)
{
    GLBuffer *buffer = (GLBuffer *)object;
    if (buffer->surface) CFRelease(buffer->surface);
    if (buffer->attributes) CFRelease(buffer->attributes);
    _FinchCVBufferFinalize(&buffer->cv);
}

static void
pool_finalize(CFTypeRef object)
{
    GLBufferPool *pool = (GLBufferPool *)object;
    if (pool->attributes) CFRelease(pool->attributes);
    if (pool->bufferAttributes) CFRelease(pool->bufferAttributes);
}

static void
cache_finalize(CFTypeRef object)
{
    GLTextureCache *cache = (GLTextureCache *)object;
    if (cache->context) CGLReleaseContext(cache->context);
    if (cache->pixelFormat) CGLReleasePixelFormat(cache->pixelFormat);
    if (cache->attributes) CFRelease(cache->attributes);
    if (cache->textureAttributes) CFRelease(cache->textureAttributes);
}

static void
texture_finalize(CFTypeRef object)
{
    GLTexture *texture = (GLTexture *)object;
    if (texture->name && texture->context) {
        CGLContextObj previous = CGLGetCurrentContext();
        CGLLockContext(texture->context);
        if (CGLSetCurrentContext(texture->context) == kCGLNoError)
            glDeleteTextures(1, &texture->name);
        CGLSetCurrentContext(previous);
        CGLUnlockContext(texture->context);
    }
    if (texture->context) CGLReleaseContext(texture->context);
    if (texture->surface) CFRelease(texture->surface);
    if (texture->source) CFRelease(texture->source);
    _FinchCVBufferFinalize(&texture->cv);
}

CV_DEFINE_TYPE(CVOpenGLBufferGetTypeID, "CVOpenGLBuffer", buffer_finalize, NULL)
CV_DEFINE_TYPE(CVOpenGLBufferPoolGetTypeID, "CVOpenGLBufferPool", pool_finalize, NULL)
CV_DEFINE_TYPE(CVOpenGLTextureCacheGetTypeID, "CVOpenGLTextureCache", cache_finalize, NULL)
CV_DEFINE_TYPE(CVOpenGLTextureGetTypeID, "CVOpenGLTexture", texture_finalize, NULL)

static CFDictionaryRef
copy_dictionary(CFAllocatorRef allocator, CFDictionaryRef dictionary)
{
    return dictionary ? CFDictionaryCreateCopy(allocator, dictionary) : NULL;
}

static size_t
number_value(CFDictionaryRef dictionary, CFStringRef key, size_t fallback)
{
    CFTypeRef value = dictionary ? CFDictionaryGetValue(dictionary, key) : NULL;
    long long number = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(value, kCFNumberLongLongType, &number) || number < 0)
        return fallback;
    return (size_t)number;
}

static Boolean
boolean_value(CFDictionaryRef dictionary, CFStringRef key)
{
    CFTypeRef value = dictionary ? CFDictionaryGetValue(dictionary, key) : NULL;
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
}

CVOpenGLBufferRef
CVOpenGLBufferRetain(CVOpenGLBufferRef buffer)
{
    return buffer ? (CVOpenGLBufferRef)CFRetain(buffer) : NULL;
}

void
CVOpenGLBufferRelease(CVOpenGLBufferRef buffer)
{
    if (buffer) CFRelease(buffer);
}

CVReturn
CVOpenGLBufferCreate(CFAllocatorRef allocator, size_t width, size_t height, CFDictionaryRef attributes,
                     CVOpenGLBufferRef *bufferOut)
{
    (void)allocator;
    (void)attributes;
    if (!bufferOut)
        return kCVReturnInvalidArgument;
    *bufferOut = NULL;
    if (!width || !height || width > INT_MAX || height > INT_MAX)
        return kCVReturnInvalidArgument;
    return kCVReturnError;
}

CFDictionaryRef
CVOpenGLBufferGetAttributes(CVOpenGLBufferRef buffer)
{
    return buffer && CFGetTypeID(buffer) == CVOpenGLBufferGetTypeID() ? ((GLBuffer *)buffer)->attributes : NULL;
}

CVReturn
CVOpenGLBufferAttach(CVOpenGLBufferRef object, CGLContextObj context, GLenum face, GLint level, GLint screen)
{
    if (!object || CFGetTypeID(object) != CVOpenGLBufferGetTypeID() || !context || level < 0 || screen < 0)
        return kCVReturnInvalidArgument;
    GLBuffer *buffer = (GLBuffer *)object;
    GLenum target = (GLenum)number_value(buffer->attributes, kCVOpenGLBufferTarget, GL_TEXTURE_RECTANGLE_EXT);
    GLenum internal = (GLenum)number_value(buffer->attributes, kCVOpenGLBufferInternalFormat, GL_RGBA);
    if (face && target != GL_TEXTURE_CUBE_MAP)
        return kCVReturnInvalidArgument;
    CGLError error = CGLTexImageIOSurface2D(context, target, (GLint)internal, (GLsizei)buffer->width,
        (GLsizei)buffer->height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, buffer->surface, 0);
    return error == kCGLNoError ? kCVReturnSuccess : kCVReturnPixelBufferNotOpenGLCompatible;
}

CVOpenGLBufferPoolRef
CVOpenGLBufferPoolRetain(CVOpenGLBufferPoolRef pool)
{
    return pool ? (CVOpenGLBufferPoolRef)CFRetain(pool) : NULL;
}

void
CVOpenGLBufferPoolRelease(CVOpenGLBufferPoolRef pool)
{
    if (pool) CFRelease(pool);
}

CVReturn
CVOpenGLBufferPoolCreate(CFAllocatorRef allocator, CFDictionaryRef poolAttributes,
                         CFDictionaryRef bufferAttributes, CVOpenGLBufferPoolRef *poolOut)
{
    if (poolOut) *poolOut = NULL;
    if (!poolOut)
        return kCVReturnInvalidArgument;
    GLBufferPool *pool = (GLBufferPool *)cv_create(allocator, CVOpenGLBufferPoolGetTypeID(), sizeof(*pool));
    if (!pool)
        return kCVReturnAllocationFailed;
    pool->attributes = copy_dictionary(allocator, poolAttributes);
    pool->bufferAttributes = copy_dictionary(allocator, bufferAttributes);
    *poolOut = (CVOpenGLBufferPoolRef)pool;
    return kCVReturnSuccess;
}

CFDictionaryRef
CVOpenGLBufferPoolGetAttributes(CVOpenGLBufferPoolRef object)
{
    return object && CFGetTypeID(object) == CVOpenGLBufferPoolGetTypeID() ? ((GLBufferPool *)object)->attributes : NULL;
}

CFDictionaryRef
CVOpenGLBufferPoolGetOpenGLBufferAttributes(CVOpenGLBufferPoolRef object)
{
    return object && CFGetTypeID(object) == CVOpenGLBufferPoolGetTypeID() ? ((GLBufferPool *)object)->bufferAttributes : NULL;
}

CVReturn
CVOpenGLBufferPoolCreateOpenGLBuffer(CFAllocatorRef allocator, CVOpenGLBufferPoolRef object,
                                     CVOpenGLBufferRef *bufferOut)
{
    if (bufferOut) *bufferOut = NULL;
    if (!object || CFGetTypeID(object) != CVOpenGLBufferPoolGetTypeID() || !bufferOut)
        return kCVReturnInvalidArgument;
    (void)allocator;
    return kCVReturnError;
}

CVOpenGLTextureCacheRef
CVOpenGLTextureCacheRetain(CVOpenGLTextureCacheRef cache)
{
    return cache ? (CVOpenGLTextureCacheRef)CFRetain(cache) : NULL;
}

void
CVOpenGLTextureCacheRelease(CVOpenGLTextureCacheRef cache)
{
    if (cache) CFRelease(cache);
}

CVReturn
CVOpenGLTextureCacheCreate(CFAllocatorRef allocator, CFDictionaryRef attributes, CGLContextObj context,
                           CGLPixelFormatObj pixelFormat, CFDictionaryRef textureAttributes,
                           CVOpenGLTextureCacheRef *cacheOut)
{
    if (cacheOut) *cacheOut = NULL;
    if (!cacheOut || !context || !pixelFormat || CGLGetPixelFormat(context) != pixelFormat)
        return kCVReturnInvalidArgument;
    GLTextureCache *cache = (GLTextureCache *)cv_create(allocator, CVOpenGLTextureCacheGetTypeID(), sizeof(*cache));
    if (!cache)
        return kCVReturnAllocationFailed;
    cache->context = CGLRetainContext(context);
    cache->pixelFormat = CGLRetainPixelFormat(pixelFormat);
    cache->attributes = copy_dictionary(allocator, attributes);
    cache->textureAttributes = copy_dictionary(allocator, textureAttributes);
    if (!cache->context || !cache->pixelFormat) {
        CFRelease(cache);
        return kCVReturnInvalidArgument;
    }
    *cacheOut = (CVOpenGLTextureCacheRef)cache;
    return kCVReturnSuccess;
}

static Boolean
pixel_buffer_surface(CVImageBufferRef image, IOSurfaceRef *surface)
{
    if (!image || CFGetTypeID(image) != CVPixelBufferGetTypeID())
        return false;
    *surface = CVPixelBufferGetIOSurface((CVPixelBufferRef)image);
    return *surface != NULL;
}

CVReturn
CVOpenGLTextureCacheCreateTextureFromImage(CFAllocatorRef allocator, CVOpenGLTextureCacheRef object,
                                           CVImageBufferRef source, CFDictionaryRef attributes,
                                           CVOpenGLTextureRef *textureOut)
{
    if (textureOut) *textureOut = NULL;
    if (!object || CFGetTypeID(object) != CVOpenGLTextureCacheGetTypeID() || !source || !textureOut)
        return kCVReturnInvalidArgument;
    IOSurfaceRef surface = NULL;
    if (!pixel_buffer_surface(source, &surface))
        return kCVReturnPixelBufferNotOpenGLCompatible;
    GLTextureCache *cache = (GLTextureCache *)object;
    size_t width = CVPixelBufferGetWidth((CVPixelBufferRef)source);
    size_t height = CVPixelBufferGetHeight((CVPixelBufferRef)source);
    GLenum target = (GLenum)number_value(attributes, kCVOpenGLBufferTarget, GL_TEXTURE_RECTANGLE_EXT);
    GLenum internal = (GLenum)number_value(attributes, kCVOpenGLBufferInternalFormat, GL_RGBA);
    GLuint name = 0;
    CGLContextObj previous = CGLGetCurrentContext();
    CGLLockContext(cache->context);
    CGLError cgl = CGLSetCurrentContext(cache->context);
    if (cgl == kCGLNoError) {
        glGenTextures(1, &name);
        glBindTexture(target, name);
        glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        cgl = CGLTexImageIOSurface2D(cache->context, target, (GLint)internal, (GLsizei)width,
            (GLsizei)height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surface, 0);
    }
    CGLSetCurrentContext(previous);
    CGLUnlockContext(cache->context);
    if (cgl != kCGLNoError || !name) {
        if (name) glDeleteTextures(1, &name);
        return kCVReturnPixelBufferNotOpenGLCompatible;
    }
    GLTexture *texture = (GLTexture *)cv_create(allocator, CVOpenGLTextureGetTypeID(), sizeof(*texture));
    if (!texture) {
        CGLContextObj prior = CGLGetCurrentContext();
        CGLSetCurrentContext(cache->context);
        glDeleteTextures(1, &name);
        CGLSetCurrentContext(prior);
        return kCVReturnAllocationFailed;
    }
    _FinchCVBufferInit(&texture->cv);
    texture->context = CGLRetainContext(cache->context);
    texture->surface = (IOSurfaceRef)CFRetain(surface);
    texture->source = (CVImageBufferRef)CFRetain(source);
    texture->width = width;
    texture->height = height;
    texture->name = name;
    texture->target = target;
    CFTypeRef flipped = attributes ? CFDictionaryGetValue(attributes, CFSTR("Flipped")) : NULL;
    texture->flipped = flipped ? boolean_value(attributes, CFSTR("Flipped")) : true;
    *textureOut = (CVOpenGLTextureRef)texture;
    return kCVReturnSuccess;
}

void
CVOpenGLTextureCacheFlush(CVOpenGLTextureCacheRef cache, CVOptionFlags options)
{
    (void)options;
    if (!cache || CFGetTypeID(cache) != CVOpenGLTextureCacheGetTypeID())
        return;
}

CVOpenGLTextureRef
CVOpenGLTextureRetain(CVOpenGLTextureRef texture)
{
    return texture ? (CVOpenGLTextureRef)CFRetain(texture) : NULL;
}

void
CVOpenGLTextureRelease(CVOpenGLTextureRef texture)
{
    if (texture) CFRelease(texture);
}

GLenum
CVOpenGLTextureGetTarget(CVOpenGLTextureRef object)
{
    return object && CFGetTypeID(object) == CVOpenGLTextureGetTypeID() ? ((GLTexture *)object)->target : 0;
}

GLuint
CVOpenGLTextureGetName(CVOpenGLTextureRef object)
{
    return object && CFGetTypeID(object) == CVOpenGLTextureGetTypeID() ? ((GLTexture *)object)->name : 0;
}

Boolean
CVOpenGLTextureIsFlipped(CVOpenGLTextureRef object)
{
    return object && CFGetTypeID(object) == CVOpenGLTextureGetTypeID() ? ((GLTexture *)object)->flipped : false;
}

void
CVOpenGLTextureGetCleanTexCoords(CVOpenGLTextureRef object, GLfloat lowerLeft[2], GLfloat lowerRight[2],
                                 GLfloat upperRight[2], GLfloat upperLeft[2])
{
    if (!object || CFGetTypeID(object) != CVOpenGLTextureGetTypeID())
        return;
    GLTexture *texture = (GLTexture *)object;
    GLfloat width = texture->target == GL_TEXTURE_RECTANGLE_EXT ? (GLfloat)texture->width : 1.0f;
    GLfloat height = texture->target == GL_TEXTURE_RECTANGLE_EXT ? (GLfloat)texture->height : 1.0f;
    if (texture->flipped) {
        if (lowerLeft) lowerLeft[0] = 0, lowerLeft[1] = height;
        if (lowerRight) lowerRight[0] = width, lowerRight[1] = height;
        if (upperRight) upperRight[0] = width, upperRight[1] = 0;
        if (upperLeft) upperLeft[0] = 0, upperLeft[1] = 0;
    } else {
        if (lowerLeft) lowerLeft[0] = 0, lowerLeft[1] = 0;
        if (lowerRight) lowerRight[0] = width, lowerRight[1] = 0;
        if (upperRight) upperRight[0] = width, upperRight[1] = height;
        if (upperLeft) upperLeft[0] = 0, upperLeft[1] = height;
    }
}

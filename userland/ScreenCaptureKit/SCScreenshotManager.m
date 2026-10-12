/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Screenshots: a filter's content (or a rect of the screen) captured once, as an image,
 * a sample buffer or a screenshot output (written to a file when one is given, as HEIC,
 * PNG or JPEG through ImageIO). As Apple's, a screenshot configuration's zero size is the
 * content's own size in pixels, and its null rects are all of it. Finch has no HDR yet:
 * an HDR screenshot is the SDR pixels in extended sRGB.
 */
#import "SCInternal.h"
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation SCScreenshotConfiguration {
    UTType *_contentType;
    NSURL *_fileURL;
}

@synthesize width = _width, height = _height, showsCursor = _showsCursor, sourceRect = _sourceRect,
            destinationRect = _destinationRect, ignoreShadows = _ignoreShadows, ignoreClipping = _ignoreClipping,
            includeChildWindows = _includeChildWindows, displayIntent = _displayIntent, dynamicRange = _dynamicRange;

- (instancetype)init
{
    if ((self = [super init])) {
        _showsCursor = YES;
        _sourceRect = CGRectNull;
        _destinationRect = CGRectNull;
        _ignoreShadows = YES;
        _includeChildWindows = YES;
        _contentType = [UTTypeHEIC retain];
    }
    return self;
}

- (void)dealloc
{
    [_contentType release];
    [_fileURL release];
    [super dealloc];
}

- (UTType *)contentType { return _contentType; }
- (void)setContentType:(UTType *)type
{
    [_contentType autorelease];
    _contentType = [type retain];
}

- (NSURL *)fileURL { return _fileURL; }
- (void)setFileURL:(NSURL *)url
{
    [_fileURL autorelease];
    _fileURL = [url retain];
}

+ (NSArray<UTType *> *)supportedContentTypes { return @[ UTTypeHEIC, UTTypePNG, UTTypeJPEG ]; }

@end

@implementation SCScreenshotOutput {
    CGImageRef _sdr, _hdr;
    NSURL *_fileURL; /* not retained, as Apple's (assign) */
}

- (void)dealloc
{
    CGImageRelease(_sdr);
    CGImageRelease(_hdr);
    [super dealloc];
}

- (CGImageRef)sdrImage { return _sdr; }
- (void)setSdrImage:(CGImageRef)image
{
    CGImageRetain(image);
    CGImageRelease(_sdr);
    _sdr = image;
}
- (CGImageRef)hdrImage { return _hdr; }
- (void)setHdrImage:(CGImageRef)image
{
    CGImageRetain(image);
    CGImageRelease(_hdr);
    _hdr = image;
}
- (NSURL *)fileURL { return _fileURL; }
- (void)setFileURL:(NSURL *)url { _fileURL = url; }

@end

/* The screen's content over a rect (global points): the desktop and every window. */
static CGImageRef
copy_screen_rect(CGRect rect, BOOL cursor)
{
    FWSRect fr = {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
    return FWSCaptureImage(fr, FWS_CAPTURE_SHADOWS | (cursor ? FWS_CAPTURE_CURSOR : 0), NULL, 0);
}

/* An image of a pixel buffer's BGRA pixels. */
static CGImageRef
image_of_buffer(CVPixelBufferRef pb)
{
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb);
    CFDataRef data = CFDataCreate(NULL, CVPixelBufferGetBaseAddress(pb), (CFIndex)(bpr * h));
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef im = CGImageCreate(w, h, 8, 32, bpr, srgb, (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little,
                                  prov, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(srgb);
    CGDataProviderRelease(prov);
    CFRelease(data);
    return im;
}

/* The captured image fitted as a configuration asks (its size, rects, background). */
static CGImageRef
fitted_image(CGImageRef image, CGFloat scale, size_t width, size_t height, CGRect source, CGRect destination,
             BOOL scalesToFit, BOOL preserves, CGColorRef background)
{
    if (!width || !height) {
        /* (the content's own size, or the source rect's, in pixels) */
        if (!CGRectIsNull(source) && !CGRectIsEmpty(source))
            width = (size_t)lround(source.size.width * scale), height = (size_t)lround(source.size.height * scale);
        else
            width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    }
    CVPixelBufferRef pb = SCFinchPixelBuffer(image, scale, kCVPixelFormatType_32BGRA, width, height, source, destination,
                                             scalesToFit, preserves, background, NULL);
    if (!pb)
        return NULL;
    CGImageRef out = image_of_buffer(pb);
    CVPixelBufferRelease(pb);
    return out;
}

static void
finish(void (^handler)(id, NSError *), id result, NSError *error)
{
    if (!handler)
        return;
    handler = [[handler copy] autorelease];
    [result retain];
    dispatch_async(SCFinchQueue(), ^{
        handler(result, error);
        [result release];
    });
}

static NSError *
access_error(void)
{
    return CGPreflightScreenCaptureAccess()
               ? nil
               : SCFinchError(SCStreamErrorUserDeclined, @"The user declined TCCs for application, window, display capture");
}

@implementation SCScreenshotManager

- (instancetype)init { return [super init]; }

+ (void)captureSampleBufferWithFilter:(SCContentFilter *)contentFilter configuration:(SCStreamConfiguration *)config
                    completionHandler:(void (^)(CMSampleBufferRef, NSError *))completionHandler
{
    NSError *error = access_error();
    CMSampleBufferRef sb = NULL;
    if (!error) {
        CGImageRef image = [contentFilter _finchCopyImageOfRect:CGRectNull cursor:config.showsCursor shadows:!config.ignoreShadowsDisplay];
        CVPixelBufferRef pb = SCFinchPixelBuffer(image, [contentFilter pointPixelScale], config.pixelFormat, config.width,
                                                 config.height, config.sourceRect, config.destinationRect, config.scalesToFit,
                                                 config.preservesAspectRatio, config.backgroundColor, NULL);
        CGImageRelease(image);
        if (pb) {
            CMVideoFormatDescriptionRef fd = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fd);
            CMSampleTimingInfo timing = {kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
            CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, fd, &timing, &sb);
            if (fd)
                CFRelease(fd);
            CVPixelBufferRelease(pb);
        }
        if (!sb)
            error = SCFinchError(SCStreamErrorInvalidParameter, @"The content could not be captured in that format");
    }
    finish((void (^)(id, NSError *))completionHandler, (id)sb, error);
    if (sb)
        CFRelease(sb);
}

+ (void)captureImageWithFilter:(SCContentFilter *)contentFilter configuration:(SCStreamConfiguration *)config
             completionHandler:(void (^)(CGImageRef, NSError *))completionHandler
{
    NSError *error = access_error();
    CGImageRef out = NULL;
    if (!error) {
        CGImageRef image = [contentFilter _finchCopyImageOfRect:CGRectNull cursor:config.showsCursor shadows:!config.ignoreShadowsDisplay];
        if (image)
            out = fitted_image(image, [contentFilter pointPixelScale], config.width, config.height, config.sourceRect,
                               config.destinationRect, config.scalesToFit, config.preservesAspectRatio, config.backgroundColor);
        CGImageRelease(image);
        if (!out)
            error = SCFinchError(SCStreamErrorNoCaptureSource, @"There was nothing to capture");
    }
    finish((void (^)(id, NSError *))completionHandler, (id)out, error);
    CGImageRelease(out);
}

+ (void)captureImageInRect:(CGRect)rect completionHandler:(void (^)(CGImageRef, NSError *))completionHandler
{
    CGImageRef out = copy_screen_rect(rect, NO);
    finish((void (^)(id, NSError *))completionHandler, (id)out,
           out ? nil : SCFinchError(SCStreamErrorInvalidParameter, @"The rect has nothing in it"));
    CGImageRelease(out);
}

/* A screenshot output from a captured image: SDR, HDR or both, written out if asked. */
static SCScreenshotOutput *
make_output(CGImageRef image, CGFloat scale, SCScreenshotConfiguration *config, NSError **error)
{
    SCScreenshotOutput *out = [[[SCScreenshotOutput alloc] init] autorelease];
    CGImageRef sdr = fitted_image(image, scale, (size_t)MAX(config.width, 0), (size_t)MAX(config.height, 0), config.sourceRect,
                                  config.destinationRect, YES, YES, NULL);
    if (!sdr) {
        *error = SCFinchError(SCStreamErrorNoCaptureSource, @"There was nothing to capture");
        return out;
    }
    if (config.dynamicRange != SCScreenshotDynamicRangeHDR)
        [out setSdrImage:sdr];
    if (config.dynamicRange != SCScreenshotDynamicRangeSDR) {
        CGColorSpaceRef ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
        CGImageRef hdr = CGImageCreateCopyWithColorSpace(sdr, ext);
        CGColorSpaceRelease(ext);
        [out setHdrImage:hdr ?: sdr];
        CGImageRelease(hdr);
    }
    if (config.fileURL) {
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)config.fileURL,
                                                                     (CFStringRef)[config.contentType ?: UTTypePNG identifier], 1, NULL);
        BOOL ok = NO;
        if (dest) {
            CGImageDestinationAddImage(dest, sdr, NULL);
            ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        if (ok)
            [out setFileURL:config.fileURL];
        else
            *error = SCFinchError(SCStreamErrorInvalidParameter, @"The screenshot could not be written in that format");
    }
    CGImageRelease(sdr);
    return out;
}

+ (void)captureScreenshotWithFilter:(SCContentFilter *)contentFilter configuration:(SCScreenshotConfiguration *)config
                  completionHandler:(void (^)(SCScreenshotOutput *, NSError *))completionHandler
{
    NSError *error = access_error();
    SCScreenshotOutput *out = nil;
    if (!error) {
        CGImageRef image = [contentFilter _finchCopyImageOfRect:CGRectNull cursor:config.showsCursor shadows:!config.ignoreShadows];
        out = image ? make_output(image, [contentFilter pointPixelScale], config, &error) : nil;
        if (!image)
            error = SCFinchError(SCStreamErrorNoCaptureSource, @"There was nothing to capture");
        CGImageRelease(image);
    } else {
        out = [[[SCScreenshotOutput alloc] init] autorelease];
    }
    finish((void (^)(id, NSError *))completionHandler, out, error);
}

+ (void)captureScreenshotWithRect:(CGRect)rect configuration:(SCScreenshotConfiguration *)config
                completionHandler:(void (^)(SCScreenshotOutput *, NSError *))completionHandler
{
    NSError *error = access_error();
    SCScreenshotOutput *out = nil;
    if (!error) {
        CGImageRef image = copy_screen_rect(rect, config.showsCursor);
        CGFloat scale = image && rect.size.width > 0 ? CGImageGetWidth(image) / rect.size.width : 1;
        out = image ? make_output(image, scale, config, &error) : nil;
        if (!image)
            error = SCFinchError(SCStreamErrorInvalidParameter, @"The rect has nothing in it");
        CGImageRelease(image);
    } else {
        out = [[[SCScreenshotOutput alloc] init] autorelease];
    }
    finish((void (^)(id, NSError *))completionHandler, out, error);
}

@end

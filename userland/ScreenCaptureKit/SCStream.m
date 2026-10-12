/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Streams: a filter's content captured at the configuration's frame interval, drawn
 * into pixel buffers of its size and format (BGRA, or 4:2:0 video- or full-range
 * biplanar YCbCr by BT.709), and handed to the outputs as sample buffers carrying Apple's
 * frame info attachments. A frame is delivered when the content changed (the first
 * always). Configuration defaults and presets are Apple's.
 */
#import "SCInternal.h"
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#include <mach/mach_time.h>

#pragma mark - Pixel buffers

static void
bt709_from_bgra(const uint8_t *bgra, size_t bpr, size_t w, size_t h, CVPixelBufferRef out, BOOL full)
{
    uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(out, 0), *cp = CVPixelBufferGetBaseAddressOfPlane(out, 1);
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(out, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(out, 1);
    double yscale = full ? 255 : 219, yoff = full ? 0 : 16, cscale = full ? 255 : 224;
    for (size_t y = 0; y < h; y++) {
        const uint8_t *row = bgra + y * bpr;
        for (size_t x = 0; x < w; x++) {
            double b = row[x * 4] / 255.0, g = row[x * 4 + 1] / 255.0, r = row[x * 4 + 2] / 255.0;
            double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            yp[y * ybpr + x] = (uint8_t)lround(yoff + yscale * luma);
        }
    }
    for (size_t y = 0; y < h / 2; y++)
        for (size_t x = 0; x < w / 2; x++) {
            double r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++)
                for (int dx = 0; dx < 2; dx++) {
                    const uint8_t *p = bgra + (y * 2 + dy) * bpr + (x * 2 + dx) * 4;
                    b += p[0], g += p[1], r += p[2];
                }
            r /= 4 * 255.0, g /= 4 * 255.0, b /= 4 * 255.0;
            double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            double cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748;
            cp[y * cbpr + x * 2] = (uint8_t)MAX(0, MIN(255, lround(128 + cscale * cb)));
            cp[y * cbpr + x * 2 + 1] = (uint8_t)MAX(0, MIN(255, lround(128 + cscale * cr)));
        }
}

CVPixelBufferRef
SCFinchPixelBuffer(CGImageRef image, CGFloat scale, OSType format, size_t width, size_t height, CGRect sourceRect,
                   CGRect destinationRect, BOOL scalesToFit, BOOL preservesAspectRatio, CGColorRef background,
                   CGRect *contentRectOut)
{
    BOOL yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!image || !width || !height || !(yuv || format == kCVPixelFormatType_32BGRA))
        return NULL;
    size_t iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    /* the part of the image (pixels, top-left origin) */
    CGRect src = CGRectMake(0, 0, iw, ih);
    if (!CGRectIsNull(sourceRect) && !CGRectIsEmpty(sourceRect))
        src = CGRectIntersection(src, CGRectMake(sourceRect.origin.x * scale, sourceRect.origin.y * scale,
                                                 sourceRect.size.width * scale, sourceRect.size.height * scale));
    /* where it goes (pixels, top-left origin) */
    CGRect dst = CGRectMake(0, 0, width, height);
    if (!CGRectIsNull(destinationRect) && !CGRectIsEmpty(destinationRect))
        dst = destinationRect;
    CGRect place = CGRectMake(dst.origin.x, dst.origin.y, src.size.width, src.size.height);
    if (scalesToFit || src.size.width > dst.size.width || src.size.height > dst.size.height) {
        if (preservesAspectRatio) {
            double k = MIN(dst.size.width / src.size.width, dst.size.height / src.size.height);
            double w = src.size.width * k, h = src.size.height * k;
            place = CGRectMake(dst.origin.x + (dst.size.width - w) / 2, dst.origin.y + (dst.size.height - h) / 2, w, h);
        } else {
            place = dst;
        }
    }
    if (contentRectOut)
        *contentRectOut = place;

    size_t bpr = width * 4;
    uint8_t *pixels = calloc(height, bpr);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, bpr, srgb,
                                             (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(srgb);
    if (background) {
        CGContextSetFillColorWithColor(ctx, background);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    } else if (yuv) {
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    }
    CGImageRef part = CGImageCreateWithImageInRect(image, src);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    /* (bitmap contexts are bottom-up) */
    CGContextDrawImage(ctx, CGRectMake(place.origin.x, (CGFloat)height - CGRectGetMaxY(place), place.size.width, place.size.height),
                       part);
    CGImageRelease(part);
    CGContextRelease(ctx);

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    if (CVPixelBufferCreate(NULL, width, height, format, (CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        free(pixels);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    if (yuv) {
        bt709_from_bgra(pixels, bpr, width, height, pb, format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    } else {
        uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t obpr = CVPixelBufferGetBytesPerRow(pb);
        for (size_t y = 0; y < height; y++)
            memcpy(base + y * obpr, pixels + y * bpr, bpr);
    }
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    free(pixels);
    return pb;
}

#pragma mark - Configuration

@implementation SCStreamConfiguration {
    CGColorRef _background;
    CFStringRef _colorMatrix, _colorSpaceName;
    NSString *_streamName, *_microphoneID;
}

@synthesize width = _width, height = _height, minimumFrameInterval = _minimumFrameInterval, pixelFormat = _pixelFormat,
            scalesToFit = _scalesToFit, preservesAspectRatio = _preservesAspectRatio, showsCursor = _showsCursor,
            showMouseClicks = _showMouseClicks, sourceRect = _sourceRect, destinationRect = _destinationRect,
            queueDepth = _queueDepth, capturesAudio = _capturesAudio, sampleRate = _sampleRate,
            channelCount = _channelCount, excludesCurrentProcessAudio = _excludesCurrentProcessAudio,
            ignoreShadowsDisplay = _ignoreShadowsDisplay, ignoreShadowsSingleWindow = _ignoreShadowsSingleWindow,
            captureResolution = _captureResolution, capturesShadowsOnly = _capturesShadowsOnly,
            shouldBeOpaque = _shouldBeOpaque, ignoreGlobalClipDisplay = _ignoreGlobalClipDisplay,
            ignoreGlobalClipSingleWindow = _ignoreGlobalClipSingleWindow,
            presenterOverlayPrivacyAlertSetting = _presenterOverlayPrivacyAlertSetting,
            includeChildWindows = _includeChildWindows, captureMicrophone = _captureMicrophone,
            captureDynamicRange = _captureDynamicRange;

- (instancetype)init
{
    if ((self = [super init])) {
        _width = 1920, _height = 1080;
        _minimumFrameInterval = CMTimeMake(1, 60);
        _pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        _preservesAspectRatio = YES;
        _streamName = @"";
        _showsCursor = YES;
        _queueDepth = 8;
        _sampleRate = 48000;
        _channelCount = 2;
        _ignoreShadowsSingleWindow = YES;
        _ignoreGlobalClipSingleWindow = YES;
        _includeChildWindows = YES;
    }
    return self;
}

+ (instancetype)streamConfigurationWithPreset:(SCStreamConfigurationPreset)preset
{
    SCStreamConfiguration *c = [[[self alloc] init] autorelease];
    switch (preset) {
    case SCStreamConfigurationPresetCaptureHDRStreamLocalDisplay:
    case SCStreamConfigurationPresetCaptureHDRStreamCanonicalDisplay:
        c.pixelFormat = 'xf44';
        c.colorSpaceName = kCGColorSpaceDisplayP3_PQ;
        c.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        break;
    case SCStreamConfigurationPresetCaptureHDRScreenshotLocalDisplay:
    case SCStreamConfigurationPresetCaptureHDRScreenshotCanonicalDisplay:
        c.pixelFormat = kCVPixelFormatType_64RGBAHalf;
        c.colorSpaceName = kCGColorSpaceExtendedDisplayP3;
        break;
    case SCStreamConfigurationPresetCaptureHDRRecordingPreservedSDRHDR10:
        c.pixelFormat = 'x420';
        c.colorSpaceName = kCGColorSpaceITUR_2100_PQ;
        c.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
        break;
    }
    c.captureDynamicRange = (preset == SCStreamConfigurationPresetCaptureHDRStreamLocalDisplay ||
                             preset == SCStreamConfigurationPresetCaptureHDRScreenshotLocalDisplay)
                                ? SCCaptureDynamicRangeHDRLocalDisplay
                                : SCCaptureDynamicRangeHDRCanonicalDisplay;
    return c;
}

- (void)dealloc
{
    CGColorRelease(_background);
    if (_colorMatrix)
        CFRelease(_colorMatrix);
    if (_colorSpaceName)
        CFRelease(_colorSpaceName);
    [_streamName release];
    [_microphoneID release];
    [super dealloc];
}

- (CGColorRef)backgroundColor { return _background; }
- (void)setBackgroundColor:(CGColorRef)color
{
    CGColorRetain(color);
    CGColorRelease(_background);
    _background = color;
}

- (CFStringRef)colorMatrix { return _colorMatrix; }
- (void)setColorMatrix:(CFStringRef)matrix
{
    if (matrix)
        CFRetain(matrix);
    if (_colorMatrix)
        CFRelease(_colorMatrix);
    _colorMatrix = matrix;
}

- (CFStringRef)colorSpaceName { return _colorSpaceName; }
- (void)setColorSpaceName:(CFStringRef)name
{
    if (name)
        CFRetain(name);
    if (_colorSpaceName)
        CFRelease(_colorSpaceName);
    _colorSpaceName = name;
}

- (NSString *)streamName { return _streamName; }
- (void)setStreamName:(NSString *)name
{
    [_streamName autorelease];
    _streamName = [name copy];
}

- (NSString *)microphoneCaptureDeviceID { return _microphoneID; }
- (void)setMicrophoneCaptureDeviceID:(NSString *)deviceID
{
    [_microphoneID autorelease];
    _microphoneID = [deviceID copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    SCStreamConfiguration *c = [[SCStreamConfiguration alloc] init];
    c->_width = _width, c->_height = _height, c->_minimumFrameInterval = _minimumFrameInterval;
    c->_pixelFormat = _pixelFormat, c->_scalesToFit = _scalesToFit, c->_preservesAspectRatio = _preservesAspectRatio;
    c->_showsCursor = _showsCursor, c->_sourceRect = _sourceRect, c->_destinationRect = _destinationRect;
    c->_queueDepth = _queueDepth, c->_ignoreShadowsDisplay = _ignoreShadowsDisplay;
    c->_ignoreShadowsSingleWindow = _ignoreShadowsSingleWindow, c->_shouldBeOpaque = _shouldBeOpaque;
    c->_capturesAudio = _capturesAudio, c->_captureMicrophone = _captureMicrophone;
    c->_captureDynamicRange = _captureDynamicRange;
    [c setBackgroundColor:_background];
    [c setColorMatrix:_colorMatrix];
    [c setColorSpaceName:_colorSpaceName];
    [c setStreamName:_streamName];
    return c;
}

@end

#pragma mark - Recording

@implementation SCRecordingOutputConfiguration {
    NSURL *_url;
    AVVideoCodecType _codec;
    AVFileType _fileType;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _codec = [@"avc1" copy];
        _fileType = [@"public.mpeg-4" copy];
    }
    return self;
}

- (void)dealloc
{
    [_url release];
    [_codec release];
    [_fileType release];
    [super dealloc];
}

- (NSURL *)outputURL { return _url; }
- (void)setOutputURL:(NSURL *)url
{
    [_url autorelease];
    _url = [url copy];
}
- (AVVideoCodecType)videoCodecType { return _codec; }
- (void)setVideoCodecType:(AVVideoCodecType)codec
{
    [_codec autorelease];
    _codec = [codec copy];
}
- (AVFileType)outputFileType { return _fileType; }
- (void)setOutputFileType:(AVFileType)type
{
    [_fileType autorelease];
    _fileType = [type copy];
}
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes { return @[ @"avc1", @"hvc1" ]; }
- (NSArray<AVFileType> *)availableOutputFileTypes { return @[ @"public.mpeg-4", @"com.apple.quicktime-movie" ]; }

@end

@implementation SCRecordingOutput {
    SCRecordingOutputConfiguration *_config;
    id<SCRecordingOutputDelegate> _delegate; /* not retained */
}

- (instancetype)initWithConfiguration:(SCRecordingOutputConfiguration *)configuration delegate:(id<SCRecordingOutputDelegate>)delegate
{
    if ((self = [super init])) {
        _config = [configuration retain];
        _delegate = delegate;
    }
    return self;
}

- (void)dealloc
{
    [_config release];
    [super dealloc];
}

- (CMTime)recordedDuration { return kCMTimeZero; }
- (NSInteger)recordedFileSize { return 0; }

@end

#pragma mark - Streams

@interface _SCOutput : NSObject {
@public
    id<SCStreamOutput> output; /* retained, as Apple's */
    SCStreamOutputType type;
    dispatch_queue_t queue;
}
@end

@implementation _SCOutput
- (void)dealloc
{
    [output release];
    dispatch_release(queue);
    [super dealloc];
}
@end

@implementation SCStream {
    SCContentFilter *_filter;
    SCStreamConfiguration *_config;
    id<SCStreamDelegate> _delegate; /* not retained */
    NSMutableArray *_outputs;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSData *_last;
    BOOL _running;
}

- (instancetype)initWithFilter:(SCContentFilter *)contentFilter configuration:(SCStreamConfiguration *)streamConfig
                      delegate:(id<SCStreamDelegate>)delegate
{
    if ((self = [super init])) {
        _filter = [contentFilter retain];
        _config = [streamConfig copy];
        _delegate = delegate;
        _outputs = [[NSMutableArray alloc] init];
        _queue = dispatch_queue_create("com.apple.ScreenCaptureKit.stream", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        dispatch_release(_timer);
    }
    dispatch_release(_queue);
    [_filter release];
    [_config release];
    [_outputs release];
    [_last release];
    [super dealloc];
}

- (CMClockRef)synchronizationClock { return CMClockGetHostTimeClock(); }

- (BOOL)addStreamOutput:(id<SCStreamOutput>)output type:(SCStreamOutputType)type sampleHandlerQueue:(dispatch_queue_t)queue
                  error:(NSError **)error
{
    _SCOutput *o = [[[_SCOutput alloc] init] autorelease];
    o->output = [output retain];
    o->type = type;
    o->queue = queue ?: dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_retain(o->queue);
    @synchronized(self) {
        [_outputs addObject:o];
    }
    return YES;
}

- (BOOL)removeStreamOutput:(id<SCStreamOutput>)output type:(SCStreamOutputType)type error:(NSError **)error
{
    @synchronized(self) {
        for (_SCOutput *o in [[_outputs copy] autorelease])
            if (o->output == output && o->type == type) {
                [_outputs removeObject:o];
                return YES;
            }
    }
    if (error)
        *error = SCFinchError(SCStreamErrorRemovingStream, @"The stream output was not added");
    return NO;
}

- (void)updateContentFilter:(SCContentFilter *)contentFilter completionHandler:(void (^)(NSError *))completionHandler
{
    dispatch_async(_queue, ^{
        [_filter autorelease];
        _filter = [contentFilter retain];
        [_last release];
        _last = nil;
        if (completionHandler)
            completionHandler(nil);
    });
}

- (void)updateConfiguration:(SCStreamConfiguration *)streamConfig completionHandler:(void (^)(NSError *))completionHandler
{
    SCStreamConfiguration *copy = [[streamConfig copy] autorelease];
    dispatch_async(_queue, ^{
        [_config autorelease];
        _config = [copy retain];
        [_last release];
        _last = nil;
        if (_timer)
            [self _finchSetTimer];
        if (completionHandler)
            completionHandler(nil);
    });
}

- (void)_finchSetTimer
{
    CMTime t = _config.minimumFrameInterval;
    double interval = CMTIME_IS_VALID(t) && CMTimeGetSeconds(t) > 0 ? CMTimeGetSeconds(t) : 1.0 / 60;
    interval = MAX(interval, 1.0 / 60);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(interval * NSEC_PER_SEC),
                              (uint64_t)(interval * NSEC_PER_SEC / 10));
}

static NSDictionary *
rect_dict(CGRect r)
{
    return [(NSDictionary *)CGRectCreateDictionaryRepresentation(r) autorelease];
}

/* One frame: captured, compared with the last, made into a sample buffer and handed out. */
- (void)_finchFrame
{
    SCStreamConfiguration *c = _config;
    BOOL single = [_filter style] == SCShareableContentStyleWindow && [[_filter includedWindows] count] == 1 &&
                  [[_filter includedDisplays] count] == 0;
    BOOL shadows = single ? !c.ignoreShadowsSingleWindow : !c.ignoreShadowsDisplay;
    CGImageRef image = [_filter _finchCopyImageOfRect:CGRectNull cursor:c.showsCursor shadows:shadows];
    if (!image)
        return;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    BOOL same = _last && data && [(NSData *)data isEqualToData:_last];
    if (!same) {
        [_last release];
        _last = [(NSData *)data copy];
    }
    if (data)
        CFRelease(data);
    if (same) {
        CGImageRelease(image);
        return;
    }
    CGFloat scale = [_filter pointPixelScale];
    CGRect content = CGRectZero;
    CVPixelBufferRef pb = SCFinchPixelBuffer(image, scale, c.pixelFormat, c.width, c.height, c.sourceRect, c.destinationRect,
                                             c.scalesToFit, c.preservesAspectRatio, c.backgroundColor, &content);
    CGImageRelease(image);
    if (!pb)
        return;
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fd);
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {c.minimumFrameInterval, now, kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, fd, &timing, &sb);
    if (fd)
        CFRelease(fd);
    CVPixelBufferRelease(pb);
    if (!sb)
        return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (atts && CFArrayGetCount(atts)) {
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CGRect screen = [_filter _finchScreenRect];
        double contentScale = scale > 0 && screen.size.width > 0 ? content.size.width / (screen.size.width * scale) : 1;
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoStatus, (CFTypeRef)(@(SCFrameStatusComplete)));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoDisplayTime, (CFTypeRef)(@(mach_absolute_time())));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoScaleFactor, (CFTypeRef)(@(scale)));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoContentScale, (CFTypeRef)(@(contentScale)));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoContentRect, (CFTypeRef)(rect_dict(CGRectMake(content.origin.x / scale, content.origin.y / scale,
                                                               content.size.width / scale, content.size.height / scale))));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoBoundingRect, (CFTypeRef)(rect_dict(CGRectMake(0, 0, screen.size.width, screen.size.height))));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoScreenRect, (CFTypeRef)(rect_dict(screen)));
        CFDictionarySetValue(d, (CFStringRef)SCStreamFrameInfoDirtyRects, (CFTypeRef)(@[ rect_dict(CGRectMake(0, 0, c.width, c.height)) ]));
    }
    NSArray *outputs;
    @synchronized(self) {
        outputs = [[_outputs copy] autorelease];
    }
    for (_SCOutput *o in outputs) {
        if (o->type != SCStreamOutputTypeScreen || ![o->output respondsToSelector:@selector(stream:didOutputSampleBuffer:ofType:)])
            continue;
        CFRetain(sb);
        [self retain];
        id<SCStreamOutput> out = o->output;
        dispatch_async(o->queue, ^{
            [out stream:self didOutputSampleBuffer:sb ofType:SCStreamOutputTypeScreen];
            CFRelease(sb);
            [self release];
        });
    }
    CFRelease(sb);
}

- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    void (^done)(NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        OSType f = _config.pixelFormat;
        if (_running)
            error = SCFinchError(SCStreamErrorAttemptToStartStreamState, @"The stream is already running");
        else if (!CGPreflightScreenCaptureAccess())
            error = SCFinchError(SCStreamErrorUserDeclined, @"The user declined TCCs for application, window, display capture");
        else if (f != kCVPixelFormatType_32BGRA && f != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                 f != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            error = SCFinchError(SCStreamErrorInvalidParameter, @"The pixel format is not one Finch captures in");
        else if (!_config.width || !_config.height)
            error = SCFinchError(SCStreamErrorInvalidParameter, @"The output size is empty");
        if (!error) {
            _running = YES;
            [_last release];
            _last = nil;
            _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
            dispatch_source_set_event_handler(_timer, ^{
                @autoreleasepool {
                    [self _finchFrame];
                }
            });
            [self _finchSetTimer];
            dispatch_resume(_timer);
        }
        if (done)
            dispatch_async(SCFinchQueue(), ^{
                done(error);
            });
    });
}

- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    void (^done)(NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        if (!_running) {
            error = SCFinchError(SCStreamErrorAttemptToStopStreamState, @"The stream is not running");
        } else {
            _running = NO;
            dispatch_source_cancel(_timer);
            dispatch_release(_timer);
            _timer = NULL;
        }
        if (done)
            dispatch_async(SCFinchQueue(), ^{
                done(error);
            });
    });
}

- (BOOL)addRecordingOutput:(SCRecordingOutput *)recordingOutput error:(NSError **)error
{
    if (error)
        *error = SCFinchError(SCStreamErrorInternalError, @"Finch can't encode video to record a stream yet");
    return NO;
}

- (BOOL)removeRecordingOutput:(SCRecordingOutput *)recordingOutput error:(NSError **)error
{
    if (error)
        *error = SCFinchError(SCStreamErrorInvalidParameter, @"The recording output was not added");
    return NO;
}

@end

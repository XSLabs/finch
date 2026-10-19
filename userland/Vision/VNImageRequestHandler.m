// SPDX-License-Identifier: MIT OR Apache-2.0
#import "VNPrivate.h"

static BOOL VNOrientationSwapsDimensions(CGImagePropertyOrientation orientation)
{
    return orientation >= kCGImagePropertyOrientationLeftMirrored && orientation <= kCGImagePropertyOrientationLeft;
}

CGImageRef VNCreateOrientedCGImage(CGImageRef image, CGImagePropertyOrientation orientation)
{
    if (!image || orientation < kCGImagePropertyOrientationUp || orientation > kCGImagePropertyOrientationLeft)
        return NULL;
    if (orientation == kCGImagePropertyOrientationUp)
        return CGImageRetain(image);

    size_t sourceWidth = CGImageGetWidth(image), sourceHeight = CGImageGetHeight(image);
    BOOL swaps = VNOrientationSwapsDimensions(orientation);
    size_t width = swaps ? sourceHeight : sourceWidth;
    size_t height = swaps ? sourceWidth : sourceHeight;
    size_t bytesPerRow = width * 4;
    void *bytes = calloc(height, bytesPerRow);
    if (!bytes) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, bytesPerRow,
                                                  colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) { free(bytes); return NULL; }

    CGContextSaveGState(context);
    switch (orientation) {
        case kCGImagePropertyOrientationUpMirrored:
            CGContextTranslateCTM(context, width, 0); CGContextScaleCTM(context, -1, 1); break;
        case kCGImagePropertyOrientationDown:
            CGContextTranslateCTM(context, width, height); CGContextRotateCTM(context, (CGFloat)M_PI); break;
        case kCGImagePropertyOrientationDownMirrored:
            CGContextTranslateCTM(context, 0, height); CGContextScaleCTM(context, 1, -1); break;
        case kCGImagePropertyOrientationLeftMirrored:
            CGContextTranslateCTM(context, 0, width); CGContextRotateCTM(context, (CGFloat)(M_PI / 2.0));
            CGContextScaleCTM(context, -1, 1); break;
        case kCGImagePropertyOrientationRight:
            CGContextTranslateCTM(context, 0, height); CGContextRotateCTM(context, (CGFloat)(-M_PI / 2.0)); break;
        case kCGImagePropertyOrientationRightMirrored:
            CGContextTranslateCTM(context, height, 0); CGContextRotateCTM(context, (CGFloat)(-M_PI / 2.0));
            CGContextScaleCTM(context, -1, 1); break;
        case kCGImagePropertyOrientationLeft:
            CGContextTranslateCTM(context, width, 0); CGContextRotateCTM(context, (CGFloat)(M_PI / 2.0)); break;
        default: break;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), image);
    CGContextRestoreGState(context);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(bytes);
    return result;
}

CGImageRef VNCreateCGImageFromPixelBuffer(CVPixelBufferRef buffer)
{
    if (!buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    CGImageRef image = NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    if (format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB ||
        format == kCVPixelFormatType_32RGBA) {
        void *base = CVPixelBufferGetBaseAddress(buffer);
        size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        if (base && width && height) {
            NSData *copy = [[NSData alloc] initWithBytes:base length:rowBytes * height];
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)copy);
            CGBitmapInfo bitmap = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast;
            if (format == kCVPixelFormatType_32BGRA)
                bitmap = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
            else if (format == kCVPixelFormatType_32ARGB)
                bitmap = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst;
            image = CGImageCreate(width, height, 8, 32, rowBytes, colorSpace, bitmap, provider, NULL, false,
                                  kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);
            [copy release];
        }
    } else if (CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetPlaneCount(buffer) >= 2 &&
               (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        const uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        const uint8_t *uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        size_t rowBytes = width * 4;
        uint8_t *rgba = malloc(rowBytes * height);
        if (rgba && yPlane && uvPlane) {
            BOOL fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
            for (size_t y = 0; y < height; y++) {
                for (size_t x = 0; x < width; x++) {
                    double yy = yPlane[y * yStride + x];
                    double u = uvPlane[(y / 2) * uvStride + (x / 2) * 2] - 128.0;
                    double v = uvPlane[(y / 2) * uvStride + (x / 2) * 2 + 1] - 128.0;
                    if (!fullRange) yy = (yy - 16.0) * (255.0 / 219.0);
                    size_t offset = y * rowBytes + x * 4;
                    rgba[offset] = (uint8_t)fmin(255.0, fmax(0.0, yy + 1.5748 * v));
                    rgba[offset + 1] = (uint8_t)fmin(255.0, fmax(0.0, yy - 0.1873 * u - 0.4681 * v));
                    rgba[offset + 2] = (uint8_t)fmin(255.0, fmax(0.0, yy + 1.8556 * u));
                    rgba[offset + 3] = 255;
                }
            }
            NSData *copy = [[NSData alloc] initWithBytesNoCopy:rgba length:rowBytes * height freeWhenDone:YES];
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)copy);
            image = CGImageCreate(width, height, 8, 32, rowBytes, colorSpace,
                                  kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                  provider, NULL, false, kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);
            [copy release];
        } else {
            free(rgba);
        }
    }

    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return image;
}

@interface VNImageRequestHandler () {
    CGImageRef _image;
    CGImagePropertyOrientation _orientation;
    NSDictionary *_options;
    NSError *_inputError;
    AVDepthData *_depthData;
}
- (instancetype)_initWithCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options;
@end

@implementation VNImageRequestHandler

- (instancetype)init { [self release]; return nil; }

- (instancetype)_initWithCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    if (!image) { [self release]; return nil; }
    if ((self = [super init])) {
        _image = CGImageRetain(image);
        _orientation = orientation;
        _options = [options copy];
        if (orientation < kCGImagePropertyOrientationUp || orientation > kCGImagePropertyOrientationLeft)
            _inputError = [VNMakeError(VNErrorInvalidArgument, @"Image orientation must be between 1 and 8.") retain];
    }
    return self;
}

- (instancetype)initWithCGImage:(CGImageRef)image options:(NSDictionary *)options
{
    return [self initWithCGImage:image orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self _initWithCGImage:image orientation:orientation options:options];
}

- (instancetype)initWithCIImage:(CIImage *)image options:(NSDictionary *)options
{
    return [self initWithCIImage:image orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithCIImage:(CIImage *)image orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    if (!image) { [self release]; return nil; }
    CIContext *context = [options objectForKey:VNImageOptionCIContext];
    if (![context isKindOfClass:CIContext.class]) context = [CIContext context];
    CGImageRef cg = [context createCGImage:image fromRect:image.extent];
    self = [self _initWithCGImage:cg orientation:orientation options:options];
    if (cg) CGImageRelease(cg);
    return self;
}

- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer options:(NSDictionary *)options
{
    return [self initWithCVPixelBuffer:pixelBuffer orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    CGImageRef cg = VNCreateCGImageFromPixelBuffer(pixelBuffer);
    self = [self _initWithCGImage:cg orientation:orientation options:options];
    if (cg) CGImageRelease(cg);
    return self;
}
- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer depthData:(AVDepthData *)depthData
                          orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    return [self initWithCVPixelBuffer:pixelBuffer orientation:orientation options:options];
}

- (instancetype)initWithData:(NSData *)data options:(NSDictionary *)options
{
    return [self initWithData:data orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithData:(NSData *)data orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    self = [self _initWithCGImage:cg orientation:orientation options:options];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return self;
}
- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary *)options
{
    return [self initWithURL:url orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithURL:(NSURL *)url orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    self = [self _initWithCGImage:cg orientation:orientation options:options];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return self;
}
- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer options:(NSDictionary *)options
{
    return [self initWithCMSampleBuffer:sampleBuffer orientation:kCGImagePropertyOrientationUp options:options];
}
- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    CVImageBufferRef imageBuffer = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
    return [self initWithCVPixelBuffer:imageBuffer orientation:orientation options:options];
}
- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer depthData:(AVDepthData *)depthData
                           orientation:(CGImagePropertyOrientation)orientation options:(NSDictionary *)options
{
    if ((self = [self initWithCMSampleBuffer:sampleBuffer orientation:orientation options:options]))
        _depthData = [depthData retain];
    return self;
}
- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(CGImagePropertyOrientation)orientation
                          options:(NSDictionary *)options error:(NSError **)error
{
    if (error) *error = nil;
    return [self initWithCMSampleBuffer:sampleBuffer orientation:orientation options:options];
}

- (void)dealloc
{
    CGImageRelease(_image);
    [_options release]; [_inputError release]; [_depthData release];
    [super dealloc];
}

- (CGImageRef)_copyImageWithError:(NSError **)error
{
    if (_inputError) { if (error) *error = _inputError; return NULL; }
    CGImageRef image = VNCreateOrientedCGImage(_image, _orientation);
    if (!image && error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be decoded.");
    return image;
}

- (BOOL)performRequests:(NSArray<VNRequest *> *)requests error:(NSError **)error
{
    CGImageRef image = [self _copyImageWithError:error];
    if (!image) return NO;
    BOOL ok = VNPerformRequestsWithCGImage(requests, image, NULL, error);
    CGImageRelease(image);
    return ok;
}

@end

@interface VNSequenceRequestHandler () {
    CGImageRef _previousImage;
}
- (BOOL)_performRequests:(NSArray<VNRequest *> *)requests image:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error;
@end

@implementation VNSequenceRequestHandler
- (instancetype)init { return [super init]; }
- (void)dealloc { CGImageRelease(_previousImage); [super dealloc]; }

- (BOOL)_performRequests:(NSArray<VNRequest *> *)requests image:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{
    CGImageRef oriented = VNCreateOrientedCGImage(image, orientation);
    if (!oriented) { if (error) *error = VNMakeError(VNErrorInvalidImage, @"The image could not be decoded."); return NO; }
    BOOL ok = VNPerformRequestsWithCGImage(requests, oriented, _previousImage, error);
    if (ok) { CGImageRelease(_previousImage); _previousImage = CGImageRetain(oriented); }
    CGImageRelease(oriented);
    return ok;
}

- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCGImage:(CGImageRef)image error:(NSError **)error
{ return [self performRequests:requests onCGImage:image orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCGImage:(CGImageRef)image orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{ return [self _performRequests:requests image:image orientation:orientation error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCIImage:(CIImage *)image error:(NSError **)error
{ return [self performRequests:requests onCIImage:image orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCIImage:(CIImage *)image orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{
    CIContext *context = [CIContext context];
    CGImageRef cg = image ? [context createCGImage:image fromRect:image.extent] : NULL;
    BOOL ok = [self _performRequests:requests image:cg orientation:orientation error:error];
    if (cg) CGImageRelease(cg);
    return ok;
}
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCVPixelBuffer:(CVPixelBufferRef)buffer error:(NSError **)error
{ return [self performRequests:requests onCVPixelBuffer:buffer orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCVPixelBuffer:(CVPixelBufferRef)buffer orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{
    CGImageRef cg = VNCreateCGImageFromPixelBuffer(buffer);
    BOOL ok = [self _performRequests:requests image:cg orientation:orientation error:error];
    if (cg) CGImageRelease(cg);
    return ok;
}
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onImageData:(NSData *)data error:(NSError **)error
{ return [self performRequests:requests onImageData:data orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onImageData:(NSData *)data orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    BOOL ok = [self _performRequests:requests image:cg orientation:orientation error:error];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return ok;
}
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onImageURL:(NSURL *)url error:(NSError **)error
{ return [self performRequests:requests onImageURL:url orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onImageURL:(NSURL *)url orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL((CFURLRef)url, NULL) : NULL;
    CGImageRef cg = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    BOOL ok = [self _performRequests:requests image:cg orientation:orientation error:error];
    if (cg) CGImageRelease(cg);
    if (source) CFRelease(source);
    return ok;
}
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCMSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError **)error
{ return [self performRequests:requests onCMSampleBuffer:sampleBuffer orientation:kCGImagePropertyOrientationUp error:error]; }
- (BOOL)performRequests:(NSArray<VNRequest *> *)requests onCMSampleBuffer:(CMSampleBufferRef)sampleBuffer orientation:(CGImagePropertyOrientation)orientation error:(NSError **)error
{ return [self performRequests:requests onCVPixelBuffer:CMSampleBufferGetImageBuffer(sampleBuffer) orientation:orientation error:error]; }
@end

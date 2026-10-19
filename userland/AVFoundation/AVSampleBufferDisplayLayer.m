/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Display uncompressed BGRA and ARGB image samples in Finch's CoreAnimation tree. */
#import "AVFInternal.h"
#import <AVFoundation/AVSampleBufferDisplayLayer.h>
#import <AVFoundation/AVAnimation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

@implementation AVSampleBufferDisplayLayer {
    CMTimebaseRef _finchTimebase;
    CMTimebaseRef _finchControlTimebase;
    AVLayerVideoGravity _finchVideoGravity;
    AVQueuedSampleBufferRenderingStatus _finchStatus;
    NSError *_finchError;
    BOOL _finchReadyForDisplay;
    BOOL _finchPreventsCapture;
    BOOL _finchPreventsSleep;
    dispatch_queue_t _finchRequestQueue;
    dispatch_block_t _finchRequestBlock;
    BOOL _finchRequestScheduled;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _finchVideoGravity = AVLayerVideoGravityResizeAspect;
        _finchStatus = AVQueuedSampleBufferRenderingStatusUnknown;
        CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_finchTimebase);
        self.contentsGravity = kCAGravityResizeAspect;
    }
    return self;
}

- (void)dealloc
{
    if (_finchControlTimebase)
        CFRelease(_finchControlTimebase);
    if (_finchTimebase)
        CFRelease(_finchTimebase);
}

- (CMTimebaseRef)controlTimebase { return _finchControlTimebase; }

- (void)setControlTimebase:(CMTimebaseRef)timebase
{
    if (timebase == _finchControlTimebase)
        return;
    if (timebase)
        CFRetain(timebase);
    if (_finchControlTimebase)
        CFRelease(_finchControlTimebase);
    _finchControlTimebase = timebase;
}

- (AVLayerVideoGravity)videoGravity { return _finchVideoGravity; }

- (void)setVideoGravity:(AVLayerVideoGravity)gravity
{
    if (!gravity)
        return;
    _finchVideoGravity = [gravity copy];
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect])
        self.contentsGravity = kCAGravityResizeAspect;
    else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill])
        self.contentsGravity = kCAGravityResizeAspectFill;
    else if ([gravity isEqualToString:AVLayerVideoGravityResize])
        self.contentsGravity = kCAGravityResize;
}

- (BOOL)isReadyForDisplay { return _finchReadyForDisplay; }
- (CMTimebaseRef)timebase { return _finchTimebase; }
- (AVQueuedSampleBufferRenderingStatus)status { return _finchStatus; }
- (NSError *)error { return _finchError; }
- (BOOL)isReadyForMoreMediaData { return _finchStatus != AVQueuedSampleBufferRenderingStatusFailed; }
- (BOOL)hasSufficientMediaDataForReliablePlaybackStart { return NO; }
- (BOOL)requiresFlushToResumeDecoding { return NO; }
- (BOOL)outputObscuredDueToInsufficientExternalProtection { return NO; }
- (BOOL)preventsCapture { return _finchPreventsCapture; }
- (void)setPreventsCapture:(BOOL)value { _finchPreventsCapture = value; }
- (BOOL)preventsDisplaySleepDuringVideoPlayback { return _finchPreventsSleep; }
- (void)setPreventsDisplaySleepDuringVideoPlayback:(BOOL)value { _finchPreventsSleep = value; }

- (void)_finchSetFailed:(NSError *)error
{
    _finchError = error;
    _finchStatus = AVQueuedSampleBufferRenderingStatusFailed;
}

- (CGImageRef)_finchCopyImageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    CGBitmapInfo bitmapInfo;
    if (pixelFormat == kCVPixelFormatType_32BGRA)
        bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    else if (pixelFormat == kCVPixelFormatType_32ARGB)
        bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst;
    else
        return NULL;

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return NULL;
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t length = rowBytes * height;
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    CFDataRef bytes = base ? CFDataCreate(kCFAllocatorDefault, base, (CFIndex)length) : NULL;
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (!bytes)
        return NULL;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = provider && colorSpace ? CGImageCreate(width, height, 8, 32, rowBytes, colorSpace, bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault) : NULL;
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (provider) CGDataProviderRelease(provider);
    CFRelease(bytes);
    return image;
}

- (void)_finchScheduleRequestBlock
{
    @synchronized(self) {
        if (!_finchRequestBlock || !_finchRequestQueue || _finchRequestScheduled || !self.readyForMoreMediaData)
            return;
        _finchRequestScheduled = YES;
        dispatch_async(_finchRequestQueue, ^{
            dispatch_block_t block;
            @synchronized(self) {
                block = self->_finchRequestBlock;
                self->_finchRequestScheduled = NO;
            }
            if (block && self.readyForMoreMediaData)
                block();
        });
    }
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (_finchStatus == AVQueuedSampleBufferRenderingStatusFailed || !sampleBuffer)
        return;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        [self _finchSetFailed:AVFError(AVErrorOperationNotSupportedForAsset, nil)];
        return;
    }
    CGImageRef image = [self _finchCopyImageFromPixelBuffer:(CVPixelBufferRef)imageBuffer];
    if (!image) {
        [self _finchSetFailed:AVFError(AVErrorOperationNotSupportedForAsset, nil)];
        return;
    }
    self.contents = (__bridge id)image;
    CGImageRelease(image);
    BOOL changed = !_finchReadyForDisplay;
    _finchReadyForDisplay = YES;
    _finchStatus = AVQueuedSampleBufferRenderingStatusRendering;
    _finchError = nil;
    if (changed)
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification object:self];
    [self _finchScheduleRequestBlock];
}

- (void)flush
{
    _finchStatus = AVQueuedSampleBufferRenderingStatusUnknown;
    _finchError = nil;
}

- (void)flushAndRemoveImage
{
    [self flush];
    self.contents = nil;
    BOOL changed = _finchReadyForDisplay;
    _finchReadyForDisplay = NO;
    if (changed)
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification object:self];
}

- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    @synchronized(self) {
        _finchRequestQueue = queue;
        _finchRequestBlock = [block copy];
    }
    [self _finchScheduleRequestBlock];
}

- (void)stopRequestingMediaData
{
    @synchronized(self) {
        _finchRequestBlock = nil;
        _finchRequestQueue = nil;
    }
}

@end

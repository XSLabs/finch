/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetImageGenerator: the video frame on screen at a time, decoded (JPEG through
 * ImageIO), as Apple's (macOS 26.4, avimage-test.m): the sample whose presentation
 * covers the time, the last one past the end, its time as the actual time; sized to fit
 * maximumSize keeping its aspect; turned by the track's transform when asked. The
 * tolerances default to infinity; asynchronous requests are answered in order on a
 * background queue.
 */
#import "AVFInternal.h"

@interface AVURLAsset (FinchImages)
- (AVFMovie *)_finchMovie;
@end

@interface AVAssetTrack (FinchImages)
- (AVFTrack *)_finchTrack;
@end

@implementation AVAssetImageGenerator {
    AVAsset *_fasset;
    BOOL _ftransform;
    CGSize _fmax;
    AVAssetImageGeneratorApertureMode _faperture;
    CMTime _fbefore, _fafter;
    AVVideoComposition *_fcomposition;
    dispatch_queue_t _fqueue;
    BOOL _fcancelled;
}

+ (instancetype)assetImageGeneratorWithAsset:(AVAsset *)asset { return [[self alloc] initWithAsset:asset]; }

- (instancetype)initWithAsset:(AVAsset *)asset
{
    if ((self = [super init])) {
        _fasset = asset;
        _fbefore = kCMTimePositiveInfinity;
        _fafter = kCMTimePositiveInfinity;
        _fqueue = dispatch_queue_create("com.apple.avfoundation.imagegenerator", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (AVAsset *)asset { return _fasset; }
- (BOOL)appliesPreferredTrackTransform { return _ftransform; }
- (void)setAppliesPreferredTrackTransform:(BOOL)flag { _ftransform = flag; }
- (CGSize)maximumSize { return _fmax; }
- (void)setMaximumSize:(CGSize)size { _fmax = size; }
- (AVAssetImageGeneratorApertureMode)apertureMode { return _faperture; }
- (void)setApertureMode:(AVAssetImageGeneratorApertureMode)mode { _faperture = [mode copy]; }
- (CMTime)requestedTimeToleranceBefore { return _fbefore; }
- (void)setRequestedTimeToleranceBefore:(CMTime)t { _fbefore = t; }
- (CMTime)requestedTimeToleranceAfter { return _fafter; }
- (void)setRequestedTimeToleranceAfter:(CMTime)t { _fafter = t; }
- (AVVideoComposition *)videoComposition { return _fcomposition; }
- (void)setVideoComposition:(AVVideoComposition *)c { _fcomposition = c; }
- (id<AVVideoCompositing>)customVideoCompositor { return nil; }
- (AVAssetImageGeneratorDynamicRangePolicy)dynamicRangePolicy { return AVAssetImageGeneratorDynamicRangePolicyForceSDR; }
- (void)setDynamicRangePolicy:(AVAssetImageGeneratorDynamicRangePolicy)policy {}

static CGImageRef
fitted(CGImageRef im, CGSize max, CGAffineTransform transform, BOOL turn)
{
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im);
    CGRect turned = CGRectApplyAffineTransform(CGRectMake(0, 0, w, h), turn ? transform : CGAffineTransformIdentity);
    double tw = fabs(turned.size.width), th = fabs(turned.size.height);
    double scale = 1;
    if (max.width > 0 && max.height > 0)
        scale = MIN(1.0, MIN(max.width / tw, max.height / th));
    size_t ow = (size_t)lround(tw * scale), oh = (size_t)lround(th * scale);
    if (ow == w && oh == h && (!turn || CGAffineTransformIsIdentity(transform)))
        return CGImageRetain(im);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, ow, oh, 8, 0, cs, (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c)
        return NULL;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextScaleCTM(c, scale, scale);
    if (turn && !CGAffineTransformIsIdentity(transform)) {
        CGAffineTransform t = CGAffineTransformMake(transform.a, transform.b, transform.c, transform.d, 0, 0);
        CGRect r = CGRectApplyAffineTransform(CGRectMake(0, 0, w, h), t);
        CGContextTranslateCTM(c, -r.origin.x, -r.origin.y);
        CGContextConcatCTM(c, t);
    }
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), im);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

- (CGImageRef)copyCGImageAtTime:(CMTime)requestedTime actualTime:(CMTime *)actualTime error:(NSError **)outError
{
    AVAssetTrack *track = [_fasset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVFMovie *movie = [_fasset respondsToSelector:@selector(_finchMovie)] ? [(AVURLAsset *)_fasset _finchMovie] : nil;
    AVFTrack *t = [track _finchTrack];
    if (!track || !movie || !t || !t->sampleCount) {
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }
    CMTime at = CMTimeConvertScale(requestedTime, (int32_t)t->timescale, kCMTimeRoundingMethod_RoundTowardNegativeInfinity);
    size_t index = t->sampleCount - 1;
    for (size_t i = 0; i < t->sampleCount; i++) {
        int64_t pts = t->samples[i].decodeTime + t->samples[i].compositionOffset;
        if (at.value >= pts && at.value < pts + t->samples[i].duration) {
            index = i;
            break;
        }
        if (at.value < pts) {
            index = i ? i - 1 : 0;
            break;
        }
    }
    CGImageRef im = AVFCopySampleImage(t, movie->data, index);
    if (!im) {
        if (outError)
            *outError = AVFError(AVErrorDecoderNotFound, nil);
        return NULL;
    }
    if (actualTime)
        *actualTime = CMTimeMake(t->samples[index].decodeTime + t->samples[index].compositionOffset, (int32_t)t->timescale);
    CGImageRef out = fitted(im, _fmax, track.preferredTransform, _ftransform);
    CGImageRelease(im);
    return out;
}

- (void)generateCGImagesAsynchronouslyForTimes:(NSArray<NSValue *> *)requestedTimes
                             completionHandler:(AVAssetImageGeneratorCompletionHandler)handler
{
    AVAssetImageGeneratorCompletionHandler h = [handler copy];
    _fcancelled = NO;
    for (NSValue *v in requestedTimes) {
        CMTime requested = v.CMTimeValue;
        dispatch_async(_fqueue, ^{
            if (self->_fcancelled) {
                h(requested, NULL, kCMTimeInvalid, AVAssetImageGeneratorCancelled, nil);
                return;
            }
            CMTime actual = kCMTimeInvalid;
            NSError *e = nil;
            CGImageRef im = [self copyCGImageAtTime:requested actualTime:&actual error:&e];
            h(requested, im, actual, im ? AVAssetImageGeneratorSucceeded : AVAssetImageGeneratorFailed, e);
            CGImageRelease(im);
        });
    }
}

- (void)generateCGImageAsynchronouslyForTime:(CMTime)requestedTime
                           completionHandler:(void (^)(CGImageRef, CMTime, NSError *))handler
{
    void (^h)(CGImageRef, CMTime, NSError *) = [handler copy];
    dispatch_async(_fqueue, ^{
        CMTime actual = kCMTimeInvalid;
        NSError *e = nil;
        CGImageRef im = [self copyCGImageAtTime:requestedTime actualTime:&actual error:&e];
        h(im, actual, e);
        CGImageRelease(im);
    });
}

- (void)cancelAllCGImageGeneration { _fcancelled = YES; }

@end

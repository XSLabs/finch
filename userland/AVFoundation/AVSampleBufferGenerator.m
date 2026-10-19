/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Create file-backed sample buffers from Finch's parsed QuickTime sample table. */
#import "AVFInternal.h"
#import <AVFoundation/AVSampleBufferGenerator.h>
#import <AVFoundation/AVSampleCursor.h>
#import <AVFoundation/AVError.h>
#include <limits.h>

@interface AVSampleCursor (FinchSampleBufferGenerator)
- (AVAssetTrack *)_finchOwner;
- (AVFTrack *)_finchTrack;
- (NSUInteger)_finchIndex;
@end

@interface AVURLAsset (FinchSampleBufferGenerator)
- (AVFMovie *)_finchMovie;
@end

@interface AVSampleBufferGeneratorBatch ()
- (instancetype)initWithGenerator:(AVSampleBufferGenerator *)generator;
- (void)_finchKeepSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (BOOL)_finchBelongsToGenerator:(AVSampleBufferGenerator *)generator;
- (BOOL)_finchHasStarted;
@end

@implementation AVSampleBufferRequest {
    AVSampleCursor *_finchStartCursor;
    AVSampleCursor *_finchLimitCursor;
    AVSampleBufferRequestDirection _finchDirection;
    NSInteger _finchPreferredMinSampleCount;
    NSInteger _finchMaxSampleCount;
    AVSampleBufferRequestMode _finchMode;
    CMTime _finchOverrideTime;
}

- (instancetype)initWithStartCursor:(AVSampleCursor *)startCursor
{
    if (!startCursor)
        [NSException raise:NSInvalidArgumentException format:@"AVSampleBufferRequest requires a start cursor"];
    if ((self = [super init])) {
        _finchStartCursor = startCursor;
        _finchDirection = AVSampleBufferRequestDirectionNone;
        _finchMode = AVSampleBufferRequestModeImmediate;
        _finchOverrideTime = kCMTimeInvalid;
    }
    return self;
}

- (AVSampleCursor *)startCursor { return _finchStartCursor; }
- (AVSampleCursor *)limitCursor { return _finchLimitCursor; }
- (void)setLimitCursor:(AVSampleCursor *)cursor { _finchLimitCursor = cursor; }
- (AVSampleBufferRequestDirection)direction { return _finchDirection; }
- (void)setDirection:(AVSampleBufferRequestDirection)direction { _finchDirection = direction; }
- (NSInteger)preferredMinSampleCount { return _finchPreferredMinSampleCount; }
- (void)setPreferredMinSampleCount:(NSInteger)value { _finchPreferredMinSampleCount = value; }
- (NSInteger)maxSampleCount { return _finchMaxSampleCount; }
- (void)setMaxSampleCount:(NSInteger)value { _finchMaxSampleCount = value; }
- (AVSampleBufferRequestMode)mode { return _finchMode; }
- (void)setMode:(AVSampleBufferRequestMode)mode { _finchMode = mode; }
- (CMTime)overrideTime { return _finchOverrideTime; }
- (void)setOverrideTime:(CMTime)time { _finchOverrideTime = time; }

@end

@implementation AVSampleBufferGeneratorBatch {
    AVSampleBufferGenerator *_finchGenerator;
    NSMutableArray *_finchBuffers;
    BOOL _finchStarted, _finchCancelled;
}

- (instancetype)initWithGenerator:(AVSampleBufferGenerator *)generator
{
    if ((self = [super init])) {
        _finchGenerator = generator;
        _finchBuffers = [NSMutableArray array];
    }
    return self;
}

- (void)_finchKeepSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (sampleBuffer)
        [_finchBuffers addObject:(__bridge id)sampleBuffer];
}

- (BOOL)_finchBelongsToGenerator:(AVSampleBufferGenerator *)generator
{
    return _finchGenerator == generator;
}

- (BOOL)_finchHasStarted { return _finchStarted; }

- (void)makeDataReadyWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    if (_finchStarted)
        [NSException raise:NSInternalInconsistencyException format:@"AVSampleBufferGeneratorBatch can only be made ready once"];
    _finchStarted = YES;
    if (completionHandler)
        completionHandler(_finchCancelled ? AVFError(AVErrorOperationNotSupportedForAsset, nil) : nil);
}

- (void)cancel { _finchCancelled = YES; }

@end

@implementation AVSampleBufferGenerator {
    AVAsset *_finchAsset;
    CMTimebaseRef _finchTimebase;
}

- (instancetype)initWithAsset:(AVAsset *)asset timebase:(CMTimebaseRef)timebase
{
    if (!asset)
        [NSException raise:NSInvalidArgumentException format:@"AVSampleBufferGenerator requires an asset"];
    if ((self = [super init])) {
        _finchAsset = asset;
        _finchTimebase = timebase ? (CMTimebaseRef)CFRetain(timebase) : NULL;
    }
    return self;
}

- (void)dealloc
{
    if (_finchTimebase)
        CFRelease(_finchTimebase);
}

- (AVSampleBufferGeneratorBatch *)makeBatch
{
    return [[AVSampleBufferGeneratorBatch alloc] initWithGenerator:self];
}

- (CMSampleBufferRef)_finchSampleBufferForRequest:(AVSampleBufferRequest *)request error:(NSError **)outError
{
    AVSampleCursor *cursor = request.startCursor;
    AVAssetTrack *owner = [cursor _finchOwner];
    AVFTrack *track = [cursor _finchTrack];
    NSUInteger index = [cursor _finchIndex];
    if (!cursor || !owner || !track || owner.asset != _finchAsset || index >= track->sampleCount ||
        request.direction != AVSampleBufferRequestDirectionNone ||
        (request.mode != AVSampleBufferRequestModeImmediate && !_finchTimebase)) {
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }
    if (![_finchAsset isKindOfClass:[AVURLAsset class]]) {
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }
    AVFMovie *movie = [(AVURLAsset *)_finchAsset _finchMovie];
    AVFSample source = track->samples[index];
    if (!movie || source.offset > movie->data.length || source.size > movie->data.length - source.offset ||
        source.description >= track->formatDescriptions.count || !track->timescale) {
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, source.size, NULL, NULL, 0, source.size,
                                                         kCMBlockBufferAssureMemoryNowFlag, &block);
    if (!status)
        status = CMBlockBufferReplaceDataBytes((const uint8_t *)movie->data.bytes + source.offset, block, 0, source.size);
    if (status || !block) {
        if (block) CFRelease(block);
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }

    CMTime pts = CMTimeMake(source.decodeTime + source.compositionOffset, (int32_t)track->timescale);
    if (CMTIME_IS_NUMERIC(request.overrideTime))
        pts = request.overrideTime;
    CMSampleTimingInfo timing = {CMTimeMake(source.duration, (int32_t)track->timescale), pts,
                                 CMTimeMake(source.decodeTime, (int32_t)track->timescale)};
    size_t size = source.size;
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreate(NULL, block, true, NULL, NULL,
                                  (__bridge CMFormatDescriptionRef)track->formatDescriptions[source.description], 1, 1,
                                  &timing, 1, &size, &sampleBuffer);
    CFRelease(block);
    if (status || !sampleBuffer) {
        if (sampleBuffer) CFRelease(sampleBuffer);
        if (outError)
            *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }
    return sampleBuffer;
}

- (CMSampleBufferRef)createSampleBufferForRequest:(AVSampleBufferRequest *)request error:(NSError **)outError
{
    if (outError) *outError = nil;
    if (!request) {
        if (outError) *outError = AVFError(AVErrorOperationNotSupportedForAsset, nil);
        return NULL;
    }
    return [self _finchSampleBufferForRequest:request error:outError];
}

- (CMSampleBufferRef)createSampleBufferForRequest:(AVSampleBufferRequest *)request
{
    return [self createSampleBufferForRequest:request error:NULL];
}

- (CMSampleBufferRef)createSampleBufferForRequest:(AVSampleBufferRequest *)request
                                     addingToBatch:(AVSampleBufferGeneratorBatch *)batch
                                              error:(NSError **)outError
{
    if (!batch || ![batch _finchBelongsToGenerator:self])
        [NSException raise:NSInvalidArgumentException format:@"The batch must be made by this AVSampleBufferGenerator"];
    if (outError) *outError = nil;
    if (!request || [batch _finchHasStarted])
        [NSException raise:NSInternalInconsistencyException format:@"Cannot add a request to this batch"];
    CMSampleBufferRef sampleBuffer = [self _finchSampleBufferForRequest:request error:outError];
    if (sampleBuffer)
        [batch _finchKeepSampleBuffer:sampleBuffer];
    return sampleBuffer;
}

+ (void)notifyOfDataReadyForSampleBuffer:(CMSampleBufferRef)sampleBuffer completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(sampleBuffer && CMSampleBufferDataIsReady(sampleBuffer), nil);
}

@end

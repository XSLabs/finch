/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Pass-through exports over Finch's asset reader and movie writer. */
#import "AVFInternal.h"

@implementation AVAssetExportSession {
    AVAsset *_fasset;
    NSString *_fpreset;
    NSURL *_foutputURL;
    AVFileType _foutputType;
    AVAssetExportSessionStatus _fstatus;
    NSError *_ferror;
    CMTimeRange _frange;
    NSArray *_fmetadata;
    NSString *_faudioTimePitchAlgorithm;
    AVAudioMix *_faudioMix;
    AVVideoComposition *_fvideoComposition;
    NSURL *_ftemporaryDirectory;
    BOOL _foptimize;
    BOOL _fmultipass;
    BOOL _fparallel;
    BOOL _fcancelled;
    long long _ffileLengthLimit;
    AVAssetTrackGroupOutputHandling _faudioTrackGroupHandling;
    float _fprogress;
    AVAssetReader *_freader;
    AVAssetWriter *_fwriter;
}

+ (instancetype)exportSessionWithAsset:(AVAsset *)asset presetName:(NSString *)presetName
{
    return [[self alloc] initWithAsset:asset presetName:presetName];
}

- (instancetype)initWithAsset:(AVAsset *)asset presetName:(NSString *)presetName
{
    if (!asset || !presetName) {
        return nil;
    }
    if ((self = [super init])) {
        _fasset = asset;
        _fpreset = [presetName copy];
        _frange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
        _faudioTimePitchAlgorithm = [AVAudioTimePitchAlgorithmSpectral copy];
        _fparallel = YES;
    }
    return self;
}

+ (NSArray<NSString *> *)allExportPresets
{
    /* Passthrough is intentionally excluded by this API; Finch has no encoder presets. */
    return @[];
}

+ (NSArray<NSString *> *)exportPresetsCompatibleWithAsset:(AVAsset *)asset
{
    /* Passthrough is intentionally excluded by this API. */
    return @[];
}

+ (void)determineCompatibilityOfExportPreset:(NSString *)presetName
                                    withAsset:(AVAsset *)asset
                               outputFileType:(AVFileType)outputFileType
                            completionHandler:(void (^)(BOOL))handler
{
    BOOL supported = [presetName isEqualToString:AVAssetExportPresetPassthrough] &&
                     asset.isExportable && asset.tracks.count > 0 &&
                     (!outputFileType || [outputFileType isEqualToString:AVFileTypeQuickTimeMovie] ||
                      [outputFileType isEqualToString:AVFileTypeMPEG4]);
    if (handler)
        handler(supported);
}

- (NSString *)presetName { return _fpreset; }
- (AVAsset *)asset { return _fasset; }
- (AVFileType)outputFileType { return _foutputType; }
- (void)setOutputFileType:(AVFileType)type
{
    if (_fstatus != AVAssetExportSessionStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"outputFileType cannot change after export starts"];
    if (type && ![self.supportedFileTypes containsObject:type])
        [NSException raise:NSInvalidArgumentException format:@"The requested file type is not supported by this export session"];
    _foutputType = [type copy];
}
- (NSURL *)outputURL { return _foutputURL; }
- (void)setOutputURL:(NSURL *)url { if (_fstatus == AVAssetExportSessionStatusUnknown) _foutputURL = [url copy]; }
- (BOOL)shouldOptimizeForNetworkUse { return _foptimize; }
- (void)setShouldOptimizeForNetworkUse:(BOOL)flag { if (_fstatus == AVAssetExportSessionStatusUnknown) _foptimize = flag; }
- (AVAssetExportSessionStatus)status { return _fstatus; }
- (NSError *)error { return _ferror; }
- (float)progress { return _fprogress; }
- (CMTimeRange)timeRange { return _frange; }
- (void)setTimeRange:(CMTimeRange)range { if (_fstatus == AVAssetExportSessionStatusUnknown) _frange = range; }
- (long long)fileLengthLimit { return _ffileLengthLimit; }
- (void)setFileLengthLimit:(long long)limit { if (_fstatus == AVAssetExportSessionStatusUnknown) _ffileLengthLimit = MAX(0, limit); }
- (NSArray<AVFileType> *)supportedFileTypes
{
    if (![_fpreset isEqualToString:AVAssetExportPresetPassthrough] || !_fasset.isExportable || !_fasset.tracks.count)
        return @[];
    return @[AVFileTypeQuickTimeMovie, AVFileTypeMPEG4];
}
- (void)determineCompatibleFileTypesWithCompletionHandler:(void (^)(NSArray<AVFileType> *))handler
{
    if (handler)
        handler(self.supportedFileTypes);
}
- (CMTime)maxDuration { return _fasset.duration; }
- (long long)estimatedOutputFileLength { return 0; }
- (long long)estimatedOutputFileLengthInBytes { return 0; }
- (NSArray<AVMetadataItem *> *)metadata { return _fmetadata; }
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata { if (_fstatus == AVAssetExportSessionStatusUnknown) _fmetadata = [metadata copy]; }
- (NSString *)audioTimePitchAlgorithm { return _faudioTimePitchAlgorithm; }
- (void)setAudioTimePitchAlgorithm:(NSString *)algorithm { if (_fstatus == AVAssetExportSessionStatusUnknown && algorithm) _faudioTimePitchAlgorithm = [algorithm copy]; }
- (AVAudioMix *)audioMix { return _faudioMix; }
- (void)setAudioMix:(AVAudioMix *)audioMix { if (_fstatus == AVAssetExportSessionStatusUnknown) _faudioMix = [audioMix copy]; }
- (AVVideoComposition *)videoComposition { return _fvideoComposition; }
- (void)setVideoComposition:(AVVideoComposition *)composition { if (_fstatus == AVAssetExportSessionStatusUnknown) _fvideoComposition = [composition copy]; }
- (id<AVVideoCompositing>)customVideoCompositor { return nil; }
- (BOOL)canPerformMultiplePassesOverSourceMediaData { return _fmultipass; }
- (void)setCanPerformMultiplePassesOverSourceMediaData:(BOOL)flag { if (_fstatus == AVAssetExportSessionStatusUnknown) _fmultipass = flag; }
- (BOOL)allowsParallelizedExport { return _fparallel; }
- (void)setAllowsParallelizedExport:(BOOL)flag { if (_fstatus == AVAssetExportSessionStatusUnknown) _fparallel = flag; }
- (AVAssetTrackGroupOutputHandling)audioTrackGroupHandling { return _faudioTrackGroupHandling; }
- (void)setAudioTrackGroupHandling:(AVAssetTrackGroupOutputHandling)handling
{
    if (_fstatus == AVAssetExportSessionStatusUnknown)
        _faudioTrackGroupHandling = handling;
}
- (NSURL *)directoryForTemporaryFiles { return _ftemporaryDirectory; }
- (void)setDirectoryForTemporaryFiles:(NSURL *)url { if (_fstatus == AVAssetExportSessionStatusUnknown) _ftemporaryDirectory = [url copy]; }

- (void)_finchSetStatus:(AVAssetExportSessionStatus)status
{
    [self willChangeValueForKey:@"status"];
    _fstatus = status;
    [self didChangeValueForKey:@"status"];
}

- (void)_finchSetError:(NSError *)error
{
    _ferror = error;
    [self _finchSetStatus:_fcancelled ? AVAssetExportSessionStatusCancelled : AVAssetExportSessionStatusFailed];
}

- (void)_finchExport:(void (^)(void))handler
{
    @autoreleasepool {
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_fasset error:&error];
        if (!reader) {
            [self _finchSetError:error ?: AVFError(AVErrorExportFailed, nil)];
            goto finished;
        }
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:_foutputURL fileType:_foutputType error:&error];
        if (!writer) {
            [self _finchSetError:error ?: AVFError(AVErrorExportFailed, nil)];
            goto finished;
        }
        @synchronized (self) {
            _freader = reader;
            _fwriter = writer;
        }
        if (CMTIMERANGE_IS_VALID(_frange) && CMTIME_IS_NUMERIC(_frange.start) &&
            (CMTIME_IS_NUMERIC(_frange.duration) || CMTimeCompare(_frange.start, kCMTimeZero) != 0))
            reader.timeRange = _frange;

        NSMutableArray *outputs = [NSMutableArray array];
        NSMutableArray *inputs = [NSMutableArray array];
        NSArray<AVAssetTrack *> *tracks = _fasset.tracks;
        BOOL configured = tracks.count > 0;
        for (AVAssetTrack *track in tracks) {
            AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType
                outputSettings:nil sourceFormatHint:format];
            if (![reader canAddOutput:output] || ![writer canAddInput:input]) {
                configured = NO;
                break;
            }
            [reader addOutput:output];
            [writer addInput:input];
            [outputs addObject:output];
            [inputs addObject:input];
        }
        writer.shouldOptimizeForNetworkUse = _foptimize;
        writer.metadata = _fmetadata ?: _fasset.metadata;
        if (!configured || !reader.startReading || !writer.startWriting) {
            NSError *failure = writer.error ?: reader.error ?: AVFError(AVErrorExportFailed, nil);
            [writer cancelWriting];
            [reader cancelReading];
            [self _finchSetError:failure];
            goto finished;
        }
        CMTime start = CMTIME_IS_NUMERIC(_frange.start) ? _frange.start : kCMTimeZero;
        [writer startSessionAtSourceTime:start];
        NSUInteger totalTracks = inputs.count;
        NSUInteger trackIndex = 0;
        for (AVAssetReaderTrackOutput *output in outputs) {
            AVAssetWriterInput *input = inputs[trackIndex++];
            CMSampleBufferRef sample;
            while (!_fcancelled && (sample = [output copyNextSampleBuffer])) {
                if (![input appendSampleBuffer:sample]) {
                    CFRelease(sample);
                    error = writer.error ?: AVFError(AVErrorExportFailed, nil);
                    break;
                }
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                if (CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(_fasset.duration) && _fasset.duration.value > 0) {
                    float progress = (float)(CMTimeGetSeconds(pts) / CMTimeGetSeconds(_fasset.duration));
                    if (progress > _fprogress && progress < 1) {
                        [self willChangeValueForKey:@"progress"];
                        _fprogress = progress;
                        [self didChangeValueForKey:@"progress"];
                    }
                }
                CFRelease(sample);
            }
            [input markAsFinished];
            if (error || _fcancelled)
                break;
            [self willChangeValueForKey:@"progress"];
            _fprogress = MIN(0.95f, (float)trackIndex / (float)MAX(totalTracks, (NSUInteger)1));
            [self didChangeValueForKey:@"progress"];
        }
        if (_fcancelled || error || reader.status == AVAssetReaderStatusFailed) {
            NSError *failure = error ?: reader.error ?: AVFError(AVErrorExportFailed, nil);
            [reader cancelReading];
            [writer cancelWriting];
            [self _finchSetError:failure];
            goto finished;
        }
        CMTime end = CMTIME_IS_NUMERIC(_frange.duration) ? CMTimeAdd(start, _frange.duration) : _fasset.duration;
        if (CMTIME_IS_NUMERIC(end))
            [writer endSessionAtSourceTime:end];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (writer.status != AVAssetWriterStatusCompleted) {
            NSError *failure = writer.error ?: AVFError(AVErrorExportFailed, nil);
            [self _finchSetError:failure];
            goto finished;
        }
        if (_ffileLengthLimit > 0) {
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_foutputURL.path error:&error];
            if ([attributes[NSFileSize] longLongValue] > _ffileLengthLimit) {
                [[NSFileManager defaultManager] removeItemAtURL:_foutputURL error:NULL];
                [self _finchSetError:AVFError(AVErrorExportFailed, nil)];
                goto finished;
            }
        }
        [self willChangeValueForKey:@"progress"];
        _fprogress = 1;
        [self didChangeValueForKey:@"progress"];
        [self _finchSetStatus:AVAssetExportSessionStatusCompleted];
    }
finished:
    if (handler)
        handler();
}

- (void)exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler
{
    if (_fstatus != AVAssetExportSessionStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"-[AVAssetExportSession exportAsynchronouslyWithCompletionHandler:] called after export started"];
    if (!_foutputType)
        [NSException raise:NSInternalInconsistencyException format:@"outputFileType must be set before export starts"];
    if (![_fpreset isEqualToString:AVAssetExportPresetPassthrough] ||
        (![_foutputType isEqualToString:AVFileTypeQuickTimeMovie] && ![_foutputType isEqualToString:AVFileTypeMPEG4]) ||
        !_foutputURL || !_fasset.isExportable || !_fasset.tracks.count) {
        [self _finchSetError:AVFError(AVErrorExportFailed, nil)];
        if (handler)
            handler();
        return;
    }
    [self _finchSetStatus:AVAssetExportSessionStatusExporting];
    void (^done)(void) = [handler copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self _finchExport:done];
    });
}

- (void)cancelExport
{
    if (_fstatus != AVAssetExportSessionStatusExporting)
        return;
    @synchronized (self) {
        _fcancelled = YES;
        [_freader cancelReading];
        [_fwriter cancelWriting];
    }
}

- (void)estimateMaximumDurationWithCompletionHandler:(void (^)(CMTime, NSError *))handler
{
    if (handler)
        handler(_fasset.duration, nil);
}

- (void)estimateOutputFileLengthWithCompletionHandler:(void (^)(int64_t, NSError *))handler
{
    if (handler)
        handler(0, nil);
}

@end

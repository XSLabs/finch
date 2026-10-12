/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetReader and AVAssetReaderTrackOutput over Finch's movie reader. As Apple's
 * (macOS 26.4, avreader-test.m):
 *   - Without output settings a track's samples come as they are stored: video a sample
 *     a buffer, the first marked ResetDecoderBeforeDecoding, after an EditBoundary marker
 *     at the start of the range; audio a chunk a buffer (PCM cut to the range). Then
 *     DrainAfterDecoding, for video PostNotificationWhenConsumed (from the range's end
 *     onwards), and EmptyMedia at the range's end (with PermanentEmptyMedia for video, and
 *     for audio read over less than the whole asset).
 *   - With output settings video is decoded to pixel buffers (JPEG through ImageIO;
 *     BGRA, ARGB or RGBA), its buffers' durations left invalid; audio is converted
 *     (AudioToolbox) to the linear PCM asked for, 8192 frames a buffer. Decoded outputs
 *     carry no markers.
 *   - The reader completes when every output has given its last buffer; outputs can't
 *     be added once it has started (NSInternalInconsistencyException). An asset that
 *     can't be read gives no reader, and its error.
 * Codecs other than JPEG (H.264, HEVC, AAC) wait for VideoToolbox and AudioToolbox.
 */
#import "AVFInternal.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

@interface AVURLAsset (FinchReading)
- (AVFMovie *)_finchMovie;
- (NSError *)_finchError;
@end

@interface AVAssetTrack (FinchReading)
- (AVFTrack *)_finchTrack;
@end

@interface AVAssetReaderOutput ()
- (void)_finchStartWithReader:(AVAssetReader *)reader movie:(AVFMovie *)movie range:(CMTimeRange)range;
- (BOOL)_finchFinished;
@end

#pragma mark - Sample buffers

static CMSampleBufferRef
marker(CMTime pts, CFStringRef key, CFTypeRef value)
{
    CMSampleTimingInfo t = {kCMTimeZero, pts, kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreate(NULL, NULL, true, NULL, NULL, NULL, 0, 1, &t, 0, NULL, &sb);
    if (sb && key)
        CMSetAttachment(sb, key, value, kCMAttachmentMode_ShouldPropagate);
    return sb;
}

static CMBlockBufferRef
block_of(NSData *file, uint64_t offset, size_t size)
{
    CMBlockBufferRef bb = NULL;
    if (offset + size > file.length)
        return NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &bb))
        return NULL;
    CMBlockBufferReplaceDataBytes((const uint8_t *)file.bytes + offset, bb, 0, size);
    return bb;
}

#pragma mark - Outputs

@implementation AVAssetReaderOutput {
@protected
    NSMutableArray *_queue;     /* CMSampleBufferRef, prepared */
    __weak AVAssetReader *_reader;
    BOOL _started, _finished, _copies;
}

- (instancetype)init
{
    if ((self = [super init]))
        _copies = YES;
    return self;
}

- (NSString *)mediaType { return nil; }
- (BOOL)alwaysCopiesSampleData { return _copies; }
- (void)setAlwaysCopiesSampleData:(BOOL)flag { _copies = flag; }
- (BOOL)supportsRandomAccess { return NO; }
- (void)setSupportsRandomAccess:(BOOL)flag {}
- (void)resetForReadingTimeRanges:(NSArray<NSValue *> *)timeRanges {}
- (void)markConfigurationAsFinal {}
- (BOOL)_finchFinished { return _finished || !_started; }

- (void)_finchStartWithReader:(AVAssetReader *)reader movie:(AVFMovie *)movie range:(CMTimeRange)range
{
    _reader = reader;
    _started = YES;
    _queue = [NSMutableArray array];
}

/* More buffers for the queue; NO when there are none. */
- (BOOL)_finchFill { return NO; }

- (CMSampleBufferRef)copyNextSampleBuffer
{
    AVAssetReader *r = _reader;
    if (!_started || _finished || !r || r.status != AVAssetReaderStatusReading)
        return NULL;
    while (![_queue count])
        if (![self _finchFill]) {
            _finished = YES;
            [r performSelector:@selector(_finchOutputFinished)];
            return NULL;
        }
    CMSampleBufferRef sb = (__bridge_retained CMSampleBufferRef)_queue[0];
    [_queue removeObjectAtIndex:0];
    return sb;
}

@end

@implementation AVAssetReaderTrackOutput {
    AVAssetTrack *_ftrack;
    NSDictionary *_settings;
    AVFTrack *_t;
    NSData *_file;
    CMTimeRange _range;
    BOOL _wholeAsset;
    size_t _next;
    int _phase; /* 0 before, 1 samples, 2 markers, 3 done */
    AudioConverterRef _converter;
    AudioStreamBasicDescription _outFormat;
    CMAudioFormatDescriptionRef _outDesc;
    int64_t _audioFrame, _audioEnd;
    BOOL _queuedAny;
}

+ (instancetype)assetReaderTrackOutputWithTrack:(AVAssetTrack *)track outputSettings:(NSDictionary<NSString *, id> *)outputSettings
{
    return [[self alloc] initWithTrack:track outputSettings:outputSettings];
}

- (instancetype)initWithTrack:(AVAssetTrack *)track outputSettings:(NSDictionary<NSString *, id> *)outputSettings
{
    if ((self = [super init])) {
        _ftrack = track;
        _settings = [outputSettings copy];
    }
    return self;
}

- (void)dealloc
{
    if (_converter)
        AudioConverterDispose(_converter);
    if (_outDesc)
        CFRelease(_outDesc);
}

- (AVAssetTrack *)track { return _ftrack; }
- (NSDictionary *)outputSettings { return _settings; }
- (NSString *)mediaType { return _ftrack.mediaType; }
- (AVAudioTimePitchAlgorithm)audioTimePitchAlgorithm { return AVAudioTimePitchAlgorithmSpectral; }
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {}

- (BOOL)_finchIsVideo { return _t->handler == 'vide'; }
- (BOOL)_finchIsAudio { return _t->handler == 'soun'; }

- (void)_finchStartWithReader:(AVAssetReader *)reader movie:(AVFMovie *)movie range:(CMTimeRange)range
{
    [super _finchStartWithReader:reader movie:movie range:range];
    _t = [_ftrack _finchTrack];
    _file = movie->data;
    _range = range;
    CMTime assetEnd = movie->timescale ? CMTimeMake((int64_t)movie->duration, (int32_t)movie->timescale) : kCMTimeZero;
    _wholeAsset = CMTimeCompare(CMTimeRangeGetEnd(range), assetEnd) >= 0 || CMTIME_IS_POSITIVE_INFINITY(range.duration);
    if (_settings && [self _finchIsAudio])
        [self _finchSetUpConverter];
}

/* The range, in a time scale's units. */
- (void)_finchRange:(uint32_t)timescale start:(int64_t *)start end:(int64_t *)end
{
    CMTime s = CMTimeConvertScale(_range.start, (int32_t)timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    *start = s.value;
    *end = CMTIME_IS_POSITIVE_INFINITY(_range.duration)
               ? INT64_MAX
               : CMTimeConvertScale(CMTimeRangeGetEnd(_range), (int32_t)timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
}

/* The track's end as a reading range sees it, in the movie's timescale. */
- (CMTime)_finchEnd
{
    CMTimeRange tr = _ftrack.timeRange;
    CMTime end = CMTimeRangeGetEnd(tr);
    if (!CMTIME_IS_POSITIVE_INFINITY(_range.duration) && CMTimeCompare(CMTimeRangeGetEnd(_range), end) < 0)
        end = CMTimeRangeGetEnd(_range);
    return end;
}

- (BOOL)_finchFill
{
    if (!_t)
        return NO;
    if (_settings)
        return [self _finchIsAudio] ? [self _finchFillDecodedAudio] : [self _finchFillDecodedVideo];
    return [self _finchFillStored];
}

#pragma mark Stored samples

- (CMFormatDescriptionRef)_finchDescription:(uint32_t)index
{
    NSArray *fds = _t->formatDescriptions;
    return index < fds.count ? (__bridge CMFormatDescriptionRef)fds[index] : (fds.count ? (__bridge CMFormatDescriptionRef)fds[0] : NULL);
}

- (BOOL)_finchFillStored
{
    int64_t start, end;
    [self _finchRange:_t->timescale start:&start end:&end];
    BOOL video = [self _finchIsVideo];
    if (_phase == 0) {
        _phase = 1;
        /* the first sample in range */
        _next = 0;
        while (_next < _t->sampleCount && _t->samples[_next].decodeTime + _t->samples[_next].duration <= start)
            _next++;
        if (video) {
            CMSampleBufferRef m = marker(_range.start, CFSTR("EditBoundary"), kCFBooleanTrue);
            [_queue addObject:(__bridge_transfer id)m];
            return YES;
        }
    }
    if (_phase == 1) {
        if (_next < _t->sampleCount && _t->samples[_next].decodeTime < end) {
            if ([self _finchIsAudio] && _t->formatDescriptions.count) {
                [self _finchQueueStoredAudioFrom:start to:end];
            } else {
                AVFSample s = _t->samples[_next];
                CMBlockBufferRef bb = block_of(_file, s.offset, s.size);
                CMSampleTimingInfo timing = {CMTimeMake(s.duration, (int32_t)_t->timescale),
                                             CMTimeMake(s.decodeTime + s.compositionOffset, (int32_t)_t->timescale),
                                             CMTimeMake(s.decodeTime, (int32_t)_t->timescale)};
                if (!s.compositionOffset)
                    timing.decodeTimeStamp = kCMTimeInvalid;
                size_t size = s.size;
                CMSampleBufferRef sb = NULL;
                CMSampleBufferCreate(NULL, bb, true, NULL, NULL, [self _finchDescription:s.description], 1, 1, &timing, 1, &size, &sb);
                if (bb)
                    CFRelease(bb);
                if (sb) {
                    /* (as Apple's, every stored sample has its attachments dictionary) */
                    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
                    if (!s.sync) {
                        if (atts && CFArrayGetCount(atts))
                            CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0), kCMSampleAttachmentKey_NotSync,
                                                 kCFBooleanTrue);
                    }
                    if (video && !_queuedAny)
                        CMSetAttachment(sb, kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding, kCFBooleanTrue,
                                        kCMAttachmentMode_ShouldPropagate);
                    [_queue addObject:(__bridge_transfer id)sb];
                }
                _queuedAny = YES;
                _next++;
            }
            return YES;
        }
        _phase = 2;
        CMTime end = [self _finchEnd];
        [_queue addObject:(__bridge_transfer id)marker(kCMTimeInvalid, kCMSampleBufferAttachmentKey_DrainAfterDecoding, kCFBooleanTrue)];
        if (video) {
            NSDictionary *note = @{
                @"StartPresentationTimesStamp" : (__bridge_transfer NSDictionary *)CMTimeCopyAsDictionary(end, NULL),
                @"EndPresentationTimesStamp" : (__bridge_transfer NSDictionary *)CMTimeCopyAsDictionary(kCMTimePositiveInfinity, NULL)
            };
            [_queue addObject:(__bridge_transfer id)marker(kCMTimeInvalid, kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed,
                                                           (__bridge CFTypeRef)note)];
        }
        CMSampleBufferRef empty = marker(end, kCMSampleBufferAttachmentKey_EmptyMedia, kCFBooleanTrue);
        if (video || !_wholeAsset)
            CMSetAttachment(empty, kCMSampleBufferAttachmentKey_PermanentEmptyMedia, kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
        [_queue addObject:(__bridge_transfer id)empty];
        return YES;
    }
    return NO;
}

/* PCM (or any audio stored in frames) from a chunk: one buffer of the chunk's samples,
   cut to the range. */
- (void)_finchQueueStoredAudioFrom:(int64_t)start to:(int64_t)end
{
    AVFSample first = _t->samples[_next];
    size_t n = 0;
    uint64_t bytes = 0;
    /* (the run of samples stored together) */
    while (_next + n < _t->sampleCount) {
        AVFSample s = _t->samples[_next + n];
        if (s.offset != first.offset + bytes || s.description != first.description || s.decodeTime >= end)
            break;
        bytes += s.size;
        n++;
    }
    /* cut to the range: whole samples only */
    size_t skip = 0;
    while (skip < n && _t->samples[_next + skip].decodeTime < start)
        skip++;
    size_t count = n - skip;
    uint64_t at = first.offset;
    for (size_t i = 0; i < skip; i++)
        at += _t->samples[_next + i].size;
    uint64_t size = 0;
    for (size_t i = skip; i < n; i++)
        size += _t->samples[_next + i].size;
    if (count) {
        AVFSample s0 = _t->samples[_next + skip];
        CMBlockBufferRef bb = block_of(_file, at, (size_t)size);
        CMSampleTimingInfo timing = {CMTimeMake(s0.duration, (int32_t)_t->timescale), CMTimeMake(s0.decodeTime, (int32_t)_t->timescale),
                                     kCMTimeInvalid};
        size_t sampleSize = s0.size;
        CMSampleBufferRef sb = NULL;
        CMSampleBufferCreate(NULL, bb, true, NULL, NULL, [self _finchDescription:s0.description], (CMItemCount)count, 1, &timing, 1,
                             &sampleSize, &sb);
        if (bb)
            CFRelease(bb);
        if (sb)
            [_queue addObject:(__bridge_transfer id)sb];
        _queuedAny = YES;
    }
    _next += n;
}

#pragma mark Decoded video

static OSType
pixel_format(NSDictionary *settings)
{
    id f = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    if ([f isKindOfClass:[NSArray class]])
        f = [f firstObject];
    return f ? (OSType)[f unsignedIntValue] : kCVPixelFormatType_32BGRA;
}

CGImageRef
AVFCopySampleImage(AVFTrack *track, NSData *file, size_t index)
{
    if (index >= track->sampleCount)
        return NULL;
    AVFSample s = track->samples[index];
    NSArray *fds = track->formatDescriptions;
    CMFormatDescriptionRef fd = s.description < fds.count ? (__bridge CMFormatDescriptionRef)fds[s.description]
                                : fds.count                ? (__bridge CMFormatDescriptionRef)fds[0]
                                                           : NULL;
    FourCharCode codec = fd ? CMFormatDescriptionGetMediaSubType(fd) : 0;
    if (codec != 'jpeg' && codec != 'mjpa' && codec != 'dmb1')
        return NULL;
    if (s.offset + s.size > file.length)
        return NULL;
    NSData *jpeg = [NSData dataWithBytesNoCopy:(void *)((const uint8_t *)file.bytes + s.offset) length:s.size freeWhenDone:NO];
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src)
        CFRelease(src);
    return im;
}

- (CVPixelBufferRef)_finchDecodeSample:(size_t)index
{
    CGImageRef im = AVFCopySampleImage(_t, _file, index);
    if (!im)
        return NULL;
    OSType format = pixel_format(_settings);
    uint32_t info;
    switch (format) {
    case kCVPixelFormatType_32ARGB: info = (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Big; break;
    case kCVPixelFormatType_32RGBA: info = (uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big; break;
    default:
        format = kCVPixelFormatType_32BGRA;
        info = (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little;
        break;
    }
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im);
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    if (CVPixelBufferCreate(NULL, w, h, format, (__bridge CFDictionaryRef)attrs, &pb)) {
        CGImageRelease(im);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb), cs, info);
    CGColorSpaceRelease(cs);
    if (c) {
        CGContextSetBlendMode(c, kCGBlendModeCopy);
        CGContextDrawImage(c, CGRectMake(0, 0, w, h), im);
        CGContextRelease(c);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(im);
    /* the colour JPEG implies, as Apple's decoder tags it */
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    return pb;
}

- (BOOL)_finchFillDecodedVideo
{
    int64_t start, end;
    [self _finchRange:_t->timescale start:&start end:&end];
    if (_phase == 0) {
        _phase = 1;
        while (_next < _t->sampleCount && _t->samples[_next].decodeTime + _t->samples[_next].duration <= start)
            _next++;
    }
    while (_next < _t->sampleCount && _t->samples[_next].decodeTime < end) {
        AVFSample s = _t->samples[_next];
        CVPixelBufferRef pb = [self _finchDecodeSample:_next++];
        if (!pb) {
            [_reader performSelector:@selector(_finchFailWithError:) withObject:AVFError(AVErrorDecoderNotFound, nil)];
            return NO;
        }
        CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fd);
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(s.decodeTime + s.compositionOffset, (int32_t)_t->timescale), kCMTimeInvalid};
        CMSampleBufferRef sb = NULL;
        CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, fd, &timing, &sb);
        if (fd)
            CFRelease(fd);
        CVPixelBufferRelease(pb);
        if (sb) {
            [_queue addObject:(__bridge_transfer id)sb];
            return YES;
        }
    }
    return NO;
}

#pragma mark Decoded audio

- (void)_finchSetUpConverter
{
    if (!_t->formatDescriptions.count)
        return;
    const AudioStreamBasicDescription *in =
        CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)_t->formatDescriptions[0]);
    if (!in)
        return;
    AudioStreamBasicDescription out = {0};
    out.mFormatID = kAudioFormatLinearPCM;
    out.mSampleRate = _settings[AVSampleRateKey] ? [_settings[AVSampleRateKey] doubleValue] : in->mSampleRate;
    out.mChannelsPerFrame = _settings[AVNumberOfChannelsKey] ? [_settings[AVNumberOfChannelsKey] unsignedIntValue] : in->mChannelsPerFrame;
    BOOL isFloat = _settings[AVLinearPCMIsFloatKey] ? [_settings[AVLinearPCMIsFloatKey] boolValue] : NO;
    out.mBitsPerChannel = _settings[AVLinearPCMBitDepthKey] ? [_settings[AVLinearPCMBitDepthKey] unsignedIntValue] : (isFloat ? 32 : 16);
    BOOL big = [_settings[AVLinearPCMIsBigEndianKey] boolValue];
    BOOL planar = [_settings[AVLinearPCMIsNonInterleaved] boolValue];
    out.mFormatFlags = kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                       (big ? kAudioFormatFlagIsBigEndian : 0) | (planar ? kAudioFormatFlagIsNonInterleaved : 0);
    UInt32 bytes = out.mBitsPerChannel / 8;
    out.mBytesPerFrame = planar ? bytes : bytes * out.mChannelsPerFrame;
    out.mBytesPerPacket = out.mBytesPerFrame;
    out.mFramesPerPacket = 1;
    _outFormat = out;
    AudioConverterNew(in, &out, &_converter);
    CMAudioFormatDescriptionCreate(NULL, &out, 0, NULL, 0, NULL, NULL, &_outDesc);
    int64_t start, end;
    [self _finchRange:_t->timescale start:&start end:&end];
    _audioFrame = start;
    _audioEnd = MIN(end, (int64_t)_t->sampleCount);
}

typedef struct {
    const uint8_t *data;
    UInt32 bytes, bytesPerFrame;
    bool used;
} ConverterInput;

static OSStatus
supply(AudioConverterRef c, UInt32 *packets, AudioBufferList *io, AudioStreamPacketDescription **descs, void *info)
{
    ConverterInput *in = info;
    if (in->used || !in->bytes) {
        *packets = 0;
        return noErr;
    }
    io->mBuffers[0].mData = (void *)in->data;
    io->mBuffers[0].mDataByteSize = in->bytes;
    *packets = in->bytes / in->bytesPerFrame;
    in->used = true;
    return noErr;
}

- (BOOL)_finchFillDecodedAudio
{
    if (!_converter || _audioFrame >= _audioEnd || !_t->sampleCount)
        return NO;
    /* (PCM stored a frame a sample: 8192 frames at a time, from their places in the file) */
    const AudioStreamBasicDescription *in =
        CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)_t->formatDescriptions[0]);
    UInt32 frames = (UInt32)MIN((int64_t)8192, _audioEnd - _audioFrame);
    NSMutableData *src = [NSMutableData dataWithCapacity:frames * in->mBytesPerFrame];
    for (UInt32 i = 0; i < frames; i++) {
        AVFSample s = _t->samples[_audioFrame + i];
        if (s.offset + s.size > _file.length)
            break;
        [src appendBytes:(const uint8_t *)_file.bytes + s.offset length:s.size];
    }
    UInt32 outBytes = frames * _outFormat.mBytesPerFrame;
    UInt32 channels = (_outFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? _outFormat.mChannelsPerFrame : 1;
    NSMutableData *dst = [NSMutableData dataWithLength:outBytes * channels];
    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + channels * sizeof(AudioBuffer));
    abl->mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        abl->mBuffers[c].mNumberChannels = channels == 1 ? _outFormat.mChannelsPerFrame : 1;
        abl->mBuffers[c].mData = (uint8_t *)dst.mutableBytes + c * outBytes;
        abl->mBuffers[c].mDataByteSize = outBytes;
    }
    ConverterInput ci = {src.bytes, (UInt32)src.length, in->mBytesPerFrame, false};
    UInt32 packets = frames;
    AudioConverterFillComplexBuffer(_converter, supply, &ci, &packets, abl, NULL);
    AudioConverterReset(_converter);
    free(abl);
    if (!packets)
        return NO;
    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, NULL, dst.length, NULL, NULL, 0, dst.length, kCMBlockBufferAssureMemoryNowFlag, &bb);
    CMBlockBufferReplaceDataBytes(dst.bytes, bb, 0, dst.length);
    CMSampleBufferRef sb = NULL;
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, _outDesc, packets, CMTimeMake(_audioFrame, (int32_t)_t->timescale), NULL, &sb);
    if (bb)
        CFRelease(bb);
    _audioFrame += frames;
    if (!sb)
        return NO;
    [_queue addObject:(__bridge_transfer id)sb];
    return YES;
}

@end

#pragma mark - The reader

@implementation AVAssetReader {
    AVAsset *_fasset;
    AVFMovie *_fmovie;
    NSMutableArray *_foutputs;
    AVAssetReaderStatus _fstatus;
    NSError *_ferror;
    CMTimeRange _frange;
}

+ (instancetype)assetReaderWithAsset:(AVAsset *)asset error:(NSError **)outError
{
    return [[self alloc] initWithAsset:asset error:outError];
}

- (instancetype)initWithAsset:(AVAsset *)asset error:(NSError **)outError
{
    if (!(self = [super init]))
        return nil;
    _fasset = asset;
    _foutputs = [NSMutableArray array];
    _frange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    if ([asset respondsToSelector:@selector(_finchMovie)])
        _fmovie = [(AVURLAsset *)asset _finchMovie];
    if (!_fmovie) {
        NSError *e = [asset respondsToSelector:@selector(_finchError)] ? [(AVURLAsset *)asset _finchError] : nil;
        if (outError)
            *outError = e ?: AVFError(AVErrorUnknown, nil);
        return nil;
    }
    return self;
}

- (AVAsset *)asset { return _fasset; }
- (AVAssetReaderStatus)status { return _fstatus; }
- (NSError *)error { return _ferror; }
- (CMTimeRange)timeRange { return _frange; }

- (void)setTimeRange:(CMTimeRange)timeRange
{
    if (_fstatus != AVAssetReaderStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"-[AVAssetReader setTimeRange:] cannot be called after reading has started"];
    _frange = timeRange;
}

- (NSArray<AVAssetReaderOutput *> *)outputs { return [_foutputs copy]; }

- (BOOL)canAddOutput:(AVAssetReaderOutput *)output
{
    return _fstatus == AVAssetReaderStatusUnknown && output && ![_foutputs containsObject:output];
}

- (void)addOutput:(AVAssetReaderOutput *)output
{
    if (_fstatus != AVAssetReaderStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"-[AVAssetReader addOutput:] cannot add an output after reading has started"];
    if (output && ![_foutputs containsObject:output])
        [_foutputs addObject:output];
}

- (BOOL)startReading
{
    if (_fstatus != AVAssetReaderStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"-[AVAssetReader startReading] cannot be called again after reading has already started"];
    _fstatus = AVAssetReaderStatusReading;
    for (AVAssetReaderOutput *o in _foutputs)
        [o _finchStartWithReader:self movie:_fmovie range:_frange];
    return YES;
}

- (void)cancelReading
{
    if (_fstatus == AVAssetReaderStatusReading || _fstatus == AVAssetReaderStatusUnknown)
        _fstatus = AVAssetReaderStatusCancelled;
}

- (void)_finchOutputFinished
{
    for (AVAssetReaderOutput *o in _foutputs)
        if (![o _finchFinished])
            return;
    if (_fstatus == AVAssetReaderStatusReading)
        _fstatus = AVAssetReaderStatusCompleted;
}

- (void)_finchFailWithError:(NSError *)error
{
    _ferror = error;
    _fstatus = AVAssetReaderStatusFailed;
}

@end

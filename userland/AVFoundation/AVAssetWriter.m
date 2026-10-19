/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAssetWriter, AVAssetWriterInput and AVAssetWriterInputPixelBufferAdaptor, writing
 * QuickTime and MPEG-4 files with Finch's own muxer: 'ftyp' ('qt  ', or 'mp42' with
 * 'mp41', 'mp42' and 'isom'), 'wide', 'mdat' as samples arrive, then 'moov' with a
 * track per input (edit list, sample table, the sample description CoreMedia writes)
 * and the metadata ('meta' with 'keys' and 'ilst' for QuickTime metadata, 'udta' text
 * for user data). As Apple's (macOS 26.4, avwriter-test.m):
 *   - Inputs are ready for data once writing has started; the adaptor's pool exists from
 *     then on. Inputs can't be added after starting (NSInternalInconsistencyException).
 *   - A file already at the URL fails startWriting with AVErrorFileAlreadyExists.
 *   - Video is encoded as JPEG (ImageIO; AVVideoQualityKey, 0.75 otherwise); audio is
 *     written as the linear PCM the settings ask for, converted by AudioToolbox; inputs
 *     without settings write the samples they're given as they are.
 *   - The movie's timescale is 600 (or movieTimeScale); video media takes the movie's,
 *     audio its sample rate. A video sample lasts until the next; the last until the
 *     session's end (or as long as the one before).
 * H.264, HEVC and AAC wait for VideoToolbox's and AudioToolbox's encoders: settings that
 * ask for them can't be applied.
 */
#import "AVFInternal.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#pragma mark - Boxes

@interface AVFBox : NSObject {
@public
    NSMutableData *d;
}
@end
@implementation AVFBox
@end

static void
w8(NSMutableData *d, uint32_t v)
{
    uint8_t b = (uint8_t)v;
    [d appendBytes:&b length:1];
}

static void
w16(NSMutableData *d, uint32_t v)
{
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:2];
}

static void
w32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:4];
}

static void
w64(NSMutableData *d, uint64_t v)
{
    w32(d, (uint32_t)(v >> 32));
    w32(d, (uint32_t)v);
}

static uint16_t
writer_language_code(NSString *language)
{
    if (language.length != 3) return 0x55C4; /* und */
    unichar a = [language characterAtIndex:0], b = [language characterAtIndex:1], c = [language characterAtIndex:2];
    if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
    if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
    if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (a < 'a' || a > 'z' || b < 'a' || b > 'z' || c < 'a' || c > 'z') return 0x55C4;
    return (uint16_t)(((a - 0x60) << 10) | ((b - 0x60) << 5) | (c - 0x60));
}

static NSData *
box(uint32_t type, NSData *body)
{
    NSMutableData *d = [NSMutableData data];
    w32(d, (uint32_t)(8 + body.length));
    w32(d, type);
    [d appendData:body];
    return d;
}

static NSData *
boxes(uint32_t type, NSArray<NSData *> *children)
{
    NSMutableData *body = [NSMutableData data];
    for (NSData *c in children)
        [body appendData:c];
    return box(type, body);
}

static NSData *
full_box(uint32_t type, uint32_t versionFlags, void (^fill)(NSMutableData *))
{
    NSMutableData *d = [NSMutableData data];
    w32(d, versionFlags);
    fill(d);
    return box(type, d);
}

static void
matrix(NSMutableData *d, CGAffineTransform t)
{
    w32(d, (uint32_t)(int32_t)lround(t.a * 65536)), w32(d, (uint32_t)(int32_t)lround(t.b * 65536)), w32(d, 0);
    w32(d, (uint32_t)(int32_t)lround(t.c * 65536)), w32(d, (uint32_t)(int32_t)lround(t.d * 65536)), w32(d, 0);
    w32(d, (uint32_t)(int32_t)lround(t.tx * 65536)), w32(d, (uint32_t)(int32_t)lround(t.ty * 65536)), w32(d, 0x40000000);
}

#pragma mark - Inputs

typedef struct {
    uint64_t offset;
    uint32_t size, count;   /* count > 1: a run of fixed-size samples (PCM) */
    int64_t time;            /* media timescale */
    uint32_t duration;       /* per sample */
    BOOL sync;
} AVFWrittenSample;

@interface AVAssetWriterInput ()
- (void)_finchStartWithWriter:(AVAssetWriter *)writer;
- (void)_finchAttachWriter:(AVAssetWriter *)writer;
- (BOOL)_finchFinished;
- (AVAssetWriter *)_finchWriter;
- (BOOL)_finchHasSamples;
- (NSDictionary<NSString *, NSArray<AVAssetWriterInput *> *> *)_finchTrackAssociations;
- (NSData *)_finchTrackWithID:(uint32_t)trackID alternateGroup:(int16_t)alternateGroup movieTimescale:(uint32_t)movieTimescale sessionStart:(CMTime)start
                    sessionEnd:(CMTime)end quickTime:(BOOL)quickTime trackReferences:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)trackReferences
                     duration:(int64_t *)durationOut;
@end

@interface AVAssetWriter ()
- (BOOL)_finchWriteBytes:(const void *)bytes length:(size_t)length offset:(uint64_t *)offsetOut;
- (void)_finchFailWithError:(NSError *)error;
- (BOOL)_finchQuickTime;
- (int16_t)_finchAlternateGroupForInput:(AVAssetWriterInput *)input;
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)_finchTrackReferencesForInput:(AVAssetWriterInput *)input
                                                                          trackIDs:(NSDictionary<NSValue *, NSNumber *> *)trackIDs;
@end

@implementation AVAssetWriterInput {
    AVMediaType _ftype;
    NSDictionary *_fsettings;
    CMFormatDescriptionRef _hint, _written;
    __weak AVAssetWriter *_fwriter;
    BOOL _ready, _finished, _realTime;
    CMTimeScale _timescale;
    CGAffineTransform _transform;
    float _volume;
    NSString *_language;
    NSString *_fextendedLanguageTag;
    BOOL _fenabled;
    NSMutableData *_samples; /* AVFWrittenSample */
    AudioConverterRef _converter;
    AudioStreamBasicDescription _outFormat, _inFormat;
    NSArray *_metadata;
    NSMutableDictionary<NSString *, NSMutableArray<AVAssetWriterInput *> *> *_fassociations;
}

+ (instancetype)assetWriterInputWithMediaType:(AVMediaType)mediaType outputSettings:(NSDictionary<NSString *, id> *)outputSettings
{
    return [[self alloc] initWithMediaType:mediaType outputSettings:outputSettings sourceFormatHint:NULL];
}

+ (instancetype)assetWriterInputWithMediaType:(AVMediaType)mediaType
                               outputSettings:(NSDictionary<NSString *, id> *)outputSettings
                             sourceFormatHint:(CMFormatDescriptionRef)sourceFormatHint
{
    return [[self alloc] initWithMediaType:mediaType outputSettings:outputSettings sourceFormatHint:sourceFormatHint];
}

- (instancetype)initWithMediaType:(AVMediaType)mediaType outputSettings:(NSDictionary<NSString *, id> *)outputSettings
{
    return [self initWithMediaType:mediaType outputSettings:outputSettings sourceFormatHint:NULL];
}

- (instancetype)initWithMediaType:(AVMediaType)mediaType
                   outputSettings:(NSDictionary<NSString *, id> *)outputSettings
                 sourceFormatHint:(CMFormatDescriptionRef)sourceFormatHint
{
    if ((self = [super init])) {
        _ftype = [mediaType copy];
        _fsettings = [outputSettings copy];
        if (sourceFormatHint)
            _hint = (CMFormatDescriptionRef)CFRetain(sourceFormatHint);
        _transform = CGAffineTransformIdentity;
        _volume = [mediaType isEqualToString:AVMediaTypeAudio] ? 1 : 0;
        _fenabled = YES;
        _samples = [NSMutableData data];
        _fassociations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc
{
    if (_hint)
        CFRelease(_hint);
    if (_written)
        CFRelease(_written);
    if (_converter)
        AudioConverterDispose(_converter);
}

- (AVMediaType)mediaType { return _ftype; }
- (NSDictionary *)outputSettings { return _fsettings; }
- (CMFormatDescriptionRef)sourceFormatHint { return _hint; }
- (BOOL)isReadyForMoreMediaData { return _ready && !_finished; }
- (BOOL)expectsMediaDataInRealTime { return _realTime; }
- (void)setExpectsMediaDataInRealTime:(BOOL)flag { _realTime = flag; }
- (CMTimeScale)mediaTimeScale { return _timescale; }
- (void)setMediaTimeScale:(CMTimeScale)mediaTimeScale { _timescale = mediaTimeScale; }
- (CGAffineTransform)transform { return _transform; }
- (void)setTransform:(CGAffineTransform)transform { _transform = transform; }
- (float)preferredVolume { return _volume; }
- (void)setPreferredVolume:(float)volume { _volume = volume; }
- (NSString *)languageCode { return _language; }
- (void)setLanguageCode:(NSString *)languageCode { _language = [languageCode copy]; }
- (NSArray<AVMetadataItem *> *)metadata { return _metadata ?: @[]; }
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata { _metadata = [metadata copy]; }
- (void)setMarksOutputTrackAsEnabled:(BOOL)enabled { _fenabled = enabled; }
- (BOOL)marksOutputTrackAsEnabled { return _fenabled; }
- (NSString *)extendedLanguageTag { return _fextendedLanguageTag; }
- (void)setExtendedLanguageTag:(NSString *)tag { _fextendedLanguageTag = [tag copy]; }
- (BOOL)performsMultiPassEncodingIfSupported { return NO; }
- (BOOL)canPerformMultiplePasses { return NO; }
- (BOOL)_finchFinished { return _finished; }
- (AVAssetWriter *)_finchWriter { return _fwriter; }
- (void)_finchAttachWriter:(AVAssetWriter *)writer { _fwriter = writer; }
- (BOOL)_finchHasSamples { return _samples.length != 0; }
- (NSDictionary<NSString *,NSArray<AVAssetWriterInput *> *> *)_finchTrackAssociations
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [_fassociations enumerateKeysAndObjectsUsingBlock:^(NSString *type, NSMutableArray *inputs, BOOL *stop) {
        out[type] = [inputs copy];
    }];
    return out;
}

- (void)_finchStartWithWriter:(AVAssetWriter *)writer
{
    _fwriter = writer;
    [self willChangeValueForKey:@"readyForMoreMediaData"];
    _ready = YES;
    [self didChangeValueForKey:@"readyForMoreMediaData"];
}

- (void)markAsFinished
{
    [self willChangeValueForKey:@"readyForMoreMediaData"];
    _finished = YES;
    [self didChangeValueForKey:@"readyForMoreMediaData"];
}

- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    void (^b)(void) = [block copy];
    __weak AVAssetWriterInput *weakSelf = self;
    dispatch_async(queue, ^{
        AVAssetWriterInput *s = weakSelf;
        while (s && s.readyForMoreMediaData) {
            NSUInteger before = s->_samples.length;
            b();
            if (s->_samples.length == before && s.readyForMoreMediaData)
                break;
        }
    });
}

static uint32_t
codec_of(NSDictionary *settings)
{
    NSString *c = settings[AVVideoCodecKey];
    if (!c)
        return 0;
    NSData *d = [c dataUsingEncoding:NSMacOSRomanStringEncoding];
    const uint8_t *b = d.bytes;
    return d.length == 4 ? (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3] : 0;
}

/* Settings Finch can write: JPEG video, linear PCM audio, or none (as given). */
+ (BOOL)_finchCanWriteSettings:(NSDictionary *)settings mediaType:(AVMediaType)mediaType
{
    if (!settings)
        return YES;
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        uint32_t c = codec_of(settings);
        return c == 'jpeg' && [settings[AVVideoWidthKey] integerValue] > 0 && [settings[AVVideoHeightKey] integerValue] > 0;
    }
    if ([mediaType isEqualToString:AVMediaTypeAudio])
        return [settings[AVFormatIDKey] unsignedIntValue] == kAudioFormatLinearPCM;
    return NO;
}

#pragma mark Appending

- (CMTimeScale)_finchTimescale
{
    if (_timescale)
        return _timescale;
    if ([_ftype isEqualToString:AVMediaTypeAudio]) {
        double rate = _fsettings[AVSampleRateKey] ? [_fsettings[AVSampleRateKey] doubleValue] : _inFormat.mSampleRate;
        if (!rate && _hint) {
            const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(_hint);
            rate = a ? a->mSampleRate : 0;
        }
        return rate > 0 ? (CMTimeScale)rate : 44100;
    }
    return 600;
}

- (void)_finchRecord:(AVFWrittenSample)s
{
    [_samples appendBytes:&s length:sizeof s];
}

- (BOOL)_finchWrite:(const void *)bytes length:(size_t)length sample:(AVFWrittenSample)s
{
    AVAssetWriter *w = _fwriter;
    uint64_t at;
    if (!w || ![w _finchWriteBytes:bytes length:length offset:&at])
        return NO;
    s.offset = at;
    [self _finchRecord:s];
    return YES;
}

- (void)_finchSetWritten:(CMFormatDescriptionRef)fd
{
    if (!_written && fd)
        _written = (CMFormatDescriptionRef)CFRetain(fd);
}

- (BOOL)_finchAppendJPEGFromPixelBuffer:(CVPixelBufferRef)pb time:(CMTime)pts
{
    NSInteger width = [_fsettings[AVVideoWidthKey] integerValue], height = [_fsettings[AVVideoHeightKey] integerValue];
    double quality = 0.75;
    NSDictionary *props = _fsettings[AVVideoCompressionPropertiesKey];
    if (props[AVVideoQualityKey])
        quality = [props[AVVideoQualityKey] doubleValue];
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    OSType format = CVPixelBufferGetPixelFormatType(pb);
    uint32_t info = format == kCVPixelFormatType_32ARGB ? (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Big
                    : format == kCVPixelFormatType_32RGBA ? (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big
                                                          : (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Little;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef src = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 8,
                                             CVPixelBufferGetBytesPerRow(pb), cs, info);
    CGImageRef im = src ? CGBitmapContextCreateImage(src) : NULL;
    if (src)
        CGContextRelease(src);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (im && ((NSInteger)CGImageGetWidth(im) != width || (NSInteger)CGImageGetHeight(im) != height)) {
        CGContextRef c = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, 0, cs,
                                               (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big);
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, CGRectMake(0, 0, width, height), im);
        CGImageRelease(im);
        im = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
    }
    CGColorSpaceRelease(cs);
    if (!im)
        return NO;
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(dst, im, (__bridge CFDictionaryRef) @{(id)kCGImageDestinationLossyCompressionQuality : @(quality)});
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(im);
    if (!ok)
        return NO;
    if (!_written) {
        CMVideoFormatDescriptionRef fd = NULL;
        NSDictionary *ext = @{
            (id)kCMFormatDescriptionExtension_FormatName : @"Photo - JPEG",
            (id)kCMFormatDescriptionExtension_Depth : @24,
            (id)kCMFormatDescriptionExtension_TemporalQuality : @512,
            (id)kCMFormatDescriptionExtension_SpatialQuality : @512,
            (id)kCMFormatDescriptionExtension_Vendor : @"appl",
            (id)kCMFormatDescriptionExtension_Version : @0,
            (id)kCMFormatDescriptionExtension_RevisionLevel : @0
        };
        CMVideoFormatDescriptionCreate(NULL, 'jpeg', (int32_t)width, (int32_t)height, (__bridge CFDictionaryRef)ext, &fd);
        [self _finchSetWritten:fd];
        if (fd)
            CFRelease(fd);
    }
    CMTime t = CMTimeConvertScale(pts, [self _finchTimescale], kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    AVFWrittenSample s = {0, (uint32_t)jpeg.length, 1, t.value, 0, YES};
    return [self _finchWrite:jpeg.bytes length:jpeg.length sample:s];
}

- (BOOL)_finchAppendPixelBuffer:(CVPixelBufferRef)pb time:(CMTime)pts
{
    if (!self.readyForMoreMediaData)
        [NSException raise:NSInternalInconsistencyException
                    format:@"*** -[AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer:withPresentationTime:] A pixel buffer cannot be "
                           @"appended when readyForMoreMediaData is NO."];
    if (codec_of(_fsettings) == 'jpeg')
        return [self _finchAppendJPEGFromPixelBuffer:pb time:pts];
    [_fwriter _finchFailWithError:AVFError(AVErrorEncoderNotFound, nil)];
    return NO;
}

/* Audio converted to the settings' linear PCM. */
- (NSData *)_finchConvert:(NSData *)data frames:(UInt32)frames from:(const AudioStreamBasicDescription *)in
{
    if (!_converter) {
        _inFormat = *in;
        AudioStreamBasicDescription out = {0};
        out.mFormatID = kAudioFormatLinearPCM;
        out.mSampleRate = _fsettings[AVSampleRateKey] ? [_fsettings[AVSampleRateKey] doubleValue] : in->mSampleRate;
        out.mChannelsPerFrame = _fsettings[AVNumberOfChannelsKey] ? [_fsettings[AVNumberOfChannelsKey] unsignedIntValue] : in->mChannelsPerFrame;
        BOOL isFloat = [_fsettings[AVLinearPCMIsFloatKey] boolValue];
        out.mBitsPerChannel = _fsettings[AVLinearPCMBitDepthKey] ? [_fsettings[AVLinearPCMBitDepthKey] unsignedIntValue] : 16;
        out.mFormatFlags = kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                           ([_fsettings[AVLinearPCMIsBigEndianKey] boolValue] ? kAudioFormatFlagIsBigEndian : 0);
        out.mBytesPerFrame = out.mBitsPerChannel / 8 * out.mChannelsPerFrame;
        out.mBytesPerPacket = out.mBytesPerFrame;
        out.mFramesPerPacket = 1;
        _outFormat = out;
        if (memcmp(in, &out, sizeof out) && AudioConverterNew(in, &out, &_converter))
            return nil;
    }
    if (!_converter)
        return data;
    NSMutableData *dst = [NSMutableData dataWithLength:(NSUInteger)ceil(frames * _outFormat.mSampleRate / in->mSampleRate + 16) * _outFormat.mBytesPerFrame];
    UInt32 outBytes = (UInt32)dst.length;
    if (AudioConverterConvertBuffer(_converter, (UInt32)data.length, data.bytes, &outBytes, dst.mutableBytes))
        return nil;
    dst.length = outBytes;
    return dst;
}

- (BOOL)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (!self.readyForMoreMediaData)
        [NSException raise:NSInternalInconsistencyException
                    format:@"*** -[AVAssetWriterInput appendSampleBuffer:] A sample buffer cannot be appended when readyForMoreMediaData is NO."];
    AVAssetWriter *w = _fwriter;
    if (!w || w.status != AVAssetWriterStatusWriting)
        return NO;
    CMItemCount n = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!n)
        return YES;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sampleBuffer);
    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (ib)
        return [self _finchAppendPixelBuffer:ib time:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t total = bb ? CMBlockBufferGetDataLength(bb) : 0;
    NSMutableData *data = [NSMutableData dataWithLength:total];
    if (total)
        CMBlockBufferCopyDataBytes(bb, 0, total, data.mutableBytes);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTimeScale ts = [self _finchTimescale];
    if ([_ftype isEqualToString:AVMediaTypeAudio] && fd) {
        const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
        if (a && a->mFormatID == kAudioFormatLinearPCM) {
            NSData *pcm = _fsettings ? [self _finchConvert:data frames:(UInt32)n from:a] : data;
            if (!pcm) {
                [w _finchFailWithError:AVFError(AVErrorUnknown, nil)];
                return NO;
            }
            const AudioStreamBasicDescription *outA = _fsettings ? &_outFormat : a;
            if (!_written) {
                CMAudioFormatDescriptionRef wfd = NULL;
                if (_fsettings)
                    CMAudioFormatDescriptionCreate(NULL, &_outFormat, 0, NULL, 0, NULL, NULL, &wfd);
                [self _finchSetWritten:_fsettings ? wfd : fd];
                if (wfd)
                    CFRelease(wfd);
            }
            uint32_t frames = (uint32_t)(pcm.length / outA->mBytesPerFrame);
            CMTime t = CMTimeConvertScale(pts, ts, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
            AVFWrittenSample s = {0, outA->mBytesPerFrame, frames, t.value, 1, YES};
            return [self _finchWrite:pcm.bytes length:pcm.length sample:s];
        }
    }
    if (_fsettings && ![_ftype isEqualToString:AVMediaTypeAudio]) {
        [w _finchFailWithError:AVFError(AVErrorEncoderNotFound, nil)];
        return NO;
    }
    /* stored samples, as they are */
    [self _finchSetWritten:fd];
    size_t sizes[64];
    CMItemCount sizeCount = 0;
    CMSampleBufferGetSampleSizeArray(sampleBuffer, 64, sizes, &sizeCount);
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    size_t at = 0;
    for (CMItemCount i = 0; i < n; i++) {
        size_t size = sizeCount == 1 ? sizes[0] : (i < sizeCount ? sizes[i] : 0);
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, i, &timing);
        BOOL sync = YES;
        if (atts && i < CFArrayGetCount(atts)) {
            CFBooleanRef notSync = CFDictionaryGetValue(CFArrayGetValueAtIndex(atts, i), kCMSampleAttachmentKey_NotSync);
            sync = !(notSync && CFBooleanGetValue(notSync));
        }
        CMTime t = CMTimeConvertScale(timing.presentationTimeStamp, ts, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
        AVFWrittenSample s = {0, (uint32_t)size, 1, t.value, 0, sync};
        if (size && at + size <= data.length && ![self _finchWrite:(const uint8_t *)data.bytes + at length:size sample:s])
            return NO;
        at += size;
    }
    return YES;
}

#pragma mark The track

- (NSData *)_finchSampleTableQuickTime:(BOOL)quickTime durations:(uint32_t *)durations count:(size_t)count
{
    const AVFWrittenSample *s = _samples.bytes;
    size_t n = _samples.length / sizeof *s;
    BOOL video = ![_ftype isEqualToString:AVMediaTypeAudio];
    /* stsd */
    NSData *desc = nil;
    CMBlockBufferRef bb = NULL;
    if (_written) {
        CMMediaType mt = CMFormatDescriptionGetMediaType(_written);
        if (mt == kCMMediaType_Video)
            CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(NULL, _written, kCFStringEncodingUTF8,
                                                                              quickTime ? NULL : kCMImageDescriptionFlavor_ISOFamily, &bb);
        else if (mt == kCMMediaType_Audio)
            CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(NULL, _written,
                                                                              quickTime ? kCMSoundDescriptionFlavor_QuickTimeMovieV2
                                                                                        : kCMSoundDescriptionFlavor_ISOFamily,
                                                                              &bb);
    }
    if (bb) {
        NSMutableData *d = [NSMutableData dataWithLength:CMBlockBufferGetDataLength(bb)];
        CMBlockBufferCopyDataBytes(bb, 0, d.length, d.mutableBytes);
        /* (the data reference is the first) */
        if (d.length >= 16) {
            uint8_t *p = d.mutableBytes;
            p[14] = 0, p[15] = 1;
        }
        desc = d;
        CFRelease(bb);
    }
    NSData *stsd = full_box('stsd', 0, ^(NSMutableData *d) {
        w32(d, desc ? 1 : 0);
        if (desc)
            [d appendData:desc];
    });
    /* stts: per sample (PCM runs count frames) */
    NSMutableArray *stts = [NSMutableArray array];
    uint32_t runCount = 0, runDelta = 0;
    NSMutableData *sttsBody = [NSMutableData data];
    uint32_t entries = 0;
    void (^flush)(void) = ^{
    };
    (void)flush;
    (void)stts;
    for (size_t i = 0; i < count; i++) {
        uint32_t frames = video ? 1 : s[i].count;
        uint32_t delta = video ? durations[i] : 1;
        if (runCount && delta == runDelta) {
            runCount += frames;
        } else {
            if (runCount) {
                w32(sttsBody, runCount), w32(sttsBody, runDelta);
                entries++;
            }
            runCount = frames, runDelta = delta;
        }
    }
    if (runCount) {
        w32(sttsBody, runCount), w32(sttsBody, runDelta);
        entries++;
    }
    NSData *sttsBox = full_box('stts', 0, ^(NSMutableData *d) {
        w32(d, entries);
        [d appendData:sttsBody];
    });
    /* stss for video when some samples aren't sync */
    BOOL allSync = YES;
    for (size_t i = 0; i < n; i++)
        allSync &= s[i].sync;
    NSData *stss = nil;
    if (video && !allSync)
        stss = full_box('stss', 0, ^(NSMutableData *d) {
            uint32_t k = 0;
            for (size_t i = 0; i < n; i++)
                k += s[i].sync;
            w32(d, k);
            for (size_t i = 0; i < n; i++)
                if (s[i].sync)
                    w32(d, (uint32_t)i + 1);
        });
    /* chunks: a run of contiguous samples each */
    NSMutableData *chunkOffsets = [NSMutableData data];
    NSMutableData *stscBody = [NSMutableData data];
    uint32_t chunks = 0, stscEntries = 0, lastPer = 0;
    BOOL wide = NO;
    for (size_t i = 0; i < n;) {
        size_t j = i;
        uint64_t end = s[i].offset + (uint64_t)s[i].size * s[i].count;
        uint32_t per = s[i].count;
        while (j + 1 < n && s[j + 1].offset == end) {
            j++;
            end += (uint64_t)s[j].size * s[j].count;
            per += s[j].count;
        }
        chunks++;
        uint64_t off = s[i].offset;
        [chunkOffsets appendBytes:&off length:8];
        wide |= off > UINT32_MAX;
        if (per != lastPer) {
            w32(stscBody, chunks), w32(stscBody, per), w32(stscBody, 1);
            stscEntries++;
            lastPer = per;
        }
        i = j + 1;
    }
    NSData *stsc = full_box('stsc', 0, ^(NSMutableData *d) {
        w32(d, stscEntries);
        [d appendData:stscBody];
    });
    NSData *stsz = full_box('stsz', 0, ^(NSMutableData *d) {
        if (!video && n) {
            w32(d, s[0].size);
            uint32_t frames = 0;
            for (size_t i = 0; i < n; i++)
                frames += s[i].count;
            w32(d, frames);
        } else {
            w32(d, 0), w32(d, (uint32_t)n);
            for (size_t i = 0; i < n; i++)
                w32(d, s[i].size);
        }
    });
    const uint64_t *offs = chunkOffsets.bytes;
    NSData *stco = full_box(wide ? 'co64' : 'stco', 0, ^(NSMutableData *d) {
        w32(d, chunks);
        for (uint32_t i = 0; i < chunks; i++) {
            if (wide)
                w64(d, offs[i]);
            else
                w32(d, (uint32_t)offs[i]);
        }
    });
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:stsd, sttsBox, nil];
    if (stss)
        [parts addObject:stss];
    [parts addObjectsFromArray:@[ stsc, stsz, stco ]];
    return boxes('stbl', parts);
}

static NSData *
hdlr_box(BOOL quickTime, uint32_t component, uint32_t subtype, NSString *name)
{
    return full_box('hdlr', 0, ^(NSMutableData *d) {
        w32(d, quickTime ? component : 0);
        w32(d, subtype);
        w32(d, quickTime && component == 'mhlr' ? 'appl' : 0), w32(d, 0), w32(d, 0);
        NSData *n = [name dataUsingEncoding:NSUTF8StringEncoding];
        if (quickTime)
            w8(d, (uint32_t)n.length);
        [d appendData:n];
        if (!quickTime)
            w8(d, 0);
    });
}

- (NSData *)_finchTrackWithID:(uint32_t)trackID alternateGroup:(int16_t)alternateGroup movieTimescale:(uint32_t)movieTimescale sessionStart:(CMTime)start
                    sessionEnd:(CMTime)end quickTime:(BOOL)quickTime trackReferences:(NSDictionary<NSString *,NSArray<NSNumber *> *> *)trackReferences
                     duration:(int64_t *)durationOut
{
    const AVFWrittenSample *s = _samples.bytes;
    size_t n = _samples.length / sizeof *s;
    if (!n)
        return nil;
    BOOL video = ![_ftype isEqualToString:AVMediaTypeAudio];
    CMTimeScale ts = [self _finchTimescale];
    int64_t startValue = CMTIME_IS_VALID(start) ? CMTimeConvertScale(start, ts, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : 0;
    /* durations: until the next sample; the last until the session's end */
    uint32_t *durations = calloc(n, sizeof(uint32_t));
    uint64_t mediaDuration = 0;
    for (size_t i = 0; i < n; i++) {
        if (!video) {
            durations[i] = 1;
            mediaDuration += s[i].count;
            continue;
        }
        int64_t next;
        if (i + 1 < n)
            next = s[i + 1].time;
        else if (CMTIME_IS_VALID(end))
            next = CMTimeConvertScale(end, ts, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        else
            next = s[i].time + (i ? (int64_t)durations[i - 1] : ts / 30);
        durations[i] = next > s[i].time ? (uint32_t)(next - s[i].time) : 1;
        mediaDuration += durations[i];
    }
    int64_t trackDuration = (int64_t)llround((double)mediaDuration * movieTimescale / ts);
    *durationOut = trackDuration;
    int64_t firstTime = video ? s[0].time : s[0].time;
    NSData *stbl = [self _finchSampleTableQuickTime:quickTime durations:durations count:n];
    free(durations);
    NSData *tkhd = full_box('tkhd', 0xF, ^(NSMutableData *d) {
        uint32_t now = (uint32_t)([[NSDate date] timeIntervalSince1970] + 2082844800.0);
        w32(d, now), w32(d, now);
        w32(d, trackID), w32(d, 0);
        w32(d, (uint32_t)trackDuration);
        w32(d, 0), w32(d, 0);
        w16(d, 0), w16(d, (uint16_t)alternateGroup);
        w16(d, (uint32_t)lround(self->_volume * 256)), w16(d, 0);
        matrix(d, self->_transform);
        if (video && self->_written) {
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(self->_written);
            w32(d, (uint32_t)dim.width << 16), w32(d, (uint32_t)dim.height << 16);
        } else {
            w32(d, 0), w32(d, 0);
        }
    });
    NSData *elst = full_box('elst', 0, ^(NSMutableData *d) {
        w32(d, 1);
        w32(d, (uint32_t)trackDuration);
        w32(d, (uint32_t)(firstTime - startValue > 0 ? firstTime - startValue : 0));
        w32(d, 0x10000);
    });
    NSData *mdhd = full_box('mdhd', 0, ^(NSMutableData *d) {
        uint32_t now = (uint32_t)([[NSDate date] timeIntervalSince1970] + 2082844800.0);
        w32(d, now), w32(d, now);
        w32(d, (uint32_t)ts), w32(d, (uint32_t)mediaDuration);
        w16(d, writer_language_code(self->_language)), w16(d, 0);
    });
    NSData *mediaHeader = video ? full_box('vmhd', 1, ^(NSMutableData *d) {
        w16(d, 0x40), w16(d, 0x8000), w16(d, 0x8000), w16(d, 0x8000);
    })
                                : full_box('smhd', 0, ^(NSMutableData *d) {
                                      w32(d, 0);
                                  });
    NSData *dinf = boxes('dinf', @[ full_box('dref', 0, ^(NSMutableData *d) {
                             w32(d, 1);
                             [d appendData:full_box(quickTime ? 'alis' : 'url ', 1, ^(NSMutableData *x) {
                                })];
                         }) ]);
    NSMutableArray *minf = [NSMutableArray arrayWithObject:mediaHeader];
    if (quickTime)
        [minf addObject:hdlr_box(YES, 'dhlr', 'alis', @"Core Media Data Handler")];
    [minf addObjectsFromArray:@[ dinf, stbl ]];
    NSData *mdia = boxes('mdia', @[
        mdhd, hdlr_box(quickTime, 'mhlr', video ? 'vide' : 'soun', video ? @"Core Media Video" : @"Core Media Audio"),
        boxes('minf', minf)
    ]);
    NSMutableArray *trak = [NSMutableArray arrayWithObjects:tkhd, boxes('edts', @[ elst ]), mdia, nil];
    NSMutableArray *references = [NSMutableArray array];
    [trackReferences enumerateKeysAndObjectsUsingBlock:^(NSString *type, NSArray<NSNumber *> *ids, BOOL *stop) {
        if (type.length != 4 || !ids.count)
            return;
        uint32_t code = (uint32_t)[type characterAtIndex:0] << 24 | (uint32_t)[type characterAtIndex:1] << 16 |
                        (uint32_t)[type characterAtIndex:2] << 8 | (uint32_t)[type characterAtIndex:3];
        NSMutableData *body = [NSMutableData data];
        for (NSNumber *referenceID in ids)
            w32(body, referenceID.unsignedIntValue);
        [references addObject:box(code, body)];
    }];
    if (references.count)
        [trak addObject:boxes('tref', references)];
    return boxes('trak', trak);
}

- (BOOL)canAddTrackAssociationWithTrackOfInput:(AVAssetWriterInput *)input type:(NSString *)type
{
    AVAssetWriter *writer = _fwriter;
    if (!input || input == self || !type.length || !writer || writer != input._finchWriter ||
        writer.status != AVAssetWriterStatusUnknown || ![writer _finchQuickTime])
        return NO;
    static NSSet<NSString *> *supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = [NSSet setWithArray:@[ AVTrackAssociationTypeAudioFallback, AVTrackAssociationTypeChapterList,
            AVTrackAssociationTypeForcedSubtitlesOnly, AVTrackAssociationTypeMetadataReferent,
            AVTrackAssociationTypeRenderMetadataSource, AVTrackAssociationTypeSelectionFollower,
            AVTrackAssociationTypeTimecode ]];
    });
    if (![supported containsObject:type])
        return NO;
    if ([type isEqualToString:AVTrackAssociationTypeAudioFallback])
        return [self.mediaType isEqualToString:AVMediaTypeAudio] && [input.mediaType isEqualToString:AVMediaTypeAudio];
    if ([type isEqualToString:AVTrackAssociationTypeForcedSubtitlesOnly])
        return [self.mediaType isEqualToString:AVMediaTypeSubtitle] && [input.mediaType isEqualToString:AVMediaTypeSubtitle];
    if ([type isEqualToString:AVTrackAssociationTypeChapterList])
        return ![self.mediaType isEqualToString:AVMediaTypeMetadata] &&
               ([input.mediaType isEqualToString:AVMediaTypeText] || [input.mediaType isEqualToString:AVMediaTypeSubtitle] ||
                [input.mediaType isEqualToString:AVMediaTypeClosedCaption] || [input.mediaType isEqualToString:AVMediaTypeMetadata]);
    if ([type isEqualToString:AVTrackAssociationTypeMetadataReferent])
        return [self.mediaType isEqualToString:AVMediaTypeMetadata];
    if ([type isEqualToString:AVTrackAssociationTypeRenderMetadataSource])
        return [self.mediaType isEqualToString:AVMediaTypeMetadata] && [input.mediaType isEqualToString:AVMediaTypeVideo];
    if ([type isEqualToString:AVTrackAssociationTypeTimecode])
        return [input.mediaType isEqualToString:AVMediaTypeTimecode];
    return YES;
}

- (void)addTrackAssociationWithTrackOfInput:(AVAssetWriterInput *)input type:(NSString *)type
{
    if (![self canAddTrackAssociationWithTrackOfInput:input type:type])
        [NSException raise:NSInvalidArgumentException format:@"The track association cannot be added to this writer"];
    NSMutableArray *inputs = _fassociations[type];
    if (!inputs) {
        inputs = [NSMutableArray array];
        _fassociations[type] = inputs;
    }
    if (![inputs containsObject:input])
        [inputs addObject:input];
}

@end

#pragma mark - The adaptor

@implementation AVAssetWriterInputPixelBufferAdaptor {
    AVAssetWriterInput *_finput;
    NSDictionary *_fattributes;
    CVPixelBufferPoolRef _fpool;
}

+ (instancetype)assetWriterInputPixelBufferAdaptorWithAssetWriterInput:(AVAssetWriterInput *)input
                                           sourcePixelBufferAttributes:(NSDictionary<NSString *, id> *)sourcePixelBufferAttributes
{
    return [[self alloc] initWithAssetWriterInput:input sourcePixelBufferAttributes:sourcePixelBufferAttributes];
}

- (instancetype)initWithAssetWriterInput:(AVAssetWriterInput *)input
             sourcePixelBufferAttributes:(NSDictionary<NSString *, id> *)sourcePixelBufferAttributes
{
    if ((self = [super init])) {
        _finput = input;
        _fattributes = [sourcePixelBufferAttributes copy];
        [input addObserver:self forKeyPath:@"readyForMoreMediaData" options:0 context:NULL];
    }
    return self;
}

- (void)dealloc
{
    [_finput removeObserver:self forKeyPath:@"readyForMoreMediaData"];
    if (_fpool)
        CVPixelBufferPoolRelease(_fpool);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (!_fpool && _finput.readyForMoreMediaData) {
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:_fattributes ?: @{}];
        if (!a[(id)kCVPixelBufferPixelFormatTypeKey])
            a[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_32BGRA);
        if (!a[(id)kCVPixelBufferWidthKey] && _finput.outputSettings[AVVideoWidthKey])
            a[(id)kCVPixelBufferWidthKey] = _finput.outputSettings[AVVideoWidthKey];
        if (!a[(id)kCVPixelBufferHeightKey] && _finput.outputSettings[AVVideoHeightKey])
            a[(id)kCVPixelBufferHeightKey] = _finput.outputSettings[AVVideoHeightKey];
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &_fpool);
    }
}

- (AVAssetWriterInput *)assetWriterInput { return _finput; }
- (NSDictionary *)sourcePixelBufferAttributes { return _fattributes; }

- (CVPixelBufferPoolRef)pixelBufferPool
{
    if (!_fpool && _finput.readyForMoreMediaData)
        [self observeValueForKeyPath:nil ofObject:nil change:nil context:NULL];
    return _fpool;
}

- (BOOL)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime
{
    return [_finput _finchAppendPixelBuffer:pixelBuffer time:presentationTime];
}

@end

#pragma mark - The writer

@implementation AVAssetWriter {
    NSURL *_furl;
    AVFileType _ffileType;
    NSMutableArray *_finputs;
    NSMutableArray<AVAssetWriterInputGroup *> *_finputGroups;
    AVAssetWriterStatus _fstatus;
    NSError *_ferror;
    NSArray *_fmetadata;
    CMTime _fstart, _fend, _fmovieFragmentInterval, _foverallDurationHint;
    CMTimeScale _fmovieTimeScale;
    BOOL _foptimize;
    FILE *_ffile;
    uint64_t _fmdatStart, _fat;
    NSURL *_fdirectory;
}

+ (instancetype)assetWriterWithURL:(NSURL *)outputURL fileType:(AVFileType)outputFileType error:(NSError **)outError
{
    return [[self alloc] initWithURL:outputURL fileType:outputFileType error:outError];
}

- (instancetype)initWithURL:(NSURL *)outputURL fileType:(AVFileType)outputFileType error:(NSError **)outError
{
    if ((self = [super init])) {
        _furl = [outputURL copy];
        _ffileType = [outputFileType copy];
        _finputs = [NSMutableArray array];
        _finputGroups = [NSMutableArray array];
        _fstart = kCMTimeInvalid;
        _fend = kCMTimeInvalid;
        _fmovieFragmentInterval = kCMTimeInvalid;
        _foverallDurationHint = kCMTimeInvalid;
    }
    return self;
}

- (instancetype)initWithContentType:(UTType *)outputContentType
{
    if ((self = [super init])) {
        _ffileType = [outputContentType.identifier copy];
        _finputs = [NSMutableArray array];
        _finputGroups = [NSMutableArray array];
        _fstart = kCMTimeInvalid;
        _fend = kCMTimeInvalid;
        _fmovieFragmentInterval = kCMTimeInvalid;
        _foverallDurationHint = kCMTimeInvalid;
    }
    return self;
}

- (void)dealloc
{
    if (_ffile)
        fclose(_ffile);
}

- (NSURL *)outputURL { return _furl; }
- (AVFileType)outputFileType { return _ffileType; }
- (AVAssetWriterStatus)status { return _fstatus; }
- (NSError *)error { return _ferror; }
- (NSArray<AVAssetWriterInput *> *)inputs { return [_finputs copy]; }
- (NSArray<AVMetadataItem *> *)metadata { return _fmetadata ?: @[]; }
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata { _fmetadata = [metadata copy]; }
- (BOOL)shouldOptimizeForNetworkUse { return _foptimize; }
- (void)setShouldOptimizeForNetworkUse:(BOOL)flag { _foptimize = flag; }
- (CMTimeScale)movieTimeScale { return _fmovieTimeScale; }
- (void)setMovieTimeScale:(CMTimeScale)movieTimeScale { _fmovieTimeScale = movieTimeScale; }
- (CMTime)movieFragmentInterval { return _fmovieFragmentInterval; }
- (void)setMovieFragmentInterval:(CMTime)interval { _fmovieFragmentInterval = interval; }
- (CMTime)overallDurationHint { return _foverallDurationHint; }
- (void)setOverallDurationHint:(CMTime)hint { _foverallDurationHint = hint; }
- (NSURL *)directoryForTemporaryFiles { return _fdirectory; }
- (void)setDirectoryForTemporaryFiles:(NSURL *)directory { _fdirectory = [directory copy]; }

- (NSArray<AVMediaType> *)availableMediaTypes
{
    return @[
        AVMediaTypeSubtitle, AVMediaTypeHaptic, AVMediaTypeMetadata, AVMediaTypeText, AVMediaTypeAudio, AVMediaTypeAuxiliaryPicture,
        AVMediaTypeClosedCaption, AVMediaTypeTimecode, @"scen", AVMediaTypeVideo
    ];
}

- (BOOL)canApplyOutputSettings:(NSDictionary<NSString *, id> *)outputSettings forMediaType:(AVMediaType)mediaType
{
    return [AVAssetWriterInput _finchCanWriteSettings:outputSettings mediaType:mediaType];
}

- (BOOL)canAddInput:(AVAssetWriterInput *)input
{
    return _fstatus == AVAssetWriterStatusUnknown && input && ![_finputs containsObject:input] &&
           [AVAssetWriterInput _finchCanWriteSettings:input.outputSettings mediaType:input.mediaType];
}

- (void)addInput:(AVAssetWriterInput *)input
{
    if (_fstatus != AVAssetWriterStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"*** -[AVAssetWriter addInput:] Cannot call method when status is %ld", (long)_fstatus];
    if (input && ![_finputs containsObject:input]) {
        [_finputs addObject:input];
        [input _finchAttachWriter:self];
    }
}

- (BOOL)canAddInputGroup:(AVAssetWriterInputGroup *)inputGroup
{
    if (_fstatus != AVAssetWriterStatusUnknown || ![self _finchQuickTime] ||
        ![inputGroup isKindOfClass:AVAssetWriterInputGroup.class] || inputGroup.inputs.count < 2)
        return NO;
    AVMediaType type = inputGroup.inputs.firstObject.mediaType;
    for (AVAssetWriterInput *input in inputGroup.inputs) {
        if (![_finputs containsObject:input] || ![input.mediaType isEqualToString:type]) return NO;
        for (AVAssetWriterInputGroup *existing in _finputGroups)
            if ([existing.inputs containsObject:input]) return NO;
    }
    return YES;
}
- (void)addInputGroup:(AVAssetWriterInputGroup *)inputGroup
{
    if (_fstatus != AVAssetWriterStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"Cannot add an input group after writing starts"];
    if (![self canAddInputGroup:inputGroup])
        [NSException raise:NSInvalidArgumentException format:@"The input group cannot be added to this writer"];
    [_finputGroups addObject:inputGroup];
    for (AVAssetWriterInput *input in inputGroup.inputs)
        input.marksOutputTrackAsEnabled = input == inputGroup.defaultInput;
}
- (NSArray<AVAssetWriterInputGroup *> *)inputGroups { return [_finputGroups copy]; }
- (int16_t)_finchAlternateGroupForInput:(AVAssetWriterInput *)input
{
    for (NSUInteger index = 0; index < _finputGroups.count; index++)
        if ([_finputGroups[index].inputs containsObject:input])
            return (int16_t)MIN(index + 1, INT16_MAX);
    return 0;
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)_finchTrackReferencesForInput:(AVAssetWriterInput *)input
                                                                          trackIDs:(NSDictionary<NSValue *, NSNumber *> *)trackIDs
{
    NSMutableDictionary *references = [NSMutableDictionary dictionary];
    [[input _finchTrackAssociations] enumerateKeysAndObjectsUsingBlock:^(NSString *type, NSArray<AVAssetWriterInput *> *inputs, BOOL *stop) {
        NSMutableArray *ids = [NSMutableArray array];
        for (AVAssetWriterInput *other in inputs) {
            NSNumber *trackID = trackIDs[[NSValue valueWithNonretainedObject:other]];
            if (trackID)
                [ids addObject:trackID];
        }
        if (ids.count)
            references[type] = [ids copy];
    }];
    return references;
}

- (BOOL)_finchQuickTime { return ![_ffileType isEqualToString:AVFileTypeMPEG4] && ![_ffileType isEqualToString:AVFileTypeAppleM4V] && ![_ffileType isEqualToString:AVFileTypeAppleM4A]; }

- (void)_finchFailWithError:(NSError *)error
{
    if (_fstatus == AVAssetWriterStatusFailed)
        return;
    [self willChangeValueForKey:@"status"];
    _ferror = error;
    _fstatus = AVAssetWriterStatusFailed;
    [self didChangeValueForKey:@"status"];
}

- (BOOL)startWriting
{
    if (_fstatus != AVAssetWriterStatusUnknown)
        [NSException raise:NSInternalInconsistencyException format:@"*** -[AVAssetWriter startWriting] Cannot call method when status is %ld", (long)_fstatus];
    if ([[NSFileManager defaultManager] fileExistsAtPath:_furl.path]) {
        [self _finchFailWithError:AVFError(AVErrorFileAlreadyExists, nil)];
        return NO;
    }
    _ffile = fopen(_furl.fileSystemRepresentation, "w+b");
    if (!_ffile) {
        [self _finchFailWithError:AVFError(AVErrorUnknown, [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil])];
        return NO;
    }
    NSMutableData *head = [NSMutableData data];
    BOOL qt = [self _finchQuickTime];
    NSMutableData *ftyp = [NSMutableData data];
    if (qt) {
        w32(ftyp, 'qt  '), w32(ftyp, 0), w32(ftyp, 'qt  ');
    } else {
        w32(ftyp, 'mp42'), w32(ftyp, 1), w32(ftyp, 'mp41'), w32(ftyp, 'mp42'), w32(ftyp, 'isom');
    }
    [head appendData:box('ftyp', ftyp)];
    w32(head, 8), w32(head, 'wide');
    _fmdatStart = head.length;
    w32(head, 8), w32(head, 'mdat');
    fwrite(head.bytes, 1, head.length, _ffile);
    _fat = head.length;
    [self willChangeValueForKey:@"status"];
    _fstatus = AVAssetWriterStatusWriting;
    [self didChangeValueForKey:@"status"];
    for (AVAssetWriterInput *i in _finputs)
        [i _finchStartWithWriter:self];
    return YES;
}

- (BOOL)_finchWriteBytes:(const void *)bytes length:(size_t)length offset:(uint64_t *)offsetOut
{
    if (_fstatus != AVAssetWriterStatusWriting || !_ffile)
        return NO;
    if (fwrite(bytes, 1, length, _ffile) != length) {
        [self _finchFailWithError:AVFError(AVErrorDiskFull, nil)];
        return NO;
    }
    *offsetOut = _fat;
    _fat += length;
    return YES;
}

- (void)startSessionAtSourceTime:(CMTime)startTime { _fstart = startTime; }
- (void)endSessionAtSourceTime:(CMTime)endTime { _fend = endTime; }

/* 'meta' for the QuickTime metadata keys; 'udta' text for user data. */
- (NSArray<NSData *> *)_finchMetadataBoxes
{
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *mdta = [NSMutableArray array], *udta = [NSMutableArray array];
    for (AVMetadataItem *m in [self metadata]) {
        if ([m.keySpace isEqualToString:AVMetadataKeySpaceQuickTimeMetadata] && [m.key isKindOfClass:[NSString class]])
            [mdta addObject:m];
        else if ([m.keySpace isEqualToString:AVMetadataKeySpaceQuickTimeUserData])
            [udta addObject:m];
    }
    if (mdta.count) {
        NSData *hdlr = full_box('hdlr', 0, ^(NSMutableData *d) {
            w32(d, 0), w32(d, 'mdta'), w32(d, 0), w32(d, 0), w32(d, 0), w8(d, 0);
        });
        NSData *keys = full_box('keys', 0, ^(NSMutableData *d) {
            w32(d, (uint32_t)mdta.count);
            for (AVMetadataItem *m in mdta) {
                NSData *k = [(NSString *)m.key dataUsingEncoding:NSUTF8StringEncoding];
                w32(d, (uint32_t)(8 + k.length)), w32(d, 'mdta');
                [d appendData:k];
            }
        });
        NSMutableArray *items = [NSMutableArray array];
        [mdta enumerateObjectsUsingBlock:^(AVMetadataItem *m, NSUInteger i, BOOL *stop) {
            NSMutableData *data = [NSMutableData data];
            id v = m.value;
            if ([v isKindOfClass:[NSString class]]) {
                w32(data, 1), w32(data, 0);
                [data appendData:[v dataUsingEncoding:NSUTF8StringEncoding]];
            } else if ([v isKindOfClass:[NSData class]]) {
                w32(data, 0), w32(data, 0);
                [data appendData:v];
            } else if ([v isKindOfClass:[NSNumber class]]) {
                w32(data, 21), w32(data, 0), w32(data, (uint32_t)[v intValue]);
            } else if ([v isKindOfClass:[NSDate class]]) {
                w32(data, 1), w32(data, 0);
                [data appendData:[[[[NSISO8601DateFormatter alloc] init] stringFromDate:v] dataUsingEncoding:NSUTF8StringEncoding]];
            } else {
                return;
            }
            [items addObject:boxes((uint32_t)i + 1, @[ box('data', data) ])];
        }];
        [out addObject:boxes('meta', @[ hdlr, keys, boxes('ilst', items) ])];
    }
    if (udta.count) {
        NSMutableArray *items = [NSMutableArray array];
        for (AVMetadataItem *m in udta) {
            uint32_t code = [m.key isKindOfClass:[NSNumber class]] ? [(NSNumber *)m.key unsignedIntValue] : 0;
            NSString *text = m.stringValue;
            if (!code || !text)
                continue;
            NSData *t = [text dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *d = [NSMutableData data];
            w16(d, (uint32_t)t.length), w16(d, 0);
            [d appendData:t];
            [items addObject:box(code, d)];
        }
        if (items.count)
            [out addObject:boxes('udta', items)];
    }
    return out;
}

- (void)_finchFinish
{
    BOOL qt = [self _finchQuickTime];
    uint32_t movieTimescale = _fmovieTimeScale ? (uint32_t)_fmovieTimeScale : 600;
    NSMutableArray *traks = [NSMutableArray array];
    int64_t movieDuration = 0;
    NSMutableDictionary<NSValue *, NSNumber *> *trackIDs = [NSMutableDictionary dictionary];
    uint32_t nextTrackID = 1;
    for (AVAssetWriterInput *input in _finputs)
        if ([input _finchHasSamples])
            trackIDs[[NSValue valueWithNonretainedObject:input]] = @(nextTrackID++);
    for (AVAssetWriterInput *i in _finputs) {
        NSNumber *number = trackIDs[[NSValue valueWithNonretainedObject:i]];
        if (!number)
            continue;
        int64_t d = 0;
        NSDictionary *references = [self _finchTrackReferencesForInput:i trackIDs:trackIDs];
        NSData *t = [i _finchTrackWithID:number.unsignedIntValue alternateGroup:[self _finchAlternateGroupForInput:i]
            movieTimescale:movieTimescale sessionStart:_fstart sessionEnd:_fend quickTime:qt
            trackReferences:references duration:&d];
        if (t) {
            [traks addObject:t];
            movieDuration = MAX(movieDuration, d);
        }
    }
    uint32_t trackID = nextTrackID;
    NSData *mvhd = full_box('mvhd', 0, ^(NSMutableData *d) {
        uint32_t now = (uint32_t)([[NSDate date] timeIntervalSince1970] + 2082844800.0);
        w32(d, now), w32(d, now);
        w32(d, movieTimescale), w32(d, (uint32_t)movieDuration);
        w32(d, 0x10000), w16(d, 0x100);
        w16(d, 0), w32(d, 0), w32(d, 0);
        matrix(d, CGAffineTransformIdentity);
        for (int k = 0; k < 6; k++)
            w32(d, 0);
        w32(d, trackID);
    });
    NSMutableArray *moovParts = [NSMutableArray arrayWithObject:mvhd];
    [moovParts addObjectsFromArray:traks];
    [moovParts addObjectsFromArray:[self _finchMetadataBoxes]];
    NSData *moov = boxes('moov', moovParts);
    uint64_t mdatSize = _fat - _fmdatStart;
    fwrite(moov.bytes, 1, moov.length, _ffile);
    if (mdatSize > UINT32_MAX) {
        /* (the 'wide' before 'mdat' becomes its 64-bit size) */
        fseeko(_ffile, (off_t)_fmdatStart - 8, SEEK_SET);
        NSMutableData *h = [NSMutableData data];
        w32(h, 1), w32(h, 'mdat'), w64(h, mdatSize + 8);
        fwrite(h.bytes, 1, h.length, _ffile);
    } else {
        fseeko(_ffile, (off_t)_fmdatStart, SEEK_SET);
        NSMutableData *h = [NSMutableData data];
        w32(h, (uint32_t)mdatSize);
        fwrite(h.bytes, 1, h.length, _ffile);
    }
    fclose(_ffile);
    _ffile = NULL;
    [self willChangeValueForKey:@"status"];
    _fstatus = AVAssetWriterStatusCompleted;
    [self didChangeValueForKey:@"status"];
}

- (void)finishWritingWithCompletionHandler:(void (^)(void))handler
{
    void (^done)(void) = [handler copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (self->_fstatus == AVAssetWriterStatusWriting)
            [self _finchFinish];
        if (done)
            done();
    });
}

- (BOOL)finishWriting
{
    if (_fstatus == AVAssetWriterStatusWriting)
        [self _finchFinish];
    return _fstatus == AVAssetWriterStatusCompleted;
}

- (void)cancelWriting
{
    if (_ffile) {
        fclose(_ffile);
        _ffile = NULL;
        [[NSFileManager defaultManager] removeItemAtURL:_furl error:NULL];
    }
    [self willChangeValueForKey:@"status"];
    _fstatus = AVAssetWriterStatusCancelled;
    [self didChangeValueForKey:@"status"];
}

- (void)flushSegment {}

@end

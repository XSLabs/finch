/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Compositions keep a real timeline of source and empty ranges. The source movie stays
 * on disk; each segment records its URL, track, source range, and place in the new track.
 */
#import "AVFInternal.h"
#import <AVFoundation/AVComposition.h>
#import <AVFoundation/AVCompositionTrack.h>
#import <AVFoundation/AVCompositionTrackSegment.h>
#import <AVFoundation/AVError.h>
#import <math.h>

#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@interface AVAssetTrack (FinchCompositionInit)
- (instancetype)_finchInit;
@end

@interface AVAssetTrackSegment (FinchCompositionInit)
- (instancetype)_finchInit;
@end

@interface AVCompositionTrack (FinchComposition)
- (instancetype)initWithFinchComposition:(AVComposition *)composition mediaType:(AVMediaType)mediaType trackID:(CMPersistentTrackID)trackID;
- (void)_finchInsertDuration:(CMTime)duration atTime:(CMTime)time;
- (void)_finchInsertEmptyRange:(CMTimeRange)range;
- (void)_finchRemoveRange:(CMTimeRange)range;
- (void)_finchScaleRange:(CMTimeRange)range toDuration:(CMTime)duration;
- (BOOL)_finchInsertTrack:(AVAssetTrack *)track timeRange:(CMTimeRange)timeRange atTime:(CMTime)time error:(NSError **)error;
- (void)_finchInsertSegment:(AVCompositionTrackSegment *)segment sourceTrack:(nullable AVAssetTrack *)sourceTrack;
- (void)_finchAssociateTrack:(AVCompositionTrack *)track withType:(AVTrackAssociationType)type;
@end

@interface AVMutableCompositionTrack (FinchComposition)
- (BOOL)insertTimeRange:(CMTimeRange)timeRange ofTrack:(AVAssetTrack *)track atTime:(CMTime)startTime error:(NSError **)error;
- (BOOL)insertTimeRanges:(NSArray<NSValue *> *)timeRanges ofTracks:(NSArray<AVAssetTrack *> *)tracks atTime:(CMTime)startTime error:(NSError **)error;
- (void)insertEmptyTimeRange:(CMTimeRange)timeRange;
- (void)removeTimeRange:(CMTimeRange)timeRange;
- (void)scaleTimeRange:(CMTimeRange)timeRange toDuration:(CMTime)duration;
- (BOOL)validateTrackSegments:(NSArray<AVCompositionTrackSegment *> *)trackSegments error:(NSError **)outError;
- (void)addTrackAssociationToTrack:(AVCompositionTrack *)compositionTrack type:(AVTrackAssociationType)trackAssociationType;
- (void)removeTrackAssociationToTrack:(AVCompositionTrack *)compositionTrack type:(AVTrackAssociationType)trackAssociationType;
- (void)replaceFormatDescription:(CMFormatDescriptionRef)originalFormatDescription withFormatDescription:(nullable CMFormatDescriptionRef)replacementFormatDescription;
- (void)setNaturalTimeScale:(CMTimeScale)value;
- (void)setLanguageCode:(nullable NSString *)value;
- (void)setExtendedLanguageTag:(nullable NSString *)value;
- (void)setPreferredTransform:(CGAffineTransform)value;
- (void)setPreferredVolume:(float)value;
- (void)setSegments:(NSArray<AVCompositionTrackSegment *> *)segments;
@end

@interface AVComposition (FinchComposition)
- (instancetype)initWithFinchOptions:(nullable NSDictionary *)options;
- (AVMutableCompositionTrack *)_finchAddTrack:(AVMediaType)mediaType trackID:(CMPersistentTrackID)trackID;
- (void)_finchRemoveTrack:(AVCompositionTrack *)track;
@end

@interface AVMutableComposition (FinchComposition)
- (void)setNaturalSize:(CGSize)size;
@end

static CMTime
map_time(CMTime time, CMTimeRange from, CMTimeRange to)
{
    if (!CMTIME_IS_VALID(time) || !CMTIME_IS_VALID(from.duration) || !CMTIME_IS_VALID(to.duration) ||
        CMTimeCompare(from.duration, kCMTimeZero) <= 0)
        return kCMTimeInvalid;
    double scale = CMTimeGetSeconds(to.duration) / CMTimeGetSeconds(from.duration);
    if (!isfinite(scale))
        return kCMTimeInvalid;
    return CMTimeAdd(to.start, CMTimeMultiplyByFloat64(CMTimeSubtract(time, from.start), scale));
}

static CMTimeRange
map_range(CMTimeRange range, CMTimeRange from, CMTimeRange to)
{
    CMTime start = map_time(range.start, from, to);
    CMTime end = map_time(CMTimeRangeGetEnd(range), from, to);
    if (!CMTIME_IS_VALID(start) || !CMTIME_IS_VALID(end))
        return CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid);
    return CMTimeRangeFromTimeToTime(start, end);
}

static CMTimeRange
intersection(CMTimeRange a, CMTimeRange b)
{
    if (!CMTIMERANGE_IS_VALID(a) || !CMTIMERANGE_IS_VALID(b))
        return CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid);
    CMTime start = CMTimeCompare(a.start, b.start) > 0 ? a.start : b.start;
    CMTime aEnd = CMTimeRangeGetEnd(a), bEnd = CMTimeRangeGetEnd(b);
    CMTime end = CMTimeCompare(aEnd, bEnd) < 0 ? aEnd : bEnd;
    if (CMTimeCompare(end, start) <= 0)
        return CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid);
    return CMTimeRangeFromTimeToTime(start, end);
}

static AVCompositionTrackSegment *
piece_mapped(AVCompositionTrackSegment *segment, CMTimeRange oldTargetRange, CMTimeRange newTargetRange)
{
    if (segment.empty)
        return [[AVCompositionTrackSegment alloc] initWithTimeRange:newTargetRange];
    CMTimeRange sourceRange = map_range(oldTargetRange, segment.timeMapping.target, segment.timeMapping.source);
    if (!CMTIMERANGE_IS_VALID(sourceRange) || !segment.sourceURL)
        return nil;
    return [[AVCompositionTrackSegment alloc] initWithURL:segment.sourceURL trackID:segment.sourceTrackID
                                         sourceTimeRange:sourceRange targetTimeRange:newTargetRange];
}

static AVCompositionTrackSegment *
piece(AVCompositionTrackSegment *segment, CMTimeRange targetRange)
{
    return piece_mapped(segment, targetRange, targetRange);
}

static BOOL
set_error(NSError **error, NSInteger code)
{
    if (error)
        *error = AVFError(code, nil);
    return NO;
}

@implementation AVCompositionTrackSegment {
    CMTimeMapping _timeMapping;
    BOOL _empty;
    NSURL *_sourceURL;
    CMPersistentTrackID _sourceTrackID;
}

+ (instancetype)compositionTrackSegmentWithURL:(NSURL *)URL trackID:(CMPersistentTrackID)trackID
                               sourceTimeRange:(CMTimeRange)sourceTimeRange targetTimeRange:(CMTimeRange)targetTimeRange
{
    return [[self alloc] initWithURL:URL trackID:trackID sourceTimeRange:sourceTimeRange targetTimeRange:targetTimeRange];
}

+ (instancetype)compositionTrackSegmentWithTimeRange:(CMTimeRange)timeRange
{
    return [[self alloc] initWithTimeRange:timeRange];
}

- (instancetype)initWithURL:(NSURL *)URL trackID:(CMPersistentTrackID)trackID
            sourceTimeRange:(CMTimeRange)sourceTimeRange targetTimeRange:(CMTimeRange)targetTimeRange
{
    if (!URL || !CMTIMERANGE_IS_VALID(sourceTimeRange) || !CMTIMERANGE_IS_VALID(targetTimeRange))
        return nil;
    CMTimeMapping mapping = { sourceTimeRange, targetTimeRange };
    if ((self = [super _finchInit])) {
        _timeMapping = mapping;
        _empty = NO;
        _sourceURL = [URL copy];
        _sourceTrackID = trackID;
    }
    return self;
}

- (instancetype)initWithTimeRange:(CMTimeRange)timeRange
{
    if (!CMTIMERANGE_IS_VALID(timeRange))
        return nil;
    CMTimeMapping mapping = { CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid), timeRange };
    if ((self = [super _finchInit])) {
        _timeMapping = mapping;
        _empty = YES;
        _sourceTrackID = kCMPersistentTrackID_Invalid;
    }
    return self;
}

- (CMTimeMapping)timeMapping { return _timeMapping; }
- (BOOL)isEmpty { return _empty; }
- (NSURL *)sourceURL { return _sourceURL; }
- (CMPersistentTrackID)sourceTrackID { return _sourceTrackID; }

@end

static NSData *
format_description_data(CMFormatDescriptionRef description)
{
    if (!description)
        return nil;
    CMBlockBufferRef buffer = NULL;
    OSStatus status = noErr;
    if (CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video)
        status = CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(kCFAllocatorDefault,
            (CMVideoFormatDescriptionRef)description, kCFStringEncodingUTF8, NULL, &buffer);
    else if (CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio)
        status = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(kCFAllocatorDefault,
            (CMAudioFormatDescriptionRef)description, NULL, &buffer);
    else
        return nil;
    if (status != noErr || !buffer)
        return nil;
    size_t size = CMBlockBufferGetDataLength(buffer);
    NSMutableData *data = [NSMutableData dataWithLength:size];
    status = CMBlockBufferCopyDataBytes(buffer, 0, size, data.mutableBytes);
    CFRelease(buffer);
    return status == noErr ? data : nil;
}

static CMFormatDescriptionRef
format_description_from_data(NSString *key, NSCoder *coder)
{
    NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:key];
    if (!data.length)
        return NULL;
    int32_t mediaType = [coder decodeInt32ForKey:[key stringByAppendingString:@"Type"]];
    CMFormatDescriptionRef description = NULL;
    OSStatus status;
    if (mediaType == kCMMediaType_Video)
        status = CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(kCFAllocatorDefault, data.bytes, data.length,
            kCFStringEncodingUTF8, NULL, (CMVideoFormatDescriptionRef *)&description);
    else if (mediaType == kCMMediaType_Audio)
        status = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(kCFAllocatorDefault, data.bytes, data.length,
            NULL, (CMAudioFormatDescriptionRef *)&description);
    else
        return NULL;
    return status == noErr ? description : NULL;
}

@interface AVCompositionTrackFormatDescriptionReplacement (FinchComposition)
- (instancetype)initWithFinchOriginal:(CMFormatDescriptionRef)original replacement:(CMFormatDescriptionRef)replacement;
@end

@implementation AVCompositionTrackFormatDescriptionReplacement {
    CMFormatDescriptionRef _originalFormatDescription;
    CMFormatDescriptionRef _replacementFormatDescription;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithFinchOriginal:(CMFormatDescriptionRef)original replacement:(CMFormatDescriptionRef)replacement
{
    if ((self = [super init])) {
        _originalFormatDescription = original ? CFRetain(original) : NULL;
        _replacementFormatDescription = replacement ? CFRetain(replacement) : NULL;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    CMFormatDescriptionRef original = format_description_from_data(@"original", coder);
    if (!original)
        return nil;
    CMFormatDescriptionRef replacement = format_description_from_data(@"replacement", coder);
    self = [self initWithFinchOriginal:original replacement:replacement];
    CFRelease(original);
    if (replacement)
        CFRelease(replacement);
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    CMFormatDescriptionRef values[] = { _originalFormatDescription, _replacementFormatDescription };
    NSString *keys[] = { @"original", @"replacement" };
    for (NSUInteger i = 0; i < 2; i++) {
        CMFormatDescriptionRef value = values[i];
        NSData *data = format_description_data(value);
        if (data) {
            [coder encodeObject:data forKey:keys[i]];
            [coder encodeInt32:CMFormatDescriptionGetMediaType(value) forKey:[keys[i] stringByAppendingString:@"Type"]];
        }
    }
}
- (void)dealloc
{
    if (_originalFormatDescription)
        CFRelease(_originalFormatDescription);
    if (_replacementFormatDescription)
        CFRelease(_replacementFormatDescription);
}
- (CMFormatDescriptionRef)originalFormatDescription { return _originalFormatDescription; }
- (CMFormatDescriptionRef)replacementFormatDescription { return _replacementFormatDescription; }
@end

@implementation AVCompositionTrack {
    __weak AVComposition *_finchComposition;
    AVMediaType _finchMediaType;
    CMPersistentTrackID _finchTrackID;
    NSMutableArray<AVCompositionTrackSegment *> *_finchSegments;
    NSMapTable<AVCompositionTrackSegment *, AVAssetTrack *> *_finchSources;
    NSMutableArray<AVCompositionTrackFormatDescriptionReplacement *> *_finchReplacements;
    NSMutableDictionary<AVTrackAssociationType, NSHashTable<AVCompositionTrack *> *> *_finchAssociations;
    NSString *_finchLanguageCode;
    NSString *_finchExtendedLanguageTag;
    CGAffineTransform _finchTransform;
    float _finchVolume;
    CMTimeScale _finchNaturalTimeScale;
    BOOL _finchEnabled;
}

- (instancetype)initWithFinchComposition:(AVComposition *)composition mediaType:(AVMediaType)mediaType trackID:(CMPersistentTrackID)trackID
{
    if ((self = [super _finchInit])) {
        _finchComposition = composition;
        _finchMediaType = [mediaType copy];
        _finchTrackID = trackID;
        _finchSegments = [NSMutableArray array];
        _finchSources = [NSMapTable strongToStrongObjectsMapTable];
        _finchReplacements = [NSMutableArray array];
        _finchAssociations = [NSMutableDictionary dictionary];
        _finchTransform = CGAffineTransformIdentity;
        _finchVolume = 1.0f;
        _finchEnabled = YES;
    }
    return self;
}

- (AVAsset *)asset { return _finchComposition; }
- (CMPersistentTrackID)trackID { return _finchTrackID; }
- (AVMediaType)mediaType { return _finchMediaType; }
- (NSArray<AVCompositionTrackSegment *> *)segments { return [_finchSegments copy]; }
- (NSArray<AVCompositionTrackFormatDescriptionReplacement *> *)formatDescriptionReplacements { return [_finchReplacements copy]; }

- (CMTimeRange)timeRange
{
    if (!_finchSegments.count)
        return CMTimeRangeMake(kCMTimeZero, kCMTimeZero);
    CMTime end = CMTimeRangeGetEnd(_finchSegments.lastObject.timeMapping.target);
    return CMTimeRangeFromTimeToTime(kCMTimeZero, end);
}

- (AVCompositionTrackSegment *)segmentForTrackTime:(CMTime)trackTime
{
    if (!_finchSegments.count)
        return nil;
    AVCompositionTrackSegment *nearest = _finchSegments.firstObject;
    double nearestDistance = DBL_MAX;
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        CMTimeRange range = segment.timeMapping.target;
        if (CMTimeRangeContainsTime(range, trackTime))
            return segment;
        double start = CMTimeGetSeconds(range.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(range));
        double time = CMTimeGetSeconds(trackTime);
        double distance = time < start ? start - time : time > end ? time - end : 0;
        if (distance < nearestDistance) {
            nearest = segment;
            nearestDistance = distance;
        }
    }
    return nearest;
}

- (AVAssetTrack *)_finchSourceForSegment:(AVCompositionTrackSegment *)segment
{
    AVAssetTrack *track = [_finchSources objectForKey:segment];
    if (!track && segment.sourceURL) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:segment.sourceURL options:nil];
        track = [asset trackWithTrackID:segment.sourceTrackID];
        if (track)
            [_finchSources setObject:track forKey:segment];
    }
    return track;
}

- (AVAssetTrack *)_finchFirstSource
{
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        AVAssetTrack *track = [self _finchSourceForSegment:segment];
        if (track)
            return track;
    }
    return nil;
}

- (NSArray *)formatDescriptions
{
    NSMutableArray *descriptions = [NSMutableArray array];
    for (AVCompositionTrackSegment *segment in _finchSegments)
        for (id description in [self _finchSourceForSegment:segment].formatDescriptions ?: @[])
            if (![descriptions containsObject:description])
                [descriptions addObject:description];
    return descriptions;
}

- (BOOL)isPlayable { return self.formatDescriptions.count > 0; }
- (BOOL)isDecodable { return self.playable; }
- (BOOL)isEnabled { return _finchEnabled; }
- (void)setEnabled:(BOOL)value { _finchEnabled = value; }
- (BOOL)isSelfContained
{
    for (AVCompositionTrackSegment *segment in _finchSegments)
        if (!segment.empty && !segment.sourceURL.isFileURL)
            return NO;
    return YES;
}
- (long long)totalSampleDataLength
{
    long long total = 0;
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        AVAssetTrack *track = [self _finchSourceForSegment:segment];
        if (track && CMTIME_IS_VALID(segment.timeMapping.source.duration) && CMTIME_IS_VALID(track.timeRange.duration) &&
            CMTimeCompare(track.timeRange.duration, kCMTimeZero) > 0) {
            double fraction = CMTimeGetSeconds(segment.timeMapping.source.duration) / CMTimeGetSeconds(track.timeRange.duration);
            if (isfinite(fraction) && fraction > 0)
                total += (long long)(track.totalSampleDataLength * fraction);
        }
    }
    return total;
}
- (CMTimeScale)naturalTimeScale
{
    if (_finchNaturalTimeScale > 0)
        return _finchNaturalTimeScale;
    CMTimeScale sourceScale = [self _finchFirstSource].naturalTimeScale;
    return sourceScale > 0 ? sourceScale : 600;
}
- (void)setNaturalTimeScale:(CMTimeScale)value { _finchNaturalTimeScale = MAX(0, value); }
- (NSString *)languageCode { return _finchLanguageCode ?: [self _finchFirstSource].languageCode; }
- (void)setLanguageCode:(NSString *)value { _finchLanguageCode = [value copy]; }
- (NSString *)extendedLanguageTag { return _finchExtendedLanguageTag ?: [self _finchFirstSource].extendedLanguageTag; }
- (void)setExtendedLanguageTag:(NSString *)value { _finchExtendedLanguageTag = [value copy]; }
- (CGAffineTransform)preferredTransform
{
    return CGAffineTransformIsIdentity(_finchTransform) ? [self _finchFirstSource].preferredTransform : _finchTransform;
}
- (void)setPreferredTransform:(CGAffineTransform)value { _finchTransform = value; }
- (float)preferredVolume { return _finchVolume; }
- (void)setPreferredVolume:(float)value { _finchVolume = value; }
- (CGSize)naturalSize { return [self _finchFirstSource].naturalSize; }
- (float)nominalFrameRate { return [self _finchFirstSource].nominalFrameRate; }
- (float)estimatedDataRate
{
    CMTime duration = self.timeRange.duration;
    double seconds = CMTimeGetSeconds(duration);
    return seconds > 0 ? (float)(self.totalSampleDataLength * 8 / seconds) : 0;
}
- (CMTime)minFrameDuration { return [self _finchFirstSource].minFrameDuration; }
- (BOOL)requiresFrameReordering { return [self _finchFirstSource].requiresFrameReordering; }
- (BOOL)hasAudioSampleDependencies { return [self _finchFirstSource].hasAudioSampleDependencies; }
- (CMTime)samplePresentationTimeForTrackTime:(CMTime)trackTime
{
    AVCompositionTrackSegment *segment = [self segmentForTrackTime:trackTime];
    if (!segment || segment.empty)
        return kCMTimeInvalid;
    CMTime sourceTime = map_time(trackTime, segment.timeMapping.target, segment.timeMapping.source);
    AVAssetTrack *source = [self _finchSourceForSegment:segment];
    return source ? [source samplePresentationTimeForTrackTime:sourceTime] : sourceTime;
}
- (BOOL)hasMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        AVAssetTrack *source = [self _finchSourceForSegment:segment];
        if (source && [source hasMediaCharacteristic:characteristic])
            return YES;
    }
    if ([characteristic isEqualToString:AVMediaCharacteristicVisual])
        return [_finchMediaType isEqualToString:AVMediaTypeVideo];
    if ([characteristic isEqualToString:AVMediaCharacteristicAudible])
        return [_finchMediaType isEqualToString:AVMediaTypeAudio];
    if ([characteristic isEqualToString:AVMediaCharacteristicLegible])
        return [_finchMediaType isEqualToString:AVMediaTypeText] || [_finchMediaType isEqualToString:AVMediaTypeSubtitle] ||
               [_finchMediaType isEqualToString:AVMediaTypeClosedCaption];
    return NO;
}
- (NSArray<AVMetadataItem *> *)metadata { return [self _finchFirstSource].metadata ?: @[]; }
- (NSArray<AVMetadataItem *> *)commonMetadata { return [self _finchFirstSource].commonMetadata ?: @[]; }
- (NSArray<AVMetadataFormat> *)availableMetadataFormats { return [self _finchFirstSource].availableMetadataFormats ?: @[]; }
- (NSArray<AVMetadataItem *> *)metadataForFormat:(AVMetadataFormat)format
{
    return [[self _finchFirstSource] metadataForFormat:format] ?: @[];
}
- (NSArray<AVTrackAssociationType> *)availableTrackAssociationTypes { return _finchAssociations.allKeys; }
- (NSArray<AVAssetTrack *> *)associatedTracksOfType:(AVTrackAssociationType)type
{
    return [_finchAssociations[type] allObjects] ?: @[];
}
- (BOOL)canProvideSampleCursors
{
    for (AVCompositionTrackSegment *segment in _finchSegments)
        if ([self _finchSourceForSegment:segment].canProvideSampleCursors)
            return YES;
    return NO;
}

- (BOOL)validateTrackSegments:(NSArray<AVCompositionTrackSegment *> *)trackSegments error:(NSError **)outError
{
    CMTime expected = kCMTimeZero;
    for (AVCompositionTrackSegment *segment in trackSegments) {
        CMTimeRange target = segment.timeMapping.target;
        if (!CMTIMERANGE_IS_VALID(target) || CMTimeCompare(target.duration, kCMTimeZero) <= 0) {
            if (outError)
                *outError = AVFError(AVErrorInvalidCompositionTrackSegmentDuration, nil);
            return NO;
        }
        if (CMTimeCompare(target.start, expected) != 0) {
            if (outError)
                *outError = AVFError(AVErrorCompositionTrackSegmentsNotContiguous, nil);
            return NO;
        }
        if (!segment.empty && (!CMTIME_IS_VALID(segment.timeMapping.source.start) ||
                               !CMTIME_IS_VALID(segment.timeMapping.source.duration) ||
                               CMTimeCompare(segment.timeMapping.source.duration, kCMTimeZero) <= 0)) {
            if (outError)
                *outError = AVFError(AVErrorInvalidCompositionTrackSegmentSourceDuration, nil);
            return NO;
        }
        expected = CMTimeRangeGetEnd(target);
    }
    if (outError)
        *outError = nil;
    return YES;
}

- (void)setSegments:(NSArray<AVCompositionTrackSegment *> *)segments
{
    NSError *error = nil;
    if (![self validateTrackSegments:segments error:&error])
        return;
    _finchSegments = [segments mutableCopy] ?: [NSMutableArray array];
    _finchSources = [NSMapTable strongToStrongObjectsMapTable];
}

- (void)_finchInsertSegment:(AVCompositionTrackSegment *)segment sourceTrack:(AVAssetTrack *)sourceTrack
{
    NSUInteger index = 0;
    while (index < _finchSegments.count &&
           CMTimeCompare(_finchSegments[index].timeMapping.target.start, segment.timeMapping.target.start) < 0)
        index++;
    [_finchSegments insertObject:segment atIndex:index];
    if (sourceTrack)
        [_finchSources setObject:sourceTrack forKey:segment];
}

- (void)_finchInsertDuration:(CMTime)duration atTime:(CMTime)time
{
    if (!CMTIME_IS_VALID(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0)
        return;
    CMTime end = CMTimeAdd(time, duration);
    NSMutableArray *shifted = [NSMutableArray array];
    NSMapTable *sources = [NSMapTable strongToStrongObjectsMapTable];
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        CMTimeRange target = segment.timeMapping.target;
        CMTime segmentEnd = CMTimeRangeGetEnd(target);
        AVAssetTrack *source = [_finchSources objectForKey:segment];
        if (CMTimeCompare(segmentEnd, time) <= 0) {
            [shifted addObject:segment];
            if (source)
                [sources setObject:source forKey:segment];
        } else if (CMTimeCompare(target.start, time) >= 0) {
            CMTimeRange newTarget = CMTimeRangeMake(CMTimeAdd(target.start, duration), target.duration);
            AVCompositionTrackSegment *copy = piece_mapped(segment, target, newTarget);
            if (copy) {
                [shifted addObject:copy];
                if (source)
                    [sources setObject:source forKey:copy];
            }
        } else {
            CMTimeRange leftRange = CMTimeRangeFromTimeToTime(target.start, time);
            CMTimeRange rightRange = CMTimeRangeMake(end, CMTimeSubtract(segmentEnd, time));
            AVCompositionTrackSegment *left = piece(segment, leftRange);
            AVCompositionTrackSegment *right = piece_mapped(segment, CMTimeRangeFromTimeToTime(time, segmentEnd), rightRange);
            if (left) {
                [shifted addObject:left];
                if (source)
                    [sources setObject:source forKey:left];
            }
            if (right) {
                [shifted addObject:right];
                if (source)
                    [sources setObject:source forKey:right];
            }
        }
    }
    _finchSegments = shifted;
    _finchSources = sources;
}

- (void)_finchInsertEmptyRange:(CMTimeRange)range
{
    [self _finchInsertDuration:range.duration atTime:range.start];
    AVCompositionTrackSegment *empty = [[AVCompositionTrackSegment alloc] initWithTimeRange:range];
    if (empty)
        [self _finchInsertSegment:empty sourceTrack:nil];
}

- (void)_finchRemoveRange:(CMTimeRange)range
{
    CMTime removeEnd = CMTimeRangeGetEnd(range);
    NSMutableArray *result = [NSMutableArray array];
    NSMapTable *sources = [NSMapTable strongToStrongObjectsMapTable];
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        CMTimeRange target = segment.timeMapping.target;
        CMTime end = CMTimeRangeGetEnd(target);
        AVAssetTrack *source = [_finchSources objectForKey:segment];
        if (CMTimeCompare(end, range.start) <= 0) {
            [result addObject:segment];
            if (source)
                [sources setObject:source forKey:segment];
        } else if (CMTimeCompare(target.start, removeEnd) >= 0) {
            CMTimeRange shifted = CMTimeRangeMake(CMTimeSubtract(target.start, range.duration), target.duration);
            AVCompositionTrackSegment *copy = piece_mapped(segment, target, shifted);
            if (copy) {
                [result addObject:copy];
                if (source)
                    [sources setObject:source forKey:copy];
            }
        } else {
            if (CMTimeCompare(target.start, range.start) < 0) {
                AVCompositionTrackSegment *left = piece(segment, CMTimeRangeFromTimeToTime(target.start, range.start));
                if (left) {
                    [result addObject:left];
                    if (source)
                        [sources setObject:source forKey:left];
                }
            }
            if (CMTimeCompare(end, removeEnd) > 0) {
                CMTimeRange rightRange = CMTimeRangeMake(range.start, CMTimeSubtract(end, removeEnd));
                CMTimeRange oldRightRange = CMTimeRangeFromTimeToTime(removeEnd, end);
                AVCompositionTrackSegment *right = piece_mapped(segment, oldRightRange, rightRange);
                if (right) {
                    [result addObject:right];
                    if (source)
                        [sources setObject:source forKey:right];
                }
            }
        }
    }
    _finchSegments = result;
    _finchSources = sources;
}

- (void)_finchScaleRange:(CMTimeRange)range toDuration:(CMTime)newDuration
{
    if (!CMTIMERANGE_IS_VALID(range) || !CMTIME_IS_VALID(newDuration) ||
        CMTimeCompare(range.duration, kCMTimeZero) <= 0)
        return;
    CMTime rangeEnd = CMTimeRangeGetEnd(range);
    CMTime delta = CMTimeSubtract(newDuration, range.duration);
    NSMutableArray *result = [NSMutableArray array];
    NSMapTable *sources = [NSMapTable strongToStrongObjectsMapTable];
    for (AVCompositionTrackSegment *segment in _finchSegments) {
        CMTimeRange target = segment.timeMapping.target;
        CMTime end = CMTimeRangeGetEnd(target);
        AVAssetTrack *source = [_finchSources objectForKey:segment];
        if (CMTimeCompare(end, range.start) <= 0) {
            [result addObject:segment];
            if (source)
                [sources setObject:source forKey:segment];
            continue;
        }
        if (CMTimeCompare(target.start, rangeEnd) >= 0) {
            AVCompositionTrackSegment *copy = piece_mapped(segment, target, CMTimeRangeMake(CMTimeAdd(target.start, delta), target.duration));
            if (copy) {
                [result addObject:copy];
                if (source)
                    [sources setObject:source forKey:copy];
            }
            continue;
        }
        CMTime middleStart = CMTimeCompare(target.start, range.start) < 0 ? range.start : target.start;
        CMTime middleEnd = CMTimeCompare(end, rangeEnd) > 0 ? rangeEnd : end;
        if (CMTimeCompare(target.start, middleStart) < 0) {
            AVCompositionTrackSegment *left = piece(segment, CMTimeRangeFromTimeToTime(target.start, middleStart));
            if (left) {
                [result addObject:left];
                if (source)
                    [sources setObject:source forKey:left];
            }
        }
        CMTime scaledStart = map_time(middleStart, range, CMTimeRangeMake(range.start, newDuration));
        CMTime scaledEnd = map_time(middleEnd, range, CMTimeRangeMake(range.start, newDuration));
        CMTimeRange oldMiddleRange = CMTimeRangeFromTimeToTime(middleStart, middleEnd);
        AVCompositionTrackSegment *middle = piece_mapped(segment, oldMiddleRange, CMTimeRangeFromTimeToTime(scaledStart, scaledEnd));
        if (middle) {
            [result addObject:middle];
            if (source)
                [sources setObject:source forKey:middle];
        }
        if (CMTimeCompare(end, middleEnd) > 0) {
            CMTimeRange oldRightRange = CMTimeRangeFromTimeToTime(middleEnd, end);
            CMTimeRange rightRange = CMTimeRangeMake(scaledEnd, oldRightRange.duration);
            AVCompositionTrackSegment *right = piece_mapped(segment, oldRightRange, rightRange);
            if (right) {
                [result addObject:right];
                if (source)
                    [sources setObject:source forKey:right];
            }
        }
    }
    _finchSegments = result;
    _finchSources = sources;
}

- (BOOL)_finchInsertTrack:(AVAssetTrack *)track timeRange:(CMTimeRange)timeRange atTime:(CMTime)time error:(NSError **)error
{
    if (!track || !CMTIMERANGE_IS_VALID(timeRange) || CMTimeCompare(timeRange.duration, kCMTimeZero) <= 0)
        return set_error(error, AVErrorInvalidCompositionTrackSegmentDuration);
    if (!CMTIME_IS_VALID(time))
        time = CMTimeRangeGetEnd(self.timeRange);
    if (CMTimeCompare(time, kCMTimeZero) < 0)
        return set_error(error, AVErrorInvalidCompositionTrackSegmentSourceStartTime);
    NSURL *URL = [track.asset isKindOfClass:[AVURLAsset class]] ? [(AVURLAsset *)track.asset URL] : nil;
    if (!URL)
        return set_error(error, AVErrorNoSourceTrack);
    CMTimeRange sourceRange = intersection(timeRange, track.timeRange);
    if (!CMTIMERANGE_IS_VALID(sourceRange))
        return set_error(error, AVErrorNoSourceTrack);
    [self _finchInsertDuration:sourceRange.duration atTime:time];
    CMTime currentEnd = CMTimeRangeGetEnd(self.timeRange);
    if (CMTimeCompare(currentEnd, time) < 0) {
        CMTimeRange gap = CMTimeRangeFromTimeToTime(currentEnd, time);
        AVCompositionTrackSegment *empty = [[AVCompositionTrackSegment alloc] initWithTimeRange:gap];
        if (empty)
            [self _finchInsertSegment:empty sourceTrack:nil];
    }
    CMTime targetTime = CMTimeAdd(time, CMTimeSubtract(sourceRange.start, timeRange.start));
    CMTimeRange targetRange = CMTimeRangeMake(targetTime, sourceRange.duration);
    AVCompositionTrackSegment *segment = [[AVCompositionTrackSegment alloc] initWithURL:URL trackID:track.trackID
                                                                         sourceTimeRange:sourceRange targetTimeRange:targetRange];
    if (!segment)
        return set_error(error, AVErrorInvalidCompositionTrackSegmentSourceDuration);
    [self _finchInsertSegment:segment sourceTrack:track];
    if (error)
        *error = nil;
    return YES;
}

- (void)insertEmptyTimeRange:(CMTimeRange)timeRange
{
    if (!CMTIMERANGE_IS_VALID(timeRange) || CMTimeCompare(timeRange.duration, kCMTimeZero) <= 0)
        return;
    [self _finchInsertEmptyRange:timeRange];
}
- (void)removeTimeRange:(CMTimeRange)timeRange
{
    if (CMTIMERANGE_IS_VALID(timeRange) && CMTimeCompare(timeRange.duration, kCMTimeZero) > 0)
        [self _finchRemoveRange:timeRange];
}
- (void)scaleTimeRange:(CMTimeRange)timeRange toDuration:(CMTime)duration
{
    [self _finchScaleRange:timeRange toDuration:duration];
}
- (BOOL)insertTimeRange:(CMTimeRange)timeRange ofTrack:(AVAssetTrack *)track atTime:(CMTime)startTime error:(NSError **)error
{
    return [self _finchInsertTrack:track timeRange:timeRange atTime:startTime error:error];
}
- (BOOL)insertTimeRanges:(NSArray<NSValue *> *)timeRanges ofTracks:(NSArray<AVAssetTrack *> *)tracks atTime:(CMTime)startTime error:(NSError **)error
{
    if (timeRanges.count != tracks.count)
        return set_error(error, AVErrorInvalidCompositionTrackSegmentDuration);
    if (!CMTIME_IS_VALID(startTime))
        startTime = CMTimeRangeGetEnd(self.timeRange);
    CMTime offset = kCMTimeZero;
    for (NSUInteger i = 0; i < timeRanges.count; i++) {
        CMTimeRange range = timeRanges[i].CMTimeRangeValue;
        if (![self _finchInsertTrack:tracks[i] timeRange:range atTime:CMTimeAdd(startTime, offset) error:error])
            return NO;
        offset = CMTimeAdd(offset, range.duration);
    }
    return YES;
}
- (void)_finchAssociateTrack:(AVCompositionTrack *)track withType:(AVTrackAssociationType)type
{
    if (!track || track == self || !type.length)
        return;
    NSHashTable *tracks = _finchAssociations[type];
    if (!tracks) {
        tracks = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory];
        _finchAssociations[type] = tracks;
    }
    [tracks addObject:track];
}
- (void)addTrackAssociationToTrack:(AVCompositionTrack *)track type:(AVTrackAssociationType)type
{
    if (![track isKindOfClass:[AVCompositionTrack class]] || track.asset != self.asset)
        return;
    [self _finchAssociateTrack:track withType:type];
    [(AVCompositionTrack *)track _finchAssociateTrack:self withType:type];
}
- (void)removeTrackAssociationToTrack:(AVCompositionTrack *)track type:(AVTrackAssociationType)type
{
    [_finchAssociations[type] removeObject:track];
    if ([track isKindOfClass:[AVCompositionTrack class]])
        [((AVCompositionTrack *)track)->_finchAssociations[type] removeObject:self];
}
- (void)replaceFormatDescription:(CMFormatDescriptionRef)originalFormatDescription withFormatDescription:(CMFormatDescriptionRef)replacementFormatDescription
{
    if (!originalFormatDescription)
        return;
    NSUInteger index = [_finchReplacements indexOfObjectPassingTest:^BOOL(AVCompositionTrackFormatDescriptionReplacement *item, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        return CFEqual(item.originalFormatDescription, originalFormatDescription);
    }];
    AVCompositionTrackFormatDescriptionReplacement *replacement =
        [[AVCompositionTrackFormatDescriptionReplacement alloc] initWithFinchOriginal:originalFormatDescription replacement:replacementFormatDescription];
    if (!replacement)
        return;
    if (index == NSNotFound)
        [_finchReplacements addObject:replacement];
    else
        _finchReplacements[index] = replacement;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation AVMutableCompositionTrack
- (void)addTrackAssociationToTrack:(AVCompositionTrack *)track type:(AVTrackAssociationType)type
{
    [super addTrackAssociationToTrack:track type:type];
}
- (void)removeTrackAssociationToTrack:(AVCompositionTrack *)track type:(AVTrackAssociationType)type
{
    [super removeTrackAssociationToTrack:track type:type];
}
- (BOOL)insertTimeRange:(CMTimeRange)timeRange ofTrack:(AVAssetTrack *)track atTime:(CMTime)startTime error:(NSError **)error
{
    return [super insertTimeRange:timeRange ofTrack:track atTime:startTime error:error];
}
- (BOOL)insertTimeRanges:(NSArray<NSValue *> *)timeRanges ofTracks:(NSArray<AVAssetTrack *> *)tracks atTime:(CMTime)startTime error:(NSError **)error
{
    return [super insertTimeRanges:timeRanges ofTracks:tracks atTime:startTime error:error];
}
- (void)insertEmptyTimeRange:(CMTimeRange)timeRange { [super insertEmptyTimeRange:timeRange]; }
- (void)removeTimeRange:(CMTimeRange)timeRange { [super removeTimeRange:timeRange]; }
- (void)scaleTimeRange:(CMTimeRange)timeRange toDuration:(CMTime)duration { [super scaleTimeRange:timeRange toDuration:duration]; }
- (BOOL)validateTrackSegments:(NSArray<AVCompositionTrackSegment *> *)segments error:(NSError **)error
{
    return [super validateTrackSegments:segments error:error];
}
- (void)replaceFormatDescription:(CMFormatDescriptionRef)originalFormatDescription withFormatDescription:(CMFormatDescriptionRef)replacementFormatDescription
{
    [super replaceFormatDescription:originalFormatDescription withFormatDescription:replacementFormatDescription];
}
@dynamic naturalTimeScale, languageCode, extendedLanguageTag, preferredTransform, preferredVolume, segments;
@end

@implementation AVComposition {
    NSMutableArray<AVMutableCompositionTrack *> *_finchTracks;
    NSDictionary *_finchURLAssetOptions;
    CGSize _finchNaturalSize;
}

- (instancetype)init { return [self initWithFinchOptions:nil]; }
- (instancetype)initWithFinchOptions:(NSDictionary *)options
{
    if ((self = [super init])) {
        _finchTracks = [NSMutableArray array];
        _finchURLAssetOptions = [options copy] ?: @{};
    }
    return self;
}
- (NSArray<AVCompositionTrack *> *)tracks { return [_finchTracks copy]; }
- (NSDictionary *)URLAssetInitializationOptions { return _finchURLAssetOptions; }
- (CGSize)naturalSize
{
    if (!CGSizeEqualToSize(_finchNaturalSize, CGSizeZero))
        return _finchNaturalSize;
    for (AVCompositionTrack *track in _finchTracks)
        if ([track.mediaType isEqualToString:AVMediaTypeVideo])
            return track.naturalSize;
    return CGSizeZero;
}
- (void)setNaturalSize:(CGSize)size { _finchNaturalSize = size; }
- (CMTime)duration
{
    CMTime end = kCMTimeZero;
    for (AVCompositionTrack *track in _finchTracks)
        if (CMTimeCompare(CMTimeRangeGetEnd(track.timeRange), end) > 0)
            end = CMTimeRangeGetEnd(track.timeRange);
    return end;
}
- (BOOL)isPlayable
{
    for (AVCompositionTrack *track in _finchTracks)
        if (track.playable)
            return YES;
    return NO;
}
- (BOOL)isReadable { return self.playable; }
- (BOOL)isExportable { return self.playable; }
- (BOOL)isComposable { return self.playable; }
- (BOOL)hasProtectedContent { return NO; }
- (BOOL)providesPreciseDurationAndTiming { return YES; }
- (CMPersistentTrackID)unusedTrackID
{
    CMPersistentTrackID highest = 0;
    for (AVCompositionTrack *track in _finchTracks)
        highest = MAX(highest, track.trackID);
    return highest < INT32_MAX - 1 ? highest + 2 : INT32_MAX;
}
- (AVMutableCompositionTrack *)_finchAddTrack:(AVMediaType)mediaType trackID:(CMPersistentTrackID)trackID
{
    if (trackID == kCMPersistentTrackID_Invalid) {
        trackID = 1;
        while ([self trackWithTrackID:trackID])
            trackID++;
    } else if ([self trackWithTrackID:trackID]) {
        return nil;
    }
    AVMutableCompositionTrack *track = [[AVMutableCompositionTrack alloc] initWithFinchComposition:self mediaType:mediaType trackID:trackID];
    if (track)
        [_finchTracks addObject:track];
    return track;
}
- (void)_finchRemoveTrack:(AVCompositionTrack *)track { [_finchTracks removeObjectIdenticalTo:(AVMutableCompositionTrack *)track]; }
- (AVCompositionTrack *)trackWithTrackID:(CMPersistentTrackID)trackID
{
    for (AVCompositionTrack *track in _finchTracks)
        if (track.trackID == trackID)
            return track;
    return nil;
}
- (AVMutableCompositionTrack *)addMutableTrackWithMediaType:(AVMediaType)mediaType preferredTrackID:(CMPersistentTrackID)preferredTrackID
{
    if (!mediaType.length)
        return nil;
    return [self _finchAddTrack:mediaType trackID:preferredTrackID];
}
- (void)removeTrack:(AVCompositionTrack *)track { [self _finchRemoveTrack:track]; }
- (AVMutableCompositionTrack *)mutableTrackCompatibleWithTrack:(AVAssetTrack *)track
{
    if (!track)
        return nil;
    for (AVMutableCompositionTrack *candidate in _finchTracks)
        if ([candidate.mediaType isEqualToString:track.mediaType] && candidate.segments.count == 0)
            return candidate;
    return [self addMutableTrackWithMediaType:track.mediaType preferredTrackID:kCMPersistentTrackID_Invalid];
}
- (BOOL)insertTimeRange:(CMTimeRange)timeRange ofAsset:(AVAsset *)asset atTime:(CMTime)startTime error:(NSError **)error
{
    if (!asset || !CMTIMERANGE_IS_VALID(timeRange) || CMTimeCompare(timeRange.duration, kCMTimeZero) <= 0 ||
        !CMTIME_IS_VALID(startTime) || CMTimeCompare(startTime, kCMTimeZero) < 0)
        return set_error(error, AVErrorInvalidCompositionTrackSegmentDuration);
    if (!CMTIME_IS_VALID(self.duration))
        return set_error(error, AVErrorInvalidCompositionTrackSegmentDuration);
    for (AVMutableCompositionTrack *track in _finchTracks)
        [track _finchInsertDuration:timeRange.duration atTime:startTime];

    for (AVAssetTrack *source in asset.tracks) {
        CMTimeRange available = intersection(timeRange, source.timeRange);
        if (!CMTIMERANGE_IS_VALID(available))
            continue;
        AVMutableCompositionTrack *target = [self addMutableTrackWithMediaType:source.mediaType preferredTrackID:kCMPersistentTrackID_Invalid];
        if (!target)
            return set_error(error, AVErrorInvalidCompositionTrackSegmentDuration);
        target.naturalTimeScale = source.naturalTimeScale;
        target.languageCode = source.languageCode;
        target.extendedLanguageTag = source.extendedLanguageTag;
        target.preferredTransform = source.preferredTransform;
        target.preferredVolume = source.preferredVolume;
        CMTime targetStart = CMTimeAdd(startTime, CMTimeSubtract(available.start, timeRange.start));
        if (CMTimeCompare(targetStart, kCMTimeZero) > 0) {
            CMTimeRange gap = CMTimeRangeMake(kCMTimeZero, targetStart);
            AVCompositionTrackSegment *empty = [[AVCompositionTrackSegment alloc] initWithTimeRange:gap];
            [target _finchInsertSegment:empty sourceTrack:nil];
        }
        NSURL *URL = [source.asset isKindOfClass:[AVURLAsset class]] ? [(AVURLAsset *)source.asset URL] : nil;
        if (!URL)
            return set_error(error, AVErrorNoSourceTrack);
        CMTimeRange targetRange = CMTimeRangeMake(targetStart, available.duration);
        AVCompositionTrackSegment *segment = [[AVCompositionTrackSegment alloc] initWithURL:URL trackID:source.trackID
                                                                             sourceTimeRange:available targetTimeRange:targetRange];
        if (!segment)
            return set_error(error, AVErrorInvalidCompositionTrackSegmentSourceDuration);
        [target _finchInsertSegment:segment sourceTrack:source];
        CMTime tailStart = CMTimeRangeGetEnd(targetRange);
        CMTime tailEnd = CMTimeAdd(startTime, timeRange.duration);
        if (CMTimeCompare(tailEnd, tailStart) > 0) {
            AVCompositionTrackSegment *empty = [[AVCompositionTrackSegment alloc] initWithTimeRange:CMTimeRangeFromTimeToTime(tailStart, tailEnd)];
            [target _finchInsertSegment:empty sourceTrack:nil];
        }
    }
    if (error)
        *error = nil;
    return YES;
}
- (void)insertTimeRange:(CMTimeRange)timeRange ofAsset:(AVAsset *)asset atTime:(CMTime)startTime completionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = nil;
    [self insertTimeRange:timeRange ofAsset:asset atTime:startTime error:&error];
    if (completionHandler)
        dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(error); });
}
- (void)insertEmptyTimeRange:(CMTimeRange)timeRange
{
    for (AVMutableCompositionTrack *track in _finchTracks)
        [track insertEmptyTimeRange:timeRange];
}
- (void)removeTimeRange:(CMTimeRange)timeRange
{
    for (AVMutableCompositionTrack *track in _finchTracks)
        [track removeTimeRange:timeRange];
}
- (void)scaleTimeRange:(CMTimeRange)timeRange toDuration:(CMTime)duration
{
    for (AVMutableCompositionTrack *track in _finchTracks)
        [track scaleTimeRange:timeRange toDuration:duration];
}
- (id)copyWithZone:(NSZone *)zone
{
    AVComposition *copy = [[AVComposition alloc] initWithFinchOptions:_finchURLAssetOptions];
    copy->_finchNaturalSize = _finchNaturalSize;
    for (AVMutableCompositionTrack *track in _finchTracks) {
        AVMutableCompositionTrack *newTrack = [copy _finchAddTrack:track.mediaType trackID:track.trackID];
        newTrack.naturalTimeScale = track.naturalTimeScale;
        newTrack.languageCode = track.languageCode;
        newTrack.extendedLanguageTag = track.extendedLanguageTag;
        newTrack.preferredTransform = track.preferredTransform;
        newTrack.preferredVolume = track.preferredVolume;
        newTrack.enabled = track.enabled;
        newTrack.segments = track.segments;
    }
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    AVMutableComposition *copy = [[AVMutableComposition alloc] initWithFinchOptions:_finchURLAssetOptions];
    copy.naturalSize = _finchNaturalSize;
    for (AVMutableCompositionTrack *track in _finchTracks) {
        AVMutableCompositionTrack *newTrack = [copy _finchAddTrack:track.mediaType trackID:track.trackID];
        newTrack.naturalTimeScale = track.naturalTimeScale;
        newTrack.languageCode = track.languageCode;
        newTrack.extendedLanguageTag = track.extendedLanguageTag;
        newTrack.preferredTransform = track.preferredTransform;
        newTrack.preferredVolume = track.preferredVolume;
        newTrack.enabled = track.enabled;
        newTrack.segments = track.segments;
    }
    return copy;
}
@end

@implementation AVMutableComposition
@dynamic naturalSize;
+ (instancetype)composition { return [[self alloc] init]; }
+ (instancetype)compositionWithURLAssetInitializationOptions:(NSDictionary *)options
{
    return [[self alloc] initWithFinchOptions:options];
}
@end

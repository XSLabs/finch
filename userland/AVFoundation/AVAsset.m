/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AVAsset, AVURLAsset, AVAssetTrack and AVAssetTrackSegment over Finch's movie reader
 * (AVFMovie.m). An asset reads its file the first time anything is asked of it (or when
 * its values are loaded asynchronously, on a background queue); what it reports is
 * Apple's arithmetic over the file (macOS 26.4, avasset-test.m):
 *   - The asset's duration is the movie header's; a track's time range starts at zero
 *     and lasts its header's duration (in the movie's timescale), and with no edit list
 *     it has one segment mapping that range onto itself.
 *   - A track's nominal frame rate is its samples per second of media; its data rate
 *     is its sample bytes in bits per second of media; its minimum frame duration is
 *     its shortest sample (video only).
 *   - The creation date is the user data's date (ISO 8601) or else the movie header's.
 *   - Common metadata: the first item for each common key, in Apple's order.
 *   - A missing file fails loading with AVErrorUnknown (-11800), one that isn't a movie
 *     with -11829; unknown keys load (as Apple's, which logs them).
 */
#import "AVFInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSError *
AVFError(NSInteger code, NSError *underlying)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (underlying)
        info[NSUnderlyingErrorKey] = underlying;
    info[NSLocalizedDescriptionKey] = code == AVErrorUnknown ? @"The operation could not be completed" : @"Cannot Open";
    return [NSError errorWithDomain:AVFoundationErrorDomain code:code userInfo:info];
}

CGRect
AVMakeRectWithAspectRatioInsideRect(CGSize aspectRatio, CGRect boundingRect)
{
    if (aspectRatio.width <= 0 || aspectRatio.height <= 0)
        return CGRectMake(CGRectGetMidX(boundingRect), CGRectGetMidY(boundingRect), 0, 0);
    double scale = MIN(boundingRect.size.width / aspectRatio.width, boundingRect.size.height / aspectRatio.height);
    CGSize s = CGSizeMake(aspectRatio.width * scale, aspectRatio.height * scale);
    return CGRectMake(boundingRect.origin.x + (boundingRect.size.width - s.width) / 2,
                      boundingRect.origin.y + (boundingRect.size.height - s.height) / 2, s.width, s.height);
}

static NSArray *
asset_keys(void)
{
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"duration", @"tracks", @"playable", @"readable", @"exportable", @"composable", @"metadata", @"commonMetadata",
            @"availableMetadataFormats", @"preferredRate", @"preferredVolume", @"preferredTransform", @"naturalSize",
            @"providesPreciseDurationAndTiming", @"creationDate", @"lyrics", @"availableChapterLocales",
            @"availableMediaCharacteristicsWithMediaSelectionOptions", @"hasProtectedContent", @"compatibleWithSavedPhotosAlbum",
            @"compatibleWithAirPlayVideo", @"overallDurationHint", @"minimumTimeOffsetFromLive", @"canContainFragments",
            @"containsFragments", @"referenceRestrictions", @"trackGroups", @"allMediaSelections", @"preferredMediaSelection",
            @"URL", @"variants", @"mediaSelections"
        ];
    });
    return keys;
}

#pragma mark - Tracks

@interface AVAssetTrack ()
- (instancetype)initWithFinchTrack:(AVFTrack *)track movie:(AVFMovie *)movie asset:(AVAsset *)asset;
@end

@interface AVAssetTrackSegment ()
- (instancetype)initWithFinchMapping:(CMTimeMapping)mapping empty:(BOOL)empty;
@end

@implementation AVAssetTrackSegment {
    BOOL _empty;
}
- (instancetype)initWithFinchMapping:(CMTimeMapping)mapping empty:(BOOL)empty
{
    if ((self = [super init])) {
        _timeMapping = mapping;
        _empty = empty;
    }
    return self;
}
- (CMTimeMapping)timeMapping { return _timeMapping; }
- (BOOL)isEmpty { return _empty; }
@end

@implementation AVAssetTrack {
    AVFTrack *_ftrack;
    AVFMovie *_fmovie;
    __weak AVAsset *_fasset;
    NSArray *_fmetadata;
}

- (instancetype)initWithFinchTrack:(AVFTrack *)track movie:(AVFMovie *)movie asset:(AVAsset *)asset
{
    if ((self = [super init])) {
        _ftrack = track;
        _fmovie = movie;
        _fasset = asset;
        NSMutableArray *items = [NSMutableArray array];
        for (AVFMetadataEntry *e in track->userData)
            [items addObject:[AVMetadataItem _finchItemWithEntry:e]];
        _fmetadata = items;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (AVFTrack *)_finchTrack { return _ftrack; }
- (AVAsset *)asset { return _fasset; }
- (CMPersistentTrackID)trackID { return (CMPersistentTrackID)_ftrack->trackID; }

- (AVMediaType)mediaType
{
    switch (_ftrack->handler) {
    case 'vide': return AVMediaTypeVideo;
    case 'soun': return AVMediaTypeAudio;
    case 'text': return AVMediaTypeText;
    case 'clcp': return AVMediaTypeClosedCaption;
    case 'sbtl': return AVMediaTypeSubtitle;
    case 'tmcd': return AVMediaTypeTimecode;
    case 'meta': return AVMediaTypeMetadata;
    case 'muxx': return AVMediaTypeMuxed;
    default: {
        uint32_t h = _ftrack->handler;
        char s[5] = {(char)(h >> 24), (char)(h >> 16), (char)(h >> 8), (char)h, 0};
        return @(s);
    }
    }
}

- (NSArray *)formatDescriptions { return [_ftrack->formatDescriptions copy]; }
- (BOOL)isPlayable { return [_ftrack->formatDescriptions count] > 0; }
- (BOOL)isDecodable { return [self isPlayable]; }
- (BOOL)isEnabled { return (_ftrack->flags & 1) != 0; }
- (BOOL)isSelfContained { return _ftrack->selfContained; }
- (long long)totalSampleDataLength { return (long long)_ftrack->totalBytes; }
- (CMTimeScale)naturalTimeScale { return (CMTimeScale)_ftrack->timescale; }
- (NSString *)languageCode { return _ftrack->language; }
- (NSString *)extendedLanguageTag { return _ftrack->extendedLanguage; }
- (float)preferredVolume { return _ftrack->volume; }
- (CGAffineTransform)preferredTransform { return _ftrack->matrix; }
- (BOOL)requiresFrameReordering
{
    for (size_t i = 0; i < _ftrack->sampleCount; i++)
        if (_ftrack->samples[i].compositionOffset)
            return YES;
    return NO;
}

- (CGSize)naturalSize
{
    if (_ftrack->handler != 'vide')
        return _ftrack->dimensions;
    return _ftrack->dimensions;
}

- (CMTimeRange)timeRange
{
    uint32_t ts = _fmovie->timescale ? _fmovie->timescale : 600;
    int64_t total = 0;
    if (_ftrack->editCount) {
        for (size_t i = 0; i < _ftrack->editCount; i++)
            total += _ftrack->edits[i].duration;
    } else {
        total = (int64_t)_ftrack->duration;
    }
    return CMTimeRangeMake(kCMTimeZero, CMTimeMake(total, (int32_t)ts));
}

- (double)_finchMediaSeconds
{
    return _ftrack->timescale ? (double)_ftrack->mediaDuration / _ftrack->timescale : 0;
}

- (float)nominalFrameRate
{
    double secs = [self _finchMediaSeconds];
    return secs > 0 ? (float)(_ftrack->sampleCount / secs) : 0;
}

- (float)estimatedDataRate
{
    double secs = [self _finchMediaSeconds];
    return secs > 0 ? (float)(_ftrack->totalBytes * 8 / secs) : 0;
}

- (CMTime)minFrameDuration
{
    if (_ftrack->handler != 'vide' || !_ftrack->sampleCount)
        return kCMTimeInvalid;
    uint32_t m = UINT32_MAX;
    for (size_t i = 0; i < _ftrack->sampleCount; i++)
        if (_ftrack->samples[i].duration && _ftrack->samples[i].duration < m)
            m = _ftrack->samples[i].duration;
    return m == UINT32_MAX ? kCMTimeInvalid : CMTimeMake(m, (int32_t)_ftrack->timescale);
}

- (NSArray<AVAssetTrackSegment *> *)segments
{
    uint32_t ts = _fmovie->timescale ? _fmovie->timescale : 600;
    NSMutableArray *out = [NSMutableArray array];
    if (!_ftrack->editCount) {
        CMTimeRange r = [self timeRange];
        [out addObject:[[AVAssetTrackSegment alloc] initWithFinchMapping:(CMTimeMapping){r, r} empty:NO]];
        return out;
    }
    int64_t at = 0;
    for (size_t i = 0; i < _ftrack->editCount; i++) {
        AVFEdit e = _ftrack->edits[i];
        CMTimeRange target = CMTimeRangeMake(CMTimeMake(at, (int32_t)ts), CMTimeMake(e.duration, (int32_t)ts));
        AVAssetTrackSegment *s;
        if (e.mediaTime < 0) {
            s = [[AVAssetTrackSegment alloc] initWithFinchMapping:(CMTimeMapping){CMTimeRangeMake(kCMTimeInvalid, kCMTimeInvalid), target}
                                                            empty:YES];
        } else {
            CMTime d = CMTimeConvertScale(target.duration, (int32_t)_ftrack->timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
            s = [[AVAssetTrackSegment alloc]
                initWithFinchMapping:(CMTimeMapping){CMTimeRangeMake(CMTimeMake(e.mediaTime, (int32_t)_ftrack->timescale), d), target}
                               empty:NO];
        }
        [out addObject:s];
        at += e.duration;
    }
    return out;
}

- (AVAssetTrackSegment *)segmentForTrackTime:(CMTime)trackTime
{
    for (AVAssetTrackSegment *s in [self segments])
        if (CMTimeRangeContainsTime(s.timeMapping.target, trackTime))
            return s;
    return nil;
}

- (CMTime)samplePresentationTimeForTrackTime:(CMTime)trackTime { return trackTime; }

- (BOOL)hasMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    uint32_t h = _ftrack->handler;
    if ([characteristic isEqualToString:AVMediaCharacteristicVisual])
        return h == 'vide' || h == 'text' || h == 'sbtl' || h == 'clcp';
    if ([characteristic isEqualToString:AVMediaCharacteristicAudible])
        return h == 'soun';
    if ([characteristic isEqualToString:AVMediaCharacteristicLegible])
        return h == 'text' || h == 'sbtl' || h == 'clcp';
    if ([characteristic isEqualToString:AVMediaCharacteristicFrameBased])
        return h == 'vide';
    return NO;
}

- (NSArray<AVMetadataItem *> *)metadata { return _fmetadata; }
- (NSArray<AVMetadataItem *> *)commonMetadata { return AVFCommonMetadata(_fmetadata); }
- (NSArray<AVMetadataFormat> *)availableMetadataFormats
{
    return [_fmetadata count] ? @[ AVMetadataFormatQuickTimeUserData ] : @[];
}
- (NSArray<AVMetadataItem *> *)metadataForFormat:(AVMetadataFormat)format
{
    return [format isEqualToString:AVMetadataFormatQuickTimeUserData] ? _fmetadata : @[];
}
- (NSArray<AVTrackAssociationType> *)availableTrackAssociationTypes { return @[]; }
- (NSArray<AVAssetTrack *> *)associatedTracksOfType:(AVTrackAssociationType)trackAssociationType { return @[]; }
- (BOOL)canProvideSampleCursors { return YES; }
- (BOOL)hasAudioSampleDependencies { return NO; }

- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)outError { return AVKeyValueStatusLoaded; }

- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler
{
    if (handler)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), handler);
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, trackID = %d, mediaType = %@>", NSStringFromClass([self class]), self,
                                      self.trackID, self.mediaType];
}

@end

#pragma mark - Assets

@implementation AVAsset

+ (instancetype)assetWithURL:(NSURL *)URL { return [AVURLAsset URLAssetWithURL:URL options:nil]; }

- (CMTime)duration { return kCMTimeZero; }
- (NSArray<AVAssetTrack *> *)tracks { return @[]; }
- (float)preferredRate { return 1; }
- (float)preferredVolume { return 1; }
- (CGAffineTransform)preferredTransform { return CGAffineTransformIdentity; }
- (CGSize)naturalSize { return CGSizeZero; }
- (BOOL)providesPreciseDurationAndTiming { return NO; }
- (BOOL)isPlayable { return NO; }
- (BOOL)isReadable { return NO; }
- (BOOL)isExportable { return NO; }
- (BOOL)isComposable { return NO; }
- (BOOL)hasProtectedContent { return NO; }
- (BOOL)isCompatibleWithSavedPhotosAlbum { return NO; }
- (BOOL)isCompatibleWithAirPlayVideo { return NO; }
- (BOOL)canContainFragments { return NO; }
- (BOOL)containsFragments { return NO; }
- (CMTime)overallDurationHint { return kCMTimeInvalid; }
- (CMTime)minimumTimeOffsetFromLive { return kCMTimeInvalid; }
- (AVAssetReferenceRestrictions)referenceRestrictions { return AVAssetReferenceRestrictionForbidLocalReferenceToRemote; }
- (NSArray *)trackGroups { return @[]; }
- (NSArray<AVMetadataItem *> *)metadata { return @[]; }
- (NSArray<AVMetadataItem *> *)commonMetadata { return AVFCommonMetadata([self metadata]); }
- (NSArray<AVMetadataFormat> *)availableMetadataFormats { return @[]; }
- (NSArray<AVMetadataItem *> *)metadataForFormat:(AVMetadataFormat)format { return @[]; }
- (AVMetadataItem *)creationDate { return nil; }
- (NSString *)lyrics { return nil; }
- (NSArray<NSLocale *> *)availableChapterLocales { return @[]; }
- (NSArray<AVTimedMetadataGroup *> *)chapterMetadataGroupsWithTitleLocale:(NSLocale *)locale
                                             containingItemsWithCommonKeys:(NSArray<AVMetadataKey> *)commonKeys
{
    return @[];
}
- (NSArray<AVTimedMetadataGroup *> *)chapterMetadataGroupsBestMatchingPreferredLanguages:(NSArray<NSString *> *)preferredLanguages
{
    return @[];
}
- (NSArray<AVMediaCharacteristic> *)availableMediaCharacteristicsWithMediaSelectionOptions { return @[]; }
- (AVMediaSelectionGroup *)mediaSelectionGroupForMediaCharacteristic:(AVMediaCharacteristic)mediaCharacteristic { return nil; }
- (NSArray<AVMediaSelection *> *)allMediaSelections { return @[]; }
- (AVMediaSelection *)preferredMediaSelection { return nil; }

- (AVAssetTrack *)trackWithTrackID:(CMPersistentTrackID)trackID
{
    for (AVAssetTrack *t in [self tracks])
        if (t.trackID == trackID)
            return t;
    return nil;
}

- (NSArray<AVAssetTrack *> *)tracksWithMediaType:(AVMediaType)mediaType
{
    NSMutableArray *out = [NSMutableArray array];
    for (AVAssetTrack *t in [self tracks])
        if ([t.mediaType isEqualToString:mediaType])
            [out addObject:t];
    return out;
}

- (NSArray<AVAssetTrack *> *)tracksWithMediaCharacteristic:(AVMediaCharacteristic)mediaCharacteristic
{
    NSMutableArray *out = [NSMutableArray array];
    for (AVAssetTrack *t in [self tracks])
        if ([t hasMediaCharacteristic:mediaCharacteristic])
            [out addObject:t];
    return out;
}

- (void)cancelLoading {}

- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)outError { return AVKeyValueStatusLoaded; }

- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler
{
    if (handler)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), handler);
}

- (void)loadTrackWithTrackID:(CMPersistentTrackID)trackID completionHandler:(void (^)(AVAssetTrack *, NSError *))handler
{
    [self loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        handler([self trackWithTrackID:trackID], nil);
    }];
}

- (void)loadTracksWithMediaType:(AVMediaType)mediaType completionHandler:(void (^)(NSArray<AVAssetTrack *> *, NSError *))handler
{
    [self loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        NSError *e = nil;
        [self statusOfValueForKey:@"tracks" error:&e];
        handler(e ? nil : [self tracksWithMediaType:mediaType], e);
    }];
}

- (void)loadTracksWithMediaCharacteristic:(AVMediaCharacteristic)c completionHandler:(void (^)(NSArray<AVAssetTrack *> *, NSError *))handler
{
    [self loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        NSError *e = nil;
        [self statusOfValueForKey:@"tracks" error:&e];
        handler(e ? nil : [self tracksWithMediaCharacteristic:c], e);
    }];
}

- (void)loadMetadataForFormat:(AVMetadataFormat)format completionHandler:(void (^)(NSArray<AVMetadataItem *> *, NSError *))handler
{
    [self loadValuesAsynchronouslyForKeys:@[ @"metadata" ] completionHandler:^{
        handler([self metadataForFormat:format], nil);
    }];
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation AVURLAsset {
    NSURL *_URL;
    NSDictionary *_options;
    AVFMovie *_movie;
    NSError *_error;
    NSArray *_tracks, *_metadata;
    NSMutableSet *_loadedKeys;
    BOOL _read;
    dispatch_queue_t _queue;
}

+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options
{
    return [[self alloc] initWithURL:URL options:options];
}

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options
{
    if ((self = [super init])) {
        _URL = [URL copy];
        _options = [options copy];
        _loadedKeys = [NSMutableSet set];
        _queue = dispatch_queue_create("com.apple.avfoundation.asset", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (NSArray<UTType *> *)audiovisualContentTypes
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [self audiovisualTypes]) {
        UTType *u = [UTType typeWithIdentifier:t];
        if (u)
            [out addObject:u];
    }
    return out;
}

+ (NSArray<AVFileType> *)audiovisualTypes
{
    static NSArray *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = AVFAudiovisualTypes();
    });
    return types;
}

+ (NSArray<NSString *> *)audiovisualMIMETypes
{
    static NSArray *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = AVFAudiovisualMIMETypes();
    });
    return types;
}

+ (BOOL)isPlayableExtendedMIMEType:(NSString *)extendedMIMEType
{
    NSString *base = [[extendedMIMEType componentsSeparatedByString:@";"] firstObject];
    base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *t in [self audiovisualMIMETypes])
        if ([t caseInsensitiveCompare:base] == NSOrderedSame)
            return YES;
    return NO;
}

- (NSURL *)URL { return _URL; }
- (AVAssetResourceLoader *)resourceLoader { return nil; }
- (AVAssetCache *)assetCache { return nil; }
- (BOOL)mayRequireContentKeysForMediaDataProcessing { return NO; }

/* Read the file, once. */
- (void)_finchRead
{
    @synchronized(self) {
        if (_read)
            return;
        _read = YES;
        NSError *ioError = nil;
        NSData *data = _URL.isFileURL ? [NSData dataWithContentsOfURL:_URL options:NSDataReadingMappedIfSafe error:&ioError] : nil;
        if (!data) {
            _error = AVFError(AVErrorUnknown, ioError ?: [NSError errorWithDomain:NSOSStatusErrorDomain code:-12935 userInfo:nil]);
            _tracks = @[];
            _metadata = @[];
            return;
        }
        NSError *parseError = nil;
        _movie = [AVFMovie movieWithData:data error:&parseError];
        if (!_movie) {
            _error = AVFError(-11829, parseError);
            _tracks = @[];
            _metadata = @[];
            return;
        }
        NSMutableArray *tracks = [NSMutableArray array];
        for (AVFTrack *t in _movie->tracks)
            [tracks addObject:[[AVAssetTrack alloc] initWithFinchTrack:t movie:_movie asset:self]];
        _tracks = tracks;
        NSMutableArray *items = [NSMutableArray array];
        for (AVFMetadataEntry *e in _movie->userData)
            [items addObject:[AVMetadataItem _finchItemWithEntry:e]];
        for (AVFMetadataEntry *e in _movie->metadata)
            [items addObject:[AVMetadataItem _finchItemWithEntry:e]];
        _metadata = items;
    }
}

- (AVFMovie *)_finchMovie
{
    [self _finchRead];
    return _movie;
}

- (CMTime)duration
{
    AVFMovie *m = [self _finchMovie];
    return m && m->timescale ? CMTimeMake((int64_t)m->duration, (int32_t)m->timescale) : kCMTimeZero;
}

- (NSArray<AVAssetTrack *> *)tracks
{
    [self _finchRead];
    return _tracks;
}

- (float)preferredRate { AVFMovie *m = [self _finchMovie]; return m ? (float)m->rate : 1; }
- (float)preferredVolume { AVFMovie *m = [self _finchMovie]; return m ? m->volume : 1; }
- (CGAffineTransform)preferredTransform { AVFMovie *m = [self _finchMovie]; return m ? m->matrix : CGAffineTransformIdentity; }

- (CGSize)naturalSize
{
    for (AVAssetTrack *t in [self tracks])
        if ([t.mediaType isEqualToString:AVMediaTypeVideo])
            return t.naturalSize;
    return CGSizeZero;
}

- (BOOL)providesPreciseDurationAndTiming
{
    return [_options[AVURLAssetPreferPreciseDurationAndTimingKey] boolValue] || [self _finchMovie] != nil;
}

- (BOOL)_finchUsable
{
    [self _finchRead];
    for (AVAssetTrack *t in _tracks)
        if (t.playable)
            return YES;
    return NO;
}

- (BOOL)isPlayable { return [self _finchUsable]; }
- (BOOL)isReadable { return [self _finchUsable]; }
- (BOOL)isExportable { return [self _finchUsable]; }
- (BOOL)isComposable { return [self _finchUsable]; }
- (BOOL)isCompatibleWithAirPlayVideo { return [self _finchUsable]; }
- (BOOL)isCompatibleWithSavedPhotosAlbum { return [self _finchUsable]; }

- (NSArray<AVMetadataItem *> *)metadata
{
    [self _finchRead];
    return _metadata;
}

- (NSArray<AVMetadataFormat> *)availableMetadataFormats
{
    [self _finchRead];
    NSMutableArray *formats = [NSMutableArray array];
    if ([_movie->userData count])
        [formats addObject:AVMetadataFormatQuickTimeUserData];
    for (AVFMetadataEntry *e in _movie->metadata) {
        NSString *f = [e->keySpace isEqualToString:@"mdta"] ? AVMetadataFormatQuickTimeMetadata : AVMetadataFormatiTunesMetadata;
        if (![formats containsObject:f])
            [formats addObject:f];
    }
    return formats;
}

- (NSArray<AVMetadataItem *> *)metadataForFormat:(AVMetadataFormat)format
{
    NSString *space = [format isEqualToString:AVMetadataFormatQuickTimeUserData] ? AVMetadataKeySpaceQuickTimeUserData
                      : [format isEqualToString:AVMetadataFormatQuickTimeMetadata] ? AVMetadataKeySpaceQuickTimeMetadata
                      : [format isEqualToString:AVMetadataFormatiTunesMetadata]    ? AVMetadataKeySpaceiTunes
                                                                                    : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (AVMetadataItem *m in [self metadata])
        if ([m.keySpace isEqualToString:space])
            [out addObject:m];
    return out;
}

- (AVMetadataItem *)creationDate
{
    AVFMovie *m = [self _finchMovie];
    if (!m)
        return nil;
    for (AVMetadataItem *item in [self commonMetadata])
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyCreationDate]) {
            NSDate *d = item.dateValue;
            if (d) {
                AVMutableMetadataItem *c = [item mutableCopy];
                c.value = d;
                return [c copy];
            }
        }
    AVMutableMetadataItem *c = [AVMutableMetadataItem metadataItem];
    c.keySpace = AVMetadataKeySpaceCommon;
    c.key = AVMetadataCommonKeyCreationDate;
    /* (the movie header counts seconds from 1904) */
    c.value = [NSDate dateWithTimeIntervalSince1970:(double)m->creationTime - 2082844800.0];
    return [c copy];
}

#pragma mark Loading

- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)outError
{
    @synchronized(self) {
        if (![_loadedKeys containsObject:key])
            return AVKeyValueStatusUnknown;
    }
    if (_error && [asset_keys() containsObject:key]) {
        if (outError)
            *outError = _error;
        return AVKeyValueStatusFailed;
    }
    return AVKeyValueStatusLoaded;
}

- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler
{
    void (^done)(void) = [handler copy];
    dispatch_async(_queue, ^{
        [self _finchRead];
        @synchronized(self) {
            [self->_loadedKeys addObjectsFromArray:keys];
        }
        if (done)
            done();
    });
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, URL = %@>", NSStringFromClass([self class]), self, _URL];
}

@end

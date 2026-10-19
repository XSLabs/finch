/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Read-only AVMovie views over Finch's QuickTime movie reader. The source movie and
 * track times come from AVFMovie; writing movie headers and mutable movie edits are
 * not exposed here because Finch does not yet have a movie-header writer.
 */
#import "AVFInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AVAssetTrack (AVMovieFinch)
- (AVFTrack *)_finchTrack;
- (instancetype)initWithFinchTrack:(AVFTrack *)track movie:(AVFMovie *)movie asset:(AVAsset *)asset;
@end

@interface AVMovie ()
- (AVFMovie *)_finchMovie;
- (void)_finchSetData:(NSData *)data;
@end

@implementation AVMediaDataStorage {
    NSURL *_finchURL;
}

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *,id> *)options
{
    (void)options;
    if ((self = [super init]))
        _finchURL = [URL copy];
    return self;
}

- (NSURL *)URL { return _finchURL; }

@end

@implementation AVMovie {
    NSURL *_fURL;
    NSData *_fdata;
    AVFMovie *_fparsedMovie;
    NSArray<AVMovieTrack *> *_fmovieTracks;
    NSError *_fmovieError;
}

+ (NSArray<AVFileType> *)movieTypes
{
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *identifier in AVFAudiovisualTypes()) {
        if ([identifier isEqualToString:AVFileTypeQuickTimeMovie] ||
            [identifier isEqualToString:AVFileTypeMPEG4])
            [types addObject:identifier];
    }
    return types;
}

+ (instancetype)movieWithURL:(NSURL *)URL options:(NSDictionary<NSString *,id> *)options
{
    return [[self alloc] initWithURL:URL options:options];
}

+ (instancetype)movieWithURL:(NSURL *)URL options:(NSDictionary<NSString *,id> *)options error:(NSError **)outError
{
    AVMovie *movie = [[self alloc] initWithURL:URL options:options];
    if (!movie && outError)
        *outError = AVFError(AVErrorUnknown, nil);
    return movie;
}

+ (instancetype)movieWithData:(NSData *)data options:(NSDictionary<NSString *,id> *)options
{
    return [[self alloc] initWithData:data options:options];
}

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *,id> *)options
{
    if (!URL.isFileURL)
        return nil;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:&readError];
    self = [super init];
    if (!self)
        return nil;
    _fURL = [URL copy];
    if (!data) {
        _fmovieError = AVFError(AVErrorUnknown, readError);
        _fmovieTracks = @[];
        return self;
    }
    [self _finchSetData:data];
    _fdata = nil;
    return self;
}

- (instancetype)initWithData:(NSData *)data options:(NSDictionary<NSString *,id> *)options
{
    if (!data)
        return nil;
    self = [super init];
    if (!self)
        return nil;
    [self _finchSetData:data];
    return self;
}

- (void)_finchSetData:(NSData *)data
{
    _fdata = [data copy];
    NSError *parseError = nil;
    _fparsedMovie = [AVFMovie movieWithData:_fdata error:&parseError];
    if (!_fparsedMovie) {
        _fmovieError = AVFError(-11829, parseError);
        _fmovieTracks = @[];
        return;
    }
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:_fparsedMovie->tracks.count];
    for (AVFTrack *track in _fparsedMovie->tracks) {
        AVMovieTrack *movieTrack = [[AVMovieTrack alloc] initWithFinchTrack:track movie:_fparsedMovie asset:self];
        [tracks addObject:movieTrack];
    }
    _fmovieTracks = [tracks copy];
}

- (instancetype)init { return [self initWithData:[NSData data] options:nil]; }
- (NSURL *)URL { return _fURL; }
- (NSData *)data { return _fdata; }
- (AVFMovie *)_finchMovie { return _fparsedMovie; }
- (NSArray<AVMovieTrack *> *)tracks { return _fmovieTracks ?: @[]; }
- (AVMovieTrack *)trackWithTrackID:(CMPersistentTrackID)trackID
{
    for (AVMovieTrack *track in self.tracks)
        if (track.trackID == trackID)
            return track;
    return nil;
}
- (void)loadTrackWithTrackID:(CMPersistentTrackID)trackID completionHandler:(void (^)(AVMovieTrack *, NSError *))handler
{
    if (handler)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            handler([self trackWithTrackID:trackID], self->_fmovieError);
        });
}

- (CMTime)duration
{
    return _fparsedMovie && _fparsedMovie->timescale ? CMTimeMake((int64_t)_fparsedMovie->duration, (int32_t)_fparsedMovie->timescale) : kCMTimeZero;
}
- (float)preferredRate { return _fparsedMovie ? (float)_fparsedMovie->rate : 1.0f; }
- (float)preferredVolume { return _fparsedMovie ? _fparsedMovie->volume : 1.0f; }
- (CGAffineTransform)preferredTransform { return _fparsedMovie ? _fparsedMovie->matrix : CGAffineTransformIdentity; }
- (BOOL)providesPreciseDurationAndTiming { return _fparsedMovie != nil; }
- (BOOL)isPlayable { return _fmovieTracks.count > 0; }
- (BOOL)isReadable { return self.isPlayable; }
- (BOOL)isExportable { return self.isPlayable; }
- (BOOL)isComposable { return self.isPlayable; }
- (BOOL)hasProtectedContent { return NO; }
- (BOOL)canContainMovieFragments { return NO; }
- (BOOL)containsMovieFragments { return NO; }
- (AVMediaDataStorage *)defaultMediaDataStorage { return nil; }
- (BOOL)isCompatibleWithFileType:(AVFileType)fileType
{
    return _fparsedMovie != nil && [[AVMovie movieTypes] containsObject:fileType];
}

- (CGSize)naturalSize
{
    for (AVMovieTrack *track in self.tracks)
        if ([track.mediaType isEqualToString:AVMediaTypeVideo])
            return track.naturalSize;
    return CGSizeZero;
}

- (NSArray<AVMetadataItem *> *)metadata
{
    if (!_fparsedMovie)
        return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (AVFMetadataEntry *entry in _fparsedMovie->userData)
        [items addObject:[AVMetadataItem _finchItemWithEntry:entry]];
    for (AVFMetadataEntry *entry in _fparsedMovie->metadata)
        [items addObject:[AVMetadataItem _finchItemWithEntry:entry]];
    return items;
}

- (NSArray<AVMetadataFormat> *)availableMetadataFormats
{
    if (!_fparsedMovie)
        return @[];
    NSMutableArray *formats = [NSMutableArray array];
    if (_fparsedMovie->userData.count)
        [formats addObject:AVMetadataFormatQuickTimeUserData];
    for (AVFMetadataEntry *entry in _fparsedMovie->metadata) {
        NSString *format = [entry->keySpace isEqualToString:@"mdta"] ? AVMetadataFormatQuickTimeMetadata : AVMetadataFormatiTunesMetadata;
        if (![formats containsObject:format])
            [formats addObject:format];
    }
    return formats;
}

- (NSArray<AVMetadataItem *> *)metadataForFormat:(AVMetadataFormat)format
{
    NSString *space = [format isEqualToString:AVMetadataFormatQuickTimeUserData] ? AVMetadataKeySpaceQuickTimeUserData
                      : [format isEqualToString:AVMetadataFormatQuickTimeMetadata] ? AVMetadataKeySpaceQuickTimeMetadata
                      : [format isEqualToString:AVMetadataFormatiTunesMetadata] ? AVMetadataKeySpaceiTunes : nil;
    NSMutableArray *items = [NSMutableArray array];
    for (AVMetadataItem *item in self.metadata)
        if ([item.keySpace isEqualToString:space])
            [items addObject:item];
    return items;
}

- (NSArray<AVMetadataItem *> *)commonMetadata { return AVFCommonMetadata(self.metadata); }
- (AVMetadataItem *)creationDate { return nil; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone { return nil; }

@end

@implementation AVMovieTrack

- (CMTimeRange)mediaDecodeTimeRange
{
    AVFTrack *track = [self _finchTrack];
    if (!track->sampleCount || !track->timescale)
        return kCMTimeRangeInvalid;
    int64_t start = track->samples[0].decodeTime;
    AVFSample last = track->samples[track->sampleCount - 1];
    int64_t end = last.decodeTime + last.duration;
    return CMTimeRangeMake(CMTimeMake(start, (int32_t)track->timescale),
                           CMTimeMake(MAX(0, end - start), (int32_t)track->timescale));
}

- (CMTimeRange)mediaPresentationTimeRange
{
    AVFTrack *track = [self _finchTrack];
    if (!track->sampleCount || !track->timescale)
        return kCMTimeRangeInvalid;
    int64_t start = INT64_MAX, end = INT64_MIN;
    for (size_t i = 0; i < track->sampleCount; i++) {
        AVFSample sample = track->samples[i];
        int64_t presentation = sample.decodeTime + sample.compositionOffset;
        start = MIN(start, presentation);
        end = MAX(end, presentation + sample.duration);
    }
    return CMTimeRangeMake(CMTimeMake(start, (int32_t)track->timescale),
                           CMTimeMake(MAX(0, end - start), (int32_t)track->timescale));
}

- (NSInteger)alternateGroupID { return [self _finchTrack]->alternateGroup; }

@end

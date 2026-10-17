// SPDX-License-Identifier: MIT OR Apache-2.0
#import <MediaPlayer/MediaPlayer.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static char MPNowPlayingInfoKey;
static char MPNowPlayingStateKey;
static char MPMediaArtworkBoundsKey;
static char MPMediaArtworkHandlerKey;

@implementation MPMediaEntity

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class],
            [NSNumber class], [NSDate class], [NSData class], [NSURL class], [NSNull class], nil];
        NSDictionary *values = [coder decodeObjectOfClasses:classes forKey:@"properties"];
        if (values) objc_setAssociatedObject(self, &MPNowPlayingInfoKey, values, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSDictionary *values = objc_getAssociatedObject(self, &MPNowPlayingInfoKey);
    [coder encodeObject:values forKey:@"properties"];
}

+ (BOOL)canFilterByProperty:(NSString *)property
{
    (void)property;
    return NO;
}

- (id)valueForProperty:(NSString *)property
{
    if (![property isKindOfClass:[NSString class]]) return nil;
    NSDictionary *values = objc_getAssociatedObject(self, &MPNowPlayingInfoKey);
    return [values objectForKey:property];
}

- (id)objectForKeyedSubscript:(id)key
{
    return [key isKindOfClass:[NSString class]] ? [self valueForProperty:key] : nil;
}

- (void)enumerateValuesForProperties:(NSSet *)properties usingBlock:(void (^)(NSString *, id, BOOL *))block
{
    if (!block) return;
    BOOL stop = NO;
    for (NSString *property in properties) {
        if (stop) break;
        block(property, [self valueForProperty:property], &stop);
    }
}

- (MPMediaEntityPersistentID)persistentID
{
    return [[self valueForProperty:MPMediaEntityPropertyPersistentID] unsignedLongLongValue];
}

@end

@implementation MPNowPlayingInfoCenter

+ (MPNowPlayingInfoCenter *)defaultCenter
{
    static MPNowPlayingInfoCenter *center = nil;
    @synchronized(self) {
        if (!center) center = [[self alloc] init];
    }
    return center;
}

- (NSDictionary *)nowPlayingInfo { return objc_getAssociatedObject(self, &MPNowPlayingInfoKey); }
- (void)setNowPlayingInfo:(NSDictionary *)info
{
    if (info && ![info isKindOfClass:[NSDictionary class]])
        [NSException raise:NSInvalidArgumentException format:@"nowPlayingInfo must be a dictionary or nil"];
    objc_setAssociatedObject(self, &MPNowPlayingInfoKey, [info copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (MPNowPlayingPlaybackState)playbackState
{
    NSNumber *state = objc_getAssociatedObject(self, &MPNowPlayingStateKey);
    return state ? (MPNowPlayingPlaybackState)state.unsignedIntegerValue : MPNowPlayingPlaybackStateUnknown;
}
- (void)setPlaybackState:(MPNowPlayingPlaybackState)state
{
    objc_setAssociatedObject(self, &MPNowPlayingStateKey, [NSNumber numberWithUnsignedInteger:state], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
+ (NSArray<NSString *> *)supportedAnimatedArtworkKeys { return [NSArray array]; }

@end

@implementation MPMediaItem

- (id)valueForProperty:(NSString *)property
{
    return [super valueForProperty:property];
}
- (NSString *)title { return [self valueForProperty:MPMediaItemPropertyTitle]; }
- (NSString *)artist { return [self valueForProperty:MPMediaItemPropertyArtist]; }
- (NSString *)albumTitle { return [self valueForProperty:MPMediaItemPropertyAlbumTitle]; }
- (NSString *)albumArtist { return [self valueForProperty:MPMediaItemPropertyAlbumArtist]; }
- (NSString *)genre { return [self valueForProperty:MPMediaItemPropertyGenre]; }
- (NSString *)composer { return [self valueForProperty:MPMediaItemPropertyComposer]; }
- (NSTimeInterval)playbackDuration { return [[self valueForProperty:MPMediaItemPropertyPlaybackDuration] doubleValue]; }
- (MPMediaEntityPersistentID)persistentID { return [[self valueForProperty:MPMediaItemPropertyPersistentID] unsignedLongLongValue]; }
- (MPMediaType)mediaType { return [[self valueForProperty:MPMediaItemPropertyMediaType] unsignedIntegerValue]; }
- (MPMediaItemArtwork *)artwork { return [self valueForProperty:MPMediaItemPropertyArtwork]; }
- (BOOL)isExplicitItem { return [[self valueForProperty:MPMediaItemPropertyIsExplicit] boolValue]; }
- (BOOL)isCompilation { return [[self valueForProperty:MPMediaItemPropertyIsCompilation] boolValue]; }
- (BOOL)isCloudItem { return [[self valueForProperty:MPMediaItemPropertyIsCloudItem] boolValue]; }
- (BOOL)hasProtectedAsset { return [[self valueForProperty:MPMediaItemPropertyHasProtectedAsset] boolValue]; }
- (NSURL *)assetURL { return [self valueForProperty:MPMediaItemPropertyAssetURL]; }
- (NSString *)lyrics { return [self valueForProperty:MPMediaItemPropertyLyrics]; }
- (NSString *)comments { return [self valueForProperty:MPMediaItemPropertyComments]; }
- (NSDate *)releaseDate { return [self valueForProperty:MPMediaItemPropertyReleaseDate]; }
- (NSDate *)lastPlayedDate { return [self valueForProperty:MPMediaItemPropertyLastPlayedDate]; }
- (NSString *)podcastTitle { return [self valueForProperty:MPMediaItemPropertyPodcastTitle]; }
- (NSString *)userGrouping { return [self valueForProperty:MPMediaItemPropertyUserGrouping]; }
- (NSUInteger)albumTrackNumber { return [[self valueForProperty:MPMediaItemPropertyAlbumTrackNumber] unsignedIntegerValue]; }
- (NSUInteger)albumTrackCount { return [[self valueForProperty:MPMediaItemPropertyAlbumTrackCount] unsignedIntegerValue]; }
- (NSUInteger)discNumber { return [[self valueForProperty:MPMediaItemPropertyDiscNumber] unsignedIntegerValue]; }
- (NSUInteger)discCount { return [[self valueForProperty:MPMediaItemPropertyDiscCount] unsignedIntegerValue]; }
- (NSUInteger)beatsPerMinute { return [[self valueForProperty:MPMediaItemPropertyBeatsPerMinute] unsignedIntegerValue]; }
- (NSUInteger)playCount { return [[self valueForProperty:MPMediaItemPropertyPlayCount] unsignedIntegerValue]; }
- (NSUInteger)skipCount { return [[self valueForProperty:MPMediaItemPropertySkipCount] unsignedIntegerValue]; }
- (NSUInteger)rating { return [[self valueForProperty:MPMediaItemPropertyRating] unsignedIntegerValue]; }
- (NSTimeInterval)bookmarkTime { return [[self valueForProperty:MPMediaItemPropertyBookmarkTime] doubleValue]; }
- (NSDate *)dateAdded { return [self valueForProperty:MPMediaItemPropertyDateAdded]; }
- (NSString *)playbackStoreID { return [self valueForProperty:MPMediaItemPropertyPlaybackStoreID]; }
- (BOOL)isPreorder { return [[self valueForProperty:MPMediaItemPropertyIsPreorder] boolValue]; }
- (MPMediaEntityPersistentID)albumPersistentID { return [[self valueForProperty:MPMediaItemPropertyAlbumPersistentID] unsignedLongLongValue]; }
- (MPMediaEntityPersistentID)artistPersistentID { return [[self valueForProperty:MPMediaItemPropertyArtistPersistentID] unsignedLongLongValue]; }
- (MPMediaEntityPersistentID)albumArtistPersistentID { return [[self valueForProperty:MPMediaItemPropertyAlbumArtistPersistentID] unsignedLongLongValue]; }
- (MPMediaEntityPersistentID)genrePersistentID { return [[self valueForProperty:MPMediaItemPropertyGenrePersistentID] unsignedLongLongValue]; }
- (MPMediaEntityPersistentID)composerPersistentID { return [[self valueForProperty:MPMediaItemPropertyComposerPersistentID] unsignedLongLongValue]; }
- (MPMediaEntityPersistentID)podcastPersistentID { return [[self valueForProperty:MPMediaItemPropertyPodcastPersistentID] unsignedLongLongValue]; }

@end

@implementation MPMediaItemArtwork

- (instancetype)initWithBoundsSize:(CGSize)boundsSize requestHandler:(NSImage *(^)(CGSize))requestHandler
{
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &MPMediaArtworkBoundsKey, [NSValue valueWithSize:NSSizeFromCGSize(boundsSize)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (requestHandler) objc_setAssociatedObject(self, &MPMediaArtworkHandlerKey, [[requestHandler copy] autorelease], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return self;
}

- (CGRect)bounds
{
    NSValue *value = objc_getAssociatedObject(self, &MPMediaArtworkBoundsKey);
    return value ? CGRectMake(0, 0, value.sizeValue.width, value.sizeValue.height) : CGRectZero;
}
- (CGRect)imageCropRect { return self.bounds; }

- (NSImage *)imageWithSize:(CGSize)size
{
    if (size.width <= 0 || size.height <= 0) return nil;
    NSImage *(^handler)(CGSize) = objc_getAssociatedObject(self, &MPMediaArtworkHandlerKey);
    if (!handler) return nil;
    CGSize bounds = self.bounds.size;
    if (bounds.width <= 0 || bounds.height <= 0) return nil;
    CGFloat scale = MIN(1.0, MIN(bounds.width / size.width, bounds.height / size.height));
    NSImage *image = handler(CGSizeMake(size.width * scale, size.height * scale));
    return [image isKindOfClass:[NSImage class]] ? image : nil;
}

@end

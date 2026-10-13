/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * MobileAsset, Finch's: the catalog of downloadable assets (fonts, voices, dictionaries)
 * apps query. Finch has no asset server yet, so catalogs are empty: queries find nothing,
 * catalog downloads finish at once with nothing new, and there are no assets to download.
 */
#import <Foundation/Foundation.h>

/* MAQueryResult and MADownloadResult: success is 0 */
enum { MAQuerySuccessful = 0, MADownloadSuccessful = 0 };

@interface MADownloadOptions : NSObject
@property BOOL discretionary;
@property BOOL allowsCellularAccess;
@property BOOL allowsExpensiveAccess;
@property BOOL doNotBlockBeforeFirstUnlock;
@property BOOL doNotBlockOnNetworkStatus;
@property BOOL requiresPowerPluggedIn;
@property long timeoutIntervalForResource;
@end

@implementation MADownloadOptions
@end

@interface MAAsset : NSObject
@property (copy) NSString *assetType;
@property (copy) NSString *assetId;
@property (copy) NSDictionary *attributes;
@property long state;
@property (copy) NSURL *getLocalUrl;
@end

@implementation MAAsset

+ (void)startCatalogDownload:(NSString *)type options:(MADownloadOptions *)options then:(void (^)(long result))then
{
    if (then)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            then(MADownloadSuccessful);
        });
}

+ (void)startCatalogDownload:(NSString *)type then:(void (^)(long result))then
{
    [self startCatalogDownload:type options:nil then:then];
}

- (long)purgeSync { return 0; }
- (void)purge:(void (^)(long result))then
{
    if (then)
        then(0);
}

- (void)startDownload:(void (^)(long result))then
{
    if (then)
        then(1); /* nothing to download from */
}

- (void)startDownload:(MADownloadOptions *)options then:(void (^)(long result))then { [self startDownload:then]; }
- (void)cancelDownload:(void (^)(long result))then
{
    if (then)
        then(0);
}

- (NSURL *)getLocalFileUrl { return self.getLocalUrl; }
- (BOOL)wasLocal { return NO; }
- (void)refreshState {}
@end

@interface MAAssetQuery : NSObject
@property (copy) NSString *assetType;
@property (strong) NSArray *results;
@end

@implementation MAAssetQuery {
    NSMutableArray *_predicates;
}

- (instancetype)initWithType:(NSString *)type
{
    if ((self = [super init])) {
        _assetType = [type copy];
        _results = @[];
        _predicates = [NSMutableArray new];
    }
    return self;
}

- (instancetype)initWithType:(NSString *)type subpredicates:(NSArray *)predicates
{
    if ((self = [self initWithType:type]))
        [_predicates addObjectsFromArray:predicates ?: @[]];
    return self;
}

- (void)dealloc
{
    [_assetType release];
    [_results release];
    [_predicates release];
    [super dealloc];
}

- (void)returnTypes:(long)types {}
- (void)addKeyValuePair:(NSString *)key with:(NSString *)value {}
- (void)addKeyValueArray:(NSString *)key with:(NSArray *)values {}
- (void)addKeyValueNull:(NSString *)key {}
- (void)setDoNotBlockBeforeFirstUnlock:(BOOL)flag {}

- (long)queryMetaDataSync
{
    self.results = @[];
    return MAQuerySuccessful;
}

- (long)queryMetaDataWithError:(NSError **)error
{
    if (error)
        *error = nil;
    return [self queryMetaDataSync];
}

- (void)queryMetaData:(void (^)(long result))then
{
    long r = [self queryMetaDataSync];
    if (then)
        then(r);
}
@end

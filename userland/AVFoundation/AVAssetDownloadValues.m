/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Download settings and storage policies as real value objects. */
#import <AVFoundation/AVAssetDownloadStorageManager.h>
#import <AVFoundation/AVAssetDownloadTask.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>

static char kFinchPolicyPriority;
static char kFinchPolicyExpirationDate;

@interface AVAssetDownloadStorageManagementPolicy (FinchPolicy)
- (instancetype)initWithFinchPriority:(AVAssetDownloadedAssetEvictionPriority)priority expirationDate:(NSDate *)date;
@end

@interface AVAssetDownloadContentConfiguration (FinchContentConfiguration)
- (instancetype)initWithFinchDefaults;
@end

@interface AVAssetDownloadConfiguration (FinchDownloadConfiguration)
- (instancetype)initWithFinchAsset:(AVURLAsset *)asset title:(NSString *)title;
@end

@implementation AVAssetDownloadStorageManagementPolicy

- (instancetype)initWithFinchPriority:(AVAssetDownloadedAssetEvictionPriority)priority expirationDate:(NSDate *)date
{
    if ((self = [super init])) {
        objc_setAssociatedObject(self, &kFinchPolicyPriority,
            priority ?: AVAssetDownloadedAssetEvictionPriorityDefault, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, &kFinchPolicyExpirationDate,
            date ?: [NSDate distantFuture], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return self;
}

- (AVAssetDownloadedAssetEvictionPriority)priority
{
    return objc_getAssociatedObject(self, &kFinchPolicyPriority) ?: AVAssetDownloadedAssetEvictionPriorityDefault;
}
- (NSDate *)expirationDate
{
    return objc_getAssociatedObject(self, &kFinchPolicyExpirationDate) ?: [NSDate distantFuture];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[AVAssetDownloadStorageManagementPolicy allocWithZone:zone]
        initWithFinchPriority:self.priority expirationDate:self.expirationDate];
}
- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [[AVMutableAssetDownloadStorageManagementPolicy allocWithZone:zone]
        initWithFinchPriority:self.priority expirationDate:self.expirationDate];
}

@end

@implementation AVMutableAssetDownloadStorageManagementPolicy

- (instancetype)init
{
    return [self initWithFinchPriority:AVAssetDownloadedAssetEvictionPriorityDefault
        expirationDate:[NSDate distantFuture]];
}
- (void)setPriority:(AVAssetDownloadedAssetEvictionPriority)value
{
    objc_setAssociatedObject(self, &kFinchPolicyPriority,
        value ?: AVAssetDownloadedAssetEvictionPriorityDefault, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void)setExpirationDate:(NSDate *)value
{
    objc_setAssociatedObject(self, &kFinchPolicyExpirationDate,
        value ?: [NSDate distantFuture], OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@end

@implementation AVAssetDownloadStorageManager {
    NSMutableDictionary *_finchPolicies;
}

+ (AVAssetDownloadStorageManager *)sharedDownloadStorageManager
{
    static AVAssetDownloadStorageManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [self new]; });
    return manager;
}

- (instancetype)init
{
    if ((self = [super init]))
        _finchPolicies = [NSMutableDictionary new];
    return self;
}

- (void)setStorageManagementPolicy:(AVAssetDownloadStorageManagementPolicy *)policy forURL:(NSURL *)URL
{
    if (!URL)
        return;
    NSString *key = URL.absoluteURL.absoluteString;
    @synchronized (self) {
        if (policy)
            _finchPolicies[key] = [policy copy];
        else
            [_finchPolicies removeObjectForKey:key];
    }
}

- (AVAssetDownloadStorageManagementPolicy *)storageManagementPolicyForURL:(NSURL *)URL
{
    if (!URL)
        return nil;
    @synchronized (self) {
        return [_finchPolicies[URL.absoluteURL.absoluteString] copy];
    }
}

@end

@implementation AVAssetDownloadContentConfiguration {
    NSArray<AVAssetVariantQualifier *> *_finchQualifiers;
    NSArray<AVMediaSelection *> *_finchSelections;
}

- (instancetype)initWithFinchDefaults
{
    if ((self = [super init])) {
        _finchQualifiers = @[];
        _finchSelections = @[];
    }
    return self;
}
- (NSArray<AVAssetVariantQualifier *> *)variantQualifiers { return _finchQualifiers; }
- (void)setVariantQualifiers:(NSArray<AVAssetVariantQualifier *> *)value { _finchQualifiers = [value copy] ?: @[]; }
- (NSArray<AVMediaSelection *> *)mediaSelections { return _finchSelections; }
- (void)setMediaSelections:(NSArray<AVMediaSelection *> *)value { _finchSelections = [value copy] ?: @[]; }
- (id)copyWithZone:(NSZone *)zone
{
    AVAssetDownloadContentConfiguration *copy = [[[self class] allocWithZone:zone] initWithFinchDefaults];
    copy.variantQualifiers = self.variantQualifiers;
    copy.mediaSelections = self.mediaSelections;
    return copy;
}

@end

@implementation AVAssetDownloadConfiguration {
    AVURLAsset *_finchAsset;
    NSString *_finchTitle;
    NSData *_finchArtworkData;
    AVAssetDownloadContentConfiguration *_finchPrimary;
    NSArray<AVAssetDownloadContentConfiguration *> *_finchAuxiliary;
    BOOL _finchOptimizesAuxiliary;
    BOOL _finchDownloadsInterstitials;
    NSMutableDictionary *_finchInterstitialCriteria;
}

+ (instancetype)downloadConfigurationWithAsset:(AVURLAsset *)asset title:(NSString *)title
{
    return [[self alloc] initWithFinchAsset:asset title:title];
}

- (instancetype)initWithFinchAsset:(AVURLAsset *)asset title:(NSString *)title
{
    if (!asset || !title)
        return nil;
    if ((self = [super init])) {
        _finchAsset = asset;
        _finchTitle = [title copy];
        _finchPrimary = [[AVAssetDownloadContentConfiguration alloc] initWithFinchDefaults];
        _finchAuxiliary = @[];
        _finchOptimizesAuxiliary = YES;
        _finchInterstitialCriteria = [NSMutableDictionary new];
    }
    return self;
}

- (NSData *)artworkData { return _finchArtworkData; }
- (void)setArtworkData:(NSData *)value
{
    _finchArtworkData = [value copy];
}
- (AVAssetDownloadContentConfiguration *)primaryContentConfiguration { return _finchPrimary; }
- (NSArray<AVAssetDownloadContentConfiguration *> *)auxiliaryContentConfigurations { return _finchAuxiliary; }
- (void)setAuxiliaryContentConfigurations:(NSArray<AVAssetDownloadContentConfiguration *> *)value
{
    _finchAuxiliary = [value copy] ?: @[];
}
- (BOOL)optimizesAuxiliaryContentConfigurations { return _finchOptimizesAuxiliary; }
- (void)setOptimizesAuxiliaryContentConfigurations:(BOOL)value { _finchOptimizesAuxiliary = value; }
- (BOOL)downloadsInterstitialAssets { return _finchDownloadsInterstitials; }
- (void)setDownloadsInterstitialAssets:(BOOL)value { _finchDownloadsInterstitials = value; }
- (void)setInterstitialMediaSelectionCriteria:(NSArray<AVPlayerMediaSelectionCriteria *> *)criteria
                      forMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    if (criteria)
        _finchInterstitialCriteria[characteristic] = [criteria copy];
    else
        [_finchInterstitialCriteria removeObjectForKey:characteristic];
}

@end

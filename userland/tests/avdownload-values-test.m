/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check asset download settings and storage-policy values. */
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVAssetDownloadStorageManager.h>
#import <AVFoundation/AVAssetDownloadTask.h>
#import <Foundation/Foundation.h>

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSURL *url = [NSURL URLWithString:@"https://example.invalid/movie.mov"];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetDownloadConfiguration *configuration = [AVAssetDownloadConfiguration downloadConfigurationWithAsset:asset title:@"Movie"];
        AVAssetDownloadContentConfiguration *primary = configuration.primaryContentConfiguration;
        AVAssetDownloadContentConfiguration *auxiliary = [primary copy];
        auxiliary.variantQualifiers = @[];
        configuration.auxiliaryContentConfigurations = @[auxiliary];
        configuration.optimizesAuxiliaryContentConfigurations = NO;
        configuration.downloadsInterstitialAssets = YES;
        configuration.artworkData = [NSData dataWithBytes:"art" length:3];
        AVMutableAssetDownloadStorageManagementPolicy *policy = [[AVMutableAssetDownloadStorageManagementPolicy alloc] init];
        policy.priority = AVAssetDownloadedAssetEvictionPriorityImportant;
        policy.expirationDate = [NSDate dateWithTimeIntervalSince1970:2000000000];
        AVAssetDownloadStorageManagementPolicy *immutable = [policy copy];
        AVMutableAssetDownloadStorageManagementPolicy *mutable = [immutable mutableCopy];
        puts("AVFoundation download value checks");
        printf("configuration %d %lu %d %d %lu primary %lu/%lu\n", configuration != nil,
            (unsigned long)configuration.auxiliaryContentConfigurations.count,
            configuration.optimizesAuxiliaryContentConfigurations,
            configuration.downloadsInterstitialAssets,
            (unsigned long)configuration.artworkData.length,
            (unsigned long)primary.variantQualifiers.count, (unsigned long)primary.mediaSelections.count);
        printf("policy %s %.0f copy %s %.0f mutable %d\n", policy.priority.UTF8String,
            policy.expirationDate.timeIntervalSince1970, immutable.priority.UTF8String,
            immutable.expirationDate.timeIntervalSince1970, [mutable isKindOfClass:[AVMutableAssetDownloadStorageManagementPolicy class]]);
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Metadata collector configuration and its association with player items. */
#import <AVFoundation/AVFoundation.h>

int
main(void)
{
    @autoreleasepool {
        AVPlayerItemMetadataCollector *collector = [[AVPlayerItemMetadataCollector alloc]
            initWithIdentifiers:@[@"com.apple.quicktime.title"] classifyingLabels:@[@"main"]];
        NSObject *delegate = [NSObject new];
        dispatch_queue_t queue = dispatch_queue_create("finch.test.metadata-collector", DISPATCH_QUEUE_SERIAL);
        [collector setDelegate:(id<AVPlayerItemMetadataCollectorPushDelegate>)delegate queue:queue];
        AVPlayerItem *first = [[AVPlayerItem alloc] initWithAsset:[AVAsset assetWithURL:[NSURL fileURLWithPath:@"/missing.mov"]]];
        AVPlayerItem *second = [[AVPlayerItem alloc] initWithAsset:[AVAsset assetWithURL:[NSURL fileURLWithPath:@"/missing.mov"]]];
        printf("collector %d delegate %d queue %d initial %lu\n", [collector isKindOfClass:[AVPlayerItemMediaDataCollector class]],
               collector.delegate == delegate, collector.delegateQueue != nil, (unsigned long)first.mediaDataCollectors.count);
        [first addMediaDataCollector:collector];
        printf("added %lu same %d\n", (unsigned long)first.mediaDataCollectors.count, first.mediaDataCollectors.firstObject == collector);
        [first removeMediaDataCollector:collector];
        printf("removed %lu\n", (unsigned long)first.mediaDataCollectors.count);
        [second addMediaDataCollector:collector];
        printf("moved %lu first %lu\n", (unsigned long)second.mediaDataCollectors.count, (unsigned long)first.mediaDataCollectors.count);
        (void)queue;
    }
    return 0;
}

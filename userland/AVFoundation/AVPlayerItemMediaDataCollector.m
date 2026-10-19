/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Playback metadata collectors retain their filter settings and delegate. */
#import <AVFoundation/AVFoundation.h>

@implementation AVPlayerItemMediaDataCollector
{
    __weak AVPlayerItem *_fattachedItem;
}

- (AVPlayerItem *)_finchAttachedItem { return _fattachedItem; }
- (void)_finchSetAttachedItem:(AVPlayerItem *)item { _fattachedItem = item; }
@end

@implementation AVPlayerItemMetadataCollector {
    NSArray<NSString *> *_fidentifiers;
    NSArray<NSString *> *_fclassifyingLabels;
    __weak id<AVPlayerItemMetadataCollectorPushDelegate> _fdelegate;
    dispatch_queue_t _fdelegateQueue;
}

- (instancetype)init
{
    return [self initWithIdentifiers:nil classifyingLabels:nil];
}

- (instancetype)initWithIdentifiers:(NSArray<NSString *> *)identifiers classifyingLabels:(NSArray<NSString *> *)labels
{
    if ((self = [super init])) {
        _fidentifiers = [identifiers copy];
        _fclassifyingLabels = [labels copy];
    }
    return self;
}

- (void)setDelegate:(id<AVPlayerItemMetadataCollectorPushDelegate>)delegate queue:(dispatch_queue_t)queue
{
    _fdelegate = delegate;
    _fdelegateQueue = queue;
}

- (id<AVPlayerItemMetadataCollectorPushDelegate>)delegate { return _fdelegate; }
- (dispatch_queue_t)delegateQueue { return _fdelegateQueue; }

@end

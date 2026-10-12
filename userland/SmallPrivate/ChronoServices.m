/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ChronoServices (private): CHSTimelineController asks the widget system to reload an
 * extension's timeline. Finch has no widgets yet, so the requests are accepted and
 * nothing more happens.
 */
#import <Foundation/Foundation.h>

__attribute__((visibility("default")))
@interface CHSTimelineController : NSObject
@property (readonly, copy) NSString *kind;
@end

@implementation CHSTimelineController {
    NSString *_extension;
}

- (instancetype)initWithExtensionBundleIdentifier:(NSString *)extension kind:(NSString *)kind
{
    if ((self = [super init])) {
        _extension = [extension copy];
        _kind = [kind copy];
    }
    return self;
}

- (instancetype)initForAvocadoIdentifier:(NSString *)identifier inBundleIdentifier:(NSString *)bundle
{
    return [self initWithExtensionBundleIdentifier:bundle kind:identifier];
}

- (NSError *)reloadTimeline { return nil; }
- (NSError *)reloadTimelineWithReason:(NSString *)reason { return nil; }

@end

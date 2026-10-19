/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch has one local media route until it gains external route discovery. */
#import <AVFoundation/AVRouteDetector.h>

@implementation AVRouteDetector {
    BOOL _finchRouteDetectionEnabled;
}

- (BOOL)isRouteDetectionEnabled { return _finchRouteDetectionEnabled; }
- (void)setRouteDetectionEnabled:(BOOL)enabled { _finchRouteDetectionEnabled = enabled; }
- (BOOL)multipleRoutesDetected { return NO; }
@end

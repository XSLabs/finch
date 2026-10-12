/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UserManagement (private): UMUserManager, which on shared iPads and the like knows the
 * logged-in persona. A Mac has one user per session and no personas: not multi-user, and
 * no persona to hand out; stakeholders that register to hear of switches never do.
 */
#import <Foundation/Foundation.h>

__attribute__((visibility("default")))
@interface UMUserManager : NSObject
+ (instancetype)sharedManager;
@end

@implementation UMUserManager

+ (instancetype)sharedManager
{
    static UMUserManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[self alloc] init]; });
    return m;
}

- (BOOL)isMultiUser { return NO; }
- (id)currentPersona { return nil; }
- (id)currentUser { return nil; }
- (void)registerUserSwitchStakeHolder:(id)stakeholder {}

@end

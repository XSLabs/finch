/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LocalAuthentication. Finch has no Touch ID and no authentication prompt for apps
 * yet, so no policy can be evaluated: biometric policies fail as on a Mac without
 * biometrics (LAErrorBiometryNotAvailable), and the others as when no prompt can be
 * shown (LAErrorNotInteractive). Apps then take the path they take on such a Mac.
 */
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>

static NSError *
la_error(LAPolicy policy)
{
    BOOL biometric = policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics ||
                     policy == LAPolicyDeviceOwnerAuthenticationWithBiometricsOrWatch ||
                     policy == LAPolicyDeviceOwnerAuthenticationWithWatch;
    NSInteger code = biometric ? LAErrorBiometryNotAvailable : LAErrorNotInteractive;
    NSString *what = biometric ? @"Biometry is not available on this device." : @"Authentication can't be shown here.";
    return [NSError errorWithDomain:LAErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : what}];
}

@implementation LAContext {
    NSString *_fallback, *_cancel, *_reason;
    NSNumber *_maxFailures;
    NSTimeInterval _reuse;
    BOOL _interactionNotAllowed, _invalid;
}

- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error
{
    if (error)
        *error = la_error(policy);
    return NO;
}

- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)localizedReason reply:(void (^)(BOOL, NSError *))reply
{
    NSError *e = _invalid ? [NSError errorWithDomain:LAErrorDomain code:LAErrorAppCancel userInfo:nil] : la_error(policy);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ reply(NO, e); });
}

- (void)evaluateAccessControl:(SecAccessControlRef)accessControl operation:(LAAccessControlOperation)operation
              localizedReason:(NSString *)localizedReason reply:(void (^)(BOOL, NSError *))reply
{
    [self evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:localizedReason reply:reply];
}

- (void)invalidate { _invalid = YES; }
- (BOOL)setCredential:(NSData *)credential type:(LACredentialType)type { return NO; }
- (BOOL)isCredentialSet:(LACredentialType)type { return NO; }
- (NSString *)localizedFallbackTitle { return _fallback; }
- (void)setLocalizedFallbackTitle:(NSString *)t { _fallback = [t copy]; }
- (NSString *)localizedCancelTitle { return _cancel; }
- (void)setLocalizedCancelTitle:(NSString *)t { _cancel = [t copy]; }
- (NSString *)localizedReason { return _reason ?: @""; }
- (void)setLocalizedReason:(NSString *)r { _reason = [r copy]; }
- (NSNumber *)maxBiometryFailures { return _maxFailures; }
- (void)setMaxBiometryFailures:(NSNumber *)n { _maxFailures = n; }
- (NSTimeInterval)touchIDAuthenticationAllowableReuseDuration { return _reuse; }
- (void)setTouchIDAuthenticationAllowableReuseDuration:(NSTimeInterval)d
{
    _reuse = MIN(MAX(d, 0), LATouchIDAuthenticationMaximumAllowableReuseDuration);
}
- (BOOL)interactionNotAllowed { return _interactionNotAllowed; }
- (void)setInteractionNotAllowed:(BOOL)v { _interactionNotAllowed = v; }
- (LABiometryType)biometryType { return LABiometryTypeNone; }
- (NSData *)evaluatedPolicyDomainState { return nil; }
- (LADomainState *)domainState { return nil; }

@end

/* The environment: no biometry, no companion devices; a password for the user. */
@implementation LAEnvironment
+ (LAEnvironment *)currentUser
{
    static LAEnvironment *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[LAEnvironment alloc] _finchInit]; });
    return e;
}
- (instancetype)_finchInit __attribute__((objc_method_family(init)))
{
    return [super init];
}
- (void)addObserver:(id<LAEnvironmentObserver>)observer {}
- (void)removeObserver:(id<LAEnvironmentObserver>)observer {}
- (LAEnvironmentState *)state { return nil; }
@end

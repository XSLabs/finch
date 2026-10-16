/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Minimal Objective-C declarations used by Finch's Swift ABI overlay. */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@protocol ASAuthorizationWebBrowserPlatformPublicKeyCredentialAssertionRequest <NSObject>
@end

@protocol ASAuthorizationWebBrowserPlatformPublicKeyCredentialRegistrationRequest <NSObject>
@end

@protocol ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialAssertionRequest <NSObject>
@end

@protocol ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialRegistrationRequest <NSObject>
@end

@interface ASAuthorizationPlatformPublicKeyCredentialAssertionRequest : NSObject <ASAuthorizationWebBrowserPlatformPublicKeyCredentialAssertionRequest>
@property(nonatomic, copy) NSData *challenge;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest : NSObject <ASAuthorizationWebBrowserPlatformPublicKeyCredentialRegistrationRequest>
@property(nonatomic, copy) NSData *challenge;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialProvider : NSObject
- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier;
- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge NS_SWIFT_NAME(createCredentialAssertionRequest(challenge:));
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID NS_SWIFT_NAME(createCredentialRegistrationRequest(challenge:name:userID:));
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest : NSObject <ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialAssertionRequest>
@property(nonatomic, copy) NSData *challenge;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest : NSObject <ASAuthorizationWebBrowserSecurityKeyPublicKeyCredentialRegistrationRequest>
@property(nonatomic, copy) NSData *challenge;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialProvider : NSObject
- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier;
- (ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge NS_SWIFT_NAME(createCredentialAssertionRequest(challenge:));
- (ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID NS_SWIFT_NAME(createCredentialRegistrationRequest(challenge:displayName:name:userID:));
@end
NS_ASSUME_NONNULL_END

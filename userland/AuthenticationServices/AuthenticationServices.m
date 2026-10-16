/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AuthenticationServices keeps the request and credential value types used by
 * apps. Finch has no Apple ID, passkey broker, or web-authentication service,
 * so requests that need one complete with Apple's public unavailable error.
 */
#import <AuthenticationServices/AuthenticationServices.h>
#import <AuthenticationServices/ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest.h>
#import <AuthenticationServices/ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest.h>
#import <AuthenticationServices/ASAuthorizationWebBrowserPublicKeyCredentialManager.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <Block.h>

NSErrorDomain const ASAuthorizationErrorDomain = @"ASAuthorizationErrorDomain";
NSErrorDomain const ASWebAuthenticationSessionErrorDomain = @"ASWebAuthenticationSessionErrorDomain";
ASAuthorizationScope const ASAuthorizationScopeFullName = @"full_name";
ASAuthorizationScope const ASAuthorizationScopeEmail = @"email";
ASAuthorizationOpenIDOperation const ASAuthorizationOperationImplicit = @"implicit";
ASAuthorizationOpenIDOperation const ASAuthorizationOperationLogin = @"login";
ASAuthorizationOpenIDOperation const ASAuthorizationOperationRefresh = @"refresh";
ASAuthorizationOpenIDOperation const ASAuthorizationOperationLogout = @"logout";
NSNotificationName const ASAuthorizationAppleIDProviderCredentialRevokedNotification = @"ASAuthorizationAppleIDProviderCredentialRevokedNotification";
ASAuthorizationPublicKeyCredentialUserVerificationPreference const ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred = @"preferred";
ASAuthorizationPublicKeyCredentialUserVerificationPreference const ASAuthorizationPublicKeyCredentialUserVerificationPreferenceRequired = @"required";
ASAuthorizationPublicKeyCredentialUserVerificationPreference const ASAuthorizationPublicKeyCredentialUserVerificationPreferenceDiscouraged = @"discouraged";
ASAuthorizationPublicKeyCredentialAttestationKind const ASAuthorizationPublicKeyCredentialAttestationKindNone = @"none";
ASAuthorizationPublicKeyCredentialAttestationKind const ASAuthorizationPublicKeyCredentialAttestationKindDirect = @"direct";
ASAuthorizationPublicKeyCredentialAttestationKind const ASAuthorizationPublicKeyCredentialAttestationKindIndirect = @"indirect";
ASAuthorizationPublicKeyCredentialAttestationKind const ASAuthorizationPublicKeyCredentialAttestationKindEnterprise = @"enterprise";
ASAuthorizationPublicKeyCredentialResidentKeyPreference const ASAuthorizationPublicKeyCredentialResidentKeyPreferenceDiscouraged = @"discouraged";
ASAuthorizationPublicKeyCredentialResidentKeyPreference const ASAuthorizationPublicKeyCredentialResidentKeyPreferencePreferred = @"preferred";
ASAuthorizationPublicKeyCredentialResidentKeyPreference const ASAuthorizationPublicKeyCredentialResidentKeyPreferenceRequired = @"required";
ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportUSB = @"usb";
ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportNFC = @"nfc";
ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportBluetooth = @"ble";

static const void *ASStateKey = &ASStateKey;

@interface ASFinchState : NSObject {
    NSMutableDictionary *_values;
}
@end

@implementation ASFinchState
- (instancetype)init
{
    if ((self = [super init]))
        _values = [[NSMutableDictionary alloc] init];
    return self;
}
- (void)dealloc
{
    [_values release];
    [super dealloc];
}
- (id)valueForKey:(NSString *)key { return [_values objectForKey:key]; }
- (void)setValue:(id)value forKey:(NSString *)key
{
    if (value)
        [_values setObject:value forKey:key];
    else
        [_values removeObjectForKey:key];
}
- (NSDictionary *)allValues { return _values; }
@end

static ASFinchState *
ASStateFor(id object, BOOL create)
{
    ASFinchState *state = objc_getAssociatedObject(object, ASStateKey);
    if (!state && create) {
        @synchronized (object) {
            state = objc_getAssociatedObject(object, ASStateKey);
            if (!state) {
                state = [[[ASFinchState alloc] init] autorelease];
                objc_setAssociatedObject(object, ASStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    return state;
}

static id ASGet(id object, NSString *key) { return [[[ASStateFor(object, NO) valueForKey:key] retain] autorelease]; }
static void ASSet(id object, NSString *key, id value) { [ASStateFor(object, YES) setValue:value forKey:key]; }
static void ASSetNonretained(id object, NSString *key, id value)
{
    ASSet(object, key, value ? [NSValue valueWithNonretainedObject:value] : nil);
}
static id ASGetNonretained(id object, NSString *key)
{
    return [ASGet(object, key) nonretainedObjectValue];
}
static void ASSetCopy(id object, NSString *key, id value)
{
    id copy = [value copy];
    ASSet(object, key, copy);
    [copy release];
}
static BOOL ASGetBool(id object, NSString *key) { return [ASGet(object, key) boolValue]; }
static void ASSetBool(id object, NSString *key, BOOL value) { ASSet(object, key, [NSNumber numberWithBool:value]); }
static id ASInitObject(Class cls)
{
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    return ((id (*)(id, SEL))objc_msgSend)(allocated, @selector(init));
}

static NSError *
ASError(NSErrorDomain domain, NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:domain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"The requested service is not available on this computer."}];
}

static NSError *
ASUnavailableError(void)
{
    return ASError(ASAuthorizationErrorDomain, ASAuthorizationErrorNotHandled,
                   @"This computer does not provide Apple account or passkey authorization.");
}

@implementation ASPublicKeyCredentialClientData
- (instancetype)initWithChallenge:(NSData *)challenge origin:(NSString *)origin
{
    if ((self = [super init])) {
        ASSetCopy(self, @"challenge", challenge);
        ASSetCopy(self, @"origin", origin);
        ASSet(self, @"crossOrigin", @(ASPublicKeyCredentialClientDataCrossOriginValueNotSet));
    }
    return self;
}
- (NSData *)challenge { return ASGet(self, @"challenge"); }
- (void)setChallenge:(NSData *)value { ASSetCopy(self, @"challenge", value); }
- (NSString *)origin { return ASGet(self, @"origin"); }
- (void)setOrigin:(NSString *)value { ASSetCopy(self, @"origin", value); }
- (NSString *)topOrigin { return ASGet(self, @"topOrigin"); }
- (void)setTopOrigin:(NSString *)value { ASSetCopy(self, @"topOrigin", value); }
- (ASPublicKeyCredentialClientDataCrossOriginValue)crossOrigin
{
    return [ASGet(self, @"crossOrigin") integerValue];
}
- (void)setCrossOrigin:(ASPublicKeyCredentialClientDataCrossOriginValue)value
{
    ASSet(self, @"crossOrigin", @(value));
}
@end

@interface ASAuthorizationRequest (Finch)
- (instancetype)_finchInitWithProvider:(id<ASAuthorizationProvider>)provider;
@end
@interface ASAuthorizationPlatformPublicKeyCredentialAssertionRequest (Finch)
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge relyingParty:(NSString *)relyingParty;
@end
@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest (Finch)
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID relyingParty:(NSString *)relyingParty;
@end
@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest (Finch)
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge relyingParty:(NSString *)relyingParty;
@end
@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest (Finch)
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID relyingParty:(NSString *)relyingParty;
@end
@interface ASWebAuthenticationSessionRequest (Finch)
- (instancetype)_finchInitWithURL:(NSURL *)url callback:(ASWebAuthenticationSessionCallback *)callback
                callbackURLScheme:(NSString *)scheme ephemeral:(BOOL)ephemeral
             additionalHeaderFields:(NSDictionary *)headers;
@end

/* Requests are immutable to callers except for the properties Apple makes mutable. */
@implementation ASAuthorizationRequest
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)_finchInitWithProvider:(id<ASAuthorizationProvider>)provider
{
    if ((self = [super init]))
        ASSet(self, @"provider", provider);
    return self;
}
- (id<ASAuthorizationProvider>)provider { return ASGet(self, @"provider"); }
- (id)copyWithZone:(NSZone *)zone
{
    id copy = ASInitObject([self class]);
    ASFinchState *source = ASStateFor(self, NO);
    if (source)
        for (NSString *key in [source allValues])
            ASSet(copy, key, [source valueForKey:key]);
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    ASFinchState *state = ASStateFor(self, NO);
    [coder encodeObject:state ? [state allValues] : @{} forKey:@"FinchRequestValues"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        NSDictionary *values = [coder decodeObjectOfClass:[NSDictionary class] forKey:@"FinchRequestValues"];
        for (NSString *key in values)
            ASSet(self, key, [values objectForKey:key]);
    }
    return self;
}
@end

@implementation ASAuthorizationOpenIDRequest
- (NSArray *)requestedScopes { return ASGet(self, @"requestedScopes"); }
- (void)setRequestedScopes:(NSArray *)value { ASSetCopy(self, @"requestedScopes", value); }
- (NSString *)state { return ASGet(self, @"state"); }
- (void)setState:(NSString *)value { ASSetCopy(self, @"state", value); }
- (NSString *)nonce { return ASGet(self, @"nonce"); }
- (void)setNonce:(NSString *)value { ASSetCopy(self, @"nonce", value); }
- (ASAuthorizationOpenIDOperation)requestedOperation { return ASGet(self, @"requestedOperation") ?: ASAuthorizationOperationImplicit; }
- (void)setRequestedOperation:(ASAuthorizationOpenIDOperation)value { ASSetCopy(self, @"requestedOperation", value); }
@end

@implementation ASAuthorizationAppleIDRequest
- (NSString *)user { return ASGet(self, @"user"); }
- (void)setUser:(NSString *)value { ASSetCopy(self, @"user", value); }
@end

@implementation ASAuthorizationAppleIDProvider
- (ASAuthorizationAppleIDRequest *)createRequest
{
    ASAuthorizationAppleIDRequest *request = [[ASAuthorizationAppleIDRequest alloc] _finchInitWithProvider:self];
    return [request autorelease];
}
- (void)getCredentialStateForUserID:(NSString *)userID completion:(void (^)(ASAuthorizationAppleIDProviderCredentialState, NSError *))completion
{
    if (!completion)
        return;
    void (^handler)(ASAuthorizationAppleIDProviderCredentialState, NSError *) = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(ASAuthorizationAppleIDProviderCredentialNotFound, ASUnavailableError());
        [handler release];
    });
}
@end

@implementation ASAuthorizationPasswordRequest
@end

@implementation ASAuthorizationPasswordProvider
- (ASAuthorizationPasswordRequest *)createRequest
{
    return [[[ASAuthorizationPasswordRequest alloc] _finchInitWithProvider:self] autorelease];
}
@end

@implementation ASPasswordCredential
+ (instancetype)credentialWithUser:(NSString *)user password:(NSString *)password
{
    return [[[self alloc] initWithUser:user password:password] autorelease];
}
- (instancetype)initWithUser:(NSString *)user password:(NSString *)password
{
    if ((self = [super init])) {
        ASSetCopy(self, @"user", user);
        ASSetCopy(self, @"password", password);
    }
    return self;
}
- (NSString *)user { return ASGet(self, @"user"); }
- (NSString *)password { return ASGet(self, @"password"); }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithUser:self.user password:self.password]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.user forKey:@"user"];
    [coder encodeObject:self.password forKey:@"password"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithUser:[coder decodeObjectOfClass:[NSString class] forKey:@"user"]
                     password:[coder decodeObjectOfClass:[NSString class] forKey:@"password"]];
}
@end

@implementation ASAuthorizationPlatformPublicKeyCredentialProvider
- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier
{
    if ((self = [super init]))
        ASSetCopy(self, @"relyingPartyIdentifier", relyingPartyIdentifier);
    return self;
}
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge
{
    return [[[ASAuthorizationPlatformPublicKeyCredentialAssertionRequest alloc] _finchInitWithProvider:self challenge:challenge relyingParty:self.relyingPartyIdentifier] autorelease];
}
- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData
{
    ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *request = [self createCredentialAssertionRequestWithChallenge:clientData.challenge];
    ASSet(request, @"clientDataObject", clientData);
    return request;
}
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID
{
    return [[[ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest alloc] _finchInitWithProvider:self challenge:challenge name:name userID:userID relyingParty:self.relyingPartyIdentifier] autorelease];
}
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData name:(NSString *)name userID:(NSData *)userID
{
    ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *request = [self createCredentialRegistrationRequestWithChallenge:clientData.challenge name:name userID:userID];
    ASSet(request, @"clientDataObject", clientData);
    return request;
}
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData name:(NSString *)name userID:(NSData *)userID requestStyle:(ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle)requestStyle
{
    ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *request = [self createCredentialRegistrationRequestWithClientData:clientData name:name userID:userID];
    request.requestStyle = requestStyle;
    return request;
}
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID requestStyle:(ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle)requestStyle
{
    ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *request =
        [self createCredentialRegistrationRequestWithChallenge:challenge name:name userID:userID];
    request.requestStyle = requestStyle;
    return request;
}
@end

@implementation ASAuthorizationSecurityKeyPublicKeyCredentialProvider
- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier
{
    if ((self = [super init]))
        ASSetCopy(self, @"relyingPartyIdentifier", relyingPartyIdentifier);
    return self;
}
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge
{
    return [[[ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest alloc] _finchInitWithProvider:self challenge:challenge relyingParty:self.relyingPartyIdentifier] autorelease];
}
- (ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData
{
    ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *request = [self createCredentialAssertionRequestWithChallenge:clientData.challenge];
    ASSet(request, @"clientDataObject", clientData);
    return request;
}
- (ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID
{
    return [[[ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest alloc] _finchInitWithProvider:self challenge:challenge displayName:displayName name:name userID:userID relyingParty:self.relyingPartyIdentifier] autorelease];
}
- (ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID
{
    ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *request = [self createCredentialRegistrationRequestWithChallenge:clientData.challenge displayName:displayName name:name userID:userID];
    ASSet(request, @"clientDataObject", clientData);
    return request;
}
@end

@implementation ASAuthorizationPlatformPublicKeyCredentialDescriptor
- (instancetype)initWithCredentialID:(NSData *)credentialID
{
    if ((self = [super init]))
        ASSetCopy(self, @"credentialID", credentialID);
    return self;
}
- (NSData *)credentialID { return ASGet(self, @"credentialID"); }
- (void)setCredentialID:(NSData *)value { ASSetCopy(self, @"credentialID", value); }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithCredentialID:self.credentialID]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.credentialID forKey:@"credentialID"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithCredentialID:[coder decodeObjectOfClass:[NSData class] forKey:@"credentialID"]]; }
@end

@implementation ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor
- (instancetype)initWithCredentialID:(NSData *)credentialID transports:(NSArray *)transports
{
    if ((self = [super init])) {
        ASSetCopy(self, @"credentialID", credentialID);
        ASSetCopy(self, @"transports", transports ?: @[]);
    }
    return self;
}
- (NSData *)credentialID { return ASGet(self, @"credentialID"); }
- (void)setCredentialID:(NSData *)value { ASSetCopy(self, @"credentialID", value); }
- (NSArray *)transports { return ASGet(self, @"transports") ?: @[]; }
- (void)setTransports:(NSArray *)value { ASSetCopy(self, @"transports", value ?: @[]); }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithCredentialID:self.credentialID transports:self.transports]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.credentialID forKey:@"credentialID"];
    [coder encodeObject:self.transports forKey:@"transports"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *credential = [coder decodeObjectOfClass:[NSData class] forKey:@"credentialID"];
    NSArray *transports = [coder decodeObjectOfClass:[NSArray class] forKey:@"transports"];
    return [self initWithCredentialID:credential transports:transports];
}
@end

NSArray *ASAuthorizationAllSupportedPublicKeyCredentialDescriptorTransports(void)
{
    return @[ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportUSB,
             ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportNFC,
             ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportBluetooth];
}

@implementation ASAuthorizationPublicKeyCredentialParameters
- (instancetype)initWithAlgorithm:(ASCOSEAlgorithmIdentifier)algorithm
{
    if ((self = [super init]))
        ASSet(self, @"algorithm", [NSNumber numberWithLong:algorithm]);
    return self;
}
- (ASCOSEAlgorithmIdentifier)algorithm { return [ASGet(self, @"algorithm") longValue]; }
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithAlgorithm:self.algorithm]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInteger:self.algorithm forKey:@"algorithm"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithAlgorithm:(ASCOSEAlgorithmIdentifier)[coder decodeIntegerForKey:@"algorithm"]]; }
@end

@implementation ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge relyingParty:(NSString *)relyingParty
{
    if ((self = [self _finchInitWithProvider:provider])) {
        self.challenge = challenge;
        self.relyingPartyIdentifier = relyingParty;
        self.allowedCredentials = @[];
        self.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred;
    }
    return self;
}
- (NSData *)challenge { return ASGet(self, @"challenge"); }
- (ASPublicKeyCredentialClientData *)clientData { return ASGet(self, @"clientDataObject"); }
- (void)setChallenge:(NSData *)value { ASSetCopy(self, @"challenge", value); }
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (void)setRelyingPartyIdentifier:(NSString *)value { ASSetCopy(self, @"relyingPartyIdentifier", value); }
- (NSArray *)allowedCredentials { return ASGet(self, @"allowedCredentials") ?: @[]; }
- (void)setAllowedCredentials:(NSArray *)value { ASSetCopy(self, @"allowedCredentials", value ?: @[]); }
- (NSString *)userVerificationPreference { return ASGet(self, @"userVerificationPreference") ?: ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred; }
- (void)setUserVerificationPreference:(NSString *)value { ASSetCopy(self, @"userVerificationPreference", value); }
- (ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput *)largeBlob { return ASGet(self, @"largeBlob"); }
- (void)setLargeBlob:(ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput *)value { ASSet(self, @"largeBlob", value); }
- (ASAuthorizationPublicKeyCredentialPRFAssertionInput *)prf { return ASGet(self, @"prf"); }
- (void)setPrf:(ASAuthorizationPublicKeyCredentialPRFAssertionInput *)value { ASSet(self, @"prf", value); }
@end

@implementation ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID relyingParty:(NSString *)relyingParty
{
    if ((self = [self _finchInitWithProvider:provider])) {
        self.challenge = challenge;
        self.name = name;
        self.userID = userID;
        self.relyingPartyIdentifier = relyingParty;
        self.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred;
        self.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKindNone;
    }
    return self;
}
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (ASPublicKeyCredentialClientData *)clientData { return ASGet(self, @"clientDataObject"); }
- (void)setRelyingPartyIdentifier:(NSString *)value { ASSetCopy(self, @"relyingPartyIdentifier", value); }
- (NSData *)challenge { return ASGet(self, @"challenge"); }
- (void)setChallenge:(NSData *)value { ASSetCopy(self, @"challenge", value); }
- (NSData *)userID { return ASGet(self, @"userID"); }
- (void)setUserID:(NSData *)value { ASSetCopy(self, @"userID", value); }
- (NSString *)name { return ASGet(self, @"name"); }
- (void)setName:(NSString *)value { ASSetCopy(self, @"name", value); }
- (NSString *)displayName { return ASGet(self, @"displayName"); }
- (void)setDisplayName:(NSString *)value { ASSetCopy(self, @"displayName", value); }
- (NSString *)userVerificationPreference { return ASGet(self, @"userVerificationPreference") ?: ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred; }
- (void)setUserVerificationPreference:(NSString *)value { ASSetCopy(self, @"userVerificationPreference", value); }
- (NSString *)attestationPreference { return ASGet(self, @"attestationPreference") ?: ASAuthorizationPublicKeyCredentialAttestationKindNone; }
- (void)setAttestationPreference:(NSString *)value { ASSetCopy(self, @"attestationPreference", value); }
- (ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput *)largeBlob { return ASGet(self, @"largeBlob"); }
- (void)setLargeBlob:(ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput *)value { ASSet(self, @"largeBlob", value); }
- (ASAuthorizationPublicKeyCredentialPRFRegistrationInput *)prf { return ASGet(self, @"prf"); }
- (void)setPrf:(ASAuthorizationPublicKeyCredentialPRFRegistrationInput *)value { ASSet(self, @"prf", value); }
- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle)requestStyle { return [ASGet(self, @"requestStyle") integerValue]; }
- (void)setRequestStyle:(ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle)value { ASSet(self, @"requestStyle", [NSNumber numberWithInteger:value]); }
@end

@implementation ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge relyingParty:(NSString *)relyingParty
{
    if ((self = [self _finchInitWithProvider:provider])) {
        self.challenge = challenge;
        self.relyingPartyIdentifier = relyingParty;
        self.allowedCredentials = @[];
        self.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred;
    }
    return self;
}
- (NSData *)challenge { return ASGet(self, @"challenge"); }
- (ASPublicKeyCredentialClientData *)clientData { return ASGet(self, @"clientDataObject"); }
- (void)setChallenge:(NSData *)value { ASSetCopy(self, @"challenge", value); }
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (void)setRelyingPartyIdentifier:(NSString *)value { ASSetCopy(self, @"relyingPartyIdentifier", value); }
- (NSArray *)allowedCredentials { return ASGet(self, @"allowedCredentials") ?: @[]; }
- (void)setAllowedCredentials:(NSArray *)value { ASSetCopy(self, @"allowedCredentials", value ?: @[]); }
- (NSString *)userVerificationPreference { return ASGet(self, @"userVerificationPreference") ?: ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred; }
- (void)setUserVerificationPreference:(NSString *)value { ASSetCopy(self, @"userVerificationPreference", value); }
- (NSString *)appID { return ASGet(self, @"appID"); }
- (void)setAppID:(NSString *)value { ASSetCopy(self, @"appID", value); }
- (ASAuthorizationPublicKeyCredentialPRFAssertionInput *)prf { return ASGet(self, @"prf"); }
- (void)setPrf:(ASAuthorizationPublicKeyCredentialPRFAssertionInput *)value { ASSet(self, @"prf", value); }
@end

@implementation ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest
- (instancetype)_finchInitWithProvider:(id)provider challenge:(NSData *)challenge displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID relyingParty:(NSString *)relyingParty
{
    if ((self = [self _finchInitWithProvider:provider])) {
        self.challenge = challenge;
        self.name = name;
        self.displayName = displayName;
        self.userID = userID;
        self.relyingPartyIdentifier = relyingParty;
        self.credentialParameters = @[];
        self.excludedCredentials = @[];
        self.residentKeyPreference = ASAuthorizationPublicKeyCredentialResidentKeyPreferenceDiscouraged;
        self.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKindNone;
    }
    return self;
}
- (NSString *)relyingPartyIdentifier { return ASGet(self, @"relyingPartyIdentifier"); }
- (ASPublicKeyCredentialClientData *)clientData { return ASGet(self, @"clientDataObject"); }
- (void)setRelyingPartyIdentifier:(NSString *)value { ASSetCopy(self, @"relyingPartyIdentifier", value); }
- (NSData *)challenge { return ASGet(self, @"challenge"); }
- (void)setChallenge:(NSData *)value { ASSetCopy(self, @"challenge", value); }
- (NSData *)userID { return ASGet(self, @"userID"); }
- (void)setUserID:(NSData *)value { ASSetCopy(self, @"userID", value); }
- (NSString *)name { return ASGet(self, @"name"); }
- (void)setName:(NSString *)value { ASSetCopy(self, @"name", value); }
- (NSString *)displayName { return ASGet(self, @"displayName"); }
- (void)setDisplayName:(NSString *)value { ASSetCopy(self, @"displayName", value); }
- (NSString *)attestationPreference { return ASGet(self, @"attestationPreference") ?: ASAuthorizationPublicKeyCredentialAttestationKindNone; }
- (void)setAttestationPreference:(NSString *)value { ASSetCopy(self, @"attestationPreference", value); }
- (NSArray *)credentialParameters { return ASGet(self, @"credentialParameters") ?: @[]; }
- (void)setCredentialParameters:(NSArray *)value { ASSetCopy(self, @"credentialParameters", value ?: @[]); }
- (NSArray *)excludedCredentials { return ASGet(self, @"excludedCredentials") ?: @[]; }
- (void)setExcludedCredentials:(NSArray *)value { ASSetCopy(self, @"excludedCredentials", value ?: @[]); }
- (NSString *)residentKeyPreference { return ASGet(self, @"residentKeyPreference") ?: ASAuthorizationPublicKeyCredentialResidentKeyPreferenceDiscouraged; }
- (void)setResidentKeyPreference:(NSString *)value { ASSetCopy(self, @"residentKeyPreference", value); }
- (ASAuthorizationPublicKeyCredentialPRFRegistrationInput *)prf { return ASGet(self, @"prf"); }
- (void)setPrf:(ASAuthorizationPublicKeyCredentialPRFRegistrationInput *)value { ASSet(self, @"prf", value); }
@end

@implementation ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput
- (instancetype)initWithOperation:(ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperation)operation
{
    if ((self = [super init]))
        ASSet(self, @"operation", [NSNumber numberWithInteger:operation]);
    return self;
}
- (ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperation)operation { return [ASGet(self, @"operation") integerValue]; }
- (NSData *)dataToWrite { return ASGet(self, @"dataToWrite"); }
- (void)setDataToWrite:(NSData *)value { ASSetCopy(self, @"dataToWrite", value); }
@end

@implementation ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput
- (instancetype)initWithSupportRequirement:(ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement)requirement
{
    if ((self = [super init]))
        self.supportRequirement = requirement;
    return self;
}
+ (instancetype)supportPreferred { return [[[self alloc] initWithSupportRequirement:ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirementPreferred] autorelease]; }
+ (instancetype)supportRequired { return [[[self alloc] initWithSupportRequirement:ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirementRequired] autorelease]; }
- (ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement)supportRequirement { return [ASGet(self, @"supportRequirement") integerValue]; }
- (void)setSupportRequirement:(ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement)value { ASSet(self, @"supportRequirement", [NSNumber numberWithInteger:value]); }
@end

@implementation ASAuthorizationPublicKeyCredentialPRFAssertionInputValues
- (instancetype)initWithSaltInput1:(NSData *)saltInput1 saltInput2:(NSData *)saltInput2
{
    if ((self = [super init])) {
        ASSetCopy(self, @"saltInput1", saltInput1);
        ASSetCopy(self, @"saltInput2", saltInput2);
    }
    return self;
}
- (NSData *)saltInput1 { return ASGet(self, @"saltInput1"); }
- (NSData *)saltInput2 { return ASGet(self, @"saltInput2"); }
@end

@implementation ASAuthorizationPublicKeyCredentialPRFAssertionInput
- (instancetype)initWithInputValues:(ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues perCredentialInputValues:(NSDictionary *)perCredentialInputValues
{
    if ((self = [super init])) {
        ASSet(self, @"inputValues", inputValues);
        ASSetCopy(self, @"perCredentialInputValues", perCredentialInputValues);
    }
    return self;
}
- (ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues { return ASGet(self, @"inputValues"); }
- (NSDictionary *)perCredentialInputValues { return ASGet(self, @"perCredentialInputValues"); }
@end

@implementation ASAuthorizationPublicKeyCredentialPRFRegistrationInput
+ (instancetype)checkForSupport { return [[[self alloc] initWithInputValues:nil] autorelease]; }
- (instancetype)initWithInputValues:(ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues
{
    if ((self = [super init])) {
        ASSet(self, @"inputValues", inputValues);
        ASSetBool(self, @"shouldCheckForSupport", inputValues == nil);
    }
    return self;
}
- (BOOL)shouldCheckForSupport { return ASGetBool(self, @"shouldCheckForSupport"); }
- (ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues { return ASGet(self, @"inputValues"); }
@end

@implementation ASAuthorizationAppleIDCredential
@end
@implementation ASAuthorizationPlatformPublicKeyCredentialAssertion
@end
@implementation ASAuthorizationPlatformPublicKeyCredentialRegistration
@end
@implementation ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
@end
@implementation ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
@end
@implementation ASAuthorizationSingleSignOnCredential
@end

@implementation ASAuthorizationSingleSignOnRequest
- (NSArray *)authorizationOptions { return ASGet(self, @"authorizationOptions") ?: @[]; }
- (void)setAuthorizationOptions:(NSArray *)value { ASSetCopy(self, @"authorizationOptions", value ?: @[]); }
- (BOOL)isUserInterfaceEnabled { return ![ASGet(self, @"userInterfaceEnabled") isEqual:@NO]; }
- (void)setUserInterfaceEnabled:(BOOL)value { ASSetBool(self, @"userInterfaceEnabled", value); }
@end

@implementation ASAuthorizationSingleSignOnProvider
+ (instancetype)authorizationProviderWithIdentityProviderURL:(NSURL *)url
{
    ASAuthorizationSingleSignOnProvider *provider = [ASInitObject(self) autorelease];
    ASSet(provider, @"url", url);
    return provider;
}
- (NSURL *)url { return ASGet(self, @"url"); }
- (BOOL)canPerformAuthorization { return NO; }
- (ASAuthorizationSingleSignOnRequest *)createRequest
{
    ASAuthorizationSingleSignOnRequest *request = [[ASAuthorizationSingleSignOnRequest alloc] _finchInitWithProvider:self];
    return [request autorelease];
}
@end

@implementation ASAuthorizationController
- (instancetype)initWithAuthorizationRequests:(NSArray<ASAuthorizationRequest *> *)authorizationRequests
{
    if ((self = [super init]))
        ASSetCopy(self, @"authorizationRequests", authorizationRequests ?: @[]);
    return self;
}
- (NSArray *)authorizationRequests { return ASGet(self, @"authorizationRequests") ?: @[]; }
- (id<ASAuthorizationControllerDelegate>)delegate { return ASGetNonretained(self, @"delegate"); }
- (void)setDelegate:(id<ASAuthorizationControllerDelegate>)delegate { ASSetNonretained(self, @"delegate", delegate); }
- (id<ASAuthorizationControllerPresentationContextProviding>)presentationContextProvider { return ASGetNonretained(self, @"presentationContextProvider"); }
- (void)setPresentationContextProvider:(id<ASAuthorizationControllerPresentationContextProviding>)provider { ASSetNonretained(self, @"presentationContextProvider", provider); }
- (void)performRequests { [self performRequestsWithOptions:0]; }
- (void)performRequestsWithOptions:(ASAuthorizationControllerRequestOptions)options
{
    if (ASGetBool(self, @"finished"))
        return;
    ASSetBool(self, @"finished", YES);
    id delegate = self.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(authorizationController:didCompleteWithError:)])
        return;
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ASGetBool(self, @"cancelled"))
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(authorizationController:didCompleteWithError:), self, ASUnavailableError());
        [self release];
    });
}
- (void)performAutoFillAssistedRequests { [self performRequests]; }
- (void)cancel
{
    ASSetBool(self, @"cancelled", YES);
    id delegate = self.delegate;
    if (delegate && [delegate respondsToSelector:@selector(authorizationController:didCompleteWithError:)]) {
        NSError *error = ASError(ASAuthorizationErrorDomain, ASAuthorizationErrorCanceled, @"The authorization request was canceled.");
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(authorizationController:didCompleteWithError:), self, error);
    }
}
@end

@implementation ASAuthorizationWebBrowserPublicKeyCredentialManager
+ (BOOL)isDeviceConfiguredForPasskeys { return NO; }
- (ASAuthorizationWebBrowserPublicKeyCredentialManagerAuthorizationState)authorizationStateForPlatformCredentials
{
    return ASAuthorizationWebBrowserPublicKeyCredentialManagerAuthorizationStateDenied;
}
- (void)requestAuthorizationForPublicKeyCredentials:(void (^)(ASAuthorizationWebBrowserPublicKeyCredentialManagerAuthorizationState))completionHandler
{
    if (!completionHandler)
        return;
    void (^handler)(ASAuthorizationWebBrowserPublicKeyCredentialManagerAuthorizationState) = [completionHandler copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(ASAuthorizationWebBrowserPublicKeyCredentialManagerAuthorizationStateDenied);
        [handler release];
    });
}
- (void)platformCredentialsForRelyingParty:(NSString *)relyingParty completionHandler:(void (^)(NSArray<ASAuthorizationWebBrowserPlatformPublicKeyCredential *> *))completionHandler
{
    if (!completionHandler)
        return;
    void (^handler)(NSArray *) = [completionHandler copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(@[]);
        [handler release];
    });
}
@end

@interface ASWebAuthenticationSessionRequest (FinchPrivate)
- (void)_setDelegate:(id<ASWebAuthenticationSessionRequestDelegate>)delegate;
@end

@implementation ASWebAuthenticationSessionRequest
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)_finchInitWithURL:(NSURL *)url callback:(ASWebAuthenticationSessionCallback *)callback callbackURLScheme:(NSString *)scheme ephemeral:(BOOL)ephemeral additionalHeaderFields:(NSDictionary *)headers
{
    if ((self = [super init])) {
        ASSet(self, @"UUID", [NSUUID UUID]);
        ASSet(self, @"URL", url);
        ASSet(self, @"callback", callback);
        ASSetCopy(self, @"callbackURLScheme", scheme);
        ASSetBool(self, @"shouldUseEphemeralSession", ephemeral);
        ASSetCopy(self, @"additionalHeaderFields", headers);
    }
    return self;
}
- (NSUUID *)UUID { return ASGet(self, @"UUID"); }
- (NSURL *)URL { return ASGet(self, @"URL"); }
- (NSString *)callbackURLScheme { return ASGet(self, @"callbackURLScheme"); }
- (BOOL)shouldUseEphemeralSession { return ASGetBool(self, @"shouldUseEphemeralSession"); }
- (NSDictionary *)additionalHeaderFields { return ASGet(self, @"additionalHeaderFields"); }
- (ASWebAuthenticationSessionCallback *)callback { return ASGet(self, @"callback"); }
- (id<ASWebAuthenticationSessionRequestDelegate>)delegate { return ASGetNonretained(self, @"delegate"); }
- (void)setDelegate:(id<ASWebAuthenticationSessionRequestDelegate>)delegate { ASSetNonretained(self, @"delegate", delegate); }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.URL forKey:@"url"];
    [coder encodeObject:self.callback forKey:@"callback"];
    [coder encodeObject:self.callbackURLScheme forKey:@"scheme"];
    [coder encodeBool:self.shouldUseEphemeralSession forKey:@"ephemeral"];
    [coder encodeObject:self.additionalHeaderFields forKey:@"headers"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSURL *url = [coder decodeObjectOfClass:[NSURL class] forKey:@"url"];
    ASWebAuthenticationSessionCallback *callback = [coder decodeObjectOfClass:[ASWebAuthenticationSessionCallback class] forKey:@"callback"];
    NSString *scheme = [coder decodeObjectOfClass:[NSString class] forKey:@"scheme"];
    NSDictionary *headers = [coder decodeObjectOfClass:[NSDictionary class] forKey:@"headers"];
    return [self _finchInitWithURL:url callback:callback callbackURLScheme:scheme ephemeral:[coder decodeBoolForKey:@"ephemeral"] additionalHeaderFields:headers];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] _finchInitWithURL:self.URL callback:self.callback callbackURLScheme:self.callbackURLScheme ephemeral:self.shouldUseEphemeralSession additionalHeaderFields:self.additionalHeaderFields];
}
- (void)_setDelegate:(id<ASWebAuthenticationSessionRequestDelegate>)delegate { ASSetNonretained(self, @"delegate", delegate); }
- (void)cancelWithError:(NSError *)error
{
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(authenticationSessionRequest:didCancelWithError:)])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(authenticationSessionRequest:didCancelWithError:), self, error);
}
- (void)completeWithCallbackURL:(NSURL *)url
{
    if (self.callback && ![self.callback matchesURL:url]) {
        [self cancelWithError:ASError(ASWebAuthenticationSessionErrorDomain, ASWebAuthenticationSessionErrorCodeCanceledLogin, @"The callback URL does not match this sign-in request.")];
        return;
    }
    if (!self.callback && self.callbackURLScheme &&
        ![[url.scheme lowercaseString] isEqualToString:[self.callbackURLScheme lowercaseString]]) {
        [self cancelWithError:ASError(ASWebAuthenticationSessionErrorDomain, ASWebAuthenticationSessionErrorCodeCanceledLogin, @"The callback URL scheme does not match this sign-in request.")];
        return;
    }
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(authenticationSessionRequest:didCompleteWithCallbackURL:)])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(authenticationSessionRequest:didCompleteWithCallbackURL:), self, url);
}
@end

@implementation ASWebAuthenticationSessionCallback
+ (instancetype)callbackWithCustomScheme:(NSString *)customScheme
{
    if (![customScheme length])
        return nil;
    ASWebAuthenticationSessionCallback *callback = [ASInitObject(self) autorelease];
    ASSetCopy(callback, @"scheme", customScheme);
    return callback;
}
+ (instancetype)callbackWithHTTPSHost:(NSString *)host path:(NSString *)path
{
    if (![host length])
        return nil;
    ASWebAuthenticationSessionCallback *callback = [ASInitObject(self) autorelease];
    ASSetCopy(callback, @"host", [host lowercaseString]);
    ASSetCopy(callback, @"path", [path length] ? path : @"/");
    return callback;
}
- (BOOL)matchesURL:(NSURL *)url
{
    if (!url)
        return NO;
    NSString *scheme = ASGet(self, @"scheme");
    if (scheme)
        return [[url.scheme lowercaseString] isEqualToString:[scheme lowercaseString]];
    NSString *host = ASGet(self, @"host");
    return [[url.scheme lowercaseString] isEqualToString:@"https"] &&
           [[url.host lowercaseString] isEqualToString:host] &&
           [url.path isEqualToString:ASGet(self, @"path")];
}
@end

@interface ASWebAuthenticationSessionWebBrowserSessionManager (Finch)
@end
@implementation ASWebAuthenticationSessionWebBrowserSessionManager
+ (instancetype)sharedManager
{
    static ASWebAuthenticationSessionWebBrowserSessionManager *manager;
    @synchronized (self) {
        if (!manager)
            manager = [[self alloc] init];
    }
    return manager;
}
- (id<ASWebAuthenticationSessionWebBrowserSessionHandling>)sessionHandler { return ASGet(self, @"sessionHandler"); }
- (void)setSessionHandler:(id<ASWebAuthenticationSessionWebBrowserSessionHandling>)handler { ASSet(self, @"sessionHandler", handler); }
- (BOOL)wasLaunchedByAuthenticationServices { return NO; }
@end

@interface ASWebAuthenticationSession (FinchPrivate)
- (void)_sessionRequest:(ASWebAuthenticationSessionRequest *)request didCompleteWithURL:(NSURL *)url;
- (void)_sessionRequest:(ASWebAuthenticationSessionRequest *)request didCancelWithError:(NSError *)error;
@end

@implementation ASWebAuthenticationSession
- (instancetype)initWithURL:(NSURL *)url callbackURLScheme:(NSString *)callbackURLScheme completionHandler:(ASWebAuthenticationSessionCompletionHandler)completionHandler
{
    if ((self = [super init])) {
        ASWebAuthenticationSessionCompletionHandler copied = [completionHandler copy];
        ASSet(self, @"URL", url);
        ASSetCopy(self, @"callbackURLScheme", callbackURLScheme);
        ASSet(self, @"completionHandler", copied);
        [copied release];
        ASSet(self, @"UUID", [NSUUID UUID]);
    }
    return self;
}
- (instancetype)initWithURL:(NSURL *)url callback:(ASWebAuthenticationSessionCallback *)callback completionHandler:(ASWebAuthenticationSessionCompletionHandler)completionHandler
{
    if ((self = [super init])) {
        ASWebAuthenticationSessionCompletionHandler copied = [completionHandler copy];
        ASSet(self, @"URL", url);
        ASSet(self, @"callback", callback);
        ASSet(self, @"completionHandler", copied);
        [copied release];
        ASSet(self, @"UUID", [NSUUID UUID]);
    }
    return self;
}
- (id<ASWebAuthenticationPresentationContextProviding>)presentationContextProvider { return ASGetNonretained(self, @"presentationContextProvider"); }
- (void)setPresentationContextProvider:(id<ASWebAuthenticationPresentationContextProviding>)provider { ASSetNonretained(self, @"presentationContextProvider", provider); }
- (BOOL)prefersEphemeralWebBrowserSession { return ASGetBool(self, @"ephemeral"); }
- (void)setPrefersEphemeralWebBrowserSession:(BOOL)value { ASSetBool(self, @"ephemeral", value); }
- (NSDictionary *)additionalHeaderFields { return ASGet(self, @"additionalHeaderFields"); }
- (void)setAdditionalHeaderFields:(NSDictionary *)value { ASSetCopy(self, @"additionalHeaderFields", value); }
- (BOOL)canStart { return [ASWebAuthenticationSessionWebBrowserSessionManager.sharedManager sessionHandler] != nil; }
- (BOOL)start
{
    if (ASGetBool(self, @"running") || ASGetBool(self, @"completed"))
        return NO;
    id<ASWebAuthenticationPresentationContextProviding> context = self.presentationContextProvider;
    if (!context) {
        ASSetBool(self, @"completed", YES);
        ASWebAuthenticationSessionCompletionHandler callback = ASGet(self, @"completionHandler");
        NSError *error = ASError(ASWebAuthenticationSessionErrorDomain, ASWebAuthenticationSessionErrorCodePresentationContextNotProvided,
                                 @"A presentation context is required for web authentication.");
        if (callback)
            dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, error); });
        return NO;
    }
    id<ASWebAuthenticationSessionWebBrowserSessionHandling> handler = ASWebAuthenticationSessionWebBrowserSessionManager.sharedManager.sessionHandler;
    if (!handler) {
        ASSetBool(self, @"completed", YES);
        ASWebAuthenticationSessionCompletionHandler callback = ASGet(self, @"completionHandler");
        NSError *error = ASUnavailableError();
        if (callback)
            dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, error); });
        return NO;
    }
    ASWebAuthenticationSessionRequest *request = [[[ASWebAuthenticationSessionRequest alloc] _finchInitWithURL:ASGet(self, @"URL") callback:ASGet(self, @"callback") callbackURLScheme:ASGet(self, @"callbackURLScheme") ephemeral:self.prefersEphemeralWebBrowserSession additionalHeaderFields:self.additionalHeaderFields] autorelease];
    [request _setDelegate:(id<ASWebAuthenticationSessionRequestDelegate>)self];
    ASSet(self, @"request", request);
    ASSetBool(self, @"running", YES);
    [handler beginHandlingWebAuthenticationSessionRequest:request];
    return YES;
}
- (void)cancel
{
    if (!ASGetBool(self, @"running") || ASGetBool(self, @"completed"))
        return;
    ASSetBool(self, @"completed", YES);
    ASSetBool(self, @"running", NO);
    NSError *error = ASError(ASWebAuthenticationSessionErrorDomain, ASWebAuthenticationSessionErrorCodeCanceledLogin, @"The sign-in request was canceled.");
    id handler = ASWebAuthenticationSessionWebBrowserSessionManager.sharedManager.sessionHandler;
    ASWebAuthenticationSessionRequest *request = ASGet(self, @"request");
    if ([handler respondsToSelector:@selector(cancelWebAuthenticationSessionRequest:)])
        [handler cancelWebAuthenticationSessionRequest:request];
    [self _sessionRequest:request didCancelWithError:error];
}
- (void)_sessionRequest:(ASWebAuthenticationSessionRequest *)request didCompleteWithURL:(NSURL *)url
{
    if (ASGetBool(self, @"completed"))
        return;
    ASSetBool(self, @"completed", YES);
    ASSetBool(self, @"running", NO);
    ASWebAuthenticationSessionCompletionHandler callback = ASGet(self, @"completionHandler");
    if (callback)
        callback(url, nil);
}
- (void)_sessionRequest:(ASWebAuthenticationSessionRequest *)request didCancelWithError:(NSError *)error
{
    if (ASGetBool(self, @"completed"))
        return;
    ASSetBool(self, @"completed", YES);
    ASSetBool(self, @"running", NO);
    ASWebAuthenticationSessionCompletionHandler callback = ASGet(self, @"completionHandler");
    if (callback)
        callback(nil, error);
}
- (void)authenticationSessionRequest:(ASWebAuthenticationSessionRequest *)request didCompleteWithCallbackURL:(NSURL *)url
{
    [self _sessionRequest:request didCompleteWithURL:url];
}
- (void)authenticationSessionRequest:(ASWebAuthenticationSessionRequest *)request didCancelWithError:(NSError *)error
{
    [self _sessionRequest:request didCancelWithError:error];
}
@end

@implementation ASAuthorizationWebBrowserPlatformPublicKeyCredential
@end

/*
 * SFIconCache is a private class in Apple's binary, imported by a few apps.
 * This implementation is an in-process object cache; no icon lookup is faked.
 */
@interface SFIconCache : NSObject
+ (instancetype)sharedCache;
- (id)objectForKey:(id)key;
- (void)setObject:(id)object forKey:(id)key;
- (void)removeObjectForKey:(id)key;
- (void)removeAllObjects;
@end
@implementation SFIconCache {
    NSCache *_cache;
}
+ (instancetype)sharedCache
{
    static SFIconCache *cache;
    @synchronized (self) {
        if (!cache)
            cache = [[self alloc] init];
    }
    return cache;
}
- (instancetype)init
{
    if ((self = [super init]))
        _cache = [[NSCache alloc] init];
    return self;
}
- (void)dealloc { [_cache release]; [super dealloc]; }
- (id)objectForKey:(id)key { return [_cache objectForKey:key]; }
- (void)setObject:(id)object forKey:(id)key { if (object && key) [_cache setObject:object forKey:key]; }
- (void)removeObjectForKey:(id)key { if (key) [_cache removeObjectForKey:key]; }
- (void)removeAllObjects { [_cache removeAllObjects]; }
@end

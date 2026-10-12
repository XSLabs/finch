/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SecurityFoundation: SFAuthorization, the Objective-C face of Authorization Services,
 * and SFCertificateData, the certificate-and-trust summary apps show (whether a
 * certificate is a root or a CA, its expiry, the trust policies and a status line),
 * over Finch's Security.
 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <SecurityFoundation/SFAuthorization.h>

/* Private, in Finch's Security as in Apple's */
extern bool SecCertificateIsCA(SecCertificateRef certificate);
extern OSStatus SecCertificateIsSelfSigned(SecCertificateRef certificate, Boolean *isSelfSigned);

#pragma mark - SFAuthorization

@implementation SFAuthorization

+ (BOOL)supportsSecureCoding { return YES; }

+ (id)authorization
{
    return [[[self alloc] init] autorelease];
}

+ (id)authorizationWithFlags:(AuthorizationFlags)flags rights:(const AuthorizationRights *)rights
                 environment:(const AuthorizationEnvironment *)environment
{
    return [[[self alloc] initWithFlags:flags rights:rights environment:environment] autorelease];
}

- (id)initWithFlags:(AuthorizationFlags)flags rights:(const AuthorizationRights *)rights
        environment:(const AuthorizationEnvironment *)environment
{
    if ((self = [super init])) {
        if (AuthorizationCreate(rights, environment, flags, &_authorization) != errAuthorizationSuccess) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (id)init
{
    return [self initWithFlags:kAuthorizationFlagDefaults rights:NULL environment:NULL];
}

- (void)dealloc
{
    if (_authorization)
        AuthorizationFree(_authorization, kAuthorizationFlagDefaults);
    [super dealloc];
}

/* (archived as its external form, which another process on the machine can use) */
- (void)encodeWithCoder:(NSCoder *)coder
{
    AuthorizationExternalForm form;
    if (_authorization && AuthorizationMakeExternalForm(_authorization, &form) == errAuthorizationSuccess)
        [coder encodeBytes:(const uint8_t *)&form length:sizeof form forKey:@"SFAuthorizationExternalForm"];
}

- (id)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        NSUInteger length = 0;
        const uint8_t *bytes = [coder decodeBytesForKey:@"SFAuthorizationExternalForm" returnedLength:&length];
        AuthorizationExternalForm form;
        if (!bytes || length != sizeof form) {
            [self release];
            return nil;
        }
        memcpy(&form, bytes, sizeof form);
        if (AuthorizationCreateFromExternalForm(&form, &_authorization) != errAuthorizationSuccess) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (id)replacementObjectForPortCoder:(NSPortCoder *)coder { return self; }

- (AuthorizationRef)authorizationRef { return _authorization; }

static NSError *
status_error(OSStatus status)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

- (OSStatus)permitWithRights:(const AuthorizationRights *)rights flags:(AuthorizationFlags)flags
                 environment:(const AuthorizationEnvironment *)environment
            authorizedRights:(AuthorizationRights *)authorizedRights
{
    AuthorizationRights *granted = NULL;
    OSStatus status = AuthorizationCopyRights(_authorization, rights, environment, flags, authorizedRights ? &granted : NULL);
    if (authorizedRights && granted) {
        *authorizedRights = *granted;
        /* (the items stay the caller's to read; the container is freed) */
        free(granted);
    }
    return status;
}

- (OSStatus)permitWithRight:(AuthorizationString)rightName flags:(AuthorizationFlags)flags
{
    AuthorizationItem item = {rightName, 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    return [self permitWithRights:&rights flags:flags environment:NULL authorizedRights:NULL];
}

- (BOOL)obtainWithRights:(const AuthorizationRights *)rights flags:(AuthorizationFlags)flags
             environment:(const AuthorizationEnvironment *)environment
        authorizedRights:(AuthorizationRights **)authorizedRights
                   error:(NSError **)error
{
    OSStatus status = AuthorizationCopyRights(_authorization, rights, environment, flags | kAuthorizationFlagExtendRights,
                                              authorizedRights);
    if (status != errAuthorizationSuccess && error)
        *error = status_error(status);
    return status == errAuthorizationSuccess;
}

- (BOOL)obtainWithRight:(AuthorizationString)rightName flags:(AuthorizationFlags)flags error:(NSError **)error
{
    AuthorizationItem item = {rightName, 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    return [self obtainWithRights:&rights flags:flags environment:NULL authorizedRights:NULL error:error];
}

- (void)invalidateCredentials:(BOOL)destroy
{
    if (_authorization)
        AuthorizationFree(_authorization, destroy ? kAuthorizationFlagDestroyRights : kAuthorizationFlagDefaults);
    _authorization = NULL;
    AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, &_authorization);
}

- (void)invalidateCredentials
{
    [self invalidateCredentials:YES];
}

@end

#pragma mark - SFCertificateData

typedef struct {
    uint64_t Length;
    uint8_t *Data;
} FinchCSSMData;

/* The CSSM trust result codes Apple's status lines name */
enum {
    kTPCertExpired = -2147409654,
    kTPCertNotValidYet = -2147409653,
    kTPCertRevoked = -2147409652,
    kTPNotTrusted = -2147409622,
    kAppleTPUnknownCriticalExtension = -2147408892,
    kAppleTPUnknownCertExtension = -2147408891,
};

@interface SFCertificateData : NSObject {
    SecCertificateRef _certificate;
    NSArray *_policies;
    CFDataRef _bytes;
    FinchCSSMData _data;
    BOOL _leaf;
}
@end

@implementation SFCertificateData

static NSInteger log_level;
+ (NSInteger)logLevel { return log_level; }
+ (void)setLogLevel:(NSInteger)level { log_level = level; }

+ (BOOL)isRoot:(SecCertificateRef)certificate
{
    Boolean self_signed = false;
    return certificate && SecCertificateIsSelfSigned(certificate, &self_signed) == errSecSuccess && self_signed;
}

+ (BOOL)isCA:(SecCertificateRef)certificate
{
    return certificate && SecCertificateIsCA(certificate);
}

/* The policies a certificate is shown against, as Apple's lists them. */
+ (NSArray *)trustPolicies
{
    NSMutableArray *policies = [NSMutableArray array];
    CFStringRef oids[] = {kSecPolicyAppleX509Basic, kSecPolicyAppleSSL, kSecPolicyAppleSMIME, kSecPolicyAppleEAP,
                          kSecPolicyAppleIPsec, kSecPolicyAppleCodeSigning, kSecPolicyAppleTimeStamping};
    for (size_t i = 0; i < sizeof oids / sizeof *oids; i++) {
        SecPolicyRef p = SecPolicyCreateWithProperties(oids[i], NULL);
        if (p) {
            [policies addObject:(id)p];
            CFRelease(p);
        }
    }
    return policies;
}

+ (OSStatus)createTrustWithCertificates:(NSArray *)certificates policy:(void *)policy trust:(SecTrustRef *)trust
{
    return SecTrustCreateWithCertificates((CFArrayRef)certificates, policy, trust);
}

+ (NSArray *)policyValuesForTrust:(SecTrustRef)trust
{
    CFArrayRef policies = NULL;
    if (!trust || SecTrustCopyPolicies(trust, &policies) != errSecSuccess || !policies)
        return @[];
    NSMutableArray *values = [NSMutableArray array];
    for (id p in (NSArray *)policies) {
        CFDictionaryRef props = SecPolicyCopyProperties((SecPolicyRef)p);
        if (props) {
            [values addObject:(id)props];
            CFRelease(props);
        }
    }
    CFRelease(policies);
    return values;
}

+ (BOOL)isRevocationStatusCode:(OSStatus)code { return code == kTPCertRevoked; }
+ (BOOL)isCRLStatusCode:(OSStatus)code { return NO; }
+ (BOOL)isOCSPStatusCode:(OSStatus)code { return NO; }
+ (BOOL)isPolicySpecificStatusCode:(OSStatus)code { return NO; }
+ (SecTrustSettingsDomain)trustDomainForKeychain:(SecKeychainRef)keychain { return kSecTrustSettingsDomainUser; }

/* As Apple's: a line for each trust result it names, and the code itself otherwise. */
+ (NSString *)statusStringForCode:(OSStatus)code domain:(SecTrustSettingsDomain)domain
{
    switch (code) {
    case errSecSuccess: return @"This certificate is valid";
    case kTPCertExpired: return @"This certificate has expired";
    case kTPCertNotValidYet: return @"This certificate is not yet valid";
    case kTPCertRevoked: return @"This certificate has been revoked";
    case kTPNotTrusted: return @"This certificate was signed by an unknown authority";
    case kAppleTPUnknownCriticalExtension:
    case kAppleTPUnknownCertExtension: return @"This certificate is not valid (nonconforming extension)";
    }
    NSString *n = [NSNumberFormatter localizedStringFromNumber:@(code) numberStyle:NSNumberFormatterDecimalStyle];
    return [NSString stringWithFormat:@"This certificate is not valid (%@)", n];
}

- (id)init
{
    return [self initWithCertificate:NULL];
}

- (id)initWithCertificate:(SecCertificateRef)certificate
{
    if ((self = [super init])) {
        _leaf = YES;
        [self setCertificate:certificate];
    }
    return self;
}

- (id)initWithTrust:(SecTrustRef)trust
{
    CFArrayRef chain = trust ? SecTrustCopyCertificateChain(trust) : NULL;
    SecCertificateRef leaf = chain && CFArrayGetCount(chain) ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0) : NULL;
    self = [self initWithCertificate:leaf];
    if (chain)
        CFRelease(chain);
    return self;
}

- (id)initWithData:(const FinchCSSMData *)data
{
    SecCertificateRef c = NULL;
    if (data && data->Data) {
        CFDataRef d = CFDataCreate(kCFAllocatorDefault, data->Data, (CFIndex)data->Length);
        c = SecCertificateCreateWithData(kCFAllocatorDefault, d);
        CFRelease(d);
    }
    self = [self initWithCertificate:c];
    if (c)
        CFRelease(c);
    return self;
}

- (void)dealloc
{
    if (_certificate)
        CFRelease(_certificate);
    if (_bytes)
        CFRelease(_bytes);
    [_policies release];
    [super dealloc];
}

- (SecCertificateRef)certificate { return _certificate; }

- (void)setCertificate:(SecCertificateRef)certificate
{
    if (certificate)
        CFRetain(certificate);
    if (_certificate)
        CFRelease(_certificate);
    _certificate = certificate;
    if (_bytes)
        CFRelease(_bytes);
    _bytes = certificate ? SecCertificateCopyData(certificate) : NULL;
    _data.Length = _bytes ? (uint64_t)CFDataGetLength(_bytes) : 0;
    _data.Data = _bytes ? (uint8_t *)CFDataGetBytePtr(_bytes) : NULL;
}

- (const FinchCSSMData *)data { return &_data; }
- (const FinchCSSMData *)certData { return &_data; }
- (void)setData:(const FinchCSSMData *)data
{
    SecCertificateRef c = NULL;
    if (data && data->Data) {
        CFDataRef d = CFDataCreate(kCFAllocatorDefault, data->Data, (CFIndex)data->Length);
        c = SecCertificateCreateWithData(kCFAllocatorDefault, d);
        CFRelease(d);
    }
    [self setCertificate:c];
    if (c)
        CFRelease(c);
}

- (void)setLeaf:(BOOL)leaf { _leaf = leaf; }
- (NSUInteger)certIssuerIndex { return 0; }
- (SecKeychainRef)keychain { return NULL; }
/* (Finch's certificates aren't parsed into CSSM structures) */
- (void *)subject { return NULL; }
- (void)parseKeyHeader:(const void *)header {}
- (void)saveTrustValues {}
- (NSString *)labelAtIndex:(NSUInteger)index { return @""; }

- (NSArray *)policies
{
    return _policies ?: [[self class] trustPolicies];
}

- (void)setPolicies:(NSArray *)policies
{
    [_policies autorelease];
    _policies = [policies copy];
}

- (NSDate *)expirationDate
{
    return _certificate ? [(id)SecCertificateCopyNotValidAfterDate(_certificate) autorelease] : nil;
}

- (BOOL)expired
{
    NSDate *d = [self expirationDate];
    return d && [d timeIntervalSinceNow] < 0;
}

/* The certificate checked as a basic X.509 one, its result as a status line. */
- (NSString *)statusString
{
    if (!_certificate)
        return nil;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    OSStatus code = SecTrustCreateWithCertificates(_certificate, policy, &trust);
    CFRelease(policy);
    CFArrayRef anchors = NULL;
    if (code == errSecSuccess && SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess && anchors) {
        /* (against the system's anchors, as Apple's is) */
        SecTrustSetAnchorCertificates(trust, anchors);
        CFRelease(anchors);
    }
    if (code == errSecSuccess) {
        CFErrorRef error = NULL;
        if (!SecTrustEvaluateWithError(trust, &error)) {
            OSStatus e = error ? (OSStatus)CFErrorGetCode(error) : errSecNotTrusted;
            code = e == errSecCertificateExpired      ? kTPCertExpired
                 : e == errSecCertificateNotValidYet  ? kTPCertNotValidYet
                 : e == errSecCertificateRevoked      ? kTPCertRevoked
                 : e == errSecCreateChainFailed || e == errSecNotTrusted ? kTPNotTrusted
                                                                          : e;
        }
        if (error)
            CFRelease(error);
    }
    if (trust)
        CFRelease(trust);
    return [[self class] statusStringForCode:code domain:kSecTrustSettingsDomainUser];
}

- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[SFCertificateData class]])
        return NO;
    SecCertificateRef o = [other certificate];
    return o == _certificate || (o && _certificate && CFEqual(o, _certificate));
}

- (NSUInteger)hash
{
    return _certificate ? CFHash(_certificate) : 0;
}

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The URL loading system's authentication (Apple's are in CFNetwork; Finch's URL loading is
 * in Foundation): credentials, protection spaces, challenges and the credential storage.
 *
 * The storage keeps credentials in memory, for the process: a permanent credential lasts as
 * long as a session one (Apple's go to the keychain). A credential with no persistence isn't
 * stored. Sessions ask it for a protection space's default credential when a server asks
 * for a password (NSURLSession.m).
 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>

NSString *const NSURLProtectionSpaceHTTP = @"http";
NSString *const NSURLProtectionSpaceHTTPS = @"https";
NSString *const NSURLProtectionSpaceFTP = @"ftp";
NSString *const NSURLProtectionSpaceHTTPProxy = @"http";
NSString *const NSURLProtectionSpaceHTTPSProxy = @"https";
NSString *const NSURLProtectionSpaceFTPProxy = @"ftp";
NSString *const NSURLProtectionSpaceSOCKSProxy = @"SOCKS";
NSString *const NSURLAuthenticationMethodDefault = @"NSURLAuthenticationMethodDefault";
NSString *const NSURLAuthenticationMethodHTTPBasic = @"NSURLAuthenticationMethodHTTPBasic";
NSString *const NSURLAuthenticationMethodHTTPDigest = @"NSURLAuthenticationMethodHTTPDigest";
NSString *const NSURLAuthenticationMethodHTMLForm = @"NSURLAuthenticationMethodHTMLForm";
NSString *const NSURLAuthenticationMethodNTLM = @"NSURLAuthenticationMethodNTLM";
NSString *const NSURLAuthenticationMethodNegotiate = @"NSURLAuthenticationMethodNegotiate";
NSString *const NSURLAuthenticationMethodClientCertificate = @"NSURLAuthenticationMethodClientCertificate";
NSString *const NSURLAuthenticationMethodServerTrust = @"NSURLAuthenticationMethodServerTrust";
NSString *const NSURLCredentialStorageChangedNotification = @"NSURLCredentialStorageChangedNotification";
NSString *const NSURLCredentialStorageRemoveSynchronizableCredentials = @"NSURLCredentialStorageRemoveSynchronizableCredentials";

static BOOL
same(id a, id b)
{
    return a == b || [a isEqual:b];
}

#pragma mark - NSURLCredential

@implementation NSURLCredential {
    NSString *_user, *_password;
    NSURLCredentialPersistence _persistence;
    SecIdentityRef _identity;
    NSArray *_certificates;
    SecTrustRef _trust;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithUser:(NSString *)user password:(NSString *)password persistence:(NSURLCredentialPersistence)persistence
{
    if ((self = [super init])) {
        _user = [user copy];
        _password = [password copy];
        _persistence = persistence;
    }
    return self;
}

+ (NSURLCredential *)credentialWithUser:(NSString *)user password:(NSString *)password persistence:(NSURLCredentialPersistence)persistence
{
    return [[[self alloc] initWithUser:user password:password persistence:persistence] autorelease];
}

- (instancetype)initWithIdentity:(SecIdentityRef)identity certificates:(NSArray *)certArray persistence:(NSURLCredentialPersistence)persistence
{
    if ((self = [super init])) {
        _identity = identity ? (SecIdentityRef)CFRetain(identity) : NULL;
        _certificates = [certArray copy];
        _persistence = persistence;
    }
    return self;
}

+ (NSURLCredential *)credentialWithIdentity:(SecIdentityRef)identity certificates:(NSArray *)certArray persistence:(NSURLCredentialPersistence)persistence
{
    return [[[self alloc] initWithIdentity:identity certificates:certArray persistence:persistence] autorelease];
}

- (instancetype)initWithTrust:(SecTrustRef)trust
{
    if ((self = [super init])) {
        _trust = trust ? (SecTrustRef)CFRetain(trust) : NULL;
        _persistence = NSURLCredentialPersistenceForSession;
    }
    return self;
}

+ (NSURLCredential *)credentialForTrust:(SecTrustRef)trust { return [[[self alloc] initWithTrust:trust] autorelease]; }

- (void)dealloc
{
    [_user release];
    [_password release];
    [_certificates release];
    if (_identity)
        CFRelease(_identity);
    if (_trust)
        CFRelease(_trust);
    [super dealloc];
}

- (NSString *)user { return _user; }
- (NSString *)password { return _password; }
- (BOOL)hasPassword { return _password != nil; }
- (NSURLCredentialPersistence)persistence { return _persistence; }
- (SecIdentityRef)identity { return _identity; }
- (NSArray *)certificates { return _certificates ?: @[]; }
- (SecTrustRef)_finchTrust { return _trust; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSURLCredential class]])
        return NO;
    NSURLCredential *o = other;
    return same(_user, o->_user) && same(_password, o->_password) && _identity == o->_identity && _trust == o->_trust;
}

- (NSUInteger)hash { return [_user hash] ^ (NSUInteger)_identity ^ (NSUInteger)_trust; }

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p>: %@", [self class], self, _user]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_user forKey:@"user"];
    [coder encodeObject:_password forKey:@"password"];
    [coder encodeInteger:(NSInteger)_persistence forKey:@"persistence"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithUser:[coder decodeObjectOfClass:[NSString class] forKey:@"user"]
                     password:[coder decodeObjectOfClass:[NSString class] forKey:@"password"]
                  persistence:(NSURLCredentialPersistence)[coder decodeIntegerForKey:@"persistence"]];
}

@end

#pragma mark - NSURLProtectionSpace

@implementation NSURLProtectionSpace {
    NSString *_host, *_protocol, *_realm, *_method, *_proxyType;
    NSInteger _port;
    SecTrustRef _trust;
    NSArray *_distinguishedNames;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port protocol:(NSString *)protocol realm:(NSString *)realm
        authenticationMethod:(NSString *)authenticationMethod
{
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _protocol = [[protocol lowercaseString] copy];
        _realm = [realm copy];
        _method = [authenticationMethod ?: NSURLAuthenticationMethodDefault copy];
    }
    return self;
}

- (instancetype)initWithProxyHost:(NSString *)host port:(NSInteger)port type:(NSString *)type realm:(NSString *)realm
             authenticationMethod:(NSString *)authenticationMethod
{
    if ((self = [self initWithHost:host port:port protocol:nil realm:realm authenticationMethod:authenticationMethod]))
        _proxyType = [type copy];
    return self;
}

- (void)dealloc
{
    [_host release];
    [_protocol release];
    [_realm release];
    [_method release];
    [_proxyType release];
    [_distinguishedNames release];
    if (_trust)
        CFRelease(_trust);
    [super dealloc];
}

/* (a server's trust, for an https connection's server-trust challenge) */
- (void)_finchSetServerTrust:(SecTrustRef)trust
{
    if (_trust)
        CFRelease(_trust);
    _trust = trust ? (SecTrustRef)CFRetain(trust) : NULL;
}

- (NSString *)host { return _host; }
- (NSInteger)port { return _port; }
- (NSString *)protocol { return _protocol; }
- (NSString *)realm { return _realm; }
- (NSString *)authenticationMethod { return _method; }
- (NSString *)proxyType { return _proxyType; }
- (BOOL)isProxy { return _proxyType != nil; }
- (NSArray<NSData *> *)distinguishedNames { return _distinguishedNames; }
- (SecTrustRef)serverTrust { return _trust; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* A password sent only over TLS, or one that isn't sent as it is. */
- (BOOL)receivesCredentialSecurely
{
    NSString *p = _proxyType ?: _protocol;
    if ([p isEqualToString:@"https"])
        return YES;
    return ![_method isEqualToString:NSURLAuthenticationMethodDefault] && ![_method isEqualToString:NSURLAuthenticationMethodHTTPBasic] &&
           ![_method isEqualToString:NSURLAuthenticationMethodHTMLForm];
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSURLProtectionSpace class]])
        return NO;
    NSURLProtectionSpace *o = other;
    return (_host == o->_host || [_host caseInsensitiveCompare:o->_host] == NSOrderedSame) && _port == o->_port &&
           same(_protocol, o->_protocol) && same(_realm, o->_realm) && same(_method, o->_method) && same(_proxyType, o->_proxyType);
}

- (NSUInteger)hash { return [[_host lowercaseString] hash] ^ (NSUInteger)_port ^ [_realm hash]; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>: Host:%@, Server:%@, Auth-Scheme:%@, Realm:%@, Port:%ld, Proxy:%@, Proxy-Type:%@",
                                      [self class], self, _host, _protocol, _method, _realm, (long)_port,
                                      _proxyType ? @"YES" : @"NO", _proxyType];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_host forKey:@"host"];
    [coder encodeInteger:_port forKey:@"port"];
    [coder encodeObject:_protocol forKey:@"protocol"];
    [coder encodeObject:_realm forKey:@"realm"];
    [coder encodeObject:_method forKey:@"authenticationMethod"];
    [coder encodeObject:_proxyType forKey:@"proxyType"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *proxy = [coder decodeObjectOfClass:[NSString class] forKey:@"proxyType"];
    if ((self = [self initWithHost:[coder decodeObjectOfClass:[NSString class] forKey:@"host"]
                              port:[coder decodeIntegerForKey:@"port"]
                          protocol:[coder decodeObjectOfClass:[NSString class] forKey:@"protocol"]
                             realm:[coder decodeObjectOfClass:[NSString class] forKey:@"realm"]
              authenticationMethod:[coder decodeObjectOfClass:[NSString class] forKey:@"authenticationMethod"]]))
        _proxyType = [proxy copy];
    return self;
}

@end

#pragma mark - NSURLAuthenticationChallenge

@implementation NSURLAuthenticationChallenge {
    NSURLProtectionSpace *_space;
    NSURLCredential *_proposed;
    NSInteger _failures;
    NSURLResponse *_response;
    NSError *_error;
    id<NSURLAuthenticationChallengeSender> _sender;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithProtectionSpace:(NSURLProtectionSpace *)space proposedCredential:(NSURLCredential *)credential
                   previousFailureCount:(NSInteger)previousFailureCount failureResponse:(NSURLResponse *)response
                                  error:(NSError *)error sender:(id<NSURLAuthenticationChallengeSender>)sender
{
    if ((self = [super init])) {
        _space = [space copy];
        _proposed = [credential copy];
        _failures = previousFailureCount;
        _response = [response copy];
        _error = [error copy];
        _sender = [sender retain];
    }
    return self;
}

- (instancetype)initWithAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge sender:(id<NSURLAuthenticationChallengeSender>)sender
{
    return [self initWithProtectionSpace:challenge.protectionSpace proposedCredential:challenge.proposedCredential
                    previousFailureCount:challenge.previousFailureCount failureResponse:challenge.failureResponse
                                   error:challenge.error sender:sender];
}

- (void)dealloc
{
    [_space release];
    [_proposed release];
    [_response release];
    [_error release];
    [_sender release];
    [super dealloc];
}

- (NSURLProtectionSpace *)protectionSpace { return _space; }
- (NSURLCredential *)proposedCredential { return _proposed; }
- (NSInteger)previousFailureCount { return _failures; }
- (NSURLResponse *)failureResponse { return _response; }
- (NSError *)error { return _error; }
- (id<NSURLAuthenticationChallengeSender>)sender { return _sender; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_space forKey:@"protectionSpace"];
    [coder encodeObject:_proposed forKey:@"proposedCredential"];
    [coder encodeInteger:_failures forKey:@"previousFailureCount"];
    [coder encodeObject:_response forKey:@"failureResponse"];
    [coder encodeObject:_error forKey:@"error"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithProtectionSpace:[coder decodeObjectOfClass:[NSURLProtectionSpace class] forKey:@"protectionSpace"]
                      proposedCredential:[coder decodeObjectOfClass:[NSURLCredential class] forKey:@"proposedCredential"]
                    previousFailureCount:[coder decodeIntegerForKey:@"previousFailureCount"]
                         failureResponse:[coder decodeObjectOfClass:[NSURLResponse class] forKey:@"failureResponse"]
                                   error:[coder decodeObjectOfClass:[NSError class] forKey:@"error"]
                                  sender:(id _Nonnull)nil];
}

@end

#pragma mark - NSURLCredentialStorage

@implementation NSURLCredentialStorage {
    NSMutableDictionary<NSURLProtectionSpace *, NSMutableDictionary<NSString *, NSURLCredential *> *> *_credentials;
    NSMutableDictionary<NSURLProtectionSpace *, NSString *> *_defaults; /* (by user) */
}

+ (NSURLCredentialStorage *)sharedCredentialStorage
{
    static NSURLCredentialStorage *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[NSURLCredentialStorage alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _credentials = [NSMutableDictionary new];
        _defaults = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_credentials release];
    [_defaults release];
    [super dealloc];
}

- (NSDictionary<NSString *, NSURLCredential *> *)credentialsForProtectionSpace:(NSURLProtectionSpace *)space
{
    @synchronized(self) {
        NSDictionary *d = _credentials[space];
        return d.count ? [[d copy] autorelease] : nil;
    }
}

- (NSDictionary<NSURLProtectionSpace *, NSDictionary<NSString *, NSURLCredential *> *> *)allCredentials
{
    @synchronized(self) {
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (NSURLProtectionSpace *space in _credentials)
            if (_credentials[space].count)
                all[space] = [[_credentials[space] copy] autorelease];
        return all;
    }
}

- (void)setCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    if (!credential.user || !space || credential.persistence == NSURLCredentialPersistenceNone)
        return;
    @synchronized(self) {
        NSMutableDictionary *d = _credentials[space];
        if (!d)
            _credentials[space] = d = [NSMutableDictionary dictionary];
        d[credential.user] = credential;
    }
}

- (void)removeCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    [self removeCredential:credential forProtectionSpace:space options:nil];
}

- (void)removeCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space options:(NSDictionary<NSString *, id> *)options
{
    if (!credential.user || !space)
        return;
    @synchronized(self) {
        [_credentials[space] removeObjectForKey:credential.user];
        if ([_defaults[space] isEqualToString:credential.user])
            [_defaults removeObjectForKey:space];
    }
}

- (NSURLCredential *)defaultCredentialForProtectionSpace:(NSURLProtectionSpace *)space
{
    @synchronized(self) {
        NSString *user = _defaults[space];
        return user ? [[_credentials[space][user] retain] autorelease] : nil;
    }
}

- (void)setDefaultCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    if (!credential.user || !space || credential.persistence == NSURLCredentialPersistenceNone)
        return;
    [self setCredential:credential forProtectionSpace:space];
    @synchronized(self) {
        _defaults[space] = credential.user;
    }
}

- (void)getCredentialsForProtectionSpace:(NSURLProtectionSpace *)protectionSpace task:(NSURLSessionTask *)task
                       completionHandler:(void (^)(NSDictionary<NSString *, NSURLCredential *> *))completionHandler
{
    completionHandler([self credentialsForProtectionSpace:protectionSpace]);
}

- (void)setCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)protectionSpace task:(NSURLSessionTask *)task
{
    [self setCredential:credential forProtectionSpace:protectionSpace];
}

- (void)removeCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)protectionSpace
                 options:(NSDictionary<NSString *, id> *)options task:(NSURLSessionTask *)task
{
    [self removeCredential:credential forProtectionSpace:protectionSpace options:options];
}

- (void)getDefaultCredentialForProtectionSpace:(NSURLProtectionSpace *)space task:(NSURLSessionTask *)task
                             completionHandler:(void (^)(NSURLCredential *))completionHandler
{
    completionHandler([self defaultCredentialForProtectionSpace:space]);
}

- (void)setDefaultCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)protectionSpace task:(NSURLSessionTask *)task
{
    [self setDefaultCredential:credential forProtectionSpace:protectionSpace];
}

@end

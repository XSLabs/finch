/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The URL loading system: NSURLRequest and NSMutableURLRequest, NSURLResponse and
 * NSHTTPURLResponse, and NSURLSession with its configuration and data and download
 * tasks. Apple's is CFNetwork's, re-exported by Foundation; Finch's lives in
 * Foundation itself and loads:
 *   - file: URLs, by reading the file;
 *   - data: URLs (RFC 2397), base64 or percent-encoded;
 *   - http: and https: URLs over HTTP/1.1 (TLS through OpenSSL, linked privately,
 *     verifying the server against /etc/ssl/cert.pem), following redirects, with
 *     chunked and length-delimited bodies.
 * Tasks run on a private queue; completion handlers and delegate calls go to the
 * session's delegate queue. Responses are cached and custom protocols answer requests
 * through NSURLCache.m. Cookies are sent and kept through the session's cookie storage
 * (NSHTTPCookie.m). Basic, Digest and server-trust authentication challenges work; NTLM,
 * HTTP/2 and background sessions aren't there yet. WebSocket and stream tasks are in
 * NSURLSessionSockets.m, over the connections here (NSURLSession_Finch.h).
 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <os/lock.h>
#include <sys/stat.h>
#include <openssl/err.h>
#include <openssl/md5.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <sys/socket.h>
#include <unistd.h>

#include "NSURLSession_Finch.h"

const int64_t NSURLSessionTransferSizeUnknown = -1;
const float NSURLSessionTaskPriorityDefault = 0.5f;
const float NSURLSessionTaskPriorityLow = 0.25f;
const float NSURLSessionTaskPriorityHigh = 0.75f;
NSString *const NSURLSessionDownloadTaskResumeData = @"NSURLSessionDownloadTaskResumeData";
NSString *const NSURLSessionUploadTaskResumeData = @"NSURLSessionUploadTaskResumeData";

#pragma mark - NSURLRequest

@implementation NSURLRequest {
  @protected
    NSURL *_URL;
    NSURLRequestCachePolicy _cachePolicy;
    NSTimeInterval _timeout;
    NSURL *_mainDocumentURL;
    NSURLRequestNetworkServiceType _serviceType;
    BOOL _allowsCellular, _allowsExpensive, _allowsConstrained, _handlesCookies, _pipelining, _assumesHTTP3;
    NSString *_method;
    NSMutableDictionary<NSString *, NSString *> *_headers;
    NSData *_body;
    NSInputStream *_bodyStream;
    NSURLRequestAttribution _attribution;
    NSMutableDictionary *_properties; /* (NSURLProtocol's, carried by copies) */
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)requestWithURL:(NSURL *)URL { return [[[self alloc] initWithURL:URL] autorelease]; }
+ (instancetype)requestWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeout
{
    return [[[self alloc] initWithURL:URL cachePolicy:cachePolicy timeoutInterval:timeout] autorelease];
}

- (instancetype)init { return [self initWithURL:(NSURL *_Nonnull)nil]; }
- (instancetype)initWithURL:(NSURL *)URL { return [self initWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60]; }

- (instancetype)initWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeout
{
    if ((self = [super init])) {
        _URL = [URL copy];
        _cachePolicy = cachePolicy;
        _timeout = timeout;
        _allowsCellular = _allowsExpensive = _allowsConstrained = _handlesCookies = YES;
        _method = @"GET";
        _headers = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_mainDocumentURL release];
    [_method release];
    [_headers release];
    [_body release];
    [_bodyStream release];
    [_properties release];
    [super dealloc];
}

- (id)_finchPropertyForKey:(NSString *)key
{
    @synchronized(self) {
        return [[[_properties objectForKey:key] retain] autorelease];
    }
}

- (void)_finchSetProperty:(id)value forKey:(NSString *)key
{
    @synchronized(self) {
        if (!_properties)
            _properties = [NSMutableDictionary new];
        [_properties setObject:value forKey:key];
    }
}

- (void)_finchRemovePropertyForKey:(NSString *)key
{
    @synchronized(self) {
        [_properties removeObjectForKey:key];
    }
}

- (void)_finchCopyTo:(NSURLRequest *)r
{
    r->_URL = [_URL copy];
    r->_cachePolicy = _cachePolicy;
    r->_timeout = _timeout;
    r->_mainDocumentURL = [_mainDocumentURL copy];
    r->_serviceType = _serviceType;
    r->_allowsCellular = _allowsCellular, r->_allowsExpensive = _allowsExpensive, r->_allowsConstrained = _allowsConstrained;
    r->_handlesCookies = _handlesCookies, r->_pipelining = _pipelining, r->_assumesHTTP3 = _assumesHTTP3;
    r->_method = [_method copy];
    r->_headers = [_headers mutableCopy];
    r->_body = [_body copy];
    r->_bodyStream = [_bodyStream retain];
    r->_attribution = _attribution;
    r->_properties = [_properties mutableCopy];
}

- (id)copyWithZone:(NSZone *)zone
{
    if ([self class] == [NSURLRequest class])
        return [self retain];
    NSURLRequest *r = [[NSURLRequest allocWithZone:zone] init];
    [r->_headers release];
    [r->_method release];
    [self _finchCopyTo:r];
    return r;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    NSMutableURLRequest *r = [[NSMutableURLRequest allocWithZone:zone] init];
    [((NSURLRequest *)r)->_headers release];
    [((NSURLRequest *)r)->_method release];
    [self _finchCopyTo:r];
    return r;
}

- (NSURL *)URL { return _URL; }
- (NSURLRequestCachePolicy)cachePolicy { return _cachePolicy; }
- (NSTimeInterval)timeoutInterval { return _timeout; }
- (NSURL *)mainDocumentURL { return _mainDocumentURL; }
- (NSURLRequestNetworkServiceType)networkServiceType { return _serviceType; }
- (BOOL)allowsCellularAccess { return _allowsCellular; }
- (BOOL)allowsExpensiveNetworkAccess { return _allowsExpensive; }
- (BOOL)allowsConstrainedNetworkAccess { return _allowsConstrained; }
- (BOOL)assumesHTTP3Capable { return _assumesHTTP3; }
- (NSURLRequestAttribution)attribution { return _attribution; }
- (BOOL)requiresDNSSECValidation { return NO; }
- (BOOL)allowsPersistentDNS { return NO; }
- (NSString *)cookiePartitionIdentifier { return nil; }
- (NSString *)HTTPMethod { return _method; }
- (NSDictionary<NSString *, NSString *> *)allHTTPHeaderFields { return [_headers count] ? [[_headers copy] autorelease] : nil; }
- (NSData *)HTTPBody { return _body; }
- (NSInputStream *)HTTPBodyStream { return _bodyStream; }
- (BOOL)HTTPShouldHandleCookies { return _handlesCookies; }
- (BOOL)HTTPShouldUsePipelining { return _pipelining; }

/* Header names compare without case. */
- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    for (NSString *k in _headers)
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            return _headers[k];
    return nil;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSURLRequest class]])
        return NO;
    NSURLRequest *o = other;
    return (_URL == o->_URL || [_URL isEqual:o->_URL]) && [_method isEqual:o->_method] &&
           [_headers isEqual:o->_headers] && (_body == o->_body || [_body isEqual:o->_body]) &&
           _cachePolicy == o->_cachePolicy && _timeout == o->_timeout;
}

- (NSUInteger)hash { return [_URL hash] ^ [_method hash]; }

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> { URL: %@ }", [self class], self, _URL]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeInteger:(NSInteger)_cachePolicy forKey:@"cachePolicy"];
    [coder encodeDouble:_timeout forKey:@"timeoutInterval"];
    [coder encodeObject:_method forKey:@"HTTPMethod"];
    [coder encodeObject:_headers forKey:@"headers"];
    [coder encodeObject:_body forKey:@"HTTPBody"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSURL *u = [coder decodeObjectOfClass:[NSURL class] forKey:@"URL"];
    if ((self = [self initWithURL:u cachePolicy:(NSURLRequestCachePolicy)[coder decodeIntegerForKey:@"cachePolicy"]
                  timeoutInterval:[coder decodeDoubleForKey:@"timeoutInterval"]])) {
        NSString *m = [coder decodeObjectOfClass:[NSString class] forKey:@"HTTPMethod"];
        if (m) {
            [_method release];
            _method = [m copy];
        }
        NSDictionary *h = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSString class], nil]
                                                forKey:@"headers"];
        if (h)
            [_headers setDictionary:h];
        _body = [[coder decodeObjectOfClass:[NSData class] forKey:@"HTTPBody"] copy];
    }
    return self;
}

@end

@implementation NSMutableURLRequest

- (void)setURL:(NSURL *)URL
{
    [_URL autorelease];
    _URL = [URL copy];
}
- (void)setCachePolicy:(NSURLRequestCachePolicy)p { _cachePolicy = p; }
- (void)setTimeoutInterval:(NSTimeInterval)t { _timeout = t; }
- (void)setMainDocumentURL:(NSURL *)u
{
    [_mainDocumentURL autorelease];
    _mainDocumentURL = [u copy];
}
- (void)setNetworkServiceType:(NSURLRequestNetworkServiceType)t { _serviceType = t; }
- (void)setAllowsCellularAccess:(BOOL)f { _allowsCellular = f; }
- (void)setAllowsExpensiveNetworkAccess:(BOOL)f { _allowsExpensive = f; }
- (void)setAllowsConstrainedNetworkAccess:(BOOL)f { _allowsConstrained = f; }
- (void)setAssumesHTTP3Capable:(BOOL)f { _assumesHTTP3 = f; }
- (void)setAttribution:(NSURLRequestAttribution)a { _attribution = a; }
- (void)setRequiresDNSSECValidation:(BOOL)f {}
- (void)setAllowsPersistentDNS:(BOOL)f {}
- (void)setCookiePartitionIdentifier:(NSString *)s {}
- (void)setHTTPMethod:(NSString *)m
{
    [_method autorelease];
    _method = [(m ?: @"GET") copy];
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)fields
{
    [_headers removeAllObjects];
    for (NSString *k in fields)
        [self setValue:fields[k] forHTTPHeaderField:k];
}
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    for (NSString *k in [_headers allKeys])
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            [_headers removeObjectForKey:k];
    if (value)
        _headers[field] = value;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    NSString *old = [self valueForHTTPHeaderField:field];
    [self setValue:old ? [NSString stringWithFormat:@"%@,%@", old, value] : value forHTTPHeaderField:field];
}
- (void)setHTTPBody:(NSData *)body
{
    [_body autorelease];
    _body = [body copy];
}
- (void)setHTTPBodyStream:(NSInputStream *)s
{
    [_bodyStream autorelease];
    _bodyStream = [s retain];
}
- (void)setHTTPShouldHandleCookies:(BOOL)f { _handlesCookies = f; }
- (void)setHTTPShouldUsePipelining:(BOOL)f { _pipelining = f; }

- (id)copyWithZone:(NSZone *)zone
{
    NSMutableURLRequest *r = [[NSMutableURLRequest allocWithZone:zone] init];
    [((NSURLRequest *)r)->_headers release];
    [((NSURLRequest *)r)->_method release];
    [self _finchCopyTo:r];
    return r;
}

@end

#pragma mark - NSURLResponse

/* The usual extension of a MIME type, for suggested file names. */
static NSString *
extension_for_mime(NSString *type)
{
    static NSDictionary *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      exts = [@{@"text/html" : @"html", @"text/plain" : @"txt", @"application/json" : @"json", @"image/png" : @"png",
                @"image/jpeg" : @"jpeg", @"image/gif" : @"gif", @"application/pdf" : @"pdf", @"text/xml" : @"xml",
                @"application/xml" : @"xml", @"text/css" : @"css", @"text/javascript" : @"js", @"text/rtf" : @"rtf",
                @"image/svg+xml" : @"svg", @"image/heic" : @"heic", @"application/zip" : @"zip", @"text/csv" : @"csv",
                @"application/octet-stream" : @"bin"} retain];
    });
    return type ? exts[[type lowercaseString]] : nil;
}

@implementation NSURLResponse {
  @protected
    NSURL *_URL;
    NSString *_MIMEType, *_encoding;
    long long _length;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithURL:(NSURL *)URL MIMEType:(NSString *)MIMEType expectedContentLength:(NSInteger)length
           textEncodingName:(NSString *)name
{
    if ((self = [super init])) {
        _URL = [URL copy];
        _MIMEType = [MIMEType copy];
        _length = length;
        _encoding = [name copy];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_MIMEType release];
    [_encoding release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSURL *)URL { return _URL; }
- (NSString *)MIMEType { return _MIMEType; }
- (long long)expectedContentLength { return _length; }
- (NSString *)textEncodingName { return _encoding; }

- (NSString *)suggestedFilename
{
    NSString *name = [[_URL path] lastPathComponent];
    if (![name length] || [name isEqualToString:@"/"])
        name = [_URL host] ?: @"Unknown";
    if ([name isEqualToString:@"Unknown"])
        return name;
    if (![[name pathExtension] length] && extension_for_mime(_MIMEType))
        name = [name stringByAppendingPathExtension:extension_for_mime(_MIMEType)];
    return name;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeObject:_MIMEType forKey:@"MIMEType"];
    [coder encodeInt64:_length forKey:@"expectedContentLength"];
    [coder encodeObject:_encoding forKey:@"textEncodingName"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithURL:[coder decodeObjectOfClass:[NSURL class] forKey:@"URL"]
                    MIMEType:[coder decodeObjectOfClass:[NSString class] forKey:@"MIMEType"]
       expectedContentLength:(NSInteger)[coder decodeInt64ForKey:@"expectedContentLength"]
            textEncodingName:[coder decodeObjectOfClass:[NSString class] forKey:@"textEncodingName"]];
}

@end

@implementation NSHTTPURLResponse {
    NSInteger _status;
    NSDictionary *_fields;
}

- (instancetype)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)version
               headerFields:(NSDictionary<NSString *, NSString *> *)fields
{
    NSString *type = nil, *charset = nil;
    NSString *ct = nil;
    for (NSString *k in fields)
        if ([k caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame)
            ct = fields[k];
    if (ct) {
        NSArray *parts = [ct componentsSeparatedByString:@";"];
        type = [[parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        for (NSString *p in parts) {
            NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([[t lowercaseString] hasPrefix:@"charset="])
                charset = [[t substringFromIndex:8] lowercaseString];
        }
    }
    long long length = -1;
    for (NSString *k in fields)
        if ([k caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame)
            length = [fields[k] longLongValue];
    if ((self = [super initWithURL:url MIMEType:type expectedContentLength:(NSInteger)length textEncodingName:charset])) {
        _status = statusCode;
        _fields = [fields copy] ?: [NSDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_fields release];
    [super dealloc];
}

- (NSInteger)statusCode { return _status; }

/* A Content-Disposition filename, if the server gave one. */
- (NSString *)suggestedFilename
{
    NSString *cd = [self valueForHTTPHeaderField:@"Content-Disposition"];
    for (NSString *part in [cd componentsSeparatedByString:@";"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([[t lowercaseString] hasPrefix:@"filename="]) {
            NSString *name = [[t substringFromIndex:9] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
            name = [name lastPathComponent];
            if ([name length])
                return name;
        }
    }
    return [super suggestedFilename];
}
- (NSDictionary *)allHeaderFields { return _fields; }

- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    for (NSString *k in _fields)
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            return _fields[k];
    return nil;
}

+ (NSString *)localizedStringForStatusCode:(NSInteger)code
{
    switch (code) {
    case 200: return @"no error";
    case 201: return @"created";
    case 204: return @"no content";
    case 301: return @"moved permanently";
    case 302: return @"found";
    case 304: return @"not modified";
    case 400: return @"bad request";
    case 401: return @"unauthorized";
    case 403: return @"forbidden";
    case 404: return @"not found";
    case 500: return @"internal server error";
    case 503: return @"service unavailable";
    }
    return code < 200 ? @"informational" : code < 300 ? @"success" : code < 400 ? @"redirected" : code < 500 ? @"client error" : @"server error";
}

@end

#pragma mark - Loading

typedef NS_ENUM(NSUInteger, FinchMetricDateField) {
    FinchMetricFetchStart,
    FinchMetricDomainLookupStart,
    FinchMetricDomainLookupEnd,
    FinchMetricConnectStart,
    FinchMetricConnectEnd,
    FinchMetricSecureConnectionStart,
    FinchMetricSecureConnectionEnd,
    FinchMetricRequestStart,
    FinchMetricRequestEnd,
    FinchMetricResponseStart,
    FinchMetricResponseEnd,
};

@interface NSURLSessionTaskTransactionMetrics (Finch)
- (instancetype)_finchInitWithRequest:(NSURLRequest *)request;
- (void)_finchSetDate:(NSDate *)date field:(FinchMetricDateField)field;
- (void)_finchSetResponse:(NSURLResponse *)response;
- (void)_finchSetNetworkProtocolName:(NSString *)name;
- (void)_finchSetResourceFetchType:(NSURLSessionTaskMetricsResourceFetchType)type;
- (void)_finchSetRequestHeaderBytes:(int64_t)bytes bodyBytes:(int64_t)bodyBytes;
- (void)_finchSetResponseHeaderBytes:(int64_t)headerBytes bodyBytes:(int64_t)bodyBytes decodedBytes:(int64_t)decodedBytes;
- (void)_finchSetAddressesWithSocket:(int)fd;
- (void)_finchSetTLSVersion:(uint16_t)version cipherSuite:(uint16_t)cipherSuite;
@end

@interface NSURLSessionTaskMetrics (Finch)
- (instancetype)_finchInitWithStartDate:(NSDate *)startDate endDate:(NSDate *)endDate
                      transactionMetrics:(NSArray *)transactionMetrics redirectCount:(NSUInteger)redirectCount;
@end

@interface FinchURLTaskMetricsCollector : NSObject
- (instancetype)initWithTaskStartDate:(NSDate *)startDate;
- (NSURLSessionTaskTransactionMetrics *)beginTransactionForRequest:(NSURLRequest *)request;
- (void)recordRedirect;
- (NSURLSessionTaskMetrics *)metricsForEndDate:(NSDate *)endDate request:(NSURLRequest *)request response:(NSURLResponse *)response;
@end

@implementation NSURLSessionTaskTransactionMetrics {
    NSURLRequest *_request;
    NSURLResponse *_response;
    NSDate *_fetchStartDate, *_domainLookupStartDate, *_domainLookupEndDate, *_connectStartDate, *_connectEndDate;
    NSDate *_secureConnectionStartDate, *_secureConnectionEndDate, *_requestStartDate, *_requestEndDate;
    NSDate *_responseStartDate, *_responseEndDate;
    NSString *_networkProtocolName, *_localAddress, *_remoteAddress;
    NSNumber *_localPort, *_remotePort, *_negotiatedTLSProtocolVersion, *_negotiatedTLSCipherSuite;
    NSURLSessionTaskMetricsResourceFetchType _resourceFetchType;
    int64_t _requestHeaderBytes, _requestBodyBytes, _responseHeaderBytes, _responseBodyBytes, _decodedBodyBytes;
    NSURLSessionTaskMetricsDomainResolutionProtocol _domainResolutionProtocol;
}

- (instancetype)_finchInitWithRequest:(NSURLRequest *)request
{
    if ((self = [super init])) {
        _request = [request copy];
        _fetchStartDate = [[NSDate date] retain];
        _resourceFetchType = NSURLSessionTaskMetricsResourceFetchTypeUnknown;
        _domainResolutionProtocol = NSURLSessionTaskMetricsDomainResolutionProtocolUnknown;
    }
    return self;
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NSURLSessionTaskTransactionMetrics cannot be initialized directly" userInfo:nil];
}

- (void)dealloc
{
    [_request release];
    [_response release];
    [_fetchStartDate release];
    [_domainLookupStartDate release];
    [_domainLookupEndDate release];
    [_connectStartDate release];
    [_connectEndDate release];
    [_secureConnectionStartDate release];
    [_secureConnectionEndDate release];
    [_requestStartDate release];
    [_requestEndDate release];
    [_responseStartDate release];
    [_responseEndDate release];
    [_networkProtocolName release];
    [_localAddress release];
    [_remoteAddress release];
    [_localPort release];
    [_remotePort release];
    [_negotiatedTLSProtocolVersion release];
    [_negotiatedTLSCipherSuite release];
    [super dealloc];
}

- (NSURLRequest *)request { return _request; }
- (NSURLResponse *)response { return _response; }
- (NSDate *)fetchStartDate { return _fetchStartDate; }
- (NSDate *)domainLookupStartDate { return _domainLookupStartDate; }
- (NSDate *)domainLookupEndDate { return _domainLookupEndDate; }
- (NSDate *)connectStartDate { return _connectStartDate; }
- (NSDate *)connectEndDate { return _connectEndDate; }
- (NSDate *)secureConnectionStartDate { return _secureConnectionStartDate; }
- (NSDate *)secureConnectionEndDate { return _secureConnectionEndDate; }
- (NSDate *)requestStartDate { return _requestStartDate; }
- (NSDate *)requestEndDate { return _requestEndDate; }
- (NSDate *)responseStartDate { return _responseStartDate; }
- (NSDate *)responseEndDate { return _responseEndDate; }
- (NSString *)networkProtocolName { return _networkProtocolName; }
- (BOOL)isProxyConnection { return NO; }
- (BOOL)isReusedConnection { return NO; }
- (NSURLSessionTaskMetricsResourceFetchType)resourceFetchType { return _resourceFetchType; }
- (int64_t)countOfRequestHeaderBytesSent { return _requestHeaderBytes; }
- (int64_t)countOfRequestBodyBytesSent { return _requestBodyBytes; }
- (int64_t)countOfRequestBodyBytesBeforeEncoding { return [_request.HTTPBody length]; }
- (int64_t)countOfResponseHeaderBytesReceived { return _responseHeaderBytes; }
- (int64_t)countOfResponseBodyBytesReceived { return _responseBodyBytes; }
- (int64_t)countOfResponseBodyBytesAfterDecoding { return _decodedBodyBytes; }
- (NSString *)localAddress { return _localAddress; }
- (NSNumber *)localPort { return _localPort; }
- (NSString *)remoteAddress { return _remoteAddress; }
- (NSNumber *)remotePort { return _remotePort; }
- (NSNumber *)negotiatedTLSProtocolVersion { return _negotiatedTLSProtocolVersion; }
- (NSNumber *)negotiatedTLSCipherSuite { return _negotiatedTLSCipherSuite; }
- (BOOL)isCellular { return NO; }
- (BOOL)isExpensive { return NO; }
- (BOOL)isConstrained { return NO; }
- (BOOL)isMultipath { return NO; }
- (NSURLSessionTaskMetricsDomainResolutionProtocol)domainResolutionProtocol { return _domainResolutionProtocol; }

- (void)_finchSetDate:(NSDate *)date field:(FinchMetricDateField)field
{
    NSDate **slot = NULL;
    switch (field) {
    case FinchMetricFetchStart: slot = &_fetchStartDate; break;
    case FinchMetricDomainLookupStart: slot = &_domainLookupStartDate; break;
    case FinchMetricDomainLookupEnd: slot = &_domainLookupEndDate; break;
    case FinchMetricConnectStart: slot = &_connectStartDate; break;
    case FinchMetricConnectEnd: slot = &_connectEndDate; break;
    case FinchMetricSecureConnectionStart: slot = &_secureConnectionStartDate; break;
    case FinchMetricSecureConnectionEnd: slot = &_secureConnectionEndDate; break;
    case FinchMetricRequestStart: slot = &_requestStartDate; break;
    case FinchMetricRequestEnd: slot = &_requestEndDate; break;
    case FinchMetricResponseStart: slot = &_responseStartDate; break;
    case FinchMetricResponseEnd: slot = &_responseEndDate; break;
    }
    [*slot release];
    *slot = [date copy];
}

- (void)_finchSetResponse:(NSURLResponse *)response
{
    [_response release];
    _response = [response copy];
}

- (void)_finchSetNetworkProtocolName:(NSString *)name
{
    [_networkProtocolName release];
    _networkProtocolName = [name copy];
}

- (void)_finchSetResourceFetchType:(NSURLSessionTaskMetricsResourceFetchType)type { _resourceFetchType = type; }
- (void)_finchSetRequestHeaderBytes:(int64_t)bytes bodyBytes:(int64_t)bodyBytes
{
    _requestHeaderBytes = bytes;
    _requestBodyBytes = bodyBytes;
}
- (void)_finchSetResponseHeaderBytes:(int64_t)headerBytes bodyBytes:(int64_t)bodyBytes decodedBytes:(int64_t)decodedBytes
{
    _responseHeaderBytes = headerBytes;
    _responseBodyBytes = bodyBytes;
    _decodedBodyBytes = decodedBytes;
}

- (void)_finchSetAddressesWithSocket:(int)fd
{
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    char text[INET6_ADDRSTRLEN];
    if (getsockname(fd, (struct sockaddr *)&address, &length) == 0) {
        const void *bytes = address.ss_family == AF_INET ? (const void *)&((struct sockaddr_in *)&address)->sin_addr :
                                                            (const void *)&((struct sockaddr_in6 *)&address)->sin6_addr;
        if (inet_ntop(address.ss_family, bytes, text, sizeof(text))) {
            [_localAddress release];
            _localAddress = [[NSString alloc] initWithUTF8String:text];
        }
        uint16_t port = address.ss_family == AF_INET ? ntohs(((struct sockaddr_in *)&address)->sin_port) :
                                                        ntohs(((struct sockaddr_in6 *)&address)->sin6_port);
        [_localPort release];
        _localPort = [[NSNumber alloc] initWithUnsignedShort:port];
    }
    length = sizeof(address);
    if (getpeername(fd, (struct sockaddr *)&address, &length) == 0) {
        const void *bytes = address.ss_family == AF_INET ? (const void *)&((struct sockaddr_in *)&address)->sin_addr :
                                                            (const void *)&((struct sockaddr_in6 *)&address)->sin6_addr;
        if (inet_ntop(address.ss_family, bytes, text, sizeof(text))) {
            [_remoteAddress release];
            _remoteAddress = [[NSString alloc] initWithUTF8String:text];
        }
        uint16_t port = address.ss_family == AF_INET ? ntohs(((struct sockaddr_in *)&address)->sin_port) :
                                                        ntohs(((struct sockaddr_in6 *)&address)->sin6_port);
        [_remotePort release];
        _remotePort = [[NSNumber alloc] initWithUnsignedShort:port];
    }
}

- (void)_finchSetTLSVersion:(uint16_t)version cipherSuite:(uint16_t)cipherSuite
{
    [_negotiatedTLSProtocolVersion release];
    [_negotiatedTLSCipherSuite release];
    _negotiatedTLSProtocolVersion = [[NSNumber alloc] initWithUnsignedShort:version];
    _negotiatedTLSCipherSuite = [[NSNumber alloc] initWithUnsignedShort:cipherSuite];
}

@end

@implementation NSURLSessionTaskMetrics {
    NSArray *_transactionMetrics;
    NSDateInterval *_taskInterval;
    NSUInteger _redirectCount;
}

- (instancetype)_finchInitWithStartDate:(NSDate *)startDate endDate:(NSDate *)endDate
                      transactionMetrics:(NSArray *)transactionMetrics redirectCount:(NSUInteger)redirectCount
{
    if ((self = [super init])) {
        _transactionMetrics = [transactionMetrics copy];
        _taskInterval = [[NSDateInterval alloc] initWithStartDate:startDate endDate:endDate];
        _redirectCount = redirectCount;
    }
    return self;
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NSURLSessionTaskMetrics cannot be initialized directly" userInfo:nil];
}

- (void)dealloc
{
    [_transactionMetrics release];
    [_taskInterval release];
    [super dealloc];
}

- (NSArray *)transactionMetrics { return _transactionMetrics; }
- (NSDateInterval *)taskInterval { return _taskInterval; }
- (NSUInteger)redirectCount { return _redirectCount; }

@end

@implementation FinchURLTaskMetricsCollector {
    NSDate *_taskStartDate;
    NSMutableArray *_transactionMetrics;
    NSUInteger _redirectCount;
}

- (instancetype)initWithTaskStartDate:(NSDate *)startDate
{
    if ((self = [super init])) {
        _taskStartDate = [startDate copy];
        _transactionMetrics = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    [_taskStartDate release];
    [_transactionMetrics release];
    [super dealloc];
}

- (NSURLSessionTaskTransactionMetrics *)beginTransactionForRequest:(NSURLRequest *)request
{
    NSURLSessionTaskTransactionMetrics *metrics = [[NSURLSessionTaskTransactionMetrics alloc] _finchInitWithRequest:request];
    @synchronized(self) {
        [_transactionMetrics addObject:metrics];
    }
    return [metrics autorelease];
}

- (void)recordRedirect
{
    @synchronized(self) { _redirectCount++; }
}

- (NSURLSessionTaskMetrics *)metricsForEndDate:(NSDate *)endDate request:(NSURLRequest *)request response:(NSURLResponse *)response
{
    NSArray *transactions;
    NSUInteger redirects;
    @synchronized(self) {
        if (![_transactionMetrics count] && response && request) {
            NSURLSessionTaskTransactionMetrics *metrics = [[NSURLSessionTaskTransactionMetrics alloc] _finchInitWithRequest:request];
            [metrics _finchSetDate:_taskStartDate field:FinchMetricFetchStart];
            [metrics _finchSetResponse:response];
            [metrics _finchSetDate:endDate field:FinchMetricResponseEnd];
            [_transactionMetrics addObject:metrics];
            [metrics autorelease];
        }
        transactions = [_transactionMetrics copy];
        redirects = _redirectCount;
    }
    NSURLSessionTaskMetrics *metrics = [[NSURLSessionTaskMetrics alloc] _finchInitWithStartDate:_taskStartDate endDate:endDate
                                                                           transactionMetrics:transactions redirectCount:redirects];
    [transactions release];
    return [metrics autorelease];
}

@end

static __thread FinchURLTaskMetricsCollector *current_metrics_collector;
static __thread NSURLSessionTaskTransactionMetrics *current_transaction_metrics;

static NSDate *metric_now(void) { return [NSDate date]; }

NSError *
url_error(NSInteger code, NSURL *url, NSString *description)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (url) {
        info[NSURLErrorFailingURLErrorKey] = url;
        info[NSURLErrorFailingURLStringErrorKey] = [url absoluteString];
    }
    if (description)
        info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

/* data:[<mediatype>][;base64],<data> */
static NSData *
load_data_url(NSURL *url, NSURLResponse **response)
{
    NSString *s = [url resourceSpecifier];
    NSRange comma = [s rangeOfString:@","];
    if (comma.location == NSNotFound)
        return nil;
    NSString *meta = [s substringToIndex:comma.location], *payload = [s substringFromIndex:NSMaxRange(comma)];
    BOOL base64 = [meta hasSuffix:@";base64"];
    if (base64)
        meta = [meta substringToIndex:[meta length] - 7];
    NSData *d = base64 ? [[[NSData alloc] initWithBase64EncodedString:[payload stringByRemovingPercentEncoding] ?: payload
                                                              options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease]
                       : [[payload stringByRemovingPercentEncoding] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *parts = [meta componentsSeparatedByString:@";"];
    NSString *type = [parts[0] length] ? parts[0] : @"text/plain";
    NSString *charset = nil;
    for (NSString *p in parts)
        if ([p hasPrefix:@"charset="])
            charset = [p substringFromIndex:8];
    *response = [[[NSURLResponse alloc] initWithURL:url MIMEType:type expectedContentLength:(NSInteger)[d length]
                                   textEncodingName:charset] autorelease];
    return d;
}

static NSString *
mime_for_extension(NSString *ext)
{
    static NSDictionary *types;
    if (!types)
        types = [@{@"html" : @"text/html", @"htm" : @"text/html", @"txt" : @"text/plain", @"json" : @"application/json",
                   @"png" : @"image/png", @"jpg" : @"image/jpeg", @"jpeg" : @"image/jpeg", @"gif" : @"image/gif",
                   @"pdf" : @"application/pdf", @"xml" : @"text/xml", @"css" : @"text/css", @"js" : @"text/javascript",
                   @"rtf" : @"text/rtf", @"svg" : @"image/svg+xml", @"heic" : @"image/heic"} retain];
    return types[[ext lowercaseString]] ?: @"application/octet-stream";
}

static NSInteger conn_server_trust(Connection *c, NSURL *url);

ssize_t
conn_read(Connection *c, void *buf, size_t n)
{
    return c->ssl ? SSL_read(c->ssl, buf, (int)n) : read(c->fd, buf, n);
}

BOOL
conn_write(Connection *c, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t w = c->ssl ? SSL_write(c->ssl, p, (int)n) : write(c->fd, p, n);
        if (w <= 0)
            return NO;
        c->bytesWritten += (uint64_t)w;
        p += w;
        n -= (size_t)w;
    }
    return YES;
}

void
conn_close(Connection *c)
{
    if (c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
    }
    if (c->ctx)
        SSL_CTX_free(c->ctx);
    if (c->fd >= 0)
        close(c->fd);
}

/* OpenSSL is built without sockets (no-sock), so TLS runs over a BIO of our own on the
 * connected descriptor. */
static int
fd_bio_write(BIO *b, const char *buf, int n)
{
    ssize_t w = write((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
    return (int)w;
}

static int
fd_bio_read(BIO *b, char *buf, int n)
{
    ssize_t r = read((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
    return (int)r;
}

static long
fd_bio_ctrl(BIO *b, int cmd, long num, void *ptr)
{
    return cmd == BIO_CTRL_FLUSH ? 1 : 0;
}

static BIO_METHOD *
fd_bio_method(void)
{
    static BIO_METHOD *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      m = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "finch fd");
      BIO_meth_set_write(m, fd_bio_write);
      BIO_meth_set_read(m, fd_bio_read);
      BIO_meth_set_ctrl(m, fd_bio_ctrl);
    });
    return m;
}

NSInteger
conn_open(Connection *c, NSURL *url, NSTimeInterval timeout)
{
    c->fd = -1;
    c->ssl = NULL;
    c->ctx = NULL;
    c->bytesWritten = 0;
    BOOL tls = [[[url scheme] lowercaseString] isEqualToString:@"https"];
    NSString *host = [url host];
    if (![host length])
        return NSURLErrorBadURL;
    int port = [url port] ? [[url port] intValue] : tls ? 443 : 80;
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof portStr, "%d", port);
    struct in_addr ipv4;
    struct in6_addr ipv6;
    BOOL literalAddress = inet_pton(AF_INET, [host UTF8String], &ipv4) == 1 || inet_pton(AF_INET6, [host UTF8String], &ipv6) == 1;
    if (current_transaction_metrics && !literalAddress)
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricDomainLookupStart];
    int lookup = getaddrinfo([host UTF8String], portStr, &hints, &res);
    if (lookup != 0 || !res)
        return NSURLErrorCannotFindHost;
    if (current_transaction_metrics && !literalAddress)
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricDomainLookupEnd];
    if (current_transaction_metrics)
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricConnectStart];
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0)
            continue;
        struct timeval tv = {(time_t)timeout, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) {
            c->fd = fd;
            break;
        }
        close(fd);
    }
    freeaddrinfo(res);
    if (c->fd < 0)
        return NSURLErrorCannotConnectToHost;
    if (current_transaction_metrics) {
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricConnectEnd];
        [current_transaction_metrics _finchSetAddressesWithSocket:c->fd];
    }
    if (!tls)
        return 0;
    c->ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(c->ctx, TLS1_2_VERSION);
    /* Security evaluates the peer chain after the handshake so a delegate can accept it. */
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_NONE, NULL);
    c->ssl = SSL_new(c->ctx);
    SSL_set_tlsext_host_name(c->ssl, [host UTF8String]);
    BIO *bio = BIO_new(fd_bio_method());
    BIO_set_data(bio, (void *)(intptr_t)c->fd);
    BIO_set_init(bio, 1);
    SSL_set_bio(c->ssl, bio, bio);
    if (current_transaction_metrics)
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricSecureConnectionStart];
    if (SSL_connect(c->ssl) != 1)
        return NSURLErrorSecureConnectionFailed;
    if (current_transaction_metrics) {
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricSecureConnectionEnd];
        const SSL_CIPHER *cipher = SSL_get_current_cipher(c->ssl);
        [current_transaction_metrics _finchSetTLSVersion:(uint16_t)SSL_version(c->ssl)
                                               cipherSuite:cipher ? SSL_CIPHER_get_protocol_id(cipher) : 0];
    }
    return 0;
}

/* The cookie storage of the session loading on this thread (set around each load; nil when
   the session doesn't set cookies). Without a session, the shared storage, as on macOS. */
static __thread NSHTTPCookieStorage *current_cookies;
static __thread BOOL current_cookies_set;

static NSHTTPCookieStorage *
cookie_store(void)
{
    return current_cookies_set ? current_cookies : [NSHTTPCookieStorage sharedHTTPCookieStorage];
}

/* A download task's file, which a successful response's body streams into (a resumed one's
   206 response appending to what's there), set on the loading thread around its load. The
   socket is kept so a cancel can cut the connection. */
typedef struct {
    int fd;
    int64_t offset;   /* bytes in the file from before, by the resume data (0 for a new download) */
    int64_t written;  /* bytes in it now */
    int64_t expected; /* the whole size, when the response says */
    int sock;
    BOOL cancelled;
    os_unfair_lock lock;
    NSHTTPURLResponse *response; /* (retained) the response whose body went into the file */
    void (^progress)(void);
    void (^resumed)(void); /* (a 206 continuing the file) */
} Download;
static __thread Download *current_download;

/* What a task's delegate takes part in, set on the loading thread around the task's load:
   redirects and password challenges, and, for a data task with a delegate, the final
   response and its body as it arrives (delivered set once the response has gone). */
typedef struct {
    NSURLRequest *(^redirect)(NSHTTPURLResponse *response, NSURLRequest *proposed); /* nil: stop at the redirect */
    NSURLSessionAuthChallengeDisposition (^challenge)(NSURLAuthenticationChallenge *challenge, NSURLCredential **credential);
    BOOL (^response)(NSURLResponse *response); /* NO: cancel the task */
    void (^data)(NSData *data);
    BOOL delivered;
} Hooks;
static __thread Hooks *current_hooks;
static __thread NSURLCredentialStorage *current_credentials;
static __thread BOOL current_credentials_set;

/* A response load() answers itself: a redirect it follows, or a password challenge. */
static NSDictionary *http_authentication_parameters(NSHTTPURLResponse *r, NSString *scheme);
static BOOL
answered_by_load(NSHTTPURLResponse *r)
{
    NSInteger s = [r statusCode];
    return ((s == 301 || s == 302 || s == 303 || s == 307 || s == 308) && [r valueForHTTPHeaderField:@"Location"]) ||
           (s == 401 && (http_authentication_parameters(r, @"Digest") || http_authentication_parameters(r, @"Basic")));
}

/* A response body as it arrives: by its length, chunked, or to the end of the connection;
   decoded into memory or a download's file. */
typedef struct {
    BOOL chunked, done, failed;
    int64_t length, got; /* (length -1: to the connection's end) */
    int state;           /* chunked: 0 the size line, 1 its data, 2 the line end after it */
    uint64_t remaining;
    char line[64];
    int lineLength;
    NSMutableData *memory;
    Download *download;
    Hooks *hooks; /* (the delegate gets the body as it comes, and memory keeps it for the cache) */
} Body;

static void
body_emit(Body *b, const char *p, size_t n)
{
    if (!n || b->failed)
        return;
    if (!b->download) {
        [b->memory appendBytes:p length:n];
        if (b->hooks)
            b->hooks->data([NSData dataWithBytes:p length:n]);
        return;
    }
    while (n) {
        ssize_t w = write(b->download->fd, p, n);
        if (w <= 0) {
            b->failed = YES;
            return;
        }
        p += w;
        n -= (size_t)w;
        b->download->written += w;
    }
    if (b->download->progress)
        b->download->progress();
}

static void
body_feed(Body *b, const char *p, size_t n)
{
    if (!b->chunked) {
        size_t take = b->length < 0 ? n : (size_t)MIN((int64_t)n, b->length - b->got);
        body_emit(b, p, take);
        b->got += (int64_t)take;
        b->done = b->length >= 0 && b->got == b->length;
        return;
    }
    while (n && !b->done) {
        if (b->state == 1) {
            size_t take = (size_t)MIN((uint64_t)n, b->remaining);
            body_emit(b, p, take);
            p += take;
            n -= take;
            if (!(b->remaining -= take))
                b->state = 2;
            continue;
        }
        char ch = *p++;
        n--;
        if (ch != '\n') {
            if (b->state == 0 && b->lineLength < (int)sizeof b->line - 1)
                b->line[b->lineLength++] = ch;
            continue;
        }
        if (b->state == 2) {
            b->state = 0;
            continue;
        }
        b->line[b->lineLength] = 0;
        b->lineLength = 0;
        b->remaining = strtoull(b->line, NULL, 16);
        if (b->remaining)
            b->state = 1;
        else
            b->done = YES; /* (trailers, if any, are left unread) */
    }
}

/* One request and its response over HTTP/1.1 (the connection closes after it). Each
   Set-Cookie line comes back on its own in setCookies (folded together they'd be ambiguous).
   A body cut short is an error (NSURLErrorNetworkConnectionLost). With a download on this
   thread, a successful response's body goes into its file, and nothing comes back. */
static NSData *
load_http_once(NSURLRequest *request, NSURL *url, NSHTTPURLResponse **outResponse, NSInteger *outError, NSMutableArray *setCookies)
{
    if (current_transaction_metrics)
        [current_transaction_metrics _finchSetResourceFetchType:NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad];
    Connection c;
    NSInteger err = conn_open(&c, url, [request timeoutInterval] > 0 ? [request timeoutInterval] : 60);
    if (!err)
        err = conn_server_trust(&c, url);
    if (err) {
        conn_close(&c);
        *outError = err;
        return nil;
    }
    NSString *path = [(NSString *)CFURLCopyPath((CFURLRef)url) autorelease];
    if (![path length])
        path = @"/";
    NSString *query = [url query];
    NSString *pq = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\n", [request HTTPMethod], pq,
                                                              [url port] ? [NSString stringWithFormat:@"%@:%@", [url host], [url port]] : [url host]];
    NSDictionary *fields = [request allHTTPHeaderFields] ?: @{};
    BOOL hasUA = NO, hasAccept = NO;
    for (NSString *k in fields) {
        [head appendFormat:@"%@: %@\r\n", k, fields[k]];
        hasUA |= [k caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame;
        hasAccept |= [k caseInsensitiveCompare:@"Accept"] == NSOrderedSame;
    }
    if (!hasUA)
        [head appendFormat:@"User-Agent: %@ (Finch)\r\n", [[NSProcessInfo processInfo] processName]];
    if (!hasAccept)
        [head appendString:@"Accept: */*\r\n"];
    NSData *body = [request HTTPBody];
    NSURL *uploadFile = [NSURLProtocol propertyForKey:@"_FinchUploadFile" inRequest:request];
    if (!body && uploadFile)
        body = [NSData dataWithContentsOfURL:uploadFile] ?: [NSData data];
    if (!body && [request HTTPBodyStream]) {
        /* (a body stream is read whole and sent with its length) */
        NSInputStream *in = [request HTTPBodyStream];
        NSMutableData *all = [NSMutableData data];
        uint8_t buf[16384];
        NSInteger n;
        [in open];
        while ((n = [in read:buf maxLength:sizeof buf]) > 0)
            [all appendBytes:buf length:(NSUInteger)n];
        [in close];
        body = all;
    }
    if (body || ![[request HTTPMethod] isEqualToString:@"GET"])
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    [head appendString:@"Connection: close\r\n\r\n"];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (current_transaction_metrics) {
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricRequestStart];
        [current_transaction_metrics _finchSetRequestHeaderBytes:0 bodyBytes:0];
    }
    BOOL wroteHead = conn_write(&c, [headData bytes], [headData length]);
    uint64_t headerBytes = c.bytesWritten;
    BOOL wroteBody = wroteHead && (!body || conn_write(&c, [body bytes], [body length]));
    if (current_transaction_metrics)
        [current_transaction_metrics _finchSetRequestHeaderBytes:(int64_t)headerBytes
                                                       bodyBytes:(int64_t)(c.bytesWritten - headerBytes)];
    if (!wroteHead || !wroteBody) {
        conn_close(&c);
        *outError = NSURLErrorNetworkConnectionLost;
        return nil;
    }
    if (current_transaction_metrics)
        [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricRequestEnd];
    Download *download = current_download;
    if (download) {
        os_unfair_lock_lock(&download->lock);
        download->sock = c.fd;
        BOOL cancelled = download->cancelled;
        os_unfair_lock_unlock(&download->lock);
        if (cancelled)
            shutdown(c.fd, SHUT_RDWR);
    }
    /* the head */
    NSMutableData *all = [NSMutableData data];
    char buf[16384];
    ssize_t n;
    NSUInteger end = 0;
    BOOL found = NO;
    BOOL recordedResponseStart = NO;
    while (!found && (n = conn_read(&c, buf, sizeof buf)) > 0) {
        if (!recordedResponseStart && current_transaction_metrics) {
            [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricResponseStart];
            recordedResponseStart = YES;
        }
        NSUInteger from = [all length] > 3 ? [all length] - 3 : 0;
        [all appendBytes:buf length:(NSUInteger)n];
        const char *b = [all bytes];
        for (NSUInteger i = from; i + 3 < [all length]; i++)
            if (!memcmp(b + i, "\r\n\r\n", 4)) {
                end = i;
                found = YES;
                break;
            }
    }
    const char *bytes = [all bytes];
    NSUInteger len = [all length];
    if (!found) {
        if (download) {
            os_unfair_lock_lock(&download->lock);
            download->sock = -1;
            os_unfair_lock_unlock(&download->lock);
        }
        conn_close(&c);
        *outError = len ? NSURLErrorBadServerResponse : NSURLErrorTimedOut;
        return nil;
    }
    NSString *headerText = [[[NSString alloc] initWithBytes:bytes length:end encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray *status = [lines[0] componentsSeparatedByString:@" "];
    if ([status count] < 2) {
        if (download) {
            os_unfair_lock_lock(&download->lock);
            download->sock = -1;
            os_unfair_lock_unlock(&download->lock);
        }
        conn_close(&c);
        *outError = NSURLErrorBadServerResponse;
        return nil;
    }
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *k = [lines[i] substringToIndex:colon.location];
        NSString *v = [[lines[i] substringFromIndex:NSMaxRange(colon)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k caseInsensitiveCompare:@"Set-Cookie"] == NSOrderedSame)
            [setCookies addObject:v];
        h[k] = h[k] ? [NSString stringWithFormat:@"%@, %@", h[k], v] : v;
    }
    *outResponse = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:[status[1] integerValue] HTTPVersion:status[0]
                                              headerFields:h] autorelease];
    if (current_transaction_metrics) {
        NSString *protocol = [status[0] lowercaseString];
        if ([protocol hasPrefix:@"http/"])
            protocol = [protocol substringFromIndex:5];
        [current_transaction_metrics _finchSetNetworkProtocolName:[@"http/" stringByAppendingString:protocol]];
        [current_transaction_metrics _finchSetResponse:*outResponse];
        [current_transaction_metrics _finchSetResponseHeaderBytes:(int64_t)(end + 4) bodyBytes:0 decodedBytes:0];
    }
    /* the body */
    NSInteger code = [*outResponse statusCode];
    Body rb = {.length = -1, .memory = [NSMutableData data]};
    rb.chunked = [[[*outResponse valueForHTTPHeaderField:@"Transfer-Encoding"] lowercaseString] containsString:@"chunked"];
    NSString *length = [*outResponse valueForHTTPHeaderField:@"Content-Length"];
    if (!rb.chunked && length)
        rb.length = [length longLongValue];
    if ([[request HTTPMethod] isEqualToString:@"HEAD"] || code == 204 || code == 304 || code < 200)
        rb.length = 0, rb.chunked = NO;
    NSInteger failure = 0;
    if (download && code >= 200 && code < 300) {
        /* a 206 continues the file where the resume data left it; anything else starts it again */
        NSString *range = [*outResponse valueForHTTPHeaderField:@"Content-Range"];
        long long start = -1;
        if (code == 206 && !(range && sscanf([range UTF8String], "bytes %lld-", &start) == 1 && start == download->offset))
            failure = NSURLErrorBadServerResponse;
        if (code != 206)
            download->offset = 0;
        if (!failure && (ftruncate(download->fd, download->offset) < 0 || lseek(download->fd, download->offset, SEEK_SET) < 0))
            failure = NSURLErrorCannotWriteToFile;
        download->written = download->offset;
        download->expected = rb.length >= 0 ? download->offset + rb.length : -1;
        if (!failure && download->offset > 0 && download->resumed)
            download->resumed();
        [download->response release];
        download->response = [*outResponse retain];
        rb.download = download;
    }
    Hooks *hooks = current_hooks;
    if (!failure && !rb.download && hooks && hooks->response && !answered_by_load(*outResponse)) {
        hooks->delivered = YES;
        if (!hooks->response(*outResponse))
            failure = NSURLErrorCancelled;
        else
            rb.hooks = hooks;
    }
    if (!failure) {
        body_feed(&rb, bytes + end + 4, len - end - 4);
    }
    int64_t responseBodyWireBytes = (int64_t)(len - end - 4);
    if (!failure) {
        while (!rb.done && !rb.failed && (n = conn_read(&c, buf, sizeof buf)) > 0) {
            responseBodyWireBytes += n;
            body_feed(&rb, buf, (size_t)n);
        }
    }
    if (current_transaction_metrics) {
        int64_t decodedBytes = rb.download ? MAX((int64_t)0, rb.download->written - rb.download->offset) : (int64_t)[rb.memory length];
        [current_transaction_metrics _finchSetResponseHeaderBytes:(int64_t)(end + 4) bodyBytes:responseBodyWireBytes decodedBytes:decodedBytes];
        if (rb.done || (!rb.chunked && rb.length == 0))
            [current_transaction_metrics _finchSetDate:metric_now() field:FinchMetricResponseEnd];
    }
    BOOL cancelled = NO;
    if (download) {
        os_unfair_lock_lock(&download->lock);
        download->sock = -1;
        cancelled = download->cancelled;
        os_unfair_lock_unlock(&download->lock);
    }
    conn_close(&c);
    if (!failure && rb.failed)
        failure = NSURLErrorCannotWriteToFile;
    if (!failure && !rb.done && (rb.chunked || rb.length >= 0))
        failure = cancelled ? NSURLErrorCancelled : NSURLErrorNetworkConnectionLost;
    if (failure) {
        *outError = failure;
        return nil;
    }
    return rb.download ? [NSData data] : rb.memory;
}

/* Parameters from a Basic or Digest WWW-Authenticate challenge. */
static NSDictionary *
http_authentication_parameters(NSHTTPURLResponse *r, NSString *scheme)
{
    if ([r statusCode] != 401)
        return nil;
    NSString *header = [r valueForHTTPHeaderField:@"WWW-Authenticate"];
    if (!header)
        return nil;
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSRange search = NSMakeRange(0, [header length]);
    NSRange found = NSMakeRange(NSNotFound, 0);
    while (search.location < [header length]) {
        NSRange candidate = [header rangeOfString:scheme options:NSCaseInsensitiveSearch range:search];
        if (candidate.location == NSNotFound)
            break;
        NSUInteger end = NSMaxRange(candidate);
        BOOL startsScheme = (candidate.location == 0 || [header characterAtIndex:candidate.location - 1] == ',' ||
                             [space characterIsMember:[header characterAtIndex:candidate.location - 1]]) &&
                            (end == [header length] || [space characterIsMember:[header characterAtIndex:end]]);
        if (startsScheme) {
            found = candidate;
            break;
        }
        search.location = end;
    }
    if (found.location == NSNotFound)
        return nil;

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    NSUInteger p = NSMaxRange(found), length = [header length];
    while (p < length) {
        while (p < length && ([space characterIsMember:[header characterAtIndex:p]] || [header characterAtIndex:p] == ','))
            p++;
        if (p == length)
            break;
        NSUInteger start = p;
        while (p < length && [header characterAtIndex:p] != '=' && [header characterAtIndex:p] != ',')
            p++;
        NSString *name = [[header substringWithRange:NSMakeRange(start, p - start)]
            stringByTrimmingCharactersInSet:space];
        if (p == length || [header characterAtIndex:p] != '=') {
            while (p < length && [header characterAtIndex:p] != ',')
                p++;
            continue;
        }
        p++;
        while (p < length && [space characterIsMember:[header characterAtIndex:p]])
            p++;
        NSMutableString *value = [NSMutableString string];
        if (p < length && [header characterAtIndex:p] == '"') {
            p++;
            while (p < length && [header characterAtIndex:p] != '"') {
                unichar c = [header characterAtIndex:p++];
                if (c == '\\' && p < length)
                    c = [header characterAtIndex:p++];
                [value appendFormat:@"%C", c];
            }
            if (p < length)
                p++;
        } else {
            NSUInteger valueStart = p;
            while (p < length && [header characterAtIndex:p] != ',')
                p++;
            [value appendString:[[header substringWithRange:NSMakeRange(valueStart, p - valueStart)]
                stringByTrimmingCharactersInSet:space]];
        }
        if ([name length])
            parameters[[name lowercaseString]] = value;
        while (p < length && [header characterAtIndex:p] != ',')
            p++;
        if (p < length)
            p++;
    }
    parameters[@"scheme"] = scheme;
    return parameters;
}

static NSString *
md5_hex(NSString *text)
{
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[MD5_DIGEST_LENGTH];
    MD5([bytes bytes], [bytes length], digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < MD5_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *
digest_quote(NSString *value)
{
    return [NSString stringWithFormat:@"\"%@\"", [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                                            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}

static NSString *
digest_authorization(NSURLCredential *credential, NSURLRequest *request, NSDictionary *challenge)
{
    NSString *realm = challenge[@"realm"], *nonce = challenge[@"nonce"], *qops = challenge[@"qop"];
    NSString *algorithm = challenge[@"algorithm"] ?: @"MD5";
    if (![realm length] || ![nonce length] || ![qops length] || [algorithm caseInsensitiveCompare:@"MD5"] != NSOrderedSame)
        return nil;
    BOOL auth = NO;
    for (NSString *qop in [qops componentsSeparatedByString:@","])
        if ([[qop stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                caseInsensitiveCompare:@"auth"] == NSOrderedSame)
            auth = YES;
    if (!auth)
        return nil;

    NSURL *url = [request URL];
    NSString *path = [(NSString *)CFURLCopyPath((CFURLRef)url) autorelease];
    if (![path length])
        path = @"/";
    NSString *query = [url query];
    NSString *uri = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
    unsigned char random[16];
    arc4random_buf(random, sizeof random);
    NSMutableString *cnonce = [NSMutableString stringWithCapacity:sizeof random * 2];
    for (NSUInteger i = 0; i < sizeof random; i++)
        [cnonce appendFormat:@"%02x", random[i]];
    NSString *nc = @"00000001", *qop = @"auth";
    NSString *ha1 = md5_hex([NSString stringWithFormat:@"%@:%@:%@", [credential user], realm, [credential password]]);
    NSString *ha2 = md5_hex([NSString stringWithFormat:@"%@:%@", [request HTTPMethod], uri]);
    NSString *response = md5_hex([NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@", ha1, nonce, nc, cnonce, qop, ha2]);
    NSMutableString *header = [NSMutableString stringWithFormat:@"Digest username=%@, realm=%@, nonce=%@, uri=%@, response=%@, "
                                                                "algorithm=MD5, qop=auth, nc=%@, cnonce=%@",
                                digest_quote([credential user]), digest_quote(realm), digest_quote(nonce), digest_quote(uri),
                                digest_quote(response), nc, digest_quote(cnonce)];
    if (challenge[@"opaque"])
        [header appendFormat:@", opaque=%@", digest_quote(challenge[@"opaque"])];
    return header;
}

static NSURLCredentialStorage *
credential_store(void)
{
    return current_credentials_set ? current_credentials : [NSURLCredentialStorage sharedCredentialStorage];
}

/* The challenge's sender, for delegates that answer through it (NSURLConnection's way)
   rather than the completion handler. */
@interface FinchChallengeSender : NSObject <NSURLAuthenticationChallengeSender> {
  @public
    NSURLSessionAuthChallengeDisposition disposition;
    NSURLCredential *credential;
    BOOL answered;
}
@end

@implementation FinchChallengeSender
- (void)dealloc
{
    [credential release];
    [super dealloc];
}
- (void)answer:(NSURLSessionAuthChallengeDisposition)d credential:(NSURLCredential *)c
{
    disposition = d;
    [credential autorelease];
    credential = [c retain];
    answered = YES;
}
- (void)useCredential:(NSURLCredential *)c forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:NSURLSessionAuthChallengeUseCredential credential:c];
}
- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:NSURLSessionAuthChallengeUseCredential credential:nil];
}
- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:NSURLSessionAuthChallengeCancelAuthenticationChallenge credential:nil];
}
- (void)performDefaultHandlingForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:NSURLSessionAuthChallengePerformDefaultHandling credential:nil];
}
- (void)rejectProtectionSpaceAndContinueWithChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:NSURLSessionAuthChallengeRejectProtectionSpace credential:nil];
}
@end

@interface NSURLProtectionSpace (FinchServerTrust)
- (void)_finchSetServerTrust:(SecTrustRef)trust;
@end

@interface NSURLCredential (FinchServerTrust)
- (SecTrustRef)_finchTrust;
@end

static SecCertificateRef
certificate_from_x509(X509 *certificate)
{
    unsigned char *bytes = NULL;
    int length = i2d_X509(certificate, &bytes);
    if (length <= 0)
        return NULL;
    CFDataRef data = CFDataCreate(NULL, bytes, length);
    OPENSSL_free(bytes);
    if (!data)
        return NULL;
    SecCertificateRef result = SecCertificateCreateWithData(NULL, data);
    CFRelease(data);
    return result;
}

/* Turn the server's presented chain into the trust object NSURLSession gives its delegate. */
static SecTrustRef
server_trust(Connection *c, NSURL *url)
{
    X509 *leaf = SSL_get1_peer_certificate(c->ssl);
    if (!leaf)
        return NULL;
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (!certificates) {
        X509_free(leaf);
        return NULL;
    }
    SecCertificateRef first = certificate_from_x509(leaf);
    if (first) {
        CFArrayAppendValue(certificates, first);
        CFRelease(first);
    }
    STACK_OF(X509) *chain = SSL_get_peer_cert_chain(c->ssl);
    for (int i = 0; chain && i < sk_X509_num(chain); i++) {
        X509 *certificate = sk_X509_value(chain, i);
        if (X509_cmp(certificate, leaf) == 0)
            continue;
        SecCertificateRef item = certificate_from_x509(certificate);
        if (!item) {
            CFRelease(certificates);
            certificates = NULL;
            break;
        }
        CFArrayAppendValue(certificates, item);
        CFRelease(item);
    }
    X509_free(leaf);
    if (!certificates || !CFArrayGetCount(certificates)) {
        if (certificates)
            CFRelease(certificates);
        return NULL;
    }
    SecPolicyRef policy = SecPolicyCreateSSL(true, (CFStringRef)[url host]);
    SecTrustRef trust = NULL;
    if (policy)
        SecTrustCreateWithCertificates(certificates, policy, &trust);
    if (policy)
        CFRelease(policy);
    CFRelease(certificates);
    return trust;
}

static NSInteger
conn_server_trust(Connection *c, NSURL *url)
{
    if (!c->ssl)
        return 0;
    SecTrustRef trust = server_trust(c, url);
    if (!trust)
        return NSURLErrorSecureConnectionFailed;
    BOOL trusted = SecTrustEvaluateWithError(trust, NULL);
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    NSURLCredential *credential = nil;
    if (current_hooks && current_hooks->challenge) {
        NSString *scheme = [[url scheme] lowercaseString];
        NSInteger port = [url port] ? [[url port] integerValue] : 443;
        NSURLProtectionSpace *space = [[[NSURLProtectionSpace alloc]
            initWithHost:[url host]
                    port:port
                protocol:scheme
                   realm:nil
      authenticationMethod:NSURLAuthenticationMethodServerTrust] autorelease];
        [space _finchSetServerTrust:trust];
        FinchChallengeSender *sender = [[FinchChallengeSender new] autorelease];
        NSURLAuthenticationChallenge *challenge = [[[NSURLAuthenticationChallenge alloc]
            initWithProtectionSpace:space
                 proposedCredential:nil
               previousFailureCount:0
                    failureResponse:nil
                              error:nil
                             sender:sender] autorelease];
        disposition = current_hooks->challenge(challenge, &credential);
    }
    NSInteger error = 0;
    if (disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge)
        error = NSURLErrorCancelled;
    else if (disposition == NSURLSessionAuthChallengeRejectProtectionSpace)
        error = NSURLErrorServerCertificateUntrusted;
    else if (disposition == NSURLSessionAuthChallengeUseCredential && !trusted) {
        SecTrustRef credentialTrust = [credential _finchTrust];
        if (!credentialTrust || !CFEqual(credentialTrust, trust))
            error = NSURLErrorServerCertificateUntrusted;
    } else if (!trusted)
        error = NSURLErrorServerCertificateUntrusted;
    CFRelease(trust);
    return error;
}

/* Load a request, following up to 16 redirects (the delegate may stop one) and answering
   Basic and Digest password challenges: the delegate's credential, or by default the
   URL's user and password, then the protection space's default credential in the session's
   storage. A credential that works is kept there, if its persistence allows. */
static NSData *
load(NSURLRequest *request, NSURLResponse **outResponse, NSError **outError)
{
    NSURL *url = [request URL];
    NSString *scheme = [[url scheme] lowercaseString];
    *outResponse = nil;
    *outError = nil;
    if ([url isFileURL]) {
        NSURLSessionTaskTransactionMetrics *metrics = [current_metrics_collector beginTransactionForRequest:request];
        current_transaction_metrics = metrics;
        [metrics _finchSetDate:metric_now() field:FinchMetricRequestStart];
        NSError *e = nil;
        NSData *d = [NSData dataWithContentsOfURL:url options:0 error:&e];
        if (!d) {
            *outError = url_error(NSURLErrorFileDoesNotExist, url, @"The requested URL was not found on this server.");
            current_transaction_metrics = nil;
            return nil;
        }
        [metrics _finchSetDate:metric_now() field:FinchMetricRequestEnd];
        [metrics _finchSetDate:metric_now() field:FinchMetricResponseStart];
        *outResponse = [[[NSURLResponse alloc] initWithURL:url MIMEType:mime_for_extension([url pathExtension])
                                     expectedContentLength:(NSInteger)[d length] textEncodingName:nil] autorelease];
        [metrics _finchSetResponse:*outResponse];
        [metrics _finchSetResponseHeaderBytes:0 bodyBytes:(int64_t)[d length] decodedBytes:(int64_t)[d length]];
        [metrics _finchSetDate:metric_now() field:FinchMetricResponseEnd];
        current_transaction_metrics = nil;
        return d;
    }
    if ([scheme isEqualToString:@"data"]) {
        NSURLSessionTaskTransactionMetrics *metrics = [current_metrics_collector beginTransactionForRequest:request];
        current_transaction_metrics = metrics;
        [metrics _finchSetDate:metric_now() field:FinchMetricRequestStart];
        NSData *d = load_data_url(url, outResponse);
        if (!d)
            *outError = url_error(NSURLErrorBadURL, url, @"bad URL");
        [metrics _finchSetDate:metric_now() field:FinchMetricRequestEnd];
        [metrics _finchSetDate:metric_now() field:FinchMetricResponseStart];
        [metrics _finchSetResponse:*outResponse];
        [metrics _finchSetResponseHeaderBytes:0 bodyBytes:(int64_t)[d length] decodedBytes:(int64_t)[d length]];
        [metrics _finchSetDate:metric_now() field:FinchMetricResponseEnd];
        current_transaction_metrics = nil;
        return d;
    }
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        *outError = url_error(NSURLErrorUnsupportedURL, url, @"unsupported URL");
        return nil;
    }
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    Hooks *hooks = current_hooks;
    NSURLCredential *used = nil;
    NSURLProtectionSpace *usedSpace = nil;
    NSInteger failures = 0;
    for (int hops = 0; hops < 16 + 8; hops++) {
        NSURLSessionTaskTransactionMetrics *metrics = [current_metrics_collector beginTransactionForRequest:r];
        current_transaction_metrics = metrics;
        NSHTTPURLResponse *resp = nil;
        NSInteger code = 0;
        NSHTTPCookieStorage *jar = [r HTTPShouldHandleCookies] ? cookie_store() : nil;
        if (jar && ![r valueForHTTPHeaderField:@"Cookie"]) {
            NSString *cookie = [NSHTTPCookie requestHeaderFieldsWithCookies:[jar cookiesForURL:[r URL]]][@"Cookie"];
            if (cookie)
                [r setValue:cookie forHTTPHeaderField:@"Cookie"];
        }
        NSMutableArray *setCookies = [NSMutableArray array];
        NSData *d = load_http_once(r, [r URL], &resp, &code, setCookies);
        [metrics _finchSetResponse:resp];
        current_transaction_metrics = nil;
        if (jar && !code)
            for (NSString *line in setCookies)
                [jar setCookies:[NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie" : line} forURL:[r URL]]
                         forURL:[r URL]
                mainDocumentURL:[r mainDocumentURL] ?: [request mainDocumentURL] ?: [r URL]];
        /* (a redirect's next request gets its own cookies) */
        [r setValue:nil forHTTPHeaderField:@"Cookie"];
        if (code) {
            *outError = url_error(code, [r URL], nil);
            return nil;
        }
        NSInteger s = [resp statusCode];
        NSString *loc = [resp valueForHTTPHeaderField:@"Location"];
        NSDictionary *auth = http_authentication_parameters(resp, @"Digest");
        if (!auth)
            auth = http_authentication_parameters(resp, @"Basic");
        if (auth && failures < 8) {
            BOOL digest = [auth[@"scheme"] caseInsensitiveCompare:@"Digest"] == NSOrderedSame;
            NSURL *u = [r URL];
            NSString *scheme = [[u scheme] lowercaseString];
            NSInteger port = [u port] ? [[u port] integerValue] : [scheme isEqualToString:@"https"] ? 443 : 80;
            NSURLProtectionSpace *space = [[[NSURLProtectionSpace alloc]
                        initWithHost:[u host]
                                port:port
                            protocol:scheme
                               realm:[auth[@"realm"] length] ? auth[@"realm"] : nil
                authenticationMethod:digest ? NSURLAuthenticationMethodHTTPDigest : NSURLAuthenticationMethodHTTPBasic] autorelease];
            NSURLCredential *proposed = used ?: [credential_store() defaultCredentialForProtectionSpace:space];
            FinchChallengeSender *sender = [[FinchChallengeSender new] autorelease];
            NSURLAuthenticationChallenge *challenge = [[[NSURLAuthenticationChallenge alloc]
                initWithProtectionSpace:space
                     proposedCredential:proposed
                   previousFailureCount:failures
                        failureResponse:resp
                                  error:nil
                                 sender:sender] autorelease];
            NSURLCredential *credential = nil;
            NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
            if (hooks && hooks->challenge)
                disposition = hooks->challenge(challenge, &credential);
            if (disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge) {
                *outError = url_error(NSURLErrorCancelled, u, @"cancelled");
                return nil;
            }
            if (disposition != NSURLSessionAuthChallengeUseCredential) {
                credential = nil;
                if (failures == 0 && [u user])
                    credential = [NSURLCredential credentialWithUser:[[u user] stringByRemovingPercentEncoding]
                                                            password:[[u password] stringByRemovingPercentEncoding] ?: @""
                                                         persistence:NSURLCredentialPersistenceForSession];
                else if (failures == 0)
                    credential = proposed;
            }
            if ([credential user] && [credential password]) {
                NSString *value = nil;
                if (digest)
                    value = digest_authorization(credential, r, auth);
                else {
                    NSString *pair = [NSString stringWithFormat:@"%@:%@", [credential user], [credential password]];
                    value = [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
                }
                if (value) {
                    [r setValue:digest ? value : [@"Basic " stringByAppendingString:value]
                        forHTTPHeaderField:@"Authorization"];
                    used = credential;
                    usedSpace = space;
                    failures++;
                    continue;
                }
            }
        }
        if (used && s != 401 && [used persistence] != NSURLCredentialPersistenceNone) {
            NSURLCredentialStorage *store = credential_store();
            if (![store defaultCredentialForProtectionSpace:usedSpace])
                [store setDefaultCredential:used forProtectionSpace:usedSpace];
            else
                [store setCredential:used forProtectionSpace:usedSpace];
        }
        if ((s == 301 || s == 302 || s == 303 || s == 307 || s == 308) && loc) {
            NSMutableURLRequest *next = [[r mutableCopy] autorelease];
            [next setURL:[[NSURL URLWithString:loc relativeToURL:[r URL]] absoluteURL]];
            if (s == 303 || ((s == 301 || s == 302) && [[r HTTPMethod] isEqualToString:@"POST"])) {
                [next setHTTPMethod:@"GET"];
                [next setHTTPBody:nil];
            }
            /* (the next host gets no password meant for this one) */
            if (![[[next URL] host] isEqualToString:[[r URL] host]])
                [next setValue:nil forHTTPHeaderField:@"Authorization"];
            NSURLRequest *chosen = next;
            if (hooks && hooks->redirect)
                chosen = hooks->redirect(resp, next);
            if (chosen) {
                r = [[chosen mutableCopy] autorelease];
                [current_metrics_collector recordRedirect];
                continue;
            }
        }
        /* a final response the delegate hasn't had yet (a redirect it stopped, a challenge
           left unanswered) */
        if (hooks && hooks->response && !hooks->delivered) {
            hooks->delivered = YES;
            if (!hooks->response(resp)) {
                *outError = url_error(NSURLErrorCancelled, [r URL], @"cancelled");
                return nil;
            }
            if ([d length])
                hooks->data(d);
        }
        *outResponse = resp;
        return d;
    }
    *outError = url_error(NSURLErrorHTTPTooManyRedirects, [r URL], @"too many HTTP redirects");
    return nil;
}

#pragma mark - NSURLSessionConfiguration

@implementation NSURLSessionConfiguration {
    NSString *_identifier;
}

+ (NSURLSessionConfiguration *)defaultSessionConfiguration
{
    NSURLSessionConfiguration *c = [[[self alloc] init] autorelease];
    c.URLCache = [NSURLCache sharedURLCache];
    c.URLCredentialStorage = [NSURLCredentialStorage sharedCredentialStorage];
    c.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    return c;
}

/* (its own cache, in memory only) */
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration
{
    NSURLSessionConfiguration *c = [[[self alloc] init] autorelease];
    c.URLCache = [[[NSURLCache alloc] initWithMemoryCapacity:4 << 20 diskCapacity:0 directoryURL:nil] autorelease];
    c.HTTPCookieStorage = [[[NSHTTPCookieStorage alloc] init] autorelease]; /* (in memory, the session's own) */
    c.URLCredentialStorage = [[[NSURLCredentialStorage alloc] init] autorelease];
    return c;
}
+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier
{
    NSURLSessionConfiguration *c = [[[self alloc] init] autorelease];
    c->_identifier = [identifier copy];
    return c;
}

- (instancetype)init
{
    if ((self = [super init])) {
        self.timeoutIntervalForRequest = 60;
        self.timeoutIntervalForResource = 7 * 24 * 3600;
        self.allowsCellularAccess = YES;
        self.HTTPMaximumConnectionsPerHost = 6;
        self.HTTPShouldSetCookies = YES;
        self.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain;
        self.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }

- (id)copyWithZone:(NSZone *)zone
{
    NSURLSessionConfiguration *c = [[NSURLSessionConfiguration allocWithZone:zone] init];
    c->_identifier = [_identifier copy];
    c.timeoutIntervalForRequest = self.timeoutIntervalForRequest;
    c.timeoutIntervalForResource = self.timeoutIntervalForResource;
    c.HTTPAdditionalHeaders = self.HTTPAdditionalHeaders;
    c.requestCachePolicy = self.requestCachePolicy;
    c.allowsCellularAccess = self.allowsCellularAccess;
    c.URLCache = self.URLCache;
    c.protocolClasses = self.protocolClasses;
    c.HTTPShouldSetCookies = self.HTTPShouldSetCookies;
    c.HTTPCookieStorage = self.HTTPCookieStorage;
    c.HTTPCookieAcceptPolicy = self.HTTPCookieAcceptPolicy;
    c.URLCredentialStorage = self.URLCredentialStorage;
    c.HTTPMaximumConnectionsPerHost = self.HTTPMaximumConnectionsPerHost;
    return c;
}

@end

#pragma mark - Tasks

NSData *_FinchURLLoad(NSURLSessionConfiguration *configuration, NSURLSessionTask *task, NSURLRequest *request,
    NSURLResponse **outResponse, NSError **outError, NSData *(*plain)(NSURLRequest *, NSURLResponse **, NSError **));

@interface NSURLSessionTask ()
- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download
                           completion:(void (^)(id result, NSURLResponse *response, NSError *error))completion;
- (void)_finchSetResumeInfo:(NSDictionary *)info;
- (BOOL)_finchEverResumed;
- (void)_finchHooks:(Hooks *)h dataDelegate:(BOOL)dataDelegate;
@end

@implementation NSURLSessionTask {
    NSURLSession *_session; /* retained while running, as Apple's */
    NSURLRequest *_original;
    NSURLResponse *_response;
    NSError *_error;
    NSUInteger _identifier;
    NSURLSessionTaskState _state;
    BOOL _download;
    int64_t _received, _expected;
    void (^_completion)(id, NSURLResponse *, NSError *);
    NSString *_description;
    float _priority;
    Download *_loading;              /* a download's, while it loads */
    NSDictionary *_resumeInfo;       /* a resumed download's resume data */
    void (^_resumeHandler)(NSData *); /* cancelByProducingResumeData:'s */
    BOOL _loadsToFile;               /* (an http(s) download, which counts its bytes as it writes) */
    FinchURLTaskMetricsCollector *_metricsCollector;
    NSURLSessionTaskMetrics *_taskMetrics;
    BOOL _everResumed, _paused; /* (suspended after starting: the load goes on, the state says suspended) */
}

- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download completion:(void (^)(id, NSURLResponse *, NSError *))completion
{
    if ((self = [super init])) {
        _session = [session retain];
        _original = [request copy];
        _identifier = ident;
        _download = download;
        _completion = [completion copy];
        _state = NSURLSessionTaskStateSuspended;
        _expected = NSURLSessionTransferSizeUnknown;
        _priority = NSURLSessionTaskPriorityDefault;
        _metricsCollector = [[FinchURLTaskMetricsCollector alloc] initWithTaskStartDate:[NSDate date]];
    }
    return self;
}

- (void)dealloc
{
    [_session release];
    [_original release];
    [_response release];
    [_error release];
    [_completion release];
    [_description release];
    [_resumeInfo release];
    [_resumeHandler release];
    [_metricsCollector release];
    [_taskMetrics release];
    [super dealloc];
}

- (void)_finchSetResumeInfo:(NSDictionary *)info
{
    [_resumeInfo autorelease];
    _resumeInfo = [info copy];
}

- (NSUInteger)taskIdentifier { return _identifier; }
- (NSURLRequest *)originalRequest { return _original; }
- (NSURLRequest *)currentRequest { return _original; }
- (NSURLResponse *)response { return _response; }
- (NSError *)error { return _error; }
- (NSURLSessionTaskState)state
{
    @synchronized(self) {
        return _paused && _state == NSURLSessionTaskStateRunning ? NSURLSessionTaskStateSuspended : _state;
    }
}
- (BOOL)_finchEverResumed { return _everResumed; }
- (int64_t)countOfBytesReceived { return _received; }
- (int64_t)countOfBytesSent { return 0; }
- (int64_t)countOfBytesExpectedToSend { return 0; }
- (int64_t)countOfBytesExpectedToReceive { return _expected; }
- (NSString *)taskDescription { return _description; }
- (void)setTaskDescription:(NSString *)d
{
    [_description autorelease];
    _description = [d copy];
}
- (float)priority { return _priority; }
- (void)setPriority:(float)p { _priority = p; }
- (NSProgress *)progress { return [NSProgress progressWithTotalUnitCount:_expected > 0 ? _expected : -1]; }

- (void)resume
{
    @synchronized(self) {
        if (_paused) {
            _paused = NO;
            return;
        }
        if (_state != NSURLSessionTaskStateSuspended)
            return;
        _state = NSURLSessionTaskStateRunning;
        _everResumed = YES;
    }
    [self retain];
    NSURLRequest *request = _original;
    BOOL download = _download;
    NSURLSessionConfiguration *configuration = [[_session.configuration retain] autorelease];
    NSString *scheme = [[[request URL] scheme] lowercaseString];
    if (download && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        _loadsToFile = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [self _finchDownload:request configuration:configuration];
          [self release];
        });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSURLResponse *response = nil;
      NSError *error = nil;
      Hooks hooks = {0};
      [self _finchHooks:&hooks dataDelegate:!download];
      /* (through the cache and any protocol classes, NSURLCache.m) */
      [self _finchEnterLoad:configuration hooks:&hooks];
      current_metrics_collector = _metricsCollector;
      NSData *data = _FinchURLLoad(configuration, self, request, &response, &error, load);
      current_transaction_metrics = nil;
      current_metrics_collector = nil;
      [self _finchLeaveLoad];
      /* (what the cache or a protocol answered, the delegate gets now) */
      if (data && hooks.response && !hooks.delivered) {
          if (hooks.response(response))
              hooks.data(data);
          else
              data = nil, error = url_error(NSURLErrorCancelled, [request URL], @"cancelled");
          hooks.delivered = YES;
      }
      id result = hooks.delivered ? nil : data;
      if (data && download) {
          NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                      [NSString stringWithFormat:@"CFNetworkDownload_%@.tmp", [[NSUUID UUID] UUIDString]]];
          result = [data writeToFile:tmp atomically:YES] ? [NSURL fileURLWithPath:tmp] : nil;
      }
      [self _finchFinishWithResult:result response:response error:error];
      [self release];
    });
}

/* Wait on the delegate queue for what block, run there, hands to done. */
static void
on_delegate_queue(NSURLSession *session, void (^block)(dispatch_semaphore_t done))
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [session.delegateQueue addOperationWithBlock:^{
      block(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
}

/* The hooks for what this task's delegate takes part in (dataDelegate: the response and data,
   for a data task without a completion handler). */
- (void)_finchHooks:(Hooks *)h dataDelegate:(BOOL)dataDelegate
{
    id d = [_session delegate];
    NSURLSession *session = [[_session retain] autorelease];
    if (!d)
        return;
    if ([d respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)])
        h->redirect = [[^NSURLRequest *(NSHTTPURLResponse *response, NSURLRequest *proposed) {
          __block NSURLRequest *chosen = nil;
          on_delegate_queue(session, ^(dispatch_semaphore_t done) {
            [(id<NSURLSessionTaskDelegate>)d URLSession:session task:self willPerformHTTPRedirection:response newRequest:proposed
                                      completionHandler:^(NSURLRequest *r) {
                                        chosen = [r copy];
                                        dispatch_semaphore_signal(done);
                                      }];
          });
          return [chosen autorelease];
        } copy] autorelease];
    BOOL taskChallenge = [d respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)];
    BOOL sessionChallenge = !taskChallenge && [d respondsToSelector:@selector(URLSession:didReceiveChallenge:completionHandler:)];
    if (taskChallenge || sessionChallenge)
        h->challenge = [[^NSURLSessionAuthChallengeDisposition(NSURLAuthenticationChallenge *challenge, NSURLCredential **out) {
          __block NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
          __block NSURLCredential *credential = nil;
          dispatch_semaphore_t done = dispatch_semaphore_create(0);
          void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) = [[^
              (NSURLSessionAuthChallengeDisposition answer, NSURLCredential *c) {
                  disposition = answer;
                  credential = [c retain];
                  dispatch_semaphore_signal(done);
              } copy] autorelease];
          [session.delegateQueue addOperationWithBlock:^{
            if (taskChallenge)
                [(id<NSURLSessionTaskDelegate>)d URLSession:session task:self didReceiveChallenge:challenge completionHandler:completion];
            else
                [(id<NSURLSessionDelegate>)d URLSession:session didReceiveChallenge:challenge completionHandler:completion];
          }];
          dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
          dispatch_release(done);
          *out = [credential autorelease];
          return disposition;
        } copy] autorelease];
    if (!dataDelegate || _completion)
        return;
    BOOL asks = [d respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)];
    h->response = [[^BOOL(NSURLResponse *response) {
      @synchronized(self) {
          [_response autorelease];
          _response = [response retain];
          _expected = [response expectedContentLength];
      }
      if (!asks)
          return YES;
      __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
      on_delegate_queue(session, ^(dispatch_semaphore_t done) {
        [(id<NSURLSessionDataDelegate>)d URLSession:session dataTask:(NSURLSessionDataTask *)self didReceiveResponse:response
                                  completionHandler:^(NSURLSessionResponseDisposition answer) {
                                    disposition = answer;
                                    dispatch_semaphore_signal(done);
                                  }];
      });
      return disposition != NSURLSessionResponseCancel;
    } copy] autorelease];
    BOOL takes = [d respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)];
    h->data = [[^(NSData *data) {
      @synchronized(self) {
          _received += (int64_t)[data length];
      }
      if (takes)
          [session.delegateQueue addOperationWithBlock:^{
            [(id<NSURLSessionDataDelegate>)d URLSession:session dataTask:(NSURLSessionDataTask *)self didReceiveData:data];
          }];
    } copy] autorelease];
}

/* This thread's session state for a load: the cookies, credentials and delegate hooks. */
- (void)_finchEnterLoad:(NSURLSessionConfiguration *)configuration hooks:(Hooks *)hooks
{
    current_cookies = configuration.HTTPShouldSetCookies && configuration.HTTPCookieAcceptPolicy != NSHTTPCookieAcceptPolicyNever
                          ? configuration.HTTPCookieStorage
                          : nil;
    current_cookies_set = YES;
    current_credentials = configuration.URLCredentialStorage;
    current_credentials_set = YES;
    current_hooks = hooks;
}

- (void)_finchLeaveLoad
{
    current_cookies = nil;
    current_cookies_set = NO;
    current_credentials = nil;
    current_credentials_set = NO;
    current_hooks = NULL;
}

/* An http(s) download: its body streamed into a file in the temporary folder (not through the
   cache) and, when the load fails after a successful response with a validator (ETag or
   Last-Modified), resume data in the error to continue it from where it stopped, with a
   Range request (downloadTaskWithResumeData:). A cancel cuts the connection; with
   cancelByProducingResumeData:, the handler gets the resume data too. */
- (void)_finchDownload:(NSURLRequest *)request configuration:(NSURLSessionConfiguration *)configuration
{
    NSDictionary *resume = _resumeInfo;
    NSString *path = resume[@"NSURLSessionResumeInfoLocalPath"];
    int64_t offset = [resume[@"NSURLSessionResumeBytesReceived"] longLongValue];
    NSString *validator = resume[@"NSURLSessionResumeEntityTag"] ?: resume[@"NSURLSessionResumeServerDownloadDate"];
    struct stat st;
    if (resume && !(path && stat([path fileSystemRepresentation], &st) == 0 && st.st_size >= offset))
        path = nil, offset = 0; /* (the partial file is gone: start again) */
    if (!path)
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                           [NSString stringWithFormat:@"CFNetworkDownload_%@.tmp", [[NSUUID UUID] UUIDString]]];
    Download dl = {.fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT, 0600), .offset = offset, .sock = -1,
                   .expected = -1, .lock = OS_UNFAIR_LOCK_INIT};
    if (dl.fd < 0) {
        [self _finchFinishWithResult:nil response:nil
                               error:url_error(NSURLErrorCannotCreateFile, [request URL], @"cannot create file")];
        return;
    }
    if (offset > 0) {
        NSMutableURLRequest *r = [[request mutableCopy] autorelease];
        [r setValue:[NSString stringWithFormat:@"bytes=%lld-", offset] forHTTPHeaderField:@"Range"];
        if (validator)
            [r setValue:validator forHTTPHeaderField:@"If-Range"];
        request = r;
    }
    __block Download *dp = &dl;
    id delegate = [_session delegate];
    NSURLSession *session = [[_session retain] autorelease];
    BOOL reports = !_completion && [delegate respondsToSelector:@selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)];
    __block atomic_bool pending = NO;
    __block int64_t reported = offset;
    dl.progress = ^{
      @synchronized(self) {
          _received = dp->written;
          _expected = dp->expected;
      }
      /* (one report waiting on the delegate queue at a time, with all written by then) */
      if (reports && !atomic_exchange(&pending, YES))
          [session.delegateQueue addOperationWithBlock:^{
            atomic_store(&pending, NO);
            int64_t written, expected;
            @synchronized(self) {
                written = _received;
                expected = _expected;
            }
            if (written == reported)
                return;
            [(id<NSURLSessionDownloadDelegate>)delegate URLSession:session downloadTask:(NSURLSessionDownloadTask *)self
                                                      didWriteData:written - reported
                                                 totalBytesWritten:written
                                         totalBytesExpectedToWrite:expected];
            reported = written;
          }];
    };
    if (!_completion && [delegate respondsToSelector:@selector(URLSession:downloadTask:didResumeAtOffset:expectedTotalBytes:)])
        dl.resumed = ^{
          int64_t at = dp->offset, total = dp->expected;
          [session.delegateQueue addOperationWithBlock:^{
            [(id<NSURLSessionDownloadDelegate>)delegate URLSession:session downloadTask:(NSURLSessionDownloadTask *)self
                                                 didResumeAtOffset:at
                                                expectedTotalBytes:total];
          }];
        };
    @synchronized(self) {
        _loading = &dl;
    }
    NSURLResponse *response = nil;
    NSError *error = nil;
    Hooks hooks = {0};
    [self _finchHooks:&hooks dataDelegate:NO];
    [self _finchEnterLoad:configuration hooks:&hooks];
    current_metrics_collector = _metricsCollector;
    current_download = &dl;
    load(request, &response, &error);
    current_download = NULL;
    current_transaction_metrics = nil;
    current_metrics_collector = nil;
    [self _finchLeaveLoad];
    void (^handler)(NSData *) = nil;
    BOOL finished;
    @synchronized(self) {
        _loading = NULL;
        handler = [[_resumeHandler retain] autorelease];
        finished = _state == NSURLSessionTaskStateCompleted;
        _received = dl.written;
        _expected = dl.expected;
    }
    close(dl.fd);
    NSHTTPURLResponse *got = [dl.response autorelease];
    NSData *resumeData = nil;
    if (error || dl.cancelled) {
        NSString *etag = [got valueForHTTPHeaderField:@"ETag"], *date = [got valueForHTTPHeaderField:@"Last-Modified"];
        if (got && dl.written > 0 && (etag || date) && [[request HTTPMethod] isEqualToString:@"GET"] && (handler || !finished)) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"NSURLSessionResumeInfoVersion"] = @2;
            info[@"NSURLSessionDownloadURL"] = [[_original URL] absoluteString];
            info[@"NSURLSessionResumeBytesReceived"] = @(dl.written);
            info[@"NSURLSessionResumeInfoLocalPath"] = path;
            info[@"NSURLSessionResumeInfoTempFileName"] = [path lastPathComponent];
            if (etag)
                info[@"NSURLSessionResumeEntityTag"] = etag;
            if (date)
                info[@"NSURLSessionResumeServerDownloadDate"] = date;
            if ([_original allHTTPHeaderFields])
                info[@"NSURLSessionResumeOriginalRequestHeaders"] = [_original allHTTPHeaderFields];
            resumeData = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0
                                                                     error:NULL];
        } else {
            unlink([path fileSystemRepresentation]);
        }
        if (dl.cancelled)
            error = url_error(NSURLErrorCancelled, [_original URL], @"cancelled");
        if (resumeData) {
            NSMutableDictionary *userInfo = [[[error userInfo] mutableCopy] autorelease];
            userInfo[NSURLSessionDownloadTaskResumeData] = resumeData;
            error = [NSError errorWithDomain:[error domain] code:[error code] userInfo:userInfo];
        }
        if (handler)
            handler(resumeData);
        [self _finchFinishWithResult:nil response:response error:error];
        return;
    }
    if (finished) {
        unlink([path fileSystemRepresentation]);
        return;
    }
    [self _finchFinishWithResult:[NSURL fileURLWithPath:path] response:response error:nil];
}

/* Cut a download's connection, if it's loading; it ends with NSURLErrorCancelled. */
- (BOOL)_finchInterruptDownload
{
    @synchronized(self) {
        if (!_loading)
            return NO;
        os_unfair_lock_lock(&_loading->lock);
        _loading->cancelled = YES;
        if (_loading->sock >= 0)
            shutdown(_loading->sock, SHUT_RDWR);
        os_unfair_lock_unlock(&_loading->lock);
        return YES;
    }
}

- (void)_finchCancelProducingResumeData:(void (^)(NSData *))handler
{
    @synchronized(self) {
        if (_loading && !_resumeHandler) {
            _resumeHandler = [handler copy];
            [self _finchInterruptDownload];
            return;
        }
    }
    [self cancel];
    if (handler)
        handler(nil);
}

- (void)_finchFinishWithResult:(id)result response:(NSURLResponse *)response error:(NSError *)error
{
    @synchronized(self) {
        if (_state == NSURLSessionTaskStateCompleted)
            return;
        _state = NSURLSessionTaskStateCompleted;
        [_taskMetrics release];
        _taskMetrics = [[_metricsCollector metricsForEndDate:[NSDate date] request:_original response:response] retain];
        if (response) {
            [_response release];
            _response = [response retain];
        }
        _error = [error retain];
        if (result && !_loadsToFile)
            _received = [result isKindOfClass:[NSData class]] ? (int64_t)[result length] : [response expectedContentLength];
    }
    void (^completion)(id, NSURLResponse *, NSError *) = [[_completion retain] autorelease];
    NSURLSession *session = [[_session retain] autorelease];
    [session.delegateQueue addOperationWithBlock:^{
      if (completion) {
          completion(result, response, error);
      } else {
          id d = session.delegate;
          if (result && [result isKindOfClass:[NSData class]] && [d respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)])
              [(id<NSURLSessionDataDelegate>)d URLSession:session dataTask:(NSURLSessionDataTask *)self didReceiveData:result];
          if (result && [result isKindOfClass:[NSURL class]] &&
              [d respondsToSelector:@selector(URLSession:downloadTask:didFinishDownloadingToURL:)])
              [(id<NSURLSessionDownloadDelegate>)d URLSession:session downloadTask:(NSURLSessionDownloadTask *)self
                                    didFinishDownloadingToURL:result];
          if ([d respondsToSelector:@selector(URLSession:task:didFinishCollectingMetrics:)])
              [(id<NSURLSessionTaskDelegate>)d URLSession:session task:self didFinishCollectingMetrics:_taskMetrics];
          if ([d respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
              [(id<NSURLSessionTaskDelegate>)d URLSession:session task:self didCompleteWithError:error];
      }
      if ([result isKindOfClass:[NSURL class]])
          [[NSFileManager defaultManager] removeItemAtURL:result error:NULL];
    }];
    [_session release];
    _session = nil;
}

- (void)cancel
{
    [self _finchInterruptDownload];
    [self _finchFinishWithResult:nil response:nil
                           error:url_error(NSURLErrorCancelled, [_original URL], @"cancelled")];
}

- (void)suspend
{
    @synchronized(self) {
        if (_state == NSURLSessionTaskStateRunning)
            _paused = YES;
    }
}

/* For the socket tasks (NSURLSessionSockets.m). */
- (NSURLSession *)_finchSession { return _session; }

- (void)_finchSetResponse:(NSURLResponse *)response
{
    @synchronized(self) {
        [_response autorelease];
        _response = [response retain];
    }
}

- (BOOL)_finchStartRunning
{
    @synchronized(self) {
        if (_paused) {
            _paused = NO;
            return NO;
        }
        if (_state != NSURLSessionTaskStateSuspended)
            return NO;
        _state = NSURLSessionTaskStateRunning;
        _everResumed = YES;
        return YES;
    }
}

- (void)_finchFinishQuietly
{
    @synchronized(self) {
        if (_state == NSURLSessionTaskStateCompleted)
            return;
        _state = NSURLSessionTaskStateCompleted;
    }
    [_session release];
    _session = nil;
}

@end

/* An http(s) connection for a task, its server trust answered by the task's delegate. */
NSInteger
_FinchURLTaskConnect(NSURLSessionTask *task, Connection *c, NSURL *url, NSTimeInterval timeout)
{
    @autoreleasepool {
        Hooks hooks = {0};
        [task _finchHooks:&hooks dataDelegate:NO];
        current_hooks = &hooks;
        NSInteger error = conn_open(c, url, timeout);
        if (!error)
            error = conn_server_trust(c, url);
        current_hooks = NULL;
        if (error)
            conn_close(c);
        return error;
    }
}

NSInteger
_FinchURLTaskStartTLS(NSURLSessionTask *task, Connection *c, NSString *host)
{
    @autoreleasepool {
        c->ctx = SSL_CTX_new(TLS_client_method());
        SSL_CTX_set_min_proto_version(c->ctx, TLS1_2_VERSION);
        SSL_CTX_set_verify(c->ctx, SSL_VERIFY_NONE, NULL);
        c->ssl = SSL_new(c->ctx);
        SSL_set_tlsext_host_name(c->ssl, [host UTF8String]);
        BIO *bio = BIO_new(fd_bio_method());
        BIO_set_data(bio, (void *)(intptr_t)c->fd);
        BIO_set_init(bio, 1);
        SSL_set_bio(c->ssl, bio, bio);
        if (SSL_connect(c->ssl) != 1)
            return NSURLErrorSecureConnectionFailed;
        Hooks hooks = {0};
        [task _finchHooks:&hooks dataDelegate:NO];
        current_hooks = &hooks;
        NSURLComponents *u = [[NSURLComponents new] autorelease];
        u.scheme = @"https";
        u.host = host;
        NSInteger error = conn_server_trust(c, u.URL);
        current_hooks = NULL;
        return error;
    }
}

@implementation NSURLSessionDataTask
@end
@implementation NSURLSessionUploadTask
- (void)cancelByProducingResumeData:(void (^)(NSData *))completionHandler
{
    [self _finchCancelProducingResumeData:completionHandler];
}
@end
@implementation NSURLSessionDownloadTask
- (void)cancelByProducingResumeData:(void (^)(NSData *))handler
{
    [self _finchCancelProducingResumeData:handler];
}
@end

#pragma mark - NSURLSession

@implementation NSURLSession {
    NSURLSessionConfiguration *_configuration;
    id<NSURLSessionDelegate> _delegate;
    NSOperationQueue *_queue;
    NSUInteger _nextIdentifier;
    NSString *_description;
    NSHashTable *_tasks; /* (weak) the tasks made, for -getAllTasksWithCompletionHandler: */
}

+ (NSURLSession *)sharedSession
{
    static NSURLSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[NSURLSession alloc] _finchInitWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                        delegate:nil queue:nil];
    });
    return shared;
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
{
    return [self sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue
{
    return [[[self alloc] _finchInitWithConfiguration:configuration delegate:delegate queue:queue] autorelease];
}

- (instancetype)_finchInitWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate queue:(NSOperationQueue *)queue
{
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _delegate = [delegate retain]; /* as Apple's: until invalidated */
        if (queue) {
            _queue = [queue retain];
        } else {
            _queue = [NSOperationQueue new];
            _queue.maxConcurrentOperationCount = 1;
        }
        _nextIdentifier = 1;
        _tasks = [[NSHashTable weakObjectsHashTable] retain];
    }
    return self;
}

- (void)dealloc
{
    [_configuration release];
    [_delegate release];
    [_queue release];
    [_description release];
    [_tasks release];
    [super dealloc];
}

- (NSURLSessionConfiguration *)configuration { return [[_configuration copy] autorelease]; }
- (id<NSURLSessionDelegate>)delegate { return _delegate; }
- (NSOperationQueue *)delegateQueue { return _queue; }
- (NSString *)sessionDescription { return _description; }
- (void)setSessionDescription:(NSString *)d
{
    [_description autorelease];
    _description = [d copy];
}

/* The request with the configuration's timeout and extra headers. */
- (NSURLRequest *)_finchPrepare:(NSURLRequest *)request
{
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    if ([request timeoutInterval] == 60)
        [r setTimeoutInterval:_configuration.timeoutIntervalForRequest];
    NSDictionary *extra = _configuration.HTTPAdditionalHeaders;
    for (NSString *k in extra)
        if (![r valueForHTTPHeaderField:k])
            [r setValue:[extra[k] description] forHTTPHeaderField:k];
    return r;
}

- (id)_finchTask:(Class)cls request:(NSURLRequest *)request download:(BOOL)download completion:(id)completion
{
    NSUInteger ident;
    @synchronized(self) {
        ident = _nextIdentifier++;
    }
    id task = [[[cls alloc] _finchInitWithSession:self request:[self _finchPrepare:request] identifier:ident download:download
                                       completion:completion] autorelease];
    @synchronized(self) {
        [_tasks addObject:task];
    }
    return task;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    return [self _finchTask:[NSURLSessionDataTask class] request:request download:NO completion:nil];
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url { return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url]]; }
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    return [self _finchTask:[NSURLSessionDataTask class] request:request download:NO completion:completionHandler];
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completionHandler];
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
{
    return [self _finchTask:[NSURLSessionDownloadTask class] request:request download:YES completion:nil];
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url { return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:url]]; }
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    return [self _finchTask:[NSURLSessionDownloadTask class] request:request download:YES completion:completionHandler];
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url
                                completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completionHandler];
}
/* (resume data from Finch's downloads; anything else gives a task that fails) */
- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                       completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    id info = resumeData ? [NSPropertyListSerialization propertyListWithData:resumeData options:0 format:NULL error:NULL] : nil;
    NSString *url = [info isKindOfClass:[NSDictionary class]] ? info[@"NSURLSessionDownloadURL"] : nil;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[url isKindOfClass:[NSString class]] ? url : @"finch-invalid-resume-data:"]];
    NSDictionary *headers = [info isKindOfClass:[NSDictionary class]] ? info[@"NSURLSessionResumeOriginalRequestHeaders"] : nil;
    if ([headers isKindOfClass:[NSDictionary class]])
        [r setAllHTTPHeaderFields:headers];
    NSURLSessionDownloadTask *task = [self _finchTask:[NSURLSessionDownloadTask class] request:r download:YES completion:completionHandler];
    if (url)
        [(NSURLSessionTask *)task _finchSetResumeInfo:info];
    return task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
{
    return [self downloadTaskWithResumeData:resumeData completionHandler:(id _Nonnull)nil];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    [r setHTTPBody:bodyData];
    return [self _finchTask:[NSURLSessionUploadTask class] request:r download:NO completion:completionHandler];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData
{
    return [self uploadTaskWithRequest:request fromData:bodyData completionHandler:(id _Nonnull)nil];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    /* (the file goes with the request privately, as Apple's keeps it out of the request's body) */
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    if (fileURL)
        [NSURLProtocol setProperty:fileURL forKey:@"_FinchUploadFile" inRequest:r];
    return [self _finchTask:[NSURLSessionUploadTask class] request:r download:NO completion:completionHandler];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL
{
    return [self uploadTaskWithRequest:request fromFile:fileURL completionHandler:(id _Nonnull)nil];
}
/* (the request's body stream; Finch doesn't ask the delegate for another) */
- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
{
    return [self _finchTask:[NSURLSessionUploadTask class] request:request download:NO completion:nil];
}
/* (Finch's uploads don't make resume data, so any gives a task that fails) */
- (NSURLSessionUploadTask *)uploadTaskWithResumeData:(NSData *)resumeData
                                   completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:@"finch-invalid-resume-data:"]];
    return [self _finchTask:[NSURLSessionUploadTask class] request:r download:NO completion:completionHandler];
}
- (NSURLSessionUploadTask *)uploadTaskWithResumeData:(NSData *)resumeData
{
    return [self uploadTaskWithResumeData:resumeData completionHandler:(id _Nonnull)nil];
}

- (void)finishTasksAndInvalidate
{
    id d = _delegate;
    [_queue addOperationWithBlock:^{
      if ([d respondsToSelector:@selector(URLSession:didBecomeInvalidWithError:)])
          [d URLSession:self didBecomeInvalidWithError:nil];
    }];
}

- (void)invalidateAndCancel
{
    for (NSURLSessionTask *t in [self _finchLiveTasks:NO])
        [t cancel];
    [self finishTasksAndInvalidate];
}

/* The tasks not yet completed, in the order they were made (as Apple's lists them: only
   those that were ever resumed). */
- (NSArray *)_finchLiveTasks:(BOOL)resumedOnly
{
    NSArray *all;
    @synchronized(self) {
        all = [_tasks allObjects];
    }
    NSMutableArray *live = [NSMutableArray array];
    for (NSURLSessionTask *t in all)
        if ([t state] != NSURLSessionTaskStateCompleted && (!resumedOnly || [t _finchEverResumed]))
            [live addObject:t];
    [live sortUsingComparator:^NSComparisonResult(NSURLSessionTask *a, NSURLSessionTask *b) {
      return a.taskIdentifier < b.taskIdentifier ? NSOrderedAscending : a.taskIdentifier > b.taskIdentifier ? NSOrderedDescending : NSOrderedSame;
    }];
    return live;
}

- (void)getTasksWithCompletionHandler:(void (^)(NSArray<NSURLSessionDataTask *> *, NSArray<NSURLSessionUploadTask *> *,
                                          NSArray<NSURLSessionDownloadTask *> *))completionHandler
{
    NSArray *live = [self _finchLiveTasks:YES];
    NSMutableArray *data = [NSMutableArray array], *uploads = [NSMutableArray array], *downloads = [NSMutableArray array];
    for (NSURLSessionTask *t in live) {
        if ([t isKindOfClass:[NSURLSessionUploadTask class]]) [uploads addObject:t];
        else if ([t isKindOfClass:[NSURLSessionDataTask class]]) [data addObject:t];
        else if ([t isKindOfClass:[NSURLSessionDownloadTask class]]) [downloads addObject:t];
    }
    completionHandler = [[completionHandler copy] autorelease];
    [_queue addOperationWithBlock:^{ completionHandler(data, uploads, downloads); }];
}
- (void)resetWithCompletionHandler:(void (^)(void))completionHandler { [_queue addOperationWithBlock:completionHandler]; }
- (void)flushWithCompletionHandler:(void (^)(void))completionHandler { [_queue addOperationWithBlock:completionHandler]; }
- (void)getAllTasksWithCompletionHandler:(void (^)(NSArray<__kindof NSURLSessionTask *> *))completionHandler
{
    NSArray *live = [self _finchLiveTasks:YES];
    completionHandler = [[completionHandler copy] autorelease];
    [_queue addOperationWithBlock:^{ completionHandler(live); }];
}

@end

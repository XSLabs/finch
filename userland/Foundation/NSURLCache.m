/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURLCache and NSCachedURLResponse, and NSURLProtocol with its client, and the path a
 * session's task loads by through them (NSURLSession.m calls _FinchURLLoad).
 *
 * The cache keeps responses by URL, as Apple's does (the method and headers don't enter
 * into it), in memory and, unless a response is memory-only, on disk under its
 * directory as archives. Capacities are honoured by dropping the oldest entries.
 *
 * A task's request goes first to the cache, by its cache policy: a fresh HTTP response
 * (max-age or Expires) answers a request that uses the protocol's policy, any cached
 * response answers one that prefers the cache, and a request that may only use the
 * cache fails with NSURLErrorResourceUnavailable when nothing's there. Otherwise it goes
 * to the first protocol class (the configuration's, then those registered) that takes
 * it, run to completion, its redirects followed; failing that, to Finch's own loading.
 * A custom protocol is always asked (it keeps its own cache), as with Apple's. What's
 * loaded is stored when it is a GET's successful response and its policy allows.
 */
#import <Foundation/Foundation.h>

/* --- request properties (kept on NSURLRequest, NSURLSession.m) --- */

@interface NSURLRequest (FinchProperties)
- (id)_finchPropertyForKey:(NSString *)key;
- (void)_finchSetProperty:(id)value forKey:(NSString *)key;
- (void)_finchRemovePropertyForKey:(NSString *)key;
@end

/* --- NSCachedURLResponse --- */

@implementation NSCachedURLResponse {
    NSURLResponse *_response;
    NSData *_data;
    NSDictionary *_userInfo;
    NSURLCacheStoragePolicy _policy;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithResponse:(NSURLResponse *)response data:(NSData *)data
{
    return [self initWithResponse:response data:data userInfo:nil storagePolicy:NSURLCacheStorageAllowed];
}

- (instancetype)initWithResponse:(NSURLResponse *)response data:(NSData *)data userInfo:(NSDictionary *)userInfo
                   storagePolicy:(NSURLCacheStoragePolicy)storagePolicy
{
    if ((self = [super init])) {
        _response = [response copy];
        _data = [data copy];
        _userInfo = [userInfo copy];
        _policy = storagePolicy;
    }
    return self;
}

- (void)dealloc
{
    [_response release];
    [_data release];
    [_userInfo release];
    [super dealloc];
}

- (NSURLResponse *)response { return _response; }
- (NSData *)data { return _data; }
- (NSDictionary *)userInfo { return _userInfo; }
- (NSURLCacheStoragePolicy)storagePolicy { return _policy; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_response forKey:@"response"];
    [coder encodeObject:_data forKey:@"data"];
    [coder encodeObject:_userInfo forKey:@"userInfo"];
    [coder encodeInteger:(NSInteger)_policy forKey:@"storagePolicy"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *plist = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [NSData class],
                          [NSDate class], nil];
    return [self initWithResponse:[coder decodeObjectOfClass:[NSURLResponse class] forKey:@"response"]
                             data:[coder decodeObjectOfClass:[NSData class] forKey:@"data"]
                         userInfo:[coder decodeObjectOfClasses:plist forKey:@"userInfo"]
                    storagePolicy:(NSURLCacheStoragePolicy)[coder decodeIntegerForKey:@"storagePolicy"]];
}

@end

/* --- NSURLCache --- */

@implementation NSURLCache {
    NSUInteger _memoryCapacity, _diskCapacity;
    NSURL *_directory;
    NSMutableDictionary<NSString *, NSCachedURLResponse *> *_memory;
    NSMutableArray<NSString *> *_order; /* (oldest first) */
}

static NSURLCache *shared_cache;

+ (NSURLCache *)sharedURLCache
{
    @synchronized(self) {
        if (!shared_cache) {
            NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSString *name = [[NSBundle mainBundle] bundleIdentifier] ?: [[NSProcessInfo processInfo] processName];
            NSURL *dir = caches ? [NSURL fileURLWithPath:[[caches stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Cache.db"]]
                                : nil;
            shared_cache = [[NSURLCache alloc] initWithMemoryCapacity:4 << 20 diskCapacity:20 << 20 directoryURL:dir];
        }
        return [[shared_cache retain] autorelease];
    }
}

+ (void)setSharedURLCache:(NSURLCache *)cache
{
    @synchronized(self) {
        [shared_cache autorelease];
        shared_cache = [cache retain];
    }
}

- (instancetype)init
{
    return [self initWithMemoryCapacity:4 << 20 diskCapacity:20 << 20 directoryURL:nil];
}

- (instancetype)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path
{
    if (diskCapacity && diskCapacity < (20 << 20))
        diskCapacity = 20 << 20;
    return [self initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity directoryURL:path ? [NSURL fileURLWithPath:path] : nil];
}

- (instancetype)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity directoryURL:(NSURL *)directoryURL
{
    if ((self = [super init])) {
        _memoryCapacity = memoryCapacity;
        _diskCapacity = diskCapacity;
        _directory = [directoryURL copy];
        _memory = [NSMutableDictionary new];
        _order = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    [_directory release];
    [_memory release];
    [_order release];
    [super dealloc];
}

- (NSUInteger)memoryCapacity { return _memoryCapacity; }
- (void)setMemoryCapacity:(NSUInteger)c { @synchronized(self) { _memoryCapacity = c; [self _trim]; } }
- (NSUInteger)diskCapacity { return _diskCapacity; }
- (void)setDiskCapacity:(NSUInteger)c { _diskCapacity = c; }

static NSString *
cache_key(NSURLRequest *request)
{
    return request.URL.absoluteString;
}

static NSUInteger
cost(NSCachedURLResponse *r)
{
    return r.data.length + 256;
}

- (NSUInteger)currentMemoryUsage
{
    @synchronized(self) {
        NSUInteger n = 0;
        for (NSCachedURLResponse *r in _memory.allValues)
            n += cost(r);
        return n;
    }
}

/* An entry's file: a hash of its key in the directory. */
- (NSString *)_fileFor:(NSString *)key
{
    if (!_directory || !key)
        return nil;
    unsigned long long h = 1469598103934665603ULL;
    for (const char *p = key.UTF8String; *p; p++)
        h = (h ^ (unsigned char)*p) * 1099511628211ULL;
    return [_directory.path stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.cache", h]];
}

- (NSUInteger)currentDiskUsage
{
    if (!_directory)
        return 0;
    NSUInteger n = 0;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory.path error:NULL])
        n += (NSUInteger)[[[NSFileManager defaultManager] attributesOfItemAtPath:[_directory.path stringByAppendingPathComponent:f]
                                                                            error:NULL] fileSize];
    return n;
}

/* Drops the oldest entries until memory use fits. */
- (void)_trim
{
    NSUInteger used = 0;
    for (NSCachedURLResponse *r in _memory.allValues)
        used += cost(r);
    while (used > _memoryCapacity && _order.count) {
        NSString *oldest = _order.firstObject;
        used -= cost(_memory[oldest]);
        [_memory removeObjectForKey:oldest];
        [_order removeObjectAtIndex:0];
    }
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    NSString *key = cache_key(request);
    if (!key)
        return nil;
    @synchronized(self) {
        NSCachedURLResponse *r = _memory[key];
        if (r)
            return [[r retain] autorelease];
    }
    NSString *file = [self _fileFor:key];
    NSData *archived = file ? [NSData dataWithContentsOfFile:file] : nil;
    if (!archived)
        return nil;
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:archived error:NULL] autorelease];
    u.requiresSecureCoding = NO;
    NSCachedURLResponse *r = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    NSString *stored = [u decodeObjectForKey:@"key"];
    return [r isKindOfClass:[NSCachedURLResponse class]] && [stored isEqualToString:key] ? r : nil;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    NSString *key = cache_key(request);
    if (!key || !cachedResponse || cachedResponse.storagePolicy == NSURLCacheStorageNotAllowed)
        return;
    if (cost(cachedResponse) <= _memoryCapacity) {
        @synchronized(self) {
            [_order removeObject:key];
            [_order addObject:key];
            _memory[key] = cachedResponse;
            [self _trim];
        }
    }
    NSString *file = [self _fileFor:key];
    if (file && cachedResponse.storagePolicy == NSURLCacheStorageAllowed && cachedResponse.data.length < _diskCapacity) {
        NSKeyedArchiver *a = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:NO] autorelease];
        [a encodeObject:cachedResponse forKey:NSKeyedArchiveRootObjectKey];
        [a encodeObject:key forKey:@"key"];
        [a finishEncoding];
        [[NSFileManager defaultManager] createDirectoryAtPath:_directory.path withIntermediateDirectories:YES attributes:nil error:NULL];
        [a.encodedData writeToFile:file atomically:YES];
    }
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    NSString *key = cache_key(request);
    if (!key)
        return;
    @synchronized(self) {
        [_memory removeObjectForKey:key];
        [_order removeObject:key];
    }
    NSString *file = [self _fileFor:key];
    if (file)
        [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
}

- (void)removeAllCachedResponses
{
    @synchronized(self) {
        [_memory removeAllObjects];
        [_order removeAllObjects];
    }
    if (_directory)
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory.path error:NULL])
            if ([f.pathExtension isEqualToString:@"cache"])
                [[NSFileManager defaultManager] removeItemAtPath:[_directory.path stringByAppendingPathComponent:f] error:NULL];
}

- (void)removeCachedResponsesSinceDate:(NSDate *)date
{
    [self removeAllCachedResponses]; /* (entries keep no dates yet; everything goes) */
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forDataTask:(NSURLSessionDataTask *)dataTask
{
    [self storeCachedResponse:cachedResponse forRequest:dataTask.currentRequest];
}

- (void)getCachedResponseForDataTask:(NSURLSessionDataTask *)dataTask completionHandler:(void (^)(NSCachedURLResponse *))completionHandler
{
    completionHandler([self cachedResponseForRequest:dataTask.currentRequest]);
}

- (void)removeCachedResponseForDataTask:(NSURLSessionDataTask *)dataTask
{
    [self removeCachedResponseForRequest:dataTask.currentRequest];
}

@end

/* --- NSURLProtocol --- */

static NSMutableArray<Class> *registered_protocols;

@implementation NSURLProtocol {
    NSURLRequest *_request;
    NSCachedURLResponse *_cachedResponse;
    id<NSURLProtocolClient> _client;
    NSURLSessionTask *_task;
}

+ (BOOL)registerClass:(Class)protocolClass
{
    if (![protocolClass isSubclassOfClass:[NSURLProtocol class]])
        return NO;
    @synchronized([NSURLProtocol class]) {
        if (!registered_protocols)
            registered_protocols = [NSMutableArray new];
        [registered_protocols removeObject:protocolClass];
        [registered_protocols insertObject:protocolClass atIndex:0]; /* (the last registered is asked first) */
    }
    return YES;
}

+ (void)unregisterClass:(Class)protocolClass
{
    @synchronized([NSURLProtocol class]) {
        [registered_protocols removeObject:protocolClass];
    }
}

+ (NSArray<Class> *)_finchRegisteredClasses
{
    @synchronized([NSURLProtocol class]) {
        return registered_protocols ? [[registered_protocols copy] autorelease] : @[];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return NO;
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task
{
    return [self canInitWithRequest:task.currentRequest];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b
{
    return [[self canonicalRequestForRequest:a] isEqual:[self canonicalRequestForRequest:b]];
}

+ (id)propertyForKey:(NSString *)key inRequest:(NSURLRequest *)request
{
    return [request _finchPropertyForKey:key];
}

+ (void)setProperty:(id)value forKey:(NSString *)key inRequest:(NSMutableURLRequest *)request
{
    [request _finchSetProperty:value forKey:key];
}

+ (void)removePropertyForKey:(NSString *)key inRequest:(NSMutableURLRequest *)request
{
    [request _finchRemovePropertyForKey:key];
}

- (instancetype)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse
                         client:(id<NSURLProtocolClient>)client
{
    if ((self = [super init])) {
        _request = [request copy];
        _cachedResponse = [cachedResponse retain];
        _client = [(id)client retain];
    }
    return self;
}

- (instancetype)initWithTask:(NSURLSessionTask *)task cachedResponse:(NSCachedURLResponse *)cachedResponse
                      client:(id<NSURLProtocolClient>)client
{
    if ((self = [self initWithRequest:task.currentRequest cachedResponse:cachedResponse client:client]))
        _task = [task retain];
    return self;
}

- (void)dealloc
{
    [_request release];
    [_cachedResponse release];
    [(id)_client release];
    [_task release];
    [super dealloc];
}

- (NSURLRequest *)request { return _request; }
- (NSCachedURLResponse *)cachedResponse { return _cachedResponse; }
- (id<NSURLProtocolClient>)client { return _client; }
- (NSURLSessionTask *)task { return _task; }

- (void)startLoading
{
    [NSException raise:NSInternalInconsistencyException format:@"-[NSURLProtocol startLoading] must be implemented by a subclass"];
}

- (void)stopLoading
{
}

@end

/* --- loading through protocols and the cache --- */

/* Collects what a protocol hands its client. */
@interface FinchProtocolClient : NSObject <NSURLProtocolClient> {
@public
    NSURLResponse *response;
    NSMutableData *data;
    NSError *error;
    NSURLRequest *redirect;
    NSURLCacheStoragePolicy policy;
    BOOL finished;
    dispatch_semaphore_t done;
}
@end

@implementation FinchProtocolClient

- (instancetype)init
{
    if ((self = [super init])) {
        data = [NSMutableData new];
        done = dispatch_semaphore_create(0);
        policy = NSURLCacheStorageAllowed;
    }
    return self;
}

- (void)dealloc
{
    [response release];
    [data release];
    [error release];
    [redirect release];
    dispatch_release(done);
    [super dealloc];
}

- (void)_finish
{
    @synchronized(self) {
        if (finished)
            return;
        finished = YES;
    }
    dispatch_semaphore_signal(done);
}

- (void)URLProtocol:(NSURLProtocol *)protocol wasRedirectedToRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse
{
    [redirect autorelease];
    redirect = [request copy];
}

- (void)URLProtocol:(NSURLProtocol *)protocol cachedResponseIsValid:(NSCachedURLResponse *)cachedResponse
{
    [response autorelease];
    response = [cachedResponse.response retain];
    [data setData:cachedResponse.data];
    [self _finish];
}

- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveResponse:(NSURLResponse *)r cacheStoragePolicy:(NSURLCacheStoragePolicy)p
{
    [response autorelease];
    response = [r retain];
    policy = p;
}

- (void)URLProtocol:(NSURLProtocol *)protocol didLoadData:(NSData *)d
{
    @synchronized(self) {
        [data appendData:d];
    }
}

- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol
{
    [self _finish];
}

- (void)URLProtocol:(NSURLProtocol *)protocol didFailWithError:(NSError *)e
{
    [error autorelease];
    error = [e retain];
    [self _finish];
}

- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
}

- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
}

@end

static NSError *
load_error(NSInteger code, NSURL *url)
{
    return [NSError errorWithDomain:NSURLErrorDomain code:code
                           userInfo:url ? @{NSURLErrorFailingURLErrorKey : url, NSURLErrorFailingURLStringErrorKey : url.absoluteString} : nil];
}

/* Whether a cached HTTP response is still fresh by its max-age or Expires. */
static BOOL
fresh(NSCachedURLResponse *cached)
{
    NSHTTPURLResponse *r = (NSHTTPURLResponse *)cached.response;
    if (![r isKindOfClass:[NSHTTPURLResponse class]])
        return NO;
    NSString *control = [r valueForHTTPHeaderField:@"Cache-Control"].lowercaseString;
    if ([control containsString:@"no-cache"] || [control containsString:@"no-store"])
        return NO;
    NSDate *stored = cached.userInfo[@"FinchStoredDate"];
    NSRange age = [control rangeOfString:@"max-age="];
    if (age.location != NSNotFound && stored)
        return [[NSDate date] timeIntervalSinceDate:stored] < [[control substringFromIndex:NSMaxRange(age)] doubleValue];
    NSString *expires = [r valueForHTTPHeaderField:@"Expires"];
    if (expires) {
        NSDateFormatter *f = [[NSDateFormatter new] autorelease];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
        NSDate *d = [f dateFromString:expires];
        return d && [d timeIntervalSinceNow] > 0;
    }
    return NO;
}

static Class
protocol_for(NSArray<Class> *classes, NSURLRequest *request)
{
    for (Class c in classes)
        if ([c isSubclassOfClass:[NSURLProtocol class]] && [c canInitWithRequest:request])
            return c;
    return Nil;
}

NSData *_FinchURLLoad(NSURLSessionConfiguration *configuration, NSURLSessionTask *task, NSURLRequest *request,
    NSURLResponse **outResponse, NSError **outError, NSData *(*plain)(NSURLRequest *, NSURLResponse **, NSError **));

NSData *
_FinchURLLoad(NSURLSessionConfiguration *configuration, NSURLSessionTask *task, NSURLRequest *request, NSURLResponse **outResponse,
    NSError **outError, NSData *(*plain)(NSURLRequest *, NSURLResponse **, NSError **))
{
    NSMutableArray<Class> *classes = [NSMutableArray array];
    if (configuration.protocolClasses)
        [classes addObjectsFromArray:configuration.protocolClasses];
    for (Class c in [NSURLProtocol _finchRegisteredClasses])
        if (![classes containsObject:c])
            [classes addObject:c];
    NSURLCache *cache = configuration.URLCache;
    NSURLRequestCachePolicy cachePolicy = request.cachePolicy;
    if (cachePolicy == NSURLRequestUseProtocolCachePolicy && configuration.requestCachePolicy != NSURLRequestUseProtocolCachePolicy)
        cachePolicy = configuration.requestCachePolicy;
    BOOL get = [request.HTTPMethod isEqualToString:@"GET"];
    NSCachedURLResponse *cached = cache && get ? [cache cachedResponseForRequest:request] : nil;
    BOOL custom = protocol_for(classes, request) != Nil;
    switch (cachePolicy) {
    case NSURLRequestReturnCacheDataDontLoad:
        if (cached) {
            *outResponse = cached.response;
            return cached.data;
        }
        *outError = load_error(NSURLErrorResourceUnavailable, request.URL);
        return nil;
    case NSURLRequestReturnCacheDataElseLoad:
        if (cached) {
            *outResponse = cached.response;
            return cached.data;
        }
        break;
    case NSURLRequestUseProtocolCachePolicy:
        /* (HTTP's own caching, so for http and https alone) */
        if (cached && !custom && fresh(cached) &&
            ([request.URL.scheme caseInsensitiveCompare:@"http"] == NSOrderedSame ||
                [request.URL.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)) {
            *outResponse = cached.response;
            return cached.data;
        }
        break;
    default:
        break;
    }

    NSURLRequest *current = request;
    NSData *result = nil;
    NSURLCacheStoragePolicy storage = NSURLCacheStorageAllowed;
    for (int redirects = 0; redirects < 16; redirects++) {
        Class c = protocol_for(classes, current);
        if (!c) {
            result = plain(current, outResponse, outError);
            break;
        }
        NSURLRequest *canonical = [c canonicalRequestForRequest:current] ?: current;
        FinchProtocolClient *client = [[FinchProtocolClient new] autorelease];
        NSURLProtocol *p = [[[c alloc] initWithRequest:canonical cachedResponse:cached client:client] autorelease];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [p startLoading];
        });
        NSTimeInterval timeout = configuration.timeoutIntervalForRequest > 0 ? configuration.timeoutIntervalForRequest : 60;
        if (dispatch_semaphore_wait(client->done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)))) {
            [p stopLoading];
            *outError = load_error(NSURLErrorTimedOut, current.URL);
            return nil;
        }
        [p stopLoading];
        if (client->redirect && !client->error) {
            current = [[client->redirect retain] autorelease];
            continue;
        }
        if (client->error) {
            *outError = [[client->error retain] autorelease];
            return nil;
        }
        *outResponse = [[client->response retain] autorelease];
        storage = client->policy;
        result = [[client->data copy] autorelease];
        break;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)*outResponse;
    BOOL ok = ![http isKindOfClass:[NSHTTPURLResponse class]] || http.statusCode == 200;
    if (cache && get && result && *outResponse && ok && storage != NSURLCacheStorageNotAllowed &&
        cachePolicy != NSURLRequestReloadIgnoringLocalAndRemoteCacheData) {
        NSCachedURLResponse *entry = [[[NSCachedURLResponse alloc] initWithResponse:*outResponse data:result
                                                                           userInfo:@{@"FinchStoredDate" : [NSDate date]}
                                                                      storagePolicy:storage] autorelease];
        [cache storeCachedResponse:entry forRequest:request];
    }
    return result;
}

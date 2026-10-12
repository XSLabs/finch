/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURLCache, NSCachedURLResponse and NSURLProtocol: storing and finding responses,
 * custom protocols answering a session's requests (per configuration and registered
 * for everyone), request properties, and a session reading through its cache. Nothing
 * here touches the network: the protocol stands in for the server.
 */
#import <Foundation/Foundation.h>

static int loads;

@interface FinchTestProtocol : NSURLProtocol
@end

@implementation FinchTestProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return [request.URL.scheme isEqualToString:@"finchtest"] && ![NSURLProtocol propertyForKey:@"seen" inRequest:request];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    loads++;
    NSString *path = self.request.URL.path;
    if ([path isEqualToString:@"/fail"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"finchtest" code:42 userInfo:nil]];
        return;
    }
    if ([path isEqualToString:@"/redirect"]) {
        NSURLRequest *next = [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/hello"]];
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1"
                                                         headerFields:@{@"Location" : @"finchtest://host/hello"}];
        [self.client URLProtocol:self wasRedirectedToRequest:next redirectResponse:r];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    NSDictionary *headers = @{@"Content-Type" : @"text/plain", @"Cache-Control" : @"max-age=3600", @"X-Path" : path ?: @""};
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                     headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageAllowed];
    NSString *body = [NSString stringWithFormat:@"body of %@ (%@)", path, [self.request valueForHTTPHeaderField:@"X-Test"] ?: @"-"];
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    [self.client URLProtocol:self didLoadData:[d subdataWithRange:NSMakeRange(0, 4)]];
    [self.client URLProtocol:self didLoadData:[d subdataWithRange:NSMakeRange(4, d.length - 4)]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading
{
}

@end

static void
fetch(NSURLSession *s, NSURLRequest *req, const char *label)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[s dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *h = (NSHTTPURLResponse *)response;
      printf("%s: %s | status %ld | url %s | x-path %s | error %s %ld\n", label,
          data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "nil",
          [h isKindOfClass:[NSHTTPURLResponse class]] ? (long)h.statusCode : -1L, response.URL.absoluteString.UTF8String,
          [h isKindOfClass:[NSHTTPURLResponse class]] ? [h valueForHTTPHeaderField:@"X-Path"].UTF8String : "-", error.domain.UTF8String,
          (long)error.code);
      dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)))
        printf("%s: timed out\n", label);
}

int
main(void)
{
    @autoreleasepool {
        /* the cache on its own */
        NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-urlcache-test"]];
        [[NSFileManager defaultManager] removeItemAtURL:dir error:NULL];
        NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:1 << 20 diskCapacity:4 << 20 directoryURL:dir];
        printf("capacities: memory %lu disk %lu usage %lu %lu\n", (unsigned long)cache.memoryCapacity, (unsigned long)cache.diskCapacity,
            (unsigned long)cache.currentMemoryUsage, (unsigned long)cache.currentDiskUsage);
        NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/a"]];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type" : @"text/plain"}];
        NSCachedURLResponse *c = [[NSCachedURLResponse alloc] initWithResponse:resp data:[@"cached" dataUsingEncoding:NSUTF8StringEncoding]
                                                                      userInfo:@{@"k" : @"v"} storagePolicy:NSURLCacheStorageAllowedInMemoryOnly];
        printf("cached response: %s policy %lu user %s\n", [[NSString alloc] initWithData:c.data encoding:NSUTF8StringEncoding].UTF8String,
            (unsigned long)c.storagePolicy, [c.userInfo[@"k"] UTF8String]);
        printf("before store: %s\n", [cache cachedResponseForRequest:req] ? "found" : "none");
        [cache storeCachedResponse:c forRequest:req];
        NSCachedURLResponse *got = [cache cachedResponseForRequest:req];
        printf("after store: %s status %ld policy %lu usage>0 %d\n", got ? [[NSString alloc] initWithData:got.data encoding:NSUTF8StringEncoding].UTF8String : "none",
            (long)((NSHTTPURLResponse *)got.response).statusCode, (unsigned long)got.storagePolicy, cache.currentMemoryUsage > 0);
        NSMutableURLRequest *other = [req mutableCopy];
        [other setValue:@"x" forHTTPHeaderField:@"Accept"];
        printf("same URL, other header: %s\n", [cache cachedResponseForRequest:other] ? "found" : "none");
        NSURLRequest *post = ({
            NSMutableURLRequest *m = [req mutableCopy];
            m.HTTPMethod = @"POST";
            m;
        });
        printf("POST: %s\n", [cache cachedResponseForRequest:post] ? "found" : "none");
        [cache removeCachedResponseForRequest:req];
        printf("after remove: %s\n", [cache cachedResponseForRequest:req] ? "found" : "none");
        [cache storeCachedResponse:c forRequest:req];
        [cache removeAllCachedResponses];
        printf("after remove all: %s usage %lu\n", [cache cachedResponseForRequest:req] ? "found" : "none", (unsigned long)cache.currentMemoryUsage);
        printf("shared: %d memory>0 %d\n", [NSURLCache sharedURLCache] != nil, [NSURLCache sharedURLCache].memoryCapacity > 0);

        /* properties on requests */
        NSMutableURLRequest *m = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/p"]];
        [NSURLProtocol setProperty:@"value" forKey:@"key" inRequest:m];
        printf("property: %s copy keeps it %s\n", [[NSURLProtocol propertyForKey:@"key" inRequest:m] UTF8String],
            [[NSURLProtocol propertyForKey:@"key" inRequest:[m copy]] UTF8String]);
        [NSURLProtocol removePropertyForKey:@"key" inRequest:m];
        printf("removed: %s\n", [NSURLProtocol propertyForKey:@"key" inRequest:m] ? "still" : "gone");
        printf("cache equivalent: %d %d\n", [NSURLProtocol requestIsCacheEquivalent:req toRequest:[req copy]],
            [NSURLProtocol requestIsCacheEquivalent:req toRequest:m]);

        /* a protocol per configuration */
        NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        conf.protocolClasses = @[ [FinchTestProtocol class] ];
        conf.URLCache = nil;
        NSURLSession *s = [NSURLSession sessionWithConfiguration:conf];
        NSMutableURLRequest *hello = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/hello"]];
        [hello setValue:@"yes" forHTTPHeaderField:@"X-Test"];
        fetch(s, hello, "protocol");
        fetch(s, [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/fail"]], "failing");
        fetch(s, [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/redirect"]], "redirect");
        NSURLSession *plain = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
        fetch(plain, [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/hello"]], "unregistered");

        /* registered for everyone */
        printf("register: %d\n", [NSURLProtocol registerClass:[FinchTestProtocol class]]);
        fetch([NSURLSession sharedSession], [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/global"]], "registered");
        [NSURLProtocol unregisterClass:[FinchTestProtocol class]];
        fetch([NSURLSession sharedSession], [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/global"]], "unregistered again");

        /* a session reading through a cache */
        NSURLSessionConfiguration *cached = [NSURLSessionConfiguration defaultSessionConfiguration];
        cached.protocolClasses = @[ [FinchTestProtocol class] ];
        NSURL *dir2 = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-urlcache-test2"]];
        [[NSFileManager defaultManager] removeItemAtURL:dir2 error:NULL];
        cached.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:1 << 20 diskCapacity:0 directoryURL:dir2];
        NSURLSession *cs = [NSURLSession sessionWithConfiguration:cached];
        loads = 0;
        NSURLRequest *page = [NSURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/page"]];
        fetch(cs, page, "first");
        fetch(cs, page, "second");
        printf("loads through the protocol: %d; cached %s\n", loads, [cached.URLCache cachedResponseForRequest:page] ? "yes" : "no");
        NSMutableURLRequest *reload = [page mutableCopy];
        reload.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        fetch(cs, reload, "reload");
        NSMutableURLRequest *offline = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"finchtest://host/never"]];
        offline.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
        fetch(cs, offline, "cache only, missing");
        printf("loads: %d\n", loads);
        [[NSFileManager defaultManager] removeItemAtURL:dir error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:dir2 error:NULL];
    }
    return 0;
}

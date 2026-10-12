/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * HTTP cookies (Apple's are CFNetwork's, re-exported by Foundation; Finch's are in
 * Foundation with its URL loading). NSHTTPCookie holds one cookie: made from a
 * properties dictionary (Apple's keys), or parsed from a response's Set-Cookie headers
 * (RFC 6265: Domain, Path, Expires, Max-Age, Secure, HttpOnly, SameSite) with the
 * request URL supplying the defaults; as Apple's, none lives more than 400 days. NSHTTPCookieStorage keeps an app's cookies: it
 * replaces a cookie of the same name, domain and path, drops expired ones, answers which
 * cookies go with a URL (domain-match, path-match, secure only over https), and keeps
 * cookies that outlive the session in ~/Library/HTTPStorages/<bundle id>.cookies (a
 * property list: Finch's own format, not Apple's binary cookies).
 */
#import <Foundation/Foundation.h>

NSHTTPCookiePropertyKey const NSHTTPCookieName = @"Name";
NSHTTPCookiePropertyKey const NSHTTPCookieValue = @"Value";
NSHTTPCookiePropertyKey const NSHTTPCookieOriginURL = @"OriginURL";
NSHTTPCookiePropertyKey const NSHTTPCookieVersion = @"Version";
NSHTTPCookiePropertyKey const NSHTTPCookieDomain = @"Domain";
NSHTTPCookiePropertyKey const NSHTTPCookiePath = @"Path";
NSHTTPCookiePropertyKey const NSHTTPCookieSecure = @"Secure";
NSHTTPCookiePropertyKey const NSHTTPCookieExpires = @"Expires";
NSHTTPCookiePropertyKey const NSHTTPCookieComment = @"Comment";
NSHTTPCookiePropertyKey const NSHTTPCookieCommentURL = @"CommentURL";
NSHTTPCookiePropertyKey const NSHTTPCookieDiscard = @"Discard";
NSHTTPCookiePropertyKey const NSHTTPCookieMaximumAge = @"Max-Age";
NSHTTPCookiePropertyKey const NSHTTPCookiePort = @"Port";
NSHTTPCookiePropertyKey const NSHTTPCookieSameSitePolicy = @"SameSite";
NSHTTPCookieStringPolicy const NSHTTPCookieSameSiteLax = @"lax";
NSHTTPCookieStringPolicy const NSHTTPCookieSameSiteStrict = @"strict";
NSNotificationName const NSHTTPCookieManagerCookiesChangedNotification = @"NSHTTPCookieManagerCookiesChangedNotification";
NSNotificationName const NSHTTPCookieManagerAcceptPolicyChangedNotification = @"com.apple.Foundation.NSHTTPCookieManagerAcceptPolicyChanged";
static NSString *const kHTTPOnly = @"HttpOnly";

/* An HTTP date (RFC 1123, RFC 850 and asctime forms, and Netscape's dashes). */
static NSDate *
http_date(NSString *s)
{
    static NSArray<NSDateFormatter *> *formats;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *f in @[ @"EEE, dd MMM yyyy HH:mm:ss zzz", @"EEE, dd-MMM-yyyy HH:mm:ss zzz", @"EEEE, dd-MMM-yy HH:mm:ss zzz",
                               @"EEE MMM d HH:mm:ss yyyy", @"EEE, dd-MMM-yy HH:mm:ss zzz", @"EEE, dd MMM yy HH:mm:ss zzz" ]) {
            NSDateFormatter *d = [[NSDateFormatter alloc] init];
            d.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            d.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
            d.dateFormat = f;
            [a addObject:d];
            [d release];
        }
        formats = [a copy];
    });
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSDateFormatter *f in formats) {
        NSDate *d = [f dateFromString:s];
        if (d)
            return d;
    }
    return nil;
}

@implementation NSHTTPCookie {
    NSDictionary *_properties;
    NSDate *_expires;
}

+ (instancetype)cookieWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
    return [[[self alloc] initWithProperties:properties] autorelease];
}

static NSString *
string_property(NSDictionary *p, NSString *k)
{
    id v = p[k];
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[NSNumber class]])
        return [v stringValue];
    return nil;
}

static BOOL
true_property(NSDictionary *p, NSString *k)
{
    id v = p[k];
    if ([v isKindOfClass:[NSString class]])
        return [v caseInsensitiveCompare:@"TRUE"] == NSOrderedSame || [v isEqualToString:@"1"] ||
               [v caseInsensitiveCompare:@"yes"] == NSOrderedSame;
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

/* As Apple's: a name, a value, a path and a domain (else the origin URL's host) are needed. */
- (instancetype)initWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
    NSMutableDictionary *p = [[properties mutableCopy] autorelease];
    NSString *name = string_property(p, NSHTTPCookieName), *value = string_property(p, NSHTTPCookieValue);
    NSString *path = string_property(p, NSHTTPCookiePath), *domain = string_property(p, NSHTTPCookieDomain);
    if (!domain) {
        id origin = p[NSHTTPCookieOriginURL];
        NSURL *u = [origin isKindOfClass:[NSURL class]] ? origin : [origin isKindOfClass:[NSString class]] ? [NSURL URLWithString:origin] : nil;
        domain = [u host]; /* (as written: Apple's keeps the origin's case) */
    }
    if (!name || !value || !path || !domain || [name length] == 0) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        p[NSHTTPCookieName] = name;
        p[NSHTTPCookieValue] = value;
        p[NSHTTPCookiePath] = path;
        p[NSHTTPCookieDomain] = domain;
        id exp = p[NSHTTPCookieExpires];
        if ([exp isKindOfClass:[NSDate class]])
            _expires = [exp retain];
        else if ([exp isKindOfClass:[NSString class]])
            _expires = [http_date(exp) retain];
        NSString *maxAge = string_property(p, NSHTTPCookieMaximumAge);
        if (maxAge)
            _expires = [[NSDate dateWithTimeIntervalSinceNow:[maxAge doubleValue]] retain];
        if (true_property(p, NSHTTPCookieDiscard) && !maxAge) {
            [_expires release];
            _expires = nil;
        }
        /* as Apple's (and RFC 6265bis): no cookie lives more than 400 days from now */
        NSDate *cap = [NSDate dateWithTimeIntervalSinceNow:400 * 86400.0];
        if (_expires && [_expires compare:cap] == NSOrderedDescending) {
            [_expires release];
            _expires = [cap retain];
        }
        if (_expires)
            p[NSHTTPCookieExpires] = _expires;
        _properties = [p copy];
    }
    return self;
}

- (void)dealloc
{
    [_properties release];
    [_expires release];
    [super dealloc];
}

- (NSDictionary *)properties { return _properties; }
- (NSUInteger)version { return (NSUInteger)[string_property(_properties, NSHTTPCookieVersion) integerValue]; }
- (NSString *)name { return _properties[NSHTTPCookieName]; }
- (NSString *)value { return _properties[NSHTTPCookieValue]; }
- (NSDate *)expiresDate { return _expires; }
- (BOOL)isSessionOnly { return _expires == nil; }
- (NSString *)domain { return _properties[NSHTTPCookieDomain]; }
- (NSString *)path { return _properties[NSHTTPCookiePath]; }
- (BOOL)isSecure { return true_property(_properties, NSHTTPCookieSecure); }
- (BOOL)isHTTPOnly { return true_property(_properties, kHTTPOnly); }
- (NSString *)comment { return string_property(_properties, NSHTTPCookieComment); }

- (NSURL *)commentURL
{
    id u = _properties[NSHTTPCookieCommentURL];
    return [u isKindOfClass:[NSURL class]] ? u : [u isKindOfClass:[NSString class]] ? [NSURL URLWithString:u] : nil;
}

- (NSArray<NSNumber *> *)portList
{
    NSString *ports = string_property(_properties, NSHTTPCookiePort);
    if (!ports)
        return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in [ports componentsSeparatedByString:@","])
        [a addObject:@([p integerValue])];
    return a;
}

- (NSHTTPCookieStringPolicy)sameSitePolicy
{
    NSString *s = [string_property(_properties, NSHTTPCookieSameSitePolicy) lowercaseString];
    if ([s isEqualToString:@"lax"])
        return NSHTTPCookieSameSiteLax;
    if ([s isEqualToString:@"strict"])
        return NSHTTPCookieSameSiteStrict;
    return nil;
}

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[NSHTTPCookie class]])
        return NO;
    NSHTTPCookie *c = o;
    return [c.name isEqualToString:self.name] && [c.domain isEqualToString:self.domain] && [c.path isEqualToString:self.path];
}

- (NSUInteger)hash { return self.name.hash ^ self.domain.hash ^ self.path.hash; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSHTTPCookie\n\tversion:%lu\n\tname:%@\n\tvalue:%@\n\texpiresDate:'%@'\n\tcreated:'(null)'\n"
                                      @"\tsessionOnly:%d\n\tdomain:%@\n\tpartition:none\n\tsameSite:%@\n\tpath:%@\n\tisSecure:%d\n"
                                      @"\tisHTTPOnly: %s\n path:\"%@\" isSecure:%s>",
                                      (unsigned long)self.version, self.name, self.value, self.expiresDate, self.sessionOnly, self.domain,
                                      self.sameSitePolicy ?: @"none", self.path, self.secure, self.HTTPOnly ? "YES" : "NO", self.path,
                                      self.secure ? "TRUE" : "FALSE"];
}

/* Set-Cookie headers (possibly several folded into one with commas) into cookies. */
static NSArray<NSString *> *
split_set_cookie(NSString *header)
{
    /* a comma starts a new cookie unless it sits in an Expires date ("Wed, 21 Oct ...") */
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger start = 0, n = [header length];
    for (NSUInteger i = 0; i < n; i++) {
        if ([header characterAtIndex:i] != ',')
            continue;
        NSString *before = [[header substringWithRange:NSMakeRange(start, i - start)] lowercaseString];
        NSRange e = [before rangeOfString:@"expires=" options:NSBackwardsSearch];
        if (e.location != NSNotFound && [before rangeOfString:@";" options:0 range:NSMakeRange(e.location, [before length] - e.location)].location ==
                                            NSNotFound &&
            [[before substringFromIndex:NSMaxRange(e)] rangeOfString:@" "].location == NSNotFound)
            continue; /* the comma after the day of the week */
        [out addObject:[header substringWithRange:NSMakeRange(start, i - start)]];
        start = i + 1;
    }
    if (start < n)
        [out addObject:[header substringFromIndex:start]];
    return out;
}

static NSString *
default_path(NSURL *url)
{
    NSString *p = [url path];
    if (![p length] || ![p hasPrefix:@"/"])
        return @"/";
    NSRange last = [p rangeOfString:@"/" options:NSBackwardsSearch];
    return last.location == 0 ? @"/" : [p substringToIndex:last.location];
}

+ (NSArray<NSHTTPCookie *> *)cookiesWithResponseHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields forURL:(NSURL *)URL
{
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSString *key in headerFields) {
        if ([key caseInsensitiveCompare:@"Set-Cookie"] != NSOrderedSame)
            continue;
        for (NSString *line in split_set_cookie(headerFields[key])) {
            NSArray *parts = [line componentsSeparatedByString:@";"];
            NSString *pair = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound)
                continue;
            NSMutableDictionary *p = [NSMutableDictionary dictionary];
            p[NSHTTPCookieName] = [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            p[NSHTTPCookieValue] = [[pair substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            p[NSHTTPCookiePath] = default_path(URL);
            p[NSHTTPCookieDomain] = [[URL host] lowercaseString] ?: @"";
            p[NSHTTPCookieOriginURL] = URL;
            for (NSUInteger i = 1; i < [parts count]; i++) {
                NSString *attr = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSRange e2 = [attr rangeOfString:@"="];
                NSString *k = e2.location == NSNotFound ? attr : [attr substringToIndex:e2.location];
                NSString *v = e2.location == NSNotFound ? @"" : [attr substringFromIndex:NSMaxRange(e2)];
                k = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([k caseInsensitiveCompare:@"domain"] == NSOrderedSame && [v length]) {
                    /* a leading dot means the domain and its subdomains, as does any Domain attribute */
                    p[NSHTTPCookieDomain] = [v hasPrefix:@"."] ? [v lowercaseString] : [@"." stringByAppendingString:[v lowercaseString]];
                } else if ([k caseInsensitiveCompare:@"path"] == NSOrderedSame && [v hasPrefix:@"/"]) {
                    p[NSHTTPCookiePath] = v;
                } else if ([k caseInsensitiveCompare:@"expires"] == NSOrderedSame) {
                    NSDate *d = http_date(v);
                    if (d)
                        p[NSHTTPCookieExpires] = d;
                } else if ([k caseInsensitiveCompare:@"max-age"] == NSOrderedSame) {
                    p[NSHTTPCookieMaximumAge] = v;
                } else if ([k caseInsensitiveCompare:@"secure"] == NSOrderedSame) {
                    p[NSHTTPCookieSecure] = @"TRUE";
                } else if ([k caseInsensitiveCompare:@"httponly"] == NSOrderedSame) {
                    p[kHTTPOnly] = @"TRUE";
                } else if ([k caseInsensitiveCompare:@"samesite"] == NSOrderedSame) {
                    p[NSHTTPCookieSameSitePolicy] = [v lowercaseString];
                } else if ([k caseInsensitiveCompare:@"version"] == NSOrderedSame) {
                    p[NSHTTPCookieVersion] = v;
                } else if ([k caseInsensitiveCompare:@"comment"] == NSOrderedSame) {
                    p[NSHTTPCookieComment] = v;
                }
            }
            NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:p];
            if (c)
                [cookies addObject:c];
        }
    }
    return cookies;
}

+ (NSDictionary<NSString *, NSString *> *)requestHeaderFieldsWithCookies:(NSArray<NSHTTPCookie *> *)cookies
{
    if (![cookies count])
        return @{};
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSHTTPCookie *c in cookies)
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    return @{@"Cookie" : [pairs componentsJoinedByString:@"; "]};
}

@end

#pragma mark - Storage

@implementation NSHTTPCookieStorage {
    NSMutableArray<NSHTTPCookie *> *_cookies;
    NSHTTPCookieAcceptPolicy _policy;
    NSString *_file;
}

+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage
{
    static NSHTTPCookieStorage *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: [[NSProcessInfo processInfo] processName];
        s = [[self alloc] _initWithFile:[NSHomeDirectory() stringByAppendingPathComponent:
                                                                   [NSString stringWithFormat:@"Library/HTTPStorages/%@.cookies", bundle]]];
    });
    return s;
}

+ (NSHTTPCookieStorage *)sharedCookieStorageForGroupContainerIdentifier:(NSString *)identifier
{
    static NSMutableDictionary *byGroup;
    @synchronized(self) {
        if (!byGroup)
            byGroup = [[NSMutableDictionary alloc] init];
        NSHTTPCookieStorage *s = byGroup[identifier];
        if (!s) {
            s = [[[self alloc] _initWithFile:[NSHomeDirectory() stringByAppendingPathComponent:
                                                                     [NSString stringWithFormat:@"Library/HTTPStorages/group.%@.cookies", identifier]]] autorelease];
            byGroup[identifier] = s;
        }
        return s;
    }
}

- (instancetype)init
{
    return [self _initWithFile:nil];
}

- (instancetype)_initWithFile:(NSString *)file
{
    if ((self = [super init])) {
        _cookies = [[NSMutableArray alloc] init];
        _policy = NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain;
        _file = [file copy];
        for (NSDictionary *p in [NSArray arrayWithContentsOfFile:_file]) {
            NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:p];
            if (c && (!c.expiresDate || [c.expiresDate timeIntervalSinceNow] > 0))
                [_cookies addObject:c];
        }
    }
    return self;
}

- (void)dealloc
{
    [_cookies release];
    [_file release];
    [super dealloc];
}

/* (cookies that outlive the session, written whenever the store changes) */
- (void)_save
{
    if (!_file)
        return;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSHTTPCookie *c in _cookies)
        if (!c.sessionOnly) {
            NSMutableDictionary *p = [[c.properties mutableCopy] autorelease];
            [p removeObjectForKey:NSHTTPCookieOriginURL];
            [p removeObjectForKey:NSHTTPCookieMaximumAge];
            id cu = p[NSHTTPCookieCommentURL];
            if ([cu isKindOfClass:[NSURL class]])
                p[NSHTTPCookieCommentURL] = [cu absoluteString];
            [keep addObject:p];
        }
    [[NSFileManager defaultManager] createDirectoryAtPath:[_file stringByDeletingLastPathComponent] withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    [keep writeToFile:_file atomically:YES];
}

- (void)_changed
{
    [self _save];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSHTTPCookieManagerCookiesChangedNotification object:self];
}

- (void)_dropExpired
{
    NSDate *now = [NSDate date];
    NSIndexSet *gone = [_cookies indexesOfObjectsPassingTest:^BOOL(NSHTTPCookie *c, NSUInteger i, BOOL *stop) {
        return c.expiresDate && [c.expiresDate compare:now] != NSOrderedDescending;
    }];
    [_cookies removeObjectsAtIndexes:gone];
}

- (NSArray<NSHTTPCookie *> *)cookies
{
    @synchronized(self) {
        [self _dropExpired];
        return [[_cookies copy] autorelease];
    }
}

- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy { return _policy; }
- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)p { _policy = p; }

- (void)setCookie:(NSHTTPCookie *)cookie
{
    if (!cookie || _policy == NSHTTPCookieAcceptPolicyNever)
        return;
    @synchronized(self) {
        [_cookies removeObject:cookie];
        /* an already-expired cookie deletes the one it names */
        if (!cookie.expiresDate || [cookie.expiresDate timeIntervalSinceNow] > 0)
            [_cookies addObject:cookie];
    }
    [self _changed];
}

- (void)deleteCookie:(NSHTTPCookie *)cookie
{
    @synchronized(self) {
        [_cookies removeObject:cookie];
    }
    [self _changed];
}

- (void)removeCookiesSinceDate:(NSDate *)date
{
    /* (Finch doesn't keep creation dates: all of them go, as all are newer than any date before the store) */
    @synchronized(self) {
        [_cookies removeAllObjects];
    }
    [self _changed];
}

/* RFC 6265's domain and path matches. */
static BOOL
domain_matches(NSString *host, NSString *domain)
{
    host = [host lowercaseString];
    if ([domain hasPrefix:@"."]) {
        NSString *bare = [domain substringFromIndex:1];
        return [host isEqualToString:bare] || [host hasSuffix:domain];
    }
    return [host isEqualToString:domain];
}

static BOOL
path_matches(NSString *path, NSString *cookiePath)
{
    if (![path length])
        path = @"/";
    if ([path isEqualToString:cookiePath])
        return YES;
    if (![path hasPrefix:cookiePath])
        return NO;
    return [cookiePath hasSuffix:@"/"] || [path characterAtIndex:[cookiePath length]] == '/';
}

- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)URL
{
    NSString *host = [URL host];
    if (!host)
        return @[];
    BOOL secure = [[[URL scheme] lowercaseString] isEqualToString:@"https"];
    NSMutableArray *out = [NSMutableArray array];
    @synchronized(self) {
        [self _dropExpired];
        for (NSHTTPCookie *c in _cookies)
            if (domain_matches(host, c.domain) && path_matches([URL path], c.path) && (!c.secure || secure))
                [out addObject:c];
    }
    /* longer paths first, as browsers send them */
    [out sortUsingComparator:^NSComparisonResult(NSHTTPCookie *a, NSHTTPCookie *b) {
        return a.path.length > b.path.length ? NSOrderedAscending : a.path.length < b.path.length ? NSOrderedDescending : NSOrderedSame;
    }];
    return out;
}

- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL
{
    if (_policy == NSHTTPCookieAcceptPolicyNever)
        return;
    NSString *main = [[mainDocumentURL host] lowercaseString];
    for (NSHTTPCookie *c in cookies) {
        /* only from the main document's domain: a cookie for another site is refused */
        if (_policy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain && main && !domain_matches(main, c.domain) &&
            !domain_matches(c.domain.length && [c.domain hasPrefix:@"."] ? [c.domain substringFromIndex:1] : c.domain, [@"." stringByAppendingString:main]))
            continue;
        [self setCookie:c];
    }
}

- (NSArray<NSHTTPCookie *> *)sortedCookiesUsingDescriptors:(NSArray<NSSortDescriptor *> *)sortOrder
{
    return [[self cookies] sortedArrayUsingDescriptors:sortOrder];
}

- (void)storeCookies:(NSArray<NSHTTPCookie *> *)cookies forTask:(NSURLSessionTask *)task
{
    NSURLRequest *r = task.currentRequest ?: task.originalRequest;
    [self setCookies:cookies forURL:r.URL mainDocumentURL:r.mainDocumentURL ?: r.URL];
}

- (void)getCookiesForTask:(NSURLSessionTask *)task completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler
{
    NSURLRequest *r = task.currentRequest ?: task.originalRequest;
    if (completionHandler)
        completionHandler([self cookiesForURL:r.URL]);
}

@end

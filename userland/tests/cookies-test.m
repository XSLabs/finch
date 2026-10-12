/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * HTTP cookies: NSHTTPCookie from properties and from Set-Cookie headers (domain, path,
 * expiry, Secure, HttpOnly, SameSite, a folded header with an Expires date), the request
 * header for a set of cookies, a private NSHTTPCookieStorage's matching (domain, path,
 * secure), replacement and deletion, and a round trip through URL loading against a
 * server in this process: the first response sets a cookie, the second request sends it.
 * Compared with Apple's.
 */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

static int listener;
static char received[2][2048];

static void *
serve(void *arg)
{
    for (int i = 0; i < 2; i++) {
        int c = accept(listener, NULL, NULL);
        if (c < 0)
            return NULL;
        ssize_t n = read(c, received[i], sizeof received[i] - 1);
        received[i][n > 0 ? n : 0] = 0;
        const char *r = i == 0 ? "HTTP/1.1 200 OK\r\nSet-Cookie: session=abc123; Path=/\r\nSet-Cookie: theme=dark; Path=/; HttpOnly\r\n"
                                 "Content-Length: 2\r\nConnection: close\r\n\r\nok"
                               : "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
        write(c, r, strlen(r));
        close(c);
    }
    return NULL;
}

static void
show(NSHTTPCookie *c)
{
    if (!c) {
        printf("  (none)\n");
        return;
    }
    printf("  %s=%s domain %s path %s session %d secure %d httpOnly %d sameSite %s expires %s\n", c.name.UTF8String, c.value.UTF8String,
           c.domain.UTF8String, c.path.UTF8String, c.sessionOnly, c.secure, c.HTTPOnly, c.sameSitePolicy.UTF8String ?: "none",
           c.expiresDate ? [[NSString stringWithFormat:@"in %.0f days", c.expiresDate.timeIntervalSinceNow / 86400] UTF8String] : "-");
}

int
main(void)
{
    @autoreleasepool {
        printf("from properties:\n");
        show([NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"a", NSHTTPCookieValue : @"1", NSHTTPCookieDomain : @"example.com",
                                                  NSHTTPCookiePath : @"/"}]);
        show([NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"b", NSHTTPCookieValue : @"2",
                                                  NSHTTPCookieOriginURL : [NSURL URLWithString:@"https://Shop.Example.com/cart"],
                                                  NSHTTPCookiePath : @"/cart", NSHTTPCookieSecure : @"TRUE"}]);
        printf("missing a path: %d\n", [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"c", NSHTTPCookieValue : @"3",
                                                                            NSHTTPCookieDomain : @"example.com"}] != nil);
        NSURL *u = [NSURL URLWithString:@"https://www.example.com/docs/page.html"];
        printf("from headers:\n");
        for (NSString *h in @[ @"id=42", @"id=42; Domain=example.com; Path=/; Secure; HttpOnly; SameSite=Lax",
                               @"pref=x; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/docs",
                               @"one=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT, two=2; Path=/" ]) {
            NSArray *cs = [NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie" : h} forURL:u];
            printf(" %lu from \"%s\":\n", (unsigned long)cs.count, h.UTF8String);
            for (NSHTTPCookie *c in cs)
                show(c);
        }
        NSArray *two = @[ [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"a", NSHTTPCookieValue : @"1", NSHTTPCookieDomain : @"x.org", NSHTTPCookiePath : @"/"}],
                          [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"b", NSHTTPCookieValue : @"2", NSHTTPCookieDomain : @"x.org", NSHTTPCookiePath : @"/"}] ];
        printf("request header: %s\n", [[NSHTTPCookie requestHeaderFieldsWithCookies:two][@"Cookie"] UTF8String]);

        NSURLSessionConfiguration *eph = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSHTTPCookieStorage *jar = eph.HTTPCookieStorage;
        jar.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        printf("ephemeral storage separate: %d, empty: %d\n", jar != [NSHTTPCookieStorage sharedHTTPCookieStorage], jar.cookies.count == 0);
        for (NSString *h in @[ @"root=1; Domain=example.com; Path=/", @"docs=2; Path=/docs", @"safe=3; Path=/; Secure" ])
            [jar setCookies:[NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie" : h} forURL:u] forURL:u mainDocumentURL:u];
        for (NSString *s in @[ @"https://www.example.com/docs/x", @"http://www.example.com/docs/x", @"https://api.example.com/", @"https://other.org/" ]) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSHTTPCookie *c in [jar cookiesForURL:[NSURL URLWithString:s]])
                [names addObject:c.name];
            [names sortUsingSelector:@selector(compare:)];
            printf("cookies for %s: %s\n", s.UTF8String, [[names componentsJoinedByString:@","] UTF8String]);
        }
        [jar setCookies:[NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie" : @"docs=changed; Path=/docs"} forURL:u] forURL:u mainDocumentURL:u];
        printf("replaced: %lu cookies, docs=%s\n", (unsigned long)jar.cookies.count,
               [[[jar cookiesForURL:[NSURL URLWithString:@"https://www.example.com/docs/"]] filteredArrayUsingPredicate:
                   [NSPredicate predicateWithFormat:@"name == 'docs'"]].firstObject value].UTF8String);
        [jar deleteCookie:jar.cookies.firstObject];
        printf("after a delete: %lu\n", (unsigned long)jar.cookies.count);

        listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        bind(listener, (struct sockaddr *)&a, sizeof a);
        socklen_t len = sizeof a;
        getsockname(listener, (struct sockaddr *)&a, &len);
        listen(listener, 4);
        pthread_t t;
        pthread_create(&t, NULL, serve, NULL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        NSURL *base = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", ntohs(a.sin_port)]];
        for (int i = 0; i < 2; i++) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [[session dataTaskWithURL:[base URLByAppendingPathComponent:i ? @"again" : @"first"]
                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                        dispatch_semaphore_signal(done);
                    }] resume];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
        }
        pthread_join(t, NULL);
        char *cookie = strcasestr(received[1], "\r\nCookie:");
        char line[256] = "";
        if (cookie)
            sscanf(cookie + 2, "%255[^\r]", line);
        printf("first request had a cookie: %d\n", strcasestr(received[0], "\r\nCookie:") != NULL);
        printf("second request: %s\n", cookie ? line : "(no cookie)");
        printf("session storage: %lu cookies\n", (unsigned long)cfg.HTTPCookieStorage.cookies.count);
    }
    return 0;
}

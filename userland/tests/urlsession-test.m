/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-urlsession-test: the URL loading system: requests and their headers,
 * responses, and NSURLSession loading file:, data: and http: URLs (from a
 * small HTTP server on the loopback interface, with redirects and chunked
 * bodies), with completion handlers and delegates, downloads cut short (the
 * connection dropped, or the task cancelled) resumed from their resume data, Basic and
 * Digest password challenges, and what a session's delegate is told: challenges, redirects,
 * responses, data and download progress. Prints everything; run it
 * against Apple's Foundation and Finch's (DYLD_FRAMEWORK_PATH) and diff all
 * but the first line.
 */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int port;

/* /big and /stall: 64 KiB with a validator, served whole or from a Range; the first whole
   one of each is cut off halfway (/big's connection closed, /stall's left hanging). */
#define BIG 65536
static char big_body[BIG];
static int big_served, stall_served, big2_served;
static char last_range[64];

static int
digest_field(const char *request, const char *name, char *value, size_t size)
{
    const char *p = strcasestr(request, "\r\nAuthorization:");
    if (!p)
        return 0;
    p += strlen("\r\nAuthorization:");
    while (*p == ' ' || *p == '\t')
        p++;
    if (strncasecmp(p, "Digest", 6) || (p[6] != ' ' && p[6] != '\t'))
        return 0;
    p += 6;
    while (*p == ' ' || *p == '\t')
        p++;
    while (*p && *p != '\r' && *p != '\n') {
        while (*p == ' ' || *p == '\t' || *p == ',')
            p++;
        const char *key = p;
        while (*p && *p != '=' && *p != ',' && *p != '\r' && *p != '\n')
            p++;
        size_t key_length = (size_t)(p - key);
        while (key_length && (key[key_length - 1] == ' ' || key[key_length - 1] == '\t'))
            key_length--;
        if (*p != '=') {
            while (*p && *p != ',' && *p != '\r' && *p != '\n')
                p++;
            continue;
        }
        p++;
        while (*p == ' ' || *p == '\t')
            p++;
        char parsed[512];
        size_t n = 0;
        if (*p == '"') {
            p++;
            while (*p && *p != '"' && *p != '\r' && *p != '\n') {
                if (*p == '\\' && p[1])
                    p++;
                if (n + 1 < sizeof parsed)
                    parsed[n++] = *p;
                p++;
            }
            if (*p == '"')
                p++;
        } else {
            while (*p && *p != ',' && *p != '\r' && *p != '\n') {
                if (n + 1 < sizeof parsed)
                    parsed[n++] = *p;
                p++;
            }
            while (n && (parsed[n - 1] == ' ' || parsed[n - 1] == '\t'))
                n--;
        }
        parsed[n] = 0;
        if (strlen(name) == key_length && !strncasecmp(key, name, key_length)) {
            if (n >= size)
                return 0;
            memcpy(value, parsed, n + 1);
            return 1;
        }
        while (*p && *p != ',' && *p != '\r' && *p != '\n')
            p++;
    }
    return 0;
}

static void
md5_hex(const char *text, char out[33])
{
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(text, (CC_LONG)strlen(text), digest);
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        snprintf(out + i * 2, 3, "%02x", digest[i]);
}

static int
valid_digest(const char *request, const char *method, const char *path)
{
    char username[128], realm[128], nonce[128], uri[512], response[64];
    char qop[32], cnonce[128], nc[16], opaque[128], algorithm[32];
    if (!digest_field(request, "username", username, sizeof username) || strcmp(username, "ada") ||
        !digest_field(request, "realm", realm, sizeof realm) || strcmp(realm, "Finch Digest") ||
        !digest_field(request, "nonce", nonce, sizeof nonce) || strcmp(nonce, "finch-fixed-nonce") ||
        !digest_field(request, "uri", uri, sizeof uri) || strcmp(uri, path) ||
        !digest_field(request, "response", response, sizeof response) ||
        !digest_field(request, "qop", qop, sizeof qop) || strcasecmp(qop, "auth") ||
        !digest_field(request, "cnonce", cnonce, sizeof cnonce) || !cnonce[0] ||
        !digest_field(request, "nc", nc, sizeof nc) || strlen(nc) != 8 ||
        !digest_field(request, "opaque", opaque, sizeof opaque) || strcmp(opaque, "finch-fixed-opaque") ||
        !digest_field(request, "algorithm", algorithm, sizeof algorithm) || strcasecmp(algorithm, "MD5"))
        return 0;
    for (int i = 0; i < 8; i++)
        if (!isxdigit((unsigned char)nc[i]))
            return 0;
    char source[1024], ha1[33], ha2[33], expected[33];
    snprintf(source, sizeof source, "%s:%s:%s", username, realm, "secret");
    md5_hex(source, ha1);
    snprintf(source, sizeof source, "%s:%s", method, uri);
    md5_hex(source, ha2);
    snprintf(source, sizeof source, "%s:%s:%s:%s:%s:%s", ha1, nonce, nc, cnonce, qop, ha2);
    md5_hex(source, expected);
    return !strcasecmp(response, expected);
}

static void
serve_big(int fd, const char *req, int *served)
{
    const char *range = strcasestr(req, "\r\nRange: bytes=");
    long from = range ? atol(range + 15) : 0;
    snprintf(last_range, sizeof last_range, "%s", range ? "" : "(none)");
    if (range)
        sscanf(range + 9, "%63[^\r]", last_range);
    char head[512];
    if (from > 0)
        snprintf(head, sizeof head,
                 "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nETag: \"v1\"\r\n"
                 "Last-Modified: Thu, 01 Oct 2026 00:00:00 GMT\r\nAccept-Ranges: bytes\r\n"
                 "Content-Range: bytes %ld-%d/%d\r\nContent-Length: %ld\r\n\r\n",
                 from, BIG - 1, BIG, BIG - from);
    else
        snprintf(head, sizeof head,
                 "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nETag: \"v1\"\r\n"
                 "Last-Modified: Thu, 01 Oct 2026 00:00:00 GMT\r\nAccept-Ranges: bytes\r\nContent-Length: %d\r\n\r\n",
                 BIG);
    write(fd, head, strlen(head));
    if (from == 0 && !(*served)++) {
        write(fd, big_body, BIG / 2);
        if (served == &stall_served)
            sleep(30); /* (until the client cancels) */
        return;
    }
    write(fd, big_body + from, BIG - from);
}

/* Serves one canned response per connection, chosen by the request path. */
static void *
handle(void *arg)
{
    int fd = (int)(intptr_t)arg;
    {
        char req[4096];
        ssize_t n = 0, r;
        while (n < (ssize_t)sizeof req - 1 && (r = read(fd, req + n, sizeof req - 1 - n)) > 0) {
            n += r;
            req[n] = 0;
            if (strstr(req, "\r\n\r\n")) {
                const char *cl = strcasestr(req, "Content-Length:");
                long body = cl ? atol(cl + 15) : 0;
                if (n - (strstr(req, "\r\n\r\n") + 4 - req) >= body)
                    break;
            }
        }
        req[n] = 0;
        char path[256] = "";
        char method[16] = "";
        sscanf(req, "%15s %255s", method, path);
        char out[8192];
        if (!strcmp(path, "/big") || !strcmp(path, "/stall") || !strcmp(path, "/big2")) {
            serve_big(fd, req, !strcmp(path, "/big") ? &big_served : !strcmp(path, "/big2") ? &big2_served : &stall_served);
            close(fd);
            return NULL;
        }
        if (!strcmp(path, "/auth")) {
            /* ada:secret */
            if (strstr(req, "\r\nAuthorization: Basic YWRhOnNlY3JldA==\r\n"))
                snprintf(out, sizeof out, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\nwelcome");
            else
                snprintf(out, sizeof out,
                         "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Finch Test\"\r\n"
                         "Content-Type: text/plain\r\nContent-Length: 6\r\n\r\ndenied");
        } else if (!strcmp(path, "/digest")) {
            if (valid_digest(req, method, path))
                snprintf(out, sizeof out, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\nwelcome");
            else
                snprintf(out, sizeof out,
                         "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"Finch Digest\", nonce=\"finch-fixed-nonce\", "
                         "opaque=\"finch-fixed-opaque\", qop=\"auth\", algorithm=MD5\r\n"
                         "Content-Type: text/plain\r\nContent-Length: 6\r\n\r\ndenied");
        } else if (!strcmp(path, "/hello")) {
            snprintf(out, sizeof out,
                     "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 6\r\nX-Test: one\r\n\r\nhello\n");
        } else if (!strcmp(path, "/chunked")) {
            snprintf(out, sizeof out,
                     "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
                     "5\r\n{\"a\":\r\n3\r\n 1}\r\n0\r\n\r\n");
        } else if (!strcmp(path, "/redirect")) {
            snprintf(out, sizeof out, "HTTP/1.1 302 Found\r\nLocation: /hello\r\nContent-Length: 0\r\n\r\n");
        } else if (!strcmp(path, "/echo")) {
            const char *ua = strcasestr(req, "\r\nX-Echo:");
            char value[64] = "";
            if (ua)
                sscanf(ua + 9, " %63[^\r]", value);
            const char *body = strstr(req, "\r\n\r\n") + 4;
            char text[512];
            snprintf(text, sizeof text, "%s %s body=%s", method, value, body);
            snprintf(out, sizeof out, "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\n\r\n%s",
                     strlen(text), text);
        } else {
            snprintf(out, sizeof out, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 9\r\n\r\nnot found");
        }
        write(fd, out, strlen(out));
        shutdown(fd, SHUT_WR);
        char drain[256];
        while (read(fd, drain, sizeof drain) > 0)
            ;
        close(fd);
    }
    return NULL;
}

static void *
serve(void *arg)
{
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            break;
        pthread_t t;
        pthread_create(&t, NULL, handle, (void *)(intptr_t)fd);
        pthread_detach(t);
    }
    return NULL;
}

static void
start_server(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(s, (struct sockaddr *)&a, sizeof a);
    listen(s, 8);
    socklen_t len = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &len);
    port = ntohs(a.sin_port);
    pthread_t t;
    pthread_create(&t, NULL, serve, (void *)(intptr_t)s);
}

static NSURL *
local(NSString *path)
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", port, path]];
}

/* The response, minus what varies between runs (ports, dates). */
static void
print_result(NSString *label, NSData *data, NSURLResponse *response, NSError *error)
{
    printf("%s:\n", label.UTF8String);
    if (error) {
        printf("  error %s %ld\n", error.domain.UTF8String, (long)error.code);
        return;
    }
    NSString *url = response.URL.absoluteString;
    url = [url stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@":%d", port] withString:@":PORT"];
    printf("  class %s url %s\n", NSStringFromClass([response class]).UTF8String, url.UTF8String);
    printf("  MIME %s encoding %s length %lld suggested %s\n", response.MIMEType.UTF8String ?: "(nil)",
           response.textEncodingName.UTF8String ?: "(nil)", response.expectedContentLength,
           response.suggestedFilename.UTF8String);
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)response;
        printf("  status %ld x-test %s\n", (long)h.statusCode, [h valueForHTTPHeaderField:@"x-TEST"].UTF8String ?: "(nil)");
    }
    printf("  data (%lu) %s\n", (unsigned long)data.length,
           [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"\n"
                                                                                                         withString:@"\\n"]
               .UTF8String);
}

static void
load(NSString *label, NSURLRequest *request)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                       print_result(label, data, response, error);
                                       dispatch_semaphore_signal(done);
                                     }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

/* A session delegate that says what it's told, and answers as the test sets it to. */
@interface Watcher : NSObject <NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (retain) NSMutableData *data;
@property (retain) dispatch_semaphore_t done;
@property (retain) NSArray<NSURLCredential *> *credentials; /* given in turn; then cancel */
@property BOOL stopRedirects, refuseResponse;
@property int writes, challenges;
@property int64_t lastWritten, lastExpected;
@end

@implementation Watcher
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)c
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    NSURLProtectionSpace *space = c.protectionSpace;
    printf("  challenge: %s realm %s host %s port ours %d protocol %s secure %d failures %ld proposed %s status %ld\n",
           space.authenticationMethod.UTF8String, space.realm.UTF8String, space.host.UTF8String, space.port == port,
           space.protocol.UTF8String, space.receivesCredentialSecurely, (long)c.previousFailureCount,
           c.proposedCredential.user.UTF8String ?: "(none)", (long)((NSHTTPURLResponse *)c.failureResponse).statusCode);
    int n = self.challenges++;
    if (n < (int)self.credentials.count)
        completionHandler(NSURLSessionAuthChallengeUseCredential, self.credentials[n]);
    else
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    printf("  redirect: %ld to %s, %s\n", (long)response.statusCode, request.URL.path.UTF8String, self.stopRedirects ? "stopped" : "followed");
    completionHandler(self.stopRedirects ? nil : request);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    printf("  response: %ld task response same %d\n", (long)((NSHTTPURLResponse *)response).statusCode, task.response == response);
    completionHandler(self.refuseResponse ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten
    totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    self.writes++;
    self.lastWritten = totalBytesWritten;
    self.lastExpected = totalBytesExpectedToWrite;
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didResumeAtOffset:(int64_t)fileOffset
    expectedTotalBytes:(int64_t)expectedTotalBytes
{
    printf("  resumed at %lld of %lld\n", fileOffset, expectedTotalBytes);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location
{
    printf("  downloaded: progress reports %d last %lld of %lld file %lu\n", self.writes > 0, self.lastWritten, self.lastExpected,
           (unsigned long)[NSData dataWithContentsOfURL:location].length);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    printf("  complete: error %ld status %ld data %s\n", (long)error.code, (long)((NSHTTPURLResponse *)task.response).statusCode,
           [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding].UTF8String);
    dispatch_semaphore_signal(self.done);
}
@end

/* A task in a session of its own with a Watcher, run to the end. */
static NSURLSession *
watched(NSString *label, Watcher *w, NSURLSessionTask * (^make)(NSURLSession *))
{
    printf("%s:\n", label.UTF8String);
    w.data = [NSMutableData data];
    w.done = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                          delegate:w
                                                     delegateQueue:nil];
    [make(session) resume];
    dispatch_semaphore_wait(w.done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    return session;
}

/* A download that ends with resume data, resumed from it. */
static void
resumed(NSString *label, NSData *resumeData)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession]
        downloadTaskWithResumeData:resumeData
                 completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                   NSData *got = [NSData dataWithContentsOfURL:location];
                   printf("%s resumed: error %ld status %ld range %s size %lu intact %d\n", label.UTF8String, (long)error.code,
                          (long)((NSHTTPURLResponse *)response).statusCode, last_range, (unsigned long)got.length,
                          [got isEqualToData:[NSData dataWithBytes:big_body length:BIG]]);
                   dispatch_semaphore_signal(done);
                 }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

@interface Delegate : NSObject <NSURLSessionDataDelegate>
@property (retain) NSMutableData *data;
@property (retain) dispatch_semaphore_t done;
@end

@implementation Delegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    printf("delegate: complete error %ld state %ld data %s\n", (long)error.code, (long)task.state,
           [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding].UTF8String);
    dispatch_semaphore_signal(self.done);
}
@end

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge const void *)[NSURLSession class], &info);
        printf("NSURLSession from %s\n", info.dli_fname);
        start_server();

        /* Requests. */
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.com/a?b=c"]];
        printf("method %s timeout %.0f cache %lu cookies %d\n", r.HTTPMethod.UTF8String, r.timeoutInterval,
               (unsigned long)r.cachePolicy, r.HTTPShouldHandleCookies);
        printf("headers %s\n", r.allHTTPHeaderFields ? "set" : "(nil)");
        [r setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        [r addValue:@"a" forHTTPHeaderField:@"Accept"];
        [r addValue:@"b" forHTTPHeaderField:@"accept"];
        printf("content-type %s accept %s count %lu\n", [r valueForHTTPHeaderField:@"content-type"].UTF8String,
               [r valueForHTTPHeaderField:@"ACCEPT"].UTF8String, (unsigned long)r.allHTTPHeaderFields.count);
        [r setValue:nil forHTTPHeaderField:@"CONTENT-TYPE"];
        printf("after removal count %lu\n", (unsigned long)r.allHTTPHeaderFields.count);
        r.HTTPMethod = @"POST";
        r.HTTPBody = [@"x=1" dataUsingEncoding:NSUTF8StringEncoding];
        NSURLRequest *copy = [r copy];
        NSMutableURLRequest *mcopy = [copy mutableCopy];
        printf("copy class %s equal %d method %s body %lu\n", NSStringFromClass([copy class]).UTF8String,
               [copy isEqual:r], copy.HTTPMethod.UTF8String, (unsigned long)copy.HTTPBody.length);
        mcopy.HTTPMethod = @"PUT";
        printf("mutated copy equal %d original %s\n", [mcopy isEqual:r], r.HTTPMethod.UTF8String);
        NSURLRequest *plain = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.com/"]];
        printf("immutable copy same %d\n", [plain copy] == plain);
        NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:r requiringSecureCoding:YES error:NULL];
        NSURLRequest *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURLRequest class] fromData:archived error:NULL];
        printf("archived %s %s accept %s body %lu\n", back.HTTPMethod.UTF8String, back.URL.absoluteString.UTF8String,
               [back valueForHTTPHeaderField:@"Accept"].UTF8String, (unsigned long)back.HTTPBody.length);

        /* Responses. */
        NSHTTPURLResponse *h = [[NSHTTPURLResponse alloc]
             initWithURL:[NSURL URLWithString:@"https://example.com/dir/"]
              statusCode:404
             HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"content-type" : @"text/html; charset=ISO-8859-1", @"Content-Length" : @"42"}];
        printf("response MIME %s encoding %s length %lld suggested %s status %ld\n", h.MIMEType.UTF8String,
               h.textEncodingName.UTF8String, h.expectedContentLength, h.suggestedFilename.UTF8String, (long)h.statusCode);
        for (NSNumber *code in @[ @200, @204, @301, @404, @418, @500, @503 ])
            printf("  %d: %s\n", code.intValue, [NSHTTPURLResponse localizedStringForStatusCode:code.integerValue].UTF8String);
        NSURLResponse *plainResponse = [[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/report.pdf"]
                                                                  MIMEType:@"application/pdf"
                                                     expectedContentLength:-1
                                                          textEncodingName:nil];
        printf("plain response suggested %s length %lld\n", plainResponse.suggestedFilename.UTF8String,
               plainResponse.expectedContentLength);

        /* Loading. */
        NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-urlsession-test.txt"];
        [@"file contents" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        load(@"file", [NSURLRequest requestWithURL:[NSURL fileURLWithPath:file]]);
        load(@"missing file", [NSURLRequest requestWithURL:[NSURL fileURLWithPath:@"/nonexistent/finch"]]);
        load(@"data base64", [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:text/plain;base64,aGVsbG8gZGF0YQ=="]]);
        load(@"data plain", [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:,a%20b"]]);
        load(@"unsupported", [NSURLRequest requestWithURL:[NSURL URLWithString:@"gopher://example.com/"]]);
        load(@"http", [NSURLRequest requestWithURL:local(@"/hello")]);
        load(@"http chunked", [NSURLRequest requestWithURL:local(@"/chunked")]);
        load(@"http redirect", [NSURLRequest requestWithURL:local(@"/redirect")]);
        load(@"http 404", [NSURLRequest requestWithURL:local(@"/missing")]);
        NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:local(@"/echo")];
        post.HTTPMethod = @"POST";
        post.HTTPBody = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
        [post setValue:@"echoed" forHTTPHeaderField:@"X-Echo"];
        load(@"http post", post);
        load(@"refused", [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/"]]);

        /* A download, and a delegate session. */
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession]
            downloadTaskWithURL:local(@"/hello")
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                printf("download: file %d exists %d contents %s\n", location.isFileURL,
                       [[NSFileManager defaultManager] fileExistsAtPath:location.path],
                       [[NSString stringWithContentsOfURL:location encoding:NSUTF8StringEncoding error:NULL]
                           stringByReplacingOccurrencesOfString:@"\n"
                                                     withString:@"\\n"]
                           .UTF8String);
                dispatch_semaphore_signal(done);
              }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

        /* A download whose connection drops halfway, then one cancelled halfway. */
        for (int i = 0; i < BIG; i++)
            big_body[i] = (char)('a' + i % 26 + i / 4096);
        __block NSData *resumeData = nil;
        [[[NSURLSession sharedSession]
            downloadTaskWithURL:local(@"/big")
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
                printf("dropped download: file %d error %ld resume data %d\n", location != nil, (long)error.code, resumeData != nil);
                dispatch_semaphore_signal(done);
              }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (resumeData)
            resumed(@"dropped", resumeData);
        resumeData = nil;
        NSURLSessionDownloadTask *stalled = [[NSURLSession sharedSession]
            downloadTaskWithURL:local(@"/stall")
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                printf("cancelled download: error %ld has resume data %d\n", (long)error.code,
                       error.userInfo[NSURLSessionDownloadTaskResumeData] != nil);
                dispatch_semaphore_signal(done);
              }];
        [stalled resume];
        while (stalled.countOfBytesReceived < BIG / 2)
            usleep(50000);
        [stalled cancelByProducingResumeData:^(NSData *data) {
          resumeData = data;
          printf("cancel: resume data %d received %lld\n", data != nil, stalled.countOfBytesReceived);
          dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (resumeData)
            resumed(@"cancelled", resumeData);

        /* Password challenges. */
        load(@"auth, no password", [NSURLRequest requestWithURL:local(@"/auth")]);
        load(@"auth, password in the URL",
             [NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://ada:secret@127.0.0.1:%d/auth", port]]]);
        NSURLProtectionSpace *space = [[NSURLProtectionSpace alloc] initWithHost:@"127.0.0.1" port:port protocol:@"http"
                                                                           realm:@"Finch Test"
                                                            authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
        printf("shared storage after: default %s count %lu\n",
               [NSURLCredentialStorage.sharedCredentialStorage defaultCredentialForProtectionSpace:space].user.UTF8String ?: "(none)",
               (unsigned long)[NSURLCredentialStorage.sharedCredentialStorage credentialsForProtectionSpace:space].count);
        load(@"auth, from the storage", [NSURLRequest requestWithURL:local(@"/auth")]);
        Watcher *w = [Watcher new];
        w.credentials = @[ [NSURLCredential credentialWithUser:@"ada" password:@"wrong" persistence:NSURLCredentialPersistenceForSession],
                           [NSURLCredential credentialWithUser:@"ada" password:@"secret" persistence:NSURLCredentialPersistenceForSession] ];
        NSURLSession *ws = watched(@"delegate auth", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/auth")]; });
        printf("  session storage: default %s\n",
               [ws.configuration.URLCredentialStorage defaultCredentialForProtectionSpace:space].user.UTF8String ?: "(none)");
        w = [Watcher new];
        watched(@"delegate auth cancelled", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/auth")]; });

        load(@"digest, no password", [NSURLRequest requestWithURL:local(@"/digest")]);
        load(@"digest, password in the URL",
             [NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://ada:secret@127.0.0.1:%d/digest", port]]]);
        w = [Watcher new];
        w.credentials = @[ [NSURLCredential credentialWithUser:@"ada" password:@"wrong" persistence:NSURLCredentialPersistenceForSession],
                           [NSURLCredential credentialWithUser:@"ada" password:@"secret" persistence:NSURLCredentialPersistenceForSession] ];
        watched(@"delegate digest auth", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/digest")]; });
        w = [Watcher new];
        watched(@"delegate digest auth cancelled", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/digest")]; });

        w = [Watcher new];
        watched(@"delegate redirect", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/redirect")]; });
        w = [Watcher new];
        w.stopRedirects = YES;
        watched(@"delegate redirect stopped", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/redirect")]; });
        w = [Watcher new];
        w.refuseResponse = YES;
        watched(@"delegate response refused", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/hello")]; });
        w = [Watcher new];
        watched(@"delegate chunked", w, ^(NSURLSession *session) { return [session dataTaskWithURL:local(@"/chunked")]; });
        w = [Watcher new];
        watched(@"delegate download", w, ^(NSURLSession *session) { return [session downloadTaskWithURL:local(@"/big")]; });
        __block NSData *more = nil;
        [[[NSURLSession sharedSession] downloadTaskWithURL:local(@"/big2")
                                         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                                           more = error.userInfo[NSURLSessionDownloadTaskResumeData];
                                           dispatch_semaphore_signal(done);
                                         }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        w = [Watcher new];
        watched(@"delegate resumed download", w, ^(NSURLSession *session) { return [session downloadTaskWithResumeData:more]; });

        Delegate *d = [Delegate new];
        d.data = [NSMutableData data];
        d.done = dispatch_semaphore_create(0);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                              delegate:d
                                                         delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithURL:local(@"/hello")];
        printf("task id %lu state %ld\n", (unsigned long)task.taskIdentifier, (long)task.state);
        [task resume];
        dispatch_semaphore_wait(d.done, DISPATCH_TIME_FOREVER);
        printf("task state %ld response status %ld\n", (long)task.state, (long)((NSHTTPURLResponse *)task.response).statusCode);
        [session finishTasksAndInvalidate];
    }
    return 0;
}

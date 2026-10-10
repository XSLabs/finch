/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cfnetwork-test: CFNetwork's HTTP messages, authentication, HTTP and socket
 * streams (against a server in this process, on the loopback), CFHost, proxies, FTP
 * listings and TXT records, one result per line so runs against Apple's CFNetwork
 * and Finch's can be diffed. What's sent on the wire is printed too, with the
 * server's port (which differs from run to run) as PORT.
 */
#include <CFNetwork/CFNetwork.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* exported by CFNetwork, though no header declares it */
static void (*CFHTTPMessageSetResponseURL)(CFHTTPMessageRef response, CFURLRef url);

static int port;
static int listener;
static char wire[16][2048];
static int served;

static void
cstr(CFTypeRef v, char *b, size_t n)
{
    snprintf(b, n, "(null)");
    if (!v)
        return;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString(v, b, (CFIndex)n, kCFStringEncodingUTF8);
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        long long x = 0;
        CFNumberGetValue(v, kCFNumberLongLongType, &x);
        snprintf(b, n, "%lld", x);
    } else if (CFGetTypeID(v) == CFURLGetTypeID()) {
        CFStringGetCString(CFURLGetString(v), b, (CFIndex)n, kCFStringEncodingUTF8);
    } else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        snprintf(b, n, "%s", CFBooleanGetValue(v) ? "true" : "false");
    } else if (CFGetTypeID(v) == CFDataGetTypeID()) {
        size_t o = (size_t)snprintf(b, n, "<%ld bytes>", (long)CFDataGetLength(v));
        (void)o;
    } else if (CFGetTypeID(v) == CFDateGetTypeID()) {
        snprintf(b, n, "date %.0f", CFDateGetAbsoluteTime(v));
    } else {
        snprintf(b, n, "(type %lu)", (unsigned long)CFGetTypeID(v));
    }
}

/* Prints s with the port replaced and CR/LF escaped. */
static void
print_masked(const char *label, const char *s)
{
    char p[16];
    snprintf(p, sizeof p, "%d", port);
    printf("%s: ", label);
    for (const char *c = s; *c;) {
        if (!strncmp(c, p, strlen(p))) {
            fputs("PORT", stdout);
            c += strlen(p);
        } else if (*c == '\r') {
            fputs("\\r", stdout);
            c++;
        } else if (*c == '\n') {
            fputs("\\n", stdout);
            c++;
        } else {
            putchar(*c++);
        }
    }
    putchar('\n');
}

static void
show(const char *label, CFTypeRef v)
{
    char b[1024];
    cstr(v, b, sizeof b);
    print_masked(label, b);
}

static void
show_dict(const char *label, CFDictionaryRef d)
{
    if (!d) {
        printf("%s: (null)\n", label);
        return;
    }
    CFIndex n = CFDictionaryGetCount(d);
    const void *keys[64], *values[64];
    CFDictionaryGetKeysAndValues(d, keys, values);
    /* sorted by key, so the order doesn't depend on hashing */
    for (CFIndex i = 0; i < n; i++)
        for (CFIndex j = i + 1; j < n; j++)
            if (CFStringCompare(keys[j], keys[i], 0) < 0) {
                const void *t = keys[i];
                keys[i] = keys[j];
                keys[j] = t;
                t = values[i];
                values[i] = values[j];
                values[j] = t;
            }
    printf("%s: %ld entries\n", label, (long)n);
    for (CFIndex i = 0; i < n; i++) {
        char k[256], v[1024], l[300];
        cstr(keys[i], k, sizeof k);
        cstr(values[i], v, sizeof v);
        snprintf(l, sizeof l, "  %s", k);
        print_masked(l, v);
    }
}

/* --- the server --- */

static void
reply(int c, const char *s, size_t n)
{
    while (n) {
        ssize_t w = write(c, s, n);
        if (w <= 0)
            return;
        s += w;
        n -= (size_t)w;
    }
}

static void *
server(void *arg)
{
    for (;;) {
        int c = accept(listener, NULL, NULL);
        if (c < 0)
            return NULL;
        char req[2048] = {0};
        size_t have = 0;
        while (have < sizeof req - 1 && !strstr(req, "\r\n\r\n")) {
            ssize_t r = read(c, req + have, sizeof req - 1 - have);
            if (r <= 0)
                break;
            have += (size_t)r;
        }
        /* a body announced: read it too */
        char *cl = strcasestr(req, "Content-Length: ");
        char *end = strstr(req, "\r\n\r\n");
        if (cl && end) {
            size_t want = (size_t)atoi(cl + 16), got = have - (size_t)(end + 4 - req);
            while (got < want && have < sizeof req - 1) {
                ssize_t r = read(c, req + have, sizeof req - 1 - have);
                if (r <= 0)
                    break;
                have += (size_t)r;
                got += (size_t)r;
            }
        }
        if (served < 16)
            snprintf(wire[served++], sizeof wire[0], "%s", req);
        if (!strncmp(req, "ECHO", 4)) {
            reply(c, req, have);
        } else if (strstr(req, " /redir ")) {
            const char *r = "HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\n\r\n";
            reply(c, r, strlen(r));
        } else if (strstr(req, " /chunk ")) {
            const char *r = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: 1\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
            reply(c, r, strlen(r));
        } else if (strstr(req, " /missing ")) {
            const char *r = "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 9\r\n\r\nnot here!";
            reply(c, r, strlen(r));
        } else if (strstr(req, " /close ")) {
            const char *r = "HTTP/1.0 200 OK\r\nServer: test\r\n\r\nuntil the end";
            reply(c, r, strlen(r));
        } else {
            const char *r = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world";
            reply(c, r, strlen(r));
        }
        close(c);
    }
}

static CFURLRef
url(const char *path)
{
    char u[256];
    snprintf(u, sizeof u, "http://127.0.0.1:%d%s", port, path);
    return CFURLCreateWithBytes(NULL, (const UInt8 *)u, (CFIndex)strlen(u), kCFStringEncodingUTF8, NULL);
}

static void
wait_served(int n)
{
    for (int i = 0; i < 200 && served < n; i++)
        usleep(10000);
}

/* --- HTTP streams --- */

static void
get(const char *label, const char *path, const char *method, const char *body, bool redirect)
{
    printf("== %s\n", label);
    CFURLRef u = url(path);
    CFHTTPMessageRef m = CFHTTPMessageCreateRequest(NULL, CFStringCreateWithCString(NULL, method, kCFStringEncodingUTF8),
                                                    u, kCFHTTPVersion1_1);
    if (body) {
        CFDataRef d = CFDataCreate(NULL, (const UInt8 *)body, (CFIndex)strlen(body));
        CFHTTPMessageSetBody(m, d);
        CFHTTPMessageSetHeaderFieldValue(m, CFSTR("User-Agent"), CFSTR("mine"));
        CFHTTPMessageSetHeaderFieldValue(m, CFSTR("X-Extra"), CFSTR("1"));
    }
    CFReadStreamRef s = CFReadStreamCreateForHTTPRequest(NULL, m);
    show("autoredirect default", CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPShouldAutoredirect));
    if (redirect)
        CFReadStreamSetProperty(s, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
    int before = served;
    printf("open %d status %ld\n", CFReadStreamOpen(s), (long)CFReadStreamGetStatus(s));
    char got[256] = {0};
    size_t have = 0;
    UInt8 buf[4];
    CFIndex n;
    while ((n = CFReadStreamRead(s, buf, sizeof buf)) > 0 && have + (size_t)n < sizeof got) {
        memcpy(got + have, buf, (size_t)n);
        have += (size_t)n;
    }
    printf("body \"%s\" last %ld status %ld\n", got, (long)n, (long)CFReadStreamGetStatus(s));
    CFHTTPMessageRef r = (CFHTTPMessageRef)CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPResponseHeader);
    if (r) {
        show("status line", CFHTTPMessageCopyResponseStatusLine(r));
        printf("status %ld\n", (long)CFHTTPMessageGetResponseStatusCode(r));
        show_dict("headers", CFHTTPMessageCopyAllHeaderFields(r));
        show("response URL", CFHTTPMessageCopyRequestURL(r));
        show("version", CFHTTPMessageCopyVersion(r));
        CFDataRef b = CFHTTPMessageCopyBody(r);
        printf("response body %ld\n", b ? (long)CFDataGetLength(b) : -1L);
        printf("header complete %d\n", CFHTTPMessageIsHeaderComplete(r));
    } else {
        printf("no response header\n");
    }
    show("final URL", CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPFinalURL));
    CFHTTPMessageRef fr = (CFHTTPMessageRef)CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPFinalRequest);
    if (fr)
        show_dict("final request", CFHTTPMessageCopyAllHeaderFields(fr));
    show("bytes written", CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPRequestBytesWrittenCount));
    if (n < 0) {
        CFStreamError e = CFReadStreamGetError(s);
        printf("error %ld %d\n", (long)e.domain, (int)e.error);
        CFErrorRef err = CFReadStreamCopyError(s);
        if (err) {
            show("error domain", CFErrorGetDomain(err));
            printf("error code %ld\n", (long)CFErrorGetCode(err));
            show_dict("error info", CFErrorCopyUserInfo(err));
        }
    }
    CFReadStreamClose(s);
    CFRelease(s);
    wait_served(before + (redirect ? 2 : 1));
    for (int i = before; i < served; i++)
        print_masked("sent", wire[i]);
}

static CFIndex event_reads;

static void
event(CFReadStreamRef s, CFStreamEventType t, void *info)
{
    printf("event %lu status %ld\n", (unsigned long)t, (long)CFReadStreamGetStatus(s));
    if (t & kCFStreamEventHasBytesAvailable) {
        UInt8 b[4];
        CFIndex n = CFReadStreamRead(s, b, sizeof b);
        printf("  read %ld\n", (long)n);
        event_reads++;
    }
    if (t & (kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred))
        CFRunLoopStop(CFRunLoopGetCurrent());
}

static void
run_loop_get(const char *path)
{
    printf("== run loop %s\n", path);
    CFHTTPMessageRef m = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url(path), kCFHTTPVersion1_1);
    CFReadStreamRef s = CFReadStreamCreateForHTTPRequest(NULL, m);
    CFStreamClientContext ctx = {0, NULL, NULL, NULL, NULL};
    CFReadStreamSetClient(s, kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered |
                                 kCFStreamEventErrorOccurred,
                          event, &ctx);
    CFReadStreamScheduleWithRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    printf("open %d status %ld\n", CFReadStreamOpen(s), (long)CFReadStreamGetStatus(s));
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);
    CFReadStreamUnscheduleFromRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFReadStreamClose(s);
    CFRelease(s);
}

/* --- socket streams --- */

static void
socket_streams(void)
{
    printf("== socket streams\n");
    CFReadStreamRef r = NULL;
    CFWriteStreamRef w = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, CFSTR("127.0.0.1"), (UInt32)port, &r, &w);
    printf("made %d %d\n", r != NULL, w != NULL);
    show("host prop", CFReadStreamCopyProperty(r, kCFStreamPropertySocketRemoteHostName));
    printf("open %d %d\n", CFReadStreamOpen(r), CFWriteStreamOpen(w));
    /* wait for the connection */
    for (int i = 0; i < 500 && CFWriteStreamGetStatus(w) == kCFStreamStatusOpening; i++)
        usleep(10000);
    printf("status %ld %ld\n", (long)CFReadStreamGetStatus(r), (long)CFWriteStreamGetStatus(w));
    const char *msg = "ECHO hello\r\n\r\n";
    printf("wrote %ld\n", (long)CFWriteStreamWrite(w, (const UInt8 *)msg, (CFIndex)strlen(msg)));
    char got[64] = {0};
    size_t have = 0;
    while (have < strlen(msg)) {
        CFIndex n = CFReadStreamRead(r, (UInt8 *)got + have, (CFIndex)(sizeof got - 1 - have));
        if (n <= 0)
            break;
        have += (size_t)n;
    }
    print_masked("echoed", got);
    CFDataRef fd = CFReadStreamCopyProperty(r, kCFStreamPropertySocketNativeHandle);
    printf("native handle %ld bytes\n", fd ? (long)CFDataGetLength(fd) : -1L);
    UInt8 b[4];
    printf("then %ld status %ld\n", (long)CFReadStreamRead(r, b, 4), (long)CFReadStreamGetStatus(r));
    CFReadStreamClose(r);
    CFWriteStreamClose(w);

    /* refused */
    CFStreamCreatePairWithSocketToHost(NULL, CFSTR("127.0.0.1"), 1, &r, &w);
    CFReadStreamOpen(r);
    for (int i = 0; i < 500 && CFReadStreamGetStatus(r) == kCFStreamStatusOpening; i++)
        usleep(10000);
    CFStreamError e = CFReadStreamGetError(r);
    printf("refused status %ld error %ld %d\n", (long)CFReadStreamGetStatus(r), (long)e.domain, (int)e.error);
    CFReadStreamClose(r);
}

/* --- messages and authentication --- */

static void
messages(void)
{
    printf("== messages\n");
    CFHTTPMessageRef m = CFHTTPMessageCreateEmpty(NULL, false);
    const char *resp = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"r1\"\r\nWWW-Authenticate: Digest realm=\"r2\", nonce=\"abc\", opaque=\"xyz\"\r\nContent-Length: 2\r\n\r\nhi";
    printf("append %d\n", CFHTTPMessageAppendBytes(m, (const UInt8 *)resp, (CFIndex)strlen(resp)));
    printf("complete %d status %ld\n", CFHTTPMessageIsHeaderComplete(m), (long)CFHTTPMessageGetResponseStatusCode(m));
    show("www-authenticate", CFHTTPMessageCopyHeaderFieldValue(m, CFSTR("www-authenticate")));
    CFDataRef body = CFHTTPMessageCopyBody(m);
    printf("body %ld\n", body ? (long)CFDataGetLength(body) : -1L);

    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url("/dir/x?y=1"), kCFHTTPVersion1_1);
    CFHTTPAuthenticationRef a0 = CFHTTPAuthenticationCreateFromResponse(NULL, m);
    printf("no URL: valid %d\n", CFHTTPAuthenticationIsValid(a0, NULL));
    show("no URL: method", CFHTTPAuthenticationCopyMethod(a0));
    CFHTTPMessageSetResponseURL(m, url("/dir/x?y=1"));
    CFHTTPAuthenticationRef a = CFHTTPAuthenticationCreateFromResponse(NULL, m);
    CFStreamError e = {0, 0};
    printf("valid %d\n", CFHTTPAuthenticationIsValid(a, &e));
    show("method", CFHTTPAuthenticationCopyMethod(a));
    show("realm", CFHTTPAuthenticationCopyRealm(a));
    printf("requires user %d ordered %d domain %d applies %d\n", CFHTTPAuthenticationRequiresUserNameAndPassword(a),
           CFHTTPAuthenticationRequiresOrderedRequests(a), CFHTTPAuthenticationRequiresAccountDomain(a),
           CFHTTPAuthenticationAppliesToRequest(a, req));
    printf("apply %d\n", CFHTTPMessageApplyCredentials(req, a, CFSTR("user"), CFSTR("pass"), &e));
    show("authorization", CFHTTPMessageCopyHeaderFieldValue(req, CFSTR("Authorization")));

    CFHTTPMessageRef basic = CFHTTPMessageCreateEmpty(NULL, false);
    const char *b = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"only\"\r\n\r\n";
    CFHTTPMessageAppendBytes(basic, (const UInt8 *)b, (CFIndex)strlen(b));
    CFHTTPMessageSetResponseURL(basic, url("/"));
    CFHTTPAuthenticationRef ba = CFHTTPAuthenticationCreateFromResponse(NULL, basic);
    CFHTTPMessageRef req2 = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url("/"), kCFHTTPVersion1_1);
    printf("basic apply %d\n", CFHTTPMessageApplyCredentials(req2, ba, CFSTR("Aladdin"), CFSTR("open sesame"), &e));
    show("basic", CFHTTPMessageCopyHeaderFieldValue(req2, CFSTR("Authorization")));
    CFArrayRef domains = CFHTTPAuthenticationCopyDomains(ba);
    printf("domains %ld\n", domains ? (long)CFArrayGetCount(domains) : -1L);
    for (CFIndex i = 0; domains && i < CFArrayGetCount(domains); i++)
        show(" domain", CFArrayGetValueAtIndex(domains, i));

    CFHTTPMessageRef ntlm = CFHTTPMessageCreateEmpty(NULL, false);
    const char *n = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bogus\r\n\r\n";
    CFHTTPMessageAppendBytes(ntlm, (const UInt8 *)n, (CFIndex)strlen(n));
    CFHTTPMessageSetResponseURL(ntlm, url("/"));
    CFHTTPAuthenticationRef na = CFHTTPAuthenticationCreateFromResponse(NULL, ntlm);
    e.domain = e.error = 0;
    printf("bogus valid %d error %ld %d\n", CFHTTPAuthenticationIsValid(na, &e), (long)e.domain, (int)e.error);

    CFHTTPMessageRef s = CFHTTPMessageCreateRequest(NULL, CFSTR("POST"), url("/p?q"), kCFHTTPVersion1_0);
    CFHTTPMessageSetHeaderFieldValue(s, CFSTR("B"), CFSTR("2"));
    CFHTTPMessageSetHeaderFieldValue(s, CFSTR("A"), CFSTR("1"));
    CFHTTPMessageSetBody(s, CFDataCreate(NULL, (const UInt8 *)"xy", 2));
    CFDataRef ser = CFHTTPMessageCopySerializedMessage(s);
    char sb[512] = {0};
    memcpy(sb, CFDataGetBytePtr(ser), (size_t)CFDataGetLength(ser));
    print_masked("serialized", sb);
    CFHTTPMessageRef resp2 = CFHTTPMessageCreateResponse(NULL, 404, NULL, kCFHTTPVersion1_1);
    show("404 line", CFHTTPMessageCopyResponseStatusLine(resp2));
}

/* --- proxies, hosts, listings, TXT --- */

static void
num(CFMutableDictionaryRef m, CFStringRef k, int v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(m, k, n);
    CFRelease(n);
}

static void
proxies_for(const char *u, CFDictionaryRef settings)
{
    CFURLRef x = CFURLCreateWithBytes(NULL, (const UInt8 *)u, (CFIndex)strlen(u), kCFStringEncodingUTF8, NULL);
    CFArrayRef a = CFNetworkCopyProxiesForURL(x, settings);
    printf("%s: %ld\n", u, (long)CFArrayGetCount(a));
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++)
        show_dict(" proxy", CFArrayGetValueAtIndex(a, i));
}

static void
proxies(void)
{
    printf("== proxies\n");
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    num(m, CFSTR("HTTPEnable"), 1);
    CFDictionarySetValue(m, CFSTR("HTTPProxy"), CFSTR("h.p"));
    num(m, CFSTR("HTTPPort"), 8080);
    num(m, CFSTR("HTTPSEnable"), 1);
    CFDictionarySetValue(m, CFSTR("HTTPSProxy"), CFSTR("s.p"));
    num(m, CFSTR("SOCKSEnable"), 1);
    CFDictionarySetValue(m, CFSTR("SOCKSProxy"), CFSTR("k.p"));
    num(m, CFSTR("SOCKSPort"), 1080);
    num(m, CFSTR("FTPEnable"), 1);
    CFDictionarySetValue(m, CFSTR("FTPProxy"), CFSTR("f.p"));
    num(m, CFSTR("FTPPort"), 2121);
    num(m, CFSTR("ExcludeSimpleHostnames"), 1);
    const void *ex[] = {CFSTR("example.org"), CFSTR("10.0.0.0/8"), CFSTR("*.foo.com")};
    CFDictionarySetValue(m, CFSTR("ExceptionsList"), CFArrayCreate(NULL, ex, 3, &kCFTypeArrayCallBacks));
    const char *urls[] = {"http://example.com/", "https://example.com/", "ftp://example.com/", "ws://example.com/",
                          "http://simple/", "http://example.org/", "http://www.example.org/", "http://10.1.2.3/",
                          "http://foo.com/", "http://a.foo.com/"};
    for (size_t i = 0; i < sizeof urls / sizeof *urls; i++)
        proxies_for(urls[i], m);
    CFMutableDictionaryRef pac = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    num(pac, CFSTR("ProxyAutoConfigEnable"), 1);
    CFDictionarySetValue(pac, CFSTR("ProxyAutoConfigURLString"), CFSTR("http://wpad/wpad.dat"));
    proxies_for("http://x.com/", pac);
    proxies_for("http://x.com/", CFDictionaryCreate(NULL, NULL, NULL, 0, NULL, NULL));
    CFErrorRef e = NULL;
    CFArrayRef r = CFNetworkCopyProxiesForAutoConfigurationScript(
        CFSTR("function FindProxyForURL(url, host) { return \"PROXY a.b:3128; SOCKS c.d:1080; DIRECT\"; }"),
        url("/"), &e);
    printf("pac script: %ld\n", r ? (long)CFArrayGetCount(r) : -1L);
    for (CFIndex i = 0; r && i < CFArrayGetCount(r); i++)
        show_dict(" proxy", CFArrayGetValueAtIndex(r, i));
}

static void
hosts(void)
{
    printf("== hosts\n");
    CFHostRef h = CFHostCreateWithName(NULL, CFSTR("localhost"));
    CFStreamError e = {0, 0};
    printf("resolve %d\n", CFHostStartInfoResolution(h, kCFHostAddresses, &e));
    Boolean done = false;
    CFArrayRef a = CFHostGetAddressing(h, &done);
    printf("resolved %d\n", done);
    for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
        const struct sockaddr *sa = (const struct sockaddr *)CFDataGetBytePtr(CFArrayGetValueAtIndex(a, i));
        char t[64];
        inet_ntop(sa->sa_family, sa->sa_family == AF_INET ? (const void *)&((const struct sockaddr_in *)sa)->sin_addr
                                                           : (const void *)&((const struct sockaddr_in6 *)sa)->sin6_addr,
                  t, sizeof t);
        printf("  %s (%ld bytes)\n", t, (long)CFDataGetLength(CFArrayGetValueAtIndex(a, i)));
    }
    CFArrayRef names = CFHostGetNames(h, &done);
    printf("names %d %ld\n", done, names ? (long)CFArrayGetCount(names) : -1L);
    show(" name", names ? CFArrayGetValueAtIndex(names, 0) : NULL);
    printf("reachability %d\n", CFHostStartInfoResolution(h, kCFHostReachability, &e));
    CFDataRef reach = CFHostGetReachability(h, &done);
    printf("reachability %d %ld\n", done, reach ? (long)CFDataGetLength(reach) : -1L);
    /* (a name that needs DNS isn't looked up: on the host, getaddrinfo then loads Apple's
       Network framework, which can't load beside Finch's Foundation) */
}

static void
listing(const char *s)
{
    CFDictionaryRef d = NULL;
    CFIndex n = CFFTPCreateParsedResourceListing(NULL, (const UInt8 *)s, (CFIndex)strlen(s), &d);
    printf("listing %ld\n", (long)n);
    if (d) {
        /* the date (local time, this year) is shown as whether there is one */
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
        if (CFDictionaryContainsKey(m, kCFFTPResourceModDate))
            CFDictionarySetValue(m, kCFFTPResourceModDate, CFSTR("(date)"));
        show_dict(" entry", m);
    }
}

static void
ftp_and_txt(void)
{
    printf("== ftp\n");
    listing("-rw-r--r--   1 owner    group        1234 Jan  5 12:34 file.txt\r\n");
    listing("drwxr-xr-x   2 owner    group        4096 Mar 15  2021 dir\r\n");
    listing("lrwxrwxrwx   1 o g 7 Jan  5 12:34 link -> target\r\n");
    listing("total 12\r\n");
    listing("01-05-21  12:34PM       <DIR>          windir\r\n");
    listing("-rw-r--r--   1 owner    group        1234 Jan  5 12:34 partial");
    listing("");
    CFDictionaryRef d = NULL;
    const char *year = "drwxr-xr-x   2 owner    group        4096 Mar 15  2021 dir\r\n";
    CFFTPCreateParsedResourceListing(NULL, (const UInt8 *)year, (CFIndex)strlen(year), &d);
    CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(CFDateGetAbsoluteTime(CFDictionaryGetValue(d, kCFFTPResourceModDate)),
                                                       CFTimeZoneCopyDefault());
    printf("date %d-%d-%d %d:%d\n", (int)g.year, g.month, g.day, g.hour, g.minute);

    printf("== txt\n");
    const void *keys[] = {CFSTR("path"), CFSTR("empty"), CFSTR("data")};
    const void *values[] = {CFSTR("/x"), CFSTR(""), CFDataCreate(NULL, (const UInt8 *)"\x01\x02", 2)};
    CFDictionaryRef txt = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef rec = CFNetServiceCreateTXTDataWithDictionary(NULL, txt);
    printf("txt %ld bytes\n", rec ? (long)CFDataGetLength(rec) : -1L);
    show_dict("back", CFNetServiceCreateDictionaryWithTXTData(NULL, rec));
    CFNetServiceRef svc = CFNetServiceCreate(NULL, CFSTR("local."), CFSTR("_http._tcp."), CFSTR("Finch"), 8080);
    show("svc name", CFNetServiceGetName(svc));
    show("svc type", CFNetServiceGetType(svc));
    printf("svc port %d addressing %p\n", (int)CFNetServiceGetPortNumber(svc), (void *)CFNetServiceGetAddressing(svc));
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)CFHTTPMessageCreateEmpty, &info);
    printf("CFNetwork: %s\n", info.dli_fname);

    listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sin = {sizeof sin, AF_INET, 0, {htonl(INADDR_LOOPBACK)}, {0}};
    bind(listener, (struct sockaddr *)&sin, sizeof sin);
    socklen_t len = sizeof sin;
    getsockname(listener, (struct sockaddr *)&sin, &len);
    port = ntohs(sin.sin_port);
    listen(listener, 8);
    pthread_t t;
    pthread_create(&t, NULL, server, NULL);

    CFHTTPMessageSetResponseURL = (void (*)(CFHTTPMessageRef, CFURLRef))dlsym(RTLD_DEFAULT, "_CFHTTPMessageSetResponseURL");
    messages();
    get("GET", "/a?b=1", "GET", NULL, false);
    get("redirect", "/redir", "GET", NULL, true);
    get("redirect not followed", "/redir", "GET", NULL, false);
    get("chunked", "/chunk", "GET", NULL, false);
    get("404", "/missing", "GET", NULL, false);
    get("to the close", "/close", "GET", NULL, false);
    get("POST", "/post", "POST", "abc", false);
    get("HEAD", "/a", "HEAD", NULL, false);
    run_loop_get("/a");
    socket_streams();
    proxies();
    hosts();
    ftp_and_txt();

    printf("== refused\n");
    CFURLRef refused = CFURLCreateWithString(NULL, CFSTR("http://127.0.0.1:1/"), NULL);
    CFReadStreamRef s = CFReadStreamCreateForHTTPRequest(NULL, CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), refused, kCFHTTPVersion1_1));
    printf("open %d\n", CFReadStreamOpen(s));
    UInt8 b[4];
    printf("read %ld status %ld\n", (long)CFReadStreamRead(s, b, 4), (long)CFReadStreamGetStatus(s));
    CFStreamError e = CFReadStreamGetError(s);
    printf("error %ld %d\n", (long)e.domain, (int)e.error);
    CFErrorRef err = CFReadStreamCopyError(s);
    show("error domain", err ? CFErrorGetDomain(err) : NULL);
    printf("error code %ld\n", err ? (long)CFErrorGetCode(err) : 0L);
    show_dict("error info", err ? CFErrorCopyUserInfo(err) : NULL);
    return 0;
}

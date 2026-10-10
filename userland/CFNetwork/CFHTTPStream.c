/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The HTTP read stream (CFReadStreamCreateForHTTPRequest): sends a request and reads
 * back its response's body, as Apple's CFHTTPStream. HTTP/1.1, one request per
 * connection ("Connection: close"); https over OpenSSL; an HTTP proxy, or a CONNECT
 * tunnel through one, from kCFStreamPropertyHTTPProxy; redirects followed when
 * kCFStreamPropertyHTTPShouldAutoredirect is set. The response's head is the
 * kCFStreamPropertyHTTPResponseHeader property once it has arrived, and a chunked
 * body is decoded (the header then reads "Transfer-Encoding: Identity", as Apple's).
 *
 * The stream opens at once, as Apple's does, and the exchange runs on a thread of its
 * own: a read waits for the body's bytes, and a stream scheduled on a run loop is told
 * as they arrive.
 *
 * What's sent, as Apple's: the request line, Host, the request's own header fields,
 * Content-Length when there's a body, "Connection: close" and the default User-Agent
 * ("App (unknown version) CFNetwork/... Darwin/...") unless the request has one.
 */
#include "CFNetworkInternal.h"
#include <CoreFoundation/CFStream.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

/* CoreFoundation's abstract stream (CFStreamAbstract.h, not in the SDK). */
typedef struct {
    CFIndex version;
    void *(*create)(CFReadStreamRef, void *);
    void (*finalize)(CFReadStreamRef, void *);
    CFStringRef (*copyDescription)(CFReadStreamRef, void *);
    Boolean (*open)(CFReadStreamRef, CFErrorRef *, Boolean *, void *);
    Boolean (*openCompleted)(CFReadStreamRef, CFErrorRef *, void *);
    CFIndex (*read)(CFReadStreamRef, UInt8 *, CFIndex, CFErrorRef *, Boolean *, void *);
    const UInt8 *(*getBuffer)(CFReadStreamRef, CFIndex, CFIndex *, CFErrorRef *, Boolean *, void *);
    Boolean (*canRead)(CFReadStreamRef, CFErrorRef *, void *);
    void (*close)(CFReadStreamRef, void *);
    CFTypeRef (*copyProperty)(CFReadStreamRef, CFStringRef, void *);
    Boolean (*setProperty)(CFReadStreamRef, CFStringRef, CFTypeRef, void *);
    void (*requestEvents)(CFReadStreamRef, CFOptionFlags, void *);
    void (*schedule)(CFReadStreamRef, CFRunLoopRef, CFStringRef, void *);
    void (*unschedule)(CFReadStreamRef, CFRunLoopRef, CFStringRef, void *);
} CFReadStreamCallBacks;

extern CFReadStreamRef CFReadStreamCreate(CFAllocatorRef, const CFReadStreamCallBacks *, void *);
extern void CFReadStreamSignalEvent(CFReadStreamRef, CFStreamEventType, const void *);

enum { MAX_REDIRECTS = 16 };

typedef struct {
    _Atomic int refs;
    pthread_mutex_t m;
    pthread_cond_t cv;
    CFReadStreamRef stream; /* not retained; cleared when it goes */
    CFHTTPMessageRef request;
    CFReadStreamRef bodyStream; /* a streamed request's body */
    CFMutableDictionaryRef properties;
    bool started, closed;
    /* the exchange's results */
    CFHTTPMessageRef response, finalRequest;
    CFURLRef finalURL;
    CFMutableDataRef buffer; /* body bytes not yet read */
    bool done;
    CFErrorRef error;
    int64_t bytesWritten;
    int fd; /* the connection's, to abort it on close */
} HTTPStream;

static HTTPStream *
hs_retain(HTTPStream *h)
{
    h->refs++;
    return h;
}

static void
hs_release(HTTPStream *h)
{
    if (--h->refs)
        return;
    CFTypeRef owned[] = {h->request, h->bodyStream, h->properties, h->response, h->finalRequest, h->finalURL,
                         h->buffer, h->error};
    for (size_t i = 0; i < sizeof owned / sizeof *owned; i++)
        if (owned[i])
            CFRelease(owned[i]);
    pthread_mutex_destroy(&h->m);
    pthread_cond_destroy(&h->cv);
    free(h);
}

/* Under h->m: tells the stream's client. */
static void
hs_signal(HTTPStream *h, CFStreamEventType event)
{
    if (h->stream && !h->closed)
        CFReadStreamSignalEvent(h->stream, event, event == kCFStreamEventErrorOccurred ? h->error : NULL);
}

static void
hs_fail(HTTPStream *h, long domain, int code)
{
    pthread_mutex_lock(&h->m);
    if (!h->error)
        h->error = cfn_error(domain, code);
    h->done = true;
    pthread_cond_broadcast(&h->cv);
    hs_signal(h, kCFStreamEventErrorOccurred);
    pthread_mutex_unlock(&h->m);
}

static void
hs_deliver(HTTPStream *h, const UInt8 *bytes, CFIndex n)
{
    if (n <= 0)
        return;
    pthread_mutex_lock(&h->m);
    CFDataAppendBytes(h->buffer, bytes, n);
    pthread_cond_broadcast(&h->cv);
    hs_signal(h, kCFStreamEventHasBytesAvailable);
    pthread_mutex_unlock(&h->m);
}

/* --- the default User-Agent --- */

CFStringRef
_CFNetworkCopyDefaultUserAgentString(void)
{
    static CFStringRef agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      CFBundleRef main = CFBundleGetMainBundle();
      CFStringRef name = main ? CFBundleGetValueForInfoDictionaryKey(main, kCFBundleNameKey) : NULL;
      CFStringRef version = main ? CFBundleGetValueForInfoDictionaryKey(main, kCFBundleVersionKey) : NULL;
      CFStringRef app;
      if (name && version && CFGetTypeID(version) == CFStringGetTypeID()) {
          app = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), name, version);
      } else {
          const char *prog = getprogname();
          app = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s (unknown version)"), prog ? prog : "");
      }
      struct utsname u;
      uname(&u);
      CFBundleRef me = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.CFNetwork"));
      CFStringRef cfn = me ? CFBundleGetValueForInfoDictionaryKey(me, kCFBundleVersionKey) : NULL;
      agent = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ CFNetwork/%@ Darwin/%s"), app,
                                       cfn ? cfn : CFSTR("3860.500.112"), u.release);
      CFRelease(app);
    });
    return CFRetain(agent);
}

/* --- the exchange --- */

typedef struct {
    cfn_conn conn;
    UInt8 buf[16384];
    size_t have, at; /* bytes read but not yet used: buf[at..have) */
} Wire;

static ssize_t
wire_fill(Wire *w)
{
    if (w->at == w->have)
        w->at = w->have = 0;
    if (w->have == sizeof w->buf) {
        memmove(w->buf, w->buf + w->at, w->have - w->at);
        w->have -= w->at;
        w->at = 0;
    }
    ssize_t n = cfn_conn_read(&w->conn, w->buf + w->have, sizeof w->buf - w->have);
    if (n > 0)
        w->have += (size_t)n;
    return n;
}

/* A line (CRLF or LF ended) into line; false at the end of the connection. */
static bool
wire_line(Wire *w, char *line, size_t size)
{
    for (;;) {
        for (size_t i = w->at; i < w->have; i++) {
            if (w->buf[i] == '\n') {
                size_t len = i - w->at;
                if (len && w->buf[i - 1] == '\r')
                    len--;
                if (len >= size)
                    len = size - 1;
                memcpy(line, w->buf + w->at, len);
                line[len] = 0;
                w->at = i + 1;
                return true;
            }
        }
        if (wire_fill(w) <= 0)
            return false;
    }
}

static CFStringRef
url_host(CFURLRef url, int *port, bool *tls)
{
    CFStringRef scheme = CFURLCopyScheme(url);
    *tls = scheme && CFStringCompare(scheme, CFSTR("https"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (scheme)
        CFRelease(scheme);
    SInt32 p = CFURLGetPortNumber(url);
    *port = p >= 0 ? (int)p : *tls ? 443 : 80;
    return CFURLCopyHostName(url);
}

/* The proxy for this URL from kCFStreamPropertyHTTPProxy (a host, or NULL). */
static CFStringRef
proxy_for(HTTPStream *h, bool tls, int *port)
{
    pthread_mutex_lock(&h->m);
    CFDictionaryRef proxy = CFDictionaryGetValue(h->properties, kCFStreamPropertyHTTPProxy);
    CFStringRef host = NULL;
    if (proxy && CFGetTypeID(proxy) == CFDictionaryGetTypeID()) {
        CFStringRef hostKey = tls ? kCFStreamPropertyHTTPSProxyHost : kCFStreamPropertyHTTPProxyHost;
        CFStringRef portKey = tls ? kCFStreamPropertyHTTPSProxyPort : kCFStreamPropertyHTTPProxyPort;
        CFNumberRef enable = CFDictionaryGetValue(proxy, tls ? CFSTR("HTTPSEnable") : CFSTR("HTTPEnable"));
        int on = 1;
        if (enable && CFGetTypeID(enable) == CFNumberGetTypeID())
            CFNumberGetValue(enable, kCFNumberIntType, &on);
        CFStringRef hv = CFDictionaryGetValue(proxy, hostKey);
        if (on && hv && CFGetTypeID(hv) == CFStringGetTypeID() && CFStringGetLength(hv)) {
            host = CFRetain(hv);
            CFNumberRef pv = CFDictionaryGetValue(proxy, portKey);
            *port = 80;
            if (pv && CFGetTypeID(pv) == CFNumberGetTypeID())
                CFNumberGetValue(pv, kCFNumberIntType, port);
        }
    }
    pthread_mutex_unlock(&h->m);
    return host;
}

static bool
ssl_verify(HTTPStream *h, char **peer, const char *host)
{
    bool verify = true;
    *peer = strdup(host);
    pthread_mutex_lock(&h->m);
    CFDictionaryRef settings = CFDictionaryGetValue(h->properties, kCFStreamPropertySSLSettings);
    if (settings && CFGetTypeID(settings) == CFDictionaryGetTypeID()) {
        if (CFDictionaryGetValue(settings, kCFStreamSSLValidatesCertificateChain) == kCFBooleanFalse)
            verify = false;
        CFTypeRef name = CFDictionaryGetValue(settings, kCFStreamSSLPeerName);
        if (name == kCFNull) {
            free(*peer);
            *peer = NULL;
        } else if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
            free(*peer);
            *peer = cfn_cstring(name);
        }
    }
    pthread_mutex_unlock(&h->m);
    return verify;
}

static void
append(CFMutableDataRef d, CFStringRef s)
{
    char *c = cfn_cstring(s);
    if (c) {
        CFDataAppendBytes(d, (const UInt8 *)c, (CFIndex)strlen(c));
        free(c);
    }
}

static bool
has_header(CFHTTPMessageRef m, const char *name)
{
    return cfn_message_header(m, name) != NULL;
}

/* The request as it goes on the wire (its head; a CFData body follows when present). */
static CFDataRef
serialize_request(HTTPStream *h, CFHTTPMessageRef req, CFURLRef url, bool absoluteTarget, bool chunked)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CFStringRef method = CFHTTPMessageCopyRequestMethod(req);
    CFStringRef version = CFHTTPMessageCopyVersion(req);
    CFStringRef target;
    if (absoluteTarget) {
        target = CFRetain(CFURLGetString(url));
    } else {
        CFStringRef path = CFURLCopyPath(url), query = CFURLCopyQueryString(url, NULL);
        CFStringRef p = path && CFStringGetLength(path) ? path : CFSTR("/");
        target = query ? CFStringCreateWithFormat(NULL, NULL, CFSTR("%@?%@"), p, query) : CFRetain(p);
        if (path)
            CFRelease(path);
        if (query)
            CFRelease(query);
    }
    CFStringRef line = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ %@ %@\r\n"), method, target, version);
    append(d, line);
    CFRelease(line);
    CFRelease(target);
    CFRelease(version);
    CFArrayRef names = cfn_message_copy_header_names(req);
    CFMutableArrayRef fields = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks); /* "Name: value" in order */
    if (!has_header(req, "Host")) {
        CFStringRef host = CFURLCopyHostName(url);
        SInt32 port = CFURLGetPortNumber(url);
        bool v6 = host && CFStringFind(host, CFSTR(":"), 0).location != kCFNotFound;
        CFStringRef f = port >= 0 ? CFStringCreateWithFormat(NULL, NULL, CFSTR("Host: %s%@%s:%d"), v6 ? "[" : "", host,
                                                             v6 ? "]" : "", (int)port)
                                  : CFStringCreateWithFormat(NULL, NULL, CFSTR("Host: %s%@%s"), v6 ? "[" : "", host,
                                                             v6 ? "]" : "");
        CFArrayAppendValue(fields, f);
        CFRelease(f);
        if (host)
            CFRelease(host);
    }
    CFStringRef ua = NULL, connection = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
        CFStringRef name = CFArrayGetValueAtIndex(names, i);
        CFStringRef value = CFHTTPMessageCopyHeaderFieldValue(req, name);
        if (CFStringCompare(name, CFSTR("User-Agent"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            ua = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@: %@"), name, value);
        } else if (CFStringCompare(name, CFSTR("Connection"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            connection = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@: %@"), name, value);
        } else if (CFStringCompare(name, CFSTR("Content-Length"), kCFCompareCaseInsensitive) != kCFCompareEqualTo) {
            CFStringRef f = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@: %@"), name, value);
            CFArrayAppendValue(fields, f);
            CFRelease(f);
        }
        CFRelease(value);
    }
    CFRelease(names);
    CFDataRef body = CFHTTPMessageCopyBody(req);
    CFStringRef length = cfn_message_header(req, "Content-Length");
    if (chunked) {
        CFArrayAppendValue(fields, CFSTR("Transfer-Encoding: chunked"));
    } else if (body && CFDataGetLength(body)) {
        CFStringRef f = CFStringCreateWithFormat(NULL, NULL, CFSTR("Content-Length: %ld"), (long)CFDataGetLength(body));
        CFArrayAppendValue(fields, f);
        CFRelease(f);
    } else if (length) {
        CFStringRef f = CFStringCreateWithFormat(NULL, NULL, CFSTR("Content-Length: %@"), length);
        CFArrayAppendValue(fields, f);
        CFRelease(f);
    }
    if (body)
        CFRelease(body);
    CFArrayAppendValue(fields, connection ? connection : CFSTR("Connection: close"));
    if (!ua) {
        CFStringRef agent = _CFNetworkCopyDefaultUserAgentString();
        ua = CFStringCreateWithFormat(NULL, NULL, CFSTR("User-Agent: %@"), agent);
        CFRelease(agent);
    }
    CFArrayAppendValue(fields, ua);
    CFRelease(ua);
    if (connection)
        CFRelease(connection);
    for (CFIndex i = 0; i < CFArrayGetCount(fields); i++) {
        append(d, CFArrayGetValueAtIndex(fields, i));
        CFDataAppendBytes(d, (const UInt8 *)"\r\n", 2);
    }
    CFDataAppendBytes(d, (const UInt8 *)"\r\n", 2);
    CFRelease(fields);
    CFRelease(method);
    return d;
}

/* The request as Apple's kCFStreamPropertyHTTPFinalRequest shows it: the fields sent. */
static CFHTTPMessageRef
final_request(CFHTTPMessageRef req, CFURLRef url)
{
    CFHTTPMessageRef f = CFHTTPMessageCreateCopy(NULL, req);
    if (!has_header(f, "Host")) {
        CFStringRef host = CFURLCopyHostName(url);
        SInt32 port = CFURLGetPortNumber(url);
        CFStringRef v = port >= 0 ? CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%d"), host, (int)port) : CFRetain(host);
        CFHTTPMessageSetHeaderFieldValue(f, CFSTR("Host"), v);
        CFRelease(v);
        CFRelease(host);
    }
    CFDataRef body = CFHTTPMessageCopyBody(f);
    if (body && CFDataGetLength(body) && !has_header(f, "Content-Length")) {
        CFStringRef n = CFStringCreateWithFormat(NULL, NULL, CFSTR("%ld"), (long)CFDataGetLength(body));
        CFHTTPMessageSetHeaderFieldValue(f, CFSTR("Content-Length"), n);
        CFRelease(n);
    }
    if (body)
        CFRelease(body);
    if (!has_header(f, "Connection"))
        CFHTTPMessageSetHeaderFieldValue(f, CFSTR("Connection"), CFSTR("close"));
    if (!has_header(f, "User-Agent")) {
        CFStringRef agent = _CFNetworkCopyDefaultUserAgentString();
        CFHTTPMessageSetHeaderFieldValue(f, CFSTR("User-Agent"), agent);
        CFRelease(agent);
    }
    return f;
}

/* Sends the request's body: its data, or the body stream's bytes (chunked when the
   length isn't known). */
static bool
send_body(HTTPStream *h, Wire *w, CFHTTPMessageRef req, bool chunked)
{
    if (h->bodyStream) {
        if (CFReadStreamGetStatus(h->bodyStream) == kCFStreamStatusNotOpen && !CFReadStreamOpen(h->bodyStream))
            return false;
        UInt8 buf[16384];
        CFIndex n;
        while ((n = CFReadStreamRead(h->bodyStream, buf, sizeof buf)) > 0) {
            if (chunked) {
                char head[24];
                int hl = snprintf(head, sizeof head, "%lx\r\n", (long)n);
                if (!cfn_conn_write(&w->conn, head, (size_t)hl))
                    return false;
            }
            if (!cfn_conn_write(&w->conn, buf, (size_t)n) || (chunked && !cfn_conn_write(&w->conn, "\r\n", 2)))
                return false;
            pthread_mutex_lock(&h->m);
            h->bytesWritten += n;
            pthread_mutex_unlock(&h->m);
        }
        if (n < 0)
            return false;
        return !chunked || cfn_conn_write(&w->conn, "0\r\n\r\n", 5);
    }
    CFDataRef body = CFHTTPMessageCopyBody(req);
    bool ok = true;
    if (body && CFDataGetLength(body)) {
        ok = cfn_conn_write(&w->conn, CFDataGetBytePtr(body), (size_t)CFDataGetLength(body));
        if (ok) {
            pthread_mutex_lock(&h->m);
            h->bytesWritten += CFDataGetLength(body);
            pthread_mutex_unlock(&h->m);
        }
    }
    if (body)
        CFRelease(body);
    return ok;
}

/* Reads a response's head; NULL (and *err) when the connection doesn't give one. */
static CFHTTPMessageRef
read_head(Wire *w, CFStreamError *err)
{
    CFHTTPMessageRef m = CFHTTPMessageCreateEmpty(NULL, false);
    char line[8192];
    bool first = true;
    for (;;) {
        if (!wire_line(w, line, sizeof line)) {
            CFRelease(m);
            err->domain = 4; /* kCFStreamErrorDomainHTTP */
            err->error = first ? kCFStreamErrorHTTPConnectionLost : kCFStreamErrorHTTPParseFailure;
            if (first && errno && errno != ECONNRESET) {
                err->domain = kCFStreamErrorDomainPOSIX;
                err->error = errno;
            }
            return NULL;
        }
        if (first && !line[0])
            continue;
        first = false;
        size_t len = strlen(line);
        line[len] = '\r';
        line[len + 1] = '\n';
        CFHTTPMessageAppendBytes(m, (const UInt8 *)line, (CFIndex)len + 2);
        if (!len)
            break;
    }
    if (!CFHTTPMessageIsHeaderComplete(m) || !CFHTTPMessageGetResponseStatusCode(m)) {
        CFRelease(m);
        err->domain = 4;
        err->error = kCFStreamErrorHTTPParseFailure;
        return NULL;
    }
    return m;
}

/* Reads the body as framed, to the stream (deliver) or nowhere (a redirect's). */
static bool
read_body(HTTPStream *h, Wire *w, CFHTTPMessageRef response, bool head, bool deliver)
{
    CFIndex status = CFHTTPMessageGetResponseStatusCode(response);
    if (head || status == 204 || status == 304 || (status >= 100 && status < 200))
        return true;
    CFStringRef te = cfn_message_header(response, "Transfer-Encoding");
    CFStringRef cl = cfn_message_header(response, "Content-Length");
    if (te && CFStringFind(te, CFSTR("chunked"), kCFCompareCaseInsensitive).location != kCFNotFound) {
        char line[1024];
        for (;;) {
            if (!wire_line(w, line, sizeof line))
                return false;
            unsigned long long size = strtoull(line, NULL, 16);
            if (!size)
                break;
            while (size) {
                if (w->at == w->have && wire_fill(w) <= 0)
                    return false;
                size_t n = w->have - w->at < size ? w->have - w->at : (size_t)size;
                if (deliver)
                    hs_deliver(h, w->buf + w->at, (CFIndex)n);
                w->at += n;
                size -= n;
            }
            if (!wire_line(w, line, sizeof line)) /* the chunk's CRLF */
                return false;
        }
        while (wire_line(w, line, sizeof line) && line[0]) /* trailers */
            ;
        return true;
    }
    if (cl) {
        char *c = cfn_cstring(cl);
        long long left = c ? strtoll(c, NULL, 10) : 0;
        free(c);
        while (left > 0) {
            if (w->at == w->have && wire_fill(w) <= 0)
                return false;
            size_t n = (long long)(w->have - w->at) < left ? w->have - w->at : (size_t)left;
            if (deliver)
                hs_deliver(h, w->buf + w->at, (CFIndex)n);
            w->at += n;
            left -= (long long)n;
        }
        return true;
    }
    /* to the end of the connection */
    for (;;) {
        if (w->at < w->have) {
            if (deliver)
                hs_deliver(h, w->buf + w->at, (CFIndex)(w->have - w->at));
            w->at = w->have;
        }
        ssize_t n = wire_fill(w);
        if (n == 0)
            return true;
        if (n < 0)
            return false;
    }
}

static bool
closed(HTTPStream *h)
{
    pthread_mutex_lock(&h->m);
    bool c = h->closed;
    pthread_mutex_unlock(&h->m);
    return c;
}

static void
run_exchange(HTTPStream *h)
{
    CFHTTPMessageRef req = (CFHTTPMessageRef)CFRetain(h->request);
    CFURLRef url = CFHTTPMessageCopyRequestURL(req);
    pthread_mutex_lock(&h->m);
    CFTypeRef redirect = CFDictionaryGetValue(h->properties, kCFStreamPropertyHTTPShouldAutoredirect);
    bool autoredirect = redirect && CFGetTypeID(redirect) == CFBooleanGetTypeID() && CFBooleanGetValue(redirect);
    pthread_mutex_unlock(&h->m);
    for (int hop = 0;; hop++) {
        if (hop > MAX_REDIRECTS) {
            hs_fail(h, 4, kCFStreamErrorHTTPRedirectionLoop);
            break;
        }
        int port;
        bool tls;
        CFStringRef hostName = url ? url_host(url, &port, &tls) : NULL;
        if (!hostName) {
            hs_fail(h, 4, kCFStreamErrorHTTPBadURL);
            break;
        }
        char *host = cfn_cstring(hostName);
        CFRelease(hostName);
        int proxyPort = 0;
        CFStringRef proxy = proxy_for(h, tls, &proxyPort);
        char *proxyHost = proxy ? cfn_cstring(proxy) : NULL;
        if (proxy)
            CFRelease(proxy);
        Wire *w = calloc(1, sizeof *w);
        cfn_conn_init(&w->conn);
        CFStreamError err = {0, 0};
        bool ok = cfn_conn_connect(&w->conn, proxyHost ? proxyHost : host, proxyHost ? proxyPort : port, 75, &err);
        if (ok) {
            pthread_mutex_lock(&h->m);
            h->fd = w->conn.fd;
            if (h->closed)
                shutdown(w->conn.fd, SHUT_RDWR);
            pthread_mutex_unlock(&h->m);
        }
        if (ok && proxyHost && tls) { /* a tunnel through the proxy */
            char connect[1200];
            int n = snprintf(connect, sizeof connect, "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n", host, port, host, port);
            ok = cfn_conn_write(&w->conn, connect, (size_t)n);
            CFHTTPMessageRef reply = ok ? read_head(w, &err) : NULL;
            if (!reply || CFHTTPMessageGetResponseStatusCode(reply) / 100 != 2) {
                ok = false;
                if (reply) {
                    err.domain = 4;
                    err.error = kCFStreamErrorHTTPConnectionLost;
                }
            }
            if (reply)
                CFRelease(reply);
        }
        if (ok && tls) {
            char *peer;
            bool verify = ssl_verify(h, &peer, host);
            ok = cfn_conn_start_tls(&w->conn, peer, verify, &err);
            free(peer);
        }
        bool chunked = h->bodyStream && !has_header(req, "Content-Length");
        if (ok) {
            CFDataRef head = serialize_request(h, req, url, proxyHost && !tls, chunked);
            ok = cfn_conn_write(&w->conn, CFDataGetBytePtr(head), (size_t)CFDataGetLength(head)) &&
                 send_body(h, w, req, chunked);
            CFRelease(head);
            if (!ok) {
                err.domain = kCFStreamErrorDomainPOSIX;
                err.error = errno ? errno : EPIPE;
            }
        }
        free(proxyHost);
        free(host);
        CFHTTPMessageRef response = NULL;
        if (ok) {
            /* a 100 Continue (and other 1xx) comes before the response */
            while ((response = read_head(w, &err)) && CFHTTPMessageGetResponseStatusCode(response) < 200) {
                CFRelease(response);
                response = NULL;
            }
            ok = response != NULL;
        }
        if (!ok) {
            cfn_conn_close(&w->conn, true);
            free(w);
            if (!closed(h))
                hs_fail(h, err.domain, err.error);
            break;
        }
        _CFHTTPMessageSetResponseURL(response, url);
        cfn_message_set_bodyless(response);
        CFIndex status = CFHTTPMessageGetResponseStatusCode(response);
        CFStringRef method = CFHTTPMessageCopyRequestMethod(req);
        bool isHead = CFEqual(method, CFSTR("HEAD"));
        CFStringRef location = cfn_message_header(response, "Location");
        CFURLRef next = NULL;
        if (autoredirect && location && (status == 301 || status == 302 || status == 303 || status == 307 || status == 308))
        {
            CFURLRef relative = CFURLCreateWithString(NULL, location, url);
            next = relative ? CFURLCopyAbsoluteURL(relative) : NULL;
            if (relative)
                CFRelease(relative);
        }
        if (next) {
            read_body(h, w, response, isHead, false);
            cfn_conn_close(&w->conn, true);
            free(w);
            CFHTTPMessageRef nreq;
            CFStringRef version = CFHTTPMessageCopyVersion(req);
            if (status == 303 || ((status == 301 || status == 302) && CFEqual(method, CFSTR("POST")))) {
                nreq = CFHTTPMessageCreateRequest(NULL, isHead ? CFSTR("HEAD") : CFSTR("GET"), next, version);
                CFArrayRef names = cfn_message_copy_header_names(req);
                for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
                    CFStringRef n = CFArrayGetValueAtIndex(names, i);
                    if (CFStringCompare(n, CFSTR("Host"), kCFCompareCaseInsensitive) &&
                        CFStringCompare(n, CFSTR("Content-Length"), kCFCompareCaseInsensitive) &&
                        CFStringCompare(n, CFSTR("Content-Type"), kCFCompareCaseInsensitive)) {
                        CFStringRef v = CFHTTPMessageCopyHeaderFieldValue(req, n);
                        CFHTTPMessageSetHeaderFieldValue(nreq, n, v);
                        CFRelease(v);
                    }
                }
                CFRelease(names);
            } else {
                /* the same request, on the new URL */
                CFHTTPMessageRef moved = CFHTTPMessageCreateRequest(NULL, method, next, version);
                CFArrayRef names = cfn_message_copy_header_names(req);
                for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
                    CFStringRef n = CFArrayGetValueAtIndex(names, i);
                    if (CFStringCompare(n, CFSTR("Host"), kCFCompareCaseInsensitive)) {
                        CFStringRef v = CFHTTPMessageCopyHeaderFieldValue(req, n);
                        CFHTTPMessageSetHeaderFieldValue(moved, n, v);
                        CFRelease(v);
                    }
                }
                CFRelease(names);
                CFDataRef body = CFHTTPMessageCopyBody(req);
                CFHTTPMessageSetBody(moved, body);
                if (body)
                    CFRelease(body);
                nreq = moved;
            }
            CFRelease(version);
            CFRelease(method);
            CFRelease(response);
            CFRelease(req);
            CFRelease(url);
            req = nreq;
            url = next;
            continue;
        }
        CFRelease(method);
        /* the response: its head is the stream's, and its body the stream's bytes */
        CFStringRef te = cfn_message_header(response, "Transfer-Encoding");
        bool wasChunked = te && CFStringFind(te, CFSTR("chunked"), kCFCompareCaseInsensitive).location != kCFNotFound;
        CFHTTPMessageRef shown = response;
        if (wasChunked) {
            shown = CFHTTPMessageCreateCopy(NULL, response);
            CFHTTPMessageSetHeaderFieldValue(shown, CFSTR("Transfer-Encoding"), CFSTR("Identity"));
            cfn_message_set_bodyless(shown);
        }
        pthread_mutex_lock(&h->m);
        h->response = shown == response ? (CFHTTPMessageRef)CFRetain(response) : shown;
        h->finalURL = CFRetain(url);
        h->finalRequest = final_request(req, url);
        pthread_mutex_unlock(&h->m);
        bool full = read_body(h, w, response, isHead, true);
        CFRelease(response);
        int readErrno = errno;
        cfn_conn_close(&w->conn, true);
        free(w);
        pthread_mutex_lock(&h->m);
        h->fd = -1;
        pthread_mutex_unlock(&h->m);
        if (!full && !closed(h)) {
            hs_fail(h, readErrno && readErrno != ECONNRESET ? kCFStreamErrorDomainPOSIX : 4,
                    readErrno && readErrno != ECONNRESET ? readErrno : kCFStreamErrorHTTPConnectionLost);
        } else {
            pthread_mutex_lock(&h->m);
            h->done = true;
            pthread_cond_broadcast(&h->cv);
            hs_signal(h, CFDataGetLength(h->buffer) ? kCFStreamEventHasBytesAvailable : kCFStreamEventEndEncountered);
            pthread_mutex_unlock(&h->m);
        }
        break;
    }
    CFRelease(req);
    if (url)
        CFRelease(url);
}

/* --- the stream --- */

static void
hs_finalize(CFReadStreamRef s, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    h->stream = NULL;
    pthread_mutex_unlock(&h->m);
    hs_release(h);
}

static void
hs_start(HTTPStream *h)
{
    if (h->started)
        return;
    h->started = true;
    hs_retain(h);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      run_exchange(h);
      hs_release(h);
    });
}

static Boolean
hs_open(CFReadStreamRef s, CFErrorRef *error, Boolean *complete, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    hs_start(h);
    pthread_mutex_unlock(&h->m);
    *complete = true;
    return true;
}

static CFIndex
hs_read(CFReadStreamRef s, UInt8 *buf, CFIndex len, CFErrorRef *error, Boolean *atEOF, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    while (!CFDataGetLength(h->buffer) && !h->done && !h->closed)
        pthread_cond_wait(&h->cv, &h->m);
    CFIndex n = CFDataGetLength(h->buffer) < len ? CFDataGetLength(h->buffer) : len;
    if (n) {
        memcpy(buf, CFDataGetBytePtr(h->buffer), (size_t)n);
        CFDataDeleteBytes(h->buffer, CFRangeMake(0, n));
    } else if (h->error) {
        *error = (CFErrorRef)CFRetain(h->error);
        pthread_mutex_unlock(&h->m);
        return -1;
    }
    *atEOF = h->done && !h->error && !CFDataGetLength(h->buffer);
    /* more already here: the client hears of it again, as from Apple's */
    if (CFDataGetLength(h->buffer))
        hs_signal(h, kCFStreamEventHasBytesAvailable);
    pthread_mutex_unlock(&h->m);
    return n;
}

static Boolean
hs_can_read(CFReadStreamRef s, CFErrorRef *error, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    Boolean can = CFDataGetLength(h->buffer) > 0 || h->done;
    pthread_mutex_unlock(&h->m);
    return can;
}

static void
hs_close(CFReadStreamRef s, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    h->closed = true;
    if (h->fd >= 0)
        shutdown(h->fd, SHUT_RDWR);
    pthread_cond_broadcast(&h->cv);
    pthread_mutex_unlock(&h->m);
}

static CFTypeRef
hs_copy_property(CFReadStreamRef s, CFStringRef name, void *info)
{
    HTTPStream *h = info;
    CFTypeRef out = NULL;
    pthread_mutex_lock(&h->m);
    if (CFEqual(name, kCFStreamPropertyHTTPResponseHeader)) {
        out = h->response;
    } else if (CFEqual(name, kCFStreamPropertyHTTPFinalURL)) {
        out = h->finalURL;
        if (!out) {
            pthread_mutex_unlock(&h->m);
            return CFHTTPMessageCopyRequestURL(h->request);
        }
    } else if (CFEqual(name, kCFStreamPropertyHTTPFinalRequest)) {
        out = h->finalRequest;
        if (!out) {
            CFURLRef url = CFHTTPMessageCopyRequestURL(h->request);
            out = url ? final_request(h->request, url) : NULL;
            if (url)
                CFRelease(url);
            pthread_mutex_unlock(&h->m);
            return out;
        }
    } else if (CFEqual(name, kCFStreamPropertyHTTPRequestBytesWrittenCount)) {
        pthread_mutex_unlock(&h->m);
        return CFNumberCreate(NULL, kCFNumberSInt64Type, &h->bytesWritten);
    } else if (CFEqual(name, kCFStreamPropertyHTTPShouldAutoredirect)) {
        out = CFDictionaryGetValue(h->properties, name);
        if (!out)
            out = kCFBooleanFalse;
    } else {
        out = CFDictionaryGetValue(h->properties, name);
    }
    if (out)
        CFRetain(out);
    pthread_mutex_unlock(&h->m);
    return out;
}

static Boolean
hs_set_property(CFReadStreamRef s, CFStringRef name, CFTypeRef value, void *info)
{
    HTTPStream *h = info;
    pthread_mutex_lock(&h->m);
    if (value)
        CFDictionarySetValue(h->properties, name, value);
    else
        CFDictionaryRemoveValue(h->properties, name);
    pthread_mutex_unlock(&h->m);
    return true;
}

static const CFReadStreamCallBacks http_callbacks = {
    2, NULL, hs_finalize, NULL, hs_open, NULL, hs_read, NULL, hs_can_read, hs_close,
    hs_copy_property, hs_set_property, NULL, NULL, NULL};

static CFReadStreamRef
create_stream(CFAllocatorRef alloc, CFHTTPMessageRef request, CFReadStreamRef body)
{
    if (!request || !CFHTTPMessageIsRequest(request))
        return NULL;
    HTTPStream *h = calloc(1, sizeof *h);
    pthread_mutex_init(&h->m, NULL);
    pthread_cond_init(&h->cv, NULL);
    h->refs = 1;
    h->fd = -1;
    h->request = CFHTTPMessageCreateCopy(NULL, request);
    h->bodyStream = body ? (CFReadStreamRef)CFRetain(body) : NULL;
    h->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    h->buffer = CFDataCreateMutable(NULL, 0);
    h->stream = CFReadStreamCreate(alloc, &http_callbacks, h);
    if (!h->stream) {
        hs_release(h);
        return NULL;
    }
    return h->stream;
}

CFReadStreamRef
CFReadStreamCreateForHTTPRequest(CFAllocatorRef alloc, CFHTTPMessageRef request)
{
    return create_stream(alloc, request, NULL);
}

CFReadStreamRef
CFReadStreamCreateForStreamedHTTPRequest(CFAllocatorRef alloc, CFHTTPMessageRef requestHeaders,
                                         CFReadStreamRef requestBody)
{
    return create_stream(alloc, requestHeaders, requestBody);
}

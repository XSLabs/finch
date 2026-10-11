/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Socket streams: the read and write stream pair over one TCP connection that
 * CFStreamCreatePairWithSocketToHost (CoreFoundation, which calls
 * _CFSocketStreamCreatePair here, as on macOS) and NSStream's
 * +getStreamsToHostWithName:... make. Either stream's open starts the connection
 * (resolving the host, connecting and, when kCFStreamPropertySocketSecurityLevel or
 * kCFStreamPropertySSLSettings ask for it, the TLS handshake, which is OpenSSL's) on a
 * queue, and both report it open. Reads and writes are the socket's own, blocking; a
 * stream scheduled on a run loop is told when bytes arrive or room frees up by a
 * dispatch source on the descriptor.
 *
 * And the connection code the HTTP stream uses too (cfn_conn), and Apple's mapping
 * between CFStreamError and CFError.
 */
#include "CFNetworkInternal.h"
#include "../certificates/ca-bundle.h"
#include <CoreFoundation/CFStream.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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

typedef struct {
    CFIndex version;
    void *(*create)(CFWriteStreamRef, void *);
    void (*finalize)(CFWriteStreamRef, void *);
    CFStringRef (*copyDescription)(CFWriteStreamRef, void *);
    Boolean (*open)(CFWriteStreamRef, CFErrorRef *, Boolean *, void *);
    Boolean (*openCompleted)(CFWriteStreamRef, CFErrorRef *, void *);
    CFIndex (*write)(CFWriteStreamRef, const UInt8 *, CFIndex, CFErrorRef *, void *);
    Boolean (*canWrite)(CFWriteStreamRef, CFErrorRef *, void *);
    void (*close)(CFWriteStreamRef, void *);
    CFTypeRef (*copyProperty)(CFWriteStreamRef, CFStringRef, void *);
    Boolean (*setProperty)(CFWriteStreamRef, CFStringRef, CFTypeRef, void *);
    void (*requestEvents)(CFWriteStreamRef, CFOptionFlags, void *);
    void (*schedule)(CFWriteStreamRef, CFRunLoopRef, CFStringRef, void *);
    void (*unschedule)(CFWriteStreamRef, CFRunLoopRef, CFStringRef, void *);
} CFWriteStreamCallBacks;

extern CFReadStreamRef CFReadStreamCreate(CFAllocatorRef, const CFReadStreamCallBacks *, void *);
extern CFWriteStreamRef CFWriteStreamCreate(CFAllocatorRef, const CFWriteStreamCallBacks *, void *);
extern void CFReadStreamSignalEvent(CFReadStreamRef, CFStreamEventType, const void *);
extern void CFWriteStreamSignalEvent(CFWriteStreamRef, CFStreamEventType, const void *);

/* CoreFoundation loads only a CFNetwork that exports this (Finch's, not Apple's). */
__attribute__((visibility("default"))) const int FinchCFNetwork = 1;

char *
cfn_cstring(CFStringRef s)
{
    if (!s)
        return NULL;
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    char *out = malloc((size_t)size);
    if (!CFStringGetCString(s, out, size, kCFStringEncodingUTF8)) {
        free(out);
        return NULL;
    }
    return out;
}

/* --- errors --- */

CFErrorRef
_CFErrorCreateWithStreamError(CFAllocatorRef alloc, CFStreamError *streamError)
{
    CFStringRef domain;
    CFIndex code = streamError->error;
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
    switch (streamError->domain) {
    case kCFStreamErrorDomainPOSIX:
        domain = kCFErrorDomainPOSIX;
        break;
    case kCFStreamErrorDomainMacOSStatus:
    case 3: /* kCFStreamErrorDomainSSL: OSStatus codes */
        domain = kCFErrorDomainOSStatus;
        break;
    case 12: { /* kCFStreamErrorDomainNetDB: a host the resolver couldn't find */
        domain = kCFErrorDomainCFNetwork;
        code = kCFHostErrorUnknown;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &streamError->error);
        CFDictionarySetValue(info, kCFGetAddrInfoFailureKey, n);
        CFRelease(n);
        break;
    }
    case 4: /* kCFStreamErrorDomainHTTP */
        domain = kCFErrorDomainCFNetwork;
        code = streamError->error == kCFStreamErrorHTTPParseFailure      ? kCFErrorHTTPParseFailure
               : streamError->error == kCFStreamErrorHTTPRedirectionLoop ? kCFErrorHTTPRedirectionLoopDetected
               : streamError->error == kCFStreamErrorHTTPBadURL          ? kCFErrorHTTPBadURL
                                                                         : kCFErrorHTTPConnectionLost;
        break;
    default:
        domain = kCFErrorDomainCFNetwork;
        break;
    }
    CFNumberRef d = CFNumberCreate(NULL, kCFNumberCFIndexType, &streamError->domain);
    CFNumberRef e = CFNumberCreate(NULL, kCFNumberSInt32Type, &streamError->error);
    CFDictionarySetValue(info, CFSTR("_kCFStreamErrorDomainKey"), d);
    CFDictionarySetValue(info, CFSTR("_kCFStreamErrorCodeKey"), e);
    CFRelease(d);
    CFRelease(e);
    CFErrorRef error = CFErrorCreate(alloc, domain, code, info);
    CFRelease(info);
    return error;
}

CFStreamError
_CFStreamErrorFromCFError(CFErrorRef error)
{
    CFStreamError out = {kCFStreamErrorDomainCustom, (SInt32)CFErrorGetCode(error)};
    CFDictionaryRef info = CFErrorCopyUserInfo(error);
    CFNumberRef d = info ? CFDictionaryGetValue(info, CFSTR("_kCFStreamErrorDomainKey")) : NULL;
    CFNumberRef e = info ? CFDictionaryGetValue(info, CFSTR("_kCFStreamErrorCodeKey")) : NULL;
    if (d && e) {
        CFNumberGetValue(d, kCFNumberCFIndexType, &out.domain);
        CFNumberGetValue(e, kCFNumberSInt32Type, &out.error);
    } else if (CFEqual(CFErrorGetDomain(error), kCFErrorDomainPOSIX)) {
        out.domain = kCFStreamErrorDomainPOSIX;
    } else if (CFEqual(CFErrorGetDomain(error), kCFErrorDomainOSStatus)) {
        out.domain = kCFStreamErrorDomainMacOSStatus;
    }
    if (info)
        CFRelease(info);
    return out;
}

CFErrorRef
cfn_error(long domain, int code)
{
    CFStreamError e = {domain, code};
    return _CFErrorCreateWithStreamError(NULL, &e);
}

/* --- connections --- */

void
cfn_conn_init(cfn_conn *c)
{
    c->fd = -1;
    c->ssl = c->ctx = NULL;
    pthread_mutex_init(&c->lock, NULL);
}

bool
cfn_conn_connect(cfn_conn *c, const char *host, int port, double timeout, CFStreamError *err)
{
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof portStr, "%d", port);
    int gai = getaddrinfo(host, portStr, &hints, &res);
    if (gai != 0 || !res) {
        err->domain = 12; /* kCFStreamErrorDomainNetDB */
        err->error = gai ? gai : EAI_NONAME;
        return false;
    }
    int lastErrno = ECONNREFUSED;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0)
            continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        if (timeout > 0) {
            struct timeval tv = {(time_t)timeout, 0};
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        }
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) {
            c->fd = fd;
            break;
        }
        lastErrno = errno;
        close(fd);
    }
    freeaddrinfo(res);
    if (c->fd < 0) {
        err->domain = kCFStreamErrorDomainPOSIX;
        err->error = lastErrno;
        return false;
    }
    return true;
}

/* OpenSSL is built without sockets (no-sock), so TLS runs over a BIO of our own on the
   connected descriptor, as Foundation's. */
static int
fd_bio_write(BIO *b, const char *buf, int n)
{
    return (int)write((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
}

static int
fd_bio_read(BIO *b, char *buf, int n)
{
    return (int)read((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
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

bool
cfn_conn_start_tls(cfn_conn *c, const char *peer, bool verify, CFStreamError *err)
{
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    if (verify) {
        char caPath[PATH_MAX];
        const char *caFile = finch_ca_bundle((const void *)cfn_conn_start_tls, caPath);
        if (!caFile || SSL_CTX_load_verify_locations(ctx, caFile, NULL) != 1) {
            SSL_CTX_free(ctx);
            err->domain = 3;
            err->error = -9807; /* errSSLXCertChainInvalid */
            return false;
        }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    }
    SSL *ssl = SSL_new(ctx);
    if (peer) {
        SSL_set_tlsext_host_name(ssl, peer);
        if (verify)
            SSL_set1_host(ssl, peer);
    }
    BIO *bio = BIO_new(fd_bio_method());
    BIO_set_data(bio, (void *)(intptr_t)c->fd);
    BIO_set_init(bio, 1);
    SSL_set_bio(ssl, bio, bio);
    c->ctx = ctx;
    c->ssl = ssl;
    if (SSL_connect(ssl) != 1) {
        err->domain = 3; /* kCFStreamErrorDomainSSL */
        err->error = SSL_get_verify_result(ssl) != X509_V_OK ? -9807 /* errSSLXCertChainInvalid */
                                                             : -9806 /* errSSLClosedAbort */;
        return false;
    }
    return true;
}

ssize_t
cfn_conn_read(cfn_conn *c, void *buf, size_t n)
{
    if (!c->ssl)
        return read(c->fd, buf, n);
    /* wait for bytes outside the lock, so a writer isn't held up by a reader */
    if (!SSL_pending(c->ssl)) {
        struct pollfd p = {c->fd, POLLIN, 0};
        while (poll(&p, 1, -1) < 0 && errno == EINTR)
            ;
    }
    pthread_mutex_lock(&c->lock);
    int r = SSL_read(c->ssl, buf, (int)n);
    int e = r <= 0 ? SSL_get_error(c->ssl, r) : SSL_ERROR_NONE;
    pthread_mutex_unlock(&c->lock);
    if (r > 0)
        return r;
    if (e == SSL_ERROR_ZERO_RETURN || (e == SSL_ERROR_SYSCALL && errno == 0))
        return 0;
    if (e == SSL_ERROR_SYSCALL && errno)
        return -1;
    errno = ECONNRESET;
    return -1;
}

bool
cfn_conn_write(cfn_conn *c, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t w;
        if (c->ssl) {
            pthread_mutex_lock(&c->lock);
            w = SSL_write(c->ssl, p, (int)n);
            pthread_mutex_unlock(&c->lock);
        } else {
            w = write(c->fd, p, n);
        }
        if (w <= 0) {
            if (w < 0 && errno == EINTR)
                continue;
            return false;
        }
        p += w;
        n -= (size_t)w;
    }
    return true;
}

bool
cfn_conn_readable(cfn_conn *c)
{
    if (c->ssl && SSL_pending(c->ssl))
        return true;
    struct pollfd p = {c->fd, POLLIN, 0};
    return poll(&p, 1, 0) > 0;
}

void
cfn_conn_close(cfn_conn *c, bool close_fd)
{
    if (c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
        c->ssl = NULL;
    }
    if (c->ctx) {
        SSL_CTX_free(c->ctx);
        c->ctx = NULL;
    }
    if (c->fd >= 0 && close_fd)
        close(c->fd);
    c->fd = -1;
}

/* --- the stream pair --- */

enum { PAIR_IDLE, PAIR_CONNECTING, PAIR_OPEN, PAIR_FAILED };

typedef struct {
    _Atomic int refs;
    dispatch_queue_t queue; /* signals, sources and state changes */
    char *host;
    int port;
    cfn_conn conn;
    int state;
    CFStreamError error;
    bool closeNative, readOpened, writeOpened, readClosed, writeClosed, readEOF;
    CFReadStreamRef rs; /* not retained: each stream holds the pair */
    CFWriteStreamRef ws;
    bool readScheduled, writeScheduled;
    dispatch_source_t readSource, writeSource;
    bool readArmed, writeArmed; /* the source is resumed, waiting */
    CFMutableDictionaryRef properties;
} Pair;

static Pair *
pair_retain(Pair *p)
{
    p->refs++;
    return p;
}

static void
pair_release(Pair *p)
{
    if (--p->refs)
        return;
    cfn_conn_close(&p->conn, p->closeNative);
    free(p->host);
    if (p->properties)
        CFRelease(p->properties);
    dispatch_release(p->queue);
    free(p);
}

/* On the queue: a source for each scheduled, open stream; armed until it fires, and
   re-armed by the next read or write. */
static void
pair_update_sources(Pair *p)
{
    if (p->state != PAIR_OPEN)
        return;
    if (p->rs && p->readScheduled && !p->readSource && !p->readEOF) {
        p->readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)p->conn.fd, 0, p->queue);
        dispatch_source_set_event_handler(p->readSource, ^{
          dispatch_suspend(p->readSource);
          p->readArmed = false;
          if (p->rs)
              CFReadStreamSignalEvent(p->rs, kCFStreamEventHasBytesAvailable, NULL);
        });
        p->readArmed = true;
        dispatch_resume(p->readSource);
    }
    if (p->ws && p->writeScheduled && !p->writeSource) {
        p->writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)p->conn.fd, 0, p->queue);
        dispatch_source_set_event_handler(p->writeSource, ^{
          dispatch_suspend(p->writeSource);
          p->writeArmed = false;
          if (p->ws)
              CFWriteStreamSignalEvent(p->ws, kCFStreamEventCanAcceptBytes, NULL);
        });
        p->writeArmed = true;
        dispatch_resume(p->writeSource);
    }
}

static void
cancel_source(dispatch_source_t *s, bool *armed)
{
    if (!*s)
        return;
    dispatch_source_cancel(*s);
    if (!*armed)
        dispatch_resume(*s); /* a suspended source must be resumed to be released */
    dispatch_release(*s);
    *s = NULL;
    *armed = false;
}

static bool
security_requested(Pair *p, bool *verify, char **peer)
{
    *verify = true;
    *peer = p->host ? strdup(p->host) : NULL;
    CFTypeRef level = CFDictionaryGetValue(p->properties, kCFStreamPropertySocketSecurityLevel);
    CFDictionaryRef settings = CFDictionaryGetValue(p->properties, kCFStreamPropertySSLSettings);
    bool tls = level && !CFEqual(level, kCFStreamSocketSecurityLevelNone);
    if (settings && CFGetTypeID(settings) == CFDictionaryGetTypeID()) {
        tls = true;
        CFTypeRef l = CFDictionaryGetValue(settings, kCFStreamSSLLevel);
        if (l && CFEqual(l, kCFStreamSocketSecurityLevelNone))
            tls = false;
        CFTypeRef v = CFDictionaryGetValue(settings, kCFStreamSSLValidatesCertificateChain);
        if (v == kCFBooleanFalse)
            *verify = false;
        CFTypeRef name = CFDictionaryGetValue(settings, kCFStreamSSLPeerName);
        if (name == kCFNull) {
            free(*peer);
            *peer = NULL;
        } else if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
            free(*peer);
            *peer = cfn_cstring(name);
        }
    }
    return tls;
}

static void
pair_signal_open(Pair *p)
{
    CFErrorRef error = p->state == PAIR_FAILED ? _CFErrorCreateWithStreamError(NULL, &p->error) : NULL;
    if (p->rs && p->readOpened && !p->readClosed)
        CFReadStreamSignalEvent(p->rs, error ? kCFStreamEventErrorOccurred : kCFStreamEventOpenCompleted, error);
    if (p->ws && p->writeOpened && !p->writeClosed)
        CFWriteStreamSignalEvent(p->ws, error ? kCFStreamEventErrorOccurred : kCFStreamEventOpenCompleted, error);
    if (error)
        CFRelease(error);
    pair_update_sources(p);
}

/* Starts connecting (once, for whichever stream opens first). */
static void
pair_open(Pair *p)
{
    if (p->state != PAIR_IDLE)
        return;
    if (p->conn.fd >= 0) { /* made with a native socket: open already */
        p->state = PAIR_OPEN;
        bool verify;
        char *peer;
        if (security_requested(p, &verify, &peer) &&
            !cfn_conn_start_tls(&p->conn, peer, verify, &p->error))
            p->state = PAIR_FAILED;
        free(peer);
        return;
    }
    p->state = PAIR_CONNECTING;
    pair_retain(p);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      __block cfn_conn c;
      cfn_conn_init(&c);
      __block CFStreamError err = {0, 0};
      __block bool verify, tls;
      __block char *peer;
      dispatch_sync(p->queue, ^{ tls = security_requested(p, &verify, &peer); });
      bool ok = cfn_conn_connect(&c, p->host, p->port, 75, &err) && (!tls || cfn_conn_start_tls(&c, peer, verify, &err));
      free(peer);
      dispatch_async(p->queue, ^{
        if (ok) {
            p->conn.fd = c.fd;
            p->conn.ssl = c.ssl;
            p->conn.ctx = c.ctx;
            p->state = PAIR_OPEN;
        } else {
            cfn_conn_close(&c, true);
            p->error = err;
            p->state = PAIR_FAILED;
        }
        pair_signal_open(p);
        pair_release(p);
      });
    });
}

/* read stream */

static void
rs_finalize(CFReadStreamRef s, void *info)
{
    Pair *p = info;
    dispatch_sync(p->queue, ^{
      p->rs = NULL;
      cancel_source(&p->readSource, &p->readArmed);
    });
    pair_release(p);
}

static Boolean
rs_open(CFReadStreamRef s, CFErrorRef *error, Boolean *complete, void *info)
{
    Pair *p = info;
    __block int state;
    dispatch_sync(p->queue, ^{
      p->readOpened = true;
      pair_open(p);
      state = p->state;
    });
    *complete = state != PAIR_CONNECTING;
    if (state == PAIR_FAILED) {
        *error = _CFErrorCreateWithStreamError(NULL, &p->error);
        return false;
    }
    return true;
}

static Boolean
rs_open_completed(CFReadStreamRef s, CFErrorRef *error, void *info)
{
    Pair *p = info;
    __block int state;
    dispatch_sync(p->queue, ^{ state = p->state; });
    if (state == PAIR_FAILED)
        *error = _CFErrorCreateWithStreamError(NULL, &p->error);
    return state == PAIR_OPEN || state == PAIR_FAILED;
}

static CFIndex
rs_read(CFReadStreamRef s, UInt8 *buf, CFIndex len, CFErrorRef *error, Boolean *atEOF, void *info)
{
    Pair *p = info;
    ssize_t n = cfn_conn_read(&p->conn, buf, (size_t)len);
    if (n < 0) {
        *error = cfn_error(kCFStreamErrorDomainPOSIX, errno);
        return -1;
    }
    *atEOF = n == 0;
    dispatch_sync(p->queue, ^{
      if (n == 0) {
          p->readEOF = true;
          cancel_source(&p->readSource, &p->readArmed);
      } else if (p->readSource && !p->readArmed) {
          p->readArmed = true;
          dispatch_resume(p->readSource);
      }
    });
    return n;
}

static Boolean
rs_can_read(CFReadStreamRef s, CFErrorRef *error, void *info)
{
    return cfn_conn_readable(&((Pair *)info)->conn);
}

static void
rs_close(CFReadStreamRef s, void *info)
{
    Pair *p = info;
    dispatch_sync(p->queue, ^{
      p->readClosed = true;
      cancel_source(&p->readSource, &p->readArmed);
      if (p->conn.fd >= 0)
          shutdown(p->conn.fd, p->writeClosed ? SHUT_RDWR : SHUT_RD);
    });
}

static CFTypeRef
pair_copy_property(Pair *p, CFStringRef name)
{
    __block CFTypeRef out = NULL;
    dispatch_sync(p->queue, ^{
      if (CFEqual(name, kCFStreamPropertySocketNativeHandle)) {
          if (p->conn.fd >= 0)
              out = CFDataCreate(NULL, (const UInt8 *)&p->conn.fd, sizeof p->conn.fd);
      } else if (CFEqual(name, kCFStreamPropertySocketRemoteHostName)) {
          if (p->host)
              out = CFStringCreateWithCString(NULL, p->host, kCFStringEncodingUTF8);
      } else if (CFEqual(name, kCFStreamPropertySocketRemotePortNumber)) {
          if (p->host)
              out = CFNumberCreate(NULL, kCFNumberIntType, &p->port);
      } else if (CFEqual(name, kCFStreamPropertyShouldCloseNativeSocket)) {
          out = CFRetain(p->closeNative ? kCFBooleanTrue : kCFBooleanFalse);
      } else {
          out = CFDictionaryGetValue(p->properties, name);
          if (out)
              CFRetain(out);
      }
    });
    return out;
}

static Boolean
pair_set_property(Pair *p, CFStringRef name, CFTypeRef value)
{
    __block Boolean ok = true;
    dispatch_sync(p->queue, ^{
      if (CFEqual(name, kCFStreamPropertyShouldCloseNativeSocket)) {
          p->closeNative = value && CFBooleanGetValue(value);
          return;
      }
      bool security = CFEqual(name, kCFStreamPropertySSLSettings) || CFEqual(name, kCFStreamPropertySocketSecurityLevel);
      if (value)
          CFDictionarySetValue(p->properties, name, value);
      else
          CFDictionaryRemoveValue(p->properties, name);
      /* TLS on a connection that's already open (STARTTLS) */
      if (security && p->state == PAIR_OPEN && !p->conn.ssl) {
          bool verify;
          char *peer;
          if (security_requested(p, &verify, &peer) && !cfn_conn_start_tls(&p->conn, peer, verify, &p->error)) {
              p->state = PAIR_FAILED;
              ok = false;
          }
          free(peer);
      }
    });
    return ok;
}

static CFTypeRef
rs_copy_property(CFReadStreamRef s, CFStringRef name, void *info)
{
    return pair_copy_property(info, name);
}

static Boolean
rs_set_property(CFReadStreamRef s, CFStringRef name, CFTypeRef value, void *info)
{
    return pair_set_property(info, name, value);
}

static void
rs_schedule(CFReadStreamRef s, CFRunLoopRef loop, CFStringRef mode, void *info)
{
    Pair *p = info;
    dispatch_async(p->queue, ^{
      p->readScheduled = true;
      pair_update_sources(p);
    });
}

static void
rs_unschedule(CFReadStreamRef s, CFRunLoopRef loop, CFStringRef mode, void *info)
{
}

static const CFReadStreamCallBacks read_callbacks = {
    2, NULL, rs_finalize, NULL, rs_open, rs_open_completed, rs_read, NULL, rs_can_read, rs_close,
    rs_copy_property, rs_set_property, NULL, rs_schedule, rs_unschedule};

/* write stream */

static void
ws_finalize(CFWriteStreamRef s, void *info)
{
    Pair *p = info;
    dispatch_sync(p->queue, ^{
      p->ws = NULL;
      cancel_source(&p->writeSource, &p->writeArmed);
    });
    pair_release(p);
}

static Boolean
ws_open(CFWriteStreamRef s, CFErrorRef *error, Boolean *complete, void *info)
{
    Pair *p = info;
    __block int state;
    dispatch_sync(p->queue, ^{
      p->writeOpened = true;
      pair_open(p);
      state = p->state;
    });
    *complete = state != PAIR_CONNECTING;
    if (state == PAIR_FAILED) {
        *error = _CFErrorCreateWithStreamError(NULL, &p->error);
        return false;
    }
    return true;
}

static Boolean
ws_open_completed(CFWriteStreamRef s, CFErrorRef *error, void *info)
{
    return rs_open_completed(NULL, error, info);
}

static CFIndex
ws_write(CFWriteStreamRef s, const UInt8 *buf, CFIndex len, CFErrorRef *error, void *info)
{
    Pair *p = info;
    ssize_t n;
    if (p->conn.ssl) {
        n = cfn_conn_write(&p->conn, buf, (size_t)len) ? len : -1;
    } else {
        do
            n = write(p->conn.fd, buf, (size_t)len);
        while (n < 0 && errno == EINTR);
    }
    if (n < 0) {
        *error = cfn_error(kCFStreamErrorDomainPOSIX, errno ? errno : EPIPE);
        return -1;
    }
    dispatch_sync(p->queue, ^{
      if (p->writeSource && !p->writeArmed) {
          p->writeArmed = true;
          dispatch_resume(p->writeSource);
      }
    });
    return n;
}

static Boolean
ws_can_write(CFWriteStreamRef s, CFErrorRef *error, void *info)
{
    Pair *p = info;
    struct pollfd fd = {p->conn.fd, POLLOUT, 0};
    return poll(&fd, 1, 0) > 0;
}

static void
ws_close(CFWriteStreamRef s, void *info)
{
    Pair *p = info;
    dispatch_sync(p->queue, ^{
      p->writeClosed = true;
      cancel_source(&p->writeSource, &p->writeArmed);
      if (p->conn.fd >= 0)
          shutdown(p->conn.fd, p->readClosed ? SHUT_RDWR : SHUT_WR);
    });
}

static CFTypeRef
ws_copy_property(CFWriteStreamRef s, CFStringRef name, void *info)
{
    return pair_copy_property(info, name);
}

static Boolean
ws_set_property(CFWriteStreamRef s, CFStringRef name, CFTypeRef value, void *info)
{
    return pair_set_property(info, name, value);
}

static void
ws_schedule(CFWriteStreamRef s, CFRunLoopRef loop, CFStringRef mode, void *info)
{
    Pair *p = info;
    dispatch_async(p->queue, ^{
      p->writeScheduled = true;
      pair_update_sources(p);
    });
}

static void
ws_unschedule(CFWriteStreamRef s, CFRunLoopRef loop, CFStringRef mode, void *info)
{
}

static const CFWriteStreamCallBacks write_callbacks = {
    2, NULL, ws_finalize, NULL, ws_open, ws_open_completed, ws_write, ws_can_write, ws_close,
    ws_copy_property, ws_set_property, NULL, ws_schedule, ws_unschedule};

/* CoreFoundation's CFStreamCreatePairWithSocket... functions come here: to a host and
   port, or over a socket already connected (sock, which the streams close only when
   kCFStreamPropertyShouldCloseNativeSocket is set), or to a signature's address. */
void
_CFSocketStreamCreatePair(CFAllocatorRef alloc, CFStringRef host, UInt32 port, CFSocketNativeHandle sock,
                          const CFSocketSignature *signature, CFReadStreamRef *readStream,
                          CFWriteStreamRef *writeStream)
{
    if (readStream)
        *readStream = NULL;
    if (writeStream)
        *writeStream = NULL;
    Pair *p = calloc(1, sizeof *p);
    p->refs = 0;
    p->queue = dispatch_queue_create("com.apple.CFNetwork.socketstream", NULL);
    p->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    cfn_conn_init(&p->conn);
    if (host) {
        p->host = cfn_cstring(host);
        p->port = (int)port;
        p->closeNative = true;
    } else if (signature) {
        /* an address: connected in the open, as a numeric host */
        const struct sockaddr *sa = (const struct sockaddr *)CFDataGetBytePtr(signature->address);
        char name[NI_MAXHOST], serv[NI_MAXSERV];
        if (getnameinfo(sa, sa->sa_len, name, sizeof name, serv, sizeof serv, NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
            p->host = strdup(name);
            p->port = atoi(serv);
        }
        p->closeNative = true;
    } else {
        p->conn.fd = sock;
    }
    if (readStream) {
        *readStream = CFReadStreamCreate(alloc, &read_callbacks, pair_retain(p));
        p->rs = *readStream;
    }
    if (writeStream) {
        *writeStream = CFWriteStreamCreate(alloc, &write_callbacks, pair_retain(p));
        p->ws = *writeStream;
    }
    if (!p->refs) {
        p->refs = 1;
        pair_release(p);
    }
}

void
CFStreamCreatePairWithSocketToCFHost(CFAllocatorRef alloc, CFHostRef host, SInt32 port, CFReadStreamRef *readStream,
                                     CFWriteStreamRef *writeStream)
{
    CFArrayRef names = CFHostGetNames(host, NULL);
    CFArrayRef addresses = CFHostGetAddressing(host, NULL);
    if (names && CFArrayGetCount(names)) {
        _CFSocketStreamCreatePair(alloc, CFArrayGetValueAtIndex(names, 0), (UInt32)port, 0, NULL, readStream, writeStream);
    } else if (addresses && CFArrayGetCount(addresses)) {
        CFDataRef a = CFArrayGetValueAtIndex(addresses, 0);
        CFMutableDataRef copy = CFDataCreateMutableCopy(NULL, 0, a);
        struct sockaddr *sa = (struct sockaddr *)CFDataGetMutableBytePtr(copy);
        if (sa->sa_family == AF_INET)
            ((struct sockaddr_in *)sa)->sin_port = htons((uint16_t)port);
        else if (sa->sa_family == AF_INET6)
            ((struct sockaddr_in6 *)sa)->sin6_port = htons((uint16_t)port);
        CFSocketSignature sig = {sa->sa_family, SOCK_STREAM, IPPROTO_TCP, copy};
        _CFSocketStreamCreatePair(alloc, NULL, 0, 0, &sig, readStream, writeStream);
        CFRelease(copy);
    } else {
        if (readStream)
            *readStream = NULL;
        if (writeStream)
            *writeStream = NULL;
    }
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Bonjour: CFNetService (registering and resolving a service), CFNetServiceBrowser
 * (finding services and domains) and CFNetServiceMonitor (watching a service's TXT
 * record), over the system's DNS service discovery (dns_sd), as Apple's.
 *
 * Each operation is a DNSServiceRef. On an object scheduled on run loops, its socket is
 * a CFSocket there and results come back through the client's callback; on one that
 * isn't, registering and resolving block until done (or the timeout), as Apple's do.
 */
#include "CFNetworkInternal.h"
#include <dns_sd.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

/* --- an operation on the run loops --- */

typedef struct {
    DNSServiceRef ref;
    CFSocketRef socket;
    CFRunLoopSourceRef source;
} Op;

typedef struct {
    CFMutableArrayRef loops, modes;
} Schedules;

static void
schedules_init(Schedules *s)
{
    s->loops = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    s->modes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
}

static void
schedules_free(Schedules *s)
{
    CFRelease(s->loops);
    CFRelease(s->modes);
}

static void
op_socket_callback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    Op *op = info;
    if (op->ref)
        DNSServiceProcessResult(op->ref);
}

static void
op_schedule_one(Op *op, CFRunLoopRef loop, CFStringRef mode)
{
    if (op->source)
        CFRunLoopAddSource(loop, op->source, mode);
}

/* Puts a started operation on the object's run loops. */
static void
op_attach(Op *op, Schedules *s)
{
    CFSocketContext ctx = {0, op, NULL, NULL, NULL};
    op->socket = CFSocketCreateWithNative(NULL, DNSServiceRefSockFD(op->ref), kCFSocketReadCallBack, op_socket_callback, &ctx);
    CFSocketSetSocketFlags(op->socket, CFSocketGetSocketFlags(op->socket) & ~(CFOptionFlags)kCFSocketCloseOnInvalidate);
    op->source = CFSocketCreateRunLoopSource(NULL, op->socket, 0);
    for (CFIndex i = 0; i < CFArrayGetCount(s->loops); i++)
        op_schedule_one(op, (CFRunLoopRef)CFArrayGetValueAtIndex(s->loops, i), CFArrayGetValueAtIndex(s->modes, i));
}

static void
op_stop(Op *op)
{
    if (op->source) {
        CFRunLoopSourceInvalidate(op->source);
        CFRelease(op->source);
        op->source = NULL;
    }
    if (op->socket) {
        CFSocketInvalidate(op->socket);
        CFRelease(op->socket);
        op->socket = NULL;
    }
    if (op->ref) {
        DNSServiceRefDeallocate(op->ref);
        op->ref = NULL;
    }
}

/* Processes results until *done or the timeout (seconds; <= 0 for none). */
static bool
op_wait(Op *op, volatile bool *done, double timeout)
{
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout;
    while (!*done && op->ref) {
        int ms = -1;
        if (timeout > 0) {
            double left = end - CFAbsoluteTimeGetCurrent();
            if (left <= 0)
                return false;
            ms = (int)(left * 1000) + 1;
        }
        struct pollfd p = {DNSServiceRefSockFD(op->ref), POLLIN, 0};
        int r = poll(&p, 1, ms);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return false;
        if (DNSServiceProcessResult(op->ref) != kDNSServiceErr_NoError)
            return false;
    }
    return *done;
}

static void
schedules_add(Schedules *s, CFRunLoopRef loop, CFStringRef mode, Op **ops, int n)
{
    CFArrayAppendValue(s->loops, loop);
    CFArrayAppendValue(s->modes, mode);
    for (int i = 0; i < n; i++)
        op_schedule_one(ops[i], loop, mode);
}

static void
schedules_remove(Schedules *s, CFRunLoopRef loop, CFStringRef mode, Op **ops, int n)
{
    for (CFIndex i = 0; i < CFArrayGetCount(s->loops); i++) {
        if (CFArrayGetValueAtIndex(s->loops, i) == loop && CFEqual(CFArrayGetValueAtIndex(s->modes, i), mode)) {
            CFArrayRemoveValueAtIndex(s->loops, i);
            CFArrayRemoveValueAtIndex(s->modes, i);
            break;
        }
    }
    for (int i = 0; i < n; i++)
        if (ops[i]->source)
            CFRunLoopRemoveSource(loop, ops[i]->source, mode);
}

static CFStreamError
ns_error(DNSServiceErrorType e)
{
    CFStreamError err = {kCFStreamErrorDomainNetServices, kCFNetServicesErrorUnknown};
    if (e == kDNSServiceErr_NameConflict)
        err.error = kCFNetServicesErrorCollision;
    else if (e == kDNSServiceErr_BadParam)
        err.error = kCFNetServicesErrorBadArgument;
    else if (e == kDNSServiceErr_NoSuchName || e == kDNSServiceErr_NoSuchRecord)
        err.error = kCFNetServicesErrorNotFound;
    else
        err.error = e;
    return err;
}

static char *
cstr_or(CFStringRef s, const char *fallback)
{
    char *c = s && CFStringGetLength(s) ? cfn_cstring(s) : NULL;
    return c ? c : strdup(fallback);
}

/* --- CFNetService --- */

struct __CFNetService {
    CFRuntimeBase base;
    CFStringRef domain, type, name, targetHost;
    SInt32 port;
    CFDataRef txt;
    CFMutableArrayRef addresses;
    CFNetServiceClientCallBack callback;
    CFNetServiceClientContext context;
    Schedules schedules;
    Op op, addrOp;
    volatile bool done;
    CFStreamError error;
    bool registering;
};

static CFTypeID service_type;

static void service_cancel_ops(struct __CFNetService *s);

static void
service_finalize(CFTypeRef cf)
{
    struct __CFNetService *s = (struct __CFNetService *)cf;
    service_cancel_ops(s);
    CFTypeRef owned[] = {s->domain, s->type, s->name, s->targetHost, s->txt, s->addresses};
    for (size_t i = 0; i < sizeof owned / sizeof *owned; i++)
        if (owned[i])
            CFRelease(owned[i]);
    if (s->context.release && s->context.info)
        s->context.release(s->context.info);
    schedules_free(&s->schedules);
}

static CFStringRef
service_description(CFTypeRef cf)
{
    struct __CFNetService *s = (struct __CFNetService *)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CFNetService %p>{domain = %@, type = %@, name = %@, port = %d}"),
                                    cf, s->domain, s->type, s->name, (int)s->port);
}

static Boolean
service_equal(CFTypeRef a, CFTypeRef b)
{
    const struct __CFNetService *x = a, *y = b;
    return CFEqual(x->domain, y->domain) && CFEqual(x->type, y->type) && CFEqual(x->name, y->name);
}

static CFHashCode
service_hash(CFTypeRef cf)
{
    return CFHash(((const struct __CFNetService *)cf)->name);
}

static const CFRuntimeClass service_class = {0, "CFNetService", NULL, NULL, service_finalize, service_equal,
                                             service_hash, NULL, service_description, NULL, NULL, 0};

CFTypeID
CFNetServiceGetTypeID(void)
{
    CFN_REGISTER(service_type, service_class);
}

CFNetServiceRef
CFNetServiceCreate(CFAllocatorRef alloc, CFStringRef domain, CFStringRef serviceType, CFStringRef name, SInt32 port)
{
    struct __CFNetService *s = cfn_create(CFNetServiceGetTypeID(), sizeof(struct __CFNetService));
    s->domain = CFStringCreateCopy(NULL, domain ? domain : CFSTR(""));
    s->type = CFStringCreateCopy(NULL, serviceType ? serviceType : CFSTR(""));
    s->name = CFStringCreateCopy(NULL, name ? name : CFSTR(""));
    s->port = port;
    schedules_init(&s->schedules);
    return s;
}

CFNetServiceRef
CFNetServiceCreateCopy(CFAllocatorRef alloc, CFNetServiceRef service)
{
    struct __CFNetService *s = (struct __CFNetService *)CFNetServiceCreate(alloc, service->domain, service->type,
                                                                           service->name, service->port);
    if (service->txt)
        s->txt = CFRetain(service->txt);
    if (service->targetHost)
        s->targetHost = CFRetain(service->targetHost);
    if (service->addresses)
        s->addresses = CFArrayCreateMutableCopy(NULL, 0, service->addresses);
    return s;
}

CFStringRef CFNetServiceGetDomain(CFNetServiceRef s) { return s->domain; }
CFStringRef CFNetServiceGetType(CFNetServiceRef s) { return s->type; }
CFStringRef CFNetServiceGetName(CFNetServiceRef s) { return s->name; }
CFStringRef CFNetServiceGetTargetHost(CFNetServiceRef s) { return s->targetHost; }
SInt32 CFNetServiceGetPortNumber(CFNetServiceRef s) { return s->port; }
CFDataRef CFNetServiceGetTXTData(CFNetServiceRef s) { return s->txt; }
CFArrayRef CFNetServiceGetAddressing(CFNetServiceRef s) { return s->addresses && CFArrayGetCount(s->addresses) ? s->addresses : NULL; }

/* The old TXT record as a string. */
CFStringRef
CFNetServiceGetProtocolSpecificInformation(CFNetServiceRef s)
{
    if (!s->txt || CFDataGetLength(s->txt) < 1)
        return NULL;
    const UInt8 *b = CFDataGetBytePtr(s->txt);
    CFStringRef str = CFStringCreateWithBytes(NULL, b + 1, b[0] < CFDataGetLength(s->txt) ? b[0] : CFDataGetLength(s->txt) - 1,
                                              kCFStringEncodingUTF8, false);
    return str ? (CFStringRef)CFAutorelease(str) : NULL;
}

void
CFNetServiceSetProtocolSpecificInformation(CFNetServiceRef theService, CFStringRef theInfo)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    char *c = theInfo ? cfn_cstring(theInfo) : NULL;
    UInt8 len = c ? (UInt8)(strlen(c) > 255 ? 255 : strlen(c)) : 0;
    CFDataAppendBytes(d, &len, 1);
    if (c)
        CFDataAppendBytes(d, (const UInt8 *)c, len);
    free(c);
    CFNetServiceSetTXTData(theService, d);
    CFRelease(d);
    (void)s;
}

Boolean
CFNetServiceSetTXTData(CFNetServiceRef theService, CFDataRef txtRecord)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    if (s->txt)
        CFRelease(s->txt);
    s->txt = txtRecord ? CFDataCreateCopy(NULL, txtRecord) : NULL;
    if (s->registering && s->op.ref)
        return DNSServiceUpdateRecord(s->op.ref, NULL, 0, s->txt ? (uint16_t)CFDataGetLength(s->txt) : 0,
                                      s->txt ? CFDataGetBytePtr(s->txt) : NULL, 0) == kDNSServiceErr_NoError;
    return true;
}

static void
service_notify(struct __CFNetService *s, CFStreamError *error)
{
    if (s->callback)
        s->callback((CFNetServiceRef)s, error, s->context.info);
}

static void
service_cancel_ops(struct __CFNetService *s)
{
    op_stop(&s->op);
    op_stop(&s->addrOp);
    s->registering = false;
}

static void DNSSD_API
register_reply(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType e, const char *name, const char *type,
               const char *domain, void *ctx)
{
    struct __CFNetService *s = ctx;
    if (e) {
        s->error = ns_error(e);
        s->done = true;
        service_cancel_ops(s);
        service_notify(s, &s->error);
        return;
    }
    /* the name it got (renamed on a conflict) */
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (n) {
        CFRelease(s->name);
        s->name = n;
    }
    CFStringRef d = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    if (d) {
        CFRelease(s->domain);
        s->domain = d;
    }
    s->done = true;
}

Boolean
CFNetServiceRegisterWithOptions(CFNetServiceRef theService, CFOptionFlags options, CFStreamError *error)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    CFStreamError local;
    if (!error)
        error = &local;
    error->domain = 0;
    error->error = 0;
    if (s->op.ref) {
        error->domain = kCFStreamErrorDomainNetServices;
        error->error = kCFNetServicesErrorInProgress;
        return false;
    }
    char *name = cstr_or(s->name, ""), *type = cstr_or(s->type, ""), *domain = cstr_or(s->domain, "");
    DNSServiceErrorType e = DNSServiceRegister(&s->op.ref, (options & kCFNetServiceFlagNoAutoRename) ? kDNSServiceFlagsNoAutoRename : 0,
                                               0, name, type, domain[0] ? domain : NULL, NULL, htons((uint16_t)s->port),
                                               s->txt ? (uint16_t)CFDataGetLength(s->txt) : 0,
                                               s->txt ? CFDataGetBytePtr(s->txt) : NULL, register_reply, s);
    free(name);
    free(type);
    free(domain);
    if (e) {
        s->op.ref = NULL;
        *error = ns_error(e);
        return false;
    }
    s->registering = true;
    s->done = false;
    if (s->callback && CFArrayGetCount(s->schedules.loops)) {
        op_attach(&s->op, &s->schedules);
        return true;
    }
    /* not scheduled: blocks until registered (and stays registered until cancelled) */
    s->error.domain = 0;
    if (!op_wait(&s->op, &s->done, 0) || s->error.domain) {
        *error = s->error.domain ? s->error : ns_error(kDNSServiceErr_Unknown);
        service_cancel_ops(s);
        return false;
    }
    return true;
}

Boolean
CFNetServiceRegister(CFNetServiceRef theService, CFStreamError *error)
{
    return CFNetServiceRegisterWithOptions(theService, 0, error);
}

static void DNSSD_API
addr_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType e, const char *hostname,
           const struct sockaddr *address, uint32_t ttl, void *ctx)
{
    struct __CFNetService *s = ctx;
    if (e) {
        if (!s->addresses || !CFArrayGetCount(s->addresses)) {
            s->error = ns_error(e);
            s->done = true;
            op_stop(&s->addrOp);
            service_notify(s, &s->error);
        }
        return;
    }
    if (flags & kDNSServiceFlagsAdd) {
        CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
        CFDataAppendBytes(d, (const UInt8 *)address, address->sa_len);
        struct sockaddr *sa = (struct sockaddr *)CFDataGetMutableBytePtr(d);
        if (sa->sa_family == AF_INET)
            ((struct sockaddr_in *)sa)->sin_port = htons((uint16_t)s->port);
        else if (sa->sa_family == AF_INET6)
            ((struct sockaddr_in6 *)sa)->sin6_port = htons((uint16_t)s->port);
        if (!s->addresses)
            s->addresses = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!CFArrayContainsValue(s->addresses, CFRangeMake(0, CFArrayGetCount(s->addresses)), d))
            CFArrayAppendValue(s->addresses, d);
        CFRelease(d);
    }
    if (!(flags & kDNSServiceFlagsMoreComing)) {
        bool first = !s->done;
        s->done = true;
        if (first || s->op.socket)
            service_notify(s, NULL);
    }
}

static void DNSSD_API
resolve_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType e,
              const char *fullname, const char *hosttarget, uint16_t port, uint16_t txtLen, const unsigned char *txt,
              void *ctx)
{
    struct __CFNetService *s = ctx;
    if (e) {
        s->error = ns_error(e);
        s->done = true;
        service_cancel_ops(s);
        service_notify(s, &s->error);
        return;
    }
    if (s->targetHost)
        CFRelease(s->targetHost);
    s->targetHost = CFStringCreateWithCString(NULL, hosttarget, kCFStringEncodingUTF8);
    s->port = ntohs(port);
    if (s->txt)
        CFRelease(s->txt);
    s->txt = CFDataCreate(NULL, txt, txtLen);
    /* then its addresses */
    op_stop(&s->addrOp);
    if (DNSServiceGetAddrInfo(&s->addrOp.ref, 0, interfaceIndex, 0, hosttarget, addr_reply, s) == kDNSServiceErr_NoError) {
        if (s->op.socket)
            op_attach(&s->addrOp, &s->schedules);
    } else {
        s->addrOp.ref = NULL;
    }
}

Boolean
CFNetServiceResolveWithTimeout(CFNetServiceRef theService, CFTimeInterval timeout, CFStreamError *error)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    CFStreamError local;
    if (!error)
        error = &local;
    error->domain = 0;
    error->error = 0;
    if (s->op.ref) {
        error->domain = kCFStreamErrorDomainNetServices;
        error->error = kCFNetServicesErrorInProgress;
        return false;
    }
    char *name = cstr_or(s->name, ""), *type = cstr_or(s->type, ""), *domain = cstr_or(s->domain, "local.");
    DNSServiceErrorType e = DNSServiceResolve(&s->op.ref, 0, 0, name, type, domain, resolve_reply, s);
    free(name);
    free(type);
    free(domain);
    if (e) {
        s->op.ref = NULL;
        *error = ns_error(e);
        return false;
    }
    s->done = false;
    s->error.domain = 0;
    if (s->callback && CFArrayGetCount(s->schedules.loops)) {
        op_attach(&s->op, &s->schedules);
        return true;
    }
    /* not scheduled: blocks until the addresses come (or the timeout) */
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout;
    while (!s->done && s->op.ref) {
        if (timeout > 0 && CFAbsoluteTimeGetCurrent() >= end)
            break;
        Op *active = s->addrOp.ref ? &s->addrOp : &s->op;
        struct pollfd p = {DNSServiceRefSockFD(active->ref), POLLIN, 0};
        if (poll(&p, 1, 250) > 0 && DNSServiceProcessResult(active->ref) != kDNSServiceErr_NoError)
            break;
    }
    bool ok = s->done && !s->error.domain;
    service_cancel_ops(s);
    if (!ok) {
        error->domain = kCFStreamErrorDomainNetServices;
        error->error = s->error.domain ? s->error.error : kCFNetServicesErrorTimeout;
    }
    return ok;
}

Boolean
CFNetServiceResolve(CFNetServiceRef theService, CFStreamError *error)
{
    return CFNetServiceResolveWithTimeout(theService, 0, error);
}

void
CFNetServiceCancel(CFNetServiceRef theService)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    bool active = s->op.ref != NULL;
    service_cancel_ops(s);
    if (active && s->callback) {
        CFStreamError e = {kCFStreamErrorDomainNetServices, kCFNetServicesErrorCancel};
        service_notify(s, &e);
    }
}

Boolean
CFNetServiceSetClient(CFNetServiceRef theService, CFNetServiceClientCallBack clientCB, CFNetServiceClientContext *clientContext)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    if (s->context.release && s->context.info)
        s->context.release(s->context.info);
    memset(&s->context, 0, sizeof s->context);
    s->callback = clientCB;
    if (clientCB && clientContext) {
        s->context = *clientContext;
        if (s->context.retain && s->context.info)
            s->context.info = (void *)s->context.retain(s->context.info);
    }
    return true;
}

void
CFNetServiceScheduleWithRunLoop(CFNetServiceRef theService, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    Op *ops[] = {&s->op, &s->addrOp};
    schedules_add(&s->schedules, runLoop, runLoopMode, ops, 2);
}

void
CFNetServiceUnscheduleFromRunLoop(CFNetServiceRef theService, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetService *s = (struct __CFNetService *)theService;
    Op *ops[] = {&s->op, &s->addrOp};
    schedules_remove(&s->schedules, runLoop, runLoopMode, ops, 2);
}

/* --- TXT records --- */

CFDictionaryRef
CFNetServiceCreateDictionaryWithTXTData(CFAllocatorRef alloc, CFDataRef txtRecord)
{
    if (!txtRecord)
        return NULL;
    uint16_t len = (uint16_t)CFDataGetLength(txtRecord);
    const void *bytes = CFDataGetBytePtr(txtRecord);
    uint16_t n = TXTRecordGetCount(len, bytes);
    if (len && !n)
        return NULL;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(alloc, n, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    for (uint16_t i = 0; i < n; i++) {
        char key[256];
        uint8_t vlen = 0;
        const void *value = NULL;
        if (TXTRecordGetItemAtIndex(len, bytes, i, sizeof key, key, &vlen, &value) != kDNSServiceErr_NoError)
            continue;
        CFStringRef k = CFStringCreateWithCString(alloc, key, kCFStringEncodingUTF8);
        if (!k)
            continue;
        CFTypeRef v = value ? (CFTypeRef)CFDataCreate(alloc, value, vlen) : (CFTypeRef)CFRetain(kCFNull);
        if (!CFDictionaryContainsKey(d, k))
            CFDictionarySetValue(d, k, v);
        CFRelease(k);
        CFRelease(v);
    }
    return d;
}

static void
txt_add(const void *key, const void *value, void *ctx)
{
    TXTRecordRef *txt = ctx;
    char *k = CFGetTypeID(key) == CFStringGetTypeID() ? cfn_cstring(key) : NULL;
    if (!k)
        return;
    if (CFGetTypeID(value) == CFDataGetTypeID()) {
        TXTRecordSetValue(txt, k, (uint8_t)CFDataGetLength(value), CFDataGetBytePtr(value));
    } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char *v = cfn_cstring(value);
        TXTRecordSetValue(txt, k, (uint8_t)strlen(v), v);
        free(v);
    } else {
        TXTRecordSetValue(txt, k, 0, NULL);
    }
    free(k);
}

CFDataRef
CFNetServiceCreateTXTDataWithDictionary(CFAllocatorRef alloc, CFDictionaryRef keyValuePairs)
{
    if (!keyValuePairs)
        return NULL;
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    CFDictionaryApplyFunction(keyValuePairs, txt_add, &txt);
    CFDataRef d = CFDataCreate(alloc, TXTRecordGetBytesPtr(&txt), TXTRecordGetLength(&txt));
    TXTRecordDeallocate(&txt);
    return d;
}

/* --- CFNetServiceBrowser --- */

struct __CFNetServiceBrowser {
    CFRuntimeBase base;
    CFNetServiceBrowserClientCallBack callback;
    CFNetServiceClientContext context;
    Schedules schedules;
    Op op;
    bool invalid;
    CFStringRef domain;
};

static CFTypeID browser_type;

static void
browser_finalize(CFTypeRef cf)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)cf;
    op_stop(&b->op);
    if (b->domain)
        CFRelease(b->domain);
    if (b->context.release && b->context.info)
        b->context.release(b->context.info);
    schedules_free(&b->schedules);
}

static const CFRuntimeClass browser_class = {0, "CFNetServiceBrowser", NULL, NULL, browser_finalize, NULL, NULL,
                                             NULL, NULL, NULL, NULL, 0};

CFTypeID
CFNetServiceBrowserGetTypeID(void)
{
    CFN_REGISTER(browser_type, browser_class);
}

CFNetServiceBrowserRef
CFNetServiceBrowserCreate(CFAllocatorRef alloc, CFNetServiceBrowserClientCallBack clientCB, CFNetServiceClientContext *clientContext)
{
    struct __CFNetServiceBrowser *b = cfn_create(CFNetServiceBrowserGetTypeID(), sizeof(struct __CFNetServiceBrowser));
    b->callback = clientCB;
    if (clientContext) {
        b->context = *clientContext;
        if (b->context.retain && b->context.info)
            b->context.info = (void *)b->context.retain(b->context.info);
    }
    schedules_init(&b->schedules);
    return b;
}

void
CFNetServiceBrowserInvalidate(CFNetServiceBrowserRef browser)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    op_stop(&b->op);
    b->invalid = true;
    b->callback = NULL;
}

static void DNSSD_API
domain_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType e,
             const char *replyDomain, void *ctx)
{
    struct __CFNetServiceBrowser *b = ctx;
    if (!b->callback)
        return;
    if (e) {
        CFStreamError err = ns_error(e);
        b->callback((CFNetServiceBrowserRef)b, 0, NULL, &err, b->context.info);
        return;
    }
    CFOptionFlags f = kCFNetServiceFlagIsDomain;
    if (flags & kDNSServiceFlagsMoreComing)
        f |= kCFNetServiceFlagMoreComing;
    if (flags & kDNSServiceFlagsDefault)
        f |= kCFNetServiceFlagIsDefault;
    if (!(flags & kDNSServiceFlagsAdd))
        f |= kCFNetServiceFlagRemove;
    CFStringRef d = CFStringCreateWithCString(NULL, replyDomain, kCFStringEncodingUTF8);
    b->callback((CFNetServiceBrowserRef)b, f, d, NULL, b->context.info);
    CFRelease(d);
}

static void DNSSD_API
browse_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType e,
             const char *serviceName, const char *regtype, const char *replyDomain, void *ctx)
{
    struct __CFNetServiceBrowser *b = ctx;
    if (!b->callback)
        return;
    if (e) {
        CFStreamError err = ns_error(e);
        b->callback((CFNetServiceBrowserRef)b, 0, NULL, &err, b->context.info);
        return;
    }
    CFOptionFlags f = 0;
    if (flags & kDNSServiceFlagsMoreComing)
        f |= kCFNetServiceFlagMoreComing;
    if (!(flags & kDNSServiceFlagsAdd))
        f |= kCFNetServiceFlagRemove;
    CFStringRef d = CFStringCreateWithCString(NULL, replyDomain, kCFStringEncodingUTF8);
    CFStringRef t = CFStringCreateWithCString(NULL, regtype, kCFStringEncodingUTF8);
    CFStringRef n = CFStringCreateWithCString(NULL, serviceName, kCFStringEncodingUTF8);
    CFNetServiceRef s = CFNetServiceCreate(NULL, d, t, n, -1);
    b->callback((CFNetServiceBrowserRef)b, f, s, NULL, b->context.info);
    if (s)
        CFRelease(s);
    CFRelease(d);
    CFRelease(t);
    CFRelease(n);
}

static Boolean
browser_start(struct __CFNetServiceBrowser *b, DNSServiceErrorType e, CFStreamError *error)
{
    if (e) {
        b->op.ref = NULL;
        if (error)
            *error = ns_error(e);
        return false;
    }
    op_attach(&b->op, &b->schedules);
    if (!CFArrayGetCount(b->schedules.loops)) {
        /* not scheduled: blocks, calling back, until stopped (from the callback) */
        volatile bool never = false;
        op_wait(&b->op, &never, 0);
    }
    if (error)
        error->domain = 0, error->error = 0;
    return true;
}

Boolean
CFNetServiceBrowserSearchForDomains(CFNetServiceBrowserRef browser, Boolean registrationDomains, CFStreamError *error)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    if (b->invalid || b->op.ref) {
        if (error)
            error->domain = kCFStreamErrorDomainNetServices,
            error->error = b->invalid ? kCFNetServicesErrorInvalid : kCFNetServicesErrorInProgress;
        return false;
    }
    DNSServiceErrorType e = DNSServiceEnumerateDomains(&b->op.ref,
                                                       registrationDomains ? kDNSServiceFlagsRegistrationDomains
                                                                           : kDNSServiceFlagsBrowseDomains,
                                                       0, domain_reply, b);
    return browser_start(b, e, error);
}

Boolean
CFNetServiceBrowserSearchForServices(CFNetServiceBrowserRef browser, CFStringRef domain, CFStringRef serviceType,
                                     CFStreamError *error)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    if (b->invalid || b->op.ref) {
        if (error)
            error->domain = kCFStreamErrorDomainNetServices,
            error->error = b->invalid ? kCFNetServicesErrorInvalid : kCFNetServicesErrorInProgress;
        return false;
    }
    char *type = cstr_or(serviceType, ""), *dom = cstr_or(domain, "");
    DNSServiceErrorType e = DNSServiceBrowse(&b->op.ref, 0, 0, type, dom[0] ? dom : NULL, browse_reply, b);
    free(type);
    free(dom);
    return browser_start(b, e, error);
}

void
CFNetServiceBrowserStopSearch(CFNetServiceBrowserRef browser, CFStreamError *error)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    bool active = b->op.ref != NULL;
    op_stop(&b->op);
    if (active && b->callback) {
        CFStreamError e = error && error->domain ? *error : (CFStreamError){kCFStreamErrorDomainNetServices, kCFNetServicesErrorCancel};
        b->callback(browser, 0, NULL, &e, b->context.info);
    }
}

void
CFNetServiceBrowserScheduleWithRunLoop(CFNetServiceBrowserRef browser, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    Op *ops[] = {&b->op};
    schedules_add(&b->schedules, runLoop, runLoopMode, ops, 1);
}

void
CFNetServiceBrowserUnscheduleFromRunLoop(CFNetServiceBrowserRef browser, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetServiceBrowser *b = (struct __CFNetServiceBrowser *)browser;
    Op *ops[] = {&b->op};
    schedules_remove(&b->schedules, runLoop, runLoopMode, ops, 1);
}

/* --- CFNetServiceMonitor: a service's TXT record as it changes --- */

struct __CFNetServiceMonitor {
    CFRuntimeBase base;
    CFNetServiceRef service;
    CFNetServiceMonitorClientCallBack callback;
    CFNetServiceClientContext context;
    Schedules schedules;
    Op op;
    bool invalid;
};

static CFTypeID monitor_type;

static void
monitor_finalize(CFTypeRef cf)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)cf;
    op_stop(&m->op);
    if (m->service)
        CFRelease(m->service);
    if (m->context.release && m->context.info)
        m->context.release(m->context.info);
    schedules_free(&m->schedules);
}

static const CFRuntimeClass monitor_class = {0, "CFNetServiceMonitor", NULL, NULL, monitor_finalize, NULL, NULL,
                                             NULL, NULL, NULL, NULL, 0};

CFTypeID
CFNetServiceMonitorGetTypeID(void)
{
    CFN_REGISTER(monitor_type, monitor_class);
}

CFNetServiceMonitorRef
CFNetServiceMonitorCreate(CFAllocatorRef alloc, CFNetServiceRef theService, CFNetServiceMonitorClientCallBack clientCB,
                          CFNetServiceClientContext *clientContext)
{
    struct __CFNetServiceMonitor *m = cfn_create(CFNetServiceMonitorGetTypeID(), sizeof(struct __CFNetServiceMonitor));
    m->service = (CFNetServiceRef)CFRetain(theService);
    m->callback = clientCB;
    if (clientContext) {
        m->context = *clientContext;
        if (m->context.retain && m->context.info)
            m->context.info = (void *)m->context.retain(m->context.info);
    }
    schedules_init(&m->schedules);
    return m;
}

void
CFNetServiceMonitorInvalidate(CFNetServiceMonitorRef monitor)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)monitor;
    op_stop(&m->op);
    m->invalid = true;
    m->callback = NULL;
}

static void DNSSD_API
query_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType e, const char *fullname,
            uint16_t rrtype, uint16_t rrclass, uint16_t rdlen, const void *rdata, uint32_t ttl, void *ctx)
{
    struct __CFNetServiceMonitor *m = ctx;
    if (!m->callback)
        return;
    if (e) {
        CFStreamError err = ns_error(e);
        m->callback((CFNetServiceMonitorRef)m, m->service, kCFNetServiceMonitorTXT, NULL, &err, m->context.info);
        return;
    }
    if (!(flags & kDNSServiceFlagsAdd))
        return;
    CFDataRef d = CFDataCreate(NULL, rdata, rdlen);
    m->callback((CFNetServiceMonitorRef)m, m->service, kCFNetServiceMonitorTXT, d, NULL, m->context.info);
    CFRelease(d);
}

Boolean
CFNetServiceMonitorStart(CFNetServiceMonitorRef monitor, CFNetServiceMonitorType recordType, CFStreamError *error)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)monitor;
    if (m->invalid || m->op.ref || recordType != kCFNetServiceMonitorTXT) {
        if (error)
            error->domain = kCFStreamErrorDomainNetServices,
            error->error = m->invalid ? kCFNetServicesErrorInvalid
                           : m->op.ref ? kCFNetServicesErrorInProgress
                                       : kCFNetServicesErrorBadArgument;
        return false;
    }
    char *name = cstr_or(CFNetServiceGetName(m->service), ""), *type = cstr_or(CFNetServiceGetType(m->service), ""),
         *domain = cstr_or(CFNetServiceGetDomain(m->service), "local.");
    char full[kDNSServiceMaxDomainName];
    DNSServiceConstructFullName(full, name, type, domain);
    free(name);
    free(type);
    free(domain);
    DNSServiceErrorType e = DNSServiceQueryRecord(&m->op.ref, kDNSServiceFlagsLongLivedQuery, 0, full,
                                                  kDNSServiceType_TXT, kDNSServiceClass_IN, query_reply, m);
    if (e) {
        m->op.ref = NULL;
        if (error)
            *error = ns_error(e);
        return false;
    }
    op_attach(&m->op, &m->schedules);
    if (error)
        error->domain = 0, error->error = 0;
    return true;
}

void
CFNetServiceMonitorStop(CFNetServiceMonitorRef monitor, CFStreamError *error)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)monitor;
    op_stop(&m->op);
}

void
CFNetServiceMonitorScheduleWithRunLoop(CFNetServiceMonitorRef monitor, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)monitor;
    Op *ops[] = {&m->op};
    schedules_add(&m->schedules, runLoop, runLoopMode, ops, 1);
}

void
CFNetServiceMonitorUnscheduleFromRunLoop(CFNetServiceMonitorRef monitor, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFNetServiceMonitor *m = (struct __CFNetServiceMonitor *)monitor;
    Op *ops[] = {&m->op};
    schedules_remove(&m->schedules, runLoop, runLoopMode, ops, 1);
}

/* --- streams to a service --- */

extern void _CFSocketStreamCreatePair(CFAllocatorRef, CFStringRef, UInt32, CFSocketNativeHandle, const CFSocketSignature *,
                                      CFReadStreamRef *, CFWriteStreamRef *);

void
CFStreamCreatePairWithSocketToNetService(CFAllocatorRef alloc, CFNetServiceRef service, CFReadStreamRef *readStream,
                                         CFWriteStreamRef *writeStream)
{
    struct __CFNetService *s = (struct __CFNetService *)service;
    if (!s->targetHost || s->port <= 0) {
        /* resolved when the streams are made, as Apple's resolve at open */
        CFNetServiceRef copy = CFNetServiceCreateCopy(alloc, service);
        CFNetServiceResolveWithTimeout(copy, 5, NULL);
        if (CFNetServiceGetTargetHost(copy))
            _CFSocketStreamCreatePair(alloc, CFNetServiceGetTargetHost(copy), (UInt32)CFNetServiceGetPortNumber(copy), 0,
                                      NULL, readStream, writeStream);
        else
            _CFSocketStreamCreatePair(alloc, s->name, 0, 0, NULL, readStream, writeStream);
        CFRelease(copy);
        return;
    }
    _CFSocketStreamCreatePair(alloc, s->targetHost, (UInt32)s->port, 0, NULL, readStream, writeStream);
}

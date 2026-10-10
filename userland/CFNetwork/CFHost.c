/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFHost: a host's addresses, names and reachability, looked up with the system's
 * resolver (getaddrinfo, getnameinfo) and SystemConfiguration's reachability. A lookup
 * blocks unless the host has a client and is scheduled on a run loop: then it runs on
 * a thread of its own and the client is called back on the run loop when it's done.
 * A failed lookup reports the resolver's error in kCFStreamErrorDomainNetDB, as Apple's.
 */
#include "CFNetworkInternal.h"
#include <SystemConfiguration/SCNetworkReachability.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

struct __CFHost {
    CFRuntimeBase base;
    pthread_mutex_t m;
    CFMutableArrayRef names, addresses;
    CFDataRef reachability;
    /* the client, and where it's called back */
    CFHostClientCallBack callback;
    CFHostClientContext context;
    CFMutableArrayRef loops, modes; /* in pairs */
    CFRunLoopSourceRef source;
    /* a lookup on its own thread, and its result for the callback */
    bool resolving, cancelled;
    unsigned generation;
    CFHostInfoType doneType;
    CFStreamError doneError;
};

static CFTypeID host_type;

static void
host_finalize(CFTypeRef cf)
{
    struct __CFHost *h = (struct __CFHost *)cf;
    CFTypeRef owned[] = {h->names, h->addresses, h->reachability, h->loops, h->modes};
    for (size_t i = 0; i < sizeof owned / sizeof *owned; i++)
        if (owned[i])
            CFRelease(owned[i]);
    if (h->source) {
        CFRunLoopSourceInvalidate(h->source);
        CFRelease(h->source);
    }
    if (h->context.release && h->context.info)
        h->context.release(h->context.info);
    pthread_mutex_destroy(&h->m);
}

static CFStringRef
host_description(CFTypeRef cf)
{
    struct __CFHost *h = (struct __CFHost *)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CFHost %p>{names = %@; addresses = %@}"), cf, h->names,
                                    h->addresses);
}

static const CFRuntimeClass host_class = {0, "CFHost", NULL, NULL, host_finalize, NULL, NULL, NULL, host_description,
                                          NULL, NULL, 0};

CFTypeID
CFHostGetTypeID(void)
{
    CFN_REGISTER(host_type, host_class);
}

static struct __CFHost *
host_new(void)
{
    struct __CFHost *h = cfn_create(CFHostGetTypeID(), sizeof(struct __CFHost));
    pthread_mutex_init(&h->m, NULL);
    h->loops = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    h->modes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    return h;
}

CFHostRef
CFHostCreateWithName(CFAllocatorRef allocator, CFStringRef hostname)
{
    struct __CFHost *h = host_new();
    h->names = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(h->names, hostname);
    return h;
}

CFHostRef
CFHostCreateWithAddress(CFAllocatorRef allocator, CFDataRef addr)
{
    struct __CFHost *h = host_new();
    h->addresses = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(h->addresses, addr);
    return h;
}

CFHostRef
CFHostCreateCopy(CFAllocatorRef alloc, CFHostRef host)
{
    struct __CFHost *h = host_new();
    pthread_mutex_lock(&((struct __CFHost *)host)->m);
    if (host->names)
        h->names = CFArrayCreateMutableCopy(NULL, 0, host->names);
    if (host->addresses)
        h->addresses = CFArrayCreateMutableCopy(NULL, 0, host->addresses);
    if (host->reachability)
        h->reachability = CFRetain(host->reachability);
    pthread_mutex_unlock(&((struct __CFHost *)host)->m);
    return h;
}

static CFArrayRef
info_copy(CFHostRef host, CFMutableArrayRef *field, Boolean *hasBeenResolved)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    CFArrayRef out = *field && CFArrayGetCount(*field) ? *field : NULL;
    pthread_mutex_unlock(&h->m);
    if (hasBeenResolved)
        *hasBeenResolved = out != NULL;
    return out;
}

CFArrayRef
CFHostGetAddressing(CFHostRef host, Boolean *hasBeenResolved)
{
    return info_copy(host, &((struct __CFHost *)host)->addresses, hasBeenResolved);
}

CFArrayRef
CFHostGetNames(CFHostRef host, Boolean *hasBeenResolved)
{
    return info_copy(host, &((struct __CFHost *)host)->names, hasBeenResolved);
}

CFDataRef
CFHostGetReachability(CFHostRef host, Boolean *hasBeenResolved)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    CFDataRef out = h->reachability;
    pthread_mutex_unlock(&h->m);
    if (hasBeenResolved)
        *hasBeenResolved = out != NULL;
    return out;
}

/* --- looking up --- */

static bool
lookup_addresses(struct __CFHost *h, CFStreamError *err)
{
    pthread_mutex_lock(&h->m);
    char *name = h->names && CFArrayGetCount(h->names) ? cfn_cstring(CFArrayGetValueAtIndex(h->names, 0)) : NULL;
    pthread_mutex_unlock(&h->m);
    if (!name) {
        err->domain = 12;
        err->error = EAI_NONAME;
        return false;
    }
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM; /* one entry per address */
    int gai = getaddrinfo(name, NULL, &hints, &res);
    free(name);
    if (gai) {
        err->domain = 12; /* kCFStreamErrorDomainNetDB */
        err->error = gai;
        return false;
    }
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        CFDataRef d = CFDataCreate(NULL, (const UInt8 *)a->ai_addr, a->ai_addrlen);
        CFArrayAppendValue(list, d);
        CFRelease(d);
    }
    freeaddrinfo(res);
    pthread_mutex_lock(&h->m);
    if (h->addresses)
        CFRelease(h->addresses);
    h->addresses = list;
    pthread_mutex_unlock(&h->m);
    return true;
}

static bool
lookup_names(struct __CFHost *h, CFStreamError *err)
{
    pthread_mutex_lock(&h->m);
    CFDataRef addr = h->addresses && CFArrayGetCount(h->addresses) ? CFRetain(CFArrayGetValueAtIndex(h->addresses, 0)) : NULL;
    pthread_mutex_unlock(&h->m);
    if (!addr) {
        /* a host made with a name: its name, as resolved */
        if (!lookup_addresses(h, err))
            return false;
        pthread_mutex_lock(&h->m);
        addr = CFRetain(CFArrayGetValueAtIndex(h->addresses, 0));
        pthread_mutex_unlock(&h->m);
    }
    char name[NI_MAXHOST];
    const struct sockaddr *sa = (const struct sockaddr *)CFDataGetBytePtr(addr);
    int gai = getnameinfo(sa, (socklen_t)CFDataGetLength(addr), name, sizeof name, NULL, 0, NI_NAMEREQD);
    CFRelease(addr);
    if (gai) {
        err->domain = 12;
        err->error = gai;
        return false;
    }
    CFStringRef s = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    pthread_mutex_lock(&h->m);
    if (h->names)
        CFRelease(h->names);
    h->names = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(h->names, s);
    pthread_mutex_unlock(&h->m);
    CFRelease(s);
    return true;
}

static bool
lookup_reachability(struct __CFHost *h, CFStreamError *err)
{
    pthread_mutex_lock(&h->m);
    char *name = h->names && CFArrayGetCount(h->names) ? cfn_cstring(CFArrayGetValueAtIndex(h->names, 0)) : NULL;
    CFDataRef addr = !name && h->addresses && CFArrayGetCount(h->addresses) ? CFRetain(CFArrayGetValueAtIndex(h->addresses, 0)) : NULL;
    pthread_mutex_unlock(&h->m);
    SCNetworkReachabilityRef r = name ? SCNetworkReachabilityCreateWithName(NULL, name)
                                 : addr ? SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)CFDataGetBytePtr(addr))
                                        : NULL;
    free(name);
    if (addr)
        CFRelease(addr);
    SCNetworkReachabilityFlags flags = 0;
    if (!r || !SCNetworkReachabilityGetFlags(r, &flags)) {
        if (r)
            CFRelease(r);
        err->domain = 12;
        err->error = EAI_FAIL;
        return false;
    }
    CFRelease(r);
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)&flags, sizeof flags);
    pthread_mutex_lock(&h->m);
    if (h->reachability)
        CFRelease(h->reachability);
    h->reachability = d;
    pthread_mutex_unlock(&h->m);
    return true;
}

static bool
lookup(struct __CFHost *h, CFHostInfoType info, CFStreamError *err)
{
    err->domain = 0;
    err->error = 0;
    switch (info) {
    case kCFHostAddresses:
        return lookup_addresses(h, err);
    case kCFHostNames:
        return lookup_names(h, err);
    case kCFHostReachability:
        return lookup_reachability(h, err);
    default:
        err->domain = kCFStreamErrorDomainPOSIX;
        err->error = EINVAL;
        return false;
    }
}

static void
host_perform(void *info)
{
    struct __CFHost *h = info;
    pthread_mutex_lock(&h->m);
    CFHostClientCallBack cb = h->callback;
    void *ctx = h->context.info;
    CFHostInfoType type = h->doneType;
    CFStreamError err = h->doneError;
    pthread_mutex_unlock(&h->m);
    if (cb)
        cb((CFHostRef)h, type, err.domain ? &err : NULL, ctx);
}

Boolean
CFHostStartInfoResolution(CFHostRef host, CFHostInfoType info, CFStreamError *error)
{
    struct __CFHost *h = (struct __CFHost *)host;
    CFStreamError local;
    if (!error)
        error = &local;
    pthread_mutex_lock(&h->m);
    bool async = h->callback && CFArrayGetCount(h->loops);
    if (async && h->resolving) {
        pthread_mutex_unlock(&h->m);
        error->domain = kCFStreamErrorDomainPOSIX;
        error->error = EBUSY;
        return false;
    }
    if (async) {
        h->resolving = true;
        h->cancelled = false;
        unsigned gen = ++h->generation;
        pthread_mutex_unlock(&h->m);
        CFRetain(h);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
          CFStreamError err;
          lookup(h, info, &err);
          pthread_mutex_lock(&h->m);
          if (!h->cancelled && gen == h->generation) {
              h->resolving = false;
              h->doneType = info;
              h->doneError = err;
              CFRunLoopSourceSignal(h->source);
              for (CFIndex i = 0; i < CFArrayGetCount(h->loops); i++)
                  CFRunLoopWakeUp((CFRunLoopRef)CFArrayGetValueAtIndex(h->loops, i));
          }
          pthread_mutex_unlock(&h->m);
          CFRelease(h);
        });
        error->domain = 0;
        error->error = 0;
        return true;
    }
    pthread_mutex_unlock(&h->m);
    return lookup(h, info, error);
}

void
CFHostCancelInfoResolution(CFHostRef host, CFHostInfoType info)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    h->cancelled = true;
    h->resolving = false;
    pthread_mutex_unlock(&h->m);
}

Boolean
CFHostSetClient(CFHostRef host, CFHostClientCallBack clientCB, CFHostClientContext *clientContext)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    if (h->context.release && h->context.info)
        h->context.release(h->context.info);
    memset(&h->context, 0, sizeof h->context);
    h->callback = clientCB;
    if (clientCB && clientContext) {
        h->context = *clientContext;
        if (h->context.retain && h->context.info)
            h->context.info = (void *)h->context.retain(h->context.info);
    }
    if (!clientCB)
        h->cancelled = true, h->resolving = false;
    pthread_mutex_unlock(&h->m);
    return true;
}

void
CFHostScheduleWithRunLoop(CFHostRef host, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    if (!h->source) {
        /* the source holds the host only weakly: the host owns the source */
        CFRunLoopSourceContext ctx = {0, h, NULL, NULL, NULL, NULL, NULL, NULL, NULL, host_perform};
        h->source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    }
    CFArrayAppendValue(h->loops, runLoop);
    CFArrayAppendValue(h->modes, runLoopMode);
    pthread_mutex_unlock(&h->m);
    CFRunLoopAddSource(runLoop, h->source, runLoopMode);
}

void
CFHostUnscheduleFromRunLoop(CFHostRef host, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    struct __CFHost *h = (struct __CFHost *)host;
    pthread_mutex_lock(&h->m);
    for (CFIndex i = 0; i < CFArrayGetCount(h->loops); i++) {
        if (CFArrayGetValueAtIndex(h->loops, i) == runLoop && CFEqual(CFArrayGetValueAtIndex(h->modes, i), runLoopMode)) {
            CFArrayRemoveValueAtIndex(h->loops, i);
            CFArrayRemoveValueAtIndex(h->modes, i);
            break;
        }
    }
    CFRunLoopSourceRef src = h->source ? (CFRunLoopSourceRef)CFRetain(h->source) : NULL;
    pthread_mutex_unlock(&h->m);
    if (src) {
        CFRunLoopRemoveSource(runLoop, src, runLoopMode);
        CFRelease(src);
    }
}

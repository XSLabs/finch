/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Pasteboards, the store under NSPasteboard and the Pasteboard Manager (as Apple's
 * CFPasteboard is): named pasteboards of items, each item a list of typed flavors whose
 * data is there or promised by the process that wrote it. finch-pboardd keeps them for
 * every process of a user (userland/pboard); where it isn't running (a program on the
 * host, or before it starts) a pasteboard lives in the process, as it did before.
 *
 * A write starts by clearing the pasteboard, which makes the writer its owner for that
 * change count; promised data is asked of the owner when read, through the provider it
 * set. A process reading its own promise answers it itself, without asking the daemon.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.pboard"

typedef CFDataRef (*FinchPasteboardProvider)(CFStringRef name, CFIndex seed, uint64_t item, CFStringRef type, void *info);

typedef struct __FinchPasteboard {
    CFStringRef name;
    pthread_mutex_t lock;
    CFIndex ownSeed;               /* the change count this process wrote (0: none) */
    CFMutableSetRef ownPromises;   /* "item type" this process promised for ownSeed */
    FinchPasteboardProvider provider;
    void *info;
    /* the in-process store, when there's no daemon */
    CFIndex seed;
    CFMutableArrayRef items;       /* {id: number, types: [type], data: {type: data}} */
} FinchPasteboard;
typedef FinchPasteboard *FinchPasteboardRef;

static pthread_mutex_t all_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef all;      /* name -> FinchPasteboard (never freed: they're few) */
static xpc_connection_t pboard_daemon;
static int local_only = -1;             /* unknown until the daemon is first asked */
static dispatch_queue_t queue;

static CFStringRef
promise_key(uint64_t item, CFStringRef type)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%llu %@"), (unsigned long long)item, type);
}

static char *
cstring(CFStringRef s)
{
    CFIndex n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    char *c = malloc((size_t)n);
    if (c && !CFStringGetCString(s, c, n, kCFStringEncodingUTF8))
        c[0] = 0;
    return c;
}

static FinchPasteboardRef lookup(CFStringRef name);

/* The daemon asks for promised data: the provider gives it, or nothing. */
static void
handle_request(xpc_object_t msg)
{
    const char *op = xpc_dictionary_get_string(msg, "op");
    if (!op || strcmp(op, "provide"))
        return;
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (!reply)
        return;
    const char *name = xpc_dictionary_get_string(msg, "name"), *type = xpc_dictionary_get_string(msg, "type");
    CFIndex seed = (CFIndex)xpc_dictionary_get_int64(msg, "seed");
    uint64_t item = xpc_dictionary_get_uint64(msg, "item");
    if (name && type) {
        CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
        CFStringRef t = CFStringCreateWithCString(NULL, type, kCFStringEncodingUTF8);
        FinchPasteboardRef pb = lookup(n);
        FinchPasteboardProvider provider = NULL;
        void *info = NULL;
        pthread_mutex_lock(&pb->lock);
        if (seed == pb->ownSeed)
            provider = pb->provider, info = pb->info;
        pthread_mutex_unlock(&pb->lock);
        CFDataRef data = provider ? provider(n, seed, item, t, info) : NULL;
        if (data) {
            xpc_dictionary_set_data(reply, "data", CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
            CFRelease(data);
        }
        CFRelease(n);
        CFRelease(t);
    }
    xpc_connection_send_message(xpc_dictionary_get_remote_connection(msg), reply);
    xpc_release(reply);
}

static void
connect_daemon(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      queue = dispatch_queue_create("org.finch.pasteboard", DISPATCH_QUEUE_SERIAL);
      pboard_daemon = xpc_connection_create_mach_service(SERVICE, queue, 0);
      xpc_connection_set_event_handler(pboard_daemon, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_DICTIONARY)
            handle_request(event);
      });
      xpc_connection_resume(pboard_daemon);
    });
}

/* A request to the daemon and its reply (NULL: no daemon, and then never again). */
static xpc_object_t
call(xpc_object_t msg)
{
    if (local_only == 1)
        return NULL;
    connect_daemon();
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(pboard_daemon, msg);
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        xpc_release(reply);
        if (local_only == -1)
            local_only = 1;
        return NULL;
    }
    local_only = 0;
    return reply;
}

static xpc_object_t
request(const char *op, FinchPasteboardRef pb)
{
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", op);
    char *n = cstring(pb->name);
    xpc_dictionary_set_string(m, "name", n);
    free(n);
    return m;
}

static FinchPasteboardRef
lookup(CFStringRef name)
{
    pthread_mutex_lock(&all_lock);
    if (!all)
        all = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    FinchPasteboardRef pb = (FinchPasteboardRef)CFDictionaryGetValue(all, name);
    if (!pb) {
        pb = calloc(1, sizeof *pb);
        pb->name = CFStringCreateCopy(NULL, name);
        pthread_mutex_init(&pb->lock, NULL);
        pb->ownPromises = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
        pb->items = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(all, pb->name, pb);
    }
    pthread_mutex_unlock(&all_lock);
    return pb;
}

CF_EXPORT FinchPasteboardRef
_FinchPasteboardGet(CFStringRef name)
{
    return name ? lookup(name) : NULL;
}

CF_EXPORT CFStringRef
_FinchPasteboardGetName(FinchPasteboardRef pb)
{
    return pb->name;
}

/* The provider of this process's promises on the pasteboard. */
CF_EXPORT void
_FinchPasteboardSetProvider(FinchPasteboardRef pb, FinchPasteboardProvider provider, void *info)
{
    pthread_mutex_lock(&pb->lock);
    pb->provider = provider;
    pb->info = info;
    pthread_mutex_unlock(&pb->lock);
}

/* Empties the pasteboard and makes this process its owner: the new change count. */
CF_EXPORT CFIndex
_FinchPasteboardClear(FinchPasteboardRef pb)
{
    xpc_object_t m = request("clear", pb);
    xpc_object_t reply = call(m);
    xpc_release(m);
    pthread_mutex_lock(&pb->lock);
    CFIndex seed;
    if (reply) {
        seed = (CFIndex)xpc_dictionary_get_int64(reply, "seed");
        xpc_release(reply);
    } else {
        seed = ++pb->seed;
        CFArrayRemoveAllValues(pb->items);
    }
    pb->ownSeed = seed;
    CFSetRemoveAllValues(pb->ownPromises);
    pthread_mutex_unlock(&pb->lock);
    return seed;
}

CF_EXPORT CFIndex
_FinchPasteboardGetChangeCount(FinchPasteboardRef pb)
{
    xpc_object_t m = request("seed", pb);
    xpc_object_t reply = call(m);
    xpc_release(m);
    if (!reply) {
        pthread_mutex_lock(&pb->lock);
        CFIndex s = pb->seed;
        pthread_mutex_unlock(&pb->lock);
        return s;
    }
    CFIndex s = (CFIndex)xpc_dictionary_get_int64(reply, "seed");
    xpc_release(reply);
    return s;
}

/* The in-process item with this ID (made when asked to). */
static CFMutableDictionaryRef
local_item(FinchPasteboardRef pb, uint64_t item, Boolean make)
{
    for (CFIndex i = 0; i < CFArrayGetCount(pb->items); i++) {
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(pb->items, i);
        uint64_t id = 0;
        CFNumberGetValue(CFDictionaryGetValue(d, CFSTR("id")), kCFNumberSInt64Type, &id);
        if (id == item)
            return d;
    }
    if (!make)
        return NULL;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &item);
    CFDictionarySetValue(d, CFSTR("id"), n);
    CFRelease(n);
    CFMutableArrayRef types = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(d, CFSTR("types"), types);
    CFRelease(types);
    CFMutableDictionaryRef data = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("data"), data);
    CFRelease(data);
    CFArrayAppendValue(pb->items, d);
    CFRelease(d);
    return d;
}

/* Puts a flavor on an item (data NULL: promised by this process). False if the
   pasteboard has changed since the writer cleared it. */
CF_EXPORT Boolean
_FinchPasteboardPut(FinchPasteboardRef pb, CFIndex seed, uint64_t item, CFStringRef type, CFDataRef data)
{
    pthread_mutex_lock(&pb->lock);
    Boolean mine = seed == pb->ownSeed;
    if (mine) {
        CFStringRef k = promise_key(item, type);
        if (data)
            CFSetRemoveValue(pb->ownPromises, k);
        else
            CFSetAddValue(pb->ownPromises, k);
        CFRelease(k);
    }
    pthread_mutex_unlock(&pb->lock);
    if (!mine)
        return false;
    xpc_object_t m = request("put", pb);
    xpc_dictionary_set_int64(m, "seed", seed);
    xpc_dictionary_set_uint64(m, "item", item);
    char *t = cstring(type);
    xpc_dictionary_set_string(m, "type", t);
    free(t);
    if (data)
        xpc_dictionary_set_data(m, "data", CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
    xpc_object_t reply = call(m);
    xpc_release(m);
    if (reply) {
        Boolean ok = !xpc_dictionary_get_bool(reply, "stale");
        xpc_release(reply);
        return ok;
    }
    pthread_mutex_lock(&pb->lock);
    Boolean ok = seed == pb->seed;
    if (ok) {
        CFMutableDictionaryRef d = local_item(pb, item, true);
        CFMutableArrayRef types = (CFMutableArrayRef)CFDictionaryGetValue(d, CFSTR("types"));
        if (!CFArrayContainsValue(types, CFRangeMake(0, CFArrayGetCount(types)), type))
            CFArrayAppendValue(types, type);
        CFMutableDictionaryRef values = (CFMutableDictionaryRef)CFDictionaryGetValue(d, CFSTR("data"));
        if (data)
            CFDictionarySetValue(values, type, data);
        else
            CFDictionaryRemoveValue(values, type);
    }
    pthread_mutex_unlock(&pb->lock);
    return ok;
}

/* The items: [{id, types}], and the change count they're of. */
CF_EXPORT CFArrayRef
_FinchPasteboardCopyItems(FinchPasteboardRef pb, CFIndex *seed)
{
    xpc_object_t m = request("items", pb);
    xpc_object_t reply = call(m);
    xpc_release(m);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (reply) {
        if (seed)
            *seed = (CFIndex)xpc_dictionary_get_int64(reply, "seed");
        xpc_object_t items = xpc_dictionary_get_value(reply, "items");
        size_t n = items ? xpc_array_get_count(items) : 0;
        for (size_t i = 0; i < n; i++) {
            xpc_object_t it = xpc_array_get_value(items, i);
            uint64_t id = xpc_dictionary_get_uint64(it, "id");
            xpc_object_t types = xpc_dictionary_get_value(it, "types");
            CFMutableArrayRef ts = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
            for (size_t k = 0; types && k < xpc_array_get_count(types); k++) {
                CFStringRef t = CFStringCreateWithCString(NULL, xpc_array_get_string(types, k), kCFStringEncodingUTF8);
                if (t) {
                    CFArrayAppendValue(ts, t);
                    CFRelease(t);
                }
            }
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
            const void *keys[] = {CFSTR("id"), CFSTR("types")}, *values[] = {num, ts};
            CFDictionaryRef d = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(out, d);
            CFRelease(d);
            CFRelease(num);
            CFRelease(ts);
        }
        xpc_release(reply);
        return out;
    }
    pthread_mutex_lock(&pb->lock);
    if (seed)
        *seed = pb->seed;
    for (CFIndex i = 0; i < CFArrayGetCount(pb->items); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(pb->items, i);
        const void *keys[] = {CFSTR("id"), CFSTR("types")};
        const void *values[] = {CFDictionaryGetValue(d, CFSTR("id")), CFDictionaryGetValue(d, CFSTR("types"))};
        CFArrayRef types = CFArrayCreateCopy(NULL, values[1]);
        values[1] = types;
        CFDictionaryRef copy = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(out, copy);
        CFRelease(copy);
        CFRelease(types);
    }
    pthread_mutex_unlock(&pb->lock);
    return out;
}

/* A flavor's data: its own promise from this process's provider, others' from the
   daemon (which asks their owner). */
CF_EXPORT CFDataRef
_FinchPasteboardCopyData(FinchPasteboardRef pb, uint64_t item, CFStringRef type)
{
    CFStringRef k = promise_key(item, type);
    pthread_mutex_lock(&pb->lock);
    Boolean ownPromise = CFSetContainsValue(pb->ownPromises, k);
    FinchPasteboardProvider provider = pb->provider;
    void *info = pb->info;
    CFIndex own = pb->ownSeed;
    pthread_mutex_unlock(&pb->lock);
    CFRelease(k);
    if (ownPromise && provider && _FinchPasteboardGetChangeCount(pb) == own) {
        CFDataRef data = provider(pb->name, own, item, type, info);
        if (data) {
            _FinchPasteboardPut(pb, own, item, type, data);
            return data;
        }
        return NULL;
    }
    xpc_object_t m = request("get", pb);
    xpc_dictionary_set_uint64(m, "item", item);
    char *t = cstring(type);
    xpc_dictionary_set_string(m, "type", t);
    free(t);
    xpc_object_t reply = call(m);
    xpc_release(m);
    if (reply) {
        size_t len = 0;
        const void *bytes = xpc_dictionary_get_data(reply, "data", &len);
        CFDataRef d = bytes ? CFDataCreate(NULL, bytes, (CFIndex)len) : NULL;
        xpc_release(reply);
        return d;
    }
    pthread_mutex_lock(&pb->lock);
    CFMutableDictionaryRef d = local_item(pb, item, false);
    CFDataRef data = d ? CFDictionaryGetValue(CFDictionaryGetValue(d, CFSTR("data")), type) : NULL;
    if (data)
        CFRetain(data);
    pthread_mutex_unlock(&pb->lock);
    return data;
}

/* The pasteboard is no longer wanted (a unique one, released globally). */
CF_EXPORT void
_FinchPasteboardRelease(FinchPasteboardRef pb)
{
    xpc_object_t m = request("release", pb);
    xpc_object_t reply = call(m);
    xpc_release(m);
    if (reply)
        xpc_release(reply);
    pthread_mutex_lock(&pb->lock);
    CFArrayRemoveAllValues(pb->items);
    CFSetRemoveAllValues(pb->ownPromises);
    pb->ownSeed = 0;
    pthread_mutex_unlock(&pb->lock);
}

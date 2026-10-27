/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFNotificationCenter, which swift-corelibs doesn't have (only the header).
 *
 * As on macOS, there are three centers:
 * - The local center shares its observers with Foundation's default
 *   NSNotificationCenter: a notification posted through either reaches the
 *   observers of both, in the order they were added. Observers are kept as
 *   NSNotificationCenter observers when Foundation is loaded (looked up at
 *   run time; CF sits below it), and in CF's own list when it isn't.
 * - The Darwin center rides on notify(3): names only, delivered on the main
 *   queue; the object and user info are dropped, as macOS's are.
 * - The distributed center goes through finch-distnoted (userland/distnoted):
 *   observers' filters are registered with it, posts go to it, and it hands each
 *   notification to every process observing it, the poster included; they're
 *   delivered on the main queue with the object (a string, matched by value) and
 *   the user info (a property list). Without the service (a process outside
 *   Finch's domains), they're delivered within the process the same way.
 */
#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#include <CoreFoundation/CFNotificationCenter.h>
#import <objc/NSObject.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <xpc/xpc.h>

enum { LOCAL, DARWIN, DISTRIBUTED };

typedef struct {
    const void *observer;
    CFNotificationCallback callback;
    CFStringRef name;     /* NULL: any */
    const void *object;   /* NULL: any */
    id proxy;             /* the NSNotificationCenter observer (local center, with Foundation) */
    int token;            /* notify(3) registration (Darwin center) */
    int64_t id;           /* its filter in finch-distnoted (distributed center) */
} Observer;

struct __CFNotificationCenter {
    CFRuntimeBase base;
    int kind;
    os_unfair_lock lock;
    Observer *observers;
    CFIndex count, capacity;
};

static CFStringRef
copy_description(CFTypeRef cf)
{
    return CFStringCreateWithFormat(kCFAllocatorSystemDefault, NULL, CFSTR("<CFNotificationCenter %p [%p]>"), cf,
                                    CFGetAllocator(cf));
}

static const CFRuntimeClass __CFNotificationCenterClass = {
    .version = 0,
    .className = "CFNotificationCenter",
    .copyDebugDesc = copy_description,
};

static CFTypeID type_id;
static struct __CFNotificationCenter *centers[3];

static void
make_centers(void)
{
    type_id = _CFRuntimeRegisterClass(&__CFNotificationCenterClass);
    for (int i = 0; i < 3; i++) {
        centers[i] = (struct __CFNotificationCenter *)_CFRuntimeCreateInstance(
            kCFAllocatorSystemDefault, type_id, sizeof(struct __CFNotificationCenter) - sizeof(CFRuntimeBase), NULL);
        centers[i]->kind = i;
        centers[i]->lock = OS_UNFAIR_LOCK_INIT;
    }
}

static struct __CFNotificationCenter *
center(int kind)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_centers);
    return centers[kind];
}

CFTypeID
CFNotificationCenterGetTypeID(void)
{
    center(LOCAL);
    return type_id;
}

CFNotificationCenterRef CFNotificationCenterGetLocalCenter(void) { return center(LOCAL); }
CFNotificationCenterRef CFNotificationCenterGetDarwinNotifyCenter(void) { return center(DARWIN); }
CFNotificationCenterRef CFNotificationCenterGetDistributedCenter(void) { return center(DISTRIBUTED); }

#pragma mark Foundation's default center

static id
ns_default_center(void)
{
    Class c = objc_getClass("NSNotificationCenter");
    return c ? ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("defaultCenter")) : nil;
}

/* An NSNotificationCenter observer that calls a CF callback. */
@interface __CFNotificationObserver : NSObject {
@public
    CFNotificationCallback callback;
    const void *observer;
}
@end

@implementation __CFNotificationObserver
- (void)_cfNotify:(id)note
{
    CFStringRef name = (CFStringRef)((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("name"));
    id object = ((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("object"));
    CFDictionaryRef info = (CFDictionaryRef)((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("userInfo"));
    callback((CFNotificationCenterRef)center(LOCAL), (void *)observer, name, object, info);
}
@end

#pragma mark The distributed service

#define DISTNOTED "org.finch.distnoted"

static xpc_connection_t dist_connection;   /* NULL: no service, deliver in-process */
static int64_t dist_next_id;
static void deliver_distributed(CFStringRef name, CFStringRef object, CFDictionaryRef info);

static void
dist_send_observe(const Observer *o)
{
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "observe");
    xpc_dictionary_set_int64(m, "id", o->id);
    char buf[1024];
    if (o->name && CFStringGetCString(o->name, buf, sizeof buf, kCFStringEncodingUTF8))
        xpc_dictionary_set_string(m, "name", buf);
    if (o->object && CFGetTypeID(o->object) == CFStringGetTypeID() &&
        CFStringGetCString((CFStringRef)o->object, buf, sizeof buf, kCFStringEncodingUTF8))
        xpc_dictionary_set_string(m, "object", buf);
    xpc_connection_send_message(dist_connection, m);
    xpc_release(m);
}

static void
dist_receive(xpc_object_t event)
{
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        /* the service started again: tell it what's observed */
        struct __CFNotificationCenter *c = center(DISTRIBUTED);
        os_unfair_lock_lock(&c->lock);
        for (CFIndex i = 0; i < c->count; i++)
            dist_send_observe(&c->observers[i]);
        os_unfair_lock_unlock(&c->lock);
        return;
    }
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY)
        return;
    const char *op = xpc_dictionary_get_string(event, "op"), *name = xpc_dictionary_get_string(event, "name");
    if (!op || strcmp(op, "notification") || !name)
        return;
    const char *object = xpc_dictionary_get_string(event, "object");
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(event, "userInfo", &length);
    CFStringRef n = CFStringCreateWithCString(kCFAllocatorSystemDefault, name, kCFStringEncodingUTF8);
    CFStringRef obj = object ? CFStringCreateWithCString(kCFAllocatorSystemDefault, object, kCFStringEncodingUTF8) : NULL;
    CFDictionaryRef info = NULL;
    if (bytes) {
        CFDataRef d = CFDataCreate(kCFAllocatorSystemDefault, bytes, (CFIndex)length);
        CFPropertyListRef pl = CFPropertyListCreateWithData(kCFAllocatorSystemDefault, d, kCFPropertyListImmutable, NULL, NULL);
        CFRelease(d);
        if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID())
            info = pl;
        else if (pl)
            CFRelease(pl);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        deliver_distributed(n, obj, info);
        CFRelease(n);
        if (obj)
            CFRelease(obj);
        if (info)
            CFRelease(info);
    });
}

/* The connection to finch-distnoted, if the process can reach one. */
static xpc_connection_t
dist_service(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_port_t port = MACH_PORT_NULL;
        if (bootstrap_look_up(bootstrap_port, DISTNOTED, &port) != KERN_SUCCESS || port == MACH_PORT_NULL)
            return;
        mach_port_deallocate(mach_task_self(), port);
        dispatch_queue_t q = dispatch_queue_create("com.apple.CFNotificationCenter.distributed", DISPATCH_QUEUE_SERIAL);
        dist_connection = xpc_connection_create_mach_service(DISTNOTED, q, 0);
        xpc_connection_set_event_handler(dist_connection, ^(xpc_object_t event) { dist_receive(event); });
        xpc_connection_resume(dist_connection);
    });
    return dist_connection;
}

#pragma mark Observers

static void
append(struct __CFNotificationCenter *c, Observer o)
{
    if (c->count == c->capacity) {
        c->capacity = c->capacity ? c->capacity * 2 : 8;
        c->observers = realloc(c->observers, (size_t)c->capacity * sizeof(Observer));
    }
    c->observers[c->count++] = o;
}

static void
deliver_darwin(CFStringRef name)
{
    struct __CFNotificationCenter *c = center(DARWIN);
    os_unfair_lock_lock(&c->lock);
    CFIndex n = 0;
    Observer *hits = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    for (CFIndex i = 0; i < c->count; i++)
        if (c->observers[i].name && CFEqual(c->observers[i].name, name))
            hits[n++] = c->observers[i];
    os_unfair_lock_unlock(&c->lock);
    /* macOS hands Darwin observers this placeholder in place of an object */
    for (CFIndex i = 0; i < n; i++)
        hits[i].callback(c, (void *)hits[i].observer, name, CFSTR("kCFNotificationAnyObject"), NULL);
    free(hits);
}

void
CFNotificationCenterAddObserver(CFNotificationCenterRef cref, const void *observer, CFNotificationCallback callBack,
                                CFStringRef name, const void *object,
                                CFNotificationSuspensionBehavior suspensionBehavior)
{
    struct __CFNotificationCenter *c = (struct __CFNotificationCenter *)cref;
    if (!c || !callBack)
        return;
    Observer o = {observer, callBack, name ? CFStringCreateCopy(kCFAllocatorSystemDefault, name) : NULL, object, nil, 0};
    if (c->kind == DARWIN) {
        if (!name)
            return;  /* macOS requires a name here */
        char buf[512];
        if (!CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
            return;
        CFStringRef held = o.name;
        CFRetain(held);
        notify_register_dispatch(buf, &o.token, dispatch_get_main_queue(), ^(int token) {
            deliver_darwin(held);
        });
    } else if (c->kind == DISTRIBUTED) {
        /* (the object is a string, kept by value) */
        if (o.object)
            o.object = CFGetTypeID(o.object) == CFStringGetTypeID()
                           ? CFStringCreateCopy(kCFAllocatorSystemDefault, (CFStringRef)o.object) : NULL;
        o.id = __atomic_add_fetch(&dist_next_id, 1, __ATOMIC_RELAXED);
        if (dist_service())
            dist_send_observe(&o);
    } else if (c->kind == LOCAL) {
        id ns = ns_default_center();
        if (ns) {
            __CFNotificationObserver *p = [[__CFNotificationObserver alloc] init];
            p->callback = callBack;
            p->observer = observer;
            o.proxy = p;
            ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(ns, sel_registerName("addObserver:selector:name:object:"),
                                                              p, @selector(_cfNotify:), (id)name, (id)object);
        }
    }
    os_unfair_lock_lock(&c->lock);
    append(c, o);
    os_unfair_lock_unlock(&c->lock);
}

static void
remove_matching(struct __CFNotificationCenter *c, const void *observer, CFStringRef name, const void *object, bool every)
{
    os_unfair_lock_lock(&c->lock);
    CFIndex n = 0;
    Observer *gone = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    CFIndex k = 0;
    for (CFIndex i = 0; i < c->count; i++) {
        Observer *o = &c->observers[i];
        bool sameObject = !object || o->object == object ||
                          (c->kind == DISTRIBUTED && o->object && CFEqual(o->object, object));
        bool match = o->observer == observer && (every || ((!name || (o->name && CFEqual(o->name, name))) && sameObject));
        if (match)
            gone[n++] = *o;
        else
            c->observers[k++] = *o;
    }
    c->count = k;
    os_unfair_lock_unlock(&c->lock);
    id ns = n && c->kind == LOCAL ? ns_default_center() : nil;
    for (CFIndex i = 0; i < n; i++) {
        if (gone[i].proxy) {
            ((void (*)(id, SEL, id))objc_msgSend)(ns, sel_registerName("removeObserver:"), gone[i].proxy);
            [gone[i].proxy release];
        }
        if (c->kind == DARWIN)
            notify_cancel(gone[i].token);
        if (c->kind == DISTRIBUTED) {
            if (dist_connection) {
                xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
                xpc_dictionary_set_string(m, "op", "unobserve");
                xpc_dictionary_set_int64(m, "id", gone[i].id);
                xpc_connection_send_message(dist_connection, m);
                xpc_release(m);
            }
            if (gone[i].object)
                CFRelease(gone[i].object);
        }
        if (gone[i].name)
            CFRelease(gone[i].name);
    }
    free(gone);
}

void
CFNotificationCenterRemoveObserver(CFNotificationCenterRef c, const void *observer, CFNotificationName name,
                                   const void *object)
{
    if (c)
        remove_matching((struct __CFNotificationCenter *)c, observer, name, object, false);
}

void
CFNotificationCenterRemoveEveryObserver(CFNotificationCenterRef c, const void *observer)
{
    if (c)
        remove_matching((struct __CFNotificationCenter *)c, observer, NULL, NULL, true);
}

#pragma mark Posting

/* The observers of a CF-only list that match, copied out so callbacks can add or remove. */
static Observer *
matches(struct __CFNotificationCenter *c, CFStringRef name, const void *object, CFIndex *count)
{
    os_unfair_lock_lock(&c->lock);
    Observer *hits = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    CFIndex n = 0;
    for (CFIndex i = 0; i < c->count; i++) {
        Observer *o = &c->observers[i];
        bool sameObject = !o->object || o->object == object ||
                          (c->kind == DISTRIBUTED && object && CFEqual(o->object, object));
        if ((!o->name || CFEqual(o->name, name)) && sameObject)
            hits[n++] = *o;
    }
    os_unfair_lock_unlock(&c->lock);
    *count = n;
    return hits;
}

void
CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterRef cref, CFNotificationName name,
                                                const void *object, CFDictionaryRef userInfo, CFOptionFlags options)
{
    struct __CFNotificationCenter *c = (struct __CFNotificationCenter *)cref;
    if (!c || !name)
        return;
    if (c->kind == DARWIN) {
        char buf[512];
        if (CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
            notify_post(buf);
        return;
    }
    if (c->kind == LOCAL) {
        id ns = ns_default_center();
        if (ns) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(ns, sel_registerName("postNotificationName:object:userInfo:"),
                                                          (id)name, (id)object, (id)userInfo);
            return;
        }
        CFIndex n;
        Observer *hits = matches(c, name, object, &n);
        for (CFIndex i = 0; i < n; i++)
            hits[i].callback(c, (void *)hits[i].observer, name, object, userInfo);
        free(hits);
        return;
    }
    /* distributed: through finch-distnoted, which hands it back to every process
       observing it (this one too); without it, the same here */
    CFStringRef obj = object && CFGetTypeID(object) == CFStringGetTypeID() ? (CFStringRef)object : NULL;
    xpc_connection_t service = dist_service();
    if (service) {
        char nbuf[1024], obuf[1024];
        if (!CFStringGetCString(name, nbuf, sizeof nbuf, kCFStringEncodingUTF8))
            return;
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "op", "post");
        xpc_dictionary_set_string(m, "name", nbuf);
        if (obj && CFStringGetCString(obj, obuf, sizeof obuf, kCFStringEncodingUTF8))
            xpc_dictionary_set_string(m, "object", obuf);
        if (userInfo) {
            CFDataRef d = CFPropertyListCreateData(kCFAllocatorSystemDefault, userInfo, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
            if (d) {
                xpc_dictionary_set_data(m, "userInfo", CFDataGetBytePtr(d), (size_t)CFDataGetLength(d));
                CFRelease(d);
            }
        }
        xpc_connection_send_message(service, m);
        xpc_release(m);
        return;
    }
    CFStringRef n = CFStringCreateCopy(kCFAllocatorSystemDefault, name);
    CFStringRef o = obj ? CFStringCreateCopy(kCFAllocatorSystemDefault, obj) : NULL;
    CFDictionaryRef info = userInfo ? CFDictionaryCreateCopy(kCFAllocatorSystemDefault, userInfo) : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        deliver_distributed(n, o, info);
        CFRelease(n);
        if (o)
            CFRelease(o);
        if (info)
            CFRelease(info);
    });
}

static void
deliver_distributed(CFStringRef name, CFStringRef object, CFDictionaryRef info)
{
    struct __CFNotificationCenter *c = center(DISTRIBUTED);
    CFIndex count;
    Observer *hits = matches(c, name, object, &count);
    for (CFIndex i = 0; i < count; i++)
        hits[i].callback(c, (void *)hits[i].observer, name, object, info);
    free(hits);
}

void
CFNotificationCenterPostNotification(CFNotificationCenterRef c, CFNotificationName name, const void *object,
                                     CFDictionaryRef userInfo, Boolean deliverImmediately)
{
    CFNotificationCenterPostNotificationWithOptions(c, name, object, userInfo,
                                                    deliverImmediately ? kCFNotificationDeliverImmediately : 0);
}

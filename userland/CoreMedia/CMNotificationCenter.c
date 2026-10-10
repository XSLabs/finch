/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's notification center (private API; the signatures are those WebKit
 * declares for it), Finch's: listeners for a name (or every name) from an object (or
 * any), called as each notification is posted, on the poster's thread. Sample buffers
 * post kCMSampleBufferNotification_DataBecameReady through it.
 */
#include "CMInternal.h"
#include <stdlib.h>

typedef struct OpaqueCMNotificationCenter *CMNotificationCenterRef;
typedef void (*CMNotificationCallback)(CMNotificationCenterRef center, const void *listener, CFStringRef name, const void *object,
                                       CFTypeRef payload);

typedef struct {
    const void *listener;
    CMNotificationCallback callback;
    CFStringRef name;
    const void *object;
} Listener;

struct OpaqueCMNotificationCenter {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    Listener *listeners;
    size_t count, capacity;
};

CM_DEFINE_TYPE(CMNotificationCenterGetTypeID, "CMNotificationCenter", NULL, NULL, NULL, NULL)

static CMNotificationCenterRef local;

static void
make_local(void)
{
    local = (CMNotificationCenterRef)cm_create(NULL, CMNotificationCenterGetTypeID(), sizeof(struct OpaqueCMNotificationCenter));
    pthread_mutex_init(&local->lock, NULL);
}

CMNotificationCenterRef
CMNotificationCenterGetDefaultLocalCenter(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_local);
    return local;
}

OSStatus
CMNotificationCenterAddListener(CMNotificationCenterRef center, const void *listener, CMNotificationCallback callback, CFStringRef name,
                                const void *object, UInt32 flags)
{
    if (!center || !callback)
        return -12780; /* (kCMNotificationCenterError_ParamErr) */
    pthread_mutex_lock(&center->lock);
    if (center->count == center->capacity) {
        size_t c = center->capacity ? center->capacity * 2 : 8;
        Listener *l = realloc(center->listeners, c * sizeof *l);
        if (!l) {
            pthread_mutex_unlock(&center->lock);
            return -12781;
        }
        center->listeners = l, center->capacity = c;
    }
    center->listeners[center->count++] = (Listener){listener, callback, name ? CFStringCreateCopy(NULL, name) : NULL, object};
    pthread_mutex_unlock(&center->lock);
    return noErr;
}

static bool
same_name(CFStringRef a, CFStringRef b)
{
    return a == b || (a && b && CFEqual(a, b));
}

OSStatus
CMNotificationCenterRemoveListener(CMNotificationCenterRef center, const void *listener, CMNotificationCallback callback, CFStringRef name,
                                   const void *object)
{
    if (!center)
        return -12780;
    bool found = false;
    pthread_mutex_lock(&center->lock);
    for (size_t i = 0; i < center->count;) {
        Listener *l = &center->listeners[i];
        if (l->listener == listener && l->callback == callback && same_name(l->name, name) && l->object == object) {
            if (l->name)
                CFRelease(l->name);
            center->listeners[i] = center->listeners[--center->count];
            found = true;
        } else
            i++;
    }
    pthread_mutex_unlock(&center->lock);
    return found ? noErr : -12782; /* (kCMNotificationCenterError_ListenerNotFound) */
}

OSStatus
CMNotificationCenterPostNotification(CMNotificationCenterRef center, CFStringRef name, const void *object, CFTypeRef payload, UInt32 flags)
{
    if (!center || !name)
        return -12780;
    /* (the matching listeners copied out, so a callback may add or remove listeners) */
    pthread_mutex_lock(&center->lock);
    Listener *matching = malloc(sizeof *matching * (center->count ? center->count : 1));
    size_t n = 0;
    for (size_t i = 0; i < center->count; i++) {
        Listener *l = &center->listeners[i];
        if ((!l->name || CFEqual(l->name, name)) && (!l->object || l->object == object))
            matching[n++] = *l;
    }
    pthread_mutex_unlock(&center->lock);
    for (size_t i = 0; i < n; i++)
        matching[i].callback(center, matching[i].listener, name, object, payload);
    free(matching);
    return noErr;
}

void
_FinchCMPostDataBecameReady(CMSampleBufferRef sbuf)
{
    CMNotificationCenterPostNotification(CMNotificationCenterGetDefaultLocalCenter(), kCMSampleBufferNotification_DataBecameReady, sbuf, NULL, 0);
}

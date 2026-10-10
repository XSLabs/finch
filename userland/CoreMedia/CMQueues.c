/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's queues and memory pools, Finch's.
 *
 * A simple queue is a ring of pointers. A buffer queue holds CF buffers (sample
 * buffers, usually) in arrival order or sorted by a comparison, and answers for their
 * total duration, size and times through the callbacks it was made with; its triggers
 * fire when their condition becomes true (and when installed, if it already is), as
 * Apple's do. A memory pool's allocator keeps freed blocks to hand out again, for a
 * while (half a second unless asked).
 */
#include "CMInternal.h"
#include <Block.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* --- simple queues --- */

struct opaqueCMSimpleQueue {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    const void **ring;
    int32_t capacity, head, count;
};

static void
simple_finalize(CFTypeRef cf)
{
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)cf;
    free(q->ring);
    pthread_mutex_destroy(&q->lock);
}

CM_DEFINE_TYPE(CMSimpleQueueGetTypeID, "CMSimpleQueue", simple_finalize, NULL, NULL, NULL)

OSStatus
CMSimpleQueueCreate(CFAllocatorRef allocator, int32_t capacity, CMSimpleQueueRef *queueOut)
{
    if (!queueOut)
        return kCMSimpleQueueError_RequiredParameterMissing;
    *queueOut = NULL;
    if (capacity < 0)
        return kCMSimpleQueueError_ParameterOutOfRange;
    if (capacity == 0)
        return kCMSimpleQueueError_RequiredParameterMissing;
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)cm_create(allocator, CMSimpleQueueGetTypeID(), sizeof(struct opaqueCMSimpleQueue));
    if (!q)
        return kCMSimpleQueueError_AllocationFailed;
    q->ring = calloc((size_t)capacity, sizeof(void *));
    q->capacity = capacity;
    pthread_mutex_init(&q->lock, NULL);
    *queueOut = q;
    return noErr;
}

OSStatus
CMSimpleQueueEnqueue(CMSimpleQueueRef queue, const void *element)
{
    if (!queue || !element)
        return kCMSimpleQueueError_RequiredParameterMissing;
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)queue;
    pthread_mutex_lock(&q->lock);
    OSStatus e = noErr;
    if (q->count == q->capacity)
        e = kCMSimpleQueueError_QueueIsFull;
    else
        q->ring[(q->head + q->count++) % q->capacity] = element;
    pthread_mutex_unlock(&q->lock);
    return e;
}

const void *
CMSimpleQueueDequeue(CMSimpleQueueRef queue)
{
    if (!queue)
        return NULL;
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)queue;
    pthread_mutex_lock(&q->lock);
    const void *v = NULL;
    if (q->count) {
        v = q->ring[q->head];
        q->head = (q->head + 1) % q->capacity;
        q->count--;
    }
    pthread_mutex_unlock(&q->lock);
    return v;
}

const void *
CMSimpleQueueGetHead(CMSimpleQueueRef queue)
{
    if (!queue)
        return NULL;
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)queue;
    pthread_mutex_lock(&q->lock);
    const void *v = q->count ? q->ring[q->head] : NULL;
    pthread_mutex_unlock(&q->lock);
    return v;
}

OSStatus
CMSimpleQueueReset(CMSimpleQueueRef queue)
{
    if (!queue)
        return kCMSimpleQueueError_RequiredParameterMissing;
    struct opaqueCMSimpleQueue *q = (struct opaqueCMSimpleQueue *)queue;
    pthread_mutex_lock(&q->lock);
    q->head = q->count = 0;
    pthread_mutex_unlock(&q->lock);
    return noErr;
}

int32_t
CMSimpleQueueGetCapacity(CMSimpleQueueRef queue)
{
    return queue ? queue->capacity : 0;
}

int32_t
CMSimpleQueueGetCount(CMSimpleQueueRef queue)
{
    return queue ? queue->count : 0;
}

/* --- buffer queues --- */

typedef struct Trigger {
    struct Trigger *next;
    CMBufferQueueTriggerCallback callback;
    void *refcon;
    CMBufferQueueTriggerHandler handler;
    CMBufferQueueTriggerCondition condition;
    CMTime time;
    CMItemCount count;
    bool state;
    CMTime last; /* (for the conditions on a time changing) */
} Trigger;

struct opaqueCMBufferQueue {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    CMBufferCallbacks callbacks;
    CMBufferHandlers handlers;
    bool useHandlers;
    CMItemCount capacity;
    CFMutableArrayRef buffers;
    bool endOfData;
    Trigger *triggers;
    int inTrigger;
    CMBufferValidationCallback validate;
    void *validateRefcon;
    CMBufferValidationHandler validateHandler;
};

typedef struct opaqueCMBufferQueue *BQ;

static void
queue_finalize(CFTypeRef cf)
{
    BQ q = (BQ)cf;
    for (Trigger *t = q->triggers, *next; t; t = next) {
        next = t->next;
        if (t->handler)
            Block_release(t->handler);
        free(t);
    }
    if (q->buffers)
        CFRelease(q->buffers);
    if (q->useHandlers) {
        CMBufferHandlers *h = &q->handlers;
        void *blocks[] = {(void *)h->getDecodeTimeStamp, (void *)h->getPresentationTimeStamp, (void *)h->getDuration, (void *)h->isDataReady,
                          (void *)h->compare, (void *)h->getSize};
        for (size_t i = 0; i < sizeof blocks / sizeof blocks[0]; i++)
            if (blocks[i])
                Block_release(blocks[i]);
        if (h->dataBecameReadyNotification)
            CFRelease(h->dataBecameReadyNotification);
    } else if (q->callbacks.dataBecameReadyNotification)
        CFRelease(q->callbacks.dataBecameReadyNotification);
    if (q->validateHandler)
        Block_release(q->validateHandler);
    pthread_mutex_destroy(&q->lock);
}

CM_DEFINE_TYPE(CMBufferQueueGetTypeID, "CMBufferQueue", queue_finalize, NULL, NULL, NULL)

/* The callbacks, whichever way they were given. */
static CMTime
get_time(BQ q, CMBufferRef b, int which)
{
    if (q->useHandlers) {
        CMBufferGetTimeHandler h = which == 0 ? q->handlers.getDecodeTimeStamp : which == 1 ? q->handlers.getPresentationTimeStamp
                                                                                            : q->handlers.getDuration;
        return h ? h(b) : kCMTimeInvalid;
    }
    CMBufferGetTimeCallback c = which == 0 ? q->callbacks.getDecodeTimeStamp : which == 1 ? q->callbacks.getPresentationTimeStamp
                                                                                         : q->callbacks.getDuration;
    return c ? c(b, q->callbacks.refcon) : kCMTimeInvalid;
}

#define DTS 0
#define PTS 1
#define DURATION 2

static bool
is_ready(BQ q, CMBufferRef b)
{
    if (q->useHandlers)
        return q->handlers.isDataReady ? q->handlers.isDataReady(b) : true;
    return q->callbacks.isDataReady ? q->callbacks.isDataReady(b, q->callbacks.refcon) : true;
}

static bool
has_compare(BQ q)
{
    return q->useHandlers ? q->handlers.compare != NULL : q->callbacks.compare != NULL;
}

static CFComparisonResult
compare(BQ q, CMBufferRef a, CMBufferRef b)
{
    return q->useHandlers ? q->handlers.compare(a, b) : q->callbacks.compare(a, b, q->callbacks.refcon);
}

static size_t
get_size(BQ q, CMBufferRef b)
{
    if (q->useHandlers)
        return q->handlers.getSize ? q->handlers.getSize(b) : 0;
    return q->callbacks.version >= 1 && q->callbacks.getSize ? q->callbacks.getSize(b, q->callbacks.refcon) : 0;
}

static CMTime
total_duration(BQ q)
{
    CMTime d = kCMTimeZero;
    for (CFIndex i = 0; i < CFArrayGetCount(q->buffers); i++) {
        CMTime b = get_time(q, CFArrayGetValueAtIndex(q->buffers, i), DURATION);
        if (CMTIME_IS_NUMERIC(b))
            d = CMTimeAdd(d, b);
    }
    return d;
}

/* The least or greatest of a time over the buffers. */
static CMTime
extreme(BQ q, int which, bool greatest)
{
    CMTime best = kCMTimeInvalid;
    for (CFIndex i = 0; i < CFArrayGetCount(q->buffers); i++) {
        CMTime t = get_time(q, CFArrayGetValueAtIndex(q->buffers, i), which);
        if (CMTIME_IS_NUMERIC(t) && (!CMTIME_IS_VALID(best) || (greatest ? CMTimeCompare(t, best) > 0 : CMTimeCompare(t, best) < 0)))
            best = t;
    }
    return best;
}

static bool
condition_holds(BQ q, Trigger *t)
{
    CMItemCount n = CFArrayGetCount(q->buffers);
    switch (t->condition) {
    case kCMBufferQueueTrigger_WhenDurationBecomesLessThan: return CMTimeCompare(total_duration(q), t->time) < 0;
    case kCMBufferQueueTrigger_WhenDurationBecomesLessThanOrEqualTo: return CMTimeCompare(total_duration(q), t->time) <= 0;
    case kCMBufferQueueTrigger_WhenDurationBecomesGreaterThan: return CMTimeCompare(total_duration(q), t->time) > 0;
    case kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualTo: return CMTimeCompare(total_duration(q), t->time) >= 0;
    case kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges: return CMTimeCompare(extreme(q, PTS, false), t->last) != 0;
    case kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges: return CMTimeCompare(extreme(q, PTS, true), t->last) != 0;
    case kCMBufferQueueTrigger_WhenDataBecomesReady: return n > 0 && is_ready(q, CFArrayGetValueAtIndex(q->buffers, 0));
    case kCMBufferQueueTrigger_WhenEndOfDataReached: return q->endOfData && n == 0;
    case kCMBufferQueueTrigger_WhenReset: return false;
    case kCMBufferQueueTrigger_WhenBufferCountBecomesLessThan: return n < t->count;
    case kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan: return n > t->count;
    case kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualToAndBufferCountBecomesGreaterThan:
        return CMTimeCompare(total_duration(q), t->time) >= 0 && n > t->count;
    }
    return false;
}

static void
fire(BQ q, Trigger *t)
{
    q->inTrigger++;
    if (t->callback)
        t->callback(t->refcon, (CMBufferQueueTriggerToken)t);
    if (t->handler)
        t->handler((CMBufferQueueTriggerToken)t);
    q->inTrigger--;
}

/* The order triggers are looked at in, as Apple's are: counts, presentation times, end of
   data, then durations by their threshold (least first), then data readiness. */
static int
group(const Trigger *t)
{
    switch (t->condition) {
    case kCMBufferQueueTrigger_WhenBufferCountBecomesLessThan:
    case kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan:
    case kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualToAndBufferCountBecomesGreaterThan: return 0;
    case kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges:
    case kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges: return 1;
    case kCMBufferQueueTrigger_WhenEndOfDataReached: return 2;
    case kCMBufferQueueTrigger_WhenDataBecomesReady: return 4;
    default: return 3;
    }
}

static bool
before(const Trigger *a, const Trigger *b)
{
    int ga = group(a), gb = group(b);
    if (ga != gb)
        return ga < gb;
    return ga == 3 && CMTimeCompare(a->time, b->time) < 0;
}

/* Each trigger whose condition has become true fires (the lock held, recursively). */
static void
check_triggers(BQ q, bool reset)
{
    size_t n = 0;
    for (Trigger *t = q->triggers; t; t = t->next)
        n++;
    Trigger **order = malloc(sizeof *order * (n ? n : 1));
    n = 0;
    for (Trigger *t = q->triggers; t; t = t->next) {
        /* (an insertion sort, stable, so equal ones keep the order they were installed in) */
        size_t at = n++;
        while (at > 0 && before(t, order[at - 1])) {
            order[at] = order[at - 1];
            at--;
        }
        order[at] = t;
    }
    for (size_t i = 0; i < n; i++) {
        Trigger *t = order[i];
        if (t->condition == kCMBufferQueueTrigger_WhenReset) {
            if (reset)
                fire(q, t);
            continue;
        }
        bool now = condition_holds(q, t);
        if (t->condition == kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges ||
            t->condition == kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges) {
            if (now) {
                t->last = extreme(q, PTS, t->condition == kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges);
                fire(q, t);
            }
            continue;
        }
        if (now && !t->state)
            fire(q, t);
        t->state = now;
    }
    free(order);
}

static void listen_ready(BQ q);

static OSStatus
make_queue(CFAllocatorRef allocator, CMItemCount capacity, CMBufferQueueRef *queueOut, BQ *out)
{
    if (!queueOut)
        return kCMBufferQueueError_RequiredParameterMissing;
    *queueOut = NULL;
    if (capacity < 0)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)cm_create(allocator, CMBufferQueueGetTypeID(), sizeof(struct opaqueCMBufferQueue));
    if (!q)
        return kCMBufferQueueError_AllocationFailed;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&q->lock, &attr);
    pthread_mutexattr_destroy(&attr);
    q->capacity = capacity;
    q->buffers = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    *out = q;
    return noErr;
}

OSStatus
CMBufferQueueCreate(CFAllocatorRef allocator, CMItemCount capacity, const CMBufferCallbacks *callbacks, CMBufferQueueRef *queueOut)
{
    if (!callbacks)
        return kCMBufferQueueError_RequiredParameterMissing;
    if (callbacks->version > 1 || !callbacks->getDuration)
        return kCMBufferQueueError_InvalidCMBufferCallbacksStruct;
    BQ q;
    OSStatus e = make_queue(allocator, capacity, queueOut, &q);
    if (e)
        return e;
    q->callbacks = *callbacks;
    if (q->callbacks.dataBecameReadyNotification)
        CFRetain(q->callbacks.dataBecameReadyNotification);
    *queueOut = q;
    return noErr;
}

OSStatus
CMBufferQueueCreateWithHandlers(CFAllocatorRef allocator, CMItemCount capacity, const CMBufferHandlers *handlers, CMBufferQueueRef *queueOut)
{
    if (!handlers)
        return kCMBufferQueueError_RequiredParameterMissing;
    if (!handlers->getDuration)
        return kCMBufferQueueError_InvalidCMBufferCallbacksStruct;
    BQ q;
    OSStatus e = make_queue(allocator, capacity, queueOut, &q);
    if (e)
        return e;
    q->useHandlers = true;
    q->handlers = *handlers;
    CMBufferHandlers *h = &q->handlers;
    h->getDecodeTimeStamp = h->getDecodeTimeStamp ? Block_copy(h->getDecodeTimeStamp) : NULL;
    h->getPresentationTimeStamp = h->getPresentationTimeStamp ? Block_copy(h->getPresentationTimeStamp) : NULL;
    h->getDuration = Block_copy(h->getDuration);
    h->isDataReady = h->isDataReady ? Block_copy(h->isDataReady) : NULL;
    h->compare = h->compare ? Block_copy(h->compare) : NULL;
    h->getSize = h->getSize ? Block_copy(h->getSize) : NULL;
    if (h->dataBecameReadyNotification)
        CFRetain(h->dataBecameReadyNotification);
    *queueOut = q;
    return noErr;
}

/* The callbacks for sample buffers. */
static CMTime
sb_dts(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetDecodeTimeStamp((CMSampleBufferRef)b);
}

static CMTime
sb_pts(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetPresentationTimeStamp((CMSampleBufferRef)b);
}

static CMTime
sb_duration(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetDuration((CMSampleBufferRef)b);
}

static Boolean
sb_ready(CMBufferRef b, void *refcon)
{
    return CMSampleBufferDataIsReady((CMSampleBufferRef)b);
}

static size_t
sb_size(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetTotalSampleSize((CMSampleBufferRef)b);
}

static CMTime
sb_output_pts(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetOutputPresentationTimeStamp((CMSampleBufferRef)b);
}

static CMTime
sb_output_duration(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetOutputDuration((CMSampleBufferRef)b);
}

static CMTime
sb_output_dts(CMBufferRef b, void *refcon)
{
    return CMSampleBufferGetOutputDecodeTimeStamp((CMSampleBufferRef)b);
}

static CFComparisonResult
sb_compare_output(CMBufferRef a, CMBufferRef b, void *refcon)
{
    int32_t c = CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp((CMSampleBufferRef)a),
                              CMSampleBufferGetOutputPresentationTimeStamp((CMSampleBufferRef)b));
    return c < 0 ? kCFCompareLessThan : c > 0 ? kCFCompareGreaterThan : kCFCompareEqualTo;
}

static CMBufferCallbacks unsorted, sortedByOutput;

static void
make_callbacks(void)
{
    unsorted = (CMBufferCallbacks){1, NULL, sb_dts, sb_pts, sb_duration, sb_ready, NULL, kCMSampleBufferNotification_DataBecameReady, sb_size};
    sortedByOutput = (CMBufferCallbacks){1, NULL, sb_output_dts, sb_output_pts, sb_output_duration, sb_ready, sb_compare_output,
                                         kCMSampleBufferNotification_DataBecameReady, sb_size};
}

const CMBufferCallbacks *
CMBufferQueueGetCallbacksForUnsortedSampleBuffers(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_callbacks);
    return &unsorted;
}

const CMBufferCallbacks *
CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS(void)
{
    CMBufferQueueGetCallbacksForUnsortedSampleBuffers();
    return &sortedByOutput;
}

OSStatus
CMBufferQueueEnqueue(CMBufferQueueRef queue, CMBufferRef buf)
{
    if (!queue || !buf)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    OSStatus e = noErr;
    if (q->inTrigger)
        e = kCMBufferQueueError_CannotModifyQueueFromTriggerCallback;
    else if (q->endOfData)
        e = kCMBufferQueueError_EnqueueAfterEndOfData;
    else if (q->capacity && CFArrayGetCount(q->buffers) >= q->capacity)
        e = kCMBufferQueueError_QueueIsFull;
    else if (q->validate && (e = q->validate(q, buf, q->validateRefcon)))
        ;
    else if (q->validateHandler && (e = q->validateHandler(q, buf)))
        ;
    if (!e) {
        CFIndex at = CFArrayGetCount(q->buffers);
        /* (sorted: after the last buffer that isn't later) */
        if (has_compare(q))
            while (at > 0 && compare(q, CFArrayGetValueAtIndex(q->buffers, at - 1), buf) == kCFCompareGreaterThan)
                at--;
        CFArrayInsertValueAtIndex(q->buffers, at, buf);
        if (at == 0)
            listen_ready(q);
        check_triggers(q, false);
    }
    pthread_mutex_unlock(&q->lock);
    return e;
}

static CMBufferRef
dequeue(CMBufferQueueRef queue, bool onlyReady)
{
    if (!queue)
        return NULL;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    CMBufferRef b = NULL;
    if (!q->inTrigger && CFArrayGetCount(q->buffers) > 0) {
        CMBufferRef head = CFArrayGetValueAtIndex(q->buffers, 0);
        if (!onlyReady || is_ready(q, head)) {
            b = CFRetain(head);
            CFArrayRemoveValueAtIndex(q->buffers, 0);
            listen_ready(q);
            check_triggers(q, false);
        }
    }
    pthread_mutex_unlock(&q->lock);
    return b;
}

CMBufferRef
CMBufferQueueDequeueAndRetain(CMBufferQueueRef queue)
{
    return dequeue(queue, false);
}

CMBufferRef
CMBufferQueueDequeueIfDataReadyAndRetain(CMBufferQueueRef queue)
{
    return dequeue(queue, true);
}

CMBufferRef
CMBufferQueueCopyHead(CMBufferQueueRef queue)
{
    if (!queue)
        return NULL;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    CMBufferRef b = CFArrayGetCount(q->buffers) ? CFRetain(CFArrayGetValueAtIndex(q->buffers, 0)) : NULL;
    pthread_mutex_unlock(&q->lock);
    return b;
}

CMBufferRef
CMBufferQueueGetHead(CMBufferQueueRef queue)
{
    CMBufferRef b = CMBufferQueueCopyHead(queue);
    if (b)
        CFRelease(b);
    return b;
}

Boolean
CMBufferQueueIsEmpty(CMBufferQueueRef queue)
{
    return !queue || CFArrayGetCount(queue->buffers) == 0;
}

OSStatus
CMBufferQueueMarkEndOfData(CMBufferQueueRef queue)
{
    if (!queue)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    q->endOfData = true;
    check_triggers(q, false);
    pthread_mutex_unlock(&q->lock);
    return noErr;
}

Boolean
CMBufferQueueContainsEndOfData(CMBufferQueueRef queue)
{
    return queue && queue->endOfData;
}

Boolean
CMBufferQueueIsAtEndOfData(CMBufferQueueRef queue)
{
    return queue && queue->endOfData && CFArrayGetCount(queue->buffers) == 0;
}

OSStatus
CMBufferQueueResetWithCallback(CMBufferQueueRef queue, void (*callback)(CMBufferRef buffer, void *refcon), void *refcon)
{
    if (!queue)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    if (q->inTrigger) {
        pthread_mutex_unlock(&q->lock);
        return kCMBufferQueueError_CannotModifyQueueFromTriggerCallback;
    }
    if (callback)
        for (CFIndex i = 0; i < CFArrayGetCount(q->buffers); i++)
            callback((CMBufferRef)CFArrayGetValueAtIndex(q->buffers, i), refcon);
    CFArrayRemoveAllValues(q->buffers);
    q->endOfData = false;
    listen_ready(q);
    check_triggers(q, true);
    pthread_mutex_unlock(&q->lock);
    return noErr;
}

static void
no_callback(CMBufferRef buffer, void *refcon)
{
}

OSStatus
CMBufferQueueReset(CMBufferQueueRef queue)
{
    return CMBufferQueueResetWithCallback(queue, no_callback, NULL);
}

CMItemCount
CMBufferQueueGetBufferCount(CMBufferQueueRef queue)
{
    return queue ? CFArrayGetCount(queue->buffers) : 0;
}

CMTime
CMBufferQueueGetDuration(CMBufferQueueRef queue)
{
    if (!queue)
        return kCMTimeInvalid;
    pthread_mutex_lock(&((BQ)queue)->lock);
    CMTime d = total_duration((BQ)queue);
    pthread_mutex_unlock(&((BQ)queue)->lock);
    return d;
}

size_t
CMBufferQueueGetTotalSize(CMBufferQueueRef queue)
{
    if (!queue)
        return 0;
    size_t total = 0;
    pthread_mutex_lock(&((BQ)queue)->lock);
    for (CFIndex i = 0; i < CFArrayGetCount(queue->buffers); i++)
        total += get_size((BQ)queue, CFArrayGetValueAtIndex(queue->buffers, i));
    pthread_mutex_unlock(&((BQ)queue)->lock);
    return total;
}

static CMTime
head_time(CMBufferQueueRef queue, int which)
{
    if (!queue)
        return kCMTimeInvalid;
    pthread_mutex_lock(&((BQ)queue)->lock);
    CMTime t = CFArrayGetCount(queue->buffers) ? get_time((BQ)queue, CFArrayGetValueAtIndex(queue->buffers, 0), which) : kCMTimeInvalid;
    pthread_mutex_unlock(&((BQ)queue)->lock);
    return t;
}

static CMTime
locked_extreme(CMBufferQueueRef queue, int which, bool greatest)
{
    if (!queue)
        return kCMTimeInvalid;
    pthread_mutex_lock(&((BQ)queue)->lock);
    CMTime t = extreme((BQ)queue, which, greatest);
    pthread_mutex_unlock(&((BQ)queue)->lock);
    return t;
}

CMTime
CMBufferQueueGetMinDecodeTimeStamp(CMBufferQueueRef queue)
{
    return locked_extreme(queue, DTS, false);
}

CMTime
CMBufferQueueGetFirstDecodeTimeStamp(CMBufferQueueRef queue)
{
    return head_time(queue, DTS);
}

CMTime
CMBufferQueueGetMinPresentationTimeStamp(CMBufferQueueRef queue)
{
    return locked_extreme(queue, PTS, false);
}

CMTime
CMBufferQueueGetFirstPresentationTimeStamp(CMBufferQueueRef queue)
{
    return head_time(queue, PTS);
}

CMTime
CMBufferQueueGetMaxPresentationTimeStamp(CMBufferQueueRef queue)
{
    return locked_extreme(queue, PTS, true);
}

CMTime
CMBufferQueueGetEndPresentationTimeStamp(CMBufferQueueRef queue)
{
    if (!queue)
        return kCMTimeInvalid;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    CMTime end = kCMTimeInvalid;
    for (CFIndex i = 0; i < CFArrayGetCount(q->buffers); i++) {
        CMBufferRef b = CFArrayGetValueAtIndex(q->buffers, i);
        CMTime p = get_time(q, b, PTS), d = get_time(q, b, DURATION);
        if (!CMTIME_IS_NUMERIC(p))
            continue;
        CMTime e = CMTIME_IS_NUMERIC(d) ? CMTimeAdd(p, d) : p;
        if (!CMTIME_IS_VALID(end) || CMTimeCompare(e, end) > 0)
            end = e;
    }
    pthread_mutex_unlock(&q->lock);
    return end;
}

OSStatus
CMBufferQueueCallForEachBuffer(CMBufferQueueRef queue, OSStatus (*callback)(CMBufferRef buffer, void *refcon), void *refcon)
{
    if (!queue || !callback)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    CFArrayRef copy = CFArrayCreateCopy(NULL, q->buffers);
    pthread_mutex_unlock(&q->lock);
    OSStatus e = noErr;
    for (CFIndex i = 0; i < CFArrayGetCount(copy) && !e; i++)
        e = callback((CMBufferRef)CFArrayGetValueAtIndex(copy, i), refcon);
    CFRelease(copy);
    return e;
}

OSStatus
CMBufferQueueSetValidationCallback(CMBufferQueueRef queue, CMBufferValidationCallback callback, void *refcon)
{
    if (!queue || !callback)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    q->validate = callback;
    q->validateRefcon = refcon;
    return noErr;
}

OSStatus
CMBufferQueueSetValidationHandler(CMBufferQueueRef queue, CMBufferValidationHandler handler)
{
    if (!queue || !handler)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    if (q->validateHandler)
        Block_release(q->validateHandler);
    q->validateHandler = Block_copy(handler);
    return noErr;
}

/* --- triggers --- */

static bool
time_condition(CMBufferQueueTriggerCondition c)
{
    return c == kCMBufferQueueTrigger_WhenDurationBecomesLessThan || c == kCMBufferQueueTrigger_WhenDurationBecomesLessThanOrEqualTo ||
           c == kCMBufferQueueTrigger_WhenDurationBecomesGreaterThan || c == kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualTo ||
           c == kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges || c == kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges ||
           c == kCMBufferQueueTrigger_WhenDataBecomesReady || c == kCMBufferQueueTrigger_WhenEndOfDataReached ||
           c == kCMBufferQueueTrigger_WhenReset;
}

static bool
count_condition(CMBufferQueueTriggerCondition c)
{
    return c == kCMBufferQueueTrigger_WhenBufferCountBecomesLessThan || c == kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan ||
           c == kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualToAndBufferCountBecomesGreaterThan;
}

static OSStatus
install(CMBufferQueueRef queue, CMBufferQueueTriggerCallback callback, void *refcon, CMBufferQueueTriggerHandler handler,
        CMBufferQueueTriggerCondition condition, CMTime time, CMItemCount count, bool byCount, CMBufferQueueTriggerToken *tokenOut)
{
    if (!queue || (!callback && !handler))
        return kCMBufferQueueError_RequiredParameterMissing;
    if (byCount ? !count_condition(condition) : !time_condition(condition))
        return kCMBufferQueueError_InvalidTriggerCondition;
    if (!byCount && condition <= kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualTo && !CMTIME_IS_NUMERIC(time))
        return kCMBufferQueueError_BadTriggerDuration;
    BQ q = (BQ)queue;
    Trigger *t = calloc(1, sizeof *t);
    if (!t)
        return kCMBufferQueueError_AllocationFailed;
    t->callback = callback;
    t->refcon = refcon;
    t->handler = handler ? Block_copy(handler) : NULL;
    t->condition = condition;
    t->time = time;
    t->count = count;
    pthread_mutex_lock(&q->lock);
    t->last = extreme(q, PTS, condition == kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges);
    Trigger **end = &q->triggers;
    while (*end)
        end = &(*end)->next;
    *end = t;
    if (tokenOut)
        *tokenOut = (CMBufferQueueTriggerToken)t;
    /* (one that already holds fires now) */
    if (condition != kCMBufferQueueTrigger_WhenReset && condition != kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges &&
        condition != kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges) {
        t->state = condition_holds(q, t);
        if (t->state)
            fire(q, t);
    }
    pthread_mutex_unlock(&q->lock);
    return noErr;
}

OSStatus
CMBufferQueueInstallTrigger(CMBufferQueueRef queue, CMBufferQueueTriggerCallback callback, void *refcon, CMBufferQueueTriggerCondition condition,
                            CMTime time, CMBufferQueueTriggerToken *triggerTokenOut)
{
    return install(queue, callback, refcon, NULL, condition, time, 0, false, triggerTokenOut);
}

OSStatus
CMBufferQueueInstallTriggerWithIntegerThreshold(CMBufferQueueRef queue, CMBufferQueueTriggerCallback callback, void *refcon,
                                                CMBufferQueueTriggerCondition condition, CMItemCount threshold,
                                                CMBufferQueueTriggerToken *triggerTokenOut)
{
    return install(queue, callback, refcon, NULL, condition, kCMTimeInvalid, threshold, true, triggerTokenOut);
}

OSStatus
CMBufferQueueInstallTriggerHandler(CMBufferQueueRef queue, CMBufferQueueTriggerCondition condition, CMTime time,
                                   CMBufferQueueTriggerToken *triggerTokenOut, CMBufferQueueTriggerHandler handler)
{
    return install(queue, NULL, NULL, handler, condition, time, 0, false, triggerTokenOut);
}

OSStatus
CMBufferQueueInstallTriggerHandlerWithIntegerThreshold(CMBufferQueueRef queue, CMBufferQueueTriggerCondition condition, CMItemCount threshold,
                                                       CMBufferQueueTriggerToken *triggerTokenOut, CMBufferQueueTriggerHandler handler)
{
    return install(queue, NULL, NULL, handler, condition, kCMTimeInvalid, threshold, true, triggerTokenOut);
}

OSStatus
CMBufferQueueRemoveTrigger(CMBufferQueueRef queue, CMBufferQueueTriggerToken triggerToken)
{
    if (!queue)
        return kCMBufferQueueError_RequiredParameterMissing;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    for (Trigger **p = &q->triggers; *p; p = &(*p)->next)
        if (*p == (Trigger *)triggerToken) {
            Trigger *t = *p;
            *p = t->next;
            pthread_mutex_unlock(&q->lock);
            if (t->handler)
                Block_release(t->handler);
            free(t);
            return noErr;
        }
    pthread_mutex_unlock(&q->lock);
    return kCMBufferQueueError_InvalidTriggerToken;
}

Boolean
CMBufferQueueTestTrigger(CMBufferQueueRef queue, CMBufferQueueTriggerToken triggerToken)
{
    if (!queue)
        return false;
    BQ q = (BQ)queue;
    pthread_mutex_lock(&q->lock);
    bool holds = false;
    for (Trigger *t = q->triggers; t; t = t->next)
        if (t == (Trigger *)triggerToken)
            holds = condition_holds(q, t);
    pthread_mutex_unlock(&q->lock);
    return holds;
}

/* (the head's data becoming ready, for the data-ready triggers) */
typedef struct OpaqueCMNotificationCenter *CMNotificationCenterRef;
extern CMNotificationCenterRef CMNotificationCenterGetDefaultLocalCenter(void);
extern OSStatus CMNotificationCenterAddListener(CMNotificationCenterRef, const void *, void (*)(CMNotificationCenterRef, const void *, CFStringRef,
                                                                                                 const void *, CFTypeRef),
                                                CFStringRef, const void *, UInt32);
extern OSStatus CMNotificationCenterRemoveListener(CMNotificationCenterRef, const void *,
                                                   void (*)(CMNotificationCenterRef, const void *, CFStringRef, const void *, CFTypeRef), CFStringRef,
                                                   const void *);

static void
head_became_ready(CMNotificationCenterRef center, const void *listener, CFStringRef name, const void *object, CFTypeRef payload)
{
    BQ q = (BQ)listener;
    pthread_mutex_lock(&q->lock);
    check_triggers(q, false);
    pthread_mutex_unlock(&q->lock);
}

static void
listen_ready(BQ q)
{
    CFStringRef name = q->useHandlers ? q->handlers.dataBecameReadyNotification : q->callbacks.dataBecameReadyNotification;
    if (!name)
        return;
    CMNotificationCenterRef c = CMNotificationCenterGetDefaultLocalCenter();
    /* (one listener per queue, on whichever buffer is at the head) */
    CMNotificationCenterRemoveListener(c, q, head_became_ready, name, NULL);
    if (CFArrayGetCount(q->buffers))
        CMNotificationCenterAddListener(c, q, head_became_ready, name, NULL, 0);
}

/* --- memory pools --- */

typedef struct Block {
    struct Block *next;
    size_t size;
    double freed;
} BlockHeader;

/* The pool's free blocks, shared by the pool and its allocator (which may outlive it). */
typedef struct {
    _Atomic int refs;
    pthread_mutex_t lock;
    BlockHeader *free;
    double ageOut;
    bool invalid;
} PoolState;

struct OpaqueCMMemoryPool {
    CFRuntimeBase base;
    PoolState *state;
    CFAllocatorRef allocator;
};

typedef struct OpaqueCMMemoryPool *Pool;

#define HEADER 32 /* (the block's header, before the memory handed out: room for alignment) */

static double
seconds_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void
age_out(PoolState *p, bool all)
{
    double now = seconds_now();
    for (BlockHeader **b = &p->free; *b;) {
        if (all || now - (*b)->freed > p->ageOut) {
            BlockHeader *gone = *b;
            *b = gone->next;
            free(gone);
        } else
            b = &(*b)->next;
    }
}

static void *
pool_allocate(CFIndex size, CFOptionFlags hint, void *info)
{
    PoolState *p = info;
    pthread_mutex_lock(&p->lock);
    age_out(p, false);
    BlockHeader *b = NULL;
    for (BlockHeader **at = &p->free; *at; at = &(*at)->next)
        if ((*at)->size == (size_t)size) {
            b = *at;
            *at = b->next;
            break;
        }
    pthread_mutex_unlock(&p->lock);
    if (!b) {
        b = malloc(HEADER + (size_t)size);
        if (!b)
            return NULL;
        b->size = (size_t)size;
    }
    return (char *)b + HEADER;
}

static void
pool_deallocate(void *ptr, void *info)
{
    PoolState *p = info;
    BlockHeader *b = (BlockHeader *)((char *)ptr - HEADER);
    pthread_mutex_lock(&p->lock);
    if (p->invalid) {
        pthread_mutex_unlock(&p->lock);
        free(b);
        return;
    }
    b->freed = seconds_now();
    b->next = p->free;
    p->free = b;
    age_out(p, false);
    pthread_mutex_unlock(&p->lock);
}

static void *
pool_reallocate(void *ptr, CFIndex newsize, CFOptionFlags hint, void *info)
{
    BlockHeader *b = (BlockHeader *)((char *)ptr - HEADER);
    BlockHeader *n = realloc(b, HEADER + (size_t)newsize);
    if (!n)
        return NULL;
    n->size = (size_t)newsize;
    return (char *)n + HEADER;
}

static const void *
state_retain(const void *info)
{
    atomic_fetch_add(&((PoolState *)info)->refs, 1);
    return info;
}

static void
state_release(const void *info)
{
    PoolState *p = (PoolState *)info;
    if (atomic_fetch_sub(&p->refs, 1) != 1)
        return;
    age_out(p, true);
    pthread_mutex_destroy(&p->lock);
    free(p);
}

static void
pool_finalize(CFTypeRef cf)
{
    Pool p = (Pool)cf;
    CMMemoryPoolInvalidate(p);
    CFRelease(p->allocator);
}

CM_DEFINE_TYPE(CMMemoryPoolGetTypeID, "CMMemoryPool", pool_finalize, NULL, NULL, NULL)

CMMemoryPoolRef
CMMemoryPoolCreate(CFDictionaryRef options)
{
    Pool p = (Pool)cm_create(NULL, CMMemoryPoolGetTypeID(), sizeof(struct OpaqueCMMemoryPool));
    PoolState *st = calloc(1, sizeof *st);
    pthread_mutex_init(&st->lock, NULL);
    st->ageOut = 0.5;
    CFTypeRef age = options ? CFDictionaryGetValue(options, kCMMemoryPoolOption_AgeOutPeriod) : NULL;
    if (age && CFGetTypeID(age) == CFNumberGetTypeID())
        CFNumberGetValue(age, kCFNumberDoubleType, &st->ageOut);
    CFAllocatorContext ctx = {0, st, state_retain, state_release, NULL, pool_allocate, pool_reallocate, pool_deallocate, NULL};
    p->allocator = CFAllocatorCreate(NULL, &ctx);
    p->state = st;
    return p;
}

CFAllocatorRef
CMMemoryPoolGetAllocator(CMMemoryPoolRef pool)
{
    return pool ? ((Pool)pool)->allocator : NULL;
}

void
CMMemoryPoolFlush(CMMemoryPoolRef pool)
{
    if (!pool)
        return;
    PoolState *p = ((Pool)pool)->state;
    pthread_mutex_lock(&p->lock);
    age_out(p, true);
    pthread_mutex_unlock(&p->lock);
}

void
CMMemoryPoolInvalidate(CMMemoryPoolRef pool)
{
    if (!pool)
        return;
    PoolState *p = ((Pool)pool)->state;
    pthread_mutex_lock(&p->lock);
    p->invalid = true;
    age_out(p, true);
    pthread_mutex_unlock(&p->lock);
}

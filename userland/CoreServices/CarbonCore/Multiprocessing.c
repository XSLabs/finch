/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Pthreads backing for the Carbon multiprocessing primitives Finch can host. */
#include "CarbonCore_Finch.h"
#include <errno.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <sched.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define MP_MAGIC 0x4d504643u
#define MP_STORAGE_LIMIT 1024
#define MP_STORAGE_FIRST 259

enum {
    kMPObjectTask = 1, kMPObjectQueue, kMPObjectSemaphore, kMPObjectCritical, kMPObjectEvent,
    kMPObjectTimer, kMPObjectNotification
};

struct mp_task_start_data;

struct mp_header {
    UInt32 magic;
    UInt32 kind;
    Boolean deleted;
    struct mp_header *next;
};

struct OpaqueMPTaskID {
    struct mp_header header;
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    Boolean hasThread;
    Boolean finished;
    OSStatus result;
    MPTaskWeight weight;
    OSType taskType;
    struct mp_task_start_data *startData;
};

struct mp_message {
    void *value[3];
    struct mp_message *next;
};

struct OpaqueMPQueueID {
    struct mp_header header;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    struct mp_message *head;
    struct mp_message *tail;
    ItemCount reserve;
};

struct OpaqueMPSemaphoreID {
    struct mp_header header;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    MPSemaphoreCount count;
    MPSemaphoreCount maximum;
};

struct OpaqueMPCriticalRegionID {
    struct mp_header header;
    pthread_mutex_t lock;
};

struct OpaqueMPEventID {
    struct mp_header header;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    MPEventFlags flags;
};

struct OpaqueMPTimerID {
    struct mp_header header;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pthread_t thread;
    Boolean armed;
    Boolean stop;
    Boolean preserveID;
    AbsoluteTime expiration;
    MPOpaqueID target;
    MPOpaqueIDClass targetKind;
    void *parameter[3];
};

struct OpaqueMPNotificationID {
    struct mp_header header;
    pthread_mutex_t lock;
    MPOpaqueID target;
    MPOpaqueIDClass targetKind;
    void *parameter[3];
};

static pthread_mutex_t mp_objects_lock = PTHREAD_MUTEX_INITIALIZER;
static struct mp_header *mp_objects;
static pthread_once_t mp_task_key_once = PTHREAD_ONCE_INIT;
static pthread_key_t mp_task_key;
static pthread_mutex_t mp_storage_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t mp_storage_keys[MP_STORAGE_LIMIT];
static Boolean mp_storage_used[MP_STORAGE_LIMIT];
struct mp_aligned_allocation {
    void *pointer;
    void *base;
    ByteCount size;
    struct mp_aligned_allocation *next;
};
static pthread_mutex_t mp_allocation_lock = PTHREAD_MUTEX_INITIALIZER;
static struct mp_aligned_allocation *mp_aligned_allocations;

struct mp_task_start_data {
    TaskProc entry;
    void *parameter;
    MPQueueID notifyQueue;
    void *terminationParameter1;
    void *terminationParameter2;
};

static OSStatus mp_run_task(struct OpaqueMPTaskID *task);
static OSStatus mp_notify_target(MPOpaqueID target, MPOpaqueIDClass kind,
                                 void *parameter1, void *parameter2, void *parameter3);

static void
mp_make_task_key(void)
{
    pthread_key_create(&mp_task_key, NULL);
}

static void
mp_register(struct mp_header *object, UInt32 kind)
{
    object->magic = MP_MAGIC;
    object->kind = kind;
    pthread_mutex_lock(&mp_objects_lock);
    object->next = mp_objects;
    mp_objects = object;
    pthread_mutex_unlock(&mp_objects_lock);
}

static struct mp_header *
mp_find(const void *pointer, UInt32 kind)
{
    struct mp_header *found = NULL;
    pthread_mutex_lock(&mp_objects_lock);
    for (struct mp_header *item = mp_objects; item; item = item->next) {
        if (item == pointer && item->magic == MP_MAGIC && item->kind == kind && !item->deleted) {
            found = item;
            break;
        }
    }
    pthread_mutex_unlock(&mp_objects_lock);
    return found;
}

static OSStatus
mp_mark_deleted(struct mp_header *object)
{
    if (!object) return kMPInvalidIDErr;
    pthread_mutex_lock(&mp_objects_lock);
    if (object->deleted) {
        pthread_mutex_unlock(&mp_objects_lock);
        return kMPInvalidIDErr;
    }
    object->deleted = true;
    pthread_mutex_unlock(&mp_objects_lock);
    return noErr;
}

static int
mp_deadline(Duration timeout, struct timespec *deadline)
{
    if (timeout == kDurationImmediate) return 0;
    if (timeout == kDurationForever) return 1;
    if (clock_gettime(CLOCK_REALTIME, deadline) != 0) return -1;
    int64_t ns = timeout < 0 ? -(int64_t)timeout * 1000 : (int64_t)timeout * 1000000;
    deadline->tv_sec += (time_t)(ns / 1000000000);
    deadline->tv_nsec += (long)(ns % 1000000000);
    if (deadline->tv_nsec >= 1000000000) {
        deadline->tv_sec++;
        deadline->tv_nsec -= 1000000000;
    }
    return 2;
}

ItemCount
MPProcessors(void)
{
    int count = 1;
    size_t size = sizeof count;
    if (sysctlbyname("hw.ncpu", &count, &size, NULL, 0) != 0 || count < 1) count = 1;
    return (ItemCount)count;
}

ItemCount
MPProcessorsScheduled(void)
{
    int count = 1;
    size_t size = sizeof count;
    if (sysctlbyname("hw.activecpu", &count, &size, NULL, 0) != 0 || count < 1) count = 1;
    return (ItemCount)count;
}

void
MPYield(void)
{
    sched_yield();
}

MPTaskID
MPCurrentTaskID(void)
{
    pthread_once(&mp_task_key_once, mp_make_task_key);
    struct OpaqueMPTaskID *task = pthread_getspecific(mp_task_key);
    if (!task) {
        task = calloc(1, sizeof *task);
        if (!task) return NULL;
        pthread_mutex_init(&task->lock, NULL);
        pthread_cond_init(&task->changed, NULL);
        task->thread = pthread_self();
        task->hasThread = true;
        task->weight = 100;
        mp_register(&task->header, kMPObjectTask);
        pthread_setspecific(mp_task_key, task);
    }
    return task;
}

OSStatus
MPSetTaskWeight(MPTaskID taskID, MPTaskWeight weight)
{
    struct OpaqueMPTaskID *task = (struct OpaqueMPTaskID *)mp_find(taskID, kMPObjectTask);
    if (!task)
        return kMPInvalidIDErr;
    pthread_mutex_lock(&task->lock);
    task->weight = weight;
    pthread_mutex_unlock(&task->lock);
    return noErr;
}

OSStatus
MPSetTaskType(MPTaskID taskID, OSType taskType)
{
    struct OpaqueMPTaskID *task = (struct OpaqueMPTaskID *)mp_find(taskID, kMPObjectTask);
    if (!task)
        return kMPInvalidIDErr;
    pthread_mutex_lock(&task->lock);
    task->taskType = taskType;
    pthread_mutex_unlock(&task->lock);
    return noErr;
}

OSStatus
MPDelayUntil(AbsoluteTime *expirationTime)
{
    if (!expirationTime)
        return paramErr;
    AbsoluteTime now = UpTime();
    UInt64 expiration = ((UInt64)expirationTime->hi << 32) | expirationTime->lo;
    UInt64 current = ((UInt64)now.hi << 32) | now.lo;
    if (expiration <= current)
        return noErr;
    Nanoseconds wait = AbsoluteDeltaToNanoseconds(*expirationTime, now);
    UInt64 nanoseconds = ((UInt64)wait.hi << 32) | wait.lo;
    struct timespec requested = {(time_t)(nanoseconds / 1000000000ULL), (long)(nanoseconds % 1000000000ULL)};
    while (nanosleep(&requested, &requested) != 0 && errno == EINTR)
        ;
    return noErr;
}

static MPOpaqueIDClass
mp_kind_for_object(MPOpaqueID object)
{
    if (mp_find(object, kMPObjectQueue)) return kOpaqueQueueID;
    if (mp_find(object, kMPObjectSemaphore)) return kOpaqueSemaphoreID;
    if (mp_find(object, kMPObjectCritical)) return kOpaqueCriticalRegionID;
    if (mp_find(object, kMPObjectEvent)) return kOpaqueEventID;
    if (mp_find(object, kMPObjectTimer)) return kOpaqueTimerID;
    if (mp_find(object, kMPObjectTask)) return kOpaqueTaskID;
    return kOpaqueAnyID;
}

static OSStatus
mp_notify_target(MPOpaqueID target, MPOpaqueIDClass kind, void *parameter1, void *parameter2, void *parameter3)
{
    if (kind == kOpaqueAnyID)
        kind = mp_kind_for_object(target);
    switch (kind) {
    case kOpaqueQueueID:
        return MPNotifyQueue((MPQueueID)target, parameter1, parameter2, parameter3);
    case kOpaqueEventID:
        return MPSetEvent((MPEventID)target, (MPEventFlags)(uintptr_t)parameter1);
    case kOpaqueSemaphoreID:
        return MPSignalSemaphore((MPSemaphoreID)target);
    default:
        return kMPInvalidIDErr;
    }
}

static void *
mp_timer_thread(void *context)
{
    struct OpaqueMPTimerID *timer = context;
    pthread_mutex_lock(&timer->lock);
    while (!timer->stop) {
        while (!timer->armed && !timer->stop)
            pthread_cond_wait(&timer->changed, &timer->lock);
        if (timer->stop)
            break;

        AbsoluteTime now = UpTime();
        UInt64 deadline = ((UInt64)timer->expiration.hi << 32) | timer->expiration.lo;
        UInt64 current = ((UInt64)now.hi << 32) | now.lo;
        if (deadline <= current) {
            MPOpaqueID target = timer->target;
            MPOpaqueIDClass kind = timer->targetKind;
            void *p1 = timer->parameter[0], *p2 = timer->parameter[1], *p3 = timer->parameter[2];
            Boolean retire = !timer->preserveID;
            timer->armed = false;
            if (retire) timer->stop = true;
            pthread_mutex_unlock(&timer->lock);
            if (target)
                mp_notify_target(target, kind, p1, p2, p3);
            if (retire)
                mp_mark_deleted(&timer->header);
            pthread_mutex_lock(&timer->lock);
            continue;
        }

        Nanoseconds wait = AbsoluteDeltaToNanoseconds(timer->expiration, now);
        UInt64 nanoseconds = ((UInt64)wait.hi << 32) | wait.lo;
        struct timespec wake;
        clock_gettime(CLOCK_REALTIME, &wake);
        wake.tv_sec += (time_t)(nanoseconds / 1000000000ULL);
        wake.tv_nsec += (long)(nanoseconds % 1000000000ULL);
        if (wake.tv_nsec >= 1000000000L) {
            wake.tv_sec++;
            wake.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&timer->changed, &timer->lock, &wake);
    }
    pthread_mutex_unlock(&timer->lock);
    return NULL;
}

OSStatus
MPCreateNotification(MPNotificationID *notificationID)
{
    if (!notificationID) return paramErr;
    *notificationID = NULL;
    struct OpaqueMPNotificationID *notification = calloc(1, sizeof *notification);
    if (!notification) return memFullErr;
    pthread_mutex_init(&notification->lock, NULL);
    mp_register(&notification->header, kMPObjectNotification);
    *notificationID = notification;
    return noErr;
}

OSStatus
MPDeleteNotification(MPNotificationID notificationID)
{
    struct OpaqueMPNotificationID *notification =
        (struct OpaqueMPNotificationID *)mp_find(notificationID, kMPObjectNotification);
    return mp_mark_deleted(notification ? &notification->header : NULL);
}

OSStatus
MPModifyNotification(MPNotificationID notificationID, MPOpaqueID anID,
                     void *notifyParam1, void *notifyParam2, void *notifyParam3)
{
    struct OpaqueMPNotificationID *notification =
        (struct OpaqueMPNotificationID *)mp_find(notificationID, kMPObjectNotification);
    MPOpaqueIDClass kind = mp_kind_for_object(anID);
    if (!notification || kind == kOpaqueAnyID) return kMPInvalidIDErr;
    pthread_mutex_lock(&notification->lock);
    notification->target = anID;
    notification->targetKind = kind;
    notification->parameter[0] = notifyParam1;
    notification->parameter[1] = notifyParam2;
    notification->parameter[2] = notifyParam3;
    pthread_mutex_unlock(&notification->lock);
    return noErr;
}

OSStatus
MPModifyNotificationParameters(MPNotificationID notificationID, MPOpaqueIDClass kind,
                               void *notifyParam1, void *notifyParam2, void *notifyParam3)
{
    struct OpaqueMPNotificationID *notification =
        (struct OpaqueMPNotificationID *)mp_find(notificationID, kMPObjectNotification);
    if (!notification || kind < kOpaqueQueueID || kind > kOpaqueNotificationID)
        return kMPInvalidIDErr;
    pthread_mutex_lock(&notification->lock);
    if (notification->target && mp_kind_for_object(notification->target) != kind) {
        pthread_mutex_unlock(&notification->lock);
        return kMPInvalidIDErr;
    }
    notification->targetKind = kind;
    notification->parameter[0] = notifyParam1;
    notification->parameter[1] = notifyParam2;
    notification->parameter[2] = notifyParam3;
    pthread_mutex_unlock(&notification->lock);
    return noErr;
}

OSStatus
MPCauseNotification(MPNotificationID notificationID)
{
    struct OpaqueMPNotificationID *notification =
        (struct OpaqueMPNotificationID *)mp_find(notificationID, kMPObjectNotification);
    if (!notification) return kMPInvalidIDErr;
    pthread_mutex_lock(&notification->lock);
    MPOpaqueID target = notification->target;
    MPOpaqueIDClass kind = notification->targetKind;
    void *p1 = notification->parameter[0], *p2 = notification->parameter[1], *p3 = notification->parameter[2];
    pthread_mutex_unlock(&notification->lock);
    if (!target) return kMPInvalidIDErr;
    return mp_notify_target(target, kind, p1, p2, p3);
}

OSStatus
MPCreateTimer(MPTimerID *timerID)
{
    if (!timerID) return paramErr;
    *timerID = NULL;
    struct OpaqueMPTimerID *timer = calloc(1, sizeof *timer);
    if (!timer) return memFullErr;
    pthread_mutex_init(&timer->lock, NULL);
    pthread_cond_init(&timer->changed, NULL);
    mp_register(&timer->header, kMPObjectTimer);
    int error = pthread_create(&timer->thread, NULL, mp_timer_thread, timer);
    if (error) {
        timer->header.deleted = true;
        return error == EAGAIN ? kMPInsufficientResourcesErr : paramErr;
    }
    pthread_detach(timer->thread);
    *timerID = timer;
    return noErr;
}

OSStatus
MPDeleteTimer(MPTimerID timerID)
{
    struct OpaqueMPTimerID *timer = (struct OpaqueMPTimerID *)mp_find(timerID, kMPObjectTimer);
    if (!timer) return kMPInvalidIDErr;
    OSStatus status = mp_mark_deleted(&timer->header);
    pthread_mutex_lock(&timer->lock);
    timer->stop = true;
    timer->armed = false;
    pthread_cond_signal(&timer->changed);
    pthread_mutex_unlock(&timer->lock);
    return status;
}

OSStatus
MPSetTimerNotify(MPTimerID timerID, MPOpaqueID anID,
                 void *notifyParam1, void *notifyParam2, void *notifyParam3)
{
    struct OpaqueMPTimerID *timer = (struct OpaqueMPTimerID *)mp_find(timerID, kMPObjectTimer);
    MPOpaqueIDClass kind = mp_kind_for_object(anID);
    if (!timer || kind == kOpaqueAnyID) return kMPInvalidIDErr;
    pthread_mutex_lock(&timer->lock);
    timer->target = anID;
    timer->targetKind = kind;
    timer->parameter[0] = notifyParam1;
    timer->parameter[1] = notifyParam2;
    timer->parameter[2] = notifyParam3;
    pthread_mutex_unlock(&timer->lock);
    return noErr;
}

OSStatus
MPArmTimer(MPTimerID timerID, AbsoluteTime *expirationTime, OptionBits options)
{
    struct OpaqueMPTimerID *timer = (struct OpaqueMPTimerID *)mp_find(timerID, kMPObjectTimer);
    if (!timer) return kMPInvalidIDErr;
    if (!expirationTime || (options & ~(kMPPreserveTimerIDMask | kMPTimeIsDeltaMask | kMPTimeIsDurationMask)) ||
        ((options & kMPTimeIsDeltaMask) && (options & kMPTimeIsDurationMask))) return paramErr;
    AbsoluteTime expiration = *expirationTime;
    if (options & kMPTimeIsDurationMask) {
        UInt64 raw = ((UInt64)expiration.hi << 32) | expiration.lo;
        expiration = AddAbsoluteToAbsolute(DurationToAbsolute((Duration)(SInt32)raw), UpTime());
    } else if (options & kMPTimeIsDeltaMask) {
        expiration = AddAbsoluteToAbsolute(expiration, UpTime());
    }
    pthread_mutex_lock(&timer->lock);
    if (timer->stop || timer->header.deleted) {
        pthread_mutex_unlock(&timer->lock);
        return kMPDeletedErr;
    }
    timer->expiration = expiration;
    timer->armed = true;
    timer->preserveID = (options & kMPPreserveTimerIDMask) != 0;
    pthread_cond_signal(&timer->changed);
    pthread_mutex_unlock(&timer->lock);
    return noErr;
}

OSStatus
MPCancelTimer(MPTimerID timerID, AbsoluteTime *timeRemaining)
{
    struct OpaqueMPTimerID *timer = (struct OpaqueMPTimerID *)mp_find(timerID, kMPObjectTimer);
    if (!timer) return kMPInvalidIDErr;
    pthread_mutex_lock(&timer->lock);
    if (timeRemaining) {
        AbsoluteTime now = UpTime();
        UInt64 expiration = ((UInt64)timer->expiration.hi << 32) | timer->expiration.lo;
        UInt64 current = ((UInt64)now.hi << 32) | now.lo;
        *timeRemaining = expiration > current ? SubAbsoluteFromAbsolute(timer->expiration, now) : (AbsoluteTime){0, 0};
    }
    timer->armed = false;
    pthread_cond_signal(&timer->changed);
    pthread_mutex_unlock(&timer->lock);
    return noErr;
}

/* macOS stopped providing task exception and debugger services. */
OSStatus
MPSetExceptionHandler(MPTaskID task, MPQueueID exceptionQueue)
{
    (void)task;
    (void)exceptionQueue;
    return kMPInvalidIDErr;
}

OSStatus
MPDisposeTaskException(MPTaskID task, OptionBits action)
{
    (void)task;
    (void)action;
    return kMPInvalidIDErr;
}

OSStatus
MPExtractTaskState(MPTaskID task, MPTaskStateKind kind, void *info)
{
    (void)task;
    (void)kind;
    (void)info;
    return kMPInvalidIDErr;
}

OSStatus
MPSetTaskState(MPTaskID task, MPTaskStateKind kind, void *info)
{
    (void)task;
    (void)kind;
    (void)info;
    return kMPInvalidIDErr;
}

OSStatus
MPThrowException(MPTaskID task, MPExceptionKind kind)
{
    (void)task;
    (void)kind;
    return kMPInvalidIDErr;
}

OSStatus
MPRegisterDebugger(MPQueueID queue, MPDebuggerLevel level)
{
    (void)queue;
    (void)level;
    return kMPInvalidIDErr;
}

OSStatus
MPUnregisterDebugger(MPQueueID queue)
{
    (void)queue;
    return kMPInvalidIDErr;
}

static void *
mp_task_start(void *context)
{
    struct OpaqueMPTaskID *task = context;
    pthread_once(&mp_task_key_once, mp_make_task_key);
    pthread_setspecific(mp_task_key, task);
    /* The entry point and arguments are kept in the small wrapper below. */
    return (void *)(intptr_t)mp_run_task(task);
}

static OSStatus
mp_run_task(struct OpaqueMPTaskID *task)
{
    struct mp_task_start_data *startData = task->startData;
    task->startData = NULL;
    struct mp_task_start_data data = startData ? *startData : (struct mp_task_start_data){0};
    free(startData);
    OSStatus result = data.entry ? data.entry(data.parameter) : paramErr;
    pthread_mutex_lock(&task->lock);
    task->result = result;
    task->finished = true;
    pthread_cond_broadcast(&task->changed);
    pthread_mutex_unlock(&task->lock);
    if (data.notifyQueue)
        MPNotifyQueue(data.notifyQueue, data.terminationParameter1, data.terminationParameter2,
                      (void *)(intptr_t)result);
    return result;
}

OSStatus
MPCreateTask(TaskProc entryPoint, void *parameter, ByteCount stackSize, MPQueueID notifyQueue,
             void *terminationParameter1, void *terminationParameter2, MPTaskOptions options, MPTaskID *taskOut)
{
    if (!entryPoint || !taskOut || (options & ~kMPCreateTaskValidOptionsMask) ||
        (options & kMPCreateTaskSuspendedMask)) return paramErr;
    *taskOut = NULL;
    struct OpaqueMPTaskID *task = calloc(1, sizeof *task);
    struct mp_task_start_data *data = calloc(1, sizeof *data);
    if (!task || !data) {
        free(task);
        free(data);
        return memFullErr;
    }
    data->entry = entryPoint;
    data->parameter = parameter;
    data->notifyQueue = notifyQueue;
    data->terminationParameter1 = terminationParameter1;
    data->terminationParameter2 = terminationParameter2;
    task->startData = data;
    pthread_mutex_init(&task->lock, NULL);
    pthread_cond_init(&task->changed, NULL);
    task->weight = 100;
    mp_register(&task->header, kMPObjectTask);
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    if (stackSize >= PTHREAD_STACK_MIN) pthread_attr_setstacksize(&attributes, stackSize);
    int error = pthread_create(&task->thread, &attributes, mp_task_start, task);
    pthread_attr_destroy(&attributes);
    if (error) {
        free(data);
        task->startData = NULL;
        task->header.deleted = true;
        return error == EAGAIN ? kMPInsufficientResourcesErr : paramErr;
    }
    task->hasThread = true;
    pthread_detach(task->thread);
    *taskOut = task;
    return noErr;
}

OSStatus
MPTerminateTask(MPTaskID taskID, OSStatus terminationStatus)
{
    struct OpaqueMPTaskID *task = (struct OpaqueMPTaskID *)mp_find(taskID, kMPObjectTask);
    if (!task) return kMPInvalidIDErr;
    if (pthread_equal(task->thread, pthread_self())) MPExit(terminationStatus);
    int error = pthread_cancel(task->thread);
    return error == 0 || error == ESRCH ? noErr : paramErr;
}

Boolean
MPTaskIsPreemptive(MPTaskID taskID)
{
    return mp_find(taskID, kMPObjectTask) != NULL;
}

void
MPExit(OSStatus status)
{
    struct OpaqueMPTaskID *task = MPCurrentTaskID();
    if (task) {
        pthread_mutex_lock(&task->lock);
        task->result = status;
        task->finished = true;
        pthread_cond_broadcast(&task->changed);
        pthread_mutex_unlock(&task->lock);
    }
    pthread_exit((void *)(intptr_t)status);
}

static Boolean
mp_valid_storage(TaskStorageIndex index)
{
    return index >= MP_STORAGE_FIRST && index - MP_STORAGE_FIRST < MP_STORAGE_LIMIT &&
           mp_storage_used[index - MP_STORAGE_FIRST];
}

OSStatus
MPAllocateTaskStorageIndex(TaskStorageIndex *taskIndex)
{
    if (!taskIndex) return paramErr;
    pthread_mutex_lock(&mp_storage_lock);
    for (TaskStorageIndex slot = 0; slot < MP_STORAGE_LIMIT; slot++) {
        if (mp_storage_used[slot]) continue;
        if (pthread_key_create(&mp_storage_keys[slot], NULL) != 0) break;
        mp_storage_used[slot] = true;
        *taskIndex = slot + MP_STORAGE_FIRST;
        pthread_mutex_unlock(&mp_storage_lock);
        return noErr;
    }
    pthread_mutex_unlock(&mp_storage_lock);
    return kMPInsufficientResourcesErr;
}

OSStatus
MPDeallocateTaskStorageIndex(TaskStorageIndex taskIndex)
{
    pthread_mutex_lock(&mp_storage_lock);
    if (!mp_valid_storage(taskIndex)) {
        pthread_mutex_unlock(&mp_storage_lock);
        return paramErr;
    }
    TaskStorageIndex slot = taskIndex - MP_STORAGE_FIRST;
    pthread_key_delete(mp_storage_keys[slot]);
    mp_storage_used[slot] = false;
    pthread_mutex_unlock(&mp_storage_lock);
    return noErr;
}

OSStatus
MPSetTaskStorageValue(TaskStorageIndex taskIndex, TaskStorageValue value)
{
    pthread_mutex_lock(&mp_storage_lock);
    Boolean valid = mp_valid_storage(taskIndex);
    TaskStorageIndex slot = taskIndex >= MP_STORAGE_FIRST ? taskIndex - MP_STORAGE_FIRST : MP_STORAGE_LIMIT;
    int error = valid ? pthread_setspecific(mp_storage_keys[slot], value) : EINVAL;
    pthread_mutex_unlock(&mp_storage_lock);
    return error == 0 ? noErr : paramErr;
}

TaskStorageValue
MPGetTaskStorageValue(TaskStorageIndex taskIndex)
{
    pthread_mutex_lock(&mp_storage_lock);
    TaskStorageIndex slot = taskIndex >= MP_STORAGE_FIRST ? taskIndex - MP_STORAGE_FIRST : MP_STORAGE_LIMIT;
    TaskStorageValue value = mp_valid_storage(taskIndex) ? pthread_getspecific(mp_storage_keys[slot]) : NULL;
    pthread_mutex_unlock(&mp_storage_lock);
    return value;
}

OSStatus
MPCreateQueue(MPQueueID *queueOut)
{
    if (!queueOut) return paramErr;
    *queueOut = NULL;
    struct OpaqueMPQueueID *queue = calloc(1, sizeof *queue);
    if (!queue) return memFullErr;
    pthread_mutex_init(&queue->lock, NULL);
    pthread_cond_init(&queue->changed, NULL);
    mp_register(&queue->header, kMPObjectQueue);
    *queueOut = queue;
    return noErr;
}

OSStatus
MPDeleteQueue(MPQueueID queueID)
{
    struct OpaqueMPQueueID *queue = (struct OpaqueMPQueueID *)mp_find(queueID, kMPObjectQueue);
    if (!queue) return kMPInvalidIDErr;
    OSStatus error = mp_mark_deleted(&queue->header);
    pthread_mutex_lock(&queue->lock);
    pthread_cond_broadcast(&queue->changed);
    struct mp_message *message = queue->head;
    queue->head = queue->tail = NULL;
    pthread_mutex_unlock(&queue->lock);
    while (message) {
        struct mp_message *next = message->next;
        free(message);
        message = next;
    }
    return error;
}

OSStatus
MPNotifyQueue(MPQueueID queueID, void *param1, void *param2, void *param3)
{
    struct OpaqueMPQueueID *queue = (struct OpaqueMPQueueID *)mp_find(queueID, kMPObjectQueue);
    if (!queue) return kMPInvalidIDErr;
    struct mp_message *message = calloc(1, sizeof *message);
    if (!message) return memFullErr;
    message->value[0] = param1;
    message->value[1] = param2;
    message->value[2] = param3;
    pthread_mutex_lock(&queue->lock);
    if (queue->header.deleted) {
        pthread_mutex_unlock(&queue->lock);
        free(message);
        return kMPDeletedErr;
    }
    if (queue->tail) queue->tail->next = message;
    else queue->head = message;
    queue->tail = message;
    pthread_cond_signal(&queue->changed);
    pthread_mutex_unlock(&queue->lock);
    return noErr;
}

OSStatus
MPWaitOnQueue(MPQueueID queueID, void **param1, void **param2, void **param3, Duration timeout)
{
    struct OpaqueMPQueueID *queue = (struct OpaqueMPQueueID *)mp_find(queueID, kMPObjectQueue);
    if (!queue) return kMPInvalidIDErr;
    struct timespec deadline;
    int waitKind = mp_deadline(timeout, &deadline);
    pthread_mutex_lock(&queue->lock);
    while (!queue->head && !queue->header.deleted) {
        if (waitKind == 0) {
            pthread_mutex_unlock(&queue->lock);
            return kMPTimeoutErr;
        }
        int error = waitKind == 1 ? pthread_cond_wait(&queue->changed, &queue->lock)
                                  : pthread_cond_timedwait(&queue->changed, &queue->lock, &deadline);
        if (error == ETIMEDOUT) {
            pthread_mutex_unlock(&queue->lock);
            return kMPTimeoutErr;
        }
        if (error) {
            pthread_mutex_unlock(&queue->lock);
            return paramErr;
        }
    }
    if (queue->header.deleted) {
        pthread_mutex_unlock(&queue->lock);
        return kMPDeletedErr;
    }
    struct mp_message *message = queue->head;
    queue->head = message->next;
    if (!queue->head) queue->tail = NULL;
    pthread_mutex_unlock(&queue->lock);
    if (param1) *param1 = message->value[0];
    if (param2) *param2 = message->value[1];
    if (param3) *param3 = message->value[2];
    free(message);
    return noErr;
}

OSStatus
MPSetQueueReserve(MPQueueID queueID, ItemCount count)
{
    struct OpaqueMPQueueID *queue = (struct OpaqueMPQueueID *)mp_find(queueID, kMPObjectQueue);
    if (!queue) return kMPInvalidIDErr;
    queue->reserve = count;
    return noErr;
}

OSStatus
MPCreateSemaphore(MPSemaphoreCount maximumValue, MPSemaphoreCount initialValue, MPSemaphoreID *out)
{
    if (!out || !maximumValue || initialValue > maximumValue) return paramErr;
    *out = NULL;
    struct OpaqueMPSemaphoreID *semaphore = calloc(1, sizeof *semaphore);
    if (!semaphore) return memFullErr;
    semaphore->count = initialValue;
    semaphore->maximum = maximumValue;
    pthread_mutex_init(&semaphore->lock, NULL);
    pthread_cond_init(&semaphore->changed, NULL);
    mp_register(&semaphore->header, kMPObjectSemaphore);
    *out = semaphore;
    return noErr;
}

OSStatus
MPDeleteSemaphore(MPSemaphoreID semaphoreID)
{
    struct OpaqueMPSemaphoreID *semaphore = (struct OpaqueMPSemaphoreID *)mp_find(semaphoreID, kMPObjectSemaphore);
    if (!semaphore) return kMPInvalidIDErr;
    OSStatus error = mp_mark_deleted(&semaphore->header);
    pthread_mutex_lock(&semaphore->lock);
    pthread_cond_broadcast(&semaphore->changed);
    pthread_mutex_unlock(&semaphore->lock);
    return error;
}

OSStatus
MPSignalSemaphore(MPSemaphoreID semaphoreID)
{
    struct OpaqueMPSemaphoreID *semaphore = (struct OpaqueMPSemaphoreID *)mp_find(semaphoreID, kMPObjectSemaphore);
    if (!semaphore) return kMPInvalidIDErr;
    pthread_mutex_lock(&semaphore->lock);
    if (semaphore->header.deleted) {
        pthread_mutex_unlock(&semaphore->lock);
        return kMPDeletedErr;
    }
    if (semaphore->count == semaphore->maximum) {
        pthread_mutex_unlock(&semaphore->lock);
        return kMPInsufficientResourcesErr;
    }
    semaphore->count++;
    pthread_cond_signal(&semaphore->changed);
    pthread_mutex_unlock(&semaphore->lock);
    return noErr;
}

OSStatus
MPWaitOnSemaphore(MPSemaphoreID semaphoreID, Duration timeout)
{
    struct OpaqueMPSemaphoreID *semaphore = (struct OpaqueMPSemaphoreID *)mp_find(semaphoreID, kMPObjectSemaphore);
    if (!semaphore) return kMPInvalidIDErr;
    struct timespec deadline;
    int waitKind = mp_deadline(timeout, &deadline);
    pthread_mutex_lock(&semaphore->lock);
    while (!semaphore->count && !semaphore->header.deleted) {
        if (waitKind == 0) {
            pthread_mutex_unlock(&semaphore->lock);
            return kMPTimeoutErr;
        }
        int error = waitKind == 1 ? pthread_cond_wait(&semaphore->changed, &semaphore->lock)
                                  : pthread_cond_timedwait(&semaphore->changed, &semaphore->lock, &deadline);
        if (error == ETIMEDOUT) {
            pthread_mutex_unlock(&semaphore->lock);
            return kMPTimeoutErr;
        }
        if (error) {
            pthread_mutex_unlock(&semaphore->lock);
            return paramErr;
        }
    }
    if (semaphore->header.deleted) {
        pthread_mutex_unlock(&semaphore->lock);
        return kMPDeletedErr;
    }
    semaphore->count--;
    pthread_mutex_unlock(&semaphore->lock);
    return noErr;
}

OSStatus
MPCreateCriticalRegion(MPCriticalRegionID *out)
{
    if (!out) return paramErr;
    *out = NULL;
    struct OpaqueMPCriticalRegionID *region = calloc(1, sizeof *region);
    if (!region) return memFullErr;
    pthread_mutex_init(&region->lock, NULL);
    mp_register(&region->header, kMPObjectCritical);
    *out = region;
    return noErr;
}

OSStatus
MPDeleteCriticalRegion(MPCriticalRegionID regionID)
{
    struct OpaqueMPCriticalRegionID *region = (struct OpaqueMPCriticalRegionID *)mp_find(regionID, kMPObjectCritical);
    return mp_mark_deleted(region ? &region->header : NULL);
}

OSStatus
MPEnterCriticalRegion(MPCriticalRegionID regionID, Duration timeout)
{
    struct OpaqueMPCriticalRegionID *region = (struct OpaqueMPCriticalRegionID *)mp_find(regionID, kMPObjectCritical);
    if (!region) return kMPInvalidIDErr;
    struct timespec deadline;
    int waitKind = mp_deadline(timeout, &deadline);
    int error = waitKind == 0 ? pthread_mutex_trylock(&region->lock)
                : waitKind == 1 ? pthread_mutex_lock(&region->lock)
                                : pthread_mutex_trylock(&region->lock);
    while (waitKind == 2 && error == EBUSY) {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > deadline.tv_sec ||
            (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec))
            break;
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
        error = pthread_mutex_trylock(&region->lock);
    }
    if (error == 0) return noErr;
    return error == ETIMEDOUT || error == EBUSY ? kMPTimeoutErr : paramErr;
}

OSStatus
MPExitCriticalRegion(MPCriticalRegionID regionID)
{
    struct OpaqueMPCriticalRegionID *region = (struct OpaqueMPCriticalRegionID *)mp_find(regionID, kMPObjectCritical);
    if (!region) return kMPInvalidIDErr;
    return pthread_mutex_unlock(&region->lock) == 0 ? noErr : paramErr;
}

OSStatus
MPCreateEvent(MPEventID *out)
{
    if (!out) return paramErr;
    *out = NULL;
    struct OpaqueMPEventID *event = calloc(1, sizeof *event);
    if (!event) return memFullErr;
    pthread_mutex_init(&event->lock, NULL);
    pthread_cond_init(&event->changed, NULL);
    mp_register(&event->header, kMPObjectEvent);
    *out = event;
    return noErr;
}

OSStatus
MPDeleteEvent(MPEventID eventID)
{
    struct OpaqueMPEventID *event = (struct OpaqueMPEventID *)mp_find(eventID, kMPObjectEvent);
    if (!event) return kMPInvalidIDErr;
    OSStatus error = mp_mark_deleted(&event->header);
    pthread_mutex_lock(&event->lock);
    pthread_cond_broadcast(&event->changed);
    pthread_mutex_unlock(&event->lock);
    return error;
}

OSStatus
MPSetEvent(MPEventID eventID, MPEventFlags flags)
{
    struct OpaqueMPEventID *event = (struct OpaqueMPEventID *)mp_find(eventID, kMPObjectEvent);
    if (!event) return kMPInvalidIDErr;
    pthread_mutex_lock(&event->lock);
    if (event->header.deleted) {
        pthread_mutex_unlock(&event->lock);
        return kMPDeletedErr;
    }
    event->flags |= flags;
    pthread_cond_broadcast(&event->changed);
    pthread_mutex_unlock(&event->lock);
    return noErr;
}

OSStatus
MPWaitForEvent(MPEventID eventID, MPEventFlags *flags, Duration timeout)
{
    struct OpaqueMPEventID *event = (struct OpaqueMPEventID *)mp_find(eventID, kMPObjectEvent);
    if (!event || !flags) return event ? paramErr : kMPInvalidIDErr;
    struct timespec deadline;
    int waitKind = mp_deadline(timeout, &deadline);
    pthread_mutex_lock(&event->lock);
    while (!event->flags && !event->header.deleted) {
        if (waitKind == 0) {
            pthread_mutex_unlock(&event->lock);
            return kMPTimeoutErr;
        }
        int error = waitKind == 1 ? pthread_cond_wait(&event->changed, &event->lock)
                                  : pthread_cond_timedwait(&event->changed, &event->lock, &deadline);
        if (error == ETIMEDOUT) {
            pthread_mutex_unlock(&event->lock);
            return kMPTimeoutErr;
        }
        if (error) {
            pthread_mutex_unlock(&event->lock);
            return paramErr;
        }
    }
    if (event->header.deleted) {
        pthread_mutex_unlock(&event->lock);
        return kMPDeletedErr;
    }
    *flags = event->flags;
    event->flags = 0;
    pthread_mutex_unlock(&event->lock);
    return noErr;
}

LogicalAddress
MPAllocate(ByteCount size)
{
    if (!size || size > kMPMaxAllocSize) return NULL;
    return malloc((size_t)size);
}

LogicalAddress
MPAllocateAligned(ByteCount size, UInt8 alignment, OptionBits options)
{
    if (!size || size > kMPMaxAllocSize) return NULL;
    if (options & ~(kMPAllocateClearMask | kMPAllocateGloballyMask | kMPAllocateResidentMask |
                    kMPAllocateNoGrowthMask | kMPAllocateNoCreateMask)) return NULL;
    size_t align;
    if (alignment == kMPAllocateVMPageAligned || alignment == kMPAllocateInterlockAligned)
        align = (size_t)sysconf(_SC_PAGESIZE);
    else if (alignment > kMPAllocateMaxAlignment)
        return NULL;
    else
        align = alignment ? (size_t)1 << alignment : sizeof(void *);
    if (align < sizeof(void *)) align = sizeof(void *);
    if (align > (1u << kMPAllocateMaxAlignment)) return NULL;
    if (size > SIZE_MAX - align - 16) return NULL;
    void *base = NULL;
    size_t allocationSize = (size_t)size + align + 16;
    if (posix_memalign(&base, align, allocationSize) != 0) return NULL;
    void *memory = (char *)base + align;
    struct mp_aligned_allocation *record = malloc(sizeof *record);
    if (!record) {
        free(base);
        return NULL;
    }
    record->pointer = memory;
    record->base = base;
    size_t baseSize = malloc_size(base);
    record->size = baseSize > align ? (ByteCount)(baseSize - align) : size;
    pthread_mutex_lock(&mp_allocation_lock);
    record->next = mp_aligned_allocations;
    mp_aligned_allocations = record;
    pthread_mutex_unlock(&mp_allocation_lock);
    if (options & kMPAllocateClearMask) memset(memory, 0, (size_t)size);
    return memory;
}

void
MPFree(LogicalAddress object)
{
    pthread_mutex_lock(&mp_allocation_lock);
    struct mp_aligned_allocation **link = &mp_aligned_allocations;
    while (*link && (*link)->pointer != object) link = &(*link)->next;
    if (*link) {
        struct mp_aligned_allocation *record = *link;
        *link = record->next;
        pthread_mutex_unlock(&mp_allocation_lock);
        free(record->base);
        free(record);
        return;
    }
    pthread_mutex_unlock(&mp_allocation_lock);
    free(object);
}

ByteCount
MPGetAllocatedBlockSize(LogicalAddress object)
{
    if (!object) return 0;
    pthread_mutex_lock(&mp_allocation_lock);
    for (struct mp_aligned_allocation *record = mp_aligned_allocations; record; record = record->next) {
        if (record->pointer == object) {
            ByteCount size = record->size;
            pthread_mutex_unlock(&mp_allocation_lock);
            return size;
        }
    }
    pthread_mutex_unlock(&mp_allocation_lock);
    return (ByteCount)malloc_size(object);
}

void
MPBlockCopy(LogicalAddress source, LogicalAddress destination, ByteCount size)
{
    if (source && destination && size) memmove(destination, source, (size_t)size);
}

void
MPBlockClear(LogicalAddress address, ByteCount size)
{
    if (address && size) memset(address, 0, (size_t)size);
}

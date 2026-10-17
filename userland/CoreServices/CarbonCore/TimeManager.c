/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Carbon Time Manager tasks run on their own sleeping pthread. */
#include "CarbonCore_Finch.h"
#include <pthread.h>
#include <time.h>

struct finch_time_task {
    struct finch_time_task *next;
    TMTaskPtr task;
    pthread_t worker;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    Boolean installed;
    Boolean active;
    Boolean removed;
    struct timespec deadline;
};

static pthread_mutex_t time_tasks_lock = PTHREAD_MUTEX_INITIALIZER;
static struct finch_time_task *time_tasks;

static struct finch_time_task *
time_task_find_locked(TMTaskPtr task)
{
    for (struct finch_time_task *item = time_tasks; item; item = item->next)
        if (item->task == task)
            return item;
    return NULL;
}

static struct finch_time_task *
time_task_find(TMTaskPtr task)
{
    pthread_mutex_lock(&time_tasks_lock);
    struct finch_time_task *item = time_task_find_locked(task);
    pthread_mutex_unlock(&time_tasks_lock);
    return item;
}

static void
time_task_set_active(struct finch_time_task *item, Boolean active)
{
    item->active = active;
    if (active)
        item->task->qType = (short)((UInt16)item->task->qType | kTMTaskActive);
    else
        item->task->qType = (short)((UInt16)item->task->qType & ~kTMTaskActive);
}

static void *
time_task_worker(void *context)
{
    struct finch_time_task *item = context;
    pthread_mutex_lock(&item->lock);
    while (!item->removed) {
        while (!item->active && !item->removed)
            pthread_cond_wait(&item->changed, &item->lock);
        if (item->removed)
            break;
        int error = pthread_cond_timedwait(&item->changed, &item->lock, &item->deadline);
        if (!item->active || item->removed || error == 0)
            continue;
        time_task_set_active(item, false);
        TimerUPP callback = item->task->tmAddr;
        pthread_mutex_unlock(&item->lock);
        if (callback)
            callback(item->task);
        pthread_mutex_lock(&item->lock);
    }
    pthread_mutex_unlock(&item->lock);
    return NULL;
}

static OSErr
time_task_install(QElemPtr queueElement, Boolean allowEmptyCallback)
{
    TMTaskPtr task = (TMTaskPtr)queueElement;
    if (!task || (!allowEmptyCallback && !task->tmAddr))
        return paramErr;
    pthread_mutex_lock(&time_tasks_lock);
    if (time_task_find_locked(task)) {
        pthread_mutex_unlock(&time_tasks_lock);
        return noErr;
    }
    struct finch_time_task *item = calloc(1, sizeof *item);
    if (!item) {
        pthread_mutex_unlock(&time_tasks_lock);
        return memFullErr;
    }
    item->task = task;
    item->installed = true;
    pthread_mutex_init(&item->lock, NULL);
    pthread_cond_init(&item->changed, NULL);
    item->next = time_tasks;
    time_tasks = item;
    pthread_mutex_unlock(&time_tasks_lock);
    int error = pthread_create(&item->worker, NULL, time_task_worker, item);
    if (error) {
        pthread_mutex_lock(&time_tasks_lock);
        struct finch_time_task **link = &time_tasks;
        while (*link && *link != item)
            link = &(*link)->next;
        if (*link)
            *link = item->next;
        pthread_mutex_unlock(&time_tasks_lock);
        pthread_cond_destroy(&item->changed);
        pthread_mutex_destroy(&item->lock);
        free(item);
        return memFullErr;
    }
    task->qType = (short)((UInt16)task->qType & ~kTMTaskActive);
    return noErr;
}

OSErr
InstallTimeTask(QElemPtr task)
{
    return time_task_install(task, false);
}

OSErr
InstallXTimeTask(QElemPtr task)
{
    return time_task_install(task, true);
}

void
InsTime(QElemPtr task)
{
    (void)time_task_install(task, false);
}

void
InsXTime(QElemPtr task)
{
    (void)time_task_install(task, true);
}

static OSErr
time_task_prime(QElemPtr queueElement, long count)
{
    struct finch_time_task *item = time_task_find((TMTaskPtr)queueElement);
    if (!item)
        return paramErr;
    pthread_mutex_lock(&item->lock);
    if (item->removed) {
        pthread_mutex_unlock(&item->lock);
        return paramErr;
    }
    clock_gettime(CLOCK_REALTIME, &item->deadline);
    int64_t nanoseconds = count < 0 ? -(int64_t)count * 1000 : (int64_t)count * 1000000;
    item->deadline.tv_sec += (time_t)(nanoseconds / 1000000000);
    item->deadline.tv_nsec += (long)(nanoseconds % 1000000000);
    if (item->deadline.tv_nsec >= 1000000000) {
        item->deadline.tv_sec++;
        item->deadline.tv_nsec -= 1000000000;
    }
    item->task->tmCount = count;
    time_task_set_active(item, true);
    pthread_cond_broadcast(&item->changed);
    pthread_mutex_unlock(&item->lock);
    return noErr;
}

OSErr
PrimeTimeTask(QElemPtr task, long count)
{
    return time_task_prime(task, count);
}

void
PrimeTime(QElemPtr task, long count)
{
    (void)time_task_prime(task, count);
}

static OSErr
time_task_remove(QElemPtr queueElement)
{
    struct finch_time_task *item = time_task_find((TMTaskPtr)queueElement);
    if (!item)
        return paramErr;
    pthread_mutex_lock(&item->lock);
    if (item->active) {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t remaining = (int64_t)(item->deadline.tv_sec - now.tv_sec) * 1000000000 +
                            item->deadline.tv_nsec - now.tv_nsec;
        if (remaining < 0)
            remaining = 0;
        if (remaining < 1000000000LL)
            item->task->tmCount = -(long)(remaining / 1000);
        else
            item->task->tmCount = (long)((remaining + 999999) / 1000000);
    }
    time_task_set_active(item, false);
    item->removed = true;
    pthread_cond_broadcast(&item->changed);
    pthread_mutex_unlock(&item->lock);

    pthread_mutex_lock(&time_tasks_lock);
    struct finch_time_task **link = &time_tasks;
    while (*link && *link != item)
        link = &(*link)->next;
    if (*link)
        *link = item->next;
    pthread_mutex_unlock(&time_tasks_lock);
    pthread_join(item->worker, NULL);
    pthread_cond_destroy(&item->changed);
    pthread_mutex_destroy(&item->lock);
    free(item);
    return noErr;
}

OSErr
RemoveTimeTask(QElemPtr task)
{
    return time_task_remove(task);
}

void
RmvTime(QElemPtr task)
{
    (void)time_task_remove(task);
}

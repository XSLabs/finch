/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The old Thread Manager calls use native pthreads for runnable threads. */
#include "CarbonCore_Finch.h"
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

struct finch_thread {
    struct finch_thread *next;
    pthread_t native;
    pthread_mutex_t lock;
    pthread_cond_t ready;
    ThreadID id;
    ThreadEntryTPP entry;
    void *parameter;
    void *result;
    Boolean started;
    Boolean suspended;
    Boolean allowRun;
    Boolean cancelled;
    Boolean finished;
    Boolean joined;
    ThreadTerminationTPP terminator;
    void *terminatorParameter;
};

static pthread_mutex_t thread_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t thread_critical_lock = PTHREAD_MUTEX_INITIALIZER;
static struct finch_thread *threads;
static ThreadID next_thread_id = 3;
static _Thread_local unsigned critical_depth;

static struct finch_thread *
thread_find_locked(ThreadID id)
{
    for (struct finch_thread *thread = threads; thread; thread = thread->next)
        if (thread->id == id)
            return thread;
    return NULL;
}

static void *
thread_main(void *context)
{
    struct finch_thread *thread = context;
    pthread_mutex_lock(&thread->lock);
    while (!thread->allowRun && !thread->cancelled)
        pthread_cond_wait(&thread->ready, &thread->lock);
    if (thread->cancelled) {
        pthread_mutex_unlock(&thread->lock);
        return NULL;
    }
    thread->started = true;
    pthread_mutex_unlock(&thread->lock);

    void *result = thread->entry(thread->parameter);

    pthread_mutex_lock(&thread->lock);
    thread->result = result;
    thread->finished = true;
    ThreadTerminationTPP terminator = thread->terminator;
    void *terminatorParameter = thread->terminatorParameter;
    pthread_mutex_unlock(&thread->lock);
    if (terminator)
        terminator(thread->id, terminatorParameter);
    return result;
}

OSErr
NewThread(ThreadStyle threadStyle, ThreadEntryTPP threadEntry, void *threadParam, Size stackSize,
          ThreadOptions options, void **threadResult, ThreadID *threadMade)
{
    if (!threadEntry || !threadMade || (threadStyle != kPreemptiveThread && threadStyle != kCooperativeThread) ||
        (options & ~(kNewSuspend | kFPUNotNeeded)))
        return paramErr;
    if (threadStyle == kPreemptiveThread)
        return paramErr;

    struct finch_thread *thread = calloc(1, sizeof *thread);
    if (!thread)
        return memFullErr;
    pthread_mutex_init(&thread->lock, NULL);
    pthread_cond_init(&thread->ready, NULL);
    thread->entry = threadEntry;
    thread->parameter = threadParam;
    thread->suspended = (options & kNewSuspend) != 0;

    pthread_mutex_lock(&thread_lock);
    thread->id = next_thread_id++;
    if (!thread->id)
        thread->id = next_thread_id++;
    thread->next = threads;
    threads = thread;
    pthread_mutex_unlock(&thread_lock);

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    if (stackSize > 0) {
        int error = pthread_attr_setstacksize(&attributes, (size_t)stackSize);
        if (error) {
            pthread_attr_destroy(&attributes);
            pthread_mutex_lock(&thread_lock);
            threads = thread->next;
            pthread_mutex_unlock(&thread_lock);
            pthread_cond_destroy(&thread->ready);
            pthread_mutex_destroy(&thread->lock);
            free(thread);
            return paramErr;
        }
    }
    int error = pthread_create(&thread->native, &attributes, thread_main, thread);
    pthread_attr_destroy(&attributes);
    if (error) {
        pthread_mutex_lock(&thread_lock);
        struct finch_thread **link = &threads;
        while (*link && *link != thread)
            link = &(*link)->next;
        if (*link)
            *link = thread->next;
        pthread_mutex_unlock(&thread_lock);
        pthread_cond_destroy(&thread->ready);
        pthread_mutex_destroy(&thread->lock);
        free(thread);
        return memFullErr;
    }
    *threadMade = thread->id;
    (void)threadResult;
    return noErr;
}

OSErr
DisposeThread(ThreadID threadToDump, void *threadResult, Boolean recycleThread)
{
    (void)recycleThread;
    pthread_mutex_lock(&thread_lock);
    struct finch_thread *thread = thread_find_locked(threadToDump);
    if (!thread) {
        pthread_mutex_unlock(&thread_lock);
        return threadNotFoundErr;
    }
    if (pthread_equal(thread->native, pthread_self())) {
        pthread_mutex_unlock(&thread_lock);
        return threadProtocolErr;
    }
    struct finch_thread **link = &threads;
    while (*link && *link != thread)
        link = &(*link)->next;
    if (*link)
        *link = thread->next;
    pthread_mutex_unlock(&thread_lock);

    pthread_mutex_lock(&thread->lock);
    Boolean notStarted = !thread->started;
    if (notStarted) {
        thread->cancelled = true;
        pthread_cond_broadcast(&thread->ready);
    }
    pthread_mutex_unlock(&thread->lock);
    pthread_join(thread->native, NULL);
    (void)threadResult;
    pthread_cond_destroy(&thread->ready);
    pthread_mutex_destroy(&thread->lock);
    free(thread);
    return noErr;
}

OSErr
YieldToAnyThread(void)
{
    pthread_mutex_lock(&thread_lock);
    for (struct finch_thread *thread = threads; thread; thread = thread->next) {
        pthread_mutex_lock(&thread->lock);
        if (!thread->suspended && !thread->started && !thread->finished) {
            thread->allowRun = true;
            pthread_cond_broadcast(&thread->ready);
        }
        pthread_mutex_unlock(&thread->lock);
    }
    pthread_mutex_unlock(&thread_lock);
    sched_yield();
    return noErr;
}

OSErr
YieldToThread(ThreadID suggestedThread)
{
    pthread_mutex_lock(&thread_lock);
    Boolean exists = suggestedThread == kCurrentThreadID || suggestedThread == kApplicationThreadID ||
                     thread_find_locked(suggestedThread) != NULL;
    pthread_mutex_unlock(&thread_lock);
    if (!exists)
        return threadNotFoundErr;
    pthread_mutex_lock(&thread_lock);
    struct finch_thread *thread = thread_find_locked(suggestedThread);
    if (thread) {
        pthread_mutex_lock(&thread->lock);
        if (!thread->suspended && !thread->started && !thread->finished) {
            thread->allowRun = true;
            pthread_cond_broadcast(&thread->ready);
        }
        pthread_mutex_unlock(&thread->lock);
    }
    pthread_mutex_unlock(&thread_lock);
    sched_yield();
    return noErr;
}

OSErr
GetThreadState(ThreadID threadToGet, ThreadState *threadState)
{
    if (!threadState)
        return paramErr;
    if (threadToGet == kCurrentThreadID || threadToGet == kApplicationThreadID) {
        *threadState = kRunningThreadState;
        return noErr;
    }
    pthread_mutex_lock(&thread_lock);
    struct finch_thread *thread = thread_find_locked(threadToGet);
    pthread_mutex_unlock(&thread_lock);
    if (!thread)
        return threadNotFoundErr;
    pthread_mutex_lock(&thread->lock);
    *threadState = thread->finished ? kStoppedThreadState :
                   !thread->started ? kReadyThreadState : kRunningThreadState;
    pthread_mutex_unlock(&thread->lock);
    return noErr;
}

OSErr
SetThreadState(ThreadID threadToSet, ThreadState newState, ThreadID suggestedThread)
{
    (void)suggestedThread;
    if (newState != kReadyThreadState && newState != kStoppedThreadState && newState != kRunningThreadState)
        return paramErr;
    pthread_mutex_lock(&thread_lock);
    struct finch_thread *thread = thread_find_locked(threadToSet);
    pthread_mutex_unlock(&thread_lock);
    if (!thread)
        return threadNotFoundErr;
    pthread_mutex_lock(&thread->lock);
    if (newState == kReadyThreadState && thread->suspended) {
        thread->suspended = false;
        thread->allowRun = true;
        pthread_cond_broadcast(&thread->ready);
    } else if (newState == kStoppedThreadState && !thread->started) {
        thread->suspended = true;
    } else if (newState == kStoppedThreadState || (newState == kRunningThreadState && thread->finished)) {
        pthread_mutex_unlock(&thread->lock);
        return threadProtocolErr;
    }
    pthread_mutex_unlock(&thread->lock);
    return noErr;
}

OSErr
SetThreadStateEndCritical(ThreadID threadToSet, ThreadState newState, ThreadID suggestedThread)
{
    OSErr status = SetThreadState(threadToSet, newState, suggestedThread);
    OSErr endStatus = ThreadEndCritical();
    return status != noErr ? status : endStatus;
}

OSErr
ThreadBeginCritical(void)
{
    if (critical_depth++ == 0)
        pthread_mutex_lock(&thread_critical_lock);
    return noErr;
}

OSErr
ThreadEndCritical(void)
{
    if (!critical_depth)
        return threadProtocolErr;
    if (--critical_depth == 0)
        pthread_mutex_unlock(&thread_critical_lock);
    return noErr;
}

OSErr
GetThreadCurrentTaskRef(ThreadTaskRef *threadTRef)
{
    if (!threadTRef)
        return paramErr;
    *threadTRef = (ThreadTaskRef)(uintptr_t)getpid();
    return noErr;
}

OSErr
GetThreadStateGivenTaskRef(ThreadTaskRef threadTRef, ThreadID threadToGet, ThreadState *threadState)
{
    if (!threadTRef)
        return paramErr;
    return GetThreadState(threadToGet, threadState);
}

OSErr
SetThreadReadyGivenTaskRef(ThreadTaskRef threadTRef, ThreadID threadToSet)
{
    if (!threadTRef)
        return paramErr;
    return SetThreadState(threadToSet, kReadyThreadState, kCurrentThreadID);
}

OSErr
ThreadCurrentStackSpace(ThreadID thread, ByteCount *freeStack)
{
    if (!freeStack)
        return paramErr;
    if (thread != kCurrentThreadID && thread != kApplicationThreadID)
        return threadNotFoundErr;
    pthread_t self = pthread_self();
    void *top = pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    /* The Carbon Thread Manager cannot account for stack space on modern macOS. */
    (void)top;
    (void)size;
    *freeStack = 0;
    return noErr;
}

OSErr
GetDefaultThreadStackSize(ThreadStyle threadStyle, Size *stackSize)
{
    if (!stackSize || (threadStyle != kPreemptiveThread && threadStyle != kCooperativeThread))
        return paramErr;
    *stackSize = threadStyle == kCooperativeThread ? 512 * 1024 : 1024 * 1024;
    return noErr;
}

OSErr
SetThreadTerminator(ThreadID thread, ThreadTerminationTPP terminator, void *terminationProcParam)
{
    pthread_mutex_lock(&thread_lock);
    struct finch_thread *found = thread_find_locked(thread);
    pthread_mutex_unlock(&thread_lock);
    if (!found)
        return threadNotFoundErr;
    pthread_mutex_lock(&found->lock);
    found->terminator = terminator;
    found->terminatorParameter = terminationProcParam;
    pthread_mutex_unlock(&found->lock);
    return noErr;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's clocks, timebases and their synchronisation, Finch's. The host time
 * clock counts mach_absolute_time in nanoseconds (timescale 10^9), as Apple's does; an
 * audio device clock follows it (Finch has no audio hardware clocks yet). A timebase is
 * an anchor (its time at a time of its source, a clock or another timebase) and a rate:
 * its time is the anchor plus the source's elapsed time at that rate. Timers (run loop
 * timers and dispatch sources) are moved whenever the timebase's time or rate changes
 * so they fire when the timebase reaches their time.
 */
#include "CMInternal.h"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>

typedef struct OpaqueCMClock *MutableClock;
typedef struct OpaqueCMTimebase *MutableTimebase;

struct OpaqueCMClock {
    CFRuntimeBase base;
    const char *kind;
    bool invalid;
};

typedef struct {
    CFTypeRef timer; /* a CFRunLoopTimer or a dispatch source */
    bool dispatch;
    CFRunLoopRef runLoop;
    CMTime fireTime;
} Timer;

struct OpaqueCMTimebase {
    CFRuntimeBase base;
    pthread_mutex_t lock;
    CFTypeRef source; /* a clock or a timebase */
    bool readOnly;
    CMTimebaseRef readOnlyOf;
    CMTime anchor, sourceAnchor;
    double rate;
    Timer *timers;
    size_t timerCount, timerCapacity;
};

static void
clock_finalize(CFTypeRef cf)
{
}

static CFStringRef clock_description(CFTypeRef cf);
static CFStringRef timebase_description(CFTypeRef cf);
static void timebase_finalize(CFTypeRef cf);

CM_DEFINE_TYPE(CMClockGetTypeID, "CMClock", clock_finalize, NULL, NULL, clock_description)
CM_DEFINE_TYPE(CMTimebaseGetTypeID, "CMTimebase", timebase_finalize, NULL, NULL, timebase_description)

static bool
is_clock(CFTypeRef cf)
{
    return cf && CFGetTypeID(cf) == CMClockGetTypeID();
}

static bool
is_timebase(CFTypeRef cf)
{
    return cf && CFGetTypeID(cf) == CMTimebaseGetTypeID();
}

/* --- clocks --- */

static mach_timebase_info_data_t
ticks(void)
{
    static mach_timebase_info_data_t info;
    if (!info.denom)
        mach_timebase_info(&info);
    return info;
}

CMTime
CMClockMakeHostTimeFromSystemUnits(uint64_t hostTime)
{
    mach_timebase_info_data_t i = ticks();
    return CMTimeMake((int64_t)((__uint128_t)hostTime * i.numer / i.denom), 1000000000);
}

uint64_t
CMClockConvertHostTimeToSystemUnits(CMTime hostTime)
{
    if (!CMTIME_IS_NUMERIC(hostTime))
        return 0;
    /* (by way of nanoseconds, each step truncated, as Apple's) */
    CMTime ns = CMTimeConvertScale(hostTime, 1000000000, kCMTimeRoundingMethod_RoundTowardZero);
    mach_timebase_info_data_t i = ticks();
    return (uint64_t)((__int128)ns.value * i.denom / i.numer);
}

static MutableClock
make_clock(CFAllocatorRef allocator, const char *kind)
{
    MutableClock c = (MutableClock)cm_create(allocator, CMClockGetTypeID(), sizeof(struct OpaqueCMClock));
    if (c)
        c->kind = kind;
    return c;
}

CMClockRef
CMClockGetHostTimeClock(void)
{
    static CMClockRef host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      host = make_clock(NULL, "HostTimeClock");
    });
    return host;
}

CMTime
CMClockGetTime(CMClockRef clock)
{
    if (!is_clock(clock) || clock->invalid)
        return kCMTimeInvalid;
    return CMClockMakeHostTimeFromSystemUnits(mach_absolute_time());
}

OSStatus
CMClockGetAnchorTime(CMClockRef clock, CMTime *clockTimeOut, CMTime *referenceClockTimeOut)
{
    if (!is_clock(clock) || !clockTimeOut || !referenceClockTimeOut)
        return kCMClockError_MissingRequiredParameter;
    if (clock->invalid)
        return kCMClockError_UnsupportedOperation;
    *clockTimeOut = *referenceClockTimeOut = CMClockGetTime(clock);
    return noErr;
}

Boolean
CMClockMightDrift(CMClockRef clock, CMClockRef otherClock)
{
    /* (every clock Finch has follows the host clock) */
    return false;
}

void
CMClockInvalidate(CMClockRef clock)
{
    if (is_clock(clock) && clock != CMClockGetHostTimeClock())
        ((MutableClock)clock)->invalid = true;
}

static OSStatus
audio_clock(CFAllocatorRef allocator, CMClockRef *clockOut)
{
    if (!clockOut)
        return kCMClockError_MissingRequiredParameter;
    *clockOut = make_clock(allocator, "AudioClock");
    return *clockOut ? noErr : kCMClockError_AllocationFailed;
}

/* (iOS's, but exported on macOS too) */
OSStatus finch_audio_clock_create(CFAllocatorRef allocator, CMClockRef *clockOut) __asm__("_CMAudioClockCreate");
OSStatus
finch_audio_clock_create(CFAllocatorRef allocator, CMClockRef *clockOut)
{
    return audio_clock(allocator, clockOut);
}

OSStatus
CMAudioDeviceClockCreate(CFAllocatorRef allocator, CFStringRef deviceUID, CMClockRef *clockOut)
{
    return audio_clock(allocator, clockOut);
}

OSStatus
CMAudioDeviceClockCreateFromAudioDeviceID(CFAllocatorRef allocator, uint32_t deviceID, CMClockRef *clockOut)
{
    return audio_clock(allocator, clockOut);
}

OSStatus
CMAudioDeviceClockSetAudioDeviceUID(CMClockRef clock, CFStringRef deviceUID)
{
    return is_clock(clock) ? noErr : kCMClockError_MissingRequiredParameter;
}

OSStatus
CMAudioDeviceClockSetAudioDeviceID(CMClockRef clock, uint32_t deviceID)
{
    return is_clock(clock) ? noErr : kCMClockError_MissingRequiredParameter;
}

OSStatus
CMAudioDeviceClockGetAudioDevice(CMClockRef clock, CFStringRef *deviceUIDOut, uint32_t *deviceIDOut, Boolean *trackingDefaultDeviceOut)
{
    if (!is_clock(clock))
        return kCMClockError_MissingRequiredParameter;
    if (deviceUIDOut)
        *deviceUIDOut = NULL;
    if (deviceIDOut)
        *deviceIDOut = 0;
    if (trackingDefaultDeviceOut)
        *trackingDefaultDeviceOut = true;
    return noErr;
}

static CFStringRef
clock_description(CFTypeRef cf)
{
    CMClockRef c = (CMClockRef)cf;
    CMTime now = CMClockGetTime(c);
    CFStringRef t = CMTimeCopyDescription(NULL, now);
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL, CFSTR("FigClock[%s]: %p retainCount: %ld allocator: %p current time: %@ = %f seconds"), c->kind,
                                             cf, (long)CFGetRetainCount(cf), CFGetAllocator(cf), t, CMTimeGetSeconds(now));
    CFRelease(t);
    return s;
}

/* --- timebases --- */

static CMTime source_time(CFTypeRef source);

/* The timebase's time, given its source's (the lock held). */
static CMTime
time_at(CMTimebaseRef tb, CMTime sourceNow)
{
    if (tb->rate == 0 || !CMTIME_IS_NUMERIC(sourceNow) || !CMTIME_IS_NUMERIC(tb->sourceAnchor))
        return tb->anchor;
    CMTime elapsed = CMTimeSubtract(sourceNow, tb->sourceAnchor);
    if (!CMTimeCompare(elapsed, kCMTimeZero))
        return tb->anchor;
    return CMTimeAdd(tb->anchor, tb->rate == 1 ? elapsed : CMTimeMultiplyByFloat64(elapsed, tb->rate));
}

/* The source's time at which the timebase reaches t (the lock held). */
static CMTime
source_time_for(CMTimebaseRef tb, CMTime t)
{
    if (tb->rate == 0 || !CMTIME_IS_NUMERIC(t))
        return kCMTimeInvalid;
    CMTime d = CMTimeSubtract(t, tb->anchor);
    if (tb->rate != 1)
        d = CMTimeMakeWithSeconds(CMTimeGetSeconds(d) / tb->rate, 1000000000);
    return CMTimeAdd(tb->sourceAnchor, d);
}

static CMTime
source_time(CFTypeRef source)
{
    if (is_clock(source))
        return CMClockGetTime((CMClockRef)source);
    if (is_timebase(source))
        return CMTimebaseGetTime((CMTimebaseRef)source);
    return kCMTimeInvalid;
}

CMTime
CMTimebaseGetTime(CMTimebaseRef timebase)
{
    if (!is_timebase(timebase))
        return kCMTimeInvalid;
    if (timebase->readOnlyOf)
        return CMTimebaseGetTime(timebase->readOnlyOf);
    MutableTimebase tb = (MutableTimebase)timebase;
    CMTime now = source_time(tb->source);
    pthread_mutex_lock(&tb->lock);
    CMTime t = time_at(tb, now);
    pthread_mutex_unlock(&tb->lock);
    return t;
}

CMTime
CMTimebaseGetTimeWithTimeScale(CMTimebaseRef timebase, CMTimeScale timescale, CMTimeRoundingMethod method)
{
    return CMTimeConvertScale(CMTimebaseGetTime(timebase), timescale, method);
}

static OSStatus
make_timebase(CFAllocatorRef allocator, CFTypeRef source, CMTimebaseRef *out)
{
    if (!out || !source)
        return kCMTimebaseError_MissingRequiredParameter;
    MutableTimebase tb = (MutableTimebase)cm_create(allocator, CMTimebaseGetTypeID(), sizeof(struct OpaqueCMTimebase));
    if (!tb)
        return kCMTimebaseError_AllocationFailed;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&tb->lock, &attr);
    pthread_mutexattr_destroy(&attr);
    tb->source = CFRetain(source);
    tb->anchor = kCMTimeZero;
    tb->sourceAnchor = source_time(source);
    *out = tb;
    return noErr;
}

OSStatus
CMTimebaseCreateWithSourceClock(CFAllocatorRef allocator, CMClockRef sourceClock, CMTimebaseRef *timebaseOut)
{
    if (!is_clock(sourceClock))
        return kCMTimebaseError_MissingRequiredParameter;
    return make_timebase(allocator, sourceClock, timebaseOut);
}

OSStatus
CMTimebaseCreateWithSourceTimebase(CFAllocatorRef allocator, CMTimebaseRef sourceTimebase, CMTimebaseRef *timebaseOut)
{
    if (!is_timebase(sourceTimebase))
        return kCMTimebaseError_MissingRequiredParameter;
    return make_timebase(allocator, sourceTimebase, timebaseOut);
}

OSStatus finch_timebase_create_with_master_clock(CFAllocatorRef allocator, CMClockRef masterClock, CMTimebaseRef *timebaseOut) __asm__("_CMTimebaseCreateWithMasterClock");
OSStatus
finch_timebase_create_with_master_clock(CFAllocatorRef allocator, CMClockRef masterClock, CMTimebaseRef *timebaseOut)
{
    return CMTimebaseCreateWithSourceClock(allocator, masterClock, timebaseOut);
}

OSStatus finch_timebase_create_with_master_timebase(CFAllocatorRef allocator, CMTimebaseRef masterTimebase, CMTimebaseRef *timebaseOut) __asm__("_CMTimebaseCreateWithMasterTimebase");
OSStatus
finch_timebase_create_with_master_timebase(CFAllocatorRef allocator, CMTimebaseRef masterTimebase, CMTimebaseRef *timebaseOut)
{
    return CMTimebaseCreateWithSourceTimebase(allocator, masterTimebase, timebaseOut);
}

OSStatus
CMTimebaseCreateReadOnlyTimebase(CFAllocatorRef allocator, CMTimebaseRef timebase, CMTimebaseRef *readOnlyTimebaseOut)
{
    if (!is_timebase(timebase) || !readOnlyTimebaseOut)
        return kCMTimebaseError_MissingRequiredParameter;
    OSStatus e = make_timebase(allocator, timebase->source, readOnlyTimebaseOut);
    if (!e) {
        MutableTimebase r = (MutableTimebase)*readOnlyTimebaseOut;
        r->readOnly = true;
        r->readOnlyOf = (CMTimebaseRef)CFRetain(timebase);
    }
    return e;
}

static void reschedule(MutableTimebase tb);

static void
timebase_finalize(CFTypeRef cf)
{
    MutableTimebase tb = (MutableTimebase)cf;
    for (size_t i = 0; i < tb->timerCount; i++) {
        if (tb->timers[i].runLoop)
            CFRelease(tb->timers[i].runLoop);
        CFRelease(tb->timers[i].timer);
    }
    free(tb->timers);
    if (tb->source)
        CFRelease(tb->source);
    if (tb->readOnlyOf)
        CFRelease(tb->readOnlyOf);
    pthread_mutex_destroy(&tb->lock);
}

/* What a change notifies: the effective rate, or a jump in time. */
static void
notify(CMTimebaseRef tb, CFStringRef name)
{
    extern OSStatus CMNotificationCenterPostNotification(CFTypeRef center, CFStringRef name, const void *object, CFTypeRef payload, UInt32 flags);
    extern CFTypeRef CMNotificationCenterGetDefaultLocalCenter(void);
    CMNotificationCenterPostNotification(CMNotificationCenterGetDefaultLocalCenter(), name, tb, NULL, 0);
}

static OSStatus
set_anchor_and_rate(CMTimebaseRef timebase, bool setRate, double rate, CMTime time, CMTime sourceTime, bool sourceGiven)
{
    if (!is_timebase(timebase))
        return kCMTimebaseError_MissingRequiredParameter;
    if (timebase->readOnly)
        return kCMTimebaseError_ReadOnly;
    MutableTimebase tb = (MutableTimebase)timebase;
    CMTime now = sourceGiven ? sourceTime : source_time(tb->source);
    pthread_mutex_lock(&tb->lock);
    double old = tb->rate;
    if (CMTIME_IS_VALID(time)) {
        tb->anchor = time;
        tb->sourceAnchor = now;
    } else if (setRate) {
        /* (a new rate from the time now) */
        tb->anchor = time_at(tb, now);
        tb->sourceAnchor = now;
    }
    if (setRate)
        tb->rate = rate;
    pthread_mutex_unlock(&tb->lock);
    reschedule(tb);
    if (CMTIME_IS_VALID(time))
        notify(tb, kCMTimebaseNotification_TimeJumped);
    if (setRate && old != rate)
        notify(tb, kCMTimebaseNotification_EffectiveRateChanged);
    return noErr;
}

OSStatus
CMTimebaseSetTime(CMTimebaseRef timebase, CMTime time)
{
    if (!CMTIME_IS_VALID(time))
        return kCMTimebaseError_MissingRequiredParameter;
    return set_anchor_and_rate(timebase, false, 0, time, kCMTimeInvalid, false);
}

OSStatus
CMTimebaseSetAnchorTime(CMTimebaseRef timebase, CMTime timebaseTime, CMTime immediateSourceTime)
{
    if (!CMTIME_IS_VALID(timebaseTime) || !CMTIME_IS_VALID(immediateSourceTime))
        return kCMTimebaseError_InvalidParameter;
    return set_anchor_and_rate(timebase, false, 0, timebaseTime, immediateSourceTime, true);
}

OSStatus
CMTimebaseSetRate(CMTimebaseRef timebase, Float64 rate)
{
    return set_anchor_and_rate(timebase, true, rate, kCMTimeInvalid, kCMTimeInvalid, false);
}

OSStatus
CMTimebaseSetRateAndAnchorTime(CMTimebaseRef timebase, Float64 rate, CMTime timebaseTime, CMTime immediateSourceTime)
{
    if (!CMTIME_IS_VALID(timebaseTime) || !CMTIME_IS_VALID(immediateSourceTime))
        return kCMTimebaseError_InvalidParameter;
    return set_anchor_and_rate(timebase, true, rate, timebaseTime, immediateSourceTime, true);
}

Float64
CMTimebaseGetRate(CMTimebaseRef timebase)
{
    if (!is_timebase(timebase))
        return 0;
    return timebase->readOnlyOf ? CMTimebaseGetRate(timebase->readOnlyOf) : timebase->rate;
}

OSStatus
CMTimebaseGetTimeAndRate(CMTimebaseRef timebase, CMTime *timeOut, Float64 *rateOut)
{
    if (!is_timebase(timebase))
        return kCMTimebaseError_MissingRequiredParameter;
    if (timeOut)
        *timeOut = CMTimebaseGetTime(timebase);
    if (rateOut)
        *rateOut = CMTimebaseGetRate(timebase);
    return noErr;
}

Float64
CMTimebaseGetEffectiveRate(CMTimebaseRef timebase)
{
    if (!is_timebase(timebase))
        return 0;
    if (timebase->readOnlyOf)
        return CMTimebaseGetEffectiveRate(timebase->readOnlyOf);
    double r = timebase->rate;
    return is_timebase(timebase->source) ? r * CMTimebaseGetEffectiveRate((CMTimebaseRef)timebase->source) : r;
}

CFTypeRef
CMTimebaseCopySource(CMTimebaseRef timebase)
{
    return is_timebase(timebase) && timebase->source ? CFRetain(timebase->source) : NULL;
}

CMClockRef
CMTimebaseCopySourceClock(CMTimebaseRef timebase)
{
    return is_timebase(timebase) && is_clock(timebase->source) ? (CMClockRef)CFRetain(timebase->source) : NULL;
}

CMTimebaseRef
CMTimebaseCopySourceTimebase(CMTimebaseRef timebase)
{
    return is_timebase(timebase) && is_timebase(timebase->source) ? (CMTimebaseRef)CFRetain(timebase->source) : NULL;
}

CMClockRef
CMTimebaseCopyUltimateSourceClock(CMTimebaseRef timebase)
{
    CFTypeRef s = is_timebase(timebase) ? timebase->source : NULL;
    while (is_timebase(s))
        s = ((CMTimebaseRef)s)->source;
    return is_clock(s) ? (CMClockRef)CFRetain(s) : NULL;
}

/* The deprecated "master" names (inline in the SDK's headers, exported all the same). */
CMClockRef finch_timebase_get_master_clock(CMTimebaseRef timebase) __asm__("_CMTimebaseGetMasterClock");
CMClockRef
finch_timebase_get_master_clock(CMTimebaseRef timebase)
{
    return is_timebase(timebase) && is_clock(timebase->source) ? (CMClockRef)timebase->source : NULL;
}

CMTimebaseRef finch_timebase_get_master_timebase(CMTimebaseRef timebase) __asm__("_CMTimebaseGetMasterTimebase");
CMTimebaseRef
finch_timebase_get_master_timebase(CMTimebaseRef timebase)
{
    return is_timebase(timebase) && is_timebase(timebase->source) ? (CMTimebaseRef)timebase->source : NULL;
}

CFTypeRef finch_timebase_get_master(CMTimebaseRef timebase) __asm__("_CMTimebaseGetMaster");
CFTypeRef
finch_timebase_get_master(CMTimebaseRef timebase)
{
    return is_timebase(timebase) ? timebase->source : NULL;
}

CMClockRef finch_timebase_get_ultimate_master_clock(CMTimebaseRef timebase) __asm__("_CMTimebaseGetUltimateMasterClock");
CMClockRef
finch_timebase_get_ultimate_master_clock(CMTimebaseRef timebase)
{
    CMClockRef c = CMTimebaseCopyUltimateSourceClock(timebase);
    if (c)
        CFRelease(c);
    return c;
}

CMTimebaseRef finch_timebase_copy_master_timebase(CMTimebaseRef timebase) __asm__("_CMTimebaseCopyMasterTimebase");
CMTimebaseRef
finch_timebase_copy_master_timebase(CMTimebaseRef timebase)
{
    return CMTimebaseCopySourceTimebase(timebase);
}

CMClockRef finch_timebase_copy_master_clock(CMTimebaseRef timebase) __asm__("_CMTimebaseCopyMasterClock");
CMClockRef
finch_timebase_copy_master_clock(CMTimebaseRef timebase)
{
    return CMTimebaseCopySourceClock(timebase);
}

CFTypeRef finch_timebase_copy_master(CMTimebaseRef timebase) __asm__("_CMTimebaseCopyMaster");
CFTypeRef
finch_timebase_copy_master(CMTimebaseRef timebase)
{
    return CMTimebaseCopySource(timebase);
}

CMClockRef finch_timebase_copy_ultimate_master_clock(CMTimebaseRef timebase) __asm__("_CMTimebaseCopyUltimateMasterClock");
CMClockRef
finch_timebase_copy_ultimate_master_clock(CMTimebaseRef timebase)
{
    return CMTimebaseCopyUltimateSourceClock(timebase);
}

static OSStatus
set_source(CMTimebaseRef timebase, CFTypeRef source)
{
    if (!is_timebase(timebase) || !source)
        return kCMTimebaseError_MissingRequiredParameter;
    if (timebase->readOnly)
        return kCMTimebaseError_ReadOnly;
    MutableTimebase tb = (MutableTimebase)timebase;
    /* (the time carries over: re-anchored to the new source's time now) */
    CMTime t = CMTimebaseGetTime(tb);
    CMTime now = source_time(source);
    pthread_mutex_lock(&tb->lock);
    CFRetain(source);
    CFRelease(tb->source);
    tb->source = source;
    tb->anchor = t;
    tb->sourceAnchor = now;
    pthread_mutex_unlock(&tb->lock);
    reschedule(tb);
    return noErr;
}

OSStatus
CMTimebaseSetSourceClock(CMTimebaseRef timebase, CMClockRef newSourceClock)
{
    return is_clock(newSourceClock) ? set_source(timebase, newSourceClock) : kCMTimebaseError_MissingRequiredParameter;
}

OSStatus
CMTimebaseSetSourceTimebase(CMTimebaseRef timebase, CMTimebaseRef newSourceTimebase)
{
    return is_timebase(newSourceTimebase) ? set_source(timebase, newSourceTimebase) : kCMTimebaseError_MissingRequiredParameter;
}

OSStatus finch_timebase_set_master_clock(CMTimebaseRef timebase, CMClockRef newMasterClock) __asm__("_CMTimebaseSetMasterClock");
OSStatus
finch_timebase_set_master_clock(CMTimebaseRef timebase, CMClockRef newMasterClock)
{
    return CMTimebaseSetSourceClock(timebase, newMasterClock);
}

OSStatus finch_timebase_set_master_timebase(CMTimebaseRef timebase, CMTimebaseRef newMasterTimebase) __asm__("_CMTimebaseSetMasterTimebase");
OSStatus
finch_timebase_set_master_timebase(CMTimebaseRef timebase, CMTimebaseRef newMasterTimebase)
{
    return CMTimebaseSetSourceTimebase(timebase, newMasterTimebase);
}

OSStatus
CMTimebaseNotificationBarrier(CMTimebaseRef timebase)
{
    /* (notifications are posted as changes happen, so there's nothing to wait for) */
    return is_timebase(timebase) ? noErr : kCMTimebaseError_MissingRequiredParameter;
}

/* --- timers --- */

/* Seconds of host time until the timebase reaches t; +inf if it won't. */
static double
host_delay(CMTimebaseRef tb, CMTime t)
{
    if (!CMTIME_IS_NUMERIC(t))
        return INFINITY;
    double rate = CMTimebaseGetEffectiveRate(tb);
    if (rate == 0)
        return INFINITY;
    double d = (CMTimeGetSeconds(t) - CMTimeGetSeconds(CMTimebaseGetTime(tb))) / rate;
    return d < 0 ? 0 : d;
}

static void
schedule(CMTimebaseRef tb, Timer *t)
{
    double d = host_delay(tb, t->fireTime);
    if (t->dispatch) {
        dispatch_source_t s = (dispatch_source_t)t->timer;
        dispatch_source_set_timer(s, isinf(d) ? DISPATCH_TIME_FOREVER : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * 1e9)), DISPATCH_TIME_FOREVER, 0);
    } else
        CFRunLoopTimerSetNextFireDate((CFRunLoopTimerRef)t->timer, isinf(d) ? 1e18 : CFAbsoluteTimeGetCurrent() + d);
}

static void
reschedule(MutableTimebase tb)
{
    pthread_mutex_lock(&tb->lock);
    for (size_t i = 0; i < tb->timerCount; i++)
        schedule(tb, &tb->timers[i]);
    pthread_mutex_unlock(&tb->lock);
}

static Timer *
find(MutableTimebase tb, CFTypeRef timer)
{
    for (size_t i = 0; i < tb->timerCount; i++)
        if (tb->timers[i].timer == timer)
            return &tb->timers[i];
    return NULL;
}

static OSStatus
add_timer(CMTimebaseRef timebase, CFTypeRef timer, bool dispatch, CFRunLoopRef runLoop)
{
    if (!is_timebase(timebase) || !timer)
        return kCMTimebaseError_MissingRequiredParameter;
    MutableTimebase tb = (MutableTimebase)timebase;
    pthread_mutex_lock(&tb->lock);
    if (find(tb, timer)) {
        pthread_mutex_unlock(&tb->lock);
        return noErr;
    }
    if (tb->timerCount == tb->timerCapacity) {
        size_t c = tb->timerCapacity ? tb->timerCapacity * 2 : 4;
        Timer *t = realloc(tb->timers, c * sizeof *t);
        if (!t) {
            pthread_mutex_unlock(&tb->lock);
            return kCMTimebaseError_AllocationFailed;
        }
        tb->timers = t, tb->timerCapacity = c;
    }
    Timer *t = &tb->timers[tb->timerCount++];
    *t = (Timer){CFRetain(timer), dispatch, runLoop ? (CFRunLoopRef)CFRetain(runLoop) : NULL, kCMTimeInvalid};
    schedule(tb, t);
    pthread_mutex_unlock(&tb->lock);
    /* (a run loop timer is the caller's to add to its run loop, as with Apple's) */
    return noErr;
}

static OSStatus
remove_timer(CMTimebaseRef timebase, CFTypeRef timer)
{
    if (!is_timebase(timebase) || !timer)
        return kCMTimebaseError_MissingRequiredParameter;
    MutableTimebase tb = (MutableTimebase)timebase;
    pthread_mutex_lock(&tb->lock);
    Timer *t = find(tb, timer);
    if (!t) {
        pthread_mutex_unlock(&tb->lock);
        return kCMTimebaseError_InvalidParameter;
    }
    Timer gone = *t;
    *t = tb->timers[--tb->timerCount];
    pthread_mutex_unlock(&tb->lock);
    if (!gone.dispatch) {
        CFRunLoopTimerSetNextFireDate((CFRunLoopTimerRef)gone.timer, 1e18);
        CFRelease(gone.runLoop);
    } else
        dispatch_source_set_timer((dispatch_source_t)gone.timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    CFRelease(gone.timer);
    return noErr;
}

static OSStatus
set_fire_time(CMTimebaseRef timebase, CFTypeRef timer, CMTime fireTime, bool immediately)
{
    if (!is_timebase(timebase) || !timer)
        return kCMTimebaseError_MissingRequiredParameter;
    MutableTimebase tb = (MutableTimebase)timebase;
    pthread_mutex_lock(&tb->lock);
    Timer *t = find(tb, timer);
    OSStatus e = noErr;
    if (!t)
        e = kCMTimebaseError_MissingRequiredParameter;
    else {
        t->fireTime = immediately ? CMTimebaseGetTime(tb) : fireTime;
        schedule(tb, t);
    }
    pthread_mutex_unlock(&tb->lock);
    return e;
}

OSStatus
CMTimebaseAddTimer(CMTimebaseRef timebase, CFRunLoopTimerRef timer, CFRunLoopRef runloop)
{
    if (!runloop)
        return kCMTimebaseError_MissingRequiredParameter;
    return add_timer(timebase, timer, false, runloop);
}

OSStatus
CMTimebaseRemoveTimer(CMTimebaseRef timebase, CFRunLoopTimerRef timer)
{
    return remove_timer(timebase, timer);
}

OSStatus
CMTimebaseSetTimerNextFireTime(CMTimebaseRef timebase, CFRunLoopTimerRef timer, CMTime fireTime, uint32_t flags)
{
    return set_fire_time(timebase, timer, fireTime, false);
}

OSStatus
CMTimebaseSetTimerToFireImmediately(CMTimebaseRef timebase, CFRunLoopTimerRef timer)
{
    return set_fire_time(timebase, timer, kCMTimeInvalid, true);
}

OSStatus
CMTimebaseAddTimerDispatchSource(CMTimebaseRef timebase, dispatch_source_t timerSource)
{
    return add_timer(timebase, (CFTypeRef)(void *)timerSource, true, NULL);
}

OSStatus
CMTimebaseRemoveTimerDispatchSource(CMTimebaseRef timebase, dispatch_source_t timerSource)
{
    return remove_timer(timebase, (CFTypeRef)(void *)timerSource);
}

OSStatus
CMTimebaseSetTimerDispatchSourceNextFireTime(CMTimebaseRef timebase, dispatch_source_t timerSource, CMTime fireTime, uint32_t flags)
{
    return set_fire_time(timebase, (CFTypeRef)(void *)timerSource, fireTime, false);
}

OSStatus
CMTimebaseSetTimerDispatchSourceToFireImmediately(CMTimebaseRef timebase, dispatch_source_t timerSource)
{
    return set_fire_time(timebase, (CFTypeRef)(void *)timerSource, kCMTimeInvalid, true);
}

static CFStringRef
timebase_description(CFTypeRef cf)
{
    CMTimebaseRef tb = (CMTimebaseRef)cf;
    CMTime now = CMTimebaseGetTime(tb);
    CFStringRef t = CMTimeCopyDescription(NULL, now);
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL, CFSTR("FigTimebase: %p  targetTimebase: %p retainCount: %ld allocator: %p master %s: %p rate: %f time: %@ = %f seconds"),
                                             cf, tb->readOnlyOf, (long)CFGetRetainCount(cf), CFGetAllocator(cf), is_clock(tb->source) ? "clock" : "timebase",
                                             tb->source, CMTimebaseGetRate(tb), t, CMTimeGetSeconds(now));
    CFRelease(t);
    return s;
}

/* --- synchronisation --- */

/* The chain from a clock or timebase up to its clock: [x, its source, ...]. */
static size_t
chain(CFTypeRef x, CFTypeRef out[16])
{
    size_t n = 0;
    while (x && n < 16) {
        out[n++] = x;
        x = is_timebase(x) ? ((CMTimebaseRef)x)->source : NULL;
    }
    return n;
}

/* A time on x converted to its source's time, or back. */
static CMTime
up(CFTypeRef x, CMTime t)
{
    if (!is_timebase(x))
        return t;
    CMTimebaseRef tb = (CMTimebaseRef)x;
    if (tb->readOnlyOf)
        return up(tb->readOnlyOf, t);
    pthread_mutex_lock(&((MutableTimebase)tb)->lock);
    CMTime r = source_time_for(tb, t);
    pthread_mutex_unlock(&((MutableTimebase)tb)->lock);
    return r;
}

static CMTime
down(CFTypeRef x, CMTime t)
{
    if (!is_timebase(x))
        return t;
    CMTimebaseRef tb = (CMTimebaseRef)x;
    if (tb->readOnlyOf)
        return down(tb->readOnlyOf, t);
    pthread_mutex_lock(&((MutableTimebase)tb)->lock);
    CMTime r = time_at(tb, t);
    pthread_mutex_unlock(&((MutableTimebase)tb)->lock);
    return r;
}

CMTime
CMSyncConvertTime(CMTime time, CMClockOrTimebaseRef fromClockOrTimebase, CMClockOrTimebaseRef toClockOrTimebase)
{
    if (!fromClockOrTimebase || !toClockOrTimebase)
        return kCMTimeInvalid;
    CFTypeRef a[16], b[16];
    size_t na = chain(fromClockOrTimebase, a), nb = chain(toClockOrTimebase, b);
    /* (up from the one to where the chains meet, then down to the other) */
    for (size_t i = 0; i < na; i++)
        for (size_t j = 0; j < nb; j++)
            if (a[i] == b[j] || (is_clock(a[i]) && is_clock(b[j]))) {
                CMTime t = time;
                for (size_t k = 0; k < i; k++)
                    t = up(a[k], t);
                for (size_t k = j; k-- > 0;)
                    t = down(b[k], t);
                return t;
            }
    return kCMTimeInvalid;
}

static double
rate_to_clock(CFTypeRef x)
{
    double r = 1;
    for (; is_timebase(x); x = ((CMTimebaseRef)x)->source)
        r *= CMTimebaseGetRate((CMTimebaseRef)x);
    return r;
}

Float64
CMSyncGetRelativeRate(CMClockOrTimebaseRef ofClockOrTimebase, CMClockOrTimebaseRef relativeToClockOrTimebase)
{
    if (!ofClockOrTimebase || !relativeToClockOrTimebase)
        return 0;
    /* (along the chain, when one is the other's descendant: the rates between) */
    double r = 1;
    for (CFTypeRef x = ofClockOrTimebase; x; x = is_timebase(x) ? ((CMTimebaseRef)x)->source : NULL) {
        if (x == relativeToClockOrTimebase)
            return r;
        if (!is_timebase(x))
            break;
        r *= CMTimebaseGetRate((CMTimebaseRef)x);
    }
    /* (or the other way: one over the rates between) */
    r = 1;
    for (CFTypeRef x = relativeToClockOrTimebase; x; x = is_timebase(x) ? ((CMTimebaseRef)x)->source : NULL) {
        if (x == ofClockOrTimebase)
            return r ? 1 / r : 0;
        if (!is_timebase(x))
            break;
        r *= CMTimebaseGetRate((CMTimebaseRef)x);
    }
    double other = rate_to_clock(relativeToClockOrTimebase);
    return other ? rate_to_clock(ofClockOrTimebase) / other : 0;
}

OSStatus
CMSyncGetRelativeRateAndAnchorTime(CMClockOrTimebaseRef ofClockOrTimebase, CMClockOrTimebaseRef relativeToClockOrTimebase, Float64 *outRelativeRate,
                                   CMTime *outOfClockOrTimebaseAnchorTime, CMTime *outRelativeToClockOrTimebaseAnchorTime)
{
    if (!ofClockOrTimebase || !relativeToClockOrTimebase)
        return kCMSyncError_MissingRequiredParameter;
    if (outRelativeRate)
        *outRelativeRate = CMSyncGetRelativeRate(ofClockOrTimebase, relativeToClockOrTimebase);
    /* (a timebase directly on the other: its anchor; otherwise both times now) */
    CMTime ofAnchor, relAnchor;
    if (is_timebase(ofClockOrTimebase) && ((CMTimebaseRef)ofClockOrTimebase)->source == relativeToClockOrTimebase) {
        MutableTimebase tb = (MutableTimebase)ofClockOrTimebase;
        pthread_mutex_lock(&tb->lock);
        ofAnchor = tb->anchor;
        relAnchor = tb->sourceAnchor;
        pthread_mutex_unlock(&tb->lock);
    } else {
        ofAnchor = CMSyncGetTime(ofClockOrTimebase);
        relAnchor = CMSyncConvertTime(ofAnchor, ofClockOrTimebase, relativeToClockOrTimebase);
    }
    if (outOfClockOrTimebaseAnchorTime)
        *outOfClockOrTimebaseAnchorTime = ofAnchor;
    if (outRelativeToClockOrTimebaseAnchorTime)
        *outRelativeToClockOrTimebaseAnchorTime = relAnchor;
    return noErr;
}

Boolean
CMSyncMightDrift(CMClockOrTimebaseRef clockOrTimebase1, CMClockOrTimebaseRef clockOrTimebase2)
{
    return false;
}

CMTime
CMSyncGetTime(CMClockOrTimebaseRef clockOrTimebase)
{
    return source_time(clockOrTimebase);
}

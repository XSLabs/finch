/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CMTime, CMTimeRange and CMTimeMapping: rational times as CoreMedia keeps them, with the
 * rules Apple's follows (read from what its functions return; finch-coremedia-test).
 *
 * A time is value/timescale in an epoch, or one of the invalid, +infinite, -infinite and
 * indefinite times. Arithmetic on two times works in a common timescale: the least
 * common multiple of theirs, or kCMTimeMaxTimescale (10^9) when that's larger; where a
 * value overflows, the timescale is halved until it fits (marked rounded if that lost
 * precision), and with no halving left the result is an infinity. Epochs combine as
 * Apple's do: one nonzero epoch carries over, equal ones give epoch 0, different nonzero
 * ones give an invalid time. Times order as -infinity < finite < indefinite < +infinity
 * < invalid, epochs first.
 */
#include "CMInternal.h"
#include <math.h>
#include <stdio.h>

#define MAX_TIMESCALE 1000000000

const CMTime kCMTimeInvalid = {0, 0, 0, 0};
const CMTime kCMTimeIndefinite = {0, 0, kCMTimeFlags_Valid | kCMTimeFlags_Indefinite, 0};
const CMTime kCMTimePositiveInfinity = {0, 0, kCMTimeFlags_Valid | kCMTimeFlags_PositiveInfinity, 0};
const CMTime kCMTimeNegativeInfinity = {0, 0, kCMTimeFlags_Valid | kCMTimeFlags_NegativeInfinity, 0};
const CMTime kCMTimeZero = {0, 1, kCMTimeFlags_Valid, 0};

#define VALID(t) (((t).flags & kCMTimeFlags_Valid) != 0)
#define POSINF(t) (VALID(t) && ((t).flags & kCMTimeFlags_PositiveInfinity))
#define NEGINF(t) (VALID(t) && ((t).flags & kCMTimeFlags_NegativeInfinity))
#define INDEF(t) (VALID(t) && ((t).flags & kCMTimeFlags_Indefinite))
#define NUMERIC(t) (VALID(t) && !((t).flags & kCMTimeFlags_ImpliedValueFlagsMask))

CMTime
CMTimeMake(int64_t value, int32_t timescale)
{
    if (timescale <= 0)
        return kCMTimeInvalid;
    CMTime t = {value, timescale, kCMTimeFlags_Valid, 0};
    return t;
}

CMTime
CMTimeMakeWithEpoch(int64_t value, int32_t timescale, int64_t epoch)
{
    CMTime t = CMTimeMake(value, timescale);
    if (VALID(t))
        t.epoch = epoch;
    return t;
}

/* A double, rounded half away from zero. */
static double
round_half_away(double x)
{
    return x < 0 ? -floor(-x + 0.5) : floor(x + 0.5);
}

static CMTime
make_rounded_time(double seconds, int32_t timescale)
{
    if (timescale <= 0 || isnan(seconds))
        return kCMTimeInvalid;
    if (isinf(seconds))
        return seconds > 0 ? kCMTimePositiveInfinity : kCMTimeNegativeInfinity;
    long double exact = (long double)seconds * timescale;
    long double rounded = exact < 0 ? ceill(exact - 0.5L) : floorl(exact + 0.5L);
    if (rounded > (long double)INT64_MAX || rounded < (long double)INT64_MIN)
        return rounded < 0 ? kCMTimeNegativeInfinity : kCMTimePositiveInfinity;
    CMTime time = {(int64_t)rounded, timescale, kCMTimeFlags_Valid, 0};
    if (rounded != exact)
        time.flags |= kCMTimeFlags_HasBeenRounded;
    return time;
}

CMTime
CMTimeMakeWithSeconds(Float64 seconds, int32_t preferredTimescale)
{
    if (preferredTimescale <= 0)
        return kCMTimeInvalid;
    if (isinf(seconds))
        return seconds > 0 ? kCMTimePositiveInfinity : kCMTimeNegativeInfinity;
    if (isnan(seconds)) {
        CMTime t = {0, preferredTimescale, kCMTimeFlags_Valid | kCMTimeFlags_HasBeenRounded, 0};
        return t;
    }
    int32_t ts = preferredTimescale;
    /* (halving the timescale until the value fits) */
    while (ts > 1 && fabs(seconds * ts) >= 9.2233720368547758e18)
        ts /= 2;
    double exact = seconds * ts;
    if (fabs(exact) >= 9.2233720368547758e18)
        return seconds > 0 ? kCMTimePositiveInfinity : kCMTimeNegativeInfinity;
    /* (truncated, as Apple's are; an error of more than 10 ms is logged, ten times at most) */
    double v = trunc(exact);
    CMTime t = {(int64_t)v, ts, kCMTimeFlags_Valid, 0};
    if (v != exact) {
        t.flags |= kCMTimeFlags_HasBeenRounded;
        double error = v / ts - seconds;
        static _Atomic int warned;
        if (fabs(error) > 0.01 && warned++ < 10)
            cm_log("CMTimeMakeWithSeconds(%.3f seconds, timescale %d): warning: error of %.3f introduced due to very low timescale",
                   seconds, preferredTimescale, error);
    }
    return t;
}

Float64
CMTimeGetSeconds(CMTime time)
{
    if (!VALID(time))
        return NAN;
    if (time.flags & kCMTimeFlags_PositiveInfinity)
        return INFINITY;
    if (time.flags & kCMTimeFlags_NegativeInfinity)
        return -INFINITY;
    if (time.flags & kCMTimeFlags_Indefinite)
        return NAN;
    return (Float64)time.value / (Float64)time.timescale;
}

/* --- exact rational steps --- */

/* value * num / den, rounded by the method; false if it overflows. Sets *inexact. */
static bool
scale(int64_t value, int64_t num, int64_t den, CMTimeRoundingMethod method, bool lowering, int64_t *out, bool *inexact)
{
    __int128 p = (__int128)value * num;
    __int128 q = p / den, r = p % den;
    *inexact = r != 0;
    if (r) {
        bool negative = (p < 0) != (den < 0);
        __int128 twice = r < 0 ? -2 * r : 2 * r;
        __int128 d = den < 0 ? -den : den;
        bool away;
        switch (method) {
        case kCMTimeRoundingMethod_RoundTowardZero: away = false; break;
        case kCMTimeRoundingMethod_RoundAwayFromZero: away = true; break;
        case kCMTimeRoundingMethod_QuickTime: away = !lowering; break;
        case kCMTimeRoundingMethod_RoundTowardPositiveInfinity: away = !negative; break;
        case kCMTimeRoundingMethod_RoundTowardNegativeInfinity: away = negative; break;
        default: away = twice >= d; break; /* half away from zero */
        }
        if (away)
            q += negative ? -1 : 1;
        /* (QuickTime's: a negative time never rounds up to 0) */
        if (method == kCMTimeRoundingMethod_QuickTime && negative && q == 0)
            q = -1;
    }
    if (q > INT64_MAX || q < INT64_MIN)
        return false;
    *out = (int64_t)q;
    return true;
}

static CMTime
infinity_like(bool negative)
{
    return negative ? kCMTimeNegativeInfinity : kCMTimePositiveInfinity;
}

CMTime
CMTimeConvertScale(CMTime time, int32_t newTimescale, CMTimeRoundingMethod method)
{
    if (!VALID(time) || newTimescale <= 0)
        return kCMTimeInvalid;
    if (!NUMERIC(time))
        return time;
    if (time.timescale == newTimescale)
        return time;
    int64_t v;
    bool inexact;
    if (!scale(time.value, newTimescale, time.timescale, method, newTimescale < time.timescale, &v, &inexact))
        return infinity_like(time.value < 0);
    CMTime t = {v, newTimescale, time.flags & ~kCMTimeFlags_HasBeenRounded, time.epoch};
    if (inexact || (time.flags & kCMTimeFlags_HasBeenRounded))
        t.flags |= kCMTimeFlags_HasBeenRounded;
    return t;
}

static int64_t
gcd(int64_t a, int64_t b)
{
    while (b) {
        int64_t r = a % b;
        a = b;
        b = r;
    }
    return a;
}

/* Both numeric times in one timescale (halved where a value overflows). */
static bool
common(CMTime *a, CMTime *b, int32_t *outScale, bool *rounded)
{
    int64_t ts;
    if (a->timescale == b->timescale)
        ts = a->timescale;
    else {
        int64_t l = (int64_t)a->timescale / gcd(a->timescale, b->timescale) * b->timescale;
        ts = l <= INT32_MAX ? l : MAX_TIMESCALE;
    }
    for (;;) {
        int64_t va, vb;
        bool ia = false, ib = false;
        bool ok = scale(a->value, ts, a->timescale, kCMTimeRoundingMethod_Default, ts < a->timescale, &va, &ia) &&
                  scale(b->value, ts, b->timescale, kCMTimeRoundingMethod_Default, ts < b->timescale, &vb, &ib);
        if (ok) {
            *rounded = ia || ib;
            a->value = va, b->value = vb;
            a->timescale = b->timescale = (int32_t)ts;
            *outScale = (int32_t)ts;
            return true;
        }
        if (ts <= 1)
            return false;
        ts /= 2;
    }
}

/* The epoch two times combine to, or -1 for none (different nonzero epochs). */
static bool
combined_epoch(CMTime a, CMTime b, int64_t *epoch)
{
    if (a.epoch == b.epoch)
        *epoch = 0;
    else if (!a.epoch)
        *epoch = b.epoch;
    else if (!b.epoch)
        *epoch = a.epoch;
    else
        return false;
    return true;
}

static CMTime
add_sub(CMTime a, CMTime b, bool subtract)
{
    if (!VALID(a) || !VALID(b))
        return kCMTimeInvalid;
    bool aPos = POSINF(a), aNeg = NEGINF(a), bPos = POSINF(b), bNeg = NEGINF(b);
    if (subtract) {
        bool t = bPos;
        bPos = bNeg;
        bNeg = t;
    }
    if (aPos || aNeg || bPos || bNeg) {
        if ((aPos && bNeg) || (aNeg && bPos))
            return kCMTimeInvalid;
        return infinity_like(aNeg || bNeg);
    }
    if (INDEF(a) || INDEF(b))
        return kCMTimeIndefinite;
    int64_t epoch;
    if (!combined_epoch(a, b, &epoch))
        return kCMTimeInvalid;
    bool rounded = (a.flags | b.flags) & kCMTimeFlags_HasBeenRounded;
    for (;;) {
        CMTime x = a, y = b;
        int32_t ts;
        bool r = false;
        if (!common(&x, &y, &ts, &r))
            return infinity_like(subtract ? (a.value < 0 && b.value > 0) || (a.value < b.value) : a.value < 0);
        __int128 v = subtract ? (__int128)x.value - y.value : (__int128)x.value + y.value;
        if (v <= INT64_MAX && v >= INT64_MIN) {
            CMTime t = {(int64_t)v, ts, kCMTimeFlags_Valid, epoch};
            if (r || rounded)
                t.flags |= kCMTimeFlags_HasBeenRounded;
            return t;
        }
        /* (the sum overflows: half the timescale, if there is one to halve) */
        if (ts <= 1)
            return infinity_like(v < 0);
        a = CMTimeConvertScale(a, ts / 2, kCMTimeRoundingMethod_Default);
        b = CMTimeConvertScale(b, ts / 2, kCMTimeRoundingMethod_Default);
        if (!NUMERIC(a) || !NUMERIC(b))
            return infinity_like(v < 0);
        rounded = rounded || ((a.flags | b.flags) & kCMTimeFlags_HasBeenRounded);
    }
}

CMTime CMTimeAdd(CMTime lhs, CMTime rhs) { return add_sub(lhs, rhs, false); }
CMTime CMTimeSubtract(CMTime lhs, CMTime rhs) { return add_sub(lhs, rhs, true); }

CMTime
CMTimeMultiply(CMTime time, int32_t multiplier)
{
    if (!VALID(time) || INDEF(time))
        return time;
    if (POSINF(time) || NEGINF(time))
        return multiplier == 0 ? kCMTimeInvalid : infinity_like(NEGINF(time) != (multiplier < 0));
    __int128 v = (__int128)time.value * multiplier;
    if (v > INT64_MAX || v < INT64_MIN)
        return infinity_like(v < 0);
    time.value = (int64_t)v;
    return time;
}

CMTime
CMTimeMultiplyByFloat64(CMTime time, Float64 multiplier)
{
    if (!VALID(time) || INDEF(time))
        return time;
    if (POSINF(time) || NEGINF(time))
        return multiplier == 0 ? kCMTimeInvalid : infinity_like(NEGINF(time) != (multiplier < 0));
    /* A whole product stays in the timescale; at 10^9 and above a fraction rounds there
       (half away from zero); below, the product moves to 10^9, rounded away from zero. */
    double product = (double)time.value * multiplier;
    if (product == trunc(product) || time.timescale >= MAX_TIMESCALE) {
        double v = round_half_away(product);
        if (fabs(v) >= 9.2233720368547758e18)
            return infinity_like(v < 0);
        time.value = (int64_t)v;
        if (fabs(product) >= 9007199254740992.0)
            time.flags |= kCMTimeFlags_HasBeenRounded;
        return time;
    }
    /* (exact unless a step loses something, which fma's remainders show) */
    double lost = fma((double)time.value, multiplier, -product);
    double n = product * MAX_TIMESCALE;
    lost = lost * MAX_TIMESCALE + fma(product, MAX_TIMESCALE, -n);
    double scaled = n / time.timescale;
    double rest = fma(scaled, time.timescale, -n);
    double v = scaled < 0 ? floor(scaled) : ceil(scaled);
    bool exact = v == scaled && rest == 0 && lost == 0;
    if (v == scaled && (scaled < 0 ? lost - rest < 0 : lost - rest > 0))
        v += scaled < 0 ? -1 : 1;
    if (fabs(v) >= 9.2233720368547758e18)
        return infinity_like(v < 0);
    time.value = (int64_t)v;
    time.timescale = MAX_TIMESCALE;
    if (!exact)
        time.flags |= kCMTimeFlags_HasBeenRounded;
    return time;
}

CMTime
CMTimeMultiplyByRatio(CMTime time, int32_t multiplier, int32_t divisor)
{
    if (!VALID(time))
        return kCMTimeInvalid;
    if (INDEF(time))
        return time;
    if (POSINF(time) || NEGINF(time))
        return multiplier == 0 ? kCMTimeInvalid : infinity_like(NEGINF(time) != ((multiplier < 0) != (divisor < 0)));
    if (divisor == 0)
        return !time.value || !multiplier ? kCMTimeInvalid : infinity_like((time.value < 0) != (multiplier < 0));
    int64_t numeratorFactor = multiplier, denominatorFactor = divisor;
    if (denominatorFactor < 0)
        numeratorFactor = -numeratorFactor, denominatorFactor = -denominatorFactor;
    /* the exact time: value*multiplier / (timescale*divisor), in lowest terms */
    __int128 num = (__int128)time.value * numeratorFactor, den = (__int128)time.timescale * denominatorFactor;
    int64_t g = gcd(numeratorFactor < 0 ? -numeratorFactor : numeratorFactor, denominatorFactor);
    if (g > 1) {
        num /= g;
        den /= g;
    }
    if (den <= INT32_MAX && num <= INT64_MAX && num >= INT64_MIN && den <= MAX_TIMESCALE) {
        CMTime t = {(int64_t)num, (int32_t)den, time.flags, time.epoch};
        return t;
    }
    if (den <= INT32_MAX && num <= INT64_MAX && num >= INT64_MIN && time.timescale * denominatorFactor == den && den > MAX_TIMESCALE &&
        time.timescale > MAX_TIMESCALE) {
        CMTime t = {(int64_t)num, (int32_t)den, time.flags, time.epoch};
        return t;
    }
    /* (in kCMTimeMaxTimescale, rounded) */
    __int128 scaled = num * MAX_TIMESCALE;
    __int128 q = scaled / den, r = scaled % den;
    if (r && (r < 0 ? -2 * r : 2 * r) >= den)
        q += scaled < 0 ? -1 : 1;
    if (q > INT64_MAX || q < INT64_MIN)
        return infinity_like(q < 0);
    CMTime t = {(int64_t)q, MAX_TIMESCALE, time.flags, time.epoch};
    if (r)
        t.flags |= kCMTimeFlags_HasBeenRounded;
    return t;
}

/* -infinity < finite < indefinite < +infinity < invalid; epochs first, then values. */
static int
rank(CMTime t)
{
    if (!VALID(t))
        return 4;
    if (t.flags & kCMTimeFlags_PositiveInfinity)
        return 3;
    if (t.flags & kCMTimeFlags_Indefinite)
        return 2;
    if (t.flags & kCMTimeFlags_NegativeInfinity)
        return 0;
    return 1;
}

int32_t
CMTimeCompare(CMTime time1, CMTime time2)
{
    int r1 = rank(time1), r2 = rank(time2);
    if (r1 != r2)
        return r1 < r2 ? -1 : 1;
    if (r1 != 1)
        return 0;
    if (time1.epoch != time2.epoch)
        return time1.epoch < time2.epoch ? -1 : 1;
    __int128 a = (__int128)time1.value * time2.timescale, b = (__int128)time2.value * time1.timescale;
    return a < b ? -1 : a > b ? 1 : 0;
}

/* (an invalid time is passed over) */
CMTime
CMTimeMinimum(CMTime time1, CMTime time2)
{
    if (!VALID(time1))
        return time2;
    if (!VALID(time2))
        return time1;
    return CMTimeCompare(time1, time2) <= 0 ? time1 : time2;
}

CMTime
CMTimeMaximum(CMTime time1, CMTime time2)
{
    if (!VALID(time1))
        return time2;
    if (!VALID(time2))
        return time1;
    return CMTimeCompare(time1, time2) >= 0 ? time1 : time2;
}

CMTime
CMTimeAbsoluteValue(CMTime time)
{
    if (NEGINF(time))
        return kCMTimePositiveInfinity;
    if (NUMERIC(time) && time.value < 0) {
        if (time.value == INT64_MIN)
            return kCMTimePositiveInfinity;
        time.value = -time.value;
    }
    return time;
}

/* --- descriptions and dictionaries --- */

const CFStringRef kCMTimeValueKey = CFSTR("value");
const CFStringRef kCMTimeScaleKey = CFSTR("timescale");
const CFStringRef kCMTimeEpochKey = CFSTR("epoch");
const CFStringRef kCMTimeFlagsKey = CFSTR("flags");

CFDictionaryRef
CMTimeCopyAsDictionary(CMTime time, CFAllocatorRef allocator)
{
    int64_t flags = time.flags;
    CFNumberRef v = CFNumberCreate(allocator, kCFNumberSInt64Type, &time.value);
    CFNumberRef s = CFNumberCreate(allocator, kCFNumberSInt32Type, &time.timescale);
    CFNumberRef f = CFNumberCreate(allocator, kCFNumberSInt32Type, &time.flags);
    CFNumberRef e = CFNumberCreate(allocator, kCFNumberSInt64Type, &time.epoch);
    (void)flags;
    const void *keys[] = {kCMTimeValueKey, kCMTimeScaleKey, kCMTimeFlagsKey, kCMTimeEpochKey};
    const void *values[] = {v, s, f, e};
    CFDictionaryRef d = CFDictionaryCreate(allocator, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(v);
    CFRelease(s);
    CFRelease(f);
    CFRelease(e);
    return d;
}

static bool
number(CFDictionaryRef d, CFStringRef key, CFNumberType type, void *out)
{
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, type, out);
}

CMTime
CMTimeMakeFromDictionary(CFDictionaryRef dictionaryRepresentation)
{
    if (!dictionaryRepresentation || CFGetTypeID(dictionaryRepresentation) != CFDictionaryGetTypeID())
        return kCMTimeInvalid;
    CMTime t = kCMTimeInvalid;
    if (!number(dictionaryRepresentation, kCMTimeValueKey, kCFNumberSInt64Type, &t.value) ||
        !number(dictionaryRepresentation, kCMTimeScaleKey, kCFNumberSInt32Type, &t.timescale) ||
        !number(dictionaryRepresentation, kCMTimeFlagsKey, kCFNumberSInt32Type, &t.flags))
        return kCMTimeInvalid;
    number(dictionaryRepresentation, kCMTimeEpochKey, kCFNumberSInt64Type, &t.epoch);
    return t;
}

CFStringRef
CMTimeCopyDescription(CFAllocatorRef allocator, CMTime time)
{
    if (!VALID(time))
        return CFStringCreateWithCString(allocator, "{INVALID}", kCFStringEncodingUTF8);
    if (time.flags & kCMTimeFlags_PositiveInfinity)
        return CFStringCreateWithCString(allocator, "{+INFINITY}", kCFStringEncodingUTF8);
    if (time.flags & kCMTimeFlags_NegativeInfinity)
        return CFStringCreateWithCString(allocator, "{-INFINITY}", kCFStringEncodingUTF8);
    if (time.flags & kCMTimeFlags_Indefinite)
        return CFStringCreateWithCString(allocator, "{INDEFINITE}", kCFStringEncodingUTF8);
    char buf[256];
    int n = snprintf(buf, sizeof buf, "{%lld/%d = %.3f", (long long)time.value, time.timescale, CMTimeGetSeconds(time));
    if (time.epoch)
        n += snprintf(buf + n, sizeof buf - (size_t)n, ", epoch=%lld", (long long)time.epoch);
    if (time.flags & kCMTimeFlags_HasBeenRounded)
        n += snprintf(buf + n, sizeof buf - (size_t)n, ", rounded");
    snprintf(buf + n, sizeof buf - (size_t)n, "}");
    return CFStringCreateWithCString(allocator, buf, kCFStringEncodingUTF8);
}

void
CMTimeShow(CMTime time)
{
    CFStringRef s = CMTimeCopyDescription(NULL, time);
    char buf[256];
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    fprintf(stderr, "%s\n", buf);
}

/* --- ranges --- */

const CMTimeRange kCMTimeRangeZero = {{0, 1, kCMTimeFlags_Valid, 0}, {0, 1, kCMTimeFlags_Valid, 0}};
const CMTimeRange kCMTimeRangeInvalid = {{0, 0, 0, 0}, {0, 0, 0, 0}};

CMTimeRange
CMTimeRangeMake(CMTime start, CMTime duration)
{
    if (!VALID(start) || !VALID(duration) || duration.epoch != 0)
        return kCMTimeRangeInvalid;
    CMTimeRange r = {start, duration};
    return r;
}

CMTime
CMTimeRangeGetEnd(CMTimeRange range)
{
    return CMTimeAdd(range.start, range.duration);
}

CMTimeRange
CMTimeRangeFromTimeToTime(CMTime start, CMTime end)
{
    if (!VALID(start) || !VALID(end) || CMTimeCompare(end, start) < 0)
        return kCMTimeRangeInvalid;
    return CMTimeRangeMake(start, CMTimeSubtract(end, start));
}

CMTimeRange
CMTimeRangeGetUnion(CMTimeRange range, CMTimeRange otherRange)
{
    CMTime start = CMTimeMinimum(range.start, otherRange.start);
    CMTime end = CMTimeMaximum(CMTimeRangeGetEnd(range), CMTimeRangeGetEnd(otherRange));
    return CMTimeRangeFromTimeToTime(start, end);
}

CMTimeRange
CMTimeRangeGetIntersection(CMTimeRange range, CMTimeRange otherRange)
{
    CMTime start = CMTimeMaximum(range.start, otherRange.start);
    CMTime end = CMTimeMinimum(CMTimeRangeGetEnd(range), CMTimeRangeGetEnd(otherRange));
    if (CMTimeCompare(end, start) <= 0)
        return kCMTimeRangeZero;
    return CMTimeRangeFromTimeToTime(start, end);
}

Boolean
CMTimeRangeEqual(CMTimeRange range1, CMTimeRange range2)
{
    return CMTimeCompare(range1.start, range2.start) == 0 && CMTimeCompare(range1.duration, range2.duration) == 0;
}

Boolean
CMTimeRangeContainsTime(CMTimeRange range, CMTime time)
{
    return CMTimeCompare(time, range.start) >= 0 && CMTimeCompare(time, CMTimeRangeGetEnd(range)) < 0;
}

Boolean
CMTimeRangeContainsTimeRange(CMTimeRange range, CMTimeRange otherRange)
{
    return CMTimeCompare(otherRange.start, range.start) >= 0 &&
           CMTimeCompare(CMTimeRangeGetEnd(otherRange), CMTimeRangeGetEnd(range)) <= 0;
}

CMTime
CMTimeClampToRange(CMTime time, CMTimeRange range)
{
    if (CMTimeCompare(time, range.start) < 0)
        return range.start;
    CMTime end = CMTimeRangeGetEnd(range);
    if (CMTimeCompare(time, end) > 0)
        return end;
    return time;
}

/* Where a time in one range falls in the other, proportionally. */
CMTime
CMTimeMapTimeFromRangeToRange(CMTime t, CMTimeRange fromRange, CMTimeRange toRange)
{
    if (!NUMERIC(t) || !NUMERIC(fromRange.start) || !NUMERIC(fromRange.duration) ||
        !NUMERIC(toRange.start) || !NUMERIC(toRange.duration) || t.epoch != fromRange.start.epoch)
        return kCMTimeInvalid;
    CMTime offset = CMTimeSubtract(t, fromRange.start);
    double f = CMTimeGetSeconds(fromRange.duration);
    double scaled = f != 0 ? CMTimeGetSeconds(offset) * CMTimeGetSeconds(toRange.duration) / f : 0;
    CMTime result = CMTimeAdd(toRange.start, make_rounded_time(scaled, MAX_TIMESCALE));
    result.epoch = 0;
    return result;
}

CMTime
CMTimeMapDurationFromRangeToRange(CMTime dur, CMTimeRange fromRange, CMTimeRange toRange)
{
    if (!NUMERIC(dur) || !NUMERIC(fromRange.duration) || !NUMERIC(toRange.duration) || dur.epoch != 0)
        return kCMTimeInvalid;
    double f = CMTimeGetSeconds(fromRange.duration);
    double scaled = f != 0 ? CMTimeGetSeconds(dur) * CMTimeGetSeconds(toRange.duration) / f : 0;
    return make_rounded_time(scaled, MAX_TIMESCALE);
}

/* A time folded into a range, as if the range repeated. */
CMTime
CMTimeFoldIntoRange(CMTime time, CMTimeRange foldRange)
{
    if (!NUMERIC(time) || !NUMERIC(foldRange.duration) || foldRange.duration.value <= 0)
        return time;
    CMTime offset = CMTimeSubtract(time, foldRange.start), d = foldRange.duration, x = offset, y = d;
    int32_t ts;
    bool r;
    if (!common(&x, &y, &ts, &r))
        return time;
    int64_t m = x.value % y.value;
    if (m < 0)
        m += y.value;
    CMTime folded = {m, ts, kCMTimeFlags_Valid, time.epoch};
    return CMTimeAdd(foldRange.start, folded);
}

const CFStringRef kCMTimeRangeStartKey = CFSTR("start");
const CFStringRef kCMTimeRangeDurationKey = CFSTR("duration");

CFDictionaryRef
CMTimeRangeCopyAsDictionary(CMTimeRange range, CFAllocatorRef allocator)
{
    CFDictionaryRef s = CMTimeCopyAsDictionary(range.start, allocator), d = CMTimeCopyAsDictionary(range.duration, allocator);
    const void *keys[] = {kCMTimeRangeStartKey, kCMTimeRangeDurationKey}, *values[] = {s, d};
    CFDictionaryRef r = CFDictionaryCreate(allocator, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(s);
    CFRelease(d);
    return r;
}

CMTimeRange
CMTimeRangeMakeFromDictionary(CFDictionaryRef dictionaryRepresentation)
{
    if (!dictionaryRepresentation)
        return kCMTimeRangeInvalid;
    return CMTimeRangeMake(CMTimeMakeFromDictionary(CFDictionaryGetValue(dictionaryRepresentation, kCMTimeRangeStartKey)),
                           CMTimeMakeFromDictionary(CFDictionaryGetValue(dictionaryRepresentation, kCMTimeRangeDurationKey)));
}

CFStringRef
CMTimeRangeCopyDescription(CFAllocatorRef allocator, CMTimeRange range)
{
    CFStringRef s = CMTimeCopyDescription(allocator, range.start), d = CMTimeCopyDescription(allocator, range.duration);
    CFStringRef r = CFStringCreateWithFormat(allocator, NULL, CFSTR("{%@, %@}"), s, d);
    CFRelease(s);
    CFRelease(d);
    return r;
}

void
CMTimeRangeShow(CMTimeRange range)
{
    CFStringRef s = CMTimeRangeCopyDescription(NULL, range);
    char buf[512];
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    fprintf(stderr, "%s\n", buf);
}

/* --- mappings --- */

const CMTimeMapping kCMTimeMappingInvalid = {{{0, 0, 0, 0}, {0, 0, 0, 0}}, {{0, 0, 0, 0}, {0, 0, 0, 0}}};

CMTimeMapping
CMTimeMappingMake(CMTimeRange source, CMTimeRange target)
{
    CMTimeMapping m = {source, target};
    return m;
}

CMTimeMapping
CMTimeMappingMakeEmpty(CMTimeRange target)
{
    CMTimeMapping m = {kCMTimeRangeInvalid, target};
    return m;
}

const CFStringRef kCMTimeMappingSourceKey = CFSTR("source");
const CFStringRef kCMTimeMappingTargetKey = CFSTR("target");

CFDictionaryRef
CMTimeMappingCopyAsDictionary(CMTimeMapping mapping, CFAllocatorRef allocator)
{
    CFDictionaryRef s = CMTimeRangeCopyAsDictionary(mapping.source, allocator), t = CMTimeRangeCopyAsDictionary(mapping.target, allocator);
    const void *keys[] = {kCMTimeMappingSourceKey, kCMTimeMappingTargetKey}, *values[] = {s, t};
    CFDictionaryRef r = CFDictionaryCreate(allocator, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(s);
    CFRelease(t);
    return r;
}

CMTimeMapping
CMTimeMappingMakeFromDictionary(CFDictionaryRef dictionaryRepresentation)
{
    if (!dictionaryRepresentation)
        return kCMTimeMappingInvalid;
    return CMTimeMappingMake(CMTimeRangeMakeFromDictionary(CFDictionaryGetValue(dictionaryRepresentation, kCMTimeMappingSourceKey)),
                             CMTimeRangeMakeFromDictionary(CFDictionaryGetValue(dictionaryRepresentation, kCMTimeMappingTargetKey)));
}

CFStringRef
CMTimeMappingCopyDescription(CFAllocatorRef allocator, CMTimeMapping mapping)
{
    CFStringRef s = CMTimeRangeCopyDescription(allocator, mapping.source), t = CMTimeRangeCopyDescription(allocator, mapping.target);
    CFStringRef r = CFStringCreateWithFormat(allocator, NULL, CFSTR("{%@, %@}"), s, t);
    CFRelease(s);
    CFRelease(t);
    return r;
}

void
CMTimeMappingShow(CMTimeMapping mapping)
{
    CFStringRef s = CMTimeMappingCopyDescription(NULL, mapping);
    char buf[1024];
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    fprintf(stderr, "%s\n", buf);
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "CarbonCore_Finch.h"
#include <math.h>
#include <time.h>

#define FINCH_CF_EPOCH_FROM_1904 3061152000.0
#define FINCH_UNIX_EPOCH_FROM_CF 978307200.0
#define FINCH_UNIX_EPOCH_FROM_1904 2082844800LL
#define FINCH_UTC_MAX_SECONDS 0x0000ffffffffffffULL

static UInt64
utc_seconds(const UTCDateTime *date)
{
    return ((UInt64)date->highSeconds << 32) | date->lowSeconds;
}

static void
utc_set_seconds(UTCDateTime *date, UInt64 seconds)
{
    date->highSeconds = (UInt16)(seconds >> 32);
    date->lowSeconds = (UInt32)seconds;
}

static Boolean
local_seconds_to_cf(SInt64 seconds, CFAbsoluteTime *result)
{
    SInt64 unixWall = seconds - FINCH_UNIX_EPOCH_FROM_1904;
    time_t wall = (time_t)unixWall;
    struct tm fields;
    if ((SInt64)wall != unixWall || !gmtime_r(&wall, &fields))
        goto timezone_fallback;
    time_t unixTime = mktime(&fields);
    if (unixTime == (time_t)-1)
        goto timezone_fallback;
    *result = (CFAbsoluteTime)unixTime - FINCH_UNIX_EPOCH_FROM_CF;
    return true;

timezone_fallback: {
    CFTimeZoneRef zone = CFTimeZoneCopySystem();
    if (!zone)
        return false;
    CFAbsoluteTime approximate = (CFAbsoluteTime)seconds - FINCH_CF_EPOCH_FROM_1904;
    CFTimeInterval offset = CFTimeZoneGetSecondsFromGMT(zone, approximate);
    CFRelease(zone);
    *result = approximate - offset;
    return true;
}
}

static Boolean
cf_to_local_seconds(CFAbsoluteTime value, SInt64 *result)
{
    if (!isfinite(value))
        return false;
    CFTimeZoneRef zone = CFTimeZoneCopySystem();
    if (!zone)
        return false;
    CFTimeInterval offset = CFTimeZoneGetSecondsFromGMT(zone, value);
    CFRelease(zone);
    double unixValue = floor(value + FINCH_CF_EPOCH_FROM_1904 + offset);
    if (unixValue < (double)INT64_MIN || unixValue >= 9223372036854775808.0)
        return false;
    *result = (SInt64)unixValue;
    return true;
}

OSStatus
UCConvertUTCDateTimeToCFAbsoluteTime(const UTCDateTime *iUTCDate, CFAbsoluteTime *oCFTime)
{
    if (!iUTCDate || !oCFTime)
        return paramErr;
    *oCFTime = (CFAbsoluteTime)utc_seconds(iUTCDate) - FINCH_CF_EPOCH_FROM_1904 +
               (CFAbsoluteTime)iUTCDate->fraction / 65536.0;
    return noErr;
}

OSStatus
UCConvertSecondsToCFAbsoluteTime(UInt32 iSeconds, CFAbsoluteTime *oCFTime)
{
    if (!oCFTime)
        return paramErr;
    return local_seconds_to_cf(iSeconds, oCFTime) ? noErr : paramErr;
}

OSStatus
UCConvertLongDateTimeToCFAbsoluteTime(LongDateTime iLongTime, CFAbsoluteTime *oCFTime)
{
    if (!oCFTime)
        return paramErr;
    return local_seconds_to_cf(iLongTime, oCFTime) ? noErr : paramErr;
}

OSStatus
UCConvertCFAbsoluteTimeToUTCDateTime(CFAbsoluteTime iCFTime, UTCDateTime *oUTCDate)
{
    if (!oUTCDate || !isfinite(iCFTime))
        return paramErr;
    double seconds = floor(iCFTime + FINCH_CF_EPOCH_FROM_1904);
    double fraction = iCFTime + FINCH_CF_EPOCH_FROM_1904 - seconds;
    if (seconds < 0 || seconds > (double)FINCH_UTC_MAX_SECONDS)
        return paramErr;
    UInt64 fractionBits = (UInt64)llround(fraction * 65536.0);
    if (fractionBits == 65536) {
        seconds += 1.0;
        fractionBits = 0;
    }
    if (seconds > (double)FINCH_UTC_MAX_SECONDS)
        return paramErr;
    utc_set_seconds(oUTCDate, (UInt64)seconds);
    oUTCDate->fraction = (UInt16)fractionBits;
    return noErr;
}

OSStatus
UCConvertCFAbsoluteTimeToSeconds(CFAbsoluteTime iCFTime, UInt32 *oSeconds)
{
    SInt64 seconds;
    if (!oSeconds || !cf_to_local_seconds(iCFTime, &seconds))
        return paramErr;
    *oSeconds = (UInt32)seconds;
    return noErr;
}

OSStatus
UCConvertCFAbsoluteTimeToLongDateTime(CFAbsoluteTime iCFTime, LongDateTime *oLongDate)
{
    SInt64 seconds;
    if (!oLongDate || !cf_to_local_seconds(iCFTime, &seconds))
        return paramErr;
    *oLongDate = (LongDateTime)seconds;
    return noErr;
}

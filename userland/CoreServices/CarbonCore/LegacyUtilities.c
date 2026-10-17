/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Classic utility calls whose behavior still has a clear macOS equivalent. */
#include "CarbonCore_Finch.h"
#include <CoreFoundation/CFLocale.h>
#include <CoreFoundation/CFTimeZone.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

Boolean
IsMetric(void)
{
    /* The modern Carbon API has no classic numeric-format resource to read. */
    return false;
}

void
ReadLocation(MachineLocation *location)
{
    if (!location)
        return;
    memset(location, 0, sizeof *location);
    CFTimeZoneRef zone = CFTimeZoneCopyDefault();
    if (!zone)
        return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    SInt32 offset = (SInt32)CFTimeZoneGetSecondsFromGMT(zone, now);
    Boolean daylight = CFTimeZoneIsDaylightSavingTime(zone, now);
    CFRelease(zone);
    UInt32 packed = ((UInt32)offset & 0x00ffffffu) | (daylight ? 0x80000000u : 0);
    location->u.gmtDelta = (long)(SInt32)packed;
}

UInt32
TaskLevel(void)
{
    /* macOS has no interrupt task levels; the Carbon API specifies zero. */
    return 0;
}

long
Munger(Handle handle, long offset, const void *findBytes, long findLength,
       const void *replaceBytes, long replaceLength)
{
    if (!handle || !*handle || offset < 0 || findLength < 0 || replaceLength < 0 ||
        (findLength && !findBytes) || (replaceLength && !replaceBytes))
        return -1;
    Size oldSize = GetHandleSize(handle);
    if (oldSize < 0 || offset > oldSize || (Size)findLength > oldSize - offset)
        return -1;

    UInt8 *bytes = (UInt8 *)*handle;
    Size found = -1;
    if (!findLength) {
        found = (Size)offset;
    } else {
        for (Size index = (Size)offset; index <= oldSize - findLength; index++) {
            if (memcmp(bytes + index, findBytes, (size_t)findLength) == 0) {
                found = index;
                break;
            }
        }
    }
    if (found < 0 || (Size)replaceLength > LONG_MAX - oldSize + findLength)
        return -1;

    Size newSize = oldSize - (Size)findLength + (Size)replaceLength;
    UInt8 *result = newSize ? malloc((size_t)newSize) : NULL;
    if (newSize && !result)
        return -1;
    if (found)
        memcpy(result, bytes, (size_t)found);
    if (replaceLength)
        memcpy(result + found, replaceBytes, (size_t)replaceLength);
    Size suffixStart = found + findLength;
    Size suffixLength = oldSize - suffixStart;
    if (suffixLength)
        memcpy(result + found + replaceLength, bytes + suffixStart, (size_t)suffixLength);

    SetHandleSize(handle, newSize);
    if (MemError() != noErr) {
        free(result);
        return -1;
    }
    bytes = (UInt8 *)*handle;
    if (newSize)
        memcpy(bytes, result, (size_t)newSize);
    free(result);
    return (long)found + 1;
}

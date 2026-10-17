/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Conversion between Carbon's bounded HFS name and CoreFoundation strings. */
#include "CarbonCore_Finch.h"

CFStringRef
FSCreateStringFromHFSUniStr(CFAllocatorRef allocator, const HFSUniStr255 *uniString)
{
    if (!uniString || uniString->length > 255)
        return NULL;
    return CFStringCreateWithCharacters(allocator, uniString->unicode, uniString->length);
}

OSStatus
FSGetHFSUniStrFromString(CFStringRef string, HFSUniStr255 *uniString)
{
    if (!string || !uniString)
        return paramErr;
    CFIndex length = CFStringGetLength(string);
    if (length > 255)
        return bdNamErr;
    uniString->length = (UInt16)length;
    if (length)
        CFStringGetCharacters(string, CFRangeMake(0, length), uniString->unicode);
    return noErr;
}

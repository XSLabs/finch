/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* String helpers used by the Swift runtime. A tagged string holds up to
 * seven ASCII characters (NSConstantObjects_Finch.m); anything else is NULL,
 * and the caller makes an ordinary string. */
#include "CFObjCClasses_Finch.h"

CF_PRIVATE id __CFFinchCreateTaggedString(const uint8_t *bytes, CFIndex count);

CFStringRef
_CFStringCreateTaggedPointerString(const uint8_t *bytes, CFIndex count)
{
    return (CFStringRef)__CFFinchCreateTaggedString(bytes, count);
}

BOOL
_NSIsNSString(id object)
{
    return [object isKindOfClass:[NSString class]];
}

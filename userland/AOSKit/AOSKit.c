/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AOSKit (private), Finch's own: Apple's iCloud ("Apple Online Services") account calls.
 * Finch has no iCloud, so there's never an account: creating one gives NULL, retrieving
 * its information fails, and a transaction reports an error in AOSErrorDomain. The keys
 * have Apple's values.
 */
#include <CoreFoundation/CoreFoundation.h>

#define AOS_EXPORT __attribute__((visibility("default")))

AOS_EXPORT const CFStringRef kAOSAppleAccountInfoKey = CFSTR("appleAccountInfo");
AOS_EXPORT const CFStringRef kAOSErrorDomain = CFSTR("AOSErrorDomain");
AOS_EXPORT const CFStringRef kAOSMMeInfoKey = CFSTR("com.apple.mobileme");
AOS_EXPORT const CFStringRef kAOSPersonIDKey = CFSTR("dsPrsID");
AOS_EXPORT const CFStringRef kAOSTokensKey = CFSTR("tokens");
AOS_EXPORT const CFStringRef kAOSURLKey = CFSTR("url");

typedef struct __AOSAccount *AOSAccountRef;
typedef struct __AOSTransaction *AOSTransactionRef;

/* No account to create. */
AOS_EXPORT AOSAccountRef
AOSAccountCreate(CFAllocatorRef allocator, CFStringRef accountType, CFStringRef userName)
{
    return NULL;
}

AOS_EXPORT Boolean
_AOSAccountRetrieveInfo(AOSAccountRef account, CFDictionaryRef options, void *callback, void *context)
{
    return false;
}

AOS_EXPORT Boolean
AOSTransactionSuccessful(AOSTransactionRef t)
{
    return false;
}

AOS_EXPORT CFTypeRef
AOSTransactionGetResult(AOSTransactionRef t)
{
    return NULL;
}

AOS_EXPORT CFErrorRef
AOSTransactionGetError(AOSTransactionRef t)
{
    static CFErrorRef none;
    if (!none)
        none = CFErrorCreate(NULL, kAOSErrorDomain, -1, NULL);
    return none;
}

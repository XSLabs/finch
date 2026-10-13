/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Values used by the private Finch keychain service protocol. */
#ifndef FINCH_SEC_KEYCHAIN_SERVICE_WIRE_H
#define FINCH_SEC_KEYCHAIN_SERVICE_WIRE_H

#include "SecInternal.h"

SEC_HIDDEN SecKeychainRef _FinchKeychainCreateLocalReference(CFStringRef path);
SEC_HIDDEN SecKeychainItemRef _FinchKeychainCreateItemProxy(CFDataRef persistentRef);
SEC_HIDDEN CFPropertyListRef _FinchKeychainWireEncode(CFTypeRef value);
SEC_HIDDEN CFTypeRef _FinchKeychainWireDecode(CFPropertyListRef value,
    bool makeClientProxies);

#endif

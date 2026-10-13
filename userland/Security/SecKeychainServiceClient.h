/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Private Finch keychain-service transport. */
#ifndef FINCH_SEC_KEYCHAIN_SERVICE_CLIENT_H
#define FINCH_SEC_KEYCHAIN_SERVICE_CLIENT_H

#include "SecInternal.h"
#include "SecKeychainServiceProtocol.h"

/* True in a Finch guest. An absent service in a guest is an error, never a
 * reason to use this process's own key cache or file backend. */
SEC_HIDDEN bool _FinchKeychainServiceRequired(void);

/* Send a property-list request to the per-user service. The reply is another
 * property list when requested. */
SEC_HIDDEN OSStatus _FinchKeychainServiceCall(CFStringRef operation,
    CFPropertyListRef request, CFPropertyListRef *response);

#endif

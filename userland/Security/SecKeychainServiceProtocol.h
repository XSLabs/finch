/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SEC_KEYCHAIN_SERVICE_PROTOCOL_H
#define FINCH_SEC_KEYCHAIN_SERVICE_PROTOCOL_H

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#define FINCH_KEYCHAIN_SERVICE_NAME "org.finch.securityd"
#define FINCH_KEYCHAIN_SERVICE_VERSION 1
#define FINCH_KEYCHAIN_SERVICE_MAX_MESSAGE (16U * 1024U * 1024U)

/* The values come from the kernel's XPC audit token, not the request body. */
static inline bool
_FinchKeychainServiceTokenMatchesUID(uint32_t effectiveUID, uint32_t pid,
	uid_t serviceUID)
{
	return effectiveUID == (uint32_t)serviceUID && pid > 0 && pid <= INT_MAX;
}

#endif

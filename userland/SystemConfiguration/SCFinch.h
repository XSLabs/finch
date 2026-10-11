/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch's SystemConfiguration: shared internals (docs/design/SECURITY.md). */
#ifndef FINCH_SC_H
#define FINCH_SC_H

#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CFRuntime.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <xpc/xpc.h>

#define SC_HIDDEN __attribute__((visibility("hidden")))

#define SC_DEFINE_TYPE(func, name, finalize, equal, hash, describe)                                \
	CFTypeID func(void)                                                                        \
	{                                                                                          \
		static CFTypeID id;                                                                \
		static dispatch_once_t once;                                                       \
		static const CFRuntimeClass cls = {0, name, NULL, NULL, finalize, equal, hash, NULL, describe}; \
		dispatch_once(&once, ^{ id = _CFRuntimeRegisterClass(&cls); });                   \
		return id;                                                                         \
	}

/* SPI constants (configd's SCNetworkConfigurationPrivate.h) */
extern const CFStringRef kSCNetworkInterfaceTypeBridge;

SC_HIDDEN void _SCErrorSet(int error);
SC_HIDDEN CFTypeRef _SCCreateInstance(CFTypeID type, size_t size);   /* size includes CFRuntimeBase */

/* Finch configd client transport. Requests and replies carry binary plists so
 * the daemon and framework share CoreFoundation's public value types. */
SC_HIDDEN xpc_connection_t _SCConfigdCreateConnection(xpc_handler_t handler);
SC_HIDDEN xpc_object_t _SCConfigdCreateRequest(const char *operation);
SC_HIDDEN xpc_object_t _SCConfigdSendRequest(xpc_connection_t connection,
    xpc_object_t request, int *status);
SC_HIDDEN bool _SCConfigdSetPropertyList(xpc_object_t request, const char *name,
    CFPropertyListRef value);
SC_HIDDEN CFPropertyListRef _SCConfigdCopyPropertyList(xpc_object_t reply,
    const char *name);

/* The local state the dynamic store answers from (SCDynamicStore.c). */
SC_HIDDEN CFDictionaryRef _SCCopyLocalState(void);
SC_HIDDEN CFStringRef _SCCopyComputerName(CFStringEncoding *encoding);
SC_HIDDEN CFStringRef _SCCopyLocalHostName(void);

/* System preferences (SCPreferences.c). */
SC_HIDDEN CFDictionaryRef _SCCopySystemPreferences(void);

/* Network change monitor (SCNetworkReachability.c): calls back on a private
 * queue whenever the kernel's routes or addresses change. */
SC_HIDDEN void _SCWatchNetworkChanges(void (^handler)(void));

/* Interfaces (SCNetworkConfiguration.c) */
SC_HIDDEN SCNetworkInterfaceRef _SCNetworkInterfaceCreateFromConfiguration(CFDictionaryRef interface);

#endif

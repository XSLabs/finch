/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "SecKeychainServiceClient.h"

#include <CoreFoundation/CFPropertyList.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <xpc/xpc.h>

#define FINCH_GUEST_MARKER "/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist"
#define FINCH_SERVICE_MARKER "/System/Library/Finch/LaunchAgents/org.finch.securityd.plist"

static bool markerPresentOrUnknown(const char *path)
{
	struct stat st;
	if (lstat(path, &st) == 0)
		return true;
	/* Only a definite absence means that the Finch service is optional. */
	return errno != ENOENT && errno != ENOTDIR;
}

bool
_FinchKeychainServiceRequired(void)
{
	return markerPresentOrUnknown(FINCH_GUEST_MARKER) ||
	    markerPresentOrUnknown(FINCH_SERVICE_MARKER);
}

static bool
copyString(CFStringRef string, char *buffer, size_t size)
{
	return string && CFGetTypeID(string) == CFStringGetTypeID() &&
	    CFStringGetCString(string, buffer, (CFIndex)size, kCFStringEncodingUTF8);
}

OSStatus
_FinchKeychainServiceCall(CFStringRef operation, CFPropertyListRef request,
	CFPropertyListRef *response)
{
	if (response)
		*response = NULL;
	char op[64];
	if (!copyString(operation, op, sizeof(op)) ||
	    (request && !CFPropertyListIsValid(request, kCFPropertyListBinaryFormat_v1_0)))
		return errSecParam;
	CFDataRef bytes = NULL;
	if (request) {
		CFErrorRef error = NULL;
		bytes = CFPropertyListCreateData(NULL, request, kCFPropertyListBinaryFormat_v1_0,
		    0, &error);
		if (error)
			CFRelease(error);
		if (!bytes)
			return errSecAllocate;
		if ((size_t)CFDataGetLength(bytes) > FINCH_KEYCHAIN_SERVICE_MAX_MESSAGE) {
			CFRelease(bytes);
			return errSecParam;
		}
	}

	xpc_connection_t connection = xpc_connection_create_mach_service(
	    FINCH_KEYCHAIN_SERVICE_NAME, NULL, 0);
	if (!connection) {
		if (bytes)
			CFRelease(bytes);
		return errSecNotAvailable;
	}
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		/* Replies are read synchronously below; ignore lifecycle events here. */
		(void)event;
	});
	xpc_connection_resume(connection);
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	if (!message) {
		xpc_release(connection);
		return errSecAllocate;
	}
	xpc_dictionary_set_uint64(message, "version", FINCH_KEYCHAIN_SERVICE_VERSION);
	xpc_dictionary_set_string(message, "operation", op);
	if (bytes)
		xpc_dictionary_set_data(message, "payload", CFDataGetBytePtr(bytes),
		    (size_t)CFDataGetLength(bytes));
	if (bytes)
		CFRelease(bytes);
	xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, message);
	xpc_release(message);
	xpc_release(connection);
	if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
		if (reply)
			xpc_release(reply);
		return errSecNotAvailable;
	}

	xpc_object_t version = xpc_dictionary_get_value(reply, "version");
	xpc_object_t statusValue = xpc_dictionary_get_value(reply, "status");
	if (!version || xpc_get_type(version) != XPC_TYPE_UINT64 ||
	    xpc_uint64_get_value(version) != FINCH_KEYCHAIN_SERVICE_VERSION ||
	    !statusValue || xpc_get_type(statusValue) != XPC_TYPE_INT64) {
		xpc_release(reply);
		return errSecInternalComponent;
	}
	int64_t rawStatus = xpc_int64_get_value(statusValue);
	if (rawStatus < INT32_MIN || rawStatus > INT32_MAX) {
		xpc_release(reply);
		return errSecInternalComponent;
	}
	OSStatus status = (OSStatus)rawStatus;
	if (!status && response) {
		xpc_object_t result = xpc_dictionary_get_value(reply, "result");
		if (!result || xpc_get_type(result) != XPC_TYPE_DATA ||
		    xpc_data_get_length(result) > FINCH_KEYCHAIN_SERVICE_MAX_MESSAGE) {
			status = errSecInternalComponent;
		} else {
			CFDataRef resultBytes = CFDataCreate(NULL,
			    xpc_data_get_bytes_ptr(result), (CFIndex)xpc_data_get_length(result));
			CFPropertyListRef value = resultBytes ? CFPropertyListCreateWithData(NULL,
				resultBytes, kCFPropertyListImmutable, NULL, NULL) : NULL;
			if (resultBytes)
				CFRelease(resultBytes);
			if (!value || !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0)) {
				if (value)
					CFRelease(value);
				status = errSecInternalComponent;
			} else {
				*response = value;
			}
		}
	}
	xpc_release(reply);
	return status;
}

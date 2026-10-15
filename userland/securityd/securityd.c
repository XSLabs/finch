/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Per-user owner of Finch's encrypted keychain files and unlocked keys. */
#include "../Security/SecInternal.h"
#include "../Security/SecKeychainCrypto.h"
#include "../Security/SecKeychainServiceProtocol.h"
#include "../Security/SecKeychainServiceWire.h"

#include <CoreFoundation/CFPropertyList.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

/* Finch's libxpc supplies this message-audit-token helper. */
void xpc_dictionary_get_audit_token(xpc_object_t message, audit_token_t *token);

static bool validType(CFTypeRef value, CFTypeID type)
{
	return value && CFGetTypeID(value) == type;
}

static CFTypeRef field(CFDictionaryRef request, CFStringRef name)
{
	return request ? CFDictionaryGetValue(request, name) : NULL;
}

static bool copyPath(CFTypeRef value, char path[PATH_MAX])
{
	if (!validType(value, CFStringGetTypeID()))
		return false;
	CFStringRef string = (CFStringRef)value;
	CFIndex characterCount = CFStringGetLength(string);
	if (characterCount <= 0)
		return false;
	CFIndex byteCount = 0;
	CFIndex convertedCharacters = CFStringGetBytes(string, CFRangeMake(0, characterCount),
	    kCFStringEncodingUTF8, 0, false, (UInt8 *)path, PATH_MAX - 1, &byteCount);
	if (convertedCharacters != characterCount || byteCount <= 0 || byteCount >= PATH_MAX ||
	    memchr(path, 0, (size_t)byteCount))
		return false;
	path[byteCount] = '\0';
	return path[0] == '/';
}

static bool requestBoolean(CFDictionaryRef request, CFStringRef key, bool *value)
{
	CFTypeRef object = field(request, key);
	if (!object) {
		*value = false;
		return true;
	}
	if (CFGetTypeID(object) != CFBooleanGetTypeID())
		return false;
	*value = CFBooleanGetValue((CFBooleanRef)object);
	return true;
}

static OSStatus dispatchRequest(const char *operation, CFDictionaryRef request,
	CFTypeRef *result, bool *resultRequired)
{
	*result = NULL;
	*resultRequired = false;
	if (strcmp(operation, "keychain.default-path") == 0) {
		SecKeychainRef keychain = NULL;
		OSStatus status = SecKeychainCopyDefault(&keychain);
		if (status)
			return status;
		char path[PATH_MAX];
		UInt32 size = sizeof(path);
		status = SecKeychainGetPath(keychain, &size, path);
		if (!status)
			*result = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
		CFRelease(keychain);
		if (!status && !*result)
			status = errSecAllocate;
		*resultRequired = true;
		return status;
	}
	if (strcmp(operation, "keychain.interaction-get") == 0) {
		Boolean allowed = false;
		OSStatus status = SecKeychainGetUserInteractionAllowed(&allowed);
		if (!status)
			*result = CFRetain(allowed ? kCFBooleanTrue : kCFBooleanFalse);
		*resultRequired = true;
		return status;
	}
	if (strcmp(operation, "keychain.interaction-set") == 0) {
		bool allowed = false;
		if (!requestBoolean(request, CFSTR("allowed"), &allowed) ||
		    !field(request, CFSTR("allowed")))
			return errSecParam;
		return SecKeychainSetUserInteractionAllowed(allowed);
	}
	if (strcmp(operation, "keychain.create") == 0 ||
	    strcmp(operation, "keychain.open") == 0) {
		char path[PATH_MAX];
		if (!copyPath(field(request, CFSTR("path")), path))
			return errSecParam;
		if (strcmp(operation, "keychain.open") == 0) {
			SecKeychainRef keychain = NULL;
			OSStatus status = SecKeychainOpen(path, &keychain);
			*result = keychain;
			*resultRequired = true;
			return status;
		}
		CFDataRef password = (CFDataRef)field(request, CFSTR("password"));
		if (!validType(password, CFDataGetTypeID()) ||
		    CFDataGetLength(password) <= 0 ||
		    (size_t)CFDataGetLength(password) > SEC_KEYCHAIN_CRYPTO_MAX_PASSWORD_BYTES)
			return errSecParam;
		SecKeychainRef keychain = NULL;
		OSStatus status = SecKeychainCreate(path, (UInt32)CFDataGetLength(password),
		    CFDataGetBytePtr(password), false, NULL, &keychain);
		*result = keychain;
		*resultRequired = true;
		return status;
	}
	if (strcmp(operation, "keychain.delete") == 0) {
		CFTypeRef keychain = field(request, CFSTR("keychain"));
		if (!keychain || (CFGetTypeID(keychain) != SecKeychainGetTypeID() &&
		    CFGetTypeID(keychain) != CFArrayGetTypeID()))
			return errSecInvalidKeychain;
		return SecKeychainDelete((SecKeychainRef)keychain);
	}
	if (strcmp(operation, "keychain.status") == 0) {
		CFTypeRef keychain = field(request, CFSTR("keychain"));
		if (keychain && CFGetTypeID(keychain) != SecKeychainGetTypeID())
			return errSecInvalidKeychain;
		SecKeychainStatus statusValue = 0;
		OSStatus status = SecKeychainGetStatus((SecKeychainRef)keychain, &statusValue);
		if (!status) {
			int32_t value = (int32_t)statusValue;
			*result = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
			if (!*result)
				status = errSecAllocate;
		}
		*resultRequired = true;
		return status;
	}
	if (strcmp(operation, "keychain.lock") == 0) {
		CFTypeRef keychain = field(request, CFSTR("keychain"));
		if (keychain && CFGetTypeID(keychain) != SecKeychainGetTypeID())
			return errSecInvalidKeychain;
		return SecKeychainLock((SecKeychainRef)keychain);
	}
	if (strcmp(operation, "keychain.lock-all") == 0)
		return SecKeychainLockAll();
	if (strcmp(operation, "keychain.unlock") == 0) {
		CFTypeRef keychain = field(request, CFSTR("keychain"));
		CFDataRef password = (CFDataRef)field(request, CFSTR("password"));
		bool usePassword = false;
		if ((keychain && CFGetTypeID(keychain) != SecKeychainGetTypeID()) ||
		    !validType(password, CFDataGetTypeID()) || CFDataGetLength(password) <= 0 ||
		    !requestBoolean(request, CFSTR("usePassword"), &usePassword))
			return errSecParam;
		return SecKeychainUnlock((SecKeychainRef)keychain,
		    (UInt32)CFDataGetLength(password), CFDataGetBytePtr(password), usePassword);
	}
	if (strcmp(operation, "keychain.change-password") == 0) {
		CFTypeRef keychain = field(request, CFSTR("keychain"));
		CFDataRef oldPassword = (CFDataRef)field(request, CFSTR("oldPassword"));
		CFDataRef newPassword = (CFDataRef)field(request, CFSTR("newPassword"));
		if ((keychain && CFGetTypeID(keychain) != SecKeychainGetTypeID()) ||
		    !validType(oldPassword, CFDataGetTypeID()) || CFDataGetLength(oldPassword) <= 0 ||
		    !validType(newPassword, CFDataGetTypeID()) || CFDataGetLength(newPassword) <= 0)
			return errSecParam;
		return SecKeychainChangePassword((SecKeychainRef)keychain,
		    (UInt32)CFDataGetLength(oldPassword), CFDataGetBytePtr(oldPassword),
		    (UInt32)CFDataGetLength(newPassword), CFDataGetBytePtr(newPassword));
	}
	if (strcmp(operation, "item.add") == 0) {
		CFTypeRef attributes = field(request, CFSTR("attributes"));
		bool wantsResult = false;
		if (!validType(attributes, CFDictionaryGetTypeID()) ||
		    !requestBoolean(request, CFSTR("returnResult"), &wantsResult))
			return errSecParam;
		*resultRequired = wantsResult;
		return SecItemAdd((CFDictionaryRef)attributes, wantsResult ? result : NULL);
	}
	if (strcmp(operation, "item.copy") == 0) {
		CFTypeRef query = field(request, CFSTR("query"));
		bool wantsResult = false;
		if (!validType(query, CFDictionaryGetTypeID()) ||
		    !requestBoolean(request, CFSTR("returnResult"), &wantsResult))
			return errSecParam;
		*resultRequired = wantsResult;
		return SecItemCopyMatching((CFDictionaryRef)query, wantsResult ? result : NULL);
	}
	if (strcmp(operation, "item.update") == 0) {
		CFTypeRef query = field(request, CFSTR("query"));
		CFTypeRef attributes = field(request, CFSTR("attributes"));
		if (!validType(query, CFDictionaryGetTypeID()) ||
		    !validType(attributes, CFDictionaryGetTypeID()))
			return errSecParam;
		return SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)attributes);
	}
	if (strcmp(operation, "item.delete") == 0) {
		CFTypeRef query = field(request, CFSTR("query"));
		if (!validType(query, CFDictionaryGetTypeID()))
			return errSecParam;
		return SecItemDelete((CFDictionaryRef)query);
	}
	return errSecUnimplemented;
}

static CFPropertyListRef parsePayload(xpc_object_t message, bool *valid)
{
	*valid = true;
	xpc_object_t data = xpc_dictionary_get_value(message, "payload");
	if (!data)
		return NULL;
	if (xpc_get_type(data) != XPC_TYPE_DATA ||
	    xpc_data_get_length(data) > FINCH_KEYCHAIN_SERVICE_MAX_MESSAGE) {
		*valid = false;
		return NULL;
	}
	CFDataRef bytes = CFDataCreate(NULL, xpc_data_get_bytes_ptr(data),
	    (CFIndex)xpc_data_get_length(data));
	if (!bytes) {
		*valid = false;
		return NULL;
	}
	CFPropertyListRef value = CFPropertyListCreateWithData(NULL, bytes,
	    kCFPropertyListImmutable, NULL, NULL);
	CFRelease(bytes);
	if (!value || !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0)) {
		if (value)
			CFRelease(value);
		*valid = false;
		return NULL;
	}
	return value;
}

static void handleMessage(xpc_connection_t peer, xpc_object_t message)
{
	xpc_object_t reply = xpc_dictionary_create_reply(message);
	if (!reply)
		return;
	xpc_dictionary_set_uint64(reply, "version", FINCH_KEYCHAIN_SERVICE_VERSION);
	OSStatus status = errSecParam;
	CFTypeRef result = NULL;
	bool resultRequired = false;
	if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
		audit_token_t token = {0};
		xpc_dictionary_get_audit_token(message, &token);
		if (!_FinchKeychainServiceTokenMatchesUID(token.val[1], token.val[5], geteuid())) {
			status = errSecAuthFailed;
		} else {
			xpc_object_t version = xpc_dictionary_get_value(message, "version");
			const char *operation = xpc_dictionary_get_string(message, "operation");
			if (!version || xpc_get_type(version) != XPC_TYPE_UINT64 ||
			    xpc_uint64_get_value(version) != FINCH_KEYCHAIN_SERVICE_VERSION ||
			    !operation || strlen(operation) > 63) {
				status = errSecParam;
			} else {
				bool payloadValid = false;
				CFPropertyListRef wireRequest = parsePayload(message, &payloadValid);
				if (!payloadValid) {
					status = errSecParam;
				} else {
					CFTypeRef request = wireRequest ?
					    _FinchKeychainWireDecode(wireRequest, false) : NULL;
					if (wireRequest && !request) {
						status = errSecParam;
					} else if (request && CFGetTypeID(request) != CFDictionaryGetTypeID()) {
						status = errSecParam;
					} else {
						status = dispatchRequest(operation, (CFDictionaryRef)request,
						    &result, &resultRequired);
					}
					if (request)
						CFRelease(request);
					if (wireRequest)
						CFRelease(wireRequest);
				}
			}
		}
	}
	if (!status && resultRequired) {
		CFPropertyListRef wireResult = result ? _FinchKeychainWireEncode(result) : NULL;
		CFDataRef bytes = wireResult ? CFPropertyListCreateData(NULL, wireResult,
		    kCFPropertyListBinaryFormat_v1_0, 0, NULL) : NULL;
		if (wireResult)
			CFRelease(wireResult);
		if (!bytes || (size_t)CFDataGetLength(bytes) > FINCH_KEYCHAIN_SERVICE_MAX_MESSAGE) {
			status = errSecUnimplemented;
		} else {
			xpc_dictionary_set_data(reply, "result", CFDataGetBytePtr(bytes),
			    (size_t)CFDataGetLength(bytes));
		}
		if (bytes)
			CFRelease(bytes);
	}
	if (result)
		CFRelease(result);
	xpc_dictionary_set_int64(reply, "status", status);
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

static bool validateServiceAccount(void)
{
	uid_t uid = geteuid();
	if (uid == 0 || getuid() != uid)
		return false;
	long size = sysconf(_SC_GETPW_R_SIZE_MAX);
	if (size < 1024)
		size = 16384;
	char *buffer = malloc((size_t)size);
	if (!buffer)
		return false;
	struct passwd account, *found = NULL;
	int error = getpwuid_r(uid, &account, buffer, (size_t)size, &found);
	struct stat home;
	bool valid = !error && found && account.pw_dir && account.pw_dir[0] == '/' &&
	    stat(account.pw_dir, &home) == 0 && S_ISDIR(home.st_mode) && home.st_uid == uid;
	free(buffer);
	return valid;
}

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	if (!validateServiceAccount()) {
		fprintf(stderr, "securityd: expected a non-root user account with an owned home directory\n");
		return 1;
	}
	xpc_connection_t listener = xpc_connection_create_mach_service(
	    FINCH_KEYCHAIN_SERVICE_NAME, dispatch_get_main_queue(),
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);
	if (!listener) {
		fprintf(stderr, "securityd: could not register the per-user Mach service\n");
		return 1;
	}
	xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
		if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
			return;
		xpc_connection_t peer = (xpc_connection_t)event;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
			if (xpc_get_type(message) == XPC_TYPE_DICTIONARY)
				handleMessage(peer, message);
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}

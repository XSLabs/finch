/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "../Security/SecKeychainServiceProtocol.h"
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

extern char **environ;

static const char password[] = "finch-service-test-password";
static const char wrongPassword[] = "not the right password";
static const char serviceName[] = "org.finch.security-service-test";
static int failures;

static void check(const char *name, BOOL passed)
{
	printf("%s: %s\n", name, passed ? "pass" : "FAIL");
	if (!passed)
		failures++;
}

static OSStatus rawRequest(uint64_t version, const char *operation, bool badPayload)
{
	xpc_connection_t connection = xpc_connection_create_mach_service(
	    FINCH_KEYCHAIN_SERVICE_NAME, NULL, 0);
	if (!connection)
		return errSecNotAvailable;
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
	xpc_connection_resume(connection);
	xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(request, "version", version);
	xpc_dictionary_set_string(request, "operation", operation);
	if (badPayload)
		xpc_dictionary_set_string(request, "payload", "not a property-list data block");
	xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
	OSStatus status = errSecNotAvailable;
	if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
		xpc_object_t value = xpc_dictionary_get_value(reply, "status");
		if (value && xpc_get_type(value) == XPC_TYPE_INT64)
			status = (OSStatus)xpc_int64_get_value(value);
	}
	if (reply)
		xpc_release(reply);
	xpc_release(request);
	xpc_release(connection);
	return status;
}

static NSString *readSecret(SecKeychainRef keychain, OSStatus *status)
{
	NSDictionary *query = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: [NSString stringWithUTF8String:serviceName],
		(id)kSecAttrAccount: @"shared-client",
		(id)kSecReturnData: @YES,
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	CFTypeRef result = NULL;
	*status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	NSString *value = nil;
	if (!*status && result && CFGetTypeID(result) == CFDataGetTypeID())
		value = [[NSString alloc] initWithData:(__bridge NSData *)result
		    encoding:NSUTF8StringEncoding];
	if (result)
		CFRelease(result);
	return value;
}

static int childClient(const char *path)
{
	SecKeychainRef keychain = NULL;
	if (SecKeychainOpen(path, &keychain) != errSecSuccess || !keychain)
		return 1;
	SecKeychainStatus status = 0;
	if (SecKeychainGetStatus(keychain, &status) != errSecSuccess ||
	    !(status & kSecUnlockStateStatus)) {
		CFRelease(keychain);
		return 2;
	}
	OSStatus error = errSecSuccess;
	NSString *secret = readSecret(keychain, &error);
	BOOL readWorked = error == errSecSuccess && [secret isEqualToString:@"updated shared secret"];
	if (!readWorked) {
		CFRelease(keychain);
		return 3;
	}
	if (SecKeychainLockAll() != errSecSuccess) {
		CFRelease(keychain);
		return 4;
	}
	status = 0;
	if (SecKeychainGetStatus(keychain, &status) != errSecSuccess ||
	    (status & kSecUnlockStateStatus)) {
		CFRelease(keychain);
		return 5;
	}
	secret = readSecret(keychain, &error);
	CFRelease(keychain);
	return error == errSecInteractionNotAllowed && secret == nil ? 0 : 6;
}

static BOOL spawnClient(const char *executable, const char *path)
{
	char *arguments[] = {(char *)executable, "--client", (char *)path, NULL};
	pid_t pid = 0;
	int error = posix_spawn(&pid, executable, NULL, NULL, arguments, environ);
	if (error)
		return NO;
	int status = 0;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR)
			return NO;
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "--client"))
		return childClient(argv[2]);
	if (access("/System/Library/Finch/LaunchAgents/org.finch.securityd.plist", F_OK) < 0) {
		puts("security keychain service: skip (Finch guest only)");
		return 0;
	}
	uid_t uid = geteuid();
	uint32_t pid = (uint32_t)getpid();
	uid_t otherUID = uid == UINT_MAX ? uid - 1 : uid + 1;
	check("same-user audit token is allowed",
	    _FinchKeychainServiceTokenMatchesUID((uint32_t)uid, pid, uid));
	check("different-user audit token is denied",
	    !_FinchKeychainServiceTokenMatchesUID((uint32_t)otherUID, pid, uid));
	check("audit token without a process is denied",
	    !_FinchKeychainServiceTokenMatchesUID((uint32_t)uid, 0, uid));

	check("reject unsupported protocol version",
	    rawRequest(0, "keychain.lock-all", NO) == errSecParam);
	check("reject unknown request",
	    rawRequest(FINCH_KEYCHAIN_SERVICE_VERSION, "unknown.request", NO) == errSecUnimplemented);
	check("reject malformed request data",
	    rawRequest(FINCH_KEYCHAIN_SERVICE_VERSION, "item.copy", YES) == errSecParam);

	char directory[] = "/tmp/finch-keychain-service-XXXXXX";
	check("make private test folder", mkdtemp(directory) != NULL && chmod(directory, 0700) == 0);
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%s/login.keychain", directory);
	SecKeychainRef keychain = NULL;
	OSStatus status = SecKeychainCreate(path, sizeof(password) - 1, password,
	    false, NULL, &keychain);
	check("create keychain through service", status == errSecSuccess && keychain != NULL);
	if (!status && keychain) {
		status = SecKeychainLockAll();
		check("lock all keychains through service", status == errSecSuccess);
		status = SecKeychainUnlock(keychain, sizeof(wrongPassword) - 1,
		    wrongPassword, false);
		check("wrong password stays rejected", status == errSecAuthFailed);
		status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
		check("unlock through service", status == errSecSuccess);

		NSDictionary *attributes = @{
			(id)kSecClass: (id)kSecClassGenericPassword,
			(id)kSecAttrService: [NSString stringWithUTF8String:serviceName],
			(id)kSecAttrAccount: @"shared-client",
			(id)kSecValueData: [@"first shared secret" dataUsingEncoding:NSUTF8StringEncoding],
			(id)kSecUseKeychain: (__bridge id)keychain,
			(id)kSecReturnRef: @YES,
		};
		CFTypeRef result = NULL;
		status = SecItemAdd((__bridge CFDictionaryRef)attributes, &result);
		SecKeychainItemRef item = result && CFGetTypeID(result) == SecKeychainItemGetTypeID() ?
		    (SecKeychainItemRef)result : NULL;
		check("add item and return a client proxy", status == errSecSuccess && item != NULL);
		if (status == errSecSuccess && item) {
			UInt32 length = 0;
			void *data = NULL;
			status = SecKeychainItemCopyContent(item, NULL, NULL, &length, &data);
			check("read through the returned item proxy", status == errSecSuccess &&
			    length == sizeof("first shared secret") - 1 &&
			    !memcmp(data, "first shared secret", length));
			if (data)
				SecKeychainItemFreeContent(NULL, data);

			status = SecKeychainItemModifyContent(item, NULL,
			    sizeof("updated shared secret") - 1, "updated shared secret");
			check("update through the returned item proxy", status == errSecSuccess);
			CFDataRef persistent = NULL;
			status = SecKeychainItemCreatePersistentReference(item, &persistent);
			SecKeychainItemRef fromPersistent = NULL;
			if (!status)
				status = SecKeychainItemCopyFromPersistentReference(persistent, &fromPersistent);
			check("persistent reference returns a working proxy", status == errSecSuccess &&
			    fromPersistent && CFEqual(item, fromPersistent));
			if (persistent)
				CFRelease(persistent);
			if (fromPersistent)
				CFRelease(fromPersistent);
		}
		if (item)
			CFRelease(item);
		else if (result)
			CFRelease(result);

		char executable[PATH_MAX];
		char executablePath[PATH_MAX];
		uint32_t executablePathSize = sizeof(executablePath);
		BOOL executableResolved = _NSGetExecutablePath(executablePath, &executablePathSize) == 0 &&
		    realpath(executablePath, executable) != NULL;
		check("resolve test executable", executableResolved);
		check("second client shares the unlocked key and locks it",
		    executableResolved && spawnClient(executable, path));
		SecKeychainStatus keychainStatus = 0;
		status = SecKeychainGetStatus(keychain, &keychainStatus);
		check("first client sees the second client's lock", status == errSecSuccess &&
		    !(keychainStatus & kSecUnlockStateStatus));
		NSString *secret = readSecret(keychain, &status);
		check("first client cannot read after the shared lock", status == errSecInteractionNotAllowed && secret == nil);
		status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
		check("first client unlocks the shared keychain again", status == errSecSuccess);
		secret = readSecret(keychain, &status);
		check("first client reads after unlock", status == errSecSuccess &&
		    [secret isEqualToString:@"updated shared secret"]);
		status = SecKeychainDelete(keychain);
		check("delete test keychain through service", status == errSecSuccess);
		CFRelease(keychain);
	}
	unlink(path);
	char lockPath[PATH_MAX];
	snprintf(lockPath, sizeof(lockPath), "%s/.finch-keychain.lock", directory);
	unlink(lockPath);
	check("remove private test folder", rmdir(directory) == 0);
	printf("failures: %d\n", failures);
	return failures ? 1 : 0;
}

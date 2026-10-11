/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Checks the configd service inside Finch. Run as root with the service
 * loaded, except for --unavailable, which must run in the VM before launchd
 * loads the configd job. Do not run --unavailable on a Mac host.
 */
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static char *testProgramPath;

typedef struct {
	dispatch_semaphore_t semaphore;
	CFStringRef key;
	bool matched;
} NotifyContext;

static void
check(bool condition, const char *message)
{
	if (!condition) {
		fprintf(stderr, "configd-service: FAIL: %s (SCError=%d)\n",
		    message, SCError());
		exit(1);
	}
}

static CFStringRef
uniqueKey(const char *leaf, pid_t pid)
{
	CFUUIDRef uuid = CFUUIDCreate(NULL);
	if (uuid == NULL)
		return NULL;
	CFStringRef uuidString = CFUUIDCreateString(NULL, uuid);
	if (uuidString == NULL) {
		CFRelease(uuid);
		return NULL;
	}
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL,
	    CFSTR("State:/Finch/ConfigdTest/%d/%s/%@"), pid, leaf, uuidString);
	CFRelease(uuidString);
	CFRelease(uuid);
	return key;
}

static CFStringRef
uniqueUserKey(uid_t uid, const char *leaf, pid_t pid)
{
	CFUUIDRef uuid = CFUUIDCreate(NULL);
	if (uuid == NULL)
		return NULL;
	CFStringRef uuidString = CFUUIDCreateString(NULL, uuid);
	if (uuidString == NULL) {
		CFRelease(uuid);
		return NULL;
	}
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL,
	    CFSTR("State:/Users/%u/Finch/ConfigdTest/%d/%s/%@"),
	    (unsigned)uid, pid, leaf, uuidString);
	CFRelease(uuidString);
	CFRelease(uuid);
	return key;
}

static bool
containsKey(CFArrayRef keys, CFStringRef key)
{
	return keys && CFArrayContainsValue(keys,
	    CFRangeMake(0, CFArrayGetCount(keys)), key);
}

static void
notifyCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info)
{
	(void)store;
	NotifyContext *context = info;
	context->matched = containsKey(changedKeys, context->key);
	dispatch_semaphore_signal(context->semaphore);
}

static bool
writeByte(int fd, char byte)
{
	ssize_t result;
	do {
		result = write(fd, &byte, 1);
	} while (result < 0 && errno == EINTR);
	return result == 1;
}

static bool
readByte(int fd, char *byte)
{
	ssize_t result;
	do {
		result = read(fd, byte, 1);
	} while (result < 0 && errno == EINTR);
	return result == 1;
}

#define CONFIGD_LABEL "com.apple.SystemConfiguration.configd"

static bool
finchConfigdTestEnvironment(void)
{
	return access("/etc/finch/rc", R_OK) == 0 &&
	    access("/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist",
	        R_OK) == 0;
}

/* Read the service PID through Finch's own launchctl, so this test never
 * sends a signal to a guessed process. */
static bool
launchctlConfigdPID(pid_t *pidOut)
{
	int output[2];
	if (pipe(output) != 0)
		return false;
	posix_spawn_file_actions_t actions;
	if (posix_spawn_file_actions_init(&actions) != 0) {
		close(output[0]);
		close(output[1]);
		return false;
	}
	int err = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
	if (err == 0)
		err = posix_spawn_file_actions_addclose(&actions, output[0]);
	if (err == 0)
		err = posix_spawn_file_actions_addclose(&actions, output[1]);
	char *arguments[] = {
		(char *)"/bin/launchctl", (char *)"list", (char *)CONFIGD_LABEL, NULL,
	};
	pid_t child = 0;
	if (err == 0)
		err = posix_spawn(&child, arguments[0], &actions, NULL, arguments, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(output[1]);
	if (err != 0) {
		close(output[0]);
		return false;
	}
	char text[2048];
	size_t used = 0;
	while (used < sizeof(text) - 1) {
		ssize_t count = read(output[0], text + used, sizeof(text) - 1 - used);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			break;
		used += (size_t)count;
	}
	close(output[0]);
	text[used] = '\0';
	int status = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &status, 0);
	} while (waited < 0 && errno == EINTR);
	if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
		return false;
	char *field = strstr(text, "\"PID\" = ");
	if (field == NULL) {
		*pidOut = 0;
		return true;
	}
	char *end = NULL;
	long value = strtol(field + strlen("\"PID\" = "), &end, 10);
	if (end == field + strlen("\"PID\" = ") || value <= 0 || value > INT_MAX)
		return false;
	*pidOut = (pid_t)value;
	return true;
}

static bool
restartConfigdWithLaunchctl(void)
{
	char target[128];
	snprintf(target, sizeof(target), "system/%s", CONFIGD_LABEL);
	char *arguments[] = {
		(char *)"/bin/launchctl", (char *)"kickstart", (char *)"-k", target, NULL,
	};
	pid_t child = 0;
	if (posix_spawn(&child, arguments[0], NULL, NULL, arguments, environ) != 0)
		return false;
	int status = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &status, 0);
	} while (waited < 0 && errno == EINTR);
	return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

typedef struct {
	atomic_uint references;
	dispatch_semaphore_t semaphore;
	CFStringRef key;
	atomic_bool matched;
} RecoveryNotifyContext;

static const void *
recoveryContextRetain(const void *info)
{
	RecoveryNotifyContext *context = (RecoveryNotifyContext *)info;
	atomic_fetch_add(&context->references, 1);
	return info;
}

static void
recoveryContextRelease(const void *info)
{
	RecoveryNotifyContext *context = (RecoveryNotifyContext *)info;
	if (context && atomic_fetch_sub(&context->references, 1) == 1) {
		if (context->semaphore)
			dispatch_release(context->semaphore);
		if (context->key)
			CFRelease(context->key);
		free(context);
	}
}

static void
recoveryNotifyCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info)
{
	(void)store;
	RecoveryNotifyContext *context = info;
	if (containsKey(changedKeys, context->key)) {
		atomic_store(&context->matched, true);
		dispatch_semaphore_signal(context->semaphore);
	}
}

static bool
testSubscriptionRestartRecovery(void)
{
	bool ok = false;
	SCDynamicStoreRef listener = NULL, writer = NULL;
	CFStringRef key = uniqueKey("RestartNotification", getpid());
	CFArrayRef watched = NULL;
	dispatch_queue_t queue = NULL;
	RecoveryNotifyContext *context = key ? calloc(1, sizeof(*context)) : NULL;
	SCDynamicStoreContext storeContext = {
		.version = 0,
		.info = context,
		.retain = recoveryContextRetain,
		.release = recoveryContextRelease,
		.copyDescription = NULL,
	};
	if (context) {
		atomic_init(&context->references, 1);
		atomic_init(&context->matched, false);
		context->key = CFRetain(key);
		context->semaphore = dispatch_semaphore_create(0);
	}
	if (!finchConfigdTestEnvironment() || geteuid() != 0 || key == NULL ||
	    context == NULL || context->semaphore == NULL)
		goto cleanup;
	listener = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd subscription restart listener"),
	    recoveryNotifyCallback, &storeContext);
	writer = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd subscription restart writer"), NULL, NULL);
	if (listener == NULL || writer == NULL)
		goto cleanup;
	watched = CFArrayCreate(NULL, (const void **)&key, 1, &kCFTypeArrayCallBacks);
	queue = dispatch_queue_create("finch.configd.test.restart", DISPATCH_QUEUE_SERIAL);
	if (watched == NULL || queue == NULL ||
	    !SCDynamicStoreSetNotificationKeys(listener, watched, NULL) ||
	    !SCDynamicStoreSetDispatchQueue(listener, queue) ||
	    !SCDynamicStoreSetValue(writer, key, CFSTR("before restart")))
		goto cleanup;
	bool initialNotification =
	    dispatch_semaphore_wait(context->semaphore,
		dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0 &&
	    atomic_exchange(&context->matched, false);
	if (!initialNotification)
		goto cleanup;

	pid_t before = 0;
	if (!launchctlConfigdPID(&before) || before <= 0 ||
	    !restartConfigdWithLaunchctl())
		goto cleanup;
	bool restarted = false;
	for (unsigned i = 0; i < 100; i++) {
		pid_t current = 0;
		if (launchctlConfigdPID(&current) && current > 0 && current != before) {
			restarted = true;
			break;
		}
		usleep(50000);
	}
	if (!restarted)
		goto cleanup;

	/* This request uses the original store object and drives its reconnect.
	 * Dynamic values live in configd's memory, so the earlier marker vanishes
	 * when the service restarts; the later write checks the restored watch. */
	CFDictionaryRef snapshot = SCDynamicStoreCopyMultiple(listener, NULL, NULL);
	bool readAfterRestart = snapshot != NULL;
	if (snapshot)
		CFRelease(snapshot);
	if (!readAfterRestart ||
	    !SCDynamicStoreSetValue(writer, key, CFSTR("after restart")))
		goto cleanup;
	bool resumedNotification =
	    dispatch_semaphore_wait(context->semaphore,
		dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0 &&
	    atomic_exchange(&context->matched, false);
	ok = resumedNotification;

cleanup:
	/* Remove the watch first, then drain callbacks queued before the reply. */
	if (listener)
		(void)SCDynamicStoreSetNotificationKeys(listener, NULL, NULL);
	if (writer && key)
		(void)SCDynamicStoreRemoveValue(writer, key);
	if (listener) {
		if (queue)
			dispatch_sync(queue, ^{});
		(void)SCDynamicStoreSetDispatchQueue(listener, NULL);
		CFRelease(listener);
	}
	if (writer)
		CFRelease(writer);
	if (queue)
		dispatch_release(queue);
	if (watched)
		CFRelease(watched);
	if (context)
		recoveryContextRelease(context);
	if (key)
		CFRelease(key);
	return ok;
}

static int
runNotificationListener(int parentRead, int parentWrite, CFStringRef notifyKey,
    CFStringRef temporaryKey)
{
	NotifyContext context = {
		.semaphore = dispatch_semaphore_create(0),
		.key = notifyKey,
		.matched = false,
	};
	SCDynamicStoreContext storeContext = {
		.version = 0,
		.info = &context,
		.retain = NULL,
		.release = NULL,
		.copyDescription = NULL,
	};
	SCDynamicStoreRef listener = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd notification listener"), notifyCallback,
	    &storeContext);
	SCDynamicStoreRef temporaryStore = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd temporary owner"), NULL, NULL);
	CFArrayRef watched = CFArrayCreate(NULL,
	    (const void **)&notifyKey, 1, &kCFTypeArrayCallBacks);
	dispatch_queue_t queue = dispatch_queue_create(
	    "finch.configd.test.notifications", DISPATCH_QUEUE_SERIAL);
	if (!context.semaphore || !listener || !temporaryStore || !watched ||
	    !queue || !SCDynamicStoreSetNotificationKeys(listener, watched, NULL) ||
	    !SCDynamicStoreSetDispatchQueue(listener, queue) ||
	    !SCDynamicStoreAddTemporaryValue(temporaryStore, temporaryKey,
	        CFSTR("temporary value"))) {
		(void)writeByte(parentWrite, 'F');
		if (listener) CFRelease(listener);
		if (temporaryStore) CFRelease(temporaryStore);
		if (watched) CFRelease(watched);
		if (queue) dispatch_release(queue);
		if (context.semaphore) dispatch_release(context.semaphore);
		return 5;
	}
	if (!writeByte(parentWrite, 'R'))
		return 6;
	char release = 0;
	bool released = readByte(parentRead, &release) && release == 'G';
	long waitResult = released ? dispatch_semaphore_wait(context.semaphore,
	    dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) : -1;
	bool notified = released && waitResult == 0 && context.matched;
	(void)writeByte(parentWrite, notified ? 'N' : 'F');
	char finish = 0;
	if (!readByte(parentRead, &finish) || finish != 'D')
		notified = false;
	(void)SCDynamicStoreSetDispatchQueue(listener, NULL);
	CFRelease(listener);
	CFRelease(temporaryStore);
	CFRelease(watched);
	dispatch_release(queue);
	dispatch_release(context.semaphore);
	return notified ? 0 : 7;
}

static bool
testRootPreferences(bool restartService)
{
	bool ok = false, locked = false, wrote = false;
	SCPreferencesRef prefs = SCPreferencesCreate(NULL,
	    CFSTR("Finch configd service test"), NULL);
	CFStringRef marker = uniqueKey("Preference", getpid());
	CFStringRef value = CFStringCreateWithFormat(NULL, NULL,
	    CFSTR("configd preference test %d"), getpid());
	check(prefs != NULL && marker != NULL && value != NULL,
	    "create preferences test values");

	if (!SCPreferencesLock(prefs, true))
		goto cleanup;
	locked = true;
	if (SCPreferencesGetValue(prefs, marker) != NULL ||
	    !SCPreferencesAddValue(prefs, marker, value) ||
	    !SCPreferencesCommitChanges(prefs))
		goto cleanup;
	wrote = true;
	if (!SCPreferencesUnlock(prefs))
		goto cleanup;
	locked = false;
	if (restartService) {
		pid_t before = 0;
		if (!launchctlConfigdPID(&before) || before <= 0 ||
		    !restartConfigdWithLaunchctl())
			goto cleanup;
		bool restarted = false;
		for (unsigned i = 0; i < 100; i++) {
			pid_t current = 0;
			if (launchctlConfigdPID(&current) && current > 0 && current != before) {
				restarted = true;
				break;
			}
			usleep(50000);
		}
		if (!restarted)
			goto cleanup;
	}

	SCPreferencesRef readback = SCPreferencesCreate(NULL,
	    CFSTR("Finch configd service readback"), NULL);
	if (readback == NULL)
		goto cleanup;
	CFPropertyListRef actual = SCPreferencesGetValue(readback, marker);
	ok = actual && CFEqual(actual, value);
	CFRelease(readback);

cleanup:
	if (locked && !SCPreferencesUnlock(prefs))
		ok = false;
	if (wrote) {
		if (!SCPreferencesLock(prefs, true) ||
		    !SCPreferencesRemoveValue(prefs, marker) ||
		    !SCPreferencesCommitChanges(prefs) ||
		    !SCPreferencesUnlock(prefs))
			ok = false;
	}
	CFRelease(value);
	CFRelease(marker);
	CFRelease(prefs);
	return ok;
}

static int
runPreferencesDeniedCheck(void)
{
	struct passwd *account = getpwnam("nobody");
	if (account == NULL || setgid(account->pw_gid) != 0 ||
	    setuid(account->pw_uid) != 0 || geteuid() == 0)
		return 2;
	SCPreferencesRef prefs = SCPreferencesCreate(NULL,
	    CFSTR("Finch configd nonroot test"), NULL);
	CFStringRef marker = uniqueKey("NonrootWrite", getpid());
	if (!prefs || !marker) {
		if (marker) CFRelease(marker);
		if (prefs) CFRelease(prefs);
		return 3;
	}
	Boolean locked = SCPreferencesLock(prefs, false);
	int status = SCError();
	if (locked)
		(void)SCPreferencesUnlock(prefs);
	CFRelease(marker);
	CFRelease(prefs);
	return !locked && status == kSCStatusAccessError ? 0 : 4;
}

static bool
testNonrootWriteDenied(void)
{
	struct passwd *account = getpwnam("nobody");
	check(account != NULL, "find the nobody account for the permission check");
	char *arguments[] = {testProgramPath, (char *)"--preferences-denied-check", NULL};
	pid_t child = 0;
	int spawnError = posix_spawnp(&child, arguments[0], NULL, NULL,
	    arguments, environ);
	check(spawnError == 0, "start the nonroot permission check");
	int status = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &status, 0);
	} while (waited < 0 && errno == EINTR);
	return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* Run in a fresh process so dropping root does not disturb dispatch or XPC. */
static int
runStorePermissionCheck(int argc, char **argv)
{
	if (argc != 5)
		return 2;
	struct passwd *account = getpwnam("nobody");
	if (account == NULL || setgid(account->pw_gid) != 0 ||
	    setuid(account->pw_uid) != 0 || geteuid() == 0)
		return 3;

	CFStringRef publicKey = CFStringCreateWithCString(NULL, argv[2],
	    kCFStringEncodingUTF8);
	CFStringRef rootPrivateKey = CFStringCreateWithCString(NULL, argv[3],
	    kCFStringEncodingUTF8);
	CFStringRef ownKey = CFStringCreateWithCString(NULL, argv[4],
	    kCFStringEncodingUTF8);
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd nonroot store test"), NULL, NULL);
	if (publicKey == NULL || rootPrivateKey == NULL || ownKey == NULL || store == NULL) {
		if (store) CFRelease(store);
		if (ownKey) CFRelease(ownKey);
		if (rootPrivateKey) CFRelease(rootPrivateKey);
		if (publicKey) CFRelease(publicKey);
		return 4;
	}

	/* Keep a broken service from leaving the parent test waiting forever. */
	alarm(15);
	CFPropertyListRef publicValue = SCDynamicStoreCopyValue(store, publicKey);
	bool canReadPublic = publicValue && CFEqual(publicValue, CFSTR("root public value"));
	if (publicValue) CFRelease(publicValue);
	CFPropertyListRef privateValue = SCDynamicStoreCopyValue(store, rootPrivateKey);
	bool cannotReadRootPrivate = privateValue == NULL && SCError() == kSCStatusNoKey;
	if (privateValue) CFRelease(privateValue);
	Boolean globalWrite = SCDynamicStoreSetValue(store, publicKey,
	    CFSTR("overwritten by nobody"));
	bool cannotWriteGlobal = !globalWrite && SCError() == kSCStatusAccessError;
	Boolean ownWrite = SCDynamicStoreSetValue(store, ownKey,
	    CFSTR("nobody private value"));
	CFPropertyListRef ownValue = ownWrite ?
	    SCDynamicStoreCopyValue(store, ownKey) : NULL;
	bool canWriteOwn = ownValue &&
	    CFEqual(ownValue, CFSTR("nobody private value"));
	if (ownValue) CFRelease(ownValue);
	CFRelease(store);
	CFRelease(ownKey);
	CFRelease(rootPrivateKey);
	CFRelease(publicKey);
	return canReadPublic && cannotReadRootPrivate && cannotWriteGlobal && canWriteOwn ? 0 : 5;
}

static bool
testDynamicStorePermissions(void)
{
	struct passwd *account = getpwnam("nobody");
	if (account == NULL)
		return false;
	uid_t nobody = account->pw_uid;
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd root store test"), NULL, NULL);
	CFStringRef publicKey = uniqueKey("StorePublic", getpid());
	CFStringRef rootPrivateKey = uniqueUserKey(0, "StorePrivate", getpid());
	CFStringRef ownKey = uniqueUserKey(nobody, "StorePrivate", getpid());
	CFStringRef publicValue = CFSTR("root public value");
	CFStringRef privateValue = CFSTR("root private value");
	bool ok = false;
	char publicText[1024], privateText[1024], ownText[1024];
	pid_t child = 0;
	int childStatus = 0;

	if (store == NULL || publicKey == NULL || rootPrivateKey == NULL || ownKey == NULL)
		goto cleanup;
	if (!SCDynamicStoreSetValue(store, publicKey, publicValue) ||
	    !SCDynamicStoreSetValue(store, rootPrivateKey, privateValue))
		goto cleanup;
	CFPropertyListRef publicReadback = SCDynamicStoreCopyValue(store, publicKey);
	CFPropertyListRef privateReadback = SCDynamicStoreCopyValue(store, rootPrivateKey);
	bool rootCanRead = publicReadback && privateReadback &&
	    CFEqual(publicReadback, publicValue) && CFEqual(privateReadback, privateValue);
	if (publicReadback) CFRelease(publicReadback);
	if (privateReadback) CFRelease(privateReadback);
	if (!rootCanRead ||
	    !CFStringGetCString(publicKey, publicText, sizeof(publicText), kCFStringEncodingUTF8) ||
	    !CFStringGetCString(rootPrivateKey, privateText, sizeof(privateText), kCFStringEncodingUTF8) ||
	    !CFStringGetCString(ownKey, ownText, sizeof(ownText), kCFStringEncodingUTF8))
		goto cleanup;

	char *childArguments[] = {
		testProgramPath,
		(char *)"--store-permission-check",
		publicText,
		privateText,
		ownText,
		NULL,
	};
	if (posix_spawnp(&child, childArguments[0], NULL, NULL, childArguments, environ) != 0)
		goto cleanup;
	pid_t waited;
	do {
		waited = waitpid(child, &childStatus, 0);
	} while (waited < 0 && errno == EINTR);
	if (waited != child || !WIFEXITED(childStatus) || WEXITSTATUS(childStatus) != 0)
		goto cleanup;
	CFPropertyListRef ownReadback = SCDynamicStoreCopyValue(store, ownKey);
	ok = ownReadback && CFEqual(ownReadback, CFSTR("nobody private value"));
	if (ownReadback) CFRelease(ownReadback);

cleanup:
	if (store) {
		if (publicKey) (void)SCDynamicStoreRemoveValue(store, publicKey);
		if (rootPrivateKey) (void)SCDynamicStoreRemoveValue(store, rootPrivateKey);
		if (ownKey) (void)SCDynamicStoreRemoveValue(store, ownKey);
		CFRelease(store);
	}
	if (publicKey) CFRelease(publicKey);
	if (rootPrivateKey) CFRelease(rootPrivateKey);
	if (ownKey) CFRelease(ownKey);
	return ok;
}

static bool
testCrossProcessStore(void)
{
	int parentToChild[2], childToParent[2];
	check(pipe(parentToChild) == 0 && pipe(childToParent) == 0,
	    "create notification test pipes");
	CFStringRef notifyKey = uniqueKey("Notify", getpid());
	CFStringRef temporaryKey = uniqueKey("Temporary", getpid());
	check(notifyKey && temporaryKey, "create dynamic-store test keys");
	char notifyText[1024], temporaryText[1024];
	check(CFStringGetCString(notifyKey, notifyText, sizeof(notifyText),
	    kCFStringEncodingUTF8) &&
	    CFStringGetCString(temporaryKey, temporaryText, sizeof(temporaryText),
	        kCFStringEncodingUTF8), "convert dynamic-store test keys");
	int childRead = fcntl(parentToChild[0], F_DUPFD_CLOEXEC, 64);
	int childWrite = fcntl(childToParent[1], F_DUPFD_CLOEXEC, 64);
	check(childRead >= 0 && childWrite >= 0,
	    "copy the child communication pipe handles");
	posix_spawn_file_actions_t actions;
	check(posix_spawn_file_actions_init(&actions) == 0,
	    "prepare the notification listener process");
	int spawnError = posix_spawn_file_actions_adddup2(&actions, childRead, 3);
	if (spawnError == 0)
		spawnError = posix_spawn_file_actions_adddup2(&actions, childWrite, 4);
	int descriptors[] = {
		parentToChild[0], parentToChild[1], childToParent[0], childToParent[1],
		childRead, childWrite,
	};
	for (size_t i = 0; spawnError == 0 && i < sizeof(descriptors) / sizeof(*descriptors); i++)
		if (descriptors[i] != 3 && descriptors[i] != 4)
			spawnError = posix_spawn_file_actions_addclose(&actions, descriptors[i]);
	check(spawnError == 0, "set up the notification listener pipes");
	char *childArguments[] = {
		testProgramPath,
		(char *)"--notify-listener",
		notifyText,
		temporaryText,
		NULL,
	};
	pid_t child = 0;
	spawnError = posix_spawnp(&child, childArguments[0], &actions, NULL,
	    childArguments, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(childRead);
	close(childWrite);
	check(spawnError == 0, "start the notification listener process");

	close(parentToChild[0]);
	close(childToParent[1]);
	char ready = 0;
	bool setup = readByte(childToParent[0], &ready) && ready == 'R';
	SCDynamicStoreRef writer = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd notification writer"), NULL, NULL);
	bool changed = setup && writer &&
	    SCDynamicStoreSetValue(writer, notifyKey, CFSTR("cross-process value"));
	if (setup)
		(void)writeByte(parentToChild[1], 'G');
	char notified = 0;
	bool sawNotification = setup && readByte(childToParent[0], &notified) &&
	    notified == 'N';
	CFPropertyListRef temporary = writer ?
	    SCDynamicStoreCopyValue(writer, temporaryKey) : NULL;
	bool temporaryVisible = temporary &&
	    CFEqual(temporary, CFSTR("temporary value"));
	if (temporary) CFRelease(temporary);
	if (setup)
		(void)writeByte(parentToChild[1], 'D');
	if (writer) CFRelease(writer);
	int childStatus = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &childStatus, 0);
	} while (waited < 0 && errno == EINTR);

	bool temporaryRemoved = false;
	for (unsigned i = 0; i < 100 && !temporaryRemoved; i++) {
		SCDynamicStoreRef checkStore = SCDynamicStoreCreate(NULL,
		    CFSTR("Finch configd temporary cleanup check"), NULL, NULL);
		CFPropertyListRef after = checkStore ?
		    SCDynamicStoreCopyValue(checkStore, temporaryKey) : NULL;
		temporaryRemoved = after == NULL;
		if (after) CFRelease(after);
		if (checkStore) CFRelease(checkStore);
		if (!temporaryRemoved)
			usleep(20000);
	}

	SCDynamicStoreRef cleanup = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd test cleanup"), NULL, NULL);
	if (cleanup) {
		(void)SCDynamicStoreRemoveValue(cleanup, notifyKey);
		CFRelease(cleanup);
	}
	CFRelease(temporaryKey);
	CFRelease(notifyKey);
	close(parentToChild[1]);
	close(childToParent[0]);
	return changed && sawNotification && temporaryVisible && temporaryRemoved &&
	    waited == child && WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0;
}

static int
runListenerFromArguments(int argc, char **argv)
{
	if (argc != 4)
		return 2;
	CFStringRef notifyKey = CFStringCreateWithCString(NULL, argv[2],
	    kCFStringEncodingUTF8);
	CFStringRef temporaryKey = CFStringCreateWithCString(NULL, argv[3],
	    kCFStringEncodingUTF8);
	if (!notifyKey || !temporaryKey)
		return 3;
	int status = runNotificationListener(3, 4, notifyKey, temporaryKey);
	CFRelease(temporaryKey);
	CFRelease(notifyKey);
	return status;
}

static int
testUnavailable(void)
{
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL,
	    CFSTR("Finch configd unavailable test"), NULL, NULL);
	CFStringRef key = uniqueKey("Unavailable", getpid());
	check(store && key, "create unavailable-server test values");
	Boolean changed = SCDynamicStoreSetValue(store, key, CFSTR("must not be stored"));
	bool noStoreServer = !changed && SCError() == kSCStatusNoStoreServer;

	SCPreferencesRef prefs = SCPreferencesCreate(NULL,
	    CFSTR("Finch configd unavailable preferences"), NULL);
	CFStringRef marker = uniqueKey("UnavailablePreference", getpid());
	bool noPrefsServer = prefs && marker &&
	    SCPreferencesSetValue(prefs, marker, CFSTR("must not be saved")) &&
	    !SCPreferencesCommitChanges(prefs) &&
	    SCError() == kSCStatusNoStoreServer;
	if (prefs) CFRelease(prefs);
	CFRelease(key);
	CFRelease(store);
	check(noStoreServer && noPrefsServer,
	    "dynamic-store and preferences writes report an unavailable service");
	puts("configd-service: PASS (unavailable service)");
	return 0;
}

int
main(int argc, char **argv)
{
	testProgramPath = argv[0];
	check(finchConfigdTestEnvironment(), "run service tests only inside Finch's VM image");
	if (argc >= 2 && strcmp(argv[1], "--notify-listener") == 0)
		return runListenerFromArguments(argc, argv);
	if (argc >= 2 && strcmp(argv[1], "--store-permission-check") == 0)
		return runStorePermissionCheck(argc, argv);
	if (argc == 2 && strcmp(argv[1], "--preferences-denied-check") == 0)
		return runPreferencesDeniedCheck();
	if (argc == 2 && strcmp(argv[1], "--unavailable") == 0)
		return testUnavailable();
	if (argc == 2 && strcmp(argv[1], "--preferences-restart") == 0) {
		check(geteuid() == 0, "run the restart test as root inside Finch");
		check(testRootPreferences(true), "saved preferences survive service restart");
		puts("configd-service: PASS (saved preferences survive configd restart)");
		return 0;
	}
	if (argc == 2 && strcmp(argv[1], "--subscription-restart") == 0) {
		check(geteuid() == 0, "run the restart test as root inside Finch");
		check(finchConfigdTestEnvironment(),
		    "run the restart test only in the Finch VM image");
		check(testSubscriptionRestartRecovery(),
		    "an existing dynamic-store watch resumes after configd restarts");
		puts("configd-service: PASS (subscription survives configd restart)");
		return 0;
	}
	if (argc == 2 && strcmp(argv[1], "--store-only") == 0) {
		check(geteuid() == 0, "run service tests as root inside Finch");
		check(testDynamicStorePermissions(), "root and nonroot dynamic-store access");
		check(testCrossProcessStore(), "cross-process notification and temporary-key cleanup");
		puts("configd-service: PASS (store access, notifications, temporary keys)");
		return 0;
	}
	check(argc == 1,
	    "use no option, --store-only, --preferences-restart, --subscription-restart, or --unavailable");
	check(geteuid() == 0, "run service tests as root inside Finch");
	check(testRootPreferences(false), "root preference commit and readback");
	check(testNonrootWriteDenied(), "nonroot system preference writes are denied");
	check(testDynamicStorePermissions(), "root and nonroot dynamic-store access");
	check(testCrossProcessStore(), "cross-process notification and temporary-key cleanup");
	puts("configd-service: PASS (service, root preferences, permissions, notifications, temporary keys)");
	return 0;
}

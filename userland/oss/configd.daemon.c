/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's configd service.
 *
 * The pinned Apple configd source (configd-1405.100.8) uses a private MIG
 * transport and a large set of platform plug-ins. Finch's client framework
 * uses its own small XPC protocol instead. This process is the shared owner of
 * dynamic-store values and preference writes. Network state that comes from
 * the kernel is still read from the kernel by SystemConfiguration.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <pthread.h>
#include <pwd.h>
#include <regex.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

#define CONFIGD_SERVICE "com.apple.SystemConfiguration.configd"
#define SYSTEM_PREFS_ROOT "/Library/Preferences/SystemConfiguration"
#define SYSTEM_PREFS_PATH SYSTEM_PREFS_ROOT "/preferences.plist"
#define MAX_PLIST_SIZE (16 * 1024 * 1024)

/* The message carries the kernel token captured when it was received. */
void xpc_dictionary_get_audit_token(xpc_object_t message, audit_token_t *token);

enum {
	SC_OK = 0,
	SC_FAILED = 1001,
	SC_INVALID_ARGUMENT = 1002,
	SC_ACCESS_ERROR = 1003,
	SC_NO_KEY = 1004,
	SC_KEY_EXISTS = 1005,
	SC_LOCKED = 1006,
	SC_NEED_LOCK = 1007,
	SC_NO_STORE_SERVER = 2002,
	SC_NO_PREFS_SESSION = 3001,
	SC_PREFS_BUSY = 3002,
	SC_STALE = 3005,
};

typedef struct Peer Peer;
typedef struct PrefsLock PrefsLock;

struct PrefsLock {
	char path[PATH_MAX];
	CFDataRef signature;
	int fd;
	PrefsLock *next;
};

struct Peer {
	xpc_connection_t connection; /* owned by the XPC receive source */
	uid_t uid;
	pid_t pid;
	uint64_t identifier;
	CFArrayRef watchedKeys;
	CFArrayRef watchedPatterns;
	PrefsLock *locks;
	Peer *next;
};

static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef dynamicValues;
static CFMutableDictionaryRef temporaryOwners;
static Peer *peers;
static uint64_t nextPeerIdentifier = 1;
static char preferencesRoot[PATH_MAX] = SYSTEM_PREFS_ROOT;

static CFMutableDictionaryRef
newDictionary(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
}

static bool
stringFromCF(CFStringRef value, char *buffer, size_t capacity)
{
	if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID() ||
	    buffer == NULL || capacity == 0 || capacity > LONG_MAX)
		return false;
	CFIndex length = CFStringGetLength(value), used = 0;
	CFIndex converted = CFStringGetBytes(value, CFRangeMake(0, length),
	    kCFStringEncodingUTF8, 0, false, (UInt8 *)buffer, (CFIndex)capacity - 1, &used);
	if (converted != length || memchr(buffer, '\0', (size_t)used) != NULL)
		return false;
	buffer[used] = '\0';
	return true;
}

static CFStringRef
stringFromUTF8(const char *value)
{
	return CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
}

static CFPropertyListRef
propertyListFromXPC(xpc_object_t request, const char *name)
{
	xpc_object_t data = xpc_dictionary_get_value(request, name);
	if (data == NULL || xpc_get_type(data) != XPC_TYPE_DATA)
		return NULL;
	size_t length = xpc_data_get_length(data);
	if (length == 0 || length > MAX_PLIST_SIZE)
		return NULL;
	CFDataRef bytes = CFDataCreate(NULL, xpc_data_get_bytes_ptr(data), (CFIndex)length);
	if (bytes == NULL)
		return NULL;
	CFPropertyListRef value = CFPropertyListCreateWithData(NULL, bytes,
	    kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
	CFRelease(bytes);
	if (value == NULL || !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0)) {
		if (value)
			CFRelease(value);
		return NULL;
	}
	return value;
}

static xpc_object_t
propertyListToXPC(CFPropertyListRef value)
{
	if (value == NULL || !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0))
		return NULL;
	CFErrorRef error = NULL;
	CFDataRef bytes = CFPropertyListCreateData(NULL, value, kCFPropertyListBinaryFormat_v1_0,
	    0, &error);
	if (bytes == NULL) {
		if (error)
			CFRelease(error);
		return NULL;
	}
	xpc_object_t data = xpc_data_create(CFDataGetBytePtr(bytes), (size_t)CFDataGetLength(bytes));
	CFRelease(bytes);
	if (error)
		CFRelease(error);
	return data;
}

static CFDataRef
signatureForPath(const char *path)
{
	struct {
		uint64_t dev, ino, size;
		int64_t sec, nsec;
	} signature = {0};
	struct stat st;
	if (stat(path, &st) == 0) {
		signature.dev = (uint64_t)st.st_dev;
		signature.ino = (uint64_t)st.st_ino;
		signature.size = (uint64_t)st.st_size;
		signature.sec = (int64_t)st.st_mtimespec.tv_sec;
		signature.nsec = (int64_t)st.st_mtimespec.tv_nsec;
	}
	return CFDataCreate(NULL, (const UInt8 *)&signature, sizeof(signature));
}

static bool
safeAbsolutePath(const char *path)
{
	if (path == NULL || path[0] != '/' || strlen(path) >= PATH_MAX)
		return false;
	const char *p = path;
	while (*p) {
		while (*p == '/')
			p++;
		const char *start = p;
		while (*p && *p != '/')
			p++;
		size_t n = (size_t)(p - start);
		if ((n == 1 && start[0] == '.') || (n == 2 && start[0] == '.' && start[1] == '.'))
			return false;
	}
	return true;
}

/* The daemon runs as root, so check the caller's visible file permissions
 * before opening a preferences file on its behalf. Group-only access is
 * treated conservatively as unavailable. */
static bool
callerHasMode(uid_t uid, const struct stat *st, mode_t ownerBit, mode_t otherBit)
{
	return uid == 0 || (st->st_uid == uid && (st->st_mode & ownerBit)) ||
	    (st->st_uid != uid && (st->st_mode & otherBit));
}

static bool
callerCanTraverseDirectories(uid_t uid, const char *directory)
{
	if (uid == 0)
		return true;
	char path[PATH_MAX];
	if (strlcpy(path, directory, sizeof(path)) >= sizeof(path))
		return false;
	if (path[0] != '/')
		return false;
	for (char *p = path + 1; ; p++) {
		if (*p != '/' && *p != '\0')
			continue;
		char saved = *p;
		*p = '\0';
		struct stat st;
		bool allowed = stat(path, &st) == 0 && S_ISDIR(st.st_mode) &&
		    callerHasMode(uid, &st, S_IXUSR, S_IXOTH);
		*p = saved;
		if (!allowed)
			return false;
		if (saved == '\0')
			break;
	}
	return true;
}

static bool
trustedSystemPreferencesRoot(char root[PATH_MAX])
{
	if (strcmp(preferencesRoot, SYSTEM_PREFS_ROOT) != 0 ||
	    strlcpy(root, preferencesRoot, PATH_MAX) >= PATH_MAX)
		return false;
	int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return false;
	const char *components[] = {"Library", "Preferences", "SystemConfiguration"};
	bool valid = true;
	for (size_t i = 0; i < sizeof(components) / sizeof(*components); i++) {
		int next = openat(fd, components[i],
		    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
		if (next < 0) {
			valid = false;
			break;
		}
		struct stat st;
		if (fstat(next, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
		    (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
			close(next);
			valid = false;
			break;
		}
		close(fd);
		fd = next;
	}
	close(fd);
	return valid;
}

/*
 * This slice only serves the system preferences directory. The daemon refuses
 * arbitrary preference paths until it can keep user-path authorization tied
 * to the same directory descriptors used for each read and write.
 */
static bool
authorizePreferencesPath(const char *path, uid_t uid, bool writeAccess,
    char canonical[PATH_MAX], struct stat *targetStat, struct stat *directoryStat)
{
	if (!safeAbsolutePath(path))
		return false;
	char root[PATH_MAX];
	if (!trustedSystemPreferencesRoot(root))
		return false;
	size_t rootLength = strlen(root);
	bool systemPath = strncmp(path, root, rootLength) == 0 && path[rootLength] == '/';
	if (!systemPath)
		return false;
	const char *leaf = path + rootLength + 1;
	if (*leaf == '\0' || strchr(leaf, '/') != NULL || strlen(leaf) > NAME_MAX)
		return false;
	if (writeAccess && uid != 0)
		return false;
	if (strlcpy(canonical, path, PATH_MAX) >= PATH_MAX)
		return false;
	struct stat st = {0};
	bool targetExists = lstat(canonical, &st) == 0;
	if (!targetExists && errno != ENOENT)
		return false;
	if (targetExists && (!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)))
		return false;
	struct stat dirStat;
	if (stat(root, &dirStat) < 0 || !S_ISDIR(dirStat.st_mode) ||
	    dirStat.st_uid != 0 || (dirStat.st_mode & (S_IWGRP | S_IWOTH)) != 0)
		return false;
	if (!writeAccess &&
	    (!callerCanTraverseDirectories(uid, root) ||
	     (targetExists && !callerHasMode(uid, &st, S_IRUSR, S_IROTH))))
		return false;
	if (targetStat)
		*targetStat = st;
	if (directoryStat)
		*directoryStat = dirStat;
	return true;
}

static bool
pathForRequest(xpc_object_t request, uid_t uid, bool writeAccess,
    char canonical[PATH_MAX], struct stat *targetStat, struct stat *directoryStat)
{
	const char *path = xpc_dictionary_get_string(request, "path");
	return authorizePreferencesPath(path, uid, writeAccess, canonical, targetStat, directoryStat);
}

static bool
isUserDynamicKey(uid_t uid, CFStringRef key)
{
	char name[1024];
	if (!stringFromCF(key, name, sizeof(name)))
		return false;
	const char prefix[] = "State:/Users/";
	if (strncmp(name, prefix, sizeof(prefix) - 1) != 0)
		return false;
	const char *start = name + sizeof(prefix) - 1;
	char *end = NULL;
	unsigned long parsed = strtoul(start, &end, 10);
	return end != start && *end == '/' && parsed == (unsigned long)uid;
}

static bool
authorizeDynamicKey(uid_t uid, CFStringRef key)
{
	return key != NULL && CFGetTypeID(key) == CFStringGetTypeID() &&
	    (uid == 0 || isUserDynamicKey(uid, key));
}

static bool
dynamicKeyReadableBy(uid_t uid, CFStringRef key)
{
	if (uid == 0)
		return true;
	char name[1024];
	if (!stringFromCF(key, name, sizeof(name)))
		return false;
	const char prefix[] = "State:/Users/";
	if (strncmp(name, prefix, sizeof(prefix) - 1) != 0)
		return true;
	const char *start = name + sizeof(prefix) - 1;
	char *end = NULL;
	unsigned long parsed = strtoul(start, &end, 10);
	/* The console-user summary is public; numeric per-user state is private. */
	if (end == start || *end != '/')
		return true;
	return parsed == (unsigned long)uid;
}

static bool
compileKeyPattern(CFStringRef pattern, regex_t *compiled)
{
	char text[1024], anchored[1100];
	if (!stringFromCF(pattern, text, sizeof(text)))
		return false;
	if ((size_t)snprintf(anchored, sizeof(anchored), "^(%s)$", text) >= sizeof(anchored))
		return false;
	return regcomp(compiled, anchored, REG_EXTENDED | REG_NOSUB) == 0;
}

static bool
matchesPattern(CFStringRef key, CFStringRef pattern)
{
	regex_t compiled;
	char text[1024];
	if (!stringFromCF(key, text, sizeof(text)) || !compileKeyPattern(pattern, &compiled))
		return false;
	bool matches = regexec(&compiled, text, 0, NULL, 0) == 0;
	regfree(&compiled);
	return matches;
}

static bool
peerWatches(Peer *peer, CFStringRef key)
{
	if (peer->watchedKeys && CFArrayContainsValue(peer->watchedKeys,
	    CFRangeMake(0, CFArrayGetCount(peer->watchedKeys)), key))
		return true;
	for (CFIndex i = 0; peer->watchedPatterns && i < CFArrayGetCount(peer->watchedPatterns); i++)
		if (matchesPattern(key, CFArrayGetValueAtIndex(peer->watchedPatterns, i)))
			return true;
	return false;
}

static CFMutableArrayRef
uniqueKeys(CFArrayRef input)
{
	CFMutableArrayRef output = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; input && i < CFArrayGetCount(input); i++) {
		CFTypeRef key = CFArrayGetValueAtIndex(input, i);
		if (key && CFGetTypeID(key) == CFStringGetTypeID() &&
		    !CFArrayContainsValue(output, CFRangeMake(0, CFArrayGetCount(output)), key))
			CFArrayAppendValue(output, key);
	}
	return output;
}

static xpc_object_t
xpcArrayFromStrings(CFArrayRef keys)
{
	xpc_object_t output = xpc_array_create(NULL, 0);
	for (CFIndex i = 0; keys && i < CFArrayGetCount(keys); i++) {
		char text[1024];
		if (stringFromCF(CFArrayGetValueAtIndex(keys, i), text, sizeof(text))) {
			xpc_object_t value = xpc_string_create(text);
			xpc_array_append_value(output, value);
			xpc_release(value);
		}
	}
	return output;
}

static void
notifyPeers(CFArrayRef changedKeys)
{
	CFArrayRef keys = uniqueKeys(changedKeys);
	if (CFArrayGetCount(keys) == 0) {
		CFRelease(keys);
		return;
	}
	xpc_connection_t *targets = NULL;
	size_t count = 0;
	pthread_mutex_lock(&stateLock);
	for (Peer *peer = peers; peer; peer = peer->next) {
		bool matches = false;
		for (CFIndex i = 0; !matches && i < CFArrayGetCount(keys); i++)
			matches = dynamicKeyReadableBy(peer->uid, CFArrayGetValueAtIndex(keys, i)) &&
			    peerWatches(peer, CFArrayGetValueAtIndex(keys, i));
		if (matches)
			count++;
	}
	targets = calloc(count ? count : 1, sizeof(*targets));
	if (targets) {
		size_t j = 0;
		for (Peer *peer = peers; peer; peer = peer->next) {
			bool matches = false;
			for (CFIndex i = 0; !matches && i < CFArrayGetCount(keys); i++)
				matches = dynamicKeyReadableBy(peer->uid, CFArrayGetValueAtIndex(keys, i)) &&
				    peerWatches(peer, CFArrayGetValueAtIndex(keys, i));
			if (matches) {
				targets[j++] = xpc_retain(peer->connection);
			}
		}
		count = j;
	} else {
		count = 0;
	}
	pthread_mutex_unlock(&stateLock);

	xpc_object_t xkeys = xpcArrayFromStrings(keys);
	for (size_t i = 0; i < count; i++) {
		xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_string(event, "event", "store.changed");
		xpc_dictionary_set_value(event, "keys", xkeys);
		xpc_connection_send_message(targets[i], event);
		xpc_release(event);
		xpc_release(targets[i]);
	}
	xpc_release(xkeys);
	free(targets);
	CFRelease(keys);
}

static void
removeTemporaryValues(Peer *peer)
{
	CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFNumberRef id = CFNumberCreate(NULL, kCFNumberSInt64Type, &peer->identifier);
	pthread_mutex_lock(&stateLock);
	if (temporaryOwners) {
		CFIndex count = CFDictionaryGetCount(temporaryOwners);
		const void **keys = calloc(count ? (size_t)count : 1, sizeof(*keys));
		const void **owners = calloc(count ? (size_t)count : 1, sizeof(*owners));
		if (keys && owners) {
			CFDictionaryGetKeysAndValues(temporaryOwners, keys, owners);
			for (CFIndex i = 0; i < count; i++) {
				if (CFEqual(owners[i], id)) {
					if (dynamicValues && CFDictionaryContainsKey(dynamicValues, keys[i])) {
						CFArrayAppendValue(changed, keys[i]);
						CFDictionaryRemoveValue(dynamicValues, keys[i]);
					}
					CFDictionaryRemoveValue(temporaryOwners, keys[i]);
				}
			}
		}
		free(keys);
		free(owners);
	}
	pthread_mutex_unlock(&stateLock);
	CFRelease(id);
	notifyPeers(changed);
	CFRelease(changed);
}

static void
peerFinalizer(void *context)
{
	Peer *peer = context;
	if (peer == NULL)
		return;
	pthread_mutex_lock(&stateLock);
	Peer **p = &peers;
	while (*p && *p != peer)
		p = &(*p)->next;
	if (*p == peer)
		*p = peer->next;
	pthread_mutex_unlock(&stateLock);

	removeTemporaryValues(peer);
	PrefsLock *lock = peer->locks;
	while (lock) {
		PrefsLock *next = lock->next;
		if (lock->fd >= 0) {
			(void)flock(lock->fd, LOCK_UN);
			close(lock->fd);
		}
		if (lock->signature)
			CFRelease(lock->signature);
		free(lock);
		lock = next;
	}
	if (peer->watchedKeys)
		CFRelease(peer->watchedKeys);
	if (peer->watchedPatterns)
		CFRelease(peer->watchedPatterns);
	free(peer);
}

static int
dynamicCopyAll(Peer *peer, uid_t uid, xpc_object_t reply)
{
	pthread_mutex_lock(&stateLock);
	if (dynamicValues == NULL)
		dynamicValues = newDictionary();
	CFMutableDictionaryRef values = newDictionary();
	CFIndex count = CFDictionaryGetCount(dynamicValues);
	const void **keys = calloc(count ? (size_t)count : 1, sizeof(*keys));
	const void **items = calloc(count ? (size_t)count : 1, sizeof(*items));
	if (keys && items) {
		CFDictionaryGetKeysAndValues(dynamicValues, keys, items);
		for (CFIndex i = 0; i < count; i++)
			if (dynamicKeyReadableBy(uid, keys[i]))
				CFDictionarySetValue(values, keys[i], items[i]);
	} else {
		CFRelease(values);
		values = NULL;
	}
	free(keys);
	free(items);
	pthread_mutex_unlock(&stateLock);
	if (values == NULL)
		return SC_FAILED;
	xpc_object_t data = propertyListToXPC(values);
	CFRelease(values);
	if (data == NULL)
		return SC_FAILED;
	xpc_dictionary_set_value(reply, "plist", data);
	xpc_release(data);
	(void)peer;
	return SC_OK;
}

static bool
validPropertyArray(CFPropertyListRef value)
{
	if (value == NULL || CFGetTypeID(value) != CFArrayGetTypeID())
		return false;
	for (CFIndex i = 0; i < CFArrayGetCount(value); i++)
		if (CFGetTypeID(CFArrayGetValueAtIndex(value, i)) != CFStringGetTypeID())
			return false;
	return true;
}

static int
dynamicSubscribe(Peer *peer, xpc_object_t request)
{
	CFPropertyListRef keys = propertyListFromXPC(request, "keys");
	CFPropertyListRef patterns = propertyListFromXPC(request, "patterns");
	if (!validPropertyArray(keys) || !validPropertyArray(patterns)) {
		if (keys) CFRelease(keys);
		if (patterns) CFRelease(patterns);
		return SC_INVALID_ARGUMENT;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(patterns); i++) {
		regex_t compiled;
		if (!compileKeyPattern(CFArrayGetValueAtIndex(patterns, i), &compiled)) {
			CFRelease(keys);
			CFRelease(patterns);
			return SC_INVALID_ARGUMENT;
		}
		regfree(&compiled);
	}
	pthread_mutex_lock(&stateLock);
	if (peer->watchedKeys)
		CFRelease(peer->watchedKeys);
	if (peer->watchedPatterns)
		CFRelease(peer->watchedPatterns);
	peer->watchedKeys = CFArrayCreateCopy(NULL, keys);
	peer->watchedPatterns = CFArrayCreateCopy(NULL, patterns);
	pthread_mutex_unlock(&stateLock);
	CFRelease(keys);
	CFRelease(patterns);
	return SC_OK;
}

static void
appendKey(CFMutableArrayRef keys, CFStringRef key)
{
	if (key && !CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), key))
		CFArrayAppendValue(keys, key);
}

static int
dynamicSetValue(Peer *peer, uid_t uid, CFStringRef key, CFPropertyListRef value,
    bool add, bool temporary)
{
	if (!authorizeDynamicKey(uid, key) || value == NULL ||
	    !CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0))
		return uid != 0 && !isUserDynamicKey(uid, key) ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
	CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	pthread_mutex_lock(&stateLock);
	if (dynamicValues == NULL)
		dynamicValues = newDictionary();
	if (add && CFDictionaryContainsKey(dynamicValues, key)) {
		pthread_mutex_unlock(&stateLock);
		CFRelease(changed);
		return SC_KEY_EXISTS;
	}
	CFDictionarySetValue(dynamicValues, key, value);
	if (temporary) {
		if (temporaryOwners == NULL)
			temporaryOwners = newDictionary();
		CFNumberRef id = CFNumberCreate(NULL, kCFNumberSInt64Type, &peer->identifier);
		CFDictionarySetValue(temporaryOwners, key, id);
		CFRelease(id);
	} else if (temporaryOwners) {
		CFDictionaryRemoveValue(temporaryOwners, key);
	}
	appendKey(changed, key);
	pthread_mutex_unlock(&stateLock);
	notifyPeers(changed);
	CFRelease(changed);
	return SC_OK;
}

static int
dynamicRemoveValue(uid_t uid, CFStringRef key, CFMutableArrayRef changed)
{
	if (!authorizeDynamicKey(uid, key))
		return uid != 0 && !isUserDynamicKey(uid, key) ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
	pthread_mutex_lock(&stateLock);
	bool exists = dynamicValues && CFDictionaryContainsKey(dynamicValues, key);
	if (exists) {
		CFDictionaryRemoveValue(dynamicValues, key);
		if (temporaryOwners)
			CFDictionaryRemoveValue(temporaryOwners, key);
		appendKey(changed, key);
	}
	pthread_mutex_unlock(&stateLock);
	return exists ? SC_OK : SC_NO_KEY;
}

static int
dynamicSetMultiple(Peer *peer, uid_t uid, xpc_object_t request)
{
	CFPropertyListRef sets = propertyListFromXPC(request, "sets");
	CFPropertyListRef removes = propertyListFromXPC(request, "removes");
	CFPropertyListRef notifies = propertyListFromXPC(request, "notifies");
	if (sets == NULL || CFGetTypeID(sets) != CFDictionaryGetTypeID() ||
	    !validPropertyArray(removes) || !validPropertyArray(notifies)) {
		if (sets) CFRelease(sets);
		if (removes) CFRelease(removes);
		if (notifies) CFRelease(notifies);
		return SC_INVALID_ARGUMENT;
	}
	CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	int status = SC_OK;
	CFIndex setCount = CFDictionaryGetCount(sets);
	const void **setKeys = calloc(setCount ? (size_t)setCount : 1, sizeof(*setKeys));
	const void **setValues = calloc(setCount ? (size_t)setCount : 1, sizeof(*setValues));
	if (setKeys == NULL || setValues == NULL)
		status = SC_FAILED;
	if (status == SC_OK) {
		CFDictionaryGetKeysAndValues(sets, setKeys, setValues);
		for (CFIndex i = 0; i < setCount; i++) {
			if (!authorizeDynamicKey(uid, setKeys[i])) {
				status = uid != 0 && !isUserDynamicKey(uid, setKeys[i]) ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
				break;
			}
			if (!CFPropertyListIsValid(setValues[i], kCFPropertyListBinaryFormat_v1_0)) {
				status = SC_INVALID_ARGUMENT;
				break;
			}
		}
		for (CFIndex i = 0; status == SC_OK && i < CFArrayGetCount(removes); i++) {
			CFStringRef key = CFArrayGetValueAtIndex(removes, i);
			if (!authorizeDynamicKey(uid, key))
				status = uid != 0 && !isUserDynamicKey(uid, key) ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
		}
		for (CFIndex i = 0; status == SC_OK && i < CFArrayGetCount(notifies); i++) {
			CFStringRef key = CFArrayGetValueAtIndex(notifies, i);
			if (!authorizeDynamicKey(uid, key))
				status = uid != 0 && !isUserDynamicKey(uid, key) ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
		}
	}
	if (status == SC_OK) {
		pthread_mutex_lock(&stateLock);
		if (dynamicValues == NULL)
			dynamicValues = newDictionary();
		for (CFIndex i = 0; i < setCount; i++) {
			CFDictionarySetValue(dynamicValues, setKeys[i], setValues[i]);
			if (temporaryOwners)
				CFDictionaryRemoveValue(temporaryOwners, setKeys[i]);
			appendKey(changed, setKeys[i]);
		}
		for (CFIndex i = 0; i < CFArrayGetCount(removes); i++) {
			CFStringRef key = CFArrayGetValueAtIndex(removes, i);
			if (CFDictionaryContainsKey(dynamicValues, key)) {
				CFDictionaryRemoveValue(dynamicValues, key);
				if (temporaryOwners)
					CFDictionaryRemoveValue(temporaryOwners, key);
				appendKey(changed, key);
			}
		}
		for (CFIndex i = 0; i < CFArrayGetCount(notifies); i++)
			appendKey(changed, CFArrayGetValueAtIndex(notifies, i));
		pthread_mutex_unlock(&stateLock);
	}
	free(setKeys);
	free(setValues);
	CFRelease(sets);
	CFRelease(removes);
	CFRelease(notifies);
	if (status == SC_OK)
		notifyPeers(changed);
	CFRelease(changed);
	(void)peer;
	return status;
}

static CFDictionaryRef
readPreferenceDictionary(const char *path, CFDataRef *signature, int *status)
{
	*status = SC_OK;
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0 && errno != ENOENT) {
		*status = errno == EACCES || errno == EPERM ? SC_ACCESS_ERROR : SC_FAILED;
		return NULL;
	}
	if (fd < 0) {
		CFMutableDictionaryRef empty = newDictionary();
		if (signature)
			*signature = signatureForPath(path);
		return empty;
	}
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
	    st.st_size > MAX_PLIST_SIZE) {
		close(fd);
		*status = SC_FAILED;
		return NULL;
	}
	CFMutableDictionaryRef dictionary = NULL;
	if (st.st_size == 0) {
		dictionary = newDictionary();
	} else {
		CFMutableDataRef data = CFDataCreateMutable(NULL, (CFIndex)st.st_size);
		CFDataSetLength(data, (CFIndex)st.st_size);
		uint8_t *bytes = CFDataGetMutableBytePtr(data);
		size_t offset = 0;
		while (offset < (size_t)st.st_size) {
			ssize_t n = pread(fd, bytes + offset, (size_t)st.st_size - offset, (off_t)offset);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;
			offset += (size_t)n;
		}
		if (offset == (size_t)st.st_size) {
			CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data,
			    kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
			if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID())
				dictionary = (CFMutableDictionaryRef)plist;
			else if (plist)
				CFRelease(plist);
		}
		CFRelease(data);
		if (dictionary == NULL)
			*status = SC_FAILED;
	}
	close(fd);
	if (signature)
		*signature = signatureForPath(path);
	return dictionary;
}

static PrefsLock *
findPrefsLock(Peer *peer, const char *path)
{
	for (PrefsLock *lock = peer->locks; lock; lock = lock->next)
		if (strcmp(lock->path, path) == 0)
			return lock;
	return NULL;
}

static int
prefsRead(Peer *peer, uid_t uid, xpc_object_t request, xpc_object_t reply)
{
	char path[PATH_MAX];
	if (!pathForRequest(request, uid, false, path, NULL, NULL))
		return SC_INVALID_ARGUMENT;
	int status = SC_OK;
	CFDataRef signature = NULL;
	CFDictionaryRef prefs = readPreferenceDictionary(path, &signature, &status);
	if (status != SC_OK || prefs == NULL) {
		if (signature) CFRelease(signature);
		if (prefs) CFRelease(prefs);
		return status;
	}
	xpc_object_t data = propertyListToXPC(prefs);
	if (data == NULL) {
		CFRelease(signature);
		CFRelease(prefs);
		return SC_FAILED;
	}
	xpc_dictionary_set_value(reply, "plist", data);
	xpc_dictionary_set_data(reply, "signature", CFDataGetBytePtr(signature),
	    (size_t)CFDataGetLength(signature));
	xpc_release(data);
	CFRelease(signature);
	CFRelease(prefs);
	(void)peer;
	return SC_OK;
}

static int
prefsLock(Peer *peer, uid_t uid, xpc_object_t request)
{
	char path[PATH_MAX];
	struct stat targetStat = {0}, directoryStat = {0};
	if (!pathForRequest(request, uid, true, path, &targetStat, &directoryStat))
		return uid != 0 ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
	if (findPrefsLock(peer, path))
		return SC_LOCKED;
	xpc_object_t expected = xpc_dictionary_get_value(request, "signature");
	if (expected == NULL || xpc_get_type(expected) != XPC_TYPE_DATA)
		return SC_INVALID_ARGUMENT;
	char lockPath[PATH_MAX];
	if ((size_t)snprintf(lockPath, sizeof(lockPath), "%s.lock", path) >= sizeof(lockPath))
		return SC_INVALID_ARGUMENT;
	int fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return errno == EACCES || errno == EPERM ? SC_ACCESS_ERROR : SC_FAILED;
	int operation = LOCK_EX | (xpc_dictionary_get_bool(request, "wait") ? 0 : LOCK_NB);
	if (flock(fd, operation) < 0) {
		int err = errno;
		close(fd);
		return (err == EWOULDBLOCK || err == EAGAIN) ? SC_PREFS_BUSY : SC_FAILED;
	}
	CFDataRef current = signatureForPath(path);
	const void *expectedBytes = xpc_data_get_bytes_ptr(expected);
	size_t expectedLength = xpc_data_get_length(expected);
	bool same = current && expectedLength == (size_t)CFDataGetLength(current) &&
	    memcmp(expectedBytes, CFDataGetBytePtr(current), expectedLength) == 0;
	if (!same) {
		CFRelease(current);
		(void)flock(fd, LOCK_UN);
		close(fd);
		return SC_STALE;
	}
	PrefsLock *lock = calloc(1, sizeof(*lock));
	if (lock == NULL) {
		CFRelease(current);
		(void)flock(fd, LOCK_UN);
		close(fd);
		return SC_FAILED;
	}
	strlcpy(lock->path, path, sizeof(lock->path));
	lock->signature = current;
	lock->fd = fd;
	lock->next = peer->locks;
	peer->locks = lock;
	(void)targetStat;
	(void)directoryStat;
	return SC_OK;
}

static bool
writeAll(int fd, const UInt8 *bytes, size_t length)
{
	size_t offset = 0;
	while (offset < length) {
		ssize_t n = write(fd, bytes + offset, length - offset);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return false;
		offset += (size_t)n;
	}
	return true;
}

static int
atomicWritePreferences(const char *path, CFDataRef data, const struct stat *oldStat,
    const struct stat *directoryStat)
{
	char directory[PATH_MAX], leaf[NAME_MAX + 1], temp[NAME_MAX + 1];
	strlcpy(directory, path, sizeof(directory));
	char *slash = strrchr(directory, '/');
	if (slash == NULL || strlen(slash + 1) > NAME_MAX)
		return SC_INVALID_ARGUMENT;
	strlcpy(leaf, slash + 1, sizeof(leaf));
	*slash = '\0';
	int dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (dirfd < 0)
		return errno == EACCES || errno == EPERM || errno == EROFS ? SC_ACCESS_ERROR : SC_FAILED;
	snprintf(temp, sizeof(temp), ".%s.configd.%d.%llu", leaf, getpid(),
	    (unsigned long long)arc4random());
	int fd = openat(dirfd, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0) {
		close(dirfd);
		return errno == EACCES || errno == EPERM || errno == EROFS ? SC_ACCESS_ERROR : SC_FAILED;
	}
	mode_t mode = oldStat && oldStat->st_mode ? (oldStat->st_mode & 0777) : 0644;
	uid_t owner = oldStat && oldStat->st_mode ? oldStat->st_uid :
	    (directoryStat ? directoryStat->st_uid : 0);
	gid_t group = oldStat && oldStat->st_mode ? oldStat->st_gid :
	    (directoryStat ? directoryStat->st_gid : 0);
	bool ok = fchown(fd, owner, group) == 0 && fchmod(fd, mode) == 0 &&
	    writeAll(fd, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data)) && fsync(fd) == 0;
	int saved = errno;
	if (close(fd) < 0 && ok) {
		ok = false;
		saved = errno;
	}
	if (ok && renameat(dirfd, temp, dirfd, leaf) < 0) {
		ok = false;
		saved = errno;
	}
	if (ok && fsync(dirfd) < 0) {
		ok = false;
		saved = errno;
	}
	if (!ok)
		(void)unlinkat(dirfd, temp, 0);
	close(dirfd);
	if (ok)
		return SC_OK;
	return saved == EACCES || saved == EPERM || saved == EROFS ? SC_ACCESS_ERROR : SC_FAILED;
}

static int
prefsCommit(Peer *peer, uid_t uid, xpc_object_t request, xpc_object_t reply)
{
	char path[PATH_MAX];
	struct stat targetStat = {0}, directoryStat = {0};
	if (!pathForRequest(request, uid, true, path, &targetStat, &directoryStat))
		return uid != 0 ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
	PrefsLock *lock = findPrefsLock(peer, path);
	if (lock == NULL)
		return SC_NEED_LOCK;
	xpc_object_t expected = xpc_dictionary_get_value(request, "signature");
	xpc_object_t dataObject = xpc_dictionary_get_value(request, "plist");
	if (expected == NULL || xpc_get_type(expected) != XPC_TYPE_DATA ||
	    dataObject == NULL || xpc_get_type(dataObject) != XPC_TYPE_DATA)
		return SC_INVALID_ARGUMENT;
	size_t expectedLength = xpc_data_get_length(expected);
	CFDataRef current = signatureForPath(path);
	bool same = current && expectedLength == (size_t)CFDataGetLength(current) &&
	    memcmp(xpc_data_get_bytes_ptr(expected), CFDataGetBytePtr(current), expectedLength) == 0 &&
	    CFEqual(current, lock->signature);
	if (current)
		CFRelease(current);
	if (!same)
		return SC_STALE;
	CFPropertyListRef plist = propertyListFromXPC(request, "plist");
	if (plist == NULL || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
		if (plist) CFRelease(plist);
		return SC_INVALID_ARGUMENT;
	}
	CFRelease(plist);
	CFDataRef bytes = CFDataCreate(NULL, xpc_data_get_bytes_ptr(dataObject),
	    (CFIndex)xpc_data_get_length(dataObject));
	if (bytes == NULL)
		return SC_FAILED;
	int status = atomicWritePreferences(path, bytes, &targetStat, &directoryStat);
	CFRelease(bytes);
	if (status != SC_OK)
		return status;
	CFDataRef updated = signatureForPath(path);
	if (updated == NULL)
		return SC_FAILED;
	CFRelease(lock->signature);
	lock->signature = CFRetain(updated);
	xpc_dictionary_set_data(reply, "signature", CFDataGetBytePtr(updated),
	    (size_t)CFDataGetLength(updated));
	CFRelease(updated);
	return SC_OK;
}

static int
prefsUnlock(Peer *peer, uid_t uid, xpc_object_t request)
{
	char path[PATH_MAX];
	if (!pathForRequest(request, uid, true, path, NULL, NULL))
		return uid != 0 ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
	PrefsLock **p = &peer->locks;
	while (*p && strcmp((*p)->path, path) != 0)
		p = &(*p)->next;
	if (*p == NULL)
		return SC_NEED_LOCK;
	PrefsLock *lock = *p;
	*p = lock->next;
	(void)flock(lock->fd, LOCK_UN);
	close(lock->fd);
	CFRelease(lock->signature);
	free(lock);
	return SC_OK;
}

static CFTypeRef
dictionaryPath(CFDictionaryRef dictionary, const char *first, const char *second,
    const char *third, const char *fourth)
{
	const char *parts[] = {first, second, third, fourth, NULL};
	CFTypeRef value = dictionary;
	for (size_t i = 0; parts[i] && value; i++) {
		CFStringRef key = stringFromUTF8(parts[i]);
		value = CFGetTypeID(value) == CFDictionaryGetTypeID() ?
		    CFDictionaryGetValue((CFDictionaryRef)value, key) : NULL;
		CFRelease(key);
	}
	return value;
}

static bool
getCFString(CFDictionaryRef dictionary, const char *key, char *out, size_t size)
{
	CFStringRef k = stringFromUTF8(key);
	CFTypeRef value = CFDictionaryGetValue(dictionary, k);
	CFRelease(k);
	return stringFromCF(value, out, size);
}

static bool
trustedResolverDirectory(const char *path)
{
	/* /etc may be a real directory in Finch or resolve into /private/etc.
	 * macOS also points /etc/resolv.conf at /var/run/resolv.conf, whose
	 * canonical location is /private/var/run/resolv.conf. */
	return strcmp(path, "/etc") == 0 || strcmp(path, "/private/etc") == 0 ||
	    strcmp(path, "/private/var/run") == 0;
}

static int
openTrustedResolverDirectory(const char *path)
{
	if (path == NULL || path[0] != '/' || strlen(path) >= PATH_MAX)
		return -1;
	int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
	    (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
		close(fd);
		return -1;
	}

	char components[PATH_MAX];
	if (strlcpy(components, path + 1, sizeof(components)) >= sizeof(components)) {
		close(fd);
		return -1;
	}
	char *component = components;
	while (*component) {
		char *slash = strchr(component, '/');
		if (slash)
			*slash = '\0';
		if (*component == '\0' || strcmp(component, ".") == 0 ||
		    strcmp(component, "..") == 0) {
			close(fd);
			return -1;
		}
		int next = openat(fd, component,
		    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
		if (next < 0) {
			close(fd);
			return -1;
		}
		if (fstat(next, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
		    (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
			close(next);
			close(fd);
			return -1;
		}
		close(fd);
		fd = next;
		if (!slash)
			break;
		component = slash + 1;
	}
	return fd;
}

static bool
resolverPathForWrite(char path[PATH_MAX])
{
	if (realpath("/etc/resolv.conf", path) != NULL)
		return true;

	/* realpath needs the final file to exist. Resolve the link's parent when
	 * the resolver file is missing, so /etc/resolv.conf can still point at
	 * the usual /var/run/resolv.conf location. */
	char etc[PATH_MAX], source[PATH_MAX];
	if (realpath("/etc", etc) == NULL)
		return false;
	int n = snprintf(source, sizeof(source), "%s/resolv.conf", etc);
	if (n < 0 || (size_t)n >= sizeof(source))
		return false;
	struct stat st;
	if (lstat(source, &st) < 0) {
		if (errno != ENOENT || strlcpy(path, source, PATH_MAX) >= PATH_MAX)
			return false;
		return true;
	}
	if (!S_ISLNK(st.st_mode))
		return false;

	char target[PATH_MAX];
	ssize_t length = readlink(source, target, sizeof(target) - 1);
	if (length <= 0 || (size_t)length >= sizeof(target) - 1)
		return false;
	target[length] = '\0';
	char targetPath[PATH_MAX];
	if (target[0] == '/') {
		if (strlcpy(targetPath, target, sizeof(targetPath)) >= sizeof(targetPath))
			return false;
	} else {
		n = snprintf(targetPath, sizeof(targetPath), "%s/%s", etc, target);
		if (n < 0 || (size_t)n >= sizeof(targetPath))
			return false;
	}
	char *slash = strrchr(targetPath, '/');
	if (slash == NULL || slash[1] == '\0' || strcmp(slash + 1, ".") == 0 ||
	    strcmp(slash + 1, "..") == 0)
		return false;
	char leaf[NAME_MAX + 1];
	if (strlen(slash + 1) > NAME_MAX)
		return false;
	strlcpy(leaf, slash + 1, sizeof(leaf));
	if (strcmp(leaf, "resolv.conf") != 0)
		return false;
	if (slash == targetPath)
		slash[1] = '\0';
	else
		*slash = '\0';
	char directory[PATH_MAX];
	if (realpath(targetPath, directory) == NULL)
		return false;
	n = snprintf(path, PATH_MAX, "%s/%s", directory[0] == '/' &&
	    directory[1] == '\0' ? "" : directory, leaf);
	return n >= 0 && (size_t)n < PATH_MAX;
}

static bool
ipv4Address(CFTypeRef value, struct in_addr *address)
{
	char text[INET_ADDRSTRLEN];
	return stringFromCF(value, text, sizeof(text)) &&
		inet_pton(AF_INET, text, address) == 1;
}

static bool
ipv4Mask(CFTypeRef value, struct in_addr *mask)
{
	if (!ipv4Address(value, mask))
		return false;
	uint32_t bits = ntohl(mask->s_addr);
	bool sawZero = false;
	for (int bit = 31; bit >= 0; bit--) {
		bool set = (bits & (UINT32_C(1) << bit)) != 0;
		if (!set)
			sawZero = true;
		else if (sawZero)
			return false;
	}
	return true;
}

typedef struct {
	char interfaceName[IF_NAMESIZE + 1];
	bool hasIPv4;
	bool ipv4NeedsAdd;
	bool ipv4Added;
	struct in_addr address;
	struct in_addr mask;
	struct in_addr broadcast;
} NetworkServicePlan;

typedef struct {
	NetworkServicePlan *services;
	CFIndex serviceCount;
	CFMutableArrayRef nameservers;
	CFMutableArrayRef searchDomains;
	bool hasDNS;
	char resolverContents[8192];
	size_t resolverLength;
	int resolverDirectoryFD;
	char resolverLeaf[NAME_MAX + 1];
} NetworkApplyPlan;

static void
freeNetworkApplyPlan(NetworkApplyPlan *plan)
{
	if (plan == NULL)
		return;
	if (plan->resolverDirectoryFD >= 0)
		close(plan->resolverDirectoryFD);
	if (plan->nameservers)
		CFRelease(plan->nameservers);
	if (plan->searchDomains)
		CFRelease(plan->searchDomains);
	free(plan->services);
	memset(plan, 0, sizeof(*plan));
	plan->resolverDirectoryFD = -1;
}

static bool
validSearchDomain(CFTypeRef value, char output[256])
{
	if (!stringFromCF(value, output, 256))
		return false;
	size_t length = strlen(output);
	if (length == 0 || length != (size_t)CFStringGetLength((CFStringRef)value) ||
	    length > 254)
		return false;
	if (output[length - 1] == '.')
		length--;
	if (length == 0 || length > 253)
		return false;
	size_t labelStart = 0;
	for (size_t i = 0; i <= length; i++) {
		if (i == length || output[i] == '.') {
			size_t labelLength = i - labelStart;
			if (labelLength == 0 || labelLength > 63 ||
			    output[labelStart] == '-' || output[i - 1] == '-')
				return false;
			labelStart = i + 1;
			continue;
		}
		unsigned char c = (unsigned char)output[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == '-'))
			return false;
	}
	return true;
}

static bool
validDNSAddress(CFTypeRef value)
{
	char text[INET6_ADDRSTRLEN];
	struct in_addr address4;
	struct in6_addr address6;
	return stringFromCF(value, text, sizeof(text)) &&
	    (inet_pton(AF_INET, text, &address4) == 1 ||
	     inet_pton(AF_INET6, text, &address6) == 1);
}

static void
appendUniqueString(CFMutableArrayRef array, CFStringRef value)
{
	if (!CFArrayContainsValue(array, CFRangeMake(0, CFArrayGetCount(array)), value))
		CFArrayAppendValue(array, value);
}

static int
appendServiceDNS(CFDictionaryRef service, NetworkApplyPlan *plan)
{
	if (!CFDictionaryContainsKey(service, CFSTR("DNS")))
		return SC_OK;
	CFTypeRef value = CFDictionaryGetValue(service, CFSTR("DNS"));
	if (value == NULL || CFGetTypeID(value) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;
	CFDictionaryRef dns = (CFDictionaryRef)value;
	plan->hasDNS = true;
	CFTypeRef addresses = CFDictionaryGetValue(dns, CFSTR("ServerAddresses"));
	CFTypeRef domains = CFDictionaryGetValue(dns, CFSTR("SearchDomains"));
	if ((addresses && CFGetTypeID(addresses) != CFArrayGetTypeID()) ||
	    (domains && CFGetTypeID(domains) != CFArrayGetTypeID()))
		return SC_INVALID_ARGUMENT;
	CFArrayRef addressList = (CFArrayRef)addresses;
	CFArrayRef domainList = (CFArrayRef)domains;
	for (CFIndex i = 0; addressList && i < CFArrayGetCount(addressList); i++) {
		CFTypeRef address = CFArrayGetValueAtIndex(addressList, i);
		if (!validDNSAddress(address))
			return SC_INVALID_ARGUMENT;
		appendUniqueString(plan->nameservers, (CFStringRef)address);
	}
	for (CFIndex i = 0; domainList && i < CFArrayGetCount(domainList); i++) {
		char domain[256];
		CFTypeRef item = CFArrayGetValueAtIndex(domainList, i);
		if (!validSearchDomain(item, domain))
			return SC_INVALID_ARGUMENT;
		appendUniqueString(plan->searchDomains, (CFStringRef)item);
	}
	return SC_OK;
}

static int
validateServiceIPv4(CFDictionaryRef service, NetworkServicePlan *plan)
{
	CFTypeRef value = CFDictionaryGetValue(service, CFSTR("IPv4"));
	if (value == NULL)
		return SC_OK;
	if (CFGetTypeID(value) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;
	CFDictionaryRef ipv4 = (CFDictionaryRef)value;
	if (CFDictionaryContainsKey(ipv4, CFSTR("Router")))
		return SC_FAILED;
	CFTypeRef addressesValue = CFDictionaryGetValue(ipv4, CFSTR("Addresses"));
	CFTypeRef masksValue = CFDictionaryGetValue(ipv4, CFSTR("SubnetMasks"));
	if ((addressesValue && CFGetTypeID(addressesValue) != CFArrayGetTypeID()) ||
	    (masksValue && CFGetTypeID(masksValue) != CFArrayGetTypeID()))
		return SC_INVALID_ARGUMENT;
	CFArrayRef addresses = (CFArrayRef)addressesValue;
	CFArrayRef masks = (CFArrayRef)masksValue;
	if ((addresses && CFArrayGetCount(addresses) > 1) ||
	    (masks && CFArrayGetCount(masks) > 1))
		return SC_FAILED;
	char method[32] = "";
	if (!getCFString(ipv4, "ConfigMethod", method, sizeof(method)) || method[0] == '\0')
		return SC_INVALID_ARGUMENT;
	if (strcmp(method, "None") == 0)
		return SC_OK;
	if (strcmp(method, "DHCP") == 0)
		return SC_FAILED;
	if (strcmp(method, "Manual") != 0)
		return SC_FAILED;
	if (addresses == NULL || masks == NULL || CFArrayGetCount(addresses) != 1 ||
	    CFArrayGetCount(masks) != 1)
		return SC_INVALID_ARGUMENT;
	if (!ipv4Address(CFArrayGetValueAtIndex(addresses, 0), &plan->address) ||
	    !ipv4Mask(CFArrayGetValueAtIndex(masks, 0), &plan->mask))
		return SC_INVALID_ARGUMENT;
	plan->broadcast.s_addr = plan->address.s_addr | ~plan->mask.s_addr;
	plan->hasIPv4 = true;
	return SC_OK;
}

static int
validateServiceIPv6(CFDictionaryRef service)
{
	CFTypeRef value = CFDictionaryGetValue(service, CFSTR("IPv6"));
	if (value == NULL)
		return SC_OK;
	if (CFGetTypeID(value) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;
	char method[32] = "";
	if (!getCFString((CFDictionaryRef)value, "ConfigMethod", method, sizeof(method)) ||
	    method[0] == '\0')
		return SC_INVALID_ARGUMENT;
	return strcmp(method, "None") == 0 ? SC_OK : SC_FAILED;
}

static int
buildNetworkApplyPlan(CFDictionaryRef prefs, NetworkApplyPlan *plan)
{
	memset(plan, 0, sizeof(*plan));
	plan->resolverDirectoryFD = -1;
	plan->nameservers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	plan->searchDomains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (plan->nameservers == NULL || plan->searchDomains == NULL)
		return SC_FAILED;
	if (prefs == NULL || CFGetTypeID(prefs) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;

	bool hasCurrent = CFDictionaryContainsKey(prefs, CFSTR("CurrentSet"));
	bool hasSets = CFDictionaryContainsKey(prefs, CFSTR("Sets"));
	if (!hasCurrent && !hasSets)
		return SC_OK;
	if (!hasCurrent || !hasSets)
		return SC_INVALID_ARGUMENT;
	CFTypeRef currentValue = CFDictionaryGetValue(prefs, CFSTR("CurrentSet"));
	CFTypeRef setsValue = CFDictionaryGetValue(prefs, CFSTR("Sets"));
	if (currentValue == NULL || CFGetTypeID(currentValue) != CFStringGetTypeID() ||
	    setsValue == NULL || CFGetTypeID(setsValue) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;
	char currentPath[PATH_MAX];
	if (!stringFromCF((CFStringRef)currentValue, currentPath, sizeof(currentPath)) ||
	    strncmp(currentPath, "/Sets/", 6) != 0 || strchr(currentPath + 6, '/') != NULL ||
	    currentPath[6] == '\0' || strcmp(currentPath + 6, ".") == 0 ||
	    strcmp(currentPath + 6, "..") == 0)
		return SC_INVALID_ARGUMENT;
	CFStringRef setID = CFStringCreateWithCString(NULL, currentPath + 6,
	    kCFStringEncodingUTF8);
	CFTypeRef setValue = setID ? CFDictionaryGetValue((CFDictionaryRef)setsValue, setID) : NULL;
	if (setID)
		CFRelease(setID);
	if (setValue == NULL || CFGetTypeID(setValue) != CFDictionaryGetTypeID())
		return SC_INVALID_ARGUMENT;
	CFTypeRef network = CFDictionaryGetValue((CFDictionaryRef)setValue, CFSTR("Network"));
	CFTypeRef global = network && CFGetTypeID(network) == CFDictionaryGetTypeID() ?
	    CFDictionaryGetValue((CFDictionaryRef)network, CFSTR("Global")) : NULL;
	CFTypeRef globalIPv4 = global && CFGetTypeID(global) == CFDictionaryGetTypeID() ?
	    CFDictionaryGetValue((CFDictionaryRef)global, CFSTR("IPv4")) : NULL;
	CFTypeRef serviceOrderValue = globalIPv4 &&
	    CFGetTypeID(globalIPv4) == CFDictionaryGetTypeID() ?
	    CFDictionaryGetValue((CFDictionaryRef)globalIPv4, CFSTR("ServiceOrder")) : NULL;
	if (network == NULL || CFGetTypeID(network) != CFDictionaryGetTypeID() ||
	    global == NULL || CFGetTypeID(global) != CFDictionaryGetTypeID() ||
	    globalIPv4 == NULL || CFGetTypeID(globalIPv4) != CFDictionaryGetTypeID() ||
	    serviceOrderValue == NULL || CFGetTypeID(serviceOrderValue) != CFArrayGetTypeID())
		return SC_INVALID_ARGUMENT;
	CFArrayRef serviceOrder = (CFArrayRef)serviceOrderValue;
	CFIndex orderCount = CFArrayGetCount(serviceOrder);
	if ((uintmax_t)orderCount > SIZE_MAX / sizeof(*plan->services))
		return SC_INVALID_ARGUMENT;
	if (orderCount > 0) {
		plan->services = calloc((size_t)orderCount, sizeof(*plan->services));
		if (plan->services == NULL)
			return SC_FAILED;
	}
	CFTypeRef networkServicesValue = CFDictionaryGetValue(prefs, CFSTR("NetworkServices"));
	if ((networkServicesValue != NULL &&
	    CFGetTypeID(networkServicesValue) != CFDictionaryGetTypeID()) ||
	    (orderCount > 0 && networkServicesValue == NULL))
		return SC_INVALID_ARGUMENT;
	CFMutableArrayRef seen = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (seen == NULL)
		return SC_FAILED;
	int status = SC_OK;
	for (CFIndex i = 0; i < orderCount && status == SC_OK; i++) {
		CFTypeRef serviceID = CFArrayGetValueAtIndex(serviceOrder, i);
		char serviceName[256];
		if (!stringFromCF(serviceID, serviceName, sizeof(serviceName)) ||
		    serviceName[0] == '\0' || strchr(serviceName, '/') != NULL ||
		    CFArrayContainsValue(seen, CFRangeMake(0, CFArrayGetCount(seen)), serviceID)) {
			status = SC_INVALID_ARGUMENT;
			break;
		}
		CFArrayAppendValue(seen, serviceID);
		CFTypeRef serviceValue = CFDictionaryGetValue((CFDictionaryRef)networkServicesValue,
		    serviceID);
		if (serviceValue == NULL || CFGetTypeID(serviceValue) != CFDictionaryGetTypeID()) {
			status = SC_INVALID_ARGUMENT;
			break;
		}
		CFDictionaryRef service = (CFDictionaryRef)serviceValue;
		if (CFDictionaryContainsKey(service, CFSTR("__INACTIVE__")))
			continue;
		CFTypeRef interfaceValue = CFDictionaryGetValue(service, CFSTR("Interface"));
		char interfaceName[IF_NAMESIZE + 1];
		if (interfaceValue == NULL || CFGetTypeID(interfaceValue) != CFDictionaryGetTypeID() ||
		    !getCFString((CFDictionaryRef)interfaceValue, "DeviceName", interfaceName,
		        sizeof(interfaceName)) || interfaceName[0] == '\0' ||
		    strpbrk(interfaceName, "/ \t\r\n") != NULL || if_nametoindex(interfaceName) == 0) {
			status = SC_INVALID_ARGUMENT;
			break;
		}
		NetworkServicePlan *servicePlan = &plan->services[plan->serviceCount];
		strlcpy(servicePlan->interfaceName, interfaceName,
		    sizeof(servicePlan->interfaceName));
		status = validateServiceIPv4(service, servicePlan);
		if (status == SC_OK)
			status = validateServiceIPv6(service);
		if (status == SC_OK)
			status = appendServiceDNS(service, plan);
		if (status == SC_OK)
			plan->serviceCount++;
	}
	CFRelease(seen);
	return status;
}

static int
formatResolverContents(NetworkApplyPlan *plan)
{
	plan->resolverLength = 0;
	for (CFIndex i = 0; i < CFArrayGetCount(plan->nameservers); i++) {
		char address[INET6_ADDRSTRLEN];
		if (!stringFromCF(CFArrayGetValueAtIndex(plan->nameservers, i), address,
		    sizeof(address)))
			return SC_INVALID_ARGUMENT;
		int n = snprintf(plan->resolverContents + plan->resolverLength,
		    sizeof(plan->resolverContents) - plan->resolverLength,
		    "nameserver %s\n", address);
		if (n < 0 || (size_t)n >= sizeof(plan->resolverContents) - plan->resolverLength)
			return SC_INVALID_ARGUMENT;
		plan->resolverLength += (size_t)n;
	}
	if (CFArrayGetCount(plan->searchDomains) > 0) {
		int n = snprintf(plan->resolverContents + plan->resolverLength,
		    sizeof(plan->resolverContents) - plan->resolverLength, "search");
		if (n < 0 || (size_t)n >= sizeof(plan->resolverContents) - plan->resolverLength)
			return SC_INVALID_ARGUMENT;
		plan->resolverLength += (size_t)n;
		for (CFIndex i = 0; i < CFArrayGetCount(plan->searchDomains); i++) {
			char domain[256];
			if (!stringFromCF(CFArrayGetValueAtIndex(plan->searchDomains, i), domain,
			    sizeof(domain)))
				return SC_INVALID_ARGUMENT;
			n = snprintf(plan->resolverContents + plan->resolverLength,
			    sizeof(plan->resolverContents) - plan->resolverLength, " %s", domain);
			if (n < 0 || (size_t)n >= sizeof(plan->resolverContents) - plan->resolverLength)
				return SC_INVALID_ARGUMENT;
			plan->resolverLength += (size_t)n;
		}
		if (plan->resolverLength + 1 >= sizeof(plan->resolverContents))
			return SC_INVALID_ARGUMENT;
		plan->resolverContents[plan->resolverLength++] = '\n';
	}
	return SC_OK;
}

static int
prepareResolverTarget(NetworkApplyPlan *plan)
{
	if (!plan->hasDNS)
		return SC_OK;
	char resolved[PATH_MAX];
	if (!resolverPathForWrite(resolved))
		return SC_FAILED;
	char directory[PATH_MAX];
	if (strlcpy(directory, resolved, sizeof(directory)) >= sizeof(directory))
		return SC_FAILED;
	char *slash = strrchr(directory, '/');
	if (slash == NULL || slash == directory)
		return SC_ACCESS_ERROR;
	if (strcmp(slash + 1, "resolv.conf") != 0 || strlen(slash + 1) > NAME_MAX)
		return SC_ACCESS_ERROR;
	strlcpy(plan->resolverLeaf, slash + 1, sizeof(plan->resolverLeaf));
	*slash = '\0';
	if (!trustedResolverDirectory(directory))
		return SC_ACCESS_ERROR;
	int dirfd = openTrustedResolverDirectory(directory);
	if (dirfd < 0)
		return SC_ACCESS_ERROR;
	struct stat target;
	if (fstatat(dirfd, plan->resolverLeaf, &target, AT_SYMLINK_NOFOLLOW) == 0) {
		if (!S_ISREG(target.st_mode) || target.st_uid != 0 || target.st_nlink != 1 ||
		    (target.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
			close(dirfd);
			return SC_ACCESS_ERROR;
		}
	} else if (errno != ENOENT) {
		close(dirfd);
		return SC_ACCESS_ERROR;
	}
	plan->resolverDirectoryFD = dirfd;
	return SC_OK;
}

static int
networkStatusForErrno(int error)
{
	return error == EACCES || error == EPERM ? SC_ACCESS_ERROR : SC_FAILED;
}

static bool
sameIPv4Request(const NetworkServicePlan *left, const NetworkServicePlan *right)
{
	return strcmp(left->interfaceName, right->interfaceName) == 0 &&
	    left->address.s_addr == right->address.s_addr &&
	    left->mask.s_addr == right->mask.s_addr &&
	    left->broadcast.s_addr == right->broadcast.s_addr;
}

static bool
ipv4EntryMatches(const struct ifaddrs *entry, const NetworkServicePlan *plan)
{
	if (entry->ifa_netmask == NULL || entry->ifa_netmask->sa_family != AF_INET ||
	    ((const struct sockaddr_in *)entry->ifa_netmask)->sin_addr.s_addr !=
	        plan->mask.s_addr)
		return false;
	if ((entry->ifa_flags & IFF_BROADCAST) != 0) {
		if (entry->ifa_broadaddr == NULL ||
		    entry->ifa_broadaddr->sa_family != AF_INET ||
		    ((const struct sockaddr_in *)entry->ifa_broadaddr)->sin_addr.s_addr !=
		        plan->broadcast.s_addr)
			return false;
	}
	if ((entry->ifa_flags & IFF_POINTOPOINT) != 0) {
		if (entry->ifa_dstaddr == NULL || entry->ifa_dstaddr->sa_family != AF_INET ||
		    ((const struct sockaddr_in *)entry->ifa_dstaddr)->sin_addr.s_addr !=
		        plan->broadcast.s_addr)
			return false;
	}
	return true;
}

static int
findIPv4Tuple(const NetworkServicePlan *plan, bool *present, bool *matches)
{
	struct ifaddrs *all = NULL;
	*present = false;
	*matches = false;
	if (getifaddrs(&all) < 0)
		return networkStatusForErrno(errno);
	int status = SC_OK;
	for (struct ifaddrs *entry = all; entry != NULL; entry = entry->ifa_next) {
		if (entry->ifa_name == NULL || strcmp(entry->ifa_name, plan->interfaceName) != 0 ||
		    entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET ||
		    ((const struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr !=
		        plan->address.s_addr)
			continue;
		if (*present) {
			status = SC_FAILED;
			break;
		}
		*present = true;
		*matches = ipv4EntryMatches(entry, plan);
	}
	freeifaddrs(all);
	return status;
}

static int
snapshotIPv4Aliases(NetworkApplyPlan *plan)
{
	for (CFIndex i = 0; i < plan->serviceCount; i++) {
		NetworkServicePlan *service = &plan->services[i];
		service->ipv4NeedsAdd = false;
		service->ipv4Added = false;
		if (!service->hasIPv4)
			continue;
		bool coveredByEarlierService = false;
		for (CFIndex j = 0; j < i; j++) {
			NetworkServicePlan *earlier = &plan->services[j];
			if (!earlier->hasIPv4 ||
			    strcmp(earlier->interfaceName, service->interfaceName) != 0 ||
			    earlier->address.s_addr != service->address.s_addr)
				continue;
			if (!sameIPv4Request(earlier, service))
				return SC_FAILED;
			coveredByEarlierService = true;
			break;
		}
		if (coveredByEarlierService)
			continue;
		bool present, matches;
		int status = findIPv4Tuple(service, &present, &matches);
		if (status != SC_OK)
			return status;
		if (present && !matches)
			return SC_FAILED;
		service->ipv4NeedsAdd = !present;
	}
	return SC_OK;
}

static int
applyIPv4(NetworkServicePlan *plan)
{
	if (!plan->hasIPv4 || !plan->ipv4NeedsAdd)
		return SC_OK;
	bool present, matches;
	int lookupStatus = findIPv4Tuple(plan, &present, &matches);
	if (lookupStatus != SC_OK)
		return lookupStatus;
	if (present) {
		if (!matches)
			return SC_FAILED;
		plan->ipv4NeedsAdd = false;
		return SC_OK;
	}
	const char *interfaceName = plan->interfaceName;
	if (if_nametoindex(interfaceName) == 0)
		return SC_FAILED;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return SC_FAILED;
	struct ifaliasreq request;
	memset(&request, 0, sizeof(request));
	strlcpy(request.ifra_name, interfaceName, sizeof(request.ifra_name));
	struct sockaddr_in *sin = (struct sockaddr_in *)&request.ifra_addr;
	sin->sin_len = sizeof(*sin);
	sin->sin_family = AF_INET;
	sin->sin_addr = plan->address;
	sin = (struct sockaddr_in *)&request.ifra_mask;
	sin->sin_len = sizeof(*sin);
	sin->sin_family = AF_INET;
	sin->sin_addr = plan->mask;
	sin = (struct sockaddr_in *)&request.ifra_broadaddr;
	sin->sin_len = sizeof(*sin);
	sin->sin_family = AF_INET;
	sin->sin_addr.s_addr = plan->address.s_addr | ~plan->mask.s_addr;
	int result = ioctl(fd, SIOCAIFADDR, &request);
	int saved = errno;
	close(fd);
	if (result != 0)
		return networkStatusForErrno(saved);
	plan->ipv4Added = true;
	return SC_OK;
}

static int
rollbackAddedIPv4(NetworkApplyPlan *plan)
{
	int fd = -1;
	int status = SC_OK;
	for (CFIndex i = plan->serviceCount; i > 0; i--) {
		NetworkServicePlan *service = &plan->services[i - 1];
		if (!service->ipv4Added)
			continue;
		bool present, matches;
		int lookupStatus = findIPv4Tuple(service, &present, &matches);
		if (lookupStatus != SC_OK) {
			status = lookupStatus;
			continue;
		}
		if (!present) {
			service->ipv4Added = false;
			continue;
		}
		if (!matches) {
			status = SC_FAILED;
			continue;
		}
		if (fd < 0) {
			fd = socket(AF_INET, SOCK_DGRAM, 0);
			if (fd < 0) {
				status = networkStatusForErrno(errno);
				continue;
			}
		}
		struct ifreq request;
		memset(&request, 0, sizeof(request));
		strlcpy(request.ifr_name, service->interfaceName, sizeof(request.ifr_name));
		struct sockaddr_in *sin = (struct sockaddr_in *)&request.ifr_addr;
		sin->sin_len = sizeof(*sin);
		sin->sin_family = AF_INET;
		sin->sin_addr = service->address;
		int result = ioctl(fd, SIOCDIFADDR, &request);
		int saved = errno;
		if (result < 0 && saved != EADDRNOTAVAIL && saved != ENXIO) {
			status = networkStatusForErrno(saved);
			continue;
		}
		lookupStatus = findIPv4Tuple(service, &present, &matches);
		if (lookupStatus != SC_OK) {
			status = lookupStatus;
		} else if (present) {
			status = SC_FAILED;
		} else {
			service->ipv4Added = false;
		}
	}
	if (fd >= 0)
		close(fd);
	return status;
}

static int
writeResolverConfig(NetworkApplyPlan *plan)
{
	if (!plan->hasDNS)
		return SC_OK;
	if (plan->resolverDirectoryFD < 0 || plan->resolverLeaf[0] == '\0')
		return SC_FAILED;
	char temp[NAME_MAX + 1];
	snprintf(temp, sizeof(temp), ".%s.configd.%d.%llu", plan->resolverLeaf, getpid(),
	    (unsigned long long)arc4random());
	int fd = openat(plan->resolverDirectoryFD, temp,
	    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
	if (fd < 0) {
		return errno == EACCES || errno == EPERM || errno == EROFS ? SC_ACCESS_ERROR : SC_FAILED;
	}
	bool ok = fchmod(fd, 0644) == 0 &&
	    writeAll(fd, (const UInt8 *)plan->resolverContents, plan->resolverLength) &&
	    fsync(fd) == 0;
	int saved = errno;
	if (close(fd) < 0 && ok) {
		ok = false;
		saved = errno;
	}
	if (ok && renameat(plan->resolverDirectoryFD, temp, plan->resolverDirectoryFD,
	    plan->resolverLeaf) < 0) {
		ok = false;
		saved = errno;
	}
	if (ok && fsync(plan->resolverDirectoryFD) < 0) {
		ok = false;
		saved = errno;
	}
	if (!ok)
		(void)unlinkat(plan->resolverDirectoryFD, temp, 0);
	return ok ? SC_OK : (saved == EACCES || saved == EPERM || saved == EROFS ?
	    SC_ACCESS_ERROR : SC_FAILED);
}

static int
applyNetworkServices(NetworkApplyPlan *plan)
{
	for (CFIndex i = 0; i < plan->serviceCount; i++) {
		int status = applyIPv4(&plan->services[i]);
		if (status != SC_OK)
			return status;
	}
	return writeResolverConfig(plan);
}

/* Rollback is best effort when other actors can change addresses at the same time.
 * If hostname setup fails after DNS was written, DNS contents are not restored. */
static int
applyPreparedNetworkPlan(NetworkApplyPlan *plan, bool hasHostname, const char *hostname)
{
	int status = applyNetworkServices(plan);
	if (status == SC_OK && hasHostname && sethostname(hostname, strlen(hostname)) < 0)
		status = networkStatusForErrno(errno);
	if (status != SC_OK) {
		int rollbackStatus = rollbackAddedIPv4(plan);
		if (rollbackStatus != SC_OK) {
			fprintf(stderr, "configd: IPv4 address rollback did not finish cleanly\n");
			status = rollbackStatus;
		}
	}
	return status;
}

static int
validateHostname(CFTypeRef value, char hostname[256], bool *hasHostname)
{
	*hasHostname = value != NULL;
	if (value == NULL)
		return SC_OK;
	if (CFGetTypeID(value) != CFStringGetTypeID() ||
	    !stringFromCF((CFStringRef)value, hostname, 256) || hostname[0] == '\0' ||
	    strpbrk(hostname, " /\\\t\r\n") != NULL)
		return SC_INVALID_ARGUMENT;
	return SC_OK;
}

static int
applyPreferences(uid_t uid, CFDictionaryRef prefs)
{
	if (uid != 0)
		return SC_ACCESS_ERROR;
	CFTypeRef localHost = dictionaryPath(prefs, "System", "Network", "HostNames",
	    "LocalHostName");
	char hostname[256];
	bool hasHostname;
	int status = validateHostname(localHost, hostname, &hasHostname);
	if (status != SC_OK)
		return status;

	NetworkApplyPlan plan;
	status = buildNetworkApplyPlan(prefs, &plan);
	if (status == SC_OK)
		status = formatResolverContents(&plan);
	if (status == SC_OK)
		status = prepareResolverTarget(&plan);
	if (status == SC_OK)
		status = snapshotIPv4Aliases(&plan);
	if (status == SC_OK)
		status = applyPreparedNetworkPlan(&plan, hasHostname, hostname);
	freeNetworkApplyPlan(&plan);
	return status;
}

static int
prefsApply(Peer *peer, uid_t uid, xpc_object_t request, xpc_object_t reply)
{
	char path[PATH_MAX];
	if (!pathForRequest(request, uid, false, path, NULL, NULL))
		return SC_INVALID_ARGUMENT;
	if (uid != 0)
		return SC_ACCESS_ERROR;
	int status = SC_OK;
	CFDataRef signature = NULL;
	CFDictionaryRef prefs = readPreferenceDictionary(path, &signature, &status);
	if (signature) CFRelease(signature);
	if (status == SC_OK && prefs)
		status = applyPreferences(uid, prefs);
	if (prefs)
		CFRelease(prefs);
	if (status == SC_OK) {
		/* Notify preference observers after the real apply operation succeeds. */
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFArrayAppendValue(changed, CFSTR("Setup:/"));
		CFArrayAppendValue(changed, CFSTR("State:/Network/Global/DNS"));
		CFArrayAppendValue(changed, CFSTR("State:/Network/Global/Proxies"));
		notifyPeers(changed);
		CFRelease(changed);
	}
	(void)peer;
	(void)reply;
	return status;
}

static int
handleRequest(Peer *peer, xpc_object_t request, xpc_object_t reply)
{
	const char *op = xpc_dictionary_get_string(request, "op");
	if (op == NULL)
		return SC_INVALID_ARGUMENT;
	audit_token_t token = {0};
	xpc_dictionary_get_audit_token(request, &token);
	if (token.val[5] == 0 || token.val[5] > INT_MAX)
		return SC_ACCESS_ERROR;
	uid_t uid = (uid_t)token.val[1];
	pid_t pid = (pid_t)token.val[5];
	pthread_mutex_lock(&stateLock);
	peer->uid = uid;
	peer->pid = pid;
	pthread_mutex_unlock(&stateLock);

	if (strcmp(op, "ping") == 0)
		return SC_OK;
	if (strcmp(op, "store.copy") == 0)
		return dynamicCopyAll(peer, uid, reply);
	if (strcmp(op, "store.subscribe") == 0)
		return dynamicSubscribe(peer, request);
	if (strcmp(op, "store.set") == 0 || strcmp(op, "store.add") == 0 ||
	    strcmp(op, "store.temporary") == 0) {
		CFPropertyListRef key = propertyListFromXPC(request, "key");
		CFPropertyListRef value = propertyListFromXPC(request, "value");
		int status = dynamicSetValue(peer, uid, (CFStringRef)key, value,
		    strcmp(op, "store.add") == 0 || strcmp(op, "store.temporary") == 0,
		    strcmp(op, "store.temporary") == 0);
		if (key) CFRelease(key);
		if (value) CFRelease(value);
		return status;
	}
	if (strcmp(op, "store.remove") == 0) {
		CFPropertyListRef key = propertyListFromXPC(request, "key");
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		int status = dynamicRemoveValue(uid, (CFStringRef)key, changed);
		if (status == SC_OK)
			notifyPeers(changed);
		if (key) CFRelease(key);
		CFRelease(changed);
		return status;
	}
	if (strcmp(op, "store.set-multiple") == 0)
		return dynamicSetMultiple(peer, uid, request);
	if (strcmp(op, "store.notify") == 0) {
		CFPropertyListRef key = propertyListFromXPC(request, "key");
		if (key == NULL || CFGetTypeID(key) != CFStringGetTypeID() ||
		    !authorizeDynamicKey(uid, (CFStringRef)key)) {
			if (key) CFRelease(key);
			return uid != 0 ? SC_ACCESS_ERROR : SC_INVALID_ARGUMENT;
		}
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFArrayAppendValue(changed, key);
		notifyPeers(changed);
		CFRelease(changed);
		CFRelease(key);
		return SC_OK;
	}
	if (strcmp(op, "prefs.read") == 0)
		return prefsRead(peer, uid, request, reply);
	if (strcmp(op, "prefs.lock") == 0)
		return prefsLock(peer, uid, request);
	if (strcmp(op, "prefs.commit") == 0)
		return prefsCommit(peer, uid, request, reply);
	if (strcmp(op, "prefs.unlock") == 0)
		return prefsUnlock(peer, uid, request);
	if (strcmp(op, "prefs.apply") == 0)
		return prefsApply(peer, uid, request, reply);
	return SC_INVALID_ARGUMENT;
}

static void
peerEventHandler(xpc_object_t peerConnection, xpc_object_t event)
{
	if (xpc_get_type(event) == XPC_TYPE_ERROR)
		return;
	if (xpc_get_type(event) != XPC_TYPE_DICTIONARY)
		return;
	Peer *peer = xpc_connection_get_context(peerConnection);
	if (peer == NULL)
		return;
	xpc_object_t reply = xpc_dictionary_create_reply(event);
	if (reply == NULL)
		return;
	int status = handleRequest(peer, event, reply);
	xpc_dictionary_set_int64(reply, "status", status);
	xpc_dictionary_set_bool(reply, "ok", status == SC_OK);
	xpc_connection_send_message(peerConnection, reply);
	xpc_release(reply);
}

static void
listenerEventHandler(xpc_object_t event)
{
	if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
		return;
	Peer *peer = calloc(1, sizeof(*peer));
	if (peer == NULL)
		return;
	peer->connection = (xpc_connection_t)event;
	peer->uid = xpc_connection_get_euid(peer->connection);
	peer->pid = xpc_connection_get_pid(peer->connection);
	pthread_mutex_lock(&stateLock);
	peer->identifier = nextPeerIdentifier++;
	peer->next = peers;
	peers = peer;
	pthread_mutex_unlock(&stateLock);
	xpc_connection_set_context(peer->connection, peer);
	xpc_connection_set_finalizer_f(peer->connection, peerFinalizer);
	xpc_connection_set_event_handler(peer->connection, ^(xpc_object_t message) {
		peerEventHandler(peer->connection, message);
	});
	xpc_connection_resume(peer->connection);
}

#ifndef CONFIGD_NO_MAIN
int
main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	xpc_connection_t listener = xpc_connection_create_mach_service(CONFIGD_SERVICE, NULL,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);
	if (listener == NULL) {
		fprintf(stderr, "configd: could not check in with Finch's service manager\n");
		return 1;
	}
	xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
		listenerEventHandler(event);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}
#endif

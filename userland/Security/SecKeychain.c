/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's keychain: SecItem and SecKeychain calls over an encrypted file store.
 *
 * A keychain stores an authenticated-encrypted binary property list. In a
 * Finch guest, the per-user security service owns unlocked keys and item
 * operations; outside Finch, tests use the same file store directly. The file
 * is readable only by its owner (0600 in a 0700 directory), and holds each
 * item's attributes (under Apple's keys: acct, svce, labl, ...) and secret
 * (v_Data). The default keychain is ~/Library/Keychains/login.keychain-finch.
 * Calls use stable directory locks so processes see each other's changes.
 * Items follow macOS's matching and duplicate rules.
 */
#include "SecInternal.h"
#include "SecKeychainCrypto.h"
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
#include "SecKeychainServiceClient.h"
#include "SecKeychainServiceWire.h"
#endif
#include <Security/SecKeychainSearch.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <openssl/crypto.h>
#include <pthread.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static bool isType(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}

/* ---- Keychain and item objects ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef path;
} Keychain;

typedef struct {
	CFRuntimeBase base;
	SecKeychainRef keychain;
	CFStringRef itemClass;
	int64_t id;
} Item;

static void keychainFree(CFTypeRef o)
{
	CFRelease(((Keychain *)o)->path);
}
static Boolean keychainEqual(CFTypeRef a, CFTypeRef b)
{
	return CFEqual(((Keychain *)a)->path, ((Keychain *)b)->path);
}
static CFHashCode keychainHash(CFTypeRef a)
{
	return CFHash(((Keychain *)a)->path);
}
static CFStringRef keychainDescription(CFTypeRef o)
{
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SecKeychain %p: %@>"), o, ((Keychain *)o)->path);
}
CFTypeID SecKeychainGetTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "SecKeychain", NULL, NULL, keychainFree, keychainEqual,
	    keychainHash, NULL, keychainDescription};
	return _SecRegisterClass(&id, &cls);
}
static void itemFree(CFTypeRef o)
{
	CFRelease(((Item *)o)->keychain);
	CFRelease(((Item *)o)->itemClass);
}
static Boolean itemEqual(CFTypeRef a, CFTypeRef b)
{
	return ((Item *)a)->id == ((Item *)b)->id && CFEqual(((Item *)a)->keychain, ((Item *)b)->keychain);
}
static CFHashCode itemHash(CFTypeRef a)
{
	return (CFHashCode)((Item *)a)->id;
}
SEC_DEFINE_TYPE(SecKeychainItemGetTypeID, "SecKeychainItem", itemFree, itemEqual, itemHash)

static CFStringRef homeDirectory(void)
{
#ifdef FINCH_KEYCHAIN_SERVICE_BACKEND
	/* The service account, not a caller's environment, owns the default store. */
	struct passwd *pw = getpwuid(geteuid());
	const char *home = pw ? pw->pw_dir : NULL;
	if (!home || home[0] != '/')
		return NULL;
#else
	const char *home = getenv("HOME");
	if (!home || !*home) {
		struct passwd *pw = getpwuid(getuid());
		home = pw ? pw->pw_dir : "/var/root";
	}
#endif
	return CFStringCreateWithCString(NULL, home, kCFStringEncodingUTF8);
}

/* Relative keychain paths are relative to ~/Library/Keychains, as Apple's. */
static CFStringRef absolutePath(const char *path)
{
	if (!path || !*path)
		return NULL;
	/* (bytes that aren't UTF-8 name no keychain) */
	CFStringRef check = CFStringCreateWithBytes(NULL, (const UInt8 *)path, (CFIndex)strlen(path), kCFStringEncodingUTF8, false);
	if (!check)
		return NULL;
	CFRelease(check);
	if (path[0] == '/')
		return CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
	CFStringRef home = homeDirectory();
	if (!home)
		return NULL;
	CFStringRef p = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/Library/Keychains/%s"), home, path);
	CFRelease(home);
	return p;
}

static SecKeychainRef keychainCreate(CFStringRef path)
{
	if (!path)
		return NULL;
	Keychain *k = (Keychain *)_SecCreateInstance(SecKeychainGetTypeID(), sizeof(*k));
	if (!k)
		return NULL;
	k->path = CFRetain(path);
	return (SecKeychainRef)k;
}

SEC_HIDDEN SecKeychainRef
_FinchKeychainCreateLocalReference(CFStringRef path)
{
	return keychainCreate(path);
}

static CFMutableDictionaryRef newServiceRequest(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
}

#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
static bool keychainServiceActive(void)
{
	return _FinchKeychainServiceRequired();
}

static OSStatus keychainServiceCall(CFStringRef operation, CFTypeRef request,
	CFTypeRef *response)
{
	if (response)
		*response = NULL;
	CFPropertyListRef wireRequest = request ? _FinchKeychainWireEncode(request) : NULL;
	if (request && !wireRequest)
		return errSecUnimplemented;
	CFPropertyListRef wireResponse = NULL;
	OSStatus status = _FinchKeychainServiceCall(operation, wireRequest, response ? &wireResponse : NULL);
	if (wireRequest)
		CFRelease(wireRequest);
	if (!status && response) {
		CFTypeRef value = _FinchKeychainWireDecode(wireResponse, true);
		if (!value)
			status = errSecInternalComponent;
		else
			*response = value;
	}
	if (wireResponse)
		CFRelease(wireResponse);
	return status;
}

static OSStatus serviceItemCall(CFStringRef operation, CFDictionaryRef query,
	CFDictionaryRef attributes, CFTypeRef *result)
{
	CFMutableDictionaryRef request = newServiceRequest();
	if (!request)
		return errSecAllocate;
	if (query)
		CFDictionarySetValue(request, CFSTR("query"), query);
	if (attributes)
		CFDictionarySetValue(request, CFSTR("attributes"), attributes);
	if (result)
		CFDictionarySetValue(request, CFSTR("returnResult"), kCFBooleanTrue);
	CFTypeRef response = NULL;
	OSStatus status = keychainServiceCall(operation, request, result ? &response : NULL);
	CFRelease(request);
	if (!status && result)
		*result = response;
	else if (response)
		CFRelease(response);
	return status;
}
#else
static bool keychainServiceActive(void)
{
	return false;
}
#endif

static SecKeychainRef defaultKeychain(void)
{
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		CFPropertyListRef path = NULL;
		OSStatus status = _FinchKeychainServiceCall(CFSTR("keychain.default-path"), NULL, &path);
		if (status || !isType(path, CFStringGetTypeID())) {
			if (path)
				CFRelease(path);
			return NULL;
		}
		SecKeychainRef keychain = keychainCreate((CFStringRef)path);
		CFRelease(path);
		return keychain;
	}
#endif
	CFStringRef home = homeDirectory();
	if (!home)
		return NULL;
	CFStringRef p = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/Library/Keychains/login.keychain-finch"), home);
	SecKeychainRef k = keychainCreate(p);
	CFRelease(p);
	CFRelease(home);
	return k;
}

static bool pathOf(SecKeychainRef kc, char *buf, size_t size)
{
	return CFStringGetFileSystemRepresentation(((Keychain *)kc)->path, buf, size);
}

/* ---- The file ---- */

typedef struct {
	int fd;
	int lockFD;
	int parentFD;
	char path[PATH_MAX];
	char cachePath[PATH_MAX];
	char leaf[NAME_MAX + 1];
	CFMutableDictionaryRef db;
	CFMutableArrayRef items;
	bool dirty;
	bool created;
	bool hasKey;
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
} Store;

typedef struct KeyEntry {
	char path[PATH_MAX];
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	bool valid;
	struct KeyEntry *next;
} KeyEntry;

static KeyEntry *keyEntries;
static pthread_mutex_t keyEntriesLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t keyEntriesOnce = PTHREAD_ONCE_INIT;
static pid_t keyEntriesPID;

static void keyEntriesForkPrepare(void)
{
	pthread_mutex_lock(&keyEntriesLock);
}

static void keyEntriesForkParent(void)
{
	pthread_mutex_unlock(&keyEntriesLock);
}

static void keyEntriesForkChild(void)
{
	for (KeyEntry *entry = keyEntries; entry; entry = entry->next) {
		OPENSSL_cleanse(entry->salt, sizeof(entry->salt));
		OPENSSL_cleanse(entry->key, sizeof(entry->key));
		entry->valid = false;
	}
	keyEntriesPID = getpid();
	pthread_mutex_unlock(&keyEntriesLock);
}

static void keyEntriesInitialize(void)
{
	keyEntriesPID = getpid();
	(void)pthread_atfork(keyEntriesForkPrepare, keyEntriesForkParent, keyEntriesForkChild);
}

static void keyEntriesClearAfterFork(void)
{
	if (keyEntriesPID == getpid())
		return;
	for (KeyEntry *entry = keyEntries; entry; entry = entry->next) {
		OPENSSL_cleanse(entry->salt, sizeof(entry->salt));
		OPENSSL_cleanse(entry->key, sizeof(entry->key));
		entry->valid = false;
	}
	keyEntriesPID = getpid();
}

static bool keychainPath(SecKeychainRef kc, char path[PATH_MAX])
{
	return isType(kc, SecKeychainGetTypeID()) && pathOf(kc, path, PATH_MAX);
}

static bool keyCacheCopy(const char *cachePath,
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES])
{
	if (!cachePath || !*cachePath)
		return false;
	pthread_once(&keyEntriesOnce, keyEntriesInitialize);
	pthread_mutex_lock(&keyEntriesLock);
	keyEntriesClearAfterFork();
	bool found = false;
	for (KeyEntry *entry = keyEntries; entry; entry = entry->next)
		if (entry->valid && !strcmp(entry->path, cachePath)) {
			memcpy(salt, entry->salt, sizeof(entry->salt));
			memcpy(key, entry->key, sizeof(entry->key));
			found = true;
			break;
		}
	pthread_mutex_unlock(&keyEntriesLock);
	return found;
}

static bool keyCacheMatchesSalt(const char *cachePath,
	const uint8_t expectedSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES])
{
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	bool found = keyCacheCopy(cachePath, salt, key);
	if (found)
		found = CRYPTO_memcmp(salt, expectedSalt, sizeof(salt)) == 0;
	OPENSSL_cleanse(salt, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	return found;
}

static OSStatus keyCacheSet(const char *cachePath,
	const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES])
{
	if (!cachePath || !*cachePath || strlen(cachePath) >= PATH_MAX)
		return errSecInvalidKeychain;
	pthread_once(&keyEntriesOnce, keyEntriesInitialize);
	KeyEntry *fresh = calloc(1, sizeof(*fresh));
	if (!fresh)
		return errSecAllocate;
	strlcpy(fresh->path, cachePath, sizeof(fresh->path));
	memcpy(fresh->salt, salt, sizeof(fresh->salt));
	memcpy(fresh->key, key, sizeof(fresh->key));
	fresh->valid = true;
	pthread_mutex_lock(&keyEntriesLock);
	keyEntriesClearAfterFork();
	for (KeyEntry *entry = keyEntries; entry; entry = entry->next)
		if (!strcmp(entry->path, cachePath)) {
			memcpy(entry->salt, salt, sizeof(entry->salt));
			memcpy(entry->key, key, sizeof(entry->key));
			entry->valid = true;
			pthread_mutex_unlock(&keyEntriesLock);
			OPENSSL_cleanse(fresh, sizeof(*fresh));
			free(fresh);
			return 0;
		}
	fresh->next = keyEntries;
	keyEntries = fresh;
	pthread_mutex_unlock(&keyEntriesLock);
	return 0;
}

static void keyCacheClearPath(const char *cachePath)
{
	pthread_once(&keyEntriesOnce, keyEntriesInitialize);
	pthread_mutex_lock(&keyEntriesLock);
	keyEntriesClearAfterFork();
	for (KeyEntry *entry = keyEntries; entry; entry = entry->next)
		if (!cachePath || !strcmp(entry->path, cachePath)) {
			OPENSSL_cleanse(entry->salt, sizeof(entry->salt));
			OPENSSL_cleanse(entry->key, sizeof(entry->key));
			entry->valid = false;
		}
	pthread_mutex_unlock(&keyEntriesLock);
}

/* The file contains secrets, so never trust a keychain path just because
 * open(2) succeeded. Resolve only the known macOS /tmp and /var aliases,
 * then walk the path without following any other links. */
static OSStatus pathError(int error)
{
	if (error == ENOENT)
		return errSecNoSuchKeychain;
	if (error == EACCES || error == EPERM)
		return errSecNoAccessForItem;
	if (error == ELOOP || error == ENOTDIR)
		return errSecInvalidKeychain;
	return errSecIO;
}

static bool trustedTempDirectory(const char *path)
{
	return !strcmp(path, "/tmp") || !strcmp(path, "/var/tmp") ||
	    !strcmp(path, "/private/tmp") || !strcmp(path, "/private/var/tmp");
}

/* Only these two aliases are followed. Any other symlink in a supplied
 * parent path is rejected by the no-follow directory walk below. */
static OSStatus resolveAllowedAlias(const char *path, char out[PATH_MAX])
{
	const char *alias = NULL;
	const char *allowedA = NULL, *allowedB = NULL;
	if (!strncmp(path, "/tmp", 4) && (path[4] == 0 || path[4] == '/')) {
		alias = "/tmp";
		allowedA = "/tmp";
		allowedB = "/private/tmp";
	} else if (!strncmp(path, "/var", 4) && (path[4] == 0 || path[4] == '/')) {
		alias = "/var";
		allowedA = "/var";
		allowedB = "/private/var";
	}
	if (!alias)
		return strlcpy(out, path, PATH_MAX) >= PATH_MAX ? errSecParam : 0;
	char target[PATH_MAX];
	if (!realpath(alias, target))
		return pathError(errno);
	if (strcmp(target, allowedA) && strcmp(target, allowedB))
		return errSecNoAccessForItem;
	int n = snprintf(out, PATH_MAX, "%s%s", target, path + strlen(alias));
	return n < 0 || n >= PATH_MAX ? errSecParam : 0;
}

static OSStatus checkDirectory(int fd, const char *path, bool *created, bool privateLeaf)
{
	struct stat st;
	if (fstat(fd, &st) < 0)
		return errSecIO;
	if (!S_ISDIR(st.st_mode) || (st.st_uid != geteuid() && st.st_uid != 0))
		return errSecNoAccessForItem;
	if (created && *created) {
		/* Only fix permissions on directories this call created. */
		if (st.st_uid != geteuid())
			return errSecNoAccessForItem;
		if (fchmod(fd, 0700) < 0)
			return errSecIO;
		*created = false;
		if (fstat(fd, &st) < 0)
			return errSecIO;
	}
	if (privateLeaf) {
		/* The keychain's own folder: the user's, and nobody else may write
		 * in it (Apple's ~/Library/Keychains is 0755; the files are 0600). */
		if (st.st_uid != geteuid() || (st.st_mode & 0022))
			return errSecNoAccessForItem;
	} else if ((st.st_mode & 0022) &&
	    !(st.st_uid == 0 && (st.st_mode & S_ISVTX) && trustedTempDirectory(path)))
		return errSecNoAccessForItem;
	return 0;
}

static OSStatus openParentDirectory(const char *path, bool create, int *parentFD,
	char leaf[NAME_MAX + 1], char cachePath[PATH_MAX])
{
	if (!path || path[0] != '/' || !parentFD || !leaf)
		return errSecParam;
	*parentFD = -1;
	size_t pathLength = strlen(path);
	if (pathLength == 0 || pathLength >= PATH_MAX || path[pathLength - 1] == '/')
		return errSecParam;
	char fullPath[PATH_MAX];
	strlcpy(fullPath, path, sizeof(fullPath));
	char *slash = strrchr(fullPath, '/');
	if (!slash)
		return errSecParam;
	const char *name = slash + 1;
	if (!*name || !strcmp(name, ".") || !strcmp(name, "..") || strlen(name) > NAME_MAX)
		return errSecParam;
	strlcpy(leaf, name, NAME_MAX + 1);
	char parent[PATH_MAX];
	if (slash == fullPath)
		strlcpy(parent, "/", sizeof(parent));
	else {
		*slash = 0;
		if (strlcpy(parent, fullPath, sizeof(parent)) >= sizeof(parent))
			return errSecParam;
	}
	OSStatus err = resolveAllowedAlias(parent, fullPath);
	if (err)
		return err;
	int fd = -1;
	if (strlcpy(parent, fullPath, sizeof(parent)) >= sizeof(parent))
		return errSecParam;
	/* Walk the path directly. This rejects arbitrary parent symlinks instead
	 * of letting realpath silently turn them into another trusted location. */
	fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0)
		return pathError(errno);
	err = checkDirectory(fd, "/", NULL, false);
	if (err) {
		close(fd);
		return err;
	}
	char current[PATH_MAX] = "/";
	char *cursor = parent + 1;
	while (*cursor) {
		char *nextSlash = strchr(cursor, '/');
		if (nextSlash)
			*nextSlash = 0;
		if (!*cursor && nextSlash) {
			/* (an empty component, "a//b", names the same folder) */
			cursor = nextSlash + 1;
			continue;
		}
		if (!*cursor || !strcmp(cursor, ".") || !strcmp(cursor, "..")) {
			close(fd);
			return errSecInvalidKeychain;
		}
		if (strlen(cursor) > NAME_MAX) {
			close(fd);
			return errSecParam;
		}
		bool made = false;
		int child = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (child < 0 && errno == ENOENT && create) {
			if (mkdirat(fd, cursor, 0700) == 0)
				made = true;
			else if (errno != EEXIST) {
				err = pathError(errno);
				close(fd);
				return err;
			}
			child = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		}
		if (child < 0) {
			err = pathError(errno);
			close(fd);
			return err;
		}
		size_t used = strlen(current), remaining = sizeof(current) - used;
		int n = snprintf(current + used, remaining, !strcmp(current, "/") ? "%s" : "/%s", cursor);
		if (n < 0 || (size_t)n >= remaining) {
			close(fd);
			close(child);
			return errSecParam;
		}
		err = checkDirectory(child, current, &made, nextSlash == NULL);
		close(fd);
		if (err) {
			close(child);
			return err;
		}
		fd = child;
		if (!nextSlash)
			break;
		cursor = nextSlash + 1;
	}
	if (cachePath) {
		int n = !strcmp(current, "/") ?
		    snprintf(cachePath, PATH_MAX, "/%s", leaf) :
		    snprintf(cachePath, PATH_MAX, "%s/%s", current, leaf);
		if (n < 0 || n >= PATH_MAX) {
			close(fd);
			return errSecParam;
		}
	}
	*parentFD = fd;
	return 0;
}

static OSStatus checkKeychainFile(int fd, struct stat *out)
{
	struct stat st;
	if (fstat(fd, &st) < 0)
		return errSecIO;
	if (!S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1 ||
	    (st.st_mode & 07777) != 0600)
		return errSecInvalidKeychain;
	if (out)
		*out = st;
	return 0;
}

static OSStatus openKeychainFile(int parentFD, const char *leaf, bool write,
	bool create, int *fdOut, bool *created)
{
	*fdOut = -1;
	*created = false;
	int flags = (write ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
	int fd;
	if (create) {
		fd = openat(parentFD, leaf, flags | O_CREAT | O_EXCL, 0600);
		if (fd >= 0)
			*created = true;
		else if (errno == EEXIST)
			fd = openat(parentFD, leaf, flags);
	} else
		fd = openat(parentFD, leaf, flags);
	if (fd < 0)
		return pathError(errno);
	OSStatus err = 0;
	if (*created) {
		struct stat st;
		if (fstat(fd, &st) < 0)
			err = errSecIO;
		else if (!S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1)
			err = errSecInvalidKeychain;
		else if (fchmod(fd, 0600) < 0)
			err = errSecIO;
	}
	if (!err)
		err = checkKeychainFile(fd, NULL);
	if (err) {
		close(fd);
		*fdOut = -1;
		return err;
	}
	*fdOut = fd;
	return 0;
}

/* The caller may have used different letter case for a path on a
 * case-insensitive volume. Ask the already-checked file descriptor for the
 * spelling the file system uses, so all such paths share one cache entry. */
static OSStatus cacheIdentityForFile(int fd, char cachePath[PATH_MAX],
	char leaf[NAME_MAX + 1])
{
	if (fcntl(fd, F_GETPATH, cachePath) < 0 || cachePath[0] != '/' ||
	    !memchr(cachePath, '\0', PATH_MAX))
		return errSecInvalidKeychain;
	const char *name = strrchr(cachePath, '/') + 1;
	if (!*name || strlen(name) > NAME_MAX)
		return errSecInvalidKeychain;
	if (leaf && strlcpy(leaf, name, NAME_MAX + 1) >= NAME_MAX + 1)
		return errSecInvalidKeychain;
	return 0;
}

static void keyCacheClearKeychain(SecKeychainRef kc)
{
	char path[PATH_MAX], cachePath[PATH_MAX], leaf[NAME_MAX + 1];
	int parentFD = -1, fd = -1;
	bool created = false;
	OSStatus err = 0;
	if (!keychainPath(kc, path) ||
	    (err = openParentDirectory(path, false, &parentFD, leaf, cachePath)) != 0 ||
	    (err = openKeychainFile(parentFD, leaf, false, false, &fd, &created)) != 0 ||
	    (err = cacheIdentityForFile(fd, cachePath, NULL)) != 0) {
		/* A changed folder or unavailable file identity must not turn a
		 * successful lock into a no-op. Forget every cached key instead. */
		if (fd >= 0)
			close(fd);
		if (parentFD >= 0)
			close(parentFD);
		keyCacheClearPath(NULL);
		return;
	}
	close(fd);
	close(parentFD);
	keyCacheClearPath(cachePath);
}

#define KEYCHAIN_LOCK_NAME ".finch-keychain.lock"
#define KEYCHAIN_MAX_FILE_BYTES (SEC_KEYCHAIN_CRYPTO_HEADER_BYTES + \
	SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES + SEC_KEYCHAIN_CRYPTO_TAG_BYTES)

static atomic_ulong temporaryFileNumber = 1;

static void storeDispose(Store *s)
{
	if (s->db)
		CFRelease(s->db);
	if (s->fd >= 0)
		close(s->fd);
	if (s->lockFD >= 0) {
		(void)flock(s->lockFD, LOCK_UN);
		close(s->lockFD);
	}
	if (s->parentFD >= 0)
		close(s->parentFD);
	OPENSSL_cleanse(s->salt, sizeof(s->salt));
	OPENSSL_cleanse(s->key, sizeof(s->key));
	s->fd = s->lockFD = s->parentFD = -1;
	s->db = NULL;
	s->items = NULL;
	s->hasKey = false;
}

/* The sidecar lock stays in the directory while encrypted data files are
 * replaced. Locking the data inode itself would let another process miss the
 * lock after rename and overwrite a newer item list. */
static OSStatus openSidecarLock(int parentFD, int *fdOut)
{
	*fdOut = -1;
	int fd = openat(parentFD, KEYCHAIN_LOCK_NAME,
	    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	bool created = fd >= 0;
	if (fd < 0 && errno == EEXIST)
		fd = openat(parentFD, KEYCHAIN_LOCK_NAME,
		    O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
	if (fd < 0)
		return pathError(errno);
	struct stat st;
	OSStatus err = 0;
	if (fstat(fd, &st) < 0)
		err = errSecIO;
	else if (created && fchmod(fd, 0600) < 0)
		err = errSecIO;
	if (!err)
		err = checkKeychainFile(fd, &st);
	if (!err && st.st_size != 0)
		err = errSecInvalidKeychain;
	if (err) {
		close(fd);
		return err;
	}
	*fdOut = fd;
	return 0;
}

static void removeCreatedFile(Store *s);

static OSStatus storeAcquire(SecKeychainRef kc, bool write, bool createParent,
	bool createFile, Store *s)
{
	memset(s, 0, sizeof(*s));
	s->fd = s->lockFD = s->parentFD = -1;
	if (!keychainPath(kc, s->path))
		return errSecInvalidKeychain;
	OSStatus err = openParentDirectory(s->path, createParent, &s->parentFD,
	    s->leaf, s->cachePath);
	if (err)
		return err;
	err = openSidecarLock(s->parentFD, &s->lockFD);
	if (err) {
		storeDispose(s);
		return err;
	}
	if (flock(s->lockFD, write ? LOCK_EX : LOCK_SH) < 0) {
		storeDispose(s);
		return errSecIO;
	}
	err = openKeychainFile(s->parentFD, s->leaf, write, createFile, &s->fd, &s->created);
	if (!err)
		err = cacheIdentityForFile(s->fd, s->cachePath, s->leaf);
	if (err) {
		removeCreatedFile(s);
		storeDispose(s);
		return err;
	}
	return 0;
}

static OSStatus readEnvelope(Store *s, uint8_t **bytesOut, size_t *lengthOut)
{
	*bytesOut = NULL;
	*lengthOut = 0;
	struct stat st;
	OSStatus err = checkKeychainFile(s->fd, &st);
	if (err)
		return err;
	if (st.st_size < 0 || (uint64_t)st.st_size > KEYCHAIN_MAX_FILE_BYTES)
		return errSecInvalidKeychain;
	size_t length = (size_t)st.st_size;
	uint8_t *bytes = malloc(length ? length : 1);
	if (!bytes)
		return errSecAllocate;
	size_t offset = 0;
	while (offset < length) {
		ssize_t count = pread(s->fd, bytes + offset, length - offset, (off_t)offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			free(bytes);
			return errSecIO;
		}
		offset += (size_t)count;
	}
	*bytesOut = bytes;
	*lengthOut = length;
	return 0;
}

static OSStatus inspectEnvelope(Store *s, uint8_t **bytesOut, size_t *lengthOut,
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES], size_t *plaintextLength)
{
	uint8_t *bytes = NULL;
	size_t length = 0;
	OSStatus err = readEnvelope(s, &bytes, &length);
	if (err)
		return err;
	SecKeychainCryptoStatus crypto = finch_keychain_crypto_inspect(bytes, length,
	    salt, plaintextLength);
	if (crypto != SEC_KEYCHAIN_CRYPTO_OK) {
		free(bytes);
		return crypto == SEC_KEYCHAIN_CRYPTO_NO_MEMORY ? errSecAllocate : errSecInvalidKeychain;
	}
	if (bytesOut)
		*bytesOut = bytes;
	else
		free(bytes);
	if (lengthOut)
		*lengthOut = length;
	return 0;
}

static OSStatus parseDatabase(const uint8_t *bytes, size_t length, Store *s)
{
	if (length > LONG_MAX)
		return errSecInvalidKeychain;
	CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)length);
	if (!data)
		return errSecAllocate;
	CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data,
	    kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
	CFRelease(data);
	if (!plist || !isType(plist, CFDictionaryGetTypeID()) ||
	    !isType(CFDictionaryGetValue(plist, CFSTR("items")), CFArrayGetTypeID())) {
		if (plist)
			CFRelease(plist);
		return errSecInvalidKeychain;
	}
	s->db = (CFMutableDictionaryRef)plist;
	s->items = (CFMutableArrayRef)CFDictionaryGetValue(s->db, CFSTR("items"));
	return 0;
}

static OSStatus storeOpen(SecKeychainRef kc, bool write, Store *s)
{
	OSStatus err = storeAcquire(kc, write, false, false, s);
	if (err)
		return err;
	uint8_t *envelope = NULL;
	size_t envelopeLength = 0, plaintextLength = 0;
	uint8_t inspectedSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	err = inspectEnvelope(s, &envelope, &envelopeLength, inspectedSalt, &plaintextLength);
	OPENSSL_cleanse(inspectedSalt, sizeof(inspectedSalt));
	if (err) {
		storeDispose(s);
		return err;
	}
	if (!keyCacheCopy(s->cachePath, s->salt, s->key)) {
		free(envelope);
		storeDispose(s);
		return errSecInteractionNotAllowed;
	}
	s->hasKey = true;
	uint8_t *plaintext = NULL;
	size_t openedLength = 0;
	SecKeychainCryptoStatus crypto = finch_keychain_crypto_open_with_key(envelope,
	    envelopeLength, s->salt, s->key, &plaintext, &openedLength);
	free(envelope);
	if (crypto != SEC_KEYCHAIN_CRYPTO_OK) {
		storeDispose(s);
		if (crypto == SEC_KEYCHAIN_CRYPTO_AUTH_FAILED)
			return errSecAuthFailed;
		if (crypto == SEC_KEYCHAIN_CRYPTO_NO_MEMORY)
			return errSecAllocate;
		return errSecInvalidKeychain;
	}
	err = parseDatabase(plaintext, openedLength, s);
	finch_keychain_crypto_clear_free(plaintext, openedLength);
	if (err)
		storeDispose(s);
	return err;
}

static OSStatus writeAll(int fd, const uint8_t *bytes, size_t length)
{
	size_t offset = 0;
	while (offset < length) {
		ssize_t count = write(fd, bytes + offset, length - offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return errSecIO;
		offset += (size_t)count;
	}
	return 0;
}

static OSStatus replaceEnvelope(Store *s, const uint8_t *bytes, size_t length)
{
	char temporary[NAME_MAX + 1];
	int fd = -1;
	for (unsigned attempt = 0; attempt < 32; attempt++) {
		unsigned long serial = atomic_fetch_add(&temporaryFileNumber, 1);
		int n = snprintf(temporary, sizeof(temporary), ".finch-keychain-%ld-%lu.tmp",
		    (long)getpid(), serial);
		if (n < 0 || (size_t)n >= sizeof(temporary))
			return errSecIO;
		fd = openat(s->parentFD, temporary,
		    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
		if (fd >= 0 || errno != EEXIST)
			break;
	}
	if (fd < 0)
		return pathError(errno);
	OSStatus err = 0;
	struct stat tempInfo;
	if (fstat(fd, &tempInfo) < 0)
		err = errSecIO;
	else if (!S_ISREG(tempInfo.st_mode) || tempInfo.st_uid != geteuid() ||
	    tempInfo.st_nlink != 1 || fchmod(fd, 0600) < 0)
		err = errSecInvalidKeychain;
	if (!err)
		err = writeAll(fd, bytes, length);
	if (!err && fsync(fd) < 0)
		err = errSecIO;
	if (!err) {
		struct stat opened, current;
		err = checkKeychainFile(s->fd, &opened);
		if (!err && fstatat(s->parentFD, s->leaf, &current, AT_SYMLINK_NOFOLLOW) < 0)
			err = errno == ENOENT ? errSecNoSuchKeychain : errSecIO;
		else if (!err && (!S_ISREG(current.st_mode) || current.st_uid != geteuid() ||
		    current.st_nlink != 1 || (current.st_mode & 07777) != 0600 ||
		    current.st_dev != opened.st_dev || current.st_ino != opened.st_ino))
			err = errSecInvalidKeychain;
	}
	if (!err && renameat(s->parentFD, temporary, s->parentFD, s->leaf) < 0)
		err = pathError(errno);
	if (!err) {
		int oldFD = s->fd;
		s->fd = fd;
		fd = -1;
		(void)close(oldFD);
	}
	if (!err && fsync(s->parentFD) < 0)
		err = errSecIO;
	if (fd >= 0)
		(void)close(fd);
	if (err)
		(void)unlinkat(s->parentFD, temporary, 0);
	return err;
}

static OSStatus storeCommit(Store *s)
{
	if (!s->dirty)
		return 0;
	if (!s->hasKey || !s->db)
		return errSecInteractionNotAllowed;
	CFDataRef data = CFPropertyListCreateData(NULL, s->db,
	    kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	if (!data)
		return errSecAllocate;
	uint8_t *envelope = NULL;
	size_t envelopeLength = 0;
	SecKeychainCryptoStatus crypto = finch_keychain_crypto_seal(s->key, s->salt,
	    CFDataGetBytePtr(data), (size_t)CFDataGetLength(data),
	    &envelope, &envelopeLength);
	CFRelease(data);
	if (crypto != SEC_KEYCHAIN_CRYPTO_OK) {
		if (crypto == SEC_KEYCHAIN_CRYPTO_NO_MEMORY)
			return errSecAllocate;
		return crypto == SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT ? errSecParam : errSecIO;
	}
	OSStatus err = replaceEnvelope(s, envelope, envelopeLength);
	finch_keychain_crypto_clear_free(envelope, envelopeLength);
	if (!err)
		s->dirty = false;
	return err;
}

static OSStatus storeClose(Store *s)
{
	OSStatus err = storeCommit(s);
	storeDispose(s);
	return err;
}

static OSStatus storeInspect(SecKeychainRef kc,
	uint8_t saltOut[SEC_KEYCHAIN_CRYPTO_SALT_BYTES], char cachePathOut[PATH_MAX])
{
	Store s;
	OSStatus err = storeAcquire(kc, false, false, false, &s);
	if (err)
		return err;
	if (cachePathOut)
		strlcpy(cachePathOut, s.cachePath, PATH_MAX);
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	size_t plaintextLength = 0;
	err = inspectEnvelope(&s, NULL, NULL, salt, &plaintextLength);
	if (!err && saltOut)
		memcpy(saltOut, salt, sizeof(salt));
	OPENSSL_cleanse(salt, sizeof(salt));
	storeDispose(&s);
	return err;
}

static OSStatus createEmptyDatabase(Store *s)
{
	s->db = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFMutableArrayRef items = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (!s->db || !items) {
		if (items)
			CFRelease(items);
		return errSecAllocate;
	}
	CFDictionarySetValue(s->db, CFSTR("items"), items);
	s->items = (CFMutableArrayRef)CFDictionaryGetValue(s->db, CFSTR("items"));
	CFRelease(items);
	int version = 1;
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &version);
	if (!number) {
		return errSecAllocate;
	}
	CFDictionarySetValue(s->db, CFSTR("version"), number);
	CFRelease(number);
	return 0;
}

static void removeCreatedFile(Store *s)
{
	if (!s->created || s->fd < 0)
		return;
	struct stat opened, current;
	if (fstat(s->fd, &opened) == 0 &&
	    fstatat(s->parentFD, s->leaf, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
	    S_ISREG(current.st_mode) && current.st_uid == geteuid() && current.st_nlink == 1 &&
	    current.st_dev == opened.st_dev && current.st_ino == opened.st_ino)
		(void)unlinkat(s->parentFD, s->leaf, 0);
}

static int64_t nextID(Store *s)
{
	int64_t n = 1;
	CFNumberRef v = CFDictionaryGetValue(s->db, CFSTR("next"));
	if (isType(v, CFNumberGetTypeID()))
		CFNumberGetValue(v, kCFNumberSInt64Type, &n);
	int64_t next = n + 1;
	CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt64Type, &next);
	CFDictionarySetValue(s->db, CFSTR("next"), nv);
	CFRelease(nv);
	return n;
}

static int64_t itemID(CFDictionaryRef item)
{
	int64_t n = 0;
	CFNumberRef v = CFDictionaryGetValue(item, CFSTR("_id"));
	if (isType(v, CFNumberGetTypeID()))
		CFNumberGetValue(v, kCFNumberSInt64Type, &n);
	return n;
}

static CFIndex findID(Store *s, int64_t id)
{
	for (CFIndex i = 0; i < CFArrayGetCount(s->items); i++)
		if (itemID(CFArrayGetValueAtIndex(s->items, i)) == id)
			return i;
	return kCFNotFound;
}

/* ---- Callbacks ---- */

typedef struct Callback {
	SecKeychainCallback fn;
	SecKeychainEventMask mask;
	void *context;
	struct Callback *next;
} Callback;
static Callback *callbacks;
static pthread_mutex_t callbackLock = PTHREAD_MUTEX_INITIALIZER;

static void notify(SecKeychainEvent event, SecKeychainRef kc, SecKeychainItemRef item)
{
	pthread_mutex_lock(&callbackLock);
	for (Callback *c = callbacks; c; c = c->next) {
		if (!(c->mask & (1u << event)))
			continue;
		SecKeychainCallback fn = c->fn;
		void *ctx = c->context;
		if (kc)
			CFRetain(kc);
		if (item)
			CFRetain(item);
		dispatch_async(dispatch_get_main_queue(), ^{
			SecKeychainCallbackInfo info = {SEC_KEYCHAIN_SETTINGS_VERS1, item, kc, getpid()};
			fn(event, &info, ctx);
			if (kc)
				CFRelease(kc);
			if (item)
				CFRelease(item);
		});
	}
	pthread_mutex_unlock(&callbackLock);
}

OSStatus SecKeychainAddCallback(SecKeychainCallback fn, SecKeychainEventMask mask, void *context)
{
	if (!fn)
		return errSecParam;
	pthread_mutex_lock(&callbackLock);
	for (Callback *c = callbacks; c; c = c->next)
		if (c->fn == fn) {
			pthread_mutex_unlock(&callbackLock);
			return errSecDuplicateCallback;
		}
	Callback *c = calloc(1, sizeof(*c));
	*c = (Callback){fn, mask, context, callbacks};
	callbacks = c;
	pthread_mutex_unlock(&callbackLock);
	return 0;
}

OSStatus SecKeychainRemoveCallback(SecKeychainCallback fn)
{
	pthread_mutex_lock(&callbackLock);
	for (Callback **p = &callbacks; *p; p = &(*p)->next)
		if ((*p)->fn == fn) {
			Callback *c = *p;
			*p = c->next;
			free(c);
			pthread_mutex_unlock(&callbackLock);
			return 0;
		}
	pthread_mutex_unlock(&callbackLock);
	return errSecInvalidCallback;
}

/* ---- Keychain calls ---- */

static atomic_bool interactionAllowed = true;

OSStatus SecKeychainGetUserInteractionAllowed(Boolean *state)
{
	if (!state)
		return errSecParam;
	#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		CFTypeRef value = NULL;
		OSStatus status = _FinchKeychainServiceCall(CFSTR("keychain.interaction-get"), NULL, &value);
		if (!status && isType(value, CFBooleanGetTypeID()))
			*state = CFBooleanGetValue(value);
		else if (!status)
			status = errSecInternalComponent;
		if (value)
			CFRelease(value);
		return status;
	}
	#endif
	*state = atomic_load(&interactionAllowed);
	return 0;
}

OSStatus SecKeychainSetUserInteractionAllowed(Boolean state)
{
	#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		CFMutableDictionaryRef request = newServiceRequest();
		if (!request)
			return errSecAllocate;
		CFDictionarySetValue(request, CFSTR("allowed"), state ? kCFBooleanTrue : kCFBooleanFalse);
		OSStatus status = keychainServiceCall(CFSTR("keychain.interaction-set"), request, NULL);
		CFRelease(request);
		return status;
	}
	#endif
	atomic_store(&interactionAllowed, state);
	return 0;
}

OSStatus SecKeychainCreate(const char *pathName, UInt32 passwordLength, const void *password,
    Boolean promptUser, SecAccessRef initialAccess, SecKeychainRef *keychain)
{
	if (!pathName || !keychain)
		return errSecParam;
	*keychain = NULL;
	if (!password || passwordLength == 0)
		return errSecPassphraseRequired;
	if (passwordLength > SEC_KEYCHAIN_CRYPTO_MAX_PASSWORD_BYTES)
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (!*pathName)
			return errSecParam;
		CFStringRef path = CFStringCreateWithBytes(NULL, (const UInt8 *)pathName,
		    (CFIndex)strlen(pathName), kCFStringEncodingUTF8, false);
		if (!path)
			return errSecParam;
		CFDataRef passwordData = CFDataCreate(NULL, password, passwordLength);
		CFMutableDictionaryRef request = newServiceRequest();
		if (!passwordData || !request) {
			CFRelease(path);
			if (passwordData) CFRelease(passwordData);
			if (request) CFRelease(request);
			return errSecAllocate;
		}
		CFDictionarySetValue(request, CFSTR("path"), path);
		CFDictionarySetValue(request, CFSTR("password"), passwordData);
		CFTypeRef response = NULL;
		OSStatus status = keychainServiceCall(CFSTR("keychain.create"), request, &response);
		if (!status && isType(response, SecKeychainGetTypeID()))
			*keychain = (SecKeychainRef)response;
		else {
			if (response)
				CFRelease(response);
			if (!status)
				status = errSecInternalComponent;
		}
		CFRelease(request);
		CFRelease(passwordData);
		CFRelease(path);
		return status;
	}
#endif
	CFStringRef path = absolutePath(pathName);
	if (!path)
		return errSecParam;
	SecKeychainRef kc = keychainCreate(path);
	CFRelease(path);
	if (!kc)
		return errSecAllocate;
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	SecKeychainCryptoStatus crypto = finch_keychain_crypto_create_key(password,
	    passwordLength, salt, key);
	if (crypto != SEC_KEYCHAIN_CRYPTO_OK) {
		CFRelease(kc);
		OPENSSL_cleanse(salt, sizeof(salt));
		OPENSSL_cleanse(key, sizeof(key));
		return crypto == SEC_KEYCHAIN_CRYPTO_NO_MEMORY ? errSecAllocate : errSecIO;
	}
	Store s;
	OSStatus st = storeAcquire(kc, true, true, true, &s);
	if (!st && !s.created) {
		uint8_t existingSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
		size_t plaintextLength = 0;
		st = inspectEnvelope(&s, NULL, NULL, existingSalt, &plaintextLength);
		OPENSSL_cleanse(existingSalt, sizeof(existingSalt));
		if (!st)
			st = errSecDuplicateKeychain;
		storeDispose(&s);
	} else if (!st) {
		memcpy(s.salt, salt, sizeof(s.salt));
		memcpy(s.key, key, sizeof(s.key));
		s.hasKey = true;
		st = createEmptyDatabase(&s);
		if (!st) {
			s.dirty = true;
			st = storeCommit(&s);
		}
		if (!st)
			st = keyCacheSet(s.cachePath, salt, key);
		if (st)
			removeCreatedFile(&s);
		storeDispose(&s);
	}
	OPENSSL_cleanse(salt, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	if (st) {
		CFRelease(kc);
		return st;
	}
	*keychain = kc;
	notify(kSecKeychainListChangedEvent, kc, NULL);
	return 0;
}

OSStatus SecKeychainOpen(const char *pathName, SecKeychainRef *keychain)
{
	if (!pathName || !keychain)
		return errSecParam;
	*keychain = NULL;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (!*pathName)
			return errSecParam;
		CFStringRef path = CFStringCreateWithBytes(NULL, (const UInt8 *)pathName,
		    (CFIndex)strlen(pathName), kCFStringEncodingUTF8, false);
		if (!path)
			return errSecParam;
		CFMutableDictionaryRef request = newServiceRequest();
		if (!request) {
			CFRelease(path);
			if (request) CFRelease(request);
			return errSecAllocate;
		}
		CFDictionarySetValue(request, CFSTR("path"), path);
		CFTypeRef response = NULL;
		OSStatus status = keychainServiceCall(CFSTR("keychain.open"), request, &response);
		if (!status && isType(response, SecKeychainGetTypeID()))
			*keychain = (SecKeychainRef)response;
		else {
			if (response)
				CFRelease(response);
			if (!status)
				status = errSecInternalComponent;
		}
		CFRelease(request);
		CFRelease(path);
		return status;
	}
#endif
	CFStringRef path = absolutePath(pathName);
	if (!path)
		return errSecParam;
	SecKeychainRef kc = keychainCreate(path);
	CFRelease(path);
	if (!kc)
		return errSecAllocate;
	OSStatus st = storeInspect(kc, NULL, NULL);
	if (st) {
		CFRelease(kc);
		return st;
	}
	*keychain = kc;
	return 0;
}

OSStatus SecKeychainDelete(SecKeychainRef keychainOrArray)
{
	if (!keychainOrArray)
		return errSecInvalidKeychain;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (!isType(keychainOrArray, SecKeychainGetTypeID()) &&
		    !isType(keychainOrArray, CFArrayGetTypeID()))
			return errSecInvalidKeychain;
		CFMutableDictionaryRef request = newServiceRequest();
		if (!request)
			return errSecAllocate;
		CFDictionarySetValue(request, CFSTR("keychain"), keychainOrArray);
		OSStatus status = keychainServiceCall(CFSTR("keychain.delete"), request, NULL);
		CFRelease(request);
		return status;
	}
#endif
	if (isType(keychainOrArray, CFArrayGetTypeID())) {
		CFArrayRef a = (CFArrayRef)keychainOrArray;
		for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
			OSStatus st = SecKeychainDelete((SecKeychainRef)CFArrayGetValueAtIndex(a, i));
			if (st)
				return st;
		}
		return 0;
	}
	if (!isType(keychainOrArray, SecKeychainGetTypeID()))
		return errSecInvalidKeychain;
	/* Keep the stable directory lock and validated descriptor through unlink. */
	Store contents;
	OSStatus st = storeAcquire((SecKeychainRef)keychainOrArray, true, false, false, &contents);
	if (st)
		return st;
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	size_t plaintextLength = 0;
	st = inspectEnvelope(&contents, NULL, NULL, salt, &plaintextLength);
	OPENSSL_cleanse(salt, sizeof(salt));
	struct stat opened, current;
	if (!st)
		st = checkKeychainFile(contents.fd, &opened);
	if (!st &&
	    fstatat(contents.parentFD, contents.leaf, &current, AT_SYMLINK_NOFOLLOW) < 0) {
		st = errno == ENOENT ? errSecNoSuchKeychain : errSecIO;
	} else if (!st && (!S_ISREG(current.st_mode) || current.st_uid != geteuid() ||
	    current.st_nlink != 1 || (current.st_mode & 07777) != 0600 ||
	    current.st_dev != opened.st_dev || current.st_ino != opened.st_ino)) {
		st = errSecInvalidKeychain;
	} else if (!st && unlinkat(contents.parentFD, contents.leaf, 0) < 0)
		st = pathError(errno);
	if (!st)
		keyCacheClearPath(contents.cachePath);
	storeDispose(&contents);
	if (st)
		return st;
	notify(kSecKeychainListChangedEvent, keychainOrArray, NULL);
	return 0;
}

OSStatus SecKeychainCopyDefault(SecKeychainRef *keychain)
{
	if (!keychain)
		return errSecParam;
	*keychain = defaultKeychain();
	return *keychain ? 0 : errSecNotAvailable;
}

OSStatus SecKeychainCopyDomainDefault(SecPreferencesDomain domain, SecKeychainRef *keychain)
{
	return SecKeychainCopyDefault(keychain);
}

OSStatus SecKeychainCopyLogin(SecKeychainRef *keychain)
{
	return SecKeychainCopyDefault(keychain);
}

OSStatus SecKeychainSetDefault(SecKeychainRef keychain)
{
	return isType(keychain, SecKeychainGetTypeID()) ? 0 : errSecParam;
}

OSStatus SecKeychainCopySearchList(CFArrayRef *searchList)
{
	if (!searchList)
		return errSecParam;
	SecKeychainRef kc = NULL;
	OSStatus status = SecKeychainCopyDefault(&kc);
	if (status)
		return status;
	*searchList = CFArrayCreate(NULL, (const void **)&kc, 1, &kCFTypeArrayCallBacks);
	CFRelease(kc);
	return *searchList ? 0 : errSecAllocate;
}

OSStatus SecKeychainCopyDomainSearchList(SecPreferencesDomain domain, CFArrayRef *searchList)
{
	return SecKeychainCopySearchList(searchList);
}

OSStatus SecKeychainSetSearchList(CFArrayRef searchList)
{
	return isType(searchList, CFArrayGetTypeID()) ? 0 : errSecParam;
}

OSStatus SecKeychainGetPath(SecKeychainRef keychain, UInt32 *ioPathLength, char *pathName)
{
	if (!ioPathLength || !pathName)
		return errSecParam;
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	if (!isType(kc, SecKeychainGetTypeID())) {
		CFRelease(kc);
		return errSecInvalidKeychain;
	}
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	CFRelease(kc);
	size_t n = strlen(p);
	if (n + 1 > *ioPathLength)
		return errSecBufferTooSmall;
	memcpy(pathName, p, n + 1);
	*ioPathLength = (UInt32)n;
	return 0;
}

OSStatus SecKeychainGetStatus(SecKeychainRef keychain, SecKeychainStatus *status)
{
	if (!status)
		return errSecParam;
	*status = 0;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (keychain && !isType(keychain, SecKeychainGetTypeID()))
			return errSecInvalidKeychain;
		CFMutableDictionaryRef request = newServiceRequest();
		if (!request)
			return errSecAllocate;
		if (keychain)
			CFDictionarySetValue(request, CFSTR("keychain"), keychain);
		CFTypeRef response = NULL;
		OSStatus result = keychainServiceCall(CFSTR("keychain.status"), request, &response);
		if (!result && isType(response, CFNumberGetTypeID()))
			CFNumberGetValue(response, kCFNumberSInt32Type, status);
		else if (!result)
			result = errSecInternalComponent;
		if (response)
			CFRelease(response);
		CFRelease(request);
		return result;
	}
#endif
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	if (!isType(kc, SecKeychainGetTypeID())) {
		CFRelease(kc);
		return errSecInvalidKeychain;
	}
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	char cachePath[PATH_MAX];
	OSStatus st = storeInspect(kc, salt, cachePath);
	if (!st)
		*status = kSecReadPermStatus | kSecWritePermStatus |
		    (keyCacheMatchesSalt(cachePath, salt) ? kSecUnlockStateStatus : 0);
	OPENSSL_cleanse(salt, sizeof(salt));
	CFRelease(kc);
	return st;
}

OSStatus SecKeychainLock(SecKeychainRef keychain)
{
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (keychain && !isType(keychain, SecKeychainGetTypeID()))
			return errSecInvalidKeychain;
		CFMutableDictionaryRef request = newServiceRequest();
		if (!request)
			return errSecAllocate;
		if (keychain)
			CFDictionarySetValue(request, CFSTR("keychain"), keychain);
		OSStatus status = keychainServiceCall(CFSTR("keychain.lock"), request, NULL);
		CFRelease(request);
		return status;
	}
#endif
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	if (!isType(kc, SecKeychainGetTypeID())) {
		if (kc)
			CFRelease(kc);
		return errSecInvalidKeychain;
	}
	keyCacheClearKeychain(kc);
	CFRelease(kc);
	return 0;
}
OSStatus SecKeychainLockAll(void)
{
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive())
		return _FinchKeychainServiceCall(CFSTR("keychain.lock-all"), NULL, NULL);
#endif
	keyCacheClearPath(NULL);
	return 0;
}
OSStatus SecKeychainUnlock(SecKeychainRef keychain, UInt32 passwordLength, const void *password, Boolean usePassword)
{
	if (!password || passwordLength == 0)
		return errSecPassphraseRequired;
	if (passwordLength > SEC_KEYCHAIN_CRYPTO_MAX_PASSWORD_BYTES)
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive()) {
		if (keychain && !isType(keychain, SecKeychainGetTypeID()))
			return errSecInvalidKeychain;
		CFDataRef passwordData = CFDataCreate(NULL, password, passwordLength);
		CFMutableDictionaryRef request = newServiceRequest();
		if (!passwordData || !request) {
			if (passwordData) CFRelease(passwordData);
			if (request) CFRelease(request);
			return errSecAllocate;
		}
		if (keychain)
			CFDictionarySetValue(request, CFSTR("keychain"), keychain);
		CFDictionarySetValue(request, CFSTR("password"), passwordData);
		CFDictionarySetValue(request, CFSTR("usePassword"), usePassword ? kCFBooleanTrue : kCFBooleanFalse);
		OSStatus status = keychainServiceCall(CFSTR("keychain.unlock"), request, NULL);
		CFRelease(request);
		CFRelease(passwordData);
		return status;
	}
#endif
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	if (!isType(kc, SecKeychainGetTypeID())) {
		if (kc)
			CFRelease(kc);
		return errSecInvalidKeychain;
	}
	Store s;
	OSStatus err = storeAcquire(kc, false, false, false, &s);
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	uint8_t *envelope = NULL, *plaintext = NULL;
	size_t envelopeLength = 0, plaintextLength = 0;
	OPENSSL_cleanse(salt, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	if (!err)
		err = readEnvelope(&s, &envelope, &envelopeLength);
	if (!err) {
		SecKeychainCryptoStatus crypto = finch_keychain_crypto_unlock(envelope,
		    envelopeLength, password, passwordLength, salt, key, &plaintext,
		    &plaintextLength);
		if (crypto == SEC_KEYCHAIN_CRYPTO_AUTH_FAILED)
			err = errSecAuthFailed;
		else if (crypto == SEC_KEYCHAIN_CRYPTO_NO_MEMORY)
			err = errSecAllocate;
		else if (crypto != SEC_KEYCHAIN_CRYPTO_OK)
			err = errSecInvalidKeychain;
	}
	free(envelope);
	if (!err)
		err = parseDatabase(plaintext, plaintextLength, &s);
	if (plaintext)
		finch_keychain_crypto_clear_free(plaintext, plaintextLength);
	if (!err)
		err = keyCacheSet(s.cachePath, salt, key);
	storeDispose(&s);
	OPENSSL_cleanse(salt, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	CFRelease(kc);
	return err;
}
OSStatus SecKeychainGetVersion(UInt32 *returnVers)
{
	if (!returnVers)
		return errSecParam;
	*returnVers = 0x00010000;
	return 0;
}
OSStatus SecKeychainGetPreferenceDomain(SecPreferencesDomain *domain)
{
	if (!domain)
		return errSecParam;
	*domain = kSecPreferencesDomainUser;
	return 0;
}
OSStatus SecKeychainSetPreferenceDomain(SecPreferencesDomain domain)
{
	return 0;
}

/* ---- Items: attributes and matching ---- */

static CFStringRef const kClass = CFSTR("class");
static CFStringRef const kID = CFSTR("_id");
static CFStringRef const kSync = CFSTR("sync");

static bool isClass(CFTypeRef c)
{
	return isType(c, CFStringGetTypeID()) &&
	    (CFEqual(c, kSecClassGenericPassword) || CFEqual(c, kSecClassInternetPassword) ||
	        CFEqual(c, kSecClassCertificate) || CFEqual(c, kSecClassKey) || CFEqual(c, kSecClassIdentity));
}

/* Attribute keys are Apple's four-letter (or so) names; query controls have
 * prefixes (r_, m_, u_, v_) or are class. */
static bool isAttributeKey(CFStringRef k)
{
	if (!isType(k, CFStringGetTypeID()) || CFEqual(k, kClass))
		return false;
	if (CFStringGetLength(k) > 2 && CFStringGetCharacterAtIndex(k, 1) == '_')
		return false;
	return true;
}

static const CFStringRef *primaryKeys(CFStringRef cls)
{
	static const CFStringRef genp[] = {CFSTR("acct"), CFSTR("svce"), NULL};
	static const CFStringRef inet[] = {CFSTR("acct"), CFSTR("sdmn"), CFSTR("srvr"), CFSTR("ptcl"),
	    CFSTR("atyp"), CFSTR("port"), CFSTR("path"), NULL};
	static const CFStringRef cert[] = {CFSTR("ctyp"), CFSTR("issr"), CFSTR("slnr"), NULL};
	static const CFStringRef keys[] = {CFSTR("kcls"), CFSTR("klbl"), CFSTR("atag"), CFSTR("type"), CFSTR("bsiz"), NULL};
	if (CFEqual(cls, kSecClassGenericPassword))
		return genp;
	if (CFEqual(cls, kSecClassInternetPassword))
		return inet;
	if (CFEqual(cls, kSecClassCertificate))
		return cert;
	return keys;
}

static bool sameValue(CFTypeRef a, CFTypeRef b)
{
	if (!a || !b)
		return a == b;
	/* A port or type given as a number matches a stored number. */
	return CFEqual(a, b);
}

static bool duplicate(Store *s, CFDictionaryRef item, int64_t except)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	const CFStringRef *keys = primaryKeys(cls);
	for (CFIndex i = 0; i < CFArrayGetCount(s->items); i++) {
		CFDictionaryRef other = CFArrayGetValueAtIndex(s->items, i);
		if (itemID(other) == except || !CFEqual(CFDictionaryGetValue(other, kClass), cls))
			continue;
		bool same = sameValue(CFDictionaryGetValue(item, kSync), CFDictionaryGetValue(other, kSync)) ||
		    (!CFDictionaryGetValue(item, kSync) && CFDictionaryGetValue(other, kSync) == kCFBooleanFalse);
		for (int k = 0; same && keys[k]; k++)
			same = sameValue(CFDictionaryGetValue(item, keys[k]), CFDictionaryGetValue(other, keys[k]));
		if (same)
			return true;
	}
	return false;
}

/* What a search covers: the keychains and the filters. */
typedef struct {
	CFStringRef itemClass;   /* NULL: any (persistent-reference lookups) */
	CFMutableArrayRef keychains;
	CFDictionaryRef query;
	int64_t onlyID;          /* a persistent reference or item ref: that item */
	SecKeychainRef onlyKeychain;
	CFDataRef certData;      /* kSecValueRef of a certificate */
	CFIndex limit;           /* -1: all */
	bool syncAny, syncOnly;
} Search;

static CFDataRef persistentRef(SecKeychainRef kc, int64_t id)
{
	CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
	CFDataAppendBytes(d, (const UInt8 *)"FNKC", 4);
	CFDataAppendBytes(d, (const UInt8 *)&id, sizeof(id));
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	CFDataAppendBytes(d, (const UInt8 *)p, strlen(p));
	return d;
}

static bool parsePersistentRef(CFDataRef d, SecKeychainRef *kc, int64_t *id)
{
	if (!isType(d, CFDataGetTypeID()) || CFDataGetLength(d) <= 12 ||
	    CFDataGetLength(d) - 12 >= PATH_MAX || memcmp(CFDataGetBytePtr(d), "FNKC", 4) ||
	    memchr(CFDataGetBytePtr(d) + 12, 0, (size_t)(CFDataGetLength(d) - 12)))
		return false;
	memcpy(id, CFDataGetBytePtr(d) + 4, sizeof(*id));
	CFStringRef path = CFStringCreateWithBytes(NULL, CFDataGetBytePtr(d) + 12, CFDataGetLength(d) - 12,
	    kCFStringEncodingUTF8, false);
	if (!path)
		return false;
	char nativePath[PATH_MAX];
	if (!CFStringGetFileSystemRepresentation(path, nativePath, sizeof(nativePath)) ||
	    nativePath[0] != '/' || strlen(nativePath) != (size_t)(CFDataGetLength(d) - 12)) {
		CFRelease(path);
		return false;
	}
	*kc = keychainCreate(path);
	CFRelease(path);
	return *kc != NULL;
}

SEC_HIDDEN SecKeychainItemRef
_FinchKeychainCreateItemProxy(CFDataRef persistentItemRef)
{
	SecKeychainRef keychain = NULL;
	int64_t id = 0;
	if (!parsePersistentRef(persistentItemRef, &keychain, &id))
		return NULL;
	Item *item = (Item *)_SecCreateInstance(SecKeychainItemGetTypeID(), sizeof(*item));
	if (!item) {
		CFRelease(keychain);
		return NULL;
	}
	item->keychain = keychain;
	item->itemClass = CFRetain(kSecClassGenericPassword);
	item->id = id;
	return (SecKeychainItemRef)item;
}

static OSStatus searchInit(Search *s, CFDictionaryRef query, bool defaultAll)
{
	memset(s, 0, sizeof(*s));
	s->query = query;
	s->limit = defaultAll ? -1 : 1;
	s->keychains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFTypeRef pref = CFDictionaryGetValue(query, kSecValuePersistentRef);
	CFTypeRef vref = CFDictionaryGetValue(query, kSecValueRef);
	if (pref) {
		if (!parsePersistentRef(pref, &s->onlyKeychain, &s->onlyID))
			return errSecItemNotFound;
		CFArrayAppendValue(s->keychains, s->onlyKeychain);
	} else if (vref && isType(vref, SecKeychainItemGetTypeID())) {
		Item *it = (Item *)vref;
		s->onlyID = it->id;
		s->onlyKeychain = (SecKeychainRef)CFRetain(it->keychain);
		s->itemClass = it->itemClass;
		CFArrayAppendValue(s->keychains, it->keychain);
	}
	if (!s->onlyID) {
		s->itemClass = CFDictionaryGetValue(query, kClass);
		if (!isClass(s->itemClass))
			return errSecParam;
		if (vref && isType(vref, SecCertificateGetTypeID()))
			s->certData = SecCertificateCopyData((SecCertificateRef)vref);
		CFTypeRef list = CFDictionaryGetValue(query, kSecMatchSearchList);
		CFTypeRef use = CFDictionaryGetValue(query, kSecUseKeychain);
		if (isType(list, CFArrayGetTypeID())) {
			for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
				if (isType(CFArrayGetValueAtIndex(list, i), SecKeychainGetTypeID()))
					CFArrayAppendValue(s->keychains, CFArrayGetValueAtIndex(list, i));
		} else if (isType(use, SecKeychainGetTypeID()))
			CFArrayAppendValue(s->keychains, use);
		else {
			SecKeychainRef kc = defaultKeychain();
			CFArrayAppendValue(s->keychains, kc);
			CFRelease(kc);
		}
	}
	CFTypeRef limit = CFDictionaryGetValue(query, kSecMatchLimit);
	if (limit) {
		if (CFEqual(limit, kSecMatchLimitAll))
			s->limit = -1;
		else if (CFEqual(limit, kSecMatchLimitOne))
			s->limit = 1;
		else if (isType(limit, CFNumberGetTypeID()))
			CFNumberGetValue(limit, kCFNumberCFIndexType, &s->limit);
		else
			return errSecParam;
	}
	CFTypeRef sync = CFDictionaryGetValue(query, kSecAttrSynchronizable);
	if (sync && CFEqual(sync, kSecAttrSynchronizableAny))
		s->syncAny = true;
	else if (sync == kCFBooleanTrue || (isType(sync, CFNumberGetTypeID()) && CFBooleanGetValue(sync)))
		s->syncOnly = true;
	return 0;
}

static void searchFree(Search *s)
{
	if (s->keychains)
		CFRelease(s->keychains);
	if (s->onlyKeychain)
		CFRelease(s->onlyKeychain);
	if (s->certData)
		CFRelease(s->certData);
}

static bool truthy(CFTypeRef v)
{
	if (v == kCFBooleanTrue)
		return true;
	if (isType(v, CFNumberGetTypeID())) {
		int n = 0;
		CFNumberGetValue(v, kCFNumberIntType, &n);
		return n != 0;
	}
	return false;
}

static bool matches(Search *s, CFDictionaryRef item)
{
	if (s->onlyID)
		return itemID(item) == s->onlyID;
	if (!CFEqual(CFDictionaryGetValue(item, kClass), s->itemClass))
		return false;
	bool synced = truthy(CFDictionaryGetValue(item, kSync));
	if (!s->syncAny && synced != s->syncOnly)
		return false;
	if (s->certData && !sameValue(CFDictionaryGetValue(item, kSecValueData), s->certData))
		return false;
	CFIndex n = CFDictionaryGetCount(s->query);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(s->query, keys, values);
	bool ok = true;
	for (CFIndex i = 0; ok && i < n; i++) {
		if (!isAttributeKey(keys[i]) || CFEqual(keys[i], kSync) || CFEqual(keys[i], kSecAttrAccess) ||
		    CFEqual(keys[i], kSecAttrAccessGroup) || CFEqual(keys[i], kSecAttrAccessible) ||
		    CFEqual(keys[i], kSecAttrAccessControl) || CFEqual(keys[i], CFSTR("nleg")))
			continue;
		ok = sameValue(CFDictionaryGetValue(item, keys[i]), values[i]);
	}
	free(keys);
	free(values);
	return ok;
}

/* ---- Results ---- */

static CFTypeRef refFor(SecKeychainRef kc, CFDictionaryRef item);

static CFDictionaryRef attributesOf(CFDictionaryRef item)
{
	CFMutableDictionaryRef a = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFIndex n = CFDictionaryGetCount(item);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(item, keys, values);
	for (CFIndex i = 0; i < n; i++)
		if ((isAttributeKey(keys[i]) && !CFEqual(keys[i], kID)) || CFEqual(keys[i], kClass))
			CFDictionarySetValue(a, keys[i], values[i]);
	free(keys);
	free(values);
	return a;
}

/* One result in the shape the query asks for: a single return type gives
 * that value, several a dictionary. */
static CFTypeRef resultFor(CFDictionaryRef query, SecKeychainRef kc, CFDictionaryRef item)
{
	bool data = truthy(CFDictionaryGetValue(query, kSecReturnData));
	bool attrs = truthy(CFDictionaryGetValue(query, kSecReturnAttributes));
	bool ref = truthy(CFDictionaryGetValue(query, kSecReturnRef));
	bool pref = truthy(CFDictionaryGetValue(query, kSecReturnPersistentRef));
	int count = data + attrs + ref + pref;
	if (count == 0)
		return refFor(kc, item);
	if (count == 1) {
		if (data) {
			CFTypeRef v = CFDictionaryGetValue(item, kSecValueData);
			return v ? CFRetain(v) : CFDataCreate(NULL, NULL, 0);
		}
		if (attrs)
			return attributesOf(item);
		if (ref)
			return refFor(kc, item);
		return persistentRef(kc, itemID(item));
	}
	CFMutableDictionaryRef d;
	if (attrs) {
		CFDictionaryRef a = attributesOf(item);
		d = CFDictionaryCreateMutableCopy(NULL, 0, a);
		CFRelease(a);
	} else
		d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (data) {
		CFTypeRef v = CFDictionaryGetValue(item, kSecValueData);
		if (v)
			CFDictionarySetValue(d, kSecValueData, v);
	}
	if (ref) {
		CFTypeRef r = refFor(kc, item);
		if (r) {
			CFDictionarySetValue(d, kSecValueRef, r);
			CFRelease(r);
		}
	}
	if (pref) {
		CFDataRef p = persistentRef(kc, itemID(item));
		CFDictionarySetValue(d, kSecValuePersistentRef, p);
		CFRelease(p);
	}
	return d;
}

/* ---- Certificates, keys and identities in the store ---- */

static void setNumber(CFMutableDictionaryRef d, CFStringRef k, int v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}

static void certificateAttributes(CFMutableDictionaryRef item, SecCertificateRef c)
{
	CFDataRef der = SecCertificateCopyData(c);
	CFDictionarySetValue(item, kSecValueData, der);
	CFRelease(der);
	setNumber(item, CFSTR("ctyp"), 1);   /* CSSM_CERT_X_509v3 */
	setNumber(item, CFSTR("cenc"), 3);   /* CSSM_CERT_ENCODING_DER */
	if (!CFDictionaryGetValue(item, CFSTR("labl"))) {
		CFStringRef label = SecCertificateCopySubjectSummary(c);
		if (label) {
			CFDictionarySetValue(item, CFSTR("labl"), label);
			CFRelease(label);
		}
	}
	CFDataRef subj = _SecCertificateCopyNameDER(c, false), issr = _SecCertificateCopyNameDER(c, true);
	CFDataRef slnr = SecCertificateCopySerialNumberData(c, NULL), pkhh = _SecCertificateCopyPublicKeySHA1(c);
	if (subj) { CFDictionarySetValue(item, CFSTR("subj"), subj); CFRelease(subj); }
	if (issr) { CFDictionarySetValue(item, CFSTR("issr"), issr); CFRelease(issr); }
	if (slnr) { CFDictionarySetValue(item, CFSTR("slnr"), slnr); CFRelease(slnr); }
	if (pkhh) { CFDictionarySetValue(item, CFSTR("pkhh"), pkhh); CFRelease(pkhh); }
	CFArrayRef emails = NULL;
	if (SecCertificateCopyEmailAddresses(c, &emails) == 0 && emails) {
		if (CFArrayGetCount(emails))
			CFDictionarySetValue(item, CFSTR("alis"), CFArrayGetValueAtIndex(emails, 0));
		CFRelease(emails);
	}
}

static void keyAttributes(CFMutableDictionaryRef item, SecKeyRef k)
{
	CFDictionaryRef a = SecKeyCopyAttributes(k);
	CFDataRef ext = SecKeyCopyExternalRepresentation(k, NULL);
	if (ext) {
		CFDictionarySetValue(item, kSecValueData, ext);
		CFRelease(ext);
	}
	CFStringRef copy[] = {kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits, kSecAttrEffectiveKeySize,
	    kSecAttrApplicationLabel, kSecAttrCanEncrypt, kSecAttrCanDecrypt, kSecAttrCanSign, kSecAttrCanVerify,
	    kSecAttrCanDerive};
	for (size_t i = 0; a && i < sizeof(copy) / sizeof(*copy); i++)
		if (!CFDictionaryGetValue(item, copy[i]) && CFDictionaryGetValue(a, copy[i]))
			CFDictionarySetValue(item, copy[i], CFDictionaryGetValue(a, copy[i]));
	CFDictionarySetValue(item, kSecAttrIsPermanent, kCFBooleanTrue);
	if (a)
		CFRelease(a);
}

static SecKeyRef keyFromItem(CFDictionaryRef item)
{
	CFDataRef d = CFDictionaryGetValue(item, kSecValueData);
	if (!d)
		return NULL;
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef keys[] = {kSecAttrKeyType, kSecAttrKeyClass};
	for (int i = 0; i < 2; i++) {
		CFTypeRef v = CFDictionaryGetValue(item, keys[i]);
		if (v)
			CFDictionarySetValue(attrs, keys[i], v);
	}
	SecKeyRef k = SecKeyCreateWithData(d, attrs, NULL);
	CFRelease(attrs);
	return k;
}

static CFTypeRef refFor(SecKeychainRef kc, CFDictionaryRef item)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	if (CFEqual(cls, kSecClassCertificate))
		return SecCertificateCreateWithData(NULL, CFDictionaryGetValue(item, kSecValueData));
	if (CFEqual(cls, kSecClassKey))
		return keyFromItem(item);
	if (CFEqual(cls, kSecClassIdentity)) {
		SecCertificateRef c = SecCertificateCreateWithData(NULL, CFDictionaryGetValue(item, kSecValueData));
		CFDictionaryRef keyItem = CFDictionaryGetValue(item, CFSTR("_key"));
		SecKeyRef k = keyItem ? keyFromItem(keyItem) : NULL;
		SecIdentityRef ident = c && k ? _SecIdentityCreate(c, k) : NULL;
		if (c)
			CFRelease(c);
		if (k)
			CFRelease(k);
		return ident;
	}
	Item *it = (Item *)_SecCreateInstance(SecKeychainItemGetTypeID(), sizeof(*it));
	it->keychain = (SecKeychainRef)CFRetain(kc);
	it->itemClass = CFRetain(cls);
	it->id = itemID(item);
	return (CFTypeRef)it;
}

/* Identities aren't stored: they're certificates whose public key matches a
 * private key's application label. The search yields synthetic items. */
static CFArrayRef identitiesIn(Store *st)
{
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(st->items); i++) {
		CFDictionaryRef cert = CFArrayGetValueAtIndex(st->items, i);
		if (!CFEqual(CFDictionaryGetValue(cert, kClass), kSecClassCertificate))
			continue;
		CFDataRef pkhh = CFDictionaryGetValue(cert, CFSTR("pkhh"));
		for (CFIndex j = 0; pkhh && j < CFArrayGetCount(st->items); j++) {
			CFDictionaryRef key = CFArrayGetValueAtIndex(st->items, j);
			if (!CFEqual(CFDictionaryGetValue(key, kClass), kSecClassKey) ||
			    !sameValue(CFDictionaryGetValue(key, kSecAttrKeyClass), kSecAttrKeyClassPrivate) ||
			    !sameValue(CFDictionaryGetValue(key, kSecAttrApplicationLabel), pkhh))
				continue;
			CFMutableDictionaryRef ident = CFDictionaryCreateMutableCopy(NULL, 0, cert);
			CFDictionarySetValue(ident, kClass, kSecClassIdentity);
			CFDictionarySetValue(ident, CFSTR("_key"), key);
			CFArrayAppendValue(out, ident);
			CFRelease(ident);
		}
	}
	return out;
}

/* ---- SecItem ---- */

typedef OSStatus (^ItemVisitor)(Store *store, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex index, bool *stop);

/* Runs visit on each matching item, in each keychain of the search. */
static OSStatus forEachMatch(Search *s, bool write, CFIndex *found, ItemVisitor visit)
{
	*found = 0;
	bool stop = false;
	for (CFIndex k = 0; !stop && k < CFArrayGetCount(s->keychains); k++) {
		SecKeychainRef kc = (SecKeychainRef)CFArrayGetValueAtIndex(s->keychains, k);
		Store st;
		OSStatus err = storeOpen(kc, write, &st);
		if (err == errSecNoSuchKeychain)
			continue;
		if (err)
			return err;
		/* A snapshot: visitors may remove items (they find them by ID). */
		CFArrayRef idents = s->itemClass && CFEqual(s->itemClass, kSecClassIdentity)
		    ? identitiesIn(&st)
		    : CFArrayCreateCopy(NULL, st.items);
		CFArrayRef pool = idents;
		for (CFIndex i = 0; !stop && i < CFArrayGetCount(pool); i++) {
			CFMutableDictionaryRef item = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(pool, i);
			if (!matches(s, item))
				continue;
			err = visit(&st, kc, item, findID(&st, itemID(item)), &stop);
			if (err) {
				CFRelease(idents);
				storeClose(&st);
				return err;
			}
			(*found)++;
			if (s->limit > 0 && *found >= s->limit)
				stop = true;
		}
		CFRelease(idents);
		err = storeClose(&st);
		if (err)
			return err;
	}
	return 0;
}

OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
{
	if (result)
		*result = NULL;
	if (!isType(query, CFDictionaryGetTypeID()))
		return errSecParam;
	/* as Apple's: a query names its class (or the item itself), checked before any search */
	if (!CFDictionaryGetValue(query, kSecValuePersistentRef) && !CFDictionaryGetValue(query, kSecValueRef) &&
	    !isClass(CFDictionaryGetValue(query, kClass)))
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive())
		return serviceItemCall(CFSTR("item.copy"), query, NULL, result);
#endif
	Search s;
	OSStatus err = searchInit(&s, query, false);
	if (err) {
		searchFree(&s);
		return err;
	}
	/* Apple's file keychains don't return the data of more than one item. */
	if (s.limit != 1 && truthy(CFDictionaryGetValue(query, kSecReturnData))) {
		searchFree(&s);
		return errSecParam;
	}
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, false, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		if (result) {
			CFTypeRef r = resultFor(query, kc, item);
			if (r) {
				CFArrayAppendValue(out, r);
				CFRelease(r);
			}
		}
		return 0;
	});
	bool one = s.limit == 1;
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	if (!err && result) {
		if (one)
			*result = CFArrayGetCount(out) ? CFRetain(CFArrayGetValueAtIndex(out, 0)) : NULL;
		else
			*result = CFRetain(out);
	}
	CFRelease(out);
	return err;
}

static CFAbsoluteTime now(void)
{
	return CFAbsoluteTimeGetCurrent();
}

/* Adds a prepared item (class, attributes, v_Data) to a keychain. */
static OSStatus addItem(SecKeychainRef kc, CFMutableDictionaryRef item, CFDictionaryRef query, CFTypeRef *result,
    SecKeychainItemRef *itemRef)
{
	Store st;
	OSStatus err = storeOpen(kc, true, &st);
	if (err)
		return err;
	if (duplicate(&st, item, 0)) {
		storeClose(&st);
		return errSecDuplicateItem;
	}
	int64_t id = nextID(&st);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
	CFDictionarySetValue(item, kID, n);
	CFRelease(n);
	CFDateRef date = CFDateCreate(NULL, now());
	if (!CFDictionaryGetValue(item, CFSTR("cdat")))
		CFDictionarySetValue(item, CFSTR("cdat"), date);
	CFDictionarySetValue(item, CFSTR("mdat"), date);
	CFRelease(date);
	CFArrayAppendValue(st.items, item);
	st.dirty = true;
	err = storeClose(&st);
	if (err)
		return err;
	if (result && query)
		*result = resultFor(query, kc, item);
	CFTypeRef ref = refFor(kc, item);
	if (itemRef)
		*itemRef = isType(ref, SecKeychainItemGetTypeID()) ? (SecKeychainItemRef)CFRetain(ref) : NULL;
	notify(kSecAddEvent, kc, isType(ref, SecKeychainItemGetTypeID()) ? (SecKeychainItemRef)ref : NULL);
	if (ref)
		CFRelease(ref);
	return 0;
}

static void copyAttributes(CFMutableDictionaryRef item, CFDictionaryRef attrs)
{
	CFIndex n = CFDictionaryGetCount(attrs);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(attrs, keys, values);
	for (CFIndex i = 0; i < n; i++) {
		if (CFEqual(keys[i], kSecValueData))
			CFDictionarySetValue(item, keys[i], values[i]);
		else if (isAttributeKey(keys[i]) && !CFEqual(keys[i], kSecAttrAccess) &&
		    !CFEqual(keys[i], kSecAttrAccessControl) && !CFEqual(keys[i], kID) &&
		    !CFEqual(keys[i], CFSTR("_key"))) {
			if (CFEqual(keys[i], kSync) && CFEqual(values[i], kSecAttrSynchronizableAny))
				continue;
			CFDictionarySetValue(item, keys[i], values[i]);
		}
	}
	free(keys);
	free(values);
}

static void defaultLabel(CFMutableDictionaryRef item)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	if (CFDictionaryGetValue(item, CFSTR("labl")))
		return;
	CFTypeRef v = CFEqual(cls, kSecClassGenericPassword) ? CFDictionaryGetValue(item, CFSTR("svce"))
	    : CFEqual(cls, kSecClassInternetPassword)        ? CFDictionaryGetValue(item, CFSTR("srvr"))
	                                                     : NULL;
	if (v)
		CFDictionarySetValue(item, CFSTR("labl"), v);
}

OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
{
	if (result)
		*result = NULL;
	if (!isType(attributes, CFDictionaryGetTypeID()))
		return errSecParam;
	CFStringRef cls = CFDictionaryGetValue(attributes, kClass);
	CFTypeRef value = CFDictionaryGetValue(attributes, kSecValueRef);
	if (!cls && value) {
		cls = isType(value, SecCertificateGetTypeID()) ? kSecClassCertificate
		    : isType(value, SecKeyGetTypeID())          ? kSecClassKey
		    : isType(value, SecIdentityGetTypeID())     ? kSecClassIdentity
		                                                : NULL;
	}
	if (!isClass(cls))
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive())
		return serviceItemCall(CFSTR("item.add"), NULL, attributes, result);
#endif
	SecKeychainRef kc = NULL;
	CFTypeRef use = CFDictionaryGetValue(attributes, kSecUseKeychain);
	kc = isType(use, SecKeychainGetTypeID()) ? (SecKeychainRef)CFRetain(use) : defaultKeychain();
	if (CFEqual(cls, kSecClassIdentity)) {
		/* An identity is stored as its certificate and its private key. */
		SecCertificateRef c = NULL;
		SecKeyRef k = NULL;
		OSStatus err = isType(value, SecIdentityGetTypeID()) ? SecIdentityCopyCertificate((SecIdentityRef)value, &c) : errSecParam;
		if (!err)
			err = SecIdentityCopyPrivateKey((SecIdentityRef)value, &k);
		if (!err) {
			CFMutableDictionaryRef ci = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CFDictionarySetValue(ci, kClass, kSecClassCertificate);
			certificateAttributes(ci, c);
			err = addItem(kc, ci, NULL, NULL, NULL);
			CFRelease(ci);
			if (!err || err == errSecDuplicateItem) {
				CFMutableDictionaryRef ki = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
				CFDictionarySetValue(ki, kClass, kSecClassKey);
				keyAttributes(ki, k);
				OSStatus kerr = addItem(kc, ki, NULL, NULL, NULL);
				CFRelease(ki);
				err = err ? err : kerr;
			}
		}
		if (c)
			CFRelease(c);
		if (k)
			CFRelease(k);
		if (!err && result)
			*result = CFRetain(value);
		CFRelease(kc);
		return err;
	}
	CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(item, kClass, cls);
	copyAttributes(item, attributes);
	OSStatus err = 0;
	if (CFEqual(cls, kSecClassCertificate)) {
		SecCertificateRef c = isType(value, SecCertificateGetTypeID()) ? (SecCertificateRef)CFRetain(value)
		    : isType(CFDictionaryGetValue(attributes, kSecValueData), CFDataGetTypeID())
		    ? SecCertificateCreateWithData(NULL, CFDictionaryGetValue(attributes, kSecValueData))
		    : NULL;
		if (c) {
			certificateAttributes(item, c);
			CFRelease(c);
		} else
			err = errSecParam;
	} else if (CFEqual(cls, kSecClassKey)) {
		if (isType(value, SecKeyGetTypeID()))
			keyAttributes(item, (SecKeyRef)value);
		else if (!CFDictionaryGetValue(item, kSecValueData))
			err = errSecParam;
	} else {
		defaultLabel(item);
		if (!CFDictionaryGetValue(item, kSecValueData)) {
			CFDataRef empty = CFDataCreate(NULL, NULL, 0);
			CFDictionarySetValue(item, kSecValueData, empty);
			CFRelease(empty);
		}
	}
	if (!err)
		err = addItem(kc, item, attributes, result, NULL);
	CFRelease(item);
	CFRelease(kc);
	return err;
}

OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
{
	if (!isType(query, CFDictionaryGetTypeID()) || !isType(attributesToUpdate, CFDictionaryGetTypeID()))
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive())
		return serviceItemCall(CFSTR("item.update"), query, attributesToUpdate, NULL);
#endif
	Search s;
	OSStatus err = searchInit(&s, query, true);
	if (err) {
		searchFree(&s);
		return err;
	}
	CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, true, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		if (i == kCFNotFound)
			return errSecItemNotFound;
		/* (An identity updates its certificate.) */
		CFMutableDictionaryRef updated = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st->items, i));
		copyAttributes(updated, attributesToUpdate);
		if (duplicate(st, updated, itemID(item))) {
			CFRelease(updated);
			return errSecDuplicateItem;
		}
		CFDateRef date = CFDateCreate(NULL, now());
		CFDictionarySetValue(updated, CFSTR("mdat"), date);
		CFRelease(date);
		CFArraySetValueAtIndex(st->items, i, updated);
		st->dirty = true;
		CFTypeRef ref = refFor(kc, updated);
		if (isType(ref, SecKeychainItemGetTypeID()))
			CFArrayAppendValue(changed, ref);
		if (ref)
			CFRelease(ref);
		CFRelease(updated);
		return 0;
	});
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	for (CFIndex i = 0; !err && i < CFArrayGetCount(changed); i++) {
		Item *it = (Item *)CFArrayGetValueAtIndex(changed, i);
		notify(kSecUpdateEvent, it->keychain, (SecKeychainItemRef)it);
	}
	CFRelease(changed);
	return err;
}

OSStatus SecItemDelete(CFDictionaryRef query)
{
	if (!isType(query, CFDictionaryGetTypeID()))
		return errSecParam;
#ifndef FINCH_KEYCHAIN_SERVICE_BACKEND
	if (keychainServiceActive())
		return serviceItemCall(CFSTR("item.delete"), query, NULL, NULL);
#endif
	Search s;
	OSStatus err = searchInit(&s, query, true);
	if (err) {
		searchFree(&s);
		return err;
	}
	bool identities = s.itemClass && CFEqual(s.itemClass, kSecClassIdentity);
	CFMutableArrayRef gone = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, true, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		CFTypeRef ref = identities ? NULL : refFor(kc, item);
		if (isType(ref, SecKeychainItemGetTypeID()))
			CFArrayAppendValue(gone, ref);
		if (ref)
			CFRelease(ref);
		if (identities) {
			/* Deleting an identity deletes its certificate and key. */
			int64_t certID = itemID(item), keyID = itemID(CFDictionaryGetValue(item, CFSTR("_key")));
			CFIndex ci = findID(st, certID);
			if (ci != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, ci);
			CFIndex ki = findID(st, keyID);
			if (ki != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, ki);
		} else {
			CFIndex at = findID(st, itemID(item));
			if (at != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, at);
		}
		st->dirty = true;
		return 0;
	});
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	for (CFIndex i = 0; !err && i < CFArrayGetCount(gone); i++) {
		Item *it = (Item *)CFArrayGetValueAtIndex(gone, i);
		notify(kSecDeleteEvent, it->keychain, (SecKeychainItemRef)it);
	}
	CFRelease(gone);
	return err;
}

/* ---- The SecKeychainItem calls ---- */

static CFStringRef classForItemClass(SecItemClass c)
{
	switch (c) {
	case kSecGenericPasswordItemClass:
		return kSecClassGenericPassword;
	case kSecInternetPasswordItemClass:
		return kSecClassInternetPassword;
	case kSecCertificateItemClass:
		return kSecClassCertificate;
	case kSecPublicKeyItemClass:
	case kSecPrivateKeyItemClass:
	case kSecSymmetricKeyItemClass:
		return kSecClassKey;
	default:
		return NULL;
	}
}

static SecItemClass itemClassFor(CFDictionaryRef item)
{
	CFStringRef c = CFDictionaryGetValue(item, kClass);
	if (CFEqual(c, kSecClassGenericPassword))
		return kSecGenericPasswordItemClass;
	if (CFEqual(c, kSecClassInternetPassword))
		return kSecInternetPasswordItemClass;
	if (CFEqual(c, kSecClassCertificate))
		return kSecCertificateItemClass;
	CFTypeRef kcls = CFDictionaryGetValue(item, kSecAttrKeyClass);
	if (kcls && CFEqual(kcls, kSecAttrKeyClassPrivate))
		return kSecPrivateKeyItemClass;
	if (kcls && CFEqual(kcls, kSecAttrKeyClassSymmetric))
		return kSecSymmetricKeyItemClass;
	return kSecPublicKeyItemClass;
}

/* Legacy attribute tags are the four-character codes the keys spell. */
static CFStringRef keyForTag(UInt32 tag)
{
	char c[5] = {(char)(tag >> 24), (char)(tag >> 16), (char)(tag >> 8), (char)tag, 0};
	return CFStringCreateWithCString(NULL, c, kCFStringEncodingMacRoman);
}

enum { kNumber, kString, kDate, kFourCC, kData };
static int tagFormat(UInt32 tag)
{
	switch (tag) {
	case kSecCreationDateItemAttr:
	case kSecModDateItemAttr:
		return kDate;
	case kSecPortItemAttr:
	case kSecCreatorItemAttr:
	case kSecTypeItemAttr:
	case kSecInvisibleItemAttr:
	case kSecNegativeItemAttr:
	case kSecCustomIconItemAttr:
	case kSecScriptCodeItemAttr:
		return kNumber;
	case kSecProtocolItemAttr:
	case kSecAuthenticationTypeItemAttr:
		return kFourCC;
	case kSecGenericItemAttr:
		return kData;
	default:
		return kString;
	}
}

static CFTypeRef valueFromAttribute(const SecKeychainAttribute *a)
{
	switch (tagFormat(a->tag)) {
	case kNumber:
	case kFourCC: {
		UInt32 v = 0;
		if (a->data && a->length >= 4)
			memcpy(&v, a->data, 4);
		else if (a->data && a->length == 1)
			v = *(const UInt8 *)a->data;
		if (tagFormat(a->tag) == kFourCC)
			return keyForTag(v);
		return CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
	}
	case kDate:
		return NULL;   /* dates are the keychain's to set */
	case kData:
		return CFDataCreate(NULL, a->data, a->length);
	default:
		return CFStringCreateWithBytes(NULL, a->data, a->length, kCFStringEncodingUTF8, false);
	}
}

static void *attributeBytes(CFTypeRef v, UInt32 tag, UInt32 *length)
{
	*length = 0;
	if (!v)
		return NULL;
	if (isType(v, CFStringGetTypeID())) {
		if (tagFormat(tag) == kFourCC) {
			char c[5] = {0};
			CFStringGetCString(v, c, sizeof(c), kCFStringEncodingMacRoman);
			UInt32 code = ((UInt32)(UInt8)c[0] << 24) | ((UInt32)(UInt8)c[1] << 16) | ((UInt32)(UInt8)c[2] << 8) | (UInt8)c[3];
			UInt32 *p = malloc(4);
			*p = code;
			*length = 4;
			return p;
		}
		CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(v), kCFStringEncodingUTF8) + 1;
		char *p = malloc(max);
		CFStringGetCString(v, p, max, kCFStringEncodingUTF8);
		*length = (UInt32)strlen(p);
		return p;
	}
	if (isType(v, CFNumberGetTypeID()) || isType(v, CFBooleanGetTypeID())) {
		UInt32 *p = malloc(4);
		*p = truthy(v) && isType(v, CFBooleanGetTypeID()) ? 1 : 0;
		if (isType(v, CFNumberGetTypeID()))
			CFNumberGetValue(v, kCFNumberSInt32Type, p);
		*length = 4;
		return p;
	}
	if (isType(v, CFDataGetTypeID())) {
		*length = (UInt32)CFDataGetLength(v);
		void *p = malloc(*length ? *length : 1);
		memcpy(p, CFDataGetBytePtr(v), *length);
		return p;
	}
	if (isType(v, CFDateGetTypeID())) {
		/* "YYYYMMDDhhmmssZ" and a NUL, as CSSM's time strings. */
		CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(CFDateGetAbsoluteTime(v), NULL);
		char *p = malloc(16);
		snprintf(p, 16, "%04d%02d%02d%02d%02d%02dZ", (int)g.year, g.month, g.day, g.hour, g.minute, (int)g.second);
		*length = 16;
		return p;
	}
	return NULL;
}

/* Reads an item by reference: a copy of its stored dictionary. */
static OSStatus loadItem(SecKeychainItemRef ref, CFMutableDictionaryRef *out)
{
	*out = NULL;
	if (!isType(ref, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	if (keychainServiceActive()) {
		CFMutableDictionaryRef query = newServiceRequest();
		if (!query)
			return errSecAllocate;
		CFDictionarySetValue(query, kSecValueRef, ref);
		CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);
		CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
		CFTypeRef result = NULL;
		OSStatus status = SecItemCopyMatching(query, &result);
		CFRelease(query);
		if (!status && isType(result, CFDictionaryGetTypeID()))
			*out = CFDictionaryCreateMutableCopy(NULL, 0, result);
		else if (!status)
			status = errSecInternalComponent;
		if (result)
			CFRelease(result);
		return status;
	}
	Item *it = (Item *)ref;
	Store st;
	OSStatus err = storeOpen(it->keychain, false, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i != kCFNotFound)
		*out = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st.items, i));
	storeClose(&st);
	return *out ? 0 : errSecInvalidItemRef;
}

static OSStatus modifyItem(SecKeychainItemRef ref, const SecKeychainAttributeList *attrList, UInt32 length,
    const void *data, bool setData)
{
	if (!isType(ref, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	if (keychainServiceActive()) {
		CFMutableDictionaryRef query = newServiceRequest();
		CFMutableDictionaryRef attributes = newServiceRequest();
		if (!query || !attributes) {
			if (query) CFRelease(query);
			if (attributes) CFRelease(attributes);
			return errSecAllocate;
		}
		CFDictionarySetValue(query, kSecValueRef, ref);
		for (UInt32 a = 0; attrList && a < attrList->count; a++) {
			CFTypeRef value = valueFromAttribute(&attrList->attr[a]);
			if (!value)
				continue;
			CFStringRef key = keyForTag(attrList->attr[a].tag);
			CFDictionarySetValue(attributes, key, value);
			CFRelease(key);
			CFRelease(value);
		}
		if (setData) {
			CFDataRef value = CFDataCreate(NULL, data, length);
			if (!value) {
				CFRelease(attributes);
				CFRelease(query);
				return errSecAllocate;
			}
			CFDictionarySetValue(attributes, kSecValueData, value);
			CFRelease(value);
		}
		OSStatus status = SecItemUpdate(query, attributes);
		CFRelease(attributes);
		CFRelease(query);
		return status;
	}
	Item *it = (Item *)ref;
	Store st;
	OSStatus err = storeOpen(it->keychain, true, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i == kCFNotFound) {
		storeClose(&st);
		return errSecInvalidItemRef;
	}
	CFMutableDictionaryRef item = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st.items, i));
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(item, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	if (setData) {
		CFDataRef d = CFDataCreate(NULL, data, length);
		CFDictionarySetValue(item, kSecValueData, d);
		CFRelease(d);
	}
	if (duplicate(&st, item, it->id)) {
		CFRelease(item);
		storeClose(&st);
		return errSecDuplicateItem;
	}
	CFDateRef date = CFDateCreate(NULL, now());
	CFDictionarySetValue(item, CFSTR("mdat"), date);
	CFRelease(date);
	CFArraySetValueAtIndex(st.items, i, item);
	CFRelease(item);
	st.dirty = true;
	err = storeClose(&st);
	if (!err)
		notify(kSecUpdateEvent, it->keychain, ref);
	return err;
}

OSStatus SecKeychainItemModifyContent(SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
    UInt32 length, const void *data)
{
	return modifyItem(itemRef, attrList, length, data, data != NULL);
}

OSStatus SecKeychainItemModifyAttributesAndData(SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
    UInt32 length, const void *data)
{
	return modifyItem(itemRef, attrList, length, data, data != NULL);
}

static void *copySecret(CFDictionaryRef item, UInt32 *length)
{
	CFDataRef d = CFDictionaryGetValue(item, kSecValueData);
	*length = d ? (UInt32)CFDataGetLength(d) : 0;
	void *p = malloc(*length + 1);
	if (d)
		memcpy(p, CFDataGetBytePtr(d), *length);
	((char *)p)[*length] = 0;
	return p;
}

OSStatus SecKeychainItemCopyContent(SecKeychainItemRef itemRef, SecItemClass *itemClass,
    SecKeychainAttributeList *attrList, UInt32 *length, void **outData)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	if (itemClass)
		*itemClass = itemClassFor(item);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		attrList->attr[a].data = attributeBytes(CFDictionaryGetValue(item, key), attrList->attr[a].tag, &attrList->attr[a].length);
		CFRelease(key);
	}
	if (outData) {
		*outData = copySecret(item, length);
	} else if (length)
		*length = 0;
	CFRelease(item);
	return 0;
}

OSStatus SecKeychainItemCopyAttributesAndData(SecKeychainItemRef itemRef, SecKeychainAttributeInfo *info,
    SecItemClass *itemClass, SecKeychainAttributeList **attrList, UInt32 *length, void **outData)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	if (itemClass)
		*itemClass = itemClassFor(item);
	if (attrList) {
		UInt32 n = info ? info->count : 0;
		SecKeychainAttributeList *list = calloc(1, sizeof(*list));
		list->count = n;
		list->attr = calloc(n ? n : 1, sizeof(SecKeychainAttribute));
		for (UInt32 a = 0; a < n; a++) {
			UInt32 tag = info->tag[a];
			CFStringRef key = keyForTag(tag);
			list->attr[a].tag = tag;
			list->attr[a].data = attributeBytes(CFDictionaryGetValue(item, key), tag, &list->attr[a].length);
			CFRelease(key);
		}
		*attrList = list;
	}
	if (outData)
		*outData = copySecret(item, length);
	else if (length)
		*length = 0;
	CFRelease(item);
	return 0;
}

OSStatus SecKeychainItemFreeAttributesAndData(SecKeychainAttributeList *attrList, void *data)
{
	if (attrList) {
		for (UInt32 a = 0; a < attrList->count; a++)
			free(attrList->attr[a].data);
		free(attrList->attr);
		free(attrList);
	}
	free(data);
	return 0;
}

OSStatus SecKeychainItemFreeContent(SecKeychainAttributeList *attrList, void *data)
{
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		free(attrList->attr[a].data);
		attrList->attr[a].data = NULL;
	}
	free(data);
	return 0;
}

OSStatus SecKeychainItemCreateFromContent(SecItemClass itemClass, SecKeychainAttributeList *attrList,
    UInt32 length, const void *data, SecKeychainRef keychainRef, SecAccessRef initialAccess,
    SecKeychainItemRef *itemRef)
{
	if (itemRef)
		*itemRef = NULL;
	CFStringRef cls = classForItemClass(itemClass);
	if (!cls || cls == kSecClassCertificate || cls == kSecClassKey)
		return errSecParam;
	CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(item, kClass, cls);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(item, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	defaultLabel(item);
	CFDataRef d = CFDataCreate(NULL, data, data ? length : 0);
	CFDictionarySetValue(item, kSecValueData, d);
	CFRelease(d);
	if (keychainServiceActive()) {
		if (keychainRef)
			CFDictionarySetValue(item, kSecUseKeychain, keychainRef);
		if (itemRef)
			CFDictionarySetValue(item, kSecReturnRef, kCFBooleanTrue);
		CFTypeRef result = NULL;
		OSStatus status = SecItemAdd(item, itemRef ? &result : NULL);
		if (!status && itemRef && isType(result, SecKeychainItemGetTypeID()))
			*itemRef = (SecKeychainItemRef)result;
		else if (!status && itemRef)
			status = errSecInternalComponent;
		if (result && (status || !itemRef))
			CFRelease(result);
		CFRelease(item);
		return status;
	}
	SecKeychainRef kc = keychainRef ? (SecKeychainRef)CFRetain(keychainRef) : defaultKeychain();
	OSStatus err = isType(kc, SecKeychainGetTypeID()) ? addItem(kc, item, NULL, NULL, itemRef) : errSecInvalidKeychain;
	CFRelease(kc);
	CFRelease(item);
	return err;
}

OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	if (keychainServiceActive()) {
		CFMutableDictionaryRef query = newServiceRequest();
		if (!query)
			return errSecAllocate;
		CFDictionarySetValue(query, kSecValueRef, itemRef);
		OSStatus status = SecItemDelete(query);
		CFRelease(query);
		return status;
	}
	Item *it = (Item *)itemRef;
	Store st;
	OSStatus err = storeOpen(it->keychain, true, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i == kCFNotFound) {
		storeClose(&st);
		return errSecInvalidItemRef;
	}
	CFArrayRemoveValueAtIndex(st.items, i);
	st.dirty = true;
	err = storeClose(&st);
	if (!err)
		notify(kSecDeleteEvent, it->keychain, itemRef);
	return err;
}

OSStatus SecKeychainItemCopyKeychain(SecKeychainItemRef itemRef, SecKeychainRef *keychainRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !keychainRef)
		return errSecParam;
	*keychainRef = (SecKeychainRef)CFRetain(((Item *)itemRef)->keychain);
	return 0;
}

OSStatus SecKeychainItemCreatePersistentReference(SecKeychainItemRef itemRef, CFDataRef *persistentItemRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !persistentItemRef)
		return errSecParam;
	*persistentItemRef = persistentRef(((Item *)itemRef)->keychain, ((Item *)itemRef)->id);
	return 0;
}

OSStatus SecKeychainItemCopyFromPersistentReference(CFDataRef persistentItemRef, SecKeychainItemRef *itemRef)
{
	if (!itemRef)
		return errSecParam;
	*itemRef = NULL;
	if (!isType(persistentItemRef, CFDataGetTypeID()))
		return errSecItemNotFound;
	if (keychainServiceActive()) {
		CFMutableDictionaryRef query = newServiceRequest();
		if (!query)
			return errSecAllocate;
		CFDictionarySetValue(query, kSecValuePersistentRef, persistentItemRef);
		CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
		CFTypeRef result = NULL;
		OSStatus status = SecItemCopyMatching(query, &result);
		CFRelease(query);
		if (!status && isType(result, SecKeychainItemGetTypeID()))
			*itemRef = (SecKeychainItemRef)result;
		else if (!status)
			status = errSecInternalComponent;
		if (result && (status || !*itemRef))
			CFRelease(result);
		return status;
	}
	SecKeychainRef kc = NULL;
	int64_t id = 0;
	if (!parsePersistentRef(persistentItemRef, &kc, &id))
		return errSecItemNotFound;
	Store st;
	OSStatus err = storeOpen(kc, false, &st);
	if (!err) {
		CFIndex i = findID(&st, id);
		*itemRef = i == kCFNotFound ? NULL : (SecKeychainItemRef)refFor(kc, CFArrayGetValueAtIndex(st.items, i));
		storeClose(&st);
		err = *itemRef ? 0 : errSecItemNotFound;
	}
	CFRelease(kc);
	return err;
}

OSStatus SecKeychainItemCreateCopy(SecKeychainItemRef itemRef, SecKeychainRef destKeychainRef,
    SecAccessRef initialAccess, SecKeychainItemRef *itemCopy)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	if (keychainServiceActive()) {
		CFDictionaryRemoveValue(item, kID);
		CFDictionaryRemoveValue(item, CFSTR("cdat"));
		CFDictionaryRemoveValue(item, CFSTR("mdat"));
		if (destKeychainRef)
			CFDictionarySetValue(item, kSecUseKeychain, destKeychainRef);
		if (itemCopy)
			CFDictionarySetValue(item, kSecReturnRef, kCFBooleanTrue);
		CFTypeRef result = NULL;
		err = SecItemAdd(item, itemCopy ? &result : NULL);
		if (!err && itemCopy && isType(result, SecKeychainItemGetTypeID()))
			*itemCopy = (SecKeychainItemRef)result;
		else if (!err && itemCopy)
			err = errSecInternalComponent;
		if (result && (err || !itemCopy))
			CFRelease(result);
		CFRelease(item);
		return err;
	}
	CFDictionaryRemoveValue(item, kID);
	CFDictionaryRemoveValue(item, CFSTR("cdat"));
	SecKeychainRef kc = destKeychainRef ? (SecKeychainRef)CFRetain(destKeychainRef) : defaultKeychain();
	err = addItem(kc, item, NULL, NULL, itemCopy);
	CFRelease(kc);
	CFRelease(item);
	return err;
}

OSStatus SecKeychainItemCopyAccess(SecKeychainItemRef itemRef, SecAccessRef *access)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !access)
		return errSecParam;
	return SecAccessCreate(CFSTR(""), NULL, access);
}

OSStatus SecKeychainItemSetAccess(SecKeychainItemRef itemRef, SecAccessRef access)
{
	return isType(itemRef, SecKeychainItemGetTypeID()) ? 0 : errSecParam;
}

/* ---- Passwords by name ---- */

static OSStatus findPassword(CFTypeRef keychainOrArray, CFMutableDictionaryRef query, UInt32 *length,
    void **data, SecKeychainItemRef *itemRef)
{
	if (length)
		*length = 0;
	if (data)
		*data = NULL;
	if (itemRef)
		*itemRef = NULL;
	if (keychainOrArray) {
		if (isType(keychainOrArray, CFArrayGetTypeID()))
			CFDictionarySetValue(query, kSecMatchSearchList, keychainOrArray);
		else if (isType(keychainOrArray, SecKeychainGetTypeID())) {
			CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
			CFDictionarySetValue(query, kSecMatchSearchList, a);
			CFRelease(a);
		} else
			return errSecParam;
	}
	CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
	CFTypeRef ref = NULL;
	OSStatus err = SecItemCopyMatching(query, &ref);
	if (err)
		return err;
	if (data) {
		CFMutableDictionaryRef item;
		err = loadItem((SecKeychainItemRef)ref, &item);
		if (!err) {
			*data = copySecret(item, length);
			CFRelease(item);
		}
	}
	if (!err && itemRef)
		*itemRef = (SecKeychainItemRef)CFRetain(ref);
	CFRelease(ref);
	return err;
}

static void setBytes(CFMutableDictionaryRef d, CFStringRef key, UInt32 len, const char *bytes)
{
	if (!bytes || !len)
		return;
	CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)bytes, len, kCFStringEncodingUTF8, false);
	if (s) {
		CFDictionarySetValue(d, key, s);
		CFRelease(s);
	}
}

OSStatus SecKeychainFindGenericPassword(CFTypeRef keychainOrArray, UInt32 serviceNameLength,
    const char *serviceName, UInt32 accountNameLength, const char *accountName, UInt32 *passwordLength,
    void **passwordData, SecKeychainItemRef *itemRef)
{
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassGenericPassword);
	setBytes(q, kSecAttrService, serviceNameLength, serviceName);
	setBytes(q, kSecAttrAccount, accountNameLength, accountName);
	OSStatus err = findPassword(keychainOrArray, q, passwordLength, passwordData, itemRef);
	CFRelease(q);
	return err;
}

OSStatus SecKeychainAddGenericPassword(SecKeychainRef keychain, UInt32 serviceNameLength, const char *serviceName,
    UInt32 accountNameLength, const char *accountName, UInt32 passwordLength, const void *passwordData,
    SecKeychainItemRef *itemRef)
{
	SecKeychainAttribute attrs[] = {
	    {kSecServiceItemAttr, serviceNameLength, (void *)serviceName},
	    {kSecAccountItemAttr, accountNameLength, (void *)accountName},
	};
	SecKeychainAttributeList list = {2, attrs};
	return SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass, &list, passwordLength, passwordData,
	    keychain, NULL, itemRef);
}

static void setFourCC(CFMutableDictionaryRef d, CFStringRef key, UInt32 code)
{
	if (!code)
		return;
	CFStringRef s = keyForTag(code);
	CFDictionarySetValue(d, key, s);
	CFRelease(s);
}

OSStatus SecKeychainFindInternetPassword(CFTypeRef keychainOrArray, UInt32 serverNameLength, const char *serverName,
    UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength, const char *accountName,
    UInt32 pathLength, const char *path, UInt16 port, SecProtocolType protocol, SecAuthenticationType authenticationType,
    UInt32 *passwordLength, void **passwordData, SecKeychainItemRef *itemRef)
{
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassInternetPassword);
	setBytes(q, kSecAttrServer, serverNameLength, serverName);
	setBytes(q, kSecAttrSecurityDomain, securityDomainLength, securityDomain);
	setBytes(q, kSecAttrAccount, accountNameLength, accountName);
	setBytes(q, kSecAttrPath, pathLength, path);
	if (port) {
		int p = port;
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &p);
		CFDictionarySetValue(q, kSecAttrPort, n);
		CFRelease(n);
	}
	setFourCC(q, kSecAttrProtocol, protocol);
	if (authenticationType != kSecAuthenticationTypeAny)
		setFourCC(q, kSecAttrAuthenticationType, authenticationType);
	OSStatus err = findPassword(keychainOrArray, q, passwordLength, passwordData, itemRef);
	CFRelease(q);
	return err;
}

OSStatus SecKeychainAddInternetPassword(SecKeychainRef keychain, UInt32 serverNameLength, const char *serverName,
    UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength, const char *accountName,
    UInt32 pathLength, const char *path, UInt16 port, SecProtocolType protocol, SecAuthenticationType authenticationType,
    UInt32 passwordLength, const void *passwordData, SecKeychainItemRef *itemRef)
{
	UInt32 p32 = port;
	SecKeychainAttribute attrs[8];
	UInt32 n = 0;
	attrs[n++] = (SecKeychainAttribute){kSecServerItemAttr, serverNameLength, (void *)serverName};
	if (securityDomainLength)
		attrs[n++] = (SecKeychainAttribute){kSecSecurityDomainItemAttr, securityDomainLength, (void *)securityDomain};
	attrs[n++] = (SecKeychainAttribute){kSecAccountItemAttr, accountNameLength, (void *)accountName};
	if (pathLength)
		attrs[n++] = (SecKeychainAttribute){kSecPathItemAttr, pathLength, (void *)path};
	if (port)
		attrs[n++] = (SecKeychainAttribute){kSecPortItemAttr, 4, &p32};
	if (protocol)
		attrs[n++] = (SecKeychainAttribute){kSecProtocolItemAttr, 4, &protocol};
	if (authenticationType)
		attrs[n++] = (SecKeychainAttribute){kSecAuthenticationTypeItemAttr, 4, &authenticationType};
	SecKeychainAttributeList list = {n, attrs};
	return SecKeychainItemCreateFromContent(kSecInternetPasswordItemClass, &list, passwordLength, passwordData,
	    keychain, NULL, itemRef);
}

/* ---- Searches (deprecated API) ---- */

typedef struct {
	CFRuntimeBase base;
	CFArrayRef results;
	CFIndex next;
} KCSearch;
static void searchObjFree(CFTypeRef o)
{
	if (((KCSearch *)o)->results)
		CFRelease(((KCSearch *)o)->results);
}
SEC_DEFINE_TYPE(SecKeychainSearchGetTypeID, "SecKeychainSearch", searchObjFree, NULL, NULL)

OSStatus SecKeychainSearchCreateFromAttributes(CFTypeRef keychainOrArray, SecItemClass itemClass,
    const SecKeychainAttributeList *attrList, SecKeychainSearchRef *searchRef)
{
	if (!searchRef)
		return errSecParam;
	CFStringRef cls = classForItemClass(itemClass);
	if (!cls)
		return errSecParam;
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, cls);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitAll);
	CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(q, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	if (isType(keychainOrArray, SecKeychainGetTypeID())) {
		CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(q, kSecMatchSearchList, a);
		CFRelease(a);
	} else if (isType(keychainOrArray, CFArrayGetTypeID()))
		CFDictionarySetValue(q, kSecMatchSearchList, keychainOrArray);
	CFTypeRef results = NULL;
	SecItemCopyMatching(q, &results);
	CFRelease(q);
	KCSearch *s = (KCSearch *)_SecCreateInstance(SecKeychainSearchGetTypeID(), sizeof(*s));
	s->results = results;
	*searchRef = (SecKeychainSearchRef)s;
	return 0;
}

OSStatus SecKeychainSearchCopyNext(SecKeychainSearchRef searchRef, SecKeychainItemRef *itemRef)
{
	if (!isType(searchRef, SecKeychainSearchGetTypeID()) || !itemRef)
		return errSecParam;
	KCSearch *s = (KCSearch *)searchRef;
	if (!s->results || s->next >= CFArrayGetCount(s->results))
		return errSecItemNotFound;
	*itemRef = (SecKeychainItemRef)CFRetain(CFArrayGetValueAtIndex(s->results, s->next++));
	return 0;
}

/* ---- Identities ---- */

typedef struct {
	CFRuntimeBase base;
	SecCertificateRef certificate;
	SecKeyRef key;
} Identity;
static void identityFree(CFTypeRef o)
{
	CFRelease(((Identity *)o)->certificate);
	CFRelease(((Identity *)o)->key);
}
static Boolean identityEqual(CFTypeRef a, CFTypeRef b)
{
	return CFEqual(((Identity *)a)->certificate, ((Identity *)b)->certificate) &&
	    CFEqual(((Identity *)a)->key, ((Identity *)b)->key);
}
static CFHashCode identityHash(CFTypeRef a)
{
	return CFHash(((Identity *)a)->certificate);
}
SEC_DEFINE_TYPE(SecIdentityGetTypeID, "SecIdentity", identityFree, identityEqual, identityHash)

SecIdentityRef _SecIdentityCreate(SecCertificateRef cert, SecKeyRef key)
{
	Identity *i = (Identity *)_SecCreateInstance(SecIdentityGetTypeID(), sizeof(*i));
	i->certificate = (SecCertificateRef)CFRetain(cert);
	i->key = (SecKeyRef)CFRetain(key);
	return (SecIdentityRef)i;
}

SecIdentityRef SecIdentityCreate(CFAllocatorRef allocator, SecCertificateRef certificate, SecKeyRef privateKey)
{
	if (!isType(certificate, SecCertificateGetTypeID()) || !isType(privateKey, SecKeyGetTypeID()))
		return NULL;
	return _SecIdentityCreate(certificate, privateKey);
}

OSStatus SecIdentityCreateWithCertificate(CFTypeRef keychainOrArray, SecCertificateRef certificateRef,
    SecIdentityRef *identityRef)
{
	if (!isType(certificateRef, SecCertificateGetTypeID()) || !identityRef)
		return errSecParam;
	*identityRef = NULL;
	CFDataRef label = _SecCertificateCopyPublicKeySHA1(certificateRef);
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassKey);
	CFDictionarySetValue(q, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
	if (label) {
		CFDictionarySetValue(q, kSecAttrApplicationLabel, label);
		CFRelease(label);
	}
	CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
	if (isType(keychainOrArray, CFArrayGetTypeID()))
		CFDictionarySetValue(q, kSecMatchSearchList, keychainOrArray);
	else if (isType(keychainOrArray, SecKeychainGetTypeID())) {
		CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(q, kSecMatchSearchList, a);
		CFRelease(a);
	}
	CFTypeRef key = NULL;
	OSStatus err = SecItemCopyMatching(q, &key);
	CFRelease(q);
	if (!err) {
		*identityRef = _SecIdentityCreate(certificateRef, (SecKeyRef)key);
		CFRelease(key);
	}
	return err;
}

OSStatus SecIdentityCopyCertificate(SecIdentityRef identityRef, SecCertificateRef *certificateRef)
{
	if (!isType(identityRef, SecIdentityGetTypeID()) || !certificateRef)
		return errSecParam;
	*certificateRef = (SecCertificateRef)CFRetain(((Identity *)identityRef)->certificate);
	return 0;
}

OSStatus SecIdentityCopyPrivateKey(SecIdentityRef identityRef, SecKeyRef *privateKeyRef)
{
	if (!isType(identityRef, SecIdentityGetTypeID()) || !privateKeyRef)
		return errSecParam;
	*privateKeyRef = (SecKeyRef)CFRetain(((Identity *)identityRef)->key);
	return 0;
}

SecIdentityRef SecIdentityCopyPreferred(CFStringRef name, CFArrayRef keyUsage, CFArrayRef validIssuers)
{
	return NULL;
}

OSStatus SecIdentityCopySystemIdentity(CFStringRef domain, SecIdentityRef *idRef, CFStringRef *actualDomain)
{
	if (idRef)
		*idRef = NULL;
	return errSecItemNotFound;
}

/* A keychain's lock settings (lock on sleep, after an interval): kept per keychain in
   the process. Finch's keychains don't lock themselves yet, so the settings change nothing. */
static CFMutableDictionaryRef keychain_settings;

OSStatus SecKeychainSetSettings(SecKeychainRef keychain, const SecKeychainSettings *newSettings)
{
	if (!newSettings || newSettings->version != SEC_KEYCHAIN_SETTINGS_VERS1)
		return errSecParam;
	if (!keychain_settings)
		keychain_settings = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
	CFDataRef d = CFDataCreate(NULL, (const UInt8 *)newSettings, sizeof *newSettings);
	CFDictionarySetValue(keychain_settings, keychain, d);
	CFRelease(d);
	return errSecSuccess;
}

OSStatus SecKeychainCopySettings(SecKeychainRef keychain, SecKeychainSettings *outSettings)
{
	if (!outSettings || outSettings->version != SEC_KEYCHAIN_SETTINGS_VERS1)
		return errSecParam;
	CFDataRef d = keychain_settings ? CFDictionaryGetValue(keychain_settings, keychain) : NULL;
	if (d)
		memcpy(outSettings, CFDataGetBytePtr(d), sizeof *outSettings);
	else {
		outSettings->lockOnSleep = false;
		outSettings->useLockInterval = false;
		outSettings->lockInterval = INT_MAX;
	}
	return errSecSuccess;
}

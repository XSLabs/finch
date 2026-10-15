/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SCPreferences sessions read through configd when it is available and keep
 * local edits until the daemon commits them. System preferences are writable
 * only by a root connection. If configd is absent, reads can still use the
 * readable file, but writes fail with kSCStatusNoStoreServer.
 *
 * A preferences file of the caller's own, an absolute path outside the system
 * folder, is read in the process and, by root, locked (PATH.lock, flock'd, as
 * configd does) and written (atomically, by renaming) there too, as Apple's
 * are; anyone else's lock is refused (kSCStatusAccessError), as Apple's is
 * without an authorization. A commit without the lock takes it for the commit,
 * as with Apple's.
 */
#include "SCFinch.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define kSystemPrefsDir "/Library/Preferences/SystemConfiguration"
#define kSystemPrefs kSystemPrefsDir "/preferences.plist"

static CFMutableDictionaryRef readPlist(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return NULL;
	struct stat st;
	CFMutableDictionaryRef out = NULL;
	if (fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < 64 * 1024 * 1024) {
		CFMutableDataRef d = CFDataCreateMutable(NULL, st.st_size);
		CFDataSetLength(d, st.st_size);
		if (pread(fd, CFDataGetMutableBytePtr(d), st.st_size, 0) == st.st_size) {
			CFPropertyListRef p = CFPropertyListCreateWithData(NULL, d, kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
			if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
				out = (CFMutableDictionaryRef)p;
			else if (p)
				CFRelease(p);
		}
		CFRelease(d);
	}
	close(fd);
	return out;
}

CFDictionaryRef _SCCopySystemPreferences(void)
{
	return readPlist(kSystemPrefs);
}

/* ---- Sessions ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef name, prefsID;
	char path[PATH_MAX];
	xpc_connection_t connection;
	CFMutableDictionaryRef prefs;   /* NULL until read */
	CFDataRef signature;            /* of the file as read */
	bool changed, locked;
	SCPreferencesCallBack callout;
	SCPreferencesContext context;
	dispatch_queue_t queue;
	CFRunLoopRef runLoop;
	CFStringRef runLoopMode;
	dispatch_source_t watcher;
	bool local;                     /* the caller's own file, handled here */
	int lockFD;                     /* a local session's lock */
} Prefs;

static void prefsFree(CFTypeRef o)
{
	Prefs *p = (Prefs *)o;
	if (p->local && p->lockFD >= 0)
		close(p->lockFD);
	if (p->watcher) {
		dispatch_source_cancel(p->watcher);
		dispatch_release(p->watcher);
	}
	if (p->queue)
		dispatch_release(p->queue);
	if (p->connection) {
		xpc_connection_cancel(p->connection);
		xpc_release(p->connection);
	}
	if (p->context.release && p->context.info)
		p->context.release(p->context.info);
	CFTypeRef refs[] = {p->name, p->prefsID, p->prefs, p->signature, p->runLoop, p->runLoopMode};
	for (size_t i = 0; i < sizeof(refs) / sizeof(*refs); i++)
		if (refs[i])
			CFRelease(refs[i]);
}

static CFStringRef prefsDescription(CFTypeRef o)
{
	Prefs *p = (Prefs *)o;
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCPreferences %p> { name = %@, path = %s }"), o, p->name, p->path);
}

SC_DEFINE_TYPE(SCPreferencesGetTypeID, "SCPreferences", prefsFree, NULL, NULL, prefsDescription)

static CFDataRef signatureOf(const char *path)
{
	struct {
		uint64_t dev, ino, size;
		int64_t sec, nsec;
	} sig = {0};
	struct stat st;
	if (stat(path, &st) == 0) {
		sig.dev = st.st_dev;
		sig.ino = st.st_ino;
		sig.size = st.st_size;
		sig.sec = st.st_mtimespec.tv_sec;
		sig.nsec = st.st_mtimespec.tv_nsec;
	}
	return CFDataCreate(NULL, (const UInt8 *)&sig, sizeof(sig));
}

static CFMutableDictionaryRef access_(Prefs *p)
{
	if (!p->prefs && p->local) {
		p->prefs = readPlist(p->path);
		if (!p->prefs)
			p->prefs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (p->signature)
			CFRelease(p->signature);
		p->signature = signatureOf(p->path);
		p->changed = false;
	}
	if (!p->prefs) {
		xpc_object_t request = _SCConfigdCreateRequest("prefs.read");
		int status = kSCStatusNoStoreServer;
		xpc_object_t reply = NULL;
		if (request) {
			xpc_dictionary_set_string(request, "path", p->path);
			reply = _SCConfigdSendRequest(p->connection, request, &status);
			xpc_release(request);
		}
		CFPropertyListRef remote = status == kSCStatusOK ?
		    _SCConfigdCopyPropertyList(reply, "plist") : NULL;
		if (remote && CFGetTypeID(remote) == CFDictionaryGetTypeID())
			p->prefs = (CFMutableDictionaryRef)remote;
		else if (remote)
			CFRelease(remote);
		if (reply) {
			xpc_object_t signature = xpc_dictionary_get_value(reply, "signature");
			if (signature && xpc_get_type(signature) == XPC_TYPE_DATA)
				p->signature = CFDataCreate(NULL, xpc_data_get_bytes_ptr(signature),
				    (CFIndex)xpc_data_get_length(signature));
			xpc_release(reply);
		}
		if (!p->prefs)
			p->prefs = readPlist(p->path);
		if (!p->prefs)
			p->prefs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (!p->signature)
			p->signature = signatureOf(p->path);
		p->changed = false;
	}
	return p->prefs;
}

SCPreferencesRef SCPreferencesCreateWithOptions(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID,
    AuthorizationRef authorization, CFDictionaryRef options)
{
	if (!name || CFGetTypeID(name) != CFStringGetTypeID() || (prefsID && CFGetTypeID(prefsID) != CFStringGetTypeID())) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Prefs *p = (Prefs *)_SCCreateInstance(SCPreferencesGetTypeID(), sizeof(*p));
	p->name = CFStringCreateCopy(NULL, name);
	p->connection = _SCConfigdCreateConnection(NULL);
	char id[PATH_MAX] = "";
	if (prefsID) {
		p->prefsID = CFStringCreateCopy(NULL, prefsID);
		CFStringGetFileSystemRepresentation(prefsID, id, sizeof(id));
	}
	if (!id[0])
		strlcpy(p->path, kSystemPrefs, sizeof(p->path));
	else if (id[0] == '/')
		strlcpy(p->path, id, sizeof(p->path));
	else
		snprintf(p->path, sizeof(p->path), "%s/%s", kSystemPrefsDir, id);
	p->local = strncmp(p->path, kSystemPrefsDir "/", sizeof(kSystemPrefsDir "/") - 1) != 0;
	p->lockFD = -1;
	_SCErrorSet(kSCStatusOK);
	return (SCPreferencesRef)p;
}

SCPreferencesRef SCPreferencesCreate(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID)
{
	return SCPreferencesCreateWithOptions(allocator, name, prefsID, NULL, NULL);
}

SCPreferencesRef SCPreferencesCreateWithAuthorization(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID,
    AuthorizationRef authorization)
{
	return SCPreferencesCreateWithOptions(allocator, name, prefsID, authorization, NULL);
}

static Prefs *valid(SCPreferencesRef ref)
{
	if (ref && CFGetTypeID(ref) == SCPreferencesGetTypeID())
		return (Prefs *)ref;
	_SCErrorSet(kSCStatusNoPrefsSession);
	return NULL;
}

CFArrayRef SCPreferencesCopyKeyList(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	CFDictionaryRef d = access_(p);
	CFIndex n = CFDictionaryGetCount(d);
	const void **keys = malloc(sizeof(void *) * (n ? n : 1));
	CFDictionaryGetKeysAndValues(d, keys, NULL);
	CFArrayRef a = CFArrayCreate(NULL, keys, n, &kCFTypeArrayCallBacks);
	free(keys);
	_SCErrorSet(kSCStatusOK);
	return a;
}

CFPropertyListRef SCPreferencesGetValue(SCPreferencesRef ref, CFStringRef key)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	CFPropertyListRef v = key ? CFDictionaryGetValue(access_(p), key) : NULL;
	_SCErrorSet(v ? kSCStatusOK : kSCStatusNoKey);
	return v;
}

Boolean SCPreferencesSetValue(SCPreferencesRef ref, CFStringRef key, CFPropertyListRef value)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!key || !value) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFDictionarySetValue(access_(p), key, value);
	p->changed = true;
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesAddValue(SCPreferencesRef ref, CFStringRef key, CFPropertyListRef value)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (key && CFDictionaryGetValue(access_(p), key)) {
		_SCErrorSet(kSCStatusKeyExists);
		return false;
	}
	return SCPreferencesSetValue(ref, key, value);
}

Boolean SCPreferencesRemoveValue(SCPreferencesRef ref, CFStringRef key)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!key || !CFDictionaryGetValue(access_(p), key)) {
		_SCErrorSet(kSCStatusNoKey);
		return false;
	}
	CFDictionaryRemoveValue(p->prefs, key);
	p->changed = true;
	_SCErrorSet(kSCStatusOK);
	return true;
}

CFDataRef SCPreferencesGetSignature(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	access_(p);
	_SCErrorSet(kSCStatusOK);
	return p->signature;
}

void SCPreferencesSynchronize(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return;
	if (p->prefs)
		CFRelease(p->prefs);
	p->prefs = NULL;
	p->changed = false;
	_SCErrorSet(kSCStatusOK);
}

static int statusForErrno(int err)
{
	return err == EACCES || err == EPERM || err == EROFS ? kSCStatusAccessError : kSCStatusFailed;
}

static bool sameSignature(Prefs *p)
{
	CFDataRef now = signatureOf(p->path);
	bool same = p->signature && CFEqual(now, p->signature);
	CFRelease(now);
	return same;
}

static int localLock(Prefs *p, bool wait)
{
	if (geteuid() != 0)
		return kSCStatusAccessError;
	char lockPath[PATH_MAX];
	if ((size_t)snprintf(lockPath, sizeof(lockPath), "%s.lock", p->path) >= sizeof(lockPath))
		return kSCStatusInvalidArgument;
	int fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return statusForErrno(errno);
	if (flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) < 0) {
		int err = errno;
		close(fd);
		return err == EWOULDBLOCK || err == EAGAIN ? kSCStatusPrefsBusy : kSCStatusFailed;
	}
	if (!sameSignature(p)) {
		close(fd);
		return kSCStatusStale;
	}
	p->lockFD = fd;
	return kSCStatusOK;
}

static void localUnlock(Prefs *p)
{
	if (p->lockFD >= 0) {
		(void)flock(p->lockFD, LOCK_UN);
		close(p->lockFD);
	}
	p->lockFD = -1;
}

/* The file replaced by a new one, renamed into place, with the old one's mode. */
static int localWrite(Prefs *p)
{
	CFDataRef bytes = CFPropertyListCreateData(NULL, p->prefs, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	if (!bytes)
		return kSCStatusInvalidArgument;
	char temp[PATH_MAX];
	snprintf(temp, sizeof(temp), "%s.XXXXXX", p->path);
	int fd = mkstemp(temp);
	if (fd < 0) {
		CFRelease(bytes);
		return statusForErrno(errno);
	}
	struct stat st;
	mode_t mode = stat(p->path, &st) == 0 ? (st.st_mode & 0777) : 0644;
	const UInt8 *b = CFDataGetBytePtr(bytes);
	size_t left = (size_t)CFDataGetLength(bytes);
	bool ok = fchmod(fd, mode) == 0;
	while (ok && left) {
		ssize_t n = write(fd, b, left);
		if (n < 0 && errno == EINTR)
			continue;
		ok = n > 0;
		if (ok)
			b += n, left -= (size_t)n;
	}
	ok = ok && fsync(fd) == 0;
	int err = errno;
	ok = close(fd) == 0 && ok;
	ok = ok && rename(temp, p->path) == 0;
	if (!ok) {
		err = errno ? errno : err;
		unlink(temp);
	}
	CFRelease(bytes);
	return ok ? kSCStatusOK : statusForErrno(err);
}

Boolean SCPreferencesLock(SCPreferencesRef ref, Boolean wait)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (p->locked) {
		_SCErrorSet(kSCStatusLocked);
		return false;
	}
	access_(p);
	if (p->signature == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	if (p->local) {
		int status = localLock(p, wait);
		p->locked = status == kSCStatusOK;
		_SCErrorSet(status);
		return p->locked;
	}
	xpc_object_t request = _SCConfigdCreateRequest("prefs.lock");
	if (request == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	xpc_dictionary_set_string(request, "path", p->path);
	xpc_dictionary_set_bool(request, "wait", wait);
	xpc_dictionary_set_data(request, "signature", CFDataGetBytePtr(p->signature),
	    (size_t)CFDataGetLength(p->signature));
	int status = kSCStatusNoStoreServer;
	xpc_object_t reply = _SCConfigdSendRequest(p->connection, request, &status);
	if (reply)
		xpc_release(reply);
	xpc_release(request);
	if (status != kSCStatusOK) {
		_SCErrorSet(status);
		return false;
	}
	p->locked = true;
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesUnlock(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!p->locked) {
		_SCErrorSet(kSCStatusNeedLock);
		return false;
	}
	if (p->local) {
		localUnlock(p);
		p->locked = false;
		_SCErrorSet(kSCStatusOK);
		return true;
	}
	xpc_object_t request = _SCConfigdCreateRequest("prefs.unlock");
	if (request == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	xpc_dictionary_set_string(request, "path", p->path);
	int status = kSCStatusNoStoreServer;
	xpc_object_t reply = _SCConfigdSendRequest(p->connection, request, &status);
	if (reply)
		xpc_release(reply);
	xpc_release(request);
	if (status != kSCStatusOK) {
		_SCErrorSet(status);
		return false;
	}
	p->locked = false;
	_SCErrorSet(kSCStatusOK);
	return true;
}

static Boolean commit(Prefs *p);

Boolean SCPreferencesCommitChanges(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!p->changed) {
		_SCErrorSet(kSCStatusOK);
		return true;
	}
	if (p->signature == NULL || p->prefs == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	if (p->locked)
		return commit(p);
	/* (locked for the commit alone) */
	if (!SCPreferencesLock(ref, true))
		return false;
	Boolean ok = commit(p);
	int status = SCError();
	SCPreferencesUnlock(ref);
	_SCErrorSet(status);
	return ok;
}

static Boolean commit(Prefs *p)
{
	if (p->local) {
		int status = sameSignature(p) ? localWrite(p) : kSCStatusStale;
		if (status == kSCStatusOK) {
			CFRelease(p->signature);
			p->signature = signatureOf(p->path);
			p->changed = false;
		}
		_SCErrorSet(status);
		return status == kSCStatusOK;
	}
	xpc_object_t request = _SCConfigdCreateRequest("prefs.commit");
	bool encoded = request != NULL;
	if (encoded) {
		xpc_dictionary_set_string(request, "path", p->path);
		xpc_dictionary_set_data(request, "signature", CFDataGetBytePtr(p->signature),
		    (size_t)CFDataGetLength(p->signature));
		encoded = _SCConfigdSetPropertyList(request, "plist", p->prefs);
	}
	int status = encoded ? kSCStatusNoStoreServer :
	    (request ? kSCStatusInvalidArgument : kSCStatusFailed);
	xpc_object_t reply = encoded ?
	    _SCConfigdSendRequest(p->connection, request, &status) : NULL;
	if (reply && status == kSCStatusOK) {
		xpc_object_t signature = xpc_dictionary_get_value(reply, "signature");
		if (signature && xpc_get_type(signature) == XPC_TYPE_DATA) {
			CFDataRef updated = CFDataCreate(NULL, xpc_data_get_bytes_ptr(signature),
			    (CFIndex)xpc_data_get_length(signature));
			if (updated) {
				CFRelease(p->signature);
				p->signature = updated;
			}
		} else {
			CFRelease(p->signature);
			p->signature = signatureOf(p->path);
		}
		p->changed = false;
	}
	if (reply)
		xpc_release(reply);
	if (request)
		xpc_release(request);
	if (status != kSCStatusOK) {
		_SCErrorSet(status);
		return false;
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesApplyChanges(SCPreferencesRef ref)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (p->changed) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	if (p->local) {
		/* (nothing to apply a file of the caller's own to) */
		_SCErrorSet(kSCStatusOK);
		return true;
	}
	xpc_object_t request = _SCConfigdCreateRequest("prefs.apply");
	if (request == NULL) {
		_SCErrorSet(kSCStatusFailed);
		return false;
	}
	xpc_dictionary_set_string(request, "path", p->path);
	int status = kSCStatusNoStoreServer;
	xpc_object_t reply = _SCConfigdSendRequest(p->connection, request, &status);
	if (reply)
		xpc_release(reply);
	xpc_release(request);
	_SCErrorSet(status);
	return status == kSCStatusOK;
}

/* ---- Callbacks: the file changing on disk ---- */

static void fire(Prefs *p, SCPreferencesNotification what)
{
	SCPreferencesCallBack fn = p->callout;
	if (!fn)
		return;
	CFRetain(p);
	void (^call)(void) = ^{
		fn((SCPreferencesRef)p, what, p->context.info);
		CFRelease(p);
	};
	if (p->queue)
		dispatch_async(p->queue, call);
	else if (p->runLoop) {
		CFRunLoopPerformBlock(p->runLoop, p->runLoopMode, call);
		CFRunLoopWakeUp(p->runLoop);
	} else
		CFRelease(p);
}

static void stopWatching(Prefs *p)
{
	if (p->watcher) {
		dispatch_source_cancel(p->watcher);
		dispatch_release(p->watcher);
		p->watcher = NULL;
	}
}

static void startWatching(Prefs *p)
{
	stopWatching(p);
	/* Watch the directory: commits replace the file. */
	char dir[PATH_MAX];
	strlcpy(dir, p->path, sizeof(dir));
	char *slash = strrchr(dir, '/');
	if (slash && slash != dir)
		*slash = 0;
	int fd = open(dir, O_EVTONLY | O_CLOEXEC);
	if (fd < 0)
		return;
	dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE,
	    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	__block CFDataRef last = signatureOf(p->path);
	dispatch_source_set_event_handler(s, ^{
		CFDataRef now = signatureOf(p->path);
		if (!CFEqual(now, last)) {
			CFRelease(last);
			last = now;
			fire(p, kSCPreferencesNotificationCommit | kSCPreferencesNotificationApply);
		} else
			CFRelease(now);
	});
	dispatch_source_set_cancel_handler(s, ^{
		close(fd);
		CFRelease(last);
	});
	p->watcher = s;
	dispatch_resume(s);
}

Boolean SCPreferencesSetCallback(SCPreferencesRef ref, SCPreferencesCallBack callout, SCPreferencesContext *context)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (p->context.release && p->context.info)
		p->context.release(p->context.info);
	memset(&p->context, 0, sizeof(p->context));
	p->callout = callout;
	if (context) {
		p->context = *context;
		if (context->retain && context->info)
			p->context.info = (void *)context->retain(context->info);
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesSetDispatchQueue(SCPreferencesRef ref, dispatch_queue_t queue)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (queue && (p->queue || p->runLoop)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (p->queue)
		dispatch_release(p->queue);
	p->queue = queue;
	if (queue) {
		dispatch_retain(queue);
		startWatching(p);
	} else
		stopWatching(p);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesScheduleWithRunLoop(SCPreferencesRef ref, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!runLoop || p->queue) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (p->runLoop)
		CFRelease(p->runLoop);
	if (p->runLoopMode)
		CFRelease(p->runLoopMode);
	p->runLoop = (CFRunLoopRef)CFRetain(runLoop);
	p->runLoopMode = CFRetain(runLoopMode ? runLoopMode : kCFRunLoopDefaultMode);
	startWatching(p);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesUnscheduleFromRunLoop(SCPreferencesRef ref, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!p->runLoop || p->runLoop != runLoop) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	stopWatching(p);
	CFRelease(p->runLoop);
	p->runLoop = NULL;
	if (p->runLoopMode)
		CFRelease(p->runLoopMode);
	p->runLoopMode = NULL;
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* ---- Paths: "/a/b/c" through nested dictionaries, following __LINK__s ---- */

static CFArrayRef components(CFStringRef path)
{
	if (!path || CFGetTypeID(path) != CFStringGetTypeID() || !CFStringHasPrefix(path, CFSTR("/")))
		return NULL;
	CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, path, CFSTR("/"));
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(parts); i++)
		if (CFStringGetLength(CFArrayGetValueAtIndex(parts, i)))
			CFArrayAppendValue(out, CFArrayGetValueAtIndex(parts, i));
	CFRelease(parts);
	return out;
}

/* The dictionary at a path; follow the final link or not. depth bounds link chains. */
static CFDictionaryRef lookup(Prefs *p, CFStringRef path, bool followLast, int depth)
{
	CFArrayRef parts = components(path);
	if (!parts || depth > 16) {
		if (parts)
			CFRelease(parts);
		return NULL;
	}
	CFDictionaryRef node = access_(p);
	for (CFIndex i = 0; node && i < CFArrayGetCount(parts); i++) {
		CFTypeRef next = CFDictionaryGetValue(node, CFArrayGetValueAtIndex(parts, i));
		if (!next || CFGetTypeID(next) != CFDictionaryGetTypeID()) {
			node = NULL;
			break;
		}
		node = next;
		CFStringRef link = CFDictionaryGetValue(node, kSCResvLink);
		bool last = i == CFArrayGetCount(parts) - 1;
		if (link && CFGetTypeID(link) == CFStringGetTypeID() && (!last || followLast))
			node = lookup(p, link, true, depth + 1);
	}
	CFRelease(parts);
	return node;
}

CFDictionaryRef SCPreferencesPathGetValue(SCPreferencesRef ref, CFStringRef path)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	CFDictionaryRef d = CFEqual(path, CFSTR("/")) ? access_(p) : lookup(p, path, true, 0);
	_SCErrorSet(d ? kSCStatusOK : kSCStatusNoKey);
	return d;
}

CFStringRef SCPreferencesPathGetLink(SCPreferencesRef ref, CFStringRef path)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	CFDictionaryRef d = lookup(p, path, false, 0);
	CFStringRef link = d ? CFDictionaryGetValue(d, kSCResvLink) : NULL;
	if (link && CFGetTypeID(link) != CFStringGetTypeID())
		link = NULL;
	_SCErrorSet(link ? kSCStatusOK : kSCStatusNoKey);
	return link;
}

/* Sets (value) or removes (NULL) the dictionary at a path, making parents. */
static Boolean store(Prefs *p, CFStringRef path, CFDictionaryRef value)
{
	CFArrayRef parts = components(path);
	if (!parts || CFArrayGetCount(parts) == 0) {
		if (parts)
			CFRelease(parts);
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFMutableDictionaryRef node = access_(p);
	CFIndex n = CFArrayGetCount(parts);
	for (CFIndex i = 0; i < n - 1; i++) {
		CFStringRef k = CFArrayGetValueAtIndex(parts, i);
		CFTypeRef next = CFDictionaryGetValue(node, k);
		if (next && CFGetTypeID(next) == CFDictionaryGetTypeID()) {
			/* Copy-on-write: the stored dictionaries may be immutable. */
			CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, next);
			CFDictionarySetValue(node, k, m);
			CFRelease(m);
			node = m;
		} else if (!value) {
			CFRelease(parts);
			_SCErrorSet(kSCStatusNoKey);
			return false;
		} else {
			CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CFDictionarySetValue(node, k, m);
			CFRelease(m);
			node = m;
		}
	}
	CFStringRef last = CFArrayGetValueAtIndex(parts, n - 1);
	if (!value && !CFDictionaryGetValue(node, last)) {
		CFRelease(parts);
		_SCErrorSet(kSCStatusNoKey);
		return false;
	}
	if (value)
		CFDictionarySetValue(node, last, value);
	else
		CFDictionaryRemoveValue(node, last);
	CFRelease(parts);
	p->changed = true;
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCPreferencesPathSetValue(SCPreferencesRef ref, CFStringRef path, CFDictionaryRef value)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	return store(p, path, value);
}

Boolean SCPreferencesPathSetLink(SCPreferencesRef ref, CFStringRef path, CFStringRef link)
{
	Prefs *p = valid(ref);
	if (!p)
		return false;
	if (!link || CFGetTypeID(link) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&kSCResvLink, (const void **)&link, 1,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	Boolean ok = store(p, path, d);
	CFRelease(d);
	return ok;
}

Boolean SCPreferencesPathRemoveValue(SCPreferencesRef ref, CFStringRef path)
{
	Prefs *p = valid(ref);
	return p ? store(p, path, NULL) : false;
}

CFStringRef SCPreferencesPathCreateUniqueChild(SCPreferencesRef ref, CFStringRef prefix)
{
	Prefs *p = valid(ref);
	if (!p)
		return NULL;
	CFUUIDRef u = CFUUIDCreate(NULL);
	CFStringRef s = CFUUIDCreateString(NULL, u);
	CFRelease(u);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), prefix, s);
	CFRelease(s);
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!store(p, path, empty)) {
		CFRelease(path);
		path = NULL;
	}
	CFRelease(empty);
	return path;
}

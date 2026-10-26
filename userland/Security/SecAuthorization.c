/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Authorization Services and security sessions.
 *
 * Where Finch's authorization service runs (authd, userland/authd: Finch's
 * systems), every call goes to it: it decides rights for the caller's
 * identity, checks passwords, shares credentials within a session, makes
 * external forms work between processes and runs privileged tools. Where it
 * doesn't (a macOS host, in the comparison tests), the rules are evaluated
 * in-process as below.
 *
 * In-process, rights and rules come from Apple's published authorization database
 * (Security's OSX/authd/authorization.plist, installed in the framework's
 * Resources): "allow" rules are granted, "deny" rules
 * denied, and rules that would need a user to authenticate are granted to
 * root (allow-root) or to members of the rule's group when the rule doesn't
 * ask for authentication. Anything that would need an authentication dialog
 * fails as Apple's does when interaction isn't possible: without
 * kAuthorizationFlagExtendRights, errAuthorizationDenied; without
 * kAuthorizationFlagInteractionAllowed, errAuthorizationInteractionNotAllowed;
 * and, since Finch has no SecurityAgent yet, errAuthorizationDenied otherwise.
 * External forms work within a process only (no authd to hand them across).
 */
#include "SecInternal.h"
#include "../authd/authd_protocol.h"
#include <Security/AuthSession.h>
#include <xpc/xpc.h>
#include <Security/AuthorizationDB.h>
#include <bsm/audit.h>
#include <bsm/audit_session.h>
#include <dlfcn.h>
#include <grp.h>
#include <limits.h>
#include <pthread.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct AuthorizationOpaqueRef {
	uint32_t magic;
	uint8_t token[32];
	bool remote;		/* authd's */
	struct AuthorizationOpaqueRef *next;
};
#define kAuthMagic 0x46415554u   /* 'FAUT' */

static pthread_mutex_t authLock = PTHREAD_MUTEX_INITIALIZER;
static struct AuthorizationOpaqueRef *allRefs;

static bool validRef(AuthorizationRef a)
{
	bool ok = false;
	pthread_mutex_lock(&authLock);
	for (struct AuthorizationOpaqueRef *r = allRefs; r; r = r->next)
		if (r == a && r->magic == kAuthMagic)
			ok = true;
	pthread_mutex_unlock(&authLock);
	return ok;
}

/* ---- authd ---- */

static bool authdAbsent;

/*
 * Send a request to authd and wait for its reply. NULL (with authdAbsent set
 * the first time) when the service isn't there.
 */
static xpc_object_t authdRequest(xpc_object_t request, OSStatus *status)
{
	if (authdAbsent)
		return NULL;
	xpc_connection_t c = xpc_connection_create_mach_service(AUTHD_SERVICE, NULL, 0);
	if (!c) {
		authdAbsent = true;
		return NULL;
	}
	xpc_connection_set_event_handler(c, ^(xpc_object_t event) { (void)event; });
	xpc_connection_resume(c);
	xpc_object_t reply = xpc_connection_send_message_with_reply_sync(c, request);
	xpc_connection_cancel(c);
	xpc_release(c);
	if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
	    xpc_dictionary_get_uint64(reply, AUTHD_KEY_VERSION) != AUTHD_VERSION) {
		/* No service, or another system's authd under the same name. */
		if (reply == XPC_ERROR_CONNECTION_INVALID ||
		    (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY))
			authdAbsent = true;
		if (reply)
			xpc_release(reply);
		return NULL;
	}
	*status = (OSStatus)xpc_dictionary_get_int64(reply, AUTHD_KEY_STATUS);
	return reply;
}

static xpc_object_t authdMessage(const char *op, AuthorizationRef a)
{
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(m, AUTHD_KEY_VERSION, AUTHD_VERSION);
	xpc_dictionary_set_string(m, AUTHD_KEY_OP, op);
	if (a)
		xpc_dictionary_set_data(m, AUTHD_KEY_TOKEN, a->token, AUTHD_TOKEN_SIZE);
	return m;
}

static struct AuthorizationOpaqueRef *newRef(const uint8_t token[32], bool remote)
{
	struct AuthorizationOpaqueRef *a = calloc(1, sizeof(*a));
	a->magic = kAuthMagic;
	if (token)
		memcpy(a->token, token, sizeof(a->token));
	else
		arc4random_buf(a->token, sizeof(a->token));
	a->remote = remote;
	pthread_mutex_lock(&authLock);
	a->next = allRefs;
	allRefs = a;
	pthread_mutex_unlock(&authLock);
	return a;
}

/* ---- The rules database ---- */

static CFDictionaryRef database;

static void loadDatabase(void)
{
	Dl_info info;
	if (!dladdr((const void *)loadDatabase, &info) || !info.dli_fname)
		return;
	const char *slash = strrchr(info.dli_fname, '/');
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%.*s/Resources/authorization.plist", (int)(slash - info.dli_fname), info.dli_fname);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
	if (stream && CFReadStreamOpen(stream)) {
		CFPropertyListRef p = CFPropertyListCreateWithStream(NULL, stream, 0, 0, NULL, NULL);
		if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
			database = p;
		else if (p)
			CFRelease(p);
		CFReadStreamClose(stream);
	}
	if (stream)
		CFRelease(stream);
	CFRelease(url);
}

static CFDictionaryRef section(CFStringRef name)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, loadDatabase);
	CFDictionaryRef d = database ? CFDictionaryGetValue(database, name) : NULL;
	return d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? d : NULL;
}

/* A right's definition: an exact match, else the longest wildcard ("prefix.")
 * that begins the name, else the default ("") right. */
static CFDictionaryRef rightDefinition(const char *name, bool fallback)
{
	CFDictionaryRef rights = section(CFSTR("rights"));
	if (!rights)
		return NULL;
	CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFDictionaryRef d = key ? CFDictionaryGetValue(rights, key) : NULL;
	if (key)
		CFRelease(key);
	if (d)
		return d;
	char prefix[1024];
	strlcpy(prefix, name, sizeof(prefix));
	for (char *dot = strrchr(prefix, '.'); dot; dot = strrchr(prefix, '.')) {
		dot[1] = 0;
		CFStringRef k = CFStringCreateWithCString(NULL, prefix, kCFStringEncodingUTF8);
		d = CFDictionaryGetValue(rights, k);
		CFRelease(k);
		if (d)
			return d;
		*dot = 0;
	}
	return fallback ? CFDictionaryGetValue(rights, CFSTR("")) : NULL;
}

static bool boolValue(CFDictionaryRef d, CFStringRef key, bool def)
{
	CFTypeRef v = CFDictionaryGetValue(d, key);
	return v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue(v) : def;
}

static bool inGroup(CFStringRef group)
{
	char name[256];
	if (!group || !CFStringGetCString(group, name, sizeof(name), kCFStringEncodingUTF8))
		return false;
	struct group *g = getgrnam(name);
	if (!g)
		return false;
	gid_t groups[NGROUPS_MAX];
	int n = getgroups(NGROUPS_MAX, groups);
	for (int i = 0; i < n; i++)
		if (groups[i] == g->gr_gid)
			return true;
	return getegid() == g->gr_gid;
}

enum { kGranted, kDenied, kNeedsAuthentication };

static int evaluateRule(CFDictionaryRef rule, int depth)
{
	if (!rule || depth > 10)
		return kDenied;
	CFStringRef cls = CFDictionaryGetValue(rule, CFSTR("class"));
	if (cls && CFEqual(cls, CFSTR("allow")))
		return kGranted;
	if (cls && CFEqual(cls, CFSTR("deny")))
		return kDenied;
	if (cls && CFEqual(cls, CFSTR("rule"))) {
		CFTypeRef names = CFDictionaryGetValue(rule, CFSTR("rule"));
		CFDictionaryRef rules = section(CFSTR("rules"));
		if (names && CFGetTypeID(names) == CFStringGetTypeID())
			names = CFArrayCreate(NULL, &names, 1, &kCFTypeArrayCallBacks);
		else if (names && CFGetTypeID(names) == CFArrayGetTypeID())
			CFRetain(names);
		else
			return kDenied;
		CFIndex count = CFArrayGetCount(names), k = count;
		/* "k-of-n" in the published database ("k" in older ones) */
		CFNumberRef kn = CFDictionaryGetValue(rule, CFSTR("k-of-n"));
		if (!kn)
			kn = CFDictionaryGetValue(rule, CFSTR("k"));
		if (kn && CFGetTypeID(kn) == CFNumberGetTypeID())
			CFNumberGetValue(kn, kCFNumberCFIndexType, &k);
		CFIndex granted = 0;
		int result = kDenied;
		for (CFIndex i = 0; i < count; i++) {
			CFDictionaryRef sub = rules ? CFDictionaryGetValue(rules, CFArrayGetValueAtIndex(names, i)) : NULL;
			int r = evaluateRule(sub, depth + 1);
			if (r == kGranted)
				granted++;
			else if (r == kNeedsAuthentication)
				result = kNeedsAuthentication;
		}
		CFRelease(names);
		return granted >= k ? kGranted : result;
	}
	/* user and evaluate-mechanisms: a person would authenticate. */
	if (geteuid() == 0 && boolValue(rule, CFSTR("allow-root"), false))
		return kGranted;
	if (cls && CFEqual(cls, CFSTR("user")) && !boolValue(rule, CFSTR("authenticate-user"), true) &&
	    inGroup(CFDictionaryGetValue(rule, CFSTR("group"))))
		return kGranted;
	if (geteuid() == 0 && cls && CFEqual(cls, CFSTR("evaluate-mechanisms")))
		return kGranted;
	return kNeedsAuthentication;
}

/* A right's rule: the right itself, or the named rule(s) it points to. */
static int evaluateRight(const char *name)
{
	CFDictionaryRef def = rightDefinition(name, true);
	return def ? evaluateRule(def, 0) : kNeedsAuthentication;
}

/* ---- Authorization calls ---- */

static AuthorizationItemSet *copyItems(const AuthorizationRights *rights)
{
	AuthorizationItemSet *set = calloc(1, sizeof(*set));
	UInt32 n = rights ? rights->count : 0;
	set->items = calloc(n ? n : 1, sizeof(AuthorizationItem));
	for (UInt32 i = 0; i < n; i++) {
		const AuthorizationItem *src = &rights->items[i];
		AuthorizationItem *dst = &set->items[set->count++];
		dst->name = src->name ? strdup(src->name) : NULL;
		dst->flags = src->flags;
		if (src->value && src->valueLength) {
			dst->value = malloc(src->valueLength);
			memcpy(dst->value, src->value, src->valueLength);
			dst->valueLength = src->valueLength;
		}
	}
	return set;
}

OSStatus AuthorizationFreeItemSet(AuthorizationItemSet *set)
{
	if (!set)
		return errAuthorizationInvalidSet;
	for (UInt32 i = 0; i < set->count; i++) {
		free((void *)set->items[i].name);
		free(set->items[i].value);
	}
	free(set->items);
	free(set);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const AuthorizationRights *rights,
    const AuthorizationEnvironment *environment, AuthorizationFlags flags, AuthorizationRights **authorizedRights)
{
	if (authorizedRights)
		*authorizedRights = NULL;
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (rights && rights->count && !rights->items)
		return errAuthorizationInvalidSet;
	if (authorization->remote) {
		xpc_object_t m = authdMessage(AUTHD_OP_COPY_RIGHTS, authorization);
		xpc_object_t names = xpc_array_create(NULL, 0);
		for (UInt32 i = 0; rights && i < rights->count; i++) {
			if (!rights->items[i].name) {
				xpc_release(names);
				xpc_release(m);
				return errAuthorizationInvalidSet;
			}
			xpc_array_set_string(names, XPC_ARRAY_APPEND, rights->items[i].name);
		}
		xpc_dictionary_set_value(m, AUTHD_KEY_RIGHTS, names);
		xpc_release(names);
		xpc_object_t env = xpc_dictionary_create(NULL, NULL, 0);
		for (UInt32 i = 0; environment && i < environment->count; i++) {
			const AuthorizationItem *it = &environment->items[i];
			if (it->name && it->value && it->valueLength)
				xpc_dictionary_set_data(env, it->name, it->value, it->valueLength);
		}
		xpc_dictionary_set_value(m, AUTHD_KEY_ENVIRONMENT, env);
		xpc_release(env);
		xpc_dictionary_set_uint64(m, AUTHD_KEY_FLAGS, flags);
		OSStatus st = errAuthorizationInternal;
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (!reply)
			return errAuthorizationInternal;
		if (st == errAuthorizationSuccess && authorizedRights) {
			xpc_object_t granted = xpc_dictionary_get_value(reply, AUTHD_KEY_RIGHTS);
			size_t n = granted && xpc_get_type(granted) == XPC_TYPE_ARRAY ? xpc_array_get_count(granted) : 0;
			AuthorizationItemSet *set = calloc(1, sizeof(*set));
			set->items = calloc(n ? n : 1, sizeof(AuthorizationItem));
			for (size_t i = 0; i < n; i++)
				set->items[set->count++].name = strdup(xpc_array_get_string(granted, i));
			*authorizedRights = set;
		}
		xpc_release(reply);
		return st;
	}
	for (UInt32 i = 0; rights && i < rights->count; i++) {
		if (!rights->items[i].name)
			return errAuthorizationInvalidSet;
		int r = evaluateRight(rights->items[i].name);
		if (r == kDenied)
			return errAuthorizationDenied;
		if (r == kNeedsAuthentication) {
			if (!(flags & kAuthorizationFlagExtendRights))
				return errAuthorizationDenied;
			if (!(flags & kAuthorizationFlagInteractionAllowed))
				return errAuthorizationInteractionNotAllowed;
			return errAuthorizationDenied;   /* no SecurityAgent to ask */
		}
	}
	if (authorizedRights && !(flags & kAuthorizationFlagPreAuthorize))
		*authorizedRights = copyItems(rights);
	else if (authorizedRights)
		*authorizedRights = copyItems(rights);
	return errAuthorizationSuccess;
}

void AuthorizationCopyRightsAsync(AuthorizationRef authorization, const AuthorizationRights *rights,
    const AuthorizationEnvironment *environment, AuthorizationFlags flags, AuthorizationAsyncCallback callbackBlock)
{
	AuthorizationRights *granted = NULL;
	OSStatus st = AuthorizationCopyRights(authorization, rights, environment, flags, &granted);
	callbackBlock(st, granted);
}

OSStatus AuthorizationCreate(const AuthorizationRights *rights, const AuthorizationEnvironment *environment,
    AuthorizationFlags flags, AuthorizationRef *authorization)
{
	if (flags & ~(kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPartialRights |
	                 kAuthorizationFlagDestroyRights | kAuthorizationFlagPreAuthorize | kAuthorizationFlagSkipInternalAuth |
	                 kAuthorizationFlagNoData))
		return errAuthorizationInvalidFlags;
	struct AuthorizationOpaqueRef *a = NULL;
	OSStatus st = errAuthorizationSuccess;
	xpc_object_t m = authdMessage(AUTHD_OP_CREATE, NULL);
	xpc_object_t reply = authdRequest(m, &st);
	xpc_release(m);
	if (reply) {
		size_t n = 0;
		const void *token = xpc_dictionary_get_data(reply, AUTHD_KEY_TOKEN, &n);
		if (st == errAuthorizationSuccess && token && n == AUTHD_TOKEN_SIZE)
			a = newRef(token, true);
		xpc_release(reply);
		if (!a)
			return st ? st : errAuthorizationInternal;
	} else {
		a = newRef(NULL, false);
	}
	st = errAuthorizationSuccess;
	if (rights && rights->count)
		st = AuthorizationCopyRights(a, rights, environment, flags, NULL);
	if (st || !authorization) {
		AuthorizationFree(a, kAuthorizationFlagDefaults);
		return st;
	}
	*authorization = a;
	return errAuthorizationSuccess;
}

OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags)
{
	if (validRef(authorization) && authorization->remote) {
		xpc_object_t m = authdMessage(AUTHD_OP_FREE, authorization);
		xpc_dictionary_set_bool(m, AUTHD_KEY_DESTROY, (flags & kAuthorizationFlagDestroyRights) != 0);
		OSStatus st;
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (reply)
			xpc_release(reply);
	}
	pthread_mutex_lock(&authLock);
	for (struct AuthorizationOpaqueRef **p = &allRefs; *p; p = &(*p)->next)
		if (*p == authorization) {
			*p = authorization->next;
			pthread_mutex_unlock(&authLock);
			struct AuthorizationOpaqueRef *a = (struct AuthorizationOpaqueRef *)authorization;
			a->magic = 0;
			free(a);
			return errAuthorizationSuccess;
		}
	pthread_mutex_unlock(&authLock);
	return errAuthorizationInvalidRef;
}

OSStatus AuthorizationCopyInfo(AuthorizationRef authorization, AuthorizationString tag, AuthorizationItemSet **info)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!info)
		return errAuthorizationInvalidPointer;
	if (authorization->remote) {
		OSStatus st = errAuthorizationInternal;
		xpc_object_t m = authdMessage(AUTHD_OP_COPY_INFO, authorization);
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (!reply)
			return errAuthorizationInternal;
		AuthorizationItemSet *set = calloc(1, sizeof(*set));
		xpc_object_t d = xpc_dictionary_get_value(reply, AUTHD_KEY_INFO);
		size_t n = d && xpc_get_type(d) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_count(d) : 0;
		set->items = calloc(n ? n : 1, sizeof(AuthorizationItem));
		if (n)
			xpc_dictionary_apply(d, ^bool(const char *key, xpc_object_t value) {
				if (tag && strcmp(tag, key))
					return true;
				AuthorizationItem *it = &set->items[set->count++];
				it->name = strdup(key);
				it->valueLength = xpc_data_get_length(value);
				it->value = malloc(it->valueLength ? it->valueLength : 1);
				memcpy(it->value, xpc_data_get_bytes_ptr(value), it->valueLength);
				return true;
			});
		xpc_release(reply);
		*info = set;
		return st;
	}
	/* No credentials are ever acquired in-process, so there's no context to report. */
	*info = copyItems(NULL);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationMakeExternalForm(AuthorizationRef authorization, AuthorizationExternalForm *extForm)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!extForm)
		return errAuthorizationInvalidPointer;
	memcpy(extForm->bytes, authorization->token, kAuthorizationExternalFormLength);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCreateFromExternalForm(const AuthorizationExternalForm *extForm, AuthorizationRef *authorization)
{
	if (!extForm || !authorization)
		return errAuthorizationInvalidPointer;
	/* authd's: any process holding the form may use the authorization. */
	{
		struct AuthorizationOpaqueRef probe = { .magic = kAuthMagic };
		memcpy(probe.token, extForm->bytes, sizeof(probe.token));
		OSStatus st = errAuthorizationInternal;
		xpc_object_t m = authdMessage(AUTHD_OP_EXTERNAL, &probe);
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (reply) {
			xpc_release(reply);
			if (st != errAuthorizationSuccess)
				return st;
			*authorization = newRef(probe.token, true);
			return errAuthorizationSuccess;
		}
	}
	pthread_mutex_lock(&authLock);
	struct AuthorizationOpaqueRef *found = NULL;
	for (struct AuthorizationOpaqueRef *r = allRefs; r; r = r->next)
		if (!memcmp(r->token, extForm->bytes, kAuthorizationExternalFormLength))
			found = r;
	pthread_mutex_unlock(&authLock);
	if (!found)
		return errAuthorizationInvalidRef;
	/* A second reference to the same authorization (its own handle). */
	struct AuthorizationOpaqueRef *a = calloc(1, sizeof(*a));
	a->magic = kAuthMagic;
	memcpy(a->token, found->token, sizeof(a->token));
	pthread_mutex_lock(&authLock);
	a->next = allRefs;
	allRefs = a;
	pthread_mutex_unlock(&authLock);
	*authorization = a;
	return errAuthorizationSuccess;
}

OSStatus AuthorizationRightGet(const char *rightName, CFDictionaryRef *rightDefinitionOut)
{
	if (!rightName)
		return errAuthorizationInvalidPointer;
	{
		OSStatus st = errAuthorizationInternal;
		xpc_object_t m = authdMessage(AUTHD_OP_RIGHT_GET, NULL);
		xpc_dictionary_set_string(m, AUTHD_KEY_NAME, rightName);
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (reply) {
			size_t n = 0;
			const void *bytes = xpc_dictionary_get_data(reply, AUTHD_KEY_DEFINITION, &n);
			if (st == errAuthorizationSuccess && rightDefinitionOut) {
				CFDataRef data = bytes ? CFDataCreate(NULL, bytes, (CFIndex)n) : NULL;
				*rightDefinitionOut = data ? CFPropertyListCreateWithData(NULL, data, 0, NULL, NULL) : NULL;
				if (data)
					CFRelease(data);
				if (!*rightDefinitionOut)
					st = errAuthorizationInternal;
			}
			xpc_release(reply);
			return st;
		}
	}
	CFDictionaryRef d = rightDefinition(rightName, false);
	if (!d)
		return errAuthorizationDenied;
	if (rightDefinitionOut)
		*rightDefinitionOut = CFDictionaryCreateCopy(NULL, d);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationRightSet(AuthorizationRef authRef, const char *rightName, CFTypeRef rightDefinition,
    CFStringRef descriptionKey, CFBundleRef bundle, CFStringRef localeTableName)
{
	if (!validRef(authRef))
		return errAuthorizationInvalidRef;
	if (!rightName || !rightDefinition)
		return errAuthorizationInvalidPointer;
	if (!authRef->remote)
		return errAuthorizationDenied;	/* in-process, Apple's published rules are read-only */
	CFDictionaryRef def = NULL;
	if (CFGetTypeID(rightDefinition) == CFDictionaryGetTypeID()) {
		def = CFRetain(rightDefinition);
	} else if (CFGetTypeID(rightDefinition) == CFStringGetTypeID()) {
		/* A rule's name: the right uses that rule. */
		const void *k[] = { CFSTR("class"), CFSTR("rule") };
		const void *v[] = { CFSTR("rule"), rightDefinition };
		def = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	} else {
		return errAuthorizationInvalidPointer;
	}
	CFDataRef data = CFPropertyListCreateData(NULL, def, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	CFRelease(def);
	if (!data)
		return errAuthorizationInternal;
	xpc_object_t m = authdMessage(AUTHD_OP_RIGHT_SET, authRef);
	xpc_dictionary_set_string(m, AUTHD_KEY_NAME, rightName);
	xpc_dictionary_set_data(m, AUTHD_KEY_DEFINITION, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
	CFRelease(data);
	OSStatus st = errAuthorizationInternal;
	xpc_object_t reply = authdRequest(m, &st);
	xpc_release(m);
	if (reply)
		xpc_release(reply);
	return reply ? st : errAuthorizationInternal;
}

OSStatus AuthorizationRightRemove(AuthorizationRef authRef, const char *rightName)
{
	if (!validRef(authRef))
		return errAuthorizationInvalidRef;
	if (!rightName)
		return errAuthorizationInvalidPointer;
	if (!authRef->remote)
		return errAuthorizationDenied;
	xpc_object_t m = authdMessage(AUTHD_OP_RIGHT_REMOVE, authRef);
	xpc_dictionary_set_string(m, AUTHD_KEY_NAME, rightName);
	OSStatus st = errAuthorizationInternal;
	xpc_object_t reply = authdRequest(m, &st);
	xpc_release(m);
	if (reply)
		xpc_release(reply);
	return reply ? st : errAuthorizationInternal;
}

/* Runs a tool as root, which only a process that's already root can do here. */
OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef authorization, const char *pathToTool,
    AuthorizationFlags options, char *const *arguments, FILE **communicationsPipe)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!pathToTool)
		return errAuthorizationInvalidPointer;
	if (geteuid() != 0) {
		/* authd runs it as root for an authorization with system.privilege.admin. */
		if (!authorization->remote)
			return errAuthorizationDenied;
		xpc_object_t m = authdMessage(AUTHD_OP_EXECUTE, authorization);
		xpc_dictionary_set_string(m, AUTHD_KEY_PATH, pathToTool);
		xpc_object_t args = xpc_array_create(NULL, 0);
		for (int i = 0; arguments && arguments[i]; i++)
			xpc_array_set_string(args, XPC_ARRAY_APPEND, arguments[i]);
		xpc_dictionary_set_value(m, AUTHD_KEY_ARGUMENTS, args);
		xpc_release(args);
		OSStatus st = errAuthorizationInternal;
		xpc_object_t reply = authdRequest(m, &st);
		xpc_release(m);
		if (!reply)
			return errAuthorizationInternal;
		int fd = st == errAuthorizationSuccess ? xpc_dictionary_dup_fd(reply, AUTHD_KEY_PIPE) : -1;
		xpc_release(reply);
		if (st != errAuthorizationSuccess)
			return st;
		if (fd < 0)
			return errAuthorizationToolExecuteFailure;
		if (communicationsPipe)
			*communicationsPipe = fdopen(fd, "r+");
		else
			close(fd);
		return errAuthorizationSuccess;
	}
	int fds[2];
	if (communicationsPipe && pipe(fds) < 0)
		return errAuthorizationToolExecuteFailure;
	pid_t pid = fork();
	if (pid < 0)
		return errAuthorizationToolExecuteFailure;
	if (pid == 0) {
		if (communicationsPipe) {
			dup2(fds[1], 0);
			dup2(fds[1], 1);
			close(fds[0]);
			close(fds[1]);
		}
		int argc = 0;
		while (arguments && arguments[argc])
			argc++;
		char **argv = calloc(argc + 2, sizeof(char *));
		argv[0] = (char *)pathToTool;
		for (int i = 0; i < argc; i++)
			argv[i + 1] = arguments[i];
		execv(pathToTool, argv);
		_exit(127);
	}
	if (communicationsPipe) {
		close(fds[1]);
		*communicationsPipe = fdopen(fds[0], "r+");
	}
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCopyPrivilegedReference(AuthorizationRef *authorization, AuthorizationFlags flags)
{
	return errAuthorizationInvalidRef;
}

/* ---- Security sessions: the audit session ---- */

OSStatus SessionGetInfo(SecuritySessionId session, SecuritySessionId *sessionId, SessionAttributeBits *attributes)
{
	auditinfo_addr_t info;
	memset(&info, 0, sizeof(info));
	if (session == callerSecuritySession) {
		if (getaudit_addr(&info, sizeof(info)) < 0)
			return errSessionInternal;
	} else {
		info.ai_asid = (au_asid_t)session;
		if (audit_session_self() == MACH_PORT_NULL)
			return errSessionInvalidId;
	}
	if (sessionId)
		*sessionId = (SecuritySessionId)info.ai_asid;
	if (attributes)
		*attributes = (SessionAttributeBits)(info.ai_flags &
		    (sessionIsRoot | sessionHasGraphicAccess | sessionHasTTY | sessionIsRemote));
	return errSessionSuccess;
}

OSStatus SessionCreate(SessionCreationFlags flags, SessionAttributeBits attributes)
{
	auditinfo_addr_t info;
	memset(&info, 0, sizeof(info));
	if (getaudit_addr(&info, sizeof(info)) < 0)
		return errSessionInternal;
	info.ai_asid = AU_ASSIGN_ASID;
	info.ai_flags = attributes & (sessionHasGraphicAccess | sessionHasTTY | sessionIsRemote);
	return setaudit_addr(&info, sizeof(info)) < 0 ? errSessionAuthorizationDenied : errSessionSuccess;
}

/* ---- Gatekeeper's assessment control ---- */

/* Finch has no assessment service: assessments are off (as with spctl
 * --master-disable), and nothing else is supported. */
Boolean SecAssessmentControl(CFStringRef control, void *arguments, CFErrorRef *errors)
{
	if (errors)
		*errors = NULL;
	if (control && (CFEqual(control, CFSTR("ui-status")) || CFEqual(control, CFSTR("ui-get-devid")) ||
	                   CFEqual(control, CFSTR("ui-get-devid-local")))) {
		if (arguments)
			*(CFBooleanRef *)arguments = kCFBooleanFalse;
		return true;
	}
	if (errors)
		*errors = _SecCreateError(errSecCSUnimplemented, NULL);
	return false;
}

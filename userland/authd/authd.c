/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * authd: Finch's authorization service (com.apple.authd), the one place that
 * decides authorization rights for every process, as macOS's authd does.
 *
 * Security.framework's Authorization calls come here over XPC. An
 * authorization is a 32-byte token (its external form) owned by the audit
 * session that made it. Rights are decided by the rules database
 * (/var/db/auth.plist, seeded from Apple's published authorization.plist in
 * Security.framework's Resources) for the caller's identity, taken from the
 * message's audit token:
 *
 *   allow / deny               as written
 *   user                       root with allow-root; a member of the rule's
 *                              group without authenticate-user; otherwise a
 *                              credential: a user, of the group, who gave
 *                              their password (checked with PAM's
 *                              "authorization" service) within the rule's
 *                              timeout, kept by the authorization and, with
 *                              shared, by its session
 *   rule (k of n)              its sub-rules
 *   evaluate-mechanisms        root, or a credential
 *
 * Passwords come in the request's environment (kAuthorizationEnvironmentUsername
 * and ...Password); without them a right that needs one fails as macOS's
 * does with no agent to ask (errAuthorizationInteractionNotAllowed without
 * kAuthorizationFlagInteractionAllowed, else errAuthorizationDenied).
 *
 * AuthorizationExecuteWithPrivileges comes here too: an authorization that holds
 * system.privilege.admin may have a tool run as root, with a pipe to it.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <bsm/libbsm.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "authd_protocol.h"

void xpc_dictionary_get_audit_token(xpc_object_t message, audit_token_t *token);

#define DATABASE "/private/var/db/auth.plist"
#define TEMPLATE "/System/Library/Frameworks/Security.framework/Versions/A/Resources/authorization.plist"
#define MAX_AUTHORIZATIONS 4096
#define MAX_CREDENTIALS 16

extern char **environ;

/* ---- the rules database ---- */

static CFMutableDictionaryRef database;

static CFDictionaryRef
read_plist(const char *path)
{
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
	CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
	CFPropertyListRef p = NULL;
	if (stream && CFReadStreamOpen(stream)) {
		p = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
		CFReadStreamClose(stream);
	}
	if (stream) {
		CFRelease(stream);
	}
	CFRelease(url);
	if (p && CFGetTypeID(p) != CFDictionaryGetTypeID()) {
		CFRelease(p);
		p = NULL;
	}
	return p;
}

static bool
write_database(void)
{
	CFDataRef data = CFPropertyListCreateData(NULL, database, kCFPropertyListXMLFormat_v1_0, 0, NULL);
	if (data == NULL) {
		return false;
	}
	char temp[] = DATABASE ".XXXXXX";
	int fd = mkstemp(temp);
	bool ok = fd >= 0 && fchmod(fd, 0644) == 0 &&
	    write(fd, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data)) == CFDataGetLength(data) &&
	    fsync(fd) == 0;
	if (fd >= 0) {
		close(fd);
	}
	ok = ok && rename(temp, DATABASE) == 0;
	if (!ok) {
		unlink(temp);
	}
	CFRelease(data);
	return ok;
}

static void
load_database(void)
{
	CFDictionaryRef d = read_plist(DATABASE);
	if (d == NULL) {
		/* First start: the published rules become this system's database. */
		d = read_plist(TEMPLATE);
		if (d != NULL) {
			database = (CFMutableDictionaryRef)d;
			if (!write_database()) {
				fprintf(stderr, "authd: can't write %s\n", DATABASE);
			}
			return;
		}
		d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	}
	database = (CFMutableDictionaryRef)d;
}

static CFMutableDictionaryRef
section(CFStringRef name)
{
	CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFDictionaryGetValue(database, name);
	if (d == NULL || CFGetTypeID(d) != CFDictionaryGetTypeID()) {
		d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFDictionarySetValue(database, name, d);
		CFRelease(d);
	}
	return d;
}

/* A right's definition: an exact match, else the longest wildcard ("prefix.")
   that begins the name, else the default ("") right. */
static CFDictionaryRef
right_definition(const char *name, bool fallback)
{
	CFDictionaryRef rights = section(CFSTR("rights"));
	CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFDictionaryRef d = key ? CFDictionaryGetValue(rights, key) : NULL;
	if (key) {
		CFRelease(key);
	}
	if (d) {
		return d;
	}
	char prefix[1024];
	strlcpy(prefix, name, sizeof(prefix));
	for (char *dot = strrchr(prefix, '.'); dot; dot = strrchr(prefix, '.')) {
		dot[1] = 0;
		CFStringRef k = CFStringCreateWithCString(NULL, prefix, kCFStringEncodingUTF8);
		d = CFDictionaryGetValue(rights, k);
		CFRelease(k);
		if (d) {
			return d;
		}
		*dot = 0;
	}
	return fallback ? CFDictionaryGetValue(rights, CFSTR("")) : NULL;
}

static bool
bool_value(CFDictionaryRef d, CFStringRef key, bool def)
{
	CFTypeRef v = CFDictionaryGetValue(d, key);
	return v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue(v) : def;
}

static long
number_value(CFDictionaryRef d, CFStringRef key, long def)
{
	CFNumberRef v = CFDictionaryGetValue(d, key);
	long n = def;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
		CFNumberGetValue(v, kCFNumberLongType, &n);
	}
	return n;
}

/* ---- identities ---- */

static bool
user_in_group(uid_t uid, CFStringRef group)
{
	char name[256];
	if (group == NULL || !CFStringGetCString(group, name, sizeof(name), kCFStringEncodingUTF8)) {
		return false;
	}
	struct group *g = getgrnam(name);
	struct passwd *pw = getpwuid(uid);
	if (g == NULL || pw == NULL) {
		return false;
	}
	if (pw->pw_gid == g->gr_gid) {
		return true;
	}
	for (char **m = g->gr_mem; m && *m; m++) {
		if (strcmp(*m, pw->pw_name) == 0) {
			return true;
		}
	}
	return false;
}

/* A user who gave their password, until expires (0: for the authorization's life). */
struct credential {
	uid_t uid;
	time_t expires;
	uint64_t order;		/* when it was given: the latest is the context's user */
	bool used;
};

static bool
credential_valid(const struct credential *c, time_t now)
{
	return c->used && (c->expires == 0 || now < c->expires);
}

/* ---- authorizations and sessions ---- */

struct authorization {
	uint8_t token[AUTHD_TOKEN_SIZE];
	au_asid_t session;
	uid_t creator_uid;
	pid_t creator_pid;
	struct credential credentials[MAX_CREDENTIALS];
	CFMutableSetRef rights;		/* rights it holds */
	bool used;
};

struct session_credentials {
	au_asid_t session;
	struct credential credentials[MAX_CREDENTIALS];
	struct session_credentials *next;
};

static struct authorization *authorizations;
static size_t authorization_count;
static struct session_credentials *sessions;

static struct authorization *
find_authorization(const uint8_t token[AUTHD_TOKEN_SIZE])
{
	for (size_t i = 0; i < authorization_count; i++) {
		if (authorizations[i].used && memcmp(authorizations[i].token, token, AUTHD_TOKEN_SIZE) == 0) {
			return &authorizations[i];
		}
	}
	return NULL;
}

static struct session_credentials *
session_for(au_asid_t asid)
{
	for (struct session_credentials *s = sessions; s; s = s->next) {
		if (s->session == asid) {
			return s;
		}
	}
	struct session_credentials *s = calloc(1, sizeof(*s));
	if (s) {
		s->session = asid;
		s->next = sessions;
		sessions = s;
	}
	return s;
}

static void
add_credential(struct credential *list, uid_t uid, long timeout, time_t now)
{
	struct credential *slot = NULL;
	for (int i = 0; i < MAX_CREDENTIALS; i++) {
		if (list[i].used && list[i].uid == uid) {
			slot = &list[i];
			break;
		}
		if (!slot && !credential_valid(&list[i], now)) {
			slot = &list[i];
		}
	}
	if (slot == NULL) {
		slot = &list[0];
	}
	slot->uid = uid;
	slot->used = true;
	slot->expires = timeout > 0 ? now + timeout : 0;
	static uint64_t given;
	slot->order = ++given;
}

/* ---- evaluation ---- */

enum { GRANTED, DENIED, NEEDS_CREDENTIAL };

struct subject {
	uid_t uid;
	uid_t audit_uid;	/* who logged in to the caller's session */
	au_asid_t session;
	struct authorization *auth;
};

/* The caller runs as the user who logged in to its session. */
static bool
session_owner(const struct subject *s)
{
	return s->audit_uid != AU_DEFAUDITID && s->uid == s->audit_uid;
}

/* A credential of the rule's (in its group, unexpired, shared or own). */
static bool
has_credential(const struct subject *s, CFDictionaryRef rule)
{
	time_t now = time(NULL);
	CFStringRef group = CFDictionaryGetValue(rule, CFSTR("group"));
	bool shared = bool_value(rule, CFSTR("shared"), false);
	long timeout = number_value(rule, CFSTR("timeout"), LONG_MAX);
	struct session_credentials *sess = shared ? session_for(s->session) : NULL;
	for (int pass = 0; pass < 2; pass++) {
		const struct credential *list = pass == 0 ? s->auth->credentials : (sess ? sess->credentials : NULL);
		for (int i = 0; list && i < MAX_CREDENTIALS; i++) {
			if (!credential_valid(&list[i], now)) {
				continue;
			}
			/* A rule's own timeout: an older password no longer counts (0: never reused). */
			if (timeout == 0 && pass == 1) {
				continue;
			}
			if (group == NULL || user_in_group(list[i].uid, group)) {
				return true;
			}
		}
	}
	return false;
}

static int
evaluate_rule(const struct subject *s, CFDictionaryRef rule, int depth, CFDictionaryRef *needs)
{
	if (rule == NULL || depth > 10) {
		return DENIED;
	}
	CFStringRef cls = CFDictionaryGetValue(rule, CFSTR("class"));
	if (cls && CFEqual(cls, CFSTR("allow"))) {
		return GRANTED;
	}
	if (cls && CFEqual(cls, CFSTR("deny"))) {
		return DENIED;
	}
	if (cls && CFEqual(cls, CFSTR("rule"))) {
		CFTypeRef names = CFDictionaryGetValue(rule, CFSTR("rule"));
		CFDictionaryRef rules = section(CFSTR("rules"));
		if (names && CFGetTypeID(names) == CFStringGetTypeID()) {
			names = CFArrayCreate(NULL, &names, 1, &kCFTypeArrayCallBacks);
		} else if (names && CFGetTypeID(names) == CFArrayGetTypeID()) {
			CFRetain(names);
		} else {
			return DENIED;
		}
		CFIndex count = CFArrayGetCount(names), k = count;
		/* "k-of-n" in the published database ("k" in older ones) */
		CFNumberRef kn = CFDictionaryGetValue(rule, CFSTR("k-of-n"));
		if (!kn)
			kn = CFDictionaryGetValue(rule, CFSTR("k"));
		if (kn && CFGetTypeID(kn) == CFNumberGetTypeID()) {
			CFNumberGetValue(kn, kCFNumberCFIndexType, &k);
		}
		CFIndex granted = 0;
		int result = DENIED;
		for (CFIndex i = 0; i < count; i++) {
			CFDictionaryRef sub = CFDictionaryGetValue(rules, CFArrayGetValueAtIndex(names, i));
			int r = evaluate_rule(s, sub, depth + 1, needs);
			if (r == GRANTED) {
				granted++;
			} else if (r == NEEDS_CREDENTIAL) {
				result = NEEDS_CREDENTIAL;
			}
		}
		CFRelease(names);
		return granted >= k ? GRANTED : result;
	}
	if (s->uid == 0 && bool_value(rule, CFSTR("allow-root"), false)) {
		return GRANTED;
	}
	if (cls && CFEqual(cls, CFSTR("user"))) {
		CFStringRef group = CFDictionaryGetValue(rule, CFSTR("group"));
		if (!bool_value(rule, CFSTR("authenticate-user"), true)) {
			/* The caller itself: the session's owner, or in the group. Neither
			   (is-root without root): denied, not asked for a password. */
			bool owner = bool_value(rule, CFSTR("session-owner"), false) && session_owner(s);
			return owner || (group != NULL && user_in_group(s->uid, group)) ? GRANTED : DENIED;
		}
		if (has_credential(s, rule)) {
			return GRANTED;
		}
		*needs = rule;
		return NEEDS_CREDENTIAL;
	}
	if (cls && CFEqual(cls, CFSTR("evaluate-mechanisms"))) {
		if (s->uid == 0 || has_credential(s, rule)) {
			return GRANTED;
		}
		*needs = rule;
		return NEEDS_CREDENTIAL;
	}
	return DENIED;
}

/* ---- passwords (PAM's "authorization" service) ---- */

struct conversation_data {
	const char *password;
};

static int
conversation(int count, const struct pam_message **messages, struct pam_response **responses, void *arg)
{
	struct conversation_data *d = arg;
	struct pam_response *r = calloc((size_t)count, sizeof(*r));
	if (r == NULL) {
		return PAM_BUF_ERR;
	}
	for (int i = 0; i < count; i++) {
		if (messages[i]->msg_style == PAM_PROMPT_ECHO_OFF || messages[i]->msg_style == PAM_PROMPT_ECHO_ON) {
			r[i].resp = strdup(d->password ? d->password : "");
		}
	}
	*responses = r;
	return PAM_SUCCESS;
}

static bool
check_password(const char *user, const char *password)
{
	struct conversation_data data = { password };
	struct pam_conv conv = { conversation, &data };
	pam_handle_t *pamh = NULL;
	int r = pam_start("authorization", user, &conv, &pamh);
	if (r == PAM_SUCCESS) {
		r = pam_authenticate(pamh, 0);
	}
	if (r == PAM_SUCCESS) {
		r = pam_acct_mgmt(pamh, 0);
	}
	if (pamh) {
		pam_end(pamh, r);
	}
	return r == PAM_SUCCESS;
}

/* ---- requests ---- */

static struct authorization *
new_authorization(au_asid_t session, uid_t uid, pid_t pid)
{
	struct authorization *a = NULL;
	for (size_t i = 0; i < authorization_count; i++) {
		if (!authorizations[i].used) {
			a = &authorizations[i];
			break;
		}
	}
	if (a == NULL) {
		if (authorization_count == MAX_AUTHORIZATIONS) {
			return NULL;
		}
		a = &authorizations[authorization_count++];
	}
	memset(a, 0, sizeof(*a));
	a->used = true;
	arc4random_buf(a->token, sizeof(a->token));
	a->session = session;
	a->creator_uid = uid;
	a->creator_pid = pid;
	a->rights = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	return a;
}

static void
free_authorization(struct authorization *a)
{
	if (a->rights) {
		CFRelease(a->rights);
	}
	memset(a, 0, sizeof(*a));
}

static const uint8_t *
request_token(xpc_object_t request)
{
	size_t n = 0;
	const void *t = xpc_dictionary_get_data(request, AUTHD_KEY_TOKEN, &n);
	return n == AUTHD_TOKEN_SIZE ? t : NULL;
}

/* The environment's value for a name (username, password), or NULL. */
static char *
environment_value(xpc_object_t request, const char *name)
{
	xpc_object_t env = xpc_dictionary_get_value(request, AUTHD_KEY_ENVIRONMENT);
	if (env == NULL || xpc_get_type(env) != XPC_TYPE_DICTIONARY) {
		return NULL;
	}
	size_t n = 0;
	const void *v = xpc_dictionary_get_data(env, name, &n);
	if (v == NULL || n == 0 || n > 4096) {
		return NULL;
	}
	char *s = malloc(n + 1);
	if (s) {
		memcpy(s, v, n);
		s[n] = '\0';
		/* values may carry their C string's terminator */
		s[strnlen(s, n)] = '\0';
	}
	return s;
}

static OSStatus
copy_rights(const struct subject *s, xpc_object_t request, xpc_object_t reply)
{
	struct authorization *a = s->auth;
	AuthorizationFlags flags = (AuthorizationFlags)xpc_dictionary_get_uint64(request, AUTHD_KEY_FLAGS);
	xpc_object_t names = xpc_dictionary_get_value(request, AUTHD_KEY_RIGHTS);
	xpc_object_t granted = xpc_array_create(NULL, 0);
	OSStatus status = errAuthorizationSuccess;
	bool tried_password = false;

	if (names == NULL || xpc_get_type(names) != XPC_TYPE_ARRAY) {
		xpc_release(granted);
		return errAuthorizationInvalidSet;
	}
	for (size_t i = 0; i < xpc_array_get_count(names) && status == errAuthorizationSuccess; i++) {
		const char *right = xpc_array_get_string(names, i);
		if (right == NULL) {
			status = errAuthorizationInvalidSet;
			break;
		}
		CFStringRef name = CFStringCreateWithCString(NULL, right, kCFStringEncodingUTF8);
		CFDictionaryRef needs = NULL;
		int r = CFSetContainsValue(a->rights, name) ? GRANTED : evaluate_rule(s, right_definition(right, true), 0, &needs);
		if (r == NEEDS_CREDENTIAL) {
			if (!(flags & kAuthorizationFlagExtendRights)) {
				r = DENIED;
			} else {
				char *user = environment_value(request, kAuthorizationEnvironmentUsername);
				char *password = environment_value(request, kAuthorizationEnvironmentPassword);
				if (user && password && !tried_password) {
					/* One password per request: a wrong one isn't retried. */
					tried_password = true;
					struct passwd *pw = getpwnam(user);
					if (pw != NULL && check_password(user, password)) {
						time_t now = time(NULL);
						long timeout = needs ? number_value(needs, CFSTR("timeout"), 0) : 0;
						add_credential(a->credentials, pw->pw_uid, 0, now);
						if (needs && bool_value(needs, CFSTR("shared"), false)) {
							struct session_credentials *sess = session_for(a->session);
							if (sess) {
								add_credential(sess->credentials, pw->pw_uid, timeout, now);
							}
						}
						needs = NULL;
						r = evaluate_rule(s, right_definition(right, true), 0, &needs);
					}
				}
				if (password) {
					memset(password, 0, strlen(password));
				}
				free(user);
				free(password);
				if (r == NEEDS_CREDENTIAL) {
					status = (flags & kAuthorizationFlagInteractionAllowed) ? errAuthorizationDenied :
					    errAuthorizationInteractionNotAllowed;
					if (tried_password) {
						status = errAuthorizationDenied;
					}
				}
			}
		}
		if (r == GRANTED) {
			if (!(flags & kAuthorizationFlagPreAuthorize)) {
				CFSetAddValue(a->rights, name);
			}
			xpc_array_set_string(granted, XPC_ARRAY_APPEND, right);
		} else if (r == DENIED) {
			if (!(flags & kAuthorizationFlagPartialRights)) {
				status = errAuthorizationDenied;
			}
		} else if ((flags & kAuthorizationFlagPartialRights) && status != errAuthorizationSuccess) {
			status = errAuthorizationSuccess;
		}
		CFRelease(name);
	}
	if (status == errAuthorizationSuccess && (flags & kAuthorizationFlagPartialRights) &&
	    xpc_array_get_count(granted) == 0 && xpc_array_get_count(names) > 0) {
		status = errAuthorizationDenied;
	}
	xpc_dictionary_set_value(reply, AUTHD_KEY_RIGHTS, granted);
	xpc_release(granted);
	return status;
}

static OSStatus
copy_info(const struct subject *s, xpc_object_t reply)
{
	/* The context: the user whose password it was given, as macOS reports. */
	xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
	const struct credential *latest = NULL;
	for (int i = 0; i < MAX_CREDENTIALS; i++) {
		const struct credential *c = &s->auth->credentials[i];
		if (credential_valid(c, time(NULL)) && (latest == NULL || c->order > latest->order)) {
			latest = c;
		}
	}
	struct passwd *pw = latest ? getpwuid(latest->uid) : NULL;
	if (pw) {
		xpc_dictionary_set_data(info, kAuthorizationEnvironmentUsername, pw->pw_name, strlen(pw->pw_name) + 1);
	}
	xpc_dictionary_set_value(reply, AUTHD_KEY_INFO, info);
	xpc_release(info);
	return errAuthorizationSuccess;
}

/* Changing the rules: config.modify.RIGHT (or config.add/remove) for the caller. */
static OSStatus
change_right(const struct subject *s, xpc_object_t request, bool remove)
{
	const char *right = xpc_dictionary_get_string(request, AUTHD_KEY_NAME);
	if (right == NULL || !*right) {
		return errAuthorizationInvalidPointer;
	}
	CFStringRef name = CFStringCreateWithCString(NULL, right, kCFStringEncodingUTF8);
	CFMutableDictionaryRef rights = section(CFSTR("rights"));
	bool exists = CFDictionaryContainsKey(rights, name);
	char config[1100];
	snprintf(config, sizeof(config), "config.%s.%s", remove ? "remove" : exists ? "modify" : "add", right);
	CFStringRef config_name = CFStringCreateWithCString(NULL, config, kCFStringEncodingUTF8);
	CFDictionaryRef needs = NULL;
	int r = CFSetContainsValue(s->auth->rights, config_name) ? GRANTED :
	    evaluate_rule(s, right_definition(config, true), 0, &needs);
	CFRelease(config_name);
	OSStatus status = r == GRANTED ? errAuthorizationSuccess : errAuthorizationDenied;
	if (status == errAuthorizationSuccess) {
		if (remove) {
			CFDictionaryRemoveValue(rights, name);
		} else {
			size_t n = 0;
			const void *bytes = xpc_dictionary_get_data(request, AUTHD_KEY_DEFINITION, &n);
			CFDataRef data = bytes ? CFDataCreate(NULL, bytes, (CFIndex)n) : NULL;
			CFPropertyListRef def = data ? CFPropertyListCreateWithData(NULL, data, kCFPropertyListMutableContainers,
			    NULL, NULL) : NULL;
			if (data) {
				CFRelease(data);
			}
			if (def == NULL || CFGetTypeID(def) != CFDictionaryGetTypeID()) {
				status = errAuthorizationInvalidPointer;
			} else {
				CFDictionarySetValue(rights, name, def);
			}
			if (def) {
				CFRelease(def);
			}
		}
		if (status == errAuthorizationSuccess && !write_database()) {
			status = errAuthorizationInternal;
		}
	}
	CFRelease(name);
	return status;
}

static OSStatus
right_get(xpc_object_t request, xpc_object_t reply)
{
	const char *right = xpc_dictionary_get_string(request, AUTHD_KEY_NAME);
	if (right == NULL) {
		return errAuthorizationInvalidPointer;
	}
	CFDictionaryRef d = right_definition(right, false);
	if (d == NULL) {
		return errAuthorizationDenied;
	}
	CFDataRef data = CFPropertyListCreateData(NULL, d, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	if (data == NULL) {
		return errAuthorizationInternal;
	}
	xpc_dictionary_set_data(reply, AUTHD_KEY_DEFINITION, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
	CFRelease(data);
	return errAuthorizationSuccess;
}

/* AuthorizationExecuteWithPrivileges: the tool as root, for system.privilege.admin. */
static OSStatus
execute(const struct subject *s, xpc_object_t request, xpc_object_t reply)
{
	CFStringRef admin = CFSTR("system.privilege.admin");
	if (!CFSetContainsValue(s->auth->rights, admin)) {
		return errAuthorizationDenied;
	}
	const char *path = xpc_dictionary_get_string(request, AUTHD_KEY_PATH);
	xpc_object_t args = xpc_dictionary_get_value(request, AUTHD_KEY_ARGUMENTS);
	if (path == NULL || path[0] != '/') {
		return errAuthorizationInvalidPointer;
	}
	size_t n = args && xpc_get_type(args) == XPC_TYPE_ARRAY ? xpc_array_get_count(args) : 0;
	char **argv = calloc(n + 2, sizeof(*argv));
	if (argv == NULL) {
		return errAuthorizationInternal;
	}
	argv[0] = (char *)path;
	for (size_t i = 0; i < n; i++) {
		argv[i + 1] = (char *)xpc_array_get_string(args, i);
	}
	int pipefd[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, pipefd) != 0) {
		free(argv);
		return errAuthorizationToolExecuteFailure;
	}
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDIN_FILENO);
	posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
	posix_spawn_file_actions_addclose(&actions, pipefd[0]);
	pid_t pid;
	int r = posix_spawn(&pid, path, &actions, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&actions);
	free(argv);
	close(pipefd[1]);
	if (r != 0) {
		close(pipefd[0]);
		return errAuthorizationToolExecuteFailure;
	}
	/* Reap it when it exits; the caller talks to it over the pipe. */
	dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
	    DISPATCH_PROC_EXIT, dispatch_get_main_queue());
	dispatch_source_set_event_handler(src, ^{
		int status;
		waitpid(pid, &status, WNOHANG);
		dispatch_source_cancel(src);
	});
	dispatch_resume(src);
	xpc_dictionary_set_fd(reply, AUTHD_KEY_PIPE, pipefd[0]);
	close(pipefd[0]);
	return errAuthorizationSuccess;
}

static void
handle(xpc_connection_t peer, xpc_object_t request)
{
	xpc_object_t reply = xpc_dictionary_create_reply(request);
	if (reply == NULL) {
		return;
	}
	audit_token_t token;
	xpc_dictionary_get_audit_token(request, &token);
	struct subject s = {
		.uid = audit_token_to_euid(token),
		.audit_uid = audit_token_to_auid(token),
		.session = audit_token_to_asid(token),
	};
	const char *op = xpc_dictionary_get_string(request, AUTHD_KEY_OP);
	OSStatus status = errAuthorizationInternal;

	if (op == NULL || xpc_dictionary_get_uint64(request, AUTHD_KEY_VERSION) != AUTHD_VERSION) {
		status = errAuthorizationInternal;
	} else if (!strcmp(op, AUTHD_OP_CREATE)) {
		struct authorization *a = new_authorization(s.session, s.uid, audit_token_to_pid(token));
		if (a) {
			xpc_dictionary_set_data(reply, AUTHD_KEY_TOKEN, a->token, AUTHD_TOKEN_SIZE);
			status = errAuthorizationSuccess;
		}
	} else if (!strcmp(op, AUTHD_OP_RIGHT_GET)) {
		status = right_get(request, reply);
	} else {
		const uint8_t *t = request_token(request);
		s.auth = t ? find_authorization(t) : NULL;
		if (s.auth == NULL) {
			status = errAuthorizationInvalidRef;
		} else if (!strcmp(op, AUTHD_OP_COPY_RIGHTS)) {
			status = copy_rights(&s, request, reply);
		} else if (!strcmp(op, AUTHD_OP_FREE)) {
			/* Only its session may free it; destroying rights empties it for all. */
			if (s.auth->session == s.session || s.uid == 0) {
				if (xpc_dictionary_get_bool(request, AUTHD_KEY_DESTROY)) {
					CFSetRemoveAllValues(s.auth->rights);
					memset(s.auth->credentials, 0, sizeof(s.auth->credentials));
				}
				free_authorization(s.auth);
			}
			status = errAuthorizationSuccess;
		} else if (!strcmp(op, AUTHD_OP_EXTERNAL)) {
			status = errAuthorizationSuccess;	/* it exists: the caller may use it */
		} else if (!strcmp(op, AUTHD_OP_COPY_INFO)) {
			status = copy_info(&s, reply);
		} else if (!strcmp(op, AUTHD_OP_RIGHT_SET)) {
			status = change_right(&s, request, false);
		} else if (!strcmp(op, AUTHD_OP_RIGHT_REMOVE)) {
			status = change_right(&s, request, true);
		} else if (!strcmp(op, AUTHD_OP_EXECUTE)) {
			status = execute(&s, request, reply);
		}
	}
	xpc_dictionary_set_int64(reply, AUTHD_KEY_STATUS, status);
	xpc_dictionary_set_uint64(reply, AUTHD_KEY_VERSION, AUTHD_VERSION);
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

int
main(void)
{
	authorizations = calloc(MAX_AUTHORIZATIONS, sizeof(*authorizations));
	if (authorizations == NULL) {
		return 1;
	}
	load_database();
	xpc_connection_t listener = xpc_connection_create_mach_service(AUTHD_SERVICE, dispatch_get_main_queue(),
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);
	xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
		if (xpc_get_type(event) != XPC_TYPE_CONNECTION) {
			return;
		}
		xpc_connection_t peer = (xpc_connection_t)event;
		xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
		xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
			if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
				handle(peer, message);
			}
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}

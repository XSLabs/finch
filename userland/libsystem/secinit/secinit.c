/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_secinit: the App Sandbox's start, run by libSystem's initializer in
 * every process (_libsecinit_initializer, Libsystem-1356 init.c). A process
 * whose code signature has com.apple.security.app-sandbox gets, before main:
 *
 *   - its container, HOME/Library/Containers/IDENTIFIER/Data, laid out as
 *     macOS lays it out (its own Documents, Library and tmp; links to the
 *     user's folders, which the profile keeps closed unless entitled);
 *   - HOME, CFFIXED_USER_HOME and TMPDIR pointing into it;
 *   - Finch's application.sb (userland/sandbox-profiles), compiled with the
 *     container, its bundle and its entitlements, and applied for good.
 *
 * IDENTIFIER is the code-signing identifier, as on macOS. A process already
 * sandboxed (a sandboxed app's child, com.apple.security.inherit) keeps its
 * parent's sandbox. If the sandbox can't be applied the process stops: a
 * sandboxed app never runs unsandboxed. macOS asks secinitd for the profile;
 * Finch compiles it in the process, with libsandbox.
 */

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

void _libsecinit_initializer(void);
int libsecinit_delete_all_data_container_content_for_current_user(void);
int libsecinit_fileoperation_save(void);
int libsecinit_fileoperation_set_attributes(void);
int libsecinit_fileoperation_symlink(void);

/* libxpc, libsystem_sandbox, libsystem_kernel */
xpc_object_t xpc_copy_entitlements_for_self(void);
int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[],
    char **errorbuf);
int sandbox_check(pid_t pid, const char *operation, int type, ...);
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_IDENTITY 11

#define APP_SANDBOX "com.apple.security.app-sandbox"
#define INHERIT "com.apple.security.inherit"

/* The user's folders a container links to (Data/NAME -> ../../../../NAME). */
static const char *const home_links[] = { "Desktop", "Downloads", "Movies", "Music", "Pictures" };
/* The user's Library folders its Library links to. */
static const char *const library_links[] = {
	"Audio", "Calendars", "ColorPickers", "Colors", "ColorSync", "Components", "Compositions",
	"Dictionaries", "Favorites", "Filters", "FontCollections", "Fonts", "Input Methods", "KeyBindings",
	"Keyboard Layouts", "Keychains", "Mail", "PDF Services", "QuickLook", "Sounds", "Spelling",
};
/* Its own folders. */
static const char *const own_folders[] = {
	"Documents", "Library", "Library/Application Scripts", "Library/Application Support",
	"Library/Caches", "Library/Logs", "Library/Preferences", "Library/Saved Application State",
	"Library/Autosave Information", "SystemData", "tmp",
};

static __attribute__((noreturn)) void
fail(const char *what, const char *detail)
{
	fprintf(stderr, "Sandbox: %s%s%s; the app can't start sandboxed\n", what, detail ? ": " : "", detail ? detail : "");
	abort();
}

/* The code-signing identifier: a blob of an 8-byte header and the string. */
static char *
signing_identifier(void)
{
	uint32_t header[2] = { 0, 0 };
	if (csops(getpid(), CS_OPS_IDENTITY, header, sizeof(header)) == 0 || errno != ERANGE)
		return NULL;
	uint32_t length = __builtin_bswap32(header[1]);
	if (length <= 8 || length > 4096)
		return NULL;
	char *blob = malloc(length + 1);
	if (blob == NULL || csops(getpid(), CS_OPS_IDENTITY, blob, length) != 0) {
		free(blob);
		return NULL;
	}
	blob[length] = '\0';
	char *identifier = strdup(blob + 8);
	free(blob);
	/* No slashes or dot-dot: it names a folder. */
	if (identifier && (!identifier[0] || strchr(identifier, '/') || !strcmp(identifier, ".") ||
	    !strcmp(identifier, ".."))) {
		free(identifier);
		return NULL;
	}
	return identifier;
}

static bool
make_folder(const char *path)
{
	return mkdir(path, 0700) == 0 || errno == EEXIST;
}

static void
make_link(const char *target, const char *path)
{
	struct stat st;
	if (lstat(path, &st) != 0)
		(void)symlink(target, path);
}

/* HOME/Library/Containers/IDENTIFIER/Data and what's in it. */
static bool
make_container(const char *home, const char *identifier, char *data, size_t size)
{
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%s/Library", home);
	if (!make_folder(path))
		return false;
	snprintf(path, sizeof(path), "%s/Library/Containers", home);
	if (!make_folder(path))
		return false;
	snprintf(path, sizeof(path), "%s/Library/Containers/%s", home, identifier);
	if (!make_folder(path))
		return false;
	if ((size_t)snprintf(data, size, "%s/Library/Containers/%s/Data", home, identifier) >= size || !make_folder(data))
		return false;
	for (size_t i = 0; i < sizeof(own_folders) / sizeof(own_folders[0]); i++) {
		snprintf(path, sizeof(path), "%s/%s", data, own_folders[i]);
		if (!make_folder(path))
			return false;
	}
	char target[PATH_MAX];
	for (size_t i = 0; i < sizeof(home_links) / sizeof(home_links[0]); i++) {
		snprintf(target, sizeof(target), "../../../../%s", home_links[i]);
		snprintf(path, sizeof(path), "%s/%s", data, home_links[i]);
		make_link(target, path);
	}
	snprintf(path, sizeof(path), "%s/.CFUserTextEncoding", data);
	make_link("../../../../.CFUserTextEncoding", path);
	for (size_t i = 0; i < sizeof(library_links) / sizeof(library_links[0]); i++) {
		snprintf(target, sizeof(target), "../../../../%s", library_links[i]);
		snprintf(path, sizeof(path), "%s/Library/%s", data, library_links[i]);
		make_link(target, path);
	}
	return true;
}

/* An app's bundle (the folder ending in .app above Contents/MacOS), or a
   tool's own executable. */
static bool
application_bundle(char *out, size_t size)
{
	char path[PATH_MAX], resolved[PATH_MAX];
	uint32_t n = sizeof(path);
	if (_NSGetExecutablePath(path, &n) != 0 || realpath(path, resolved) == NULL)
		return false;
	char *contents = strstr(resolved, ".app/Contents/MacOS/");
	if (contents != NULL)
		contents[4] = '\0';
	return strlcpy(out, resolved, size) < size;
}

/* The entitlements the profile asks about, as libsandbox's ENTITLEMENT:
   parameters: booleans as "true", arrays of strings comma-separated. */
struct parameters {
	const char *list[256];
	size_t count;
};

static void
add(struct parameters *p, const char *name, const char *value)
{
	if (p->count + 2 < sizeof(p->list) / sizeof(p->list[0])) {
		p->list[p->count++] = name;
		p->list[p->count++] = value;
		p->list[p->count] = NULL;
	}
}

static void
add_entitlements(struct parameters *p, xpc_object_t entitlements)
{
	xpc_dictionary_apply(entitlements, ^bool(const char *key, xpc_object_t value) {
		if (strncmp(key, "com.apple.security.", strlen("com.apple.security.")) != 0)
			return true;
		char *name = NULL, *text = NULL;
		if (xpc_get_type(value) == XPC_TYPE_BOOL) {
			if (!xpc_bool_get_value(value))
				return true;
			text = strdup("true");
		} else if (xpc_get_type(value) == XPC_TYPE_STRING) {
			text = strdup(xpc_string_get_string_ptr(value));
		} else if (xpc_get_type(value) == XPC_TYPE_ARRAY) {
			size_t length = 1;
			for (size_t i = 0; i < xpc_array_get_count(value); i++) {
				const char *s = xpc_array_get_string(value, i);
				length += s ? strlen(s) + 1 : 0;
			}
			/* Paths are matched resolved, as the kernel sees them. */
			bool paths = strstr(key, ".absolute-path.") != NULL;
			length += paths ? xpc_array_get_count(value) * PATH_MAX : 0;
			text = calloc(1, length);
			for (size_t i = 0; text && i < xpc_array_get_count(value); i++) {
				const char *s = xpc_array_get_string(value, i);
				char resolved[PATH_MAX];
				if (paths && s && realpath(s, resolved) != NULL)
					s = resolved;
				/* (a value with a comma would split; it's left out) */
				if (s == NULL || strchr(s, ','))
					continue;
				if (text[0])
					strlcat(text, ",", length);
				strlcat(text, s, length);
			}
		}
		if (text != NULL && asprintf(&name, "ENTITLEMENT:%s", key) > 0)
			add(p, name, text);
		else
			free(text);
		return true;
	});
}

void
_libsecinit_initializer(void)
{
	xpc_object_t entitlements = xpc_copy_entitlements_for_self();
	if (entitlements == NULL)
		return;
	if (xpc_get_type(entitlements) != XPC_TYPE_DICTIONARY ||
	    !xpc_dictionary_get_bool(entitlements, APP_SANDBOX)) {
		xpc_release(entitlements);
		return;
	}
	/* A sandboxed app's child keeps the sandbox it inherited. */
	if (sandbox_check(getpid(), NULL, 0) == 1) {
		xpc_release(entitlements);
		return;
	}
	if (xpc_dictionary_get_bool(entitlements, INHERIT))
		fail("com.apple.security.inherit, but no parent sandbox", NULL);

	char *identifier = signing_identifier();
	if (identifier == NULL)
		fail("no code-signing identifier", NULL);
	struct passwd *pw = getpwuid(getuid());
	char home[PATH_MAX], data[PATH_MAX], container[PATH_MAX], bundle[PATH_MAX];
	if (pw == NULL || pw->pw_dir == NULL || realpath(pw->pw_dir, home) == NULL)
		fail("no home folder", NULL);
	if (!make_container(home, identifier, data, sizeof(data)) || realpath(data, container) == NULL)
		fail("can't make the container", strerror(errno));
	if (!application_bundle(bundle, sizeof(bundle)))
		fail("can't find the app's bundle", NULL);

	struct parameters p = { .count = 0 };
	add(&p, "HOME_DIRECTORY", home);
	add(&p, "APPLICATION_CONTAINER", container);
	add(&p, "APPLICATION_BUNDLE", bundle);
	add_entitlements(&p, entitlements);
	xpc_release(entitlements);

	/* The app's home is its container. */
	char tmp[PATH_MAX];
	snprintf(tmp, sizeof(tmp), "%s/tmp/", container);
	setenv("HOME", container, 1);
	setenv("CFFIXED_USER_HOME", container, 1);
	setenv("TMPDIR", tmp, 1);

	char *error = NULL;
	if (sandbox_init_with_parameters("(version 1)(import \"application.sb\")", 0, p.list, &error) != 0)
		fail("can't apply the App Sandbox", error);
	free(identifier);
}

/* The rest of macOS's interface, for containers' file operations (made through
   containermanagerd there). */
int libsecinit_delete_all_data_container_content_for_current_user(void) { return EPERM; }
int libsecinit_fileoperation_save(void) { return EPERM; }
int libsecinit_fileoperation_set_attributes(void) { return EPERM; }
int libsecinit_fileoperation_symlink(void) { return EPERM; }

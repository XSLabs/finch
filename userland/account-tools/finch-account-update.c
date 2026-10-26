/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-account-update: changes a local account's fields for a caller who
 * isn't root, as macOS's opendirectoryd does for the local node. Finch's
 * OpenDirectory runs it (ODRecordSynchronize, for chpass, chsh and chfn);
 * installed setuid root.
 *
 *   finch-account-update NAME uid=N gid=N gecos=TEXT home=PATH shell=PATH
 *   finch-account-update --verify
 *
 * --verify only checks the credentials (ODRecordSetNodeCredentials and
 * ODRecordVerifyPassword, which can't read password hashes as anyone but root).
 *
 * Standard input: the name and password the caller authenticated with, each
 * ending in a NUL. The rules, by who the caller is (the real uid):
 *
 *   root                      any of these fields
 *   an administrator's        any of these fields
 *     password (group admin)
 *   the account's own user,   GECOS (full name, office, phones), and the
 *     with its own password   shell, when the old and new shells are both
 *                             in /etc/shells
 *
 * Exit status: 0 changed, 1 invalid or failed, 2 not authorized.
 */
#include "account_tools.h"

#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ADMIN_GROUP "admin"

static int
usage(void)
{
	fprintf(stderr, "usage: finch-account-update name [uid=N] [gid=N] [gecos=TEXT] [home=PATH] [shell=PATH]\n"
	    "       finch-account-update --verify\n");
	return 1;
}

static int
denied(const char *why)
{
	fprintf(stderr, "finch-account-update: %s\n", why);
	return 2;
}

static bool
parse_id(const char *text, uint32_t *out)
{
	char *end;
	if (!*text || *text == '-')
		return false;
	errno = 0;
	unsigned long v = strtoul(text, &end, 10);
	if (errno || *end || v >= UINT32_MAX - 1U)
		return false;
	*out = (uint32_t)v;
	return true;
}

/* A shell listed in /etc/shells. */
static bool
approved_shell(const char *shell)
{
	bool found = false;
	const char *s;
	setusershell();
	while ((s = getusershell()) != NULL) {
		if (strcmp(s, shell) == 0) {
			found = true;
			break;
		}
	}
	endusershell();
	return found;
}

static bool
in_admin_group(const struct passwd *pw)
{
	struct group *g = getgrnam(ADMIN_GROUP);
	if (g == NULL)
		return false;
	if (pw->pw_gid == g->gr_gid)
		return true;
	for (char **m = g->gr_mem; m && *m; m++)
		if (strcmp(*m, pw->pw_name) == 0)
			return true;
	return false;
}

/* Up to two NUL-terminated strings from standard input. */
static void
read_credentials(char *name, size_t name_size, char *password, size_t password_size)
{
	char buffer[AT_PASSWORD_MAX + 512];
	size_t used = 0;
	ssize_t n;
	while (used < sizeof(buffer) && (n = read(STDIN_FILENO, buffer + used, sizeof(buffer) - used)) > 0)
		used += (size_t)n;
	name[0] = password[0] = '\0';
	const char *end = memchr(buffer, '\0', used);
	if (end != NULL) {
		strlcpy(name, buffer, name_size);
		size_t rest = used - (size_t)(end + 1 - buffer);
		const char *pass_end = memchr(end + 1, '\0', rest);
		if (pass_end != NULL)
			strlcpy(password, end + 1, password_size);
	}
	at_secure_clear(buffer, sizeof(buffer));
}

int
main(int argc, char *argv[])
{
	if (argc == 2 && strcmp(argv[1], "--verify") == 0) {
		char auth_name[256], password[AT_PASSWORD_MAX + 1];
		read_credentials(auth_name, sizeof(auth_name), password, sizeof(password));
		struct passwd *auth = auth_name[0] ? getpwnam(auth_name) : NULL;
		bool verified = auth != NULL && auth->pw_passwd != NULL && at_password_verify(password, auth->pw_passwd);
		at_secure_clear(password, sizeof(password));
		if (!verified) {
			sleep(1);
			return 2;
		}
		return 0;
	}
	if (argc < 3)
		return usage();
	const char *name = argv[1];
	struct at_user_update update = {0};
	for (int i = 2; i < argc; i++) {
		char *value = strchr(argv[i], '=');
		if (value == NULL)
			return usage();
		*value++ = '\0';
		if (strcmp(argv[i], "uid") == 0 && parse_id(value, &update.uid))
			update.set_uid = true;
		else if (strcmp(argv[i], "gid") == 0 && parse_id(value, &update.gid))
			update.set_gid = true;
		else if (strcmp(argv[i], "gecos") == 0)
			update.gecos = value;
		else if (strcmp(argv[i], "home") == 0)
			update.home = value;
		else if (strcmp(argv[i], "shell") == 0)
			update.shell = value;
		else
			return usage();
	}

	char auth_name[256], password[AT_PASSWORD_MAX + 1];
	read_credentials(auth_name, sizeof(auth_name), password, sizeof(password));
	struct passwd *target = getpwnam(name);
	if (target == NULL) {
		at_secure_clear(password, sizeof(password));
		fprintf(stderr, "finch-account-update: no account named %s\n", name);
		return 1;
	}
	uid_t target_uid = target->pw_uid;
	gid_t target_gid = target->pw_gid;
	char target_home[1100], target_shell[1100];
	strlcpy(target_home, target->pw_dir ? target->pw_dir : "", sizeof(target_home));
	strlcpy(target_shell, target->pw_shell ? target->pw_shell : "", sizeof(target_shell));

	uid_t caller = getuid();
	if (caller != 0) {
		/* The password the caller gave, checked here as root. */
		struct passwd *auth = auth_name[0] ? getpwnam(auth_name) : NULL;
		bool verified = auth != NULL && auth->pw_passwd != NULL && at_password_verify(password, auth->pw_passwd);
		at_secure_clear(password, sizeof(password));
		if (!verified) {
			sleep(1);
			return denied("the credentials could not be verified");
		}
		if (!in_admin_group(auth)) {
			if (strcmp(auth->pw_name, name) != 0 || target_uid != caller)
				return denied("only an administrator may change another account");
			if ((update.set_uid && update.uid != target_uid) || (update.set_gid && update.gid != target_gid) ||
			    (update.home && strcmp(update.home, target_home) != 0))
				return denied("only an administrator may change an account's ids or home");
			if (update.shell && strcmp(update.shell, target_shell) != 0 &&
			    (!approved_shell(target_shell) || !approved_shell(update.shell)))
				return denied("the shell must be one listed in /etc/shells");
		}
	}
	at_secure_clear(password, sizeof(password));

	char message[256] = "";
	struct at_store store = { .directory_fd = -1 };
	int result = at_store_open_default(&store, message, sizeof(message)) == 0 &&
	    at_store_update_user(&store, name, &update, message, sizeof(message)) == 0 ? 0 : 1;
	at_store_close(&store);
	if (result != 0)
		fprintf(stderr, "finch-account-update: %s\n", message[0] ? message : "the account could not be changed");
	return result;
}

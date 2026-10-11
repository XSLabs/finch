/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * accountctl changes only a directory that the running user owns. It has no
 * default folder, so an accidental run cannot touch the host's account files.
 */

#include "account_tools.h"

#include <errno.h>
#include <limits.h>
#include <readpassphrase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Keep one extra input byte so readpassphrase truncation cannot turn an
 * overlong password into an accepted maximum-length password. */
#define PROMPT_MAX (AT_PASSWORD_MAX + 2)

static void
usage(FILE *stream)
{
	fputs("Usage:\n"
	    "  accountctl -d ACCOUNT_FOLDER create NAME UID GID GECOS HOME SHELL\n"
	    "  accountctl -d ACCOUNT_FOLDER change NAME\n"
	    "\nACCOUNT_FOLDER must contain master.passwd, passwd, and group.\n",
	    stream);
}

static int
parse_id(const char *text, unsigned long max, unsigned long *value)
{
	if (!text || !text[0])
		return -1;
	for (const char *p = text; *p; ++p)
		if (*p < '0' || *p > '9')
			return -1;
	char *end;
	errno = 0;
	unsigned long parsed = strtoul(text, &end, 10);
	if (errno || *end || parsed > max)
		return -1;
	*value = parsed;
	return 0;
}

static int
read_password(const char *prompt, char *buffer)
{
	if (!readpassphrase(prompt, buffer, PROMPT_MAX, RPP_REQUIRE_TTY)) {
		fputs("accountctl: could not read a password from the terminal\n", stderr);
		return -1;
	}
	if (strlen(buffer) > AT_PASSWORD_MAX) {
		fputs("accountctl: password is too long\n", stderr);
		at_secure_clear(buffer, PROMPT_MAX);
		return -1;
	}
	return 0;
}

static int
read_new_password(char *password)
{
	char confirm[PROMPT_MAX] = {0};
	if (read_password("New password: ", password) != 0 ||
	    read_password("Repeat new password: ", confirm) != 0)
		goto fail;
	if (strcmp(password, confirm) != 0) {
		fputs("accountctl: the two passwords did not match\n", stderr);
		goto fail;
	}
	if (!at_password_is_acceptable(password)) {
		fprintf(stderr, "accountctl: use a password from %d to %d bytes long\n",
		    AT_PASSWORD_MIN, AT_PASSWORD_MAX);
		goto fail;
	}
	at_secure_clear(confirm, sizeof(confirm));
	return 0;
fail:
	at_secure_clear(password, PROMPT_MAX);
	at_secure_clear(confirm, sizeof(confirm));
	return -1;
}

int
main(int argc, char **argv)
{
	const char *directory = NULL;
	int option;
	while ((option = getopt(argc, argv, "d:h")) != -1) {
		switch (option) {
		case 'd': directory = optarg; break;
		case 'h': usage(stdout); return 0;
		default: usage(stderr); return 2;
		}
	}
	if (!directory || optind >= argc) {
		usage(stderr);
		return 2;
	}
	const char *action = argv[optind++];
	struct at_store store = {.directory_fd = -1};
	char error[256] = {0};
	if (at_store_open(&store, directory, error, sizeof(error)) != 0) {
		fprintf(stderr, "accountctl: %s\n", error);
		return 1;
	}
	int result = 1;
	if (strcmp(action, "create") == 0) {
		unsigned long uid, gid;
		char password[PROMPT_MAX] = {0};
		if (geteuid() != 0) {
			fputs("accountctl: creating an account requires root access\n", stderr);
			goto finish;
		}
		if (argc - optind != 6 || parse_id(argv[optind + 1], INT_MAX, &uid) != 0 ||
		    parse_id(argv[optind + 2], INT_MAX, &gid) != 0) {
			usage(stderr);
			goto finish;
		}
		if (read_new_password(password) != 0)
			goto finish;
		result = at_store_create_user(&store, argv[optind], (uid_t)uid,
		    (gid_t)gid, argv[optind + 3], argv[optind + 4], argv[optind + 5],
		    password, error, sizeof(error)) == 0 ? 0 : 1;
		at_secure_clear(password, sizeof(password));
	} else if (strcmp(action, "change") == 0) {
		char old_password[PROMPT_MAX] = {0};
		char new_password[PROMPT_MAX] = {0};
		if (argc - optind != 1) {
			usage(stderr);
			at_secure_clear(old_password, sizeof(old_password));
			at_secure_clear(new_password, sizeof(new_password));
			goto finish;
		}
		uid_t actor_uid = getuid();
		bool root_override = actor_uid == 0;
		if (!root_override && read_password("Current password: ", old_password) != 0) {
			at_secure_clear(old_password, sizeof(old_password));
			at_secure_clear(new_password, sizeof(new_password));
			goto finish;
		}
		if (read_new_password(new_password) != 0) {
			at_secure_clear(old_password, sizeof(old_password));
			at_secure_clear(new_password, sizeof(new_password));
			goto finish;
		}
		result = at_store_change_password(&store, argv[optind], actor_uid,
		    root_override, root_override ? NULL : old_password, new_password,
		    error, sizeof(error)) == 0 ? 0 : 1;
		at_secure_clear(old_password, sizeof(old_password));
		at_secure_clear(new_password, sizeof(new_password));
	} else {
		usage(stderr);
		result = 2;
	}
finish:
	if (result != 0 && error[0])
		fprintf(stderr, "accountctl: %s\n", error);
	at_store_close(&store);
	return result;
}

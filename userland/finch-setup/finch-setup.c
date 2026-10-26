/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-setup: making a new system's first account, at the console.
 *
 * finch-init runs it in place of login in normal mode. When the system has a
 * person's account already (a uid of 501 or more with a password), it hands
 * the console to login at once. Otherwise it asks for a full name, an account
 * name, a password and a computer name, makes the account an administrator
 * (staff, admin) with a home holding macOS's standard folders, sets the names
 * and then hands over to login, where the new account can log in.
 *
 * It runs as root, from finch-init only; nothing else starts it.
 */
#include "account_tools.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <readpassphrase.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define LOGIN "/usr/bin/login"
#define SCUTIL "/usr/sbin/scutil"
#define FIRST_UID 501
#define STAFF_GID 20
#define ACCOUNT_NAME_MAX 31

extern char **environ;

/* An account a person logs in with: a regular uid and a password set. */
static bool
has_person_account(void)
{
	struct passwd *pw;
	bool found = false;

	setpwent();
	while ((pw = getpwent()) != NULL) {
		if (pw->pw_uid >= FIRST_UID && pw->pw_uid < 0xfffe &&
		    strcmp(pw->pw_shell, "/usr/bin/false") != 0) {
			found = true;
			break;
		}
	}
	endpwent();
	return found;
}

static void
hand_over_to_login(void)
{
	char *argv[] = { "login", NULL };
	execv(LOGIN, argv);
	fprintf(stderr, "finch-setup: can't start login: %s\n", strerror(errno));
	exit(1);
}

static bool
ask(const char *prompt, const char *suggestion, char *out, size_t size)
{
	if (suggestion && *suggestion) {
		printf("%s [%s]: ", prompt, suggestion);
	} else {
		printf("%s: ", prompt);
	}
	fflush(stdout);
	if (fgets(out, (int)size, stdin) == NULL) {
		return false;
	}
	out[strcspn(out, "\r\n")] = '\0';
	/* trim spaces at both ends */
	char *start = out;
	while (isspace((unsigned char)*start)) {
		start++;
	}
	memmove(out, start, strlen(start) + 1);
	for (size_t n = strlen(out); n > 0 && isspace((unsigned char)out[n - 1]); n--) {
		out[n - 1] = '\0';
	}
	if (*out == '\0' && suggestion) {
		strlcpy(out, suggestion, size);
	}
	return true;
}

/* macOS's account names: lowercase letters, digits, '_', '-' and '.', starting
   with a letter or '_'. */
static bool
valid_account_name(const char *s)
{
	size_t n = strlen(s);
	if (n == 0 || n > ACCOUNT_NAME_MAX || !(islower((unsigned char)s[0]) || s[0] == '_')) {
		return false;
	}
	for (size_t i = 0; i < n; i++) {
		if (!islower((unsigned char)s[i]) && !isdigit((unsigned char)s[i]) &&
		    s[i] != '_' && s[i] != '-' && s[i] != '.') {
			return false;
		}
	}
	return true;
}

/* "Ada Lovelace" -> "adalovelace", as macOS suggests. */
static void
suggest_account_name(const char *full, char *out, size_t size)
{
	size_t n = 0;
	for (const char *p = full; *p && n + 1 < size && n < ACCOUNT_NAME_MAX; p++) {
		if (isalnum((unsigned char)*p)) {
			out[n++] = (char)tolower((unsigned char)*p);
		}
	}
	out[n] = '\0';
	if (n == 0 || isdigit((unsigned char)out[0])) {
		strlcpy(out, "user", size);
	}
}

/* "Ada's Finch" -> "Adas-Finch", for the local host name. */
static void
local_host_name(const char *computer, char *out, size_t size)
{
	size_t n = 0;
	bool dash = false;
	for (const char *p = computer; *p && n + 1 < size && n < 63; p++) {
		if (isalnum((unsigned char)*p)) {
			out[n++] = *p;
			dash = false;
		} else if (isspace((unsigned char)*p) && !dash && n > 0) {
			out[n++] = '-';
			dash = true;
		}
	}
	while (n > 0 && out[n - 1] == '-') {
		n--;
	}
	out[n] = '\0';
	if (n == 0) {
		strlcpy(out, "Finch", size);
	}
}

static uid_t
free_uid(void)
{
	uid_t uid = FIRST_UID;
	while (getpwuid(uid) != NULL) {
		uid++;
	}
	return uid;
}

/* Where homes are made: the real folder /Users leads to, less "/Users". */
static bool
home_root(char *out, size_t size)
{
	char real[PATH_MAX];
	if (realpath("/Users", real) == NULL) {
		return false;
	}
	size_t n = strlen(real);
	if (n < 6 || strcmp(real + n - 6, "/Users") != 0) {
		return false;
	}
	real[n - 6] = '\0';
	strlcpy(out, real[0] ? real : "/", size);
	return true;
}

static int
run(char *const argv[])
{
	pid_t pid;
	int status = 0;
	if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) {
		return -1;
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static bool
read_password(char *out, size_t size)
{
	char again[AT_PASSWORD_MAX + 1];
	for (;;) {
		if (readpassphrase("Password: ", out, size, RPP_REQUIRE_TTY) == NULL) {
			return false;
		}
		if (!at_password_is_acceptable(out)) {
			printf("Use at least %d characters.\n", AT_PASSWORD_MIN);
			continue;
		}
		if (readpassphrase("Repeat password: ", again, sizeof(again), RPP_REQUIRE_TTY) == NULL) {
			at_secure_clear(out, size);
			return false;
		}
		bool same = strcmp(out, again) == 0;
		at_secure_clear(again, sizeof(again));
		if (same) {
			return true;
		}
		printf("The passwords don't match. Try again.\n");
	}
}

int
main(void)
{
	char full[256], account[64], suggested[64], computer[256], local[64];
	char password[AT_PASSWORD_MAX + 1], root[PATH_MAX], home[PATH_MAX], error[256];

	if (getuid() != 0) {
		fprintf(stderr, "finch-setup: run by finch-init only\n");
		return 1;
	}
	if (has_person_account()) {
		hand_over_to_login();
	}

	printf("\nWelcome to Finch.\n\n"
	    "This computer has no accounts yet. Make the first one now: it will be an\n"
	    "administrator, able to change system settings and make more accounts.\n\n");
	do {
		if (!ask("Full name", NULL, full, sizeof(full))) {
			return 1;
		}
	} while (full[0] == '\0' || strchr(full, ':') != NULL);
	suggest_account_name(full, suggested, sizeof(suggested));
	for (;;) {
		if (!ask("Account name", suggested, account, sizeof(account))) {
			return 1;
		}
		if (!valid_account_name(account)) {
			printf("Use lowercase letters, digits, '_', '-' or '.', starting with a letter.\n");
		} else if (getpwnam(account) != NULL) {
			printf("That name is taken. Choose another.\n");
		} else {
			break;
		}
	}
	if (!read_password(password, sizeof(password))) {
		return 1;
	}
	char default_computer[300];
	snprintf(default_computer, sizeof(default_computer), "%s's Finch", full);
	if (!ask("Computer name", default_computer, computer, sizeof(computer))) {
		at_secure_clear(password, sizeof(password));
		return 1;
	}

	printf("\nMaking your account...\n");
	struct at_store store = { .directory_fd = -1 };
	snprintf(home, sizeof(home), "/Users/%s", account);
	int failed = !home_root(root, sizeof(root));
	if (failed) {
		snprintf(error, sizeof(error), "there's no folder for homes at /Users");
	} else {
		failed = at_store_open_default(&store, error, sizeof(error)) != 0 ||
		    at_store_create_user_with_home_root(&store, account, free_uid(), STAFF_GID, full,
		        home, "/bin/zsh", password, root, error, sizeof(error)) != 0 ||
		    at_store_add_group_member(&store, "admin", account, error, sizeof(error)) != 0;
	}
	at_secure_clear(password, sizeof(password));
	if (store.directory_fd >= 0) {
		at_store_close(&store);
	}
	if (failed) {
		printf("Your account couldn't be made: %s\n", error);
		return 1;	/* finch-init starts setup again */
	}
	local_host_name(computer, local, sizeof(local));
	char *set_computer[] = { SCUTIL, "--set", "ComputerName", computer, NULL };
	char *set_local[] = { SCUTIL, "--set", "LocalHostName", local, NULL };
	if (run(set_computer) != 0 || run(set_local) != 0) {
		printf("(The computer name couldn't be set; set it later with scutil.)\n");
	}
	printf("Done. Log in as %s.\n\n", account);
	fflush(stdout);
	hand_over_to_login();
}

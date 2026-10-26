/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Guest-only test of chpass, chsh and chfn over Finch's OpenDirectory and its
 * account helper (finch-account-update), run as root by
 * tools/vm/test-chpass.sh on the persistent VM. It makes three accounts and
 * changes them as their own user, as another user, as an administrator and as
 * root, checking the account files after each. Don't run it on the host.
 */
#include "account_tools.h"

#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#define USER "chptestuser"
#define OTHER "chptestother"
#define ADMIN "chptestadmin"
#define USER_PASSWORD "Finch chpass user 2026"
#define OTHER_PASSWORD "Finch chpass other 2026"
#define ADMIN_PASSWORD "Finch chpass admin 2026"
/* The editor chpass runs is this program (a script in /tmp isn't allowed to run). */
#define EDITOR "/usr/local/bin/finch-chpass-test"
#define EDIT_VARIABLE "FINCH_CHPASS_EDIT"

static int failures, checks;
static char edit_setting[512] = EDIT_VARIABLE "=";

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { \
		failures++; \
		printf("FAIL: %s\n", what); \
	} \
} while (0)

static void
make_account(const char *name, uid_t uid, const char *password, bool admin)
{
	struct at_store store = { .directory_fd = -1 };
	char error[256];
	if (getpwnam(name) != NULL)
		return;
	if (at_store_open_default(&store, error, sizeof(error)) != 0 ||
	    at_store_create_user(&store, name, uid, 20, name, "/var/empty", "/bin/sh", password, error,
	    sizeof(error)) != 0 ||
	    (admin && at_store_add_group_member(&store, "admin", name, error, sizeof(error)) != 0)) {
		printf("can't make %s: %s\n", name, error);
		exit(1);
	}
	at_store_close(&store);
}

/*
 * Run a program as a user (or root), with stdin from text and no controlling
 * terminal, so getpass(3) reads the password from stdin. Its exit status.
 */
static int
run_as_bytes(const char *user, const char *text, size_t length, char *const argv[])
{
	int input[2];
	if (pipe(input) != 0)
		return -1;
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		close(input[1]);
		dup2(input[0], STDIN_FILENO);
		close(input[0]);
		setsid();
		if (user != NULL) {
			struct passwd *pw = getpwnam(user);
			if (pw == NULL || initgroups(user, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 ||
			    setuid(pw->pw_uid) != 0)
				_exit(126);
		}
		char *envp[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "EDITOR=" EDITOR, "TMPDIR=/tmp", edit_setting, NULL };
		execve(argv[0], argv, envp);
		_exit(127);
	}
	close(input[0]);
	if (text)
		(void)!write(input[1], text, length);
	close(input[1]);
	int status;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static int
run_as(const char *user, const char *text, char *const argv[])
{
	return run_as_bytes(user, text, text ? strlen(text) : 0, argv);
}

/* The helper's credentials on its input: a name and a password, each ending in a NUL. */
#define HELPER_INPUT(name, password) name "\0" password, sizeof(name "\0" password)

/* An account's field now, read from the files. */
static char *
field(const char *name, char which)
{
	static char value[1100];
	struct passwd *pw = getpwnam(name);
	if (pw == NULL)
		return "(no account)";
	switch (which) {
	case 's': strlcpy(value, pw->pw_shell, sizeof(value)); break;
	case 'g': strlcpy(value, pw->pw_gecos, sizeof(value)); break;
	case 'h': strlcpy(value, pw->pw_dir, sizeof(value)); break;
	case 'u': snprintf(value, sizeof(value), "%u", pw->pw_uid); break;
	}
	return value;
}

/* What the editor changes: "PREFIX=VALUE|PREFIX=VALUE", each line starting
   with PREFIX becoming "PREFIX VALUE". */
static void
set_editor(const char *changes)
{
	snprintf(edit_setting, sizeof(edit_setting), EDIT_VARIABLE "=%s", changes);
}

/* As chpass's editor: rewrite the file it gives. */
static int
edit(const char *path, char *changes)
{
	FILE *f = fopen(path, "r");
	if (f == NULL)
		return 1;
	char text[8192] = "", line[1024];
	while (fgets(line, sizeof(line), f)) {
		char copy[512];
		strlcpy(copy, changes, sizeof(copy));
		for (char *rest = copy, *change; (change = strsep(&rest, "|")) != NULL;) {
			char *value = strchr(change, '=');
			if (value && !strncmp(line, change, (size_t)(value - change))) {
				*value = '\0';
				snprintf(line, sizeof(line), "%s %s\n", change, value + 1);
				break;
			}
		}
		strlcat(text, line, sizeof(text));
	}
	fclose(f);
	f = fopen(path, "w");
	if (f == NULL)
		return 1;
	fputs(text, f);
	fflush(f);
	/* chpass sees a change only by a later modification time. */
	struct stat st;
	if (fstat(fileno(f), &st) == 0) {
		struct timeval times[2] = { { st.st_atime, 0 }, { st.st_mtime + 2, 0 } };
		futimes(fileno(f), times);
	}
	return fclose(f) != 0;
}

int
main(int argc, char *argv[])
{
	if (argc == 2 && getenv(EDIT_VARIABLE))
		return edit(argv[1], getenv(EDIT_VARIABLE));
	if (getuid() != 0) {
		printf("run as root\n");
		return 2;
	}
	make_account(USER, 6521, USER_PASSWORD, false);
	make_account(OTHER, 6522, OTHER_PASSWORD, false);
	make_account(ADMIN, 6523, ADMIN_PASSWORD, true);
	struct stat st;
	CHECK(stat("/usr/libexec/finch-account-update", &st) == 0 && st.st_uid == 0 && (st.st_mode & 04000),
	    "finch-account-update is setuid root");

	/* A user's own shell. */
	CHECK(run_as(USER, USER_PASSWORD "\n", (char *[]){ "/usr/bin/chsh", "-s", "/bin/bash", NULL }) == 0 &&
	    !strcmp(field(USER, 's'), "/bin/bash"), "chsh -s /bin/bash with the user's password");
	CHECK(run_as(USER, USER_PASSWORD "\n", (char *[]){ "/usr/bin/chsh", "-s", "/usr/bin/false", NULL }) != 0 &&
	    !strcmp(field(USER, 's'), "/bin/bash"), "a shell not in /etc/shells is refused");
	CHECK(run_as(USER, "wrong password 2026\n", (char *[]){ "/usr/bin/chsh", "-s", "/bin/zsh", NULL }) != 0 &&
	    !strcmp(field(USER, 's'), "/bin/bash"), "a wrong password changes nothing");

	/* Their own finger information, through the editor. */
	set_editor("Full Name:=Grace Hopper|Office Location:=Room 7");
	CHECK(run_as(USER, USER_PASSWORD "\n", (char *[]){ "/usr/bin/chfn", NULL }) == 0 &&
	    !strcmp(field(USER, 'g'), "Grace Hopper,Room 7"), "chfn changes the full name and office");

	/* Not someone else's, nor their own ids or home. */
	CHECK(run_as(USER, USER_PASSWORD "\n", (char *[]){ "/usr/bin/chsh", "-s", "/bin/zsh", OTHER, NULL }) != 0 &&
	    !strcmp(field(OTHER, 's'), "/bin/sh"), "another user's shell, with one's own password, is refused");
	CHECK(run_as_bytes(USER, HELPER_INPUT(USER, USER_PASSWORD), (char *[]){ "/usr/libexec/finch-account-update", USER, "uid=6600",
	    NULL }) == 2 && !strcmp(field(USER, 'u'), "6521"), "the helper refuses a user's own uid change");
	CHECK(run_as_bytes(USER, HELPER_INPUT(USER, USER_PASSWORD), (char *[]){ "/usr/libexec/finch-account-update", USER,
	    "home=/private/var/root", NULL }) == 2 && !strcmp(field(USER, 'h'), "/var/empty"),
	    "the helper refuses a user's own home change");
	CHECK(run_as_bytes(USER, HELPER_INPUT(USER, "wrong password 2026"), (char *[]){ "/usr/libexec/finch-account-update", USER,
	    "gecos=Nobody", NULL }) == 2 && !strcmp(field(USER, 'g'), "Grace Hopper,Room 7"),
	    "the helper refuses a wrong password");
	CHECK(run_as_bytes(USER, HELPER_INPUT(USER, USER_PASSWORD), (char *[]){ "/usr/libexec/finch-account-update", USER,
	    "gecos=Grace Hopper,Room 8", NULL }) == 0 && !strcmp(field(USER, 'g'), "Grace Hopper,Room 8"),
	    "the helper takes a user's own GECOS change with their password");
	CHECK(run_as_bytes(USER, HELPER_INPUT(OTHER, OTHER_PASSWORD), (char *[]){ "/usr/libexec/finch-account-update",
	    USER, "gecos=Mallory", NULL }) == 2 && !strcmp(field(USER, 'g'), "Grace Hopper,Room 8"),
	    "the helper refuses another ordinary user's password for this account");
	CHECK(run_as(USER, "", (char *[]){ "/usr/libexec/finch-account-update", OTHER, "shell=/bin/zsh", NULL }) == 2 &&
	    !strcmp(field(OTHER, 's'), "/bin/sh"), "the helper refuses no credentials");

	/* An administrator's password lets them change another account. */
	CHECK(run_as(USER, ADMIN_PASSWORD "\n", (char *[]){ "/usr/bin/chsh", "-u", ADMIN, "-s", "/bin/zsh", OTHER,
	    NULL }) == 0 && !strcmp(field(OTHER, 's'), "/bin/zsh"), "an administrator's password changes another account");

	/* Root: no password, and the ids and home too. */
	set_editor("Uid [#]:=6530|Home directory:=/Users/chptestother");
	CHECK(run_as(NULL, "", (char *[]){ "/usr/bin/chpass", OTHER, NULL }) == 0 && !strcmp(field(OTHER, 'u'), "6530") &&
	    !strcmp(field(OTHER, 'h'), "/Users/chptestother"), "root changes another account's uid and home");
	CHECK(run_as(NULL, "", (char *[]){ "/usr/bin/chsh", "-s", "/bin/sh", USER, NULL }) == 0 &&
	    !strcmp(field(USER, 's'), "/bin/sh"), "root changes a shell without a password");
	/* The public file has the change, and still no hash. */
	FILE *f = fopen("/etc/passwd", "r");
	char line[512];
	bool found = false;
	while (f && fgets(line, sizeof(line), f))
		if (!strncmp(line, OTHER ":", strlen(OTHER) + 1))
			found = strstr(line, ":*:6530:20:") != NULL;
	if (f)
		fclose(f);
	CHECK(found, "/etc/passwd shows the new uid without the hash");

	printf("chpass-test: %d checks, %d failed\n", checks, failures);
	return failures != 0;
}

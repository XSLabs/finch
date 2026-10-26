/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Guest-only test of Finch's authorization service (authd) through
 * Security.framework, run as root by the VM runner. It makes an administrator
 * and an ordinary account, then, as the ordinary account in child processes:
 * rights that need an administrator's password (none, wrong, the user's own,
 * an administrator's), allow and deny rules, a credential shared within the
 * session, an authorization handed to another process by its external form, a
 * privileged tool, and changing the rules. Don't run it on the host.
 */
#include "account_tools.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationDB.h>
#include <Security/AuthorizationTags.h>
#include <bsm/audit.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define ADMIN "authtestadmin"
#define USER "authtestuser"
#define ADMIN_PASSWORD "Finch admin password 2026"
#define USER_PASSWORD "Finch user password 2026"

static int failures, checks;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { \
		failures++; \
		printf("FAIL: %s\n", what); \
	} \
} while (0)

/* A status check that says what came back. */
#define STATUS(expr, want, what) do { \
	OSStatus got_ = (expr); \
	checks++; \
	if (got_ != (want)) { \
		failures++; \
		printf("FAIL: %s (status %d, expected %d)\n", what, (int)got_, (int)(want)); \
	} \
} while (0)

static OSStatus
copy_right(AuthorizationRef auth, const char *right, const char *user, const char *password,
    AuthorizationFlags flags)
{
	AuthorizationItem item = { right, 0, NULL, 0 };
	AuthorizationRights rights = { 1, &item };
	AuthorizationItem env[2] = {
		{ kAuthorizationEnvironmentUsername, user ? strlen(user) : 0, (void *)user, 0 },
		{ kAuthorizationEnvironmentPassword, password ? strlen(password) : 0, (void *)password, 0 },
	};
	AuthorizationEnvironment environment = { user ? 2 : 0, env };
	return AuthorizationCopyRights(auth, &rights, &environment, flags, NULL);
}

static void
make_account(const char *name, uid_t uid, const char *password, bool admin)
{
	struct at_store store = { .directory_fd = -1 };
	char error[256], home[128];
	snprintf(home, sizeof(home), "/var/empty");
	if (getpwnam(name) != NULL) {
		return;
	}
	if (at_store_open_default(&store, error, sizeof(error)) != 0 ||
	    at_store_create_user(&store, name, uid, 20, name, home, "/bin/sh", password, error, sizeof(error)) != 0 ||
	    (admin && at_store_add_group_member(&store, "admin", name, error, sizeof(error)) != 0)) {
		printf("can't make %s: %s\n", name, error);
		exit(1);
	}
	at_store_close(&store);
}

/* Become the ordinary account in this child. */
static void
become_user(void)
{
	struct passwd *pw = getpwnam(USER);
	if (pw == NULL || initgroups(USER, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 ||
	    setuid(pw->pw_uid) != 0) {
		printf("can't become %s: %s\n", USER, strerror(errno));
		_exit(2);
	}
}

static void
run_child(const char *name, void (*fn)(int), int arg)
{
	int pipefd[2];
	if (pipe(pipefd) != 0) {
		failures++;
		return;
	}
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		close(pipefd[0]);
		failures = checks = 0;
		become_user();
		fn(arg);
		int counts[2] = { checks, failures };
		fflush(stdout);
		write(pipefd[1], counts, sizeof(counts));
		_exit(0);
	}
	close(pipefd[1]);
	int counts[2] = { 0, 1 };
	ssize_t n = read(pipefd[0], counts, sizeof(counts));
	close(pipefd[0]);
	int status;
	waitpid(pid, &status, 0);
	if (n != sizeof(counts)) {
		printf("FAIL: %s: the child didn't finish\n", name);
		failures++;
		return;
	}
	checks += counts[0];
	failures += counts[1];
	printf("%s: %d checks, %d failed\n", name, counts[0], counts[1]);
}

static void
passwords(int unused)
{
	(void)unused;
	AuthorizationRef auth = NULL;
	CHECK(AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, &auth) == errAuthorizationSuccess && auth,
	    "AuthorizationCreate");
	const AuthorizationFlags extend = kAuthorizationFlagExtendRights;
	STATUS(copy_right(auth, "system.privilege.admin", NULL, NULL, kAuthorizationFlagDefaults), errAuthorizationDenied, "a right needing a password without extending rights is denied");
	STATUS(copy_right(auth, "system.privilege.admin", NULL, NULL, extend), errAuthorizationInteractionNotAllowed, "without a password or interaction: interaction not allowed");
	STATUS(copy_right(auth, "system.privilege.admin", ADMIN, "wrong password 12345", extend), errAuthorizationDenied, "a wrong password is denied");
	STATUS(copy_right(auth, "system.privilege.admin", USER, USER_PASSWORD, extend), errAuthorizationDenied, "a non-administrator's own password is denied");
	STATUS(copy_right(auth, "system.privilege.admin", ADMIN, ADMIN_PASSWORD, extend), errAuthorizationSuccess, "an administrator's password grants it");
	STATUS(copy_right(auth, "system.privilege.admin", NULL, NULL, kAuthorizationFlagDefaults), errAuthorizationSuccess, "the authorization holds the right afterwards");
	AuthorizationItemSet *info = NULL;
	CHECK(AuthorizationCopyInfo(auth, NULL, &info) == errAuthorizationSuccess && info && info->count == 1 &&
	    !strcmp(info->items[0].name, kAuthorizationEnvironmentUsername) &&
	    !strcmp(info->items[0].value, ADMIN), "its context names the administrator");
	if (info) {
		AuthorizationFreeItemSet(info);
	}
	STATUS(copy_right(auth, "system.burn", NULL, NULL, extend), errAuthorizationSuccess, "an allow rule");
	STATUS(copy_right(auth, "config.config.anything", ADMIN, ADMIN_PASSWORD, extend), errAuthorizationDenied,
	    "a deny rule, even with an administrator's password");
	/* The privileged tool runs as root. */
	FILE *pipe = NULL;
	char *args[] = { "-u", NULL };
	CHECK(AuthorizationExecuteWithPrivileges(auth, "/usr/bin/id", 0, args, &pipe) == errAuthorizationSuccess && pipe,
	    "AuthorizationExecuteWithPrivileges");
	char line[64] = "";
	if (pipe) {
		if (fgets(line, sizeof(line), pipe) == NULL) {
			line[0] = 0;
		}
		fclose(pipe);
	}
	CHECK(!strcmp(line, "0\n"), "the tool ran as root");
	AuthorizationFree(auth, kAuthorizationFlagDestroyRights);

	/* Without system.privilege.admin, no tool. */
	AuthorizationRef plain = NULL;
	AuthorizationCreate(NULL, NULL, 0, &plain);
	STATUS(AuthorizationExecuteWithPrivileges(plain, "/usr/bin/id", 0, args, NULL), errAuthorizationDenied,
	    "an authorization without the right can't run a tool as root");
	AuthorizationFree(plain, 0);
}

static void
shared(int unused)
{
	(void)unused;
	/* system.preferences: an administrator's credential is shared in the session. */
	AuthorizationRef first = NULL, second = NULL;
	AuthorizationCreate(NULL, NULL, 0, &first);
	AuthorizationCreate(NULL, NULL, 0, &second);
	STATUS(copy_right(first, "system.preferences", ADMIN, ADMIN_PASSWORD, kAuthorizationFlagExtendRights), errAuthorizationSuccess, "the first authorization gets system.preferences with a password");
	STATUS(copy_right(second, "system.preferences", NULL, NULL, kAuthorizationFlagExtendRights), errAuthorizationSuccess, "a second one in the session gets it from the shared credential");
	/* system.privilege.admin's credential isn't shared. */
	STATUS(copy_right(second, "system.privilege.admin", NULL, NULL, kAuthorizationFlagExtendRights), errAuthorizationInteractionNotAllowed, "a non-shared right still needs its own password");
	AuthorizationFree(first, 0);
	AuthorizationFree(second, 0);
}

static void
external_maker(int fd)
{
	AuthorizationRef auth = NULL;
	AuthorizationCreate(NULL, NULL, 0, &auth);
	STATUS(copy_right(auth, "system.privilege.admin", ADMIN, ADMIN_PASSWORD, kAuthorizationFlagExtendRights), errAuthorizationSuccess, "the maker gets the right");
	AuthorizationExternalForm form;
	STATUS(AuthorizationMakeExternalForm(auth, &form), errAuthorizationSuccess, "AuthorizationMakeExternalForm");
	write(fd, &form, sizeof(form));
	/* Keep it alive until the other process has used it. */
	char done;
	read(fd, &done, 1);
	AuthorizationFree(auth, 0);
}

static void
external_user(int fd)
{
	AuthorizationExternalForm form;
	CHECK(read(fd, &form, sizeof(form)) == sizeof(form), "the external form arrives");
	AuthorizationRef auth = NULL;
	CHECK(AuthorizationCreateFromExternalForm(&form, &auth) == errAuthorizationSuccess && auth,
	    "another process opens it from its external form");
	STATUS(copy_right(auth, "system.privilege.admin", NULL, NULL, kAuthorizationFlagDefaults), errAuthorizationSuccess, "and finds the right it holds, without a password");
	AuthorizationFree(auth, 0);
	write(fd, "x", 1);
	AuthorizationExternalForm bogus;
	memset(&bogus, 0x5a, sizeof(bogus));
	AuthorizationRef none = NULL;
	STATUS(AuthorizationCreateFromExternalForm(&bogus, &none), errAuthorizationInvalidRef,
	    "a made-up external form is refused");
}

static void
rules(int unused)
{
	(void)unused;
	AuthorizationRef auth = NULL;
	AuthorizationCreate(NULL, NULL, 0, &auth);
	const void *k[] = { CFSTR("class") }, *v[] = { CFSTR("allow") };
	CFDictionaryRef allow = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	/* config.add. is allow: anyone may add a right. */
	STATUS(AuthorizationRightSet(auth, "org.finch.test.right", allow, NULL, NULL, NULL), errAuthorizationSuccess,
	    "a new right is added");
	CFDictionaryRef got = NULL;
	CHECK(AuthorizationRightGet("org.finch.test.right", &got) == errAuthorizationSuccess && got,
	    "and read back");
	if (got) {
		CFRelease(got);
	}
	/* Changing it needs an administrator (config.modify.: authenticate-admin). */
	STATUS(AuthorizationRightSet(auth, "org.finch.test.right", allow, NULL, NULL, NULL), errAuthorizationDenied,
	    "changing it without an administrator is denied");
	STATUS(copy_right(auth, "config.modify.org.finch.test.right", ADMIN, ADMIN_PASSWORD,
	    kAuthorizationFlagExtendRights), errAuthorizationSuccess, "an administrator authorizes the change");
	STATUS(AuthorizationRightSet(auth, "org.finch.test.right", allow, NULL, NULL, NULL), errAuthorizationSuccess,
	    "then it changes");
	STATUS(copy_right(auth, "config.remove.org.finch.test.right", ADMIN, ADMIN_PASSWORD,
	    kAuthorizationFlagExtendRights), errAuthorizationSuccess, "and removing it is authorized");
	STATUS(AuthorizationRightRemove(auth, "org.finch.test.right"), errAuthorizationSuccess, "it's removed");
	STATUS(AuthorizationRightGet("org.finch.test.right", NULL), errAuthorizationDenied, "and gone");
	CFRelease(allow);
	AuthorizationFree(auth, 0);
}

int
main(void)
{
	if (getuid() != 0) {
		printf("run as root\n");
		return 2;
	}
	make_account(ADMIN, 6501, ADMIN_PASSWORD, true);
	make_account(USER, 6502, USER_PASSWORD, false);
	run_child("passwords and rules", passwords, 0);
	run_child("shared credentials", shared, 0);
	int sv[2];
	socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
	pid_t maker = fork();
	if (maker == 0) {
		close(sv[1]);
		become_user();
		failures = checks = 0;
		external_maker(sv[0]);
		_exit(failures != 0);
	}
	close(sv[0]);
	run_child("external form", external_user, sv[1]);
	int status;
	waitpid(maker, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "the maker's checks");
	/* authenticate-admin's credential is shared in a session, and the children
	   above left one in this session: the rules run in a new one. */
	auditinfo_addr_t session;
	memset(&session, 0, sizeof(session));
	CHECK(getaudit_addr(&session, sizeof(session)) == 0, "getaudit_addr");
	session.ai_asid = AU_ASSIGN_ASID;
	CHECK(setaudit_addr(&session, sizeof(session)) == 0, "a new audit session");
	run_child("the rules database", rules, 0);
	printf("authorization-test: %d checks, %d failed\n", checks, failures);
	return failures != 0;
}

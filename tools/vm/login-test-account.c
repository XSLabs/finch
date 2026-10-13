/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Add the disposable login used by login-init-smoke.exp.
 * This is only shipped in the separate VM test image.
 */
#include "account_tools.h"

#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define LOGIN_TEST_BOOT_ARG "finch_login_test=1"

static int
test_boot_argument_present(void)
{
	char boot_args[4096] = {0};
	size_t length = sizeof(boot_args) - 1;

	if (sysctlbyname("kern.bootargs", boot_args, &length, NULL, 0) != 0 ||
	    length >= sizeof(boot_args))
		return 0;
	boot_args[length] = '\0';

	const char *p = boot_args;
	while (*p) {
		while (*p == ' ' || *p == '\t' || *p == '\n')
			++p;
		const char *start = p;
		while (*p && *p != ' ' && *p != '\t' && *p != '\n')
			++p;
		size_t token_length = (size_t)(p - start);
		if (token_length == sizeof(LOGIN_TEST_BOOT_ARG) - 1 &&
		    memcmp(start, LOGIN_TEST_BOOT_ARG, token_length) == 0)
			return 1;
	}
	return 0;
}

static int
is_tmpfs(const char *path)
{
	struct statfs filesystem;
	return statfs(path, &filesystem) == 0 &&
	    strcmp(filesystem.f_fstypename, "tmpfs") == 0;
}

int
main(void)
{
	if (!test_boot_argument_present()) {
		fputs("finch-login-test-account: test boot flag is missing\n", stderr);
		return 1;
	}
	if (geteuid() != 0) {
		fputs("finch-login-test-account: must run as root\n", stderr);
		return 1;
	}
	if (!is_tmpfs("/private/etc") || !is_tmpfs("/usr/lib/pam")) {
		fputs("finch-login-test-account: account and PAM paths must be tmpfs\n",
		    stderr);
		return 1;
	}

	struct at_store store = {.directory_fd = -1};
	char error[256] = {0};
	if (at_store_open(&store, "/private/etc", error, sizeof(error)) != 0) {
		fprintf(stderr, "finch-login-test-account: %s\n", error);
		return 1;
	}

	int result = at_store_create_user(&store, "finchconsole", 6000, 20,
	    "Finch Console Smoke", "/private/var/rw/Users/finchconsole",
	    "/bin/sh", "Finch local password test 2026", error, sizeof(error));
	at_store_close(&store);
	if (result != 0) {
		fprintf(stderr, "finch-login-test-account: %s\n", error);
		return 1;
	}
	return 0;
}

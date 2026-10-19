/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CONSOLE_POLICY_H
#define FINCH_CONSOLE_POLICY_H

#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

enum finch_startup_path {
	FINCH_STARTUP_NORMAL,
	FINCH_STARTUP_RECOVERY,
	FINCH_STARTUP_BLOCKED,
};

/* A root console is a development opt-in, never a fallback for failed login.
 * Duplicate or malformed settings fail closed rather than depending on order. */
static inline bool
finch_development_console(const char *args)
{
	const char key[] = "finch_dev_console=";
	bool found = false;
	if (args == NULL) return false;
	while (*args) {
		while (isspace((unsigned char)*args)) args++;
		const char *end = args;
		while (*end && !isspace((unsigned char)*end)) end++;
		size_t length = (size_t)(end - args);
		if (length >= sizeof(key) - 1 && memcmp(args, key, sizeof(key) - 1) == 0) {
			if (found || length != sizeof(key) || args[sizeof(key) - 1] != '1') return false;
			found = true;
		}
		args = end;
	}
	return found;
}

static inline bool
finch_rc_startup_succeeded(bool script_present, pid_t child_pid, int wait_status)
{
	return script_present && child_pid > 0 && wait_status >= 0 &&
	    WIFEXITED(wait_status) && WEXITSTATUS(wait_status) == 0;
}

/* A failed rc must not start services or login. Only the existing explicit
 * development-console opt-in may turn that failure into a root recovery shell. */
static inline enum finch_startup_path
finch_startup_path_for_rc(bool rc_succeeded, bool development_console)
{
	if (rc_succeeded) return FINCH_STARTUP_NORMAL;
	return development_console ? FINCH_STARTUP_RECOVERY : FINCH_STARTUP_BLOCKED;
}

#endif

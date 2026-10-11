/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CONSOLE_POLICY_H
#define FINCH_CONSOLE_POLICY_H

#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

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

#endif

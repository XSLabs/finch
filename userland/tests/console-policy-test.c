/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../finch-init/console-policy.h"
#include <signal.h>
#include <stdio.h>

int
main(void)
{
	const char *rejected[] = { NULL, "", "-v", "finch_dev_console=0",
	    "not_finch_dev_console=1", "finch_dev_console=10", "finch_dev_console=",
	    "finch_dev_console=1x", "finch_dev_console=1 finch_dev_console=0",
	    "finch_dev_console=0 finch_dev_console=1",
	    "finch_dev_console=1 finch_dev_console=1" };
	const char *accepted[] = { "finch_dev_console=1", "-v finch_dev_console=1 serial=3",
	    "\tfinch_dev_console=1\n" };
	for (size_t i = 0; i < sizeof(rejected) / sizeof(rejected[0]); i++)
		if (finch_development_console(rejected[i])) return 1;
	for (size_t i = 0; i < sizeof(accepted) / sizeof(accepted[0]); i++)
		if (!finch_development_console(accepted[i])) return 1;
	if (!finch_rc_startup_succeeded(true, 42, 0) ||
	    finch_rc_startup_succeeded(false, 42, 0) ||
	    finch_rc_startup_succeeded(true, -1, 0) ||
	    finch_rc_startup_succeeded(true, 0, 0) ||
	    finch_rc_startup_succeeded(true, 42, -1) ||
	    finch_rc_startup_succeeded(true, 42, W_EXITCODE(1, 0)) ||
	    finch_rc_startup_succeeded(true, 42, SIGTERM))
		return 2;
	if (finch_startup_path_for_rc(true, false) != FINCH_STARTUP_NORMAL ||
	    finch_startup_path_for_rc(true, true) != FINCH_STARTUP_NORMAL ||
	    finch_startup_path_for_rc(false, true) != FINCH_STARTUP_RECOVERY ||
	    finch_startup_path_for_rc(false, false) != FINCH_STARTUP_BLOCKED)
		return 3;
	puts("console policy: success opens normal startup; every rc failure skips services and login");
	return 0;
}

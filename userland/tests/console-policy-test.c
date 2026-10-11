/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../finch-init/console-policy.h"
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
	puts("console policy: login by default; root shell requires explicit development opt-in");
	return 0;
}

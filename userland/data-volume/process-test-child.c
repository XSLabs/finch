/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <signal.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc != 2)
		return 90;
	if (strcmp(argv[1], "success") == 0)
		return 0;
	if (strcmp(argv[1], "nonzero") == 0)
		return 7;
	if (strcmp(argv[1], "signal") == 0) {
		(void)raise(SIGTERM);
		return 91;
	}
	if (strcmp(argv[1], "sleep") == 0) {
		(void)sleep(10);
		return 92;
	}
	return 93;
}

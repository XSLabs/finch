/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "data-volume-process.h"

#include <stdio.h>

static unsigned int checks;
static unsigned int failures;

#define CHECK(expression) do { \
	checks++; \
	if (!(expression)) { \
		fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
		failures++; \
	} \
} while (0)

static enum finch_dv_process_result
run_child(const char *path, const char *mode, unsigned int timeout_ms)
{
	char *arguments[] = { (char *)path, (char *)mode, NULL };
	return finch_dv_run_program(path, arguments, timeout_ms);
}

int
main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: process-test child-program\n");
		return 2;
	}
	CHECK(run_child(argv[1], "success", 2000) == FINCH_DV_PROCESS_OK);
	CHECK(run_child(argv[1], "nonzero", 2000) == FINCH_DV_PROCESS_NONZERO);
	CHECK(run_child(argv[1], "signal", 2000) == FINCH_DV_PROCESS_SIGNALED);
	CHECK(run_child(argv[1], "sleep", 100) == FINCH_DV_PROCESS_TIMEOUT);
	CHECK(run_child("/not/a/finch-test-program", "success", 2000) ==
	    FINCH_DV_PROCESS_SYSTEM_ERROR);
	if (failures) {
		fprintf(stderr, "%u of %u process checks failed\n", failures, checks);
		return 1;
	}
	printf("%u data-volume process checks passed\n", checks);
	return 0;
}

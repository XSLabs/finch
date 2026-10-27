/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Sparse/Solve.h implements its public interface as overloadable inline
 * functions over the _Sparse* entry points. macOS's libSparse also exports
 * each of them (under its overloadable, C++-mangled name) for callers that
 * cannot inline them, such as Swift. Finch compiles the same interface once
 * with external linkage: everything the header needs is included first, so
 * that only Solve.h itself is read with `static inline` turned into ordinary
 * definitions.
 */
#include <TargetConditionals.h>
#include <limits.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SPARSE_SOLVE_HEADER /* keep Accelerate.h from reading Solve.h yet */
#include <Accelerate/Accelerate.h>
#undef SPARSE_SOLVE_HEADER

/* The header's own check logs with os_log, whose macro needs a static local. */
void sparse_report(void (*report)(const char *), const char *format, ...) __attribute__((format(printf, 2, 3)));
#define SPARSE_PARAMETER_CHECK(condition, result, format, ...)              \
	do {                                                                \
		if (!(condition)) {                                         \
			sparse_report(options.reportError, format, ##__VA_ARGS__); \
			return result;                                      \
		}                                                           \
	} while (0)

#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#define static
#define inline
#include <vecLib/Sparse/Solve.h>
#undef static
#undef inline

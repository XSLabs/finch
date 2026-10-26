/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Questions for Finch's own sandbox policy (FinchSandbox, the kernel side of
 * libsandbox's compiled profiles). sandbox_check and its relatives ask it
 * first; only where it isn't registered (a macOS host, in the comparison
 * tests) do they ask Apple's Sandbox policy as before.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/param.h>
#include <unistd.h>

#include "finch_sandbox_abi.h"
#include "fsb_ops.h"
#include "fsb_format.h"
#include "internal.h"

#ifndef ENOPOLICY
#define ENOPOLICY 103
#endif

static const char *const op_names[FSB_OP_COUNT] = { FSB_OP_NAMES };

static uint32_t
op_index(const char *name)
{
	for (uint32_t i = 0; i < FSB_OP_COUNT; i++) {
		if (!strcmp(op_names[i], name))
			return i;
	}
	return FSB_NONE;
}

/* The FSB field a sandbox_check filter type names, or -1 for none Finch reads. */
static int
filter_field(uint32_t filter)
{
	switch (filter) {
	case 1: return FSB_F_PATH;
	case 2: return FSB_F_GLOBAL_NAME;
	case 3: return FSB_F_LOCAL_NAME;
	case 5: return FSB_F_RIGHT_NAME;
	case 6: return FSB_F_PREFERENCE_DOMAIN;
	case 7: return FSB_F_KEXT_BUNDLE_ID;
	case 9: return FSB_F_NOTIFICATION_NAME;
	case 10: return FSB_F_PATH;		/* a descriptor: its path */
	case 12: return FSB_F_XPC_SERVICE_NAME;
	case 13: return FSB_F_IOKIT_USER_CLIENT_CLASS;
	default: return -1;
	}
}

int
finch_sandbox_check(int64_t pid, uint32_t pidversion, const char *operation, uint32_t filter,
    uint64_t arg, int no_report)
{
	struct finch_sandbox_query_request req = {
		.version = FINCH_SANDBOX_ABI_VERSION, .size = sizeof(req),
		.target_pid = (int32_t)pid, .target_pidversion = pidversion,
		.field = 0xffffffffu, .flags = no_report || !operation ? FINCH_SANDBOX_QUERY_NO_REPORT : 0,
	};
	char path[MAXPATHLEN];
	int field = filter_field(filter);

	if (pid == getpid())
		req.target_pid = 0;
	/* An unknown operation is still asked as default, so a sandboxed process
	   is denied what its profile denies by default. */
	req.operation = operation ? op_index(operation) : FSB_OP_DEFAULT;
	if (req.operation == FSB_NONE)
		req.operation = FSB_OP_DEFAULT;
	if (field >= 0) {
		const char *s = (const char *)(uintptr_t)arg;
		if (filter == 10) {
			if (fcntl((int)arg, F_GETPATH, path) == -1)
				return -1;
			s = path;
		}
		if (s) {
			req.field = (uint32_t)field;
			req.value = (uint64_t)(uintptr_t)s;
			req.value_size = strlen(s);
		}
	}
	int saved_errno = errno;
	if (__sandbox_ms("FinchSandbox", FINCH_SANDBOX_CALL_QUERY, &req) != 0) {
		if (errno != ENOPOLICY)
			return -1;
		errno = saved_errno;	/* not registered: the caller asks Apple's */
		return -2;
	}
	if (!operation)		/* "is it sandboxed?" */
		return req.result != FINCH_SANDBOX_QUERY_RESULT_UNSANDBOXED;
	return req.result == FINCH_SANDBOX_QUERY_RESULT_DENY;
}

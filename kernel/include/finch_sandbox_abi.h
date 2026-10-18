/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SANDBOX_ABI_H
#define FINCH_SANDBOX_ABI_H

#include <stdint.h>

#define FINCH_SANDBOX_POLICY "FinchSandbox"
#define FINCH_SANDBOX_ABI_VERSION 1u

/* These calls use Finch's request format. The older proof calls stay separate. */
#define FINCH_SANDBOX_CALL_APPLY 0x100
#define FINCH_SANDBOX_CALL_CHECK 0x101

#define FINCH_SANDBOX_PROFILE_DENY_READ 1u
#define FINCH_SANDBOX_PROFILE_DENY_WRITE 2u
/* Reserved for the future service policy. Applying it returns ENOTSUP for now. */
#define FINCH_SANDBOX_PROFILE_NOTIFYD 3u

#define FINCH_SANDBOX_OP_STATUS 0u
#define FINCH_SANDBOX_OP_READ_DATA 1u
#define FINCH_SANDBOX_OP_WRITE_DATA 2u

#define FINCH_SANDBOX_RESULT_ALLOW 0u
#define FINCH_SANDBOX_RESULT_DENY 1u

/* Call 0x100. All reserved words and flags must be zero. */
struct finch_sandbox_apply_request {
	uint32_t version;
	uint32_t size;
	uint32_t profile;
	uint32_t flags;
	uint64_t reserved[2];
};

/*
 * Call 0x101. The kernel writes result back after a successful check.
 * This reports a snapshot. A target may change its restrictions before the
 * caller receives it. Actual file operations still need kernel access checks.
 */
struct finch_sandbox_check_request {
	uint32_t version;
	uint32_t size;
	int32_t target_pid;
	uint32_t target_pidversion;
	uint32_t operation;
	uint32_t flags;
	uint64_t reserved[2];
	uint32_t result;
	uint32_t result_reserved;
};

#if defined(__cplusplus)
static_assert(sizeof(struct finch_sandbox_apply_request) == 32,
    "Finch sandbox apply request size");
static_assert(sizeof(struct finch_sandbox_check_request) == 48,
    "Finch sandbox check request size");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(struct finch_sandbox_apply_request) == 32,
    "Finch sandbox apply request size");
_Static_assert(sizeof(struct finch_sandbox_check_request) == 48,
    "Finch sandbox check request size");
#endif

#endif /* FINCH_SANDBOX_ABI_H */

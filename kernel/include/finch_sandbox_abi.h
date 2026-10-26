/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SANDBOX_ABI_H
#define FINCH_SANDBOX_ABI_H

#include <stdint.h>

#define FINCH_SANDBOX_POLICY "FinchSandbox"
#define FINCH_SANDBOX_ABI_VERSION 1u

/* These calls use Finch's request format. The older proof calls stay separate. */
#define FINCH_SANDBOX_CALL_APPLY 0x100
#define FINCH_SANDBOX_CALL_CHECK 0x101
/* Apply a compiled profile (kernel/sandbox/fsb_format.h) to the caller. */
#define FINCH_SANDBOX_CALL_APPLY_PROFILE 0x102
/* Ask how a process's profile decides one request (sandbox_check). */
#define FINCH_SANDBOX_CALL_QUERY 0x103

#define FINCH_SANDBOX_PROFILE_DENY_READ 1u
#define FINCH_SANDBOX_PROFILE_DENY_WRITE 2u
/* Retired: notifyd's sandbox is now its compiled profile (call 0x102). Applying
   this fixed id still returns ENOTSUP. */
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

/*
 * Call 0x102. The profile is copied in and checked before it is applied; a
 * process can be given one sandbox, once (EPERM after that).
 */
struct finch_sandbox_profile_request {
	uint32_t version;
	uint32_t size;
	uint64_t profile;	/* user address */
	uint64_t profile_size;
	uint32_t flags;		/* zero */
	uint32_t reserved;
};

/*
 * Call 0x103. target_pid 0 is the caller; otherwise target_pidversion must
 * match (the audit token's), and a caller other than root may ask only about
 * itself. result: 0 allowed, 1 denied, 2 the target has no sandbox (allowed).
 * value is a user address of value_size bytes for a string field, or the
 * number for a numeric one; field is FSB_F_* or 0xffffffff for none.
 */
struct finch_sandbox_query_request {
	uint32_t version;
	uint32_t size;
	int32_t target_pid;
	uint32_t target_pidversion;
	uint32_t operation;	/* FSB_OP_* */
	uint32_t field;
	uint64_t value;
	uint64_t value_size;
	uint32_t flags;		/* FINCH_SANDBOX_QUERY_NO_REPORT */
	uint32_t result;
};

#define FINCH_SANDBOX_QUERY_NO_REPORT 0x1u
#define FINCH_SANDBOX_QUERY_RESULT_ALLOW 0u
#define FINCH_SANDBOX_QUERY_RESULT_DENY 1u
#define FINCH_SANDBOX_QUERY_RESULT_UNSANDBOXED 2u

#if defined(__cplusplus)
static_assert(sizeof(struct finch_sandbox_profile_request) == 32,
    "Finch sandbox profile request size");
static_assert(sizeof(struct finch_sandbox_query_request) == 48,
    "Finch sandbox query request size");
static_assert(sizeof(struct finch_sandbox_apply_request) == 32,
    "Finch sandbox apply request size");
static_assert(sizeof(struct finch_sandbox_check_request) == 48,
    "Finch sandbox check request size");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(struct finch_sandbox_profile_request) == 32,
    "Finch sandbox profile request size");
_Static_assert(sizeof(struct finch_sandbox_query_request) == 48,
    "Finch sandbox query request size");
_Static_assert(sizeof(struct finch_sandbox_apply_request) == 32,
    "Finch sandbox apply request size");
_Static_assert(sizeof(struct finch_sandbox_check_request) == 48,
    "Finch sandbox check request size");
#endif

#endif /* FINCH_SANDBOX_ABI_H */

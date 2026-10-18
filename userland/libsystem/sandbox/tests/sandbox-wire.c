/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Check the filter-9 wire shape without asking the host kernel to enforce it.
 * Only __sandbox_ms is replaced; this test checks the request sent to it.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int fake_sandbox_ms(const char *, int, void *);
#define __sandbox_ms fake_sandbox_ms
#include "../sandbox.c"

struct filter9_pair {
	uint64_t first;
	uint64_t second;
};

static unsigned checks;
static const char *expected_operation;
static const char *expected_name;
static int64_t expected_pid;
static uint64_t expected_flags;
static uint64_t expected_target;
static uint64_t expected_second;
static int expected_result;

static void check(int condition, const char *message)
{
	checks++;
	if (!condition) {
		fprintf(stderr, "sandbox wire check failed: %s\n", message);
		exit(1);
	}
}

int fake_sandbox_ms(const char *policy, int call, void *argument)
{
	struct check_request *request = argument;
	check(!strcmp(policy, "Sandbox"), "policy name");
	check(call == 2, "call number");
	check(request->result != NULL, "result pointer");
	check(request->pid == expected_pid, "target pid");
	check(request->operation && !strcmp(request->operation, expected_operation), "operation");
	check(request->filter_kind == 35, "filter kind");
	check(request->flags == expected_flags, "request flags");
	check(request->target == expected_target, "audit token target");
	struct filter9_pair *pair = (void *)request->filter_arg;
	check(pair != NULL, "filter pair");
	check(pair->first == (uint64_t)(uintptr_t)expected_name, "first filter value");
	check(pair->second == expected_second, "second filter value");
	check(*request->result == 0, "initial result");
	*request->result = (uint64_t)expected_result;
	return 0;
}

static void expect(const char *operation, const char *name, int64_t pid,
	uint64_t flags, uint64_t target, uint64_t second, int result)
{
	expected_operation = operation;
	expected_name = name;
	expected_pid = pid;
	expected_flags = flags;
	expected_target = target;
	expected_second = second;
	expected_result = result;
}

int main(void)
{
	const char *notification = "com.codex.sandbox-wire";
	expect("darwin-notification-post", notification, 4242, 0, 0, 0, 1);
	check(sandbox_check(4242, "darwin-notification-post", 9, notification) == 1,
		"one-argument notification result");

	audit_token_t token = { .val = { 0, 0, 0, 0, 0, 5151, 0, 6161 } };
	expect("darwin-notification-post", notification, 5151, CHECK_BY_AUDIT_TOKEN, 6161, 0, 0);
	check(sandbox_check_by_audit_token(&token, "darwin-notification-post", 9, notification) == 0,
		"one-argument audit-token result");

	const char *other = "some-other-operation";
	expect(other, notification, 7373, 0, 0, (uint64_t)(int64_t)-1, 1);
	check(sandbox_check(7373, other, 9, notification, -1) == 1,
		"two-argument non-notification result");

	printf("sandbox filter-9 wire: %u checks passed\n", checks);
	return 0;
}

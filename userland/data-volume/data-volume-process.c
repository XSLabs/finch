/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "data-volume-process.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define POLL_NANOSECONDS 20000000L
#define REAP_TIMEOUT_MILLISECONDS 1000

extern char **environ;

static int
compare_timespec(const struct timespec *left, const struct timespec *right)
{
	if (left->tv_sec != right->tv_sec)
		return left->tv_sec < right->tv_sec ? -1 : 1;
	if (left->tv_nsec != right->tv_nsec)
		return left->tv_nsec < right->tv_nsec ? -1 : 1;
	return 0;
}

static void
deadline_after(struct timespec *deadline, unsigned int milliseconds)
{
	deadline->tv_sec += (time_t)(milliseconds / 1000);
	deadline->tv_nsec += (long)(milliseconds % 1000) * 1000000L;
	if (deadline->tv_nsec >= 1000000000L) {
		deadline->tv_sec++;
		deadline->tv_nsec -= 1000000000L;
	}
}

static enum finch_dv_process_result
child_result(int status)
{
	if (WIFEXITED(status))
		return WEXITSTATUS(status) == 0 ? FINCH_DV_PROCESS_OK : FINCH_DV_PROCESS_NONZERO;
	if (WIFSIGNALED(status))
		return FINCH_DV_PROCESS_SIGNALED;
	return FINCH_DV_PROCESS_SYSTEM_ERROR;
}

static enum finch_dv_process_result
kill_and_reap(pid_t child)
{
	struct timespec deadline, now, delay = { .tv_sec = 0,
	    .tv_nsec = POLL_NANOSECONDS };
	int status;

	if (kill(child, SIGKILL) != 0 && errno != ESRCH)
		return FINCH_DV_PROCESS_REAP_TIMEOUT;
	if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0)
		return FINCH_DV_PROCESS_REAP_TIMEOUT;
	deadline_after(&deadline, REAP_TIMEOUT_MILLISECONDS);
	for (;;) {
		pid_t waited = waitpid(child, &status, WNOHANG);
		if (waited == child)
			return FINCH_DV_PROCESS_TIMEOUT;
		if (waited < 0 && errno != EINTR)
			return FINCH_DV_PROCESS_REAP_TIMEOUT;
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
		    compare_timespec(&now, &deadline) >= 0)
			return FINCH_DV_PROCESS_REAP_TIMEOUT;
		(void)nanosleep(&delay, NULL);
	}
}

enum finch_dv_process_result
finch_dv_run_program(const char *path, char *const arguments[],
    unsigned int timeout_milliseconds)
{
	struct timespec deadline, now, delay = { .tv_sec = 0,
	    .tv_nsec = POLL_NANOSECONDS };
	pid_t child;
	int status;
	int spawn_error;

	if (!path || !arguments || timeout_milliseconds == 0) {
		errno = EINVAL;
		return FINCH_DV_PROCESS_SYSTEM_ERROR;
	}
	spawn_error = posix_spawn(&child, path, NULL, NULL, arguments, environ);
	if (spawn_error != 0) {
		errno = spawn_error;
		return FINCH_DV_PROCESS_SYSTEM_ERROR;
	}
	if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) {
		int saved_errno = errno;
		(void)kill_and_reap(child);
		errno = saved_errno;
		return FINCH_DV_PROCESS_SYSTEM_ERROR;
	}
	deadline_after(&deadline, timeout_milliseconds);
	for (;;) {
		pid_t waited = waitpid(child, &status, WNOHANG);
		if (waited == child)
			return child_result(status);
		if (waited < 0 && errno != EINTR) {
			int saved_errno = errno;
			/* ECHILD no longer proves that this PID belongs to us. */
			if (saved_errno != ECHILD)
				(void)kill_and_reap(child);
			errno = saved_errno;
			return FINCH_DV_PROCESS_SYSTEM_ERROR;
		}
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
			int saved_errno = errno;
			(void)kill_and_reap(child);
			errno = saved_errno;
			return FINCH_DV_PROCESS_SYSTEM_ERROR;
		}
		if (compare_timespec(&now, &deadline) >= 0)
			return kill_and_reap(child);
		(void)nanosleep(&delay, NULL);
	}
}

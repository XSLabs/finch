/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-screencaptured: the screen capture service Apple's Screenshot app (and anything
 * else that asks for com.apple.screencapture.connection) talks to. On macOS
 * SystemUIServer serves it; here it runs Finch's screencapture for the caller.
 *
 * Requests (XPC dictionaries):
 *   message  1  run screencapture with "args" (an array of strings); with "nowait"
 *               the reply comes at once, else when it exits ({status: exit status})
 *            4  start a screen recording (not on Finch yet: status 1)
 *            5  stop the recording ({status: 0})
 *            6  whether a recording is running ({status: 0, none})
 * screencapture runs as the caller's user, with the caller's environment (its home,
 * and the window server it draws on), read from the caller's process.
 */
#include <bsm/libbsm.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

void xpc_dictionary_get_audit_token(xpc_object_t message, audit_token_t *token);

#define TOOL "/usr/sbin/screencapture"

/* The caller's environment: its process's arguments area holds argc, the path, the
   arguments and then the environment. Returns a NULL-terminated array (to free). */
static char **
caller_environment(pid_t pid)
{
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int))
        return NULL;
    char *buf = malloc(size);
    if (!buf || sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        free(buf);
        return NULL;
    }
    int argc;
    memcpy(&argc, buf, sizeof argc);
    char *p = buf + sizeof argc, *end = buf + size;
    p += strnlen(p, (size_t)(end - p)); /* the executable path */
    while (p < end && *p == '\0')
        p++;
    for (int i = 0; i < argc && p < end; i++)
        p += strnlen(p, (size_t)(end - p)) + 1;
    size_t n = 0, cap = 32;
    char **env = calloc(cap + 1, sizeof *env);
    while (p < end && *p) {
        if (n == cap) {
            cap *= 2;
            env = realloc(env, (cap + 1) * sizeof *env);
        }
        env[n++] = strdup(p);
        p += strnlen(p, (size_t)(end - p)) + 1;
    }
    env[n] = NULL;
    free(buf);
    return env;
}

static void
free_env(char **env)
{
    for (size_t i = 0; env && env[i]; i++)
        free(env[i]);
    free(env);
}

/* Run screencapture for the caller; its pid, or -1. */
static pid_t
run_tool(xpc_object_t args, uid_t uid, gid_t gid, char **env)
{
    size_t n = args && xpc_get_type(args) == XPC_TYPE_ARRAY ? xpc_array_get_count(args) : 0;
    char **argv = calloc(n + 2, sizeof *argv);
    argv[0] = TOOL;
    size_t k = 1;
    for (size_t i = 0; i < n; i++) {
        const char *s = xpc_array_get_string(args, i);
        if (s)
            argv[k++] = (char *)s;
    }
    argv[k] = NULL;
    pid_t pid = fork();
    if (pid == 0) {
        struct passwd *pw = getpwuid(uid);
        if (getuid() == 0) {
            if (pw)
                initgroups(pw->pw_name, (int)gid);
            if (setgid(gid) != 0 || setuid(uid) != 0)
                _exit(126);
        }
        if (pw && pw->pw_dir)
            chdir(pw->pw_dir);
        char *fallback[] = {NULL};
        execve(TOOL, argv, env ? env : fallback);
        _exit(127);
    }
    free(argv);
    return pid;
}

static void
reply(xpc_object_t message, int64_t status)
{
    xpc_object_t r = xpc_dictionary_create_reply(message);
    if (!r)
        return;
    xpc_dictionary_set_int64(r, "status", status);
    xpc_connection_t c = xpc_dictionary_get_remote_connection(message);
    if (c)
        xpc_connection_send_message(c, r);
    xpc_release(r);
}

static void
handle(xpc_object_t message)
{
    uint64_t what = xpc_dictionary_get_uint64(message, "message");
    switch (what) {
    case 1: {
        audit_token_t token;
        xpc_dictionary_get_audit_token(message, &token);
        pid_t caller = audit_token_to_pid(token);
        uid_t uid = audit_token_to_euid(token);
        gid_t gid = audit_token_to_egid(token);
        char **env = caller_environment(caller);
        pid_t pid = run_tool(xpc_dictionary_get_value(message, "args"), uid, gid, env);
        free_env(env);
        if (pid < 0) {
            reply(message, 1);
            return;
        }
        if (xpc_dictionary_get_bool(message, "nowait")) {
            reply(message, 0);
            /* reap it when it's done */
            xpc_retain(message);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
              int st;
              waitpid(pid, &st, 0);
              xpc_release(message);
            });
            return;
        }
        xpc_retain(message);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
          int st = 0;
          while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
              ;
          reply(message, WIFEXITED(st) ? WEXITSTATUS(st) : 1);
          xpc_release(message);
        });
        return;
    }
    case 4: /* start recording: not yet */
        reply(message, 1);
        return;
    case 5:
    case 6:
        reply(message, 0);
        return;
    default:
        reply(message, 1);
    }
}

static void
listen_on(const char *name)
{
    xpc_connection_t l = xpc_connection_create_mach_service(name, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
      if (xpc_get_type(peer) != XPC_TYPE_CONNECTION)
          return;
      xpc_connection_t c = peer;
      xpc_connection_set_event_handler(c, ^(xpc_object_t m) {
        if (xpc_get_type(m) == XPC_TYPE_DICTIONARY)
            handle(m);
      });
      xpc_connection_resume(c);
    });
    xpc_connection_resume(l);
}

int
main(void)
{
    signal(SIGPIPE, SIG_IGN);
    listen_on("com.apple.screencapture.connection");
    listen_on("com.apple.systemuiserver.screencapture");
    dispatch_main();
}

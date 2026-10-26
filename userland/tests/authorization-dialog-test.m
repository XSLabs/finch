/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-authorization-dialog-test: authorization's password dialog
 * (finch-securityagent, asked by authd), on the persistent VM
 * (tools/vm/test-authorization-dialog.sh). Three parts, one program:
 *
 *   (root)      makes an administrator and an ordinary user, and runs the
 *               session part as the ordinary user in their own domain
 *   --session   starts a headless window server and the client, and plays the
 *               person at the screen: the administrator's name with a wrong
 *               password, then with the right one; then Escape
 *   --client    asks for system.privilege.admin with interaction allowed,
 *               twice: granted after the second try, then cancelled
 */
#import <AppKit/AppKit.h>
#include <Security/Authorization.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"
#include "account_tools.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
FWSWindowInfo *FWSCopyWindowList(uint32_t *count);

#define ADMIN "dialogadmin"
#define USER "dialoguser"
#define ADMIN_PASSWORD "Finch dialog admin 2026"
#define USER_PASSWORD "Finch dialog user 2026"
#define SELF "/usr/local/bin/finch-authorization-dialog-test"
#define SERVER "/usr/libexec/finch-windowserver"

static int failures;

static void check(const char *what, bool ok)
{
    printf("%s: %s\n", what, ok ? "pass" : "FAIL");
    if (!ok)
        failures++;
}

/* ---- the client ---- */

static OSStatus ask(void)
{
    AuthorizationRef auth = NULL;
    AuthorizationCreate(NULL, NULL, 0, &auth);
    AuthorizationItem item = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    OSStatus status = AuthorizationCopyRights(auth, &rights, NULL,
        kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed, NULL);
    AuthorizationFree(auth, kAuthorizationFlagDestroyRights);
    return status;
}

static int client(void)
{
    OSStatus first = ask();
    check("the administrator's password, at the second try, grants the right", first == errAuthorizationSuccess);
    if (first != errAuthorizationSuccess)
        printf("(status %d)\n", (int)first);
    OSStatus second = ask();
    check("cancelling the dialog cancels the request", second == errAuthorizationCanceled);
    if (second != errAuthorizationCanceled)
        printf("(status %d)\n", (int)second);
    return failures != 0;
}

/* ---- the session ---- */

static void key(unichar c, uint32_t code)
{
    for (uint32_t type = FWS_EVENT_KEY_DOWN; type <= FWS_EVENT_KEY_UP; type++) {
        FWSEvent e;
        memset(&e, 0, sizeof e);
        e.type = type;
        e.key_code = code;
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
        FWSPostEvent(&e);
    }
}

static void type(const char *s)
{
    for (; *s; s++) {
        key((unichar)*s, 0);
        usleep(50000);
    }
}

static bool dialog_shown(void)
{
    uint32_t n = 0;
    FWSWindowInfo *list = FWSCopyWindowList(&n);
    bool found = false;
    for (uint32_t w = 0; w < n && !found; w++)
        found = list[w].on_screen && strcmp(list[w].title, "Authorization") == 0;
    free(list);
    return found;
}

/* The dialog appearing (shown == true) or going (false), within a few minutes. */
static bool wait_dialog(bool shown)
{
    for (int i = 0; i < 1200; i++) {
        if (dialog_shown() == shown)
            return true;
        usleep(250000);
    }
    return false;
}

/* Answer the dialog: a name and password, then Return. */
static void answer(const char *user, const char *password)
{
    sleep(2);
    type(user);
    key('\t', 48);
    usleep(300000);
    type(password);
    key('\r', 36);
}

static int session(void)
{
    pid_t server, c;
    char *serverArgs[] = { SERVER, "--headless", "--size", "1024x768", NULL };
    unsetenv(FWS_SOCKET_ENV);
    if (posix_spawn(&server, SERVER, NULL, NULL, serverArgs, environ) != 0)
        return 1;
    for (int i = 0; i < 200 && !FWSConnect(); i++)
        usleep(100000);
    char *clientArgs[] = { SELF, "--client", NULL };
    if (posix_spawn(&c, SELF, NULL, NULL, clientArgs, environ) != 0) {
        kill(server, SIGTERM);
        return 1;
    }
    bool shown = wait_dialog(true);
    check("authd's agent shows the dialog", shown);
    if (shown) {
        answer(ADMIN, "not the password");
        check("a wrong password asks again", wait_dialog(false) && wait_dialog(true));
        answer(ADMIN, ADMIN_PASSWORD);
        check("the right one closes it", wait_dialog(false));
        check("the second request asks too", wait_dialog(true));
        sleep(2);
        key('\e', 53);
    }
    int status = 0;
    waitpid(c, &status, 0);
    check("the client's checks", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    return failures != 0;
}

/* ---- the driver ---- */

static void make_account(const char *name, uid_t uid, const char *password, bool admin)
{
    struct at_store store = { .directory_fd = -1 };
    char error[256], users[PATH_MAX];
    if (getpwnam(name))
        return;
    realpath("/Users", users);
    users[strlen(users) - strlen("/Users")] = '\0';
    char home[128];
    snprintf(home, sizeof(home), "/Users/%s", name);
    if (at_store_open_default(&store, error, sizeof(error)) != 0 ||
        at_store_create_user_with_home_root(&store, name, uid, 20, name, home, "/bin/sh", password,
        users[0] ? users : "/", error, sizeof(error)) != 0 ||
        (admin && at_store_add_group_member(&store, "admin", name, error, sizeof(error)) != 0)) {
        printf("can't make %s: %s\n", name, error);
        exit(1);
    }
    at_store_close(&store);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 2 && !strcmp(argv[1], "--client"))
        return client();
    if (argc == 2 && !strcmp(argv[1], "--session"))
        return session();
    if (getuid() != 0) {
        printf("run as root\n");
        return 2;
    }
    make_account(ADMIN, 6561, ADMIN_PASSWORD, true);
    make_account(USER, 6562, USER_PASSWORD, false);
    struct passwd *pw = getpwnam(USER);
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        char uid[16];
        snprintf(uid, sizeof(uid), "%u", pw->pw_uid);
        if (initgroups(USER, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0)
            _exit(126);
        setenv("HOME", pw->pw_dir, 1);
        execl("/bin/launchctl", "launchctl", "asuser", uid, SELF, "--session", (char *)NULL);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    check("the session", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("authorization-dialog-test: %d failed\n", failures);
    return failures != 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-openpanel-test: a sandboxed app's open and save panels, run by the
 * panel service (finch-openandsavepanel), on the persistent VM
 * (tools/vm/test-openpanel.sh). Three parts, one program:
 *
 *   (root)       makes a user with ~/Documents/chosen.txt and secret.txt, and
 *                runs the session part as the user in their own domain
 *                (launchctl asuser), then checks ~/Documents/saved.txt
 *   --session    starts a headless window server, starts the app, and plays
 *                the user: when the service's Open panel appears it selects
 *                the first file and presses Return; when its Save panel
 *                appears, Return (the app named the file)
 *   --app        OpenPanelTest.app, sandboxed with
 *                files.user-selected.read-write: it can't read the user's
 *                files until the panel hands them over, then reads the chosen
 *                one and writes the saved one, and still can't read the other
 */
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"
#include "account_tools.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
FWSWindowInfo *FWSCopyWindowList(uint32_t *count);

#define USER "paneluser"
#define PASSWORD "Finch panel user 2026"
#define APP "/usr/local/share/finch/apps/OpenPanelTest.app/Contents/MacOS/OpenPanelTest"
#define SERVER "/usr/libexec/finch-windowserver"

static int failures;

static void check(const char *what, bool ok)
{
    printf("%s: %s\n", what, ok ? "pass" : "FAIL");
    if (!ok)
        failures++;
}

static int read_errno(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0)
        return errno;
    char c;
    int r = read(fd, &c, 1) < 0 ? errno : 0;
    close(fd);
    return r;
}

static NSString *home(void)
{
    return [NSString stringWithUTF8String:getpwuid(getuid())->pw_dir];
}

/* ---- the app ---- */

static int app(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *documents = [[home() stringByResolvingSymlinksInPath] stringByAppendingPathComponent:@"Documents"];
        NSString *chosen = [documents stringByAppendingPathComponent:@"chosen.txt"];
        NSString *secret = [documents stringByAppendingPathComponent:@"secret.txt"];
        check("the app is sandboxed: the user's file is closed", read_errno(chosen) == EPERM);
        /* A window of its own: the sandboxed app reaches the window server. */
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:@"Panel Test App"];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSOpenPanel *open = [NSOpenPanel openPanel];
        [open setDirectoryURL:[NSURL fileURLWithPath:documents isDirectory:YES]];
        [open setCanChooseFiles:YES];
        NSModalResponse r = [open runModal];
        check("the open panel answers OK", r == NSModalResponseOK);
        NSURL *url = [open URL];
        check("with the file the user chose", [[url.path stringByResolvingSymlinksInPath] isEqualToString:chosen]);
        NSString *text = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
        check("which the app can now read", [text isEqualToString:@"chosen by the user\n"]);
        check("and only that one", read_errno(secret) == EPERM);

        NSSavePanel *save = [NSSavePanel savePanel];
        [save setDirectoryURL:[NSURL fileURLWithPath:documents isDirectory:YES]];
        [save setNameFieldStringValue:@"saved.txt"];
        r = [save runModal];
        check("the save panel answers OK", r == NSModalResponseOK);
        NSURL *saved = [save URL];
        check("with the name the app gave", [saved.lastPathComponent isEqualToString:@"saved.txt"]);
        NSError *error = nil;
        check("and the app may write it", saved && [@"saved through the panel\n" writeToURL:saved atomically:NO
            encoding:NSUTF8StringEncoding error:&error]);
        check("still not the other file", read_errno(secret) == EPERM);
        printf("app: %d failed\n", failures);
    }
    return failures != 0;
}

/* ---- the session: a window server, the app, and someone at the keyboard ---- */

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

/* Wait (up to a few minutes, emulated) for a window with this title. */
static bool wait_for_window(const char *title)
{
    for (int i = 0; i < 600; i++) {
        uint32_t n = 0;
        FWSWindowInfo *list = FWSCopyWindowList(&n);
        bool found = false;
        for (uint32_t w = 0; w < n && !found; w++)
            found = list[w].on_screen && strcmp(list[w].title, title) == 0;
        free(list);
        if (found)
            return true;
        usleep(250000);
    }
    return false;
}

static int session(void)
{
    pid_t server, client;
    char *serverArgs[] = { SERVER, "--headless", "--size", "1024x768", NULL };
    unsetenv(FWS_SOCKET_ENV);   /* the default socket, which the panel service uses too */
    if (posix_spawn(&server, SERVER, NULL, NULL, serverArgs, environ) != 0) {
        printf("can't start the window server\n");
        return 1;
    }
    for (int i = 0; i < 200 && !FWSConnect(); i++)
        usleep(100000);
    check("the window server is up", FWSConnect());
    char *appArgs[] = { APP, "--app", NULL };
    if (posix_spawn(&client, APP, NULL, NULL, appArgs, environ) != 0) {
        printf("can't start the app\n");
        kill(server, SIGTERM);
        return 1;
    }
    check("the sandboxed app shows its window", wait_for_window("Panel Test App"));
    bool opened = wait_for_window("Open");
    check("the service shows the Open panel", opened);
    if (opened) {
        sleep(2);
        key(NSDownArrowFunctionKey, 125);   /* the first file: chosen.txt */
        sleep(1);
        key('\r', 36);
    }
    bool saving = opened && wait_for_window("Save");
    check("then the Save panel", saving);
    if (saving) {
        sleep(2);
        key('\r', 36);
    }
    int status = 0;
    waitpid(client, &status, 0);
    check("the app's checks", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    return failures != 0;
}

/* ---- the driver (root) ---- */

static void put(NSString *path, NSString *text, uid_t uid)
{
    [text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chown(path.fileSystemRepresentation, uid, 20);
    chmod(path.fileSystemRepresentation, 0600);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 2 && !strcmp(argv[1], "--app"))
        return app();
    if (argc == 2 && !strcmp(argv[1], "--session"))
        return session();
    if (getuid() != 0) {
        printf("run as root\n");
        return 2;
    }
    @autoreleasepool {
        if (getpwnam(USER) == NULL) {
            struct at_store store = { .directory_fd = -1 };
            char error[256], users[PATH_MAX];
            realpath("/Users", users);
            users[strlen(users) - strlen("/Users")] = '\0';
            if (at_store_open_default(&store, error, sizeof(error)) != 0 ||
                at_store_create_user_with_home_root(&store, USER, 6541, 20, "Panel Test", "/Users/" USER, "/bin/sh",
                PASSWORD, users[0] ? users : "/", error, sizeof(error)) != 0) {
                printf("can't make %s: %s\n", USER, error);
                return 1;
            }
            at_store_close(&store);
        }
        struct passwd *pw = getpwnam(USER);
        NSString *documents = [[NSString stringWithUTF8String:pw->pw_dir] stringByAppendingPathComponent:@"Documents"];
        put([documents stringByAppendingPathComponent:@"chosen.txt"], @"chosen by the user\n", pw->pw_uid);
        put([documents stringByAppendingPathComponent:@"secret.txt"], @"not chosen\n", pw->pw_uid);
        [[NSFileManager defaultManager] removeItemAtPath:[documents stringByAppendingPathComponent:@"saved.txt"] error:nil];

        /* The session runs as the user, in the user's domain (where the agent is). */
        fflush(stdout);
        pid_t pid = fork();
        if (pid == 0) {
            char uid[16];
            snprintf(uid, sizeof(uid), "%u", pw->pw_uid);
            if (initgroups(USER, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0)
                _exit(126);
            setenv("HOME", pw->pw_dir, 1);
            setenv("USER", USER, 1);
            execl("/bin/launchctl", "launchctl", "asuser", uid, "/usr/local/bin/finch-openpanel-test", "--session",
                (char *)NULL);
            _exit(127);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        check("the session", WIFEXITED(status) && WEXITSTATUS(status) == 0);
        NSString *saved = [NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"saved.txt"]
            encoding:NSUTF8StringEncoding error:nil];
        check("the saved file is in the user's Documents", [saved isEqualToString:@"saved through the panel\n"]);
        printf("openpanel-test: %d failed\n", failures);
    }
    return failures != 0;
}

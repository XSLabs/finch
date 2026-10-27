/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-app-test: run an app on a headless window server and drive it.
 * Starts finch-windowserver, launches the app's executable with the
 * server's socket, waits for its windows (the window list), posts input
 * at points relative to a window, and reports what the app printed and
 * what the screen shows. Finch-only; compare with the expected output.
 *
 *   finch-app-test SERVER APP-EXECUTABLE STEP...
 *   (FINCH_APP_ARGS="file ..." passes arguments to the app; commas separate them too;
 *   FINCH_SHELL=EXECUTABLE starts a shell process first, such as the Rail)
 *
 * Steps (points; window-relative ones are from the top left of the named
 * window, title bar included):
 *   wait:N            wait N milliseconds
 *   window:TITLE      wait for a window titled TITLE and make it the current one
 *                     (TITLE* for a title starting with TITLE)
 *   click:X,Y         click at X,Y in the current window
 *   move:X,Y          move the pointer to X,Y in the current window
 *   rclick:X,Y        right-click at X,Y in the current window
 *   drag:X1,Y1,X2,Y2  press at X1,Y1, drag in ten steps to X2,Y2 and let go (current window)
 *   hold:X,Y,MS       press at X,Y, hold for MS milliseconds and let go (current window)
 *   scroll:X,Y,DX,DY  scroll by DX,DY points (a wheel's deltas) at X,Y in the current window
 *   type:TEXT         type TEXT (ASCII)
 *   key:CODE,CHAR     press a key (macOS virtual key code, character as a number)
 *   cmd:CHAR          press Command-CHAR
 *   ctrlcmd:CHAR      press Control-Command-CHAR
 *   shiftcmd:CHAR     press Shift-Command-CHAR (CHAR as typed with Shift: "C" for ⇧⌘C)
 *   sample:X,Y,LABEL  print the screen's colour at X,Y in the current window
 *   windows           print the window list (titles and sizes)
 *   frames            print the window list with where each window is
 *   screenshot:PATH   save the screen as a PNG
 *   screenshot64[:half]  print the screen as a base64 PNG between BEGIN-PNG and
 *                     END-PNG lines (to get it out of the VM over its console),
 *                     as numbered, checksummed lines, twice; half scales it down
 *                     by two (tools/vm/png-from-console.py decodes it)
 *   output            print what the app has written since the last time
 *
 * If the app crashes, its exception, registers and backtrace are printed as "crash:" lines.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <errno.h>
#include <fcntl.h>
char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../WindowServer/FinchWSProtocol.h"
#include "crashwatch.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
void FWSSetCursorVisible(bool v);
CGImageRef FWSCopyScreenImage(void);
FWSWindowInfo *FWSCopyWindowList(uint32_t *count);

static int app_out = -1;
static FWSRect current;
static double scale = 2;

static void
post(uint32_t type, double x, double y, uint16_t ch, uint32_t code, uint64_t mods)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = x, e.screen_y = y;
    e.key_code = code;
    e.modifiers = mods;
    if (ch) {
        e.characters[0] = e.unmodified[0] = ch;
        e.length = 1;
    }
    FWSPostEvent(&e);
    usleep(20000);
}

static void
key(uint16_t ch, uint32_t code, uint64_t mods)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, ch, code, mods);
    post(FWS_EVENT_KEY_UP, 0, 0, ch, code, mods);
}

/* The U.S. keyboard's key for an ASCII character, and whether it takes Shift, as a real
   keyboard sends them (apps such as Terminal translate key codes themselves). */
static uint32_t
us_key(char c, bool *shift)
{
    static const struct { char c; uint32_t code; } keys[] = {
        {'a', 0}, {'s', 1}, {'d', 2}, {'f', 3}, {'h', 4}, {'g', 5}, {'z', 6}, {'x', 7}, {'c', 8}, {'v', 9},
        {'b', 11}, {'q', 12}, {'w', 13}, {'e', 14}, {'r', 15}, {'y', 16}, {'t', 17}, {'1', 18}, {'2', 19},
        {'3', 20}, {'4', 21}, {'6', 22}, {'5', 23}, {'=', 24}, {'9', 25}, {'7', 26}, {'-', 27}, {'8', 28},
        {'0', 29}, {']', 30}, {'o', 31}, {'u', 32}, {'[', 33}, {'i', 34}, {'p', 35}, {'l', 37}, {'j', 38},
        {'\'', 39}, {'k', 40}, {';', 41}, {'\\', 42}, {',', 43}, {'/', 44}, {'n', 45}, {'m', 46}, {'.', 47},
        {' ', 49}, {'`', 50},
    };
    static const char shifted[] = "~!@#$%^&*()_+{}|:\"<>?", plain[] = "`1234567890-=[]\\;',./";
    *shift = false;
    if (c >= 'A' && c <= 'Z') {
        *shift = true;
        c = (char)(c - 'A' + 'a');
    } else {
        const char *at = strchr(shifted, c);
        if (at && c) {
            *shift = true;
            c = plain[at - shifted];
        }
    }
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++)
        if (keys[i].c == c)
            return keys[i].code;
    return 0;
}

static bool
find_window(const char *title, int ms)
{
    for (int waited = 0; waited <= ms; waited += 50) {
        uint32_t n = 0;
        FWSWindowInfo *list = FWSCopyWindowList(&n);
        for (uint32_t i = 0; i < n; i++) {
            size_t len = strlen(title);
            bool prefix = len && title[len - 1] == '*'; /* "Terminal*": a title starting so */
            if (list[i].on_screen && (prefix ? !strncmp(list[i].title, title, len - 1) : !strcmp(list[i].title, title))) {
                current = list[i].frame;
                free(list);
                return true;
            }
        }
        free(list);
        usleep(50000);
    }
    return false;
}

static void
drain_output(bool print)
{
    char buf[4096];
    ssize_t n;
    while ((n = read(app_out, buf, sizeof buf)) > 0)
        if (print)
            fwrite(buf, 1, (size_t)n, stdout);
}

int
main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s SERVER APP-EXECUTABLE STEP...\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    int failures = 0;
    char sock[64];
    snprintf(sock, sizeof sock, "/tmp/finch-app-test.%d", getpid());
    setenv(FWS_SOCKET_ENV, sock, 1);
    pid_t server, app;
    char *sargs[] = {argv[1], "--headless", "--size", "1024x768", "--scale", "2", NULL};
    if (posix_spawn(&server, argv[1], NULL, NULL, sargs, environ)) {
        printf("can't start %s\n", argv[1]);
        return 1;
    }
    for (int i = 0; i < 100 && !FWSConnect(); i++)
        usleep(20000);
    if (!FWSConnect()) {
        fprintf(stderr, "window server did not become ready\n");
        kill(server, SIGTERM);
        waitpid(server, NULL, 0);
        unlink(sock);
        return 1;
    }
    FWSSetCursorVisible(false);
    /* FINCH_SHELL: the desktop's own process (the Rail), started before the app */
    pid_t shell = 0;
    const char *shell_path = getenv("FINCH_SHELL");
    if (shell_path && *shell_path) {
        char *shargs[] = {(char *)shell_path, NULL};
        if (posix_spawn(&shell, shell_path, NULL, NULL, shargs, environ))
            shell = 0;
        usleep(1500000);
    }
    int pipefd[2];
    pipe(pipefd);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    /* FINCH_APP_ARGS: arguments for the app (files to open, as Finch's NSWorkspace passes them), separated by spaces or commas */
    char *aargs[16] = {argv[2], NULL};
    char *extra = getenv("FINCH_APP_ARGS") ? strdup(getenv("FINCH_APP_ARGS")) : NULL;
    int na = 1;
    for (char *tok = extra ? strtok(extra, " ,") : NULL; tok && na < 15; tok = strtok(NULL, " ,"))
        aargs[na++] = tok;
    aargs[na] = NULL;
    /* As Launch Services does: a sandboxed app may open the files it's given
       (their extensions in FINCH_SANDBOX_EXTENSIONS, consumed at its start). */
    char tokens[16384] = "";
    for (int i = 1; i < na; i++) {
        static const char *const classes[] = { "com.apple.app-sandbox.read", "com.apple.app-sandbox.read-write" };
        for (int c = 0; aargs[i][0] == '/' && c < 2; c++) {
            char *t = sandbox_extension_issue_file(classes[c], aargs[i], 0);
            if (t && strlen(tokens) + strlen(t) + 2 < sizeof(tokens)) {
                if (tokens[0])
                    strlcat(tokens, ",", sizeof(tokens));
                strlcat(tokens, t, sizeof(tokens));
            }
            free(t);
        }
    }
    if (tokens[0])
        setenv("FINCH_SANDBOX_EXTENSIONS", tokens, 1);
    /* a crash in the app is reported with a backtrace (crashwatch.c) */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if (!getenv("FINCH_CRASHWATCH") || strcmp(getenv("FINCH_CRASHWATCH"), "0"))
        crashwatch_spawnattr(&attr);
    int spawned = posix_spawn(&app, argv[2], &fa, &attr, aargs, environ);
    unsetenv("FINCH_SANDBOX_EXTENSIONS");
    if (spawned) {
        printf("can't start %s\n", argv[2]);
        kill(server, SIGTERM);
        return 1;
    }
    crashwatch_child(app);
    close(pipefd[1]);
    app_out = pipefd[0];
    fcntl(app_out, F_SETFL, O_NONBLOCK);

    for (int i = 3; i < argc; i++) {
        const char *s = argv[i];
        double x, y, dx, dy;
        int n, c;
        char label[64];
        if (sscanf(s, "wait:%d", &n) == 1) {
            usleep((useconds_t)n * 1000);
        } else if (!strncmp(s, "window:", 7)) {
            bool found = find_window(s + 7, 15000);
            printf("window \"%s\": %s", s + 7, found ? "shown" : "not found\n");
            if (found)
                printf(" %gx%g\n", current.width, current.height);
            else
                failures++;
        } else if (sscanf(s, "move:%lf,%lf", &x, &y) == 2) {
            post(FWS_EVENT_MOUSE_MOVED, current.x + x, current.y + y, 0, 0, 0);
        } else if (sscanf(s, "click:%lf,%lf", &x, &y) == 2) {
            double sx = current.x + x, sy = current.y + y;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_DOWN, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_UP, sx, sy, 0, 0, 0);
        } else if (sscanf(s, "hold:%lf,%lf,%d", &x, &y, &n) == 3) {
            double sx = current.x + x, sy = current.y + y;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_DOWN, sx, sy, 0, 0, 0);
            usleep((useconds_t)n * 1000);
            post(FWS_EVENT_LEFT_UP, sx, sy, 0, 0, 0);
        } else if (sscanf(s, "drag:%lf,%lf,%lf,%lf", &x, &y, &dx, &dy) == 4) {
            double sx = current.x + x, sy = current.y + y, ex = current.x + dx, ey = current.y + dy;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_DOWN, sx, sy, 0, 0, 0);
            for (int k = 1; k <= 10; k++) {
                post(FWS_EVENT_LEFT_DRAGGED, sx + (ex - sx) * k / 10, sy + (ey - sy) * k / 10, 0, 0, 0);
                usleep(16000);
            }
            post(FWS_EVENT_LEFT_UP, ex, ey, 0, 0, 0);
        } else if (sscanf(s, "rclick:%lf,%lf", &x, &y) == 2) {
            double sx = current.x + x, sy = current.y + y;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            post(FWS_EVENT_RIGHT_DOWN, sx, sy, 0, 0, 0);
            post(FWS_EVENT_RIGHT_UP, sx, sy, 0, 0, 0);
        } else if (sscanf(s, "scroll:%lf,%lf,%lf,%lf", &x, &y, &dx, &dy) == 4) {
            double sx = current.x + x, sy = current.y + y;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            FWSEvent e;
            memset(&e, 0, sizeof e);
            e.type = FWS_EVENT_SCROLL;
            e.screen_x = sx, e.screen_y = sy;
            e.delta_x = dx, e.delta_y = dy;
            FWSPostEvent(&e);
            usleep(20000);
        } else if (!strncmp(s, "type:", 5)) {
            for (const char *p = s + 5; *p; p++) {
                bool shift;
                uint32_t code = us_key(*p, &shift);
                key((uint16_t)(unsigned char)*p, code, shift ? kCGEventFlagMaskShift : 0);
            }
        } else if (sscanf(s, "key:%d,%d", &n, &c) == 2) {
            key((uint16_t)c, (uint32_t)n, 0);
        } else if (!strncmp(s, "cmd:", 4) && s[4]) {
            key((uint16_t)(unsigned char)s[4], 0, kCGEventFlagMaskCommand);
        } else if (!strncmp(s, "ctrlcmd:", 8) && s[8]) {
            key((uint16_t)(unsigned char)s[8], 0, kCGEventFlagMaskCommand | kCGEventFlagMaskControl);
        } else if (!strncmp(s, "shiftcmd:", 9) && s[9]) {
            key((uint16_t)(unsigned char)s[9], 0, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        } else if (sscanf(s, "sample:%lf,%lf,%63s", &x, &y, label) == 3) {
            usleep(200000);
            CGImageRef im = FWSCopyScreenImage();
            CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(im));
            size_t bpr = CGImageGetBytesPerRow(im);
            const uint8_t *px = CFDataGetBytePtr(d) + (size_t)((current.y + y) * scale) * bpr +
                                (size_t)((current.x + x) * scale) * 4;
            printf("%s: %d %d %d\n", label, px[2], px[1], px[0]);
            CFRelease(d);
            CGImageRelease(im);
        } else if (!strncmp(s, "screenshot64", 12)) {
            usleep(200000);
            CGImageRef im = FWSCopyScreenImage();
            if (!im) {
                fprintf(stderr, "cannot capture screen\n");
                failures++;
                continue;
            }
            if (!strcmp(s + 12, ":half")) {
                size_t w = CGImageGetWidth(im) / 2, h = CGImageGetHeight(im) / 2;
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGContextRef cg = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                                        (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                CGColorSpaceRelease(cs);
                CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
                CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), im);
                CGImageRelease(im);
                im = CGBitmapContextCreateImage(cg);
                CGContextRelease(cg);
            }
            CFMutableDataRef png = CFDataCreateMutable(NULL, 0);
            CGImageDestinationRef d = CGImageDestinationCreateWithData(png, CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, im, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
            CGImageRelease(im);
            static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            const uint8_t *p = CFDataGetBytePtr(png);
            size_t len = (size_t)CFDataGetLength(png);
            /* Numbered lines with a checksum, the whole image twice: the console can interleave kernel
             * messages, so tools/vm/png-from-console.py keeps the first intact copy of each line. */
            printf("BEGIN-PNG\n");
            for (int pass = 0; pass < 2; pass++) {
                size_t line = 0;
                for (size_t i = 0; i < len; i += 57, line++) {
                    char out[80];
                    size_t n = 0;
                    for (size_t k = i; k < i + 57 && k < len; k += 3) {
                        uint32_t v = (uint32_t)p[k] << 16 | (k + 1 < len ? (uint32_t)p[k + 1] << 8 : 0) |
                                     (k + 2 < len ? p[k + 2] : 0);
                        out[n++] = b64[v >> 18 & 63];
                        out[n++] = b64[v >> 12 & 63];
                        out[n++] = k + 1 < len ? b64[v >> 6 & 63] : '=';
                        out[n++] = k + 2 < len ? b64[v & 63] : '=';
                    }
                    unsigned sum = 0;
                    for (size_t k = 0; k < n; k++)
                        sum = (sum * 31 + (unsigned char)out[k]) & 0xffff;
                    printf("P%zu:%04x:%.*s\n", line, sum, (int)n, out);
                }
            }
            printf("END-PNG\n");
            CFRelease(png);
        } else if (!strncmp(s, "screenshot:", 11)) {
            usleep(200000);
            CGImageRef im = FWSCopyScreenImage();
            if (!im) {
                fprintf(stderr, "cannot capture screen\n");
                failures++;
                continue;
            }
            CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)s + 11, (CFIndex)strlen(s + 11), false);
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
            if (d) {
                CGImageDestinationAddImage(d, im, NULL);
                bool saved = CGImageDestinationFinalize(d);
                printf("screenshot %s: %s\n", s + 11, saved ? "saved" : "failed");
                if (!saved)
                    failures++;
                CFRelease(d);
            } else
                failures++;
            CFRelease(url);
            CGImageRelease(im);
        } else if (!strcmp(s, "windows")) {
            uint32_t count = 0;
            FWSWindowInfo *list = FWSCopyWindowList(&count);
            for (uint32_t k = 0; k < count; k++)
                if (list[k].on_screen && !(list[k].flags & FWS_WINDOW_DESKTOP))
                    printf("  window \"%s\" %gx%g level %d\n", list[k].title, list[k].frame.width,
                           list[k].frame.height, list[k].level);
            free(list);
        } else if (!strcmp(s, "frames")) {
            /* the windows with where they are (top-left origin, points) */
            uint32_t count = 0;
            FWSWindowInfo *list = FWSCopyWindowList(&count);
            for (uint32_t k = 0; k < count; k++)
                if (list[k].on_screen && !(list[k].flags & FWS_WINDOW_DESKTOP))
                    printf("  window \"%s\" at %g,%g %gx%g level %d\n", list[k].title, list[k].frame.x, list[k].frame.y,
                           list[k].frame.width, list[k].frame.height, list[k].level);
            free(list);
        } else if (!strcmp(s, "output")) {
            usleep(300000);
            drain_output(true);
        } else {
            printf("unknown step %s\n", s);
            failures++;
        }
    }
    usleep(300000);
    drain_output(true);
    int status = 0;
    pid_t ended;
    do {
        ended = waitpid(app, &status, WNOHANG);
    } while (ended < 0 && errno == EINTR);
    bool stoppedByTest = ended == 0;
    if (stoppedByTest) {
        kill(app, SIGTERM);
        do {
            ended = waitpid(app, &status, 0);
        } while (ended < 0 && errno == EINTR);
    }
    if (ended < 0 || (WIFEXITED(status) && WEXITSTATUS(status) != 0) ||
        (WIFSIGNALED(status) && !(stoppedByTest && WTERMSIG(status) == SIGTERM))) {
        fprintf(stderr, "app failed (wait status %d)\n", status);
        failures++;
    }
    if (shell)
        kill(shell, SIGTERM);
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    unlink(sock);
    return failures ? 1 : 0;
}

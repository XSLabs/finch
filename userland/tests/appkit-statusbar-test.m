/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-statusbar-test: an accessory app's status item on Finch's window
 * server, a Carbon hot key that reaches the app while it isn't key, and Quartz events
 * posted by the app. Starts a headless server, puts up a status item with a title and a
 * menu, checks where it sits and what reaches the screen, opens its menu with a click,
 * registers ⌘⇧K and presses it, and posts a key with CGEventPost into a window.
 * Finch-only (it drives Finch's server): compare with appkit-statusbar-test.expected.
 *
 *   finch-appkit-statusbar-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
CGImageRef FWSCopyScreenImage(void);
void FWSSetCursorVisible(bool v);

static NSMutableArray<NSString *> *log_;

static void
flush_log(NSString *label)
{
    printf("%s: %s\n", label.UTF8String, [log_ componentsJoinedByString:@"; "].UTF8String);
    [log_ removeAllObjects];
}

static void
pump(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (!e)
            break;
        [NSApp sendEvent:e];
    }
    [NSApp updateWindows];
}

static CFDataRef screen;
static size_t screen_bpr;

static void
snapshot(void)
{
    if (screen)
        CFRelease(screen);
    CGImageRef im = FWSCopyScreenImage();
    screen = CGDataProviderCopyData(CGImageGetDataProvider(im));
    screen_bpr = CGImageGetBytesPerRow(im);
    CGImageRelease(im);
}

/* Whether anything other than the desktop's colour is in a rectangle (points, y down). */
static BOOL
drawn(double x, double y, double w, double h)
{
    const uint8_t *base = CFDataGetBytePtr(screen);
    const uint8_t *d = base + (size_t)(599 * 2) * screen_bpr + (size_t)(2 * 2) * 4; /* the desktop, bottom left */
    for (double yy = y; yy < y + h; yy += 1)
        for (double xx = x; xx < x + w; xx += 1) {
            const uint8_t *p = base + (size_t)(yy * 2) * screen_bpr + (size_t)(xx * 2) * 4;
            if (p[0] != d[0] || p[1] != d[1] || p[2] != d[2])
                return YES;
        }
    return NO;
}

static void
post(uint32_t type, double x, double y, uint32_t code, uint64_t flags)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = x, e.screen_y = y;
    e.modifiers = flags;
    e.key_code = code;
    FWSPostEvent(&e);
}

@interface Target : NSObject
@end

@implementation Target
- (void)chosen:(NSMenuItem *)item
{
    [log_ addObject:[NSString stringWithFormat:@"chose %@", item.title]];
}
@end

@interface KeyView : NSView
@end

@implementation KeyView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e
{
    [log_ addObject:[NSString stringWithFormat:@"keyDown %@ code %u flags %lx", e.characters, e.keyCode,
                                               (unsigned long)(e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask)]];
}
@end

static OSStatus
hotkey_handler(EventHandlerCallRef call, EventRef event, void *info)
{
    EventHotKeyID id;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id);
    [log_ addObject:[NSString stringWithFormat:@"hot key %s '%c%c%c%c' %u", GetEventKind(event) == kEventHotKeyPressed ? "pressed" : "released",
                                               (char)(id.signature >> 24), (char)(id.signature >> 16), (char)(id.signature >> 8),
                                               (char)id.signature, (unsigned)id.id]];
    return noErr;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-asb.%d", getpid());
        setenv(FWS_SOCKET_ENV, sock, 1);
        pid_t pid;
        char *args[] = {(char *)server, "--headless", "--size", "800x600", "--scale", "2", NULL};
        if (posix_spawn(&pid, server, NULL, NULL, args, environ)) {
            printf("can't start %s\n", server);
            return 1;
        }
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        FWSSetCursorVisible(false);
        log_ = [NSMutableArray array];

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
        [NSApp finishLaunching];

        /* a status item: a title and a menu */
        NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        item.button.title = @"Finch";
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        Target *t = [Target new];
        NSMenuItem *mi = [menu addItemWithTitle:@"Keep Awake" action:@selector(chosen:) keyEquivalent:@""];
        mi.target = t;
        item.menu = menu;
        pump(0.3);
        printf("thickness %g vertical %d\n", NSStatusBar.systemStatusBar.thickness, NSStatusBar.systemStatusBar.isVertical);
        NSWindow *iw = item.button.window;
        NSRect f = iw.frame;
        printf("item window level %ld visible %d height %g right of centre %d at top %d\n", (long)iw.level, iw.isVisible,
               f.size.height, NSMinX(f) > 400, NSMaxY(f) == NSMaxY(NSScreen.mainScreen.frame));
        snapshot();
        double top = 600 - NSMaxY(f);
        printf("item drawn %d; left of it empty %d\n", drawn(NSMinX(f) + 2, top + 2, f.size.width - 4, f.size.height - 4),
               !drawn(20, 2, 300, 20));

        /* a second item goes to the left of the first */
        NSStatusItem *second = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
        second.button.title = @"2";
        pump(0.2);
        printf("second left of first %d, square %d\n", NSMaxX(second.button.window.frame) <= NSMinX(item.button.window.frame),
               second.button.window.frame.size.width == NSStatusBar.systemStatusBar.thickness);
        [NSStatusBar.systemStatusBar removeStatusItem:second];
        pump(0.2);
        printf("removed: visible %d\n", second.button.window.isVisible);

        /* a click on the item opens its menu (looked at while it's open); a click on the row
           chooses it */
        double cx = NSMidX(f), cy = 600 - NSMidY(f);
        NSTimer *look = [NSTimer timerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *timer) {
          snapshot();
          printf("menu drawn below the item %d\n", drawn(NSMinX(f) + 4, top + f.size.height + 4, 60, 10));
          post(FWS_EVENT_LEFT_DOWN, NSMinX(f) + 20, top + f.size.height + 12, 0, 0);
          post(FWS_EVENT_LEFT_UP, NSMinX(f) + 20, top + f.size.height + 12, 0, 0);
        }];
        [[NSRunLoop currentRunLoop] addTimer:look forMode:NSRunLoopCommonModes];
        post(FWS_EVENT_LEFT_DOWN, cx, cy, 0, 0);
        post(FWS_EVENT_LEFT_UP, cx, cy, 0, 0);
        pump(1.0);
        flush_log(@"menu");

        /* a window of the app's, key, and a hot key: ⌘⇧K goes to the hot key's handler */
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 200, 120) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        KeyView *kv = [[KeyView alloc] initWithFrame:NSZeroRect];
        w.contentView = kv;
        [w makeKeyAndOrderFront:nil];
        [w makeFirstResponder:kv];
        [NSApp activateIgnoringOtherApps:YES];
        pump(0.3);
        EventTypeSpec types[2] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
        EventHandlerRef handler;
        InstallEventHandler(GetApplicationEventTarget(), hotkey_handler, 2, types, NULL, &handler);
        EventHotKeyRef hk;
        EventHotKeyID hid = {'FNCH', 7};
        printf("register %d\n", (int)RegisterEventHotKey(kVK_ANSI_K, cmdKey | shiftKey, hid, GetApplicationEventTarget(), 0, &hk));
        pump(0.2);
        post(FWS_EVENT_KEY_DOWN, 0, 0, kVK_ANSI_K, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        post(FWS_EVENT_KEY_UP, 0, 0, kVK_ANSI_K, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        pump(0.3);
        flush_log(@"hot key");
        /* without Shift it's an ordinary key, to the window */
        post(FWS_EVENT_KEY_DOWN, 0, 0, kVK_ANSI_K, kCGEventFlagMaskCommand);
        pump(0.3);
        flush_log(@"not the hot key");
        UnregisterEventHotKey(hk);
        pump(0.2);
        post(FWS_EVENT_KEY_DOWN, 0, 0, kVK_ANSI_K, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        pump(0.3);
        flush_log(@"unregistered");

        /* a Quartz event posted by the app, as from the keyboard */
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_A, true);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
        pump(0.3);
        flush_log(@"CGEventPost");
        printf("input state: modifiers 0x%llx\n", (unsigned long long)CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState));

        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-drag-apps-test: a drag from one app to another, on Finch's window server
 * and pasteboard server. Starts a headless window server, then a second process (this
 * program with "dest") whose window holds a logging destination and a text view; the
 * first process drags a string from its own window to the destination and into the
 * text, through the window server. The second process writes what its destination
 * was told to a file the first reads. Needs the pasteboard server (finch-pboardd), so
 * it runs in the VM: compare with appkit-drag-apps-test.expected.
 *
 *   finch-appkit-drag-apps-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#include <spawn.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
void FWSSetCursorVisible(bool v);

static const double kScreenHeight = 600;
static NSMutableArray *calls;
static NSString *logPath;

static void
note(NSString *s)
{
    [calls addObject:s];
    [[calls componentsJoinedByString:@"\n"] writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void
post_at(uint32_t type, NSPoint p)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = p.x, e.screen_y = kScreenHeight - p.y;
    FWSPostEvent(&e);
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
}

static NSString *
op_name(NSDragOperation op)
{
    switch (op) {
    case NSDragOperationNone: return @"none";
    case NSDragOperationCopy: return @"copy";
    case NSDragOperationMove: return @"move";
    case NSDragOperationGeneric: return @"generic";
    default: return [NSString stringWithFormat:@"%lu", (unsigned long)op];
    }
}

@interface SourceView : NSView <NSDraggingSource>
@property (copy) NSString *text;
@end
@implementation SourceView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)drawRect:(NSRect)r
{
    [[NSColor systemOrangeColor] setFill];
    NSRectFill(self.bounds);
}
- (void)mouseDown:(NSEvent *)e {}
- (void)mouseDragged:(NSEvent *)e
{
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:self.text];
    [item setDraggingFrame:self.bounds contents:[NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor systemOrangeColor] setFill];
        NSRectFill(r);
        return YES;
    }]];
    [self beginDraggingSessionWithItems:@[ item ] event:e source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c
{
    [calls addObject:[NSString stringWithFormat:@"source: mask asked %s", c == NSDraggingContextOutsideApplication ? "outside" : "within"]];
    return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op
{
    [calls addObject:[@"source: ended " stringByAppendingString:op_name(op)]];
}
@end

@interface DestView : NSView
@end
@implementation DestView
- (void)drawRect:(NSRect)r
{
    [[NSColor systemTealColor] setFill];
    NSRectFill(self.bounds);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    note([NSString stringWithFormat:@"dest: entered (mask %@, source %s)", op_name(info.draggingSourceOperationMask),
                                    info.draggingSource ? "here" : "elsewhere"]);
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { note(@"dest: exited"); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    note([NSString stringWithFormat:@"dest: perform [%@]", [info.draggingPasteboard stringForType:NSPasteboardTypeString]]);
    return YES;
}
- (void)draggingEnded:(id<NSDraggingInfo>)info { note(@"dest: ended"); }
@end

static int
destination(void)
{
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    calls = [NSMutableArray array];
    NSWindow *b = [[NSWindow alloc] initWithContentRect:NSMakeRect(320, 120, 420, 340) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    DestView *dest = [[DestView alloc] initWithFrame:NSMakeRect(20, 220, 120, 90)];
    [dest registerForDraggedTypes:@[ NSPasteboardTypeString ]];
    [b.contentView addSubview:dest];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 20, 380, 180)];
    tv.string = @"Hello";
    [b.contentView addSubview:tv];
    [b makeKeyAndOrderFront:nil];
    note(@"ready");
    /* runs until the first process kills it, writing the text view's string as it changes */
    for (;;) {
        pump(0.2);
        NSString *s = [NSString stringWithFormat:@"%@\ntext: [%@]", [calls componentsJoinedByString:@"\n"], tv.string];
        [s writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return 0;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-drag-apps-%d.log",
                                                                                                      argc > 1 && !strcmp(argv[1], "dest") ? getppid() : getpid()]];
        if (argc > 1 && !strcmp(argv[1], "dest"))
            return destination();
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-dawt.%d", getpid());
        setenv(FWS_SOCKET_ENV, sock, 1);
        pid_t spid, dpid;
        char *args[] = {(char *)server, "--headless", "--size", "800x600", "--scale", "2", NULL};
        if (posix_spawn(&spid, server, NULL, NULL, args, environ)) {
            printf("can't start %s\n", server);
            return 1;
        }
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        FWSSetCursorVisible(false);
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        char *dargs[] = {argv[0], "dest", NULL};
        if (posix_spawnp(&dpid, argv[0], NULL, NULL, dargs, environ)) {
            printf("can't start the destination\n");
            return 1;
        }
        for (int i = 0; i < 200 && ![[NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil] hasPrefix:@"ready"]; i++)
            usleep(50000);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        calls = [NSMutableArray array];
        NSWindow *a = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 300, 200, 160) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        SourceView *src = [[SourceView alloc] initWithFrame:NSMakeRect(20, 20, 60, 60)];
        src.text = @"from the other app";
        [a.contentView addSubview:src];
        [a orderFront:nil];
        pump(0.5);

        /* the destination's window: 320,120 420x340; its destination view at 20,220 120x90,
           the text view at 20,20 */
        NSPoint from = [a convertPointToScreen:[src convertPoint:NSMakePoint(30, 30) toView:nil]];
        NSPoint toDest = NSMakePoint(320 + 80, 120 + 265), toText = NSMakePoint(320 + 200, 120 + 190);
        for (int which = 0; which < 2; which++) {
            NSPoint to = which ? toText : toDest;
            post_at(FWS_EVENT_LEFT_DOWN, from);
            post_at(FWS_EVENT_LEFT_DRAGGED, NSMakePoint(from.x + 10, from.y));
            NSTimer *move = [NSTimer timerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *t) {
                post_at(FWS_EVENT_LEFT_DRAGGED, to);
            }];
            NSTimer *up = [NSTimer timerWithTimeInterval:1.2 repeats:NO block:^(NSTimer *t) {
                post_at(FWS_EVENT_LEFT_UP, to);
            }];
            [[NSRunLoop currentRunLoop] addTimer:move forMode:NSRunLoopCommonModes];
            [[NSRunLoop currentRunLoop] addTimer:up forMode:NSRunLoopCommonModes];
            pump(3);
            src.text = @"more text";
        }
        printf("source:\n");
        for (NSString *c in calls)
            printf("  %s\n", c.UTF8String);
        printf("destination:\n");
        NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [log componentsSeparatedByString:@"\n"])
            if (line.length && ![line isEqualToString:@"ready"])
                printf("  %s\n", line.UTF8String);
        kill(dpid, SIGTERM);
        kill(spid, SIGTERM);
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    }
    return 0;
}

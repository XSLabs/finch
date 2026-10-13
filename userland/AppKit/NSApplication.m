/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSApplication: the app's connection to the window server, its event
 * queue and main loop, and the routing of actions.
 *
 * Events arrive on the main run loop (CoreGraphics' window-server client
 * reads them in a CFFileDescriptor source in the common modes) and are
 * queued as NSEvents. -nextEventMatchingMask:... runs the run loop in the
 * mode asked for until a matching event is queued; windows that need it
 * are redrawn before the run loop waits, as on macOS.
 */
#import "NSMenu_Finch.h"
#import "NSStoryboard_Finch.h"
#include <dlfcn.h>

id NSApp = nil;

NSNotificationName NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
NSNotificationName NSApplicationDidHideNotification = @"NSApplicationDidHideNotification";
NSNotificationName NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
NSNotificationName const NSApplicationDidFinishRestoringWindowsNotification = @"NSApplicationDidFinishRestoringWindowsNotification";
NSNotificationName NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
NSNotificationName NSApplicationDidUnhideNotification = @"NSApplicationDidUnhideNotification";
NSNotificationName NSApplicationDidUpdateNotification = @"NSApplicationDidUpdateNotification";
NSNotificationName NSApplicationWillBecomeActiveNotification = @"NSApplicationWillBecomeActiveNotification";
NSNotificationName NSApplicationWillHideNotification = @"NSApplicationWillHideNotification";
NSNotificationName NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";
NSNotificationName NSApplicationWillResignActiveNotification = @"NSApplicationWillResignActiveNotification";
NSNotificationName NSApplicationWillUnhideNotification = @"NSApplicationWillUnhideNotification";
NSNotificationName NSApplicationWillUpdateNotification = @"NSApplicationWillUpdateNotification";
NSNotificationName NSApplicationWillTerminateNotification = @"NSApplicationWillTerminateNotification";
NSNotificationName NSApplicationDidChangeScreenParametersNotification =
    @"NSApplicationDidChangeScreenParametersNotification";
NSNotificationName NSApplicationProtectedDataWillBecomeUnavailableNotification =
    @"NSApplicationProtectedDataWillBecomeUnavailableNotification";
NSNotificationName NSApplicationProtectedDataDidBecomeAvailableNotification =
    @"NSApplicationProtectedDataDidBecomeAvailableNotification";
NSNotificationName const NSApplicationDidChangeOcclusionStateNotification =
    @"NSApplicationDidChangeOcclusionStateNotification";
NSString *const NSApplicationLaunchIsDefaultLaunchKey = @"NSApplicationLaunchIsDefaultLaunchKey";
NSString *const NSApplicationLaunchUserNotificationKey = @"NSApplicationLaunchUserNotificationKey";
NSString *const NSApplicationLaunchRemoteNotificationKey = @"NSApplicationLaunchRemoteNotificationKey";
NSRunLoopMode NSModalPanelRunLoopMode = @"NSModalPanelRunLoopMode";
NSRunLoopMode NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";
NSAboutPanelOptionKey const NSAboutPanelOptionCredits = @"Credits";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationName = @"ApplicationName";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationIcon = @"ApplicationIcon";
NSAboutPanelOptionKey const NSAboutPanelOptionVersion = @"Version";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationVersion = @"ApplicationVersion";

static NSMutableArray<NSEvent *> *queue;
static CFRunLoopSourceRef post_source;
static CFRunLoopObserverRef display_observer;
static BOOL needs_display;
static NSWindow *key_window, *main_window;  /* not retained */

@interface NSApplication (FinchModal)
- (void)_finchServerEvent:(const FWSEvent *)e;
@end

@implementation NSApplication {
    id<NSApplicationDelegate> _delegate;  /* not retained */
    NSEvent *_currentEvent;
    NSMenu *_mainMenu, *_windowsMenu, *_servicesMenu, *_helpMenu;
    NSImage *_icon;
    NSApplicationActivationPolicy _policy;
    NSApplicationPresentationOptions _presentation;
    NSMutableArray *_modalWindows;   /* the modal session stack */
    NSInteger _modalResponse;
    NSAppearance *_appearance;
    struct {
        unsigned running : 1;
        unsigned active : 1;
        unsigned hidden : 1;
        unsigned launched : 1;
        unsigned stopModal : 1;
        unsigned terminating : 1;
    } _a;
}

#pragma mark - Creating

+ (NSApplication *)sharedApplication
{
    if (!NSApp) {
        NSApp = [[self alloc] init];
    }
    return NSApp;
}

static void
server_event(const FWSEvent *e, void *info)
{
    [(NSApplication *)NSApp _finchServerEvent:e];
}

static void
post_perform(void *info)
{
    /* Nothing to do: being signalled makes the run loop return to -nextEventMatchingMask:. */
}

static void
before_waiting(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    if (needs_display)
        [(NSApplication *)NSApp updateWindows];
}

- (instancetype)init
{
    if (NSApp && NSApp != self) {
        [self release];
        return [NSApp retain];
    }
    self = [super init];
    if (!self)
        return nil;
    NSApp = self;
    if (!queue)
        queue = [[NSMutableArray alloc] init];
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopAddCommonMode(main, (CFStringRef)NSEventTrackingRunLoopMode);
    CFRunLoopAddCommonMode(main, (CFStringRef)NSModalPanelRunLoopMode);
    CFRunLoopSourceContext ctx = {0};
    ctx.perform = post_perform;
    post_source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    CFRunLoopAddSource(main, post_source, kCFRunLoopCommonModes);
    display_observer = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, 2000000, before_waiting, NULL);
    CFRunLoopAddObserver(main, display_observer, kCFRunLoopCommonModes);
    FWSSetEventHandler(server_event, NULL);
    _policy = NSApplicationActivationPolicyRegular;
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

#pragma mark - Delegate

- (id<NSApplicationDelegate>)delegate { return _delegate; }

- (void)setDelegate:(id<NSApplicationDelegate>)delegate
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_delegate)
        [nc removeObserver:_delegate name:nil object:self];
    _delegate = delegate;
    if (!delegate)
        return;
    static const struct {
        const char *selector;
        NSNotificationName const *name;
    } hooks[] = {
        {"applicationWillFinishLaunching:", &NSApplicationWillFinishLaunchingNotification},
        {"applicationDidFinishLaunching:", &NSApplicationDidFinishLaunchingNotification},
        {"applicationWillBecomeActive:", &NSApplicationWillBecomeActiveNotification},
        {"applicationDidBecomeActive:", &NSApplicationDidBecomeActiveNotification},
        {"applicationWillResignActive:", &NSApplicationWillResignActiveNotification},
        {"applicationDidResignActive:", &NSApplicationDidResignActiveNotification},
        {"applicationWillHide:", &NSApplicationWillHideNotification},
        {"applicationDidHide:", &NSApplicationDidHideNotification},
        {"applicationWillUnhide:", &NSApplicationWillUnhideNotification},
        {"applicationDidUnhide:", &NSApplicationDidUnhideNotification},
        {"applicationWillUpdate:", &NSApplicationWillUpdateNotification},
        {"applicationDidUpdate:", &NSApplicationDidUpdateNotification},
        {"applicationWillTerminate:", &NSApplicationWillTerminateNotification},
        {"applicationDidChangeScreenParameters:", &NSApplicationDidChangeScreenParametersNotification},
        {"applicationDidChangeOcclusionState:", &NSApplicationDidChangeOcclusionStateNotification},
    };
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++) {
        SEL sel = sel_registerName(hooks[i].selector);
        if ([(id)delegate respondsToSelector:sel])
            [nc addObserver:delegate selector:sel name:*hooks[i].name object:self];
    }
}

#pragma mark - Windows

- (NSArray<NSWindow *> *)windows { return FinchAllWindows(); }
- (NSWindow *)keyWindow { return key_window; }
- (NSWindow *)mainWindow { return main_window; }
- (NSWindow *)modalWindow { return [_modalWindows lastObject]; }

void
FinchApplicationSetKeyWindow(NSWindow *window)
{
    key_window = window;
}

void
FinchApplicationSetMainWindow(NSWindow *window)
{
    main_window = window;
}

void
FinchApplicationNeedsDisplay(void)
{
    if (needs_display)
        return;
    needs_display = YES;
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void
FinchApplicationWindowOrderedOut(NSWindow *window)
{
    NSApplication *app = NSApp;
    if (!app || app->_a.terminating || ![app->_delegate respondsToSelector:
                                                            @selector(applicationShouldTerminateAfterLastWindowClosed:)])
        return;
    for (NSWindow *w in FinchAllWindows())
        if (w != window && [w isVisible] && ![w isKindOfClass:[NSPanel class]])
            return;
    if ([app->_delegate applicationShouldTerminateAfterLastWindowClosed:app])
        [app performSelector:@selector(terminate:) withObject:app afterDelay:0];
}

- (NSWindow *)windowWithWindowNumber:(NSInteger)number
{
    return FinchWindowForNumber(number);
}

- (void)enumerateWindowsWithOptions:(NSWindowListOptions)options
                         usingBlock:(void (NS_NOESCAPE ^)(NSWindow *, BOOL *))block
{
    BOOL stop = NO;
    for (NSWindow *w in FinchAllWindows()) {
        block(w, &stop);
        if (stop)
            break;
    }
}

- (NSArray *)orderedWindows
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [a addObject:w];
    return a;
}

- (void)updateWindows
{
    needs_display = NO;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillUpdateNotification object:self];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible] && [w isAutodisplay])
            [w displayIfNeeded];
    [nc postNotificationName:NSApplicationDidUpdateNotification object:self];
}

- (void)setWindowsNeedUpdate:(BOOL)flag
{
    if (flag)
        FinchApplicationNeedsDisplay();
}

- (NSWindow *)makeWindowsPerform:(SEL)selector inOrder:(BOOL)inOrder
{
    for (NSWindow *w in FinchAllWindows())
        if (((BOOL(*)(id, SEL))objc_msgSend)(w, selector))
            return w;
    return nil;
}

- (void)miniaturizeAll:(id)sender
{
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [w miniaturize:sender];
}

- (void)arrangeInFront:(id)sender
{
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [w orderFront:sender];
}

#pragma mark - Events

- (NSEvent *)currentEvent { return _currentEvent; }

static void
set_current(NSApplication *app, NSEvent *e)
{
    [e retain];
    [app->_currentEvent release];
    app->_currentEvent = e;
}

/* A window-server event: activation is handled here; input is queued. */
- (void)_finchServerEvent:(const FWSEvent *)e
{
    if (e->type == FWS_EVENT_APP_ACTIVATED || e->type == FWS_EVENT_APP_DEACTIVATED) {
        [self _finchSetActive:e->type == FWS_EVENT_APP_ACTIVATED];
        return;
    }
    if (e->type == FWS_EVENT_WINDOW_MOVED) {
        FinchWindowServerEvent(e);
        return;
    }
    if (e->type == FWS_EVENT_DRAG || e->type == FWS_EVENT_DRAG_REPLY) {
        /* a drag from another app over one of ours, or another app's answer to ours */
        extern void FinchDragMessage(const FWSEvent *e); /* (NSDraggingSession.m) */
        FinchDragMessage(e);
        return;
    }
    if (e->type == FWS_EVENT_HOTKEY_DOWN || e->type == FWS_EVENT_HOTKEY_UP) {
        /* a Carbon hot key (RegisterEventHotKey): to HIToolbox's handlers */
        static void (*carbon_hotkey)(uint32_t, bool);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ carbon_hotkey = dlsym(RTLD_DEFAULT, "FinchHIToolboxHotKey"); });
        if (carbon_hotkey)
            carbon_hotkey(e->button, e->type == FWS_EVENT_HOTKEY_DOWN);
        return;
    }
    NSWindow *window = FinchWindowForNumber(e->window);
    if ((e->type == FWS_EVENT_KEY_DOWN || e->type == FWS_EVENT_KEY_UP || e->type == FWS_EVENT_FLAGS_CHANGED) &&
        !window)
        window = key_window;
    NSEvent *event = FinchEventFromServer(e, window);
    if (!event)
        return;
    NSRect screen = [[NSScreen mainScreen] frame];
    NSUInteger buttons = [NSEvent pressedMouseButtons];
    switch (e->type) {
    case FWS_EVENT_LEFT_DOWN: buttons |= 1; break;
    case FWS_EVENT_LEFT_UP: buttons &= ~1u; break;
    case FWS_EVENT_RIGHT_DOWN: buttons |= 2; break;
    case FWS_EVENT_RIGHT_UP: buttons &= ~2u; break;
    case FWS_EVENT_OTHER_DOWN: buttons |= 1u << e->button; break;
    case FWS_EVENT_OTHER_UP: buttons &= ~(1u << e->button); break;
    }
    FinchEventNoteModifiers([event modifierFlags], NSMakePoint(e->screen_x, NSMaxY(screen) - e->screen_y), buttons);
    /* Coalesce moves and drags, as macOS does. */
    NSEventType type = [event type];
    if ((type == NSEventTypeMouseMoved || type == NSEventTypeLeftMouseDragged) && [queue count] &&
        [[queue lastObject] type] == type && [[queue lastObject] window] == window)
        [queue removeLastObject];
    [queue addObject:event];
}

- (void)_finchSetActive:(BOOL)active
{
    if (_a.active == (unsigned)active)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:active ? NSApplicationWillBecomeActiveNotification : NSApplicationWillResignActiveNotification
                      object:self];
    _a.active = active;
    if (!active)
        for (NSWindow *w in FinchAllWindows())
            if ([w hidesOnDeactivate] && [w isVisible])
                [w orderOut:self];
    [nc postNotificationName:active ? NSApplicationDidBecomeActiveNotification : NSApplicationDidResignActiveNotification
                      object:self];
}

static NSEvent *
take_matching(NSEventMask mask, BOOL dequeue)
{
    for (NSUInteger i = 0; i < [queue count]; i++) {
        NSEvent *e = queue[i];
        if (mask & NSEventMaskFromType([e type])) {
            [[e retain] autorelease];
            if (dequeue)
                [queue removeObjectAtIndex:i];
            return e;
        }
    }
    return nil;
}

- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)expiration inMode:(NSRunLoopMode)mode
                           dequeue:(BOOL)deqFlag
{
    if (!mode)
        mode = NSDefaultRunLoopMode;
    for (;;) {
        NSEvent *e = take_matching(mask, deqFlag);
        if (e && deqFlag) {
            e = FinchEventApplyLocalMonitors(e);
            if (!e)
                continue;
        }
        if (e) {
            if (deqFlag)
                set_current(self, e);
            return e;
        }
        NSTimeInterval wait = expiration ? [expiration timeIntervalSinceNow] : 0;
        if (wait <= 0) {
            /* one pass, to pick up what is pending */
            CFRunLoopRunInMode((CFStringRef)mode, 0, true);
            e = take_matching(mask, deqFlag);
            if (e && deqFlag)
                e = FinchEventApplyLocalMonitors(e);
            if (e && deqFlag)
                set_current(self, e);
            return e;
        }
        if (needs_display)
            [self updateWindows];
        CFRunLoopRunResult r = CFRunLoopRunInMode((CFStringRef)mode, MIN(wait, 1e10), true);
        if (r == kCFRunLoopRunFinished)
            [NSThread sleepForTimeInterval:MIN(wait, 0.01)];  /* nothing to wait on in this mode */
    }
}

- (void)discardEventsMatchingMask:(NSEventMask)mask beforeEvent:(NSEvent *)lastEvent
{
    NSUInteger end = lastEvent ? [queue indexOfObjectIdenticalTo:lastEvent] : [queue count];
    if (end == NSNotFound)
        end = [queue count];
    for (NSInteger i = (NSInteger)end - 1; i >= 0; i--)
        if (mask & NSEventMaskFromType([queue[(NSUInteger)i] type]))
            [queue removeObjectAtIndex:(NSUInteger)i];
}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)flag
{
    if (!event)
        return;
    if (flag)
        [queue insertObject:event atIndex:0];
    else
        [queue addObject:event];
    CFRunLoopSourceSignal(post_source);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

/* A drag begun while an event was handled runs as soon as that event is done, before
   any later event is read (NSDraggingSession.m), as Apple's takes over the mouse. */
- (void)sendEvent:(NSEvent *)event
{
    extern void FinchRunPendingDrag(void);
    [self _finchDispatchEvent:event];
    FinchRunPendingDrag();
}

- (void)_finchDispatchEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    switch (type) {
    case NSEventTypeKeyDown:
        if (([event modifierFlags] & NSEventModifierFlagCommand)) {
            if ([[self keyWindow] performKeyEquivalent:event])
                return;
            if ([_mainMenu performKeyEquivalent:event])
                return;
        }
        [[self keyWindow] sendEvent:event];
        break;
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged:
        [[self keyWindow] sendEvent:event];
        break;
    case NSEventTypeAppKitDefined:
    case NSEventTypeSystemDefined:
    case NSEventTypeApplicationDefined:
    case NSEventTypePeriodic:
        break;
    default: {
        NSWindow *w = [event window];
        if (_modalWindows.count && w && w != [_modalWindows lastObject] && ![w worksWhenModal]) {
            if (type == NSEventTypeLeftMouseDown)
                NSBeep();
            return;
        }
        [w sendEvent:event];
        break;
    }
    }
}

- (void)preventWindowOrdering {}

#pragma mark - Running

- (BOOL)isRunning { return _a.running; }
/* SPI SwiftUI calls as an app starts (through its private-API shims): launch is complete
   when the app finishes launching, and the rest change nothing in Finch's AppKit. */
- (void)markAppLaunchComplete {}
- (void)_setAlwaysCallDelegateBeforeSidebandUpdaters:(BOOL)flag {}
- (void)_setAlwaysInstallWindowTabItems:(BOOL)flag {}
- (void)_setUsingModernDocuments:(BOOL)flag {}

- (BOOL)isActive { return _a.active; }

/* FINCH_DUMP_VIEWS=SECONDS prints every window's views once, that long after launch (to see
   why an app's window looks wrong) */
static void
dump_view(NSView *v, int depth)
{
    NSRect f = [v frame], b = [v bounds];
    NSRect inWindow = [v convertRect:b toView:nil];
    fprintf(stderr, "%*s%s frame %s bounds %s in window %s%s%s%s%s\n", depth * 2, "", object_getClassName(v),
            NSStringFromRect(f).UTF8String, NSStringFromRect(b).UTF8String, NSStringFromRect(inWindow).UTF8String,
            [v isHidden] ? " hidden" : "", [v isOpaque] ? " opaque" : "", [v isFlipped] ? " flipped" : "",
            [v wantsLayer] ? " layer" : "");
    if ([v isKindOfClass:[NSButton class]]) {
        NSButton *b = (NSButton *)v;
        fprintf(stderr, "%*s  title \"%s\" image %s position %ld bezel %ld action %s\n", depth * 2, "", [[b title] UTF8String],
                [b image] ? NSStringFromSize([[b image] size]).UTF8String : "none", (long)[b imagePosition], (long)[b bezelStyle],
                [b action] ? sel_getName([b action]) : "-");
    }
    for (NSView *sub in [v subviews])
        dump_view(sub, depth + 1);
}

/* FINCH_DUMP_THREADS=SECONDS prints every thread's stack once, that long after launch (to
   see what an app is waiting on): each thread's frame-pointer chain, named with dladdr. */
static void
dump_threads(void)
{
    thread_act_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
        return;
    thread_t me = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        fprintf(stderr, "thread %u%s\n", i, threads[i] == me ? " (dumping)" : "");
        if (threads[i] == me)
            continue;
        thread_suspend(threads[i]);
        arm_thread_state64_t st;
        mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS) {
            uintptr_t pcs[40];
            int depth = 0;
            pcs[depth++] = (uintptr_t)__darwin_arm_thread_state64_get_pc(st);
            pcs[depth++] = (uintptr_t)__darwin_arm_thread_state64_get_lr(st);
            uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(st);
            while (fp && depth < 40 && !(fp & 7)) {
                uintptr_t *frame = (uintptr_t *)fp;
                uintptr_t next = frame[0], lr = frame[1] & 0x0000000fffffffffULL;
                if (!lr || next <= fp)
                    break;
                pcs[depth++] = lr;
                fp = next;
            }
            for (int k = 0; k < depth; k++) {
                Dl_info info;
                uintptr_t pc = pcs[k] & 0x0000000fffffffffULL;
                if (dladdr((void *)pc, &info) && info.dli_sname)
                    fprintf(stderr, "  %2d %s %s + %lu\n", k, strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
                            info.dli_sname, (unsigned long)(pc - (uintptr_t)info.dli_saddr));
                else if (dladdr((void *)pc, &info))
                    fprintf(stderr, "  %2d %s + 0x%lx\n", k, strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
                            (unsigned long)(pc - (uintptr_t)info.dli_fbase));
                else
                    fprintf(stderr, "  %2d 0x%lx\n", k, (unsigned long)pc);
            }
        }
        thread_resume(threads[i]);
    }
}

/* FINCH_PROFILE_MAIN=SECONDS[,COUNT] samples the main thread's stack COUNT times (100 by
   default), 20 ms apart, starting that long after launch, and prints the functions seen,
   the most often first: where a busy main thread spends its time. */
static void
sample_main_thread(thread_t main, int samples)
{
    NSCountedSet *seen = [NSCountedSet set];
    NSCountedSet *leaves = [NSCountedSet set];
    for (int s = 0; s < samples; s++) {
        usleep(20000);
        thread_suspend(main);
        arm_thread_state64_t st;
        mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
        uintptr_t pcs[64];
        int depth = 0;
        if (thread_get_state(main, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS) {
            pcs[depth++] = (uintptr_t)__darwin_arm_thread_state64_get_pc(st);
            uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(st);
            while (fp && depth < 64 && !(fp & 7)) {
                uintptr_t *frame = (uintptr_t *)fp;
                uintptr_t next = frame[0], lr = frame[1] & 0x0000000fffffffffULL;
                if (!lr || next <= fp)
                    break;
                pcs[depth++] = lr;
                fp = next;
            }
        }
        thread_resume(main);
        NSMutableSet *once = [NSMutableSet set];
        for (int k = 0; k < depth; k++) {
            Dl_info info;
            uintptr_t pc = pcs[k] & 0x0000000fffffffffULL;
            NSString *name;
            if (dladdr((void *)pc, &info) && info.dli_sname)
                name = [NSString stringWithFormat:@"%s %s", strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname, info.dli_sname];
            else if (dladdr((void *)pc, &info))
                name = [NSString stringWithFormat:@"%s + 0x%lx", strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
                                                  (unsigned long)(pc - (uintptr_t)info.dli_fbase)];
            else
                name = [NSString stringWithFormat:@"0x%lx", (unsigned long)pc];
            if (k == 0)
                [leaves addObject:name];
            if (![once containsObject:name]) {
                [once addObject:name];
                [seen addObject:name];
            }
        }
    }
    for (NSCountedSet *set in @[ seen, leaves ]) {
        fprintf(stderr, set == seen ? "main thread, %d samples (inclusive):\n" : "leaf functions:\n", samples);
        NSArray *sorted = [[set allObjects] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSUInteger x = [set countForObject:a], y = [set countForObject:b];
            return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
        }];
        for (NSUInteger i = 0; i < sorted.count && i < 60; i++)
            fprintf(stderr, "  %4lu %s\n", (unsigned long)[set countForObject:sorted[i]], [sorted[i] UTF8String]);
    }
    /* then how long a block sent to the main queue waits */
    for (int i = 0; i < 3; i++) {
        uint64_t sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block uint64_t ran = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            ran = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)))
            fprintf(stderr, "main queue: no answer in 5 s\n");
        else
            fprintf(stderr, "main queue: %.1f ms\n", (ran - sent) / 1e6);
    }
}

static void
schedule_view_dump(void)
{
    const char *sampleEnv = getenv("FINCH_PROFILE_MAIN");
    if (sampleEnv) {
        thread_t main = mach_thread_self();
        const char *comma = strchr(sampleEnv, ',');
        int samples = comma ? atoi(comma + 1) : 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(sampleEnv) * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                           @autoreleasepool {
                               sample_main_thread(main, samples > 0 ? samples : 100);
                           }
                       });
    }
    const char *threadsEnv = getenv("FINCH_DUMP_THREADS");
    if (threadsEnv)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(threadsEnv) * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                           dump_threads();
                       });
    const char *env = getenv("FINCH_DUMP_VIEWS");
    if (!env)
        return;
    [NSTimer scheduledTimerWithTimeInterval:atof(env) repeats:NO block:^(NSTimer *t) {
        for (NSWindow *w in [NSApp windows]) {
            fprintf(stderr, "window \"%s\" %s%s\n", [[w title] UTF8String], NSStringFromRect([w frame]).UTF8String,
                    [w isVisible] ? "" : " (not visible)");
            NSView *top = [[w contentView] superview] ?: [w contentView];
            if (top)
                dump_view(top, 1);
        }
    }];
}

- (void)finishLaunching
{
    if (_a.launched)
        return;
    _a.launched = YES;
    schedule_view_dump();
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillFinishLaunchingNotification object:self];
    if (_policy == NSApplicationActivationPolicyRegular)
        [self activateIgnoringOtherApps:YES];
    FinchMenuBarDidLaunch();  /* the menu bar shows from now on (FinchMenuWindow.m) */
    /* windows would be restored here; none are kept between launches yet */
    [nc postNotificationName:NSApplicationDidFinishRestoringWindowsNotification object:self];
    [nc postNotificationName:NSApplicationDidFinishLaunchingNotification
                      object:self
                    userInfo:@{NSApplicationLaunchIsDefaultLaunchKey : @YES}];
    /* Then, as the "open application" or "open documents" Apple event would on macOS. */
    [self performSelector:@selector(_finchOpenLaunchDocuments) withObject:nil afterDelay:0];
}

/*
 * The files named on the command line (how Finch's NSWorkspace hands them to
 * an app it launches), else an untitled document: the delegate decides
 * (application:openURLs:, application:openFiles:, application:openFile:;
 * applicationShouldOpenUntitledFile:, applicationOpenUntitledFile:), then
 * the shared document controller, for apps that declare document types.
 */
- (void)_finchOpenLaunchDocuments
{
    id d = _delegate;
    /* As Apple's: a document app is one whose document types name a document class it has
       (an app can declare types it only views or exports, with no NSDocument behind them). */
    BOOL documentApp = NO;
    for (NSDictionary *t in [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDocumentTypes"]) {
        NSString *cls = [t isKindOfClass:[NSDictionary class]] ? t[@"NSDocumentClass"] : nil;
        if ([cls isKindOfClass:[NSString class]] && NSClassFromString(cls))
            documentApp = YES;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 1; i < [args count]; i++) {
        NSString *a = args[i];
        if ([a hasPrefix:@"-"]) {
            i++;  /* -Key value: a defaults argument */
            continue;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:a])
            [urls addObject:[NSURL fileURLWithPath:a]];
    }
    if ([urls count]) {
        if ([d respondsToSelector:@selector(application:openURLs:)]) {
            [d application:self openURLs:urls];
        } else if ([d respondsToSelector:@selector(application:openFiles:)]) {
            [d application:self openFiles:[urls valueForKey:@"path"]];
        } else if ([d respondsToSelector:@selector(application:openFile:)]) {
            for (NSURL *u in urls)
                [d application:self openFile:[u path]];
        } else if (documentApp) {
            for (NSURL *u in urls)
                [[NSDocumentController sharedDocumentController]
                    openDocumentWithContentsOfURL:u
                                          display:YES
                                completionHandler:^(NSDocument *doc, BOOL already, NSError *error) {
                                    if (error)
                                        [self presentError:error];
                                }];
        }
        return;
    }
    if ([d respondsToSelector:@selector(applicationShouldOpenUntitledFile:)] && ![d applicationShouldOpenUntitledFile:self])
        return;
    if ([d respondsToSelector:@selector(applicationOpenUntitledFile:)]) {
        [d applicationOpenUntitledFile:self];
    } else if (documentApp) {
        NSError *error = nil;
        if (![[NSDocumentController sharedDocumentController] openUntitledDocumentAndDisplay:YES error:&error] && error)
            [self presentError:error];
    }
}

- (void)run
{
    [self finishLaunching];
    _a.running = YES;
    while (_a.running) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSEvent *e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                          inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e)
            [self sendEvent:e];
        [pool drain];
    }
}

static NSEvent *
wake_event(void)
{
    return [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                             timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
}

- (void)stop:(id)sender
{
    if (_modalWindows.count) {
        [self stopModal];
        return;
    }
    _a.running = NO;
    [self postEvent:wake_event() atStart:NO];
}

- (void)terminate:(id)sender
{
    /* as Apple's: documents that autosave in place are saved before quitting */
    Class dc = FINCH_CLASS(NSDocumentController);
    if (dc)
        for (NSDocument *doc in [[[[dc sharedDocumentController] documents] copy] autorelease])
            if ([[doc class] autosavesInPlace] && [doc hasUnautosavedChanges])
                [doc autosaveWithImplicitCancellability:NO completionHandler:^(NSError *error) {}];
    NSApplicationTerminateReply reply = NSTerminateNow;
    if ([(id)_delegate respondsToSelector:@selector(applicationShouldTerminate:)])
        reply = [_delegate applicationShouldTerminate:self];
    if (reply == NSTerminateNow)
        [self _finchTerminateNow];
}

- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate
{
    if (shouldTerminate)
        [self _finchTerminateNow];
}

- (void)_finchTerminateNow
{
    _a.terminating = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillTerminateNotification object:self];
    [[NSUserDefaults standardUserDefaults] synchronize];
    exit(0);
}

- (void)replyToOpenOrPrint:(NSApplicationDelegateReply)reply {}

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    [self _finchSetActive:YES];
}

- (void)activate
{
    [self activateIgnoringOtherApps:YES];
}

- (void)yieldActivationToApplication:(NSRunningApplication *)application {}
- (void)yieldActivationToApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {}

- (void)deactivate
{
    [self _finchSetActive:NO];
}

- (void)hide:(id)sender
{
    if (_a.hidden)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillHideNotification object:self];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible] && [w canHide])
            [w orderOut:sender];
    _a.hidden = YES;
    [nc postNotificationName:NSApplicationDidHideNotification object:self];
}

- (void)unhide:(id)sender
{
    [self unhideWithoutActivation];
    [self activateIgnoringOtherApps:YES];
}

- (void)unhideWithoutActivation
{
    if (!_a.hidden)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillUnhideNotification object:self];
    _a.hidden = NO;
    [nc postNotificationName:NSApplicationDidUnhideNotification object:self];
}

- (BOOL)isHidden { return _a.hidden; }
- (void)hideOtherApplications:(id)sender {}
- (void)unhideAllApplications:(id)sender {}

- (NSApplicationActivationPolicy)activationPolicy { return _policy; }

- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy
{
    _policy = policy;
    return YES;
}

- (NSApplicationPresentationOptions)presentationOptions { return _presentation; }
- (void)setPresentationOptions:(NSApplicationPresentationOptions)options { _presentation = options; }
- (NSApplicationPresentationOptions)currentSystemPresentationOptions { return _presentation; }
- (NSApplicationOcclusionState)occlusionState { return NSApplicationOcclusionStateVisible; }
- (NSInteger)requestUserAttention:(NSRequestUserAttentionType)type { return 0; }
- (void)cancelUserAttentionRequest:(NSInteger)request {}
- (BOOL)isProtectedDataAvailable { return YES; }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return NSUserInterfaceLayoutDirectionLeftToRight; }
- (void)registerForRemoteNotifications {}
- (void)unregisterForRemoteNotifications {}
- (BOOL)isRegisteredForRemoteNotifications { return NO; }
- (void)registerServicesMenuSendTypes:(NSArray *)send returnTypes:(NSArray *)ret {}
- (void)disableRelaunchOnLogin {}
- (void)enableRelaunchOnLogin {}
- (BOOL)isAutomaticCustomizeTouchBarMenuItemEnabled { return NO; }
- (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)flag {}

- (NSAppearance *)appearance { return _appearance; }
- (void)setAppearance:(NSAppearance *)appearance { [_appearance autorelease]; _appearance = [appearance retain]; }
/*
 * As Apple's: the system's appearance (AppleInterfaceStyle Dark in the global domain) unless the
 * app sets its own or asks for Aqua (NSRequiresAquaSystemAppearance). Fieldwork draws Night for it.
 */
- (NSAppearance *)effectiveAppearance
{
    if (_appearance)
        return _appearance;
    static NSAppearance *system;
    if (!system) {
        NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
        BOOL dark = style && [style caseInsensitiveCompare:@"Dark"] == NSOrderedSame;
        if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSRequiresAquaSystemAppearance"] boolValue])
            dark = NO;
        system = [[NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua] retain];
    }
    return system;
}

#pragma mark - Modal sessions

struct _NSModalSession {
    NSWindow *window;
    NSInteger response;
    BOOL done;
};

- (NSModalSession)beginModalSessionForWindow:(NSWindow *)window
{
    if (!_modalWindows)
        _modalWindows = [[NSMutableArray alloc] init];
    [_modalWindows addObject:window];
    NSModalSession s = calloc(1, sizeof *s);
    s->window = window;
    s->response = NSModalResponseContinue;
    if (![window isVisible])
        [window center];
    [window makeKeyAndOrderFront:self];
    _a.stopModal = NO;
    return s;
}

- (NSModalResponse)runModalSession:(NSModalSession)session
{
    NSEvent *e;
    while (!_a.stopModal &&
           (e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSModalPanelRunLoopMode
                                    dequeue:YES]))
        [self sendEvent:e];
    if (_a.stopModal) {
        _a.stopModal = NO;
        return _modalResponse;
    }
    return NSModalResponseContinue;
}

- (void)endModalSession:(NSModalSession)session
{
    [_modalWindows removeObjectIdenticalTo:session->window];
    free(session);
}

- (NSModalResponse)runModalForWindow:(NSWindow *)window
{
    NSModalSession s = [self beginModalSessionForWindow:window];
    NSModalResponse r;
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSEvent *e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                          inMode:NSModalPanelRunLoopMode dequeue:YES];
        if (e && !_a.stopModal)
            [self sendEvent:e];
        [pool drain];
        if (_a.stopModal) {
            _a.stopModal = NO;
            r = _modalResponse;
            break;
        }
    }
    [self endModalSession:s];
    return r;
}

- (void)stopModal
{
    [self stopModalWithCode:NSModalResponseStop];
}

- (void)stopModalWithCode:(NSModalResponse)code
{
    _modalResponse = code;
    _a.stopModal = YES;
    [self postEvent:wake_event() atStart:NO];
}

- (void)abortModal
{
    [self stopModalWithCode:NSModalResponseAbort];
}

- (NSInteger)runModalForWindow:(NSWindow *)window relativeToWindow:(NSWindow *)docWindow
{
    return [self runModalForWindow:window];
}

- (void)beginSheet:(NSWindow *)sheet modalForWindow:(NSWindow *)docWindow modalDelegate:(id)modalDelegate
    didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    [docWindow beginSheet:sheet completionHandler:nil];
}

- (void)endSheet:(NSWindow *)sheet
{
    [[sheet sheetParent] endSheet:sheet];
}

- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)returnCode
{
    [[sheet sheetParent] endSheet:sheet returnCode:returnCode];
}

#pragma mark - Actions

/* Where an action with no target goes: the key window's responder chain, the key window and its delegate,
 * the same for the main window, then the app and its delegate. */
- (id)targetForAction:(SEL)action
{
    return [self targetForAction:action to:nil from:nil];
}

static id
responds(id object, SEL action)
{
    return object && [object respondsToSelector:action] ? object : nil;
}

static id
search_window(NSWindow *w, SEL action)
{
    if (!w)
        return nil;
    for (NSResponder *r = [w firstResponder]; r; r = [r nextResponder])
        if ([r respondsToSelector:action])
            return r;
    id t = responds(w, action) ?: responds([w delegate], action);
    if (!t && [[w windowController] document])
        t = responds([[w windowController] document], action);
    return t;
}

/* As Apple's, an explicit target is returned as it is; -sendAction:to:from: resolves without calling the
 * (overridable) -targetForAction:to:from:. */
static id
resolve_target(NSApplication *self, SEL action, id target)
{
    if (!action)
        return nil;
    if (target)
        return target;
    id t = search_window([self keyWindow], action);
    if (!t && [self mainWindow] != [self keyWindow])
        t = search_window([self mainWindow], action);
    if (!t)
        t = responds(self, action) ?: responds(self->_delegate, action);
    if (!t) {
        Class dc = FINCH_CLASS(NSDocumentController);
        id shared = dc ? [dc sharedDocumentController] : nil;
        t = responds(shared, action);
    }
    return t;
}

- (id)targetForAction:(SEL)action to:(id)target from:(id)sender
{
    return resolve_target(self, action, target);
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender
{
    id t = resolve_target(self, action, target);
    if (!t || ![t respondsToSelector:action])
        return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(t, action, sender);
    return YES;
}

- (BOOL)tryToPerform:(SEL)action with:(id)object
{
    if ([super tryToPerform:action with:object])
        return YES;
    if (_delegate && [(id)_delegate respondsToSelector:action]) {
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, action, object);
        return YES;
    }
    return NO;
}

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    return nil;
}

#pragma mark - Menus and the icon

- (NSMenu *)mainMenu { return _mainMenu; }
- (void)setMainMenu:(NSMenu *)menu
{
    [_mainMenu autorelease];
    _mainMenu = [menu retain];
    FinchMenuBarUpdate();  /* redraws the menu bar, once launched (FinchMenuWindow.m) */
}
- (NSMenu *)windowsMenu { return _windowsMenu; }
- (void)setWindowsMenu:(NSMenu *)menu { [_windowsMenu autorelease]; _windowsMenu = [menu retain]; }
- (NSMenu *)servicesMenu { return _servicesMenu; }
- (void)setServicesMenu:(NSMenu *)menu { [_servicesMenu autorelease]; _servicesMenu = [menu retain]; }
- (NSMenu *)helpMenu { return _helpMenu; }
- (void)setHelpMenu:(NSMenu *)menu { [_helpMenu autorelease]; _helpMenu = [menu retain]; }
- (void)addWindowsItem:(NSWindow *)win title:(NSString *)string filename:(BOOL)isFilename {}
- (void)changeWindowsItem:(NSWindow *)win title:(NSString *)string filename:(BOOL)isFilename {}
- (void)removeWindowsItem:(NSWindow *)win {}
- (void)updateWindowsItem:(NSWindow *)win {}
- (NSImage *)applicationIconImage { return _icon; }
- (void)setApplicationIconImage:(NSImage *)image { [_icon autorelease]; _icon = [image retain]; }
- (NSDockTile *)dockTile { return FinchApplicationDockTile(self); }
- (void)orderFrontStandardAboutPanel:(id)sender {}
- (void)orderFrontStandardAboutPanelWithOptions:(NSDictionary *)options {}
- (void)orderFrontCharacterPalette:(id)sender {}
- (void)orderFrontColorPanel:(id)sender {}
- (void)runPageLayout:(id)sender {}
- (void)showHelp:(id)sender {}
- (void)activateContextHelpMode:(id)sender {}

#pragma mark - Errors

/* The error's recovery attempter, given the alert button chosen (NSAlert.m's buttons are the options). */
static BOOL
attempt_recovery(NSError *error, NSModalResponse response)
{
    id attempter = [error recoveryAttempter];
    NSInteger option = response - NSAlertFirstButtonReturn;
    if (!attempter || option < 0 || option >= (NSInteger)[[error localizedRecoveryOptions] count] ||
        ![attempter respondsToSelector:@selector(attemptRecoveryFromError:optionIndex:)])
        return NO;
    return [attempter attemptRecoveryFromError:error optionIndex:(NSUInteger)option];
}

- (BOOL)presentError:(NSError *)error
{
    if ([(id)_delegate respondsToSelector:@selector(application:willPresentError:)])
        error = [_delegate application:self willPresentError:error];
    return attempt_recovery(error, [[NSAlert alertWithError:error] runModal]);
}

- (void)presentError:(NSError *)error modalForWindow:(NSWindow *)window delegate:(id)delegate
    didPresentSelector:(SEL)didPresentSelector contextInfo:(void *)contextInfo
{
    if ([(id)_delegate respondsToSelector:@selector(application:willPresentError:)])
        error = [_delegate application:self willPresentError:error];
    [[NSAlert alertWithError:error] beginSheetModalForWindow:window
                                           completionHandler:^(NSModalResponse r) {
                                               BOOL recovered = attempt_recovery(error, r);
                                               if (delegate && didPresentSelector)
                                                   ((void (*)(id, SEL, BOOL, void *))objc_msgSend)(
                                                       delegate, didPresentSelector, recovered, contextInfo);
                                           }];
}

@end

#pragma mark - NSApplicationMain

int
NSApplicationMain(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];
    Class principal = NSClassFromString(info[@"NSPrincipalClass"]);
    if (!principal || ![principal isSubclassOfClass:[NSApplication class]])
        principal = [NSApplication class];
    NSApplication *app = [principal sharedApplication];
    NSString *nib = info[@"NSMainNibFile"];
    if ([nib length]) {
        Class nibClass = FINCH_CLASS(NSNib);
        id loaded = nibClass ? [[[nibClass alloc] initWithNibNamed:nib bundle:bundle] autorelease] : nil;
        if (![loaded instantiateWithOwner:app topLevelObjects:NULL])
            NSLog(@"Unable to load nib file: %@, exiting", nib);
    } else if ([info[@"NSMainStoryboardFile"] length]) {
        FinchStoryboardLaunch(app, bundle);  /* NSStoryboard.m */
    }
    [pool drain];
    [app run];
    return 0;
}

BOOL
NSShowsServicesMenuItem(NSString *itemName)
{
    return YES;
}

NSInteger
NSSetShowsServicesMenuItem(NSString *itemName, BOOL enabled)
{
    return 0;
}

BOOL
NSPerformService(NSString *itemName, NSPasteboard *pboard)
{
    return NO;
}

void
NSUpdateDynamicServices(void)
{
}

/*
 * Services providers. Finch has no services daemon (pbs) yet, so other apps
 * can't call a provider; the app's own provider is kept, as Apple's API keeps it.
 */
static NSMutableDictionary *service_providers;

void
NSRegisterServicesProvider(id provider, NSServiceProviderName name)
{
    if (!name)
        return;
    if (!service_providers)
        service_providers = [[NSMutableDictionary alloc] init];
    if (provider)
        service_providers[name] = provider;
    else
        [service_providers removeObjectForKey:name];
}

void
NSUnregisterServicesProvider(NSServiceProviderName name)
{
    if (name)
        [service_providers removeObjectForKey:name];
}

@implementation NSApplication (NSServicesHandling)

static id services_provider;

- (id)servicesProvider { return services_provider; }

- (void)setServicesProvider:(id)provider
{
    [provider retain];
    [services_provider release];
    services_provider = provider;
}

@end

/* The Dock menu a nib connects (the dockMenu outlet). Finch has no Dock yet; it's kept. */
@implementation NSApplication (FinchDockMenu)
static NSMenu *dock_menu;
- (NSMenu *)dockMenu { return dock_menu; }
- (void)setDockMenu:(NSMenu *)menu
{
    [menu retain];
    [dock_menu release];
    dock_menu = menu;
}
@end

@implementation NSApplication (FinchMore)
- (IBAction)orderFrontFontPanel:(id)sender { [[NSFontManager sharedFontManager] orderFrontFontPanel:sender]; }
/* Window restoration isn't kept between launches yet. */
- (BOOL)restoreWindowWithIdentifier:(NSUserInterfaceItemIdentifier)identifier state:(NSCoder *)state
                  completionHandler:(void (^)(NSWindow *, NSError *))completionHandler
{
    return NO;
}
- (void)invalidateRestorableState {}
/* Apple's performance-test hooks. */
- (void)startedTest:(NSString *)name {}
- (void)finishedTest:(NSString *)name {}
@end

#pragma mark - Help menu search

static NSMutableArray *search_handlers;
static BOOL help_book_search = YES;

@implementation NSApplication (FinchHelpSearch)

/* Handlers the Help menu's search field asks for matching items (Finch's Help menu has
   no search field yet; the handlers are kept for it). */
- (void)registerUserInterfaceItemSearchHandler:(id<NSUserInterfaceItemSearching>)handler
{
    if (!search_handlers)
        search_handlers = [[NSMutableArray alloc] init];
    if (handler && ![search_handlers containsObject:handler])
        [search_handlers addObject:handler];
}

- (void)unregisterUserInterfaceItemSearchHandler:(id<NSUserInterfaceItemSearching>)handler
{
    [search_handlers removeObject:handler];
}

- (BOOL)defaultHelpBookSearchEnabled { return help_book_search; }
- (void)setDefaultHelpBookSearchEnabled:(BOOL)flag { help_book_search = flag; }

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ScreenCaptureKit: the displays, apps and windows there are to capture, content
 * filters over them, screenshots and streams of frames, over Finch's window server.
 *
 * A filter is resolved, each time it is captured, into the window server's capture
 * request (FWSCapture): the windows to draw (listed or all but those listed; the desktop
 * is a window, as on macOS), shadows and the cursor; the server composites them afresh, so
 * excluded windows are really absent and a single window is captured alone. Windows of
 * applications are found by owner when captured, so an app's new windows are in.
 *
 * Defaults and values (configuration defaults and presets, frame info keys, the error
 * domain, recording and picker configurations) are Apple's, as measured on macOS 26.4
 * (screencapturekit-test.m). Finch has no screen-recording permission prompt: capture is
 * allowed, as CGPreflightScreenCaptureAccess answers. Not yet: audio and microphone
 * capture (no samples are delivered), HDR (an HDR screenshot is the SDR pixels), the
 * recording output (Finch has no video encoder yet: adding one fails), idle frames.
 */
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach_time.h>
#include "../WindowServer/FinchWSProtocol.h"
#import "SCInternal.h"

CGImageRef FWSCaptureImage(FWSRect rect, uint32_t options, const uint32_t *windows, uint32_t count);

NSString *const SCStreamErrorDomain = @"com.apple.ScreenCaptureKit.SCStreamErrorDomain";
SCStreamFrameInfo const SCStreamFrameInfoStatus = @"SCStreamUpdateFrameStatus";
SCStreamFrameInfo const SCStreamFrameInfoDisplayTime = @"SCStreamUpdateFrameDisplayTime";
SCStreamFrameInfo const SCStreamFrameInfoScaleFactor = @"SCStreamUpdateFrameDisplayResolution";
SCStreamFrameInfo const SCStreamFrameInfoContentScale = @"SCStreamUpdateFrameContentScale";
SCStreamFrameInfo const SCStreamFrameInfoContentRect = @"SCStreamUpdateFrameContentRect";
SCStreamFrameInfo const SCStreamFrameInfoDirtyRects = @"SCStreamUpdateFrameDirtyRect";
SCStreamFrameInfo const SCStreamFrameInfoScreenRect = @"SCStreamUpdateFrameScreenRect";
SCStreamFrameInfo const SCStreamFrameInfoBoundingRect = @"SCStreamUpdateFrameBoundingRect";
SCStreamFrameInfo const SCStreamFrameInfoPresenterOverlayContentRect = @"SCStreamUpdateFramePresenterOverlayContentRect";

NSError *
SCFinchError(SCStreamErrorCode code, NSString *what)
{
    return [NSError errorWithDomain:SCStreamErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : what}];
}

dispatch_queue_t
SCFinchQueue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.apple.ScreenCaptureKit.completion", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static CGFloat
display_scale(CGDirectDisplayID display)
{
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    CGFloat scale = 1;
    if (mode) {
        size_t pw = CGDisplayModeGetPixelWidth(mode), w = CGDisplayModeGetWidth(mode);
        if (w)
            scale = (CGFloat)pw / (CGFloat)w;
        CGDisplayModeRelease(mode);
    }
    return scale > 0 ? scale : 1;
}

#pragma mark - Displays, apps and windows

@interface SCRunningApplication ()
- (instancetype)_initWithPID:(pid_t)pid name:(NSString *)name;
@end

@implementation SCRunningApplication {
    NSString *_bundleIdentifier, *_applicationName;
    pid_t _pid;
}

- (instancetype)_initWithPID:(pid_t)pid name:(NSString *)name
{
    if ((self = [super init])) {
        _pid = pid;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        _bundleIdentifier = [[app bundleIdentifier] copy] ?: @"";
        _applicationName = [([app localizedName] ?: name) copy] ?: @"";
    }
    return self;
}

- (void)dealloc
{
    [_bundleIdentifier release];
    [_applicationName release];
    [super dealloc];
}

- (NSString *)bundleIdentifier { return _bundleIdentifier; }
- (NSString *)applicationName { return _applicationName; }
- (pid_t)processID { return _pid; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SCRunningApplication: %p, %@ (%d)>", self, _bundleIdentifier, _pid];
}

@end

@interface SCWindow ()
- (instancetype)_initWithInfo:(NSDictionary *)info application:(SCRunningApplication *)app;
@end

@implementation SCWindow {
    CGWindowID _windowID;
    CGRect _frame;
    NSString *_title;
    NSInteger _layer;
    SCRunningApplication *_app;
    BOOL _onScreen;
}

- (instancetype)_initWithInfo:(NSDictionary *)info application:(SCRunningApplication *)app
{
    if ((self = [super init])) {
        _windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &_frame);
        _title = [info[(id)kCGWindowName] copy];
        _layer = [info[(id)kCGWindowLayer] integerValue];
        _app = [app retain];
        _onScreen = [info[(id)kCGWindowIsOnscreen] boolValue];
    }
    return self;
}

- (void)dealloc
{
    [_title release];
    [_app release];
    [super dealloc];
}

- (CGWindowID)windowID { return _windowID; }
- (CGRect)frame { return _frame; }
- (NSString *)title { return _title; }
- (NSInteger)windowLayer { return _layer; }
- (SCRunningApplication *)owningApplication { return _app; }
- (BOOL)isOnScreen { return _onScreen; }
- (BOOL)isActive { return _onScreen; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SCWindow: %p, %u \"%@\" %@>", self, _windowID, _title ?: @"",
                                      NSStringFromRect(NSRectFromCGRect(_frame))];
}

@end

@interface SCDisplay ()
- (instancetype)_initWithID:(CGDirectDisplayID)display;
@end

@implementation SCDisplay {
    CGDirectDisplayID _display;
    CGRect _frame;
}

- (instancetype)_initWithID:(CGDirectDisplayID)display
{
    if ((self = [super init])) {
        _display = display;
        _frame = CGDisplayBounds(display);
    }
    return self;
}

- (CGDirectDisplayID)displayID { return _display; }
- (NSInteger)width { return (NSInteger)_frame.size.width; }
- (NSInteger)height { return (NSInteger)_frame.size.height; }
- (CGRect)frame { return _frame; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SCDisplay: %p, %u %ldx%ld>", self, _display, (long)[self width], (long)[self height]];
}

@end

@interface SCShareableContentInfo ()
- (instancetype)_initWithStyle:(SCShareableContentStyle)style scale:(float)scale rect:(CGRect)rect;
@end

@implementation SCShareableContentInfo {
    SCShareableContentStyle _style;
    float _scale;
    CGRect _rect;
}

- (instancetype)_initWithStyle:(SCShareableContentStyle)style scale:(float)scale rect:(CGRect)rect
{
    if ((self = [super init])) {
        _style = style;
        _scale = scale;
        _rect = rect;
    }
    return self;
}

- (SCShareableContentStyle)style { return _style; }
- (float)pointPixelScale { return _scale; }
- (CGRect)contentRect { return _rect; }

@end

static BOOL
is_desktop_window(NSDictionary *info)
{
    return [info[(id)kCGWindowLayer] intValue] <= CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
}

@interface SCShareableContent ()
- (instancetype)_initExcludingDesktop:(BOOL)excludeDesktop option:(CGWindowListOption)option relativeTo:(CGWindowID)window
                                  pid:(pid_t)onlyPID;
@end

@implementation SCShareableContent {
    NSArray *_windows, *_displays, *_apps;
}

- (instancetype)_initExcludingDesktop:(BOOL)excludeDesktop option:(CGWindowListOption)option relativeTo:(CGWindowID)window
                                  pid:(pid_t)onlyPID
{
    if (!(self = [super init]))
        return nil;
    uint32_t n = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &n);
    NSMutableArray *displays = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++)
        [displays addObject:[[[SCDisplay alloc] _initWithID:ids[i]] autorelease]];

    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    NSMutableArray *windows = [NSMutableArray array];
    NSArray *list = [(NSArray *)CGWindowListCopyWindowInfo(option, window) autorelease];
    for (NSDictionary *info in list) {
        pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
        if ((onlyPID && pid != onlyPID) || (excludeDesktop && is_desktop_window(info)))
            continue;
        SCRunningApplication *app = apps[@(pid)];
        if (!app) {
            app = [[[SCRunningApplication alloc] _initWithPID:pid name:info[(id)kCGWindowOwnerName]] autorelease];
            apps[@(pid)] = app;
        }
        [windows addObject:[[[SCWindow alloc] _initWithInfo:info application:app] autorelease]];
    }
    /* the running apps without windows too */
    if (!onlyPID)
        for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
            pid_t pid = [ra processIdentifier];
            if (!apps[@(pid)])
                apps[@(pid)] = [[[SCRunningApplication alloc] _initWithPID:pid name:[ra localizedName]] autorelease];
        }
    else if (!apps[@(onlyPID)])
        apps[@(onlyPID)] = [[[SCRunningApplication alloc] _initWithPID:onlyPID name:[[NSProcessInfo processInfo] processName]] autorelease];
    _displays = [displays copy];
    _windows = [windows copy];
    _apps = [[apps allValues] copy];
    return self;
}

- (void)dealloc
{
    [_windows release];
    [_displays release];
    [_apps release];
    [super dealloc];
}

- (NSArray<SCWindow *> *)windows { return _windows; }
- (NSArray<SCDisplay *> *)displays { return _displays; }
- (NSArray<SCRunningApplication *> *)applications { return _apps; }

static void
deliver_content(SCShareableContent *content, void (^handler)(SCShareableContent *, NSError *))
{
    if (!handler)
        return;
    handler = [[handler copy] autorelease];
    [content retain];
    dispatch_async(SCFinchQueue(), ^{
        if (!CGPreflightScreenCaptureAccess())
            handler(nil, SCFinchError(SCStreamErrorUserDeclined, @"The user declined TCCs for application, window, display capture"));
        else
            handler(content, nil);
        [content release];
    });
}

+ (void)getShareableContentWithCompletionHandler:(void (^)(SCShareableContent *, NSError *))completionHandler
{
    [self getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:completionHandler];
}

+ (void)getCurrentProcessShareableContentWithCompletionHandler:(void (^)(SCShareableContent *, NSError *))completionHandler
{
    SCShareableContent *c = [[[self alloc] _initExcludingDesktop:NO option:kCGWindowListOptionAll relativeTo:kCGNullWindowID
                                                             pid:getpid()] autorelease];
    if (completionHandler) {
        void (^h)(SCShareableContent *, NSError *) = [[completionHandler copy] autorelease];
        [c retain];
        dispatch_async(SCFinchQueue(), ^{
            h(c, nil);
            [c release];
        });
    }
}

+ (void)getShareableContentExcludingDesktopWindows:(BOOL)excludeDesktopWindows onScreenWindowsOnly:(BOOL)onScreenWindowsOnly
                                 completionHandler:(void (^)(SCShareableContent *, NSError *))completionHandler
{
    deliver_content([[[self alloc] _initExcludingDesktop:excludeDesktopWindows
                                                  option:onScreenWindowsOnly ? kCGWindowListOptionOnScreenOnly : kCGWindowListOptionAll
                                              relativeTo:kCGNullWindowID
                                                     pid:0] autorelease],
                    completionHandler);
}

+ (void)getShareableContentExcludingDesktopWindows:(BOOL)excludeDesktopWindows onScreenWindowsOnlyBelowWindow:(SCWindow *)window
                                 completionHandler:(void (^)(SCShareableContent *, NSError *))completionHandler
{
    deliver_content([[[self alloc] _initExcludingDesktop:excludeDesktopWindows
                                                  option:kCGWindowListOptionOnScreenOnly | kCGWindowListOptionOnScreenBelowWindow
                                              relativeTo:[window windowID]
                                                     pid:0] autorelease],
                    completionHandler);
}

+ (void)getShareableContentExcludingDesktopWindows:(BOOL)excludeDesktopWindows onScreenWindowsOnlyAboveWindow:(SCWindow *)window
                                 completionHandler:(void (^)(SCShareableContent *, NSError *))completionHandler
{
    deliver_content([[[self alloc] _initExcludingDesktop:excludeDesktopWindows
                                                  option:kCGWindowListOptionOnScreenOnly | kCGWindowListOptionOnScreenAboveWindow
                                              relativeTo:[window windowID]
                                                     pid:0] autorelease],
                    completionHandler);
}

+ (SCShareableContentInfo *)infoForFilter:(SCContentFilter *)filter
{
    return [[[SCShareableContentInfo alloc] _initWithStyle:[filter style] scale:[filter pointPixelScale]
                                                      rect:[filter contentRect]] autorelease];
}

@end

#pragma mark - Content filters

typedef enum {
    FILTER_WINDOW,              /* one window, desktop-independent */
    FILTER_EXCLUDING_WINDOWS,   /* a display but some windows */
    FILTER_INCLUDING_WINDOWS,   /* only some windows on a display */
    FILTER_INCLUDING_APPS,      /* some apps' windows, but some windows */
    FILTER_EXCLUDING_APPS,      /* a display but some apps' windows (some windows kept) */
} FilterKind;

@implementation SCContentFilter {
    FilterKind _kind;
    SCDisplay *_display;
    SCWindow *_window;
    NSArray *_windows, *_apps;
    BOOL _includeMenuBar;
}

- (instancetype)_initKind:(FilterKind)kind display:(SCDisplay *)display window:(SCWindow *)window windows:(NSArray *)windows
                     apps:(NSArray *)apps
{
    if ((self = [super init])) {
        _kind = kind;
        _display = [display retain];
        _window = [window retain];
        _windows = [windows copy] ?: @[];
        _apps = [apps copy] ?: @[];
        _includeMenuBar = kind != FILTER_WINDOW;
    }
    return self;
}

- (instancetype)init
{
    return [self _initKind:FILTER_EXCLUDING_WINDOWS display:nil window:nil windows:nil apps:nil];
}

- (instancetype)initWithDesktopIndependentWindow:(SCWindow *)window
{
    return [self _initKind:FILTER_WINDOW display:nil window:window windows:nil apps:nil];
}

- (instancetype)initWithDisplay:(SCDisplay *)display excludingWindows:(NSArray<SCWindow *> *)excluded
{
    return [self _initKind:FILTER_EXCLUDING_WINDOWS display:display window:nil windows:excluded apps:nil];
}

- (instancetype)initWithDisplay:(SCDisplay *)display includingWindows:(NSArray<SCWindow *> *)includedWindows
{
    return [self _initKind:FILTER_INCLUDING_WINDOWS display:display window:nil windows:includedWindows apps:nil];
}

- (instancetype)initWithDisplay:(SCDisplay *)display includingApplications:(NSArray<SCRunningApplication *> *)applications
               exceptingWindows:(NSArray<SCWindow *> *)exceptingWindows
{
    return [self _initKind:FILTER_INCLUDING_APPS display:display window:nil windows:exceptingWindows apps:applications];
}

- (instancetype)initWithDisplay:(SCDisplay *)display excludingApplications:(NSArray<SCRunningApplication *> *)applications
               exceptingWindows:(NSArray<SCWindow *> *)exceptingWindows
{
    return [self _initKind:FILTER_EXCLUDING_APPS display:display window:nil windows:exceptingWindows apps:applications];
}

- (void)dealloc
{
    [_display release];
    [_window release];
    [_windows release];
    [_apps release];
    [super dealloc];
}

- (SCStreamType)streamType { return _kind == FILTER_WINDOW ? SCStreamTypeWindow : SCStreamTypeDisplay; }

- (SCShareableContentStyle)style
{
    switch (_kind) {
    case FILTER_WINDOW:
    case FILTER_INCLUDING_WINDOWS:
        return SCShareableContentStyleWindow;
    case FILTER_INCLUDING_APPS:
        return SCShareableContentStyleApplication;
    default:
        return SCShareableContentStyleDisplay;
    }
}

- (CGDirectDisplayID)_finchDisplayID { return _display ? [_display displayID] : CGMainDisplayID(); }

- (float)pointPixelScale { return (float)display_scale([self _finchDisplayID]); }

/* The window's current frame, from the window list (it may have moved). */
- (CGRect)_finchWindowFrame
{
    NSArray *list = [(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, [_window windowID]) autorelease];
    CGRect f = [_window frame];
    if ([list count])
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)list[0][(id)kCGWindowBounds], &f);
    return f;
}

/* What's captured, in global points. */
- (CGRect)_finchScreenRect
{
    if (_kind == FILTER_WINDOW)
        return [self _finchWindowFrame];
    return CGDisplayBounds([self _finchDisplayID]);
}

- (CGRect)contentRect
{
    CGRect r = [self _finchScreenRect];
    return CGRectMake(0, 0, r.size.width, r.size.height);
}

- (BOOL)includeMenuBar { return _includeMenuBar; }
- (void)setIncludeMenuBar:(BOOL)flag { _includeMenuBar = flag; }
- (NSArray<SCDisplay *> *)includedDisplays { return _display ? @[ _display ] : @[]; }
- (NSArray<SCRunningApplication *> *)includedApplications
{
    return _kind == FILTER_INCLUDING_APPS ? _apps : @[];
}
- (NSArray<SCWindow *> *)includedWindows
{
    if (_kind == FILTER_WINDOW)
        return _window ? @[ _window ] : @[];
    return _kind == FILTER_INCLUDING_WINDOWS ? _windows : @[];
}

/* The window server's capture of the filter's content over rect (global points), or the
   whole content; pixels at the display's scale. */
- (CGImageRef)_finchCopyImageOfRect:(CGRect)rect cursor:(BOOL)cursor shadows:(BOOL)shadows
{
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect))
        rect = [self _finchScreenRect];
    NSMutableArray *ids = [NSMutableArray array];
    uint32_t options = 0;
    NSMutableSet *pids = [NSMutableSet set];
    for (SCRunningApplication *a in _apps)
        [pids addObject:@([a processID])];
    NSMutableSet *listed = [NSMutableSet set];
    for (SCWindow *w in _windows)
        [listed addObject:@([w windowID])];
    switch (_kind) {
    case FILTER_WINDOW:
        options = FWS_CAPTURE_INCLUDE;
        [ids addObject:@([_window windowID])];
        break;
    case FILTER_EXCLUDING_WINDOWS:
        options = 0;
        [ids addObjectsFromArray:[listed allObjects]];
        break;
    case FILTER_INCLUDING_WINDOWS:
        options = FWS_CAPTURE_INCLUDE;
        [ids addObjectsFromArray:[listed allObjects]];
        break;
    case FILTER_INCLUDING_APPS:
    case FILTER_EXCLUDING_APPS: {
        options = _kind == FILTER_INCLUDING_APPS ? FWS_CAPTURE_INCLUDE : 0;
        NSArray *list = [(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID) autorelease];
        for (NSDictionary *info in list)
            if ([pids containsObject:info[(id)kCGWindowOwnerPID]] && ![listed containsObject:info[(id)kCGWindowNumber]])
                [ids addObject:info[(id)kCGWindowNumber]];
        break;
    }
    }
    if (cursor)
        options |= FWS_CAPTURE_CURSOR;
    if (shadows)
        options |= FWS_CAPTURE_SHADOWS;
    NSUInteger n = [ids count];
    uint32_t *raw = n ? malloc(n * sizeof(uint32_t)) : NULL;
    for (NSUInteger i = 0; i < n; i++)
        raw[i] = [ids[i] unsignedIntValue];
    FWSRect fr = {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
    CGImageRef im = FWSCaptureImage(fr, options, raw, (uint32_t)n);
    free(raw);
    return im;
}

@end

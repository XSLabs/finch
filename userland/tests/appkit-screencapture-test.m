/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-screencapture-test: ScreenCaptureKit on Finch's window server.
 * Starts a headless server, shows a red and a blue window, then lists the shareable
 * content, captures through each kind of content filter (a window alone, the display
 * without a window, only a window, an app's windows but one), screenshots of a rect
 * (one written to a file), CGWindowListCreateImage, and streams in BGRA and 4:2:0,
 * checking frames follow a change on screen. Finch-only (Apple's asks the user for
 * screen access): compare with appkit-screencapture-test.expected.
 *
 *   finch-appkit-screencapture-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <spawn.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSSetCursorVisible(bool v);
/* (still in CoreGraphics, apps call it; the SDK marks it obsoleted) */
CGImageRef window_list_image(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) __asm("_CGWindowListCreateImage");

static const double kScreenHeight = 600;

@interface Fill : NSView
@property (strong) NSColor *color;
@end

@implementation Fill
- (void)drawRect:(NSRect)r
{
    [self.color setFill];
    NSRectFill(self.bounds);
}
@end

@interface Frames : NSObject <SCStreamOutput>
@property (strong) NSMutableArray *buffers;
@end

@implementation Frames
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type
{
    @synchronized(self) {
        [self.buffers addObject:(__bridge id)sb];
    }
}
@end

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

/* Waits (running the main loop) for a completion handler to set done. */
static void
wait_for(BOOL *done)
{
    for (int i = 0; i < 300 && !*done; i++)
        pump(0.01);
}

/* A pixel of an image (top-left origin) as a colour name. */
static NSString *
pixel(CGImageRef im, double x, double y)
{
    if (!im)
        return @"no image";
    if (x < 0 || y < 0 || x >= CGImageGetWidth(im) || y >= CGImageGetHeight(im))
        return @"outside";
    uint8_t p[4] = {0};
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(p, 1, 1, 8, 4, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(srgb);
    CGContextDrawImage(ctx, CGRectMake(-floor(x), floor(y) - (CGImageGetHeight(im) - 1), CGImageGetWidth(im), CGImageGetHeight(im)), im);
    CGContextRelease(ctx);
    if (p[3] < 16)
        return @"clear";
    if (p[0] > 200 && p[1] < 60 && p[2] < 60)
        return @"red";
    if (p[0] < 60 && p[1] < 60 && p[2] > 200)
        return @"blue";
    if (p[0] < 60 && p[1] > 200 && p[2] < 60)
        return @"green";
    return @"other";
}

/* A window's frame in global (top-left) points. */
static CGRect
cg_frame(NSWindow *w)
{
    NSRect f = w.frame;
    return CGRectMake(f.origin.x, kScreenHeight - NSMaxY(f), f.size.width, f.size.height);
}

/* The centre of a window's content in global points. */
static CGPoint
content_center(NSWindow *w)
{
    NSRect c = [w contentRectForFrameRect:w.frame];
    return CGPointMake(NSMidX(c), kScreenHeight - NSMidY(c));
}

static SCWindow *
find_window(SCShareableContent *content, NSString *title)
{
    for (SCWindow *w in content.windows)
        if ([w.title isEqualToString:title])
            return w;
    return nil;
}

static CGImageRef
capture(SCContentFilter *filter, SCStreamConfiguration *config)
{
    __block CGImageRef out = NULL;
    __block BOOL done = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef im, NSError *e) {
        if (e)
            printf("  error %ld\n", (long)e.code);
        out = CGImageRetain(im);
        done = YES;
    }];
    wait_for(&done);
    return out;
}

static SCStreamConfiguration *
native_config(void)
{
    SCStreamConfiguration *c = [SCStreamConfiguration new];
    c.width = 1600;
    c.height = 1200;
    c.showsCursor = NO;
    return c;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-ascr.%d", getpid());
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
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        NSWindow *red = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 300, 200, 150) styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        red.title = @"Red";
        red.releasedWhenClosed = NO;
        Fill *redFill = [[Fill alloc] initWithFrame:NSZeroRect];
        redFill.color = NSColor.redColor;
        red.contentView = redFill;
        NSWindow *blue = [[NSWindow alloc] initWithContentRect:NSMakeRect(450, 100, 200, 150) styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        blue.title = @"Blue";
        blue.releasedWhenClosed = NO;
        Fill *blueFill = [[Fill alloc] initWithFrame:NSZeroRect];
        blueFill.color = NSColor.blueColor;
        blue.contentView = blueFill;
        [red makeKeyAndOrderFront:nil];
        [blue orderFront:nil];
        __block int occlusions = 0;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeOcclusionStateNotification object:red queue:nil
                                                      usingBlock:^(NSNotification *n) {
                                                          occlusions++;
                                                      }];
        printf("red occlusion before ordering %lu\n", (unsigned long)red.occlusionState);
        pump(0.5);
        CGPoint rc = content_center(red), bc = content_center(blue);
        printf("red occluded visible %d, notifications %d\n", (red.occlusionState & NSWindowOcclusionStateVisible) != 0, occlusions);

        /* shareable content */
        __block SCShareableContent *content = nil;
        __block BOOL done = NO;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                     completionHandler:^(SCShareableContent *c, NSError *e) {
                                                         content = c;
                                                         printf("content: error %ld, on main thread %d\n", (long)e.code,
                                                             [NSThread isMainThread]);
                                                         done = YES;
                                                     }];
        wait_for(&done);
        SCDisplay *display = content.displays.firstObject;
        printf("displays %lu: %ldx%ld frame %s\n", (unsigned long)content.displays.count, (long)display.width,
            (long)display.height, NSStringFromRect(NSRectFromCGRect(display.frame)).UTF8String);
        SCWindow *sred = find_window(content, @"Red"), *sblue = find_window(content, @"Blue");
        printf("red window: found %d, frame matches %d, ours %d, on screen %d, layer %ld\n", sred != nil,
            CGRectEqualToRect(sred.frame, cg_frame(red)), sred.owningApplication.processID == getpid(), sred.onScreen,
            (long)sred.windowLayer);
        printf("blue window: found %d, id matches %d\n", sblue != nil, sblue.windowID == (CGWindowID)blue.windowNumber);
        BOOL appListed = NO;
        for (SCRunningApplication *a in content.applications)
            appListed |= a.processID == getpid();
        printf("app listed %d\n", appListed);
        /* the desktop is a window, below the rest, as on macOS */
        NSArray *all = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        NSDictionary *bottom = all.lastObject;
        NSArray *noDesktop = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        printf("desktop window: last %d, level is desktop's %d, full screen %d, left out by ExcludeDesktopElements %d\n",
            [bottom[(id)kCGWindowName] isEqualToString:@"Desktop"],
            [bottom[(id)kCGWindowLayer] intValue] == CGWindowLevelForKey(kCGDesktopWindowLevelKey),
            [[bottom[(id)kCGWindowBounds] objectForKey:@"Width"] intValue] == 800, noDesktop.count == all.count - 1);
        SCContentFilter *noDesk = nil;
        for (SCWindow *w in content.windows)
            if (w.windowLayer == CGWindowLevelForKey(kCGDesktopWindowLevelKey))
                noDesk = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingWindows:@[ w ]];
        printf("  in shareable content without desktop windows %d\n", noDesk == nil);
        done = NO;
        [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
            printf("current process: windows %lu, apps %lu\n", (unsigned long)c.windows.count, (unsigned long)c.applications.count);
            done = YES;
        }];
        wait_for(&done);

        /* filters */
        SCContentFilter *one = [[SCContentFilter alloc] initWithDesktopIndependentWindow:sred];
        SCShareableContentInfo *info = [SCShareableContent infoForFilter:one];
        printf("window filter: style %ld scale %.0f rect %s, included windows %lu displays %lu\n", (long)one.style,
            one.pointPixelScale, NSStringFromRect(NSRectFromCGRect(one.contentRect)).UTF8String,
            (unsigned long)one.includedWindows.count, (unsigned long)one.includedDisplays.count);
        printf("  info: style %ld scale %.0f rect %s\n", (long)info.style, info.pointPixelScale,
            NSStringFromRect(NSRectFromCGRect(info.contentRect)).UTF8String);
        SCStreamConfiguration *wc = [SCStreamConfiguration new];
        wc.width = 400;
        wc.height = 300;
        wc.showsCursor = NO;
        CGImageRef im = capture(one, wc);
        printf("  image %zux%zu, centre %s\n", CGImageGetWidth(im), CGImageGetHeight(im),
            pixel(im, (rc.x - cg_frame(red).origin.x) * 2, (rc.y - cg_frame(red).origin.y) * 2).UTF8String);
        CGImageRelease(im);

        SCContentFilter *without = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[ sred ]];
        printf("display without red: style %ld rect %s\n", (long)without.style,
            NSStringFromRect(NSRectFromCGRect(without.contentRect)).UTF8String);
        im = capture(without, native_config());
        printf("  image %zux%zu, red's place %s, blue's %s\n", CGImageGetWidth(im), CGImageGetHeight(im),
            pixel(im, rc.x * 2, rc.y * 2).UTF8String, pixel(im, bc.x * 2, bc.y * 2).UTF8String);
        CGImageRelease(im);

        SCContentFilter *only = [[SCContentFilter alloc] initWithDisplay:display includingWindows:@[ sblue ]];
        im = capture(only, native_config());
        printf("only blue: style %ld, red's place %s, blue's %s\n", (long)only.style, pixel(im, rc.x * 2, rc.y * 2).UTF8String,
            pixel(im, bc.x * 2, bc.y * 2).UTF8String);
        CGImageRelease(im);

        SCRunningApplication *me = sred.owningApplication;
        SCContentFilter *apps = [[SCContentFilter alloc] initWithDisplay:display includingApplications:@[ me ]
                                                        exceptingWindows:@[ sblue ]];
        im = capture(apps, native_config());
        printf("our app but blue: style %ld apps %lu, red's place %s, blue's %s\n", (long)apps.style,
            (unsigned long)apps.includedApplications.count, pixel(im, rc.x * 2, rc.y * 2).UTF8String,
            pixel(im, bc.x * 2, bc.y * 2).UTF8String);
        CGImageRelease(im);

        SCContentFilter *notApps = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:@[ me ]
                                                           exceptingWindows:@[ sblue ]];
        im = capture(notApps, native_config());
        printf("all but our app, blue kept: red's place %s, blue's %s\n", pixel(im, rc.x * 2, rc.y * 2).UTF8String,
            pixel(im, bc.x * 2, bc.y * 2).UTF8String);
        CGImageRelease(im);

        /* scaled into a smaller output, aspect kept */
        SCStreamConfiguration *small = [SCStreamConfiguration new];
        small.width = 400;
        small.height = 400;
        small.showsCursor = NO;
        im = capture(without, small);
        printf("display into 400x400: %zux%zu, blue's place %s, top band %s\n", CGImageGetWidth(im), CGImageGetHeight(im),
            pixel(im, bc.x / 2, 50 + bc.y / 2).UTF8String, pixel(im, 200, 10).UTF8String);
        CGImageRelease(im);

        /* rects and screenshots */
        done = NO;
        [SCScreenshotManager captureImageInRect:cg_frame(red) completionHandler:^(CGImageRef image, NSError *e) {
            printf("image in red's rect: %zux%zu, centre %s\n", CGImageGetWidth(image), CGImageGetHeight(image),
                pixel(image, (rc.x - cg_frame(red).origin.x) * 2, (rc.y - cg_frame(red).origin.y) * 2).UTF8String);
            done = YES;
        }];
        wait_for(&done);
        SCScreenshotConfiguration *sc = [SCScreenshotConfiguration new];
        sc.contentType = UTTypePNG;
        NSString *path = [NSString stringWithFormat:@"/tmp/finch-ascr-%d.png", getpid()];
        sc.fileURL = [NSURL fileURLWithPath:path];
        sc.dynamicRange = SCScreenshotDynamicRangeSDRAndHDR;
        done = NO;
        [SCScreenshotManager captureScreenshotWithRect:CGRectMake(bc.x - 20, bc.y - 10, 40, 20) configuration:sc
                                     completionHandler:^(SCScreenshotOutput *o, NSError *e) {
                                         printf("screenshot of blue: error %ld, sdr %zux%zu %s, hdr %d, file %d\n", (long)e.code,
                                             CGImageGetWidth(o.sdrImage), CGImageGetHeight(o.sdrImage),
                                             pixel(o.sdrImage, 40, 20).UTF8String, o.hdrImage != NULL,
                                             [o.fileURL.path isEqualToString:path]);
                                         done = YES;
                                     }];
        wait_for(&done);
        NSImage *saved = [[NSImage alloc] initWithContentsOfFile:path];
        NSBitmapImageRep *rep = (NSBitmapImageRep *)saved.representations.firstObject;
        printf("  file: %ldx%ld pixels\n", (long)rep.pixelsWide, (long)rep.pixelsHigh);
        unlink(path.fileSystemRepresentation);
        SCScreenshotConfiguration *sized = [SCScreenshotConfiguration new];
        sized.width = 100;
        sized.height = 50;
        done = NO;
        [SCScreenshotManager captureScreenshotWithFilter:one configuration:sized completionHandler:^(SCScreenshotOutput *o, NSError *e) {
            printf("red screenshot at 100x50: %zux%zu, centre %s\n", CGImageGetWidth(o.sdrImage), CGImageGetHeight(o.sdrImage),
                pixel(o.sdrImage, 50, 28).UTF8String);
            done = YES;
        }];
        wait_for(&done);

        /* CoreGraphics's window images */
        CGImageRef cgim = window_list_image(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)red.windowNumber,
                                                  kCGWindowImageBoundsIgnoreFraming);
        printf("CGWindowListCreateImage red: %zux%zu, centre %s\n", CGImageGetWidth(cgim), CGImageGetHeight(cgim),
            pixel(cgim, (rc.x - cg_frame(red).origin.x) * 2, (rc.y - cg_frame(red).origin.y) * 2).UTF8String);
        CGImageRelease(cgim);
        cgim = window_list_image(CGRectMake(rc.x - 5, rc.y - 5, 10, 10), kCGWindowListOptionOnScreenBelowWindow,
                                       (CGWindowID)red.windowNumber, kCGWindowImageDefault);
        printf("  below red, at red's centre: %s\n", pixel(cgim, 10, 10).UTF8String);
        CGImageRelease(cgim);

        /* streams */
        Frames *frames = [Frames new];
        frames.buffers = [NSMutableArray array];
        SCStreamConfiguration *stc = [SCStreamConfiguration new];
        stc.width = 400;
        stc.height = 300;
        stc.pixelFormat = kCVPixelFormatType_32BGRA;
        stc.minimumFrameInterval = CMTimeMake(1, 30);
        stc.showsCursor = NO;
        SCStream *stream = [[SCStream alloc] initWithFilter:without configuration:stc delegate:nil];
        NSError *err = nil;
        printf("stream: add output %d, clock %d\n",
            [stream addStreamOutput:frames type:SCStreamOutputTypeScreen sampleHandlerQueue:nil error:&err],
            stream.synchronizationClock != NULL);
        done = NO;
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            printf("  started: error %ld\n", (long)e.code);
            done = YES;
        }];
        wait_for(&done);
        done = NO;
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            printf("  started again: error %ld\n", (long)e.code);
            done = YES;
        }];
        wait_for(&done);
        pump(0.4);
        NSUInteger before;
        @synchronized(frames) {
            before = frames.buffers.count;
        }
        pump(0.3);
        NSUInteger still;
        @synchronized(frames) {
            still = frames.buffers.count;
        }
        printf("  frames while nothing changes: first %d, then none %d\n", before >= 1, still == before);
        blueFill.color = NSColor.greenColor;
        blueFill.needsDisplay = YES;
        pump(0.4);
        done = NO;
        [stream stopCaptureWithCompletionHandler:^(NSError *e) {
            printf("  stopped: error %ld\n", (long)e.code);
            done = YES;
        }];
        wait_for(&done);
        done = NO;
        [stream stopCaptureWithCompletionHandler:^(NSError *e) {
            printf("  stopped again: error %ld\n", (long)e.code);
            done = YES;
        }];
        wait_for(&done);
        pump(0.1);
        NSArray *got;
        @synchronized(frames) {
            got = [frames.buffers copy];
        }
        printf("  a frame after the change %d\n", got.count > still);
        CMSampleBufferRef first = (__bridge CMSampleBufferRef)got.firstObject, last = (__bridge CMSampleBufferRef)got.lastObject;
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(first);
        printf("  first frame: %zux%zu format %s valid %d\n", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
            CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA ? "BGRA" : "other", CMSampleBufferIsValid(first));
        NSDictionary *att = [(__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(first, false) firstObject];
        CGRect cr;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)att[SCStreamFrameInfoContentRect], &cr);
        printf("  info: status %ld scale %.0f content scale %.2f content rect %s\n", (long)[att[SCStreamFrameInfoStatus] integerValue],
            [att[SCStreamFrameInfoScaleFactor] doubleValue], [att[SCStreamFrameInfoContentScale] doubleValue],
            NSStringFromRect(NSRectFromCGRect(cr)).UTF8String);
        CVPixelBufferRef lpb = CMSampleBufferGetImageBuffer(last);
        CVPixelBufferLockBaseAddress(lpb, kCVPixelBufferLock_ReadOnly);
        const uint8_t *base = CVPixelBufferGetBaseAddress(lpb);
        size_t bpr = CVPixelBufferGetBytesPerRow(lpb);
        /* (the 800x600 display in a 400x300 frame: half size) */
        const uint8_t *px = base + (size_t)(bc.y / 2) * bpr + (size_t)(bc.x / 2) * 4;
        printf("  last frame at blue's place: B %d G %d R %d\n", px[0] > 200, px[1] > 200, px[2] > 200);
        CVPixelBufferUnlockBaseAddress(lpb, kCVPixelBufferLock_ReadOnly);

        Frames *yuv = [Frames new];
        yuv.buffers = [NSMutableArray array];
        SCStreamConfiguration *yc = [SCStreamConfiguration new];
        yc.width = 200;
        yc.height = 150;
        yc.showsCursor = NO;
        SCStream *ys = [[SCStream alloc] initWithFilter:one configuration:yc delegate:nil];
        [ys addStreamOutput:yuv type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:nil];
        done = NO;
        [ys startCaptureWithCompletionHandler:^(NSError *e) {
            done = YES;
        }];
        wait_for(&done);
        pump(0.3);
        done = NO;
        [ys stopCaptureWithCompletionHandler:^(NSError *e) {
            done = YES;
        }];
        wait_for(&done);
        pump(0.1);
        CMSampleBufferRef ysb = (__bridge CMSampleBufferRef)yuv.buffers.firstObject;
        CVPixelBufferRef ypb = CMSampleBufferGetImageBuffer(ysb);
        CVPixelBufferLockBaseAddress(ypb, kCVPixelBufferLock_ReadOnly);
        const uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(ypb, 0), *cp = CVPixelBufferGetBaseAddressOfPlane(ypb, 1);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(ypb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(ypb, 1);
        /* (red, BT.709 video range: Y 63, Cb 102, Cr 240) */
        printf("4:2:0 stream of red: frames %d, format %s, planes %zu, centre Y %d Cb %d Cr %d\n", yuv.buffers.count > 0,
            CVPixelBufferGetPixelFormatType(ypb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "420v" : "other",
            CVPixelBufferGetPlaneCount(ypb), yp[90 * ybpr + 100], cp[45 * cbpr + 100], cp[45 * cbpr + 101]);
        CVPixelBufferUnlockBaseAddress(ypb, kCVPixelBufferLock_ReadOnly);

        SCRecordingOutput *rec = [[SCRecordingOutput alloc] initWithConfiguration:[SCRecordingOutputConfiguration new] delegate:(id)frames];
        printf("recording output added %d\n", [ys addRecordingOutput:rec error:&err]);

        kill(pid, SIGTERM);
        unlink(sock);
    }
    return 0;
}

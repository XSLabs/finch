/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-opengl-test: an NSOpenGLView on Finch's window server. Starts a headless
 * server, shows a window with an NSOpenGLView subclass that clears to blue and draws a
 * red quad on its left half and, with GLU, a lit green sphere on its right; then checks
 * the order of -prepareOpenGL, -reshape and -drawRect:, the context and pixel format,
 * the screen's colours, a resize (reshaped, redrawn at the new size) and a redraw from a
 * timer through flushBuffer, and an opaque subview staying under the GL surface, as on
 * macOS. Finch-only (Apple's OpenGL surfaces are composited apart):
 * compare with appkit-opengl-test.expected.
 *
 *   finch-appkit-opengl-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <OpenGL/gl.h>
#import <OpenGL/glu.h>
#import <ImageIO/ImageIO.h>
#include <spawn.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSSetCursorVisible(bool v);
CGImageRef FWSCopyScreenImage(void);

static NSMutableArray *calls;
static BOOL greenRight = YES;

@interface GLTestView : NSOpenGLView
@end

@interface WhiteView : NSView
@end
@implementation WhiteView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)r
{
    [[NSColor whiteColor] set];
    NSRectFill(self.bounds);
}
@end

@implementation GLTestView
- (void)prepareOpenGL
{
    [super prepareOpenGL];
    [calls addObject:@"prepare"];
    glEnable(GL_DEPTH_TEST);
}
- (void)reshape
{
    [super reshape];
    [calls addObject:[NSString stringWithFormat:@"reshape %.0fx%.0f", self.bounds.size.width, self.bounds.size.height]];
    glViewport(0, 0, (GLsizei)self.bounds.size.width, (GLsizei)self.bounds.size.height);
}
- (void)drawRect:(NSRect)r
{
    [calls addObject:@"draw"];
    glClearColor(0, 0, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluOrtho2D(0, 2, 0, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glColor3f(1, 0, 0);
    glRectf(0.1f, 0.1f, 0.9f, 0.9f);
    if (greenRight) {
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        gluPerspective(40, self.bounds.size.width / self.bounds.size.height, 1, 10);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        gluLookAt(0, 0, 4, 0, 0, 0, 0, 1, 0);
        glTranslatef(0.8f, 0, 0);
        glEnable(GL_LIGHTING);
        glEnable(GL_LIGHT0);
        GLfloat pos[] = {0, 0, 5, 1}, green[] = {0, 1, 0, 1}, white[] = {1, 1, 1, 1};
        glLightfv(GL_LIGHT0, GL_POSITION, pos);
        glLightfv(GL_LIGHT0, GL_DIFFUSE, white);
        glMaterialfv(GL_FRONT, GL_DIFFUSE, green);
        GLUquadric *q = gluNewQuadric();
        gluSphere(q, 0.5, 24, 12);
        gluDeleteQuadric(q);
        glDisable(GL_LIGHTING);
    }
    [[self openGLContext] flushBuffer];
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

static NSString *
screen_colour(CGPoint p)
{
    CGImageRef screen = FWSCopyScreenImage();
    if (!screen)
        return @"no screen";
    uint8_t px[4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(-p.x * 2, p.y * 2 - (CGImageGetHeight(screen) - 1), CGImageGetWidth(screen), CGImageGetHeight(screen)),
                       screen);
    CGContextRelease(c);
    CGImageRelease(screen);
    if (px[0] > 150 && px[1] < 100 && px[2] < 100)
        return @"red";
    if (px[2] > 150 && px[0] < 100 && px[1] < 100)
        return @"blue";
    if (px[1] > 150 && px[0] < 100 && px[2] < 100)
        return @"green";
    return @"other";
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-aogl.%d", getpid());
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
        calls = [NSMutableArray array];

        NSOpenGLPixelFormatAttribute attrs[] = {NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, 24, NSOpenGLPFADepthSize, 24, 0};
        NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
        GLint depth = 0;
        [pf getValues:&depth forAttribute:NSOpenGLPFADepthSize forVirtualScreen:0];
        printf("pixel format %d, depth %d, screens %d\n", pf != nil, depth, pf.numberOfVirtualScreens);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 200, 320, 160) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.releasedWhenClosed = NO;
        GLTestView *v = [[GLTestView alloc] initWithFrame:NSMakeRect(0, 0, 320, 160) pixelFormat:pf];
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        w.contentView = v;
        [w makeKeyAndOrderFront:nil];
        pump(0.5);
        printf("calls: %s\n", [calls componentsJoinedByString:@", "].UTF8String);
        printf("context %d, view is it %d, current is it %d, format is it %d\n", v.openGLContext != nil, v.openGLContext.view == v,
            [NSOpenGLContext currentContext] == v.openGLContext, v.openGLContext.pixelFormat == pf);
        NSRect c = [w contentRectForFrameRect:w.frame];
        CGPoint left = CGPointMake(NSMinX(c) + c.size.width / 4, 600 - NSMidY(c));
        /* (the sphere's centre: x 0.8 of a 5.82-wide view of z = 0) */
        CGPoint right = CGPointMake(NSMinX(c) + c.size.width * (0.5 + 0.8 / 5.82), 600 - NSMidY(c));
        CGPoint corner = CGPointMake(NSMinX(c) + 4, 600 - NSMinY(c) - 4);
        if (getenv("OPENGL_TEST_SCREENSHOT")) {
            CGImageRef shot = FWSCopyScreenImage();
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:@(getenv("OPENGL_TEST_SCREENSHOT"))], CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, shot, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
            CGImageRelease(shot);
        }
        printf("screen: left %s, right %s, corner %s\n", screen_colour(left).UTF8String, screen_colour(right).UTF8String,
            screen_colour(corner).UTF8String);

        [calls removeAllObjects];
        [w setFrame:NSMakeRect(w.frame.origin.x, w.frame.origin.y, w.frame.size.width + 80, w.frame.size.height) display:YES];
        pump(0.3);
        printf("resized: %s\n", [calls componentsJoinedByString:@", "].UTF8String);

        /* a redraw from a timer, outside the display cycle */
        [calls removeAllObjects];
        greenRight = NO;
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *t) {
            [v.openGLContext makeCurrentContext];
            [v drawRect:v.bounds];
        }];
        pump(0.4);
        c = [w contentRectForFrameRect:w.frame];
        right = CGPointMake(NSMinX(c) + c.size.width * (0.5 + 0.8 / (2 * tan(20 * M_PI / 180) * 4 * c.size.width / c.size.height)), 600 - NSMidY(c));
        printf("timer redraw: right now %s, calls start with %s\n", screen_colour(right).UTF8String, [calls.firstObject UTF8String]);
        /* an opaque subview over the left half: the GL surface still shows above it */
        WhiteView *cover = [[WhiteView alloc] initWithFrame:NSMakeRect(0, 0, c.size.width / 2, c.size.height)];
        [v addSubview:cover];
        pump(0.4);
        left = CGPointMake(NSMinX(c) + c.size.width / 4, 600 - NSMidY(c));
        printf("covered by a subview: left %s\n", screen_colour(left).UTF8String);
        [NSOpenGLContext clearCurrentContext];
        printf("cleared current: %p\n", [NSOpenGLContext currentContext]);
        kill(pid, SIGTERM);
        unlink(sock);
    }
    return 0;
}

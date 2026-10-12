/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-avplayer-test: an AVPlayerLayer in a window on Finch's window server.
 * Starts a headless server, shows a window whose view's layer holds a player layer
 * playing a movie the test writes itself (JPEG frames, red and blue in turn), then
 * checks the screen: the frame at each seek, the layer's video rect and readiness, and
 * frames changing while it plays. Finch-only (Apple's player layers draw outside the
 * app): compare with appkit-avplayer-test.expected.
 *
 *   finch-appkit-avplayer-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <spawn.h>
#include "../WindowServer/FinchWSProtocol.h"
#include "avmovie.h"
#include "avframes.h"

extern char **environ;
bool FWSConnect(void);
void FWSSetCursorVisible(bool v);
CGImageRef FWSCopyScreenImage(void);

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

/* The screen's colour at a point (points, top-left origin, 2x display). */
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
    if (px[0] > 150 && px[2] < 100)
        return @"red";
    if (px[2] > 150 && px[0] < 100)
        return @"blue";
    return [NSString stringWithFormat:@"other"];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-aavp.%d", getpid());
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

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aavp-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"test.mov"]];
        NSMutableArray *frames = [NSMutableArray array];
        for (int i = 0; i < 6; i++)
            [frames addObject:i % 2 ? [NSData dataWithBytes:frame1 length:sizeof frame1] : [NSData dataWithBytes:frame0 length:sizeof frame0]];
        [build_movie_with_frames(frames) writeToURL:url atomically:YES];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 200, 320, 240) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.releasedWhenClosed = NO;
        NSView *v = w.contentView;
        v.wantsLayer = YES;
        AVPlayer *player = [AVPlayer playerWithURL:url];
        AVPlayerLayer *pl = [AVPlayerLayer playerLayerWithPlayer:player];
        pl.frame = v.bounds;
        [v.layer addSublayer:pl];
        [w makeKeyAndOrderFront:nil];
        for (int i = 0; i < 300 && player.currentItem.status != AVPlayerItemStatusReadyToPlay; i++)
            pump(0.01);
        /* the centre of the content, in screen points (top-left origin) */
        NSRect c = [w contentRectForFrameRect:w.frame];
        CGPoint centre = CGPointMake(NSMidX(c), 600 - NSMidY(c));
        __block BOOL done = NO;
        [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL f) {
            done = YES;
        }];
        for (int i = 0; i < 100 && !done; i++)
            pump(0.01);
        pump(0.3);
        printf("item ready %d, layer ready %d, video rect %s\n", player.currentItem.status == AVPlayerItemStatusReadyToPlay,
            pl.readyForDisplay, NSStringFromRect(NSRectFromCGRect(pl.videoRect)).UTF8String);
        printf("at 0: %s; beside the picture: %s\n", screen_colour(centre).UTF8String,
            screen_colour(CGPointMake(c.origin.x + 10, centre.y)).UTF8String);
        done = NO;
        [player seekToTime:CMTimeMake(100, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL f) {
            done = YES;
        }];
        for (int i = 0; i < 100 && !done; i++)
            pump(0.01);
        pump(0.3);
        printf("at 1/6 s: %s\n", screen_colour(centre).UTF8String);
        /* playing: the picture changes */
        [player seekToTime:kCMTimeZero];
        pump(0.2);
        [player play];
        NSMutableSet *seen = [NSMutableSet set];
        for (int i = 0; i < 40; i++) {
            pump(0.03);
            [seen addObject:screen_colour(centre)];
        }
        printf("while playing: red %d blue %d\n", [seen containsObject:@"red"], [seen containsObject:@"blue"]);
        pump(1.0);
        printf("after the end: rate %.1f, %s\n", player.rate, screen_colour(centre).UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        kill(pid, SIGTERM);
        unlink(sock);
    }
    return 0;
}

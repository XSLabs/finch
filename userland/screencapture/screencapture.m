/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * screencapture: Finch's own, with Apple's options. It captures the screen, a display,
 * a rectangle or a window (CoreGraphics' window-server capture) to files, in any format
 * ImageIO writes, or to the clipboard. With -i it asks the user what to capture: an
 * overlay over the frozen screen where a drag selects a rectangle, a click (after space,
 * or with -w/-W) picks a window, and Return takes the whole screen; -U adds a bar to
 * choose the mode. Files go to the screencapture location (the com.apple.screencapture
 * "location" default, else the Desktop) named as macOS names them, unless given.
 *
 *   screencapture [-icmwsWxSUoCparu] [-t format] [-T seconds] [-R x,y,w,h] [-l windowid]
 *                 [-D display] [files]
 *
 * Exit status 0 when something was captured, 1 when the user cancelled or capture failed.
 * Not on Finch yet: video recording (-v, -V, -g, -G, -k) and the Touch Bar (-b).
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <getopt.h>
#include <unistd.h>

/* CoreGraphics' capture calls (Finch's has them; the SDK marks them obsoleted in favour of
   ScreenCaptureKit), under names of our own bound to the same symbols. */
extern CGImageRef window_list_image(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption)
    __asm__("_CGWindowListCreateImage");
extern CGImageRef display_image(CGDirectDisplayID) __asm__("_CGDisplayCreateImage");

typedef struct {
    BOOL interactive, clipboard, mainOnly, windowOnly, selectionOnly, startInWindow, toolbar, noShadow, quiet;
    NSString *format;
    double delay;
    NSRect rect;
    BOOL hasRect;
    CGWindowID window;
    int display; /* 1-based, as Apple's -D */
} Options;

static void
usage(void)
{
    fprintf(stderr, "usage: screencapture [-icmwsWxSUoCparu] [-t format] [-T seconds] [-R x,y,w,h] [-l windowid] [-D display] [files]\n");
}

/* The UTI for a -t format name (png, jpg, tiff, pdf, heic, gif, bmp, ...). */
static NSString *
type_for_format(NSString *f)
{
    NSDictionary *names = @{@"jpg" : @"public.jpeg", @"jpeg" : @"public.jpeg", @"png" : @"public.png", @"tif" : @"public.tiff",
                            @"tiff" : @"public.tiff", @"gif" : @"com.compuserve.gif", @"bmp" : @"com.microsoft.bmp",
                            @"heic" : @"public.heic", @"pdf" : @"com.adobe.pdf", @"jp2" : @"public.jpeg-2000",
                            @"tga" : @"com.truevision.tga-image", @"psd" : @"com.adobe.photoshop-image"};
    return names[[f lowercaseString]] ?: [UTType typeWithFilenameExtension:f].identifier;
}

/* Where unnamed captures go: the com.apple.screencapture "location" default, else the Desktop. */
static NSString *
capture_folder(void)
{
    NSString *loc = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("location"), CFSTR("com.apple.screencapture"));
    BOOL dir = NO;
    if ([loc isKindOfClass:[NSString class]] &&
        [[NSFileManager defaultManager] fileExistsAtPath:[loc stringByExpandingTildeInPath] isDirectory:&dir] && dir)
        return [loc stringByExpandingTildeInPath];
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
}

/* "Screenshot 2026-10-12 at 15.46.12.png", as macOS names them. */
static NSString *
default_path(NSString *ext)
{
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *base = [NSString stringWithFormat:@"Screenshot %@", [f stringFromDate:[NSDate date]]];
    NSString *folder = capture_folder();
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [folder stringByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
    for (int n = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; n++)
        path = [folder stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ (%d)", base, n] stringByAppendingPathExtension:ext]];
    return path;
}

static BOOL
write_image(CGImageRef image, NSString *path, NSString *type)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)type, 1, NULL);
    if (!d)
        return NO;
    CGImageDestinationAddImage(d, image, NULL);
    BOOL ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    return ok;
}

static BOOL
copy_to_clipboard(CGImageRef image)
{
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    if (!d)
        return NO;
    CGImageDestinationAddImage(d, image, NULL);
    BOOL ok = CGImageDestinationFinalize(d);
    CFRelease(d);
    if (!ok)
        return NO;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    return [pb setData:png forType:NSPasteboardTypePNG];
}

/* The displays, in Apple's -D numbering (1 is the main display). */
static CGDirectDisplayID
display_number(int n)
{
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetActiveDisplayList(16, ids, &count);
    if (n < 1 || (uint32_t)n > count)
        return kCGNullDirectDisplay;
    return ids[n - 1];
}

static CGImageRef
capture_window(CGWindowID wid, BOOL noShadow)
{
    CGWindowImageOption o = kCGWindowImageBoundsIgnoreFraming;
    if (noShadow)
        o |= kCGWindowImageShouldBeOpaque;
    return window_list_image(CGRectNull, kCGWindowListOptionIncludingWindow, wid, o);
}

#pragma mark - Interactive

typedef enum { ModeSelection, ModeWindow, ModeScreen } Mode;

/* The overlay's view: the frozen screen, dimmed but for the selection or the window under
   the pointer, drawn in Fieldwork's ink. */
@interface FinchCaptureView : NSView
@property (strong) NSImage *frozen;
@property Mode mode;
@property NSRect selection;   /* view coordinates; empty when none */
@property NSRect hoverWindow; /* view coordinates */
@property CGWindowID hoverID;
@property (copy) void (^finish)(NSRect rect, CGWindowID window, BOOL cancelled);
@property BOOL allowWindow, allowSelection;
@end

@implementation FinchCaptureView {
    NSPoint _start;
    BOOL _dragging;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; } /* the first press starts a selection */
- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty
{
    [self.frozen drawInRect:self.bounds];
    NSRect focus = self.mode == ModeWindow ? self.hoverWindow : self.mode == ModeScreen ? self.bounds : self.selection;
    [[NSColor colorWithWhite:0 alpha:0.32] setFill];
    NSBezierPath *dim = [NSBezierPath bezierPathWithRect:self.bounds];
    if (!NSIsEmptyRect(focus) && self.mode != ModeScreen) {
        [dim appendBezierPathWithRect:focus];
        dim.windingRule = NSWindingRuleEvenOdd;
    }
    if (self.mode != ModeScreen)
        [dim fill];
    if (NSIsEmptyRect(focus))
        return;
    NSColor *ink = self.mode == ModeWindow ? [NSColor controlAccentColor] : [NSColor whiteColor];
    [ink setStroke];
    NSBezierPath *edge = [NSBezierPath bezierPathWithRect:NSInsetRect(focus, 0.5, 0.5)];
    edge.lineWidth = self.mode == ModeWindow ? 2 : 1;
    [edge stroke];
    if (self.mode == ModeSelection) {
        /* its size, in points, beside the corner */
        NSString *size = [NSString stringWithFormat:@"%.0f × %.0f", focus.size.width, focus.size.height];
        NSDictionary *a = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName : [NSColor whiteColor]};
        NSSize s = [size sizeWithAttributes:a];
        NSRect tag = NSMakeRect(NSMaxX(focus) + 6, NSMinY(focus) - s.height - 8, s.width + 10, s.height + 4);
        if (NSMaxX(tag) > NSMaxX(self.bounds))
            tag.origin.x = NSMaxX(focus) - tag.size.width;
        if (tag.origin.y < 0)
            tag.origin.y = NSMinY(focus) + 4;
        [[NSColor colorWithWhite:0.1 alpha:0.85] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:tag xRadius:3 yRadius:3] fill];
        [size drawAtPoint:NSMakePoint(tag.origin.x + 5, tag.origin.y + 2) withAttributes:a];
    }
}

/* The topmost normal window under a point (screen coordinates, top-left origin), other than ours. */
- (void)updateHover:(NSPoint)p
{
    NSArray *info = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    CGFloat H = self.bounds.size.height;
    CGPoint q = CGPointMake(p.x, H - p.y);
    self.hoverWindow = NSZeroRect;
    self.hoverID = 0;
    for (NSDictionary *w in info) {
        if ([w[(id)kCGWindowNumber] unsignedIntValue] == (unsigned)self.window.windowNumber ||
            [w[(id)kCGWindowLayer] intValue] != 0)
            continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b) || !CGRectContainsPoint(b, q))
            continue;
        self.hoverWindow = NSMakeRect(b.origin.x, H - CGRectGetMaxY(b), b.size.width, b.size.height);
        self.hoverID = [w[(id)kCGWindowNumber] unsignedIntValue];
        break;
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)e
{
    if (self.mode == ModeWindow)
        [self updateHover:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.mode == ModeWindow) {
        [self updateHover:p];
        if (self.hoverID)
            self.finish(self.hoverWindow, self.hoverID, NO);
        return;
    }
    if (self.mode == ModeScreen) {
        self.finish(self.bounds, 0, NO);
        return;
    }
    _start = p;
    _dragging = YES;
    self.selection = NSZeroRect;
}

- (void)mouseDragged:(NSEvent *)e
{
    if (!_dragging)
        return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    self.selection = NSIntegralRect(NSMakeRect(MIN(p.x, _start.x), MIN(p.y, _start.y), fabs(p.x - _start.x), fabs(p.y - _start.y)));
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
    if (!_dragging)
        return;
    _dragging = NO;
    if (self.selection.size.width >= 2 && self.selection.size.height >= 2)
        self.finish(self.selection, 0, NO);
}

- (void)setModeAndRedraw:(Mode)m
{
    if (m == ModeWindow && !self.allowWindow)
        return;
    if (m == ModeSelection && !self.allowSelection)
        return;
    self.mode = m;
    self.selection = NSZeroRect;
    if (m == ModeWindow)
        [self updateHover:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]];
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)e
{
    unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c == 27) /* Escape */
        self.finish(NSZeroRect, 0, YES);
    else if (c == ' ')
        [self setModeAndRedraw:self.mode == ModeWindow ? ModeSelection : ModeWindow];
    else if (c == '\r' || c == 3)
        self.finish(self.bounds, 0, NO);
}

@end

/* The -U bar: the capture modes and Cancel, in Fieldwork's controls. */
@interface FinchCaptureBar : NSObject
@property (weak) FinchCaptureView *view;
@end

@implementation FinchCaptureBar
- (void)mode:(NSSegmentedControl *)s
{
    [self.view setModeAndRedraw:s.selectedSegment == 0 ? ModeScreen : s.selectedSegment == 1 ? ModeWindow : ModeSelection];
    [self.view.window makeFirstResponder:self.view];
}
- (void)cancel:(id)sender
{
    self.view.finish(NSZeroRect, 0, YES);
}
@end

typedef struct {
    BOOL cancelled;
    NSRect rect; /* screen points, top-left origin */
    CGWindowID window;
} Choice;

static Choice
ask_user(const Options *o)
{
    __block Choice choice = {YES, NSZeroRect, 0};
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = screen.frame;
    CGImageRef shot = display_image(CGMainDisplayID());
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.level = NSScreenSaverWindowLevel;
    w.opaque = YES;
    w.acceptsMouseMovedEvents = YES;
    FinchCaptureView *v = [[FinchCaptureView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    if (shot) {
        v.frozen = [[NSImage alloc] initWithCGImage:shot size:frame.size];
        CGImageRelease(shot);
    }
    v.allowWindow = !o->selectionOnly;
    v.allowSelection = !o->windowOnly;
    v.mode = (o->windowOnly || o->startInWindow) ? ModeWindow : ModeSelection;
    v.finish = ^(NSRect r, CGWindowID wid, BOOL cancelled) {
        choice.cancelled = cancelled;
        choice.rect = NSMakeRect(r.origin.x, frame.size.height - NSMaxY(r), r.size.width, r.size.height);
        choice.window = wid;
        [NSApp stop:nil];
        /* (a stop takes effect once an event arrives) */
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                           timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0]
                 atStart:NO];
    };
    w.contentView = v;
    FinchCaptureBar *bar = nil;
    if (o->toolbar) {
        bar = [FinchCaptureBar new];
        bar.view = v;
        NSSegmentedControl *modes = [NSSegmentedControl segmentedControlWithLabels:@[@"Entire Screen", @"Window", @"Selection"]
                                                                      trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                            target:bar action:@selector(mode:)];
        modes.selectedSegment = v.mode == ModeWindow ? 1 : 2;
        [modes setEnabled:v.allowWindow forSegment:1];
        [modes setEnabled:v.allowSelection forSegment:2];
        NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:bar action:@selector(cancel:)];
        NSStackView *row = [NSStackView stackViewWithViews:@[modes, cancel]];
        row.spacing = 12;
        row.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
        NSSize s = row.fittingSize;
        NSVisualEffectView *panel = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect((frame.size.width - s.width) / 2, 40, s.width, s.height)];
        panel.wantsLayer = YES;
        panel.layer.cornerRadius = 6;
        row.frame = panel.bounds;
        [panel addSubview:row];
        [v addSubview:panel];
    }
    [w makeKeyAndOrderFront:nil];
    [w makeFirstResponder:v];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    [w orderOut:nil];
    (void)bar;
    return choice;
}

#pragma mark - Main

static BOOL
parse_rect(const char *s, NSRect *r)
{
    double x, y, w, h;
    if (sscanf(s, "%lf,%lf,%lf,%lf", &x, &y, &w, &h) != 4 || w <= 0 || h <= 0)
        return NO;
    *r = NSMakeRect(x, y, w, h);
    return YES;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        Options o = {0};
        o.format = nil;
        int ch;
        while ((ch = getopt(argc, argv, "bcCdimMoPpSsUuWwxaArvgkt:T:R:l:D:B:J:V:G:")) != -1) {
            switch (ch) {
            case 'c': o.clipboard = YES; break;
            case 'i': o.interactive = YES; break;
            case 'm': o.mainOnly = YES; break;
            case 'w': o.windowOnly = YES; break;
            case 's': o.selectionOnly = YES; break;
            case 'W': o.startInWindow = YES; break;
            case 'U': o.toolbar = YES; break;
            case 'o': o.noShadow = YES; break;
            case 'x': o.quiet = YES; break;
            case 't': o.format = @(optarg); break;
            case 'T': o.delay = atof(optarg); break;
            case 'R':
                if (!parse_rect(optarg, &o.rect)) {
                    usage();
                    return 1;
                }
                o.hasRect = YES;
                break;
            case 'l': o.window = (CGWindowID)strtoul(optarg, NULL, 10); break;
            case 'D': o.display = atoi(optarg); break;
            case 'v':
            case 'V':
            case 'g':
            case 'G':
            case 'k':
                fprintf(stderr, "screencapture: screen recording isn't available on Finch yet\n");
                return 1;
            case 'b':
                fprintf(stderr, "screencapture: there's no Touch Bar to capture\n");
                return 1;
            case 'C': case 'd': case 'M': case 'P': case 'p': case 'S': case 'u': case 'a': case 'A': case 'r':
            case 'B': case 'J':
                break; /* accepted: defaults, cursor, mail and preview hand-offs Finch doesn't have */
            default:
                usage();
                return 1;
            }
        }
        argc -= optind;
        argv += optind;
        if (!o.format) {
            NSString *t = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("type"), CFSTR("com.apple.screencapture"));
            o.format = [t isKindOfClass:[NSString class]] ? t : @"png";
        }
        NSString *type = type_for_format(o.format);
        if (!type) {
            fprintf(stderr, "screencapture: unknown format %s\n", o.format.UTF8String);
            return 1;
        }
        if (o.delay > 0)
            usleep((useconds_t)(o.delay * 1e6));

        CGImageRef image = NULL;
        if (o.interactive) {
            Choice c = ask_user(&o);
            if (c.cancelled)
                return 1;
            image = c.window ? capture_window(c.window, o.noShadow)
                             : window_list_image(NSRectToCGRect(c.rect), kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
                                                       kCGWindowImageDefault);
        } else if (o.window) {
            image = capture_window(o.window, o.noShadow);
        } else if (o.hasRect) {
            image = window_list_image(NSRectToCGRect(o.rect), kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
                                            kCGWindowImageDefault);
        } else {
            CGDirectDisplayID d = o.display ? display_number(o.display) : CGMainDisplayID();
            if (d == kCGNullDirectDisplay) {
                fprintf(stderr, "screencapture: no display %d\n", o.display);
                return 1;
            }
            image = display_image(d);
        }
        if (!image) {
            fprintf(stderr, "screencapture: could not create image\n");
            return 1;
        }
        BOOL ok = YES;
        if (o.clipboard) {
            ok = copy_to_clipboard(image);
        } else if (argc == 0) {
            NSString *ext = [UTType typeWithIdentifier:type].preferredFilenameExtension ?: o.format;
            NSString *path = default_path(ext);
            ok = write_image(image, path, type);
        } else {
            for (int i = 0; i < argc && ok; i++)
                ok = write_image(image, [@(argv[i]) stringByExpandingTildeInPath], type);
        }
        CGImageRelease(image);
        if (!ok)
            fprintf(stderr, "screencapture: could not write the capture\n");
        return ok ? 0 : 1;
    }
}

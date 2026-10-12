/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's system images (NSImageNameAddTemplate, NSImageNameCaution, the private
 * NSDisclosable, ...): Finch's own artwork, drawn in code in Fieldwork's style
 * (docs/design/FIELDWORK.md), at the sizes and with the template flags Apple's have.
 * Templates are ink line glyphs that controls tint; the 32-point icons are small
 * illustrations in a restrained palette. +imageNamed: asks here after the app's own
 * images.
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

typedef void (^Drawer)(NSRect r);

/* MARK: Drawing helpers (points, origin at the bottom left) */

/* (symbol images set it for their weight while they draw) */
static CGFloat kStroke = 1.5;

static NSBezierPath *
stroke_path(void)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = kStroke;
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    return p;
}

static void
line(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2)
{
    NSBezierPath *p = stroke_path();
    [p moveToPoint:NSMakePoint(x1, y1)];
    [p lineToPoint:NSMakePoint(x2, y2)];
    [p stroke];
}

/* A polyline (closed: a polygon) through n points given as x, y pairs; filled or stroked. */
static void
poly(BOOL closed, BOOL fill, int n, const CGFloat *xy)
{
    NSBezierPath *p = stroke_path();
    [p moveToPoint:NSMakePoint(xy[0], xy[1])];
    for (int i = 1; i < n; i++)
        [p lineToPoint:NSMakePoint(xy[2 * i], xy[2 * i + 1])];
    if (closed)
        [p closePath];
    if (fill)
        [p fill];
    else
        [p stroke];
}
#define POLY(closed, fill, ...)                                          \
    do {                                                                 \
        const CGFloat pts_[] = {__VA_ARGS__};                            \
        poly(closed, fill, (int)(sizeof pts_ / sizeof pts_[0] / 2), pts_); \
    } while (0)

static void
circle(CGFloat cx, CGFloat cy, CGFloat radius, BOOL fill)
{
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - radius, cy - radius, 2 * radius, 2 * radius)];
    p.lineWidth = kStroke;
    if (fill)
        [p fill];
    else
        [p stroke];
}

static void
rrect(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat radius, BOOL fill)
{
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, w, h) xRadius:radius yRadius:radius];
    p.lineWidth = kStroke;
    p.lineJoinStyle = NSLineJoinStyleRound;
    if (fill)
        [p fill];
    else
        [p stroke];
}

static void
arc(CGFloat cx, CGFloat cy, CGFloat radius, CGFloat from, CGFloat to, BOOL clockwise)
{
    NSBezierPath *p = stroke_path();
    [p appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:radius startAngle:from endAngle:to clockwise:clockwise];
    [p stroke];
}

/* Text centred in a rect, in the system font. */
static void
text(NSString *s, NSRect r, CGFloat size, NSFontWeight weight, NSFontTraitMask traits, NSColor *color)
{
    NSFont *f = [NSFont systemFontOfSize:size weight:weight];
    if (traits)
        f = [[NSFontManager sharedFontManager] convertFont:f toHaveTrait:traits] ?: f;
    NSDictionary *a = @{NSFontAttributeName : f, NSForegroundColorAttributeName : color ?: [NSColor blackColor]};
    NSSize ts = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2, NSMidY(r) - ts.height / 2) withAttributes:a];
}

static NSColor *
rgb(unsigned hex)
{
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0 green:((hex >> 8) & 0xff) / 255.0 blue:(hex & 0xff) / 255.0 alpha:1];
}

/* The icons' palette: ink, paper, manila, a muted green, amber, brick, slate blue, graphite. */
#define INK rgb(0x2b2a27)
#define PAPER rgb(0xf4f0e6)
#define MANILA rgb(0xd8b57a)
#define MANILA_DARK rgb(0xb8924f)
#define GREEN rgb(0x3f7a5c)
#define AMBER rgb(0xe0a63a)
#define BRICK rgb(0xc4553f)
#define SLATE rgb(0x4d7192)
#define GRAPHITE rgb(0x8a8e92)

/* MARK: Template glyphs */

static void
chevron(NSRect r, int dir) /* 0 left, 1 right, 2 up, 3 down */
{
    CGFloat w = r.size.width, h = r.size.height, cx = w / 2, cy = h / 2, a = MIN(w, h) * 0.28;
    switch (dir) {
    case 0: POLY(NO, NO, cx + a / 1.6, cy + a * 1.3, cx - a / 1.6, cy, cx + a / 1.6, cy - a * 1.3); break;
    case 1: POLY(NO, NO, cx - a / 1.6, cy + a * 1.3, cx + a / 1.6, cy, cx - a / 1.6, cy - a * 1.3); break;
    case 2: POLY(NO, NO, cx - a * 1.3, cy - a / 1.6, cx, cy + a / 1.6, cx + a * 1.3, cy - a / 1.6); break;
    default: POLY(NO, NO, cx - a * 1.3, cy + a / 1.6, cx, cy - a / 1.6, cx + a * 1.3, cy + a / 1.6); break;
    }
}

static void
triangle(NSRect r, int dir, CGFloat inset)
{
    CGFloat x0 = inset, y0 = inset, x1 = r.size.width - inset, y1 = r.size.height - inset;
    CGFloat mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
    switch (dir) {
    case 0: POLY(YES, YES, x1, y1, x0, my, x1, y0); break;
    case 1: POLY(YES, YES, x0, y1, x1, my, x0, y0); break;
    case 2: POLY(YES, YES, x0, y0, mx, y1, x1, y0); break;
    default: POLY(YES, YES, x0, y1, mx, y0, x1, y1); break;
    }
}

static void
plus(CGFloat cx, CGFloat cy, CGFloat a)
{
    line(cx - a, cy, cx + a, cy);
    line(cx, cy - a, cx, cy + a);
}

static void
cross(CGFloat cx, CGFloat cy, CGFloat a)
{
    line(cx - a, cy - a, cx + a, cy + a);
    line(cx - a, cy + a, cx + a, cy - a);
}

static void
gear(CGFloat cx, CGFloat cy, CGFloat outer, int teeth, BOOL fill)
{
    NSBezierPath *p = stroke_path();
    CGFloat inner = outer * 0.78;
    for (int i = 0; i < teeth * 2; i++) {
        CGFloat a0 = M_PI * i / teeth, a1 = M_PI * (i + 1) / teeth;
        CGFloat rad = (i % 2) ? inner : outer;
        NSPoint q0 = NSMakePoint(cx + rad * cos(a0), cy + rad * sin(a0)), q1 = NSMakePoint(cx + rad * cos(a1), cy + rad * sin(a1));
        if (i == 0)
            [p moveToPoint:q0];
        else
            [p lineToPoint:q0];
        [p lineToPoint:q1];
    }
    [p closePath];
    [p appendBezierPathWithOvalInRect:NSMakeRect(cx - outer * 0.32, cy - outer * 0.32, outer * 0.64, outer * 0.64)];
    p.windingRule = NSWindingRuleEvenOdd;
    if (fill)
        [p fill];
    else
        [p stroke];
}

static void
magnifier(CGFloat cx, CGFloat cy, CGFloat radius)
{
    circle(cx, cy, radius, NO);
    line(cx + radius * 0.72, cy - radius * 0.72, cx + radius * 1.6, cy - radius * 1.6);
}

static void
person(CGFloat cx, CGFloat y, CGFloat scale, BOOL fill)
{
    circle(cx, y + scale * 1.45, scale * 0.45, fill);
    NSBezierPath *p = stroke_path();
    [p appendBezierPathWithArcWithCenter:NSMakePoint(cx, y) radius:scale * 0.85 startAngle:0 endAngle:180];
    [p closePath];
    if (fill)
        [p fill];
    else
        [p stroke];
}

static void
folder_outline(CGFloat x, CGFloat y, CGFloat w, CGFloat h, BOOL fill)
{
    CGFloat tab = w * 0.38, th = h * 0.16;
    NSBezierPath *p = stroke_path();
    [p moveToPoint:NSMakePoint(x, y)];
    [p lineToPoint:NSMakePoint(x, y + h)];
    [p lineToPoint:NSMakePoint(x + tab, y + h)];
    [p lineToPoint:NSMakePoint(x + tab + th, y + h - th)];
    [p lineToPoint:NSMakePoint(x + w, y + h - th)];
    [p lineToPoint:NSMakePoint(x + w, y)];
    [p closePath];
    if (fill)
        [p fill];
    else
        [p stroke];
}

static void
speaker(CGFloat x, CGFloat cy, CGFloat h)
{
    POLY(YES, YES, x, cy - h * 0.2, x + h * 0.25, cy - h * 0.2, x + h * 0.55, cy - h * 0.5, x + h * 0.55, cy + h * 0.5, x + h * 0.25,
         cy + h * 0.2, x, cy + h * 0.2);
}

static void
waves(CGFloat x, CGFloat cy, int n)
{
    for (int i = 0; i < n; i++)
        arc(x, cy, 3 + 3.5 * i, -45, 45, NO);
}

static void
lines(NSRect r, int count, int align) /* text alignment glyphs: 0 left, 1 centre, 2 right, 3 justified */
{
    CGFloat w = r.size.width - 3, gap = (r.size.height - 3) / (count - 1);
    for (int i = 0; i < count; i++) {
        CGFloat y = 1.5 + i * gap, len = (align == 3 || i % 2 == 0) ? w : w * 0.65;
        CGFloat x = align == 0 || align == 3 ? 1.5 : align == 1 ? 1.5 + (w - len) / 2 : 1.5 + w - len;
        line(x, y, x + len, y);
    }
}

static void
clock_face(CGFloat cx, CGFloat cy, CGFloat radius)
{
    circle(cx, cy, radius, NO);
    line(cx, cy, cx, cy + radius * 0.6);
    line(cx, cy, cx + radius * 0.45, cy);
}

static void
lock(NSRect r, BOOL open)
{
    CGFloat bw = 13, bh = 9, bx = 1.5;
    rrect(bx, 1, bw, bh, 2, YES);
    NSBezierPath *p = stroke_path();
    CGFloat sx = open ? bx + bw - 1 : bx + 2.5, sw = bw - 5;
    [p moveToPoint:NSMakePoint(sx, bh + 1)];
    [p lineToPoint:NSMakePoint(sx, bh + 4)];
    [p appendBezierPathWithArcWithCenter:NSMakePoint(sx + sw / 2, bh + 4) radius:sw / 2 startAngle:180 endAngle:0 clockwise:YES];
    if (!open)
        [p lineToPoint:NSMakePoint(sx + sw, bh + 1)];
    [p stroke];
}

static void
refresh(CGFloat cx, CGFloat cy, CGFloat radius)
{
    arc(cx, cy, radius, 100, 400, NO);
    CGFloat ex = cx + radius * cos(100 * M_PI / 180), ey = cy + radius * sin(100 * M_PI / 180);
    POLY(YES, YES, ex - 1, ey + 3.5, ex + 3.5, ey, ex - 1, ey - 3.5);
}

static void
envelope(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
    rrect(x, y, w, h, 1.5, NO);
    POLY(NO, NO, x, y + h, x + w / 2, y + h * 0.4, x + w, y + h);
}

/* MARK: Icons (32 points) */

static void
icon_folder(NSRect r, NSColor *body, void (^mark)(void))
{
    /* an archival folder: a manila back with its tab, a front leaf slightly lower */
    [MANILA_DARK setFill];
    folder_outline(3, 5, 26, 22, YES);
    [body setFill];
    rrect(3, 4, 26, 18, 1.5, YES);
    [[MANILA_DARK colorWithAlphaComponent:0.6] setStroke];
    line(6, 18, 26, 18);
    if (mark)
        mark();
}

static void
icon_person(CGFloat cx, CGFloat y, CGFloat scale, NSColor *color)
{
    [color setFill];
    person(cx, y, scale, YES);
}

static void
icon_disc(NSColor *fill, NSColor *edge)
{
    [fill setFill];
    circle(16, 16, 13.5, YES);
    [edge setStroke];
    circle(16, 16, 13.5, NO);
}

static void
globe(CGFloat cx, CGFloat cy, CGFloat radius)
{
    circle(cx, cy, radius, NO);
    NSBezierPath *m = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - radius * 0.45, cy - radius, radius * 0.9, radius * 2)];
    m.lineWidth = kStroke * 0.8;
    [m stroke];
    line(cx - radius, cy, cx + radius, cy);
    line(cx - radius * 0.86, cy + radius * 0.5, cx + radius * 0.86, cy + radius * 0.5);
    line(cx - radius * 0.86, cy - radius * 0.5, cx + radius * 0.86, cy - radius * 0.5);
}

static void
document(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
    CGFloat fold = w * 0.3;
    [PAPER setFill];
    [INK setStroke];
    NSBezierPath *p = stroke_path();
    p.lineWidth = 1;
    [p moveToPoint:NSMakePoint(x, y)];
    [p lineToPoint:NSMakePoint(x, y + h)];
    [p lineToPoint:NSMakePoint(x + w - fold, y + h)];
    [p lineToPoint:NSMakePoint(x + w, y + h - fold)];
    [p lineToPoint:NSMakePoint(x + w, y)];
    [p closePath];
    [p fill];
    [p stroke];
    [[INK colorWithAlphaComponent:0.35] setStroke];
    for (CGFloat ly = y + h * 0.25; ly < y + h - fold - 1; ly += 3)
        line(x + 2.5, ly, x + w - 2.5, ly);
}

static void
trash(BOOL full)
{
    [GRAPHITE setFill];
    POLY(YES, YES, 8, 3, 24, 3, 26, 24, 6, 24);
    [INK setStroke];
    POLY(YES, NO, 8, 3, 24, 3, 26, 24, 6, 24);
    rrect(4.5, 24, 23, 3, 1, NO);
    [[INK colorWithAlphaComponent:0.5] setStroke];
    for (int i = 0; i < 3; i++)
        line(11 + 5 * i, 6, 11.5 + 5 * i, 21);
    if (full) {
        [PAPER setFill];
        [INK setStroke];
        POLY(YES, YES, 9, 26, 14, 30, 19, 27, 24, 30, 23, 26);
        POLY(YES, NO, 9, 26, 14, 30, 19, 27, 24, 30, 23, 26);
    }
}

/* MARK: The table */

typedef struct {
    NSString *name;
    CGFloat w, h;
    BOOL isTemplate;
    Drawer draw;
} SystemImage;

static NSDictionary<NSString *, NSValue *> *
table(void)
{
    static NSMutableDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [NSMutableDictionary new];
        void (^add)(NSString *, CGFloat, CGFloat, BOOL, Drawer) = ^(NSString *n, CGFloat w, CGFloat h, BOOL tmpl, Drawer d) {
            SystemImage *s = calloc(1, sizeof *s);
            s->name = [n copy];
            s->w = w, s->h = h, s->isTemplate = tmpl;
            s->draw = [d copy];
            t[n] = [NSValue valueWithPointer:s];
        };
        /* the same glyph under its Touch Bar name too */
        void (^both)(NSString *, CGFloat, CGFloat, Drawer) = ^(NSString *n, CGFloat w, CGFloat h, Drawer d) {
            add([NSString stringWithFormat:@"NS%@Template", n], w, h, YES, d);
            add([NSString stringWithFormat:@"NSTouchBar%@Template", n], w, h, YES, d);
        };

        /* disclosure triangles (private, as Grapher and others ask for them) */
        add(@"NSDisclosable", 11, 11, YES, ^(NSRect r) { triangle(r, 1, 2.5); });
        add(@"NSDisclosed", 11, 11, YES, ^(NSRect r) { triangle(r, 3, 2.5); });

        /* navigation */
        add(@"NSGoLeftTemplate", 12, 17, YES, ^(NSRect r) { chevron(r, 0); });
        add(@"NSGoRightTemplate", 12, 17, YES, ^(NSRect r) { chevron(r, 1); });
        both(@"GoBack", 12, 17, ^(NSRect r) { chevron(r, 0); });
        both(@"GoForward", 12, 17, ^(NSRect r) { chevron(r, 1); });
        add(@"NSTouchBarGoUpTemplate", 18, 11, YES, ^(NSRect r) { chevron(r, 2); });
        add(@"NSTouchBarGoDownTemplate", 18, 11, YES, ^(NSRect r) { chevron(r, 3); });
        add(@"NSLeftFacingTriangleTemplate", 12, 17, YES, ^(NSRect r) { triangle(r, 0, 2); });
        add(@"NSRightFacingTriangleTemplate", 12, 17, YES, ^(NSRect r) { triangle(r, 1, 2); });

        /* editing */
        both(@"Add", 18, 17, ^(NSRect r) { plus(9, 8.5, 6); });
        both(@"Remove", 18, 5, ^(NSRect r) { line(3, 2.5, 15, 2.5); });
        add(@"NSMenuOnStateTemplate", 18, 17, YES, ^(NSRect r) { POLY(NO, NO, 4, 9, 7.5, 4.5, 14, 13); });
        add(@"NSMenuMixedStateTemplate", 18, 5, YES, ^(NSRect r) { line(5, 2.5, 13, 2.5); });
        add(@"NSActionTemplate", 20, 20, YES, ^(NSRect r) { gear(10, 10, 8, 8, YES); });
        add(@"NSSmartBadgeTemplate", 14, 14, YES, ^(NSRect r) { gear(7, 7, 6, 6, YES); });
        both(@"Share", 19, 23, ^(NSRect r) {
            POLY(NO, NO, 6, 14, 3, 14, 3, 1.5, 16, 1.5, 16, 14, 13, 14);
            line(9.5, 6, 9.5, 21);
            POLY(NO, NO, 5.5, 17, 9.5, 21, 13.5, 17);
        });
        both(@"Refresh", 18, 21, ^(NSRect r) { refresh(9, 9.5, 6.5); });
        add(@"NSRefreshFreestandingTemplate", 20, 20, YES, ^(NSRect r) { refresh(10, 10, 6.5); });
        add(@"NSStopProgressTemplate", 17, 16, YES, ^(NSRect r) { cross(8.5, 8, 4.5); });
        add(@"NSStopProgressFreestandingTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            cross(10, 10, 3.5);
        });
        add(@"NSFollowLinkFreestandingTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            line(6, 10, 14, 10);
            POLY(NO, NO, 10.5, 13.5, 14, 10, 10.5, 6.5);
        });
        add(@"NSInvalidDataFreestandingTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            line(10, 8.5, 10, 14.5);
            circle(10, 5.5, 1, YES);
        });
        add(@"NSRevealFreestandingTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            magnifier(9, 11, 3.2);
        });
        both(@"Search", 20, 20, ^(NSRect r) { magnifier(8.5, 11.5, 5.5); });
        both(@"Delete", 19, 22, ^(NSRect r) {
            POLY(YES, NO, 4, 1.5, 15, 1.5, 16, 17, 3, 17);
            line(1.5, 17, 17.5, 17);
            POLY(NO, NO, 7, 17, 7, 20, 12, 20, 12, 17);
        });

        /* locks */
        add(@"NSLockLockedTemplate", 17, 19, YES, ^(NSRect r) { lock(r, NO); });
        add(@"NSLockUnlockedTemplate", 21, 19, YES, ^(NSRect r) { lock(r, YES); });

        /* views */
        both(@"IconView", 19, 18, ^(NSRect r) {
            for (int i = 0; i < 4; i++)
                rrect(1.5 + (i % 2) * 9, 1.5 + (i / 2) * 8.5, 7, 6.5, 1, NO);
        });
        both(@"ListView", 21, 15, ^(NSRect r) {
            for (int i = 0; i < 3; i++) {
                circle(2.5, 2.5 + i * 5, 1.2, YES);
                line(6.5, 2.5 + i * 5, 19.5, 2.5 + i * 5);
            }
        });
        add(@"NSColumnViewTemplate", 24, 18, YES, ^(NSRect r) {
            rrect(1.5, 1.5, 21, 15, 1.5, NO);
            line(8.5, 1.5, 8.5, 16.5);
            line(15.5, 1.5, 15.5, 16.5);
        });
        add(@"NSFlowViewTemplate", 18, 10, YES, ^(NSRect r) {
            rrect(6, 1.5, 6, 7, 1, NO);
            POLY(YES, NO, 1.5, 3, 4, 2, 4, 8, 1.5, 7);
            POLY(YES, NO, 16.5, 3, 14, 2, 14, 8, 16.5, 7);
        });
        both(@"Slideshow", 24, 18, ^(NSRect r) {
            rrect(1.5, 1.5, 21, 15, 1.5, NO);
            POLY(YES, YES, 10, 5, 16, 9, 10, 13);
        });
        add(@"NSTouchBarSidebarTemplate", 24, 18, YES, ^(NSRect r) {
            rrect(1.5, 1.5, 21, 15, 1.5, NO);
            line(8.5, 1.5, 8.5, 16.5);
        });
        add(@"NSPathTemplate", 25, 15, YES, ^(NSRect r) {
            for (int i = 0; i < 3; i++)
                POLY(NO, NO, 2 + i * 8, 2.5, 7 + i * 8, 7.5, 2 + i * 8, 12.5);
        });
        both(@"QuickLook", 26, 17, ^(NSRect r) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(1.5, 8.5)];
            [p curveToPoint:NSMakePoint(24.5, 8.5) controlPoint1:NSMakePoint(7, 16) controlPoint2:NSMakePoint(19, 16)];
            [p curveToPoint:NSMakePoint(1.5, 8.5) controlPoint1:NSMakePoint(19, 1) controlPoint2:NSMakePoint(7, 1)];
            [p stroke];
            circle(13, 8.5, 3, YES);
        });
        add(@"NSEnterFullScreenTemplate", 20, 19, YES, ^(NSRect r) {
            POLY(NO, NO, 2, 12, 2, 17, 7, 17);
            POLY(NO, NO, 18, 7, 18, 2, 13, 2);
            line(2, 17, 8, 11);
            line(18, 2, 12, 8);
        });
        add(@"NSTouchBarEnterFullScreenTemplate", 20, 19, YES, ^(NSRect r) {
            POLY(NO, NO, 2, 12, 2, 17, 7, 17);
            POLY(NO, NO, 18, 7, 18, 2, 13, 2);
            line(2, 17, 8, 11);
            line(18, 2, 12, 8);
        });
        void (^exitFull)(NSRect) = ^(NSRect r) {
            POLY(NO, NO, 3, 8, 8, 8, 8, 3);
            POLY(NO, NO, 12, 17, 12, 12, 17, 12);
            line(8, 8, 2, 2);
            line(12, 12, 18, 18);
        };
        add(@"NSExitFullScreenTemplate", 20, 20, YES, exitFull);
        add(@"NSTouchBarExitFullScreenTemplate", 20, 20, YES, exitFull);

        /* places and things */
        both(@"Bookmarks", 22, 18, ^(NSRect r) {
            POLY(NO, NO, 11, 3, 11, 16, 6, 16.5, 1.5, 15, 1.5, 2, 6, 3.5, 11, 3);
            POLY(NO, NO, 11, 3, 16, 3.5, 20.5, 2, 20.5, 15, 16, 16.5, 11, 16);
        });
        add(@"NSHomeTemplate", 24, 21, YES, ^(NSRect r) {
            POLY(NO, NO, 2, 10, 12, 19, 22, 10);
            POLY(NO, NO, 5, 12, 5, 1.5, 19, 1.5, 19, 12);
            rrect(10, 1.5, 4, 6, 0.5, YES);
        });
        add(@"NSPrintTemplate", 23, 21, YES, ^(NSRect r) {
            rrect(1.5, 6, 20, 9, 2, NO);
            POLY(NO, NO, 6, 15, 6, 19.5, 17, 19.5, 17, 15);
            POLY(YES, NO, 6, 1.5, 17, 1.5, 17, 9, 6, 9);
        });
        add(@"NSBluetoothTemplate", 16, 21, YES, ^(NSRect r) {
            POLY(NO, NO, 3.5, 6, 12, 14.5, 8, 19, 8, 2, 12, 6.5, 3.5, 15);
        });
        add(@"NSIChatTheaterTemplate", 15, 13, YES, ^(NSRect r) {
            rrect(1.5, 3.5, 12, 8, 1, NO);
            line(5, 1, 10, 1);
        });
        add(@"NSTouchBarTagIconTemplate", 22, 22, YES, ^(NSRect r) {
            POLY(YES, NO, 2, 12, 12, 2, 20, 10, 20, 20, 10, 20);
            circle(15.5, 15.5, 1.5, YES);
        });
        void (^folderGlyph)(NSRect) = ^(NSRect r) { folder_outline(1.5, 1.5, r.size.width - 3, r.size.height - 3, NO); };
        add(@"NSTouchBarFolderTemplate", 23, 18, YES, folderGlyph);
        add(@"NSTouchBarFolderMoveToTemplate", 23, 18, YES, ^(NSRect r) {
            folderGlyph(r);
            line(7, 7.5, 16, 7.5);
            POLY(NO, NO, 13, 10.5, 16, 7.5, 13, 4.5);
        });
        add(@"NSTouchBarFolderCopyToTemplate", 25, 19, YES, ^(NSRect r) {
            folderGlyph(r);
            plus(12.5, 8, 3.5);
        });
        add(@"NSTouchBarNewFolderTemplate", 25, 20, YES, ^(NSRect r) {
            folderGlyph(r);
            plus(12.5, 8.5, 3.5);
        });
        add(@"NSTouchBarUserTemplate", 18, 18, YES, ^(NSRect r) { person(9, 2, 6.5, NO); });
        add(@"NSTouchBarUserAddTemplate", 23, 21, YES, ^(NSRect r) {
            person(9, 2, 6.5, NO);
            plus(19, 15, 3);
        });
        add(@"NSTouchBarUserGroupTemplate", 27, 19, YES, ^(NSRect r) {
            person(9, 2, 6, NO);
            person(19, 3, 5, NO);
        });
        add(@"NSTouchBarMailTemplate", 24, 17, YES, ^(NSRect r) { envelope(1.5, 1.5, 21, 14); });
        add(@"NSTouchBarNewMessageTemplate", 22, 19, YES, ^(NSRect r) {
            rrect(1.5, 5, 19, 12.5, 4, NO);
            POLY(NO, NO, 5, 5, 4, 1, 9, 5);
        });
        add(@"NSTouchBarComposeTemplate", 21, 21, YES, ^(NSRect r) {
            POLY(NO, NO, 10, 3, 2, 3, 2, 18, 13, 18);
            POLY(YES, NO, 8, 7, 18, 17, 20, 15, 10, 5);
        });
        add(@"NSTouchBarOpenInBrowserTemplate", 20, 20, YES, ^(NSRect r) { globe(10, 10, 8.5); });
        add(@"NSTouchBarDownloadTemplate", 20, 20, YES, ^(NSRect r) {
            line(10, 18.5, 10, 6);
            POLY(NO, NO, 5.5, 10.5, 10, 6, 14.5, 10.5);
            line(2, 1.5, 18, 1.5);
        });
        add(@"NSTouchBarGetInfoTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            line(10, 5, 10, 11);
            circle(10, 14, 1, YES);
        });
        add(@"NSTouchBarAddDetailTemplate", 20, 20, YES, ^(NSRect r) {
            circle(10, 10, 8.5, NO);
            plus(10, 10, 4);
        });
        add(@"NSTouchBarHistoryTemplate", 20, 20, YES, ^(NSRect r) { clock_face(10, 10, 8.5); });
        add(@"NSTouchBarAlarmTemplate", 19, 20, YES, ^(NSRect r) {
            clock_face(9.5, 9, 7.5);
            line(2, 17, 5, 19);
            line(17, 17, 14, 19);
        });
        add(@"NSTouchBarAddTabTemplate", 18, 30, YES, ^(NSRect r) { plus(9, 15, 5.5); });
        add(@"NSTouchBarRotateLeftTemplate", 19, 21, YES, ^(NSRect r) {
            arc(10, 9, 7, 200, -60, YES);
            POLY(YES, YES, 0.5, 9.5, 6, 9.5, 3, 13.5);
        });
        add(@"NSTouchBarRotateRightTemplate", 19, 21, YES, ^(NSRect r) {
            arc(9, 9, 7, -20, 240, NO);
            POLY(YES, YES, 18.5, 9.5, 13, 9.5, 16, 13.5);
        });
        add(@"NSTouchBarCommunicationAudioTemplate", 20, 19, YES, ^(NSRect r) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(4, 17)];
            [p curveToPoint:NSMakePoint(17, 3) controlPoint1:NSMakePoint(2, 9) controlPoint2:NSMakePoint(9, 1)];
            [p stroke];
            line(4, 17, 7, 13);
            line(17, 3, 13, 6);
        });
        add(@"NSTouchBarCommunicationVideoTemplate", 24, 17, YES, ^(NSRect r) {
            rrect(1.5, 2.5, 15, 12, 2, NO);
            POLY(YES, NO, 16.5, 7, 22.5, 3.5, 22.5, 13.5, 16.5, 10);
        });

        /* media */
        add(@"NSPlayTemplate", 25, 23, YES, ^(NSRect r) { POLY(YES, YES, 7, 3, 21, 11.5, 7, 20); });
        add(@"NSTouchBarPlayTemplate", 15, 17, YES, ^(NSRect r) { POLY(YES, YES, 2, 1.5, 13.5, 8.5, 2, 15.5); });
        add(@"NSPauseTemplate", 8, 9, YES, ^(NSRect r) {
            NSRectFill(NSMakeRect(0.5, 0, 2.5, 9));
            NSRectFill(NSMakeRect(5, 0, 2.5, 9));
        });
        add(@"NSTouchBarPauseTemplate", 14, 17, YES, ^(NSRect r) {
            NSRectFill(NSMakeRect(1.5, 1, 4, 15));
            NSRectFill(NSMakeRect(8.5, 1, 4, 15));
        });
        add(@"NSTouchBarPlayPauseTemplate", 28, 16, YES, ^(NSRect r) {
            POLY(YES, YES, 1.5, 1.5, 13, 8, 1.5, 14.5);
            NSRectFill(NSMakeRect(17, 1.5, 3.5, 13));
            NSRectFill(NSMakeRect(23, 1.5, 3.5, 13));
        });
        add(@"NSTouchBarFastForwardTemplate", 25, 16, YES, ^(NSRect r) {
            POLY(YES, YES, 1.5, 1.5, 12, 8, 1.5, 14.5);
            POLY(YES, YES, 12.5, 1.5, 23.5, 8, 12.5, 14.5);
        });
        add(@"NSTouchBarRewindTemplate", 25, 16, YES, ^(NSRect r) {
            POLY(YES, YES, 23.5, 1.5, 13, 8, 23.5, 14.5);
            POLY(YES, YES, 12.5, 1.5, 1.5, 8, 12.5, 14.5);
        });
        add(@"NSTouchBarSkipToEndTemplate", 19, 16, YES, ^(NSRect r) {
            POLY(YES, YES, 1.5, 1.5, 13, 8, 1.5, 14.5);
            NSRectFill(NSMakeRect(14.5, 1.5, 3, 13));
        });
        add(@"NSTouchBarSkipToStartTemplate", 19, 16, YES, ^(NSRect r) {
            POLY(YES, YES, 17.5, 1.5, 6, 8, 17.5, 14.5);
            NSRectFill(NSMakeRect(1.5, 1.5, 3, 13));
        });
        add(@"NSTouchBarSkipAheadTemplate", 30, 16, YES, ^(NSRect r) {
            arc(8, 8, 6, 160, -60, YES);
            POLY(YES, YES, 11, 0.5, 15, 3.5, 10.5, 5.5);
            POLY(YES, YES, 17, 1.5, 28, 8, 17, 14.5);
        });
        add(@"NSTouchBarSkipBackTemplate", 30, 16, YES, ^(NSRect r) {
            arc(22, 8, 6, 20, 240, NO);
            POLY(YES, YES, 19, 0.5, 15, 3.5, 19.5, 5.5);
            POLY(YES, YES, 13, 1.5, 2, 8, 13, 14.5);
        });
        add(@"NSTouchBarRecordStartTemplate", 20, 20, YES, ^(NSRect r) { circle(10, 10, 7, YES); });
        add(@"NSTouchBarRecordStopTemplate", 18, 17, YES, ^(NSRect r) { rrect(3, 2.5, 12, 12, 2, YES); });
        add(@"NSTouchBarAudioInputTemplate", 17, 21, YES, ^(NSRect r) {
            rrect(5.5, 7, 6, 12.5, 3, NO);
            arc(8.5, 11, 6.5, 200, 340, NO);
            line(8.5, 4.5, 8.5, 1.5);
        });
        add(@"NSTouchBarAudioInputMuteTemplate", 17, 21, YES, ^(NSRect r) {
            rrect(5.5, 7, 6, 12.5, 3, NO);
            arc(8.5, 11, 6.5, 200, 340, NO);
            line(8.5, 4.5, 8.5, 1.5);
            line(1.5, 19.5, 15.5, 1.5);
        });
        add(@"NSTouchBarAudioOutputMuteTemplate", 17, 20, YES, ^(NSRect r) {
            speaker(1.5, 10, 14);
            cross(13.5, 10, 2.5);
        });
        add(@"NSTouchBarAudioOutputVolumeOffTemplate", 17, 18, YES, ^(NSRect r) { speaker(1.5, 9, 14); });
        add(@"NSTouchBarAudioOutputVolumeLowTemplate", 20, 18, YES, ^(NSRect r) {
            speaker(1.5, 9, 14);
            waves(10, 9, 1);
        });
        add(@"NSTouchBarVolumeDownTemplate", 20, 18, YES, ^(NSRect r) {
            speaker(1.5, 9, 14);
            waves(10, 9, 1);
        });
        add(@"NSTouchBarAudioOutputVolumeMediumTemplate", 24, 18, YES, ^(NSRect r) {
            speaker(1.5, 9, 14);
            waves(10, 9, 2);
        });
        void (^loud)(NSRect) = ^(NSRect r) {
            speaker(1.5, r.size.height / 2, 14);
            waves(10, r.size.height / 2, 3);
        };
        add(@"NSTouchBarAudioOutputVolumeHighTemplate", 27, 19, YES, loud);
        add(@"NSTouchBarVolumeUpTemplate", 27, 19, YES, loud);
        add(@"NSTouchBarPlayheadTemplate", 7, 30, NO, ^(NSRect r) {
            [INK setFill];
            NSRectFill(NSMakeRect(2.75, 0, 1.5, 24));
            POLY(YES, YES, 0, 30, 7, 30, 7, 26, 3.5, 23, 0, 26);
        });

        /* text */
        add(@"NSTouchBarTextBoldTemplate", 14, 15, YES, ^(NSRect r) { text(@"B", r, 13, NSFontWeightBold, 0, nil); });
        add(@"NSTouchBarTextItalicTemplate", 13, 15, YES, ^(NSRect r) { text(@"I", r, 13, NSFontWeightRegular, NSItalicFontMask, nil); });
        add(@"NSTouchBarTextUnderlineTemplate", 14, 18, YES, ^(NSRect r) {
            text(@"U", NSMakeRect(0, 3, 14, 15), 13, NSFontWeightRegular, 0, nil);
            line(2, 1.5, 12, 1.5);
        });
        add(@"NSTouchBarTextStrikethroughTemplate", 18, 16, YES, ^(NSRect r) {
            text(@"S", r, 13, NSFontWeightRegular, 0, nil);
            line(2, 8, 16, 8);
        });
        add(@"NSTouchBarTextLeftAlignTemplate", 21, 17, YES, ^(NSRect r) { lines(r, 4, 0); });
        add(@"NSTouchBarTextCenterAlignTemplate", 21, 17, YES, ^(NSRect r) { lines(r, 4, 1); });
        add(@"NSTouchBarTextRightAlignTemplate", 21, 17, YES, ^(NSRect r) { lines(r, 4, 2); });
        add(@"NSTouchBarTextJustifiedAlignTemplate", 21, 17, YES, ^(NSRect r) { lines(r, 4, 3); });
        add(@"NSTouchBarTextListTemplate", 21, 15, YES, ^(NSRect r) {
            for (int i = 0; i < 3; i++) {
                circle(2.5, 2.5 + i * 5, 1.2, YES);
                line(6.5, 2.5 + i * 5, 19.5, 2.5 + i * 5);
            }
        });
        add(@"NSTouchBarTextBoxTemplate", 25, 18, YES, ^(NSRect r) {
            rrect(1.5, 1.5, 22, 15, 1.5, NO);
            text(@"T", r, 11, NSFontWeightMedium, 0, nil);
        });
        add(@"NSTouchBarColorPickerFont", 13, 30, NO, ^(NSRect r) {
            text(@"A", NSMakeRect(0, 8, 13, 22), 15, NSFontWeightMedium, 0, INK);
            [BRICK setFill];
            NSRectFill(NSMakeRect(0, 3, 13, 3));
        });
        add(@"NSTouchBarColorPickerFill", 18, 30, NO, ^(NSRect r) {
            [INK setFill];
            rrect(2, 10, 14, 14, 2, YES);
            [BRICK setFill];
            NSRectFill(NSMakeRect(0, 3, 18, 3));
        });
        add(@"NSTouchBarColorPickerStroke", 18, 30, NO, ^(NSRect r) {
            [INK setStroke];
            rrect(2.5, 10.5, 13, 13, 2, NO);
            [BRICK setFill];
            NSRectFill(NSMakeRect(0, 3, 18, 3));
        });

        /* status dots (not templates) */
        void (^dot)(NSString *, NSColor *) = ^(NSString *n, NSColor *c) {
            add(n, 16, 16, NO, ^(NSRect r) {
                if (c) {
                    [c setFill];
                    circle(8, 8, 5, YES);
                    [[INK colorWithAlphaComponent:0.35] setStroke];
                    circle(8, 8, 5, NO);
                } else {
                    [GRAPHITE setStroke];
                    circle(8, 8, 5, NO);
                }
            });
        };
        dot(@"NSStatusAvailable", GREEN);
        dot(@"NSStatusPartiallyAvailable", AMBER);
        dot(@"NSStatusUnavailable", BRICK);
        dot(@"NSStatusNone", nil);

        /* icons */
        add(@"NSCaution", 32, 32, NO, ^(NSRect r) {
            [AMBER setFill];
            POLY(YES, YES, 16, 29, 30, 4, 2, 4);
            [INK setStroke];
            POLY(YES, NO, 16, 29, 30, 4, 2, 4);
            [INK setFill];
            POLY(YES, YES, 14.6, 21, 17.4, 21, 16.7, 11, 15.3, 11);
            circle(16, 7.5, 1.6, YES);
        });
        add(@"NSInfo", 32, 32, NO, ^(NSRect r) {
            icon_disc(SLATE, INK);
            [PAPER setFill];
            NSRectFill(NSMakeRect(14.5, 7, 3, 11));
            circle(16, 22.5, 2, YES);
        });
        add(@"NSAdvanced", 32, 32, NO, ^(NSRect r) {
            [GRAPHITE setFill];
            gear(16, 16, 13, 10, YES);
            [INK setStroke];
            gear(16, 16, 13, 10, NO);
        });
        add(@"NSPreferencesGeneral", 32, 32, NO, ^(NSRect r) {
            /* a machined dial */
            icon_disc(GRAPHITE, INK);
            [PAPER setFill];
            circle(16, 16, 9, YES);
            [INK setStroke];
            for (int i = 0; i < 12; i++) {
                CGFloat a = i * M_PI / 6;
                line(16 + 11 * cos(a), 16 + 11 * sin(a), 16 + 12.8 * cos(a), 16 + 12.8 * sin(a));
            }
            [BRICK setStroke];
            line(16, 16, 21, 21);
        });
        add(@"NSBonjour", 32, 32, NO, ^(NSRect r) {
            icon_disc(PAPER, INK);
            [SLATE setStroke];
            for (int i = 0; i < 3; i++)
                arc(10, 10, 5 + 5 * i, 0, 90, NO);
            [SLATE setFill];
            circle(10, 10, 2.2, YES);
        });
        add(@"NSColorPanel", 32, 32, NO, ^(NSRect r) {
            NSColor *cs[] = {BRICK, AMBER, GREEN, SLATE, rgb(0x7a5c8f), rgb(0xd17c5a)};
            for (int i = 0; i < 6; i++) {
                [cs[i] setFill];
                NSBezierPath *p = [NSBezierPath bezierPath];
                [p moveToPoint:NSMakePoint(16, 16)];
                [p appendBezierPathWithArcWithCenter:NSMakePoint(16, 16) radius:13.5 startAngle:i * 60 endAngle:(i + 1) * 60];
                [p closePath];
                [p fill];
            }
            [PAPER setFill];
            circle(16, 16, 4, YES);
            [INK setStroke];
            circle(16, 16, 13.5, NO);
        });
        add(@"NSFontPanel", 32, 32, NO, ^(NSRect r) {
            [PAPER setFill];
            rrect(3, 3, 26, 26, 3, YES);
            [INK setStroke];
            rrect(3, 3, 26, 26, 3, NO);
            text(@"Aa", NSMakeRect(3, 3, 26, 26), 15, NSFontWeightMedium, 0, INK);
        });
        add(@"NSComputer", 32, 32, NO, ^(NSRect r) {
            /* a small instrument display on a stand */
            [INK setFill];
            rrect(2, 9, 28, 19, 2, YES);
            [GREEN setFill];
            NSRectFill(NSMakeRect(4.5, 11.5, 23, 14));
            [INK setFill];
            POLY(YES, YES, 13, 9, 19, 9, 20.5, 4, 11.5, 4);
            rrect(8, 2.5, 16, 2, 1, YES);
        });
        add(@"NSNetwork", 32, 32, NO, ^(NSRect r) {
            icon_disc(SLATE, INK);
            [PAPER setStroke];
            globe(16, 16, 10);
        });
        void (^cloud)(NSRect) = ^(NSRect r) {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p appendBezierPathWithOvalInRect:NSMakeRect(4, 8, 12, 12)];
            [p appendBezierPathWithOvalInRect:NSMakeRect(10, 11, 15, 15)];
            [p appendBezierPathWithOvalInRect:NSMakeRect(18, 8, 11, 11)];
            [p appendBezierPathWithRect:NSMakeRect(10, 8, 14, 7)];
            [SLATE setFill];
            [p fill];
        };
        add(@"NSDotMac", 32, 32, NO, cloud);
        add(@"NSMobileMe", 32, 32, NO, cloud);
        add(@"NSFolder", 32, 32, NO, ^(NSRect r) { icon_folder(r, MANILA, nil); });
        add(@"NSFolderBurnable", 32, 32, NO, ^(NSRect r) {
            icon_folder(r, MANILA, ^{
                [INK setStroke];
                circle(16, 11, 4.5, NO);
                circle(16, 11, 1, YES);
            });
        });
        add(@"NSFolderSmart", 32, 32, NO, ^(NSRect r) {
            icon_folder(r, rgb(0xb9c6cf), ^{
                [INK setFill];
                gear(16, 11.5, 5, 6, YES);
            });
        });
        add(@"NSMultipleDocuments", 32, 32, NO, ^(NSRect r) {
            document(10, 6, 17, 22);
            document(5, 3, 17, 22);
        });
        add(@"NSTrashEmpty", 32, 32, NO, ^(NSRect r) { trash(NO); });
        add(@"NSTrashFull", 32, 32, NO, ^(NSRect r) { trash(YES); });
        add(@"NSUser", 32, 32, NO, ^(NSRect r) {
            icon_disc(PAPER, INK);
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2.5, 2.5, 27, 27)] addClip];
            icon_person(16, 4, 11, GRAPHITE);
            [NSGraphicsContext restoreGraphicsState];
        });
        add(@"NSUserGuest", 32, 32, NO, ^(NSRect r) {
            icon_disc(PAPER, INK);
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2.5, 2.5, 27, 27)] addClip];
            icon_person(16, 4, 11, AMBER);
            [NSGraphicsContext restoreGraphicsState];
        });
        void (^group)(NSRect) = ^(NSRect r) {
            icon_person(21, 6, 8, GRAPHITE);
            icon_person(11, 3, 9.5, INK);
        };
        add(@"NSUserGroup", 32, 32, NO, group);
        add(@"NSEveryone", 32, 32, NO, ^(NSRect r) {
            icon_person(24, 7, 6.5, GRAPHITE);
            icon_person(8, 7, 6.5, GRAPHITE);
            icon_person(16, 3, 9, INK);
        });
        add(@"NSUserAccounts", 32, 32, NO, ^(NSRect r) {
            group(r);
            [GREEN setFill];
            circle(25, 25, 5, YES);
            [PAPER setStroke];
            plus(25, 25, 2.5);
        });
    });
    return t;
}

/* The system image named `name` (one object per name), or nil. */
__attribute__((visibility("hidden"))) NSImage *
FinchSystemImageNamed(NSString *name)
{
    static NSMutableDictionary *made;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ made = [NSMutableDictionary new]; });
    @synchronized(made) {
        NSImage *i = made[name];
        if (i)
            return i;
        SystemImage *s = [table()[name] pointerValue];
        if (!s)
            return nil;
        Drawer draw = s->draw;
        BOOL tmpl = s->isTemplate;
        i = [NSImage imageWithSize:NSMakeSize(s->w, s->h) flipped:NO drawingHandler:^BOOL(NSRect dst) {
            [NSGraphicsContext saveGraphicsState];
            /* drawn at the image's own size, scaled to wherever it's drawn */
            NSAffineTransform *t = [NSAffineTransform transform];
            [t translateXBy:dst.origin.x yBy:dst.origin.y];
            [t scaleXBy:dst.size.width / s->w yBy:dst.size.height / s->h];
            [t concat];
            if (tmpl) {
                [[NSColor blackColor] setFill];
                [[NSColor blackColor] setStroke];
            }
            draw(NSMakeRect(0, 0, s->w, s->h));
            [NSGraphicsContext restoreGraphicsState];
            return YES;
        }];
        i.template = tmpl;
        [i setName:name];
        made[name] = i;
        return i;
    }
}

/* Every name, for tests. */
__attribute__((visibility("hidden"))) NSArray<NSString *> *
FinchSystemImageNames(void)
{
    return [table().allKeys sortedArrayUsingSelector:@selector(compare:)];
}

/* MARK: - Symbol images
 *
 * +imageWithSystemSymbolName: and friends: Finch's own glyphs (SF Symbols are Apple's
 * artwork) under the symbol names apps use, drawn in the same ink line style. A name is
 * read as a base glyph and Apple's modifiers: ".fill" (the glyph's filled form),
 * ".circle" or ".square" (enclosed; with ".fill", a filled shape with the glyph knocked
 * out), ".slash" (struck through) and ".badge.plus" / ".badge.minus" / ".badge.checkmark"
 * (a small mark at the corner). Names with no glyph give nil, as Apple's unknown names
 * do. Sizes follow the configuration as Apple's do: a glyph's size at 13 points scaled
 * with the point size and by the scale (small 0.82, large 1.29); the weight sets the
 * stroke.
 */

typedef void (^SymbolDrawer)(CGFloat w, CGFloat h, BOOL fill);

typedef struct {
    CGFloat w, h; /* at 13 points */
    __unsafe_unretained NSString *label;
    SymbolDrawer draw;
} SymbolGlyph;

static void
shape(BOOL fill, NSBezierPath *p)
{
    p.lineWidth = kStroke;
    p.lineJoinStyle = NSLineJoinStyleRound;
    p.lineCapStyle = NSLineCapStyleRound;
    if (fill)
        [p fill];
    else
        [p stroke];
}

static NSBezierPath *
star_path(CGFloat cx, CGFloat cy, CGFloat outer)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    for (int i = 0; i < 10; i++) {
        CGFloat a = M_PI / 2 + i * M_PI / 5, r = i % 2 ? outer * 0.45 : outer;
        NSPoint q = NSMakePoint(cx + r * cos(a), cy + r * sin(a));
        if (i == 0)
            [p moveToPoint:q];
        else
            [p lineToPoint:q];
    }
    [p closePath];
    return p;
}

static NSBezierPath *
heart_path(CGFloat w, CGFloat h)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(w / 2, 1.5)];
    [p curveToPoint:NSMakePoint(1, h * 0.62) controlPoint1:NSMakePoint(w * 0.25, h * 0.3) controlPoint2:NSMakePoint(1, h * 0.42)];
    [p curveToPoint:NSMakePoint(w / 2, h * 0.72) controlPoint1:NSMakePoint(1, h * 0.95) controlPoint2:NSMakePoint(w * 0.42, h * 0.98)];
    [p curveToPoint:NSMakePoint(w - 1, h * 0.62) controlPoint1:NSMakePoint(w * 0.58, h * 0.98) controlPoint2:NSMakePoint(w - 1, h * 0.95)];
    [p curveToPoint:NSMakePoint(w / 2, 1.5) controlPoint1:NSMakePoint(w - 1, h * 0.42) controlPoint2:NSMakePoint(w * 0.75, h * 0.3)];
    [p closePath];
    return p;
}

static NSBezierPath *
doc_path(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
    CGFloat fold = w * 0.35;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x, y)];
    [p lineToPoint:NSMakePoint(x, y + h)];
    [p lineToPoint:NSMakePoint(x + w - fold, y + h)];
    [p lineToPoint:NSMakePoint(x + w, y + h - fold)];
    [p lineToPoint:NSMakePoint(x + w, y)];
    [p closePath];
    return p;
}

static void
arrow(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat head)
{
    line(x1, y1, x2, y2);
    CGFloat a = atan2(y2 - y1, x2 - x1);
    POLY(NO, NO, x2 - head * cos(a - 0.6), y2 - head * sin(a - 0.6), x2, y2, x2 - head * cos(a + 0.6), y2 - head * sin(a + 0.6));
}

/* A curved arrow round (cx, cy), from `from` to `to` degrees, the head at `to`. */
static void
curved_arrow(CGFloat cx, CGFloat cy, CGFloat r, CGFloat from, CGFloat to)
{
    BOOL cw = to < from;
    arc(cx, cy, r, from, to, cw);
    CGFloat a = to * M_PI / 180, ex = cx + r * cos(a), ey = cy + r * sin(a);
    CGFloat tangent = a + (cw ? -M_PI / 2 : M_PI / 2), head = r * 0.55;
    POLY(YES, YES, ex + head * cos(tangent), ey + head * sin(tangent), ex + head * 0.55 * cos(a), ey + head * 0.55 * sin(a),
         ex - head * 0.55 * cos(a), ey - head * 0.55 * sin(a));
}

static NSDictionary<NSString *, NSValue *> *
symbol_glyphs(void)
{
    static NSMutableDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [NSMutableDictionary new];
        void (^add)(NSString *, CGFloat, CGFloat, NSString *, SymbolDrawer) = ^(NSString *n, CGFloat w, CGFloat h, NSString *label,
                                                                                SymbolDrawer d) {
            SymbolGlyph *g = calloc(1, sizeof *g);
            g->w = w, g->h = h;
            g->label = [label copy];
            g->draw = [d copy];
            t[n] = [NSValue valueWithPointer:g];
        };
        void (^alias)(NSString *, NSString *) = ^(NSString *n, NSString *to) { t[n] = t[to]; };

        /* marks */
        add(@"plus", 14, 13, @"add", ^(CGFloat w, CGFloat h, BOOL f) { plus(w / 2, h / 2, w / 2 - 1.5); });
        add(@"minus", 14, 4, @"remove", ^(CGFloat w, CGFloat h, BOOL f) { line(1.5, h / 2, w - 1.5, h / 2); });
        add(@"xmark", 12, 12, @"close", ^(CGFloat w, CGFloat h, BOOL f) { cross(w / 2, h / 2, w / 2 - 1.5); });
        alias(@"multiply", @"xmark");
        add(@"checkmark", 14, 13, @"checkmark", ^(CGFloat w, CGFloat h, BOOL f) { POLY(NO, NO, 1.5, h * 0.48, w * 0.38, 1.5, w - 1.5, h - 1.5); });
        add(@"exclamationmark", 4, 14, @"alert", ^(CGFloat w, CGFloat h, BOOL f) {
            line(w / 2, h * 0.38, w / 2, h - 1.5);
            circle(w / 2, 1.8, 1, YES);
        });
        add(@"questionmark", 10, 15, @"help", ^(CGFloat w, CGFloat h, BOOL f) {
            arc(w / 2, h * 0.7, w / 2 - 1.5, 160, -60, YES);
            line(w / 2 + (w / 2 - 1.5) * 0.5, h * 0.7 - (w / 2 - 1.5) * 0.86, w / 2, h * 0.38);
            circle(w / 2, 1.8, 1, YES);
        });
        add(@"info", 6, 14, @"info", ^(CGFloat w, CGFloat h, BOOL f) {
            line(w / 2, 1.5, w / 2, h * 0.62);
            line(w / 2 - 2, 1.5, w / 2 + 2, 1.5);
            circle(w / 2, h - 2, 1.1, YES);
        });
        add(@"ellipsis", 16, 4, @"more", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 3; i++)
                circle(2.5 + i * (w - 5) / 2, h / 2, 1.4, YES);
        });
        add(@"star", 17, 16, @"favorite", ^(CGFloat w, CGFloat h, BOOL f) { shape(f, star_path(w / 2, h / 2 - 0.5, w / 2 - 1)); });
        add(@"heart", 16, 14, @"love", ^(CGFloat w, CGFloat h, BOOL f) { shape(f, heart_path(w, h)); });
        add(@"circle", 15, 15, @"circle", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 1, w - 2, h - 2)];
            shape(f, p);
        });
        add(@"square", 15, 15, @"square", ^(CGFloat w, CGFloat h, BOOL f) {
            shape(f, [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1, w - 2, h - 2) xRadius:3 yRadius:3]);
        });
        add(@"rectangle", 18, 13, @"rectangle", ^(CGFloat w, CGFloat h, BOOL f) {
            shape(f, [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1.5, w - 2, h - 3) xRadius:2.5 yRadius:2.5]);
        });

        /* directions */
        void (^chev)(NSString *, int) = ^(NSString *n, int dir) {
            BOOL vertical = dir >= 2;
            add(n, vertical ? 14 : 10, vertical ? 9 : 14, n, ^(CGFloat w, CGFloat h, BOOL f) { chevron(NSMakeRect(0, 0, w, h), dir); });
        };
        chev(@"chevron.left", 0), chev(@"chevron.right", 1), chev(@"chevron.up", 2), chev(@"chevron.down", 3);
        alias(@"chevron.backward", @"chevron.left"), alias(@"chevron.forward", @"chevron.right");
        alias(@"chevron.compact.left", @"chevron.left"), alias(@"chevron.compact.right", @"chevron.right");
        alias(@"chevron.compact.up", @"chevron.up"), alias(@"chevron.compact.down", @"chevron.down");
        add(@"arrow.up", 12, 15, @"up", ^(CGFloat w, CGFloat h, BOOL f) { arrow(w / 2, 1.5, w / 2, h - 1.5, 5); });
        add(@"arrow.down", 12, 15, @"down", ^(CGFloat w, CGFloat h, BOOL f) { arrow(w / 2, h - 1.5, w / 2, 1.5, 5); });
        add(@"arrow.left", 15, 12, @"back", ^(CGFloat w, CGFloat h, BOOL f) { arrow(w - 1.5, h / 2, 1.5, h / 2, 5); });
        add(@"arrow.right", 15, 12, @"forward", ^(CGFloat w, CGFloat h, BOOL f) { arrow(1.5, h / 2, w - 1.5, h / 2, 5); });
        alias(@"arrow.backward", @"arrow.left"), alias(@"arrow.forward", @"arrow.right");
        add(@"arrow.left.arrow.right", 17, 14, @"swap", ^(CGFloat w, CGFloat h, BOOL f) {
            arrow(1.5, h * 0.7, w - 1.5, h * 0.7, 4);
            arrow(w - 1.5, h * 0.3, 1.5, h * 0.3, 4);
        });
        add(@"arrow.up.arrow.down", 15, 15, @"sort", ^(CGFloat w, CGFloat h, BOOL f) {
            arrow(w * 0.3, 1.5, w * 0.3, h - 1.5, 4);
            arrow(w * 0.7, h - 1.5, w * 0.7, 1.5, 4);
        });
        add(@"arrow.clockwise", 15, 16, @"refresh", ^(CGFloat w, CGFloat h, BOOL f) { curved_arrow(w / 2, h / 2, w / 2 - 2, 120, -200); });
        add(@"arrow.counterclockwise", 15, 16, @"undo", ^(CGFloat w, CGFloat h, BOOL f) { curved_arrow(w / 2, h / 2, w / 2 - 2, 60, 380); });
        add(@"arrow.uturn.backward", 16, 14, @"undo", ^(CGFloat w, CGFloat h, BOOL f) {
            arc(w * 0.55, h * 0.5, h * 0.35, 90, -90, YES);
            line(w * 0.55, h * 0.85, w * 0.15, h * 0.85);
            arrow(w * 0.55, h * 0.15, w * 0.3, h * 0.15, 0.1);
            POLY(NO, NO, w * 0.32, h - 0.5, w * 0.12, h * 0.85, w * 0.32, h * 0.7);
            line(w * 0.55, h * 0.15, w * 0.35, h * 0.15);
        });
        add(@"arrow.uturn.forward", 16, 14, @"redo", ^(CGFloat w, CGFloat h, BOOL f) {
            arc(w * 0.45, h * 0.5, h * 0.35, 90, 270, NO);
            line(w * 0.45, h * 0.85, w * 0.85, h * 0.85);
            POLY(NO, NO, w * 0.68, h - 0.5, w * 0.88, h * 0.85, w * 0.68, h * 0.7);
            line(w * 0.45, h * 0.15, w * 0.65, h * 0.15);
        });
        alias(@"arrow.uturn.left", @"arrow.uturn.backward"), alias(@"arrow.uturn.right", @"arrow.uturn.forward");
        add(@"rotate.left", 15, 16, @"rotate left", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w * 0.6, h * 0.5, 1.5, NO);
            curved_arrow(w * 0.55, h * 0.55, w * 0.38, 0, 110);
        });
        add(@"rotate.right", 15, 16, @"rotate right", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(w * 0.4 - 1.5, 1.5, w * 0.6, h * 0.5, 1.5, NO);
            curved_arrow(w * 0.45, h * 0.55, w * 0.38, 180, 70);
        });
        void (^tri)(NSString *, int) = ^(NSString *n, int dir) {
            add(n, 12, 12, n, ^(CGFloat w, CGFloat h, BOOL f) { triangle(NSMakeRect(0, 0, w, h), dir, 2); });
        };
        tri(@"arrowtriangle.left", 0), tri(@"arrowtriangle.right", 1), tri(@"arrowtriangle.up", 2), tri(@"arrowtriangle.down", 3);

        /* media */
        add(@"play", 13, 15, @"play", ^(CGFloat w, CGFloat h, BOOL f) { shape(f, ({
                                                                          NSBezierPath *p = [NSBezierPath bezierPath];
                                                                          [p moveToPoint:NSMakePoint(2, 1.5)];
                                                                          [p lineToPoint:NSMakePoint(w - 1.5, h / 2)];
                                                                          [p lineToPoint:NSMakePoint(2, h - 1.5)];
                                                                          [p closePath];
                                                                          p;
                                                                      })); });
        add(@"pause", 12, 15, @"pause", ^(CGFloat w, CGFloat h, BOOL f) {
            shape(f, [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.5, 1.5, w * 0.3, h - 3) xRadius:1 yRadius:1]);
            shape(f, [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(w - 1.5 - w * 0.3, 1.5, w * 0.3, h - 3) xRadius:1 yRadius:1]);
        });
        add(@"stop", 13, 13, @"stop", ^(CGFloat w, CGFloat h, BOOL f) {
            shape(f, [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.5, 1.5, w - 3, h - 3) xRadius:2 yRadius:2]);
        });
        add(@"backward", 18, 12, @"rewind", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, w / 2, 1.5, 1.5, h / 2, w / 2, h - 1.5);
            POLY(YES, f, w - 1.5, 1.5, w / 2, h / 2, w - 1.5, h - 1.5);
        });
        add(@"forward", 18, 12, @"fast forward", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 1.5, 1.5, w / 2, h / 2, 1.5, h - 1.5);
            POLY(YES, f, w / 2, 1.5, w - 1.5, h / 2, w / 2, h - 1.5);
        });
        void (^spk)(NSString *, int) = ^(NSString *n, int levels) {
            add(n, 13 + 4 * levels, 14, @"volume", ^(CGFloat w, CGFloat h, BOOL f) {
                NSBezierPath *p = [NSBezierPath bezierPath];
                [p moveToPoint:NSMakePoint(1.5, h * 0.35)];
                [p lineToPoint:NSMakePoint(4.5, h * 0.35)];
                [p lineToPoint:NSMakePoint(9, 1.5)];
                [p lineToPoint:NSMakePoint(9, h - 1.5)];
                [p lineToPoint:NSMakePoint(4.5, h * 0.65)];
                [p lineToPoint:NSMakePoint(1.5, h * 0.65)];
                [p closePath];
                shape(f, p);
                waves(10, h / 2, levels);
            });
        };
        spk(@"speaker", 0), spk(@"speaker.wave.1", 1), spk(@"speaker.wave.2", 2), spk(@"speaker.wave.3", 3);
        add(@"film", 17, 14, @"film", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, f);
            line(w * 0.28, 1, w * 0.28, h - 1);
            line(w * 0.72, 1, w * 0.72, h - 1);
            line(1.5, h / 2, w * 0.28, h / 2);
            line(w * 0.72, h / 2, w - 1.5, h / 2);
        });
        add(@"camera", 18, 14, @"camera", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h * 0.72, 2.5, f);
            POLY(NO, NO, w * 0.32, h * 0.72 + 1, w * 0.4, h - 1.5, w * 0.6, h - 1.5, w * 0.68, h * 0.72 + 1);
            circle(w / 2, h * 0.38, h * 0.22, NO);
        });
        add(@"camera.filters", 16, 15, @"filters", ^(CGFloat w, CGFloat h, BOOL f) {
            circle(w * 0.5, h * 0.66, w * 0.27, NO);
            circle(w * 0.33, h * 0.36, w * 0.27, NO);
            circle(w * 0.67, h * 0.36, w * 0.27, NO);
        });
        add(@"photo", 18, 14, @"photo", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, f);
            POLY(NO, NO, 2.5, 3, w * 0.38, h * 0.5, w * 0.58, h * 0.3, w * 0.72, h * 0.45, w - 2.5, 3);
            circle(w * 0.7, h * 0.7, 1.5, YES);
        });
        add(@"photo.on.rectangle", 19, 15, @"photos", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 6, h - 5, 2, f);
            POLY(NO, NO, 4.5, h - 3.5, w - 1.5, h - 3.5, w - 1.5, 4);
            POLY(NO, NO, 2.5, 3, w * 0.33, h * 0.42, w * 0.5, h * 0.26, w - 6.5, 3);
        });
        add(@"pip", 18, 14, @"picture in picture", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, NO);
            rrect(w * 0.5, 3, w * 0.38, h * 0.4, 1, YES);
        });
        add(@"aspectratio", 17, 14, @"aspect ratio", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, f);
            POLY(NO, NO, 4.5, h * 0.42, 4.5, h - 4, 8, h - 4);
            POLY(NO, NO, w - 4.5, h * 0.58, w - 4.5, 4, w - 8, 4);
        });

        /* documents and files */
        add(@"doc", 14, 16, @"document", ^(CGFloat w, CGFloat h, BOOL f) {
            shape(f, doc_path(1.5, 1, w - 3, h - 2));
            if (!f)
                POLY(NO, NO, w - 1.5 - (w - 3) * 0.35, h - 1, w - 1.5 - (w - 3) * 0.35, h - 1 - (w - 3) * 0.35, w - 1.5, h - 1 - (w - 3) * 0.35);
        });
        alias(@"document", @"doc");
        add(@"doc.on.doc", 16, 17, @"copy", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, 4.5, h - 1.5, w - 1.5, h - 1.5, w - 1.5, 5);
            shape(f, doc_path(1.5, 1, w - 5, h - 4));
        });
        alias(@"document.on.document", @"doc.on.doc");
        add(@"doc.on.clipboard", 15, 17, @"paste", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 3, 2, f);
            rrect(w * 0.32, h - 3.5, w * 0.36, 3, 1, YES);
        });
        alias(@"document.on.clipboard", @"doc.on.clipboard");
        alias(@"clipboard", @"doc.on.clipboard");
        add(@"folder", 18, 14, @"folder", ^(CGFloat w, CGFloat h, BOOL f) { folder_outline(1.5, 1.5, w - 3, h - 3, f); });
        add(@"tray", 17, 14, @"tray", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, f, 1.5, h * 0.45, 1.5, 1.5, w - 1.5, 1.5, w - 1.5, h * 0.45);
            POLY(NO, NO, 1.5, h * 0.45, w * 0.35, h * 0.45, w * 0.4, h * 0.3, w * 0.6, h * 0.3, w * 0.65, h * 0.45, w - 1.5, h * 0.45);
            POLY(NO, NO, 1.5, h * 0.45, 4, h - 1.5, w - 4, h - 1.5, w - 1.5, h * 0.45);
        });
        add(@"trash", 15, 17, @"trash", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 3, 1.5, w - 3, 1.5, w - 2, h - 4, 2, h - 4);
            line(1, h - 4, w - 1, h - 4);
            POLY(NO, NO, w * 0.35, h - 4, w * 0.35, h - 1.5, w * 0.65, h - 1.5, w * 0.65, h - 4);
        });
        add(@"square.and.arrow.up", 15, 18, @"Share", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, w * 0.3, h * 0.6, 1.5, h * 0.6, 1.5, 1.5, w - 1.5, 1.5, w - 1.5, h * 0.6, w * 0.7, h * 0.6);
            arrow(w / 2, h * 0.3, w / 2, h - 1.5, 4);
        });
        add(@"square.and.arrow.down", 15, 18, @"Save", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, w * 0.3, h * 0.6, 1.5, h * 0.6, 1.5, 1.5, w - 1.5, 1.5, w - 1.5, h * 0.6, w * 0.7, h * 0.6);
            arrow(w / 2, h - 1.5, w / 2, h * 0.3, 4);
        });
        add(@"square.and.arrow.up.on.square", 17, 19, @"Share", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 6, h * 0.55, 2, NO);
            POLY(NO, NO, 4.5, h * 0.55 + 1.5, 4.5, h * 0.65, w - 1.5, h * 0.65, w - 1.5, 4.5, w - 4.5, 4.5);
            arrow(w * 0.42, h * 0.3, w * 0.42, h - 1.5, 3.5);
        });
        add(@"square.and.pencil", 17, 16, @"compose", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, w * 0.55, h - 2.5, 1.5, h - 2.5, 1.5, 1.5, w - 3.5, 1.5, w - 3.5, h * 0.45);
            POLY(YES, f, w * 0.38, h * 0.4, w - 3, h - 1.5, w - 1, h - 3.5, w * 0.48, h * 0.3, w * 0.35, h * 0.27);
        });
        add(@"plus.square.on.square", 17, 17, @"duplicate", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, 4.5, h - 1.5, w - 1.5, h - 1.5, w - 1.5, 4.5);
            rrect(1.5, 1.5, w - 5, h - 5, 2, f);
            plus((w - 2) / 2, (h - 2) / 2, w * 0.18);
        });
        add(@"printer", 17, 16, @"print", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, h * 0.3, w - 3, h * 0.42, 2, f);
            POLY(NO, NO, w * 0.25, h * 0.72, w * 0.25, h - 1.5, w * 0.75, h - 1.5, w * 0.75, h * 0.72);
            POLY(YES, NO, w * 0.25, 1.5, w * 0.75, 1.5, w * 0.75, h * 0.42, w * 0.25, h * 0.42);
        });
        add(@"book", 17, 14, @"book", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, w / 2, 2, w / 2, h - 1.5, 1.5, h - 1, 1.5, 1.5);
            POLY(YES, f, w / 2, 2, w / 2, h - 1.5, w - 1.5, h - 1, w - 1.5, 1.5);
        });
        add(@"bookmark", 11, 15, @"bookmark", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 1.5, h - 1.5, w - 1.5, h - 1.5, w - 1.5, 1.5, w / 2, h * 0.3, 1.5, 1.5);
        });
        add(@"tag", 15, 15, @"tag", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 1.5, h * 0.55, w * 0.45, 1.5, w - 1.5, h * 0.55, w - 1.5, h - 1.5, w * 0.45, h - 1.5);
            circle(w * 0.72, h * 0.75, 1.2, !f);
        });
        add(@"paperclip", 9, 17, @"attachment", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(w * 0.7, h * 0.3)];
            [p lineToPoint:NSMakePoint(w * 0.7, h * 0.75)];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w * 0.5, h * 0.75) radius:w * 0.2 startAngle:0 endAngle:180];
            [p lineToPoint:NSMakePoint(w * 0.3, h * 0.2)];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w * 0.5, h * 0.2) radius:w * 0.2 startAngle:180 endAngle:360];
            [p lineToPoint:NSMakePoint(w * 0.7, h * 0.65)];
            [p stroke];
        });
        add(@"link", 16, 16, @"link", ^(CGFloat w, CGFloat h, BOOL f) {
            NSAffineTransform *t = [NSAffineTransform transform];
            [t translateXBy:w / 2 yBy:h / 2];
            [t rotateByDegrees:45];
            [NSGraphicsContext saveGraphicsState];
            [t concat];
            rrect(-w * 0.45, -2.5, w * 0.5, 5, 2.5, NO);
            rrect(-w * 0.05, -2.5, w * 0.5, 5, 2.5, NO);
            [NSGraphicsContext restoreGraphicsState];
        });
        add(@"signature", 18, 13, @"signature", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(1.5, h * 0.35)];
            [p curveToPoint:NSMakePoint(w * 0.4, h * 0.45) controlPoint1:NSMakePoint(w * 0.15, h) controlPoint2:NSMakePoint(w * 0.3, h * 0.9)];
            [p curveToPoint:NSMakePoint(w - 1.5, h * 0.55) controlPoint1:NSMakePoint(w * 0.5, 0) controlPoint2:NSMakePoint(w * 0.75, h * 0.9)];
            [p stroke];
            line(1.5, 1.5, w - 1.5, 1.5);
        });

        /* tools and controls */
        add(@"gear", 17, 16, @"settings", ^(CGFloat w, CGFloat h, BOOL f) { gear(w / 2, h / 2, h / 2 - 0.5, 8, f); });
        alias(@"gearshape", @"gear");
        add(@"gearshape.2", 19, 17, @"settings", ^(CGFloat w, CGFloat h, BOOL f) {
            gear(w * 0.38, h * 0.4, h * 0.36, 8, f);
            gear(w * 0.75, h * 0.75, h * 0.24, 6, f);
        });
        add(@"magnifyingglass", 16, 15, @"Search", ^(CGFloat w, CGFloat h, BOOL f) { magnifier(w * 0.4, h * 0.6, h * 0.34); });
        add(@"plus.magnifyingglass", 16, 15, @"zoom in", ^(CGFloat w, CGFloat h, BOOL f) {
            magnifier(w * 0.4, h * 0.6, h * 0.34);
            plus(w * 0.4, h * 0.6, h * 0.16);
        });
        add(@"minus.magnifyingglass", 16, 15, @"zoom out", ^(CGFloat w, CGFloat h, BOOL f) {
            magnifier(w * 0.4, h * 0.6, h * 0.34);
            line(w * 0.4 - h * 0.16, h * 0.6, w * 0.4 + h * 0.16, h * 0.6);
        });
        add(@"slider.horizontal.3", 17, 15, @"adjust", ^(CGFloat w, CGFloat h, BOOL f) {
            CGFloat knobs[3] = {0.65, 0.3, 0.55};
            for (int i = 0; i < 3; i++) {
                CGFloat y = 2 + i * (h - 4) / 2;
                line(1.5, y, w - 1.5, y);
                circle(1.5 + knobs[i] * (w - 3), y, 1.8, YES);
            }
        });
        add(@"slider.horizontal.below.rectangle", 17, 16, @"adjust", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, h * 0.42, w - 3, h * 0.55, 2, f);
            line(1.5, 2.5, w - 1.5, 2.5);
            circle(w * 0.6, 2.5, 1.8, YES);
        });
        add(@"list.bullet", 17, 13, @"list", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 3; i++) {
                CGFloat y = 2 + i * (h - 4) / 2;
                circle(2, y, 1.2, YES);
                line(5.5, y, w - 1.5, y);
            }
        });
        add(@"line.3.horizontal", 16, 11, @"menu", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 3; i++)
                line(1.5, 1.5 + i * (h - 3) / 2, w - 1.5, 1.5 + i * (h - 3) / 2);
        });
        add(@"line.3.horizontal.decrease", 16, 11, @"filter", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 3; i++)
                line(1.5 + i * 2.5, h - 1.5 - i * (h - 3) / 2, w - 1.5 - i * 2.5, h - 1.5 - i * (h - 3) / 2);
        });
        add(@"square.grid.2x2", 15, 15, @"grid", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 4; i++)
                rrect(1.5 + (i % 2) * (w / 2), 1.5 + (i / 2) * (h / 2), w / 2 - 3, h / 2 - 3, 1.5, f);
        });
        alias(@"rectangle.grid.2x2", @"square.grid.2x2");
        add(@"sidebar.leading", 18, 14, @"sidebar", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, NO);
            line(w * 0.36, 1, w * 0.36, h - 1);
        });
        alias(@"sidebar.left", @"sidebar.leading");
        add(@"sidebar.trailing", 18, 14, @"sidebar", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1, w - 3, h - 2, 2, NO);
            line(w * 0.64, 1, w * 0.64, h - 1);
        });
        alias(@"sidebar.right", @"sidebar.trailing");
        add(@"pencil", 15, 15, @"edit", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 1.5, 1.5, 2.5, 5, w - 4, h - 1.5, w - 1.5, h - 4, 5, 2.5);
        });
        add(@"scissors", 15, 16, @"cut", ^(CGFloat w, CGFloat h, BOOL f) {
            circle(w * 0.28, 3.5, 2.2, f);
            circle(w * 0.72, 3.5, 2.2, f);
            line(w * 0.38, 5.5, w * 0.75, h - 1.5);
            line(w * 0.62, 5.5, w * 0.25, h - 1.5);
        });
        add(@"lock", 13, 17, @"lock", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h * 0.5, 2, f);
            arc(w / 2, h * 0.52 + 1.5, w / 2 - 3.5, 0, 180, NO);
            line(3.5, h * 0.52, 3.5, h * 0.52 + 1.5);
            line(w - 3.5, h * 0.52, w - 3.5, h * 0.52 + 1.5);
        });
        add(@"lock.open", 16, 17, @"unlock", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w * 0.65, h * 0.5, 2, f);
            arc(w * 0.72, h * 0.62 + 1.5, w * 0.22, 0, 180, NO);
            line(w * 0.5, h * 0.52, w * 0.5, h * 0.62 + 1.5);
        });
        add(@"key", 17, 12, @"key", ^(CGFloat w, CGFloat h, BOOL f) {
            circle(4.5, h / 2, 3, f);
            line(7.5, h / 2, w - 1.5, h / 2);
            line(w - 4, h / 2, w - 4, 2.5);
        });
        add(@"eye", 18, 12, @"show", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(1.5, h / 2)];
            [p curveToPoint:NSMakePoint(w - 1.5, h / 2) controlPoint1:NSMakePoint(w * 0.3, h + 2) controlPoint2:NSMakePoint(w * 0.7, h + 2)];
            [p curveToPoint:NSMakePoint(1.5, h / 2) controlPoint1:NSMakePoint(w * 0.7, -2) controlPoint2:NSMakePoint(w * 0.3, -2)];
            shape(f, p);
            circle(w / 2, h / 2, 2.5, !f);
        });
        add(@"fan", 16, 16, @"fan", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 0; i < 3; i++) {
                NSAffineTransform *t = [NSAffineTransform transform];
                [t translateXBy:w / 2 yBy:h / 2];
                [t rotateByDegrees:i * 120];
                [NSGraphicsContext saveGraphicsState];
                [t concat];
                NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-2, 1, 4, h / 2 - 2)];
                shape(f, p);
                [NSGraphicsContext restoreGraphicsState];
            }
            circle(w / 2, h / 2, 1.2, YES);
        });
        add(@"wind", 17, 13, @"wind", ^(CGFloat w, CGFloat h, BOOL f) {
            arc(w * 0.7, h * 0.75, 2.5, 270, 170, NO);
            line(1.5, h * 0.75 - 2.5, w * 0.7, h * 0.75 - 2.5);
            line(1.5, h * 0.48, w - 1.5, h * 0.48);
            arc(w * 0.62, h * 0.22, 2.5, 90, 190, YES);
            line(1.5, h * 0.22 + 2.5, w * 0.62, h * 0.22 + 2.5);
        });
        add(@"mug", 17, 15, @"mug", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w * 0.68, h - 4, 2, f);
            arc(w * 0.72, h * 0.5, 3, -90, 90, NO);
        });
        add(@"cross", 12, 16, @"cross", ^(CGFloat w, CGFloat h, BOOL f) {
            line(w / 2, 1.5, w / 2, h - 1.5);
            line(1.5, h * 0.66, w - 1.5, h * 0.66);
        });
        add(@"translate", 18, 16, @"translate", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, h * 0.3, w * 0.55, h * 0.65, 2, NO);
            text(@"A", NSMakeRect(1.5, h * 0.3, w * 0.55, h * 0.65), h * 0.5, NSFontWeightSemibold, 0, nil);
            rrect(w * 0.45, 1.5, w * 0.5, h * 0.55, 2, f);
        });

        /* people, places, communication */
        /* head and shoulders, from the bottom of the box */
        void (^bust)(CGFloat, CGFloat, CGFloat, BOOL) = ^(CGFloat cx, CGFloat bottom, CGFloat width, BOOL f) {
            circle(cx, bottom + width * 0.82, width * 0.26, f);
            NSBezierPath *body = stroke_path();
            [body appendBezierPathWithArcWithCenter:NSMakePoint(cx, bottom) radius:width / 2 startAngle:0 endAngle:180];
            [body closePath];
            shape(f, body);
        };
        add(@"person", 14, 15, @"person", ^(CGFloat w, CGFloat h, BOOL f) { bust(w / 2, 1.5, w - 3, f); });
        add(@"person.crop.circle", 15, 15, @"account", ^(CGFloat w, CGFloat h, BOOL f) {
            CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 1, w - 2, h - 2)];
            ring.lineWidth = kStroke;
            CGContextSaveGState(cg);
            [ring addClip];
            if (f) {
                CGContextBeginTransparencyLayer(cg, NULL);
                [ring fill];
                CGContextSetBlendMode(cg, kCGBlendModeClear);
                bust(w / 2, 1, w * 0.6, YES);
                CGContextEndTransparencyLayer(cg);
            } else {
                bust(w / 2, 1, w * 0.6, NO);
            }
            CGContextRestoreGState(cg);
            if (!f)
                [ring stroke];
        });
        add(@"person.2", 19, 14, @"people", ^(CGFloat w, CGFloat h, BOOL f) {
            circle(w * 0.35, h * 0.72, h * 0.2, f);
            arc(w * 0.35, 1.5, w * 0.3, 0, 180, NO);
            circle(w * 0.72, h * 0.68, h * 0.17, f);
            arc(w * 0.75, 3, w * 0.22, 0, 120, NO);
        });
        add(@"house", 17, 15, @"home", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(NO, NO, 1.5, h * 0.5, w / 2, h - 1.5, w - 1.5, h * 0.5);
            POLY(NO, f, 3.5, h * 0.55, 3.5, 1.5, w - 3.5, 1.5, w - 3.5, h * 0.55);
        });
        add(@"globe", 15, 15, @"globe", ^(CGFloat w, CGFloat h, BOOL f) { globe(w / 2, h / 2, w / 2 - 1); });
        add(@"mappin.and.ellipse", 16, 16, @"location", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *e = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1.5, 1, w - 3, 4)];
            e.lineWidth = kStroke;
            [e stroke];
            circle(w / 2, h * 0.7, h * 0.2, f);
            line(w / 2, h * 0.5, w / 2, 3);
        });
        add(@"envelope", 18, 13, @"mail", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h - 3, 2, f);
            POLY(NO, NO, 1.5, h - 2, w / 2, h * 0.4, w - 1.5, h - 2);
        });
        add(@"paperplane", 16, 16, @"send", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, 1.5, h * 0.55, w - 1.5, h - 1.5, w * 0.6, 1.5, w * 0.45, h * 0.42);
        });
        add(@"bubble.left", 16, 15, @"message", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 4, w - 3, h - 5.5, 5, f);
            POLY(YES, f, 3, 5, 2, 1, 7, 4.5);
        });
        alias(@"message", @"bubble.left");
        add(@"exclamationmark.bubble", 16, 15, @"feedback", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 4, w - 3, h - 5.5, 5, f);
            POLY(YES, f, 3, 5, 2, 1, 7, 4.5);
            line(w / 2, h * 0.5, w / 2, h - 4);
            circle(w / 2, 6.5, 0.9, YES);
        });
        add(@"phone", 15, 15, @"phone", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(3, h - 1.5)];
            [p curveToPoint:NSMakePoint(w - 1.5, 3) controlPoint1:NSMakePoint(0, h * 0.4) controlPoint2:NSMakePoint(w * 0.4, 0)];
            [p lineToPoint:NSMakePoint(w - 4, 6)];
            [p lineToPoint:NSMakePoint(6, h - 4)];
            [p closePath];
            shape(f, p);
        });
        add(@"bell", 15, 16, @"notifications", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(1.5, 3.5)];
            [p lineToPoint:NSMakePoint(w - 1.5, 3.5)];
            [p curveToPoint:NSMakePoint(w / 2, h - 1.5) controlPoint1:NSMakePoint(w * 0.75, 6) controlPoint2:NSMakePoint(w * 0.85, h - 1.5)];
            [p curveToPoint:NSMakePoint(1.5, 3.5) controlPoint1:NSMakePoint(w * 0.15, h - 1.5) controlPoint2:NSMakePoint(w * 0.25, 6)];
            shape(f, p);
            line(w * 0.4, 1, w * 0.6, 1);
        });
        add(@"calendar", 16, 15, @"calendar", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h - 3, 2, f);
            line(1.5, h * 0.7, w - 1.5, h * 0.7);
            line(w * 0.3, h - 3, w * 0.3, h - 0.5);
            line(w * 0.7, h - 3, w * 0.7, h - 0.5);
        });
        add(@"clock", 15, 15, @"clock", ^(CGFloat w, CGFloat h, BOOL f) { clock_face(w / 2, h / 2, w / 2 - 1); });
        add(@"calendar.badge.clock", 17, 16, @"schedule", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 3, w - 6, h - 4.5, 2, f);
            line(1.5, h * 0.72, w - 4.5, h * 0.72);
            clock_face(w - 4.5, 4.5, 4);
        });

        /* weather, devices, the rest */
        add(@"sun.max", 17, 17, @"brightness", ^(CGFloat w, CGFloat h, BOOL f) {
            circle(w / 2, h / 2, w * 0.2, f);
            for (int i = 0; i < 8; i++) {
                CGFloat a = i * M_PI / 4;
                line(w / 2 + w * 0.32 * cos(a), h / 2 + h * 0.32 * sin(a), w / 2 + w * 0.44 * cos(a), h / 2 + h * 0.44 * sin(a));
            }
        });
        add(@"moon", 14, 15, @"night", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w / 2, h / 2) radius:w / 2 - 1 startAngle:60 endAngle:290];
            [p curveToPoint:NSMakePoint(w / 2 + (w / 2 - 1) * 0.5, h / 2 + (w / 2 - 1) * 0.86)
              controlPoint1:NSMakePoint(w * 0.35, h * 0.3) controlPoint2:NSMakePoint(w * 0.35, h * 0.75)];
            shape(f, p);
        });
        add(@"bolt", 11, 16, @"power", ^(CGFloat w, CGFloat h, BOOL f) {
            POLY(YES, f, w * 0.62, h - 1.5, 1.5, h * 0.42, w * 0.48, h * 0.42, w * 0.38, 1.5, w - 1.5, h * 0.58, w * 0.52, h * 0.58);
        });
        add(@"cloud", 18, 13, @"cloud", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(4, 1.5)];
            [p lineToPoint:NSMakePoint(w - 4, 1.5)];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w - 4, 4.5) radius:3 startAngle:-90 endAngle:90];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w * 0.55, h * 0.6) radius:h * 0.32 startAngle:20 endAngle:170];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(4.5, 4.5) radius:3 startAngle:90 endAngle:270];
            [p closePath];
            shape(f, p);
        });
        alias(@"icloud", @"cloud");
        add(@"icloud.and.arrow.down", 18, 15, @"download", ^(CGFloat w, CGFloat h, BOOL f) {
            NSBezierPath *p = stroke_path();
            [p moveToPoint:NSMakePoint(5, 4)];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(4.5, 7) radius:3 startAngle:270 endAngle:90 clockwise:YES];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w * 0.55, h * 0.68) radius:h * 0.28 startAngle:170 endAngle:20 clockwise:YES];
            [p appendBezierPathWithArcWithCenter:NSMakePoint(w - 4, 7) radius:3 startAngle:90 endAngle:-90 clockwise:YES];
            [p stroke];
            arrow(w / 2, h * 0.55, w / 2, 1.5, 3.5);
        });
        add(@"wifi", 17, 13, @"Wi-Fi", ^(CGFloat w, CGFloat h, BOOL f) {
            for (int i = 1; i <= 3; i++)
                arc(w / 2, 2, i * (h - 3) / 3, 45, 135, NO);
            circle(w / 2, 2, 1.3, YES);
        });
        add(@"mic", 11, 16, @"microphone", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(w / 2 - 2.5, h * 0.38, 5, h * 0.6, 2.5, f);
            arc(w / 2, h * 0.55, w / 2 - 1, 200, 340, NO);
            line(w / 2, h * 0.2, w / 2, 1);
        });
        add(@"video", 19, 12, @"video", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w * 0.65, h - 3, 2, f);
            POLY(YES, f, w * 0.65 + 2, h * 0.4, w - 1.5, 2, w - 1.5, h - 2, w * 0.65 + 2, h * 0.6);
        });
        add(@"keyboard", 19, 13, @"keyboard", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h - 3, 2, f);
            line(w * 0.3, 4, w * 0.7, 4);
            for (int i = 0; i < 4; i++)
                circle(4.5 + i * (w - 9) / 3, h * 0.62, 0.8, YES);
        });
        add(@"display", 18, 15, @"display", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, h * 0.28, w - 3, h * 0.7, 2, f);
            line(w * 0.35, 1, w * 0.65, 1);
            line(w / 2, 1, w / 2, h * 0.28);
        });
        add(@"textformat.size.smaller", 15, 13, @"smaller text", ^(CGFloat w, CGFloat h, BOOL f) {
            text(@"A", NSMakeRect(0, 0, w * 0.55, h), h * 0.75, NSFontWeightMedium, 0, nil);
            text(@"A", NSMakeRect(w * 0.5, 0, w * 0.5, h * 0.8), h * 0.5, NSFontWeightMedium, 0, nil);
        });
        add(@"textformat.size.larger", 15, 13, @"larger text", ^(CGFloat w, CGFloat h, BOOL f) {
            text(@"A", NSMakeRect(0, 0, w * 0.5, h * 0.8), h * 0.5, NSFontWeightMedium, 0, nil);
            text(@"A", NSMakeRect(w * 0.45, 0, w * 0.55, h), h * 0.75, NSFontWeightMedium, 0, nil);
        });
        add(@"character.textbox", 16, 16, @"text box", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h - 3, 3, f);
            text(@"A", NSMakeRect(1.5, 1.5, w - 3, h - 3), h * 0.55, NSFontWeightMedium, 0, nil);
        });
        add(@"hand.thumbsup", 15, 15, @"like", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, 3, h * 0.55, 1, f);
            POLY(YES, f, 6, 1.5, w - 2.5, 1.5, w - 1.5, h * 0.55, w * 0.62, h * 0.6, w * 0.62, h - 1.5, w * 0.5, h - 1.5, 6, h * 0.55);
        });
        add(@"hand.thumbsdown", 15, 15, @"dislike", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, h * 0.45 - 1.5, 3, h * 0.55, 1, f);
            POLY(YES, f, 6, h - 1.5, w - 2.5, h - 1.5, w - 1.5, h * 0.45, w * 0.62, h * 0.4, w * 0.62, 1.5, w * 0.5, 1.5, 6, h * 0.45);
        });
        add(@"filemenu.and.selection", 17, 15, @"menu", ^(CGFloat w, CGFloat h, BOOL f) {
            rrect(1.5, 1.5, w - 3, h - 3, 2, NO);
            line(1.5, h - 4.5, w - 1.5, h - 4.5);
            rrect(3.5, h * 0.35, w - 7, 3.5, 1, YES);
        });
    });
    return t;
}

/* A name read as a base glyph and its modifiers. */
typedef struct {
    SymbolGlyph *glyph;
    BOOL fill, slash;
    int enclosure; /* 0 none, 1 circle, 2 square */
    int badge;     /* 0 none, 1 plus, 2 minus, 3 checkmark */
} ParsedSymbol;

static BOOL
parse_symbol(NSString *name, ParsedSymbol *out)
{
    memset(out, 0, sizeof *out);
    NSDictionary *glyphs = symbol_glyphs();
    NSMutableArray *parts = [[[name componentsSeparatedByString:@"."] mutableCopy] autorelease];
    for (;;) {
        NSString *joined = [parts componentsJoinedByString:@"."];
        SymbolGlyph *g = [glyphs[joined] pointerValue];
        if (g) {
            out->glyph = g;
            return YES;
        }
        if (parts.count < 2)
            return NO;
        NSString *last = parts.lastObject, *before = parts[parts.count - 2];
        if ([last isEqual:@"fill"] && !out->fill && !out->enclosure)
            out->fill = YES;
        else if (([last isEqual:@"circle"] || [last isEqual:@"square"]) && !out->enclosure)
            out->enclosure = [last isEqual:@"circle"] ? 1 : 2;
        else if ([last isEqual:@"slash"] && !out->slash)
            out->slash = YES;
        else if ([before isEqual:@"badge"] && !out->badge &&
                 ([last isEqual:@"plus"] || [last isEqual:@"minus"] || [last isEqual:@"checkmark"])) {
            out->badge = [last isEqual:@"plus"] ? 1 : [last isEqual:@"minus"] ? 2 : 3;
            [parts removeLastObject];
        } else
            return NO;
        [parts removeLastObject];
    }
}

/* The stroke for a weight, at 13 points. */
static CGFloat
weight_stroke(NSFontWeight weight)
{
    if (weight <= NSFontWeightUltraLight)
        return 0.6;
    if (weight <= NSFontWeightThin)
        return 0.85;
    if (weight <= NSFontWeightLight)
        return 1.15;
    if (weight <= NSFontWeightRegular)
        return 1.45;
    if (weight <= NSFontWeightMedium)
        return 1.65;
    if (weight <= NSFontWeightSemibold)
        return 1.9;
    if (weight <= NSFontWeightBold)
        return 2.15;
    if (weight <= NSFontWeightHeavy)
        return 2.5;
    return 2.85;
}

@interface NSImageSymbolConfiguration (FinchSymbols)
- (void)_finchPointSize:(CGFloat *)pointSize weight:(NSFontWeight *)weight hasWeight:(BOOL *)hasWeight scale:(NSImageSymbolScale *)scale;
@end

static char symbol_name_key, symbol_config_key;

/* The symbol image for a name and configuration, or nil for a name with no glyph. */
static NSImage *
symbol_image(NSString *name, NSImageSymbolConfiguration *config, NSString *description)
{
    ParsedSymbol ps;
    if (![name isKindOfClass:[NSString class]] || !parse_symbol(name, &ps))
        return nil;
    CGFloat pointSize = 0;
    NSFontWeight weight = NSFontWeightRegular;
    BOOL hasWeight = NO;
    NSImageSymbolScale scale = (NSImageSymbolScale)0;
    if (config)
        [config _finchPointSize:&pointSize weight:&weight hasWeight:&hasWeight scale:&scale];
    if (pointSize <= 0)
        pointSize = 13;
    /* (Apple's grow a little less than the point size: about 1.148 pt + 1.07) */
    CGFloat k = (1.148 * pointSize + 1.07) / (1.148 * 13 + 1.07) *
                (scale == NSImageSymbolScaleSmall ? 0.82 : scale == NSImageSymbolScaleLarge ? 1.29 : 1);
    SymbolGlyph *g = ps.glyph;
    CGFloat gw = g->w, gh = g->h;
    if (ps.enclosure)
        gw = gh = MAX(15, MAX(g->w, g->h) + 3);
    NSSize size = NSMakeSize(round(gw * k), round(gh * k));
    CGFloat stroke = weight_stroke(hasWeight ? weight : NSFontWeightRegular);
    ParsedSymbol p = ps;
    NSImage *im = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        CGFloat saved = kStroke;
        kStroke = stroke;
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:dst.origin.x yBy:dst.origin.y];
        [t scaleXBy:dst.size.width / gw yBy:dst.size.height / gh];
        [t concat];
        [[NSColor blackColor] set];
        CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
        if (p.enclosure) {
            NSBezierPath *outline = p.enclosure == 1 ? [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 1, gw - 2, gh - 2)]
                                                     : [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1, gw - 2, gh - 2)
                                                                                      xRadius:3.5
                                                                                      yRadius:3.5];
            outline.lineWidth = kStroke;
            if (p.fill) {
                CGContextBeginTransparencyLayer(cg, NULL);
                [outline fill];
                CGContextSetBlendMode(cg, kCGBlendModeClear);
            } else {
                [outline stroke];
            }
            /* the glyph at 55%, centred */
            CGFloat s = 0.55 * MIN(gw / g->w, gh / g->h);
            NSAffineTransform *in = [NSAffineTransform transform];
            [in translateXBy:(gw - g->w * s) / 2 yBy:(gh - g->h * s) / 2];
            [in scaleBy:s];
            [NSGraphicsContext saveGraphicsState];
            [in concat];
            kStroke = stroke / s * 0.9;
            g->draw(g->w, g->h, NO);
            [NSGraphicsContext restoreGraphicsState];
            kStroke = stroke;
            if (p.fill)
                CGContextEndTransparencyLayer(cg);
        } else {
            g->draw(g->w, g->h, p.fill);
        }
        if (p.slash) {
            /* a stroke corner to corner, with a gap cut beside it */
            CGContextSaveGState(cg);
            CGContextSetBlendMode(cg, kCGBlendModeClear);
            line(1, gh, gw, 1);
            CGContextRestoreGState(cg);
            line(1.5, gh - 0.5, gw - 0.5, 1.5);
        }
        if (p.badge) {
            CGFloat r = MIN(gw, gh) * 0.24, cx = gw - r, cy = r;
            CGContextSaveGState(cg);
            CGContextSetBlendMode(cg, kCGBlendModeClear);
            circle(cx, cy, r + 1, YES);
            CGContextRestoreGState(cg);
            circle(cx, cy, r, YES);
            CGContextSaveGState(cg);
            CGContextSetBlendMode(cg, kCGBlendModeClear);
            kStroke = stroke * 0.8;
            if (p.badge == 1)
                plus(cx, cy, r * 0.55);
            else if (p.badge == 2)
                line(cx - r * 0.55, cy, cx + r * 0.55, cy);
            else
                POLY(NO, NO, cx - r * 0.5, cy, cx - r * 0.1, cy - r * 0.45, cx + r * 0.55, cy + r * 0.45);
            CGContextRestoreGState(cg);
        }
        [NSGraphicsContext restoreGraphicsState];
        kStroke = saved;
        return YES;
    }];
    im.template = YES;
    im.accessibilityDescription = description ?: g->label;
    objc_setAssociatedObject(im, &symbol_name_key, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(im, &symbol_config_key, config ?: [NSImageSymbolConfiguration configurationWithScale:NSImageSymbolScaleMedium],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return im;
}

__attribute__((visibility("hidden"))) NSImage *
FinchSymbolImage(NSString *name, NSImageSymbolConfiguration *config, NSString *description)
{
    return symbol_image(name, config, description);
}

/* For -imageWithSymbolConfiguration: and -symbolConfiguration (NSImage.m): the name a
   symbol image was made with, and its configuration. */
__attribute__((visibility("hidden"))) NSString *
FinchSymbolImageName(NSImage *image)
{
    return objc_getAssociatedObject(image, &symbol_name_key);
}

__attribute__((visibility("hidden"))) NSImageSymbolConfiguration *
FinchSymbolImageConfiguration(NSImage *image)
{
    return objc_getAssociatedObject(image, &symbol_config_key);
}

/* Every base glyph's name, for tests. */
__attribute__((visibility("hidden"))) NSArray<NSString *> *
FinchSymbolNames(void)
{
    return [symbol_glyphs().allKeys sortedArrayUsingSelector:@selector(compare:)];
}

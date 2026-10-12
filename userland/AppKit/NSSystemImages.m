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

typedef void (^Drawer)(NSRect r);

/* MARK: Drawing helpers (points, origin at the bottom left) */

static const CGFloat kStroke = 1.5;

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

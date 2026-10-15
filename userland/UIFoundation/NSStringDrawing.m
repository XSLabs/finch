/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * String drawing and measuring (NSStringDrawing.h): NSString and
 * NSAttributedString, laid out as Apple's text system lays out a string in
 * a text container, and drawn with CoreText into the current
 * NSGraphicsContext's CGContext.
 *
 * The layout itself is UIFTextLayout.m's.
 */
#import "UIFTextLayout.h"

UIF_HIDDEN void UIFStringDrawingContextSetResult(NSStringDrawingContext *c, CGFloat scale, CGRect bounds, CGFloat firstBaseline,
                                                 CGFloat lastBaselineFromBottom, NSInteger lines, BOOL truncated);
UIF_HIDDEN NSUInteger UIFStringDrawingContextMaximumLines(NSStringDrawingContext *c);

/* A layout's results, for the drawing context. */
static void
set_result(NSStringDrawingContext *context, UIFLayout *L, CGRect used, CGFloat scale)
{
    if (!context)
        return;
    CGFloat first = 0, last = 0;
    if (L->count) {
        first = L->lines[0].top + L->lines[0].baseline;
        UIFLine *ln = &L->lines[L->count - 1];
        last = used.size.height - (ln->top + ln->baseline);
    }
    UIFStringDrawingContextSetResult(context, scale, used, first, last, (NSInteger)L->count, L->truncated);
}

#pragma mark - Shrinking to fit

/* The string with every font scaled. */
static NSAttributedString *
scaled(NSAttributedString *s, CGFloat factor)
{
    NSMutableAttributedString *out = [[s mutableCopy] autorelease];
    [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0
                       usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                           CTFontRef f = (CTFontRef)UIFFontIn(attrs);
                           CTFontRef g = CTFontCreateCopyWithAttributes(f, CTFontGetSize(f) * factor, NULL, NULL);
                           if (g) {
                               [out addAttribute:NSFontAttributeName value:(id)g range:range];
                               CFRelease(g);
                           }
                       }];
    return out;
}

static NSDictionary *
scaled_typing(NSDictionary *typing, CGFloat factor)
{
    CTFontRef f = (CTFontRef)UIFFontIn(typing);
    CTFontRef g = CTFontCreateCopyWithAttributes(f, CTFontGetSize(f) * factor, NULL, NULL);
    if (!g)
        return typing;
    NSMutableDictionary *out = [[typing mutableCopy] autorelease];
    out[NSFontAttributeName] = (id)g;
    CFRelease(g);
    return out;
}

/* All of it laid out, untruncated, within the width (0: unbounded) */
static BOOL
fits(UIFLayout *L, NSAttributedString *s, CGFloat width)
{
    if (L->truncated || L->end < s.length)
        return NO;
    /* each line's text measured whole: the layout keeps a line within the container,
       truncating it (to an ellipsis) without saying so */
    if (width <= 0)
        return YES;
    for (size_t i = 0; i < L->count; i++) {
        NSRange r = NSIntersectionRange(L->lines[i].range, NSMakeRange(0, s.length));
        while (r.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
                               characterIsMember:[s.string characterAtIndex:NSMaxRange(r) - 1]])
            r.length--;
        if (!r.length)
            continue;
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)[s attributedSubstringFromRange:r]);
        CGFloat w = line ? CTLineGetTypographicBounds(line, NULL, NULL, NULL) : 0;
        if (line)
            CFRelease(line);
        if (L->lines[i].x + w > width + 0.01)
            return NO;
    }
    return YES;
}

/*
 * Lay a string out. With a drawing context's minimumScaleFactor (above 0, below 1), an
 * attributed string that doesn't fit is laid out with its fonts scaled down by the least that
 * fits, to a hundredth, down to the minimum; that is the context's actualScaleFactor.
 * Apple's (macOS 26) scale by the minimum even when less would do, and report the lines'
 * unscaled heights; its SwiftUI works out how much the text needs. Finch's SwiftUI
 * (OpenSwiftUI) leaves that to string drawing and sizes the text by what it reports, so here
 * a string is scaled no more than it needs, and measured as drawn. NSString's methods don't
 * scale, as Apple's don't.
 */
static UIFLayout
layout_scaled(NSAttributedString **s, NSDictionary **typing, UIFLayoutParams p, CGFloat width,
              NSStringDrawingContext *context, BOOL scales, CGFloat *scale)
{
    *scale = 1;
    UIFLayout L = UIFLayoutString(*s, *typing, p);
    CGFloat minimum = scales && context ? context.minimumScaleFactor : 0;
    if (minimum <= 0 || minimum >= 1 || !(*s).length || fits(&L, *s, width))
        return L;
    CGFloat lo = minimum, hi = 1;
    NSAttributedString *best = nil;
    for (int i = 0; i < 7 && hi - lo > 0.005; i++) {
        CGFloat mid = (lo + hi) / 2;
        NSAttributedString *t = scaled(*s, mid);
        UIFLayout M = UIFLayoutString(t, scaled_typing(*typing, mid), p);
        BOOL ok = fits(&M, t, width);
        UIFLayoutFree(&M);
        if (ok) {
            lo = mid;
            best = t;
        } else {
            hi = mid;
        }
    }
    CGFloat use = best ? lo : minimum;
    UIFLayoutFree(&L);
    *s = best ?: scaled(*s, use);
    *typing = scaled_typing(*typing, use);
    *scale = use;
    return UIFLayoutString(*s, *typing, p);
}

#pragma mark - The API

static NSAttributedString *
attributed(NSString *s, NSDictionary *attrs)
{
    return [[[NSAttributedString alloc] initWithString:s ? s : @"" attributes:attrs] autorelease];
}

static NSDictionary *
typing_attributes(NSAttributedString *s)
{
    return s.length ? [s attributesAtIndex:s.length - 1 effectiveRange:NULL] : @{};
}

static CGRect
bounding_rect(NSAttributedString *s, NSDictionary *typing, CGSize size, NSStringDrawingOptions options,
              NSStringDrawingContext *context, BOOL scales)
{
    UIFLayoutParams p = {size.width, size.height, options, 0, NO, NO, UIFStringDrawingContextMaximumLines(context), NO};
    CGFloat scale;
    UIFLayout L = layout_scaled(&s, &typing, p, size.width, context, scales, &scale);
    CGRect r = UIFLayoutUsedRect(&L, p);
    set_result(context, &L, r, scale);
    UIFLayoutFree(&L);
    return r;
}

static void
draw_in_rect(NSAttributedString *s, NSDictionary *typing, CGRect rect, NSStringDrawingOptions options,
             NSStringDrawingContext *context, BOOL clip, BOOL scales)
{
    BOOL flipped = UIFCurrentContextIsFlipped();
    BOOL multi = (options & NSStringDrawingUsesLineFragmentOrigin) != 0;
    UIFLayoutParams p = {multi ? rect.size.width : 0, multi ? rect.size.height : 0, options, 0, NO, NO,
                         UIFStringDrawingContextMaximumLines(context), NO};
    CGFloat scale;
    UIFLayout L = layout_scaled(&s, &typing, p, rect.size.width, context, scales, &scale);
    CGRect used = UIFLayoutUsedRect(&L, p);
    if (multi) {
        CGFloat top = flipped ? CGRectGetMinY(rect) : CGRectGetMaxY(rect);
        CGContextRef cg = clip ? UIFCurrentCGContext() : NULL;
        if (cg) {
            CGContextSaveGState(cg);
            CGContextClipToRect(cg, rect);
        }
        UIFLayoutDraw(&L, rect.origin.x, top, flipped);
        if (cg)
            CGContextRestoreGState(cg);
    } else if (L.count) {
        /* The rectangle's origin is the first line's baseline. */
        UIFLine *ln = &L.lines[0];
        CGFloat top = flipped ? rect.origin.y - ln->baseline : rect.origin.y + ln->baseline;
        UIFLayoutDraw(&L, rect.origin.x - ln->x, top, flipped);
    }
    set_result(context, &L, used, scale);
    UIFLayoutFree(&L);
}

static void
draw_at_point(NSAttributedString *s, NSDictionary *typing, CGPoint point)
{
    BOOL flipped = UIFCurrentContextIsFlipped();
    UIFLayoutParams p = {0, 0, NSStringDrawingUsesLineFragmentOrigin, 0, NO, NO, 0, NO};
    UIFLayout L = UIFLayoutString(s, typing, p);
    /* The point is the top-left of the text in a flipped context, its bottom-left otherwise. */
    CGFloat top = flipped ? point.y : point.y + L.height;
    UIFLayoutDraw(&L, point.x, top, flipped);
    UIFLayoutFree(&L);
}

@implementation NSString (NSStringDrawing)

- (CGSize)sizeWithAttributes:(NSDictionary *)attrs
{
    return [self boundingRectWithSize:CGSizeZero options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs context:nil]
        .size;
}

- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attrs
{
    draw_at_point(attributed(self, attrs), attrs ? attrs : @{}, point);
}

- (void)drawInRect:(CGRect)rect withAttributes:(NSDictionary *)attrs
{
    draw_in_rect(attributed(self, attrs), attrs ? attrs : @{}, rect, NSStringDrawingUsesLineFragmentOrigin, nil, YES, NO);
}

- (void)drawWithRect:(CGRect)rect
             options:(NSStringDrawingOptions)options
          attributes:(NSDictionary *)attributes
             context:(NSStringDrawingContext *)context
{
    draw_in_rect(attributed(self, attributes), attributes ? attributes : @{}, rect, options, context, NO, NO);
}

- (CGRect)boundingRectWithSize:(CGSize)size
                       options:(NSStringDrawingOptions)options
                    attributes:(NSDictionary *)attributes
                       context:(NSStringDrawingContext *)context
{
    return bounding_rect(attributed(self, attributes), attributes ? attributes : @{}, size, options, context, NO);
}

- (void)drawWithRect:(NSRect)rect options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes
{
    [self drawWithRect:rect options:options attributes:attributes context:nil];
}

- (NSRect)boundingRectWithSize:(NSSize)size options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes
{
    return [self boundingRectWithSize:size options:options attributes:attributes context:nil];
}

@end

@implementation NSAttributedString (NSStringDrawing)

- (CGSize)size
{
    return [self boundingRectWithSize:CGSizeZero options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
}

- (void)drawAtPoint:(CGPoint)point
{
    draw_at_point(self, typing_attributes(self), point);
}

- (void)drawInRect:(CGRect)rect
{
    draw_in_rect(self, typing_attributes(self), rect, NSStringDrawingUsesLineFragmentOrigin, nil, YES, YES);
}

- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context
{
    draw_in_rect(self, typing_attributes(self), rect, options, context, NO, YES);
}

- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context
{
    return bounding_rect(self, typing_attributes(self), size, options, context, YES);
}

- (void)drawWithRect:(NSRect)rect options:(NSStringDrawingOptions)options
{
    [self drawWithRect:rect options:options context:nil];
}

- (NSRect)boundingRectWithSize:(NSSize)size options:(NSStringDrawingOptions)options
{
    return [self boundingRectWithSize:size options:options context:nil];
}

@end

/* Apple's private string-drawing class settings that apps still call. */
@implementation NSString (FinchDrawingSettings)
+ (CGFloat)defaultLineHeightForFont:(NSFont *)font
{
    NSLayoutManager *lm = [[[NSLayoutManager alloc] init] autorelease];
    return [lm defaultLineHeightForFont:font];
}
+ (BOOL)usesScreenFonts { return NO; }
+ (void)setUsesScreenFonts:(BOOL)f {}
+ (float)hyphenationFactor { return 0; }
+ (void)setDefaultAttachmentScaling:(NSUInteger)s {}
@end

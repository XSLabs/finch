/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The rest of NSLayoutManager's API, and NSGlyphGenerator and NSTextStorage's
 * scripting collections.
 *
 * Finch's layout manager lays text out itself, a glyph for each character
 * (UIFoundation/NSLayoutManager.m). The methods a custom typesetter or glyph
 * generator calls to feed layout in (setting glyphs, locations, line fragments and
 * containers) are accepted and kept: what they set is what the matching getters
 * (intAttribute:forGlyphAtIndex:, glyphs, attachment sizes) answer, but the layout
 * drawn is Finch's own. Underlines, strikethroughs, attachment cells and packed
 * glyphs draw as Apple's do.
 */
#import "NSView_Finch.h"
#import <CoreText/CoreText.h>

@implementation NSLayoutManager (FinchGlyphStorage)

static char overrides_key;

/* What's been set for glyphs: "glyph", "char", "attr<n>", "notShown", "outside", by index. */
- (NSMutableDictionary *)_finchGlyphOverrides
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &overrides_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &overrides_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    return d;
}

static void
set_override(NSLayoutManager *lm, NSString *what, NSUInteger index, id value)
{
    NSMutableDictionary *all = [lm _finchGlyphOverrides];
    NSMutableDictionary *byIndex = all[what];
    if (!byIndex)
        all[what] = byIndex = [NSMutableDictionary dictionary];
    byIndex[@(index)] = value;
}

- (void)insertGlyph:(NSGlyph)glyph atGlyphIndex:(NSUInteger)glyphIndex characterIndex:(NSUInteger)charIndex
{
    set_override(self, @"glyph", glyphIndex, @(glyph));
    set_override(self, @"char", glyphIndex, @(charIndex));
}

- (void)insertGlyphs:(const NSGlyph *)glyphs length:(NSUInteger)length forStartingGlyphAtIndex:(NSUInteger)glyphIndex
      characterIndex:(NSUInteger)charIndex
{
    for (NSUInteger i = 0; i < length; i++)
        [self insertGlyph:glyphs[i] atGlyphIndex:glyphIndex + i characterIndex:charIndex + i];
}

- (void)replaceGlyphAtIndex:(NSUInteger)glyphIndex withGlyph:(NSGlyph)newGlyph { set_override(self, @"glyph", glyphIndex, @(newGlyph)); }

- (void)deleteGlyphsInRange:(NSRange)glyphRange
{
    for (NSString *what in [self _finchGlyphOverrides])
        for (NSUInteger i = glyphRange.location; i < NSMaxRange(glyphRange); i++)
            [[self _finchGlyphOverrides][what] removeObjectForKey:@(i)];
}

- (void)setCharacterIndex:(NSUInteger)charIndex forGlyphAtIndex:(NSUInteger)glyphIndex { set_override(self, @"char", glyphIndex, @(charIndex)); }

- (void)setGlyphs:(const CGGlyph *)glyphs properties:(const NSGlyphProperty *)props characterIndexes:(const NSUInteger *)charIndexes
             font:(NSFont *)aFont forGlyphRange:(NSRange)glyphRange
{
    for (NSUInteger i = 0; i < glyphRange.length; i++) {
        set_override(self, @"glyph", glyphRange.location + i, @(glyphs[i]));
        if (charIndexes)
            set_override(self, @"char", glyphRange.location + i, @(charIndexes[i]));
    }
}

- (void)setIntAttribute:(NSInteger)attributeTag value:(NSInteger)val forGlyphAtIndex:(NSUInteger)glyphIndex
{
    set_override(self, [NSString stringWithFormat:@"attr%ld", (long)attributeTag], glyphIndex, @(val));
}

- (NSInteger)intAttribute:(NSInteger)attributeTag forGlyphAtIndex:(NSUInteger)glyphIndex
{
    return [[self _finchGlyphOverrides][[NSString stringWithFormat:@"attr%ld", (long)attributeTag]][@(glyphIndex)] integerValue];
}

- (void)setNotShownAttribute:(BOOL)flag forGlyphAtIndex:(NSUInteger)glyphIndex { set_override(self, @"notShown", glyphIndex, @(flag)); }
- (void)setDrawsOutsideLineFragment:(BOOL)flag forGlyphAtIndex:(NSUInteger)glyphIndex { set_override(self, @"outside", glyphIndex, @(flag)); }

/* (layout results a typesetter would hand over; Finch lays out itself) */
- (void)setTextContainer:(NSTextContainer *)container forGlyphRange:(NSRange)glyphRange {}
- (void)setLineFragmentRect:(NSRect)fragmentRect forGlyphRange:(NSRange)glyphRange usedRect:(NSRect)usedRect {}
- (void)setExtraLineFragmentRect:(NSRect)fragmentRect usedRect:(NSRect)usedRect textContainer:(NSTextContainer *)container {}
- (void)setLocation:(NSPoint)location forStartOfGlyphRange:(NSRange)glyphRange {}
- (void)setLocations:(NSPointArray)locations startingGlyphIndexes:(NSUInteger *)glyphIndexes count:(NSUInteger)count
       forGlyphRange:(NSRange)glyphRange
{
}

- (void)setAttachmentSize:(NSSize)attachmentSize forGlyphRange:(NSRange)glyphRange
{
    for (NSUInteger i = glyphRange.location; i < NSMaxRange(glyphRange); i++)
        set_override(self, @"attachment", i, [NSValue valueWithSize:attachmentSize]);
}

/* Glyphs with their character indexes; no inscriptions, elastic bits or bidi levels. */
- (NSUInteger)getGlyphsInRange:(NSRange)glyphRange glyphs:(NSGlyph *)glyphBuffer characterIndexes:(NSUInteger *)charIndexBuffer
             glyphInscriptions:(NSGlyphInscription *)inscribeBuffer elasticBits:(BOOL *)elasticBuffer bidiLevels:(unsigned char *)bidiLevelBuffer
{
    NSUInteger n = 0;
    for (NSUInteger i = glyphRange.location; i < NSMaxRange(glyphRange); i++, n++) {
        BOOL valid = NO;
        NSGlyph g = [self glyphAtIndex:i isValidIndex:&valid];
        if (!valid)
            break;
        if (glyphBuffer)
            glyphBuffer[n] = g;
        if (charIndexBuffer)
            charIndexBuffer[n] = [self characterIndexForGlyphAtIndex:i];
        if (inscribeBuffer)
            inscribeBuffer[n] = NSGlyphInscribeBase;
        if (elasticBuffer)
            elasticBuffer[n] = NO;
        if (bidiLevelBuffer)
            bidiLevelBuffer[n] = 0;
    }
    return n;
}

- (NSUInteger)getGlyphsInRange:(NSRange)glyphRange glyphs:(NSGlyph *)glyphBuffer characterIndexes:(NSUInteger *)charIndexBuffer
             glyphInscriptions:(NSGlyphInscription *)inscribeBuffer elasticBits:(BOOL *)elasticBuffer
{
    return [self getGlyphsInRange:glyphRange glyphs:glyphBuffer characterIndexes:charIndexBuffer glyphInscriptions:inscribeBuffer
                      elasticBits:elasticBuffer bidiLevels:NULL];
}

static char generator_key;
/* (each layout manager has its own, as Apple's, until given one) */
- (NSGlyphGenerator *)glyphGenerator
{
    NSGlyphGenerator *g = objc_getAssociatedObject(self, &generator_key);
    if (!g) {
        g = [[[NSGlyphGenerator alloc] init] autorelease];
        objc_setAssociatedObject(self, &generator_key, g, OBJC_ASSOCIATION_RETAIN);
    }
    return g;
}
- (void)setGlyphGenerator:(NSGlyphGenerator *)glyphGenerator
{
    objc_setAssociatedObject(self, &generator_key, glyphGenerator, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark Drawing

/* The horizontal extent of glyphs on their line, in container coordinates. */
static NSRect
glyph_span(NSLayoutManager *lm, NSRange glyphRange, NSRect lineRect)
{
    NSTextContainer *tc = [lm textContainerForGlyphAtIndex:glyphRange.location effectiveRange:NULL];
    NSRect r = tc ? [lm boundingRectForGlyphRange:glyphRange inTextContainer:tc] : lineRect;
    return NSMakeRect(NSMinX(r), NSMinY(lineRect), NSWidth(r), NSHeight(lineRect));
}

static void
draw_line(NSLayoutManager *lm, NSRange glyphRange, NSInteger style, CGFloat y, NSRect lineRect, NSPoint origin, NSString *colorKey)
{
    NSRect span = glyph_span(lm, glyphRange, lineRect);
    NSUInteger ch = [lm characterIndexForGlyphAtIndex:glyphRange.location];
    NSTextStorage *ts = [lm textStorage];
    NSDictionary *a = ch < [ts length] ? [ts attributesAtIndex:ch effectiveRange:NULL] : @{};
    NSColor *c = a[colorKey] ?: a[NSForegroundColorAttributeName] ?: [NSColor textColor];
    NSFont *f = a[NSFontAttributeName] ?: [NSFont systemFontOfSize:12];
    CGFloat thick = MAX(1, [f underlineThickness]) * ((style & 0xff) == NSUnderlineStyleThick ? 2 : 1);
    [c setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p setLineWidth:thick];
    if (style & NSUnderlinePatternDot) {
        CGFloat dash[] = {thick, thick};
        [p setLineDash:dash count:2 phase:0];
    } else if (style & NSUnderlinePatternDash) {
        CGFloat dash[] = {thick * 4, thick * 2};
        [p setLineDash:dash count:2 phase:0];
    }
    CGFloat lineY = origin.y + y;
    [p moveToPoint:NSMakePoint(origin.x + NSMinX(span), lineY)];
    [p lineToPoint:NSMakePoint(origin.x + NSMaxX(span), lineY)];
    if ((style & 0xff) == NSUnderlineStyleDouble) {
        [p moveToPoint:NSMakePoint(origin.x + NSMinX(span), lineY + thick * 2)];
        [p lineToPoint:NSMakePoint(origin.x + NSMaxX(span), lineY + thick * 2)];
    }
    [p stroke];
}

- (void)drawUnderlineForGlyphRange:(NSRange)glyphRange underlineType:(NSUnderlineStyle)underlineVal baselineOffset:(CGFloat)baselineOffset
                  lineFragmentRect:(NSRect)lineRect lineFragmentGlyphRange:(NSRange)lineGlyphRange containerOrigin:(NSPoint)containerOrigin
{
    CGFloat baseline = NSMinY(lineRect) + [self locationForGlyphAtIndex:glyphRange.location].y;
    draw_line(self, glyphRange, underlineVal, baseline + baselineOffset + 1.5, lineRect, containerOrigin, NSUnderlineColorAttributeName);
}

- (void)underlineGlyphRange:(NSRange)glyphRange underlineType:(NSUnderlineStyle)underlineVal lineFragmentRect:(NSRect)lineRect
     lineFragmentGlyphRange:(NSRange)lineGlyphRange containerOrigin:(NSPoint)containerOrigin
{
    [self drawUnderlineForGlyphRange:glyphRange underlineType:underlineVal baselineOffset:0 lineFragmentRect:lineRect
              lineFragmentGlyphRange:lineGlyphRange containerOrigin:containerOrigin];
}

- (void)drawStrikethroughForGlyphRange:(NSRange)glyphRange strikethroughType:(NSUnderlineStyle)strikethroughVal
                        baselineOffset:(CGFloat)baselineOffset lineFragmentRect:(NSRect)lineRect
                lineFragmentGlyphRange:(NSRange)lineGlyphRange containerOrigin:(NSPoint)containerOrigin
{
    NSUInteger ch = [self characterIndexForGlyphAtIndex:glyphRange.location];
    NSFont *f = ch < [[self textStorage] length] ? [[self textStorage] attribute:NSFontAttributeName atIndex:ch effectiveRange:NULL] : nil;
    CGFloat baseline = NSMinY(lineRect) + [self locationForGlyphAtIndex:glyphRange.location].y;
    draw_line(self, glyphRange, strikethroughVal, baseline + baselineOffset - [f ?: [NSFont systemFontOfSize:12] xHeight] / 2, lineRect,
              containerOrigin, NSStrikethroughColorAttributeName);
}

- (void)strikethroughGlyphRange:(NSRange)glyphRange strikethroughType:(NSUnderlineStyle)strikethroughVal lineFragmentRect:(NSRect)lineRect
         lineFragmentGlyphRange:(NSRange)lineGlyphRange containerOrigin:(NSPoint)containerOrigin
{
    [self drawStrikethroughForGlyphRange:glyphRange strikethroughType:strikethroughVal baselineOffset:0 lineFragmentRect:lineRect
                  lineFragmentGlyphRange:lineGlyphRange containerOrigin:containerOrigin];
}

- (void)showAttachmentCell:(NSCell *)cell inRect:(NSRect)rect characterIndex:(NSUInteger)attachmentIndex
{
    NSView *view = [[NSView focusView] isFlipped] ? [NSView focusView] : nil;
    if ([cell respondsToSelector:@selector(drawWithFrame:inView:characterIndex:layoutManager:)])
        [(id<NSTextAttachmentCell>)cell drawWithFrame:rect inView:view characterIndex:attachmentIndex layoutManager:self];
    else
        [cell drawWithFrame:rect inView:view];
}

/* The glyphs drawn at the point in the font and colour (packed as CGGlyphs). */
- (void)showPackedGlyphs:(char *)glyphs length:(NSUInteger)glyphLen glyphRange:(NSRange)glyphRange atPoint:(NSPoint)point font:(NSFont *)font
                   color:(NSColor *)color printingAdjustment:(NSSize)printingAdjustment
{
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx || !font)
        return;
    NSUInteger count = glyphLen / sizeof(CGGlyph);
    CGGlyph *g = (CGGlyph *)glyphs;
    CGPoint *positions = calloc(count ?: 1, sizeof(CGPoint));
    CGFloat x = 0;
    for (NSUInteger i = 0; i < count; i++) {
        positions[i] = CGPointMake(x, 0);
        x += [font advancementForCGGlyph:g[i]].width;
    }
    CGContextSaveGState(ctx);
    [color ?: [NSColor textColor] setFill];
    CGContextTranslateCTM(ctx, point.x, point.y);
    if ([[NSGraphicsContext currentContext] isFlipped])
        CGContextScaleCTM(ctx, 1, -1);
    CTFontDrawGlyphs((CTFontRef)font, g, positions, count, ctx);
    CGContextRestoreGState(ctx);
    free(positions);
}

@end

#pragma mark - NSGlyphGenerator

/* Glyphs for a glyph storage's characters: the font's glyph for each (0 where it has
   none), as Finch's layout makes them. */
@implementation NSGlyphGenerator

+ (NSGlyphGenerator *)sharedGlyphGenerator
{
    static NSGlyphGenerator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[NSGlyphGenerator alloc] init];
    });
    return shared;
}

- (void)generateGlyphsForGlyphStorage:(id<NSGlyphStorage>)glyphStorage desiredNumberOfCharacters:(NSUInteger)nChars
                           glyphIndex:(NSUInteger *)glyphIndex characterIndex:(NSUInteger *)charIndex
{
    NSAttributedString *s = [glyphStorage attributedString];
    NSUInteger start = charIndex ? *charIndex : 0, end = MIN([s length], start + nChars);
    NSUInteger gi = glyphIndex ? *glyphIndex : 0;
    for (NSUInteger i = start; i < end; i++) {
        NSFont *f = [s attribute:NSFontAttributeName atIndex:i effectiveRange:NULL] ?: [NSFont systemFontOfSize:12];
        unichar c = [[s string] characterAtIndex:i];
        CGGlyph g = 0;
        CTFontGetGlyphsForCharacters((CTFontRef)f, &c, &g, 1);
        NSGlyph glyph = g;
        [glyphStorage insertGlyphs:&glyph length:1 forStartingGlyphAtIndex:gi++ characterIndex:i];
    }
    if (glyphIndex)
        *glyphIndex = gi;
    if (charIndex)
        *charIndex = end;
}

@end

#pragma mark - NSTextStorage's scripting collections

/* (AppleScript's text: the storage's paragraphs, words, characters and attribute runs,
   each an attributed substring; setting one replaces the whole text with them) */
@implementation NSTextStorage (FinchScripting)

- (NSArray<NSTextStorage *> *)_finchPieces:(NSStringEnumerationOptions)by
{
    NSMutableArray *out = [NSMutableArray array];
    [[self string] enumerateSubstringsInRange:NSMakeRange(0, [self length]) options:by | NSStringEnumerationSubstringNotRequired
                                   usingBlock:^(NSString *sub, NSRange r, NSRange enclosing, BOOL *stop) {
                                       [out addObject:[[[NSTextStorage alloc] initWithAttributedString:[self attributedSubstringFromRange:r]] autorelease]];
                                   }];
    return out;
}

- (void)_finchSetPieces:(NSArray *)pieces separator:(NSString *)separator
{
    if (![pieces count])
        return; /* (as Apple's: no pieces leave the text alone) */
    NSMutableAttributedString *all = [[[NSMutableAttributedString alloc] init] autorelease];
    for (NSUInteger i = 0; i < [pieces count]; i++) {
        id p = pieces[i];
        if (i && separator)
            [all appendAttributedString:[[[NSAttributedString alloc] initWithString:separator] autorelease]];
        [all appendAttributedString:[p isKindOfClass:[NSAttributedString class]] ? p : [[[NSAttributedString alloc] initWithString:[p description]] autorelease]];
    }
    [self setAttributedString:all];
}

- (NSArray<NSTextStorage *> *)paragraphs { return [self _finchPieces:NSStringEnumerationByParagraphs]; }
- (void)setParagraphs:(NSArray<NSTextStorage *> *)paragraphs { [self _finchSetPieces:paragraphs separator:@"\n"]; }
- (NSArray<NSTextStorage *> *)words { return [self _finchPieces:NSStringEnumerationByWords]; }
- (void)setWords:(NSArray<NSTextStorage *> *)words { [self _finchSetPieces:words separator:@" "]; }
- (NSArray<NSTextStorage *> *)characters { return [self _finchPieces:NSStringEnumerationByComposedCharacterSequences]; }
- (void)setCharacters:(NSArray<NSTextStorage *> *)characters { [self _finchSetPieces:characters separator:nil]; }

- (NSArray<NSTextStorage *> *)attributeRuns
{
    NSMutableArray *out = [NSMutableArray array];
    [self enumerateAttributesInRange:NSMakeRange(0, [self length]) options:0
                          usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
                              [out addObject:[[[NSTextStorage alloc] initWithAttributedString:[self attributedSubstringFromRange:r]] autorelease]];
                          }];
    return out;
}

- (void)setAttributeRuns:(NSArray<NSTextStorage *> *)attributeRuns { [self _finchSetPieces:attributeRuns separator:nil]; }

@end

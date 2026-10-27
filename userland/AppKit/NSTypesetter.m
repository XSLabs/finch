/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTypesetter and NSATSTypesetter. Finch's NSLayoutManager (UIFoundation) lays out its
 * own text, so the typesetter keeps the settings and paragraph state the API exposes,
 * answers its questions (spacing, breaks, hyphens, tabs) from the text's attributes, and
 * turns layout requests into the layout manager's own layout. NSATSTypesetter is the
 * shared system typesetter, as Apple's is.
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@implementation NSTypesetter {
    BOOL _usesFontLeading, _bidi;
    NSTypesetterBehavior _behavior;
    float _hyphenation;
    CGFloat _padding;
    NSAttributedString *_string;      /* not retained, as Apple's */
    NSRange _paragraphGlyphs, _separatorGlyphs;
    NSLayoutManager *_layoutManager;  /* while laying out */
    NSTextContainer *_container;
}

+ (NSTypesetterBehavior)defaultTypesetterBehavior { return NSTypesetterBehavior_10_4; }
+ (id)sharedSystemTypesetter { return [NSATSTypesetter sharedTypesetter]; }
+ (id)sharedSystemTypesetterForBehavior:(NSTypesetterBehavior)behavior
{
    (void)behavior;
    return [NSATSTypesetter sharedTypesetter];
}

+ (NSSize)printingAdjustmentInLayoutManager:(NSLayoutManager *)layoutMgr forNominallySpacedGlyphRange:(NSRange)nominallySpacedGlyphsRange
                               packedGlyphs:(const unsigned char *)packedGlyphs count:(NSUInteger)packedGlyphsCount
{
    (void)layoutMgr; (void)nominallySpacedGlyphsRange; (void)packedGlyphs; (void)packedGlyphsCount;
    return NSZeroSize;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _usesFontLeading = YES;
        _bidi = YES;
        _behavior = [[self class] defaultTypesetterBehavior];
    }
    return self;
}

- (BOOL)usesFontLeading { return _usesFontLeading; }
- (void)setUsesFontLeading:(BOOL)flag { _usesFontLeading = flag; }
- (NSTypesetterBehavior)typesetterBehavior { return _behavior; }
- (void)setTypesetterBehavior:(NSTypesetterBehavior)behavior { _behavior = behavior; }
- (float)hyphenationFactor { return _hyphenation; }
- (void)setHyphenationFactor:(float)factor { _hyphenation = factor; }
- (CGFloat)lineFragmentPadding { return _padding; }
- (void)setLineFragmentPadding:(CGFloat)padding { _padding = padding; }
- (BOOL)bidiProcessingEnabled { return _bidi; }
- (void)setBidiProcessingEnabled:(BOOL)flag { _bidi = flag; }
- (NSAttributedString *)attributedString { return _string; }
- (void)setAttributedString:(NSAttributedString *)string { _string = string; }
- (NSLayoutManager *)layoutManager { return _layoutManager; }
- (NSTextContainer *)currentTextContainer { return _container; }
- (NSArray *)textContainers { return [_layoutManager textContainers]; }

- (NSFont *)substituteFontForFont:(NSFont *)originalFont
{
    if (_layoutManager && [_layoutManager usesScreenFonts]) return [originalFont screenFont] ?: originalFont;
    return originalFont;
}

- (NSParagraphStyle *)currentParagraphStyle
{
    NSRange chars = [self paragraphCharacterRange];
    if (!_string || chars.location >= [_string length]) return [NSParagraphStyle defaultParagraphStyle];
    return [_string attribute:NSParagraphStyleAttributeName atIndex:chars.location effectiveRange:NULL] ?: [NSParagraphStyle defaultParagraphStyle];
}

- (NSTextTab *)textTabForGlyphLocation:(CGFloat)glyphLocation writingDirection:(NSWritingDirection)direction maxLocation:(CGFloat)maxLocation
{
    NSParagraphStyle *style = [self currentParagraphStyle];
    NSArray *tabs = [style tabStops];
    if (direction == NSWritingDirectionRightToLeft) {
        for (NSTextTab *tab in [tabs reverseObjectEnumerator])
            if ([tab location] < glyphLocation && [tab location] <= maxLocation) return tab;
        return nil;
    }
    for (NSTextTab *tab in tabs)
        if ([tab location] > glyphLocation && [tab location] <= maxLocation) return tab;
    CGFloat interval = [style defaultTabInterval];
    if (interval > 0) {
        CGFloat next = (floor(glyphLocation / interval) + 1) * interval;
        if (next <= maxLocation) return [[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:next options:@{}] autorelease];
    }
    return nil;
}

- (void)setParagraphGlyphRange:(NSRange)paragraphRange separatorGlyphRange:(NSRange)paragraphSeparatorRange
{
    _paragraphGlyphs = paragraphRange;
    _separatorGlyphs = paragraphSeparatorRange;
}

- (NSRange)paragraphGlyphRange { return _paragraphGlyphs; }
- (NSRange)paragraphSeparatorGlyphRange { return _separatorGlyphs; }
- (NSRange)paragraphCharacterRange { return [self characterRangeForGlyphRange:_paragraphGlyphs actualGlyphRange:NULL]; }
- (NSRange)paragraphSeparatorCharacterRange { return [self characterRangeForGlyphRange:_separatorGlyphs actualGlyphRange:NULL]; }

- (NSUInteger)layoutParagraphAtPoint:(NSPointPointer)lineFragmentOrigin
{
    [self beginParagraph];
    NSRange glyphs = NSMakeRange(_paragraphGlyphs.location, NSMaxRange(_separatorGlyphs.length ? _separatorGlyphs : _paragraphGlyphs) - _paragraphGlyphs.location);
    if (_layoutManager && glyphs.length) {
        [_layoutManager ensureLayoutForGlyphRange:glyphs];
        NSRect used = [_layoutManager lineFragmentRectForGlyphAtIndex:NSMaxRange(glyphs) - 1 effectiveRange:NULL];
        if (lineFragmentOrigin) lineFragmentOrigin->y = NSMaxY(used);
    }
    [self endParagraph];
    return NSMaxRange(glyphs);
}

- (void)beginParagraph {}
- (void)endParagraph {}
- (void)beginLineWithGlyphAtIndex:(NSUInteger)glyphIndex { (void)glyphIndex; }
- (void)endLineWithGlyphRange:(NSRange)lineGlyphRange { (void)lineGlyphRange; }

static NSParagraphStyle *
style_at_glyph(NSTypesetter *self, NSUInteger glyphIndex)
{
    NSAttributedString *string = [self attributedString];
    NSUInteger character = [self layoutManager] ? [[self layoutManager] characterIndexForGlyphAtIndex:glyphIndex] : glyphIndex;
    if (!string || character >= [string length]) return [NSParagraphStyle defaultParagraphStyle];
    return [string attribute:NSParagraphStyleAttributeName atIndex:character effectiveRange:NULL] ?: [NSParagraphStyle defaultParagraphStyle];
}

- (CGFloat)lineSpacingAfterGlyphAtIndex:(NSUInteger)glyphIndex withProposedLineFragmentRect:(NSRect)rect
{
    (void)rect;
    return [style_at_glyph(self, glyphIndex) lineSpacing];
}

- (CGFloat)paragraphSpacingBeforeGlyphAtIndex:(NSUInteger)glyphIndex withProposedLineFragmentRect:(NSRect)rect
{
    (void)rect;
    return [style_at_glyph(self, glyphIndex) paragraphSpacingBefore];
}

- (CGFloat)paragraphSpacingAfterGlyphAtIndex:(NSUInteger)glyphIndex withProposedLineFragmentRect:(NSRect)rect
{
    (void)rect;
    return [style_at_glyph(self, glyphIndex) paragraphSpacing];
}

- (void)getLineFragmentRect:(NSRectPointer)lineFragmentRect usedRect:(NSRectPointer)lineFragmentUsedRect
    forParagraphSeparatorGlyphRange:(NSRange)paragraphSeparatorGlyphRange atProposedOrigin:(NSPoint)lineOrigin
{
    (void)paragraphSeparatorGlyphRange;
    NSFont *font = [[self attributesForExtraLineFragment] objectForKey:NSFontAttributeName] ?: [NSFont systemFontOfSize:0];
    CGFloat height = _layoutManager ? [_layoutManager defaultLineHeightForFont:font] : ceil([font ascender] - [font descender]);
    CGFloat width = _container ? [_container size].width : 0;
    NSRect rect = NSMakeRect(lineOrigin.x, lineOrigin.y, width, height);
    if (lineFragmentRect) *lineFragmentRect = rect;
    if (lineFragmentUsedRect) *lineFragmentUsedRect = NSMakeRect(lineOrigin.x, lineOrigin.y, 2 * _padding, height);
}

- (NSDictionary *)attributesForExtraLineFragment
{
    if (_layoutManager && [_layoutManager respondsToSelector:@selector(firstTextView)]) {
        NSDictionary *typing = [[_layoutManager firstTextView] typingAttributes];
        if (typing) return typing;
    }
    if (_string && [_string length]) return [_string attributesAtIndex:[_string length] - 1 effectiveRange:NULL];
    return @{};
}

- (void)setHardInvalidation:(BOOL)flag forGlyphRange:(NSRange)glyphRange { (void)flag; (void)glyphRange; }

- (void)layoutGlyphsInLayoutManager:(NSLayoutManager *)layoutManager startingAtGlyphIndex:(NSUInteger)startGlyphIndex
           maxNumberOfLineFragments:(NSUInteger)maxNumLines nextGlyphIndex:(NSUInteger *)nextGlyph
{
    (void)maxNumLines;
    _layoutManager = layoutManager;
    _string = [layoutManager textStorage];
    NSUInteger glyphs = [layoutManager numberOfGlyphs];
    if (startGlyphIndex < glyphs) [layoutManager ensureLayoutForGlyphRange:NSMakeRange(startGlyphIndex, glyphs - startGlyphIndex)];
    if (nextGlyph) *nextGlyph = glyphs;
    _layoutManager = nil;
    _string = nil;
}

- (NSRange)layoutCharactersInRange:(NSRange)characterRange forLayoutManager:(NSLayoutManager *)layoutManager maximumNumberOfLineFragments:(NSUInteger)maxNumLines
{
    (void)maxNumLines;
    [layoutManager ensureLayoutForCharacterRange:characterRange];
    return characterRange;
}

- (CGFloat)baselineOffsetInLayoutManager:(NSLayoutManager *)layoutMgr glyphIndex:(NSUInteger)glyphIndex
{
    if (glyphIndex >= [layoutMgr numberOfGlyphs]) return 0;
    NSFont *font = [[layoutMgr textStorage] attribute:NSFontAttributeName atIndex:[layoutMgr characterIndexForGlyphAtIndex:glyphIndex] effectiveRange:NULL]
                   ?: [NSFont userFontOfSize:0];
    return -[font descender];
}

/* Layout phase */
- (void)willSetLineFragmentRect:(NSRectPointer)lineRect forGlyphRange:(NSRange)glyphRange usedRect:(NSRectPointer)usedRect baselineOffset:(CGFloat *)baselineOffset
{
    (void)lineRect; (void)glyphRange; (void)usedRect; (void)baselineOffset;
}

- (BOOL)shouldBreakLineByWordBeforeCharacterAtIndex:(NSUInteger)charIndex { (void)charIndex; return YES; }
- (BOOL)shouldBreakLineByHyphenatingBeforeCharacterAtIndex:(NSUInteger)charIndex { (void)charIndex; return YES; }

- (float)hyphenationFactorForGlyphAtIndex:(NSUInteger)glyphIndex
{
    float factor = [style_at_glyph(self, glyphIndex) hyphenationFactor];
    return factor > 0 ? factor : _hyphenation;
}

- (UTF32Char)hyphenCharacterForGlyphAtIndex:(NSUInteger)glyphIndex
{
    (void)glyphIndex;
    return 0x2010;
}

- (NSRect)boundingBoxForControlGlyphAtIndex:(NSUInteger)glyphIndex forTextContainer:(NSTextContainer *)textContainer proposedLineFragment:(NSRect)proposedRect
                             glyphPosition:(NSPoint)glyphPosition characterIndex:(NSUInteger)charIndex
{
    (void)glyphIndex; (void)textContainer; (void)proposedRect; (void)charIndex;
    return NSMakeRect(glyphPosition.x, glyphPosition.y, 0, 0);
}

/* Glyph storage */
- (NSRange)characterRangeForGlyphRange:(NSRange)glyphRange actualGlyphRange:(NSRangePointer)actualGlyphRange
{
    if (_layoutManager) return [_layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:actualGlyphRange];
    if (actualGlyphRange) *actualGlyphRange = glyphRange;
    return glyphRange;
}

- (NSRange)glyphRangeForCharacterRange:(NSRange)charRange actualCharacterRange:(NSRangePointer)actualCharRange
{
    if (_layoutManager) return [_layoutManager glyphRangeForCharacterRange:charRange actualCharacterRange:actualCharRange];
    if (actualCharRange) *actualCharRange = charRange;
    return charRange;
}

- (NSUInteger)getGlyphsInRange:(NSRange)glyphsRange glyphs:(NSGlyph *)glyphBuffer characterIndexes:(NSUInteger *)charIndexBuffer
             glyphInscriptions:(NSGlyphInscription *)inscribeBuffer elasticBits:(BOOL *)elasticBuffer bidiLevels:(unsigned char *)bidiLevelBuffer
{
    if (!_layoutManager) return 0;
    NSUInteger count = 0;
    NSUInteger end = MIN(NSMaxRange(glyphsRange), [_layoutManager numberOfGlyphs]);
    for (NSUInteger g = glyphsRange.location; g < end; g++, count++) {
        if (glyphBuffer) glyphBuffer[count] = [_layoutManager CGGlyphAtIndex:g];
        if (charIndexBuffer) charIndexBuffer[count] = [_layoutManager characterIndexForGlyphAtIndex:g];
        if (inscribeBuffer) inscribeBuffer[count] = NSGlyphInscribeBase;
        if (elasticBuffer) elasticBuffer[count] = NO;
        if (bidiLevelBuffer) bidiLevelBuffer[count] = 0;
    }
    return count;
}

- (void)getLineFragmentRect:(NSRectPointer)lineFragmentRect usedRect:(NSRectPointer)lineFragmentUsedRect remainingRect:(NSRectPointer)remainingRect
    forStartingGlyphAtIndex:(NSUInteger)startingGlyphIndex proposedRect:(NSRect)proposedRect lineSpacing:(CGFloat)lineSpacing
     paragraphSpacingBefore:(CGFloat)paragraphSpacingBefore paragraphSpacingAfter:(CGFloat)paragraphSpacingAfter
{
    (void)startingGlyphIndex; (void)lineSpacing; (void)paragraphSpacingAfter;
    proposedRect.origin.y += paragraphSpacingBefore;
    NSRect rect = _container ? [_container lineFragmentRectForProposedRect:proposedRect atIndex:0 writingDirection:NSWritingDirectionNatural
                                                              remainingRect:remainingRect]
                             : proposedRect;
    if (!_container && remainingRect) *remainingRect = NSZeroRect;
    if (lineFragmentRect) *lineFragmentRect = rect;
    if (lineFragmentUsedRect) *lineFragmentUsedRect = rect;
}

- (void)setLineFragmentRect:(NSRect)fragmentRect forGlyphRange:(NSRange)glyphRange usedRect:(NSRect)usedRect baselineOffset:(CGFloat)baselineOffset
{
    (void)baselineOffset;
    if (_layoutManager && _container) [_layoutManager setLineFragmentRect:fragmentRect forGlyphRange:glyphRange usedRect:usedRect];
}

- (void)setNotShownAttribute:(BOOL)flag forGlyphRange:(NSRange)glyphRange
{
    for (NSUInteger g = glyphRange.location; _layoutManager && g < NSMaxRange(glyphRange); g++) [_layoutManager setNotShownAttribute:flag forGlyphAtIndex:g];
}

- (void)setDrawsOutsideLineFragment:(BOOL)flag forGlyphRange:(NSRange)glyphRange
{
    for (NSUInteger g = glyphRange.location; _layoutManager && g < NSMaxRange(glyphRange); g++) [_layoutManager setDrawsOutsideLineFragment:flag forGlyphAtIndex:g];
}

- (void)setLocation:(NSPoint)location withAdvancements:(const CGFloat *)advancements forStartOfGlyphRange:(NSRange)glyphRange
{
    (void)advancements;
    if (_layoutManager) [_layoutManager setLocation:location forStartOfGlyphRange:glyphRange];
}

- (void)setAttachmentSize:(NSSize)attachmentSize forGlyphRange:(NSRange)glyphRange
{
    if (_layoutManager) [_layoutManager setAttachmentSize:attachmentSize forGlyphRange:glyphRange];
}

- (void)setBidiLevels:(const uint8_t *)levels forGlyphRange:(NSRange)glyphRange { (void)levels; (void)glyphRange; }

/* Deprecated */
- (NSTypesetterControlCharacterAction)actionForControlCharacterAtIndex:(NSUInteger)charIndex
{
    NSString *string = [_string string];
    unichar c = charIndex < [string length] ? [string characterAtIndex:charIndex] : 0;
    switch (c) {
    case '\t': return NSTypesetterHorizontalTabAction;
    case '\n': case '\r': case 0x2029: return NSTypesetterParagraphBreakAction;
    case 0x2028: return NSTypesetterLineBreakAction;
    case 0x0C: return NSTypesetterContainerBreakAction;
    case ' ': return NSTypesetterWhitespaceAction;
    default: return NSTypesetterZeroAdvancementAction;
    }
}

- (void)substituteGlyphsInRange:(NSRange)glyphRange withGlyphs:(NSGlyph *)glyphs { (void)glyphRange; (void)glyphs; }
- (void)insertGlyph:(NSGlyph)glyph atGlyphIndex:(NSUInteger)glyphIndex characterIndex:(NSUInteger)characterIndex
{
    (void)glyph; (void)glyphIndex; (void)characterIndex;
}
- (void)deleteGlyphsInRange:(NSRange)glyphRange { (void)glyphRange; }

@end

@implementation NSATSTypesetter

+ (NSATSTypesetter *)sharedTypesetter
{
    static NSATSTypesetter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[NSATSTypesetter alloc] init]; });
    return shared;
}

- (NSRect)lineFragmentRectForProposedRect:(NSRect)proposedRect remainingRect:(NSRectPointer)remainingRect
{
    NSTextContainer *container = [self currentTextContainer];
    if (!container) {
        if (remainingRect) *remainingRect = NSZeroRect;
        return proposedRect;
    }
    return [container lineFragmentRectForProposedRect:proposedRect atIndex:0 writingDirection:NSWritingDirectionNatural remainingRect:remainingRect];
}

@end

/* The layout manager's typesetter: the shared one unless it is given another. */
@implementation NSLayoutManager (FinchTypesetter)

static char typesetter_key;

- (NSTypesetter *)typesetter
{
    return objc_getAssociatedObject(self, &typesetter_key) ?: [NSTypesetter sharedSystemTypesetterForBehavior:[self typesetterBehavior]];
}

- (void)setTypesetter:(NSTypesetter *)typesetter
{
    objc_setAssociatedObject(self, &typesetter_key, typesetter, OBJC_ASSOCIATION_RETAIN);
}

@end

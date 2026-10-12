/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextView's Format-menu commands and helpers beyond the basics: underline,
 * superscript and baseline, kerning and ligatures, outline, copy and paste of font
 * and ruler styles, writing direction, the automatic-substitution toggles, smart
 * insert and delete, completion's range, spelling state, highlights, links, and
 * NSText's own versions of the editing actions. Compared with Apple's.
 */
#import <AppKit/AppKit.h>

static NSString *
attrs_at(NSTextView *tv, NSUInteger i)
{
    NSDictionary *a = [tv.textStorage attributesAtIndex:i effectiveRange:NULL];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in @[ NSUnderlineStyleAttributeName, NSSuperscriptAttributeName, NSBaselineOffsetAttributeName, NSKernAttributeName,
             NSLigatureAttributeName, NSStrokeWidthAttributeName, NSStrikethroughStyleAttributeName ]) {
        id v = a[k];
        if (v)
            [parts addObject:[NSString stringWithFormat:@"%@=%@", [k stringByReplacingOccurrencesOfString:@"NS" withString:@""], v]];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *
para_at(NSTextView *tv, NSUInteger i)
{
    NSParagraphStyle *p = [tv.textStorage attribute:NSParagraphStyleAttributeName atIndex:i effectiveRange:NULL];
    return [NSString stringWithFormat:@"align %ld dir %ld head %g first %g", (long)p.alignment, (long)p.baseWritingDirection,
        p.headIndent, p.firstLineHeadIndent];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [NSApplication sharedApplication];
        printf("NSTextView more\n");
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        tv.richText = YES;
        [tv.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@"Hello wonderful world"
                                                                            attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:12]}]];
        tv.selectedRange = NSMakeRange(6, 9);

        [tv underline:nil];
        printf("underline: %s\n", attrs_at(tv, 6).UTF8String);
        [tv underline:nil];
        printf("underline again: [%s]\n", attrs_at(tv, 6).UTF8String);
        [tv superscript:nil];
        [tv superscript:nil];
        printf("superscript x2: %s\n", attrs_at(tv, 6).UTF8String);
        [tv subscript:nil];
        printf("subscript: %s\n", attrs_at(tv, 6).UTF8String);
        [tv unscript:nil];
        printf("unscript: [%s]\n", attrs_at(tv, 6).UTF8String);
        [tv raiseBaseline:nil];
        [tv raiseBaseline:nil];
        printf("raise x2: %s\n", attrs_at(tv, 6).UTF8String);
        [tv lowerBaseline:nil];
        printf("lower: %s\n", attrs_at(tv, 6).UTF8String);
        [tv unscript:nil];
        printf("unscript clears offset: [%s]\n", attrs_at(tv, 6).UTF8String);
        [tv tightenKerning:nil];
        printf("tighten: %s\n", attrs_at(tv, 6).UTF8String);
        [tv loosenKerning:nil];
        [tv loosenKerning:nil];
        printf("loosen x2: %s\n", attrs_at(tv, 6).UTF8String);
        [tv turnOffKerning:nil];
        printf("kerning off: %s\n", attrs_at(tv, 6).UTF8String);
        [tv useStandardKerning:nil];
        printf("standard kerning: [%s]\n", attrs_at(tv, 6).UTF8String);
        [tv turnOffLigatures:nil];
        printf("ligatures off: %s\n", attrs_at(tv, 6).UTF8String);
        [tv useAllLigatures:nil];
        printf("all ligatures: %s\n", attrs_at(tv, 6).UTF8String);
        [tv useStandardLigatures:nil];
        printf("standard ligatures: [%s]\n", attrs_at(tv, 6).UTF8String);
        [tv outline:nil];
        printf("outline: %s\n", attrs_at(tv, 6).UTF8String);
        [tv outline:nil];
        printf("outline again: [%s]\n", attrs_at(tv, 6).UTF8String);
        printf("outside selection: [%s]\n", attrs_at(tv, 0).UTF8String);

        /* styles by pasteboard */
        tv.selectedRange = NSMakeRange(0, 5);
        [tv setFont:[NSFont boldSystemFontOfSize:20] range:NSMakeRange(0, 5)];
        [tv copyFont:nil];
        NSPasteboard *fontPB = [NSPasteboard pasteboardWithName:NSPasteboardNameFont];
        printf("font pasteboard types: %s\n", [[fontPB.types valueForKey:@"description"] componentsJoinedByString:@","].UTF8String);
        tv.selectedRange = NSMakeRange(16, 5);
        [tv pasteFont:nil];
        NSFont *pasted = [tv.textStorage attribute:NSFontAttributeName atIndex:16 effectiveRange:NULL];
        printf("pasted font: %g bold %d\n", pasted.pointSize, (pasted.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0);
        tv.selectedRange = NSMakeRange(0, 5);
        [tv alignCenter:nil];
        [tv copyRuler:nil];
        NSPasteboard *rulerPB = [NSPasteboard pasteboardWithName:NSPasteboardNameRuler];
        printf("ruler pasteboard types: %s\n", [[rulerPB.types valueForKey:@"description"] componentsJoinedByString:@","].UTF8String);
        [tv.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:@"\nSecond line"]];
        tv.selectedRange = NSMakeRange(23, 3);
        [tv pasteRuler:nil];
        printf("pasted ruler: %s\n", para_at(tv, 23).UTF8String);
        [tv toggleBaseWritingDirection:nil];
        printf("writing direction: %s\n", para_at(tv, 23).UTF8String);
        [tv alignRight:nil];
        printf("align right: %s\n", para_at(tv, 23).UTF8String);

        /* toggles */
        BOOL before[] = {tv.isAutomaticQuoteSubstitutionEnabled, tv.isAutomaticDashSubstitutionEnabled, tv.isAutomaticLinkDetectionEnabled,
                         tv.isAutomaticDataDetectionEnabled, tv.isAutomaticSpellingCorrectionEnabled, tv.isAutomaticTextReplacementEnabled,
                         tv.isAutomaticTextCompletionEnabled, tv.isGrammarCheckingEnabled, tv.smartInsertDeleteEnabled};
        [tv toggleAutomaticQuoteSubstitution:nil];
        [tv toggleAutomaticDashSubstitution:nil];
        [tv toggleAutomaticLinkDetection:nil];
        [tv toggleAutomaticDataDetection:nil];
        [tv toggleAutomaticSpellingCorrection:nil];
        [tv toggleAutomaticTextReplacement:nil];
        [tv toggleAutomaticTextCompletion:nil];
        [tv toggleGrammarChecking:nil];
        [tv toggleSmartInsertDelete:nil];
        BOOL after[] = {tv.isAutomaticQuoteSubstitutionEnabled, tv.isAutomaticDashSubstitutionEnabled, tv.isAutomaticLinkDetectionEnabled,
                        tv.isAutomaticDataDetectionEnabled, tv.isAutomaticSpellingCorrectionEnabled, tv.isAutomaticTextReplacementEnabled,
                        tv.isAutomaticTextCompletionEnabled, tv.isGrammarCheckingEnabled, tv.smartInsertDeleteEnabled};
        printf("toggles:");
        for (int i = 0; i < 9; i++)
            printf(" %d>%d", before[i], after[i]);
        printf("\n");

        /* smart insert and delete */
        [tv setString:@"one two three"];
        tv.smartInsertDeleteEnabled = YES;
        NSRange r = [tv smartDeleteRangeForProposedRange:NSMakeRange(4, 3)];
        printf("smart delete range: %s\n", NSStringFromRange(r).UTF8String);
        NSString *before_s = nil, *after_s = nil;
        [tv smartInsertForString:@"new" replacingRange:NSMakeRange(3, 0) beforeString:&before_s afterString:&after_s];
        printf("smart insert at 3: [%s] [%s]\n", before_s.UTF8String ?: "nil", after_s.UTF8String ?: "nil");
        [tv smartInsertForString:@"new" replacingRange:NSMakeRange(4, 3) beforeString:&before_s afterString:&after_s];
        printf("smart insert replacing two: [%s] [%s]\n", before_s.UTF8String ?: "nil", after_s.UTF8String ?: "nil");
        printf("before/after strings: [%s] [%s]\n", [tv smartInsertBeforeStringForString:@"x" replacingRange:NSMakeRange(3, 0)].UTF8String ?: "nil",
            [tv smartInsertAfterStringForString:@"x" replacingRange:NSMakeRange(3, 0)].UTF8String ?: "nil");
        tv.selectedRange = NSMakeRange(10, 0);
        printf("completion range: %s\n", NSStringFromRange(tv.rangeForUserCompletion).UTF8String);
        tv.selectedRange = NSMakeRange(3, 0);
        printf("completion range after space: %s\n", NSStringFromRange(tv.rangeForUserCompletion).UTF8String);

        /* odds and ends */
        printf("highlight attributes: %lu keys, rollover %d, inline prediction %ld, math %ld, writing tools options %lu\n",
            (unsigned long)tv.textHighlightAttributes.count, tv.usesRolloverButtonForSelection, (long)tv.inlinePredictionType,
            (long)tv.mathExpressionCompletionType, (unsigned long)tv.allowedWritingToolsResultOptions);
        printf("acceptable drag types: %lu, strongly references storage %d\n", (unsigned long)tv.acceptableDragTypes.count,
            [NSTextView stronglyReferencesTextStorage]);
        NSTextView *fe = [NSTextView fieldEditor];
        printf("field editor: %s %d\n", fe ? object_getClassName(fe) : "nil", fe.isFieldEditor);
        [tv setSpellingState:NSSpellingStateSpellingFlag range:NSMakeRange(0, 3)];
        NSDictionary *temp = [tv.layoutManager temporaryAttributesAtCharacterIndex:0 effectiveRange:NULL];
        printf("spelling state: %s\n", [temp[NSSpellingStateAttributeName] description].UTF8String ?: "none");
        BOOL replaced = [tv performValidatedReplacementInRange:NSMakeRange(0, 3) withAttributedString:[[NSAttributedString alloc] initWithString:@"ONE"]];
        printf("validated replacement: %d %s\n", replaced, tv.string.UTF8String);

        /* the layout manager, glyph generator and scripting collections */
        NSTextStorage *ts = [[NSTextStorage alloc] initWithString:@"First para here.\nSecond one."];
        [ts addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:12] range:NSMakeRange(0, 5)];
        printf("scripting: %lu paragraphs, %lu words, %lu characters, %lu runs; word 2 [%s]\n", (unsigned long)ts.paragraphs.count,
            (unsigned long)ts.words.count, (unsigned long)ts.characters.count, (unsigned long)ts.attributeRuns.count, ts.words[1].string.UTF8String);
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        [ts addLayoutManager:lm];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(200, 1000)];
        [lm addTextContainer:tc];
        NSUInteger chars[4];
        NSGlyphInscription ins[4];
        BOOL elastic[4];
        NSUInteger got = [lm getGlyphsInRange:NSMakeRange(0, 4) glyphs:NULL characterIndexes:chars glyphInscriptions:ins elasticBits:elastic];
        printf("glyphs: %lu, chars %lu %lu %lu %lu, inscription %ld\n", (unsigned long)got, (unsigned long)chars[0], (unsigned long)chars[1],
            (unsigned long)chars[2], (unsigned long)chars[3], (long)ins[0]);
        [lm setIntAttribute:NSGlyphAttributeInscribe value:NSGlyphInscribeOverstrike forGlyphAtIndex:2];
        printf("int attribute: %ld\n", (long)[lm intAttribute:NSGlyphAttributeInscribe forGlyphAtIndex:2]);
        printf("glyph generator: %d shared %d\n", lm.glyphGenerator != nil, lm.glyphGenerator == [NSGlyphGenerator sharedGlyphGenerator]);

        /* NSText's versions */
        NSText *t = [[NSText alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [t setString:@"abc"];
        [t selectAll:nil];
        [t replaceCharactersInRange:NSMakeRange(1, 1) withString:@"X"];
        NSData *rtf = [t RTFFromRange:NSMakeRange(0, 3)];
        printf("NSText: %s %s rtf %d\n", object_getClassName(t), t.string.UTF8String, rtf.length > 0);
    }
    return 0;
}

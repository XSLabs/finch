/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextView's commands and helpers beyond the basics, as measured against Apple's
 * (textview-more-test.m): underline, superscript and baseline offsets, kerning (steps
 * of the font's size over 75), ligatures, outline, the font and ruler styles copied and
 * pasted through their pasteboards, writing direction, smart insert and delete,
 * completion, text checking, link clicks, the format panels, highlights and the
 * remaining settings; and NSText's own versions of the editing actions.
 */
#import "NSView_Finch.h"

NSPasteboardType const FinchLegacyFontType = @"NeXT font pasteboard type";
NSPasteboardType const FinchLegacyRulerType = @"NeXT ruler pasteboard type";

/* Each selected range (or the typing attributes, for an insertion point) changed by
   `change`, with undo and the change notifications. */
static void
change_attributes(NSTextView *tv, void (^change)(NSMutableDictionary *attrs, NSTextStorage *ts, NSRange r))
{
    NSArray<NSValue *> *ranges = [tv selectedRanges];
    BOOL empty = [ranges count] == 1 && [ranges[0] rangeValue].length == 0;
    if (empty) {
        NSMutableDictionary *typing = [[[tv typingAttributes] mutableCopy] autorelease];
        change(typing, nil, NSMakeRange(NSNotFound, 0));
        [tv setTypingAttributes:typing];
        return;
    }
    if (![tv shouldChangeTextInRanges:ranges replacementStrings:nil])
        return;
    NSTextStorage *ts = [tv textStorage];
    [ts beginEditing];
    for (NSValue *v in ranges)
        if ([v rangeValue].length)
            change(nil, ts, [v rangeValue]);
    [ts endEditing];
    [tv didChangeText];
}

/* An attribute's value at the start of the selection (the typing attribute for an
   insertion point). */
static id
current(NSTextView *tv, NSString *key)
{
    NSRange r = [tv selectedRange];
    if (!r.length || r.location >= [[tv textStorage] length])
        return [tv typingAttributes][key];
    return [[tv textStorage] attribute:key atIndex:r.location effectiveRange:NULL];
}

/* A numeric attribute stepped over each run of the range. */
static void
step_number(NSTextView *tv, NSString *key, double (^next)(double now, NSFont *font))
{
    change_attributes(tv, ^(NSMutableDictionary *attrs, NSTextStorage *ts, NSRange r) {
        if (attrs) {
            double v = next([attrs[key] doubleValue], attrs[NSFontAttributeName]);
            attrs[key] = @(v);
            return;
        }
        [ts enumerateAttributesInRange:r options:0 usingBlock:^(NSDictionary *a, NSRange run, BOOL *stop) {
            [ts addAttribute:key value:@(next([a[key] doubleValue], a[NSFontAttributeName])) range:run];
        }];
    });
}

static void
set_value(NSTextView *tv, NSString *key, id value)
{
    change_attributes(tv, ^(NSMutableDictionary *attrs, NSTextStorage *ts, NSRange r) {
        if (attrs) {
            if (value)
                attrs[key] = value;
            else
                [attrs removeObjectForKey:key];
        } else if (value)
            [ts addAttribute:key value:value range:r];
        else
            [ts removeAttribute:key range:r];
    });
}

@implementation NSTextView (FinchMore)

#pragma mark Underline, scripts, baseline

- (IBAction)underline:(id)sender
{
    set_value(self, NSUnderlineStyleAttributeName, [current(self, NSUnderlineStyleAttributeName) integerValue] ? nil : @(NSUnderlineStyleSingle));
}

- (IBAction)superscript:(id)sender
{
    step_number(self, NSSuperscriptAttributeName, ^double(double now, NSFont *f) { return now + 1; });
}

- (IBAction)subscript:(id)sender
{
    step_number(self, NSSuperscriptAttributeName, ^double(double now, NSFont *f) { return now - 1; });
}

- (IBAction)unscript:(id)sender
{
    change_attributes(self, ^(NSMutableDictionary *attrs, NSTextStorage *ts, NSRange r) {
        if (attrs) {
            [attrs removeObjectForKey:NSSuperscriptAttributeName];
            [attrs removeObjectForKey:NSBaselineOffsetAttributeName];
        } else {
            [ts removeAttribute:NSSuperscriptAttributeName range:r];
            [ts removeAttribute:NSBaselineOffsetAttributeName range:r];
        }
    });
}

- (IBAction)raiseBaseline:(id)sender
{
    step_number(self, NSBaselineOffsetAttributeName, ^double(double now, NSFont *f) { return now + 1; });
}

- (IBAction)lowerBaseline:(id)sender
{
    step_number(self, NSBaselineOffsetAttributeName, ^double(double now, NSFont *f) { return now - 1; });
}

#pragma mark Kerning and ligatures

/* (a step is the font's size over 75, as Apple's: 0.16 at 12 points) */
static double
kern_step(NSFont *f)
{
    return ([f pointSize] ?: 12) / 75.0;
}

- (IBAction)tightenKerning:(id)sender
{
    step_number(self, NSKernAttributeName, ^double(double now, NSFont *f) { return now - kern_step(f); });
}

- (IBAction)loosenKerning:(id)sender
{
    step_number(self, NSKernAttributeName, ^double(double now, NSFont *f) { return now + kern_step(f); });
}

- (IBAction)turnOffKerning:(id)sender { set_value(self, NSKernAttributeName, @0); }
- (IBAction)useStandardKerning:(id)sender { set_value(self, NSKernAttributeName, nil); }
- (IBAction)turnOffLigatures:(id)sender { set_value(self, NSLigatureAttributeName, @0); }
- (IBAction)useStandardLigatures:(id)sender { set_value(self, NSLigatureAttributeName, nil); }
- (IBAction)useAllLigatures:(id)sender { set_value(self, NSLigatureAttributeName, @2); }

- (IBAction)outline:(id)sender
{
    set_value(self, NSStrokeWidthAttributeName, [current(self, NSStrokeWidthAttributeName) doubleValue] > 0 ? nil : @3);
}

- (IBAction)toggleTraditionalCharacterShape:(id)sender
{
    set_value(self, NSCharacterShapeAttributeName, [current(self, NSCharacterShapeAttributeName) integerValue] ? nil : @1);
}

#pragma mark Styles by pasteboard

/* Copy Style: the typing attributes, as RTF of one character, on the font pasteboard. */
- (IBAction)copyFont:(id)sender
{
    NSMutableDictionary *attrs = [[[self typingAttributes] mutableCopy] autorelease];
    [attrs removeObjectForKey:NSParagraphStyleAttributeName];
    NSAttributedString *sample = [[[NSAttributedString alloc] initWithString:@" " attributes:attrs] autorelease];
    NSData *rtf = [sample RTFFromRange:NSMakeRange(0, 1) documentAttributes:@{}];
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameFont];
    [pb declareTypes:@[ NSPasteboardTypeFont, FinchLegacyFontType ] owner:nil];
    [pb setData:rtf forType:NSPasteboardTypeFont];
    [pb setData:rtf forType:FinchLegacyFontType];
}

- (IBAction)pasteFont:(id)sender
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameFont];
    NSData *rtf = [pb dataForType:NSPasteboardTypeFont] ?: [pb dataForType:FinchLegacyFontType];
    NSAttributedString *sample = rtf ? [[[NSAttributedString alloc] initWithRTF:rtf documentAttributes:NULL] autorelease] : nil;
    if (![sample length])
        return;
    NSMutableDictionary *style = [[[sample attributesAtIndex:0 effectiveRange:NULL] mutableCopy] autorelease];
    [style removeObjectForKey:NSParagraphStyleAttributeName];
    change_attributes(self, ^(NSMutableDictionary *attrs, NSTextStorage *ts, NSRange r) {
        if (attrs)
            [attrs addEntriesFromDictionary:style];
        else
            [ts addAttributes:style range:r];
    });
}

/* Copy Ruler: the first selected paragraph's style, on the ruler pasteboard. */
- (IBAction)copyRuler:(id)sender
{
    NSParagraphStyle *ps = current(self, NSParagraphStyleAttributeName) ?: [self defaultParagraphStyle] ?: [NSParagraphStyle defaultParagraphStyle];
    NSAttributedString *sample = [[[NSAttributedString alloc] initWithString:@" " attributes:@{NSParagraphStyleAttributeName : ps}] autorelease];
    NSData *rtf = [sample RTFFromRange:NSMakeRange(0, 1) documentAttributes:@{}];
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameRuler];
    [pb declareTypes:@[ NSPasteboardTypeRuler, FinchLegacyRulerType ] owner:nil];
    [pb setData:rtf forType:NSPasteboardTypeRuler];
    [pb setData:rtf forType:FinchLegacyRulerType];
}

- (IBAction)pasteRuler:(id)sender
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameRuler];
    NSData *rtf = [pb dataForType:NSPasteboardTypeRuler] ?: [pb dataForType:FinchLegacyRulerType];
    NSAttributedString *sample = rtf ? [[[NSAttributedString alloc] initWithRTF:rtf documentAttributes:NULL] autorelease] : nil;
    NSParagraphStyle *ps = [sample length] ? [sample attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] : nil;
    if (!ps)
        return;
    NSString *s = [[self textStorage] string];
    NSRange paras = [s paragraphRangeForRange:[self selectedRange]];
    if (!paras.length) {
        NSMutableDictionary *typing = [[[self typingAttributes] mutableCopy] autorelease];
        typing[NSParagraphStyleAttributeName] = ps;
        [self setTypingAttributes:typing];
        return;
    }
    if (![self shouldChangeTextInRange:paras replacementString:nil])
        return;
    [[self textStorage] addAttribute:NSParagraphStyleAttributeName value:ps range:paras];
    [self didChangeText];
}

/* Right to left, or back to left to right (natural counts as left to right). */
- (IBAction)toggleBaseWritingDirection:(id)sender
{
    NSParagraphStyle *ps = current(self, NSParagraphStyleAttributeName);
    NSWritingDirection now = ps ? [ps baseWritingDirection] : NSWritingDirectionNatural;
    [self setBaseWritingDirection:now == NSWritingDirectionRightToLeft ? NSWritingDirectionLeftToRight : NSWritingDirectionRightToLeft
                            range:[[[self textStorage] string] paragraphRangeForRange:[self selectedRange]]];
}

#pragma mark Settings toggled

- (IBAction)toggleAutomaticQuoteSubstitution:(id)sender { [self setAutomaticQuoteSubstitutionEnabled:![self isAutomaticQuoteSubstitutionEnabled]]; }
- (IBAction)toggleAutomaticDashSubstitution:(id)sender { [self setAutomaticDashSubstitutionEnabled:![self isAutomaticDashSubstitutionEnabled]]; }
- (IBAction)toggleAutomaticLinkDetection:(id)sender { [self setAutomaticLinkDetectionEnabled:![self isAutomaticLinkDetectionEnabled]]; }
- (IBAction)toggleAutomaticDataDetection:(id)sender { [self setAutomaticDataDetectionEnabled:![self isAutomaticDataDetectionEnabled]]; }
- (IBAction)toggleAutomaticSpellingCorrection:(id)sender { [self setAutomaticSpellingCorrectionEnabled:![self isAutomaticSpellingCorrectionEnabled]]; }
- (IBAction)toggleAutomaticTextReplacement:(id)sender { [self setAutomaticTextReplacementEnabled:![self isAutomaticTextReplacementEnabled]]; }
- (IBAction)toggleAutomaticTextCompletion:(id)sender { [self setAutomaticTextCompletionEnabled:![self isAutomaticTextCompletionEnabled]]; }
- (IBAction)toggleGrammarChecking:(id)sender { [self setGrammarCheckingEnabled:![self isGrammarCheckingEnabled]]; }
- (IBAction)toggleSmartInsertDelete:(id)sender { [self setSmartInsertDeleteEnabled:![self smartInsertDeleteEnabled]]; }

#pragma mark Smart insert and delete

static BOOL
is_space(unichar c)
{
    return [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c];
}

static BOOL
is_space_or_punctuation(unichar c)
{
    return is_space(c) || [[NSCharacterSet punctuationCharacterSet] characterIsMember:c];
}

/* A word deleted takes the space before it with it (or after it, at the start). */
- (NSRange)smartDeleteRangeForProposedRange:(NSRange)proposedCharRange
{
    if (![self smartInsertDeleteEnabled] || !proposedCharRange.length)
        return proposedCharRange;
    NSString *s = [self string];
    NSUInteger start = proposedCharRange.location, end = NSMaxRange(proposedCharRange), n = [s length];
    BOOL spaceBefore = start > 0 && is_space([s characterAtIndex:start - 1]);
    BOOL spaceAfter = end < n && is_space([s characterAtIndex:end]);
    BOOL edgeAfter = end >= n || is_space_or_punctuation([s characterAtIndex:end]);
    if (spaceBefore && edgeAfter)
        return NSMakeRange(start - 1, proposedCharRange.length + 1);
    if (start == 0 && spaceAfter)
        return NSMakeRange(start, proposedCharRange.length + 1);
    return proposedCharRange;
}

/* The spaces a word inserted needs to stay apart from its neighbours. */
- (void)smartInsertForString:(NSString *)pasteString replacingRange:(NSRange)charRangeToReplace
                beforeString:(NSString **)beforeString afterString:(NSString **)afterString
{
    if (beforeString)
        *beforeString = [self smartInsertBeforeStringForString:pasteString replacingRange:charRangeToReplace];
    if (afterString)
        *afterString = [self smartInsertAfterStringForString:pasteString replacingRange:charRangeToReplace];
}

- (NSString *)smartInsertBeforeStringForString:(NSString *)pasteString replacingRange:(NSRange)charRangeToReplace
{
    NSString *s = [self string];
    if (![pasteString length] || charRangeToReplace.location == 0 || charRangeToReplace.location > [s length])
        return nil;
    unichar before = [s characterAtIndex:charRangeToReplace.location - 1], first = [pasteString characterAtIndex:0];
    return is_space_or_punctuation(before) || is_space_or_punctuation(first) ? nil : @" ";
}

- (NSString *)smartInsertAfterStringForString:(NSString *)pasteString replacingRange:(NSRange)charRangeToReplace
{
    NSString *s = [self string];
    NSUInteger end = NSMaxRange(charRangeToReplace);
    if (![pasteString length] || end >= [s length])
        return nil;
    unichar after = [s characterAtIndex:end], last = [pasteString characterAtIndex:[pasteString length] - 1];
    return is_space_or_punctuation(after) || is_space_or_punctuation(last) ? nil : @" ";
}

#pragma mark Completion

/* The word part before the insertion point. */
- (NSRange)rangeForUserCompletion
{
    NSRange sel = [self selectedRange];
    NSString *s = [self string];
    NSCharacterSet *word = [NSCharacterSet alphanumericCharacterSet];
    NSUInteger start = sel.location;
    while (start > 0 && [word characterIsMember:[s characterAtIndex:start - 1]])
        start--;
    if (start == sel.location)
        return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(start, NSMaxRange(sel) - start);
}

- (NSArray<NSString *> *)completionsForPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)index
{
    if (index)
        *index = 0;
    NSArray *words = [[NSSpellChecker sharedSpellChecker] completionsForPartialWordRange:charRange inString:[self string]
                                                                                language:nil
                                                                  inSpellDocumentWithTag:[self spellCheckerDocumentTag]];
    id d = [self delegate];
    if ([d respondsToSelector:@selector(textView:completions:forPartialWordRange:indexOfSelectedItem:)])
        words = [d textView:self completions:words ?: @[] forPartialWordRange:charRange indexOfSelectedItem:index];
    return words;
}

- (void)insertCompletion:(NSString *)word forPartialWordRange:(NSRange)charRange movement:(NSInteger)movement isFinal:(BOOL)flag
{
    if (!word || ![self shouldChangeTextInRange:charRange replacementString:word])
        return;
    [self replaceCharactersInRange:charRange withString:word];
    [self setSelectedRange:NSMakeRange(charRange.location + [word length], 0)];
    [self didChangeText];
}

#pragma mark Text checking

- (void)checkTextInRange:(NSRange)range types:(NSTextCheckingTypes)checkingTypes options:(NSDictionary<NSTextCheckingOptionKey, id> *)options
{
    NSSpellChecker *checker = [NSSpellChecker sharedSpellChecker];
    NSOrthography *orthography = nil;
    NSInteger wordCount = 0;
    NSArray *results = [checker checkString:[self string] range:range types:checkingTypes options:options
                     inSpellDocumentWithTag:[self spellCheckerDocumentTag] orthography:&orthography wordCount:&wordCount];
    [self handleTextCheckingResults:results ?: @[] forRange:range types:checkingTypes options:options ?: @{} orthography:orthography
                          wordCount:wordCount];
}

- (void)checkTextInSelection:(id)sender
{
    [self checkTextInRange:[self selectedRange] types:[self enabledTextCheckingTypes] options:@{}];
}

- (void)checkTextInDocument:(id)sender
{
    [self checkTextInRange:NSMakeRange(0, [[self string] length]) types:[self enabledTextCheckingTypes] options:@{}];
}

/* Corrections and replacements applied (last first), links and dates made links. */
- (void)handleTextCheckingResults:(NSArray<NSTextCheckingResult *> *)results forRange:(NSRange)range types:(NSTextCheckingTypes)checkingTypes
                          options:(NSDictionary<NSTextCheckingOptionKey, id> *)options orthography:(NSOrthography *)orthography
                        wordCount:(NSInteger)wordCount
{
    for (NSTextCheckingResult *r in [results reverseObjectEnumerator]) {
        switch (r.resultType) {
        case NSTextCheckingTypeCorrection:
        case NSTextCheckingTypeReplacement:
        case NSTextCheckingTypeQuote:
        case NSTextCheckingTypeDash:
            if (r.replacementString && [self shouldChangeTextInRange:r.range replacementString:r.replacementString]) {
                [self replaceCharactersInRange:r.range withString:r.replacementString];
                [self didChangeText];
            }
            break;
        case NSTextCheckingTypeLink:
            if (r.URL)
                [[self textStorage] addAttribute:NSLinkAttributeName value:r.URL range:r.range];
            break;
        case NSTextCheckingTypeSpelling:
            [self setSpellingState:NSSpellingStateSpellingFlag range:r.range];
            break;
        case NSTextCheckingTypeGrammar:
            [self setSpellingState:NSSpellingStateGrammarFlag range:r.range];
            break;
        default: break;
        }
    }
}

/* (kept for drawing marks, apart from the layout manager's temporary attributes, as
   Apple's TextKit 2 views keep them) */
static char spelling_key;
- (void)setSpellingState:(NSInteger)value range:(NSRange)charRange
{
    NSMutableDictionary *states = objc_getAssociatedObject(self, &spelling_key);
    if (!states) {
        states = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &spelling_key, states, OBJC_ASSOCIATION_RETAIN);
    }
    states[[NSValue valueWithRange:charRange]] = @(value);
    [self setNeedsDisplay:YES];
}

- (BOOL)performValidatedReplacementInRange:(NSRange)range withAttributedString:(NSAttributedString *)attributedString
{
    if (![self shouldChangeTextInRange:range replacementString:[attributedString string]])
        return NO;
    [[self textStorage] replaceCharactersInRange:range withAttributedString:attributedString];
    [self didChangeText];
    return YES;
}

#pragma mark Links

- (void)clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(textView:clickedOnLink:atIndex:)] && [d textView:self clickedOnLink:link atIndex:charIndex])
        return;
    NSURL *url = [link isKindOfClass:[NSURL class]] ? link : [link isKindOfClass:[NSString class]] ? [NSURL URLWithString:link] : nil;
    if (url)
        [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark Panels

/* A link for the selection, asked for in a sheet. */
- (IBAction)orderFrontLinkPanel:(id)sender
{
    NSRange r = [self selectedRange];
    if (!r.length)
        return;
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Add Link"];
    NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)] autorelease];
    [field setPlaceholderString:@"https://"];
    id existing = [[self textStorage] attribute:NSLinkAttributeName atIndex:r.location effectiveRange:NULL];
    if (existing)
        [field setStringValue:[existing description]];
    [alert setAccessoryView:field];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;
    NSURL *url = [NSURL URLWithString:[field stringValue]];
    set_value(self, NSLinkAttributeName, [[field stringValue] length] ? (id)url : nil);
}

/* A bulleted list for the selected paragraphs (the list panel's default style). */
- (IBAction)orderFrontListPanel:(id)sender
{
    NSTextList *list = [[[NSTextList alloc] initWithMarkerFormat:NSTextListMarkerDisc options:0] autorelease];
    NSString *s = [self string];
    NSRange paras = [s paragraphRangeForRange:[self selectedRange]];
    NSMutableParagraphStyle *ps = [[(current(self, NSParagraphStyleAttributeName) ?: [NSParagraphStyle defaultParagraphStyle]) mutableCopy] autorelease];
    [ps setTextLists:@[ list ]];
    if (!paras.length || ![self shouldChangeTextInRange:paras replacementString:nil])
        return;
    [[self textStorage] addAttribute:NSParagraphStyleAttributeName value:ps range:paras];
    [self didChangeText];
}

/* (spacing and substitutions are set through the Format menu's own items) */
- (IBAction)orderFrontSpacingPanel:(id)sender {}
- (IBAction)orderFrontSubstitutionsPanel:(id)sender {}

/* A two-by-two table at the insertion point (the table panel's default). */
- (IBAction)orderFrontTablePanel:(id)sender
{
    NSTextTable *table = [[[NSTextTable alloc] init] autorelease];
    [table setNumberOfColumns:2];
    NSMutableAttributedString *cells = [[[NSMutableAttributedString alloc] init] autorelease];
    for (NSInteger row = 0; row < 2; row++)
        for (NSInteger col = 0; col < 2; col++) {
            NSTextTableBlock *block = [[[NSTextTableBlock alloc] initWithTable:table startingRow:row rowSpan:1 startingColumn:col columnSpan:1] autorelease];
            [block setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];
            NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
            [ps setTextBlocks:@[ block ]];
            [cells appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSParagraphStyleAttributeName : ps}] autorelease]];
        }
    [self insertText:cells replacementRange:[self selectedRange]];
}

- (IBAction)orderFrontSharingServicePicker:(id)sender
{
    NSRange r = [self selectedRange];
    NSArray *items = r.length ? @[ [[self textStorage] attributedSubstringFromRange:r] ] : @[ [[[self textStorage] copy] autorelease] ];
    NSSharingServicePicker *picker = [[[NSSharingServicePicker alloc] initWithItems:items] autorelease];
    [picker showRelativeToRect:[self firstRectForCharacterRange:r actualRange:NULL] ofView:self preferredEdge:NSRectEdgeMinY];
}

#pragma mark Speaking

static char speech_key;
- (IBAction)startSpeaking:(id)sender
{
    NSRange r = [self selectedRange];
    NSString *text = r.length ? [[self string] substringWithRange:r] : [self string];
    NSSpeechSynthesizer *s = objc_getAssociatedObject(self, &speech_key);
    if (!s) {
        s = [[[NSSpeechSynthesizer alloc] init] autorelease];
        objc_setAssociatedObject(self, &speech_key, s, OBJC_ASSOCIATION_RETAIN);
    }
    [s startSpeakingString:text];
}

- (IBAction)stopSpeaking:(id)sender { [objc_getAssociatedObject(self, &speech_key) stopSpeaking]; }

#pragma mark Dragging

/* As Apple's: the text, rich text, file, image, URL, color, font and ruler types. */
- (NSArray<NSPasteboardType> *)acceptableDragTypes
{
    return @[
        @"NeXT RTFD pasteboard type", @"NeXT Rich Text Format v1.0 pasteboard type", @"Apple HTML pasteboard type", @"NSFilenamesPboardType",
        @"com.apple.NSFilePromiseItemMetaData", @"dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu",
        @"com.apple.pasteboard.promised-file-content-type", @"CorePasteboardFlavorType 0x6D6F6F76", @"Apple PDF pasteboard type",
        @"NeXT TIFF v4.0 pasteboard type", @"Apple PICT pasteboard type", @"Apple PNG pasteboard type", @"WebURLsWithTitlesPboardType",
        @"public.url", @"Apple URL pasteboard type", @"NSStringPboardType", @"NSColor pasteboard type", @"NeXT font pasteboard type",
        @"NeXT ruler pasteboard type"
    ];
}

- (void)updateDragTypeRegistration
{
    if ([self isEditable])
        [self registerForDraggedTypes:[self acceptableDragTypes]];
    else
        [self unregisterDraggedTypes];
}

- (NSDragOperation)dragOperationForDraggingInfo:(id<NSDraggingInfo>)dragInfo type:(NSPasteboardType)type
{
    if (![self isEditable])
        return NSDragOperationNone;
    return [dragInfo draggingSource] == self ? NSDragOperationMove : NSDragOperationCopy;
}

- (void)cleanUpAfterDragOperation {}

- (NSImage *)dragImageForSelectionWithEvent:(NSEvent *)event origin:(NSPointPointer)origin
{
    NSRange r = [self selectedRange];
    if (!r.length)
        return nil;
    NSRect rect = [self firstRectForCharacterRange:r actualRange:NULL];
    rect = [self convertRect:[[self window] convertRectFromScreen:rect] fromView:nil];
    if (origin)
        *origin = NSMakePoint(NSMinX(rect), NSMaxY(rect));
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:rect];
    [self cacheDisplayInRect:rect toBitmapImageRep:rep];
    NSImage *image = [[[NSImage alloc] initWithSize:rect.size] autorelease];
    [image addRepresentation:rep];
    return image;
}

- (BOOL)dragSelectionWithEvent:(NSEvent *)event offset:(NSSize)mouseOffset slideBack:(BOOL)slideBack
{
    NSRange r = [self selectedRange];
    if (!r.length)
        return NO;
    NSDraggingItem *item = [[[NSDraggingItem alloc] initWithPasteboardWriter:[[self textStorage] attributedSubstringFromRange:r]] autorelease];
    NSPoint origin = NSZeroPoint;
    NSImage *image = [self dragImageForSelectionWithEvent:event origin:&origin];
    [item setDraggingFrame:NSMakeRect(origin.x, origin.y - [image size].height, [image size].width, [image size].height) contents:image];
    return [self beginDraggingSessionWithItems:@[ item ] event:event source:(id<NSDraggingSource>)self] != nil;
}

#pragma mark Quick Look

/* The selection's file attachments. */
- (NSArray *)quickLookPreviewableItemsInRanges:(NSArray<NSValue *> *)ranges
{
    NSMutableArray *items = [NSMutableArray array];
    for (NSValue *v in ranges)
        [[self textStorage] enumerateAttribute:NSAttachmentAttributeName inRange:[v rangeValue] options:0
                                    usingBlock:^(NSTextAttachment *a, NSRange r, BOOL *stop) {
                                        NSURL *url = [[a fileWrapper] filename] ? [NSURL fileURLWithPath:[[a fileWrapper] filename]] : nil;
                                        if (url)
                                            [items addObject:url];
                                    }];
    return items;
}

- (IBAction)toggleQuickLookPreviewPanel:(id)sender {}
- (void)updateQuickLookPreviewPanel {}

#pragma mark Highlights and other settings

static char highlight_key, rollover_key, prediction_key, math_key, writing_key;

- (NSDictionary<NSAttributedStringKey, id> *)textHighlightAttributes
{
    NSDictionary *d = objc_getAssociatedObject(self, &highlight_key);
    return d ?: @{NSForegroundColorAttributeName : [NSColor controlAccentColor],
                  @"NSTextHighlightOutlineColor" : [NSColor secondarySystemFillColor]};
}

- (void)setTextHighlightAttributes:(NSDictionary<NSAttributedStringKey, id> *)attrs
{
    objc_setAssociatedObject(self, &highlight_key, [[attrs copy] autorelease], OBJC_ASSOCIATION_RETAIN);
}

/* The highlighted text's background, in the highlight colour at a low opacity. */
- (void)drawTextHighlightBackgroundForTextRange:(NSTextRange *)textRange origin:(NSPoint)origin
{
    NSColor *c = [self textHighlightAttributes][NSForegroundColorAttributeName] ?: [NSColor controlAccentColor];
    [[c colorWithAlphaComponent:0.2] setFill];
    NSRectFillUsingOperation([self visibleRect], NSCompositingOperationSourceOver);
}

- (BOOL)usesRolloverButtonForSelection
{
    NSNumber *n = objc_getAssociatedObject(self, &rollover_key);
    return n ? [n boolValue] : YES;
}
- (void)setUsesRolloverButtonForSelection:(BOOL)flag { objc_setAssociatedObject(self, &rollover_key, @(flag), OBJC_ASSOCIATION_RETAIN); }

- (NSTextInputTraitType)inlinePredictionType { return [objc_getAssociatedObject(self, &prediction_key) integerValue]; }
- (void)setInlinePredictionType:(NSTextInputTraitType)t { objc_setAssociatedObject(self, &prediction_key, @(t), OBJC_ASSOCIATION_RETAIN); }
- (NSTextInputTraitType)mathExpressionCompletionType { return [objc_getAssociatedObject(self, &math_key) integerValue]; }
- (void)setMathExpressionCompletionType:(NSTextInputTraitType)t { objc_setAssociatedObject(self, &math_key, @(t), OBJC_ASSOCIATION_RETAIN); }
- (NSWritingToolsResultOptions)allowedWritingToolsResultOptions { return [objc_getAssociatedObject(self, &writing_key) unsignedIntegerValue]; }
- (void)setAllowedWritingToolsResultOptions:(NSWritingToolsResultOptions)o
{
    objc_setAssociatedObject(self, &writing_key, @(o), OBJC_ASSOCIATION_RETAIN);
}

#pragma mark Touch Bar and candidates

- (NSCandidateListTouchBarItem *)candidateListTouchBarItem { return nil; }
- (void)updateTextTouchBarItems {}
- (void)updateTouchBarItemIdentifiers {}
- (void)updateCandidates {}
- (void)updateFontPanel
{
    NSFont *f = current(self, NSFontAttributeName);
    if (f && [self usesFontPanel])
        [[NSFontManager sharedFontManager] setSelectedFont:f isMultiple:NO];
}

#pragma mark Class

+ (NSTextView *)fieldEditor
{
    NSTextView *fe = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [fe setFieldEditor:YES];
    return fe;
}

+ (void)registerForServices {}
+ (BOOL)stronglyReferencesTextStorage { return YES; }

@end

#pragma mark - NSText

/* NSText's actions: an NSTextView's (which every NSText made through +alloc is), else
   what the abstract text API allows. */
static IMP
text_view_imp(id self, SEL sel)
{
    if (![self isKindOfClass:[NSTextView class]])
        return NULL;
    IMP imp = class_getMethodImplementation([NSTextView class], sel);
    /* (never NSText's own: that would come straight back here) */
    return imp == class_getMethodImplementation([NSText class], sel) ? NULL : imp;
}

#define FORWARD_ACTION(sel)                                  \
    -(IBAction)sel : (id)sender                               \
    {                                                         \
        IMP imp = text_view_imp(self, _cmd);                  \
        if (imp)                                              \
            ((void (*)(id, SEL, id))imp)(self, _cmd, sender); \
    }

@implementation NSText (FinchActions)

FORWARD_ACTION(alignCenter)
FORWARD_ACTION(alignLeft)
FORWARD_ACTION(alignRight)
FORWARD_ACTION(changeFont)
FORWARD_ACTION(checkSpelling)
FORWARD_ACTION(copy)
FORWARD_ACTION(copyFont)
FORWARD_ACTION(copyRuler)
FORWARD_ACTION(cut)
FORWARD_ACTION(delete)
FORWARD_ACTION(paste)
FORWARD_ACTION(pasteFont)
FORWARD_ACTION(pasteRuler)
FORWARD_ACTION(selectAll)
FORWARD_ACTION(showGuessPanel)
FORWARD_ACTION(subscript)
FORWARD_ACTION(superscript)
FORWARD_ACTION(toggleRuler)
FORWARD_ACTION(underline)
FORWARD_ACTION(unscript)

- (void)sizeToFit
{
    IMP imp = text_view_imp(self, _cmd);
    if (imp)
        ((void (*)(id, SEL))imp)(self, _cmd);
}

- (void)scrollRangeToVisible:(NSRange)range
{
    IMP imp = text_view_imp(self, _cmd);
    if (imp)
        ((void (*)(id, SEL, NSRange))imp)(self, _cmd, range);
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string
{
    IMP imp = text_view_imp(self, _cmd);
    if (imp)
        ((void (*)(id, SEL, NSRange, id))imp)(self, _cmd, range, string);
}

- (void)replaceCharactersInRange:(NSRange)range withRTF:(NSData *)rtfData
{
    NSAttributedString *a = [[[NSAttributedString alloc] initWithRTF:rtfData documentAttributes:NULL] autorelease];
    if ([self isKindOfClass:[NSTextView class]] && a)
        [[(NSTextView *)self textStorage] replaceCharactersInRange:range withAttributedString:a];
}

- (void)replaceCharactersInRange:(NSRange)range withRTFD:(NSData *)rtfdData
{
    NSAttributedString *a = [[[NSAttributedString alloc] initWithRTFD:rtfdData documentAttributes:NULL] autorelease];
    if ([self isKindOfClass:[NSTextView class]] && a)
        [[(NSTextView *)self textStorage] replaceCharactersInRange:range withAttributedString:a];
}

- (NSData *)RTFFromRange:(NSRange)range
{
    if (![self isKindOfClass:[NSTextView class]])
        return nil;
    return [[(NSTextView *)self textStorage] RTFFromRange:range documentAttributes:@{}];
}

- (NSData *)RTFDFromRange:(NSRange)range
{
    if (![self isKindOfClass:[NSTextView class]])
        return nil;
    return [[(NSTextView *)self textStorage] RTFDFromRange:range documentAttributes:@{}];
}

- (BOOL)writeRTFDToFile:(NSString *)path atomically:(BOOL)flag
{
    NSData *d = [self RTFDFromRange:NSMakeRange(0, [[self string] length])];
    NSFileWrapper *w = d ? [[[NSFileWrapper alloc] initWithSerializedRepresentation:d] autorelease] : nil;
    return w && [w writeToURL:[NSURL fileURLWithPath:path] options:flag ? NSFileWrapperWritingAtomic : 0 originalContentsURL:nil error:NULL];
}

- (BOOL)readRTFDFromFile:(NSString *)path
{
    NSAttributedString *a = [[[NSAttributedString alloc] initWithURL:[NSURL fileURLWithPath:path] options:@{} documentAttributes:NULL
                                                               error:NULL] autorelease];
    if (!a || ![self isKindOfClass:[NSTextView class]])
        return NO;
    [[(NSTextView *)self textStorage] setAttributedString:a];
    return YES;
}

- (void)setFont:(NSFont *)font range:(NSRange)range
{
    IMP imp = text_view_imp(self, _cmd);
    if (imp)
        ((void (*)(id, SEL, id, NSRange))imp)(self, _cmd, font, range);
}

- (void)setTextColor:(NSColor *)color range:(NSRange)range
{
    IMP imp = text_view_imp(self, _cmd);
    if (imp)
        ((void (*)(id, SEL, id, NSRange))imp)(self, _cmd, color, range);
}

@end

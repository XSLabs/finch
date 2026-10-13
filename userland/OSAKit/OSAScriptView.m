/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAKit: the script view and its text storage, Finch's. The view is a text view whose
 * storage is an OSAScriptTextStorage: whatever is typed is uncompiled text (AppleScript's
 * "new text" style), Return keeps the line's indentation, Enter compiles, and tab stops
 * follow the tab width. The braces helpers match (), {}, [] and «».
 */
#import "OSAKit_Finch.h"

/* ---- text storage ---- */

@implementation OSATextStorage {
    NSMutableAttributedString *_s;
}

+ (NSFont *)defaultPlainTextFont { return [NSFont userFixedPitchFontOfSize:12]; }

+ (void)sourceStylesChanged { [OSAScript sourceStylesChanged]; }

- (instancetype)init { return [self initWithOwnedMutableAttributedString:[NSMutableAttributedString new]]; }

- (instancetype)initWithOwnedMutableAttributedString:(NSMutableAttributedString *)s
{
    if ((self = [super init])) {
        _s = s ?: [NSMutableAttributedString new];
        _usesTabs = YES;
        _tabWidth = 4;
        _wrapsLines = YES;
        _indentsWrappedLines = YES;
        _indentWidth = 4;
    }
    return self;
}

- (instancetype)initWithString:(NSString *)str
{
    return [self initWithOwnedMutableAttributedString:[[NSMutableAttributedString alloc] initWithString:str ?: @""]];
}

- (instancetype)initWithString:(NSString *)str attributes:(NSDictionary *)attrs
{
    return [self initWithOwnedMutableAttributedString:[[NSMutableAttributedString alloc] initWithString:str ?: @"" attributes:attrs]];
}

- (instancetype)initWithAttributedString:(NSAttributedString *)a
{
    return [self initWithOwnedMutableAttributedString:a ? [a mutableCopy] : [NSMutableAttributedString new]];
}

- (NSString *)string { return _s.string; }
- (NSUInteger)length { return _s.length; }

- (NSDictionary *)attributesAtIndex:(NSUInteger)i effectiveRange:(NSRangePointer)r
{
    return [_s attributesAtIndex:i effectiveRange:r];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str
{
    NSUInteger before = _s.length;
    [_s replaceCharactersInRange:range withString:str];
    [self edited:NSTextStorageEditedCharacters | NSTextStorageEditedAttributes range:range changeInLength:(NSInteger)_s.length - (NSInteger)before];
}

- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range
{
    [_s setAttributes:attrs range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (NSAttributedString *)contents { return [_s copy]; }

- (void)setContents:(NSAttributedString *)contents
{
    [self beginEditing];
    [self replaceCharactersInRange:NSMakeRange(0, self.length) withAttributedString:contents ?: [NSAttributedString new]];
    [self endEditing];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)s withUndoManager:(NSUndoManager *)undo
{
    if (undo) {
        NSString *old = [self.string substringWithRange:range];
        [[undo prepareWithInvocationTarget:self] replaceCharactersInRange:NSMakeRange(range.location, s.length) withString:old withUndoManager:undo];
    }
    [self replaceCharactersInRange:range withString:s];
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)s withUndoManager:(NSUndoManager *)undo
{
    if (undo) {
        NSAttributedString *old = [self attributedSubstringFromRange:range];
        [[undo prepareWithInvocationTarget:self] replaceCharactersInRange:NSMakeRange(range.location, s.length)
                                                      withAttributedString:old
                                                           withUndoManager:undo];
    }
    [self replaceCharactersInRange:range withAttributedString:s];
}

- (void)setTabWidth:(NSUInteger)w
{
    _tabWidth = w ?: 4;
    [self fixTabStopsInRange:NSMakeRange(0, self.length)];
}

/* tab stops every tabWidth spaces of the text's font */
- (void)fixTabStopsInRange:(NSRange)range
{
    if (!self.length)
        return;
    NSFont *f = [self attribute:NSFontAttributeName atIndex:MIN(range.location, self.length - 1) effectiveRange:NULL] ?: [OSATextStorage defaultPlainTextFont];
    CGFloat space = [@" " sizeWithAttributes:@{NSFontAttributeName : f}].width;
    NSMutableParagraphStyle *p = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    p.tabStops = @[];
    p.defaultTabInterval = space * (CGFloat)(_tabWidth ?: 4);
    [_s addAttribute:NSParagraphStyleAttributeName value:p range:range];
}

- (void)fixWrappedLineIndentsInRange:(NSRange)range
{
}

- (void)processEditing
{
    NSRange r = [self.string paragraphRangeForRange:self.editedRange];
    if (r.length)
        [self fixTabStopsInRange:r];
    [super processEditing];
}
@end

@implementation OSAScriptTextStorage

- (instancetype)initWithController:(OSAScriptController *)controller
{
    if ((self = [self init]))
        _controller = controller;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (NSUndoManager *)undoManager { return [_controller undoManager]; }

/* typed text is uncompiled */
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str
{
    [super replaceCharactersInRange:range withString:str];
    if (str.length)
        [self setAttributes:[OSAScript defaultTextAttributes] range:NSMakeRange(range.location, str.length)];
    [_controller _sourceEdited];
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)s
{
    [super replaceCharactersInRange:range withAttributedString:s];
}
@end

/* ---- the view ---- */

@interface OSAScriptView ()
@end

@implementation OSAScriptView {
    __weak id _controller;
    BOOL _usesScriptAssistant;
}

- (void)_commonInit
{
    if (![self.textStorage isKindOfClass:[OSAScriptTextStorage class]])
        [self replaceTextStorage:[[OSAScriptTextStorage alloc] initWithController:_controller]];
    self.richText = YES;
    self.allowsUndo = YES;
    self.automaticQuoteSubstitutionEnabled = NO;
    self.automaticDashSubstitutionEnabled = NO;
    self.automaticTextReplacementEnabled = NO;
    self.automaticSpellingCorrectionEnabled = NO;
    self.continuousSpellCheckingEnabled = NO;
    self.smartInsertDeleteEnabled = NO;
    [super setTypingAttributes:[OSAScript defaultTextAttributes]];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self _commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self _commonInit];
    return self;
}

- (void)awakeFromNib
{
    if ([NSTextView instancesRespondToSelector:@selector(awakeFromNib)])
        [super awakeFromNib];
}

- (void)replaceTextStorage:(NSTextStorage *)storage
{
    NSAttributedString *old = self.textStorage ? [self.textStorage copy] : nil;
    [self.layoutManager replaceTextStorage:storage];
    if (old.length && !storage.length)
        [storage setAttributedString:old];
}

- (id)controller { return _controller; }

- (void)setController:(id)controller
{
    _controller = controller;
    if ([self.textStorage isKindOfClass:[OSAScriptTextStorage class]])
        ((OSAScriptTextStorage *)self.textStorage).controller = controller;
}

/* new text is always uncompiled, whatever it's next to */
- (void)setTypingAttributes:(NSDictionary *)attrs { [super setTypingAttributes:[OSAScript defaultTextAttributes]]; }

- (NSString *)source { return self.string; }

- (void)setSource:(NSString *)source
{
    NSTextStorage *ts = self.textStorage;
    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(0, ts.length)
            withAttributedString:[[NSAttributedString alloc] initWithString:source ?: @"" attributes:[OSAScript defaultTextAttributes]]];
    [ts endEditing];
}

- (OSATextStorage *)_osaStorage { return [self.textStorage isKindOfClass:[OSATextStorage class]] ? (OSATextStorage *)self.textStorage : nil; }
- (BOOL)usesTabs { return self._osaStorage ? self._osaStorage.usesTabs : YES; }
- (void)setUsesTabs:(BOOL)v { self._osaStorage.usesTabs = v; }
- (NSUInteger)tabWidth { return self._osaStorage ? self._osaStorage.tabWidth : 4; }
- (void)setTabWidth:(NSUInteger)v { self._osaStorage.tabWidth = v; }
- (BOOL)wrapsLines { return self._osaStorage ? self._osaStorage.wrapsLines : YES; }

- (void)setWrapsLines:(BOOL)v
{
    self._osaStorage.wrapsLines = v;
    NSTextContainer *c = self.textContainer;
    if (v) {
        c.widthTracksTextView = YES;
        self.horizontallyResizable = NO;
    } else {
        c.widthTracksTextView = NO;
        c.containerSize = NSMakeSize(1e7, c.containerSize.height);
        self.horizontallyResizable = YES;
    }
}

- (BOOL)indentsWrappedLines { return self._osaStorage ? self._osaStorage.indentsWrappedLines : YES; }
- (void)setIndentsWrappedLines:(BOOL)v { self._osaStorage.indentsWrappedLines = v; }
- (NSUInteger)indentWidth { return self._osaStorage ? self._osaStorage.indentWidth : 4; }
- (void)setIndentWidth:(NSUInteger)v { self._osaStorage.indentWidth = v; }
- (BOOL)usesScriptAssistant { return _usesScriptAssistant; }
- (void)setUsesScriptAssistant:(BOOL)v { _usesScriptAssistant = v; }
- (id)scriptAssistant { return nil; }

/* Return keeps the current line's leading tabs and spaces */
- (void)insertNewline:(id)sender
{
    NSString *s = self.string;
    NSRange sel = self.selectedRange;
    NSRange line = [s lineRangeForRange:NSMakeRange(sel.location, 0)];
    NSUInteger i = line.location;
    while (i < sel.location && ([s characterAtIndex:i] == '\t' || [s characterAtIndex:i] == ' '))
        i++;
    NSString *indent = [s substringWithRange:NSMakeRange(line.location, i - line.location)];
    [super insertNewline:sender];
    if (indent.length)
        [self insertText:indent replacementRange:self.selectedRange];
}

- (void)autoIndent:(id)sender {}

/* Enter (on the keypad, or fn-Return) compiles */
- (void)keyDown:(NSEvent *)event
{
    if (event.keyCode == 76 && !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) {
        [self compileScript:self];
        return;
    }
    [super keyDown:event];
}

- (void)compileScript:(id)sender { [_controller compileScript:sender]; }
- (void)runScript:(id)sender { [_controller runScript:sender]; }
- (void)stopScript:(id)sender { [_controller stopScript:sender]; }
- (void)recordScript:(id)sender { [_controller recordScript:sender]; }

- (void)complete:(id)sender
{
    if (!_usesScriptAssistant) {
        NSBeep();
        return;
    }
    [super complete:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = item.action;
    if (a == @selector(compileScript:) || a == @selector(runScript:))
        return _controller != nil && [_controller scriptState] == OSAScriptStopped;
    if (a == @selector(stopScript:))
        return _controller != nil && [_controller scriptState] != OSAScriptStopped;
    if (a == @selector(recordScript:))
        return NO;
    return [super validateMenuItem:item];
}

- (NSArray *)readablePasteboardTypes { return @[ NSPasteboardTypeString ]; }

- (void)copyFont:(id)sender { [super copyFont:sender]; }
@end

/* ---- braces ---- */

static NSString *const opening = @"({[«", *const closing = @")}]»";

BOOL
OSA_isOpeningBrace(unichar c)
{
    return [opening rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

BOOL
OSA_isClosingBrace(unichar c)
{
    return [closing rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

/* the brace matching the one at location (a one-character range), or {NSNotFound, 0} */
NSRange
OSA_findMatchingBraceForRangeInString(NSUInteger location, NSUInteger length, NSString *s)
{
    if (location >= s.length)
        return NSMakeRange(NSNotFound, 0);
    unichar c = [s characterAtIndex:location];
    BOOL forward = OSA_isOpeningBrace(c);
    if (!forward && !OSA_isClosingBrace(c))
        return NSMakeRange(NSNotFound, 0);
    NSMutableArray<NSNumber *> *stack = [NSMutableArray arrayWithObject:@(c)];
    NSInteger step = forward ? 1 : -1;
    NSInteger i = forward ? (NSInteger)(location + MAX(length, (NSUInteger)1)) : (NSInteger)location - 1;
    for (; i >= 0 && i < (NSInteger)s.length; i += step) {
        unichar d = [s characterAtIndex:(NSUInteger)i];
        BOOL same = forward ? OSA_isOpeningBrace(d) : OSA_isClosingBrace(d);
        BOOL other = forward ? OSA_isClosingBrace(d) : OSA_isOpeningBrace(d);
        if (same)
            [stack addObject:@(d)];
        else if (other) {
            unichar top = (unichar)stack.lastObject.unsignedShortValue;
            NSUInteger k = forward ? [opening rangeOfString:[NSString stringWithCharacters:&top length:1]].location
                                   : [closing rangeOfString:[NSString stringWithCharacters:&top length:1]].location;
            unichar want = [(forward ? closing : opening) characterAtIndex:k];
            if (d != want)
                return NSMakeRange(NSNotFound, 0);
            [stack removeLastObject];
            if (!stack.count)
                return NSMakeRange((NSUInteger)i, 1);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

/* Carbon TextEdit data ('TEXT' and its 'styl'): the text, in the default style */
NSAttributedString *
OSA_attributedStringWithCarbonTEData(NSData *text, NSData *styl)
{
    if (!text || !styl)
        return nil;
    NSString *s = [[NSString alloc] initWithData:text encoding:NSMacOSRomanStringEncoding] ?: @"";
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return [[NSMutableAttributedString alloc] initWithString:s attributes:[OSAScript defaultTextAttributes]];
}

BOOL
OSA_carbonTEDataFromAttributedString(NSAttributedString *a, NSData **text, NSData **styl)
{
    NSString *s = [a.string stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if (text)
        *text = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
    if (styl)
        *styl = [NSData data];
    return YES;
}

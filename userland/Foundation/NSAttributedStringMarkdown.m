/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The Objective-C Markdown option, source-position and presentation-intent
 * value classes. The Markdown constructors stay out until Finch has a full
 * CommonMark parser.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

@interface NSAttributedStringMarkdownParsingOptions () {
    BOOL _allowsExtendedAttributes, _appliesSourcePositionAttributes;
    NSAttributedStringMarkdownInterpretedSyntax _interpretedSyntax;
    NSAttributedStringMarkdownParsingFailurePolicy _failurePolicy;
    NSString *_languageCode;
}
@end

@implementation NSAttributedStringMarkdownParsingOptions

- (instancetype)init
{
    if ((self = [super init])) {
        _interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxFull;
        _failurePolicy = NSAttributedStringMarkdownParsingFailureReturnError;
    }
    return self;
}

- (BOOL)allowsExtendedAttributes { return _allowsExtendedAttributes; }
- (void)setAllowsExtendedAttributes:(BOOL)value { _allowsExtendedAttributes = value; }
- (NSAttributedStringMarkdownInterpretedSyntax)interpretedSyntax { return _interpretedSyntax; }
- (void)setInterpretedSyntax:(NSAttributedStringMarkdownInterpretedSyntax)value { _interpretedSyntax = value; }
- (NSAttributedStringMarkdownParsingFailurePolicy)failurePolicy { return _failurePolicy; }
- (void)setFailurePolicy:(NSAttributedStringMarkdownParsingFailurePolicy)value { _failurePolicy = value; }
- (NSString *)languageCode { return _languageCode; }
- (void)setLanguageCode:(NSString *)value
{
    NSString *old = _languageCode;
    _languageCode = [value copy];
    [old release];
}
- (BOOL)appliesSourcePositionAttributes { return _appliesSourcePositionAttributes; }
- (void)setAppliesSourcePositionAttributes:(BOOL)value { _appliesSourcePositionAttributes = value; }

- (void)dealloc
{
    [_languageCode release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSAttributedStringMarkdownParsingOptions *copy = [[[self class] allocWithZone:zone] init];
    copy->_allowsExtendedAttributes = _allowsExtendedAttributes;
    copy->_appliesSourcePositionAttributes = _appliesSourcePositionAttributes;
    copy->_interpretedSyntax = _interpretedSyntax;
    copy->_failurePolicy = _failurePolicy;
    copy->_languageCode = [_languageCode copy];
    return copy;
}

@end

@interface NSAttributedStringMarkdownSourcePosition () {
    NSInteger _startLine, _startColumn, _endLine, _endColumn;
}
@end

static NSUInteger
utf8_width(NSString *string, NSUInteger index, NSUInteger *utf16Width)
{
    unichar c = [string characterAtIndex:index];
    if (c >= 0xd800 && c <= 0xdbff && index + 1 < [string length]) {
        unichar low = [string characterAtIndex:index + 1];
        if (low >= 0xdc00 && low <= 0xdfff) {
            *utf16Width = 2;
            return 4;
        }
    }
    *utf16Width = 1;
    if (c <= 0x7f) return 1;
    if (c <= 0x7ff) return 2;
    return 3;
}

static BOOL
source_offset(NSString *string, NSInteger line, NSInteger column, NSUInteger *utf16Offset, NSUInteger *utf8Offset)
{
    if (line < 1 || column < 1)
        return NO;
    NSUInteger currentLine = 1, utf16 = 0, utf8 = 0, lineStart = 0;
    for (NSUInteger i = 0; i < [string length];) {
        if (currentLine == (NSUInteger)line && utf8 - lineStart + 1 >= (NSUInteger)column) {
            *utf16Offset = utf16;
            *utf8Offset = utf8;
            return YES;
        }
        NSUInteger width16;
        NSUInteger width8 = utf8_width(string, i, &width16);
        unichar c = [string characterAtIndex:i];
        utf8 += width8;
        utf16 += width16;
        i += width16;
        if (c == '\n') {
            currentLine++;
            lineStart = utf8;
        }
    }
    if (currentLine != (NSUInteger)line || utf8 - lineStart + 1 < (NSUInteger)column)
        return NO;
    *utf16Offset = utf16;
    *utf8Offset = utf8;
    return YES;
}

static NSUInteger
utf16_length_of_codepoint_at_utf8_offset(NSString *string, NSUInteger byteOffset, NSUInteger *nextByteOffset)
{
    NSUInteger utf8 = 0;
    for (NSUInteger i = 0; i < [string length];) {
        NSUInteger width16;
        NSUInteger width8 = utf8_width(string, i, &width16);
        if (utf8 + width8 > byteOffset) {
            *nextByteOffset = utf8 + width8;
            return width16;
        }
        utf8 += width8;
        i += width16;
    }
    *nextByteOffset = utf8;
    return 0;
}

@implementation NSAttributedStringMarkdownSourcePosition

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithStartLine:(NSInteger)startLine startColumn:(NSInteger)startColumn
                           endLine:(NSInteger)endLine endColumn:(NSInteger)endColumn
{
    if ((self = [super init])) {
        _startLine = startLine;
        _startColumn = startColumn;
        _endLine = endLine;
        _endColumn = endColumn;
    }
    return self;
}

- (NSInteger)startLine { return _startLine; }
- (NSInteger)startColumn { return _startColumn; }
- (NSInteger)endLine { return _endLine; }
- (NSInteger)endColumn { return _endColumn; }

- (NSRange)rangeInString:(NSString *)string
{
    NSUInteger start, end, startUTF8, endUTF8;
    if (!source_offset(string, _startLine, _startColumn, &start, &startUTF8) ||
        !source_offset(string, _endLine, _endColumn, &end, &endUTF8))
        return NSMakeRange(NSNotFound, NSNotFound);
    NSUInteger nextUTF8 = 0;
    NSUInteger endWidth = utf16_length_of_codepoint_at_utf8_offset(string, endUTF8, &nextUTF8);
    if (endUTF8 + 1 == nextUTF8)
        end += endWidth;
    if (end < start || end > [string length])
        return NSMakeRange(NSNotFound, NSNotFound);
    return NSMakeRange(start, end - start);
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_startLine forKey:@"startLine"];
    [coder encodeInteger:_startColumn forKey:@"startColumn"];
    [coder encodeInteger:_endLine forKey:@"endLine"];
    [coder encodeInteger:_endColumn forKey:@"endColumn"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithStartLine:[coder decodeIntegerForKey:@"startLine"]
                       startColumn:[coder decodeIntegerForKey:@"startColumn"]
                           endLine:[coder decodeIntegerForKey:@"endLine"]
                         endColumn:[coder decodeIntegerForKey:@"endColumn"]];
}

@end

@interface NSPresentationIntent () {
    NSPresentationIntentKind _intentKind;
    NSInteger _identity, _ordinal, _columnCount, _headerLevel, _column, _row;
    NSArray<NSNumber *> *_columnAlignments;
    NSString *_languageHint;
    NSPresentationIntent *_parentIntent;
}
- (instancetype)initWithKind:(NSPresentationIntentKind)kind identity:(NSInteger)identity parent:(NSPresentationIntent *)parent;
@end

@implementation NSPresentationIntent

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    [self release];
    FinchRaise(NSInvalidArgumentException, "-[NSPresentationIntent init] must be called through an intent factory");
}

- (instancetype)initWithKind:(NSPresentationIntentKind)kind identity:(NSInteger)identity parent:(NSPresentationIntent *)parent
{
    if ((self = [super init])) {
        _intentKind = kind;
        _identity = identity;
        _parentIntent = [parent retain];
    }
    return self;
}

- (void)dealloc
{
    [_columnAlignments release];
    [_languageHint release];
    [_parentIntent release];
    [super dealloc];
}

- (NSPresentationIntentKind)intentKind { return _intentKind; }
- (NSInteger)identity { return _identity; }
- (NSInteger)ordinal { return _ordinal; }
- (NSArray<NSNumber *> *)columnAlignments { return _columnAlignments; }
- (NSInteger)columnCount { return _columnCount; }
- (NSInteger)headerLevel { return _headerLevel; }
- (NSString *)languageHint { return _languageHint; }
- (NSInteger)column { return _column; }
- (NSInteger)row { return _row; }
- (NSPresentationIntent *)parentIntent { return _parentIntent; }

- (NSInteger)indentationLevel
{
    NSInteger level = 0;
    for (NSPresentationIntent *intent = self; intent; intent = intent->_parentIntent)
        if (intent->_intentKind == NSPresentationIntentKindOrderedList ||
            intent->_intentKind == NSPresentationIntentKindUnorderedList ||
            intent->_intentKind == NSPresentationIntentKindBlockQuote)
            level++;
    return level;
}

+ (instancetype)paragraphIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindParagraph identity:identity parent:parent] autorelease];
}

+ (instancetype)headerIntentWithIdentity:(NSInteger)identity level:(NSInteger)level nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindHeader identity:identity parent:parent] autorelease];
    intent->_headerLevel = level;
    return intent;
}

+ (instancetype)codeBlockIntentWithIdentity:(NSInteger)identity languageHint:(NSString *)languageHint nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindCodeBlock identity:identity parent:parent] autorelease];
    intent->_languageHint = [languageHint copy];
    return intent;
}

+ (instancetype)thematicBreakIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindThematicBreak identity:identity parent:parent] autorelease];
}

+ (instancetype)orderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindOrderedList identity:identity parent:parent] autorelease];
}

+ (instancetype)unorderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindUnorderedList identity:identity parent:parent] autorelease];
}

+ (instancetype)listItemIntentWithIdentity:(NSInteger)identity ordinal:(NSInteger)ordinal nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindListItem identity:identity parent:parent] autorelease];
    intent->_ordinal = ordinal;
    return intent;
}

+ (instancetype)blockQuoteIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindBlockQuote identity:identity parent:parent] autorelease];
}

+ (instancetype)tableIntentWithIdentity:(NSInteger)identity columnCount:(NSInteger)columnCount alignments:(NSArray<NSNumber *> *)alignments
                      nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindTable identity:identity parent:parent] autorelease];
    intent->_columnCount = columnCount;
    intent->_columnAlignments = [alignments copy];
    return intent;
}

+ (instancetype)tableHeaderRowIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] initWithKind:NSPresentationIntentKindTableHeaderRow identity:identity parent:parent] autorelease];
}

+ (instancetype)tableRowIntentWithIdentity:(NSInteger)identity row:(NSInteger)row nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindTableRow identity:identity parent:parent] autorelease];
    intent->_row = row;
    return intent;
}

+ (instancetype)tableCellIntentWithIdentity:(NSInteger)identity column:(NSInteger)column nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] initWithKind:NSPresentationIntentKindTableCell identity:identity parent:parent] autorelease];
    intent->_column = column;
    return intent;
}

- (BOOL)isEquivalentToPresentationIntent:(NSPresentationIntent *)other
{
    if (other == self)
        return YES;
    if (!other || _intentKind != other->_intentKind || _ordinal != other->_ordinal || _columnCount != other->_columnCount ||
        _headerLevel != other->_headerLevel || _column != other->_column || _row != other->_row ||
        ((_columnAlignments || other->_columnAlignments) && ![_columnAlignments isEqualToArray:other->_columnAlignments]) ||
        ((_languageHint || other->_languageHint) && ![_languageHint isEqualToString:other->_languageHint]))
        return NO;
    if (!_parentIntent || !other->_parentIntent)
        return _parentIntent == other->_parentIntent;
    return [_parentIntent isEquivalentToPresentationIntent:other->_parentIntent];
}

- (BOOL)isEqual:(id)object
{
    if (object == self)
        return YES;
    if (![object isKindOfClass:[NSPresentationIntent class]])
        return NO;
    NSPresentationIntent *other = object;
    return _identity == other->_identity && [self isEquivalentToPresentationIntent:other];
}

- (NSUInteger)hash
{
    return (NSUInteger)_intentKind ^ (NSUInteger)_identity ^ (NSUInteger)_ordinal ^ (NSUInteger)_headerLevel ^
           (NSUInteger)_column ^ (NSUInteger)_row ^ [_columnAlignments hash] ^ [_languageHint hash] ^ [_parentIntent hash];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_intentKind forKey:@"kind"];
    [coder encodeInteger:_identity forKey:@"identity"];
    [coder encodeInteger:_ordinal forKey:@"ordinal"];
    [coder encodeInteger:_columnCount forKey:@"columnCount"];
    [coder encodeInteger:_headerLevel forKey:@"headerLevel"];
    [coder encodeInteger:_column forKey:@"column"];
    [coder encodeInteger:_row forKey:@"row"];
    [coder encodeObject:_columnAlignments forKey:@"columnAlignments"];
    [coder encodeObject:_languageHint forKey:@"languageHint"];
    [coder encodeObject:_parentIntent forKey:@"parentIntent"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSPresentationIntentKind kind = [coder decodeIntegerForKey:@"kind"];
    self = [self initWithKind:kind identity:[coder decodeIntegerForKey:@"identity"]
                       parent:[coder decodeObjectOfClass:[NSPresentationIntent class] forKey:@"parentIntent"]];
    if (self) {
        _ordinal = [coder decodeIntegerForKey:@"ordinal"];
        _columnCount = [coder decodeIntegerForKey:@"columnCount"];
        _headerLevel = [coder decodeIntegerForKey:@"headerLevel"];
        _column = [coder decodeIntegerForKey:@"column"];
        _row = [coder decodeIntegerForKey:@"row"];
        NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSNumber class], nil];
        _columnAlignments = [[coder decodeObjectOfClasses:classes forKey:@"columnAlignments"] copy];
        _languageHint = [[coder decodeObjectOfClass:[NSString class] forKey:@"languageHint"] copy];
    }
    return self;
}

@end

/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Markdown parsing, its options and source positions, and presentation intents.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"
#include <cmark-gfm.h>
#include <cmark-gfm-core-extensions.h>

#include <string.h>

@interface NSAttributedStringMarkdownParsingOptions () {
    BOOL _allowsExtendedAttributes, _appliesSourcePositionAttributes;
    NSAttributedStringMarkdownInterpretedSyntax _interpretedSyntax;
    NSAttributedStringMarkdownParsingFailurePolicy _failurePolicy;
    NSString *_languageCode;
}
@end

typedef struct {
    NSMutableAttributedString *result;
    NSString *source;
    const char *sourceBytes;
    NSUInteger sourceLength;
    NSURL *baseURL;
    NSString *languageCode;
    NSUInteger nextIdentity;
    BOOL sourcePositions;
    BOOL inlineOnly;
} MarkdownBuilder;

typedef struct {
    NSUInteger intent;
    NSURL *linkURL;
    NSURL *imageURL;
    NSString *alternateDescription;
} MarkdownInlineAttributes;

static NSString *const MarkdownLinkAttributeName = @"NSLink";
static NSString *const MarkdownImageURLAttributeName = @"NSImageURL";
static NSString *const MarkdownAlternateDescriptionAttributeName = @"NSAlternateDescription";
static unichar const MarkdownInlineOnlyLinePrefix = 'x';

static NSUInteger
next_identity(MarkdownBuilder *builder)
{
    return ++builder->nextIdentity;
}

static NSString *
string_from_utf8(const char *bytes, NSUInteger length)
{
    if (!bytes)
        return @"";
    NSString *string = [[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
    return string ?: @"";
}

static NSAttributedStringMarkdownSourcePosition *
source_position_for_node(MarkdownBuilder *builder, cmark_node *node, BOOL removedLinePrefix)
{
    NSInteger startLine = cmark_node_get_start_line(node);
    NSInteger startColumn = cmark_node_get_start_column(node);
    NSInteger endLine = cmark_node_get_end_line(node);
    NSInteger endColumn = cmark_node_get_end_column(node);
    if (startLine < 1 || startColumn < 1 || endLine < 1 || endColumn < 1)
        return nil;
    if (builder->inlineOnly) {
        if (removedLinePrefix && startLine == endLine && startColumn == 1)
            startColumn = 1;
        else
            startColumn = MAX(1, startColumn - 1);
        endColumn = MAX(1, endColumn - 1);
    }
    return [[[NSAttributedStringMarkdownSourcePosition alloc] initWithStartLine:startLine
                                                                   startColumn:startColumn
                                                                       endLine:endLine
                                                                     endColumn:endColumn] autorelease];
}

static NSRange
append_markdown_text(MarkdownBuilder *builder, NSString *string, cmark_node *node,
                     MarkdownInlineAttributes inlineAttributes, BOOL removedLinePrefix,
                     NSUInteger additionalIntent)
{
    NSUInteger start = [builder->result length];
    if (![string length])
        return NSMakeRange(start, 0);

    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSUInteger intent = inlineAttributes.intent | additionalIntent;
    if (intent)
        [attributes setObject:[NSNumber numberWithUnsignedInteger:intent]
                       forKey:NSInlinePresentationIntentAttributeName];
    if (inlineAttributes.linkURL)
        [attributes setObject:inlineAttributes.linkURL forKey:MarkdownLinkAttributeName];
    if (inlineAttributes.imageURL)
        [attributes setObject:inlineAttributes.imageURL forKey:MarkdownImageURLAttributeName];
    if (inlineAttributes.alternateDescription)
        [attributes setObject:inlineAttributes.alternateDescription forKey:MarkdownAlternateDescriptionAttributeName];
    if (builder->languageCode)
        [attributes setObject:builder->languageCode forKey:NSLanguageIdentifierAttributeName];
    if (builder->sourcePositions && node) {
        NSAttributedStringMarkdownSourcePosition *position = source_position_for_node(builder, node, removedLinePrefix);
        if (position)
            [attributes setObject:position forKey:NSMarkdownSourcePositionAttributeName];
    }

    NSAttributedString *part = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    [builder->result appendAttributedString:part];
    [part release];
    return NSMakeRange(start, [string length]);
}

static NSURL *
resolved_markdown_url(MarkdownBuilder *builder, const char *rawURL)
{
    if (!rawURL)
        return nil;
    NSString *string = [NSString stringWithUTF8String:rawURL];
    if (!string)
        return nil;
    NSURL *url = [NSURL URLWithString:string relativeToURL:builder->baseURL];
    if (!url)
        return nil;
    return builder->baseURL ? [url absoluteURL] : url;
}

static NSString *
text_for_node(cmark_node *node)
{
    const char *literal = cmark_node_get_literal(node);
    if (!literal)
        return @"";
    return string_from_utf8(literal, strlen(literal));
}

static void parse_inline_node(MarkdownBuilder *, cmark_node *, MarkdownInlineAttributes);

static void
parse_inline_children(MarkdownBuilder *builder, cmark_node *node, MarkdownInlineAttributes attributes)
{
    for (cmark_node *child = cmark_node_first_child(node); child; child = cmark_node_next(child))
        parse_inline_node(builder, child, attributes);
}

static void
parse_inline_node(MarkdownBuilder *builder, cmark_node *node, MarkdownInlineAttributes attributes)
{
    cmark_node_type type = cmark_node_get_type(node);
    const char *typeName = cmark_node_get_type_string(node);
    if (type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE || type == CMARK_NODE_HTML_INLINE) {
        NSString *text = text_for_node(node);
        BOOL removedPrefix = NO;
        if (builder->inlineOnly && cmark_node_get_start_column(node) == 1 &&
            [text length] && [text characterAtIndex:0] == MarkdownInlineOnlyLinePrefix) {
            text = [text substringFromIndex:1];
            removedPrefix = YES;
        }
        if (type == CMARK_NODE_HTML_INLINE)
            attributes.intent |= NSInlinePresentationIntentInlineHTML;
        if (type == CMARK_NODE_CODE)
            attributes.intent |= NSInlinePresentationIntentCode;
        append_markdown_text(builder, text, node, attributes, removedPrefix, 0);
        return;
    }
    if (type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK) {
        NSString *breakString = builder->inlineOnly ? @"\n" : @" ";
        NSUInteger breakIntent = 0;
        if (!builder->inlineOnly)
            breakIntent = type == CMARK_NODE_SOFTBREAK ? NSInlinePresentationIntentSoftBreak : NSInlinePresentationIntentLineBreak;
        append_markdown_text(builder, breakString, node, attributes, NO, breakIntent);
        return;
    }
    if (type == CMARK_NODE_EMPH) {
        attributes.intent |= NSInlinePresentationIntentEmphasized;
    } else if (type == CMARK_NODE_STRONG) {
        attributes.intent |= NSInlinePresentationIntentStronglyEmphasized;
    } else if (typeName && strcmp(typeName, "strikethrough") == 0) {
        attributes.intent |= NSInlinePresentationIntentStrikethrough;
    } else if (type == CMARK_NODE_LINK) {
        attributes.linkURL = resolved_markdown_url(builder, cmark_node_get_url(node));
        const char *title = cmark_node_get_title(node);
        attributes.alternateDescription = title && *title ? [NSString stringWithUTF8String:title] : nil;
    } else if (type == CMARK_NODE_IMAGE) {
        attributes.imageURL = resolved_markdown_url(builder, cmark_node_get_url(node));
        const char *title = cmark_node_get_title(node);
        attributes.alternateDescription = title && *title ? [NSString stringWithUTF8String:title] : nil;
    }
    parse_inline_children(builder, node, attributes);
}

static void parse_block_node(MarkdownBuilder *, cmark_node *, NSPresentationIntent *);

static void
parse_block_children(MarkdownBuilder *builder, cmark_node *node, NSPresentationIntent *parent)
{
    for (cmark_node *child = cmark_node_first_child(node); child; child = cmark_node_next(child))
        parse_block_node(builder, child, parent);
}

static void
apply_block_intent(MarkdownBuilder *builder, NSRange range, NSPresentationIntent *intent)
{
    if (range.length)
        [builder->result addAttribute:NSPresentationIntentAttributeName value:intent range:range];
}

static NSUInteger
source_line_offset(MarkdownBuilder *builder, NSInteger line)
{
    if (line < 1)
        return NSNotFound;
    NSUInteger offset = 0;
    NSInteger current = 1;
    while (current < line && offset < builder->sourceLength) {
        if (builder->sourceBytes[offset++] == '\n')
            current++;
    }
    return current == line ? offset : NSNotFound;
}

static NSString *
list_item_delimiter(MarkdownBuilder *builder, cmark_node *list)
{
    if (cmark_node_get_list_type(list) == CMARK_ORDERED_LIST)
        return cmark_node_get_list_delim(list) == CMARK_PAREN_DELIM ? @")" : @".";
    NSUInteger lineOffset = source_line_offset(builder, cmark_node_get_start_line(list));
    if (lineOffset == NSNotFound)
        return @"-";
    NSInteger column = cmark_node_get_start_column(list);
    NSUInteger at = column > 0 ? lineOffset + (NSUInteger)column - 1 : lineOffset;
    if (at >= builder->sourceLength)
        return @"-";
    unsigned char marker = (unsigned char)builder->sourceBytes[at];
    if (marker == '-' || marker == '*' || marker == '+')
        return [NSString stringWithFormat:@"%c", marker];
    return @"-";
}

static void
parse_list_item(MarkdownBuilder *builder, cmark_node *item, NSPresentationIntent *itemIntent,
                NSString *delimiter)
{
    for (cmark_node *child = cmark_node_first_child(item); child; child = cmark_node_next(child)) {
        NSUInteger start = [builder->result length];
        parse_block_node(builder, child, itemIntent);
        if (cmark_node_get_type(child) != CMARK_NODE_LIST) {
            NSUInteger length = [builder->result length] - start;
            if (length)
                [builder->result addAttribute:NSListItemDelimiterAttributeName value:delimiter
                                         range:NSMakeRange(start, length)];
        }
    }
}

static NSArray *
table_alignments(cmark_node *table)
{
    NSUInteger count = cmark_gfm_extensions_get_table_columns(table);
    uint8_t *values = cmark_gfm_extensions_get_table_alignments(table);
    NSMutableArray *alignments = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger alignment = values && values[i] == 'c' ? NSPresentationIntentTableColumnAlignmentCenter :
            values && values[i] == 'r' ? NSPresentationIntentTableColumnAlignmentRight :
            NSPresentationIntentTableColumnAlignmentLeft;
        [alignments addObject:[NSNumber numberWithInteger:alignment]];
    }
    return alignments;
}

static void
parse_table(MarkdownBuilder *builder, cmark_node *table, NSPresentationIntent *parent)
{
    NSInteger columns = cmark_gfm_extensions_get_table_columns(table);
    NSPresentationIntent *tableIntent = [NSPresentationIntent tableIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                            columnCount:columns
                                                                             alignments:table_alignments(table)
                                                                     nestedInsideIntent:parent];
    NSInteger rowNumber = 1;
    for (cmark_node *row = cmark_node_first_child(table); row; row = cmark_node_next(row)) {
        const char *typeName = cmark_node_get_type_string(row);
        BOOL header = typeName && strcmp(typeName, "table_header") == 0;
        NSPresentationIntent *rowIntent = header ?
            [NSPresentationIntent tableHeaderRowIntentWithIdentity:(NSInteger)next_identity(builder)
                                                nestedInsideIntent:tableIntent] :
            [NSPresentationIntent tableRowIntentWithIdentity:(NSInteger)next_identity(builder)
                                                          row:rowNumber++
                                            nestedInsideIntent:tableIntent];
        NSInteger column = 0;
        for (cmark_node *cell = cmark_node_first_child(row); cell; cell = cmark_node_next(cell), column++) {
            NSPresentationIntent *cellIntent = [NSPresentationIntent tableCellIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                                           column:column
                                                                             nestedInsideIntent:rowIntent];
            NSUInteger start = [builder->result length];
            parse_inline_children(builder, cell, (MarkdownInlineAttributes){0});
            apply_block_intent(builder, NSMakeRange(start, [builder->result length] - start), cellIntent);
        }
    }
}

static void
parse_block_node(MarkdownBuilder *builder, cmark_node *node, NSPresentationIntent *parent)
{
    cmark_node_type type = cmark_node_get_type(node);
    const char *typeName = cmark_node_get_type_string(node);
    if (type == CMARK_NODE_DOCUMENT) {
        parse_block_children(builder, node, parent);
        return;
    }
    if (typeName && strcmp(typeName, "table") == 0) {
        parse_table(builder, node, parent);
        return;
    }
    if (type == CMARK_NODE_BLOCK_QUOTE) {
        NSPresentationIntent *intent = [NSPresentationIntent blockQuoteIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                        nestedInsideIntent:parent];
        parse_block_children(builder, node, intent);
        return;
    }
    if (type == CMARK_NODE_LIST) {
        BOOL ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST;
        NSPresentationIntent *intent = ordered ?
            [NSPresentationIntent orderedListIntentWithIdentity:(NSInteger)next_identity(builder) nestedInsideIntent:parent] :
            [NSPresentationIntent unorderedListIntentWithIdentity:(NSInteger)next_identity(builder) nestedInsideIntent:parent];
        NSString *delimiter = list_item_delimiter(builder, node);
        NSInteger ordinal = cmark_node_get_list_start(node);
        if (ordinal < 1) ordinal = 1;
        for (cmark_node *item = cmark_node_first_child(node); item; item = cmark_node_next(item)) {
            NSPresentationIntent *itemIntent = [NSPresentationIntent listItemIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                                          ordinal:ordinal++
                                                                            nestedInsideIntent:intent];
            parse_list_item(builder, item, itemIntent, delimiter);
        }
        return;
    }
    if (type == CMARK_NODE_PARAGRAPH || type == CMARK_NODE_HEADING) {
        NSPresentationIntent *intent = type == CMARK_NODE_HEADING ?
            [NSPresentationIntent headerIntentWithIdentity:(NSInteger)next_identity(builder)
                                                      level:cmark_node_get_heading_level(node)
                                        nestedInsideIntent:parent] :
            [NSPresentationIntent paragraphIntentWithIdentity:(NSInteger)next_identity(builder)
                                           nestedInsideIntent:parent];
        NSUInteger start = [builder->result length];
        parse_inline_children(builder, node, (MarkdownInlineAttributes){0});
        apply_block_intent(builder, NSMakeRange(start, [builder->result length] - start), intent);
        return;
    }
    if (type == CMARK_NODE_THEMATIC_BREAK) {
        NSPresentationIntent *intent = [NSPresentationIntent thematicBreakIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                            nestedInsideIntent:parent];
        NSUInteger start = [builder->result length];
        append_markdown_text(builder, @"\u2e3b", node, (MarkdownInlineAttributes){0}, NO, 0);
        apply_block_intent(builder, NSMakeRange(start, [builder->result length] - start), intent);
        return;
    }
    if (type == CMARK_NODE_CODE_BLOCK) {
        const char *rawLanguage = cmark_node_get_fence_info(node);
        NSString *language = rawLanguage ? [NSString stringWithUTF8String:rawLanguage] : nil;
        if (language) {
            NSRange whitespace = [language rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (whitespace.location != NSNotFound)
                language = [language substringToIndex:whitespace.location];
            if (![language length]) language = nil;
        }
        NSPresentationIntent *intent = [NSPresentationIntent codeBlockIntentWithIdentity:(NSInteger)next_identity(builder)
                                                                              languageHint:language
                                                                        nestedInsideIntent:parent];
        NSUInteger start = [builder->result length];
        append_markdown_text(builder, text_for_node(node), node, (MarkdownInlineAttributes){0}, NO, 0);
        apply_block_intent(builder, NSMakeRange(start, [builder->result length] - start), intent);
        return;
    }
    if (type == CMARK_NODE_HTML_BLOCK) {
        append_markdown_text(builder, text_for_node(node), node, (MarkdownInlineAttributes){0}, NO,
                             NSInlinePresentationIntentBlockHTML);
        return;
    }
    parse_inline_children(builder, node, (MarkdownInlineAttributes){0});
}

static NSString *
source_for_inline_only(NSString *source)
{
    NSMutableString *result = [NSMutableString string];
    NSUInteger start = 0;
    while (start < [source length]) {
        NSRange newline = [source rangeOfString:@"\n" options:0 range:NSMakeRange(start, [source length] - start)];
        NSUInteger end = newline.location == NSNotFound ? [source length] : newline.location;
        [result appendFormat:@"%C", MarkdownInlineOnlyLinePrefix];
        [result appendString:[source substringWithRange:NSMakeRange(start, end - start)]];
        if (newline.location == NSNotFound)
            break;
        [result appendString:@"\n"];
        start = newline.location + 1;
    }
    if (![source length])
        return @"";
    if ([source characterAtIndex:[source length] - 1] == '\n')
        [result appendFormat:@"%C", MarkdownInlineOnlyLinePrefix];
    return result;
}

static NSAttributedString *
parse_markdown_string(NSString *source, NSAttributedStringMarkdownParsingOptions *options, NSURL *baseURL)
{
    NSString *parseSource = options.interpretedSyntax == NSAttributedStringMarkdownInterpretedSyntaxFull ?
        source : source_for_inline_only(source);
    NSData *data = [parseSource dataUsingEncoding:NSUTF8StringEncoding];
    if (!data)
        return nil;

    static dispatch_once_t extensionRegistration;
    dispatch_once(&extensionRegistration, ^{
        cmark_gfm_core_extensions_ensure_registered();
    });
    int cmarkOptions = options.appliesSourcePositionAttributes ? CMARK_OPT_SOURCEPOS : CMARK_OPT_DEFAULT;
    cmark_parser *parser = cmark_parser_new(cmarkOptions);
    if (!parser)
        return nil;
    const char *extensionNames[] = { "table", "strikethrough", "autolink" };
    for (NSUInteger i = 0; i < sizeof(extensionNames) / sizeof(extensionNames[0]); i++) {
        cmark_syntax_extension *extension = cmark_find_syntax_extension(extensionNames[i]);
        if (extension)
            cmark_parser_attach_syntax_extension(parser, extension);
    }
    const char *bytes = [data length] ? [data bytes] : "";
    cmark_parser_feed(parser, bytes, [data length]);
    cmark_node *document = cmark_parser_finish(parser);
    cmark_parser_free(parser);
    if (!document)
        return nil;

    NSMutableAttributedString *result = [[[NSMutableAttributedString alloc] initWithString:@""] autorelease];
    NSData *sourceData = [source dataUsingEncoding:NSUTF8StringEncoding];
    MarkdownBuilder builder = {
        .result = result,
        .source = source,
        .sourceBytes = [sourceData bytes],
        .sourceLength = [sourceData length],
        .baseURL = baseURL,
        .languageCode = options.languageCode,
        .nextIdentity = 0,
        .sourcePositions = options.appliesSourcePositionAttributes,
        .inlineOnly = options.interpretedSyntax != NSAttributedStringMarkdownInterpretedSyntaxFull
    };
    if (builder.inlineOnly) {
        MarkdownInlineAttributes inlineAttributes = {0};
        for (cmark_node *paragraph = cmark_node_first_child(document); paragraph; paragraph = cmark_node_next(paragraph))
            parse_inline_children(&builder, paragraph, inlineAttributes);
    } else {
        parse_block_node(&builder, document, nil);
    }
    cmark_node_free(document);
    return result;
}

static NSAttributedStringMarkdownParsingOptions *
effective_markdown_options(NSAttributedStringMarkdownParsingOptions *options)
{
    return options ?: [[[NSAttributedStringMarkdownParsingOptions alloc] init] autorelease];
}

static void
set_markdown_error(NSError **error, NSInteger code, NSString *description)
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:code
                                  userInfo:@{ NSLocalizedDescriptionKey: description }];
}

@implementation NSAttributedString (NSAttributedStringCreateFromMarkdown)

- (instancetype)initWithMarkdownString:(NSString *)markdownString
                               options:(NSAttributedStringMarkdownParsingOptions *)options
                               baseURL:(NSURL *)baseURL
                                 error:(NSError **)error
{
    if (error) *error = nil;
    if (!markdownString) {
        set_markdown_error(error, NSFileReadUnknownError, @"The Markdown string is missing.");
        [self release];
        return nil;
    }
    NSAttributedStringMarkdownParsingOptions *effective = effective_markdown_options(options);
    NSAttributedString *parsed = parse_markdown_string(markdownString, effective, baseURL);
    if (!parsed) {
        if (effective.failurePolicy == NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible)
            return [self initWithString:markdownString];
        set_markdown_error(error, NSFileReadUnknownError, @"The Markdown text could not be parsed.");
        [self release];
        return nil;
    }
    return [self initWithAttributedString:parsed];
}

- (instancetype)initWithMarkdown:(NSData *)markdown
                          options:(NSAttributedStringMarkdownParsingOptions *)options
                          baseURL:(NSURL *)baseURL
                            error:(NSError **)error
{
    if (error) *error = nil;
    NSAttributedStringMarkdownParsingOptions *effective = effective_markdown_options(options);
    NSString *string = [[NSString alloc] initWithData:markdown encoding:NSUTF8StringEncoding];
    if (!string) {
        if (effective.failurePolicy == NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible)
            return [self initWithString:@""];
        set_markdown_error(error, NSFileReadCorruptFileError, @"The Markdown data is not valid UTF-8.");
        [self release];
        return nil;
    }
    self = [self initWithMarkdownString:string options:effective baseURL:baseURL error:error];
    [string release];
    return self;
}

- (instancetype)initWithContentsOfMarkdownFileAtURL:(NSURL *)markdownFile
                                            options:(NSAttributedStringMarkdownParsingOptions *)options
                                            baseURL:(NSURL *)baseURL
                                              error:(NSError **)error
{
    if (error) *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:markdownFile options:0 error:error];
    if (!data) {
        [self release];
        return nil;
    }
    return [self initWithMarkdown:data options:options baseURL:baseURL error:error];
}

@end

__attribute__((visibility("hidden"))) NSAttributedString *
_FinchAttributedStringFromMarkdownString(NSString *markdown, NSInteger interpretedSyntax, NSInteger failurePolicy,
                                         BOOL allowsExtendedAttributes, NSString *languageCode,
                                         BOOL appliesSourcePositionAttributes, NSURL *baseURL, NSError **error)
{
    (void)allowsExtendedAttributes;
    NSAttributedStringMarkdownParsingOptions *options = [[NSAttributedStringMarkdownParsingOptions alloc] init];
    options.interpretedSyntax = (NSAttributedStringMarkdownInterpretedSyntax)interpretedSyntax;
    options.failurePolicy = (NSAttributedStringMarkdownParsingFailurePolicy)failurePolicy;
    options.languageCode = languageCode;
    options.appliesSourcePositionAttributes = appliesSourcePositionAttributes;
    NSAttributedString *result = [[NSAttributedString alloc] initWithMarkdownString:markdown options:options
                                                                             baseURL:baseURL error:error];
    [options release];
    return result;
}

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
        NSUInteger width16;
        NSUInteger width8 = utf8_width(string, i, &width16);
        if (currentLine == (NSUInteger)line && utf8 - lineStart + width8 >= (NSUInteger)column) {
            *utf16Offset = utf16;
            *utf8Offset = utf8;
            return YES;
        }
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
    if (endWidth)
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

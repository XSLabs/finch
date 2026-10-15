/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <string.h>

static NSAttributedStringKey const FinchLinkAttributeName = @"NSLink";
static NSAttributedStringKey const FinchAlternateDescriptionAttributeName = @"NSAlternateDescription";
static NSAttributedStringKey const FinchImageURLAttributeName = @"NSImageURL";

static const char *
intent_kind_name(NSPresentationIntentKind kind)
{
    static const char *names[] = {
        "paragraph", "header", "orderedList", "unorderedList", "listItem", "codeBlock",
        "blockQuote", "thematicBreak", "table", "tableHeaderRow", "tableRow", "tableCell"
    };
    if ((NSUInteger)kind >= sizeof(names) / sizeof(names[0]))
        return "unknown";
    return names[kind];
}

static void
print_quoted(NSString *string)
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [data bytes];
    NSUInteger length = [data length];
    putchar('"');
    for (NSUInteger i = 0; i < length; i++) {
        unsigned char c = bytes[i];
        switch (c) {
        case '\\': fputs("\\\\", stdout); break;
        case '"': fputs("\\\"", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20 || c == 0x7f)
                printf("\\u%04x", c);
            else
                putchar(c);
            break;
        }
    }
    putchar('"');
}

static void
print_intent(NSPresentationIntent *intent)
{
    if (!intent) {
        fputs("nil", stdout);
        return;
    }
    printf("%s(id=%ld", intent_kind_name(intent.intentKind), (long)intent.identity);
    if (intent.intentKind == NSPresentationIntentKindHeader)
        printf(",level=%ld", (long)intent.headerLevel);
    if (intent.intentKind == NSPresentationIntentKindListItem)
        printf(",ordinal=%ld", (long)intent.ordinal);
    if (intent.intentKind == NSPresentationIntentKindCodeBlock) {
        fputs(",language=", stdout);
        if (intent.languageHint) print_quoted(intent.languageHint); else fputs("nil", stdout);
    }
    if (intent.intentKind == NSPresentationIntentKindTable) {
        printf(",columns=%ld,alignments=", (long)intent.columnCount);
        if (intent.columnAlignments) {
            putchar('[');
            for (NSUInteger i = 0; i < intent.columnAlignments.count; i++) {
                if (i) putchar(',');
                printf("%ld", (long)intent.columnAlignments[i].integerValue);
            }
            putchar(']');
        } else {
            fputs("nil", stdout);
        }
    }
    if (intent.intentKind == NSPresentationIntentKindTableRow ||
        intent.intentKind == NSPresentationIntentKindTableHeaderRow)
        printf(",row=%ld", (long)intent.row);
    if (intent.intentKind == NSPresentationIntentKindTableCell)
        printf(",column=%ld", (long)intent.column);
    fputs(",parent=", stdout);
    print_intent(intent.parentIntent);
    putchar(')');
}

static void
print_attribute_value(NSAttributedStringKey key, id value, NSString *source)
{
    if ([key isEqualToString:NSInlinePresentationIntentAttributeName]) {
        printf("%lu", (unsigned long)[value unsignedIntegerValue]);
    } else if ([key isEqualToString:FinchLinkAttributeName] ||
               [key isEqualToString:FinchImageURLAttributeName]) {
        NSString *string = [value isKindOfClass:[NSURL class]] ? [value absoluteString] : [value description];
        print_quoted(string);
    } else if ([key isEqualToString:NSPresentationIntentAttributeName]) {
        print_intent(value);
    } else if ([key isEqualToString:NSMarkdownSourcePositionAttributeName]) {
        NSAttributedStringMarkdownSourcePosition *position = value;
        NSRange range = [position rangeInString:source];
        printf("%ld:%ld-%ld:%ld/range=%lu:%lu", (long)position.startLine, (long)position.startColumn,
               (long)position.endLine, (long)position.endColumn, (unsigned long)range.location,
               (unsigned long)range.length);
    } else if ([key isEqualToString:NSLanguageIdentifierAttributeName] ||
               [key isEqualToString:NSListItemDelimiterAttributeName]) {
        print_quoted([value description]);
    } else {
        print_quoted([value description]);
    }
}

static void
print_result(const char *name, NSAttributedString *result, NSError *error, NSString *source)
{
    printf("[%s] ", name);
    if (error)
        printf("error=%s:%ld ", error.domain.UTF8String, (long)error.code);
    else
        fputs("error=none ", stdout);
    if (!result) {
        fputs("result=nil\n", stdout);
        return;
    }
    fputs("text=", stdout);
    print_quoted(result.string);
    printf(" length=%lu\n", (unsigned long)result.length);

    NSArray<NSAttributedStringKey> *keys = @[
        NSInlinePresentationIntentAttributeName,
        FinchLinkAttributeName,
        NSPresentationIntentAttributeName,
        NSMarkdownSourcePositionAttributeName,
        NSLanguageIdentifierAttributeName,
        NSListItemDelimiterAttributeName,
        FinchAlternateDescriptionAttributeName,
        FinchImageURLAttributeName
    ];
    for (NSAttributedStringKey key in keys) {
        [result enumerateAttribute:key inRange:NSMakeRange(0, result.length) options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
            (void)stop;
            if (!value)
                return;
            printf("  %s %lu:%lu = ", key.UTF8String, (unsigned long)range.location,
                   (unsigned long)range.length);
            print_attribute_value(key, value, source);
            putchar('\n');
        }];
    }
}

static NSAttributedStringMarkdownParsingOptions *
options(NSAttributedStringMarkdownInterpretedSyntax syntax,
        NSAttributedStringMarkdownParsingFailurePolicy failurePolicy,
        BOOL sourcePositions, NSString *language)
{
    NSAttributedStringMarkdownParsingOptions *result = [[NSAttributedStringMarkdownParsingOptions alloc] init];
    result.interpretedSyntax = syntax;
    result.failurePolicy = failurePolicy;
    result.appliesSourcePositionAttributes = sourcePositions;
    result.languageCode = language;
    return result;
}

static void
run_string(const char *name, NSString *source, NSAttributedStringMarkdownParsingOptions *parsingOptions,
           NSURL *baseURL)
{
    NSError *error = nil;
    NSAttributedString *result = [[NSAttributedString alloc] initWithMarkdownString:source
                                                                              options:parsingOptions
                                                                               baseURL:baseURL
                                                                                 error:&error];
    print_result(name, result, error, source);
}

int
main(void)
{
    const char *image = class_getImageName([NSAttributedString class]);
    printf("framework=%s\n", image ? image : "unknown");

    NSURL *base = [NSURL URLWithString:@"https://example.test/docs/page.md"];
    run_string("inline", @"plain *em* **strong** `code` ~~gone~~ [child](../guide.md \"title\") and \\*escaped\\*",
               nil, base);
    run_string("nested-inline", @"***triple*** _under_ ~~strike *nested*~~ [site](https://example.test)",
               nil, nil);
    run_string("blocks", @"# Title *nice*\n\nA paragraph with\nsoft break and  two spaces.\n\n> quoted\n> more\n\n1. first\n2. second\n   - nested\n\n---\n\n```swift\nlet x = 1\n```\n\n| A | B |\n| :- | -: |\n| **x** | y |",
               nil, nil);
    run_string("inline-only", @"# Header\n\none  two\nthree\n\n- item *em*",
               options(NSAttributedStringMarkdownInterpretedSyntaxInlineOnly,
                       NSAttributedStringMarkdownParsingFailureReturnError, NO, nil), nil);
    run_string("preserving-whitespace", @"one  two\nthree\t four\n\nlast",
               options(NSAttributedStringMarkdownInterpretedSyntaxInlineOnlyPreservingWhitespace,
                       NSAttributedStringMarkdownParsingFailureReturnError, NO, nil), nil);
    run_string("source-and-language", @"# Café\n\nText *here*.",
               options(NSAttributedStringMarkdownInterpretedSyntaxFull,
                       NSAttributedStringMarkdownParsingFailureReturnError, YES, @"fr-CA"), nil);

    NSString *dataSource = @"Data **strong** and [relative](item.md).";
    NSData *data = [dataSource dataUsingEncoding:NSUTF8StringEncoding];
    NSError *dataError = nil;
    NSAttributedString *dataResult = [[NSAttributedString alloc] initWithMarkdown:data options:nil
                                                                           baseURL:base error:&dataError];
    print_result("data", dataResult, dataError, dataSource);

    NSString *fixturePath = [[NSFileManager defaultManager].currentDirectoryPath
        stringByAppendingPathComponent:@"userland/tests/markdown-file.md"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fixturePath])
        fixturePath = @"/usr/local/share/finch/markdown-file.md";
    NSURL *fileURL = [NSURL fileURLWithPath:fixturePath];
    NSError *fileError = nil;
    NSAttributedString *fileResult = [[NSAttributedString alloc] initWithContentsOfMarkdownFileAtURL:fileURL
                                                                                              options:nil
                                                                                             baseURL:base
                                                                                               error:&fileError];
    NSString *fileSource = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    print_result("file", fileResult, fileError, fileSource);

    const unsigned char invalidBytes[] = { 0xff, 0xfe, 0x00 };
    NSData *invalidData = [NSData dataWithBytes:invalidBytes length:sizeof(invalidBytes)];
    NSError *invalidError = nil;
    NSAttributedString *invalidResult = [[NSAttributedString alloc] initWithMarkdown:invalidData options:nil
                                                                               baseURL:nil error:&invalidError];
    print_result("invalid-data", invalidResult, invalidError, @"");
    invalidError = nil;
    invalidResult = [[NSAttributedString alloc] initWithMarkdown:invalidData
                                                        options:options(NSAttributedStringMarkdownInterpretedSyntaxFull,
                                                            NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible,
                                                            NO, nil)
                                                         baseURL:nil error:&invalidError];
    print_result("partial-invalid-data", invalidResult, invalidError, @"");
    return 0;
}

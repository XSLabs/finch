/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Word 97 documents (.doc): an attributed string with each run and paragraph attribute
 * TextEdit gives written, read back and printed, with the document's attributes; compared
 * with Apple's. With a path, that .doc is read instead (to read the other's files).
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

static NSString *
color_string(NSColor *c)
{
    NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    return rgb ? [NSString stringWithFormat:@"%.3f %.3f %.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent] : @"?";
}

static void
dump(NSAttributedString *back, NSDictionary *da)
{
    [back enumerateAttributesInRange:NSMakeRange(0, back.length) options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
        NSString *t = [[[back.string substringWithRange:r] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
            stringByReplacingOccurrencesOfString:@" " withString:@"\\u2028"];
        NSFont *font = a[NSFontAttributeName];
        NSFontTraitMask traits = [[NSFontManager sharedFontManager] traitsOfFont:font];
        printf("[%s] %.1f%s%s", t.UTF8String, font.pointSize, (traits & NSBoldFontMask) ? " bold" : "",
               (traits & NSItalicFontMask) ? " italic" : "");
        for (NSString *k in [a.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id v = a[k];
            if ([k isEqual:NSFontAttributeName])
                continue;
            if ([k isEqual:NSParagraphStyleAttributeName]) {
                NSParagraphStyle *ps = v;
                NSMutableArray *tabs = [NSMutableArray array];
                for (NSTextTab *tab in ps.tabStops)
                    [tabs addObject:[NSString stringWithFormat:@"%g%c", tab.location, tab.tabStopType == NSDecimalTabStopType ? 'D' : 'L']];
                printf(" para{al %ld head %g first %g tail %g after %g before %g mult %g min %g max %g dir %ld deftab %g tabs %s}",
                       (long)ps.alignment, ps.headIndent, ps.firstLineHeadIndent, ps.tailIndent, ps.paragraphSpacing,
                       ps.paragraphSpacingBefore, ps.lineHeightMultiple, ps.minimumLineHeight, ps.maximumLineHeight,
                       (long)ps.baseWritingDirection, ps.defaultTabInterval, [[tabs componentsJoinedByString:@","] UTF8String]);
            } else if ([v isKindOfClass:[NSColor class]]) {
                printf(" %s=%s", k.UTF8String, color_string(v).UTF8String);
            } else {
                printf(" %s=%s", k.UTF8String, [[v description] UTF8String]);
            }
        }
        printf("\n");
    }];
    for (NSString *k in [da.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id v = da[k];
        if ([k isEqual:NSCreationTimeDocumentAttribute] || [k isEqual:NSModificationTimeDocumentAttribute])
            v = [v isKindOfClass:[NSDate class]] ? @"(date)" : v;
        if ([v isKindOfClass:[NSArray class]])
            v = [v componentsJoinedByString:@"|"];
        printf("doc %s = %s\n", k.UTF8String, [[v description] UTF8String]);
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    if (argc > 1) {
        NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSDictionary *da = nil;
        NSError *e = nil;
        NSAttributedString *back = [[NSAttributedString alloc] initWithData:d options:@{} documentAttributes:&da error:&e];
        printf("read %s: %s\n", argv[1], back ? "ok" : e.description.UTF8String);
        dump(back, da);
        if (argc > 2) {
            NSData *again = [back dataFromRange:NSMakeRange(0, back.length) documentAttributes:@{NSDocumentTypeDocumentAttribute: NSDocFormatTextDocumentType} error:&e];
            [again writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
        }
        return 0;
    }
    Dl_info info;
    dladdr((__bridge void *)[NSAttributedString class], &info);
    printf("word documents: %s\n", info.dli_fname);
    NSFont *h = [NSFont fontWithName:@"Helvetica" size:12];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    void (^add)(NSString *, NSDictionary *) = ^(NSString *t, NSDictionary *a) {
        NSMutableDictionary *m = [@{NSFontAttributeName: h} mutableCopy];
        [m addEntriesFromDictionary:a];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:m]];
    };
    NSFontManager *fm = [NSFontManager sharedFontManager];
    add(@"bold", @{NSFontAttributeName: [fm convertFont:h toHaveTrait:NSBoldFontMask]});
    add(@" italic", @{NSFontAttributeName: [fm convertFont:h toHaveTrait:NSItalicFontMask]});
    add(@" big", @{NSFontAttributeName: [NSFont fontWithName:@"Times New Roman" size:20] ?: h});
    add(@" strike", @{NSStrikethroughStyleAttributeName: @1});
    add(@" super", @{NSSuperscriptAttributeName: @1});
    add(@" sub", @{NSSuperscriptAttributeName: @-1});
    add(@" back", @{NSBackgroundColorAttributeName: [NSColor yellowColor]});
    add(@" under", @{NSUnderlineStyleAttributeName: @1});
    add(@" double", @{NSUnderlineStyleAttributeName: @(NSUnderlineStyleDouble)});
    add(@" red", @{NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1 green:0 blue:0 alpha:1]});
    add(@" teal", @{NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.1 green:0.5 blue:0.7 alpha:1]});
    add(@" kern", @{NSKernAttributeName: @2});
    add(@" raised", @{NSBaselineOffsetAttributeName: @3});
    add(@" outline", @{NSStrokeWidthAttributeName: @3});
    add(@"\tTab Line é ü 中\n", @{});
    NSMutableParagraphStyle *p;
    p = [NSMutableParagraphStyle new]; p.alignment = NSTextAlignmentRight; add(@"right\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.alignment = NSTextAlignmentCenter; add(@"centre\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.alignment = NSTextAlignmentJustified; add(@"justified\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.headIndent = 36; p.firstLineHeadIndent = 18; p.tailIndent = -20;
    add(@"indents\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.paragraphSpacing = 10; p.paragraphSpacingBefore = 6;
    add(@"spacing\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.minimumLineHeight = 20; p.maximumLineHeight = 20;
    add(@"exactly\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.minimumLineHeight = 20; add(@"at least\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new];
    p.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:100 options:@{}],
                   [[NSTextTab alloc] initWithType:NSDecimalTabStopType location:200]];
    add(@"tabs\n", @{NSParagraphStyleAttributeName: p});
    p = [NSMutableParagraphStyle new]; p.baseWritingDirection = NSWritingDirectionRightToLeft;
    add(@"right to left\n", @{NSParagraphStyleAttributeName: p});
    add(@"last", @{});
    NSDictionary *attrs = @{NSDocumentTypeDocumentAttribute: NSDocFormatTextDocumentType, NSTitleDocumentAttribute: @"Title",
                            NSAuthorDocumentAttribute: @"Author", NSSubjectDocumentAttribute: @"Subject",
                            NSKeywordsDocumentAttribute: @[@"one", @"two"], NSCommentDocumentAttribute: @"Comment",
                            NSCompanyDocumentAttribute: @"Company", NSCopyrightDocumentAttribute: @"Copyright",
                            NSEditorDocumentAttribute: @"Editor", NSViewModeDocumentAttribute: @1};
    NSError *e = nil;
    NSData *d = [s dataFromRange:NSMakeRange(0, s.length) documentAttributes:attrs error:&e];
    printf("written: %s\n", d ? "yes" : e.description.UTF8String);
    const char *keep = getenv("WORDDOC_TEST_OUT");
    if (keep)
        [d writeToFile:[NSString stringWithUTF8String:keep] atomically:YES];
    NSDictionary *da = nil;
    NSAttributedString *back = d ? [[NSAttributedString alloc] initWithData:d options:@{} documentAttributes:&da error:&e] : nil;
    printf("read back: %s\n", back ? "yes" : e.description.UTF8String);
    dump(back, da);
    /* a long document: more runs and paragraphs than a page of properties holds */
    NSMutableAttributedString *longDoc = [[NSMutableAttributedString alloc] init];
    for (int i = 0; i < 700; i++) {
        NSMutableParagraphStyle *lp = [NSMutableParagraphStyle new];
        lp.alignment = i % 3 == 0 ? NSTextAlignmentCenter : NSTextAlignmentNatural;
        lp.headIndent = i % 7;
        [longDoc appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"Line %d ", i]
            attributes:@{NSFontAttributeName: h, NSParagraphStyleAttributeName: lp}]];
        [longDoc appendAttributedString:[[NSAttributedString alloc] initWithString:@"bold"
            attributes:@{NSFontAttributeName: [fm convertFont:h toHaveTrait:NSBoldFontMask], NSParagraphStyleAttributeName: lp}]];
        [longDoc appendAttributedString:[[NSAttributedString alloc] initWithString:@" end\n"
            attributes:@{NSFontAttributeName: [NSFont fontWithName:@"Helvetica" size:10 + i % 5], NSParagraphStyleAttributeName: lp}]];
    }
    NSData *longData = [longDoc dataFromRange:NSMakeRange(0, longDoc.length)
                                documentAttributes:@{NSDocumentTypeDocumentAttribute: NSDocFormatTextDocumentType} error:&e];
    NSAttributedString *longBack = [[NSAttributedString alloc] initWithData:longData options:@{} documentAttributes:NULL error:&e];
    __block NSUInteger runs = 0, bold = 0, centred = 0;
    __block CGFloat sizes = 0, indents = 0;
    [longBack enumerateAttributesInRange:NSMakeRange(0, longBack.length) options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
        runs++;
        if ([fm traitsOfFont:a[NSFontAttributeName]] & NSBoldFontMask)
            bold++;
        sizes += [a[NSFontAttributeName] pointSize];
        NSParagraphStyle *lps = a[NSParagraphStyleAttributeName];
        if (lps.alignment == NSTextAlignmentCenter)
            centred += r.length;
        indents += lps.headIndent;
    }];
    if (getenv("WORDDOC_TEST_LONG"))
        [longData writeToFile:[NSString stringWithUTF8String:getenv("WORDDOC_TEST_LONG")] atomically:YES];
    printf("long: text same %d, %lu runs, %lu bold, sizes %g, centred %lu, indents %g\n",
           [longBack.string isEqualToString:longDoc.string], (unsigned long)runs, (unsigned long)bold, sizes,
           (unsigned long)centred, indents);
    NSDictionary *plain = nil;
    NSData *empty = [[[NSAttributedString alloc] initWithString:@""] dataFromRange:NSMakeRange(0, 0)
        documentAttributes:@{NSDocumentTypeDocumentAttribute: NSDocFormatTextDocumentType} error:&e];
    NSAttributedString *none = [[NSAttributedString alloc] initWithData:empty options:@{} documentAttributes:&plain error:&e];
    printf("empty: [%s]\n", [[none.string stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]);
} return 0; }

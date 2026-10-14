/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Attributed strings written as HTML, web archives, Word 2003 XML, Word 2007 (.docx) and
 * OpenDocument text, and read back: each run's text, size, weight, underline and the
 * paragraph's alignment. Compared with Apple's (font families and colours are left out:
 * Finch's fonts stand in for Apple's, and Apple's Word and OpenDocument readers drop colours).
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    Dl_info info;
    dladdr((__bridge void *)[NSAttributedString class], &info);
    printf("text formats: %s\n", info.dli_fname);
    NSString *types[] = {NSHTMLTextDocumentType, NSWebArchiveTextDocumentType, NSWordMLTextDocumentType,
                         NSOfficeOpenXMLTextDocumentType, NSOpenDocumentTextDocumentType};
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    NSFont *f = [NSFont fontWithName:@"Helvetica" size:14];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"Plain and " attributes:@{NSFontAttributeName: f}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"bold" attributes:@{NSFontAttributeName:
        [[NSFontManager sharedFontManager] convertFont:f toHaveTrait:NSBoldFontMask]}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@" & <escaped>\n" attributes:@{NSFontAttributeName: f}]];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"Centred underlined" attributes:@{
        NSFontAttributeName: [NSFont fontWithName:@"Times New Roman" size:20] ?: f, NSParagraphStyleAttributeName: ps,
        NSUnderlineStyleAttributeName: @1}]];
    for (int i = 0; i < 5; i++) {
        NSError *e = nil;
        NSData *d = [s dataFromRange:NSMakeRange(0, s.length) documentAttributes:@{NSDocumentTypeDocumentAttribute: types[i]}
                               error:&e];
        NSAttributedString *back = d ? [[NSAttributedString alloc] initWithData:d options:@{} documentAttributes:NULL error:&e] : nil;
        printf("%s: %s\n", types[i].UTF8String, back ? "read back" : "failed");
        [back enumerateAttributesInRange:NSMakeRange(0, back.length) options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
            NSFont *font = a[NSFontAttributeName];
            NSString *t = [[back.string substringWithRange:r] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
            printf("  [%s] %.0f%s%s align %ld\n", t.UTF8String, font.pointSize,
                   ([[NSFontManager sharedFontManager] traitsOfFont:font] & NSBoldFontMask) ? " bold" : "",
                   [a[NSUnderlineStyleAttributeName] intValue] ? " underline" : "", (long)[a[NSParagraphStyleAttributeName] alignment]);
        }];
    }
} return 0; }

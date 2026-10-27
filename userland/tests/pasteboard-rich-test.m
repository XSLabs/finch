/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-pasteboard-rich-test: rich text and images through the pasteboard, as apps copy
 * and paste them: a text view's types and its RTF copy pasted into rich and plain
 * views, and an image written and read back (NSImage and its reps). Compared with
 * Apple's AppKit.
 */
#import <AppKit/AppKit.h>
#include <stdio.h>

static NSString *
types(NSPasteboard *pb)
{
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *t in pb.types)
        if (![t hasPrefix:@"dyn."] && ![t hasPrefix:@"CorePasteboardFlavorType"] && ![t isEqualToString:@"public.utf16-external-plain-text"])
            [list addObject:t];
    return [list componentsJoinedByString:@" | "];
}

static void
describe_font(NSTextStorage *s, NSUInteger i)
{
    NSFont *f = [s attribute:NSFontAttributeName atIndex:i effectiveRange:NULL];
    NSColor *c = [[s attribute:NSForegroundColorAttributeName atIndex:i effectiveRange:NULL] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    printf("  at %lu: size %.0f bold %d color %s\n", (unsigned long)i, f.pointSize,
           (f.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0,
           c ? [NSString stringWithFormat:@"%.2f %.2f %.2f", c.redComponent, c.greenComponent, c.blueComponent].UTF8String : "none");
}

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];

        NSTextView *rich = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        printf("rich readable: %s\n", [[rich.readablePasteboardTypes componentsJoinedByString:@" | "] UTF8String]);
        printf("rich writable without a selection: %lu\n", (unsigned long)rich.writablePasteboardTypes.count);
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"plain bold red"];
        [s addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:20] range:NSMakeRange(6, 4)];
        [s addAttribute:NSForegroundColorAttributeName value:[NSColor redColor] range:NSMakeRange(11, 3)];
        [rich.textStorage setAttributedString:s];
        rich.selectedRange = NSMakeRange(0, s.length);
        printf("rich writable: %s\n", [[rich.writablePasteboardTypes componentsJoinedByString:@" | "] UTF8String]);
        rich.importsGraphics = YES;
        printf("graphics writable: %s\n", [[rich.writablePasteboardTypes componentsJoinedByString:@" | "] UTF8String]);
        rich.importsGraphics = NO;
        printf("written %d: %s\n", [rich writeSelectionToPasteboard:pb types:rich.writablePasteboardTypes], types(pb).UTF8String);

        NSTextView *into = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        printf("pasted rich %d: '%s'\n", [into readSelectionFromPasteboard:pb], into.string.UTF8String);
        describe_font(into.textStorage, 0);
        describe_font(into.textStorage, 6);
        describe_font(into.textStorage, 12);

        NSTextView *plain = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        plain.richText = NO;
        printf("plain readable: %s\n", [[plain.readablePasteboardTypes componentsJoinedByString:@" | "] UTF8String]);
        printf("pasted plain %d: '%s'\n", [plain readSelectionFromPasteboard:pb], plain.string.UTF8String);
        plain.selectedRange = NSMakeRange(0, 5);
        printf("plain writable: %s\n", [[plain.writablePasteboardTypes componentsJoinedByString:@" | "] UTF8String]);

        NSImage *im = [[NSImage alloc] initWithSize:NSMakeSize(4, 3)];
        [im lockFocus];
        [[NSColor redColor] set];
        NSRectFill(NSMakeRect(0, 0, 4, 3));
        [im unlockFocus];
        [pb clearContents];
        printf("image written %d: %s\n", [pb writeObjects:@[ im ]], types(pb).UTF8String);
        printf("image can init %d, bitmap %d, pdf %d\n", [NSImage canInitWithPasteboard:pb], [NSBitmapImageRep canInitWithPasteboard:pb],
               [NSPDFImageRep canInitWithPasteboard:pb]);
        NSImage *back = [[NSImage alloc] initWithPasteboard:pb];
        printf("image read: %s, %lu reps\n", NSStringFromSize(back.size).UTF8String, (unsigned long)back.representations.count);
        NSArray *objects = [pb readObjectsForClasses:@[ [NSImage class] ] options:nil];
        printf("objects read: %lu, %s\n", (unsigned long)objects.count, NSStringFromSize([objects.firstObject size]).UTF8String);
        printf("bitmap reps: %lu\n", (unsigned long)[NSBitmapImageRep imageRepsWithPasteboard:pb].count);
        printf("unfiltered pasteboard types: %s\n", [[[NSImage imageUnfilteredPasteboardTypes] componentsJoinedByString:@" | "] UTF8String]);
        [pb clearContents];
        [pb setString:@"x" forType:NSPasteboardTypeString];
        printf("text is an image: %d\n", [NSImage canInitWithPasteboard:pb]);
    }
    return 0;
}

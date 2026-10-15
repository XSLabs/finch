/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * pbcopy and pbpaste (one source, named by how it's run), as macOS's: pbcopy puts its
 * standard input on a pasteboard as text, pbpaste writes a pasteboard's text (or, with
 * -Prefer rtf or ps, that flavour when it's there) to its standard output.
 *
 *   pbcopy [-pboard general|ruler|find|font]
 *   pbpaste [-pboard general|ruler|find|font] [-Prefer txt|rtf|ps]
 */
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSPasteboard *
pasteboard(const char *name)
{
    if (!name || !strcmp(name, "general"))
        return [NSPasteboard generalPasteboard];
    if (!strcmp(name, "ruler"))
        return [NSPasteboard pasteboardWithName:NSPasteboardNameRuler];
    if (!strcmp(name, "find"))
        return [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
    if (!strcmp(name, "font"))
        return [NSPasteboard pasteboardWithName:NSPasteboardNameFont];
    return nil;
}

static int
usage(BOOL copy)
{
    fprintf(stderr, copy ? "usage: pbcopy [-pboard {general | ruler | find | font}]\n"
                         : "usage: pbpaste [-pboard {general | ruler | find | font}] [-Prefer {txt | rtf | ps}]\n");
    return 1;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        const char *slash = strrchr(argv[0], '/');
        BOOL copy = strstr(slash ? slash + 1 : argv[0], "copy") != NULL;
        const char *board = NULL, *prefer = "txt";
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-pboard") && i + 1 < argc)
                board = argv[++i];
            else if (!copy && !strcmp(argv[i], "-Prefer") && i + 1 < argc)
                prefer = argv[++i];
            else if (!strcmp(argv[i], "-help") || !strcmp(argv[i], "-h"))
                return usage(copy), 0;
            else
                return usage(copy);
        }
        NSPasteboard *pb = pasteboard(board);
        if (!pb)
            return usage(copy);
        if (copy) {
            NSData *in = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSString *text = [[NSString alloc] initWithData:in encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:in encoding:NSMacOSRomanStringEncoding];
            [pb clearContents];
            return [pb setString:text forType:NSPasteboardTypeString] ? 0 : 1;
        }
        NSData *out = nil;
        if (!strcmp(prefer, "rtf"))
            out = [pb dataForType:NSPasteboardTypeRTF];
        else if (!strcmp(prefer, "ps"))
            out = [pb dataForType:@"com.adobe.encapsulated-postscript"];
        else if (strcmp(prefer, "txt"))
            return usage(copy);
        if (!out)
            out = [[pb stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
        if (out)
            fwrite(out.bytes, 1, out.length, stdout);
        return 0;
    }
}

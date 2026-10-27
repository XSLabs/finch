/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-filewrapper-rtfd-test: file wrappers' serialized representation (the
 * pasteboard's RTFD): a directory with a file, a subdirectory and a link, and a
 * lone file. host-tests runs it across systems: Finch reads what Apple's run
 * writes and Apple reads Finch's.
 *
 *     finch-filewrapper-rtfd-test write|read FILE [ignored]
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

static NSFileWrapper *
file(NSData *contents, NSString *name)
{
    NSFileWrapper *w = [[NSFileWrapper alloc] initRegularFileWithContents:contents];
    w.preferredFilename = name;
    return w;
}

static NSString *
describe(NSFileWrapper *w)
{
    if (w.isRegularFile) return [[NSString alloc] initWithData:w.regularFileContents encoding:NSUTF8StringEncoding] ?: @"(binary)";
    if (w.isSymbolicLink) return w.symbolicLinkDestinationURL.path;
    return [[w.fileWrappers.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 3) return 2;
        printf("NSFileWrapper serialized representations\n");
        NSString *path = @(argv[2]), *lonePath = [path stringByAppendingString:@"1"];
        if (!strcmp(argv[1], "write")) {
            NSFileWrapper *d = [[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{}];
            [d addFileWrapper:file([@"héllo" dataUsingEncoding:NSUTF8StringEncoding], @"TXT.rtf")];
            NSFileWrapper *sub = [[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{}];
            sub.preferredFilename = @"pics";
            [sub addFileWrapper:file([NSData dataWithBytes:"\x89PNG" length:4], @"a.png")];
            [d addFileWrapper:sub];
            NSFileWrapper *link = [[NSFileWrapper alloc] initSymbolicLinkWithDestinationURL:[NSURL fileURLWithPath:@"/tmp/x"]];
            link.preferredFilename = @"ln";
            [d addFileWrapper:link];
            [d.serializedRepresentation writeToFile:path atomically:YES];
            [file([@"solo" dataUsingEncoding:NSUTF8StringEncoding], @"solo.txt").serializedRepresentation writeToFile:lonePath atomically:YES];
        }
        NSFileWrapper *d = [[NSFileWrapper alloc] initWithSerializedRepresentation:[NSData dataWithContentsOfFile:path]];
        printf("directory %d: %s\n", d.isDirectory, describe(d).UTF8String);
        for (NSString *name in [d.fileWrappers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSFileWrapper *w = d.fileWrappers[name];
            printf("  %s directory %d link %d: %s, permissions %o\n", name.UTF8String, w.isDirectory, w.isSymbolicLink, describe(w).UTF8String,
                   [w.fileAttributes[NSFilePosixPermissions] intValue]);
        }
        NSFileWrapper *lone = [[NSFileWrapper alloc] initWithSerializedRepresentation:[NSData dataWithContentsOfFile:lonePath]];
        printf("lone file %s: %s\n", lone.preferredFilename.UTF8String, describe(lone).UTF8String);
        printf("junk %s\n", [[NSFileWrapper alloc] initWithSerializedRepresentation:[NSData dataWithBytes:"junk" length:4]] ? "read" : "refused");
    }
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-pasteboard-test: pasteboards, run against Apple's AppKit and Finch's to compare
 * (tools/host-tests.sh) on a pasteboard of its own (not the clipboard): writing and
 * reading text, URLs, items and property lists; the old API's declared types with an
 * owner that provides the data when it's read; item data providers; change counts; and
 * the Pasteboard Manager on the same pasteboard.
 *
 * With "cross" (Finch's VM, where finch-pboardd runs) it shares a pasteboard between two
 * processes: one writes text and promises more, the other (a child) reads both, the
 * promise kept by the writer while it waits; then the child writes and the parent reads.
 *
 *   finch-pasteboard-test [cross | child NAME]
 */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

@interface Owner : NSObject
@property NSInteger asked;
@end

@implementation Owner
- (void)pasteboard:(NSPasteboard *)sender provideDataForType:(NSPasteboardType)type
{
    self.asked++;
    [sender setString:[NSString stringWithFormat:@"provided %@", type] forType:type];
}
@end

@interface Provider : NSObject <NSPasteboardItemDataProvider>
@property NSInteger asked;
@end

@implementation Provider
- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type
{
    self.asked++;
    [item setString:@"lazy item text" forType:type];
}
@end

static NSString *
types(NSArray *t)
{
    return [t componentsJoinedByString:@","];
}

static void
local(void)
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    NSInteger c0 = pb.changeCount;
    NSInteger c1 = [pb clearContents];
    printf("clear: change count moved %d, returned it %d\n", c1 != c0, c1 == pb.changeCount);
    printf("write text and URL: %d\n", [pb writeObjects:@[ @"hello", [NSURL URLWithString:@"https://example.com/a"] ]]);
    printf("count changed by writing %d\n", pb.changeCount != c1);
    NSArray *items = pb.pasteboardItems;
    printf("items %lu: [%s] [%s]\n", (unsigned long)items.count, types([items[0] types]).UTF8String, types([items[1] types]).UTF8String);
    printf("types: %s\n", types(pb.types).UTF8String);
    printf("string %s, old name %s\n", [pb stringForType:NSPasteboardTypeString].UTF8String, [pb stringForType:NSStringPboardType].UTF8String);
    NSArray *read = [pb readObjectsForClasses:@[ [NSURL class], [NSString class] ] options:nil];
    printf("read objects: %s\n", [[read valueForKey:@"description"] componentsJoinedByString:@" | "].UTF8String);
    printf("can read string %d, image %d\n", [pb canReadObjectForClasses:@[ [NSString class] ] options:nil],
           [pb availableTypeFromArray:@[ NSPasteboardTypePNG ]] != nil);

    /* the old API: declared types, the owner asked when they're read */
    Owner *owner = [Owner new];
    NSInteger d = [pb declareTypes:@[ NSPasteboardTypeString, @"org.finch.custom" ] owner:owner];
    printf("declared: count %d types %s asked %ld\n", d == pb.changeCount, types(pb.types).UTF8String, (long)owner.asked);
    printf("read: %s, asked %ld\n", [pb stringForType:@"org.finch.custom"].UTF8String, (long)owner.asked);
    printf("again: %s, asked %ld\n", [pb stringForType:@"org.finch.custom"].UTF8String, (long)owner.asked);
    [pb setString:@"set now" forType:NSPasteboardTypeString];
    printf("set then read: %s, asked %ld\n", [pb stringForType:NSPasteboardTypeString].UTF8String, (long)owner.asked);
    [pb addTypes:@[ NSPasteboardTypeTabularText ] owner:nil];
    printf("added: %s\n", types(pb.types).UTF8String);

    /* items with data providers, and property lists */
    [pb clearContents];
    Provider *provider = [Provider new];
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setDataProvider:provider forTypes:@[ NSPasteboardTypeString ]];
    [item setPropertyList:@[ @"/a", @"/b" ] forType:@"org.finch.list"];
    printf("write item %d, asked %ld\n", [pb writeObjects:@[ item ]], (long)provider.asked);
    NSPasteboardItem *back = pb.pasteboardItems.firstObject;
    printf("item types [%s]\n", types([back types]).UTF8String);
    printf("provided: %s, asked %ld; plist %s\n", [back stringForType:NSPasteboardTypeString].UTF8String, (long)provider.asked,
           [[[back propertyListForType:@"org.finch.list"] componentsJoinedByString:@" "] UTF8String]);
    [pb setData:[NSData dataWithBytes:"\x01\x02" length:2] forType:@"org.finch.bytes"];
    printf("data: %lu bytes\n", (unsigned long)[pb dataForType:@"org.finch.bytes"].length);

    /* the Pasteboard Manager on the same pasteboard */
    PasteboardRef carbon = NULL;
    printf("create %d\n", (int)PasteboardCreate((__bridge CFStringRef)pb.name, &carbon));
    PasteboardSyncFlags f = PasteboardSynchronize(carbon);
    ItemCount n = 0;
    PasteboardGetItemCount(carbon, &n);
    printf("carbon: modified %d owner %d, %lu items\n", (f & kPasteboardModified) != 0, (f & kPasteboardClientIsOwner) != 0, (unsigned long)n);
    PasteboardItemID id1 = 0;
    PasteboardGetItemIdentifier(carbon, 1, &id1);
    CFArrayRef flavors = NULL;
    PasteboardCopyItemFlavors(carbon, id1, &flavors);
    printf("carbon flavors [%s]\n", types((__bridge NSArray *)flavors).UTF8String);
    CFDataRef data = NULL;
    OSStatus e = PasteboardCopyItemFlavorData(carbon, id1, CFSTR("public.utf8-plain-text"), &data);
    printf("carbon data %d: %s\n", (int)e, [[NSString alloc] initWithData:(__bridge NSData *)data encoding:NSUTF8StringEncoding].UTF8String);
    printf("put without owning: %d\n", (int)PasteboardPutItemFlavor(carbon, (PasteboardItemID)7, CFSTR("public.utf8-plain-text"),
                                                                     (__bridge CFDataRef)[@"x" dataUsingEncoding:4], 0));
    printf("clear %d\n", (int)PasteboardClear(carbon));
    f = PasteboardSynchronize(carbon);
    printf("after clear: owner %d\n", (f & kPasteboardClientIsOwner) != 0);
    printf("put %d\n", (int)PasteboardPutItemFlavor(carbon, (PasteboardItemID)7, CFSTR("public.utf8-plain-text"),
                                                     (__bridge CFDataRef)[@"from carbon" dataUsingEncoding:4], 0));
    printf("NSPasteboard reads: %s, items %lu\n", [pb stringForType:NSPasteboardTypeString].UTF8String,
           (unsigned long)pb.pasteboardItems.count);
    printf("bad index %d, bad item %d\n", (int)PasteboardGetItemIdentifier(carbon, 9, &id1),
           (int)PasteboardCopyItemFlavors(carbon, (PasteboardItemID)99, &flavors));
    CFRelease(carbon);
    [pb releaseGlobally];
}

/* --- across processes (Finch) --- */

static void
pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static int
child(NSString *name)
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:name];
    printf("child sees: %s; types %s\n", [pb stringForType:NSPasteboardTypeString].UTF8String, types(pb.types).UTF8String);
    printf("child reads the promise: %s\n", [pb stringForType:@"org.finch.custom"].UTF8String);
    [pb clearContents];
    [pb setString:@"written by the child" forType:NSPasteboardTypeString];
    return 0;
}

static void
cross(const char *self_path)
{
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:@"org.finch.test.cross"];
    Owner *owner = [Owner new];
    [pb declareTypes:@[ NSPasteboardTypeString, @"org.finch.custom" ] owner:owner];
    [pb setString:@"written by the parent" forType:NSPasteboardTypeString];
    pid_t pid;
    char *args[] = {(char *)self_path, "child", "org.finch.test.cross", NULL};
    posix_spawnp(&pid, self_path, NULL, NULL, args, environ);
    /* (the run loop turns while the child reads, so the promise can be kept) */
    int status = 0;
    for (int i = 0; i < 100 && waitpid(pid, &status, WNOHANG) == 0; i++)
        pump(0.1);
    printf("parent: owner asked %ld; now reads %s\n", (long)owner.asked, [pb stringForType:NSPasteboardTypeString].UTF8String);
    [pb releaseGlobally];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [NSApplication sharedApplication];
        if (argc > 2 && !strcmp(argv[1], "child"))
            return child(@(argv[2]));
        printf("%s\n", [[NSBundle bundleForClass:[NSPasteboard class]] executablePath].UTF8String);
        if (argc > 1 && !strcmp(argv[1], "cross"))
            cross(argv[0]);
        else
            local();
    }
    return 0;
}

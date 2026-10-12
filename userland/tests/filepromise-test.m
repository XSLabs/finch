/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * File promises on a pasteboard (what a provider writes, what a receiver reads), and
 * reading objects of an app's own NSPasteboardReading class; compared with Apple's.
 * (Receiving a promise's file goes through the drag machinery on Apple's, so it isn't
 * compared here.)
 */
#import <AppKit/AppKit.h>

@interface Delegate : NSObject <NSFilePromiseProviderDelegate>
@end
@implementation Delegate
- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)p fileNameForType:(NSString *)t
{
    return @"promised.txt";
}
- (void)filePromiseProvider:(NSFilePromiseProvider *)p writePromiseToURL:(NSURL *)url completionHandler:(void (^)(NSError *))done
{
    done(nil);
}
@end

@interface Note : NSObject <NSPasteboardWriting, NSPasteboardReading>
@property (copy) NSString *text;
@end
@implementation Note
- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pb { return @[ @"org.finch.note", NSPasteboardTypeString ]; }
- (id)pasteboardPropertyListForType:(NSPasteboardType)type
{
    return [type isEqualToString:@"org.finch.note"] ? @{@"text" : self.text} : self.text;
}
+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pb { return @[ @"org.finch.note" ]; }
+ (NSPasteboardReadingOptions)readingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard *)pb
{
    return NSPasteboardReadingAsPropertyList;
}
- (instancetype)initWithPasteboardPropertyList:(id)plist ofType:(NSPasteboardType)type
{
    if ((self = [super init]))
        self.text = [plist isKindOfClass:[NSDictionary class]] ? plist[@"text"] : nil;
    return self.text ? self : nil;
}
@end

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        Delegate *d = [Delegate new];
        NSFilePromiseProvider *p = [[NSFilePromiseProvider alloc] initWithFileType:@"public.plain-text" delegate:d];
        printf("provider: type %s delegate %d user %s\n", p.fileType.UTF8String, p.delegate == d, [p.userInfo description].UTF8String);
        NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
        NSArray *types = [p writableTypesForPasteboard:pb];
        printf("writable: %s\n", [types componentsJoinedByString:@", "].UTF8String);
        for (NSString *t in types) {
            id v = [p pasteboardPropertyListForType:t];
            printf("  %s -> %s\n", t.UTF8String,
                [v isKindOfClass:[NSData class]] ? [NSString stringWithFormat:@"%lu bytes", (unsigned long)[v length]].UTF8String
                                                 : [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
        }
        printf("writing options: %lu\n", (unsigned long)[p writingOptionsForType:types.firstObject pasteboard:pb]);
        printf("receiver readable: %s\n", [[NSFilePromiseReceiver readableDraggedTypes] componentsJoinedByString:@", "].UTF8String);
        [pb clearContents];
        printf("write: %d\n", [pb writeObjects:@[ p ]]);
        BOOL all = YES;
        for (NSString *t in types)
            all = all && [pb.types containsObject:t];
        printf("pasteboard has every written type: %d\n", all);
        NSArray *rs = [pb readObjectsForClasses:@[ [NSFilePromiseReceiver class] ] options:nil];
        NSFilePromiseReceiver *r = rs.firstObject;
        printf("receivers %lu: types %s names %s\n", (unsigned long)rs.count, [r.fileTypes componentsJoinedByString:@","].UTF8String,
            [r.fileNames componentsJoinedByString:@","].UTF8String);

        /* an app's own reading class */
        Note *n = [Note new];
        n.text = @"a note";
        [pb clearContents];
        [pb writeObjects:@[ n ]];
        NSArray *notes = [pb readObjectsForClasses:@[ [Note class] ] options:nil];
        printf("notes back: %lu %s; strings %s\n", (unsigned long)notes.count, [notes.firstObject text].UTF8String,
            [[pb readObjectsForClasses:@[ [NSString class] ] options:nil].firstObject UTF8String]);
        printf("can read notes %d, receivers %d\n", [pb canReadObjectForClasses:@[ [Note class] ] options:nil],
            [pb canReadObjectForClasses:@[ [NSFilePromiseReceiver class] ] options:nil]);
    }
    return 0;
}

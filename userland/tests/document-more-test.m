/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSDocument and NSDocumentController beyond the basics: the deprecated file-name
 * methods and the chain by which the current ones call an app's overrides of them,
 * synchronous saving, locking (the file's immutable flag), moving, duplicating, draft
 * names, file-presenter callbacks, printing's defaults, restoration keys and the
 * controller's type and document helpers. Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#include <sys/stat.h>
#include <unistd.h>

/* A document written the old way: data representations and file names. */
@interface OldDoc : NSDocument
@property (copy) NSString *text;
@property NSMutableArray *calls;
@end
@implementation OldDoc
- (instancetype)init { if ((self = [super init])) self.calls = [NSMutableArray array]; return self; }
- (BOOL)loadDataRepresentation:(NSData *)data ofType:(NSString *)type
{
    [self.calls addObject:@"loadDataRepresentation"];
    self.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return YES;
}
- (NSData *)dataRepresentationOfType:(NSString *)type
{
    [self.calls addObject:@"dataRepresentation"];
    return [self.text dataUsingEncoding:NSUTF8StringEncoding];
}
@end

/* One that overrides the file-based reading and writing. */
@interface FileDoc : NSDocument
@property NSMutableArray *calls;
@end
@implementation FileDoc
- (instancetype)init { if ((self = [super init])) self.calls = [NSMutableArray array]; return self; }
- (BOOL)readFromFile:(NSString *)fileName ofType:(NSString *)type
{
    [self.calls addObject:[@"readFromFile " stringByAppendingString:fileName.lastPathComponent]];
    return YES;
}
- (BOOL)writeToFile:(NSString *)fileName ofType:(NSString *)type
{
    [self.calls addObject:[@"writeToFile " stringByAppendingString:fileName.lastPathComponent]];
    return [@"file" writeToFile:fileName atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}
@end

/* A current-style document. */
@interface NewDoc : NSDocument
@property (copy) NSString *text;
@end
@implementation NewDoc
- (BOOL)readFromData:(NSData *)data ofType:(NSString *)type error:(NSError **)e
{
    self.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return YES;
}
- (NSData *)dataOfType:(NSString *)type error:(NSError **)e { return [self.text ?: @"" dataUsingEncoding:NSUTF8StringEncoding]; }
@end

static BOOL
immutable(NSURL *url)
{
    struct stat st;
    return stat(url.fileSystemRepresentation, &st) == 0 && (st.st_flags & UF_IMMUTABLE);
}

static void
spin(void)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [NSApplication sharedApplication];
        printf("NSDocument more\n");
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-docmore"];
        system([[NSString stringWithFormat:@"chflags -R nouchg '%@' 2>/dev/null", dir] UTF8String]);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *a = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"a.txt"]];
        [@"hello" writeToURL:a atomically:NO encoding:NSUTF8StringEncoding error:nil];

        /* the deprecated chain */
        NSError *error = nil;
        OldDoc *old = [[OldDoc alloc] initWithContentsOfURL:a ofType:@"public.plain-text" error:&error];
        printf("old read: %s via %s, fileName %s, last %s\n", old.text.UTF8String, [old.calls componentsJoinedByString:@","].UTF8String,
            old.fileName.lastPathComponent.UTF8String, old.lastComponentOfFileName.UTF8String);
        old.text = @"changed";
        NSURL *b = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"b.txt"]];
        BOOL ok = [old writeToURL:b ofType:@"public.plain-text" error:&error];
        printf("old write: %d %s, calls %s\n", ok, [NSString stringWithContentsOfURL:b encoding:NSUTF8StringEncoding error:nil].UTF8String,
            [old.calls componentsJoinedByString:@","].UTF8String);
        [old setFileName:[dir stringByAppendingPathComponent:@"c.txt"]];
        printf("set file name: %s\n", old.fileURL.lastPathComponent.UTF8String);
        [old setLastComponentOfFileName:@"d.txt"];
        printf("set last component: %s\n", old.fileURL.lastPathComponent.UTF8String);
        OldDoc *byFile = [[OldDoc alloc] initWithContentsOfFile:a.path ofType:@"public.plain-text"];
        printf("init with file: %s url %s\n", byFile.text.UTF8String, byFile.fileURL.lastPathComponent.UTF8String);
        FileDoc *fd = [[FileDoc alloc] initWithContentsOfURL:a ofType:@"public.plain-text" error:&error];
        ok = [fd writeToURL:b ofType:@"public.plain-text" error:&error];
        printf("file doc: %d calls %s\n", ok, [fd.calls componentsJoinedByString:@","].UTF8String);

        /* synchronous saving */
        NewDoc *nd = [[NewDoc alloc] initWithType:@"public.plain-text" error:&error];
        nd.text = @"saved";
        NSURL *s = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"s.txt"]];
        ok = [nd saveToURL:s ofType:@"public.plain-text" forSaveOperation:NSSaveAsOperation error:&error];
        printf("sync save: %d %s, url %s edited %d\n", ok, [NSString stringWithContentsOfURL:s encoding:NSUTF8StringEncoding error:nil].UTF8String,
            nd.fileURL.lastPathComponent.UTF8String, nd.isDocumentEdited);
        printf("draft name: %s, default user activity %s\n", nd.defaultDraftName.UTF8String, nd.userActivity ? "set" : "nil");

        /* locking */
        printf("locked before: %d (flag %d)\n", nd.isLocked, immutable(s));
        __block NSError *lockError = (id)@"pending";
        [nd lockWithCompletionHandler:^(NSError *e) { lockError = e; }];
        spin();
        /* (Apple's isLocked and unlocking settle later, by file presentation: only the flag is compared) */
        printf("lock: %s, flag %d\n", lockError ? "error" : "done", immutable(s));
        chflags(s.fileSystemRepresentation, 0);

        /* moving */
        NSURL *moved = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"moved.txt"]];
        __block NSError *moveError = (id)@"pending";
        [nd moveToURL:moved completionHandler:^(NSError *e) { moveError = e; }];
        spin();
        printf("move: %s, url %s, old exists %d new exists %d\n", moveError ? "error" : "done", nd.fileURL.lastPathComponent.UTF8String,
            [[NSFileManager defaultManager] fileExistsAtPath:s.path], [[NSFileManager defaultManager] fileExistsAtPath:moved.path]);

        /* file presenter */
        NSURL *elsewhere = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"elsewhere.txt"]];
        [nd presentedItemDidMoveToURL:elsewhere];
        spin();
        printf("presented move: %s\n", nd.fileURL.lastPathComponent.UTF8String);
        printf("presented item: %s, queue %s\n", nd.presentedItemURL.lastPathComponent.UTF8String, nd.presentedItemOperationQueue ? "set" : "nil");

        /* duplicating */
        NSDocumentController *dc = [NSDocumentController sharedDocumentController];
        NewDoc *src = [[NewDoc alloc] initWithContentsOfURL:a ofType:@"public.plain-text" error:&error];
        NSError *dupError = nil;
        NSDocument *dup = [dc duplicateDocumentWithContentsOfURL:a copying:YES displayName:@"Copy Name" error:&dupError];
        printf("duplicate: %s, class %s, url %s, name %s, edited %d, documents %lu\n", dup ? "doc" : "nil", dup ? object_getClassName(dup) : "-",
            dup.fileURL ? "set" : "nil", dup.displayName.UTF8String, dup.isDocumentEdited, (unsigned long)dc.documents.count);
        (void)src;

        /* printing defaults */
        @try {
            NSError *pe = nil;
            NSPrintOperation *op = [nd printOperationWithSettings:@{} error:&pe];
            printf("print operation: %s error %ld\n", op ? "op" : "nil", (long)pe.code);
        } @catch (NSException *e) {
            printf("print operation: raises %s\n", e.name.UTF8String);
        }
        printf("should change print info: %d\n", [nd shouldChangePrintInfo:[NSPrintInfo sharedPrintInfo]]);

        /* restoration keys */
        printf("restorable key paths: %s\n", [[NSDocument restorableStateKeyPaths] componentsJoinedByString:@","].UTF8String);
        printf("allowed classes: %lu\n", (unsigned long)[NSDocument allowedClassesForRestorableStateKeyPath:@"x"].count);

        /* controller helpers */
        printf("controller: should create UI %d, type for txt %s, extensions %s\n", dc.shouldCreateUI,
            [dc typeFromFileExtension:@"txt"].UTF8String ?: "nil", [[dc fileExtensionsFromType:@"public.plain-text"] componentsJoinedByString:@","].UTF8String);
        NSMenuItem *share = [dc standardShareMenuItem];
        printf("share item: %s action %s\n", share.title.UTF8String, NSStringFromSelector(share.action).UTF8String);
        printf("document for file name: %s\n", [dc documentForFileName:a.path] ? "found" : "nil");
        @try {
            id made = [dc makeUntitledDocumentOfType:@"public.plain-text"];
            printf("make untitled (old): %s\n", made ? "doc" : "nil");
        } @catch (NSException *e) {
            printf("make untitled (old): raises %s\n", e.name.UTF8String);
        }
        system([[NSString stringWithFormat:@"chflags -R nouchg '%@' 2>/dev/null", dir] UTF8String]);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

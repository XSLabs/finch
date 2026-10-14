/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFileVersion's version store: adding versions of a file, listing, finding by persistent
 * identifier, replacing the file with one, removing one and all. Compared with Apple's.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

int main(void) { @autoreleasepool {
    Dl_info info;
    dladdr((__bridge void *)[NSFileVersion class], &info);
    printf("Foundation: %s\n", info.dli_fname);
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/finch-fileversion-test"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *u = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"doc.txt"]];
    [@"one" writeToURL:u atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    printf("others at start: %lu\n", (unsigned long)[NSFileVersion otherVersionsOfItemAtURL:u].count);
    NSError *e = nil;
    NSFileVersion *v1 = [NSFileVersion addVersionOfItemAtURL:u withContentsOfURL:u options:0 error:&e];
    printf("add: %s %s\n", v1 ? "ok" : "nil", e.description.UTF8String ?: "");
    [@"two" writeToURL:u atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    NSFileVersion *v2 = [NSFileVersion addVersionOfItemAtURL:u withContentsOfURL:u options:0 error:&e];
    NSArray *others = [NSFileVersion otherVersionsOfItemAtURL:u];
    printf("others: %lu\n", (unsigned long)others.count);
    for (NSFileVersion *v in others)
        printf("  name %s url-is-doc %d contents %s pid %s computer %s discardable %d conflict %d local %d\n",
               v.localizedName.UTF8String, [v.URL isEqual:u],
               [[NSString stringWithContentsOfURL:v.URL encoding:NSUTF8StringEncoding error:NULL] UTF8String],
               [(id)v.persistentIdentifier isKindOfClass:[NSArray class]] ? "array" : "other", v.localizedNameOfSavingComputer.UTF8String,
               v.discardable, v.conflict, v.hasLocalContents);
    NSFileVersion *cur = [NSFileVersion currentVersionOfItemAtURL:u];
    printf("current in others: %d\n", [others containsObject:cur]);
    NSFileVersion *found = [NSFileVersion versionOfItemAtURL:u forPersistentIdentifier:v1.persistentIdentifier];
    printf("found by id: %s\n", [[NSString stringWithContentsOfURL:found.URL encoding:NSUTF8StringEncoding error:NULL] UTF8String]);
    NSURL *r = [v1 replaceItemAtURL:u options:0 error:&e];
    printf("replace: %s now %s\n", r ? "ok" : e.description.UTF8String,
           [[NSString stringWithContentsOfURL:u encoding:NSUTF8StringEncoding error:NULL] UTF8String]);
    printf("remove v2: %d\n", [v2 removeAndReturnError:&e]);
    printf("others: %lu\n", (unsigned long)[NSFileVersion otherVersionsOfItemAtURL:u].count);
    printf("remove others: %d\n", [NSFileVersion removeOtherVersionsOfItemAtURL:u error:&e]);
    printf("others: %lu\n", (unsigned long)[NSFileVersion otherVersionsOfItemAtURL:u].count);
    printf("remove current: %d\n", [cur removeAndReturnError:&e]);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
} return 0; }

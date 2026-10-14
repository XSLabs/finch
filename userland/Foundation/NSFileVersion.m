/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFileVersion. Apple's keeps a file's past versions in the volume's document revision
 * store (revisiond); Finch's keeps them in the user's version store,
 * ~/Library/Application Support/Finch/Versions: a folder per document, holding each
 * version's contents and a list of them (versions.plist: its identifier, file, date and
 * name). A document is known by an identifier in an extended attribute on it, or, when a
 * safe save has replaced the file without it, by its path (index.plist). As Apple's: a
 * version's persistent identifier is an array, its URL is the stored copy's, versions
 * replace a file by copying, and the current version can't be removed.
 */
#import <Foundation/Foundation.h>
#include <sys/xattr.h>
#include <unistd.h>

static NSString *const DocumentIDAttribute = @"org.finch.document-id";

@interface NSFileVersion ()
- (instancetype)_initWithURL:(NSURL *)url;
@end

@implementation NSFileVersion {
    NSURL *_URL;
    BOOL _resolved, _discardable;
    NSString *_documentID, *_versionID, *_name;
    NSDate *_date;
}

#pragma mark - The store

static NSString *
store_root(void)
{
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Finch/Versions"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    return root;
}

static NSString *
index_path(void)
{
    return [store_root() stringByAppendingPathComponent:@"index.plist"];
}

static NSString *
attribute_of(NSURL *url)
{
    char buf[64];
    ssize_t n = getxattr(url.fileSystemRepresentation, DocumentIDAttribute.UTF8String, buf, sizeof buf - 1, 0, 0);
    if (n <= 0)
        return nil;
    buf[n] = 0;
    return [NSString stringWithUTF8String:buf];
}

/* The document's identifier in the store; with `create`, one is given it when it has none. */
static NSString *
document_id(NSURL *url, BOOL create)
{
    if (!url.isFileURL)
        return nil;
    NSString *path = url.URLByStandardizingPath.path;
    NSString *ident = attribute_of(url);
    NSMutableDictionary *index = [NSMutableDictionary dictionaryWithContentsOfFile:index_path()] ?: [NSMutableDictionary dictionary];
    if (!ident)
        ident = index[path];
    if (!ident && !create)
        return nil;
    if (!ident)
        ident = [[NSUUID UUID] UUIDString];
    if (!attribute_of(url))
        setxattr(url.fileSystemRepresentation, DocumentIDAttribute.UTF8String, ident.UTF8String, strlen(ident.UTF8String), 0, 0);
    if (![index[path] isEqual:ident]) {
        index[path] = ident;
        [index writeToFile:index_path() atomically:YES];
    }
    return ident;
}

static NSString *
document_folder(NSString *ident)
{
    return [store_root() stringByAppendingPathComponent:ident];
}

static NSMutableArray *
version_list(NSString *ident)
{
    NSString *plist = [document_folder(ident) stringByAppendingPathComponent:@"versions.plist"];
    return [NSMutableArray arrayWithContentsOfFile:plist] ?: [NSMutableArray array];
}

static void
save_version_list(NSString *ident, NSArray *list)
{
    [list writeToFile:[document_folder(ident) stringByAppendingPathComponent:@"versions.plist"] atomically:YES];
}

- (instancetype)_initWithDocument:(NSString *)ident entry:(NSDictionary *)entry
{
    NSURL *url = [NSURL fileURLWithPath:[document_folder(ident) stringByAppendingPathComponent:entry[@"file"]]];
    if ((self = [self _initWithURL:url])) {
        _documentID = [ident copy];
        _versionID = [entry[@"id"] copy];
        _name = [entry[@"name"] copy];
        _date = [entry[@"date"] retain];
    }
    return self;
}

- (instancetype)_initWithURL:(NSURL *)url
{
    if ((self = [super init]))
        _URL = [url copy];
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_documentID release];
    [_versionID release];
    [_name release];
    [_date release];
    [super dealloc];
}

+ (NSFileVersion *)currentVersionOfItemAtURL:(NSURL *)url
{
    if (!url.isFileURL || ![url checkResourceIsReachableAndReturnError:NULL])
        return nil;
    return [[[self alloc] _initWithURL:url] autorelease];
}

+ (NSArray *)otherVersionsOfItemAtURL:(NSURL *)url
{
    if (!url.isFileURL)
        return nil;
    NSString *ident = document_id(url, NO);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *entry in ident ? version_list(ident) : @[])
        [out addObject:[[[self alloc] _initWithDocument:ident entry:entry] autorelease]];
    return out;
}
+ (NSArray *)unresolvedConflictVersionsOfItemAtURL:(NSURL *)url { return url.isFileURL ? @[] : nil; }

+ (void)getNonlocalVersionsOfItemAtURL:(NSURL *)url completionHandler:(void (^)(NSArray<NSFileVersion *> *, NSError *))handler
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        handler(@[], nil);
    });
}

+ (NSFileVersion *)versionOfItemAtURL:(NSURL *)url forPersistentIdentifier:(id)persistentIdentifier
{
    NSFileVersion *current = [self currentVersionOfItemAtURL:url];
    if ([persistentIdentifier isEqual:current.persistentIdentifier])
        return current;
    for (NSFileVersion *v in [self otherVersionsOfItemAtURL:url])
        if ([persistentIdentifier isEqual:v.persistentIdentifier])
            return v;
    return nil;
}

+ (NSFileVersion *)addVersionOfItemAtURL:(NSURL *)url withContentsOfURL:(NSURL *)contentsURL
                                 options:(NSFileVersionAddingOptions)options error:(NSError **)error
{
    if (!url.isFileURL || !contentsURL.isFileURL || ![url checkResourceIsReachableAndReturnError:error])
        return nil;
    NSString *ident = document_id(url, YES);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *folder = document_folder(ident);
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSString *versionID = [[NSUUID UUID] UUIDString];
    NSString *ext = url.pathExtension;
    NSString *file = ext.length ? [versionID stringByAppendingPathExtension:ext] : versionID;
    NSURL *stored = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:file]];
    BOOL ok = (options & NSFileVersionAddingByMoving) ? [fm moveItemAtURL:contentsURL toURL:stored error:error]
                                                      : [fm copyItemAtURL:contentsURL toURL:stored error:error];
    if (!ok)
        return nil;
    NSDate *date = nil;
    [contentsURL getResourceValue:&date forKey:NSURLContentModificationDateKey error:NULL];
    if (!date)
        [stored getResourceValue:&date forKey:NSURLContentModificationDateKey error:NULL];
    NSString *name = nil;
    [url getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL];
    NSDictionary *entry = @{@"id" : versionID, @"file" : file, @"date" : date ?: [NSDate date],
                            @"name" : name ?: url.lastPathComponent};
    NSMutableArray *list = version_list(ident);
    [list addObject:entry];
    save_version_list(ident, list);
    return [[[self alloc] _initWithDocument:ident entry:entry] autorelease];
}

+ (NSURL *)temporaryDirectoryURLForNewVersionOfItemAtURL:(NSURL *)url
{
    NSURL *dir = [[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                                               appropriateForURL:url create:YES error:NULL];
    return dir ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
}

+ (BOOL)removeOtherVersionsOfItemAtURL:(NSURL *)url error:(NSError **)error
{
    NSString *ident = document_id(url, NO);
    if (!ident)
        return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *entry in version_list(ident))
        [fm removeItemAtPath:[document_folder(ident) stringByAppendingPathComponent:entry[@"file"]] error:NULL];
    save_version_list(ident, @[]);
    return YES;
}

- (NSURL *)URL { return _URL; }

- (NSString *)localizedName
{
    if (_name)
        return _name;
    NSString *name = nil;
    [_URL getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL];
    return name ?: _URL.lastPathComponent;
}

- (NSString *)localizedNameOfSavingComputer { return nil; }
- (NSPersonNameComponents *)originatorNameComponents { return nil; }

- (NSDate *)modificationDate
{
    if (_date)
        return _date;
    NSDate *d = nil;
    [_URL getResourceValue:&d forKey:NSURLContentModificationDateKey error:NULL];
    return d;
}

- (id<NSCoding>)persistentIdentifier
{
    return _versionID ? @[ _documentID, _versionID ] : @[];
}
- (BOOL)isConflict { return NO; }
- (BOOL)isResolved { return _resolved; }
- (void)setResolved:(BOOL)resolved { _resolved = resolved; }
- (BOOL)isDiscardable { return _discardable; }
- (void)setDiscardable:(BOOL)discardable { _discardable = discardable; }
- (BOOL)hasLocalContents { return YES; }
- (BOOL)hasThumbnail { return NO; }

- (NSURL *)replaceItemAtURL:(NSURL *)url options:(NSFileVersionReplacingOptions)options error:(NSError **)error
{
    if ([url isEqual:_URL])
        return url;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (options & NSFileVersionReplacingByMoving) {
        NSURL *result = nil;
        if ([fm replaceItemAtURL:url withItemAtURL:_URL backupItemName:nil options:0 resultingItemURL:&result error:error])
            return result;
        return nil;
    }
    [fm removeItemAtURL:url error:NULL];
    return [fm copyItemAtURL:_URL toURL:url error:error] ? url : nil;
}

- (BOOL)removeAndReturnError:(NSError **)error
{
    if (_versionID) {
        NSMutableArray *list = version_list(_documentID);
        NSUInteger at = [list indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) {
            return [entry[@"id"] isEqual:_versionID];
        }];
        if (at != NSNotFound) {
            [list removeObjectAtIndex:at];
            save_version_list(_documentID, list);
        }
        [[NSFileManager defaultManager] removeItemAtURL:_URL error:NULL];
        return YES;
    }
    /* the current version can't be removed */
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:@{NSURLErrorKey : _URL}];
    return NO;
}

@end

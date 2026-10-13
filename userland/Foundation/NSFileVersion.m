/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFileVersion. Apple's keeps a file's past versions in the volume's document revision
 * store; Finch has none yet, so a file has its current version and no others, and
 * adding a version fails as unsupported. The current version describes the file as it
 * is now, as Apple's does.
 */
#import <Foundation/Foundation.h>

@implementation NSFileVersion {
    NSURL *_URL;
    BOOL _resolved, _discardable;
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
    [super dealloc];
}

+ (NSFileVersion *)currentVersionOfItemAtURL:(NSURL *)url
{
    if (!url.isFileURL || ![url checkResourceIsReachableAndReturnError:NULL])
        return nil;
    return [[[self alloc] _initWithURL:url] autorelease];
}

+ (NSArray *)otherVersionsOfItemAtURL:(NSURL *)url { return url.isFileURL ? @[] : nil; }
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
    return [persistentIdentifier isEqual:current.persistentIdentifier] ? current : nil;
}

+ (NSFileVersion *)addVersionOfItemAtURL:(NSURL *)url withContentsOfURL:(NSURL *)contentsURL
                                 options:(NSFileVersionAddingOptions)options error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:@{NSURLErrorKey : url ?: [NSNull null]}];
    return nil;
}

+ (NSURL *)temporaryDirectoryURLForNewVersionOfItemAtURL:(NSURL *)url
{
    NSURL *dir = [[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                                               appropriateForURL:url create:YES error:NULL];
    return dir ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
}

+ (BOOL)removeOtherVersionsOfItemAtURL:(NSURL *)url error:(NSError **)error { return YES; }

- (NSURL *)URL { return _URL; }

- (NSString *)localizedName
{
    NSString *name = nil;
    [_URL getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL];
    return name ?: _URL.lastPathComponent;
}

- (NSString *)localizedNameOfSavingComputer { return nil; }
- (NSPersonNameComponents *)originatorNameComponents { return nil; }

- (NSDate *)modificationDate
{
    NSDate *d = nil;
    [_URL getResourceValue:&d forKey:NSURLContentModificationDateKey error:NULL];
    return d;
}

- (id<NSCoding>)persistentIdentifier { return @{}; }
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
    /* the current version can't be removed */
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:@{NSURLErrorKey : _URL}];
    return NO;
}

@end

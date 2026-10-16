/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CSSearchableIndex stores each app's items in a small, locked local archive. The file is
 * replaced atomically after each change, so a reader never sees a half-written index.
 */
#import "CoreSpotlight_Finch.h"
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

static NSString *
index_directory(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"Finch/CoreSpotlight"] stringByStandardizingPath];
}

NSString *
FinchCSSearchIndexPath(NSString *name)
{
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"default";
    NSString *indexIdentifier = [NSString stringWithFormat:@"%@\n%@", bundleIdentifier, name ?: @"default"];
    NSData *bytes = [indexIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    NSString *encoded = [bytes base64EncodedStringWithOptions:0];
    encoded = [[encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return [[index_directory() stringByAppendingPathComponent:encoded] stringByAppendingPathExtension:@"index"];
}

static int
lock_file(NSString *path, int mode)
{
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                              attributes:@{ NSFilePosixPermissions : @0700 } error:NULL];
    int fd = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0)
        return -1;
    if (flock(fd, mode) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static NSMutableDictionary *
read_store(NSString *path)
{
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *store = [stored mutableCopy] ?: [NSMutableDictionary dictionary];
    if (![store[@"items"] isKindOfClass:[NSDictionary class]])
        store[@"items"] = [NSMutableDictionary dictionary];
    else
        store[@"items"] = [store[@"items"] mutableCopy];
    return store;
}

static NSError *
write_store(NSString *path, NSDictionary *store)
{
    if (![store writeToFile:path atomically:YES])
        return [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeRemoteConnectionError
                               userInfo:@{ NSLocalizedDescriptionKey : @"The local searchable index could not be saved." }];
    return nil;
}

static NSError *
mutate_store(NSString *path, void (^change)(NSMutableDictionary *store, NSError **error))
{
    int fd = lock_file(path, LOCK_EX);
    if (fd < 0)
        return [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeRemoteConnectionError
                               userInfo:@{ NSLocalizedDescriptionKey : @"The local searchable index could not be opened." }];
    NSMutableDictionary *store = read_store(path);
    NSError *error = nil;
    change(store, &error);
    if (!error)
        error = write_store(path, store);
    flock(fd, LOCK_UN);
    close(fd);
    return error;
}

static NSDictionary *
snapshot_store(NSString *path)
{
    int fd = lock_file(path, LOCK_SH);
    if (fd < 0)
        return @{};
    NSDictionary *store = [read_store(path) copy];
    flock(fd, LOCK_UN);
    close(fd);
    return store;
}

static CSSearchableItem *
decode_item(id data)
{
    if (![data isKindOfClass:[NSData class]])
        return nil;
    @try {
        id item = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        return [item isKindOfClass:[CSSearchableItem class]] ? item : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void
index_items(NSString *path, NSArray<CSSearchableItem *> *items, NSError **outError)
{
    NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
        NSMutableDictionary *stored = store[@"items"];
        for (CSSearchableItem *item in items) {
            if (![item isKindOfClass:[CSSearchableItem class]] || !item.uniqueIdentifier.length) {
                *innerError = [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeInvalidItemError
                                              userInfo:@{ NSLocalizedDescriptionKey : @"A searchable item needs an identifier." }];
                return;
            }
            if (item.isUpdate && !stored[item.uniqueIdentifier])
                continue;
            NSError *archiveError = nil;
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:item requiringSecureCoding:NO error:&archiveError];
            if (!data) {
                *innerError = archiveError ?: [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeInvalidItemError userInfo:nil];
                return;
            }
            stored[item.uniqueIdentifier] = data;
        }
    });
    if (outError)
        *outError = error;
}

static NSArray<CSSearchableItem *> *
items_in_store(NSString *path)
{
    NSDictionary *store = snapshot_store(path);
    NSMutableArray *items = [NSMutableArray array];
    for (NSData *data in [store[@"items"] allValues]) {
        CSSearchableItem *item = decode_item(data);
        if (item && [item.expirationDate compare:[NSDate date]] == NSOrderedDescending)
            [items addObject:item];
    }
    return items;
}

NSArray<CSSearchableItem *> *
FinchCSSearchItemsNamed(NSString *name)
{
    return items_in_store(FinchCSSearchIndexPath(name));
}

NSArray<CSSearchableItem *> *
FinchCSSearchAllItems(void)
{
    NSString *dir = index_directory();
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"index"])
            continue;
        [all addObjectsFromArray:items_in_store([dir stringByAppendingPathComponent:entry])];
    }
    return all;
}

@implementation CSSearchableIndex {
    NSString *_name;
    __weak id<CSSearchableIndexDelegate> _indexDelegate;
    BOOL _batching;
}

+ (BOOL)isIndexingAvailable { return YES; }
+ (instancetype)defaultSearchableIndex
{
    static CSSearchableIndex *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = NSBundle.mainBundle.bundleIdentifier ?: @"default";
        index = [[self alloc] initWithName:name];
    });
    return index;
}
- (instancetype)initWithName:(NSString *)name { return [self initWithName:name protectionClass:nil]; }
- (instancetype)initWithName:(NSString *)name protectionClass:(NSFileProtectionType)protectionClass
{
    if ((self = [super init]))
        _name = [name copy] ?: @"default";
    return self;
}
- (id<CSSearchableIndexDelegate>)indexDelegate { return _indexDelegate; }
- (void)setIndexDelegate:(id<CSSearchableIndexDelegate>)delegate { _indexDelegate = delegate; }

- (void)indexSearchableItems:(NSArray<CSSearchableItem *> *)items completionHandler:(void (^)(NSError *))completion
{
    NSArray *copy = [items copy] ?: @[];
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        index_items(path, copy, &error);
        if (completion)
            completion(error);
    });
}

- (void)deleteSearchableItemsWithIdentifiers:(NSArray<NSString *> *)identifiers completionHandler:(void (^)(NSError *))completion
{
    NSSet *ids = [NSSet setWithArray:identifiers ?: @[]];
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
            NSMutableDictionary *items = store[@"items"];
            [items removeObjectsForKeys:ids.allObjects];
        });
        if (completion)
            completion(error);
    });
}

- (void)deleteSearchableItemsWithDomainIdentifiers:(NSArray<NSString *> *)domains completionHandler:(void (^)(NSError *))completion
{
    NSSet *domainSet = [NSSet setWithArray:domains ?: @[]];
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
            NSMutableDictionary *items = store[@"items"];
            for (NSString *key in [items.allKeys copy]) {
                CSSearchableItem *item = decode_item(items[key]);
                NSString *domain = item.domainIdentifier;
                for (NSString *wanted in domainSet)
                    if (domain && ([domain isEqualToString:wanted] || [domain hasPrefix:[wanted stringByAppendingString:@"."]])) {
                        [items removeObjectForKey:key];
                        break;
                    }
            }
        });
        if (completion)
            completion(error);
    });
}

- (void)deleteAllSearchableItemsWithCompletionHandler:(void (^)(NSError *))completion
{
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
            store[@"items"] = [NSMutableDictionary dictionary];
            [store removeObjectForKey:@"clientState"];
        });
        if (completion)
            completion(error);
    });
}

- (void)beginIndexBatch { @synchronized(self) { _batching = YES; } }

- (void)endIndexBatchWithClientState:(NSData *)clientState completionHandler:(void (^)(NSError *))completion
{
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
            if (clientState)
                store[@"clientState"] = clientState;
            else
                [store removeObjectForKey:@"clientState"];
        });
        @synchronized(self) { _batching = NO; }
        if (completion)
            completion(error);
    });
}

- (void)endIndexBatchWithExpectedClientState:(NSData *)expected newClientState:(NSData *)newState completionHandler:(void (^)(NSError *))completion
{
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = mutate_store(path, ^(NSMutableDictionary *store, NSError **innerError) {
            NSData *current = store[@"clientState"];
            BOOL matches = (!expected && !current) || [expected isEqualToData:current];
            if (!matches) {
                *innerError = [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeMismatchedClientState
                                              userInfo:@{ NSLocalizedDescriptionKey : @"The saved index state no longer matches." }];
                return;
            }
            store[@"clientState"] = newState;
        });
        @synchronized(self) { _batching = NO; }
        if (completion)
            completion(error);
    });
}

- (void)fetchLastClientStateWithCompletionHandler:(void (^)(NSData *, NSError *))completion
{
    NSString *path = FinchCSSearchIndexPath(_name);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *state = snapshot_store(path)[@"clientState"];
        if (completion)
            completion(state, nil);
    });
}

- (void)fetchDataForBundleIdentifier:(NSString *)bundleIdentifier itemIdentifier:(NSString *)itemIdentifier
                         contentType:(UTType *)contentType completionHandler:(void (^)(NSData *, NSError *))completion
{
    NSData *data = nil;
    NSError *error = nil;
    id<CSSearchableIndexDelegate> delegate = _indexDelegate;
    SEL selector = @selector(dataForSearchableIndex:itemIdentifier:typeIdentifier:error:);
    if ([delegate respondsToSelector:selector]) {
        data = [delegate dataForSearchableIndex:self itemIdentifier:itemIdentifier typeIdentifier:contentType.identifier error:&error];
    } else {
        error = [NSError errorWithDomain:CSIndexErrorDomain code:CSIndexErrorCodeInvalidItemError
                                userInfo:@{ NSLocalizedDescriptionKey : @"No item data provider is registered for this index." }];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (completion)
            completion(data, error);
    });
}

@end

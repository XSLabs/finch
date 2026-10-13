/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSMetadataItem and NSMetadataQuery. Apple's ask Spotlight's index; Finch has no index
 * yet, so an item's attributes are what the file system says (Apple's kMDItemFS* set,
 * with the path, display name, kind, content type and its tree), and a query walks its
 * search scopes, testing each file against its predicate. Gathering happens on a
 * background queue; results, the notifications and the delegate's calls arrive on the
 * query's operation queue, or the main thread, as Apple's do. Live updates after
 * gathering aren't sent, and the ubiquitous scopes are empty.
 */
#import <Foundation/Foundation.h>
#include <sys/stat.h>

/* ---- NSMetadataItem ---- */

@implementation NSMetadataItem {
    NSString *_path;
    NSDictionary *_attrs;
}

- (instancetype)initWithURL:(NSURL *)url
{
    if (!url.isFileURL) {
        [self release];
        return nil;
    }
    const char *p = url.path.fileSystemRepresentation;
    char real[PATH_MAX];
    struct stat st;
    if (!p || !realpath(p, real) || lstat(real, &st) != 0) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _path = [[[NSFileManager defaultManager] stringWithFileSystemRepresentation:real length:strlen(real)] retain];
        NSURL *u = [NSURL fileURLWithPath:_path];
        NSNumber *hidden = nil, *extHidden = nil;
        [u getResourceValue:&hidden forKey:NSURLIsHiddenKey error:NULL];
        [u getResourceValue:&extHidden forKey:NSURLHasHiddenExtensionKey error:NULL];
        long long nodes = 1;
        if (S_ISDIR(st.st_mode))
            nodes = (long long)[[NSFileManager defaultManager] contentsOfDirectoryAtPath:_path error:NULL].count;
        NSDate *created = [NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec + st.st_birthtimespec.tv_nsec / 1e9];
        NSDate *changed = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9];
        long long size = S_ISDIR(st.st_mode) ? nodes : (long long)st.st_size;
        _attrs = [@{
            @"kMDItemFSName" : _path.lastPathComponent,
            @"kMDItemFSSize" : @(size),
            @"kMDItemFSCreationDate" : created,
            @"kMDItemFSContentChangeDate" : changed,
            @"kMDItemFSOwnerUserID" : @(st.st_uid),
            @"kMDItemFSOwnerGroupID" : @(st.st_gid),
            @"kMDItemFSNodeCount" : @(nodes),
            @"kMDItemFSInvisible" : @(hidden.boolValue),
            @"kMDItemFSIsExtensionHidden" : @(extHidden.boolValue),
            @"kMDItemFSLabel" : @0,
            @"kMDItemFSTypeCode" : @0,
            @"kMDItemFSCreatorCode" : @0,
            @"kMDItemFSFinderFlags" : @0,
            @"kMDItemFSHasCustomIcon" : @NO,
            @"kMDItemFSIsStationery" : @NO,
        } retain];
    }
    return self;
}

- (void)dealloc
{
    [_path release];
    [_attrs release];
    [super dealloc];
}

- (NSArray *)attributes { return _attrs.allKeys; }

/* The content type and the types it conforms to, from UniformTypeIdentifiers when it's loaded. */
static NSArray *
type_tree(NSString *type)
{
    Class UTType = NSClassFromString(@"UTType");
    id t = [UTType performSelector:@selector(typeWithIdentifier:) withObject:type];
    if (!t)
        return @[ type ];
    NSMutableArray *a = [NSMutableArray arrayWithObject:type];
    for (id s in [t valueForKey:@"supertypes"])
        [a addObject:[s valueForKey:@"identifier"]];
    return a;
}

- (id)valueForAttribute:(NSString *)key
{
    id v = _attrs[key];
    if (v)
        return v;
    NSURL *u = [NSURL fileURLWithPath:_path];
    if ([key isEqualToString:NSMetadataItemPathKey])
        return _path;
    if ([key isEqualToString:NSMetadataItemDisplayNameKey]) {
        NSString *n = nil;
        [u getResourceValue:&n forKey:NSURLLocalizedNameKey error:NULL];
        return n ?: _path.lastPathComponent;
    }
    if ([key isEqualToString:NSMetadataItemContentTypeKey] || [key isEqualToString:NSMetadataItemContentTypeTreeKey]) {
        NSString *t = nil;
        [u getResourceValue:&t forKey:NSURLTypeIdentifierKey error:NULL];
        if (!t)
            return nil;
        return [key isEqualToString:NSMetadataItemContentTypeKey] ? t : type_tree(t);
    }
    if ([key isEqualToString:NSMetadataItemKindKey]) {
        NSString *k = nil;
        [u getResourceValue:&k forKey:NSURLLocalizedTypeDescriptionKey error:NULL];
        return k;
    }
    if ([key isEqualToString:NSMetadataItemContentModificationDateKey])
        return _attrs[@"kMDItemFSContentChangeDate"];
    if ([key isEqualToString:NSMetadataItemContentCreationDateKey])
        return _attrs[@"kMDItemFSCreationDate"];
    if ([key isEqualToString:@"kMDItemLogicalSize"])
        return _attrs[@"kMDItemFSSize"];
    return nil;
}

- (NSDictionary *)valuesForAttributes:(NSArray *)keys
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        id v = [self valueForAttribute:k];
        if (v)
            d[k] = v;
    }
    return d;
}

/* So that predicates and sort descriptors can name attributes as keys. */
- (id)valueForKey:(NSString *)key
{
    return [key hasPrefix:@"kMD"] || [key hasPrefix:@"NSMetadata"] ? [self valueForAttribute:key] : [super valueForKey:key];
}

- (id)valueForUndefinedKey:(NSString *)key { return [self valueForAttribute:key]; }

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, _path]; }

@end

/* ---- NSMetadataQueryAttributeValueTuple, NSMetadataQueryResultGroup ---- */

@implementation NSMetadataQueryAttributeValueTuple

- (instancetype)_initWithAttribute:(NSString *)a value:(id)v count:(NSUInteger)n
{
    if ((self = [super init])) {
        _attr = [a copy];
        _value = [v retain];
        _count = n;
    }
    return self;
}

- (void)dealloc
{
    [_attr release];
    [_value release];
    [super dealloc];
}

- (NSString *)attribute { return _attr; }
- (id)value { return _value; }
- (NSUInteger)count { return _count; }

@end

@implementation NSMetadataQueryResultGroup {
    NSString *_attribute;
    id _value;
    NSArray *_results, *_subgroups;
}

- (instancetype)_initWithAttribute:(NSString *)a value:(id)v results:(NSArray *)r subgroups:(NSArray *)s
{
    if ((self = [super init])) {
        _attribute = [a copy];
        _value = [v retain];
        _results = [r copy];
        _subgroups = [s copy];
    }
    return self;
}

- (void)dealloc
{
    [_attribute release];
    [_value release];
    [_results release];
    [_subgroups release];
    [super dealloc];
}

- (NSString *)attribute { return _attribute; }
- (id)value { return _value; }
- (NSArray *)subgroups { return _subgroups; }
- (NSUInteger)resultCount { return _results.count; }
- (id)resultAtIndex:(NSUInteger)i { return _results[i]; }
- (NSArray *)results { return _results; }

@end

/* ---- NSMetadataQuery ---- */

@implementation NSMetadataQuery {
    id<NSMetadataQueryDelegate> _delegate;
    NSPredicate *_predicate;
    NSArray *_sortDescriptors, *_valueListAttributes, *_groupingAttributes, *_searchScopes, *_searchItems;
    NSTimeInterval _batching;
    NSOperationQueue *_operationQueue;
    NSMutableArray *_results;
    NSArray *_groups;
    NSDictionary *_valueLists;
    BOOL _started, _gathering, _stopped;
    NSInteger _disabled;
    unsigned _generation;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _results = [NSMutableArray new];
        _batching = 1;
        _searchScopes = [@[] retain];
    }
    return self;
}

- (void)dealloc
{
    [_predicate release];
    [_sortDescriptors release];
    [_valueListAttributes release];
    [_groupingAttributes release];
    [_searchScopes release];
    [_searchItems release];
    [_operationQueue release];
    [_results release];
    [_groups release];
    [_valueLists release];
    [super dealloc];
}

- (id<NSMetadataQueryDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSMetadataQueryDelegate>)d { _delegate = d; }
- (NSPredicate *)predicate { return _predicate; }
- (void)setPredicate:(NSPredicate *)p { [_predicate autorelease]; _predicate = [p copy]; }
- (NSArray *)sortDescriptors { return _sortDescriptors ?: @[]; }
- (void)setSortDescriptors:(NSArray *)s { [_sortDescriptors autorelease]; _sortDescriptors = [s copy]; }
- (NSArray *)valueListAttributes { return _valueListAttributes ?: @[]; }
- (void)setValueListAttributes:(NSArray *)a { [_valueListAttributes autorelease]; _valueListAttributes = [a copy]; }
- (NSArray *)groupingAttributes { return _groupingAttributes; }
- (void)setGroupingAttributes:(NSArray *)a { [_groupingAttributes autorelease]; _groupingAttributes = [a copy]; }
- (NSTimeInterval)notificationBatchingInterval { return _batching; }
- (void)setNotificationBatchingInterval:(NSTimeInterval)t { _batching = t; }
- (NSArray *)searchScopes { return _searchScopes; }
- (void)setSearchScopes:(NSArray *)s { [_searchScopes autorelease]; _searchScopes = [s copy] ?: [@[] retain]; }
- (NSArray *)searchItems { return _searchItems; }
- (void)setSearchItems:(NSArray *)s { [_searchItems autorelease]; _searchItems = [s copy]; }
- (NSOperationQueue *)operationQueue { return _operationQueue; }
- (void)setOperationQueue:(NSOperationQueue *)q { [_operationQueue autorelease]; _operationQueue = [q retain]; }
- (BOOL)isStarted { return _started; }
- (BOOL)isGathering { return _gathering; }
- (BOOL)isStopped { return _stopped; }
- (void)disableUpdates { _disabled++; }
- (void)enableUpdates { if (_disabled) _disabled--; }

/* The directories a scope stands for. */
static NSArray *
scope_paths(id scope)
{
    if ([scope isKindOfClass:[NSURL class]])
        return [scope isFileURL] ? @[ [scope path] ] : @[];
    if (![scope isKindOfClass:[NSString class]])
        return @[];
    if ([scope isEqualToString:NSMetadataQueryUserHomeScope])
        return @[ NSHomeDirectory() ];
    if ([scope isEqualToString:NSMetadataQueryLocalComputerScope] || [scope isEqualToString:NSMetadataQueryIndexedLocalComputerScope])
        return @[ @"/Applications", @"/System/Applications", @"/Library", @"/Users" ];
    if ([scope isEqualToString:@"NSMetadataQueryLocalDocumentsScope"])
        return @[ [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] ];
    if ([scope hasPrefix:@"/"])
        return @[ scope ];
    return @[]; /* network and ubiquitous scopes */
}

- (void)gatherInto:(NSMutableArray *)found
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet *seen = [NSMutableSet set];
    void (^consider)(NSURL *) = ^(NSURL *u) {
        @autoreleasepool {
            NSMetadataItem *item = [[[NSMetadataItem alloc] initWithURL:u] autorelease];
            NSString *p = [item valueForAttribute:NSMetadataItemPathKey];
            if (!item || [seen containsObject:p])
                return;
            [seen addObject:p];
            if (!_predicate || [_predicate evaluateWithObject:item])
                [found addObject:item];
        }
    };
    if (_searchItems.count) {
        for (id i in _searchItems) {
            NSURL *u = [i isKindOfClass:[NSURL class]] ? i : [i isKindOfClass:[NSString class]] ? [NSURL fileURLWithPath:i] : nil;
            if (u)
                consider(u);
        }
        return;
    }
    for (id scope in _searchScopes)
        for (NSString *dir in scope_paths(scope)) {
            NSDirectoryEnumerator *e = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir isDirectory:YES] includingPropertiesForKeys:nil
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                                              errorHandler:^BOOL(NSURL *u, NSError *err) { return YES; }];
            for (NSURL *u in e)
                consider(u);
        }
}

- (void)deliver:(void (^)(void))block
{
    if (_operationQueue)
        [_operationQueue addOperationWithBlock:block];
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

- (id)replacementFor:(NSMetadataItem *)item
{
    if ([_delegate respondsToSelector:@selector(metadataQuery:replacementObjectForResultObject:)])
        return [_delegate metadataQuery:self replacementObjectForResultObject:item];
    return item;
}

static NSArray *group(NSArray *items, NSArray *attrs, NSUInteger level);

- (void)summarize
{
    /* value lists: for each attribute, its values and how many results have each */
    NSMutableDictionary *lists = [NSMutableDictionary dictionary];
    for (NSString *attr in _valueListAttributes) {
        NSCountedSet *counts = [NSCountedSet set];
        for (NSMetadataItem *item in _results) {
            id v = [item valueForAttribute:attr];
            if (v)
                [counts addObject:v];
        }
        NSMutableArray *tuples = [NSMutableArray array];
        for (id v in counts) {
            id rv = v;
            if ([_delegate respondsToSelector:@selector(metadataQuery:replacementValueForAttribute:value:)])
                rv = [_delegate metadataQuery:self replacementValueForAttribute:attr value:v];
            [tuples addObject:[[[NSMetadataQueryAttributeValueTuple alloc] _initWithAttribute:attr value:rv count:[counts countForObject:v]]
                                  autorelease]];
        }
        lists[attr] = tuples;
    }
    [_valueLists release];
    _valueLists = [lists copy];
    [_groups release];
    _groups = [group(_results, _groupingAttributes, 0) retain];
}

static NSArray *
group(NSArray *items, NSArray *attrs, NSUInteger level)
{
    if (level >= attrs.count)
        return @[];
    NSString *attr = attrs[level];
    NSMutableDictionary *byValue = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSMetadataItem *item in items) {
        id v = [item valueForAttribute:attr] ?: [NSNull null];
        if (!byValue[v]) {
            byValue[v] = [NSMutableArray array];
            [order addObject:v];
        }
        [byValue[v] addObject:item];
    }
    NSMutableArray *groups = [NSMutableArray array];
    for (id v in order)
        [groups addObject:[[[NSMetadataQueryResultGroup alloc] _initWithAttribute:attr value:v == [NSNull null] ? nil : v
                                                                         results:byValue[v]
                                                                       subgroups:group(byValue[v], attrs, level + 1)] autorelease]];
    return groups;
}

- (BOOL)startQuery
{
    if (_started && !_stopped)
        return NO;
    if (!_predicate) {
        [NSException raise:NSInternalInconsistencyException format:@"NSMetadataQuery: a query can't be started without a predicate"];
        return NO;
    }
    _started = YES;
    _stopped = NO;
    _gathering = YES;
    [_results removeAllObjects];
    unsigned generation = ++_generation;
    [self retain];
    [self deliver:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NSMetadataQueryDidStartGatheringNotification object:self];
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *found = [NSMutableArray array];
        [self gatherInto:found];
        if (_sortDescriptors.count)
            [found sortUsingDescriptors:_sortDescriptors];
        [self deliver:^{
            if (generation == _generation && !_stopped) {
                for (NSMetadataItem *item in found)
                    [_results addObject:[self replacementFor:item]];
                [self summarize];
                _gathering = NO;
                [[NSNotificationCenter defaultCenter] postNotificationName:NSMetadataQueryDidFinishGatheringNotification object:self];
            }
            [self release];
        }];
    });
    return YES;
}

- (void)stopQuery
{
    if (!_started)
        return;
    _stopped = YES;
    _gathering = NO;
}

- (NSUInteger)resultCount { return _results.count; }
- (id)resultAtIndex:(NSUInteger)idx { return _results[idx]; }
- (NSArray *)results { return [[_results copy] autorelease]; }
- (NSUInteger)indexOfResult:(id)result { return [_results indexOfObject:result]; }
- (NSDictionary *)valueLists { return _valueLists ?: @{}; }
- (NSArray *)groupedResults { return _groups ?: @[]; }

- (void)enumerateResultsUsingBlock:(NS_NOESCAPE void (^)(id, NSUInteger, BOOL *))block
{
    [[[_results copy] autorelease] enumerateObjectsUsingBlock:block];
}

- (void)enumerateResultsWithOptions:(NSEnumerationOptions)opts usingBlock:(NS_NOESCAPE void (^)(id, NSUInteger, BOOL *))block
{
    [[[_results copy] autorelease] enumerateObjectsWithOptions:opts usingBlock:block];
}

- (id)valueOfAttribute:(NSString *)attr forResultAtIndex:(NSUInteger)idx
{
    id r = _results[idx];
    return [r isKindOfClass:[NSMetadataItem class]] ? [r valueForAttribute:attr] : [r valueForKey:attr];
}

@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coredata-stores-test: custom persistent stores (an NSIncrementalStore,
 * NSAtomicStores with and without relationships, the abstract defaults) and the
 * SQLite store's relationship handling (diff Apple's and Finch's).
 */
#import <CoreData/CoreData.h>
#include <stdio.h>
#include <unistd.h>
@interface AbstractAtomic : NSAtomicStore @end
@implementation AbstractAtomic
- (BOOL)loadMetadata:(NSError **)e { self.metadata = @{ NSStoreTypeKey : @"AbstractAtomic", NSStoreUUIDKey : @"A" }; return YES; }
- (BOOL)load:(NSError **)e { return YES; }
@end
@interface AbstractIncremental : NSIncrementalStore @end
@implementation AbstractIncremental
- (BOOL)loadMetadata:(NSError **)e { self.metadata = @{ NSStoreTypeKey : @"AbstractIncremental", NSStoreUUIDKey : @"I" }; return YES; }
@end

/* An incremental store over a dictionary: references are NSNumbers. */
@interface MemStore : NSIncrementalStore
@property (strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *rows;
@property NSInteger next;
@property (strong) NSMutableDictionary *versions;
@property (strong) NSMutableArray *log;
@end
@implementation MemStore
- (BOOL)loadMetadata:(NSError **)error
{
    self.metadata = @{ NSStoreTypeKey : @"MemStore", NSStoreUUIDKey : @"11111111-2222-3333-4444-555555555555" };
    self.rows = [NSMutableDictionary dictionary];
    self.next = 1;
    self.versions = [NSMutableDictionary dictionary];
    self.log = [NSMutableArray array];
    return YES;
}
- (id)executeRequest:(NSPersistentStoreRequest *)request withContext:(NSManagedObjectContext *)context error:(NSError **)error
{
    [self.log addObject:[NSString stringWithFormat:@"execute %lu", (unsigned long)request.requestType]];
    if (request.requestType == NSFetchRequestType) {
        NSFetchRequest *f = (NSFetchRequest *)request;
        NSEntityDescription *entity = f.entity ?: [NSEntityDescription entityForName:f.entityName inManagedObjectContext:context];
        NSMutableArray *ids = [NSMutableArray array];
        for (NSNumber *ref in [[self.rows allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [ids addObject:[self newObjectIDForEntity:entity referenceObject:ref]];
        if (f.resultType == NSCountResultType) return @[ @(ids.count) ];
        if (f.resultType == NSManagedObjectIDResultType) return ids;
        NSMutableArray *objects = [NSMutableArray array];
        for (NSManagedObjectID *i in ids) [objects addObject:[context objectWithID:i]];
        return objects;
    }
    NSSaveChangesRequest *s = (NSSaveChangesRequest *)request;
    [self.log addObject:[NSString stringWithFormat:@"save inserted %lu updated %lu deleted %lu", (unsigned long)s.insertedObjects.count,
                                    (unsigned long)s.updatedObjects.count, (unsigned long)s.deletedObjects.count]];
    NSMutableSet *written = [NSMutableSet setWithSet:s.insertedObjects ?: [NSSet set]];
    [written unionSet:s.updatedObjects ?: [NSSet set]];
    for (NSManagedObject *o in written) {
        NSNumber *ref = [self referenceObjectForObjectID:o.objectID];
        self.versions[ref] = @([self.versions[ref] integerValue] + 1);
        self.rows[ref] = [@{ @"name" : [o valueForKey:@"name"] ?: @"", @"count" : [o valueForKey:@"count"] ?: @0 } mutableCopy];
    }
    for (NSManagedObject *o in s.deletedObjects) [self.rows removeObjectForKey:[self referenceObjectForObjectID:o.objectID]];
    return @[];
}
- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID withContext:(NSManagedObjectContext *)context error:(NSError **)error
{
    NSNumber *ref = [self referenceObjectForObjectID:objectID];
    return [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:self.rows[ref] version:[self.versions[ref] unsignedLongLongValue]];
}
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error
{
    NSMutableArray *ids = [NSMutableArray array];
    for (NSManagedObject *o in array) [ids addObject:[self newObjectIDForEntity:o.entity referenceObject:@([[o valueForKey:@"name"] characterAtIndex:0])]];
    [self.log addObject:[NSString stringWithFormat:@"permanent %lu", (unsigned long)array.count]];
    return ids;
}
@end

/* An atomic store kept in memory: references are strings. */
@interface ListStore : NSAtomicStore
@property (strong) NSMutableArray *log;
@end
@implementation ListStore
- (BOOL)loadMetadata:(NSError **)error
{
    self.metadata = @{ NSStoreTypeKey : @"ListStore", NSStoreUUIDKey : @"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" };
    self.log = [NSMutableArray array];
    return YES;
}
- (BOOL)load:(NSError **)error
{
    [self.log addObject:@"load"];
    NSEntityDescription *entity = self.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Item"];
    NSAtomicStoreCacheNode *n = [[NSAtomicStoreCacheNode alloc] initWithObjectID:[self objectIDForEntity:entity referenceObject:@"seed"]];
    [n setValue:@"seeded" forKey:@"name"];
    [n setValue:@7 forKey:@"count"];
    [self addCacheNodes:[NSSet setWithObject:n]];
    return YES;
}
- (id)newReferenceObjectForManagedObject:(NSManagedObject *)object { return [NSString stringWithFormat:@"ref-%@", [object valueForKey:@"name"]]; }
- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject
{
    [self.log addObject:[NSString stringWithFormat:@"node for %@", [managedObject valueForKey:@"name"]]];
    NSAtomicStoreCacheNode *n = [[NSAtomicStoreCacheNode alloc] initWithObjectID:managedObject.objectID];
    [self updateCacheNode:n fromManagedObject:managedObject];
    return n;
}
- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject
{
    [node setValue:[managedObject valueForKey:@"name"] forKey:@"name"];
    [node setValue:[managedObject valueForKey:@"count"] forKey:@"count"];
}
- (BOOL)save:(NSError **)error
{
    [self.log addObject:@"save"];
    return YES;
}
@end

/* An atomic store using the default cache-node methods, with relationships. */
@interface TreeStore : NSAtomicStore
@end
@implementation TreeStore
- (BOOL)loadMetadata:(NSError **)error
{
    self.metadata = @{ NSStoreTypeKey : @"TreeStore", NSStoreUUIDKey : @"99999999-8888-7777-6666-555555555555" };
    return YES;
}
- (BOOL)load:(NSError **)error { return YES; }
- (id)newReferenceObjectForManagedObject:(NSManagedObject *)object { return [object valueForKey:@"name"]; }
- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject
{
    NSAtomicStoreCacheNode *n = [[NSAtomicStoreCacheNode alloc] initWithObjectID:managedObject.objectID];
    [self updateCacheNode:n fromManagedObject:managedObject];
    return n;
}
- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject
{
    [node setValue:[managedObject valueForKey:@"name"] forKey:@"name"];
    for (NSRelationshipDescription *r in managedObject.entity.relationshipsByName.allValues) {
        id value = [managedObject valueForKey:r.name];
        if (r.isToMany) {
            NSMutableSet *nodes = [NSMutableSet set];
            for (NSManagedObject *o in value) {
                NSAtomicStoreCacheNode *related = [self cacheNodeForObjectID:o.objectID];
                if (related) [nodes addObject:related];
            }
            [node setValue:nodes forKey:r.name];
        } else [node setValue:value ? [self cacheNodeForObjectID:[value objectID]] : nil forKey:r.name];
    }
}
- (void)willRemoveCacheNodes:(NSSet *)nodes
{
    NSMutableArray *names = [NSMutableArray array];
    for (NSAtomicStoreCacheNode *n in nodes) [names addObject:[n valueForKey:@"name"]];
    [names sortUsingSelector:@selector(compare:)];
    printf("removing %s\n", [[names componentsJoinedByString:@","] UTF8String]);
}
- (BOOL)save:(NSError **)error
{
    NSMutableArray *lines = [NSMutableArray array];
    for (NSAtomicStoreCacheNode *n in self.cacheNodes) {
        NSMutableArray *fields = [NSMutableArray array];
        for (NSString *key in [n.propertyCache.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id v = n.propertyCache[key];
            NSString *text;
            if ([v isKindOfClass:[NSAtomicStoreCacheNode class]]) text = [NSString stringWithFormat:@"node(%@)", [v valueForKey:@"name"]];
            else if ([v isKindOfClass:[NSSet class]]) {
                NSMutableArray *names = [NSMutableArray array];
                for (id x in v) [names addObject:[x isKindOfClass:[NSAtomicStoreCacheNode class]] ? [x valueForKey:@"name"] : NSStringFromClass([x class])];
                [names sortUsingSelector:@selector(compare:)];
                text = [NSString stringWithFormat:@"%@{%@}", [v isKindOfClass:[NSMutableSet class]] ? @"mset" : @"set", [names componentsJoinedByString:@","]];
            } else text = [v description];
            [fields addObject:[NSString stringWithFormat:@"%@=%@", key, text]];
        }
        [lines addObject:[NSString stringWithFormat:@"%@ [%@]", n.objectID.entity.name, [fields componentsJoinedByString:@" "]]];
    }
    [lines sortUsingSelector:@selector(compare:)];
    printf("tree save:\n  %s\n", [[lines componentsJoinedByString:@"\n  "] UTF8String]);
    return YES;
}
@end

static void
tree(void)
{
    printf("== TreeStore\n");
    NSEntityDescription *folder = [NSEntityDescription new], *item = [NSEntityDescription new];
    folder.name = @"Folder";
    item.name = @"Leaf";
    NSAttributeDescription *fn = [NSAttributeDescription new], *in = [NSAttributeDescription new];
    fn.name = in.name = @"name";
    fn.attributeType = in.attributeType = NSStringAttributeType;
    NSRelationshipDescription *items = [NSRelationshipDescription new], *parent = [NSRelationshipDescription new];
    items.name = @"leaves";
    items.destinationEntity = item;
    items.maxCount = 0;
    items.deleteRule = NSCascadeDeleteRule;
    parent.name = @"folder";
    parent.destinationEntity = folder;
    parent.maxCount = 1;
    parent.optional = YES;
    items.inverseRelationship = parent;
    parent.inverseRelationship = items;
    folder.properties = @[ fn, items ];
    item.properties = @[ in, parent ];
    NSManagedObjectModel *m = [NSManagedObjectModel new];
    m.entities = @[ folder, item ];
    [NSPersistentStoreCoordinator registerStoreClass:[TreeStore class] forStoreType:@"TreeStore"];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
    NSError *error = nil;
    TreeStore *store = (TreeStore *)[psc addPersistentStoreWithType:@"TreeStore" configuration:nil URL:[NSURL fileURLWithPath:@"/nonexistent/finch-tree-store"] options:nil error:&error];
    NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx.persistentStoreCoordinator = psc;
    NSManagedObject *docs = [NSEntityDescription insertNewObjectForEntityForName:@"Folder" inManagedObjectContext:ctx];
    [docs setValue:@"docs" forKey:@"name"];
    printf("save0 %d\n", [ctx save:&error]);
    for (NSString *name in @[ @"a.txt", @"b.txt" ]) {
        NSManagedObject *leaf = [NSEntityDescription insertNewObjectForEntityForName:@"Leaf" inManagedObjectContext:ctx];
        [leaf setValue:name forKey:@"name"];
        [leaf setValue:docs forKey:@"folder"];
    }
    printf("save %d\n", [ctx save:&error]);
    NSManagedObjectContext *ctx2 = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx2.persistentStoreCoordinator = psc;
    NSManagedObject *f = [ctx2 executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Folder"] error:&error].firstObject;
    NSMutableArray *names = [NSMutableArray array];
    for (NSManagedObject *leaf in [f valueForKey:@"leaves"]) [names addObject:[NSString stringWithFormat:@"%@ in %@", [leaf valueForKey:@"name"], [[leaf valueForKey:@"folder"] valueForKey:@"name"]]];
    [names sortUsingSelector:@selector(compare:)];
    printf("folder %s: %s\n", [[f valueForKey:@"name"] UTF8String], [[names componentsJoinedByString:@", "] UTF8String]);
    NSFetchRequest *byFolder = [NSFetchRequest fetchRequestWithEntityName:@"Leaf"];
    byFolder.predicate = [NSPredicate predicateWithFormat:@"folder.name == 'docs' AND name BEGINSWITH 'b'"];
    printf("leaves in docs starting b: %lu\n", (unsigned long)[ctx2 countForFetchRequest:byFolder error:&error]);
    [ctx2 deleteObject:f];
    printf("save2 %d\n", [ctx2 save:&error]);
    printf("left %lu\n", (unsigned long)store.cacheNodes.count);
}

static NSManagedObjectModel *
model(void)
{
    NSEntityDescription *e = [NSEntityDescription new];
    e.name = @"Item";
    NSAttributeDescription *n = [NSAttributeDescription new], *c = [NSAttributeDescription new];
    n.name = @"name";
    n.attributeType = NSStringAttributeType;
    n.optional = YES;
    c.name = @"count";
    c.attributeType = NSInteger64AttributeType;
    c.optional = YES;
    e.properties = @[ n, c ];
    NSManagedObjectModel *m = [NSManagedObjectModel new];
    m.entities = @[ e ];
    return m;
}

static NSString *
listing(NSArray *objects)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSManagedObject *o in objects) [parts addObject:[NSString stringWithFormat:@"%@=%@", [o valueForKey:@"name"], [o valueForKey:@"count"]]];
    return [parts componentsJoinedByString:@" "];
}

static void
exercise(NSString *type, Class cls)
{
    printf("== %s\n", type.UTF8String);
    [NSPersistentStoreCoordinator registerStoreClass:cls forStoreType:type];
    printf("registered: %d\n", NSPersistentStoreCoordinator.registeredStoreTypes[type] != nil);
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model()];
    NSError *error = nil;
    NSPersistentStore *store = [psc addPersistentStoreWithType:type configuration:nil URL:[NSURL fileURLWithPath:@"/nonexistent/finch-custom-store"]
                                                       options:nil error:&error];
    printf("store %s type %s identifier %s error %ld\n", NSStringFromClass([store class]).UTF8String, store.type.UTF8String,
        store.identifier.UTF8String, (long)error.code);
    NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx.persistentStoreCoordinator = psc;
    for (NSString *name in @[ @"alpha", @"beta" ]) {
        NSManagedObject *o = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:ctx];
        [o setValue:name forKey:@"name"];
        [o setValue:@(name.length) forKey:@"count"];
    }
    printf("save %d\n", [ctx save:&error]);
    NSManagedObjectContext *ctx2 = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx2.persistentStoreCoordinator = psc;
    NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"Item"];
    f.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    NSArray *all = [ctx2 executeFetchRequest:f error:&error];
    printf("fetched %lu: %s\n", (unsigned long)all.count, listing(all).UTF8String);
    for (NSManagedObject *o in all) printf("  uri %s temporary %d store %s\n", o.objectID.URIRepresentation.absoluteString.UTF8String,
        o.objectID.isTemporaryID, NSStringFromClass([o.objectID.persistentStore class]).UTF8String);
    f.predicate = [NSPredicate predicateWithFormat:@"count > 4"];
    printf("predicate: %s\n", listing([ctx2 executeFetchRequest:f error:&error]).UTF8String);
    printf("count %lu\n", (unsigned long)[ctx2 countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Item"] error:&error]);
    f.predicate = nil;
    NSManagedObject *first = [ctx2 executeFetchRequest:f error:&error].firstObject;
    [first setValue:@99 forKey:@"count"];
    NSManagedObject *last = [ctx2 executeFetchRequest:f error:&error].lastObject;
    [ctx2 deleteObject:last];
    printf("save2 %d\n", [ctx2 save:&error]);
    NSManagedObjectContext *ctx3 = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx3.persistentStoreCoordinator = psc;
    printf("after: %s\n", listing([ctx3 executeFetchRequest:f error:&error]).UTF8String);
    NSArray *log = [(id)store log];
    if ([store isKindOfClass:[NSAtomicStore class]]) log = [log sortedArrayUsingSelector:@selector(compare:)];
    printf("log: %s\n", [[log componentsJoinedByString:@"; "] UTF8String]);
    if ([store isKindOfClass:[NSAtomicStore class]]) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSAtomicStoreCacheNode *n in [(NSAtomicStore *)store cacheNodes]) [names addObject:[NSString stringWithFormat:@"%@=%@", [n valueForKey:@"name"], [n valueForKey:@"count"]]];
        [names sortUsingSelector:@selector(compare:)];
        printf("nodes: %s\n", [[names componentsJoinedByString:@" "] UTF8String]);
    }
    NSManagedObjectID *again = [psc managedObjectIDForURIRepresentation:[all.firstObject objectID].URIRepresentation];
    id ref = [(id)store referenceObjectForObjectID:again];
    printf("uri round trip %d ref %s number %d\n", [again isEqual:[all.firstObject objectID]], [ref description].UTF8String, [ref isKindOfClass:[NSNumber class]]);
    NSManagedObject *viaURI = [ctx3 objectWithID:again];
    printf("via uri %s fault %d\n", [[viaURI valueForKey:@"name"] UTF8String], viaURI.isFault);
    NSManagedObject *existing = [ctx3 existingObjectWithID:[psc managedObjectIDForURIRepresentation:[NSURL URLWithString:[again.URIRepresentation.absoluteString stringByAppendingString:@"0"]]] error:&error];
    printf("missing %d error %ld\n", existing != nil, (long)error.code);
}

static void try(const char *what, void (^b)(void)) {
    @try { b(); printf("%s: ok\n", what); }
    @catch (NSException *x) { printf("%s: %s: %s\n", what, x.name.UTF8String, [x.reason stringByReplacingOccurrencesOfString:@"0x[0-9a-f]+" withString:@"ADDR" options:NSRegularExpressionSearch range:NSMakeRange(0, x.reason.length)].UTF8String); }
}

static void
defaults(void)
{
    printf("== defaults\n");
    NSEntityDescription *e = [NSEntityDescription new]; e.name = @"E";
    NSAttributeDescription *n = [NSAttributeDescription new]; n.name = @"name"; n.attributeType = NSStringAttributeType; e.properties = @[n];
    NSManagedObjectModel *m = [NSManagedObjectModel new]; m.entities = @[e];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
    [NSPersistentStoreCoordinator registerStoreClass:[AbstractAtomic class] forStoreType:@"AbstractAtomic"];
    [NSPersistentStoreCoordinator registerStoreClass:[AbstractIncremental class] forStoreType:@"AbstractIncremental"];
    NSError *err;
    AbstractAtomic *a = (AbstractAtomic *)[psc addPersistentStoreWithType:@"AbstractAtomic" configuration:nil URL:[NSURL fileURLWithPath:@"/nonexistent/a"] options:nil error:&err];
    AbstractIncremental *i = (AbstractIncremental *)[psc addPersistentStoreWithType:@"AbstractIncremental" configuration:nil URL:[NSURL fileURLWithPath:@"/nonexistent/i"] options:nil error:&err];
    NSManagedObjectContext *c = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType]; c.persistentStoreCoordinator = psc;
    NSManagedObject *o = [[NSManagedObject alloc] initWithEntity:e insertIntoManagedObjectContext:c];
    [o setValue:@"x" forKey:@"name"];
    try("atomic save", ^{ NSError *x; printf("  -> %d\n", [a save:&x]); });
    try("atomic newCacheNode", ^{ [a newCacheNodeForManagedObject:o]; });
    try("atomic updateCacheNode", ^{ [a updateCacheNode:[[NSAtomicStoreCacheNode alloc] initWithObjectID:[a objectIDForEntity:e referenceObject:@1]] fromManagedObject:o]; });
    try("atomic newReference", ^{ id r = [a newReferenceObjectForManagedObject:o]; printf("  -> %s\n", [[r description] UTF8String]); });
    try("atomic cacheNodeForObjectID missing", ^{ printf("  -> %s\n", [a cacheNodeForObjectID:[a objectIDForEntity:e referenceObject:@5]] ? "node" : "nil"); });
    try("atomic objectID same", ^{ printf("  -> %d %d\n", [a objectIDForEntity:e referenceObject:@5] == [a objectIDForEntity:e referenceObject:@5], [[a objectIDForEntity:e referenceObject:@5] isEqual:[a objectIDForEntity:e referenceObject:@5]]); });
    try("incremental execute", ^{ NSError *x = nil; id r = [i executeRequest:[NSFetchRequest fetchRequestWithEntityName:@"E"] withContext:c error:&x]; printf("  -> %s %ld %s\n", r ? "object" : "nil", (long)x.code, x.localizedDescription.UTF8String); });
    try("incremental values", ^{ NSError *x = nil; id r = [i newValuesForObjectWithID:[i newObjectIDForEntity:e referenceObject:@1] withContext:c error:&x]; printf("  -> %s %ld\n", r ? "object" : "nil", (long)x.code); });
    try("incremental relationship", ^{ NSError *x = nil; id r = [i newValueForRelationship:nil forObjectWithID:[i newObjectIDForEntity:e referenceObject:@1] withContext:c error:&x]; printf("  -> %s %ld\n", r ? "object" : "nil", (long)x.code); });
    try("incremental permanent", ^{ NSError *x = nil; NSArray *r = [i obtainPermanentIDsForObjects:@[o] error:&x]; printf("  -> %lu %s\n", (unsigned long)r.count, [[[r.firstObject URIRepresentation] absoluteString] hasPrefix:@"x-coredata://I/E/p"] ? "prefix" : [[[r.firstObject URIRepresentation] absoluteString] UTF8String]); });
    try("incremental identifier", ^{ id x = [AbstractIncremental identifierForNewStoreAtURL:[NSURL fileURLWithPath:@"/tmp/z"]]; printf("  -> %s %lu\n", NSStringFromClass([x class]).UTF8String, (unsigned long)[x length]); });
    try("node", ^{ NSIncrementalStoreNode *nd = [[NSIncrementalStoreNode alloc] initWithObjectID:[i newObjectIDForEntity:e referenceObject:@1] withValues:@{@"name": @"q"} version:3];
        printf("  -> %llu %s %s\n", nd.version, [[nd valueForPropertyDescription:n] UTF8String], [[nd.description componentsSeparatedByString:@" "].lastObject UTF8String]); });
    try("cachenode", ^{ NSAtomicStoreCacheNode *nd = [[NSAtomicStoreCacheNode alloc] initWithObjectID:[a objectIDForEntity:e referenceObject:@1]];
        printf("  -> cache %d %s\n", nd.propertyCache == nil, NSStringFromClass([nd.propertyCache class]).UTF8String); [nd setValue:@"v" forKey:@"name"]; printf("  -> %s %s %s\n", [[nd valueForKey:@"name"] UTF8String], NSStringFromClass([nd.propertyCache class]).UTF8String, [[nd valueForKey:@"other"] description].UTF8String); });
    try("save request", ^{ NSSaveChangesRequest *r = [[NSSaveChangesRequest alloc] initWithInsertedObjects:nil updatedObjects:[NSSet set] deletedObjects:nil lockedObjects:nil];
        printf("  -> type %lu %d %d %s\n", (unsigned long)r.requestType, r.insertedObjects == nil, r.updatedObjects == nil, [r.description substringFromIndex:[r.description rangeOfString:@">"].location + 1].UTF8String); NSSaveChangesRequest *r2 = [[NSSaveChangesRequest alloc] initWithInsertedObjects:[NSSet setWithObject:o] updatedObjects:nil deletedObjects:nil lockedObjects:nil]; printf("  -> %s\n", [r2.description containsString:@"inserts ((\n    \"0x"] && [r2.description containsString:@"<x-coredata:///E/t"] ? "inserts listed" : r2.description.UTF8String); });
}

/* The SQLite store's side of relationships: inverses kept in step, to-many
   values of fetched objects, row faults. */
static void
relationships(void)
{
    printf("== SQLite relationships\n");
    NSEntityDescription *folder = [NSEntityDescription new], *item = [NSEntityDescription new];
    folder.name = @"Folder";
    item.name = @"Leaf";
    NSAttributeDescription *fn = [NSAttributeDescription new], *in = [NSAttributeDescription new];
    fn.name = in.name = @"name";
    fn.attributeType = in.attributeType = NSStringAttributeType;
    NSRelationshipDescription *items = [NSRelationshipDescription new], *parent = [NSRelationshipDescription new];
    items.name = @"leaves";
    items.destinationEntity = item;
    items.maxCount = 0;
    items.deleteRule = NSCascadeDeleteRule;
    parent.name = @"folder";
    parent.destinationEntity = folder;
    parent.maxCount = 1;
    items.inverseRelationship = parent;
    parent.inverseRelationship = items;
    folder.properties = @[ fn, items ];
    item.properties = @[ in, parent ];
    NSManagedObjectModel *m = [NSManagedObjectModel new];
    m.entities = @[ folder, item ];
    printf("optional by default %d\n", fn.isOptional);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-stores-%d.sqlite", getpid()]];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
    NSError *error = nil;
    [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:nil error:&error];
    NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx.persistentStoreCoordinator = psc;
    NSManagedObject *docs = [NSEntityDescription insertNewObjectForEntityForName:@"Folder" inManagedObjectContext:ctx];
    NSManagedObject *music = [NSEntityDescription insertNewObjectForEntityForName:@"Folder" inManagedObjectContext:ctx];
    [docs setValue:@"docs" forKey:@"name"];
    [music setValue:@"music" forKey:@"name"];
    NSManagedObject *a = [NSEntityDescription insertNewObjectForEntityForName:@"Leaf" inManagedObjectContext:ctx];
    NSManagedObject *b = [NSEntityDescription insertNewObjectForEntityForName:@"Leaf" inManagedObjectContext:ctx];
    [a setValue:@"a.txt" forKey:@"name"];
    [b setValue:@"b.mp3" forKey:@"name"];
    printf("empty to-many %lu\n", (unsigned long)[[docs valueForKey:@"leaves"] count]);
    [a setValue:docs forKey:@"folder"];
    [b setValue:docs forKey:@"folder"];
    printf("docs after setting folders %lu\n", (unsigned long)[[docs valueForKey:@"leaves"] count]);
    [b setValue:music forKey:@"folder"];
    printf("docs %lu music %lu\n", (unsigned long)[[docs valueForKey:@"leaves"] count], (unsigned long)[[music valueForKey:@"leaves"] count]);
    [music setValue:[NSSet set] forKey:@"leaves"];
    printf("b folder after clearing music %s\n", [[[b valueForKey:@"folder"] valueForKey:@"name"] ?: @"(none)" UTF8String]);
    [[docs mutableSetValueForKey:@"leaves"] addObject:b];
    printf("b folder after adding to docs %s\n", [[[b valueForKey:@"folder"] valueForKey:@"name"] UTF8String]);
    printf("save %d\n", [ctx save:&error]);
    NSManagedObjectContext *ctx2 = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx2.persistentStoreCoordinator = psc;
    NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"Folder"];
    f.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    for (NSManagedObject *o in [ctx2 executeFetchRequest:f error:&error]) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSManagedObject *leaf in [o valueForKey:@"leaves"]) [names addObject:[leaf valueForKey:@"name"]];
        [names sortUsingSelector:@selector(compare:)];
        printf("fetched %s: %s\n", [[o valueForKey:@"name"] UTF8String], [[names componentsJoinedByString:@","] UTF8String]);
    }
    NSManagedObject *fault = [ctx2 objectWithID:a.objectID];
    printf("fault %d name %s folder %s\n", fault.isFault, [[fault valueForKey:@"name"] UTF8String], [[[fault valueForKey:@"folder"] valueForKey:@"name"] UTF8String]);
    NSManagedObject *docs2 = [ctx2 existingObjectWithID:docs.objectID error:&error];
    [ctx2 deleteObject:docs2];
    printf("save2 %d\n", [ctx2 save:&error]);
    printf("leaves left %lu\n", (unsigned long)[ctx2 countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Leaf"] error:&error]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        exercise(@"MemStore", [MemStore class]);
        exercise(@"ListStore", [ListStore class]);
        tree();
        defaults();
        relationships();
    }
    return 0;
}

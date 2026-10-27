// SPDX-License-Identifier: MIT OR Apache-2.0
// Custom persistent stores: NSIncrementalStore answers requests itself and
// fills faults on demand; NSAtomicStore keeps every object as a cache node
// and is read and written whole. Object IDs of both carry the store's
// reference object where SQLite IDs carry a primary key.
#import "CDInternal.h"

@implementation NSSaveChangesRequest
- (instancetype)initWithInsertedObjects:(NSSet *)insertedObjects updatedObjects:(NSSet *)updatedObjects
                         deletedObjects:(NSSet *)deletedObjects lockedObjects:(NSSet *)lockedObjects {
    self = [super init];
    if (self) {
        CDSet(self, @"requestType", [NSNumber numberWithUnsignedInteger:NSSaveRequestType]);
        CDSet(self, @"insertedObjects", [[insertedObjects copy] autorelease]);
        CDSet(self, @"updatedObjects", [[updatedObjects copy] autorelease]);
        CDSet(self, @"deletedObjects", [[deletedObjects copy] autorelease]);
        CDSet(self, @"lockedObjects", [[lockedObjects copy] autorelease]);
    }
    return self;
}
- (NSPersistentStoreRequestType)requestType { return NSSaveRequestType; }
- (NSSet *)insertedObjects { return CDGet(self, @"insertedObjects"); }
- (NSSet *)updatedObjects { return CDGet(self, @"updatedObjects"); }
- (NSSet *)deletedObjects { return CDGet(self, @"deletedObjects"); }
- (NSSet *)lockedObjects { return CDGet(self, @"lockedObjects"); }
- (NSString *)description {
    NSString *(^ids)(NSSet *) = ^NSString *(NSSet *objects) {
        return objects.count ? [[[objects allObjects] valueForKey:@"objectID"] description] : @"";
    };
    return [NSString stringWithFormat:@"<%@: %p> { inserts (%@), updates (%@), deletes (%@) locks (%@) }", [self class], self,
            ids(self.insertedObjects), ids(self.updatedObjects), ids(self.deletedObjects), ids(self.lockedObjects)];
}
@end

static void CDAbstract(id store, SEL selector) {
    [NSException raise:NSInvalidArgumentException format:@"*** -%@ only defined for abstract class.  Define -[%@ %@]!",
     NSStringFromSelector(selector), [store class], NSStringFromSelector(selector)];
}

static void CDMustOverride(SEL selector, NSString *purpose) {
    [NSException raise:NSInternalInconsistencyException format:@"%@ must be overriden by your store class to %@", NSStringFromSelector(selector), purpose];
}

@implementation NSIncrementalStoreNode
- (instancetype)initWithObjectID:(NSManagedObjectID *)objectID withValues:(NSDictionary *)values version:(uint64_t)version {
    self = [super init];
    if (self) {
        CDSet(self, @"objectID", objectID);
        [self updateWithValues:values version:version];
    }
    return self;
}
- (void)updateWithValues:(NSDictionary *)values version:(uint64_t)version {
    CDSet(self, @"values", [[values copy] autorelease] ?: [NSDictionary dictionary]);
    CDSet(self, @"version", [NSNumber numberWithUnsignedLongLong:version]);
}
- (NSManagedObjectID *)objectID { return CDGet(self, @"objectID"); }
- (uint64_t)version { return [CDGet(self, @"version") unsignedLongLongValue]; }
- (id)valueForPropertyDescription:(NSPropertyDescription *)property {
    return [CDGet(self, @"values") objectForKey:property.name];
}
- (NSString *)description { return [NSString stringWithFormat:@"%@ - %llu", self.objectID, self.version]; }
@end

// A custom store's metadata as Core Data keeps it: typed by the store class
// and stamped with the model's version hashes.
static NSDictionary *CDCustomMetadata(NSPersistentStore *store, NSDictionary *metadata) {
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:metadata ?: [NSDictionary dictionary]];
    [result addEntriesFromDictionary:CDModelMetadata(store.persistentStoreCoordinator.managedObjectModel)];
    [result setObject:store.type forKey:NSStoreTypeKey];
    return result;
}

static NSManagedObjectID *CDCustomObjectID(NSPersistentStore *store, NSEntityDescription *entity, id reference) {
    NSManagedObjectID *objectID = [[NSManagedObjectID alloc] cd_init];
    CDSet(objectID, @"entity", entity);
    CDSet(objectID, @"persistentStore", store);
    CDSet(objectID, @"primaryKey", reference);
    CDSet(objectID, @"temporary", [NSNumber numberWithBool:NO]);
    return objectID;
}

@implementation NSIncrementalStore
- (NSString *)type { return NSStringFromClass([self class]); }
- (void)setMetadata:(NSDictionary *)metadata { [super setMetadata:CDCustomMetadata(self, metadata)]; }
+ (id)identifierForNewStoreAtURL:(NSURL *)storeURL { (void)storeURL; return [[NSUUID UUID] UUIDString]; }
- (BOOL)loadMetadata:(NSError **)error { (void)error; CDAbstract(self, _cmd); return NO; }
- (id)executeRequest:(NSPersistentStoreRequest *)request withContext:(NSManagedObjectContext *)context error:(NSError **)error {
    (void)request; (void)context; (void)error;
    CDAbstract(self, _cmd);
    return nil;
}
- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID withContext:(NSManagedObjectContext *)context error:(NSError **)error {
    (void)objectID; (void)context; (void)error;
    CDAbstract(self, _cmd);
    return nil;
}
- (id)newValueForRelationship:(NSRelationshipDescription *)relationship forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context error:(NSError **)error {
    (void)relationship; (void)objectID; (void)context; (void)error;
    CDAbstract(self, _cmd);
    return nil;
}
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSManagedObject *object in array) {
        NSManagedObjectID *objectID = [self newObjectIDForEntity:object.entity referenceObject:[[NSUUID UUID] UUIDString]];
        [ids addObject:objectID];
        [objectID release];
    }
    (void)error;
    return ids;
}
- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs { (void)objectIDs; }
- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs { (void)objectIDs; }
- (NSManagedObjectID *)newObjectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data {
    return CDCustomObjectID(self, entity, data);
}
- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID { return CDGet(objectID, @"primaryKey"); }
@end

@implementation NSAtomicStoreCacheNode
- (instancetype)initWithObjectID:(NSManagedObjectID *)moid {
    self = [super init];
    if (self) CDSet(self, @"objectID", moid);
    return self;
}
- (NSManagedObjectID *)objectID { return CDGet(self, @"objectID"); }
- (NSMutableDictionary *)propertyCache { return CDGet(self, @"propertyCache"); }
- (void)setPropertyCache:(NSMutableDictionary *)cache { CDSet(self, @"propertyCache", cache); }
- (id)valueForKey:(NSString *)key {
    id value = [self.propertyCache objectForKey:key];
    if (value || [self.objectID.entity.propertiesByName objectForKey:key]) return value;
    return [super valueForKey:key];
}
- (void)setValue:(id)value forKey:(NSString *)key {
    NSMutableDictionary *cache = self.propertyCache;
    if (!cache) { cache = [NSMutableDictionary dictionary]; self.propertyCache = cache; }
    if (value) [cache setObject:value forKey:key]; else [cache removeObjectForKey:key];
}
@end

static NSMutableDictionary *CDAtomicNodes(NSAtomicStore *store) {
    NSMutableDictionary *nodes = CDGet(store, @"cacheNodes");
    if (!nodes) { nodes = [NSMutableDictionary dictionary]; CDSet(store, @"cacheNodes", nodes); }
    return nodes;
}

@implementation NSAtomicStore
- (NSString *)type { return NSStringFromClass([self class]); }
- (void)setMetadata:(NSDictionary *)metadata { [super setMetadata:CDCustomMetadata(self, metadata)]; }
- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator configurationName:(NSString *)configurationName
                                               URL:(NSURL *)url options:(NSDictionary *)options {
    return [super initWithPersistentStoreCoordinator:coordinator configurationName:configurationName URL:url options:options];
}
- (BOOL)load:(NSError **)error { (void)error; CDMustOverride(_cmd, @"load data from the store"); return NO; }
- (BOOL)save:(NSError **)error { (void)error; CDMustOverride(_cmd, @"save data to the store"); return NO; }
- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject {
    (void)managedObject;
    CDMustOverride(_cmd, @"create a cache node from a managed object");
    return nil;
}
- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject {
    (void)node; (void)managedObject;
    CDMustOverride(_cmd, @"update a cache node from a managed object");
}
- (NSSet *)cacheNodes { return [NSSet setWithArray:[CDAtomicNodes(self) allValues]]; }
- (void)addCacheNodes:(NSSet *)cacheNodes {
    NSMutableDictionary *nodes = CDAtomicNodes(self);
    for (NSAtomicStoreCacheNode *node in cacheNodes) if (node.objectID) [nodes setObject:node forKey:node.objectID];
}
- (void)willRemoveCacheNodes:(NSSet *)cacheNodes { (void)cacheNodes; }
- (NSAtomicStoreCacheNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID {
    return objectID ? [CDAtomicNodes(self) objectForKey:objectID] : nil;
}
- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data {
    return [CDCustomObjectID(self, entity, data) autorelease];
}
- (id)newReferenceObjectForManagedObject:(NSManagedObject *)managedObject {
    (void)managedObject;
    NSUInteger next = [CDGet(self, @"nextReference") unsignedIntegerValue] + 1;
    CDSet(self, @"nextReference", [NSNumber numberWithUnsignedInteger:next]);
    return [[NSNumber alloc] initWithUnsignedInteger:next];
}
- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID { return CDGet(objectID, @"primaryKey"); }
@end

BOOL CDIsCustomStore(NSPersistentStore *store) {
    return [store isKindOfClass:[NSIncrementalStore class]] || [store isKindOfClass:[NSAtomicStore class]];
}

// A store or cache node value as a managed object value: IDs for to-one
// relationships, sets of registered objects for to-many ones.
static id CDCustomValue(NSManagedObjectContext *context, NSPropertyDescription *property, id value) {
    if (value == [NSNull null]) return nil;
    if (![property isKindOfClass:[NSRelationshipDescription class]] || !value) return value;
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    if ([value isKindOfClass:[NSAtomicStoreCacheNode class]]) return [value objectID];
    if ([value isKindOfClass:[NSManagedObject class]]) return [value objectID];
    if ([value isKindOfClass:[NSManagedObjectID class]]) return value;
    if (![value conformsToProtocol:@protocol(NSFastEnumeration)]) return nil;
    id objects = relationship.isOrdered ? (id)[NSMutableOrderedSet orderedSet] : (id)[NSMutableSet set];
    for (id item in value) {
        NSManagedObjectID *objectID = [item isKindOfClass:[NSManagedObjectID class]] ? item : [item objectID];
        NSManagedObject *object = objectID ? [context objectWithID:objectID] : nil;
        if (object) [objects addObject:object];
    }
    return objects;
}

static void CDApplyCustomValues(NSManagedObject *object, id source, BOOL incremental, BOOL preserveChanges) {
    NSManagedObjectContext *context = object.managedObjectContext;
    NSPersistentStore *store = object.objectID.persistentStore;
    for (NSPropertyDescription *property in object.entity.properties) {
        if (property.isTransient) continue;
        if (preserveChanges && [[object changedValues] objectForKey:property.name]) continue;
        id value = nil;
        if (incremental) {
            value = [(NSIncrementalStoreNode *)source valueForPropertyDescription:property];
            if (!value && [property isKindOfClass:[NSRelationshipDescription class]] && [(NSRelationshipDescription *)property isToMany]) {
                value = [(NSIncrementalStore *)store newValueForRelationship:(NSRelationshipDescription *)property
                                                             forObjectWithID:object.objectID withContext:context error:NULL];
                [value autorelease];
            }
        } else {
            value = [(NSAtomicStoreCacheNode *)source valueForKey:property.name];
        }
        CDObjectSetValue(object, CDCustomValue(context, property, value), property.name, NO);
    }
    CDSet(object, @"committedValues", [[CDGet(object, @"values") copy] autorelease]);
}

// Loads a custom-store fault's values; NO when the store no longer has the object.
BOOL CDFireCustomFault(NSManagedObject *object, NSError **error) {
    NSManagedObjectID *objectID = object.objectID;
    NSPersistentStore *store = objectID.persistentStore;
    if (!object.isFault || objectID.isTemporaryID || !CDIsCustomStore(store)) return YES;
    CDSet(object, @"fault", [NSNumber numberWithBool:NO]);
    if ([store isKindOfClass:[NSIncrementalStore class]]) {
        NSIncrementalStoreNode *node = [(NSIncrementalStore *)store newValuesForObjectWithID:objectID withContext:object.managedObjectContext error:error];
        if (!node) { CDSet(object, @"fault", [NSNumber numberWithBool:YES]); return NO; }
        CDApplyCustomValues(object, node, YES, NO);
        [node release];
    } else {
        NSAtomicStoreCacheNode *node = [(NSAtomicStore *)store cacheNodeForObjectID:objectID];
        if (!node) {
            CDSet(object, @"fault", [NSNumber numberWithBool:YES]);
            return CDReturnError(error, CDError(133000, @"The managed object no longer exists in the store."));
        }
        CDApplyCustomValues(object, node, NO, NO);
    }
    [object awakeFromFetch];
    return YES;
}

static NSManagedObject *CDRegisterCustomObject(NSManagedObjectContext *context, NSManagedObjectID *objectID) {
    NSManagedObject *object = [context objectWithID:objectID];
    if (object && [object.objectID.persistentStore isKindOfClass:[NSIncrementalStore class]])
        [(NSIncrementalStore *)object.objectID.persistentStore managedObjectContextDidRegisterObjectsWithIDs:[NSArray arrayWithObject:objectID]];
    return object;
}

static BOOL CDEntityMatches(NSEntityDescription *entity, NSEntityDescription *wanted, BOOL subentities) {
    for (NSEntityDescription *candidate = entity; candidate; candidate = candidate.superentity) {
        if ([candidate.name isEqualToString:wanted.name]) return YES;
        if (!subentities) break;
    }
    return NO;
}

// The managed objects a custom store holds for a fetch. Incremental stores
// filter and sort themselves; atomic stores hand back every node of the entity.
NSArray *CDCustomStoreFetch(NSManagedObjectContext *context, NSPersistentStore *store, NSFetchRequest *request,
                            NSEntityDescription *entity, NSError **error) {
    NSMutableArray *objects = [NSMutableArray array];
    if ([store isKindOfClass:[NSIncrementalStore class]]) {
        NSFetchRequest *copy = [[request copy] autorelease];
        copy.affectedStores = [NSArray arrayWithObject:store];
        if (copy.resultType != NSManagedObjectIDResultType) copy.resultType = NSManagedObjectResultType;
        copy.fetchOffset = 0;
        copy.fetchLimit = 0;
        id result = [(NSIncrementalStore *)store executeRequest:copy withContext:context error:error];
        if (!result) return nil;
        for (id item in result) {
            NSManagedObject *object = nil;
            if ([item isKindOfClass:[NSManagedObject class]]) object = item;
            else if ([item isKindOfClass:[NSManagedObjectID class]]) object = CDRegisterCustomObject(context, item);
            if (object && ![objects containsObject:object]) [objects addObject:object];
        }
        return objects;
    }
    for (NSAtomicStoreCacheNode *node in [(NSAtomicStore *)store cacheNodes]) {
        if (!CDEntityMatches(node.objectID.entity, entity, request.includesSubentities)) continue;
        NSManagedObject *object = CDRegisterCustomObject(context, node.objectID);
        BOOL preserveChanges = object.isUpdated && !request.shouldRefreshRefetchedObjects;
        BOOL wasFault = object.isFault;
        CDSet(object, @"fault", [NSNumber numberWithBool:NO]);
        CDApplyCustomValues(object, node, NO, preserveChanges);
        if (wasFault) [object awakeFromFetch];
        if (!request.predicate || [request.predicate evaluateWithObject:object]) [objects addObject:object];
    }
    return objects;
}

static void CDAssignObjectID(NSManagedObject *object, NSManagedObjectID *objectID) {
    NSManagedObjectContext *context = object.managedObjectContext;
    CDSet(object, @"objectID", objectID);
    if (context) CDRekeyRegisteredObjects(context);
}

BOOL CDObtainCustomIDs(NSPersistentStore *store, NSArray *objects, NSError **error) {
    if (!objects.count) return YES;
    if ([store isKindOfClass:[NSIncrementalStore class]]) {
        NSArray *ids = [(NSIncrementalStore *)store obtainPermanentIDsForObjects:objects error:error];
        if (!ids) return NO;
        if (ids.count != objects.count)
            return CDReturnError(error, CDError(134030, @"The store returned the wrong number of permanent object IDs."));
        for (NSUInteger i = 0; i < objects.count; i++) CDAssignObjectID([objects objectAtIndex:i], [ids objectAtIndex:i]);
        return YES;
    }
    NSAtomicStore *atomic = (NSAtomicStore *)store;
    for (NSManagedObject *object in objects) {
        id reference = [atomic newReferenceObjectForManagedObject:object];
        CDAssignObjectID(object, [atomic objectIDForEntity:object.entity referenceObject:reference]);
        [reference release];
    }
    return YES;
}

// Saves one custom store's share of a context's changes.
BOOL CDCustomStoreSave(NSManagedObjectContext *context, NSPersistentStore *store, NSArray *inserted, NSArray *updated,
                       NSArray *deleted, NSError **error) {
    if (store.isReadOnly) return CDReturnError(error, CDError(134030, @"The selected persistent store cannot be written."));
    NSMutableArray *temporary = [NSMutableArray array];
    for (NSManagedObject *object in inserted) if (object.objectID.isTemporaryID) [temporary addObject:object];
    if (!CDObtainCustomIDs(store, temporary, error)) return NO;
    if ([store isKindOfClass:[NSIncrementalStore class]]) {
        NSSaveChangesRequest *request = [[[NSSaveChangesRequest alloc]
            initWithInsertedObjects:inserted.count ? [NSSet setWithArray:inserted] : nil
                     updatedObjects:updated.count ? [NSSet setWithArray:updated] : nil
                     deletedObjects:deleted.count ? [NSSet setWithArray:deleted] : nil
                      lockedObjects:nil] autorelease];
        request.affectedStores = [NSArray arrayWithObject:store];
        return [(NSIncrementalStore *)store executeRequest:request withContext:context error:error] != nil;
    }
    NSAtomicStore *atomic = (NSAtomicStore *)store;
    NSMutableSet *added = [NSMutableSet set];
    for (NSManagedObject *object in inserted) {
        NSAtomicStoreCacheNode *node = [atomic newCacheNodeForManagedObject:object];
        if (node) [added addObject:node];
        [node release];
    }
    [atomic addCacheNodes:added];
    for (NSManagedObject *object in updated) {
        NSAtomicStoreCacheNode *node = [atomic cacheNodeForObjectID:object.objectID];
        if (node) [atomic updateCacheNode:node fromManagedObject:object];
    }
    NSMutableSet *removed = [NSMutableSet set];
    for (NSManagedObject *object in deleted) {
        NSAtomicStoreCacheNode *node = [atomic cacheNodeForObjectID:object.objectID];
        if (node) [removed addObject:node];
    }
    [atomic willRemoveCacheNodes:removed];
    for (NSAtomicStoreCacheNode *node in removed) [CDAtomicNodes(atomic) removeObjectForKey:node.objectID];
    return [atomic save:error];
}

// Opens a custom store once the coordinator has created it: metadata first,
// then an atomic store's contents.
BOOL CDLoadCustomStore(NSPersistentStore *store, NSString *type, NSError **error) {
    if (![store loadMetadata:error]) return NO;
    if (![[store.metadata objectForKey:NSStoreTypeKey] isEqual:type]) {
        NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
            @"The store type is inconsistent with the data format.", NSLocalizedDescriptionKey,
            store.metadata, @"metadata",
            @"The store type in the metadata does not match the specified store type.", @"reason", nil];
        return CDReturnError(error, [NSError errorWithDomain:NSCocoaErrorDomain code:134010 userInfo:info]);
    }
    NSString *identifier = [store.metadata objectForKey:NSStoreUUIDKey];
    if (identifier) store.identifier = identifier;
    if ([store isKindOfClass:[NSAtomicStore class]] && ![(NSAtomicStore *)store load:error]) return NO;
    return YES;
}

id CDCustomReferenceFromURIKey(NSString *key) {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (key.length && [key rangeOfCharacterFromSet:nonDigits].location == NSNotFound)
        return [NSNumber numberWithLongLong:[key longLongValue]];
    return key;
}

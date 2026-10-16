// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

static NSString *CDObjectKey(NSManagedObjectID *objectID) {
    return [[objectID URIRepresentation] absoluteString];
}

static NSString *CDKeyForSetter(SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    if (![name hasPrefix:@"set"] || ![name hasSuffix:@":"] || name.length < 5) return name;
    NSString *part = [name substringWithRange:NSMakeRange(3, name.length - 4)];
    return [part stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                          withString:[[part substringToIndex:1] lowercaseString]];
}

void CDObjectSetValue(NSManagedObject *object, id value, NSString *key, BOOL markChanged) {
    NSMutableDictionary *values = CDGet(object, @"values");
    if (!values) { values = [NSMutableDictionary dictionary]; CDSet(object, @"values", values); }
    if (value) [values setObject:value forKey:key]; else [values removeObjectForKey:key];
    if (!markChanged) return;
    NSMutableDictionary *changed = CDGet(object, @"changedValues");
    if (!changed) { changed = [NSMutableDictionary dictionary]; CDSet(object, @"changedValues", changed); }
    [changed setObject:value ?: [NSNull null] forKey:key];
    NSManagedObjectContext *context = object.managedObjectContext;
    if (context && !object.isInserted && !object.isDeleted) [CDGet(context, @"updatedObjects") addObject:object];
}

id CDObjectValue(NSManagedObject *object, NSString *key) {
    id value = [CDGet(object, @"values") objectForKey:key];
    if ([value isKindOfClass:[NSManagedObjectID class]]) {
        NSManagedObjectContext *context = object.managedObjectContext;
        if (context) {
            NSManagedObject *related = [context objectWithID:value];
            if (related.isFault) {
                NSManagedObject *loaded = [context existingObjectWithID:value error:NULL];
                if (loaded) return loaded;
            }
            return related;
        }
    }
    return value;
}

static id CDObjectGetter(NSManagedObject *object, SEL selector) {
    return CDObjectValue(object, NSStringFromSelector(selector));
}

static void CDObjectSetter(NSManagedObject *object, SEL selector, id value) {
    NSString *key = CDKeyForSetter(selector);
    [object willChangeValueForKey:key];
    CDObjectSetValue(object, value, key, YES);
    [object didChangeValueForKey:key];
}

static BOOL CDBooleanGetter(NSManagedObject *object, SEL selector) {
    return [CDObjectValue(object, NSStringFromSelector(selector)) boolValue];
}

static void CDBooleanSetter(NSManagedObject *object, SEL selector, BOOL value) {
    CDObjectSetValue(object, [NSNumber numberWithBool:value], CDKeyForSetter(selector), YES);
}

static long long CDIntegerGetter(NSManagedObject *object, SEL selector) {
    return [CDObjectValue(object, NSStringFromSelector(selector)) longLongValue];
}

static void CDIntegerSetter(NSManagedObject *object, SEL selector, long long value) {
    CDObjectSetValue(object, [NSNumber numberWithLongLong:value], CDKeyForSetter(selector), YES);
}

static double CDFloatingGetter(NSManagedObject *object, SEL selector) {
    return [CDObjectValue(object, NSStringFromSelector(selector)) doubleValue];
}

static void CDFloatingSetter(NSManagedObject *object, SEL selector, double value) {
    CDObjectSetValue(object, [NSNumber numberWithDouble:value], CDKeyForSetter(selector), YES);
}

static BOOL CDAddModeledAccessor(Class cls, SEL selector, NSAttributeDescription *attribute) {
    const char *types = NULL;
    IMP implementation = NULL;
    if (!attribute) return NO;
    switch (attribute.attributeType) {
        case NSBooleanAttributeType:
            types = @encode(BOOL); implementation = (IMP)CDBooleanGetter; break;
        case NSInteger16AttributeType:
        case NSInteger32AttributeType:
        case NSInteger64AttributeType:
            types = @encode(long long); implementation = (IMP)CDIntegerGetter; break;
        case NSFloatAttributeType:
        case NSDoubleAttributeType:
            types = @encode(double); implementation = (IMP)CDFloatingGetter; break;
        default:
            types = @encode(id); implementation = (IMP)CDObjectGetter; break;
    }
    BOOL setter = [NSStringFromSelector(selector) hasPrefix:@"set"];
    if (setter) {
        if (attribute.attributeType == NSBooleanAttributeType) implementation = (IMP)CDBooleanSetter;
        else if (attribute.attributeType == NSInteger16AttributeType || attribute.attributeType == NSInteger32AttributeType || attribute.attributeType == NSInteger64AttributeType) implementation = (IMP)CDIntegerSetter;
        else if (attribute.attributeType == NSFloatAttributeType || attribute.attributeType == NSDoubleAttributeType) implementation = (IMP)CDFloatingSetter;
        else implementation = (IMP)CDObjectSetter;
        types = attribute.attributeType == NSBooleanAttributeType ? "v@:B" :
                (attribute.attributeType == NSInteger16AttributeType || attribute.attributeType == NSInteger32AttributeType || attribute.attributeType == NSInteger64AttributeType) ? "v@:q" :
                (attribute.attributeType == NSFloatAttributeType || attribute.attributeType == NSDoubleAttributeType) ? "v@:d" : "v@:@";
    } else {
        NSString *signature = [NSString stringWithFormat:@"%s@:", types];
        return class_addMethod(cls, selector, implementation, [signature UTF8String]);
    }
    return class_addMethod(cls, selector, implementation, types);
}

@implementation NSManagedObject
+ (BOOL)contextShouldIgnoreUnmodeledPropertyChanges { return NO; }
+ (NSEntityDescription *)entity { return CDGet((id)self, @"entity"); }
+ (NSFetchRequest *)fetchRequest { return [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass(self)]; }
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    NSEntityDescription *entity = CDGet((id)self, @"entity");
    if (!entity) return [super resolveInstanceMethod:selector];
    NSString *name = NSStringFromSelector(selector);
    NSString *key = [name hasPrefix:@"set"] ? CDKeyForSetter(selector) : name;
    NSAttributeDescription *attribute = [entity.attributesByName objectForKey:key];
    if (attribute) return CDAddModeledAccessor(self, selector, attribute);
    if ([entity.relationshipsByName objectForKey:key]) {
        const char *types = [name hasPrefix:@"set"] ? "v@:@" : "@@:";
        IMP implementation = [name hasPrefix:@"set"] ? (IMP)CDObjectSetter : (IMP)CDObjectGetter;
        if (class_addMethod(self, selector, implementation, types)) return YES;
    }
    return [super resolveInstanceMethod:selector];
}
- (instancetype)initWithEntity:(NSEntityDescription *)entity insertIntoManagedObjectContext:(NSManagedObjectContext *)context {
    self = [super init];
    if (self) {
        CDSet(self, @"entity", entity);
        CDSet(self, @"context", context ? [NSValue valueWithNonretainedObject:context] : nil);
        CDSet(self, @"values", [NSMutableDictionary dictionary]);
        CDSet(self, @"changedValues", [NSMutableDictionary dictionary]);
        NSManagedObjectID *objectID = CDMakeObjectID(entity, nil, 0, YES);
        CDSet(self, @"objectID", objectID);
        for (NSAttributeDescription *attribute in [entity.attributesByName allValues])
            if (attribute.defaultValue) CDObjectSetValue(self, attribute.defaultValue, attribute.name, NO);
        if (context) {
            [context insertObject:self];
            [self awakeFromInsert];
        }
    }
    return self;
}
- (instancetype)init {
    NSEntityDescription *entity = [[self class] entity];
    if (!entity) entity = [[[NSEntityDescription alloc] init] autorelease];
    return [self initWithEntity:entity insertIntoManagedObjectContext:nil];
}
- (instancetype)initWithContext:(NSManagedObjectContext *)context {
    NSEntityDescription *entity = [[self class] entity];
    return [self initWithEntity:entity insertIntoManagedObjectContext:context];
}
- (NSManagedObjectContext *)managedObjectContext { return [[[CDGet(self, @"context") nonretainedObjectValue] retain] autorelease]; }
- (NSEntityDescription *)entity { return CDGet(self, @"entity"); }
- (NSManagedObjectID *)objectID { return CDGet(self, @"objectID"); }
- (BOOL)isInserted { return [CDGet(self, @"inserted") boolValue]; }
- (BOOL)isUpdated { return [CDGet(self, @"updated") boolValue] || ([CDGet(self, @"updatedObjects") containsObject:self]); }
- (BOOL)isDeleted { return [CDGet(self, @"deleted") boolValue]; }
- (BOOL)hasChanges { return self.isInserted || self.isUpdated || self.isDeleted; }
- (BOOL)hasPersistentChangedValues { return self.isInserted || self.isDeleted || self.isUpdated; }
- (BOOL)isFault { return [CDGet(self, @"fault") boolValue]; }
- (NSUInteger)faultingState { return self.isFault ? 1 : 0; }
- (BOOL)hasFaultForRelationshipNamed:(NSString *)key { return [CDGet(self, @"faultRelationships") containsObject:key]; }
- (NSArray *)objectIDsForRelationshipNamed:(NSString *)key {
    id value = CDObjectValue(self, key);
    if ([value isKindOfClass:[NSManagedObject class]]) return [NSArray arrayWithObject:[value objectID]];
    if ([value isKindOfClass:[NSSet class]]) {
        NSMutableArray *ids = [NSMutableArray array];
        for (NSManagedObject *object in value) [ids addObject:object.objectID];
        return ids;
    }
    return [NSArray array];
}
- (id)valueForKey:(NSString *)key {
    if ([self.entity.propertiesByName objectForKey:key]) return CDObjectValue(self, key);
    return [super valueForKey:key];
}
- (void)setValue:(id)value forKey:(NSString *)key {
    if ([self.entity.propertiesByName objectForKey:key]) { CDObjectSetter(self, NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]), value); return; }
    [super setValue:value forKey:key];
}
- (id)primitiveValueForKey:(NSString *)key { return [CDGet(self, @"values") objectForKey:key]; }
- (void)setPrimitiveValue:(id)value forKey:(NSString *)key { CDObjectSetValue(self, value, key, NO); }
- (NSDictionary *)committedValuesForKeys:(NSArray *)keys {
    NSDictionary *values = CDGet(self, @"committedValues") ?: CDGet(self, @"values") ?: [NSDictionary dictionary];
    if (!keys) return values;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in keys) { id value = [values objectForKey:key]; if (value) result[key] = value; }
    return result;
}
- (NSDictionary *)changedValues { return CDGet(self, @"changedValues") ?: [NSDictionary dictionary]; }
- (NSDictionary *)changedValuesForCurrentEvent { return self.changedValues; }
- (BOOL)validateValue:(id *)value forKey:(NSString *)key error:(NSError **)error {
    NSPropertyDescription *property = [self.entity.propertiesByName objectForKey:key];
    if (!property) return [super validateValue:value forKey:key error:error];
    if (*value == [NSNull null]) *value = nil;
    if (!*value && !property.optional && !property.isTransient) {
        if (error) *error = CDError(1570, [NSString stringWithFormat:@"%@ is required on %@", key, self.entity.name]);
        return NO;
    }
    if (*value && [property isKindOfClass:[NSAttributeDescription class]]) {
        NSAttributeType type = [(NSAttributeDescription *)property attributeType];
        if (type == NSStringAttributeType && ![*value isKindOfClass:[NSString class]]) {
            if (error) *error = CDError(1600, [NSString stringWithFormat:@"%@ must be a string", key]);
            return NO;
        }
        if ((type == NSBinaryDataAttributeType) && ![*value isKindOfClass:[NSData class]]) {
            if (error) *error = CDError(1600, [NSString stringWithFormat:@"%@ must be data", key]);
            return NO;
        }
        if (type == NSDateAttributeType && ![*value isKindOfClass:[NSDate class]]) {
            if (error) *error = CDError(1600, [NSString stringWithFormat:@"%@ must be a date", key]);
            return NO;
        }
    }
    return YES;
}
- (BOOL)validateForInsert:(NSError **)error {
    for (NSString *key in self.entity.propertiesByName) {
        id value = [self primitiveValueForKey:key];
        if (![self validateValue:&value forKey:key error:error]) return NO;
    }
    return YES;
}
- (BOOL)validateForUpdate:(NSError **)error { return [self validateForInsert:error]; }
- (BOOL)validateForDelete:(NSError **)error { (void)error; return YES; }
- (void)willAccessValueForKey:(NSString *)key { (void)key; }
- (void)didAccessValueForKey:(NSString *)key { (void)key; }
- (void)willChangeValueForKey:(NSString *)key {
    SEL selector = NSSelectorFromString(@"_finchNotifyObjectWillChange");
    if ([self respondsToSelector:selector]) {
        void (*notify)(id, SEL) = (void (*)(id, SEL))[self methodForSelector:selector];
        notify(self, selector);
    }
    [super willChangeValueForKey:key];
}
- (void)didChangeValueForKey:(NSString *)key { [super didChangeValueForKey:key]; }
- (void)willChangeValueForKey:(NSString *)key withSetMutation:(NSKeyValueSetMutationKind)kind usingObjects:(NSSet *)objects {
    [super willChangeValueForKey:key withSetMutation:kind usingObjects:objects];
}
- (void)didChangeValueForKey:(NSString *)key withSetMutation:(NSKeyValueSetMutationKind)kind usingObjects:(NSSet *)objects {
    [super didChangeValueForKey:key withSetMutation:kind usingObjects:objects];
}
- (void)awakeFromFetch {}
- (void)awakeFromInsert {}
- (void)awakeFromSnapshotEvents:(NSSnapshotEventType)flags { (void)flags; }
- (void)prepareForDeletion {}
- (void)willSave {}
- (void)didSave {}
- (void)willTurnIntoFault {}
- (void)didTurnIntoFault {}
- (void)setObservationInfo:(void *)info { CDSet(self, @"observationInfo", info ? [NSValue valueWithPointer:info] : nil); }
- (void *)observationInfo { return [CDGet(self, @"observationInfo") pointerValue]; }
@end

NSManagedObjectID *CDMakeObjectID(NSEntityDescription *entity, NSPersistentStore *store, NSInteger primaryKey, BOOL temporary) {
    NSManagedObjectID *objectID = [[[NSManagedObjectID alloc] cd_init] autorelease];
    CDSet(objectID, @"entity", entity);
    CDSet(objectID, @"persistentStore", store);
    CDSet(objectID, @"primaryKey", [NSNumber numberWithInteger:primaryKey]);
    CDSet(objectID, @"temporary", [NSNumber numberWithBool:temporary]);
    CDSet(objectID, @"temporaryToken", [[NSUUID UUID] UUIDString]);
    return objectID;
}

NSManagedObject *CDNewObject(NSEntityDescription *entity, NSManagedObjectContext *context) {
    if (!entity || entity.isAbstract) return nil;
    Class cls = NSClassFromString(entity.managedObjectClassName);
    if (!cls || ![cls isSubclassOfClass:[NSManagedObject class]]) cls = [NSManagedObject class];
    return [[[cls alloc] initWithEntity:entity insertIntoManagedObjectContext:context] autorelease];
}

NSManagedObject *CDRegisterFetchedObject(NSManagedObjectContext *context, NSEntityDescription *entity, NSPersistentStore *store, NSInteger primaryKey) {
    NSManagedObjectID *objectID = CDMakeObjectID(entity, store, primaryKey, NO);
    NSManagedObject *existing = [context objectRegisteredForID:objectID];
    if (existing) return existing;
    Class cls = NSClassFromString(entity.managedObjectClassName);
    if (!cls || ![cls isSubclassOfClass:[NSManagedObject class]]) cls = [NSManagedObject class];
    NSManagedObject *object = [[cls alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
    CDSet(object, @"objectID", objectID);
    CDSet(object, @"context", [NSValue valueWithNonretainedObject:context]);
    CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    CDSet(object, @"fault", [NSNumber numberWithBool:NO]);
    [context insertObject:object];
    [CDGet(context, @"insertedObjects") removeObject:object];
    CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    [object awakeFromFetch];
    return [object autorelease];
}

void CDObjectDidPersist(NSManagedObject *object, NSPersistentStore *store) {
    CDSet(object.objectID, @"persistentStore", store);
    CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    CDSet(object, @"updated", [NSNumber numberWithBool:NO]);
    CDSet(object, @"deleted", [NSNumber numberWithBool:NO]);
    CDSet(object, @"committedValues", [[CDGet(object, @"values") copy] autorelease]);
    [CDGet(object, @"changedValues") removeAllObjects];
}

@implementation NSManagedObjectContext
- (instancetype)init { return [self initWithConcurrencyType:NSMainQueueConcurrencyType]; }
+ (instancetype)new { return [[self alloc] initWithConcurrencyType:NSConfinementConcurrencyType]; }
- (instancetype)initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)type {
    self = [super init];
    if (self) {
        CDSet(self, @"concurrencyType", [NSNumber numberWithUnsignedInteger:type]);
        CDSet(self, @"insertedObjects", [NSMutableSet set]);
        CDSet(self, @"updatedObjects", [NSMutableSet set]);
        CDSet(self, @"deletedObjects", [NSMutableSet set]);
        CDSet(self, @"registeredObjects", [NSMutableDictionary dictionary]);
        CDSet(self, @"userInfo", [NSMutableDictionary dictionary]);
        CDSet(self, @"lock", [[NSRecursiveLock alloc] init]);
        dispatch_queue_t queue = type == NSMainQueueConcurrencyType ? dispatch_get_main_queue() :
            dispatch_queue_create("com.finch.coredata.context", DISPATCH_QUEUE_SERIAL);
        CDSet(self, @"queue", (id)queue);
        dispatch_queue_set_specific(queue, @selector(_finchContextQueue), self, NULL);
        CDSet(self, @"mergePolicy", [NSMergePolicy errorMergePolicy]);
        CDSet(self, @"propagatesDeletesAtEndOfEvent", [NSNumber numberWithBool:YES]);
        CDSet(self, @"stalenessInterval", [NSNumber numberWithDouble:-1.0]);
    }
    return self;
}
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator { return CDGet(self, @"coordinator"); }
- (void)setPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator { CDSet(self, @"coordinator", coordinator); }
- (NSManagedObjectContext *)parentContext { return CDGet(self, @"parentContext"); }
- (void)setParentContext:(NSManagedObjectContext *)context { CDSet(self, @"parentContext", context); }
- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (NSUndoManager *)undoManager { return CDGet(self, @"undoManager"); }
- (void)setUndoManager:(NSUndoManager *)value { CDSet(self, @"undoManager", value); }
- (NSManagedObjectContextConcurrencyType)concurrencyType { return [CDGet(self, @"concurrencyType") unsignedIntegerValue]; }
- (NSMutableDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (BOOL)hasChanges { return self.insertedObjects.count || self.updatedObjects.count || self.deletedObjects.count; }
- (NSSet *)insertedObjects { return [NSSet setWithSet:CDGet(self, @"insertedObjects")]; }
- (NSSet *)updatedObjects { return [NSSet setWithSet:CDGet(self, @"updatedObjects")]; }
- (NSSet *)deletedObjects { return [NSSet setWithSet:CDGet(self, @"deletedObjects")]; }
- (NSSet *)registeredObjects { return [NSSet setWithArray:[CDGet(self, @"registeredObjects") allValues]]; }
- (BOOL)propagatesDeletesAtEndOfEvent { return [CDGet(self, @"propagatesDeletesAtEndOfEvent") boolValue]; }
- (void)setPropagatesDeletesAtEndOfEvent:(BOOL)value { CDSet(self, @"propagatesDeletesAtEndOfEvent", [NSNumber numberWithBool:value]); }
- (BOOL)retainsRegisteredObjects { return [CDGet(self, @"retainsRegisteredObjects") boolValue]; }
- (void)setRetainsRegisteredObjects:(BOOL)value { CDSet(self, @"retainsRegisteredObjects", [NSNumber numberWithBool:value]); }
- (BOOL)shouldDeleteInaccessibleFaults { return [CDGet(self, @"shouldDeleteInaccessibleFaults") boolValue]; }
- (void)setShouldDeleteInaccessibleFaults:(BOOL)value { CDSet(self, @"shouldDeleteInaccessibleFaults", [NSNumber numberWithBool:value]); }
- (NSTimeInterval)stalenessInterval { return [CDGet(self, @"stalenessInterval") doubleValue]; }
- (void)setStalenessInterval:(NSTimeInterval)value { CDSet(self, @"stalenessInterval", [NSNumber numberWithDouble:value]); }
- (id)mergePolicy { return CDGet(self, @"mergePolicy"); }
- (void)setMergePolicy:(id)value { CDSet(self, @"mergePolicy", value); }
- (NSQueryGenerationToken *)queryGenerationToken { return CDGet(self, @"queryGenerationToken"); }
- (BOOL)setQueryGenerationFromToken:(NSQueryGenerationToken *)token error:(NSError **)error {
    if (self.parentContext && token) return CDReturnError(error, CDError(134190, @"A child context follows its parent query generation."));
    CDSet(self, @"queryGenerationToken", token);
    return YES;
}
- (void)performBlock:(void (^)(void))block {
    if (!block) return;
    dispatch_queue_t queue = CDGet(self, @"queue");
    dispatch_async(queue, ^{ @autoreleasepool { block(); [self processPendingChanges]; } });
}
- (void)performBlockAndWait:(void (^NS_NOESCAPE NS_SWIFT_SENDABLE)(void))block {
    if (!block) return;
    dispatch_queue_t queue = CDGet(self, @"queue");
    if (dispatch_get_specific(@selector(_finchContextQueue)) == self ||
        (self.concurrencyType == NSMainQueueConcurrencyType && [NSThread isMainThread])) {
        block(); [self processPendingChanges]; return;
    }
    dispatch_sync(queue, ^{ @autoreleasepool { block(); [self processPendingChanges]; } });
}
- (void)lock { [CDGet(self, @"lock") lock]; }
- (void)unlock { [CDGet(self, @"lock") unlock]; }
- (BOOL)tryLock { return [CDGet(self, @"lock") tryLock]; }
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)undo { [self.undoManager undo]; }
- (void)redo { [self.undoManager redo]; }
- (BOOL)shouldHandleInaccessibleFault:(NSManagedObject *)fault forObjectID:(NSManagedObjectID *)objectID triggeredByProperty:(NSPropertyDescription *)property {
    (void)fault; (void)objectID; (void)property;
    return self.shouldDeleteInaccessibleFaults;
}
- (void)insertObject:(NSManagedObject *)object {
    if (!object || (object.managedObjectContext && object.managedObjectContext != self)) return;
    CDSet(object, @"context", [NSValue valueWithNonretainedObject:self]);
    CDSet(object, @"inserted", [NSNumber numberWithBool:YES]);
    CDSet(object, @"deleted", [NSNumber numberWithBool:NO]);
    CDSet(object, @"updated", [NSNumber numberWithBool:NO]);
    [CDGet(self, @"insertedObjects") addObject:object];
    [CDGet(self, @"registeredObjects") setObject:object forKey:CDObjectKey(object.objectID)];
}
- (void)deleteObject:(NSManagedObject *)object {
    if (!object || object.managedObjectContext != self || object.isDeleted) return;
    [object prepareForDeletion];
    if (object.isInserted) [CDGet(self, @"insertedObjects") removeObject:object];
    else [CDGet(self, @"deletedObjects") addObject:object];
    [CDGet(self, @"updatedObjects") removeObject:object];
    CDSet(object, @"deleted", [NSNumber numberWithBool:YES]);
    CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    for (NSRelationshipDescription *relationship in [object.entity.relationshipsByName allValues]) {
        id value = CDObjectValue(object, relationship.name);
        if (relationship.deleteRule == NSCascadeDeleteRule) {
            if ([value isKindOfClass:[NSManagedObject class]]) [self deleteObject:value];
            else if ([value isKindOfClass:[NSSet class]]) for (NSManagedObject *related in value) [self deleteObject:related];
        } else if (relationship.deleteRule == NSNullifyDeleteRule) {
            if ([value isKindOfClass:[NSManagedObject class]] && relationship.inverseRelationship)
                [value setValue:nil forKey:relationship.inverseRelationship.name];
            else if ([value isKindOfClass:[NSSet class]] && relationship.inverseRelationship)
                for (NSManagedObject *related in value) [related setValue:nil forKey:relationship.inverseRelationship.name];
        }
    }
}
- (NSManagedObject *)objectRegisteredForID:(NSManagedObjectID *)objectID {
    return [CDGet(self, @"registeredObjects") objectForKey:CDObjectKey(objectID)];
}
- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID {
    NSManagedObject *object = [self objectRegisteredForID:objectID];
    if (object) return object;
    NSEntityDescription *entity = objectID.entity;
    if (!entity) return nil;
    Class cls = NSClassFromString(entity.managedObjectClassName);
    if (!cls || ![cls isSubclassOfClass:[NSManagedObject class]]) cls = [NSManagedObject class];
    object = [[cls alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
    CDSet(object, @"objectID", objectID);
    CDSet(object, @"context", [NSValue valueWithNonretainedObject:self]);
    CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    CDSet(object, @"fault", [NSNumber numberWithBool:YES]);
    [CDGet(self, @"registeredObjects") setObject:object forKey:CDObjectKey(objectID)];
    return [object autorelease];
}
- (NSManagedObject *)existingObjectWithID:(NSManagedObjectID *)objectID error:(NSError **)error {
    NSManagedObject *registered = [self objectRegisteredForID:objectID];
    if (registered && !registered.isFault) return registered;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:objectID.entity.name];
    NSArray *objects = [self executeFetchRequest:request error:error];
    for (NSManagedObject *object in objects) if ([object.objectID isEqual:objectID]) return object;
    CDReturnError(error, CDError(133000, @"The managed object no longer exists in the store."));
    return nil;
}
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error {
    NSArray *persisted = CDStoreFetch(self, request, error);
    if (!persisted) return nil;
    NSMutableArray *result = [NSMutableArray arrayWithArray:persisted];
    if (request.includesPendingChanges) {
        for (NSManagedObject *object in self.insertedObjects)
            if ([object.entity.name isEqualToString:request.entityName] && (!request.predicate || [request.predicate evaluateWithObject:object])) [result addObject:object];
        for (NSManagedObject *object in self.deletedObjects) [result removeObject:object];
    }
    if (request.sortDescriptors.count) [result sortUsingDescriptors:request.sortDescriptors];
    NSUInteger offset = MIN(request.fetchOffset, result.count);
    if (offset) [result removeObjectsInRange:NSMakeRange(0, offset)];
    if (request.fetchLimit && result.count > request.fetchLimit) [result removeObjectsInRange:NSMakeRange(request.fetchLimit, result.count - request.fetchLimit)];
    if (request.resultType == NSCountResultType) return [NSArray arrayWithObject:[NSNumber numberWithUnsignedInteger:result.count]];
    if (request.resultType == NSManagedObjectIDResultType) {
        NSMutableArray *ids = [NSMutableArray array]; for (NSManagedObject *object in result) [ids addObject:object.objectID]; return ids;
    }
    if (request.resultType == NSDictionaryResultType) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSManagedObject *object in result) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            NSArray *properties = request.propertiesToFetch ?: object.entity.properties;
            for (id property in properties) {
                NSString *name = [property isKindOfClass:[NSString class]] ? property : [property name];
                id value = [object valueForKey:name]; if (value) row[name] = value;
            }
            [rows addObject:row];
        }
        return rows;
    }
    return result;
}
- (NSUInteger)countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error {
    NSArray *result = [self executeFetchRequest:request error:error];
    return result ? (request.resultType == NSCountResultType ? [[result firstObject] unsignedIntegerValue] : result.count) : NSNotFound;
}
- (NSPersistentStoreResult *)executeRequest:(NSPersistentStoreRequest *)request error:(NSError **)error {
    return [self.persistentStoreCoordinator executeRequest:request withContext:self error:error];
}
- (BOOL)save:(NSError **)error {
    for (NSManagedObject *object in self.insertedObjects) if (![object validateForInsert:error]) return NO;
    for (NSManagedObject *object in self.updatedObjects) if (![object validateForUpdate:error]) return NO;
    for (NSManagedObject *object in self.deletedObjects) if (![object validateForDelete:error]) return NO;
    for (NSManagedObject *object in self.insertedObjects) [object willSave];
    for (NSManagedObject *object in self.updatedObjects) [object willSave];
    if (self.parentContext) {
        NSManagedObjectContext *parent = self.parentContext;
        for (NSManagedObject *object in self.insertedObjects) {
            NSManagedObject *copy = CDNewObject(object.entity, parent);
            for (NSString *key in object.entity.propertiesByName) [copy setValue:[object valueForKey:key] forKey:key];
        }
        for (NSManagedObject *object in self.updatedObjects) {
            NSManagedObject *copy = [parent objectWithID:object.objectID];
            for (NSString *key in object.changedValues) [copy setValue:[object valueForKey:key] forKey:key];
        }
        for (NSManagedObject *object in self.deletedObjects) [parent deleteObject:[parent objectWithID:object.objectID]];
        [self rollback];
        return YES;
    }
    if (!self.persistentStoreCoordinator) return CDReturnError(error, CDError(134080, @"The context has no persistent store coordinator."));
    if (!CDStoreSave(self, error)) return NO;
    for (NSManagedObject *object in self.registeredObjects) [object didSave];
    return YES;
}
- (void)rollback {
    for (NSManagedObject *object in self.insertedObjects) CDSet(object, @"inserted", [NSNumber numberWithBool:NO]);
    for (NSManagedObject *object in self.registeredObjects) {
        NSDictionary *committed = [object committedValuesForKeys:nil];
        CDSet(object, @"values", [committed mutableCopy]);
        [CDGet(object, @"changedValues") removeAllObjects];
        CDSet(object, @"updated", [NSNumber numberWithBool:NO]);
        CDSet(object, @"deleted", [NSNumber numberWithBool:NO]);
    }
    [CDGet(self, @"insertedObjects") removeAllObjects];
    [CDGet(self, @"updatedObjects") removeAllObjects];
    [CDGet(self, @"deletedObjects") removeAllObjects];
}
- (void)reset {
    for (NSManagedObject *object in self.registeredObjects) {
        CDSet(object, @"context", nil);
        [object willTurnIntoFault];
        [object didTurnIntoFault];
    }
    [CDGet(self, @"registeredObjects") removeAllObjects];
    [self rollback];
}
- (void)refreshObject:(NSManagedObject *)object mergeChanges:(BOOL)flag {
    if (!object || object.managedObjectContext != self) return;
    if (flag) {
        NSManagedObject *fresh = [self existingObjectWithID:object.objectID error:NULL];
        if (fresh && fresh != object) CDSet(object, @"values", [[CDGet(fresh, @"values") mutableCopy] autorelease]);
    } else {
        CDSet(object, @"values", [[object committedValuesForKeys:nil] mutableCopy]);
        [object willTurnIntoFault];
        CDSet(object, @"fault", [NSNumber numberWithBool:YES]);
    }
    [CDGet(object, @"changedValues") removeAllObjects];
    [CDGet(self, @"updatedObjects") removeObject:object];
}
- (void)refreshAllObjects { for (NSManagedObject *object in self.registeredObjects) [self refreshObject:object mergeChanges:NO]; }
- (void)detectConflictsForObject:(NSManagedObject *)object { if (object) [CDGet(self, @"conflictObjects") addObject:object]; }
- (void)assignObject:(id)object toPersistentStore:(NSPersistentStore *)store { if ([object isKindOfClass:[NSManagedObject class]]) CDSet([object objectID], @"persistentStore", store); }
- (void)processPendingChanges {
    if (!self.hasChanges) return;
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:self.insertedObjects, NSInsertedObjectsKey,
                          self.updatedObjects, NSUpdatedObjectsKey, self.deletedObjects, NSDeletedObjectsKey, nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextObjectsDidChangeNotification object:self userInfo:info];
}
- (void)mergeChangesFromContextDidSaveNotification:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    for (NSString *key in @[NSInsertedObjectsKey, NSUpdatedObjectsKey]) {
        for (id value in [info objectForKey:key]) {
            NSManagedObjectID *objectID = [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
            NSManagedObject *object = [self objectRegisteredForID:objectID];
            if (object && [value isKindOfClass:[NSManagedObject class]]) {
                CDSet(object, @"values", [[CDGet(value, @"values") mutableCopy] autorelease]);
                [object awakeFromSnapshotEvents:NSSnapshotEventRefresh];
            }
        }
    }
    for (id value in [info objectForKey:NSDeletedObjectsKey]) {
        NSManagedObjectID *objectID = [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
        NSManagedObject *object = [self objectRegisteredForID:objectID]; if (object) [self deleteObject:object];
    }
}
+ (void)mergeChangesFromRemoteContextSave:(NSDictionary *)data intoContexts:(NSArray *)contexts {
    NSNotification *notification = [NSNotification notificationWithName:NSManagedObjectContextDidSaveNotification object:nil userInfo:data];
    for (NSManagedObjectContext *context in contexts) [context mergeChangesFromContextDidSaveNotification:notification];
}
- (BOOL)obtainPermanentIDsForObjects:(NSArray *)objects error:(NSError **)error {
    for (NSManagedObject *object in objects) if (!object.isInserted || object.managedObjectContext != self)
        return CDReturnError(error, CDError(134080, @"Only inserted objects in this context can receive permanent IDs."));
    return CDReturnError(error, CDError(134190, @"Permanent IDs are assigned when the SQLite transaction commits."));
}
- (id)initWithCoder:(NSCoder *)coder { (void)coder; return [self initWithConcurrencyType:NSMainQueueConcurrencyType]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.name forKey:@"NSName"]; }
- (void)dealloc {
    dispatch_queue_t queue = CDGet(self, @"queue");
    if (queue && self.concurrencyType != NSMainQueueConcurrencyType) dispatch_queue_set_specific(queue, @selector(_finchContextQueue), NULL, NULL);
    [super dealloc];
}
@end

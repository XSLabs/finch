// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

void CDPerformBlock(NSManagedObjectContext *context, void (^block)(void)) {
    [context performBlock:block];
}

void CDPerformBlockAndWait(NSManagedObjectContext *context, void (^block)(void)) {
    [context performBlockAndWait:block];
}

NSError *CDCountForFetchRequest(NSManagedObjectContext *context, NSFetchRequest *request, NSUInteger *result) {
    NSError *error = nil;
    NSUInteger count = [context countForFetchRequest:request error:&error];
    if (count == NSNotFound) return [(error ?: CDError(134091, @"The fetch count could not be read.")) retain];
    if (result) *result = count;
    return nil;
}

NSError *CDFetchForFetchRequest(NSManagedObjectContext *context, NSFetchRequest *request, NSArray **result) {
    NSError *error = nil;
    NSArray *objects = [context executeFetchRequest:request error:&error];
    if (!objects) return [(error ?: CDError(134091, @"The fetch could not be completed.")) retain];
    if (result) *result = [objects retain];
    return nil;
}

NSError *CDReplacePersistentStore(NSPersistentStoreCoordinator *coordinator, NSURL *destinationURL,
                                  NSDictionary *destinationOptions, NSURL *sourceURL,
                                  NSDictionary *sourceOptions, NSString *storeType) {
    NSError *error = nil;
    BOOL replaced = [coordinator replacePersistentStoreAtURL:destinationURL
                                          destinationOptions:destinationOptions
                                   withPersistentStoreFromURL:sourceURL
                                               sourceOptions:sourceOptions
                                                   storeType:storeType
                                                       error:&error];
    if (replaced) return nil;
    return [(error ?: CDError(134080, @"The persistent store could not be replaced.")) retain];
}

NSError *CDAddPersistentStore(NSPersistentStoreCoordinator *coordinator, NSString *type,
                              NSString *configuration, NSURL *url, NSDictionary *options,
                              NSPersistentStore **result) {
    NSError *error = nil;
    NSPersistentStore *store = [coordinator addPersistentStoreWithType:type
                                                        configuration:configuration
                                                                   URL:url
                                                              options:options
                                                                error:&error];
    if (!store) return [(error ?: CDError(134080, @"The persistent store could not be added.")) retain];
    if (result) *result = [store retain];
    return nil;
}

NSError *CDDestroyPersistentStore(NSPersistentStoreCoordinator *coordinator, NSURL *url,
                                  NSString *type, NSDictionary *options) {
    NSError *error = nil;
    if ([coordinator destroyPersistentStoreAtURL:url withType:type options:options error:&error]) return nil;
    return [(error ?: CDError(134080, @"The persistent store could not be destroyed.")) retain];
}

@implementation NSMergeConflict
- (instancetype)initWithSource:(NSManagedObject *)source newVersion:(NSUInteger)newVersion oldVersion:(NSUInteger)oldVersion cachedSnapshot:(NSDictionary *)cached persistedSnapshot:(NSDictionary *)persisted {
    self = [super init];
    if (self) {
        CDSet(self, @"source", source);
        CDSet(self, @"newVersion", [NSNumber numberWithUnsignedInteger:newVersion]);
        CDSet(self, @"oldVersion", [NSNumber numberWithUnsignedInteger:oldVersion]);
        CDSet(self, @"cachedSnapshot", cached);
        CDSet(self, @"persistedSnapshot", persisted);
        CDSet(self, @"objectSnapshot", [[source committedValuesForKeys:nil] copy]);
    }
    return self;
}
- (NSManagedObject *)sourceObject { return CDGet(self, @"source"); }
- (NSDictionary *)objectSnapshot { return CDGet(self, @"objectSnapshot"); }
- (NSDictionary *)cachedSnapshot { return CDGet(self, @"cachedSnapshot"); }
- (NSDictionary *)persistedSnapshot { return CDGet(self, @"persistedSnapshot"); }
- (NSUInteger)newVersionNumber { return [CDGet(self, @"newVersion") unsignedIntegerValue]; }
- (NSUInteger)oldVersionNumber { return [CDGet(self, @"oldVersion") unsignedIntegerValue]; }
@end

@implementation NSConstraintConflict
- (instancetype)init {
    return [self initWithConstraint:[NSArray array] databaseObject:nil databaseSnapshot:nil
                  conflictingObjects:[NSArray array] conflictingSnapshots:[NSArray array]];
}
- (instancetype)initWithConstraint:(NSArray *)constraint databaseObject:(NSManagedObject *)databaseObject databaseSnapshot:(NSDictionary *)databaseSnapshot conflictingObjects:(NSArray *)objects conflictingSnapshots:(NSArray *)snapshots {
    self = [super init];
    if (self) {
        CDSet(self, @"constraint", [constraint copy]);
        CDSet(self, @"databaseObject", databaseObject);
        CDSet(self, @"databaseSnapshot", [databaseSnapshot copy]);
        CDSet(self, @"conflictingObjects", [objects copy]);
        CDSet(self, @"conflictingSnapshots", [snapshots copy]);
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *key in constraint) {
            id value = [databaseObject valueForKey:key];
            if (value) [values setObject:value forKey:key];
        }
        CDSet(self, @"constraintValues", values);
    }
    return self;
}
- (NSArray *)constraint { return CDGet(self, @"constraint"); }
- (NSDictionary *)constraintValues { return CDGet(self, @"constraintValues"); }
- (NSManagedObject *)databaseObject { return CDGet(self, @"databaseObject"); }
- (NSDictionary *)databaseSnapshot { return CDGet(self, @"databaseSnapshot"); }
- (NSArray *)conflictingObjects { return CDGet(self, @"conflictingObjects"); }
- (NSArray *)conflictingSnapshots { return CDGet(self, @"conflictingSnapshots"); }
@end

@implementation NSMergePolicy
+ (void)initialize {
    if (self != [NSMergePolicy class]) return;
    NSErrorMergePolicy = [[NSMergePolicy alloc] initWithMergeType:NSErrorMergePolicyType];
    NSRollbackMergePolicy = [[NSMergePolicy alloc] initWithMergeType:NSRollbackMergePolicyType];
    NSOverwriteMergePolicy = [[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType];
    NSMergeByPropertyObjectTrumpMergePolicy = [[NSMergePolicy alloc] initWithMergeType:NSMergeByPropertyObjectTrumpMergePolicyType];
    NSMergeByPropertyStoreTrumpMergePolicy = [[NSMergePolicy alloc] initWithMergeType:NSMergeByPropertyStoreTrumpMergePolicyType];
}
+ (NSMergePolicy *)errorMergePolicy { return NSErrorMergePolicy; }
+ (NSMergePolicy *)rollbackMergePolicy { return NSRollbackMergePolicy; }
+ (NSMergePolicy *)overwriteMergePolicy { return NSOverwriteMergePolicy; }
+ (NSMergePolicy *)mergeByPropertyObjectTrumpMergePolicy { return NSMergeByPropertyObjectTrumpMergePolicy; }
+ (NSMergePolicy *)mergeByPropertyStoreTrumpMergePolicy { return NSMergeByPropertyStoreTrumpMergePolicy; }
- (instancetype)initWithMergeType:(NSMergePolicyType)type {
    self = [super init];
    if (self) CDSet(self, @"mergeType", [NSNumber numberWithUnsignedInteger:type]);
    return self;
}
- (NSMergePolicyType)mergeType { return [CDGet(self, @"mergeType") unsignedIntegerValue]; }
- (BOOL)resolveConflicts:(NSArray *)conflicts error:(NSError **)error {
    NSMutableArray *versions = [NSMutableArray array];
    NSMutableArray *constraints = [NSMutableArray array];
    for (id conflict in conflicts) {
        if ([conflict isKindOfClass:[NSMergeConflict class]]) [versions addObject:conflict];
        else if ([conflict isKindOfClass:[NSConstraintConflict class]]) [constraints addObject:conflict];
    }
    return [self resolveOptimisticLockingVersionConflicts:versions error:error] &&
           [self resolveConstraintConflicts:constraints error:error];
}
- (BOOL)resolveOptimisticLockingVersionConflicts:(NSArray<NSMergeConflict *> *)conflicts error:(NSError **)error {
    if (self.mergeType == NSErrorMergePolicyType && conflicts.count)
        return CDReturnError(error, CDError(134050, @"The save conflicted with a newer version in the store."));
    for (NSMergeConflict *conflict in conflicts) {
        NSManagedObject *object = conflict.sourceObject;
        if (!object) continue;
        NSDictionary *memory = conflict.objectSnapshot ?: [NSDictionary dictionary];
        NSDictionary *base = conflict.cachedSnapshot ?: [NSDictionary dictionary];
        NSDictionary *store = conflict.persistedSnapshot ?: base;
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:memory];
        if (self.mergeType == NSRollbackMergePolicyType) [merged setDictionary:store];
        else if (self.mergeType == NSOverwriteMergePolicyType) { /* Keep the entire in-memory snapshot. */ }
        else {
            NSMutableSet *keys = [NSMutableSet setWithArray:[base allKeys]];
            [keys addObjectsFromArray:[store allKeys]];
            [keys addObjectsFromArray:[memory allKeys]];
            for (NSString *key in keys) {
                id before = [base objectForKey:key] ?: [NSNull null];
                id database = [store objectForKey:key] ?: [NSNull null];
                id current = [memory objectForKey:key] ?: [NSNull null];
                BOOL memoryChanged = ![current isEqual:before];
                BOOL storeChanged = ![database isEqual:before];
                if (self.mergeType == NSMergeByPropertyStoreTrumpMergePolicyType && storeChanged) {
                    if (database == [NSNull null]) [merged removeObjectForKey:key]; else merged[key] = database;
                } else if (!memoryChanged && storeChanged) {
                    if (database == [NSNull null]) [merged removeObjectForKey:key]; else merged[key] = database;
                }
            }
        }
        CDSet(object, @"committedValues", [store mutableCopy]);
        for (NSString *key in object.entity.propertiesByName) {
            id value = [merged objectForKey:key];
            CDObjectSetValue(object, value == [NSNull null] ? nil : value, key, NO);
        }
        [CDGet(object, @"changedValues") removeAllObjects];
        NSManagedObjectContext *context = object.managedObjectContext;
        if (object.isUpdated) [CDGet(context, @"updatedObjects") addObject:object];
    }
    return YES;
}
- (BOOL)resolveConstraintConflicts:(NSArray<NSConstraintConflict *> *)conflicts error:(NSError **)error {
    if (!conflicts.count) return YES;
    // The trumping policies keep one side's values; only the error policy refuses.
    if (self.mergeType != NSErrorMergePolicyType) return YES;
    return CDReturnError(error, CDError(133021, @"The save violates a uniqueness constraint."));
}
@end

@implementation NSPropertyMapping
- (NSString *)description {
    return [NSString stringWithFormat:@"(NSPropertyMapping), name %@, valueExpression %@, userInfo %@", self.name, self.valueExpression, self.userInfo];
}
- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (NSExpression *)valueExpression { return CDGet(self, @"valueExpression"); }
- (void)setValueExpression:(NSExpression *)value { CDSet(self, @"valueExpression", value); }
- (NSDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { CDSet(self, @"userInfo", [value copy]); }
@end

@implementation NSEntityMapping
- (NSString *)name {
    return CDGet(self, @"name") ?: [NSString stringWithFormat:@"%@->%@", self.sourceEntityName, self.destinationEntityName];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"(NSEntityMapping), name %@, mappingType %lu, sourceEntityName %@, sourceEntityVersionHash %@, destinationEntityName %@, destinationEntityVersionHash %@, attributeMappings %@, relationshipMappings %@, sourceExpression %@, entityMigrationPolicyClassName %@, userInfo %@",
            self.name, (unsigned long)self.mappingType, self.sourceEntityName, self.sourceEntityVersionHash, self.destinationEntityName,
            self.destinationEntityVersionHash, self.attributeMappings ?: [NSArray array], self.relationshipMappings ?: [NSArray array],
            self.sourceExpression, self.entityMigrationPolicyClassName, self.userInfo];
}
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (NSEntityMappingType)mappingType { return [CDGet(self, @"mappingType") unsignedIntegerValue]; }
- (void)setMappingType:(NSEntityMappingType)value { CDSet(self, @"mappingType", [NSNumber numberWithUnsignedInteger:value]); }
- (NSString *)sourceEntityName { return CDGet(self, @"sourceEntityName"); }
- (void)setSourceEntityName:(NSString *)value { CDSet(self, @"sourceEntityName", [value copy]); }
- (NSData *)sourceEntityVersionHash { return CDGet(self, @"sourceEntityVersionHash"); }
- (void)setSourceEntityVersionHash:(NSData *)value { CDSet(self, @"sourceEntityVersionHash", [value copy]); }
- (NSString *)destinationEntityName { return CDGet(self, @"destinationEntityName"); }
- (void)setDestinationEntityName:(NSString *)value { CDSet(self, @"destinationEntityName", [value copy]); }
- (NSData *)destinationEntityVersionHash { return CDGet(self, @"destinationEntityVersionHash"); }
- (void)setDestinationEntityVersionHash:(NSData *)value { CDSet(self, @"destinationEntityVersionHash", [value copy]); }
- (NSArray *)attributeMappings { return CDGet(self, @"attributeMappings"); }
- (void)setAttributeMappings:(NSArray *)value { CDSet(self, @"attributeMappings", [value copy]); }
- (NSArray *)relationshipMappings { return CDGet(self, @"relationshipMappings"); }
- (void)setRelationshipMappings:(NSArray *)value { CDSet(self, @"relationshipMappings", [value copy]); }
- (NSExpression *)sourceExpression { return CDGet(self, @"sourceExpression"); }
- (void)setSourceExpression:(NSExpression *)value { CDSet(self, @"sourceExpression", value); }
- (NSDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { CDSet(self, @"userInfo", [value copy]); }
- (NSString *)entityMigrationPolicyClassName { return CDGet(self, @"entityMigrationPolicyClassName"); }
- (void)setEntityMigrationPolicyClassName:(NSString *)value { CDSet(self, @"entityMigrationPolicyClassName", [value copy]); }
@end

@implementation NSMappingModel
- (NSString *)description { return [NSString stringWithFormat:@"(NSMappingModel), entityMappings %@", self.entityMappings]; }
// A compiled mapping model (.cdm) whose entity version hashes match both models.
+ (NSMappingModel *)mappingModelFromBundles:(NSArray *)bundles forSourceModel:(NSManagedObjectModel *)source destinationModel:(NSManagedObjectModel *)destination {
    if (!source || !destination) return nil;
    if (!bundles) bundles = [NSArray arrayWithObject:[NSBundle mainBundle]];
    for (NSBundle *bundle in bundles) {
        for (NSString *path in [bundle pathsForResourcesOfType:@"cdm" inDirectory:nil]) {
            NSMappingModel *mapping = [[[NSMappingModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]] autorelease];
            if (!mapping.entityMappings.count) continue;
            BOOL matches = YES;
            for (NSEntityMapping *entityMapping in mapping.entityMappings) {
                if (entityMapping.sourceEntityName &&
                    ![[[source.entitiesByName objectForKey:entityMapping.sourceEntityName] versionHash] isEqual:entityMapping.sourceEntityVersionHash]) matches = NO;
                if (entityMapping.destinationEntityName &&
                    ![[[destination.entitiesByName objectForKey:entityMapping.destinationEntityName] versionHash] isEqual:entityMapping.destinationEntityVersionHash]) matches = NO;
                if (!matches) break;
            }
            if (matches) return mapping;
        }
    }
    return nil;
}
static NSExpression *CDSourceValueExpression(NSString *key) {
    return [NSExpression expressionForFunction:[NSExpression expressionForVariable:@"source"] selectorName:@"valueForKey:"
                                     arguments:[NSArray arrayWithObject:[NSExpression expressionForConstantValue:key]]];
}

static NSExpression *CDSourceFetchExpression(NSString *entityName) {
    NSExpression *manager = [NSExpression expressionForVariable:@"manager"];
    NSExpression *request = [NSExpression expressionForFunction:manager selectorName:@"fetchRequestForSourceEntityNamed:predicateString:"
                                                      arguments:[NSArray arrayWithObjects:[NSExpression expressionForConstantValue:entityName],
                                                                 [NSExpression expressionForConstantValue:@"TRUEPREDICATE"], nil]];
    NSExpression *context = [NSExpression expressionForFunction:manager selectorName:@"sourceContext" arguments:[NSArray array]];
    return [NSFetchRequestExpression expressionForFetch:request context:context countOnly:NO];
}

// The mapping Core Data infers between two models: entities and properties
// matched by name or renaming identifier, new ones added, missing ones removed.
+ (NSMappingModel *)inferredMappingModelForSourceModel:(NSManagedObjectModel *)source destinationModel:(NSManagedObjectModel *)destination error:(NSError **)error {
    if (!source || !destination) {
        CDReturnError(error, CDError(134110, @"Both source and destination models are required."));
        return nil;
    }
    NSMappingModel *mapping = [[[self alloc] init] autorelease];
    NSMutableArray *entities = [NSMutableArray array];
    NSMutableSet *usedSources = [NSMutableSet set];
    for (NSEntityDescription *target in destination.entities) {
        NSEntityDescription *origin = [source.entitiesByName objectForKey:target.name];
        if (!origin && target.renamingIdentifier) origin = [source.entitiesByName objectForKey:target.renamingIdentifier];
        NSEntityMapping *entityMapping = [[[NSEntityMapping alloc] init] autorelease];
        entityMapping.destinationEntityName = target.name;
        entityMapping.destinationEntityVersionHash = target.versionHash;
        if (!origin) {
            for (NSAttributeDescription *attribute in [target.attributesByName allValues]) {
                if (!attribute.optional && !attribute.defaultValue && !attribute.isTransient) {
                    CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The new entity %@ has a required attribute without a default value.", target.name]));
                    return nil;
                }
            }
            entityMapping.name = [@"IEM_Add_" stringByAppendingString:target.name];
            entityMapping.mappingType = NSAddEntityMappingType;
            [entities addObject:entityMapping];
            continue;
        }
        [usedSources addObject:origin.name];
        BOOL same = [origin.versionHash isEqual:target.versionHash];
        entityMapping.name = [(same ? @"IEM_Copy_" : @"IEM_Transform_") stringByAppendingString:origin.name];
        entityMapping.sourceEntityName = origin.name;
        entityMapping.sourceEntityVersionHash = origin.versionHash;
        entityMapping.mappingType = same ? NSCopyEntityMappingType : NSTransformEntityMappingType;
        entityMapping.sourceExpression = CDSourceFetchExpression(origin.name);
        NSMutableArray *attributes = [NSMutableArray array];
        for (NSAttributeDescription *attribute in target.properties) {
            if (![attribute isKindOfClass:[NSAttributeDescription class]] || attribute.isTransient) continue;
            NSAttributeDescription *sourceAttribute = [origin.attributesByName objectForKey:attribute.name];
            if (!sourceAttribute && attribute.renamingIdentifier) sourceAttribute = [origin.attributesByName objectForKey:attribute.renamingIdentifier];
            if (!sourceAttribute && !attribute.optional && !attribute.defaultValue) {
                CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The new required attribute %@.%@ has no default value.", target.name, attribute.name]));
                return nil;
            }
            if (sourceAttribute && sourceAttribute.attributeType != attribute.attributeType) {
                CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The attribute %@.%@ changes type.", target.name, attribute.name]));
                return nil;
            }
            NSPropertyMapping *property = [[[NSPropertyMapping alloc] init] autorelease];
            property.name = attribute.name;
            if (sourceAttribute) property.valueExpression = CDSourceValueExpression(sourceAttribute.name);
            [attributes addObject:property];
        }
        NSMutableArray *relationships = [NSMutableArray array];
        for (NSRelationshipDescription *relationship in target.properties) {
            if (![relationship isKindOfClass:[NSRelationshipDescription class]] || relationship.isTransient) continue;
            NSRelationshipDescription *sourceRelationship = [origin.relationshipsByName objectForKey:relationship.name];
            if (!sourceRelationship && relationship.renamingIdentifier) sourceRelationship = [origin.relationshipsByName objectForKey:relationship.renamingIdentifier];
            NSPropertyMapping *property = [[[NSPropertyMapping alloc] init] autorelease];
            property.name = relationship.name;
            if (sourceRelationship)
                property.valueExpression = [NSExpression expressionForFunction:[NSExpression expressionForVariable:@"manager"]
                                                                  selectorName:@"destinationInstancesForSourceRelationshipNamed:sourceInstances:"
                                                                     arguments:[NSArray arrayWithObjects:[NSExpression expressionForConstantValue:sourceRelationship.name],
                                                                                CDSourceValueExpression(sourceRelationship.name), nil]];
            [relationships addObject:property];
        }
        entityMapping.attributeMappings = attributes;
        entityMapping.relationshipMappings = relationships;
        [entities addObject:entityMapping];
    }
    for (NSEntityDescription *origin in source.entities) {
        if ([usedSources containsObject:origin.name]) continue;
        NSEntityMapping *entityMapping = [[[NSEntityMapping alloc] init] autorelease];
        entityMapping.name = [@"IEM_Remove_" stringByAppendingString:origin.name];
        entityMapping.sourceEntityName = origin.name;
        entityMapping.sourceEntityVersionHash = origin.versionHash;
        entityMapping.mappingType = NSRemoveEntityMappingType;
        [entities addObject:entityMapping];
    }
    mapping.entityMappings = entities;
    return mapping;
}
- (instancetype)initWithContentsOfURL:(NSURL *)url {
    self = [self init];
    if (!self) return nil;
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) { [self release]; return nil; }
    [self release];
    id decoded = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    return [decoded isKindOfClass:[NSMappingModel class]] ? [decoded retain] : nil;
}
- (NSArray *)entityMappings { return CDGet(self, @"entityMappings") ?: [NSArray array]; }
- (void)setEntityMappings:(NSArray *)value { CDSet(self, @"entityMappings", [value copy] ?: [NSArray array]); }
- (NSDictionary *)entityMappingsByName {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSEntityMapping *mapping in self.entityMappings) if (mapping.name) result[mapping.name] = mapping;
    return result;
}
@end

@implementation NSMigrationManager
- (instancetype)initWithSourceModel:(NSManagedObjectModel *)sourceModel destinationModel:(NSManagedObjectModel *)destinationModel {
    self = [super init];
    if (self) {
        CDSet(self, @"sourceModel", [sourceModel retain]);
        CDSet(self, @"destinationModel", [destinationModel retain]);
        CDSet(self, @"associations", [NSMutableDictionary dictionary]);
        CDSet(self, @"usesStoreManager", [NSNumber numberWithBool:YES]);
    }
    return self;
}
- (BOOL)migrateStoreFromURL:(NSURL *)sourceURL type:(NSString *)sourceType options:(NSDictionary *)sourceOptions withMappingModel:(NSMappingModel *)mapping toDestinationURL:(NSURL *)destinationURL destinationType:(NSString *)destinationType destinationOptions:(NSDictionary *)destinationOptions error:(NSError **)error {
    if (!self.sourceModel || !self.destinationModel)
        return CDReturnError(error, CDError(134110, @"Migration needs a source and a destination model."));
    BOOL sameModel = [self.sourceModel.entityVersionHashesByName isEqual:self.destinationModel.entityVersionHashesByName];
    BOOL sqliteCopy = [sourceType isEqualToString:NSSQLiteStoreType] && [destinationType isEqualToString:NSSQLiteStoreType] &&
                      sourceURL.isFileURL && destinationURL.isFileURL;
    if (!sameModel || !sqliteCopy) {
        if (!mapping) mapping = [NSMappingModel inferredMappingModelForSourceModel:self.sourceModel destinationModel:self.destinationModel error:error];
        if (!mapping) return NO;
        return CDMigrateWithMapping(self, sourceURL, sourceType, sourceOptions, mapping, destinationURL, destinationType, destinationOptions, error);
    }

    sqlite3 *source = NULL, *destination = NULL;
    if (sqlite3_open_v2([sourceURL fileSystemRepresentation], &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSError *failure = CDError(134030, @"The source SQLite store could not be opened.");
        if (source) sqlite3_close(source);
        return CDReturnError(error, failure);
    }
    if (sqlite3_open_v2([destinationURL fileSystemRepresentation], &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSError *failure = CDError(134030, @"The destination SQLite store could not be opened.");
        sqlite3_close(source);
        if (destination) sqlite3_close(destination);
        return CDReturnError(error, failure);
    }
    sqlite3_backup *backup = sqlite3_backup_init(destination, "main", source, "main");
    int result = backup ? sqlite3_backup_step(backup, -1) : SQLITE_ERROR;
    if (backup) sqlite3_backup_finish(backup);
    sqlite3_close(source);
    sqlite3_close(destination);
    if (result != SQLITE_DONE) return CDReturnError(error, CDError(134030, @"The SQLite store could not be copied."));
    CDSet(self, @"migrationProgress", [NSNumber numberWithFloat:1.0f]);
    return YES;
}
- (BOOL)usesStoreSpecificMigrationManager { return CDGet(self, @"usesStoreManager") ? [CDGet(self, @"usesStoreManager") boolValue] : YES; }
- (void)setUsesStoreSpecificMigrationManager:(BOOL)value { CDSet(self, @"usesStoreManager", [NSNumber numberWithBool:value]); }
- (void)reset {
    CDSet(self, @"associations", [NSMutableDictionary dictionary]);
    CDSet(self, @"reverseAssociations", [NSMutableDictionary dictionary]);
    CDSet(self, @"currentMapping", nil);
    CDSet(self, @"cancelledError", nil);
    CDSet(self, @"migrationProgress", [NSNumber numberWithFloat:0]);
}
- (NSMappingModel *)mappingModel { return CDGet(self, @"mappingModel"); }
- (NSManagedObjectModel *)sourceModel { return CDGet(self, @"sourceModel"); }
- (NSManagedObjectModel *)destinationModel { return CDGet(self, @"destinationModel"); }
- (NSManagedObjectContext *)sourceContext { return CDGet(self, @"sourceContext"); }
- (NSManagedObjectContext *)destinationContext { return CDGet(self, @"destinationContext"); }
- (NSEntityDescription *)sourceEntityForEntityMapping:(NSEntityMapping *)mapping { return [self.sourceModel.entitiesByName objectForKey:mapping.sourceEntityName]; }
- (NSEntityDescription *)destinationEntityForEntityMapping:(NSEntityMapping *)mapping { return [self.destinationModel.entitiesByName objectForKey:mapping.destinationEntityName]; }
- (void)associateSourceInstance:(NSManagedObject *)source withDestinationInstance:(NSManagedObject *)destination forEntityMapping:(NSEntityMapping *)mapping {
    if (!source || !destination || !mapping.name) return;
    NSMutableDictionary *all = CDGet(self, @"associations");
    NSMutableDictionary *map = [all objectForKey:mapping.name];
    if (!map) { map = [NSMutableDictionary dictionary]; [all setObject:map forKey:mapping.name]; }
    NSMutableArray *destinations = [map objectForKey:[[source.objectID URIRepresentation] absoluteString]];
    if (!destinations) { destinations = [NSMutableArray array]; [map setObject:destinations forKey:[[source.objectID URIRepresentation] absoluteString]]; }
    [destinations addObject:destination];
    NSMutableDictionary *reverse = CDGet(self, @"reverseAssociations");
    if (!reverse) { reverse = [NSMutableDictionary dictionary]; CDSet(self, @"reverseAssociations", reverse); }
    NSMutableDictionary *back = [reverse objectForKey:mapping.name];
    if (!back) { back = [NSMutableDictionary dictionary]; [reverse setObject:back forKey:mapping.name]; }
    NSValue *key = [NSValue valueWithNonretainedObject:destination];
    NSMutableArray *sources = [back objectForKey:key];
    if (!sources) { sources = [NSMutableArray array]; [back setObject:sources forKey:key]; }
    [sources addObject:source];
}
// The destination objects made from the far side of the current mapping's
// source relationship.
- (NSArray *)destinationInstancesForSourceRelationshipNamed:(NSString *)name sourceInstances:(id)sources {
    NSEntityDescription *entity = [self.sourceModel.entitiesByName objectForKey:self.currentEntityMapping.sourceEntityName];
    NSString *target = [[entity.relationshipsByName objectForKey:name] destinationEntity].name;
    if (!target || !sources || sources == [NSNull null]) return [NSArray array];
    NSMutableArray *result = [NSMutableArray array];
    for (NSEntityMapping *mapping in self.mappingModel.entityMappings) {
        if (![mapping.sourceEntityName isEqualToString:target] || mapping.mappingType == NSRemoveEntityMappingType) continue;
        [result addObjectsFromArray:[self destinationInstancesForEntityMappingNamed:mapping.name sourceInstances:sources]];
    }
    return result;
}
- (NSFetchRequest *)fetchRequestForSourceEntityNamed:(NSString *)entityName predicateString:(NSString *)predicateString {
    return [self fetchRequestForSourceEntityNamed:entityName predicateString:predicateString includesSubentities:NO];
}
- (NSFetchRequest *)fetchRequestForSourceEntityNamed:(NSString *)entityName predicateString:(NSString *)predicateString includesSubentities:(BOOL)subentities {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
    if (predicateString.length && ![predicateString isEqualToString:@"TRUEPREDICATE"])
        request.predicate = [NSPredicate predicateWithFormat:predicateString];
    request.includesSubentities = subentities;
    return request;
}
- (NSArray *)destinationInstancesForEntityMappingNamed:(NSString *)name sourceInstances:(NSArray *)sources {
    NSDictionary *map = [CDGet(self, @"associations") objectForKey:name];
    if ([sources isKindOfClass:[NSManagedObject class]]) sources = [NSArray arrayWithObject:sources];
    else if ([sources isKindOfClass:[NSSet class]] || [sources isKindOfClass:[NSOrderedSet class]]) sources = [(id)sources allObjects] ?: [(id)sources array];
    if (sources) {
        NSMutableArray *result = [NSMutableArray array];
        for (NSManagedObject *source in sources) [result addObjectsFromArray:[map objectForKey:[[source.objectID URIRepresentation] absoluteString]] ?: [NSArray array]];
        return result;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSArray *items in [map allValues]) [result addObjectsFromArray:items];
    return result;
}
- (NSArray *)sourceInstancesForEntityMappingNamed:(NSString *)name destinationInstances:(NSArray *)destinations {
    NSDictionary *back = [CDGet(self, @"reverseAssociations") objectForKey:name];
    NSMutableArray *result = [NSMutableArray array];
    if (!destinations) {
        for (NSArray *sources in [back allValues])
            for (id source in sources) if (![result containsObject:source]) [result addObject:source];
        return result;
    }
    for (NSManagedObject *destination in destinations)
        for (id source in [back objectForKey:[NSValue valueWithNonretainedObject:destination]] ?: [NSArray array])
            if (![result containsObject:source]) [result addObject:source];
    return result;
}
- (NSEntityMapping *)currentEntityMapping { return CDGet(self, @"currentMapping"); }
- (float)migrationProgress { return [CDGet(self, @"migrationProgress") floatValue]; }
- (NSDictionary *)userInfo { return CDGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { CDSet(self, @"userInfo", [value copy]); }
- (void)cancelMigrationWithError:(NSError *)error { CDSet(self, @"cancelledError", error); }
@end

@implementation NSMigrationStage
- (NSString *)label { return CDGet(self, @"label") ?: @""; }
- (void)setLabel:(NSString *)value { CDSet(self, @"label", [value copy] ?: @""); }
@end

@implementation NSManagedObjectModelReference
- (instancetype)initWithModel:(NSManagedObjectModel *)model versionChecksum:(NSString *)checksum {
    self = [super init];
    if (self) {
        if (![model.versionChecksum isEqualToString:checksum]) { [self release]; return nil; }
        CDSet(self, @"model", [model retain]);
        CDSet(self, @"checksum", [checksum copy]);
    }
    return self;
}
- (instancetype)initWithFileURL:(NSURL *)url versionChecksum:(NSString *)checksum {
    NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:url] autorelease];
    if (!model) { [self release]; return nil; }
    return [self initWithModel:model versionChecksum:checksum];
}
- (instancetype)initWithEntityVersionHashes:(NSDictionary *)hashes inBundle:(NSBundle *)bundle versionChecksum:(NSString *)checksum {
    NSArray *bundles = bundle ? [NSArray arrayWithObject:bundle] : [NSArray arrayWithObject:[NSBundle mainBundle]];
    for (NSBundle *candidate in bundles) {
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:candidate.resourcePath error:NULL];
        for (NSString *file in files) {
            if (![@[@"mom", @"momd"] containsObject:file.pathExtension]) continue;
            NSURL *url = [NSURL fileURLWithPath:[candidate.resourcePath stringByAppendingPathComponent:file]];
            NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:url] autorelease];
            if ([model.entityVersionHashesByName isEqual:hashes]) return [self initWithModel:model versionChecksum:checksum];
        }
    }
    [self release];
    return nil;
}
- (instancetype)initWithName:(NSString *)name inBundle:(NSBundle *)bundle versionChecksum:(NSString *)checksum {
    NSBundle *target = bundle ?: [NSBundle mainBundle];
    NSURL *url = [target URLForResource:name withExtension:@"momd"] ?: [target URLForResource:name withExtension:@"mom"];
    return url ? [self initWithFileURL:url versionChecksum:checksum] : nil;
}
- (NSManagedObjectModel *)resolvedModel { return CDGet(self, @"model"); }
- (NSString *)versionChecksum { return CDGet(self, @"checksum"); }
@end

@implementation NSLightweightMigrationStage
- (instancetype)initWithVersionChecksums:(NSArray *)checksums {
    self = [super init];
    if (self) CDSet(self, @"checksums", [checksums copy]);
    return self;
}
- (NSArray *)versionChecksums { return CDGet(self, @"checksums") ?: [NSArray array]; }
@end

@implementation NSCustomMigrationStage
- (instancetype)initWithCurrentModelReference:(NSManagedObjectModelReference *)current nextModelReference:(NSManagedObjectModelReference *)next {
    self = [super init];
    if (self) { CDSet(self, @"currentModel", current); CDSet(self, @"nextModel", next); }
    return self;
}
- (NSManagedObjectModelReference *)currentModel { return CDGet(self, @"currentModel"); }
- (NSManagedObjectModelReference *)nextModel { return CDGet(self, @"nextModel"); }
- (BOOL (^)(NSStagedMigrationManager *, NSCustomMigrationStage *, NSError **))willMigrateHandler { return CDGet(self, @"willMigrateHandler"); }
- (void)setWillMigrateHandler:(BOOL (^)(NSStagedMigrationManager *, NSCustomMigrationStage *, NSError **))block { CDSet(self, @"willMigrateHandler", [[block copy] autorelease]); }
- (BOOL (^)(NSStagedMigrationManager *, NSCustomMigrationStage *, NSError **))didMigrateHandler { return CDGet(self, @"didMigrateHandler"); }
- (void)setDidMigrateHandler:(BOOL (^)(NSStagedMigrationManager *, NSCustomMigrationStage *, NSError **))block { CDSet(self, @"didMigrateHandler", [[block copy] autorelease]); }
@end

typedef BOOL (^CDMigrationStageHandler)(NSStagedMigrationManager *, NSCustomMigrationStage *, NSError **);
CDMigrationStageHandler CDGetWillMigrateHandler(NSCustomMigrationStage *stage) {
    return [stage willMigrateHandler];
}
void CDSetWillMigrateHandler(NSCustomMigrationStage *stage, CDMigrationStageHandler handler) {
    [stage setWillMigrateHandler:handler];
}
CDMigrationStageHandler CDGetDidMigrateHandler(NSCustomMigrationStage *stage) {
    return [stage didMigrateHandler];
}
void CDSetDidMigrateHandler(NSCustomMigrationStage *stage, CDMigrationStageHandler handler) {
    [stage setDidMigrateHandler:handler];
}

@implementation NSStagedMigrationManager
- (instancetype)initWithMigrationStages:(NSArray *)stages {
    self = [super init];
    if (self) CDSet(self, @"stages", [stages copy]);
    return self;
}
- (NSArray *)stages { return CDGet(self, @"stages") ?: [NSArray array]; }
- (NSPersistentContainer *)container { return CDGet(self, @"container"); }
@end

@implementation NSQueryGenerationToken
+ (NSQueryGenerationToken *)currentQueryGenerationToken {
    static NSQueryGenerationToken *token;
    @synchronized(self) {
        if (!token) token = [[NSQueryGenerationToken alloc] init];
    }
    return token;
}
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder { (void)coder; return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
@end

@implementation NSPersistentHistoryToken
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder { (void)coder; return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
@end

@implementation NSPersistentHistoryChangeRequest
+ (instancetype)requestWithOperation:(NSString *)operation value:(id)value {
    NSPersistentHistoryChangeRequest *request = [[[self alloc] init] autorelease];
    CDSet(request, @"operation", operation);
    CDSet(request, @"filter", value);
    return request;
}
+ (instancetype)fetchHistoryAfterDate:(NSDate *)date { return [self requestWithOperation:@"fetchAfterDate" value:date]; }
+ (instancetype)fetchHistoryAfterToken:(NSPersistentHistoryToken *)token { return [self requestWithOperation:@"fetchAfterToken" value:token]; }
+ (instancetype)fetchHistoryAfterTransaction:(NSPersistentHistoryTransaction *)transaction { return [self requestWithOperation:@"fetchAfterTransaction" value:transaction]; }
+ (instancetype)fetchHistoryWithFetchRequest:(NSFetchRequest *)request {
    NSPersistentHistoryChangeRequest *historyRequest = [self requestWithOperation:@"fetchWithRequest" value:nil];
    CDSet(historyRequest, @"fetchRequest", [request copy]);
    return historyRequest;
}
+ (instancetype)deleteHistoryBeforeDate:(NSDate *)date { return [self requestWithOperation:@"deleteBeforeDate" value:date]; }
+ (instancetype)deleteHistoryBeforeToken:(NSPersistentHistoryToken *)token { return [self requestWithOperation:@"deleteBeforeToken" value:token]; }
+ (instancetype)deleteHistoryBeforeTransaction:(NSPersistentHistoryTransaction *)transaction { return [self requestWithOperation:@"deleteBeforeTransaction" value:transaction]; }
- (NSPersistentHistoryResultType)resultType { return CDGet(self, @"resultType") ? [CDGet(self, @"resultType") integerValue] : NSPersistentHistoryResultTypeTransactionsAndChanges; }
- (void)setResultType:(NSPersistentHistoryResultType)value { CDSet(self, @"resultType", [NSNumber numberWithInteger:value]); }
- (NSPersistentHistoryToken *)token {
    id filter = CDGet(self, @"filter");
    if ([filter isKindOfClass:[NSPersistentHistoryToken class]]) return filter;
    if ([filter isKindOfClass:[NSPersistentHistoryTransaction class]]) return [filter token];
    return nil;
}
- (NSFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (void)setFetchRequest:(NSFetchRequest *)request { CDSet(self, @"fetchRequest", [request copy]); }
- (NSPersistentStoreRequestType)requestType { return NSFetchRequestType; }
- (id)copyWithZone:(NSZone *)zone {
    NSPersistentHistoryChangeRequest *copy = [[[self class] allocWithZone:zone] init];
    CDSet(copy, @"operation", CDGet(self, @"operation"));
    CDSet(copy, @"filter", CDGet(self, @"filter"));
    copy.resultType = self.resultType;
    copy.affectedStores = self.affectedStores;
    return copy;
}
@end

@implementation NSPersistentHistoryResult
- (id)result { return CDGet(self, @"result"); }
- (NSPersistentHistoryResultType)resultType { return [CDGet(self, @"resultType") integerValue]; }
@end

@implementation NSPersistentHistoryChange
+ (NSEntityDescription *)entityDescriptionWithContext:(NSManagedObjectContext *)context { (void)context; return nil; }
+ (NSEntityDescription *)entityDescription { return nil; }
+ (NSFetchRequest *)fetchRequest { return nil; }
- (int64_t)changeID { return [CDGet(self, @"changeID") longLongValue]; }
- (NSManagedObjectID *)changedObjectID { return CDGet(self, @"changedObjectID"); }
- (NSPersistentHistoryChangeType)changeType { return [CDGet(self, @"changeType") integerValue]; }
- (NSDictionary *)tombstone { return CDGet(self, @"tombstone"); }
- (NSPersistentHistoryTransaction *)transaction { return CDGet(self, @"transaction"); }
- (NSSet *)updatedProperties { return CDGet(self, @"updatedProperties"); }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation NSPersistentHistoryTransaction
+ (NSEntityDescription *)entityDescriptionWithContext:(NSManagedObjectContext *)context { (void)context; return nil; }
+ (NSEntityDescription *)entityDescription { return nil; }
+ (NSFetchRequest *)fetchRequest { return nil; }
- (NSDate *)timestamp { return CDGet(self, @"timestamp") ?: [NSDate dateWithTimeIntervalSince1970:0]; }
- (NSArray *)changes { return CDGet(self, @"changes"); }
- (int64_t)transactionNumber { return [CDGet(self, @"transactionNumber") longLongValue]; }
- (NSString *)storeID { return CDGet(self, @"storeID") ?: @""; }
- (NSString *)bundleID { return CDGet(self, @"bundleID") ?: @""; }
- (NSString *)processID { return CDGet(self, @"processID") ?: @""; }
- (NSString *)contextName { return CDGet(self, @"contextName"); }
- (NSString *)author { return CDGet(self, @"author"); }
- (NSPersistentHistoryToken *)token { return CDGet(self, @"token") ?: [[[NSPersistentHistoryToken alloc] init] autorelease]; }
- (NSNotification *)objectIDNotification {
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSSet set], NSInsertedObjectsKey,
                          [NSSet set], NSUpdatedObjectsKey,
                          [NSSet set], NSDeletedObjectsKey, nil];
    return [NSNotification notificationWithName:NSManagedObjectContextDidSaveObjectIDsNotification object:self userInfo:info];
}
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation NSCoreDataCoreSpotlightDelegate
- (instancetype)initForStoreWithDescription:(NSPersistentStoreDescription *)description coordinator:(NSPersistentStoreCoordinator *)coordinator {
    self = [super init];
    if (self) { CDSet(self, @"description", description); CDSet(self, @"coordinator", coordinator); }
    return self;
}
- (instancetype)initForStoreWithDescription:(NSPersistentStoreDescription *)description model:(NSManagedObjectModel *)model {
    NSPersistentStoreCoordinator *coordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] autorelease];
    return [self initForStoreWithDescription:description coordinator:coordinator];
}
- (BOOL)isIndexingEnabled { return NO; }
- (NSString *)domainIdentifier { return CDGet(self, @"domainIdentifier") ?: @""; }
- (NSString *)indexName { return CDGet(self, @"indexName"); }
- (void)startSpotlightIndexing { CDSet(self, @"indexing", [NSNumber numberWithBool:NO]); }
- (void)stopSpotlightIndexing { CDSet(self, @"indexing", [NSNumber numberWithBool:NO]); }
- (void)deleteSpotlightIndexWithCompletionHandler:(void (^)(NSError *))completionHandler {
    if (completionHandler) completionHandler(CDError(134000, @"Core Spotlight indexing is not supported."));
}
- (CSSearchableItemAttributeSet *)attributeSetForObject:(NSManagedObject *)object { (void)object; return nil; }
- (void)searchableIndex:(CSSearchableIndex *)index reindexAllSearchableItemsWithAcknowledgementHandler:(void (^)(void))handler {
    (void)index; if (handler) handler();
}
- (void)searchableIndex:(CSSearchableIndex *)index reindexSearchableItemsWithIdentifiers:(NSArray *)identifiers acknowledgementHandler:(void (^)(void))handler {
    (void)index; (void)identifiers; if (handler) handler();
}
@end

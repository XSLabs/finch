// SPDX-License-Identifier: MIT OR Apache-2.0
// Mapping-model migration: entity policies create destination objects from
// source objects, then their relationships, then the destination is saved.
#import "CDInternal.h"

static NSMutableDictionary *CDPolicyVariables(NSMigrationManager *manager, NSEntityMapping *mapping, NSEntityMigrationPolicy *policy,
                                              NSManagedObject *source, NSManagedObject *destination) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    if (manager) [variables setObject:manager forKey:NSMigrationManagerKey];
    if (mapping) [variables setObject:mapping forKey:NSMigrationEntityMappingKey];
    if (policy) [variables setObject:policy forKey:NSMigrationEntityPolicyKey];
    if (source) [variables setObject:source forKey:NSMigrationSourceObjectKey];
    if (destination) [variables setObject:destination forKey:NSMigrationDestinationObjectKey];
    return variables;
}

// A relationship mapping's value in the shape the destination relationship takes.
static id CDRelationshipValue(NSRelationshipDescription *relationship, id value) {
    if (!relationship || !value || value == [NSNull null]) return nil;
    BOOL collection = [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]];
    if (!relationship.isToMany) {
        if (!collection) return value;
        for (id item in value) return item;
        return nil;
    }
    id result = relationship.isOrdered ? (id)[NSMutableOrderedSet orderedSet] : (id)[NSMutableSet set];
    if (collection) for (id item in value) [result addObject:item];
    else [result addObject:value];
    return result;
}

@implementation NSEntityMigrationPolicy
- (BOOL)beginEntityMapping:(NSEntityMapping *)mapping manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)mapping; (void)manager; (void)error;
    return YES;
}
- (BOOL)createDestinationInstancesForSourceInstance:(NSManagedObject *)sInstance entityMapping:(NSEntityMapping *)mapping
                                            manager:(NSMigrationManager *)manager error:(NSError **)error {
    NSEntityDescription *entity = [manager destinationEntityForEntityMapping:mapping];
    if (!entity) return CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The mapping %@ has no destination entity.", mapping.name]));
    NSManagedObject *destination = CDNewObject(entity, manager.destinationContext);
    for (NSPropertyMapping *propertyMapping in mapping.attributeMappings) {
        if (!propertyMapping.valueExpression || !propertyMapping.name) continue;
        NSMutableDictionary *variables = CDPolicyVariables(manager, mapping, self, sInstance, destination);
        [variables setObject:propertyMapping forKey:NSMigrationPropertyMappingKey];
        id value = [propertyMapping.valueExpression expressionValueWithObject:sInstance context:variables];
        [destination setValue:value == [NSNull null] ? nil : value forKey:propertyMapping.name];
    }
    [manager associateSourceInstance:sInstance withDestinationInstance:destination forEntityMapping:mapping];
    return YES;
}
- (BOOL)endInstanceCreationForEntityMapping:(NSEntityMapping *)mapping manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)mapping; (void)manager; (void)error;
    return YES;
}
- (BOOL)createRelationshipsForDestinationInstance:(NSManagedObject *)dInstance entityMapping:(NSEntityMapping *)mapping
                                          manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)error;
    NSManagedObject *source = [[manager sourceInstancesForEntityMappingNamed:mapping.name destinationInstances:[NSArray arrayWithObject:dInstance]] firstObject];
    for (NSPropertyMapping *propertyMapping in mapping.relationshipMappings) {
        if (!propertyMapping.valueExpression || !propertyMapping.name) continue;
        NSMutableDictionary *variables = CDPolicyVariables(manager, mapping, self, source, dInstance);
        [variables setObject:propertyMapping forKey:NSMigrationPropertyMappingKey];
        id value = [propertyMapping.valueExpression expressionValueWithObject:source context:variables];
        NSRelationshipDescription *relationship = [dInstance.entity.relationshipsByName objectForKey:propertyMapping.name];
        [dInstance setValue:CDRelationshipValue(relationship, value) forKey:propertyMapping.name];
    }
    return YES;
}
- (BOOL)endRelationshipCreationForEntityMapping:(NSEntityMapping *)mapping manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)mapping; (void)manager; (void)error;
    return YES;
}
- (BOOL)performCustomValidationForEntityMapping:(NSEntityMapping *)mapping manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)mapping; (void)manager; (void)error;
    return YES;
}
- (BOOL)endEntityMapping:(NSEntityMapping *)mapping manager:(NSMigrationManager *)manager error:(NSError **)error {
    (void)mapping; (void)manager; (void)error;
    return YES;
}
@end

// Inferred mappings migrate the way Core Data's lightweight migration does,
// without entity policies.
static NSEntityMigrationPolicy *CDPolicyForMapping(NSEntityMapping *mapping) {
    BOOL inferred = [mapping.name hasPrefix:@"IEM_"];
    Class cls = mapping.entityMigrationPolicyClassName && !inferred ? NSClassFromString(mapping.entityMigrationPolicyClassName) : Nil;
    if (!cls || ![cls isSubclassOfClass:[NSEntityMigrationPolicy class]]) cls = [NSEntityMigrationPolicy class];
    return [[[cls alloc] init] autorelease];
}

static NSArray *CDSourceInstances(NSMigrationManager *manager, NSEntityMapping *mapping, NSError **error) {
    if (!mapping.sourceEntityName || mapping.mappingType == NSAddEntityMappingType) return [NSArray array];
    if (mapping.sourceExpression) {
        NSDictionary *variables = CDPolicyVariables(manager, mapping, nil, nil, nil);
        id value = nil;
        @try { value = [mapping.sourceExpression expressionValueWithObject:nil context:[[variables mutableCopy] autorelease]]; }
        @catch (NSException *exception) { value = nil; }
        if ([value isKindOfClass:[NSArray class]]) return value;
        if ([value isKindOfClass:[NSSet class]]) return [value allObjects];
    }
    (void)error;
    return [NSArray array];
}

static BOOL CDMigrationCancelled(NSMigrationManager *manager, NSError **error) {
    NSError *cancelled = CDGet(manager, @"cancelledError");
    if (!cancelled) return NO;
    CDReturnError(error, cancelled);
    return YES;
}

BOOL CDMigrateWithMapping(NSMigrationManager *manager, NSURL *sourceURL, NSString *sourceType, NSDictionary *sourceOptions,
                          NSMappingModel *mapping, NSURL *destinationURL, NSString *destinationType,
                          NSDictionary *destinationOptions, NSError **error) {
    [manager reset];
    NSPersistentStoreCoordinator *sourceCoordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:manager.sourceModel] autorelease];
    NSPersistentStoreCoordinator *destinationCoordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:manager.destinationModel] autorelease];
    NSPersistentStore *sourceStore = [sourceCoordinator addPersistentStoreWithType:sourceType configuration:nil URL:sourceURL options:sourceOptions error:error];
    if (!sourceStore) return NO;
    NSPersistentStore *destinationStore = [destinationCoordinator addPersistentStoreWithType:destinationType configuration:nil URL:destinationURL options:destinationOptions error:error];
    if (!destinationStore) { [sourceCoordinator removePersistentStore:sourceStore error:NULL]; return NO; }
    NSManagedObjectContext *sourceContext = [[[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType] autorelease];
    NSManagedObjectContext *destinationContext = [[[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType] autorelease];
    sourceContext.persistentStoreCoordinator = sourceCoordinator;
    destinationContext.persistentStoreCoordinator = destinationCoordinator;
    CDSet(manager, @"sourceContext", sourceContext);
    CDSet(manager, @"destinationContext", destinationContext);
    CDSet(manager, @"mappingModel", mapping);

    NSArray *mappings = mapping.entityMappings;
    NSMutableArray *policies = [NSMutableArray array];
    for (NSEntityMapping *entityMapping in mappings) [policies addObject:CDPolicyForMapping(entityMapping)];
    NSUInteger steps = MAX((NSUInteger)1, mappings.count * 3), done = 0;
    BOOL ok = YES;
    for (NSUInteger i = 0; ok && i < mappings.count; i++) {
        NSEntityMapping *entityMapping = [mappings objectAtIndex:i];
        NSEntityMigrationPolicy *policy = [policies objectAtIndex:i];
        if (entityMapping.mappingType == NSRemoveEntityMappingType) continue;
        CDSet(manager, @"currentMapping", entityMapping);
        ok = [policy beginEntityMapping:entityMapping manager:manager error:error];
        NSArray *sources = ok ? CDSourceInstances(manager, entityMapping, error) : nil;
        if (ok && !sources) ok = NO;
        for (NSManagedObject *source in sources) {
            if (!ok || CDMigrationCancelled(manager, error)) { ok = NO; break; }
            ok = [policy createDestinationInstancesForSourceInstance:source entityMapping:entityMapping manager:manager error:error];
        }
        if (ok) ok = [policy endInstanceCreationForEntityMapping:entityMapping manager:manager error:error];
        CDSet(manager, @"migrationProgress", [NSNumber numberWithFloat:(float)++done / steps]);
    }
    for (NSUInteger i = 0; ok && i < mappings.count; i++) {
        NSEntityMapping *entityMapping = [mappings objectAtIndex:i];
        NSEntityMigrationPolicy *policy = [policies objectAtIndex:i];
        if (entityMapping.mappingType == NSRemoveEntityMappingType) continue;
        CDSet(manager, @"currentMapping", entityMapping);
        for (NSManagedObject *destination in [manager destinationInstancesForEntityMappingNamed:entityMapping.name sourceInstances:nil]) {
            if (CDMigrationCancelled(manager, error)) { ok = NO; break; }
            ok = [policy createRelationshipsForDestinationInstance:destination entityMapping:entityMapping manager:manager error:error];
            if (!ok) break;
        }
        if (ok) ok = [policy endRelationshipCreationForEntityMapping:entityMapping manager:manager error:error];
        CDSet(manager, @"migrationProgress", [NSNumber numberWithFloat:(float)++done / steps]);
    }
    for (NSUInteger i = 0; ok && i < mappings.count; i++) {
        NSEntityMapping *entityMapping = [mappings objectAtIndex:i];
        if (entityMapping.mappingType == NSRemoveEntityMappingType) continue;
        CDSet(manager, @"currentMapping", entityMapping);
        ok = [[policies objectAtIndex:i] performCustomValidationForEntityMapping:entityMapping manager:manager error:error];
    }
    if (ok && !CDMigrationCancelled(manager, error)) ok = [destinationContext save:error];
    else ok = NO;
    for (NSUInteger i = 0; ok && i < mappings.count; i++) {
        NSEntityMapping *entityMapping = [mappings objectAtIndex:i];
        if (entityMapping.mappingType == NSRemoveEntityMappingType) continue;
        CDSet(manager, @"currentMapping", entityMapping);
        ok = [[policies objectAtIndex:i] endEntityMapping:entityMapping manager:manager error:error];
        CDSet(manager, @"migrationProgress", [NSNumber numberWithFloat:(float)++done / steps]);
    }
    CDSet(manager, @"currentMapping", nil);
    [sourceCoordinator removePersistentStore:sourceStore error:NULL];
    [destinationCoordinator removePersistentStore:destinationStore error:NULL];
    CDSet(manager, @"migrationProgress", [NSNumber numberWithFloat:0.0f]);
    return ok;
}

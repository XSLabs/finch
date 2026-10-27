/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coredata-classes-test: derived and composite attributes, batch
 * inserts, fetch-request expressions, the default entity migration policy and
 * the CloudKit container without mirroring (diff Apple's and Finch's).
 */
#import <CoreData/CoreData.h>
#include <stdio.h>
#include <unistd.h>
static NSString *clean(id o);
static void try(const char *what, void (^b)(void)) {
    @try { b(); }
    @catch (NSException *x) { printf("%s: %s: %s\n", what, x.name.UTF8String, clean(x.reason).UTF8String); }
}
static NSString *clean(id o) { NSString *s = [o description]; return [s stringByReplacingOccurrencesOfString:@"0x[0-9a-f]+" withString:@"ADDR" options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)]; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSEntityDescription *e = [NSEntityDescription new]; e.name = @"Song";
    NSAttributeDescription *title = [NSAttributeDescription new]; title.name = @"title"; title.attributeType = NSStringAttributeType;
    NSAttributeDescription *plays = [NSAttributeDescription new]; plays.name = @"plays"; plays.attributeType = NSInteger64AttributeType; plays.defaultValue = @0;
    NSDerivedAttributeDescription *lower = [NSDerivedAttributeDescription new]; lower.name = @"lowerTitle"; lower.attributeType = NSStringAttributeType;
    lower.derivationExpression = [NSExpression expressionWithFormat:@"lowercase:(title)"];
    NSCompositeAttributeDescription *where = [NSCompositeAttributeDescription new]; where.name = @"where";
    NSAttributeDescription *lat = [NSAttributeDescription new]; lat.name = @"lat"; lat.attributeType = NSDoubleAttributeType;
    NSAttributeDescription *lon = [NSAttributeDescription new]; lon.name = @"lon"; lon.attributeType = NSDoubleAttributeType;
    where.elements = @[lat, lon];
    e.properties = @[title, plays, lower, where];
    printf("derived type %lu expr %s desc %s\n", (unsigned long)lower.attributeType, lower.derivationExpression.description.UTF8String, clean(lower).UTF8String);
    printf("composite type %lu elements %lu desc %s\n", (unsigned long)where.attributeType, (unsigned long)where.elements.count, clean(where).UTF8String);
    NSCompositeAttributeDescription *copy = [where copy];
    printf("composite copy elements %lu equal %d class %s\n", (unsigned long)copy.elements.count, [copy isEqual:where], NSStringFromClass([copy class]).UTF8String);
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:e requiringSecureCoding:NO error:NULL];
    NSEntityDescription *back = [NSKeyedUnarchiver unarchiveObjectWithData:archived];
    printf("archived round trip %s %s\n", NSStringFromClass([back.propertiesByName[@"lowerTitle"] class]).UTF8String, NSStringFromClass([back.propertiesByName[@"where"] class]).UTF8String);
    NSManagedObjectModel *m = [NSManagedObjectModel new]; m.entities = @[e];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"probe-%d.sqlite", getpid()]];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
    NSError *error = nil;
    [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:nil error:&error];
    printf("store error %ld\n", (long)error.code);
    NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx.persistentStoreCoordinator = psc;
    NSManagedObject *s = [NSEntityDescription insertNewObjectForEntityForName:@"Song" inManagedObjectContext:ctx];
    [s setValue:@"Hello World" forKey:@"title"];
    [s setValue:@{@"lat": @1.5, @"lon": @2.5} forKey:@"where"];
    printf("before save derived %s where %s\n", [[s valueForKey:@"lowerTitle"] description].UTF8String, clean([s valueForKey:@"where"]).UTF8String);
    printf("save %d %ld\n", [ctx save:&error], (long)error.code);
    printf("after save derived %s\n", [[s valueForKey:@"lowerTitle"] description].UTF8String);
    [ctx refreshObject:s mergeChanges:NO];
    printf("after refresh derived %s where.lat %s\n", [[s valueForKey:@"lowerTitle"] description].UTF8String, [[s valueForKeyPath:@"where.lat"] description].UTF8String);
    NSFetchRequest *byLat = [NSFetchRequest fetchRequestWithEntityName:@"Song"];
    byLat.predicate = [NSPredicate predicateWithFormat:@"where.lat > 1"];
    printf("fetch by composite element %lu\n", (unsigned long)[ctx countForFetchRequest:byLat error:&error]);

    printf("== batch insert\n");
    NSBatchInsertRequest *bi = [[NSBatchInsertRequest alloc] initWithEntityName:@"Song" objects:@[@{@"title": @"One", @"plays": @3}, @{@"title": @"Two"}]];
    printf("type %lu result %lu entity %s objects %lu desc %s\n", (unsigned long)bi.requestType, (unsigned long)bi.resultType, bi.entityName.UTF8String, (unsigned long)bi.objectsToInsert.count, clean(bi).UTF8String);
    try("entity before use", ^{ printf("entity %s\n", bi.entity.name.UTF8String); });
    NSBatchInsertResult *r = [ctx executeRequest:bi error:&error];
    printf("result %s type %lu value %s\n", NSStringFromClass([r class]).UTF8String, (unsigned long)r.resultType, [r.result description].UTF8String);
    try("entity after use", ^{ printf("entity %s\n", bi.entity.name.UTF8String); });
    bi.resultType = NSBatchInsertRequestResultTypeCount;
    bi.objectsToInsert = @[@{@"title": @"Three"}];
    r = [ctx executeRequest:bi error:&error];
    printf("count result %s\n", [r.result description].UTF8String);
    __block int n = 0;
    NSBatchInsertRequest *handler = [[NSBatchInsertRequest alloc] initWithEntity:e dictionaryHandler:^BOOL(NSMutableDictionary *d) { d[@"title"] = [NSString stringWithFormat:@"Gen%d", n]; return ++n >= 3; }];
    handler.resultType = NSBatchInsertRequestResultTypeObjectIDs;
    r = [ctx executeRequest:handler error:&error];
    printf("handler ids %lu temporary %d n %d\n", (unsigned long)[r.result count], [[r.result firstObject] isTemporaryID], n);
    __block int k = 0;
    NSBatchInsertRequest *moh = [NSBatchInsertRequest batchInsertRequestWithEntityName:@"Song" managedObjectHandler:^BOOL(NSManagedObject *o) { [o setValue:@"Managed" forKey:@"title"]; return ++k >= 2; }];
    moh.resultType = NSBatchInsertRequestResultTypeCount;
    r = [ctx executeRequest:moh error:&error];
    printf("managed handler %s k %d\n", [r.result description].UTF8String, k);
    NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:@"Song"];
    all.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES]];
    NSMutableArray *titles = [NSMutableArray array];
    for (NSManagedObject *o in [ctx executeFetchRequest:all error:&error]) [titles addObject:[NSString stringWithFormat:@"%@/%@/%@", [o valueForKey:@"title"], [o valueForKey:@"plays"], [o valueForKey:@"lowerTitle"]]];
    printf("all: %s\n", [titles componentsJoinedByString:@" "].UTF8String);
    error = nil;
    r = [ctx executeRequest:[[NSBatchInsertRequest alloc] initWithEntityName:@"Nope" objects:@[]] error:&error];
    printf("bad entity %s %ld\n", r ? "result" : "nil", (long)error.code);
    try("bad key", ^{ NSError *e2 = nil; id r2 = [ctx executeRequest:[[NSBatchInsertRequest alloc] initWithEntityName:@"Song" objects:@[@{@"bogus": @1}]] error:&e2]; printf("bad key %s %ld\n", r2 ? "result" : "nil", (long)e2.code); });

    printf("== fetch expression\n");
    NSExpression *fe = [NSFetchRequestExpression expressionForFetch:[NSExpression expressionForConstantValue:all] context:[NSExpression expressionForConstantValue:ctx] countOnly:YES];
    printf("class %s type %lu count %d desc %s\n", NSStringFromClass([fe class]).UTF8String, (unsigned long)fe.expressionType, [(NSFetchRequestExpression *)fe isCountOnlyRequest], clean(fe).UTF8String);
    printf("value %s\n", [[fe expressionValueWithObject:nil context:nil] description].UTF8String);
    NSExpression *fe2 = [NSFetchRequestExpression expressionForFetch:[NSExpression expressionForConstantValue:all] context:[NSExpression expressionForConstantValue:ctx] countOnly:NO];
    printf("objects %lu\n", (unsigned long)[[fe2 expressionValueWithObject:nil context:nil] count]);

    printf("== migration policy\n");
    NSEntityMigrationPolicy *p = [NSEntityMigrationPolicy new];
    NSEntityMapping *em = [NSEntityMapping new];
    NSMigrationManager *mm = [[NSMigrationManager alloc] initWithSourceModel:m destinationModel:m];
    printf("begin %d\n", [p beginEntityMapping:em manager:mm error:&error]);
    printf("end %d\n", [p endEntityMapping:em manager:mm error:&error]);
    printf("endInstance %d endRel %d validate %d\n", [p endInstanceCreationForEntityMapping:em manager:mm error:&error], [p endRelationshipCreationForEntityMapping:em manager:mm error:&error], [p performCustomValidationForEntityMapping:em manager:mm error:&error]);
    printf("keys %s %s %s %s %s %s\n", NSMigrationManagerKey.UTF8String, NSMigrationSourceObjectKey.UTF8String, NSMigrationDestinationObjectKey.UTF8String, NSMigrationEntityMappingKey.UTF8String, NSMigrationPropertyMappingKey.UTF8String, NSMigrationEntityPolicyKey.UTF8String);

    printf("== cloudkit\n");
    NSPersistentCloudKitContainerOptions *o = [[NSPersistentCloudKitContainerOptions alloc] initWithContainerIdentifier:@"iCloud.org.finch.test"];
    printf("options %s scope %ld\n", o.containerIdentifier.UTF8String, (long)o.databaseScope);
    NSPersistentCloudKitContainer *ck = [[NSPersistentCloudKitContainer alloc] initWithName:@"Probe" managedObjectModel:m];
    NSPersistentStoreDescription *d = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:[NSURL fileURLWithPath:[path stringByAppendingString:@"-ck"]]];
    ck.persistentStoreDescriptions = @[d];
    printf("description ck options %s\n", d.cloudKitContainerOptions ? "set" : "nil");
    [ck loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *desc, NSError *err) { (void)desc; printf("loaded %ld\n", (long)err.code); }];
    printf("stores %lu can modify %d\n", (unsigned long)ck.persistentStoreCoordinator.persistentStores.count, [ck canModifyManagedObjectsInStore:ck.persistentStoreCoordinator.persistentStores.firstObject]);
    NSManagedObject *x = [NSEntityDescription insertNewObjectForEntityForName:@"Song" inManagedObjectContext:ck.viewContext];
    [x setValue:@"ck" forKey:@"title"];
    [ck.viewContext save:&error];
    printf("record %s recordID %s canUpdate %d canDelete %d\n", [ck recordForManagedObjectID:x.objectID] ? "set" : "nil", [ck recordIDForManagedObjectID:x.objectID] ? "set" : "nil", [ck canUpdateRecordForManagedObjectWithID:x.objectID], [ck canDeleteRecordForManagedObjectWithID:x.objectID]);
    printf("records %lu ids %lu\n", (unsigned long)[ck recordsForManagedObjectIDs:@[x.objectID]].count, (unsigned long)[ck recordIDsForManagedObjectIDs:@[x.objectID]].count);
    error = nil;
    BOOL init = [ck initializeCloudKitSchemaWithOptions:NSPersistentCloudKitContainerSchemaInitializationOptionsDryRun error:&error];
    printf("init schema %d %ld %s\n", init, (long)error.code, error.localizedDescription.UTF8String);
    NSPersistentCloudKitContainerEventRequest *er = [NSPersistentCloudKitContainerEventRequest fetchEventsAfterDate:[NSDate distantPast]];
    printf("event request type %lu result %lu fetch entity %s\n", (unsigned long)er.requestType, (unsigned long)er.resultType, [NSPersistentCloudKitContainerEventRequest fetchRequestForEvents].entityName.UTF8String);
    printf("event names %s %s\n", NSPersistentCloudKitContainerEventChangedNotification.UTF8String, NSPersistentCloudKitContainerEventUserInfoKey.UTF8String);
    error = nil;
    id er2 = [ck.viewContext executeRequest:er error:&error];
    printf("event fetch %s %ld %s\n", NSStringFromClass([er2 class]).UTF8String, (long)error.code, [[er2 result] description].UTF8String);
    for (NSString *suffix in @[@"", @"-shm", @"-wal", @"-ck", @"-ck-shm", @"-ck-wal"]) [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:suffix] error:NULL];
}}

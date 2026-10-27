/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coredata-migration-test: inferred mapping models, lightweight
 * migration of a SQLite store (new attribute and entity, renamed attribute and
 * entity), and mapping-model migration through entity policies (diff Apple's
 * and Finch's). Core Data finds the source model beside the tool.
 */
#import <CoreData/CoreData.h>
#include <stdio.h>
#include <unistd.h>

static NSMutableArray *policyLines;
@interface ShoutPolicy : NSEntityMigrationPolicy
@end
@implementation ShoutPolicy
- (BOOL)createDestinationInstancesForSourceInstance:(NSManagedObject *)s entityMapping:(NSEntityMapping *)m manager:(NSMigrationManager *)mgr error:(NSError **)e
{
    if (![super createDestinationInstancesForSourceInstance:s entityMapping:m manager:mgr error:e]) return NO;
    NSManagedObject *d = [mgr destinationInstancesForEntityMappingNamed:m.name sourceInstances:@[ s ]].firstObject;
    [d setValue:[[s valueForKey:@"name"] uppercaseString] forKey:@"title"];
    [policyLines addObject:[NSString stringWithFormat:@"  policy made %@ (current %@)", [d valueForKey:@"title"], mgr.currentEntityMapping.name]];
    return YES;
}
- (BOOL)endEntityMapping:(NSEntityMapping *)m manager:(NSMigrationManager *)mgr error:(NSError **)e
{
    printf("  end %s progress>0 %d\n", m.name.UTF8String, mgr.migrationProgress > 0);
    return YES;
}
@end

static NSAttributeDescription *attr(NSString *name, NSAttributeType type, id def)
{
    NSAttributeDescription *a = [NSAttributeDescription new];
    a.name = name;
    a.attributeType = type;
    a.defaultValue = def;
    return a;
}

static NSManagedObjectModel *v1(void)
{
    NSEntityDescription *item = [NSEntityDescription new], *box = [NSEntityDescription new];
    item.name = @"Item";
    box.name = @"Box";
    NSRelationshipDescription *items = [NSRelationshipDescription new], *inbox = [NSRelationshipDescription new];
    items.name = @"items"; items.destinationEntity = item; items.maxCount = 0;
    inbox.name = @"box"; inbox.destinationEntity = box; inbox.maxCount = 1;
    items.inverseRelationship = inbox; inbox.inverseRelationship = items;
    item.properties = @[ attr(@"name", NSStringAttributeType, nil), attr(@"count", NSInteger64AttributeType, @0), inbox ];
    box.properties = @[ attr(@"label", NSStringAttributeType, nil), items ];
    NSEntityDescription *note = [NSEntityDescription new], *old = [NSEntityDescription new];
    note.name = @"Note";
    note.properties = @[ attr(@"text", NSStringAttributeType, nil) ];
    old.name = @"Old";
    old.properties = @[ attr(@"junk", NSStringAttributeType, nil) ];
    NSManagedObjectModel *m = [NSManagedObjectModel new];
    m.entities = @[ item, box, note, old ];
    return m;
}

static NSManagedObjectModel *v2(void)
{
    NSEntityDescription *item = [NSEntityDescription new], *box = [NSEntityDescription new], *tag = [NSEntityDescription new];
    item.name = @"Item";
    box.name = @"Crate";
    box.renamingIdentifier = @"Box";
    tag.name = @"Tag";
    NSRelationshipDescription *items = [NSRelationshipDescription new], *inbox = [NSRelationshipDescription new];
    items.name = @"items"; items.destinationEntity = item; items.maxCount = 0;
    inbox.name = @"box"; inbox.destinationEntity = box; inbox.maxCount = 1;
    items.inverseRelationship = inbox; inbox.inverseRelationship = items;
    NSAttributeDescription *title = attr(@"title", NSStringAttributeType, nil);
    title.renamingIdentifier = @"name";
    item.properties = @[ title, attr(@"count", NSInteger64AttributeType, @0), attr(@"rating", NSInteger16AttributeType, @3), inbox ];
    box.properties = @[ attr(@"label", NSStringAttributeType, nil), items ];
    tag.properties = @[ attr(@"word", NSStringAttributeType, nil) ];
    NSEntityDescription *note = [NSEntityDescription new];
    note.name = @"Note";
    note.properties = @[ attr(@"text", NSStringAttributeType, nil) ];
    NSManagedObjectModel *m = [NSManagedObjectModel new];
    m.entities = @[ item, box, tag, note ];
    return m;
}

static void dump(NSManagedObjectContext *ctx, NSString *itemName, NSString *titleKey, NSString *boxName)
{
    NSError *error = nil;
    NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:itemName];
    f.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:titleKey ascending:YES] ];
    NSArray *items = [ctx executeFetchRequest:f error:&error];
    if (!items) printf("  fetch error %ld\n", (long)error.code);
    for (NSManagedObject *o in items) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"  %@ count=%@", [o valueForKey:titleKey], [o valueForKey:@"count"]];
        if (o.entity.attributesByName[@"rating"]) [line appendFormat:@" rating=%@", [o valueForKey:@"rating"]];
        [line appendFormat:@" box=%@", [[o valueForKey:@"box"] valueForKey:@"label"]];
        printf("%s\n", line.UTF8String);
    }
    NSFetchRequest *b = [NSFetchRequest fetchRequestWithEntityName:boxName];
    for (NSManagedObject *o in [ctx executeFetchRequest:b error:&error]) printf("  %s %s holds %lu\n", boxName.UTF8String, [[o valueForKey:@"label"] UTF8String], (unsigned long)[[o valueForKey:@"items"] count]);
}

static NSString *seed(NSString *dir, NSString *name)
{
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:v1()];
    NSError *error = nil;
    [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:nil error:&error];
    NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    ctx.persistentStoreCoordinator = psc;
    NSManagedObject *box = [NSEntityDescription insertNewObjectForEntityForName:@"Box" inManagedObjectContext:ctx];
    [box setValue:@"red" forKey:@"label"];
    for (NSString *n in @[ @"apple", @"pear" ]) {
        NSManagedObject *o = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:ctx];
        [o setValue:n forKey:@"name"];
        [o setValue:@(n.length) forKey:@"count"];
        [o setValue:box forKey:@"box"];
    }
    NSManagedObject *note = [NSEntityDescription insertNewObjectForEntityForName:@"Note" inManagedObjectContext:ctx];
    [note setValue:@"remember" forKey:@"text"];
    printf("seed save %d\n", [ctx save:&error]);
    [psc removePersistentStore:psc.persistentStores.firstObject error:NULL];
    return path;
}

int main(int argc, char **argv)
{
    (void)argc;
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        policyLines = [NSMutableArray array];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-mig-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        /* the source model where Core Data looks for it: beside the tool */
        NSString *tool = [[NSString stringWithUTF8String:argv[0]] stringByResolvingSymlinksInPath];
        NSString *mom = [[tool stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"FinchMigV1.mom"];
        [[NSKeyedArchiver archivedDataWithRootObject:v1() requiringSecureCoding:NO error:NULL] writeToFile:mom atomically:YES];

        printf("== inferred mapping\n");
        NSError *error = nil;
        NSMappingModel *inferred = [NSMappingModel inferredMappingModelForSourceModel:v1() destinationModel:v2() error:&error];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSEntityMapping *em in inferred.entityMappings) {
            NSMutableArray *props = [NSMutableArray array];
            for (NSPropertyMapping *pm in [em.attributeMappings arrayByAddingObjectsFromArray:em.relationshipMappings ?: @[]])
                [props addObject:[NSString stringWithFormat:@"%@<-%@", pm.name, pm.valueExpression]];
            [props sortUsingSelector:@selector(compare:)];
            [lines addObject:[NSString stringWithFormat:@"%@ %@->%@ type %lu policy %@ source %@ [%@]", em.name, em.sourceEntityName, em.destinationEntityName, (unsigned long)em.mappingType, em.entityMigrationPolicyClassName, em.sourceExpression, [props componentsJoinedByString:@"; "]]];
        }
        [lines sortUsingSelector:@selector(compare:)];
        printf("%s\n", [lines componentsJoinedByString:@"\n"].UTF8String);

        printf("== open v1 store with v2, no options\n");
        NSString *a = seed(dir, @"a.sqlite");
        NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:v2()];
        error = nil;
        NSPersistentStore *s = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:a] options:nil error:&error];
        printf("store %d error %ld\n", s != nil, (long)error.code);

        printf("== lightweight\n");
        error = nil;
        s = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:a]
                                     options:@{ NSMigratePersistentStoresAutomaticallyOption : @YES, NSInferMappingModelAutomaticallyOption : @YES } error:&error];
        printf("store %d error %ld\n", s != nil, (long)error.code);
        NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        ctx.persistentStoreCoordinator = psc;
        dump(ctx, @"Item", @"title", @"Crate");
        printf("  notes: %s\n", [[[ctx executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Note"] error:&error] valueForKey:@"text"] componentsJoinedByString:@","].UTF8String);
        NSManagedObject *t = [NSEntityDescription insertNewObjectForEntityForName:@"Tag" inManagedObjectContext:ctx];
        [t setValue:@"fresh" forKey:@"word"];
        NSManagedObject *n = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:ctx];
        [n setValue:@"plum" forKey:@"title"];
        printf("save after migration %d\n", [ctx save:&error]);
        printf("compatible %d\n", [v2() isConfiguration:nil compatibleWithStoreMetadata:s.metadata]);

        printf("== mapping model migration\n");
        NSString *b = seed(dir, @"b.sqlite");
        NSString *c = [dir stringByAppendingPathComponent:@"c.sqlite"];
        NSMappingModel *inferredAgain = [NSMappingModel inferredMappingModelForSourceModel:v1() destinationModel:v2() error:&error];
        printf("inferred class %s\n", NSStringFromClass([inferredAgain class]).UTF8String);
        NSMappingModel *mapping = [NSMappingModel new];
        NSMutableArray *fresh = [NSMutableArray array];
        for (NSEntityMapping *em in inferredAgain.entityMappings) {
            NSEntityMapping *copy = [NSEntityMapping new];
            copy.name = [em.name stringByReplacingOccurrencesOfString:@"IEM_" withString:@"Custom_"];
            copy.mappingType = em.mappingType == NSTransformEntityMappingType ? NSCustomEntityMappingType : em.mappingType;
            copy.sourceEntityName = em.sourceEntityName;
            copy.sourceEntityVersionHash = em.sourceEntityVersionHash;
            copy.destinationEntityName = em.destinationEntityName;
            copy.destinationEntityVersionHash = em.destinationEntityVersionHash;
            copy.sourceExpression = em.sourceExpression;
            copy.attributeMappings = em.attributeMappings;
            copy.relationshipMappings = em.relationshipMappings;
            if ([em.sourceEntityName isEqualToString:@"Item"]) copy.entityMigrationPolicyClassName = @"ShoutPolicy";
            [fresh addObject:copy];
        }
        mapping.entityMappings = fresh;
        for (NSEntityMapping *em in mapping.entityMappings)
            if ([em.sourceEntityName isEqualToString:@"Item"]) em.entityMigrationPolicyClassName = @"ShoutPolicy";
        NSMigrationManager *mgr = [[NSMigrationManager alloc] initWithSourceModel:v1() destinationModel:v2()];
        BOOL ok = [mgr migrateStoreFromURL:[NSURL fileURLWithPath:b] type:NSSQLiteStoreType options:nil withMappingModel:mapping
                          toDestinationURL:[NSURL fileURLWithPath:c] destinationType:NSSQLiteStoreType destinationOptions:nil error:&error];
        [policyLines sortUsingSelector:@selector(compare:)];
        printf("%s\n", [policyLines componentsJoinedByString:@"\n"].UTF8String);
        printf("migrated %d error %ld progress %.1f\n", ok, (long)error.code, mgr.migrationProgress);
        NSPersistentStoreCoordinator *psc2 = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:v2()];
        [psc2 addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:c] options:nil error:&error];
        NSManagedObjectContext *ctx2 = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        ctx2.persistentStoreCoordinator = psc2;
        dump(ctx2, @"Item", @"title", @"Crate");
        NSFetchRequest *notes = [NSFetchRequest fetchRequestWithEntityName:@"Note"];
        printf("  notes: %s\n", [[[ctx2 executeFetchRequest:notes error:&error] valueForKey:@"text"] componentsJoinedByString:@","].UTF8String);

        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:mom error:NULL];
    }
    return 0;
}

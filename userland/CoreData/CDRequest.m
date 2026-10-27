// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

@implementation NSPersistentStoreRequest
- (NSArray *)affectedStores { return CDGet(self, @"affectedStores"); }
- (void)setAffectedStores:(NSArray *)stores { CDSet(self, @"affectedStores", [stores copy]); }
- (NSPersistentStoreRequestType)requestType { return (NSPersistentStoreRequestType)[CDGet(self, @"requestType") unsignedIntegerValue]; }
- (id)copyWithZone:(NSZone *)zone {
    NSPersistentStoreRequest *copy = [[[self class] allocWithZone:zone] init];
    copy.affectedStores = self.affectedStores;
    return copy;
}
@end

@implementation NSFetchRequest
+ (instancetype)fetchRequestWithEntityName:(NSString *)name { return [[[self alloc] initWithEntityName:name] autorelease]; }
- (instancetype)init {
    self = [super init];
    if (self) {
        self.resultType = NSManagedObjectResultType;
        self.includesSubentities = YES;
        self.includesPropertyValues = YES;
        self.returnsObjectsAsFaults = YES;
        self.includesPendingChanges = YES;
    }
    return self;
}
- (instancetype)initWithEntityName:(NSString *)name {
    self = [self init];
    if (self) CDSet(self, @"entityName", [name copy]);
    return self;
}
// Like Core Data, a request made from an entity name cannot say which entity
// it means until a context has run it.
- (NSEntityDescription *)entity {
    NSEntityDescription *entity = CDGet(self, @"entity");
    if (!entity && CDGet(self, @"entityName"))
        [NSException raise:NSObjectInaccessibleException format:@"This fetch request (%p) was created with a string name (%@), and cannot respond to -entity until used by an NSManagedObjectContext",
         self, CDGet(self, @"entityName")];
    return entity;
}
- (void)setEntity:(NSEntityDescription *)entity {
    CDSet(self, @"entity", entity);
    if (entity.name) CDSet(self, @"entityName", [entity.name copy]);
}
- (NSString *)entityName { return CDGet(self, @"entityName") ?: [CDGet(self, @"entity") name]; }
- (NSPredicate *)predicate { return CDGet(self, @"predicate"); }
- (void)setPredicate:(NSPredicate *)value { CDSet(self, @"predicate", [value copy]); }
- (NSArray *)sortDescriptors { return CDGet(self, @"sortDescriptors"); }
- (void)setSortDescriptors:(NSArray *)value { CDSet(self, @"sortDescriptors", [value copy]); }
- (NSUInteger)fetchLimit { return [CDGet(self, @"fetchLimit") unsignedIntegerValue]; }
- (void)setFetchLimit:(NSUInteger)value { CDSet(self, @"fetchLimit", [NSNumber numberWithUnsignedInteger:value]); }
- (NSFetchRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
- (void)setResultType:(NSFetchRequestResultType)value {
    CDSet(self, @"resultType", [NSNumber numberWithUnsignedInteger:value]);
    if (value == NSManagedObjectIDResultType || value == NSCountResultType) self.includesPropertyValues = NO;
}
- (NSString *)description {
    static NSString *const types[] = { @"NSManagedObjectResultType", @"NSManagedObjectIDResultType", @"NSDictionaryResultType", @"", @"NSCountResultType" };
    NSUInteger type = self.resultType;
    NSMutableString *text = [NSMutableString stringWithFormat:@"<NSFetchRequest: %p> (entity: %@; predicate: (%@); sortDescriptors: (%@); ",
                             self, self.entityName, self.predicate, self.sortDescriptors];
    if (self.fetchLimit) [text appendFormat:@"limit: %lu; ", (unsigned long)self.fetchLimit];
    if (self.fetchOffset) [text appendFormat:@"offset: %lu; ", (unsigned long)self.fetchOffset];
    if (self.fetchBatchSize) [text appendFormat:@"batch size: %lu; ", (unsigned long)self.fetchBatchSize];
    [text appendFormat:@"type: %@; ", type < 5 ? types[type] : @""];
    if (!self.includesSubentities) [text appendString:@"includesSubentities: NO; "];
    if (!self.includesPropertyValues) [text appendString:@"includesPropertyValues: NO; "];
    if (!self.returnsObjectsAsFaults) [text appendString:@"returnsObjectsAsFaults: NO; "];
    if (!self.includesPendingChanges) [text appendString:@"includesPendingChanges: NO; "];
    if (self.returnsDistinctResults) [text appendString:@"returnsDistinctResults: YES; "];
    if (self.shouldRefreshRefetchedObjects) [text appendString:@"shouldRefreshRefetchedObjects: YES; "];
    if (self.relationshipKeyPathsForPrefetching.count) [text appendFormat:@"relationshipKeyPathsForPrefetching: (%@); ", self.relationshipKeyPathsForPrefetching];
    if (self.propertiesToFetch.count) [text appendFormat:@"propertiesToFetch: (%@); ", self.propertiesToFetch];
    if (self.havingPredicate) [text appendFormat:@"havingPredicate: (%@); ", self.havingPredicate];
    if (self.propertiesToGroupBy.count) [text appendFormat:@"propertiesToGroupBy: (%@); ", self.propertiesToGroupBy];
    if (self.affectedStores.count) [text appendFormat:@"affected stores: (%@); ", [self.affectedStores valueForKey:@"identifier"]];
    [text appendString:@")"];
    return text;
}
- (BOOL)includesSubentities { return CDGet(self, @"includesSubentities") ? [CDGet(self, @"includesSubentities") boolValue] : YES; }
- (void)setIncludesSubentities:(BOOL)value { CDSet(self, @"includesSubentities", [NSNumber numberWithBool:value]); }
- (BOOL)includesPropertyValues { return CDGet(self, @"includesPropertyValues") ? [CDGet(self, @"includesPropertyValues") boolValue] : YES; }
- (void)setIncludesPropertyValues:(BOOL)value { CDSet(self, @"includesPropertyValues", [NSNumber numberWithBool:value]); }
- (BOOL)returnsObjectsAsFaults { return CDGet(self, @"returnsObjectsAsFaults") ? [CDGet(self, @"returnsObjectsAsFaults") boolValue] : YES; }
- (void)setReturnsObjectsAsFaults:(BOOL)value { CDSet(self, @"returnsObjectsAsFaults", [NSNumber numberWithBool:value]); }
- (NSArray *)relationshipKeyPathsForPrefetching { return CDGet(self, @"relationshipKeyPathsForPrefetching"); }
- (void)setRelationshipKeyPathsForPrefetching:(NSArray *)value { CDSet(self, @"relationshipKeyPathsForPrefetching", [value copy]); }
- (BOOL)includesPendingChanges { return CDGet(self, @"includesPendingChanges") ? [CDGet(self, @"includesPendingChanges") boolValue] : YES; }
- (void)setIncludesPendingChanges:(BOOL)value { CDSet(self, @"includesPendingChanges", [NSNumber numberWithBool:value]); }
- (BOOL)returnsDistinctResults { return [CDGet(self, @"returnsDistinctResults") boolValue]; }
- (void)setReturnsDistinctResults:(BOOL)value { CDSet(self, @"returnsDistinctResults", [NSNumber numberWithBool:value]); }
- (NSArray *)propertiesToFetch { return CDGet(self, @"propertiesToFetch"); }
- (void)setPropertiesToFetch:(NSArray *)value { CDSet(self, @"propertiesToFetch", [value copy]); }
- (NSUInteger)fetchOffset { return [CDGet(self, @"fetchOffset") unsignedIntegerValue]; }
- (void)setFetchOffset:(NSUInteger)value { CDSet(self, @"fetchOffset", [NSNumber numberWithUnsignedInteger:value]); }
- (NSUInteger)fetchBatchSize { return [CDGet(self, @"fetchBatchSize") unsignedIntegerValue]; }
- (void)setFetchBatchSize:(NSUInteger)value { CDSet(self, @"fetchBatchSize", [NSNumber numberWithUnsignedInteger:value]); }
- (BOOL)shouldRefreshRefetchedObjects { return [CDGet(self, @"shouldRefreshRefetchedObjects") boolValue]; }
- (void)setShouldRefreshRefetchedObjects:(BOOL)value { CDSet(self, @"shouldRefreshRefetchedObjects", [NSNumber numberWithBool:value]); }
- (NSArray *)propertiesToGroupBy { return CDGet(self, @"propertiesToGroupBy"); }
- (void)setPropertiesToGroupBy:(NSArray *)value { CDSet(self, @"propertiesToGroupBy", [value copy]); }
- (NSPredicate *)havingPredicate { return CDGet(self, @"havingPredicate"); }
- (void)setHavingPredicate:(NSPredicate *)value { CDSet(self, @"havingPredicate", [value copy]); }
- (NSArray *)affectedStores { return [super affectedStores]; }
- (NSPersistentStoreRequestType)requestType { return NSFetchRequestType; }
// Runs in the context whose perform block is current.
- (NSArray *)execute:(NSError **)error {
    NSManagedObjectContext *context = (NSManagedObjectContext *)dispatch_get_specific(@selector(_finchContextQueue));
    if (context) return [context executeFetchRequest:self error:error];
    CDReturnError(error, [NSError errorWithDomain:NSCocoaErrorDomain code:134060 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
        @"A Core Data error occurred.", NSLocalizedDescriptionKey,
        @"Cannot fetch without an NSManagedObjectContext in scope", @"message", nil]]);
    return nil;
}
- (id)copyWithZone:(NSZone *)zone {
    NSFetchRequest *copy = [[[self class] allocWithZone:zone] initWithEntityName:self.entityName];
    if (CDGet(self, @"entity")) copy.entity = CDGet(self, @"entity");
    copy.predicate = self.predicate;
    copy.sortDescriptors = self.sortDescriptors;
    copy.fetchLimit = self.fetchLimit;
    copy.resultType = self.resultType;
    copy.includesSubentities = self.includesSubentities;
    copy.includesPropertyValues = self.includesPropertyValues;
    copy.returnsObjectsAsFaults = self.returnsObjectsAsFaults;
    copy.relationshipKeyPathsForPrefetching = self.relationshipKeyPathsForPrefetching;
    copy.includesPendingChanges = self.includesPendingChanges;
    copy.returnsDistinctResults = self.returnsDistinctResults;
    copy.propertiesToFetch = self.propertiesToFetch;
    copy.fetchOffset = self.fetchOffset;
    copy.fetchBatchSize = self.fetchBatchSize;
    copy.shouldRefreshRefetchedObjects = self.shouldRefreshRefetchedObjects;
    copy.propertiesToGroupBy = self.propertiesToGroupBy;
    copy.havingPredicate = self.havingPredicate;
    copy.affectedStores = self.affectedStores;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [self initWithEntityName:[coder decodeObjectForKey:@"NSEntityName"]];
    if (self) {
        self.predicate = [coder decodeObjectForKey:@"NSPredicate"];
        self.sortDescriptors = [coder decodeObjectForKey:@"NSSortDescriptors"];
        self.fetchLimit = (NSUInteger)[coder decodeIntegerForKey:@"NSFetchLimit"];
        self.resultType = (NSFetchRequestResultType)[coder decodeIntegerForKey:@"NSFetchRequestResultType"];
        self.includesSubentities = [coder decodeBoolForKey:@"NSIncludesSubentities"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.entityName forKey:@"NSEntityName"];
    [coder encodeObject:self.predicate forKey:@"NSPredicate"];
    [coder encodeObject:self.sortDescriptors forKey:@"NSSortDescriptors"];
    [coder encodeInteger:self.fetchLimit forKey:@"NSFetchLimit"];
    [coder encodeInteger:self.resultType forKey:@"NSFetchRequestResultType"];
    [coder encodeBool:self.includesSubentities forKey:@"NSIncludesSubentities"];
}
@end

@implementation NSBatchDeleteRequest
- (instancetype)init { return [self initWithFetchRequest:[[[NSFetchRequest alloc] init] autorelease]]; }
- (instancetype)initWithFetchRequest:(NSFetchRequest *)fetch {
    self = [super init];
    if (self) {
        NSFetchRequest *request = [[fetch copy] autorelease];
        request.resultType = NSManagedObjectIDResultType;
        request.includesPropertyValues = NO;
        request.includesPendingChanges = NO;
        CDSet(self, @"fetchRequest", request);
        self.resultType = NSBatchDeleteResultTypeStatusOnly;
    }
    return self;
}
- (instancetype)initWithObjectIDs:(NSArray *)objects {
    if (!objects.count) {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"Must supply a non-zero number of objectIDs to request during initialization"];
    }
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    request.entity = [(NSManagedObjectID *)[objects firstObject] entity];
    self = [self initWithFetchRequest:request];
    if (self) CDSet(self, @"objectIDs", [objects copy]);
    return self;
}
- (NSFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (NSBatchDeleteRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
- (void)setResultType:(NSBatchDeleteRequestResultType)value { CDSet(self, @"resultType", [NSNumber numberWithUnsignedInteger:value]); }
- (NSPersistentStoreRequestType)requestType { return NSBatchDeleteRequestType; }
- (id)copyWithZone:(NSZone *)zone {
    NSBatchDeleteRequest *copy = [[[self class] allocWithZone:zone] initWithFetchRequest:self.fetchRequest];
    copy.resultType = self.resultType;
    return copy;
}
@end

@implementation NSBatchUpdateRequest
+ (instancetype)batchUpdateRequestWithEntityName:(NSString *)name { return [[[self alloc] initWithEntityName:name] autorelease]; }
- (instancetype)init { return [self initWithEntityName:@""]; }
- (instancetype)initWithEntityName:(NSString *)name {
    self = [super init];
    if (self) {
        CDSet(self, @"entityName", [name copy]);
        self.includesSubentities = YES;
        self.resultType = NSStatusOnlyResultType;
    }
    return self;
}
- (instancetype)initWithEntity:(NSEntityDescription *)entity {
    self = [super init];
    if (self) {
        CDSet(self, @"entityName", [entity.name copy]);
        CDSet(self, @"entity", entity);
        self.includesSubentities = YES;
        self.resultType = NSStatusOnlyResultType;
    }
    return self;
}
- (NSString *)entityName { return CDGet(self, @"entityName") ?: [CDGet(self, @"entity") name]; }
- (NSEntityDescription *)entity {
    NSEntityDescription *entity = CDGet(self, @"entity");
    if (!entity && [CDGet(self, @"entityName") length])
        [NSException raise:NSObjectInaccessibleException format:@"This batch update request (%p) was created with a string name (%@), and cannot respond to -entity until used by an NSManagedObjectContext",
         self, CDGet(self, @"entityName")];
    return entity;
}
- (NSPredicate *)predicate { return CDGet(self, @"predicate"); }
- (void)setPredicate:(NSPredicate *)value { CDSet(self, @"predicate", [value copy]); }
- (BOOL)includesSubentities { return CDGet(self, @"includesSubentities") ? [CDGet(self, @"includesSubentities") boolValue] : YES; }
- (void)setIncludesSubentities:(BOOL)value { CDSet(self, @"includesSubentities", [NSNumber numberWithBool:value]); }
- (NSBatchUpdateRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
- (void)setResultType:(NSBatchUpdateRequestResultType)value { CDSet(self, @"resultType", [NSNumber numberWithUnsignedInteger:value]); }
- (NSDictionary *)propertiesToUpdate { return CDGet(self, @"propertiesToUpdate"); }
- (void)setPropertiesToUpdate:(NSDictionary *)value { CDSet(self, @"propertiesToUpdate", [value copy]); }
- (NSPersistentStoreRequestType)requestType { return NSBatchUpdateRequestType; }
- (id)copyWithZone:(NSZone *)zone {
    NSBatchUpdateRequest *copy = [[[self class] allocWithZone:zone] initWithEntityName:self.entityName];
    CDSet(copy, @"entity", CDGet(self, @"entity"));
    copy.predicate = self.predicate;
    copy.includesSubentities = self.includesSubentities;
    copy.resultType = self.resultType;
    copy.propertiesToUpdate = self.propertiesToUpdate;
    copy.affectedStores = self.affectedStores;
    return copy;
}
@end

@implementation NSPersistentStoreResult
@end

@implementation NSBatchDeleteResult
- (id)result { return CDGet(self, @"result"); }
- (NSBatchDeleteRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
@end

@implementation NSBatchUpdateResult
- (id)result { return CDGet(self, @"result"); }
- (NSBatchUpdateRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
@end

@implementation NSBatchInsertResult
- (id)result { return CDGet(self, @"result"); }
- (NSBatchInsertRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
@end

@implementation NSPersistentStoreAsynchronousResult
- (NSManagedObjectContext *)managedObjectContext { return CDGet(self, @"managedObjectContext"); }
- (NSError *)operationError { return CDGet(self, @"operationError"); }
- (NSProgress *)progress { return CDGet(self, @"progress"); }
- (void)cancel { [self.progress cancel]; }
@end

@implementation NSAsynchronousFetchRequest
- (instancetype)initWithFetchRequest:(NSFetchRequest<id<NSFetchRequestResult>> *)request completionBlock:(void (^)(NSAsynchronousFetchResult<id<NSFetchRequestResult>> *))block {
    self = [super init];
    if (self) { CDSet(self, @"fetchRequest", [request copy]); if (block) CDSet(self, @"completionBlock", [[block copy] autorelease]); }
    return self;
}
- (NSFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (void (^)(NSAsynchronousFetchResult *))completionBlock { return CDGet(self, @"completionBlock"); }
- (NSInteger)estimatedResultCount { return [CDGet(self, @"estimatedResultCount") integerValue]; }
- (void)setEstimatedResultCount:(NSInteger)value { CDSet(self, @"estimatedResultCount", [NSNumber numberWithInteger:value]); }
@end

@implementation NSAsynchronousFetchResult
- (NSAsynchronousFetchRequest *)fetchRequest { return CDGet(self, @"fetchRequest"); }
- (NSArray *)finalResult { return CDGet(self, @"finalResult"); }
@end

// The objects a fetch can return, as Core Data declares them.
@implementation NSNumber (NSFetchedResultSupport)
@end
@implementation NSDictionary (NSFetchedResultSupport)
@end
@implementation NSManagedObject (NSFetchedResultSupport)
@end
@implementation NSManagedObjectID (NSFetchedResultSupport)
@end

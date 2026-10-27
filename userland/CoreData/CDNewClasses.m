// SPDX-License-Identifier: MIT OR Apache-2.0
// Derived and composite attributes, fetch-request expressions, batch inserts
// and the CloudKit container. Finch has no CloudKit mirroring: the CloudKit
// container keeps its stores local, as Core Data does without an account.
#import "CDInternal.h"
#import <CommonCrypto/CommonDigest.h>

@class CKShare, CKContainer, CKRecordZoneID, CKRecord, CKRecordID;

@implementation NSDerivedAttributeDescription
- (NSExpression *)derivationExpression { return CDGet(self, @"derivationExpression"); }
- (NSString *)description {
    return [NSString stringWithFormat:@"%@, attributeType %lu , attributeValueClassName %@, derivationExpression %@, filteringPredicate %@, preservesValueInHistoryOnDeletion %@",
            [super description], (unsigned long)self.attributeType, self.attributeValueClassName, self.derivationExpression,
            CDGet(self, @"filteringPredicate"), self.preservesValueInHistoryOnDeletion ? @"YES" : @"NO"];
}
- (BOOL)isEqual:(id)other {
    return [super isEqual:other] && (self.derivationExpression == [other derivationExpression] || [self.derivationExpression isEqual:[other derivationExpression]]);
}
- (NSUInteger)hash { return [super hash]; }
- (void)setDerivationExpression:(NSExpression *)expression { CDSet(self, @"derivationExpression", expression); }
// Core Data hashes only the expressions of a derived attribute.
- (NSData *)versionHash {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const char *text = [[self.derivationExpression description] UTF8String];
    if (text) CC_SHA256_Update(&context, text, (CC_LONG)strlen(text));
    text = [[CDGet(self, @"filteringPredicate") predicateFormat] UTF8String];
    if (text) CC_SHA256_Update(&context, text, (CC_LONG)strlen(text));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
- (id)copyWithZone:(NSZone *)zone {
    NSDerivedAttributeDescription *copy = [super copyWithZone:zone];
    copy.derivationExpression = self.derivationExpression;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) self.derivationExpression = [coder decodeObjectForKey:@"NSDerivationExpression"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:self.derivationExpression forKey:@"NSDerivationExpression"];
}
@end

@implementation NSCompositeAttributeDescription
- (instancetype)init {
    self = [super init];
    if (self) CDSet(self, @"attributeType", [NSNumber numberWithUnsignedInteger:NSCompositeAttributeType]);
    return self;
}
- (NSAttributeType)attributeType { return NSCompositeAttributeType; }
- (void)setAttributeType:(NSAttributeType)type {
    if (type != NSCompositeAttributeType)
        [NSException raise:NSInvalidArgumentException format:@"The attribute type of a composite cannot be changed from NSCompositeAttributeType."];
}
- (NSString *)attributeValueClassName { return @"NSDictionary"; }
- (NSArray *)elements { return CDGet(self, @"elements") ?: [NSArray array]; }
- (NSString *)description {
    return [NSString stringWithFormat:@"%@, attributeType %lu , elements %@, preservesValueInHistoryOnDeletion %@",
            [super description], (unsigned long)self.attributeType, self.elements, self.preservesValueInHistoryOnDeletion ? @"YES" : @"NO"];
}
- (BOOL)isEqual:(id)other { return [super isEqual:other] && [self.elements isEqual:[other elements]]; }
static void CDFlattenElements(NSArray *elements, NSMutableArray *into) {
    for (NSAttributeDescription *element in elements) {
        if ([element isKindOfClass:[NSCompositeAttributeDescription class]]) CDFlattenElements([(NSCompositeAttributeDescription *)element elements], into);
        else if ([element isKindOfClass:[NSAttributeDescription class]] && !element.isTransient) [into addObject:element];
    }
}
// Core Data hashes a composite by its elements, in name order.
- (NSData *)versionHash {
    NSMutableArray *elements = [NSMutableArray array];
    CDFlattenElements(self.elements, elements);
    [elements sortUsingComparator:^NSComparisonResult(id a, id b) { return [[a name] compare:[b name]]; }];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (NSAttributeDescription *element in elements) {
        NSData *hash = element.versionHash;
        CC_SHA256_Update(&context, hash.bytes, (CC_LONG)hash.length);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
- (NSUInteger)hash { return [super hash]; }
- (void)setElements:(NSArray *)elements { CDSet(self, @"elements", [[elements copy] autorelease]); }
- (id)copyWithZone:(NSZone *)zone {
    NSCompositeAttributeDescription *copy = [super copyWithZone:zone];
    copy.elements = self.elements;
    return copy;
}
- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) self.elements = [coder decodeObjectForKey:@"NSCompositeElements"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:self.elements forKey:@"NSCompositeElements"];
}
@end

@implementation NSFetchRequestExpression
+ (BOOL)supportsSecureCoding { return YES; }
+ (NSExpression *)expressionForFetch:(NSExpression *)fetch context:(NSExpression *)context countOnly:(BOOL)countFlag {
    NSFetchRequestExpression *expression = [[[self alloc] initWithExpressionType:NSFetchRequestExpressionType] autorelease];
    CDSet(expression, @"request", fetch);
    CDSet(expression, @"context", context);
    CDSet(expression, @"countOnly", [NSNumber numberWithBool:countFlag]);
    return expression;
}
- (NSExpressionType)expressionType { return NSFetchRequestExpressionType; }
- (NSExpression *)requestExpression { return CDGet(self, @"request"); }
- (NSExpression *)contextExpression { return CDGet(self, @"context"); }
- (BOOL)isCountOnlyRequest { return [CDGet(self, @"countOnly") boolValue]; }
- (NSString *)description {
    return [NSString stringWithFormat:@"FETCH(%@, %@, %@)", self.requestExpression, self.contextExpression, self.isCountOnlyRequest ? @"YES" : @"NO"];
}
- (NSString *)predicateFormat { return self.description; }
- (id)expressionValueWithObject:(id)object context:(NSMutableDictionary *)variables {
    id request = [self.requestExpression expressionValueWithObject:object context:variables];
    id context = [self.contextExpression expressionValueWithObject:object context:variables];
    if (![request isKindOfClass:[NSFetchRequest class]] || ![context isKindOfClass:[NSManagedObjectContext class]]) return nil;
    NSError *error = nil;
    if (self.isCountOnlyRequest) {
        NSUInteger count = [context countForFetchRequest:request error:&error];
        return count == NSNotFound ? nil : [NSNumber numberWithUnsignedInteger:count];
    }
    return [context executeFetchRequest:request error:&error];
}
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return [[NSFetchRequestExpression expressionForFetch:self.requestExpression context:self.contextExpression countOnly:self.isCountOnlyRequest] retain];
}
- (BOOL)isEqual:(id)other {
    if (![other isKindOfClass:[NSFetchRequestExpression class]]) return NO;
    NSFetchRequestExpression *expression = other;
    return [self.requestExpression isEqual:expression.requestExpression] && [self.contextExpression isEqual:expression.contextExpression] &&
           self.isCountOnlyRequest == expression.isCountOnlyRequest;
}
- (NSUInteger)hash { return [self.requestExpression hash] ^ [self.contextExpression hash]; }
- (id)initWithCoder:(NSCoder *)coder {
    self = [self initWithExpressionType:NSFetchRequestExpressionType];
    if (self) {
        CDSet(self, @"request", [coder decodeObjectForKey:@"NSFRExpression"]);
        CDSet(self, @"context", [coder decodeObjectForKey:@"NSMOCExpression"]);
        CDSet(self, @"countOnly", [NSNumber numberWithBool:[coder decodeBoolForKey:@"NSCountOnlyFlag"]]);
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:NSFetchRequestExpressionType forKey:@"NSExpressionType"];
    [coder encodeObject:self.requestExpression forKey:@"NSFRExpression"];
    [coder encodeObject:self.contextExpression forKey:@"NSMOCExpression"];
    [coder encodeBool:self.isCountOnlyRequest forKey:@"NSCountOnlyFlag"];
}
@end

@implementation NSBatchInsertRequest
+ (instancetype)batchInsertRequestWithEntityName:(NSString *)entityName objects:(NSArray *)dictionaries {
    return [[[self alloc] initWithEntityName:entityName objects:dictionaries] autorelease];
}
+ (instancetype)batchInsertRequestWithEntityName:(NSString *)entityName dictionaryHandler:(BOOL (^)(NSMutableDictionary<NSString *, id> *))handler {
    return [[[self alloc] initWithEntityName:entityName dictionaryHandler:handler] autorelease];
}
+ (instancetype)batchInsertRequestWithEntityName:(NSString *)entityName managedObjectHandler:(BOOL (^)(NSManagedObject *))handler {
    return [[[self alloc] initWithEntityName:entityName managedObjectHandler:handler] autorelease];
}
- (instancetype)init { return [self initWithEntityName:@"" objects:[NSArray array]]; }
- (instancetype)initWithEntityName:(NSString *)entityName objects:(NSArray *)dictionaries {
    self = [super init];
    if (self) {
        CDSet(self, @"requestType", [NSNumber numberWithUnsignedInteger:NSBatchInsertRequestType]);
        CDSet(self, @"entityName", [[entityName copy] autorelease]);
        self.objectsToInsert = dictionaries;
    }
    return self;
}
- (instancetype)initWithEntity:(NSEntityDescription *)entity objects:(NSArray *)dictionaries {
    self = [self initWithEntityName:entity.name objects:dictionaries];
    if (self) CDSet(self, @"entity", entity);
    return self;
}
- (instancetype)initWithEntity:(NSEntityDescription *)entity dictionaryHandler:(BOOL (^)(NSMutableDictionary<NSString *, id> *))handler {
    self = [self initWithEntity:entity objects:[NSArray array]];
    if (self) self.objectsToInsert = nil;
    if (self) self.dictionaryHandler = handler;
    return self;
}
- (instancetype)initWithEntity:(NSEntityDescription *)entity managedObjectHandler:(BOOL (^)(NSManagedObject *))handler {
    self = [self initWithEntity:entity objects:[NSArray array]];
    if (self) self.objectsToInsert = nil;
    if (self) self.managedObjectHandler = handler;
    return self;
}
- (instancetype)initWithEntityName:(NSString *)entityName dictionaryHandler:(BOOL (^)(NSMutableDictionary<NSString *, id> *))handler {
    self = [self initWithEntityName:entityName objects:[NSArray array]];
    if (self) self.objectsToInsert = nil;
    if (self) self.dictionaryHandler = handler;
    return self;
}
- (instancetype)initWithEntityName:(NSString *)entityName managedObjectHandler:(BOOL (^)(NSManagedObject *))handler {
    self = [self initWithEntityName:entityName objects:[NSArray array]];
    if (self) self.objectsToInsert = nil;
    if (self) self.managedObjectHandler = handler;
    return self;
}
- (NSPersistentStoreRequestType)requestType { return NSBatchInsertRequestType; }
- (NSString *)entityName { return CDGet(self, @"entityName"); }
- (NSEntityDescription *)entity {
    NSEntityDescription *entity = CDGet(self, @"entity");
    if (!entity)
        [NSException raise:NSObjectInaccessibleException format:@"This batch insert request (%p) was created with a string name (%@), and cannot respond to -entity until used by an NSManagedObjectContext",
         self, self.entityName];
    return entity;
}
- (NSArray *)objectsToInsert { return CDGet(self, @"objectsToInsert"); }
- (void)setObjectsToInsert:(NSArray *)objects { CDSet(self, @"objectsToInsert", [[objects copy] autorelease]); }
- (BOOL (^)(NSMutableDictionary<NSString *, id> *))dictionaryHandler { return CDGet(self, @"dictionaryHandler"); }
- (void)setDictionaryHandler:(BOOL (^)(NSMutableDictionary<NSString *, id> *))handler { CDSet(self, @"dictionaryHandler", [[handler copy] autorelease]); }
- (BOOL (^)(NSManagedObject *))managedObjectHandler { return CDGet(self, @"managedObjectHandler"); }
- (void)setManagedObjectHandler:(BOOL (^)(NSManagedObject *))handler { CDSet(self, @"managedObjectHandler", [[handler copy] autorelease]); }
- (NSBatchInsertRequestResultType)resultType { return [CDGet(self, @"resultType") unsignedIntegerValue]; }
- (void)setResultType:(NSBatchInsertRequestResultType)type { CDSet(self, @"resultType", [NSNumber numberWithUnsignedInteger:type]); }
- (NSString *)description {
    static NSString *const types[] = { @"NSBatchInsertRequestResultTypeStatusOnly", @"NSBatchInsertRequestResultTypeObjectIDs", @"NSBatchInsertRequestResultTypeCount" };
    NSUInteger type = self.resultType;
    return [NSString stringWithFormat:@"<NSBatchInsertRequest : entity = %@ resultType = %@ and %lu objects>", self.entityName,
            type < 3 ? types[type] : @"(unknown)", (unsigned long)self.objectsToInsert.count];
}
@end

// Inserts the request's objects through a context of its own, so the
// caller's context sees none of them until it fetches.
NSPersistentStoreResult *CDExecuteBatchInsert(NSPersistentStoreCoordinator *coordinator, NSBatchInsertRequest *request, NSError **error) {
    NSEntityDescription *entity = CDGet(request, @"entity") ?: [coordinator.managedObjectModel.entitiesByName objectForKey:request.entityName];
    if (!entity) return nil;
    CDSet(request, @"entity", entity);
    NSManagedObjectContext *context = [[[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType] autorelease];
    context.persistentStoreCoordinator = coordinator;
    NSMutableArray *inserted = [NSMutableArray array];
    BOOL (^insert)(NSDictionary *) = ^BOOL(NSDictionary *values) {
        for (NSString *key in values) {
            if (![entity.attributesByName objectForKey:key]) {
                CDReturnError(error, CDError(1605, [NSString stringWithFormat:@"%@ is not an attribute of %@.", key, entity.name]));
                return NO;
            }
        }
        NSManagedObject *object = CDNewObject(entity, context);
        for (NSString *key in values) {
            id value = [values objectForKey:key];
            [object setValue:value == [NSNull null] ? nil : value forKey:key];
        }
        [inserted addObject:object];
        return YES;
    };
    if (request.managedObjectHandler) {
        for (;;) {
            NSManagedObject *object = CDNewObject(entity, context);
            if (request.managedObjectHandler(object)) { [context deleteObject:object]; break; }
            [inserted addObject:object];
        }
    } else if (request.dictionaryHandler) {
        for (;;) {
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            if (request.dictionaryHandler(values)) break;
            if (!insert(values)) return nil;
        }
    } else {
        for (NSDictionary *values in request.objectsToInsert) if (!insert(values)) return nil;
    }
    if (inserted.count && ![context save:error]) return nil;
    NSBatchInsertResult *result = [[[NSBatchInsertResult alloc] init] autorelease];
    CDSet(result, @"resultType", [NSNumber numberWithUnsignedInteger:request.resultType]);
    id value = [NSNumber numberWithBool:YES];
    if (request.resultType == NSBatchInsertRequestResultTypeCount) value = [NSNumber numberWithUnsignedInteger:inserted.count];
    else if (request.resultType == NSBatchInsertRequestResultTypeObjectIDs) value = [inserted valueForKey:@"objectID"];
    CDSet(result, @"result", value);
    return result;
}

@implementation NSPersistentCloudKitContainerOptions
- (instancetype)initWithContainerIdentifier:(NSString *)containerIdentifier {
    self = [super init];
    if (self) {
        CDSet(self, @"containerIdentifier", [[containerIdentifier copy] autorelease]);
        CDSet(self, @"databaseScope", [NSNumber numberWithInteger:2]);
    }
    return self;
}
- (NSString *)containerIdentifier { return CDGet(self, @"containerIdentifier"); }
- (CKDatabaseScope)databaseScope { return (CKDatabaseScope)[CDGet(self, @"databaseScope") integerValue]; }
- (void)setDatabaseScope:(CKDatabaseScope)scope { CDSet(self, @"databaseScope", [NSNumber numberWithInteger:scope]); }
@end

@implementation NSPersistentCloudKitContainerEvent
- (id)copyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }
- (NSUUID *)identifier { return CDGet(self, @"identifier"); }
- (NSString *)storeIdentifier { return CDGet(self, @"storeIdentifier"); }
- (NSPersistentCloudKitContainerEventType)type { return [CDGet(self, @"type") integerValue]; }
- (NSDate *)startDate { return CDGet(self, @"startDate"); }
- (NSDate *)endDate { return CDGet(self, @"endDate"); }
- (BOOL)succeeded { return [CDGet(self, @"succeeded") boolValue]; }
- (NSError *)error { return CDGet(self, @"error"); }
@end

@implementation NSPersistentCloudKitContainerEventRequest
+ (instancetype)fetchEventsAfterDate:(NSDate *)date {
    NSPersistentCloudKitContainerEventRequest *request = [[[self alloc] init] autorelease];
    CDSet(request, @"afterDate", date);
    return request;
}
+ (instancetype)fetchEventsAfterEvent:(NSPersistentCloudKitContainerEvent *)event {
    NSPersistentCloudKitContainerEventRequest *request = [[[self alloc] init] autorelease];
    CDSet(request, @"afterEvent", event);
    return request;
}
+ (instancetype)fetchEventsMatchingFetchRequest:(NSFetchRequest *)fetchRequest {
    NSPersistentCloudKitContainerEventRequest *request = [[[self alloc] init] autorelease];
    CDSet(request, @"fetchRequest", fetchRequest);
    return request;
}
+ (NSFetchRequest *)fetchRequestForEvents { return [NSFetchRequest fetchRequestWithEntityName:@"NSPersistentCloudKitContainerEvent"]; }
- (NSPersistentStoreRequestType)requestType { return (NSPersistentStoreRequestType)11; }
- (NSPersistentCloudKitContainerEventResultType)resultType { return [CDGet(self, @"resultType") integerValue]; }
- (void)setResultType:(NSPersistentCloudKitContainerEventResultType)type { CDSet(self, @"resultType", [NSNumber numberWithInteger:type]); }
@end

@implementation NSPersistentCloudKitContainerEventResult
- (NSPersistentCloudKitContainerEventResultType)resultType { return [CDGet(self, @"resultType") integerValue]; }
- (id)result { return CDGet(self, @"result"); }
@end

// No mirroring runs, so there are never any events.
NSPersistentStoreResult *CDExecuteCloudKitEventRequest(NSPersistentCloudKitContainerEventRequest *request) {
    NSPersistentCloudKitContainerEventResult *result = [[(id)[NSPersistentCloudKitContainerEventResult alloc] init] autorelease];
    CDSet(result, @"resultType", [NSNumber numberWithInteger:request.resultType]);
    CDSet(result, @"result", request.resultType == NSPersistentCloudKitContainerEventResultTypeCountEvents
                             ? [NSArray arrayWithObject:[NSNumber numberWithInteger:0]] : [NSArray array]);
    return result;
}

@implementation NSPersistentCloudKitContainer
- (BOOL)initializeCloudKitSchemaWithOptions:(NSPersistentCloudKitContainerSchemaInitializationOptions)options error:(NSError **)error {
    (void)options;
    return CDReturnError(error, CDError(134060, @"A Core Data error occurred."));
}
- (CKRecord *)recordForManagedObjectID:(NSManagedObjectID *)managedObjectID { (void)managedObjectID; return nil; }
- (NSDictionary *)recordsForManagedObjectIDs:(NSArray *)managedObjectIDs { (void)managedObjectIDs; return [NSDictionary dictionary]; }
- (CKRecordID *)recordIDForManagedObjectID:(NSManagedObjectID *)managedObjectID { (void)managedObjectID; return nil; }
- (NSDictionary *)recordIDsForManagedObjectIDs:(NSArray *)managedObjectIDs { (void)managedObjectIDs; return [NSDictionary dictionary]; }
- (BOOL)canUpdateRecordForManagedObjectWithID:(NSManagedObjectID *)objectID { (void)objectID; return YES; }
- (BOOL)canDeleteRecordForManagedObjectWithID:(NSManagedObjectID *)objectID { (void)objectID; return YES; }
- (BOOL)canModifyManagedObjectsInStore:(NSPersistentStore *)store { return !store.isReadOnly; }
- (void)acceptShareInvitationsFromMetadata:(NSArray *)metadata intoPersistentStore:(NSPersistentStore *)persistentStore
                                completion:(void (^)(NSArray *, NSError *))completion {
    (void)metadata; (void)persistentStore;
    if (completion) completion(nil, CDError(134400, @"CloudKit sharing is not available."));
}
- (void)purgeObjectsAndRecordsInZoneWithID:(CKRecordZoneID *)zoneID inPersistentStore:(NSPersistentStore *)persistentStore
                                completion:(void (^)(CKRecordZoneID *, NSError *))completion {
    (void)persistentStore;
    if (completion) completion(zoneID, CDError(134400, @"CloudKit sharing is not available."));
}
- (void)persistUpdatedShare:(CKShare *)share inPersistentStore:(NSPersistentStore *)persistentStore
                 completion:(void (^)(CKShare *, NSError *))completion {
    (void)persistentStore;
    if (completion) completion(share, CDError(134400, @"CloudKit sharing is not available."));
}
- (void)fetchParticipantsMatchingLookupInfos:(NSArray *)lookupInfos intoPersistentStore:(NSPersistentStore *)persistentStore
                                  completion:(void (^)(NSArray *, NSError *))completion {
    (void)lookupInfos; (void)persistentStore;
    if (completion) completion(nil, CDError(134400, @"CloudKit sharing is not available."));
}
- (NSDictionary *)fetchSharesMatchingObjectIDs:(NSArray *)objectIDs error:(NSError **)error {
    (void)objectIDs; (void)error;
    return [NSDictionary dictionary];
}
- (NSArray *)fetchSharesInPersistentStore:(NSPersistentStore *)persistentStore error:(NSError **)error {
    (void)persistentStore; (void)error;
    return [NSArray array];
}
- (void)shareManagedObjects:(NSArray *)managedObjects toShare:(CKShare *)share
                 completion:(void (^)(NSSet *, CKShare *, CKContainer *, NSError *))completion {
    (void)managedObjects;
    if (completion) completion(nil, share, nil, CDError(134400, @"CloudKit sharing is not available."));
}
@end

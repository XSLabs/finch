// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CloudKitInternal.h"
#import <objc/message.h>

static char CKSyncEngineConfigurationKey;
static char CKSyncEngineStateSerializationKey;

static NSData *CKStateData(CKSyncEngineState *state)
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    values[@"recordIDs"] = [state.pendingRecordZoneChanges valueForKey:@"recordID"] ?: @[];
    values[@"recordChangeTypes"] = [state.pendingRecordZoneChanges valueForKey:@"type"] ?: @[];
    NSMutableArray *zoneIDs = [NSMutableArray array];
    NSMutableArray *databaseTypes = [NSMutableArray array];
    for (CKSyncEnginePendingDatabaseChange *change in state.pendingDatabaseChanges) {
        [zoneIDs addObject:change.zoneID];
        [databaseTypes addObject:@(change.type)];
    }
    values[@"databaseZoneIDs"] = zoneIDs;
    values[@"databaseChangeTypes"] = databaseTypes;
    values[@"hasPendingUntrackedChanges"] = @(state.hasPendingUntrackedChanges);
    values[@"unfetchedZoneIDs"] = state.zoneIDsWithUnfetchedServerChanges ?: @[];
    return [NSKeyedArchiver archivedDataWithRootObject:values requiringSecureCoding:YES error:NULL];
}

static id CKSyncNewObject(Class cls)
{
    return ((id (*)(id, SEL))objc_msgSend)([cls alloc], @selector(init));
}

static id CKSyncNSObjectInit(id object)
{
    IMP initializer = class_getMethodImplementation([NSObject class], @selector(init));
    return ((id (*)(id, SEL))initializer)(object, @selector(init));
}

static id CKCopyImmutableSet(NSSet *set)
{
    return [[set copy] autorelease];
}

@implementation CKSyncEngineConfiguration (Finch)

- (instancetype)initWithDatabase:(CKDatabase *)database stateSerialization:(CKSyncEngineStateSerialization *)stateSerialization delegate:(id<CKSyncEngineDelegate>)delegate
{
    if (![database isKindOfClass:[CKDatabase class]] || !delegate)
        [NSException raise:NSInvalidArgumentException format:@"A database and sync delegate are required"];
    self = CKSyncNSObjectInit(self);
    if (self) {
        self.database = database;
        self.stateSerialization = stateSerialization;
        self.delegate = delegate;
        self.automaticallySync = YES;
    }
    return self;
}

@end

@implementation CKSyncEngineStateSerialization (Finch)

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = CKSyncNSObjectInit(self);
    if (self) objc_setAssociatedObject(self, &CKSyncEngineStateSerializationKey,
        [coder decodeObjectOfClass:[NSData class] forKey:@"state"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:objc_getAssociatedObject(self, &CKSyncEngineStateSerializationKey) forKey:@"state"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSyncEngineStateSerialization *copy = CKSyncNewObject([CKSyncEngineStateSerialization class]);
    objc_setAssociatedObject(copy, &CKSyncEngineStateSerializationKey,
        objc_getAssociatedObject(self, &CKSyncEngineStateSerializationKey), OBJC_ASSOCIATION_COPY_NONATOMIC);
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKSyncEngineState (Finch)

- (instancetype)_initWithSerialization:(CKSyncEngineStateSerialization *)serialization
{
    self = [super init];
    if (self) {
        [self setValue:@[] forKey:@"pendingRecordZoneChanges"];
        [self setValue:@[] forKey:@"pendingDatabaseChanges"];
        [self setValue:@[] forKey:@"zoneIDsWithUnfetchedServerChanges"];
        NSData *data = objc_getAssociatedObject(serialization, &CKSyncEngineStateSerializationKey);
        if (data.length) {
            NSDictionary *saved = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [CKRecordID class], [CKRecordZoneID class], nil]
                fromData:data error:NULL];
            NSArray *recordIDs = saved[@"recordIDs"];
            NSArray *types = saved[@"recordChangeTypes"];
            NSMutableArray *records = [NSMutableArray array];
            for (NSUInteger index = 0; index < MIN(recordIDs.count, types.count); index++) {
                [records addObject:[[[CKSyncEnginePendingRecordZoneChange alloc] initWithRecordID:recordIDs[index] type:[types[index] integerValue]] autorelease]];
            }
            [self setValue:records forKey:@"pendingRecordZoneChanges"];
            NSArray *databaseZoneIDs = saved[@"databaseZoneIDs"];
            NSArray *databaseTypes = saved[@"databaseChangeTypes"];
            NSMutableArray *databaseChanges = [NSMutableArray array];
            for (NSUInteger index = 0; index < MIN(databaseZoneIDs.count, databaseTypes.count); index++) {
                CKRecordZoneID *zoneID = databaseZoneIDs[index];
                if ([databaseTypes[index] integerValue] == CKSyncEnginePendingDatabaseChangeTypeDeleteZone) {
                    [databaseChanges addObject:[[[CKSyncEnginePendingZoneDelete alloc] initWithZoneID:zoneID] autorelease]];
                } else {
                    CKRecordZone *zone = [[[CKRecordZone alloc] initWithZoneID:zoneID] autorelease];
                    [databaseChanges addObject:[[[CKSyncEnginePendingZoneSave alloc] initWithZone:zone] autorelease]];
                }
            }
            [self setValue:databaseChanges forKey:@"pendingDatabaseChanges"];
            [self setValue:saved[@"hasPendingUntrackedChanges"] ?: @NO forKey:@"hasPendingUntrackedChanges"];
            [self setValue:saved[@"unfetchedZoneIDs"] ?: @[] forKey:@"zoneIDsWithUnfetchedServerChanges"];
        }
    }
    return self;
}

- (void)addPendingRecordZoneChanges:(NSArray<CKSyncEnginePendingRecordZoneChange *> *)changes
{
    NSMutableArray *current = [NSMutableArray arrayWithArray:self.pendingRecordZoneChanges ?: @[]];
    for (CKSyncEnginePendingRecordZoneChange *change in changes) {
        if (![change isKindOfClass:[CKSyncEnginePendingRecordZoneChange class]])
            [NSException raise:NSInvalidArgumentException format:@"Pending changes must be CloudKit record changes"];
        NSIndexSet *matches = [current indexesOfObjectsPassingTest:^BOOL(CKSyncEnginePendingRecordZoneChange *existing, NSUInteger index, BOOL *stop) {
            return [existing.recordID isEqual:change.recordID];
        }];
        [current removeObjectsAtIndexes:matches];
        [current addObject:change];
    }
    [self setValue:current forKey:@"pendingRecordZoneChanges"];
}

- (void)removePendingRecordZoneChanges:(NSArray<CKSyncEnginePendingRecordZoneChange *> *)changes
{
    NSMutableArray *current = [NSMutableArray arrayWithArray:self.pendingRecordZoneChanges ?: @[]];
    for (CKSyncEnginePendingRecordZoneChange *change in changes) {
        NSIndexSet *matches = [current indexesOfObjectsPassingTest:^BOOL(CKSyncEnginePendingRecordZoneChange *existing, NSUInteger index, BOOL *stop) {
            return [existing.recordID isEqual:change.recordID] && existing.type == change.type;
        }];
        [current removeObjectsAtIndexes:matches];
    }
    [self setValue:current forKey:@"pendingRecordZoneChanges"];
}

- (void)addPendingDatabaseChanges:(NSArray<CKSyncEnginePendingDatabaseChange *> *)changes
{
    NSMutableArray *current = [NSMutableArray arrayWithArray:self.pendingDatabaseChanges ?: @[]];
    for (CKSyncEnginePendingDatabaseChange *change in changes) {
        if (![change isKindOfClass:[CKSyncEnginePendingDatabaseChange class]])
            [NSException raise:NSInvalidArgumentException format:@"Pending changes must be CloudKit database changes"];
        NSIndexSet *matches = [current indexesOfObjectsPassingTest:^BOOL(CKSyncEnginePendingDatabaseChange *existing, NSUInteger index, BOOL *stop) {
            return [existing.zoneID isEqual:change.zoneID];
        }];
        [current removeObjectsAtIndexes:matches];
        [current addObject:change];
    }
    [self setValue:current forKey:@"pendingDatabaseChanges"];
}

- (void)removePendingDatabaseChanges:(NSArray<CKSyncEnginePendingDatabaseChange *> *)changes
{
    NSMutableArray *current = [NSMutableArray arrayWithArray:self.pendingDatabaseChanges ?: @[]];
    for (CKSyncEnginePendingDatabaseChange *change in changes) {
        NSIndexSet *matches = [current indexesOfObjectsPassingTest:^BOOL(CKSyncEnginePendingDatabaseChange *existing, NSUInteger index, BOOL *stop) {
            return [existing.zoneID isEqual:change.zoneID] && existing.type == change.type;
        }];
        [current removeObjectsAtIndexes:matches];
    }
    [self setValue:current forKey:@"pendingDatabaseChanges"];
}

- (CKSyncEngineStateSerialization *)_serialization
{
    CKSyncEngineStateSerialization *serialization = CKSyncNewObject([CKSyncEngineStateSerialization class]);
    objc_setAssociatedObject(serialization, &CKSyncEngineStateSerializationKey, CKStateData(self), OBJC_ASSOCIATION_COPY_NONATOMIC);
    return [serialization autorelease];
}

@end

@implementation CKSyncEnginePendingRecordZoneChange (Finch)

- (instancetype)initWithRecordID:(CKRecordID *)recordID type:(CKSyncEnginePendingRecordZoneChangeType)type
{
    if (![recordID isKindOfClass:[CKRecordID class]] || (type != CKSyncEnginePendingRecordZoneChangeTypeSaveRecord && type != CKSyncEnginePendingRecordZoneChangeTypeDeleteRecord))
        [NSException raise:NSInvalidArgumentException format:@"A record identifier and valid change type are required"];
    self = [super init];
    if (self) {
        [self setValue:recordID forKey:@"recordID"];
        [self setValue:@(type) forKey:@"type"];
    }
    return self;
}

@end

@implementation CKSyncEnginePendingZoneSave (Finch)

- (instancetype)initWithZone:(CKRecordZone *)zone
{
    if (![zone isKindOfClass:[CKRecordZone class]])
        [NSException raise:NSInvalidArgumentException format:@"A record zone is required"];
    self = CKSyncNSObjectInit(self);
    if (self) {
        [self setValue:zone.zoneID forKey:@"zoneID"];
        [self setValue:@(CKSyncEnginePendingDatabaseChangeTypeSaveZone) forKey:@"type"];
        [self setValue:zone forKey:@"zone"];
    }
    return self;
}

@end

@implementation CKSyncEnginePendingZoneDelete (Finch)

- (instancetype)initWithZoneID:(CKRecordZoneID *)zoneID
{
    if (![zoneID isKindOfClass:[CKRecordZoneID class]])
        [NSException raise:NSInvalidArgumentException format:@"A record zone identifier is required"];
    self = CKSyncNSObjectInit(self);
    if (self) {
        [self setValue:zoneID forKey:@"zoneID"];
        [self setValue:@(CKSyncEnginePendingDatabaseChangeTypeDeleteZone) forKey:@"type"];
    }
    return self;
}

@end

@implementation CKSyncEngineFetchChangesScope (Finch)

- (instancetype)initWithZoneIDs:(NSSet<CKRecordZoneID *> *)zoneIDs
{
    self = [super init];
    if (self) [self setValue:CKCopyImmutableSet(zoneIDs) forKey:@"zoneIDs"];
    return self;
}

- (instancetype)initWithExcludedZoneIDs:(NSSet<CKRecordZoneID *> *)zoneIDs
{
    self = [super init];
    if (self) [self setValue:CKCopyImmutableSet(zoneIDs) forKey:@"excludedZoneIDs"];
    return self;
}

- (BOOL)containsZoneID:(CKRecordZoneID *)zoneID
{
    return zoneID && (!self.zoneIDs || [self.zoneIDs containsObject:zoneID]) && ![self.excludedZoneIDs containsObject:zoneID];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSyncEngineFetchChangesScope *copy = self.zoneIDs ? [[CKSyncEngineFetchChangesScope allocWithZone:zone] initWithZoneIDs:self.zoneIDs]
        : [[CKSyncEngineFetchChangesScope allocWithZone:zone] initWithExcludedZoneIDs:self.excludedZoneIDs];
    return copy;
}

@end

@implementation CKSyncEngineSendChangesScope (Finch)

- (instancetype)initWithZoneIDs:(NSSet<CKRecordZoneID *> *)zoneIDs
{
    self = [super init];
    if (self) [self setValue:CKCopyImmutableSet(zoneIDs) forKey:@"zoneIDs"];
    return self;
}

- (instancetype)initWithExcludedZoneIDs:(NSSet<CKRecordZoneID *> *)zoneIDs
{
    self = [super init];
    if (self) [self setValue:CKCopyImmutableSet(zoneIDs) forKey:@"excludedZoneIDs"];
    return self;
}

- (instancetype)initWithRecordIDs:(NSSet<CKRecordID *> *)recordIDs
{
    self = [super init];
    if (self) [self setValue:CKCopyImmutableSet(recordIDs) forKey:@"recordIDs"];
    return self;
}

- (BOOL)containsRecordID:(CKRecordID *)recordID
{
    if (!recordID) return NO;
    if (self.recordIDs) return [self.recordIDs containsObject:recordID];
    return (!self.zoneIDs || [self.zoneIDs containsObject:recordID.zoneID]) && ![self.excludedZoneIDs containsObject:recordID.zoneID];
}

- (BOOL)containsPendingRecordZoneChange:(CKSyncEnginePendingRecordZoneChange *)change
{
    return change && [self containsRecordID:change.recordID];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSyncEngineSendChangesScope *copy = self.recordIDs ? [[CKSyncEngineSendChangesScope allocWithZone:zone] initWithRecordIDs:self.recordIDs]
        : (self.zoneIDs ? [[CKSyncEngineSendChangesScope allocWithZone:zone] initWithZoneIDs:self.zoneIDs]
                        : [[CKSyncEngineSendChangesScope allocWithZone:zone] initWithExcludedZoneIDs:self.excludedZoneIDs]);
    return copy;
}

@end

@implementation CKSyncEngineFetchChangesOptions (Finch)

- (instancetype)initWithScope:(CKSyncEngineFetchChangesScope *)scope
{
    self = [super init];
    if (self) { self.scope = scope; self.prioritizedZoneIDs = @[]; }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSyncEngineFetchChangesOptions *copy = [[CKSyncEngineFetchChangesOptions allocWithZone:zone] initWithScope:self.scope];
    copy.operationGroup = self.operationGroup;
    copy.prioritizedZoneIDs = self.prioritizedZoneIDs;
    return copy;
}

@end

@implementation CKSyncEngineSendChangesOptions (Finch)

- (instancetype)initWithScope:(CKSyncEngineSendChangesScope *)scope
{
    self = [super init];
    if (self) self.scope = scope;
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSyncEngineSendChangesOptions *copy = [[CKSyncEngineSendChangesOptions allocWithZone:zone] initWithScope:self.scope];
    copy.operationGroup = self.operationGroup;
    return copy;
}

@end

@implementation CKSyncEngine (Finch)

- (instancetype)initWithConfiguration:(CKSyncEngineConfiguration *)configuration
{
    if (![configuration isKindOfClass:[CKSyncEngineConfiguration class]])
        [NSException raise:NSInvalidArgumentException format:@"A sync engine configuration is required"];
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &CKSyncEngineConfigurationKey, configuration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self setValue:configuration.database forKey:@"database"];
        CKSyncEngineState *state = CKSyncNewObject([CKSyncEngineState class]);
        state = [state _initWithSerialization:configuration.stateSerialization];
        [self setValue:[state autorelease] forKey:@"state"];
    }
    return self;
}

- (void)fetchChangesWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(error); });
}

- (void)fetchChangesWithOptions:(CKSyncEngineFetchChangesOptions *)options completionHandler:(void (^)(NSError *))completionHandler
{
    [self fetchChangesWithCompletionHandler:completionHandler];
}

- (void)sendChangesWithCompletionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(error); });
}

- (void)sendChangesWithOptions:(CKSyncEngineSendChangesOptions *)options completionHandler:(void (^)(NSError *))completionHandler
{
    [self sendChangesWithCompletionHandler:completionHandler];
}

- (void)cancelOperationsWithCompletionHandler:(void (^)(void))completionHandler
{
    CKPerformAsync(^{ if (completionHandler) completionHandler(); });
}

@end

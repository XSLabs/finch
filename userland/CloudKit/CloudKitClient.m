// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CloudKitInternal.h"

static char CKDatabaseContainerKey;
static char CKDatabaseQueueKey;
static char CKContainerQueueKey;
static char CKContainerPrivateDatabaseKey;
static char CKContainerPublicDatabaseKey;
static char CKContainerSharedDatabaseKey;

NSError *CKNoAccountError(void)
{
    return [NSError errorWithDomain:CKErrorDomain code:CKErrorNotAuthenticated
        userInfo:[NSDictionary dictionaryWithObject:@"Not authenticated" forKey:NSLocalizedDescriptionKey]];
}

void CKPerformAsync(dispatch_block_t block)
{
    if (block)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), block);
}

static NSOperationQueue *CKQueueForObject(id object, const void *key)
{
    NSOperationQueue *queue = objc_getAssociatedObject(object, key);
    if (!queue) {
        queue = [[NSOperationQueue alloc] init];
        objc_setAssociatedObject(object, key, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [queue release];
        queue = objc_getAssociatedObject(object, key);
    }
    return queue;
}

@implementation CKContainer (Finch)

+ (instancetype)defaultContainer
{
    static CKContainer *container = nil;
    if (!container)
        container = [[self alloc] _initWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
    return container;
}

+ (instancetype)containerWithIdentifier:(NSString *)containerIdentifier
{
    if (![containerIdentifier isKindOfClass:[NSString class]] || containerIdentifier.length == 0)
        [NSException raise:NSInvalidArgumentException format:@"A container identifier is required"];
    static NSMutableDictionary *containers = nil;
    @synchronized(self) {
        if (!containers)
            containers = [[NSMutableDictionary alloc] init];
        CKContainer *container = [containers objectForKey:containerIdentifier];
        if (!container) {
            container = [[self alloc] _initWithIdentifier:containerIdentifier];
            [containers setObject:container forKey:containerIdentifier];
            [container release];
        }
        return container;
    }
}

- (instancetype)_initWithIdentifier:(NSString *)identifier
{
    self = [super init];
    if (self)
        [self setValue:identifier forKey:@"containerIdentifier"];
    return self;
}

- (CKDatabase *)_databaseWithScope:(CKDatabaseScope)scope
{
    const void *key = scope == CKDatabaseScopePublic ? &CKContainerPublicDatabaseKey :
        (scope == CKDatabaseScopeShared ? &CKContainerSharedDatabaseKey : &CKContainerPrivateDatabaseKey);
    CKDatabase *database = objc_getAssociatedObject(self, key);
    if (!database) {
        database = [[CKDatabase alloc] _initWithContainer:self scope:scope];
        objc_setAssociatedObject(self, key, database, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [database release];
        database = objc_getAssociatedObject(self, key);
    }
    return database;
}

- (CKDatabase *)privateCloudDatabase { return [self _databaseWithScope:CKDatabaseScopePrivate]; }
- (CKDatabase *)publicCloudDatabase { return [self _databaseWithScope:CKDatabaseScopePublic]; }
- (CKDatabase *)sharedCloudDatabase { return [self _databaseWithScope:CKDatabaseScopeShared]; }

- (CKDatabase *)databaseWithDatabaseScope:(CKDatabaseScope)scope
{
    if (scope < CKDatabaseScopePublic || scope > CKDatabaseScopeShared)
        [NSException raise:NSInvalidArgumentException format:@"Unknown database scope"];
    return [self _databaseWithScope:scope];
}

- (void)addOperation:(CKOperation *)operation
{
    if (![operation isKindOfClass:[CKOperation class]])
        [NSException raise:NSInvalidArgumentException format:@"A CloudKit operation is required"];
    operation.configuration.container = self;
    [CKQueueForObject(self, &CKContainerQueueKey) addOperation:operation];
}

- (void)accountStatusWithCompletionHandler:(void (^)(CKAccountStatus, NSError *))completionHandler
{
    CKPerformAsync(^{ if (completionHandler) completionHandler(CKAccountStatusNoAccount, nil); });
}

- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(CKRecordID *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)discoverAllIdentitiesWithCompletionHandler:(void (^)(NSArray<CKUserIdentity *> *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)discoverUserIdentityWithEmailAddress:(NSString *)email completionHandler:(void (^)(CKUserIdentity *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)discoverUserIdentityWithPhoneNumber:(NSString *)phoneNumber completionHandler:(void (^)(CKUserIdentity *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)discoverUserIdentityWithUserRecordID:(CKRecordID *)userRecordID completionHandler:(void (^)(CKUserIdentity *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchShareParticipantWithEmailAddress:(NSString *)emailAddress completionHandler:(void (^)(CKShareParticipant *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchShareParticipantWithPhoneNumber:(NSString *)phoneNumber completionHandler:(void (^)(CKShareParticipant *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchShareParticipantWithUserRecordID:(CKRecordID *)userRecordID completionHandler:(void (^)(CKShareParticipant *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchShareMetadataWithURL:(NSURL *)url completionHandler:(void (^)(CKShareMetadata *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)acceptShareMetadata:(CKShareMetadata *)metadata completionHandler:(void (^)(CKShare *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchAllLongLivedOperationIDsWithCompletionHandler:(void (^)(NSArray<CKOperationID> *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchLongLivedOperationWithID:(CKOperationID)operationID completionHandler:(void (^)(CKOperation *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)statusForApplicationPermission:(CKApplicationPermissions)applicationPermission completionHandler:(CKApplicationPermissionBlock)completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(CKApplicationPermissionStatusInitialState, error); });
}

- (void)requestApplicationPermission:(CKApplicationPermissions)applicationPermission completionHandler:(CKApplicationPermissionBlock)completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(CKApplicationPermissionStatusInitialState, error); });
}

@end

@implementation CKDatabase (Finch)

- (instancetype)_initWithContainer:(CKContainer *)container scope:(CKDatabaseScope)scope
{
    self = [super init];
    if (self) {
        [self setValue:@(scope) forKey:@"databaseScope"];
        objc_setAssociatedObject(self, &CKDatabaseContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (void)addOperation:(CKDatabaseOperation *)operation
{
    if (![operation isKindOfClass:[CKDatabaseOperation class]])
        [NSException raise:NSInvalidArgumentException format:@"A database operation is required"];
    operation.database = self;
    [CKQueueForObject(self, &CKDatabaseQueueKey) addOperation:operation];
}

- (NSError *)_unavailableError
{
    if (self.databaseScope == CKDatabaseScopePublic)
        return [NSError errorWithDomain:CKErrorDomain code:CKErrorNetworkUnavailable
            userInfo:[NSDictionary dictionaryWithObject:@"Network unavailable" forKey:NSLocalizedDescriptionKey]];
    return CKNoAccountError();
}

- (void)fetchRecordWithID:(CKRecordID *)recordID completionHandler:(void (^)(CKRecord *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)saveRecord:(CKRecord *)record completionHandler:(void (^)(CKRecord *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)deleteRecordWithID:(CKRecordID *)recordID completionHandler:(void (^)(CKRecordID *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)performQuery:(CKQuery *)query inZoneWithID:(CKRecordZoneID *)zoneID completionHandler:(void (^)(NSArray<CKRecord *> *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchAllRecordZonesWithCompletionHandler:(void (^)(NSArray<CKRecordZone *> *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchRecordZoneWithID:(CKRecordZoneID *)zoneID completionHandler:(void (^)(CKRecordZone *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)saveRecordZone:(CKRecordZone *)zone completionHandler:(void (^)(CKRecordZone *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)deleteRecordZoneWithID:(CKRecordZoneID *)zoneID completionHandler:(void (^)(CKRecordZoneID *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchSubscriptionWithID:(CKSubscriptionID)subscriptionID completionHandler:(void (^)(CKSubscription *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)fetchAllSubscriptionsWithCompletionHandler:(void (^)(NSArray<CKSubscription *> *, NSError *))completionHandler
{
    NSError *error = [self _unavailableError];
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)saveSubscription:(CKSubscription *)subscription completionHandler:(void (^)(CKSubscription *, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

- (void)deleteSubscriptionWithID:(CKSubscriptionID)subscriptionID completionHandler:(void (^)(CKSubscriptionID, NSError *))completionHandler
{
    NSError *error = CKNoAccountError();
    CKPerformAsync(^{ if (completionHandler) completionHandler(nil, error); });
}

@end

// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CloudKitInternal.h"

static char CKOperationConfigurationKey;
static char CKOperationGroupConfigurationKey;
static char CKFetchCurrentUserRecordKey;

static NSString *CKShortIdentifier(void)
{
    NSString *uuid = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [uuid substringToIndex:16];
}

static void CKFinishOperation(CKOperation *operation)
{
    NSError *error = CKNoAccountError();
    if ([operation isKindOfClass:[CKModifyRecordsOperation class]]) {
        CKModifyRecordsOperation *modify = (id)operation;
        for (CKRecord *record in modify.recordsToSave)
            if (modify.perRecordSaveBlock) modify.perRecordSaveBlock(record.recordID, nil, error);
        for (CKRecordID *recordID in modify.recordIDsToDelete)
            if (modify.perRecordDeleteBlock) modify.perRecordDeleteBlock(recordID, error);
        if (modify.modifyRecordsCompletionBlock) modify.modifyRecordsCompletionBlock(nil, nil, error);
    } else if ([operation isKindOfClass:[CKFetchRecordsOperation class]]) {
        CKFetchRecordsOperation *fetch = (id)operation;
        for (CKRecordID *recordID in fetch.recordIDs)
            if (fetch.perRecordCompletionBlock) fetch.perRecordCompletionBlock(nil, recordID, error);
        if (fetch.fetchRecordsCompletionBlock) fetch.fetchRecordsCompletionBlock(nil, error);
    } else if ([operation isKindOfClass:[CKModifyRecordZonesOperation class]]) {
        CKModifyRecordZonesOperation *modify = (id)operation;
        for (CKRecordZone *zone in modify.recordZonesToSave)
            if (modify.perRecordZoneSaveBlock) modify.perRecordZoneSaveBlock(zone.zoneID, nil, error);
        for (CKRecordZoneID *zoneID in modify.recordZoneIDsToDelete)
            if (modify.perRecordZoneDeleteBlock) modify.perRecordZoneDeleteBlock(zoneID, error);
        if (modify.modifyRecordZonesCompletionBlock) modify.modifyRecordZonesCompletionBlock(nil, nil, error);
    } else if ([operation isKindOfClass:[CKFetchRecordZonesOperation class]]) {
        CKFetchRecordZonesOperation *fetch = (id)operation;
        for (CKRecordZoneID *zoneID in fetch.recordZoneIDs)
            if (fetch.perRecordZoneCompletionBlock) fetch.perRecordZoneCompletionBlock(zoneID, nil, error);
        if (fetch.fetchRecordZonesCompletionBlock) fetch.fetchRecordZonesCompletionBlock(nil, error);
    } else if ([operation isKindOfClass:[CKModifySubscriptionsOperation class]]) {
        CKModifySubscriptionsOperation *modify = (id)operation;
        for (CKSubscription *subscription in modify.subscriptionsToSave)
            if (modify.perSubscriptionSaveBlock) modify.perSubscriptionSaveBlock(subscription.subscriptionID, nil, error);
        for (CKSubscriptionID subscriptionID in modify.subscriptionIDsToDelete)
            if (modify.perSubscriptionDeleteBlock) modify.perSubscriptionDeleteBlock(subscriptionID, error);
        if (modify.modifySubscriptionsCompletionBlock) modify.modifySubscriptionsCompletionBlock(nil, nil, error);
    } else if ([operation isKindOfClass:[CKFetchSubscriptionsOperation class]]) {
        CKFetchSubscriptionsOperation *fetch = (id)operation;
        for (CKSubscriptionID subscriptionID in fetch.subscriptionIDs)
            if (fetch.perSubscriptionCompletionBlock) fetch.perSubscriptionCompletionBlock(subscriptionID, nil, error);
        if (fetch.fetchSubscriptionCompletionBlock) fetch.fetchSubscriptionCompletionBlock(nil, error);
    } else if ([operation isKindOfClass:[CKFetchDatabaseChangesOperation class]]) {
        CKFetchDatabaseChangesOperation *fetch = (id)operation;
        if (fetch.fetchDatabaseChangesCompletionBlock) fetch.fetchDatabaseChangesCompletionBlock(nil, NO, error);
    } else if ([operation isKindOfClass:[CKFetchRecordZoneChangesOperation class]]) {
        CKFetchRecordZoneChangesOperation *fetch = (id)operation;
        if (fetch.fetchRecordZoneChangesCompletionBlock) fetch.fetchRecordZoneChangesCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKQueryOperation class]]) {
        CKQueryOperation *query = (id)operation;
        if (query.queryCompletionBlock) query.queryCompletionBlock(nil, error);
    } else if ([operation isKindOfClass:[CKAcceptSharesOperation class]]) {
        CKAcceptSharesOperation *accept = (id)operation;
        for (CKShareMetadata *metadata in accept.shareMetadatas)
            if (accept.perShareCompletionBlock) accept.perShareCompletionBlock(metadata, nil, error);
        if (accept.acceptSharesCompletionBlock) accept.acceptSharesCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKDiscoverUserIdentitiesOperation class]]) {
        CKDiscoverUserIdentitiesOperation *discover = (id)operation;
        if (discover.discoverUserIdentitiesCompletionBlock) discover.discoverUserIdentitiesCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKDiscoverAllUserIdentitiesOperation class]]) {
        CKDiscoverAllUserIdentitiesOperation *discover = (id)operation;
        if (discover.discoverAllUserIdentitiesCompletionBlock) discover.discoverAllUserIdentitiesCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKFetchShareMetadataOperation class]]) {
        CKFetchShareMetadataOperation *fetch = (id)operation;
        for (NSURL *url in fetch.shareURLs)
            if (fetch.perShareMetadataBlock) fetch.perShareMetadataBlock(url, nil, error);
        if (fetch.fetchShareMetadataCompletionBlock) fetch.fetchShareMetadataCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKFetchShareParticipantsOperation class]]) {
        CKFetchShareParticipantsOperation *fetch = (id)operation;
        for (CKUserIdentityLookupInfo *lookup in fetch.userIdentityLookupInfos)
            if (fetch.perShareParticipantCompletionBlock) fetch.perShareParticipantCompletionBlock(lookup, nil, error);
        if (fetch.fetchShareParticipantsCompletionBlock) fetch.fetchShareParticipantsCompletionBlock(error);
    } else if ([operation isKindOfClass:[CKFetchWebAuthTokenOperation class]]) {
        CKFetchWebAuthTokenOperation *fetch = (id)operation;
        if (fetch.fetchWebAuthTokenCompletionBlock) fetch.fetchWebAuthTokenCompletionBlock(nil, error);
    }
}

@implementation CKOperationConfiguration (Finch)

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.qualityOfService = NSQualityOfServiceDefault;
        self.allowsCellularAccess = YES;
        self.longLived = NO;
        self.timeoutIntervalForRequest = 60.0;
        self.timeoutIntervalForResource = -1.0;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    CKOperationConfiguration *copy = [[CKOperationConfiguration allocWithZone:zone] init];
    copy.container = self.container;
    copy.qualityOfService = self.qualityOfService;
    copy.allowsCellularAccess = self.allowsCellularAccess;
    copy.longLived = self.longLived;
    copy.timeoutIntervalForRequest = self.timeoutIntervalForRequest;
    copy.timeoutIntervalForResource = self.timeoutIntervalForResource;
    return copy;
}

@end

@implementation CKOperationGroup (Finch)

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setValue:CKShortIdentifier() forKey:@"operationGroupID"];
        [self setValue:[[[CKOperationConfiguration alloc] init] autorelease] forKey:@"defaultConfiguration"];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (self) {
        NSString *identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"operationGroupID"];
        NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
        CKOperationConfiguration *configuration = [coder decodeObjectOfClass:[CKOperationConfiguration class] forKey:@"defaultConfiguration"];
        [self setValue:identifier forKey:@"operationGroupID"];
        self.name = name;
        self.defaultConfiguration = configuration;
        self.quantity = [coder decodeIntegerForKey:@"quantity"];
        self.expectedSendSize = [coder decodeIntegerForKey:@"expectedSendSize"];
        self.expectedReceiveSize = [coder decodeIntegerForKey:@"expectedReceiveSize"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.operationGroupID forKey:@"operationGroupID"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.defaultConfiguration forKey:@"defaultConfiguration"];
    [coder encodeInteger:self.quantity forKey:@"quantity"];
    [coder encodeInteger:self.expectedSendSize forKey:@"expectedSendSize"];
    [coder encodeInteger:self.expectedReceiveSize forKey:@"expectedReceiveSize"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKOperationGroup *copy = [[CKOperationGroup allocWithZone:zone] init];
    [copy setValue:self.operationGroupID forKey:@"operationGroupID"];
    copy.name = self.name;
    copy.defaultConfiguration = self.defaultConfiguration;
    copy.quantity = self.quantity;
    copy.expectedSendSize = self.expectedSendSize;
    copy.expectedReceiveSize = self.expectedReceiveSize;
    return copy;
}

- (CKOperationConfiguration *)defaultConfiguration
{
    CKOperationConfiguration *configuration = objc_getAssociatedObject(self, &CKOperationGroupConfigurationKey);
    if (!configuration) {
        configuration = [[[CKOperationConfiguration alloc] init] autorelease];
        objc_setAssociatedObject(self, &CKOperationGroupConfigurationKey, configuration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return configuration;
}

- (void)setDefaultConfiguration:(CKOperationConfiguration *)configuration
{
    if (!configuration)
        configuration = [[[CKOperationConfiguration alloc] init] autorelease];
    CKOperationConfiguration *copy = [configuration copy];
    objc_setAssociatedObject(self, &CKOperationGroupConfigurationKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [copy release];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKAllowedSharingOptions (Finch)

- (instancetype)initWithAllowedParticipantPermissionOptions:(CKSharingParticipantPermissionOption)permissionOptions
                                  allowedParticipantAccessOptions:(CKSharingParticipantAccessOption)accessOptions
{
    self = [super init];
    if (self) {
        self.allowedParticipantPermissionOptions = permissionOptions;
        self.allowedParticipantAccessOptions = accessOptions;
    }
    return self;
}

+ (instancetype)standardOptions
{
    return [[[self alloc] initWithAllowedParticipantPermissionOptions:CKSharingParticipantPermissionOptionAny
        allowedParticipantAccessOptions:CKSharingParticipantAccessOptionAny] autorelease];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[CKAllowedSharingOptions allocWithZone:zone]
        initWithAllowedParticipantPermissionOptions:self.allowedParticipantPermissionOptions
        allowedParticipantAccessOptions:self.allowedParticipantAccessOptions];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithAllowedParticipantPermissionOptions:[coder decodeIntegerForKey:@"permissions"]
        allowedParticipantAccessOptions:[coder decodeIntegerForKey:@"access"]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:self.allowedParticipantPermissionOptions forKey:@"permissions"];
    [coder encodeInteger:self.allowedParticipantAccessOptions forKey:@"access"];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end

@implementation CKOperation (Finch)

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setValue:CKShortIdentifier() forKey:@"operationID"];
        self.configuration = [[[CKOperationConfiguration alloc] init] autorelease];
        self.qualityOfService = NSQualityOfServiceDefault;
    }
    return self;
}

- (CKOperationConfiguration *)configuration
{
    CKOperationConfiguration *configuration = objc_getAssociatedObject(self, &CKOperationConfigurationKey);
    if (!configuration) {
        configuration = [[[CKOperationConfiguration alloc] init] autorelease];
        objc_setAssociatedObject(self, &CKOperationConfigurationKey, configuration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return configuration;
}

- (void)setConfiguration:(CKOperationConfiguration *)configuration
{
    if (!configuration)
        configuration = [[[CKOperationConfiguration alloc] init] autorelease];
    CKOperationConfiguration *copy = [configuration copy];
    objc_setAssociatedObject(self, &CKOperationConfigurationKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [copy release];
}

- (void)main
{
    CKFinishOperation(self);
}

@end

#define CK_DEFAULT_INIT(ClassName) \
    @implementation ClassName (FinchInit) \
    - (instancetype)init { return [super init]; } \
    @end

CK_DEFAULT_INIT(CKAcceptSharesOperation)
CK_DEFAULT_INIT(CKDiscoverAllUserIdentitiesOperation)
CK_DEFAULT_INIT(CKDiscoverUserIdentitiesOperation)
CK_DEFAULT_INIT(CKFetchDatabaseChangesOperation)
CK_DEFAULT_INIT(CKFetchRecordChangesOperation)
CK_DEFAULT_INIT(CKFetchRecordZoneChangesOperation)
CK_DEFAULT_INIT(CKFetchRecordZonesOperation)
CK_DEFAULT_INIT(CKFetchRecordsOperation)
CK_DEFAULT_INIT(CKFetchShareMetadataOperation)
CK_DEFAULT_INIT(CKFetchShareParticipantsOperation)
CK_DEFAULT_INIT(CKFetchSubscriptionsOperation)
CK_DEFAULT_INIT(CKFetchWebAuthTokenOperation)
CK_DEFAULT_INIT(CKModifyRecordZonesOperation)
CK_DEFAULT_INIT(CKModifyRecordsOperation)
CK_DEFAULT_INIT(CKModifySubscriptionsOperation)
CK_DEFAULT_INIT(CKQueryOperation)
CK_DEFAULT_INIT(CKShareRequestAccessOperation)

@implementation CKAcceptSharesOperation (FinchInitWithMetadatas)
- (instancetype)initWithShareMetadatas:(NSArray<CKShareMetadata *> *)shareMetadatas
{
    self = [self init];
    if (self) self.shareMetadatas = shareMetadatas;
    return self;
}
@end

@implementation CKDiscoverUserIdentitiesOperation (FinchInitWithLookupInfos)
- (instancetype)initWithUserIdentityLookupInfos:(NSArray<CKUserIdentityLookupInfo *> *)lookupInfos
{
    self = [self init];
    if (self) self.userIdentityLookupInfos = lookupInfos;
    return self;
}
@end

@implementation CKFetchDatabaseChangesOperation (FinchInitWithToken)
- (instancetype)initWithPreviousServerChangeToken:(CKServerChangeToken *)token
{
    self = [self init];
    if (self) self.previousServerChangeToken = token;
    return self;
}
@end

@implementation CKFetchRecordChangesOperation (FinchInitWithZone)
- (instancetype)initWithRecordZoneID:(CKRecordZoneID *)zoneID previousServerChangeToken:(CKServerChangeToken *)token
{
    self = [self init];
    if (self) {
        self.recordZoneID = zoneID;
        self.previousServerChangeToken = token;
    }
    return self;
}
@end

@implementation CKFetchRecordZoneChangesOperation (FinchInitWithZones)
- (instancetype)initWithRecordZoneIDs:(NSArray<CKRecordZoneID *> *)zoneIDs
        configurationsByRecordZoneID:(NSDictionary<CKRecordZoneID *,CKFetchRecordZoneChangesConfiguration *> *)configurations
{
    self = [self init];
    if (self) {
        self.recordZoneIDs = zoneIDs ?: [configurations allKeys];
        [self setValue:configurations forKey:@"configurationsByRecordZoneID"];
    }
    return self;
}

- (instancetype)initWithRecordZoneIDs:(NSArray<CKRecordZoneID *> *)zoneIDs
             optionsByRecordZoneID:(NSDictionary<CKRecordZoneID *,CKFetchRecordZoneChangesOptions *> *)options
{
    self = [self init];
    if (self) {
        self.recordZoneIDs = zoneIDs ?: [options allKeys];
        [self setValue:options forKey:@"optionsByRecordZoneID"];
    }
    return self;
}
@end

@implementation CKFetchRecordZonesOperation (FinchFactory)
+ (instancetype)fetchAllRecordZonesOperation
{
    return [[[self alloc] init] autorelease];
}
@end

@implementation CKFetchRecordsOperation (FinchInitWithIDs)
- (instancetype)initWithRecordIDs:(NSArray<CKRecordID *> *)recordIDs
{
    self = [self init];
    if (self) self.recordIDs = recordIDs;
    return self;
}

+ (instancetype)fetchCurrentUserRecordOperation
{
    CKFetchRecordsOperation *operation = [[[self alloc] init] autorelease];
    objc_setAssociatedObject(operation, &CKFetchCurrentUserRecordKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return operation;
}
@end

@implementation CKFetchRecordZonesOperation (FinchInitWithIDs)
- (instancetype)initWithRecordZoneIDs:(NSArray<CKRecordZoneID *> *)recordZoneIDs
{
    self = [self init];
    if (self) self.recordZoneIDs = recordZoneIDs;
    return self;
}
@end

@implementation CKFetchShareMetadataOperation (FinchInitWithURLs)
- (instancetype)initWithShareURLs:(NSArray<NSURL *> *)shareURLs
{
    self = [self init];
    if (self) self.shareURLs = shareURLs;
    return self;
}
@end

@implementation CKFetchShareParticipantsOperation (FinchInitWithLookupInfos)
- (instancetype)initWithUserIdentityLookupInfos:(NSArray<CKUserIdentityLookupInfo *> *)lookupInfos
{
    self = [self init];
    if (self) self.userIdentityLookupInfos = lookupInfos;
    return self;
}
@end

@implementation CKFetchSubscriptionsOperation (FinchFactoryAndInit)
+ (instancetype)fetchAllSubscriptionsOperation
{
    return [[[self alloc] init] autorelease];
}

- (instancetype)initWithSubscriptionIDs:(NSArray<CKSubscriptionID> *)subscriptionIDs
{
    self = [self init];
    if (self) self.subscriptionIDs = subscriptionIDs;
    return self;
}
@end

@implementation CKFetchWebAuthTokenOperation (FinchInitWithToken)
- (instancetype)initWithAPIToken:(NSString *)APIToken
{
    self = [self init];
    if (self) self.APIToken = APIToken;
    return self;
}
@end

@implementation CKModifyRecordZonesOperation (FinchInitWithZones)
- (instancetype)initWithRecordZonesToSave:(NSArray<CKRecordZone *> *)zones
                   recordZoneIDsToDelete:(NSArray<CKRecordZoneID *> *)zoneIDs
{
    self = [self init];
    if (self) {
        self.recordZonesToSave = zones;
        self.recordZoneIDsToDelete = zoneIDs;
    }
    return self;
}
@end

@implementation CKModifyRecordsOperation (FinchInitWithRecords)
- (instancetype)initWithRecordsToSave:(NSArray<CKRecord *> *)records
                   recordIDsToDelete:(NSArray<CKRecordID *> *)recordIDs
{
    self = [self init];
    if (self) {
        self.recordsToSave = records;
        self.recordIDsToDelete = recordIDs;
    }
    return self;
}
@end

@implementation CKModifySubscriptionsOperation (FinchInitWithSubscriptions)
- (instancetype)initWithSubscriptionsToSave:(NSArray<CKSubscription *> *)subscriptions
                     subscriptionIDsToDelete:(NSArray<CKSubscriptionID> *)subscriptionIDs
{
    self = [self init];
    if (self) {
        self.subscriptionsToSave = subscriptions;
        self.subscriptionIDsToDelete = subscriptionIDs;
    }
    return self;
}
@end

@implementation CKQueryOperation (FinchInitWithQuery)
- (instancetype)initWithQuery:(CKQuery *)query
{
    self = [self init];
    if (self) self.query = query;
    return self;
}

- (instancetype)initWithCursor:(CKQueryCursor *)cursor
{
    self = [self init];
    if (self) self.cursor = cursor;
    return self;
}
@end

@implementation CKShareRequestAccessOperation (FinchInitWithURLs)
- (instancetype)initWithShareURLs:(NSArray<NSURL *> *)shareURLs
{
    self = [self init];
    if (self) self.shareURLs = shareURLs;
    return self;
}
@end

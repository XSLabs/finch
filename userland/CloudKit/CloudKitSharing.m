// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CloudKitInternal.h"
#import <objc/message.h>

static char CKNotificationIDValueKey;

static id CKNewObject(Class cls)
{
    return ((id (*)(id, SEL))objc_msgSend)([cls alloc], @selector(init));
}

static NSString *CKNewSubscriptionID(void)
{
    return [[NSUUID UUID] UUIDString];
}

static CKUserIdentity *CKOwnerIdentity(void)
{
    CKUserIdentity *identity = CKNewObject([CKUserIdentity class]);
    [identity setValue:@NO forKey:@"hasiCloudAccount"];
    [identity setValue:@[] forKey:@"contactIdentifiers"];
    return identity;
}

static CKShareParticipant *CKOwnerParticipant(void)
{
    CKShareParticipant *participant = CKNewObject([CKShareParticipant class]);
    [participant setValue:CKOwnerIdentity() forKey:@"userIdentity"];
    [participant setValue:@(CKShareParticipantRoleOwner) forKey:@"role"];
    [participant setValue:@(CKShareParticipantPermissionReadWrite) forKey:@"permission"];
    [participant setValue:@(CKShareParticipantAcceptanceStatusAccepted) forKey:@"acceptanceStatus"];
    [participant setValue:@"owner" forKey:@"participantID"];
    return participant;
}

@implementation CKSubscription (Finch)

- (instancetype)_initWithSubscriptionID:(NSString *)subscriptionID type:(CKSubscriptionType)type
{
    self = [super init];
    if (self) {
        if (![subscriptionID isKindOfClass:[NSString class]] || subscriptionID.length == 0)
            [NSException raise:NSInvalidArgumentException format:@"A subscription identifier is required"];
        [self setValue:[[subscriptionID copy] autorelease] forKey:@"subscriptionID"];
        [self setValue:@(type) forKey:@"subscriptionType"];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"subscriptionID"];
    self = [self _initWithSubscriptionID:identifier type:[coder decodeIntegerForKey:@"subscriptionType"]];
    if (self)
        self.notificationInfo = [coder decodeObjectOfClass:[CKNotificationInfo class] forKey:@"notificationInfo"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.subscriptionID forKey:@"subscriptionID"];
    [coder encodeInteger:self.subscriptionType forKey:@"subscriptionType"];
    [coder encodeObject:self.notificationInfo forKey:@"notificationInfo"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKSubscription *copy = [[CKSubscription allocWithZone:zone] _initWithSubscriptionID:self.subscriptionID type:self.subscriptionType];
    copy.notificationInfo = self.notificationInfo;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKQuerySubscription (Finch)

- (instancetype)initWithRecordType:(CKRecordType)recordType predicate:(NSPredicate *)predicate options:(CKQuerySubscriptionOptions)options
{
    return [self initWithRecordType:recordType predicate:predicate subscriptionID:CKNewSubscriptionID() options:options];
}

- (instancetype)initWithRecordType:(CKRecordType)recordType predicate:(NSPredicate *)predicate
                   subscriptionID:(CKSubscriptionID)subscriptionID options:(CKQuerySubscriptionOptions)options
{
    if (![recordType isKindOfClass:[NSString class]] || recordType.length == 0 || !predicate)
        [NSException raise:NSInvalidArgumentException format:@"A record type and predicate are required"];
    CKValidateQuery(predicate);
    self = [super _initWithSubscriptionID:subscriptionID type:CKSubscriptionTypeQuery];
    if (self) {
        
        [self setValue:[[recordType copy] autorelease] forKey:@"recordType"];
        [self setValue:predicate forKey:@"predicate"];
        [self setValue:@(options) forKey:@"querySubscriptionOptions"];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        NSString *type = [coder decodeObjectOfClass:[NSString class] forKey:@"recordType"];
        NSPredicate *predicate = [coder decodeObjectOfClass:[NSPredicate class] forKey:@"predicate"];
        CKValidateQuery(predicate);
        [self setValue:type forKey:@"recordType"];
        [self setValue:predicate forKey:@"predicate"];
        [self setValue:@([coder decodeIntegerForKey:@"querySubscriptionOptions"]) forKey:@"querySubscriptionOptions"];
        [self setValue:[coder decodeObjectOfClass:[CKRecordZoneID class] forKey:@"zoneID"] forKey:@"zoneID"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.recordType forKey:@"recordType"];
    [coder encodeObject:self.predicate forKey:@"predicate"];
    [coder encodeInteger:self.querySubscriptionOptions forKey:@"querySubscriptionOptions"];
    [coder encodeObject:self.zoneID forKey:@"zoneID"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKQuerySubscription *copy = [[CKQuerySubscription allocWithZone:zone] initWithRecordType:self.recordType
        predicate:self.predicate subscriptionID:self.subscriptionID options:self.querySubscriptionOptions];
    copy.zoneID = self.zoneID;
    copy.notificationInfo = self.notificationInfo;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKRecordZoneSubscription (Finch)

- (instancetype)initWithZoneID:(CKRecordZoneID *)zoneID
{
    return [self initWithZoneID:zoneID subscriptionID:CKNewSubscriptionID()];
}

- (instancetype)initWithZoneID:(CKRecordZoneID *)zoneID subscriptionID:(CKSubscriptionID)subscriptionID
{
    if (![zoneID isKindOfClass:[CKRecordZoneID class]])
        [NSException raise:NSInvalidArgumentException format:@"A record zone identifier is required"];
    self = [super _initWithSubscriptionID:subscriptionID type:CKSubscriptionTypeRecordZone];
    if (self) {
        [self setValue:zoneID forKey:@"zoneID"];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self setValue:[coder decodeObjectOfClass:[CKRecordZoneID class] forKey:@"zoneID"] forKey:@"zoneID"];
        [self setValue:[coder decodeObjectOfClass:[NSString class] forKey:@"recordType"] forKey:@"recordType"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.zoneID forKey:@"zoneID"];
    [coder encodeObject:self.recordType forKey:@"recordType"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKRecordZoneSubscription *copy = [[CKRecordZoneSubscription allocWithZone:zone] initWithZoneID:self.zoneID subscriptionID:self.subscriptionID];
    copy.recordType = self.recordType;
    copy.notificationInfo = self.notificationInfo;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKDatabaseSubscription (Finch)

- (instancetype)init
{
    return [self initWithSubscriptionID:CKNewSubscriptionID()];
}

- (instancetype)initWithSubscriptionID:(CKSubscriptionID)subscriptionID
{
    self = [super _initWithSubscriptionID:subscriptionID type:CKSubscriptionTypeDatabase];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self)
        self.recordType = [coder decodeObjectOfClass:[NSString class] forKey:@"recordType"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.recordType forKey:@"recordType"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKDatabaseSubscription *copy = [[CKDatabaseSubscription allocWithZone:zone] initWithSubscriptionID:self.subscriptionID];
    copy.recordType = self.recordType;
    copy.notificationInfo = self.notificationInfo;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKNotificationInfo (Finch)

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        NSArray *keys = @[@"alertBody", @"alertLocalizationKey", @"alertLocalizationArgs", @"title",
            @"titleLocalizationKey", @"titleLocalizationArgs", @"subtitle", @"subtitleLocalizationKey",
            @"subtitleLocalizationArgs", @"alertActionLocalizationKey", @"alertLaunchImage", @"soundName",
            @"desiredKeys", @"category", @"collapseIDKey"];
        for (NSString *key in keys)
            [self setValue:[coder decodeObjectForKey:key] forKey:key];
        self.shouldBadge = [coder decodeBoolForKey:@"shouldBadge"];
        self.shouldSendContentAvailable = [coder decodeBoolForKey:@"shouldSendContentAvailable"];
        self.shouldSendMutableContent = [coder decodeBoolForKey:@"shouldSendMutableContent"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSArray *keys = @[@"alertBody", @"alertLocalizationKey", @"alertLocalizationArgs", @"title",
        @"titleLocalizationKey", @"titleLocalizationArgs", @"subtitle", @"subtitleLocalizationKey",
        @"subtitleLocalizationArgs", @"alertActionLocalizationKey", @"alertLaunchImage", @"soundName",
        @"desiredKeys", @"category", @"collapseIDKey"];
    for (NSString *key in keys)
        [coder encodeObject:[self valueForKey:key] forKey:key];
    [coder encodeBool:self.shouldBadge forKey:@"shouldBadge"];
    [coder encodeBool:self.shouldSendContentAvailable forKey:@"shouldSendContentAvailable"];
    [coder encodeBool:self.shouldSendMutableContent forKey:@"shouldSendMutableContent"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKNotificationInfo *copy = [[CKNotificationInfo allocWithZone:zone] init];
    NSArray *keys = @[@"alertBody", @"alertLocalizationKey", @"alertLocalizationArgs", @"title",
        @"titleLocalizationKey", @"titleLocalizationArgs", @"subtitle", @"subtitleLocalizationKey",
        @"subtitleLocalizationArgs", @"alertActionLocalizationKey", @"alertLaunchImage", @"soundName",
        @"desiredKeys", @"category", @"collapseIDKey", @"shouldBadge", @"shouldSendContentAvailable",
        @"shouldSendMutableContent"];
    for (NSString *key in keys)
        [copy setValue:[self valueForKey:key] forKey:key];
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKUserIdentityLookupInfo (Finch)

- (instancetype)initWithEmailAddress:(NSString *)emailAddress
{
    if (![emailAddress isKindOfClass:[NSString class]] || emailAddress.length == 0)
        [NSException raise:NSInvalidArgumentException format:@"An email address is required"];
    self = [super init];
    if (self) [self setValue:emailAddress forKey:@"emailAddress"];
    return self;
}

- (instancetype)initWithPhoneNumber:(NSString *)phoneNumber
{
    if (![phoneNumber isKindOfClass:[NSString class]] || phoneNumber.length == 0)
        [NSException raise:NSInvalidArgumentException format:@"A phone number is required"];
    self = [super init];
    if (self) [self setValue:phoneNumber forKey:@"phoneNumber"];
    return self;
}

- (instancetype)initWithUserRecordID:(CKRecordID *)userRecordID
{
    if (![userRecordID isKindOfClass:[CKRecordID class]])
        [NSException raise:NSInvalidArgumentException format:@"A user record identifier is required"];
    self = [super init];
    if (self) [self setValue:userRecordID forKey:@"userRecordID"];
    return self;
}

+ (NSArray<CKUserIdentityLookupInfo *> *)lookupInfosWithEmails:(NSArray<NSString *> *)emails
{
    NSMutableArray *infos = [NSMutableArray arrayWithCapacity:emails.count];
    for (NSString *email in emails) [infos addObject:[[[self alloc] initWithEmailAddress:email] autorelease]];
    return infos;
}

+ (NSArray<CKUserIdentityLookupInfo *> *)lookupInfosWithPhoneNumbers:(NSArray<NSString *> *)phoneNumbers
{
    NSMutableArray *infos = [NSMutableArray arrayWithCapacity:phoneNumbers.count];
    for (NSString *phone in phoneNumbers) [infos addObject:[[[self alloc] initWithPhoneNumber:phone] autorelease]];
    return infos;
}

+ (NSArray<CKUserIdentityLookupInfo *> *)lookupInfosWithRecordIDs:(NSArray<CKRecordID *> *)recordIDs
{
    NSMutableArray *infos = [NSMutableArray arrayWithCapacity:recordIDs.count];
    for (CKRecordID *recordID in recordIDs) [infos addObject:[[[self alloc] initWithUserRecordID:recordID] autorelease]];
    return infos;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        [self setValue:[coder decodeObjectOfClass:[NSString class] forKey:@"emailAddress"] forKey:@"emailAddress"];
        [self setValue:[coder decodeObjectOfClass:[NSString class] forKey:@"phoneNumber"] forKey:@"phoneNumber"];
        [self setValue:[coder decodeObjectOfClass:[CKRecordID class] forKey:@"userRecordID"] forKey:@"userRecordID"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.emailAddress forKey:@"emailAddress"];
    [coder encodeObject:self.phoneNumber forKey:@"phoneNumber"];
    [coder encodeObject:self.userRecordID forKey:@"userRecordID"];
}

- (id)copyWithZone:(NSZone *)zone
{
    if (self.emailAddress) return [[CKUserIdentityLookupInfo allocWithZone:zone] initWithEmailAddress:self.emailAddress];
    if (self.phoneNumber) return [[CKUserIdentityLookupInfo allocWithZone:zone] initWithPhoneNumber:self.phoneNumber];
    return [[CKUserIdentityLookupInfo allocWithZone:zone] initWithUserRecordID:self.userRecordID];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKShareParticipant (Finch)

+ (instancetype)oneTimeURLParticipant
{
    CKShareParticipant *participant = CKNewObject(self);
    [participant setValue:CKOwnerIdentity() forKey:@"userIdentity"];
    [participant setValue:@(CKShareParticipantRolePrivateUser) forKey:@"role"];
    [participant setValue:@(CKShareParticipantPermissionReadOnly) forKey:@"permission"];
    [participant setValue:@(CKShareParticipantAcceptanceStatusPending) forKey:@"acceptanceStatus"];
    [participant setValue:@"one-time-url" forKey:@"participantID"];
    return [participant autorelease];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        [self setValue:[coder decodeObjectOfClass:[CKUserIdentity class] forKey:@"userIdentity"] forKey:@"userIdentity"];
        [self setValue:@([coder decodeIntegerForKey:@"role"]) forKey:@"role"];
        [self setValue:@([coder decodeIntegerForKey:@"permission"]) forKey:@"permission"];
        [self setValue:@([coder decodeIntegerForKey:@"acceptanceStatus"]) forKey:@"acceptanceStatus"];
        [self setValue:[coder decodeObjectOfClass:[NSString class] forKey:@"participantID"] forKey:@"participantID"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.userIdentity forKey:@"userIdentity"];
    [coder encodeInteger:self.role forKey:@"role"];
    [coder encodeInteger:self.permission forKey:@"permission"];
    [coder encodeInteger:self.acceptanceStatus forKey:@"acceptanceStatus"];
    [coder encodeObject:self.participantID forKey:@"participantID"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKShareParticipant *copy = CKNewObject([CKShareParticipant class]);
    [copy setValue:self.userIdentity forKey:@"userIdentity"];
    [copy setValue:@(self.role) forKey:@"role"];
    [copy setValue:@(self.permission) forKey:@"permission"];
    [copy setValue:@(self.acceptanceStatus) forKey:@"acceptanceStatus"];
    [copy setValue:self.participantID forKey:@"participantID"];
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKShare (Finch)

- (instancetype)initWithRecordZoneID:(CKRecordZoneID *)recordZoneID
{
    if (![recordZoneID isKindOfClass:[CKRecordZoneID class]])
        [NSException raise:NSInvalidArgumentException format:@"A record zone identifier is required"];
    CKRecordID *shareID = [[[CKRecordID alloc] initWithRecordName:[[NSUUID UUID] UUIDString] zoneID:recordZoneID] autorelease];
    self = [super initWithRecordType:CKRecordTypeShare recordID:shareID];
    if (self) {
        [self setValue:@(CKShareParticipantPermissionNone) forKey:@"publicPermission"];
        [self setValue:@[] forKey:@"participants"];
        [self addParticipant:CKOwnerParticipant()];
    }
    return self;
}

- (instancetype)initWithRootRecord:(CKRecord *)rootRecord
{
    CKRecordID *shareID = [[[CKRecordID alloc] initWithRecordName:[[NSUUID UUID] UUIDString] zoneID:rootRecord.recordID.zoneID] autorelease];
    return [self initWithRootRecord:rootRecord shareID:shareID];
}

- (instancetype)initWithRootRecord:(CKRecord *)rootRecord shareID:(CKRecordID *)shareID
{
    if (![rootRecord isKindOfClass:[CKRecord class]] || ![shareID isKindOfClass:[CKRecordID class]])
        [NSException raise:NSInvalidArgumentException format:@"A root record and share identifier are required"];
    self = [super initWithRecordType:CKRecordTypeShare recordID:shareID];
    if (self) {
        [self setValue:@(CKShareParticipantPermissionNone) forKey:@"publicPermission"];
        [self setValue:@[] forKey:@"participants"];
        [self setValue:rootRecord.recordID forKey:@"hierarchicalRootRecordID"];
        [self addParticipant:CKOwnerParticipant()];
    }
    return self;
}

- (void)addParticipant:(CKShareParticipant *)participant
{
    if (![participant isKindOfClass:[CKShareParticipant class]])
        [NSException raise:NSInvalidArgumentException format:@"A share participant is required"];
    NSMutableArray *participants = [NSMutableArray arrayWithArray:self.participants ?: @[]];
    if (![participants containsObject:participant]) [participants addObject:participant];
    [self setValue:participants forKey:@"participants"];
    if (participant.role == CKShareParticipantRoleOwner) {
        [self setValue:participant forKey:@"owner"];
        [self setValue:participant forKey:@"currentUserParticipant"];
    }
}

- (void)removeParticipant:(CKShareParticipant *)participant
{
    NSMutableArray *participants = [NSMutableArray arrayWithArray:self.participants ?: @[]];
    [participants removeObject:participant];
    [self setValue:participants forKey:@"participants"];
    if (self.owner == participant) [self setValue:nil forKey:@"owner"];
}

- (NSURL *)oneTimeURLForParticipantID:(NSString *)participantID
{
    return nil;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self setValue:@([coder decodeIntegerForKey:@"publicPermission"]) forKey:@"publicPermission"];
        [self setValue:[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [CKShareParticipant class], nil] forKey:@"participants"] forKey:@"participants"];
        [self setValue:[coder decodeObjectOfClass:[CKShareParticipant class] forKey:@"owner"] forKey:@"owner"];
        [self setValue:[coder decodeObjectOfClass:[CKShareParticipant class] forKey:@"currentUserParticipant"] forKey:@"currentUserParticipant"];
        [self setValue:[coder decodeObjectOfClass:[NSURL class] forKey:@"URL"] forKey:@"URL"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeInteger:self.publicPermission forKey:@"publicPermission"];
    [coder encodeObject:self.participants forKey:@"participants"];
    [coder encodeObject:self.owner forKey:@"owner"];
    [coder encodeObject:self.currentUserParticipant forKey:@"currentUserParticipant"];
    [coder encodeObject:self.URL forKey:@"URL"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKShare *copy = [[CKShare allocWithZone:zone] initWithRecordZoneID:self.recordID.zoneID];
    [copy setValue:self.recordID forKey:@"recordID"];
    [copy setValue:@(self.publicPermission) forKey:@"publicPermission"];
    [copy setValue:self.participants forKey:@"participants"];
    [copy setValue:self.owner forKey:@"owner"];
    [copy setValue:self.currentUserParticipant forKey:@"currentUserParticipant"];
    [copy setValue:self.URL forKey:@"URL"];
    for (NSString *key in self.allKeys) copy[key] = self[key];
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation CKNotification (Finch)

+ (instancetype)notificationFromRemoteNotificationDictionary:(NSDictionary *)notificationDictionary
{
    if (![notificationDictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *cloudKit = notificationDictionary[@"ck"];
    if (![cloudKit isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *query = cloudKit[@"qry"];
    NSDictionary *zone = cloudKit[@"fet"];
    Class cls = query ? [CKQueryNotification class] : (zone ? [CKRecordZoneNotification class] : [CKNotification class]);
    CKNotification *notification = CKNewObject(cls);
    if (query || zone)
        [notification setValue:@(query ? CKNotificationTypeQuery : CKNotificationTypeRecordZone) forKey:@"notificationType"];
    [notification setValue:cloudKit[@"cid"] forKey:@"containerIdentifier"];
    [notification setValue:query[@"sid"] forKey:@"subscriptionID"];
    NSString *notificationID = cloudKit[@"nid"];
    if ([notificationID isKindOfClass:[NSString class]]) {
        id identifier = CKNewObject([CKNotificationID class]);
        objc_setAssociatedObject(identifier, &CKNotificationIDValueKey, notificationID, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [notification setValue:identifier forKey:@"notificationID"];
        [identifier release];
    }
    NSDictionary *content = query ?: zone;
    if (query) {
        CKQueryNotification *queryNotification = (id)notification;
        NSString *recordName = content[@"rid"];
        NSString *zoneName = content[@"zid"] ?: CKRecordZoneDefaultName;
        NSString *ownerName = content[@"zoid"] ?: CKCurrentUserDefaultName;
        if ([recordName isKindOfClass:[NSString class]]) {
            CKRecordZoneID *zoneID = [[[CKRecordZoneID alloc] initWithZoneName:zoneName ownerName:ownerName] autorelease];
            CKRecordID *recordID = [[[CKRecordID alloc] initWithRecordName:recordName zoneID:zoneID] autorelease];
            [queryNotification setValue:recordID forKey:@"recordID"];
        }
        NSInteger databaseScope = [content[@"dbs"] integerValue];
        if (databaseScope == 1) databaseScope = CKDatabaseScopePrivate;
        else if (databaseScope == 2) databaseScope = CKDatabaseScopePublic;
        [queryNotification setValue:@(databaseScope) forKey:@"databaseScope"];
    } else if (zone) {
        CKRecordZoneNotification *zoneNotification = (id)notification;
        NSString *zoneName = content[@"zid"];
        NSString *ownerName = content[@"zoid"] ?: CKCurrentUserDefaultName;
        if ([zoneName isKindOfClass:[NSString class]]) {
            CKRecordZoneID *zoneID = [[[CKRecordZoneID alloc] initWithZoneName:zoneName ownerName:ownerName] autorelease];
            [zoneNotification setValue:zoneID forKey:@"recordZoneID"];
        }
        NSInteger databaseScope = [content[@"dbs"] integerValue];
        if (databaseScope == 1) databaseScope = CKDatabaseScopePrivate;
        else if (databaseScope == 2) databaseScope = CKDatabaseScopePublic;
        [zoneNotification setValue:@(databaseScope) forKey:@"databaseScope"];
    }
    return [notification autorelease];
}

@end

@implementation CKNotificationID (Finch)

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
        objc_setAssociatedObject(self, &CKNotificationIDValueKey,
            [coder decodeObjectOfClass:[NSString class] forKey:@"uuid"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:objc_getAssociatedObject(self, &CKNotificationIDValueKey) forKey:@"uuid"];
}

- (id)copyWithZone:(NSZone *)zone
{
    CKNotificationID *copy = CKNewObject([CKNotificationID class]);
    objc_setAssociatedObject(copy, &CKNotificationIDValueKey,
        objc_getAssociatedObject(self, &CKNotificationIDValueKey), OBJC_ASSOCIATION_COPY_NONATOMIC);
    return copy;
}

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    NSString *identifier = objc_getAssociatedObject(self, &CKNotificationIDValueKey);
    return [object isKindOfClass:[CKNotificationID class]] && identifier &&
        [identifier isEqual:objc_getAssociatedObject(object, &CKNotificationIDValueKey)];
}

- (NSUInteger)hash
{
    return [objc_getAssociatedObject(self, &CKNotificationIDValueKey) hash];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

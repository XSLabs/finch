// SPDX-License-Identifier: MIT OR Apache-2.0
// Stable CloudKit model behavior compared with the macOS SDK implementation.
#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

int main(void)
{
    @autoreleasepool {
        Dl_info info;
        printf("CloudKit: %s\n", dladdr((__bridge const void *)[CKRecord class], &info) ? info.dli_fname : "?");

        CKRecordZoneID *zoneID = [[CKRecordZoneID alloc] initWithZoneName:@"work" ownerName:CKCurrentUserDefaultName];
        CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:@"task-1" zoneID:zoneID];
        CKRecord *record = [[CKRecord alloc] initWithRecordType:@"Task" recordID:recordID];
        record[@"title"] = @"Hello World!";
        record[@"count"] = @3;
        NSArray *tokens = [[record.allTokens sortedArrayUsingSelector:@selector(compare:)] copy];
        printf("record: %s %s keys=%s changed=%s tokens=%s\n", record.recordType.UTF8String,
            record.recordID.recordName.UTF8String, record.allKeys.description.UTF8String,
            record.changedKeys.description.UTF8String, tokens.description.UTF8String);
        CKRecord *copy = [record copy];
        printf("copy: sameFields=%d equal=%d\n", [copy.allKeys isEqual:record.allKeys], [copy isEqual:record]);

        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:record requiringSecureCoding:YES error:NULL];
        CKRecord *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[CKRecord class] fromData:archive error:NULL];
        printf("archive: %s %s fields=%s\n", decoded.recordType.UTF8String,
            decoded.recordID.recordName.UTF8String, decoded.allKeys.description.UTF8String);

        CKReference *reference = [[CKReference alloc] initWithRecordID:recordID action:CKReferenceActionDeleteSelf];
        printf("reference: %s action=%ld\n", reference.recordID.recordName.UTF8String, (long)reference.referenceAction);
        CKRecordZone *defaultZone = [CKRecordZone defaultRecordZone];
        printf("default zone: %s %s\n", defaultZone.zoneID.zoneName.UTF8String, defaultZone.zoneID.ownerName.UTF8String);

        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"title == %@", @"Hello World!"];
        CKQuery *query = [[CKQuery alloc] initWithRecordType:@"Task" predicate:predicate];
        printf("query: %s predicate=%d\n", query.recordType.UTF8String, query.predicate != nil);
        @try {
            NSPredicate *blockPredicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                (void)object;
                (void)bindings;
                return YES;
            }];
            (void)[[CKQuery alloc] initWithRecordType:@"Task" predicate:blockPredicate];
            puts("block query: accepted");
        } @catch (NSException *exception) {
            printf("block query: %s\n", exception.name.UTF8String);
        }

        CKQuerySubscription *subscription = [[CKQuerySubscription alloc] initWithRecordType:@"Task"
            predicate:predicate subscriptionID:@"task-changes" options:CKQuerySubscriptionOptionsFiresOnRecordUpdate];
        CKRecordZoneSubscription *zoneSubscription = [[CKRecordZoneSubscription alloc] initWithZoneID:zoneID subscriptionID:@"zone-changes"];
        printf("subscriptions: %ld %s %ld %s\n", (long)subscription.subscriptionType,
            subscription.subscriptionID.UTF8String, (long)zoneSubscription.subscriptionType, zoneSubscription.subscriptionID.UTF8String);

        CKShare *share = [[CKShare alloc] initWithRecordZoneID:zoneID];
        CKAllowedSharingOptions *sharing = [CKAllowedSharingOptions standardOptions];
        printf("share: permission=%ld participants=%lu owner=%d options=%lu/%lu\n",
            (long)share.publicPermission, (unsigned long)share.participants.count,
            share.owner == share.currentUserParticipant,
            (unsigned long)sharing.allowedParticipantPermissionOptions,
            (unsigned long)sharing.allowedParticipantAccessOptions);

        CKOperationConfiguration *configuration = [[CKOperationConfiguration alloc] init];
        CKOperationGroup *group = [[CKOperationGroup alloc] init];
        printf("operation defaults: qos=%ld cellular=%d longLived=%d request=%.0f resource=%.0f groupIDLength=%lu\n",
            (long)configuration.qualityOfService, configuration.allowsCellularAccess, configuration.longLived,
            configuration.timeoutIntervalForRequest, configuration.timeoutIntervalForResource,
            (unsigned long)group.operationGroupID.length);
        CKOperationConfiguration *groupConfiguration = group.defaultConfiguration;
        group.defaultConfiguration = nil;
        printf("operation group defaults: present=%d qos=%ld resets=%d\n",
            groupConfiguration != nil, (long)groupConfiguration.qualityOfService,
            group.defaultConfiguration != nil);

        CKFetchRecordsOperation *fetchOperation = [[CKFetchRecordsOperation alloc] init];
        CKOperationConfiguration *operationConfiguration = fetchOperation.configuration;
        fetchOperation.configuration = nil;
        printf("operation configuration: present=%d qos=%ld resets=%d\n",
            operationConfiguration != nil, (long)operationConfiguration.qualityOfService,
            fetchOperation.configuration != nil);

        // The SDK hides -init; call NSObject's initializer to check the weak
        // delegate property without starting a sync engine or using iCloud.
        IMP objectInit = class_getMethodImplementation([NSObject class], @selector(init));
        CKSyncEngineConfiguration *syncConfiguration = ((id (*)(id, SEL))objectInit)(
            [CKSyncEngineConfiguration alloc], @selector(init));
        BOOL hadDelegate = NO;
        @autoreleasepool {
            NSObject *delegate = [[NSObject alloc] init];
            syncConfiguration.delegate = (id<CKSyncEngineDelegate>)delegate;
            hadDelegate = syncConfiguration.delegate != nil;
        }
        printf("sync delegate: %d %d\n", hadDelegate, syncConfiguration.delegate != nil);

        NSDictionary *payload = @{@"ck": @{@"cid": @"iCloud.example", @"nid": @"n-1",
            @"qry": @{@"sid": @"task-changes", @"rid": @"task-1", @"zid": @"work",
                @"zoid": CKCurrentUserDefaultName, @"dbs": @1, @"qre": @2}}};
        CKNotification *notification = [CKNotification notificationFromRemoteNotificationDictionary:payload];
        CKQueryNotification *queryNotification = (id)notification;
        printf("notification: %s type=%ld subscription=%s record=%s zone=%s scope=%ld reason=%ld\n",
            NSStringFromClass(notification.class).UTF8String, (long)notification.notificationType,
            notification.subscriptionID.UTF8String, queryNotification.recordID.recordName.UTF8String,
            queryNotification.recordID.zoneID.zoneName.UTF8String, (long)queryNotification.databaseScope,
            (long)queryNotification.queryNotificationReason);
    }
    return 0;
}

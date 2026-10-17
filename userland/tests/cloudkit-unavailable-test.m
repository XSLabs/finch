// SPDX-License-Identifier: MIT OR Apache-2.0
// Finch-only check for CloudKit's local no-account responses.
#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

int main(void)
{
    @autoreleasepool {
        CKContainer *container = [CKContainer containerWithIdentifier:@"iCloud.org.finch.offline-test"];
        dispatch_semaphore_t statusDone = dispatch_semaphore_create(0);
        __block CKAccountStatus accountStatus = CKAccountStatusCouldNotDetermine;
        __block NSError *accountError = nil;
        [container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {
            accountStatus = status;
            accountError = error;
            dispatch_semaphore_signal(statusDone);
        }];
        if (dispatch_semaphore_wait(statusDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            puts("account status: timed out");
            return 1;
        }
        printf("account status: no account=%d error=%d\n",
            accountStatus == CKAccountStatusNoAccount, accountError != nil);

        CKDatabase *database = container.privateCloudDatabase;
        CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:@"offline-record"];
        dispatch_semaphore_t fetchDone = dispatch_semaphore_create(0);
        __block NSError *fetchError = nil;
        [database fetchRecordWithID:recordID completionHandler:^(CKRecord *record, NSError *error) {
            (void)record;
            fetchError = error;
            dispatch_semaphore_signal(fetchDone);
        }];
        if (dispatch_semaphore_wait(fetchDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            puts("record fetch: timed out");
            return 1;
        }
        printf("record fetch: error=%d domain=%s code=%ld description=%s\n",
            fetchError != nil, fetchError.domain.UTF8String, (long)fetchError.code,
            fetchError.localizedDescription.UTF8String);

        NSObject *delegate = [[NSObject alloc] init];
        CKSyncEngineConfiguration *configuration = [[CKSyncEngineConfiguration alloc]
            initWithDatabase:database stateSerialization:nil delegate:(id<CKSyncEngineDelegate>)delegate];
        CKSyncEngine *engine = [[CKSyncEngine alloc] initWithConfiguration:configuration];
        CKSyncEnginePendingRecordZoneChange *change = [[CKSyncEnginePendingRecordZoneChange alloc]
            initWithRecordID:recordID type:CKSyncEnginePendingRecordZoneChangeTypeSaveRecord];
        [engine.state addPendingRecordZoneChanges:@[change]];
        // No sync events run offline, so ask the local state object for its
        // serialized snapshot to test the save-and-restore path.
        id serialization = ((id (*)(id, SEL))objc_msgSend)(engine.state, sel_registerName("_serialization"));
        NSError *archiveError = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:serialization
            requiringSecureCoding:YES error:&archiveError];
        CKSyncEngineStateSerialization *restoredSerialization = [NSKeyedUnarchiver
            unarchivedObjectOfClass:[CKSyncEngineStateSerialization class] fromData:archive error:&archiveError];
        CKSyncEngineConfiguration *restoredConfiguration = [[CKSyncEngineConfiguration alloc]
            initWithDatabase:database stateSerialization:restoredSerialization delegate:(id<CKSyncEngineDelegate>)delegate];
        CKSyncEngine *restoredEngine = [[CKSyncEngine alloc] initWithConfiguration:restoredConfiguration];
        CKSyncEnginePendingRecordZoneChange *restoredChange = restoredEngine.state.pendingRecordZoneChanges.firstObject;
        printf("sync state: pending=%lu sameRecord=%d type=%ld archiveError=%d\n",
            (unsigned long)restoredEngine.state.pendingRecordZoneChanges.count,
            [restoredChange.recordID isEqual:recordID], (long)restoredChange.type, archiveError != nil);
    }
    return 0;
}

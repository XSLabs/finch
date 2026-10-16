// SPDX-License-Identifier: MIT OR Apache-2.0
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

NSString * const NSInMemoryStoreType = @"InMemory";
NSString * const NSBinaryStoreType = @"Binary";
NSString * const NSXMLStoreType = @"XML";
NSString * const NSSQLiteStoreType = @"SQLite";
NSString * const NSSQLiteErrorDomain = @"NSSQLiteErrorDomain";
NSString * const NSStoreTypeKey = @"NSStoreType";
NSString * const NSStoreUUIDKey = @"NSStoreUUID";
NSString * const NSStoreModelVersionHashesKey = @"NSStoreModelVersionHashes";
NSString * const NSStoreModelVersionIdentifiersKey = @"NSStoreModelVersionIdentifiers";

NSString * const NSInsertedObjectsKey = @"inserted";
NSString * const NSUpdatedObjectsKey = @"updated";
NSString * const NSUpdatedObjectIDsKey = @"updatedObjectIDs";
NSString * const NSDeletedObjectsKey = @"deleted";
NSString * const NSRefreshedObjectsKey = @"refreshed";
NSString * const NSInvalidatedObjectsKey = @"invalidated";
NSString * const NSInvalidatedAllObjectsKey = @"invalidatedAll";
NSString * const NSManagedObjectContextDidSaveNotification = @"NSManagingContextDidSaveChangesNotification";
NSString * const NSManagedObjectContextDidSaveObjectIDsNotification = @"NSManagedObjectContextDidSaveObjectIDsNotification";
NSString * const NSManagedObjectContextObjectsDidChangeNotification = @"NSManagingContextDidChangeObjectValuesNotification";
NSString * const NSManagedObjectContextWillSaveNotification = @"NSManagingContextWillSaveChangesNotification";
NSString * const NSManagedObjectContextDidMergeChangesObjectIDsNotification = @"NSManagedObjectContextDidMergeChangesObjectIDsNotification";
NSString * const NSPersistentStoreCoordinatorStoresDidChangeNotification = @"NSPersistentStoreCoordinatorStoresDidChangeNotification";
NSString * const NSPersistentStoreRemoteChangeNotification = @"NSPersistentStoreRemoteChangeNotification";
NSString * const NSPersistentHistoryTokenKey = @"NSPersistentHistoryToken";
NSString * const NSPersistentHistoryTrackingKey = @"NSPersistentHistoryTrackingKey";
NSString * const NSPersistentStoreFileProtectionKey = @"NSPersistentStoreFileProtectionKey";
NSString * const NSPersistentStoreRemoteChangeNotificationPostOptionKey = @"NSPersistentStoreRemoteChangeNotificationPostOptionKey";
NSString * const NSPersistentStoreStagedMigrationManagerOptionKey = @"NSPersistentStoreStagedMigrationManagerOptionKey";
NSString * const NSSQLitePragmasOption = @"NSSQLitePragmasOption";
NSString * const NSPersistentStoreTimeoutOption = @"NSPersistentStoreTimeoutOption";
NSString * const NSSQLiteAnalyzeOption = @"NSSQLiteAnalyzeOption";
NSString * const NSSQLiteManualVacuumOption = @"NSSQLiteManualVacuumOption";
NSString * const NSReadOnlyPersistentStoreOption = @"NSReadOnlyPersistentStoreOption";
NSString * const NSMigratePersistentStoresAutomaticallyOption = @"NSMigratePersistentStoresAutomaticallyOption";
NSString * const NSInferMappingModelAutomaticallyOption = @"NSInferMappingModelAutomaticallyOption";
NSString * const NSIgnorePersistentStoreVersioningOption = @"NSIgnorePersistentStoreVersioningOption";
NSString * const NSStoreModelVersionHashesVersionKey = @"NSStoreModelVersionHashesVersion";
NSString * const NSCoreDataCoreSpotlightDelegateIndexDidUpdateNotification = @"NSCoreDataCoreSpotlightDelegateIndexDidUpdateNotification";

id NSErrorMergePolicy;
id NSRollbackMergePolicy;
id NSOverwriteMergePolicy;
id NSMergeByPropertyObjectTrumpMergePolicy;
id NSMergeByPropertyStoreTrumpMergePolicy;

void CDInitializeMergePolicyGlobals(void) {
    Class cls = objc_getClass("NSMergePolicy");
    if (!cls) return;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSErrorMergePolicy = send((id)cls, sel_registerName("errorMergePolicy"));
    NSRollbackMergePolicy = send((id)cls, sel_registerName("rollbackMergePolicy"));
    NSOverwriteMergePolicy = send((id)cls, sel_registerName("overwriteMergePolicy"));
    NSMergeByPropertyObjectTrumpMergePolicy = send((id)cls, sel_registerName("mergeByPropertyObjectTrumpMergePolicy"));
    NSMergeByPropertyStoreTrumpMergePolicy = send((id)cls, sel_registerName("mergeByPropertyStoreTrumpMergePolicy"));
}

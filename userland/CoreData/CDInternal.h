// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreData/CoreData.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <sqlite3.h>

@interface NSManagedObjectID (FinchInitializer)
- (instancetype)cd_init;
@end

static inline NSMutableDictionary *CDState(id object) {
    NSMutableDictionary *state = objc_getAssociatedObject(object, @selector(_finchCoreDataState));
    if (!state) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(object, @selector(_finchCoreDataState), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static inline id CDGet(id object, NSString *key) {
    id value = [CDState(object) objectForKey:key];
    return value == [NSNull null] ? nil : value;
}

static inline void CDSet(id object, NSString *key, id value) {
    if (value) [CDState(object) setObject:value forKey:key];
    else [CDState(object) removeObjectForKey:key];
}

static inline NSError *CDError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code
                           userInfo:[NSDictionary dictionaryWithObject:(description ?: @"Core Data operation failed")
                                                                forKey:NSLocalizedDescriptionKey]];
}

static inline BOOL CDReturnError(NSError **error, NSError *value) {
    if (error) *error = value;
    return NO;
}

NSManagedObject *CDNewObject(NSEntityDescription *entity, NSManagedObjectContext *context);
NSManagedObject *CDRegisterFetchedObject(NSManagedObjectContext *context, NSEntityDescription *entity, NSPersistentStore *store, NSInteger primaryKey);
NSManagedObjectID *CDMakeObjectID(NSEntityDescription *entity, NSPersistentStore *store, NSInteger primaryKey, BOOL temporary);
void CDObjectDidPersist(NSManagedObject *object, NSPersistentStore *store);
NSArray *CDStoreFetch(NSManagedObjectContext *context, NSFetchRequest *request, NSError **error);
BOOL CDStoreSave(NSManagedObjectContext *context, NSError **error);
BOOL CDStoreDelete(NSManagedObjectContext *context, NSManagedObject *object, NSError **error);
void CDPerformBlock(NSManagedObjectContext *context, void (^block)(void));
void CDPerformBlockAndWait(NSManagedObjectContext *context, void (^block)(void));
NSError *CDCountForFetchRequest(NSManagedObjectContext *context, NSFetchRequest *request, NSUInteger *result);
NSError *CDFetchForFetchRequest(NSManagedObjectContext *context, NSFetchRequest *request, NSArray **result);
NSError *CDReplacePersistentStore(NSPersistentStoreCoordinator *coordinator, NSURL *destinationURL,
                                  NSDictionary *destinationOptions, NSURL *sourceURL,
                                  NSDictionary *sourceOptions, NSString *storeType);
void CDObjectSetValue(NSManagedObject *object, id value, NSString *key, BOOL markChanged);
id CDObjectValue(NSManagedObject *object, NSString *key);
sqlite3 *CDStoreDatabase(NSPersistentStore *store);
NSString *CDTableName(NSEntityDescription *entity);
NSInteger CDEntityID(NSPersistentStore *store, NSEntityDescription *entity);
BOOL CDIsCustomStore(NSPersistentStore *store);
BOOL CDLoadCustomStore(NSPersistentStore *store, NSString *type, NSError **error);
NSDictionary *CDModelMetadata(NSManagedObjectModel *model);
BOOL CDFireCustomFault(NSManagedObject *object, NSError **error);
NSArray *CDCustomStoreFetch(NSManagedObjectContext *context, NSPersistentStore *store, NSFetchRequest *request,
                            NSEntityDescription *entity, NSError **error);
BOOL CDCustomStoreSave(NSManagedObjectContext *context, NSPersistentStore *store, NSArray *inserted, NSArray *updated,
                       NSArray *deleted, NSError **error);
BOOL CDObtainCustomIDs(NSPersistentStore *store, NSArray *objects, NSError **error);
id CDCustomReferenceFromURIKey(NSString *key);
void CDRekeyRegisteredObjects(NSManagedObjectContext *context);
BOOL CDFireSQLiteFault(NSManagedObject *object, NSError **error);
id CDLoadSQLiteToMany(NSManagedObject *object, NSRelationshipDescription *relationship);
BOOL CDFireFault(NSManagedObject *object, NSError **error);
BOOL CDMigrateWithMapping(NSMigrationManager *manager, NSURL *sourceURL, NSString *sourceType, NSDictionary *sourceOptions,
                          NSMappingModel *mapping, NSURL *destinationURL, NSString *destinationType,
                          NSDictionary *destinationOptions, NSError **error);
NSPersistentStoreResult *CDExecuteBatchInsert(NSPersistentStoreCoordinator *coordinator, NSBatchInsertRequest *request, NSError **error);
NSPersistentStoreResult *CDExecuteCloudKitEventRequest(NSPersistentCloudKitContainerEventRequest *request);
void CDRegisterBuiltInStores(NSMutableDictionary *classes);

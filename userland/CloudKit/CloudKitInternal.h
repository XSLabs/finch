// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

NSError *CKNoAccountError(void);
void CKPerformAsync(dispatch_block_t block);
BOOL CKIsValidRecordValue(id value);
void CKValidateQuery(NSPredicate *predicate);

@interface CKContainer (FinchPrivate)
- (instancetype)_initWithIdentifier:(NSString *)identifier;
@end

@interface CKDatabase (FinchPrivate)
- (instancetype)_initWithContainer:(CKContainer *)container scope:(CKDatabaseScope)scope;
@end

@interface CKRecord (FinchPrivate)
- (void)_setSystemValue:(id)value forKey:(NSString *)key;
- (NSDictionary *)_fieldValues;
@end

@interface CKSubscription (FinchPrivate)
- (instancetype)_initWithSubscriptionID:(NSString *)subscriptionID type:(CKSubscriptionType)type;
@end

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Contacts.framework, Finch's: what its files share. */
#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

/* (Finch's own initializers: in the init family, for ARC) */
#define FINCH_INIT __attribute__((objc_method_family(init)))

/* An aggregate key descriptor: a list of descriptors, under a name for its description. */
@interface CNAggregateKeyDescriptor : NSObject <CNKeyDescriptor> {
  @public
    NSArray *_descriptors;
    NSString *_finchDescription;
}
- (instancetype)initWithKeyDescriptors:(NSArray *)descriptors description:(NSString *)description;
@end

@interface CNContact () {
  @public
    NSString *_identifier;
    NSMutableDictionary<NSString *, id> *_values;
    NSSet<NSString *> *_Nullable _available; /* nil: every key */
    BOOL _persisted;
}
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier values:(NSDictionary *)values available:(nullable NSSet *)available FINCH_INIT;
@end

@interface CNGroup () {
  @public
    NSString *_identifier;
    NSString *_name;
}
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name FINCH_INIT;
@end

@interface CNContainer () {
  @public
    NSString *_identifier;
    NSString *_name;
    CNContainerType _type;
}
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier name:(NSString *)name type:(CNContainerType)type FINCH_INIT;
@end

/* A store predicate: the store answers it from its records (CNContactStore.m). */
@interface FinchCNPredicate : NSPredicate
@property (copy) NSString *kind;
@property (copy, nullable) id argument;
@property (copy, nullable) NSString *finchDescription;
@end

NSArray<NSString *> *FinchCNStringKeys(void);
NSArray<NSString *> *FinchCNArrayKeys(void);
NSArray<NSString *> *FinchCNAllKeys(void);
NSSet<NSString *> *FinchCNKeysOfDescriptors(NSArray *descriptors);
/* The English name for a label, key or service ("label", "contact", "postal", ...). */
NSString *_Nullable FinchCNLocalizedString(NSString *table, NSString *key, NSString *_Nullable fallback);
/* A contact picture's thumbnail (or nil without one). */
NSData *_Nullable FinchCNThumbnail(NSData *_Nullable imageData);
NSError *FinchCNError(CNErrorCode code, NSString *_Nullable description);

NS_ASSUME_NONNULL_END

// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CryptoTokenKit/CryptoTokenKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <Block.h>

NSString * const TKErrorDomain = @"CryptoTokenKit.ErrorDomain";

static char TKObjectIDKey;
static char TKLabelKey;
static char TKConstraintsKey;
static char TKDataKey;
static char TKKeyTypeKey;
static char TKApplicationTagKey;
static char TKKeySizeKey;
static char TKPublicKeyKey;
static char TKPublicKeyHashKey;
static char TKKeyCanDecryptKey;
static char TKKeyCanSignKey;
static char TKKeyCanExchangeKey;
static char TKKeyLoginKey;
static char TKItemsKey;
static char TKInstanceIDKey;
static char TKConfigurationDataKey;
static char TKKeychainItemsKey;
static char TKTokenDriverKey;
static char TKTokenDelegateKey;
static char TKTokenConfigurationKey;
static char TKTokenContentsKey;
static char TKSessionTokenKey;
static char TKSessionDelegateKey;
static char TKDriverDelegateKey;
static char TKOperationFinishedKey;
static char TKPasswordKey;
static char TKTokenConfigsKey;
static char TKDriverClassIDKey;
static char TKPINCharsetKey;
static char TKPINEncodingKey;
static char TKPINMinimumLengthKey;
static char TKPINMaximumLengthKey;
static char TKPINBlockLengthKey;
static char TKPINJustificationKey;
static char TKPINBitOffsetKey;
static char TKPINLengthBitOffsetKey;
static char TKPINLengthBitSizeKey;

static NSError *TKMissingObjectError(void)
{
    return [NSError errorWithDomain:TKErrorDomain code:TKErrorCodeObjectNotFound
        userInfo:[NSDictionary dictionaryWithObject:@"The token object is not available" forKey:NSLocalizedDescriptionKey]];
}

static NSInteger TKPINValue(id object, const void *key, NSInteger fallback)
{
    NSNumber *value = objc_getAssociatedObject(object, key);
    return value ? value.integerValue : fallback;
}

static void TKSetPINValue(id object, const void *key, NSInteger value)
{
    objc_setAssociatedObject(object, key, [NSNumber numberWithInteger:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@implementation TKSmartCardPINFormat

- (TKSmartCardPINCharset)charset { return (TKSmartCardPINCharset)TKPINValue(self, &TKPINCharsetKey, TKSmartCardPINCharsetNumeric); }
- (void)setCharset:(TKSmartCardPINCharset)value { TKSetPINValue(self, &TKPINCharsetKey, value); }
- (TKSmartCardPINEncoding)encoding { return (TKSmartCardPINEncoding)TKPINValue(self, &TKPINEncodingKey, TKSmartCardPINEncodingASCII); }
- (void)setEncoding:(TKSmartCardPINEncoding)value { TKSetPINValue(self, &TKPINEncodingKey, value); }
- (NSInteger)minPINLength { return TKPINValue(self, &TKPINMinimumLengthKey, 4); }
- (void)setMinPINLength:(NSInteger)value { TKSetPINValue(self, &TKPINMinimumLengthKey, value); }
- (NSInteger)maxPINLength { return TKPINValue(self, &TKPINMaximumLengthKey, 8); }
- (void)setMaxPINLength:(NSInteger)value { TKSetPINValue(self, &TKPINMaximumLengthKey, value); }
- (NSInteger)PINBlockByteLength { return TKPINValue(self, &TKPINBlockLengthKey, 8); }
- (void)setPINBlockByteLength:(NSInteger)value { TKSetPINValue(self, &TKPINBlockLengthKey, value); }
- (TKSmartCardPINJustification)PINJustification { return (TKSmartCardPINJustification)TKPINValue(self, &TKPINJustificationKey, TKSmartCardPINJustificationLeft); }
- (void)setPINJustification:(TKSmartCardPINJustification)value { TKSetPINValue(self, &TKPINJustificationKey, value); }
- (NSInteger)PINBitOffset { return TKPINValue(self, &TKPINBitOffsetKey, 0); }
- (void)setPINBitOffset:(NSInteger)value { TKSetPINValue(self, &TKPINBitOffsetKey, value); }
- (NSInteger)PINLengthBitOffset { return TKPINValue(self, &TKPINLengthBitOffsetKey, 0); }
- (void)setPINLengthBitOffset:(NSInteger)value { TKSetPINValue(self, &TKPINLengthBitOffsetKey, value); }
- (NSInteger)PINLengthBitSize { return TKPINValue(self, &TKPINLengthBitSizeKey, 0); }
- (void)setPINLengthBitSize:(NSInteger)value { TKSetPINValue(self, &TKPINLengthBitSizeKey, value); }

@end

@interface TKWeakBox : NSObject
{
    id _object;
}
- (instancetype)initWithObject:(id)object;
- (id)load;
@end

@implementation TKWeakBox
- (instancetype)initWithObject:(id)object
{
    self = [super init];
    if (self) objc_storeWeak(&_object, object);
    return self;
}
- (id)load { return [objc_loadWeak(&_object) retain]; }
- (void)dealloc { objc_storeWeak(&_object, nil); [super dealloc]; }
@end

static void TKSetWeak(id object, const void *key, id value)
{
    TKWeakBox *box = value ? [[TKWeakBox alloc] initWithObject:value] : nil;
    objc_setAssociatedObject(object, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [box release];
}

static id TKGetWeak(id object, const void *key)
{
    TKWeakBox *box = objc_getAssociatedObject(object, key);
    return [[box load] autorelease];
}

@implementation TKTokenKeychainItem

- (instancetype)initWithObjectID:(TKTokenObjectID)objectID
{
    if (!objectID || ![objectID conformsToProtocol:@protocol(NSCopying)]) {
        [self release];
        return nil;
    }
    self = [super init];
    if (self) objc_setAssociatedObject(self, &TKObjectIDKey, [objectID copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}
- (id)objectID { return objc_getAssociatedObject(self, &TKObjectIDKey); }
- (NSString *)label { return objc_getAssociatedObject(self, &TKLabelKey); }
- (void)setLabel:(NSString *)value { objc_setAssociatedObject(self, &TKLabelKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSDictionary *)constraints { return objc_getAssociatedObject(self, &TKConstraintsKey); }
- (void)setConstraints:(NSDictionary *)value { objc_setAssociatedObject(self, &TKConstraintsKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

@end

@implementation TKTokenKeychainCertificate

- (instancetype)initWithCertificate:(SecCertificateRef)certificateRef objectID:(TKTokenObjectID)objectID
{
    if (!certificateRef || !objectID) { [self release]; return nil; }
    self = [super initWithObjectID:objectID];
    if (self) {
        CFDataRef data = SecCertificateCopyData(certificateRef);
        if (data) {
            objc_setAssociatedObject(self, &TKDataKey, [(NSData *)data copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(data);
        }
        self.constraints = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
            forKey:[NSNumber numberWithInteger:TKTokenOperationReadData]];
    }
    return self;
}
- (NSData *)data { return objc_getAssociatedObject(self, &TKDataKey); }

@end

@implementation TKTokenKeychainKey

- (instancetype)initWithCertificate:(SecCertificateRef)certificateRef objectID:(TKTokenObjectID)objectID
{
    if (!objectID) { [self release]; return nil; }
    self = [super initWithObjectID:objectID];
    if (self && certificateRef) {
        CFDataRef data = SecCertificateCopyData(certificateRef);
        if (data) {
            objc_setAssociatedObject(self, &TKDataKey, [(NSData *)data copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(data);
        }
    }
    return self;
}
- (NSString *)keyType { return objc_getAssociatedObject(self, &TKKeyTypeKey); }
- (void)setKeyType:(NSString *)value { objc_setAssociatedObject(self, &TKKeyTypeKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSData *)applicationTag { return objc_getAssociatedObject(self, &TKApplicationTagKey); }
- (void)setApplicationTag:(NSData *)value { objc_setAssociatedObject(self, &TKApplicationTagKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)keySizeInBits { return [objc_getAssociatedObject(self, &TKKeySizeKey) integerValue]; }
- (void)setKeySizeInBits:(NSInteger)value { objc_setAssociatedObject(self, &TKKeySizeKey, [NSNumber numberWithInteger:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSData *)publicKeyData { return objc_getAssociatedObject(self, &TKPublicKeyKey); }
- (void)setPublicKeyData:(NSData *)value { objc_setAssociatedObject(self, &TKPublicKeyKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSData *)publicKeyHash { return objc_getAssociatedObject(self, &TKPublicKeyHashKey); }
- (void)setPublicKeyHash:(NSData *)value { objc_setAssociatedObject(self, &TKPublicKeyHashKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)canDecrypt { return [objc_getAssociatedObject(self, &TKKeyCanDecryptKey) boolValue]; }
- (void)setCanDecrypt:(BOOL)value { objc_setAssociatedObject(self, &TKKeyCanDecryptKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)canSign { return [objc_getAssociatedObject(self, &TKKeyCanSignKey) boolValue]; }
- (void)setCanSign:(BOOL)value { objc_setAssociatedObject(self, &TKKeyCanSignKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)canPerformKeyExchange { return [objc_getAssociatedObject(self, &TKKeyCanExchangeKey) boolValue]; }
- (void)setCanPerformKeyExchange:(BOOL)value { objc_setAssociatedObject(self, &TKKeyCanExchangeKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)isSuitableForLogin { return [objc_getAssociatedObject(self, &TKKeyLoginKey) boolValue]; }
- (void)setSuitableForLogin:(BOOL)value { objc_setAssociatedObject(self, &TKKeyLoginKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

@end

static TKTokenKeychainItem *TKFindKeychainItem(NSArray *items, id objectID, Class itemClass)
{
    for (TKTokenKeychainItem *item in items)
        if ([item isKindOfClass:itemClass] && [item.objectID isEqual:objectID]) return item;
    return nil;
}

@implementation TKTokenKeychainContents

- (instancetype)init
{
    self = [super init];
    if (self) objc_setAssociatedObject(self, &TKItemsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}
- (void)fillWithItems:(NSArray<TKTokenKeychainItem *> *)items
{
    for (id item in items)
        if (![item isKindOfClass:[TKTokenKeychainItem class]])
            [NSException raise:NSInvalidArgumentException format:@"Token keychain contents accept TKTokenKeychainItem values"];
    objc_setAssociatedObject(self, &TKItemsKey, [items copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSArray *)items { return objc_getAssociatedObject(self, &TKItemsKey) ?: [NSArray array]; }
- (TKTokenKeychainKey *)keyForObjectID:(id)objectID error:(NSError **)error
{
    TKTokenKeychainKey *item = (id)TKFindKeychainItem(self.items, objectID, [TKTokenKeychainKey class]);
    if (!item && error) *error = TKMissingObjectError();
    return item;
}
- (TKTokenKeychainCertificate *)certificateForObjectID:(id)objectID error:(NSError **)error
{
    TKTokenKeychainCertificate *item = (id)TKFindKeychainItem(self.items, objectID, [TKTokenKeychainCertificate class]);
    if (!item && error) *error = TKMissingObjectError();
    return item;
}

@end

@interface TKTokenConfiguration (FinchInternal)
- (instancetype)_initWithInstanceID:(NSString *)instanceID;
@end

@implementation TKTokenConfiguration

- (instancetype)_initWithInstanceID:(NSString *)instanceID
{
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &TKInstanceIDKey, [instanceID copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TKKeychainItemsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (NSString *)instanceID { return objc_getAssociatedObject(self, &TKInstanceIDKey); }
- (NSData *)configurationData { return objc_getAssociatedObject(self, &TKConfigurationDataKey); }
- (void)setConfigurationData:(NSData *)value { objc_setAssociatedObject(self, &TKConfigurationDataKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSArray *)keychainItems { return objc_getAssociatedObject(self, &TKKeychainItemsKey); }
- (void)setKeychainItems:(NSArray *)value
{
    for (id item in value)
        if (![item isKindOfClass:[TKTokenKeychainItem class]])
            [NSException raise:NSInvalidArgumentException format:@"Token configurations accept TKTokenKeychainItem values"];
    objc_setAssociatedObject(self, &TKKeychainItemsKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (TKTokenKeychainKey *)keyForObjectID:(id)objectID error:(NSError **)error
{
    TKTokenKeychainKey *item = (id)TKFindKeychainItem(self.keychainItems, objectID, [TKTokenKeychainKey class]);
    if (!item && error) *error = TKMissingObjectError();
    return item;
}
- (TKTokenKeychainCertificate *)certificateForObjectID:(id)objectID error:(NSError **)error
{
    TKTokenKeychainCertificate *item = (id)TKFindKeychainItem(self.keychainItems, objectID, [TKTokenKeychainCertificate class]);
    if (!item && error) *error = TKMissingObjectError();
    return item;
}

@end

@interface TKTokenDriverConfiguration (FinchInternal)
- (instancetype)_initWithClassID:(NSString *)classID;
@end

@implementation TKTokenDriverConfiguration

+ (NSDictionary *)driverConfigurations { return [NSDictionary dictionary]; }
- (instancetype)_initWithClassID:(NSString *)classID
{
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &TKDriverClassIDKey, [classID copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TKTokenConfigsKey, [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (NSString *)classID { return objc_getAssociatedObject(self, &TKDriverClassIDKey); }
- (NSDictionary *)tokenConfigurations { return [objc_getAssociatedObject(self, &TKTokenConfigsKey) copy]; }
- (TKTokenConfiguration *)addTokenConfigurationForTokenInstanceID:(NSString *)instanceID
{
    if (![instanceID isKindOfClass:[NSString class]] || instanceID.length == 0)
        [NSException raise:NSInvalidArgumentException format:@"A token instance identifier is required"];
    TKTokenConfiguration *configuration = [[[TKTokenConfiguration alloc] _initWithInstanceID:instanceID] autorelease];
    NSMutableDictionary *values = objc_getAssociatedObject(self, &TKTokenConfigsKey);
    [values setObject:configuration forKey:instanceID];
    return configuration;
}
- (void)removeTokenConfigurationForTokenInstanceID:(NSString *)instanceID
{
    [objc_getAssociatedObject(self, &TKTokenConfigsKey) removeObjectForKey:instanceID];
}

@end

@implementation TKTokenKeyAlgorithm
- (BOOL)isAlgorithm:(SecKeyAlgorithm)algorithm
{
    id value = objc_getAssociatedObject(self, &TKDataKey);
    return value && CFEqual((CFTypeRef)value, (CFTypeRef)algorithm);
}
- (BOOL)supportsAlgorithm:(SecKeyAlgorithm)algorithm { return [self isAlgorithm:algorithm]; }
@end

@implementation TKTokenKeyExchangeParameters
- (NSInteger)requestedSize { return [objc_getAssociatedObject(self, &TKKeySizeKey) integerValue]; }
- (NSData *)sharedInfo { return objc_getAssociatedObject(self, &TKDataKey); }
@end

@implementation TKTokenSession
- (instancetype)initWithToken:(TKToken *)token
{
    if (!token) { [self release]; return nil; }
    self = [super init];
    if (self) objc_setAssociatedObject(self, &TKSessionTokenKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}
- (TKToken *)token { return objc_getAssociatedObject(self, &TKSessionTokenKey); }
- (id<TKTokenSessionDelegate>)delegate { return TKGetWeak(self, &TKSessionDelegateKey); }
- (void)setDelegate:(id<TKTokenSessionDelegate>)delegate { TKSetWeak(self, &TKSessionDelegateKey, delegate); }
@end

@implementation TKToken
- (instancetype)initWithTokenDriver:(TKTokenDriver *)tokenDriver instanceID:(NSString *)instanceID
{
    if (!tokenDriver || ![instanceID isKindOfClass:[NSString class]] || instanceID.length == 0) { [self release]; return nil; }
    self = [super init];
    if (self) {
        objc_setAssociatedObject(self, &TKTokenDriverKey, tokenDriver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TKInstanceIDKey, [instanceID copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (TKTokenDriver *)tokenDriver { return objc_getAssociatedObject(self, &TKTokenDriverKey); }
- (id<TKTokenDelegate>)delegate { return TKGetWeak(self, &TKTokenDelegateKey); }
- (void)setDelegate:(id<TKTokenDelegate>)delegate { TKSetWeak(self, &TKTokenDelegateKey, delegate); }
- (TKTokenConfiguration *)configuration { return objc_getAssociatedObject(self, &TKTokenConfigurationKey); }
- (TKTokenKeychainContents *)keychainContents { return objc_getAssociatedObject(self, &TKTokenContentsKey); }
@end

@implementation TKTokenDriver
- (id<TKTokenDriverDelegate>)delegate { return TKGetWeak(self, &TKDriverDelegateKey); }
- (void)setDelegate:(id<TKTokenDriverDelegate>)delegate { TKSetWeak(self, &TKDriverDelegateKey, delegate); }
@end

@implementation TKSmartCardSlotManager

+ (TKSmartCardSlotManager *)defaultManager { return nil; }
- (NSArray<NSString *> *)slotNames { return [NSArray array]; }
- (TKSmartCardSlot *)slotNamed:(NSString *)name
{
    (void)name;
    return nil;
}
- (void)getSlotWithName:(NSString *)name reply:(void (^)(TKSmartCardSlot *))reply
{
    (void)name;
    if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(nil); });
}
- (BOOL)isNFCSupported { return NO; }

@end

@implementation TKTokenAuthOperation
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) objc_setAssociatedObject(self, &TKOperationFinishedKey,
        [NSNumber numberWithBool:[coder decodeBoolForKey:@"finished"]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:[objc_getAssociatedObject(self, &TKOperationFinishedKey) boolValue] forKey:@"finished"];
}
- (BOOL)finishWithError:(NSError **)error
{
    if ([objc_getAssociatedObject(self, &TKOperationFinishedKey) boolValue]) {
        if (error) *error = [NSError errorWithDomain:TKErrorDomain code:TKErrorCodeBadParameter
            userInfo:[NSDictionary dictionaryWithObject:@"This authentication operation already finished" forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    objc_setAssociatedObject(self, &TKOperationFinishedKey, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
@end

@implementation TKTokenPasswordAuthOperation
- (NSString *)password { return objc_getAssociatedObject(self, &TKPasswordKey); }
- (void)setPassword:(NSString *)value { objc_setAssociatedObject(self, &TKPasswordKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end

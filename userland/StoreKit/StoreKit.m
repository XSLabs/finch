/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * StoreKit. Finch has no App Store, so it answers as a Mac signed out of one with
 * payments not allowed: +canMakePayments is NO, product requests fail as offline
 * (SKErrorCloudServiceNetworkConnectionFailed), purchases fail with
 * SKErrorPaymentNotAllowed, and the payment queue holds no transactions. Payments,
 * products and their discounts work as values.
 */
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>

@interface NSObject (FinchSKInit)
- (instancetype)_finchInit __attribute__((objc_method_family(init)));
@end
@implementation NSObject (FinchSKInit)
- (instancetype)_finchInit { return [self init]; }
@end

static NSError *
sk_error(NSInteger code)
{
    return [NSError errorWithDomain:SKErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : @"The App Store isn't available on this computer."}];
}

/* --- requests --- */

@implementation SKRequest {
    @protected
    __weak id<SKRequestDelegate> _delegate;
    BOOL _cancelled;
}
- (id<SKRequestDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<SKRequestDelegate>)delegate { _delegate = delegate; }
- (void)cancel { _cancelled = YES; }
- (void)start
{
    id<SKRequestDelegate> d = _delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_cancelled)
          return;
      if ([d respondsToSelector:@selector(request:didFailWithError:)])
          [d request:self didFailWithError:sk_error(SKErrorCloudServiceNetworkConnectionFailed)];
    });
}
@end

@implementation SKProductsRequest {
    NSSet *_identifiers;
}
- (instancetype)initWithProductIdentifiers:(NSSet<NSString *> *)productIdentifiers
{
    if ((self = [super init]))
        _identifiers = [productIdentifiers copy];
    return self;
}
- (id<SKProductsRequestDelegate>)delegate { return (id<SKProductsRequestDelegate>)_delegate; }
- (void)setDelegate:(id<SKProductsRequestDelegate>)delegate { _delegate = delegate; }
@end

@implementation SKReceiptRefreshRequest {
    NSDictionary *_finchProperties;
}
- (instancetype)initWithReceiptProperties:(NSDictionary<NSString *, id> *)properties
{
    if ((self = [super init]))
        _finchProperties = [properties copy];
    return self;
}
- (NSDictionary *)receiptProperties { return _finchProperties; }
@end

@implementation SKProductsResponse
- (NSArray<SKProduct *> *)products { return @[]; }
- (NSArray<NSString *> *)invalidProductIdentifiers { return @[]; }
@end

/* --- products and payments, as values --- */

@implementation SKProduct
- (NSString *)localizedDescription { return @""; }
- (NSString *)localizedTitle { return @""; }
- (NSDecimalNumber *)price { return [NSDecimalNumber zero]; }
- (NSLocale *)priceLocale { return [NSLocale currentLocale]; }
- (NSString *)productIdentifier { return @""; }
- (BOOL)isDownloadable { return NO; }
- (BOOL)downloadable { return NO; }
- (BOOL)isFamilyShareable { return NO; }
- (NSArray<NSNumber *> *)contentLengths { return @[]; }
- (NSArray<NSNumber *> *)downloadContentLengths { return @[]; }
- (NSString *)contentVersion { return @""; }
- (NSString *)downloadContentVersion { return @""; }
- (SKProductSubscriptionPeriod *)subscriptionPeriod { return nil; }
- (SKProductDiscount *)introductoryPrice { return nil; }
- (NSString *)subscriptionGroupIdentifier { return nil; }
- (NSArray<SKProductDiscount *> *)discounts { return @[]; }
@end

@implementation SKProductSubscriptionPeriod
- (NSUInteger)numberOfUnits { return 0; }
- (SKProductPeriodUnit)unit { return SKProductPeriodUnitDay; }
@end

@implementation SKProductDiscount
- (NSDecimalNumber *)price { return [NSDecimalNumber zero]; }
- (NSLocale *)priceLocale { return [NSLocale currentLocale]; }
- (NSString *)identifier { return nil; }
- (SKProductSubscriptionPeriod *)subscriptionPeriod { return nil; }
- (NSUInteger)numberOfPeriods { return 0; }
- (SKProductDiscountPaymentMode)paymentMode { return SKProductDiscountPaymentModePayAsYouGo; }
- (SKProductDiscountType)type { return SKProductDiscountTypeIntroductory; }
@end

@implementation SKPaymentDiscount {
    NSString *_identifier, *_keyIdentifier, *_signature;
    NSUUID *_nonce;
    NSNumber *_timestamp;
}
- (instancetype)initWithIdentifier:(NSString *)identifier keyIdentifier:(NSString *)keyIdentifier nonce:(NSUUID *)nonce
                         signature:(NSString *)signature timestamp:(NSNumber *)timestamp
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _keyIdentifier = [keyIdentifier copy];
        _nonce = nonce;
        _signature = [signature copy];
        _timestamp = timestamp;
    }
    return self;
}
- (NSString *)identifier { return _identifier; }
- (NSString *)keyIdentifier { return _keyIdentifier; }
- (NSUUID *)nonce { return _nonce; }
- (NSString *)signature { return _signature; }
- (NSNumber *)timestamp { return _timestamp; }
@end

@implementation SKPayment {
    @protected
    NSString *_productIdentifier, *_applicationUsername;
    NSData *_requestData;
    NSInteger _quantity;
    BOOL _simulatesAskToBuyInSandbox;
    SKPaymentDiscount *_paymentDiscount;
}

+ (instancetype)paymentWithProduct:(SKProduct *)product
{
    SKPayment *p = [[self alloc] _finchInit];
    p->_productIdentifier = [product.productIdentifier copy];
    p->_quantity = 1;
    return p;
}

+ (id)paymentWithProductIdentifier:(NSString *)identifier
{
    SKPayment *p = [[self alloc] _finchInit];
    p->_productIdentifier = [identifier copy];
    p->_quantity = 1;
    return p;
}

- (NSString *)productIdentifier { return _productIdentifier; }
- (NSData *)requestData { return _requestData; }
- (NSInteger)quantity { return _quantity; }
- (NSString *)applicationUsername { return _applicationUsername; }
- (BOOL)simulatesAskToBuyInSandbox { return _simulatesAskToBuyInSandbox; }
- (SKPaymentDiscount *)paymentDiscount { return _paymentDiscount; }

- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone
{
    SKMutablePayment *m = [SKMutablePayment new];
    m.productIdentifier = _productIdentifier;
    m.requestData = _requestData;
    m.quantity = _quantity;
    m.applicationUsername = _applicationUsername;
    m.paymentDiscount = _paymentDiscount;
    return m;
}

@end

@implementation SKMutablePayment
- (void)setProductIdentifier:(NSString *)v { _productIdentifier = [v copy]; }
- (void)setRequestData:(NSData *)v { _requestData = [v copy]; }
- (void)setQuantity:(NSInteger)v { _quantity = v; }
- (void)setApplicationUsername:(NSString *)v { _applicationUsername = [v copy]; }
- (void)setSimulatesAskToBuyInSandbox:(BOOL)v { _simulatesAskToBuyInSandbox = v; }
- (void)setPaymentDiscount:(SKPaymentDiscount *)v { _paymentDiscount = v; }
- (id)copyWithZone:(NSZone *)zone { return [super mutableCopyWithZone:zone]; }
@end

@implementation SKPaymentTransaction {
    SKPayment *_payment;
    NSError *_error;
    NSString *_identifier;
    NSDate *_date;
}

+ (instancetype)_finchFailedTransactionFor:(SKPayment *)payment
{
    SKPaymentTransaction *t = [[self alloc] _finchInit];
    t->_payment = payment;
    t->_error = sk_error(SKErrorPaymentNotAllowed);
    t->_date = [NSDate date];
    return t;
}

- (SKPayment *)payment { return _payment; }
- (NSError *)error { return _error; }
- (SKPaymentTransactionState)transactionState { return SKPaymentTransactionStateFailed; }
- (NSString *)transactionIdentifier { return _identifier; }
- (NSDate *)transactionDate { return _date; }
- (SKPaymentTransaction *)originalTransaction { return nil; }
- (NSData *)transactionReceipt { return nil; }
- (NSArray<SKDownload *> *)downloads { return @[]; }
@end

@implementation SKDownload
- (SKDownloadState)state { return SKDownloadStateFailed; }
- (SKDownloadState)downloadState { return SKDownloadStateFailed; }
- (NSNumber *)contentLength { return @0; }
- (long long)expectedContentLength { return 0; }
- (NSString *)contentIdentifier { return @""; }
- (NSURL *)contentURL { return nil; }
- (NSString *)contentVersion { return @""; }
- (NSError *)error { return sk_error(SKErrorPaymentNotAllowed); }
- (float)progress { return 0; }
- (NSTimeInterval)timeRemaining { return SKDownloadTimeRemainingUnknown; }
- (SKPaymentTransaction *)transaction { return nil; }
+ (NSURL *)contentURLForProductID:(NSString *)productID { return nil; }
+ (void)deleteContentForProductID:(NSString *)productID {}
@end

/* --- the payment queue --- */

@implementation SKPaymentQueue {
    NSHashTable *_observers;
    __weak id<SKPaymentQueueDelegate> _delegate;
    NSMutableArray<SKPaymentTransaction *> *_transactions;
}

+ (BOOL)canMakePayments { return NO; }

+ (instancetype)defaultQueue
{
    static SKPaymentQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [[SKPaymentQueue alloc] init]; });
    return queue;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _observers = [NSHashTable weakObjectsHashTable];
        _transactions = [NSMutableArray array];
    }
    return self;
}

- (id<SKPaymentQueueDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<SKPaymentQueueDelegate>)delegate { _delegate = delegate; }
- (SKStorefront *)storefront { return nil; }
- (NSArray<SKPaymentTransaction *> *)transactions { return [_transactions copy]; }
- (NSArray *)transactionObservers { return _observers.allObjects; }
- (void)addTransactionObserver:(id<SKPaymentTransactionObserver>)observer { [_observers addObject:observer]; }
- (void)removeTransactionObserver:(id<SKPaymentTransactionObserver>)observer { [_observers removeObject:observer]; }

/* A purchase fails: purchases aren't allowed. */
- (void)addPayment:(SKPayment *)payment
{
    SKPaymentTransaction *t = [SKPaymentTransaction _finchFailedTransactionFor:payment];
    [_transactions addObject:t];
    NSArray *observers = _observers.allObjects;
    dispatch_async(dispatch_get_main_queue(), ^{
      for (id<SKPaymentTransactionObserver> o in observers)
          [o paymentQueue:self updatedTransactions:@[ t ]];
    });
}

- (void)finishTransaction:(SKPaymentTransaction *)transaction
{
    [_transactions removeObject:transaction];
    NSArray *observers = _observers.allObjects;
    dispatch_async(dispatch_get_main_queue(), ^{
      for (id<SKPaymentTransactionObserver> o in observers)
          if ([o respondsToSelector:@selector(paymentQueue:removedTransactions:)])
              [o paymentQueue:self removedTransactions:@[ transaction ]];
    });
}

- (void)restoreCompletedTransactions { [self restoreCompletedTransactionsWithApplicationUsername:nil]; }

- (void)restoreCompletedTransactionsWithApplicationUsername:(NSString *)username
{
    NSArray *observers = _observers.allObjects;
    dispatch_async(dispatch_get_main_queue(), ^{
      for (id<SKPaymentTransactionObserver> o in observers)
          if ([o respondsToSelector:@selector(paymentQueue:restoreCompletedTransactionsFailedWithError:)])
              [o paymentQueue:self restoreCompletedTransactionsFailedWithError:sk_error(SKErrorCloudServiceNetworkConnectionFailed)];
    });
}

- (void)startDownloads:(NSArray<SKDownload *> *)downloads {}
- (void)pauseDownloads:(NSArray<SKDownload *> *)downloads {}
- (void)resumeDownloads:(NSArray<SKDownload *> *)downloads {}
- (void)cancelDownloads:(NSArray<SKDownload *> *)downloads {}
- (void)presentCodeRedemptionSheet {}
- (void)showPriceConsentIfNeeded {}

@end

@implementation SKStorefront
- (NSString *)countryCode { return @""; }
- (NSString *)identifier { return @""; }
@end

/* Review requests: there's no store to review in. */
@implementation SKStoreReviewController
+ (void)requestReview {}
+ (void)requestReviewInScene:(id)windowScene {}
@end

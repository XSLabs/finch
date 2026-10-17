// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CBInternal.h"
#import <dispatch/dispatch.h>
#import <objc/message.h>

static char CBManagerDelegateKey;
static char CBManagerQueueKey;
static char CBManagerCentralKey;
static char CBManagerPeripheralKey;
static char CBManagerCommandQueueKey;

static id CBManagerBaseInit(id object)
{
    struct objc_super call = {object, [CBManager class]};
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&call, @selector(init));
}

@interface CBWeakReference : NSObject
{
    id _object;
}
- (instancetype)initWithObject:(id)object;
- (id)load;
@end

@implementation CBWeakReference
- (instancetype)initWithObject:(id)object
{
    self = [super init];
    if (self) objc_storeWeak(&_object, object);
    return self;
}
- (id)load { return [objc_loadWeak(&_object) retain]; }
- (void)dealloc { objc_storeWeak(&_object, nil); [super dealloc]; }
@end

NSError *CBUnsupportedError(void)
{
    return [NSError errorWithDomain:CBErrorDomain code:CBErrorOperationNotSupported
        userInfo:[NSDictionary dictionaryWithObject:@"Finch has no Bluetooth transport" forKey:NSLocalizedDescriptionKey]];
}

void CBSetWeak(id object, const void *key, id value)
{
    CBWeakReference *reference = value ? [[CBWeakReference alloc] initWithObject:value] : nil;
    objc_setAssociatedObject(object, key, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [reference release];
}
id CBGetWeak(id object, const void *key)
{
    CBWeakReference *reference = objc_getAssociatedObject(object, key);
    return [[reference load] autorelease];
}

static dispatch_queue_t CBQueueFor(id object)
{
    dispatch_queue_t queue = (dispatch_queue_t)CBGet(object, &CBManagerQueueKey);
    return queue ? queue : dispatch_get_main_queue();
}

static void CBNotifyState(id object, id delegate, BOOL central)
{
    if (!delegate) return;
    void *delegateIdentity = delegate;
    dispatch_async(CBQueueFor(object), ^{
        id currentDelegate = CBGetWeak(object, &CBManagerDelegateKey);
        if ((void *)currentDelegate != delegateIdentity) return;
        if (central) {
            if ([currentDelegate respondsToSelector:@selector(centralManagerDidUpdateState:)])
                [currentDelegate centralManagerDidUpdateState:object];
        } else if ([currentDelegate respondsToSelector:@selector(peripheralManagerDidUpdateState:)])
            [currentDelegate peripheralManagerDidUpdateState:object];
    });
}

@implementation CBManager

- (CBManagerState)state { return CBManagerStateUnsupported; }

+ (CBManagerAuthorization)authorization
{
    return CBManagerAuthorizationNotDetermined;
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation CBCentralManager

- (instancetype)init { return [self initWithDelegate:nil queue:nil options:nil]; }

- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)delegate queue:(dispatch_queue_t)queue
{
    return [self initWithDelegate:delegate queue:queue options:nil];
}

- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)delegate queue:(dispatch_queue_t)queue options:(NSDictionary *)options
{
    (void)options;
    self = CBManagerBaseInit(self);
    if (self) {
        CBSetWeak(self, &CBManagerDelegateKey, delegate);
        if (queue) CBSet(self, &CBManagerQueueKey, (id)queue);
        CBSet(self, &CBManagerCentralKey, [NSMutableArray array]);
        CBNotifyState(self, delegate, YES);
    }
    return self;
}

- (id<CBCentralManagerDelegate>)delegate { return CBGetWeak(self, &CBManagerDelegateKey); }
- (void)setDelegate:(id<CBCentralManagerDelegate>)delegate
{
    CBSetWeak(self, &CBManagerDelegateKey, delegate);
    CBNotifyState(self, delegate, YES);
}
- (BOOL)isScanning { return NO; }
+ (BOOL)supportsFeatures:(CBCentralManagerFeature)features { (void)features; return NO; }
- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray *)identifiers { (void)identifiers; return [NSArray array]; }
- (NSArray *)retrieveConnectedPeripheralsWithServices:(NSArray *)services { (void)services; return [NSArray array]; }
- (void)scanForPeripheralsWithServices:(NSArray *)serviceUUIDs options:(NSDictionary *)options { (void)serviceUUIDs; (void)options; }
- (void)stopScan {}
- (void)connectPeripheral:(CBPeripheral *)peripheral options:(NSDictionary *)options
{
    (void)options;
    id delegate = self.delegate;
    if (!delegate) return;
    void *delegateIdentity = delegate;
    dispatch_async(CBQueueFor(self), ^{
        id currentDelegate = self.delegate;
        if ((void *)currentDelegate != delegateIdentity) return;
        if ([currentDelegate respondsToSelector:@selector(centralManager:didFailToConnectPeripheral:error:)])
            [currentDelegate centralManager:self didFailToConnectPeripheral:peripheral error:CBUnsupportedError()];
    });
}
- (void)cancelPeripheralConnection:(CBPeripheral *)peripheral { (void)peripheral; }
- (void)registerForConnectionEventsWithOptions:(NSDictionary *)options { (void)options; }

@end

@implementation CBPeripheralManager

- (instancetype)init { return [self initWithDelegate:nil queue:nil options:nil]; }

- (instancetype)initWithDelegate:(id<CBPeripheralManagerDelegate>)delegate queue:(dispatch_queue_t)queue
{
    return [self initWithDelegate:delegate queue:queue options:nil];
}

- (instancetype)initWithDelegate:(id<CBPeripheralManagerDelegate>)delegate queue:(dispatch_queue_t)queue options:(NSDictionary *)options
{
    (void)options;
    self = CBManagerBaseInit(self);
    if (self) {
        CBSetWeak(self, &CBManagerDelegateKey, delegate);
        if (queue) CBSet(self, &CBManagerQueueKey, (id)queue);
        CBSet(self, &CBManagerPeripheralKey, [NSMutableArray array]);
        CBSet(self, &CBManagerCommandQueueKey, [NSMutableArray array]);
        CBNotifyState(self, delegate, NO);
    }
    return self;
}

- (id<CBPeripheralManagerDelegate>)delegate { return CBGetWeak(self, &CBManagerDelegateKey); }
- (void)setDelegate:(id<CBPeripheralManagerDelegate>)delegate
{
    CBSetWeak(self, &CBManagerDelegateKey, delegate);
    CBNotifyState(self, delegate, NO);
}
- (BOOL)isAdvertising { return NO; }
+ (CBPeripheralManagerAuthorizationStatus)authorizationStatus { return CBPeripheralManagerAuthorizationStatusAuthorized; }

- (void)startAdvertising:(NSDictionary *)advertisementData
{
    (void)advertisementData;
    id delegate = self.delegate;
    if (!delegate) return;
    void *delegateIdentity = delegate;
    dispatch_async(CBQueueFor(self), ^{
        id currentDelegate = self.delegate;
        if ((void *)currentDelegate != delegateIdentity) return;
        if ([currentDelegate respondsToSelector:@selector(peripheralManagerDidStartAdvertising:error:)])
            [currentDelegate peripheralManagerDidStartAdvertising:self error:CBUnsupportedError()];
    });
}
- (void)stopAdvertising {}
- (void)setDesiredConnectionLatency:(CBPeripheralManagerConnectionLatency)latency forCentral:(CBCentral *)central { (void)latency; (void)central; }
- (void)addService:(CBMutableService *)service
{
    id delegate = self.delegate;
    if (!delegate) return;
    void *delegateIdentity = delegate;
    dispatch_async(CBQueueFor(self), ^{
        id currentDelegate = self.delegate;
        if ((void *)currentDelegate != delegateIdentity) return;
        if ([currentDelegate respondsToSelector:@selector(peripheralManager:didAddService:error:)])
            [currentDelegate peripheralManager:self didAddService:service error:CBUnsupportedError()];
    });
}
- (void)removeService:(CBMutableService *)service { (void)service; }
- (void)removeAllServices { [(NSMutableArray *)CBGet(self, &CBManagerPeripheralKey) removeAllObjects]; }
- (void)respondToRequest:(CBATTRequest *)request withResult:(CBATTError)result { (void)request; (void)result; }
- (BOOL)updateValue:(NSData *)value forCharacteristic:(CBMutableCharacteristic *)characteristic onSubscribedCentrals:(NSArray *)centrals
{ (void)value; (void)characteristic; (void)centrals; return NO; }
- (void)publishL2CAPChannelWithEncryption:(BOOL)encryptionRequired
{
    (void)encryptionRequired;
    id delegate = self.delegate;
    if (!delegate) return;
    void *delegateIdentity = delegate;
    dispatch_async(CBQueueFor(self), ^{
        id currentDelegate = self.delegate;
        if ((void *)currentDelegate != delegateIdentity) return;
        if ([currentDelegate respondsToSelector:@selector(peripheralManager:didPublishL2CAPChannel:error:)])
            [currentDelegate peripheralManager:self didPublishL2CAPChannel:0 error:CBUnsupportedError()];
    });
}
- (void)unpublishL2CAPChannel:(CBL2CAPPSM)PSM { (void)PSM; }

@end

@implementation CBL2CAPChannel

- (instancetype)init
{
    [self release];
    return nil;
}

- (NSInputStream *)inputStream { return nil; }
- (NSOutputStream *)outputStream { return nil; }
- (CBPeripheral *)peer { return nil; }
- (CBL2CAPPSM)PSM { return 0; }

@end

#pragma clang diagnostic pop

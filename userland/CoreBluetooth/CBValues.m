// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CBInternal.h"

NSString * const CBErrorDomain = @"CBErrorDomain";
NSString * const CBATTErrorDomain = @"CBATTErrorDomain";

NSString * const CBAdvertisementDataIsConnectable = @"kCBAdvDataIsConnectable";
NSString * const CBAdvertisementDataLocalNameKey = @"kCBAdvDataLocalName";
NSString * const CBAdvertisementDataManufacturerDataKey = @"kCBAdvDataManufacturerData";
NSString * const CBAdvertisementDataOverflowServiceUUIDsKey = @"kCBAdvDataHashedServiceUUIDs";
NSString * const CBAdvertisementDataServiceDataKey = @"kCBAdvDataServiceData";
NSString * const CBAdvertisementDataServiceUUIDsKey = @"kCBAdvDataServiceUUIDs";
NSString * const CBAdvertisementDataSolicitedServiceUUIDsKey = @"kCBAdvDataSolicitedServiceUUIDs";
NSString * const CBAdvertisementDataTxPowerLevelKey = @"kCBAdvDataTxPowerLevel";
NSString * const CBCentralManagerOptionRestoreIdentifierKey = @"kCBInitOptionRestoreIdentifier";
NSString * const CBCentralManagerOptionShowPowerAlertKey = @"kCBInitOptionShowPowerAlert";
NSString * const CBCentralManagerRestoredStatePeripheralsKey = @"kCBRestoredPeripherals";
NSString * const CBCentralManagerRestoredStateScanOptionsKey = @"kCBRestoredScanOptions";
NSString * const CBCentralManagerRestoredStateScanServicesKey = @"kCBRestoredScanServices";
NSString * const CBCentralManagerScanOptionAllowDuplicatesKey = @"kCBScanOptionAllowDuplicates";
NSString * const CBCentralManagerScanOptionSolicitedServiceUUIDsKey = @"kCBScanOptionSolicitedServiceUUIDs";
NSString * const CBConnectPeripheralOptionEnableAutoReconnect = @"kCBConnectOptionAutoReconnect";
NSString * const CBConnectPeripheralOptionNotifyOnConnectionKey = @"kCBConnectOptionNotifyOnConnection";
NSString * const CBConnectPeripheralOptionNotifyOnDisconnectionKey = @"kCBConnectOptionNotifyOnDisconnection";
NSString * const CBConnectPeripheralOptionNotifyOnNotificationKey = @"kCBConnectOptionNotifyOnNotification";
NSString * const CBConnectPeripheralOptionStartDelayKey = @"kCBConnectOptionStartDelay";
NSString * const CBPeripheralManagerOptionRestoreIdentifierKey = @"kCBInitOptionRestoreIdentifier";
NSString * const CBPeripheralManagerOptionShowPowerAlertKey = @"kCBInitOptionShowPowerAlert";
NSString * const CBPeripheralManagerRestoredStateAdvertisementDataKey = @"kCBRestoredAdvertisement";
NSString * const CBPeripheralManagerRestoredStateServicesKey = @"kCBRestoredServices";

static char CBAttributeUUIDKey;
static char CBServicePeripheralKey;
static char CBServicePrimaryKey;
static char CBServiceIncludedKey;
static char CBServiceCharacteristicsKey;
static char CBCharacteristicServiceKey;
static char CBCharacteristicPropertiesKey;
static char CBCharacteristicPermissionsKey;
static char CBCharacteristicValueKey;
static char CBCharacteristicDescriptorsKey;
static char CBCharacteristicBroadcastKey;
static char CBCharacteristicNotifyingKey;
static char CBDescriptorCharacteristicKey;
static char CBDescriptorValueKey;

void CBSet(id object, const void *key, id value)
{
    objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

id CBGet(id object, const void *key)
{
    return objc_getAssociatedObject(object, key);
}

@implementation CBAttribute

- (instancetype)_initWithUUID:(CBUUID *)UUID
{
    self = [super init];
    if (self) CBSet(self, &CBAttributeUUIDKey, UUID);
    return self;
}

- (CBUUID *)UUID { return CBGet(self, &CBAttributeUUIDKey); }

@end

@implementation CBService

- (CBPeripheral *)peripheral { return CBGet(self, &CBServicePeripheralKey); }
- (BOOL)isPrimary { return [CBGet(self, &CBServicePrimaryKey) boolValue]; }
- (NSArray *)includedServices { return CBGet(self, &CBServiceIncludedKey); }
- (NSArray *)characteristics { return CBGet(self, &CBServiceCharacteristicsKey); }

@end

@implementation CBMutableService

- (instancetype)initWithType:(CBUUID *)UUID primary:(BOOL)isPrimary
{
    if (!UUID) { [self release]; return nil; }
    self = [super _initWithUUID:UUID];
    if (self) CBSet(self, &CBServicePrimaryKey, [NSNumber numberWithBool:isPrimary]);
    return self;
}

- (void)setIncludedServices:(NSArray *)services
{
    for (id service in services)
        if (![service isKindOfClass:[CBService class]]) [NSException raise:NSInvalidArgumentException format:@"Included services must be CBService objects"];
    CBSet(self, &CBServiceIncludedKey, services);
}

- (void)setCharacteristics:(NSArray *)characteristics
{
    for (id characteristic in characteristics)
        if (![characteristic isKindOfClass:[CBCharacteristic class]]) [NSException raise:NSInvalidArgumentException format:@"Characteristics must be CBCharacteristic objects"];
    CBSet(self, &CBServiceCharacteristicsKey, characteristics);
}

@end

@implementation CBCharacteristic

- (CBService *)service { return CBGet(self, &CBCharacteristicServiceKey); }
- (CBCharacteristicProperties)properties { return [CBGet(self, &CBCharacteristicPropertiesKey) unsignedIntegerValue]; }
- (NSData *)value { return CBGet(self, &CBCharacteristicValueKey); }
- (NSArray *)descriptors { return CBGet(self, &CBCharacteristicDescriptorsKey); }
- (BOOL)isBroadcasted { return [CBGet(self, &CBCharacteristicBroadcastKey) boolValue]; }
- (BOOL)isNotifying { return [CBGet(self, &CBCharacteristicNotifyingKey) boolValue]; }
- (NSArray *)subscribedCentrals { return nil; }

@end

@implementation CBMutableCharacteristic

- (instancetype)initWithType:(CBUUID *)UUID properties:(CBCharacteristicProperties)properties
    value:(NSData *)value permissions:(CBAttributePermissions)permissions
{
    if (!UUID) { [self release]; return nil; }
    self = [super _initWithUUID:UUID];
    if (self) {
        CBSet(self, &CBCharacteristicPropertiesKey, [NSNumber numberWithUnsignedInteger:properties]);
        CBSet(self, &CBCharacteristicValueKey, value);
        CBSet(self, &CBCharacteristicPermissionsKey, [NSNumber numberWithUnsignedInteger:permissions]);
    }
    return self;
}

- (CBAttributePermissions)permissions { return [CBGet(self, &CBCharacteristicPermissionsKey) unsignedIntegerValue]; }
- (void)setPermissions:(CBAttributePermissions)value { CBSet(self, &CBCharacteristicPermissionsKey, [NSNumber numberWithUnsignedInteger:value]); }
- (void)setProperties:(CBCharacteristicProperties)value { CBSet(self, &CBCharacteristicPropertiesKey, [NSNumber numberWithUnsignedInteger:value]); }
- (void)setValue:(NSData *)value
{
    if (value && ![value isKindOfClass:[NSData class]]) [NSException raise:NSInvalidArgumentException format:@"Characteristic values must be data"];
    CBSet(self, &CBCharacteristicValueKey, value);
}
- (void)setDescriptors:(NSArray *)descriptors
{
    for (id descriptor in descriptors)
        if (![descriptor isKindOfClass:[CBDescriptor class]]) [NSException raise:NSInvalidArgumentException format:@"Descriptors must be CBDescriptor objects"];
    CBSet(self, &CBCharacteristicDescriptorsKey, descriptors);
}

@end

@implementation CBDescriptor

- (CBCharacteristic *)characteristic { return CBGet(self, &CBDescriptorCharacteristicKey); }
- (id)value { return CBGet(self, &CBDescriptorValueKey); }

@end

@implementation CBMutableDescriptor

- (instancetype)initWithType:(CBUUID *)UUID value:(id)value
{
    if (!UUID) { [self release]; return nil; }
    self = [super _initWithUUID:UUID];
    if (self) CBSet(self, &CBDescriptorValueKey, value);
    return self;
}

@end

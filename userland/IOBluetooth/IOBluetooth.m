/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IOBluetooth. Finch has no Bluetooth driver yet, so there's no host controller, as on
 * a Mac without Bluetooth: no controller, no paired or recent devices, inquiries end at
 * once with kIOReturnNotAttached, and connections can't be opened. Device objects made
 * from an address work as values (address, name), and the address utilities work.
 */
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

@interface NSObject (FinchBTInit)
- (instancetype)_finchInit __attribute__((objc_method_family(init)));
@end
@implementation NSObject (FinchBTInit)
- (instancetype)_finchInit { return [self init]; }
@end

/* --- addresses --- */

NSString *
IOBluetoothNSStringFromDeviceAddress(const BluetoothDeviceAddress *a)
{
    if (!a)
        return nil;
    return [NSString stringWithFormat:@"%02x-%02x-%02x-%02x-%02x-%02x", a->data[0], a->data[1], a->data[2], a->data[3], a->data[4],
                                      a->data[5]];
}

NSString *
IOBluetoothNSStringFromDeviceAddressColon(const BluetoothDeviceAddress *a)
{
    if (!a)
        return nil;
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", a->data[0], a->data[1], a->data[2], a->data[3], a->data[4],
                                      a->data[5]];
}

IOReturn
IOBluetoothNSStringToDeviceAddress(NSString *s, BluetoothDeviceAddress *out)
{
    unsigned v[6];
    if (!s || !out)
        return kIOReturnBadArgument;
    const char *c = s.UTF8String;
    if (sscanf(c, "%2x%*[-:]%2x%*[-:]%2x%*[-:]%2x%*[-:]%2x%*[-:]%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6 &&
        sscanf(c, "%2x%2x%2x%2x%2x%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
        return kIOReturnBadArgument;
    for (int i = 0; i < 6; i++)
        out->data[i] = (UInt8)v[i];
    return kIOReturnSuccess;
}


/* --- devices --- */

@implementation IOBluetoothObject
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation IOBluetoothDevice {
    BluetoothDeviceAddress _finchAddress;
    NSString *_finchName;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)deviceWithAddress:(const BluetoothDeviceAddress *)address
{
    if (!address)
        return nil;
    IOBluetoothDevice *d = [[self alloc] _finchInit];
    d->_finchAddress = *address;
    return d;
}

+ (instancetype)withAddress:(const BluetoothDeviceAddress *)address { return [self deviceWithAddress:address]; }

+ (instancetype)deviceWithAddressString:(NSString *)address
{
    BluetoothDeviceAddress a;
    return IOBluetoothNSStringToDeviceAddress(address, &a) == kIOReturnSuccess ? [self deviceWithAddress:&a] : nil;
}

+ (NSArray *)pairedDevices { return @[]; }
+ (NSArray *)favoriteDevices { return @[]; }
+ (NSArray *)recentDevices:(NSUInteger)numDevices { return @[]; }
+ (IOBluetoothUserNotification *)registerForConnectNotifications:(id)observer selector:(SEL)inSelector { return nil; }
- (IOBluetoothUserNotification *)registerForDisconnectNotification:(id)observer selector:(SEL)inSelector { return nil; }

- (const BluetoothDeviceAddress *)getAddress { return &_finchAddress; }
- (NSString *)addressString { return IOBluetoothNSStringFromDeviceAddress(&_finchAddress); }
- (NSString *)getAddressString { return [self addressString]; }
- (NSString *)name { return _finchName; }
- (NSString *)getName { return _finchName; }
- (NSString *)nameOrAddress { return _finchName ?: [self addressString]; }
- (NSString *)getNameOrAddress { return [self nameOrAddress]; }
- (NSDate *)getLastNameUpdate { return nil; }
- (NSDate *)lastNameUpdate { return nil; }
- (NSDate *)recentAccessDate { return nil; }
- (NSDate *)getLastInquiryUpdate { return nil; }
- (BluetoothClassOfDevice)classOfDevice { return 0; }
- (BluetoothClassOfDevice)getClassOfDevice { return 0; }
- (BluetoothServiceClassMajor)serviceClassMajor { return 0; }
- (BluetoothDeviceClassMajor)deviceClassMajor { return 0; }
- (BluetoothDeviceClassMinor)deviceClassMinor { return 0; }
- (BluetoothHCIRSSIValue)RSSI { return 127; }
- (BluetoothHCIRSSIValue)rawRSSI { return 127; }
- (BOOL)isConnected { return NO; }
- (BOOL)isPaired { return NO; }
- (BOOL)isFavorite { return NO; }
- (BOOL)isIncoming { return NO; }
- (NSArray *)services { return nil; }
- (IOReturn)openConnection { return kIOReturnNotAttached; }
- (IOReturn)openConnection:(id)target { return kIOReturnNotAttached; }
- (IOReturn)openConnection:(id)target withPageTimeout:(BluetoothHCIPageTimeout)t authenticationRequired:(BOOL)a { return kIOReturnNotAttached; }
- (IOReturn)closeConnection { return kIOReturnSuccess; }
- (IOReturn)remoteNameRequest:(id)target { return kIOReturnNotAttached; }
- (IOReturn)remoteNameRequest:(id)target withPageTimeout:(BluetoothHCIPageTimeout)t { return kIOReturnNotAttached; }
- (IOReturn)requestAuthentication { return kIOReturnNotAttached; }
- (IOReturn)performSDPQuery:(id)target { return kIOReturnNotAttached; }
- (IOReturn)performSDPQuery:(id)target uuids:(NSArray *)uuidArray { return kIOReturnNotAttached; }
- (IOReturn)addToFavorites { return kIOReturnNotAttached; }
- (IOReturn)removeFromFavorites { return kIOReturnSuccess; }
- (IOReturn)openL2CAPChannelSync:(IOBluetoothL2CAPChannel **)c withPSM:(BluetoothL2CAPPSM)psm delegate:(id)d { return kIOReturnNotAttached; }
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)c withPSM:(BluetoothL2CAPPSM)psm delegate:(id)d { return kIOReturnNotAttached; }
- (IOReturn)openRFCOMMChannelSync:(IOBluetoothRFCOMMChannel **)c withChannelID:(BluetoothRFCOMMChannelID)i delegate:(id)d
{
    return kIOReturnNotAttached;
}
- (IOReturn)openRFCOMMChannelAsync:(IOBluetoothRFCOMMChannel **)c withChannelID:(BluetoothRFCOMMChannelID)i delegate:(id)d
{
    return kIOReturnNotAttached;
}
- (IOBluetoothSDPServiceRecord *)getServiceRecordForUUID:(IOBluetoothSDPUUID *)sdpUUID { return nil; }
- (NSUInteger)hash { return (NSUInteger)_finchAddress.data[5] | (NSUInteger)_finchAddress.data[4] << 8; }
- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[IOBluetoothDevice class]] && !memcmp(&_finchAddress, [other getAddress], sizeof _finchAddress);
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeBytes:_finchAddress.data length:6 forKey:@"address"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super _finchInit])) {
        NSUInteger n = 0;
        const uint8_t *b = [coder decodeBytesForKey:@"address" returnedLength:&n];
        if (b && n == 6)
            memcpy(_finchAddress.data, b, 6);
    }
    return self;
}

@end

/* --- the host controller: none --- */

@implementation IOBluetoothHostController
+ (instancetype)defaultController { return nil; }
- (BluetoothHCIPowerState)powerState { return kBluetoothHCIPowerStateOFF; }
- (BluetoothClassOfDevice)classOfDevice { return 0; }
- (NSString *)addressAsString { return nil; }
- (NSString *)nameAsString { return nil; }
- (IOReturn)setClassOfDevice:(BluetoothClassOfDevice)c forTimeInterval:(NSTimeInterval)s { return kIOReturnNotAttached; }
@end

@implementation IOBluetoothDeviceInquiry {
    __weak id _finchDelegate;
    NSTimeInterval _finchLength;
    BOOL _finchUpdateNames;
}

+ (instancetype)inquiryWithDelegate:(id)delegate { return [[self alloc] initWithDelegate:delegate]; }

- (instancetype)initWithDelegate:(id)delegate
{
    if ((self = [super init])) {
        _finchDelegate = delegate;
        _finchLength = 10;
        _finchUpdateNames = YES;
    }
    return self;
}

- (id)delegate { return _finchDelegate; }
- (void)setDelegate:(id)d { _finchDelegate = d; }
- (uint8_t)inquiryLength { return (uint8_t)_finchLength; }
- (void)setInquiryLength:(uint8_t)l { _finchLength = l; }
- (BOOL)updateNewDeviceNames { return _finchUpdateNames; }
- (void)setUpdateNewDeviceNames:(BOOL)v { _finchUpdateNames = v; }

/* No controller: the inquiry ends at once. */
- (IOReturn)start
{
    id d = _finchDelegate;
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([d respondsToSelector:@selector(deviceInquiryComplete:error:aborted:)])
          [d deviceInquiryComplete:self error:kIOReturnNotAttached aborted:NO];
    });
    return kIOReturnNotAttached;
}

- (IOReturn)stop { return kIOReturnSuccess; }
- (NSArray *)foundDevices { return @[]; }
- (void)clearFoundDevices {}
- (void)setSearchCriteria:(BluetoothServiceClassMajor)s majorDeviceClass:(BluetoothDeviceClassMajor)ma minorDeviceClass:(BluetoothDeviceClassMinor)mi
{
}
@end

/* --- channels, SDP and OBEX: value objects only, with no controller to use them --- */

@implementation IOBluetoothL2CAPChannel
- (IOReturn)closeChannel { return kIOReturnSuccess; }
- (BluetoothL2CAPMTU)outgoingMTU { return 0; }
- (BluetoothL2CAPMTU)incomingMTU { return 0; }
- (IOBluetoothDevice *)device { return nil; }
- (BOOL)isIncoming { return NO; }
- (IOReturn)writeSync:(void *)data length:(UInt16)length { return kIOReturnNotAttached; }
- (IOReturn)writeAsync:(void *)data length:(UInt16)length refcon:(void *)refcon { return kIOReturnNotAttached; }
@end

@implementation IOBluetoothRFCOMMChannel
- (IOReturn)closeChannel { return kIOReturnSuccess; }
- (BOOL)isOpen { return NO; }
- (BluetoothRFCOMMMTU)getMTU { return 0; }
- (IOBluetoothDevice *)getDevice { return nil; }
- (BluetoothRFCOMMChannelID)getChannelID { return 0; }
- (BOOL)isIncoming { return NO; }
- (IOReturn)writeSync:(void *)data length:(UInt16)length { return kIOReturnNotAttached; }
- (IOReturn)writeAsync:(void *)data length:(UInt16)length refcon:(void *)refcon { return kIOReturnNotAttached; }
@end

@implementation IOBluetoothSDPUUID
+ (instancetype)uuidWithBytes:(const void *)bytes length:(unsigned)length
{
    return [self dataWithBytes:bytes length:length];
}
+ (instancetype)uuidWithData:(NSData *)data { return [self dataWithData:data]; }
+ (instancetype)uuid16:(BluetoothSDPUUID16)uuid16
{
    uint8_t b[2] = {(uint8_t)(uuid16 >> 8), (uint8_t)uuid16};
    return [self dataWithBytes:b length:2];
}
+ (instancetype)uuid32:(BluetoothSDPUUID32)uuid32
{
    uint8_t b[4] = {(uint8_t)(uuid32 >> 24), (uint8_t)(uuid32 >> 16), (uint8_t)(uuid32 >> 8), (uint8_t)uuid32};
    return [self dataWithBytes:b length:4];
}
- (BOOL)isEqualToUUID:(IOBluetoothSDPUUID *)otherUUID { return [self isEqualToData:otherUUID]; }
@end

@implementation IOBluetoothSDPServiceRecord
@dynamic sortedAttributes;
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super _finchInit]; }
- (NSArray *)sortedAttributes { return @[]; }
- (IOBluetoothDevice *)device { return nil; }
- (NSDictionary *)attributes { return @{}; }
- (NSString *)getServiceName { return nil; }
@end

@implementation IOBluetoothUserNotification
- (void)unregister {}
@end

@implementation OBEXSession
@end

@implementation IOBluetoothOBEXSession
+ (instancetype)withSDPServiceRecord:(IOBluetoothSDPServiceRecord *)inSDPServiceRecord { return nil; }
+ (instancetype)withDevice:(IOBluetoothDevice *)inDevice channelID:(BluetoothRFCOMMChannelID)inRFCOMMChannelID { return nil; }
@end

@implementation OBEXFileTransferServices
+ (instancetype)withOBEXSession:(IOBluetoothOBEXSession *)inOBEXSession { return nil; }
- (BOOL)isConnected { return NO; }
- (BOOL)isBusy { return NO; }
- (OBEXError)connectToFTPService { return kOBEXSessionNotConnectedError; }
- (OBEXError)connectToObjectPushService { return kOBEXSessionNotConnectedError; }
- (OBEXError)disconnect { return kOBEXSuccess; }
@end

/* Private pieces apps link: Bluetooth's preferences and lower-level calls. */
@interface IOBluetoothPreferences : NSObject
@end
@implementation IOBluetoothPreferences
@end

void IOBluetoothPreferenceSetControllerPowerState(int state) {}
int IOBluetoothPreferenceGetControllerPowerState(void) { return 0; }
void *IOBluetoothNotificationLibNotificationCreate(void *a, void *b, void *c) { return NULL; }
void IOBluetoothNotificationLibNotificationDelete(void *n) {}

CFArrayRef
OBEXFolderListingCreateFromFile(CFURLRef url)
{
    return NULL;
}

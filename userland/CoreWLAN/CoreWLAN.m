/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreWLAN. Finch has no Wi-Fi driver yet, so the system has no Wi-Fi interface, as a
 * Mac with none (a Mac mini on Ethernet with Wi-Fi removed): the client lists no
 * interfaces, event monitoring succeeds and reports nothing, and the keychain calls
 * find no stored passwords. The value classes (networks, channels, configurations,
 * profiles) work.
 */
#import <CoreWLAN/CoreWLAN.h>
#import <Foundation/Foundation.h>

@implementation CWWiFiClient {
    __weak id _delegate;
}

+ (CWWiFiClient *)sharedWiFiClient
{
    static CWWiFiClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [[CWWiFiClient alloc] init]; });
    return client;
}

- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }
- (CWInterface *)interface { return nil; }
- (NSArray<NSString *> *)interfaceNames { return @[]; }
+ (NSArray<NSString *> *)interfaceNames { return @[]; }
- (CWInterface *)interfaceWithName:(NSString *)interfaceName { return nil; }
- (NSArray<CWInterface *> *)interfaces { return @[]; }
- (BOOL)startMonitoringEventWithType:(CWEventType)type error:(NSError **)error { return YES; }
- (BOOL)stopMonitoringEventWithType:(CWEventType)type error:(NSError **)error { return YES; }
- (BOOL)stopMonitoringAllEventsAndReturnError:(NSError **)error { return YES; }

@end

@implementation CWInterface
+ (NSArray<NSString *> *)interfaceNames { return @[]; }
+ (instancetype)interface { return nil; }
+ (instancetype)interfaceWithName:(NSString *)name { return nil; }
- (NSString *)interfaceName { return nil; }
- (BOOL)powerOn { return NO; }
- (BOOL)serviceActive { return NO; }
- (NSString *)ssid { return nil; }
- (NSData *)ssidData { return nil; }
- (NSString *)bssid { return nil; }
- (NSInteger)rssiValue { return 0; }
- (NSInteger)noiseMeasurement { return 0; }
- (double)transmitRate { return 0; }
- (NSInteger)transmitPower { return 0; }
- (NSString *)hardwareAddress { return nil; }
- (NSString *)countryCode { return nil; }
- (CWChannel *)wlanChannel { return nil; }
- (CWConfiguration *)configuration { return nil; }
- (NSSet<CWNetwork *> *)scanForNetworksWithName:(NSString *)networkName error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:CWErrorDomain code:kCWNotSupportedErr userInfo:nil];
    return nil;
}
- (NSSet<CWNetwork *> *)scanForNetworksWithSSID:(NSData *)ssid error:(NSError **)error
{
    return [self scanForNetworksWithName:nil error:error];
}
- (NSSet<CWNetwork *> *)cachedScanResults { return nil; }
- (BOOL)setPower:(BOOL)power error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:CWErrorDomain code:kCWNotSupportedErr userInfo:nil];
    return NO;
}
- (BOOL)associateToNetwork:(CWNetwork *)network password:(NSString *)password error:(NSError **)error
{
    return [self setPower:YES error:error];
}
- (void)disassociate {}
@end

@implementation CWNetwork
+ (BOOL)supportsSecureCoding { return YES; }
- (NSString *)ssid { return nil; }
- (NSData *)ssidData { return nil; }
- (NSString *)bssid { return nil; }
- (CWChannel *)wlanChannel { return nil; }
- (NSInteger)rssiValue { return 0; }
- (NSInteger)noiseMeasurement { return 0; }
- (NSData *)informationElementData { return nil; }
- (NSString *)countryCode { return nil; }
- (NSInteger)beaconInterval { return 0; }
- (BOOL)ibss { return NO; }
- (BOOL)supportsSecurity:(CWSecurity)security { return NO; }
- (BOOL)supportsPHYMode:(CWPHYMode)phyMode { return NO; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (BOOL)isEqualToNetwork:(CWNetwork *)network { return [self isEqual:network]; }
@end

@implementation CWChannel
+ (BOOL)supportsSecureCoding { return YES; }
- (NSInteger)channelNumber { return 0; }
- (CWChannelWidth)channelWidth { return kCWChannelWidthUnknown; }
- (CWChannelBand)channelBand { return kCWChannelBandUnknown; }
- (BOOL)isEqualToChannel:(CWChannel *)channel { return [self isEqual:channel]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end

@implementation CWConfiguration
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)configuration { return [[self alloc] init]; }
+ (instancetype)configurationWithConfiguration:(CWConfiguration *)configuration { return [[self alloc] init]; }
- (instancetype)initWithConfiguration:(CWConfiguration *)configuration { return [self init]; }
- (NSOrderedSet<CWNetworkProfile *> *)networkProfiles { return [NSOrderedSet orderedSet]; }
- (BOOL)requireAdministratorForAssociation { return NO; }
- (BOOL)requireAdministratorForPower { return NO; }
- (BOOL)requireAdministratorForIBSSMode { return NO; }
- (BOOL)rememberJoinedNetworks { return YES; }
- (BOOL)isEqualToConfiguration:(CWConfiguration *)configuration { return YES; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [CWMutableConfiguration new]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end

@implementation CWMutableConfiguration
- (void)setNetworkProfiles:(NSOrderedSet<CWNetworkProfile *> *)networkProfiles {}
- (void)setRequireAdministratorForAssociation:(BOOL)v {}
- (void)setRequireAdministratorForPower:(BOOL)v {}
- (void)setRequireAdministratorForIBSSMode:(BOOL)v {}
- (void)setRememberJoinedNetworks:(BOOL)v {}
@end

@implementation CWNetworkProfile {
    @protected
    NSData *_finchSSID;
    CWSecurity _finchSecurity;
}
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)networkProfile { return [[self alloc] init]; }
+ (instancetype)networkProfileWithNetworkProfile:(CWNetworkProfile *)networkProfile
{
    return [[self alloc] initWithNetworkProfile:networkProfile];
}
- (instancetype)initWithNetworkProfile:(CWNetworkProfile *)networkProfile
{
    if ((self = [super init])) {
        _finchSSID = networkProfile.ssidData;
        _finchSecurity = networkProfile.security;
    }
    return self;
}
- (NSString *)ssid { return _finchSSID ? [[NSString alloc] initWithData:_finchSSID encoding:NSUTF8StringEncoding] : nil; }
- (NSData *)ssidData { return _finchSSID; }
- (CWSecurity)security { return _finchSecurity; }
- (BOOL)isEqualToNetworkProfile:(CWNetworkProfile *)networkProfile { return [_finchSSID isEqual:networkProfile.ssidData]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [[CWMutableNetworkProfile alloc] initWithNetworkProfile:self]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_finchSSID forKey:@"ssid"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        _finchSSID = [coder decodeObjectOfClass:[NSData class] forKey:@"ssid"];
    return self;
}
@end

@implementation CWMutableNetworkProfile
- (void)setSsidData:(NSData *)ssidData { _finchSSID = [ssidData copy]; }
- (void)setSecurity:(CWSecurity)security { _finchSecurity = security; }
@end

/* --- the keychain: no Wi-Fi passwords stored --- */

OSStatus CWKeychainFindWiFiPassword(CWKeychainDomain domain, NSData *ssid, NSString **password) { return errSecItemNotFound; }
OSStatus CWKeychainSetWiFiPassword(CWKeychainDomain domain, NSData *ssid, NSString *password) { return errSecNotAvailable; }
OSStatus CWKeychainDeleteWiFiPassword(CWKeychainDomain domain, NSData *ssid) { return errSecItemNotFound; }
OSStatus CWKeychainFindWiFiEAPUsernameAndPassword(CWKeychainDomain domain, NSData *ssid, NSString **username, NSString **password)
{
    return errSecItemNotFound;
}
OSStatus CWKeychainSetWiFiEAPUsernameAndPassword(CWKeychainDomain domain, NSData *ssid, NSString *username, NSString *password)
{
    return errSecNotAvailable;
}
OSStatus CWKeychainDeleteWiFiEAPUsernameAndPassword(CWKeychainDomain domain, NSData *ssid) { return errSecItemNotFound; }
OSStatus CWKeychainCopyWiFiEAPIdentity(CWKeychainDomain domain, NSData *ssid, SecIdentityRef *identity) { return errSecItemNotFound; }
OSStatus CWKeychainSetWiFiEAPIdentity(CWKeychainDomain domain, NSData *ssid, SecIdentityRef identity) { return errSecNotAvailable; }

NSSet<CWNetwork *> *
CWMergeNetworks(NSSet<CWNetwork *> *networks)
{
    return networks;
}

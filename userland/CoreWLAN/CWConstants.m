/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreWLAN's exported constants, with the values Apple's have (tools/gen-constants.py). */
#import <Foundation/Foundation.h>

NSString *const Apple80211APIErrorDomain = @"com.apple.wifi.apple80211API.error";
NSString *const CWBSSIDDidChangeNotification = @"com.apple.coreWLAN.notification.bssid";
NSString *const CWBaseStationPPPCallTypeKey = @"PPPCallType";
NSString *const CWBaseStationPPPConnectionSpeedKey = @"PPPConnectionSpeed";
NSString *const CWBaseStationPPPConnectionStatusKey = @"PPPConnectionStatus";
NSString *const CWBaseStationPPPConnectionTimeKey = @"PPPConnectionTime";
NSString *const CWBaseStationPPPHardwareTypeKey = @"PPPHardwareType";
NSString *const CWBaseStationPPPPhoneNumberKey = @"PPPPhoneNumber";
NSString *const CWBaseStationPPPProtocolKey = @"PPPProtocol";
NSString *const CWBaseStationPPPRemainingTimeKey = @"PPPRemainingTime";
NSString *const CWBaseStationPPPStatusDidChangeNotification = @"com.apple.coreWLAN.notification.ppp";
NSString *const CWCountryCodeDidChangeNotification = @"com.apple.coreWLAN.notification.countryCode";
NSString *const CWDHCPStatusDidChangeNotification = @"com.apple.coreWLAN.notification.dhcp";
NSString *const CWDeviceDidAttachNotification = @"com.apple.coreWLAN.notification.hardwareAttach";
NSString *const CWDeviceDidDetachNotification = @"com.apple.coreWLAN.notification.hardwareDetach";
NSString *const CWDynamicConfigurationDidChangeNotification = @"com.apple.coreWLAN.notification.configuration";
NSString *const CWErrorDomain = @"com.apple.coreWLAN.error";
NSString *const CWIEEE80211StatusCodeDomain = @"com.apple.CoreWLAN.IEEE80211.StatusCode";
NSString *const CWIPStatusDidChangeNotification = @"com.apple.coreWLAN.notification.ip";
NSString *const CWLinkDidChangeNotification = @"com.apple.coreWLAN.notification.link";
NSString *const CWLinkQualityDidChangeNotification = @"com.apple.coreWLAN.notification.linkQuality";
NSString *const CWLinkQualityNotificationRSSIKey = @"LinkQualityNotificationRSSIKey";
NSString *const CWLinkQualityNotificationTransmitRateKey = @"LinkQualityNotificationTransmitRateKey";
NSString *const CWModeDidChangeNotification = @"com.apple.coreWLAN.notification.mode";
NSString *const CWNetworkReachabilityDidChangeNotification = @"com.apple.coreWLAN.notification.reachability";
NSString *const CWNetworkReachabilityNotificationFlagsKey = @"NetworkReachabilityNotificationFlagsKey";
NSString *const CWPowerDidChangeNotification = @"com.apple.coreWLAN.notification.power";
NSString *const CWRSNHandshakeCompleteNotification = @"com.apple.coreWLAN.notification.RSNHandshake";
NSString *const CWSSIDDidChangeNotification = @"com.apple.coreWLAN.notification.ssid";
NSString *const CWScanCacheDidUpdateNotification = @"com.apple.coreWLAN.notification.scanCache";
NSString *const CWScanDoneNotification = @"com.apple.coreWLAN.notification.scanDone";
NSString *const CWServiceDidChangeNotification = @"com.apple.coreWLAN.notification.service";
NSString *const CoreWLANFrameworkBundleID = @"com.apple.framework.CoreWLAN";
NSString *const EAPOLErrorDomain = @"com.apple.coreWLAN.EAPOL.error";
NSString *const EAPOLSupplicantStateDidChangeNotification = @"com.apple.coreWLAN.notification.EAPOL";
NSString *const WiFiErrorDomain = @"com.apple.wifi.request.error";
NSString *const kCWCountryCodeDidChangeNotification = @"com.apple.coreWLAN.notification.countryCode.legacy";
NSString *const kCWLinkDidChangeNotification = @"com.apple.coreWLAN.notification.link.legacy";
NSString *const kCWModeDidChangeNotification = @"com.apple.coreWLAN.notification.mode.legacy";
NSString *const kCWPowerDidChangeNotification = @"com.apple.coreWLAN.notification.power.legacy";
NSString *const kCWSSIDDidChangeNotification = @"com.apple.coreWLAN.notification.ssid.legacy";
NSString *const kWiFiAutoJoinPowerDiagnosticsKey = @"AutoJoinPowerDiag";
NSString *const kWiFiNetworkIsAutoJoinedKey = @"WiFiNetworkIsAutoJoined";

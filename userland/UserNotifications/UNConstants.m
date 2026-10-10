/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* UserNotifications's exported constants, with the values Apple's have (tools/gen-constants.py). */
#import <Foundation/Foundation.h>

NSString *const UNErrorDomain = @"UNErrorDomain";
NSString *const UNLogDeveloperAPIDomainDescriptionBadging = @"-[UNUserNotificationCenter setBadgeCount:(NSInteger) error:(NSError *)]";
NSString *const UNLogDeveloperAPIDomainDescriptionCommunication = @"-[UNNotificationContent contentByUpdatingWithProvider:(id<UNNotificationContentProviding>) error:(NSError *)]";
NSString *const UNLogDeveloperAPIDomainDescriptionFirstPartyWarning = @"(<UserNotifications | All>: warning to internal client)";
NSString *const UNNotificationActionTextInputButtonTitleKey = @"UNNotificationActionTextInputButtonTitle";
NSString *const UNNotificationActionTextInputPlaceholderKey = @"UNNotificationActionTextInputPlaceholder";
NSString *const UNNotificationAttachmentOptionsHiddenFromDefaultExpandedViewKey = @"hidden";
NSString *const UNNotificationAttachmentOptionsThumbnailClippingRectKey = @"thumbnailClippingRect";
NSString *const UNNotificationAttachmentOptionsThumbnailHiddenKey = @"thumbnailHidden";
NSString *const UNNotificationAttachmentOptionsThumbnailTimeKey = @"thumbnailTime";
NSString *const UNNotificationAttachmentOptionsTypeHintKey = @"typeHint";
NSString *const UNNotificationAttachmentUserInfoDataKey = @"data";
NSString *const UNNotificationAttachmentUserInfoIdentityImageStyleKey = @"identityImageStyle";
NSString *const UNNotificationAttachmentUserInfoPurposeKey = @"purpose";
NSString *const UNNotificationAttachmentUserInfoRelocationUUIDKey = @"relocationUUID";
NSString *const UNNotificationDefaultActionIdentifier = @"com.apple.UNNotificationDefaultActionIdentifier";
NSString *const UNNotificationDismissActionIdentifier = @"com.apple.UNNotificationDismissActionIdentifier";
NSString *const UNNotificationFollowActivityActionIdentifier = @"com.apple.UNNotificationFollowActivityActionIdentifier";
NSString *const UNNotificationIconCalendarKey = @"NotificationIconCalendarKey";
NSString *const UNNotificationIconDateComponentsKey = @"NotificationIconDateComponents";
NSString *const UNNotificationIconDateFormatKey = @"NotificationIconDateFormatKey";
NSString *const UNNotificationSandboxExtensionClassGenericReadOnly = @"com.apple.app-sandbox.read-only";
NSString *const UNNotificationSandboxExtensionClassGenericReadWrite = @"com.apple.app-sandbox.read-write";
NSString *const UNNotificationSilenceActionIdentifier = @"com.apple.UNNotificationSilenceActionIdentifier";
NSString *const UNOneTimeCodeMachServiceName = @"com.apple.UserNotifications.OneTimeCodeService";
NSString *const UNUserNotificationDaemonServiceName = @"com.apple.usernotifications.listener";
NSString *const UNUserNotificationServiceName = @"com.apple.usernotifications.usernotificationservice";
NSString *const _UNNotificationContentTypeAirDrop = @"UNNotificationContentTypeAirDrop";
NSString *const _UNNotificationContentTypeCallOther = @"UNNotificationContentTypeCallOther";
NSString *const _UNNotificationContentTypeDefault = @"UNNotificationContentTypeDefault";
NSString *const _UNNotificationContentTypeIncomingCall = @"UNNotificationContentTypeIncomingCall";
NSString *const _UNNotificationContentTypeIntercom = @"UNNotificationContentTypeIntercom";
NSString *const _UNNotificationContentTypeMessagingDirect = @"UNNotificationContentTypeMessagingDirect";
NSString *const _UNNotificationContentTypeMessagingGroup = @"UNNotificationContentTypeMessagingGroup";
NSString *const _UNNotificationContentTypeMissedCall = @"UNNotificationContentTypeMissedCall";
NSString *const _UNNotificationContentTypeVoicemail = @"UNNotificationContentTypeVoicemail";
NSString *const kUNResponseContextArchivedUserNotificationKey = @"UNResponseContextArchivedUserNotificationKey";

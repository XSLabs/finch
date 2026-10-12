/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Small exports apps import from AppKit and Foundation: NSStringFromBOOL, _NSFullMethodName,
 * NSRequestConcreteImplementation's exception, the autorelease-pool calls,
 * _NSCenteredRectForImage, UIKit's rounding helpers and a sample of the constants.
 * Compared with Apple's.
 */
#import <AppKit/AppKit.h>

extern NSString *NSStringFromBOOL(BOOL);
extern NSString *_NSFullMethodName(id, SEL);
extern void NSRequestConcreteImplementation(id, SEL, Class);
extern void *NSPushAutoreleasePool(NSUInteger);
extern void NSPopAutoreleasePool(void *);
extern NSRect _NSCenteredRectForImage(NSSize, NSRect, CGFloat);
extern CGRect UIRectIntegralWithScale(CGRect, CGFloat);
extern CGRect UIRectCenteredAboutPointScale(CGRect, CGPoint, CGFloat);
extern BOOL NSColorControlAccentIsDefaultColor(void);
extern NSString *NSMenuDidCompleteInteractionNotification, *NSAppleMenuName, *NSSharingServiceMailExportTextKey;

int
main(void)
{
    @autoreleasepool {
        printf("BOOL: %s %s\n", NSStringFromBOOL(YES).UTF8String, NSStringFromBOOL(NO).UTF8String);
        printf("method names: %s %s\n", _NSFullMethodName(@"x", @selector(length)).UTF8String,
               _NSFullMethodName([NSArray class], @selector(array)).UTF8String);
        @try {
            NSRequestConcreteImplementation([NSObject new], @selector(count), [NSArray class]);
        } @catch (NSException *e) {
            printf("abstract: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
        }
        void *pool = NSPushAutoreleasePool(0);
        NSPopAutoreleasePool(pool);
        printf("pool: %d\n", pool != NULL);
        printf("centred: %s %s %s\n", NSStringFromRect(_NSCenteredRectForImage(NSMakeSize(10, 20), NSMakeRect(0, 0, 100, 100), 0)).UTF8String,
               NSStringFromRect(_NSCenteredRectForImage(NSMakeSize(10, 20), NSMakeRect(0, 0, 100, 100), 10)).UTF8String,
               NSStringFromRect(_NSCenteredRectForImage(NSMakeSize(400, 200), NSMakeRect(0, 0, 100, 100), 0)).UTF8String);
        printf("integral: %s\n", NSStringFromRect(UIRectIntegralWithScale(CGRectMake(0.3, 0.6, 10.1, 5.2), 2)).UTF8String);
        printf("centred on point: %s\n", NSStringFromRect(UIRectCenteredAboutPointScale(CGRectMake(0, 0, 11, 7), CGPointMake(20, 20), 2)).UTF8String);
        printf("constants: %s %s %s %s %s %s %s\n", NSToolbarItemKey.UTF8String, NSMenuDidCompleteInteractionNotification.UTF8String,
               NSAppleMenuName.UTF8String, NSSharingServiceMailExportTextKey.UTF8String, NSMetadataQueryDidFinishGatheringNotification.UTF8String,
               NSUbiquitousKeyValueStoreChangedKeysKey.UTF8String, NSURLProtectionSpaceHTTP.UTF8String);
    }
    return 0;
}

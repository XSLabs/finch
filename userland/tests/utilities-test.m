/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What Apple's Utilities apps import beyond the rest: CoreGraphics' headroom copies,
 * image writing, window counts and pointer; Core Animation's tone mapping; AppKit's
 * legacy alert panels and constants; CFFileSecurity and the file-security resource;
 * scripting coercions; SecurityFoundation; SkyLight's capture options and display
 * queries; message tracer messages; and IOBluetoothUI's hardware check classes.
 * Compared with Apple's.
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <SecurityFoundation/SFAuthorization.h>
#include <dlfcn.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

extern bool CGImageWriteToFile(CGImageRef, const char *);
extern CGError CGSGetOnScreenWindowCount(int cid, int owner, int *count);
extern CGError CGSGetOnScreenWindowList(int cid, int owner, int capacity, uint32_t *list, int *count);
extern int CGSMainConnectionID(void);
extern CGPoint CGSCurrentInputPointerPosition(void);
extern NSString *const CAToneMapModeAutomatic, *const CAToneMapModeIfSupported, *const CAToneMapModeNever;
extern NSString *const NSVoiceName, *const NSVoiceDemoText, *const NSVoiceLocaleIdentifier, *const NSVoiceGenderNeutral;
extern const float NSLocaleLanguageConfidenceHigh, NSLocaleLanguageConfidenceMedium, NSLocaleLanguageConfidenceLow;
extern id NSGetAlertPanel(NSString *, NSString *, NSString *, NSString *, NSString *, ...);
extern void NSReleaseAlertPanel(id);
extern NSString *const NSImageNamePauseTemplate, *const NSImageNamePlayTemplate, *const NSImageHintSymbolScale,
    *const NSImageNamePrintTemplate;
extern const uint32_t kSLSCaptureExtendedRange, kSLSCapturePrioritizeCaptureRectCenter;
extern const CFStringRef kSLSConnectionHasPluginPower;
extern float SLSDisplayGetCurrentHeadroom(CGDirectDisplayID);
extern int SLSDisplayGetPresetCount(CGDirectDisplayID);
extern void *msgtracer_domain_new(const char *);
extern void *msgtracer_msg_new(void *);
extern int msgtracer_set(void *, const char *, const char *);
extern void msgtracer_msg_free(void *);
extern void msgtracer_domain_free(void *);
extern int msgtracer_log_with_keys(const char *, int, ...);
extern char *msgtracer_uuid_create(void);

@interface SFCertificateData : NSObject
+ (BOOL)isRoot:(SecCertificateRef)c;
+ (BOOL)isCA:(SecCertificateRef)c;
+ (NSArray *)trustPolicies;
+ (NSString *)statusStringForCode:(OSStatus)c domain:(unsigned)d;
- (instancetype)initWithCertificate:(SecCertificateRef)c;
- (NSString *)statusString;
- (BOOL)expired;
- (SecCertificateRef)certificate;
@end

int
main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        printf("Utilities\n");

        /* CoreGraphics */
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        CGContextRef c8 = CGBitmapContextCreate(NULL, 4, 4, 8, 0, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextRef c16 = CGBitmapContextCreate(NULL, 4, 4, 16, 0, ext,
            (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little);
        CGImageRef sdr = CGBitmapContextCreateImage(c8), hdr = CGBitmapContextCreateImage(c16);
        printf("headroom: sdr %g extended %g\n", CGImageGetContentHeadroom(sdr), CGImageGetContentHeadroom(hdr));
        float rooms[] = {0, 0.5, 1, 2, 20};
        for (int i = 0; i < 5; i++) {
            CGImageRef a = CGImageCreateCopyWithContentHeadroom(rooms[i], sdr), b = CGImageCreateCopyWithContentHeadroom(rooms[i], hdr);
            printf("  copy at %g: sdr %s, extended %s %g\n", rooms[i], a ? "image" : "null", b ? "image" : "null",
                b ? CGImageGetContentHeadroom(b) : -1);
            CGImageRelease(a), CGImageRelease(b);
        }
        char tmp[] = "/tmp/finch-utilities-XXXXXX";
        mkdtemp(tmp);
        NSString *dir = @(tmp);
        const char *exts[] = {"tif", "png", "jpg"};
        for (int i = 0; i < 3; i++) {
            NSString *path = [dir stringByAppendingPathComponent:[@"image." stringByAppendingString:@(exts[i])]];
            bool ok = CGImageWriteToFile(sdr, path.fileSystemRepresentation);
            NSData *d = [NSData dataWithContentsOfFile:path];
            const uint8_t *p = d.bytes;
            printf("write %s: %d, magic %02x%02x\n", exts[i], ok, d.length > 1 ? p[0] : 0, d.length > 1 ? p[1] : 0);
        }
        int count = -1, listed = -1;
        CGSGetOnScreenWindowCount(CGSMainConnectionID(), 0, &count);
        uint32_t *ids = calloc((size_t)count + 1, sizeof *ids);
        CGSGetOnScreenWindowList(CGSMainConnectionID(), 0, count, ids, &listed);
        NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
        printf("window list: count matches %d, listed matches %d, first matches %d\n", count == (int)info.count, listed == count,
            count == 0 || ids[0] == [info[0][(id)kCGWindowNumber] unsignedIntValue]);
        free(ids);
        CGEventRef ev = CGEventCreate(NULL);
        CGPoint pointer = CGSCurrentInputPointerPosition(), there = CGEventGetLocation(ev);
        printf("pointer matches events: %d\n", pointer.x == there.x && pointer.y == there.y);
        CFRelease(ev);

        /* Core Animation */
        printf("tone map: %s %s %s\n", CAToneMapModeAutomatic.UTF8String, CAToneMapModeIfSupported.UTF8String, CAToneMapModeNever.UTF8String);
        CALayer *layer = [CALayer layer];
        printf("layer: %s %s %d", [[layer valueForKey:@"preferredDynamicRange"] UTF8String], [[layer valueForKey:@"toneMapMode"] UTF8String],
            [[layer valueForKey:@"toneMapToStandardDynamicRange"] boolValue]);
        [layer setValue:CAToneMapModeNever forKey:@"toneMapMode"];
        [layer setValue:@"high" forKey:@"preferredDynamicRange"];
        printf(" -> %s %s\n", [[layer valueForKey:@"toneMapMode"] UTF8String], [[layer valueForKey:@"preferredDynamicRange"] UTF8String]);

        /* AppKit */
        printf("names: %s %s %s %s\n", NSImageNamePauseTemplate.UTF8String, NSImageNamePlayTemplate.UTF8String,
            NSImageHintSymbolScale.UTF8String, NSImageNamePrintTemplate.UTF8String);
        printf("voice keys: %s %s %s %s\n", NSVoiceName.UTF8String, NSVoiceDemoText.UTF8String, NSVoiceLocaleIdentifier.UTF8String,
            NSVoiceGenderNeutral.UTF8String);
        NSPanel *panel = NSGetAlertPanel(@"Title", @"Message %d", @"OK", @"Cancel", nil, 3);
        printf("alert panel: is panel %d\n", [panel isKindOfClass:[NSPanel class]]);
        NSReleaseAlertPanel(panel);

        /* CFFileSecurity */
        CFFileSecurityRef sec = CFFileSecurityCreate(NULL);
        mode_t mode = 0;
        uid_t owner = 0;
        gid_t group = 0;
        printf("file security empty: %d %d %d\n", CFFileSecurityGetMode(sec, &mode), CFFileSecurityGetOwner(sec, &owner),
            CFFileSecurityGetGroup(sec, &group));
        CFFileSecuritySetMode(sec, 0100644);
        CFFileSecuritySetOwner(sec, 501);
        CFFileSecuritySetGroup(sec, 20);
        CFFileSecurityRef copy = CFFileSecurityCreateCopy(NULL, sec);
        CFFileSecurityGetMode(copy, &mode);
        printf("  set: mode %o, copy equal %d, type %d, bridged %d\n", mode, CFEqual(copy, sec), CFGetTypeID(sec) == CFFileSecurityGetTypeID(),
            [(__bridge id)sec isKindOfClass:[NSFileSecurity class]]);
        CFFileSecurityClearProperties(sec, kCFFileSecurityClearMode | kCFFileSecurityClearOwner);
        printf("  cleared: %d %d %d\n", CFFileSecurityGetMode(sec, &mode), CFFileSecurityGetOwner(sec, &owner),
            CFFileSecurityGetGroup(sec, &group));
        acl_t acl = acl_init(1), back = NULL;
        printf("  acl: set %d copy %d\n", CFFileSecuritySetAccessControlList(sec, acl), CFFileSecurityCopyAccessControlList(sec, &back));
        CFFileSecuritySetAccessControlList(sec, _FILESEC_REMOVE_ACL);
        back = NULL;
        printf("  acl removed: copy %d is remove %d\n", CFFileSecurityCopyAccessControlList(sec, &back), back == _FILESEC_REMOVE_ACL);
        NSString *file = [dir stringByAppendingPathComponent:@"image.png"];
        chmod(file.fileSystemRepresentation, 0640);
        NSFileSecurity *fs = nil;
        [[NSURL fileURLWithPath:file] getResourceValue:&fs forKey:NSURLFileSecurityKey error:nil];
        CFFileSecurityGetMode((__bridge CFFileSecurityRef)fs, &mode);
        CFFileSecurityGetOwner((__bridge CFFileSecurityRef)fs, &owner);
        printf("  resource: mode %o, owner is me %d\n", mode, owner == getuid());
        CFRelease(sec), CFRelease(copy);

        /* Foundation */
        NSScriptCoercionHandler *coercion = [NSScriptCoercionHandler sharedCoercionHandler];
        printf("coerce: %s %s %s\n", [[[coercion coerceValue:@42 toClass:[NSString class]] description] UTF8String],
            [[[coercion coerceValue:@"17" toClass:[NSNumber class]] description] UTF8String],
            [[[coercion coerceValue:@"x" toClass:[NSString class]] description] UTF8String]);
        printf("language confidence: %g %g %g\n", NSLocaleLanguageConfidenceHigh, NSLocaleLanguageConfidenceMedium, NSLocaleLanguageConfidenceLow);

        /* SecurityFoundation */
        CFArrayRef anchors = NULL;
        SecTrustCopyAnchorCertificates(&anchors);
        SecCertificateRef root = anchors && CFArrayGetCount(anchors) ? (SecCertificateRef)CFArrayGetValueAtIndex(anchors, 0) : NULL;
        SFCertificateData *cd = [[SFCertificateData alloc] initWithCertificate:root];
        printf("certificate data: root %d ca %d same %d expired %d\n", [SFCertificateData isRoot:root], [SFCertificateData isCA:root],
            [cd certificate] == root, [cd expired]);
        printf("  status: %s\n", [[cd statusString] UTF8String]);
        printf("  policies:");
        for (id p in [SFCertificateData trustPolicies]) {
            NSDictionary *props = CFBridgingRelease(SecPolicyCopyProperties((__bridge SecPolicyRef)p));
            printf(" %s", [props[(__bridge id)kSecPolicyOid] UTF8String]);
        }
        printf("\n");
        int codes[] = {0, 3, -2147409654, -2147409653, -2147409652, -2147409622, -2147408892, -67818};
        for (int i = 0; i < 8; i++)
            printf("  code %d: %s\n", codes[i], [[SFCertificateData statusStringForCode:codes[i] domain:0] UTF8String]);
        SFAuthorization *auth = [SFAuthorization authorization];
        NSError *error = nil;
        BOOL ok = [auth obtainWithRight:"system.burn" flags:0 error:&error];
        printf("authorization: ref %d, allowed %d", [auth authorizationRef] != NULL, ok);
        error = nil;
        ok = [auth obtainWithRight:"config.config.x" flags:0 error:&error];
        printf(", denied %d (%ld)\n", ok, (long)error.code);
        if (anchors)
            CFRelease(anchors);

        /* SkyLight */
        void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
        const uint32_t *extended = dlsym(skylight, "kSLSCaptureExtendedRange");
        const uint32_t *center = dlsym(skylight, "kSLSCapturePrioritizeCaptureRectCenter");
        const CFStringRef *power = dlsym(skylight, "kSLSConnectionHasPluginPower");
        int (*presets)(CGDirectDisplayID) = dlsym(skylight, "SLSDisplayGetPresetCount");
        /* (Apple's display has its own preset count; the call only has to answer) */
        printf("skylight: %#x %#x %s, presets %d\n", extended ? *extended : 0, center ? *center : 0,
            power ? [(__bridge NSString *)*power UTF8String] : "-", presets ? presets(CGMainDisplayID()) >= 0 : -1);

        /* message tracer */
        /* (Apple's accepts a domain by an allow list that depends on the process; only the
           calls that don't are compared) */
        void *domain = msgtracer_domain_new("com.apple.automation.app_launched");
        void *msg = msgtracer_msg_new(domain);
        msgtracer_set(msg, "com.apple.message.signature", "Finch");
        msgtracer_log_with_keys("com.apple.automation.app_launched", 5, "com.apple.message.signature", "Finch", NULL);
        printf("message tracer: set on no message %d\n", msgtracer_set(NULL, "a", "b"));
        msgtracer_msg_free(msg);
        msgtracer_domain_free(domain);
        char *uuid = msgtracer_uuid_create();
        printf("  uuid: %zu characters, uppercase %d\n", strlen(uuid), strpbrk(uuid, "abcdef") == NULL);
        free(uuid);

        /* IOBluetoothUI */
        void *btui = dlopen("/System/Library/Frameworks/IOBluetoothUI.framework/IOBluetoothUI", RTLD_NOW);
        printf("bluetooth ui: %d %d %d, progress is a transfer progress %d\n", btui != NULL,
            NSClassFromString(@"IOBluetoothDeviceSelectorController") != nil, NSClassFromString(@"IOBluetoothObjectPushUIController") != nil,
            [NSClassFromString(@"IOBluetoothTransferProgressUI") isSubclassOfClass:NSClassFromString(@"IOBluetoothTransferProgress")]);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    }
    return 0;
}

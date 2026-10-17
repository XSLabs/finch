// SPDX-License-Identifier: MIT OR Apache-2.0
#import <CoreFoundation/CoreFoundation.h>
#import <MediaAccessibility/MediaAccessibility.h>
#include <dlfcn.h>
#include <stdio.h>

static void printImage(void)
{
    Dl_info info = {0};
    if (dladdr((const void *)MACaptionAppearanceGetDisplayType, &info) && info.dli_fname)
        puts(info.dli_fname);
    else puts("(MediaAccessibility image unavailable)");
}

static void printString(const char *name, CFStringRef value)
{
    char text[512] = {0};
    if (value) CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8);
    printf("%s=%s\n", name, value ? text : "(null)");
}

int main(void)
{
    @autoreleasepool {
        printImage();
        MACaptionAppearanceDomain domain = kMACaptionAppearanceDomainDefault;
        MACaptionAppearanceBehavior behavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
        printf("caption defaults: display=%ld customized=%d foreground=%.3f background=%.3f size=%.3f edge=%ld\n",
            (long)MACaptionAppearanceGetDisplayType(domain), MACaptionAppearanceIsCustomized(domain),
            MACaptionAppearanceGetForegroundOpacity(domain, &behavior),
            MACaptionAppearanceGetBackgroundOpacity(domain, &behavior),
            MACaptionAppearanceGetRelativeCharacterSize(domain, &behavior),
            (long)MACaptionAppearanceGetTextEdgeStyle(domain, &behavior));
        CFArrayRef profiles = MACaptionAppearanceCopyProfileIDs();
        CFStringRef path = MAImageCaptioningCopyMetadataTagPath();
        CFStringRef profileName = MACaptionAppearanceCopyProfileName(CFSTR("MACaptionProfile-Default"));
        printf("profiles=%ld\n", (long)CFArrayGetCount(profiles));
        printString("caption metadata path", path);
        printString("default profile", profileName);
        CFRelease(path);
        CFRelease(profileName);
        CFRelease(profiles);
    }
    return 0;
}

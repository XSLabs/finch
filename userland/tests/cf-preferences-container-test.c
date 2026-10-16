/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

CFPropertyListRef _CFPreferencesCopyValueWithContainer(CFStringRef key, CFStringRef applicationID, CFStringRef user,
                                                       CFStringRef host, CFStringRef container);
void _CFPreferencesSetValueWithContainer(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID,
                                         CFStringRef user, CFStringRef host, CFStringRef container);
Boolean _CFPreferencesSynchronizeWithContainer(CFStringRef applicationID, CFStringRef user, CFStringRef host,
                                                CFStringRef container);
CFPropertyListRef _CFPreferencesCopyAppValueWithContainer(CFStringRef key, CFStringRef applicationID,
                                                           CFStringRef container);
Boolean _CFPreferencesGetAppBooleanValueWithContainer(CFStringRef key, CFStringRef applicationID, CFStringRef container,
                                                        Boolean *keyExistsAndHasValidFormat);
void _CFPreferencesSetAppValueWithContainer(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID,
                                            CFStringRef container);

int
main(void)
{
    Dl_info image;
    if (dladdr((void *)CFPreferencesCopyValue, &image))
        printf("CoreFoundation: %s\n", image.dli_fname);

    const char *homePath = getenv("CFFIXED_USER_HOME");
    char containerPath[PATH_MAX], appName[128], containerFile[PATH_MAX], homeFile[PATH_MAX];
    if (!homePath || snprintf(containerPath, sizeof containerPath, "%s-container-%d", homePath, getpid()) >= (int)sizeof containerPath ||
        snprintf(appName, sizeof appName, "org.finch.cf-container-test.%d", getpid()) >= (int)sizeof appName)
        return 1;
    mkdir(homePath, 0700);
    if (mkdir(containerPath, 0700) != 0)
        return 1;
    snprintf(containerFile, sizeof containerFile, "%s/Library/Preferences/%s.plist", containerPath, appName);
    snprintf(homeFile, sizeof homeFile, "%s/Library/Preferences/%s.plist", homePath, appName);

    CFStringRef container = CFStringCreateWithFileSystemRepresentation(NULL, containerPath);
    CFStringRef app = CFStringCreateWithCString(NULL, appName, kCFStringEncodingUTF8);
    if (!container || !app)
        return 1;

    CFStringRef appKey = CFSTR("ContainerBoolean");
    CFStringRef directKey = CFSTR("ContainerDomainString");
    _CFPreferencesSetAppValueWithContainer(appKey, kCFBooleanTrue, app, container);
    Boolean synchronized = _CFPreferencesSynchronizeWithContainer(app, kCFPreferencesCurrentUser,
                                                                   kCFPreferencesAnyHost, container);

    Boolean valid = false;
    Boolean booleanValue = _CFPreferencesGetAppBooleanValueWithContainer(appKey, app, container, &valid);
    CFPropertyListRef appValue = _CFPreferencesCopyAppValueWithContainer(appKey, app, container);
    Boolean appMatches = appValue && CFEqual(appValue, kCFBooleanTrue);
    _CFPreferencesSetValueWithContainer(directKey, CFSTR("kept"), app, kCFPreferencesCurrentUser,
                                        kCFPreferencesAnyHost, container);
    synchronized = _CFPreferencesSynchronizeWithContainer(app, kCFPreferencesCurrentUser,
                                                           kCFPreferencesAnyHost, container) && synchronized;
    CFPropertyListRef directValue = _CFPreferencesCopyValueWithContainer(directKey, app,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container);
    Boolean directMatches = directValue && CFEqual(directValue, CFSTR("kept"));
    Boolean containerFileExists = access(containerFile, F_OK) == 0;
    Boolean homeFileExists = access(homeFile, F_OK) == 0;

    printf("synchronized: %d\n", synchronized);
    printf("app boolean: %d valid:%d\n", booleanValue, valid);
    printf("app value: %d\n", appMatches);
    printf("domain value: %d\n", directMatches);
    printf("container file: %d\n", containerFileExists);
    printf("home file: %d\n", homeFileExists);

    if (appValue) CFRelease(appValue);
    if (directValue) CFRelease(directValue);
    CFRelease(app);
    CFRelease(container);
    unlink(containerFile);
    char preferencesPath[PATH_MAX], libraryPath[PATH_MAX];
    snprintf(preferencesPath, sizeof preferencesPath, "%s/Library/Preferences", containerPath);
    snprintf(libraryPath, sizeof libraryPath, "%s/Library", containerPath);
    rmdir(preferencesPath);
    rmdir(libraryPath);
    rmdir(containerPath);
    return synchronized && booleanValue && valid && appMatches && directMatches && containerFileExists && !homeFileExists ? 0 : 1;
}

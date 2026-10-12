/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* ConfigurationProfiles (private): the notification name apps watch for profile changes
   (Finch installs no configuration profiles, so it's never posted). */
#include <CoreFoundation/CoreFoundation.h>

__attribute__((visibility("default"))) const CFStringRef CPProfilePreferencesChangedNotification =
    CFSTR("com.apple.ManagedConfiguration.profileListChanged");

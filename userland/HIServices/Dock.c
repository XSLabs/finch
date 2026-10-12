/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreDockSendNotification: asks the Dock to do something by name (Apple's Apps app
 * sends com.apple.launchpad.toggle, Mission Control com.apple.expose.awake). On
 * Finch the Rail stands in for the Dock, and hears these as Darwin notifications
 * named "org.finch.dock." followed by the name.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <notify.h>

void CoreDockSendNotification(CFStringRef notification, int flags);

void
CoreDockSendNotification(CFStringRef notification, int flags)
{
    (void)flags;
    char name[256] = "org.finch.dock.";
    size_t prefix = strlen(name);
    if (!notification ||
        !CFStringGetCString(notification, name + prefix, (CFIndex)(sizeof name - prefix), kCFStringEncodingUTF8))
        return;
    notify_post(name);
}

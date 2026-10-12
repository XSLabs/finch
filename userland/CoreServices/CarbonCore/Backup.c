/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Time Machine's backup server, as CarbonCore's private _CSBackup calls reach it.
 * Finch has no backup server yet: it is never active, so there is no proxy to ask
 * for, and a cancel has nothing to cancel. (The Time Machine app only asks for the
 * proxy when the server is active.)
 */
#include <CoreFoundation/CoreFoundation.h>

Boolean _CSBackupServerIsActive(void);
void *_CSBackupGetSharedServerProxy(void);
OSStatus _CSBackupServerProxyCancelBackup(void *proxy);

Boolean
_CSBackupServerIsActive(void)
{
    return false;
}

void *
_CSBackupGetSharedServerProxy(void)
{
    return NULL;
}

OSStatus
_CSBackupServerProxyCancelBackup(void *proxy)
{
    (void)proxy;
    return noErr;
}

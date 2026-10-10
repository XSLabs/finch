/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AESend: HIToolbox's Apple event send, with idle and filter procedures for the events
 * that arrive while waiting for a reply. Finch's AE (AESendMessage) waits on its own,
 * so the procedures aren't called; the send is AESendMessage's.
 */
#include <Carbon/Carbon.h>

OSErr
AESend(const AppleEvent *theAppleEvent, AppleEvent *reply, AESendMode sendMode, AESendPriority sendPriority, SInt32 timeOutInTicks,
       AEIdleUPP idleProc, AEFilterUPP filterProc)
{
    return (OSErr)AESendMessage(theAppleEvent, reply, sendMode, timeOutInTicks);
}

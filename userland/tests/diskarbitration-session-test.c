/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check that a client can open and close a session with diskarbitrationd. */
#include <DiskArbitration/DiskArbitration.h>
#include <CoreFoundation/CoreFoundation.h>

#include <stdio.h>

int main(void)
{
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (session == NULL) {
        fputs("DASessionCreate could not reach the Disk Arbitration service\n", stderr);
        return 1;
    }

    CFRelease(session);
    puts("Disk Arbitration session opened and closed");
    return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFNetDiagnostics: whether the network is up, from SystemConfiguration's reachability
 * of the Internet (or the diagnostic's host), with Apple's words for it. There's no
 * Network Diagnostics assistant to bring up: diagnosing "interactively" reports the
 * status the same way.
 */
#include "CFNetworkInternal.h"
#include <SystemConfiguration/SCNetworkReachability.h>
#include <netinet/in.h>
#include <string.h>

struct __CFNetDiagnostic {
    CFRuntimeBase base;
    CFStringRef host, name;
};

static CFTypeID diagnostic_type;

static void
diagnostic_finalize(CFTypeRef cf)
{
    struct __CFNetDiagnostic *d = (struct __CFNetDiagnostic *)cf;
    if (d->host)
        CFRelease(d->host);
    if (d->name)
        CFRelease(d->name);
}

static const CFRuntimeClass diagnostic_class = {0, "CFNetDiagnostic", NULL, NULL, diagnostic_finalize, NULL, NULL,
                                                NULL, NULL, NULL, NULL, 0};

static CFTypeID
diagnostic_get_type_id(void)
{
    CFN_REGISTER(diagnostic_type, diagnostic_class);
}

CFNetDiagnosticRef
CFNetDiagnosticCreateWithURL(CFAllocatorRef alloc, CFURLRef url)
{
    struct __CFNetDiagnostic *d = cfn_create(diagnostic_get_type_id(), sizeof(struct __CFNetDiagnostic));
    d->host = url ? CFURLCopyHostName(url) : NULL;
    return d;
}

CFNetDiagnosticRef
CFNetDiagnosticCreateWithStreams(CFAllocatorRef alloc, CFReadStreamRef readStream, CFWriteStreamRef writeStream)
{
    struct __CFNetDiagnostic *d = cfn_create(diagnostic_get_type_id(), sizeof(struct __CFNetDiagnostic));
    CFTypeRef host = readStream ? CFReadStreamCopyProperty(readStream, kCFStreamPropertySocketRemoteHostName)
                     : writeStream ? CFWriteStreamCopyProperty(writeStream, kCFStreamPropertySocketRemoteHostName)
                                   : NULL;
    if (host && CFGetTypeID(host) == CFStringGetTypeID())
        d->host = host;
    else if (host)
        CFRelease(host);
    return d;
}

void
CFNetDiagnosticSetName(CFNetDiagnosticRef details, CFStringRef name)
{
    struct __CFNetDiagnostic *d = (struct __CFNetDiagnostic *)details;
    if (d->name)
        CFRelease(d->name);
    d->name = name ? CFStringCreateCopy(NULL, name) : NULL;
}

static CFNetDiagnosticStatus
status(struct __CFNetDiagnostic *d)
{
    struct sockaddr_in any = {sizeof any, AF_INET, 0, {0}, {0}};
    SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&any);
    SCNetworkReachabilityFlags flags = 0;
    bool known = r && SCNetworkReachabilityGetFlags(r, &flags);
    if (r)
        CFRelease(r);
    if (!known)
        return kCFNetDiagnosticConnectionIndeterminate;
    return (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsConnectionRequired)
               ? kCFNetDiagnosticConnectionUp
               : kCFNetDiagnosticConnectionDown;
}

CFNetDiagnosticStatus
CFNetDiagnosticCopyNetworkStatusPassively(CFNetDiagnosticRef details, CFStringRef *description)
{
    CFNetDiagnosticStatus s = status((struct __CFNetDiagnostic *)details);
    if (description)
        *description = s == kCFNetDiagnosticConnectionUp
                           ? CFStringCreateCopy(NULL, CFSTR("This computer’s Internet connection appears to be online."))
                       : s == kCFNetDiagnosticConnectionDown
                           ? CFStringCreateCopy(NULL, CFSTR("This computer’s Internet connection appears to be offline."))
                           : CFStringCreateCopy(NULL, CFSTR("This computer’s Internet connection appears to be inactive."));
    return s;
}

CFNetDiagnosticStatus
CFNetDiagnosticDiagnoseProblemInteractively(CFNetDiagnosticRef details)
{
    return status((struct __CFNetDiagnostic *)details) == kCFNetDiagnosticConnectionUp ? kCFNetDiagnosticNoErr
                                                                                        : kCFNetDiagnosticErr;
}

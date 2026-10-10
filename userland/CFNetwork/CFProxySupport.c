/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Proxies: the system's proxy settings (SystemConfiguration's, as Apple's), and the
 * proxies a URL goes through under them, worked out as Apple's CFNetwork does:
 *   - a host in ExceptionsList (an exact name, "*.domain" for the names under it, or an
 *     address range "10.0.0.0/8"), or a name without dots when ExcludeSimpleHostnames
 *     is set, goes direct;
 *   - otherwise a PAC script or URL comes first, then the scheme's proxy (http: the
 *     HTTP proxy; https: the HTTPS proxy; ftp: the FTP proxy, as an HTTP proxy on port
 *     80 and as an FTP proxy) and then the SOCKS proxy; with none of those, direct.
 * Finch has no JavaScript engine for PAC files yet: a script that only returns its
 * answer ("return \"PROXY host:port; DIRECT\";") is read; any other is a
 * kCFErrorPACFileError.
 */
#include "CFNetworkInternal.h"
#include <SystemConfiguration/SCDynamicStoreCopySpecific.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

CFDictionaryRef
CFNetworkCopySystemProxySettings(void)
{
    return SCDynamicStoreCopyProxies(NULL);
}

static bool
enabled(CFDictionaryRef s, CFStringRef key)
{
    CFNumberRef n = CFDictionaryGetValue(s, key);
    int v = 0;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberIntType, &v);
    return v != 0;
}

static CFDictionaryRef
proxy_entry(CFStringRef type, CFStringRef host, CFTypeRef port, int defaultPort)
{
    int p = defaultPort;
    if (port && CFGetTypeID(port) == CFNumberGetTypeID())
        CFNumberGetValue(port, kCFNumberIntType, &p);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    const void *keys[] = {kCFProxyTypeKey, kCFProxyHostNameKey, kCFProxyPortNumberKey};
    const void *values[] = {type, host, pn};
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(pn);
    return d;
}

static void
add_proxy(CFMutableArrayRef list, CFDictionaryRef s, CFStringRef enable, CFStringRef hostKey, CFStringRef portKey,
          CFStringRef type, int defaultPort, bool usePort)
{
    if (!enabled(s, enable))
        return;
    CFStringRef host = CFDictionaryGetValue(s, hostKey);
    if (!host || CFGetTypeID(host) != CFStringGetTypeID() || !CFStringGetLength(host))
        return;
    CFDictionaryRef d = proxy_entry(type, host, usePort ? CFDictionaryGetValue(s, portKey) : NULL, defaultPort);
    CFArrayAppendValue(list, d);
    CFRelease(d);
}

static CFDictionaryRef
direct(void)
{
    const void *keys[] = {kCFProxyTypeKey};
    const void *values[] = {kCFProxyTypeNone};
    return CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

/* "10.0.0.0/8", "169.254/16": an IPv4 range, octets left out being zero. */
static bool
in_range(const char *host, const char *pattern)
{
    struct in_addr a;
    if (inet_pton(AF_INET, host, &a) != 1)
        return false;
    const char *slash = strchr(pattern, '/');
    if (!slash)
        return false;
    unsigned octets[4] = {0, 0, 0, 0}, n = 0;
    for (const char *p = pattern; p < slash && n < 4; n++) {
        octets[n] = (unsigned)strtoul(p, (char **)&p, 10);
        if (*p == '.')
            p++;
    }
    int bits = atoi(slash + 1);
    if (bits < 0 || bits > 32)
        return false;
    uint32_t net = octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3];
    uint32_t mask = bits ? ~0u << (32 - bits) : 0;
    return (ntohl(a.s_addr) & mask) == (net & mask);
}

static bool
excepted(CFDictionaryRef s, CFStringRef host)
{
    if (enabled(s, CFSTR("ExcludeSimpleHostnames")) && CFStringFind(host, CFSTR("."), 0).location == kCFNotFound &&
        CFStringFind(host, CFSTR(":"), 0).location == kCFNotFound)
        return true;
    CFArrayRef list = CFDictionaryGetValue(s, CFSTR("ExceptionsList"));
    if (!list || CFGetTypeID(list) != CFArrayGetTypeID())
        return false;
    char *h = cfn_cstring(host);
    bool hit = false;
    for (CFIndex i = 0; h && !hit && i < CFArrayGetCount(list); i++) {
        CFStringRef e = CFArrayGetValueAtIndex(list, i);
        if (CFGetTypeID(e) != CFStringGetTypeID())
            continue;
        char *p = cfn_cstring(e);
        if (!p)
            continue;
        if (p[0] == '*' && p[1] == '.') {
            size_t hl = strlen(h), sl = strlen(p + 1); /* ".domain" */
            hit = hl > sl && strcasecmp(h + hl - sl, p + 1) == 0;
        } else if (strchr(p, '/')) {
            hit = in_range(h, p);
        } else {
            hit = strcasecmp(h, p) == 0;
        }
        free(p);
    }
    free(h);
    return hit;
}

CFArrayRef
CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings)
{
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionaryRef s = proxySettings;
    CFStringRef host = url ? CFURLCopyHostName(url) : NULL;
    if (!s || (host && excepted(s, host))) {
        if (host)
            CFRelease(host);
        CFDictionaryRef d = direct();
        CFArrayAppendValue(list, d);
        CFRelease(d);
        return list;
    }
    if (host)
        CFRelease(host);
    CFMutableArrayRef proxies = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (enabled(s, CFSTR("ProxyAutoConfigEnable"))) {
        CFStringRef script = CFDictionaryGetValue(s, CFSTR("ProxyAutoConfigJavaScript"));
        CFStringRef pac = CFDictionaryGetValue(s, CFSTR("ProxyAutoConfigURLString"));
        const void *keys[2] = {kCFProxyTypeKey, NULL}, *values[2] = {NULL, NULL};
        if (script && CFGetTypeID(script) == CFStringGetTypeID()) {
            values[0] = kCFProxyTypeAutoConfigurationJavaScript;
            keys[1] = kCFProxyAutoConfigurationJavaScriptKey;
            values[1] = script;
        } else if (pac && CFGetTypeID(pac) == CFStringGetTypeID()) {
            values[0] = kCFProxyTypeAutoConfigurationURL;
            keys[1] = kCFProxyAutoConfigurationURLKey;
            values[1] = pac;
        }
        if (values[0]) {
            CFDictionaryRef d = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(list, d);
            CFRelease(d);
        }
    }
    CFStringRef scheme = url ? CFURLCopyScheme(url) : NULL;
    if (scheme && CFStringCompare(scheme, CFSTR("http"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        add_proxy(proxies, s, CFSTR("HTTPEnable"), CFSTR("HTTPProxy"), CFSTR("HTTPPort"), kCFProxyTypeHTTP, 80, true);
    } else if (scheme && CFStringCompare(scheme, CFSTR("https"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        add_proxy(proxies, s, CFSTR("HTTPSEnable"), CFSTR("HTTPSProxy"), CFSTR("HTTPSPort"), kCFProxyTypeHTTPS, 80, true);
    } else if (scheme && CFStringCompare(scheme, CFSTR("ftp"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        /* as an HTTP proxy too: on its port, unless that's FTP's own (then 80) */
        CFNumberRef ftpPort = CFDictionaryGetValue(s, CFSTR("FTPPort"));
        int fp = 0;
        if (ftpPort && CFGetTypeID(ftpPort) == CFNumberGetTypeID())
            CFNumberGetValue(ftpPort, kCFNumberIntType, &fp);
        add_proxy(proxies, s, CFSTR("FTPEnable"), CFSTR("FTPProxy"), CFSTR("FTPPort"), kCFProxyTypeHTTP, 80, fp && fp != 21);
        add_proxy(proxies, s, CFSTR("FTPEnable"), CFSTR("FTPProxy"), CFSTR("FTPPort"), kCFProxyTypeFTP, 21, true);
    }
    add_proxy(proxies, s, CFSTR("SOCKSEnable"), CFSTR("SOCKSProxy"), CFSTR("SOCKSPort"), kCFProxyTypeSOCKS, 1080, true);
    if (scheme)
        CFRelease(scheme);
    if (!CFArrayGetCount(proxies)) {
        CFDictionaryRef d = direct();
        CFArrayAppendValue(proxies, d);
        CFRelease(d);
    }
    CFArrayAppendArray(list, proxies, CFRangeMake(0, CFArrayGetCount(proxies)));
    CFRelease(proxies);
    return list;
}

/* --- PAC --- */

/* A PAC answer ("PROXY a:1; SOCKS b:2; DIRECT") as proxy dictionaries. */
static CFArrayRef
parse_pac_result(const char *r)
{
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    char *copy = strdup(r), *save = NULL;
    for (char *part = strtok_r(copy, ";", &save); part; part = strtok_r(NULL, ";", &save)) {
        while (*part == ' ' || *part == '\t')
            part++;
        char kind[16] = {0}, where[512] = {0};
        if (sscanf(part, "%15s %511s", kind, where) < 1)
            continue;
        CFDictionaryRef d = NULL;
        if (!strcasecmp(kind, "DIRECT")) {
            d = direct();
        } else if (where[0]) {
            CFStringRef type = !strcasecmp(kind, "PROXY")   ? kCFProxyTypeHTTP
                               : !strcasecmp(kind, "HTTPS") ? kCFProxyTypeHTTPS
                               : !strncasecmp(kind, "SOCKS", 5) ? kCFProxyTypeSOCKS
                                                                : NULL;
            if (!type)
                continue;
            char *colon = strrchr(where, ':');
            int port = type == kCFProxyTypeSOCKS ? 1080 : 80;
            if (colon) {
                *colon = 0;
                port = atoi(colon + 1);
            }
            CFStringRef host = CFStringCreateWithCString(NULL, where, kCFStringEncodingUTF8);
            CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &port);
            d = proxy_entry(type, host, pn, port);
            if (type == kCFProxyTypeSOCKS) {
                CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
                CFDictionarySetValue(m, kCFStreamPropertySOCKSVersion,
                                     !strcasecmp(kind, "SOCKS4") ? kCFStreamSocketSOCKSVersion4 : kCFStreamSocketSOCKSVersion5);
                CFRelease(d);
                d = m;
            }
            CFRelease(pn);
            CFRelease(host);
        }
        if (d) {
            CFArrayAppendValue(list, d);
            CFRelease(d);
        }
    }
    free(copy);
    return list;
}

/* The answer of a script whose FindProxyForURL only returns a string, else NULL. */
static char *
constant_answer(CFStringRef script)
{
    char *s = cfn_cstring(script);
    if (!s)
        return NULL;
    char *f = strstr(s, "FindProxyForURL");
    char *open = f ? strchr(f, '{') : NULL;
    char *out = NULL;
    if (open) {
        char *p = open + 1;
        while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r')
            p++;
        if (!strncmp(p, "return", 6)) {
            p += 6;
            while (*p == ' ' || *p == '(')
                p++;
            char quote = *p;
            if (quote == '"' || quote == '\'') {
                char *end = strchr(p + 1, quote);
                if (end) {
                    char *rest = end + 1;
                    while (*rest == ' ' || *rest == ')' || *rest == ';' || *rest == '\n' || *rest == '\t' || *rest == '\r')
                        rest++;
                    if (*rest == '}')
                        out = strndup(p + 1, (size_t)(end - p - 1));
                }
            }
        }
    }
    free(s);
    return out;
}

CFArrayRef
CFNetworkCopyProxiesForAutoConfigurationScript(CFStringRef script, CFURLRef targetURL, CFErrorRef *error)
{
    char *answer = script ? constant_answer(script) : NULL;
    if (!answer) {
        if (error)
            *error = CFErrorCreate(NULL, kCFErrorDomainCFNetwork, kCFErrorPACFileError, NULL);
        return NULL;
    }
    CFArrayRef list = parse_pac_result(answer);
    free(answer);
    if (error)
        *error = NULL;
    return list;
}

typedef struct {
    CFProxyAutoConfigurationResultCallback cb;
    CFStreamClientContext ctx;
    CFArrayRef result;
    CFErrorRef error;
} PACRun;

static void
pac_perform(void *info)
{
    PACRun *r = info;
    if (r->cb)
        r->cb(r->ctx.info, r->result, r->error);
    r->cb = NULL; /* once */
}

static void
pac_release(const void *info)
{
    PACRun *r = (PACRun *)info;
    if (r->ctx.release && r->ctx.info)
        r->ctx.release(r->ctx.info);
    if (r->result)
        CFRelease(r->result);
    if (r->error)
        CFRelease(r->error);
    free(r);
}

static CFRunLoopSourceRef
pac_source(CFArrayRef result, CFErrorRef error, CFProxyAutoConfigurationResultCallback cb, CFStreamClientContext *clientContext)
{
    PACRun *r = calloc(1, sizeof *r);
    r->cb = cb;
    if (clientContext) {
        r->ctx = *clientContext;
        if (r->ctx.retain && r->ctx.info)
            r->ctx.info = r->ctx.retain(r->ctx.info);
    }
    r->result = result;
    r->error = error;
    CFRunLoopSourceContext ctx = {0, r, NULL, pac_release, NULL, NULL, NULL, NULL, NULL, pac_perform};
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    CFRunLoopSourceSignal(source); /* fires once added to a run loop */
    return source;
}

CFRunLoopSourceRef
CFNetworkExecuteProxyAutoConfigurationScript(CFStringRef script, CFURLRef targetURL,
                                             CFProxyAutoConfigurationResultCallback cb, CFStreamClientContext *clientContext)
{
    CFErrorRef error = NULL;
    CFArrayRef result = CFNetworkCopyProxiesForAutoConfigurationScript(script, targetURL, &error);
    return pac_source(result, error, cb, clientContext);
}

CFRunLoopSourceRef
CFNetworkExecuteProxyAutoConfigurationURL(CFURLRef url, CFURLRef targetURL, CFProxyAutoConfigurationResultCallback cb,
                                          CFStreamClientContext *clientContext)
{
    /* the script is fetched (file: or http:) and read as above */
    CFErrorRef error = NULL;
    CFArrayRef result = NULL;
    CFStringRef scheme = url ? CFURLCopyScheme(url) : NULL;
    CFDataRef data = NULL;
    if (scheme && CFStringCompare(scheme, CFSTR("file"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        CFReadStreamRef s = CFReadStreamCreateWithFile(NULL, url);
        if (s && CFReadStreamOpen(s)) {
            CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
            UInt8 buf[4096];
            CFIndex n;
            while ((n = CFReadStreamRead(s, buf, sizeof buf)) > 0)
                CFDataAppendBytes(d, buf, n);
            CFReadStreamClose(s);
            data = d;
        }
        if (s)
            CFRelease(s);
    } else if (url) {
        CFHTTPMessageRef req = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url, kCFHTTPVersion1_1);
        CFReadStreamRef s = CFReadStreamCreateForHTTPRequest(NULL, req);
        CFRelease(req);
        CFReadStreamSetProperty(s, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
        if (CFReadStreamOpen(s)) {
            CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
            UInt8 buf[4096];
            CFIndex n;
            while ((n = CFReadStreamRead(s, buf, sizeof buf)) > 0)
                CFDataAppendBytes(d, buf, n);
            CFHTTPMessageRef resp = (CFHTTPMessageRef)CFReadStreamCopyProperty(s, kCFStreamPropertyHTTPResponseHeader);
            if (n == 0 && resp && CFHTTPMessageGetResponseStatusCode(resp) == 200)
                data = d;
            else
                CFRelease(d);
            if (resp)
                CFRelease(resp);
            CFReadStreamClose(s);
        }
        CFRelease(s);
    }
    if (scheme)
        CFRelease(scheme);
    if (data) {
        CFStringRef script = CFStringCreateFromExternalRepresentation(NULL, data, kCFStringEncodingUTF8);
        CFRelease(data);
        result = script ? CFNetworkCopyProxiesForAutoConfigurationScript(script, targetURL, &error) : NULL;
        if (script)
            CFRelease(script);
        if (!result && !error)
            error = CFErrorCreate(NULL, kCFErrorDomainCFNetwork, kCFErrorPACFileError, NULL);
    } else {
        error = CFErrorCreate(NULL, kCFErrorDomainCFNetwork, kCFErrorPACFileError, NULL);
    }
    return pac_source(result, error, cb, clientContext);
}

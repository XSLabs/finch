/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFHTTPAuthentication: the challenge in a 401 or 407 response, and the credentials
 * that answer it. Basic and Digest (RFC 7616: MD5 or SHA-256, qop "auth") are
 * answered; NTLM, Negotiate and Kerberos challenges are read but aren't valid on
 * Finch (there's no NTLM or Kerberos client), as a challenge with no usable scheme.
 */
#include "CFNetworkInternal.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

struct _CFHTTPAuthentication {
    CFRuntimeBase base;
    CFStringRef scheme; /* kCFHTTPAuthenticationScheme... */
    CFMutableDictionaryRef params; /* lower-cased parameter -> value */
    CFURLRef url;
    Boolean proxy, valid;
    uint32_t nc;
};

static CFTypeID auth_type;

static void
auth_finalize(CFTypeRef cf)
{
    struct _CFHTTPAuthentication *a = (struct _CFHTTPAuthentication *)cf;
    if (a->scheme)
        CFRelease(a->scheme);
    if (a->params)
        CFRelease(a->params);
    if (a->url)
        CFRelease(a->url);
}

static const CFRuntimeClass auth_class = {0, "CFHTTPAuthentication", NULL, NULL, auth_finalize, NULL, NULL, NULL, NULL,
                                          NULL, NULL, 0};

CFTypeID
CFHTTPAuthenticationGetTypeID(void)
{
    CFN_REGISTER(auth_type, auth_class);
}

/* Parses one challenge "Scheme a=b, c="d e"" from s at *at; returns the scheme. */
static CFStringRef
parse_challenge(const char *s, size_t *at, CFMutableDictionaryRef params)
{
    size_t i = *at;
    while (s[i] == ' ' || s[i] == ',')
        i++;
    size_t start = i;
    while (s[i] && s[i] != ' ' && s[i] != ',')
        i++;
    if (i == start) {
        *at = i;
        return NULL;
    }
    CFStringRef scheme = CFStringCreateWithBytes(NULL, (const UInt8 *)s + start, (CFIndex)(i - start),
                                                 kCFStringEncodingISOLatin1, false);
    for (;;) {
        while (s[i] == ' ' || s[i] == ',')
            i++;
        size_t k = i;
        while (s[i] && s[i] != '=' && s[i] != ' ' && s[i] != ',')
            i++;
        if (s[i] != '=') { /* the next challenge's scheme (or a token68) */
            i = k;
            break;
        }
        char key[64];
        size_t kl = i - k < sizeof key - 1 ? i - k : sizeof key - 1;
        for (size_t j = 0; j < kl; j++)
            key[j] = (char)tolower((unsigned char)s[k + j]);
        key[kl] = 0;
        i++;
        char value[1024];
        size_t vl = 0;
        if (s[i] == '"') {
            i++;
            while (s[i] && s[i] != '"') {
                if (s[i] == '\\' && s[i + 1])
                    i++;
                if (vl < sizeof value - 1)
                    value[vl++] = s[i];
                i++;
            }
            if (s[i] == '"')
                i++;
        } else {
            while (s[i] && s[i] != ',' && s[i] != ' ' && vl < sizeof value - 1)
                value[vl++] = s[i++];
        }
        value[vl] = 0;
        CFStringRef kk = CFStringCreateWithCString(NULL, key, kCFStringEncodingISOLatin1);
        CFStringRef vv = CFStringCreateWithCString(NULL, value, kCFStringEncodingISOLatin1);
        CFDictionarySetValue(params, kk, vv);
        CFRelease(kk);
        CFRelease(vv);
        if (!s[i])
            break;
    }
    *at = i;
    return scheme;
}

static int
scheme_rank(CFStringRef scheme)
{
    if (CFStringCompare(scheme, CFSTR("Digest"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
        return 3;
    if (CFStringCompare(scheme, CFSTR("Basic"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
        return 2;
    return 1;
}

static CFStringRef
canonical_scheme(CFStringRef scheme)
{
    CFStringRef known[] = {kCFHTTPAuthenticationSchemeBasic, kCFHTTPAuthenticationSchemeDigest,
                           kCFHTTPAuthenticationSchemeNTLM, kCFHTTPAuthenticationSchemeKerberos,
                           kCFHTTPAuthenticationSchemeNegotiate, kCFHTTPAuthenticationSchemeNegotiate2,
                           kCFHTTPAuthenticationSchemeXMobileMeAuthToken};
    for (size_t i = 0; i < sizeof known / sizeof *known; i++)
        if (CFStringCompare(scheme, known[i], kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            return CFRetain(known[i]);
    return CFRetain(scheme);
}

CFHTTPAuthenticationRef
CFHTTPAuthenticationCreateFromResponse(CFAllocatorRef alloc, CFHTTPMessageRef response)
{
    struct _CFHTTPAuthentication *a = cfn_create(CFHTTPAuthenticationGetTypeID(), sizeof(struct _CFHTTPAuthentication));
    CFIndex status = CFHTTPMessageGetResponseStatusCode(response);
    a->proxy = status == 407;
    CFStringRef header = cfn_message_header(response, a->proxy ? "Proxy-Authenticate" : "WWW-Authenticate");
    a->params = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    a->url = CFHTTPMessageCopyRequestURL(response);
    /* a response not from a request (no URL) has no challenge to answer, as Apple's */
    if (!header || !a->url)
        return a;
    char buf[4096];
    if (!CFStringGetCString(header, buf, sizeof buf, kCFStringEncodingISOLatin1))
        return a;
    /* several challenges: the strongest scheme Finch can answer */
    size_t at = 0;
    int best = 0;
    while (buf[at]) {
        CFMutableDictionaryRef params = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                  &kCFTypeDictionaryValueCallBacks);
        size_t before = at;
        CFStringRef scheme = parse_challenge(buf, &at, params);
        if (!scheme) {
            CFRelease(params);
            if (at == before)
                break;
            continue;
        }
        int rank = scheme_rank(scheme);
        if (rank > best) {
            best = rank;
            if (a->scheme)
                CFRelease(a->scheme);
            a->scheme = canonical_scheme(scheme);
            CFRelease(a->params);
            a->params = (CFMutableDictionaryRef)CFRetain(params);
        }
        CFRelease(scheme);
        CFRelease(params);
    }
    a->valid = best >= 2;
    return a;
}

Boolean
CFHTTPAuthenticationIsValid(CFHTTPAuthenticationRef auth, CFStreamError *error)
{
    if (!auth->valid && error) {
        error->domain = kCFStreamErrorDomainHTTP;
        error->error = auth->scheme ? kCFStreamErrorHTTPAuthenticationTypeUnsupported : kCFStreamErrorHTTPAuthenticationBadUserName;
    }
    return auth->valid;
}

Boolean
CFHTTPAuthenticationAppliesToRequest(CFHTTPAuthenticationRef auth, CFHTTPMessageRef request)
{
    if (!auth->url)
        return true;
    CFURLRef url = CFHTTPMessageCopyRequestURL(request);
    if (!url)
        return false;
    CFStringRef h1 = CFURLCopyHostName(auth->url), h2 = CFURLCopyHostName(url);
    Boolean same = h1 && h2 && CFStringCompare(h1, h2, kCFCompareCaseInsensitive) == kCFCompareEqualTo &&
                   CFURLGetPortNumber(auth->url) == CFURLGetPortNumber(url);
    if (h1)
        CFRelease(h1);
    if (h2)
        CFRelease(h2);
    CFRelease(url);
    return same;
}

Boolean CFHTTPAuthenticationRequiresOrderedRequests(CFHTTPAuthenticationRef auth) { return false; }
Boolean CFHTTPAuthenticationRequiresUserNameAndPassword(CFHTTPAuthenticationRef auth) { return true; }
Boolean CFHTTPAuthenticationRequiresAccountDomain(CFHTTPAuthenticationRef auth) { return false; }

CFStringRef
CFHTTPAuthenticationCopyRealm(CFHTTPAuthenticationRef auth)
{
    CFStringRef r = CFDictionaryGetValue(auth->params, CFSTR("realm"));
    return r ? CFRetain(r) : NULL;
}

CFArrayRef
CFHTTPAuthenticationCopyDomains(CFHTTPAuthenticationRef auth)
{
    CFArrayRef none = NULL; /* Apple's answers NULL for an invalid one, whatever the header says */
    if (!auth->valid)
        return none;
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef domain = CFDictionaryGetValue(auth->params, CFSTR("domain"));
    if (domain) {
        CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, domain, CFSTR(" "));
        for (CFIndex i = 0; i < CFArrayGetCount(parts); i++) {
            CFURLRef u = CFURLCreateWithString(NULL, CFArrayGetValueAtIndex(parts, i), auth->url);
            if (u) {
                CFArrayAppendValue(out, u);
                CFRelease(u);
            }
        }
        CFRelease(parts);
    } else if (auth->url) {
        CFURLRef root = CFURLCreateWithString(NULL, CFSTR("/"), auth->url);
        if (root) {
            CFURLRef abs = CFURLCopyAbsoluteURL(root);
            CFArrayAppendValue(out, abs);
            CFRelease(abs);
            CFRelease(root);
        }
    }
    return out;
}

CFStringRef
CFHTTPAuthenticationCopyMethod(CFHTTPAuthenticationRef auth)
{
    return auth->scheme ? CFRetain(auth->scheme) : NULL;
}

/* --- answering --- */

static CFStringRef
hex_digest(const char *text, Boolean sha256)
{
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    size_t n = sha256 ? CC_SHA256_DIGEST_LENGTH : CC_MD5_DIGEST_LENGTH;
    if (sha256)
        CC_SHA256(text, (CC_LONG)strlen(text), d);
    else
        CC_MD5(text, (CC_LONG)strlen(text), d);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (size_t i = 0; i < n; i++)
        snprintf(hex + 2 * i, 3, "%02x", d[i]);
    return CFStringCreateWithCString(NULL, hex, kCFStringEncodingASCII);
}

static void
cstr(CFStringRef s, char *buf, size_t size)
{
    buf[0] = 0;
    if (s)
        CFStringGetCString(s, buf, (CFIndex)size, kCFStringEncodingUTF8);
}

static CFStringRef
digest_header(struct _CFHTTPAuthentication *a, CFHTTPMessageRef request, CFStringRef username, CFStringRef password)
{
    char user[512], pass[512], realm[512], nonce[512], opaque[512], method[32], uri[2048], qop[64], algorithm[32];
    cstr(username, user, sizeof user);
    cstr(password, pass, sizeof pass);
    cstr(CFDictionaryGetValue(a->params, CFSTR("realm")), realm, sizeof realm);
    cstr(CFDictionaryGetValue(a->params, CFSTR("nonce")), nonce, sizeof nonce);
    cstr(CFDictionaryGetValue(a->params, CFSTR("opaque")), opaque, sizeof opaque);
    cstr(CFDictionaryGetValue(a->params, CFSTR("qop")), qop, sizeof qop);
    cstr(CFDictionaryGetValue(a->params, CFSTR("algorithm")), algorithm, sizeof algorithm);
    CFStringRef m = CFHTTPMessageCopyRequestMethod(request);
    cstr(m, method, sizeof method);
    if (m)
        CFRelease(m);
    CFURLRef url = CFHTTPMessageCopyRequestURL(request);
    CFStringRef path = url ? CFURLCopyPath(url) : NULL, query = url ? CFURLCopyQueryString(url, NULL) : NULL;
    char p[2048], q[2048];
    cstr(path, p, sizeof p);
    cstr(query, q, sizeof q);
    snprintf(uri, sizeof uri, "%s%s%s", p[0] ? p : "/", q[0] ? "?" : "", q);
    if (path)
        CFRelease(path);
    if (query)
        CFRelease(query);
    if (url)
        CFRelease(url);
    Boolean sha = strncasecmp(algorithm, "SHA-256", 7) == 0;
    Boolean useQop = strstr(qop, "auth") != NULL;
    char buf[4096], ha1s[80], ha2s[80], cnonce[17], ncs[9];
    snprintf(buf, sizeof buf, "%s:%s:%s", user, realm, pass);
    CFStringRef ha1 = hex_digest(buf, sha);
    snprintf(buf, sizeof buf, "%s:%s", method, uri);
    CFStringRef ha2 = hex_digest(buf, sha);
    cstr(ha1, ha1s, sizeof ha1s);
    cstr(ha2, ha2s, sizeof ha2s);
    CFRelease(ha1);
    CFRelease(ha2);
    snprintf(cnonce, sizeof cnonce, "%08x%08x", arc4random(), arc4random());
    snprintf(ncs, sizeof ncs, "%08x", ++a->nc);
    if (useQop)
        snprintf(buf, sizeof buf, "%s:%s:%s:%s:auth:%s", ha1s, nonce, ncs, cnonce, ha2s);
    else
        snprintf(buf, sizeof buf, "%s:%s:%s", ha1s, nonce, ha2s);
    CFStringRef response = hex_digest(buf, sha);
    char rs[80];
    cstr(response, rs, sizeof rs);
    CFRelease(response);
    char header[8192];
    int n = snprintf(header, sizeof header, "Digest username=\"%s\", realm=\"%s\", nonce=\"%s\", uri=\"%s\", response=\"%s\"",
                     user, realm, nonce, uri, rs);
    if (algorithm[0])
        n += snprintf(header + n, sizeof header - (size_t)n, ", algorithm=%s", algorithm);
    if (opaque[0])
        n += snprintf(header + n, sizeof header - (size_t)n, ", opaque=\"%s\"", opaque);
    if (useQop)
        snprintf(header + n, sizeof header - (size_t)n, ", qop=auth, nc=%s, cnonce=\"%s\"", ncs, cnonce);
    return CFStringCreateWithCString(NULL, header, kCFStringEncodingUTF8);
}

Boolean
CFHTTPMessageApplyCredentials(CFHTTPMessageRef request, CFHTTPAuthenticationRef auth, CFStringRef username,
                              CFStringRef password, CFStreamError *error)
{
    struct _CFHTTPAuthentication *a = (struct _CFHTTPAuthentication *)auth;
    if (!a->valid) {
        CFHTTPAuthenticationIsValid(auth, error);
        return false;
    }
    CFStringRef header = CFEqual(a->scheme, kCFHTTPAuthenticationSchemeDigest)
                             ? digest_header(a, request, username, password)
                             : cfn_basic_credentials(username, password);
    CFHTTPMessageSetHeaderFieldValue(request, a->proxy ? CFSTR("Proxy-Authorization") : CFSTR("Authorization"), header);
    CFRelease(header);
    if (error)
        error->domain = 0, error->error = 0;
    return true;
}

Boolean
CFHTTPMessageApplyCredentialDictionary(CFHTTPMessageRef request, CFHTTPAuthenticationRef auth, CFDictionaryRef dict,
                                       CFStreamError *error)
{
    return CFHTTPMessageApplyCredentials(request, auth, CFDictionaryGetValue(dict, kCFHTTPAuthenticationUsername),
                                         CFDictionaryGetValue(dict, kCFHTTPAuthenticationPassword), error);
}

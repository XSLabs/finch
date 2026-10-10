/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFHTTPMessage: an HTTP request or response, built or parsed. Header fields keep the
 * order and spelling they were given and are found without regard to case; setting
 * one already present replaces it. Parsing (CFHTTPMessageAppendBytes) takes bytes as
 * they arrive: the start line and header fields until the blank line, then the body.
 */
#include "CFNetworkInternal.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

struct __CFHTTPMessage {
    CFRuntimeBase base;
    Boolean isRequest;
    CFStringRef method, version, statusLine;
    CFURLRef url;
    CFIndex status;
    CFMutableArrayRef names, values; /* header fields in order */
    CFMutableDataRef body;
    CFMutableDataRef pending; /* bytes of the head not yet parsed */
    Boolean headerComplete;
    CFURLRef responseURL;
    Boolean bodyless; /* a stream's response header: the body went to the stream */
};

static CFTypeID message_type;

static void
message_finalize(CFTypeRef cf)
{
    struct __CFHTTPMessage *m = (struct __CFHTTPMessage *)cf;
    CFTypeRef owned[] = {m->method, m->version, m->statusLine, m->url, m->names, m->values, m->body, m->pending,
                         m->responseURL};
    for (size_t i = 0; i < sizeof owned / sizeof *owned; i++)
        if (owned[i])
            CFRelease(owned[i]);
}

static CFStringRef
message_description(CFTypeRef cf)
{
    struct __CFHTTPMessage *m = (struct __CFHTTPMessage *)cf;
    if (m->isRequest)
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CFHTTPMessage %p>{url = %@; request = %@}"), cf, m->url,
                                        m->method);
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CFHTTPMessage %p>{status = %ld}"), cf, (long)m->status);
}

static const CFRuntimeClass message_class = {0, "CFHTTPMessage", NULL, NULL, message_finalize, NULL, NULL, NULL,
                                             message_description, NULL, NULL, 0};

CFTypeID
CFHTTPMessageGetTypeID(void)
{
    CFN_REGISTER(message_type, message_class);
}

static struct __CFHTTPMessage *
message_alloc(Boolean isRequest)
{
    struct __CFHTTPMessage *m = cfn_create(CFHTTPMessageGetTypeID(), sizeof(struct __CFHTTPMessage));
    m->isRequest = isRequest;
    m->names = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    m->values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    m->body = CFDataCreateMutable(NULL, 0);
    m->version = CFRetain(kCFHTTPVersion1_1);
    return m;
}

CFHTTPMessageRef
CFHTTPMessageCreateRequest(CFAllocatorRef alloc, CFStringRef requestMethod, CFURLRef url, CFStringRef httpVersion)
{
    struct __CFHTTPMessage *m = message_alloc(true);
    m->method = CFStringCreateCopy(NULL, requestMethod);
    m->url = CFURLCopyAbsoluteURL(url);
    CFRelease(m->version);
    m->version = CFStringCreateCopy(NULL, httpVersion);
    m->headerComplete = true;
    return m;
}

static const char *
reason_phrase(CFIndex code)
{
    switch (code) {
    case 100: return "Continue";
    case 101: return "Switching Protocols";
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 204: return "No Content";
    case 206: return "Partial Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 407: return "Proxy Authentication Required";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 413: return "Payload Too Large";
    case 415: return "Unsupported Media Type";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    default: return "";
    }
}

CFHTTPMessageRef
CFHTTPMessageCreateResponse(CFAllocatorRef alloc, CFIndex statusCode, CFStringRef statusDescription,
                            CFStringRef httpVersion)
{
    struct __CFHTTPMessage *m = message_alloc(false);
    CFRelease(m->version);
    m->version = CFStringCreateCopy(NULL, httpVersion);
    m->status = statusCode;
    if (statusDescription)
        m->statusLine = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ %ld %@"), httpVersion, (long)statusCode,
                                                 statusDescription);
    else
        m->statusLine = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ %ld %s"), httpVersion, (long)statusCode,
                                                 reason_phrase(statusCode));
    m->headerComplete = true;
    return m;
}

CFHTTPMessageRef
CFHTTPMessageCreateEmpty(CFAllocatorRef alloc, Boolean isRequest)
{
    struct __CFHTTPMessage *m = message_alloc(isRequest);
    m->pending = CFDataCreateMutable(NULL, 0);
    return m;
}

CFHTTPMessageRef
CFHTTPMessageCreateCopy(CFAllocatorRef alloc, CFHTTPMessageRef message)
{
    struct __CFHTTPMessage *m = message_alloc(message->isRequest);
    m->method = message->method ? CFRetain(message->method) : NULL;
    CFRelease(m->version);
    m->version = CFRetain(message->version);
    m->statusLine = message->statusLine ? CFRetain(message->statusLine) : NULL;
    m->url = message->url ? CFRetain(message->url) : NULL;
    m->status = message->status;
    CFArrayAppendArray(m->names, message->names, CFRangeMake(0, CFArrayGetCount(message->names)));
    CFArrayAppendArray(m->values, message->values, CFRangeMake(0, CFArrayGetCount(message->values)));
    CFDataAppendBytes(m->body, CFDataGetBytePtr(message->body), CFDataGetLength(message->body));
    m->pending = message->pending ? CFDataCreateMutableCopy(NULL, 0, message->pending) : NULL;
    m->headerComplete = message->headerComplete;
    m->responseURL = message->responseURL ? CFRetain(message->responseURL) : NULL;
    return m;
}

Boolean CFHTTPMessageIsRequest(CFHTTPMessageRef message) { return message->isRequest; }
CFStringRef CFHTTPMessageCopyVersion(CFHTTPMessageRef message) { return CFRetain(message->version); }

CFDataRef
CFHTTPMessageCopyBody(CFHTTPMessageRef message)
{
    if (message->bodyless)
        return NULL;
    return CFDataGetLength(message->body) || message->headerComplete ? CFDataCreateCopy(NULL, message->body) : NULL;
}

void
CFHTTPMessageSetBody(CFHTTPMessageRef message, CFDataRef bodyData)
{
    CFDataSetLength(message->body, 0);
    if (bodyData)
        CFDataAppendBytes(message->body, CFDataGetBytePtr(bodyData), CFDataGetLength(bodyData));
}

static CFIndex
field_index(CFHTTPMessageRef m, CFStringRef name)
{
    CFIndex n = CFArrayGetCount(m->names);
    for (CFIndex i = 0; i < n; i++)
        if (CFStringCompare(CFArrayGetValueAtIndex(m->names, i), name, kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            return i;
    return kCFNotFound;
}

CFStringRef
CFHTTPMessageCopyHeaderFieldValue(CFHTTPMessageRef message, CFStringRef headerField)
{
    CFIndex i = headerField ? field_index(message, headerField) : kCFNotFound;
    return i == kCFNotFound ? NULL : CFRetain(CFArrayGetValueAtIndex(message->values, i));
}

CFStringRef
cfn_message_header(CFHTTPMessageRef message, const char *name)
{
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingASCII);
    CFIndex i = field_index(message, n);
    CFRelease(n);
    return i == kCFNotFound ? NULL : CFArrayGetValueAtIndex(message->values, i);
}

CFArrayRef
cfn_message_copy_header_names(CFHTTPMessageRef message)
{
    return CFArrayCreateCopy(NULL, message->names);
}

void
cfn_message_set_bodyless(CFHTTPMessageRef message)
{
    message->bodyless = true;
}

CFDictionaryRef
CFHTTPMessageCopyAllHeaderFields(CFHTTPMessageRef message)
{
    CFIndex n = CFArrayGetCount(message->names);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, n, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    for (CFIndex i = 0; i < n; i++)
        CFDictionarySetValue(d, CFArrayGetValueAtIndex(message->names, i), CFArrayGetValueAtIndex(message->values, i));
    return d;
}

void
CFHTTPMessageSetHeaderFieldValue(CFHTTPMessageRef message, CFStringRef headerField, CFStringRef value)
{
    if (!headerField)
        return;
    CFIndex i = field_index(message, headerField);
    if (!value) {
        if (i != kCFNotFound) {
            CFArrayRemoveValueAtIndex(message->names, i);
            CFArrayRemoveValueAtIndex(message->values, i);
        }
        return;
    }
    if (i != kCFNotFound) {
        CFArraySetValueAtIndex(message->values, i, value);
        return;
    }
    CFStringRef name = CFStringCreateCopy(NULL, headerField), v = CFStringCreateCopy(NULL, value);
    CFArrayAppendValue(message->names, name);
    CFArrayAppendValue(message->values, v);
    CFRelease(name);
    CFRelease(v);
}

/* --- parsing --- */

static CFStringRef
latin1(const uint8_t *p, CFIndex n)
{
    return CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingISOLatin1, false);
}

/* The start line: "METHOD target HTTP/x.y" or "HTTP/x.y code reason". */
static Boolean
parse_start(struct __CFHTTPMessage *m, const uint8_t *p, CFIndex n)
{
    const uint8_t *end = p + n, *sp1 = memchr(p, ' ', (size_t)n);
    if (!sp1)
        return false;
    if (m->isRequest) {
        const uint8_t *sp2 = memchr(sp1 + 1, ' ', (size_t)(end - sp1 - 1));
        if (!sp2)
            return false;
        m->method = latin1(p, sp1 - p);
        CFStringRef target = latin1(sp1 + 1, sp2 - sp1 - 1);
        m->url = CFURLCreateWithString(NULL, target, NULL);
        CFRelease(target);
        if (m->version)
            CFRelease(m->version);
        m->version = latin1(sp2 + 1, end - sp2 - 1);
        return true;
    }
    if (m->version)
        CFRelease(m->version);
    m->version = latin1(p, sp1 - p);
    m->status = strtol((const char *)sp1 + 1, NULL, 10);
    if (m->statusLine)
        CFRelease(m->statusLine);
    m->statusLine = latin1(p, n);
    return true;
}

static void
parse_field(struct __CFHTTPMessage *m, const uint8_t *p, CFIndex n)
{
    const uint8_t *colon = memchr(p, ':', (size_t)n);
    if (!colon)
        return;
    const uint8_t *v = colon + 1, *end = p + n;
    while (v < end && (*v == ' ' || *v == '\t'))
        v++;
    while (end > v && (end[-1] == ' ' || end[-1] == '\t'))
        end--;
    CFStringRef name = latin1(p, colon - p), value = latin1(v, end - v);
    /* a repeated field joins the earlier one with a comma, as RFC 9110 allows */
    CFIndex i = field_index(m, name);
    if (i != kCFNotFound) {
        CFStringRef joined = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@, %@"), CFArrayGetValueAtIndex(m->values, i),
                                                      value);
        CFArraySetValueAtIndex(m->values, i, joined);
        CFRelease(joined);
    } else {
        CFArrayAppendValue(m->names, name);
        CFArrayAppendValue(m->values, value);
    }
    CFRelease(name);
    CFRelease(value);
}

/* Parses complete lines from pending; returns false on a malformed head. */
static Boolean
parse_head(struct __CFHTTPMessage *m)
{
    const uint8_t *b = CFDataGetBytePtr(m->pending);
    CFIndex n = CFDataGetLength(m->pending), at = 0;
    Boolean started = m->method || m->statusLine;
    while (!m->headerComplete) {
        const uint8_t *nl = memchr(b + at, '\n', (size_t)(n - at));
        if (!nl)
            break;
        CFIndex len = nl - (b + at);
        if (len && b[at + len - 1] == '\r')
            len--;
        if (!started) {
            if (len == 0) { /* leading blank lines are skipped */
                at = nl - b + 1;
                continue;
            }
            if (!parse_start(m, b + at, len))
                return false;
            started = true;
        } else if (len == 0) {
            m->headerComplete = true;
        } else {
            parse_field(m, b + at, len);
        }
        at = nl - b + 1;
    }
    if (m->headerComplete && at < n)
        CFDataAppendBytes(m->body, b + at, n - at);
    CFDataReplaceBytes(m->pending, CFRangeMake(0, m->headerComplete ? n : at), NULL, 0);
    return true;
}

Boolean
CFHTTPMessageAppendBytes(CFHTTPMessageRef message, const UInt8 *newBytes, CFIndex numBytes)
{
    if (numBytes <= 0)
        return true;
    if (message->headerComplete) {
        CFDataAppendBytes(message->body, newBytes, numBytes);
        return true;
    }
    if (!message->pending)
        message->pending = CFDataCreateMutable(NULL, 0);
    CFDataAppendBytes(message->pending, newBytes, numBytes);
    return parse_head(message);
}

Boolean CFHTTPMessageIsHeaderComplete(CFHTTPMessageRef message) { return message->headerComplete; }

CFHTTPMessageRef
cfn_message_parse_response_head(const uint8_t *bytes, CFIndex length, CFIndex *consumed)
{
    CFHTTPMessageRef m = CFHTTPMessageCreateEmpty(NULL, false);
    /* only up to the blank line: the body is the caller's */
    for (CFIndex i = 0; i + 1 < length; i++) {
        if (bytes[i] == '\n' && (bytes[i + 1] == '\n' || (i + 2 < length && bytes[i + 1] == '\r' && bytes[i + 2] == '\n'))) {
            CFIndex end = bytes[i + 1] == '\n' ? i + 2 : i + 3;
            CFHTTPMessageAppendBytes(m, bytes, end);
            if (consumed)
                *consumed = end;
            return m;
        }
    }
    CFRelease(m);
    return NULL;
}

/* --- serializing --- */

static void
append_string(CFMutableDataRef d, CFStringRef s)
{
    CFIndex used = 0, n = CFStringGetLength(s);
    CFStringGetBytes(s, CFRangeMake(0, n), kCFStringEncodingISOLatin1, '?', false, NULL, 0, &used);
    UInt8 *buf = malloc((size_t)used + 1);
    CFStringGetBytes(s, CFRangeMake(0, n), kCFStringEncodingISOLatin1, '?', false, buf, used, &used);
    CFDataAppendBytes(d, buf, used);
    free(buf);
}

/* The request target: the URL's path and query ("/" when there's no path). */
static CFStringRef
request_target(CFURLRef url)
{
    CFStringRef path = CFURLCopyPath(url);
    CFStringRef query = CFURLCopyQueryString(url, NULL);
    CFStringRef t;
    if (query)
        t = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@?%@"), CFStringGetLength(path) ? path : CFSTR("/"), query);
    else
        t = CFStringCreateCopy(NULL, CFStringGetLength(path) ? path : CFSTR("/"));
    CFRelease(path);
    if (query)
        CFRelease(query);
    return t;
}

CFDataRef
CFHTTPMessageCopySerializedMessage(CFHTTPMessageRef message)
{
    if (!message->headerComplete)
        return NULL;
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    if (message->isRequest) {
        CFStringRef target = message->url ? request_target(message->url) : CFRetain(CFSTR("/"));
        CFStringRef line = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ %@ %@\r\n"), message->method, target,
                                                    message->version);
        append_string(d, line);
        CFRelease(line);
        CFRelease(target);
    } else {
        append_string(d, message->statusLine);
        CFDataAppendBytes(d, (const UInt8 *)"\r\n", 2);
    }
    for (CFIndex i = 0; i < CFArrayGetCount(message->names); i++) {
        append_string(d, CFArrayGetValueAtIndex(message->names, i));
        CFDataAppendBytes(d, (const UInt8 *)": ", 2);
        append_string(d, CFArrayGetValueAtIndex(message->values, i));
        CFDataAppendBytes(d, (const UInt8 *)"\r\n", 2);
    }
    CFDataAppendBytes(d, (const UInt8 *)"\r\n", 2);
    CFDataAppendBytes(d, CFDataGetBytePtr(message->body), CFDataGetLength(message->body));
    return d;
}

CFURLRef
CFHTTPMessageCopyRequestURL(CFHTTPMessageRef request)
{
    if (!request->isRequest)
        return request->responseURL ? CFRetain(request->responseURL) : NULL;
    return request->url ? CFRetain(request->url) : NULL;
}

CFStringRef
CFHTTPMessageCopyRequestMethod(CFHTTPMessageRef request)
{
    return request->isRequest && request->method ? CFRetain(request->method) : NULL;
}

CFIndex
CFHTTPMessageGetResponseStatusCode(CFHTTPMessageRef response)
{
    return response->isRequest ? 0 : response->status;
}

CFStringRef
CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef response)
{
    return !response->isRequest && response->statusLine ? CFRetain(response->statusLine) : NULL;
}

void
_CFHTTPMessageSetResponseURL(CFHTTPMessageRef response, CFURLRef url)
{
    if (response->responseURL)
        CFRelease(response->responseURL);
    response->responseURL = url ? CFRetain(url) : NULL;
}

/* --- Basic authentication, the old way (CFHTTPMessageAddAuthentication) --- */

static CFStringRef
base64(CFDataRef data)
{
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const UInt8 *p = CFDataGetBytePtr(data);
    CFIndex n = CFDataGetLength(data);
    char *out = malloc((size_t)(n + 2) / 3 * 4 + 1);
    CFIndex o = 0;
    for (CFIndex i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        out[o++] = table[v >> 18 & 63];
        out[o++] = table[v >> 12 & 63];
        out[o++] = i + 1 < n ? table[v >> 6 & 63] : '=';
        out[o++] = i + 2 < n ? table[v & 63] : '=';
    }
    out[o] = 0;
    CFStringRef s = CFStringCreateWithCString(NULL, out, kCFStringEncodingASCII);
    free(out);
    return s;
}

CFStringRef
cfn_basic_credentials(CFStringRef username, CFStringRef password)
{
    CFStringRef pair = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@:%@"), username ?: CFSTR(""), password ?: CFSTR(""));
    CFDataRef bytes = CFStringCreateExternalRepresentation(NULL, pair, kCFStringEncodingUTF8, 0);
    CFStringRef b64 = base64(bytes);
    CFStringRef header = CFStringCreateWithFormat(NULL, NULL, CFSTR("Basic %@"), b64);
    CFRelease(pair);
    CFRelease(bytes);
    CFRelease(b64);
    return header;
}

Boolean
CFHTTPMessageAddAuthentication(CFHTTPMessageRef request, CFHTTPMessageRef authenticationFailureResponse,
                               CFStringRef username, CFStringRef password, CFStringRef authenticationScheme,
                               Boolean forProxy)
{
    if (!request->isRequest)
        return false;
    if (authenticationScheme && !CFEqual(authenticationScheme, kCFHTTPAuthenticationSchemeBasic))
        return false;
    CFStringRef header = cfn_basic_credentials(username, password);
    CFHTTPMessageSetHeaderFieldValue(request, forProxy ? CFSTR("Proxy-Authorization") : CFSTR("Authorization"), header);
    CFRelease(header);
    return true;
}

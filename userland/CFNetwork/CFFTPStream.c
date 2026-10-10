/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * FTP: read streams that download a file or list a directory (a URL ending in "/"),
 * and write streams that upload, over passive-mode FTP; and the parsing of a listing's
 * lines (CFFTPCreateParsedResourceListing), as Apple's.
 *
 * The control connection's exchange (log in, TYPE I, PASV, then RETR, LIST or STOR)
 * happens in the open, which blocks until the data connection is up; the stream then
 * reads or writes that connection, and closing it reads the server's last reply.
 * Credentials come from the URL, else kCFStreamPropertyFTPUserName and
 * kCFStreamPropertyFTPPassword, else anonymous.
 */
#include "CFNetworkInternal.h"
#include <CoreFoundation/CFStream.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/dirent.h>
#include <time.h>
#include <unistd.h>

/* CoreFoundation's abstract stream (CFStreamAbstract.h, not in the SDK). */
typedef struct {
    CFIndex version;
    void *(*create)(CFReadStreamRef, void *);
    void (*finalize)(CFReadStreamRef, void *);
    CFStringRef (*copyDescription)(CFReadStreamRef, void *);
    Boolean (*open)(CFReadStreamRef, CFErrorRef *, Boolean *, void *);
    Boolean (*openCompleted)(CFReadStreamRef, CFErrorRef *, void *);
    CFIndex (*read)(CFReadStreamRef, UInt8 *, CFIndex, CFErrorRef *, Boolean *, void *);
    const UInt8 *(*getBuffer)(CFReadStreamRef, CFIndex, CFIndex *, CFErrorRef *, Boolean *, void *);
    Boolean (*canRead)(CFReadStreamRef, CFErrorRef *, void *);
    void (*close)(CFReadStreamRef, void *);
    CFTypeRef (*copyProperty)(CFReadStreamRef, CFStringRef, void *);
    Boolean (*setProperty)(CFReadStreamRef, CFStringRef, CFTypeRef, void *);
    void (*requestEvents)(CFReadStreamRef, CFOptionFlags, void *);
    void (*schedule)(CFReadStreamRef, CFRunLoopRef, CFStringRef, void *);
    void (*unschedule)(CFReadStreamRef, CFRunLoopRef, CFStringRef, void *);
} CFReadStreamCallBacks;

typedef struct {
    CFIndex version;
    void *(*create)(CFWriteStreamRef, void *);
    void (*finalize)(CFWriteStreamRef, void *);
    CFStringRef (*copyDescription)(CFWriteStreamRef, void *);
    Boolean (*open)(CFWriteStreamRef, CFErrorRef *, Boolean *, void *);
    Boolean (*openCompleted)(CFWriteStreamRef, CFErrorRef *, void *);
    CFIndex (*write)(CFWriteStreamRef, const UInt8 *, CFIndex, CFErrorRef *, void *);
    Boolean (*canWrite)(CFWriteStreamRef, CFErrorRef *, void *);
    void (*close)(CFWriteStreamRef, void *);
    CFTypeRef (*copyProperty)(CFWriteStreamRef, CFStringRef, void *);
    Boolean (*setProperty)(CFWriteStreamRef, CFStringRef, CFTypeRef, void *);
    void (*requestEvents)(CFWriteStreamRef, CFOptionFlags, void *);
    void (*schedule)(CFWriteStreamRef, CFRunLoopRef, CFStringRef, void *);
    void (*unschedule)(CFWriteStreamRef, CFRunLoopRef, CFStringRef, void *);
} CFWriteStreamCallBacks;

extern CFReadStreamRef CFReadStreamCreate(CFAllocatorRef, const CFReadStreamCallBacks *, void *);
extern CFWriteStreamRef CFWriteStreamCreate(CFAllocatorRef, const CFWriteStreamCallBacks *, void *);

/* --- listings --- */

static const char *const months[] = {"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"};

static int
month_index(const char *m)
{
    for (int i = 0; i < 12; i++)
        if (!strncasecmp(m, months[i], 3))
            return i;
    return -1;
}

static int
mode_bits(const char *p)
{
    int mode = 0;
    static const int bits[9] = {0400, 0200, 0100, 040, 020, 010, 04, 02, 01};
    for (int i = 0; i < 9 && p[i]; i++) {
        char c = p[i];
        if (c != '-' && c != 'S' && c != 'T')
            mode |= bits[i];
        if (i == 2 && (c == 's' || c == 'S'))
            mode |= 04000;
        if (i == 5 && (c == 's' || c == 'S'))
            mode |= 02000;
        if (i == 8 && (c == 't' || c == 'T'))
            mode |= 01000;
        if (c == 'S' || c == 'T')
            mode &= ~bits[i];
    }
    return mode;
}

static void
set_number(CFMutableDictionaryRef d, CFStringRef key, long long v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static void
set_string(CFMutableDictionaryRef d, CFStringRef key, const char *s)
{
    CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    if (!v)
        v = CFStringCreateWithCString(NULL, s, kCFStringEncodingISOLatin1);
    CFDictionarySetValue(d, key, v);
    CFRelease(v);
}

/* "-rw-r--r--  1 owner group 1234 Jan  5 12:34 name" (ls -l), else NULL. */
static CFDictionaryRef
parse_unix(char *line)
{
    char perms[16], owner[128], group[128], mon[8], dayStr[8], timeOrYear[8];
    long long links, size;
    int consumed = 0;
    if (sscanf(line, "%15s %lld %127s %127s %lld %7s %7s %7s %n", perms, &links, owner, group, &size, mon, dayStr,
               timeOrYear, &consumed) < 8 ||
        !consumed || strlen(perms) < 10)
        return NULL;
    int m = month_index(mon);
    if (m < 0)
        return NULL;
    char *name = line + consumed;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    int type = perms[0] == 'd' ? DT_DIR : perms[0] == 'l' ? DT_LNK : perms[0] == 'c' ? DT_CHR : perms[0] == 'b' ? DT_BLK
               : perms[0] == 'p' ? DT_FIFO : perms[0] == 's' ? DT_SOCK : DT_REG;
    const char *link = "";
    char *arrow = type == DT_LNK ? strstr(name, " -> ") : NULL;
    if (arrow) {
        *arrow = 0;
        link = arrow + 4;
    }
    set_string(d, kCFFTPResourceName, name);
    set_string(d, kCFFTPResourceLink, link);
    set_string(d, kCFFTPResourceOwner, owner);
    set_string(d, kCFFTPResourceGroup, group);
    set_number(d, kCFFTPResourceMode, mode_bits(perms + 1));
    set_number(d, kCFFTPResourceSize, size);
    set_number(d, kCFFTPResourceType, type);
    /* the date, local time: "12:34" in the last year, or a year at midnight */
    struct tm tm = {0};
    time_t now = time(NULL);
    struct tm today;
    localtime_r(&now, &today);
    tm.tm_mon = m;
    tm.tm_mday = atoi(dayStr);
    tm.tm_isdst = -1;
    if (strchr(timeOrYear, ':')) {
        tm.tm_hour = atoi(timeOrYear);
        tm.tm_min = atoi(strchr(timeOrYear, ':') + 1);
        tm.tm_year = today.tm_year;
        if (mktime(&(struct tm){.tm_year = tm.tm_year, .tm_mon = tm.tm_mon, .tm_mday = tm.tm_mday, .tm_isdst = -1}) > now + 86400)
            tm.tm_year--;
    } else {
        tm.tm_year = atoi(timeOrYear) - 1900;
    }
    time_t t = mktime(&tm);
    CFDateRef date = CFDateCreate(NULL, (CFAbsoluteTime)t - kCFAbsoluteTimeIntervalSince1970);
    CFDictionarySetValue(d, kCFFTPResourceModDate, date);
    CFRelease(date);
    return d;
}

CFIndex
CFFTPCreateParsedResourceListing(CFAllocatorRef alloc, const UInt8 *buffer, CFIndex bufferLength, CFDictionaryRef *parsed)
{
    if (parsed)
        *parsed = NULL;
    CFIndex at = 0;
    for (;;) {
        CFIndex end = at;
        while (end < bufferLength && buffer[end] != '\n' && buffer[end] != '\r')
            end++;
        if (end >= bufferLength)
            return 0; /* not a whole line yet */
        CFIndex next = end;
        while (next < bufferLength && (buffer[next] == '\n' || buffer[next] == '\r'))
            next++;
        size_t len = (size_t)(end - at);
        char *line = malloc(len + 1);
        memcpy(line, buffer + at, len);
        line[len] = 0;
        at = next;
        if (!len || !strncmp(line, "total ", 6)) {
            free(line);
            if (parsed)
                return at;
            continue;
        }
        CFDictionaryRef d = parse_unix(line);
        if (!d) {
            /* a form not known: the line as the name */
            CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
            set_string(m, kCFFTPResourceName, line);
            d = m;
        }
        free(line);
        if (parsed)
            *parsed = d;
        else
            CFRelease(d);
        return at;
    }
}

/* --- streams --- */

typedef struct {
    CFURLRef url;
    CFMutableDictionaryRef properties;
    cfn_conn control, data;
    bool opened, upload;
    char reply[1024];
    int64_t bytes;
} FTP;

static FTP *
ftp_new(CFURLRef url, bool upload)
{
    FTP *f = calloc(1, sizeof *f);
    f->url = CFRetain(url);
    f->upload = upload;
    f->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    cfn_conn_init(&f->control);
    cfn_conn_init(&f->data);
    return f;
}

static void
ftp_free(FTP *f)
{
    cfn_conn_close(&f->data, true);
    cfn_conn_close(&f->control, true);
    CFRelease(f->url);
    CFRelease(f->properties);
    free(f);
}

/* A reply's code (its last line's, for a multi-line reply), or -1. */
static int
ftp_reply(FTP *f)
{
    size_t n = 0;
    for (;;) {
        char c;
        ssize_t r = cfn_conn_read(&f->control, &c, 1);
        if (r <= 0)
            return -1;
        if (c == '\n') {
            f->reply[n] = 0;
            if (n && f->reply[n - 1] == '\r')
                f->reply[n - 1] = 0;
            if (n >= 4 && f->reply[0] >= '1' && f->reply[0] <= '5' && f->reply[3] == ' ')
                return atoi(f->reply);
            n = 0;
            continue;
        }
        if (n < sizeof f->reply - 1)
            f->reply[n++] = c;
    }
}

static int
ftp_command(FTP *f, const char *fmt, const char *arg)
{
    char line[1100];
    int n = snprintf(line, sizeof line, fmt, arg);
    if (n < 0 || !cfn_conn_write(&f->control, line, (size_t)n) || !cfn_conn_write(&f->control, "\r\n", 2))
        return -1;
    return ftp_reply(f);
}

static CFStringRef
property_string(FTP *f, CFStringRef key)
{
    CFStringRef v = CFDictionaryGetValue(f->properties, key);
    return v && CFGetTypeID(v) == CFStringGetTypeID() ? v : NULL;
}

static CFErrorRef
ftp_error(int code)
{
    return code < 0 ? cfn_error(kCFStreamErrorDomainPOSIX, errno ? errno : ECONNRESET) : cfn_error(6 /* FTP */, code);
}

/* Logs in and opens the data connection for the transfer. */
static bool
ftp_open(FTP *f, CFErrorRef *error)
{
    CFStringRef host = CFURLCopyHostName(f->url);
    char *h = cfn_cstring(host);
    if (host)
        CFRelease(host);
    if (!h) {
        *error = cfn_error(kCFStreamErrorDomainPOSIX, EINVAL);
        return false;
    }
    SInt32 port = CFURLGetPortNumber(f->url);
    CFStreamError err = {0, 0};
    if (!cfn_conn_connect(&f->control, h, port > 0 ? (int)port : 21, 75, &err)) {
        free(h);
        *error = _CFErrorCreateWithStreamError(NULL, &err);
        return false;
    }
    int code = ftp_reply(f);
    if (code != 220) {
        free(h);
        *error = ftp_error(code);
        return false;
    }
    CFStringRef user = CFURLCopyUserName(f->url), pass = CFURLCopyPassword(f->url);
    if (!user && property_string(f, kCFStreamPropertyFTPUserName))
        user = CFRetain(property_string(f, kCFStreamPropertyFTPUserName));
    if (!pass && property_string(f, kCFStreamPropertyFTPPassword))
        pass = CFRetain(property_string(f, kCFStreamPropertyFTPPassword));
    char *u = user ? cfn_cstring(user) : strdup("anonymous");
    char *p = pass ? cfn_cstring(pass) : strdup("");
    if (user)
        CFRelease(user);
    if (pass)
        CFRelease(pass);
    code = ftp_command(f, "USER %s", u);
    if (code == 331)
        code = ftp_command(f, "PASS %s", p);
    free(u);
    free(p);
    if (code != 230 && code != 202) {
        free(h);
        *error = ftp_error(code);
        return false;
    }
    CFStringRef path = CFURLCopyPath(f->url);
    char *pathStr = cfn_cstring(path);
    if (path)
        CFRelease(path);
    bool listing = !f->upload && pathStr && (!pathStr[0] || pathStr[strlen(pathStr) - 1] == '/');
    code = ftp_command(f, "TYPE %s", listing ? "A" : "I");
    code = ftp_command(f, "PASV%s", "");
    unsigned a[6];
    char *paren = strchr(f->reply, '(');
    if (code != 227 || !paren || sscanf(paren + 1, "%u,%u,%u,%u,%u,%u", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) != 6) {
        free(h);
        free(pathStr);
        *error = ftp_error(code);
        return false;
    }
    char dataHost[32];
    snprintf(dataHost, sizeof dataHost, "%u.%u.%u.%u", a[0], a[1], a[2], a[3]);
    if (!cfn_conn_connect(&f->data, dataHost, (int)(a[4] * 256 + a[5]), 75, &err)) {
        free(h);
        free(pathStr);
        *error = _CFErrorCreateWithStreamError(NULL, &err);
        return false;
    }
    free(h);
    /* the path is percent-decoded and relative to the login directory, as a URL's is */
    CFStringRef decoded = NULL;
    if (pathStr) {
        CFStringRef raw = CFStringCreateWithCString(NULL, pathStr, kCFStringEncodingUTF8);
        decoded = CFURLCreateStringByReplacingPercentEscapes(NULL, raw, CFSTR(""));
        CFRelease(raw);
    }
    char *target = decoded ? cfn_cstring(decoded) : strdup("");
    if (decoded)
        CFRelease(decoded);
    free(pathStr);
    const char *arg = target[0] == '/' ? target + 1 : target;
    if (f->upload)
        code = ftp_command(f, "STOR %s", arg);
    else if (listing)
        code = arg[0] ? ftp_command(f, "LIST %s", arg) : ftp_command(f, "LIST%s", "");
    else
        code = ftp_command(f, "RETR %s", arg);
    free(target);
    if (code != 125 && code != 150) {
        *error = ftp_error(code);
        return false;
    }
    f->opened = true;
    return true;
}

static void
ftp_finish(FTP *f)
{
    cfn_conn_close(&f->data, true);
    if (f->opened) {
        ftp_reply(f); /* 226 */
        ftp_command(f, "QUIT%s", "");
    }
    f->opened = false;
    cfn_conn_close(&f->control, true);
}

static CFTypeRef
ftp_copy_property(FTP *f, CFStringRef name)
{
    if (CFEqual(name, kCFStreamPropertyFTPResourceSize))
        return NULL;
    if (CFEqual(name, kCFStreamPropertyFTPFetchResourceInfo) || CFEqual(name, kCFStreamPropertyFTPUsePassiveMode))
        return CFRetain(kCFBooleanTrue);
    CFTypeRef v = CFDictionaryGetValue(f->properties, name);
    return v ? CFRetain(v) : NULL;
}

static Boolean
ftp_set_property(FTP *f, CFStringRef name, CFTypeRef value)
{
    if (value)
        CFDictionarySetValue(f->properties, name, value);
    else
        CFDictionaryRemoveValue(f->properties, name);
    return true;
}

static void
frs_finalize(CFReadStreamRef s, void *info)
{
    ftp_free(info);
}

static Boolean
frs_open(CFReadStreamRef s, CFErrorRef *error, Boolean *complete, void *info)
{
    *complete = true;
    return ftp_open(info, error);
}

static CFIndex
frs_read(CFReadStreamRef s, UInt8 *buf, CFIndex len, CFErrorRef *error, Boolean *atEOF, void *info)
{
    FTP *f = info;
    ssize_t n = cfn_conn_read(&f->data, buf, (size_t)len);
    if (n < 0) {
        *error = cfn_error(kCFStreamErrorDomainPOSIX, errno);
        return -1;
    }
    f->bytes += n;
    *atEOF = n == 0;
    return n;
}

static Boolean
frs_can_read(CFReadStreamRef s, CFErrorRef *error, void *info)
{
    return cfn_conn_readable(&((FTP *)info)->data);
}

static void
frs_close(CFReadStreamRef s, void *info)
{
    ftp_finish(info);
}

static CFTypeRef
frs_copy_property(CFReadStreamRef s, CFStringRef name, void *info)
{
    return ftp_copy_property(info, name);
}

static Boolean
frs_set_property(CFReadStreamRef s, CFStringRef name, CFTypeRef value, void *info)
{
    return ftp_set_property(info, name, value);
}

static const CFReadStreamCallBacks ftp_read_callbacks = {
    2, NULL, frs_finalize, NULL, frs_open, NULL, frs_read, NULL, frs_can_read, frs_close,
    frs_copy_property, frs_set_property, NULL, NULL, NULL};

static void
fws_finalize(CFWriteStreamRef s, void *info)
{
    ftp_free(info);
}

static Boolean
fws_open(CFWriteStreamRef s, CFErrorRef *error, Boolean *complete, void *info)
{
    *complete = true;
    return ftp_open(info, error);
}

static CFIndex
fws_write(CFWriteStreamRef s, const UInt8 *buf, CFIndex len, CFErrorRef *error, void *info)
{
    FTP *f = info;
    if (!cfn_conn_write(&f->data, buf, (size_t)len)) {
        *error = cfn_error(kCFStreamErrorDomainPOSIX, errno ? errno : EPIPE);
        return -1;
    }
    f->bytes += len;
    return len;
}

static Boolean
fws_can_write(CFWriteStreamRef s, CFErrorRef *error, void *info)
{
    return true;
}

static void
fws_close(CFWriteStreamRef s, void *info)
{
    ftp_finish(info);
}

static CFTypeRef
fws_copy_property(CFWriteStreamRef s, CFStringRef name, void *info)
{
    return ftp_copy_property(info, name);
}

static Boolean
fws_set_property(CFWriteStreamRef s, CFStringRef name, CFTypeRef value, void *info)
{
    return ftp_set_property(info, name, value);
}

static const CFWriteStreamCallBacks ftp_write_callbacks = {
    2, NULL, fws_finalize, NULL, fws_open, NULL, fws_write, fws_can_write, fws_close,
    fws_copy_property, fws_set_property, NULL, NULL, NULL};

CFReadStreamRef
CFReadStreamCreateWithFTPURL(CFAllocatorRef alloc, CFURLRef ftpURL)
{
    return ftpURL ? CFReadStreamCreate(alloc, &ftp_read_callbacks, ftp_new(ftpURL, false)) : NULL;
}

CFWriteStreamRef
CFWriteStreamCreateWithFTPURL(CFAllocatorRef alloc, CFURLRef ftpURL)
{
    return ftpURL ? CFWriteStreamCreate(alloc, &ftp_write_callbacks, ftp_new(ftpURL, true)) : NULL;
}

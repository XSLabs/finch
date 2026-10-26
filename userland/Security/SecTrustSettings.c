/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Trust settings: the user's, the administrator's and the system's choices of
 * which certificates to trust for what.
 *
 *   system  Finch's pinned root bundle (userland/certificates); read-only
 *   admin   /Library/Security/Trust Settings/Admin.plist, root's to change
 *   user    ~/Library/Security/Trust Settings/User.plist, the user's own
 *
 * Each file is macOS's trust settings record: trustVersion 1 and a trustList
 * keyed by the certificate's SHA-1 (upper-case hex), each with its issuerName,
 * serialNumber, modDate and trustSettings array. Finch also keeps the
 * certificate itself in its entry ("certificate"), so the settings stand alone.
 * Trust evaluation (SecObjects.c) asks _FinchTrustSettingsCopyForPolicies:
 * certificates set to trust as a root become anchors, denied ones fail any chain
 * they're in; a user's setting overrides the administrator's.
 *
 * FINCH_TRUST_SETTINGS_ROOT moves both files under another folder, for tests;
 * setuid programs ignore it.
 */
#include <Security/Security.h>
#include <Security/SecTrustSettings.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/sha.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "SecInternal.h"

#define ADMIN_FILE "/Library/Security/Trust Settings/Admin.plist"
#define USER_FILE "/Library/Security/Trust Settings/User.plist"

SEC_HIDDEN void _FinchTrustSettingsCopyForPolicies(CFArrayRef policies, CFArrayRef *anchors, CFArrayRef *denied);

/* ---- where they're kept ---- */

static bool settingsPath(SecTrustSettingsDomain domain, char *out, size_t size)
{
    const char *root = issetugid() ? NULL : getenv("FINCH_TRUST_SETTINGS_ROOT");
    if (domain == kSecTrustSettingsDomainAdmin)
        return (size_t)snprintf(out, size, "%s%s", root ? root : "", ADMIN_FILE) < size;
    if (domain != kSecTrustSettingsDomainUser)
        return false;
    struct passwd *pw = getpwuid(getuid());
    if (root)
        return (size_t)snprintf(out, size, "%s/user-%u%s", root, getuid(), USER_FILE) < size;
    return pw && pw->pw_dir && (size_t)snprintf(out, size, "%s%s", pw->pw_dir, USER_FILE) < size;
}

/* The record, or an empty one; NULL if the file is there but corrupt. */
static CFMutableDictionaryRef readRecord(SecTrustSettingsDomain domain, bool *corrupt)
{
    char path[PATH_MAX];
    *corrupt = false;
    CFMutableDictionaryRef record = NULL;
    if (settingsPath(domain, path, sizeof(path))) {
        int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat st;
        if (fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size < 16 << 20) {
            CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
            UInt8 buf[16384];
            ssize_t n;
            while ((n = read(fd, buf, sizeof(buf))) > 0)
                CFDataAppendBytes(data, buf, n);
            CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data,
                kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
            CFRelease(data);
            if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID() &&
                CFGetTypeID(CFDictionaryGetValue(plist, CFSTR("trustList")) ?: kCFNull) == CFDictionaryGetTypeID())
                record = (CFMutableDictionaryRef)plist;
            else {
                if (plist)
                    CFRelease(plist);
                *corrupt = true;
            }
        }
        if (fd >= 0)
            close(fd);
    }
    if (!record && !*corrupt) {
        record = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFMutableDictionaryRef list = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        int one = 1;
        CFNumberRef version = CFNumberCreate(NULL, kCFNumberIntType, &one);
        CFDictionarySetValue(record, CFSTR("trustVersion"), version);
        CFDictionarySetValue(record, CFSTR("trustList"), list);
        CFRelease(version);
        CFRelease(list);
    }
    return record;
}

/* Make the folders down to the file, owned by whoever writes it. */
static bool makeParents(const char *path, mode_t mode)
{
    char dir[PATH_MAX];
    strlcpy(dir, path, sizeof(dir));
    for (char *p = dir + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        if (mkdir(dir, mode) != 0 && errno != EEXIST)
            return false;
        *p = '/';
    }
    return true;
}

static OSStatus writeRecord(SecTrustSettingsDomain domain, CFDictionaryRef record)
{
    char path[PATH_MAX], temporary[PATH_MAX];
    if (domain == kSecTrustSettingsDomainSystem)
        return errSecDataNotModifiable;
    if (!settingsPath(domain, path, sizeof(path)))
        return errSecParam;
    /* The administrator's settings are root's (on macOS, an administrator's
       authorization through the security server). */
    if (domain == kSecTrustSettingsDomainAdmin && geteuid() != 0)
        return errAuthorizationDenied;
    mode_t mode = domain == kSecTrustSettingsDomainAdmin ? 0644 : 0600;
    if (!makeParents(path, domain == kSecTrustSettingsDomainAdmin ? 0755 : 0700))
        return errSecIO;
    CFDataRef data = CFPropertyListCreateData(NULL, record, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    if (!data)
        return errSecAllocate;
    snprintf(temporary, sizeof(temporary), "%s.XXXXXX", path);
    int fd = mkstemp(temporary);
    OSStatus status = errSecIO;
    if (fd >= 0) {
        const UInt8 *bytes = CFDataGetBytePtr(data);
        size_t left = (size_t)CFDataGetLength(data);
        bool ok = fchmod(fd, mode) == 0;
        while (ok && left > 0) {
            ssize_t n = write(fd, bytes, left);
            ok = n > 0;
            bytes += n > 0 ? n : 0;
            left -= n > 0 ? (size_t)n : 0;
        }
        ok = ok && fsync(fd) == 0;
        close(fd);
        if (ok && rename(temporary, path) == 0)
            status = errSecSuccess;
        else
            unlink(temporary);
    }
    CFRelease(data);
    return status;
}

/* ---- certificates ---- */

static CFStringRef copyKey(SecCertificateRef cert)
{
    CFDataRef der = SecCertificateCopyData(cert);
    if (!der)
        return NULL;
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1(CFDataGetBytePtr(der), (size_t)CFDataGetLength(der), digest);
    CFRelease(der);
    char hex[2 * SHA_DIGEST_LENGTH + 1];
    for (int i = 0; i < SHA_DIGEST_LENGTH; i++)
        snprintf(hex + 2 * i, 3, "%02X", digest[i]);
    return CFStringCreateWithCString(NULL, hex, kCFStringEncodingASCII);
}

static bool selfIssued(SecCertificateRef cert)
{
    CFDataRef subject = SecCertificateCopyNormalizedSubjectSequence(cert);
    CFDataRef issuer = SecCertificateCopyNormalizedIssuerSequence(cert);
    bool same = subject && issuer && CFEqual(subject, issuer);
    if (subject) CFRelease(subject);
    if (issuer) CFRelease(issuer);
    return same;
}

static CFStringRef copyPolicyOID(SecPolicyRef policy)
{
    CFDictionaryRef properties = SecPolicyCopyProperties(policy);
    CFStringRef oid = properties ? CFDictionaryGetValue(properties, kSecPolicyOid) : NULL;
    if (oid)
        CFRetain(oid);
    if (properties)
        CFRelease(properties);
    return oid;
}

/*
 * The caller's settings, as stored: an array of dictionaries, policies by OID.
 * NULL (no constraints) is an empty array: trust as a root for everything.
 */
static CFArrayRef copyStoredSettings(CFTypeRef settings, SecCertificateRef cert, OSStatus *status)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayRef list = NULL;
    *status = errSecSuccess;
    if (settings == NULL)
        list = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    else if (CFGetTypeID(settings) == CFDictionaryGetTypeID())
        list = CFArrayCreate(NULL, &settings, 1, &kCFTypeArrayCallBacks);
    else if (CFGetTypeID(settings) == CFArrayGetTypeID())
        list = CFRetain(settings);
    else {
        CFRelease(out);
        *status = errSecParam;
        return NULL;
    }
    bool root = selfIssued(cert);
    for (CFIndex i = 0; i < CFArrayGetCount(list) && *status == errSecSuccess; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        if (CFGetTypeID(d) != CFDictionaryGetTypeID()) {
            *status = errSecParam;
            break;
        }
        CFMutableDictionaryRef stored = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFTypeRef policy = CFDictionaryGetValue(d, kSecTrustSettingsPolicy);
        if (policy) {
            CFStringRef oid = CFGetTypeID(policy) == SecPolicyGetTypeID() ? copyPolicyOID((SecPolicyRef)policy) : NULL;
            if (!oid)
                *status = errSecParam;
            else {
                CFDictionarySetValue(stored, kSecTrustSettingsPolicy, oid);
                CFRelease(oid);
            }
        }
        CFTypeRef string = CFDictionaryGetValue(d, kSecTrustSettingsPolicyString);
        if (string && CFGetTypeID(string) == CFStringGetTypeID())
            CFDictionarySetValue(stored, kSecTrustSettingsPolicyString, string);
        CFTypeRef result = CFDictionaryGetValue(d, kSecTrustSettingsResult);
        SInt32 r = kSecTrustSettingsResultTrustRoot;
        if (result && (CFGetTypeID(result) != CFNumberGetTypeID() ||
            !CFNumberGetValue(result, kCFNumberSInt32Type, &r) ||
            r < kSecTrustSettingsResultTrustRoot || r > kSecTrustSettingsResultUnspecified))
            *status = errSecParam;
        /* Only a self-signed certificate can be trusted as a root. */
        if (r == kSecTrustSettingsResultTrustRoot && !root)
            *status = errSecParam;
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &r);
        CFDictionarySetValue(stored, kSecTrustSettingsResult, number);
        CFRelease(number);
        CFTypeRef allowed = CFDictionaryGetValue(d, kSecTrustSettingsAllowedError);
        if (allowed && CFGetTypeID(allowed) == CFNumberGetTypeID())
            CFDictionarySetValue(stored, kSecTrustSettingsAllowedError, allowed);
        CFArrayAppendValue(out, stored);
        CFRelease(stored);
    }
    if (list)
        CFRelease(list);
    if (*status != errSecSuccess) {
        CFRelease(out);
        return NULL;
    }
    /* With no constraint at all, a non-root is trusted as a root. */
    if (CFArrayGetCount(out) == 0 && !root) {
        SInt32 r = kSecTrustSettingsResultTrustAsRoot;
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &r);
        const void *k[] = { kSecTrustSettingsResult }, *v[] = { number };
        CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(out, d);
        CFRelease(d);
        CFRelease(number);
    }
    return out;
}

/* ---- the API ---- */

OSStatus
SecTrustSettingsSetTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFTypeRef trustSettingsDictOrArray)
{
    if (!certRef || CFGetTypeID(certRef) != SecCertificateGetTypeID())
        return errSecParam;
    if (domain == kSecTrustSettingsDomainSystem)
        return errSecDataNotModifiable;
    if (domain != kSecTrustSettingsDomainUser && domain != kSecTrustSettingsDomainAdmin)
        return errSecParam;
    OSStatus status;
    CFArrayRef settings = copyStoredSettings(trustSettingsDictOrArray, certRef, &status);
    if (!settings)
        return status;
    bool corrupt;
    CFMutableDictionaryRef record = readRecord(domain, &corrupt);
    if (!record) {
        CFRelease(settings);
        return errSecInvalidTrustSettings;
    }
    CFStringRef key = copyKey(certRef);
    CFDataRef der = SecCertificateCopyData(certRef);
    CFDataRef issuer = SecCertificateCopyNormalizedIssuerSequence(certRef);
    CFDataRef serial = SecCertificateCopySerialNumberData(certRef, NULL);
    CFDateRef now = CFDateCreate(NULL, CFAbsoluteTimeGetCurrent());
    CFMutableDictionaryRef entry = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    status = key && der && issuer && serial && now && entry ? errSecSuccess : errSecAllocate;
    if (status == errSecSuccess) {
        CFDictionarySetValue(entry, CFSTR("issuerName"), issuer);
        CFDictionarySetValue(entry, CFSTR("serialNumber"), serial);
        CFDictionarySetValue(entry, CFSTR("modDate"), now);
        CFDictionarySetValue(entry, CFSTR("trustSettings"), settings);
        CFDictionarySetValue(entry, CFSTR("certificate"), der);
        CFDictionarySetValue((CFMutableDictionaryRef)CFDictionaryGetValue(record, CFSTR("trustList")), key, entry);
        status = writeRecord(domain, record);
    }
    if (key) CFRelease(key);
    if (der) CFRelease(der);
    if (issuer) CFRelease(issuer);
    if (serial) CFRelease(serial);
    if (now) CFRelease(now);
    if (entry) CFRelease(entry);
    CFRelease(settings);
    CFRelease(record);
    return status;
}

OSStatus
SecTrustSettingsRemoveTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain)
{
    if (!certRef || CFGetTypeID(certRef) != SecCertificateGetTypeID())
        return errSecParam;
    if (domain == kSecTrustSettingsDomainSystem)
        return errSecDataNotModifiable;
    bool corrupt;
    CFMutableDictionaryRef record = readRecord(domain, &corrupt);
    if (!record)
        return corrupt ? errSecInvalidTrustSettings : errSecParam;
    CFStringRef key = copyKey(certRef);
    CFMutableDictionaryRef list = (CFMutableDictionaryRef)CFDictionaryGetValue(record, CFSTR("trustList"));
    OSStatus status = errSecItemNotFound;
    if (key && CFDictionaryContainsKey(list, key)) {
        CFDictionaryRemoveValue(list, key);
        status = writeRecord(domain, record);
    }
    if (key) CFRelease(key);
    CFRelease(record);
    return status;
}

static CFDictionaryRef copyEntry(SecCertificateRef certRef, SecTrustSettingsDomain domain, OSStatus *status)
{
    *status = errSecParam;
    if (!certRef || CFGetTypeID(certRef) != SecCertificateGetTypeID())
        return NULL;
    bool corrupt;
    CFMutableDictionaryRef record = readRecord(domain, &corrupt);
    if (!record) {
        *status = corrupt ? errSecInvalidTrustSettings : errSecParam;
        return NULL;
    }
    CFStringRef key = copyKey(certRef);
    CFDictionaryRef entry = key ? CFDictionaryGetValue(CFDictionaryGetValue(record, CFSTR("trustList")), key) : NULL;
    if (entry)
        CFRetain(entry);
    if (key) CFRelease(key);
    CFRelease(record);
    *status = entry ? errSecSuccess : errSecItemNotFound;
    return entry;
}

OSStatus
SecTrustSettingsCopyTrustSettings(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFArrayRef *trustSettings)
{
    if (trustSettings)
        *trustSettings = NULL;
    if (!trustSettings)
        return errSecParam;
    if (domain == kSecTrustSettingsDomainSystem)
        return certRef ? errSecItemNotFound : errSecParam;
    OSStatus status;
    CFDictionaryRef entry = copyEntry(certRef, domain, &status);
    if (!entry)
        return status;
    /* Policies go back as SecPolicyRefs. */
    CFArrayRef stored = CFDictionaryGetValue(entry, CFSTR("trustSettings"));
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; stored && CFGetTypeID(stored) == CFArrayGetTypeID() && i < CFArrayGetCount(stored); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(stored, i);
        CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, d);
        CFTypeRef oid = CFDictionaryGetValue(d, kSecTrustSettingsPolicy);
        if (oid && CFGetTypeID(oid) == CFStringGetTypeID()) {
            SecPolicyRef policy = SecPolicyCreateWithProperties(oid, NULL);
            if (policy) {
                CFDictionarySetValue(copy, kSecTrustSettingsPolicy, policy);
                CFRelease(policy);
            } else
                CFDictionaryRemoveValue(copy, kSecTrustSettingsPolicy);
        }
        CFArrayAppendValue(out, copy);
        CFRelease(copy);
    }
    CFRelease(entry);
    *trustSettings = out;
    return errSecSuccess;
}

OSStatus
SecTrustSettingsCopyModificationDate(SecCertificateRef certRef, SecTrustSettingsDomain domain, CFDateRef *modificationDate)
{
    if (modificationDate)
        *modificationDate = NULL;
    if (!modificationDate)
        return errSecParam;
    if (domain == kSecTrustSettingsDomainSystem)
        return certRef ? errSecItemNotFound : errSecParam;
    OSStatus status;
    CFDictionaryRef entry = copyEntry(certRef, domain, &status);
    if (!entry)
        return status;
    CFDateRef date = CFDictionaryGetValue(entry, CFSTR("modDate"));
    if (date && CFGetTypeID(date) == CFDateGetTypeID())
        *modificationDate = CFRetain(date);
    CFRelease(entry);
    return *modificationDate ? errSecSuccess : errSecInvalidTrustSettings;
}

OSStatus
SecTrustSettingsCopyCertificates(SecTrustSettingsDomain domain, CFArrayRef *certArray)
{
    if (certArray)
        *certArray = NULL;
    if (domain == kSecTrustSettingsDomainSystem) {
        CFArrayRef anchors = NULL;
        OSStatus status = SecTrustCopyAnchorCertificates(&anchors);
        if (status == errSecSuccess && anchors && CFArrayGetCount(anchors) == 0) {
            CFRelease(anchors);
            return errSecNoTrustSettings;
        }
        if (certArray)
            *certArray = anchors;
        else if (anchors)
            CFRelease(anchors);
        return status;
    }
    bool corrupt;
    CFMutableDictionaryRef record = readRecord(domain, &corrupt);
    if (!record)
        return corrupt ? errSecInvalidTrustSettings : errSecParam;
    CFDictionaryRef list = CFDictionaryGetValue(record, CFSTR("trustList"));
    CFIndex n = CFDictionaryGetCount(list);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (n > 0) {
        const void **entries = calloc((size_t)n, sizeof(*entries));
        CFDictionaryGetKeysAndValues(list, NULL, entries);
        for (CFIndex i = 0; i < n; i++) {
            CFDataRef der = CFGetTypeID(entries[i]) == CFDictionaryGetTypeID() ?
                CFDictionaryGetValue(entries[i], CFSTR("certificate")) : NULL;
            SecCertificateRef cert = der && CFGetTypeID(der) == CFDataGetTypeID() ?
                SecCertificateCreateWithData(NULL, der) : NULL;
            if (cert) {
                CFArrayAppendValue(out, cert);
                CFRelease(cert);
            }
        }
        free(entries);
    }
    CFRelease(record);
    if (CFArrayGetCount(out) == 0) {
        CFRelease(out);
        return errSecNoTrustSettings;
    }
    if (certArray)
        *certArray = out;
    else
        CFRelease(out);
    return errSecSuccess;
}

OSStatus
SecTrustSettingsCreateExternalRepresentation(SecTrustSettingsDomain domain, CFDataRef *trustSettings)
{
    if (trustSettings)
        *trustSettings = NULL;
    if (!trustSettings || domain == kSecTrustSettingsDomainSystem)
        return domain == kSecTrustSettingsDomainSystem ? errSecNoTrustSettings : errSecParam;
    bool corrupt;
    CFMutableDictionaryRef record = readRecord(domain, &corrupt);
    if (!record)
        return corrupt ? errSecInvalidTrustSettings : errSecParam;
    if (CFDictionaryGetCount(CFDictionaryGetValue(record, CFSTR("trustList"))) == 0) {
        CFRelease(record);
        return errSecNoTrustSettings;
    }
    *trustSettings = CFPropertyListCreateData(NULL, record, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(record);
    return *trustSettings ? errSecSuccess : errSecAllocate;
}

OSStatus
SecTrustSettingsImportExternalRepresentation(SecTrustSettingsDomain domain, CFDataRef trustSettings)
{
    if (!trustSettings || CFGetTypeID(trustSettings) != CFDataGetTypeID())
        return errSecParam;
    if (domain == kSecTrustSettingsDomainSystem)
        return errSecDataNotModifiable;
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, trustSettings, kCFPropertyListImmutable, NULL, NULL);
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID() ||
        !CFDictionaryGetValue(plist, CFSTR("trustList")) ||
        CFGetTypeID(CFDictionaryGetValue(plist, CFSTR("trustList"))) != CFDictionaryGetTypeID()) {
        if (plist)
            CFRelease(plist);
        return errSecInvalidTrustSettings;
    }
    OSStatus status = writeRecord(domain, plist);
    CFRelease(plist);
    return status;
}

/* ---- for trust evaluation ---- */

/* The result a certificate's settings give for these policies (their OIDs, and
   the host names SSL policies name), or 0 for none. */
static SInt32 resultFor(CFArrayRef settings, CFArrayRef policyOIDs, CFArrayRef names)
{
    if (!settings || CFGetTypeID(settings) != CFArrayGetTypeID())
        return 0;
    if (CFArrayGetCount(settings) == 0)
        return kSecTrustSettingsResultTrustRoot;
    for (CFIndex i = 0; i < CFArrayGetCount(settings); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(settings, i);
        if (CFGetTypeID(d) != CFDictionaryGetTypeID())
            continue;
        CFTypeRef oid = CFDictionaryGetValue(d, kSecTrustSettingsPolicy);
        if (oid && !CFArrayContainsValue(policyOIDs, CFRangeMake(0, CFArrayGetCount(policyOIDs)), oid))
            continue;
        /* A setting for one host name applies only to it. */
        CFTypeRef string = CFDictionaryGetValue(d, kSecTrustSettingsPolicyString);
        if (string && !CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), string))
            continue;
        SInt32 r = kSecTrustSettingsResultTrustRoot;
        CFTypeRef number = CFDictionaryGetValue(d, kSecTrustSettingsResult);
        if (number && CFGetTypeID(number) == CFNumberGetTypeID())
            CFNumberGetValue(number, kCFNumberSInt32Type, &r);
        return r;
    }
    return 0;
}

void
_FinchTrustSettingsCopyForPolicies(CFArrayRef policies, CFArrayRef *anchorsOut, CFArrayRef *deniedOut)
{
    CFMutableArrayRef oids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef names = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; policies && i < CFArrayGetCount(policies); i++) {
        CFDictionaryRef properties = SecPolicyCopyProperties((SecPolicyRef)CFArrayGetValueAtIndex(policies, i));
        CFTypeRef oid = properties ? CFDictionaryGetValue(properties, kSecPolicyOid) : NULL;
        CFTypeRef name = properties ? CFDictionaryGetValue(properties, kSecPolicyName) : NULL;
        if (oid)
            CFArrayAppendValue(oids, oid);
        if (name && CFGetTypeID(name) == CFStringGetTypeID())
            CFArrayAppendValue(names, name);
        if (properties)
            CFRelease(properties);
    }
    /* Each certificate's result: the administrator's, then the user's over it. */
    CFMutableDictionaryRef results = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef certificates = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    const SecTrustSettingsDomain domains[] = { kSecTrustSettingsDomainAdmin, kSecTrustSettingsDomainUser };
    for (int d = 0; d < 2; d++) {
        bool corrupt;
        CFMutableDictionaryRef record = readRecord(domains[d], &corrupt);
        if (!record)
            continue;
        CFDictionaryRef list = CFDictionaryGetValue(record, CFSTR("trustList"));
        CFIndex n = CFDictionaryGetCount(list);
        const void **keys = calloc((size_t)(n ? n : 1), sizeof(*keys));
        const void **entries = calloc((size_t)(n ? n : 1), sizeof(*entries));
        CFDictionaryGetKeysAndValues(list, keys, entries);
        for (CFIndex i = 0; i < n; i++) {
            if (CFGetTypeID(entries[i]) != CFDictionaryGetTypeID())
                continue;
            CFDataRef der = CFDictionaryGetValue(entries[i], CFSTR("certificate"));
            SInt32 r = resultFor(CFDictionaryGetValue(entries[i], CFSTR("trustSettings")), oids, names);
            if (!der || CFGetTypeID(der) != CFDataGetTypeID() || r == 0 ||
                r == kSecTrustSettingsResultUnspecified)
                continue;
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &r);
            CFDictionarySetValue(results, keys[i], number);
            CFRelease(number);
            CFDictionarySetValue(certificates, keys[i], der);
        }
        free(keys);
        free(entries);
        CFRelease(record);
    }
    CFMutableArrayRef anchors = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableArrayRef denied = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFIndex n = CFDictionaryGetCount(results);
    const void **keys = calloc((size_t)(n ? n : 1), sizeof(*keys));
    const void **values = calloc((size_t)(n ? n : 1), sizeof(*values));
    CFDictionaryGetKeysAndValues(results, keys, values);
    for (CFIndex i = 0; i < n; i++) {
        SInt32 r = 0;
        CFNumberGetValue(values[i], kCFNumberSInt32Type, &r);
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, CFDictionaryGetValue(certificates, keys[i]));
        if (!cert)
            continue;
        if (r == kSecTrustSettingsResultTrustRoot || r == kSecTrustSettingsResultTrustAsRoot)
            CFArrayAppendValue(anchors, cert);
        else if (r == kSecTrustSettingsResultDeny)
            CFArrayAppendValue(denied, cert);
        CFRelease(cert);
    }
    free(keys);
    free(values);
    CFRelease(results);
    CFRelease(certificates);
    CFRelease(oids);
    CFRelease(names);
    *anchorsOut = anchors;
    *deniedOut = denied;
}

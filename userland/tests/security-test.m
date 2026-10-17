/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-security-test: Security.framework, as apps use it. Constants,
 * random bytes, error strings, certificates, keys, policies and trust,
 * the keychain (SecItem and the SecKeychain calls, in a keychain the test
 * creates and deletes), code signing queries, SecTask, Authorization and
 * access objects. Prints shapes and error codes, not machine-specific
 * values: run it against Apple's framework and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line.
 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Security/SecCustomTransform.h>
#import <Security/SecProtocolTypes.h>
#import <Security/SecStaticCode.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <unistd.h>

#include "security-test-certs.inc"

/* Call the C OS-object helpers directly in this ARC test. */
#undef sec_retain
#undef sec_release
void *sec_retain(void *object);
void sec_release(void *object);

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* SPI apps import (Apple's SecTrustPriv.h) */
CFDataRef SecTrustSerialize(SecTrustRef trust, CFErrorRef *error);
SecTrustRef SecTrustDeserialize(CFDataRef serializedTrust, CFErrorRef *error);
/* SecTrustedApplicationPriv.h */
OSStatus SecTrustedApplicationCreateApplicationGroup(const char *groupName, SecCertificateRef anchor, SecTrustedApplicationRef *app);

static NSString *
hex(NSData *d)
{
    NSMutableString *s = [NSMutableString string];
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++)
        [s appendFormat:@"%02x", p[i]];
    return s;
}

static NSString *
sha(NSData *d)
{
    uint8_t md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, md);
    return [hex([NSData dataWithBytes:md length:8]) stringByAppendingString:@".."];
}

static long
errcode(CFErrorRef e)
{
    return e ? (long)CFErrorGetCode(e) : 0;
}

static NSString *
domain(CFErrorRef e)
{
    return e ? (__bridge NSString *)CFErrorGetDomain(e) : @"-";
}

static NSString *
keys(NSDictionary *d)
{
    return [[d.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

static NSString *
typeName(id v)
{
    if (!v)
        return @"nil";
    CFTypeID t = CFGetTypeID((__bridge CFTypeRef)v);
    if (t == CFStringGetTypeID()) return @"string";
    if (t == CFNumberGetTypeID()) return @"number";
    if (t == CFBooleanGetTypeID()) return @"bool";
    if (t == CFDataGetTypeID()) return @"data";
    if (t == CFDateGetTypeID()) return @"date";
    if (t == CFArrayGetTypeID()) return @"array";
    if (t == CFDictionaryGetTypeID()) return @"dict";
    if (t == SecCertificateGetTypeID()) return @"cert";
    if (t == SecKeyGetTypeID()) return @"key";
    if (t == SecIdentityGetTypeID()) return @"identity";
    if (t == SecKeychainItemGetTypeID()) return @"kcitem";
    return @"other";
}

static void
constants(void)
{
    printf("== constants\n");
    static const char *names[] = {
        "kSecClass", "kSecClassGenericPassword", "kSecClassInternetPassword", "kSecClassKey",
        "kSecClassIdentity", "kSecClassCertificate", "kSecAttrAccount", "kSecAttrService",
        "kSecAttrLabel", "kSecAttrDescription", "kSecAttrGeneric", "kSecAttrServer", "kSecAttrProtocol",
        "kSecAttrType", "kSecAttrIsInvisible", "kSecAttrAccess", "kSecAttrAccessGroup",
        "kSecAttrSynchronizable", "kSecAttrSynchronizableAny", "kSecAttrKeyType", "kSecAttrKeyTypeRSA",
        "kSecAttrKeyTypeECSECPrimeRandom", "kSecAttrKeyClass", "kSecAttrKeyClassPublic",
        "kSecAttrKeyClassPrivate", "kSecAttrApplicationTag", "kSecAttrKeySizeInBits",
        "kSecReturnData", "kSecReturnRef", "kSecReturnAttributes", "kSecReturnPersistentRef",
        "kSecValueData", "kSecValueRef", "kSecValuePersistentRef", "kSecMatchLimit", "kSecMatchLimitOne",
        "kSecMatchLimitAll", "kSecMatchPolicy", "kSecMatchSearchList", "kSecUseKeychain",
        "kSecPolicyAppleCodeSigning", "kSecPolicyAppleX509Basic", "kSecPolicyAppleSSL",
        "kSecPolicyName", "kSecPolicyOid", "kSecPolicyClient",
        "kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1", "kSecKeyAlgorithmRSAEncryptionOAEPSHA1",
        "kSecKeyAlgorithmECDSASignatureMessageX962SHA256", "kSecAttrAccessibleWhenUnlocked",
        "kSecPropertyKeyType", "kSecPropertyKeyLabel", "kSecPropertyKeyValue", "kSecOIDX509V1SubjectName",
        "kSecCodeInfoIdentifier", "kSecCodeInfoUnique", "kSecCodeInfoFlags", "kSecCodeInfoFormat",
        "kSecCodeInfoTeamIdentifier", "kSecCodeInfoEntitlementsDict", "kSecCodeInfoPList",
        "kSecGuestAttributePid", "kSecTrustResultValue", "kSecImportExportPassphrase",
    };
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        CFStringRef *p = dlsym(RTLD_DEFAULT, names[i]);
        printf("%s = %s\n", names[i], p ? [(__bridge NSString *)*p UTF8String] : "(missing)");
    }
    printf("kSecRandomDefault %s\n", kSecRandomDefault == NULL ? "NULL" : "set");
}

static void
random_bytes(void)
{
    printf("== random\n");
    uint8_t a[32] = {0}, b[32] = {0}, zero[32] = {0};
    int s1 = SecRandomCopyBytes(kSecRandomDefault, sizeof a, a);
    int s2 = SecRandomCopyBytes(kSecRandomDefault, sizeof b, b);
    printf("status %d %d nonzero %d differ %d\n", s1, s2, memcmp(a, zero, 32) != 0, memcmp(a, b, 32) != 0);
    printf("zero length %d\n", SecRandomCopyBytes(kSecRandomDefault, 0, a));
}

static void
error_strings(void)
{
    printf("== error strings\n");
    OSStatus codes[] = { errSecSuccess, errSecItemNotFound, errSecDuplicateItem, errSecParam, errSecAllocate,
                         errSecUserCanceled, errSecAuthFailed, errSecNoSuchKeychain, errSecInteractionNotAllowed,
                         errSecCSUnsigned, errSecCSReqFailed, errSecCSReqInvalid, errAuthorizationDenied,
                         errAuthorizationInteractionNotAllowed, errSecNotTrusted, errSecCertificateExpired,
                         errSecUnimplemented, errSecDecode, -909090 };
    for (size_t i = 0; i < sizeof codes / sizeof *codes; i++) {
        CFStringRef s = SecCopyErrorMessageString(codes[i], NULL);
        printf("%d: %s\n", (int)codes[i], s ? [(__bridge NSString *)s UTF8String] : "(null)");
        if (s)
            CFRelease(s);
    }
}

static SecCertificateRef root, leaf;

static void
print_cert(const char *label, SecCertificateRef c)
{
    CFStringRef cn = NULL, summary;
    OSStatus st = SecCertificateCopyCommonName(c, &cn);
    summary = SecCertificateCopySubjectSummary(c);
    CFArrayRef emails = NULL;
    OSStatus es = SecCertificateCopyEmailAddresses(c, &emails);
    CFErrorRef err = NULL;
    CFDataRef serial = SecCertificateCopySerialNumberData(c, &err);
    NSData *data = CFBridgingRelease(SecCertificateCopyData(c));
    printf("%s: data %lu %s cn %d '%s' summary '%s' emails %d %s serial %s\n", label, (unsigned long)data.length,
           sha(data).UTF8String, (int)st, cn ? [(__bridge NSString *)cn UTF8String] : "-",
           summary ? [(__bridge NSString *)summary UTF8String] : "-", (int)es,
           emails ? [[(__bridge NSArray *)emails componentsJoinedByString:@","] UTF8String] : "-",
           serial ? hex((__bridge NSData *)serial).UTF8String : "-");
    CFDateRef nb = SecCertificateCopyNotValidBeforeDate(c), na = SecCertificateCopyNotValidAfterDate(c);
    printf("%s: valid %.0f .. %.0f\n", label, nb ? CFDateGetAbsoluteTime(nb) : 0, na ? CFDateGetAbsoluteTime(na) : 0);
    SecKeyRef key = SecCertificateCopyKey(c);
    NSDictionary *ka = key ? CFBridgingRelease(SecKeyCopyAttributes(key)) : nil;
    printf("%s: key type %s class %s bits %s block %zu\n", label, [ka[(id)kSecAttrKeyType] description].UTF8String,
           [ka[(id)kSecAttrKeyClass] description].UTF8String, [ka[(id)kSecAttrKeySizeInBits] description].UTF8String,
           key ? SecKeyGetBlockSize(key) : 0);
    SecKeyRef legacy = NULL;
    OSStatus ls = SecCertificateCopyPublicKey(c, &legacy);
    printf("%s: legacy public key %d %d\n", label, (int)ls, legacy != NULL);
    NSDictionary *values = CFBridgingRelease(SecCertificateCopyValues(c, NULL, NULL));
    for (id oid in @[ (id)kSecOIDX509V1SubjectName, (id)kSecOIDX509V1IssuerName, (id)kSecOIDX509V1SerialNumber,
                      (id)kSecOIDX509V1ValidityNotBefore, (id)kSecOIDX509V1ValidityNotAfter,
                      (id)kSecOIDX509V1SignatureAlgorithm, (id)kSecOIDSubjectAltName, (id)kSecOIDBasicConstraints,
                      (id)kSecOIDX509V1Version ]) {
        NSDictionary *v = values[oid];
        printf("%s: value %s %s\n", label, [oid UTF8String],
               v ? [[NSString stringWithFormat:@"type %@ value %@", v[(id)kSecPropertyKeyType],
                                               typeName(v[(id)kSecPropertyKeyValue])] UTF8String]
                 : "absent");
    }
    NSDictionary *one = CFBridgingRelease(SecCertificateCopyValues(c, (__bridge CFArrayRef) @[ (id)kSecOIDX509V1SubjectName ], NULL));
    printf("%s: values filtered %lu\n", label, (unsigned long)one.count);
    NSArray *subj = one[(id)kSecOIDX509V1SubjectName][(id)kSecPropertyKeyValue];
    for (NSDictionary *e in subj)
        printf("%s:   %s = %s\n", label, [e[(id)kSecPropertyKeyLabel] UTF8String], [[e[(id)kSecPropertyKeyValue] description] UTF8String]);
    if (cn) CFRelease(cn);
    if (summary) CFRelease(summary);
    if (emails) CFRelease(emails);
    if (serial) CFRelease(serial);
    if (nb) CFRelease(nb);
    if (na) CFRelease(na);
    if (key) CFRelease(key);
    if (legacy) CFRelease(legacy);
}

static void
certificates(void)
{
    printf("== certificates\n");
    root = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:kRootCert length:sizeof kRootCert]);
    leaf = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:kLeafCert length:sizeof kLeafCert]);
    printf("created %d %d type %d\n", root != NULL, leaf != NULL, CFGetTypeID(root) == SecCertificateGetTypeID());
    print_cert("root", root);
    print_cert("leaf", leaf);
    uint8_t junk[] = { 0x30, 0x03, 0x02, 0x01, 0x05 };
    SecCertificateRef bad = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:junk length:sizeof junk]);
    printf("junk %d\n", bad != NULL);
    SecCertificateRef again = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:kRootCert length:sizeof kRootCert]);
    printf("equal %d hash-equal %d different %d\n", CFEqual(root, again), CFHash(root) == CFHash(again), CFEqual(root, leaf));
    CSSM_DATA legacyData = {0};
    CSSM_CERT_TYPE legacyType = 0;
    const CSSM_X509_NAME *subject = NULL, *issuer = NULL;
    const CSSM_X509_ALGORITHM_IDENTIFIER *algorithm = NULL;
    OSStatus dataStatus = SecCertificateGetData(root, &legacyData);
    OSStatus typeStatus = SecCertificateGetType(root, &legacyType);
    OSStatus subjectStatus = SecCertificateGetSubject(root, &subject);
    OSStatus issuerStatus = SecCertificateGetIssuer(root, &issuer);
    OSStatus algorithmStatus = SecCertificateGetAlgorithmID(root, &algorithm);
    SecCertificateRef legacy = NULL;
    OSStatus createStatus = SecCertificateCreateFromData(&legacyData, legacyType, CSSM_CERT_ENCODING_DER, &legacy);
    CFDataRef issuerContent = SecCertificateCopyNormalizedIssuerContent(root, NULL);
    CFDataRef subjectContent = SecCertificateCopyNormalizedSubjectContent(root, NULL);
    printf("legacy cert data %d %lu type %d %d name %d %u %d %u algorithm %d %lu %lu roundtrip %d\n",
           dataStatus, (unsigned long)legacyData.Length, typeStatus, legacyType,
           subjectStatus, subject ? subject->numberOfRDNs : 0,
           issuerStatus, issuer ? issuer->numberOfRDNs : 0,
           algorithmStatus,
           (unsigned long)(algorithm ? algorithm->algorithm.Length : 0),
           (unsigned long)(algorithm ? algorithm->parameters.Length : 0),
           createStatus == errSecSuccess && legacy && CFEqual(root, legacy));
    printf("normalized content %ld %ld\n",
           (long)(issuerContent ? CFDataGetLength(issuerContent) : -1),
           (long)(subjectContent ? CFDataGetLength(subjectContent) : -1));
    if (legacy) CFRelease(legacy);
    if (issuerContent) CFRelease(issuerContent);
    if (subjectContent) CFRelease(subjectContent);
    CFRelease(again);
}

static void
policies(void)
{
    printf("== policies\n");
    SecPolicyRef basic = SecPolicyCreateBasicX509();
    SecPolicyRef ssl = SecPolicyCreateSSL(true, CFSTR("test.finch.example"));
    NSDictionary *bp = CFBridgingRelease(SecPolicyCopyProperties(basic));
    NSDictionary *sp = CFBridgingRelease(SecPolicyCopyProperties(ssl));
    printf("basic %s oid %s\n", keys(bp).UTF8String, [bp[(id)kSecPolicyOid] UTF8String]);
    printf("ssl %s oid %s name %s client %s\n", keys(sp).UTF8String, [sp[(id)kSecPolicyOid] UTF8String],
           [sp[(id)kSecPolicyName] UTF8String], [[sp[(id)kSecPolicyClient] description] UTF8String]);
    SecPolicyRef cs = SecPolicyCreateWithOID(kSecPolicyAppleCodeSigning);
    printf("codesigning %d", cs != NULL);
    if (cs) {
        NSDictionary *p = CFBridgingRelease(SecPolicyCopyProperties(cs));
        printf(" oid %s", [p[(id)kSecPolicyOid] UTF8String]);
        CFRelease(cs);
    }
    printf("\n");
    SecPolicyRef wp = SecPolicyCreateWithProperties(kSecPolicyAppleSSL, (__bridge CFDictionaryRef) @{ (id)kSecPolicyName : @"www.finch.example", (id)kSecPolicyClient : @NO });
    NSDictionary *wpp = CFBridgingRelease(SecPolicyCopyProperties(wp));
    printf("with properties %s name %s\n", keys(wpp).UTF8String, [wpp[(id)kSecPolicyName] UTF8String]);
    SecPolicyRef x = SecPolicyCreateWithProperties(kSecPolicyAppleX509Basic, NULL);
    printf("x509 with properties %d type %d\n", x != NULL, CFGetTypeID(basic) == SecPolicyGetTypeID());
    SecPolicyRef rev = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod);
    printf("revocation %d\n", rev != NULL);
    CSSM_OID policyOID = {0};
    CSSM_DATA policyValue = {0};
    OSStatus oidStatus = SecPolicyGetOID(basic, &policyOID);
    OSStatus valueStatus = SecPolicyGetValue(basic, &policyValue);
    printf("legacy policy oid %d %lu value %d %lu\n", oidStatus,
           (unsigned long)policyOID.Length, valueStatus, (unsigned long)policyValue.Length);
    CSSM_OID searchOID = CSSMOID_APPLE_X509_BASIC;
    SecPolicySearchRef search = NULL;
    SecPolicyRef found = NULL;
    OSStatus searchStatus = SecPolicySearchCreate(CSSM_CERT_X_509v3, &searchOID, NULL, &search);
    OSStatus nextStatus = searchStatus == errSecSuccess ? SecPolicySearchCopyNext(search, &found) : searchStatus;
    printf("policy search %d next %d found %d\n", searchStatus, nextStatus, found != NULL);
    CSSM_TP_HANDLE policyHandle = 0;
    printf("policy TP handle %d\n", (int)SecPolicyGetTPHandle(basic, &policyHandle));
    if (found) CFRelease(found);
    if (search) CFRelease(search);
    CSSM_DATA replacementValue = {3, (uint8_t *)"xyz"};
    OSStatus setValueStatus = SecPolicySetValue(basic, &replacementValue);
    policyValue = (CSSM_DATA){0};
    OSStatus readValueStatus = SecPolicyGetValue(basic, &policyValue);
    printf("policy value roundtrip %d %d %lu %d\n", setValueStatus, readValueStatus,
           (unsigned long)policyValue.Length,
           policyValue.Length == 3 && memcmp(policyValue.Data, "xyz", 3) == 0);
    CFRelease(basic);
    CFRelease(ssl);
    CFRelease(wp);
    if (x) CFRelease(x);
    if (rev) CFRelease(rev);
}

static CFDateRef
date(int y, int m, int d)
{
    NSDateComponents *c = [NSDateComponents new];
    c.year = y; c.month = m; c.day = d;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return (CFDateRef)CFBridgingRetain([cal dateFromComponents:c]);
}

static void
print_trust_properties(const char *label, SecTrustRef t)
{
    NSArray *properties = CFBridgingRelease(SecTrustCopyProperties(t));
    printf("%s: properties %lu", label, (unsigned long)properties.count);
    for (NSDictionary *item in properties) {
        NSString *title = item[(id)kSecPropertyTypeTitle];
        NSString *errorText = item[(id)kSecPropertyTypeError];
        printf(" [%s|%s]", title.UTF8String ?: "-", errorText.UTF8String ?: "-");
    }
    printf("\n");
}

static void
evaluate(const char *label, SecTrustRef t)
{
    CFErrorRef err = NULL;
    bool ok = SecTrustEvaluateWithError(t, &err);
    SecTrustResultType r = 0;
    OSStatus st = SecTrustGetTrustResult(t, &r);
    NSArray *chain = CFBridgingRelease(SecTrustCopyCertificateChain(t));
    printf("%s: ok %d error %ld %s result %d (%d) count %ld chain %lu\n", label, ok, errcode(err), domain(err).UTF8String,
           (int)r, (int)st, (long)SecTrustGetCertificateCount(t), (unsigned long)chain.count);
    for (id c in chain) {
        CFStringRef s = SecCertificateCopySubjectSummary((__bridge SecCertificateRef)c);
        printf("%s:   %s\n", label, [(__bridge NSString *)s UTF8String]);
        CFRelease(s);
    }
    print_trust_properties(label, t);
    if (err)
        CFRelease(err);
}

static void
trust(void)
{
    printf("== trust\n");
    SecPolicyRef ssl = SecPolicyCreateSSL(true, CFSTR("test.finch.example"));
    SecTrustRef t = NULL;
    NSArray *certs = @[ (__bridge id)leaf, (__bridge id)root ];
    OSStatus st = SecTrustCreateWithCertificates((__bridge CFArrayRef)certs, ssl, &t);
    printf("create %d type %d\n", (int)st, CFGetTypeID(t) == SecTrustGetTypeID());
    printf("set keychains %d\n", (int)SecTrustSetKeychains(t, NULL));
    print_trust_properties("not evaluated", t);
    CFDateRef when = date(2027, 1, 1);
    SecTrustSetVerifyDate(t, when);
    SecTrustSetNetworkFetchAllowed(t, false);
    evaluate("no anchor", t);
    SecTrustSetAnchorCertificates(t, (__bridge CFArrayRef) @[ (__bridge id)root ]);
    evaluate("anchored", t);
    OSStatus cssmCode = -1;
    CSSM_TP_VERIFY_CONTEXT_RESULT_PTR cssmResult = (CSSM_TP_VERIFY_CONTEXT_RESULT_PTR)1;
    CSSM_TP_HANDLE trustHandle = 0;
    OSStatus cssmCodeStatus = SecTrustGetCssmResultCode(t, &cssmCode);
    OSStatus cssmResultStatus = SecTrustGetCssmResult(t, &cssmResult);
    OSStatus trustHandleStatus = SecTrustGetTPHandle(t, &trustHandle);
    printf("legacy trust info code %d/%d result %d/%d handle %d\n",
        (int)cssmCodeStatus, (int)cssmCode, (int)cssmResultStatus,
        cssmResult == NULL, (int)trustHandleStatus);
    SecKeyRef k = SecTrustCopyKey(t);
    printf("trust key %d\n", k != NULL);
    if (k) CFRelease(k);
    NSArray *anchors = nil;
    CFArrayRef a = NULL;
    printf("copy anchors %d", (int)SecTrustCopyCustomAnchorCertificates(t, &a));
    anchors = CFBridgingRelease(a);
    printf(" count %lu\n", (unsigned long)anchors.count);

    CFDateRef late = date(2030, 6, 1);
    SecTrustSetVerifyDate(t, late);
    evaluate("expired", t);
    CFRelease(late);
    SecTrustSetVerifyDate(t, when);

    SecPolicyRef other = SecPolicyCreateSSL(true, CFSTR("other.finch.example"));
    SecTrustSetPolicies(t, other);
    evaluate("wrong host", t);
    SecPolicyRef basic = SecPolicyCreateBasicX509();
    SecTrustSetPolicies(t, basic);
    evaluate("basic", t);
    CFArrayRef pols = NULL;
    SecTrustCopyPolicies(t, &pols);
    printf("policies %ld\n", pols ? (long)CFArrayGetCount(pols) : -1);
    if (pols) CFRelease(pols);

    CFErrorRef err = NULL;
    CFDataRef ser = SecTrustSerialize(t, &err);
    printf("serialize %d\n", ser != NULL);
    if (ser) {
        SecTrustRef back = SecTrustDeserialize(ser, &err);
        printf("deserialize %d count %ld\n", back != NULL, back ? (long)SecTrustGetCertificateCount(back) : -1);
        if (back) CFRelease(back);
        CFRelease(ser);
    }
    SecTrustRef self = NULL;
    SecTrustCreateWithCertificates(root, basic, &self);
    SecTrustSetVerifyDate(self, when);
    evaluate("self-signed", self);
    Boolean fetchAllowed = true;
    OSStatus fetchStatus = SecTrustGetNetworkFetchAllowed(self, &fetchAllowed);
    printf("trust network fetch %d/%d\n", (int)fetchStatus, fetchAllowed);
    SecTrustResultType legacyResult = kSecTrustResultInvalid;
    CFArrayRef legacyChain = NULL;
    OSStatus legacyStatus = SecTrustGetResult(self, &legacyResult, &legacyChain, NULL);
    printf("legacy trust result %d/%d chain %ld\n", (int)legacyStatus, (int)legacyResult,
        legacyChain ? (long)CFArrayGetCount(legacyChain) : -1);
    if (legacyChain) CFRelease(legacyChain);
    printf("trust options %d\n", (int)SecTrustSetOptions(self, 0));
    OSStatus implicitAnchorStatus = SecTrustSetOptions(self, kSecTrustOptionImplicitAnchors);
    printf("trust implicit anchors %d\n", (int)implicitAnchorStatus);
    evaluate("implicit anchors", self);
    dispatch_queue_t trustQueue = dispatch_queue_create("finch.security.trust-test", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t trustDone = dispatch_semaphore_create(0);
    __block SecTrustResultType asyncTrustResult = kSecTrustResultInvalid;
    OSStatus asyncTrustStatus = SecTrustEvaluateAsync(self, trustQueue, ^(SecTrustRef evaluated, SecTrustResultType result) {
        (void)evaluated;
        asyncTrustResult = result;
        dispatch_semaphore_signal(trustDone);
    });
    if (!asyncTrustStatus)
        dispatch_semaphore_wait(trustDone, DISPATCH_TIME_FOREVER);
    printf("async trust %d/%d\n", (int)asyncTrustStatus, (int)asyncTrustResult);
    CFRelease(self);
    SecTrustRef only = NULL;
    SecTrustCreateWithCertificates(leaf, basic, &only);
    SecTrustSetVerifyDate(only, when);
    evaluate("leaf only", only);
    CFDataRef exceptions = SecTrustCopyExceptions(only);
    bool exceptionsSet = SecTrustSetExceptions(only, exceptions);
    SecTrustResultType exceptionResult = kSecTrustResultInvalid;
    OSStatus exceptionEvaluate = SecTrustEvaluate(only, &exceptionResult);
    printf("trust exceptions %d/%d/%d\n", exceptions != NULL, exceptionsSet,
        (int)exceptionEvaluate);
    if (exceptions) CFRelease(exceptions);
    CFRelease(only);
    CFRelease(other);
    CFRelease(basic);
    CFRelease(when);
    CFRelease(t);
    CFRelease(ssl);
}

static void
code_resource(const char *path)
{
    NSString *bundlePath = [NSString stringWithUTF8String:path];
    NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath];
    NSString *resourcePath = [bundlePath stringByAppendingPathComponent:@"Contents/Resources/marker.txt"];
    NSData *data = [NSData dataWithContentsOfFile:resourcePath];
    SecStaticCodeRef code = NULL;
    OSStatus createStatus = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &code);
    OSStatus validStatus = code && data
        ? SecCodeValidateFileResource(code, CFSTR("Resources/marker.txt"), (__bridge CFDataRef)data, kSecCSDefaultFlags)
        : errSecCSObjectRequired;
    NSMutableData *changed = [data mutableCopy];
    if (changed.length)
        ((uint8_t *)changed.mutableBytes)[0] ^= 0xff;
    OSStatus changedStatus = code && changed
        ? SecCodeValidateFileResource(code, CFSTR("Resources/marker.txt"), (__bridge CFDataRef)changed, kSecCSDefaultFlags)
        : errSecCSObjectRequired;
    OSStatus missingStatus = code && data
        ? SecCodeValidateFileResource(code, CFSTR("Resources/missing.txt"), (__bridge CFDataRef)data, kSecCSDefaultFlags)
        : errSecCSObjectRequired;
    OSStatus symlinkStatus = code && data
        ? SecCodeValidateFileResource(code, CFSTR("Resources/link.txt"), (__bridge CFDataRef)data, kSecCSDefaultFlags)
        : errSecCSObjectRequired;
    printf("code resource create %d valid %d changed %d missing %d symlink %d\n", (int)createStatus, (int)validStatus,
           (int)changedStatus, (int)missingStatus, (int)symlinkStatus);
    if (code)
        CFRelease(code);
}

static void
algorithms(SecKeyRef key, const char *label)
{
    SecKeyAlgorithm algs[] = { kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                               kSecKeyAlgorithmRSASignatureMessagePSSSHA256, kSecKeyAlgorithmRSAEncryptionOAEPSHA1,
                               kSecKeyAlgorithmRSAEncryptionPKCS1, kSecKeyAlgorithmRSAEncryptionRaw,
                               kSecKeyAlgorithmECDSASignatureMessageX962SHA256, kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                               kSecKeyAlgorithmECDHKeyExchangeStandard };
    SecKeyOperationType ops[] = { kSecKeyOperationTypeSign, kSecKeyOperationTypeVerify, kSecKeyOperationTypeEncrypt,
                                  kSecKeyOperationTypeDecrypt, kSecKeyOperationTypeKeyExchange };
    printf("%s supports:", label);
    for (size_t i = 0; i < sizeof algs / sizeof *algs; i++) {
        printf(" ");
        for (size_t j = 0; j < sizeof ops / sizeof *ops; j++)
            printf("%d", SecKeyIsAlgorithmSupported(key, ops[j], algs[i]));
    }
    printf("\n");
}

static void
key_attrs(const char *label, SecKeyRef key)
{
    NSDictionary *a = CFBridgingRelease(SecKeyCopyAttributes(key));
    // (Apple's EC block size depends on how the key was made: not compared.)
    bool rsa = [a[(id)kSecAttrKeyType] isEqual:(id)kSecAttrKeyTypeRSA];
    printf("%s: type %s class %s bits %s esiz %s block %zu", label, [a[(id)kSecAttrKeyType] description].UTF8String,
           [a[(id)kSecAttrKeyClass] description].UTF8String, [a[(id)kSecAttrKeySizeInBits] description].UTF8String,
           [a[(id)kSecAttrEffectiveKeySize] description].UTF8String, rsa ? SecKeyGetBlockSize(key) : 0);
    for (id k in @[ (id)kSecAttrCanEncrypt, (id)kSecAttrCanDecrypt, (id)kSecAttrCanSign, (id)kSecAttrCanVerify,
                    (id)kSecAttrCanDerive, (id)kSecAttrIsPermanent, (id)kSecAttrApplicationLabel ])
        printf(" %s=%s", [k UTF8String], typeName(a[k]).UTF8String);
    printf("\n");
}

static void
keys_test(void)
{
    printf("== keys\n");
    CFErrorRef err = NULL;
    NSDictionary *privAttrs = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPrivate };
    SecKeyRef priv = SecKeyCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:kRootKeyPKCS1 length:sizeof kRootKeyPKCS1],
                                          (__bridge CFDictionaryRef)privAttrs, &err);
    printf("rsa private %d err %ld type %d\n", priv != NULL, errcode(err), CFGetTypeID(priv) == SecKeyGetTypeID());
    key_attrs("rsa private", priv);
    SecKeyRef pub = SecKeyCopyPublicKey(priv);
    key_attrs("rsa public", pub);
    SecKeyRef certKey = SecCertificateCopyKey(root);
    NSData *pubData = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, NULL));
    NSData *certPubData = CFBridgingRelease(SecKeyCopyExternalRepresentation(certKey, NULL));
    NSData *privData = CFBridgingRelease(SecKeyCopyExternalRepresentation(priv, NULL));
    printf("rsa external pub %lu %s matches cert %d priv %lu same %d equal %d\n", (unsigned long)pubData.length, sha(pubData).UTF8String,
           [pubData isEqual:certPubData], (unsigned long)privData.length,
           [privData isEqual:[NSData dataWithBytes:kRootKeyPKCS1 length:sizeof kRootKeyPKCS1]], CFEqual(pub, certKey));
    algorithms(priv, "rsa private");
    algorithms(pub, "rsa public");

    NSData *msg = [@"Finch signs this message." dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sig = CFBridgingRelease(SecKeyCreateSignature(priv, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg, &err));
    printf("pkcs1 sign %lu %s\n", (unsigned long)sig.length, sha(sig).UTF8String);
    printf("pkcs1 verify %d\n", SecKeyVerifySignature(pub, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, NULL));
    err = NULL;
    NSData *msg2 = [@"Finch signs that message." dataUsingEncoding:NSUTF8StringEncoding];
    bool bad = SecKeyVerifySignature(pub, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg2, (__bridge CFDataRef)sig, &err);
    printf("pkcs1 verify other %d err %ld %s\n", bad, errcode(err), domain(err).UTF8String);
    if (err) { CFRelease(err); err = NULL; }
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(msg.bytes, (CC_LONG)msg.length, digest);
    NSData *dg = [NSData dataWithBytes:digest length:sizeof digest];
    NSData *sig1 = CFBridgingRelease(SecKeyCreateSignature(priv, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, (__bridge CFDataRef)dg, NULL));
    printf("pkcs1 sha1 digest sign %lu %s verify %d\n", (unsigned long)sig1.length, sha(sig1).UTF8String,
           SecKeyVerifySignature(certKey, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, (__bridge CFDataRef)dg, (__bridge CFDataRef)sig1, NULL));
    NSData *shortDigest = [NSData dataWithBytes:digest length:10];
    NSData *sigBad = CFBridgingRelease(SecKeyCreateSignature(priv, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, (__bridge CFDataRef)shortDigest, &err));
    printf("short digest %d err %ld\n", sigBad != nil, errcode(err));
    if (err) { CFRelease(err); err = NULL; }
    NSData *pss = CFBridgingRelease(SecKeyCreateSignature(priv, kSecKeyAlgorithmRSASignatureMessagePSSSHA256, (__bridge CFDataRef)msg, NULL));
    printf("pss %lu verify %d\n", (unsigned long)pss.length,
           SecKeyVerifySignature(pub, kSecKeyAlgorithmRSASignatureMessagePSSSHA256, (__bridge CFDataRef)msg, (__bridge CFDataRef)pss, NULL));
    NSData *noSig = CFBridgingRelease(SecKeyCreateSignature(pub, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg, &err));
    printf("sign with public %d err %ld\n", noSig != nil, errcode(err));
    if (err) { CFRelease(err); err = NULL; }
    for (id alg in @[ (id)kSecKeyAlgorithmRSAEncryptionOAEPSHA1, (id)kSecKeyAlgorithmRSAEncryptionOAEPSHA256, (id)kSecKeyAlgorithmRSAEncryptionPKCS1 ]) {
        NSData *ct = CFBridgingRelease(SecKeyCreateEncryptedData(pub, (__bridge SecKeyAlgorithm)alg, (__bridge CFDataRef)msg, &err));
        NSData *pt = CFBridgingRelease(SecKeyCreateDecryptedData(priv, (__bridge SecKeyAlgorithm)alg, (__bridge CFDataRef)ct, &err));
        printf("%s: ct %lu round trip %d\n", [alg UTF8String], (unsigned long)ct.length, [pt isEqual:msg]);
    }
    NSData *big = [NSMutableData dataWithLength:300];
    NSData *ctBig = CFBridgingRelease(SecKeyCreateEncryptedData(pub, kSecKeyAlgorithmRSAEncryptionOAEPSHA1, (__bridge CFDataRef)big, &err));
    printf("oaep too long %d err %ld\n", ctBig != nil, errcode(err));
    if (err) { CFRelease(err); err = NULL; }

    NSDictionary *pubAttrs = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic };
    SecKeyRef pub2 = SecKeyCreateWithData((__bridge CFDataRef)pubData, (__bridge CFDictionaryRef)pubAttrs, &err);
    printf("rsa public from data %d equal %d\n", pub2 != NULL, pub2 && CFEqual(pub2, pub));
    SecKeyRef junk = SecKeyCreateWithData((__bridge CFDataRef)[@"junk" dataUsingEncoding:NSUTF8StringEncoding], (__bridge CFDictionaryRef)pubAttrs, &err);
    printf("rsa junk %d err %ld %s\n", junk != NULL, errcode(err), domain(err).UTF8String);
    if (err) { CFRelease(err); err = NULL; }
    SecKeyRef notype = SecKeyCreateWithData((__bridge CFDataRef)pubData, (__bridge CFDictionaryRef) @{}, &err);
    printf("no type %d err %ld\n", notype != NULL, errcode(err));
    if (err) { CFRelease(err); err = NULL; }

    // EC
    NSDictionary *ecAttrs = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPrivate };
    SecKeyRef ec = SecKeyCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:kLeafKeyX963 length:sizeof kLeafKeyX963],
                                        (__bridge CFDictionaryRef)ecAttrs, &err);
    printf("ec private %d err %ld\n", ec != NULL, errcode(err));
    key_attrs("ec private", ec);
    SecKeyRef ecpub = SecKeyCopyPublicKey(ec);
    key_attrs("ec public", ecpub);
    SecKeyRef leafKey = SecCertificateCopyKey(leaf);
    NSData *ecPubData = CFBridgingRelease(SecKeyCopyExternalRepresentation(ecpub, NULL));
    NSData *ecPrivData = CFBridgingRelease(SecKeyCopyExternalRepresentation(ec, NULL));
    printf("ec external pub %lu %s matches cert %d priv %lu same %d\n", (unsigned long)ecPubData.length, sha(ecPubData).UTF8String,
           CFEqual(ecpub, leafKey), (unsigned long)ecPrivData.length,
           [ecPrivData isEqual:[NSData dataWithBytes:kLeafKeyX963 length:sizeof kLeafKeyX963]]);
    algorithms(ec, "ec private");
    NSData *ecsig = CFBridgingRelease(SecKeyCreateSignature(ec, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)msg, &err));
    printf("ecdsa sign %d verify %d other %d\n", ecsig.length > 64,
           SecKeyVerifySignature(leafKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)msg, (__bridge CFDataRef)ecsig, NULL),
           SecKeyVerifySignature(leafKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)msg2, (__bridge CFDataRef)ecsig, NULL));

    NSDictionary *gen = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeySizeInBits : @256 };
    SecKeyRef g1 = SecKeyCreateRandomKey((__bridge CFDictionaryRef)gen, &err);
    SecKeyRef g2 = SecKeyCreateRandomKey((__bridge CFDictionaryRef)gen, &err);
    key_attrs("ec random", g1);
    SecKeyRef g1p = SecKeyCopyPublicKey(g1), g2p = SecKeyCopyPublicKey(g2);
    NSData *s1 = CFBridgingRelease(SecKeyCopyKeyExchangeResult(g1, kSecKeyAlgorithmECDHKeyExchangeStandard, g2p, (__bridge CFDictionaryRef) @{}, &err));
    NSData *s2 = CFBridgingRelease(SecKeyCopyKeyExchangeResult(g2, kSecKeyAlgorithmECDHKeyExchangeStandard, g1p, (__bridge CFDictionaryRef) @{}, &err));
    printf("ecdh %lu equal %d\n", (unsigned long)s1.length, [s1 isEqual:s2]);
    NSDictionary *rsagen = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeySizeInBits : @2048 };
    SecKeyRef r1 = SecKeyCreateRandomKey((__bridge CFDictionaryRef)rsagen, &err);
    key_attrs("rsa random", r1);
    SecKeyRef badgen = SecKeyCreateRandomKey((__bridge CFDictionaryRef) @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeySizeInBits : @200 }, &err);
    printf("ec 200 bits %d err %ld\n", badgen != NULL, errcode(err));
    if (err) { CFRelease(err); err = NULL; }

    SecKeyRef legacyPub = NULL, legacyPriv = NULL;
    OSStatus gs = SecKeyGeneratePair((__bridge CFDictionaryRef) @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeySizeInBits : @256 }, &legacyPub, &legacyPriv);
    printf("generate pair %d %d %d\n", (int)gs, legacyPub != NULL, legacyPriv != NULL);

    CFRelease(priv); CFRelease(pub); CFRelease(certKey); CFRelease(pub2); CFRelease(ec); CFRelease(ecpub);
    CFRelease(leafKey); CFRelease(g1); CFRelease(g2); CFRelease(g1p); CFRelease(g2p); CFRelease(r1);
    if (legacyPub) CFRelease(legacyPub);
    if (legacyPriv) CFRelease(legacyPriv);
}

static void
legacy_symmetric_keys(void)
{
    printf("== symmetric keys\n");
    CFErrorRef error = NULL;
    UInt8 rawBytes[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    CFDataRef raw = CFDataCreate(NULL, rawBytes, sizeof(rawBytes));
    CFDictionaryRef parameters = (__bridge CFDictionaryRef)@{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeAES,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassSymmetric,
        (id)kSecAttrKeySizeInBits : @128
    };
    SecKeyRef imported = SecKeyCreateFromData(parameters, raw, &error);
    NSData *external = CFBridgingRelease(SecKeyCopyExternalRepresentation(imported, &error));
    printf("import AES %d raw %d size %zu err %ld\n", imported != NULL,
        [external isEqual:(__bridge NSData *)raw], imported ? SecKeyGetBlockSize(imported) : 0,
        (long)(error ? CFErrorGetCode(error) : 0));
    if (error) { CFRelease(error); error = NULL; }

    SecKeyRef generated = SecKeyGenerateSymmetric(parameters, &error);
    NSDictionary *attributes = generated ? CFBridgingRelease(SecKeyCopyAttributes(generated)) : nil;
    NSData *generatedBytes = generated ? CFBridgingRelease(SecKeyCopyExternalRepresentation(generated, &error)) : nil;
    printf("generate AES %d type %s class %s bits %s bytes %lu\n", generated != NULL,
        [attributes[(id)kSecAttrKeyType] description].UTF8String,
        [attributes[(id)kSecAttrKeyClass] description].UTF8String,
        [attributes[(id)kSecAttrKeySizeInBits] description].UTF8String,
        (unsigned long)generatedBytes.length);
    if (error) { CFRelease(error); error = NULL; }

    CFDataRef salt = CFDataCreate(NULL, (const UInt8 *)"finch-salt", 10);
    CFDictionaryRef deriveParameters = (__bridge CFDictionaryRef)@{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeAES,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassSymmetric,
        (id)kSecAttrKeySizeInBits : @128,
        (id)kSecAttrSalt : (__bridge NSData *)salt,
        (id)kSecAttrRounds : @1000,
        (id)kSecAttrPRF : (id)kSecAttrPRFHmacAlgSHA256
    };
    SecKeyRef derived = SecKeyDeriveFromPassword(CFSTR("friend"), deriveParameters, &error);
    NSData *derivedBytes = derived ? CFBridgingRelease(SecKeyCopyExternalRepresentation(derived, &error)) : nil;
    printf("derive AES %d bytes %lu hash %s err %ld\n", derived != NULL,
        (unsigned long)derivedBytes.length, sha(derivedBytes).UTF8String,
        (long)(error ? CFErrorGetCode(error) : 0));
    if (error) { CFRelease(error); error = NULL; }

    CFDataRef wrapped = SecKeyWrapSymmetric(imported, generated, (__bridge CFDictionaryRef)@{}, &error);
    printf("wrap AES %d err %ld\n", wrapped != NULL, (long)(error ? CFErrorGetCode(error) : 0));
    if (wrapped) CFRelease(wrapped);
    if (error) { CFRelease(error); error = NULL; }
    CFDataRef wrappedInput = raw;
    SecKeyRef unwrapped = SecKeyUnwrapSymmetric(&wrappedInput, generated, (__bridge CFDictionaryRef)@{}, &error);
    printf("unwrap AES %d err %ld\n", unwrapped != NULL, (long)(error ? CFErrorGetCode(error) : 0));
    if (unwrapped) CFRelease(unwrapped);
    if (error) CFRelease(error);

    int bits = 128;
    CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    CFDictionaryRef oldParameters = CFDictionaryCreate(NULL,
        (const void *[]){kSecAttrKeyType, kSecAttrKeySizeInBits},
        (const void *[]){kSecAttrKeyTypeAES, size}, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecKeyRef oldKey = NULL;
    OSStatus oldStatus = SecKeyGenerate(NULL, CSSM_ALGID_AES, 128, 0, CSSM_KEYUSE_ANY,
        CSSM_KEYATTR_RETURN_DEFAULT, NULL, &oldKey);
    printf("legacy AES generate %d key %d\n", (int)oldStatus, oldKey != NULL);
    if (oldKey) CFRelease(oldKey);
    if (oldParameters) CFRelease(oldParameters);
    if (size) CFRelease(size);

    NSDictionary *pairParameters = @{ (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA,
        (id)kSecAttrKeySizeInBits : @1024 };
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block int callbackResult = -1, callbackError = -1;
    SecKeyGeneratePairAsync((__bridge CFDictionaryRef)pairParameters,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(SecKeyRef publicKey, SecKeyRef privateKey, CFErrorRef pairError) {
            callbackResult = publicKey && privateKey;
            callbackError = pairError ? (int)CFErrorGetCode(pairError) : 0;
            dispatch_semaphore_signal(semaphore);
        });
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
    long wait = dispatch_semaphore_wait(semaphore, deadline);
    printf("async pair wait %ld result %d err %d\n", wait, callbackResult, callbackError);

    if (derived) CFRelease(derived);
    if (salt) CFRelease(salt);
    if (generated) CFRelease(generated);
    if (imported) CFRelease(imported);
    CFRelease(raw);
}

static void
keychain(void)
{
    printf("== keychain\n");
    NSString *path = [NSString stringWithFormat:@"%@/finch-security-test-%d.keychain", NSTemporaryDirectory(), getpid()];
    SecKeychainRef kc = NULL;
    OSStatus st = SecKeychainCreate(path.fileSystemRepresentation, 6, "finchy", false, NULL, &kc);
    printf("create %d type %d\n", (int)st, kc && CFGetTypeID(kc) == SecKeychainGetTypeID());
    UInt32 plen = 1024;
    char pbuf[1024];
    printf("get path %d same %d\n", (int)SecKeychainGetPath(kc, &plen, pbuf),
           [[NSString stringWithUTF8String:pbuf].stringByResolvingSymlinksInPath isEqual:path.stringByResolvingSymlinksInPath]);
    SecKeychainStatus kst = 0;
    printf("status %d %u\n", (int)SecKeychainGetStatus(kc, &kst), (unsigned)kst);

    NSData *secret = [@"hunter2" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *item = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                            (id)kSecAttrAccount : @"alice", (id)kSecAttrLabel : @"Finch test", (id)kSecValueData : secret,
                            (id)kSecAttrDescription : @"test item", (id)kSecUseKeychain : (__bridge id)kc };
    printf("add %d\n", (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL));
    printf("add again %d\n", (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL));
    NSMutableDictionary *bob = [item mutableCopy];
    bob[(id)kSecAttrAccount] = @"bob";
    bob[(id)kSecValueData] = [@"swordfish" dataUsingEncoding:NSUTF8StringEncoding];
    CFTypeRef added = NULL;
    bob[(id)kSecReturnAttributes] = @YES;
    printf("add bob %d", (int)SecItemAdd((__bridge CFDictionaryRef)bob, &added));
    printf(" returned %s\n", typeName((__bridge id)added).UTF8String);
    if (added) CFRelease(added);

    NSArray *list = @[ (__bridge id)kc ];
    NSDictionary *q = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                         (id)kSecAttrAccount : @"alice", (id)kSecMatchSearchList : list, (id)kSecReturnData : @YES };
    CFTypeRef out = NULL;
    st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    printf("find data %d %s %s\n", (int)st, typeName((__bridge id)out).UTF8String,
           [[[NSString alloc] initWithData:(__bridge NSData *)out encoding:NSUTF8StringEncoding] UTF8String]);
    if (out) { CFRelease(out); out = NULL; }

    NSMutableDictionary *qa = [q mutableCopy];
    [qa removeObjectForKey:(id)kSecReturnData];
    qa[(id)kSecReturnAttributes] = @YES;
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qa, &out);
    printf("find attributes %d %s\n", (int)st, typeName((__bridge id)out).UTF8String);
    NSDictionary *attrs = (__bridge NSDictionary *)out;
    for (NSString *k in @[ @"acct", @"svce", @"labl", @"desc", @"class", @"cdat", @"mdat" ])
        printf("  %s: %s\n", k.UTF8String, typeName(attrs[k]).UTF8String);
    printf("  account %s label %s\n", [attrs[@"acct"] UTF8String], [attrs[@"labl"] UTF8String]);
    if (out) { CFRelease(out); out = NULL; }

    qa[(id)kSecReturnData] = @YES;
    qa[(id)kSecReturnRef] = @YES;
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qa, &out);
    NSDictionary *both = (__bridge NSDictionary *)out;
    printf("find data+attrs+ref %d %s v_Data %s v_Ref %s\n", (int)st, typeName(both).UTF8String,
           typeName(both[(id)kSecValueData]).UTF8String, typeName(both[(id)kSecValueRef]).UTF8String);
    if (out) { CFRelease(out); out = NULL; }

    NSDictionary *qr = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                          (id)kSecAttrAccount : @"alice", (id)kSecMatchSearchList : list, (id)kSecReturnRef : @YES };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qr, &out);
    printf("find ref %d %s\n", (int)st, typeName((__bridge id)out).UTF8String);
    SecKeychainItemRef ref = (SecKeychainItemRef)out;
    out = NULL;

    NSDictionary *qp = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                          (id)kSecAttrAccount : @"alice", (id)kSecMatchSearchList : list, (id)kSecReturnPersistentRef : @YES };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qp, &out);
    printf("find persistent ref %d %s\n", (int)st, typeName((__bridge id)out).UTF8String);
    if (out) {
        CFTypeRef viaRef = NULL;
        NSDictionary *qv = @{ (id)kSecValuePersistentRef : (__bridge id)out, (id)kSecReturnData : @YES };
        OSStatus s2 = SecItemCopyMatching((__bridge CFDictionaryRef)qv, &viaRef);
        printf("by persistent ref %d %s\n", (int)s2, [[[NSString alloc] initWithData:(__bridge NSData *)viaRef encoding:NSUTF8StringEncoding] UTF8String]);
        if (viaRef) CFRelease(viaRef);
        CFRelease(out);
        out = NULL;
    }

    NSDictionary *qall = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                            (id)kSecMatchSearchList : list, (id)kSecMatchLimit : (id)kSecMatchLimitAll,
                            (id)kSecReturnAttributes : @YES };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qall, &out);
    NSArray *all = (__bridge NSArray *)out;
    NSMutableArray *accts = [NSMutableArray array];
    for (NSDictionary *d in all)
        [accts addObject:d[@"acct"]];
    [accts sortUsingSelector:@selector(compare:)];
    printf("find all %d %s %lu %s\n", (int)st, typeName(all).UTF8String, (unsigned long)all.count, [accts componentsJoinedByString:@","].UTF8String);
    if (out) { CFRelease(out); out = NULL; }

    NSDictionary *qallData = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                                (id)kSecMatchSearchList : list, (id)kSecMatchLimit : (id)kSecMatchLimitAll,
                                (id)kSecReturnData : @YES };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qallData, &out);
    printf("find all data %d %s\n", (int)st, typeName((__bridge id)out).UTF8String);
    if (out) { CFRelease(out); out = NULL; }

    NSDictionary *qsync = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                             (id)kSecAttrSynchronizable : (id)kSecAttrSynchronizableAny, (id)kSecMatchSearchList : list,
                             (id)kSecMatchLimit : (id)kSecMatchLimitAll };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qsync, &out);
    printf("find sync any %d %s\n", (int)st, typeName((__bridge id)out).UTF8String);
    if (out) { CFRelease(out); out = NULL; }

    NSDictionary *upq = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test",
                           (id)kSecAttrAccount : @"alice", (id)kSecMatchSearchList : list };
    st = SecItemUpdate((__bridge CFDictionaryRef)upq, (__bridge CFDictionaryRef) @{ (id)kSecValueData : [@"correct horse" dataUsingEncoding:NSUTF8StringEncoding], (id)kSecAttrLabel : @"Renamed" });
    printf("update %d\n", (int)st);
    st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    printf("after update %d %s\n", (int)st, [[[NSString alloc] initWithData:(__bridge NSData *)out encoding:NSUTF8StringEncoding] UTF8String]);
    if (out) { CFRelease(out); out = NULL; }
    NSDictionary *upnone = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.none", (id)kSecMatchSearchList : list };
    printf("update missing %d\n", (int)SecItemUpdate((__bridge CFDictionaryRef)upnone, (__bridge CFDictionaryRef) @{ (id)kSecAttrLabel : @"x" }));

    // Internet passwords.
    NSDictionary *inet = @{ (id)kSecClass : (id)kSecClassInternetPassword, (id)kSecAttrServer : @"www.finch.example",
                            (id)kSecAttrProtocol : (id)kSecAttrProtocolHTTPS, (id)kSecAttrAccount : @"carol",
                            (id)kSecValueData : secret, (id)kSecUseKeychain : (__bridge id)kc };
    printf("add inet %d\n", (int)SecItemAdd((__bridge CFDictionaryRef)inet, NULL));
    NSDictionary *qi = @{ (id)kSecClass : (id)kSecClassInternetPassword, (id)kSecAttrServer : @"www.finch.example",
                          (id)kSecMatchSearchList : list, (id)kSecReturnAttributes : @YES };
    st = SecItemCopyMatching((__bridge CFDictionaryRef)qi, &out);
    NSDictionary *ia = (__bridge NSDictionary *)out;
    printf("find inet %d acct %s srvr %s ptcl %s\n", (int)st, [ia[@"acct"] UTF8String], [ia[@"srvr"] UTF8String], [[ia[@"ptcl"] description] UTF8String]);
    if (out) { CFRelease(out); out = NULL; }

    // The legacy SecKeychain calls.
    printf("legacy add %d\n", (int)SecKeychainAddGenericPassword(kc, 9, "org.legacy", 4, "dave", 6, "s3cret", NULL));
    UInt32 len = 0;
    void *data = NULL;
    SecKeychainItemRef litem = NULL;
    st = SecKeychainFindGenericPassword(kc, 9, "org.legacy", 4, "dave", &len, &data, &litem);
    printf("legacy find %d %.*s item %d\n", (int)st, (int)len, data ? (char *)data : "", litem != NULL);
    if (data) SecKeychainItemFreeContent(NULL, data);
    if (litem) {
        SecItemClass cls = 0;
        UInt32 tags[] = { kSecAccountItemAttr, kSecServiceItemAttr, kSecLabelItemAttr };
        UInt32 fmts[] = { CSSM_DB_ATTRIBUTE_FORMAT_STRING, CSSM_DB_ATTRIBUTE_FORMAT_STRING, CSSM_DB_ATTRIBUTE_FORMAT_STRING };
        SecKeychainAttributeInfo info = { 3, tags, fmts };
        SecKeychainAttributeList *alist = NULL;
        st = SecKeychainItemCopyAttributesAndData(litem, &info, &cls, &alist, &len, &data);
        printf("legacy attributes %d class %.4s", (int)st, (char *)&(UInt32){ OSSwapHostToBigInt32(cls) });
        for (UInt32 i = 0; alist && i < alist->count; i++)
            printf(" %.4s=%.*s", (char *)&(UInt32){ OSSwapHostToBigInt32(alist->attr[i].tag) }, (int)alist->attr[i].length,
                   alist->attr[i].data ? (char *)alist->attr[i].data : "");
        printf(" data %.*s\n", (int)len, data ? (char *)data : "");
        SecKeychainItemFreeAttributesAndData(alist, data);
        data = NULL;
        SecKeychainAttribute la = { kSecLabelItemAttr, 5, "Lbl!!" };
        SecKeychainAttributeList ll = { 1, &la };
        printf("legacy modify %d\n", (int)SecKeychainItemModifyContent(litem, &ll, 7, "newpass"));
        st = SecKeychainItemCopyContent(litem, NULL, NULL, &len, &data);
        printf("legacy copy content %d %.*s\n", (int)st, (int)len, data ? (char *)data : "");
        if (data) SecKeychainItemFreeContent(NULL, data);
        data = NULL;
        SecKeychainRef owner = NULL;
        printf("legacy item keychain %d same %d\n", (int)SecKeychainItemCopyKeychain(litem, &owner), owner && CFEqual(owner, kc));
        if (owner) CFRelease(owner);
        printf("legacy delete %d\n", (int)SecKeychainItemDelete(litem));
        CFRelease(litem);
        litem = NULL;
    }
    st = SecKeychainFindGenericPassword(kc, 9, "org.legacy", 4, "dave", &len, &data, &litem);
    printf("legacy find deleted %d\n", (int)st);
    SecKeychainAttribute attrs2[] = { { kSecServiceItemAttr, 9, "org.legac2" }, { kSecAccountItemAttr, 3, "eve" } };
    SecKeychainAttributeList al2 = { 2, attrs2 };
    st = SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass, &al2, 4, "pw!!", kc, NULL, &litem);
    printf("legacy create from content %d %d\n", (int)st, litem != NULL);
    if (litem) {
        printf("legacy delete created %d\n", (int)SecKeychainItemDelete(litem));
        CFRelease(litem);
    }

    if (ref) {
        printf("delete via ref type %d %d\n", CFGetTypeID(ref) == SecKeychainItemGetTypeID(), (int)SecKeychainItemDelete(ref));
        CFRelease(ref);
    }
    printf("delete bob %d\n", (int)SecItemDelete((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test", (id)kSecMatchSearchList : list }));
    printf("delete again %d\n", (int)SecItemDelete((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test", (id)kSecMatchSearchList : list }));
    st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    printf("find deleted %d\n", (int)st);
    printf("delete inet %d\n", (int)SecItemDelete((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassInternetPassword, (id)kSecMatchSearchList : list }));
    printf("no class %d\n", (int)SecItemCopyMatching((__bridge CFDictionaryRef) @{ (id)kSecAttrService : @"x", (id)kSecMatchSearchList : list }, &out));
    printf("add no class %d\n", (int)SecItemAdd((__bridge CFDictionaryRef) @{ (id)kSecAttrService : @"x", (id)kSecUseKeychain : (__bridge id)kc }, NULL));

    Boolean allowed = 9;
    printf("interaction get %d %d", (int)SecKeychainGetUserInteractionAllowed(&allowed), allowed);
    printf(" set %d", (int)SecKeychainSetUserInteractionAllowed(false));
    SecKeychainGetUserInteractionAllowed(&allowed);
    printf(" now %d", allowed);
    SecKeychainSetUserInteractionAllowed(true);
    SecKeychainGetUserInteractionAllowed(&allowed);
    printf(" restored %d\n", allowed);

    printf("delete keychain %d\n", (int)SecKeychainDelete(kc));
    CFRelease(kc);
    printf("file gone %d\n", ![[NSFileManager defaultManager] fileExistsAtPath:path]);

    // The default keychain, read-only: nothing by this name exists.
    NSDictionary *qd = @{ (id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"org.finch.test.does-not-exist",
                          (id)kSecReturnData : @YES };
    printf("default keychain missing %d\n", (int)SecItemCopyMatching((__bridge CFDictionaryRef)qd, NULL));
    UInt32 dlen = 0;
    void *ddata = NULL;
    printf("legacy default missing %d\n", (int)SecKeychainFindGenericPassword(NULL, 29, "org.finch.test.does-not-exist", 0, NULL, &dlen, &ddata, NULL));
}

static void
codesigning(void)
{
    printf("== code signing\n");
    SecCodeRef me = NULL;
    OSStatus st = SecCodeCopySelf(kSecCSDefaultFlags, &me);
    printf("copy self %d type %d\n", (int)st, me && CFGetTypeID(me) == SecCodeGetTypeID());
    printf("check self %d\n", (int)SecCodeCheckValidity(me, kSecCSDefaultFlags, NULL));
    SecStaticCodeRef staticMe = NULL;
    st = SecCodeCopyStaticCode(me, kSecCSDefaultFlags, &staticMe);
    printf("static of self %d type %d\n", (int)st, staticMe && CFGetTypeID(staticMe) == SecStaticCodeGetTypeID());
    CFURLRef url = NULL;
    st = SecCodeCopyPath(staticMe, kSecCSDefaultFlags, &url);
    printf("path %d %s\n", (int)st, [[(__bridge NSURL *)url lastPathComponent] UTF8String]);

    CFDictionaryRef info = NULL;
    st = SecCodeCopySigningInformation(staticMe, kSecCSSigningInformation | kSecCSRequirementInformation, &info);
    NSDictionary *d = (__bridge NSDictionary *)info;
    printf("signing info %d identifier %s format %s unique %s team %s flags-adhoc %d\n", (int)st,
           [d[(id)kSecCodeInfoIdentifier] UTF8String], [d[(id)kSecCodeInfoFormat] UTF8String],
           typeName(d[(id)kSecCodeInfoUnique]).UTF8String, [d[(id)kSecCodeInfoTeamIdentifier] UTF8String] ?: "-",
           ([d[(id)kSecCodeInfoFlags] unsignedIntValue] & kSecCodeSignatureAdhoc) != 0);
    printf("  digest algorithm %s cdhashes %s main %s source %s\n", [[d[(id)kSecCodeInfoDigestAlgorithm] description] UTF8String],
           typeName(d[(id)kSecCodeInfoCdHashes]).UTF8String, typeName(d[(id)kSecCodeInfoMainExecutable]).UTF8String,
           [d[(id)kSecCodeInfoSource] UTF8String]);
    printf("  certificates %s\n", typeName(d[(id)kSecCodeInfoCertificates]).UTF8String);
    NSData *uniq = d[(id)kSecCodeInfoUnique];
    printf("  unique length %lu\n", (unsigned long)uniq.length);
    if (info) CFRelease(info);

    char exe[4096];
    uint32_t sz = sizeof exe;
    _NSGetExecutablePath(exe, &sz);
    NSURL *exeURL = [NSURL fileURLWithPath:@(exe)];
    SecStaticCodeRef byPath = NULL;
    st = SecStaticCodeCreateWithPath((__bridge CFURLRef)exeURL, kSecCSDefaultFlags, &byPath);
    printf("static by path %d\n", (int)st);
    printf("check static %d\n", (int)SecStaticCodeCheckValidity(byPath, kSecCSDefaultFlags, NULL));
    printf("check static strict %d\n", (int)SecStaticCodeCheckValidity(byPath, kSecCSStrictValidate | kSecCSCheckAllArchitectures, NULL));
    printf("same static %d\n", CFEqual(byPath, staticMe));

    const char *reqs[] = {
        "anchor apple",
        "anchor apple generic",
        "identifier \"org.finch.test.security\"",
        "identifier org.finch.test.security",
        "identifier \"org.finch.other\"",
        "identifier \"org.finch.test.security\" and anchor apple generic",
        "identifier \"org.finch.test.security\" or anchor apple",
        "!anchor apple",
        "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"",
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
        "cdhash H\"0123456789abcdef0123456789abcdef01234567\"",
        "info[CFBundleIdentifier] = \"org.finch\"",
        "entitlement[\"com.apple.security.app-sandbox\"] exists",
        "anchor trusted",
        "(identifier \"a\" or identifier \"b\") and anchor apple",
        "identifier \"x\" and",
        "nonsense here",
        "certificate root = H\"0123456789abcdef0123456789abcdef01234567\"",
        "identifier com.apple.* ",
        "always",
        "never",
    };
    for (size_t i = 0; i < sizeof reqs / sizeof *reqs; i++) {
        SecRequirementRef r = NULL;
        CFErrorRef err = NULL;
        st = SecRequirementCreateWithStringAndErrors((__bridge CFStringRef) @(reqs[i]), kSecCSDefaultFlags, &err, &r);
        printf("req '%s': %d", reqs[i], (int)st);
        if (r) {
            CFDataRef data = NULL;
            CFStringRef text = NULL;
            SecRequirementCopyData(r, kSecCSDefaultFlags, &data);
            SecRequirementCopyString(r, kSecCSDefaultFlags, &text);
            OSStatus cv = SecStaticCodeCheckValidity(byPath, kSecCSDefaultFlags, r);
            OSStatus cs = SecCodeCheckValidity(me, kSecCSDefaultFlags, r);
            printf(" data %s text '%s' check %d %d", hex((__bridge NSData *)data).UTF8String, [(__bridge NSString *)text UTF8String], (int)cv, (int)cs);
            SecRequirementRef r2 = NULL;
            OSStatus rs = SecRequirementCreateWithData(data, kSecCSDefaultFlags, &r2);
            printf(" from data %d equal %d", (int)rs, r2 && CFEqual(r, r2));
            if (r2) CFRelease(r2);
            if (data) CFRelease(data);
            if (text) CFRelease(text);
            CFRelease(r);
        }
        if (err) {
            printf(" error %ld", errcode(err));
            CFRelease(err);
        }
        printf("\n");
    }
    SecRequirementRef badData = NULL;
    uint8_t junk[] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    printf("req from junk %d\n", (int)SecRequirementCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:junk length:sizeof junk], kSecCSDefaultFlags, &badData));
    SecRequirementRef designated = NULL;
    st = SecCodeCopyDesignatedRequirement(byPath, kSecCSDefaultFlags, &designated);
    CFStringRef dtext = NULL;
    if (designated)
        SecRequirementCopyString(designated, kSecCSDefaultFlags, &dtext);
    printf("designated %d %s check %d\n", (int)st, [(__bridge NSString *)dtext UTF8String],
           designated ? (int)SecStaticCodeCheckValidity(byPath, kSecCSDefaultFlags, designated) : 0);
    if (dtext) CFRelease(dtext);
    if (designated) CFRelease(designated);

    printf("map memory %d\n", (int)SecCodeMapMemory(byPath, kSecCSDefaultFlags));

    // A file that isn't code, and one that is code but unsigned.
    NSString *dir = NSTemporaryDirectory();
    NSString *txt = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-sec-%d.txt", getpid()]];
    [@"not code\n" writeToFile:txt atomically:NO encoding:NSUTF8StringEncoding error:nil];
    SecStaticCodeRef plain = NULL;
    st = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:txt], kSecCSDefaultFlags, &plain);
    printf("text file %d", (int)st);
    if (plain) {
        printf(" check %d", (int)SecStaticCodeCheckValidity(plain, kSecCSDefaultFlags, NULL));
        CFDictionaryRef pinfo = NULL;
        printf(" info %d", (int)SecCodeCopySigningInformation(plain, kSecCSDefaultFlags, &pinfo));
        printf(" keys %s", keys((__bridge NSDictionary *)pinfo).UTF8String);
        if (pinfo) CFRelease(pinfo);
        CFRelease(plain);
    }
    printf("\n");
    unlink(txt.fileSystemRepresentation);

    // Our own binary with its signature stripped.
    NSString *copy = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-sec-%d.bin", getpid()]];
    NSMutableData *bin = [NSMutableData dataWithContentsOfFile:@(exe)];
    // Corrupt one byte of __TEXT: the signature no longer matches.
    uint8_t *bytes = bin.mutableBytes;
    bytes[0x4000 + 17] ^= 0xff;
    [bin writeToFile:copy atomically:NO];
    SecStaticCodeRef broken = NULL;
    st = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:copy], kSecCSDefaultFlags, &broken);
    printf("modified %d check %d\n", (int)st, broken ? (int)SecStaticCodeCheckValidity(broken, kSecCSDefaultFlags, NULL) : 0);
    if (broken) CFRelease(broken);
    unlink(copy.fileSystemRepresentation);

    printf("missing path %d\n", (int)SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:@"/nonexistent/finch"], kSecCSDefaultFlags, &plain));

    SecCodeRef guest = NULL;
    st = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef) @{ (id)kSecGuestAttributePid : @(getpid()) }, kSecCSDefaultFlags, &guest);
    printf("guest by pid %d equal %d\n", (int)st, guest && CFEqual(guest, me));
    SecCodeRef host = NULL;
    st = SecCodeCopyHost(me, kSecCSDefaultFlags, &host);
    printf("host %d\n", (int)st);
    if (host) CFRelease(host);
    if (guest) CFRelease(guest);
    if (url) CFRelease(url);
    CFRelease(byPath);
    CFRelease(staticMe);
    CFRelease(me);
}

static void
task(void)
{
    printf("== task\n");
    SecTaskRef t = SecTaskCreateFromSelf(NULL);
    printf("self %d type %d\n", t != NULL, t && CFGetTypeID(t) == SecTaskGetTypeID());
    CFErrorRef err = NULL;
    CFStringRef ident = SecTaskCopySigningIdentifier(t, &err);
    printf("identifier %s\n", ident ? [(__bridge NSString *)ident UTF8String] : "-");
    CFTypeRef ent = SecTaskCopyValueForEntitlement(t, CFSTR("com.apple.security.app-sandbox"), &err);
    printf("entitlement %s err %ld\n", typeName((__bridge id)ent).UTF8String, errcode(err));
    NSDictionary *ents = CFBridgingRelease(SecTaskCopyValuesForEntitlements(t, (__bridge CFArrayRef) @[ @"com.apple.security.app-sandbox", @"x" ], &err));
    printf("entitlements %s %lu\n", typeName(ents).UTF8String, (unsigned long)ents.count);
    if (ident) CFRelease(ident);
    if (ent) CFRelease(ent);
    if (t) CFRelease(t);
}

static void
authorization(void)
{
    printf("== authorization\n");
    AuthorizationRef auth = NULL;
    OSStatus st = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &auth);
    printf("create %d %d\n", (int)st, auth != NULL);
    AuthorizationExternalForm ext;
    printf("external %d", (int)AuthorizationMakeExternalForm(auth, &ext));
    AuthorizationRef back = NULL;
    printf(" from external %d %d\n", (int)AuthorizationCreateFromExternalForm(&ext, &back), back != NULL);
    if (back) AuthorizationFree(back, kAuthorizationFlagDefaults);

    AuthorizationItem item = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    AuthorizationRights *granted = NULL;
    st = AuthorizationCopyRights(auth, &rights, NULL, kAuthorizationFlagExtendRights, &granted);
    // Without interaction an administrator right is denied to non-root callers, granted to root.
    printf("copy admin right, no interaction: %s\n", geteuid() == 0 ? (st == errAuthorizationSuccess ? "as expected" : "unexpected")
                                                                : (st == errAuthorizationInteractionNotAllowed ? "as expected" : "unexpected"));
    if (granted) AuthorizationFreeItemSet(granted);
    granted = NULL;
    AuthorizationItem none = { "org.finch.test.nonexistent-right", 0, NULL, 0 };
    AuthorizationRights nr = { 1, &none };
    st = AuthorizationCopyRights(auth, &nr, NULL, kAuthorizationFlagDefaults, &granted);
    printf("copy unknown right, no extend %d\n", (int)st);
    if (granted) AuthorizationFreeItemSet(granted);
    granted = NULL;
    st = AuthorizationCopyRights(auth, &nr, NULL, kAuthorizationFlagPreAuthorize, &granted);
    printf("copy rights preauthorize %d\n", (int)st);
    if (granted) AuthorizationFreeItemSet(granted);

    AuthorizationItemSet *infoSet = NULL;
    st = AuthorizationCopyInfo(auth, NULL, &infoSet);
    printf("copy info %d %u\n", (int)st, infoSet ? (unsigned)infoSet->count : 999);
    if (infoSet) AuthorizationFreeItemSet(infoSet);

    CFDictionaryRef rdef = NULL;
    st = AuthorizationRightGet("system.preferences", &rdef);
    NSDictionary *rd = (__bridge NSDictionary *)rdef;
    printf("right get %d class %s\n", (int)st, [rd[@"class"] UTF8String]);
    if (rdef) CFRelease(rdef);
    st = AuthorizationRightGet("org.finch.test.nonexistent-right", &rdef);
    printf("right get missing %d\n", (int)st);
    printf("free %d\n", (int)AuthorizationFree(auth, kAuthorizationFlagDefaults));
    printf("create null out %d\n", (int)AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, NULL));

    SecuritySessionId sid = 0;
    SessionAttributeBits bits = 0;
    st = SessionGetInfo(callerSecuritySession, &sid, &bits);
    printf("session %d\n", (int)st);
}

static void
access_objects(void)
{
    printf("== access\n");
    CFErrorRef err = NULL;
    SecAccessControlRef ac = SecAccessControlCreateWithFlags(NULL, kSecAttrAccessibleWhenUnlocked, kSecAccessControlUserPresence, &err);
    printf("access control %d type %d\n", ac != NULL, ac && CFGetTypeID(ac) == SecAccessControlGetTypeID());
    if (ac) CFRelease(ac);
    SecAccessControlRef bad = SecAccessControlCreateWithFlags(NULL, CFSTR("nonsense"), 0, &err);
    printf("access control bad %d err %ld\n", bad != NULL, errcode(err));
    SecAccessRef access = NULL;
    OSStatus st = SecAccessCreate(CFSTR("Finch test"), NULL, &access);
    printf("access %d type %d\n", (int)st, access && CFGetTypeID(access) == SecAccessGetTypeID());
    SecTrustedApplicationRef app = NULL;
    st = SecTrustedApplicationCreateFromPath(NULL, &app);
    printf("trusted app self %d\n", (int)st);
    SecTrustedApplicationRef group = NULL;
    st = SecTrustedApplicationCreateApplicationGroup("org.finch.group", NULL, &group);
    printf("trusted app group %d %d\n", (int)st, group != NULL);
    CFArrayRef acls = NULL;
    if (access) {
        st = SecAccessCopyACLList(access, &acls);
        printf("acl list %d %d\n", (int)st, acls != NULL);
    }
    SecACLRef acl = NULL;
    CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR selector = { CSSM_ACL_KEYCHAIN_PROMPT_CURRENT_VERSION,
        CSSM_ACL_KEYCHAIN_PROMPT_REQUIRE_PASSPHRASE | CSSM_ACL_KEYCHAIN_PROMPT_UNSIGNED };
    st = access ? SecACLCreateFromSimpleContents(access, NULL, CFSTR("test ACL"), &selector, &acl) : errSecParam;
    printf("legacy ACL create %d %d\n", (int)st, acl != NULL);
    if (acl) {
        CFArrayRef apps = NULL;
        CFStringRef description = NULL;
        CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR copied = {0};
        st = SecACLCopySimpleContents(acl, &apps, &description, &copied);
        printf("legacy ACL contents %d %ld %s prompt %u %u\n", (int)st,
            (long)(apps ? CFArrayGetCount(apps) : -1), description ? [(__bridge NSString *)description UTF8String] : "-",
            copied.version, copied.flags);
        if (apps) CFRelease(apps);
        if (description) CFRelease(description);
        CSSM_ACL_AUTHORIZATION_TAG auths[] = {CSSM_ACL_AUTHORIZATION_SIGN, CSSM_ACL_AUTHORIZATION_DB_READ};
        st = SecACLSetAuthorizations(acl, auths, 2);
        CSSM_ACL_AUTHORIZATION_TAG readback[2] = {0};
        uint32_t count = 2;
        OSStatus getStatus = SecACLGetAuthorizations(acl, readback, &count);
        printf("legacy ACL auth %d %d %u %d %d\n", (int)st, (int)getStatus, count,
            readback[0], readback[1]);
        CFArrayRef selected = NULL;
        st = SecAccessCopySelectedACLList(access, CSSM_ACL_AUTHORIZATION_SIGN, &selected);
        printf("selected ACLs %d %ld\n", (int)st, (long)(selected ? CFArrayGetCount(selected) : -1));
        if (selected) CFRelease(selected);
        CFArrayRef ownerACLs = CFArrayCreate(NULL, (const void **)&acl, 1, &kCFTypeArrayCallBacks);
        CFErrorRef ownerError = NULL;
        SecAccessRef owned = SecAccessCreateWithOwnerAndACL(501, 20, kSecUseOnlyUID | kSecHonorRoot, ownerACLs, &ownerError);
        uid_t uid = 0; gid_t gid = 0; SecAccessOwnerType ownerType = 0;
        CFArrayRef copiedACLs = NULL;
        OSStatus ownerStatus = owned ? SecAccessCopyOwnerAndACL(owned, &uid, &gid, &ownerType, &copiedACLs) : errSecParam;
        printf("owner ACL %d %d %u %u %u %ld\n", owned != NULL, (int)ownerStatus,
            (unsigned)uid, (unsigned)gid, (unsigned)ownerType, (long)(copiedACLs ? CFArrayGetCount(copiedACLs) : -1));
        if (copiedACLs) CFRelease(copiedACLs);
        if (owned) CFRelease(owned);
        if (ownerError) CFRelease(ownerError);
        CFRelease(ownerACLs);
        CFRelease(acl);
    }
    if (acls) CFRelease(acls);
    if (group) CFRelease(group);
    if (app) CFRelease(app);
    if (access) CFRelease(access);
}

static void
identities(void)
{
    printf("== identity\n");
    printf("identity type %d\n", SecIdentityGetTypeID() != 0 && SecIdentityGetTypeID() != SecCertificateGetTypeID());
    CFTypeRef out = NULL;
    NSString *path = [NSString stringWithFormat:@"%@/finch-security-id-%d.keychain", NSTemporaryDirectory(), getpid()];
    SecKeychainRef kc = NULL;
    SecKeychainCreate(path.fileSystemRepresentation, 6, "finchy", false, NULL, &kc);
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassIdentity, (id)kSecMatchSearchList : @[ (__bridge id)kc ], (id)kSecReturnRef : @YES }, &out);
    printf("find identity in empty keychain %d\n", (int)st);
    SecIdentitySearchRef emptySearch = NULL;
    OSStatus emptyCreate = SecIdentitySearchCreate(kc, 0, &emptySearch);
    SecIdentityRef emptyIdentity = NULL;
    OSStatus emptyNext = emptyCreate ? emptyCreate : SecIdentitySearchCopyNext(emptySearch, &emptyIdentity);
    printf("identity search empty %d type %d next %d\n", (int)emptyCreate,
        emptySearch && CFGetTypeID(emptySearch) == SecIdentitySearchGetTypeID(), (int)emptyNext);
    if (emptyIdentity) CFRelease(emptyIdentity);
    if (emptySearch) CFRelease(emptySearch);
    st = SecItemAdd((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassCertificate, (id)kSecValueRef : (__bridge id)root, (id)kSecUseKeychain : (__bridge id)kc }, NULL);
    printf("add certificate %d\n", (int)st);
    st = SecItemAdd((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassCertificate, (id)kSecValueRef : (__bridge id)root, (id)kSecUseKeychain : (__bridge id)kc }, NULL);
    printf("add certificate again %d\n", (int)st);
    st = SecItemCopyMatching((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassCertificate, (id)kSecMatchSearchList : @[ (__bridge id)kc ], (id)kSecReturnRef : @YES }, &out);
    printf("find certificate %d %s equal %d\n", (int)st, typeName((__bridge id)out).UTF8String, out && CFEqual(out, root));
    if (out) { CFRelease(out); out = NULL; }
    st = SecItemCopyMatching((__bridge CFDictionaryRef) @{ (id)kSecClass : (id)kSecClassCertificate, (id)kSecMatchSearchList : @[ (__bridge id)kc ], (id)kSecReturnAttributes : @YES }, &out);
    NSDictionary *ca = (__bridge NSDictionary *)out;
    printf("certificate attributes %d labl %s ctyp %s subj %s issr %s slnr %s pkhh %s\n", (int)st, [ca[@"labl"] UTF8String],
           [[ca[@"ctyp"] description] UTF8String], typeName(ca[@"subj"]).UTF8String, typeName(ca[@"issr"]).UTF8String,
           typeName(ca[@"slnr"]).UTF8String, typeName(ca[@"pkhh"]).UTF8String);
    if (out) { CFRelease(out); out = NULL; }
    SecIdentitySearchRef search = NULL;
    OSStatus searchStatus = SecIdentitySearchCreate(kc, CSSM_KEYUSE_SIGN, &search);
    SecIdentityRef found = NULL;
    OSStatus nextStatus = searchStatus ? searchStatus : SecIdentitySearchCopyNext(search, &found);
    printf("identity search after certificate %d type %d next %d found %d\n", (int)searchStatus,
        search && CFGetTypeID(search) == SecIdentitySearchGetTypeID(), (int)nextStatus, found != NULL);
    if (found) CFRelease(found);
    if (search) CFRelease(search);

    NSDictionary *keyAttributes = @{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPrivate,
    };
    SecKeyRef privateKey = SecKeyCreateWithData(
        (__bridge CFDataRef)[NSData dataWithBytes:kRootKeyPKCS1 length:sizeof kRootKeyPKCS1],
        (__bridge CFDictionaryRef)keyAttributes, NULL);
    SecIdentityRef testIdentity = privateKey ? SecIdentityCreate(NULL, root, privateKey) : NULL;
    CFArrayRef certificateList = CFArrayCreate(NULL, (const void *[]){root}, 1, &kCFTypeArrayCallBacks);
    sec_certificate_t wrappedCertificate = sec_certificate_create(root);
    SecCertificateRef copiedCertificate = wrappedCertificate ? sec_certificate_copy_ref(wrappedCertificate) : NULL;
    sec_identity_t wrappedIdentity = testIdentity ? sec_identity_create(testIdentity) : NULL;
    sec_identity_t wrappedIdentityWithCertificates = testIdentity
        ? sec_identity_create_with_certificates(testIdentity, certificateList) : NULL;
    SecIdentityRef copiedIdentity = wrappedIdentity ? sec_identity_copy_ref(wrappedIdentity) : NULL;
    CFArrayRef copiedCertificates = wrappedIdentityWithCertificates
        ? sec_identity_copy_certificates_ref(wrappedIdentityWithCertificates) : NULL;
    void *retainedCertificate = wrappedCertificate ? sec_retain((__bridge void *)wrappedCertificate) : NULL;
    __block int accessedCertificates = 0;
    bool accessStatus = wrappedIdentityWithCertificates && sec_identity_access_certificates(
        wrappedIdentityWithCertificates, ^(sec_certificate_t certificate) {
            (void)certificate;
            accessedCertificates++;
        });
    SecTrustRef testTrust = NULL;
    SecPolicyRef wrapperPolicy = SecPolicyCreateBasicX509();
    OSStatus trustStatus = SecTrustCreateWithCertificates((__bridge CFArrayRef)@[(__bridge id)root], wrapperPolicy, &testTrust);
    sec_trust_t wrappedTrust = !trustStatus && testTrust ? sec_trust_create(testTrust) : NULL;
    SecTrustRef copiedTrust = wrappedTrust ? sec_trust_copy_ref(wrappedTrust) : NULL;
    printf("protocol wrappers %d %d %ld %d %d %d %d %d\n",
        retainedCertificate == (__bridge void *)wrappedCertificate, copiedCertificate && CFEqual(copiedCertificate, root),
        (long)(copiedCertificates ? CFArrayGetCount(copiedCertificates) : -1),
        accessStatus, accessedCertificates,
        copiedIdentity != NULL,
        !trustStatus && copiedTrust != NULL,
        wrappedCertificate && wrappedIdentity && wrappedIdentityWithCertificates && wrappedTrust);
    if (copiedCertificate) CFRelease(copiedCertificate);
    if (retainedCertificate) sec_release(retainedCertificate);
    if (copiedCertificates) CFRelease(copiedCertificates);
    if (copiedIdentity) CFRelease(copiedIdentity);
    if (copiedTrust) CFRelease(copiedTrust);
    if (testTrust) CFRelease(testTrust);
    if (wrapperPolicy) CFRelease(wrapperPolicy);
    if (testIdentity) CFRelease(testIdentity);
    if (privateKey) CFRelease(privateKey);
    CFRelease(certificateList);
    SecKeychainDelete(kc);
    CFRelease(kc);
}

static void
cms(void)
{
    printf("== cms\n");
    NSDictionary *attributes = @{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPrivate,
    };
    SecKeyRef key = SecKeyCreateWithData(
        (__bridge CFDataRef)[NSData dataWithBytes:kRootKeyPKCS1 length:sizeof kRootKeyPKCS1],
        (__bridge CFDictionaryRef)attributes, NULL);
    SecIdentityRef identity = key ? SecIdentityCreate(NULL, root, key) : NULL;
    CMSEncoderRef encoder = NULL;
    OSStatus status = CMSEncoderCreate(&encoder);
    printf("encoder create %d type %d\n", (int)status,
           encoder && CFGetTypeID(encoder) == CMSEncoderGetTypeID());
    if (!status && identity)
        status = CMSEncoderAddSigners(encoder, identity);
    if (!status)
        status = CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256);
    if (!status)
        status = CMSEncoderSetCertificateChainMode(encoder, kCMSCertificateSignerOnly);
    if (!status)
        status = CMSEncoderSetEncapsulatedContentTypeOID(encoder, CFSTR("1.2.3.4"));
    if (!status)
        status = CMSEncoderAddSignedAttributes(encoder, kCMSAttrSigningTime);
    if (!status)
        status = CMSEncoderUpdateContent(encoder, "CMS ", 4);
    if (!status)
        status = CMSEncoderUpdateContent(encoder, "payload", 7);
    CFArrayRef signers = NULL;
    CFDataRef contentType = NULL, encoded = NULL;
    if (!status)
        status = CMSEncoderCopySigners(encoder, &signers);
    if (!status)
        status = CMSEncoderCopyEncapsulatedContentType(encoder, &contentType);
    if (!status)
        status = CMSEncoderCopyEncodedContent(encoder, &encoded);
    printf("encode %d signers %ld oid %ld data %d\n", (int)status,
           (long)(signers ? CFArrayGetCount(signers) : 0),
           (long)(contentType ? CFDataGetLength(contentType) : 0), encoded != NULL);

    CMSDecoderRef decoder = NULL;
    OSStatus decodeStatus = CMSDecoderCreate(&decoder);
    if (!decodeStatus && encoded)
        decodeStatus = CMSDecoderUpdateMessage(decoder, CFDataGetBytePtr(encoded),
            (size_t)CFDataGetLength(encoded) / 2);
    if (!decodeStatus && encoded) {
        CFIndex half = CFDataGetLength(encoded) / 2;
        decodeStatus = CMSDecoderUpdateMessage(decoder, CFDataGetBytePtr(encoded) + half,
            (size_t)(CFDataGetLength(encoded) - half));
    }
    if (!decodeStatus)
        decodeStatus = CMSDecoderFinalizeMessage(decoder);
    size_t signerCount = 0;
    if (!decodeStatus)
        decodeStatus = CMSDecoderGetNumSigners(decoder, &signerCount);
    CFDataRef decoded = NULL, decodedType = NULL;
    SecCertificateRef signerCertificate = NULL;
    Boolean encrypted = true;
    if (!decodeStatus)
        decodeStatus = CMSDecoderCopyContent(decoder, &decoded);
    if (!decodeStatus)
        decodeStatus = CMSDecoderCopyEncapsulatedContentType(decoder, &decodedType);
    if (!decodeStatus)
        decodeStatus = CMSDecoderIsContentEncrypted(decoder, &encrypted);
    OSStatus certStatus = decodeStatus ? decodeStatus : CMSDecoderCopySignerCert(decoder, 0, &signerCertificate);
    CMSSignerStatus signerStatus = kCMSSignerUnsigned;
    SecPolicyRef cmsPolicy = SecPolicyCreateBasicX509();
    OSStatus signatureStatus = decodeStatus ? decodeStatus : CMSDecoderCopySignerStatus(
        decoder, 0, cmsPolicy, false, &signerStatus, NULL, NULL);
    CFArrayRef certificates = NULL;
    OSStatus allCertsStatus = decodeStatus ? decodeStatus : CMSDecoderCopyAllCerts(decoder, &certificates);
    BOOL contentMatches = decoded && [(__bridge NSData *)decoded
        isEqualToData:[@"CMS payload" dataUsingEncoding:NSUTF8StringEncoding]];
    printf("decode %d signers %zu content %d encrypted %d oid %d signature %d/%d cert %d equal %d all %d/%ld\n",
           (int)decodeStatus, signerCount, contentMatches,
           encrypted, decodedType && contentType && CFEqual(decodedType, contentType),
           (int)signatureStatus, (int)signerStatus, (int)certStatus,
           signerCertificate && CFEqual(signerCertificate, root), (int)allCertsStatus,
           (long)(certificates ? CFArrayGetCount(certificates) : 0));
    if (certificates) CFRelease(certificates);
    if (cmsPolicy) CFRelease(cmsPolicy);
    if (signerCertificate) CFRelease(signerCertificate);
    if (decodedType) CFRelease(decodedType);
    if (decoded) CFRelease(decoded);
    if (decoder) CFRelease(decoder);
    if (encoded) CFRelease(encoded);
    if (contentType) CFRelease(contentType);
    if (signers) CFRelease(signers);
    if (encoder) CFRelease(encoder);
    if (identity) CFRelease(identity);
    if (key) CFRelease(key);
}

static void
transforms(void)
{
    printf("== transforms\n");
    CFErrorRef error = NULL;
    CFDataRef input = CFBridgingRetain([@"Finch transform" dataUsingEncoding:NSUTF8StringEncoding]);
    SecTransformRef digest = SecDigestTransformCreate(kSecDigestSHA2, 0, &error);
    Boolean set = digest && SecTransformSetAttribute(digest, kSecTransformInputAttributeName, input, &error);
    CFTypeRef digestResult = set ? SecTransformExecute(digest, &error) : NULL;
    CFDataRef attributeResult = digest ? (CFDataRef)SecTransformGetAttribute(digest, kSecTransformOutputAttributeName) : NULL;
    printf("digest %d type %d subclass %d set %u execute %d length %ld attribute %d error %ld\n",
        digest != NULL, digest && CFGetTypeID(digest) == SecTransformGetTypeID(),
        digest && CFGetTypeID(digest) == SecDigestTransformGetTypeID(), (unsigned)set,
        digestResult != NULL, (long)(digestResult ? CFDataGetLength(digestResult) : -1),
        attributeResult && digestResult && CFEqual(attributeResult, digestResult),
        (long)(error ? CFErrorGetCode(error) : 0));
    if (error) { CFRelease(error); error = NULL; }

    SecTransformRef encoder = SecEncodeTransformCreate(kSecBase64Encoding, &error);
    set = encoder && SecTransformSetAttribute(encoder, kSecTransformInputAttributeName, input, &error);
    CFTypeRef encoded = set ? SecTransformExecute(encoder, &error) : NULL;
    char encodedText[128] = "-";
    if (encoded && CFGetTypeID(encoded) == CFDataGetTypeID()) {
        CFDataRef bytes = (CFDataRef)encoded;
        size_t length = (size_t)CFDataGetLength(bytes);
        if (length >= sizeof(encodedText)) length = sizeof(encodedText) - 1;
        memcpy(encodedText, CFDataGetBytePtr(bytes), length);
        encodedText[length] = 0;
    }
    SecTransformRef decoder = SecDecodeTransformCreate(kSecBase64Encoding, &error);
    set = decoder && encoded && SecTransformSetAttribute(decoder, kSecTransformInputAttributeName, encoded, &error);
    CFTypeRef decoded = set ? SecTransformExecute(decoder, &error) : NULL;
    printf("base64 %d %s roundtrip %d error %ld\n", encoded != NULL, encodedText,
        decoded && CFEqual(decoded, input), (long)(error ? CFErrorGetCode(error) : 0));
    if (error) CFRelease(error);

    if (decoded) CFRelease(decoded);
    if (decoder) CFRelease(decoder);
    if (encoded) CFRelease(encoded);
    if (encoder) CFRelease(encoder);
    if (attributeResult) CFRetain(attributeResult);
    if (digestResult) CFRelease(digestResult);
    if (attributeResult) CFRelease(attributeResult);
    if (digest) CFRelease(digest);
    if (input) CFRelease(input);
}

static SecTransformInstanceBlock
customShiftTransform(CFStringRef name, SecTransformRef transform,
    SecTransformImplementationRef implementation)
{
    return ^{ return (CFErrorRef)NULL; };
}

static void
custom_transforms(void)
{
    CFStringRef name = CFSTR("org.finch.test.shift");
    CFErrorRef error = NULL;
    Boolean registered = SecTransformRegister(name, customShiftTransform, &error);
    SecTransformRef transform = registered ? SecTransformCreate(name, &error) : NULL;
    CFDataRef input = CFDataCreate(NULL, (const UInt8 *)"pass", 4);
    Boolean set = transform && input && SecTransformSetAttribute(transform,
        kSecTransformInputAttributeName, input, &error);
    printf("custom transform %u %u %u no-data %u error %ld\n",
        (unsigned)registered, transform != NULL, (unsigned)set, SecTransformNoData() != NULL,
        (long)(error ? CFErrorGetCode(error) : 0));
    if (input) CFRelease(input);
    if (transform) CFRelease(transform);
    if (error) CFRelease(error);
}

int
main(int argc, const char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info dl;
    dladdr((const void *)SecRandomCopyBytes, &dl);
    printf("finch-security-test: Security from %s\n", dl.dli_fname);
    @autoreleasepool {
        constants();
        random_bytes();
        error_strings();
        certificates();
        policies();
        trust();
        keys_test();
        legacy_symmetric_keys();
        keychain();
        identities();
        codesigning();
        task();
        authorization();
        access_objects();
        cms();
        transforms();
        custom_transforms();
        if (argc > 1)
            code_resource(argv[1]);
    }
    printf("== done\n");
    return 0;
}

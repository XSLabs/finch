/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch-only: system HTTPS roots, explicit anchors and excluded purposes. */
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "security-test-certs.inc"

CFDataRef SecTrustSerialize(SecTrustRef trust, CFErrorRef *error);
SecTrustRef SecTrustDeserialize(CFDataRef serializedTrust, CFErrorRef *error);

static void
check_round_trip(SecTrustRef trust, bool trusted)
{
    CFDataRef data = SecTrustSerialize(trust, NULL);
    assert(data);
    SecTrustRef copy = SecTrustDeserialize(data, NULL);
    assert(copy && SecTrustEvaluateWithError(copy, NULL) == trusted);
    CFRelease(copy);
    CFRelease(data);
}

static CFArrayRef
read_chain(const char *path)
{
    FILE *file = fopen(path, "rb");
    assert(file);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length > 0 && length < 4 * 1024 * 1024);
    rewind(file);
    char *text = calloc((size_t)length + 1, 1);
    assert(text && fread(text, 1, (size_t)length, file) == (size_t)length);
    fclose(file);
    CFMutableArrayRef chain = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    char *next = text;
    while ((next = strstr(next, "-----BEGIN CERTIFICATE-----"))) {
        char *begin = next + strlen("-----BEGIN CERTIFICATE-----");
        char *end = strstr(begin, "-----END CERTIFICATE-----");
        assert(end);
        UInt8 *der = malloc((size_t)(end - begin));
        assert(der);
        const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        unsigned bits = 0, count = 0;
        size_t size = 0;
        for (char *p = begin; p < end; p++) {
            const char *digit = strchr(alphabet, *p);
            if (!digit)
                continue;
            bits = (bits << 6) | (unsigned)(digit - alphabet);
            count += 6;
            if (count >= 8) {
                count -= 8;
                der[size++] = (UInt8)(bits >> count);
            }
        }
        CFDataRef data = CFDataCreate(NULL, der, (CFIndex)size);
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, data);
        assert(cert);
        CFArrayAppendValue(chain, cert);
        CFRelease(cert);
        CFRelease(data);
        free(der);
        next = end;
    }
    free(text);
    assert(CFArrayGetCount(chain) == 3);
    return chain;
}

int
main(int argc, char **argv)
{
    assert(argc == 2 || argc == 3);
    bool missing = argc == 3 && strcmp(argv[2], "missing") == 0;
    CFArrayRef builtin = read_chain(argv[1]);
    SecPolicyRef server = SecPolicyCreateSSL(true, CFSTR("curl.se"));
    SecTrustRef trust = NULL;
    assert(SecTrustCreateWithCertificates(builtin, server, &trust) == noErr);
    CFDateRef when = CFDateCreate(NULL, 813283200); /* 2026-10-10 UTC. */
    assert(SecTrustSetVerifyDate(trust, when) == noErr);
    CFErrorRef firstError = NULL;
    bool firstTrusted = SecTrustEvaluateWithError(trust, &firstError);
    if (firstTrusted != !missing)
        fprintf(stderr, "system root trust error: %ld\n", firstError ? (long)CFErrorGetCode(firstError) : 0L);
    if (firstError)
        CFRelease(firstError);
    assert(firstTrusted == !missing);
    check_round_trip(trust, !missing);
    assert(SecTrustSetAnchorCertificatesOnly(trust, true) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    check_round_trip(trust, false);
    assert(SecTrustSetAnchorCertificatesOnly(trust, false) == noErr);
    assert(SecTrustEvaluateWithError(trust, NULL) == !missing);
    CFArrayRef empty = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    assert(SecTrustSetAnchorCertificates(trust, empty) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    check_round_trip(trust, false);
    assert(SecTrustSetAnchorCertificatesOnly(trust, false) == noErr);
    assert(SecTrustEvaluateWithError(trust, NULL) == !missing);
    assert(SecTrustSetAnchorCertificates(trust, NULL) == noErr);
    assert(SecTrustEvaluateWithError(trust, NULL) == !missing);
    SecPolicyRef client = SecPolicyCreateSSL(false, NULL);
    assert(SecTrustSetPolicies(trust, client) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    SecPolicyRef basic = SecPolicyCreateBasicX509();
    assert(SecTrustSetPolicies(trust, basic) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    CFRelease(trust);
    CFDataRef rootData = CFDataCreate(NULL, kRootCert, sizeof(kRootCert));
    CFDataRef leafData = CFDataCreate(NULL, kLeafCert, sizeof(kLeafCert));
    SecCertificateRef root = SecCertificateCreateWithData(NULL, rootData);
    SecCertificateRef leaf = SecCertificateCreateWithData(NULL, leafData);
    assert(root && leaf);
    SecPolicyRef named = SecPolicyCreateSSL(true, CFSTR("test.finch.example"));
    assert(SecTrustCreateWithCertificates(leaf, named, &trust) == noErr);
    CFDateRef fixtureDate = CFDateCreate(NULL, 820454400);
    assert(SecTrustSetVerifyDate(trust, fixtureDate) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    const void *anchors[] = {root};
    CFArrayRef custom = CFArrayCreate(NULL, anchors, 1, &kCFTypeArrayCallBacks);
    assert(SecTrustSetAnchorCertificates(trust, custom) == noErr);
    assert(SecTrustEvaluateWithError(trust, NULL));
    assert(SecTrustSetAnchorCertificatesOnly(trust, false) == noErr);
    assert(SecTrustEvaluateWithError(trust, NULL));
    SecPolicyRef wrong = SecPolicyCreateSSL(true, CFSTR("wrong.example"));
    assert(SecTrustSetPolicies(trust, wrong) == noErr);
    assert(!SecTrustEvaluateWithError(trust, NULL));
    CFRelease(wrong);
    CFRelease(custom);
    CFRelease(fixtureDate);
    CFRelease(trust);
    CFRelease(named);
    CFRelease(leaf);
    CFRelease(root);
    CFRelease(leafData);
    CFRelease(rootData);
    CFRelease(basic);
    CFRelease(client);
    CFRelease(empty);
    CFRelease(when);
    CFRelease(server);
    CFRelease(builtin);
    puts(missing ? "security-roots: PASS (missing store stays untrusted; custom roots work)" :
        "security-roots: PASS (HTTPS roots, custom roots, excluded purposes, wrong host)");
    return 0;
}

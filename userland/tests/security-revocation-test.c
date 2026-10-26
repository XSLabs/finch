/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Revocation checks (Finch's Security, SecRevocation.c), against a local OCSP
 * responder and CRL server that tools/test-revocation.sh starts for the
 * test-only authority in userland/tests/revocation-fixture: one certificate
 * good, one revoked.
 *
 *   finch-security-revocation-test FIXTURE-DIR STAPLED-RESPONSE
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(const char *what, bool ok)
{
	printf("%s: %s\n", what, ok ? "pass" : "FAIL");
	if (!ok)
		failures++;
}

static CFDataRef readFile(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
	UInt8 buf[8192];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
		CFDataAppendBytes(data, buf, (CFIndex)n);
	fclose(f);
	return data;
}

/* A PEM certificate's DER. */
static SecCertificateRef pem(const char *dir, const char *name)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/%s.pem", dir, name);
	CFDataRef data = readFile(path);
	if (!data)
		return NULL;
	const char *text = (const char *)CFDataGetBytePtr(data);
	const char *begin = strstr(text, "-----BEGIN CERTIFICATE-----"), *end = strstr(text, "-----END CERTIFICATE-----");
	SecCertificateRef cert = NULL;
	if (begin && end) {
		CFMutableDataRef der = CFDataCreateMutable(NULL, 0);
		unsigned bits = 0;
		int count = 0;
		for (const char *p = begin + strlen("-----BEGIN CERTIFICATE-----"); p < end; p++) {
			const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
			const char *at = *p ? strchr(alphabet, *p) : NULL;
			if (!at)
				continue;
			bits = (bits << 6) | (unsigned)(at - alphabet);
			if ((count += 6) >= 8) {
				count -= 8;
				UInt8 byte = (UInt8)(bits >> count);
				CFDataAppendBytes(der, &byte, 1);
			}
		}
		cert = SecCertificateCreateWithData(NULL, der);
		CFRelease(der);
	}
	CFRelease(data);
	return cert;
}

struct options {
	CFOptionFlags flags;
	bool revocation, noNetwork;
	CFDataRef stapled;
};

static OSStatus evaluate(SecCertificateRef leaf, SecCertificateRef root, const char *host, struct options o,
    SecTrustResultType *result)
{
	CFStringRef name = CFStringCreateWithCString(NULL, host, kCFStringEncodingUTF8);
	SecPolicyRef policies[2] = { SecPolicyCreateSSL(true, name), SecPolicyCreateRevocation(o.flags) };
	CFArrayRef list = CFArrayCreate(NULL, (const void **)policies, o.revocation ? 2 : 1, &kCFTypeArrayCallBacks);
	SecTrustRef trust = NULL;
	SecTrustCreateWithCertificates(leaf, list, &trust);
	CFArrayRef anchors = CFArrayCreate(NULL, (const void **)&root, 1, &kCFTypeArrayCallBacks);
	SecTrustSetAnchorCertificates(trust, anchors);
	if (o.noNetwork)
		SecTrustSetNetworkFetchAllowed(trust, false);
	if (o.stapled)
		SecTrustSetOCSPResponse(trust, o.stapled);
	CFErrorRef error = NULL;
	OSStatus status = SecTrustEvaluateWithError(trust, &error) ? errSecSuccess :
	    error ? (OSStatus)CFErrorGetCode(error) : errSecInternalError;
	SecTrustGetTrustResult(trust, result);
	if (error)
		CFRelease(error);
	CFRelease(trust);
	CFRelease(anchors);
	CFRelease(list);
	CFRelease(policies[0]);
	CFRelease(policies[1]);
	CFRelease(name);
	return status;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: finch-security-revocation-test fixture-dir stapled-response\n");
		return 2;
	}
	SecCertificateRef root = pem(argv[1], "root"), good = pem(argv[1], "good"), revoked = pem(argv[1], "revoked");
	CFDataRef stapled = readFile(argv[2]);
	check("fixtures load", root && good && revoked && stapled);
	const char *goodHost = "good.revocation.finch.test", *revokedHost = "revoked.revocation.finch.test";
	SecTrustResultType result;

	struct options none = { 0 };
	check("without a revocation policy a revoked certificate isn't checked",
	    evaluate(revoked, root, revokedHost, none, &result) == errSecSuccess);

	struct options ocsp = { .flags = kSecRevocationOCSPMethod, .revocation = true };
	check("OCSP: a good certificate passes", evaluate(good, root, goodHost, ocsp, &result) == errSecSuccess);
	OSStatus s = evaluate(revoked, root, revokedHost, ocsp, &result);
	check("OCSP: a revoked one fails", s == errSecCertificateRevoked && result == kSecTrustResultFatalTrustFailure);

	struct options ocspStrict = { .flags = kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse,
	    .revocation = true };
	check("OCSP: the responder's answer is a positive one",
	    evaluate(good, root, goodHost, ocspStrict, &result) == errSecSuccess);
	struct options crlStrict = { .flags = kSecRevocationCRLMethod | kSecRevocationRequirePositiveResponse,
	    .revocation = true };
	check("CRL: so is the CRL's", evaluate(good, root, goodHost, crlStrict, &result) == errSecSuccess);
	struct options crl = { .flags = kSecRevocationCRLMethod, .revocation = true };
	check("CRL: a good certificate passes", evaluate(good, root, goodHost, crl, &result) == errSecSuccess);
	check("CRL: a revoked one fails", evaluate(revoked, root, revokedHost, crl, &result) == errSecCertificateRevoked);

	struct options any = { .flags = kSecRevocationUseAnyAvailableMethod | kSecRevocationPreferCRL,
	    .revocation = true };
	check("either method, CRL first: revoked", evaluate(revoked, root, revokedHost, any, &result) ==
	    errSecCertificateRevoked);

	struct options offline = { .flags = kSecRevocationOCSPMethod, .revocation = true, .noNetwork = true };
	check("no network and no answer: passes by default",
	    evaluate(revoked, root, revokedHost, offline, &result) == errSecSuccess);
	struct options strict = { .flags = kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse,
	    .revocation = true, .noNetwork = true };
	check("no answer when one is required: incomplete",
	    evaluate(good, root, goodHost, strict, &result) == errSecIncompleteCertRevocationCheck);
	struct options disabled = { .flags = kSecRevocationOCSPMethod | kSecRevocationNetworkAccessDisabled |
	    kSecRevocationRequirePositiveResponse, .revocation = true };
	check("the policy can forbid the network too",
	    evaluate(good, root, goodHost, disabled, &result) == errSecIncompleteCertRevocationCheck);

	struct options staple = { .flags = kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse,
	    .revocation = true, .noNetwork = true, .stapled = stapled };
	check("a stapled response answers without the network",
	    evaluate(revoked, root, revokedHost, staple, &result) == errSecCertificateRevoked);
	check("and isn't taken for another certificate",
	    evaluate(good, root, goodHost, staple, &result) == errSecIncompleteCertRevocationCheck);

	printf("failures: %d\n", failures);
	return failures != 0;
}

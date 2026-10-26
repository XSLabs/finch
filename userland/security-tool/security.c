/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * security: the trust-settings and certificate commands of macOS's security(1),
 * written for Finch over its Security framework:
 *
 *   security add-trusted-cert [-d] [-r trustRoot|trustAsRoot|deny|unspecified]
 *                             [-p ssl|smime|codeSign|basic] [-s hostname] file
 *   security remove-trusted-cert [-d] file
 *   security dump-trust-settings [-d | -s]
 *   security verify-cert -c file [-c file ...] [-r root] [-p ssl|smime|basic] [-s hostname]
 *
 * -d means the administrator's settings (root's to change), otherwise the
 * user's; -s, the system's (the pinned roots). Certificates are PEM or DER.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/SecTrustSettings.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int usage(void)
{
	fprintf(stderr,
	    "usage: security add-trusted-cert [-d] [-r resultType] [-p policy] [-s hostname] certFile\n"
	    "       security remove-trusted-cert [-d] certFile\n"
	    "       security dump-trust-settings [-d | -s]\n"
	    "       security verify-cert -c certFile [-c certFile ...] [-r rootFile] [-p policy] [-s hostname]\n");
	return 2;
}

static void report(const char *what, OSStatus status)
{
	CFStringRef message = SecCopyErrorMessageString(status, NULL);
	char text[256] = "";
	if (message) {
		CFStringGetCString(message, text, sizeof(text), kCFStringEncodingUTF8);
		CFRelease(message);
	}
	fprintf(stderr, "SecTrustSettings%s: %s (%d)\n", what, text[0] ? text : "error", (int)status);
}

static int base64Value(int c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1;
}

static CFDataRef pemCertificate(CFDataRef data)
{
	const char *begin = "-----BEGIN CERTIFICATE-----", *end = "-----END CERTIFICATE-----";
	const char *bytes = (const char *)CFDataGetBytePtr(data);
	size_t length = (size_t)CFDataGetLength(data);
	const char *start = memmem(bytes, length, begin, strlen(begin));
	if (!start)
		return NULL;
	start += strlen(begin);
	const char *stop = memmem(start, length - (size_t)(start - bytes), end, strlen(end));
	if (!stop)
		return NULL;
	CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
	unsigned int bits = 0;
	int count = 0;
	for (const char *p = start; p < stop; p++) {
		int v = base64Value((unsigned char)*p);
		if (v < 0)
			continue;	/* line breaks and padding */
		bits = (bits << 6) | (unsigned)v;
		count += 6;
		if (count >= 8) {
			count -= 8;
			UInt8 byte = (UInt8)(bits >> count);
			CFDataAppendBytes(out, &byte, 1);
		}
	}
	return out;
}

/* A certificate from a PEM or DER file. */
static SecCertificateRef readCertificate(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		return NULL;
	}
	CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
	UInt8 buf[8192];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
		CFDataAppendBytes(data, buf, (CFIndex)n);
	fclose(f);
	/* PEM: the base64 between the first BEGIN and END CERTIFICATE lines. */
	CFDataRef der = pemCertificate(data);
	SecCertificateRef cert = SecCertificateCreateWithData(NULL, der ? der : data);
	if (der)
		CFRelease(der);
	CFRelease(data);
	if (!cert)
		fprintf(stderr, "%s: not a certificate\n", path);
	return cert;
}

static SecPolicyRef policyNamed(const char *name, const char *hostname)
{
	CFStringRef host = hostname ? CFStringCreateWithCString(NULL, hostname, kCFStringEncodingUTF8) : NULL;
	SecPolicyRef p = NULL;
	if (!strcmp(name, "ssl"))
		p = SecPolicyCreateSSL(true, host);
	else if (!strcmp(name, "smime"))
		p = SecPolicyCreateWithProperties(kSecPolicyAppleSMIME, NULL);
	else if (!strcmp(name, "codeSign"))
		p = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, NULL);
	else if (!strcmp(name, "basic"))
		p = SecPolicyCreateBasicX509();
	if (host)
		CFRelease(host);
	return p;
}

static void printSubject(SecCertificateRef cert)
{
	CFStringRef summary = SecCertificateCopySubjectSummary(cert);
	char text[512] = "(no name)";
	if (summary) {
		CFStringGetCString(summary, text, sizeof(text), kCFStringEncodingUTF8);
		CFRelease(summary);
	}
	printf("%s", text);
}

static int addTrusted(int argc, char **argv)
{
	SecTrustSettingsDomain domain = kSecTrustSettingsDomainUser;
	const char *result = NULL, *policy = NULL, *hostname = NULL;
	int ch;
	while ((ch = getopt(argc, argv, "dr:p:s:k:")) != -1) {
		switch (ch) {
		case 'd': domain = kSecTrustSettingsDomainAdmin; break;
		case 'r': result = optarg; break;
		case 'p': policy = optarg; break;
		case 's': hostname = optarg; break;
		case 'k': break;	/* the keychain: Finch keeps the certificate with its settings */
		default: return usage();
		}
	}
	if (optind != argc - 1)
		return usage();
	SecCertificateRef cert = readCertificate(argv[optind]);
	if (!cert)
		return 1;
	CFMutableDictionaryRef setting = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (result) {
		int r;
		if (!strcmp(result, "trustRoot"))
			r = kSecTrustSettingsResultTrustRoot;
		else if (!strcmp(result, "trustAsRoot"))
			r = kSecTrustSettingsResultTrustAsRoot;
		else if (!strcmp(result, "deny"))
			r = kSecTrustSettingsResultDeny;
		else if (!strcmp(result, "unspecified"))
			r = kSecTrustSettingsResultUnspecified;
		else
			return usage();
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &r);
		CFDictionarySetValue(setting, kSecTrustSettingsResult, number);
		CFRelease(number);
	}
	if (policy) {
		SecPolicyRef p = policyNamed(policy, NULL);
		if (!p)
			return usage();
		CFDictionarySetValue(setting, kSecTrustSettingsPolicy, p);
		CFRelease(p);
	}
	if (hostname) {
		CFStringRef host = CFStringCreateWithCString(NULL, hostname, kCFStringEncodingUTF8);
		CFDictionarySetValue(setting, kSecTrustSettingsPolicyString, host);
		CFRelease(host);
	}
	OSStatus status = SecTrustSettingsSetTrustSettings(cert, domain,
	    CFDictionaryGetCount(setting) ? (CFTypeRef)setting : NULL);
	CFRelease(setting);
	CFRelease(cert);
	if (status != errSecSuccess) {
		report("SetTrustSettings", status);
		return 1;
	}
	return 0;
}

static int removeTrusted(int argc, char **argv)
{
	SecTrustSettingsDomain domain = kSecTrustSettingsDomainUser;
	int ch;
	while ((ch = getopt(argc, argv, "d")) != -1) {
		if (ch != 'd')
			return usage();
		domain = kSecTrustSettingsDomainAdmin;
	}
	if (optind != argc - 1)
		return usage();
	SecCertificateRef cert = readCertificate(argv[optind]);
	if (!cert)
		return 1;
	OSStatus status = SecTrustSettingsRemoveTrustSettings(cert, domain);
	CFRelease(cert);
	if (status != errSecSuccess) {
		report("RemoveTrustSettings", status);
		return 1;
	}
	return 0;
}

static const char *resultName(int r)
{
	switch (r) {
	case kSecTrustSettingsResultTrustRoot: return "trustRoot";
	case kSecTrustSettingsResultTrustAsRoot: return "trustAsRoot";
	case kSecTrustSettingsResultDeny: return "deny";
	case kSecTrustSettingsResultUnspecified: return "unspecified";
	default: return "invalid";
	}
}

static int dumpTrust(int argc, char **argv)
{
	SecTrustSettingsDomain domain = kSecTrustSettingsDomainUser;
	int ch;
	while ((ch = getopt(argc, argv, "ds")) != -1) {
		if (ch == 'd')
			domain = kSecTrustSettingsDomainAdmin;
		else if (ch == 's')
			domain = kSecTrustSettingsDomainSystem;
		else
			return usage();
	}
	CFArrayRef certs = NULL;
	OSStatus status = SecTrustSettingsCopyCertificates(domain, &certs);
	if (status == errSecNoTrustSettings) {
		fprintf(stderr, "SecTrustSettingsCopyCertificates: No Trust Settings were found.\n");
		return 1;
	}
	if (status != errSecSuccess) {
		report("CopyCertificates", status);
		return 1;
	}
	printf("Number of trusted certs = %ld\n", (long)CFArrayGetCount(certs));
	for (CFIndex i = 0; i < CFArrayGetCount(certs); i++) {
		SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);
		printf("Cert %ld: ", (long)i);
		printSubject(cert);
		printf("\n");
		if (domain == kSecTrustSettingsDomainSystem)
			continue;
		CFArrayRef settings = NULL;
		if (SecTrustSettingsCopyTrustSettings(cert, domain, &settings) != errSecSuccess || !settings)
			continue;
		printf("   Number of trust settings : %ld\n", (long)CFArrayGetCount(settings));
		for (CFIndex j = 0; j < CFArrayGetCount(settings); j++) {
			CFDictionaryRef d = CFArrayGetValueAtIndex(settings, j);
			int r = kSecTrustSettingsResultTrustRoot;
			CFNumberRef number = CFDictionaryGetValue(d, kSecTrustSettingsResult);
			if (number)
				CFNumberGetValue(number, kCFNumberIntType, &r);
			printf("   Trust Setting %ld:\n", (long)j);
			SecPolicyRef policy = (SecPolicyRef)CFDictionaryGetValue(d, kSecTrustSettingsPolicy);
			if (policy) {
				CFDictionaryRef properties = SecPolicyCopyProperties(policy);
				CFStringRef oid = properties ? CFDictionaryGetValue(properties, kSecPolicyOid) : NULL;
				char text[128] = "";
				if (oid)
					CFStringGetCString(oid, text, sizeof(text), kCFStringEncodingUTF8);
				printf("      Policy OID            : %s\n", text);
				if (properties)
					CFRelease(properties);
			}
			printf("      Result Type           : %s\n", resultName(r));
		}
		CFRelease(settings);
	}
	CFRelease(certs);
	return 0;
}

static int verifyCert(int argc, char **argv)
{
	CFMutableArrayRef certs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFMutableArrayRef roots = NULL;
	const char *policy = "basic", *hostname = NULL;
	int ch;
	while ((ch = getopt(argc, argv, "c:r:p:s:")) != -1) {
		SecCertificateRef cert;
		switch (ch) {
		case 'c':
		case 'r':
			if (!(cert = readCertificate(optarg)))
				return 1;
			if (ch == 'r') {
				if (!roots)
					roots = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
				CFArrayAppendValue(roots, cert);
			} else
				CFArrayAppendValue(certs, cert);
			CFRelease(cert);
			break;
		case 'p': policy = optarg; break;
		case 's': hostname = optarg; break;
		default: return usage();
		}
	}
	if (CFArrayGetCount(certs) == 0)
		return usage();
	SecPolicyRef p = policyNamed(policy, hostname);
	if (!p)
		return usage();
	SecTrustRef trust = NULL;
	OSStatus status = SecTrustCreateWithCertificates(certs, p, &trust);
	if (status == errSecSuccess && roots)
		status = SecTrustSetAnchorCertificates(trust, roots);
	CFErrorRef error = NULL;
	bool ok = status == errSecSuccess && SecTrustEvaluateWithError(trust, &error);
	if (ok)
		printf("...certificate verification successful.\n");
	else {
		CFStringRef description = error ? CFErrorCopyDescription(error) : NULL;
		char text[512] = "evaluation failed";
		if (description) {
			CFStringGetCString(description, text, sizeof(text), kCFStringEncodingUTF8);
			CFRelease(description);
		}
		fprintf(stderr, "Cert Verify Result: %s\n", text);
	}
	if (error) CFRelease(error);
	if (trust) CFRelease(trust);
	CFRelease(p);
	CFRelease(certs);
	if (roots) CFRelease(roots);
	return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return usage();
	const char *command = argv[1];
	argc--;
	argv++;
	optind = 1;
	if (!strcmp(command, "add-trusted-cert"))
		return addTrusted(argc, argv);
	if (!strcmp(command, "remove-trusted-cert"))
		return removeTrusted(argc, argv);
	if (!strcmp(command, "dump-trust-settings"))
		return dumpTrust(argc, argv);
	if (!strcmp(command, "verify-cert"))
		return verifyCert(argc, argv);
	fprintf(stderr, "security: unknown command \"%s\" (Finch's security has add-trusted-cert, "
	    "remove-trusted-cert, dump-trust-settings and verify-cert)\n", command);
	return 2;
}

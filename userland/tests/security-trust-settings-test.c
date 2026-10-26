/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Trust settings (Finch-only): a root the user trusts makes a server
 * certificate it signed trusted, a distrusted certificate fails its chain, a
 * setting for another policy doesn't apply, the administrator's settings are
 * root's and the system's are read-only. Settings live under a private folder
 * (FINCH_TRUST_SETTINGS_ROOT), evaluated at a fixed date.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/SecTrustSettings.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "security-trust-settings-certs.inc"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures;

static void check(const char *what, bool ok)
{
	printf("%s: %s\n", what, ok ? "pass" : "FAIL");
	if (!ok)
		failures++;
}

static SecCertificateRef certificate(const unsigned char *der, size_t length)
{
	CFDataRef data = CFDataCreate(NULL, der, (CFIndex)length);
	SecCertificateRef c = SecCertificateCreateWithData(NULL, data);
	CFRelease(data);
	return c;
}

/* The result of evaluating the server certificate for trust.finch.test. */
static SecTrustResultType evaluate(SecCertificateRef leaf, SecPolicyRef policy, CFArrayRef ownAnchors)
{
	SecTrustRef trust = NULL;
	SecTrustResultType result = kSecTrustResultInvalid;
	if (SecTrustCreateWithCertificates(leaf, policy, &trust) != errSecSuccess)
		return result;
	/* 2027-01-01 */
	CFDateRef date = CFDateCreate(NULL, 820454400.0);
	SecTrustSetVerifyDate(trust, date);
	CFRelease(date);
	if (ownAnchors)
		SecTrustSetAnchorCertificates(trust, ownAnchors);
	(void)SecTrustEvaluateWithError(trust, NULL);
	SecTrustGetTrustResult(trust, &result);
	CFRelease(trust);
	return result;
}

static bool trusted(SecTrustResultType r)
{
	return r == kSecTrustResultProceed || r == kSecTrustResultUnspecified;
}

int main(void)
{
	char root[] = "/tmp/finch-trust-settings.XXXXXX";
	if (!mkdtemp(root)) {
		perror("mkdtemp");
		return 1;
	}
	setenv("FINCH_TRUST_SETTINGS_ROOT", root, 1);
	SecCertificateRef ca = certificate(trust_settings_ca, sizeof(trust_settings_ca));
	SecCertificateRef leaf = certificate(trust_settings_leaf, sizeof(trust_settings_leaf));
	SecPolicyRef ssl = SecPolicyCreateSSL(true, CFSTR("trust.finch.test"));
	SecPolicyRef smime = SecPolicyCreateWithProperties(kSecPolicyAppleSMIME, NULL);
	check("fixtures load", ca && leaf && ssl && smime);

	check("without settings the server certificate isn't trusted", !trusted(evaluate(leaf, ssl, NULL)));
	CFArrayRef certs = NULL;
	check("the user has no settings", SecTrustSettingsCopyCertificates(kSecTrustSettingsDomainUser, &certs) ==
	    errSecNoTrustSettings && certs == NULL);

	/* The user trusts the root. */
	check("the user trusts the root", SecTrustSettingsSetTrustSettings(ca, kSecTrustSettingsDomainUser, NULL) ==
	    errSecSuccess);
	char path[1024];
	struct stat st;
	snprintf(path, sizeof(path), "%s/user-%u/Library/Security/Trust Settings/User.plist", root, getuid());
	check("the user's settings file is private", stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
	check("now the server certificate is trusted, as the user chose",
	    evaluate(leaf, ssl, NULL) == kSecTrustResultProceed);
	check("the user's settings list the root", SecTrustSettingsCopyCertificates(kSecTrustSettingsDomainUser,
	    &certs) == errSecSuccess && certs && CFArrayGetCount(certs) == 1 &&
	    CFEqual(CFArrayGetValueAtIndex(certs, 0), ca));
	if (certs)
		CFRelease(certs);
	CFArrayRef settings = NULL;
	check("with no constraints", SecTrustSettingsCopyTrustSettings(ca, kSecTrustSettingsDomainUser, &settings) ==
	    errSecSuccess && settings && CFArrayGetCount(settings) == 0);
	if (settings)
		CFRelease(settings);
	CFDateRef modified = NULL;
	check("and a modification date", SecTrustSettingsCopyModificationDate(ca, kSecTrustSettingsDomainUser,
	    &modified) == errSecSuccess && modified);
	if (modified)
		CFRelease(modified);
	/* A caller with its own anchors alone decides by them: trusted, but as its choice. */
	CFArrayRef ownAnchors = CFArrayCreate(NULL, (const void **)&ca, 1, &kCFTypeArrayCallBacks);
	check("a caller's own anchors alone leave the settings out",
	    evaluate(leaf, ssl, ownAnchors) == kSecTrustResultUnspecified);
	CFRelease(ownAnchors);

	/* The user distrusts the server certificate. */
	int deny = kSecTrustSettingsResultDeny;
	CFNumberRef denyNumber = CFNumberCreate(NULL, kCFNumberIntType, &deny);
	const void *k[] = { kSecTrustSettingsResult }, *v[] = { denyNumber };
	CFDictionaryRef denySetting = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	check("the user distrusts the server certificate", SecTrustSettingsSetTrustSettings(leaf,
	    kSecTrustSettingsDomainUser, denySetting) == errSecSuccess);
	check("which fails its chain", evaluate(leaf, ssl, NULL) == kSecTrustResultDeny);
	check("removing that", SecTrustSettingsRemoveTrustSettings(leaf, kSecTrustSettingsDomainUser) == errSecSuccess);
	check("trusts it again", evaluate(leaf, ssl, NULL) == kSecTrustResultProceed);
	check("removing it twice is not found", SecTrustSettingsRemoveTrustSettings(leaf,
	    kSecTrustSettingsDomainUser) == errSecItemNotFound);

	/* A setting for another policy doesn't apply. */
	const void *pk[] = { kSecTrustSettingsPolicy }, *pv[] = { smime };
	CFDictionaryRef mailOnly = CFDictionaryCreate(NULL, pk, pv, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	check("the root trusted for mail only", SecTrustSettingsSetTrustSettings(ca, kSecTrustSettingsDomainUser,
	    mailOnly) == errSecSuccess);
	check("isn't trusted for a server", !trusted(evaluate(leaf, ssl, NULL)));
	settings = NULL;
	check("its setting names the mail policy", SecTrustSettingsCopyTrustSettings(ca, kSecTrustSettingsDomainUser,
	    &settings) == errSecSuccess && settings && CFArrayGetCount(settings) == 1 &&
	    CFGetTypeID(CFDictionaryGetValue(CFArrayGetValueAtIndex(settings, 0), kSecTrustSettingsPolicy)) ==
	    SecPolicyGetTypeID());
	if (settings)
		CFRelease(settings);

	/* Only a root can be trusted as one. */
	int asRoot = kSecTrustSettingsResultTrustRoot;
	CFNumberRef rootNumber = CFNumberCreate(NULL, kCFNumberIntType, &asRoot);
	const void *rv[] = { rootNumber };
	CFDictionaryRef rootSetting = CFDictionaryCreate(NULL, k, rv, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	check("a server certificate can't be a trusted root", SecTrustSettingsSetTrustSettings(leaf,
	    kSecTrustSettingsDomainUser, rootSetting) == errSecParam);

	/* Exported and imported whole. */
	CFDataRef exported = NULL;
	check("the user's settings export", SecTrustSettingsCreateExternalRepresentation(kSecTrustSettingsDomainUser,
	    &exported) == errSecSuccess && exported);
	check("removing the root", SecTrustSettingsRemoveTrustSettings(ca, kSecTrustSettingsDomainUser) == errSecSuccess);
	check("and importing them back", exported && SecTrustSettingsImportExternalRepresentation(
	    kSecTrustSettingsDomainUser, exported) == errSecSuccess);
	check("restores it", SecTrustSettingsCopyTrustSettings(ca, kSecTrustSettingsDomainUser, &settings) ==
	    errSecSuccess && settings && CFArrayGetCount(settings) == 1);
	if (settings)
		CFRelease(settings);
	if (exported)
		CFRelease(exported);

	/* The administrator's are root's; the system's are read-only. */
	OSStatus admin = SecTrustSettingsSetTrustSettings(ca, kSecTrustSettingsDomainAdmin, NULL);
	check("the administrator's settings are root's", geteuid() == 0 ? admin == errSecSuccess :
	    admin == errAuthorizationDenied);
	/* (as root, it was set: taken away again for the checks below) */
	if (admin == errSecSuccess)
		SecTrustSettingsRemoveTrustSettings(ca, kSecTrustSettingsDomainAdmin);
	check("the system's are read-only", SecTrustSettingsSetTrustSettings(ca, kSecTrustSettingsDomainSystem,
	    NULL) == errSecDataNotModifiable);
	certs = NULL;
	check("the system's list the pinned roots", SecTrustSettingsCopyCertificates(kSecTrustSettingsDomainSystem,
	    &certs) == errSecSuccess && certs && CFArrayGetCount(certs) == 121);
	if (certs)
		CFRelease(certs);

	/* A corrupt file is reported, not trusted. */
	FILE *f = fopen(path, "w");
	if (f) {
		fputs("not a property list", f);
		fclose(f);
	}
	check("a corrupt settings file is reported", SecTrustSettingsCopyCertificates(kSecTrustSettingsDomainUser,
	    &certs) == errSecInvalidTrustSettings);
	check("and grants nothing", !trusted(evaluate(leaf, ssl, NULL)));

	char command[1200];
	snprintf(command, sizeof(command), "rm -rf '%s'", root);
	(void)system(command);
	printf("failures: %d\n", failures);
	return failures != 0;
}

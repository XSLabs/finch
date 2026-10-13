/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check login-created keychain behavior from Finch's disposable UID 6000 user. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char guestMarker[] =
    "/System/Library/Finch/LaunchAgents/org.finch.securityd.plist";
static const char testHome[] = "/private/var/rw/Users/finchconsole";
static const char loginPassword[] = "loginpassword";
static const char wrongPassword[] = "not-loginpassword";
static const char alternatePassword[] = "alternate-keychain-password";
static const char serviceName[] = "org.finch.security-keychain-login-test";
static const char accountName[] = "login-probe";
static const char secretValue[] = "dummy login keychain secret";
static int failures;

static void check(const char *name, BOOL passed)
{
	printf("%s: %s\n", name, passed ? "pass" : "FAIL");
	if (!passed)
		failures++;
}

static void checkStatus(const char *name, OSStatus actual, OSStatus expected)
{
	BOOL passed = actual == expected;
	printf("%s: %s (%d)\n", name, passed ? "pass" : "FAIL", (int)actual);
	if (!passed)
		failures++;
}

static int finish(void)
{
	printf("failures: %d\n", failures);
	return failures ? 1 : 0;
}

static BOOL isTestLogin(void)
{
	struct passwd *account = getpwuid(6000);
	struct stat homeInfo;
	const char *home = getenv("HOME");
	return getuid() == 6000 && geteuid() == 6000 && account &&
	    account->pw_name && strcmp(account->pw_name, "finchconsole") == 0 &&
	    account->pw_dir && strcmp(account->pw_dir, testHome) == 0 &&
	    home && strcmp(home, testHome) == 0 && lstat(testHome, &homeInfo) == 0 &&
	    S_ISDIR(homeInfo.st_mode) && homeInfo.st_uid == 6000 &&
	    (homeInfo.st_mode & 0777) == 0700;
}

static BOOL copyDefaultPath(SecKeychainRef keychain, char path[PATH_MAX],
	const char *expectedPath)
{
	path[0] = '\0';
	UInt32 length = PATH_MAX;
	OSStatus status = SecKeychainGetPath(keychain, &length, path);
	checkStatus("read default keychain path", status, errSecSuccess);
	return status == errSecSuccess && strcmp(path, expectedPath) == 0;
}

static BOOL defaultFileIsOwnedAndPrivate(const char *path)
{
	struct stat info;
	return lstat(path, &info) == 0 && S_ISREG(info.st_mode) &&
	    info.st_uid == 6000 && info.st_nlink == 1 &&
	    (info.st_mode & 0777) == 0600;
}

static NSDictionary *queryForSecret(SecKeychainRef keychain)
{
	return @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: [NSString stringWithUTF8String:serviceName],
		(id)kSecAttrAccount: [NSString stringWithUTF8String:accountName],
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
}

static OSStatus readSecret(SecKeychainRef keychain, CFDataRef *secret)
{
	*secret = NULL;
	NSMutableDictionary *query = [queryForSecret(keychain) mutableCopy];
	query[(id)kSecReturnData] = @YES;
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	if (!status && result && CFGetTypeID(result) == CFDataGetTypeID())
		*secret = (CFDataRef)result;
	else {
		if (result)
			CFRelease(result);
		if (!status)
			status = errSecInternalComponent;
	}
	return status;
}

static BOOL secretMatches(CFDataRef secret)
{
	return secret && CFDataGetLength(secret) == sizeof(secretValue) - 1 &&
	    memcmp(CFDataGetBytePtr(secret), secretValue, sizeof(secretValue) - 1) == 0;
}

static BOOL openDefault(SecKeychainRef *keychain, char path[PATH_MAX])
{
	char expectedPath[PATH_MAX];
	int length = snprintf(expectedPath, sizeof(expectedPath),
	    "%s/Library/Keychains/login.keychain-finch", testHome);
	if (length < 0 || (size_t)length >= sizeof(expectedPath)) {
		check("build expected default keychain path", NO);
		return NO;
	}
	OSStatus status = SecKeychainCopyDefault(keychain);
	checkStatus("copy login default keychain", status, errSecSuccess);
	if (status || !*keychain)
		return NO;
	BOOL pathIsCorrect = copyDefaultPath(*keychain, path, expectedPath);
	check("default keychain uses the test user's home", pathIsCorrect);
	if (!pathIsCorrect)
		return NO;
	BOOL fileIsSafe = defaultFileIsOwnedAndPrivate(path);
	check("default keychain file is owned by UID 6000 and private", fileIsSafe);
	if (!fileIsSafe)
		return NO;
	return YES;
}

static int runLoginTest(void)
{
	SecKeychainRef keychain = NULL;
	char path[PATH_MAX];
	if (!openDefault(&keychain, path)) {
		if (keychain)
			CFRelease(keychain);
		return finish();
	}

	/* Check login's work before this test tries any password. */
	SecKeychainStatus keychainStatus = 0;
	OSStatus status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("check keychain state immediately after login", status, errSecSuccess);
	BOOL alreadyUnlocked = status == errSecSuccess &&
	    (keychainStatus & kSecUnlockStateStatus) != 0;
	check("PAM left the default keychain unlocked before this test", alreadyUnlocked);
	if (!alreadyUnlocked) {
		CFRelease(keychain);
		return finish();
	}

	NSMutableDictionary *item = [queryForSecret(keychain) mutableCopy];
	item[(id)kSecValueData] = [NSData dataWithBytes:secretValue length:sizeof(secretValue) - 1];
	status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
	checkStatus("add a dummy login secret", status, errSecSuccess);
	BOOL itemAdded = status == errSecSuccess;

	CFDataRef secret = NULL;
	status = readSecret(keychain, &secret);
	checkStatus("read the dummy login secret", status, errSecSuccess);
	check("read secret matches", status == errSecSuccess && secretMatches(secret));
	if (secret)
		CFRelease(secret);

	status = SecKeychainLock(keychain);
	checkStatus("lock the default keychain", status, errSecSuccess);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("check locked keychain state", status, errSecSuccess);
	check("lock cleared the unlocked state", status == errSecSuccess &&
	    !(keychainStatus & kSecUnlockStateStatus));

	secret = NULL;
	status = readSecret(keychain, &secret);
	checkStatus("locked keychain refused the read", status, errSecInteractionNotAllowed);
	check("locked read returned no secret", secret == NULL);
	if (secret)
		CFRelease(secret);

	status = SecKeychainUnlock(keychain, sizeof(wrongPassword) - 1, wrongPassword, false);
	checkStatus("wrong login password was refused", status, errSecAuthFailed);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("check state after wrong password", status, errSecSuccess);
	check("wrong password left the keychain locked", status == errSecSuccess &&
	    !(keychainStatus & kSecUnlockStateStatus));

	status = SecKeychainUnlock(keychain, sizeof(loginPassword) - 1, loginPassword, false);
	checkStatus("login password unlocked the keychain", status, errSecSuccess);

	secret = NULL;
	status = readSecret(keychain, &secret);
	checkStatus("read the dummy secret after unlock", status, errSecSuccess);
	check("dummy secret survived lock and unlock",
	    status == errSecSuccess && secretMatches(secret));
	if (secret)
		CFRelease(secret);

	if (itemAdded) {
		status = SecItemDelete((__bridge CFDictionaryRef)queryForSecret(keychain));
		checkStatus("remove the dummy login secret", status, errSecSuccess);
		secret = NULL;
		status = readSecret(keychain, &secret);
		checkStatus("confirm the dummy secret is gone", status, errSecItemNotFound);
		check("removed secret returned no data", secret == NULL);
		if (secret)
			CFRelease(secret);
	}

	CFRelease(keychain);
	return finish();
}

static int runLockDefault(void)
{
	SecKeychainRef keychain = NULL;
	char path[PATH_MAX];
	if (!openDefault(&keychain, path)) {
		if (keychain)
			CFRelease(keychain);
		return finish();
	}
	SecKeychainStatus state = 0;
	OSStatus status = SecKeychainGetStatus(keychain, &state);
	checkStatus("check keychain before relogin lock", status, errSecSuccess);
	check("keychain is unlocked before relogin lock",
	    status == errSecSuccess && (state & kSecUnlockStateStatus));
	status = SecKeychainLock(keychain);
	checkStatus("leave existing keychain locked for next login", status, errSecSuccess);
	state = 0;
	status = SecKeychainGetStatus(keychain, &state);
	checkStatus("check keychain after relogin lock", status, errSecSuccess);
	check("existing keychain is locked for next login",
	    status == errSecSuccess && !(state & kSecUnlockStateStatus));
	CFRelease(keychain);
	return finish();
}

static int runSeedAlternate(void)
{
	SecKeychainRef existing = NULL;
	char path[PATH_MAX];
	if (!openDefault(&existing, path)) {
		if (existing)
			CFRelease(existing);
		return finish();
	}
	OSStatus status = SecKeychainDelete(existing);
	checkStatus("remove the disposable login keychain", status, errSecSuccess);
	CFRelease(existing);
	if (status)
		return finish();

	SecKeychainRef alternate = NULL;
	status = SecKeychainCreate(path, sizeof(alternatePassword) - 1, alternatePassword,
	    false, NULL, &alternate);
	checkStatus("create a keychain with an alternate password", status, errSecSuccess);
	if (!status && alternate) {
		status = SecKeychainLockAll();
		checkStatus("lock alternate-password keychain for relogin", status, errSecSuccess);
		SecKeychainStatus state = 0;
		status = SecKeychainGetStatus(alternate, &state);
		checkStatus("check alternate keychain before relogin", status, errSecSuccess);
		check("alternate keychain is left locked", status == errSecSuccess &&
		    !(state & kSecUnlockStateStatus));
	}
	if (alternate)
		CFRelease(alternate);
	return finish();
}

static int runVerifyAlternate(void)
{
	SecKeychainRef alternate = NULL;
	char path[PATH_MAX];
	if (!openDefault(&alternate, path)) {
		if (alternate)
			CFRelease(alternate);
		return finish();
	}
	SecKeychainStatus state = 0;
	OSStatus status = SecKeychainGetStatus(alternate, &state);
	checkStatus("check keychain state before any test unlock", status, errSecSuccess);
	BOOL stayedLocked = status == errSecSuccess && !(state & kSecUnlockStateStatus);
	check("login left the alternate-password keychain locked", stayedLocked);
	if (!stayedLocked) {
		CFRelease(alternate);
		return finish();
	}

	CFDataRef secret = NULL;
	status = readSecret(alternate, &secret);
	checkStatus("locked alternate keychain refused reads", status, errSecInteractionNotAllowed);
	check("locked alternate read returned no secret", secret == NULL);
	if (secret)
		CFRelease(secret);

	status = SecKeychainUnlock(alternate, sizeof(loginPassword) - 1, loginPassword, false);
	checkStatus("login password did not unlock the alternate keychain", status, errSecAuthFailed);
	state = 0;
	status = SecKeychainGetStatus(alternate, &state);
	checkStatus("check state after login-password mismatch", status, errSecSuccess);
	check("mismatched login password left it locked", status == errSecSuccess &&
	    !(state & kSecUnlockStateStatus));

	status = SecKeychainUnlock(alternate, sizeof(alternatePassword) - 1,
	    alternatePassword, false);
	checkStatus("alternate password can recover the keychain", status, errSecSuccess);
	CFRelease(alternate);
	if (status)
		return finish();

	/* Restore the disposable account's normal fixture for any later login test. */
	SecKeychainRef recovered = NULL;
	SecKeychainRef current = NULL;
	status = SecKeychainOpen(path, &current);
	checkStatus("reopen recovered alternate keychain", status, errSecSuccess);
	if (!status && current) {
		status = SecKeychainDelete(current);
		checkStatus("remove recovered alternate keychain", status, errSecSuccess);
	}
	if (current)
		CFRelease(current);
	if (!status) {
		status = SecKeychainCreate(path, sizeof(loginPassword) - 1, loginPassword,
		    false, NULL, &recovered);
		checkStatus("restore the login-password fixture", status, errSecSuccess);
	}
	if (recovered) {
		state = 0;
		status = SecKeychainGetStatus(recovered, &state);
		checkStatus("check restored fixture state", status, errSecSuccess);
		check("restored login fixture is unlocked", status == errSecSuccess &&
		    (state & kSecUnlockStateStatus));
		CFRelease(recovered);
	}
	return finish();
}

int main(int argc, char **argv)
{
	const char *mode = "default";
	if (argc == 2)
		mode = argv[1];
	else if (argc != 1) {
		fprintf(stderr, "usage: %s [--lock-default|--seed-alternate-password|--verify-alternate-password]\n",
		    argv[0]);
		return 64;
	}
	if (strcmp(mode, "default") != 0 && strcmp(mode, "--lock-default") != 0 &&
	    strcmp(mode, "--seed-alternate-password") != 0 &&
	    strcmp(mode, "--verify-alternate-password") != 0) {
		fprintf(stderr, "unknown test mode: %s\n", mode);
		return 64;
	}

	/* Check both guards before calling any keychain API. */
	if (access(guestMarker, F_OK) != 0) {
		puts("security keychain login test: skip (Finch guest only)");
		return 77;
	}
	if (!isTestLogin()) {
		puts("security keychain login test: skip (requires the disposable UID 6000 login)");
		return 77;
	}
	puts("security keychain login test: running as the disposable UID 6000 user");

	if (strcmp(mode, "--lock-default") == 0)
		return runLockDefault();
	if (strcmp(mode, "--seed-alternate-password") == 0)
		return runSeedAlternate();
	if (strcmp(mode, "--verify-alternate-password") == 0)
		return runVerifyAlternate();
	return runLoginTest();
}

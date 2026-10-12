/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures;

static void
checkStatus(const char *name, OSStatus actual, OSStatus expected)
{
	BOOL ok = actual == expected;
	printf("%s: %s (%d)\n", name, ok ? "pass" : "FAIL", (int)actual);
	if (!ok)
		failures++;
}

static void
checkFlag(const char *name, BOOL actual)
{
	printf("%s: %s\n", name, actual ? "pass" : "FAIL");
	if (!actual)
		failures++;
}

static BOOL
writeFile(const char *path, const void *bytes, size_t length, mode_t mode)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
	if (fd < 0)
		return NO;
	BOOL ok = fchmod(fd, mode) == 0;
	size_t offset = 0;
	while (ok && offset < length) {
		ssize_t count = write(fd, (const char *)bytes + offset, length - offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			ok = NO;
			break;
		}
		offset += (size_t)count;
	}
	if (close(fd) < 0)
		ok = NO;
	return ok;
}

static NSString *
readSecret(SecKeychainRef keychain, OSStatus *status)
{
	if (!keychain) {
		*status = errSecInvalidKeychain;
		return nil;
	}
	NSDictionary *query = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: @"org.finch.keychain-storage-test",
		(id)kSecAttrAccount: @"sample",
		(id)kSecReturnData: @YES,
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	CFTypeRef result = NULL;
	*status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	NSString *value = nil;
	if (!*status && result && CFGetTypeID(result) == CFDataGetTypeID())
		value = [[NSString alloc] initWithData:(__bridge NSData *)result encoding:NSUTF8StringEncoding];
	if (result)
		CFRelease(result);
	return value;
}

static BOOL
hasFinchSecurity(void)
{
	Dl_info info = {0};
	BOOL frameworkPath = dladdr((const void *)SecKeychainCreate, &info) && info.dli_fname &&
	    (strstr(info.dli_fname, "/System/Library/Finch/") ||
	    strstr(info.dli_fname, "/build/root/System/Library/Frameworks/Security.framework/"));
	return frameworkPath || access(
	    "/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist", F_OK) == 0;
}

int
main(void)
{
	/* Never touch Security or a user's default keychain on the host. */
	if (!hasFinchSecurity()) {
		fprintf(stderr, "This test only runs inside Finch.\n");
		return 77;
	}
	puts("Security source: Finch");
	SecKeychainRef invalidPath = NULL;
	checkStatus("empty path", SecKeychainCreate("", 0, NULL, false, NULL, &invalidPath), errSecParam);
	checkFlag("empty path returned no keychain", invalidPath == NULL);
	const char badUTF8[] = { (char)0xff, 0 };
	checkStatus("invalid UTF-8 path", SecKeychainOpen(badUTF8, &invalidPath), errSecParam);
	checkFlag("invalid UTF-8 returned no keychain", invalidPath == NULL);

	char directory[PATH_MAX];
	int n = snprintf(directory, sizeof(directory), "%s/finch-keychain-storage.XXXXXX",
	    NSTemporaryDirectory().fileSystemRepresentation);
	if (n < 0 || (size_t)n >= sizeof(directory) || !mkdtemp(directory)) {
		perror("make private test folder");
		return 1;
	}
	struct stat directoryInfo;
	checkFlag("test folder is private", stat(directory, &directoryInfo) == 0 &&
	    (directoryInfo.st_mode & 0777) == 0700);

	char keychainPath[PATH_MAX];
	n = snprintf(keychainPath, sizeof(keychainPath), "%s/main.keychain", directory);
	if (n < 0 || (size_t)n >= sizeof(keychainPath))
		return 1;
	SecKeychainRef keychain = NULL;
	OSStatus status = SecKeychainCreate(keychainPath, 0, NULL, false, NULL, &keychain);
	checkStatus("create", status, errSecSuccess);
	checkFlag("create returned a keychain", keychain != NULL);
	if (status != errSecSuccess || !keychain) {
		if (keychain)
			CFRelease(keychain);
		rmdir(directory);
		printf("failures: %d\n", failures);
		return 1;
	}

	SecKeychainStatus keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status", status, errSecSuccess);
	checkFlag("status reports unlocked", (keychainStatus & kSecUnlockStateStatus) != 0);

	NSData *firstSecret = [@"first dummy secret" dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary *item = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: @"org.finch.keychain-storage-test",
		(id)kSecAttrAccount: @"sample",
		(id)kSecValueData: firstSecret,
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
	checkStatus("add dummy secret", status, errSecSuccess);
	NSString *value = readSecret(keychain, &status);
	checkStatus("read dummy secret", status, errSecSuccess);
	checkFlag("first secret matches", [value isEqualToString:@"first dummy secret"]);

	NSDictionary *updateQuery = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: @"org.finch.keychain-storage-test",
		(id)kSecAttrAccount: @"sample",
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	NSDictionary *update = @{ (id)kSecValueData: [@"second dummy secret" dataUsingEncoding:NSUTF8StringEncoding] };
	status = SecItemUpdate((__bridge CFDictionaryRef)updateQuery, (__bridge CFDictionaryRef)update);
	checkStatus("update dummy secret", status, errSecSuccess);
	value = readSecret(keychain, &status);
	checkStatus("read updated secret", status, errSecSuccess);
	checkFlag("updated secret matches", [value isEqualToString:@"second dummy secret"]);

	NSData *beforeDuplicate = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:keychainPath]];
	SecKeychainRef duplicate = NULL;
	status = SecKeychainCreate(keychainPath, 0, NULL, false, NULL, &duplicate);
	checkStatus("create existing keychain", status, errSecDuplicateKeychain);
	checkFlag("duplicate create returned no keychain", duplicate == NULL);
	NSData *afterDuplicate = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:keychainPath]];
	checkFlag("duplicate create left file unchanged", beforeDuplicate && [beforeDuplicate isEqualToData:afterDuplicate]);
	if (duplicate)
		CFRelease(duplicate);

	CFRelease(keychain);
	keychain = NULL;
	status = SecKeychainOpen(keychainPath, &keychain);
	checkStatus("reopen", status, errSecSuccess);
	if (status != errSecSuccess || !keychain) {
		if (keychain)
			CFRelease(keychain);
		unlink(keychainPath);
		rmdir(directory);
		printf("failures: %d\n", failures);
		return 1;
	}
	value = readSecret(keychain, &status);
	checkStatus("read after reopen", status, errSecSuccess);
	checkFlag("saved secret survived reopen", [value isEqualToString:@"second dummy secret"]);

	/* Damage only this private test file, then make sure APIs reject it without
	 * rewriting or deleting its contents. */
	static const char malformed[] = "not a keychain plist";
	checkFlag("make malformed fixture", writeFile(keychainPath, malformed, sizeof(malformed) - 1, 0600));
	keychainStatus = (SecKeychainStatus)0x7fffffff;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("malformed status", status, errSecInvalidKeychain);
	checkFlag("failed status cleared output", keychainStatus == 0);
	value = readSecret(keychain, &status);
	checkStatus("read malformed file", status, errSecInvalidKeychain);
	checkFlag("malformed read returned no secret", value == nil);
	NSDictionary *newItem = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: @"org.finch.keychain-storage-test",
		(id)kSecAttrAccount: @"other",
		(id)kSecValueData: [@"another dummy secret" dataUsingEncoding:NSUTF8StringEncoding],
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	status = SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
	checkStatus("write malformed file", status, errSecInvalidKeychain);
	SecKeychainRef invalid = NULL;
	status = SecKeychainOpen(keychainPath, &invalid);
	checkStatus("open malformed file", status, errSecInvalidKeychain);
	checkFlag("invalid open returned no keychain", invalid == NULL);
	if (invalid)
		CFRelease(invalid);
	status = SecKeychainCreate(keychainPath, 0, NULL, false, NULL, &invalid);
	checkStatus("create over malformed file", status, errSecInvalidKeychain);
	checkFlag("invalid create returned no keychain", invalid == NULL);
	if (invalid)
		CFRelease(invalid);
	status = SecKeychainDelete(keychain);
	checkStatus("delete malformed file", status, errSecInvalidKeychain);
	NSData *malformedAfter = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:keychainPath]];
	checkFlag("rejected file stayed untouched", [malformedAfter isEqualToData:[NSData dataWithBytes:malformed length:sizeof(malformed) - 1]]);
	CFRelease(keychain);
	keychain = NULL;

	/* Unsafe path shapes must fail promptly and leave their targets in place. */
	char victimPath[PATH_MAX], linkPath[PATH_MAX], fifoPath[PATH_MAX], hardPath[PATH_MAX], hardSourcePath[PATH_MAX],
	    permissivePath[PATH_MAX], emptyPath[PATH_MAX], oversizedPath[PATH_MAX], parentPath[PATH_MAX], childPath[PATH_MAX];
	snprintf(victimPath, sizeof(victimPath), "%s/victim", directory);
	snprintf(linkPath, sizeof(linkPath), "%s/symlink.keychain", directory);
	snprintf(fifoPath, sizeof(fifoPath), "%s/fifo.keychain", directory);
	snprintf(hardPath, sizeof(hardPath), "%s/hardlink.keychain", directory);
	snprintf(hardSourcePath, sizeof(hardSourcePath), "%s/hardlink-source", directory);
	snprintf(permissivePath, sizeof(permissivePath), "%s/permissive.keychain", directory);
	snprintf(emptyPath, sizeof(emptyPath), "%s/empty.keychain", directory);
	snprintf(oversizedPath, sizeof(oversizedPath), "%s/oversized.keychain", directory);
	snprintf(parentPath, sizeof(parentPath), "%s/public-parent", directory);
	snprintf(childPath, sizeof(childPath), "%s/public-parent/child.keychain", directory);
	static const char victim[] = "keep this unrelated file";
	checkFlag("make victim file", writeFile(victimPath, victim, sizeof(victim) - 1, 0600));
	checkFlag("make symlink", symlink(victimPath, linkPath) == 0);
	SecKeychainRef rejected = NULL;
	status = SecKeychainOpen(linkPath, &rejected);
	checkStatus("open symlink", status, errSecInvalidKeychain);
	checkFlag("symlink open returned no keychain", rejected == NULL);
	status = SecKeychainCreate(linkPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over symlink", status, errSecInvalidKeychain);
	checkFlag("symlink create returned no keychain", rejected == NULL);
	checkFlag("symlink target stayed untouched", [[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:victimPath]]
	    isEqualToData:[NSData dataWithBytes:victim length:sizeof(victim) - 1]]);

	checkFlag("make FIFO", mkfifo(fifoPath, 0600) == 0);
	status = SecKeychainOpen(fifoPath, &rejected);
	checkStatus("open FIFO without waiting", status, errSecInvalidKeychain);
	checkFlag("FIFO open returned no keychain", rejected == NULL);
	status = SecKeychainCreate(fifoPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over FIFO without waiting", status, errSecInvalidKeychain);
	checkFlag("FIFO create returned no keychain", rejected == NULL);
	checkFlag("FIFO stayed in place", lstat(fifoPath, &directoryInfo) == 0 && S_ISFIFO(directoryInfo.st_mode));

	checkFlag("make hard-link source", writeFile(hardSourcePath, victim, sizeof(victim) - 1, 0600));
	checkFlag("make hard link", link(hardSourcePath, hardPath) == 0);
	rejected = NULL;
	status = SecKeychainOpen(hardPath, &rejected);
	checkStatus("open hard-linked file", status, errSecInvalidKeychain);
	checkFlag("hard-link open returned no keychain", rejected == NULL);
	rejected = NULL;
	status = SecKeychainCreate(hardPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over hard-linked file", status, errSecInvalidKeychain);
	checkFlag("hard-link create returned no keychain", rejected == NULL);
	checkFlag("hard-linked contents stayed untouched", [[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:hardSourcePath]]
	    isEqualToData:[NSData dataWithBytes:victim length:sizeof(victim) - 1]]);

	checkFlag("make permissive file", writeFile(permissivePath, victim, sizeof(victim) - 1, 0600));
	checkFlag("open permissions on fixture", chmod(permissivePath, 0644) == 0);
	status = SecKeychainOpen(permissivePath, &rejected);
	checkStatus("open permissive file", status, errSecInvalidKeychain);
	status = SecKeychainCreate(permissivePath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over permissive file", status, errSecInvalidKeychain);
	checkFlag("permissive file stayed untouched", [[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:permissivePath]]
	    isEqualToData:[NSData dataWithBytes:victim length:sizeof(victim) - 1]]);

	checkFlag("make existing empty file", writeFile(emptyPath, "", 0, 0600));
	status = SecKeychainCreate(emptyPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over empty file", status, errSecInvalidKeychain);
	status = SecKeychainOpen(emptyPath, &rejected);
	checkStatus("open empty file", status, errSecInvalidKeychain);
	NSData *emptyAfter = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:emptyPath]];
	checkFlag("empty file stayed empty", emptyAfter && emptyAfter.length == 0);

	int oversizedFD = open(oversizedPath, O_RDWR | O_CREAT | O_EXCL, 0600);
	BOOL oversizedFixture = oversizedFD >= 0 && fchmod(oversizedFD, 0600) == 0 &&
	    ftruncate(oversizedFD, 64 * 1024 * 1024 + 1) == 0;
	if (oversizedFD >= 0)
		close(oversizedFD);
	checkFlag("make oversized file", oversizedFixture);
	status = SecKeychainOpen(oversizedPath, &rejected);
	checkStatus("open oversized file", status, errSecInvalidKeychain);
	status = SecKeychainCreate(oversizedPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create over oversized file", status, errSecInvalidKeychain);
	struct stat oversizedInfo;
	checkFlag("oversized file stayed in place", stat(oversizedPath, &oversizedInfo) == 0 &&
	    oversizedInfo.st_size == 64 * 1024 * 1024 + 1);

	/* (a folder others may write in; a 0755 one, like Apple's ~/Library/Keychains, is fine) */
	checkFlag("make public parent", mkdir(parentPath, 0755) == 0 && chmod(parentPath, 0777) == 0);
	status = SecKeychainCreate(childPath, 0, NULL, false, NULL, &rejected);
	checkStatus("create under public folder", status, errSecNoAccessForItem);
	checkFlag("public parent got no keychain", access(childPath, F_OK) < 0 && errno == ENOENT);

	/* A successfully deleted keychain gives a stable, private way to check that
	 * failed status calls clear their output word. */
	char deletePath[PATH_MAX];
	snprintf(deletePath, sizeof(deletePath), "%s/delete.keychain", directory);
	SecKeychainRef deleted = NULL;
	status = SecKeychainCreate(deletePath, 0, NULL, false, NULL, &deleted);
	checkStatus("create delete fixture", status, errSecSuccess);
	if (status == errSecSuccess && deleted) {
		status = SecKeychainDelete(deleted);
		checkStatus("delete valid keychain", status, errSecSuccess);
		keychainStatus = (SecKeychainStatus)0x7fffffff;
		status = SecKeychainGetStatus(deleted, &keychainStatus);
		checkStatus("status missing file", status, errSecNoSuchKeychain);
		checkFlag("missing status cleared output", keychainStatus == 0);
	} else {
		checkFlag("create delete fixture returned a keychain", NO);
	}
	if (deleted)
		CFRelease(deleted);

	/* The source hard link shares victimPath; unlink both names before cleanup. */
	unlink(keychainPath);
	unlink(victimPath);
	unlink(linkPath);
	unlink(fifoPath);
	unlink(hardPath);
	unlink(hardSourcePath);
	unlink(permissivePath);
	unlink(emptyPath);
	unlink(oversizedPath);
	unlink(deletePath);
	rmdir(parentPath);
	rmdir(directory);

	printf("failures: %d\n", failures);
	return failures ? 1 : 0;
}

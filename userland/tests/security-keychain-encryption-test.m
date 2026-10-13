/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

extern char **environ;

static const char password[] = "finch-only-encryption-test-password";
static const char wrongPassword[] = "wrong dummy password";
static const char service[] = "org.finch.keychain-encryption-test";
static int failures;
static BOOL quietOutput;

static void
checkStatus(const char *name, OSStatus actual, OSStatus expected)
{
	BOOL ok = actual == expected;
	if (!quietOutput)
		printf("%s: %s\n", name, ok ? "pass" : "FAIL");
	if (!ok)
		failures++;
}

static void
checkFlag(const char *name, BOOL actual)
{
	if (!quietOutput)
		printf("%s: %s\n", name, actual ? "pass" : "FAIL");
	if (!actual)
		failures++;
}

static BOOL
sameCanonicalPath(const char *left, const char *right)
{
	char canonicalLeft[PATH_MAX], canonicalRight[PATH_MAX];
	return left && right && *right && realpath(left, canonicalLeft) &&
	    realpath(right, canonicalRight) && !strcmp(canonicalLeft, canonicalRight);
}

static void
printCasePathDiagnostic(const char *label, const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) {
		fprintf(stderr, "case diagnostic %s: open failed errno=%d path=%s\n",
		    label, errno, path);
		return;
	}
	char actual[PATH_MAX] = {0};
	struct stat info;
	int pathStatus = fcntl(fd, F_GETPATH, actual);
	int pathError = errno;
	int statStatus = fstat(fd, &info);
	if (statStatus == 0)
		fprintf(stderr,
		    "case diagnostic %s: path=%s actual=%s path_status=%d path_errno=%d dev=%llu ino=%llu\n",
		    label, path, pathStatus == 0 ? actual : "<failed>", pathStatus,
		    pathError, (unsigned long long)info.st_dev, (unsigned long long)info.st_ino);
	else
		fprintf(stderr,
		    "case diagnostic %s: path=%s actual=%s path_status=%d path_errno=%d fstat_errno=%d\n",
		    label, path, pathStatus == 0 ? actual : "<failed>", pathStatus,
		    pathError, errno);
	close(fd);
}

static BOOL
markerPresentOrUnknown(const char *path)
{
	struct stat marker;
	if (lstat(path, &marker) == 0)
		return YES;
	return errno != ENOENT && errno != ENOTDIR;
}

/* Keep this in step with the client: when Finch is detected, a missing
 * service must fail closed instead of using this process's local key cache. */
static BOOL
usesKeychainService(void)
{
	return markerPresentOrUnknown(
	    "/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist") ||
	    markerPresentOrUnknown(
	    "/System/Library/Finch/LaunchAgents/org.finch.securityd.plist");
}

static BOOL
hasFinchSecurity(void)
{
	Dl_info info = {0};
	const char *expectedImage = getenv("FINCH_TEST_SECURITY_IMAGE");
	BOOL privateImage = dladdr((const void *)SecKeychainCreate, &info) &&
	    sameCanonicalPath(info.dli_fname, expectedImage);
	return privateImage || access(
	    "/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist", F_OK) == 0;
}

static NSString *
readSecret(SecKeychainRef keychain, NSString *account, OSStatus *status)
{
	if (!keychain) {
		*status = errSecInvalidKeychain;
		return nil;
	}
	NSDictionary *query = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: [NSString stringWithUTF8String:service],
		(id)kSecAttrAccount: account,
		(id)kSecReturnData: @YES,
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	CFTypeRef result = NULL;
	*status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	NSString *value = nil;
	if (!*status && result && CFGetTypeID(result) == CFDataGetTypeID())
		value = [[NSString alloc] initWithData:(__bridge NSData *)result
		    encoding:NSUTF8StringEncoding];
	if (result)
		CFRelease(result);
	return value;
}

static OSStatus
addSecret(SecKeychainRef keychain, NSString *account, NSString *secret)
{
	if (!keychain)
		return errSecInvalidKeychain;
	NSDictionary *item = @{
		(id)kSecClass: (id)kSecClassGenericPassword,
		(id)kSecAttrService: [NSString stringWithUTF8String:service],
		(id)kSecAttrAccount: account,
		(id)kSecValueData: [secret dataUsingEncoding:NSUTF8StringEncoding],
		(id)kSecUseKeychain: (__bridge id)keychain,
	};
	return SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

static int
freshProcessCheck(const char *path, BOOL serviceMode)
{
	if (serviceMode != usesKeychainService())
		return 1;
	SecKeychainRef keychain = NULL;
	OSStatus status = SecKeychainOpen(path, &keychain);
	checkStatus("fresh process opens keychain", status, errSecSuccess);
	checkFlag("fresh open returned a keychain", keychain != NULL);
	if (status || !keychain)
		return 1;

	SecKeychainStatus keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("fresh process reads status", status, errSecSuccess);
	BOOL unlocked = (keychainStatus & kSecUnlockStateStatus) != 0;
	checkFlag(serviceMode ? "fresh service client sees shared unlock" :
	    "fresh process starts locked", unlocked == serviceMode);
	NSString *value = readSecret(keychain, @"sample", &status);
	checkStatus(serviceMode ? "fresh shared read" : "fresh locked read", status,
	    serviceMode ? errSecSuccess : errSecInteractionNotAllowed);
	checkFlag(serviceMode ? "fresh service client reads shared secret" :
	    "fresh locked read returned no secret", serviceMode ?
	    [value isEqualToString:@"first dummy secret"] : value == nil);

	status = SecKeychainUnlock(keychain, sizeof(wrongPassword) - 1, wrongPassword, false);
	checkStatus("wrong password", status, errSecAuthFailed);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status after wrong password", status, errSecSuccess);
	checkFlag(serviceMode ? "wrong password kept shared key unlocked" :
	    "wrong password left keychain locked",
	    ((keychainStatus & kSecUnlockStateStatus) != 0) == serviceMode);

	status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
	checkStatus("correct password", status, errSecSuccess);
	value = readSecret(keychain, @"sample", &status);
	checkStatus("read after unlock", status, errSecSuccess);
	checkFlag("saved dummy secret matches", [value isEqualToString:@"first dummy secret"]);
	status = SecKeychainLock(keychain);
	checkStatus("child lock", status, errSecSuccess);
	keychainStatus = (SecKeychainStatus)0x7fffffff;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status after child lock", status, errSecSuccess);
	checkFlag(serviceMode ? "child lock cleared shared key" :
	    "child lock cleared cached key", (keychainStatus & kSecUnlockStateStatus) == 0);
	CFRelease(keychain);
	return failures ? 1 : 0;
}

static int
writerProcess(const char *path, const char *account)
{
	quietOutput = YES;
	SecKeychainRef keychain = NULL;
	OSStatus status = SecKeychainOpen(path, &keychain);
	checkStatus("writer open", status, errSecSuccess);
	if (status || !keychain)
		return 1;
	status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
	checkStatus("writer unlock", status, errSecSuccess);
	if (!status) {
		NSString *name = [NSString stringWithUTF8String:account];
		NSString *value = [NSString stringWithFormat:@"%@ dummy secret", name];
		status = addSecret(keychain, name, value);
		checkStatus("writer add", status, errSecSuccess);
	}
	CFRelease(keychain);
	return failures ? 1 : 0;
}

static BOOL
spawnTestProcess(const char *executable, const char *mode, const char *path,
	const char *account, pid_t *pidOut)
{
	char *arguments[5] = {(char *)executable, (char *)mode, (char *)path,
	    (char *)account, NULL};
	int error = posix_spawnp(pidOut, executable, NULL, NULL, arguments, environ);
	return error == 0;
}

static BOOL
waitForSuccess(pid_t pid)
{
	int childStatus = 0;
	while (waitpid(pid, &childStatus, 0) < 0) {
		if (errno == EINTR)
			continue;
		return NO;
	}
	return WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0;
}

static BOOL
writeFile(const char *path, const void *bytes, size_t length)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	if (fd < 0)
		return NO;
	BOOL ok = fchmod(fd, 0600) == 0;
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

static BOOL
rewriteFile(const char *path, const void *bytes, size_t length)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return NO;
	struct stat info;
	BOOL ok = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
	    info.st_uid == geteuid() && info.st_nlink == 1 &&
	    (info.st_mode & 07777) == 0600 && ftruncate(fd, 0) == 0;
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
	if (ok && fsync(fd) < 0)
		ok = NO;
	if (close(fd) < 0)
		ok = NO;
	return ok;
}

static int
mainTest(const char *executable, BOOL serviceMode)
{
	char directory[PATH_MAX] = {0};
	char keychainPath[PATH_MAX] = {0}, aliasPath[PATH_MAX] = {0};
	char caseAliasPath[PATH_MAX] = {0};
	char noPasswordPath[PATH_MAX] = {0};
	char plaintextPath[PATH_MAX] = {0}, lockPath[PATH_MAX] = {0};
	int count;
	struct stat info;
	SecKeychainRef missingPassword = NULL, keychain = NULL, aliasKeychain = NULL;
	SecKeychainRef caseAliasKeychain = NULL;
	SecKeychainRef duplicate = NULL, rejected = NULL;
	OSStatus status;
	SecKeychainStatus keychainStatus = 0;
	NSString *value = nil;
	NSData *encryptedFile = nil, *secretBytes = nil;
	NSData *beforeDuplicate = nil, *afterDuplicate = nil;
	NSData *beforeLockedWrite = nil, *afterLockedWrite = nil;
	NSData *originalEncryptedFile = nil, *tamperedOnDisk = nil, *afterTamper = nil;
	NSMutableData *tamperedFile = nil;
	NSData *plaintextBefore = nil, *plaintextAfter = nil;
	pid_t freshPID = -1, leftPID = -1, rightPID = -1;
	BOOL freshSpawned, leftSpawned, rightSpawned;
	static const char plaintext[] = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>items</key><array/></dict></plist>";
	puts("Security source: Finch");
	count = snprintf(directory, sizeof(directory), "/tmp/finch-keychain-encryption.XXXXXX");
	if (count < 0 || (size_t)count >= sizeof(directory) || !mkdtemp(directory)) {
		perror("make private test folder");
		return 1;
	}
	checkFlag("test folder is private", stat(directory, &info) == 0 &&
	    (info.st_mode & 0777) == 0700);

	snprintf(keychainPath, sizeof(keychainPath), "%s/main.keychain", directory);
	snprintf(caseAliasPath, sizeof(caseAliasPath), "%s/MAIN.KEYCHAIN", directory);
	snprintf(noPasswordPath, sizeof(noPasswordPath), "%s/no-password.keychain", directory);
	snprintf(plaintextPath, sizeof(plaintextPath), "%s/plaintext.keychain", directory);
	snprintf(lockPath, sizeof(lockPath), "%s/.finch-keychain.lock", directory);

	status = SecKeychainCreate(noPasswordPath, 0, NULL, false, NULL, &missingPassword);
	checkStatus("create requires a password", status, errSecPassphraseRequired);
	checkFlag("missing password returned no keychain", missingPassword == NULL);
	checkFlag("missing password created no file", access(noPasswordPath, F_OK) < 0 && errno == ENOENT);

	status = SecKeychainCreate(keychainPath, sizeof(password) - 1, password,
	    false, NULL, &keychain);
	checkStatus("create encrypted keychain", status, errSecSuccess);
	checkFlag("create returned a keychain", keychain != NULL);
	if (status || !keychain)
		goto cleanup;

	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status after create", status, errSecSuccess);
	checkFlag("created keychain starts unlocked", (keychainStatus & kSecUnlockStateStatus) != 0);

	status = addSecret(keychain, @"sample", @"first dummy secret");
	checkStatus("add dummy secret", status, errSecSuccess);
	value = readSecret(keychain, @"sample", &status);
	checkStatus("read dummy secret", status, errSecSuccess);
	checkFlag("dummy secret matches", [value isEqualToString:@"first dummy secret"]);

	encryptedFile = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	secretBytes = [@"first dummy secret" dataUsingEncoding:NSUTF8StringEncoding];
	checkFlag("stored file hides the secret", encryptedFile &&
	    [encryptedFile rangeOfData:secretBytes options:0
	        range:NSMakeRange(0, encryptedFile.length)].location == NSNotFound);
	checkFlag("keychain file has private mode", stat(keychainPath, &info) == 0 &&
	    S_ISREG(info.st_mode) && (info.st_mode & 07777) == 0600);
	checkFlag("stable lock file has private mode", stat(lockPath, &info) == 0 &&
	    S_ISREG(info.st_mode) && (info.st_mode & 07777) == 0600);

	beforeDuplicate = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	status = SecKeychainCreate(keychainPath, sizeof(password) - 1, password,
	    false, NULL, &duplicate);
	checkStatus("create existing keychain", status, errSecDuplicateKeychain);
	checkFlag("duplicate create returned no keychain", duplicate == NULL);
	afterDuplicate = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	checkFlag("duplicate create left data unchanged",
	    beforeDuplicate && [beforeDuplicate isEqualToData:afterDuplicate]);
	if (duplicate) {
		CFRelease(duplicate);
		duplicate = NULL;
	}

	status = SecKeychainLock(keychain);
	checkStatus("lock keychain", status, errSecSuccess);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status while locked", status, errSecSuccess);
	checkFlag("lock clears unlocked status", (keychainStatus & kSecUnlockStateStatus) == 0);
	value = readSecret(keychain, @"sample", &status);
	checkStatus("read while locked", status, errSecInteractionNotAllowed);
	checkFlag("locked read returned no secret", value == nil);
	beforeLockedWrite = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	status = addSecret(keychain, @"locked-write", @"must not be saved");
	checkStatus("write while locked", status, errSecInteractionNotAllowed);
	afterLockedWrite = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	checkFlag("locked write left file unchanged",
	    beforeLockedWrite && [beforeLockedWrite isEqualToData:afterLockedWrite]);
	status = SecKeychainUnlock(keychain, sizeof(wrongPassword) - 1, wrongPassword, false);
	checkStatus("wrong password", status, errSecAuthFailed);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status after wrong password", status, errSecSuccess);
	checkFlag("wrong password left keychain locked", (keychainStatus & kSecUnlockStateStatus) == 0);
	status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
	checkStatus("unlock with password", status, errSecSuccess);
	value = readSecret(keychain, @"locked-write", &status);
	checkStatus("locked write was not saved", status, errSecItemNotFound);

	count = snprintf(aliasPath, sizeof(aliasPath), "/private/tmp%s//main.keychain",
	    directory + strlen("/tmp"));
	checkFlag("build keychain path alias", count >= 0 && (size_t)count < sizeof(aliasPath));
	status = SecKeychainOpen(aliasPath, &aliasKeychain);
	checkStatus("open aliased keychain", status, errSecSuccess);
	checkFlag("alias open returned a keychain", aliasKeychain != NULL);
	if (!status && aliasKeychain) {
		status = SecKeychainUnlock(aliasKeychain, sizeof(password) - 1, password, false);
		checkStatus("unlock through alias", status, errSecSuccess);
		status = SecKeychainLock(keychain);
		checkStatus("lock through original path", status, errSecSuccess);
		value = readSecret(aliasKeychain, @"sample", &status);
		checkStatus("alias read after original lock", status, errSecInteractionNotAllowed);
		checkFlag("alias read returned no secret", value == nil);
		status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
		checkStatus("unlock after alias lock check", status, errSecSuccess);
	}

	struct stat originalInfo, caseAliasInfo;
	int originalStat = stat(keychainPath, &originalInfo);
	int caseAliasStat = stat(caseAliasPath, &caseAliasInfo);
	int caseAliasStatError = errno;
	BOOL caseAliasCheck = NO;
	const char *caseAliasStage = "file identity";
	OSStatus caseAliasLastStatus = errSecSuccess;
	BOOL sameCaseFile = originalStat == 0 && caseAliasStat == 0 &&
	    originalInfo.st_dev == caseAliasInfo.st_dev &&
	    originalInfo.st_ino == caseAliasInfo.st_ino;
	if (sameCaseFile) {
		caseAliasStage = "open alias";
		caseAliasLastStatus = SecKeychainOpen(caseAliasPath, &caseAliasKeychain);
		caseAliasCheck = caseAliasLastStatus == errSecSuccess && caseAliasKeychain != NULL;
		if (caseAliasCheck) {
			caseAliasStage = "unlock alias";
			caseAliasLastStatus = SecKeychainUnlock(caseAliasKeychain,
			    sizeof(password) - 1, password, false);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
		if (caseAliasCheck) {
			caseAliasStage = "lock original";
			caseAliasLastStatus = SecKeychainLock(keychain);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
		if (caseAliasCheck) {
			caseAliasStage = "read alias after lock";
			value = readSecret(caseAliasKeychain, @"sample", &caseAliasLastStatus);
			caseAliasCheck = caseAliasLastStatus == errSecInteractionNotAllowed && value == nil;
		}
		if (caseAliasCheck) {
			caseAliasStage = "unlock original again";
			caseAliasLastStatus = SecKeychainUnlock(keychain,
			    sizeof(password) - 1, password, false);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
	} else if (originalStat == 0 && caseAliasStat < 0 && caseAliasStatError == ENOENT) {
		/* On a case-sensitive volume these spellings name separate files.
		 * Create the second one and prove locking the first leaves it unlocked. */
		caseAliasStage = "create separate file";
		caseAliasLastStatus = SecKeychainCreate(caseAliasPath, sizeof(password) - 1, password,
		    false, NULL, &caseAliasKeychain);
		caseAliasCheck = caseAliasLastStatus == errSecSuccess && caseAliasKeychain != NULL;
		if (caseAliasCheck) {
			struct stat afterOriginal, afterAlias;
			caseAliasStage = "confirm separate files";
			caseAliasCheck = stat(keychainPath, &afterOriginal) == 0 &&
			    stat(caseAliasPath, &afterAlias) == 0 &&
			    (afterOriginal.st_dev != afterAlias.st_dev ||
			     afterOriginal.st_ino != afterAlias.st_ino);
		}
		if (caseAliasCheck) {
			caseAliasStage = "write separate file";
			caseAliasLastStatus = addSecret(caseAliasKeychain, @"case-only", @"separate dummy secret");
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
		if (caseAliasCheck) {
			caseAliasStage = "lock original";
			caseAliasLastStatus = SecKeychainLock(keychain);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
		if (caseAliasCheck) {
			caseAliasStage = "read separate file after lock";
			value = readSecret(caseAliasKeychain, @"case-only", &caseAliasLastStatus);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess &&
			    [value isEqualToString:@"separate dummy secret"];
		}
		if (caseAliasCheck) {
			caseAliasStage = "unlock original again";
			caseAliasLastStatus = SecKeychainUnlock(keychain,
			    sizeof(password) - 1, password, false);
			caseAliasCheck = caseAliasLastStatus == errSecSuccess;
		}
	} else {
		caseAliasCheck = NO;
	}
	if (!caseAliasCheck) {
		fprintf(stderr,
		    "case diagnostic: stage=%s status=%d original_stat=%d alias_stat=%d alias_errno=%d same_inode=%d\n",
		    caseAliasStage, (int)caseAliasLastStatus, originalStat, caseAliasStat,
		    caseAliasStatError, sameCaseFile);
		printCasePathDiagnostic("original", keychainPath);
		printCasePathDiagnostic("case alias", caseAliasPath);
	}
	checkFlag("case-spelling cache lock stays safe", caseAliasCheck);

	status = SecKeychainLockAll();
	checkStatus("lock all keychains", status, errSecSuccess);
	keychainStatus = 0;
	status = SecKeychainGetStatus(keychain, &keychainStatus);
	checkStatus("status after lock all", status, errSecSuccess);
	checkFlag("lock all cleared unlocked status", (keychainStatus & kSecUnlockStateStatus) == 0);
	value = readSecret(keychain, @"sample", &status);
	checkStatus("read after lock all", status, errSecInteractionNotAllowed);
	checkFlag("lock all read returned no secret", value == nil);
	status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
	checkStatus("unlock after lock all", status, errSecSuccess);

	fflush(stdout);
	freshSpawned = spawnTestProcess(executable,
	    serviceMode ? "--fresh-service" : "--fresh-local", keychainPath, NULL, &freshPID);
	checkFlag("start fresh process", freshSpawned);
	if (freshSpawned)
		checkFlag("fresh process checks passed", waitForSuccess(freshPID));

	leftSpawned = spawnTestProcess(executable, "--writer", keychainPath,
	    "parallel-left", &leftPID);
	rightSpawned = spawnTestProcess(executable, "--writer", keychainPath,
	    "parallel-right", &rightPID);
	checkFlag("start first concurrent writer", leftSpawned);
	checkFlag("start second concurrent writer", rightSpawned);
	if (leftSpawned)
		checkFlag("first concurrent writer completed", waitForSuccess(leftPID));
	if (rightSpawned)
		checkFlag("second concurrent writer completed", waitForSuccess(rightPID));
	value = readSecret(keychain, @"parallel-left", &status);
	checkStatus("read first concurrent write", status, errSecSuccess);
	checkFlag("first concurrent write survived", [value isEqualToString:@"parallel-left dummy secret"]);
	value = readSecret(keychain, @"parallel-right", &status);
	checkStatus("read second concurrent write", status, errSecSuccess);
	checkFlag("second concurrent write survived", [value isEqualToString:@"parallel-right dummy secret"]);

	originalEncryptedFile = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:keychainPath]];
	checkFlag("save encrypted file for tamper check",
	    originalEncryptedFile && originalEncryptedFile.length > 0);
	if (originalEncryptedFile && originalEncryptedFile.length > 0) {
		tamperedFile = [originalEncryptedFile mutableCopy];
		((unsigned char *)tamperedFile.mutableBytes)[tamperedFile.length - 1] ^= 1;
		checkFlag("write tampered encrypted fixture",
		    rewriteFile(keychainPath, tamperedFile.bytes, tamperedFile.length));
		tamperedOnDisk = [NSData dataWithContentsOfFile:
		    [NSString stringWithUTF8String:keychainPath]];
		checkFlag("tampered fixture is on disk",
		    tamperedOnDisk && [tamperedOnDisk isEqualToData:tamperedFile]);
		value = readSecret(keychain, @"sample", &status);
		checkStatus("tampered encrypted file read", status, errSecAuthFailed);
		checkFlag("tampered read returned no secret", value == nil);
		afterTamper = [NSData dataWithContentsOfFile:
		    [NSString stringWithUTF8String:keychainPath]];
		checkFlag("tampered read left file unchanged",
		    tamperedOnDisk && [tamperedOnDisk isEqualToData:afterTamper]);
		status = SecKeychainUnlock(keychain, sizeof(password) - 1, password, false);
		checkStatus("tampered encrypted file unlock", status, errSecAuthFailed);
		afterTamper = [NSData dataWithContentsOfFile:
		    [NSString stringWithUTF8String:keychainPath]];
		checkFlag("tampered unlock left file unchanged",
		    tamperedOnDisk && [tamperedOnDisk isEqualToData:afterTamper]);
		checkFlag("restore intact encrypted fixture",
		    rewriteFile(keychainPath, originalEncryptedFile.bytes, originalEncryptedFile.length));
		value = readSecret(keychain, @"sample", &status);
		checkStatus("read after restoring encrypted file", status, errSecSuccess);
		checkFlag("restored encrypted secret matches",
		    [value isEqualToString:@"first dummy secret"]);
	}

	checkFlag("make plaintext fixture", writeFile(plaintextPath, plaintext, sizeof(plaintext) - 1));
	plaintextBefore = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:plaintextPath]];
	status = SecKeychainOpen(plaintextPath, &rejected);
	checkStatus("open plaintext keychain", status, errSecInvalidKeychain);
	checkFlag("plaintext open returned no keychain", rejected == NULL);
	status = SecKeychainCreate(plaintextPath, sizeof(password) - 1, password,
	    false, NULL, &rejected);
	checkStatus("create over plaintext file", status, errSecInvalidKeychain);
	checkFlag("plaintext create returned no keychain", rejected == NULL);
	plaintextAfter = [NSData dataWithContentsOfFile:
	    [NSString stringWithUTF8String:plaintextPath]];
	checkFlag("plaintext file stayed unchanged",
	    plaintextBefore && [plaintextBefore isEqualToData:plaintextAfter]);
	if (rejected) {
		CFRelease(rejected);
		rejected = NULL;
	}

	checkFlag("change test folder permissions", chmod(directory, 0777) == 0);
	checkStatus("lock with changed folder", SecKeychainLock(keychain), errSecSuccess);
	checkFlag("restore test folder permissions", chmod(directory, 0700) == 0);
	value = readSecret(keychain, @"sample", &status);
	checkStatus("changed-folder lock cleared cached key", status, errSecInteractionNotAllowed);
	checkFlag("changed-folder lock returned no secret", value == nil);

	status = SecKeychainLock(keychain);
	checkStatus("lock before delete", status, errSecSuccess);
	status = SecKeychainDelete(keychain);
	checkStatus("delete locked keychain", status, errSecSuccess);

cleanup:
	if (keychain)
		CFRelease(keychain);
	if (aliasKeychain)
		CFRelease(aliasKeychain);
	if (caseAliasKeychain)
		CFRelease(caseAliasKeychain);
	if (duplicate)
		CFRelease(duplicate);
	if (rejected)
		CFRelease(rejected);
	unlink(keychainPath);
	unlink(caseAliasPath);
	unlink(noPasswordPath);
	unlink(plaintextPath);
	unlink(lockPath);
	rmdir(directory);
	printf("failures: %d\n", failures);
	return failures ? 1 : 0;
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	/* This guard runs before any Security API call, including in child modes. */
	if (!hasFinchSecurity()) {
		fprintf(stderr, "This test only runs inside Finch.\n");
		return 77;
	}
	if (argc == 3 && (!strcmp(argv[1], "--fresh-local") ||
	    !strcmp(argv[1], "--fresh-service"))) {
		quietOutput = YES;
		BOOL serviceMode = !strcmp(argv[1], "--fresh-service");
		return freshProcessCheck(argv[2], serviceMode);
	}
	if (argc == 4 && !strcmp(argv[1], "--writer"))
		return writerProcess(argv[2], argv[3]);
	return mainTest(argv[0], usesKeychainService());
}

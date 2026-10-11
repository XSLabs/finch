/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Exercise configd's real network-apply path inside the disposable Finch VM.
 * The configured service points at a chrooted configd. Its preference file
 * and resolver output live under configd-service-root; this test also checks
 * that the guest's normal resolver and preferences files stay unchanged.
 */
#include <SystemConfiguration/SystemConfiguration.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sockio.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define PRIVATE_ROOT "/private/var/rw/configd-service-root"
#define FINCH_CONFIGD_LAUNCHD_PATH \
	"/System/Library/Finch/LaunchDaemons/com.apple.SystemConfiguration.configd.plist"
#define CONTAINED_CONFIGD_PATH "/usr/local/bin/finch-configd-contained-service"
#define CONFIGD_LABEL "system/com.apple.SystemConfiguration.configd"
#define TEST_ADDRESS "127.0.0.42"
#define TEST_MASK "255.0.0.0"
#define TEST_DNS "192.0.2.53"
#define TEST_SEARCH "finch-configd-test.invalid"
#define EXPECTED_RESOLVER \
	"nameserver " TEST_DNS "\nsearch " TEST_SEARCH "\n"

typedef struct {
	bool exists;
	bool isSymlink;
	mode_t mode;
	uid_t uid;
	gid_t gid;
	char linkText[PATH_MAX];
	bool targetExists;
	char targetPath[PATH_MAX];
	mode_t targetMode;
	uid_t targetUID;
	gid_t targetGID;
	unsigned char *contents;
	size_t length;
} FileSnapshot;

static int failures;

static void
check(bool ok, const char *message)
{
	if (!ok) {
		fprintf(stderr, "configd-network: FAIL: %s\n", message);
		failures++;
	}
}

static bool
sameString(const char *a, const char *b)
{
	return strcmp(a, b) == 0;
}

static bool
captureRegularFile(const char *path, FileSnapshot *snapshot)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return errno == ENOENT;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
	    st.st_size > 1024 * 1024) {
		close(fd);
		return false;
	}
	snapshot->targetExists = true;
	if (strlcpy(snapshot->targetPath, path, sizeof(snapshot->targetPath)) >=
	    sizeof(snapshot->targetPath)) {
		close(fd);
		return false;
	}
	snapshot->targetMode = st.st_mode;
	snapshot->targetUID = st.st_uid;
	snapshot->targetGID = st.st_gid;
	snapshot->length = (size_t)st.st_size;
	snapshot->contents = malloc(snapshot->length ? snapshot->length : 1);
	if (snapshot->contents == NULL) {
		close(fd);
		return false;
	}
	size_t offset = 0;
	while (offset < snapshot->length) {
		ssize_t n = read(fd, snapshot->contents + offset, snapshot->length - offset);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			return false;
		}
		offset += (size_t)n;
	}
	unsigned char extra;
	ssize_t n;
	do {
		n = read(fd, &extra, 1);
	} while (n < 0 && errno == EINTR);
	close(fd);
	return n == 0;
}

static bool
captureSnapshot(const char *path, FileSnapshot *snapshot)
{
	memset(snapshot, 0, sizeof(*snapshot));
	struct stat st;
	if (lstat(path, &st) < 0)
		return errno == ENOENT;
	snapshot->exists = true;
	snapshot->mode = st.st_mode;
	snapshot->uid = st.st_uid;
	snapshot->gid = st.st_gid;
	if (S_ISLNK(st.st_mode)) {
		snapshot->isSymlink = true;
		ssize_t n = readlink(path, snapshot->linkText, sizeof(snapshot->linkText) - 1);
		if (n < 0 || (size_t)n >= sizeof(snapshot->linkText) - 1)
			return false;
		snapshot->linkText[n] = '\0';
		char resolved[PATH_MAX];
		if (realpath(path, resolved) == NULL)
			return errno == ENOENT;
		return captureRegularFile(resolved, snapshot);
	}
	if (S_ISREG(st.st_mode))
		return captureRegularFile(path, snapshot);
	return true;
}

static void
freeSnapshot(FileSnapshot *snapshot)
{
	free(snapshot->contents);
	memset(snapshot, 0, sizeof(*snapshot));
}

static bool
sameSnapshot(const FileSnapshot *a, const FileSnapshot *b)
{
	if (a->exists != b->exists || a->isSymlink != b->isSymlink ||
	    a->mode != b->mode || a->uid != b->uid || a->gid != b->gid ||
	    !sameString(a->linkText, b->linkText) ||
	    a->targetExists != b->targetExists ||
	    !sameString(a->targetPath, b->targetPath) ||
	    a->targetMode != b->targetMode || a->targetUID != b->targetUID ||
	    a->targetGID != b->targetGID || a->length != b->length)
		return false;
	return a->length == 0 || memcmp(a->contents, b->contents, a->length) == 0;
}

static bool
snapshotUnchanged(const char *path, const FileSnapshot *before)
{
	FileSnapshot after;
	bool captured = captureSnapshot(path, &after);
	bool same = captured && sameSnapshot(before, &after);
	freeSnapshot(&after);
	return same;
}

static int
openDirectoryAt(int parent, const char *name)
{
	int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
	    (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static bool
isPrivateRegularFile(int directory, const char *name)
{
	struct stat st;
	return fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
	    S_ISREG(st.st_mode) && st.st_uid == 0 && st.st_nlink == 1 &&
	    (st.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static int
openPrivateDirectory(const char *relativePath)
{
	char copy[PATH_MAX];
	if (strlcpy(copy, relativePath, sizeof(copy)) >= sizeof(copy) ||
	    copy[0] == '/' || copy[0] == '\0')
		return -1;
	int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	char *component = copy;
	for (;;) {
		char *slash = strchr(component, '/');
		if (slash)
			*slash = '\0';
		if (*component == '\0' || sameString(component, ".") ||
		    sameString(component, "..")) {
			close(fd);
			return -1;
		}
		int next = openDirectoryAt(fd, component);
		close(fd);
		if (next < 0)
			return -1;
		fd = next;
		if (slash == NULL)
			return fd;
		component = slash + 1;
	}
}

static bool
readLaunchctlPrint(char *output, size_t capacity)
{
	int fds[2];
	if (pipe(fds) != 0)
		return false;
	posix_spawn_file_actions_t actions;
	if (posix_spawn_file_actions_init(&actions) != 0) {
		close(fds[0]);
		close(fds[1]);
		return false;
	}
	int err = posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
	if (err == 0)
		err = posix_spawn_file_actions_addclose(&actions, fds[0]);
	if (err == 0)
		err = posix_spawn_file_actions_addclose(&actions, fds[1]);
	char *arguments[] = {(char *)"/bin/launchctl", (char *)"print",
	    (char *)CONFIGD_LABEL, NULL};
	pid_t child = 0;
	if (err == 0)
		err = posix_spawn(&child, arguments[0], &actions, NULL, arguments, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(fds[1]);
	if (err != 0) {
		close(fds[0]);
		return false;
	}
	size_t used = 0;
	char buffer[1024];
	for (;;) {
		ssize_t n = read(fds[0], buffer, sizeof(buffer));
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0) {
			close(fds[0]);
			(void)waitpid(child, NULL, 0);
			return false;
		}
		if (n == 0)
			break;
		size_t room = capacity > used + 1 ? capacity - used - 1 : 0;
		size_t copy = (size_t)n < room ? (size_t)n : room;
		if (copy) {
			memcpy(output + used, buffer, copy);
			used += copy;
		}
	}
	close(fds[0]);
	output[used] = '\0';
	int status = 0;
	pid_t waited;
	do {
		waited = waitpid(child, &status, 0);
	} while (waited < 0 && errno == EINTR);
	return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static bool
finchVMWithContainedConfigd(void)
{
	if (access("/etc/finch/rc", R_OK) != 0 ||
	    access(FINCH_CONFIGD_LAUNCHD_PATH, R_OK) != 0 ||
	    access(CONTAINED_CONFIGD_PATH, X_OK) != 0)
		return false;
	char output[32768];
	return readLaunchctlPrint(output, sizeof(output)) &&
	    strstr(output, CONTAINED_CONFIGD_PATH) != NULL;
}

static bool
aliasPresent(void)
{
	struct ifaddrs *all = NULL;
	if (getifaddrs(&all) != 0)
		return true;
	struct in_addr expected;
	if (inet_pton(AF_INET, TEST_ADDRESS, &expected) != 1) {
		freeifaddrs(all);
		return true;
	}
	bool present = false;
	for (struct ifaddrs *entry = all; entry; entry = entry->ifa_next) {
		if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
		    !sameString(entry->ifa_name, "lo0"))
			continue;
		struct sockaddr_in *address = (struct sockaddr_in *)entry->ifa_addr;
		if (address->sin_addr.s_addr == expected.s_addr) {
			present = true;
			break;
		}
	}
	freeifaddrs(all);
	return present;
}

static bool
aliasHasExpectedMask(void)
{
	struct ifaddrs *all = NULL;
	if (getifaddrs(&all) != 0)
		return false;
	struct in_addr expected, mask;
	bool found = false;
	if (inet_pton(AF_INET, TEST_ADDRESS, &expected) != 1 ||
	    inet_pton(AF_INET, TEST_MASK, &mask) != 1) {
		freeifaddrs(all);
		return false;
	}
	for (struct ifaddrs *entry = all; entry; entry = entry->ifa_next) {
		if (!entry->ifa_addr || !entry->ifa_netmask ||
		    entry->ifa_addr->sa_family != AF_INET ||
		    entry->ifa_netmask->sa_family != AF_INET ||
		    !sameString(entry->ifa_name, "lo0"))
			continue;
		struct sockaddr_in *address = (struct sockaddr_in *)entry->ifa_addr;
		struct sockaddr_in *netmask = (struct sockaddr_in *)entry->ifa_netmask;
		if (address->sin_addr.s_addr == expected.s_addr &&
		    netmask->sin_addr.s_addr == mask.s_addr) {
			found = true;
			break;
		}
	}
	freeifaddrs(all);
	return found;
}

static bool
removeAlias(void)
{
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return false;
	struct ifreq request;
	memset(&request, 0, sizeof(request));
	strlcpy(request.ifr_name, "lo0", sizeof(request.ifr_name));
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	if (inet_pton(AF_INET, TEST_ADDRESS, &address.sin_addr) != 1) {
		close(fd);
		return false;
	}
	memcpy(&request.ifr_addr, &address, sizeof(address));
	int result = ioctl(fd, SIOCDIFADDR, &request);
	int saved = errno;
	close(fd);
	if (result < 0 && saved != EADDRNOTAVAIL && saved != ENXIO)
		return false;
	return !aliasPresent();
}

static CFMutableDictionaryRef
newDictionary(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
}

static CFMutableArrayRef
newArray(void)
{
	return CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
}

static CFStringRef
newUUIDString(void)
{
	CFUUIDRef uuid = CFUUIDCreate(NULL);
	if (uuid == NULL)
		return NULL;
	CFStringRef text = CFUUIDCreateString(NULL, uuid);
	CFRelease(uuid);
	return text;
}

static bool
makePreferences(CFStringRef setID, CFStringRef serviceID,
    CFStringRef *currentSetOut, CFMutableDictionaryRef *setsOut,
    CFMutableDictionaryRef *servicesOut)
{
	CFMutableDictionaryRef services = newDictionary();
	CFMutableDictionaryRef service = newDictionary();
	CFMutableDictionaryRef interface = newDictionary();
	CFMutableDictionaryRef ipv4 = newDictionary();
	CFMutableArrayRef addresses = newArray();
	CFMutableArrayRef masks = newArray();
	CFMutableDictionaryRef dns = newDictionary();
	CFMutableArrayRef servers = newArray();
	CFMutableArrayRef searches = newArray();
	CFMutableDictionaryRef sets = newDictionary();
	CFMutableDictionaryRef set = newDictionary();
	CFMutableDictionaryRef network = newDictionary();
	CFMutableDictionaryRef global = newDictionary();
	CFMutableDictionaryRef globalIPv4 = newDictionary();
	CFMutableArrayRef order = newArray();
	CFStringRef currentSet = CFStringCreateWithFormat(NULL, NULL,
	    CFSTR("/Sets/%@"), setID);
	bool ok = services && service && interface && ipv4 && addresses && masks &&
	    dns && servers && searches && sets && set && network && global &&
	    globalIPv4 && order && currentSet;
	if (ok) {
		CFDictionarySetValue(interface, CFSTR("DeviceName"), CFSTR("lo0"));
		CFDictionarySetValue(ipv4, CFSTR("ConfigMethod"), CFSTR("Manual"));
		CFArrayAppendValue(addresses, CFSTR(TEST_ADDRESS));
		CFArrayAppendValue(masks, CFSTR(TEST_MASK));
		CFDictionarySetValue(ipv4, CFSTR("Addresses"), addresses);
		CFDictionarySetValue(ipv4, CFSTR("SubnetMasks"), masks);
		CFArrayAppendValue(servers, CFSTR(TEST_DNS));
		CFArrayAppendValue(searches, CFSTR(TEST_SEARCH));
		CFDictionarySetValue(dns, CFSTR("ServerAddresses"), servers);
		CFDictionarySetValue(dns, CFSTR("SearchDomains"), searches);
		CFDictionarySetValue(service, CFSTR("Interface"), interface);
		CFDictionarySetValue(service, CFSTR("IPv4"), ipv4);
		CFDictionarySetValue(service, CFSTR("DNS"), dns);
		CFDictionarySetValue(services, serviceID, service);
		CFArrayAppendValue(order, serviceID);
		CFDictionarySetValue(globalIPv4, CFSTR("ServiceOrder"), order);
		CFDictionarySetValue(global, CFSTR("IPv4"), globalIPv4);
		CFDictionarySetValue(network, CFSTR("Global"), global);
		CFDictionarySetValue(set, CFSTR("Network"), network);
		CFDictionarySetValue(sets, setID, set);
		*currentSetOut = currentSet;
		*setsOut = sets;
		*servicesOut = services;
		currentSet = NULL;
		sets = NULL;
		services = NULL;
	}
	CFTypeRef values[] = {services, service, interface, ipv4, addresses, masks,
	    dns, servers, searches, sets, set, network, global, globalIPv4,
	    order, currentSet};
	for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++)
		if (values[i])
			CFRelease(values[i]);
	return ok;
}

static bool
resolverMatches(int etcFD)
{
	int fd = openat(etcFD, "resolv.conf", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return false;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
	    (st.st_mode & 0777) != 0644 || st.st_size != (off_t)(sizeof(EXPECTED_RESOLVER) - 1)) {
		close(fd);
		return false;
	}
	char contents[sizeof(EXPECTED_RESOLVER)];
	size_t used = 0;
	while (used < sizeof(EXPECTED_RESOLVER) - 1) {
		ssize_t n = read(fd, contents + used, sizeof(EXPECTED_RESOLVER) - 1 - used);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			return false;
		}
		used += (size_t)n;
	}
	close(fd);
	return memcmp(contents, EXPECTED_RESOLVER, sizeof(EXPECTED_RESOLVER) - 1) == 0;
}

static bool
removeOwnedFileAt(int directory, const char *name, const struct stat *expected)
{
	struct stat current;
	if (fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) < 0)
		return errno == ENOENT;
	if (!S_ISREG(current.st_mode) || current.st_uid != 0 || current.st_nlink != 1 ||
	    (expected && (current.st_dev != expected->st_dev || current.st_ino != expected->st_ino)))
		return false;
	return unlinkat(directory, name, 0) == 0;
}

static bool
removeConfigdTemps(int directory, const char *prefix)
{
	int copy = dup(directory);
	if (copy < 0)
		return false;
	DIR *entries = fdopendir(copy);
	if (entries == NULL) {
		close(copy);
		return false;
	}
	bool ok = true;
	struct dirent *entry;
	while ((entry = readdir(entries)) != NULL) {
		if (strncmp(entry->d_name, prefix, strlen(prefix)) != 0)
			continue;
		if (!removeOwnedFileAt(directory, entry->d_name, NULL))
			ok = false;
	}
	closedir(entries);
	return ok;
}

static bool
readHostname(char hostname[256])
{
	if (gethostname(hostname, 255) != 0) {
		perror("configd-network: gethostname");
		return false;
	}
	hostname[255] = '\0';
	return true;
}

int
main(void)
{
	check(finchVMWithContainedConfigd(),
	    "run only in Finch with the contained configd service active");
	check(getuid() == 0 && geteuid() == 0,
	    "run as root inside the Finch test VM");
	if (failures)
		return 1;

	int rootFD = openPrivateDirectory("private/var/rw/configd-service-root");
	check(rootFD >= 0, "open the prepared, root-owned configd test folder");
	if (rootFD < 0)
		return 1;
	int libraryFD = openDirectoryAt(rootFD, "Library");
	int preferencesFD = libraryFD >= 0 ? openDirectoryAt(libraryFD, "Preferences") : -1;
	int systemConfigurationFD = preferencesFD >= 0 ?
	    openDirectoryAt(preferencesFD, "SystemConfiguration") : -1;
	int etcFD = openDirectoryAt(rootFD, "etc");
	check(libraryFD >= 0 && preferencesFD >= 0 && systemConfigurationFD >= 0 && etcFD >= 0,
	    "use only the prepared preference and etc folders");
	if (libraryFD < 0 || preferencesFD < 0 || systemConfigurationFD < 0 || etcFD < 0)
		goto early_cleanup;
	check(isPrivateRegularFile(etcFD, "passwd") && isPrivateRegularFile(etcFD, "group"),
	    "use the account files prepared for the contained configd");
	struct stat resolverBefore;
	if (fstatat(etcFD, "resolv.conf", &resolverBefore, AT_SYMLINK_NOFOLLOW) == 0) {
		check(false, "refuse because the private resolver file already exists");
		goto early_cleanup;
	}
	if (errno != ENOENT) {
		check(false, "check the private resolver file safely");
		goto early_cleanup;
	}
	check(if_nametoindex("lo0") != 0, "find the guest loopback interface");
	check(!aliasPresent(), "the test loopback alias is absent before the apply");
	if (failures)
		goto early_cleanup;

	char hostnameBefore[256], hostnameAfter[256];
	check(readHostname(hostnameBefore), "read the guest hostname before the test");
	if (failures)
		goto early_cleanup;
	CFStringRef setID = newUUIDString();
	CFStringRef serviceID = newUUIDString();
	CFStringRef uuid = newUUIDString();
	CFStringRef prefID = NULL;
	CFStringRef currentSet = NULL;
	CFMutableDictionaryRef sets = NULL, services = NULL;
	SCPreferencesRef prefs = NULL;
	bool locked = false, applyAttempted = false, preferenceMayExist = false;
	char preferenceName[128] = "";
	char preferencePath[PATH_MAX] = "";
	char outsideLockPath[PATH_MAX] = "";
	struct stat resolverCreated = {0};
	bool resolverOwned = false;
	FileSnapshot outsideBefore[4] = {{0}};
	const char *outsidePaths[4] = {"/etc/resolv.conf",
	    "/Library/Preferences/SystemConfiguration/preferences.plist",
	    NULL, NULL};
	bool snapshotsReady = false;
	if (!setID || !serviceID || !uuid ||
	    !(prefID = CFStringCreateWithFormat(NULL, NULL,
	        CFSTR("finch-configd-network-%@.plist"), uuid)) ||
	    !CFStringGetCString(prefID, preferenceName, sizeof(preferenceName),
	        kCFStringEncodingUTF8)) {
		check(false, "make unique preference file names");
		goto cleanup;
	}
	if (snprintf(preferencePath, sizeof(preferencePath),
	    "/Library/Preferences/SystemConfiguration/%s", preferenceName) >=
	    (int)sizeof(preferencePath) ||
	    snprintf(outsideLockPath, sizeof(outsideLockPath), "%s.lock", preferencePath) >=
	    (int)sizeof(outsideLockPath)) {
		check(false, "make safe preference file paths");
		goto cleanup;
	}
	outsidePaths[2] = preferencePath;
	outsidePaths[3] = outsideLockPath;
	for (size_t i = 0; i < 4; i++) {
		if (!captureSnapshot(outsidePaths[i], &outsideBefore[i])) {
			check(false, "snapshot guest files outside the private test folder");
			goto cleanup;
		}
	}
	snapshotsReady = true;
	struct stat privatePreference;
	if (fstatat(systemConfigurationFD, preferenceName, &privatePreference,
	    AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
		check(false, "the unique private preference file must not already exist");
		goto cleanup;
	}

	if (!makePreferences(setID, serviceID, &currentSet, &sets, &services)) {
		check(false, "build the single-service Manual IPv4 and DNS settings");
		goto cleanup;
	}
	prefs = SCPreferencesCreate(NULL,
	    CFSTR("Finch configd real network apply test"), prefID);
	if (!prefs) {
		check(false, "open the unique SCPreferences file through configd");
		goto cleanup;
	}
	preferenceMayExist = true;
	if (!SCPreferencesLock(prefs, true)) {
		fprintf(stderr, "configd-network: SCPreferencesLock failed (%d)\n", SCError());
		check(false, "lock the unique SCPreferences file");
		goto cleanup;
	}
	locked = true;
	bool set = SCPreferencesSetValue(prefs, CFSTR("CurrentSet"), currentSet) &&
	    SCPreferencesSetValue(prefs, CFSTR("Sets"), sets) &&
	    SCPreferencesSetValue(prefs, CFSTR("NetworkServices"), services);
	check(set, "stage only the test set, loopback address, and DNS values");
	if (!set)
		goto cleanup;
	check(SCPreferencesCommitChanges(prefs), "save the unique network preferences");
	if (failures)
		goto cleanup;
	bool unlocked = SCPreferencesUnlock(prefs);
	check(unlocked, "unlock the network preferences after saving");
	locked = !unlocked;
	if (failures)
		goto cleanup;
	applyAttempted = true;
	check(SCPreferencesApplyChanges(prefs), "ask configd to apply the saved network settings");
	check(aliasPresent(), "configd added the loopback IPv4 alias");
	check(aliasHasExpectedMask(), "the guest reports the exact loopback alias and /8 mask");
	check(resolverMatches(etcFD), "the private resolver file has the exact DNS and search lines");
	if (!failures) {
		check(SCPreferencesApplyChanges(prefs), "apply the same settings with the alias already present");
		check(aliasHasExpectedMask(), "the repeated apply preserves the existing alias and mask");
		check(resolverMatches(etcFD), "the repeated apply preserves the expected resolver contents");
	}
	if (fstatat(etcFD, "resolv.conf", &resolverCreated, AT_SYMLINK_NOFOLLOW) == 0)
		resolverOwned = S_ISREG(resolverCreated.st_mode) && resolverCreated.st_uid == 0 &&
		    resolverCreated.st_nlink == 1;
	check(resolverOwned, "configd created one regular root-owned private resolver file");

	SCPreferencesSynchronize(prefs);
	CFTypeRef readCurrentSet = SCPreferencesGetValue(prefs, CFSTR("CurrentSet"));
	CFTypeRef readSets = SCPreferencesGetValue(prefs, CFSTR("Sets"));
	CFTypeRef readServices = SCPreferencesGetValue(prefs, CFSTR("NetworkServices"));
	check(readCurrentSet && CFEqual(readCurrentSet, currentSet) && readSets &&
	    CFEqual(readSets, sets) && readServices && CFEqual(readServices, services),
	    "read the committed network settings back through SCPreferences");
	check(readHostname(hostnameAfter) && sameString(hostnameBefore, hostnameAfter),
	    "the guest hostname is unchanged");

cleanup:
	if (applyAttempted && aliasPresent())
		check(removeAlias(), "remove the test loopback alias with SIOCDIFADDR");
	else if (applyAttempted)
		check(!aliasPresent(), "the test loopback alias is absent after apply");
	if (locked && prefs)
		check(SCPreferencesUnlock(prefs), "release the preference lock");
	if (prefs)
		CFRelease(prefs);
	if (systemConfigurationFD >= 0 && preferenceMayExist && preferenceName[0]) {
		char tempPrefix[NAME_MAX + 1];
		if (snprintf(tempPrefix, sizeof(tempPrefix), ".%s.configd.", preferenceName) <
		    (int)sizeof(tempPrefix))
			check(removeConfigdTemps(systemConfigurationFD, tempPrefix),
			    "remove leftover unique preference temp files");
		if (preferencePath[0]) {
			char lockName[NAME_MAX + 1];
			if (snprintf(lockName, sizeof(lockName), "%s.lock", preferenceName) <
			    (int)sizeof(lockName))
				check(removeOwnedFileAt(systemConfigurationFD, lockName, NULL),
				    "remove the unique preference lock file");
			check(removeOwnedFileAt(systemConfigurationFD, preferenceName, NULL),
			    "remove the unique preference file");
		}
	}
	if (etcFD >= 0 && applyAttempted) {
		if (resolverOwned)
			check(removeOwnedFileAt(etcFD, "resolv.conf", &resolverCreated),
			    "remove the resolver file made for this test");
		else {
			struct stat current;
			if (fstatat(etcFD, "resolv.conf", &current, AT_SYMLINK_NOFOLLOW) == 0)
				check(false, "leave an unexpected resolver file untouched");
			else if (errno != ENOENT)
				check(false, "check the private resolver cleanup safely");
		}
	}
	if (snapshotsReady) {
		for (size_t i = 0; i < 4; i++) {
			if (!snapshotUnchanged(outsidePaths[i], &outsideBefore[i]))
				check(false, "a guest file outside the private test folder changed");
			freeSnapshot(&outsideBefore[i]);
		}
	}
	if (applyAttempted)
		check(readHostname(hostnameAfter) && sameString(hostnameBefore, hostnameAfter),
		    "the guest hostname is unchanged after cleanup");
	if (currentSet) CFRelease(currentSet);
	if (sets) CFRelease(sets);
	if (services) CFRelease(services);
	if (setID) CFRelease(setID);
	if (serviceID) CFRelease(serviceID);
	if (uuid) CFRelease(uuid);
	if (prefID) CFRelease(prefID);
	if (!snapshotsReady)
		for (size_t i = 0; i < 4; i++)
			freeSnapshot(&outsideBefore[i]);
early_cleanup:
	if (etcFD >= 0) close(etcFD);
	if (systemConfigurationFD >= 0) close(systemConfigurationFD);
	if (preferencesFD >= 0) close(preferencesFD);
	if (libraryFD >= 0) close(libraryFD);
	close(rootFD);
	if (failures)
		return 1;
	puts("configd-network: PASS (guest loopback alias and private resolver apply)");
	return 0;
}

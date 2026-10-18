/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-update: Finch's signed updates. An update is an install payload (a gzipped tar,
 * tools/release/mkrootfs.py) and its signature: ECDSA P-256 over the archive's SHA-256, made
 * with the release key (tools/release/sign-update.sh) and checked against the public key the
 * system carries, with Finch's Security.
 *
 *   finch-update verify ARCHIVE [SIGNATURE]
 *   finch-update install ARCHIVE [SIGNATURE] --root DIR
 *   finch-update rollback --root DIR
 *   finch-update fetch URL DIR
 *
 * SIGNATURE is ARCHIVE.sig unless given. The public key is /usr/share/finch/update-key.der
 * (the curve point, X9.63), or the file FINCH_UPDATE_KEY names. install checks the signature,
 * unpacks the archive into DIR.finch-new beside DIR (one an interrupted install left is
 * cleared first), copies the user's files and settings over from DIR (preserved[]), then
 * swaps it in by renaming: DIR becomes DIR.finch-old and the new tree DIR. A per-root lock
 * prevents overlapping installs and rollbacks; sibling names let a later run recover if a
 * process stops during the rename sequence. rollback copies current user files into
 * DIR.finch-old before swapping it back.
 * (A running system's own root can't be renamed: switching the booted system is the
 * installer's, ROADMAP Phase 3; this updates a system root held as a folder.) fetch downloads
 * URL and URL.sig into DIR, resuming one cut short (fetch.m), and verifies them.
 */
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define DEFAULT_KEY "/usr/share/finch/update-key.der"

static CFDataRef
read_file(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return NULL;
	struct stat st;
	if (fstat(fd, &st) < 0 || st.st_size > 64 * 1024) {
		close(fd);
		return NULL;
	}
	UInt8 *buf = malloc((size_t)st.st_size ?: 1);
	ssize_t n = read(fd, buf, (size_t)st.st_size);
	close(fd);
	CFDataRef d = n == st.st_size ? CFDataCreate(NULL, buf, n) : NULL;
	free(buf);
	return d;
}

/* The archive's SHA-256, read in pieces (an install payload is large). */
static int
digest_file(const char *path, unsigned char out[CC_SHA256_DIGEST_LENGTH])
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	CC_SHA256_CTX c;
	CC_SHA256_Init(&c);
	static unsigned char buf[1 << 20];
	ssize_t n;
	while ((n = read(fd, buf, sizeof buf)) > 0)
		CC_SHA256_Update(&c, buf, (CC_LONG)n);
	close(fd);
	if (n < 0)
		return -1;
	CC_SHA256_Final(out, &c);
	return 0;
}

static int
verify(const char *archive, const char *signature)
{
	const char *keypath = getenv("FINCH_UPDATE_KEY") ?: DEFAULT_KEY;
	CFDataRef point = read_file(keypath), sig = read_file(signature);
	if (!point) {
		fprintf(stderr, "finch-update: no update key at %s\n", keypath);
		return 1;
	}
	if (!sig) {
		fprintf(stderr, "finch-update: no signature at %s\n", signature);
		CFRelease(point);
		return 1;
	}
	const void *keys[] = {kSecAttrKeyType, kSecAttrKeyClass};
	const void *values[] = {kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic};
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	SecKeyRef key = SecKeyCreateWithData(point, attrs, NULL);
	CFRelease(attrs);
	CFRelease(point);
	unsigned char md[CC_SHA256_DIGEST_LENGTH];
	int status = 1;
	if (!key)
		fprintf(stderr, "finch-update: the update key at %s isn't a P-256 public key\n", keypath);
	else if (digest_file(archive, md) < 0)
		fprintf(stderr, "finch-update: can't read %s: %s\n", archive, strerror(errno));
	else {
		CFDataRef digest = CFDataCreate(NULL, md, sizeof md);
		if (SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureDigestX962SHA256, digest, sig, NULL))
			status = 0;
		else
			fprintf(stderr, "finch-update: %s isn't signed by the update key\n", archive);
		CFRelease(digest);
	}
	if (key)
		CFRelease(key);
	CFRelease(sig);
	return status;
}

static int
run(char *const argv[])
{
	pid_t pid;
	if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0)
		return -1;
	int st;
	while (waitpid(pid, &st, 0) < 0)
		if (errno != EINTR)
			return -1;
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

#ifdef FINCH_UPDATE_TESTING
/* Test builds stop at named transaction boundaries so the test can kill the process. */
static void
test_stop_at(const char *point)
{
	const char *requested = getenv("FINCH_UPDATE_TEST_STOP_AT");
	const char *ready = getenv("FINCH_UPDATE_TEST_READY");
	if (!requested || strcmp(requested, point) != 0)
		return;
	if (ready) {
		int fd = open(ready, O_CREAT | O_TRUNC | O_WRONLY, 0600);
		if (fd >= 0) {
			write(fd, point, strlen(point));
			close(fd);
		}
	}
	raise(SIGSTOP);
}
#else
#define test_stop_at(point) ((void)0)
#endif

static int
remove_tree(const char *path)
{
	struct stat st;
	if (lstat(path, &st) < 0)
		return errno == ENOENT ? 0 : -1;
	char *argv[] = {"/bin/rm", "-rf", (char *)path, NULL};
	return run(argv);
}

/* What belongs to the user, not the system: copied from the current root into the new one,
   in place of the payload's defaults, and copied back on rollback. The rest of Library and
   var/db is the system's (LaunchDaemons, timezone data), and so is usr/local (its licence
   files). */
static const char *const preserved[] = {
	"Users", "Applications", "Library/Preferences", "Library/Keychains",
	"Library/Application Support", "private/var/root", "private/var/db/dslocal", "private/var/at",
	"private/etc/master.passwd", "private/etc/passwd", "private/etc/group",
};
#define NPRESERVED (sizeof(preserved) / sizeof(*preserved))

static int
path_status(const char *path, struct stat *st)
{
	if (lstat(path, st) == 0)
		return 1;
	return errno == ENOENT ? 0 : -1;
}

static int
real_directory_if_present(const char *path, int present)
{
	if (!present)
		return 0;
	struct stat st;
	if (lstat(path, &st) < 0)
		return -1;
	if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
		errno = ENOTDIR;
		return -1;
	}
	return 0;
}

static int
root_path(char *out, size_t size, const char *root, const char *suffix)
{
	int n = snprintf(out, size, "%s%s", root, suffix);
	return n >= 0 && (size_t)n < size ? 0 : -1;
}

/* Make parents inside the new root, refusing to follow links from the payload. */
static int
make_parents(const char *dest_root, const char *relative)
{
	char p[PATH_MAX];
	if (snprintf(p, sizeof p, "%s", dest_root) >= (int)sizeof p)
		return -1;
	struct stat st;
	if (lstat(p, &st) < 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
		return -1;
	const char *slash = strchr(relative, '/');
	while (slash) {
		size_t rootlen = strlen(dest_root), prefix = (size_t)(slash - relative);
		if (rootlen + 1 + prefix + 1 > sizeof p)
			return -1;
		memcpy(p, dest_root, rootlen);
		p[rootlen] = '/';
		memcpy(p + rootlen + 1, relative, prefix);
		p[rootlen + 1 + prefix] = '\0';
		if (lstat(p, &st) < 0) {
			if (errno != ENOENT || mkdir(p, 0755) < 0)
				return -1;
		} else if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
			errno = ENOTDIR;
			return -1;
		}
		slash = strchr(slash + 1, '/');
	}
	return 0;
}

/* Copy through a sibling temporary path. The source remains intact if copy or rename fails. */
static int
copy_item(const char *from, const char *to)
{
	char temp[PATH_MAX], parked[PATH_MAX];
	if (root_path(temp, sizeof temp, to, ".finch-copy") < 0 ||
	    root_path(parked, sizeof parked, to, ".finch-parked") < 0)
		return -1;
	if (remove_tree(temp) != 0 || remove_tree(parked) != 0)
		return -1;
	char *copy[] = {"/bin/cp", "-Rp", (char *)from, temp, NULL};
	if (run(copy) != 0) {
		remove_tree(temp);
		fprintf(stderr, "finch-update: can't copy %s\n", from);
		return -1;
	}
	test_stop_at("copy.after_temp");
	struct stat st;
	int had = path_status(to, &st);
	if (had < 0 || (had && rename(to, parked) < 0)) {
		remove_tree(temp);
		return -1;
	}
	if (rename(temp, to) < 0) {
		int saved = errno;
		if (had)
			rename(parked, to);
		remove_tree(temp);
		errno = saved;
		return -1;
	}
	if (had && remove_tree(parked) != 0)
		return -1;
	return 0;
}

/* Copy user paths. During rollback, an absent path means the user deleted it. */
static int
carry(const char *from, const char *to, int clear_missing)
{
	char a[PATH_MAX], b[PATH_MAX];
	for (size_t i = 0; i < NPRESERVED; i++) {
		int na = snprintf(a, sizeof a, "%s/%s", from, preserved[i]);
		int nb = snprintf(b, sizeof b, "%s/%s", to, preserved[i]);
		if (na < 0 || (size_t)na >= sizeof a || nb < 0 || (size_t)nb >= sizeof b)
			return -1;
		struct stat st;
		int exists = path_status(a, &st);
		if (exists < 0) {
			fprintf(stderr, "finch-update: can't read %s: %s\n", a, strerror(errno));
			return -1;
		}
		if (!exists) {
			if (clear_missing && remove_tree(b) != 0)
				return -1;
			continue;
		}
		if (make_parents(to, preserved[i]) < 0 || copy_item(a, b) < 0) {
			fprintf(stderr, "finch-update: can't preserve %s: %s\n", a, strerror(errno));
			return -1;
		}
	}
	return 0;
}

static int
sync_tree(const char *path)
{
	struct stat st;
	if (lstat(path, &st) < 0)
		return -1;
	if (S_ISLNK(st.st_mode))
		return 0;
	if (S_ISDIR(st.st_mode)) {
		DIR *dir = opendir(path);
		if (!dir)
			return -1;
		int result = 0;
		for (;;) {
			errno = 0;
			struct dirent *entry = readdir(dir);
			if (!entry) {
				if (errno != 0)
					result = -1;
				break;
			}
			if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
				continue;
			char child[PATH_MAX];
			int n = snprintf(child, sizeof child, "%s/%s", path, entry->d_name);
			if (n < 0 || (size_t)n >= sizeof child || sync_tree(child) < 0) {
				result = -1;
				break;
			}
		}
		int saved = errno;
		if (closedir(dir) < 0 && result == 0)
			result = -1;
		errno = saved;
		if (result < 0)
			return -1;
	} else if (S_ISREG(st.st_mode)) {
		int fd = open(path, O_RDONLY | O_NOFOLLOW);
		if (fd < 0)
			return -1;
		int result = fsync(fd), saved = errno;
		close(fd);
		errno = saved;
		if (result < 0)
			return -1;
	} else {
		return 0;
	}
	int fd = open(path, O_RDONLY | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	int result = fsync(fd), saved = errno;
	close(fd);
	errno = saved;
	return result;
}

static int
sync_parent(const char *path)
{
	char parent[PATH_MAX];
	if (snprintf(parent, sizeof parent, "%s", path) >= (int)sizeof parent)
		return -1;
	char *slash = strrchr(parent, '/');
	if (!slash)
		return -1;
	if (slash == parent)
		slash[1] = '\0';
	else
		*slash = '\0';
	int fd = open(parent, O_RDONLY);
	if (fd < 0)
		return -1;
	int result = fsync(fd), saved = errno;
	close(fd);
	errno = saved;
	return result;
}

static int
lock_root(const char *root)
{
	char path[PATH_MAX];
	if (root_path(path, sizeof path, root, ".finch-lock") < 0) {
		errno = ENAMETOOLONG;
		return -1;
	}
	int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0 || flock(fd, LOCK_EX) < 0) {
		int saved = errno;
		if (fd >= 0)
			close(fd);
		errno = saved;
		return -1;
	}
	return fd;
}

static int
valid_root(const char *root)
{
	size_t n = root ? strlen(root) : 0;
	if (n < 2 || root[0] != '/' || root[n - 1] == '/' || n + 64 >= PATH_MAX)
		return 0;
	for (const char *p = root + 1; *p;) {
		const char *end = strchr(p, '/');
		size_t len = end ? (size_t)(end - p) : strlen(p);
		if (len == 0 || (len == 1 && p[0] == '.') ||
		    (len == 2 && p[0] == '.' && p[1] == '.'))
			return 0;
		if (!end)
			break;
		p = end + 1;
	}
	return strcmp(root, "/") != 0;
}

enum recovery_result { RECOVERY_ERROR = -1, RECOVERY_CLEAR = 0, RECOVERY_ROLLED_BACK = 1 };

/* Restore a consistent root after a stopped rename sequence. */
static enum recovery_result
recover_layout(const char *root)
{
	char stage[PATH_MAX], old[PATH_MAX], discard[PATH_MAX], failed[PATH_MAX];
	if (root_path(stage, sizeof stage, root, ".finch-new") < 0 ||
	    root_path(old, sizeof old, root, ".finch-old") < 0 ||
	    root_path(discard, sizeof discard, root, ".finch-discard") < 0 ||
	    root_path(failed, sizeof failed, root, ".finch-rolled-back") < 0)
		return RECOVERY_ERROR;
	struct stat st;
	int has_root = path_status(root, &st), has_old = path_status(old, &st);
	int has_discard = path_status(discard, &st), has_failed = path_status(failed, &st);
	int has_stage = path_status(stage, &st);
	if (has_root < 0 || has_old < 0 || has_discard < 0 || has_failed < 0 || has_stage < 0)
		return RECOVERY_ERROR;
	const char *artifacts[] = {stage, old, discard, failed};
	int present[] = {has_stage, has_old, has_discard, has_failed};
	for (size_t i = 0; i < sizeof artifacts / sizeof *artifacts; i++) {
		if (real_directory_if_present(artifacts[i], present[i]) < 0) {
			fprintf(stderr, "finch-update: %s must be a real directory; leaving it untouched\n", artifacts[i]);
			return RECOVERY_ERROR;
		}
	}
	if (has_root && (lstat(root, &st) < 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))) {
		fprintf(stderr, "finch-update: %s must be a real directory\n", root);
		return RECOVERY_ERROR;
	}
	if (!has_root) {
		if (has_old && has_failed) {
			if (rename(old, root) < 0 || sync_parent(root) < 0) {
				fprintf(stderr, "finch-update: can't finish the interrupted rollback: %s\n", strerror(errno));
				return RECOVERY_ERROR;
			}
			if (remove_tree(failed) != 0 || remove_tree(stage) != 0 ||
			    (has_discard && remove_tree(discard) != 0))
				return RECOVERY_ERROR;
			return RECOVERY_ROLLED_BACK;
		}
		if (has_old) {
			if (rename(old, root) < 0 || sync_parent(root) < 0) {
				fprintf(stderr, "finch-update: can't restore %s after an interrupted install: %s\n", root,
				    strerror(errno));
				return RECOVERY_ERROR;
			}
			if (has_discard && rename(discard, old) < 0) {
				fprintf(stderr, "finch-update: can't restore the previous rollback copy: %s\n", strerror(errno));
				return RECOVERY_ERROR;
			}
			if (remove_tree(stage) != 0 || (has_failed && remove_tree(failed) != 0))
				return RECOVERY_ERROR;
			return RECOVERY_CLEAR;
		}
		if (has_failed || has_discard) {
			const char *source = has_failed ? failed : discard;
			if (rename(source, root) < 0 || sync_parent(root) < 0)
				return RECOVERY_ERROR;
			if (remove_tree(stage) != 0)
				return RECOVERY_ERROR;
			return RECOVERY_CLEAR;
		}
		if (has_stage) {
			fprintf(stderr, "finch-update: %s is missing; only an unfinished staging tree remains\n", root);
			return RECOVERY_ERROR;
		}
		return RECOVERY_CLEAR;
	}
	if (has_discard) {
		if (!has_old) {
			if (rename(discard, old) < 0 || sync_parent(old) < 0) {
				fprintf(stderr, "finch-update: can't restore the previous rollback copy: %s\n", strerror(errno));
				return RECOVERY_ERROR;
			}
		} else {
			if (has_stage != 0) {
				fprintf(stderr, "finch-update: update files are in an unclear state; leaving them untouched\n");
				return RECOVERY_ERROR;
			}
			if (remove_tree(discard) != 0)
				return RECOVERY_ERROR;
		}
	}
	if (has_failed) {
		if (has_old) {
			fprintf(stderr, "finch-update: rollback files are in an unclear state; leaving them untouched\n");
			return RECOVERY_ERROR;
		}
		if (remove_tree(failed) != 0)
			return RECOVERY_ERROR;
		return RECOVERY_ROLLED_BACK;
	}
	return RECOVERY_CLEAR;
}

static int
install(const char *archive, const char *signature, const char *root)
{
	if (!valid_root(root)) {
		fprintf(stderr, "finch-update: refusing unsafe root path %s\n", root);
		return 1;
	}
	int lock = lock_root(root);
	if (lock < 0) {
		fprintf(stderr, "finch-update: can't lock %s: %s\n", root, strerror(errno));
		return 1;
	}
	test_stop_at("install.after_lock");
	enum recovery_result recovered = recover_layout(root);
	if (recovered == RECOVERY_ERROR) {
		close(lock);
		return 1;
	}
	char stage[PATH_MAX], old[PATH_MAX], discard[PATH_MAX];
	if (root_path(stage, sizeof stage, root, ".finch-new") < 0 ||
	    root_path(old, sizeof old, root, ".finch-old") < 0 ||
	    root_path(discard, sizeof discard, root, ".finch-discard") < 0) {
		close(lock);
		return 1;
	}
	if (verify(archive, signature)) {
		close(lock);
		return 1;
	}
	if (remove_tree(stage) != 0 || mkdir(stage, 0755) < 0) {
		fprintf(stderr, "finch-update: can't make %s: %s\n", stage, strerror(errno));
		close(lock);
		return 1;
	}
	/* pipefail makes a truncated gzip fail even if pax accepted its partial output. */
	char *argv[] = {"/bin/sh", "-c", "set -o pipefail; /usr/bin/gzip -dc \"$1\" | (cd \"$2\" && /bin/pax -r -pe)", "sh",
	    (char *)archive, stage, NULL};
	if (run(argv) != 0) {
		fprintf(stderr, "finch-update: unpacking %s failed; %s is unchanged\n", archive, root);
		remove_tree(stage);
		close(lock);
		return 1;
	}
	struct stat st;
	int had = path_status(root, &st);
	if (had < 0 || (had && carry(root, stage, 0) != 0)) {
		fprintf(stderr, "finch-update: %s is unchanged\n", root);
		remove_tree(stage);
		close(lock);
		return 1;
	}
	if (sync_tree(stage) < 0) {
		fprintf(stderr, "finch-update: can't finish writing %s: %s\n", stage, strerror(errno));
		remove_tree(stage);
		close(lock);
		return 1;
	}
	/* Keep the previous rollback copy until the new tree is in place. */
	struct stat oldst;
	int had_old = path_status(old, &oldst);
	if (had_old < 0 || (had_old && rename(old, discard) < 0)) {
		fprintf(stderr, "finch-update: can't move the previous rollback copy aside: %s\n", strerror(errno));
		remove_tree(stage);
		close(lock);
		return 1;
	}
	if (had_old && sync_parent(old) < 0) {
		fprintf(stderr, "finch-update: can't save the rollback copy: %s\n", strerror(errno));
		rename(discard, old);
		remove_tree(stage);
		close(lock);
		return 1;
	}
	if (had && rename(root, old) < 0) {
		fprintf(stderr, "finch-update: can't move %s aside: %s\n", root, strerror(errno));
		if (had_old)
			rename(discard, old);
		remove_tree(stage);
		close(lock);
		return 1;
	}
	if (had && sync_parent(root) < 0) {
		fprintf(stderr, "finch-update: can't save the previous system: %s\n", strerror(errno));
		rename(old, root);
		if (had_old)
			rename(discard, old);
		remove_tree(stage);
		close(lock);
		return 1;
	}
	if (had)
		test_stop_at("install.after_old_rename");
	if (rename(stage, root) < 0) {
		fprintf(stderr, "finch-update: can't put the new system in place: %s\n", strerror(errno));
		if (had) {
			if (rename(old, root) < 0)
				fprintf(stderr, "finch-update: recovery copy remains at %s\n", old);
		} else if (had_old) {
			rename(discard, old);
		}
		close(lock);
		return 1;
	}
	if (sync_parent(root) < 0) {
		fprintf(stderr, "finch-update: installed %s, but couldn't sync its parent directory: %s\n", root,
		    strerror(errno));
		close(lock);
		return 1;
	}
	if (had_old && remove_tree(discard) != 0)
		fprintf(stderr, "finch-update: installed %s; old rollback copy remains at %s\n", root, discard);
	printf("finch-update: %s installed%s\n", root, had ? " (the previous system kept for rollback)" : "");
	close(lock);
	return 0;
}

static int
rollback(const char *root)
{
	if (!valid_root(root)) {
		fprintf(stderr, "finch-update: refusing unsafe root path %s\n", root);
		return 1;
	}
	int lock = lock_root(root);
	if (lock < 0) {
		fprintf(stderr, "finch-update: can't lock %s: %s\n", root, strerror(errno));
		return 1;
	}
	enum recovery_result recovered = recover_layout(root);
	if (recovered == RECOVERY_ERROR) {
		close(lock);
		return 1;
	}
	if (recovered == RECOVERY_ROLLED_BACK) {
		printf("finch-update: %s rollback recovered\n", root);
		close(lock);
		return 0;
	}
	char old[PATH_MAX], failed[PATH_MAX];
	if (root_path(old, sizeof old, root, ".finch-old") < 0 ||
	    root_path(failed, sizeof failed, root, ".finch-rolled-back") < 0) {
		close(lock);
		return 1;
	}
	struct stat st;
	if (path_status(old, &st) != 1) {
		fprintf(stderr, "finch-update: no previous system at %s\n", old);
		close(lock);
		return 1;
	}
	/* Copy first; the live root keeps all user data if this or a later step fails. */
	if (carry(root, old, 1) != 0 || sync_tree(old) < 0) {
		fprintf(stderr, "finch-update: %s is unchanged\n", root);
		close(lock);
		return 1;
	}
	if (remove_tree(failed) != 0 || rename(root, failed) < 0) {
		fprintf(stderr, "finch-update: can't move %s aside: %s\n", root, strerror(errno));
		close(lock);
		return 1;
	}
	if (sync_parent(root) < 0) {
		fprintf(stderr, "finch-update: can't save the current system: %s\n", strerror(errno));
		rename(failed, root);
		close(lock);
		return 1;
	}
	test_stop_at("rollback.after_root_rename");
	if (rename(old, root) < 0) {
		fprintf(stderr, "finch-update: can't put the previous system back: %s\n", strerror(errno));
		close(lock);
		return 1;
	}
	if (sync_parent(root) < 0) {
		fprintf(stderr, "finch-update: rolled back %s, but couldn't sync its parent directory: %s\n", root,
		    strerror(errno));
		close(lock);
		return 1;
	}
	if (remove_tree(failed) != 0)
		fprintf(stderr, "finch-update: rolled back %s; the newer system remains at %s\n", root, failed);
	printf("finch-update: %s rolled back\n", root);
	close(lock);
	return 0;
}

int finch_update_fetch(const char *url, const char *dir, char *archive, size_t archiveSize);

static int
usage(void)
{
	fprintf(stderr, "usage: finch-update verify ARCHIVE [SIGNATURE]\n"
	                "       finch-update install ARCHIVE [SIGNATURE] --root DIR\n"
	                "       finch-update rollback --root DIR\n"
	                "       finch-update fetch URL DIR\n");
	return 2;
}

int
main(int argc, char **argv)
{
	if (argc < 2)
		return usage();
	const char *root = NULL, *args[2] = {NULL, NULL};
	int n = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--root") && i + 1 < argc)
			root = argv[++i];
		else if (n < 2)
			args[n++] = argv[i];
		else
			return usage();
	}
	if (!strcmp(argv[1], "fetch") && n == 2 && !root) {
		char archive[1024], signature[1100];
		if (finch_update_fetch(args[0], args[1], archive, sizeof archive) != 0)
			return 1;
		snprintf(signature, sizeof signature, "%s.sig", archive);
		int s = verify(archive, signature);
		if (!s)
			printf("finch-update: %s is signed by the update key\n", archive);
		return s;
	}
	char sig[1024];
	if (n >= 1 && !args[1]) {
		snprintf(sig, sizeof sig, "%s.sig", args[0]);
		args[1] = sig;
	}
	if (!strcmp(argv[1], "verify") && n >= 1 && !root) {
		int s = verify(args[0], args[1]);
		if (!s)
			printf("finch-update: %s is signed by the update key\n", args[0]);
		return s;
	}
	if (!strcmp(argv[1], "install") && n >= 1 && root)
		return install(args[0], args[1], root);
	if (!strcmp(argv[1], "rollback") && n == 0 && root)
		return rollback(root);
	return usage();
}

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
 *
 * SIGNATURE is ARCHIVE.sig unless given. The public key is /usr/share/finch/update-key.der
 * (the curve point, X9.63), or the file FINCH_UPDATE_KEY names. install checks the signature,
 * unpacks the archive into DIR.finch-new beside DIR (one an interrupted install left is
 * cleared first), carries the user's files and settings over from DIR (preserved[]), then
 * swaps it in by renaming: DIR becomes DIR.finch-old and the new tree DIR. A failure at any
 * step leaves DIR as it was. rollback swaps DIR.finch-old back, the user's files with it.
 * (A running system's own root can't be renamed: switching the booted system is the
 * installer's, ROADMAP Phase 3; this updates a system root held as a folder.)
 */
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static int
remove_tree(const char *path)
{
	struct stat st;
	if (lstat(path, &st) < 0)
		return errno == ENOENT ? 0 : -1;
	char *argv[] = {"/bin/rm", "-rf", (char *)path, NULL};
	return run(argv);
}

/* What belongs to the user, not the system: moved from the running root into the new one,
   in place of the payload's defaults, and back on rollback. The rest of Library and
   var/db is the system's (LaunchDaemons, timezone data), and so is usr/local (its licence
   files). */
static const char *const preserved[] = {
	"Users", "Applications", "Library/Preferences", "Library/Keychains",
	"Library/Application Support", "private/var/root", "private/var/db/dslocal", "private/var/at",
	"private/etc/master.passwd", "private/etc/passwd", "private/etc/group",
};
#define NPRESERVED (sizeof(preserved) / sizeof(*preserved))

/* Make the folders above path, as the running system has them. */
static void
make_parents(const char *path)
{
	char p[1024];
	snprintf(p, sizeof p, "%s", path);
	for (char *s = strchr(p + 1, '/'); s; s = strchr(s + 1, '/')) {
		*s = 0;
		mkdir(p, 0755);
		*s = '/';
	}
}

/* Move each preserved path from one root into the other, replacing what's there; on a
   failure, put back what was moved. */
static int
carry(const char *from, const char *to)
{
	int moved[NPRESERVED] = {0};
	char a[1024], b[1024], parked[1100];
	for (size_t i = 0; i < NPRESERVED; i++) {
		snprintf(a, sizeof a, "%s/%s", from, preserved[i]);
		snprintf(b, sizeof b, "%s/%s", to, preserved[i]);
		struct stat st;
		if (lstat(a, &st) < 0)
			continue;
		/* the destination's own copy is parked, so a failure can restore it */
		snprintf(parked, sizeof parked, "%s.finch-parked", b);
		remove_tree(parked);
		make_parents(b);
		int had = lstat(b, &st) == 0;
		if ((had && rename(b, parked) < 0) || rename(a, b) < 0) {
			fprintf(stderr, "finch-update: can't move %s: %s\n", a, strerror(errno));
			if (had)
				rename(parked, b);
			for (size_t j = i; j-- > 0;) {
				if (!moved[j])
					continue;
				snprintf(a, sizeof a, "%s/%s", from, preserved[j]);
				snprintf(b, sizeof b, "%s/%s", to, preserved[j]);
				snprintf(parked, sizeof parked, "%s.finch-parked", b);
				rename(b, a);
				rename(parked, b);
			}
			return -1;
		}
		moved[i] = 1;
	}
	for (size_t i = 0; i < NPRESERVED; i++) {
		snprintf(b, sizeof b, "%s/%s.finch-parked", to, preserved[i]);
		remove_tree(b);
	}
	return 0;
}

static int
install(const char *archive, const char *signature, const char *root)
{
	if (verify(archive, signature))
		return 1;
	char stage[1024], old[1024];
	snprintf(stage, sizeof stage, "%s.finch-new", root);
	snprintf(old, sizeof old, "%s.finch-old", root);
	if (remove_tree(stage) != 0 || mkdir(stage, 0755) < 0) {
		fprintf(stderr, "finch-update: can't make %s: %s\n", stage, strerror(errno));
		return 1;
	}
	/* gzip and pax unpack it, keeping its owners and modes (-pe) */
	char *argv[] = {"/bin/sh", "-c", "/usr/bin/gzip -dc \"$1\" | (cd \"$2\" && /bin/pax -r -pe)", "sh",
	    (char *)archive, stage, NULL};
	if (run(argv) != 0) {
		fprintf(stderr, "finch-update: unpacking %s failed; %s is unchanged\n", archive, root);
		remove_tree(stage);
		return 1;
	}
	if (remove_tree(old) != 0) {
		fprintf(stderr, "finch-update: can't clear %s; %s is unchanged\n", old, root);
		return 1;
	}
	struct stat st;
	int had = lstat(root, &st) == 0;
	if (had && carry(root, stage) != 0) {
		fprintf(stderr, "finch-update: %s is unchanged\n", root);
		remove_tree(stage);
		return 1;
	}
	if (had && rename(root, old) < 0) {
		fprintf(stderr, "finch-update: can't move %s aside: %s\n", root, strerror(errno));
		carry(stage, root);
		remove_tree(stage);
		return 1;
	}
	if (rename(stage, root) < 0) {
		fprintf(stderr, "finch-update: can't put the new system in place: %s\n", strerror(errno));
		if (had) {
			rename(old, root);
			carry(stage, root);
		}
		return 1;
	}
	printf("finch-update: %s installed%s\n", root, had ? " (the previous system kept for rollback)" : "");
	return 0;
}

static int
rollback(const char *root)
{
	char old[1024], failed[1024];
	snprintf(old, sizeof old, "%s.finch-old", root);
	snprintf(failed, sizeof failed, "%s.finch-rolled-back", root);
	struct stat st;
	if (lstat(old, &st) < 0) {
		fprintf(stderr, "finch-update: no previous system at %s\n", old);
		return 1;
	}
	/* the user's files go back with the previous system */
	if (carry(root, old) != 0) {
		fprintf(stderr, "finch-update: %s is unchanged\n", root);
		return 1;
	}
	if (remove_tree(failed) != 0 || rename(root, failed) < 0) {
		fprintf(stderr, "finch-update: can't move %s aside: %s\n", root, strerror(errno));
		carry(old, root);
		return 1;
	}
	if (rename(old, root) < 0) {
		fprintf(stderr, "finch-update: can't put the previous system back: %s\n", strerror(errno));
		rename(failed, root);
		carry(old, root);
		return 1;
	}
	remove_tree(failed);
	printf("finch-update: %s rolled back\n", root);
	return 0;
}

static int
usage(void)
{
	fprintf(stderr, "usage: finch-update verify ARCHIVE [SIGNATURE]\n"
	                "       finch-update install ARCHIVE [SIGNATURE] --root DIR\n"
	                "       finch-update rollback --root DIR\n");
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

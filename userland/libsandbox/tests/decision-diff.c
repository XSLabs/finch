/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * decision-diff: one profile, two sandboxes. A child applies the profile with
 * the host's own sandbox (macOS's, through sandbox_init_with_parameters) and
 * tries a fixed set of operations; the parent compiles the same profile with
 * Finch's compiler and asks Finch's evaluator about the same requests. Every
 * request where the two disagree is printed.
 *
 *   decision-diff [-D NAME=VALUE]... [-I dir]... profile.sb
 *
 * Paths are probed as the kernel would see them (resolved, so /etc/hosts is
 * /private/etc/hosts). Writes go only to a fresh scratch folder and /dev/null.
 */
#include "../sbpl.h"
#include "fsb_format.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[],
    char **errorbuf);

enum { P_READ, P_STAT, P_WRITE, P_CREATE, P_SYSCTL, P_LOOKUP, P_SHM };
static const char *probe_names[] = { "file-read-data", "file-read-metadata", "file-write-data",
	"file-write-create", "sysctl-read", "mach-lookup", "ipc-posix-shm-read-data" };

struct probe {
	int kind;
	char target[PATH_MAX];
};

static struct probe probes[2048];
static size_t nprobes;

static void
add(int kind, const char *target)
{
	if (nprobes < sizeof(probes) / sizeof(probes[0])) {
		probes[nprobes].kind = kind;
		snprintf(probes[nprobes].target, sizeof(probes[nprobes].target), "%s", target);
		nprobes++;
	}
}

static void
add_paths(int kind, const char *home, const char *tmp)
{
	static const char *fixed[] = {
		"/private/etc/hosts", "/private/etc/passwd", "/private/etc/master.passwd",
		"/usr/lib/libSystem.B.dylib", "/usr/lib/dyld", "/bin/sh", "/usr/bin/true",
		"/System/Library/CoreServices/SystemVersion.plist",
		"/System/Library/Frameworks/Foundation.framework/Foundation",
		"/Library/Preferences/.GlobalPreferences.plist", "/Library/Preferences/com.apple.loginwindow.plist",
		"/private/var/db/timezone/zoneinfo/UTC", "/private/var/run/resolv.conf",
		"/private/var/log/system.log", "/private/var/log/notifyd.log", "/private/var/run/notifyd_x",
		"/dev/null", "/dev/random", "/dev/urandom", "/dev/tty", "/dev/disk0",
		"/Applications", "/Users", "/private/tmp", "/private/var/folders", "/",
		"/usr/share/icu", "/usr/share/zoneinfo", "/Library/Keychains/System.keychain",
	};
	char buf[PATH_MAX];
	for (size_t i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++) {
		add(kind, fixed[i]);
	}
	static const char *in_home[] = {
		"", "/Library", "/Library/Preferences", "/Library/Preferences/.GlobalPreferences.plist",
		"/Library/Caches", "/Library/Keychains", "/Documents", "/Desktop", "/.ssh",
		"/Library/Application Support", "/Library/Containers", "/Library/Group Containers",
	};
	for (size_t i = 0; i < sizeof(in_home) / sizeof(in_home[0]); i++) {
		snprintf(buf, sizeof(buf), "%s%s", home, in_home[i]);
		add(kind, buf);
	}
	snprintf(buf, sizeof(buf), "%s", tmp);
	add(kind, buf);
}

/* A path as the kernel names it: resolved, or its resolved folder plus the name. */
static void
kernel_path(const char *path, char *out)
{
	char dir[PATH_MAX], resolved[PATH_MAX];
	if (realpath(path, out)) {
		return;
	}
	snprintf(dir, sizeof(dir), "%s", path);
	char *slash = strrchr(dir, '/');
	if (!slash) {
		snprintf(out, PATH_MAX, "%s", path);
		return;
	}
	*slash = 0;
	if (realpath(dir[0] ? dir : "/", resolved)) {
		snprintf(out, PATH_MAX, "%s/%s", strcmp(resolved, "/") ? resolved : "", slash + 1);
	} else {
		snprintf(out, PATH_MAX, "%s", path);
	}
}

/* 1 allowed, 0 denied, -1 can't tell (the operation failed for another reason). */
static int
try(const struct probe *p)
{
	int fd, r;
	struct stat st;
	switch (p->kind) {
	case P_READ:
		fd = open(p->target, O_RDONLY | O_NONBLOCK);
		if (fd >= 0) {
			close(fd);
			return 1;
		}
		return errno == EPERM ? 0 : -1;
	case P_STAT:
		r = lstat(p->target, &st);
		return r == 0 ? 1 : errno == EPERM ? 0 : -1;
	case P_WRITE:
		fd = open(p->target, O_WRONLY | O_NONBLOCK);
		if (fd >= 0) {
			close(fd);
			return 1;
		}
		return errno == EPERM ? 0 : -1;
	case P_CREATE:
		fd = open(p->target, O_WRONLY | O_CREAT | O_EXCL, 0600);
		if (fd >= 0) {
			close(fd);
			unlink(p->target);
			return 1;
		}
		return errno == EPERM ? 0 : -1;
	case P_SYSCTL: {
		char buf[4096];
		size_t len = sizeof(buf);
		r = sysctlbyname(p->target, buf, &len, NULL, 0);
		return r == 0 || errno == ENOMEM ? 1 : errno == EPERM ? 0 : -1;
	}
	case P_LOOKUP: {
		mach_port_t port = MACH_PORT_NULL;
		kern_return_t kr = bootstrap_look_up(bootstrap_port, p->target, &port);
		if (kr == KERN_SUCCESS) {
			mach_port_deallocate(mach_task_self(), port);
			return 1;
		}
		return kr == BOOTSTRAP_NOT_PRIVILEGED ? 0 : -1;
	}
	case P_SHM:
		fd = shm_open(p->target, O_RDONLY);
		if (fd >= 0) {
			close(fd);
			return 1;
		}
		return errno == EPERM ? 0 : -1;
	}
	return -1;
}

int
main(int argc, char **argv)
{
	const char *dirs[16], *params_flat[512];
	struct sbpl_param params[256];
	size_t ndirs = 0, nparams = 0, nflat = 0;
	int i;

	for (i = 1; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-I") && i + 1 < argc && ndirs < 16) {
			dirs[ndirs++] = argv[++i];
		} else if (!strcmp(argv[i], "-D") && i + 1 < argc && nparams < 256) {
			char *eq = strchr(argv[++i], '=');
			if (!eq) {
				return 2;
			}
			*eq = 0;
			params[nparams].name = argv[i];
			params[nparams++].value = eq + 1;
			params_flat[nflat++] = argv[i];
			params_flat[nflat++] = eq + 1;
		} else {
			fprintf(stderr, "usage: decision-diff [-D NAME=VALUE] [-I dir] profile.sb\n");
			return 2;
		}
	}
	if (i + 1 != argc) {
		fprintf(stderr, "usage: decision-diff [-D NAME=VALUE] [-I dir] profile.sb\n");
		return 2;
	}
	params_flat[nflat] = NULL;
	const char *profile_path = argv[i];
	const char *home = getenv("HOME");
	for (size_t k = 0; k < nparams; k++) {
		if (!strcmp(params[k].name, "HOME")) {
			home = params[k].value;
		}
	}

	/* Finch's compile. */
	struct sbpl_options opt = { .params = params, .param_count = nparams,
		.search_paths = dirs, .search_path_count = ndirs };
	void *profile;
	size_t size;
	char *error;
	if (sbpl_compile_file(profile_path, &opt, &profile, &size, &error) != 0) {
		printf("finch can't compile %s: %s\n", profile_path, error);
		return 2;
	}

	/* A scratch folder for writes, and the probes. */
	char scratch[PATH_MAX], tmpl[] = "/private/tmp/decision-diff.XXXXXX", buf[PATH_MAX];
	if (!mkdtemp(tmpl)) {
		perror("mkdtemp");
		return 2;
	}
	snprintf(scratch, sizeof(scratch), "%s", tmpl);
	snprintf(buf, sizeof(buf), "%s/existing", scratch);
	close(open(buf, O_WRONLY | O_CREAT, 0600));
	add_paths(P_READ, home, scratch);
	add_paths(P_STAT, home, scratch);
	add(P_WRITE, "/dev/null");
	add(P_WRITE, buf);
	snprintf(buf, sizeof(buf), "%s/new", scratch);
	add(P_CREATE, buf);
	static const char *sysctls[] = { "kern.ostype", "kern.osrelease", "kern.osversion", "hw.ncpu",
		"hw.memsize", "kern.hostname", "kern.boottime", "hw.model", "kern.osproductversion",
		"hw.ephemeral_storage", "kern.osbuildconfig", "kern.secure_kernel", "vm.loadavg",
		"kern.argmax", "security.mac.sandbox.sentinel", "net.inet.ip.forwarding", "hw.optional.arm64" };
	for (size_t k = 0; k < sizeof(sysctls) / sizeof(sysctls[0]); k++) {
		add(P_SYSCTL, sysctls[k]);
	}
	static const char *services[] = { "com.apple.system.notification_center", "com.apple.system.logger",
		"com.apple.logd", "com.apple.diagnosticd", "com.apple.SecurityServer", "com.apple.cfprefsd.daemon",
		"com.apple.cfprefsd.agent", "com.apple.distributed_notifications@Uv3", "com.apple.lsd.mapdb",
		"com.apple.coreservices.launchservicesd", "com.apple.trustd", "com.apple.windowserver.active",
		"com.apple.system.opendirectoryd.libinfo", "com.apple.system.DirectoryService.libinfo_v1",
		"com.apple.mDNSResponder", "com.apple.dnssd.service", "com.apple.tccd", "com.apple.securityd.xpc",
		"com.apple.FileCoordination", "com.apple.fonts", "com.apple.pasteboard.1", "com.apple.audio.coreaudiod" };
	for (size_t k = 0; k < sizeof(services) / sizeof(services[0]); k++) {
		add(P_LOOKUP, services[k]);
	}
	add(P_SHM, "apple.shm.notification_center");
	add(P_SHM, "com.apple.AppleDatabaseChanged");

	/* macOS's answers, from a child that applies the profile. They come back
	   through memory shared before the sandbox applies: a profile may deny
	   writing to a pipe. Byte 0 is the child's state: 1 done, 2 couldn't apply. */
	signed char *shared = mmap(NULL, 1 + sizeof(probes) / sizeof(probes[0]) + 1024,
	    PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
	if (shared == MAP_FAILED) {
		return 2;
	}
	memset(shared, 0, 1 + sizeof(probes) / sizeof(probes[0]) + 1024);
	FILE *src = fopen(profile_path, "r");
	if (!src) {
		perror(profile_path);
		return 2;
	}
	static char source[4 << 20];
	size_t srclen = fread(source, 1, sizeof(source) - 1, src);
	source[srclen] = 0;
	fclose(src);
	pid_t pid = fork();
	if (pid == 0) {
		char *err = NULL;
		/* imports resolve against the profile's own folder in macOS's compiler */
		if (chdir("/System/Library/Sandbox/Profiles") != 0) {
			_exit(3);
		}
		if (sandbox_init_with_parameters(source, 0, params_flat, &err) != 0) {
			snprintf((char *)shared + 1 + nprobes, 1024, "%s", err ? err : "?");
			shared[0] = 2;
			_exit(4);
		}
		for (size_t k = 0; k < nprobes; k++) {
			shared[1 + k] = (signed char)try(&probes[k]);
		}
		shared[0] = 1;
		_exit(0);
	}
	int status;
	waitpid(pid, &status, 0);
	if (shared[0] == 2) {
		printf("macOS can't apply %s: %s\n", profile_path, (char *)shared + 1 + nprobes);
		return 2;
	}
	if (shared[0] != 1) {
		printf("macOS's child failed (status %d)\n", status);
		return 2;
	}
	signed char *apple = shared + 1;

	/* Finch's answers, and the differences. */
	void *scratchmem = malloc(FSB_SCRATCH_BYTES);
	int differences = 0, compared = 0;
	for (size_t k = 0; k < nprobes; k++) {
		if (apple[k] < 0) {
			continue;	/* failed for another reason: no answer to compare */
		}
		struct fsb_request req;
		const struct probe *p = &probes[k];
		char resolved[PATH_MAX];
		fsb_request_init(&req, fsb_op_lookup(probe_names[p->kind], strlen(probe_names[p->kind])));
		switch (p->kind) {
		case P_SYSCTL:
			fsb_request_string(&req, FSB_F_SYSCTL_NAME, p->target, strlen(p->target));
			break;
		case P_LOOKUP:
			fsb_request_string(&req, FSB_F_GLOBAL_NAME, p->target, strlen(p->target));
			break;
		case P_SHM:
			fsb_request_string(&req, FSB_F_IPC_POSIX_NAME, p->target, strlen(p->target));
			break;
		default:
			kernel_path(p->target, resolved);
			fsb_request_string(&req, FSB_F_PATH, resolved, strlen(resolved));
			break;
		}
		int finch = fsb_evaluate(profile, &req, scratchmem, NULL) == FSB_ALLOW;
		/* A (version 2) profile also filters the system call the probe makes. */
		if (finch && (((const struct fsb_header *)profile)->flags & FSB_PROFILE_FILTER_SYSCALLS)) {
			static const int syscall_of[] = {
				[P_READ] = SYS_open, [P_STAT] = SYS_lstat64, [P_WRITE] = SYS_open,
				[P_CREATE] = SYS_open, [P_SYSCTL] = SYS_sysctlbyname, [P_LOOKUP] = -1,
				[P_SHM] = SYS_shm_open,
			};
			if (syscall_of[p->kind] >= 0) {
				struct fsb_request sc;
				fsb_request_init(&sc, fsb_op_lookup("syscall-unix", 12));
				fsb_request_number(&sc, FSB_F_SYSCALL_NUMBER, (uint64_t)syscall_of[p->kind]);
				finch = fsb_evaluate(profile, &sc, scratchmem, NULL) == FSB_ALLOW;
			}
		}
		compared++;
		if (finch != apple[k]) {
			differences++;
			printf("  %s %s: macOS %s, Finch %s\n", probe_names[p->kind], p->target,
			    apple[k] ? "allows" : "denies", finch ? "allows" : "denies");
		}
	}
	snprintf(buf, sizeof(buf), "%s/existing", scratch);
	unlink(buf);
	rmdir(scratch);
	printf("%s: %d decisions compared, %d differ\n", profile_path, compared, differences);
	free(scratchmem);
	free(profile);
	return differences != 0;
}

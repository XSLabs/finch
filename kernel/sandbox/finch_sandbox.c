/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * FinchSandbox: Finch's sandbox policy.
 *
 * A process gets a sandbox once, from libsandbox's compiled SBPL profile
 * (FSB1, kernel/sandbox/fsb_format.h, applied with call 0x102), and keeps it
 * through fork and exec. The policy evaluates the profile (fsb_eval.c) at the
 * MAC hooks for the operations it names: file access by path, exec, file
 * mappings, signals, sysctls, POSIX shared memory and semaphores,
 * process information, sockets, IOKit, privileges, reboot, setting the time
 * and JIT memory. Services that grant access themselves (the bootstrap server's
 * mach-lookup, notifyd's darwin-notification-post) ask with call 0x103.
 *
 * The two fixed restrictions of the first enforcement proof (deny every file
 * read, deny every file write; calls 1, 2 and 0x100) keep working: they are
 * small label values beside the profile pointers.
 *
 * Built into XNU from Finch's tree by tools/build-kernel.sh (security/).
 */

#include <sys/param.h>
#include <sys/errno.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/kauth.h>
#include <sys/ucred.h>
#include <sys/proc.h>
#include <sys/proc_internal.h>
#include <sys/proc_private.h>
#include <sys/systm.h>
#include <sys/vnode.h>
#include <sys/mount.h>
#include <sys/namei.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/posix_shm.h>
#include <sys/file_internal.h>
#include <sys/reboot.h>
#include <sys/codesign.h>
#include <sys/un.h>
#include <netinet/in.h>

#include <kern/locks.h>
#include <kern/kalloc.h>
#include <kern/clock.h>
#include <kern/cs_blobs.h>
#include <mach/vm_prot.h>
#include <os/refcnt.h>
#include <libkern/crypto/sha2.h>
#include <sys/random.h>
#include <security/mac_framework.h>
#include <security/mac_policy.h>

#include "finch_sandbox_abi.h"
#include "fsb_format.h"

/* ---- profiles on credentials ---- */

/* A consumed sandbox extension: a class, and the path or service it covers. */
struct finch_sb_extension {
	int64_t handle;
	uint32_t type;		/* FINCH_SANDBOX_EXTENSION_* */
	uint32_t class_len;
	uint32_t data_len;
	char *extension_class;
	char *data;
};

/* A process's extensions; never changed once made (consuming makes a new set). */
struct finch_sb_extensions {
	os_refcnt_t ref;
	uint32_t count;
	struct finch_sb_extension e[];
};

struct finch_sb_profile {
	os_refcnt_t ref;
	uint32_t size;
	uint32_t unix_mask_size;
	/* (version 2) profiles: a bit per Unix system call the profile allows
	   outright; the others go to proc_check_syscall_unix. NULL otherwise. */
	uint8_t *unix_mask;
	/* A label made by consuming or releasing an extension has no profile of
	   its own: it shares this one's, with its own extensions. */
	struct finch_sb_profile *shared;
	struct finch_sb_extensions *extensions;
	uint64_t data[];	/* the FSB1 profile, 8-byte aligned */
};

static os_refgrp_decl(static, finch_sb_refgrp, "FinchSandbox", NULL);

static int finch_sandbox_label_slot;
static mac_policy_handle_t finch_sandbox_policy_handle;
static const char *finch_sandbox_label_names[] = { "finch_sandbox" };

static LCK_GRP_DECLARE(finch_sandbox_apply_lock_group, "FinchSandbox");
static LCK_MTX_DECLARE(finch_sandbox_apply_lock,
    &finch_sandbox_apply_lock_group);

/* Label values: 0 none, the two fixed restrictions, or a profile pointer. */
#define FINCH_SB_IS_FIXED(v)	((v) == FINCH_SANDBOX_PROFILE_DENY_READ || \
	                         (v) == FINCH_SANDBOX_PROFILE_DENY_WRITE)

static intptr_t
finch_sb_label(kauth_cred_t cred)
{
	if (!IS_VALID_CRED(cred)) {
		return 0;
	}
	return mac_label_get(mac_cred_label(cred), finch_sandbox_label_slot);
}

static struct finch_sb_profile *
finch_sb_profile_of(intptr_t v)
{
	return v != 0 && !FINCH_SB_IS_FIXED(v) ? (struct finch_sb_profile *)v : NULL;
}

static void
finch_sb_retain(intptr_t v)
{
	struct finch_sb_profile *p = finch_sb_profile_of(v);
	if (p) {
		os_ref_retain(&p->ref);
	}
}

static void
finch_sb_extensions_release(struct finch_sb_extensions *set)
{
	if (set != NULL && os_ref_release(&set->ref) == 0) {
		for (uint32_t i = 0; i < set->count; i++) {
			kfree_data(set->e[i].extension_class, set->e[i].class_len + 1);
			if (set->e[i].data != NULL) {
				kfree_data(set->e[i].data, set->e[i].data_len + 1);
			}
		}
		kfree_type(struct finch_sb_extensions, struct finch_sb_extension, set->count, set);
	}
}

static void
finch_sb_release(intptr_t v)
{
	struct finch_sb_profile *p = finch_sb_profile_of(v);
	if (p && os_ref_release(&p->ref) == 0) {
		if (p->unix_mask != NULL) {
			kfree_data(p->unix_mask, p->unix_mask_size);
		}
		if (p->shared != NULL) {
			finch_sb_release((intptr_t)p->shared);
		}
		finch_sb_extensions_release(p->extensions);
		kfree_data(p, sizeof(*p) + p->size);
	}
}

/* The compiled profile a label decides with. */
static const void *
finch_sb_profile_data(const struct finch_sb_profile *p)
{
	return p->shared != NULL ? p->shared->data : p->data;
}

static intptr_t
finch_sb_current(void)
{
	return finch_sb_label(kauth_cred_get());
}

/* The fixed restriction a label value carries, for the proof's checks. */
static int
finch_sb_fixed(intptr_t v)
{
	return FINCH_SB_IS_FIXED(v) ? (int)v : 0;
}

/* ---- denial reports ---- */

/* At most this many reports a second, so a denied loop can't flood the log. */
#define FINCH_SB_REPORTS_PER_SECOND 32
static uint64_t finch_sb_report_second;
static uint32_t finch_sb_reports;

static void
finch_sb_report(proc_t p, const struct fsb_request *r, uint32_t rule_flags)
{
	clock_sec_t sec;
	clock_usec_t usec;
	char name[MAXCOMLEN + 1];
	const char *target = NULL;
	size_t target_len = 0;

	if (rule_flags & FSB_RULE_NO_REPORT) {
		return;
	}
	clock_get_system_microtime(&sec, &usec);
	if ((uint64_t)sec != finch_sb_report_second) {
		finch_sb_report_second = sec;
		finch_sb_reports = 0;
	}
	if (++finch_sb_reports > FINCH_SB_REPORTS_PER_SECOND) {
		return;
	}
	for (int f = 0; f < FSB_F_STRING_COUNT; f++) {
		if (r->strings_present & (1u << f)) {
			target = r->string[f];
			target_len = r->length[f];
			break;
		}
	}
	proc_name(proc_pid(p), name, sizeof(name));
	/* The same shape as macOS's sandbox reports. */
	printf("Sandbox: %s(%d) deny(1) %s %.*s\n", name, proc_pid(p),
	    fsb_op_name(r->op) ? fsb_op_name(r->op) : "?",
	    target ? (int)MIN(target_len, 1024) : 0, target ? target : "");
}

/*
 * (extension "class"): does one of the caller's extensions of that class cover
 * the request? A file extension covers its path and everything below it; a
 * Mach one its service; a generic one any request.
 */
static bool
finch_sb_extension_covers(const void *arg, const char *extension_class, size_t length,
    const struct fsb_request *r)
{
	const struct finch_sb_extensions *set = arg;

	for (uint32_t i = 0; i < set->count; i++) {
		const struct finch_sb_extension *x = &set->e[i];
		if (x->class_len != length || memcmp(x->extension_class, extension_class, length) != 0) {
			continue;
		}
		if (x->type == FINCH_SANDBOX_EXTENSION_GENERIC) {
			return true;
		}
		int field = x->type == FINCH_SANDBOX_EXTENSION_MACH ? FSB_F_GLOBAL_NAME : FSB_F_PATH;
		if ((r->strings_present & (1u << field)) == 0) {
			continue;
		}
		const char *s = r->string[field];
		size_t n = r->length[field];
		if (n == x->data_len && memcmp(s, x->data, n) == 0) {
			return true;
		}
		if (x->type == FINCH_SANDBOX_EXTENSION_FILE && n > x->data_len &&
		    memcmp(s, x->data, x->data_len) == 0 &&
		    (s[x->data_len] == '/' || (x->data_len > 0 && x->data[x->data_len - 1] == '/'))) {
			return true;
		}
	}
	return false;
}

/*
 * Decide a request against a label value: 0 allowed, EPERM denied (macOS's
 * sandbox denials are EPERM). Unsandboxed callers are always allowed.
 */
static int
finch_sb_decide_for(proc_t subject, intptr_t label, const struct fsb_request *r, bool report)
{
	struct finch_sb_profile *p = finch_sb_profile_of(label);
	uint32_t rule_flags = 0;
	void *scratch;
	int decision;

	if (p == NULL) {
		return 0;
	}
	scratch = kalloc_data(FSB_SCRATCH_BYTES, Z_WAITOK);
	if (scratch == NULL) {
		return ENOMEM;
	}
	struct fsb_request with_extensions = *r;
	if (p->extensions != NULL) {
		with_extensions.extension = finch_sb_extension_covers;
		with_extensions.extension_arg = p->extensions;
	}
	decision = fsb_evaluate(finch_sb_profile_data(p), &with_extensions, scratch, &rule_flags);
	kfree_data(scratch, FSB_SCRATCH_BYTES);
	if (decision == FSB_ALLOW) {
		return 0;
	}
	if (report) {
		finch_sb_report(subject, r, rule_flags);
	}
	return EPERM;
}

/* A request from the current process. */
static int
finch_sb_decide(intptr_t label, const struct fsb_request *r, bool report)
{
	return finch_sb_decide_for(current_proc(), label, r, report);
}

/* ---- building requests ---- */

static uint64_t
finch_sb_vnode_type(vnode_t vp)
{
	switch (vnode_vtype(vp)) {
	case VREG: return FSB_VNODE_REGULAR;
	case VDIR: return FSB_VNODE_DIRECTORY;
	case VBLK: return FSB_VNODE_BLOCK_DEVICE;
	case VCHR: return vnode_istty(vp) ? FSB_VNODE_TTY : FSB_VNODE_CHARACTER_DEVICE;
	case VLNK: return FSB_VNODE_SYMLINK;
	case VSOCK: return FSB_VNODE_SOCKET;
	case VFIFO: return FSB_VNODE_FIFO;
	default: return 0;
	}
}

static uint64_t
finch_sb_file_attributes(vnode_t vp)
{
	uint64_t bits = 0;
	mount_t mp = vnode_mount(vp);

	if (mp != NULL && (vfs_flags(mp) & MNT_UNION)) {
		bits |= FSB_FILE_ATTR_UNION_MOUNTED_FILESYSTEM;
	}
	return bits;
}

static uint64_t
finch_sb_process_attributes(proc_t p)
{
	uint64_t bits = 0;
	uint64_t csflags = proc_getcsflags(p);

	if (csflags & CS_PLATFORM_BINARY) {
		bits |= FSB_PROCESS_ATTR_IS_PLATFORM_BINARY | FSB_PROCESS_ATTR_IS_APPLE_SIGNED;
	}
	if (csflags & CS_RESTRICT) {
		bits |= FSB_PROCESS_ATTR_IS_RESTRICTED;
	}
	return bits;
}

/*
 * A file request: the operation, the vnode's path (or a folder's path and a
 * name in it, for one being created), and its type and attributes.
 * path is a MAXPATHLEN buffer the caller frees.
 */
static int
finch_sb_file_request(struct fsb_request *r, uint32_t op, vnode_t vp,
    vnode_t dvp, struct componentname *cnp, char **path)
{
	int len = MAXPATHLEN;
	char *buf = kalloc_data(MAXPATHLEN, Z_WAITOK);

	*path = buf;
	if (buf == NULL) {
		return ENOMEM;
	}
	fsb_request_init(r, op);
	if (vp != NULLVP && vn_getpath(vp, buf, &len) == 0) {
		fsb_request_string(r, FSB_F_PATH, buf, strnlen(buf, MAXPATHLEN));
	} else if (dvp != NULLVP && cnp != NULL && vn_getpath(dvp, buf, &len) == 0) {
		size_t dlen = strnlen(buf, MAXPATHLEN);
		size_t nlen = (size_t)cnp->cn_namelen;
		if (dlen == 1) {
			dlen = 0;	/* the root folder: "/" + name */
		}
		if (dlen + 1 + nlen < MAXPATHLEN) {
			buf[dlen] = '/';
			memcpy(buf + dlen + 1, cnp->cn_nameptr, nlen);
			buf[dlen + 1 + nlen] = '\0';
			fsb_request_string(r, FSB_F_PATH, buf, dlen + 1 + nlen);
		}
	}
	if (vp != NULLVP) {
		fsb_request_number(r, FSB_F_VNODE_TYPE, finch_sb_vnode_type(vp));
		fsb_request_number(r, FSB_F_FILE_ATTRIBUTES, finch_sb_file_attributes(vp));
	}
	fsb_request_number(r, FSB_F_PROCESS_ATTRIBUTES, finch_sb_process_attributes(current_proc()));
	return 0;
}

/* A file operation under the caller's profile. */
static int
finch_sb_check_file(kauth_cred_t cred, uint32_t op, vnode_t vp, vnode_t dvp,
    struct componentname *cnp)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	char *path;
	int error;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	error = finch_sb_file_request(&r, op, vp, dvp, cnp, &path);
	if (error == 0) {
		error = finch_sb_decide(label, &r, true);
	}
	if (path != NULL) {
		kfree_data(path, MAXPATHLEN);
	}
	return error;
}

/* A request with one string field (sysctl name, shm name, ...). */
static int
finch_sb_check_string(kauth_cred_t cred, uint32_t op, int field, const char *s)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, op);
	if (s != NULL) {
		fsb_request_string(&r, field, s, strnlen(s, MAXPATHLEN));
	}
	fsb_request_number(&r, FSB_F_PROCESS_ATTRIBUTES, finch_sb_process_attributes(current_proc()));
	return finch_sb_decide(label, &r, true);
}

static int
finch_sb_check_op(kauth_cred_t cred, uint32_t op)
{
	return finch_sb_check_string(cred, op, FSB_F_PATH, NULL);
}

/* ---- applying ---- */

static int
finch_sandbox_apply(proc_t p, intptr_t value)
{
	kauth_cred_t cred;
	intptr_t current;
	int error;

	/* Serialize the check and update so two threads cannot both apply. */
	lck_mtx_lock(&finch_sandbox_apply_lock);
	cred = kauth_cred_proc_ref(p);
	if (cred == NOCRED) {
		lck_mtx_unlock(&finch_sandbox_apply_lock);
		return ESRCH;
	}
	current = finch_sb_label(cred);
	kauth_cred_unref(&cred);
	if (current != 0) {
		lck_mtx_unlock(&finch_sandbox_apply_lock);
		return EPERM;
	}

	/*
	 * XNU builds the credential before taking proc_ucred_lock, then swaps
	 * under that lock, retrying from the latest credential if another change
	 * wins. Each model credential built holds its own reference to the profile
	 * (released by cred_label_destroy if XNU discards it).
	 */
	error = kauth_cred_proc_update(p, PROC_SETTOKEN_NONE,
	    ^bool (kauth_cred_t parent, kauth_cred_t model) {
		mac_cred_label_init(model);
		mac_cred_label_associate(parent, model);
		finch_sb_release(mac_label_get(mac_cred_label(model), finch_sandbox_label_slot));
		finch_sb_retain(value);
		mac_label_set(mac_cred_label(model), finch_sandbox_label_slot, value);
		posix_cred_get(model)->cr_flags |= CRF_MAC_ENFORCE;
		return true;
	}) ? 0 : EPERM;
	lck_mtx_unlock(&finch_sandbox_apply_lock);
	return error;
}

static bool
finch_sandbox_reserved_zero(const uint64_t reserved[2])
{
	return reserved[0] == 0 && reserved[1] == 0;
}

static int
finch_sandbox_apply_request(proc_t p, user_addr_t arg)
{
	struct finch_sandbox_apply_request request;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) ||
	    request.flags != 0 || !finch_sandbox_reserved_zero(request.reserved)) {
		return EINVAL;
	}

	switch (request.profile) {
	case FINCH_SANDBOX_PROFILE_DENY_READ:
	case FINCH_SANDBOX_PROFILE_DENY_WRITE:
		return finch_sandbox_apply(p, (intptr_t)request.profile);
	case FINCH_SANDBOX_PROFILE_NOTIFYD:
		/* Retired: notifyd applies its compiled profile with call 0x102. */
		return ENOTSUP;
	default:
		return EINVAL;
	}
}

static int finch_sb_build_unix_mask(struct finch_sb_profile *profile);

/* The number of Unix system calls (<sys/sysent.h>, not exported to security/). */
extern const unsigned int nsysent;

static int
finch_sandbox_profile_request(proc_t p, user_addr_t arg)
{
	struct finch_sandbox_profile_request request;
	struct finch_sb_profile *profile;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) ||
	    request.flags != 0 || request.reserved != 0 || request.profile == 0 ||
	    request.profile_size < sizeof(struct fsb_header) ||
	    request.profile_size > FSB_MAX_SIZE) {
		return EINVAL;
	}
	profile = kalloc_data(sizeof(*profile) + request.profile_size, Z_WAITOK | Z_ZERO);
	if (profile == NULL) {
		return ENOMEM;
	}
	os_ref_init(&profile->ref, &finch_sb_refgrp);
	profile->size = (uint32_t)request.profile_size;
	error = copyin((user_addr_t)request.profile, profile->data, request.profile_size);
	if (error == 0 && fsb_profile_validate(profile->data, profile->size) != 0) {
		error = EINVAL;
	}
	if (error == 0 && (((const struct fsb_header *)profile->data)->flags & FSB_PROFILE_FILTER_SYSCALLS)) {
		error = finch_sb_build_unix_mask(profile);
	}
	if (error == 0) {
		error = finch_sandbox_apply(p, (intptr_t)profile);
	}
	if (error == 0 && profile->unix_mask != NULL) {
		/*
		 * Children inherit the mask at fork, and their credentials the profile
		 * that owns it, so it lives as long as any process using it.
		 */
		error = proc_set_syscall_filter_mask(p, SYSCALL_MASK_UNIX, profile->unix_mask, nsysent);
	}
	/* The credentials hold their own references; drop the one from init. */
	finch_sb_release((intptr_t)profile);
	return error;
}

/*
 * The Unix system calls a (version 2) profile allows without asking: those its
 * syscall-unix rules allow by number alone. The rest are decided per call.
 */
static int
finch_sb_build_unix_mask(struct finch_sb_profile *profile)
{
	struct fsb_request r;
	void *scratch;
	uint32_t bytes = (nsysent + 7) / 8;

	profile->unix_mask = kalloc_data(bytes, Z_WAITOK | Z_ZERO);
	if (profile->unix_mask == NULL) {
		return ENOMEM;
	}
	profile->unix_mask_size = bytes;
	scratch = kalloc_data(FSB_SCRATCH_BYTES, Z_WAITOK);
	if (scratch == NULL) {
		return ENOMEM;
	}
	for (unsigned int n = 0; n < nsysent; n++) {
		fsb_request_init(&r, FSB_OP_SYSCALL_UNIX);
		fsb_request_number(&r, FSB_F_SYSCALL_NUMBER, n);
		if (fsb_evaluate(finch_sb_profile_data(profile), &r, scratch, NULL) == FSB_ALLOW) {
			profile->unix_mask[n >> 3] |= (uint8_t)(1u << (n & 7));
		}
	}
	kfree_data(scratch, FSB_SCRATCH_BYTES);
	return 0;
}

static int
finch_sandbox_proc_check_syscall_unix(struct proc *proc, int scnum)
{
	kauth_cred_t cred = kauth_cred_proc_ref(proc);
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	int error;

	kauth_cred_unref(&cred);
	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, FSB_OP_SYSCALL_UNIX);
	fsb_request_number(&r, FSB_F_SYSCALL_NUMBER, (uint64_t)scnum);
	fsb_request_number(&r, FSB_F_PROCESS_ATTRIBUTES, finch_sb_process_attributes(proc));
	error = finch_sb_decide_for(proc, label, &r, true);
	return error;
}

/* ---- queries ---- */

static int
finch_sandbox_find_target(proc_t caller, int32_t pid, uint32_t pidversion, proc_t *target)
{
	audit_token_t token;

	if (pid == 0 || (pid == proc_pid(caller) &&
	    (pidversion == 0 || pidversion == (uint32_t)proc_pidversion(caller)))) {
		*target = proc_ref(caller, false);
		return *target == PROC_NULL ? ESRCH : 0;
	}
	if (pid < 0) {
		return ESRCH;
	}
	/* Only root may ask about another process. */
	if (!kauth_cred_issuser(kauth_cred_get())) {
		return EPERM;
	}
	if (pidversion == 0) {
		/* sandbox_check(pid, ...): the process with that pid now */
		*target = proc_find(pid);
		return *target == PROC_NULL ? ESRCH : 0;
	}
	bzero(&token, sizeof(token));
	token.val[5] = (uint32_t)pid;
	token.val[7] = pidversion;
	*target = proc_find_audit_token(token);
	if (*target == PROC_NULL) {
		return ESRCH;
	}
	if (proc_pidversion(*target) != (int)pidversion) {
		proc_rele(*target);
		*target = PROC_NULL;
		return ESRCH;
	}
	return 0;
}

static int
finch_sandbox_check_request(proc_t caller, user_addr_t arg)
{
	struct finch_sandbox_check_request request;
	proc_t target = PROC_NULL;
	kauth_cred_t target_cred = NOCRED;
	uint32_t result;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) ||
	    request.flags != 0 || request.result_reserved != 0 ||
	    !finch_sandbox_reserved_zero(request.reserved)) {
		return EINVAL;
	}
	if (request.operation != FINCH_SANDBOX_OP_STATUS &&
	    request.operation != FINCH_SANDBOX_OP_READ_DATA &&
	    request.operation != FINCH_SANDBOX_OP_WRITE_DATA) {
		return EINVAL;
	}
	if (request.target_pid <= 0) {
		return ESRCH;
	}
	/* This older call always names its target, itself included, by pidversion. */
	if (request.target_pid == proc_pid(caller) &&
	    request.target_pidversion != (uint32_t)proc_pidversion(caller)) {
		return ESRCH;
	}
	if (request.target_pid != proc_pid(caller) && request.target_pidversion == 0) {
		return kauth_cred_issuser(kauth_cred_get()) ? ESRCH : EPERM;
	}
	error = finch_sandbox_find_target(caller, request.target_pid,
	    request.target_pidversion, &target);
	if (error != 0) {
		return error;
	}
	target_cred = kauth_cred_proc_ref(target);
	if (target_cred == NOCRED) {
		error = ESRCH;
		goto out;
	}
	/* An exec during the read makes the supplied process identity stale. */
	if (proc_pidversion(target) != (int)request.target_pidversion) {
		error = ESRCH;
		goto out;
	}

	intptr_t label = finch_sb_label(target_cred);
	int fixed = finch_sb_fixed(label);
	switch (request.operation) {
	case FINCH_SANDBOX_OP_STATUS:
		/* The fixed restriction's id; a compiled profile reports as 4. */
		result = fixed ? (uint32_t)fixed : finch_sb_profile_of(label) ? 4u : 0u;
		break;
	case FINCH_SANDBOX_OP_READ_DATA:
		result = fixed == FINCH_SANDBOX_PROFILE_DENY_READ ? FINCH_SANDBOX_RESULT_DENY : 0;
		break;
	case FINCH_SANDBOX_OP_WRITE_DATA:
		result = fixed == FINCH_SANDBOX_PROFILE_DENY_WRITE ? FINCH_SANDBOX_RESULT_DENY : 0;
		break;
	default:
		error = EINVAL;
		goto out;
	}
	error = copyout(&result,
	    arg + offsetof(struct finch_sandbox_check_request, result),
	    sizeof(result));
out:
	if (target_cred != NOCRED) {
		kauth_cred_unref(&target_cred);
	}
	if (target != PROC_NULL) {
		proc_rele(target);
	}
	return error;
}

static int
finch_sandbox_query_request(proc_t caller, user_addr_t arg)
{
	struct finch_sandbox_query_request request;
	struct fsb_request r;
	proc_t target = PROC_NULL;
	kauth_cred_t target_cred = NOCRED;
	char *value = NULL;
	uint32_t result;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) ||
	    (request.flags & ~FINCH_SANDBOX_QUERY_NO_REPORT) != 0 || request.result != 0 ||
	    request.operation >= FSB_OP_COUNT ||
	    (request.field != 0xffffffffu && request.field >= FSB_F_FIELD_MAX) ||
	    (request.field < FSB_F_FIELD_MAX && FSB_F_IS_STRING(request.field) &&
	    request.value_size > MAXPATHLEN)) {
		return EINVAL;
	}
	error = finch_sandbox_find_target(caller, request.target_pid,
	    request.target_pidversion, &target);
	if (error != 0) {
		return error;
	}
	target_cred = kauth_cred_proc_ref(target);
	if (target_cred == NOCRED) {
		error = ESRCH;
		goto out;
	}
	fsb_request_init(&r, request.operation);
	if (request.field != 0xffffffffu) {
		if (FSB_F_IS_STRING(request.field)) {
			value = kalloc_data(request.value_size + 1, Z_WAITOK | Z_ZERO);
			if (value == NULL) {
				error = ENOMEM;
				goto out;
			}
			if (request.value_size > 0) {
				error = copyin((user_addr_t)request.value, value, request.value_size);
				if (error != 0) {
					goto out;
				}
			}
			fsb_request_string(&r, (int)request.field, value,
			    strnlen(value, request.value_size));
		} else {
			fsb_request_number(&r, (int)request.field, request.value);
		}
	}
	fsb_request_number(&r, FSB_F_PROCESS_ATTRIBUTES, finch_sb_process_attributes(target));
	{
		intptr_t label = finch_sb_label(target_cred);
		if (finch_sb_profile_of(label) == NULL) {
			result = FINCH_SANDBOX_QUERY_RESULT_UNSANDBOXED;
		} else {
			/* The report names the process asked about, not the asker. */
			error = finch_sb_decide_for(target, label, &r,
			    (request.flags & FINCH_SANDBOX_QUERY_NO_REPORT) == 0);
			if (error != 0 && error != EPERM) {
				goto out;
			}
			result = error == EPERM ? FINCH_SANDBOX_QUERY_RESULT_DENY :
			    FINCH_SANDBOX_QUERY_RESULT_ALLOW;
			error = 0;
		}
	}
	error = copyout(&result,
	    arg + offsetof(struct finch_sandbox_query_request, result), sizeof(result));
out:
	if (value != NULL) {
		kfree_data(value, request.value_size + 1);
	}
	if (target_cred != NOCRED) {
		kauth_cred_unref(&target_cred);
	}
	if (target != PROC_NULL) {
		proc_rele(target);
	}
	return error;
}


/* ---- sandbox extensions ---- */

/*
 * A token is "MAC;PAYLOAD": PAYLOAD is "type;flags;pid;pidversion;CLASS;DATA"
 * (class and data in hex), MAC its HMAC-SHA256 under a key made at boot, in
 * hex. Only this boot's kernel can make one; any process holding it may
 * consume it, or only the one it was issued to.
 */
static uint8_t finch_sb_extension_key[32];
static int64_t finch_sb_extension_handles;

static void
finch_sb_hmac(const char *message, size_t length, uint8_t mac[SHA256_DIGEST_LENGTH])
{
	uint8_t pad[64], inner[SHA256_DIGEST_LENGTH];
	SHA256_CTX ctx;

	memset(pad, 0x36, sizeof(pad));
	for (size_t i = 0; i < sizeof(finch_sb_extension_key); i++) {
		pad[i] ^= finch_sb_extension_key[i];
	}
	SHA256_Init(&ctx);
	SHA256_Update(&ctx, pad, sizeof(pad));
	SHA256_Update(&ctx, message, length);
	SHA256_Final(inner, &ctx);
	memset(pad, 0x5c, sizeof(pad));
	for (size_t i = 0; i < sizeof(finch_sb_extension_key); i++) {
		pad[i] ^= finch_sb_extension_key[i];
	}
	SHA256_Init(&ctx);
	SHA256_Update(&ctx, pad, sizeof(pad));
	SHA256_Update(&ctx, inner, sizeof(inner));
	SHA256_Final(mac, &ctx);
}

static size_t
finch_sb_hex(char *out, size_t size, const void *bytes, size_t n)
{
	static const char digits[] = "0123456789abcdef";
	const uint8_t *b = bytes;
	if (size < 2 * n + 1) {
		return 0;
	}
	for (size_t i = 0; i < n; i++) {
		out[2 * i] = digits[b[i] >> 4];
		out[2 * i + 1] = digits[b[i] & 15];
	}
	out[2 * n] = '\0';
	return 2 * n;
}

static int
finch_sb_unhex_digit(char c)
{
	return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

/* Hex to bytes (a NUL added): the byte count, or -1. */
static ssize_t
finch_sb_unhex(const char *s, size_t n, char *out, size_t size)
{
	if (n % 2 != 0 || n / 2 + 1 > size) {
		return -1;
	}
	for (size_t i = 0; i < n / 2; i++) {
		int hi = finch_sb_unhex_digit(s[2 * i]), lo = finch_sb_unhex_digit(s[2 * i + 1]);
		if (hi < 0 || lo < 0) {
			return -1;
		}
		out[i] = (char)(hi << 4 | lo);
		if (out[i] == '\0') {
			return -1;
		}
	}
	out[n / 2] = '\0';
	return (ssize_t)(n / 2);
}

/* A class that grants writing ("com.apple.app-sandbox.read-write"). */
static bool
finch_sb_names_write(const char *extension_class)
{
	for (const char *s = extension_class; *s; s++) {
		if (strncmp(s, "write", 5) == 0) {
			return true;
		}
	}
	return false;
}

/* A path resolved as the kernel names files, or a missing file's resolved
   folder and its name (for a file about to be saved). */
static int
finch_sb_resolve_path(const char *path, bool nofollow, char *out)
{
	vfs_context_t ctx = vfs_context_current();
	vnode_t vp = NULLVP;
	int len = MAXPATHLEN;
	int error = vnode_lookup(path, nofollow ? VNODE_LOOKUP_NOFOLLOW : 0, &vp, ctx);

	if (error == 0) {
		error = vn_getpath(vp, out, &len);
		vnode_put(vp);
		return error;
	}
	if (error != ENOENT) {
		return error;
	}
	const char *slash = strrchr(path, '/');
	if (slash == NULL || slash[1] == '\0') {
		return ENOENT;
	}
	char *parent = kalloc_data(MAXPATHLEN, Z_WAITOK);
	if (parent == NULL) {
		return ENOMEM;
	}
	size_t plen = slash == path ? 1 : (size_t)(slash - path);
	memcpy(parent, path, plen);
	parent[plen] = '\0';
	error = vnode_lookup(parent, 0, &vp, ctx);
	if (error == 0) {
		error = vn_getpath(vp, out, &len);
		vnode_put(vp);
	}
	kfree_data(parent, MAXPATHLEN);
	if (error == 0) {
		size_t dlen = strnlen(out, MAXPATHLEN);
		if (dlen + strlen(slash) >= MAXPATHLEN) {
			return ENAMETOOLONG;
		}
		strlcpy(out + (dlen == 1 ? 0 : dlen), slash, MAXPATHLEN - dlen);
	}
	return error;
}

static int
finch_sandbox_extension_issue(proc_t p, user_addr_t arg)
{
	struct finch_sandbox_extension_issue_request request;
	char extension_class[128];
	char *data = NULL, *resolved = NULL, *payload = NULL, *token = NULL;
	size_t done;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) ||
	    (request.type != FINCH_SANDBOX_EXTENSION_FILE && request.type != FINCH_SANDBOX_EXTENSION_MACH &&
	    request.type != FINCH_SANDBOX_EXTENSION_GENERIC) || request.extension_class == 0 ||
	    request.token == 0 || request.token_size == 0) {
		return EINVAL;
	}
	error = copyinstr((user_addr_t)request.extension_class, extension_class, sizeof(extension_class), &done);
	if (error != 0 || extension_class[0] == '\0') {
		return error != 0 ? error : EINVAL;
	}
	data = kalloc_data(MAXPATHLEN, Z_WAITOK | Z_ZERO);
	resolved = kalloc_data(MAXPATHLEN, Z_WAITOK | Z_ZERO);
	payload = kalloc_data(FINCH_SANDBOX_EXTENSION_MAX, Z_WAITOK | Z_ZERO);
	token = kalloc_data(FINCH_SANDBOX_EXTENSION_MAX, Z_WAITOK | Z_ZERO);
	if (data == NULL || resolved == NULL || payload == NULL || token == NULL) {
		error = ENOMEM;
		goto out;
	}
	if (request.type != FINCH_SANDBOX_EXTENSION_GENERIC) {
		if (request.data == 0) {
			error = EINVAL;
			goto out;
		}
		error = copyinstr((user_addr_t)request.data, data, MAXPATHLEN, &done);
		if (error != 0 || data[0] == '\0') {
			error = error != 0 ? error : EINVAL;
			goto out;
		}
	}
	if (request.type == FINCH_SANDBOX_EXTENSION_FILE) {
		if (data[0] != '/') {
			error = EINVAL;
			goto out;
		}
		error = finch_sb_resolve_path(data, (request.flags & FINCH_SANDBOX_EXTENSION_NOFOLLOW) != 0, resolved);
		if (error != 0) {
			goto out;
		}
	} else {
		strlcpy(resolved, data, MAXPATHLEN);
	}

	/* A sandboxed issuer passes on only what it has itself. */
	intptr_t label = finch_sb_current();
	if (finch_sb_profile_of(label) != NULL && request.type != FINCH_SANDBOX_EXTENSION_GENERIC) {
		struct fsb_request r;
		if (request.type == FINCH_SANDBOX_EXTENSION_FILE) {
			fsb_request_init(&r, FSB_OP_FILE_READ_DATA);
			fsb_request_string(&r, FSB_F_PATH, resolved, strnlen(resolved, MAXPATHLEN));
			error = finch_sb_decide(label, &r, true);
			if (error == 0 && finch_sb_names_write(extension_class)) {
				fsb_request_init(&r, FSB_OP_FILE_WRITE_DATA);
				fsb_request_string(&r, FSB_F_PATH, resolved, strnlen(resolved, MAXPATHLEN));
				error = finch_sb_decide(label, &r, true);
			}
		} else {
			fsb_request_init(&r, FSB_OP_MACH_LOOKUP);
			fsb_request_string(&r, FSB_F_GLOBAL_NAME, resolved, strnlen(resolved, MAXPATHLEN));
			error = finch_sb_decide(label, &r, true);
		}
		if (error != 0) {
			goto out;
		}
	}

	int n = scnprintf(payload, FINCH_SANDBOX_EXTENSION_MAX, "%x;%x;%d;%u;", request.type, request.flags,
	    request.target_pid, request.target_pidversion);
	size_t used = (size_t)n;
	size_t h = finch_sb_hex(payload + used, FINCH_SANDBOX_EXTENSION_MAX - used, extension_class,
	    strnlen(extension_class, sizeof(extension_class)));
	if (h == 0 || used + h + 2 >= FINCH_SANDBOX_EXTENSION_MAX) {
		error = ENAMETOOLONG;
		goto out;
	}
	used += h;
	payload[used++] = ';';
	if (request.type != FINCH_SANDBOX_EXTENSION_GENERIC) {
		h = finch_sb_hex(payload + used, FINCH_SANDBOX_EXTENSION_MAX - used, resolved,
		    strnlen(resolved, MAXPATHLEN));
		if (h == 0) {
			error = ENAMETOOLONG;
			goto out;
		}
		used += h;
	}
	payload[used] = '\0';
	uint8_t mac[SHA256_DIGEST_LENGTH];
	finch_sb_hmac(payload, used, mac);
	finch_sb_hex(token, FINCH_SANDBOX_EXTENSION_MAX, mac, sizeof(mac));
	token[2 * sizeof(mac)] = ';';
	if (2 * sizeof(mac) + 1 + used + 1 > FINCH_SANDBOX_EXTENSION_MAX ||
	    2 * sizeof(mac) + 1 + used + 1 > request.token_size) {
		error = ERANGE;
		goto out;
	}
	memcpy(token + 2 * sizeof(mac) + 1, payload, used + 1);
	error = copyout(token, (user_addr_t)request.token, 2 * sizeof(mac) + 1 + used + 1);
out:
	if (data) kfree_data(data, MAXPATHLEN);
	if (resolved) kfree_data(resolved, MAXPATHLEN);
	if (payload) kfree_data(payload, FINCH_SANDBOX_EXTENSION_MAX);
	if (token) kfree_data(token, FINCH_SANDBOX_EXTENSION_MAX);
	(void)p;
	return error;
}

/* A new label: the current one's profile, with these extensions. */
static struct finch_sb_profile *
finch_sb_with_extensions(struct finch_sb_profile *current, struct finch_sb_extensions *set)
{
	struct finch_sb_profile *base = current->shared != NULL ? current->shared : current;
	struct finch_sb_profile *label = kalloc_data(sizeof(*label), Z_WAITOK | Z_ZERO);

	if (label == NULL) {
		return NULL;
	}
	os_ref_init(&label->ref, &finch_sb_refgrp);
	os_ref_retain(&base->ref);
	label->shared = base;
	label->extensions = set;
	return label;
}

/* Swap the process's label from `expected` to `value`; EAGAIN if it changed. */
static int
finch_sandbox_replace(proc_t p, intptr_t expected, intptr_t value)
{
	kauth_cred_t cred;
	int error;

	lck_mtx_lock(&finch_sandbox_apply_lock);
	cred = kauth_cred_proc_ref(p);
	if (cred == NOCRED) {
		lck_mtx_unlock(&finch_sandbox_apply_lock);
		return ESRCH;
	}
	if (finch_sb_label(cred) != expected) {
		kauth_cred_unref(&cred);
		lck_mtx_unlock(&finch_sandbox_apply_lock);
		return EAGAIN;
	}
	kauth_cred_unref(&cred);
	error = kauth_cred_proc_update(p, PROC_SETTOKEN_NONE,
	    ^bool (kauth_cred_t parent, kauth_cred_t model) {
		mac_cred_label_init(model);
		mac_cred_label_associate(parent, model);
		finch_sb_release(mac_label_get(mac_cred_label(model), finch_sandbox_label_slot));
		finch_sb_retain(value);
		mac_label_set(mac_cred_label(model), finch_sandbox_label_slot, value);
		return true;
	}) ? 0 : EPERM;
	lck_mtx_unlock(&finch_sandbox_apply_lock);
	return error;
}

static int
finch_sandbox_extension_consume(proc_t p, user_addr_t arg)
{
	struct finch_sandbox_extension_consume_request request;
	char *token = NULL, *extension_class = NULL, *data = NULL;
	struct finch_sb_extensions *set = NULL;
	size_t done;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request) || request.token == 0) {
		return EINVAL;
	}
	token = kalloc_data(FINCH_SANDBOX_EXTENSION_MAX, Z_WAITOK | Z_ZERO);
	extension_class = kalloc_data(128, Z_WAITOK | Z_ZERO);
	data = kalloc_data(MAXPATHLEN, Z_WAITOK | Z_ZERO);
	if (token == NULL || extension_class == NULL || data == NULL) {
		error = ENOMEM;
		goto out;
	}
	error = copyinstr((user_addr_t)request.token, token, FINCH_SANDBOX_EXTENSION_MAX, &done);
	if (error != 0) {
		goto out;
	}
	/* The MAC first: nothing else in a token is trusted before it checks. */
	size_t length = strnlen(token, FINCH_SANDBOX_EXTENSION_MAX);
	uint8_t mac[SHA256_DIGEST_LENGTH];
	char expected[2 * SHA256_DIGEST_LENGTH + 1];
	if (length < sizeof(expected) || token[2 * SHA256_DIGEST_LENGTH] != ';') {
		error = EINVAL;
		goto out;
	}
	const char *payload = token + sizeof(expected);
	finch_sb_hmac(payload, length - sizeof(expected), mac);
	finch_sb_hex(expected, sizeof(expected), mac, sizeof(mac));
	uint8_t diff = 0;
	for (size_t i = 0; i < 2 * SHA256_DIGEST_LENGTH; i++) {
		diff |= (uint8_t)(expected[i] ^ token[i]);
	}
	if (diff != 0) {
		error = EINVAL;
		goto out;
	}
	/* type;flags;pid;pidversion;CLASS;DATA */
	const char *fields[6];
	size_t lengths[6];
	const char *s = payload;
	for (int i = 0; i < 6; i++) {
		const char *end = i < 5 ? strchr(s, ';') : s + strlen(s);
		if (end == NULL) {
			error = EINVAL;
			goto out;
		}
		fields[i] = s;
		lengths[i] = (size_t)(end - s);
		s = end + (i < 5 ? 1 : 0);
	}
	uint32_t type = (uint32_t)strtoul(fields[0], NULL, 16);
	long target_pid = strtol(fields[2], NULL, 10);
	unsigned long target_pidversion = strtoul(fields[3], NULL, 10);
	if (target_pid != 0 && (target_pid != proc_pid(p) ||
	    (target_pidversion != 0 && target_pidversion != (unsigned long)proc_pidversion(p)))) {
		error = EPERM;	/* issued to another process */
		goto out;
	}
	ssize_t class_len = finch_sb_unhex(fields[4], lengths[4], extension_class, 128);
	ssize_t data_len = finch_sb_unhex(fields[5], lengths[5], data, MAXPATHLEN);
	if (class_len <= 0 || data_len < 0) {
		error = EINVAL;
		goto out;
	}

	int64_t handle = os_atomic_inc(&finch_sb_extension_handles, relaxed);
	for (int attempt = 0; attempt < 8; attempt++) {
		intptr_t label = finch_sb_current();
		struct finch_sb_profile *current = finch_sb_profile_of(label);
		if (current == NULL) {
			/* Nothing to widen: an unsandboxed process may do it all already. */
			error = 0;
			break;
		}
		uint32_t old = current->extensions ? current->extensions->count : 0;
		if (old >= 1024) {
			error = ENOSPC;
			break;
		}
		set = kalloc_type(struct finch_sb_extensions, struct finch_sb_extension, old + 1, Z_WAITOK | Z_ZERO);
		if (set == NULL) {
			error = ENOMEM;
			break;
		}
		os_ref_init(&set->ref, &finch_sb_refgrp);
		set->count = old + 1;
		bool copied = true;
		for (uint32_t i = 0; i < old + 1; i++) {
			const struct finch_sb_extension *from = i < old ? &current->extensions->e[i] : NULL;
			struct finch_sb_extension *to = &set->e[i];
			to->handle = from ? from->handle : handle;
			to->type = from ? from->type : type;
			to->class_len = from ? from->class_len : (uint32_t)class_len;
			to->data_len = from ? from->data_len : (uint32_t)data_len;
			to->extension_class = kalloc_data(to->class_len + 1, Z_WAITOK | Z_ZERO);
			to->data = kalloc_data(to->data_len + 1, Z_WAITOK | Z_ZERO);
			if (to->extension_class == NULL || to->data == NULL) {
				copied = false;
				continue;
			}
			memcpy(to->extension_class, from ? from->extension_class : extension_class, to->class_len);
			memcpy(to->data, from ? from->data : data, to->data_len);
		}
		if (!copied) {
			finch_sb_extensions_release(set);
			set = NULL;
			error = ENOMEM;
			break;
		}
		struct finch_sb_profile *next = finch_sb_with_extensions(current, set);
		if (next == NULL) {
			finch_sb_extensions_release(set);
			set = NULL;
			error = ENOMEM;
			break;
		}
		set = NULL;	/* the new label owns it */
		error = finch_sandbox_replace(p, label, (intptr_t)next);
		finch_sb_release((intptr_t)next);	/* the credential holds its own reference */
		if (error != EAGAIN) {
			break;
		}
	}
	if (error == 0) {
		request.handle = handle;
		error = copyout(&request, arg, sizeof(request));
	}
out:
	if (token) kfree_data(token, FINCH_SANDBOX_EXTENSION_MAX);
	if (extension_class) kfree_data(extension_class, 128);
	if (data) kfree_data(data, MAXPATHLEN);
	return error;
}

static int
finch_sandbox_extension_release(proc_t p, user_addr_t arg)
{
	struct finch_sandbox_extension_release_request request;
	int error;

	if (arg == USER_ADDR_NULL) {
		return EINVAL;
	}
	error = copyin(arg, &request, sizeof(request));
	if (error != 0) {
		return error;
	}
	if (request.version != FINCH_SANDBOX_ABI_VERSION || request.size != sizeof(request)) {
		return EINVAL;
	}
	for (int attempt = 0; attempt < 8; attempt++) {
		intptr_t label = finch_sb_current();
		struct finch_sb_profile *current = finch_sb_profile_of(label);
		if (current == NULL) {
			return 0;
		}
		uint32_t old = current->extensions ? current->extensions->count : 0, at = old;
		for (uint32_t i = 0; i < old; i++) {
			if (current->extensions->e[i].handle == request.handle) {
				at = i;
			}
		}
		if (at == old) {
			return ENOENT;
		}
		struct finch_sb_extensions *set = NULL;
		if (old > 1) {
			set = kalloc_type(struct finch_sb_extensions, struct finch_sb_extension, old - 1, Z_WAITOK | Z_ZERO);
			if (set == NULL) {
				return ENOMEM;
			}
			os_ref_init(&set->ref, &finch_sb_refgrp);
			set->count = old - 1;
			for (uint32_t i = 0, j = 0; i < old; i++) {
				const struct finch_sb_extension *from = &current->extensions->e[i];
				if (i == at) {
					continue;
				}
				struct finch_sb_extension *to = &set->e[j++];
				*to = *from;
				to->extension_class = kalloc_data(from->class_len + 1, Z_WAITOK | Z_ZERO);
				to->data = kalloc_data(from->data_len + 1, Z_WAITOK | Z_ZERO);
				if (to->extension_class == NULL || to->data == NULL) {
					finch_sb_extensions_release(set);
					return ENOMEM;
				}
				memcpy(to->extension_class, from->extension_class, from->class_len);
				memcpy(to->data, from->data, from->data_len);
			}
		}
		struct finch_sb_profile *next = finch_sb_with_extensions(current, set);
		if (next == NULL) {
			finch_sb_extensions_release(set);
			return ENOMEM;
		}
		error = finch_sandbox_replace(p, label, (intptr_t)next);
		finch_sb_release((intptr_t)next);
		if (error != EAGAIN) {
			return error;
		}
	}
	return EAGAIN;
}

static int
finch_sandbox_policy_syscall(proc_t p, int call, user_addr_t arg)
{
	switch (call) {
	case FINCH_SANDBOX_CALL_APPLY:
		return finch_sandbox_apply_request(p, arg);
	case FINCH_SANDBOX_CALL_CHECK:
		return finch_sandbox_check_request(p, arg);
	case FINCH_SANDBOX_CALL_APPLY_PROFILE:
		return finch_sandbox_profile_request(p, arg);
	case FINCH_SANDBOX_CALL_QUERY:
		return finch_sandbox_query_request(p, arg);
	case FINCH_SANDBOX_CALL_EXTENSION_ISSUE:
		return finch_sandbox_extension_issue(p, arg);
	case FINCH_SANDBOX_CALL_EXTENSION_CONSUME:
		return finch_sandbox_extension_consume(p, arg);
	case FINCH_SANDBOX_CALL_EXTENSION_RELEASE:
		return finch_sandbox_extension_release(p, arg);
	case FINCH_SANDBOX_PROFILE_DENY_READ:
	case FINCH_SANDBOX_PROFILE_DENY_WRITE:
		if (arg != USER_ADDR_NULL) {
			return EINVAL;
		}
		/* The original fixed-profile proof calls keep working unchanged. */
		return finch_sandbox_apply(p, call);
	default:
		return EINVAL;
	}
}

/* ---- credential labels ---- */

static void
finch_sandbox_cred_label_init(struct label *label)
{
	mac_label_set(label, finch_sandbox_label_slot, 0);
}

static void
finch_sandbox_cred_label_destroy(struct label *label)
{
	finch_sb_release(mac_label_get(label, finch_sandbox_label_slot));
	mac_label_set(label, finch_sandbox_label_slot, 0);
}

static int
finch_sandbox_cred_label_internalize(struct label *label,
    char *element_name __unused, char *element_data)
{
	/* User label updates may request only the empty state. */
	if (strcmp(element_data, "0") != 0) {
		return EINVAL;
	}
	finch_sb_release(mac_label_get(label, finch_sandbox_label_slot));
	mac_label_set(label, finch_sandbox_label_slot, 0);
	return 0;
}

static int
finch_sandbox_cred_check_label_update(kauth_cred_t cred,
    struct label *new_label)
{
	/* A user label update must never set, change, or clear the sandbox. */
	if (finch_sb_label(cred) != 0 ||
	    mac_label_get(new_label, finch_sandbox_label_slot) != 0) {
		return EPERM;
	}
	return 0;
}

static void
finch_sandbox_cred_label_associate(kauth_cred_t parent_cred,
    kauth_cred_t child_cred)
{
	intptr_t v = finch_sb_label(parent_cred);
	intptr_t old = mac_label_get(mac_cred_label(child_cred), finch_sandbox_label_slot);

	finch_sb_retain(v);
	mac_label_set(mac_cred_label(child_cred), finch_sandbox_label_slot, v);
	finch_sb_release(old);
}

static void
finch_sandbox_cred_label_update(kauth_cred_t cred,
    struct label *new_label)
{
	intptr_t v = mac_label_get(new_label, finch_sandbox_label_slot);
	intptr_t old;

	/* Zero never erases a sandbox copied from the old credential. */
	if (v == 0) {
		return;
	}
	old = mac_label_get(mac_cred_label(cred), finch_sandbox_label_slot);
	finch_sb_retain(v);
	mac_label_set(mac_cred_label(cred), finch_sandbox_label_slot, v);
	finch_sb_release(old);
}

/* ---- the fixed restrictions (the first proof) ---- */

/* The current-process check also protects descriptors opened before apply. */
static int
finch_sandbox_fixed_io(kauth_cred_t active_cred)
{
	int fixed = finch_sb_fixed(finch_sb_current());

	if (IS_VALID_CRED(active_cred)) {
		fixed |= finch_sb_fixed(finch_sb_label(active_cred));
	}
	return fixed;
}

/* ---- file hooks ---- */

static int
finch_sandbox_vnode_check_open(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, int acc_mode)
{
	int fixed = finch_sb_fixed(finch_sb_current());
	int error = 0;

	if (fixed == FINCH_SANDBOX_PROFILE_DENY_READ && (acc_mode & FREAD)) {
		return EACCES;
	}
	if (fixed == FINCH_SANDBOX_PROFILE_DENY_WRITE && (acc_mode & FWRITE)) {
		return EACCES;
	}
	if (acc_mode & FREAD) {
		error = finch_sb_check_file(cred, FSB_OP_FILE_READ_DATA, vp, NULLVP, NULL);
	}
	if (error == 0 && (acc_mode & FWRITE)) {
		error = finch_sb_check_file(cred, FSB_OP_FILE_WRITE_DATA, vp, NULLVP, NULL);
	}
	return error;
}

static int
finch_sandbox_vnode_check_read(kauth_cred_t active_cred,
    kauth_cred_t file_cred __unused, struct vnode *vp __unused,
    struct label *label __unused)
{
	/* Profiles decide at open, as macOS's do; reads of open files only obey
	   the fixed restriction. */
	return (finch_sandbox_fixed_io(active_cred) &
	    FINCH_SANDBOX_PROFILE_DENY_READ) != 0 ? EACCES : 0;
}

static int
finch_sandbox_vnode_check_write(kauth_cred_t active_cred,
    kauth_cred_t file_cred __unused, struct vnode *vp __unused,
    struct label *label __unused)
{
	return (finch_sandbox_fixed_io(active_cred) &
	    FINCH_SANDBOX_PROFILE_DENY_WRITE) != 0 ? EACCES : 0;
}

static int
finch_sandbox_vnode_check_create(kauth_cred_t cred, struct vnode *dvp,
    struct label *dlabel __unused, struct componentname *cnp,
    struct vnode_attr *vap __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_CREATE, NULLVP, dvp, cnp);
}

static int
finch_sandbox_vnode_check_unlink(kauth_cred_t cred, struct vnode *dvp __unused,
    struct label *dlabel __unused, struct vnode *vp, struct label *label __unused,
    struct componentname *cnp __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_UNLINK, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_rename(kauth_cred_t cred, struct vnode *fdvp __unused,
    struct label *fdlabel __unused, struct vnode *fvp, struct label *flabel __unused,
    struct componentname *fcnp __unused, struct vnode *tdvp, struct label *tdlabel __unused,
    struct vnode *tvp, struct label *tlabel __unused, struct componentname *tcnp)
{
	/* Moving a file away unlinks its old name and creates the new one. */
	int error = finch_sb_check_file(cred, FSB_OP_FILE_WRITE_UNLINK, fvp, NULLVP, NULL);
	if (error == 0) {
		error = finch_sb_check_file(cred, FSB_OP_FILE_WRITE_CREATE, NULLVP, tdvp, tcnp);
	}
	if (error == 0 && tvp != NULLVP) {
		error = finch_sb_check_file(cred, FSB_OP_FILE_WRITE_UNLINK, tvp, NULLVP, NULL);
	}
	return error;
}

static int
finch_sandbox_vnode_check_link(kauth_cred_t cred, struct vnode *dvp,
    struct label *dlabel __unused, struct vnode *vp, struct label *label __unused,
    struct componentname *cnp)
{
	int error = finch_sb_check_file(cred, FSB_OP_FILE_LINK, vp, NULLVP, NULL);
	if (error == 0) {
		error = finch_sb_check_file(cred, FSB_OP_FILE_WRITE_CREATE, NULLVP, dvp, cnp);
	}
	return error;
}

static int
finch_sandbox_vnode_check_stat(struct ucred *active_cred,
    struct ucred *file_cred __unused, struct vnode *vp, struct label *label __unused)
{
	return finch_sb_check_file(active_cred, FSB_OP_FILE_READ_METADATA, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_getattrlist(kauth_cred_t cred, struct vnode *vp,
    struct label *vlabel __unused, struct attrlist *alist __unused, uint64_t options __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_READ_METADATA, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_readlink(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_READ_METADATA, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_readdir(kauth_cred_t cred, struct vnode *dvp,
    struct label *dlabel __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_READ_DATA, dvp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_truncate(kauth_cred_t active_cred,
    kauth_cred_t file_cred __unused, struct vnode *vp, struct label *label __unused)
{
	return finch_sb_check_file(active_cred, FSB_OP_FILE_WRITE_DATA, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_setmode(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, mode_t mode __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_MODE, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_setowner(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, uid_t uid __unused, gid_t gid __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_OWNER, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_setutimes(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, struct timespec atime __unused,
    struct timespec mtime __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_TIMES, vp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_setflags(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, u_long flags __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_WRITE_FLAGS, vp, NULLVP, NULL);
}

/* xattr operations name the attribute too */
static int
finch_sb_check_xattr(kauth_cred_t cred, uint32_t op, struct vnode *vp, const char *name)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	char *path;
	int error;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	error = finch_sb_file_request(&r, op, vp, NULLVP, NULL, &path);
	if (error == 0) {
		if (name != NULL) {
			fsb_request_string(&r, FSB_F_XATTR, name, strnlen(name, 256));
		}
		error = finch_sb_decide(label, &r, true);
	}
	if (path != NULL) {
		kfree_data(path, MAXPATHLEN);
	}
	return error;
}

static int
finch_sandbox_vnode_check_setextattr(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, const char *name, struct uio *uio __unused)
{
	return finch_sb_check_xattr(cred, FSB_OP_FILE_WRITE_XATTR, vp, name);
}

static int
finch_sandbox_vnode_check_deleteextattr(kauth_cred_t cred, struct vnode *vp,
    struct label *vlabel __unused, const char *name)
{
	return finch_sb_check_xattr(cred, FSB_OP_FILE_WRITE_XATTR, vp, name);
}

static int
finch_sandbox_vnode_check_getextattr(kauth_cred_t cred, struct vnode *vp,
    struct label *label __unused, const char *name, struct uio *uio __unused)
{
	return finch_sb_check_xattr(cred, FSB_OP_FILE_READ_XATTR, vp, name);
}

static int
finch_sandbox_vnode_check_listextattr(kauth_cred_t cred, struct vnode *vp,
    struct label *vlabel __unused)
{
	return finch_sb_check_xattr(cred, FSB_OP_FILE_READ_XATTR, vp, NULL);
}

static int
finch_sandbox_vnode_check_ioctl(kauth_cred_t cred, struct vnode *vp,
    struct label *vlabel __unused, unsigned long cmd)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	char *path;
	int error;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	error = finch_sb_file_request(&r, FSB_OP_FILE_IOCTL, vp, NULLVP, NULL, &path);
	if (error == 0) {
		fsb_request_number(&r, FSB_F_IOCTL_COMMAND, (uint64_t)cmd);
		error = finch_sb_decide(label, &r, true);
	}
	if (path != NULL) {
		kfree_data(path, MAXPATHLEN);
	}
	return error;
}

static int
finch_sandbox_vnode_check_chroot(kauth_cred_t cred, struct vnode *dvp,
    struct label *dlabel __unused, struct componentname *cnp __unused)
{
	return finch_sb_check_file(cred, FSB_OP_FILE_CHROOT, dvp, NULLVP, NULL);
}

static int
finch_sandbox_vnode_check_exec(kauth_cred_t cred, struct vnode *vp,
    struct vnode *scriptvp, struct label *vnodelabel __unused,
    struct label *scriptlabel __unused, struct label *execlabel __unused,
    struct componentname *cnp __unused, u_int *csflags __unused,
    void *macpolicyattr __unused, size_t macpolicyattrlen __unused)
{
	int error = finch_sb_check_file(cred, FSB_OP_PROCESS_EXEC_ALL, vp, NULLVP, NULL);
	if (error == 0 && scriptvp != NULLVP) {
		error = finch_sb_check_file(cred, FSB_OP_PROCESS_EXEC_INTERPRETER, scriptvp, NULLVP, NULL);
	}
	return error;
}

static int
finch_sandbox_file_check_mmap(kauth_cred_t cred, struct fileglob *fg,
    struct label *label __unused, int prot, int flags __unused,
    uint64_t file_pos __unused, int *maxprot)
{
	int fixed = finch_sb_fixed(finch_sb_current());

	/*
	 * The fixed restrictions: XNU's mprotect check only sees an address
	 * range, not the backing file. Block all file mappings for deny-read,
	 * including PROT_NONE mappings that could later be upgraded. For
	 * deny-write, remove write from maxprot so a read-only mapping cannot
	 * gain write access through a later mprotect.
	 */
	if (fixed == FINCH_SANDBOX_PROFILE_DENY_READ) {
		return EACCES;
	}
	if (fixed == FINCH_SANDBOX_PROFILE_DENY_WRITE) {
		*maxprot &= ~VM_PROT_WRITE;
		if ((prot & VM_PROT_WRITE) != 0) {
			return EACCES;
		}
	}
	/* Profiles: mapping a file executable is its own operation. */
	if ((prot & VM_PROT_EXECUTE) != 0 && finch_sb_profile_of(finch_sb_label(cred)) != NULL &&
	    fg != NULL && fg->fg_ops != NULL && FILEGLOB_DTYPE(fg) == DTYPE_VNODE) {
		return finch_sb_check_file(cred, FSB_OP_FILE_MAP_EXECUTABLE,
		    (vnode_t)fg_get_data(fg), NULLVP, NULL);
	}
	return 0;
}

/* ---- processes ---- */

static int
finch_sandbox_proc_check_fork(kauth_cred_t cred, struct proc *proc __unused)
{
	return finch_sb_check_op(cred, FSB_OP_PROCESS_FORK);
}

/* How the target relates to the caller, as (target ...) filters ask. */
static uint64_t
finch_sb_target_relation(proc_t caller, proc_t target, intptr_t caller_label)
{
	uint64_t bits;

	if (target == caller) {
		return FSB_TARGET_SELF;
	}
	bits = FSB_TARGET_OTHERS;
	if (proc_ppid(target) == proc_pid(caller)) {
		bits |= FSB_TARGET_CHILDREN;
	}
	if (proc_ppid(caller) == proc_pid(target)) {
		bits |= FSB_TARGET_PARENT;
	}
	if (caller_label != 0) {
		kauth_cred_t tc = kauth_cred_proc_ref(target);
		if (tc != NOCRED) {
			if (finch_sb_label(tc) == caller_label) {
				bits |= FSB_TARGET_SAME_SANDBOX;
			}
			kauth_cred_unref(&tc);
		}
	}
	return bits;
}

static int
finch_sandbox_proc_check_signal(kauth_cred_t cred, proc_ident_t instigator __unused,
    proc_ident_t target, int signum __unused)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	proc_t tp;
	int error;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	tp = proc_find_ident(target);
	if (tp == PROC_NULL) {
		return 0;	/* gone: the signal fails for that reason */
	}
	fsb_request_init(&r, FSB_OP_SIGNAL);
	fsb_request_number(&r, FSB_F_TARGET, finch_sb_target_relation(current_proc(), tp, label));
	error = finch_sb_decide(label, &r, true);
	proc_rele(tp);
	return error;
}

/* proc_info's call numbers (<sys/proc_info_private.h>, which pulls in the
   network stack's private headers). */
#define FINCH_PROC_INFO_CALL_LISTPIDS		0x1
#define FINCH_PROC_INFO_CALL_PIDINFO		0x2
#define FINCH_PROC_INFO_CALL_PIDFDINFO		0x3
#define FINCH_PROC_INFO_CALL_SETCONTROL		0x5
#define FINCH_PROC_INFO_CALL_PIDFILEPORTINFO	0x6
#define FINCH_PROC_INFO_CALL_DIRTYCONTROL	0x8
#define FINCH_PROC_INFO_CALL_PIDRUSAGE		0x9

static uint32_t
finch_sb_proc_info_op(int callnum)
{
	switch (callnum) {
	case FINCH_PROC_INFO_CALL_LISTPIDS: return FSB_OP_PROCESS_INFO_LISTPIDS;
	case FINCH_PROC_INFO_CALL_PIDINFO: return FSB_OP_PROCESS_INFO_PIDINFO;
	case FINCH_PROC_INFO_CALL_PIDFDINFO: return FSB_OP_PROCESS_INFO_PIDFDINFO;
	case FINCH_PROC_INFO_CALL_SETCONTROL: return FSB_OP_PROCESS_INFO_SETCONTROL;
	case FINCH_PROC_INFO_CALL_PIDFILEPORTINFO: return FSB_OP_PROCESS_INFO_PIDFILEPORTINFO;
	case FINCH_PROC_INFO_CALL_DIRTYCONTROL: return FSB_OP_PROCESS_INFO_DIRTYCONTROL;
	case FINCH_PROC_INFO_CALL_PIDRUSAGE: return FSB_OP_PROCESS_INFO_RUSAGE;
	default: return FSB_OP_PROCESS_INFO_ALL;
	}
}

static int
finch_sandbox_proc_check_proc_info(kauth_cred_t cred, struct proc *target,
    int callnum, int flavor __unused)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, finch_sb_proc_info_op(callnum));
	if (target != PROC_NULL) {
		fsb_request_number(&r, FSB_F_TARGET,
		    finch_sb_target_relation(current_proc(), target, label));
	}
	return finch_sb_decide(label, &r, true);
}

static int
finch_sandbox_proc_check_map_anon(struct proc *proc __unused, kauth_cred_t cred,
    user_addr_t u_addr __unused, user_size_t u_size __unused, int prot __unused,
    int flags, int *maxprot __unused)
{
	if ((flags & MAP_JIT) == 0) {
		return 0;
	}
	return finch_sb_check_op(cred, FSB_OP_DYNAMIC_CODE_GENERATION);
}

/* ---- system ---- */

static int
finch_sandbox_system_check_sysctlbyname(kauth_cred_t cred, const char *namestring,
    int *name __unused, size_t namelen __unused, user_addr_t old __unused,
    size_t oldlen __unused, user_addr_t newvalue, size_t newlen __unused)
{
	int error = 0;

	if (finch_sb_profile_of(finch_sb_label(cred)) == NULL) {
		return 0;
	}
	if (old != USER_ADDR_NULL || newvalue == USER_ADDR_NULL) {
		error = finch_sb_check_string(cred, FSB_OP_SYSCTL_READ, FSB_F_SYSCTL_NAME, namestring);
	}
	if (error == 0 && newvalue != USER_ADDR_NULL) {
		error = finch_sb_check_string(cred, FSB_OP_SYSCTL_WRITE, FSB_F_SYSCTL_NAME, namestring);
	}
	return error;
}

static int
finch_sandbox_system_check_reboot(kauth_cred_t cred, int howto __unused)
{
	return finch_sb_check_op(cred, FSB_OP_SYSTEM_REBOOT);
}

static int
finch_sandbox_system_check_settime(kauth_cred_t cred)
{
	return finch_sb_check_op(cred, FSB_OP_SYSTEM_SET_TIME);
}

static int
finch_sandbox_priv_check(kauth_cred_t cred, int priv)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, FSB_OP_SYSTEM_PRIVILEGE);
	fsb_request_number(&r, FSB_F_PRIVILEGE_ID, (uint64_t)(int64_t)priv);
	/* Privilege checks are frequent and often expected to fail: no report. */
	return finch_sb_decide(label, &r, false);
}

/* ---- POSIX IPC ---- */

static int
finch_sandbox_posixshm_check_create(kauth_cred_t cred, const char *name)
{
	return finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SHM_WRITE_CREATE,
	    FSB_F_IPC_POSIX_NAME, name);
}

static int
finch_sandbox_posixshm_check_open(kauth_cred_t cred, struct pshminfo *ps,
    struct label *shmlabel __unused, int fflags)
{
	int error = 0;

	if (fflags & FREAD) {
		error = finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SHM_READ_DATA,
		    FSB_F_IPC_POSIX_NAME, ps->pshm_name);
	}
	if (error == 0 && (fflags & FWRITE)) {
		error = finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SHM_WRITE_DATA,
		    FSB_F_IPC_POSIX_NAME, ps->pshm_name);
	}
	return error;
}

static int
finch_sandbox_posixshm_check_unlink(kauth_cred_t cred, struct pshminfo *ps __unused,
    struct label *shmlabel __unused, const char *name)
{
	return finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SHM_WRITE_UNLINK,
	    FSB_F_IPC_POSIX_NAME, name);
}

static int
finch_sandbox_posixsem_check_create(kauth_cred_t cred, const char *name)
{
	return finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SEM_CREATE,
	    FSB_F_IPC_POSIX_NAME, name);
}

static int
finch_sandbox_posixsem_check_unlink(kauth_cred_t cred, struct pseminfo *ps __unused,
    struct label *semlabel __unused, const char *name)
{
	return finch_sb_check_string(cred, FSB_OP_IPC_POSIX_SEM_UNLINK,
	    FSB_F_IPC_POSIX_NAME, name);
}

/* ---- sockets ---- */

static int
finch_sandbox_socket_check_create(kauth_cred_t cred, int domain, int type, int protocol)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, FSB_OP_SYSTEM_SOCKET);
	fsb_request_number(&r, FSB_F_SOCKET_DOMAIN, (uint64_t)domain);
	fsb_request_number(&r, FSB_F_SOCKET_TYPE, (uint64_t)type);
	fsb_request_number(&r, FSB_F_SOCKET_PROTOCOL, (uint64_t)protocol);
	return finch_sb_decide(label, &r, true);
}

/*
 * A socket address as the network filters see it: a UNIX socket's path, or
 * "host:port" for an IP one ("localhost" for a loopback address).
 */
static int
finch_sb_check_socket(kauth_cred_t cred, uint32_t op, int remote_field,
    struct sockaddr *addr)
{
	intptr_t label = finch_sb_label(cred);
	struct fsb_request r;
	char buf[MAX(sizeof(((struct sockaddr_un *)0)->sun_path) + 1, 64)];

	if (finch_sb_profile_of(label) == NULL) {
		return 0;
	}
	fsb_request_init(&r, op);
	if (addr != NULL && addr->sa_family == AF_UNIX) {
		struct sockaddr_un *un = (struct sockaddr_un *)addr;
		size_t n = strnlen(un->sun_path, sizeof(un->sun_path));
		memcpy(buf, un->sun_path, n);
		buf[n] = '\0';
		fsb_request_string(&r, FSB_F_PATH, buf, n);
	} else if (addr != NULL && addr->sa_family == AF_INET) {
		struct sockaddr_in *in = (struct sockaddr_in *)addr;
		uint32_t a = ntohl(in->sin_addr.s_addr);
		int n;
		if ((a >> 24) == 127) {
			n = scnprintf(buf, sizeof(buf), "localhost:%u", ntohs(in->sin_port));
		} else {
			n = scnprintf(buf, sizeof(buf), "%u.%u.%u.%u:%u", a >> 24, (a >> 16) & 0xff,
			    (a >> 8) & 0xff, a & 0xff, ntohs(in->sin_port));
		}
		fsb_request_string(&r, remote_field, buf, (size_t)n);
	} else if (addr != NULL && addr->sa_family == AF_INET6) {
		struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
		int n = IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr) ?
		    scnprintf(buf, sizeof(buf), "localhost:%u", ntohs(in6->sin6_port)) :
		    scnprintf(buf, sizeof(buf), "*:%u", ntohs(in6->sin6_port));
		fsb_request_string(&r, remote_field, buf, (size_t)n);
	}
	if (addr != NULL) {
		fsb_request_number(&r, FSB_F_SOCKET_DOMAIN, (uint64_t)addr->sa_family);
	}
	return finch_sb_decide(label, &r, true);
}

static int
finch_sandbox_socket_check_connect(kauth_cred_t cred, socket_t so __unused,
    struct label *socklabel __unused, struct sockaddr *addr)
{
	return finch_sb_check_socket(cred, FSB_OP_NETWORK_OUTBOUND, FSB_F_REMOTE, addr);
}

static int
finch_sandbox_socket_check_bind(kauth_cred_t cred, socket_t so __unused,
    struct label *socklabel __unused, struct sockaddr *addr)
{
	return finch_sb_check_socket(cred, FSB_OP_NETWORK_BIND, FSB_F_LOCAL, addr);
}

static int
finch_sandbox_socket_check_listen(kauth_cred_t cred, socket_t so __unused,
    struct label *socklabel __unused)
{
	return finch_sb_check_socket(cred, FSB_OP_NETWORK_INBOUND, FSB_F_LOCAL, NULL);
}

/* ---- IOKit ---- */

/* FinchSandboxIOKit.cpp; io_object_t is an OSObject in the kernel */
extern const char *finch_sandbox_iokit_class_name(io_object_t object);

static int
finch_sandbox_iokit_check_open(kauth_cred_t cred, io_object_t user_client,
    unsigned int user_client_type __unused)
{
	return finch_sb_check_string(cred, FSB_OP_IOKIT_OPEN_USER_CLIENT,
	    FSB_F_IOKIT_USER_CLIENT_CLASS, finch_sandbox_iokit_class_name(user_client));
}

static int
finch_sandbox_iokit_check_open_service(kauth_cred_t cred, io_object_t service,
    unsigned int user_client_type __unused)
{
	return finch_sb_check_string(cred, FSB_OP_IOKIT_OPEN_SERVICE,
	    FSB_F_IOKIT_REGISTRY_ENTRY_CLASS, finch_sandbox_iokit_class_name(service));
}

static struct mac_policy_ops finch_sandbox_policy_ops = {
	.mpo_policy_syscall = finch_sandbox_policy_syscall,
	.mpo_cred_label_init = finch_sandbox_cred_label_init,
	.mpo_cred_label_destroy = finch_sandbox_cred_label_destroy,
	.mpo_cred_label_associate = finch_sandbox_cred_label_associate,
	.mpo_cred_check_label_update = finch_sandbox_cred_check_label_update,
	.mpo_cred_label_internalize = finch_sandbox_cred_label_internalize,
	.mpo_cred_label_update = finch_sandbox_cred_label_update,
	.mpo_vnode_check_open = finch_sandbox_vnode_check_open,
	.mpo_vnode_check_read = finch_sandbox_vnode_check_read,
	.mpo_vnode_check_write = finch_sandbox_vnode_check_write,
	.mpo_vnode_check_create = finch_sandbox_vnode_check_create,
	.mpo_vnode_check_unlink = finch_sandbox_vnode_check_unlink,
	.mpo_vnode_check_rename = finch_sandbox_vnode_check_rename,
	.mpo_vnode_check_link = finch_sandbox_vnode_check_link,
	.mpo_vnode_check_stat = finch_sandbox_vnode_check_stat,
	.mpo_vnode_check_getattrlist = finch_sandbox_vnode_check_getattrlist,
	.mpo_vnode_check_readlink = finch_sandbox_vnode_check_readlink,
	.mpo_vnode_check_readdir = finch_sandbox_vnode_check_readdir,
	.mpo_vnode_check_truncate = finch_sandbox_vnode_check_truncate,
	.mpo_vnode_check_setmode = finch_sandbox_vnode_check_setmode,
	.mpo_vnode_check_setowner = finch_sandbox_vnode_check_setowner,
	.mpo_vnode_check_setutimes = finch_sandbox_vnode_check_setutimes,
	.mpo_vnode_check_setflags = finch_sandbox_vnode_check_setflags,
	.mpo_vnode_check_setextattr = finch_sandbox_vnode_check_setextattr,
	.mpo_vnode_check_deleteextattr = finch_sandbox_vnode_check_deleteextattr,
	.mpo_vnode_check_getextattr = finch_sandbox_vnode_check_getextattr,
	.mpo_vnode_check_listextattr = finch_sandbox_vnode_check_listextattr,
	.mpo_vnode_check_ioctl = finch_sandbox_vnode_check_ioctl,
	.mpo_vnode_check_chroot = finch_sandbox_vnode_check_chroot,
	.mpo_vnode_check_exec = finch_sandbox_vnode_check_exec,
	.mpo_file_check_mmap = finch_sandbox_file_check_mmap,
	.mpo_proc_check_fork = finch_sandbox_proc_check_fork,
	.mpo_proc_check_signal = finch_sandbox_proc_check_signal,
	.mpo_proc_check_proc_info = finch_sandbox_proc_check_proc_info,
	.mpo_proc_check_map_anon = finch_sandbox_proc_check_map_anon,
	.mpo_proc_check_syscall_unix = finch_sandbox_proc_check_syscall_unix,
	.mpo_system_check_sysctlbyname = finch_sandbox_system_check_sysctlbyname,
	.mpo_system_check_reboot = finch_sandbox_system_check_reboot,
	.mpo_system_check_settime = finch_sandbox_system_check_settime,
	.mpo_priv_check = finch_sandbox_priv_check,
	.mpo_posixshm_check_create = finch_sandbox_posixshm_check_create,
	.mpo_posixshm_check_open = finch_sandbox_posixshm_check_open,
	.mpo_posixshm_check_unlink = finch_sandbox_posixshm_check_unlink,
	.mpo_posixsem_check_create = finch_sandbox_posixsem_check_create,
	.mpo_posixsem_check_unlink = finch_sandbox_posixsem_check_unlink,
	.mpo_socket_check_create = finch_sandbox_socket_check_create,
	.mpo_socket_check_connect = finch_sandbox_socket_check_connect,
	.mpo_socket_check_bind = finch_sandbox_socket_check_bind,
	.mpo_socket_check_listen = finch_sandbox_socket_check_listen,
	.mpo_iokit_check_open = finch_sandbox_iokit_check_open,
	.mpo_iokit_check_open_service = finch_sandbox_iokit_check_open_service,
};

static struct mac_policy_conf finch_sandbox_policy_conf = {
	.mpc_name = FINCH_SANDBOX_POLICY,
	.mpc_fullname = "Finch sandbox",
	.mpc_labelnames = finch_sandbox_label_names,
	.mpc_labelname_count = 1,
	.mpc_ops = &finch_sandbox_policy_ops,
	.mpc_field_off = &finch_sandbox_label_slot,
	.mpc_loadtime_flags = 0,
	.mpc_runtime_flags = 0,
};

void
finch_sandbox_policy_init(void)
{
	read_random(finch_sb_extension_key, sizeof(finch_sb_extension_key));
	int error = mac_policy_register(&finch_sandbox_policy_conf,
	    &finch_sandbox_policy_handle, NULL);

	if (error != 0) {
		panic("FinchSandbox policy registration failed: %d", error);
	}
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's compiled sandbox profile ("FSB1"), shared by the SBPL compiler in
 * libsandbox.1 and the FinchSandbox kernel policy, and the request the
 * evaluator (fsb_eval.c) decides on.
 *
 * A profile holds, for every operation in fsb_ops.h, an ordered list of rules.
 * A request for an operation is decided by the last of that operation's rules
 * whose filter matches; when none matches, by its group's rules (file-read-data,
 * then file-read*, then file*), and finally by default's. With no matching rule
 * anywhere the request is denied. This is what macOS's sandbox does.
 *
 * Layout: a header, then five arrays at the offsets it names, all 4-byte
 * aligned and little-endian. Every index is checked by fsb_profile_validate
 * before use, and a node's children always come before it, so evaluation
 * can't loop.
 */
#ifndef FSB_FORMAT_H
#define FSB_FORMAT_H

#include "fsb_ops.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define FSB_MAGIC		0x31425346u	/* "FSB1" */
#define FSB_VERSION		1u
#define FSB_MAX_SIZE		(4u << 20)	/* the kernel refuses larger profiles */
#define FSB_MAX_DEPTH		48		/* filter nesting */
#define FSB_MAX_REGEX_INSNS	8192
#define FSB_NONE		0xffffffffu

struct fsb_header {
	uint32_t magic;
	uint32_t version;
	uint32_t size;		/* the whole profile */
	uint32_t op_count;	/* FSB_OP_COUNT */
	uint32_t ops_off;	/* struct fsb_op[op_count] */
	uint32_t rules_off;	/* struct fsb_rule[rule_count] */
	uint32_t rule_count;
	uint32_t nodes_off;	/* struct fsb_node[node_count] */
	uint32_t node_count;
	uint32_t children_off;	/* uint32_t[child_count] node indexes */
	uint32_t child_count;
	uint32_t data_off;	/* strings and regex programs */
	uint32_t data_size;
	uint32_t flags;		/* FSB_PROFILE_* */
	uint32_t reserved[2];
};

#define FSB_PROFILE_DEBUG_DENIALS	0x1u	/* (debug deny): log denials */
/* (version 2) and later: system calls obey the syscall-unix rules (version 1
   profiles leave them unfiltered, as macOS does). */
#define FSB_PROFILE_FILTER_SYSCALLS	0x2u
#define FSB_PROFILE_FLAGS		(FSB_PROFILE_DEBUG_DENIALS | FSB_PROFILE_FILTER_SYSCALLS)

struct fsb_op {
	uint32_t first_rule;
	uint32_t rule_count;
};

#define FSB_RULE_DENY		0x1u
#define FSB_RULE_REPORT		0x2u	/* (with report) */
#define FSB_RULE_NO_REPORT	0x4u	/* (with no-report) / (with no-log) */

struct fsb_rule {
	uint32_t flags;
	uint32_t node;		/* filter, or FSB_NONE to match every request */
};

/* Node kinds. */
enum {
	FSB_N_TRUE = 1,
	FSB_N_FALSE,
	FSB_N_ALL,		/* a = first child (children[]), b = count */
	FSB_N_ANY,
	FSB_N_NOT,		/* a = child node */
	FSB_N_STR_EQ,		/* field; a = data offset, b = length */
	FSB_N_STR_PREFIX,
	FSB_N_SUBPATH,		/* path equal to a, or below it */
	FSB_N_REGEX,		/* field; a = data offset of the program, b = words */
	FSB_N_NUM_EQ,		/* field; a = low 32 bits, b = high 32 bits */
	FSB_N_NUM_BITS,		/* field; every bit of a is set */
	FSB_N_EXTENSION,	/* (extension "class"): a = data offset of the class, b = length;
				   matches when the caller holds an extension of that class
				   covering the request (fsb_request.extension) */
	FSB_N_KIND_MAX
};

struct fsb_node {
	uint16_t kind;
	uint16_t field;		/* FSB_F_* for the comparison kinds */
	uint32_t a;
	uint32_t b;
};

/*
 * Request fields. String fields are compared byte for byte (paths as the
 * kernel resolves them); numeric fields hold the values below.
 */
enum {
	FSB_F_PATH = 0,
	FSB_F_GLOBAL_NAME,	/* mach-lookup / mach-register service */
	FSB_F_LOCAL_NAME,
	FSB_F_IPC_POSIX_NAME,
	FSB_F_SYSCTL_NAME,
	FSB_F_NOTIFICATION_NAME,
	FSB_F_PREFERENCE_DOMAIN,
	FSB_F_IOKIT_USER_CLIENT_CLASS,
	FSB_F_IOKIT_REGISTRY_ENTRY_CLASS,
	FSB_F_IOKIT_PROPERTY,
	FSB_F_XATTR,
	FSB_F_NVRAM_VARIABLE,
	FSB_F_RIGHT_NAME,
	FSB_F_XPC_SERVICE_NAME,
	FSB_F_CONTROL_NAME,
	FSB_F_KEXT_BUNDLE_ID,
	FSB_F_SIGNING_IDENTIFIER,
	FSB_F_MAC_POLICY_NAME,
	FSB_F_PROCESS_PATH,
	FSB_F_REMOTE,		/* network: "host:port", host "*" or an address */
	FSB_F_LOCAL,
	FSB_F_STRING_COUNT,

	FSB_F_TARGET = 32,	/* FSB_TARGET_* bits */
	FSB_F_VNODE_TYPE,	/* FSB_VNODE_* */
	FSB_F_FILE_MODE,
	FSB_F_SOCKET_DOMAIN,
	FSB_F_SOCKET_TYPE,
	FSB_F_SOCKET_PROTOCOL,
	FSB_F_SOCKET_OPTION_LEVEL,
	FSB_F_SOCKET_OPTION_NAME,
	FSB_F_SYSCALL_NUMBER,
	FSB_F_MACHTRAP_NUMBER,
	FSB_F_KERNEL_MIG_ROUTINE,
	FSB_F_IOCTL_COMMAND,
	FSB_F_FSCTL_COMMAND,
	FSB_F_FCNTL_COMMAND,
	FSB_F_IOKIT_METHOD_NUMBER,
	FSB_F_PRIVILEGE_ID,
	FSB_F_UID,
	FSB_F_MESSAGE_NUMBER,
	FSB_F_MAC_SYSCALL_NUMBER,
	FSB_F_FILE_ATTRIBUTES,	/* FSB_FILE_ATTR_* bits the file has */
	FSB_F_PROCESS_ATTRIBUTES, /* FSB_PROCESS_ATTR_* bits the caller has */
	FSB_F_FIELD_MAX
};

/* FSB_F_FILE_ATTRIBUTES: (file-attribute NAME) */
#define FSB_FILE_ATTR_UNION_MOUNTED_FILESYSTEM	0x1u
#define FSB_FILE_ATTR_HAS_MULTIPLE_NAMES	0x2u
#define FSB_FILE_ATTR_APFS_PREBOOT_VOLUME	0x4u
#define FSB_FILE_ATTR_APFS_RECOVERY_VOLUME	0x8u
#define FSB_FILE_ATTR_FILEPROVIDER_OWNED	0x10u

/* FSB_F_PROCESS_ATTRIBUTES: (process-attribute NAME) */
#define FSB_PROCESS_ATTR_IS_PLATFORM_BINARY	0x1u
#define FSB_PROCESS_ATTR_IS_APPLE_SIGNED	0x2u
#define FSB_PROCESS_ATTR_IS_RESTRICTED		0x4u
#define FSB_PROCESS_ATTR_IS_PLUGIN		0x8u

#define FSB_F_IS_STRING(f)	((f) < FSB_F_STRING_COUNT)
#define FSB_F_NUM_INDEX(f)	((f) - FSB_F_TARGET)
#define FSB_F_NUM_COUNT		(FSB_F_FIELD_MAX - FSB_F_TARGET)

/* FSB_F_TARGET: who the operation acts on, relative to the caller. */
#define FSB_TARGET_SELF		0x1u
#define FSB_TARGET_OTHERS	0x2u
#define FSB_TARGET_SAME_SANDBOX	0x4u	/* another process with the same profile */
#define FSB_TARGET_CHILDREN	0x8u
#define FSB_TARGET_PARENT	0x10u

/* FSB_F_VNODE_TYPE */
enum {
	FSB_VNODE_REGULAR = 1, FSB_VNODE_DIRECTORY, FSB_VNODE_BLOCK_DEVICE,
	FSB_VNODE_CHARACTER_DEVICE, FSB_VNODE_SYMLINK, FSB_VNODE_SOCKET,
	FSB_VNODE_FIFO, FSB_VNODE_TTY
};

/*
 * Regex programs: 32-bit words. The low 8 bits of a word are the opcode;
 * the high 24, its operand. CLASS is followed by 8 words of bitmap (bit c of
 * the 256 is set for each byte c the class takes); SPLIT by a second word
 * holding its other target. Matching searches the whole subject, as macOS's
 * regex filters do; BOL and EOL anchor.
 */
enum {
	FSB_RX_CHAR = 1,	/* operand: the byte */
	FSB_RX_ANY,		/* any byte */
	FSB_RX_CLASS,		/* + 8 words */
	FSB_RX_SPLIT,		/* operand: x; next word: y (both instruction indexes) */
	FSB_RX_JMP,		/* operand: target */
	FSB_RX_BOL,
	FSB_RX_EOL,
	FSB_RX_MATCH
};
#define FSB_RX_OP(w)		((w) & 0xffu)
#define FSB_RX_ARG(w)		((w) >> 8)
#define FSB_RX_WORD(op, arg)	((uint32_t)(op) | ((uint32_t)(arg) << 8))

/* What is being asked: an operation and the values its filters look at. */
struct fsb_request {
	uint32_t op;
	uint32_t strings_present;	/* bit per string field */
	uint64_t numbers_present;	/* bit per FSB_F_NUM_INDEX */
	const char *string[FSB_F_STRING_COUNT];
	size_t length[FSB_F_STRING_COUNT];
	uint64_t number[FSB_F_NUM_COUNT];
	/* Does the caller hold an extension of this class covering the request?
	   NULL: it holds none. */
	bool (*extension)(const void *arg, const char *extension_class, size_t length,
	    const struct fsb_request *r);
	const void *extension_arg;
};

/* Scratch the regex matcher needs: three FSB_MAX_REGEX_INSNS lists and marks. */
#define FSB_SCRATCH_BYTES	(FSB_MAX_REGEX_INSNS * (3 * sizeof(uint16_t) + 1))

#define FSB_ALLOW	0
#define FSB_DENY	1

void fsb_request_init(struct fsb_request *r, uint32_t op);
void fsb_request_string(struct fsb_request *r, int field, const char *s, size_t len);
void fsb_request_number(struct fsb_request *r, int field, uint64_t value);

/* 0 when the profile is well formed; nonzero (an errno value) otherwise. */
int fsb_profile_validate(const void *profile, size_t size);

/*
 * FSB_ALLOW or FSB_DENY for a validated profile. rule_flags, when not NULL,
 * receives the deciding rule's flags (0 for the implicit deny).
 * scratch_memory is FSB_SCRATCH_BYTES of caller memory.
 */
int fsb_evaluate(const void *profile, const struct fsb_request *r,
    void *scratch_memory, uint32_t *rule_flags);

/* Each operation's group (FSB_NONE for default), from the names. */
uint32_t fsb_op_parent(uint32_t op);
/* The operation's index for a name, or FSB_NONE. */
uint32_t fsb_op_lookup(const char *name, size_t len);
const char *fsb_op_name(uint32_t op);

#endif /* FSB_FORMAT_H */

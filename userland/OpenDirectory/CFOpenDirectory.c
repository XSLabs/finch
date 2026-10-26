/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFOpenDirectory: Open Directory's C API (Apple's is closed). Finch's first
 * cut serves the local node only, from the user database libSystem reads
 * (/etc/master.passwd through getpwnam), and verifies passwords through
 * libfinchaccount, as Finch's pam_unix does. Sessions, nodes and records are CF types, so
 * callers CFRelease them as with Apple's.
 *
 * Implemented (what Finch's binaries import: chkpasswd's -i od, and passwd run by
 * root): sessions, nodes by type or name (the local and authentication nodes,
 * which here are the same), user records by name and their standard attributes,
 * password verification, and password changes, by root only (the account files
 * are root's; there is no opendirectoryd to make a user's own change, which goes
 * through PAM instead). The rest comes as something needs it, along with
 * opendirectoryd and directory services proper.
 *
 * Record changes (chpass): ODRecordSetValue collects them and
 * ODRecordSynchronize writes them, as root directly; for anyone else through
 * the setuid helper finch-account-update, which applies the local node's
 * rules (finch-account-update.c), with the credentials ODRecordSetNodeCredentials
 * was given. GECOS holds the full name, office, office phone and home phone,
 * comma-separated as in BSD's passwd(5).
 */

#include <CFOpenDirectory/CFOpenDirectory.h>
#include <CoreFoundation/CFRuntime.h>
#include <account_tools.h>
#include <errno.h>
#include <pwd.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define ACCOUNT_UPDATE_HELPER "/usr/libexec/finch-account-update"

static int run_helper(char *const argv[], const char *auth, const char *password);

const CFStringRef kODErrorDomainFramework = CFSTR("com.apple.OpenDirectory");
const ODRecordType kODRecordTypeUsers = CFSTR("dsRecTypeStandard:Users");
ODSessionRef kODSessionDefault = NULL; /* (the one session, which needs no object) */
const ODAttributeType kODAttributeTypeRecordName = CFSTR("dsAttrTypeStandard:RecordName");
const ODAttributeType kODAttributeTypeUniqueID = CFSTR("dsAttrTypeStandard:UniqueID");
const ODAttributeType kODAttributeTypePrimaryGroupID = CFSTR("dsAttrTypeStandard:PrimaryGroupID");
const ODAttributeType kODAttributeTypeFullName = CFSTR("dsAttrTypeStandard:RealName");
const ODAttributeType kODAttributeTypeNFSHomeDirectory = CFSTR("dsAttrTypeStandard:NFSHomeDirectory");
const ODAttributeType kODAttributeTypeUserShell = CFSTR("dsAttrTypeStandard:UserShell");
const ODAttributeType kODAttributeTypeMetaNodeLocation = CFSTR("dsAttrTypeStandard:AppleMetaNodeLocation");
const ODAttributeType kODAttributeTypeAuthenticationAuthority = CFSTR("dsAttrTypeStandard:AuthenticationAuthority");

#define LOCAL_NODE_NAME CFSTR("/Local/Default")

struct __ODSession { CFRuntimeBase base; };
struct __ODNode { CFRuntimeBase base; CFStringRef name; };
struct __ODRecord {
    CFRuntimeBase base;
    CFStringRef type;
    CFStringRef name;
    CFMutableDictionaryRef changes;   /* attribute -> new value (a string), until synchronized */
    CFStringRef auth_name;            /* ODRecordSetNodeCredentials' verified user and password */
    char *auth_password;
};

static void node_finalize(CFTypeRef cf) { CFRelease(((ODNodeRef)cf)->name); }
static void record_finalize(CFTypeRef cf) {
    struct __ODRecord *r = (struct __ODRecord *)cf;
    CFRelease(r->type);
    CFRelease(r->name);
    if (r->changes) CFRelease(r->changes);
    if (r->auth_name) CFRelease(r->auth_name);
    if (r->auth_password) {
        at_secure_clear(r->auth_password, strlen(r->auth_password));
        free(r->auth_password);
    }
}

static const CFRuntimeClass session_class = { .className = "ODSession" };
static const CFRuntimeClass node_class = { .className = "ODNode", .finalize = node_finalize };
static const CFRuntimeClass record_class = { .className = "ODRecord", .finalize = record_finalize };
static CFTypeID session_id, node_id, record_id;

static void register_classes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session_id = _CFRuntimeRegisterClass(&session_class);
        node_id = _CFRuntimeRegisterClass(&node_class);
        record_id = _CFRuntimeRegisterClass(&record_class);
    });
}

CFTypeID ODSessionGetTypeID(void) { register_classes(); return session_id; }
CFTypeID ODNodeGetTypeID(void) { register_classes(); return node_id; }
CFTypeID ODRecordGetTypeID(void) { register_classes(); return record_id; }

static CFTypeRef create(CFAllocatorRef allocator, CFTypeID type, size_t size) {
    return _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

static void set_error(CFErrorRef *error, CFIndex code, CFStringRef description) {
    if (!error) return;
    const void *keys[] = { kCFErrorDescriptionKey };
    const void *values[] = { description };
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    *error = CFErrorCreate(NULL, kODErrorDomainFramework, code, info);
    CFRelease(info);
}

/* A user's name as a C string, or false if it doesn't convert. */
static bool c_name(CFStringRef s, char *buf, size_t size) {
    return s && CFStringGetCString(s, buf, (CFIndex)size, kCFStringEncodingUTF8);
}

ODSessionRef ODSessionCreate(CFAllocatorRef allocator, CFDictionaryRef options, CFErrorRef *error) {
    (void)options; (void)error;
    register_classes();
    return (ODSessionRef)create(allocator, session_id, sizeof(struct __ODSession));
}

static ODNodeRef local_node(CFAllocatorRef allocator) {
    register_classes();
    struct __ODNode *n = (struct __ODNode *)create(allocator, node_id, sizeof(struct __ODNode));
    if (n) n->name = CFRetain(LOCAL_NODE_NAME);
    return n;
}

ODNodeRef ODNodeCreateWithNodeType(CFAllocatorRef allocator, ODSessionRef session, ODNodeType nodeType,
    CFErrorRef *error) {
    (void)session;
    /* Only the local directory exists, so authentication and search go there. */
    if (nodeType == kODNodeTypeAuthentication || nodeType == kODNodeTypeLocalNodes ||
        nodeType == kODNodeTypeNetwork || nodeType == kODNodeTypeContacts) {
        return local_node(allocator);
    }
    set_error(error, kODErrorNodeUnknownType, CFSTR("Unknown node type"));
    return NULL;
}

ODNodeRef ODNodeCreateWithName(CFAllocatorRef allocator, ODSessionRef session, CFStringRef nodeName,
    CFErrorRef *error) {
    (void)session;
    if (nodeName && (CFEqual(nodeName, LOCAL_NODE_NAME) || CFEqual(nodeName, CFSTR("/Search")) ||
        CFEqual(nodeName, CFSTR("/Local")))) {
        return local_node(allocator);
    }
    set_error(error, kODErrorNodeUnknownName, CFSTR("Unknown node name"));
    return NULL;
}

CFStringRef ODNodeGetName(ODNodeRef node) { return node->name; }

ODRecordRef ODNodeCopyRecord(ODNodeRef node, ODRecordType recordType, CFStringRef recordName, CFTypeRef attributes,
    CFErrorRef *error) {
    (void)node; (void)attributes; (void)error;
    char name[256];
    /* Not found is NULL without an error, as in Open Directory. */
    if (!recordType || !CFEqual(recordType, kODRecordTypeUsers) || !c_name(recordName, name, sizeof(name)) ||
        getpwnam(name) == NULL) {
        return NULL;
    }
    struct __ODRecord *r = (struct __ODRecord *)create(CFGetAllocator(node), record_id, sizeof(struct __ODRecord));
    if (r) {
        r->type = CFRetain(recordType);
        r->name = CFStringCreateCopy(NULL, recordName);
    }
    return r;
}

CFStringRef ODRecordGetRecordName(ODRecordRef record) { return record->name; }
CFStringRef ODRecordGetRecordType(ODRecordRef record) { return record->type; }

bool ODRecordVerifyPassword(ODRecordRef record, CFStringRef password, CFErrorRef *error) {
    char name[256], pass[AT_PASSWORD_MAX + 1] = {0};
    struct passwd *pw;
    if (!CFEqual(record->type, kODRecordTypeUsers) || !c_name(record->name, name, sizeof(name)) ||
        !c_name(password, pass, sizeof(pass)) || (pw = getpwnam(name)) == NULL) {
        at_secure_clear(pass, sizeof(pass));
        set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
        return false;
    }
    /* The hash is in master.passwd, which getpwnam(3) reads for root. The
     * shared verifier accepts Finch PBKDF2 hashes and old DES hashes. Anyone
     * else asks the helper, which reads it as root. */
    bool ok;
    if (geteuid() == 0) {
        ok = at_password_verify(pass, pw->pw_passwd ? pw->pw_passwd : "*");
    } else {
        char *argv[] = { "finch-account-update", "--verify", NULL };
        ok = run_helper(argv, name, pass) == 0;
    }
    at_secure_clear(pass, sizeof(pass));
    if (!ok) set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
    return ok;
}

/* GECOS's comma-separated fields: 0 full name, 1 office, 2 office phone, 3 home phone. */
static CFStringRef gecos_field(const char *gecos, int index) {
    const char *start = gecos ? gecos : "";
    for (int i = 0; i < index && start; i++) {
        start = strchr(start, ',');
        if (start) start++;
    }
    if (!start) return CFSTR("");
    size_t length = strcspn(start, ",");
    CFStringRef value = CFStringCreateWithBytes(NULL, (const UInt8 *)start, (CFIndex)length, kCFStringEncodingUTF8, false);
    return value ? value : CFRetain(CFSTR(""));
}

static int gecos_index(CFStringRef attribute) {
    if (CFEqual(attribute, kODAttributeTypeFullName)) return 0;
    if (CFEqual(attribute, kODAttributeTypeBuilding)) return 1;
    if (CFEqual(attribute, kODAttributeTypePhoneNumber)) return 2;
    if (CFEqual(attribute, kODAttributeTypeHomePhoneNumber)) return 3;
    return -1;
}

/* A user record's attribute, from the account database: its values as strings. */
CFArrayRef ODRecordCopyValues(ODRecordRef record, ODAttributeType attribute, CFErrorRef *error) {
    char name[256], number[48];
    struct passwd *pw;
    if (!attribute || !CFEqual(record->type, kODRecordTypeUsers) || !c_name(record->name, name, sizeof(name)) ||
        (pw = getpwnam(name)) == NULL) {
        set_error(error, kODErrorRecordNoLongerExists, CFSTR("Record no longer exists"));
        return NULL;
    }
    CFStringRef value = NULL;
    if (CFEqual(attribute, kODAttributeTypeRecordName))
        value = CFStringCreateCopy(NULL, record->name);
    else if (CFEqual(attribute, kODAttributeTypeUniqueID) || CFEqual(attribute, kODAttributeTypePrimaryGroupID)) {
        snprintf(number, sizeof(number), "%u", CFEqual(attribute, kODAttributeTypeUniqueID) ? pw->pw_uid : pw->pw_gid);
        value = CFStringCreateWithCString(NULL, number, kCFStringEncodingUTF8);
    } else if (gecos_index(attribute) >= 0) {
        value = gecos_field(pw->pw_gecos, gecos_index(attribute));
        /* Only the full name is there when the others are empty. */
        if (gecos_index(attribute) > 0 && CFStringGetLength(value) == 0) {
            CFRelease(value);
            value = NULL;
        }
    } else if (CFEqual(attribute, kODAttributeTypeGUID)) {
        /* libinfo's UUID for a uid with no directory record (mbr_uid_to_uuid) */
        snprintf(number, sizeof(number), "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", pw->pw_uid);
        value = CFStringCreateWithCString(NULL, number, kCFStringEncodingUTF8);
    } else if (CFEqual(attribute, kODAttributeTypePassword))
        value = CFRetain(CFSTR("********"));
    else if (CFEqual(attribute, kODAttributeTypeNFSHomeDirectory))
        value = CFStringCreateWithCString(NULL, pw->pw_dir ? pw->pw_dir : "", kCFStringEncodingUTF8);
    else if (CFEqual(attribute, kODAttributeTypeUserShell))
        value = CFStringCreateWithCString(NULL, pw->pw_shell ? pw->pw_shell : "", kCFStringEncodingUTF8);
    else if (CFEqual(attribute, kODAttributeTypeMetaNodeLocation))
        value = CFRetain(LOCAL_NODE_NAME);
    else if (CFEqual(attribute, kODAttributeTypeAuthenticationAuthority))
        value = CFRetain(CFSTR(";ShadowHash;"));
    if (!value)
        return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayRef values = CFArrayCreate(NULL, (const void **)&value, 1, &kCFTypeArrayCallBacks);
    CFRelease(value);
    return values;
}

/* Authenticate to the node as another user (passwd -u): their password must verify. */
bool ODRecordSetNodeCredentials(ODRecordRef record, CFStringRef username, CFStringRef password, CFErrorRef *error) {
    ODNodeRef node = local_node(CFGetAllocator(record));
    ODRecordRef as = node ? ODNodeCopyRecord(node, kODRecordTypeUsers, username, NULL, NULL) : NULL;
    bool ok = as && ODRecordVerifyPassword(as, password, error);
    if (!as)
        set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
    if (as) CFRelease(as);
    if (node) CFRelease(node);
    /* Kept for ODRecordSynchronize: the helper checks them again as root. */
    char pass[AT_PASSWORD_MAX + 1] = {0};
    if (ok && c_name(password, pass, sizeof(pass))) {
        struct __ODRecord *r = (struct __ODRecord *)record;
        if (r->auth_name) CFRelease(r->auth_name);
        if (r->auth_password) {
            at_secure_clear(r->auth_password, strlen(r->auth_password));
            free(r->auth_password);
        }
        r->auth_name = CFStringCreateCopy(NULL, username);
        r->auth_password = strdup(pass);
    }
    at_secure_clear(pass, sizeof(pass));
    return ok;
}

/* A user's password changed, in the account files (root's): by root, with or without the
   old password, which must verify when given. */
bool ODRecordChangePassword(ODRecordRef record, CFStringRef oldPassword, CFStringRef newPassword, CFErrorRef *error) {
    char name[256], old[AT_PASSWORD_MAX + 1] = {0}, new[AT_PASSWORD_MAX + 1] = {0}, message[256] = {0};
    bool ok = false;
    if (geteuid() != 0) {
        set_error(error, kODErrorCredentialsNotAuthorized, CFSTR("Changing a password here needs root; use passwd"));
        return false;
    }
    if (!CFEqual(record->type, kODRecordTypeUsers) || !c_name(record->name, name, sizeof(name)) ||
        !c_name(newPassword, new, sizeof(new)) || (oldPassword && !c_name(oldPassword, old, sizeof(old)))) {
        set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
        goto done;
    }
    struct at_store store = { .directory_fd = -1 };
    if (at_store_open_default(&store, message, sizeof(message)) != 0) {
        set_error(error, kODErrorCredentialsServerError, CFSTR("The account files could not be opened"));
        goto done;
    }
    ok = at_store_change_password(&store, name, getuid(), oldPassword == NULL, oldPassword ? old : NULL, new,
        message, sizeof(message)) == 0;
    at_store_close(&store);
    if (!ok)
        set_error(error, oldPassword ? kODErrorCredentialsInvalid : kODErrorCredentialsPasswordQualityFailed,
            CFSTR("The password could not be changed"));
done:
    at_secure_clear(old, sizeof(old));
    at_secure_clear(new, sizeof(new));
    return ok;
}

/* The standard attributes of a user record, or those asked for. */
CFDictionaryRef ODRecordCopyDetails(ODRecordRef record, CFArrayRef attributes, CFErrorRef *error) {
    const ODAttributeType standard[] = {
        kODAttributeTypeRecordName, kODAttributeTypeUniqueID, kODAttributeTypePrimaryGroupID,
        kODAttributeTypeFullName, kODAttributeTypeNFSHomeDirectory, kODAttributeTypeUserShell,
        kODAttributeTypeMetaNodeLocation, kODAttributeTypeAuthenticationAuthority, kODAttributeTypePassword,
        kODAttributeTypeGUID, kODAttributeTypeBuilding, kODAttributeTypePhoneNumber, kODAttributeTypeHomePhoneNumber,
    };
    CFMutableDictionaryRef details = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    for (size_t i = 0; i < sizeof(standard) / sizeof(standard[0]); i++) {
        CFStringRef attribute = standard[i];
        if (attributes && CFArrayGetCount(attributes) > 0 &&
            !CFArrayContainsValue(attributes, CFRangeMake(0, CFArrayGetCount(attributes)), kODAttributeTypeStandardOnly) &&
            !CFArrayContainsValue(attributes, CFRangeMake(0, CFArrayGetCount(attributes)), kODAttributeTypeAllAttributes) &&
            !CFArrayContainsValue(attributes, CFRangeMake(0, CFArrayGetCount(attributes)), attribute))
            continue;
        CFArrayRef values = ODRecordCopyValues(record, attribute, error);
        if (!values) {
            CFRelease(details);
            return NULL;
        }
        if (CFArrayGetCount(values) > 0)
            CFDictionarySetValue(details, attribute, values);
        CFRelease(values);
    }
    return details;
}

/* A change to one attribute, kept until ODRecordSynchronize. An empty array
   (or empty string) clears it. */
bool ODRecordSetValue(ODRecordRef record, ODAttributeType attribute, CFTypeRef value, CFErrorRef *error) {
    struct __ODRecord *r = (struct __ODRecord *)record;
    CFStringRef string = NULL;
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        if (count > 1) {
            set_error(error, kODErrorRecordAttributeValueSchemaError, CFSTR("Local accounts hold one value per attribute"));
            return false;
        }
        string = count ? CFArrayGetValueAtIndex(value, 0) : CFSTR("");
    } else {
        string = value;
    }
    bool known = attribute && (CFEqual(attribute, kODAttributeTypeUniqueID) ||
        CFEqual(attribute, kODAttributeTypePrimaryGroupID) || CFEqual(attribute, kODAttributeTypeNFSHomeDirectory) ||
        CFEqual(attribute, kODAttributeTypeUserShell) || gecos_index(attribute) >= 0);
    if (!string || CFGetTypeID(string) != CFStringGetTypeID() || !CFEqual(r->type, kODRecordTypeUsers)) {
        set_error(error, kODErrorRecordAttributeValueSchemaError, CFSTR("The value isn't a string"));
        return false;
    }
    if (!known) {
        set_error(error, kODErrorRecordAttributeUnknownType, CFSTR("This attribute can't be changed on a local account"));
        return false;
    }
    if (!r->changes)
        r->changes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(r->changes, attribute, string);
    return true;
}

static char *copy_c_string(CFStringRef s) {
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    char *out = malloc((size_t)size);
    if (out && !CFStringGetCString(s, out, size, kCFStringEncodingUTF8)) {
        free(out);
        out = NULL;
    }
    return out;
}

/* The record's GECOS with the pending changes to its fields. */
static char *changed_gecos(struct __ODRecord *r, const char *current) {
    CFStringRef parts[4];
    for (int i = 0; i < 4; i++) parts[i] = gecos_field(current, i);
    const ODAttributeType names[4] = { kODAttributeTypeFullName, kODAttributeTypeBuilding,
        kODAttributeTypePhoneNumber, kODAttributeTypeHomePhoneNumber };
    for (int i = 0; i < 4; i++) {
        CFStringRef v = CFDictionaryGetValue(r->changes, names[i]);
        if (v) {
            CFRelease(parts[i]);
            parts[i] = CFRetain(v);
        }
    }
    /* Trailing empty fields are left off, as passwd(5) writes them. */
    int last = 3;
    while (last > 0 && CFStringGetLength(parts[last]) == 0) last--;
    CFMutableStringRef joined = CFStringCreateMutable(NULL, 0);
    for (int i = 0; i <= last; i++) {
        if (i) CFStringAppend(joined, CFSTR(","));
        CFStringAppend(joined, parts[i]);
    }
    for (int i = 0; i < 4; i++) CFRelease(parts[i]);
    char *out = copy_c_string(joined);
    CFRelease(joined);
    return out;
}

static bool parse_id(CFStringRef s, uint32_t *out) {
    char text[16], *end;
    if (!c_name(s, text, sizeof(text)) || !text[0]) return false;
    errno = 0;
    unsigned long v = strtoul(text, &end, 10);
    if (errno || *end || text[0] == '-' || v >= UINT32_MAX - 1U) return false;
    *out = (uint32_t)v;
    return true;
}

/* Run the helper as the caller with a name and password on its input: its
   exit status (0 done, 2 not authorized), or -1 if it didn't run. */
static int run_helper(char *const argv[], const char *auth, const char *password) {
    int input[2];
    if (pipe(input) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    pid_t pid;
    char *envp[] = { NULL };
    int spawned = posix_spawn(&pid, ACCOUNT_UPDATE_HELPER, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    close(input[0]);
    if (spawned != 0) {
        close(input[1]);
        return -1;
    }
    /* The credentials: a name and a password, each ending in a NUL. */
    (void)!write(input[1], auth, strlen(auth) + 1);
    (void)!write(input[1], password, strlen(password) + 1);
    close(input[1]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* Run the helper as the caller: it checks the credentials and the rules. */
static bool update_through_helper(struct __ODRecord *r, const char *name, char *const assignments[], CFErrorRef *error) {
    char auth[256] = "";
    if (r->auth_name) c_name(r->auth_name, auth, sizeof(auth));
    char *argv[16] = { "finch-account-update", (char *)name };
    int argc = 2;
    for (int i = 0; assignments[i] && argc < 15; i++) argv[argc++] = assignments[i];
    argv[argc] = NULL;
    int status = run_helper(argv, auth, r->auth_password ? r->auth_password : "");
    if (status != 0) {
        bool denied = status == 2;
        set_error(error, denied ? kODErrorCredentialsNotAuthorized : kODErrorCredentialsServerError,
            denied ? CFSTR("Not authorized to change these attributes") : CFSTR("The account files could not be changed"));
        return false;
    }
    return true;
}

/* Write the pending changes to the account files. */
bool ODRecordSynchronize(ODRecordRef record, CFErrorRef *error) {
    struct __ODRecord *r = (struct __ODRecord *)record;
    char name[256];
    struct passwd *pw;
    if (!r->changes || CFDictionaryGetCount(r->changes) == 0) return true;
    if (!CFEqual(r->type, kODRecordTypeUsers) || !c_name(r->name, name, sizeof(name)) || (pw = getpwnam(name)) == NULL) {
        set_error(error, kODErrorRecordNoLongerExists, CFSTR("Record no longer exists"));
        return false;
    }
    struct at_user_update update = {0};
    char *gecos = NULL, *home = NULL, *shell = NULL, assignment[6][1100];
    char *assignments[7] = {0};
    int n = 0;
    bool ok = false;
    CFStringRef v;
    if ((v = CFDictionaryGetValue(r->changes, kODAttributeTypeUniqueID))) {
        if (!parse_id(v, &update.uid)) goto invalid;
        update.set_uid = true;
        snprintf(assignment[n], sizeof(assignment[n]), "uid=%u", update.uid);
        assignments[n] = assignment[n]; n++;
    }
    if ((v = CFDictionaryGetValue(r->changes, kODAttributeTypePrimaryGroupID))) {
        if (!parse_id(v, &update.gid)) goto invalid;
        update.set_gid = true;
        snprintf(assignment[n], sizeof(assignment[n]), "gid=%u", update.gid);
        assignments[n] = assignment[n]; n++;
    }
    if ((CFDictionaryContainsKey(r->changes, kODAttributeTypeFullName) ||
         CFDictionaryContainsKey(r->changes, kODAttributeTypeBuilding) ||
         CFDictionaryContainsKey(r->changes, kODAttributeTypePhoneNumber) ||
         CFDictionaryContainsKey(r->changes, kODAttributeTypeHomePhoneNumber))) {
        /* A comma inside a field would move the fields after it. */
        const ODAttributeType names[4] = { kODAttributeTypeFullName, kODAttributeTypeBuilding,
            kODAttributeTypePhoneNumber, kODAttributeTypeHomePhoneNumber };
        for (int i = 0; i < 4; i++)
            if ((v = CFDictionaryGetValue(r->changes, names[i])) &&
                CFStringFind(v, CFSTR(","), 0).location != kCFNotFound) goto invalid;
        if (!(gecos = changed_gecos(r, pw->pw_gecos)) || strlen(gecos) > 256) goto invalid;
        update.gecos = gecos;
        snprintf(assignment[n], sizeof(assignment[n]), "gecos=%s", gecos);
        assignments[n] = assignment[n]; n++;
    }
    if ((v = CFDictionaryGetValue(r->changes, kODAttributeTypeNFSHomeDirectory))) {
        if (!(home = copy_c_string(v)) || strlen(home) > 1024) goto invalid;
        update.home = home;
        snprintf(assignment[n], sizeof(assignment[n]), "home=%s", home);
        assignments[n] = assignment[n]; n++;
    }
    if ((v = CFDictionaryGetValue(r->changes, kODAttributeTypeUserShell))) {
        if (!(shell = copy_c_string(v)) || strlen(shell) > 1024) goto invalid;
        update.shell = shell;
        snprintf(assignment[n], sizeof(assignment[n]), "shell=%s", shell);
        assignments[n] = assignment[n]; n++;
    }
    if (getuid() == 0 && geteuid() == 0) {
        char message[256] = "";
        struct at_store store = { .directory_fd = -1 };
        ok = at_store_open_default(&store, message, sizeof(message)) == 0 &&
            at_store_update_user(&store, name, &update, message, sizeof(message)) == 0;
        at_store_close(&store);
        if (!ok) {
            CFStringRef description = CFStringCreateWithCString(NULL, message[0] ? message : "The account files could not be changed",
                kCFStringEncodingUTF8);
            set_error(error, kODErrorRecordParameterError, description);
            CFRelease(description);
        }
    } else {
        ok = update_through_helper(r, name, assignments, error);
    }
    if (ok) CFDictionaryRemoveAllValues(r->changes);
    goto done;
invalid:
    set_error(error, kODErrorRecordAttributeValueSchemaError, CFSTR("A new value isn't valid for a local account"));
done:
    free(gecos);
    free(home);
    free(shell);
    return ok;
}

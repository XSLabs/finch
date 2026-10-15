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
 */

#include <CFOpenDirectory/CFOpenDirectory.h>
#include <CoreFoundation/CFRuntime.h>
#include <account_tools.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

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
struct __ODRecord { CFRuntimeBase base; CFStringRef type; CFStringRef name; };

static void node_finalize(CFTypeRef cf) { CFRelease(((ODNodeRef)cf)->name); }
static void record_finalize(CFTypeRef cf) {
    CFRelease(((ODRecordRef)cf)->type);
    CFRelease(((ODRecordRef)cf)->name);
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
     * shared verifier accepts Finch PBKDF2 hashes and old DES hashes. */
    const char *hash = pw->pw_passwd ? pw->pw_passwd : "*";
    bool ok = at_password_verify(pass, hash);
    at_secure_clear(pass, sizeof(pass));
    if (!ok) set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
    return ok;
}

/* A user record's attribute, from the account database: its values as strings. */
CFArrayRef ODRecordCopyValues(ODRecordRef record, ODAttributeType attribute, CFErrorRef *error) {
    char name[256], number[32];
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
    } else if (CFEqual(attribute, kODAttributeTypeFullName))
        value = CFStringCreateWithCString(NULL, pw->pw_gecos ? pw->pw_gecos : "", kCFStringEncodingUTF8);
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
    if (at_store_open(&store, "/private/etc", message, sizeof(message)) != 0) {
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

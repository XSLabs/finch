/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFFileSecurity (CFFileSecurity.h on macOS; swift-corelibs has none): a file's owner,
 * group, mode, owner and group UUIDs and ACL, kept in a filesec_t as Apple's is. Its
 * objects are NSFileSecurity's, the class Apple's CoreFoundation defines too.
 */
#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFRuntime.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <sys/acl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <uuid/uuid.h>

#define FINCH_EXPORT __attribute__((visibility("default")))

typedef struct __CFFileSecurity *CFFileSecurityRef;
enum {
    kCFFileSecurityClearOwner = 1UL << 0,
    kCFFileSecurityClearGroup = 1UL << 1,
    kCFFileSecurityClearMode = 1UL << 2,
    kCFFileSecurityClearOwnerUUID = 1UL << 3,
    kCFFileSecurityClearGroupUUID = 1UL << 4,
    kCFFileSecurityClearAccessControlList = 1UL << 5,
};

FINCH_EXPORT
@interface NSFileSecurity : NSObject {
@public
    filesec_t _filesec;
    BOOL _removeACL;  /* (set to _FILESEC_REMOVE_ACL: kept as that, which filesec doesn't) */
}
@end

static filesec_t
fs(CFFileSecurityRef s)
{
    return s ? ((__bridge NSFileSecurity *)(void *)s)->_filesec : NULL;
}

static CFTypeID file_security_type;
static const CFRuntimeClass file_security_class = {0, "CFFileSecurity", NULL, NULL, NULL, NULL, NULL, NULL, NULL};

FINCH_EXPORT CFTypeID
CFFileSecurityGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        file_security_type = _CFRuntimeRegisterClass(&file_security_class);
    });
    return file_security_type;
}

@implementation NSFileSecurity

- (instancetype)init
{
    if ((self = [super init]))
        _filesec = filesec_init();
    return self;
}

- (void)dealloc
{
    if (_filesec)
        filesec_free(_filesec);
    [super dealloc];
}

+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(id)coder { return [self init]; }
- (void)encodeWithCoder:(id)coder {}
- (CFTypeID)_cfTypeID { return CFFileSecurityGetTypeID(); }

- (id)copyWithZone:(struct _NSZone *)zone
{
    NSFileSecurity *c = [[[self class] alloc] init];
    filesec_free(c->_filesec);
    c->_filesec = filesec_dup(_filesec);
    c->_removeACL = _removeACL;
    return c;
}

static BOOL
same_property(filesec_t a, filesec_t b, filesec_property_t p, size_t size)
{
    char x[16] = {0}, y[16] = {0};
    int ra = filesec_get_property(a, p, x), rb = filesec_get_property(b, p, y);
    return ra == rb && (ra != 0 || !memcmp(x, y, size));
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSFileSecurity class]])
        return NO;
    filesec_t a = _filesec, b = ((NSFileSecurity *)other)->_filesec;
    if (!same_property(a, b, FILESEC_OWNER, sizeof(uid_t)) || !same_property(a, b, FILESEC_GROUP, sizeof(gid_t)) ||
        !same_property(a, b, FILESEC_MODE, sizeof(mode_t)) || !same_property(a, b, FILESEC_UUID, sizeof(guid_t)) ||
        !same_property(a, b, FILESEC_GRPUUID, sizeof(guid_t)))
        return NO;
    acl_t x = NULL, y = NULL;
    filesec_get_property(a, FILESEC_ACL, &x);
    filesec_get_property(b, FILESEC_ACL, &y);
    BOOL same = (!x && !y);
    if (x && y) {
        ssize_t lx = 0, ly = 0;
        char *tx = acl_to_text(x, &lx), *ty = acl_to_text(y, &ly);
        same = tx && ty && !strcmp(tx, ty);
        acl_free(tx);
        acl_free(ty);
    }
    if (x)
        acl_free(x);
    if (y)
        acl_free(y);
    return same;
}

- (NSUInteger)hash
{
    mode_t m = 0;
    uid_t u = 0;
    filesec_get_property(_filesec, FILESEC_MODE, &m);
    filesec_get_property(_filesec, FILESEC_OWNER, &u);
    return (NSUInteger)m ^ ((NSUInteger)u << 16);
}

/* As Apple's: the filesec's properties, by their names. */
- (id)description
{
    uid_t u;
    gid_t g;
    mode_t m;
    guid_t ou, gu;
    acl_t acl = NULL;
    char owner[16] = "(null)", group[16] = "(null)", mode[16] = "(null)", ouuid[40] = "(null)", guuid[40] = "(null)";
    if (!filesec_get_property(_filesec, FILESEC_OWNER, &u))
        snprintf(owner, sizeof owner, "%u", u);
    if (!filesec_get_property(_filesec, FILESEC_GROUP, &g))
        snprintf(group, sizeof group, "%u", g);
    if (!filesec_get_property(_filesec, FILESEC_MODE, &m))
        snprintf(mode, sizeof mode, "%u", m);
    if (!filesec_get_property(_filesec, FILESEC_UUID, &ou))
        uuid_unparse_upper(ou.g_guid, ouuid);
    if (!filesec_get_property(_filesec, FILESEC_GRPUUID, &gu))
        uuid_unparse_upper(gu.g_guid, guuid);
    char *acltext = NULL;
    if (!filesec_get_property(_filesec, FILESEC_ACL, &acl) && acl && acl != _FILESEC_REMOVE_ACL)
        acltext = acl_to_text(acl, NULL);
    CFStringRef d = CFStringCreateWithFormat(kCFAllocatorDefault, NULL,
        CFSTR("<FileSecurity %p> [%p] {FILESEC_OWNER = %s, FILESEC_GROUP = %s, FILESEC_MODE = %s, FILESEC_UUID = %s, "
              "FILESEC_GRPUUID = %s, FILESEC_ACL = %s}"),
        self, _filesec, owner, group, mode, ouuid, guuid, acltext ?: "(null)");
    if (acltext)
        acl_free(acltext);
    if (acl && acl != _FILESEC_REMOVE_ACL)
        acl_free(acl);
    return [(id)d autorelease];
}

@end

FINCH_EXPORT CFFileSecurityRef
CFFileSecurityCreate(CFAllocatorRef allocator)
{
    return (CFFileSecurityRef)(void *)[[NSFileSecurity alloc] init];
}

FINCH_EXPORT CFFileSecurityRef
CFFileSecurityCreateCopy(CFAllocatorRef allocator, CFFileSecurityRef s)
{
    return s ? (CFFileSecurityRef)(void *)[(__bridge NSFileSecurity *)(void *)s copyWithZone:NULL] : NULL;
}

static CFUUIDRef
copy_uuid(CFFileSecurityRef s, filesec_property_t p)
{
    guid_t g;
    if (!fs(s) || filesec_get_property(fs(s), p, &g))
        return NULL;
    CFUUIDBytes b;
    memcpy(&b, g.g_guid, sizeof b);
    return CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, b);
}

static Boolean
set_uuid(CFFileSecurityRef s, filesec_property_t p, CFUUIDRef uuid)
{
    if (!fs(s))
        return false;
    if (!uuid)
        return filesec_unset_property(fs(s), p) == 0;
    CFUUIDBytes b = CFUUIDGetUUIDBytes(uuid);
    guid_t g;
    memcpy(g.g_guid, &b, sizeof b);
    return filesec_set_property(fs(s), p, &g) == 0;
}

FINCH_EXPORT Boolean
CFFileSecurityCopyOwnerUUID(CFFileSecurityRef s, CFUUIDRef *ownerUUID)
{
    CFUUIDRef u = copy_uuid(s, FILESEC_UUID);
    if (ownerUUID)
        *ownerUUID = u;
    else if (u)
        CFRelease(u);
    return u != NULL;
}

FINCH_EXPORT Boolean CFFileSecuritySetOwnerUUID(CFFileSecurityRef s, CFUUIDRef u) { return set_uuid(s, FILESEC_UUID, u); }

FINCH_EXPORT Boolean
CFFileSecurityCopyGroupUUID(CFFileSecurityRef s, CFUUIDRef *groupUUID)
{
    CFUUIDRef u = copy_uuid(s, FILESEC_GRPUUID);
    if (groupUUID)
        *groupUUID = u;
    else if (u)
        CFRelease(u);
    return u != NULL;
}

FINCH_EXPORT Boolean CFFileSecuritySetGroupUUID(CFFileSecurityRef s, CFUUIDRef u) { return set_uuid(s, FILESEC_GRPUUID, u); }

/* (the ACL comes back as a copy the caller frees with acl_free) */
FINCH_EXPORT Boolean
CFFileSecurityCopyAccessControlList(CFFileSecurityRef s, acl_t *accessControlList)
{
    acl_t acl = NULL;
    if (fs(s) && ((__bridge NSFileSecurity *)(void *)s)->_removeACL) {
        if (accessControlList)
            *accessControlList = _FILESEC_REMOVE_ACL;
        return true;
    }
    if (!fs(s) || filesec_get_property(fs(s), FILESEC_ACL, &acl))
        return false;
    if (accessControlList)
        *accessControlList = acl;
    else if (acl && acl != _FILESEC_REMOVE_ACL)
        acl_free(acl);
    return true;
}

FINCH_EXPORT Boolean
CFFileSecuritySetAccessControlList(CFFileSecurityRef s, acl_t accessControlList)
{
    if (!fs(s))
        return false;
    NSFileSecurity *o = (__bridge NSFileSecurity *)(void *)s;
    o->_removeACL = accessControlList == _FILESEC_REMOVE_ACL;
    if (o->_removeACL)
        {
        filesec_unset_property(fs(s), FILESEC_ACL);
        return true;
    }
    return filesec_set_property(fs(s), FILESEC_ACL, &accessControlList) == 0;
}

#define SCALAR(Name, type, prop)                                                                  \
    FINCH_EXPORT Boolean CFFileSecurityGet##Name(CFFileSecurityRef s, type *out)                  \
    {                                                                                             \
        type v;                                                                                   \
        if (!fs(s) || filesec_get_property(fs(s), prop, &v))                                      \
            return false;                                                                         \
        if (out)                                                                                  \
            *out = v;                                                                             \
        return true;                                                                              \
    }                                                                                             \
    FINCH_EXPORT Boolean CFFileSecuritySet##Name(CFFileSecurityRef s, type v)                     \
    {                                                                                             \
        return fs(s) && filesec_set_property(fs(s), prop, &v) == 0;                               \
    }
SCALAR(Owner, uid_t, FILESEC_OWNER)
SCALAR(Group, gid_t, FILESEC_GROUP)
SCALAR(Mode, mode_t, FILESEC_MODE)

FINCH_EXPORT Boolean
CFFileSecurityClearProperties(CFFileSecurityRef s, CFOptionFlags clearPropertyMask)
{
    if (!fs(s))
        return false;
    static const struct { CFOptionFlags flag; filesec_property_t prop; } props[] = {
        {kCFFileSecurityClearOwner, FILESEC_OWNER}, {kCFFileSecurityClearGroup, FILESEC_GROUP},
        {kCFFileSecurityClearMode, FILESEC_MODE}, {kCFFileSecurityClearOwnerUUID, FILESEC_UUID},
        {kCFFileSecurityClearGroupUUID, FILESEC_GRPUUID}, {kCFFileSecurityClearAccessControlList, FILESEC_ACL},
    };
    for (size_t i = 0; i < sizeof props / sizeof *props; i++)
        if (clearPropertyMask & props[i].flag)
            filesec_unset_property(fs(s), props[i].prop);
    if (clearPropertyMask & kCFFileSecurityClearAccessControlList)
        ((__bridge NSFileSecurity *)(void *)s)->_removeACL = NO;
    return true;
}

/* A file's security as stat and its ACL give it (NSURLFileSecurityKey's value). */
FINCH_EXPORT CFFileSecurityRef
_CFFileSecurityCreateFromPath(const char *path)
{
    struct stat st;
    if (!path || lstat(path, &st))
        return NULL;
    CFFileSecurityRef s = CFFileSecurityCreate(kCFAllocatorDefault);
    CFFileSecuritySetOwner(s, st.st_uid);
    CFFileSecuritySetGroup(s, st.st_gid);
    CFFileSecuritySetMode(s, st.st_mode);
    acl_t acl = acl_get_link_np(path, ACL_TYPE_EXTENDED);
    if (acl) {
        CFFileSecuritySetAccessControlList(s, acl);
        acl_free(acl);
    }
    return s;
}

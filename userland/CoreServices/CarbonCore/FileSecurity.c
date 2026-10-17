/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Carbon file permission objects backed by POSIX ownership, modes, and ACLs. */
#include "CarbonCore_Finch.h"
#include <CoreFoundation/CFRuntime.h>
#include <sys/acl.h>

struct __FSFileSecurity {
    CFRuntimeBase base;
    UInt32 owner;
    UInt32 group;
    UInt16 mode;
    UInt8 userAccess;
    Boolean hasOwner;
    Boolean hasGroup;
    Boolean hasMode;
    Boolean hasOwnerUUID;
    Boolean hasGroupUUID;
    Boolean hasACL;
    CFUUIDBytes ownerUUID;
    CFUUIDBytes groupUUID;
    acl_t accessControlList;
};

static CFTypeID file_security_type;

static void
file_security_finalize(CFTypeRef value)
{
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)value;
    if (security->hasACL && security->accessControlList &&
        security->accessControlList != kFSFileSecurityRemoveACL)
        acl_free(security->accessControlList);
}

static void
file_security_register(void)
{
    static dispatch_once_t once;
    static const CFRuntimeClass classInfo = {
        .className = "FSFileSecurity",
        .finalize = file_security_finalize
    };
    dispatch_once(&once, ^{ file_security_type = _CFRuntimeRegisterClass(&classInfo); });
}

static struct __FSFileSecurity *
file_security_create(CFAllocatorRef allocator)
{
    file_security_register();
    return (struct __FSFileSecurity *)_CFRuntimeCreateInstance(allocator, file_security_type,
        (CFIndex)(sizeof(struct __FSFileSecurity) - sizeof(CFRuntimeBase)), NULL);
}

CFTypeID
FSFileSecurityGetTypeID(void)
{
    file_security_register();
    return file_security_type;
}

FSFileSecurityRef
FSFileSecurityCreate(CFAllocatorRef allocator)
{
    return (FSFileSecurityRef)file_security_create(allocator);
}

FSFileSecurityRef
FSFileSecurityCreateWithFSPermissionInfo(CFAllocatorRef allocator, const FSPermissionInfo *permissions)
{
    if (!permissions)
        return NULL;
    struct __FSFileSecurity *security = file_security_create(allocator);
    if (!security)
        return NULL;
    security->owner = permissions->userID;
    security->group = permissions->groupID;
    security->mode = permissions->mode;
    security->userAccess = permissions->userAccess;
    security->hasOwner = security->hasGroup = security->hasMode = true;
    if (permissions->fileSec) {
        if (CFGetTypeID(permissions->fileSec) != FSFileSecurityGetTypeID()) {
            CFRelease(security);
            return NULL;
        }
        struct __FSFileSecurity *source = (struct __FSFileSecurity *)permissions->fileSec;
        security->hasOwnerUUID = source->hasOwnerUUID;
        security->ownerUUID = source->ownerUUID;
        security->hasGroupUUID = source->hasGroupUUID;
        security->groupUUID = source->groupUUID;
        if (source->hasACL) {
            if (source->accessControlList == kFSFileSecurityRemoveACL)
                security->accessControlList = kFSFileSecurityRemoveACL;
            else if (source->accessControlList) {
                security->accessControlList = acl_dup(source->accessControlList);
                if (!security->accessControlList) {
                    CFRelease(security);
                    return NULL;
                }
            }
            security->hasACL = true;
        }
    }
    return (FSFileSecurityRef)security;
}

FSFileSecurityRef
FSFileSecurityRefCreateCopy(CFAllocatorRef allocator, FSFileSecurityRef fileSec)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID())
        return NULL;
    const struct __FSFileSecurity *source = (const struct __FSFileSecurity *)fileSec;
    struct __FSFileSecurity *copy = file_security_create(allocator);
    if (!copy)
        return NULL;
    copy->owner = source->owner;
    copy->group = source->group;
    copy->mode = source->mode;
    copy->userAccess = source->userAccess;
    copy->hasOwner = source->hasOwner;
    copy->hasGroup = source->hasGroup;
    copy->hasMode = source->hasMode;
    copy->hasOwnerUUID = source->hasOwnerUUID;
    copy->hasGroupUUID = source->hasGroupUUID;
    copy->ownerUUID = source->ownerUUID;
    copy->groupUUID = source->groupUUID;
    if (source->hasACL) {
        copy->hasACL = true;
        if (source->accessControlList == kFSFileSecurityRemoveACL)
            copy->accessControlList = kFSFileSecurityRemoveACL;
        else if (source->accessControlList) {
            copy->accessControlList = acl_dup(source->accessControlList);
            if (!copy->accessControlList) {
                CFRelease(copy);
                return NULL;
            }
        }
    }
    return (FSFileSecurityRef)copy;
}

OSStatus
FSFileSecurityGetOwner(FSFileSecurityRef fileSec, UInt32 *owner)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !owner)
        return paramErr;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasOwner)
        return errFSPropertyNotValid;
    *owner = security->owner;
    return noErr;
}

OSStatus
FSFileSecuritySetOwner(FSFileSecurityRef fileSec, UInt32 owner)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID())
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    security->owner = owner;
    security->hasOwner = true;
    return noErr;
}

OSStatus
FSFileSecurityGetGroup(FSFileSecurityRef fileSec, UInt32 *group)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !group)
        return paramErr;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasGroup)
        return errFSPropertyNotValid;
    *group = security->group;
    return noErr;
}

OSStatus
FSFileSecuritySetGroup(FSFileSecurityRef fileSec, UInt32 group)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID())
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    security->group = group;
    security->hasGroup = true;
    return noErr;
}

OSStatus
FSFileSecurityGetMode(FSFileSecurityRef fileSec, UInt16 *mode)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !mode)
        return paramErr;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasMode)
        return errFSPropertyNotValid;
    *mode = security->mode;
    return noErr;
}

OSStatus
FSFileSecuritySetMode(FSFileSecurityRef fileSec, UInt16 mode)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID())
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    security->mode = mode;
    security->hasMode = true;
    return noErr;
}

OSStatus
FSFileSecurityGetOwnerUUID(FSFileSecurityRef fileSec, CFUUIDBytes *owner)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !owner)
        return paramErr;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasOwnerUUID)
        return errFSPropertyNotValid;
    *owner = security->ownerUUID;
    return noErr;
}

OSStatus
FSFileSecuritySetOwnerUUID(FSFileSecurityRef fileSec, const CFUUIDBytes *owner)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !owner)
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    security->ownerUUID = *owner;
    security->hasOwnerUUID = true;
    return noErr;
}

OSStatus
FSFileSecurityGetGroupUUID(FSFileSecurityRef fileSec, CFUUIDBytes *group)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !group)
        return paramErr;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasGroupUUID)
        return errFSPropertyNotValid;
    *group = security->groupUUID;
    return noErr;
}

OSStatus
FSFileSecuritySetGroupUUID(FSFileSecurityRef fileSec, const CFUUIDBytes *group)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !group)
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    security->groupUUID = *group;
    security->hasGroupUUID = true;
    return noErr;
}

OSStatus
FSFileSecurityCopyAccessControlList(FSFileSecurityRef fileSec, acl_t *accessControlList)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID() || !accessControlList)
        return paramErr;
    *accessControlList = NULL;
    const struct __FSFileSecurity *security = (const struct __FSFileSecurity *)fileSec;
    if (!security->hasACL)
        return errFSPropertyNotValid;
    if (security->accessControlList == kFSFileSecurityRemoveACL) {
        *accessControlList = kFSFileSecurityRemoveACL;
        return noErr;
    }
    if (security->accessControlList) {
        *accessControlList = acl_dup(security->accessControlList);
        if (!*accessControlList)
            return memFullErr;
    }
    return noErr;
}

OSStatus
FSFileSecuritySetAccessControlList(FSFileSecurityRef fileSec, acl_t accessControlList)
{
    if (!fileSec || CFGetTypeID(fileSec) != FSFileSecurityGetTypeID())
        return paramErr;
    struct __FSFileSecurity *security = (struct __FSFileSecurity *)fileSec;
    acl_t copy = NULL;
    if (accessControlList && accessControlList != kFSFileSecurityRemoveACL) {
        copy = acl_dup(accessControlList);
        if (!copy)
            return paramErr;
    }
    if (security->hasACL && security->accessControlList &&
        security->accessControlList != kFSFileSecurityRemoveACL)
        acl_free(security->accessControlList);
    security->accessControlList = accessControlList == kFSFileSecurityRemoveACL ? kFSFileSecurityRemoveACL : copy;
    security->hasACL = accessControlList != NULL;
    return noErr;
}

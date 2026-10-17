/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Access objects: SecAccess, SecACL, SecTrustedApplication (the file
 * keychain's access lists) and SecAccessControl (data-protection keychain
 * access). Finch's keychain doesn't enforce access lists yet
 * (docs/design/SECURITY.md): these objects are made, inspected and attached
 * as on macOS, and record what the caller asked for.
 */
#include "SecInternal.h"
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static bool isType(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}

/* ---- Trusted applications ---- */

typedef struct {
	CFRuntimeBase base;
	CFDataRef data;   /* the path, or the group name */
	bool group;
} TrustedApp;
static void appFree(CFTypeRef o)
{
	CFRelease(((TrustedApp *)o)->data);
}
SEC_DEFINE_TYPE(SecTrustedApplicationGetTypeID, "SecTrustedApplication", appFree, NULL, NULL)

static SecTrustedApplicationRef appCreate(const char *s, bool group)
{
	TrustedApp *a = (TrustedApp *)_SecCreateInstance(SecTrustedApplicationGetTypeID(), sizeof(*a));
	a->data = CFDataCreate(NULL, (const UInt8 *)s, strlen(s));
	a->group = group;
	return (SecTrustedApplicationRef)a;
}

OSStatus SecTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef *app)
{
	if (!app)
		return errSecParam;
	char self[PATH_MAX];
	uint32_t size = sizeof(self);
	if (!path) {
		if (_NSGetExecutablePath(self, &size) != 0)
			return errSecParam;
		path = self;
	}
	*app = appCreate(path, false);
	return 0;
}

OSStatus SecTrustedApplicationCreateApplicationGroup(const char *groupName, SecCertificateRef anchor,
    SecTrustedApplicationRef *app)
{
	if (!groupName || !app)
		return errSecParam;
	*app = appCreate(groupName, true);
	return 0;
}

OSStatus SecTrustedApplicationCopyData(SecTrustedApplicationRef appRef, CFDataRef *data)
{
	if (!isType(appRef, SecTrustedApplicationGetTypeID()) || !data)
		return errSecParam;
	*data = CFRetain(((TrustedApp *)appRef)->data);
	return 0;
}

OSStatus SecTrustedApplicationSetData(SecTrustedApplicationRef appRef, CFDataRef data)
{
	if (!isType(appRef, SecTrustedApplicationGetTypeID()) || !isType(data, CFDataGetTypeID()))
		return errSecParam;
	CFRelease(((TrustedApp *)appRef)->data);
	((TrustedApp *)appRef)->data = CFDataCreateCopy(NULL, data);
	return 0;
}

/* ---- ACLs and access ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef description;
	CFArrayRef apps;
	CFArrayRef authorizations;
	SecKeychainPromptSelector promptSelector;
} ACL;
static void aclFree(CFTypeRef o)
{
	ACL *a = (ACL *)o;
	if (a->description)
		CFRelease(a->description);
	if (a->apps)
		CFRelease(a->apps);
	if (a->authorizations)
		CFRelease(a->authorizations);
}
SEC_DEFINE_TYPE(SecACLGetTypeID, "SecACL", aclFree, NULL, NULL)

typedef struct {
	CFRuntimeBase base;
	CFMutableArrayRef acls;
	uid_t userID;
	gid_t groupID;
	SecAccessOwnerType ownerType;
} Access;
static void accessFree(CFTypeRef o)
{
	CFRelease(((Access *)o)->acls);
}
SEC_DEFINE_TYPE(SecAccessGetTypeID, "SecAccess", accessFree, NULL, NULL)

static ACL *aclCreate(CFStringRef description, CFArrayRef apps, CFArrayRef authorizations)
{
	ACL *a = (ACL *)_SecCreateInstance(SecACLGetTypeID(), sizeof(*a));
	a->description = description ? CFRetain(description) : CFSTR("");
	a->apps = apps ? CFArrayCreateCopy(NULL, apps) : NULL;
	a->authorizations = authorizations ? CFArrayCreateCopy(NULL, authorizations) : NULL;
	return a;
}

static CFStringRef authorizationString(CSSM_ACL_AUTHORIZATION_TAG tag)
{
	switch (tag) {
	case CSSM_ACL_AUTHORIZATION_ANY: return kSecACLAuthorizationAny;
	case CSSM_ACL_AUTHORIZATION_LOGIN: return kSecACLAuthorizationLogin;
	case CSSM_ACL_AUTHORIZATION_GENKEY: return kSecACLAuthorizationGenKey;
	case CSSM_ACL_AUTHORIZATION_DELETE: return kSecACLAuthorizationDelete;
	case CSSM_ACL_AUTHORIZATION_EXPORT_WRAPPED: return kSecACLAuthorizationExportWrapped;
	case CSSM_ACL_AUTHORIZATION_EXPORT_CLEAR: return kSecACLAuthorizationExportClear;
	case CSSM_ACL_AUTHORIZATION_IMPORT_WRAPPED: return kSecACLAuthorizationImportWrapped;
	case CSSM_ACL_AUTHORIZATION_IMPORT_CLEAR: return kSecACLAuthorizationImportClear;
	case CSSM_ACL_AUTHORIZATION_SIGN: return kSecACLAuthorizationSign;
	case CSSM_ACL_AUTHORIZATION_ENCRYPT: return kSecACLAuthorizationEncrypt;
	case CSSM_ACL_AUTHORIZATION_DECRYPT: return kSecACLAuthorizationDecrypt;
	case CSSM_ACL_AUTHORIZATION_MAC: return kSecACLAuthorizationMAC;
	case CSSM_ACL_AUTHORIZATION_DERIVE: return kSecACLAuthorizationDerive;
	case CSSM_ACL_AUTHORIZATION_DBS_CREATE: return kSecACLAuthorizationKeychainCreate;
	case CSSM_ACL_AUTHORIZATION_DBS_DELETE: return kSecACLAuthorizationKeychainDelete;
	case CSSM_ACL_AUTHORIZATION_DB_READ: return kSecACLAuthorizationKeychainItemRead;
	case CSSM_ACL_AUTHORIZATION_DB_INSERT: return kSecACLAuthorizationKeychainItemInsert;
	case CSSM_ACL_AUTHORIZATION_DB_MODIFY: return kSecACLAuthorizationKeychainItemModify;
	case CSSM_ACL_AUTHORIZATION_DB_DELETE: return kSecACLAuthorizationKeychainItemDelete;
	default: return NULL;
	}
}

static bool authorizationTag(CFTypeRef value, CSSM_ACL_AUTHORIZATION_TAG *tag)
{
	static const CSSM_ACL_AUTHORIZATION_TAG tags[] = {
		CSSM_ACL_AUTHORIZATION_ANY, CSSM_ACL_AUTHORIZATION_LOGIN, CSSM_ACL_AUTHORIZATION_GENKEY,
		CSSM_ACL_AUTHORIZATION_DELETE, CSSM_ACL_AUTHORIZATION_EXPORT_WRAPPED,
		CSSM_ACL_AUTHORIZATION_EXPORT_CLEAR, CSSM_ACL_AUTHORIZATION_IMPORT_WRAPPED,
		CSSM_ACL_AUTHORIZATION_IMPORT_CLEAR, CSSM_ACL_AUTHORIZATION_SIGN,
		CSSM_ACL_AUTHORIZATION_ENCRYPT, CSSM_ACL_AUTHORIZATION_DECRYPT, CSSM_ACL_AUTHORIZATION_MAC,
		CSSM_ACL_AUTHORIZATION_DERIVE, CSSM_ACL_AUTHORIZATION_DBS_CREATE,
		CSSM_ACL_AUTHORIZATION_DBS_DELETE, CSSM_ACL_AUTHORIZATION_DB_READ,
		CSSM_ACL_AUTHORIZATION_DB_INSERT, CSSM_ACL_AUTHORIZATION_DB_MODIFY,
		CSSM_ACL_AUTHORIZATION_DB_DELETE
	};
	for (size_t i = 0; i < sizeof(tags) / sizeof(*tags); i++) {
		CFStringRef string = authorizationString(tags[i]);
		if (string && CFEqual(value, string)) {
			*tag = tags[i];
			return true;
		}
	}
	return false;
}

static CFArrayRef matchingACLs(Access *access, CFTypeRef authorization)
{
	CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(access->acls); i++) {
		ACL *acl = (ACL *)CFArrayGetValueAtIndex(access->acls, i);
		CFArrayRef auth = acl->authorizations;
		CFStringRef any[] = {kSecACLAuthorizationAny};
		CFArrayRef defaults = NULL;
		if (!auth) {
			defaults = CFArrayCreate(NULL, (const void **)any, 1, &kCFTypeArrayCallBacks);
			auth = defaults;
		}
		bool matches = !authorization || CFArrayContainsValue(auth, CFRangeMake(0, CFArrayGetCount(auth)), authorization) ||
		    CFArrayContainsValue(auth, CFRangeMake(0, CFArrayGetCount(auth)), kSecACLAuthorizationAny);
		if (matches)
			CFArrayAppendValue(result, acl);
		if (defaults)
			CFRelease(defaults);
	}
	return result;
}

OSStatus SecAccessCreate(CFStringRef descriptor, CFArrayRef trustedlist, SecAccessRef *accessRef)
{
	if (!accessRef || (descriptor && !isType(descriptor, CFStringGetTypeID())))
		return errSecParam;
	Access *a = (Access *)_SecCreateInstance(SecAccessGetTypeID(), sizeof(*a));
	a->acls = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	a->userID = getuid();
	a->groupID = getgid();
	a->ownerType = kSecUseOnlyUID | kSecUseOnlyGID;
	CFArrayRef apps = trustedlist;
	SecTrustedApplicationRef self = NULL;
	if (!apps) {
		/* NULL: the calling application is trusted. */
		SecTrustedApplicationCreateFromPath(NULL, &self);
		apps = CFArrayCreate(NULL, (const void **)&self, 1, &kCFTypeArrayCallBacks);
	}
	ACL *decrypt = aclCreate(descriptor, apps, NULL);
	CFArrayAppendValue(a->acls, decrypt);
	CFRelease(decrypt);
	if (self) {
		CFRelease(self);
		CFRelease(apps);
	}
	*accessRef = (SecAccessRef)a;
	return 0;
}

OSStatus SecAccessCopyACLList(SecAccessRef accessRef, CFArrayRef *aclList)
{
	if (!isType(accessRef, SecAccessGetTypeID()) || !aclList)
		return errSecParam;
	*aclList = CFArrayCreateCopy(NULL, ((Access *)accessRef)->acls);
	return 0;
}

CFArrayRef SecAccessCopyMatchingACLList(SecAccessRef accessRef, CFTypeRef authorizationTag)
{
	return isType(accessRef, SecAccessGetTypeID()) ? matchingACLs((Access *)accessRef, authorizationTag) : NULL;
}

OSStatus SecAccessCopySelectedACLList(SecAccessRef accessRef, CSSM_ACL_AUTHORIZATION_TAG action, CFArrayRef *aclList)
{
	if (!isType(accessRef, SecAccessGetTypeID()) || !aclList)
		return errSecParam;
	CFStringRef authorization = authorizationString(action);
	if (!authorization)
		return errSecParam;
	*aclList = matchingACLs((Access *)accessRef, authorization);
	return 0;
}

SecAccessRef SecAccessCreateWithOwnerAndACL(uid_t userID, gid_t groupID, SecAccessOwnerType ownerType,
    CFArrayRef acls, CFErrorRef *error)
{
	if ((ownerType & ~(kSecMatchBits | kSecHonorRoot)) || !(ownerType & kSecMatchBits) ||
	    ((ownerType & kSecMatchBits) == kSecMatchBits)) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	if (acls && !isType(acls, CFArrayGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	for (CFIndex i = 0; acls && i < CFArrayGetCount(acls); i++) {
		if (!isType(CFArrayGetValueAtIndex(acls, i), SecACLGetTypeID())) {
			_SecSetError(error, errSecParam, NULL);
			return NULL;
		}
	}
	Access *a = (Access *)_SecCreateInstance(SecAccessGetTypeID(), sizeof(*a));
	a->acls = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; acls && i < CFArrayGetCount(acls); i++)
		CFArrayAppendValue(a->acls, CFArrayGetValueAtIndex(acls, i));
	a->userID = userID;
	a->groupID = groupID;
	a->ownerType = ownerType;
	return (SecAccessRef)a;
}

OSStatus SecAccessCopyOwnerAndACL(SecAccessRef accessRef, uid_t *userID, gid_t *groupID,
    SecAccessOwnerType *ownerType, CFArrayRef *aclList)
{
	if (!isType(accessRef, SecAccessGetTypeID()))
		return errSecParam;
	Access *a = (Access *)accessRef;
	if (userID) *userID = a->userID;
	if (groupID) *groupID = a->groupID;
	if (ownerType) *ownerType = a->ownerType;
	if (aclList) *aclList = CFArrayCreateCopy(NULL, a->acls);
	return 0;
}

OSStatus SecACLCreateWithSimpleContents(SecAccessRef access, CFArrayRef applicationList, CFStringRef description,
    SecKeychainPromptSelector promptSelector, SecACLRef *newAcl)
{
	if (!isType(access, SecAccessGetTypeID()) || !newAcl)
		return errSecParam;
	ACL *acl = aclCreate(description, applicationList, NULL);
	CFArrayAppendValue(((Access *)access)->acls, acl);
	*newAcl = (SecACLRef)acl;
	return 0;
}

OSStatus SecACLCreateFromSimpleContents(SecAccessRef access, CFArrayRef applicationList, CFStringRef description,
    const CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR *promptSelector, SecACLRef *newAcl)
{
	OSStatus status = SecACLCreateWithSimpleContents(access, applicationList, description,
	    promptSelector ? promptSelector->flags : 0, newAcl);
	if (!status && promptSelector)
		((ACL *)*newAcl)->promptSelector = promptSelector->flags;
	return status;
}

OSStatus SecACLCopyContents(SecACLRef acl, CFArrayRef *applicationList, CFStringRef *description,
    SecKeychainPromptSelector *promptSelector)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (applicationList)
		*applicationList = a->apps ? CFRetain(a->apps) : NULL;
	if (description)
		*description = CFRetain(a->description);
	if (promptSelector)
		*promptSelector = a->promptSelector;
	return 0;
}

OSStatus SecACLCopySimpleContents(SecACLRef acl, CFArrayRef *applicationList, CFStringRef *description,
    CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR *promptSelector)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (applicationList) *applicationList = a->apps ? CFRetain(a->apps) : NULL;
	if (description) *description = CFRetain(a->description);
	if (promptSelector) {
		promptSelector->version = CSSM_ACL_KEYCHAIN_PROMPT_CURRENT_VERSION;
		promptSelector->flags = a->promptSelector;
	}
	return 0;
}

OSStatus SecACLSetContents(SecACLRef acl, CFArrayRef applicationList, CFStringRef description,
    SecKeychainPromptSelector promptSelector)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (a->apps)
		CFRelease(a->apps);
	a->apps = applicationList ? CFArrayCreateCopy(NULL, applicationList) : NULL;
	if (description) {
		CFRelease(a->description);
		a->description = CFRetain(description);
	}
	a->promptSelector = promptSelector;
	return 0;
}

OSStatus SecACLSetSimpleContents(SecACLRef acl, CFArrayRef applicationList, CFStringRef description,
    const CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR *promptSelector)
{
	OSStatus status = SecACLSetContents(acl, applicationList, description,
	    promptSelector ? promptSelector->flags : 0);
	if (!status && promptSelector)
		((ACL *)acl)->promptSelector = promptSelector->flags;
	return status;
}

CFArrayRef SecACLCopyAuthorizations(SecACLRef acl)
{
	if (!isType(acl, SecACLGetTypeID()))
		return NULL;
	ACL *a = (ACL *)acl;
	return a->authorizations ? CFRetain(a->authorizations) : CFArrayCreate(NULL, (const void *[]){kSecACLAuthorizationAny}, 1, &kCFTypeArrayCallBacks);
}

OSStatus SecACLUpdateAuthorizations(SecACLRef acl, CFArrayRef authorizations)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (a->authorizations)
		CFRelease(a->authorizations);
	a->authorizations = authorizations ? CFArrayCreateCopy(NULL, authorizations) : NULL;
	return 0;
}

OSStatus SecACLGetAuthorizations(SecACLRef acl, CSSM_ACL_AUTHORIZATION_TAG *tags, uint32 *tagCount)
{
	if (!isType(acl, SecACLGetTypeID()) || !tagCount)
		return errSecParam;
	CFArrayRef values = SecACLCopyAuthorizations(acl);
	uint32 count = (uint32)CFArrayGetCount(values);
	uint32 capacity = *tagCount;
	*tagCount = count;
	if (!tags) {
		CFRelease(values);
		return 0;
	}
	if (capacity < count) {
		CFRelease(values);
		return errSecBufferTooSmall;
	}
	for (uint32 i = 0; i < count; i++) {
		if (!authorizationTag(CFArrayGetValueAtIndex(values, i), &tags[i])) {
			CFRelease(values);
			return errSecParam;
		}
	}
	CFRelease(values);
	return 0;
}

OSStatus SecACLSetAuthorizations(SecACLRef acl, CSSM_ACL_AUTHORIZATION_TAG *tags, uint32 tagCount)
{
	if (!isType(acl, SecACLGetTypeID()) || (tagCount && !tags))
		return errSecParam;
	CFMutableArrayRef values = CFArrayCreateMutable(NULL, tagCount, &kCFTypeArrayCallBacks);
	CSSM_ACL_AUTHORIZATION_TAG *sorted = tagCount ? malloc(tagCount * sizeof(*sorted)) : NULL;
	if (tagCount && !sorted) {
		CFRelease(values);
		return errSecAllocate;
	}
	if (tagCount) {
		memcpy(sorted, tags, tagCount * sizeof(*sorted));
		for (uint32 i = 1; i < tagCount; i++) {
			CSSM_ACL_AUTHORIZATION_TAG current = sorted[i];
			uint32 j = i;
			while (j && sorted[j - 1] > current) {
				sorted[j] = sorted[j - 1];
				j--;
			}
			sorted[j] = current;
		}
	}
	for (uint32 i = 0; i < tagCount; i++) {
		CFStringRef value = authorizationString(sorted[i]);
		if (!value) {
			free(sorted);
			CFRelease(values);
			return errSecParam;
		}
		CFArrayAppendValue(values, value);
	}
	free(sorted);
	OSStatus status = SecACLUpdateAuthorizations(acl, values);
	CFRelease(values);
	return status;
}

OSStatus SecACLRemove(SecACLRef aclRef)
{
	return isType(aclRef, SecACLGetTypeID()) ? 0 : errSecParam;
}

/* ---- Access control (data-protection keychain) ---- */

typedef struct {
	CFRuntimeBase base;
	CFTypeRef protection;
	SecAccessControlCreateFlags flags;
} AccessControl;
static void acFree(CFTypeRef o)
{
	CFRelease(((AccessControl *)o)->protection);
}
static Boolean acEqual(CFTypeRef a, CFTypeRef b)
{
	return ((AccessControl *)a)->flags == ((AccessControl *)b)->flags &&
	    CFEqual(((AccessControl *)a)->protection, ((AccessControl *)b)->protection);
}
SEC_DEFINE_TYPE(SecAccessControlGetTypeID, "SecAccessControl", acFree, acEqual, NULL)

SecAccessControlRef SecAccessControlCreateWithFlags(CFAllocatorRef allocator, CFTypeRef protection,
    SecAccessControlCreateFlags flags, CFErrorRef *error)
{
	CFTypeRef valid[] = {kSecAttrAccessibleWhenUnlocked, kSecAttrAccessibleAfterFirstUnlock,
	    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
	    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecAttrAccessibleAlways, kSecAttrAccessibleAlwaysThisDeviceOnly};
	bool ok = false;
	for (size_t i = 0; protection && i < sizeof(valid) / sizeof(*valid); i++)
		ok = ok || CFEqual(protection, valid[i]);
	if (!ok) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	AccessControl *a = (AccessControl *)_SecCreateInstance(SecAccessControlGetTypeID(), sizeof(*a));
	a->protection = CFRetain(protection);
	a->flags = flags;
	return (SecAccessControlRef)a;
}

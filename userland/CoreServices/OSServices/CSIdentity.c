/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local POSIX users and groups, with private copies for pending edits. */
#include <CoreFoundation/CFRuntime.h>
#include <OSServices/CSIdentity.h>
#include <OSServices/CSIdentityAuthority.h>
#include <OSServices/CSIdentityQuery.h>
#include <SystemConfiguration/SCDynamicStoreCopySpecific.h>
#include <membership.h>
#include <grp.h>
#include <pwd.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

enum { kAuthorityDefault = 0, kAuthorityLocal = 1, kAuthorityManaged = 2 };
enum { kQueryAll, kQueryName, kQueryUUID, kQueryPosixID, kQueryCurrentUser, kQueryReference, kQueryMembers };

struct __CSIdentityAuthority {
    CFRuntimeBase base;
    CFIndex kind;
};

struct __CSIdentity {
    CFRuntimeBase base;
    CSIdentityClass identityClass;
    CSIdentityAuthorityRef authority;
    CFUUIDRef uuid;
    CFStringRef fullName;
    CFStringRef posixName;
    CFStringRef emailAddress;
    CFURLRef imageURL;
    CFDataRef imageData;
    CFStringRef imageDataType;
    SecCertificateRef certificate;
    CFMutableArrayRef aliases;
    CFMutableArrayRef members;
    id_t posixID;
    Boolean enabled;
    Boolean hidden;
    Boolean deleted;
    Boolean dirty;
    pthread_mutex_t clientLock;
    Boolean clientLockInitialized;
    Boolean clientRemoved;
    Boolean committing;
};

struct __CSIdentityQuery {
    CFRuntimeBase base;
    CSIdentityAuthorityRef authority;
    CSIdentityClass identityClass;
    CFIndex kind;
    CFIndex comparison;
    CSIdentityQueryFlags flags;
    id_t posixID;
    CFStringRef name;
    CFUUIDRef uuid;
    CSIdentityRef group;
    CFArrayRef results;
    Boolean stopped;
    Boolean executed;
    Boolean clientRemoved;
    CSIdentityQueryReceiveEventCallback callback;
    void *clientInfo;
    CFAllocatorReleaseCallBack releaseInfo;
};

static void identity_finalize(CFTypeRef value);
static void query_finalize(CFTypeRef value);
static Boolean identity_equal(CFTypeRef left, CFTypeRef right);
static CFHashCode identity_hash(CFTypeRef value);

static const CFRuntimeClass authority_class = { .className = "CSIdentityAuthority" };
static const CFRuntimeClass identity_runtime_class = {
    .className = "CSIdentity", .finalize = identity_finalize, .equal = identity_equal, .hash = identity_hash
};
static const CFRuntimeClass query_runtime_class = { .className = "CSIdentityQuery", .finalize = query_finalize };
static CFTypeID authority_type, identity_type, query_type;
static CSIdentityAuthorityRef authorities[3];
static pthread_mutex_t directory_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t authority_lock = PTHREAD_MUTEX_INITIALIZER;

static void
identity_finalize(CFTypeRef value)
{
    struct __CSIdentity *identity = (struct __CSIdentity *)value;
    if (identity->authority) CFRelease(identity->authority);
    if (identity->uuid) CFRelease(identity->uuid);
    if (identity->fullName) CFRelease(identity->fullName);
    if (identity->posixName) CFRelease(identity->posixName);
    if (identity->emailAddress) CFRelease(identity->emailAddress);
    if (identity->imageURL) CFRelease(identity->imageURL);
    if (identity->imageData) CFRelease(identity->imageData);
    if (identity->imageDataType) CFRelease(identity->imageDataType);
    if (identity->certificate) CFRelease(identity->certificate);
    if (identity->aliases) CFRelease(identity->aliases);
    if (identity->members) CFRelease(identity->members);
    if (identity->clientLockInitialized) pthread_mutex_destroy(&identity->clientLock);
}

static void
query_finalize(CFTypeRef value)
{
    struct __CSIdentityQuery *query = (struct __CSIdentityQuery *)value;
    if (query->authority) CFRelease(query->authority);
    if (query->name) CFRelease(query->name);
    if (query->uuid) CFRelease(query->uuid);
    if (query->group) CFRelease(query->group);
    if (query->results) CFRelease(query->results);
    if (query->releaseInfo && query->clientInfo) query->releaseInfo(query->clientInfo);
}

static Boolean
identity_equal(CFTypeRef left, CFTypeRef right)
{
    const struct __CSIdentity *a = (const struct __CSIdentity *)left;
    const struct __CSIdentity *b = (const struct __CSIdentity *)right;
    return a->identityClass == b->identityClass && CFEqual(a->uuid, b->uuid);
}

static CFHashCode
identity_hash(CFTypeRef value)
{
    const struct __CSIdentity *identity = (const struct __CSIdentity *)value;
    return CFHash(identity->uuid) ^ (CFHashCode)identity->identityClass;
}

static void
register_classes(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        authority_type = _CFRuntimeRegisterClass(&authority_class);
        identity_type = _CFRuntimeRegisterClass(&identity_runtime_class);
        query_type = _CFRuntimeRegisterClass(&query_runtime_class);
    });
}

static CFTypeRef
create_cf(CFAllocatorRef allocator, CFTypeID type, size_t size)
{
    return _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

static CSIdentityAuthorityRef
authority_for_kind(CFIndex kind)
{
    register_classes();
    pthread_mutex_lock(&authority_lock);
    if (!authorities[kind]) {
        struct __CSIdentityAuthority *authority = (struct __CSIdentityAuthority *)create_cf(
            kCFAllocatorDefault, authority_type, sizeof(struct __CSIdentityAuthority));
        if (authority) {
            authority->kind = kind;
            authorities[kind] = authority;
        }
    }
    CSIdentityAuthorityRef result = authorities[kind];
    pthread_mutex_unlock(&authority_lock);
    return result;
}

static Boolean
is_authority(CSIdentityAuthorityRef authority)
{
    return authority && CFGetTypeID(authority) == CSIdentityAuthorityGetTypeID();
}

static Boolean
is_identity(CSIdentityRef identity)
{
    return identity && CFGetTypeID(identity) == CSIdentityGetTypeID();
}

static Boolean
is_query(CSIdentityQueryRef query)
{
    return query && CFGetTypeID(query) == CSIdentityQueryGetTypeID();
}

static CFUUIDRef
uuid_for_posix(CSIdentityClass identityClass, id_t posixID)
{
    uuid_t bytes;
    int status = identityClass == kCSIdentityClassUser
        ? mbr_uid_to_uuid((uid_t)posixID, bytes)
        : mbr_gid_to_uuid((gid_t)posixID, bytes);
    if (status != 0) return NULL;
    CFUUIDBytes value;
    memcpy(&value, bytes, sizeof value);
    return CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, value);
}

static CFUUIDRef
uuid_from_bytes(const UInt8 bytes[16])
{
    CFUUIDBytes value;
    memcpy(&value, bytes, sizeof value);
    return CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, value);
}

static CFStringRef
string_from_c(const char *value)
{
    return value ? CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8) : NULL;
}

static CFStringRef
full_name_from_gecos(const char *gecos, const char *fallback)
{
    if (!gecos || !*gecos) return string_from_c(fallback);
    size_t length = strcspn(gecos, ",");
    while (length && (gecos[length - 1] == ' ' || gecos[length - 1] == '\t')) length--;
    if (!length) return string_from_c(fallback);
    return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)gecos, (CFIndex)length,
                                   kCFStringEncodingUTF8, false);
}

static struct __CSIdentity *
identity_create(CFAllocatorRef allocator, CSIdentityClass identityClass, id_t posixID,
               CFStringRef fullName, CFStringRef posixName, CFUUIDRef uuid,
               CSIdentityAuthorityRef authority, Boolean hidden)
{
    register_classes();
    struct __CSIdentity *identity = (struct __CSIdentity *)create_cf(allocator, identity_type,
                                                                      sizeof(struct __CSIdentity));
    if (!identity) return NULL;
    identity->identityClass = identityClass;
    identity->authority = authority ? (CSIdentityAuthorityRef)CFRetain(authority) :
                                      (CSIdentityAuthorityRef)CFRetain(authority_for_kind(kAuthorityLocal));
    identity->uuid = uuid ? (CFUUIDRef)CFRetain(uuid) : CFUUIDCreate(kCFAllocatorDefault);
    identity->fullName = fullName ? (CFStringRef)CFRetain(fullName) : CFSTR("");
    if (!fullName) CFRetain(identity->fullName);
    identity->posixName = posixName ? (CFStringRef)CFRetain(posixName) : CFSTR("");
    if (!posixName) CFRetain(identity->posixName);
    identity->aliases = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    identity->members = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    identity->clientLockInitialized = pthread_mutex_init(&identity->clientLock, NULL) == 0;
    identity->posixID = posixID;
    identity->enabled = true;
    identity->hidden = hidden;
    if (!identity->authority || !identity->uuid || !identity->fullName || !identity->posixName ||
        !identity->aliases || !identity->members || !identity->clientLockInitialized) {
        CFRelease(identity);
        return NULL;
    }
    return identity;
}

static CSIdentityRef
identity_from_passwd(CFAllocatorRef allocator, const struct passwd *entry)
{
    if (!entry) return NULL;
    CFStringRef name = string_from_c(entry->pw_name);
    CFStringRef full = full_name_from_gecos(entry->pw_gecos, entry->pw_name);
    CFUUIDRef uuid = uuid_for_posix(kCSIdentityClassUser, entry->pw_uid);
    Boolean hidden = entry->pw_uid < 501 || (entry->pw_name && entry->pw_name[0] == '_');
    struct __CSIdentity *identity = identity_create(allocator, kCSIdentityClassUser, entry->pw_uid,
                                                     full, name, uuid, authority_for_kind(kAuthorityLocal), hidden);
    if (identity && name) CFArrayAppendValue(identity->aliases, name);
    if (name) CFRelease(name);
    if (full) CFRelease(full);
    if (uuid) CFRelease(uuid);
    return (CSIdentityRef)identity;
}

static CSIdentityRef
identity_from_group(CFAllocatorRef allocator, const struct group *entry)
{
    if (!entry) return NULL;
    CFStringRef name = string_from_c(entry->gr_name);
    CFUUIDRef uuid = uuid_for_posix(kCSIdentityClassGroup, entry->gr_gid);
    Boolean hidden = entry->gr_gid < 501 || (entry->gr_name && entry->gr_name[0] == '_');
    struct __CSIdentity *identity = identity_create(allocator, kCSIdentityClassGroup, entry->gr_gid,
                                                     name, name, uuid, authority_for_kind(kAuthorityLocal), hidden);
    if (name) CFRelease(name);
    if (uuid) CFRelease(uuid);
    return (CSIdentityRef)identity;
}

static CFErrorRef
identity_error(CFIndex code, CFStringRef description)
{
    const void *keys[] = { kCFErrorDescriptionKey };
    const void *values[] = { description ? description : CFSTR("Identity service is not available") };
    CFDictionaryRef info = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFErrorRef error = CFErrorCreate(kCFAllocatorDefault, kCSIdentityErrorDomain, code, info);
    if (info) CFRelease(info);
    return error;
}

static Boolean
string_matches(CFStringRef candidate, CFStringRef query, CFIndex comparison)
{
    if (!candidate || !query) return false;
    CFComparisonResult result = CFStringCompare(candidate, query, kCFCompareCaseInsensitive);
    if (comparison == kCSIdentityQueryStringEquals) return result == kCFCompareEqualTo;
    if (comparison != kCSIdentityQueryStringBeginsWith) return false;
    CFRange range = CFStringFind(candidate, query, kCFCompareCaseInsensitive | kCFCompareAnchored);
    return range.location == 0;
}

static CSIdentityRef
identity_copy(CFAllocatorRef allocator, CSIdentityRef source)
{
    if (!is_identity(source)) return NULL;
    struct __CSIdentity *copy = identity_create(allocator, source->identityClass, source->posixID,
                                                source->fullName, source->posixName, source->uuid,
                                                source->authority, source->hidden);
    if (!copy) return NULL;
    copy->enabled = source->enabled;
    copy->deleted = source->deleted;
    copy->dirty = source->dirty;
    if (source->emailAddress) copy->emailAddress = CFRetain(source->emailAddress);
    if (source->imageURL) copy->imageURL = CFRetain(source->imageURL);
    if (source->imageData) copy->imageData = CFRetain(source->imageData);
    if (source->imageDataType) copy->imageDataType = CFRetain(source->imageDataType);
    if (source->certificate) copy->certificate = (SecCertificateRef)CFRetain(source->certificate);
    CFArrayAppendArray(copy->aliases, source->aliases, CFRangeMake(0, CFArrayGetCount(source->aliases)));
    CFArrayAppendArray(copy->members, source->members, CFRangeMake(0, CFArrayGetCount(source->members)));
    return (CSIdentityRef)copy;
}

static CSIdentityQueryRef
query_create(CFAllocatorRef allocator, CFIndex kind, CSIdentityClass identityClass,
             CSIdentityAuthorityRef authority)
{
    register_classes();
    if (authority && !is_authority(authority)) return NULL;
    struct __CSIdentityQuery *query = (struct __CSIdentityQuery *)create_cf(allocator, query_type,
                                                                            sizeof(struct __CSIdentityQuery));
    if (!query) return NULL;
    query->kind = kind;
    query->identityClass = identityClass;
    query->authority = authority ? (CSIdentityAuthorityRef)CFRetain(authority) :
                                   (CSIdentityAuthorityRef)CFRetain(authority_for_kind(kAuthorityDefault));
    if (!query->authority) {
        CFRelease(query);
        return NULL;
    }
    return (CSIdentityQueryRef)query;
}

static void
query_add_if_match(struct __CSIdentityQuery *query, CFMutableArrayRef results, CSIdentityRef identity)
{
    if (!identity) return;
    struct __CSIdentity *item = (struct __CSIdentity *)identity;
    Boolean match = !item->deleted &&
        ((query->flags & kCSIdentityQueryIncludeHiddenIdentities) || !item->hidden);
    if (query->identityClass && item->identityClass != query->identityClass) match = false;
    switch (query->kind) {
    case kQueryName:
        {
            Boolean nameMatch = string_matches(item->posixName, query->name, query->comparison) ||
                                string_matches(item->fullName, query->name, query->comparison);
            for (CFIndex i = 0; !nameMatch && i < CFArrayGetCount(item->aliases); i++)
                nameMatch = string_matches(CFArrayGetValueAtIndex(item->aliases, i), query->name, query->comparison);
            match = match && nameMatch;
        }
        break;
    case kQueryUUID:
    case kQueryReference:
        match = match && item->uuid && query->uuid && CFEqual(item->uuid, query->uuid) &&
                (!query->identityClass || item->identityClass == query->identityClass);
        break;
    case kQueryPosixID:
        match = match && item->posixID == query->posixID;
        break;
    case kQueryCurrentUser:
        match = match && item->identityClass == kCSIdentityClassUser && item->posixID == getuid();
        break;
    case kQueryMembers:
        if (query->group && query->group->identityClass == kCSIdentityClassGroup) {
            Boolean explicitMember = false;
            for (CFIndex i = 0; i < CFArrayGetCount(query->group->members); i++)
                explicitMember |= CFEqual(CFArrayGetValueAtIndex(query->group->members, i), item->uuid);
            if (!explicitMember) {
                if (item->identityClass == kCSIdentityClassUser) {
                    struct passwd *user = getpwuid((uid_t)item->posixID);
                    struct group *group = getgrgid((gid_t)query->group->posixID);
                    match = match && group && ((user && user->pw_gid == group->gr_gid));
                    if (match && group->gr_mem) {
                        Boolean listed = false;
                        for (char **member = group->gr_mem; *member; member++) {
                            CFStringRef memberName = string_from_c(*member);
                            listed |= memberName && CFEqual(memberName, item->posixName);
                            if (memberName) CFRelease(memberName);
                        }
                        match = listed || (user && user->pw_gid == group->gr_gid);
                    }
                } else {
                    match = false;
                }
            }
        } else match = false;
        break;
    default:
        break;
    }
    if (match) CFArrayAppendValue(results, identity);
    CFRelease(identity);
}

static CFArrayRef
query_run(struct __CSIdentityQuery *query)
{
    CFMutableArrayRef results = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!results || query->stopped || !query->authority) return results;
    if (((struct __CSIdentityAuthority *)query->authority)->kind == kAuthorityManaged) return results;

    pthread_mutex_lock(&directory_lock);
    if (query->kind == kQueryCurrentUser || query->kind == kQueryPosixID) {
        CSIdentityClass cls = query->identityClass ? query->identityClass : kCSIdentityClassUser;
        id_t id = query->kind == kQueryCurrentUser ? (id_t)getuid() : query->posixID;
        if (cls == kCSIdentityClassUser) query_add_if_match(query, results, identity_from_passwd(kCFAllocatorDefault, getpwuid((uid_t)id)));
        else if (cls == kCSIdentityClassGroup) query_add_if_match(query, results, identity_from_group(kCFAllocatorDefault, getgrgid((gid_t)id)));
    } else if (query->kind == kQueryUUID || query->kind == kQueryReference) {
        if (query->uuid) {
            CFUUIDBytes bytes = CFUUIDGetUUIDBytes(query->uuid);
            uuid_t raw;
            memcpy(raw, &bytes, sizeof raw);
            id_t id = 0;
            int type = 0;
            if (mbr_uuid_to_id(raw, &id, &type) == 0) {
                CSIdentityClass cls = type == ID_TYPE_UID ? kCSIdentityClassUser :
                                      type == ID_TYPE_GID ? kCSIdentityClassGroup : 0;
                if (cls && (!query->identityClass || query->identityClass == cls)) {
                    if (cls == kCSIdentityClassUser) query_add_if_match(query, results, identity_from_passwd(kCFAllocatorDefault, getpwuid((uid_t)id)));
                    else query_add_if_match(query, results, identity_from_group(kCFAllocatorDefault, getgrgid((gid_t)id)));
                }
            }
        }
    } else {
        if (!query->identityClass || query->identityClass == kCSIdentityClassUser) {
            setpwent();
            struct passwd *entry;
            while (!query->stopped && (entry = getpwent()) != NULL)
                query_add_if_match(query, results, identity_from_passwd(kCFAllocatorDefault, entry));
            endpwent();
        }
        if (!query->identityClass || query->identityClass == kCSIdentityClassGroup) {
            setgrent();
            struct group *entry;
            while (!query->stopped && (entry = getgrent()) != NULL)
                query_add_if_match(query, results, identity_from_group(kCFAllocatorDefault, entry));
            endgrent();
        }
    }
    pthread_mutex_unlock(&directory_lock);
    return results;
}

CFTypeID CSIdentityAuthorityGetTypeID(void) { register_classes(); return authority_type; }
CFTypeID CSIdentityGetTypeID(void) { register_classes(); return identity_type; }
CFTypeID CSIdentityQueryGetTypeID(void) { register_classes(); return query_type; }

CSIdentityAuthorityRef CSGetDefaultIdentityAuthority(void) { return authority_for_kind(kAuthorityDefault); }
CSIdentityAuthorityRef CSGetLocalIdentityAuthority(void) { return authority_for_kind(kAuthorityLocal); }
CSIdentityAuthorityRef CSGetManagedIdentityAuthority(void) { return authority_for_kind(kAuthorityManaged); }

CFStringRef
CSIdentityAuthorityCopyLocalizedName(CSIdentityAuthorityRef authority)
{
    if (!is_authority(authority)) return NULL;
    switch (((struct __CSIdentityAuthority *)authority)->kind) {
    case kAuthorityLocal: {
        CFStringRef computerName = SCDynamicStoreCopyComputerName(NULL, NULL);
        return computerName ? computerName : CFRetain(CFSTR("Local"));
    }
    case kAuthorityManaged: return CFRetain(CFSTR("Directory Services"));
    default: return CFRetain(CFSTR("Search Policy"));
    }
}

CSIdentityRef
CSIdentityCreate(CFAllocatorRef allocator, CSIdentityClass identityClass, CFStringRef fullName,
                 CFStringRef posixName, CSIdentityFlags flags, CSIdentityAuthorityRef authority)
{
    if ((identityClass != kCSIdentityClassUser && identityClass != kCSIdentityClassGroup) ||
        !fullName || !is_authority(authority) ||
        ((struct __CSIdentityAuthority *)authority)->kind != kAuthorityLocal) return NULL;
    CFUUIDRef uuid = CFUUIDCreate(allocator);
    struct __CSIdentity *identity = identity_create(allocator, identityClass, (id_t)-1,
        fullName, posixName == kCSIdentityGeneratePosixName ? NULL : posixName, uuid, authority,
        (flags & kCSIdentityFlagHidden) != 0);
    if (uuid) CFRelease(uuid);
    if (identity) identity->dirty = true;
    return (CSIdentityRef)identity;
}

CSIdentityRef CSIdentityCreateCopy(CFAllocatorRef allocator, CSIdentityRef identity) { return identity_copy(allocator, identity); }
CSIdentityClass CSIdentityGetClass(CSIdentityRef identity) { return is_identity(identity) ? identity->identityClass : 0; }
CSIdentityAuthorityRef CSIdentityGetAuthority(CSIdentityRef identity) { return is_identity(identity) ? identity->authority : NULL; }
CFUUIDRef CSIdentityGetUUID(CSIdentityRef identity) { return is_identity(identity) ? identity->uuid : NULL; }
CFStringRef CSIdentityGetFullName(CSIdentityRef identity) { return is_identity(identity) ? identity->fullName : NULL; }
id_t CSIdentityGetPosixID(CSIdentityRef identity) { return is_identity(identity) ? identity->posixID : (id_t)-1; }
CFStringRef CSIdentityGetPosixName(CSIdentityRef identity) { return is_identity(identity) ? identity->posixName : NULL; }
CFStringRef CSIdentityGetEmailAddress(CSIdentityRef identity) { return is_identity(identity) ? identity->emailAddress : NULL; }
CFURLRef CSIdentityGetImageURL(CSIdentityRef identity) { return is_identity(identity) ? identity->imageURL : NULL; }
CFDataRef CSIdentityGetImageData(CSIdentityRef identity) { return is_identity(identity) ? identity->imageData : NULL; }
CFStringRef CSIdentityGetImageDataType(CSIdentityRef identity) { return is_identity(identity) ? identity->imageDataType : NULL; }
CFArrayRef CSIdentityGetAliases(CSIdentityRef identity) { return is_identity(identity) ? identity->aliases : NULL; }
CFDataRef CSIdentityCreatePersistentReference(CFAllocatorRef allocator, CSIdentityRef identity)
{
    if (!is_identity(identity)) return NULL;
    UInt8 bytes[24] = {'F','C','S','1', 0,0,0,0};
    UInt32 cls = (UInt32)identity->identityClass;
    bytes[4] = (UInt8)(cls >> 24); bytes[5] = (UInt8)(cls >> 16); bytes[6] = (UInt8)(cls >> 8); bytes[7] = (UInt8)cls;
    CFUUIDBytes uuid = CFUUIDGetUUIDBytes(identity->uuid);
    memcpy(bytes + 8, &uuid, 16);
    return CFDataCreate(allocator, bytes, sizeof bytes);
}
Boolean CSIdentityIsEnabled(CSIdentityRef identity) { return is_identity(identity) && identity->enabled; }
Boolean CSIdentityIsHidden(CSIdentityRef identity) { return is_identity(identity) && identity->hidden; }
Boolean
CSIdentityIsCommitting(CSIdentityRef identity)
{
    if (!is_identity(identity) || !identity->clientLockInitialized)
        return false;
    pthread_mutex_lock(&identity->clientLock);
    Boolean committing = identity->committing;
    pthread_mutex_unlock(&identity->clientLock);
    return committing;
}
SecCertificateRef CSIdentityGetCertificate(CSIdentityRef identity) { return is_identity(identity) ? identity->certificate : NULL; }

Boolean
CSIdentityIsMemberOfGroup(CSIdentityRef identity, CSIdentityRef group)
{
    if (!is_identity(identity) || !is_identity(group) || group->identityClass != kCSIdentityClassGroup) return false;
    for (CFIndex i = 0; i < CFArrayGetCount(group->members); i++)
        if (CFEqual(CFArrayGetValueAtIndex(group->members, i), identity->uuid)) return true;
    if (identity->identityClass != kCSIdentityClassUser) return false;
    pthread_mutex_lock(&directory_lock);
    struct passwd *user = getpwuid((uid_t)identity->posixID);
    struct group *entry = getgrgid((gid_t)group->posixID);
    Boolean found = user && entry && user->pw_gid == entry->gr_gid;
    if (!found && entry && entry->gr_mem) {
        char name[256];
        if (CFStringGetCString(identity->posixName, name, sizeof name, kCFStringEncodingUTF8))
            for (char **member = entry->gr_mem; *member; member++) found |= strcmp(name, *member) == 0;
    }
    pthread_mutex_unlock(&directory_lock);
    return found;
}

static void
identity_set_cf(CFTypeRef *slot, CFTypeRef value)
{
    if (*slot == value) return;
    if (value) CFRetain(value);
    if (*slot) CFRelease(*slot);
    *slot = value;
}

void CSIdentitySetFullName(CSIdentityRef identity, CFStringRef fullName)
{ if (is_identity(identity) && fullName) { identity_set_cf((CFTypeRef *)&identity->fullName, fullName); identity->dirty = true; } }
void CSIdentitySetEmailAddress(CSIdentityRef identity, CFStringRef emailAddress)
{ if (is_identity(identity)) { identity_set_cf((CFTypeRef *)&identity->emailAddress, emailAddress); identity->dirty = true; } }
void CSIdentitySetImageURL(CSIdentityRef identity, CFURLRef url)
{ if (is_identity(identity)) { identity_set_cf((CFTypeRef *)&identity->imageURL, url); identity->dirty = true; } }
void CSIdentitySetImageData(CSIdentityRef identity, CFDataRef imageData, CFStringRef imageDataType)
{ if (is_identity(identity)) { identity_set_cf((CFTypeRef *)&identity->imageData, imageData); identity_set_cf((CFTypeRef *)&identity->imageDataType, imageDataType); identity->dirty = true; } }
void CSIdentitySetIsEnabled(CSIdentityRef identity, Boolean enabled)
{ if (is_identity(identity)) { identity->enabled = enabled; identity->dirty = true; } }
void CSIdentitySetCertificate(CSIdentityRef identity, SecCertificateRef certificate)
{ if (is_identity(identity)) { identity_set_cf((CFTypeRef *)&identity->certificate, certificate); identity->dirty = true; } }
void CSIdentityAddAlias(CSIdentityRef identity, CFStringRef alias)
{ if (is_identity(identity) && alias && !CFArrayContainsValue(identity->aliases, CFRangeMake(0, CFArrayGetCount(identity->aliases)), alias)) { CFArrayAppendValue(identity->aliases, alias); identity->dirty = true; } }
void CSIdentityRemoveAlias(CSIdentityRef identity, CFStringRef alias)
{ if (is_identity(identity) && alias) { CFIndex i = CFArrayGetFirstIndexOfValue(identity->aliases, CFRangeMake(0, CFArrayGetCount(identity->aliases)), alias); if (i >= 0) { CFArrayRemoveValueAtIndex(identity->aliases, i); identity->dirty = true; } } }
void CSIdentityAddMember(CSIdentityRef group, CSIdentityRef member)
{ if (is_identity(group) && is_identity(member) && group->identityClass == kCSIdentityClassGroup && !CFArrayContainsValue(group->members, CFRangeMake(0, CFArrayGetCount(group->members)), member->uuid)) { CFArrayAppendValue(group->members, member->uuid); group->dirty = true; } }
void CSIdentityRemoveMember(CSIdentityRef group, CSIdentityRef member)
{ if (is_identity(group) && is_identity(member)) { CFIndex i = CFArrayGetFirstIndexOfValue(group->members, CFRangeMake(0, CFArrayGetCount(group->members)), member->uuid); if (i >= 0) { CFArrayRemoveValueAtIndex(group->members, i); group->dirty = true; } } }
void CSIdentityDelete(CSIdentityRef identity) { if (is_identity(identity)) { identity->deleted = true; identity->dirty = true; } }
void
CSIdentityRemoveClient(CSIdentityRef identity)
{
    if (!is_identity(identity) || !identity->clientLockInitialized)
        return;
    pthread_mutex_lock(&identity->clientLock);
    identity->clientRemoved = true;
    pthread_mutex_unlock(&identity->clientLock);
}

Boolean
CSIdentityCommit(CSIdentityRef identity, AuthorizationRef authorization, CFErrorRef *error)
{
    (void)authorization;
    if (error) *error = NULL;
    if (!is_identity(identity)) {
        if (error) *error = identity_error(kCSIdentityUnknownAuthorityErr, CFSTR("Unknown identity authority"));
        return false;
    }
    if (!identity->dirty) return true;
    if (error) *error = identity_error(kCSIdentityAuthorityNotAccessibleErr, CFSTR("The local identity service is unavailable"));
    return false;
}

Boolean
CSIdentityCommitAsynchronously(CSIdentityRef identity, const CSIdentityClientContext *clientContext,
                               CFRunLoopRef runLoop, CFStringRef runLoopMode, AuthorizationRef authorization)
{
    (void)authorization;
    if (!is_identity(identity) || !clientContext || !clientContext->statusUpdated ||
        clientContext->version != 0 || !identity->dirty || !identity->clientLockInitialized)
        return false;

    pthread_mutex_lock(&identity->clientLock);
    if (identity->committing) {
        pthread_mutex_unlock(&identity->clientLock);
        return false;
    }
    identity->clientRemoved = false;
    identity->committing = true;
    pthread_mutex_unlock(&identity->clientLock);

    struct commit_callback {
        CSIdentityRef identity;
        CFRunLoopRef runLoop;
        CFStringRef runLoopMode;
        CSIdentityStatusUpdatedCallback callback;
        void *info;
        CFAllocatorReleaseCallBack releaseInfo;
        Boolean didRetain;
    } *request = calloc(1, sizeof *request);
    if (!request) {
        pthread_mutex_lock(&identity->clientLock);
        identity->committing = false;
        pthread_mutex_unlock(&identity->clientLock);
        return false;
    }
    request->identity = (CSIdentityRef)CFRetain(identity);
    request->runLoop = (CFRunLoopRef)CFRetain(runLoop ? runLoop : CFRunLoopGetCurrent());
    request->runLoopMode = (CFStringRef)CFRetain(runLoopMode ? runLoopMode : kCFRunLoopDefaultMode);
    request->callback = clientContext->statusUpdated;
    request->releaseInfo = clientContext->release;
    request->didRetain = clientContext->retain != NULL;
    request->info = (void *)(clientContext->retain ? clientContext->retain(clientContext->info) : clientContext->info);
    if (!request->identity || !request->runLoop || !request->runLoopMode ||
        (clientContext->retain && clientContext->info && !request->info)) {
        if (request->didRetain && request->releaseInfo && request->info)
            request->releaseInfo(request->info);
        if (request->identity) CFRelease(request->identity);
        if (request->runLoop) CFRelease(request->runLoop);
        if (request->runLoopMode) CFRelease(request->runLoopMode);
        free(request);
        pthread_mutex_lock(&identity->clientLock);
        identity->committing = false;
        pthread_mutex_unlock(&identity->clientLock);
        return false;
    }

    CFRunLoopPerformBlock(request->runLoop, request->runLoopMode, ^{
        pthread_mutex_lock(&request->identity->clientLock);
        Boolean deliver = !request->identity->clientRemoved;
        request->identity->committing = false;
        pthread_mutex_unlock(&request->identity->clientLock);
        if (deliver) {
            CFErrorRef error = identity_error(kCSIdentityAuthorityNotAccessibleErr,
                                              CFSTR("The local identity service is unavailable"));
            request->callback(request->identity, kCSIdentityCommitCompleted, error, request->info);
            if (error) CFRelease(error);
        }
        if (request->didRetain && request->releaseInfo && request->info)
            request->releaseInfo(request->info);
        CFRelease(request->identity);
        CFRelease(request->runLoop);
        CFRelease(request->runLoopMode);
        free(request);
    });
    CFRunLoopWakeUp(request->runLoop);
    return true;
}

CSIdentityQueryRef
CSIdentityQueryCreate(CFAllocatorRef allocator, CSIdentityClass identityClass, CSIdentityAuthorityRef authority)
{
    if (identityClass != kCSIdentityClassUser && identityClass != kCSIdentityClassGroup) return NULL;
    return query_create(allocator, kQueryAll, identityClass, authority);
}

CSIdentityQueryRef
CSIdentityQueryCreateForName(CFAllocatorRef allocator, CFStringRef name,
                             CSIdentityQueryStringComparisonMethod comparisonMethod,
                             CSIdentityClass identityClass, CSIdentityAuthorityRef authority)
{
    if (!name || (comparisonMethod != kCSIdentityQueryStringEquals && comparisonMethod != kCSIdentityQueryStringBeginsWith)) return NULL;
    CSIdentityQueryRef ref = query_create(allocator, kQueryName, identityClass, authority);
    if (ref) { ref->name = CFRetain(name); ref->comparison = comparisonMethod; }
    return ref;
}

CSIdentityQueryRef
CSIdentityQueryCreateForUUID(CFAllocatorRef allocator, CFUUIDRef uuid, CSIdentityAuthorityRef authority)
{
    if (!uuid) return NULL;
    CSIdentityQueryRef ref = query_create(allocator, kQueryUUID, 0, authority);
    if (ref) ref->uuid = CFRetain(uuid);
    return ref;
}

CSIdentityQueryRef
CSIdentityQueryCreateForPosixID(CFAllocatorRef allocator, id_t posixID, CSIdentityClass identityClass,
                                CSIdentityAuthorityRef authority)
{
    if (identityClass != kCSIdentityClassUser && identityClass != kCSIdentityClassGroup) return NULL;
    CSIdentityQueryRef ref = query_create(allocator, kQueryPosixID, identityClass, authority);
    if (ref) ref->posixID = posixID;
    return ref;
}

CSIdentityQueryRef
CSIdentityQueryCreateForPersistentReference(CFAllocatorRef allocator, CFDataRef referenceData)
{
    if (!referenceData || CFDataGetLength(referenceData) != 24) return NULL;
    const UInt8 *bytes = CFDataGetBytePtr(referenceData);
    if (memcmp(bytes, "FCS1", 4) != 0) return NULL;
    UInt32 cls = ((UInt32)bytes[4] << 24) | ((UInt32)bytes[5] << 16) | ((UInt32)bytes[6] << 8) | bytes[7];
    if (cls != kCSIdentityClassUser && cls != kCSIdentityClassGroup) return NULL;
    CSIdentityQueryRef ref = query_create(allocator, kQueryReference, cls, CSGetDefaultIdentityAuthority());
    if (ref) ref->uuid = uuid_from_bytes(bytes + 8);
    return ref;
}

CSIdentityQueryRef
CSIdentityQueryCreateForCurrentUser(CFAllocatorRef allocator)
{
    return query_create(allocator, kQueryCurrentUser, kCSIdentityClassUser, CSGetDefaultIdentityAuthority());
}

CSIdentityQueryRef
CSIdentityCreateGroupMembershipQuery(CFAllocatorRef allocator, CSIdentityRef group)
{
    if (!is_identity(group) || group->identityClass != kCSIdentityClassGroup) return NULL;
    CSIdentityQueryRef query = query_create(allocator, kQueryMembers, 0, group->authority);
    if (query) query->group = (CSIdentityRef)CFRetain(group);
    return query;
}

CFArrayRef
CSIdentityQueryCopyResults(CSIdentityQueryRef query)
{
    if (!is_query(query)) return NULL;
    return query->results ? CFArrayCreateCopy(kCFAllocatorDefault, query->results) :
                            CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

Boolean
CSIdentityQueryExecute(CSIdentityQueryRef query, CSIdentityQueryFlags flags, CFErrorRef *error)
{
    if (error) *error = NULL;
    if (!is_query(query) || query->executed || (flags & ~(kCSIdentityQueryGenerateUpdateEvents | kCSIdentityQueryIncludeHiddenIdentities))) return false;
    query->flags = flags;
    if (query->results) CFRelease(query->results);
    query->results = query_run(query);
    if (!query->results) return false;
    query->executed = true;
    return true;
}

struct query_callback_data {
    CSIdentityQueryRef query;
    CFArrayRef results;
};

static void
query_deliver_callbacks(void *context)
{
    struct query_callback_data *data = context;
    struct __CSIdentityQuery *query = (struct __CSIdentityQuery *)data->query;
    if (!query->stopped && !query->clientRemoved && query->callback) {
        if (CFArrayGetCount(data->results)) query->callback(data->query, kCSIdentityQueryEventResultsAdded, data->results, NULL, query->clientInfo);
        query->callback(data->query, kCSIdentityQueryEventSearchPhaseFinished, NULL, NULL, query->clientInfo);
    }
    CFRelease(data->results);
    CFRelease(data->query);
    free(data);
}

Boolean
CSIdentityQueryExecuteAsynchronously(CSIdentityQueryRef query, CSIdentityQueryFlags flags,
                                     const CSIdentityQueryClientContext *clientContext,
                                     CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    if (!is_query(query) || query->executed || !clientContext || !clientContext->receiveEvent) return false;
    if (!CSIdentityQueryExecute(query, flags, NULL)) return false;
    query->callback = clientContext->receiveEvent;
    query->clientInfo = clientContext->retainInfo ? (void *)clientContext->retainInfo(clientContext->info) : clientContext->info;
    query->releaseInfo = clientContext->releaseInfo;
    struct query_callback_data *data = calloc(1, sizeof *data);
    if (!data) return false;
    data->query = (CSIdentityQueryRef)CFRetain(query);
    data->results = CFRetain(query->results);
    CFRunLoopRef targetLoop = runLoop ? runLoop : CFRunLoopGetCurrent();
    CFStringRef mode = runLoopMode ? runLoopMode : kCFRunLoopDefaultMode;
    CFRunLoopPerformBlock(targetLoop, mode, ^{ query_deliver_callbacks(data); });
    CFRunLoopWakeUp(targetLoop);
    return true;
}

void
CSIdentityQueryStop(CSIdentityQueryRef query)
{
    if (is_query(query)) query->stopped = true;
}

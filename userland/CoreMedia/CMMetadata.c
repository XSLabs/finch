/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreMedia's metadata identifiers, data type registry and metadata format
 * descriptions, Finch's.
 *
 * An identifier is "keyspace/key": four-character-code keyspaces (QuickTime user
 * data, ISO user data, iTunes, ID3, written "id3") take four-byte keys, other
 * keyspaces (QuickTime metadata, ICY, HLS date ranges) take strings; a byte that
 * isn't printable ASCII, '%' or '/' is written "%XX", as Apple's does.
 *
 * The registry starts with the types Apple's has (CMMetadataTypes.c, Apple's values)
 * and takes more. A boxed metadata format description keeps a key table as its
 * "MetadataKeyTable" extension, laid out as Apple's: each key's namespace and value,
 * local ID, and data type (a QuickTime well-known type number, or the type's name).
 */
#include "CMInternal.h"
#include <ctype.h>

/* (the registry's getters give NULL for a type not registered, as Apple's do, though the
   header says they never do) */
#pragma clang diagnostic ignored "-Wnonnull"
#include <stdlib.h>
#include <string.h>

/* --- identifiers --- */

static bool
code_keyspace(CFStringRef keySpace)
{
    return CFEqual(keySpace, kCMMetadataKeySpace_QuickTimeUserData) || CFEqual(keySpace, kCMMetadataKeySpace_ISOUserData) ||
           CFEqual(keySpace, kCMMetadataKeySpace_iTunes) || CFEqual(keySpace, kCMMetadataKeySpace_ID3);
}

/* The keyspace as an identifier writes it ("org.id3" is "id3"). */
static CFStringRef
identifier_prefix(CFStringRef keySpace)
{
    return CFEqual(keySpace, kCMMetadataKeySpace_ID3) ? CFSTR("id3") : keySpace;
}

static CFStringRef
keyspace_of_prefix(CFStringRef prefix)
{
    return CFEqual(prefix, CFSTR("id3")) ? kCMMetadataKeySpace_ID3 : prefix;
}

/* The key's bytes: a string's UTF-8, data's bytes, a number's four big-endian bytes. */
static CFDataRef
key_bytes(CFTypeRef key, bool code)
{
    if (CFGetTypeID(key) == CFDataGetTypeID())
        return CFRetain(key);
    if (CFGetTypeID(key) == CFStringGetTypeID()) {
        /* (in Mac Roman, as Apple's: "café" is "caf%8E") */
        return CFStringCreateExternalRepresentation(NULL, key, kCFStringEncodingMacRoman, '?');
    }
    if (CFGetTypeID(key) == CFNumberGetTypeID()) {
        int32_t v;
        CFNumberGetValue(key, kCFNumberSInt32Type, &v);
        uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
        return CFDataCreate(NULL, b, 4);
    }
    return NULL;
}

OSStatus
CMMetadataCreateIdentifierForKeyAndKeySpace(CFAllocatorRef allocator, CFTypeRef key, CFStringRef keySpace, CFStringRef *identifierOut)
{
    if (!identifierOut || !key || !keySpace)
        return kCMMetadataIdentifierError_RequiredParameterMissing;
    *identifierOut = NULL;
    CFIndex spaceLength = CFStringGetLength(keySpace);
    if (!spaceLength || (spaceLength > 4 && !CFEqual(keySpace, kCMMetadataKeySpace_ID3)))
        return kCMMetadataIdentifierError_BadKeySpace;
    bool code = code_keyspace(keySpace);
    if (CFGetTypeID(key) == CFNumberGetTypeID() && !code)
        return kCMMetadataIdentifierError_BadKeyType;
    CFDataRef bytes = key_bytes(key, code);
    if (!bytes)
        return kCMMetadataIdentifierError_BadKeyType;
    CFIndex n = CFDataGetLength(bytes);
    if (!n || (code && n != 4)) {
        CFRelease(bytes);
        return kCMMetadataIdentifierError_BadKeyLength;
    }
    CFMutableStringRef s = CFStringCreateMutableCopy(allocator, 0, identifier_prefix(keySpace));
    CFStringAppend(s, CFSTR("/"));
    const UInt8 *b = CFDataGetBytePtr(bytes);
    for (CFIndex i = 0; i < n; i++) {
        if (b[i] >= 0x20 && b[i] < 0x7f && b[i] != '%' && b[i] != '/')
            CFStringAppendFormat(s, NULL, CFSTR("%c"), b[i]);
        else
            CFStringAppendFormat(s, NULL, CFSTR("%%%02X"), b[i]);
    }
    CFRelease(bytes);
    *identifierOut = s;
    return noErr;
}

/* The identifier split at its first '/', the key's bytes decoded. */
static OSStatus
split(CFStringRef identifier, CFStringRef *prefixOut, CFDataRef *keyOut)
{
    if (!identifier)
        return kCMMetadataIdentifierError_RequiredParameterMissing;
    CFRange slash = CFStringFind(identifier, CFSTR("/"), 0);
    if (slash.location == kCFNotFound || slash.location == 0 || slash.location == CFStringGetLength(identifier) - 1)
        return kCMMetadataIdentifierError_BadIdentifier;
    *prefixOut = CFStringCreateWithSubstring(NULL, identifier, CFRangeMake(0, slash.location));
    CFStringRef rest = CFStringCreateWithSubstring(NULL, identifier, CFRangeMake(slash.location + 1, CFStringGetLength(identifier) - slash.location - 1));
    CFDataRef utf8 = CFStringCreateExternalRepresentation(NULL, rest, kCFStringEncodingMacRoman, '?');
    CFRelease(rest);
    const UInt8 *b = CFDataGetBytePtr(utf8);
    CFIndex n = CFDataGetLength(utf8);
    CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
    for (CFIndex i = 0; i < n; i++) {
        if (b[i] == '%' && i + 2 < n && isxdigit(b[i + 1]) && isxdigit(b[i + 2])) {
            char hex[3] = {(char)b[i + 1], (char)b[i + 2], 0};
            UInt8 v = (UInt8)strtol(hex, NULL, 16);
            CFDataAppendBytes(out, &v, 1);
            i += 2;
        } else
            CFDataAppendBytes(out, b + i, 1);
    }
    CFRelease(utf8);
    *keyOut = out;
    return noErr;
}

OSStatus
CMMetadataCreateKeySpaceFromIdentifier(CFAllocatorRef allocator, CFStringRef identifier, CFStringRef *keySpaceOut)
{
    if (!keySpaceOut)
        return kCMMetadataIdentifierError_RequiredParameterMissing;
    *keySpaceOut = NULL;
    CFStringRef prefix;
    CFDataRef key;
    OSStatus e = split(identifier, &prefix, &key);
    if (e)
        return e;
    CFRelease(key);
    *keySpaceOut = CFRetain(keyspace_of_prefix(prefix));
    CFRelease(prefix);
    return noErr;
}

OSStatus
CMMetadataCreateKeyFromIdentifierAsCFData(CFAllocatorRef allocator, CFStringRef identifier, CFDataRef *keyOut)
{
    if (!keyOut)
        return kCMMetadataIdentifierError_RequiredParameterMissing;
    *keyOut = NULL;
    CFStringRef prefix;
    CFDataRef key;
    OSStatus e = split(identifier, &prefix, &key);
    if (e)
        return e;
    CFRelease(prefix);
    *keyOut = key;
    return noErr;
}

OSStatus
CMMetadataCreateKeyFromIdentifier(CFAllocatorRef allocator, CFStringRef identifier, CFTypeRef *keyOut)
{
    if (!keyOut)
        return kCMMetadataIdentifierError_RequiredParameterMissing;
    *keyOut = NULL;
    CFStringRef prefix;
    CFDataRef key;
    OSStatus e = split(identifier, &prefix, &key);
    if (e)
        return e;
    bool code = code_keyspace(keyspace_of_prefix(prefix));
    CFRelease(prefix);
    if (code) {
        if (CFDataGetLength(key) != 4) {
            CFRelease(key);
            return kCMMetadataIdentifierError_BadKeyLength;
        }
        const UInt8 *b = CFDataGetBytePtr(key);
        int32_t v = (int32_t)((uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
        *keyOut = CFNumberCreate(allocator, kCFNumberSInt32Type, &v);
    } else
        *keyOut = CFStringCreateFromExternalRepresentation(allocator, key, kCFStringEncodingMacRoman);
    CFRelease(key);
    return *keyOut ? noErr : kCMMetadataIdentifierError_BadKey;
}

/* --- the data type registry --- */

extern const unsigned char _FinchCMMetadataTypes[];
extern const size_t _FinchCMMetadataTypesSize;

static CFMutableDictionaryRef types; /* name -> {description, conforming, base, wellKnown} */
static CFMutableArrayRef baseTypes;
static pthread_mutex_t registryLock = PTHREAD_MUTEX_INITIALIZER;

static void
load_types(void)
{
    types = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    baseTypes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, _FinchCMMetadataTypes, (CFIndex)_FinchCMMetadataTypesSize, kCFAllocatorNull);
    CFArrayRef all = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(all, i);
        CFStringRef name = CFDictionaryGetValue(d, CFSTR("type"));
        CFDictionarySetValue(types, name, d);
        if (CFBooleanGetValue(CFDictionaryGetValue(d, CFSTR("base"))))
            CFArrayAppendValue(baseTypes, name);
    }
    if (all)
        CFRelease(all);
}

static CFDictionaryRef
type_entry(CFStringRef name)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_types);
    if (!name)
        return NULL;
    pthread_mutex_lock(&registryLock);
    CFDictionaryRef d = CFDictionaryGetValue(types, name);
    pthread_mutex_unlock(&registryLock);
    return d;
}

CFArrayRef
CMMetadataDataTypeRegistryGetBaseDataTypes(void)
{
    type_entry(NULL);
    return baseTypes;
}

Boolean
CMMetadataDataTypeRegistryDataTypeIsRegistered(CFStringRef dataType)
{
    return type_entry(dataType) != NULL;
}

Boolean
CMMetadataDataTypeRegistryDataTypeIsBaseDataType(CFStringRef dataType)
{
    CFDictionaryRef d = type_entry(dataType);
    return d && CFBooleanGetValue(CFDictionaryGetValue(d, CFSTR("base")));
}

CFStringRef
CMMetadataDataTypeRegistryGetDataTypeDescription(CFStringRef dataType)
{
    CFDictionaryRef d = type_entry(dataType);
    CFStringRef description = d ? CFDictionaryGetValue(d, CFSTR("description")) : NULL;
    return description;
}

CFArrayRef
CMMetadataDataTypeRegistryGetConformingDataTypes(CFStringRef dataType)
{
    CFDictionaryRef d = type_entry(dataType);
    return d ? CFDictionaryGetValue(d, CFSTR("conforming")) : NULL;
}

Boolean
CMMetadataDataTypeRegistryDataTypeConformsToDataType(CFStringRef dataType, CFStringRef conformsToDataType)
{
    if (!dataType || !conformsToDataType)
        return false;
    if (CFEqual(dataType, conformsToDataType))
        return true;
    CFArrayRef c = CMMetadataDataTypeRegistryGetConformingDataTypes(dataType);
    for (CFIndex i = 0; c && i < CFArrayGetCount(c); i++)
        if (CMMetadataDataTypeRegistryDataTypeConformsToDataType(CFArrayGetValueAtIndex(c, i), conformsToDataType))
            return true;
    return false;
}

CFStringRef
CMMetadataDataTypeRegistryGetBaseDataTypeForConformingDataType(CFStringRef dataType)
{
    if (CMMetadataDataTypeRegistryDataTypeIsBaseDataType(dataType))
        return dataType;
    CFArrayRef c = CMMetadataDataTypeRegistryGetConformingDataTypes(dataType);
    for (CFIndex i = 0; c && i < CFArrayGetCount(c); i++) {
        CFStringRef b = CMMetadataDataTypeRegistryGetBaseDataTypeForConformingDataType(CFArrayGetValueAtIndex(c, i));
        if (b)
            return b;
    }
    return NULL;
}

OSStatus
CMMetadataDataTypeRegistryRegisterDataType(CFStringRef dataType, CFStringRef description, CFArrayRef conformingDataTypes)
{
    if (!dataType || !description || !conformingDataTypes || !CFArrayGetCount(conformingDataTypes))
        return kCMMetadataDataTypeRegistryError_RequiredParameterMissing;
    if (type_entry(dataType))
        return noErr; /* (registering again changes nothing, and isn't an error, as with Apple's) */
    /* (it must come to exactly one base type) */
    CFStringRef base = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(conformingDataTypes); i++) {
        CFStringRef b = CMMetadataDataTypeRegistryGetBaseDataTypeForConformingDataType(CFArrayGetValueAtIndex(conformingDataTypes, i));
        if (!b)
            return kCMMetadataDataTypeRegistryError_BadDataTypeIdentifier;
        if (base && !CFEqual(base, b))
            return kCMMetadataDataTypeRegistryError_MultipleConformingBaseTypes;
        base = b;
    }
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("type"), dataType);
    CFDictionarySetValue(d, CFSTR("description"), description);
    CFArrayRef copy = CFArrayCreateCopy(NULL, conformingDataTypes);
    CFDictionarySetValue(d, CFSTR("conforming"), copy);
    CFRelease(copy);
    CFDictionarySetValue(d, CFSTR("base"), kCFBooleanFalse);
    pthread_mutex_lock(&registryLock);
    CFDictionarySetValue(types, dataType, d);
    pthread_mutex_unlock(&registryLock);
    CFRelease(d);
    return noErr;
}

/* --- metadata format descriptions --- */

static CFStringRef kKeyTable = CFSTR("MetadataKeyTable");

static void
set_int(CFMutableDictionaryRef d, CFStringRef key, int v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

/* A data type as a key records it: its well-known number (namespace 0) or its name (1). */
static void
set_data_type(CFMutableDictionaryRef d, CFStringRef type)
{
    CFDictionaryRef entry = type_entry(type);
    CFNumberRef wellKnown = entry ? CFDictionaryGetValue(entry, CFSTR("wellKnown")) : NULL;
    int code;
    if (wellKnown && CFNumberGetValue(wellKnown, kCFNumberIntType, &code)) {
        uint8_t b[4] = {(uint8_t)(code >> 24), (uint8_t)(code >> 16), (uint8_t)(code >> 8), (uint8_t)code};
        CFDataRef data = CFDataCreate(NULL, b, 4);
        CFDictionarySetValue(d, CFSTR("MetadataKeyDataType"), data);
        CFRelease(data);
        set_int(d, CFSTR("MetadataKeyDataTypeNameSpace"), 0);
    } else {
        CFDataRef data = CFStringCreateExternalRepresentation(NULL, type, kCFStringEncodingUTF8, 0);
        CFDictionarySetValue(d, CFSTR("MetadataKeyDataType"), data);
        CFRelease(data);
        set_int(d, CFSTR("MetadataKeyDataTypeNameSpace"), 1);
    }
}

static int
fourcc(CFStringRef s)
{
    char b[8] = {0};
    CFStringGetCString(s, b, sizeof b, kCFStringEncodingMacRoman);
    return (int)((uint32_t)(uint8_t)b[0] << 24 | (uint32_t)(uint8_t)b[1] << 16 | (uint32_t)(uint8_t)b[2] << 8 | (uint8_t)b[3]);
}

/* A key table entry for a metadata specification; NULL if it can't be made. */
static CFMutableDictionaryRef
entry_for_spec(CFDictionaryRef spec, int localID, OSStatus *error)
{
    CFStringRef identifier = CFDictionaryGetValue(spec, kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier);
    CFStringRef dataType = CFDictionaryGetValue(spec, kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType);
    if (!identifier || !dataType || !CMMetadataDataTypeRegistryDataTypeIsRegistered(dataType)) {
        *error = kCMFormatDescriptionError_InvalidParameter;
        return NULL;
    }
    CFStringRef space = NULL;
    CFDataRef key = NULL;
    if ((*error = CMMetadataCreateKeySpaceFromIdentifier(NULL, identifier, &space)) ||
        (*error = CMMetadataCreateKeyFromIdentifierAsCFData(NULL, identifier, &key))) {
        if (space)
            CFRelease(space);
        return NULL;
    }
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_int(d, CFSTR("MetadataKeyNamespace"), fourcc(identifier_prefix(space)));
    CFDictionarySetValue(d, CFSTR("MetadataKeyValue"), key);
    set_int(d, CFSTR("MetadataKeyLocalID"), localID);
    set_data_type(d, dataType);
    if (!CMMetadataDataTypeRegistryDataTypeIsBaseDataType(dataType)) {
        CFMutableArrayRef conforming = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        CFArrayRef c = CMMetadataDataTypeRegistryGetConformingDataTypes(dataType);
        for (CFIndex i = 0; c && i < CFArrayGetCount(c); i++) {
            CFMutableDictionaryRef t = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            set_data_type(t, CFArrayGetValueAtIndex(c, i));
            CFArrayAppendValue(conforming, t);
            CFRelease(t);
        }
        CFDictionarySetValue(d, CFSTR("MetadataKeyConformingDataTypes"), conforming);
        CFRelease(conforming);
    }
    CFTypeRef language = CFDictionaryGetValue(spec, kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag);
    if (language)
        CFDictionarySetValue(d, CFSTR("MetadataKeyExtendedLanguageTag"), language);
    CFTypeRef setup = CFDictionaryGetValue(spec, kCMMetadataFormatDescriptionMetadataSpecificationKey_SetupData);
    if (setup)
        CFDictionarySetValue(d, CFSTR("MetadataKeySetupData"), setup);
    CFTypeRef structural = CFDictionaryGetValue(spec, kCMMetadataFormatDescriptionMetadataSpecificationKey_StructuralDependency);
    if (structural)
        CFDictionarySetValue(d, CFSTR("MetadataKeyStructuralDependency"), structural);
    CFRelease(space);
    CFRelease(key);
    return d;
}

static OSStatus
create_with_table(CFAllocatorRef allocator, CMMetadataFormatType type, CFDictionaryRef table, CMMetadataFormatDescriptionRef *out)
{
    CFDictionaryRef ext = NULL;
    if (table && CFDictionaryGetCount(table))
        ext = CFDictionaryCreate(NULL, (const void **)&kKeyTable, (const void **)&table, 1, &kCFTypeDictionaryKeyCallBacks,
                                 &kCFTypeDictionaryValueCallBacks);
    OSStatus e = CMFormatDescriptionCreate(allocator, kCMMediaType_Metadata, type, ext, out);
    if (ext)
        CFRelease(ext);
    return e;
}

/* Whether the table has a key of this namespace and value already. */
static bool
has_key(CFDictionaryRef table, CFDictionaryRef entry)
{
    CFIndex n = CFDictionaryGetCount(table);
    const void **values = malloc(sizeof(void *) * (size_t)(n ? n : 1));
    CFDictionaryGetKeysAndValues(table, NULL, values);
    bool present = false;
    for (CFIndex i = 0; i < n && !present; i++)
        present = CFEqual(CFDictionaryGetValue(values[i], CFSTR("MetadataKeyNamespace")), CFDictionaryGetValue(entry, CFSTR("MetadataKeyNamespace"))) &&
                  CFEqual(CFDictionaryGetValue(values[i], CFSTR("MetadataKeyValue")), CFDictionaryGetValue(entry, CFSTR("MetadataKeyValue")));
    free(values);
    return present;
}

static void
add_specs(CFMutableDictionaryRef table, CFArrayRef specs, OSStatus *error)
{
    int next = (int)CFDictionaryGetCount(table) + 1;
    for (CFIndex i = 0; specs && i < CFArrayGetCount(specs) && !*error; i++) {
        CFDictionaryRef spec = CFArrayGetValueAtIndex(specs, i);
        if (CFGetTypeID(spec) != CFDictionaryGetTypeID()) {
            *error = kCMFormatDescriptionError_InvalidParameter;
            break;
        }
        CFMutableDictionaryRef entry = entry_for_spec(spec, next, error);
        if (!entry)
            break;
        if (has_key(table, entry)) {
            CFRelease(entry);
            continue;
        }
        CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), next++);
        CFDictionarySetValue(table, k, entry);
        CFRelease(k);
        CFRelease(entry);
    }
}

OSStatus
CMMetadataFormatDescriptionCreateWithMetadataSpecifications(CFAllocatorRef allocator, CMMetadataFormatType metadataType,
                                                            CFArrayRef metadataSpecifications, CMMetadataFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !metadataSpecifications)
        return kCMFormatDescriptionError_InvalidParameter;
    *formatDescriptionOut = NULL;
    if (metadataType != kCMMetadataFormatType_Boxed)
        return kCMFormatDescriptionError_InvalidParameter;
    CFMutableDictionaryRef table = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus e = noErr;
    add_specs(table, metadataSpecifications, &e);
    if (!e)
        e = create_with_table(allocator, metadataType, table, formatDescriptionOut);
    CFRelease(table);
    return e;
}

OSStatus
CMMetadataFormatDescriptionCreateWithMetadataFormatDescriptionAndMetadataSpecifications(CFAllocatorRef allocator,
                                                                                         CMMetadataFormatDescriptionRef sourceDescription,
                                                                                         CFArrayRef metadataSpecifications,
                                                                                         CMMetadataFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !sourceDescription || !metadataSpecifications)
        return kCMFormatDescriptionError_InvalidParameter;
    *formatDescriptionOut = NULL;
    CFDictionaryRef old = CMFormatDescriptionGetExtension(sourceDescription, kKeyTable);
    CFMutableDictionaryRef table = old ? CFDictionaryCreateMutableCopy(NULL, 0, old)
                                       : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus e = noErr;
    add_specs(table, metadataSpecifications, &e);
    if (!e)
        e = create_with_table(allocator, CMFormatDescriptionGetMediaSubType(sourceDescription), table, formatDescriptionOut);
    CFRelease(table);
    return e;
}

OSStatus
CMMetadataFormatDescriptionCreateWithKeys(CFAllocatorRef allocator, CMMetadataFormatType metadataType, CFArrayRef keys,
                                          CMMetadataFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut)
        return kCMFormatDescriptionError_InvalidParameter;
    *formatDescriptionOut = NULL;
    if (metadataType == kCMMetadataFormatType_Boxed && !keys)
        return kCMFormatDescriptionError_InvalidParameter;
    /* (keys of a namespace and a value as data; others are left out, as Apple's leaves them) */
    CFMutableDictionaryRef table = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int next = 1;
    for (CFIndex i = 0; keys && i < CFArrayGetCount(keys); i++) {
        CFDictionaryRef k = CFArrayGetValueAtIndex(keys, i);
        CFTypeRef ns = CFDictionaryGetValue(k, kCMMetadataFormatDescriptionKey_Namespace);
        CFTypeRef value = CFDictionaryGetValue(k, kCMMetadataFormatDescriptionKey_Value);
        if (!ns || !value || CFGetTypeID(value) != CFDataGetTypeID())
            continue;
        CFMutableDictionaryRef entry = CFDictionaryCreateMutableCopy(NULL, 0, k);
        CFTypeRef localID = CFDictionaryGetValue(k, kCMMetadataFormatDescriptionKey_LocalID);
        int id = next++;
        if (localID)
            CFNumberGetValue(localID, kCFNumberIntType, &id);
        else
            set_int(entry, kCMMetadataFormatDescriptionKey_LocalID, id);
        CFStringRef idKey = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), id);
        CFDictionarySetValue(table, idKey, entry);
        CFRelease(idKey);
        CFRelease(entry);
    }
    OSStatus e = create_with_table(allocator, metadataType, table, formatDescriptionOut);
    CFRelease(table);
    return e;
}

OSStatus
CMMetadataFormatDescriptionCreateByMergingMetadataFormatDescriptions(CFAllocatorRef allocator, CMMetadataFormatDescriptionRef sourceDescription,
                                                                     CMMetadataFormatDescriptionRef otherSourceDescription,
                                                                     CMMetadataFormatDescriptionRef *formatDescriptionOut)
{
    if (!formatDescriptionOut || !sourceDescription || !otherSourceDescription)
        return kCMFormatDescriptionError_InvalidParameter;
    *formatDescriptionOut = NULL;
    CFDictionaryRef a = CMFormatDescriptionGetExtension(sourceDescription, kKeyTable);
    CFDictionaryRef b = CMFormatDescriptionGetExtension(otherSourceDescription, kKeyTable);
    if (!a || !b)
        return kCMFormatDescriptionError_InvalidParameter;
    /* (the other's keys after the first's, renumbered, those already there left out) */
    CFMutableDictionaryRef table = CFDictionaryCreateMutableCopy(NULL, 0, a);
    int next = (int)CFDictionaryGetCount(a) + 1;
    for (int id = 1; id <= (int)CFDictionaryGetCount(b); id++) {
        CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), id);
        CFDictionaryRef entry = CFDictionaryGetValue(b, k);
        CFRelease(k);
        if (!entry)
            continue;
        bool present = has_key(a, entry);
        if (present)
            continue;
        CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, entry);
        set_int(copy, CFSTR("MetadataKeyLocalID"), next);
        CFStringRef nk = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), next++);
        CFDictionarySetValue(table, nk, copy);
        CFRelease(nk);
        CFRelease(copy);
    }
    OSStatus e = create_with_table(allocator, CMFormatDescriptionGetMediaSubType(sourceDescription), table, formatDescriptionOut);
    CFRelease(table);
    return e;
}

CFDictionaryRef
CMMetadataFormatDescriptionGetKeyWithLocalID(CMMetadataFormatDescriptionRef desc, OSType localKeyID)
{
    CFDictionaryRef table = CMFormatDescriptionGetExtension(desc, kKeyTable);
    if (!table)
        return NULL;
    CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("%u"), (unsigned)localKeyID);
    CFDictionaryRef entry = CFDictionaryGetValue(table, k);
    CFRelease(k);
    return entry;
}

extern CFArrayRef _FinchCMFormatDescriptionCachedArray(CMFormatDescriptionRef desc, CFArrayRef (*make)(CMFormatDescriptionRef));

/* The identifiers of the keys, in local ID order. */
static CFArrayRef
make_identifiers(CMFormatDescriptionRef desc)
{
    CFDictionaryRef table = CMFormatDescriptionGetExtension(desc, kKeyTable);
    if (!table)
        return NULL;
    CFMutableArrayRef ids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFIndex n = CFDictionaryGetCount(table);
    for (CFIndex id = 1, found = 0; found < n && id < 100000; id++) {
        CFDictionaryRef entry = CMMetadataFormatDescriptionGetKeyWithLocalID(desc, (OSType)id);
        if (!entry)
            continue;
        found++;
        CFNumberRef ns = CFDictionaryGetValue(entry, CFSTR("MetadataKeyNamespace"));
        CFTypeRef value = CFDictionaryGetValue(entry, CFSTR("MetadataKeyValue"));
        int code = 0;
        if (!ns || !value || !CFNumberGetValue(ns, kCFNumberIntType, &code))
            continue;
        char c[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
        CFStringRef prefix = CFStringCreateWithCString(NULL, c, kCFStringEncodingMacRoman);
        CFStringRef identifier = NULL;
        if (!CMMetadataCreateIdentifierForKeyAndKeySpace(NULL, value, keyspace_of_prefix(prefix), &identifier)) {
            CFArrayAppendValue(ids, identifier);
            CFRelease(identifier);
        }
        CFRelease(prefix);
    }
    return ids;
}

CFArrayRef
CMMetadataFormatDescriptionGetIdentifiers(CMMetadataFormatDescriptionRef desc)
{
    return desc ? _FinchCMFormatDescriptionCachedArray(desc, make_identifiers) : NULL;
}

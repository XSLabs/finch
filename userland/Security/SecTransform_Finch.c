/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* In-process Security transforms built on Finch's CoreFoundation and OpenSSL. */
#include "SecInternal.h"
#include <Security/SecCustomTransform.h>
#include <Security/SecDecodeTransform.h>
#include <Security/SecDigestTransform.h>
#include <Security/SecEncodeTransform.h>
#include <Security/SecEncryptTransform.h>
#include <Security/SecSignVerifyTransform.h>
#include <Security/SecTransformReadTransform.h>
#include <Block.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct OpaqueSecTransformImplementation;
typedef struct CustomAttributeAction {
	struct CustomAttributeAction *next;
	CFStringRef action;
	CFStringRef attribute;
	SecTransformAttributeActionBlock block;
} CustomAttributeAction;
typedef struct CustomDataAction {
	struct CustomDataAction *next;
	CFStringRef action;
	SecTransformDataBlock block;
} CustomDataAction;
typedef struct CustomTransformAction {
	struct CustomTransformAction *next;
	CFStringRef action;
	SecTransformActionBlock block;
} CustomTransformAction;
struct OpaqueSecTransformImplementation {
	struct Transform *transform;
	CustomAttributeAction *attributeActions;
	CustomDataAction *dataActions;
	CustomTransformAction *transformActions;
};
typedef struct RegisteredTransform {
	struct RegisteredTransform *next;
	CFStringRef name;
	SecTransformCreateFP create;
} RegisteredTransform;

enum TransformKind {
	TransformGeneric,
	TransformGroup,
	TransformDigest,
	TransformEncode,
	TransformDecode,
	TransformEncrypt,
	TransformDecrypt,
	TransformSign,
	TransformVerify,
	TransformRead
};

typedef struct Transform {
	CFRuntimeBase base;
	enum TransformKind kind;
	CFMutableDictionaryRef attributes;
	CFMutableArrayRef members;
	CFReadStreamRef stream;
	CFTypeRef retainedKey;
	CFIndex digestLength;
	Boolean executed;
	struct OpaqueSecTransformImplementation *custom;
} Transform;
static Transform *createTransform(enum TransformKind kind);

static CFRuntimeClass transformClasses[] = {
	{0, "SecTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecGroupTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecDigestTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecEncodeTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecDecodeTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecEncryptTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecDecryptTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecSignTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecVerifyTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL},
	{0, "SecReadTransform", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL}
};
static CFTypeID transformTypes[sizeof(transformClasses) / sizeof(transformClasses[0])];
static pthread_once_t transformOnce = PTHREAD_ONCE_INIT;
static atomic_uint transformNameCounter = 0;
static pthread_mutex_t customRegistryLock = PTHREAD_MUTEX_INITIALIZER;
static RegisteredTransform *customRegistry;
static void setError(CFErrorRef *error, CFIndex code);

static void
freeCustomActions(struct OpaqueSecTransformImplementation *custom)
{
	if (!custom)
		return;
	CustomAttributeAction *attribute = custom->attributeActions;
	while (attribute) {
		CustomAttributeAction *next = attribute->next;
		CFRelease(attribute->action);
		if (attribute->attribute) CFRelease(attribute->attribute);
		Block_release(attribute->block);
		free(attribute);
		attribute = next;
	}
	CustomDataAction *data = custom->dataActions;
	while (data) {
		CustomDataAction *next = data->next;
		CFRelease(data->action);
		Block_release(data->block);
		free(data);
		data = next;
	}
	CustomTransformAction *action = custom->transformActions;
	while (action) {
		CustomTransformAction *next = action->next;
		CFRelease(action->action);
		Block_release(action->block);
		free(action);
		action = next;
	}
	free(custom);
}

static void
transformFinalize(CFTypeRef object)
{
	Transform *transform = (Transform *)object;
	if (transform->attributes) CFRelease(transform->attributes);
	if (transform->members) CFRelease(transform->members);
	if (transform->stream) CFRelease(transform->stream);
	if (transform->retainedKey) CFRelease(transform->retainedKey);
	if (transform->custom) {
		CustomTransformAction *finalize = transform->custom->transformActions;
		while (finalize && !CFEqual(finalize->action, kSecTransformActionFinalize))
			finalize = finalize->next;
		if (finalize)
			finalize->block();
		freeCustomActions(transform->custom);
	}
}

static void
registerTransformTypes(void)
{
	for (size_t i = 0; i < sizeof(transformClasses) / sizeof(transformClasses[0]); i++) {
		transformClasses[i].finalize = transformFinalize;
		transformTypes[i] = _SecRegisterClass(&transformTypes[i], &transformClasses[i]);
	}
}

static CFTypeID
typeForKind(enum TransformKind kind)
{
	pthread_once(&transformOnce, registerTransformTypes);
	return transformTypes[kind];
}

static bool
isTransform(CFTypeRef value)
{
	if (!value || CFGetTypeID(value) == 0)
		return false;
	CFTypeID type = CFGetTypeID(value);
	for (size_t i = 0; i < sizeof(transformTypes) / sizeof(transformTypes[0]); i++)
		if (type == typeForKind((enum TransformKind)i))
			return true;
	return false;
}

static CFStringRef
customAttributeName(SecTransformStringOrAttributeRef attribute)
{
	return attribute && CFGetTypeID(attribute) == CFStringGetTypeID()
	    ? (CFStringRef)attribute : NULL;
}

static CFErrorRef
customError(CFIndex code)
{
	CFStringRef domain = kSecTransformErrorDomain ? kSecTransformErrorDomain : CFSTR("SecTransformErrorDomain");
	return CFErrorCreate(NULL, domain, code, NULL);
}

static CustomAttributeAction *
findCustomAttributeAction(struct OpaqueSecTransformImplementation *custom,
	CFStringRef action, CFStringRef attribute)
{
	CustomAttributeAction *generic = NULL;
	for (CustomAttributeAction *entry = custom->attributeActions; entry; entry = entry->next) {
		if (!CFEqual(entry->action, action))
			continue;
		if (entry->attribute && attribute && CFEqual(entry->attribute, attribute))
			return entry;
		if (!entry->attribute)
			generic = entry;
	}
	return generic;
}

static CustomDataAction *
findCustomDataAction(struct OpaqueSecTransformImplementation *custom, CFStringRef action)
{
	for (CustomDataAction *entry = custom->dataActions; entry; entry = entry->next)
		if (CFEqual(entry->action, action))
			return entry;
	return NULL;
}

static CustomTransformAction *
findCustomTransformAction(struct OpaqueSecTransformImplementation *custom, CFStringRef action)
{
	for (CustomTransformAction *entry = custom->transformActions; entry; entry = entry->next)
		if (CFEqual(entry->action, action))
			return entry;
	return NULL;
}

Boolean
SecTransformRegister(CFStringRef name, SecTransformCreateFP create, CFErrorRef *error)
{
	if (!name || CFGetTypeID(name) != CFStringGetTypeID() || !CFStringGetLength(name) || !create) {
		setError(error, kSecTransformErrorInvalidInput);
		return false;
	}
	pthread_mutex_lock(&customRegistryLock);
	for (RegisteredTransform *entry = customRegistry; entry; entry = entry->next) {
		if (CFEqual(entry->name, name)) {
			pthread_mutex_unlock(&customRegistryLock);
			setError(error, kSecTransformErrorInvalidInput);
			return false;
		}
	}
	RegisteredTransform *entry = calloc(1, sizeof(*entry));
	if (entry) {
		entry->name = CFRetain(name);
		entry->create = create;
		entry->next = customRegistry;
		customRegistry = entry;
	}
	pthread_mutex_unlock(&customRegistryLock);
	if (!entry) {
		setError(error, kSecTransformErrorInvalidInput);
		return false;
	}
	return true;
}

SecTransformRef
SecTransformCreate(CFStringRef name, CFErrorRef *error)
{
	if (!name || CFGetTypeID(name) != CFStringGetTypeID()) {
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	SecTransformCreateFP create = NULL;
	pthread_mutex_lock(&customRegistryLock);
	for (RegisteredTransform *entry = customRegistry; entry; entry = entry->next)
		if (CFEqual(entry->name, name)) {
			create = entry->create;
			break;
		}
	pthread_mutex_unlock(&customRegistryLock);
	if (!create) {
		setError(error, kSecTransformErrorInvalidAlgorithm);
		return NULL;
	}
	Transform *transform = createTransform(TransformGeneric);
	if (!transform) {
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	CFDictionarySetValue(transform->attributes, kSecTransformTransformName, name);
	transform->custom = calloc(1, sizeof(*transform->custom));
	if (!transform->custom) {
		CFRelease(transform);
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	transform->custom->transform = transform;
	SecTransformImplementationRef implementation = transform->custom;
	SecTransformInstanceBlock instance = create(name, (SecTransformRef)transform, implementation);
	if (!instance) {
		CFRelease(transform);
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	SecTransformInstanceBlock copied = Block_copy(instance);
	CFErrorRef instanceError = copied();
	Block_release(copied);
	if (instanceError) {
		if (error) {
			if (*error) CFRelease(*error);
			*error = (CFErrorRef)CFRetain(instanceError);
		}
		CFRelease(instanceError);
		CFRelease(transform);
		return NULL;
	}
	return (SecTransformRef)transform;
}

CFErrorRef
SecTransformSetAttributeAction(SecTransformImplementationRef ref, CFStringRef action,
	SecTransformStringOrAttributeRef attribute, SecTransformAttributeActionBlock block)
{
	if (!ref || !action || CFGetTypeID(action) != CFStringGetTypeID() || !block ||
	    (attribute && !customAttributeName(attribute)))
		return customError(kSecTransformErrorInvalidInput);
	struct OpaqueSecTransformImplementation *custom = (void *)ref;
	CustomAttributeAction *entry = calloc(1, sizeof(*entry));
	if (!entry)
		return customError(kSecTransformErrorInvalidInput);
	entry->action = CFRetain(action);
	entry->attribute = attribute ? CFRetain((CFStringRef)attribute) : NULL;
	entry->block = Block_copy(block);
	CustomAttributeAction **cursor = &custom->attributeActions;
	while (*cursor) {
		if (CFEqual((*cursor)->action, action) &&
		    ((!attribute && !(*cursor)->attribute) || (attribute && (*cursor)->attribute && CFEqual((*cursor)->attribute, attribute)))) {
			CustomAttributeAction *old = *cursor;
			entry->next = old->next;
			*cursor = entry;
			CFRelease(old->action);
			if (old->attribute) CFRelease(old->attribute);
			Block_release(old->block);
			free(old);
			return NULL;
		}
		cursor = &(*cursor)->next;
	}
	*cursor = entry;
	return NULL;
}

CFErrorRef
SecTransformSetDataAction(SecTransformImplementationRef ref, CFStringRef action, SecTransformDataBlock block)
{
	if (!ref || !action || CFGetTypeID(action) != CFStringGetTypeID() || !block)
		return customError(kSecTransformErrorInvalidInput);
	struct OpaqueSecTransformImplementation *custom = (void *)ref;
	CustomDataAction *entry = calloc(1, sizeof(*entry));
	if (!entry)
		return customError(kSecTransformErrorInvalidInput);
	entry->action = CFRetain(action);
	entry->block = Block_copy(block);
	CustomDataAction **cursor = &custom->dataActions;
	while (*cursor) {
		if (CFEqual((*cursor)->action, action)) {
			CustomDataAction *old = *cursor;
			entry->next = old->next;
			*cursor = entry;
			CFRelease(old->action);
			Block_release(old->block);
			free(old);
			return NULL;
		}
		cursor = &(*cursor)->next;
	}
	*cursor = entry;
	return NULL;
}

CFErrorRef
SecTransformSetTransformAction(SecTransformImplementationRef ref, CFStringRef action,
	SecTransformActionBlock block)
{
	if (!ref || !action || CFGetTypeID(action) != CFStringGetTypeID() || !block)
		return customError(kSecTransformErrorInvalidInput);
	struct OpaqueSecTransformImplementation *custom = (void *)ref;
	CustomTransformAction *entry = calloc(1, sizeof(*entry));
	if (!entry)
		return customError(kSecTransformErrorInvalidInput);
	entry->action = CFRetain(action);
	entry->block = Block_copy(block);
	CustomTransformAction **cursor = &custom->transformActions;
	while (*cursor) {
		if (CFEqual((*cursor)->action, action)) {
			CustomTransformAction *old = *cursor;
			entry->next = old->next;
			*cursor = entry;
			CFRelease(old->action);
			Block_release(old->block);
			free(old);
			return NULL;
		}
		cursor = &(*cursor)->next;
	}
	*cursor = entry;
	return NULL;
}

CFTypeRef
SecTransformCustomGetAttribute(SecTransformImplementationRef ref,
	SecTransformStringOrAttributeRef attribute, SecTransformMetaAttributeType type)
{
	if (!ref || !((struct OpaqueSecTransformImplementation *)ref)->transform || !customAttributeName(attribute))
		return NULL;
	CFStringRef name = customAttributeName(attribute);
	if (type == kSecTransformMetaAttributeName)
		return name;
	if (type != kSecTransformMetaAttributeValue)
		return NULL;
	return CFDictionaryGetValue(((struct OpaqueSecTransformImplementation *)ref)->transform->attributes, name);
}

CFTypeRef
SecTransformCustomSetAttribute(SecTransformImplementationRef ref,
	SecTransformStringOrAttributeRef attribute, SecTransformMetaAttributeType type, CFTypeRef value)
{
	if (!ref || !((struct OpaqueSecTransformImplementation *)ref)->transform || !customAttributeName(attribute) ||
	    type != kSecTransformMetaAttributeValue)
		return customError(kSecTransformErrorInvalidInput);
	Transform *transform = ((struct OpaqueSecTransformImplementation *)ref)->transform;
	if (value)
		CFDictionarySetValue(transform->attributes, attribute, value);
	else
		CFDictionaryRemoveValue(transform->attributes, attribute);
	return NULL;
}

CFTypeRef
SecTransformPushbackAttribute(SecTransformImplementationRef ref,
	SecTransformStringOrAttributeRef attribute, CFTypeRef value)
{
	return SecTransformCustomSetAttribute(ref, attribute, kSecTransformMetaAttributeValue, value);
}

CFTypeRef
SecTransformNoData(void)
{
	return CFSTR("com.finch.security.transform.no-data");
}

static void
setError(CFErrorRef *error, CFIndex code)
{
	if (!error)
		return;
	if (*error) {
		CFRelease(*error);
		*error = NULL;
	}
	CFStringRef domain = kSecTransformErrorDomain ? kSecTransformErrorDomain : CFSTR("SecTransformErrorDomain");
	*error = CFErrorCreate(NULL, domain, code, NULL);
}

static Transform *
createTransform(enum TransformKind kind)
{
	Transform *transform = (Transform *)_SecCreateInstance(typeForKind(kind), sizeof(*transform));
	if (!transform)
		return NULL;
	transform->kind = kind;
	transform->attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (!transform->attributes) {
		CFRelease(transform);
		return NULL;
	}
	char name[64];
	snprintf(name, sizeof(name), "FinchTransform%u", atomic_fetch_add(&transformNameCounter, 1) + 1);
	CFStringRef value = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	if (value) {
		CFDictionarySetValue(transform->attributes, kSecTransformTransformName, value);
		CFRelease(value);
	}
	return transform;
}

static SecTransformRef
createWithKind(enum TransformKind kind, CFTypeRef type, CFIndex length, CFTypeRef key, CFErrorRef *error)
{
	Transform *transform = createTransform(kind);
	if (!transform) {
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	if (type)
		CFDictionarySetValue(transform->attributes,
		    kind == TransformEncode ? kSecEncodeTypeAttribute :
		        kind == TransformDecode ? kSecDecodeTypeAttribute : kSecDigestTypeAttribute,
		    type);
	if (kind == TransformDigest) {
		if (!type) {
			type = kSecDigestSHA2;
			length = 512;
			CFDictionarySetValue(transform->attributes, kSecDigestTypeAttribute, type);
		}
		transform->digestLength = length;
		int digestBits = 0;
		if (CFEqual(type, kSecDigestSHA2) || CFEqual(type, kSecDigestHMACSHA2)) {
			if (length == 0) digestBits = 512;
			else if (length == 224 || length == 256 || length == 384 || length == 512) digestBits = (int)length;
			else { setError(error, kSecTransformErrorInvalidLength); CFRelease(transform); return NULL; }
		} else if (CFEqual(type, kSecDigestSHA1) || CFEqual(type, kSecDigestMD5) ||
	    CFEqual(type, kSecDigestHMACMD5) || CFEqual(type, kSecDigestHMACSHA1)) {
			digestBits = 0;
		} else {
			setError(error, kSecTransformErrorInvalidAlgorithm);
			CFRelease(transform);
			return NULL;
		}
		CFNumberRef bits = CFNumberCreate(NULL, kCFNumberIntType, &digestBits);
		if (bits) { CFDictionarySetValue(transform->attributes, kSecDigestLengthAttribute, bits); CFRelease(bits); }
	}
	if (key) {
		transform->retainedKey = CFRetain(key);
		if (kind == TransformSign || kind == TransformVerify)
			CFDictionarySetValue(transform->attributes, kSecKeyAttributeName, key);
		else
			CFDictionarySetValue(transform->attributes, kSecEncryptKey, key);
	}
	return (SecTransformRef)transform;
}

CFTypeID SecGroupTransformGetTypeID(void) { return typeForKind(TransformGroup); }
/* Apple's legacy API uses the group type as its general transform ID. */
CFTypeID SecTransformGetTypeID(void) { return SecGroupTransformGetTypeID(); }
CFTypeID SecDigestTransformGetTypeID(void) { return typeForKind(TransformDigest); }
CFTypeID SecEncryptTransformGetTypeID(void) { return typeForKind(TransformEncrypt); }
CFTypeID SecDecryptTransformGetTypeID(void) { return typeForKind(TransformDecrypt); }

SecTransformRef
SecDigestTransformCreate(CFTypeRef type, CFIndex length, CFErrorRef *error)
{
	return createWithKind(TransformDigest, type, length, NULL, error);
}

SecTransformRef
SecEncodeTransformCreate(CFTypeRef type, CFErrorRef *error)
{
	return createWithKind(TransformEncode, type, 0, NULL, error);
}

SecTransformRef
SecDecodeTransformCreate(CFTypeRef type, CFErrorRef *error)
{
	return createWithKind(TransformDecode, type, 0, NULL, error);
}

SecTransformRef
SecEncryptTransformCreate(SecKeyRef key, CFErrorRef *error)
{
	if (!key || CFGetTypeID(key) != SecKeyGetTypeID()) { setError(error, kSecTransformErrorInvalidInput); return NULL; }
	return createWithKind(TransformEncrypt, NULL, 0, key, error);
}

SecTransformRef
SecDecryptTransformCreate(SecKeyRef key, CFErrorRef *error)
{
	if (!key || CFGetTypeID(key) != SecKeyGetTypeID()) { setError(error, kSecTransformErrorInvalidInput); return NULL; }
	return createWithKind(TransformDecrypt, NULL, 0, key, error);
}

SecTransformRef
SecSignTransformCreate(SecKeyRef key, CFErrorRef *error)
{
	if (!key || CFGetTypeID(key) != SecKeyGetTypeID()) { setError(error, kSecTransformErrorInvalidInput); return NULL; }
	return createWithKind(TransformSign, NULL, 0, key, error);
}

SecTransformRef
SecVerifyTransformCreate(SecKeyRef key, CFDataRef signature, CFErrorRef *error)
{
	if (!key || CFGetTypeID(key) != SecKeyGetTypeID()) { setError(error, kSecTransformErrorInvalidInput); return NULL; }
	Transform *transform = (Transform *)createWithKind(TransformVerify, NULL, 0, key, error);
	if (transform && signature)
		CFDictionarySetValue(transform->attributes, CFSTR("Signature"), signature);
	return (SecTransformRef)transform;
}

SecGroupTransformRef
SecTransformCreateGroupTransform(void)
{
	Transform *group = createTransform(TransformGroup);
	if (group)
		group->members = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (group && !group->members) { CFRelease(group); return NULL; }
	return (SecGroupTransformRef)group;
}

Boolean
SecTransformSetAttribute(SecTransformRef ref, CFStringRef key, CFTypeRef value, CFErrorRef *error)
{
	if (!isTransform(ref) || !key || !value) { setError(error, kSecTransformInvalidArgument); return false; }
	Transform *transform = (Transform *)ref;
	if (transform->kind == TransformGroup) { setError(error, kSecTransformOperationNotSupportedOnGroup); return false; }
	if (transform->executed) { setError(error, kSecTransformTransformIsExecuting); return false; }
	if (transform->custom) {
		CustomAttributeAction *handler = findCustomAttributeAction(transform->custom,
		    kSecTransformActionAttributeNotification, key);
		if (handler) {
			CFTypeRef result = handler->block(key, value);
			if (result && CFGetTypeID(result) == CFErrorGetTypeID()) {
				if (error) {
					if (*error) CFRelease(*error);
					*error = (CFErrorRef)CFRetain(result);
				}
				return false;
			}
			if (result)
				value = result;
		}
	}
	CFDictionarySetValue(transform->attributes, key, value);
	return true;
}

CFTypeRef
SecTransformGetAttribute(SecTransformRef ref, CFStringRef key)
{
	if (!isTransform(ref) || !key || ((Transform *)ref)->kind == TransformGroup)
		return NULL;
	return CFDictionaryGetValue(((Transform *)ref)->attributes, key);
}

static const EVP_MD *
digestAlgorithm(Transform *transform)
{
	CFTypeRef type = CFDictionaryGetValue(transform->attributes, kSecDigestTypeAttribute);
	CFIndex bits = transform->digestLength;
	if (type && (CFEqual(type, kSecDigestHMACMD5) || CFEqual(type, kSecDigestMD5))) return EVP_md5();
	if (type && (CFEqual(type, kSecDigestHMACSHA1) || CFEqual(type, kSecDigestSHA1))) return EVP_sha1();
	if (bits == 224) return EVP_sha224();
	if (bits == 256) return EVP_sha256();
	if (bits == 384) return EVP_sha384();
	return EVP_sha512();
}

static CFDataRef
digestData(Transform *transform, CFDataRef input)
{
	const EVP_MD *algorithm = digestAlgorithm(transform);
	unsigned int length = 0;
	UInt8 bytes[EVP_MAX_MD_SIZE];
	CFTypeRef type = CFDictionaryGetValue(transform->attributes, kSecDigestTypeAttribute);
	bool hmac = type && (CFEqual(type, kSecDigestHMACMD5) || CFEqual(type, kSecDigestHMACSHA1) ||
	    CFEqual(type, kSecDigestHMACSHA2));
	if (hmac) {
		CFDataRef key = CFDictionaryGetValue(transform->attributes, kSecDigestHMACKeyAttribute);
		const UInt8 *keyBytes = key && CFGetTypeID(key) == CFDataGetTypeID() ? CFDataGetBytePtr(key) : NULL;
		size_t keyLength = key && CFGetTypeID(key) == CFDataGetTypeID() ? (size_t)CFDataGetLength(key) : 0;
		if (!HMAC(algorithm, keyBytes, (int)keyLength, CFDataGetBytePtr(input),
		    (size_t)CFDataGetLength(input), bytes, &length))
			return NULL;
	} else if (EVP_Digest(CFDataGetBytePtr(input), (size_t)CFDataGetLength(input), bytes, &length, algorithm, NULL) != 1) {
		return NULL;
	}
	return CFDataCreate(NULL, bytes, (CFIndex)length);
}

static CFDataRef
base64Encode(CFDataRef input)
{
	CFIndex inputLength = CFDataGetLength(input);
	if (inputLength < 0 || inputLength > (INT_MAX - 4) / 4 * 3)
		return NULL;
	CFIndex capacity = 4 * ((inputLength + 2) / 3);
	UInt8 *bytes = malloc((size_t)capacity + 1);
	if (!bytes)
		return NULL;
	int length = EVP_EncodeBlock(bytes, CFDataGetBytePtr(input), (int)inputLength);
	CFDataRef result = length >= 0 ? CFDataCreate(NULL, bytes, length) : NULL;
	free(bytes);
	return result;
}

static CFDataRef
base64Decode(CFDataRef input)
{
	CFIndex inputLength = CFDataGetLength(input);
	if (inputLength < 0 || inputLength > INT_MAX || inputLength % 4 != 0)
		return NULL;
	UInt8 *bytes = malloc((size_t)inputLength + 1);
	if (!bytes)
		return NULL;
	int length = EVP_DecodeBlock(bytes, CFDataGetBytePtr(input), (int)inputLength);
	if (length >= 0 && inputLength) {
		const UInt8 *source = CFDataGetBytePtr(input);
		if (source[inputLength - 1] == '=') length--;
		if (inputLength > 1 && source[inputLength - 2] == '=') length--;
	}
	CFDataRef result = length >= 0 ? CFDataCreate(NULL, bytes, length) : NULL;
	free(bytes);
	return result;
}

static CFDataRef
transformInput(Transform *transform, CFTypeRef input, CFErrorRef *error)
{
	if (!input)
		input = CFDictionaryGetValue(transform->attributes, kSecTransformInputAttributeName);
	if (!input) { setError(error, kSecTransformErrorAttributeNotFound); return NULL; }
	if (CFGetTypeID(input) != CFDataGetTypeID()) { setError(error, kSecTransformErrorInvalidType); return NULL; }
	return (CFDataRef)input;
}

static CFTypeRef
executeOne(Transform *transform, CFTypeRef suppliedInput, CFErrorRef *error)
{
	if (!transform || transform->kind == TransformGroup) { setError(error, kSecTransformInvalidArgument); return NULL; }
	if (transform->custom) {
		CustomTransformAction *canExecute = findCustomTransformAction(transform->custom,
		    kSecTransformActionCanExecute);
		if (canExecute) {
			CFTypeRef result = canExecute->block();
			if (result && CFGetTypeID(result) == CFErrorGetTypeID()) {
				if (error) {
					if (*error) CFRelease(*error);
					*error = (CFErrorRef)CFRetain(result);
				}
				return NULL;
			}
		}
		CustomTransformAction *starting = findCustomTransformAction(transform->custom,
		    kSecTransformActionStartingExecution);
		if (starting) {
			CFTypeRef result = starting->block();
			if (result && CFGetTypeID(result) == CFErrorGetTypeID()) {
				if (error) {
					if (*error) CFRelease(*error);
					*error = (CFErrorRef)CFRetain(result);
				}
			return NULL;
			}
		}
		CFTypeRef input = suppliedInput ? suppliedInput :
		    CFDictionaryGetValue(transform->attributes, kSecTransformInputAttributeName);
		if (!input) { setError(error, kSecTransformErrorAttributeNotFound); return NULL; }
		CustomDataAction *process = findCustomDataAction(transform->custom, kSecTransformActionProcessData);
		CFTypeRef result = process ? process->block(input) : CFRetain(input);
		if (result && CFGetTypeID(result) == CFErrorGetTypeID()) {
			if (error) {
				if (*error) CFRelease(*error);
				*error = (CFErrorRef)CFRetain(result);
			}
			return NULL;
		}
		if (result)
			transform->executed = true;
		return result;
	}
	if (transform->kind == TransformRead) {
		CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
		UInt8 buffer[4096];
		CFReadStreamOpen(transform->stream);
		for (;;) {
			CFIndex count = CFReadStreamRead(transform->stream, buffer, sizeof(buffer));
			if (count <= 0) break;
			CFDataAppendBytes(data, buffer, count);
		}
		CFReadStreamClose(transform->stream);
		transform->executed = true;
		return data;
	}
	CFDataRef input = transformInput(transform, suppliedInput, error);
	if (!input)
		return NULL;
	CFDataRef result = NULL;
	switch (transform->kind) {
	case TransformGeneric:
		result = CFDataCreateCopy(NULL, input);
		break;
	case TransformDigest:
		result = digestData(transform, input);
		break;
	case TransformEncode: {
		CFTypeRef type = CFDictionaryGetValue(transform->attributes, kSecEncodeTypeAttribute);
		if (type && CFEqual(type, kSecBase64Encoding)) result = base64Encode(input);
		else { setError(error, kSecTransformErrorInvalidAlgorithm); return NULL; }
		break;
	}
	case TransformDecode: {
		CFTypeRef type = CFDictionaryGetValue(transform->attributes, kSecDecodeTypeAttribute);
		if (type && CFEqual(type, kSecBase64Encoding)) result = base64Decode(input);
		else { setError(error, kSecTransformErrorInvalidAlgorithm); return NULL; }
		break;
	}
	case TransformEncrypt:
	case TransformDecrypt: {
		SecKeyRef key = (SecKeyRef)transform->retainedKey;
		CFTypeRef padding = CFDictionaryGetValue(transform->attributes, kSecPaddingKey);
		SecKeyAlgorithm algorithm = padding && CFEqual(padding, kSecPaddingOAEPKey)
		    ? kSecKeyAlgorithmRSAEncryptionOAEPSHA1 : kSecKeyAlgorithmRSAEncryptionPKCS1;
		result = transform->kind == TransformEncrypt
		    ? SecKeyCreateEncryptedData(key, algorithm, input, error)
		    : SecKeyCreateDecryptedData(key, algorithm, input, error);
		break;
	}
	case TransformSign: {
		SecKeyRef key = (SecKeyRef)transform->retainedKey;
		SecKeyAlgorithm algorithm = kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1;
		result = SecKeyCreateSignature(key, algorithm, input, error);
		break;
	}
	case TransformVerify: {
		SecKeyRef key = (SecKeyRef)transform->retainedKey;
		CFDataRef signature = CFDictionaryGetValue(transform->attributes, CFSTR("Signature"));
		if (!signature) { setError(error, kSecTransformErrorAttributeNotFound); return NULL; }
		Boolean valid = SecKeyVerifySignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1,
		    input, signature, error);
		result = CFRetain(valid ? kCFBooleanTrue : kCFBooleanFalse);
		break;
	}
	case TransformRead:
		break;
	case TransformGroup:
		break;
	}
	if (!result && (!error || !*error))
		setError(error, kSecTransformErrorInvalidInput);
	if (result)
		transform->executed = true;
	return result;
}

CFTypeRef
SecTransformExecute(SecTransformRef ref, CFErrorRef *error)
{
	if (!isTransform(ref)) { setError(error, kSecTransformInvalidArgument); return NULL; }
	Transform *transform = (Transform *)ref;
	if (transform->kind != TransformGroup)
		return executeOne(transform, NULL, error);
	CFTypeRef value = NULL;
	for (CFIndex i = 0; i < CFArrayGetCount(transform->members); i++) {
		Transform *member = (Transform *)CFArrayGetValueAtIndex(transform->members, i);
		CFTypeRef next = executeOne(member, value, error);
		if (value) CFRelease(value);
		if (!next) return NULL;
		value = next;
	}
	return value;
}

void
SecTransformExecuteAsync(SecTransformRef ref, dispatch_queue_t queue, SecMessageBlock block)
{
	if (!block)
		return;
	CFRetain(ref);
	SecMessageBlock copied = Block_copy(block);
	dispatch_async(queue ? queue : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		CFErrorRef error = NULL;
		CFTypeRef value = SecTransformExecute(ref, &error);
		copied(value, error, true);
		if (value) CFRelease(value);
		if (error) CFRelease(error);
		CFRelease(ref);
		Block_release(copied);
	});
}

static CFStringRef
externalTypeName(enum TransformKind kind)
{
	switch (kind) {
	case TransformGeneric: return CFSTR("SecTransform");
	case TransformDigest: return CFSTR("SecDigestTransform");
	case TransformEncode: return CFSTR("SecEncodeTransform");
	case TransformDecode: return CFSTR("SecDecodeTransform");
	case TransformEncrypt: return CFSTR("SecEncryptTransform");
	case TransformDecrypt: return CFSTR("SecDecryptTransform");
	case TransformSign: return CFSTR("SecSignTransform");
	case TransformVerify: return CFSTR("SecVerifyTransform");
	case TransformRead: return CFSTR("SecTransformReadTransform");
	case TransformGroup: return CFSTR("SecGroupTransform");
	}
	return NULL;
}

static CFDictionaryRef
copyExternalNode(Transform *transform)
{
	CFMutableDictionaryRef node = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!node)
		return NULL;
	CFTypeRef name = CFDictionaryGetValue(transform->attributes, kSecTransformTransformName);
	if (!name) name = CFSTR("FinchTransform");
	CFDictionarySetValue(node, CFSTR("NAME"), name);
	CFDictionarySetValue(node, CFSTR("TYPE"), externalTypeName(transform->kind));
	CFMutableDictionaryRef state = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	int metaValue = kSecTransformMetaAttributeValue;
	CFNumberRef valueKey = CFNumberCreate(NULL, kCFNumberIntType, &metaValue);
	CFIndex count = CFDictionaryGetCount(transform->attributes);
	const void **keys = calloc((size_t)count, sizeof(*keys));
	const void **values = calloc((size_t)count, sizeof(*values));
	if (state && valueKey && keys && values) {
		CFDictionaryGetKeysAndValues(transform->attributes, keys, values);
		for (CFIndex i = 0; i < count; i++) {
			if (CFEqual(keys[i], kSecTransformTransformName))
				continue;
			CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0,
			    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			if (item) {
				CFDictionarySetValue(item, valueKey, values[i]);
				CFDictionarySetValue(state, keys[i], item);
				CFRelease(item);
			}
		}
		CFDictionarySetValue(node, CFSTR("STATE"), state);
	}
	free(keys);
	free(values);
	if (valueKey) CFRelease(valueKey);
	if (state) CFRelease(state);
	return node;
}

CFDictionaryRef
SecTransformCopyExternalRepresentation(SecTransformRef ref)
{
	if (!isTransform(ref) || ((Transform *)ref)->executed)
		return NULL;
	Transform *transform = (Transform *)ref;
	CFMutableArrayRef nodes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFMutableArrayRef connections = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (!nodes || !connections) {
		if (nodes) CFRelease(nodes);
		if (connections) CFRelease(connections);
		return NULL;
	}
	if (transform->kind == TransformGroup) {
		for (CFIndex i = 0; i < CFArrayGetCount(transform->members); i++) {
			Transform *member = (Transform *)CFArrayGetValueAtIndex(transform->members, i);
			CFDictionaryRef node = copyExternalNode(member);
			if (node) { CFArrayAppendValue(nodes, node); CFRelease(node); }
			if (i > 0) {
				Transform *previous = (Transform *)CFArrayGetValueAtIndex(transform->members, i - 1);
				CFTypeRef fromName = CFDictionaryGetValue(previous->attributes, kSecTransformTransformName);
				CFTypeRef toName = CFDictionaryGetValue(member->attributes, kSecTransformTransformName);
				CFMutableDictionaryRef connection = CFDictionaryCreateMutable(NULL, 0,
				    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
				if (connection && fromName && toName) {
					CFDictionarySetValue(connection, CFSTR("FROM_NAME"), fromName);
					CFDictionarySetValue(connection, CFSTR("FROM_ATTRIBUTE"), kSecTransformOutputAttributeName);
					CFDictionarySetValue(connection, CFSTR("TO_NAME"), toName);
					CFDictionarySetValue(connection, CFSTR("TO_ATTRIBUTE"), kSecTransformInputAttributeName);
					CFArrayAppendValue(connections, connection);
				}
				if (connection) CFRelease(connection);
			}
		}
	} else {
		CFDictionaryRef node = copyExternalNode(transform);
		if (node) { CFArrayAppendValue(nodes, node); CFRelease(node); }
	}
	CFMutableDictionaryRef result = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (result) {
		CFDictionarySetValue(result, CFSTR("TRANSFORMS"), nodes);
		CFDictionarySetValue(result, CFSTR("ARRAY"), connections);
	}
	CFRelease(nodes);
	CFRelease(connections);
	return result;
}

static enum TransformKind
kindFromExternalName(CFStringRef name)
{
	if (CFEqual(name, CFSTR("SecTransform"))) return TransformGeneric;
	if (CFEqual(name, CFSTR("SecDigestTransform"))) return TransformDigest;
	if (CFEqual(name, CFSTR("SecEncodeTransform"))) return TransformEncode;
	if (CFEqual(name, CFSTR("SecDecodeTransform"))) return TransformDecode;
	if (CFEqual(name, CFSTR("SecEncryptTransform"))) return TransformEncrypt;
	if (CFEqual(name, CFSTR("SecDecryptTransform"))) return TransformDecrypt;
	if (CFEqual(name, CFSTR("SecSignTransform"))) return TransformSign;
	if (CFEqual(name, CFSTR("SecVerifyTransform"))) return TransformVerify;
	if (CFEqual(name, CFSTR("SecTransformReadTransform"))) return TransformRead;
	return TransformGroup;
}

static void
restoreExternalState(Transform *transform, CFDictionaryRef state)
{
	if (!state || CFGetTypeID(state) != CFDictionaryGetTypeID())
		return;
	int metaValue = kSecTransformMetaAttributeValue;
	CFNumberRef valueKey = CFNumberCreate(NULL, kCFNumberIntType, &metaValue);
	if (!valueKey)
		return;
	CFIndex count = CFDictionaryGetCount(state);
	const void **keys = calloc((size_t)count, sizeof(*keys));
	const void **values = calloc((size_t)count, sizeof(*values));
	if (keys && values) {
		CFDictionaryGetKeysAndValues(state, keys, values);
		for (CFIndex i = 0; i < count; i++) {
			CFTypeRef value = values[i];
			if (value && CFGetTypeID(value) == CFDictionaryGetTypeID())
				value = CFDictionaryGetValue((CFDictionaryRef)value, valueKey);
			if (value)
				CFDictionarySetValue(transform->attributes, keys[i], value);
		}
	}
	free(keys);
	free(values);
	CFRelease(valueKey);
}

SecTransformRef
SecTransformCreateFromExternalRepresentation(CFDictionaryRef dictionary, CFErrorRef *error)
{
	if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) {
		setError(error, kSecTransformErrorInvalidInputDictionary);
		return NULL;
	}
	CFArrayRef nodes = CFDictionaryGetValue(dictionary, CFSTR("TRANSFORMS"));
	CFArrayRef connections = CFDictionaryGetValue(dictionary, CFSTR("ARRAY"));
	if (!nodes || CFGetTypeID(nodes) != CFArrayGetTypeID() || !connections ||
	    CFGetTypeID(connections) != CFArrayGetTypeID() || CFArrayGetCount(nodes) == 0) {
		setError(error, kSecTransformErrorInvalidInputDictionary);
		return NULL;
	}
	CFMutableDictionaryRef byName = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFMutableArrayRef created = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (!byName || !created) {
		if (byName) CFRelease(byName);
		if (created) CFRelease(created);
		setError(error, kSecTransformErrorInvalidInput);
		return NULL;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(nodes); i++) {
		CFDictionaryRef node = (CFDictionaryRef)CFArrayGetValueAtIndex(nodes, i);
		CFStringRef name = node && CFGetTypeID(node) == CFDictionaryGetTypeID()
		    ? CFDictionaryGetValue(node, CFSTR("NAME")) : NULL;
		CFStringRef type = node && CFGetTypeID(node) == CFDictionaryGetTypeID()
		    ? CFDictionaryGetValue(node, CFSTR("TYPE")) : NULL;
		if (!name || CFGetTypeID(name) != CFStringGetTypeID() || !type || CFGetTypeID(type) != CFStringGetTypeID()) {
			setError(error, kSecTransformErrorInvalidInputDictionary);
			goto fail;
		}
		enum TransformKind kind = kindFromExternalName(type);
		if (kind == TransformGroup) { setError(error, kSecTransformErrorInvalidAlgorithm); goto fail; }
		Transform *transform = createTransform(kind);
		if (!transform) { setError(error, kSecTransformErrorInvalidInput); goto fail; }
		CFDictionarySetValue(transform->attributes, kSecTransformTransformName, name);
		restoreExternalState(transform, CFDictionaryGetValue(node, CFSTR("STATE")));
		CFDictionarySetValue(byName, name, transform);
		CFArrayAppendValue(created, transform);
		CFRelease(transform);
	}
	if (CFArrayGetCount(connections) == 0) {
		SecTransformRef result = CFRetain(CFArrayGetValueAtIndex(created, CFArrayGetCount(created) - 1));
		CFRelease(created);
		CFRelease(byName);
		return result;
	}
	SecGroupTransformRef group = SecTransformCreateGroupTransform();
	for (CFIndex i = 0; group && i < CFArrayGetCount(connections); i++) {
		CFDictionaryRef connection = (CFDictionaryRef)CFArrayGetValueAtIndex(connections, i);
		CFStringRef fromName = CFDictionaryGetValue(connection, CFSTR("FROM_NAME"));
		CFStringRef toName = CFDictionaryGetValue(connection, CFSTR("TO_NAME"));
		CFStringRef fromAttr = CFDictionaryGetValue(connection, CFSTR("FROM_ATTRIBUTE"));
		CFStringRef toAttr = CFDictionaryGetValue(connection, CFSTR("TO_ATTRIBUTE"));
		SecTransformRef from = fromName ? CFDictionaryGetValue(byName, fromName) : NULL;
		SecTransformRef to = toName ? CFDictionaryGetValue(byName, toName) : NULL;
		if (!from || !to || !fromAttr || !toAttr ||
		    !SecTransformConnectTransforms(from, fromAttr, to, toAttr, group, error)) {
			if (group) CFRelease(group);
			group = NULL;
			setError(error, kSecTransformErrorInvalidConnection);
			break;
		}
	}
	CFRelease(created);
	CFRelease(byName);
	return (SecTransformRef)group;
fail:
	CFRelease(created);
	CFRelease(byName);
	return NULL;
}

SecGroupTransformRef
SecTransformConnectTransforms(SecTransformRef sourceRef, CFStringRef sourceKey,
	SecTransformRef destinationRef, CFStringRef destinationKey, SecGroupTransformRef groupRef, CFErrorRef *error)
{
	if (!isTransform(sourceRef) || !isTransform(destinationRef) || !isTransform(groupRef) || !sourceKey || !destinationKey ||
	    ((Transform *)groupRef)->kind != TransformGroup) {
		setError(error, kSecTransformErrorInvalidConnection);
		return NULL;
	}
	Transform *group = (Transform *)groupRef;
	Transform *members[] = {(Transform *)sourceRef, (Transform *)destinationRef};
	for (size_t i = 0; i < 2; i++) {
		CFRange all = CFRangeMake(0, CFArrayGetCount(group->members));
		if (!CFArrayContainsValue(group->members, all, members[i]))
			CFArrayAppendValue(group->members, members[i]);
	}
	return (SecGroupTransformRef)CFRetain(groupRef);
}

SecTransformRef
SecTransformFindByName(SecGroupTransformRef ref, CFStringRef name)
{
	if (!isTransform(ref) || !name)
		return NULL;
	Transform *group = (Transform *)ref;
	if (group->kind != TransformGroup) {
		CFTypeRef memberName = CFDictionaryGetValue(group->attributes, kSecTransformTransformName);
		return memberName && CFEqual(memberName, name) ? ref : NULL;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(group->members); i++) {
		Transform *member = (Transform *)CFArrayGetValueAtIndex(group->members, i);
		CFTypeRef memberName = CFDictionaryGetValue(member->attributes, kSecTransformTransformName);
		if (memberName && CFEqual(memberName, name))
			return (SecTransformRef)member;
	}
	return NULL;
}

SecTransformRef
SecTransformCreateReadTransformWithReadStream(CFReadStreamRef stream)
{
	if (!stream)
		return NULL;
	Transform *transform = createTransform(TransformRead);
	if (!transform)
		return NULL;
	transform->stream = (CFReadStreamRef)CFRetain(stream);
	return (SecTransformRef)transform;
}

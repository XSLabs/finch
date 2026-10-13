/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "SecKeychainServiceWire.h"
#include "SecKeychainServiceClient.h"

#include <Security/SecCertificate.h>
#include <Security/SecAccess.h>
#include <Security/SecKey.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define WIRE_MARKER CFSTR("_finchSecurityObject")
#define WIRE_PATH CFSTR("path")
#define WIRE_DATA CFSTR("data")
#define WIRE_ATTRIBUTES CFSTR("attributes")
#define WIRE_CERTIFICATE CFSTR("certificate")
#define WIRE_KEY CFSTR("key")

static CFDictionaryRef
wireObject(CFStringRef kind, CFTypeRef value, CFTypeRef extra)
{
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!d)
		return NULL;
	CFDictionarySetValue(d, WIRE_MARKER, kind);
	if (value)
		CFDictionarySetValue(d, CFEqual(kind, CFSTR("keychain")) ? WIRE_PATH : WIRE_DATA, value);
	if (extra)
		CFDictionarySetValue(d, WIRE_ATTRIBUTES, extra);
	return d;
}

static CFStringRef
copyKeychainPath(SecKeychainRef keychain)
{
	char path[PATH_MAX];
	UInt32 length = sizeof(path);
	if (SecKeychainGetPath(keychain, &length, path) != errSecSuccess)
		return NULL;
	return CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
}

static CFPropertyListRef encode(CFTypeRef value, unsigned depth)
{
	if (!value || depth > 32)
		return NULL;
	CFTypeID type = CFGetTypeID(value);
	if (type == SecKeychainGetTypeID()) {
		CFStringRef path = copyKeychainPath((SecKeychainRef)value);
		CFDictionaryRef out = path ? wireObject(CFSTR("keychain"), path, NULL) : NULL;
		if (path)
			CFRelease(path);
		return out;
	}
	if (type == SecKeychainItemGetTypeID()) {
		CFDataRef persistent = NULL;
		if (SecKeychainItemCreatePersistentReference((SecKeychainItemRef)value, &persistent) != errSecSuccess)
			return NULL;
		CFDictionaryRef out = wireObject(CFSTR("item"), persistent, NULL);
		CFRelease(persistent);
		return out;
	}
	if (type == SecCertificateGetTypeID()) {
		CFDataRef data = SecCertificateCopyData((SecCertificateRef)value);
		CFDictionaryRef out = data ? wireObject(CFSTR("certificate"), data, NULL) : NULL;
		if (data)
			CFRelease(data);
		return out;
	}
	if (type == SecAccessGetTypeID()) {
		CFDataRef empty = CFDataCreate(NULL, NULL, 0);
		CFDictionaryRef out = empty ? wireObject(CFSTR("access"), empty, NULL) : NULL;
		if (empty)
			CFRelease(empty);
		return out;
	}
	if (type == SecIdentityGetTypeID()) {
		SecCertificateRef certificate = NULL;
		SecKeyRef key = NULL;
		OSStatus status = SecIdentityCopyCertificate((SecIdentityRef)value, &certificate);
		if (!status)
			status = SecIdentityCopyPrivateKey((SecIdentityRef)value, &key);
		CFPropertyListRef encodedCertificate = !status ? encode(certificate, depth + 1) : NULL;
		CFPropertyListRef encodedKey = !status ? encode(key, depth + 1) : NULL;
		CFMutableDictionaryRef out = NULL;
		if (encodedCertificate && encodedKey) {
			out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
			    &kCFTypeDictionaryValueCallBacks);
			if (out) {
				CFDictionarySetValue(out, WIRE_MARKER, CFSTR("identity"));
				CFDictionarySetValue(out, WIRE_CERTIFICATE, encodedCertificate);
				CFDictionarySetValue(out, WIRE_KEY, encodedKey);
			}
		}
		if (encodedCertificate)
			CFRelease(encodedCertificate);
		if (encodedKey)
			CFRelease(encodedKey);
		if (certificate)
			CFRelease(certificate);
		if (key)
			CFRelease(key);
		return out;
	}
	if (type == SecKeyGetTypeID()) {
		CFErrorRef error = NULL;
		CFDataRef data = SecKeyCopyExternalRepresentation((SecKeyRef)value, &error);
		if (error)
			CFRelease(error);
		CFDictionaryRef attributes = SecKeyCopyAttributes((SecKeyRef)value);
		CFPropertyListRef encodedAttributes = attributes ? encode(attributes, depth + 1) : NULL;
		CFDictionaryRef out = data && encodedAttributes &&
		    CFGetTypeID(encodedAttributes) == CFDictionaryGetTypeID() ?
		    wireObject(CFSTR("key"), data, encodedAttributes) : NULL;
		if (attributes)
			CFRelease(attributes);
		if (encodedAttributes)
			CFRelease(encodedAttributes);
		if (data)
			CFRelease(data);
		return out;
	}
	if (type == CFArrayGetTypeID()) {
		CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		if (!out)
			return NULL;
		for (CFIndex i = 0; i < CFArrayGetCount(value); i++) {
			CFPropertyListRef item = encode(CFArrayGetValueAtIndex(value, i), depth + 1);
			if (!item) {
				CFRelease(out);
				return NULL;
			}
			CFArrayAppendValue(out, item);
			CFRelease(item);
		}
		return out;
	}
	if (type == CFDictionaryGetTypeID()) {
		CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0,
		    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (!out)
			return NULL;
		CFIndex count = CFDictionaryGetCount(value);
		const void **keys = count ? calloc((size_t)count, sizeof(*keys)) : NULL;
		const void **values = count ? calloc((size_t)count, sizeof(*values)) : NULL;
		if (count && (!keys || !values)) {
			free(keys);
			free(values);
			CFRelease(out);
			return NULL;
		}
		if (count)
			CFDictionaryGetKeysAndValues(value, keys, values);
		for (CFIndex i = 0; i < count; i++) {
			CFPropertyListRef key = encode(keys[i], depth + 1);
			CFPropertyListRef item = encode(values[i], depth + 1);
			if (!key || !item || CFGetTypeID(key) != CFStringGetTypeID()) {
				if (key)
					CFRelease(key);
				if (item)
					CFRelease(item);
				free(keys);
				free(values);
				CFRelease(out);
				return NULL;
			}
			CFDictionarySetValue(out, key, item);
			CFRelease(key);
			CFRelease(item);
		}
		free(keys);
		free(values);
		return out;
	}
	return CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0) ? CFRetain(value) : NULL;
}

CFPropertyListRef
_FinchKeychainWireEncode(CFTypeRef value)
{
	CFPropertyListRef result = encode(value, 0);
	if (result && !CFPropertyListIsValid(result, kCFPropertyListBinaryFormat_v1_0)) {
		CFRelease(result);
		return NULL;
	}
	return result;
}

static bool validAbsoluteKeychainPath(CFStringRef value)
{
	CFIndex characterCount = CFStringGetLength(value);
	if (characterCount <= 0)
		return false;
	char path[PATH_MAX];
	CFIndex byteCount = 0;
	CFIndex convertedCharacters = CFStringGetBytes(value, CFRangeMake(0, characterCount),
	    kCFStringEncodingUTF8, 0, false, (UInt8 *)path, sizeof(path) - 1, &byteCount);
	if (convertedCharacters != characterCount || byteCount <= 0 || byteCount >= (CFIndex)sizeof(path))
		return false;
	/* CFStringGetCString would let an embedded NUL shorten the path silently. */
	if (memchr(path, 0, (size_t)byteCount) || path[0] != '/')
		return false;
	return true;
}

static CFTypeRef decode(CFPropertyListRef value, bool makeClientProxies, unsigned depth)
{
	if (!value || depth > 32)
		return NULL;
	CFTypeID type = CFGetTypeID(value);
	if (type == CFDictionaryGetTypeID()) {
		CFDictionaryRef d = (CFDictionaryRef)value;
		CFTypeRef marker = CFDictionaryGetValue(d, WIRE_MARKER);
		if (marker && CFGetTypeID(marker) == CFStringGetTypeID()) {
			CFTypeRef payload = CFEqual(marker, CFSTR("keychain")) ?
			    CFDictionaryGetValue(d, WIRE_PATH) : CFDictionaryGetValue(d, WIRE_DATA);
			if (CFEqual(marker, CFSTR("keychain"))) {
				if (CFDictionaryGetCount(d) != 2 || !payload ||
				    CFGetTypeID(payload) != CFStringGetTypeID() ||
				    !validAbsoluteKeychainPath((CFStringRef)payload))
					return NULL;
				/* Keep the reference lazy. The requested operation must report file
				 * errors such as a damaged or deleted keychain itself. */
				return _FinchKeychainCreateLocalReference((CFStringRef)payload);
			}
			if (CFEqual(marker, CFSTR("item"))) {
				if (CFDictionaryGetCount(d) != 2 || !payload ||
				    CFGetTypeID(payload) != CFDataGetTypeID())
					return NULL;
				/* The service validates this path and item id when it executes the
				 * request. Do not read the item here: doing so would hide locked and
				 * missing-item errors behind a generic decode failure. */
				return _FinchKeychainCreateItemProxy((CFDataRef)payload);
			}
			if (CFEqual(marker, CFSTR("certificate"))) {
				if (CFDictionaryGetCount(d) != 2 || !payload ||
				    CFGetTypeID(payload) != CFDataGetTypeID())
					return NULL;
				return SecCertificateCreateWithData(NULL, (CFDataRef)payload);
			}
			if (CFEqual(marker, CFSTR("access"))) {
				if (CFDictionaryGetCount(d) != 2 || !payload ||
				    CFGetTypeID(payload) != CFDataGetTypeID() ||
				    CFDataGetLength(payload) != 0)
					return NULL;
				SecAccessRef access = NULL;
				return SecAccessCreate(CFSTR(""), NULL, &access) == errSecSuccess ? access : NULL;
			}
			if (CFEqual(marker, CFSTR("identity"))) {
				if (CFDictionaryGetCount(d) != 3)
					return NULL;
				CFTypeRef certificate = decode(CFDictionaryGetValue(d, WIRE_CERTIFICATE),
				    makeClientProxies, depth + 1);
				CFTypeRef key = decode(CFDictionaryGetValue(d, WIRE_KEY),
				    makeClientProxies, depth + 1);
				SecIdentityRef identity = NULL;
				if (certificate && key && CFGetTypeID(certificate) == SecCertificateGetTypeID() &&
				    CFGetTypeID(key) == SecKeyGetTypeID())
					identity = _SecIdentityCreate((SecCertificateRef)certificate, (SecKeyRef)key);
				if (certificate)
					CFRelease(certificate);
				if (key)
					CFRelease(key);
				return identity;
			}
			if (CFEqual(marker, CFSTR("key"))) {
				if (CFDictionaryGetCount(d) != 3 || !payload ||
				    CFGetTypeID(payload) != CFDataGetTypeID())
					return NULL;
				CFPropertyListRef attributes = CFDictionaryGetValue(d, WIRE_ATTRIBUTES);
				if (!attributes || CFGetTypeID(attributes) != CFDictionaryGetTypeID())
					return NULL;
				CFTypeRef decodedAttributes = decode(attributes, makeClientProxies, depth + 1);
				if (!decodedAttributes || CFGetTypeID(decodedAttributes) != CFDictionaryGetTypeID()) {
					if (decodedAttributes)
						CFRelease(decodedAttributes);
					return NULL;
				}
				CFErrorRef error = NULL;
				SecKeyRef key = SecKeyCreateWithData((CFDataRef)payload,
				    (CFDictionaryRef)decodedAttributes, &error);
				if (error)
					CFRelease(error);
				CFRelease(decodedAttributes);
				return key;
			}
			return NULL;
		}
		CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0,
		    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (!out)
			return NULL;
		CFIndex count = CFDictionaryGetCount(d);
		const void **keys = count ? calloc((size_t)count, sizeof(*keys)) : NULL;
		const void **values = count ? calloc((size_t)count, sizeof(*values)) : NULL;
		if (count && (!keys || !values)) {
			free(keys);
			free(values);
			CFRelease(out);
			return NULL;
		}
		if (count)
			CFDictionaryGetKeysAndValues(d, keys, values);
		for (CFIndex i = 0; i < count; i++) {
			CFTypeRef key = decode(keys[i], makeClientProxies, depth + 1);
			CFTypeRef item = decode(values[i], makeClientProxies, depth + 1);
			if (!key || !item || CFGetTypeID(key) != CFStringGetTypeID()) {
				if (key)
					CFRelease(key);
				if (item)
					CFRelease(item);
				free(keys);
				free(values);
				CFRelease(out);
				return NULL;
			}
			CFDictionarySetValue(out, key, item);
			CFRelease(key);
			CFRelease(item);
		}
		free(keys);
		free(values);
		return out;
	}
	if (type == CFArrayGetTypeID()) {
		CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		if (!out)
			return NULL;
		for (CFIndex i = 0; i < CFArrayGetCount(value); i++) {
			CFTypeRef item = decode(CFArrayGetValueAtIndex(value, i), makeClientProxies, depth + 1);
			if (!item) {
				CFRelease(out);
				return NULL;
			}
			CFArrayAppendValue(out, item);
			CFRelease(item);
		}
		return out;
	}
	return CFPropertyListIsValid(value, kCFPropertyListBinaryFormat_v1_0) ? CFRetain(value) : NULL;
}

CFTypeRef
_FinchKeychainWireDecode(CFPropertyListRef value, bool makeClientProxies)
{
	return decode(value, makeClientProxies, 0);
}

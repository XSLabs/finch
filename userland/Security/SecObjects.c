/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local Security objects use OpenSSL for key parsing and certificate checks.
 * HTTPS server trust uses Finch's pinned Mozilla roots unless the caller
 * chooses only its own anchors. Other policies require explicit anchors. */
#include "SecInternal.h"
#include "../certificates/ca-bundle.h"
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/rsa.h>
#include <openssl/rand.h>
#include <openssl/ec.h>
#include <openssl/rand.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <time.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>

static pthread_mutex_t typeLock = PTHREAD_MUTEX_INITIALIZER;
CFTypeID _SecRegisterClass(CFTypeID *slot, const CFRuntimeClass *cls)
{
	pthread_mutex_lock(&typeLock);
	if (!*slot)
		*slot = _CFRuntimeRegisterClass(cls);
	pthread_mutex_unlock(&typeLock);
	return *slot;
}
CFTypeRef _SecCreateInstance(CFTypeID type, size_t size)
{
	return _CFRuntimeCreateInstance(NULL, type, size - sizeof(CFRuntimeBase), NULL);
}
CFErrorRef _SecCreateError(OSStatus status, CFStringRef description)
{
	CFDictionaryRef info = description
	    ? CFDictionaryCreate(NULL, (const void *[]){kCFErrorDescriptionKey},
	          (const void *[]){description}, 1, &kCFTypeDictionaryKeyCallBacks,
	          &kCFTypeDictionaryValueCallBacks)
	    : NULL;
	CFErrorRef e = CFErrorCreate(NULL, kCFErrorDomainOSStatus, status, info);
	if (info)
		CFRelease(info);
	return e;
}
bool _SecSetError(CFErrorRef *e, OSStatus s, CFStringRef d)
{
	if (e)
		*e = _SecCreateError(s, d);
	return false;
}
/* Error messages: Resources/en.lproj/SecErrorMessages.strings, generated at
 * build time from Apple's headers by Apple's generateErrStrings.pl. */
static CFDictionaryRef errorStrings;
static void loadErrorStrings(void)
{
	Dl_info info;
	if (!dladdr((const void *)loadErrorStrings, &info) || !info.dli_fname)
		return;
	char path[PATH_MAX];
	const char *slash = strrchr(info.dli_fname, '/');
	if (!slash)
		return;
	snprintf(path, sizeof(path), "%.*s/Resources/en.lproj/SecErrorMessages.strings",
	    (int)(slash - info.dli_fname), info.dli_fname);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(
	    NULL, (const UInt8 *)path, strlen(path), false);
	CFReadStreamRef stream = url ? CFReadStreamCreateWithFile(NULL, url) : NULL;
	if (stream && CFReadStreamOpen(stream)) {
		CFPropertyListRef plist =
		    CFPropertyListCreateWithStream(NULL, stream, 0, 0, NULL, NULL);
		if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID())
			errorStrings = plist;
		else if (plist)
			CFRelease(plist);
		CFReadStreamClose(stream);
	}
	if (stream)
		CFRelease(stream);
	if (url)
		CFRelease(url);
}
CFStringRef _SecCopyErrorString(OSStatus s)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, loadErrorStrings);
	if (!errorStrings)
		return NULL;
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), (int)s);
	CFStringRef v = CFDictionaryGetValue(errorStrings, key);
	CFRelease(key);
	return v && CFGetTypeID(v) == CFStringGetTypeID() ? CFRetain(v) : NULL;
}
CFStringRef SecCopyErrorMessageString(OSStatus s, void *reserved)
{
	CFStringRef r = _SecCopyErrorString(s);
	return r ? r : CFStringCreateWithFormat(NULL, NULL, CFSTR("OSStatus %d"), (int)s);
}
const SecRandomRef kSecRandomDefault = NULL;
int SecRandomCopyBytes(SecRandomRef random, size_t count, void *bytes)
{
	if (random || (!bytes && count))
		return errSecParam;
	if (count)
		arc4random_buf(bytes, count);
	return 0;
}

typedef struct {
	CFRuntimeBase base;
	X509 *cert;
	CFDataRef legacyData;
	CSSM_X509_NAME *subject;
	CSSM_X509_NAME *issuer;
	CSSM_X509_ALGORITHM_IDENTIFIER algorithm;
	bool hasAlgorithm;
} Certificate;
typedef struct {
	CFRuntimeBase base;
	EVP_PKEY *key;
	bool private;
	bool symmetric;
	/* Public keys carry different attribute defaults depending on how Security made them. */
	int attributeSource;
} Key;
enum {KeyAttributesDefault, KeyAttributesPublicCopy, KeyAttributesTrust};
typedef struct {
	CFRuntimeBase base;
	CFDictionaryRef properties;
	CFDataRef oidData;
} Policy;
typedef struct {
	CFRuntimeBase base;
	SecPolicyRef policy;
	bool returned;
} PolicySearch;
typedef struct {
	CFRuntimeBase base;
	CFArrayRef certs, anchors, policies;
	CFArrayRef chain;   /* built by the last evaluation */
	CFDateRef date;
	CFDataRef exceptions;
	CFIndex result;
	OSStatus status;
	OSStatus exceptionStatus;
	SecTrustOptionFlags options;
	bool anchorsOnly;
	bool hasException;
} Trust;
static void certFree(CFTypeRef o)
{
	Certificate *certificate = (Certificate *)o;
	X509_free(certificate->cert);
	if (certificate->legacyData)
		CFRelease(certificate->legacyData);
	CSSM_X509_NAME *names[] = {certificate->subject, certificate->issuer};
	for (size_t n = 0; n < sizeof(names) / sizeof(names[0]); n++) {
		CSSM_X509_NAME *name = names[n];
		if (!name)
			continue;
		for (uint32_t i = 0; i < name->numberOfRDNs; i++) {
			CSSM_X509_RDN *rdn = &name->RelativeDistinguishedName[i];
			if (!rdn->AttributeTypeAndValue)
				continue;
			for (uint32_t j = 0; j < rdn->numberOfPairs; j++) {
				CSSM_X509_TYPE_VALUE_PAIR *pair = &rdn->AttributeTypeAndValue[j];
				free(pair->type.Data);
				free(pair->value.Data);
			}
			free(rdn->AttributeTypeAndValue);
		}
		free(name->RelativeDistinguishedName);
		free(name);
	}
	free(certificate->algorithm.algorithm.Data);
	free(certificate->algorithm.parameters.Data);
}
static void keyFree(CFTypeRef o)
{
	EVP_PKEY_free(((Key *)o)->key);
}
static void policyFree(CFTypeRef o)
{
	Policy *policy = (Policy *)o;
	if (policy->properties)
		CFRelease(policy->properties);
	if (policy->oidData)
		CFRelease(policy->oidData);
}
static void policySearchFree(CFTypeRef o)
{
	PolicySearch *search = (PolicySearch *)o;
	if (search->policy)
		CFRelease(search->policy);
}
static void trustFree(CFTypeRef o)
{
	Trust *t = (Trust *)o;
	if (t->certs)
		CFRelease(t->certs);
	if (t->anchors)
		CFRelease(t->anchors);
	if (t->policies)
		CFRelease(t->policies);
	if (t->date)
		CFRelease(t->date);
	if (t->chain)
		CFRelease(t->chain);
	if (t->exceptions)
		CFRelease(t->exceptions);
}
static Boolean certEqual(CFTypeRef a, CFTypeRef b)
{
	return X509_cmp(((Certificate *)a)->cert, ((Certificate *)b)->cert) == 0;
}
static CFHashCode certHash(CFTypeRef a)
{
	unsigned char digest[EVP_MAX_MD_SIZE];
	unsigned int n = 0;
	X509_digest(((Certificate *)a)->cert, EVP_sha1(), digest, &n);
	CFHashCode h = 0;
	memcpy(&h, digest, sizeof(h));
	return h;
}
static Boolean keyEqual(CFTypeRef a, CFTypeRef b)
{
	Key *x = (Key *)a, *y = (Key *)b;
	if (x->private != y->private || x->symmetric != y->symmetric ||
	    EVP_PKEY_base_id(x->key) != EVP_PKEY_base_id(y->key))
		return false;
	return EVP_PKEY_eq(x->key, y->key) == 1;
}
static CFHashCode keyHash(CFTypeRef a)
{
	return (CFHashCode)EVP_PKEY_bits(((Key *)a)->key) ^ ((Key *)a)->private;
}
#define TYPE(Name, Finalizer, Equal, Hash)                                                         \
	CFTypeID Sec##Name##GetTypeID(void)                                                        \
	{                                                                                          \
		static CFTypeID id;                                                                \
		static const CFRuntimeClass cls = {                                                \
		    0, "Sec" #Name, NULL, NULL, Finalizer, Equal, Hash, NULL, NULL};               \
		return _SecRegisterClass(&id, &cls);                                               \
	}
TYPE(Certificate, certFree, certEqual, certHash)
TYPE(Key, keyFree, keyEqual, keyHash)
TYPE(Policy, policyFree, NULL, NULL)
TYPE(Trust, trustFree, NULL, NULL)
TYPE(PolicySearch, policySearchFree, NULL, NULL)
static bool valid(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}
static CFArrayRef currentChain(Trust *t);
SecCertificateRef SecCertificateCreateWithData(CFAllocatorRef allocator, CFDataRef data)
{
	if (!valid(data, CFDataGetTypeID()))
		return NULL;
	const unsigned char *p = CFDataGetBytePtr(data), *start = p;
	X509 *x = d2i_X509(NULL, &p, CFDataGetLength(data));
	if (!x || p != start + CFDataGetLength(data)) {
		X509_free(x);
		return NULL;
	}
	Certificate *c = (Certificate *)_SecCreateInstance(SecCertificateGetTypeID(), sizeof(*c));
	if (!c) {
		X509_free(x);
		return NULL;
	}
	c->cert = x;
	return (SecCertificateRef)c;
}
CFDataRef SecCertificateCopyData(SecCertificateRef ref)
{
	if (!valid(ref, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509(((Certificate *)ref)->cert, &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
static CSSM_X509_NAME *legacyName(X509_NAME *source)
{
	CSSM_X509_NAME *name = calloc(1, sizeof(*name));
	if (!name)
		return NULL;
	int entries = X509_NAME_entry_count(source);
	for (int i = 0; i < entries; i++) {
		if (!i || X509_NAME_ENTRY_set(X509_NAME_get_entry(source, i)) !=
		        X509_NAME_ENTRY_set(X509_NAME_get_entry(source, i - 1)))
			name->numberOfRDNs++;
	}
	name->RelativeDistinguishedName = calloc(name->numberOfRDNs, sizeof(*name->RelativeDistinguishedName));
	if (name->numberOfRDNs && !name->RelativeDistinguishedName) {
		free(name);
		return NULL;
	}
	uint32_t rdnIndex = 0;
	for (int i = 0; i < entries;) {
		int set = X509_NAME_ENTRY_set(X509_NAME_get_entry(source, i));
		int end = i + 1;
		while (end < entries && X509_NAME_ENTRY_set(X509_NAME_get_entry(source, end)) == set)
			end++;
		CSSM_X509_RDN *rdn = &name->RelativeDistinguishedName[rdnIndex++];
		rdn->numberOfPairs = (uint32_t)(end - i);
		rdn->AttributeTypeAndValue = calloc(rdn->numberOfPairs, sizeof(*rdn->AttributeTypeAndValue));
		if (!rdn->AttributeTypeAndValue)
			goto fail;
		for (int j = i; j < end; j++) {
			CSSM_X509_TYPE_VALUE_PAIR *pair = &rdn->AttributeTypeAndValue[j - i];
			X509_NAME_ENTRY *entry = X509_NAME_get_entry(source, j);
			ASN1_OBJECT *object = X509_NAME_ENTRY_get_object(entry);
			ASN1_STRING *value = X509_NAME_ENTRY_get_data(entry);
			int oidLength = OBJ_length(object);
			int valueLength = ASN1_STRING_length(value);
			pair->type.Length = (size_t)oidLength;
			pair->type.Data = malloc(pair->type.Length);
			pair->value.Length = (size_t)valueLength;
			pair->value.Data = malloc(pair->value.Length ? pair->value.Length : 1);
			if ((pair->type.Length && !pair->type.Data) || !pair->value.Data)
				goto fail;
			memcpy(pair->type.Data, OBJ_get0_data(object), pair->type.Length);
			if (pair->value.Length)
				memcpy(pair->value.Data, ASN1_STRING_get0_data(value), pair->value.Length);
			pair->valueType = (CSSM_BER_TAG)ASN1_STRING_type(value);
		}
		i = end;
	}
	return name;
fail:
	for (uint32_t i = 0; i < name->numberOfRDNs; i++) {
		CSSM_X509_RDN *rdn = &name->RelativeDistinguishedName[i];
		for (uint32_t j = 0; rdn->AttributeTypeAndValue && j < rdn->numberOfPairs; j++) {
			free(rdn->AttributeTypeAndValue[j].type.Data);
			free(rdn->AttributeTypeAndValue[j].value.Data);
		}
		free(rdn->AttributeTypeAndValue);
	}
	free(name->RelativeDistinguishedName);
	free(name);
	return NULL;
}
OSStatus SecCertificateCreateFromData(const CSSM_DATA *data, CSSM_CERT_TYPE type,
    CSSM_CERT_ENCODING encoding, SecCertificateRef *out)
{
	if (!out || !data || !data->Data || !data->Length)
		return errSecParam;
	*out = NULL;
	if ((encoding != CSSM_CERT_ENCODING_DER && encoding != CSSM_CERT_ENCODING_BER) ||
	    (type != CSSM_CERT_UNKNOWN && type != CSSM_CERT_X_509v1 &&
	        type != CSSM_CERT_X_509v2 && type != CSSM_CERT_X_509v3))
		return errSecUnsupportedFormat;
	CFDataRef bytes = CFDataCreate(NULL, data->Data, (CFIndex)data->Length);
	SecCertificateRef certificate = bytes ? SecCertificateCreateWithData(NULL, bytes) : NULL;
	if (bytes)
		CFRelease(bytes);
	if (!certificate)
		return errSecDecode;
	*out = certificate;
	return errSecSuccess;
}
OSStatus SecCertificateGetData(SecCertificateRef ref, CSSM_DATA_PTR out)
{
	if (!valid(ref, SecCertificateGetTypeID()) || !out)
		return errSecParam;
	Certificate *certificate = (Certificate *)ref;
	if (!certificate->legacyData)
		certificate->legacyData = SecCertificateCopyData(ref);
	if (!certificate->legacyData)
		return errSecDecode;
	out->Length = (size_t)CFDataGetLength(certificate->legacyData);
	out->Data = (uint8_t *)CFDataGetBytePtr(certificate->legacyData);
	return errSecSuccess;
}
OSStatus SecCertificateGetType(SecCertificateRef ref, CSSM_CERT_TYPE *out)
{
	if (!valid(ref, SecCertificateGetTypeID()) || !out)
		return errSecParam;
	long version = X509_get_version(((Certificate *)ref)->cert);
	*out = version <= 0 ? CSSM_CERT_X_509v1 : version == 1 ? CSSM_CERT_X_509v2 : CSSM_CERT_X_509v3;
	return errSecSuccess;
}
OSStatus SecCertificateGetSubject(SecCertificateRef ref, const CSSM_X509_NAME **out)
{
	if (!valid(ref, SecCertificateGetTypeID()) || !out)
		return errSecParam;
	Certificate *certificate = (Certificate *)ref;
	if (!certificate->subject)
		certificate->subject = legacyName(X509_get_subject_name(certificate->cert));
	if (!certificate->subject)
		return errSecAllocate;
	*out = certificate->subject;
	return errSecSuccess;
}
OSStatus SecCertificateGetIssuer(SecCertificateRef ref, const CSSM_X509_NAME **out)
{
	if (!valid(ref, SecCertificateGetTypeID()) || !out)
		return errSecParam;
	Certificate *certificate = (Certificate *)ref;
	if (!certificate->issuer)
		certificate->issuer = legacyName(X509_get_issuer_name(certificate->cert));
	if (!certificate->issuer)
		return errSecAllocate;
	*out = certificate->issuer;
	return errSecSuccess;
}
OSStatus SecCertificateGetAlgorithmID(SecCertificateRef ref,
    const CSSM_X509_ALGORITHM_IDENTIFIER **out)
{
	if (!valid(ref, SecCertificateGetTypeID()) || !out)
		return errSecParam;
	Certificate *certificate = (Certificate *)ref;
	if (!certificate->hasAlgorithm) {
		const X509_ALGOR *algorithm = X509_get0_tbs_sigalg(certificate->cert);
		const ASN1_OBJECT *object = NULL;
		int parameterType = V_ASN1_UNDEF;
		const void *parameter = NULL;
		X509_ALGOR_get0(&object, &parameterType, &parameter, algorithm);
		int oidLength = object ? OBJ_length(object) : 0;
		if (oidLength <= 0)
			return errSecDecode;
		certificate->algorithm.algorithm.Length = (size_t)oidLength;
		certificate->algorithm.algorithm.Data = malloc((size_t)oidLength);
		if (!certificate->algorithm.algorithm.Data)
			return errSecAllocate;
		memcpy(certificate->algorithm.algorithm.Data, OBJ_get0_data(object), (size_t)oidLength);
		if (parameterType == V_ASN1_NULL) {
			certificate->algorithm.parameters.Length = 2;
			certificate->algorithm.parameters.Data = malloc(2);
			if (!certificate->algorithm.parameters.Data)
				return errSecAllocate;
			certificate->algorithm.parameters.Data[0] = 0x05;
			certificate->algorithm.parameters.Data[1] = 0x00;
		}
		certificate->hasAlgorithm = true;
	}
	*out = &certificate->algorithm;
	return errSecSuccess;
}
CFDataRef SecCertificateCopyNormalizedIssuerContent(SecCertificateRef ref, CFErrorRef *error)
{
	if (!valid(ref, SecCertificateGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	return SecCertificateCopyNormalizedIssuerSequence(ref);
}
CFDataRef SecCertificateCopyNormalizedSubjectContent(SecCertificateRef ref, CFErrorRef *error)
{
	if (!valid(ref, SecCertificateGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	return SecCertificateCopyNormalizedSubjectSequence(ref);
}
static CFStringRef copyASN1String(const ASN1_STRING *s)
{
	unsigned char *out = NULL;
	int len = ASN1_STRING_to_UTF8(&out, s);
	CFStringRef r =
	    len >= 0 ? CFStringCreateWithBytes(NULL, out, len, kCFStringEncodingUTF8, false) : NULL;
	OPENSSL_free(out);
	return r;
}
/* The last attribute of this type, as Apple's SecCertificateCopyCommonName. */
static CFStringRef copyName(X509_NAME *n, int nid)
{
	int i = -1, last = -1;
	while ((i = X509_NAME_get_index_by_NID(n, nid, i)) >= 0)
		last = i;
	if (last < 0)
		return NULL;
	return copyASN1String(X509_NAME_ENTRY_get_data(X509_NAME_get_entry(n, last)));
}
OSStatus SecCertificateCopyCommonName(SecCertificateRef c, CFStringRef *out)
{
	if (!out || !valid(c, SecCertificateGetTypeID()))
		return errSecParam;
	*out = copyName(X509_get_subject_name(((Certificate *)c)->cert), NID_commonName);
	return *out ? 0 : -26276 /* errSecInternal (SecBasePriv.h) */;
}
static CFArrayRef copySANStrings(X509 *x, int type)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	GENERAL_NAMES *names = X509_get_ext_d2i(x, NID_subject_alt_name, NULL, NULL);
	for (int i = 0; names && i < sk_GENERAL_NAME_num(names); i++) {
		GENERAL_NAME *g = sk_GENERAL_NAME_value(names, i);
		if (g->type != type)
			continue;
		CFStringRef v = copyASN1String(g->d.ia5);
		if (v) {
			CFArrayAppendValue(a, v);
			CFRelease(v);
		}
	}
	GENERAL_NAMES_free(names);
	return a;
}
/* Subject summary, as Apple's: the common name, else an email address, else
 * the organizational unit or organization, else a DNS name. */
CFStringRef SecCertificateCopySubjectSummary(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	X509 *x = ((Certificate *)c)->cert;
	X509_NAME *n = X509_get_subject_name(x);
	CFStringRef r = copyName(n, NID_commonName);
	if (!r)
		r = copyName(n, NID_pkcs9_emailAddress);
	if (!r) {
		CFArrayRef e = copySANStrings(x, GEN_EMAIL);
		if (CFArrayGetCount(e))
			r = CFRetain(CFArrayGetValueAtIndex(e, 0));
		CFRelease(e);
	}
	if (!r)
		r = copyName(n, NID_organizationalUnitName);
	if (!r)
		r = copyName(n, NID_organizationName);
	if (!r) {
		CFArrayRef e = copySANStrings(x, GEN_DNS);
		if (CFArrayGetCount(e))
			r = CFRetain(CFArrayGetValueAtIndex(e, 0));
		CFRelease(e);
	}
	return r;
}
CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef a, SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySubjectSummary(c);
}
CFStringRef SecCertificateCopyShortDescription(CFAllocatorRef a, SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySubjectSummary(c);
}
OSStatus SecCertificateCopyEmailAddresses(SecCertificateRef c, CFArrayRef *out)
{
	if (!out || !valid(c, SecCertificateGetTypeID()))
		return errSecParam;
	X509 *x = ((Certificate *)c)->cert;
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	X509_NAME *n = X509_get_subject_name(x);
	for (int i = -1; (i = X509_NAME_get_index_by_NID(n, NID_pkcs9_emailAddress, i)) >= 0;) {
		CFStringRef v = copyASN1String(X509_NAME_ENTRY_get_data(X509_NAME_get_entry(n, i)));
		if (v) {
			CFArrayAppendValue(a, v);
			CFRelease(v);
		}
	}
	CFArrayRef san = copySANStrings(x, GEN_EMAIL);
	CFArrayAppendArray(a, san, CFRangeMake(0, CFArrayGetCount(san)));
	CFRelease(san);
	*out = a;
	return 0;
}
CFDataRef SecCertificateCopySerialNumberData(SecCertificateRef c, CFErrorRef *e)
{
	if (!valid(c, SecCertificateGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	const ASN1_INTEGER *s = X509_get0_serialNumber(((Certificate *)c)->cert);
	return CFDataCreate(NULL, ASN1_STRING_get0_data(s), ASN1_STRING_length(s));
}
CFDataRef SecCertificateCopySerialNumber(SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySerialNumberData(c, e);
}
static CFAbsoluteTime asn1Time(const ASN1_TIME *t)
{
	struct tm tm;
	if (!t || !ASN1_TIME_to_tm(t, &tm))
		return 0;
	return (CFAbsoluteTime)timegm(&tm) - kCFAbsoluteTimeIntervalSince1970;
}
CFDateRef SecCertificateCopyNotValidBeforeDate(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID())
	    ? CFDateCreate(NULL, asn1Time(X509_get0_notBefore(((Certificate *)c)->cert)))
	    : NULL;
}
CFDateRef SecCertificateCopyNotValidAfterDate(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID())
	    ? CFDateCreate(NULL, asn1Time(X509_get0_notAfter(((Certificate *)c)->cert)))
	    : NULL;
}
/* Private, as Apple's: a certificate's CA flag (basic constraints), whether it issued
   itself, and whether it's valid at a time. */
bool SecCertificateIsCA(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID()) && X509_check_ca(((Certificate *)c)->cert) > 0;
}
OSStatus SecCertificateIsSelfSigned(SecCertificateRef c, Boolean *isSelfSigned)
{
	if (!valid(c, SecCertificateGetTypeID()) || !isSelfSigned)
		return errSecParam;
	X509 *x = ((Certificate *)c)->cert;
	*isSelfSigned = X509_check_issued(x, x) == X509_V_OK;
	return errSecSuccess;
}
bool SecCertificateIsSelfSignedCA(SecCertificateRef c)
{
	Boolean self = false;
	return SecCertificateIsSelfSigned(c, &self) == errSecSuccess && self && SecCertificateIsCA(c);
}
bool SecCertificateIsValid(SecCertificateRef c, CFAbsoluteTime verifyTime)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return false;
	X509 *x = ((Certificate *)c)->cert;
	return verifyTime >= asn1Time(X509_get0_notBefore(x)) && verifyTime <= asn1Time(X509_get0_notAfter(x));
}
CFDataRef SecCertificateCopyNormalizedIssuerSequence(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509_NAME(X509_get_issuer_name(((Certificate *)c)->cert), &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
CFDataRef SecCertificateCopyNormalizedSubjectSequence(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509_NAME(X509_get_subject_name(((Certificate *)c)->cert), &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
/* Internal accessors for the keychain. */
CFDataRef _SecCertificateCopyNameDER(SecCertificateRef c, bool issuer)
{
	return issuer ? SecCertificateCopyNormalizedIssuerSequence(c)
	              : SecCertificateCopyNormalizedSubjectSequence(c);
}
CFDataRef _SecCertificateCopyPublicKeySHA1(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char md[EVP_MAX_MD_SIZE];
	unsigned int n = 0;
	if (!X509_pubkey_digest(((Certificate *)c)->cert, EVP_sha1(), md, &n))
		return NULL;
	return CFDataCreate(NULL, md, n);
}
static SecKeyRef wrapKey(EVP_PKEY *p, bool secret)
{
	if (!p)
		return NULL;
	Key *k = (Key *)_SecCreateInstance(SecKeyGetTypeID(), sizeof(*k));
	if (!k) {
		EVP_PKEY_free(p);
		return NULL;
	}
	k->key = p;
	k->private = secret;
	return (SecKeyRef)k;
}
SecKeyRef SecCertificateCopyKey(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	Key *key = (Key *)wrapKey(X509_get_pubkey(((Certificate *)c)->cert), false);
	if (key)
		key->attributeSource = KeyAttributesPublicCopy;
	return (SecKeyRef)key;
}
OSStatus SecCertificateCopyPublicKey(SecCertificateRef c, SecKeyRef *out)
{
	if (!out)
		return errSecParam;
	*out = SecCertificateCopyKey(c);
	return *out ? 0 : errSecDecode;
}
SecKeyRef SecKeyCreateWithData(CFDataRef d, CFDictionaryRef attrs, CFErrorRef *e)
{
	if (!valid(d, CFDataGetTypeID()) || !valid(attrs, CFDictionaryGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	bool secret = CFEqual(
	    CFDictionaryGetValue(attrs, kSecAttrKeyClass) ?: kCFNull, kSecAttrKeyClassPrivate);
	CFTypeRef type = CFDictionaryGetValue(attrs, kSecAttrKeyType);
	if (!type ||
	    (!CFEqual(type, kSecAttrKeyTypeRSA) &&
	        !CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom))) {
		_SecSetError(e, errSecParam, CFSTR("Unsupported key type."));
		return NULL;
	}
	if (CFDictionaryGetValue(attrs, kSecAttrIsPermanent) == kCFBooleanTrue ||
	    CFDictionaryContainsKey(attrs, kSecAttrTokenID)) {
		_SecSetError(e, errSecNotAvailable,
		    CFSTR("Persistent and hardware keys need a keychain service."));
		return NULL;
	}
	const unsigned char *p = CFDataGetBytePtr(d), *start = p;
	long n = CFDataGetLength(d);
	EVP_PKEY *k = NULL;
	if (type && CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom)) {
		long pub = secret ? (n == 97 ? 65 : n == 145 ? 97 : n == 199 ? 133 : 0) : n;
		int nid = pub == 65 ? NID_X9_62_prime256v1
		    : pub == 97     ? NID_secp384r1
		    : pub == 133    ? NID_secp521r1
		                    : 0;
		EC_KEY *ec = nid ? EC_KEY_new_by_curve_name(nid) : NULL;
		if (ec) {
			const EC_GROUP *g = EC_KEY_get0_group(ec);
			EC_POINT *point = EC_POINT_new(g);
			int ok = point && EC_POINT_oct2point(g, point, p, pub, NULL) &&
			    EC_KEY_set_public_key(ec, point);
			if (secret && ok) {
				BIGNUM *b = BN_bin2bn(p + pub, n - pub, NULL);
				ok = b && EC_KEY_set_private_key(ec, b);
				BN_clear_free(b);
			}
			if (ok && EC_KEY_check_key(ec)) {
				k = EVP_PKEY_new();
				EVP_PKEY_assign_EC_KEY(k, ec);
				ec = NULL;
			}
			EC_POINT_free(point);
			EC_KEY_free(ec);
		}
	} else {
		k = secret ? d2i_AutoPrivateKey(NULL, &p, n)
		           : d2i_PublicKey(EVP_PKEY_RSA, NULL, &p, n);
		if (!k && !secret) {
			p = start;
			k = d2i_PUBKEY(NULL, &p, n);
		}
		if (k && (p != start + n || EVP_PKEY_base_id(k) != EVP_PKEY_RSA)) {
			EVP_PKEY_free(k);
			k = NULL;
		}
	}
	if (!k) {
		_SecSetError(e, errSecParam, CFSTR("The key data could not be decoded."));
		return NULL;
	}
	return wrapKey(k, secret);
}
SecKeyRef SecKeyCreateRandomKey(CFDictionaryRef attrs, CFErrorRef *e)
{
	if (!valid(attrs, CFDictionaryGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	CFTypeRef type = CFDictionaryGetValue(attrs, kSecAttrKeyType);
	if (!type ||
	    (!CFEqual(type, kSecAttrKeyTypeRSA) &&
	        !CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom))) {
		_SecSetError(e, errSecParam, CFSTR("Unsupported key type."));
		return NULL;
	}
	if (CFDictionaryGetValue(attrs, kSecAttrIsPermanent) == kCFBooleanTrue ||
	    CFDictionaryContainsKey(attrs, kSecAttrTokenID)) {
		_SecSetError(e, errSecNotAvailable,
		    CFSTR("Persistent and hardware keys need a keychain service."));
		return NULL;
	}
	bool ec = type && CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom);
	int bits = ec ? 256 : 2048;
	CFNumberRef value = CFDictionaryGetValue(attrs, kSecAttrKeySizeInBits);
	if (value && CFGetTypeID(value) == CFNumberGetTypeID())
		CFNumberGetValue(value, kCFNumberIntType, &bits);
	if ((ec && bits != 256 && bits != 384 && bits != 521) ||
	    (!ec && (bits < 1024 || bits > 8192))) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_id(ec ? EVP_PKEY_EC : EVP_PKEY_RSA, NULL);
	EVP_PKEY *p = NULL;
	int ok = c && EVP_PKEY_keygen_init(c) > 0;
	if (ok)
		ok = ec ? EVP_PKEY_CTX_set_ec_paramgen_curve_nid(c,
		              bits == 256       ? NID_X9_62_prime256v1
		                  : bits == 384 ? NID_secp384r1
		                                : NID_secp521r1) > 0
		        : EVP_PKEY_CTX_set_rsa_keygen_bits(c, bits) > 0;
	if (ok)
		ok = EVP_PKEY_keygen(c, &p) > 0;
	EVP_PKEY_CTX_free(c);
	if (!ok) {
		EVP_PKEY_free(p);
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	return wrapKey(p, true);
}
static SecKeyRef createSymmetricKey(const UInt8 *bytes, size_t length, CFErrorRef *error)
{
	if (!bytes || (length != 16 && length != 24 && length != 32)) {
		_SecSetError(error, errSecUnsupportedKeySize, NULL);
		return NULL;
	}
	EVP_PKEY *p = EVP_PKEY_new_raw_private_key(EVP_PKEY_HMAC, NULL, bytes, length);
	SecKeyRef result = wrapKey(p, true);
	if (!result) {
		_SecSetError(error, errSecAllocate, NULL);
		return NULL;
	}
	((Key *)result)->symmetric = true;
	return result;
}

SecKeyRef SecKeyCreateFromData(CFDictionaryRef parameters, CFDataRef keyData, CFErrorRef *error)
{
	if (!valid(parameters, CFDictionaryGetTypeID()) || !valid(keyData, CFDataGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	CFTypeRef type = CFDictionaryGetValue(parameters, kSecAttrKeyType);
	if (!type) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	if (!CFEqual(type, kSecAttrKeyTypeAES))
		return SecKeyCreateWithData(keyData, parameters, error);
	CFTypeRef keyClass = CFDictionaryGetValue(parameters, kSecAttrKeyClass);
	if (keyClass && !CFEqual(keyClass, kSecAttrKeyClassSymmetric)) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	return createSymmetricKey(CFDataGetBytePtr(keyData), (size_t)CFDataGetLength(keyData), error);
}

SecKeyRef SecKeyGenerateSymmetric(CFDictionaryRef parameters, CFErrorRef *error)
{
	if (!valid(parameters, CFDictionaryGetTypeID()) ||
	    !CFEqual(CFDictionaryGetValue(parameters, kSecAttrKeyType) ?: kCFNull, kSecAttrKeyTypeAES)) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	CFTypeRef permanent = CFDictionaryGetValue(parameters, kSecAttrIsPermanent);
	if (permanent == kCFBooleanTrue || CFDictionaryContainsKey(parameters, kSecAttrTokenID) ||
	    CFDictionaryContainsKey(parameters, kSecUseKeychain)) {
		_SecSetError(error, errSecNotAvailable, NULL);
		return NULL;
	}
	int bits = 128;
	CFNumberRef size = CFDictionaryGetValue(parameters, kSecAttrKeySizeInBits);
	if (!size || CFGetTypeID(size) != CFNumberGetTypeID() ||
	    !CFNumberGetValue(size, kCFNumberIntType, &bits) ||
	    (bits != 128 && bits != 192 && bits != 256)) {
		_SecSetError(error, errSecUnsupportedKeySize, NULL);
		return NULL;
	}
	UInt8 bytes[32];
	size_t length = (size_t)bits / 8;
	if (RAND_bytes(bytes, (int)length) != 1) {
		OPENSSL_cleanse(bytes, sizeof(bytes));
		_SecSetError(error, errSecInternalError, NULL);
		return NULL;
	}
	SecKeyRef result = createSymmetricKey(bytes, length, error);
	OPENSSL_cleanse(bytes, sizeof(bytes));
	return result;
}

SecKeyRef SecKeyDeriveFromPassword(CFStringRef password, CFDictionaryRef parameters, CFErrorRef *error)
{
	if (!valid(password, CFStringGetTypeID()) || !valid(parameters, CFDictionaryGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	CFDataRef salt = CFDictionaryGetValue(parameters, kSecAttrSalt);
	if (!valid(salt, CFDataGetTypeID()) || CFDataGetLength(salt) == 0) {
		_SecSetError(error, errSecMissingAlgorithmParms, NULL);
		return NULL;
	}
	int bits = 128, rounds = 0;
	CFNumberRef size = CFDictionaryGetValue(parameters, kSecAttrKeySizeInBits);
	CFNumberRef roundValue = CFDictionaryGetValue(parameters, kSecAttrRounds);
	if (size && (CFGetTypeID(size) != CFNumberGetTypeID() || !CFNumberGetValue(size, kCFNumberIntType, &bits))) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	if (roundValue && (CFGetTypeID(roundValue) != CFNumberGetTypeID() || !CFNumberGetValue(roundValue, kCFNumberIntType, &rounds))) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	if (rounds == 0) rounds = 33333;
	if (rounds < 1 || bits < 8 || bits > 4096 || (bits & 7)) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	CFTypeRef prf = CFDictionaryGetValue(parameters, kSecAttrPRF);
	const EVP_MD *digest = EVP_sha256();
	if (prf && CFEqual(prf, kSecAttrPRFHmacAlgSHA1)) digest = EVP_sha1();
	else if (prf && CFEqual(prf, kSecAttrPRFHmacAlgSHA224)) digest = EVP_sha224();
	else if (prf && CFEqual(prf, kSecAttrPRFHmacAlgSHA256)) digest = EVP_sha256();
	else if (prf && CFEqual(prf, kSecAttrPRFHmacAlgSHA384)) digest = EVP_sha384();
	else if (prf && CFEqual(prf, kSecAttrPRFHmacAlgSHA512)) digest = EVP_sha512();
	else if (prf) {
		_SecSetError(error, errSecInvalidAlgorithmParms, NULL);
		return NULL;
	}
	CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(password), kCFStringEncodingUTF8) + 1;
	if (capacity < 1 || capacity > INT_MAX) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	char *passwordBytes = malloc((size_t)capacity);
	if (!passwordBytes) {
		_SecSetError(error, errSecAllocate, NULL);
		return NULL;
	}
	CFIndex used = 0;
	Boolean converted = CFStringGetBytes(password, CFRangeMake(0, CFStringGetLength(password)),
	    kCFStringEncodingUTF8, 0, false, (UInt8 *)passwordBytes, capacity - 1, &used) == CFStringGetLength(password);
	UInt8 *derived = calloc((size_t)bits / 8, 1);
	int ok = converted && derived && PKCS5_PBKDF2_HMAC(passwordBytes, (int)used,
	    CFDataGetBytePtr(salt), (int)CFDataGetLength(salt), rounds, digest,
	    bits / 8, derived) == 1;
	SecKeyRef result = NULL;
	if (ok)
		result = createSymmetricKey(derived, (size_t)bits / 8, error);
	else
		_SecSetError(error, errSecParam, NULL);
	OPENSSL_cleanse(passwordBytes, (size_t)capacity);
	OPENSSL_clear_free(derived, (size_t)bits / 8);
	free(passwordBytes);
	return result;
}

CFDataRef SecKeyWrapSymmetric(SecKeyRef keyToWrap, SecKeyRef wrappingKey,
	CFDictionaryRef parameters, CFErrorRef *error)
{
	_SecSetError(error, errSecUnimplemented, NULL);
	return NULL;
}

SecKeyRef SecKeyUnwrapSymmetric(CFDataRef *keyToUnwrap, SecKeyRef unwrappingKey,
	CFDictionaryRef parameters, CFErrorRef *error)
{
	_SecSetError(error, errSecUnimplemented, NULL);
	return NULL;
}
CFDataRef SecKeyCopyExternalRepresentation(SecKeyRef ref, CFErrorRef *e)
{
	if (!valid(ref, SecKeyGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	Key *k = (Key *)ref;
	if (k->symmetric) {
		_SecSetError(e, errSecInvalidAlgorithm, NULL);
		return NULL;
	}
	unsigned char *out = NULL;
	int n = 0;
	CFDataRef result = NULL;
	if (EVP_PKEY_base_id(k->key) == EVP_PKEY_EC) {
		EC_KEY *ec = EVP_PKEY_get1_EC_KEY(k->key);
		const EC_GROUP *g = EC_KEY_get0_group(ec);
		size_t pub = EC_POINT_point2oct(
		    g, EC_KEY_get0_public_key(ec), POINT_CONVERSION_UNCOMPRESSED, NULL, 0, NULL);
		size_t bytes = (EC_GROUP_get_degree(g) + 7) / 8;
		out = OPENSSL_malloc(pub + (k->private ? bytes : 0));
		if (out) {
			EC_POINT_point2oct(g, EC_KEY_get0_public_key(ec),
			    POINT_CONVERSION_UNCOMPRESSED, out, pub, NULL);
			if (k->private)
				BN_bn2binpad(EC_KEY_get0_private_key(ec), out + pub, bytes);
			n = pub + (k->private ? bytes : 0);
		}
		EC_KEY_free(ec);
	} else if (k->symmetric) {
		size_t length = 0;
		if (EVP_PKEY_get_raw_private_key(k->key, NULL, &length) > 0 && length <= INT_MAX) {
			out = OPENSSL_malloc(length);
			if (out && EVP_PKEY_get_raw_private_key(k->key, out, &length) > 0)
				n = (int)length;
		}
	} else
		n = k->private ? i2d_PrivateKey(k->key, &out) : i2d_PublicKey(k->key, &out);
	if (n > 0)
		result = CFDataCreate(NULL, out, n);
	OPENSSL_clear_free(out, n > 0 ? (size_t)n : 0);
	if (!result)
		_SecSetError(e, errSecDecode, NULL);
	return result;
}
CFDataRef _SecKeyCopyPrivateKeyInfo(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()) || !((Key *)ref)->private)
		return NULL;
	unsigned char *out = NULL;
	PKCS8_PRIV_KEY_INFO *info = EVP_PKEY2PKCS8(((Key *)ref)->key);
	int n = info ? i2d_PKCS8_PRIV_KEY_INFO(info, &out) : 0;
	PKCS8_PRIV_KEY_INFO_free(info);
	CFDataRef result = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_clear_free(out, n > 0 ? (size_t)n : 0);
	return result;
}
SecKeyRef SecKeyCopyPublicKey(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return NULL;
	if (((Key *)ref)->symmetric)
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_PUBKEY(((Key *)ref)->key, &out);
	const unsigned char *p = out;
	EVP_PKEY *k = n > 0 ? d2i_PUBKEY(NULL, &p, n) : NULL;
	OPENSSL_free(out);
	SecKeyRef result = wrapKey(k, false);
	if (result && ((Key *)ref)->private)
		((Key *)result)->attributeSource = KeyAttributesPublicCopy;
	return result;
}
size_t SecKeyGetBlockSize(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return 0;
	Key *key = (Key *)ref;
	if (key->symmetric) {
		size_t length = 0;
		return EVP_PKEY_get_raw_private_key(key->key, NULL, &length) > 0 ? length : 0;
	}
	return (size_t)(EVP_PKEY_bits(key->key) + 7) / 8;
}
/* Only named algorithms below are accepted. Unknown names never fall back to a
 * weaker hash or padding mode. */
typedef struct {
	const EVP_MD *md;
	int padding;
	bool message;
	bool ec;
	bool encrypt;
} Algorithm;
static bool algorithm(SecKeyAlgorithm a, Algorithm *out)
{
	if (!a || CFGetTypeID(a) != CFStringGetTypeID())
		return false;
	memset(out, 0, sizeof(*out));
#define ALG(symbol, hash, pad, msg, curve, enc)                                                    \
	if (CFEqual(a, symbol)) {                                                                  \
		*out = (Algorithm){hash, pad, msg, curve, enc};                                    \
		return true;                                                                       \
	}
#define RSASIG(H, md)                                                                              \
	ALG(kSecKeyAlgorithmRSASignatureMessagePKCS1v15##H, md, RSA_PKCS1_PADDING, true, false, false) \
	ALG(kSecKeyAlgorithmRSASignatureDigestPKCS1v15##H, md, RSA_PKCS1_PADDING, false, false, false) \
	ALG(kSecKeyAlgorithmRSASignatureMessagePSS##H, md, RSA_PKCS1_PSS_PADDING, true, false, false)  \
	ALG(kSecKeyAlgorithmRSASignatureDigestPSS##H, md, RSA_PKCS1_PSS_PADDING, false, false, false)  \
	ALG(kSecKeyAlgorithmECDSASignatureMessageX962##H, md, 0, true, true, false)                \
	ALG(kSecKeyAlgorithmECDSASignatureDigestX962##H, md, 0, false, true, false)                \
	ALG(kSecKeyAlgorithmRSAEncryptionOAEP##H, md, RSA_PKCS1_OAEP_PADDING, false, false, true)
	RSASIG(SHA1, EVP_sha1())
	RSASIG(SHA224, EVP_sha224())
	RSASIG(SHA256, EVP_sha256())
	RSASIG(SHA384, EVP_sha384())
	RSASIG(SHA512, EVP_sha512())
	ALG(kSecKeyAlgorithmECDSASignatureDigestX962, NULL, 0, false, true, false)
	ALG(kSecKeyAlgorithmECDSASignatureRFC4754, NULL, 0, false, true, false)
	ALG(kSecKeyAlgorithmRSAEncryptionPKCS1, NULL, RSA_PKCS1_PADDING, false, false, true)
	ALG(kSecKeyAlgorithmRSAEncryptionRaw, NULL, RSA_NO_PADDING, false, false, true)
	ALG(kSecKeyAlgorithmRSASignatureRaw, NULL, RSA_NO_PADDING, false, false, false)
	ALG(kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw, NULL, RSA_PKCS1_PADDING, false, false, false)
#undef RSASIG
#undef ALG
	return false;
}
static bool isEC(Key *k)
{
	return EVP_PKEY_base_id(k->key) == EVP_PKEY_EC;
}
/* The same answers Apple's gives: an RSA private key signs and verifies and
 * decrypts; an RSA public key verifies, encrypts and decrypts (raw RSA); an EC
 * private key signs and exchanges keys, an EC public key verifies. */
Boolean SecKeyIsAlgorithmSupported(SecKeyRef ref, SecKeyOperationType op, SecKeyAlgorithm alg)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return false;
	Key *k = (Key *)ref;
	if (k->symmetric)
		return false;
	Algorithm a;
	if (op == kSecKeyOperationTypeKeyExchange)
		return isEC(k) && k->private &&
		    (CFEqual(alg, kSecKeyAlgorithmECDHKeyExchangeStandard) ||
		        CFEqual(alg, kSecKeyAlgorithmECDHKeyExchangeCofactor));
	if (!algorithm(alg, &a) || a.ec != isEC(k))
		return false;
	switch (op) {
	case kSecKeyOperationTypeSign:
		return !a.encrypt && k->private;
	case kSecKeyOperationTypeVerify:
		return !a.encrypt && (!k->private || !isEC(k));
	case kSecKeyOperationTypeEncrypt:
		return a.encrypt && !k->private;
	case kSecKeyOperationTypeDecrypt:
		return a.encrypt;
	default:
		return false;
	}
}
static int configure(EVP_PKEY_CTX *c, Algorithm a, bool crypt)
{
	int ok = 1;
	if (!a.ec) {
		ok = EVP_PKEY_CTX_set_rsa_padding(c, a.padding) > 0;
		if (ok && a.padding == RSA_PKCS1_PSS_PADDING)
			ok = EVP_PKEY_CTX_set_rsa_pss_saltlen(c, RSA_PSS_SALTLEN_DIGEST) > 0;
		if (ok && crypt && a.padding == RSA_PKCS1_OAEP_PADDING)
			ok = EVP_PKEY_CTX_set_rsa_oaep_md(c, a.md) > 0 &&
			    EVP_PKEY_CTX_set_rsa_mgf1_md(c, a.md) > 0;
	}
	/* PKCS#1 v1.5 signatures carry their DigestInfo in the input (pkcs1Input). */
	if (ok && !crypt && a.md && a.padding != RSA_PKCS1_PADDING)
		ok = EVP_PKEY_CTX_set_signature_md(c, a.md) > 0;
	return ok;
}
/* The bytes the key operates on: the digest (hashing a message first), and
 * for PKCS#1 v1.5 the DigestInfo around it. Apple's doesn't check the length
 * of a PKCS#1 digest; ECDSA and PSS digests must match the hash. */
static CFDataRef signInput(Algorithm a, CFDataRef d)
{
	if (!valid(d, CFDataGetTypeID()))
		return NULL;
	unsigned char buf[EVP_MAX_MD_SIZE];
	const unsigned char *p = CFDataGetBytePtr(d);
	size_t n = CFDataGetLength(d);
	if (a.message) {
		unsigned int len = 0;
		if (!EVP_Digest(p, n, buf, &len, a.md, NULL))
			return NULL;
		p = buf;
		n = len;
	} else if (a.md && a.padding != RSA_PKCS1_PADDING && n != (size_t)EVP_MD_get_size(a.md))
		return NULL;
	CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
	if (a.padding == RSA_PKCS1_PADDING && a.md) {
		static const unsigned char sha1[] = {0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03,
		    0x02, 0x1a, 0x05, 0x00, 0x04, 0x14};
		unsigned char prefix[19] = {0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
		    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20};
		int nid = EVP_MD_get_type(a.md);
		if (nid == NID_sha1)
			CFDataAppendBytes(out, sha1, sizeof(sha1));
		else {
			int mdlen = EVP_MD_get_size(a.md);
			prefix[1] = 0x11 + mdlen;
			prefix[14] = nid == NID_sha256 ? 1 : nid == NID_sha384 ? 2 : nid == NID_sha512 ? 3 : 4;
			prefix[18] = mdlen;
			CFDataAppendBytes(out, prefix, sizeof(prefix));
		}
	}
	CFDataAppendBytes(out, p, n);
	return out;
}
CFDataRef SecKeyCreateSignature(SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFErrorRef *e)
{
	Algorithm a;
	if (!SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeSign, alg) ||
	    !algorithm(alg, &a)) {
		_SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
		return NULL;
	}
	CFDataRef in = signInput(a, data);
	if (!in) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	const unsigned char *p = CFDataGetBytePtr(in);
	size_t n = CFDataGetLength(in);
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	size_t size = 0;
	int ok = c && EVP_PKEY_sign_init(c) > 0 && configure(c, a, false) &&
	    EVP_PKEY_sign(c, NULL, &size, p, n) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(size) : NULL;
	ok = out && EVP_PKEY_sign(c, out, &size, p, n) > 0;
	CFDataRef result = ok ? CFDataCreate(NULL, out, size) : NULL;
	OPENSSL_free(out);
	EVP_PKEY_CTX_free(c);
	CFRelease(in);
	if (!result)
		_SecSetError(e, errSecParam, NULL);
	return result;
}
Boolean SecKeyVerifySignature(
    SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFDataRef sig, CFErrorRef *e)
{
	Algorithm a;
	if (!valid(sig, CFDataGetTypeID()) ||
	    !SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeVerify, alg) ||
	    !algorithm(alg, &a))
		return _SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
	CFDataRef in = signInput(a, data);
	if (!in)
		return _SecSetError(e, errSecParam, NULL);
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	int ok = c && EVP_PKEY_verify_init(c) > 0 && configure(c, a, false) &&
	    EVP_PKEY_verify(c, CFDataGetBytePtr(sig), CFDataGetLength(sig), CFDataGetBytePtr(in),
	        CFDataGetLength(in)) == 1;
	EVP_PKEY_CTX_free(c);
	CFRelease(in);
	return ok ? true : _SecSetError(e, errSecVerifyFailed, NULL);
}
static CFDataRef keyCrypt(
    SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFErrorRef *e, bool decrypt)
{
	Algorithm a;
	if (!valid(data, CFDataGetTypeID()) ||
	    !SecKeyIsAlgorithmSupported(
	        ref, decrypt ? kSecKeyOperationTypeDecrypt : kSecKeyOperationTypeEncrypt, alg) ||
	    !algorithm(alg, &a)) {
		_SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	int ok = c && (decrypt ? EVP_PKEY_decrypt_init(c) : EVP_PKEY_encrypt_init(c)) > 0 &&
	    configure(c, a, true);
	size_t n = 0;
	const unsigned char *p = CFDataGetBytePtr(data);
	size_t len = CFDataGetLength(data);
	if (ok)
		ok = (decrypt ? EVP_PKEY_decrypt(c, NULL, &n, p, len)
		              : EVP_PKEY_encrypt(c, NULL, &n, p, len)) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(n) : NULL;
	if (out)
		ok = (decrypt ? EVP_PKEY_decrypt(c, out, &n, p, len)
		              : EVP_PKEY_encrypt(c, out, &n, p, len)) > 0;
	else
		ok = 0;
	CFDataRef r = ok ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_clear_free(out, n);
	EVP_PKEY_CTX_free(c);
	if (!r)
		_SecSetError(e, decrypt ? errSecDecode : errSecParam, NULL);
	return r;
}
CFDataRef SecKeyCreateEncryptedData(SecKeyRef k, SecKeyAlgorithm a, CFDataRef d, CFErrorRef *e)
{
	return keyCrypt(k, a, d, e, false);
}
CFDataRef SecKeyCreateDecryptedData(SecKeyRef k, SecKeyAlgorithm a, CFDataRef d, CFErrorRef *e)
{
	return keyCrypt(k, a, d, e, true);
}
CFDictionaryRef SecKeyCopyAttributes(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return NULL;
	Key *k = (Key *)ref;
	int bits = k->symmetric ? (int)(SecKeyGetBlockSize(ref) * 8) : EVP_PKEY_bits(k->key);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &bits);
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	bool ec = isEC(k), priv = k->private, symmetric = k->symmetric;
	bool publicCopy = ec && !priv && k->attributeSource == KeyAttributesPublicCopy;
	if (!symmetric) {
		CFDictionarySetValue(d, kSecAttrKeyType, ec ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA);
		CFDictionarySetValue(d, kSecAttrKeyClass, priv ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic);
	}
	CFDictionarySetValue(d, kSecClass, kSecClassKey);
	CFDictionarySetValue(d, kSecAttrKeySizeInBits, n);
	CFDictionarySetValue(d, kSecAttrEffectiveKeySize, n);
	CFDictionarySetValue(d, kSecAttrCanEncrypt, symmetric || !priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanDecrypt, symmetric || priv || !ec ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanSign, symmetric || priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanVerify, symmetric || !priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanDerive, ec && !publicCopy ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrIsPermanent, symmetric ? kCFBooleanFalse : (priv || !ec || publicCopy) ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrIsSensitive, kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrIsExtractable, kCFBooleanTrue);
	CFDictionarySetValue(d, kSecAttrCanWrap, symmetric || (!priv && (!ec || publicCopy)) ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanUnwrap, symmetric || priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("modi"), kCFBooleanTrue);
	CFDictionarySetValue(d, CFSTR("asen"), kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("next"), kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("priv"), (priv || !ec || publicCopy) ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("snrc"), kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("vyrc"), kCFBooleanFalse);
	/* The application label is the SHA-1 of the public key bits, as Apple's. */
	SecKeyRef pub = symmetric ? (SecKeyRef)CFRetain(ref) : priv ? SecKeyCopyPublicKey(ref) : (SecKeyRef)CFRetain(ref);
	CFDataRef bitsData = pub ? SecKeyCopyExternalRepresentation(pub, NULL) : NULL;
	if (bitsData) {
		unsigned char md[20];
		unsigned int len = 0;
		EVP_Digest(CFDataGetBytePtr(bitsData), CFDataGetLength(bitsData), md, &len, EVP_sha1(), NULL);
		CFDataRef label = CFDataCreate(NULL, md, len);
		CFDictionarySetValue(d, kSecAttrApplicationLabel, label);
		CFRelease(label);
		CFRelease(bitsData);
	}
	if (pub)
		CFRelease(pub);
	CFDataRef representation = SecKeyCopyExternalRepresentation(ref, NULL);
	if (representation) {
		CFDictionarySetValue(d, kSecValueData, representation);
		CFRelease(representation);
	}
	CFRelease(n);
	return d;
}
OSStatus SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey)
{
	CFErrorRef e = NULL;
	SecKeyRef priv = SecKeyCreateRandomKey(parameters, &e);
	if (!priv) {
		OSStatus st = e ? (OSStatus)CFErrorGetCode(e) : errSecParam;
		if (e)
			CFRelease(e);
		return st;
	}
	if (publicKey)
		*publicKey = SecKeyCopyPublicKey(priv);
	if (privateKey)
		*privateKey = priv;
	else
		CFRelease(priv);
	return 0;
}
void SecKeyGeneratePairAsync(CFDictionaryRef parameters, dispatch_queue_t deliveryQueue,
	SecKeyGeneratePairBlock result)
{
	if (!result)
		return;
	CFDictionaryRef copied = valid(parameters, CFDictionaryGetTypeID())
	    ? CFDictionaryCreateCopy(NULL, parameters) : NULL;
	SecKeyGeneratePairBlock callback = Block_copy(result);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		SecKeyRef publicKey = NULL, privateKey = NULL;
		OSStatus status = copied ? SecKeyGeneratePair(copied, &publicKey, &privateKey) : errSecParam;
		CFErrorRef error = NULL;
		if (status)
			error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, status, NULL);
		dispatch_queue_t queue = deliveryQueue ?: dispatch_get_main_queue();
		dispatch_async(queue, ^{
			callback(publicKey, privateKey, error);
			if (error) CFRelease(error);
			if (publicKey) CFRelease(publicKey);
			if (privateKey) CFRelease(privateKey);
			if (copied) CFRelease(copied);
			Block_release(callback);
		});
	});
}

OSStatus SecKeyCreatePair(SecKeychainRef keychain, CSSM_ALGORITHMS algorithm,
	uint32 keySizeInBits, CSSM_CC_HANDLE context, CSSM_KEYUSE publicUsage,
	uint32 publicAttributes, CSSM_KEYUSE privateUsage, uint32 privateAttributes,
	SecAccessRef initialAccess, SecKeyRef *publicKey, SecKeyRef *privateKey)
{
	if (keychain || context || initialAccess || algorithm != CSSM_ALGID_RSA ||
	    (publicUsage && publicUsage != CSSM_KEYUSE_ANY) ||
	    (privateUsage && privateUsage != CSSM_KEYUSE_ANY) || publicAttributes || privateAttributes)
		return errSecNotAvailable;
	int bits = (int)keySizeInBits;
	CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &bits);
	CFDictionaryRef parameters = CFDictionaryCreate(NULL,
	    (const void *[]){kSecAttrKeyType, kSecAttrKeySizeInBits},
	    (const void *[]){kSecAttrKeyTypeRSA, size}, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	SecKeyRef pub = NULL, priv = NULL;
	OSStatus status = parameters ? SecKeyGeneratePair(parameters, &pub, &priv) : errSecAllocate;
	if (size) CFRelease(size);
	if (parameters) CFRelease(parameters);
	if (status) return status;
	if (publicKey) *publicKey = pub; else if (pub) CFRelease(pub);
	if (privateKey) *privateKey = priv; else if (priv) CFRelease(priv);
	return errSecSuccess;
}

OSStatus SecKeyGenerate(SecKeychainRef keychain, CSSM_ALGORITHMS algorithm,
	uint32 keySizeInBits, CSSM_CC_HANDLE context, CSSM_KEYUSE usage,
	uint32 attributes, SecAccessRef initialAccess, SecKeyRef *key)
{
	if (!key)
		return errSecParam;
	*key = NULL;
	if (keychain || context || initialAccess || algorithm != CSSM_ALGID_AES ||
	    (usage && usage != CSSM_KEYUSE_ANY) || attributes)
		return errSecNotAvailable;
	int bits = (int)keySizeInBits;
	CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &bits);
	CFDictionaryRef parameters = CFDictionaryCreate(NULL,
	    (const void *[]){kSecAttrKeyType, kSecAttrKeySizeInBits},
	    (const void *[]){kSecAttrKeyTypeAES, size}, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (size) CFRelease(size);
	if (!parameters)
		return errSecAllocate;
	CFErrorRef error = NULL;
	*key = SecKeyGenerateSymmetric(parameters, &error);
	CFRelease(parameters);
	OSStatus status = *key ? errSecSuccess : error ? (OSStatus)CFErrorGetCode(error) : errSecParam;
	if (error) CFRelease(error);
	return status;
}
SecPolicyRef SecPolicyCreateWithProperties(CFTypeRef oid, CFDictionaryRef properties)
{
	if (!valid(oid, CFStringGetTypeID()) ||
	    (properties && !valid(properties, CFDictionaryGetTypeID())))
		return NULL;
	Policy *p = (Policy *)_SecCreateInstance(SecPolicyGetTypeID(), sizeof(*p));
	CFMutableDictionaryRef d = properties
	    ? CFDictionaryCreateMutableCopy(NULL, 0, properties)
	    : CFDictionaryCreateMutable(
	          NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(d, kSecPolicyOid, oid);
	/* As Apple's: a server (non-client) policy doesn't record kSecPolicyClient. */
	if (CFDictionaryGetValue(d, kSecPolicyClient) == kCFBooleanFalse)
		CFDictionaryRemoveValue(d, kSecPolicyClient);
	p->properties = d;
	char text[160];
	if (CFStringGetCString(oid, text, sizeof(text), kCFStringEncodingASCII)) {
		ASN1_OBJECT *object = OBJ_txt2obj(text, 1);
		if (object) {
			int length = OBJ_length(object);
			if (length > 0)
				p->oidData = CFDataCreate(NULL, OBJ_get0_data(object), length);
			ASN1_OBJECT_free(object);
		}
	}
	return (SecPolicyRef)p;
}
SecPolicyRef SecPolicyCreateBasicX509(void)
{
	return SecPolicyCreateWithProperties(kSecPolicyAppleX509Basic, NULL);
}
SecPolicyRef SecPolicyCreateSSL(Boolean server, CFStringRef hostname)
{
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!server)
		CFDictionarySetValue(d, kSecPolicyClient, kCFBooleanTrue);
	if (hostname)
		CFDictionarySetValue(d, kSecPolicyName, hostname);
	SecPolicyRef p = SecPolicyCreateWithProperties(kSecPolicyAppleSSL, d);
	CFRelease(d);
	return p;
}
SecPolicyRef SecPolicyCreateWithOID(CFTypeRef oid)
{
	return SecPolicyCreateWithProperties(oid, NULL);
}
/* Revocation isn't checked (no network fetching, no OCSP responder cache):
 * the policy exists so it can be passed along, and constrains nothing. */
SecPolicyRef SecPolicyCreateRevocation(CFOptionFlags flags)
{
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberCFIndexType, &flags);
	CFDictionarySetValue(d, kSecPolicyRevocationFlags, n);
	CFRelease(n);
	SecPolicyRef p = SecPolicyCreateWithProperties(kSecPolicyAppleRevocation, d);
	CFRelease(d);
	return p;
}
CFDictionaryRef SecPolicyCopyProperties(SecPolicyRef p)
{
	return valid(p, SecPolicyGetTypeID()) ? CFRetain(((Policy *)p)->properties) : NULL;
}
OSStatus SecPolicyGetOID(SecPolicyRef ref, CSSM_OID *out)
{
	if (!valid(ref, SecPolicyGetTypeID()) || !out)
		return errSecParam;
	CFDataRef data = ((Policy *)ref)->oidData;
	if (!data)
		return errSecDecode;
	out->Length = (size_t)CFDataGetLength(data);
	out->Data = (uint8_t *)CFDataGetBytePtr(data);
	return errSecSuccess;
}
OSStatus SecPolicyGetValue(SecPolicyRef ref, CSSM_DATA *out)
{
	if (!valid(ref, SecPolicyGetTypeID()) || !out)
		return errSecParam;
	CFTypeRef value = CFDictionaryGetValue(((Policy *)ref)->properties, CFSTR("value"));
	if (value && CFGetTypeID(value) != CFDataGetTypeID())
		return errSecDecode;
	CFDataRef data = (CFDataRef)value;
	out->Length = data ? (size_t)CFDataGetLength(data) : 0;
	out->Data = data ? (uint8_t *)CFDataGetBytePtr(data) : NULL;
	return errSecSuccess;
}
OSStatus SecPolicySetValue(SecPolicyRef ref, const CSSM_DATA *value)
{
	if (!valid(ref, SecPolicyGetTypeID()) || !value || (value->Length && !value->Data))
		return errSecParam;
	return errSecParam;
}
OSStatus SecPolicySetProperties(SecPolicyRef ref, CFDictionaryRef properties)
{
	if (!valid(ref, SecPolicyGetTypeID()) || !valid(properties, CFDictionaryGetTypeID()))
		return errSecParam;
	Policy *policy = (Policy *)ref;
	CFMutableDictionaryRef replacement = CFDictionaryCreateMutableCopy(NULL, 0, properties);
	if (!replacement)
		return errSecAllocate;
	CFDictionarySetValue(replacement, kSecPolicyOid,
	    CFDictionaryGetValue(policy->properties, kSecPolicyOid));
	if (CFDictionaryGetValue(replacement, kSecPolicyClient) == kCFBooleanFalse)
		CFDictionaryRemoveValue(replacement, kSecPolicyClient);
	CFRelease(policy->properties);
	policy->properties = replacement;
	return errSecSuccess;
}
OSStatus SecPolicyGetTPHandle(SecPolicyRef ref, CSSM_TP_HANDLE *handle)
{
	if (!valid(ref, SecPolicyGetTypeID()) || !handle)
		return errSecParam;
	return errSecServiceNotAvailable;
}
static SecPolicyRef policyForOID(const CSSM_OID *oid)
{
	if (!oid || !oid->Data || !oid->Length || oid->Length > 1024)
		return NULL;
	UInt8 *der = malloc(oid->Length + 6);
	if (!der)
		return NULL;
	size_t header = 0;
	der[header++] = V_ASN1_OBJECT;
	if (oid->Length < 128) {
		der[header++] = (UInt8)oid->Length;
	} else {
		UInt8 encoded[sizeof(size_t)];
		size_t count = 0, n = oid->Length;
		while (n) {
			encoded[count++] = (UInt8)n;
			n >>= 8;
		}
		der[header++] = (UInt8)(0x80 | count);
		while (count)
			der[header++] = encoded[--count];
	}
	memcpy(der + header, oid->Data, oid->Length);
	const unsigned char *cursor = der;
	ASN1_OBJECT *object = d2i_ASN1_OBJECT(NULL, &cursor, (long)(header + oid->Length));
	free(der);
	if (!object)
		return NULL;
	char text[160];
	int length = OBJ_obj2txt(text, sizeof(text), object, 1);
	ASN1_OBJECT_free(object);
	if (length <= 0 || (size_t)length >= sizeof(text))
		return NULL;
	CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingASCII);
	SecPolicyRef policy = string ? SecPolicyCreateWithOID(string) : NULL;
	if (string)
		CFRelease(string);
	return policy;
}
OSStatus SecPolicySearchCreate(CSSM_CERT_TYPE certType, const CSSM_OID *policyOID,
    const CSSM_DATA *value, SecPolicySearchRef *out)
{
	(void)value;
	if (!out || !policyOID || (certType != CSSM_CERT_UNKNOWN &&
	        certType != CSSM_CERT_X_509v1 && certType != CSSM_CERT_X_509v2 &&
	        certType != CSSM_CERT_X_509v3))
		return errSecParam;
	*out = NULL;
	SecPolicyRef policy = policyForOID(policyOID);
	PolicySearch *search = (PolicySearch *)_SecCreateInstance(
	    SecPolicySearchGetTypeID(), sizeof(*search));
	if (!search) {
		if (policy)
			CFRelease(policy);
		return errSecAllocate;
	}
	search->policy = policy;
	*out = (SecPolicySearchRef)search;
	return errSecSuccess;
}
OSStatus SecPolicySearchCopyNext(SecPolicySearchRef ref, SecPolicyRef *out)
{
	if (!valid(ref, SecPolicySearchGetTypeID()) || !out)
		return errSecParam;
	PolicySearch *search = (PolicySearch *)ref;
	if (!search->policy || search->returned)
		return errSecPolicyNotFound;
	*out = (SecPolicyRef)CFRetain(search->policy);
	search->returned = true;
	return errSecSuccess;
}
static CFArrayRef asArray(CFTypeRef o, CFTypeID type)
{
	if (valid(o, type))
		return CFArrayCreate(NULL, &o, 1, &kCFTypeArrayCallBacks);
	if (!valid(o, CFArrayGetTypeID()) || CFArrayGetCount(o) == 0)
		return NULL;
	for (CFIndex i = 0; i < CFArrayGetCount(o); i++)
		if (!valid(CFArrayGetValueAtIndex(o, i), type))
			return NULL;
	return CFArrayCreateCopy(NULL, o);
}
OSStatus SecTrustCreateWithCertificates(CFTypeRef certs, CFTypeRef policies, SecTrustRef *out)
{
	if (!out)
		return errSecParam;
	*out = NULL;
	CFArrayRef c = asArray(certs, SecCertificateGetTypeID()),
	           p = asArray(policies, SecPolicyGetTypeID());
	if (!c || !p) {
		if (c)
			CFRelease(c);
		if (p)
			CFRelease(p);
		return errSecParam;
	}
	Trust *t = (Trust *)_SecCreateInstance(SecTrustGetTypeID(), sizeof(*t));
	t->certs = c;
	t->policies = p;
	t->result = kSecTrustResultInvalid;
	*out = (SecTrustRef)t;
	return 0;
}
/* The system's anchors: Finch's pinned root bundle (userland/certificates). */
OSStatus SecTrustCopyAnchorCertificates(CFArrayRef *anchors)
{
	if (!anchors)
		return errSecParam;
	char path[PATH_MAX];
	const char *file = finch_ca_bundle((const void *)SecTrustCopyAnchorCertificates, path);
	BIO *in = file ? BIO_new_file(file, "r") : NULL;
	if (!in)
		return errSecNoTrustSettings;
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	X509 *x;
	while ((x = PEM_read_bio_X509(in, NULL, NULL, NULL))) {
		Certificate *c = (Certificate *)_SecCreateInstance(SecCertificateGetTypeID(), sizeof(*c));
		if (!c) {
			X509_free(x);
			break;
		}
		c->cert = x;
		CFArrayAppendValue(out, c);
		CFRelease(c);
	}
	ERR_clear_error();
	BIO_free(in);
	*anchors = out;
	return errSecSuccess;
}
OSStatus SecTrustSetAnchorCertificates(SecTrustRef ref, CFArrayRef anchors)
{
	if (!valid(ref, SecTrustGetTypeID()) || (anchors && !valid(anchors, CFArrayGetTypeID())))
		return errSecParam;
	for (CFIndex i = 0; anchors && i < CFArrayGetCount(anchors); i++)
		if (!valid(CFArrayGetValueAtIndex(anchors, i), SecCertificateGetTypeID()))
			return errSecParam;
	Trust *t = (Trust *)ref;
	if (t->anchors)
		CFRelease(t->anchors);
	t->anchors = anchors ? CFArrayCreateCopy(NULL, anchors) : NULL;
	t->anchorsOnly = anchors != NULL;
	t->result = kSecTrustResultInvalid;
	return 0;
}
OSStatus SecTrustSetAnchorCertificatesOnly(SecTrustRef ref, Boolean only)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return errSecParam;
	Trust *t = (Trust *)ref;
	t->anchorsOnly = only;
	t->result = kSecTrustResultInvalid;
	return 0;
}
OSStatus SecTrustSetNetworkFetchAllowed(SecTrustRef ref, Boolean allowed)
{
	return valid(ref, SecTrustGetTypeID()) ? (allowed ? errSecUnimplemented : 0) : errSecParam;
}
OSStatus SecTrustGetNetworkFetchAllowed(SecTrustRef ref, Boolean *allowed)
{
	if (!valid(ref, SecTrustGetTypeID()) || !allowed)
		return errSecParam;
	/* Finch does not fetch missing certificates from the network. */
	*allowed = false;
	return errSecSuccess;
}
OSStatus SecTrustSetOptions(SecTrustRef ref, SecTrustOptionFlags options)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return errSecParam;
	const SecTrustOptionFlags supported = kSecTrustOptionAllowExpired |
	    kSecTrustOptionLeafIsCA | kSecTrustOptionAllowExpiredRoot |
	    kSecTrustOptionImplicitAnchors;
	if (options & ~supported)
		return errSecUnimplemented;
	Trust *trust = (Trust *)ref;
	trust->options = options;
	trust->result = kSecTrustResultInvalid;
	return errSecSuccess;
}
OSStatus SecTrustSetKeychains(SecTrustRef ref, CFTypeRef keychains)
{
	/* macOS 10.12 and later ignore this deprecated setting. */
	return valid(ref, SecTrustGetTypeID()) ? errSecSuccess : errSecParam;
}
OSStatus SecTrustGetCssmResultCode(SecTrustRef ref, OSStatus *resultCode)
{
	if (!valid(ref, SecTrustGetTypeID()) || !resultCode)
		return errSecParam;
	Trust *trust = (Trust *)ref;
	if (trust->result == kSecTrustResultInvalid)
		return errSecTrustNotAvailable;
	*resultCode = trust->status;
	return errSecSuccess;
}
OSStatus SecTrustGetCssmResult(SecTrustRef ref, CSSM_TP_VERIFY_CONTEXT_RESULT_PTR *result)
{
	if (!valid(ref, SecTrustGetTypeID()) || !result)
		return errSecParam;
	*result = NULL;
	return errSecServiceNotAvailable;
}
OSStatus SecTrustGetTPHandle(SecTrustRef ref, CSSM_TP_HANDLE *handle)
{
	if (!valid(ref, SecTrustGetTypeID()) || !handle)
		return errSecParam;
	return errSecServiceNotAvailable;
}
OSStatus SecTrustSetVerifyDate(SecTrustRef ref, CFDateRef date)
{
	if (!valid(ref, SecTrustGetTypeID()) || !valid(date, CFDateGetTypeID()))
		return errSecParam;
	Trust *t = (Trust *)ref;
	if (t->date)
		CFRelease(t->date);
	t->date = CFRetain(date);
	t->result = kSecTrustResultInvalid;
	return 0;
}
/* OpenSSL's verification errors as Apple's trust errors. */
static OSStatus trustStatus(int err)
{
	switch (err) {
	case X509_V_OK:
		return 0;
	case X509_V_ERR_CERT_HAS_EXPIRED:
		return errSecCertificateExpired;
	case X509_V_ERR_CERT_NOT_YET_VALID:
		return errSecCertificateNotValidYet;
	case X509_V_ERR_HOSTNAME_MISMATCH:
	case X509_V_ERR_IP_ADDRESS_MISMATCH:
		return errSecHostNameMismatch;
	case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT:
	case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
	case X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE:
		return errSecCreateChainFailed;
	case X509_V_ERR_INVALID_PURPOSE:
		return errSecInvalidExtendedKeyUsage;
	case X509_V_ERR_CERT_SIGNATURE_FAILURE:
		return errSecInvalidSignature;
	case X509_V_ERR_INVALID_CA:
		return errSecNoBasicConstraints;
	default:
		return errSecNotTrusted;
	}
}
static int trustVerifyCallback(int ok, X509_STORE_CTX *context)
{
	if (ok)
		return 1;
	Trust *trust = X509_STORE_CTX_get_app_data(context);
	int error = X509_STORE_CTX_get_error(context);
	int depth = X509_STORE_CTX_get_error_depth(context);
	if (error == X509_V_ERR_CERT_HAS_EXPIRED && trust &&
	    ((trust->options & kSecTrustOptionAllowExpired) ||
	        (depth > 0 && (trust->options & kSecTrustOptionAllowExpiredRoot)))) {
		X509_STORE_CTX_set_error(context, X509_V_OK);
		return 1;
	}
	if (error == X509_V_ERR_INVALID_CA && depth == 0 && trust &&
	    (trust->options & kSecTrustOptionLeafIsCA)) {
		X509_STORE_CTX_set_error(context, X509_V_OK);
		return 1;
	}
	return 0;
}
static void setChain(Trust *t, STACK_OF(X509) *chain)
{
	if (t->chain)
		CFRelease(t->chain);
	t->chain = NULL;
	if (!chain)
		return;
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < sk_X509_num(chain); i++) {
		X509 *x = sk_X509_value(chain, i);
		SecCertificateRef found = NULL;
		/* Hand back the caller's objects where the chain uses them. */
		CFArrayRef pools[] = {t->certs, t->anchors};
		for (int p = 0; p < 2 && !found; p++)
			for (CFIndex j = 0; pools[p] && j < CFArrayGetCount(pools[p]) && !found; j++) {
				Certificate *c = (Certificate *)CFArrayGetValueAtIndex(pools[p], j);
				if (X509_cmp(c->cert, x) == 0)
					found = (SecCertificateRef)c;
			}
		if (found)
			CFArrayAppendValue(a, found);
		else {
			Certificate *c = (Certificate *)_SecCreateInstance(SecCertificateGetTypeID(), sizeof(*c));
			X509_up_ref(x);
			c->cert = x;
			CFArrayAppendValue(a, c);
			CFRelease(c);
		}
	}
	t->chain = a;
}
static bool evaluate(Trust *t)
{
	X509_STORE *s = X509_STORE_new();
	X509_STORE_CTX *c = X509_STORE_CTX_new();
	STACK_OF(X509) *chain = sk_X509_new_null();
	int ok = s && c && chain;
	int err = X509_V_ERR_UNSPECIFIED;
	bool implicitAnchorUsed = false;
	/* Mozilla's bundle approves HTTPS server roots, not code-signing or mail
	 * identities. Keep it out of those other policy checks. */
	bool https = false, serverPolicies = true;
	for (CFIndex i = 0; i < CFArrayGetCount(t->policies); i++) {
		CFDictionaryRef props = ((Policy *)CFArrayGetValueAtIndex(t->policies, i))->properties;
		CFTypeRef oid = CFDictionaryGetValue(props, kSecPolicyOid);
		if (CFEqual(oid, kSecPolicyAppleSSL)) {
			if (CFDictionaryGetValue(props, kSecPolicyClient) == kCFBooleanTrue)
				serverPolicies = false;
			else
				https = true;
		} else if (!CFEqual(oid, kSecPolicyAppleX509Basic) && !CFEqual(oid, kSecPolicyAppleRevocation))
			serverPolicies = false;
	}
	if (ok && https && serverPolicies && !t->anchorsOnly) {
		char path[PATH_MAX];
		const char *file = finch_ca_bundle((const void *)evaluate, path);
		if (!file || X509_STORE_load_file(s, file) != 1)
			ERR_clear_error(); /* Explicit anchors may still suffice. */
	}
	for (CFIndex i = 0; ok && t->anchors && i < CFArrayGetCount(t->anchors); i++)
		X509_STORE_add_cert(s, ((Certificate *)CFArrayGetValueAtIndex(t->anchors, i))->cert);
	if (ok && (t->options & kSecTrustOptionImplicitAnchors))
		for (CFIndex i = 0; ok && i < CFArrayGetCount(t->certs); i++) {
			X509 *candidate = ((Certificate *)CFArrayGetValueAtIndex(t->certs, i))->cert;
			if (X509_check_issued(candidate, candidate) == X509_V_OK) {
				if (X509_STORE_add_cert(s, candidate) == 1)
					implicitAnchorUsed = true;
				else
					ERR_clear_error();
			}
		}
	for (CFIndex i = 1; ok && i < CFArrayGetCount(t->certs); i++)
		sk_X509_push(chain, ((Certificate *)CFArrayGetValueAtIndex(t->certs, i))->cert);
	if (ok) {
		ok = X509_STORE_CTX_init(c, s, ((Certificate *)CFArrayGetValueAtIndex(t->certs, 0))->cert, chain);
		if (ok) {
			X509_STORE_CTX_set_app_data(c, t);
			X509_STORE_CTX_set_verify_cb(c, trustVerifyCallback);
		}
	}
	if (ok) {
		X509_VERIFY_PARAM *p = X509_STORE_CTX_get0_param(c);
		time_t when = (time_t)((t->date ? CFDateGetAbsoluteTime(t->date) : CFAbsoluteTimeGetCurrent()) +
		    kCFAbsoluteTimeIntervalSince1970);
		X509_VERIFY_PARAM_set_time(p, when);
		for (CFIndex i = 0; ok && i < CFArrayGetCount(t->policies); i++) {
			CFDictionaryRef props = ((Policy *)CFArrayGetValueAtIndex(t->policies, i))->properties;
			CFTypeRef oid = CFDictionaryGetValue(props, kSecPolicyOid);
			if (CFEqual(oid, kSecPolicyAppleSSL)) {
				bool client = CFDictionaryGetValue(props, kSecPolicyClient) == kCFBooleanTrue;
				X509_VERIFY_PARAM_set_purpose(p, client ? X509_PURPOSE_SSL_CLIENT : X509_PURPOSE_SSL_SERVER);
				CFStringRef host = CFDictionaryGetValue(props, kSecPolicyName);
				char name[1024];
				if (host && CFStringGetCString(host, name, sizeof(name), kCFStringEncodingUTF8)) {
					ASN1_OCTET_STRING *ip = a2i_IPADDRESS(name);
					if (ip) {
						X509_VERIFY_PARAM_set1_ip_asc(p, name);
						ASN1_OCTET_STRING_free(ip);
					} else
						X509_VERIFY_PARAM_set1_host(p, name, 0);
				}
			} else if (CFEqual(oid, kSecPolicyAppleSMIME))
				X509_VERIFY_PARAM_set_purpose(p, X509_PURPOSE_SMIME_SIGN);
			else if (!CFEqual(oid, kSecPolicyAppleX509Basic) && !CFEqual(oid, kSecPolicyAppleRevocation) &&
			    !CFEqual(oid, kSecPolicyAppleCodeSigning)) {
				ok = 0;
				err = X509_V_ERR_UNSPECIFIED;
			}
		}
		if (ok) {
			ok = X509_verify_cert(c) == 1;
			err = X509_STORE_CTX_get_error(c);
		}
		STACK_OF(X509) *built = X509_STORE_CTX_get1_chain(c);
		setChain(t, built);
		OSSL_STACK_OF_X509_free(built);
	}
	t->status = ok ? 0 : trustStatus(err == X509_V_OK ? X509_V_ERR_UNSPECIFIED : err);
	t->result = ok ? (implicitAnchorUsed ? kSecTrustResultProceed : kSecTrustResultUnspecified)
	    : kSecTrustResultRecoverableTrustFailure;
	if (!ok && t->hasException && t->exceptions &&
	    CFDataGetLength(t->exceptions) == 40 &&
	    t->exceptionStatus == t->status) {
		UInt8 digest[EVP_MAX_MD_SIZE];
		unsigned int length = 0;
		X509 *leaf = ((Certificate *)CFArrayGetValueAtIndex(t->certs, 0))->cert;
		if (X509_digest(leaf, EVP_sha256(), digest, &length) == 1 && length == 32 &&
		    memcmp(CFDataGetBytePtr(t->exceptions), "FNEX", 4) == 0 &&
		    memcmp(CFDataGetBytePtr(t->exceptions) + 4, digest, 32) == 0) {
			ok = 1;
			t->status = errSecSuccess;
			t->result = kSecTrustResultProceed;
		}
	}
	sk_X509_free(chain);
	X509_STORE_CTX_free(c);
	X509_STORE_free(s);
	return ok;
}
bool SecTrustEvaluateWithError(SecTrustRef ref, CFErrorRef *e)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return _SecSetError(e, errSecParam, NULL);
	Trust *t = (Trust *)ref;
	if (evaluate(t))
		return true;
	CFStringRef msg = _SecCopyErrorString(t->status);
	_SecSetError(e, t->status, msg);
	if (msg)
		CFRelease(msg);
	return false;
}
OSStatus SecTrustEvaluate(SecTrustRef t, SecTrustResultType *out)
{
	if (!valid(t, SecTrustGetTypeID()))
		return errSecParam;
	evaluate((Trust *)t);
	if (out)
		*out = ((Trust *)t)->result;
	return 0;
}
OSStatus SecTrustEvaluateAsyncWithError(SecTrustRef t, dispatch_queue_t queue, SecTrustWithErrorCallback result)
{
	if (!valid(t, SecTrustGetTypeID()) || !queue || !result)
		return errSecParam;
	CFRetain(t);
	dispatch_async(queue, ^{
		CFErrorRef e = NULL;
		bool ok = SecTrustEvaluateWithError(t, &e);
		result(t, ok, e);
		if (e)
			CFRelease(e);
		CFRelease(t);
	});
	return 0;
}
OSStatus SecTrustEvaluateAsync(SecTrustRef ref, dispatch_queue_t queue, SecTrustCallback callback)
{
	if (!valid(ref, SecTrustGetTypeID()) || !callback)
		return errSecParam;
	SecTrustRef trust = (SecTrustRef)CFRetain(ref);
	dispatch_queue_t target = queue ? queue : dispatch_get_main_queue();
	dispatch_async(target, ^{
		SecTrustResultType result = kSecTrustResultInvalid;
		SecTrustEvaluate(trust, &result);
		callback(trust, result);
		CFRelease(trust);
	});
	return errSecSuccess;
}
OSStatus SecTrustGetTrustResult(SecTrustRef t, SecTrustResultType *out)
{
	if (!out || !valid(t, SecTrustGetTypeID()))
		return errSecParam;
	*out = ((Trust *)t)->result;
	return 0;
}
OSStatus SecTrustGetResult(SecTrustRef ref, SecTrustResultType *result,
	CFArrayRef *certificates, CSSM_TP_APPLE_EVIDENCE_INFO **statusChain)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return errSecParam;
	Trust *trust = (Trust *)ref;
	if (trust->result == kSecTrustResultInvalid)
		return errSecTrustNotAvailable;
	if (result)
		*result = (SecTrustResultType)trust->result;
	if (certificates)
		*certificates = CFArrayCreateCopy(NULL, currentChain(trust));
	/* The unified trust implementation has no CSSM evidence records. */
	if (statusChain)
		*statusChain = NULL;
	return errSecSuccess;
}
CFDataRef SecTrustCopyExceptions(SecTrustRef ref)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return NULL;
	Trust *trust = (Trust *)ref;
	if (trust->result == kSecTrustResultInvalid || trust->status == errSecSuccess)
		return NULL;
	UInt8 bytes[40] = {'F', 'N', 'E', 'X'};
	unsigned int length = 0;
	X509 *leaf = ((Certificate *)CFArrayGetValueAtIndex(trust->certs, 0))->cert;
	if (X509_digest(leaf, EVP_sha256(), bytes + 4, &length) != 1 || length != 32)
		return NULL;
	memcpy(bytes + 36, &trust->status, sizeof(trust->status));
	return CFDataCreate(NULL, bytes, sizeof(bytes));
}
bool SecTrustSetExceptions(SecTrustRef ref, CFDataRef exceptions)
{
	if (!valid(ref, SecTrustGetTypeID()) ||
	    (exceptions && !valid(exceptions, CFDataGetTypeID())))
		return false;
	Trust *trust = (Trust *)ref;
	trust->result = kSecTrustResultInvalid;
	if (trust->exceptions) {
		CFRelease(trust->exceptions);
		trust->exceptions = NULL;
	}
	trust->hasException = false;
	if (!exceptions) {
		return true;
	}
	if (CFDataGetLength(exceptions) != 40 ||
	    memcmp(CFDataGetBytePtr(exceptions), "FNEX", 4) != 0)
		return false;
	UInt8 digest[EVP_MAX_MD_SIZE];
	unsigned int length = 0;
	X509 *leaf = ((Certificate *)CFArrayGetValueAtIndex(trust->certs, 0))->cert;
	if (X509_digest(leaf, EVP_sha256(), digest, &length) != 1 || length != 32 ||
	    memcmp(CFDataGetBytePtr(exceptions) + 4, digest, 32) != 0)
		return false;
	memcpy(&trust->exceptionStatus, CFDataGetBytePtr(exceptions) + 36,
	    sizeof(trust->exceptionStatus));
	trust->exceptions = CFDataCreateCopy(NULL, exceptions);
	trust->hasException = trust->exceptions != NULL;
	trust->result = kSecTrustResultInvalid;
	return trust->hasException;
}
static CFArrayRef currentChain(Trust *t)
{
	return t->chain ? t->chain : t->certs;
}
CFIndex SecTrustGetCertificateCount(SecTrustRef t)
{
	return valid(t, SecTrustGetTypeID()) ? CFArrayGetCount(currentChain((Trust *)t)) : 0;
}
SecCertificateRef SecTrustGetCertificateAtIndex(SecTrustRef t, CFIndex i)
{
	return valid(t, SecTrustGetTypeID()) && i >= 0 && i < SecTrustGetCertificateCount(t)
	    ? (SecCertificateRef)CFArrayGetValueAtIndex(currentChain((Trust *)t), i)
	    : NULL;
}
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef t)
{
	if (!valid(t, SecTrustGetTypeID()))
		return NULL;
	if (!((Trust *)t)->chain)
		evaluate((Trust *)t);
	return CFArrayCreateCopy(NULL, currentChain((Trust *)t));
}
CFDictionaryRef SecTrustCopyResult(SecTrustRef t)
{
	if (!valid(t, SecTrustGetTypeID()))
		return NULL;
	CFIndex r = ((Trust *)t)->result;
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberCFIndexType, &r);
	CFDictionaryRef d = CFDictionaryCreate(NULL, (const void *[]){kSecTrustResultValue}, (const void *[]){n}, 1,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(n);
	return d;
}
static CFStringRef copyTrustPropertyError(Trust *t)
{
	switch (t->status) {
	case errSecNotTrusted:
	case errSecCreateChainFailed:
		return CFRetain(CFSTR("CSSMERR_TP_NOT_TRUSTED"));
	case errSecCertificateExpired:
		return CFRetain(CFSTR("CSSMERR_TP_CERT_EXPIRED"));
	case errSecHostNameMismatch:
		return CFRetain(CFSTR("Host name mismatch"));
	default: {
		CFStringRef message = _SecCopyErrorString(t->status);
		return message ? message : CFStringCreateWithFormat(NULL, NULL, CFSTR("OSStatus %d"), (int)t->status);
	}
	}
}
CFArrayRef SecTrustCopyProperties(SecTrustRef ref)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return NULL;
	Trust *t = (Trust *)ref;
	CFMutableArrayRef properties = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (t->result == kSecTrustResultInvalid)
		evaluate(t);
	CFArrayRef chain = currentChain(t);
	for (CFIndex i = 0; i < CFArrayGetCount(chain); i++) {
		SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, i);
		CFMutableDictionaryRef item = CFDictionaryCreateMutable(
		    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFStringRef title = SecCertificateCopySubjectSummary(cert);
		if (title) {
			CFDictionarySetValue(item, kSecPropertyTypeTitle, title);
			CFRelease(title);
		}
		if (i == 0) {
			CFStringRef error = copyTrustPropertyError(t);
			if (error) {
				CFDictionarySetValue(item, kSecPropertyTypeError, error);
				CFRelease(error);
			}
		}
		CFArrayAppendValue(properties, item);
		CFRelease(item);
	}
	return properties;
}
/* Serialized trust: a binary property list of the certificates, anchors,
 * policy properties and verify date. Finch's own format (Apple's is a DER
 * plist from securityd's encoding); round trips within Finch. */
CFDataRef SecTrustSerialize(SecTrustRef ref, CFErrorRef *error)
{
	if (!valid(ref, SecTrustGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	Trust *t = (Trust *)ref;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFArrayRef lists[] = {t->certs, t->anchors};
	CFStringRef names[] = {CFSTR("certificates"), CFSTR("anchors")};
	for (int i = 0; i < 2; i++) {
		if (!lists[i])
			continue;
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		for (CFIndex j = 0; j < CFArrayGetCount(lists[i]); j++) {
			CFDataRef der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(lists[i], j));
			CFArrayAppendValue(a, der);
			CFRelease(der);
		}
		CFDictionarySetValue(d, names[i], a);
		CFRelease(a);
	}
	CFMutableArrayRef pols = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex j = 0; j < CFArrayGetCount(t->policies); j++)
		CFArrayAppendValue(pols, ((Policy *)CFArrayGetValueAtIndex(t->policies, j))->properties);
	CFDictionarySetValue(d, CFSTR("policies"), pols);
	CFDictionarySetValue(d, CFSTR("anchorsOnly"), t->anchorsOnly ? kCFBooleanTrue : kCFBooleanFalse);
	CFRelease(pols);
	if (t->date)
		CFDictionarySetValue(d, CFSTR("date"), t->date);
	CFDataRef out = CFPropertyListCreateData(NULL, d, kCFPropertyListBinaryFormat_v1_0, 0, error);
	CFRelease(d);
	return out;
}
SecTrustRef SecTrustDeserialize(CFDataRef data, CFErrorRef *error)
{
	CFPropertyListRef d = valid(data, CFDataGetTypeID())
	    ? CFPropertyListCreateWithData(NULL, data, 0, NULL, NULL)
	    : NULL;
	SecTrustRef trust = NULL;
	if (d && CFGetTypeID(d) == CFDictionaryGetTypeID()) {
		CFArrayRef certData = CFDictionaryGetValue(d, CFSTR("certificates"));
		CFArrayRef anchorData = CFDictionaryGetValue(d, CFSTR("anchors"));
		CFArrayRef polProps = CFDictionaryGetValue(d, CFSTR("policies"));
		CFMutableArrayRef certs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFMutableArrayRef anchors = anchorData ? CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks) : NULL;
		CFMutableArrayRef pols = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		bool ok = valid(certData, CFArrayGetTypeID()) && valid(polProps, CFArrayGetTypeID());
		for (int pass = 0; ok && pass < 2; pass++) {
			CFArrayRef src = pass ? anchorData : certData;
			CFMutableArrayRef dst = pass ? anchors : certs;
			for (CFIndex i = 0; ok && src && i < CFArrayGetCount(src); i++) {
				SecCertificateRef c = SecCertificateCreateWithData(NULL, CFArrayGetValueAtIndex(src, i));
				ok = c != NULL;
				if (c) {
					CFArrayAppendValue(dst, c);
					CFRelease(c);
				}
			}
		}
		for (CFIndex i = 0; ok && i < CFArrayGetCount(polProps); i++) {
			CFDictionaryRef props = CFArrayGetValueAtIndex(polProps, i);
			ok = valid(props, CFDictionaryGetTypeID()) && CFDictionaryGetValue(props, kSecPolicyOid);
			if (ok) {
				SecPolicyRef p = SecPolicyCreateWithProperties(CFDictionaryGetValue(props, kSecPolicyOid), props);
				CFArrayAppendValue(pols, p);
				CFRelease(p);
			}
		}
		if (ok && SecTrustCreateWithCertificates(certs, pols, &trust) == 0) {
			if (anchors)
				SecTrustSetAnchorCertificates(trust, anchors);
			CFTypeRef only = CFDictionaryGetValue(d, CFSTR("anchorsOnly"));
			if (valid(only, CFBooleanGetTypeID()))
				SecTrustSetAnchorCertificatesOnly(trust, CFBooleanGetValue(only));
			CFDateRef date = CFDictionaryGetValue(d, CFSTR("date"));
			if (valid(date, CFDateGetTypeID()))
				SecTrustSetVerifyDate(trust, date);
		}
		CFRelease(certs);
		CFRelease(pols);
		if (anchors)
			CFRelease(anchors);
	}
	if (d)
		CFRelease(d);
	if (!trust)
		_SecSetError(error, errSecDecode, NULL);
	return trust;
}
SecKeyRef SecTrustCopyKey(SecTrustRef t)
{
	Key *key = (Key *)SecCertificateCopyKey(SecTrustGetCertificateAtIndex(t, 0));
	if (key)
		key->attributeSource = KeyAttributesTrust;
	return (SecKeyRef)key;
}
SecKeyRef SecTrustCopyPublicKey(SecTrustRef t)
{
	return SecTrustCopyKey(t);
}
OSStatus SecTrustSetPolicies(SecTrustRef ref, CFTypeRef policies)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return errSecParam;
	CFArrayRef p = asArray(policies, SecPolicyGetTypeID());
	if (!p)
		return errSecParam;
	Trust *t = (Trust *)ref;
	CFRelease(t->policies);
	t->policies = p;
	t->result = kSecTrustResultInvalid;
	return 0;
}
OSStatus SecTrustCopyPolicies(SecTrustRef ref, CFArrayRef *out)
{
	if (!valid(ref, SecTrustGetTypeID()) || !out)
		return errSecParam;
	*out = CFArrayCreateCopy(NULL, ((Trust *)ref)->policies);
	return 0;
}
OSStatus SecTrustCopyCustomAnchorCertificates(SecTrustRef ref, CFArrayRef *out)
{
	if (!valid(ref, SecTrustGetTypeID()) || !out)
		return errSecParam;
	*out = ((Trust *)ref)->anchors ? CFArrayCreateCopy(NULL, ((Trust *)ref)->anchors) : NULL;
	return 0;
}
CFAbsoluteTime SecTrustGetVerifyTime(SecTrustRef ref)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return 0;
	return ((Trust *)ref)->date ? CFDateGetAbsoluteTime(((Trust *)ref)->date)
	                            : CFAbsoluteTimeGetCurrent();
}
/* SecCertificateCopyValues: the property dictionaries Apple's returns, keyed
 * by OID, each {type, label, value}. Sections hold arrays of properties. */
static CFDictionaryRef property(CFStringRef type, CFStringRef label, CFTypeRef value)
{
	const void *keys[] = {kSecPropertyKeyType, kSecPropertyKeyLabel, CFSTR("localized label"), kSecPropertyKeyValue};
	const void *values[] = {type, label, label, value};
	return CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
}
static void addProperty(CFMutableArrayRef a, CFStringRef type, CFStringRef label, CFTypeRef value)
{
	if (!value)
		return;
	CFDictionaryRef d = property(type, label, value);
	CFArrayAppendValue(a, d);
	CFRelease(d);
}
static CFStringRef copyOIDString(const ASN1_OBJECT *o)
{
	char buf[128];
	OBJ_obj2txt(buf, sizeof(buf), o, 1);
	return CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
}
static CFArrayRef copyNameProperties(X509_NAME *n)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < X509_NAME_entry_count(n); i++) {
		X509_NAME_ENTRY *e = X509_NAME_get_entry(n, i);
		CFStringRef label = copyOIDString(X509_NAME_ENTRY_get_object(e));
		CFStringRef value = copyASN1String(X509_NAME_ENTRY_get_data(e));
		addProperty(a, kSecPropertyTypeString, label, value);
		CFRelease(label);
		if (value)
			CFRelease(value);
	}
	return a;
}
static void setValue(CFMutableDictionaryRef d, CFArrayRef wanted, CFStringRef oid, CFStringRef type,
    CFStringRef label, CFTypeRef value)
{
	if (!value || (wanted && !CFArrayContainsValue(wanted, CFRangeMake(0, CFArrayGetCount(wanted)), oid)))
		return;
	CFDictionaryRef p = property(type, label, value);
	CFDictionarySetValue(d, oid, p);
	CFRelease(p);
}
CFDictionaryRef SecCertificateCopyValues(SecCertificateRef ref, CFArrayRef oids, CFErrorRef *error)
{
	if (!valid(ref, SecCertificateGetTypeID()) || (oids && !valid(oids, CFArrayGetTypeID()))) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	X509 *x = ((Certificate *)ref)->cert;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef version = CFStringCreateWithFormat(NULL, NULL, CFSTR("%ld"), X509_get_version(x) + 1);
	setValue(d, oids, kSecOIDX509V1Version, kSecPropertyTypeString, CFSTR("Version"), version);
	CFRelease(version);
	const ASN1_INTEGER *serial = X509_get0_serialNumber(x);
	BIGNUM *serial_number = ASN1_INTEGER_to_BN(serial, NULL);
	char *serial_text = serial_number ? BN_bn2dec(serial_number) : NULL;
	CFStringRef sn = serial_text ? CFStringCreateWithCString(NULL, serial_text, kCFStringEncodingUTF8) : NULL;
	setValue(d, oids, kSecOIDX509V1SerialNumber, kSecPropertyTypeString, CFSTR("Serial Number"), sn);
	if (sn)
		CFRelease(sn);
	OPENSSL_free(serial_text);
	BN_free(serial_number);
	CFArrayRef subject = copyNameProperties(X509_get_subject_name(x));
	setValue(d, oids, kSecOIDX509V1SubjectName, kSecPropertyTypeSection, CFSTR("Subject Name"), subject);
	CFRelease(subject);
	CFArrayRef issuer = copyNameProperties(X509_get_issuer_name(x));
	setValue(d, oids, kSecOIDX509V1IssuerName, kSecPropertyTypeSection, CFSTR("Issuer Name"), issuer);
	CFRelease(issuer);
	CFAbsoluteTime nb = asn1Time(X509_get0_notBefore(x)), na = asn1Time(X509_get0_notAfter(x));
	CFNumberRef nbn = CFNumberCreate(NULL, kCFNumberDoubleType, &nb);
	CFNumberRef nan = CFNumberCreate(NULL, kCFNumberDoubleType, &na);
	setValue(d, oids, kSecOIDX509V1ValidityNotBefore, kSecPropertyTypeNumber, CFSTR("Not Valid Before"), nbn);
	setValue(d, oids, kSecOIDX509V1ValidityNotAfter, kSecPropertyTypeNumber, CFSTR("Not Valid After"), nan);
	CFRelease(nbn);
	CFRelease(nan);
	const X509_ALGOR *alg = NULL;
	X509_get0_signature(NULL, &alg, x);
	if (alg) {
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		const ASN1_OBJECT *obj = NULL;
		int parameter_type = V_ASN1_UNDEF;
		X509_ALGOR_get0(&obj, &parameter_type, NULL, alg);
		CFStringRef o = copyOIDString(obj);
		addProperty(a, kSecPropertyTypeString, CFSTR("Algorithm"), o);
		CFRelease(o);
		if (parameter_type == V_ASN1_NULL)
			addProperty(a, kSecPropertyTypeString, CFSTR("Parameters"), CFSTR("none"));
		setValue(d, oids, kSecOIDX509V1SignatureAlgorithm, kSecPropertyTypeSection,
		    CFSTR("Signature Algorithm"), a);
		CFRelease(a);
	}
	/* Extensions: each a section of its printed form. */
	for (int i = 0; i < X509_get_ext_count(x); i++) {
		X509_EXTENSION *ext = X509_get_ext(x, i);
		CFStringRef oid = copyOIDString(X509_EXTENSION_get_object(ext));
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		addProperty(a, kSecPropertyTypeString, CFSTR("Critical"),
		    X509_EXTENSION_get_critical(ext) ? CFSTR("Yes") : CFSTR("No"));
		BIO *bio = BIO_new(BIO_s_mem());
		if (bio && X509V3_EXT_print(bio, ext, 0, 0) > 0) {
			char *text = NULL;
			long len = BIO_get_mem_data(bio, &text);
			CFStringRef v = CFStringCreateWithBytes(NULL, (const UInt8 *)text, len, kCFStringEncodingUTF8, false);
			addProperty(a, kSecPropertyTypeString, CFSTR("Value"), v);
			if (v)
				CFRelease(v);
		}
		BIO_free(bio);
		setValue(d, oids, oid, kSecPropertyTypeSection, oid, a);
		CFRelease(a);
		CFRelease(oid);
	}
	return d;
}
CFDataRef SecKeyCopyKeyExchangeResult(SecKeyRef ref, SecKeyAlgorithm alg, SecKeyRef other,
    CFDictionaryRef parameters, CFErrorRef *error)
{
	if (!SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeKeyExchange, alg) ||
	    !valid(other, SecKeyGetTypeID()) || ((Key *)other)->private ||
	    (parameters && !valid(parameters, CFDictionaryGetTypeID()))) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	size_t n = 0;
	int ok = c && EVP_PKEY_derive_init(c) > 0 &&
	    EVP_PKEY_derive_set_peer(c, ((Key *)other)->key) > 0 &&
	    EVP_PKEY_derive(c, NULL, &n) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(n) : NULL;
	ok = out && EVP_PKEY_derive(c, out, &n) > 0;
	CFDataRef result = ok ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_clear_free(out, n);
	EVP_PKEY_CTX_free(c);
	if (!result)
		_SecSetError(error, errSecParam, NULL);
	return result;
}

/* (Secure Transport's: the OpenSSL objects behind a certificate and a key) */
SEC_HIDDEN X509 *_SecCertificateGetX509(SecCertificateRef c) { return ((Certificate *)c)->cert; }
SEC_HIDDEN EVP_PKEY *_SecKeyGetEVP(SecKeyRef k) { return ((Key *)k)->key; }

/* PKCS #12 (a .p12 or .pfx): its identity, the certificates with it, and a trust for
   them, as Apple's returns them. They're returned in memory, not added to a keychain. */
#include <openssl/pkcs12.h>

static SecCertificateRef
certificate_of(X509 *x)
{
	unsigned char *der = NULL;
	int len = i2d_X509(x, &der);
	CFDataRef d = len > 0 ? CFDataCreate(NULL, der, len) : NULL;
	OPENSSL_free(der);
	SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, d) : NULL;
	if (d)
		CFRelease(d);
	return c;
}

SEC_API OSStatus SecPKCS12Import(CFDataRef pkcs12_data, CFDictionaryRef options, CFArrayRef *items)
{
	if (!pkcs12_data || !items)
		return errSecParam;
	*items = NULL;
	CFStringRef pass = options ? CFDictionaryGetValue(options, kSecImportExportPassphrase) : NULL;
	char password[1024] = "";
	if (pass && !CFStringGetCString(pass, password, sizeof password, kCFStringEncodingUTF8))
		return errSecParam;
	const unsigned char *p = CFDataGetBytePtr(pkcs12_data);
	PKCS12 *p12 = d2i_PKCS12(NULL, &p, CFDataGetLength(pkcs12_data));
	if (!p12)
		return errSecDecode;
	if (PKCS12_mac_present(p12) && !PKCS12_verify_mac(p12, password, -1)) {
		PKCS12_free(p12);
		return pass ? errSecAuthFailed : errSecPassphraseRequired;
	}
	EVP_PKEY *pkey = NULL;
	X509 *x = NULL;
	STACK_OF(X509) *ca = NULL;
	int ok = PKCS12_parse(p12, password, &pkey, &x, &ca);
	PKCS12_free(p12);
	if (!ok)
		return errSecDecode;
	CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFMutableArrayRef chain = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	SecCertificateRef cert = x ? certificate_of(x) : NULL;
	if (cert)
		CFArrayAppendValue(chain, cert);
	for (int i = 0; ca && i < sk_X509_num(ca); i++) {
		SecCertificateRef c = certificate_of(sk_X509_value(ca, i));
		if (c) {
			CFArrayAppendValue(chain, c);
			CFRelease(c);
		}
	}
	if (cert && pkey) {
		SecKeyRef key = wrapKey(pkey, true);
		pkey = NULL;
		SecIdentityRef identity = key ? _SecIdentityCreate(cert, key) : NULL;
		if (identity) {
			CFDictionarySetValue(item, kSecImportItemIdentity, identity);
			CFRelease(identity);
		}
		if (key)
			CFRelease(key);
	}
	if (CFArrayGetCount(chain)) {
		CFDictionarySetValue(item, kSecImportItemCertChain, chain);
		SecPolicyRef policy = SecPolicyCreateBasicX509();
		SecTrustRef trust = NULL;
		if (SecTrustCreateWithCertificates(chain, policy, &trust) == errSecSuccess && trust) {
			CFDictionarySetValue(item, kSecImportItemTrust, trust);
			CFRelease(trust);
		}
		if (policy)
			CFRelease(policy);
	}
	if (x) {
		int len = 0;
		unsigned char *alias = X509_alias_get0(x, &len);
		CFStringRef label = alias ? CFStringCreateWithBytes(NULL, alias, len, kCFStringEncodingUTF8, false)
		                          : (cert ? SecCertificateCopySubjectSummary(cert) : NULL);
		if (label) {
			CFDictionarySetValue(item, kSecImportItemLabel, label);
			CFRelease(label);
		}
		unsigned char *keyid = X509_keyid_get0(x, &len);
		CFDataRef kid = keyid ? CFDataCreate(NULL, keyid, len) : (cert ? _SecCertificateCopyPublicKeySHA1(cert) : NULL);
		if (kid) {
			CFDictionarySetValue(item, kSecImportItemKeyID, kid);
			CFRelease(kid);
		}
	}
	if (cert)
		CFRelease(cert);
	CFRelease(chain);
	EVP_PKEY_free(pkey);
	X509_free(x);
	sk_X509_pop_free(ca, X509_free);
	*items = CFArrayCreate(NULL, (const void **)&item, 1, &kCFTypeArrayCallBacks);
	CFRelease(item);
	return errSecSuccess;
}

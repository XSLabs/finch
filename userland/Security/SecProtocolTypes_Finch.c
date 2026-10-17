/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Core Foundation backed versions of Security's protocol object wrappers. */
#include "SecInternal.h"

#include <Security/SecProtocolTypes.h>
#include <Security/SecProtocolMetadata.h>
#include <dispatch/dispatch.h>
#include <os/object.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	CFRuntimeBase base;
	SecCertificateRef certificate;
} ProtocolCertificate;

typedef struct {
	CFRuntimeBase base;
	SecIdentityRef identity;
	CFArrayRef certificates;
} ProtocolIdentity;

typedef struct {
	CFRuntimeBase base;
	SecTrustRef trust;
} ProtocolTrust;

typedef struct {
	CFRuntimeBase base;
	tls_protocol_version_t version;
	tls_ciphersuite_t ciphersuite;
	char *negotiatedProtocol;
	char *serverName;
	CFArrayRef peerCertificates;
} ProtocolMetadata;

typedef struct ProtocolObjectNode {
	const void *object;
	CFTypeID type;
	struct ProtocolObjectNode *next;
} ProtocolObjectNode;

static pthread_mutex_t protocolObjectsLock = PTHREAD_MUTEX_INITIALIZER;
static ProtocolObjectNode *protocolObjects;

static bool registerProtocolObject(const void *object, CFTypeID type)
{
	ProtocolObjectNode *node = malloc(sizeof(*node));
	if (!node)
		return false;
	*node = (ProtocolObjectNode){.object = object, .type = type};
	pthread_mutex_lock(&protocolObjectsLock);
	node->next = protocolObjects;
	protocolObjects = node;
	pthread_mutex_unlock(&protocolObjectsLock);
	return true;
}

static void unregisterProtocolObject(const void *object)
{
	pthread_mutex_lock(&protocolObjectsLock);
	ProtocolObjectNode **cursor = &protocolObjects;
	while (*cursor) {
		if ((*cursor)->object == object) {
			ProtocolObjectNode *node = *cursor;
			*cursor = node->next;
			free(node);
			break;
		}
		cursor = &(*cursor)->next;
	}
	pthread_mutex_unlock(&protocolObjectsLock);
}

static bool isProtocolObject(const void *object)
{
	bool found = false;
	pthread_mutex_lock(&protocolObjectsLock);
	for (ProtocolObjectNode *node = protocolObjects; node; node = node->next) {
		if (node->object == object) {
			found = true;
			break;
		}
	}
	pthread_mutex_unlock(&protocolObjectsLock);
	return found;
}

static bool isProtocolObjectOfType(const void *object, CFTypeID type)
{
	bool found = false;
	pthread_mutex_lock(&protocolObjectsLock);
	for (ProtocolObjectNode *node = protocolObjects; node; node = node->next) {
		if (node->object == object && node->type == type) {
			found = true;
			break;
		}
	}
	pthread_mutex_unlock(&protocolObjectsLock);
	return found;
}

void *sec_retain(void *object)
{
	if (!object)
		return NULL;
	return isProtocolObject(object) ? (void *)CFRetain(object) : os_retain(object);
}

void sec_release(void *object)
{
	if (!object)
		return;
	if (isProtocolObject(object))
		CFRelease(object);
	else
		os_release(object);
}

static void certificateFinalize(CFTypeRef object)
{
	ProtocolCertificate *wrapper = (ProtocolCertificate *)object;
	unregisterProtocolObject(object);
	if (wrapper->certificate)
		CFRelease(wrapper->certificate);
}

static void identityFinalize(CFTypeRef object)
{
	ProtocolIdentity *wrapper = (ProtocolIdentity *)object;
	unregisterProtocolObject(object);
	if (wrapper->identity)
		CFRelease(wrapper->identity);
	if (wrapper->certificates)
		CFRelease(wrapper->certificates);
}

static void trustFinalize(CFTypeRef object)
{
	ProtocolTrust *wrapper = (ProtocolTrust *)object;
	unregisterProtocolObject(object);
	if (wrapper->trust)
		CFRelease(wrapper->trust);
}

static CFTypeID certificateTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "sec_certificate", NULL, NULL, certificateFinalize, NULL, NULL, NULL, NULL};
	return _SecRegisterClass(&id, &cls);
}

static CFTypeID identityTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "sec_identity", NULL, NULL, identityFinalize, NULL, NULL, NULL, NULL};
	return _SecRegisterClass(&id, &cls);
}

static CFTypeID trustTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "sec_trust", NULL, NULL, trustFinalize, NULL, NULL, NULL, NULL};
	return _SecRegisterClass(&id, &cls);
}

static void metadataFinalize(CFTypeRef object)
{
	ProtocolMetadata *metadata = (ProtocolMetadata *)object;
	unregisterProtocolObject(object);
	free(metadata->negotiatedProtocol);
	free(metadata->serverName);
	if (metadata->peerCertificates)
		CFRelease(metadata->peerCertificates);
}

static CFTypeID metadataTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "sec_protocol_metadata", NULL, NULL, metadataFinalize, NULL, NULL, NULL, NULL};
	return _SecRegisterClass(&id, &cls);
}

static ProtocolMetadata *protocolMetadata(sec_protocol_metadata_t object)
{
	return isProtocolObjectOfType(object, metadataTypeID()) ? (ProtocolMetadata *)object : NULL;
}

sec_protocol_metadata_t _FinchSecProtocolMetadataCreate(void)
{
	ProtocolMetadata *metadata = (ProtocolMetadata *)_SecCreateInstance(metadataTypeID(), sizeof(*metadata));
	if (!metadata)
		return NULL;
	if (!registerProtocolObject(metadata, metadataTypeID())) {
		CFRelease(metadata);
		return NULL;
	}
	return (sec_protocol_metadata_t)metadata;
}

static tls_protocol_version_t protocolType(SSLProtocol protocol)
{
	switch (protocol) {
	case kTLSProtocol1: return tls_protocol_version_TLSv10;
	case kTLSProtocol11: return tls_protocol_version_TLSv11;
	case kTLSProtocol12: return tls_protocol_version_TLSv12;
	case kTLSProtocol13: return tls_protocol_version_TLSv13;
	default: return 0;
	}
}

static SSLProtocol secureTransportType(tls_protocol_version_t version)
{
	switch (version) {
	case tls_protocol_version_TLSv10: return kTLSProtocol1;
	case tls_protocol_version_TLSv11: return kTLSProtocol11;
	case tls_protocol_version_TLSv12: return kTLSProtocol12;
	case tls_protocol_version_TLSv13: return kTLSProtocol13;
	default: return kSSLProtocolUnknown;
	}
}

OSStatus _FinchSecProtocolMetadataPopulate(sec_protocol_metadata_t object, SSLContextRef context,
	const char *serverName)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	if (!metadata || !context)
		return errSecParam;
	SSLProtocol version = kSSLProtocolUnknown;
	if (SSLGetNegotiatedProtocolVersion(context, &version) == noErr)
		metadata->version = protocolType(version);
	SSLCipherSuite ciphersuite = SSL_NULL_WITH_NULL_NULL;
	if (SSLGetNegotiatedCipher(context, &ciphersuite) == noErr)
		metadata->ciphersuite = (tls_ciphersuite_t)ciphersuite;
	CFArrayRef protocols = NULL;
	if (SSLCopyALPNProtocols(context, &protocols) == noErr && protocols && CFArrayGetCount(protocols)) {
		char value[256];
		if (CFStringGetCString((CFStringRef)CFArrayGetValueAtIndex(protocols, 0), value, sizeof(value),
		    kCFStringEncodingUTF8)) {
			char *copy = strdup(value);
			if (copy) {
				free(metadata->negotiatedProtocol);
				metadata->negotiatedProtocol = copy;
			}
		}
	}
	if (protocols)
		CFRelease(protocols);
	CFArrayRef certificates = NULL;
	if (SSLCopyPeerCertificates(context, &certificates) == noErr && certificates) {
		if (metadata->peerCertificates)
			CFRelease(metadata->peerCertificates);
		metadata->peerCertificates = certificates;
	}
	char peerName[1024];
	const char *name = serverName;
	if (!name) {
		size_t length = sizeof(peerName) - 1;
		if (SSLGetPeerDomainName(context, peerName, &length) == noErr && length < sizeof(peerName)) {
			peerName[length] = '\0';
			name = peerName;
		}
	}
	char *nameCopy = name ? strdup(name) : NULL;
	if (name && !nameCopy)
		return errSecAllocate;
	free(metadata->serverName);
	metadata->serverName = nameCopy;
	return noErr;
}

tls_protocol_version_t sec_protocol_metadata_get_negotiated_tls_protocol_version(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? metadata->version : 0;
}

SSLProtocol sec_protocol_metadata_get_negotiated_protocol_version(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? secureTransportType(metadata->version) : kSSLProtocolUnknown;
}

tls_ciphersuite_t sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? metadata->ciphersuite : 0;
}

SSLCipherSuite sec_protocol_metadata_get_negotiated_ciphersuite(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? (SSLCipherSuite)metadata->ciphersuite : SSL_NULL_WITH_NULL_NULL;
}

const char *sec_protocol_metadata_get_negotiated_protocol(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? metadata->negotiatedProtocol : NULL;
}

const char *sec_protocol_metadata_copy_negotiated_protocol(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata && metadata->negotiatedProtocol ? strdup(metadata->negotiatedProtocol) : NULL;
}

bool sec_protocol_metadata_get_early_data_accepted(sec_protocol_metadata_t object)
{
	(void)object;
	return false;
}

bool sec_protocol_metadata_access_peer_certificate_chain(sec_protocol_metadata_t object,
	void (^handler)(sec_certificate_t certificate))
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	if (!metadata || !metadata->peerCertificates || !handler)
		return false;
	for (CFIndex index = 0; index < CFArrayGetCount(metadata->peerCertificates); index++) {
		SecCertificateRef certificate = (SecCertificateRef)CFArrayGetValueAtIndex(metadata->peerCertificates, index);
		sec_certificate_t wrapped = sec_certificate_create(certificate);
		if (!wrapped)
			return false;
		handler(wrapped);
		sec_release(wrapped);
	}
	return true;
}

dispatch_data_t sec_protocol_metadata_copy_peer_public_key(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	if (!metadata || !metadata->peerCertificates || CFArrayGetCount(metadata->peerCertificates) == 0)
		return NULL;
	SecKeyRef key = SecCertificateCopyKey((SecCertificateRef)CFArrayGetValueAtIndex(metadata->peerCertificates, 0));
	if (!key)
		return NULL;
	CFErrorRef error = NULL;
	CFDataRef data = SecKeyCopyExternalRepresentation(key, &error);
	CFRelease(key);
	if (error)
		CFRelease(error);
	if (!data)
		return NULL;
	dispatch_data_t result = dispatch_data_create(CFDataGetBytePtr(data), (size_t)CFDataGetLength(data),
	    dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ CFRelease(data); });
	if (!result)
		CFRelease(data);
	return result;
}

const char *sec_protocol_metadata_get_server_name(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata ? metadata->serverName : NULL;
}

const char *sec_protocol_metadata_copy_server_name(sec_protocol_metadata_t object)
{
	ProtocolMetadata *metadata = protocolMetadata(object);
	return metadata && metadata->serverName ? strdup(metadata->serverName) : NULL;
}

static bool validType(CFTypeRef value, CFTypeID type)
{
	return value && CFGetTypeID(value) == type;
}

sec_certificate_t sec_certificate_create(SecCertificateRef certificate)
{
	if (!validType(certificate, SecCertificateGetTypeID()))
		return NULL;
	ProtocolCertificate *wrapper = (ProtocolCertificate *)_SecCreateInstance(certificateTypeID(), sizeof(*wrapper));
	if (!wrapper)
		return NULL;
	wrapper->certificate = (SecCertificateRef)CFRetain(certificate);
	if (!registerProtocolObject(wrapper, certificateTypeID())) {
		CFRelease(wrapper);
		return NULL;
	}
	return (sec_certificate_t)wrapper;
}

SecCertificateRef sec_certificate_copy_ref(sec_certificate_t object)
{
	ProtocolCertificate *wrapper = (ProtocolCertificate *)object;
	if (!isProtocolObjectOfType(object, certificateTypeID()) || !wrapper->certificate)
		return NULL;
	return (SecCertificateRef)CFRetain(wrapper->certificate);
}

sec_identity_t sec_identity_create(SecIdentityRef identity)
{
	if (!validType(identity, SecIdentityGetTypeID()))
		return NULL;
	ProtocolIdentity *wrapper = (ProtocolIdentity *)_SecCreateInstance(identityTypeID(), sizeof(*wrapper));
	if (!wrapper)
		return NULL;
	wrapper->identity = (SecIdentityRef)CFRetain(identity);
	if (!registerProtocolObject(wrapper, identityTypeID())) {
		CFRelease(wrapper);
		return NULL;
	}
	return (sec_identity_t)wrapper;
}

sec_identity_t sec_identity_create_with_certificates(SecIdentityRef identity, CFArrayRef certificates)
{
	if (!validType(identity, SecIdentityGetTypeID()) || !validType(certificates, CFArrayGetTypeID()))
		return NULL;
	for (CFIndex index = 0; index < CFArrayGetCount(certificates); index++)
		if (!validType(CFArrayGetValueAtIndex(certificates, index), SecCertificateGetTypeID()))
			return NULL;
	ProtocolIdentity *wrapper = (ProtocolIdentity *)_SecCreateInstance(identityTypeID(), sizeof(*wrapper));
	if (!wrapper)
		return NULL;
	wrapper->identity = (SecIdentityRef)CFRetain(identity);
	wrapper->certificates = CFRetain(certificates);
	if (!registerProtocolObject(wrapper, identityTypeID())) {
		CFRelease(wrapper);
		return NULL;
	}
	return (sec_identity_t)wrapper;
}

bool sec_identity_access_certificates(sec_identity_t object, void (^handler)(sec_certificate_t certificate))
{
	ProtocolIdentity *wrapper = (ProtocolIdentity *)object;
	if (!isProtocolObjectOfType(object, identityTypeID()) || !wrapper->certificates || !handler)
		return false;
	for (CFIndex index = 0; index < CFArrayGetCount(wrapper->certificates); index++) {
		sec_certificate_t certificate = sec_certificate_create((SecCertificateRef)CFArrayGetValueAtIndex(wrapper->certificates, index));
		if (certificate) {
			handler(certificate);
			CFRelease(certificate);
		}
	}
	return true;
}

SecIdentityRef sec_identity_copy_ref(sec_identity_t object)
{
	ProtocolIdentity *wrapper = (ProtocolIdentity *)object;
	if (!isProtocolObjectOfType(object, identityTypeID()) || !wrapper->identity)
		return NULL;
	return (SecIdentityRef)CFRetain(wrapper->identity);
}

CFArrayRef sec_identity_copy_certificates_ref(sec_identity_t object)
{
	ProtocolIdentity *wrapper = (ProtocolIdentity *)object;
	if (!isProtocolObjectOfType(object, identityTypeID()) || !wrapper->certificates)
		return NULL;
	return CFRetain(wrapper->certificates);
}

sec_trust_t sec_trust_create(SecTrustRef trust)
{
	if (!validType(trust, SecTrustGetTypeID()))
		return NULL;
	ProtocolTrust *wrapper = (ProtocolTrust *)_SecCreateInstance(trustTypeID(), sizeof(*wrapper));
	if (!wrapper)
		return NULL;
	wrapper->trust = (SecTrustRef)CFRetain(trust);
	if (!registerProtocolObject(wrapper, trustTypeID())) {
		CFRelease(wrapper);
		return NULL;
	}
	return (sec_trust_t)wrapper;
}

SecTrustRef sec_trust_copy_ref(sec_trust_t object)
{
	ProtocolTrust *wrapper = (ProtocolTrust *)object;
	if (!isProtocolObjectOfType(object, trustTypeID()) || !wrapper->trust)
		return NULL;
	return (SecTrustRef)CFRetain(wrapper->trust);
}

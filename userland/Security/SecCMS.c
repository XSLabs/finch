/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CMS messages use the same OpenSSL objects as Finch's certificates and keys. */
#include "SecInternal.h"
#include <openssl/cms.h>
#include <openssl/evp.h>
#include <openssl/objects.h>
#include <openssl/pkcs12.h>
#include <openssl/x509v3.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct _CMSDecoder {
	CFRuntimeBase base;
	CFMutableDataRef message;
	CFDataRef detached;
	CFTypeRef keychain;
	CFDataRef content;
	CMS_ContentInfo *cms;
	bool finalized;
	bool encrypted;
};

struct _CMSEncoder {
	CFRuntimeBase base;
	CFMutableArrayRef signers;
	CFMutableArrayRef recipients;
	CFMutableArrayRef supportingCerts;
	CFMutableDataRef content;
	CFDataRef contentType;
	CFDataRef encoded;
	CFStringRef digest;
	CMSSignedAttributes attributes;
	CMSCertificateChainMode chainMode;
	bool detached;
	bool contentStarted;
};

static bool isType(CFTypeRef value, CFTypeID type)
{
	return value && CFGetTypeID(value) == type;
}

static void decoderFree(CFTypeRef value)
{
	struct _CMSDecoder *decoder = (struct _CMSDecoder *)value;
	if (decoder->message)
		CFRelease(decoder->message);
	if (decoder->detached)
		CFRelease(decoder->detached);
	if (decoder->keychain)
		CFRelease(decoder->keychain);
	if (decoder->content)
		CFRelease(decoder->content);
	CMS_ContentInfo_free(decoder->cms);
}

static void encoderFree(CFTypeRef value)
{
	struct _CMSEncoder *encoder = (struct _CMSEncoder *)value;
	if (encoder->signers)
		CFRelease(encoder->signers);
	if (encoder->recipients)
		CFRelease(encoder->recipients);
	if (encoder->supportingCerts)
		CFRelease(encoder->supportingCerts);
	if (encoder->content)
		CFRelease(encoder->content);
	if (encoder->contentType)
		CFRelease(encoder->contentType);
	if (encoder->encoded)
		CFRelease(encoder->encoded);
	if (encoder->digest)
		CFRelease(encoder->digest);
}

SEC_DEFINE_TYPE(CMSDecoderGetTypeID, "CMSDecoder", decoderFree, NULL, NULL)
SEC_DEFINE_TYPE(CMSEncoderGetTypeID, "CMSEncoder", encoderFree, NULL, NULL)

static bool mutableDecoder(CMSDecoderRef decoder)
{
	return isType(decoder, CMSDecoderGetTypeID()) && !decoder->finalized;
}

static bool readyDecoder(CMSDecoderRef decoder)
{
	return isType(decoder, CMSDecoderGetTypeID()) && decoder->finalized && decoder->cms;
}

static bool mutableEncoder(CMSEncoderRef encoder)
{
	return isType(encoder, CMSEncoderGetTypeID()) && !encoder->contentStarted && !encoder->encoded;
}

static OSStatus appendObjects(CFMutableArrayRef destination, CFTypeRef value, CFTypeID type)
{
	if (!value)
		return errSecParam;
	CFIndex count = isType(value, CFArrayGetTypeID()) ? CFArrayGetCount((CFArrayRef)value) : 1;
	for (CFIndex i = 0; i < count; i++) {
		CFTypeRef item = isType(value, CFArrayGetTypeID())
		    ? CFArrayGetValueAtIndex((CFArrayRef)value, i)
		    : value;
		if (!isType(item, type))
			return errSecParam;
	}
	for (CFIndex i = 0; i < count; i++) {
		CFTypeRef item = isType(value, CFArrayGetTypeID())
		    ? CFArrayGetValueAtIndex((CFArrayRef)value, i)
		    : value;
		CFArrayAppendValue(destination, item);
	}
	return errSecSuccess;
}

static CFArrayRef copyArray(CFArrayRef array)
{
	return array && CFArrayGetCount(array)
	    ? CFArrayCreateCopy(NULL, array)
	    : NULL;
}

static BIO *bioForData(const void *bytes, size_t length)
{
	if (length > INT_MAX || (length && !bytes))
		return NULL;
	BIO *bio = BIO_new(BIO_s_mem());
	if (bio && length && BIO_write(bio, bytes, (int)length) != (int)length) {
		BIO_free(bio);
		return NULL;
	}
	return bio;
}

static X509 *copyX509(SecCertificateRef certificate)
{
	CFDataRef data = SecCertificateCopyData(certificate);
	if (!data)
		return NULL;
	const unsigned char *bytes = CFDataGetBytePtr(data);
	const unsigned char *end = bytes + CFDataGetLength(data);
	X509 *result = d2i_X509(NULL, &bytes, CFDataGetLength(data));
	if (!result || bytes != end) {
		X509_free(result);
		result = NULL;
	}
	CFRelease(data);
	return result;
}

static EVP_PKEY *copyPrivateKey(SecKeyRef key)
{
	CFDataRef data = _SecKeyCopyPrivateKeyInfo(key);
	if (!data)
		return NULL;
	const unsigned char *bytes = CFDataGetBytePtr(data);
	const unsigned char *end = bytes + CFDataGetLength(data);
	PKCS8_PRIV_KEY_INFO *info = d2i_PKCS8_PRIV_KEY_INFO(NULL, &bytes, CFDataGetLength(data));
	EVP_PKEY *result = info && bytes == end ? EVP_PKCS82PKEY(info) : NULL;
	PKCS8_PRIV_KEY_INFO_free(info);
	CFRelease(data);
	return result;
}

static SecCertificateRef copySecCertificate(X509 *certificate)
{
	unsigned char *bytes = NULL;
	int length = i2d_X509(certificate, &bytes);
	CFDataRef data = length > 0 ? CFDataCreate(NULL, bytes, length) : NULL;
	SecCertificateRef result = data ? SecCertificateCreateWithData(NULL, data) : NULL;
	OPENSSL_free(bytes);
	if (data)
		CFRelease(data);
	return result;
}

static STACK_OF(X509) *copyRecipientCertificates(CFArrayRef recipients)
{
	STACK_OF(X509) *stack = sk_X509_new_null();
	if (!stack)
		return NULL;
	for (CFIndex i = 0; recipients && i < CFArrayGetCount(recipients); i++) {
		X509 *certificate = copyX509((SecCertificateRef)CFArrayGetValueAtIndex(recipients, i));
		if (!certificate || !sk_X509_push(stack, certificate)) {
			X509_free(certificate);
			sk_X509_pop_free(stack, X509_free);
			return NULL;
		}
	}
	return stack;
}

static bool addSupportingCertificates(CMS_ContentInfo *cms, CFArrayRef certificates)
{
	for (CFIndex i = 0; certificates && i < CFArrayGetCount(certificates); i++) {
		X509 *certificate = copyX509((SecCertificateRef)CFArrayGetValueAtIndex(certificates, i));
		int ok = certificate && CMS_add1_cert(cms, certificate);
		X509_free(certificate);
		if (!ok)
			return false;
	}
	return true;
}

static ASN1_OBJECT *objectFromContents(CFDataRef contents)
{
	if (!isType(contents, CFDataGetTypeID()) || CFDataGetLength(contents) <= 0)
		return NULL;
	return ASN1_OBJECT_create(NID_undef,
	    (unsigned char *)CFDataGetBytePtr(contents), CFDataGetLength(contents), NULL, NULL);
}

static CFDataRef dataForObjectContents(const ASN1_OBJECT *object)
{
	int length = OBJ_length(object);
	const unsigned char *bytes = OBJ_get0_data(object);
	return length > 0 && bytes ? CFDataCreate(NULL, bytes, length) : NULL;
}

static CFDataRef dataForObjectDER(const ASN1_OBJECT *object)
{
	unsigned char *bytes = NULL;
	int length = i2d_ASN1_OBJECT(object, &bytes);
	CFDataRef result = length > 0 ? CFDataCreate(NULL, bytes, length) : NULL;
	OPENSSL_free(bytes);
	return result;
}

static bool oidDataFromString(CFStringRef string, CFDataRef *result)
{
	char oid[256];
	if (!isType(string, CFStringGetTypeID()) ||
	    !CFStringGetCString(string, oid, sizeof(oid), kCFStringEncodingUTF8))
		return false;
	ASN1_OBJECT *object = OBJ_txt2obj(oid, 1);
	CFDataRef contents = object ? dataForObjectContents(object) : NULL;
	ASN1_OBJECT_free(object);
	if (!contents)
		return false;
	*result = contents;
	return true;
}

static CFDataRef copySignedContent(CMS_ContentInfo *cms)
{
	ASN1_OCTET_STRING **content = CMS_get0_content(cms);
	if (!content || !*content)
		return NULL;
	const unsigned char *bytes = ASN1_STRING_get0_data(*content);
	int length = ASN1_STRING_length(*content);
	return length >= 0 ? CFDataCreate(NULL, bytes, length) : NULL;
}

static CFDataRef decryptMessage(CMS_ContentInfo *cms, CFTypeRef keychain)
{
	CFMutableDictionaryRef query = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!query)
		return NULL;
	CFDictionarySetValue(query, kSecClass, kSecClassIdentity);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitAll);
	CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
	if (keychain)
		CFDictionarySetValue(query, kSecMatchSearchList, keychain);
	CFTypeRef identities = NULL;
	OSStatus status = SecItemCopyMatching(query, &identities);
	CFRelease(query);
	if (status || !identities)
		return NULL;

	CFArrayRef list = isType(identities, CFArrayGetTypeID())
	    ? (CFArrayRef)identities
	    : NULL;
	CFIndex count = list ? CFArrayGetCount(list) : 1;
	CFDataRef result = NULL;
	for (CFIndex i = 0; i < count && !result; i++) {
		SecIdentityRef identity = (SecIdentityRef)(list
		    ? CFArrayGetValueAtIndex(list, i)
		    : identities);
		SecCertificateRef certificate = NULL;
		SecKeyRef key = NULL;
		if (SecIdentityCopyCertificate(identity, &certificate) ||
		    SecIdentityCopyPrivateKey(identity, &key)) {
			if (certificate)
				CFRelease(certificate);
			if (key)
				CFRelease(key);
			continue;
		}
		X509 *x509 = copyX509(certificate);
		EVP_PKEY *privateKey = copyPrivateKey(key);
		BIO *output = BIO_new(BIO_s_mem());
		if (x509 && privateKey && output && CMS_decrypt(cms, privateKey, x509, NULL, output, CMS_BINARY)) {
			BUF_MEM *buffer = NULL;
			BIO_get_mem_ptr(output, &buffer);
			if (buffer && buffer->length <= LONG_MAX)
				result = CFDataCreate(NULL, (const UInt8 *)buffer->data, (CFIndex)buffer->length);
		}
		BIO_free(output);
		EVP_PKEY_free(privateKey);
		X509_free(x509);
		CFRelease(key);
		CFRelease(certificate);
	}
	CFRelease(identities);
	return result;
}

SEC_API OSStatus CMSDecoderCreate(CMSDecoderRef *output)
{
	if (!output)
		return errSecParam;
	*output = NULL;
	struct _CMSDecoder *decoder = (struct _CMSDecoder *)_SecCreateInstance(
	    CMSDecoderGetTypeID(), sizeof(*decoder));
	if (!decoder)
		return errSecAllocate;
	decoder->message = CFDataCreateMutable(NULL, 0);
	if (!decoder->message) {
		CFRelease(decoder);
		return errSecAllocate;
	}
	*output = decoder;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderUpdateMessage(CMSDecoderRef decoder, const void *bytes, size_t length)
{
	if (!mutableDecoder(decoder) || (length && !bytes) || length > LONG_MAX)
		return errSecParam;
	if (length)
		CFDataAppendBytes(decoder->message, bytes, (CFIndex)length);
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderSetDetachedContent(CMSDecoderRef decoder, CFDataRef content)
{
	if (!isType(decoder, CMSDecoderGetTypeID()) || !isType(content, CFDataGetTypeID()))
		return errSecParam;
	if (decoder->detached)
		CFRelease(decoder->detached);
	decoder->detached = (CFDataRef)CFRetain(content);
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopyDetachedContent(CMSDecoderRef decoder, CFDataRef *output)
{
	if (!isType(decoder, CMSDecoderGetTypeID()) || !output)
		return errSecParam;
	*output = decoder->detached ? (CFDataRef)CFRetain(decoder->detached) : NULL;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderSetSearchKeychain(CMSDecoderRef decoder, CFTypeRef keychain)
{
	if (!isType(decoder, CMSDecoderGetTypeID()))
		return errSecParam;
	if (decoder->keychain)
		CFRelease(decoder->keychain);
	decoder->keychain = keychain ? CFRetain(keychain) : NULL;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderFinalizeMessage(CMSDecoderRef decoder)
{
	if (!mutableDecoder(decoder))
		return errSecParam;
	const unsigned char *bytes = CFDataGetBytePtr(decoder->message);
	const unsigned char *end = bytes + CFDataGetLength(decoder->message);
	CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &bytes, CFDataGetLength(decoder->message));
	if (!cms || bytes != end) {
		CMS_ContentInfo_free(cms);
		return errSecUnknownFormat;
	}
	int type = OBJ_obj2nid(CMS_get0_type(cms));
	CFDataRef content = NULL;
	bool encrypted = type == NID_pkcs7_enveloped || type == NID_pkcs7_encrypted;
	if (encrypted) {
		content = decryptMessage(cms, decoder->keychain);
		if (!content) {
			CMS_ContentInfo_free(cms);
			return errSecDecode;
		}
	} else {
		content = copySignedContent(cms);
	}
	decoder->cms = cms;
	decoder->content = content;
	decoder->encrypted = encrypted;
	decoder->finalized = true;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderGetNumSigners(CMSDecoderRef decoder, size_t *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	STACK_OF(CMS_SignerInfo) *signers = CMS_get0_SignerInfos(decoder->cms);
	*output = signers ? (size_t)sk_CMS_SignerInfo_num(signers) : 0;
	return errSecSuccess;
}

static X509 *copySignerX509(CMSDecoderRef decoder, size_t index)
{
	STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(decoder->cms);
	if (!infos || index >= (size_t)sk_CMS_SignerInfo_num(infos))
		return NULL;
	CMS_SignerInfo *signer = sk_CMS_SignerInfo_value(infos, index);
	STACK_OF(X509) *certificates = CMS_get1_certs(decoder->cms);
	X509 *result = NULL;
	for (int i = 0; certificates && i < sk_X509_num(certificates); i++) {
		X509 *certificate = sk_X509_value(certificates, i);
		if (CMS_SignerInfo_cert_cmp(signer, certificate) == 0 && X509_up_ref(certificate)) {
			result = certificate;
			break;
		}
	}
	sk_X509_pop_free(certificates, X509_free);
	return result;
}

SEC_API OSStatus CMSDecoderCopySignerCert(CMSDecoderRef decoder, size_t index, SecCertificateRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = NULL;
	STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(decoder->cms);
	if (!infos || index >= (size_t)sk_CMS_SignerInfo_num(infos))
		return errSecParam;
	X509 *certificate = copySignerX509(decoder, index);
	SecCertificateRef result = certificate ? copySecCertificate(certificate) : NULL;
	X509_free(certificate);
	if (!result)
		return errSecItemNotFound;
	*output = result;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopySignerEmailAddress(CMSDecoderRef decoder, size_t index, CFStringRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = NULL;
	SecCertificateRef certificate = NULL;
	OSStatus status = CMSDecoderCopySignerCert(decoder, index, &certificate);
	if (status)
		return status;
	X509 *x509 = copyX509(certificate);
	CFRelease(certificate);
	STACK_OF(OPENSSL_STRING) *emails = x509 ? X509_get1_email(x509) : NULL;
	X509_free(x509);
	if (!emails || !sk_OPENSSL_STRING_num(emails)) {
		X509_email_free(emails);
		return errSecItemNotFound;
	}
	const char *email = sk_OPENSSL_STRING_value(emails, 0);
	CFStringRef result = email
	    ? CFStringCreateWithCString(NULL, email, kCFStringEncodingUTF8)
	    : NULL;
	X509_email_free(emails);
	if (!result)
		return errSecDecode;
	*output = result;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderIsContentEncrypted(CMSDecoderRef decoder, Boolean *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = decoder->encrypted;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopyEncapsulatedContentType(CMSDecoderRef decoder, CFDataRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = NULL;
	if (OBJ_obj2nid(CMS_get0_type(decoder->cms)) != NID_pkcs7_signed)
		return errSecSuccess;
	const ASN1_OBJECT *object = CMS_get0_eContentType(decoder->cms);
	*output = object ? dataForObjectDER(object) : NULL;
	return object && !*output ? errSecDecode : errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopyAllCerts(CMSDecoderRef decoder, CFArrayRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = NULL;
	STACK_OF(X509) *certificates = CMS_get1_certs(decoder->cms);
	if (!certificates)
		return errSecSuccess;
	CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; result && i < sk_X509_num(certificates); i++) {
		SecCertificateRef certificate = copySecCertificate(sk_X509_value(certificates, i));
		if (!certificate) {
			CFRelease(result);
			result = NULL;
			break;
		}
		CFArrayAppendValue(result, certificate);
		CFRelease(certificate);
	}
	sk_X509_pop_free(certificates, X509_free);
	if (!result)
		return errSecDecode;
	*output = result;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopyContent(CMSDecoderRef decoder, CFDataRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = decoder->content ? (CFDataRef)CFRetain(decoder->content) : NULL;
	return errSecSuccess;
}

static bool signatureIsValid(CMSDecoderRef decoder, size_t index)
{
	STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(decoder->cms);
	if (!infos || index >= (size_t)sk_CMS_SignerInfo_num(infos))
		return false;
	if (!decoder->content && !decoder->detached)
		return false;
	BIO *detached = decoder->detached
	    ? bioForData(CFDataGetBytePtr(decoder->detached), CFDataGetLength(decoder->detached))
	    : NULL;
	BIO *output = BIO_new(BIO_s_mem());
	int ok = output && CMS_verify(decoder->cms, NULL, NULL, detached, output,
	    CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY | CMS_NOCRL);
	BIO_free(detached);
	BIO_free(output);
	return ok == 1;
}

static bool makeSignerTrust(SecCertificateRef certificate, CFTypeRef policies,
	SecTrustRef *trustOut, bool evaluate, OSStatus *verifyStatus)
{
	CFTypeRef policy = policies;
	CFArrayRef policyArray = NULL;
	if (!policy)
		policy = SecPolicyCreateBasicX509();
	if (isType(policy, CFArrayGetTypeID()))
		policyArray = (CFArrayRef)policy;
	else if (policy)
		policyArray = CFArrayCreate(NULL, &policy, 1, &kCFTypeArrayCallBacks);
	CFArrayRef certArray = CFArrayCreate(NULL, (const void *[]){certificate}, 1, &kCFTypeArrayCallBacks);
	SecTrustRef trust = NULL;
	OSStatus status = certArray && policyArray
	    ? SecTrustCreateWithCertificates(certArray, policyArray, &trust)
	    : errSecAllocate;
	if (certArray)
		CFRelease(certArray);
	if (policyArray && policyArray != policies)
		CFRelease(policyArray);
	if (!policies && policy)
		CFRelease(policy);
	if (status)
		return false;
	bool trusted = true;
	if (evaluate) {
		SecTrustResultType result = kSecTrustResultInvalid;
		status = SecTrustEvaluate(trust, &result);
		trusted = !status && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
	}
	if (verifyStatus)
		*verifyStatus = trusted ? errSecSuccess : (status ? status : errSecNotTrusted);
	if (trustOut)
		*trustOut = trust;
	else
		CFRelease(trust);
	return trusted;
}

SEC_API OSStatus CMSDecoderCopySignerStatus(CMSDecoderRef decoder, size_t index, CFTypeRef policy,
	Boolean evaluateTrust, CMSSignerStatus *statusOut, SecTrustRef *trustOut,
	OSStatus *verifyStatusOut)
{
	if (!readyDecoder(decoder))
		return errSecParam;
	STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(decoder->cms);
	if (!infos || !sk_CMS_SignerInfo_num(infos)) {
		if (statusOut)
			*statusOut = kCMSSignerUnsigned;
		if (trustOut)
			*trustOut = NULL;
		if (verifyStatusOut)
			*verifyStatusOut = errSecSuccess;
		return errSecSuccess;
	}
	if (index >= (size_t)sk_CMS_SignerInfo_num(infos)) {
		if (statusOut)
			*statusOut = kCMSSignerInvalidIndex;
		if (trustOut)
			*trustOut = NULL;
		if (verifyStatusOut)
			*verifyStatusOut = errSecParam;
		return errSecSuccess;
	}
	if (trustOut)
		*trustOut = NULL;
	if (!decoder->content && !decoder->detached) {
		if (statusOut)
			*statusOut = kCMSSignerNeedsDetachedContent;
		if (verifyStatusOut)
			*verifyStatusOut = errSecSuccess;
		return errSecSuccess;
	}
	if (!signatureIsValid(decoder, index)) {
		if (statusOut)
			*statusOut = kCMSSignerInvalidSignature;
		if (verifyStatusOut)
			*verifyStatusOut = errSecSuccess;
		return errSecSuccess;
	}
	if (!evaluateTrust && !trustOut) {
		if (statusOut)
			*statusOut = kCMSSignerValid;
		if (verifyStatusOut)
			*verifyStatusOut = errSecSuccess;
		return errSecSuccess;
	}
	SecCertificateRef certificate = NULL;
	OSStatus result = CMSDecoderCopySignerCert(decoder, index, &certificate);
	if (result) {
		if (statusOut)
			*statusOut = kCMSSignerInvalidCert;
		if (verifyStatusOut)
			*verifyStatusOut = result;
		return errSecSuccess;
	}
	OSStatus certStatus = errSecSuccess;
	SecTrustRef trust = NULL;
	bool trusted = makeSignerTrust(certificate, policy, trustOut ? &trust : NULL,
	    evaluateTrust, &certStatus);
	CFRelease(certificate);
	if (trustOut)
		*trustOut = trust;
	if (verifyStatusOut)
		*verifyStatusOut = certStatus;
	if (statusOut)
		*statusOut = trusted ? kCMSSignerValid : kCMSSignerInvalidCert;
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopySignerSigningTime(CMSDecoderRef decoder, size_t index, CFAbsoluteTime *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	STACK_OF(CMS_SignerInfo) *signers = CMS_get0_SignerInfos(decoder->cms);
	if (!signers || index >= (size_t)sk_CMS_SignerInfo_num(signers))
		return errSecParam;
	CMS_SignerInfo *signer = sk_CMS_SignerInfo_value(signers, index);
	int attributeIndex = CMS_signed_get_attr_by_NID(signer, NID_pkcs9_signingTime, -1);
	X509_ATTRIBUTE *attribute = attributeIndex >= 0
	    ? CMS_signed_get_attr(signer, attributeIndex)
	    : NULL;
	ASN1_TYPE *value = attribute && X509_ATTRIBUTE_count(attribute)
	    ? X509_ATTRIBUTE_get0_type(attribute, 0)
	    : NULL;
	if (!value || (value->type != V_ASN1_UTCTIME && value->type != V_ASN1_GENERALIZEDTIME))
		return errSecItemNotFound;
	struct tm date = {0};
	if (!ASN1_TIME_to_tm(value->value.asn1_string, &date))
		return errSecDecode;
	*output = (CFAbsoluteTime)(timegm(&date) - 978307200);
	return errSecSuccess;
}

SEC_API OSStatus CMSDecoderCopySignerTimestamp(CMSDecoderRef decoder, size_t index, CFAbsoluteTime *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	STACK_OF(CMS_SignerInfo) *signers = CMS_get0_SignerInfos(decoder->cms);
	return signers && index < (size_t)sk_CMS_SignerInfo_num(signers)
	    ? errSecItemNotFound
	    : errSecParam;
}

SEC_API OSStatus CMSDecoderCopySignerTimestampWithPolicy(CMSDecoderRef decoder, CFTypeRef policy,
	size_t index, CFAbsoluteTime *output)
{
	(void)policy;
	return CMSDecoderCopySignerTimestamp(decoder, index, output);
}

SEC_API OSStatus CMSDecoderCopySignerTimestampCertificates(CMSDecoderRef decoder, size_t index,
	CFArrayRef *output)
{
	if (!readyDecoder(decoder) || !output)
		return errSecParam;
	*output = NULL;
	STACK_OF(CMS_SignerInfo) *signers = CMS_get0_SignerInfos(decoder->cms);
	return signers && index < (size_t)sk_CMS_SignerInfo_num(signers)
	    ? errSecItemNotFound
	    : errSecParam;
}

SEC_API OSStatus CMSEncoderCreate(CMSEncoderRef *output)
{
	if (!output)
		return errSecParam;
	*output = NULL;
	struct _CMSEncoder *encoder = (struct _CMSEncoder *)_SecCreateInstance(
	    CMSEncoderGetTypeID(), sizeof(*encoder));
	if (!encoder)
		return errSecAllocate;
	encoder->signers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	encoder->recipients = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	encoder->supportingCerts = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	encoder->content = CFDataCreateMutable(NULL, 0);
	encoder->digest = (CFStringRef)CFRetain(kCMSEncoderDigestAlgorithmSHA256);
	encoder->chainMode = kCMSCertificateChain;
	if (!encoder->signers || !encoder->recipients || !encoder->supportingCerts ||
	    !encoder->content || !encoder->digest) {
		CFRelease(encoder);
		return errSecAllocate;
	}
	*output = encoder;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderSetSignerAlgorithm(CMSEncoderRef encoder, CFStringRef digest)
{
	if (!mutableEncoder(encoder) || !isType(digest, CFStringGetTypeID()))
		return errSecParam;
	if (!CFEqual(digest, kCMSEncoderDigestAlgorithmSHA1) &&
	    !CFEqual(digest, kCMSEncoderDigestAlgorithmSHA256))
		return errSecParam;
	CFRelease(encoder->digest);
	encoder->digest = (CFStringRef)CFRetain(digest);
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderAddSigners(CMSEncoderRef encoder, CFTypeRef signers)
{
	if (!mutableEncoder(encoder))
		return errSecParam;
	return appendObjects(encoder->signers, signers, SecIdentityGetTypeID());
}

SEC_API OSStatus CMSEncoderCopySigners(CMSEncoderRef encoder, CFArrayRef *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = copyArray(encoder->signers);
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderAddRecipients(CMSEncoderRef encoder, CFTypeRef recipients)
{
	if (!mutableEncoder(encoder) || encoder->detached)
		return errSecParam;
	return appendObjects(encoder->recipients, recipients, SecCertificateGetTypeID());
}

SEC_API OSStatus CMSEncoderCopyRecipients(CMSEncoderRef encoder, CFArrayRef *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = copyArray(encoder->recipients);
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderSetHasDetachedContent(CMSEncoderRef encoder, Boolean detached)
{
	if (!mutableEncoder(encoder) || (detached && CFArrayGetCount(encoder->recipients)))
		return errSecParam;
	encoder->detached = detached;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderGetHasDetachedContent(CMSEncoderRef encoder, Boolean *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = encoder->detached;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderSetEncapsulatedContentTypeOID(CMSEncoderRef encoder, CFTypeRef oid)
{
	if (!mutableEncoder(encoder))
		return errSecParam;
	CFDataRef contents = NULL;
	if (isType(oid, CFStringGetTypeID())) {
		if (!oidDataFromString((CFStringRef)oid, &contents))
			return errSecParam;
	} else if (isType(oid, CFDataGetTypeID())) {
		ASN1_OBJECT *object = objectFromContents((CFDataRef)oid);
		if (!object)
			return errSecParam;
		ASN1_OBJECT_free(object);
		contents = (CFDataRef)CFRetain(oid);
	} else {
		return errSecParam;
	}
	if (encoder->contentType)
		CFRelease(encoder->contentType);
	encoder->contentType = contents;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderSetEncapsulatedContentType(CMSEncoderRef encoder, const CSSM_OID *oid)
{
	if (!mutableEncoder(encoder) || !oid || !oid->Data || !oid->Length)
		return errSecParam;
	ASN1_OBJECT *object = ASN1_OBJECT_create(NID_undef, oid->Data, (int)oid->Length, NULL, NULL);
	if (!object)
		return errSecParam;
	CFDataRef contents = dataForObjectContents(object);
	ASN1_OBJECT_free(object);
	if (!contents)
		return errSecDecode;
	if (encoder->contentType)
		CFRelease(encoder->contentType);
	encoder->contentType = contents;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderCopyEncapsulatedContentType(CMSEncoderRef encoder, CFDataRef *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = NULL;
	if (encoder->contentType) {
		ASN1_OBJECT *object = objectFromContents(encoder->contentType);
		*output = object ? dataForObjectDER(object) : NULL;
		ASN1_OBJECT_free(object);
		if (!*output)
			return errSecDecode;
	}
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderAddSupportingCerts(CMSEncoderRef encoder, CFTypeRef certificates)
{
	if (!mutableEncoder(encoder))
		return errSecParam;
	return appendObjects(encoder->supportingCerts, certificates, SecCertificateGetTypeID());
}

SEC_API OSStatus CMSEncoderCopySupportingCerts(CMSEncoderRef encoder, CFArrayRef *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = copyArray(encoder->supportingCerts);
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderAddSignedAttributes(CMSEncoderRef encoder, CMSSignedAttributes attributes)
{
	if (!mutableEncoder(encoder) || (attributes & ~(kCMSAttrSmimeCapabilities |
	    kCMSAttrSmimeEncryptionKeyPrefs | kCMSAttrSmimeMSEncryptionKeyPrefs | kCMSAttrSigningTime)))
		return errSecUnimplemented;
	encoder->attributes |= attributes;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderSetCertificateChainMode(CMSEncoderRef encoder, CMSCertificateChainMode mode)
{
	if (!mutableEncoder(encoder) || mode < kCMSCertificateNone ||
	    mode > kCMSCertificateChainWithRootOrFail)
		return errSecParam;
	encoder->chainMode = mode;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderGetCertificateChainMode(CMSEncoderRef encoder, CMSCertificateChainMode *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = encoder->chainMode;
	return errSecSuccess;
}

SEC_API OSStatus CMSEncoderUpdateContent(CMSEncoderRef encoder, const void *bytes, size_t length)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || encoder->encoded ||
	    (length && !bytes) || length > LONG_MAX)
		return errSecParam;
	encoder->contentStarted = true;
	if (length)
		CFDataAppendBytes(encoder->content, bytes, (CFIndex)length);
	return errSecSuccess;
}

static bool addSigner(CMS_ContentInfo *cms, SecIdentityRef identity,
	const EVP_MD *digest, unsigned int signerFlags, CMSSignedAttributes attributes)
{
	SecCertificateRef certificate = NULL;
	SecKeyRef key = NULL;
	if (SecIdentityCopyCertificate(identity, &certificate) ||
	    SecIdentityCopyPrivateKey(identity, &key)) {
		if (certificate)
			CFRelease(certificate);
		if (key)
			CFRelease(key);
		return false;
	}
	X509 *x509 = copyX509(certificate);
	EVP_PKEY *privateKey = copyPrivateKey(key);
	CFRelease(certificate);
	CFRelease(key);
	if (!x509 || !privateKey) {
		X509_free(x509);
		EVP_PKEY_free(privateKey);
		return false;
	}
	CMS_SignerInfo *signer = CMS_add1_signer(cms, x509, privateKey, digest, signerFlags);
	X509_free(x509);
	EVP_PKEY_free(privateKey);
	if (!signer)
		return false;
	if (!(attributes & kCMSAttrSigningTime)) {
		int index;
		while ((index = CMS_signed_get_attr_by_NID(signer, NID_pkcs9_signingTime, -1)) >= 0)
			CMS_signed_delete_attr(signer, index);
	}
	if (!(attributes & kCMSAttrSmimeCapabilities)) {
		int index;
		while ((index = CMS_signed_get_attr_by_NID(signer, NID_SMIMECapabilities, -1)) >= 0)
			CMS_signed_delete_attr(signer, index);
	}
	return true;
}

static CFDataRef encodeCMS(CMSEncoderRef encoder)
{
	bool hasSigners = CFArrayGetCount(encoder->signers) > 0;
	bool hasRecipients = CFArrayGetCount(encoder->recipients) > 0;
	bool hasSupportingCerts = CFArrayGetCount(encoder->supportingCerts) > 0;
	if (!hasSigners && !hasRecipients && !hasSupportingCerts)
		return NULL;
	if (hasRecipients && encoder->detached)
		return NULL;
	BIO *content = bioForData(CFDataGetBytePtr(encoder->content), CFDataGetLength(encoder->content));
	if (!content)
		return NULL;
	CMS_ContentInfo *signedCMS = NULL;
	CFDataRef innerData = NULL;
	CMS_ContentInfo *resultCMS = NULL;
	const EVP_MD *digest = EVP_get_digestbyname(CFEqual(encoder->digest,
	    kCMSEncoderDigestAlgorithmSHA1) ? "sha1" : "sha256");
	unsigned int signerFlags = CMS_BINARY;
	if (encoder->chainMode == kCMSCertificateNone)
		signerFlags |= CMS_NOCERTS;
	if (!(encoder->attributes & kCMSAttrSmimeCapabilities))
		signerFlags |= CMS_NOSMIMECAP;
	if (hasSigners || hasSupportingCerts) {
		signedCMS = CMS_sign(NULL, NULL, NULL, NULL, CMS_PARTIAL | CMS_BINARY);
		if (!signedCMS || !digest)
			goto fail;
		for (CFIndex i = 0; i < CFArrayGetCount(encoder->signers); i++) {
			if (!addSigner(signedCMS,
			    (SecIdentityRef)CFArrayGetValueAtIndex(encoder->signers, i),
			    digest, signerFlags, encoder->attributes))
				goto fail;
		}
		if (encoder->contentType) {
			ASN1_OBJECT *object = objectFromContents(encoder->contentType);
			int ok = object && CMS_set1_eContentType(signedCMS, object);
			ASN1_OBJECT_free(object);
			if (!ok)
				goto fail;
		}
		if (!addSupportingCertificates(signedCMS, encoder->supportingCerts))
			goto fail;
		if (encoder->detached && !CMS_set_detached(signedCMS, 1))
			goto fail;
		if (!CMS_final(signedCMS, content, NULL, CMS_BINARY))
			goto fail;
		if (!hasRecipients)
			resultCMS = signedCMS;
		else {
			unsigned char *bytes = NULL;
			int length = i2d_CMS_ContentInfo(signedCMS, &bytes);
			innerData = length > 0 ? CFDataCreate(NULL, bytes, length) : NULL;
			OPENSSL_free(bytes);
			if (!innerData)
				goto fail;
		}
	}
	if (hasRecipients) {
		const void *plainBytes = innerData ? CFDataGetBytePtr(innerData) : CFDataGetBytePtr(encoder->content);
		size_t plainLength = innerData ? CFDataGetLength(innerData) : CFDataGetLength(encoder->content);
		BIO *plain = bioForData(plainBytes, plainLength);
		STACK_OF(X509) *recipients = copyRecipientCertificates(encoder->recipients);
		if (!plain || !recipients || !sk_X509_num(recipients)) {
			BIO_free(plain);
			sk_X509_pop_free(recipients, X509_free);
			goto fail;
		}
		resultCMS = CMS_encrypt(recipients, plain, EVP_aes_256_cbc(), CMS_BINARY);
		BIO_free(plain);
		sk_X509_pop_free(recipients, X509_free);
		if (!resultCMS)
			goto fail;
	}
	unsigned char *encodedBytes = NULL;
	int encodedLength = resultCMS ? i2d_CMS_ContentInfo(resultCMS, &encodedBytes) : 0;
	CFDataRef encoded = encodedLength > 0 ? CFDataCreate(NULL, encodedBytes, encodedLength) : NULL;
	OPENSSL_free(encodedBytes);
	if (resultCMS != signedCMS)
		CMS_ContentInfo_free(resultCMS);
	CMS_ContentInfo_free(signedCMS);
	if (innerData)
		CFRelease(innerData);
	BIO_free(content);
	return encoded;
fail:
	if (resultCMS && resultCMS != signedCMS)
		CMS_ContentInfo_free(resultCMS);
	CMS_ContentInfo_free(signedCMS);
	if (innerData)
		CFRelease(innerData);
	BIO_free(content);
	return NULL;
}

SEC_API OSStatus CMSEncoderCopyEncodedContent(CMSEncoderRef encoder, CFDataRef *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	*output = NULL;
	if (!encoder->encoded) {
		encoder->encoded = encodeCMS(encoder);
		if (!encoder->encoded)
			return errSecParam;
	}
	*output = (CFDataRef)CFRetain(encoder->encoded);
	return errSecSuccess;
}

static OSStatus encodeOnce(CFTypeRef signers, CFTypeRef recipients, CFTypeRef oid,
	Boolean detached, CMSSignedAttributes attributes, const void *content,
	size_t contentLength, CFDataRef *output)
{
	if ((!signers && !recipients) || (contentLength && !content))
		return errSecParam;
	CMSEncoderRef encoder = NULL;
	OSStatus status = CMSEncoderCreate(&encoder);
	if (!status && signers)
		status = CMSEncoderAddSigners(encoder, signers);
	if (!status && recipients)
		status = CMSEncoderAddRecipients(encoder, recipients);
	if (!status && oid)
		status = CMSEncoderSetEncapsulatedContentTypeOID(encoder, oid);
	if (!status && detached)
		status = CMSEncoderSetHasDetachedContent(encoder, true);
	if (!status && attributes)
		status = CMSEncoderAddSignedAttributes(encoder, attributes);
	if (!status)
		status = CMSEncoderUpdateContent(encoder, content, contentLength);
	CFDataRef encoded = NULL;
	if (!status)
		status = CMSEncoderCopyEncodedContent(encoder, &encoded);
	if (encoder)
		CFRelease(encoder);
	if (status)
		return status;
	if (output)
		*output = encoded;
	else
		CFRelease(encoded);
	return errSecSuccess;
}

SEC_API OSStatus CMSEncode(CFTypeRef signers, CFTypeRef recipients, const CSSM_OID *oid,
	Boolean detached, CMSSignedAttributes attributes, const void *content,
	size_t contentLength, CFDataRef *output)
{
	if (!output)
		return errSecParam;
	*output = NULL;
	CFDataRef oidData = NULL;
	if (oid) {
		if (!oid->Data || !oid->Length)
			return errSecParam;
		ASN1_OBJECT *object = ASN1_OBJECT_create(NID_undef, oid->Data, (int)oid->Length, NULL, NULL);
		oidData = object ? dataForObjectContents(object) : NULL;
		ASN1_OBJECT_free(object);
		if (!oidData)
			return errSecParam;
	}
	OSStatus status = encodeOnce(signers, recipients, oidData, detached,
	    attributes, content, contentLength, output);
	if (oidData)
		CFRelease(oidData);
	return status;
}

SEC_API OSStatus CMSEncodeContent(CFTypeRef signers, CFTypeRef recipients, CFTypeRef oid,
	Boolean detached, CMSSignedAttributes attributes, const void *content,
	size_t contentLength, CFDataRef *output)
{
	if (output)
		*output = NULL;
	return encodeOnce(signers, recipients, oid, detached, attributes,
	    content, contentLength, output);
}

SEC_API OSStatus CMSEncoderCopySignerTimestamp(CMSEncoderRef encoder, size_t index,
	CFAbsoluteTime *output)
{
	if (!isType(encoder, CMSEncoderGetTypeID()) || !output)
		return errSecParam;
	return index < (size_t)CFArrayGetCount(encoder->signers)
	    ? errSecItemNotFound
	    : errSecParam;
}

SEC_API OSStatus CMSEncoderCopySignerTimestampWithPolicy(CMSEncoderRef encoder,
	CFTypeRef policy, size_t index, CFAbsoluteTime *output)
{
	(void)policy;
	return CMSEncoderCopySignerTimestamp(encoder, index, output);
}

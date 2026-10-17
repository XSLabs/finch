/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Security protocol options live with Network's opaque TLS options object. */
#include "SecInternal.h"

#include <Security/SecProtocolOptions.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <stdint.h>
#include <string.h>

static const char stateAssociation;
static const char identityAssociation;
static const char challengeBlockAssociation;
static const char challengeQueueAssociation;
static const char verifyBlockAssociation;
static const char verifyQueueAssociation;

static CFMutableDictionaryRef optionsState(sec_protocol_options_t options, bool create)
{
	if (!options)
		return NULL;
	CFMutableDictionaryRef state = (CFMutableDictionaryRef)objc_getAssociatedObject((id)options, &stateAssociation);
	if (!state && create) {
		state = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		    &kCFTypeDictionaryValueCallBacks);
		if (!state)
			return NULL;
		objc_setAssociatedObject((id)options, &stateAssociation, (id)state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		CFRelease(state);
		state = (CFMutableDictionaryRef)objc_getAssociatedObject((id)options, &stateAssociation);
	}
	return state;
}

static void setObject(sec_protocol_options_t options, CFStringRef key, CFTypeRef value)
{
	CFMutableDictionaryRef state = optionsState(options, true);
	if (!state)
		return;
	if (value)
		CFDictionarySetValue(state, key, value);
	else
		CFDictionaryRemoveValue(state, key);
}

static void setNumber(sec_protocol_options_t options, CFStringRef key, int64_t value)
{
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
	if (number) {
		setObject(options, key, number);
		CFRelease(number);
	}
}

static void setBoolean(sec_protocol_options_t options, CFStringRef key, bool value)
{
	setObject(options, key, value ? kCFBooleanTrue : kCFBooleanFalse);
}

static void setString(sec_protocol_options_t options, CFStringRef key, const char *value)
{
	if (!value) {
		setObject(options, key, NULL);
		return;
	}
	CFStringRef string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
	if (string) {
		setObject(options, key, string);
		CFRelease(string);
	}
}

static CFDataRef pointerData(const void *pointer)
{
	uintptr_t value = (uintptr_t)pointer;
	return CFDataCreate(NULL, (const UInt8 *)&value, sizeof(value));
}

static void setPointer(sec_protocol_options_t options, CFStringRef key, const void *pointer)
{
	CFDataRef data = pointerData(pointer);
	if (data) {
		setObject(options, key, data);
		CFRelease(data);
	}
}

static void appendNumber(sec_protocol_options_t options, CFStringRef key, uint64_t value)
{
	CFMutableDictionaryRef state = optionsState(options, true);
	if (!state)
		return;
	CFMutableArrayRef values = (CFMutableArrayRef)CFDictionaryGetValue(state, key);
	if (!values) {
		values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		if (!values)
			return;
		CFDictionarySetValue(state, key, values);
		CFRelease(values);
		values = (CFMutableArrayRef)CFDictionaryGetValue(state, key);
	}
	int64_t item = (int64_t)value;
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &item);
	if (number) {
		CFArrayAppendValue(values, number);
		CFRelease(number);
	}
}

static void appendString(sec_protocol_options_t options, CFStringRef key, const char *value)
{
	if (!options || !value)
		return;
	CFStringRef string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
	if (!string)
		return;
	CFMutableDictionaryRef state = optionsState(options, true);
	if (state) {
		CFMutableArrayRef values = (CFMutableArrayRef)CFDictionaryGetValue(state, key);
		if (!values) {
			values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
			if (values) {
				CFDictionarySetValue(state, key, values);
				CFRelease(values);
				values = (CFMutableArrayRef)CFDictionaryGetValue(state, key);
			}
		}
		if (values)
			CFArrayAppendValue(values, string);
	}
	CFRelease(string);
}

static void setAssociated(sec_protocol_options_t options, const void *key, id value, objc_AssociationPolicy policy)
{
	if (options)
		objc_setAssociatedObject((id)options, key, value, policy);
}

bool sec_protocol_options_are_equal(sec_protocol_options_t optionsA, sec_protocol_options_t optionsB)
{
	if (optionsA == optionsB)
		return true;
	if (!optionsA || !optionsB)
		return false;
	CFDictionaryRef a = optionsState(optionsA, false);
	CFDictionaryRef b = optionsState(optionsB, false);
	if (!a || CFDictionaryGetCount(a) == 0)
		return !b || CFDictionaryGetCount(b) == 0;
	if (!b)
		return false;
	return CFEqual(a, b);
}

void sec_protocol_options_set_local_identity(sec_protocol_options_t options, sec_identity_t identity)
{
	setPointer(options, CFSTR("local_identity"), identity);
	setAssociated(options, &identityAssociation, (id)identity,
	    identity ? OBJC_ASSOCIATION_RETAIN_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
}

void sec_protocol_options_append_tls_ciphersuite(sec_protocol_options_t options, tls_ciphersuite_t ciphersuite)
{
	appendNumber(options, CFSTR("ciphersuites"), ciphersuite);
}

void sec_protocol_options_add_tls_ciphersuite(sec_protocol_options_t options, SSLCipherSuite ciphersuite)
{
	sec_protocol_options_append_tls_ciphersuite(options, (tls_ciphersuite_t)ciphersuite);
}

void sec_protocol_options_set_min_tls_protocol_version(sec_protocol_options_t options, tls_protocol_version_t version)
{
	setNumber(options, CFSTR("min_tls_version"), version);
}

void sec_protocol_options_set_max_tls_protocol_version(sec_protocol_options_t options, tls_protocol_version_t version)
{
	setNumber(options, CFSTR("max_tls_version"), version);
}

void sec_protocol_options_set_tls_min_version(sec_protocol_options_t options, SSLProtocol version)
{
	setNumber(options, CFSTR("min_tls_version"), version);
}

void sec_protocol_options_set_tls_max_version(sec_protocol_options_t options, SSLProtocol version)
{
	setNumber(options, CFSTR("max_tls_version"), version);
}

tls_protocol_version_t sec_protocol_options_get_default_min_tls_protocol_version(void)
{
	return tls_protocol_version_TLSv12;
}

tls_protocol_version_t sec_protocol_options_get_default_max_tls_protocol_version(void)
{
	return tls_protocol_version_TLSv13;
}

tls_protocol_version_t sec_protocol_options_get_default_min_dtls_protocol_version(void)
{
	return tls_protocol_version_DTLSv12;
}

tls_protocol_version_t sec_protocol_options_get_default_max_dtls_protocol_version(void)
{
	return tls_protocol_version_DTLSv12;
}

void sec_protocol_options_add_tls_application_protocol(sec_protocol_options_t options, const char *application_protocol)
{
	appendString(options, CFSTR("application_protocols"), application_protocol);
}

void sec_protocol_options_set_tls_server_name(sec_protocol_options_t options, const char *server_name)
{
	setString(options, CFSTR("server_name"), server_name);
}

void sec_protocol_options_set_tls_tickets_enabled(sec_protocol_options_t options, bool enabled)
{
	setObject(options, CFSTR("tickets_enabled"), enabled ? kCFBooleanTrue : NULL);
}

void sec_protocol_options_set_tls_is_fallback_attempt(sec_protocol_options_t options, bool enabled)
{
	setBoolean(options, CFSTR("fallback_attempt"), enabled);
}

void sec_protocol_options_set_tls_renegotiation_enabled(sec_protocol_options_t options, bool enabled)
{
	setBoolean(options, CFSTR("renegotiation_enabled"), enabled);
}

void sec_protocol_options_set_peer_authentication_required(sec_protocol_options_t options, bool required)
{
	setBoolean(options, CFSTR("peer_authentication_required"), required);
}

void sec_protocol_options_set_challenge_block(sec_protocol_options_t options, sec_protocol_challenge_t block,
    dispatch_queue_t queue)
{
	setPointer(options, CFSTR("challenge_block"), block);
	setPointer(options, CFSTR("challenge_queue"), queue);
	setAssociated(options, &challengeBlockAssociation, (id)block,
	    block ? OBJC_ASSOCIATION_COPY_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
	setAssociated(options, &challengeQueueAssociation, (id)queue,
	    queue ? OBJC_ASSOCIATION_RETAIN_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
}

void sec_protocol_options_set_verify_block(sec_protocol_options_t options, sec_protocol_verify_t block,
    dispatch_queue_t queue)
{
	setPointer(options, CFSTR("verify_block"), block);
	setPointer(options, CFSTR("verify_queue"), queue);
	setAssociated(options, &verifyBlockAssociation, (id)block,
	    block ? OBJC_ASSOCIATION_COPY_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
	setAssociated(options, &verifyQueueAssociation, (id)queue,
	    queue ? OBJC_ASSOCIATION_RETAIN_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
}

static bool numberForKey(sec_protocol_options_t options, CFStringRef key, int64_t *value)
{
	CFDictionaryRef state = optionsState(options, false);
	CFNumberRef number = state ? (CFNumberRef)CFDictionaryGetValue(state, key) : NULL;
	return number && CFGetTypeID(number) == CFNumberGetTypeID() &&
	    CFNumberGetValue(number, kCFNumberSInt64Type, value);
}

static bool booleanForKey(sec_protocol_options_t options, CFStringRef key, bool defaultValue)
{
	CFDictionaryRef state = optionsState(options, false);
	CFTypeRef value = state ? CFDictionaryGetValue(state, key) : NULL;
	if (!value)
		return defaultValue;
	return CFEqual(value, kCFBooleanTrue);
}

static SSLProtocol secureTransportVersion(int64_t value)
{
	switch (value) {
	case tls_protocol_version_TLSv10: return kTLSProtocol1;
	case tls_protocol_version_TLSv11: return kTLSProtocol11;
	case tls_protocol_version_TLSv12: return kTLSProtocol12;
	case tls_protocol_version_TLSv13: return kTLSProtocol13;
	case kTLSProtocol1:
	case kTLSProtocol11:
	case kTLSProtocol12:
	case kTLSProtocol13:	return (SSLProtocol)value;
	default:	return kSSLProtocolUnknown;
	}
}

static OSStatus clientIdentityForChallenge(SSLContextRef context, CFArrayRef *certificates, void *contextInfo)
{
	sec_protocol_options_t options = (sec_protocol_options_t)contextInfo;
	sec_protocol_challenge_t challenge = (sec_protocol_challenge_t)objc_getAssociatedObject((id)options,
	    &challengeBlockAssociation);
	if (!challenge || !certificates)
		return errSecItemNotFound;
	sec_protocol_metadata_t metadata = _FinchSecProtocolMetadataCreate();
	if (!metadata)
		return errSecAllocate;
	_FinchSecProtocolMetadataPopulate(metadata, context, NULL);
	dispatch_semaphore_t completed = dispatch_semaphore_create(0);
	if (!completed) {
		sec_release(metadata);
		return errSecAllocate;
	}
	__block sec_identity_t selected = NULL;
	sec_protocol_challenge_complete_t finish = ^(sec_identity_t identity) {
		selected = identity ? sec_retain(identity) : NULL;
		dispatch_semaphore_signal(completed);
	};
	dispatch_queue_t queue = (dispatch_queue_t)objc_getAssociatedObject((id)options, &challengeQueueAssociation);
	dispatch_async(queue ?: dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		challenge(metadata, finish);
	});
	dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
	sec_release(metadata);
	if (!selected)
		return errSecItemNotFound;
	SecIdentityRef identity = sec_identity_copy_ref(selected);
	CFArrayRef intermediates = sec_identity_copy_certificates_ref(selected);
	sec_release(selected);
	if (!identity) {
		if (intermediates)
			CFRelease(intermediates);
		return errSecItemNotFound;
	}
	CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (result) {
		CFArrayAppendValue(result, identity);
		if (intermediates)
			CFArrayAppendArray(result, intermediates, CFRangeMake(0, CFArrayGetCount(intermediates)));
		*certificates = result;
	}
	CFRelease(identity);
	if (intermediates)
		CFRelease(intermediates);
	return result ? noErr : errSecAllocate;
}

SEC_API OSStatus _FinchSecProtocolOptionsCopy(sec_protocol_options_t source, sec_protocol_options_t destination)
{
	if (!source || !destination)
		return errSecParam;
	CFDictionaryRef state = optionsState(source, false);
	CFMutableDictionaryRef copy = state ? CFDictionaryCreateMutableCopy(NULL, 0, state) : NULL;
	objc_setAssociatedObject((id)destination, &stateAssociation, (id)copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if (copy)
		CFRelease(copy);
	setAssociated(destination, &identityAssociation,
	    objc_getAssociatedObject((id)source, &identityAssociation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	setAssociated(destination, &challengeBlockAssociation,
	    objc_getAssociatedObject((id)source, &challengeBlockAssociation), OBJC_ASSOCIATION_COPY_NONATOMIC);
	setAssociated(destination, &challengeQueueAssociation,
	    objc_getAssociatedObject((id)source, &challengeQueueAssociation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	setAssociated(destination, &verifyBlockAssociation,
	    objc_getAssociatedObject((id)source, &verifyBlockAssociation), OBJC_ASSOCIATION_COPY_NONATOMIC);
	setAssociated(destination, &verifyQueueAssociation,
	    objc_getAssociatedObject((id)source, &verifyQueueAssociation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return noErr;
}

SEC_API OSStatus _FinchSecProtocolOptionsApply(sec_protocol_options_t options, SSLContextRef context,
	const char *defaultServerName)
{
	if (!options || !context)
		return errSecParam;
	int64_t rawVersion = tls_protocol_version_TLSv12;
	numberForKey(options, CFSTR("min_tls_version"), &rawVersion);
	SSLProtocol minVersion = secureTransportVersion(rawVersion);
	if (minVersion == kSSLProtocolUnknown)
		return errSecParam;
	OSStatus status = SSLSetProtocolVersionMin(context, minVersion);
	rawVersion = tls_protocol_version_TLSv13;
	numberForKey(options, CFSTR("max_tls_version"), &rawVersion);
	SSLProtocol maxVersion = secureTransportVersion(rawVersion);
	if (maxVersion == kSSLProtocolUnknown)
		return errSecParam;
	if (status == noErr)
		status = SSLSetProtocolVersionMax(context, maxVersion);
	if (status != noErr)
		return status;

	CFDictionaryRef state = optionsState(options, false);
	CFStringRef configuredName = state ? (CFStringRef)CFDictionaryGetValue(state, CFSTR("server_name")) : NULL;
	char serverName[1024];
	const char *name = defaultServerName;
	if (configuredName && CFGetTypeID(configuredName) == CFStringGetTypeID()) {
		if (!CFStringGetCString(configuredName, serverName, sizeof(serverName), kCFStringEncodingUTF8))
			return errSecParam;
		name = serverName;
	}
	status = name ? SSLSetPeerDomainName(context, name, strlen(name)) : SSLSetPeerDomainName(context, NULL, 0);
	if (status != noErr)
		return status;

	CFArrayRef protocols = state ? (CFArrayRef)CFDictionaryGetValue(state, CFSTR("application_protocols")) : NULL;
	if (protocols) {
		status = SSLSetALPNProtocols(context, protocols);
		if (status != noErr)
			return status;
	}
	CFArrayRef suiteValues = state ? (CFArrayRef)CFDictionaryGetValue(state, CFSTR("ciphersuites")) : NULL;
	if (suiteValues && CFGetTypeID(suiteValues) == CFArrayGetTypeID()) {
		CFIndex count = CFArrayGetCount(suiteValues);
		SSLCipherSuite *suites = count ? calloc((size_t)count, sizeof(*suites)) : NULL;
		if (count && !suites)
			return errSecAllocate;
		for (CFIndex i = 0; i < count; i++) {
			int64_t value = 0;
			CFNumberRef number = (CFNumberRef)CFArrayGetValueAtIndex(suiteValues, i);
			if (!number || CFGetTypeID(number) != CFNumberGetTypeID() ||
			    !CFNumberGetValue(number, kCFNumberSInt64Type, &value) || value < 0 || value > UINT16_MAX) {
				free(suites);
				return errSecParam;
			}
			suites[i] = (SSLCipherSuite)value;
		}
		status = SSLSetEnabledCiphers(context, suites, (size_t)count);
		free(suites);
		if (status != noErr)
			return status;
	}

	bool tickets = booleanForKey(options, CFSTR("tickets_enabled"), false);
	status = SSLSetSessionTicketsEnabled(context, tickets);
	if (status != noErr)
		return status;
	status = _FinchSSLSetFallbackAttempt(context, booleanForKey(options, CFSTR("fallback_attempt"), false));
	if (status != noErr)
		return status;
	status = _FinchSSLSetRenegotiationEnabled(context,
	    booleanForKey(options, CFSTR("renegotiation_enabled"), true));
	if (status != noErr)
		return status;
	status = SSLSetEnableCertVerify(context,
	    booleanForKey(options, CFSTR("peer_authentication_required"), true));
	if (status != noErr)
		return status;

	sec_identity_t identity = (sec_identity_t)objc_getAssociatedObject((id)options, &identityAssociation);
	if (identity) {
		SecIdentityRef identityRef = sec_identity_copy_ref(identity);
		CFArrayRef intermediates = sec_identity_copy_certificates_ref(identity);
		if (!identityRef)
			return errSecParam;
		CFMutableArrayRef certs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		if (!certs) {
			CFRelease(identityRef);
			if (intermediates)
				CFRelease(intermediates);
			return errSecAllocate;
		}
		CFArrayAppendValue(certs, identityRef);
		if (intermediates)
			CFArrayAppendArray(certs, intermediates, CFRangeMake(0, CFArrayGetCount(intermediates)));
		status = SSLSetCertificate(context, certs);
		CFRelease(certs);
		CFRelease(identityRef);
		if (intermediates)
			CFRelease(intermediates);
		if (status != noErr)
			return status;
	}
	if (objc_getAssociatedObject((id)options, &challengeBlockAssociation)) {
		status = _FinchSSLSetClientIdentityCallback(context, clientIdentityForChallenge, (void *)options);
		if (status != noErr)
			return status;
	}
	if (objc_getAssociatedObject((id)options, &verifyBlockAssociation))
		return SSLSetSessionOption(context, kSSLSessionOptionBreakOnServerAuth, true);
	return noErr;
}

SEC_API Boolean _FinchSecProtocolOptionsVerifyPeer(sec_protocol_options_t options,
	sec_protocol_metadata_t metadata, SSLContextRef context)
{
	sec_protocol_verify_t verify = (sec_protocol_verify_t)objc_getAssociatedObject((id)options,
	    &verifyBlockAssociation);
	if (!verify || !metadata || !context)
		return false;
	SecTrustRef trust = NULL;
	if (SSLCopyPeerTrust(context, &trust) != noErr || !trust)
		return false;
	sec_trust_t wrappedTrust = sec_trust_create(trust);
	CFRelease(trust);
	if (!wrappedTrust)
		return false;
	dispatch_semaphore_t completed = dispatch_semaphore_create(0);
	if (!completed) {
		sec_release(wrappedTrust);
		return false;
	}
	__block Boolean accepted = false;
	sec_protocol_verify_complete_t finish = ^(bool result) {
		accepted = result;
		dispatch_semaphore_signal(completed);
	};
	dispatch_queue_t queue = (dispatch_queue_t)objc_getAssociatedObject((id)options, &verifyQueueAssociation);
	dispatch_async(queue ?: dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		verify(metadata, wrappedTrust, finish);
	});
	dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
	sec_release(wrappedTrust);
	return accepted;
}

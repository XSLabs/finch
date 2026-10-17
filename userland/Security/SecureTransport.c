/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Secure Transport (SecureTransport.h): TLS over the caller's own I/O functions, with
 * OpenSSL's TLS (linked statically, as the rest of Security's crypto is). The caller's
 * read and write functions are an OpenSSL BIO; their errSSLWouldBlock is OpenSSL's
 * retry, and OpenSSL's wants are errSSLWouldBlock back. The peer's certificates are
 * judged by Security's own trust evaluation (SecTrust, with an SSL policy for the peer's
 * name) when the handshake completes, as Secure Transport judges them; with
 * kSSLSessionOptionBreakOnServerAuth (or ClientAuth) the handshake stops once there with
 * errSSLPeerAuthCompleted, for the caller to judge them itself (SSLCopyPeerTrust), and
 * goes on at the next SSLHandshake. DTLS isn't offered.
 */
#include "SecInternal.h"
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <stdlib.h>
#include <string.h>

SEC_HIDDEN X509 *_SecCertificateGetX509(SecCertificateRef c);
SEC_HIDDEN EVP_PKEY *_SecKeyGetEVP(SecKeyRef k);

struct SSLContext {
	CFRuntimeBase base;
	SSLProtocolSide side;
	SSLConnectionType type;
	SSL_CTX *ctx;
	SSL *ssl;
	SSLReadFunc readFunc;
	SSLWriteFunc writeFunc;
	SSLConnectionRef connection;
	char *peerName;
	SSLProtocol minVersion, maxVersion;
	bool options[10];
	bool authReported, verify, allowAnyRoot, allowExpired;
	SSLSessionState state;
	CFArrayRef certificates;   /* identity, then intermediates */
	SSLAuthenticate clientAuth;
	CFArrayRef alpn, anchors;
	SSLCipherSuite *enabled;
	size_t enabledCount;
	FinchSSLClientIdentityCallback clientIdentityCallback;
	void *clientIdentityContext;
	bool fallbackAttempt, renegotiationEnabled;
	void *peerID;
	size_t peerIDLength;
	OSStatus ioStatus;         /* the I/O functions' last status */
};

static void
context_free(CFTypeRef o)
{
	struct SSLContext *c = (struct SSLContext *)o;
	if (c->ssl)
		SSL_free(c->ssl);
	if (c->ctx)
		SSL_CTX_free(c->ctx);
	free(c->peerName);
	free(c->enabled);
	free(c->peerID);
	if (c->certificates)
		CFRelease(c->certificates);
	if (c->alpn)
		CFRelease(c->alpn);
	if (c->anchors)
		CFRelease(c->anchors);
}

SEC_API SEC_DEFINE_TYPE(SSLContextGetTypeID, "SSLContext", context_free, NULL, NULL)

#define CTX(ref) ((struct SSLContext *)(ref))
#define CHECK(ref)                                                                                 \
	do {                                                                                       \
		if (!(ref) || CFGetTypeID(ref) != SSLContextGetTypeID())                           \
			return errSecParam;                                                        \
	} while (0)

/* --- the caller's I/O as a BIO --- */

static BIO_METHOD *io_method;

static int
io_read(BIO *b, char *buf, int len)
{
	struct SSLContext *c = BIO_get_data(b);
	size_t n = (size_t)len;
	BIO_clear_retry_flags(b);
	OSStatus st = c->readFunc ? c->readFunc(c->connection, buf, &n) : errSSLInternal;
	c->ioStatus = st;
	if (n > 0)
		return (int)n;
	if (st == errSSLWouldBlock) {
		BIO_set_retry_read(b);
		return -1;
	}
	return st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == noErr ? 0 : -1;
}

static int
io_write(BIO *b, const char *buf, int len)
{
	struct SSLContext *c = BIO_get_data(b);
	size_t n = (size_t)len;
	BIO_clear_retry_flags(b);
	OSStatus st = c->writeFunc ? c->writeFunc(c->connection, buf, &n) : errSSLInternal;
	c->ioStatus = st;
	if (n > 0)
		return (int)n;
	if (st == errSSLWouldBlock) {
		BIO_set_retry_write(b);
		return -1;
	}
	return -1;
}

static long
io_ctrl(BIO *b, int cmd, long num, void *ptr)
{
	return cmd == BIO_CTRL_FLUSH ? 1 : 0;
}

static int
io_create(BIO *b)
{
	BIO_set_init(b, 1);
	return 1;
}

/* --- making a context --- */

SEC_API SSLContextRef
SSLCreateContext(CFAllocatorRef alloc, SSLProtocolSide protocolSide, SSLConnectionType connectionType)
{
	if (connectionType != kSSLStreamType)
		return NULL; /* (no DTLS) */
	struct SSLContext *c = (struct SSLContext *)_SecCreateInstance(SSLContextGetTypeID(), sizeof(struct SSLContext));
	if (!c)
		return NULL;
	c->side = protocolSide;
	c->type = connectionType;
	c->minVersion = kTLSProtocol1;
	c->maxVersion = kTLSProtocol13;
	c->verify = true;
	c->renegotiationEnabled = true;
	c->state = kSSLIdle;
	return (SSLContextRef)c;
}

SEC_API OSStatus
SSLNewContext(Boolean isServer, SSLContextRef *contextPtr)
{
	if (!contextPtr)
		return errSecParam;
	*contextPtr = SSLCreateContext(NULL, isServer ? kSSLServerSide : kSSLClientSide, kSSLStreamType);
	return *contextPtr ? noErr : errSecAllocate;
}

SEC_API OSStatus
SSLDisposeContext(SSLContextRef context)
{
	CHECK(context);
	CFRelease(context);
	return noErr;
}

SEC_API OSStatus
SSLGetSessionState(SSLContextRef context, SSLSessionState *state)
{
	CHECK(context);
	if (!state)
		return errSecParam;
	*state = CTX(context)->state;
	return noErr;
}

SEC_API OSStatus
SSLSetSessionOption(SSLContextRef context, SSLSessionOption option, Boolean value)
{
	CHECK(context);
	if ((int)option < 0 || (int)option >= 10)
		return errSecParam;
	CTX(context)->options[option] = value;
	return noErr;
}

SEC_API OSStatus
SSLGetSessionOption(SSLContextRef context, SSLSessionOption option, Boolean *value)
{
	CHECK(context);
	if ((int)option < 0 || (int)option >= 10 || !value)
		return errSecParam;
	*value = CTX(context)->options[option];
	return noErr;
}

SEC_API OSStatus
SSLSetIOFuncs(SSLContextRef context, SSLReadFunc readFunc, SSLWriteFunc writeFunc)
{
	CHECK(context);
	if (CTX(context)->state != kSSLIdle)
		return errSecBadReq;
	CTX(context)->readFunc = readFunc;
	CTX(context)->writeFunc = writeFunc;
	return noErr;
}

SEC_API OSStatus SSLSetSessionConfig(SSLContextRef context, CFStringRef config) { CHECK(context); return noErr; }

SEC_API OSStatus
SSLSetConnection(SSLContextRef context, SSLConnectionRef connection)
{
	CHECK(context);
	CTX(context)->connection = connection;
	return noErr;
}

SEC_API OSStatus
SSLGetConnection(SSLContextRef context, SSLConnectionRef *connection)
{
	CHECK(context);
	if (!connection)
		return errSecParam;
	*connection = CTX(context)->connection;
	return noErr;
}

SEC_API OSStatus
SSLSetPeerDomainName(SSLContextRef context, const char *peerName, size_t peerNameLen)
{
	CHECK(context);
	free(CTX(context)->peerName);
	CTX(context)->peerName = peerName ? strndup(peerName, peerNameLen) : NULL;
	return noErr;
}

OSStatus
_FinchSSLSetClientIdentityCallback(SSLContextRef context, FinchSSLClientIdentityCallback callback,
	void *contextInfo)
{
	CHECK(context);
	if (CTX(context)->state != kSSLIdle)
		return errSecBadReq;
	CTX(context)->clientIdentityCallback = callback;
	CTX(context)->clientIdentityContext = contextInfo;
	return noErr;
}

OSStatus
_FinchSSLSetFallbackAttempt(SSLContextRef context, Boolean enabled)
{
	CHECK(context);
	if (CTX(context)->state != kSSLIdle)
		return errSecBadReq;
	CTX(context)->fallbackAttempt = enabled;
	return noErr;
}

OSStatus
_FinchSSLSetRenegotiationEnabled(SSLContextRef context, Boolean enabled)
{
	CHECK(context);
	if (CTX(context)->state != kSSLIdle)
		return errSecBadReq;
	CTX(context)->renegotiationEnabled = enabled;
	return noErr;
}

SEC_API OSStatus
SSLGetPeerDomainNameLength(SSLContextRef context, size_t *peerNameLen)
{
	CHECK(context);
	if (!peerNameLen)
		return errSecParam;
	*peerNameLen = CTX(context)->peerName ? strlen(CTX(context)->peerName) : 0;
	return noErr;
}

SEC_API OSStatus
SSLGetPeerDomainName(SSLContextRef context, char *peerName, size_t *peerNameLen)
{
	CHECK(context);
	if (!peerName || !peerNameLen)
		return errSecParam;
	size_t n = CTX(context)->peerName ? strlen(CTX(context)->peerName) : 0;
	if (*peerNameLen < n)
		return errSSLBufferOverflow;
	memcpy(peerName, CTX(context)->peerName ? CTX(context)->peerName : "", n);
	*peerNameLen = n;
	return noErr;
}

/* The name a client asked a server for (SNI). */
SEC_API OSStatus
SSLCopyRequestedPeerNameLength(SSLContextRef context, size_t *peerNameLen)
{
	CHECK(context);
	const char *n = CTX(context)->ssl ? SSL_get_servername(CTX(context)->ssl, TLSEXT_NAMETYPE_host_name) : NULL;
	if (!peerNameLen)
		return errSecParam;
	*peerNameLen = n ? strlen(n) : 0;
	return n ? noErr : errSecParam;
}

SEC_API OSStatus
SSLCopyRequestedPeerName(SSLContextRef context, char *peerName, size_t *peerNameLen)
{
	CHECK(context);
	const char *n = CTX(context)->ssl ? SSL_get_servername(CTX(context)->ssl, TLSEXT_NAMETYPE_host_name) : NULL;
	if (!n || !peerName || !peerNameLen)
		return errSecParam;
	if (*peerNameLen < strlen(n))
		return errSSLBufferOverflow;
	memcpy(peerName, n, strlen(n));
	*peerNameLen = strlen(n);
	return noErr;
}

/* --- versions --- */

static int
openssl_version(SSLProtocol p)
{
	switch (p) {
	case kTLSProtocol1: return TLS1_VERSION;
	case kTLSProtocol11: return TLS1_1_VERSION;
	case kTLSProtocol12: return TLS1_2_VERSION;
	case kTLSProtocol13: case kTLSProtocolMaxSupported: return TLS1_3_VERSION;
	case kSSLProtocol3: return SSL3_VERSION;
	default: return 0;
	}
}

static SSLProtocol
st_version(int v)
{
	switch (v) {
	case TLS1_VERSION: return kTLSProtocol1;
	case TLS1_1_VERSION: return kTLSProtocol11;
	case TLS1_2_VERSION: return kTLSProtocol12;
	case TLS1_3_VERSION: return kTLSProtocol13;
	case SSL3_VERSION: return kSSLProtocol3;
	default: return kSSLProtocolUnknown;
	}
}

SEC_API OSStatus
SSLSetProtocolVersionMin(SSLContextRef context, SSLProtocol minVersion)
{
	CHECK(context);
	if (!openssl_version(minVersion))
		return errSecParam;
	CTX(context)->minVersion = minVersion;
	return noErr;
}

SEC_API OSStatus
SSLGetProtocolVersionMin(SSLContextRef context, SSLProtocol *minVersion)
{
	CHECK(context);
	if (!minVersion)
		return errSecParam;
	*minVersion = CTX(context)->minVersion;
	return noErr;
}

SEC_API OSStatus
SSLSetProtocolVersionMax(SSLContextRef context, SSLProtocol maxVersion)
{
	CHECK(context);
	if (!openssl_version(maxVersion))
		return errSecParam;
	CTX(context)->maxVersion = maxVersion == kTLSProtocolMaxSupported ? kTLSProtocol13 : maxVersion;
	return noErr;
}

SEC_API OSStatus
SSLGetProtocolVersionMax(SSLContextRef context, SSLProtocol *maxVersion)
{
	CHECK(context);
	if (!maxVersion)
		return errSecParam;
	*maxVersion = CTX(context)->maxVersion;
	return noErr;
}

/* (the old per-version switches: a version on widens the range to it) */
SEC_API OSStatus
SSLSetProtocolVersionEnabled(SSLContextRef context, SSLProtocol protocol, Boolean enable)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	if (protocol == kSSLProtocolAll) {
		c->minVersion = kTLSProtocol1, c->maxVersion = kTLSProtocol13;
		return noErr;
	}
	if (!openssl_version(protocol))
		return errSecParam;
	if (enable) {
		if (openssl_version(protocol) < openssl_version(c->minVersion))
			c->minVersion = protocol;
		if (openssl_version(protocol) > openssl_version(c->maxVersion))
			c->maxVersion = protocol;
	} else if (protocol == c->minVersion && c->minVersion != c->maxVersion) {
		c->minVersion = st_version(openssl_version(protocol) + 1);
	} else if (protocol == c->maxVersion && c->minVersion != c->maxVersion) {
		c->maxVersion = st_version(openssl_version(protocol) - 1);
	}
	return noErr;
}

SEC_API OSStatus
SSLGetProtocolVersionEnabled(SSLContextRef context, SSLProtocol protocol, Boolean *enable)
{
	CHECK(context);
	if (!enable)
		return errSecParam;
	int v = openssl_version(protocol);
	*enable = v >= openssl_version(CTX(context)->minVersion) && v <= openssl_version(CTX(context)->maxVersion);
	return noErr;
}

SEC_API OSStatus
SSLSetProtocolVersion(SSLContextRef context, SSLProtocol version)
{
	CHECK(context);
	CTX(context)->minVersion = kTLSProtocol1;
	CTX(context)->maxVersion = version == kSSLProtocolAll ? kTLSProtocol13 : version;
	return noErr;
}

SEC_API OSStatus
SSLGetProtocolVersion(SSLContextRef context, SSLProtocol *protocol)
{
	CHECK(context);
	if (!protocol)
		return errSecParam;
	*protocol = CTX(context)->maxVersion;
	return noErr;
}

SEC_API OSStatus
SSLGetNegotiatedProtocolVersion(SSLContextRef context, SSLProtocol *protocol)
{
	CHECK(context);
	if (!protocol)
		return errSecParam;
	struct SSLContext *c = CTX(context);
	*protocol = c->ssl && SSL_is_init_finished(c->ssl) &&
	    (c->state == kSSLHandshake || c->state == kSSLConnected) ? st_version(SSL_version(c->ssl))
	                                                            : kSSLProtocolUnknown;
	return noErr;
}

/* --- certificates and trust --- */

SEC_API OSStatus
SSLSetCertificate(SSLContextRef context, CFArrayRef certRefs)
{
	CHECK(context);
	if (CTX(context)->certificates)
		CFRelease(CTX(context)->certificates);
	CTX(context)->certificates = certRefs ? CFArrayCreateCopy(NULL, certRefs) : NULL;
	return noErr;
}

SEC_API OSStatus SSLSetEncryptionCertificate(SSLContextRef context, CFArrayRef certRefs) { return SSLSetCertificate(context, certRefs); }

SEC_API OSStatus
SSLSetClientSideAuthenticate(SSLContextRef context, SSLAuthenticate auth)
{
	CHECK(context);
	CTX(context)->clientAuth = auth;
	return noErr;
}

SEC_API OSStatus
SSLGetClientCertificateState(SSLContextRef context, SSLClientCertificateState *clientState)
{
	CHECK(context);
	if (!clientState)
		return errSecParam;
	struct SSLContext *c = CTX(context);
	X509 *peer = c->ssl && c->side == kSSLServerSide ? SSL_get0_peer_certificate(c->ssl) : NULL;
	*clientState = peer ? kSSLClientCertSent : c->clientAuth != kNeverAuthenticate ? kSSLClientCertRequested : kSSLClientCertNone;
	return noErr;
}

SEC_API OSStatus SSLSetEnableCertVerify(SSLContextRef context, Boolean enableVerify) { CHECK(context); CTX(context)->verify = enableVerify; return noErr; }
SEC_API OSStatus SSLGetEnableCertVerify(SSLContextRef context, Boolean *enableVerify) { CHECK(context); if (!enableVerify) return errSecParam; *enableVerify = CTX(context)->verify; return noErr; }
SEC_API OSStatus SSLSetAllowsExpiredCerts(SSLContextRef context, Boolean allows) { CHECK(context); CTX(context)->allowExpired = allows; return noErr; }
SEC_API OSStatus SSLGetAllowsExpiredCerts(SSLContextRef context, Boolean *allows) { CHECK(context); if (!allows) return errSecParam; *allows = CTX(context)->allowExpired; return noErr; }
SEC_API OSStatus SSLSetAllowsExpiredRoots(SSLContextRef context, Boolean allows) { CHECK(context); return noErr; }
SEC_API OSStatus SSLGetAllowsExpiredRoots(SSLContextRef context, Boolean *allows) { CHECK(context); if (!allows) return errSecParam; *allows = false; return noErr; }
SEC_API OSStatus SSLSetAllowsAnyRoot(SSLContextRef context, Boolean anyRoot) { CHECK(context); CTX(context)->allowAnyRoot = anyRoot; return noErr; }
SEC_API OSStatus SSLGetAllowsAnyRoot(SSLContextRef context, Boolean *anyRoot) { CHECK(context); if (!anyRoot) return errSecParam; *anyRoot = CTX(context)->allowAnyRoot; return noErr; }

SEC_API OSStatus
SSLSetTrustedRoots(SSLContextRef context, CFArrayRef trustedRoots, Boolean replaceExisting)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (c->anchors && !replaceExisting)
		CFArrayAppendArray(a, c->anchors, CFRangeMake(0, CFArrayGetCount(c->anchors)));
	if (trustedRoots)
		CFArrayAppendArray(a, trustedRoots, CFRangeMake(0, CFArrayGetCount(trustedRoots)));
	if (c->anchors)
		CFRelease(c->anchors);
	c->anchors = a;
	return noErr;
}

SEC_API OSStatus
SSLCopyTrustedRoots(SSLContextRef context, CFArrayRef *trustedRoots)
{
	CHECK(context);
	if (!trustedRoots)
		return errSecParam;
	*trustedRoots = CTX(context)->anchors ? CFRetain(CTX(context)->anchors) : NULL;
	return noErr;
}

/* The peer's chain, as certificates (leaf first). */
static CFArrayRef
peer_chain(struct SSLContext *c)
{
	if (!c->ssl)
		return NULL;
	STACK_OF(X509) *chain = SSL_get_peer_cert_chain(c->ssl);
	X509 *leaf = SSL_get0_peer_certificate(c->ssl);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	int n = chain ? sk_X509_num(chain) : 0;
	/* (a server's chain from the client includes the leaf; a client's from the server doesn't) */
	if (leaf && (!n || X509_cmp(leaf, sk_X509_value(chain, 0)) != 0)) {
		unsigned char *der = NULL;
		int len = i2d_X509(leaf, &der);
		CFDataRef d = len > 0 ? CFDataCreate(NULL, der, len) : NULL;
		OPENSSL_free(der);
		SecCertificateRef cert = d ? SecCertificateCreateWithData(NULL, d) : NULL;
		if (cert) {
			CFArrayAppendValue(out, cert);
			CFRelease(cert);
		}
		if (d)
			CFRelease(d);
	}
	for (int i = 0; i < n; i++) {
		unsigned char *der = NULL;
		int len = i2d_X509(sk_X509_value(chain, i), &der);
		CFDataRef d = len > 0 ? CFDataCreate(NULL, der, len) : NULL;
		OPENSSL_free(der);
		SecCertificateRef cert = d ? SecCertificateCreateWithData(NULL, d) : NULL;
		if (cert) {
			CFArrayAppendValue(out, cert);
			CFRelease(cert);
		}
		if (d)
			CFRelease(d);
	}
	if (!CFArrayGetCount(out)) {
		CFRelease(out);
		return NULL;
	}
	return out;
}

SEC_API OSStatus
SSLCopyPeerCertificates(SSLContextRef context, CFArrayRef *certs)
{
	CHECK(context);
	if (!certs)
		return errSecParam;
	*certs = peer_chain(CTX(context));
	return noErr;
}

static SecTrustRef
make_trust(struct SSLContext *c)
{
	CFArrayRef chain = peer_chain(c);
	if (!chain)
		return NULL;
	CFStringRef host = c->peerName ? CFStringCreateWithCString(NULL, c->peerName, kCFStringEncodingUTF8) : NULL;
	SecPolicyRef policy = SecPolicyCreateSSL(c->side == kSSLClientSide, host);
	SecTrustRef trust = NULL;
	SecTrustCreateWithCertificates(chain, policy, &trust);
	if (trust && c->anchors)
		SecTrustSetAnchorCertificates(trust, c->anchors);
	if (policy)
		CFRelease(policy);
	if (host)
		CFRelease(host);
	CFRelease(chain);
	return trust;
}

SEC_API OSStatus
SSLCopyPeerTrust(SSLContextRef context, SecTrustRef *trust)
{
	CHECK(context);
	if (!trust)
		return errSecParam;
	*trust = make_trust(CTX(context));
	return noErr;
}

/* (session resumption keys, ALPN, OCSP, certificate authorities: kept) */
SEC_API OSStatus
SSLSetPeerID(SSLContextRef context, const void *peerID, size_t peerIDLen)
{
	CHECK(context);
	free(CTX(context)->peerID);
	CTX(context)->peerID = peerIDLen ? malloc(peerIDLen) : NULL;
	if (peerIDLen)
		memcpy(CTX(context)->peerID, peerID, peerIDLen);
	CTX(context)->peerIDLength = peerIDLen;
	return noErr;
}

SEC_API OSStatus
SSLGetPeerID(SSLContextRef context, const void **peerID, size_t *peerIDLen)
{
	CHECK(context);
	if (!peerID || !peerIDLen)
		return errSecParam;
	*peerID = CTX(context)->peerID;
	*peerIDLen = CTX(context)->peerIDLength;
	return noErr;
}

SEC_API OSStatus
SSLSetALPNProtocols(SSLContextRef context, CFArrayRef protocols)
{
	CHECK(context);
	if (CTX(context)->alpn)
		CFRelease(CTX(context)->alpn);
	CTX(context)->alpn = protocols ? CFArrayCreateCopy(NULL, protocols) : NULL;
	return noErr;
}

SEC_API OSStatus
SSLCopyALPNProtocols(SSLContextRef context, CFArrayRef *protocols)
{
	CHECK(context);
	if (!protocols)
		return errSecParam;
	struct SSLContext *c = CTX(context);
	const unsigned char *p = NULL;
	unsigned int n = 0;
	if (c->ssl)
		SSL_get0_alpn_selected(c->ssl, &p, &n);
	*protocols = NULL;
	if (n) {
		CFStringRef s = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingUTF8, false);
		*protocols = CFArrayCreate(NULL, (const void **)&s, 1, &kCFTypeArrayCallBacks);
		CFRelease(s);
	}
	return noErr;
}

SEC_API OSStatus SSLSetOCSPResponse(SSLContextRef context, CFDataRef response) { CHECK(context); return noErr; }
SEC_API OSStatus SSLAddDistinguishedName(SSLContextRef context, const void *derDN, size_t derDNLen) { CHECK(context); return noErr; }
SEC_API OSStatus SSLSetCertificateAuthorities(SSLContextRef context, CFTypeRef certificateOrArray, Boolean replaceExisting) { CHECK(context); return noErr; }
SEC_API OSStatus SSLCopyCertificateAuthorities(SSLContextRef context, CFArrayRef *certificates) { CHECK(context); if (certificates) *certificates = NULL; return noErr; }
SEC_API OSStatus SSLCopyDistinguishedNames(SSLContextRef context, CFArrayRef *names) { CHECK(context); if (names) *names = NULL; return noErr; }
SEC_API OSStatus SSLSetDiffieHellmanParams(SSLContextRef context, const void *dhParams, size_t dhParamsLen) { CHECK(context); return noErr; }
SEC_API OSStatus SSLGetDiffieHellmanParams(SSLContextRef context, const void **dhParams, size_t *dhParamsLen) { CHECK(context); if (dhParams) *dhParams = NULL; if (dhParamsLen) *dhParamsLen = 0; return noErr; }
SEC_API OSStatus SSLSetRsaBlinding(SSLContextRef context, Boolean blinding) { CHECK(context); return noErr; }
SEC_API OSStatus SSLGetRsaBlinding(SSLContextRef context, Boolean *blinding) { CHECK(context); if (blinding) *blinding = true; return noErr; }
SEC_API OSStatus SSLSetSessionTicketsEnabled(SSLContextRef context, Boolean enabled) { CHECK(context); CTX(context)->options[kSSLSessionOptionEnableSessionTickets] = enabled; return noErr; }
SEC_API OSStatus SSLSetError(SSLContextRef context, OSStatus status) { CHECK(context); return noErr; }

/* DTLS: not offered. */
SEC_API OSStatus SSLSetDatagramHelloCookie(SSLContextRef dtlsContext, const void *cookie, size_t cookieLen) { return errSSLBadConfiguration; }
SEC_API OSStatus SSLSetMaxDatagramRecordSize(SSLContextRef dtlsContext, size_t maxSize) { return errSSLBadConfiguration; }
SEC_API OSStatus SSLGetMaxDatagramRecordSize(SSLContextRef dtlsContext, size_t *maxSize) { return errSSLBadConfiguration; }
SEC_API OSStatus SSLGetDatagramWriteSize(SSLContextRef dtlsContext, size_t *bufSize) { return errSSLBadConfiguration; }

/* --- cipher suites (their IANA numbers, as Secure Transport's are) --- */

static SSL_CTX *
cipher_ctx(void)
{
	static SSL_CTX *ctx;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		ctx = SSL_CTX_new(TLS_method());
	});
	return ctx;
}

SEC_API OSStatus
SSLGetNumberSupportedCiphers(SSLContextRef context, size_t *numCiphers)
{
	CHECK(context);
	if (!numCiphers)
		return errSecParam;
	STACK_OF(SSL_CIPHER) *all = SSL_CTX_get_ciphers(cipher_ctx());
	*numCiphers = all ? (size_t)sk_SSL_CIPHER_num(all) : 0;
	return noErr;
}

SEC_API OSStatus
SSLGetSupportedCiphers(SSLContextRef context, SSLCipherSuite *ciphers, size_t *numCiphers)
{
	CHECK(context);
	if (!ciphers || !numCiphers)
		return errSecParam;
	STACK_OF(SSL_CIPHER) *all = SSL_CTX_get_ciphers(cipher_ctx());
	size_t n = all ? (size_t)sk_SSL_CIPHER_num(all) : 0;
	if (*numCiphers < n)
		return errSSLBufferOverflow;
	for (size_t i = 0; i < n; i++)
		ciphers[i] = (SSLCipherSuite)SSL_CIPHER_get_protocol_id(sk_SSL_CIPHER_value(all, (int)i));
	*numCiphers = n;
	return noErr;
}

SEC_API OSStatus
SSLSetEnabledCiphers(SSLContextRef context, const SSLCipherSuite *ciphers, size_t numCiphers)
{
	CHECK(context);
	free(CTX(context)->enabled);
	CTX(context)->enabled = numCiphers ? malloc(numCiphers * sizeof(SSLCipherSuite)) : NULL;
	if (numCiphers)
		memcpy(CTX(context)->enabled, ciphers, numCiphers * sizeof(SSLCipherSuite));
	CTX(context)->enabledCount = numCiphers;
	return noErr;
}

SEC_API OSStatus
SSLGetNumberEnabledCiphers(SSLContextRef context, size_t *numCiphers)
{
	CHECK(context);
	if (!numCiphers)
		return errSecParam;
	if (CTX(context)->enabled)
		*numCiphers = CTX(context)->enabledCount;
	else
		return SSLGetNumberSupportedCiphers(context, numCiphers);
	return noErr;
}

SEC_API OSStatus
SSLGetEnabledCiphers(SSLContextRef context, SSLCipherSuite *ciphers, size_t *numCiphers)
{
	CHECK(context);
	if (!CTX(context)->enabled)
		return SSLGetSupportedCiphers(context, ciphers, numCiphers);
	if (!ciphers || !numCiphers)
		return errSecParam;
	if (*numCiphers < CTX(context)->enabledCount)
		return errSSLBufferOverflow;
	memcpy(ciphers, CTX(context)->enabled, CTX(context)->enabledCount * sizeof(SSLCipherSuite));
	*numCiphers = CTX(context)->enabledCount;
	return noErr;
}

SEC_API OSStatus
SSLGetNegotiatedCipher(SSLContextRef context, SSLCipherSuite *cipherSuite)
{
	CHECK(context);
	if (!cipherSuite)
		return errSecParam;
	const SSL_CIPHER *c = CTX(context)->ssl ? SSL_get_current_cipher(CTX(context)->ssl) : NULL;
	*cipherSuite = c ? (SSLCipherSuite)SSL_CIPHER_get_protocol_id(c) : SSL_NULL_WITH_NULL_NULL;
	return c ? noErr : errSecBadReq;
}

/* The OpenSSL cipher lists for enabled IANA suites (TLS 1.2 names, TLS 1.3 suites). */
static void
apply_ciphers(struct SSLContext *c)
{
	if (!c->enabled)
		return;
	STACK_OF(SSL_CIPHER) *all = SSL_CTX_get_ciphers(cipher_ctx());
	char list12[4096] = "", list13[1024] = "";
	for (size_t i = 0; i < c->enabledCount; i++)
		for (int k = 0; all && k < sk_SSL_CIPHER_num(all); k++) {
			const SSL_CIPHER *sc = sk_SSL_CIPHER_value(all, k);
			if (SSL_CIPHER_get_protocol_id(sc) != c->enabled[i])
				continue;
			bool v13 = !strcmp(SSL_CIPHER_get_version(sc), "TLSv1.3");
			char *list = v13 ? list13 : list12;
			size_t size = v13 ? sizeof list13 : sizeof list12;
			if (*list)
				strlcat(list, ":", size);
			strlcat(list, SSL_CIPHER_get_name(sc), size);
		}
	if (*list12)
		SSL_set_cipher_list(c->ssl, list12);
	if (*list13)
		SSL_set_ciphersuites(c->ssl, list13);
}

static int
client_certificate(SSL *ssl, X509 **certificate, EVP_PKEY **privateKey)
{
	struct SSLContext *c = SSL_get_app_data(ssl);
	if (!c || !c->clientIdentityCallback)
		return 0;
	CFArrayRef certificates = NULL;
	OSStatus status = c->clientIdentityCallback((SSLContextRef)c, &certificates, c->clientIdentityContext);
	if (status != noErr || !certificates || CFArrayGetCount(certificates) == 0) {
		if (certificates)
			CFRelease(certificates);
		return 0;
	}
	CFTypeRef first = CFArrayGetValueAtIndex(certificates, 0);
	SecCertificateRef cert = NULL;
	SecKeyRef key = NULL;
	if (first && CFGetTypeID(first) == SecIdentityGetTypeID()) {
		SecIdentityCopyCertificate((SecIdentityRef)first, &cert);
		SecIdentityCopyPrivateKey((SecIdentityRef)first, &key);
	}
	X509 *x509 = cert ? _SecCertificateGetX509(cert) : NULL;
	EVP_PKEY *pkey = key ? _SecKeyGetEVP(key) : NULL;
	int result = 0;
	if (x509 && pkey && X509_up_ref(x509) == 1) {
		if (EVP_PKEY_up_ref(pkey) == 1) {
			*certificate = x509;
			*privateKey = pkey;
			for (CFIndex i = 1; i < CFArrayGetCount(certificates); i++) {
				CFTypeRef item = CFArrayGetValueAtIndex(certificates, i);
				if (item && CFGetTypeID(item) == SecCertificateGetTypeID())
					SSL_add1_chain_cert(ssl, _SecCertificateGetX509((SecCertificateRef)item));
			}
			result = 1;
		} else {
			X509_free(x509);
		}
	}
	if (cert)
		CFRelease(cert);
	if (key)
		CFRelease(key);
	CFRelease(certificates);
	return result;
}

static int
select_alpn(SSL *ssl, const unsigned char **out, unsigned char *outLength,
	const unsigned char *offered, unsigned int offeredLength, void *context)
{
	struct SSLContext *c = context;
	if (!c || !c->alpn || CFArrayGetCount(c->alpn) == 0)
		return SSL_TLSEXT_ERR_NOACK;
	unsigned char supported[1024];
	size_t at = 0;
	for (CFIndex i = 0; i < CFArrayGetCount(c->alpn); i++) {
		char protocol[256];
		if (!CFStringGetCString(CFArrayGetValueAtIndex(c->alpn, i), protocol, sizeof(protocol),
		    kCFStringEncodingUTF8))
			continue;
		size_t length = strlen(protocol);
		if (!length || length > 255 || at + length + 1 > sizeof(supported))
			continue;
		supported[at++] = (unsigned char)length;
		memcpy(supported + at, protocol, length);
		at += length;
	}
	unsigned char *selected = NULL;
	unsigned char selectedLength = 0;
	int status = SSL_select_next_proto(&selected, &selectedLength, supported, (unsigned int)at,
	    offered, offeredLength);
	if (status != OPENSSL_NPN_NEGOTIATED)
		return SSL_TLSEXT_ERR_NOACK;
	*out = selected;
	*outLength = selectedLength;
	return SSL_TLSEXT_ERR_OK;
}

/* --- the connection --- */

static OSStatus
setup(struct SSLContext *c)
{
	if (c->ssl)
		return noErr;
	if (!io_method) {
		BIO_METHOD *m = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "SecureTransport");
		BIO_meth_set_read(m, io_read);
		BIO_meth_set_write(m, io_write);
		BIO_meth_set_ctrl(m, io_ctrl);
		BIO_meth_set_create(m, io_create);
		io_method = m;
	}
	c->ctx = SSL_CTX_new(c->side == kSSLServerSide ? TLS_server_method() : TLS_client_method());
	if (!c->ctx)
		return errSSLInternal;
	SSL_CTX_set_min_proto_version(c->ctx, openssl_version(c->minVersion));
	SSL_CTX_set_max_proto_version(c->ctx, openssl_version(c->maxVersion));
	if (!c->renegotiationEnabled)
		SSL_CTX_set_options(c->ctx, SSL_OP_NO_RENEGOTIATION);
	/* (the peer is judged by SecTrust when the handshake is done) */
	SSL_CTX_set_verify(c->ctx, SSL_VERIFY_NONE, NULL);
	if (!c->options[kSSLSessionOptionEnableSessionTickets])
		SSL_CTX_set_options(c->ctx, SSL_OP_NO_TICKET);
	if (c->side == kSSLServerSide && c->alpn)
		SSL_CTX_set_alpn_select_cb(c->ctx, select_alpn, c);
	if (c->clientIdentityCallback)
		SSL_CTX_set_client_cert_cb(c->ctx, client_certificate);
	c->ssl = SSL_new(c->ctx);
	if (!c->ssl)
		return errSSLInternal;
	if (c->side == kSSLServerSide && c->clientAuth != kNeverAuthenticate)
		SSL_set_verify(c->ssl, SSL_VERIFY_PEER | (c->clientAuth == kAlwaysAuthenticate ? SSL_VERIFY_FAIL_IF_NO_PEER_CERT : 0),
		               NULL);
	if (c->side == kSSLServerSide && c->clientAuth != kNeverAuthenticate)
		SSL_set_verify_result(c->ssl, X509_V_OK);
	SSL_set_app_data(c->ssl, c);
	if (c->fallbackAttempt)
		SSL_set_mode(c->ssl, SSL_MODE_SEND_FALLBACK_SCSV);
	apply_ciphers(c);
	if (c->peerName && c->side == kSSLClientSide)
		SSL_set_tlsext_host_name(c->ssl, c->peerName);
	if (c->side == kSSLClientSide && c->alpn && CFArrayGetCount(c->alpn)) {
		unsigned char wire[1024];
		size_t at = 0;
		for (CFIndex i = 0; i < CFArrayGetCount(c->alpn); i++) {
			char p[256];
			if (!CFStringGetCString(CFArrayGetValueAtIndex(c->alpn, i), p, sizeof p, kCFStringEncodingUTF8))
				continue;
			size_t n = strlen(p);
			if (!n || at + n + 1 > sizeof wire)
				continue;
			wire[at++] = (unsigned char)n;
			memcpy(wire + at, p, n);
			at += n;
		}
		if (at)
			SSL_set_alpn_protos(c->ssl, wire, (unsigned)at);
	}
	/* our certificate: the identity's, then the intermediates */
	if (c->certificates && CFArrayGetCount(c->certificates)) {
		CFTypeRef first = CFArrayGetValueAtIndex(c->certificates, 0);
		if (CFGetTypeID(first) == SecIdentityGetTypeID()) {
			SecCertificateRef cert = NULL;
			SecKeyRef key = NULL;
			SecIdentityCopyCertificate((SecIdentityRef)first, &cert);
			SecIdentityCopyPrivateKey((SecIdentityRef)first, &key);
			if (cert && key) {
				SSL_use_certificate(c->ssl, _SecCertificateGetX509(cert));
				SSL_use_PrivateKey(c->ssl, _SecKeyGetEVP(key));
			}
			if (cert)
				CFRelease(cert);
			if (key)
				CFRelease(key);
			for (CFIndex i = 1; i < CFArrayGetCount(c->certificates); i++) {
				CFTypeRef o = CFArrayGetValueAtIndex(c->certificates, i);
				if (CFGetTypeID(o) == SecCertificateGetTypeID())
					SSL_add1_chain_cert(c->ssl, _SecCertificateGetX509((SecCertificateRef)o));
			}
		}
	} else if (c->side == kSSLServerSide) {
		return errSSLBadConfiguration;
	}
	BIO *bio = BIO_new(io_method);
	BIO_set_data(bio, c);
	SSL_set_bio(c->ssl, bio, bio);
	if (c->side == kSSLServerSide)
		SSL_set_accept_state(c->ssl);
	else
		SSL_set_connect_state(c->ssl);
	return noErr;
}

/* What an OpenSSL result is as a Secure Transport status. */
static OSStatus
status_of(struct SSLContext *c, int r)
{
	int e = SSL_get_error(c->ssl, r);
	switch (e) {
	case SSL_ERROR_NONE: return noErr;
	case SSL_ERROR_WANT_READ:
	case SSL_ERROR_WANT_WRITE: return errSSLWouldBlock;
	case SSL_ERROR_ZERO_RETURN: return errSSLClosedGraceful;
	case SSL_ERROR_SYSCALL:
		ERR_clear_error();
		if (c->ioStatus && c->ioStatus != errSSLWouldBlock)
			return c->ioStatus;
		return errSSLClosedAbort;
	default: {
		unsigned long err = ERR_get_error();
		ERR_clear_error();
		int reason = ERR_GET_REASON(err);
		if (reason == SSL_R_UNSUPPORTED_PROTOCOL || reason == SSL_R_WRONG_VERSION_NUMBER || reason == SSL_R_TLSV1_ALERT_PROTOCOL_VERSION)
			return errSSLPeerProtocolVersion;
		if (reason == SSL_R_NO_SHARED_CIPHER || reason == SSL_R_SSLV3_ALERT_HANDSHAKE_FAILURE)
			return errSSLPeerHandshakeFail;
		if (reason == SSL_R_TLSV1_ALERT_UNKNOWN_CA)
			return errSSLPeerUnknownCA;
		if (reason == SSL_R_SSLV3_ALERT_BAD_CERTIFICATE)
			return errSSLPeerBadCert;
		return errSSLProtocol;
	}
	}
}

/* The peer's certificates judged as Secure Transport judges them. */
static OSStatus
judge_peer(struct SSLContext *c)
{
	if (!c->verify || c->allowAnyRoot)
		return noErr;
	if (c->side == kSSLServerSide && c->clientAuth == kNeverAuthenticate)
		return noErr;
	SecTrustRef trust = make_trust(c);
	if (!trust)
		return c->side == kSSLServerSide && c->clientAuth != kAlwaysAuthenticate ? noErr : errSSLXCertChainInvalid;
	CFErrorRef error = NULL;
	bool ok = SecTrustEvaluateWithError(trust, &error);
	OSStatus st = noErr;
	if (!ok) {
		CFIndex code = error ? CFErrorGetCode(error) : 0;
		st = code == errSecCertificateExpired ? errSSLCertExpired
		     : code == errSecHostNameMismatch ? errSSLHostNameMismatch
		     : code == errSecNotTrusted       ? errSSLUnknownRootCert
		                                      : errSSLXCertChainInvalid;
		if (st == errSSLCertExpired && c->allowExpired)
			st = noErr;
	}
	if (error)
		CFRelease(error);
	CFRelease(trust);
	return st;
}

SEC_API OSStatus
SSLHandshake(SSLContextRef context)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	if (c->state == kSSLClosed || c->state == kSSLAborted)
		return errSSLClosedAbort;
	if (c->state == kSSLConnected)
		return noErr;
	OSStatus st = setup(c);
	if (st)
		return st;
	c->state = kSSLHandshake;
	if (!SSL_is_init_finished(c->ssl)) {
		int r = SSL_do_handshake(c->ssl);
		if (r != 1) {
			st = status_of(c, r);
			if (st != errSSLWouldBlock)
				c->state = kSSLAborted;
			return st;
		}
	}
	/* done: the peer's certificates, judged by the caller (asked to break) or here */
	bool asked = c->side == kSSLClientSide ? c->options[kSSLSessionOptionBreakOnServerAuth]
	                                       : c->options[kSSLSessionOptionBreakOnClientAuth];
	if (asked && !c->authReported) {
		c->authReported = true;
		return errSSLPeerAuthCompleted;
	}
	if (!asked && (st = judge_peer(c))) {
		c->state = kSSLAborted;
		return st;
	}
	c->state = kSSLConnected;
	return noErr;
}

SEC_API OSStatus SSLReHandshake(SSLContextRef context) { CHECK(context); return errSecUnimplemented; }

SEC_API OSStatus
SSLWrite(SSLContextRef context, const void *data, size_t dataLength, size_t *processed)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	if (processed)
		*processed = 0;
	if (c->state != kSSLConnected) {
		OSStatus st = SSLHandshake(context);
		if (st)
			return st == errSSLPeerAuthCompleted ? errSSLWouldBlock : st;
	}
	size_t done = 0;
	while (done < dataLength) {
		size_t n = 0;
		int r = SSL_write_ex(c->ssl, (const char *)data + done, dataLength - done, &n);
		if (r != 1) {
			if (processed)
				*processed = done;
			OSStatus st = status_of(c, r);
			if (st != errSSLWouldBlock)
				c->state = kSSLAborted;
			return st;
		}
		done += n;
	}
	if (processed)
		*processed = done;
	return noErr;
}

SEC_API OSStatus
SSLRead(SSLContextRef context, void *data, size_t dataLength, size_t *processed)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	if (processed)
		*processed = 0;
	if (c->state == kSSLClosed)
		return errSSLClosedGraceful;
	if (c->state != kSSLConnected) {
		OSStatus st = SSLHandshake(context);
		if (st)
			return st == errSSLPeerAuthCompleted ? errSSLWouldBlock : st;
	}
	size_t done = 0;
	while (done < dataLength) {
		size_t n = 0;
		int r = SSL_read_ex(c->ssl, (char *)data + done, dataLength - done, &n);
		if (r != 1) {
			if (processed)
				*processed = done;
			OSStatus st = status_of(c, r);
			if (st == errSSLClosedGraceful)
				c->state = kSSLClosed;
			else if (st != errSSLWouldBlock)
				c->state = kSSLAborted;
			return st;
		}
		done += n;
	}
	if (processed)
		*processed = done;
	return noErr;
}

SEC_API OSStatus
SSLGetBufferedReadSize(SSLContextRef context, size_t *bufferSize)
{
	CHECK(context);
	if (!bufferSize)
		return errSecParam;
	*bufferSize = CTX(context)->ssl ? (size_t)SSL_pending(CTX(context)->ssl) : 0;
	return noErr;
}

SEC_API OSStatus
SSLClose(SSLContextRef context)
{
	CHECK(context);
	struct SSLContext *c = CTX(context);
	if (c->ssl && c->state == kSSLConnected)
		SSL_shutdown(c->ssl);
	c->state = kSSLClosed;
	return noErr;
}

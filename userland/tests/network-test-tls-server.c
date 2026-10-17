/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A local OpenSSL server for the Network.framework comparison test. */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static int serverSocket = -1;
static pthread_t serverThread;
static SSL_CTX *serverContext;

static int selectALPN(SSL *ssl, const unsigned char **selected, unsigned char *selectedLength,
	const unsigned char *offered, unsigned int offeredLength, void *context)
{
	(void)ssl;
	(void)context;
	static const unsigned char supported[] = {2, 'h', '2'};
	return SSL_select_next_proto((unsigned char **)selected, selectedLength, supported, sizeof(supported),
	    offered, offeredLength) == OPENSSL_NPN_NEGOTIATED ? SSL_TLSEXT_ERR_OK : SSL_TLSEXT_ERR_NOACK;
}

static void serveConnection(int fd)
{
	SSL *connection = SSL_new(serverContext);
	if (!connection)
		return;
	BIO *bio = BIO_new_fd(fd, BIO_NOCLOSE);
	if (!bio) {
		SSL_free(connection);
		return;
	}
	SSL_set_bio(connection, bio, bio);
	if (SSL_accept(connection) == 1) {
		unsigned char bytes[64];
		int count = SSL_read(connection, bytes, sizeof(bytes));
		if (count > 0)
			(void)SSL_write(connection, bytes, count);
	}
	SSL_shutdown(connection);
	SSL_free(connection);
}

static void *serve(void *unused)
{
	(void)unused;
	for (int connection = 0; connection < 3; connection++) {
		int fd;
		do {
			fd = accept(serverSocket, NULL, NULL);
		} while (fd < 0 && errno == EINTR);
		if (fd < 0)
			break;
		serveConnection(fd);
		close(fd);
	}
	close(serverSocket);
	serverSocket = -1;
	return NULL;
}

static int makeServerContext(void)
{
	EVP_PKEY_CTX *keyContext = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
	EVP_PKEY *privateKey = NULL;
	X509 *certificate = X509_new();
	if (!keyContext || EVP_PKEY_keygen_init(keyContext) <= 0 ||
	    EVP_PKEY_CTX_set_rsa_keygen_bits(keyContext, 2048) <= 0 ||
	    EVP_PKEY_keygen(keyContext, &privateKey) <= 0 || !certificate) {
		if (certificate)
			X509_free(certificate);
		if (privateKey)
			EVP_PKEY_free(privateKey);
		if (keyContext)
			EVP_PKEY_CTX_free(keyContext);
		return 0;
	}
	X509_set_version(certificate, 2);
	ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1);
	X509_gmtime_adj(X509_getm_notBefore(certificate), -60);
	X509_gmtime_adj(X509_getm_notAfter(certificate), 3600);
	X509_set_pubkey(certificate, privateKey);
	X509_NAME *name = X509_get_subject_name(certificate);
	X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)"localhost", -1, -1, 0);
	X509_set_issuer_name(certificate, name);
	X509_EXTENSION *subjectAltName = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, "DNS:localhost");
	X509_EXTENSION *basicConstraints = X509V3_EXT_conf_nid(NULL, NULL, NID_basic_constraints, "critical,CA:TRUE");
	X509_EXTENSION *keyUsage = X509V3_EXT_conf_nid(NULL, NULL, NID_key_usage,
	    "critical,digitalSignature,keyEncipherment,keyCertSign");
	X509_EXTENSION *extendedKeyUsage = X509V3_EXT_conf_nid(NULL, NULL, NID_ext_key_usage, "serverAuth");
	if (subjectAltName)
		X509_add_ext(certificate, subjectAltName, -1);
	if (basicConstraints)
		X509_add_ext(certificate, basicConstraints, -1);
	if (keyUsage)
		X509_add_ext(certificate, keyUsage, -1);
	if (extendedKeyUsage)
		X509_add_ext(certificate, extendedKeyUsage, -1);
	if (subjectAltName)
		X509_EXTENSION_free(subjectAltName);
	if (basicConstraints)
		X509_EXTENSION_free(basicConstraints);
	if (keyUsage)
		X509_EXTENSION_free(keyUsage);
	if (extendedKeyUsage)
		X509_EXTENSION_free(extendedKeyUsage);
	int signedCertificate = X509_sign(certificate, privateKey, EVP_sha256()) > 0;
	serverContext = SSL_CTX_new(TLS_server_method());
	int ok = signedCertificate && serverContext &&
	    SSL_CTX_use_certificate(serverContext, certificate) == 1 &&
	    SSL_CTX_use_PrivateKey(serverContext, privateKey) == 1 &&
	    SSL_CTX_check_private_key(serverContext) == 1 &&
	    SSL_CTX_set_min_proto_version(serverContext, TLS1_2_VERSION) == 1 &&
	    SSL_CTX_set_max_proto_version(serverContext, TLS1_2_VERSION) == 1;
	if (ok) {
		SSL_CTX_set_verify(serverContext, SSL_VERIFY_NONE, NULL);
		SSL_CTX_set_alpn_select_cb(serverContext, selectALPN, NULL);
	}
	if (certificate)
		X509_free(certificate);
	if (privateKey)
		EVP_PKEY_free(privateKey);
	EVP_PKEY_CTX_free(keyContext);
	return ok;
}

int finch_test_tls_server_start(uint16_t *port)
{
	if (!port || !makeServerContext())
		return -1;
	serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (serverSocket < 0)
		return -1;
	struct sockaddr_in address = {0};
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(serverSocket, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(serverSocket, 4) != 0) {
		close(serverSocket);
		serverSocket = -1;
		return -1;
	}
	socklen_t length = sizeof(address);
	if (getsockname(serverSocket, (struct sockaddr *)&address, &length) != 0) {
		close(serverSocket);
		serverSocket = -1;
		return -1;
	}
	*port = ntohs(address.sin_port);
	if (pthread_create(&serverThread, NULL, serve, NULL) != 0) {
		close(serverSocket);
		serverSocket = -1;
		return -1;
	}
	return 0;
}

void finch_test_tls_server_wait(void)
{
	pthread_join(serverThread, NULL);
	if (serverContext) {
		SSL_CTX_free(serverContext);
		serverContext = NULL;
	}
}

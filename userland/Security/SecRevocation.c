/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Revocation checks, for trusts with a revocation policy
 * (SecPolicyCreateRevocation), as macOS checks them: each certificate in the
 * built chain but the anchor, by OCSP (a response stapled to the trust first,
 * then the responder its Authority Information Access names) and by its CRL
 * distribution points, in the order the policy's flags ask
 * (kSecRevocationPreferCRL puts CRLs first). Responses are checked: an OCSP
 * response's signature against the issuer (or a responder it certified) and
 * its validity period, a CRL's signature against the issuer and its next
 * update. A revoked certificate fails the chain (errSecCertificateRevoked).
 * With no answer the chain passes unless the policy requires a positive one
 * (kSecRevocationRequirePositiveResponse: errSecIncompleteCertRevocationCheck).
 * Fetching uses plain HTTP/1.0, as OCSP and CRLs do (with a small client here:
 * Finch's OpenSSL is built without sockets), bounded in time and size, and is
 * skipped where the trust or the policy disallows the network.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <openssl/err.h>
#include <openssl/http.h>
#include <openssl/ocsp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "SecInternal.h"

#define FETCH_TIMEOUT 10	/* seconds a responder or CRL server gets */
#define FETCH_MAX (4 << 20)

enum { UNKNOWN, GOOD, REVOKED };

SEC_HIDDEN OSStatus _FinchCheckRevocation(STACK_OF(X509) *chain, CFOptionFlags flags, bool networkAllowed,
    CFArrayRef stapled, time_t when);

/* ---- fetching (plain HTTP/1.0; Finch's OpenSSL is built without sockets) ---- */

static bool waitFor(int fd, short events, time_t deadline)
{
    struct pollfd p = { fd, events, 0 };
    int left = (int)(deadline - time(NULL));
    return left > 0 && poll(&p, 1, left * 1000) == 1 && (p.revents & events);
}

/* GET (no body) or POST a body to an http:// URL: the response body on a 200, else NULL. */
static BIO *httpFetch(const char *url, const char *contentType, const unsigned char *body, size_t bodyLength)
{
    char *host = NULL, *port = NULL, *path = NULL, *query = NULL;
    int ssl = 0;
    BIO *out = NULL;
    int fd = -1;
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *addrs = NULL;
    time_t deadline = time(NULL) + FETCH_TIMEOUT;
    unsigned char *reply = NULL;
    size_t used = 0;

    if (OSSL_HTTP_parse_url(url, &ssl, NULL, &host, &port, NULL, &path, &query, NULL) != 1 || ssl ||
        getaddrinfo(host, port, &hints, &addrs) != 0)
        goto done;
    for (struct addrinfo *a = addrs; a && fd < 0; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0)
            continue;
        int flags = fcntl(fd, F_GETFL);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        if (connect(fd, a->ai_addr, a->ai_addrlen) != 0 &&
            (errno != EINPROGRESS || !waitFor(fd, POLLOUT, deadline))) {
            close(fd);
            fd = -1;
            continue;
        }
        int error = 0;
        socklen_t len = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) != 0 || error != 0) {
            close(fd);
            fd = -1;
        }
    }
    if (fd < 0)
        goto done;
    char head[2048];
    int n = body ? snprintf(head, sizeof(head),
        "POST %s%s%s HTTP/1.0\r\nHost: %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n\r\n",
        path, query ? "?" : "", query ? query : "", host, contentType, bodyLength) :
        snprintf(head, sizeof(head), "GET %s%s%s HTTP/1.0\r\nHost: %s\r\n\r\n", path, query ? "?" : "",
        query ? query : "", host);
    if (n <= 0 || (size_t)n >= sizeof(head))
        goto done;
    const unsigned char *parts[2] = { (const unsigned char *)head, body };
    size_t lengths[2] = { (size_t)n, body ? bodyLength : 0 };
    for (int i = 0; i < 2; i++)
        for (size_t sent = 0; sent < lengths[i];) {
            if (!waitFor(fd, POLLOUT, deadline))
                goto done;
            ssize_t w = write(fd, parts[i] + sent, lengths[i] - sent);
            if (w <= 0)
                goto done;
            sent += (size_t)w;
        }
    reply = malloc(FETCH_MAX);
    while (reply && used < FETCH_MAX && waitFor(fd, POLLIN, deadline)) {
        ssize_t got = read(fd, reply + used, FETCH_MAX - used);
        if (got <= 0)
            break;
        used += (size_t)got;
    }
    /* "HTTP/1.x 200 ...", headers, a blank line, the body. */
    if (reply && used > 12 && memcmp(reply, "HTTP/1.", 7) == 0 && memcmp(reply + 8, " 200", 4) == 0) {
        for (size_t i = 0; i + 3 < used; i++)
            if (memcmp(reply + i, "\r\n\r\n", 4) == 0) {
                out = BIO_new(BIO_s_mem());
                if (out)
                    BIO_write(out, reply + i + 4, (int)(used - i - 4));
                break;
            }
    }
done:
    free(reply);
    if (fd >= 0)
        close(fd);
    if (addrs)
        freeaddrinfo(addrs);
    OPENSSL_free(host);
    OPENSSL_free(port);
    OPENSSL_free(path);
    OPENSSL_free(query);
    return out;
}

/* ---- OCSP ---- */

static int ocspAnswer(OCSP_RESPONSE *response, OCSP_CERTID *id, STACK_OF(X509) *chain, X509 *issuer, time_t when)
{
    int answer = UNKNOWN;
    if (OCSP_response_status(response) != OCSP_RESPONSE_STATUS_SUCCESSFUL)
        return UNKNOWN;
    OCSP_BASICRESP *basic = OCSP_response_get1_basic(response);
    if (!basic)
        return UNKNOWN;
    /* Signed by the issuer, or by a responder the issuer certified for it. */
    X509_STORE *store = X509_STORE_new();
    X509_STORE_add_cert(store, issuer);
    for (int i = 0; i < sk_X509_num(chain); i++)
        X509_STORE_add_cert(store, sk_X509_value(chain, i));
    X509_VERIFY_PARAM *param = X509_STORE_get0_param(store);
    X509_VERIFY_PARAM_set_time(param, when);
    if (OCSP_basic_verify(basic, chain, store, 0) == 1) {
        int status = -1, reason = 0;
        ASN1_GENERALIZEDTIME *revoked = NULL, *thisUpdate = NULL, *nextUpdate = NULL;
        if (OCSP_resp_find_status(basic, id, &status, &reason, &revoked, &thisUpdate, &nextUpdate) == 1 &&
            OCSP_check_validity(thisUpdate, nextUpdate, 300, -1) == 1) {
            if (status == V_OCSP_CERTSTATUS_GOOD)
                answer = GOOD;
            else if (status == V_OCSP_CERTSTATUS_REVOKED)
                answer = REVOKED;
        }
    }
    ERR_clear_error();
    X509_STORE_free(store);
    OCSP_BASICRESP_free(basic);
    return answer;
}

static int ocspCheck(X509 *cert, X509 *issuer, STACK_OF(X509) *chain, bool network, CFArrayRef stapled, time_t when)
{
    OCSP_CERTID *id = OCSP_cert_to_id(NULL, cert, issuer);
    if (!id)
        return UNKNOWN;
    int answer = UNKNOWN;
    for (CFIndex i = 0; stapled && answer == UNKNOWN && i < CFArrayGetCount(stapled); i++) {
        CFDataRef data = CFArrayGetValueAtIndex(stapled, i);
        if (CFGetTypeID(data) != CFDataGetTypeID())
            continue;
        const unsigned char *p = CFDataGetBytePtr(data);
        OCSP_RESPONSE *response = d2i_OCSP_RESPONSE(NULL, &p, CFDataGetLength(data));
        if (response) {
            answer = ocspAnswer(response, id, chain, issuer, when);
            OCSP_RESPONSE_free(response);
        }
    }
    STACK_OF(OPENSSL_STRING) *urls = network && answer == UNKNOWN ? X509_get1_ocsp(cert) : NULL;
    for (int u = 0; urls && answer == UNKNOWN && u < sk_OPENSSL_STRING_num(urls); u++) {
        OCSP_REQUEST *request = OCSP_REQUEST_new();
        unsigned char *der = NULL;
        int length;
        if (request && OCSP_request_add0_id(request, OCSP_CERTID_dup(id)) &&
            (length = i2d_OCSP_REQUEST(request, &der)) > 0) {
            BIO *reply = httpFetch(sk_OPENSSL_STRING_value(urls, u), "application/ocsp-request", der,
                (size_t)length);
            OCSP_RESPONSE *response = reply ? d2i_OCSP_RESPONSE_bio(reply, NULL) : NULL;
            if (response) {
                answer = ocspAnswer(response, id, chain, issuer, when);
                OCSP_RESPONSE_free(response);
            }
            BIO_free(reply);
        }
        OPENSSL_free(der);
        OCSP_REQUEST_free(request);
        ERR_clear_error();
    }
    X509_email_free(urls);
    OCSP_CERTID_free(id);
    return answer;
}

/* ---- CRLs ---- */

static int crlCheck(X509 *cert, X509 *issuer, bool network, time_t when)
{
    if (!network)
        return UNKNOWN;
    STACK_OF(DIST_POINT) *points = X509_get_ext_d2i(cert, NID_crl_distribution_points, NULL, NULL);
    int answer = UNKNOWN;
    for (int i = 0; points && answer == UNKNOWN && i < sk_DIST_POINT_num(points); i++) {
        DIST_POINT *point = sk_DIST_POINT_value(points, i);
        if (!point->distpoint || point->distpoint->type != 0)
            continue;
        GENERAL_NAMES *names = point->distpoint->name.fullname;
        for (int n = 0; answer == UNKNOWN && n < sk_GENERAL_NAME_num(names); n++) {
            GENERAL_NAME *name = sk_GENERAL_NAME_value(names, n);
            if (name->type != GEN_URI)
                continue;
            const char *url = (const char *)ASN1_STRING_get0_data(name->d.uniformResourceIdentifier);
            if (strncmp(url, "http://", 7) != 0)
                continue;
            BIO *reply = httpFetch(url, NULL, NULL, 0);
            X509_CRL *crl = reply ? d2i_X509_CRL_bio(reply, NULL) : NULL;
            BIO_free(reply);
            /* The issuer's, signed by it, and current. */
            if (crl && X509_NAME_cmp(X509_CRL_get_issuer(crl), X509_get_subject_name(issuer)) == 0 &&
                X509_CRL_verify(crl, X509_get0_pubkey(issuer)) == 1 &&
                X509_cmp_time(X509_CRL_get0_lastUpdate(crl), &when) <= 0 &&
                (!X509_CRL_get0_nextUpdate(crl) || X509_cmp_time(X509_CRL_get0_nextUpdate(crl), &when) > 0)) {
                X509_REVOKED *entry = NULL;
                answer = X509_CRL_get0_by_cert(crl, &entry, cert) == 1 ? REVOKED : GOOD;
            }
            X509_CRL_free(crl);
            ERR_clear_error();
        }
    }
    sk_DIST_POINT_pop_free(points, DIST_POINT_free);
    return answer;
}

OSStatus _FinchCheckRevocation(STACK_OF(X509) *chain, CFOptionFlags flags, bool networkAllowed,
    CFArrayRef stapled, time_t when)
{
    bool ocsp = (flags & kSecRevocationOCSPMethod) || !(flags & kSecRevocationCRLMethod);
    bool crl = (flags & kSecRevocationCRLMethod) != 0;
    bool network = networkAllowed && !(flags & kSecRevocationNetworkAccessDisabled);
    bool crlFirst = (flags & kSecRevocationPreferCRL) != 0;
    /* Every certificate but the anchor, checked against its issuer. */
    for (int i = 0; i + 1 < sk_X509_num(chain); i++) {
        X509 *cert = sk_X509_value(chain, i), *issuer = sk_X509_value(chain, i + 1);
        int answer = UNKNOWN;
        for (int pass = 0; pass < 2 && answer == UNKNOWN; pass++) {
            bool useCRL = (pass == 0) == crlFirst;
            if (useCRL && crl)
                answer = crlCheck(cert, issuer, network, when);
            else if (!useCRL && ocsp)
                answer = ocspCheck(cert, issuer, chain, network, i == 0 ? stapled : NULL, when);
        }
        if (answer == REVOKED)
            return errSecCertificateRevoked;
        if (answer == UNKNOWN && (flags & kSecRevocationRequirePositiveResponse))
            return errSecIncompleteCertRevocationCheck;
    }
    return errSecSuccess;
}

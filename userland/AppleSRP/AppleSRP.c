/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppleSRP (private), Finch's own: the SRP-6a client with the API of Tom Wu's libsrp, which
 * Apple's framework carries (AirPort Utility signs in to base stations with it). The
 * protocol is RFC 5054's with SHA-1:
 *   x = H(salt | H(user ":" password)),  A = g^a mod N,  k = H(N | PAD(g)),
 *   u = H(PAD(A) | PAD(B)),  S = (B - k g^x)^(a + u x) mod N,  K = H(S),
 *   M1 = H(H(N) xor H(g) | H(user) | salt | A | B | K),  M2 = H(A | M1 | K).
 * Big numbers are OpenSSL's (the corecrypto build's), linked in with their symbols hidden.
 */
#include <openssl/bn.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <stdlib.h>
#include <string.h>

#define SRP_EXPORT __attribute__((visibility("default")))
#define SRP_SUCCESS 0
#define SRP_ERROR (-1)

/* libsrp's counted string; callers read data and length */
typedef struct cstr_st {
    char *data;
    int length;
    int cap;
    int ref;
    void *allocator;
} cstr;

typedef struct srp_method_st {
    const char *name;
} SRP_METHOD;

typedef struct srp_st {
    const SRP_METHOD *meth;
    char *username, *password;
    BIGNUM *N, *g, *a, *A, *x, *B;
    unsigned char *salt;
    int saltlen;
    unsigned char K[SHA_DIGEST_LENGTH];
    unsigned char M1[SHA_DIGEST_LENGTH];
    int haveKey;
    BN_CTX *ctx;
} SRP;

static const SRP_METHOD client6a = {"SRP-6a client (Finch)"};

SRP_EXPORT SRP_METHOD *
SRP6a_client_method(void)
{
    return (SRP_METHOD *)&client6a;
}

static cstr *
cstr_with(const unsigned char *bytes, int len)
{
    cstr *s = calloc(1, sizeof *s);
    s->data = malloc(len > 0 ? (size_t)len : 1);
    if (len > 0)
        memcpy(s->data, bytes, (size_t)len);
    s->length = s->cap = len;
    s->ref = 1;
    return s;
}

SRP_EXPORT void
cstr_free(cstr *s)
{
    if (!s || --s->ref > 0)
        return;
    if (s->data)
        memset(s->data, 0, (size_t)s->cap);
    free(s->data);
    free(s);
}

SRP_EXPORT SRP *
SRP_new(SRP_METHOD *meth)
{
    SRP *srp = calloc(1, sizeof *srp);
    srp->meth = meth ? meth : &client6a;
    srp->ctx = BN_CTX_new();
    return srp;
}

SRP_EXPORT int
SRP_free(SRP *srp)
{
    if (!srp)
        return SRP_ERROR;
    BN_free(srp->N), BN_free(srp->g), BN_free(srp->B), BN_free(srp->A);
    BN_clear_free(srp->a), BN_clear_free(srp->x);
    if (srp->password) {
        memset(srp->password, 0, strlen(srp->password));
        free(srp->password);
    }
    free(srp->username);
    free(srp->salt);
    BN_CTX_free(srp->ctx);
    memset(srp, 0, sizeof *srp);
    free(srp);
    return SRP_SUCCESS;
}

SRP_EXPORT int
SRP_set_username(SRP *srp, const char *username)
{
    if (!srp || !username)
        return SRP_ERROR;
    free(srp->username);
    srp->username = strdup(username);
    return SRP_SUCCESS;
}

SRP_EXPORT int
SRP_set_params(SRP *srp, const unsigned char *modulus, int modlen, const unsigned char *generator, int genlen,
               const unsigned char *salt, int saltlen)
{
    if (!srp || !modulus || modlen <= 0 || !generator || genlen <= 0)
        return SRP_ERROR;
    BN_free(srp->N), BN_free(srp->g);
    srp->N = BN_bin2bn(modulus, modlen, NULL);
    srp->g = BN_bin2bn(generator, genlen, NULL);
    free(srp->salt);
    srp->salt = malloc(saltlen > 0 ? (size_t)saltlen : 1);
    if (saltlen > 0)
        memcpy(srp->salt, salt, (size_t)saltlen);
    srp->saltlen = saltlen;
    return SRP_SUCCESS;
}

/* x = H(salt | H(user ":" password)) */
SRP_EXPORT int
SRP_set_auth_password(SRP *srp, const char *password)
{
    if (!srp || !password || !srp->username)
        return SRP_ERROR;
    if (srp->password)
        free(srp->password);
    srp->password = strdup(password);
    unsigned char inner[SHA_DIGEST_LENGTH], outer[SHA_DIGEST_LENGTH];
    SHA_CTX c;
    SHA1_Init(&c);
    SHA1_Update(&c, srp->username, strlen(srp->username));
    SHA1_Update(&c, ":", 1);
    SHA1_Update(&c, password, strlen(password));
    SHA1_Final(inner, &c);
    SHA1_Init(&c);
    SHA1_Update(&c, srp->salt, (size_t)srp->saltlen);
    SHA1_Update(&c, inner, sizeof inner);
    SHA1_Final(outer, &c);
    BN_clear_free(srp->x);
    srp->x = BN_bin2bn(outer, sizeof outer, NULL);
    return SRP_SUCCESS;
}

/* a number padded to the modulus' length */
static int
padded(const BIGNUM *n, const BIGNUM *N, unsigned char *out)
{
    int len = BN_num_bytes(N);
    return BN_bn2binpad(n, out, len) == len ? len : -1;
}

static void
hash_bn(SHA_CTX *c, const BIGNUM *n)
{
    int len = BN_num_bytes(n);
    unsigned char *b = malloc(len > 0 ? (size_t)len : 1);
    BN_bn2bin(n, b);
    SHA1_Update(c, b, (size_t)len);
    free(b);
}

static void
hash_padded(SHA_CTX *c, const BIGNUM *n, const BIGNUM *N)
{
    int len = BN_num_bytes(N);
    unsigned char *b = malloc((size_t)len);
    padded(n, N, b);
    SHA1_Update(c, b, (size_t)len);
    free(b);
}

/* A = g^a mod N, a random */
SRP_EXPORT int
SRP_gen_pub(SRP *srp, cstr **result)
{
    if (!srp || !srp->N || !srp->g)
        return SRP_ERROR;
    BN_clear_free(srp->a);
    BN_free(srp->A);
    srp->a = BN_new();
    srp->A = BN_new();
    if (!BN_rand(srp->a, 256, BN_RAND_TOP_ANY, BN_RAND_BOTTOM_ANY) ||
        !BN_mod_exp(srp->A, srp->g, srp->a, srp->N, srp->ctx))
        return SRP_ERROR;
    if (result) {
        int len = BN_num_bytes(srp->A);
        unsigned char *b = malloc((size_t)len);
        BN_bn2bin(srp->A, b);
        *result = cstr_with(b, len);
        free(b);
    }
    return SRP_SUCCESS;
}

SRP_EXPORT int
SRP_compute_key(SRP *srp, cstr **result, const unsigned char *pubkey, int pubkeylen)
{
    if (!srp || !srp->A || !srp->x || !pubkey || pubkeylen <= 0)
        return SRP_ERROR;
    BN_CTX *ctx = srp->ctx;
    BN_free(srp->B);
    srp->B = BN_bin2bn(pubkey, pubkeylen, NULL);
    /* B mod N must not be zero */
    BIGNUM *t = BN_new();
    BN_mod(t, srp->B, srp->N, ctx);
    if (BN_is_zero(t)) {
        BN_free(t);
        return SRP_ERROR;
    }
    unsigned char h[SHA_DIGEST_LENGTH];
    SHA_CTX c;
    /* k = H(N | PAD(g)) */
    SHA1_Init(&c);
    hash_bn(&c, srp->N);
    hash_padded(&c, srp->g, srp->N);
    SHA1_Final(h, &c);
    BIGNUM *k = BN_bin2bn(h, sizeof h, NULL);
    /* u = H(PAD(A) | PAD(B)) */
    SHA1_Init(&c);
    hash_padded(&c, srp->A, srp->N);
    hash_padded(&c, srp->B, srp->N);
    SHA1_Final(h, &c);
    BIGNUM *u = BN_bin2bn(h, sizeof h, NULL);
    /* S = (B - k g^x)^(a + u x) mod N */
    BIGNUM *gx = BN_new(), *kgx = BN_new(), *base = BN_new(), *exp = BN_new(), *S = BN_new();
    BN_mod_exp(gx, srp->g, srp->x, srp->N, ctx);
    BN_mod_mul(kgx, k, gx, srp->N, ctx);
    BN_mod_sub(base, srp->B, kgx, srp->N, ctx);
    BN_mul(exp, u, srp->x, ctx);
    BN_add(exp, exp, srp->a);
    BN_mod_exp(S, base, exp, srp->N, ctx);
    /* K = H(S) */
    SHA1_Init(&c);
    hash_bn(&c, S);
    SHA1_Final(srp->K, &c);
    srp->haveKey = 1;
    BN_free(t), BN_free(k), BN_free(u), BN_free(gx), BN_free(kgx), BN_free(base);
    BN_clear_free(exp), BN_clear_free(S);
    if (result)
        *result = cstr_with(srp->K, sizeof srp->K);
    return SRP_SUCCESS;
}

/* M1 = H(H(N) xor H(g) | H(user) | salt | A | B | K) */
SRP_EXPORT int
SRP_respond(SRP *srp, cstr **proof)
{
    if (!srp || !srp->haveKey)
        return SRP_ERROR;
    unsigned char hN[SHA_DIGEST_LENGTH], hg[SHA_DIGEST_LENGTH], hu[SHA_DIGEST_LENGTH];
    SHA_CTX c;
    SHA1_Init(&c);
    hash_bn(&c, srp->N);
    SHA1_Final(hN, &c);
    SHA1_Init(&c);
    hash_bn(&c, srp->g);
    SHA1_Final(hg, &c);
    for (int i = 0; i < SHA_DIGEST_LENGTH; i++)
        hN[i] ^= hg[i];
    SHA1_Init(&c);
    SHA1_Update(&c, srp->username, strlen(srp->username));
    SHA1_Final(hu, &c);
    SHA1_Init(&c);
    SHA1_Update(&c, hN, sizeof hN);
    SHA1_Update(&c, hu, sizeof hu);
    SHA1_Update(&c, srp->salt, (size_t)srp->saltlen);
    hash_bn(&c, srp->A);
    hash_bn(&c, srp->B);
    SHA1_Update(&c, srp->K, sizeof srp->K);
    SHA1_Final(srp->M1, &c);
    if (proof)
        *proof = cstr_with(srp->M1, sizeof srp->M1);
    return SRP_SUCCESS;
}

/* the server's proof: M2 = H(A | M1 | K) */
SRP_EXPORT int
SRP_verify(SRP *srp, const unsigned char *proof, int prooflen)
{
    if (!srp || !srp->haveKey || !proof || prooflen != SHA_DIGEST_LENGTH)
        return SRP_ERROR;
    unsigned char m2[SHA_DIGEST_LENGTH];
    SHA_CTX c;
    SHA1_Init(&c);
    hash_bn(&c, srp->A);
    SHA1_Update(&c, srp->M1, sizeof srp->M1);
    SHA1_Update(&c, srp->K, sizeof srp->K);
    SHA1_Final(m2, &c);
    return CRYPTO_memcmp(m2, proof, sizeof m2) == 0 ? SRP_SUCCESS : SRP_ERROR;
}

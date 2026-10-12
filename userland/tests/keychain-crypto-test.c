/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../Security/SecKeychainCrypto.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
fail(const char *name)
{
	fprintf(stderr, "keychain crypto test failed: %s\n", name);
	exit(1);
}

static void
check(bool condition, const char *name)
{
	if (!condition)
		fail(name);
}

static bool
containsBytes(const uint8_t *haystack, size_t haystackLength,
	const uint8_t *needle, size_t needleLength)
{
	if (needleLength == 0 || needleLength > haystackLength)
		return false;
	for (size_t i = 0; i <= haystackLength - needleLength; i++)
		if (memcmp(haystack + i, needle, needleLength) == 0)
			return true;
	return false;
}

static uint32_t
readU32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	    ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void
writeU32(uint8_t *p, uint32_t value)
{
	p[0] = (uint8_t)(value >> 24);
	p[1] = (uint8_t)(value >> 16);
	p[2] = (uint8_t)(value >> 8);
	p[3] = (uint8_t)value;
}

static void
writeU64(uint8_t *p, uint64_t value)
{
	for (size_t i = 0; i < 8; i++)
		p[7 - i] = (uint8_t)(value >> (i * 8));
}

static void
checkFailedOpen(const uint8_t *envelope, size_t envelopeLength,
	const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES], const char *name)
{
	uint8_t *plaintext = NULL;
	size_t plaintextLength = 99;
	SecKeychainCryptoStatus status = finch_keychain_crypto_open_with_key(envelope,
	    envelopeLength, salt, key, &plaintext, &plaintextLength);
	check(status != SEC_KEYCHAIN_CRYPTO_OK, name);
	check(plaintext == NULL && plaintextLength == 0, "failure returned plaintext");
	if (plaintext != NULL)
		finch_keychain_crypto_clear_free(plaintext, plaintextLength);
}

static void
checkFailedInspect(const uint8_t *envelope, size_t envelopeLength, const char *name)
{
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	memset(salt, 0xa5, sizeof(salt));
	size_t plaintextLength = 99;
	SecKeychainCryptoStatus status = finch_keychain_crypto_inspect(envelope,
	    envelopeLength, salt, &plaintextLength);
	uint8_t zeroSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES] = {0};
	check(status != SEC_KEYCHAIN_CRYPTO_OK, name);
	check(plaintextLength == 0 && memcmp(salt, zeroSalt, sizeof(salt)) == 0,
	    "failed inspect cleared outputs");
}

int
main(void)
{
	static const uint8_t password[] = "a long test passphrase";
	static const uint8_t wrongPassword[] = "a different passphrase";
	static const uint8_t secret[] = "token=finch-secret-value; service=mail.invalid";
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	uint8_t otherSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t otherKey[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	uint8_t *envelope = NULL;
	uint8_t *secondEnvelope = NULL;
	size_t envelopeLength = 0;
	size_t secondEnvelopeLength = 0;
	SecKeychainCryptoStatus status = finch_keychain_crypto_create_key(password,
	    sizeof(password) - 1, salt, key);
	check(status == SEC_KEYCHAIN_CRYPTO_OK, "create key");
	status = finch_keychain_crypto_seal(key, salt, secret, sizeof(secret) - 1,
	    &envelope, &envelopeLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK, "seal plaintext");
	check(envelopeLength == SEC_KEYCHAIN_CRYPTO_HEADER_BYTES + sizeof(secret) - 1 +
	    SEC_KEYCHAIN_CRYPTO_TAG_BYTES, "envelope length");
	check(!containsBytes(envelope, envelopeLength, secret, sizeof(secret) - 1),
	    "plaintext appears in envelope");
	uint8_t inspectedSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	size_t inspectedLength = 99;
	status = finch_keychain_crypto_inspect(envelope, envelopeLength,
	    inspectedSalt, &inspectedLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK && inspectedLength == sizeof(secret) - 1 &&
	    memcmp(inspectedSalt, salt, sizeof(salt)) == 0, "inspect framing metadata");
	status = finch_keychain_crypto_seal(key, salt, secret, sizeof(secret) - 1,
	    &secondEnvelope, &secondEnvelopeLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK && secondEnvelopeLength == envelopeLength,
	    "second seal");
	check(memcmp(envelope + SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET,
	    secondEnvelope + SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET,
	    SEC_KEYCHAIN_CRYPTO_NONCE_BYTES) != 0, "fresh nonce");

	uint8_t *plaintext = NULL;
	size_t plaintextLength = 0;
	status = finch_keychain_crypto_open_with_key(envelope, envelopeLength, salt, key,
	    &plaintext, &plaintextLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK && plaintextLength == sizeof(secret) - 1 &&
	    memcmp(plaintext, secret, plaintextLength) == 0, "cached-key round trip");
	finch_keychain_crypto_clear_free(plaintext, plaintextLength);
	plaintext = NULL;
	status = finch_keychain_crypto_unlock(envelope, envelopeLength, password,
	    sizeof(password) - 1, otherSalt, otherKey, &plaintext, &plaintextLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK && plaintextLength == sizeof(secret) - 1 &&
	    memcmp(otherSalt, salt, sizeof(salt)) == 0 &&
	    memcmp(otherKey, key, sizeof(key)) == 0 &&
	    memcmp(plaintext, secret, plaintextLength) == 0, "password unlock");
	finch_keychain_crypto_clear_free(plaintext, plaintextLength);
	plaintext = NULL;
	memset(otherSalt, 0xa5, sizeof(otherSalt));
	memset(otherKey, 0xa5, sizeof(otherKey));
	status = finch_keychain_crypto_unlock(envelope, envelopeLength, wrongPassword,
	    sizeof(wrongPassword) - 1, otherSalt, otherKey, &plaintext, &plaintextLength);
	check(status == SEC_KEYCHAIN_CRYPTO_AUTH_FAILED && plaintext == NULL &&
	    plaintextLength == 0, "wrong password refused");
	uint8_t zeroSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES] = {0};
	uint8_t zeroKey[SEC_KEYCHAIN_CRYPTO_KEY_BYTES] = {0};
	check(memcmp(otherSalt, zeroSalt, sizeof(zeroSalt)) == 0 &&
	    memcmp(otherKey, zeroKey, sizeof(zeroKey)) == 0, "failed unlock cleared key outputs");

	for (size_t i = 0; i < SEC_KEYCHAIN_CRYPTO_HEADER_BYTES; i++) {
		uint8_t *changed = malloc(envelopeLength);
		check(changed != NULL, "allocate header mutation");
		memcpy(changed, envelope, envelopeLength);
		changed[i] ^= 1;
		checkFailedOpen(changed, envelopeLength, salt, key, "changed header accepted");
		free(changed);
	}
	uint8_t *changed = malloc(envelopeLength);
	check(changed != NULL, "allocate ciphertext mutation");
	memcpy(changed, envelope, envelopeLength);
	changed[SEC_KEYCHAIN_CRYPTO_HEADER_BYTES] ^= 1;
	checkFailedOpen(changed, envelopeLength, salt, key, "changed ciphertext accepted");
	memcpy(changed, envelope, envelopeLength);
	changed[envelopeLength - 1] ^= 1;
	inspectedLength = 99;
	status = finch_keychain_crypto_inspect(changed, envelopeLength,
	    inspectedSalt, &inspectedLength);
	check(status == SEC_KEYCHAIN_CRYPTO_OK && inspectedLength == sizeof(secret) - 1 &&
	    memcmp(inspectedSalt, salt, sizeof(salt)) == 0,
	    "inspect incorrectly treated tag as authenticated");
	checkFailedOpen(changed, envelopeLength, salt, key, "changed tag accepted");
	free(changed);

	for (size_t i = 0; i < envelopeLength; i++) {
		if (i == 0 || i == SEC_KEYCHAIN_CRYPTO_HEADER_BYTES ||
		    i == envelopeLength - 1 || i == envelopeLength / 2) {
			char name[48];
			(void)snprintf(name, sizeof(name), "truncated envelope at %zu", i);
			checkFailedOpen(envelope, i, salt, key, name);
			checkFailedInspect(envelope, i, name);
		}
	}
	checkFailedOpen(envelope, SIZE_MAX, salt, key, "oversized envelope length accepted");
	checkFailedInspect(envelope, SIZE_MAX, "oversized inspect length accepted");
	changed = malloc(envelopeLength + 1);
	check(changed != NULL, "allocate trailing-byte check");
	memcpy(changed, envelope, envelopeLength);
	changed[envelopeLength] = 0;
	checkFailedOpen(changed, envelopeLength + 1, salt, key,
	    "trailing envelope byte accepted");
	memcpy(changed, envelope, envelopeLength);
	changed[SEC_KEYCHAIN_CRYPTO_VERSION_OFFSET + 1]++;
	checkFailedOpen(changed, envelopeLength, salt, key, "unsupported version accepted");
	checkFailedInspect(changed, envelopeLength, "unsupported inspect version accepted");
	memcpy(changed, envelope, envelopeLength);
	writeU32(changed + SEC_KEYCHAIN_CRYPTO_COST_OFFSET,
	    SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS + 1);
	checkFailedOpen(changed, envelopeLength, salt, key, "unsupported KDF cost accepted");
	memcpy(changed, envelope, envelopeLength);
	writeU64(changed + SEC_KEYCHAIN_CRYPTO_LENGTH_OFFSET, UINT64_MAX);
	checkFailedOpen(changed, envelopeLength, salt, key, "oversized plaintext length accepted");
	checkFailedInspect(changed, envelopeLength,
	    "oversized inspect plaintext length accepted");
	free(changed);
	check(readU32(envelope + SEC_KEYCHAIN_CRYPTO_COST_OFFSET) ==
	    SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS, "KDF cost header");

	uint8_t emptySalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t emptyKey[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	uint8_t *emptyEnvelope = NULL;
	size_t emptyEnvelopeLength = 0;
	check(finch_keychain_crypto_create_key(password, sizeof(password) - 1,
	    emptySalt, emptyKey) == SEC_KEYCHAIN_CRYPTO_OK, "create empty-payload key");
	check(finch_keychain_crypto_seal(emptyKey, emptySalt, NULL, 0, &emptyEnvelope,
	    &emptyEnvelopeLength) == SEC_KEYCHAIN_CRYPTO_OK, "seal empty payload");
	plaintext = NULL;
	plaintextLength = 1;
	check(finch_keychain_crypto_open_with_key(emptyEnvelope, emptyEnvelopeLength,
	    emptySalt, emptyKey, &plaintext, &plaintextLength) == SEC_KEYCHAIN_CRYPTO_OK &&
	    plaintext != NULL && plaintextLength == 0, "open empty payload");
	finch_keychain_crypto_clear_free(plaintext, plaintextLength);
	finch_keychain_crypto_clear_free(emptyEnvelope, emptyEnvelopeLength);
	memset(emptyKey, 0, sizeof(emptyKey));

	uint8_t dummy = 0;
	uint8_t *tooLargeEnvelope = NULL;
	size_t tooLargeLength = 0;
	check(finch_keychain_crypto_seal(key, salt, &dummy,
	    (size_t)SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES + 1,
	    &tooLargeEnvelope, &tooLargeLength) == SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT &&
	    tooLargeEnvelope == NULL && tooLargeLength == 0, "oversized plaintext refused");
	check(finch_keychain_crypto_create_key(password, 0, otherSalt, otherKey) ==
	    SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT, "empty password refused");
	check(finch_keychain_crypto_create_key(NULL, sizeof(password) - 1, otherSalt, otherKey) ==
	    SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT, "null password refused");

	finch_keychain_crypto_clear_free(envelope, envelopeLength);
	finch_keychain_crypto_clear_free(secondEnvelope, secondEnvelopeLength);
	memset(key, 0, sizeof(key));
	memset(otherKey, 0, sizeof(otherKey));
	memset(salt, 0, sizeof(salt));
	memset(otherSalt, 0, sizeof(otherSalt));
	puts("keychain crypto helper: PASS (envelope, authentication, bounds, cleanup)");
	return 0;
}

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "SecKeychainCrypto.h"

#include <limits.h>
#include <stdbool.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

enum {
	KDF_PBKDF2_SHA256 = 1,
	CIPHER_AES_256_GCM = 1,
	HEADER_VERSION = 1,
	HEADER_FIXED_BYTES = SEC_KEYCHAIN_CRYPTO_HEADER_BYTES
};

static const uint8_t envelopeMagic[8] = {'F', 'N', 'K', 'C', 'E', 'N', 'C', 0};

static bool
validPassword(const void *password, size_t length)
{
	return password != NULL && length > 0 &&
	    length <= SEC_KEYCHAIN_CRYPTO_MAX_PASSWORD_BYTES && length <= INT_MAX;
}

static uint16_t
readU16(const uint8_t *p)
{
	return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t
readU32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	    ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t
readU64(const uint8_t *p)
{
	uint64_t value = 0;
	for (size_t i = 0; i < 8; i++)
		value = (value << 8) | p[i];
	return value;
}

static void
writeU16(uint8_t *p, uint16_t value)
{
	p[0] = (uint8_t)(value >> 8);
	p[1] = (uint8_t)value;
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

static SecKeychainCryptoStatus
parseEnvelope(const uint8_t *envelope, size_t envelopeLength, size_t *plaintextLength)
{
	if (envelope == NULL || plaintextLength == NULL)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	*plaintextLength = 0;
	if (envelopeLength < SEC_KEYCHAIN_CRYPTO_HEADER_BYTES + SEC_KEYCHAIN_CRYPTO_TAG_BYTES ||
	    envelopeLength > SEC_KEYCHAIN_CRYPTO_HEADER_BYTES +
	        SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES + SEC_KEYCHAIN_CRYPTO_TAG_BYTES)
		return SEC_KEYCHAIN_CRYPTO_INVALID_FORMAT;
	if (CRYPTO_memcmp(envelope, envelopeMagic, sizeof(envelopeMagic)) != 0 ||
	    readU16(envelope + 8) != HEADER_VERSION ||
	    readU16(envelope + 10) != KDF_PBKDF2_SHA256 ||
	    readU16(envelope + 12) != CIPHER_AES_256_GCM ||
	    readU16(envelope + 14) != HEADER_FIXED_BYTES ||
	    readU32(envelope + SEC_KEYCHAIN_CRYPTO_COST_OFFSET) !=
	        SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS)
		return SEC_KEYCHAIN_CRYPTO_INVALID_FORMAT;
	uint64_t encodedLength = readU64(envelope + SEC_KEYCHAIN_CRYPTO_LENGTH_OFFSET);
	if (encodedLength > SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES)
		return SEC_KEYCHAIN_CRYPTO_INVALID_FORMAT;
	size_t length = (size_t)encodedLength;
	/* The upper bound above makes both additions safe on supported size_t widths. */
	if (envelopeLength != SEC_KEYCHAIN_CRYPTO_HEADER_BYTES + length +
	    SEC_KEYCHAIN_CRYPTO_TAG_BYTES)
		return SEC_KEYCHAIN_CRYPTO_INVALID_FORMAT;
	*plaintextLength = length;
	return SEC_KEYCHAIN_CRYPTO_OK;
}

SecKeychainCryptoStatus
finch_keychain_crypto_inspect(const void *envelopeBuffer, size_t envelopeLength,
	uint8_t saltOut[SEC_KEYCHAIN_CRYPTO_SALT_BYTES], size_t *plaintextLengthOut)
{
	if (saltOut != NULL)
		OPENSSL_cleanse(saltOut, SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
	if (plaintextLengthOut != NULL)
		*plaintextLengthOut = 0;
	if (saltOut == NULL || plaintextLengthOut == NULL)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;

	const uint8_t *envelope = envelopeBuffer;
	size_t plaintextLength = 0;
	SecKeychainCryptoStatus status = parseEnvelope(envelope, envelopeLength,
	    &plaintextLength);
	if (status != SEC_KEYCHAIN_CRYPTO_OK)
		return status;

	memcpy(saltOut, envelope + SEC_KEYCHAIN_CRYPTO_SALT_OFFSET,
	    SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
	*plaintextLengthOut = plaintextLength;
	return SEC_KEYCHAIN_CRYPTO_OK;
}

SecKeychainCryptoStatus
finch_keychain_crypto_derive_key(const void *password, size_t passwordLength,
    const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
    uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES])
{
	if (key != NULL)
		OPENSSL_cleanse(key, SEC_KEYCHAIN_CRYPTO_KEY_BYTES);
	if (!validPassword(password, passwordLength) || salt == NULL || key == NULL)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	if (PKCS5_PBKDF2_HMAC(password, (int)passwordLength, salt,
	        SEC_KEYCHAIN_CRYPTO_SALT_BYTES, SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS,
	        EVP_sha256(), SEC_KEYCHAIN_CRYPTO_KEY_BYTES, key) != 1) {
		OPENSSL_cleanse(key, SEC_KEYCHAIN_CRYPTO_KEY_BYTES);
		return SEC_KEYCHAIN_CRYPTO_FAILED;
	}
	return SEC_KEYCHAIN_CRYPTO_OK;
}

SecKeychainCryptoStatus
finch_keychain_crypto_create_key(const void *password, size_t passwordLength,
    uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
    uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES])
{
	if (salt != NULL)
		OPENSSL_cleanse(salt, SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
	if (key != NULL)
		OPENSSL_cleanse(key, SEC_KEYCHAIN_CRYPTO_KEY_BYTES);
	if (!validPassword(password, passwordLength) || salt == NULL || key == NULL)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	if (RAND_bytes(salt, SEC_KEYCHAIN_CRYPTO_SALT_BYTES) != 1) {
		OPENSSL_cleanse(salt, SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
		return SEC_KEYCHAIN_CRYPTO_FAILED;
	}
	SecKeychainCryptoStatus status = finch_keychain_crypto_derive_key(password,
	    passwordLength, salt, key);
	if (status != SEC_KEYCHAIN_CRYPTO_OK) {
		OPENSSL_cleanse(salt, SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
		OPENSSL_cleanse(key, SEC_KEYCHAIN_CRYPTO_KEY_BYTES);
	}
	return status;
}

SecKeychainCryptoStatus
finch_keychain_crypto_seal(const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
    const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES], const void *plaintext,
	 size_t plaintextLength, uint8_t **envelopeOut, size_t *envelopeLengthOut)
{
	if (envelopeOut != NULL)
		*envelopeOut = NULL;
	if (envelopeLengthOut != NULL)
		*envelopeLengthOut = 0;
	if (key == NULL || salt == NULL || envelopeOut == NULL || envelopeLengthOut == NULL ||
	    (plaintext == NULL && plaintextLength != 0))
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	if (plaintextLength > SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	const size_t headerLength = SEC_KEYCHAIN_CRYPTO_HEADER_BYTES;
	const size_t totalLength = headerLength + plaintextLength + SEC_KEYCHAIN_CRYPTO_TAG_BYTES;
	uint8_t *envelope = OPENSSL_zalloc(totalLength);
	if (envelope == NULL)
		return SEC_KEYCHAIN_CRYPTO_NO_MEMORY;
	memcpy(envelope, envelopeMagic, sizeof(envelopeMagic));
	writeU16(envelope + 8, HEADER_VERSION);
	writeU16(envelope + 10, KDF_PBKDF2_SHA256);
	writeU16(envelope + 12, CIPHER_AES_256_GCM);
	writeU16(envelope + 14, HEADER_FIXED_BYTES);
	writeU32(envelope + SEC_KEYCHAIN_CRYPTO_COST_OFFSET,
	    SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS);
	memcpy(envelope + SEC_KEYCHAIN_CRYPTO_SALT_OFFSET, salt,
	    SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
	if (RAND_bytes(envelope + SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET,
	        SEC_KEYCHAIN_CRYPTO_NONCE_BYTES) != 1) {
		finch_keychain_crypto_clear_free(envelope, totalLength);
		return SEC_KEYCHAIN_CRYPTO_FAILED;
	}
	writeU64(envelope + SEC_KEYCHAIN_CRYPTO_LENGTH_OFFSET, plaintextLength);

	EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
	if (context == NULL) {
		finch_keychain_crypto_clear_free(envelope, totalLength);
		return SEC_KEYCHAIN_CRYPTO_NO_MEMORY;
	}
	int written = 0;
	int finalWritten = 0;
	uint8_t *ciphertext = envelope + headerLength;
	uint8_t *tag = ciphertext + plaintextLength;
	int ok = EVP_EncryptInit_ex(context, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
	    EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN,
	        SEC_KEYCHAIN_CRYPTO_NONCE_BYTES, NULL) == 1 &&
	    EVP_EncryptInit_ex(context, NULL, NULL, key,
	        envelope + SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET) == 1 &&
	    EVP_EncryptUpdate(context, NULL, &written, envelope, (int)headerLength) == 1;
	if (ok && plaintextLength > 0) {
		ok = EVP_EncryptUpdate(context, ciphertext, &written, plaintext,
		    (int)plaintextLength) == 1;
		ok = ok && (size_t)written == plaintextLength;
	} else {
		written = 0;
	}
	if (ok)
		ok = EVP_EncryptFinal_ex(context, ciphertext + written, &finalWritten) == 1 &&
		    finalWritten == 0;
	if (ok)
		ok = EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_GET_TAG,
		    SEC_KEYCHAIN_CRYPTO_TAG_BYTES, tag) == 1;
	EVP_CIPHER_CTX_free(context);
	if (!ok) {
		finch_keychain_crypto_clear_free(envelope, totalLength);
		return SEC_KEYCHAIN_CRYPTO_FAILED;
	}
	*envelopeOut = envelope;
	*envelopeLengthOut = totalLength;
	return SEC_KEYCHAIN_CRYPTO_OK;
}

SecKeychainCryptoStatus
finch_keychain_crypto_open_with_key(const void *envelopeBuffer, size_t envelopeLength,
    const uint8_t expectedSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
    const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
	 uint8_t **plaintextOut, size_t *plaintextLengthOut)
{
	if (plaintextOut != NULL)
		*plaintextOut = NULL;
	if (plaintextLengthOut != NULL)
		*plaintextLengthOut = 0;
	if (envelopeBuffer == NULL || expectedSalt == NULL || key == NULL ||
	    plaintextOut == NULL || plaintextLengthOut == NULL)
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	const uint8_t *envelope = envelopeBuffer;
	size_t plaintextLength = 0;
	SecKeychainCryptoStatus status = parseEnvelope(envelope, envelopeLength,
	    &plaintextLength);
	if (status != SEC_KEYCHAIN_CRYPTO_OK)
		return status;
	if (CRYPTO_memcmp(envelope + SEC_KEYCHAIN_CRYPTO_SALT_OFFSET, expectedSalt,
	        SEC_KEYCHAIN_CRYPTO_SALT_BYTES) != 0)
		return SEC_KEYCHAIN_CRYPTO_AUTH_FAILED;
	size_t allocationLength = plaintextLength ? plaintextLength : 1;
	uint8_t *plaintext = OPENSSL_zalloc(allocationLength);
	if (plaintext == NULL)
		return SEC_KEYCHAIN_CRYPTO_NO_MEMORY;
	EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
	if (context == NULL) {
		finch_keychain_crypto_clear_free(plaintext, allocationLength);
		return SEC_KEYCHAIN_CRYPTO_NO_MEMORY;
	}
	int written = 0;
	int finalWritten = 0;
	const uint8_t *ciphertext = envelope + SEC_KEYCHAIN_CRYPTO_HEADER_BYTES;
	const uint8_t *tag = ciphertext + plaintextLength;
	int ok = EVP_DecryptInit_ex(context, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
	    EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN,
	        SEC_KEYCHAIN_CRYPTO_NONCE_BYTES, NULL) == 1 &&
	    EVP_DecryptInit_ex(context, NULL, NULL, key,
	        envelope + SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET) == 1 &&
	    EVP_DecryptUpdate(context, NULL, &written, envelope,
	        SEC_KEYCHAIN_CRYPTO_HEADER_BYTES) == 1;
	if (ok && plaintextLength > 0) {
		ok = EVP_DecryptUpdate(context, plaintext, &written, ciphertext,
		    (int)plaintextLength) == 1;
		ok = ok && (size_t)written == plaintextLength;
	} else {
		written = 0;
	}
	if (ok)
		ok = EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_TAG,
		    SEC_KEYCHAIN_CRYPTO_TAG_BYTES, (void *)tag) == 1;
	int authenticated = ok && EVP_DecryptFinal_ex(context, plaintext + written,
	    &finalWritten) == 1;
	EVP_CIPHER_CTX_free(context);
	if (!ok) {
		finch_keychain_crypto_clear_free(plaintext, allocationLength);
		return SEC_KEYCHAIN_CRYPTO_FAILED;
	}
	if (!authenticated || finalWritten != 0) {
		finch_keychain_crypto_clear_free(plaintext, allocationLength);
		return SEC_KEYCHAIN_CRYPTO_AUTH_FAILED;
	}
	*plaintextOut = plaintext;
	*plaintextLengthOut = plaintextLength;
	return SEC_KEYCHAIN_CRYPTO_OK;
}

SecKeychainCryptoStatus
finch_keychain_crypto_unlock(const void *envelope, size_t envelopeLength,
	const void *password, size_t passwordLength,
	uint8_t saltOut[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	uint8_t keyOut[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
	uint8_t **plaintextOut, size_t *plaintextLengthOut)
{
	if (saltOut != NULL)
		OPENSSL_cleanse(saltOut, SEC_KEYCHAIN_CRYPTO_SALT_BYTES);
	if (keyOut != NULL)
		OPENSSL_cleanse(keyOut, SEC_KEYCHAIN_CRYPTO_KEY_BYTES);
	if (plaintextOut != NULL)
		*plaintextOut = NULL;
	if (plaintextLengthOut != NULL)
		*plaintextLengthOut = 0;
	if (saltOut == NULL || keyOut == NULL || plaintextOut == NULL ||
	    plaintextLengthOut == NULL || !validPassword(password, passwordLength))
		return SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT;
	const uint8_t *bytes = envelope;
	size_t ignoredLength = 0;
	SecKeychainCryptoStatus status = parseEnvelope(bytes, envelopeLength,
	    &ignoredLength);
	if (status != SEC_KEYCHAIN_CRYPTO_OK)
		return status;
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES];
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES];
	memcpy(salt, bytes + SEC_KEYCHAIN_CRYPTO_SALT_OFFSET, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	status = finch_keychain_crypto_derive_key(password, passwordLength, salt, key);
	uint8_t *plaintext = NULL;
	size_t plaintextLength = 0;
	if (status == SEC_KEYCHAIN_CRYPTO_OK)
		status = finch_keychain_crypto_open_with_key(bytes, envelopeLength, salt, key,
		    &plaintext, &plaintextLength);
	if (status == SEC_KEYCHAIN_CRYPTO_OK) {
		memcpy(saltOut, salt, sizeof(salt));
		memcpy(keyOut, key, sizeof(key));
		*plaintextOut = plaintext;
		*plaintextLengthOut = plaintextLength;
	} else if (plaintext != NULL) {
		finch_keychain_crypto_clear_free(plaintext, plaintextLength);
	}
	OPENSSL_cleanse(salt, sizeof(salt));
	OPENSSL_cleanse(key, sizeof(key));
	return status;
}

void
finch_keychain_crypto_clear_free(void *buffer, size_t length)
{
	if (buffer != NULL)
		OPENSSL_clear_free(buffer, length ? length : 1);
}

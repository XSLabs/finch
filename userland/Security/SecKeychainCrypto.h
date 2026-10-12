/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SECKEYCHAINCRYPTO_H
#define FINCH_SECKEYCHAINCRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SEC_KEYCHAIN_CRYPTO_KEY_BYTES 32
#define SEC_KEYCHAIN_CRYPTO_SALT_BYTES 16
#define SEC_KEYCHAIN_CRYPTO_NONCE_BYTES 12
#define SEC_KEYCHAIN_CRYPTO_TAG_BYTES 16
#define SEC_KEYCHAIN_CRYPTO_HEADER_BYTES 56
#define SEC_KEYCHAIN_CRYPTO_VERSION_OFFSET 8
#define SEC_KEYCHAIN_CRYPTO_COST_OFFSET 16
#define SEC_KEYCHAIN_CRYPTO_SALT_OFFSET 20
#define SEC_KEYCHAIN_CRYPTO_NONCE_OFFSET 36
#define SEC_KEYCHAIN_CRYPTO_LENGTH_OFFSET 48
#define SEC_KEYCHAIN_CRYPTO_PBKDF2_ROUNDS 600000
#define SEC_KEYCHAIN_CRYPTO_MAX_PASSWORD_BYTES 4096
#define SEC_KEYCHAIN_CRYPTO_MAX_PLAINTEXT_BYTES (16U * 1024U * 1024U)

typedef enum {
	SEC_KEYCHAIN_CRYPTO_OK = 0,
	SEC_KEYCHAIN_CRYPTO_INVALID_ARGUMENT = 1,
	SEC_KEYCHAIN_CRYPTO_INVALID_FORMAT = 2,
	SEC_KEYCHAIN_CRYPTO_AUTH_FAILED = 3,
	SEC_KEYCHAIN_CRYPTO_NO_MEMORY = 4,
	SEC_KEYCHAIN_CRYPTO_FAILED = 5
} SecKeychainCryptoStatus;

/*
 * Internal Finch keychain-file helpers. These are not public Security API.
 * Passwords are byte strings: empty values are refused and values over 4096
 * bytes are refused. Plaintext is limited to 16 MiB.
 *
 * All caller-provided output storage must be separate from every input and
 * from other output storage. Buffers returned by seal, open_with_key, or
 * unlock are allocated by this helper and must be released only with
 * finch_keychain_crypto_clear_free(), using the returned length (zero is
 * accepted for an empty plaintext). Do not use free() for those buffers.
 */

/* Generate a fresh salt and derive the key used for this keychain. */
SecKeychainCryptoStatus finch_keychain_crypto_create_key(const void *password,
	size_t passwordLength, uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES]);

/* Derive a key again when a process opens an existing keychain. */
SecKeychainCryptoStatus finch_keychain_crypto_derive_key(const void *password,
	size_t passwordLength, const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES]);

/* Seal the full plist bytes, keeping the keychain's salt and choosing a new nonce. */
SecKeychainCryptoStatus finch_keychain_crypto_seal(
	const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
	const uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	const void *plaintext, size_t plaintextLength,
	uint8_t **envelope, size_t *envelopeLength);

/* Open with a key already derived for expectedSalt. Outputs stay empty on failure. */
SecKeychainCryptoStatus finch_keychain_crypto_open_with_key(const void *envelope,
	size_t envelopeLength,
	const uint8_t expectedSalt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	const uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
	uint8_t **plaintext, size_t *plaintextLength);

/* Derive and authenticate an existing envelope. Outputs stay empty on failure. */
SecKeychainCryptoStatus finch_keychain_crypto_unlock(const void *envelope,
	size_t envelopeLength, const void *password, size_t passwordLength,
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES],
	uint8_t key[SEC_KEYCHAIN_CRYPTO_KEY_BYTES],
	uint8_t **plaintext, size_t *plaintextLength);

/*
 * Read framing metadata from a locked file. Success validates only the
 * envelope's shape and size; it does not authenticate the salt, ciphertext,
 * or tag. Outputs are cleared on failure. Use unlock/open_with_key before
 * trusting any file contents.
 */
SecKeychainCryptoStatus finch_keychain_crypto_inspect(const void *envelope,
	size_t envelopeLength,
	uint8_t salt[SEC_KEYCHAIN_CRYPTO_SALT_BYTES], size_t *plaintextLength);

/* Free an allocated buffer after clearing its contents. */
void finch_keychain_crypto_clear_free(void *buffer, size_t length);

#ifdef __cplusplus
}
#endif

#endif

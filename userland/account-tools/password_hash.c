/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Local password hashes for Finch. We use published CommonCrypto PBKDF2 and
 * keep old DES hashes readable during the move to the stronger format.
 */

#include "account_tools.h"

#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonRandom.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HASH_PREFIX "$finch$pbkdf2-sha256$"
#define HASH_ROUNDS 600000U
#define HASH_MIN_ROUNDS 100000U
#define HASH_MAX_ROUNDS 1200000U
#define SALT_BYTES 16
#define KEY_BYTES 32
#define SALT_HEX_BYTES (SALT_BYTES * 2)
#define KEY_HEX_BYTES (KEY_BYTES * 2)
#define HASH_TEXT_MAX 160

/* Finch's old crypt() uses shared static output and tables. */
static pthread_mutex_t legacy_crypt_lock = PTHREAD_MUTEX_INITIALIZER;

void
at_secure_clear(void *value, size_t size)
{
	volatile unsigned char *p = value;
	while (size--)
		*p++ = 0;
}

static int
hex_value(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return -1;
}

static void
to_hex(const unsigned char *in, size_t size, char *out)
{
	static const char digits[] = "0123456789abcdef";
	for (size_t i = 0; i < size; ++i) {
		out[i * 2] = digits[in[i] >> 4];
		out[i * 2 + 1] = digits[in[i] & 15];
	}
	out[size * 2] = '\0';
}

static int
from_hex(const char *in, size_t size, unsigned char *out)
{
	for (size_t i = 0; i < size; i += 2) {
		int high = hex_value(in[i]);
		int low = hex_value(in[i + 1]);
		if (high < 0 || low < 0)
			return -1;
		out[i / 2] = (unsigned char)((high << 4) | low);
	}
	return 0;
}

static int
constant_time_equal(const unsigned char *a, const unsigned char *b, size_t size)
{
	unsigned char diff = 0;
	for (size_t i = 0; i < size; ++i)
		diff |= a[i] ^ b[i];
	return diff == 0;
}

int
at_password_is_acceptable(const char *password)
{
	if (!password)
		return 0;
	size_t length = strnlen(password, AT_PASSWORD_MAX + 1);
	return length >= AT_PASSWORD_MIN && length <= AT_PASSWORD_MAX;
}

int
at_password_hash(const char *password, char *out, size_t out_size)
{
	unsigned char salt[SALT_BYTES], key[KEY_BYTES];
	char salt_hex[SALT_HEX_BYTES + 1], key_hex[KEY_HEX_BYTES + 1];
	int result = -1;

	if (!at_password_is_acceptable(password) || !out || out_size < HASH_TEXT_MAX)
		return -1;
	if (CCRandomGenerateBytes(salt, sizeof(salt)) != kCCSuccess)
		goto done;
	if (CCKeyDerivationPBKDF(kCCPBKDF2, password, strlen(password), salt,
	    sizeof(salt), kCCPRFHmacAlgSHA256, HASH_ROUNDS, key,
	    sizeof(key)) != kCCSuccess)
		goto done;
	to_hex(salt, sizeof(salt), salt_hex);
	to_hex(key, sizeof(key), key_hex);
	if (snprintf(out, out_size, HASH_PREFIX "%u$%s$%s", HASH_ROUNDS,
	    salt_hex, key_hex) >= (int)out_size) {
		out[0] = '\0';
		goto done;
	}
	result = 0;
done:
	at_secure_clear(salt, sizeof(salt));
	at_secure_clear(key, sizeof(key));
	at_secure_clear(key_hex, sizeof(key_hex));
	return result;
}

static int
verify_pbkdf2(const char *password, const char *stored_hash)
{
	const char *p = stored_hash + sizeof(HASH_PREFIX) - 1;
	char *end = NULL;
	unsigned long rounds;
	unsigned char salt[SALT_BYTES], expected[KEY_BYTES], actual[KEY_BYTES];
	int result = 0;

	if (strncmp(stored_hash, HASH_PREFIX, sizeof(HASH_PREFIX) - 1) != 0)
		return 0;
	if (*p < '0' || *p > '9')
		return 0;
	rounds = strtoul(p, &end, 10);
	if (!end || *end != '$' || rounds < HASH_MIN_ROUNDS || rounds > HASH_MAX_ROUNDS)
		return 0;
	p = end + 1;
	if (strlen(p) != SALT_HEX_BYTES + 1 + KEY_HEX_BYTES ||
	    p[SALT_HEX_BYTES] != '$' || p[SALT_HEX_BYTES + 1 + KEY_HEX_BYTES] != '\0')
		return 0;
	if (from_hex(p, SALT_HEX_BYTES, salt) != 0 ||
	    from_hex(p + SALT_HEX_BYTES + 1, KEY_HEX_BYTES, expected) != 0)
		goto done;
	if (CCKeyDerivationPBKDF(kCCPBKDF2, password, strlen(password), salt,
	    sizeof(salt), kCCPRFHmacAlgSHA256, (unsigned)rounds, actual,
	    sizeof(actual)) == kCCSuccess)
		result = constant_time_equal(expected, actual, sizeof(expected));
done:
	at_secure_clear(salt, sizeof(salt));
	at_secure_clear(expected, sizeof(expected));
	at_secure_clear(actual, sizeof(actual));
	return result;
}

int
at_password_verify(const char *password, const char *stored_hash)
{
	if (!password || !stored_hash || !password[0] ||
	    strnlen(password, AT_PASSWORD_MAX + 1) > AT_PASSWORD_MAX ||
	    strnlen(stored_hash, HASH_TEXT_MAX + 1) > HASH_TEXT_MAX)
		return 0;
	if (stored_hash[0] == '*' || stored_hash[0] == '!' || stored_hash[0] == '$') {
		if (strncmp(stored_hash, HASH_PREFIX, sizeof(HASH_PREFIX) - 1) == 0)
			return verify_pbkdf2(password, stored_hash);
		return 0;
	}
	/* Finch's current crypt() is DES-only. Keep it only for old local hashes. */
	if (pthread_mutex_lock(&legacy_crypt_lock) != 0)
		return 0;
	const char *legacy = crypt(password, stored_hash);
	int matches = legacy && strlen(legacy) == strlen(stored_hash) &&
	    constant_time_equal((const unsigned char *)legacy,
	    (const unsigned char *)stored_hash, strlen(stored_hash));
	(void)pthread_mutex_unlock(&legacy_crypt_lock);
	return matches;
}

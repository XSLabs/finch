/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_PAM_KEYCHAIN_DATA_H
#define FINCH_PAM_KEYCHAIN_DATA_H

#include <security/pam_appl.h>
#include <security/openpam.h>

#include <account_tools.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define FINCH_PAM_KEYCHAIN_PASSWORD_DATA "finch_pam_keychain_password"

struct finch_pam_keychain_password {
	uid_t uid;
	size_t length;
	char value[];
};

static inline void
finch_pam_keychain_password_cleanup(pam_handle_t *pamh, void *data,
	int pam_end_status)
{
	struct finch_pam_keychain_password *secret = data;
	(void)pamh;
	(void)pam_end_status;
	if (!secret)
		return;
	at_secure_clear(secret->value, secret->length + 1);
	at_secure_clear(secret, sizeof(*secret));
	free(secret);
}

static inline int
finch_pam_keychain_password_clear(pam_handle_t *pamh)
{
	const void *data = NULL;
	int status = pam_get_data(pamh, FINCH_PAM_KEYCHAIN_PASSWORD_DATA, &data);
	if (status == PAM_NO_MODULE_DATA)
		return PAM_SUCCESS;
	if (status != PAM_SUCCESS)
		return status;
	if (!data)
		return PAM_SUCCESS;
	struct finch_pam_keychain_password *secret = (void *)data;
	/* Wipe first, even if OpenPAM cannot replace this entry right away. */
	at_secure_clear(secret->value, secret->length + 1);
	at_secure_clear(secret, sizeof(*secret));
	return pam_set_data(pamh, FINCH_PAM_KEYCHAIN_PASSWORD_DATA, NULL, NULL);
}

static inline int
finch_pam_keychain_password_store(pam_handle_t *pamh, uid_t uid,
	const char *password, bool verified)
{
	struct finch_pam_keychain_password *secret;
	size_t length;
	int status;

	status = finch_pam_keychain_password_clear(pamh);
	if (status != PAM_SUCCESS)
		return status;
	if (!verified || uid == 0 || !password || !password[0])
		return PAM_SUCCESS;
	length = strlen(password);
	if (length > UINT32_MAX || length > SIZE_MAX - sizeof(*secret) - 1)
		return PAM_SUCCESS;
	secret = malloc(sizeof(*secret) + length + 1);
	if (!secret)
		return PAM_SUCCESS;
	secret->uid = uid;
	secret->length = length;
	memcpy(secret->value, password, length + 1);
	status = pam_set_data(pamh, FINCH_PAM_KEYCHAIN_PASSWORD_DATA, secret,
	    finch_pam_keychain_password_cleanup);
	if (status != PAM_SUCCESS)
		finch_pam_keychain_password_cleanup(pamh, secret, status);
	/* A missing keychain handoff must never reject a valid password. */
	return PAM_SUCCESS;
}

static inline int
finch_pam_keychain_password_get(pam_handle_t *pamh,
	const struct finch_pam_keychain_password **secret)
{
	const void *data = NULL;
	int status;

	if (!secret)
		return PAM_SYSTEM_ERR;
	*secret = NULL;
	status = pam_get_data(pamh, FINCH_PAM_KEYCHAIN_PASSWORD_DATA, &data);
	if (status == PAM_NO_MODULE_DATA)
		return PAM_SUCCESS;
	if (status != PAM_SUCCESS)
		return status;
	*secret = data;
	return PAM_SUCCESS;
}

#endif

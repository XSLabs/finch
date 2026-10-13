/* SPDX-License-Identifier: MIT OR Apache-2.0 */

#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "../pam_keychain_data.h"

static void *storedData;
static void (*storedCleanup)(pam_handle_t *, void *, int);
static unsigned int secureClearCalls;
static int nextSetStatus;

int
pam_get_data(const pam_handle_t *pamh, const char *name, const void **data)
{
	(void)pamh;
	assert(strcmp(name, FINCH_PAM_KEYCHAIN_PASSWORD_DATA) == 0);
	if (!storedCleanup && !storedData)
		return PAM_NO_MODULE_DATA;
	*data = storedData;
	return PAM_SUCCESS;
}

int
pam_set_data(pam_handle_t *pamh, const char *name, void *data,
	void (*cleanup)(pam_handle_t *, void *, int))
{
	(void)pamh;
	assert(strcmp(name, FINCH_PAM_KEYCHAIN_PASSWORD_DATA) == 0);
	if (nextSetStatus) {
		int status = nextSetStatus;
		nextSetStatus = 0;
		return status;
	}
	if (storedCleanup)
		storedCleanup(pamh, storedData, PAM_SUCCESS);
	storedData = data;
	storedCleanup = cleanup;
	return PAM_SUCCESS;
}

void
at_secure_clear(void *value, size_t size)
{
	volatile unsigned char *bytes = value;
	secureClearCalls++;
	while (size--)
		*bytes++ = 0;
}

static pam_handle_t *
testPAMHandle(void)
{
	return (pam_handle_t *)&storedData;
}

static void
testSuccessfulAuthenticationStoresOnlyItsUserPassword(void)
{
	const struct finch_pam_keychain_password *secret = NULL;
	pam_handle_t *pamh = testPAMHandle();

	assert(finch_pam_keychain_password_store(pamh, 6000, "correct horse",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_get(pamh, &secret) == PAM_SUCCESS);
	assert(secret != NULL);
	assert(secret->uid == 6000);
	assert(secret->length == strlen("correct horse"));
	assert(strcmp(secret->value, "correct horse") == 0);
	assert(finch_pam_keychain_password_clear(pamh) == PAM_SUCCESS);
	assert(storedData == NULL);
	assert(storedCleanup == NULL);
	assert(secureClearCalls >= 2);
}

static void
testRefusedAuthenticationDoesNotKeepAPassword(void)
{
	const struct finch_pam_keychain_password *secret = NULL;
	pam_handle_t *pamh = testPAMHandle();

	assert(finch_pam_keychain_password_store(pamh, 6000, "earlier attempt",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_store(pamh, 6000, "wrong password",
	    false) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_get(pamh, &secret) == PAM_SUCCESS);
	assert(secret == NULL);
	assert(storedData == NULL);
}

static void
testRootAndPasswordChangeNeverKeepALoginToken(void)
{
	const struct finch_pam_keychain_password *secret = NULL;
	pam_handle_t *pamh = testPAMHandle();

	assert(finch_pam_keychain_password_store(pamh, 6000, "old password",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_store(pamh, 0, "root password",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_get(pamh, &secret) == PAM_SUCCESS);
	assert(secret == NULL);

	assert(finch_pam_keychain_password_store(pamh, 6000, "old password",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_clear(pamh) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_get(pamh, &secret) == PAM_SUCCESS);
	assert(secret == NULL);
}

static void
testClearWipesBeforeOpenPAMCanReplaceTheData(void)
{
	const struct finch_pam_keychain_password *secret = NULL;
	pam_handle_t *pamh = testPAMHandle();

	assert(finch_pam_keychain_password_store(pamh, 6000, "short-lived",
	    true) == PAM_SUCCESS);
	assert(finch_pam_keychain_password_get(pamh, &secret) == PAM_SUCCESS);
	assert(secret != NULL);
	nextSetStatus = PAM_SYSTEM_ERR;
	assert(finch_pam_keychain_password_clear(pamh) == PAM_SYSTEM_ERR);
	assert(storedData == secret);
	assert(secret->uid == 0);
	assert(secret->length == 0);
	assert(secret->value[0] == '\0');
	assert(finch_pam_keychain_password_clear(pamh) == PAM_SUCCESS);
	assert(storedData == NULL);
	assert(storedCleanup == NULL);
}

int
main(void)
{
	testSuccessfulAuthenticationStoresOnlyItsUserPassword();
	testRefusedAuthenticationDoesNotKeepAPassword();
	testRootAndPasswordChangeNeverKeepALoginToken();
	testClearWipesBeforeOpenPAMCanReplaceTheData();
	assert(storedData == NULL);
	assert(storedCleanup == NULL);
	return 0;
}

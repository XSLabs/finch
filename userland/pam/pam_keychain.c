/* SPDX-License-Identifier: MIT OR Apache-2.0 */

#ifndef OPENPAM
#define OPENPAM
#endif

#include <Security/Security.h>
#include <security/pam_appl.h>
#include <security/openpam.h>
#include <security/pam_modules.h>

#include <limits.h>
#include <pwd.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include "pam_keychain_data.h"

/* Apple's SPI (SecKeychainPriv.h), which Finch's Security exports. */
OSStatus SecKeychainChangePassword(SecKeychainRef keychain, UInt32 oldPasswordLength, const void *oldPassword,
    UInt32 newPasswordLength, const void *newPassword);

#ifndef PAM_EXTERN
#define PAM_EXTERN
#endif

static void
unlockOrCreateDefaultKeychain(const struct finch_pam_keychain_password *secret)
{
	SecKeychainRef defaultKeychain = NULL;
	SecKeychainRef keychain = NULL;
	char path[PATH_MAX];
	UInt32 pathLength = sizeof(path);
	OSStatus status;

	if (!secret || !secret->length || secret->length > UINT32_MAX)
		return;
	status = SecKeychainCopyDefault(&defaultKeychain);
	if (status != errSecSuccess || !defaultKeychain)
		goto done;
	status = SecKeychainGetPath(defaultKeychain, &pathLength, path);
	if (status != errSecSuccess || path[0] != '/')
		goto done;

	status = SecKeychainOpen(path, &keychain);
	if (status == errSecNoSuchKeychain) {
		status = SecKeychainCreate(path, (UInt32)secret->length, secret->value,
		    false, NULL, &keychain);
		if (status == errSecDuplicateKeychain) {
			status = SecKeychainOpen(path, &keychain);
			if (status == errSecSuccess && keychain)
				(void)SecKeychainUnlock(keychain, (UInt32)secret->length,
				    secret->value, true);
		}
	} else if (status == errSecSuccess && keychain) {
		/* A wrong password leaves an existing keychain locked and untouched. */
		(void)SecKeychainUnlock(keychain, (UInt32)secret->length,
		    secret->value, true);
	}

done:
	if (keychain)
		CFRelease(keychain);
	if (defaultKeychain)
		CFRelease(defaultKeychain);
}

PAM_EXTERN int
pam_sm_open_session(pam_handle_t *pamh, int flags, int argc,
	const char *argv[])
{
	const struct finch_pam_keychain_password *secret = NULL;
	const char *username = NULL;
	struct passwd *account;
	uid_t targetUID;
	uid_t originalEUID;
	int clearStatus;
	int pam_err;
	(void)flags;
	(void)argc;
	(void)argv;

	pam_err = finch_pam_keychain_password_get(pamh, &secret);
	if (pam_err != PAM_SUCCESS || !secret)
		goto skip;
	if ((pam_err = pam_get_user(pamh, &username, NULL)) != PAM_SUCCESS ||
	    !username || (account = getpwnam(username)) == NULL ||
	    account->pw_uid == 0 || account->pw_uid != secret->uid)
		goto skip;
	targetUID = account->pw_uid;

	/* Only the root-owned console login path needs a temporary UID switch. */
	originalEUID = geteuid();
	if (getuid() != 0 || originalEUID != 0)
		goto skip;
	if (seteuid(targetUID) != 0)
		goto skip;
	unlockOrCreateDefaultKeychain(secret);
	clearStatus = finch_pam_keychain_password_clear(pamh);
	if (seteuid(originalEUID) != 0 || clearStatus != PAM_SUCCESS)
		return PAM_SYSTEM_ERR;
	return PAM_SUCCESS;

skip:
	return finch_pam_keychain_password_clear(pamh) == PAM_SUCCESS ?
	    PAM_SUCCESS : PAM_SYSTEM_ERR;
}

PAM_EXTERN int
pam_sm_close_session(pam_handle_t *pamh, int flags, int argc,
	const char *argv[])
{
	(void)flags;
	(void)argc;
	(void)argv;
	(void)finch_pam_keychain_password_clear(pamh);
	return PAM_SUCCESS;
}

/* A user's own password change (the old one proven to pam_unix) changes their login keychain's
   password too, as that user. A reset by root, with no old password, leaves the keychain on
   its old password. Keychain errors don't fail the change, which has already been made. */
PAM_EXTERN int
pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char *argv[])
{
	const void *oldPassword = NULL, *newPassword = NULL;
	const char *username = NULL;
	struct passwd *account;
	SecKeychainRef keychain = NULL;
	uid_t originalEUID = geteuid();
	(void)argc;
	(void)argv;

	if (!(flags & PAM_UPDATE_AUTHTOK))
		return PAM_SUCCESS;
	if (pam_get_item(pamh, PAM_OLDAUTHTOK, &oldPassword) != PAM_SUCCESS || !oldPassword ||
	    pam_get_item(pamh, PAM_AUTHTOK, &newPassword) != PAM_SUCCESS || !newPassword ||
	    pam_get_user(pamh, &username, NULL) != PAM_SUCCESS || !username ||
	    (account = getpwnam(username)) == NULL || account->pw_uid == 0 ||
	    getuid() != account->pw_uid ||
	    (originalEUID != 0 && originalEUID != account->pw_uid))
		return PAM_SUCCESS;
	if (originalEUID == 0 && seteuid(account->pw_uid) != 0)
		return PAM_SUCCESS;
	size_t oldLength = strlen(oldPassword), newLength = strlen(newPassword);
	if (oldLength && newLength && oldLength <= UINT32_MAX && newLength <= UINT32_MAX &&
	    SecKeychainCopyDefault(&keychain) == errSecSuccess && keychain)
		(void)SecKeychainChangePassword(keychain, (UInt32)oldLength, oldPassword,
		    (UInt32)newLength, newPassword);
	if (keychain)
		CFRelease(keychain);
	if (originalEUID == 0 && seteuid(originalEUID) != 0)
		return PAM_SYSTEM_ERR;
	return PAM_SUCCESS;
}

PAM_MODULE_ENTRY("pam_keychain");

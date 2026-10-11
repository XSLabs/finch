/*-
 * Copyright (c) 2002-2003 Networks Associates Technology, Inc.
 * Copyright (c) 2004-2007 Dag-Erling Smørgrav
 * All rights reserved.
 *
 * This software was developed for the FreeBSD Project by ThinkSec AS and
 * Network Associates Laboratories, the Security Research Division of
 * Network Associates, Inc.  under DARPA/SPAWAR contract N66001-01-C-8035
 * ("CBOSS"), as part of the DARPA CHATS research program.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior written
 *    permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * $Id: pam_unix.c 408 2007-12-21 11:36:24Z des $
 */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#ifndef OPENPAM
# define OPENPAM
#endif

#include <sys/param.h>

#include <pwd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <account_tools.h>

#include <security/pam_modules.h>
#include <security/pam_appl.h>
#include <security/openpam.h>

#ifndef OPENPAM
static char password_prompt[] = "Password:";
#endif

#ifndef PAM_EXTERN
#define PAM_EXTERN
#endif

PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{
#ifndef OPENPAM
	struct pam_conv *conv;
	struct pam_message msg;
	const struct pam_message *msgp;
	struct pam_response *resp;
#endif
	struct passwd *pwd;
	const char *user;
	char *password;
	int pam_err, retry;

	(void)argc;
	(void)argv;

	/* identify user */
	if ((pam_err = pam_get_user(pamh, &user, NULL)) != PAM_SUCCESS)
		return (pam_err);
	if ((pwd = getpwnam(user)) == NULL)
		return (PAM_USER_UNKNOWN);

	/* get password */
#ifndef OPENPAM
	pam_err = pam_get_item(pamh, PAM_CONV, (const void **)&conv);
	if (pam_err != PAM_SUCCESS)
		return (PAM_SYSTEM_ERR);
	msg.msg_style = PAM_PROMPT_ECHO_OFF;
	msg.msg = password_prompt;
	msgp = &msg;
#endif
	for (retry = 0; retry < 3; ++retry) {
#ifdef OPENPAM
		pam_err = pam_get_authtok(pamh, PAM_AUTHTOK,
		    (const char **)&password, NULL);
#else
		resp = NULL;
		pam_err = (*conv->conv)(1, &msgp, &resp, conv->appdata_ptr);
		if (resp != NULL) {
			if (pam_err == PAM_SUCCESS)
				password = resp->resp;
			else
				free(resp->resp);
			free(resp);
		}
#endif
		if (pam_err == PAM_SUCCESS)
			break;
	}
	if (pam_err == PAM_CONV_ERR)
		return (pam_err);
	if (pam_err != PAM_SUCCESS)
		return (PAM_AUTH_ERR);

	/* Empty and locked passwords never allow a local interactive login. */
	if (!pwd->pw_passwd || !at_password_verify(password, pwd->pw_passwd))
		pam_err = PAM_AUTH_ERR;
	else
		pam_err = PAM_SUCCESS;
#ifndef OPENPAM
	free(password);
#endif
	return (pam_err);
}

PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{

	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return (PAM_SUCCESS);
}

PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{

	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return (PAM_SUCCESS);
}

PAM_EXTERN int
pam_sm_open_session(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{

	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return (PAM_SUCCESS);
}

PAM_EXTERN int
pam_sm_close_session(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{

	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return (PAM_SUCCESS);
}

PAM_EXTERN int
pam_sm_chauthtok(pam_handle_t *pamh, int flags,
	int argc, const char *argv[])
{
	const char *user, *old_password = NULL, *new_password = NULL;
	struct passwd *pwd;
	struct at_store store = { .directory_fd = -1 };
	char error[256] = {0};
	char *confirmation = NULL;
	bool root_override = getuid() == 0;
	int pam_err;
	(void)argc;
	(void)argv;

	if ((pam_err = pam_get_user(pamh, &user, NULL)) != PAM_SUCCESS)
		return pam_err;
	if ((pwd = getpwnam(user)) == NULL)
		return PAM_USER_UNKNOWN;
	if (pwd->pw_uid < 500 || !pwd->pw_passwd ||
	    pwd->pw_passwd[0] == '*' || pwd->pw_passwd[0] == '!' ||
	    pwd->pw_passwd[0] == '\0')
		return PAM_PERM_DENIED;
	if (!root_override && pwd->pw_uid != getuid())
		return PAM_PERM_DENIED;

	/* An ordinary user must prove the old password in both PAM phases. */
	if (!root_override) {
		pam_err = pam_get_authtok(pamh, PAM_OLDAUTHTOK, &old_password,
		    "Current password: ");
		if (pam_err != PAM_SUCCESS)
			return pam_err;
		if (!at_password_verify(old_password, pwd->pw_passwd))
			return PAM_AUTH_ERR;
	}
	if (flags & PAM_PRELIM_CHECK)
		return PAM_SUCCESS;
	if (!(flags & PAM_UPDATE_AUTHTOK))
		return PAM_SERVICE_ERR;

	pam_err = pam_get_authtok(pamh, PAM_AUTHTOK, &new_password,
	    "New password: ");
	if (pam_err != PAM_SUCCESS)
		return pam_err;
	if (!at_password_is_acceptable(new_password))
		return PAM_AUTHTOK_ERR;
	pam_err = pam_prompt(pamh, PAM_PROMPT_ECHO_OFF, &confirmation,
	    "Repeat new password: ");
	if (pam_err != PAM_SUCCESS)
		return pam_err;
	if (!confirmation || strcmp(new_password, confirmation) != 0) {
		if (confirmation) {
			at_secure_clear(confirmation, strlen(confirmation) + 1);
			free(confirmation);
		}
		return PAM_TRY_AGAIN;
	}
	at_secure_clear(confirmation, strlen(confirmation) + 1);
	free(confirmation);
	if (at_store_open(&store, "/private/etc", error, sizeof(error)) != 0)
		return PAM_AUTHTOK_ERR;
	int changed = at_store_change_password(&store, user, getuid(),
	    root_override, root_override ? NULL : old_password, new_password,
	    error, sizeof(error));
	at_store_close(&store);
	return changed == 0 ? PAM_SUCCESS : PAM_AUTHTOK_ERR;
}

#ifdef PAM_MODULE_ENTRY
PAM_MODULE_ENTRY("pam_unix");
#endif

/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ACCOUNT_TOOLS_H
#define FINCH_ACCOUNT_TOOLS_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

#define AT_PASSWORD_MAX 1024
#define AT_PASSWORD_MIN 12

struct at_store {
	int directory_fd;
	uid_t owner;
};

/* These hashes are for local interactive logins. New hashes never use DES. */
int at_password_hash(const char *password, char *out, size_t out_size);
int at_password_verify(const char *password, const char *stored_hash);
int at_password_is_acceptable(const char *password);
void at_secure_clear(void *value, size_t size);

/* directory must be an absolute, non-symlink path owned by the caller. */
int at_store_open(struct at_store *store, const char *directory,
	char *error, size_t error_size);
/* Uses the root-owned /etc/finch/account-store setting when present. An absent
 * setting keeps older images on /private/etc. */
int at_store_open_default(struct at_store *store, char *error,
	size_t error_size);
void at_store_close(struct at_store *store);

#if defined(AT_ACCOUNT_TOOLS_TESTING)
/* Lets host tests exercise the same selector without touching /private/etc. */
int at_test_store_open_default(struct at_store *store, const char *config_path,
	const char *fallback_directory, uid_t config_owner, char *error,
	size_t error_size);
#endif

/* New accounts must use an existing group and a non-system uid (500+).
 * This legacy helper only updates account files; it does not touch HOME. */
int at_store_create_user(struct at_store *store, const char *name, uid_t uid,
	gid_t gid, const char *gecos, const char *home, const char *shell,
	const char *password, char *error, size_t error_size);

/* Like at_store_create_user, but safely creates HOME under target_root. HOME
 * is an absolute path inside target_root. Existing homes are accepted only
 * when they are empty real directories owned by uid:gid with mode 0700. */
int at_store_create_user_with_home_root(struct at_store *store,
	const char *name, uid_t uid, gid_t gid, const char *gecos,
	const char *home, const char *shell, const char *password,
	const char *target_root, char *error, size_t error_size);

/* A non-root caller may only change their own password and must prove the old one. */
int at_store_change_password(struct at_store *store, const char *name,
	uid_t actor_uid, bool root_override, const char *old_password,
	const char *new_password, char *error, size_t error_size);

#endif

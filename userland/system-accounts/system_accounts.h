#ifndef FINCH_SYSTEM_ACCOUNTS_H
#define FINCH_SYSTEM_ACCOUNTS_H

#include <stddef.h>
#include <sys/types.h>

typedef struct sa_notifyd_plan sa_notifyd_plan;

/* For old payloads, return a NULL plan if no present account file has _notifyd. */
int sa_notifyd_plan_load_optional(const char *template_dir,
                                  sa_notifyd_plan **plan_out,
                                  char *error,
                                  size_t error_size);
/* Keep only the one checked service-account record, not the source database. */
int sa_notifyd_plan_load(const char *template_dir,
                         sa_notifyd_plan **plan_out,
                         char *error,
                         size_t error_size);
void sa_notifyd_plan_free(sa_notifyd_plan *plan);
int sa_notifyd_plan_apply_staged(const sa_notifyd_plan *plan,
                                 const char *target_dir,
                                 char *error,
                                 size_t error_size);

/*
 * Add the locked _notifyd user and group from template_dir to an offline,
 * disposable account directory. The caller must discard target_dir after an
 * error, since a crash between file renames can leave that staging copy part
 * updated. The live root is never opened or changed by this helper.
 *
 * Returns 1 when files changed, 0 when already current, and -1 on error.
 */
int sa_merge_notifyd_staged(const char *template_dir,
                            const char *target_dir,
                            char *error,
                            size_t error_size);

/* Set only the three account files to root:wheel and their standard modes. */
int sa_normalize_staged_account_files(const char *target_dir,
                                     char *error,
                                     size_t error_size);

/* Check the staged files without changing them. */
int sa_notifyd_plan_verify_staged(const sa_notifyd_plan *plan,
                                  const char *target_dir,
                                  uid_t expected_uid,
                                  gid_t expected_gid,
                                  char *error,
                                  size_t error_size);

#ifdef SYSTEM_ACCOUNTS_TESTING
/* Fail just after the requested replacement. Zero disables the fail point. */
void sa_test_fail_after_replace(unsigned int replacement_number);
int sa_test_normalize_staged_account_files(const char *target_dir,
                                           uid_t owner,
                                           gid_t group,
                                           char *error,
                                           size_t error_size);
#endif

#endif

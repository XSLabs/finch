#include "system_accounts.h"

#include <stdio.h>
#include <string.h>

int
main(int argc, char **argv)
{
    const char *template_dir = NULL;
    const char *target_dir = NULL;
    char error[512];
    int result;
    int i;

    if (argc == 3 && strcmp(argv[1], "--normalize-staged") == 0) {
        result = sa_normalize_staged_account_files(argv[2], error, sizeof(error));
        if (result != 0) {
            fprintf(stderr, "system account normalization failed: %s\n",
                    error[0] == '\0' ? "unknown error" : error);
            return 1;
        }
        puts("staged account files now have root:wheel ownership and standard modes");
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--verify-staged") == 0) {
        sa_notifyd_plan *plan = NULL;
        for (i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--template") == 0 && i + 1 < argc && template_dir == NULL) {
                template_dir = argv[++i];
            } else if (strcmp(argv[i], "--target") == 0 && i + 1 < argc && target_dir == NULL) {
                target_dir = argv[++i];
            } else {
                fprintf(stderr, "usage: %s --verify-staged --template DIR --target STAGED_ETC_DIR\n", argv[0]);
                return 2;
            }
        }
        if (template_dir == NULL || target_dir == NULL) {
            fprintf(stderr, "usage: %s --verify-staged --template DIR --target STAGED_ETC_DIR\n", argv[0]);
            return 2;
        }
        if (sa_notifyd_plan_load(template_dir, &plan, error, sizeof(error)) != 0) {
            fprintf(stderr, "system account verification failed: %s\n",
                    error[0] == '\0' ? "cannot load the service-account template" : error);
            return 1;
        }
        result = sa_notifyd_plan_verify_staged(plan, target_dir, 0, 0,
                                               error, sizeof(error));
        sa_notifyd_plan_free(plan);
        if (result != 0) {
            fprintf(stderr, "system account verification failed: %s\n",
                    error[0] == '\0' ? "unknown error" : error);
            return 1;
        }
        puts("staged account files and _notifyd entry verified");
        return 0;
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--template") == 0 && i + 1 < argc) {
            if (template_dir != NULL) goto usage;
            template_dir = argv[++i];
        } else if (strcmp(argv[i], "--target") == 0 && i + 1 < argc) {
            if (target_dir != NULL) goto usage;
            target_dir = argv[++i];
        } else {
            goto usage;
        }
    }
    if (template_dir == NULL || target_dir == NULL) {
        goto usage;
    }
    result = sa_merge_notifyd_staged(template_dir, target_dir, error, sizeof(error));
    if (result < 0) {
        fprintf(stderr, "system account merge failed: %s\n", error[0] == '\0' ? "unknown error" : error);
        return 1;
    }
    puts(result ? "_notifyd account files updated" : "_notifyd account already current");
    return 0;

usage:
    fprintf(stderr,
            "usage: %s --template DIR --target STAGED_ETC_DIR\n"
            "       %s --normalize-staged STAGED_ETC_DIR\n"
            "       %s --verify-staged --template DIR --target STAGED_ETC_DIR\n",
            argv[0], argv[0], argv[0]);
    return 2;
}

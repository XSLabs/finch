#define _DARWIN_C_SOURCE 1
#include "../system_accounts.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned int checks;
static unsigned int failures;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); \
    } \
} while (0)

typedef struct {
    char root[256];
    char template_dir[320];
    char target_dir[320];
} fixture;

static int
join(char *out, size_t size, const char *dir, const char *name)
{
    int n = snprintf(out, size, "%s/%s", dir, name);
    return n >= 0 && (size_t)n < size ? 0 : -1;
}

static int
write_file(const char *dir, const char *name, const char *contents, mode_t mode)
{
    char path[512];
    int fd;
    size_t length = strlen(contents);
    size_t offset = 0;
    if (join(path, sizeof(path), dir, name) != 0) return -1;
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return -1;
    while (offset < length) {
        ssize_t n = write(fd, contents + offset, length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        offset += (size_t)n;
    }
    if (fchmod(fd, mode) != 0 || close(fd) != 0) return -1;
    return 0;
}

static char *
read_file(const char *dir, const char *name)
{
    char path[512];
    struct stat st;
    char *data;
    int fd;
    size_t offset = 0;
    if (join(path, sizeof(path), dir, name) != 0) return NULL;
    fd = open(path, O_RDONLY);
    if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 0) {
        if (fd >= 0) close(fd);
        return NULL;
    }
    data = malloc((size_t)st.st_size + 1);
    if (data == NULL) { close(fd); return NULL; }
    while (offset < (size_t)st.st_size) {
        ssize_t n = read(fd, data + offset, (size_t)st.st_size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { free(data); close(fd); return NULL; }
        offset += (size_t)n;
    }
    data[offset] = '\0';
    close(fd);
    return data;
}

static void
remove_tree(const char *dir)
{
    static const char *names[] = {"master.passwd", "group", "passwd", "link", NULL};
    char path[512];
    size_t i;
    for (i = 0; names[i] != NULL; i++) {
        if (join(path, sizeof(path), dir, names[i]) == 0) (void)unlink(path);
    }
    (void)rmdir(dir);
}

static int
new_fixture(fixture *f)
{
    char pattern[] = "/private/tmp/finch-system-accounts.XXXXXX";
    char *root = mkdtemp(pattern);
    if (root == NULL || strlen(root) >= sizeof(f->root)) return -1;
    strcpy(f->root, root);
    if (join(f->template_dir, sizeof(f->template_dir), f->root, "template") != 0 ||
        join(f->target_dir, sizeof(f->target_dir), f->root, "target") != 0 ||
        mkdir(f->template_dir, 0700) != 0 || mkdir(f->target_dir, 0700) != 0) return -1;
    if (write_file(f->template_dir, "master.passwd",
            "_notifyd:*:211:211::0:0:Notification Server:/var/empty:/sbin/nologin\n", 0644) != 0 ||
        write_file(f->template_dir, "group", "_notifyd:*:211:\n", 0644) != 0 ||
        write_file(f->target_dir, "master.passwd",
            "# local accounts\nroot:*:0:0::0:0:root:/var/root:/bin/sh\nuser:*:501:20::0:0:User:/Users/user:/bin/sh\n", 0600) != 0 ||
        write_file(f->target_dir, "group",
            "# local groups\nwheel:*:0:root\nstaff:*:20:user\n", 0644) != 0 ||
        write_file(f->target_dir, "passwd",
            "# local accounts\nroot:*:0:0:root:/var/root:/bin/sh\nuser:*:501:20:User:/Users/user:/bin/sh\n", 0644) != 0) return -1;
    return 0;
}

static int
merge(fixture *f, char *error, size_t error_size)
{
    return sa_merge_notifyd_staged(f->template_dir, f->target_dir, error, error_size);
}

static void
test_add_and_idempotent(void)
{
    fixture f;
    char error[256];
    char *master;
    char *group;
    char *passwd;
    struct stat st;
    char path[512];
    CHECK(new_fixture(&f) == 0, "create basic fixture");
    CHECK(merge(&f, error, sizeof(error)) == 1, "first run adds service account");
    master = read_file(f.target_dir, "master.passwd");
    group = read_file(f.target_dir, "group");
    passwd = read_file(f.target_dir, "passwd");
    CHECK(master != NULL && strstr(master, "root:*:0:0") != NULL &&
          strstr(master, "_notifyd:*:211:211::0:0:Notification Server:/var/empty:/sbin/nologin\n") != NULL,
          "master file keeps existing accounts and adds the locked _notifyd row");
    CHECK(group != NULL && strstr(group, "staff:*:20:user\n") != NULL &&
          strstr(group, "_notifyd:*:211:\n") != NULL,
          "group file keeps existing groups and adds the private service group");
    CHECK(passwd != NULL && strstr(passwd, "_notifyd:*:211:211:Notification Server:/var/empty:/sbin/nologin\n") != NULL &&
          strstr(passwd, "Notification Server:$") == NULL,
          "public passwd has the service row without a password hash");
    if (join(path, sizeof(path), f.target_dir, "master.passwd") == 0 && stat(path, &st) == 0) {
        CHECK((st.st_mode & 0777) == 0600, "master.passwd keeps private permissions");
    } else CHECK(0, "stat master.passwd");
    if (join(path, sizeof(path), f.target_dir, "group") == 0 && stat(path, &st) == 0) {
        CHECK((st.st_mode & 0777) == 0644, "group keeps public permissions");
    } else CHECK(0, "stat group");
    CHECK(merge(&f, error, sizeof(error)) == 0, "second run is an exact no-op");
    free(master); free(group); free(passwd);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_public_passwd_repair(void)
{
    fixture f;
    char error[256];
    char *passwd;
    char path[512];
    CHECK(new_fixture(&f) == 0, "create passwd repair fixture");
    CHECK(merge(&f, error, sizeof(error)) == 1, "add account before passwd repair");
    CHECK(write_file(f.target_dir, "passwd", "stale\n", 0644) == 0,
          "write stale public passwd");
    CHECK(merge(&f, error, sizeof(error)) == 1, "replace stale public passwd");
    passwd = read_file(f.target_dir, "passwd");
    CHECK(passwd != NULL && strstr(passwd, "_notifyd:*:211:211:Notification Server") != NULL &&
          strstr(passwd, "stale") == NULL, "stale projection is replaced from master.passwd");
    free(passwd);
    CHECK(join(path, sizeof(path), f.target_dir, "passwd") == 0 && unlink(path) == 0,
          "remove public passwd");
    CHECK(merge(&f, error, sizeof(error)) == 1, "recreate missing public passwd");
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_plan_survives_template_replacement(void)
{
    fixture f;
    char error[256];
    char path[512];
    char *master;
    sa_notifyd_plan *plan = NULL;
    CHECK(new_fixture(&f) == 0, "create staged-plan fixture");
    CHECK(sa_notifyd_plan_load(f.template_dir, &plan, error, sizeof(error)) == 0 && plan != NULL,
          "load a checked service-account plan");
    CHECK(join(path, sizeof(path), f.template_dir, "master.passwd") == 0 && unlink(path) == 0 &&
          join(path, sizeof(path), f.template_dir, "group") == 0 && unlink(path) == 0,
          "remove source account databases after planning");
    CHECK(plan != NULL && sa_notifyd_plan_apply_staged(plan, f.target_dir, error, sizeof(error)) == 1,
          "apply uses the small saved plan after carry replaces the staged files");
    master = read_file(f.target_dir, "master.passwd");
    CHECK(master != NULL && strstr(master, "_notifyd:*:211:211") != NULL,
          "saved plan adds only the checked service account");
    free(master);
    sa_notifyd_plan_free(plan);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_optional_old_payloads(void)
{
    fixture f;
    char error[256];
    char path[512];
    sa_notifyd_plan *plan = NULL;
    CHECK(new_fixture(&f) == 0, "create optional-plan fixture");
    CHECK(join(path, sizeof(path), f.template_dir, "master.passwd") == 0 && unlink(path) == 0 &&
          join(path, sizeof(path), f.template_dir, "group") == 0 && unlink(path) == 0,
          "remove both account files from an old payload");
    CHECK(sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == 0 && plan == NULL,
          "old payload with no account files needs no migration");
    CHECK(sa_notifyd_plan_load(f.template_dir, &plan, error, sizeof(error)) == -1,
          "strict CLI loader still requires its template account");
    CHECK(write_file(f.template_dir, "master.passwd",
            "root:*:0:0::0:0:root:/var/root:/bin/sh\n", 0644) == 0,
          "add only an older master.passwd");
    CHECK(sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == 0 && plan == NULL,
          "old payload with unrelated master entries and no group needs no migration");
    CHECK(write_file(f.template_dir, "master.passwd",
            "_notifyd:*:211:211::0:0:Notification Server:/var/empty:/sbin/nologin\n", 0644) == 0,
          "add a partial service user");
    CHECK(sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "only part") != NULL,
          "partial service account without its group is rejected");
    CHECK(write_file(f.template_dir, "group", "broken\n", 0644) == 0,
          "add malformed old group file");
    CHECK(sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1,
          "malformed present account file is rejected");
    sa_notifyd_plan_free(plan);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static int
write_template_ids(const fixture *f, const char *uid, const char *gid)
{
    char master[512];
    char group[128];
    int n1 = snprintf(master, sizeof(master),
        "_notifyd:*:%s:%s::0:0:Notification Server:/var/empty:/sbin/nologin\n", uid, gid);
    int n2 = snprintf(group, sizeof(group), "_notifyd:*:%s:\n", gid);
    if (n1 < 0 || (size_t)n1 >= sizeof(master) || n2 < 0 || (size_t)n2 >= sizeof(group)) {
        return -1;
    }
    return write_file(f->template_dir, "master.passwd", master, 0644) == 0 &&
           write_file(f->template_dir, "group", group, 0644) == 0 ? 0 : -1;
}

static void
test_rejects_unsafe_system_ids(void)
{
    fixture f;
    sa_notifyd_plan *plan = NULL;
    char error[256];
    CHECK(new_fixture(&f) == 0, "create reserved-ID fixture");
    CHECK(write_template_ids(&f, "0", "11") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "between 2 and 499") != NULL,
          "root UID is rejected for a service account");
    CHECK(write_template_ids(&f, "-2", "11") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "between 2 and 499") != NULL,
          "nobody UID is rejected for a service account");
    CHECK(write_template_ids(&f, "500", "211") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "between 2 and 499") != NULL,
          "user IDs above the reserved system range are rejected");
    CHECK(write_template_ids(&f, "211", "500") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "between 2 and 499") != NULL,
          "group IDs above the reserved system range are rejected");
    CHECK(write_template_ids(&f, "11", "0") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == -1 &&
          strstr(error, "between 2 and 499") != NULL,
          "root GID is rejected for a service account");
    CHECK(write_template_ids(&f, "2", "499") == 0 &&
          sa_notifyd_plan_load_optional(f.template_dir, &plan, error, sizeof(error)) == 0 &&
          plan != NULL,
          "reserved system ID endpoints are accepted");
    sa_notifyd_plan_free(plan);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_optional_missing_directory(void)
{
    fixture f;
    char missing[512];
    char link_path[512];
    char error[256];
    sa_notifyd_plan *plan = NULL;
    CHECK(new_fixture(&f) == 0, "create missing-directory fixture");
    CHECK(snprintf(missing, sizeof(missing), "%s/private/etc", f.root) > 0,
          "build old payload account path");
    CHECK(sa_notifyd_plan_load_optional(missing, &plan, error, sizeof(error)) == 0 && plan == NULL,
          "old payload without private/etc needs no account migration");
    CHECK(sa_notifyd_plan_load(missing, &plan, error, sizeof(error)) == -1,
          "strict template loader still rejects a missing directory");
    CHECK(snprintf(link_path, sizeof(link_path), "%s/template-link", f.root) > 0 &&
          symlink(f.template_dir, link_path) == 0,
          "make a template directory symlink");
    CHECK(sa_notifyd_plan_load_optional(link_path, &plan, error, sizeof(error)) == -1,
          "optional loading does not hide an unsafe symlink path");
    (void)unlink(link_path);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_collisions_and_bad_input(void)
{
    fixture f;
    char error[256];
    char *before;
    char *after;
    CHECK(new_fixture(&f) == 0, "create conflict fixture");
    CHECK(write_file(f.target_dir, "master.passwd",
            "root:*:0:0::0:0:root:/var/root:/bin/sh\nother:*:211:20::0:0:Other:/var/empty:/sbin/nologin\n", 0600) == 0,
          "write conflicting UID");
    before = read_file(f.target_dir, "master.passwd");
    CHECK(merge(&f, error, sizeof(error)) == -1 && strstr(error, "already used") != NULL,
          "existing UID collision is rejected");
    after = read_file(f.target_dir, "master.passwd");
    CHECK(before != NULL && after != NULL && strcmp(before, after) == 0,
          "collision leaves staged account files untouched");
    free(before); free(after);
    CHECK(write_file(f.target_dir, "master.passwd",
            "root:*:0:0::0:0:root:/var/root:/bin/sh\n", 0600) == 0 &&
          write_file(f.target_dir, "group", "wheel:*:0:root\nother:*:211:\n", 0644) == 0,
          "write conflicting GID");
    CHECK(merge(&f, error, sizeof(error)) == -1 && strstr(error, "already used") != NULL,
          "existing GID collision is rejected");
    CHECK(write_file(f.target_dir, "group", "wheel:*:0:root\n", 0644) == 0 &&
          write_file(f.target_dir, "master.passwd", "broken\n", 0600) == 0,
          "write malformed account file");
    CHECK(merge(&f, error, sizeof(error)) == -1, "malformed target is rejected");
    CHECK(write_file(f.target_dir, "master.passwd",
            "root:*:0:0::0:0:root:/var/root:/bin/sh\n", 0600) == 0 &&
          write_file(f.template_dir, "master.passwd",
            "other:*:211:211::0:0:Other:/var/empty:/sbin/nologin\n", 0644) == 0,
          "remove required account from template");
    CHECK(merge(&f, error, sizeof(error)) == -1 && strstr(error, "only part") != NULL,
          "missing template account is rejected");
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_unsafe_files(void)
{
    fixture f;
    char error[256];
    char path[512];
    CHECK(new_fixture(&f) == 0, "create unsafe-file fixture");
    CHECK(join(path, sizeof(path), f.target_dir, "master.passwd") == 0 &&
          chmod(path, 0644) == 0, "change private file mode");
    CHECK(merge(&f, error, sizeof(error)) == -1 && strstr(error, "unsafe file or mode") != NULL,
          "wrong master.passwd mode is rejected");
    CHECK(chmod(path, 0600) == 0, "restore private file mode");
    CHECK(join(path, sizeof(path), f.target_dir, "passwd") == 0 && unlink(path) == 0 &&
          symlink("master.passwd", path) == 0, "replace public passwd with a symlink");
    CHECK(merge(&f, error, sizeof(error)) == -1 && strstr(error, "cannot open passwd") != NULL,
          "symlinked public passwd is rejected");
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

static void
test_staged_failure(void)
{
    fixture live, stage;
    char error[256];
    char *live_master;
    char *live_after;
    char *stage_master;
    CHECK(new_fixture(&live) == 0, "create live fixture");
    CHECK(new_fixture(&stage) == 0, "create separate staging fixture");
    live_master = read_file(live.target_dir, "master.passwd");
    sa_test_fail_after_replace(1);
    CHECK(merge(&stage, error, sizeof(error)) == -1 && strstr(error, "injected failure") != NULL,
          "interrupted multi-file update fails closed");
    sa_test_fail_after_replace(0);
    live_after = read_file(live.target_dir, "master.passwd");
    stage_master = read_file(stage.target_dir, "master.passwd");
    CHECK(live_master != NULL && live_after != NULL && strcmp(live_master, live_after) == 0,
          "failure in a disposable stage cannot change the live account files");
    CHECK(stage_master != NULL && strstr(stage_master, "_notifyd:*:211:211") != NULL,
          "the failed stage may be partial and must be discarded");
    free(live_master); free(live_after); free(stage_master);
    remove_tree(live.template_dir); remove_tree(live.target_dir); (void)rmdir(live.root);
    remove_tree(stage.template_dir); remove_tree(stage.target_dir); (void)rmdir(stage.root);
}

static void
test_staged_verification_and_normalization(void)
{
    fixture f;
    sa_notifyd_plan *plan = NULL;
    char error[256];
    char path[512];
    struct stat directory_st, file_st;
    char *master_before;
    char *master_after;

    CHECK(new_fixture(&f) == 0, "create staged verification fixture");
    CHECK(sa_notifyd_plan_load(f.template_dir, &plan, error, sizeof(error)) == 0 && plan != NULL,
          "load template for staged verification");
    CHECK(merge(&f, error, sizeof(error)) == 1,
          "merge account before staged verification");
    CHECK(stat(f.target_dir, &directory_st) == 0,
          "read staged account directory owner");
    CHECK(plan != NULL &&
          sa_notifyd_plan_verify_staged(plan, f.target_dir, directory_st.st_uid,
                                        directory_st.st_gid, error, sizeof(error)) == 0,
          "verify the exact service account, public projection, owners and modes");

    CHECK(join(path, sizeof(path), f.target_dir, "master.passwd") == 0 &&
          chmod(path, 0644) == 0, "make the private staged file too open");
    CHECK(sa_notifyd_plan_verify_staged(plan, f.target_dir, directory_st.st_uid,
                                        directory_st.st_gid, error, sizeof(error)) == -1,
          "verification rejects an unsafe file mode");
    master_before = read_file(f.target_dir, "master.passwd");
    CHECK(sa_test_normalize_staged_account_files(f.target_dir, directory_st.st_uid,
                                                  directory_st.st_gid, error,
                                                  sizeof(error)) == 0,
          "normalization repairs only staged account file owners and modes");
    master_after = read_file(f.target_dir, "master.passwd");
    CHECK(master_before != NULL && master_after != NULL &&
          strcmp(master_before, master_after) == 0,
          "normalization does not change account text");
    CHECK(stat(path, &file_st) == 0 && (file_st.st_mode & 07777) == 0600 &&
          file_st.st_uid == directory_st.st_uid && file_st.st_gid == directory_st.st_gid,
          "normalization restores master.passwd owner, group and private mode");
    CHECK(sa_notifyd_plan_verify_staged(plan, f.target_dir, directory_st.st_uid,
                                        directory_st.st_gid, error, sizeof(error)) == 0,
          "normalized staged account files pass verification");

    CHECK(write_file(f.target_dir, "passwd", "stale\n", 0644) == 0,
          "replace the public projection with stale text");
    CHECK(sa_notifyd_plan_verify_staged(plan, f.target_dir, directory_st.st_uid,
                                        directory_st.st_gid, error, sizeof(error)) == -1 &&
          strstr(error, "public passwd") != NULL,
          "verification rejects a stale public projection");
    if (geteuid() != 0) {
        CHECK(sa_normalize_staged_account_files(f.target_dir, error, sizeof(error)) == -1 &&
              strstr(error, "must run as root") != NULL,
              "production normalization requires root");
    }
    free(master_before);
    free(master_after);
    sa_notifyd_plan_free(plan);
    remove_tree(f.template_dir); remove_tree(f.target_dir); (void)rmdir(f.root);
}

int
main(void)
{
    test_add_and_idempotent();
    test_public_passwd_repair();
    test_plan_survives_template_replacement();
    test_optional_old_payloads();
    test_rejects_unsafe_system_ids();
    test_optional_missing_directory();
    test_collisions_and_bad_input();
    test_unsafe_files();
    test_staged_failure();
    test_staged_verification_and_normalization();
    if (failures != 0) {
        fprintf(stderr, "system account merge: %u checks, %u failures\n", checks, failures);
        return 1;
    }
    printf("system account merge: %u checks passed\n", checks);
    return 0;
}

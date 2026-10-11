/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* VM-only fixture: run the real settings service inside a prepared test root.
 * Loading the program before chroot avoids executing an untrusted copy from
 * the guest's temporary filesystem. Production configd has no such option. */
#define main configd_service_main
#include "../oss/configd.daemon.c"
#undef main

int main(int argc, char **argv)
{
    const char *root = "/private/var/rw/configd-service-root";
    if (geteuid() != 0) {
        fputs("configd fixture requires root inside Finch's test VM\n", stderr);
        return 1;
    }
    int fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) < 0 || st.st_uid != 0 ||
        (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 || fchdir(fd) < 0) {
        fputs("configd fixture needs its prepared root-owned folder\n", stderr);
        if (fd >= 0) close(fd);
        return 1;
    }
    close(fd);
    if (chroot(".") < 0 || chdir("/") < 0) {
        perror("configd fixture chroot");
        return 1;
    }
    return configd_service_main(argc, argv);
}

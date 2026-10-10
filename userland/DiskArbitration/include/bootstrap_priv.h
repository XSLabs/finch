/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch: the private bootstrap calls DiskArbitration makes (userland/libxpc/bootstrap.c). */
#ifndef FINCH_BOOTSTRAP_PRIV_H
#define FINCH_BOOTSTRAP_PRIV_H
#include <servers/bootstrap.h>
#include <sys/types.h>

#define BOOTSTRAP_PRIVILEGED_SERVER 0x2
#define BOOTSTRAP_PER_PID_SERVICE   0x1

__BEGIN_DECLS
kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp, pid_t target_pid, uint64_t flags);
__END_DECLS
#endif

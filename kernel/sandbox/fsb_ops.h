/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Sandbox operation names, as SBPL profiles spell them (macOS 26.4's set, in
 * its order). A name ending in '*' is a group: rules on it apply to every
 * operation it prefixes that has no matching rule of its own. FSB_OP_* index
 * this table; compiled profiles store rules per index, so the order is ABI.
 * FSB_OP_PARENTS gives each operation's nearest group, and default's for
 * ungrouped ones (default itself has none).
 *
 * Generated from the names by tools/sandbox/gen-ops.py; don't edit by hand.
 */
#ifndef FSB_OPS_H
#define FSB_OPS_H

#define FSB_OP_DEFAULT                                           0
#define FSB_OP_APPLEEVENT_SEND                                   1
#define FSB_OP_AUTHORIZATION_RIGHT_OBTAIN                        2
#define FSB_OP_BOOT_ARG_SET                                      3
#define FSB_OP_CONSUME_EXTENSION                                 4
#define FSB_OP_DEVICE_ALL                                        5
#define FSB_OP_DEVICE_CAMERA                                     6
#define FSB_OP_DEVICE_MICROPHONE                                 7
#define FSB_OP_DARWIN_NOTIFICATION_POST                          8
#define FSB_OP_DISTRIBUTED_NOTIFICATION_POST                     9
#define FSB_OP_DYNAMIC_CODE_GENERATION                           10
#define FSB_OP_FILE_ALL                                          11
#define FSB_OP_FILE_CHROOT                                       12
#define FSB_OP_FILE_CLONE                                        13
#define FSB_OP_FILE_GRAFT                                        14
#define FSB_OP_FILE_IOCTL                                        15
#define FSB_OP_FILE_ISSUE_EXTENSION                              16
#define FSB_OP_FILE_LINK                                         17
#define FSB_OP_FILE_LOCK                                         18
#define FSB_OP_FILE_MAP_EXECUTABLE                               19
#define FSB_OP_FILE_MKNOD                                        20
#define FSB_OP_FILE_MOUNT                                        21
#define FSB_OP_FILE_MOUNT_UPDATE                                 22
#define FSB_OP_FILE_READ_ALL                                     23
#define FSB_OP_FILE_READ_DATA                                    24
#define FSB_OP_FILE_READ_METADATA                                25
#define FSB_OP_FILE_READ_XATTR                                   26
#define FSB_OP_FILE_REVOKE                                       27
#define FSB_OP_FILE_SEARCH                                       28
#define FSB_OP_FILE_TEST_EXISTENCE                               29
#define FSB_OP_FILE_UNGRAFT                                      30
#define FSB_OP_FILE_UNMOUNT                                      31
#define FSB_OP_FILE_WRITE_ALL                                    32
#define FSB_OP_FILE_WRITE_ACL                                    33
#define FSB_OP_FILE_WRITE_CREATE                                 34
#define FSB_OP_FILE_WRITE_DATA                                   35
#define FSB_OP_FILE_WRITE_FINDERINFO                             36
#define FSB_OP_FILE_WRITE_FLAGS                                  37
#define FSB_OP_FILE_WRITE_MODE                                   38
#define FSB_OP_FILE_WRITE_OWNER                                  39
#define FSB_OP_FILE_WRITE_SETUGID                                40
#define FSB_OP_FILE_WRITE_TIMES                                  41
#define FSB_OP_FILE_WRITE_UNLINK                                 42
#define FSB_OP_FILE_WRITE_XATTR                                  43
#define FSB_OP_FS_QUOTA_ALL                                      44
#define FSB_OP_FS_QUOTA_GET                                      45
#define FSB_OP_FS_QUOTA_ON                                       46
#define FSB_OP_FS_QUOTA_OFF                                      47
#define FSB_OP_FS_QUOTA_SET_ALL                                  48
#define FSB_OP_FS_QUOTA_SET_LIMITS                               49
#define FSB_OP_FS_QUOTA_SET_USAGE                                50
#define FSB_OP_FS_QUOTA_STAT                                     51
#define FSB_OP_FS_QUOTA_SYNC                                     52
#define FSB_OP_FS_RENAME                                         53
#define FSB_OP_FS_SNAPSHOT_ALL                                   54
#define FSB_OP_FS_SNAPSHOT_CREATE                                55
#define FSB_OP_FS_SNAPSHOT_DELETE                                56
#define FSB_OP_FS_SNAPSHOT_MOUNT                                 57
#define FSB_OP_FS_SNAPSHOT_REVERT                                58
#define FSB_OP_GENERIC_ISSUE_EXTENSION                           59
#define FSB_OP_QTN_USER                                          60
#define FSB_OP_HID_CONTROL                                       61
#define FSB_OP_IOKIT_ALL                                         62
#define FSB_OP_IOKIT_GET_PROPERTIES                              63
#define FSB_OP_IOKIT_ISSUE_EXTENSION                             64
#define FSB_OP_IOKIT_OPEN_ALL                                    65
#define FSB_OP_IOKIT_OPEN_USER_CLIENT                            66
#define FSB_OP_IOKIT_OPEN_SERVICE                                67
#define FSB_OP_IOKIT_SET_PROPERTIES                              68
#define FSB_OP_IPC_ALL                                           69
#define FSB_OP_IPC_POSIX_ALL                                     70
#define FSB_OP_IPC_POSIX_SEM_ALL                                 71
#define FSB_OP_IPC_POSIX_SEM_CREATE                              72
#define FSB_OP_IPC_POSIX_SEM_OPEN                                73
#define FSB_OP_IPC_POSIX_SEM_POST                                74
#define FSB_OP_IPC_POSIX_SEM_UNLINK                              75
#define FSB_OP_IPC_POSIX_SEM_WAIT                                76
#define FSB_OP_IPC_POSIX_SHM_ALL                                 77
#define FSB_OP_IPC_POSIX_SHM_READ_DATA                           78
#define FSB_OP_IPC_POSIX_SHM_WRITE_ALL                           79
#define FSB_OP_IPC_POSIX_SHM_WRITE_CREATE                        80
#define FSB_OP_IPC_POSIX_SHM_WRITE_DATA                          81
#define FSB_OP_IPC_POSIX_SHM_WRITE_UNLINK                        82
#define FSB_OP_IPC_SYSV_ALL                                      83
#define FSB_OP_IPC_SYSV_MSG                                      84
#define FSB_OP_IPC_SYSV_SEM                                      85
#define FSB_OP_IPC_SYSV_SHM                                      86
#define FSB_OP_JOB_CREATION                                      87
#define FSB_OP_LSOPEN                                            88
#define FSB_OP_MACH_ALL                                          89
#define FSB_OP_MACH_BOOTSTRAP                                    90
#define FSB_OP_MACH_CROSS_DOMAIN_LOOKUP                          91
#define FSB_OP_MACH_DERIVE_PORT                                  92
#define FSB_OP_MACH_HOST_ALL                                     93
#define FSB_OP_MACH_HOST_EXCEPTION_PORT_SET                      94
#define FSB_OP_MACH_HOST_SPECIAL_PORT_SET                        95
#define FSB_OP_MACH_ISSUE_EXTENSION                              96
#define FSB_OP_MACH_LOOKUP                                       97
#define FSB_OP_MACH_PRIV_ALL                                     98
#define FSB_OP_MACH_PRIV_HOST_PORT                               99
#define FSB_OP_MACH_PRIV_TASK_PORT                               100
#define FSB_OP_MACH_REGISTER                                     101
#define FSB_OP_MACH_TASK_ALL                                     102
#define FSB_OP_MACH_TASK_EXCEPTION_PORT_SET                      103
#define FSB_OP_MACH_TASK_INSPECT                                 104
#define FSB_OP_MACH_TASK_NAME                                    105
#define FSB_OP_MACH_TASK_READ                                    106
#define FSB_OP_MACH_TASK_SPECIAL_PORT_ALL                        107
#define FSB_OP_MACH_TASK_SPECIAL_PORT_GET                        108
#define FSB_OP_MACH_TASK_SPECIAL_PORT_SET                        109
#define FSB_OP_NECP_CLIENT_OPEN                                  110
#define FSB_OP_NETWORK_ALL                                       111
#define FSB_OP_NETWORK_INBOUND                                   112
#define FSB_OP_NETWORK_BIND                                      113
#define FSB_OP_NETWORK_OUTBOUND                                  114
#define FSB_OP_NVRAM_ALL                                         115
#define FSB_OP_NVRAM_DELETE                                      116
#define FSB_OP_NVRAM_GET                                         117
#define FSB_OP_NVRAM_SET                                         118
#define FSB_OP_OPENDIRECTORY_USER_MODIFY                         119
#define FSB_OP_PROCESS_ALL                                       120
#define FSB_OP_PROCESS_CODESIGNING                               121
#define FSB_OP_PROCESS_EXEC_ALL                                  122
#define FSB_OP_PROCESS_EXEC_INTERPRETER                          123
#define FSB_OP_PROCESS_FORK                                      124
#define FSB_OP_PROCESS_INFO_ALL                                  125
#define FSB_OP_PROCESS_INFO_CODESIGNATURE                        126
#define FSB_OP_PROCESS_INFO_DIRTYCONTROL                         127
#define FSB_OP_PROCESS_INFO_LEDGER                               128
#define FSB_OP_PROCESS_INFO_LISTPIDS                             129
#define FSB_OP_PROCESS_INFO_PIDINFO                              130
#define FSB_OP_PROCESS_INFO_PIDFDINFO                            131
#define FSB_OP_PROCESS_INFO_PIDFILEPORTINFO                      132
#define FSB_OP_PROCESS_INFO_RUSAGE                               133
#define FSB_OP_PROCESS_INFO_SANDBOX_CONTAINER                    134
#define FSB_OP_PROCESS_INFO_SETCONTROL                           135
#define FSB_OP_PROCESS_IOPOLICY_ALL                              136
#define FSB_OP_PROCESS_IOPOLICY_GET                              137
#define FSB_OP_PROCESS_IOPOLICY_SET                              138
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_ALL                    139
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_BLOB_GET               140
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_CDHASH_GET             141
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_ENTITLEMENTS_BLOB_GET  142
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_ENTITLEMENTS_DER_BLOB_GET 143
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_IDENTITY_GET           144
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_STATUS_ALL             145
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_STATUS_GET             146
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_STATUS_SET             147
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_TEAMID_GET             148
#define FSB_OP_PROCESS_LEGACY_CODESIGNING_TEXT_OFFSET_GET        149
#define FSB_OP_PSEUDO_TTY                                        150
#define FSB_OP_SANDBOX_CHECK                                     151
#define FSB_OP_SIGNAL                                            152
#define FSB_OP_SOCKET_IOCTL                                      153
#define FSB_OP_SOCKET_OPTION_ALL                                 154
#define FSB_OP_SOCKET_OPTION_GET                                 155
#define FSB_OP_SOCKET_OPTION_SET                                 156
#define FSB_OP_SYSCALL_ALL                                       157
#define FSB_OP_SYSCALL_UNIX                                      158
#define FSB_OP_SYSCALL_MACH                                      159
#define FSB_OP_SYSCALL_MIG                                       160
#define FSB_OP_SYSCTL_ALL                                        161
#define FSB_OP_SYSCTL_READ                                       162
#define FSB_OP_SYSCTL_WRITE                                      163
#define FSB_OP_SYSTEM_ALL                                        164
#define FSB_OP_SYSTEM_ACCT                                       165
#define FSB_OP_SYSTEM_AUDIT                                      166
#define FSB_OP_SYSTEM_AUTOMOUNT                                  167
#define FSB_OP_SYSTEM_DEBUG                                      168
#define FSB_OP_SYSTEM_FCNTL                                      169
#define FSB_OP_SYSTEM_FSCTL                                      170
#define FSB_OP_SYSTEM_INFO                                       171
#define FSB_OP_SYSTEM_KAS_INFO                                   172
#define FSB_OP_SYSTEM_KEXT_ALL                                   173
#define FSB_OP_SYSTEM_KEXT_LOAD                                  174
#define FSB_OP_SYSTEM_KEXT_UNLOAD                                175
#define FSB_OP_SYSTEM_KEXT_QUERY                                 176
#define FSB_OP_SYSTEM_MAC_ALL                                    177
#define FSB_OP_SYSTEM_MAC_LABEL                                  178
#define FSB_OP_SYSTEM_MAC_SYSCALL                                179
#define FSB_OP_SYSTEM_MEMORYSTATUS_CONTROL                       180
#define FSB_OP_SYSTEM_NECP_CLIENT_ACTION                         181
#define FSB_OP_SYSTEM_NFSSVC                                     182
#define FSB_OP_SYSTEM_PACKAGE_CHECK                              183
#define FSB_OP_SYSTEM_PRIVILEGE                                  184
#define FSB_OP_SYSTEM_REBOOT                                     185
#define FSB_OP_SYSTEM_SCHED                                      186
#define FSB_OP_SYSTEM_SET_TIME                                   187
#define FSB_OP_SYSTEM_SOCKET                                     188
#define FSB_OP_SYSTEM_SUSPEND_RESUME                             189
#define FSB_OP_SYSTEM_SWAP                                       190
#define FSB_OP_USER_PREFERENCE_ALL                               191
#define FSB_OP_USER_PREFERENCE_READ                              192
#define FSB_OP_MANAGED_PREFERENCE_READ                           193
#define FSB_OP_USER_PREFERENCE_WRITE                             194
#define FSB_OP_EXCEPTION_ENTITLEMENT                             195
#define FSB_OP_STORAGE_CLASS_MAP                                 196
#define FSB_OP_PROCESS_EXEC_UPDATE_LABEL                         197
#define FSB_OP_DEFAULT_MESSAGE_FILTER                            198
#define FSB_OP_IOKIT_ASYNC_EXTERNAL_METHOD                       199
#define FSB_OP_IOKIT_EXTERNAL_METHOD                             200
#define FSB_OP_IOKIT_EXTERNAL_TRAP                               201
#define FSB_OP_MACH_MESSAGE_SEND                                 202
#define FSB_OP_XPC_MESSAGE_SEND                                  203
#define FSB_OP_COUNT 204

#define FSB_OP_NAMES \
	"default", \
	"appleevent-send", \
	"authorization-right-obtain", \
	"boot-arg-set", \
	"consume-extension", \
	"device*", \
	"device-camera", \
	"device-microphone", \
	"darwin-notification-post", \
	"distributed-notification-post", \
	"dynamic-code-generation", \
	"file*", \
	"file-chroot", \
	"file-clone", \
	"file-graft", \
	"file-ioctl", \
	"file-issue-extension", \
	"file-link", \
	"file-lock", \
	"file-map-executable", \
	"file-mknod", \
	"file-mount", \
	"file-mount-update", \
	"file-read*", \
	"file-read-data", \
	"file-read-metadata", \
	"file-read-xattr", \
	"file-revoke", \
	"file-search", \
	"file-test-existence", \
	"file-ungraft", \
	"file-unmount", \
	"file-write*", \
	"file-write-acl", \
	"file-write-create", \
	"file-write-data", \
	"file-write-finderinfo", \
	"file-write-flags", \
	"file-write-mode", \
	"file-write-owner", \
	"file-write-setugid", \
	"file-write-times", \
	"file-write-unlink", \
	"file-write-xattr", \
	"fs-quota*", \
	"fs-quota-get", \
	"fs-quota-on", \
	"fs-quota-off", \
	"fs-quota-set*", \
	"fs-quota-set-limits", \
	"fs-quota-set-usage", \
	"fs-quota-stat", \
	"fs-quota-sync", \
	"fs-rename", \
	"fs-snapshot*", \
	"fs-snapshot-create", \
	"fs-snapshot-delete", \
	"fs-snapshot-mount", \
	"fs-snapshot-revert", \
	"generic-issue-extension", \
	"qtn-user", \
	"hid-control", \
	"iokit*", \
	"iokit-get-properties", \
	"iokit-issue-extension", \
	"iokit-open*", \
	"iokit-open-user-client", \
	"iokit-open-service", \
	"iokit-set-properties", \
	"ipc*", \
	"ipc-posix*", \
	"ipc-posix-sem*", \
	"ipc-posix-sem-create", \
	"ipc-posix-sem-open", \
	"ipc-posix-sem-post", \
	"ipc-posix-sem-unlink", \
	"ipc-posix-sem-wait", \
	"ipc-posix-shm*", \
	"ipc-posix-shm-read-data", \
	"ipc-posix-shm-write*", \
	"ipc-posix-shm-write-create", \
	"ipc-posix-shm-write-data", \
	"ipc-posix-shm-write-unlink", \
	"ipc-sysv*", \
	"ipc-sysv-msg", \
	"ipc-sysv-sem", \
	"ipc-sysv-shm", \
	"job-creation", \
	"lsopen", \
	"mach*", \
	"mach-bootstrap", \
	"mach-cross-domain-lookup", \
	"mach-derive-port", \
	"mach-host*", \
	"mach-host-exception-port-set", \
	"mach-host-special-port-set", \
	"mach-issue-extension", \
	"mach-lookup", \
	"mach-priv*", \
	"mach-priv-host-port", \
	"mach-priv-task-port", \
	"mach-register", \
	"mach-task*", \
	"mach-task-exception-port-set", \
	"mach-task-inspect", \
	"mach-task-name", \
	"mach-task-read", \
	"mach-task-special-port*", \
	"mach-task-special-port-get", \
	"mach-task-special-port-set", \
	"necp-client-open", \
	"network*", \
	"network-inbound", \
	"network-bind", \
	"network-outbound", \
	"nvram*", \
	"nvram-delete", \
	"nvram-get", \
	"nvram-set", \
	"opendirectory-user-modify", \
	"process*", \
	"process-codesigning", \
	"process-exec*", \
	"process-exec-interpreter", \
	"process-fork", \
	"process-info*", \
	"process-info-codesignature", \
	"process-info-dirtycontrol", \
	"process-info-ledger", \
	"process-info-listpids", \
	"process-info-pidinfo", \
	"process-info-pidfdinfo", \
	"process-info-pidfileportinfo", \
	"process-info-rusage", \
	"process-info-sandbox-container", \
	"process-info-setcontrol", \
	"process-iopolicy*", \
	"process-iopolicy-get", \
	"process-iopolicy-set", \
	"process-legacy-codesigning*", \
	"process-legacy-codesigning-blob-get", \
	"process-legacy-codesigning-cdhash-get", \
	"process-legacy-codesigning-entitlements-blob-get", \
	"process-legacy-codesigning-entitlements-der-blob-get", \
	"process-legacy-codesigning-identity-get", \
	"process-legacy-codesigning-status*", \
	"process-legacy-codesigning-status-get", \
	"process-legacy-codesigning-status-set", \
	"process-legacy-codesigning-teamid-get", \
	"process-legacy-codesigning-text-offset-get", \
	"pseudo-tty", \
	"sandbox-check", \
	"signal", \
	"socket-ioctl", \
	"socket-option*", \
	"socket-option-get", \
	"socket-option-set", \
	"syscall*", \
	"syscall-unix", \
	"syscall-mach", \
	"syscall-mig", \
	"sysctl*", \
	"sysctl-read", \
	"sysctl-write", \
	"system*", \
	"system-acct", \
	"system-audit", \
	"system-automount", \
	"system-debug", \
	"system-fcntl", \
	"system-fsctl", \
	"system-info", \
	"system-kas-info", \
	"system-kext*", \
	"system-kext-load", \
	"system-kext-unload", \
	"system-kext-query", \
	"system-mac*", \
	"system-mac-label", \
	"system-mac-syscall", \
	"system-memorystatus-control", \
	"system-necp-client-action", \
	"system-nfssvc", \
	"system-package-check", \
	"system-privilege", \
	"system-reboot", \
	"system-sched", \
	"system-set-time", \
	"system-socket", \
	"system-suspend-resume", \
	"system-swap", \
	"user-preference*", \
	"user-preference-read", \
	"managed-preference-read", \
	"user-preference-write", \
	"exception-entitlement", \
	"storage-class-map", \
	"process-exec-update-label", \
	"default-message-filter", \
	"iokit-async-external-method", \
	"iokit-external-method", \
	"iokit-external-trap", \
	"mach-message-send", \
	"xpc-message-send", \

#define FSB_OP_PARENTS \
	0xffffffffu, /* default -> - */ \
	0, /* appleevent-send -> default */ \
	0, /* authorization-right-obtain -> default */ \
	0, /* boot-arg-set -> default */ \
	0, /* consume-extension -> default */ \
	0, /* device* -> default */ \
	5, /* device-camera -> device* */ \
	5, /* device-microphone -> device* */ \
	0, /* darwin-notification-post -> default */ \
	0, /* distributed-notification-post -> default */ \
	0, /* dynamic-code-generation -> default */ \
	0, /* file* -> default */ \
	11, /* file-chroot -> file* */ \
	11, /* file-clone -> file* */ \
	11, /* file-graft -> file* */ \
	11, /* file-ioctl -> file* */ \
	11, /* file-issue-extension -> file* */ \
	11, /* file-link -> file* */ \
	11, /* file-lock -> file* */ \
	11, /* file-map-executable -> file* */ \
	11, /* file-mknod -> file* */ \
	11, /* file-mount -> file* */ \
	11, /* file-mount-update -> file* */ \
	11, /* file-read* -> file* */ \
	23, /* file-read-data -> file-read* */ \
	23, /* file-read-metadata -> file-read* */ \
	23, /* file-read-xattr -> file-read* */ \
	11, /* file-revoke -> file* */ \
	11, /* file-search -> file* */ \
	11, /* file-test-existence -> file* */ \
	11, /* file-ungraft -> file* */ \
	11, /* file-unmount -> file* */ \
	11, /* file-write* -> file* */ \
	32, /* file-write-acl -> file-write* */ \
	32, /* file-write-create -> file-write* */ \
	32, /* file-write-data -> file-write* */ \
	32, /* file-write-finderinfo -> file-write* */ \
	32, /* file-write-flags -> file-write* */ \
	32, /* file-write-mode -> file-write* */ \
	32, /* file-write-owner -> file-write* */ \
	32, /* file-write-setugid -> file-write* */ \
	32, /* file-write-times -> file-write* */ \
	32, /* file-write-unlink -> file-write* */ \
	32, /* file-write-xattr -> file-write* */ \
	0, /* fs-quota* -> default */ \
	44, /* fs-quota-get -> fs-quota* */ \
	44, /* fs-quota-on -> fs-quota* */ \
	44, /* fs-quota-off -> fs-quota* */ \
	44, /* fs-quota-set* -> fs-quota* */ \
	48, /* fs-quota-set-limits -> fs-quota-set* */ \
	48, /* fs-quota-set-usage -> fs-quota-set* */ \
	44, /* fs-quota-stat -> fs-quota* */ \
	44, /* fs-quota-sync -> fs-quota* */ \
	0, /* fs-rename -> default */ \
	0, /* fs-snapshot* -> default */ \
	54, /* fs-snapshot-create -> fs-snapshot* */ \
	54, /* fs-snapshot-delete -> fs-snapshot* */ \
	54, /* fs-snapshot-mount -> fs-snapshot* */ \
	54, /* fs-snapshot-revert -> fs-snapshot* */ \
	0, /* generic-issue-extension -> default */ \
	0, /* qtn-user -> default */ \
	0, /* hid-control -> default */ \
	0, /* iokit* -> default */ \
	62, /* iokit-get-properties -> iokit* */ \
	62, /* iokit-issue-extension -> iokit* */ \
	62, /* iokit-open* -> iokit* */ \
	65, /* iokit-open-user-client -> iokit-open* */ \
	65, /* iokit-open-service -> iokit-open* */ \
	62, /* iokit-set-properties -> iokit* */ \
	0, /* ipc* -> default */ \
	69, /* ipc-posix* -> ipc* */ \
	70, /* ipc-posix-sem* -> ipc-posix* */ \
	71, /* ipc-posix-sem-create -> ipc-posix-sem* */ \
	71, /* ipc-posix-sem-open -> ipc-posix-sem* */ \
	71, /* ipc-posix-sem-post -> ipc-posix-sem* */ \
	71, /* ipc-posix-sem-unlink -> ipc-posix-sem* */ \
	71, /* ipc-posix-sem-wait -> ipc-posix-sem* */ \
	70, /* ipc-posix-shm* -> ipc-posix* */ \
	77, /* ipc-posix-shm-read-data -> ipc-posix-shm* */ \
	77, /* ipc-posix-shm-write* -> ipc-posix-shm* */ \
	79, /* ipc-posix-shm-write-create -> ipc-posix-shm-write* */ \
	79, /* ipc-posix-shm-write-data -> ipc-posix-shm-write* */ \
	79, /* ipc-posix-shm-write-unlink -> ipc-posix-shm-write* */ \
	69, /* ipc-sysv* -> ipc* */ \
	83, /* ipc-sysv-msg -> ipc-sysv* */ \
	83, /* ipc-sysv-sem -> ipc-sysv* */ \
	83, /* ipc-sysv-shm -> ipc-sysv* */ \
	0, /* job-creation -> default */ \
	0, /* lsopen -> default */ \
	0, /* mach* -> default */ \
	89, /* mach-bootstrap -> mach* */ \
	89, /* mach-cross-domain-lookup -> mach* */ \
	89, /* mach-derive-port -> mach* */ \
	89, /* mach-host* -> mach* */ \
	93, /* mach-host-exception-port-set -> mach-host* */ \
	93, /* mach-host-special-port-set -> mach-host* */ \
	89, /* mach-issue-extension -> mach* */ \
	89, /* mach-lookup -> mach* */ \
	89, /* mach-priv* -> mach* */ \
	98, /* mach-priv-host-port -> mach-priv* */ \
	98, /* mach-priv-task-port -> mach-priv* */ \
	89, /* mach-register -> mach* */ \
	89, /* mach-task* -> mach* */ \
	102, /* mach-task-exception-port-set -> mach-task* */ \
	102, /* mach-task-inspect -> mach-task* */ \
	102, /* mach-task-name -> mach-task* */ \
	102, /* mach-task-read -> mach-task* */ \
	102, /* mach-task-special-port* -> mach-task* */ \
	107, /* mach-task-special-port-get -> mach-task-special-port* */ \
	107, /* mach-task-special-port-set -> mach-task-special-port* */ \
	0, /* necp-client-open -> default */ \
	0, /* network* -> default */ \
	111, /* network-inbound -> network* */ \
	111, /* network-bind -> network* */ \
	111, /* network-outbound -> network* */ \
	0, /* nvram* -> default */ \
	115, /* nvram-delete -> nvram* */ \
	115, /* nvram-get -> nvram* */ \
	115, /* nvram-set -> nvram* */ \
	0, /* opendirectory-user-modify -> default */ \
	0, /* process* -> default */ \
	120, /* process-codesigning -> process* */ \
	120, /* process-exec* -> process* */ \
	122, /* process-exec-interpreter -> process-exec* */ \
	120, /* process-fork -> process* */ \
	120, /* process-info* -> process* */ \
	125, /* process-info-codesignature -> process-info* */ \
	125, /* process-info-dirtycontrol -> process-info* */ \
	125, /* process-info-ledger -> process-info* */ \
	125, /* process-info-listpids -> process-info* */ \
	125, /* process-info-pidinfo -> process-info* */ \
	125, /* process-info-pidfdinfo -> process-info* */ \
	125, /* process-info-pidfileportinfo -> process-info* */ \
	125, /* process-info-rusage -> process-info* */ \
	125, /* process-info-sandbox-container -> process-info* */ \
	125, /* process-info-setcontrol -> process-info* */ \
	120, /* process-iopolicy* -> process* */ \
	136, /* process-iopolicy-get -> process-iopolicy* */ \
	136, /* process-iopolicy-set -> process-iopolicy* */ \
	120, /* process-legacy-codesigning* -> process* */ \
	139, /* process-legacy-codesigning-blob-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-cdhash-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-entitlements-blob-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-entitlements-der-blob-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-identity-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-status* -> process-legacy-codesigning* */ \
	145, /* process-legacy-codesigning-status-get -> process-legacy-codesigning-status* */ \
	145, /* process-legacy-codesigning-status-set -> process-legacy-codesigning-status* */ \
	139, /* process-legacy-codesigning-teamid-get -> process-legacy-codesigning* */ \
	139, /* process-legacy-codesigning-text-offset-get -> process-legacy-codesigning* */ \
	0, /* pseudo-tty -> default */ \
	0, /* sandbox-check -> default */ \
	0, /* signal -> default */ \
	0, /* socket-ioctl -> default */ \
	0, /* socket-option* -> default */ \
	154, /* socket-option-get -> socket-option* */ \
	154, /* socket-option-set -> socket-option* */ \
	0, /* syscall* -> default */ \
	157, /* syscall-unix -> syscall* */ \
	157, /* syscall-mach -> syscall* */ \
	157, /* syscall-mig -> syscall* */ \
	0, /* sysctl* -> default */ \
	161, /* sysctl-read -> sysctl* */ \
	161, /* sysctl-write -> sysctl* */ \
	0, /* system* -> default */ \
	164, /* system-acct -> system* */ \
	164, /* system-audit -> system* */ \
	164, /* system-automount -> system* */ \
	164, /* system-debug -> system* */ \
	164, /* system-fcntl -> system* */ \
	164, /* system-fsctl -> system* */ \
	164, /* system-info -> system* */ \
	164, /* system-kas-info -> system* */ \
	164, /* system-kext* -> system* */ \
	173, /* system-kext-load -> system-kext* */ \
	173, /* system-kext-unload -> system-kext* */ \
	173, /* system-kext-query -> system-kext* */ \
	164, /* system-mac* -> system* */ \
	177, /* system-mac-label -> system-mac* */ \
	177, /* system-mac-syscall -> system-mac* */ \
	164, /* system-memorystatus-control -> system* */ \
	164, /* system-necp-client-action -> system* */ \
	164, /* system-nfssvc -> system* */ \
	164, /* system-package-check -> system* */ \
	164, /* system-privilege -> system* */ \
	164, /* system-reboot -> system* */ \
	164, /* system-sched -> system* */ \
	164, /* system-set-time -> system* */ \
	164, /* system-socket -> system* */ \
	164, /* system-suspend-resume -> system* */ \
	164, /* system-swap -> system* */ \
	0, /* user-preference* -> default */ \
	191, /* user-preference-read -> user-preference* */ \
	0, /* managed-preference-read -> default */ \
	191, /* user-preference-write -> user-preference* */ \
	0, /* exception-entitlement -> default */ \
	0, /* storage-class-map -> default */ \
	122, /* process-exec-update-label -> process-exec* */ \
	0, /* default-message-filter -> default */ \
	62, /* iokit-async-external-method -> iokit* */ \
	62, /* iokit-external-method -> iokit* */ \
	62, /* iokit-external-trap -> iokit* */ \
	89, /* mach-message-send -> mach* */ \
	0, /* xpc-message-send -> default */ \

#endif /* FSB_OPS_H */

# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libsystem_secinit
VERSION := 168.100.7
SRCS    := secinit.c
# entitlements (libxpc), sandbox_init (libsystem_sandbox), getpwuid (libsystem_info)
LIBS    := -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_malloc -lsystem_info \
           -lsystem_sandbox -lxpc -lsystem_blocks
EXTRA_CFLAGS := -fblocks
include ../lib.mk

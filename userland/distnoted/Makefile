# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-distnoted: distributed notifications between a user's processes (a per-user agent,
# with a root instance; their jobs go in through the overlays).
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks -Wno-unused-parameter

all: $(ROOT)/usr/libexec/finch-distnoted

$(ROOT)/usr/libexec/finch-distnoted: distnoted.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DOS_OBJECT_USE_OBJC=0 -o $@ distnoted.c
	codesign -f -s - -i org.finch.distnoted $@

.PHONY: all

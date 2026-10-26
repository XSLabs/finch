# SPDX-License-Identifier: MIT OR Apache-2.0
# security: macOS's trust-settings and certificate commands, over Finch's Security.
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
OUT := $(ROOT)/usr/bin/security
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)

$(OUT): security.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ security.c -Wl,-F$(ROOT)/System/Library/Frameworks -framework Security \
	    -framework CoreFoundation
	codesign -f -s - -i org.finch.security $@

.PHONY: all

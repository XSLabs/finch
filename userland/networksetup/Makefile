# SPDX-License-Identifier: MIT OR Apache-2.0
# networksetup, written for Finch (networksetup.c; macOS's is closed).
FINCH_ROOT := $(abspath ../..)
OUT := $(FINCH_ROOT)/build/root/usr/sbin/networksetup
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)

$(OUT): networksetup.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $< -framework SystemConfiguration -framework CoreFoundation
	codesign -f -s - -i com.apple.networksetup $@

.PHONY: all

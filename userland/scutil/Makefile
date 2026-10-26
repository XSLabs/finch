# SPDX-License-Identifier: MIT OR Apache-2.0
# scutil, written for Finch (scutil.c), over Finch's SystemConfiguration.
FINCH_ROOT := $(abspath ../..)
OUT := $(FINCH_ROOT)/build/root/usr/sbin/scutil
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)

$(OUT): scutil.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $< -framework SystemConfiguration -framework CoreFoundation
	codesign -f -s - -i com.apple.scutil $@

.PHONY: all

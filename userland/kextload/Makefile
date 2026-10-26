# SPDX-License-Identifier: MIT OR Apache-2.0
# kextload: start a kext from the boot kernel collection (Finch has no kernelmanagerd).
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
OUT := $(ROOT)/sbin/kextload
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)

$(OUT): kextload.c kextload.entitlements
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ kextload.c -Wl,-F$(ROOT)/System/Library/Frameworks -framework CoreFoundation \
	    -framework IOKit
	codesign -f -s - -i com.apple.kextload --entitlements kextload.entitlements $@

.PHONY: all

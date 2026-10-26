# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-setup: a new system's first account, at the console (finch-init runs it
# in place of login).
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
OUT := $(ROOT)/usr/libexec/finch-setup
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -I../account-tools

all: $(OUT)

$(OUT): finch-setup.c ../account-tools/account_tools.h $(ROOT)/usr/lib/system/libfinchaccount.dylib
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ finch-setup.c -L$(ROOT)/usr/lib/system -lfinchaccount
	codesign -f -s - -i org.finch.setup $@

.PHONY: all

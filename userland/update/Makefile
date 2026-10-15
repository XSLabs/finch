# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-update (finch-update.c, Finch's own): signed updates, checked with Finch's Security.
# The release's public key goes in with it when one has been made (tools/release/sign-update.sh
# keeps the key pair in build/release/keys, never in the repository).
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
KEYS  := $(FINCH)/build/release/keys
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror

all: $(ROOT)/usr/sbin/finch-update $(if $(wildcard $(KEYS)/update-key.der),$(ROOT)/usr/share/finch/update-key.der)

$(ROOT)/usr/sbin/finch-update: finch-update.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ finch-update.c -framework Security -framework CoreFoundation
	codesign -f -s - -i org.finch.update $@

$(ROOT)/usr/share/finch/update-key.der: $(KEYS)/update-key.der
	@mkdir -p $(dir $@)
	cp $< $@

.PHONY: all

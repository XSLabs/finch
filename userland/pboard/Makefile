# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-pboardd, the pasteboard server (pboardd.c); its LaunchDaemon goes in through tools/vm/overlay.txt.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
SDK   := $(FINCH)/build/sdk
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks -Wno-unused-parameter \
          -idirafter $(SDK)/include

all: $(ROOT)/usr/libexec/finch-pboardd

$(ROOT)/usr/libexec/finch-pboardd: pboardd.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ pboardd.c -framework CoreFoundation
	codesign -f -s - -i com.apple.pboard $@

.PHONY: all

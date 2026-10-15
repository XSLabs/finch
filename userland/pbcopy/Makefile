# SPDX-License-Identifier: MIT OR Apache-2.0
# pbcopy and pbpaste (pbcopy.m, Finch's own): the pasteboard from the command line.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fobjc-arc

all: $(ROOT)/usr/bin/pbcopy $(ROOT)/usr/bin/pbpaste

$(ROOT)/usr/bin/pbcopy: pbcopy.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ pbcopy.m -framework AppKit
	codesign -f -s - -i org.finch.pbcopy $@

$(ROOT)/usr/bin/pbpaste: pbcopy.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ pbcopy.m -framework AppKit
	codesign -f -s - -i org.finch.pbpaste $@

.PHONY: all

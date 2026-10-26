# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-openandsavepanel: sandboxed apps' open and save panels (a per-user agent; its
# job, org.finch.openandsavepanel.plist, goes in through the overlays).
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks -Wno-unused-parameter

all: $(ROOT)/usr/libexec/finch-openandsavepanel

$(ROOT)/usr/libexec/finch-openandsavepanel: openandsavepanel.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -DOS_OBJECT_USE_OBJC=0 -o $@ openandsavepanel.m -framework AppKit -lbsm
	codesign -f -s - -i org.finch.openandsavepanel $@

.PHONY: all

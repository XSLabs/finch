# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-securityagent: the authorization password dialog (a per-user agent; its
# job, org.finch.securityagent.plist, goes in through the overlays).
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks -Wno-unused-parameter

all: $(ROOT)/usr/libexec/finch-securityagent

$(ROOT)/usr/libexec/finch-securityagent: securityagent.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -DOS_OBJECT_USE_OBJC=0 -o $@ securityagent.m -framework AppKit
	codesign -f -s - -i org.finch.securityagent $@

.PHONY: all

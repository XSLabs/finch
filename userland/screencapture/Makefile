# SPDX-License-Identifier: MIT OR Apache-2.0
# screencapture (screencapture.m, Finch's own) and finch-screencaptured, the service that
# runs it for apps (screencaptured.c); its LaunchDaemon goes in through tools/vm/overlay.txt.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
SDK   := $(FINCH)/build/sdk
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks -Wno-unused-parameter

all: $(ROOT)/usr/sbin/screencapture $(ROOT)/usr/libexec/finch-screencaptured

$(ROOT)/usr/sbin/screencapture: screencapture.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ screencapture.m -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers
	codesign -f -s - -i org.finch.screencapture $@

$(ROOT)/usr/libexec/finch-screencaptured: screencaptured.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -idirafter $(SDK)/include -o $@ screencaptured.c -lbsm
	codesign -f -s - -i org.finch.screencaptured $@

.PHONY: all

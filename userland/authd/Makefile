# SPDX-License-Identifier: MIT OR Apache-2.0
# authd: Finch's authorization service (com.apple.authd), run by finch-init
# (its job: userland/LaunchDaemons/com.apple.authd.plist, through the overlays).
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
OUT := $(ROOT)/usr/libexec/authd
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -fblocks \
          -Wno-deprecated-declarations -I$(FINCH_ROOT)/build/src/OpenPAM/openpam/include
LIBS := -Wl,-F$(ROOT)/System/Library/Frameworks -framework CoreFoundation \
        -L$(FINCH_ROOT)/build/userland/libxpc -lxpc -L$(ROOT)/usr/lib -lpam -lbsm

all: $(OUT)

$(OUT): authd.c authd_protocol.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ authd.c $(LIBS)
	# (AMFI refuses com.apple.authd without Apple's version-restriction entitlement)
	codesign -f -s - -i org.finch.authd $@

.PHONY: all

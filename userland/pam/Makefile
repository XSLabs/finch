# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's PAM pieces, on Apple's OpenPAM and pam_modules (tools/build-system.sh):
#  - pam_unix.so.2, built from OpenPAM's own pam_unix (BSD; build/src/OpenPAM).
#    Apple doesn't ship it; it stands in for pam_opendirectory, which needs the
#    closed OpenDirectory.
#  - /etc/pam.d stacks that use only the modules Finch has. They replace the
#    ones pam_modules installs.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Werror -Wno-unused-parameter
SRC   := pam_unix.c
ACCOUNT_LIB := $(ROOT)/usr/lib/system/libfinchaccount.dylib
MOD   := $(ROOT)/usr/lib/pam/pam_unix.so.2
CONFS := $(notdir $(wildcard pam.d/*))

all: $(MOD) $(addprefix $(ROOT)/private/etc/pam.d/,$(CONFS))

# pam_unix.c is Finch's checked-in version of OpenPAM's BSD-licensed module.
$(MOD): $(SRC) $(ACCOUNT_LIB) $(FINCH)/userland/account-tools/account_tools.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I../account-tools \
	    -I$(FINCH)/build/src/OpenPAM/openpam/include -dynamiclib \
	    -install_name /usr/lib/pam/pam_unix.so.2 -o $@ $(SRC) \
	    -L$(ROOT)/usr/lib/system -lfinchaccount -L$(ROOT)/usr/lib -lpam
	codesign -f -s - -i org.openpam.pam_unix $@

# Always reinstalled: pam_modules installs Apple's stacks over these (they name
# closed modules), and theirs can be newer than Finch's sources.
$(ROOT)/private/etc/pam.d/%: pam.d/% FORCE
	@mkdir -p $(dir $@)
	install -m 644 $< $@

FORCE:
.PHONY: all FORCE

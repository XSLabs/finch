# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's PAM pieces, on Apple's OpenPAM and pam_modules (tools/build-system.sh):
#  - pam_unix.so.2, built from OpenPAM's own pam_unix (BSD; build/src/OpenPAM).
#    Apple doesn't ship it; it stands in for pam_opendirectory, which needs the
#    closed OpenDirectory.
#  - /etc/pam.d stacks that use only the modules Finch has. They replace the
#    ones pam_modules installs.
#  - pam_keychain.so.2, built after Security so console logins can unlock or
#    create a user's encrypted login keychain without affecting authentication.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Werror -Wno-unused-parameter
SRC   := pam_unix.c
ACCOUNT_LIB := $(ROOT)/usr/lib/system/libfinchaccount.dylib
MOD   := $(ROOT)/usr/lib/pam/pam_unix.so.2
KEYCHAIN_MOD := $(ROOT)/usr/lib/pam/pam_keychain.so.2
KEYCHAIN_OBJ := $(FINCH)/build/obj/pam/pam_keychain.o
CONFS := $(notdir $(wildcard pam.d/*))

all: $(MOD) policy

# shell_cmds and system_cmds install Apple's su and passwd stacks too, so
# tools/build-system.sh runs this again after the commands.
policy: $(addprefix $(ROOT)/private/etc/pam.d/,$(CONFS))

# Security is built after PAM. The login hook is built in a later stage.
keychain: $(KEYCHAIN_MOD)

# pam_unix.c is Finch's checked-in version of OpenPAM's BSD-licensed module.
$(MOD): $(SRC) pam_keychain_data.h $(ACCOUNT_LIB) $(FINCH)/userland/account-tools/account_tools.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I../account-tools \
	    -I$(FINCH)/build/src/OpenPAM/openpam/include -dynamiclib \
	    -install_name /usr/lib/pam/pam_unix.so.2 -o $@ $(SRC) \
	    -L$(ROOT)/usr/lib/system -lfinchaccount -L$(ROOT)/usr/lib -lpam
	codesign -f -s - -i org.openpam.pam_unix $@


$(KEYCHAIN_OBJ): pam_keychain.c pam_keychain_data.h \
		$(FINCH)/userland/account-tools/account_tools.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -I../account-tools \
	    -I$(FINCH)/build/src/OpenPAM/openpam/include -c $< -o $@

$(KEYCHAIN_MOD): $(KEYCHAIN_OBJ) \
		$(ROOT)/System/Library/Frameworks/Security.framework/Security \
		$(ROOT)/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
		$(ACCOUNT_LIB) $(ROOT)/usr/lib/libpam.dylib
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -F$(ROOT)/System/Library/Frameworks -dynamiclib \
	    -install_name /usr/lib/pam/pam_keychain.so.2 -o $@ $(KEYCHAIN_OBJ) \
	    -L$(ROOT)/usr/lib/system -lfinchaccount -L$(ROOT)/usr/lib -lpam \
	    -framework CoreFoundation -framework Security
	codesign -f -s - -i org.openpam.pam_keychain $@

# Always reinstalled: pam_modules installs Apple's stacks over these (they name
# closed modules), and theirs can be newer than Finch's sources.
$(ROOT)/private/etc/pam.d/%: pam.d/% FORCE
	@mkdir -p $(dir $@)
	install -m 644 $< $@

FORCE:
.PHONY: all keychain policy FORCE

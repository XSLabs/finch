# SPDX-License-Identifier: MIT OR Apache-2.0
# Shared local-account code and the small account file tool used by Finch.
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
ACCOUNT_SOURCES := account_store.c password_hash.c
ACCOUNT_HEADERS := account_tools.h
LIB_DIR := $(ROOT)/usr/lib/system
LIB := $(LIB_DIR)/libfinchaccount.dylib
COMMONCRYPTO_ROOT := $(LIB_DIR)/libcommonCrypto.dylib
ACCOUNTCTL := $(ROOT)/usr/sbin/accountctl
# Finch's OpenDirectory runs it for account changes by anyone but root (setuid root as installed).
ACCOUNT_UPDATE := $(ROOT)/usr/libexec/finch-account-update

# The tests use a private build tree and the already-built Finch CommonCrypto.
TEST_ROOT ?= /private/tmp/finch-account-tools-test
TEST_LIB_DIR := $(TEST_ROOT)/usr/lib/system
TEST_LIB := $(TEST_LIB_DIR)/libfinchaccount.dylib
TEST_BIN := $(TEST_ROOT)/bin/account_tools_test
TEST_CFLAGS := -O2 -Wall -Wextra -Werror -DAT_ACCOUNT_TOOLS_TESTING
COMMONCRYPTO_LIB ?= $(FINCH_ROOT)/build/userland/CommonCrypto/libcommonCrypto.dylib

all: $(LIB) $(ACCOUNTCTL) $(ACCOUNT_UPDATE)

$(LIB): $(ACCOUNT_SOURCES) $(ACCOUNT_HEADERS) $(COMMONCRYPTO_ROOT)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -dynamiclib -install_name /usr/lib/system/libfinchaccount.dylib \
	    -current_version 1.0.0 -compatibility_version 1.0.0 -o $@ $(ACCOUNT_SOURCES) \
	    -L$(ROOT)/usr/lib/system -lcommonCrypto
	codesign -f -s - $@ 2>/dev/null

$(ACCOUNTCTL): accountctl.c $(ACCOUNT_HEADERS) $(LIB)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I. -o $@ accountctl.c -L$(LIB_DIR) -lfinchaccount
	codesign -f -s - $@ 2>/dev/null

$(ACCOUNT_UPDATE): finch-account-update.c $(ACCOUNT_HEADERS) $(LIB)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I. -o $@ finch-account-update.c -L$(LIB_DIR) -lfinchaccount
	codesign -f -s - -i org.finch.account-update $@ 2>/dev/null

$(TEST_LIB): $(ACCOUNT_SOURCES) $(ACCOUNT_HEADERS) $(COMMONCRYPTO_LIB)
	@mkdir -p $(TEST_LIB_DIR)
	$(CC) $(TEST_CFLAGS) -dynamiclib \
	    -install_name /usr/lib/system/libfinchaccount.dylib \
	    -current_version 1.0.0 -compatibility_version 1.0.0 -o $@ $(ACCOUNT_SOURCES) \
	    -L$(dir $(COMMONCRYPTO_LIB)) -lcommonCrypto

$(TEST_BIN): tests/account_tools_test.c $(ACCOUNT_HEADERS) $(TEST_LIB)
	@mkdir -p $(dir $@)
	$(CC) $(TEST_CFLAGS) -I. -o $@ tests/account_tools_test.c \
	    -L$(TEST_LIB_DIR) -lfinchaccount

test: $(TEST_BIN)
	FINCH_RELEASE_ETC="$(FINCH_ROOT)/userland/release/etc" \
	    DYLD_LIBRARY_PATH="$(abspath $(TEST_LIB_DIR)):$(abspath $(dir $(COMMONCRYPTO_LIB)))" \
	    $(TEST_BIN)

clean:
	rm -f $(LIB) $(ACCOUNTCTL) $(ACCOUNT_UPDATE)

.PHONY: all test clean

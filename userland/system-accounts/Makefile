CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror
BUILD_DIR ?= /private/tmp/finch-system-accounts

.PHONY: all test clean

all: $(BUILD_DIR)/system-account-merge

$(BUILD_DIR):
	mkdir -p "$@"

$(BUILD_DIR)/system-account-merge: system_accounts.c system_accounts.h system_account_merge_main.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -D_DARWIN_C_SOURCE system_accounts.c system_account_merge_main.c -o "$@"

$(BUILD_DIR)/system_accounts_test: system_accounts.c system_accounts.h tests/system_accounts_test.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -D_DARWIN_C_SOURCE -DSYSTEM_ACCOUNTS_TESTING system_accounts.c tests/system_accounts_test.c -o "$@"

test: $(BUILD_DIR)/system_accounts_test
	"$(BUILD_DIR)/system_accounts_test"

clean:
	rm -rf "$(BUILD_DIR)"

# SPDX-License-Identifier: MIT OR Apache-2.0
# Early boot helper for Finch's pre-initialized APFS data volume.
FINCH_ROOT := $(abspath ../..)
ROOT ?= $(FINCH_ROOT)/build/root
CC := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
FRAMEWORKS := -framework IOKit -framework CoreFoundation
PROGRAM := $(ROOT)/usr/sbin/finch-data-volume

TEST_ROOT ?= /private/tmp/finch-data-volume-test
TEST_PROGRAM := $(TEST_ROOT)/data-volume-policy-test
PROCESS_TEST := $(TEST_ROOT)/data-volume-process-test
PROCESS_TEST_CHILD := $(TEST_ROOT)/data-volume-process-child
TEST_CFLAGS := -O2 -Wall -Wextra -Werror

all: $(PROGRAM)

$(PROGRAM): data-volume.c data-volume-policy.c data-volume-policy.h data-volume-process.c data-volume-process.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I. -o $@ data-volume.c data-volume-policy.c data-volume-process.c $(FRAMEWORKS)
	codesign -f -s - -i org.finch.data-volume $@ 2>/dev/null

$(TEST_PROGRAM): policy-test.c data-volume-policy.c data-volume-policy.h
	@mkdir -p $(TEST_ROOT)
	$(CC) $(TEST_CFLAGS) -I. -o $@ policy-test.c data-volume-policy.c

$(PROCESS_TEST): process-test.c data-volume-process.c data-volume-process.h
	@mkdir -p $(TEST_ROOT)
	$(CC) $(TEST_CFLAGS) -I. -o $@ process-test.c data-volume-process.c

$(PROCESS_TEST_CHILD): process-test-child.c
	@mkdir -p $(TEST_ROOT)
	$(CC) $(TEST_CFLAGS) -o $@ process-test-child.c

test: $(TEST_PROGRAM) $(PROCESS_TEST) $(PROCESS_TEST_CHILD)
	$(TEST_PROGRAM)
	$(PROCESS_TEST) $(PROCESS_TEST_CHILD)

clean:
	rm -f $(PROGRAM) $(TEST_PROGRAM) $(PROCESS_TEST) $(PROCESS_TEST_CHILD)

.PHONY: all clean test

# SPDX-License-Identifier: MIT OR Apache-2.0
# Host tests of Finch's SBPL compiler (sbpl.c, sbpl_regex.c) and the profile
# evaluator it shares with the kernel (kernel/sandbox/fsb_eval.c). The library
# itself is built by build.sh (tools/build-system.sh's libsandbox step).
#
#   make test            regexes against POSIX, compile every host profile
#   make compare         compile acceptance and decisions against macOS's sandbox
FINCH_ROOT := $(abspath ../..)
OBJ := $(FINCH_ROOT)/build/obj/libsandbox
CC := xcrun -sdk macosx clang
CFLAGS := -O1 -g -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
          -I. -I$(FINCH_ROOT)/kernel/sandbox -I$(FINCH_ROOT)/kernel/include
COMPILER := sbpl.c sbpl_regex.c $(FINCH_ROOT)/kernel/sandbox/fsb_eval.c
HEADERS := sbpl.h sbpl_consts.h $(FINCH_ROOT)/kernel/sandbox/fsb_format.h $(FINCH_ROOT)/kernel/sandbox/fsb_ops.h

$(OBJ)/%: tests/%.c $(COMPILER) $(HEADERS)
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -o $@ $< $(COMPILER)

$(OBJ)/regex-test: tests/regex-test.c sbpl_regex.c $(HEADERS)
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -o $@ tests/regex-test.c sbpl_regex.c

sbplc: $(OBJ)/sbplc

test: $(OBJ)/regex-test $(OBJ)/sbplc
	$(OBJ)/regex-test
	tests/compare.py --compile-only

compare: $(OBJ)/sbplc $(OBJ)/decision-diff
	tests/compare.py

.PHONY: sbplc test compare

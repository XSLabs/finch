# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's sandbox profiles, installed where libsandbox looks for named profiles
# and imports (/System/Library/Sandbox/Profiles). Each is checked by compiling
# it with Finch's compiler (userland/libsandbox) first.
FINCH_ROOT := $(abspath ../..)
DEST := $(FINCH_ROOT)/build/root/System/Library/Sandbox/Profiles
PROFILES := $(wildcard *.sb)
SBPLC := $(FINCH_ROOT)/build/obj/libsandbox/sbplc

all: $(addprefix $(DEST)/,$(PROFILES))

$(DEST)/%.sb: %.sb $(SBPLC)
	@mkdir -p $(DEST)
	$(SBPLC) -I . $< > /dev/null
	install -m 644 $< $@

$(SBPLC):
	$(MAKE) -C $(FINCH_ROOT)/userland/libsandbox sbplc

.PHONY: all

# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's alert sound (mksound.py, made here), where macOS keeps its system sounds.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root

all: $(ROOT)/System/Library/Sounds/Finch.aiff

$(ROOT)/System/Library/Sounds/Finch.aiff: mksound.py
	@mkdir -p $(dir $@)
	python3 mksound.py $@

.PHONY: all

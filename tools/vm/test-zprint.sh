#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# zprint and zlog, built from system_cmds over Finch's CoreSymbolication and IOKit, in the
# VM (booted with zone logging on for proc_ro): CoreSymbolication finds and places the
# running kernel (finch-coresymbolication-test); zprint lists the zones and names the
# kexts' wired memory, leaving no memory site unnamed; zlog names the kernel function in
# a logged allocation's backtrace.
#
#   tools/vm/mkramdisk.sh && tools/vm/test-zprint.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
BOOT_ARGS_EXTRA="zlog1=proc_ro" exec tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp \
    "finch-coresymbolication-test" \
    "zprint > /tmp/zprint.txt && grep -q '^proc_ro ' /tmp/zprint.txt && grep -q '^com.apple.filesystems.apfs ' /tmp/zprint.txt" \
    "! grep -q 'site 0x' /tmp/zprint.txt" \
    "zlog -t | grep -q proc_ro" \
    "zlog -z proc_ro | grep -q '<kernel> zalloc_ro'"

#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Boot the emulated M4 (darwin-vm's qemu-sptm) with Finch's kernel collection
# and ramdisk.
#
# Environment:
#   FINCH_INIT=0     boot the base image's launchd instead of finch-init (PID 1 by
#                    default when build/vm has Finch's ramdisk; launchdsuffix=finch). Apple's launchd needs xpc SPI
#                    Finch's libxpc doesn't have (docs/design/XPC.md), so with a
#                    Finch image it stops at "Symbol not found".
#   FINCH_DEV_CONSOLE=0  use login instead of the development VM's root shell
#   BOOT_ARGS_EXTRA  extra boot-args to append
#   KC / RAMDISK / TC  override images (defaults: darwin-vm bootkc, build/vm ramdisk if built)
#   FINCH_DATA_IMAGE  attach an existing raw data image through the experimental
#                    PCI bridge. Requires the bridge-enabled kernel collection
#                    and a system image configured to mount its data volume.
#   DEBUG=1          expose a GDB stub on :1234 and wait for the debugger
#   GDB=1            expose a GDB stub on :1234 without waiting (to attach to a running VM,
#                    as tools/vm/catch-stall.exp does)
#   QEMUPORT=PORT    connect the guest's /dev/cu.qemuport0 to a TCP server on the host's
#                    localhost:PORT (darwin-vm's tunnel UART; finch-viewer uses it for the
#                    window server's display)
# Quit with Ctrl-A x.
set -euo pipefail

if [[ -n "${FINCH_BOOTKC:-}" ]]; then
    echo 'FINCH_BOOTKC is not a supported override; set KC to the kernel collection path.' >&2
    exit 2
fi

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DVM="${FINCH_ROOT}/third_party/darwin-vm"
FW="${DVM}/firmware"
QEMU="${DVM}/qemu-sptm/build/qemu-system-aarch64"

if [[ -f "${FINCH_ROOT}/build/vm/ramdisk.dmg" ]]; then
    : "${FINCH_INIT:=1}"   # Finch's image: finch-init is PID 1
    : "${RAMDISK:=${FINCH_ROOT}/build/vm/ramdisk.dmg}"
    : "${TC:=${FINCH_ROOT}/build/vm/ramdisk.tc}"
fi
: "${KC:=${FW}/bootkc}"
: "${RAMDISK:=${FW}/ramdisk.dmg}"
: "${TC:=${FW}/ramdisk.tc}"

# Apple silicon's 24 MHz timebase, not the base tree's 1 MHz (tools/vm/dtree-timebase.py)
DTREE="${FINCH_ROOT}/build/vm/dtree"
if [[ ! "${DTREE}" -nt "${FW}/dtree" || "${FINCH_ROOT}/tools/vm/dtree-timebase.py" -nt "${DTREE}" ]]; then
    mkdir -p "${FINCH_ROOT}/build/vm"
    python3 "${FINCH_ROOT}/tools/vm/dtree-timebase.py" "${FW}/dtree" "${DTREE}"
fi

machine=darwin
data_args=()
if [[ -n "${FINCH_DATA_IMAGE:-}" ]]; then
    # Only image files are accepted. Never interpret a device node or create a
    # missing image as a side effect of starting the VM.
    python3 - "$FINCH_DATA_IMAGE" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
if not os.path.isabs(path):
    raise SystemExit("FINCH_DATA_IMAGE must be an absolute image path")
try:
    info = os.lstat(path)
except OSError as error:
    raise SystemExit(f"cannot open data image: {error}")
if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
    raise SystemExit("FINCH_DATA_IMAGE must be an existing, nonempty regular file, not a link or device")
PY
    pcie_tree="${FINCH_ROOT}/build/vm/dtree-pcie"
    python3 "${FINCH_ROOT}/tools/vm/dtree-virtual-pcie.py" "$DTREE" "$pcie_tree"
    DTREE="$pcie_tree"
    machine=darwin,finch-pcie=on
    # QEMU uses commas as separators, even within one shell argument.
    data_path="${FINCH_DATA_IMAGE//,/,,}"
    data_args=(-drive "file=${data_path},if=none,format=raw,id=finchdata"
               -device virtio-blk-pci,drive=finchdata,disable-legacy=on)
fi

boot_args="rd=md0 serial=3 -v -noprogress wdt=-1 wlan-olyhal-abort"
[[ "${FINCH_INIT:-0}" == 1 ]] && boot_args+=" launchdsuffix=finch"
if [[ "${FINCH_INIT:-0}" == 1 && "${FINCH_DEV_CONSOLE:-1}" == 1 ]]; then
    boot_args+=" finch_dev_console=1"
fi
# no RTC in the emulated M4: finch-init sets the clock from the host's time
boot_args+=" finch_time=$(date +%s)"
[[ -n "${BOOT_ARGS_EXTRA:-}" ]] && boot_args+=" ${BOOT_ARGS_EXTRA}"

args=(
    -M "$machine"
    -bootkc "${KC}" -dtree "${DTREE}" -tc "${TC}" -ramdisk "${RAMDISK}"
    -args "${boot_args}"
    -nographic -serial mon:stdio -m 8G
)
if [[ ${#data_args[@]} -gt 0 ]]; then args+=("${data_args[@]}"); fi
[[ -f "${FW}/sptm" ]] && args+=(-sptm "${FW}/sptm" -txm "${FW}/txm")
[[ "${DEBUG:-0}" == 1 ]] && args+=(-s -S)
[[ "${GDB:-0}" == 1 && "${DEBUG:-0}" != 1 ]] && args+=(-s)
[[ -n "${QEMUPORT:-}" ]] && args+=(-chardev "socket,id=s0,host=localhost,server=on,wait=off,port=${QEMUPORT}" -serial chardev:s0)

trap 'stty sane 2>/dev/null || true' EXIT
printf 'VM kernel: %s\n' "${KC}"
shasum -a 256 "${KC}"
printf 'VM ramdisk: %s\n' "${RAMDISK}"
shasum -a 256 "${RAMDISK}"
"${QEMU}" "${args[@]}"

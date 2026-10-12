#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# IOBluetoothUI.framework: Finch's Bluetooth panels and hardware check (IOBluetoothUI.m).
#   userland/IOBluetoothUI/build.sh -> build/root/System/Library/Frameworks/IOBluetoothUI.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJC_ARC=1 CFLAGS="-I${FINCH_ROOT}/userland/IOBluetooth" exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/IOBluetoothUI.framework/Versions/A/IOBluetoothUI 1 1 com.apple.IOBluetoothUI 1.0 \
    "${FINCH_ROOT}/userland/IOBluetoothUI/IOBluetoothUI.m" -- -framework AppKit -framework IOBluetooth

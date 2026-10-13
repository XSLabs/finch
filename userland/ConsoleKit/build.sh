#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ConsoleKit.framework (private), Finch's own: what Console.app is built on (log streams
# from Finch's log store, the stream view, search tokens, devices, log report files).
#   userland/ConsoleKit/build.sh -> build/root/System/Library/PrivateFrameworks/ConsoleKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ConsoleKit"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/ConsoleKit.framework/Versions/A/ConsoleKit 1 1 com.apple.ConsoleKit 1.0 \
    "${HERE}/CSKModel.m" "${HERE}/CSKStream.m" "${HERE}/CSKAppKitAdditions.m" -- -framework AppKit -framework Foundation

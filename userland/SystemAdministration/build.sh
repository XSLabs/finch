#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SystemAdministration.framework (private): an empty image apps link (SystemAdministration.c).
#   userland/SystemAdministration/build.sh -> build/root/System/Library/PrivateFrameworks/SystemAdministration.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/SystemAdministration"
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Versions/A/SystemAdministration 1 1 com.apple.SystemAdministration 1.0 \
    "${HERE}/SystemAdministration.c"

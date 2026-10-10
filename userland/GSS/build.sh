#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# GSS.framework: Finch's GSS-API. No Kerberos yet, so it answers as a Mac without
# tickets (GSS.c); GSSOIDs.c has the standard OIDs.
#   userland/GSS/build.sh -> build/root/System/Library/Frameworks/GSS.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/GSS"
CFLAGS="-Wno-deprecated-declarations" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/GSS.framework/Versions/A/GSS 1.0.0 1 com.apple.gssframework 4.0 \
    "${HERE}/GSSOIDs.c" "${HERE}/GSS.c"

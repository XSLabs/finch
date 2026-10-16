#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ContactsUI: Finch's contact picker and contact card, using Finch Contacts and AppKit.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ContactsUI"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/ContactsUI.framework/Versions/A/ContactsUI 2732.255.131 1 com.apple.contactsui 1.0 \
    "${HERE}/ContactsUI.m" -- -framework AppKit -framework Contacts -framework Foundation

#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Contacts.framework: Finch's. The user's contacts in Finch's own store
# (CNContactStore.m), the contact model, formatters and vCard; CNConstants.m and
# CNStrings.inc have Apple's values and English names.
#   userland/Contacts/build.sh -> build/root/System/Library/Frameworks/Contacts.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Contacts"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-objc-property-implementation" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/Contacts.framework/Versions/A/Contacts 3804.255.181 1 com.apple.contacts 1.0 \
    "${HERE}/CNConstants.m" "${HERE}/CNContact.m" "${HERE}/CNValues.m" "${HERE}/CNFormatters.m" "${HERE}/CNVCard.m" \
    "${HERE}/CNContactStore.m" -- -framework Foundation -framework CoreFoundation -framework ImageIO -framework CoreGraphics

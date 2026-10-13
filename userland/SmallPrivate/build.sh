#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Small private frameworks apps link for a few symbols each, Finch's own: SoftLinking
# (_sl_dlopen), PerformanceAnalysis (operation marks), ConfigurationProfiles (a
# notification name), UIKitMacHelper (no Catalyst delegate), ChronoServices (timeline
# reloads), UserManagement (no personas) and AppSupport (bitmap files, log flushing, no
# city database, no radios) and TextInputUI (empty: apps link it and use nothing). Each
# file's comment says what it does.
#   userland/SmallPrivate/build.sh -> build/root/System/Library/PrivateFrameworks/<name>.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/SmallPrivate"
B="${FINCH_ROOT}/tools/build-small-framework.sh"
P=/System/Library/PrivateFrameworks
"$B" $P/SoftLinking.framework/Versions/A/SoftLinking 1 1 com.apple.SoftLinking 1.0 "${HERE}/SoftLinking.c"
"$B" $P/PerformanceAnalysis.framework/Versions/A/PerformanceAnalysis 1 1 com.apple.PerformanceAnalysis 1.0 "${HERE}/PerformanceAnalysis.c"
"$B" $P/ConfigurationProfiles.framework/Versions/A/ConfigurationProfiles 1 1 com.apple.ConfigurationProfiles 1.0 \
    "${HERE}/ConfigurationProfiles.c" -- -framework CoreFoundation
"$B" $P/UIKitMacHelper.framework/Versions/A/UIKitMacHelper 1 1 com.apple.UIKitMacHelper 1.0 "${HERE}/UIKitMacHelper.c"
OBJC_ARC=1 "$B" $P/ChronoServices.framework/Versions/A/ChronoServices 1 1 com.apple.chronoservices 1.0 "${HERE}/ChronoServices.m" \
    -- -framework Foundation
OBJC_ARC=1 "$B" $P/UserManagement.framework/Versions/A/UserManagement 1 1 com.apple.UserManagement 1.0 "${HERE}/UserManagement.m" \
    -- -framework Foundation
OBJC_ARC=1 "$B" $P/AppSupport.framework/Versions/A/AppSupport 1 1 com.apple.AppSupport 1.0 "${HERE}/AppSupport.m" \
    -- -framework Foundation -framework ImageIO -framework CoreGraphics
"$B" $P/TextInputUI.framework/Versions/A/TextInputUI 1 1 com.apple.TextInputUI 1.0 "${HERE}/TextInputUI.c"

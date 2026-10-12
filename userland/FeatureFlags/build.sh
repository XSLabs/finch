#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# FeatureFlags.framework (private): Finch's, Swift, to Apple's ABI.
#
#   userland/FeatureFlags/build.sh -> build/root/System/Library/PrivateFrameworks/FeatureFlags.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/FeatureFlags"
FINCH_PRIVATE_FRAMEWORK=1 exec "${FINCH_ROOT}/tools/build-swift-framework.sh" FeatureFlags 1 "${HERE}/FeatureFlags.swift"

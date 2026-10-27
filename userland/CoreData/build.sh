#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's CoreData ABI: compiled-model reading, managed objects and contexts,
# the SQLite and in-memory stores, fetch requests and fetched results.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreData"
ROOT="${FINCH_ROOT}/build/root"
SQLITE="${ROOT}/usr/lib/libsqlite3.dylib"

for dependency in \
    "${ROOT}/System/Library/Frameworks/Foundation.framework/Foundation" \
    "${ROOT}/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" \
    "${ROOT}/System/Library/Frameworks/Combine.framework/Combine" \
    "${SQLITE}"; do
    [[ -f "${dependency}" ]] || { echo "build CoreFoundation, Foundation, Combine and libsqlite3 first" >&2; exit 1; }
done

FINCH_OBJC_FLAGS="-Wno-deprecated-declarations" \
    "${FINCH_ROOT}/tools/build-swift-framework.sh" CoreData 1526 \
    "${HERE}/CoreDataOverlay.swift" \
    "${HERE}/CDConstants.m" \
    "${HERE}/CDModel.m" \
    "${HERE}/CDRequest.m" \
    "${HERE}/CDStore.m" \
    "${HERE}/CDCustomStore.m" \
    "${HERE}/CDMigration.m" \
    "${HERE}/CDNewClasses.m" \
    "${HERE}/CDXMLStore.m" \
    "${HERE}/CDContext.m" \
    "${HERE}/CDContainer.m" \
    "${HERE}/CDFetchedResultsController.m" \
    "${HERE}/CDExtensions.m" \
    -- -framework Foundation -framework CoreFoundation -framework Combine "${SQLITE}"

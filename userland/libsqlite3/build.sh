#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Finch's SQLite from the pinned, public-domain amalgamation. The SQLite
# image uses Apple's install name so existing apps find it at /usr/lib.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=3.54.0
ARCHIVE_NAME=sqlite-amalgamation-3540000.zip
ARCHIVE_SHA3=7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93
DOWNLOADS="${FINCH_ROOT}/build/downloads"
SOURCE_ROOT="${FINCH_ROOT}/build/src/sqlite-${VERSION}"
ARCHIVE="${DOWNLOADS}/${ARCHIVE_NAME}"

mkdir -p "${DOWNLOADS}"
if [[ ! -f "${ARCHIVE}" ]]; then
    curl --fail --location --silent --show-error \
        "https://www.sqlite.org/2026/${ARCHIVE_NAME}" -o "${ARCHIVE}"
fi
python3 - "${ARCHIVE}" "${ARCHIVE_SHA3}" <<'PY'
import hashlib
import pathlib
import sys

actual = hashlib.sha3_256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit(f"SQLite archive hash mismatch: {actual}")
PY

rm -rf "${SOURCE_ROOT}"
mkdir -p "${SOURCE_ROOT}"
unzip -q "${ARCHIVE}" -d "${SOURCE_ROOT}"
SQLITE_SOURCE="${SOURCE_ROOT}/sqlite-amalgamation-3540000"
[[ -s "${SQLITE_SOURCE}/sqlite3.c" && -s "${SQLITE_SOURCE}/sqlite3.h" ]] || {
    echo "SQLite amalgamation is missing sqlite3.c or sqlite3.h" >&2
    exit 1
}

# These options keep the shared library useful to other Finch frameworks as
# well as CoreData: full mutex support, FTS5, R*Tree, sessions and metadata.
CFLAGS="-I${SQLITE_SOURCE} -Wno-error=sign-compare -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 \
    -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_COLUMN_METADATA \
    -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_SESSION \
    -DSQLITE_ENABLE_SNAPSHOT -DSQLITE_ENABLE_DESERIALIZE" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /usr/lib/libsqlite3.dylib 381 9 - 3.54.0 \
    "${SQLITE_SOURCE}/sqlite3.c" \
    -- -lm

LICENSE_DIR="${FINCH_ROOT}/build/root/usr/share/finch/licenses/sqlite"
mkdir -p "${LICENSE_DIR}"
cat > "${LICENSE_DIR}/PUBLIC-DOMAIN.txt" <<EOF
SQLite ${VERSION} amalgamation
Source: https://www.sqlite.org/2026/${ARCHIVE_NAME}
SQLite's authors dedicated the delivered code to the public domain.
EOF

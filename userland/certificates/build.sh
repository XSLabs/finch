#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Mozilla's HTTPS roots, from curl's dated PEM export. Pin the data and its
# checksum together; a rebuild must not silently change whom Finch trusts.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${FINCH_OUTPUT_ROOT:-${FINCH_ROOT}/build/root}"
VERSION=2026-09-25
SHA256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
URL="https://curl.se/ca/cacert-${VERSION}.pem"
DL="${FINCH_ROOT}/build/src/upstream-dl"
BUNDLE="${DL}/cacert-${VERSION}.pem"
mkdir -p "${DL}"
if [[ ! -f "${BUNDLE}" || "$(shasum -a 256 "${BUNDLE}" | cut -c1-64)" != "${SHA256}" ]]; then
    temp="$(mktemp "${DL}/cacert.XXXXXX")"
    trap 'rm -f "${temp}"' EXIT
    curl -fsSL --retry 2 "${URL}" -o "${temp}"
    [[ "$(shasum -a 256 "${temp}" | cut -c1-64)" == "${SHA256}" ]] || { echo "certificate bundle: checksum mismatch" >&2; exit 1; }
    mv "${temp}" "${BUNDLE}"
    trap - EXIT
fi
# Check the whole PEM before it can replace the image's trust store.
python3 - "${BUNDLE}" <<'PY'
import ssl, sys
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.load_verify_locations(cafile=sys.argv[1])
if context.cert_store_stats()['x509_ca'] != 121:
    raise SystemExit('certificate bundle: unexpected root count')
PY
OUT="${ROOT}/private/etc/ssl"
NOTICES="${ROOT}/usr/share/finch/licenses/ca-certificates"
mkdir -p "${OUT}" "${NOTICES}"
install -m 644 "${BUNDLE}" "${OUT}/cert.pem"
install -m 644 "${FINCH_ROOT}/userland/certificates/MPL-2.0.txt" "${NOTICES}/MPL-2.0.txt"
printf 'Mozilla CA certificates, curl export %s\nSource: %s\nSHA-256: %s\nLicense: MPL-2.0\n' \
    "${VERSION}" "${URL}" "${SHA256}" > "${NOTICES}/SOURCE.txt"
echo "==> installed Mozilla HTTPS roots (${VERSION}, 121 certificates)"

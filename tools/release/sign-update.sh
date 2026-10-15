#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Sign an update (an install payload, tools/release/mkrootfs.py) for finch-update: ECDSA P-256
# over the archive's SHA-256, written beside it as ARCHIVE.sig (DER, X9.62).
#
#   tools/release/sign-update.sh build/release/rootfs.tar.gz
#
# The key pair is kept in build/release/keys (made on first use; never in the repository):
# update-key.pem, the private key, and update-key.der, the public curve point (X9.63) that
# the system carries as /usr/share/finch/update-key.der (userland/update). A real release's
# key is its maker's to keep: FINCH_UPDATE_SIGNING_KEY names another private key.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
archive="${1:?usage: sign-update.sh ARCHIVE}"
keys="${FINCH_ROOT}/build/release/keys"
key="${FINCH_UPDATE_SIGNING_KEY:-${keys}/update-key.pem}"
if [[ ! -f "${key}" ]]; then
    mkdir -p "$(dirname "${key}")"
    (umask 077 && openssl ecparam -name prime256v1 -genkey -noout -out "${key}")
    echo "made a development update key: ${key}"
fi
# the public point: the last 65 bytes of the SubjectPublicKeyInfo (04 || X || Y)
openssl ec -in "${key}" -pubout -outform DER 2>/dev/null | tail -c 65 > "${keys}/update-key.der"
openssl dgst -sha256 -sign "${key}" -out "${archive}.sig" "${archive}"
echo "signed ${archive} (${archive}.sig); public key ${keys}/update-key.der"

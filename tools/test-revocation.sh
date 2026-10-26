#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Revocation checks in Finch's Security, on the host: serves OCSP (openssl ocsp)
# and the CRL (python's http.server) for the test-only authority in
# userland/tests/revocation-fixture, makes a stapled OCSP response, then runs
# finch-security-revocation-test against Finch's Security and compares its output.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"
fixture=userland/tests/revocation-fixture
work="$(mktemp -d)"
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
    rm -rf "${work}"
}
trap cleanup EXIT
openssl ocsp -index "${fixture}/index.txt" -port 18780 -rsigner "${fixture}/ocsp.pem" \
    -rkey "${fixture}/ocsp.key" -CA "${fixture}/root.pem" -ndays 7 >/dev/null 2>&1 &
pids+=($!)
python3 -m http.server 18781 --bind 127.0.0.1 --directory "${fixture}" >/dev/null 2>&1 &
pids+=($!)
sleep 2
# A response for the revoked certificate, to staple.
openssl ocsp -issuer "${fixture}/root.pem" -cert "${fixture}/revoked.pem" -url http://127.0.0.1:18780 \
    -respout "${work}/stapled.der" -noverify >/dev/null 2>&1
make -s -C userland/tests ../../build/userland/finch-security-revocation-test
R=build/root/System/Library
mkdir -p "${work}/lib"
ln -s "${root}/build/root/usr/lib/system/libfinchaccount.dylib" "${work}/lib/"
DYLD_FRAMEWORK_PATH="${R}/Frameworks:${R}/PrivateFrameworks" DYLD_LIBRARY_PATH="${work}/lib" \
    build/userland/finch-security-revocation-test "${fixture}" "${work}/stapled.der" > "${work}/out" || true
cat "${work}/out"
diff -u userland/tests/security-revocation-test.expected "${work}/out"
echo "test-revocation: passed"

#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the per-user Finch keychain service after Security.framework.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$FINCH_ROOT/userland/securityd"
SECURITY="$FINCH_ROOT/userland/Security"
OPENSSL="$FINCH_ROOT/build/obj/corecrypto-openssl"
SECURITY_OBJ="${FINCH_SECURITY_OBJ_DIR:-$FINCH_ROOT/build/obj/Security}"
OBJ="${FINCH_OBJ_DIR:-$FINCH_ROOT/build/obj/securityd}"
ROOT="${FINCH_OUTPUT_ROOT:-$FINCH_ROOT/build/root}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"

[[ -f "$SECURITY_OBJ/SecConstants.c" ]] || { echo "build Security.framework first" >&2; exit 1; }
[[ -f "$OPENSSL/libcrypto.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
[[ -f "$OPENSSL/libssl.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
[[ -f "$ROOT/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" ]] || {
	echo "build CoreFoundation first" >&2
	exit 1
}
[[ -f "$FINCH_ROOT/build/userland/libxpc/libxpc.dylib" ]] || {
	echo "build Finch libxpc first" >&2
	exit 1
}

rm -rf "$OBJ"
mkdir -p "$OBJ/o"
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "$SDKROOT" -Os -g -fblocks -fno-common
	-Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -Wno-nonnull
	-DFINCH_KEYCHAIN_SERVICE_BACKEND=1
	-I"$SECURITY" -I"$SECURITY_OBJ/hdr" -I"$OPENSSL/include" -I"$FINCH_ROOT/build/src/openssl/include")

objects=()
for source in "$SECURITY/SecKeychain.c" "$SECURITY/SecKeychainCrypto.c" \
	"$SECURITY/SecAccess.c" "$SECURITY/SecObjects.c" "$SECURITY/SecTrustSettings.c" "$SECURITY/SecRevocation.c" \
	"$SECURITY/SecKeychainServiceWire.c" "$SECURITY_OBJ/SecConstants.c" \
	"$HERE/securityd.c"; do
	output="$OBJ/o/$(basename "${source%.c}").o"
	"$CC" "${CFLAGS[@]}" -c "$source" -o "$output"
	objects+=("$output")
done

mkdir -p "$ROOT/usr/libexec" "$ROOT/System/Library/Finch/LaunchAgents"
"$CC" -arch arm64e -mmacosx-version-min=26.0 -isysroot "$SDKROOT" \
	"${objects[@]}" "$OPENSSL/libssl.a" "$OPENSSL/libcrypto.a" \
	-F"$ROOT/System/Library/Frameworks" -framework CoreFoundation -lbsm \
	-L"$FINCH_ROOT/build/userland/libxpc" -lxpc \
	-o "$ROOT/usr/libexec/securityd"
codesign -f -s - -i org.finch.securityd "$ROOT/usr/libexec/securityd" 2>/dev/null
install -m 0644 "$HERE/org.finch.securityd.plist" \
	"$ROOT/System/Library/Finch/LaunchAgents/org.finch.securityd.plist"
echo "==> installed per-user keychain service"

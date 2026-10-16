#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Select Swift Crypto's own implementation when building on macOS for Finch."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
switches = 0
namespaces = 0
for path in root.rglob("*.swift"):
    source = path.read_text()
    count = source.count("#if canImport(CryptoKit)")
    if count:
        source = source.replace(
            "#if canImport(CryptoKit)",
            "#if canImport(CryptoKit) && !FINCH_CRYPTO_IMPLEMENTATION",
        )
        switches += count
    # swift-crypto refers to its own target as Crypto; this build gives that
    # target Apple's CryptoKit module name, so retain the references' meaning.
    namespace_count = source.count("Crypto.")
    source = source.replace("Crypto.", "CryptoKit.")
    if count or namespace_count:
        path.write_text(source)
        namespaces += namespace_count

# These helper initializers are internal. With Swift 6.3's library-evolution
# checks they cannot be inlined while directly initializing their stored fields.
private_initializers = {
    "Keys/EC/BoringSSL/NISTCurvesKeys_boring.swift": (
        "    @inlinable\n    init(wrapping key: BoringSSLECPublicKeyWrapper<Curve>) {",
        "    init(wrapping key: BoringSSLECPublicKeyWrapper<Curve>) {",
    ),
    "Keys/EC/BoringSSL/X25519Keys_boring.swift": (
        "        @inlinable\n        init<D: ContiguousBytes>(rawRepresentation: D) throws {",
        "        init<D: ContiguousBytes>(rawRepresentation: D) throws {",
    ),
    "Keys/EC/BoringSSL/Ed25519_boring.swift": (
        "        @inlinable\n        init<D: ContiguousBytes>(rawRepresentation: D) throws {",
        "        init<D: ContiguousBytes>(rawRepresentation: D) throws {",
    ),
}
for relative, (old, new) in private_initializers.items():
    path = root / relative
    source = path.read_text()
    if source.count(old) != 1:
        raise SystemExit(f"{relative}: expected one private initializer to adapt")
    path.write_text(source.replace(old, new, 1))

if switches == 0:
    raise SystemExit("no Swift Crypto platform switches found; check the pinned source")
print(f"selected the Finch backend at {switches} switches and renamed {namespaces} module references")

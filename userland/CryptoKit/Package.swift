// swift-tools-version:6.2
// SPDX-License-Identifier: MIT OR Apache-2.0
// Build recipe for swift-crypto's sources as Finch's CryptoKit module.
// The package is copied into build/obj/CryptoKit before SwiftPM reads it.
import PackageDescription

let package = Package(
    name: "FinchCryptoKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CryptoKit", type: .dynamic, targets: ["CryptoKit"]),
    ],
    targets: [
        .target(
            name: "CCryptoBoringSSL",
            exclude: [
                "hash.txt",
                "CMakeLists.txt",
                "PrivacyInfo.xcprivacy",
                "crypto/bio/connect.cc",
                "crypto/bio/socket_helper.cc",
                "crypto/bio/socket.cc",
            ],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fvisibility=hidden"])],
            cxxSettings: [.unsafeFlags(["-fvisibility=hidden"]) ]
        ),
        .target(
            name: "CXKCP",
            exclude: ["CMakeLists.txt", "vendored-sources.txt"],
            publicHeadersPath: "include",
            cSettings: [
                .define("XKCP_has_KeccakP1600"),
                .headerSearchPath("include"),
                .headerSearchPath("high"),
                .headerSearchPath("low"),
                .headerSearchPath("low/KeccakP-1600"),
                .headerSearchPath("low/common"),
                .headerSearchPath("common"),
                .disableWarning("macro-redefined"),
                .unsafeFlags(["-fvisibility=hidden"]),
            ]
        ),
        .target(
            name: "CXKCPShims",
            dependencies: ["CXKCP"],
            exclude: ["CMakeLists.txt", "PrivacyInfo.xcprivacy"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fvisibility=hidden"]) ]
        ),
        .target(
            name: "CryptoBoringWrapper",
            dependencies: ["CCryptoBoringSSL"],
            exclude: ["CMakeLists.txt", "PrivacyInfo.xcprivacy"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
                .enableExperimentalFeature("SourceWarningControl"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .unsafeFlags(["-swift-version", "5", "-enable-library-evolution"]),
            ]
        ),
        .target(
            name: "CryptoKit",
            dependencies: ["CCryptoBoringSSL", "CryptoBoringWrapper", "CXKCP", "CXKCPShims"],
            path: "Sources/Crypto",
            exclude: [
                "vendored-sources.txt",
                "CMakeLists.txt",
                "PrivacyInfo.xcprivacy",
                "Signatures/BoringSSL/MLDSA_boring.swift.gyb",
                "KEM/BoringSSL/MLKEM_boring.swift.gyb",
            ],
            swiftSettings: [
                .define("CRYPTO_IN_SWIFTPM"),
                .define("FINCH_CRYPTO_IMPLEMENTATION"),
                .enableExperimentalFeature("Lifetimes"),
                .enableExperimentalFeature("SourceWarningControl"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .unsafeFlags(["-swift-version", "5", "-enable-library-evolution"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

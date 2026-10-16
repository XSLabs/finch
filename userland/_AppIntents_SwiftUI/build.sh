#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppIntents' local SwiftUI modifiers and controls.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWIFTUI_MODULES="${FINCH_ROOT}/build/obj/SwiftUI-pkg/build/arm64e-apple-macosx/release/Modules"
SWIFTUI_BUILD="${FINCH_ROOT}/build/obj/SwiftUI-pkg/build/arm64e-apple-macosx/release"
SWIFTUI_SRC="${FINCH_ROOT}/build/obj/SwiftUI-pkg/src/Sources"
CHECKOUTS="${FINCH_ROOT}/build/obj/SwiftUI-pkg/build/checkouts"
BRIDGE_FLAGS="-no-verify-emitted-module-interface -I ${FINCH_ROOT}/build/obj/AppIntents -I ${SWIFTUI_MODULES} \
    -Xcc -fmodule-map-file=${SWIFTUI_BUILD}/COpenSwiftUI.build/module.modulemap -Xcc -I${SWIFTUI_SRC}/COpenSwiftUI \
    -Xcc -fmodule-map-file=${SWIFTUI_BUILD}/OpenObservationCxx.build/module.modulemap -Xcc -I${CHECKOUTS}/OpenObservation/Sources/OpenObservationCxx/include \
    -Xcc -fmodule-map-file=${CHECKOUTS}/Compute/Sources/ComputeCxx/include/module.modulemap -Xcc -I${CHECKOUTS}/Compute/Sources/ComputeCxx/include \
    -Xcc -fmodule-map-file=${CHECKOUTS}/OpenRenderBox/Sources/OpenRenderBoxCxx/include/module.modulemap -Xcc -I${CHECKOUTS}/OpenRenderBox/Sources/OpenRenderBoxCxx/include \
    -Xcc -fmodule-map-file=${CHECKOUTS}/OpenRenderBox/Sources/OpenRenderBoxShimsCxx/include/OpenRenderBox/module.modulemap -Xcc -I${CHECKOUTS}/OpenRenderBox/Sources/OpenRenderBoxShimsCxx/include/OpenRenderBox \
    -Xcc -fmodule-map-file=${CHECKOUTS}/Compute/Sources/Utilities/include/module.modulemap -Xcc -I${CHECKOUTS}/Compute/Sources/Utilities/include \
    -Xcc -fmodule-map-file=${CHECKOUTS}/Compute/Sources/Platform/include/module.modulemap -Xcc -I${CHECKOUTS}/Compute/Sources/Platform/include \
    -Xcc -fmodule-map-file=${SWIFTUI_SRC}/OpenSwiftUI_SPI/module.modulemap -Xcc -I${SWIFTUI_SRC}/OpenSwiftUI_SPI \
    -Xcc -fmodule-map-file=${CHECKOUTS}/swift-numerics/Sources/_NumericsShims/include/module.modulemap -Xcc -I${CHECKOUTS}/swift-numerics/Sources/_NumericsShims/include"
build_bridge() {
    FINCH_SWIFT_FLAGS="${BRIDGE_FLAGS}" "${FINCH_ROOT}/tools/build-swift-framework.sh" _AppIntents_SwiftUI 1 \
        "${FINCH_ROOT}/userland/_AppIntents_SwiftUI/_AppIntents_SwiftUI.swift" -- \
        -framework SwiftUI -framework AppIntents
}
FINCH_OUTPUT_ROOT="${FINCH_ROOT}/build/root/System/iOSSupport" \
FINCH_INSTALL_NAME="/System/iOSSupport/System/Library/Frameworks/_AppIntents_SwiftUI.framework/Versions/A/_AppIntents_SwiftUI" \
    build_bridge
build_bridge

# Keep a compiled module beside the framework interface so comparison tests can
# import the same Finch SwiftUI types used by this bridge.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -swift-version 5 -O \
    -parse-as-library -enable-library-evolution -emit-module -module-name _AppIntents_SwiftUI \
    -package-name src -I "${FINCH_ROOT}/build/obj/AppIntents" ${BRIDGE_FLAGS} \
    -emit-module-path "${FINCH_ROOT}/build/obj/_AppIntents_SwiftUI/_AppIntents_SwiftUI.swiftmodule" \
    "${FINCH_ROOT}/userland/_AppIntents_SwiftUI/_AppIntents_SwiftUI.swift"

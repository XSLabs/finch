#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Network.framework: Finch's Swift API over BSD sockets and DNS-SD.
#   userland/Network/build.sh -> build/root/System/Library/Frameworks/Network.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" Network 5812 \
    "${FINCH_ROOT}/userland/Network/Network.swift" \
    "${FINCH_ROOT}/userland/Network/Endpoints.swift" \
    "${FINCH_ROOT}/userland/Network/Protocols.swift" \
    "${FINCH_ROOT}/userland/Network/SocketSupport.swift" \
    "${FINCH_ROOT}/userland/Network/Connection.swift" \
    "${FINCH_ROOT}/userland/Network/Listener.swift" \
    "${FINCH_ROOT}/userland/Network/Browser.swift" \
    "${FINCH_ROOT}/userland/Network/ConnectionGroup.swift" \
    "${FINCH_ROOT}/userland/Network/CAPI.swift" \
    "${FINCH_ROOT}/userland/Network/CAPIConnection.swift" \
    "${FINCH_ROOT}/userland/Network/CAPIServices.swift" \
    "${FINCH_ROOT}/userland/Network/CAPIProtocols.swift" \
    "${FINCH_ROOT}/userland/Network/network.m" "${FINCH_ROOT}/userland/Network/NetworkGlobals.m" -- -framework Foundation -framework Security -framework SystemConfiguration \
    -L"${FINCH_ROOT}/build/root/usr/lib/system" -lsystem_dnssd

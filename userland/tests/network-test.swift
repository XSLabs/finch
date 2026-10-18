// SPDX-License-Identifier: MIT OR Apache-2.0
// A deterministic Network.framework comparison: endpoint values, path monitor,
// a loopback TCP listener and a loopback UDP connection.
import Darwin
import Dispatch
import Foundation
import Network
import Security

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.withLock { stored = value } }
    var value: Value? { lock.withLock { stored } }
}

func wait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}

func pathName(_ status: NWPath.Status) -> String {
    switch status {
    case .satisfied: return "satisfied"
    case .unsatisfied: return "unsatisfied"
    case .requiresConnection: return "requiresConnection"
    @unknown default: return "unknown"
    }
}

func loadedNetworkPath() -> String {
    var info = Dl_info()
    let pointer = unsafeBitCast(NWConnection.self, to: UnsafeRawPointer.self)
    guard dladdr(pointer, &info) != 0, let path = info.dli_fname else { return "unknown" }
    return String(cString: path)
}

@_silgen_name("finch_test_tls_server_start")
private func startTLSServer(_ port: UnsafeMutablePointer<UInt16>) -> Int32

@_silgen_name("finch_test_tls_server_wait")
private func waitTLSServer()

struct TLSResult {
    let ready: Bool
    let verifyCalled: Bool
    let echo: String?
    let metadata: NWProtocolTLS.Metadata?
    let contextMetadata: NWProtocolTLS.Metadata?
}

func runTLS(port: NWEndpoint.Port, minimumVersion: tls_protocol_version_t,
            offerALPN: Bool, acceptPeer: Bool, exchangeData: Bool) -> TLSResult {
    let tlsOptions = NWProtocolTLS.Options()
    let securityOptions = tlsOptions.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumVersion)
    "localhost".withCString { sec_protocol_options_set_tls_server_name(securityOptions, $0) }
    if offerALPN {
        "h2".withCString { sec_protocol_options_add_tls_application_protocol(securityOptions, $0) }
    }
    let verificationQueue = DispatchQueue(label: "finch.network.tls.verify")
    let verifyCalled = Box<Bool>()
    verifyCalled.set(false)
    sec_protocol_options_set_verify_block(securityOptions, { metadata, trust, complete in
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
        var certificateCount = 0
        let hasCertificates = sec_protocol_metadata_access_peer_certificate_chain(metadata) { _ in
            certificateCount += 1
        }
        verifyCalled.set(version.rawValue != 0 && hasCertificates && certificateCount > 0)
        var trustedSelfSignedCertificate = false
        let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
        var anchor: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if anchor == nil {
                anchor = sec_certificate_copy_ref(certificate).takeRetainedValue()
            }
        }
        if let anchor {
            let anchors = [anchor] as CFArray
            let setAnchors = SecTrustSetAnchorCertificates(trustRef, anchors) == errSecSuccess
            let onlyAnchors = SecTrustSetAnchorCertificatesOnly(trustRef, true) == errSecSuccess
            let evaluated = SecTrustEvaluateWithError(trustRef, nil)
            trustedSelfSignedCertificate = setAnchors && onlyAnchors && evaluated
        }
        complete(acceptPeer && trustedSelfSignedCertificate)
    }, verificationQueue)

    let connection = NWConnection(host: "127.0.0.1", port: port,
                                  using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
    let queue = DispatchQueue(label: "finch.network.tls.connection")
    let readySignal = DispatchSemaphore(value: 0)
    let readyValue = Box<Bool>()
    readyValue.set(false)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            readyValue.set(true)
            readySignal.signal()
        case .failed:
            readyValue.set(false)
            readySignal.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    _ = wait(readySignal)
    let ready = readyValue.value ?? false
    let connectionMetadata = ready
        ? connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        : nil
    var echo: String?
    var metadata: NWProtocolTLS.Metadata?
    var contextMetadata: NWProtocolTLS.Metadata?
    if ready && exchangeData {
        let responseSignal = DispatchSemaphore(value: 0)
        let response = Box<String>()
        let responseMetadata = Box<NWProtocolTLS.Metadata>()
        connection.receive(minimumIncompleteLength: 3, maximumLength: 32) { data, context, _, _ in
            response.set(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            if let value = context?.protocolMetadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                responseMetadata.set(value)
            }
            responseSignal.signal()
        }
        let sendSignal = DispatchSemaphore(value: 0)
        connection.send(content: Data("tls".utf8), completion: .contentProcessed { _ in sendSignal.signal() })
        if wait(sendSignal) && wait(responseSignal) {
            echo = response.value
            contextMetadata = responseMetadata.value
        }
    }
    metadata = connectionMetadata ?? contextMetadata
    connection.cancel()
    return TLSResult(ready: ready, verifyCalled: verifyCalled.value ?? false, echo: echo,
                     metadata: metadata, contextMetadata: contextMetadata)
}

func compareTLSOptions() {
    var rawPort: UInt16 = 0
    precondition(startTLSServer(&rawPort) == 0)
    let port = NWEndpoint.Port(rawValue: rawPort)!
    let rejected = runTLS(port: port, minimumVersion: tls_protocol_version_t.TLSv12,
                          offerALPN: false, acceptPeer: false, exchangeData: false)
    print("TLS verify rejects: callback=\(rejected.verifyCalled) ready=\(rejected.ready)")

    let incompatible = runTLS(port: port, minimumVersion: tls_protocol_version_t.TLSv13,
                              offerALPN: false, acceptPeer: true, exchangeData: false)
    print("TLS minimum version: TLSv13 on TLSv12 server ready=\(incompatible.ready)")

    let accepted = runTLS(port: port, minimumVersion: tls_protocol_version_t.TLSv12,
                          offerALPN: true, acceptPeer: true, exchangeData: true)
    var alpn = "none"
    var version = 0
    var cipherAvailable = false
    var certificateCount = 0
    var hasCertificates = false
    var serverName = "none"
    if let metadata = accepted.metadata?.securityProtocolMetadata {
        version = Int(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue)
        cipherAvailable = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue != 0
        if let value = sec_protocol_metadata_copy_negotiated_protocol(metadata) {
            alpn = String(cString: value)
            free(UnsafeMutableRawPointer(mutating: value))
        }
        hasCertificates = sec_protocol_metadata_access_peer_certificate_chain(metadata) { _ in
            certificateCount += 1
        }
        if let value = sec_protocol_metadata_copy_server_name(metadata) {
            serverName = String(cString: value)
            free(UnsafeMutableRawPointer(mutating: value))
        }
    }
    print("TLS accepted: ready=\(accepted.ready) callback=\(accepted.verifyCalled) connectionMetadata=\(accepted.metadata != nil) contextMetadata=\(accepted.contextMetadata != nil) version=\(version) cipher=\(cipherAvailable) alpn=\(alpn) certificates=\(hasCertificates ? certificateCount : 0) serverName=\(serverName) echo=\(accepted.echo ?? "")")
    waitTLSServer()
}

func startUDPEchoServer() -> (Int32, NWEndpoint.Port, DispatchSourceRead) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    precondition(fd >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    "127.0.0.1".withCString { _ = inet_pton(AF_INET, $0, &address.sin_addr) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bound == 0)
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    precondition(named == 0)
    let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: actual.sin_port))!
    let queue = DispatchQueue(label: "finch.network.udp-echo")
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
        var client = sockaddr_storage()
        var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var bytes = [UInt8](repeating: 0, count: 65_535)
        let count = bytes.withUnsafeMutableBytes { buffer in
            withUnsafeMutablePointer(to: &client) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &clientLength)
                }
            }
        }
        guard count >= 0 else { return }
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: client) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, buffer.baseAddress, count, 0, $0, clientLength)
                }
            }
        }
    }
    source.resume()
    return (fd, port, source)
}

print("Network loaded: \(loadedNetworkPath())")

let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 8080)!)
if case let .hostPort(host, port) = endpoint {
    print("endpoint: \(host.debugDescription) port=\(port.rawValue)")
}
let address = IPv4Address("192.0.2.1")!
print("IPv4: \(address.debugDescription) bytes=\(Array(address.rawValue))")
let tcpOptions = NWProtocolTCP.Options()
tcpOptions.noDelay = true
tcpOptions.enableKeepalive = true
print("TCP options: noDelay=\(tcpOptions.noDelay) keepalive=\(tcpOptions.enableKeepalive)")
let parameters = NWParameters.tcp
print("TCP parameters: local=\(parameters.requiredLocalEndpoint == nil) reuse=\(parameters.allowLocalEndpointReuse) peer=\(parameters.includePeerToPeer)")
print("UDP parameters: \(NWProtocolUDP.Options().preferNoChecksum)")

let tlsOptionsA = NWProtocolTLS.Options()
let tlsOptionsB = NWProtocolTLS.Options()
let securityOptionsA = tlsOptionsA.securityProtocolOptions
let securityOptionsB = tlsOptionsB.securityProtocolOptions
print("TLS defaults: min=\(Int(sec_protocol_options_get_default_min_tls_protocol_version().rawValue)) max=\(Int(sec_protocol_options_get_default_max_tls_protocol_version().rawValue)) dtlsMin=\(Int(sec_protocol_options_get_default_min_dtls_protocol_version().rawValue)) dtlsMax=\(Int(sec_protocol_options_get_default_max_dtls_protocol_version().rawValue))")
print("TLS options equal at start: \(sec_protocol_options_are_equal(securityOptionsA, securityOptionsB))")
"api.finch.example".withCString { sec_protocol_options_set_tls_server_name(securityOptionsA, $0) }
print("TLS options differ after one name: \(!sec_protocol_options_are_equal(securityOptionsA, securityOptionsB))")
"api.finch.example".withCString { sec_protocol_options_set_tls_server_name(securityOptionsB, $0) }
print("TLS options equal after same name: \(sec_protocol_options_are_equal(securityOptionsA, securityOptionsB))")
sec_protocol_options_set_tls_tickets_enabled(securityOptionsA, false)
print("TLS options differ after one flag: \(!sec_protocol_options_are_equal(securityOptionsA, securityOptionsB))")
sec_protocol_options_set_tls_tickets_enabled(securityOptionsB, false)
print("TLS options equal after same flag: \(sec_protocol_options_are_equal(securityOptionsA, securityOptionsB))")

compareTLSOptions()

// A host may have an external route while the VM has only loopback. Exercise
// the same explicit interface restriction on both, then test real loopback
// TCP and TLS connections below. IPv4 availability depends on the machine.
let blockedInterfaceTypes: [NWInterface.InterfaceType] = [.other, .wifi, .cellular, .wiredEthernet, .loopback]
let pathMonitor = NWPathMonitor(prohibitedInterfaceTypes: blockedInterfaceTypes)
let pathReady = DispatchSemaphore(value: 0)
let pathResult = Box<NWPath>()
pathMonitor.pathUpdateHandler = { path in
    if pathResult.value == nil {
        pathResult.set(path)
        pathReady.signal()
    }
}
pathMonitor.start(queue: DispatchQueue(label: "finch.network.path"))
let gotPath = wait(pathReady)
pathMonitor.cancel()
if gotPath, let path = pathResult.value {
    print("blocked path: \(pathName(path.status))")
} else {
    print("blocked path: timeout")
}

let asyncPathMonitor = NWPathMonitor(prohibitedInterfaceTypes: blockedInterfaceTypes)
let asyncPathReady = DispatchSemaphore(value: 0)
let asyncPathResult = Box<String>()
Task {
    for await path in asyncPathMonitor {
        asyncPathResult.set(pathName(path.status))
        asyncPathMonitor.cancel()
        asyncPathReady.signal()
        break
    }
}
let gotAsyncPath = wait(asyncPathReady)
print("async blocked path: \(gotAsyncPath ? (asyncPathResult.value ?? "unknown") : "timeout")")

let queue = DispatchQueue(label: "finch.network.tcp")
let listener = try! NWListener(using: .tcp, on: .any)
let listenerReady = DispatchSemaphore(value: 0)
let tcpFinished = DispatchSemaphore(value: 0)
let tcpResult = Box<String>()
listener.stateUpdateHandler = { state in
    if case .ready = state { listenerReady.signal() }
}
listener.newConnectionHandler = { connection in
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                tcpResult.set(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                tcpFinished.signal()
            }
        }
    }
    connection.start(queue: queue)
}
listener.start(queue: queue)
let listenerStarted = wait(listenerReady)
let clientReady = DispatchSemaphore(value: 0)
let sendFinished = DispatchSemaphore(value: 0)
let sendError = Box<String>()
let client = NWConnection(host: "127.0.0.1", port: listener.port ?? .any, using: .tcp)
client.stateUpdateHandler = { state in
    if case .ready = state { clientReady.signal() }
}
client.start(queue: queue)
let clientStarted = listenerStarted && wait(clientReady)
if clientStarted {
    client.send(content: Data("tcp".utf8), isComplete: true, completion: .contentProcessed { error in
        sendError.set(error.map { $0.debugDescription } ?? "")
        sendFinished.signal()
    })
}
let sentTCP = clientStarted && wait(sendFinished) && (sendError.value ?? "missing") == ""
let gotTCP = sentTCP && wait(tcpFinished)
let continuedSendFinished = DispatchSemaphore(value: 0)
let continuedSendError = Box<String>()
if sentTCP {
    client.send(content: Data("again".utf8), completion: .contentProcessed { error in
        continuedSendError.set(error.map { $0.debugDescription } ?? "")
        continuedSendFinished.signal()
    })
}
let continuedTCP = sentTCP && wait(continuedSendFinished) && (continuedSendError.value ?? "missing") == ""
print("listener: \(listenerStarted ? "ready" : "timeout")")
print("TCP echo: \(gotTCP ? (tcpResult.value ?? "") : "timeout")")
print("TCP remains open: \(continuedTCP ? "yes" : "no")")
client.cancel()
listener.cancel()

let (udpServer, udpPort, udpSource) = startUDPEchoServer()
let udp = NWConnection(host: "127.0.0.1", port: udpPort, using: .udp)
let udpReady = DispatchSemaphore(value: 0)
let udpReceived = DispatchSemaphore(value: 0)
let udpSent = DispatchSemaphore(value: 0)
let udpResult = Box<String>()
udp.stateUpdateHandler = { state in
    if case .ready = state { udpReady.signal() }
}
udp.start(queue: queue)
let startedUDP = wait(udpReady)
if startedUDP {
    udp.receiveMessage { data, _, _, _ in
        udpResult.set(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        udpReceived.signal()
    }
    udp.send(content: Data("udp".utf8), completion: .contentProcessed { _ in udpSent.signal() })
}
let sentUDP = startedUDP && wait(udpSent)
let gotUDP = sentUDP && wait(udpReceived)
print("UDP echo: \(gotUDP ? (udpResult.value ?? "") : "timeout")")
udp.cancel()
udpSource.cancel()
Darwin.close(udpServer)

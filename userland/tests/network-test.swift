// SPDX-License-Identifier: MIT OR Apache-2.0
// A deterministic Network.framework comparison: endpoint values, path monitor,
// a loopback TCP listener and a loopback UDP connection.
import Darwin
import Dispatch
import Foundation
import Network

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

let pathMonitor = NWPathMonitor()
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
    print("path: \(pathName(path.status)) IPv4=\(path.supportsIPv4)")
} else {
    print("path: timeout")
}

let asyncPathMonitor = NWPathMonitor()
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
print("async path: \(gotAsyncPath ? (asyncPathResult.value ?? "unknown") : "timeout")")

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

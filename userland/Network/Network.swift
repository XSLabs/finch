// SPDX-License-Identifier: MIT OR Apache-2.0
// The path snapshot and monitor used by Network.framework's Swift API.
import Darwin
import Dispatch
import Foundation
import SystemConfiguration

public struct NWInterface: Hashable, CustomDebugStringConvertible, Sendable {
    public enum InterfaceType: Hashable, Sendable {
        case other
        case wifi
        case cellular
        case wiredEthernet
        case loopback
    }

    public enum RadioType: Sendable {
        public enum WiFi: Sendable { case b, a, g, n, ac, ax }
        public enum Cellular: Sendable {
            public enum NewRadio5GVariant: Sendable { case sub6GHz, mmWave }
            case lte, dualConnectivity5G(NewRadio5GVariant), standalone5G(NewRadio5GVariant), wcdma, gsm, cdma, evdo
        }
        case wifi(WiFi)
        case cell(Cellular)
    }

    public let type: InterfaceType
    public let name: String
    public let index: Int

    init(name: String, type: InterfaceType) {
        self.name = name
        self.type = type
        index = Int(if_nametoindex(name))
    }

    public var debugDescription: String { "\(name) (\(type))" }
}

public struct NWPath: Equatable, CustomDebugStringConvertible, Sendable {
    public enum Status: Equatable, Hashable, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    public enum UnsatisfiedReason: Equatable, Hashable, Sendable {
        case notAvailable
        case cellularDenied
        case wifiDenied
        case localNetworkDenied
        case vpnInactive
    }

    public let status: Status
    public let availableInterfaces: [NWInterface]
    public let isExpensive: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool
    public let localEndpoint: NWEndpoint?
    public let remoteEndpoint: NWEndpoint?
    public var unsatisfiedReason: UnsatisfiedReason { .notAvailable }
    public var isConstrained: Bool { false }
    public var gateways: [NWEndpoint] { [] }

    private let activeTypes: Set<NWInterface.InterfaceType>

    init(status: Status, availableInterfaces: [NWInterface] = [], supportsIPv4: Bool = false,
         supportsIPv6: Bool = false, supportsDNS: Bool = false, localEndpoint: NWEndpoint? = nil,
         remoteEndpoint: NWEndpoint? = nil) {
        self.status = status
        self.availableInterfaces = availableInterfaces
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        isExpensive = availableInterfaces.contains { $0.type == .cellular }
        activeTypes = Set(availableInterfaces.map(\.type))
    }

    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
        activeTypes.contains(type)
    }

    public var debugDescription: String {
        status == .satisfied ? "satisfied" : (status == .requiresConnection ? "requiresConnection" : "unsatisfied")
    }

    public static func == (lhs: NWPath, rhs: NWPath) -> Bool {
        lhs.status == rhs.status && lhs.availableInterfaces == rhs.availableInterfaces &&
            lhs.supportsIPv4 == rhs.supportsIPv4 && lhs.supportsIPv6 == rhs.supportsIPv6 &&
            lhs.supportsDNS == rhs.supportsDNS && lhs.localEndpoint == rhs.localEndpoint &&
            lhs.remoteEndpoint == rhs.remoteEndpoint
    }

    static func current(localEndpoint: NWEndpoint? = nil, remoteEndpoint: NWEndpoint? = nil,
                        requiredType: NWInterface.InterfaceType? = nil,
                        prohibitedTypes: Set<NWInterface.InterfaceType> = []) -> NWPath {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return NWPath(status: .unsatisfied, localEndpoint: localEndpoint, remoteEndpoint: remoteEndpoint)
        }
        defer { freeifaddrs(list) }

        let knownTypes = networkInterfaceTypes()
        var addresses: [String: (type: NWInterface.InterfaceType, up: Bool, v4: Bool, v6: Bool)] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            let type = interfaceType(name, knownTypes: knownTypes)
            var current = addresses[name] ?? (type, false, false, false)
            current.up = current.up || flags & IFF_UP != 0
            current.v4 = current.v4 || family == AF_INET
            current.v6 = current.v6 || family == AF_INET6
            addresses[name] = current
        }

        let interfaces = addresses.compactMap { name, value -> NWInterface? in
            guard value.up, value.type != .loopback, !prohibitedTypes.contains(value.type),
                  requiredType == nil || requiredType == value.type else { return nil }
            return NWInterface(name: name, type: value.type)
        }.sorted { $0.index == $1.index ? $0.name < $1.name : $0.index < $1.index }

        let usableNames = Set(interfaces.map(\.name))
        let supportsIPv4 = addresses.contains { usableNames.contains($0.key) && $0.value.v4 }
        let supportsIPv6 = addresses.contains { usableNames.contains($0.key) && $0.value.v6 }
        let satisfied = !interfaces.isEmpty && (supportsIPv4 || supportsIPv6)
        return NWPath(status: satisfied ? .satisfied : .unsatisfied, availableInterfaces: interfaces,
                      supportsIPv4: supportsIPv4, supportsIPv6: supportsIPv6, supportsDNS: satisfied,
                      localEndpoint: localEndpoint, remoteEndpoint: remoteEndpoint)
    }
}

func networkInterfaceTypes() -> [String: NWInterface.InterfaceType] {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
    var types: [String: NWInterface.InterfaceType] = [:]
    for interface in interfaces {
        guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
              let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
        if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
            types[name] = .wifi
        } else if CFEqual(type, kSCNetworkInterfaceTypeWWAN) {
            types[name] = .cellular
        } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) ||
                  CFEqual(type, kSCNetworkInterfaceTypeBond) ||
                  CFEqual(type, kSCNetworkInterfaceTypeVLAN) ||
                  CFEqual(type, kSCNetworkInterfaceTypeFireWire) || String(describing: type) == "Bridge" {
            types[name] = .wiredEthernet
        }
    }
    return types
}

func interfaceType(_ name: String, knownTypes: [String: NWInterface.InterfaceType] = networkInterfaceTypes()) -> NWInterface.InterfaceType {
    if let known = knownTypes[name] { return known }
    if name.hasPrefix("lo") { return .loopback }
    if name.hasPrefix("pdp_ip") { return .cellular }
    if name.hasPrefix("awdl") || name.hasPrefix("wl") || name.hasPrefix("wlan") { return .wifi }
    return .other
}

@_objcRuntimeName(_TtC7Network14_NWPathMonitor)
final public class NWPathMonitor: @unchecked Sendable, CustomDebugStringConvertible, AsyncSequence {
    public typealias Element = NWPath
    public typealias AsyncIterator = Iterator

    private let lock = NSLock()
    private var path = NWPath.current()
    private var handler: (@Sendable (NWPath) -> Void)?
    private var _queue: DispatchQueue?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var cancelled = false
    private let requiredType: NWInterface.InterfaceType?
    private let prohibitedTypes: Set<NWInterface.InterfaceType>
    private var continuations: [AsyncStream<NWPath>.Continuation] = []

    public init() {
        requiredType = nil
        prohibitedTypes = []
    }

    public init(requiredInterfaceType: NWInterface.InterfaceType) {
        requiredType = requiredInterfaceType
        prohibitedTypes = []
    }

    public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {
        requiredType = nil
        prohibitedTypes = Set(prohibitedInterfaceTypes)
    }

    final public var currentPath: NWPath {
        get { lock.withLock { path } }
        @available(macOS, introduced: 10.14, deprecated: 14.0, message: "setting currentPath not supported")
        set { }
    }

    @preconcurrency
    final public var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    final public var queue: DispatchQueue? { lock.withLock { _queue } }

    /// Delivers an initial path and checks for interface changes while the monitor is active.
    final public func start(queue: DispatchQueue) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started && !cancelled else { return false }
            started = true
            _queue = queue
            return true
        }
        guard shouldStart else { return }

        let first = readPath()
        lock.withLock { path = first }
        deliver(first, on: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.readPath()
            let changed = self.lock.withLock { () -> Bool in
                guard !self.cancelled else { return false }
                defer { self.path = now }
                return self.path != now
            }
            if changed { self.deliver(now, on: queue) }
        }
        lock.withLock {
            if cancelled { timer.cancel() } else { self.timer = timer }
        }
        timer.resume()
    }

    final public func cancel() {
        let (timer, continuations) = lock.withLock { () -> (DispatchSourceTimer?, [AsyncStream<NWPath>.Continuation]) in
            guard !cancelled else { return (nil, []) }
            cancelled = true
            let timer = self.timer
            self.timer = nil
            let continuations = self.continuations
            self.continuations.removeAll()
            return (timer, continuations)
        }
        timer?.cancel()
        continuations.forEach { $0.finish() }
    }

    public var debugDescription: String { "NWPathMonitor(\(currentPath.debugDescription))" }

    public struct Iterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<NWPath>.Iterator
        fileprivate init(_ iterator: AsyncStream<NWPath>.Iterator) { self.iterator = iterator }
        public mutating func next() async -> NWPath? { await iterator.next() }
    }

    public func makeAsyncIterator() -> Iterator {
        let stream = AsyncStream<NWPath> { continuation in
            let alreadyCancelled = lock.withLock { () -> Bool in
                if cancelled { return true }
                continuations.append(continuation)
                return false
            }
            if alreadyCancelled { continuation.finish() }
        }
        if queue == nil { start(queue: DispatchQueue.global(qos: .default)) }
        return Iterator(stream.makeAsyncIterator())
    }

    private func readPath() -> NWPath {
        NWPath.current(requiredType: requiredType, prohibitedTypes: prohibitedTypes)
    }

    private func deliver(_ path: NWPath, on queue: DispatchQueue) {
        let handler = lock.withLock { self.handler }
        let continuations = lock.withLock { self.continuations }
        queue.async {
            handler?(path)
            continuations.forEach { _ = $0.yield(path) }
        }
    }

    deinit { cancel() }
}

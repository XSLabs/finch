// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Network.framework, Finch's, to Apple's ABI: so far the path monitor apps use to know
// whether the network is there. A path is satisfied while any interface other than
// loopback is up with an address; the monitor checks when it starts and again when the
// system's network configuration changes (the interfaces' addresses), and tells its
// handler on its queue.

import Darwin
import Dispatch
import Foundation

public struct NWPath: Equatable, CustomDebugStringConvertible, Sendable {
    public enum Status: Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    public enum UnsatisfiedReason: Sendable {
        case notAvailable
        case cellularDenied
        case wifiDenied
        case localNetworkDenied
        case vpnInactive
    }

    public let status: Status
    public var unsatisfiedReason: UnsatisfiedReason { status == .satisfied ? .notAvailable : .notAvailable }
    public var isExpensive: Bool { false }
    public var isConstrained: Bool { false }
    public var supportsIPv4: Bool { status == .satisfied }
    public var supportsIPv6: Bool { false }
    public var supportsDNS: Bool { status == .satisfied }

    public var debugDescription: String { status == .satisfied ? "satisfied" : "unsatisfied" }

    public static func == (lhs: NWPath, rhs: NWPath) -> Bool { lhs.status == rhs.status }

    /// The path now: satisfied when an interface besides loopback is up with an address.
    static func current() -> NWPath {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return NWPath(status: .unsatisfied) }
        defer { freeifaddrs(list) }
        var up = false
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = entry.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                up = true
                break
            }
        }
        return NWPath(status: up ? .satisfied : .unsatisfied)
    }
}

@_objcRuntimeName(_TtC7Network14_NWPathMonitor)
final public class NWPathMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var path = NWPath.current()
    private var handler: (@Sendable (_ newPath: NWPath) -> Void)?
    private var _queue: DispatchQueue?
    private var timer: DispatchSourceTimer?

    public init() {}
    public init(requiredInterfaceType: NWInterface.InterfaceType) {}
    public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {}

    final public var currentPath: NWPath {
        get { lock.withLock { path } }
        set {}
    }

    @preconcurrency
    final public var pathUpdateHandler: (@Sendable (_ newPath: NWPath) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    final public var queue: DispatchQueue? { lock.withLock { _queue } }

    /// Tells the handler the path now, then whenever it changes (checked every few seconds).
    final public func start(queue: DispatchQueue) {
        lock.withLock { _queue = queue }
        let first = NWPath.current()
        lock.withLock { path = first }
        queue.async { [weak self] in self?.pathUpdateHandler?(first) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = NWPath.current()
            let changed = self.lock.withLock { () -> Bool in
                defer { self.path = now }
                return self.path != now
            }
            if changed { self.pathUpdateHandler?(now) }
        }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    final public func cancel() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        timer?.cancel()
    }
}

public struct NWInterface: Hashable, Sendable {
    public enum InterfaceType: Sendable {
        case other
        case wifi
        case cellular
        case wiredEthernet
        case loopback
    }

    public let type: InterfaceType
    public let name: String
}

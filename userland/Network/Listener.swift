// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Dispatch
import Foundation
import Security

@_silgen_name("finch_network_dns_register")
private func finchDNSRegister(_ name: UnsafePointer<CChar>?, _ type: UnsafePointer<CChar>,
                              _ domain: UnsafePointer<CChar>?, _ noAutoRename: Bool, _ port: UInt16,
                              _ txt: UnsafeRawPointer?, _ txtLength: UInt16,
                              _ callback: DNSRegisterCallback, _ client: UnsafeMutableRawPointer?,
                              _ error: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?
@_silgen_name("finch_network_dns_fd")
private func finchDNSFileDescriptor(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_process")
private func finchDNSProcess(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_cancel")
private func finchDNSCancel(_ service: UnsafeMutableRawPointer?)

private typealias DNSRegisterCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

private let networkListenerRegisterCallback: DNSRegisterCallback = { context, flags, error, name, type, domain in
    guard let context else { return }
    Unmanaged<NWListener>.fromOpaque(context).takeUnretainedValue().receivedRegistration(
        flags: flags, error: error, name: name.map(String.init(cString:)),
        type: type.map(String.init(cString:)), domain: domain.map(String.init(cString:)))
}

@_objcRuntimeName(_TtC7Network11_NWListener)
final public class NWListener: CustomDebugStringConvertible, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public struct Service: Equatable, CustomDebugStringConvertible, Sendable {
        public let name: String?
        public let type: String
        public let domain: String?
        public let txtRecord: Data?
        public var noAutoRename = false

        public init(name: String? = nil, type: String, domain: String? = nil, txtRecord: Data? = nil) {
            self.name = name
            self.type = type
            self.domain = domain
            self.txtRecord = txtRecord
        }

        public var debugDescription: String { "\(name ?? "").\(type)\(domain ?? "local.")" }
    }

    public enum ServiceRegistrationChange: Sendable {
        case add(NWEndpoint)
        case remove(NWEndpoint)
    }

    private let lock = NSLock()
    public final let parameters: NWParameters
    private let requestedPort: NWEndpoint.Port
    private var currentState: State = .setup
    private var stateHandler: (@Sendable (State) -> Void)?
    private var connectionHandler: (@Sendable (NWConnection) -> Void)?
    private var groupHandler: (@Sendable (NWConnectionGroup) -> Void)?
    private var registrationHandler: (@Sendable (ServiceRegistrationChange) -> Void)?
    private var _service: Service?
    private var workQueue: DispatchQueue?
    private var descriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var dnsService: UnsafeMutableRawPointer?
    private var dnsReadSource: DispatchSourceRead?
    private var registeredEndpoint: NWEndpoint?
    private var boundPort: NWEndpoint.Port?
    private var connectionLimit = Int.max
    private var acceptSuspended = false

    public static let InfiniteConnectionLimit = Int.max

    public init(using parameters: NWParameters, on port: NWEndpoint.Port = .any) throws {
        guard parameters.transport == .tcp else { throw NWError.posix(POSIXErrorCode(rawValue: EPROTOTYPE) ?? .EIO) }
        guard !parameters.hasUnsupportedRoutingPolicy else { throw networkError(EOPNOTSUPP) }
        guard parameters.tlsOptions == nil else { throw NWError.tls(errSSLBadConfiguration) }
        self.parameters = parameters
        requestedPort = port
    }

    public convenience init(service: Service, using parameters: NWParameters) throws {
        try self.init(using: parameters, on: .any)
        self.service = service
    }

    final public var state: State { lock.withLock { currentState } }

    @preconcurrency
    final public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    @preconcurrency
    final public var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { lock.withLock { connectionHandler } }
        set { lock.withLock { connectionHandler = newValue } }
    }

    @preconcurrency
    final public var newConnectionGroupHandler: (@Sendable (NWConnectionGroup) -> Void)? {
        get { lock.withLock { groupHandler } }
        set { lock.withLock { groupHandler = newValue } }
    }

    @preconcurrency
    final public var serviceRegistrationUpdateHandler: (@Sendable (ServiceRegistrationChange) -> Void)? {
        get { lock.withLock { registrationHandler } }
        set { lock.withLock { registrationHandler = newValue } }
    }

    final public var service: Service? {
        get { lock.withLock { _service } }
        set { lock.withLock { _service = newValue } }
    }

    final public var port: NWEndpoint.Port? { lock.withLock { boundPort } }
    final public var queue: DispatchQueue? { lock.withLock { workQueue } }
    final public var newConnectionLimit: Int {
        get { lock.withLock { connectionLimit } }
        set {
            let source = lock.withLock { () -> DispatchSourceRead? in
                connectionLimit = max(0, newValue)
                guard connectionLimit > 0, acceptSuspended else { return nil }
                acceptSuspended = false
                return acceptSource
            }
            source?.resume()
        }
    }

    final public func start(queue: DispatchQueue) {
        let shouldStart = lock.withLock { () -> Bool in
            guard currentState == .setup, workQueue == nil else { return false }
            workQueue = queue
            return true
        }
        guard shouldStart else { return }
        transition(to: .waiting(NWError.posix(.EINPROGRESS)))
        queue.async { [weak self] in self?.openListener() }
    }

    final public func cancel() {
        let (fd, source, sourceWasSuspended, dnsService, dnsSource) = lock.withLock { () -> (Int32, DispatchSourceRead?, Bool, UnsafeMutableRawPointer?, DispatchSourceRead?) in
            let fd = descriptor
            descriptor = -1
            let source = acceptSource
            acceptSource = nil
            let sourceWasSuspended = acceptSuspended
            acceptSuspended = false
            let dnsService = self.dnsService
            let dnsSource = dnsReadSource
            self.dnsService = nil
            dnsReadSource = nil
            return (fd, source, sourceWasSuspended, dnsService, dnsSource)
        }
        if sourceWasSuspended { source?.resume() }
        source?.cancel()
        dnsSource?.cancel()
        if dnsSource == nil { finchDNSCancel(dnsService) }
        if fd >= 0 { Darwin.close(fd) }
        let removal = lock.withLock { () -> (NWEndpoint, (@Sendable (ServiceRegistrationChange) -> Void)?, DispatchQueue?)? in
            defer { registeredEndpoint = nil }
            guard let endpoint = registeredEndpoint else { return nil }
            return (endpoint, registrationHandler, workQueue)
        }
        if let removal, let handler = removal.1, let queue = removal.2 {
            queue.async { handler(.remove(removal.0)) }
        }
        transition(to: .cancelled)
    }

    public var debugDescription: String { "NWListener(\(port?.rawValue ?? 0), \(listenerStateName(state)))" }

    private func openListener() {
        var chosenError: Int32 = EADDRNOTAVAIL
        for address in listenerAddresses() {
            let protocolType = address.family == AF_UNIX ? 0 : IPPROTO_TCP
            let fd = socket(address.family, SOCK_STREAM, protocolType)
            guard fd >= 0 else { chosenError = errno; continue }
            configureSocket(fd, parameters: parameters, reuse: true, family: address.family)
            let result = withUnsafePointer(to: address.storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, address.length) }
            }
            guard result == 0, listen(fd, SOMAXCONN) == 0 else {
                chosenError = errno
                Darwin.close(fd)
                continue
            }
            setSocketNonblocking(fd)
            guard let local = socketEndpoint(fd, peer: false) else {
                chosenError = EADDRNOTAVAIL
                Darwin.close(fd)
                continue
            }
            let boundPort: NWEndpoint.Port?
            switch local {
            case let .hostPort(_, port): boundPort = port
            case .unix: boundPort = nil
            default:
                chosenError = EADDRNOTAVAIL
                Darwin.close(fd)
                continue
            }
            if service != nil && boundPort == nil {
                Darwin.close(fd)
                transition(to: .failed(networkError(EOPNOTSUPP)))
                return
            }
            let accepted = lock.withLock { () -> Bool in
                guard currentState != .cancelled else { return false }
                descriptor = fd
                self.boundPort = boundPort
                return true
            }
            guard accepted else { Darwin.close(fd); return }
            transition(to: .ready)
            beginAccepting(fd)
            beginServiceRegistration()
            return
        }
        transition(to: .failed(networkError(chosenError)))
    }

    private func listenerAddresses() -> [NetworkSocketAddress] {
        if let local = parameters.requiredLocalEndpoint {
            return networkAddresses(for: local, socketType: Int32(SOCK_STREAM))
        }
        let endpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: requestedPort)
        let addresses = networkAddresses(for: endpoint, socketType: Int32(SOCK_STREAM))
        return addresses.isEmpty ? networkAddresses(for: .hostPort(host: "::", port: requestedPort), socketType: Int32(SOCK_STREAM)) : addresses
    }

    private func beginAccepting(_ fd: Int32) {
        guard let queue else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        acceptSource = source
        source.resume()
    }

    private func beginServiceRegistration() {
        guard state == .ready, let service, let queue, let port else { return }
        let txt = service.txtRecord ?? Data()
        guard txt.count <= Int(UInt16.max) else { transition(to: .failed(networkError(EINVAL))); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var error: Int32 = 0
        let handle = service.type.withCString { typePointer in
            let register: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { namePointer, domainPointer in
                txt.withUnsafeBytes { bytes in
                    finchDNSRegister(namePointer, typePointer, domainPointer, service.noAutoRename,
                                     port.rawValue, bytes.baseAddress, UInt16(txt.count),
                                     networkListenerRegisterCallback, context, &error)
                }
            }
            if let name = service.name, let domain = service.domain {
                return name.withCString { namePointer in domain.withCString { register(namePointer, $0) } }
            }
            if let name = service.name { return name.withCString { register($0, nil) } }
            if let domain = service.domain { return domain.withCString { register(nil, $0) } }
            return register(nil, nil)
        }
        guard let handle else { transition(to: .failed(.dns(error))); return }
        let fd = finchDNSFileDescriptor(handle)
        guard fd >= 0 else {
            finchDNSCancel(handle)
            transition(to: .failed(.dns(-65540)))
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let status = finchDNSProcess(handle)
            if status != 0 { self?.transition(to: .failed(.dns(status))) }
        }
        source.setCancelHandler { finchDNSCancel(handle) }
        let installed = lock.withLock { () -> Bool in
            guard currentState != .cancelled else { return false }
            dnsService = handle
            dnsReadSource = source
            return true
        }
        guard installed else { source.resume(); source.cancel(); return }
        source.resume()
    }

    fileprivate func receivedRegistration(flags: UInt32, error: Int32, name: String?, type: String?, domain: String?) {
        guard state != .cancelled else { return }
        guard error == 0, let name, let type, let domain else {
            if error != 0 { transition(to: .failed(.dns(error))) }
            return
        }
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let handler = lock.withLock { () -> (@Sendable (ServiceRegistrationChange) -> Void)? in
            registeredEndpoint = endpoint
            return registrationHandler
        }
        if flags & 2 != 0 { handler?(.add(endpoint)) }
    }

    private func acceptConnections() {
        let (fd, source, canAccept) = lock.withLock { () -> (Int32, DispatchSourceRead?, Bool) in
            guard descriptor >= 0 else { return (-1, nil, false) }
            guard connectionLimit > 0 else {
                if !acceptSuspended, let acceptSource {
                    acceptSuspended = true
                    acceptSource.suspend()
                }
                return (descriptor, acceptSource, false)
            }
            return (descriptor, acceptSource, true)
        }
        guard fd >= 0, canAccept else { return }
        while true {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
            }
            if accepted < 0 {
                if errno == EINTR { continue }
                return
            }
            if parameters.acceptLocalOnly && !isOnLocalLink(peer) {
                Darwin.close(accepted)
                continue
            }
            let (allowed, shouldSuspend) = lock.withLock { () -> (Bool, Bool) in
                guard connectionLimit > 0 else {
                    let shouldSuspend = !acceptSuspended
                    if shouldSuspend { acceptSuspended = true }
                    return (false, shouldSuspend)
                }
                if connectionLimit != Self.InfiniteConnectionLimit { connectionLimit -= 1 }
                let shouldSuspend = connectionLimit == 0 && !acceptSuspended
                if shouldSuspend { acceptSuspended = true }
                return (true, shouldSuspend)
            }
            if shouldSuspend { source?.suspend() }
            guard allowed else {
                Darwin.close(accepted)
                if shouldSuspend { return }
                continue
            }
            setSocketNonblocking(accepted)
            configureSocket(accepted, parameters: parameters, family: Int32(peer.ss_family))
            let endpoint = networkEndpoint(for: peer) ?? .unix(path: "")
            let connection = NWConnection(acceptedSocket: accepted, endpoint: endpoint, using: parameters.copy())
            lock.withLock { connectionHandler }?(connection)
            if shouldSuspend { return }
        }
    }

    private func transition(to state: State) {
        let (handler, queue) = lock.withLock { () -> ((@Sendable (State) -> Void)?, DispatchQueue?) in
            guard currentState != state else { return (nil, nil) }
            currentState = state
            return (stateHandler, workQueue)
        }
        if let handler, let queue { queue.async { handler(state) } }
    }

    deinit { cancel() }
}

private func listenerStateName(_ state: NWListener.State) -> String {
    switch state {
    case .setup: return "setup"
    case .waiting: return "waiting"
    case .ready: return "ready"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    }
}

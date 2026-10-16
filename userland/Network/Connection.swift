// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Dispatch
import Foundation
import Security

private typealias TLSReadCallback = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> Int32
private typealias TLSWriteCallback = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeMutablePointer<Int>) -> Int32

@_silgen_name("SSLCreateContext")
private func finchSSLCreateContext(_ allocator: CFAllocator?, _ side: Int32, _ type: Int32) -> UnsafeMutableRawPointer?
@_silgen_name("SSLSetIOFuncs")
private func finchSSLSetIOFuncs(_ context: UnsafeMutableRawPointer, _ read: TLSReadCallback, _ write: TLSWriteCallback) -> Int32
@_silgen_name("SSLSetConnection")
private func finchSSLSetConnection(_ context: UnsafeMutableRawPointer, _ connection: UnsafeRawPointer?) -> Int32
@_silgen_name("SSLSetPeerDomainName")
private func finchSSLSetPeerDomainName(_ context: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>, _ length: Int) -> Int32
@_silgen_name("SSLHandshake")
private func finchSSLHandshake(_ context: UnsafeMutableRawPointer) -> Int32
@_silgen_name("SSLWrite")
private func finchSSLWrite(_ context: UnsafeMutableRawPointer, _ data: UnsafeRawPointer?, _ length: Int, _ processed: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("SSLRead")
private func finchSSLRead(_ context: UnsafeMutableRawPointer, _ data: UnsafeMutableRawPointer, _ length: Int, _ processed: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("SSLClose")
private func finchSSLClose(_ context: UnsafeMutableRawPointer) -> Int32

private let networkTLSRead: TLSReadCallback = { connection, data, dataLength in
    let fd = Int32(Int(bitPattern: connection))
    var count: Int
    repeat { count = Darwin.recv(fd, data, dataLength.pointee, 0) } while count < 0 && errno == EINTR
    if count >= 0 {
        dataLength.pointee = count
        return count == 0 ? errSSLClosedGraceful : noErr
    }
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? errSSLWouldBlock : errSSLClosedAbort
}

private let networkTLSWrite: TLSWriteCallback = { connection, data, dataLength in
    let fd = Int32(Int(bitPattern: connection))
    var count: Int
    repeat { count = Darwin.send(fd, data, dataLength.pointee, 0) } while count < 0 && errno == EINTR
    if count >= 0 {
        dataLength.pointee = count
        return noErr
    }
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? errSSLWouldBlock : errSSLClosedAbort
}

@_objcRuntimeName(_TtC7Network13_NWConnection)
final public class NWConnection: CustomDebugStringConvertible, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    @_objcRuntimeName(_TtCC7Network13_NWConnection14ContentContext)
    public class ContentContext: @unchecked Sendable {
        public let identifier: String
        public let expirationMilliseconds: UInt64
        public let relativePriority: Double
        public let antecedent: ContentContext?
        public let isFinal: Bool
        public let protocolMetadata: [NWProtocolMetadata]

        public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5,
                    isFinal: Bool = false, antecedent: ContentContext? = nil,
                    metadata: [NWProtocolMetadata]? = []) {
            self.identifier = identifier
            expirationMilliseconds = expiration
            relativePriority = priority
            self.antecedent = antecedent
            self.isFinal = isFinal
            protocolMetadata = metadata ?? []
        }

        public func protocolMetadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? {
            protocolMetadata.first { $0.definition == definition }
        }

        public static let defaultMessage = ContentContext(identifier: "message")
        public static let finalMessage = ContentContext(identifier: "finalMessage", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "stream", isFinal: true)
    }

    public enum SendCompletion {
        case contentProcessed((NWError?) -> Void)
        case idempotent

        @_disfavoredOverload
        public static func contentProcessed(_ handler: @escaping @Sendable (NWError?) -> Void) -> SendCompletion {
            let legacyHandler: (NWError?) -> Void = handler
            return .contentProcessed(legacyHandler)
        }
    }

    private struct PendingReceive {
        let minimum: Int
        let maximum: Int
        let completion: (Data?, ContentContext?, Bool, NWError?) -> Void
        var data = Data()
    }

    private let lock = NSLock()
    public final let endpoint: NWEndpoint
    public final let parameters: NWParameters
    private var currentState: State = .setup
    private var stateHandler: (@Sendable (State) -> Void)?
    private var pathHandler: (@Sendable (NWPath) -> Void)?
    private var viabilityHandler: (@Sendable (Bool) -> Void)?
    private var betterPathHandler: (@Sendable (Bool) -> Void)?
    private var workQueue: DispatchQueue?
    private var descriptor: Int32 = -1
    private var tlsContext: UnsafeMutableRawPointer?
    private var readSource: DispatchSourceRead?
    private var pendingReceive: PendingReceive?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var sentBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    public init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        self.endpoint = endpoint
        self.parameters = parameters
    }

    convenience public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        self.init(to: .hostPort(host: host, port: port), using: parameters)
    }

    init(acceptedSocket descriptor: Int32, endpoint: NWEndpoint, using parameters: NWParameters) {
        self.endpoint = endpoint
        self.parameters = parameters
        self.descriptor = descriptor
        setSocketNonblocking(descriptor)
        configureSocket(descriptor, parameters: parameters, family: socketFamily(for: endpoint))
    }

    final public var state: State { lock.withLock { currentState } }

    @preconcurrency
    final public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    final public var currentPath: NWPath? {
        let descriptor = lock.withLock { self.descriptor }
        guard descriptor >= 0 else { return nil }
        return NWPath.current(localEndpoint: socketEndpoint(descriptor, peer: false),
                              remoteEndpoint: socketEndpoint(descriptor, peer: true))
    }

    @preconcurrency
    final public var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { lock.withLock { pathHandler } }
        set { lock.withLock { pathHandler = newValue } }
    }

    @preconcurrency
    final public var viabilityUpdateHandler: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { viabilityHandler } }
        set { lock.withLock { viabilityHandler = newValue } }
    }

    @preconcurrency
    final public var betterPathUpdateHandler: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { betterPathHandler } }
        set { lock.withLock { betterPathHandler = newValue } }
    }

    final public var maximumDatagramSize: Int {
        guard parameters.transport == .udp else { return 0 }
        if case .hostPort(host: .ipv6, port: _) = endpoint { return 65_527 }
        return 65_507
    }
    final public var queue: DispatchQueue? { lock.withLock { workQueue } }

    final public func start(queue: DispatchQueue) {
        let started = lock.withLock { () -> Bool in
            guard currentState == .setup, workQueue == nil else { return false }
            workQueue = queue
            return true
        }
        guard started else { return }
        transition(to: .preparing)
        queue.async { [weak self] in self?.establish() }
    }

    final public func cancel() { close(with: .cancelled) }
    final public func forceCancel() { cancel() }
    final public func cancelCurrentEndpoint() { cancel() }

    final public func restart() {
        let (queue, fd, source) = lock.withLock { () -> (DispatchQueue?, Int32, DispatchSourceRead?) in
            guard currentState == .cancelled || isFailed(currentState) else { return (nil, -1, nil) }
            let queue = workQueue
            let fd = descriptor
            let source = readSource
            descriptor = -1
            readSource = nil
            currentState = .setup
            workQueue = nil
            startedAt = ProcessInfo.processInfo.systemUptime
            return (queue, fd, source)
        }
        source?.cancel()
        if fd >= 0 { Darwin.close(fd) }
        if let queue { start(queue: queue) }
    }

    final public func batch(_ block: () -> Void) { block() }

    final public func send(content: Data?, contentContext: ContentContext = .defaultMessage,
                           isComplete: Bool = true, completion: SendCompletion) {
        guard let queue = self.queue else {
            deliverSend(completion, error: networkError(ENOTCONN))
            return
        }
        queue.async { [weak self] in
            guard let self, self.state == .ready else {
                self?.deliverSend(completion, error: networkError(ENOTCONN))
                return
            }
            let descriptor = self.lock.withLock { self.descriptor }
            guard descriptor >= 0 else {
                self.deliverSend(completion, error: networkError(ENOTCONN))
                return
            }
            let bytes = content ?? Data()
            var failure: NWError?
            let tlsContext = self.lock.withLock { self.tlsContext }
            let sent = bytes.withUnsafeBytes { buffer -> Int in
                var offset = 0
                repeat {
                    let base = buffer.baseAddress?.advanced(by: offset)
                    let count: Int
                    if let tlsContext {
                        var processed = 0
                        let status = finchSSLWrite(tlsContext, base, buffer.count - offset, &processed)
                        guard status == noErr else {
                            failure = .tls(status)
                            return offset
                        }
                        count = processed
                    } else {
                        count = Darwin.send(descriptor, base, buffer.count - offset, 0)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        failure = networkError()
                        return offset
                    }
                    if count == 0 && buffer.count > 0 {
                        failure = networkError(EPIPE)
                        return offset
                    }
                    offset += count
                    if self.parameters.transport == .udp { return offset }
                } while offset < buffer.count
                return offset
            }
            self.lock.withLock { self.sentBytes += UInt64(max(sent, 0)) }
            if isComplete && contentContext.isFinal && self.parameters.transport == .tcp {
                if let tlsContext { _ = finchSSLClose(tlsContext) }
                else { _ = shutdown(descriptor, SHUT_WR) }
            }
            self.deliverSend(completion, error: failure)
        }
    }

    private func enqueueReceive(minimumIncompleteLength: Int, maximumLength: Int,
                                completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        guard minimumIncompleteLength > 0, maximumLength >= minimumIncompleteLength else {
            completion(nil, nil, false, networkError(EINVAL))
            return
        }
        guard let queue = self.queue else {
            completion(nil, nil, false, networkError(ENOTCONN))
            return
        }
        queue.async { [weak self] in
            guard let self, self.state == .ready else {
                completion(nil, nil, false, networkError(ENOTCONN))
                return
            }
            let descriptor = self.lock.withLock { self.descriptor }
            guard descriptor >= 0, self.pendingReceive == nil else {
                completion(nil, nil, false, networkError(descriptor < 0 ? ENOTCONN : EALREADY))
                return
            }
            self.pendingReceive = PendingReceive(minimum: minimumIncompleteLength, maximum: maximumLength,
                                                 completion: completion)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readPending() }
            self.readSource = source
            source.resume()
        }
    }

    final public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                              completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        enqueueReceive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength,
                       completion: completion)
    }

    @_disfavoredOverload
    final public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                              completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        enqueueReceive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength,
                       completion: completion)
    }

    final public func receiveMessage(completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: maximumDatagramSize > 0 ? maximumDatagramSize : 65_536,
                completion: completion)
    }

    @_disfavoredOverload
    final public func receiveMessage(completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: maximumDatagramSize > 0 ? maximumDatagramSize : 65_536,
                completion: completion)
    }

    final public func receiveDiscontiguous(minimumIncompleteLength: Int, maximumLength: Int,
                                           completion: @escaping (DispatchData?, ContentContext?, Bool, NWError?) -> Void) {
        receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, context, complete, error in
            let chunks: DispatchData? = data.map { value in value.withUnsafeBytes { DispatchData(bytes: $0) } }
            completion(chunks, context, complete, error)
        }
    }

    @_disfavoredOverload
    final public func receiveDiscontiguous(minimumIncompleteLength: Int, maximumLength: Int,
                                           completion: @escaping @Sendable (DispatchData?, ContentContext?, Bool, NWError?) -> Void) {
        receiveDiscontiguous(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, context, complete, error in
            completion(data, context, complete, error)
        }
    }

    final public func receiveMessageDiscontiguous(completion: @escaping (DispatchData?, ContentContext?, Bool, NWError?) -> Void) {
        receiveDiscontiguous(minimumIncompleteLength: 1, maximumLength: maximumDatagramSize > 0 ? maximumDatagramSize : 65_536,
                             completion: completion)
    }

    @_disfavoredOverload
    final public func receiveMessageDiscontiguous(completion: @escaping @Sendable (DispatchData?, ContentContext?, Bool, NWError?) -> Void) {
        receiveMessageDiscontiguous { data, context, complete, error in
            completion(data, context, complete, error)
        }
    }

    final public func metadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? { nil }

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage,
                     isComplete: Bool = true) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: content, contentContext: contentContext, isComplete: isComplete,
                 completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public func receive(minimumIncompleteLength: Int = 1, maximumLength: Int) async throws -> (Data?, ContentContext?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, ContentContext?, Bool), Error>) in
            receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, context, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data, context, complete)) }
            }
        }
    }

    private func deliverEstablishmentReport(queue: DispatchQueue,
                                            completion: @escaping (EstablishmentReport?) -> Void) {
        let report = lock.withLock { () -> EstablishmentReport? in
            guard currentState == .ready else { return nil }
            return EstablishmentReport(duration: ProcessInfo.processInfo.systemUptime - startedAt,
                                       attemptStartedAfterInterval: 0, previousAttemptCount: 0,
                                       usedProxy: false, proxyConfigured: false, proxyEndpoint: nil,
                                       resolutions: [], handshakes: [])
        }
        queue.async { completion(report) }
    }

    public func requestEstablishmentReport(queue: DispatchQueue,
                                           completion: @escaping (EstablishmentReport?) -> Void) {
        deliverEstablishmentReport(queue: queue, completion: completion)
    }

    @_disfavoredOverload
    public func requestEstablishmentReport(queue: DispatchQueue,
                                           completion: @escaping @Sendable (EstablishmentReport?) -> Void) {
        deliverEstablishmentReport(queue: queue, completion: completion)
    }

    public func startDataTransferReport() -> PendingDataTransferReport { PendingDataTransferReport(connection: self) }

    public var debugDescription: String { "NWConnection(\(endpoint.debugDescription), \(stateName(state)))" }

    private func establish() {
        guard !parameters.hasUnsupportedRoutingPolicy else {
            transition(to: .failed(networkError(EOPNOTSUPP)))
            return
        }
        if lock.withLock({ descriptor >= 0 }) {
            transition(to: .ready)
            notifyPath()
            return
        }
        let type = parameters.transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        if parameters.tlsOptions != nil && parameters.transport != .tcp {
            transition(to: .failed(.tls(errSSLBadConfiguration)))
            return
        }
        let addresses = networkAddresses(for: endpoint, socketType: Int32(type))
        guard !addresses.isEmpty else { transition(to: .failed(networkError(EHOSTUNREACH))); return }

        var lastError: Int32 = EHOSTUNREACH
        for address in addresses {
            let protocolType = address.family == AF_UNIX ? 0 : (parameters.transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP)
            let fd = socket(address.family, type, protocolType)
            guard fd >= 0 else { lastError = errno; continue }
            configureSocket(fd, parameters: parameters, family: address.family)
            guard bindLocal(fd, family: address.family) else {
                lastError = errno
                Darwin.close(fd)
                continue
            }
            let connected = withUnsafePointer(to: address.storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, address.length)
                }
            }
            guard connected == 0 else {
                lastError = errno
                Darwin.close(fd)
                continue
            }
            var securedContext: UnsafeMutableRawPointer?
            if parameters.tlsOptions != nil {
                guard let serverName = tlsServerName(for: endpoint) else {
                    transition(to: .failed(.tls(errSSLBadConfiguration)))
                    Darwin.close(fd)
                    return
                }
                let (context, status) = makeTLSContext(for: fd, serverName: serverName)
                guard status == noErr, let context else {
                    transition(to: .failed(.tls(status)))
                    Darwin.close(fd)
                    return
                }
                securedContext = context
            }
            setSocketNonblocking(fd)
            let accepted = lock.withLock { () -> Bool in
                guard currentState != .cancelled else { return false }
                descriptor = fd
                tlsContext = securedContext
                return true
            }
            guard accepted else {
                if let securedContext { releaseTLSContext(securedContext) }
                Darwin.close(fd)
                return
            }
            transition(to: .ready)
            notifyPath()
            return
        }
        transition(to: .failed(networkError(lastError)))
    }

    private func bindLocal(_ fd: Int32, family: Int32) -> Bool {
        guard let endpoint = parameters.requiredLocalEndpoint else { return true }
        let addresses = networkAddresses(for: endpoint, socketType: parameters.transport == .tcp ? Int32(SOCK_STREAM) : Int32(SOCK_DGRAM))
        guard let address = addresses.first(where: { $0.family == family }) else { errno = EADDRNOTAVAIL; return false }
        return withUnsafePointer(to: address.storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, address.length) == 0 }
        }
    }

    private func readPending() {
        guard var pending = pendingReceive else { return }
        let fd = lock.withLock { descriptor }
        guard fd >= 0 else { finishReceive(data: pending.data, complete: false, error: networkError(ENOTCONN)); return }
        let remaining = max(1, pending.maximum - pending.data.count)
        var bytes = [UInt8](repeating: 0, count: remaining)
        let tlsContext = lock.withLock { self.tlsContext }
        var tlsStatus: OSStatus = noErr
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let tlsContext else { return Darwin.recv(fd, buffer.baseAddress, buffer.count, 0) }
            var processed = 0
            guard let base = buffer.baseAddress else { return 0 }
            tlsStatus = finchSSLRead(tlsContext, base, buffer.count, &processed)
            return processed
        }
        if tlsContext != nil && tlsStatus == errSSLWouldBlock { return }
        if tlsContext != nil && tlsStatus == errSSLClosedGraceful {
            finishReceive(data: pending.data, complete: true, error: nil)
            return
        }
        if tlsContext != nil && tlsStatus != noErr {
            finishReceive(data: pending.data, complete: false, error: .tls(tlsStatus))
            return
        }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
            finishReceive(data: pending.data, complete: false, error: networkError())
            return
        }
        if count == 0 {
            finishReceive(data: pending.data, complete: true, error: nil)
            return
        }
        pending.data.append(contentsOf: bytes.prefix(count))
        lock.withLock { receivedBytes += UInt64(count) }
        if parameters.transport == .udp || pending.data.count >= pending.minimum || pending.data.count >= pending.maximum {
            finishReceive(data: pending.data, complete: parameters.transport == .udp, error: nil)
        } else {
            pendingReceive = pending
        }
    }

    private func finishReceive(data: Data, complete: Bool, error: NWError?) {
        guard let pending = pendingReceive else { return }
        pendingReceive = nil
        readSource?.cancel()
        readSource = nil
        let content = data.isEmpty && complete && parameters.transport == .tcp ? nil : data
        pending.completion(content, ContentContext.defaultMessage, complete, error)
    }

    private func notifyPath() {
        guard let path = currentPath, let queue = self.queue else { return }
        let handler = lock.withLock { pathHandler }
        let viability = lock.withLock { viabilityHandler }
        queue.async {
            handler?(path)
            viability?(path.status == .satisfied)
        }
    }

    private func deliverSend(_ completion: SendCompletion, error: NWError?) {
        if case let .contentProcessed(handler) = completion { handler(error) }
    }

    private func transition(to state: State) {
        let (changed, handler, queue) = lock.withLock { () -> (Bool, (@Sendable (State) -> Void)?, DispatchQueue?) in
            guard currentState != state else { return (false, nil, nil) }
            currentState = state
            return (true, stateHandler, workQueue)
        }
        guard changed, let handler, let queue else { return }
        queue.async { handler(state) }
    }

    private func close(with state: State) {
        let (fd, source, tlsContext) = lock.withLock { () -> (Int32, DispatchSourceRead?, UnsafeMutableRawPointer?) in
            let fd = descriptor
            descriptor = -1
            let source = readSource
            readSource = nil
            let tlsContext = self.tlsContext
            self.tlsContext = nil
            return (fd, source, tlsContext)
        }
        source?.cancel()
        if let tlsContext {
            releaseTLSContext(tlsContext)
        }
        if fd >= 0 { Darwin.close(fd) }
        if let pending = pendingReceive {
            pendingReceive = nil
            pending.completion(nil, nil, false, state == .cancelled ? nil : networkError(ECANCELED))
        }
        transition(to: state)
    }

    deinit { close(with: .cancelled) }

    private func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

private func tlsServerName(for endpoint: NWEndpoint) -> String? {
    switch endpoint {
    case let .hostPort(host, _): return networkHostName(host)
    case let .url(url): return url.host
    case let .service(name, type, domain, interface):
        return resolveService(name: name, type: type, domain: domain,
                              interfaceIndex: UInt32(interface?.index ?? 0))?.host
    case .unix: return nil
    }
}

private func makeTLSContext(for descriptor: Int32, serverName: String) -> (UnsafeMutableRawPointer?, OSStatus) {
    guard let context = finchSSLCreateContext(nil, 1, 0) else { return (nil, errSecAllocate) }
    var status = finchSSLSetIOFuncs(context, networkTLSRead, networkTLSWrite)
    if status == noErr {
        status = finchSSLSetConnection(context, UnsafeRawPointer(bitPattern: Int(descriptor)))
    }
    if status == noErr {
        status = serverName.withCString { finchSSLSetPeerDomainName(context, $0, serverName.utf8.count) }
    }
    if status == noErr { status = finchSSLHandshake(context) }
    guard status == noErr else {
        releaseTLSContext(context)
        return (nil, status)
    }
    return (context, noErr)
}

private func releaseTLSContext(_ context: UnsafeMutableRawPointer) {
    _ = finchSSLClose(context)
    Unmanaged<AnyObject>.fromOpaque(context).release()
}

private func stateName(_ state: NWConnection.State) -> String {
    switch state {
    case .setup: return "setup"
    case .waiting: return "waiting"
    case .preparing: return "preparing"
    case .ready: return "ready"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    }
}

extension NWConnection {
    convenience public init?(message: NWConnectionGroup.Message) {
        guard let connection = message.extractConnection() else { return nil }
        self.init(to: connection.endpoint, using: connection.parameters.copy())
    }

    convenience public init?(from group: NWConnectionGroup, to endpoint: NWEndpoint? = nil,
                             using options: NWProtocolOptions? = nil) {
        guard let connection = group.extract(connectionTo: endpoint, using: options) else { return nil }
        self.init(to: connection.endpoint, using: connection.parameters.copy())
    }

    public struct EstablishmentReport: CustomDebugStringConvertible, Sendable {
        public struct Resolution: Sendable {
            public enum Source: Equatable, Hashable, Sendable { case query, cache, expiredCache }
            public enum DNSProtocol: Equatable, Hashable, Sendable { case unknown, udp, tcp, tls, https }
            public let source: Source
            public let duration: TimeInterval
            public let endpointCount: Int
            public let successfulEndpoint: NWEndpoint
            public let preferredEndpoint: NWEndpoint
            public var dnsProtocol: DNSProtocol { .unknown }
            init(source: Source, duration: TimeInterval, endpointCount: Int,
                 successfulEndpoint: NWEndpoint, preferredEndpoint: NWEndpoint) {
                self.source = source
                self.duration = duration
                self.endpointCount = endpointCount
                self.successfulEndpoint = successfulEndpoint
                self.preferredEndpoint = preferredEndpoint
            }
        }

        public struct Handshake: Sendable {
            public let definition: NWProtocolDefinition
            public let handshakeDuration: TimeInterval
            public let handshakeRTT: TimeInterval
        }

        public let duration: TimeInterval
        public let attemptStartedAfterInterval: TimeInterval
        public let previousAttemptCount: Int
        public let usedProxy: Bool
        public let proxyConfigured: Bool
        public let proxyEndpoint: NWEndpoint?
        public let resolutions: [Resolution]
        public let handshakes: [Handshake]
        public var debugDescription: String { "NWConnection.EstablishmentReport" }

        init(duration: TimeInterval, attemptStartedAfterInterval: TimeInterval, previousAttemptCount: Int,
             usedProxy: Bool, proxyConfigured: Bool, proxyEndpoint: NWEndpoint?,
             resolutions: [Resolution], handshakes: [Handshake]) {
            self.duration = duration
            self.attemptStartedAfterInterval = attemptStartedAfterInterval
            self.previousAttemptCount = previousAttemptCount
            self.usedProxy = usedProxy
            self.proxyConfigured = proxyConfigured
            self.proxyEndpoint = proxyEndpoint
            self.resolutions = resolutions
            self.handshakes = handshakes
        }
    }

    public struct DataTransferReport: CustomDebugStringConvertible, Sendable {
        public struct PathReport: Sendable {
            public let interface: NWInterface
            public var radioType: NWInterface.RadioType? { nil }
            public let receivedIPPacketCount: UInt64
            public let sentIPPacketCount: UInt64
            public let receivedTransportByteCount: UInt64
            public let receivedTransportDuplicateByteCount: UInt64
            public let receivedTransportOutOfOrderByteCount: UInt64
            public let sentTransportByteCount: UInt64
            public let retransmittedTransportByteCount: UInt64
            public let transportSmoothedRTT: TimeInterval
            public let transportMinimumRTT: TimeInterval
            public let transportRTTVariance: TimeInterval
            public let receivedApplicationByteCount: UInt64
            public let sentApplicationByteCount: UInt64

            init(interface: NWInterface, received: UInt64, sent: UInt64) {
                self.interface = interface
                receivedIPPacketCount = 0
                sentIPPacketCount = 0
                receivedTransportByteCount = received
                receivedTransportDuplicateByteCount = 0
                receivedTransportOutOfOrderByteCount = 0
                sentTransportByteCount = sent
                retransmittedTransportByteCount = 0
                transportSmoothedRTT = 0
                transportMinimumRTT = 0
                transportRTTVariance = 0
                receivedApplicationByteCount = received
                sentApplicationByteCount = sent
            }
        }
        public let duration: TimeInterval
        public let aggregatePathReport: PathReport
        public let pathReports: [PathReport]
        public var debugDescription: String { "NWConnection.DataTransferReport" }
        init(duration: TimeInterval, report: PathReport) {
            self.duration = duration
            aggregatePathReport = report
            pathReports = [report]
        }
    }

    public class PendingDataTransferReport: @unchecked Sendable {
        private weak var connection: NWConnection?
        init(connection: NWConnection) { self.connection = connection }
        public func collect(queue: DispatchQueue, completion: @escaping @Sendable (DataTransferReport) -> Void) {
            let current = connection
            let values = current?.lock.withLock { (current!.receivedBytes, current!.sentBytes) } ?? (0, 0)
            let path = current?.currentPath
            let interface = path?.availableInterfaces.first ?? NWInterface(name: "lo0", type: .loopback)
            let duration = current.map { ProcessInfo.processInfo.systemUptime - $0.startedAt } ?? 0
            let report = DataTransferReport(duration: duration,
                report: DataTransferReport.PathReport(interface: interface, received: values.0, sent: values.1))
            queue.async { completion(report) }
        }
    }
}

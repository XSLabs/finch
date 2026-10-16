// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Dispatch
import Foundation

public protocol NWGroupDescriptor: AnyObject, Sendable {
    var members: [NWEndpoint] { get }
}

public class NWMulticastGroup: NWGroupDescriptor, @unchecked Sendable {
    public let members: [NWEndpoint]
    public let sourceFilter: NWEndpoint?
    public let isUnicastDisabled: Bool

    public init(for groupAddresses: [NWEndpoint], from: NWEndpoint? = nil, disableUnicast: Bool = false) throws {
        guard !groupAddresses.isEmpty, groupAddresses.allSatisfy(isMulticastEndpoint) else {
            throw NWError.posix(POSIXErrorCode(rawValue: EINVAL) ?? .EIO)
        }
        members = groupAddresses
        sourceFilter = from
        isUnicastDisabled = disableUnicast
    }
}

public class NWMultiplexGroup: NWGroupDescriptor, @unchecked Sendable {
    public let members: [NWEndpoint]
    public init(to endpoint: NWEndpoint) { members = [endpoint] }
}

@_objcRuntimeName(_TtC7Network14_NWConnectionGroup)
final public class NWConnectionGroup: CustomDebugStringConvertible, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public class Message: NWConnection.ContentContext, @unchecked Sendable {
        public static let `default` = Message(identifier: "default")
        public var remoteEndpoint: NWEndpoint?
        public var localEndpoint: NWEndpoint?
        public var path: NWPath?
        fileprivate var replyHandler: ((Data?, Message) -> Void)?
        private let connectionParameters: NWParameters?
        private let extractHandler: (() -> NWConnection?)?

        public override init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5,
                             isFinal: Bool = false, antecedent: NWConnection.ContentContext? = nil,
                             metadata: [NWProtocolMetadata]? = []) {
            connectionParameters = nil
            extractHandler = nil
            super.init(identifier: identifier, expiration: expiration, priority: priority,
                       isFinal: isFinal, antecedent: antecedent, metadata: metadata)
        }

        fileprivate init(remote: NWEndpoint, local: NWEndpoint?, path: NWPath?,
                         using parameters: NWParameters,
                         reply: @escaping (Data?, Message) -> Void,
                         extract: @escaping () -> NWConnection?) {
            remoteEndpoint = remote
            localEndpoint = local
            self.path = path
            replyHandler = reply
            connectionParameters = parameters.copy()
            extractHandler = extract
            super.init(identifier: "datagram")
        }

        public func metadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? {
            protocolMetadata.first { $0.definition == definition }
        }

        public func reply(content: Data?, message: Message = .default) {
            replyHandler?(content, message)
        }

        public func extractConnection() -> NWConnection? {
            if let extractHandler { return extractHandler() }
            guard let remoteEndpoint, let connectionParameters else { return nil }
            return NWConnection(to: remoteEndpoint, using: connectionParameters.copy())
        }
    }

    private let lock = NSLock()
    private var currentState: State = .setup
    private var stateHandler: (@Sendable (State) -> Void)?
    private var newConnection: (@Sendable (NWConnection) -> Void)?
    private var receiveHandler: (@Sendable (Message, Data?, Bool) -> Void)?
    private var maximumMessageSize = Int.max
    private var rejectOversizedMessages = true
    private var seenEndpoints: Set<NWEndpoint> = []
    private var extractedEndpoints: Set<NWEndpoint> = []
    private var workQueue: DispatchQueue?
    private var descriptorSocket: Int32 = -1
    private var source: DispatchSourceRead?

    public final let descriptor: any NWGroupDescriptor
    public final let parameters: NWParameters

    public init(with descriptor: any NWGroupDescriptor, using parameters: NWParameters) {
        self.descriptor = descriptor
        self.parameters = parameters
    }

    final public var state: State { lock.withLock { currentState } }

    @preconcurrency
    final public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    @preconcurrency
    final public var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { lock.withLock { newConnection } }
        set { lock.withLock { newConnection = newValue } }
    }

    final public func setReceiveHandler(maximumMessageSize: Int = Int.max, rejectOversizedMessages: Bool = true,
                                        handler: (@Sendable (Message, Data?, Bool) -> Void)?) {
        lock.withLock {
            self.maximumMessageSize = max(0, maximumMessageSize)
            self.rejectOversizedMessages = rejectOversizedMessages
            receiveHandler = handler
        }
    }

    final public func send(content: Data?, to endpoint: NWEndpoint? = nil, message: Message = .default,
                           completion: @escaping (NWError?) -> Void) {
        guard let queue else { completion(networkError(ENOTCONN)); return }
        queue.async { [weak self] in
            guard let self, self.state == .ready,
                  let target = endpoint ?? self.descriptor.members.first,
                  let address = networkAddresses(for: target, socketType: Int32(SOCK_DGRAM)).first else {
                completion(networkError(EDESTADDRREQ))
                return
            }
            let descriptor = self.lock.withLock { self.descriptorSocket }
            guard descriptor >= 0 else { completion(networkError(ENOTCONN)); return }
            let bytes = content ?? Data()
            let result = bytes.withUnsafeBytes { buffer in
                withUnsafePointer(to: address.storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, address.length)
                    }
                }
            }
            completion(result < 0 ? networkError() : nil)
        }
    }

    final public func metadata(definition: NWProtocolDefinition) -> NWProtocolMetadata? { nil }

    final public func extract(connectionTo endpoint: NWEndpoint? = nil, using options: NWProtocolOptions? = nil) -> NWConnection? {
        guard parameters.transport == .udp,
              let endpoint = endpoint ?? descriptor.members.first,
              !isMulticastEndpoint(endpoint) else { return nil }
        let connectionParameters = parameters.copy()
        if let options {
            guard let udpOptions = options as? NWProtocolUDP.Options else { return nil }
            connectionParameters.udpOptions = udpOptions.copy()
        }
        let inserted = lock.withLock { () -> Bool in
            guard currentState != .cancelled, !extractedEndpoints.contains(endpoint) else { return false }
            extractedEndpoints.insert(endpoint)
            return true
        }
        return inserted ? NWConnection(to: endpoint, using: connectionParameters) : nil
    }

    final public func reinsert(connection: NWConnection) -> Bool {
        let reinserted = lock.withLock { () -> Bool in
            guard currentState != .cancelled, extractedEndpoints.remove(connection.endpoint) != nil else { return false }
            seenEndpoints.remove(connection.endpoint)
            return true
        }
        if reinserted { connection.cancel() }
        return reinserted
    }

    final public func start(queue: DispatchQueue) {
        let shouldStart = lock.withLock { () -> Bool in
            guard currentState == .setup, workQueue == nil else { return false }
            workQueue = queue
            return true
        }
        guard shouldStart else { return }
        transition(to: .waiting(networkError(EINPROGRESS)))
        queue.async { [weak self] in self?.openGroup() }
    }

    final public var queue: DispatchQueue? { lock.withLock { workQueue } }

    final public func cancel() {
        let (descriptor, source) = lock.withLock { () -> (Int32, DispatchSourceRead?) in
            let descriptor = descriptorSocket
            descriptorSocket = -1
            let source = self.source
            self.source = nil
            return (descriptor, source)
        }
        source?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor) }
        transition(to: .cancelled)
    }

    public var debugDescription: String { "NWConnectionGroup(\(state))" }

    private func openGroup() {
        guard !parameters.hasUnsupportedRoutingPolicy else {
            transition(to: .failed(networkError(EOPNOTSUPP)))
            return
        }
        if let multicast = descriptor as? NWMulticastGroup,
           (multicast.members.count != 1 || multicast.sourceFilter != nil || multicast.isUnicastDisabled) {
            transition(to: .failed(networkError(EOPNOTSUPP)))
            return
        }
        guard parameters.requiredLocalEndpoint == nil else {
            transition(to: .failed(networkError(EOPNOTSUPP)))
            return
        }
        guard parameters.transport == .udp, let endpoint = descriptor.members.first,
              case let .hostPort(host: host, port: port) = endpoint,
              let address = networkAddresses(for: endpoint, socketType: Int32(SOCK_DGRAM)).first else {
            transition(to: .failed(networkError(EOPNOTSUPP)))
            return
        }
        let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { transition(to: .failed(networkError())); return }
        configureSocket(fd, parameters: parameters, reuse: true, family: address.family)

        var bound = false
        if address.family == AF_INET, case let .ipv4(group) = host,
           descriptor is NWMulticastGroup, let bindAddress = networkAddresses(for: .hostPort(host: "0.0.0.0", port: port), socketType: Int32(SOCK_DGRAM)).first {
            bound = withUnsafePointer(to: bindAddress.storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, bindAddress.length) == 0 }
            }
            var request = ip_mreq()
            group.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &request.imr_multiaddr) { $0.copyBytes(from: bytes) }
            }
            request.imr_interface.s_addr = in_addr_t(0)
            if bound && setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) != 0 {
                bound = false
            }
        } else if address.family == AF_INET6, case let .ipv6(group) = host,
                  descriptor is NWMulticastGroup, let bindAddress = networkAddresses(for: .hostPort(host: "::", port: port), socketType: Int32(SOCK_DGRAM)).first {
            bound = withUnsafePointer(to: bindAddress.storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, bindAddress.length) == 0 }
            }
            var request = ipv6_mreq()
            group.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &request.ipv6mr_multiaddr) { $0.copyBytes(from: bytes) }
            }
            request.ipv6mr_interface = 0
            if bound && setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &request, socklen_t(MemoryLayout<ipv6_mreq>.size)) != 0 {
                bound = false
            }
        } else {
            bound = withUnsafePointer(to: address.storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, address.length) == 0 }
            }
        }
        guard bound else { let error = networkError(); Darwin.close(fd); transition(to: .failed(error)); return }
        setSocketNonblocking(fd)
        guard let queue else { Darwin.close(fd); return }
        lock.withLock { descriptorSocket = fd }
        transition(to: .ready)
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readDatagrams() }
        lock.withLock { source = read }
        read.resume()
    }

    private func readDatagrams() {
        let fd = lock.withLock { descriptorSocket }
        guard fd >= 0 else { return }
        while true {
            var bytes = [UInt8](repeating: 0, count: 65_535)
            var remote = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = bytes.withUnsafeMutableBytes { data in
                withUnsafeMutablePointer(to: &remote) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, data.baseAddress, data.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                transition(to: .failed(networkError()))
                return
            }
            guard let remoteEndpoint = networkEndpoint(for: remote) else { continue }
            let data = Data(bytes.prefix(count))
            let (handler, reject, maximumSize, isExtracted) = lock.withLock {
                (receiveHandler, rejectOversizedMessages, maximumMessageSize, extractedEndpoints.contains(remoteEndpoint))
            }
            if isExtracted { continue }
            guard let handler, !(reject && count > maximumSize) else { continue }
            let message = Message(remote: remoteEndpoint, local: socketEndpoint(fd, peer: false),
                                  path: NWPath.current(localEndpoint: socketEndpoint(fd, peer: false), remoteEndpoint: remoteEndpoint),
                                  using: parameters,
                                  reply: { [weak self] content, replyMessage in
                                      self?.send(content: content, to: replyMessage.remoteEndpoint ?? remoteEndpoint, message: replyMessage) { _ in }
                                  },
                                  extract: { [weak self] in self?.extract(connectionTo: remoteEndpoint) })
            handler(message, data, true)
            let isNew = lock.withLock { seenEndpoints.insert(remoteEndpoint).inserted }
            if isNew, descriptor is NWMultiplexGroup {
                if let connection = extract(connectionTo: remoteEndpoint) {
                    lock.withLock { newConnection }?(connection)
                }
            }
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

private func isMulticastEndpoint(_ endpoint: NWEndpoint) -> Bool {
    guard case let .hostPort(host, _) = endpoint else { return false }
    switch host {
    case let .ipv4(address): return address.isMulticast
    case let .ipv6(address): return address.isMulticast
    case .name: return false
    }
}

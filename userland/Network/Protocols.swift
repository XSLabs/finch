// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Foundation
import Security

@_objcRuntimeName(_TtC7Network21_NWProtocolDefinition)
public class NWProtocolDefinition: Equatable, CustomDebugStringConvertible, @unchecked Sendable {
    public let name: String
    init(name: String) { self.name = name }
    public var debugDescription: String { name }
    public static func == (lhs: NWProtocolDefinition, rhs: NWProtocolDefinition) -> Bool { lhs.name == rhs.name }
}

@_objcRuntimeName(_TtC7Network18_NWProtocolOptions)
public class NWProtocolOptions: @unchecked Sendable {
    init() {}
}

@_objcRuntimeName(_TtC7Network19_NWProtocolMetadata)
public class NWProtocolMetadata: @unchecked Sendable {
    let definition: NWProtocolDefinition?
    init(definition: NWProtocolDefinition? = nil) { self.definition = definition }
}

@_objcRuntimeName(_TtC7Network11_NWProtocol)
public class NWProtocol: @unchecked Sendable {
    init() {}
}

@_objcRuntimeName(_TtC7Network14_NWProtocolTCP)
public class NWProtocolTCP: NWProtocol, @unchecked Sendable {
    public static let definition = NWProtocolDefinition(name: "TCP")

    @_objcRuntimeName(_TtCC7Network14_NWProtocolTCP7Options)
    public class Options: NWProtocolOptions, @unchecked Sendable {
        public var noDelay = false
        public var noPush = false
        public var noOptions = false
        public var enableKeepalive = false
        public var keepaliveCount = 8
        public var keepaliveIdle = 60
        public var keepaliveInterval = 60
        public var maximumSegmentSize = 0
        public var connectionTimeout = 0
        public var persistTimeout = 0
        public var connectionDropTime = 0
        public var retransmitFinDrop = false
        public var disableAckStretching = false
        public var enableFastOpen = false
        public var disableECN = false

        public override init() { super.init() }

        func copy() -> Options {
            let value = Options()
            value.noDelay = noDelay
            value.noPush = noPush
            value.noOptions = noOptions
            value.enableKeepalive = enableKeepalive
            value.keepaliveCount = keepaliveCount
            value.keepaliveIdle = keepaliveIdle
            value.keepaliveInterval = keepaliveInterval
            value.maximumSegmentSize = maximumSegmentSize
            value.connectionTimeout = connectionTimeout
            value.persistTimeout = persistTimeout
            value.connectionDropTime = connectionDropTime
            value.retransmitFinDrop = retransmitFinDrop
            value.disableAckStretching = disableAckStretching
            value.enableFastOpen = enableFastOpen
            value.disableECN = disableECN
            return value
        }
    }
}

@_objcRuntimeName(_TtC7Network14_NWProtocolUDP)
public class NWProtocolUDP: NWProtocol, @unchecked Sendable {
    public static let definition = NWProtocolDefinition(name: "UDP")

    @_objcRuntimeName(_TtCC7Network14_NWProtocolUDP7Options)
    public class Options: NWProtocolOptions, @unchecked Sendable {
        public var preferNoChecksum = false
        public override init() { super.init() }
        func copy() -> Options {
            let value = Options()
            value.preferNoChecksum = preferNoChecksum
            return value
        }
    }
}

@_silgen_name("finch_network_sec_protocol_options_create")
private func makeSecProtocolOptions() -> sec_protocol_options_t

@_silgen_name("finch_network_sec_protocol_metadata_create")
private func makeSecProtocolMetadata() -> sec_protocol_metadata_t

@_silgen_name("_FinchSecProtocolOptionsCopy")
private func copySecProtocolOptions(_ source: sec_protocol_options_t,
                                    _ destination: sec_protocol_options_t) -> Int32

@_objcRuntimeName(_TtC7Network14_NWProtocolTLS)
public class NWProtocolTLS: NWProtocol, @unchecked Sendable {
    public static let definition = NWProtocolDefinition(name: "TLS")

    @_objcRuntimeName(_TtCC7Network14_NWProtocolTLS7Options)
    public class Options: NWProtocolOptions, @unchecked Sendable {
        private let options = makeSecProtocolOptions()
        public var securityProtocolOptions: sec_protocol_options_t { options }
        public override init() { super.init() }
        func copy() -> Options {
            let value = Options()
            _ = copySecProtocolOptions(options, value.options)
            return value
        }
    }

    @_objcRuntimeName(_TtCC7Network14_NWProtocolTLS8Metadata)
    public class Metadata: NWProtocolMetadata, @unchecked Sendable {
        private let metadata: sec_protocol_metadata_t
        public var securityProtocolMetadata: sec_protocol_metadata_t { metadata }

        public convenience init() { self.init(makeSecProtocolMetadata()) }

        init(_ metadata: sec_protocol_metadata_t) {
            self.metadata = metadata
            super.init(definition: NWProtocolTLS.definition)
        }
    }
}

@_objcRuntimeName(_TtC7Network13_NWParameters)
public final class NWParameters: CustomDebugStringConvertible, @unchecked Sendable {
    enum Transport: Equatable { case tcp, udp }

    var transport: Transport = .tcp
    var tlsOptions: NWProtocolTLS.Options?
    var tcpOptions = NWProtocolTCP.Options()
    var udpOptions = NWProtocolUDP.Options()
    var requiresApplicationService = false

    public var requiredInterface: NWInterface?
    public var requiredInterfaceType: NWInterface.InterfaceType = .other
    public var prohibitedInterfaces: [NWInterface]?
    public var prohibitedInterfaceTypes: [NWInterface.InterfaceType]?
    public var prohibitExpensivePaths = false
    public var prohibitConstrainedPaths = false
    public var preferNoProxies = false
    public var requiredLocalEndpoint: NWEndpoint?
    public var allowLocalEndpointReuse = false
    public var acceptLocalOnly = false
    public var includePeerToPeer = false
    public var multipathServiceType: MultipathServiceType = .disabled

    public enum ServiceClass: Equatable, Hashable, Sendable {
        case bestEffort, background, interactiveVideo, interactiveVoice, responsiveData, signaling
    }

    public enum MultipathServiceType: Equatable, Hashable, Sendable {
        case disabled, handover, interactive, aggregate
    }

    public enum ExpiredDNSBehavior: Equatable, Hashable, Sendable {
        case systemDefault, allow, prohibit, persistent
    }

    public enum Attribution: Equatable, Hashable, Sendable {
        case developer, user
    }

    public var serviceClass: ServiceClass = .bestEffort
    public var expiredDNSBehavior: ExpiredDNSBehavior = .systemDefault
    public var attribution: Attribution = .developer
    public var proxyConfigurations: [ProxyConfiguration] = []

    public init() {}

    public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()) {
        self.init()
        transport = .tcp
        tlsOptions = tls
        tcpOptions = tcp
    }

    public convenience init(dtls: NWProtocolTLS.Options?, udp: NWProtocolUDP.Options = NWProtocolUDP.Options()) {
        self.init()
        transport = .udp
        tlsOptions = dtls
        udpOptions = udp
    }

    public static var tls: NWParameters { NWParameters(tls: NWProtocolTLS.Options()) }
    public static var dtls: NWParameters { NWParameters(dtls: NWProtocolTLS.Options()) }
    public static var tcp: NWParameters { NWParameters() }
    public static var udp: NWParameters { NWParameters(dtls: nil) }
    public static var applicationService: NWParameters {
        let parameters = NWParameters.tls
        parameters.requiresApplicationService = true
        return parameters
    }

    public func copy() -> NWParameters {
        let copy = NWParameters()
        copy.transport = transport
        copy.tlsOptions = tlsOptions?.copy()
        copy.tcpOptions = tcpOptions.copy()
        copy.udpOptions = udpOptions.copy()
        copy.requiresApplicationService = requiresApplicationService
        copy.requiredInterface = requiredInterface
        copy.requiredInterfaceType = requiredInterfaceType
        copy.prohibitedInterfaces = prohibitedInterfaces
        copy.prohibitedInterfaceTypes = prohibitedInterfaceTypes
        copy.prohibitExpensivePaths = prohibitExpensivePaths
        copy.prohibitConstrainedPaths = prohibitConstrainedPaths
        copy.preferNoProxies = preferNoProxies
        copy.requiredLocalEndpoint = requiredLocalEndpoint
        copy.allowLocalEndpointReuse = allowLocalEndpointReuse
        copy.acceptLocalOnly = acceptLocalOnly
        copy.includePeerToPeer = includePeerToPeer
        copy.multipathServiceType = multipathServiceType
        copy.serviceClass = serviceClass
        copy.expiredDNSBehavior = expiredDNSBehavior
        copy.attribution = attribution
        copy.proxyConfigurations = proxyConfigurations
        return copy
    }

    var hasUnsupportedRoutingPolicy: Bool {
        requiresApplicationService || requiredInterface != nil || requiredInterfaceType != .other ||
            !(prohibitedInterfaces ?? []).isEmpty || !(prohibitedInterfaceTypes ?? []).isEmpty ||
            prohibitExpensivePaths || prohibitConstrainedPaths || includePeerToPeer ||
            multipathServiceType != .disabled || expiredDNSBehavior != .systemDefault ||
            (!preferNoProxies && !proxyConfigurations.isEmpty)
    }

    public var debugDescription: String { "NWParameters(\(transport == .tcp ? "TCP" : "UDP"))" }
}

public struct ProxyConfiguration: CustomDebugStringConvertible, Sendable {
    private enum Kind: Equatable, Sendable { case socks, httpConnect }
    private final class CredentialState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (String, String)?
        func set(username: String, password: String) { lock.withLock { value = (username, password) } }
    }

    private let kind: Kind
    private let endpoint: NWEndpoint
    private let tlsOptions: NWProtocolTLS.Options?
    private let credentials = CredentialState()
    public var allowFailover = false
    public var matchDomains: [String] = []
    public var excludedDomains: [String] = []

    public init(socksv5Proxy endpoint: NWEndpoint) {
        kind = .socks
        self.endpoint = endpoint
        tlsOptions = nil
    }

    public init(httpCONNECTProxy endpoint: NWEndpoint, tlsOptions: NWProtocolTLS.Options? = nil) {
        kind = .httpConnect
        self.endpoint = endpoint
        self.tlsOptions = tlsOptions
    }

    public func applyCredential(username: String, password: String) {
        credentials.set(username: username, password: password)
    }

    public var debugDescription: String {
        "ProxyConfiguration(\(kind == .socks ? "SOCKS" : "HTTP CONNECT"), \(endpoint.debugDescription))"
    }
}

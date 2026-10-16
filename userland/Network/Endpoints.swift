// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Foundation

public protocol IPAddress: Sendable {
    var rawValue: Data { get }
    var interface: NWInterface? { get }
    var isLoopback: Bool { get }
    var isLinkLocal: Bool { get }
    var isMulticast: Bool { get }
    init?(_ rawValue: Data, _ interface: NWInterface?)
    init?(_ string: String)
}

public struct IPv4Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public static let any = IPv4Address(bytes: [0, 0, 0, 0])
    public static let broadcast = IPv4Address(bytes: [255, 255, 255, 255])
    public static let loopback = IPv4Address(bytes: [127, 0, 0, 1])
    public static let allHostsGroup = IPv4Address(bytes: [224, 0, 0, 1])
    public static let allRoutersGroup = IPv4Address(bytes: [224, 0, 0, 2])
    public static let allReportsGroup = IPv4Address(bytes: [224, 0, 0, 22])
    public static let mdnsGroup = IPv4Address(bytes: [224, 0, 0, 251])

    public let rawValue: Data
    public let interface: NWInterface?

    private init(bytes: [UInt8]) {
        rawValue = Data(bytes)
        interface = nil
    }

    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) {
        guard rawValue.count == 4 else { return nil }
        self.rawValue = rawValue
        self.interface = interface
    }

    public init?(_ string: String) {
        var address = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: address) { Data($0) }
        interface = nil
    }

    public var isLoopback: Bool { rawValue.first == 127 }
    public var isLinkLocal: Bool { rawValue.count == 4 && rawValue[0] == 169 && rawValue[1] == 254 }
    public var isMulticast: Bool { rawValue.count == 4 && (224...239).contains(rawValue[0]) }

    public var debugDescription: String { addressString(AF_INET, rawValue) ?? rawValue.map(String.init).joined(separator: ".") }
}

public struct IPv6Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public static let any = IPv6Address(bytes: Array(repeating: 0, count: 16))
    public static let loopback = IPv6Address(bytes: Array(repeating: 0, count: 15) + [1])
    public static let allNodesGroup = IPv6Address(bytes: [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    public static let allRoutersGroup = IPv6Address(bytes: [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2])
    public static let mdnsGroup = IPv6Address(bytes: [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfb])

    public let rawValue: Data
    public let interface: NWInterface?

    private init(bytes: [UInt8]) {
        rawValue = Data(bytes)
        interface = nil
    }

    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) {
        guard rawValue.count == 16 else { return nil }
        self.rawValue = rawValue
        self.interface = interface
    }

    public init?(_ string: String) {
        var address = in6_addr()
        guard string.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: address) { Data($0) }
        interface = nil
    }

    public var isLoopback: Bool { rawValue.count == 16 && rawValue.dropLast().allSatisfy { $0 == 0 } && rawValue.last == 1 }
    public var isLinkLocal: Bool { rawValue.count == 16 && rawValue[0] == 0xfe && rawValue[1] & 0xc0 == 0x80 }
    public var isMulticast: Bool { rawValue.first == 0xff }

    public var debugDescription: String { addressString(AF_INET6, rawValue) ?? "::" }
}

private func addressString(_ family: Int32, _ data: Data) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let ok = data.withUnsafeBytes { bytes -> UnsafePointer<CChar>? in
        guard let base = bytes.baseAddress else { return nil }
        return inet_ntop(family, base, &buffer, socklen_t(buffer.count))
    }
    return ok.map { String(cString: $0) }
}

public enum NWEndpoint: Hashable, CustomDebugStringConvertible, Sendable {
    case hostPort(host: Host, port: Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)

    public enum Host: Hashable, CustomDebugStringConvertible, ExpressibleByStringLiteral, Sendable {
        public typealias StringLiteralType = String

        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)

        public init(stringLiteral value: String) { self = .name(value, nil) }
        public init(_ string: String) { self = .name(string, nil) }

        public var interface: NWInterface? {
            if case let .name(_, interface) = self { return interface }
            if case let .ipv4(address) = self { return address.interface }
            if case let .ipv6(address) = self { return address.interface }
            return nil
        }

        public var debugDescription: String {
            switch self {
            case let .name(name, _): return name
            case let .ipv4(address): return address.debugDescription
            case let .ipv6(address): return "[\(address.debugDescription)]"
            }
        }
    }

    public struct Port: Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral, RawRepresentable, Sendable {
        public typealias IntegerLiteralType = UInt16
        public typealias RawValue = UInt16
        public static let any = Port(uncheckedRawValue: 0)
        public static let ssh = Port(uncheckedRawValue: 22)
        public static let smtp = Port(uncheckedRawValue: 25)
        public static let http = Port(uncheckedRawValue: 80)
        public static let pop = Port(uncheckedRawValue: 110)
        public static let imap = Port(uncheckedRawValue: 143)
        public static let https = Port(uncheckedRawValue: 443)
        public static let imaps = Port(uncheckedRawValue: 993)
        public static let socks = Port(uncheckedRawValue: 1080)

        public let rawValue: UInt16
        private init(uncheckedRawValue: UInt16) { rawValue = uncheckedRawValue }
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { rawValue = value }

        public init?(_ service: String) {
            if let known = Self.namedPorts[service.lowercased()] { rawValue = known; return }
            guard let entry = service.withCString({ getservbyname($0, nil) }) else { return nil }
            rawValue = UInt16(bigEndian: UInt16(entry.pointee.s_port))
        }

        private static let namedPorts: [String: UInt16] = [
            "ssh": 22, "smtp": 25, "http": 80, "pop": 110, "imap": 143,
            "https": 443, "imaps": 993, "socks": 1080
        ]

        public var debugDescription: String { "\(rawValue)" }
    }

    public var interface: NWInterface? {
        switch self {
        case let .hostPort(host, _): return host.interface
        case let .service(_, _, _, interface): return interface
        case .unix, .url: return nil
        }
    }

    public var debugDescription: String {
        switch self {
        case let .hostPort(host, port): return "\(host.debugDescription):\(port.rawValue)"
        case let .service(name, type, domain, _): return "\(name).\(type)\(domain)"
        case let .unix(path): return "unix:\(path)"
        case let .url(url): return url.absoluteString
        }
    }
}

public enum NWError: Error, Equatable, CustomDebugStringConvertible, Sendable {
    case posix(POSIXErrorCode)
    case dns(Int32)
    case tls(OSStatus)
    case wifiAware(Int32)

    public var debugDescription: String {
        switch self {
        case let .posix(code): return "POSIX error: \(code.rawValue)"
        case let .dns(code): return "DNS service error: \(code)"
        case let .tls(code): return "TLS error: \(code)"
        case let .wifiAware(code): return "Wi-Fi Aware error: \(code)"
        }
    }
}

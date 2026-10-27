// SPDX-License-Identifier: MIT OR Apache-2.0
// Network's C API (nw_*) over Finch's Swift implementation: each nw_*_t is an object of a
// class conforming to its OS_nw_* protocol that holds the Swift value. Functions that
// create or copy return their object retained (Swift's @_cdecl returns autoreleased
// objects, so those return raw retained pointers); others borrow, as Apple's do.
import Darwin
import Dispatch
import Foundation
import Security

// MARK: - Ownership

@inline(__always) func nwRetained(_ object: AnyObject) -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(object).toOpaque()
}

@inline(__always) func nwRetained(_ object: AnyObject?) -> UnsafeMutableRawPointer? {
    object.map { Unmanaged.passRetained($0).toOpaque() }
}

/* A C string the object keeps for its lifetime (the get_ accessors return these). */
final class NWCStrings {
    private var strings: [String: UnsafeMutablePointer<CChar>] = [:]
    private let lock = NSLock()
    func pointer(_ key: String, _ value: String?) -> UnsafePointer<CChar>? {
        guard let value else { return nil }
        return lock.withLock {
            if let existing = strings[key], String(cString: existing) == value { return UnsafePointer(existing) }
            strings[key].map { free($0) }
            let copy = strdup(value)!
            strings[key] = copy
            return UnsafePointer(copy)
        }
    }
    deinit { strings.values.forEach { free($0) } }
}

func nwString(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }

func nwCopiedString(_ value: String?) -> UnsafeMutablePointer<CChar>? { value.flatMap { strdup($0) } }

@_cdecl("nw_retain")
public func finch_nw_retain(_ object: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let object else { return nil }
    _ = Unmanaged<AnyObject>.fromOpaque(object).retain()
    return object
}

@_cdecl("nw_release")
public func finch_nw_release(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    Unmanaged<AnyObject>.fromOpaque(object).release()
}

// MARK: - Endpoints

@objc(NWConcrete_nw_endpoint)
final class NWConcreteEndpoint: NSObject, OS_nw_endpoint {
    let endpoint: NWEndpoint
    var txtRecord: NWTXTRecord?
    var signature: Data?
    let strings = NWCStrings()
    private var storage: UnsafeMutableRawPointer?

    init(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
        super.init()
    }

    deinit { storage.map { free($0) } }

    /* The address as a sockaddr, kept for the object's lifetime. */
    var sockaddr: UnsafePointer<sockaddr>? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        if storage == nil {
            switch host {
            case let .ipv4(address):
                var sin = sockaddr_in()
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_port = port.rawValue.bigEndian
                address.rawValue.withUnsafeBytes { memcpy(&sin.sin_addr, $0.baseAddress!, 4) }
                let p = malloc(MemoryLayout<sockaddr_in>.size)!
                p.storeBytes(of: sin, as: sockaddr_in.self)
                storage = p
            case let .ipv6(address):
                var sin6 = sockaddr_in6()
                sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sin6.sin6_family = sa_family_t(AF_INET6)
                sin6.sin6_port = port.rawValue.bigEndian
                sin6.sin6_scope_id = UInt32(address.interface?.index ?? 0)
                address.rawValue.withUnsafeBytes { memcpy(&sin6.sin6_addr, $0.baseAddress!, 16) }
                let p = malloc(MemoryLayout<sockaddr_in6>.size)!
                p.storeBytes(of: sin6, as: sockaddr_in6.self)
                storage = p
            case .name:
                return nil
            }
        }
        return storage.map { UnsafePointer($0.assumingMemoryBound(to: Darwin.sockaddr.self)) }
    }

    override var description: String { endpoint.debugDescription }
}

func nwEndpoint(_ object: nw_endpoint_t?) -> NWEndpoint? { (object as AnyObject?).flatMap { ($0 as? NWConcreteEndpoint)?.endpoint } }

func nwEndpointFromSockaddr(_ address: UnsafePointer<sockaddr>) -> NWEndpoint? {
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> NWEndpoint? in
            var a = sin.pointee.sin_addr
            let data = withUnsafeBytes(of: &a) { Data($0) }
            guard let ip = IPv4Address(data) else { return nil }
            return .hostPort(host: .ipv4(ip), port: NWEndpoint.Port(rawValue: UInt16(bigEndian: sin.pointee.sin_port))!)
        }
    case AF_INET6:
        return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 -> NWEndpoint? in
            var a = sin6.pointee.sin6_addr
            let data = withUnsafeBytes(of: &a) { Data($0) }
            let scope = sin6.pointee.sin6_scope_id
            var interface: NWInterface?
            if scope != 0 {
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(scope, &name) != nil { interface = NWInterface(name: String(cString: name), type: .other) }
            }
            guard let ip = IPv6Address(data, interface) else { return nil }
            return .hostPort(host: .ipv6(ip), port: NWEndpoint.Port(rawValue: UInt16(bigEndian: sin6.pointee.sin6_port))!)
        }
    case AF_UNIX:
        return address.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { sun -> NWEndpoint? in
            var path = sun.pointee.sun_path
            let s = withUnsafeBytes(of: &path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return .unix(path: s)
        }
    default:
        return nil
    }
}

@_cdecl("nw_endpoint_create_host")
public func finch_nw_endpoint_create_host(_ hostname: UnsafePointer<CChar>, _ port: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    let host = String(cString: hostname), service = String(cString: port)
    guard let p = UInt16(service).flatMap({ NWEndpoint.Port(rawValue: $0) }) ?? NWEndpoint.Port(service) else { return nil }
    let h: NWEndpoint.Host
    /* (an IPv6 address may name its interface: "fe80::1%lo0") */
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let parts = bare.split(separator: "%", maxSplits: 1).map(String.init)
    let scope = parts.count == 2 ? NWInterface(name: parts[1], type: parts[1].hasPrefix("lo") ? .loopback : .other) : nil
    if let v4 = IPv4Address(host) { h = .ipv4(v4) }
    else if let v6 = IPv6Address(parts[0]).flatMap({ IPv6Address($0.rawValue, scope) }) { h = .ipv6(v6) }
    else { h = .name(host, nil) }
    return nwRetained(NWConcreteEndpoint(.hostPort(host: h, port: p)))
}

@_cdecl("nw_endpoint_create_address")
public func finch_nw_endpoint_create_address(_ address: UnsafePointer<sockaddr>) -> UnsafeMutableRawPointer? {
    nwRetained(nwEndpointFromSockaddr(address).map { NWConcreteEndpoint($0) })
}

@_cdecl("nw_endpoint_create_bonjour_service")
public func finch_nw_endpoint_create_bonjour_service(_ name: UnsafePointer<CChar>, _ type: UnsafePointer<CChar>,
                                                    _ domain: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteEndpoint(.service(name: String(cString: name), type: String(cString: type),
                                           domain: nwString(domain) ?? "local.", interface: nil)))
}

@_cdecl("nw_endpoint_create_url")
public func finch_nw_endpoint_create_url(_ url: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard let u = URL(string: String(cString: url)), u.host != nil else { return nil }
    return nwRetained(NWConcreteEndpoint(.url(u)))
}

@_cdecl("nw_endpoint_get_type")
public func finch_nw_endpoint_get_type(_ endpoint: nw_endpoint_t) -> nw_endpoint_type_t {
    switch nwEndpoint(endpoint) {
    case let .hostPort(host, _)?:
        if case .name = host { return nw_endpoint_type_host }
        return nw_endpoint_type_address
    case .service?: return nw_endpoint_type_bonjour_service
    case .url?: return nw_endpoint_type_url
    case .unix?: return nw_endpoint_type_address
    case nil: return nw_endpoint_type_invalid
    }
}

@_cdecl("nw_endpoint_get_hostname")
public func finch_nw_endpoint_get_hostname(_ endpoint: nw_endpoint_t) -> UnsafePointer<CChar>? {
    guard let e = endpoint as AnyObject as? NWConcreteEndpoint else { return nil }
    switch e.endpoint {
    case let .hostPort(.name(name, _), _): return e.strings.pointer("host", name)
    /* (as Apple's: an address's hostname is the address, without its interface) */
    case let .hostPort(.ipv4(address), _): return e.strings.pointer("host", address.debugDescription)
    case let .hostPort(.ipv6(address), _): return e.strings.pointer("host", address.debugDescription)
    case let .url(url): return e.strings.pointer("host", url.host)
    default: return nil
    }
}

func nwPortNumber(_ endpoint: NWEndpoint?) -> UInt16 {
    switch endpoint {
    case let .hostPort(_, port)?: return port.rawValue
    case let .url(url)?: return UInt16(url.port ?? (url.scheme == "https" || url.scheme == "wss" ? 443 : url.scheme == "http" || url.scheme == "ws" ? 80 : 0))
    default: return 0
    }
}

@_cdecl("nw_endpoint_get_port")
public func finch_nw_endpoint_get_port(_ endpoint: nw_endpoint_t) -> UInt16 { nwPortNumber(nwEndpoint(endpoint)) }

@_cdecl("nw_endpoint_copy_port_string")
public func finch_nw_endpoint_copy_port_string(_ endpoint: nw_endpoint_t) -> UnsafeMutablePointer<CChar>? {
    nwCopiedString(String(nwPortNumber(nwEndpoint(endpoint))))
}

@_cdecl("nw_endpoint_get_address")
public func finch_nw_endpoint_get_address(_ endpoint: nw_endpoint_t) -> UnsafePointer<sockaddr>? {
    (endpoint as AnyObject as? NWConcreteEndpoint)?.sockaddr
}

@_cdecl("nw_endpoint_copy_address_string")
public func finch_nw_endpoint_copy_address_string(_ endpoint: nw_endpoint_t) -> UnsafeMutablePointer<CChar>? {
    guard case let .hostPort(host, _)? = nwEndpoint(endpoint) else { return nil }
    switch host {
    case let .ipv4(address): return nwCopiedString(address.debugDescription)
    case let .ipv6(address):
        return nwCopiedString(address.debugDescription + (address.interface.map { "%\($0.name)" } ?? ""))
    case .name: return nil
    }
}

@_cdecl("nw_endpoint_get_bonjour_service_name")
public func finch_nw_endpoint_get_bonjour_service_name(_ endpoint: nw_endpoint_t) -> UnsafePointer<CChar>? {
    guard let e = endpoint as AnyObject as? NWConcreteEndpoint, case let .service(name, _, _, _) = e.endpoint else { return nil }
    return e.strings.pointer("name", name)
}

@_cdecl("nw_endpoint_get_bonjour_service_type")
public func finch_nw_endpoint_get_bonjour_service_type(_ endpoint: nw_endpoint_t) -> UnsafePointer<CChar>? {
    guard let e = endpoint as AnyObject as? NWConcreteEndpoint, case let .service(_, type, _, _) = e.endpoint else { return nil }
    return e.strings.pointer("type", type)
}

@_cdecl("nw_endpoint_get_bonjour_service_domain")
public func finch_nw_endpoint_get_bonjour_service_domain(_ endpoint: nw_endpoint_t) -> UnsafePointer<CChar>? {
    guard let e = endpoint as AnyObject as? NWConcreteEndpoint, case let .service(_, _, domain, _) = e.endpoint else { return nil }
    return e.strings.pointer("domain", domain)
}

@_cdecl("nw_endpoint_get_url")
public func finch_nw_endpoint_get_url(_ endpoint: nw_endpoint_t) -> UnsafePointer<CChar>? {
    guard let e = endpoint as AnyObject as? NWConcreteEndpoint, case let .url(url) = e.endpoint else { return nil }
    return e.strings.pointer("url", url.absoluteString)
}

@_cdecl("nw_endpoint_get_signature")
public func finch_nw_endpoint_get_signature(_ endpoint: nw_endpoint_t, _ length: UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>? {
    length?.pointee = 0
    return nil
}

@_cdecl("nw_endpoint_copy_txt_record")
public func finch_nw_endpoint_copy_txt_record(_ endpoint: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    guard let record = (endpoint as AnyObject as? NWConcreteEndpoint)?.txtRecord else { return nil }
    return nwRetained(NWConcreteTXTRecord(record))
}

// MARK: - Errors

@objc(NWConcrete_nw_error)
final class NWConcreteError: NSObject, OS_nw_error {
    let error: NWError
    init(_ error: NWError) {
        self.error = error
        super.init()
    }
    override var description: String { error.debugDescription }
}

func nwErrorObject(_ error: NWError?) -> NWConcreteError? { error.map { NWConcreteError($0) } }

@_cdecl("nw_error_get_error_domain")
public func finch_nw_error_get_error_domain(_ error: nw_error_t) -> nw_error_domain_t {
    switch (error as AnyObject as? NWConcreteError)?.error {
    case .posix?: return nw_error_domain_posix
    case .dns?: return nw_error_domain_dns
    case .tls?: return nw_error_domain_tls
    case .wifiAware?: return nw_error_domain_t(rawValue: 4)
    case nil: return nw_error_domain_invalid
    }
}

@_cdecl("nw_error_get_error_code")
public func finch_nw_error_get_error_code(_ error: nw_error_t) -> Int32 {
    switch (error as AnyObject as? NWConcreteError)?.error {
    case let .posix(code)?: return code.rawValue
    case let .dns(code)?: return code
    case let .tls(code)?: return code
    case let .wifiAware(code)?: return code
    case nil: return 0
    }
}

@_cdecl("nw_error_copy_cf_error")
public func finch_nw_error_copy_cf_error(_ error: nw_error_t) -> Unmanaged<CFError>? {
    guard let e = (error as AnyObject as? NWConcreteError)?.error else { return nil }
    let domain: CFString, code: Int
    switch e {
    case let .posix(c): domain = kNWErrorDomainPOSIX; code = Int(c.rawValue)
    case let .dns(c): domain = kNWErrorDomainDNS; code = Int(c)
    case let .tls(c): domain = kNWErrorDomainTLS; code = Int(c)
    case let .wifiAware(c): domain = kNWErrorDomainWiFiAware; code = Int(c)
    }
    return Unmanaged.passRetained(CFErrorCreate(nil, domain, code, nil))
}

// MARK: - Interfaces

@objc(NWConcrete_nw_interface)
final class NWConcreteInterface: NSObject, OS_nw_interface {
    let interface: NWInterface
    let strings = NWCStrings()
    init(_ interface: NWInterface) {
        self.interface = interface
        super.init()
    }
    override var description: String { interface.debugDescription }
}

func nwInterfaceType(_ type: NWInterface.InterfaceType) -> nw_interface_type_t {
    switch type {
    case .other: return nw_interface_type_other
    case .wifi: return nw_interface_type_wifi
    case .cellular: return nw_interface_type_cellular
    case .wiredEthernet: return nw_interface_type_wired
    case .loopback: return nw_interface_type_loopback
    }
}

func nwInterfaceType(_ type: nw_interface_type_t) -> NWInterface.InterfaceType {
    switch type.rawValue {
    case nw_interface_type_wifi.rawValue: return .wifi
    case nw_interface_type_cellular.rawValue: return .cellular
    case nw_interface_type_wired.rawValue: return .wiredEthernet
    case nw_interface_type_loopback.rawValue: return .loopback
    default: return .other
    }
}

@_cdecl("nw_interface_get_type")
public func finch_nw_interface_get_type(_ interface: nw_interface_t) -> nw_interface_type_t {
    (interface as AnyObject as? NWConcreteInterface).map { nwInterfaceType($0.interface.type) } ?? nw_interface_type_other
}

@_cdecl("nw_interface_get_name")
public func finch_nw_interface_get_name(_ interface: nw_interface_t) -> UnsafePointer<CChar>? {
    guard let i = interface as AnyObject as? NWConcreteInterface else { return nil }
    return i.strings.pointer("name", i.interface.name)
}

@_cdecl("nw_interface_get_index")
public func finch_nw_interface_get_index(_ interface: nw_interface_t) -> UInt32 {
    UInt32((interface as AnyObject as? NWConcreteInterface)?.interface.index ?? 0)
}

// MARK: - Paths and path monitors

@objc(NWConcrete_nw_path)
final class NWConcretePath: NSObject, OS_nw_path {
    let path: NWPath
    init(_ path: NWPath) {
        self.path = path
        super.init()
    }
    override var description: String { path.debugDescription }
}

func nwPath(_ object: nw_path_t?) -> NWPath? { (object as AnyObject?).flatMap { ($0 as? NWConcretePath)?.path } }

@_cdecl("nw_path_get_status")
public func finch_nw_path_get_status(_ path: nw_path_t?) -> nw_path_status_t {
    switch nwPath(path)?.status {
    case .satisfied?: return nw_path_status_satisfied
    case .unsatisfied?: return nw_path_status_unsatisfied
    case .requiresConnection?: return nw_path_status_satisfiable
    case nil: return nw_path_status_invalid
    }
}

@_cdecl("nw_path_get_unsatisfied_reason")
public func finch_nw_path_get_unsatisfied_reason(_ path: nw_path_t) -> nw_path_unsatisfied_reason_t {
    nwPath(path)?.status == .satisfied ? nw_path_unsatisfied_reason_not_available : nw_path_unsatisfied_reason_not_available
}

@_cdecl("nw_path_enumerate_interfaces")
public func finch_nw_path_enumerate_interfaces(_ path: nw_path_t, _ block: @convention(block) (nw_interface_t) -> Bool) {
    for interface in nwPath(path)?.availableInterfaces ?? [] where !block(NWConcreteInterface(interface)) { break }
}

@_cdecl("nw_path_is_equal")
public func finch_nw_path_is_equal(_ path: nw_path_t, _ other: nw_path_t) -> Bool { nwPath(path) == nwPath(other) }

@_cdecl("nw_path_is_expensive")
public func finch_nw_path_is_expensive(_ path: nw_path_t) -> Bool { nwPath(path)?.isExpensive ?? false }

@_cdecl("nw_path_is_constrained")
public func finch_nw_path_is_constrained(_ path: nw_path_t?) -> Bool { nwPath(path)?.isConstrained ?? false }

@_cdecl("nw_path_is_ultra_constrained")
public func finch_nw_path_is_ultra_constrained(_ path: nw_path_t) -> Bool { false }

@_cdecl("nw_path_has_ipv4")
public func finch_nw_path_has_ipv4(_ path: nw_path_t) -> Bool { nwPath(path)?.supportsIPv4 ?? false }

@_cdecl("nw_path_has_ipv6")
public func finch_nw_path_has_ipv6(_ path: nw_path_t) -> Bool { nwPath(path)?.supportsIPv6 ?? false }

@_cdecl("nw_path_has_dns")
public func finch_nw_path_has_dns(_ path: nw_path_t) -> Bool { nwPath(path)?.supportsDNS ?? false }

@_cdecl("nw_path_uses_interface_type")
public func finch_nw_path_uses_interface_type(_ path: nw_path_t, _ type: nw_interface_type_t) -> Bool {
    nwPath(path)?.usesInterfaceType(nwInterfaceType(type)) ?? false
}

@_cdecl("nw_path_copy_effective_local_endpoint")
public func finch_nw_path_copy_effective_local_endpoint(_ path: nw_path_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwPath(path)?.localEndpoint.map { NWConcreteEndpoint($0) })
}

@_cdecl("nw_path_copy_effective_remote_endpoint")
public func finch_nw_path_copy_effective_remote_endpoint(_ path: nw_path_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwPath(path)?.remoteEndpoint.map { NWConcreteEndpoint($0) })
}

@_cdecl("nw_path_enumerate_gateways")
public func finch_nw_path_enumerate_gateways(_ path: nw_path_t, _ block: @convention(block) (nw_endpoint_t) -> Bool) {
    for gateway in nwPath(path)?.gateways ?? [] where !block(NWConcreteEndpoint(gateway)) { break }
}

@_cdecl("nw_path_get_link_quality")
public func finch_nw_path_get_link_quality(_ path: nw_path_t) -> nw_link_quality_t {
    nwPath(path)?.status == .satisfied ? nw_link_quality_t(rawValue: 0) : nw_link_quality_t(rawValue: 0)
}

@objc(NWConcrete_nw_path_monitor)
final class NWConcretePathMonitor: NSObject, OS_nw_path_monitor {
    var requiredType: NWInterface.InterfaceType?
    var prohibited: [NWInterface.InterfaceType] = []
    var queue: DispatchQueue?
    var update: ((NWConcretePath) -> Void)?
    var cancelHandler: (() -> Void)?
    var monitor: NWPathMonitor?
    var started = false, cancelled = false
}

@_cdecl("nw_path_monitor_create")
public func finch_nw_path_monitor_create() -> UnsafeMutableRawPointer? { nwRetained(NWConcretePathMonitor()) }

@_cdecl("nw_path_monitor_create_with_type")
public func finch_nw_path_monitor_create_with_type(_ type: nw_interface_type_t) -> UnsafeMutableRawPointer? {
    let monitor = NWConcretePathMonitor()
    monitor.requiredType = nwInterfaceType(type)
    return nwRetained(monitor)
}

@_cdecl("nw_path_monitor_create_for_ethernet_channel")
public func finch_nw_path_monitor_create_for_ethernet_channel() -> UnsafeMutableRawPointer? {
    let monitor = NWConcretePathMonitor()
    monitor.requiredType = .wiredEthernet
    return nwRetained(monitor)
}

@_cdecl("nw_path_monitor_prohibit_interface_type")
public func finch_nw_path_monitor_prohibit_interface_type(_ monitor: nw_path_monitor_t, _ type: nw_interface_type_t) {
    (monitor as AnyObject as? NWConcretePathMonitor)?.prohibited.append(nwInterfaceType(type))
}

@_cdecl("nw_path_monitor_set_queue")
public func finch_nw_path_monitor_set_queue(_ monitor: nw_path_monitor_t, _ queue: DispatchQueue) {
    guard let m = monitor as AnyObject as? NWConcretePathMonitor, !m.started else { return }
    m.queue = queue
}

@_cdecl("nw_path_monitor_set_update_handler")
public func finch_nw_path_monitor_set_update_handler(_ monitor: nw_path_monitor_t,
                                                    _ handler: @escaping @convention(block) (nw_path_t) -> Void) {
    guard let m = monitor as AnyObject as? NWConcretePathMonitor, !m.cancelled else { return }
    m.update = { handler($0) }
}

@_cdecl("nw_path_monitor_set_cancel_handler")
public func finch_nw_path_monitor_set_cancel_handler(_ monitor: nw_path_monitor_t,
                                                    _ handler: @escaping @convention(block) () -> Void) {
    (monitor as AnyObject as? NWConcretePathMonitor)?.cancelHandler = { handler() }
}

@_cdecl("nw_path_monitor_start")
public func finch_nw_path_monitor_start(_ monitor: nw_path_monitor_t) {
    guard let m = monitor as AnyObject as? NWConcretePathMonitor, !m.started, !m.cancelled else { return }
    m.started = true
    let swiftMonitor: NWPathMonitor
    if let type = m.requiredType { swiftMonitor = NWPathMonitor(requiredInterfaceType: type) }
    else if !m.prohibited.isEmpty { swiftMonitor = NWPathMonitor(prohibitedInterfaceTypes: m.prohibited) }
    else { swiftMonitor = NWPathMonitor() }
    swiftMonitor.pathUpdateHandler = { [weak m] path in m?.update?(NWConcretePath(path)) }
    m.monitor = swiftMonitor
    swiftMonitor.start(queue: m.queue ?? DispatchQueue.global())
}

@_cdecl("nw_path_monitor_cancel")
public func finch_nw_path_monitor_cancel(_ monitor: nw_path_monitor_t) {
    guard let m = monitor as AnyObject as? NWConcretePathMonitor, !m.cancelled else { return }
    m.cancelled = true
    m.monitor?.cancel()
    m.monitor = nil
    m.update = nil
    if let handler = m.cancelHandler {
        m.cancelHandler = nil
        (m.queue ?? DispatchQueue.global()).async { handler() }
    }
}

// MARK: - Content contexts

@objc(NWConcrete_nw_content_context)
final class NWConcreteContentContext: NSObject, OS_nw_content_context {
    let identifier: String
    var isFinal = false
    var expiration: UInt64 = 0
    var priority = 0.5
    var antecedent: NWConcreteContentContext?
    var metadata: [NWConcreteProtocolMetadata] = []
    let strings = NWCStrings()

    init(identifier: String, isFinal: Bool = false) {
        self.identifier = identifier
        self.isFinal = isFinal
        super.init()
    }

    /* (Apple's well-known contexts can't be changed, and a final context takes no more
       changes but its finality) */
    var isFixed: Bool { self === nwDefaultMessageContext || self === nwFinalMessageContext || self === nwDefaultStreamContext }
    var acceptsChanges: Bool { !isFixed && !isFinal }

    static func wrapping(_ context: NWConnection.ContentContext) -> NWConcreteContentContext {
        if context === NWConnection.ContentContext.defaultMessage { return nwDefaultMessageContext }
        if context === NWConnection.ContentContext.finalMessage { return nwFinalMessageContext }
        if context === NWConnection.ContentContext.defaultStream { return nwDefaultStreamContext }
        return NWConcreteContentContext(context)
    }

    convenience init(_ context: NWConnection.ContentContext) {
        self.init(identifier: context.identifier, isFinal: context.isFinal)
        expiration = context.expirationMilliseconds
        priority = context.relativePriority
        antecedent = context.antecedent.map { NWConcreteContentContext.wrapping($0) }
        metadata = context.protocolMetadata.map { NWConcreteProtocolMetadata($0) }
    }

    var swiftContext: NWConnection.ContentContext {
        if self === nwDefaultMessageContext { return .defaultMessage }
        if self === nwFinalMessageContext { return .finalMessage }
        if self === nwDefaultStreamContext { return .defaultStream }
        return NWConnection.ContentContext(identifier: identifier, expiration: expiration, priority: priority, isFinal: isFinal,
                                           antecedent: antecedent?.swiftContext, metadata: metadata.map(\.metadata))
    }
}

let nwDefaultMessageContext = NWConcreteContentContext(identifier: "Default Message")
let nwFinalMessageContext = NWConcreteContentContext(identifier: "Final Message", isFinal: true)
let nwDefaultStreamContext = NWConcreteContentContext(identifier: "Default Stream", isFinal: true)

/* The well-known contexts and blocks the headers' macros name (network.m's globals). */
@_cdecl("finch_nw_well_known_context")
public func finch_nw_well_known_context(_ which: Int32) -> UnsafeMutableRawPointer? {
    nwRetained(which == 0 ? nwDefaultMessageContext : which == 1 ? nwFinalMessageContext : nwDefaultStreamContext)
}

@_cdecl("nw_content_context_create")
public func finch_nw_content_context_create(_ identifier: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteContentContext(identifier: String(cString: identifier)))
}

@_cdecl("nw_content_context_get_identifier")
public func finch_nw_content_context_get_identifier(_ context: nw_content_context_t) -> UnsafePointer<CChar>? {
    guard let c = context as AnyObject as? NWConcreteContentContext else { return nil }
    return c.strings.pointer("id", c.identifier)
}

@_cdecl("nw_content_context_get_is_final")
public func finch_nw_content_context_get_is_final(_ context: nw_content_context_t) -> Bool {
    (context as AnyObject as? NWConcreteContentContext)?.isFinal ?? false
}

@_cdecl("nw_content_context_set_is_final")
public func finch_nw_content_context_set_is_final(_ context: nw_content_context_t, _ value: Bool) {
    guard let c = context as AnyObject as? NWConcreteContentContext, !c.isFixed else { return }
    c.isFinal = value
}

@_cdecl("nw_content_context_get_expiration_milliseconds")
public func finch_nw_content_context_get_expiration_milliseconds(_ context: nw_content_context_t) -> UInt64 {
    (context as AnyObject as? NWConcreteContentContext)?.expiration ?? 0
}

@_cdecl("nw_content_context_set_expiration_milliseconds")
public func finch_nw_content_context_set_expiration_milliseconds(_ context: nw_content_context_t, _ value: UInt64) {
    guard let c = context as AnyObject as? NWConcreteContentContext, c.acceptsChanges else { return }
    c.expiration = value
}

@_cdecl("nw_content_context_get_relative_priority")
public func finch_nw_content_context_get_relative_priority(_ context: nw_content_context_t) -> Double {
    (context as AnyObject as? NWConcreteContentContext)?.priority ?? 0.5
}

@_cdecl("nw_content_context_set_relative_priority")
public func finch_nw_content_context_set_relative_priority(_ context: nw_content_context_t, _ value: Double) {
    guard let c = context as AnyObject as? NWConcreteContentContext, c.acceptsChanges else { return }
    c.priority = value
}

@_cdecl("nw_content_context_copy_antecedent")
public func finch_nw_content_context_copy_antecedent(_ context: nw_content_context_t) -> UnsafeMutableRawPointer? {
    nwRetained((context as AnyObject as? NWConcreteContentContext)?.antecedent)
}

@_cdecl("nw_content_context_set_antecedent")
public func finch_nw_content_context_set_antecedent(_ context: nw_content_context_t, _ antecedent: nw_content_context_t?) {
    guard let c = context as AnyObject as? NWConcreteContentContext, c.acceptsChanges else { return }
    let a = antecedent as AnyObject as? NWConcreteContentContext
    c.antecedent = a?.isFixed == true ? nil : a
}

@_cdecl("nw_content_context_copy_protocol_metadata")
public func finch_nw_content_context_copy_protocol_metadata(_ context: nw_content_context_t,
                                                           _ definition: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let c = context as AnyObject as? NWConcreteContentContext,
          let d = (definition as AnyObject as? NWConcreteProtocolDefinition)?.definition else { return nil }
    return nwRetained(c.metadata.first { $0.metadata.definition == d })
}

@_cdecl("nw_content_context_set_metadata_for_protocol")
public func finch_nw_content_context_set_metadata_for_protocol(_ context: nw_content_context_t, _ metadata: nw_protocol_metadata_t) {
    guard let c = context as AnyObject as? NWConcreteContentContext, let m = metadata as AnyObject as? NWConcreteProtocolMetadata else { return }
    c.metadata.removeAll { $0.metadata.definition == m.metadata.definition }
    c.metadata.append(m)
}

@_cdecl("nw_content_context_foreach_protocol_metadata")
public func finch_nw_content_context_foreach_protocol_metadata(_ context: nw_content_context_t,
                                                              _ block: @convention(block) (nw_protocol_definition_t, nw_protocol_metadata_t) -> Void) {
    for m in (context as AnyObject as? NWConcreteContentContext)?.metadata ?? [] {
        guard let d = m.metadata.definition else { continue }
        block(NWConcreteProtocolDefinition(d), m)
    }
}

// MARK: - Protocol definitions, options and metadata

@objc(NWConcrete_nw_protocol_definition)
final class NWConcreteProtocolDefinition: NSObject, OS_nw_protocol_definition {
    let definition: NWProtocolDefinition
    init(_ definition: NWProtocolDefinition) {
        self.definition = definition
        super.init()
    }
    override var description: String { definition.name }
}

@objc(NWConcrete_nw_protocol_options)
final class NWConcreteProtocolOptions: NSObject, OS_nw_protocol_options {
    let options: NWProtocolOptions
    init(_ options: NWProtocolOptions) {
        self.options = options
        super.init()
    }
}

@objc(NWConcrete_nw_protocol_metadata)
final class NWConcreteProtocolMetadata: NSObject, OS_nw_protocol_metadata {
    let metadata: NWProtocolMetadata
    init(_ metadata: NWProtocolMetadata) {
        self.metadata = metadata
        super.init()
    }
}

func nwOptions<T: NWProtocolOptions>(_ object: nw_protocol_options_t?, _ type: T.Type) -> T? {
    (object as AnyObject?).flatMap { ($0 as? NWConcreteProtocolOptions)?.options as? T }
}

func nwMetadata<T: NWProtocolMetadata>(_ object: nw_protocol_metadata_t?, _ type: T.Type) -> T? {
    (object as AnyObject?).flatMap { ($0 as? NWConcreteProtocolMetadata)?.metadata as? T }
}

func nwDefinition(of options: NWProtocolOptions) -> NWProtocolDefinition? {
    switch options {
    case is NWProtocolTCP.Options: return NWProtocolTCP.definition
    case is NWProtocolUDP.Options: return NWProtocolUDP.definition
    case is NWProtocolTLS.Options: return NWProtocolTLS.definition
    case is NWProtocolIP.Options: return NWProtocolIP.definition
    case let other as NWCOnlyOptions: return other.definition
    default: return nil
    }
}

/* Options the C API keeps for protocols Finch's connections don't speak yet (QUIC,
   WebSocket, framers): their settings are kept and read back, and a connection that
   asks for them fails with EPROTONOSUPPORT. */
class NWCOnlyOptions: NWProtocolOptions, @unchecked Sendable {
    let definition: NWProtocolDefinition
    init(definition: NWProtocolDefinition) {
        self.definition = definition
        super.init()
    }
}

final class NWCOnlyMetadata: NWProtocolMetadata, @unchecked Sendable {
    var values: [String: Any] = [:]
}

@_cdecl("nw_protocol_copy_tcp_definition")
public func finch_nw_protocol_copy_tcp_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(NWProtocolTCP.definition)) }
@_cdecl("nw_protocol_copy_udp_definition")
public func finch_nw_protocol_copy_udp_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(NWProtocolUDP.definition)) }
@_cdecl("nw_protocol_copy_tls_definition")
public func finch_nw_protocol_copy_tls_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(NWProtocolTLS.definition)) }
@_cdecl("nw_protocol_copy_ip_definition")
public func finch_nw_protocol_copy_ip_definition() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolDefinition(NWProtocolIP.definition)) }

@_cdecl("nw_protocol_definition_is_equal")
public func finch_nw_protocol_definition_is_equal(_ a: nw_protocol_definition_t, _ b: nw_protocol_definition_t) -> Bool {
    (a as AnyObject as? NWConcreteProtocolDefinition)?.definition == (b as AnyObject as? NWConcreteProtocolDefinition)?.definition
}

@_cdecl("nw_protocol_options_copy_definition")
public func finch_nw_protocol_options_copy_definition(_ options: nw_protocol_options_t) -> UnsafeMutableRawPointer? {
    nwRetained(((options as AnyObject as? NWConcreteProtocolOptions).flatMap { nwDefinition(of: $0.options) }).map { NWConcreteProtocolDefinition($0) })
}

@_cdecl("nw_protocol_metadata_copy_definition")
public func finch_nw_protocol_metadata_copy_definition(_ metadata: nw_protocol_metadata_t) -> UnsafeMutableRawPointer? {
    nwRetained((metadata as AnyObject as? NWConcreteProtocolMetadata)?.metadata.definition.map { NWConcreteProtocolDefinition($0) })
}

func nwMetadataIs(_ metadata: nw_protocol_metadata_t, _ definition: NWProtocolDefinition) -> Bool {
    (metadata as AnyObject as? NWConcreteProtocolMetadata)?.metadata.definition == definition
}

@_cdecl("nw_protocol_metadata_is_tcp")
public func finch_nw_protocol_metadata_is_tcp(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, NWProtocolTCP.definition) }
@_cdecl("nw_protocol_metadata_is_udp")
public func finch_nw_protocol_metadata_is_udp(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, NWProtocolUDP.definition) }
@_cdecl("nw_protocol_metadata_is_tls")
public func finch_nw_protocol_metadata_is_tls(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, NWProtocolTLS.definition) }
@_cdecl("nw_protocol_metadata_is_ip")
public func finch_nw_protocol_metadata_is_ip(_ m: nw_protocol_metadata_t) -> Bool { nwMetadataIs(m, NWProtocolIP.definition) }

// TCP

@_cdecl("nw_tcp_create_options")
public func finch_nw_tcp_create_options() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolOptions(NWProtocolTCP.Options())) }

func nwTCP(_ o: nw_protocol_options_t) -> NWProtocolTCP.Options? { nwOptions(o, NWProtocolTCP.Options.self) }

@_cdecl("nw_tcp_options_set_no_delay")
public func finch_nw_tcp_options_set_no_delay(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.noDelay = v }
@_cdecl("nw_tcp_options_set_no_push")
public func finch_nw_tcp_options_set_no_push(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.noPush = v }
@_cdecl("nw_tcp_options_set_no_options")
public func finch_nw_tcp_options_set_no_options(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.noOptions = v }
@_cdecl("nw_tcp_options_set_enable_keepalive")
public func finch_nw_tcp_options_set_enable_keepalive(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.enableKeepalive = v }
@_cdecl("nw_tcp_options_set_keepalive_count")
public func finch_nw_tcp_options_set_keepalive_count(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.keepaliveCount = Int(v) }
@_cdecl("nw_tcp_options_set_keepalive_idle_time")
public func finch_nw_tcp_options_set_keepalive_idle_time(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.keepaliveIdle = Int(v) }
@_cdecl("nw_tcp_options_set_keepalive_interval")
public func finch_nw_tcp_options_set_keepalive_interval(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.keepaliveInterval = Int(v) }
@_cdecl("nw_tcp_options_set_maximum_segment_size")
public func finch_nw_tcp_options_set_maximum_segment_size(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.maximumSegmentSize = Int(v) }
@_cdecl("nw_tcp_options_set_connection_timeout")
public func finch_nw_tcp_options_set_connection_timeout(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.connectionTimeout = Int(v) }
@_cdecl("nw_tcp_options_set_persist_timeout")
public func finch_nw_tcp_options_set_persist_timeout(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.persistTimeout = Int(v) }
@_cdecl("nw_tcp_options_set_retransmit_connection_drop_time")
public func finch_nw_tcp_options_set_retransmit_connection_drop_time(_ o: nw_protocol_options_t, _ v: UInt32) { nwTCP(o)?.connectionDropTime = Int(v) }
@_cdecl("nw_tcp_options_set_retransmit_fin_drop")
public func finch_nw_tcp_options_set_retransmit_fin_drop(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.retransmitFinDrop = v }
@_cdecl("nw_tcp_options_set_disable_ack_stretching")
public func finch_nw_tcp_options_set_disable_ack_stretching(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.disableAckStretching = v }
@_cdecl("nw_tcp_options_set_enable_fast_open")
public func finch_nw_tcp_options_set_enable_fast_open(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.enableFastOpen = v }
@_cdecl("nw_tcp_options_set_disable_ecn")
public func finch_nw_tcp_options_set_disable_ecn(_ o: nw_protocol_options_t, _ v: Bool) { nwTCP(o)?.disableECN = v }
@_cdecl("nw_tcp_options_set_multipath_force_version")
public func finch_nw_tcp_options_set_multipath_force_version(_ o: nw_protocol_options_t, _ v: nw_multipath_version_t) {}

@_cdecl("nw_tcp_get_available_receive_buffer")
public func finch_nw_tcp_get_available_receive_buffer(_ m: nw_protocol_metadata_t) -> UInt32 {
    nwMetadata(m, NWProtocolTCP.Metadata.self)?.availableReceiveBuffer ?? 0
}
@_cdecl("nw_tcp_get_available_send_buffer")
public func finch_nw_tcp_get_available_send_buffer(_ m: nw_protocol_metadata_t) -> UInt32 {
    nwMetadata(m, NWProtocolTCP.Metadata.self)?.availableSendBuffer ?? 0
}

// UDP

@_cdecl("nw_udp_create_options")
public func finch_nw_udp_create_options() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolOptions(NWProtocolUDP.Options())) }
@_cdecl("nw_udp_options_set_prefer_no_checksum")
public func finch_nw_udp_options_set_prefer_no_checksum(_ o: nw_protocol_options_t, _ v: Bool) {
    nwOptions(o, NWProtocolUDP.Options.self)?.preferNoChecksum = v
}
@_cdecl("nw_udp_create_metadata")
public func finch_nw_udp_create_metadata() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolMetadata(NWProtocolUDP.Metadata())) }

// TLS

@_cdecl("nw_tls_create_options")
public func finch_nw_tls_create_options() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolOptions(NWProtocolTLS.Options())) }

@_cdecl("nw_tls_copy_sec_protocol_options")
public func finch_nw_tls_copy_sec_protocol_options(_ o: nw_protocol_options_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwOptions(o, NWProtocolTLS.Options.self)?.securityProtocolOptions as AnyObject?)
}

@_cdecl("nw_tls_copy_sec_protocol_metadata")
public func finch_nw_tls_copy_sec_protocol_metadata(_ m: nw_protocol_metadata_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwMetadata(m, NWProtocolTLS.Metadata.self)?.securityProtocolMetadata as AnyObject?)
}

// IP

func nwIP(_ o: nw_protocol_options_t) -> NWProtocolIP.Options? { nwOptions(o, NWProtocolIP.Options.self) }

@_cdecl("nw_ip_options_set_version")
public func finch_nw_ip_options_set_version(_ o: nw_protocol_options_t, _ v: nw_ip_version_t) {
    nwIP(o)?.version = v.rawValue == nw_ip_version_4.rawValue ? .v4 : v.rawValue == nw_ip_version_6.rawValue ? .v6 : .any
}
@_cdecl("nw_ip_options_set_hop_limit")
public func finch_nw_ip_options_set_hop_limit(_ o: nw_protocol_options_t, _ v: UInt8) { nwIP(o)?.hopLimit = v }
@_cdecl("nw_ip_options_set_use_minimum_mtu")
public func finch_nw_ip_options_set_use_minimum_mtu(_ o: nw_protocol_options_t, _ v: Bool) { nwIP(o)?.useMinimumMTU = v }
@_cdecl("nw_ip_options_set_disable_fragmentation")
public func finch_nw_ip_options_set_disable_fragmentation(_ o: nw_protocol_options_t, _ v: Bool) { nwIP(o)?.disableFragmentation = v }
@_cdecl("nw_ip_options_set_calculate_receive_time")
public func finch_nw_ip_options_set_calculate_receive_time(_ o: nw_protocol_options_t, _ v: Bool) { nwIP(o)?.shouldCalculateReceiveTime = v }
@_cdecl("nw_ip_options_set_disable_multicast_loopback")
public func finch_nw_ip_options_set_disable_multicast_loopback(_ o: nw_protocol_options_t, _ v: Bool) { nwIP(o)?.disableMulticastLoopback = v }
@_cdecl("nw_ip_options_set_local_address_preference")
public func finch_nw_ip_options_set_local_address_preference(_ o: nw_protocol_options_t, _ v: nw_ip_local_address_preference_t) {
    nwIP(o)?.localAddressPreference = v.rawValue == nw_ip_local_address_preference_temporary.rawValue ? .temporary
        : v.rawValue == nw_ip_local_address_preference_stable.rawValue ? .stable : .default
}

@_cdecl("nw_ip_create_metadata")
public func finch_nw_ip_create_metadata() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteProtocolMetadata(NWProtocolIP.Metadata())) }

func nwIPMetadata(_ m: nw_protocol_metadata_t) -> NWProtocolIP.Metadata? { nwMetadata(m, NWProtocolIP.Metadata.self) }

@_cdecl("nw_ip_metadata_set_ecn_flag")
public func finch_nw_ip_metadata_set_ecn_flag(_ m: nw_protocol_metadata_t, _ v: nw_ip_ecn_flag_t) {
    nwIPMetadata(m)?.ecnFlag = [NWProtocolIP.ECN.nonECT, .ect1, .ect0, .ce][Int(min(v.rawValue, 3))]
}
@_cdecl("nw_ip_metadata_get_ecn_flag")
public func finch_nw_ip_metadata_get_ecn_flag(_ m: nw_protocol_metadata_t) -> nw_ip_ecn_flag_t {
    switch nwIPMetadata(m)?.ecnFlag ?? .nonECT {
    case .nonECT: return nw_ip_ecn_flag_non_ect
    case .ect1: return nw_ip_ecn_flag_ect_1
    case .ect0: return nw_ip_ecn_flag_ect_0
    case .ce: return nw_ip_ecn_flag_ce
    }
}

func nwServiceClass(_ c: NWParameters.ServiceClass) -> nw_service_class_t {
    switch c {
    case .bestEffort: return nw_service_class_best_effort
    case .background: return nw_service_class_background
    case .interactiveVideo: return nw_service_class_interactive_video
    case .interactiveVoice: return nw_service_class_interactive_voice
    case .responsiveData: return nw_service_class_responsive_data
    case .signaling: return nw_service_class_signaling
    }
}

func nwServiceClass(_ c: nw_service_class_t) -> NWParameters.ServiceClass {
    switch c.rawValue {
    case nw_service_class_background.rawValue: return .background
    case nw_service_class_interactive_video.rawValue: return .interactiveVideo
    case nw_service_class_interactive_voice.rawValue: return .interactiveVoice
    case nw_service_class_responsive_data.rawValue: return .responsiveData
    case nw_service_class_signaling.rawValue: return .signaling
    default: return .bestEffort
    }
}

@_cdecl("nw_ip_metadata_set_service_class")
public func finch_nw_ip_metadata_set_service_class(_ m: nw_protocol_metadata_t, _ v: nw_service_class_t) {
    nwIPMetadata(m)?.serviceClass = nwServiceClass(v)
}
@_cdecl("nw_ip_metadata_get_service_class")
public func finch_nw_ip_metadata_get_service_class(_ m: nw_protocol_metadata_t) -> nw_service_class_t {
    nwServiceClass(nwIPMetadata(m)?.serviceClass ?? .bestEffort)
}
@_cdecl("nw_ip_metadata_get_receive_time")
public func finch_nw_ip_metadata_get_receive_time(_ m: nw_protocol_metadata_t) -> UInt64 { nwIPMetadata(m)?.receiveTime ?? 0 }

// MARK: - Parameters and protocol stacks

@objc(NWConcrete_nw_parameters)
final class NWConcreteParameters: NSObject, OS_nw_parameters {
    let parameters: NWParameters
    var privacyContext: AnyObject?
    var requiresDNSSEC = false
    var allowUltraConstrained = false
    var fastOpen = false
    init(_ parameters: NWParameters) {
        self.parameters = parameters
        super.init()
    }
    override var description: String { parameters.debugDescription }
}

func nwParameters(_ object: nw_parameters_t?) -> NWParameters? { (object as AnyObject?).flatMap { ($0 as? NWConcreteParameters)?.parameters } }

@objc(NWConcrete_nw_protocol_stack)
final class NWConcreteProtocolStack: NSObject, OS_nw_protocol_stack {
    let stack: NWParameters.ProtocolStack
    init(_ stack: NWParameters.ProtocolStack) {
        self.stack = stack
        super.init()
    }
}


/* The headers' NW_PARAMETERS_DEFAULT_CONFIGURATION and NW_PARAMETERS_DISABLE_PROTOCOL
   (network.m's blocks), told apart from callers' blocks by identity. */
@_silgen_name("finch_nw_configure_is_disable")
func nwConfigureIsDisable(_ block: AnyObject) -> Bool

@_silgen_name("finch_nw_configure_is_default")
func nwConfigureIsDefault(_ block: AnyObject) -> Bool

func nwApply(_ block: @convention(block) (nw_protocol_options_t) -> Void, _ options: NWProtocolOptions) {
    if nwConfigureIsDefault(block as AnyObject) { return }
    block(NWConcreteProtocolOptions(options))
}

@_cdecl("nw_parameters_create")
public func finch_nw_parameters_create() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteParameters(NWParameters())) }

@_cdecl("nw_parameters_create_secure_tcp")
public func finch_nw_parameters_create_secure_tcp(_ tls: @convention(block) (nw_protocol_options_t) -> Void, _ tcp: @convention(block) (nw_protocol_options_t) -> Void) -> UnsafeMutableRawPointer? {
    let p = NWParameters(tls: nwConfigureIsDisable(tls as AnyObject) ? nil : NWProtocolTLS.Options())
    if let options = p.tlsOptions { nwApply(tls, options) }
    nwApply(tcp, p.tcpOptions)
    return nwRetained(NWConcreteParameters(p))
}

@_cdecl("nw_parameters_create_secure_udp")
public func finch_nw_parameters_create_secure_udp(_ dtls: @convention(block) (nw_protocol_options_t) -> Void, _ udp: @convention(block) (nw_protocol_options_t) -> Void) -> UnsafeMutableRawPointer? {
    let p = NWParameters(dtls: nwConfigureIsDisable(dtls as AnyObject) ? nil : NWProtocolTLS.Options())
    if let options = p.tlsOptions { nwApply(dtls, options) }
    nwApply(udp, p.udpOptions)
    return nwRetained(NWConcreteParameters(p))
}

@_cdecl("nw_parameters_create_custom_ip")
public func finch_nw_parameters_create_custom_ip(_ protocolNumber: UInt8, _ ip: @convention(block) (nw_protocol_options_t) -> Void) -> UnsafeMutableRawPointer? {
    let p = NWParameters(dtls: nil)
    nwApply(ip, p.ipOptions)
    return nwRetained(NWConcreteParameters(p))
}

@_cdecl("nw_parameters_create_application_service")
public func finch_nw_parameters_create_application_service() -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteParameters(NWParameters.applicationService))
}

@_cdecl("nw_parameters_copy")
public func finch_nw_parameters_copy(_ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let c = parameters as AnyObject as? NWConcreteParameters else { return nil }
    let copy = NWConcreteParameters(c.parameters.copy())
    copy.privacyContext = c.privacyContext
    copy.requiresDNSSEC = c.requiresDNSSEC
    copy.allowUltraConstrained = c.allowUltraConstrained
    copy.fastOpen = c.fastOpen
    return nwRetained(copy)
}

@_cdecl("nw_parameters_copy_default_protocol_stack")
public func finch_nw_parameters_copy_default_protocol_stack(_ parameters: nw_parameters_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwParameters(parameters).map { NWConcreteProtocolStack($0.defaultProtocolStack) })
}

func nwStack(_ s: nw_protocol_stack_t) -> NWParameters.ProtocolStack? { (s as AnyObject as? NWConcreteProtocolStack)?.stack }

@_cdecl("nw_protocol_stack_prepend_application_protocol")
public func finch_nw_protocol_stack_prepend_application_protocol(_ stack: nw_protocol_stack_t, _ protocolOptions: nw_protocol_options_t) {
    guard let s = nwStack(stack), let o = (protocolOptions as AnyObject as? NWConcreteProtocolOptions)?.options else { return }
    s.applicationProtocols.insert(o, at: 0)
}

@_cdecl("nw_protocol_stack_clear_application_protocols")
public func finch_nw_protocol_stack_clear_application_protocols(_ stack: nw_protocol_stack_t) { nwStack(stack)?.applicationProtocols = [] }

@_cdecl("nw_protocol_stack_iterate_application_protocols")
public func finch_nw_protocol_stack_iterate_application_protocols(_ stack: nw_protocol_stack_t,
                                                                 _ block: @convention(block) (nw_protocol_options_t) -> Void) {
    for o in nwStack(stack)?.applicationProtocols ?? [] { block(NWConcreteProtocolOptions(o)) }
}

@_cdecl("nw_protocol_stack_copy_transport_protocol")
public func finch_nw_protocol_stack_copy_transport_protocol(_ stack: nw_protocol_stack_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwStack(stack)?.transportProtocol.map { NWConcreteProtocolOptions($0) })
}

@_cdecl("nw_protocol_stack_set_transport_protocol")
public func finch_nw_protocol_stack_set_transport_protocol(_ stack: nw_protocol_stack_t, _ protocolOptions: nw_protocol_options_t) {
    nwStack(stack)?.transportProtocol = (protocolOptions as AnyObject as? NWConcreteProtocolOptions)?.options
}

@_cdecl("nw_protocol_stack_copy_internet_protocol")
public func finch_nw_protocol_stack_copy_internet_protocol(_ stack: nw_protocol_stack_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwStack(stack)?.internetProtocol.map { NWConcreteProtocolOptions($0) })
}

// Parameter settings

@_cdecl("nw_parameters_require_interface")
public func finch_nw_parameters_require_interface(_ p: nw_parameters_t, _ i: nw_interface_t?) {
    nwParameters(p)?.requiredInterface = (i as AnyObject as? NWConcreteInterface)?.interface
}
@_cdecl("nw_parameters_copy_required_interface")
public func finch_nw_parameters_copy_required_interface(_ p: nw_parameters_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwParameters(p)?.requiredInterface.map { NWConcreteInterface($0) })
}
@_cdecl("nw_parameters_prohibit_interface")
public func finch_nw_parameters_prohibit_interface(_ p: nw_parameters_t, _ i: nw_interface_t) {
    guard let parameters = nwParameters(p), let interface = (i as AnyObject as? NWConcreteInterface)?.interface else { return }
    parameters.prohibitedInterfaces = (parameters.prohibitedInterfaces ?? []) + [interface]
}
@_cdecl("nw_parameters_clear_prohibited_interfaces")
public func finch_nw_parameters_clear_prohibited_interfaces(_ p: nw_parameters_t) { nwParameters(p)?.prohibitedInterfaces = nil }
@_cdecl("nw_parameters_iterate_prohibited_interfaces")
public func finch_nw_parameters_iterate_prohibited_interfaces(_ p: nw_parameters_t, _ block: @convention(block) (nw_interface_t) -> Bool) {
    for i in nwParameters(p)?.prohibitedInterfaces ?? [] where !block(NWConcreteInterface(i)) { break }
}
@_cdecl("nw_parameters_set_required_interface_type")
public func finch_nw_parameters_set_required_interface_type(_ p: nw_parameters_t, _ t: nw_interface_type_t) {
    nwParameters(p)?.requiredInterfaceType = nwInterfaceType(t)
}
@_cdecl("nw_parameters_get_required_interface_type")
public func finch_nw_parameters_get_required_interface_type(_ p: nw_parameters_t) -> nw_interface_type_t {
    nwInterfaceType(nwParameters(p)?.requiredInterfaceType ?? .other)
}
@_cdecl("nw_parameters_prohibit_interface_type")
public func finch_nw_parameters_prohibit_interface_type(_ p: nw_parameters_t, _ t: nw_interface_type_t) {
    guard let parameters = nwParameters(p) else { return }
    parameters.prohibitedInterfaceTypes = (parameters.prohibitedInterfaceTypes ?? []) + [nwInterfaceType(t)]
}
@_cdecl("nw_parameters_clear_prohibited_interface_types")
public func finch_nw_parameters_clear_prohibited_interface_types(_ p: nw_parameters_t) { nwParameters(p)?.prohibitedInterfaceTypes = nil }
@_cdecl("nw_parameters_iterate_prohibited_interface_types")
public func finch_nw_parameters_iterate_prohibited_interface_types(_ p: nw_parameters_t, _ block: @convention(block) (nw_interface_type_t) -> Bool) {
    for t in nwParameters(p)?.prohibitedInterfaceTypes ?? [] where !block(nwInterfaceType(t)) { break }
}
@_cdecl("nw_parameters_set_prohibit_expensive")
public func finch_nw_parameters_set_prohibit_expensive(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.prohibitExpensivePaths = v }
@_cdecl("nw_parameters_get_prohibit_expensive")
public func finch_nw_parameters_get_prohibit_expensive(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.prohibitExpensivePaths ?? false }
@_cdecl("nw_parameters_set_prohibit_constrained")
public func finch_nw_parameters_set_prohibit_constrained(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.prohibitConstrainedPaths = v }
@_cdecl("nw_parameters_get_prohibit_constrained")
public func finch_nw_parameters_get_prohibit_constrained(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.prohibitConstrainedPaths ?? false }
@_cdecl("nw_parameters_set_allow_ultra_constrained")
public func finch_nw_parameters_set_allow_ultra_constrained(_ p: nw_parameters_t, _ v: Bool) {
    (p as AnyObject as? NWConcreteParameters)?.allowUltraConstrained = v
}
@_cdecl("nw_parameters_get_allow_ultra_constrained")
public func finch_nw_parameters_get_allow_ultra_constrained(_ p: nw_parameters_t) -> Bool {
    (p as AnyObject as? NWConcreteParameters)?.allowUltraConstrained ?? false
}
@_cdecl("nw_parameters_set_reuse_local_address")
public func finch_nw_parameters_set_reuse_local_address(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.allowLocalEndpointReuse = v }
@_cdecl("nw_parameters_get_reuse_local_address")
public func finch_nw_parameters_get_reuse_local_address(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.allowLocalEndpointReuse ?? false }
@_cdecl("nw_parameters_set_local_endpoint")
public func finch_nw_parameters_set_local_endpoint(_ p: nw_parameters_t, _ e: nw_endpoint_t?) {
    nwParameters(p)?.requiredLocalEndpoint = nwEndpoint(e)
}
@_cdecl("nw_parameters_copy_local_endpoint")
public func finch_nw_parameters_copy_local_endpoint(_ p: nw_parameters_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwParameters(p)?.requiredLocalEndpoint.map { NWConcreteEndpoint($0) })
}
@_cdecl("nw_parameters_set_include_peer_to_peer")
public func finch_nw_parameters_set_include_peer_to_peer(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.includePeerToPeer = v }
@_cdecl("nw_parameters_get_include_peer_to_peer")
public func finch_nw_parameters_get_include_peer_to_peer(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.includePeerToPeer ?? false }
@_cdecl("nw_parameters_set_fast_open_enabled")
public func finch_nw_parameters_set_fast_open_enabled(_ p: nw_parameters_t, _ v: Bool) { (p as AnyObject as? NWConcreteParameters)?.fastOpen = v }
@_cdecl("nw_parameters_get_fast_open_enabled")
public func finch_nw_parameters_get_fast_open_enabled(_ p: nw_parameters_t) -> Bool { (p as AnyObject as? NWConcreteParameters)?.fastOpen ?? false }
@_cdecl("nw_parameters_set_service_class")
public func finch_nw_parameters_set_service_class(_ p: nw_parameters_t, _ v: nw_service_class_t) { nwParameters(p)?.serviceClass = nwServiceClass(v) }
@_cdecl("nw_parameters_get_service_class")
public func finch_nw_parameters_get_service_class(_ p: nw_parameters_t) -> nw_service_class_t {
    nwServiceClass(nwParameters(p)?.serviceClass ?? .bestEffort)
}
@_cdecl("nw_parameters_set_multipath_service")
public func finch_nw_parameters_set_multipath_service(_ p: nw_parameters_t, _ v: nw_multipath_service_t) {
    let types: [NWParameters.MultipathServiceType] = [.disabled, .handover, .interactive, .aggregate]
    nwParameters(p)?.multipathServiceType = types[Int(min(v.rawValue, 3))]
}
@_cdecl("nw_parameters_get_multipath_service")
public func finch_nw_parameters_get_multipath_service(_ p: nw_parameters_t) -> nw_multipath_service_t {
    let types: [NWParameters.MultipathServiceType] = [.disabled, .handover, .interactive, .aggregate]
    return nw_multipath_service_t(rawValue: UInt32(types.firstIndex(of: nwParameters(p)?.multipathServiceType ?? .disabled) ?? 0))
}
@_cdecl("nw_parameters_set_local_only")
public func finch_nw_parameters_set_local_only(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.acceptLocalOnly = v }
@_cdecl("nw_parameters_get_local_only")
public func finch_nw_parameters_get_local_only(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.acceptLocalOnly ?? false }
@_cdecl("nw_parameters_set_prefer_no_proxy")
public func finch_nw_parameters_set_prefer_no_proxy(_ p: nw_parameters_t, _ v: Bool) { nwParameters(p)?.preferNoProxies = v }
@_cdecl("nw_parameters_get_prefer_no_proxy")
public func finch_nw_parameters_get_prefer_no_proxy(_ p: nw_parameters_t) -> Bool { nwParameters(p)?.preferNoProxies ?? false }
@_cdecl("nw_parameters_set_expired_dns_behavior")
public func finch_nw_parameters_set_expired_dns_behavior(_ p: nw_parameters_t, _ v: nw_parameters_expired_dns_behavior_t) {
    let values: [NWParameters.ExpiredDNSBehavior] = [.systemDefault, .allow, .prohibit, .persistent]
    nwParameters(p)?.expiredDNSBehavior = values[Int(min(v.rawValue, 3))]
}
@_cdecl("nw_parameters_get_expired_dns_behavior")
public func finch_nw_parameters_get_expired_dns_behavior(_ p: nw_parameters_t) -> nw_parameters_expired_dns_behavior_t {
    let values: [NWParameters.ExpiredDNSBehavior] = [.systemDefault, .allow, .prohibit, .persistent]
    return nw_parameters_expired_dns_behavior_t(rawValue: UInt32(values.firstIndex(of: nwParameters(p)?.expiredDNSBehavior ?? .systemDefault) ?? 0))
}
@_cdecl("nw_parameters_set_attribution")
public func finch_nw_parameters_set_attribution(_ p: nw_parameters_t, _ v: nw_parameters_attribution_t) {
    nwParameters(p)?.attribution = v.rawValue == nw_parameters_attribution_t.user.rawValue ? .user : .developer
}
@_cdecl("nw_parameters_get_attribution")
public func finch_nw_parameters_get_attribution(_ p: nw_parameters_t) -> nw_parameters_attribution_t {
    nwParameters(p)?.attribution == .user ? .user : .developer
}
@_cdecl("nw_parameters_set_requires_dnssec_validation")
public func finch_nw_parameters_set_requires_dnssec_validation(_ p: nw_parameters_t, _ v: Bool) {
    (p as AnyObject as? NWConcreteParameters)?.requiresDNSSEC = v
}
@_cdecl("nw_parameters_requires_dnssec_validation")
public func finch_nw_parameters_requires_dnssec_validation(_ p: nw_parameters_t) -> Bool {
    (p as AnyObject as? NWConcreteParameters)?.requiresDNSSEC ?? false
}
@_cdecl("nw_parameters_set_privacy_context")
public func finch_nw_parameters_set_privacy_context(_ p: nw_parameters_t, _ c: nw_privacy_context_t) {
    (p as AnyObject as? NWConcreteParameters)?.privacyContext = c as AnyObject
}

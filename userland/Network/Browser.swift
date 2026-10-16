// SPDX-License-Identifier: MIT OR Apache-2.0
import Darwin
import Dispatch
import Foundation

public struct NWTXTRecord: Sendable, Hashable, CustomDebugStringConvertible, Collection {
    public enum Entry: Hashable, CustomDebugStringConvertible, Sendable {
        case none
        case empty
        case string(String)
        case data(Data)

        public var data: Data? {
            switch self {
            case .none: return nil
            case .empty: return Data()
            case let .string(value): return Data(value.utf8)
            case let .data(value): return value
            }
        }

        public init(_ data: Data?) {
            guard let data else { self = .none; return }
            guard !data.isEmpty else { self = .empty; return }
            self = String(data: data, encoding: .utf8).map(Entry.string) ?? .data(data)
        }

        public var debugDescription: String {
            switch self {
            case .none: return "none"
            case .empty: return "empty"
            case let .string(value): return value
            case let .data(value): return value.base64EncodedString()
            }
        }
    }

    public struct Index: Comparable, Hashable, Sendable {
        fileprivate let offset: Int
        public static func < (lhs: Index, rhs: Index) -> Bool { lhs.offset < rhs.offset }
    }

    private var values: [String: Entry]

    public init(_ dictionary: [String: String] = [:]) {
        values = dictionary.mapValues(Entry.string)
    }

    public init(_ data: Data) {
        values = [:]
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            guard offset + length <= bytes.count else { break }
            if length == 0 { continue }
            let item = Array(bytes[offset..<offset + length])
            offset += length
            let separator = item.firstIndex(of: 61)
            let keyBytes = separator.map { Array(item[..<$0]) } ?? item
            guard let key = String(bytes: keyBytes, encoding: .utf8), !key.isEmpty,
                  keyBytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { continue }
            guard let separator else { values[key] = Entry.none; continue }
            let valueBytes = Array(item[(separator + 1)...])
            if valueBytes.isEmpty { values[key] = .empty }
            else if let value = String(bytes: valueBytes, encoding: .utf8) { values[key] = .string(value) }
            else { values[key] = .data(Data(valueBytes)) }
        }
    }

    public init(_ dataDictionary: [String: Data]) { values = dataDictionary.mapValues(Entry.data) }
    public init(_ entryDictionary: [String: Entry]) { values = entryDictionary }

    public var entries: [String: Entry] { values }
    public var dictionary: [String: String] {
        values.reduce(into: [:]) { result, item in
            switch item.value {
            case .none: break
            case .empty: result[item.key] = ""
            case let .string(value): result[item.key] = value
            case let .data(value): result[item.key] = String(data: value, encoding: .utf8)
            }
        }
    }
    public var dataDictionary: [String: Data] {
        values.reduce(into: [:]) { result, item in
            if let data = item.value.data { result[item.key] = data }
        }
    }
    public var data: Data {
        var output = Data()
        for key in values.keys.sorted() {
            guard let entry = values[key] else { continue }
            var item = Data(key.utf8)
            switch entry {
            case .none: break
            case .empty: item.append(61)
            case let .string(value): item.append(61); item.append(contentsOf: value.utf8)
            case let .data(value): item.append(61); item.append(value)
            }
            guard item.count <= 255 else { continue }
            output.append(UInt8(item.count))
            output.append(item)
        }
        return output
    }

    public subscript(key: String) -> String? {
        get {
            switch values[key] {
            case nil, .some(.none): return nil
            case .some(.empty): return ""
            case let .some(.string(value)): return value
            case let .some(.data(value)): return String(data: value, encoding: .utf8)
            }
        }
        set { values[key] = newValue.map(Entry.string) }
    }

    public func getEntry(for key: String) -> Entry? { values[key] }
    @discardableResult public mutating func setEntry(_ entry: Entry, for key: String) -> Bool {
        guard !key.isEmpty, !key.contains("=") else { return false }
        values[key] = entry
        return true
    }
    @discardableResult public mutating func removeEntry(key: String) -> Bool { values.removeValue(forKey: key) != nil }

    public var startIndex: Index { Index(offset: 0) }
    public var endIndex: Index { Index(offset: values.count) }
    public subscript(position: Index) -> (key: String, value: Entry) {
        let key = values.keys.sorted()[position.offset]
        return (key, values[key]!)
    }
    public func index(after index: Index) -> Index { Index(offset: index.offset + 1) }
    public var debugDescription: String { "NWTXTRecord(\(dictionary))" }

    public func hash(into hasher: inout Hasher) {
        for key in values.keys.sorted() { hasher.combine(key); hasher.combine(values[key]) }
    }
    public static func == (lhs: NWTXTRecord, rhs: NWTXTRecord) -> Bool { lhs.values == rhs.values }
}

@_silgen_name("finch_network_dns_browse")
private func finchDNSBrowse(_ type: UnsafePointer<CChar>, _ domain: UnsafePointer<CChar>?,
                            _ callback: DNSBrowseCallback, _ client: UnsafeMutableRawPointer?,
                            _ error: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?
@_silgen_name("finch_network_dns_fd")
private func finchDNSFileDescriptor(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_process")
private func finchDNSProcess(_ service: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("finch_network_dns_cancel")
private func finchDNSCancel(_ service: UnsafeMutableRawPointer?)
@_silgen_name("finch_network_dns_resolve")
private func finchDNSResolve(_ name: UnsafePointer<CChar>, _ type: UnsafePointer<CChar>,
                             _ domain: UnsafePointer<CChar>, _ interfaceIndex: UInt32,
                             _ callback: DNSResolveCallback, _ client: UnsafeMutableRawPointer?,
                             _ error: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?

private typealias DNSBrowseCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias DNSResolveCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt16, UInt16, UnsafePointer<UInt8>?) -> Void

private struct DNSResolveEntry {
    let source: DispatchSourceRead
}

private final class DNSResolveContext: @unchecked Sendable {
    weak var browser: NWBrowser?
    let endpoint: NWEndpoint

    init(browser: NWBrowser, endpoint: NWEndpoint) {
        self.browser = browser
        self.endpoint = endpoint
    }
}

private let networkBrowseCallback: DNSBrowseCallback = { context, flags, interfaceIndex, error, name, type, domain in
    guard let context else { return }
    Unmanaged<NWBrowser>.fromOpaque(context).takeUnretainedValue().receivedBrowse(
        flags: flags, interfaceIndex: interfaceIndex, error: error,
        name: name.map(String.init(cString:)), type: type.map(String.init(cString:)),
        domain: domain.map(String.init(cString:)))
}

private let networkResolveCallback: DNSResolveCallback = { context, _, _, error, _, _, _, txtLength, txt in
    guard let context else { return }
    let resolved = Unmanaged<DNSResolveContext>.fromOpaque(context).takeUnretainedValue()
    let data = txt.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
    resolved.browser?.receivedResolve(endpoint: resolved.endpoint, error: error, txt: data)
}

final public class NWBrowser: CustomDebugStringConvertible, @unchecked Sendable {
    public enum Descriptor: Sendable {
        case bonjour(type: String, domain: String?)
        case bonjourWithTXTRecord(type: String, domain: String?)
        case applicationService(name: String)
    }

    public struct Result: Hashable, Sendable {
        public let endpoint: NWEndpoint
        public let interfaces: [NWInterface]
        public let metadata: Metadata

        public enum Metadata: Equatable, Hashable, CustomDebugStringConvertible, Sendable {
            case none
            case bonjour(NWTXTRecord)
            public var debugDescription: String {
                switch self {
                case .none: return "none"
                case let .bonjour(record): return record.debugDescription
                }
            }
        }

        public enum Change: Hashable, Sendable {
            public struct Flags: OptionSet, Hashable, Sendable {
                public let rawValue: UInt8
                public init(rawValue: UInt8) { self.rawValue = rawValue }
                public static let identical = Flags(rawValue: 1 << 0)
                public static let interfaceAdded = Flags(rawValue: 1 << 1)
                public static let interfaceRemoved = Flags(rawValue: 1 << 2)
                public static let metadataChanged = Flags(rawValue: 1 << 3)
            }

            case identical
            case added(Result)
            case removed(Result)
            case changed(old: Result, new: Result, flags: Flags)

            public init(between old: Result?, _ new: Result?) {
                switch (old, new) {
                case (nil, nil): self = .identical
                case (nil, let new?): self = .added(new)
                case (let old?, nil): self = .removed(old)
                case (let old?, let new?):
                    if old == new { self = .identical; return }
                    var flags: Flags = []
                    if !Set(new.interfaces).subtracting(old.interfaces).isEmpty { flags.insert(.interfaceAdded) }
                    if !Set(old.interfaces).subtracting(new.interfaces).isEmpty { flags.insert(.interfaceRemoved) }
                    if old.metadata != new.metadata { flags.insert(.metadataChanged) }
                    self = .changed(old: old, new: new, flags: flags)
                }
            }
        }

        public var hashValue: Int { hashValueCompat }
        private var hashValueCompat: Int {
            var hasher = Hasher(); hash(into: &hasher); return hasher.finalize()
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(endpoint)
            hasher.combine(interfaces)
            hasher.combine(metadata)
        }
        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.endpoint == rhs.endpoint && lhs.interfaces == rhs.interfaces && lhs.metadata == rhs.metadata
        }
    }

    public enum State: Equatable, Sendable {
        case setup
        case ready
        case failed(NWError)
        case cancelled
        case waiting(NWError)
    }

    public final let descriptor: Descriptor
    public final let parameters: NWParameters
    private let lock = NSLock()
    private var currentState: State = .setup
    private var stateHandler: (@Sendable (State) -> Void)?
    private var resultsHandler: (@Sendable (Set<Result>, Set<Result.Change>) -> Void)?
    private var results: Set<Result> = []
    private var workQueue: DispatchQueue?
    private var dnsService: UnsafeMutableRawPointer?
    private var readSource: DispatchSourceRead?
    private var resolvers: [NWEndpoint: DNSResolveEntry] = [:]

    public init(for descriptor: Descriptor, using parameters: NWParameters) {
        self.descriptor = descriptor
        self.parameters = parameters
    }

    public var state: State { lock.withLock { currentState } }
    public var browseResults: Set<Result> { lock.withLock { results } }
    public var queue: DispatchQueue? { lock.withLock { workQueue } }

    @preconcurrency
    public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    @preconcurrency
    public var browseResultsChangedHandler: (@Sendable (Set<Result>, Set<Result.Change>) -> Void)? {
        get { lock.withLock { resultsHandler } }
        set { lock.withLock { resultsHandler = newValue } }
    }

    public func start(queue: DispatchQueue) {
        let start = lock.withLock { () -> Bool in
            guard currentState == .setup, workQueue == nil else { return false }
            workQueue = queue
            return true
        }
        guard start else { return }
        queue.async { [weak self] in self?.beginBrowsing() }
    }

    public func cancel() {
        let (service, source, resolverEntries) = lock.withLock { () -> (UnsafeMutableRawPointer?, DispatchSourceRead?, [DNSResolveEntry]) in
            let service = dnsService
            let source = readSource
            let resolverEntries = Array(resolvers.values)
            dnsService = nil
            readSource = nil
            resolvers.removeAll()
            return (service, source, resolverEntries)
        }
        source?.cancel()
        if source == nil { finchDNSCancel(service) }
        for entry in resolverEntries { entry.source.cancel() }
        transition(to: .cancelled)
    }

    public var debugDescription: String { "NWBrowser(\(state))" }

    fileprivate func receivedBrowse(flags: UInt32, interfaceIndex: UInt32, error: Int32,
                                     name: String?, type: String?, domain: String?) {
        guard state != .cancelled else { return }
        guard error == 0, let name, let type, let domain else {
            if error != 0 { transition(to: .failed(.dns(error))) }
            return
        }
        let interface = interfaceIndex == 0 ? nil : interfaceForIndex(interfaceIndex)
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
        let added = flags & 2 != 0
        let resolvesTXT: Bool
        if case .bonjourWithTXTRecord = descriptor { resolvesTXT = true } else { resolvesTXT = false }
        if added && resolvesTXT {
            beginResolving(endpoint, interfaceIndex: interfaceIndex)
            return
        }
        if !added { cancelResolver(for: endpoint) }
        let result = Result(endpoint: endpoint, interfaces: interface.map { [$0] } ?? [], metadata: .none)
        let (allResults, changes, handler, queue) = lock.withLock { () -> (Set<Result>, Set<Result.Change>, (@Sendable (Set<Result>, Set<Result.Change>) -> Void)?, DispatchQueue?) in
            let old = results.first { $0.endpoint == endpoint }
            if added {
                results.remove(old ?? result)
                results.insert(result)
                return (results, [.init(between: old, result)], resultsHandler, workQueue)
            }
            guard let old else { return (results, [], resultsHandler, workQueue) }
            results.remove(old)
            return (results, [.init(between: old, nil)], resultsHandler, workQueue)
        }
        if let handler, let queue, !changes.isEmpty { queue.async { handler(allResults, changes) } }
    }

    fileprivate func receivedResolve(endpoint: NWEndpoint, error: Int32, txt: Data) {
        cancelResolver(for: endpoint)
        guard state != .cancelled else { return }
        guard error == 0 else { transition(to: .failed(.dns(error))); return }
        let interface = endpoint.interface
        let result = Result(endpoint: endpoint, interfaces: interface.map { [$0] } ?? [],
                            metadata: .bonjour(NWTXTRecord(txt)))
        let (allResults, changes, handler, queue) = lock.withLock { () -> (Set<Result>, Set<Result.Change>, (@Sendable (Set<Result>, Set<Result.Change>) -> Void)?, DispatchQueue?) in
            let old = results.first { $0.endpoint == endpoint }
            results.remove(old ?? result)
            results.insert(result)
            return (results, [.init(between: old, result)], resultsHandler, workQueue)
        }
        if let handler, let queue, !changes.isEmpty { queue.async { handler(allResults, changes) } }
    }

    private func beginResolving(_ endpoint: NWEndpoint, interfaceIndex: UInt32) {
        guard case let .service(name, type, domain, _) = endpoint, let queue else { return }
        cancelResolver(for: endpoint)
        let context = Unmanaged.passRetained(DNSResolveContext(browser: self, endpoint: endpoint))
        var error: Int32 = 0
        let handle = name.withCString { namePointer in
            type.withCString { typePointer in
                domain.withCString { domainPointer in
                    finchDNSResolve(namePointer, typePointer, domainPointer, interfaceIndex,
                                    networkResolveCallback, context.toOpaque(), &error)
                }
            }
        }
        guard let handle else {
            context.release()
            transition(to: .failed(.dns(error)))
            return
        }
        let fd = finchDNSFileDescriptor(handle)
        guard fd >= 0 else {
            finchDNSCancel(handle)
            context.release()
            transition(to: .failed(.dns(-65540)))
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let status = finchDNSProcess(handle)
            if status != 0 { self?.transition(to: .failed(.dns(status))) }
        }
        source.setCancelHandler {
            finchDNSCancel(handle)
            context.release()
        }
        let installed = lock.withLock { () -> Bool in
            guard currentState != .cancelled else { return false }
            resolvers[endpoint] = DNSResolveEntry(source: source)
            return true
        }
        guard installed else { source.resume(); source.cancel(); return }
        source.resume()
    }

    private func cancelResolver(for endpoint: NWEndpoint) {
        let entry = lock.withLock { resolvers.removeValue(forKey: endpoint) }
        entry?.source.cancel()
    }

    private func beginBrowsing() {
        guard state == .setup, let queue else { return }
        guard !parameters.hasUnsupportedRoutingPolicy else {
            transition(to: .failed(.posix(POSIXErrorCode(rawValue: EOPNOTSUPP) ?? .EIO)))
            return
        }
        let type: String
        let domain: String?
        switch descriptor {
        case let .bonjour(value, selectedDomain), let .bonjourWithTXTRecord(value, selectedDomain):
            type = value
            domain = selectedDomain
        case .applicationService:
            transition(to: .failed(.posix(POSIXErrorCode(rawValue: EOPNOTSUPP) ?? .EIO)))
            return
        }
        var error: Int32 = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handle = type.withCString { typePointer in
            if let domain { return domain.withCString { finchDNSBrowse(typePointer, $0, networkBrowseCallback, context, &error) } }
            return finchDNSBrowse(typePointer, nil, networkBrowseCallback, context, &error)
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
            guard let self, self.state != .cancelled else { return }
            let result = finchDNSProcess(handle)
            if result != 0 { self.transition(to: .failed(.dns(result))) }
        }
        source.setCancelHandler { finchDNSCancel(handle) }
        let installed = lock.withLock { () -> Bool in
            guard currentState != .cancelled else { return false }
            dnsService = handle
            readSource = source
            return true
        }
        guard installed else { source.resume(); source.cancel(); return }
        transition(to: .ready)
        source.resume()
    }

    private func transition(to state: State) {
        let (handler, queue) = lock.withLock { () -> ((@Sendable (State) -> Void)?, DispatchQueue?) in
            guard currentState != .cancelled, currentState != state else { return (nil, nil) }
            currentState = state
            return (stateHandler, workQueue)
        }
        if let handler, let queue { queue.async { handler(state) } }
    }

    deinit { cancel() }
}

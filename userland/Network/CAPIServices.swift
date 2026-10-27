// SPDX-License-Identifier: MIT OR Apache-2.0
// Network's C API: Bonjour browsing and advertising, TXT records, connection groups, and
// the privacy, proxy and resolver configurations parameters carry.
import Darwin
import Dispatch
import Foundation

// MARK: - TXT records

@objc(NWConcrete_nw_txt_record)
final class NWConcreteTXTRecord: NSObject, OS_nw_txt_record {
    var record: NWTXTRecord
    /* (a record made from bytes that aren't key=value pairs keeps them as they were) */
    var raw: Data?
    init(_ record: NWTXTRecord, raw: Data? = nil) {
        self.record = record
        self.raw = raw
        super.init()
    }
    var bytes: Data { raw ?? record.data }
}

func nwTXT(_ t: nw_txt_record_t?) -> NWConcreteTXTRecord? { t as AnyObject? as? NWConcreteTXTRecord }

/* Whether TXT bytes are well-formed length-prefixed key=value strings. */
func nwTXTIsDictionary(_ data: Data) -> Bool {
    var i = data.startIndex
    while i < data.endIndex {
        let length = Int(data[i])
        i += 1
        guard i + length <= data.endIndex else { return false }
        if length == 0 || data[i] == UInt8(ascii: "=") { return false }
        i += length
    }
    return true
}

@_cdecl("nw_txt_record_create_dictionary")
public func finch_nw_txt_record_create_dictionary() -> UnsafeMutableRawPointer? { nwRetained(NWConcreteTXTRecord(NWTXTRecord())) }

@_cdecl("nw_txt_record_create_with_bytes")
public func finch_nw_txt_record_create_with_bytes(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> UnsafeMutableRawPointer? {
    let data = Data(bytes: bytes, count: length)
    return nwRetained(NWConcreteTXTRecord(NWTXTRecord(data), raw: nwTXTIsDictionary(data) ? nil : data))
}

@_cdecl("nw_txt_record_copy")
public func finch_nw_txt_record_copy(_ t: nw_txt_record_t?) -> UnsafeMutableRawPointer? {
    nwRetained(nwTXT(t).map { NWConcreteTXTRecord($0.record, raw: $0.raw) })
}

func nwFindKey(_ entry: NWTXTRecord.Entry?) -> nw_txt_record_find_key_t {
    switch entry {
    case nil: return nw_txt_record_find_key_not_present
    case .none?: return nw_txt_record_find_key_no_value
    case .empty?: return nw_txt_record_find_key_empty_value
    case .string?, .data?: return nw_txt_record_find_key_non_empty_value
    }
}

@_cdecl("nw_txt_record_find_key")
public func finch_nw_txt_record_find_key(_ t: nw_txt_record_t, _ key: UnsafePointer<CChar>) -> nw_txt_record_find_key_t {
    guard let record = nwTXT(t), record.raw == nil else { return nw_txt_record_find_key_invalid }
    let k = String(cString: key)
    return nwFindKey(record.record.entries.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value)
}

@_cdecl("nw_txt_record_access_key")
public func finch_nw_txt_record_access_key(_ t: nw_txt_record_t, _ key: UnsafePointer<CChar>,
                                           _ access: @convention(block) (UnsafePointer<CChar>, nw_txt_record_find_key_t, UnsafePointer<UInt8>?, Int) -> Bool) -> Bool {
    guard let record = nwTXT(t) else { return false }
    let k = String(cString: key)
    let entry = record.raw == nil ? record.record.entries.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value : nil
    let found = record.raw == nil ? nwFindKey(entry) : nw_txt_record_find_key_invalid
    guard let value = entry?.data, !value.isEmpty else { return access(key, found, nil, 0) }
    return value.withUnsafeBytes { access(key, found, $0.bindMemory(to: UInt8.self).baseAddress, value.count) }
}

@_cdecl("nw_txt_record_set_key")
public func finch_nw_txt_record_set_key(_ t: nw_txt_record_t, _ key: UnsafePointer<CChar>, _ value: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard let record = nwTXT(t), record.raw == nil else { return false }
    let k = String(cString: key)
    guard !k.isEmpty, !k.contains("=") else { return false }
    let entry: NWTXTRecord.Entry = value == nil ? .none : NWTXTRecord.Entry(Data(bytes: value!, count: length))
    if let existing = record.record.entries.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
        record.record.removeEntry(key: existing)
    }
    return record.record.setEntry(entry, for: k)
}

@_cdecl("nw_txt_record_remove_key")
public func finch_nw_txt_record_remove_key(_ t: nw_txt_record_t, _ key: UnsafePointer<CChar>) -> Bool {
    guard let record = nwTXT(t), record.raw == nil else { return false }
    let k = String(cString: key)
    guard let existing = record.record.entries.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else { return false }
    return record.record.removeEntry(key: existing)
}

@_cdecl("nw_txt_record_get_key_count")
public func finch_nw_txt_record_get_key_count(_ t: nw_txt_record_t) -> Int {
    guard let record = nwTXT(t) else { return 0 }
    return record.raw == nil ? record.record.entries.count : 0
}

@_cdecl("nw_txt_record_access_bytes")
public func finch_nw_txt_record_access_bytes(_ t: nw_txt_record_t, _ access: @convention(block) (UnsafePointer<UInt8>, Int) -> Bool) -> Bool {
    guard let record = nwTXT(t) else { return false }
    var bytes = record.bytes
    if bytes.isEmpty { bytes = Data([0]) }
    return bytes.withUnsafeBytes { access($0.bindMemory(to: UInt8.self).baseAddress!, record.bytes.count) }
}

@_cdecl("nw_txt_record_apply")
public func finch_nw_txt_record_apply(_ t: nw_txt_record_t,
                                      _ applier: @convention(block) (UnsafePointer<CChar>, nw_txt_record_find_key_t, UnsafePointer<UInt8>?, Int) -> Bool) -> Bool {
    guard let record = nwTXT(t), record.raw == nil else { return false }
    for (key, entry) in record.record.entries.sorted(by: { $0.key < $1.key }) {
        let keepGoing: Bool = key.withCString { k in
            guard let value = entry.data, !value.isEmpty else { return applier(k, nwFindKey(entry), nil, 0) }
            return value.withUnsafeBytes { applier(k, nwFindKey(entry), $0.bindMemory(to: UInt8.self).baseAddress, value.count) }
        }
        if !keepGoing { return false }
    }
    return true
}

@_cdecl("nw_txt_record_is_equal")
public func finch_nw_txt_record_is_equal(_ a: nw_txt_record_t?, _ b: nw_txt_record_t?) -> Bool {
    guard let x = nwTXT(a), let y = nwTXT(b) else { return nwTXT(a) == nil && nwTXT(b) == nil }
    return x.raw == y.raw && x.record == y.record
}

@_cdecl("nw_txt_record_is_dictionary")
public func finch_nw_txt_record_is_dictionary(_ t: nw_txt_record_t) -> Bool { nwTXT(t)?.raw == nil }

// MARK: - Browsing

@objc(NWConcrete_nw_browse_descriptor)
final class NWConcreteBrowseDescriptor: NSObject, OS_nw_browse_descriptor {
    let type: String?, domain: String?, applicationService: String?
    var includeTXT = false
    let strings = NWCStrings()
    init(type: String?, domain: String?, applicationService: String?) {
        self.type = type
        self.domain = domain
        self.applicationService = applicationService
        super.init()
    }
    var descriptor: NWBrowser.Descriptor {
        if let applicationService { return .applicationService(name: applicationService) }
        return includeTXT ? .bonjourWithTXTRecord(type: type ?? "", domain: domain) : .bonjour(type: type ?? "", domain: domain)
    }
}

@_cdecl("nw_browse_descriptor_create_bonjour_service")
public func finch_nw_browse_descriptor_create_bonjour_service(_ type: UnsafePointer<CChar>, _ domain: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteBrowseDescriptor(type: String(cString: type), domain: nwString(domain), applicationService: nil))
}

@_cdecl("nw_browse_descriptor_create_application_service")
public func finch_nw_browse_descriptor_create_application_service(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteBrowseDescriptor(type: nil, domain: nil, applicationService: String(cString: name)))
}

func nwBrowseDescriptor(_ d: nw_browse_descriptor_t) -> NWConcreteBrowseDescriptor? { d as AnyObject as? NWConcreteBrowseDescriptor }

@_cdecl("nw_browse_descriptor_get_bonjour_service_type")
public func finch_nw_browse_descriptor_get_bonjour_service_type(_ d: nw_browse_descriptor_t) -> UnsafePointer<CChar>? {
    nwBrowseDescriptor(d).flatMap { $0.strings.pointer("type", $0.type) }
}
@_cdecl("nw_browse_descriptor_get_bonjour_service_domain")
public func finch_nw_browse_descriptor_get_bonjour_service_domain(_ d: nw_browse_descriptor_t) -> UnsafePointer<CChar>? {
    nwBrowseDescriptor(d).flatMap { $0.strings.pointer("domain", $0.domain) }
}
@_cdecl("nw_browse_descriptor_get_application_service_name")
public func finch_nw_browse_descriptor_get_application_service_name(_ d: nw_browse_descriptor_t) -> UnsafePointer<CChar>? {
    nwBrowseDescriptor(d).flatMap { $0.strings.pointer("app", $0.applicationService) }
}
@_cdecl("nw_browse_descriptor_set_include_txt_record")
public func finch_nw_browse_descriptor_set_include_txt_record(_ d: nw_browse_descriptor_t, _ v: Bool) { nwBrowseDescriptor(d)?.includeTXT = v }
@_cdecl("nw_browse_descriptor_get_include_txt_record")
public func finch_nw_browse_descriptor_get_include_txt_record(_ d: nw_browse_descriptor_t) -> Bool { nwBrowseDescriptor(d)?.includeTXT ?? false }

@objc(NWConcrete_nw_browse_result)
final class NWConcreteBrowseResult: NSObject, OS_nw_browse_result {
    let result: NWBrowser.Result
    init(_ result: NWBrowser.Result) {
        self.result = result
        super.init()
    }
}

func nwBrowseResult(_ r: nw_browse_result_t?) -> NWBrowser.Result? { (r as AnyObject? as? NWConcreteBrowseResult)?.result }

@_cdecl("nw_browse_result_copy_endpoint")
public func finch_nw_browse_result_copy_endpoint(_ r: nw_browse_result_t) -> UnsafeMutableRawPointer? {
    guard let result = nwBrowseResult(r) else { return nil }
    let endpoint = NWConcreteEndpoint(result.endpoint)
    if case let .bonjour(record) = result.metadata { endpoint.txtRecord = record }
    return nwRetained(endpoint)
}

@_cdecl("nw_browse_result_get_interfaces_count")
public func finch_nw_browse_result_get_interfaces_count(_ r: nw_browse_result_t) -> Int { nwBrowseResult(r)?.interfaces.count ?? 0 }

@_cdecl("nw_browse_result_enumerate_interfaces")
public func finch_nw_browse_result_enumerate_interfaces(_ r: nw_browse_result_t, _ block: @convention(block) (nw_interface_t) -> Bool) {
    for i in nwBrowseResult(r)?.interfaces ?? [] where !block(NWConcreteInterface(i)) { break }
}

@_cdecl("nw_browse_result_copy_txt_record_object")
public func finch_nw_browse_result_copy_txt_record_object(_ r: nw_browse_result_t) -> UnsafeMutableRawPointer? {
    guard case let .bonjour(record)? = nwBrowseResult(r)?.metadata else { return nil }
    return nwRetained(NWConcreteTXTRecord(record))
}

@_cdecl("nw_browse_result_get_changes")
public func finch_nw_browse_result_get_changes(_ old: nw_browse_result_t?, _ new: nw_browse_result_t?) -> UInt64 {
    switch NWBrowser.Result.Change(between: nwBrowseResult(old), nwBrowseResult(new)) {
    case .identical: return UInt64(nw_browse_result_change_identical)
    case .added: return UInt64(nw_browse_result_change_result_added)
    case .removed: return UInt64(nw_browse_result_change_result_removed)
    case let .changed(_, _, flags):
        var changes: UInt64 = 0
        if flags.contains(.interfaceAdded) { changes |= UInt64(nw_browse_result_change_interface_added) }
        if flags.contains(.interfaceRemoved) { changes |= UInt64(nw_browse_result_change_interface_removed) }
        if flags.contains(.metadataChanged) { changes |= UInt64(nw_browse_result_change_txt_record_changed) }
        return changes
    }
}

@objc(NWConcrete_nw_browser)
final class NWConcreteBrowser: NSObject, OS_nw_browser {
    let browser: NWBrowser
    let descriptorObject: NWConcreteBrowseDescriptor
    let parametersObject: NWConcreteParameters
    var queue: DispatchQueue?
    init(_ browser: NWBrowser, descriptor: NWConcreteBrowseDescriptor, parameters: NWConcreteParameters) {
        self.browser = browser
        descriptorObject = descriptor
        parametersObject = parameters
        super.init()
    }
}

func nwBrowser(_ b: nw_browser_t) -> NWConcreteBrowser? { b as AnyObject as? NWConcreteBrowser }

@_cdecl("nw_browser_create")
public func finch_nw_browser_create(_ d: nw_browse_descriptor_t, _ p: nw_parameters_t?) -> UnsafeMutableRawPointer? {
    guard let descriptor = nwBrowseDescriptor(d) else { return nil }
    let parameters = nwParameters(p)?.copy() ?? NWParameters()
    return nwRetained(NWConcreteBrowser(NWBrowser(for: descriptor.descriptor, using: parameters), descriptor: descriptor,
                                        parameters: NWConcreteParameters(parameters)))
}

@_cdecl("nw_browser_set_queue")
public func finch_nw_browser_set_queue(_ b: nw_browser_t, _ queue: DispatchQueue) { nwBrowser(b)?.queue = queue }

@_cdecl("nw_browser_copy_browse_descriptor")
public func finch_nw_browser_copy_browse_descriptor(_ b: nw_browser_t) -> UnsafeMutableRawPointer? { nwRetained(nwBrowser(b)?.descriptorObject) }

@_cdecl("nw_browser_copy_parameters")
public func finch_nw_browser_copy_parameters(_ b: nw_browser_t) -> UnsafeMutableRawPointer? { nwRetained(nwBrowser(b)?.parametersObject) }

@_cdecl("nw_browser_set_state_changed_handler")
public func finch_nw_browser_set_state_changed_handler(_ b: nw_browser_t, _ handler: (@convention(block) (nw_browser_state_t, nw_error_t?) -> Void)?) {
    nwBrowser(b)?.browser.stateUpdateHandler = handler.map { h in
        { state in
            switch state {
            case .setup: break
            case .ready: h(nw_browser_state_ready, nil)
            case let .failed(error): h(nw_browser_state_failed, NWConcreteError(error))
            case .cancelled: h(nw_browser_state_cancelled, nil)
            case let .waiting(error): h(nw_browser_state_waiting, NWConcreteError(error))
            }
        }
    }
}

@_cdecl("nw_browser_set_browse_results_changed_handler")
public func finch_nw_browser_set_browse_results_changed_handler(
    _ b: nw_browser_t, _ handler: (@convention(block) (nw_browse_result_t?, nw_browse_result_t?, Bool) -> Void)?) {
    nwBrowser(b)?.browser.browseResultsChangedHandler = handler.map { h in
        { _, changes in
            let list = Array(changes)
            for (index, change) in list.enumerated() {
                let last = index == list.count - 1
                switch change {
                case .identical: continue
                case let .added(result): h(nil, NWConcreteBrowseResult(result), last)
                case let .removed(result): h(NWConcreteBrowseResult(result), nil, last)
                case let .changed(old, new, _): h(NWConcreteBrowseResult(old), NWConcreteBrowseResult(new), last)
                }
            }
        }
    }
}

@_cdecl("nw_browser_start")
public func finch_nw_browser_start(_ b: nw_browser_t) {
    guard let browser = nwBrowser(b) else { return }
    browser.browser.start(queue: browser.queue ?? DispatchQueue(label: "nw_browser"))
}

@_cdecl("nw_browser_cancel")
public func finch_nw_browser_cancel(_ b: nw_browser_t) { nwBrowser(b)?.browser.cancel() }

// MARK: - Advertising

@objc(NWConcrete_nw_advertise_descriptor)
final class NWConcreteAdvertiseDescriptor: NSObject, OS_nw_advertise_descriptor {
    var service: NWListener.Service
    let applicationService: String?
    var txt: NWConcreteTXTRecord?
    let strings = NWCStrings()
    init(service: NWListener.Service, applicationService: String?) {
        self.service = service
        self.applicationService = applicationService
        super.init()
    }
}

func nwAdvertise(_ d: nw_advertise_descriptor_t) -> NWConcreteAdvertiseDescriptor? { d as AnyObject as? NWConcreteAdvertiseDescriptor }

@_cdecl("nw_advertise_descriptor_create_bonjour_service")
public func finch_nw_advertise_descriptor_create_bonjour_service(_ name: UnsafePointer<CChar>?, _ type: UnsafePointer<CChar>,
                                                                _ domain: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteAdvertiseDescriptor(service: NWListener.Service(name: nwString(name), type: String(cString: type),
                                                                         domain: nwString(domain)), applicationService: nil))
}

@_cdecl("nw_advertise_descriptor_create_application_service")
public func finch_nw_advertise_descriptor_create_application_service(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteAdvertiseDescriptor(service: NWListener.Service(type: "_\(String(cString: name))._tcp"),
                                             applicationService: String(cString: name)))
}

@_cdecl("nw_advertise_descriptor_get_application_service_name")
public func finch_nw_advertise_descriptor_get_application_service_name(_ d: nw_advertise_descriptor_t) -> UnsafePointer<CChar>? {
    nwAdvertise(d).flatMap { $0.strings.pointer("app", $0.applicationService) }
}

@_cdecl("nw_advertise_descriptor_set_txt_record")
public func finch_nw_advertise_descriptor_set_txt_record(_ d: nw_advertise_descriptor_t, _ bytes: UnsafeRawPointer?, _ length: Int) {
    guard let descriptor = nwAdvertise(d) else { return }
    let data = bytes.map { Data(bytes: $0, count: length) }
    descriptor.service = NWListener.Service(name: descriptor.service.name, type: descriptor.service.type,
                                            domain: descriptor.service.domain, txtRecord: data)
    descriptor.txt = data.map { NWConcreteTXTRecord(NWTXTRecord($0), raw: nwTXTIsDictionary($0) ? nil : $0) }
}

@_cdecl("nw_advertise_descriptor_set_txt_record_object")
public func finch_nw_advertise_descriptor_set_txt_record_object(_ d: nw_advertise_descriptor_t, _ t: nw_txt_record_t?) {
    guard let descriptor = nwAdvertise(d) else { return }
    let record = nwTXT(t)
    descriptor.txt = record
    let noAutoRename = descriptor.service.noAutoRename
    descriptor.service = NWListener.Service(name: descriptor.service.name, type: descriptor.service.type,
                                            domain: descriptor.service.domain, txtRecord: record?.bytes)
    descriptor.service.noAutoRename = noAutoRename
}

@_cdecl("nw_advertise_descriptor_copy_txt_record_object")
public func finch_nw_advertise_descriptor_copy_txt_record_object(_ d: nw_advertise_descriptor_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwAdvertise(d)?.txt.map { NWConcreteTXTRecord($0.record, raw: $0.raw) })
}

@_cdecl("nw_advertise_descriptor_set_no_auto_rename")
public func finch_nw_advertise_descriptor_set_no_auto_rename(_ d: nw_advertise_descriptor_t, _ v: Bool) { nwAdvertise(d)?.service.noAutoRename = v }

@_cdecl("nw_advertise_descriptor_get_no_auto_rename")
public func finch_nw_advertise_descriptor_get_no_auto_rename(_ d: nw_advertise_descriptor_t) -> Bool { nwAdvertise(d)?.service.noAutoRename ?? false }

// MARK: - Connection groups

@objc(NWConcrete_nw_group_descriptor)
final class NWConcreteGroupDescriptor: NSObject, OS_nw_group_descriptor {
    var members: [NWEndpoint]
    let multicast: Bool
    var source: NWEndpoint?
    var disableUnicast = false
    init(members: [NWEndpoint], multicast: Bool) {
        self.members = members
        self.multicast = multicast
        super.init()
    }
    var descriptor: (any NWGroupDescriptor)? {
        if multicast { return try? NWMulticastGroup(for: members, from: source, disableUnicast: disableUnicast) }
        return members.first.map { NWMultiplexGroup(to: $0) }
    }
}

func nwGroupDescriptor(_ d: nw_group_descriptor_t) -> NWConcreteGroupDescriptor? { d as AnyObject as? NWConcreteGroupDescriptor }

@_cdecl("nw_group_descriptor_create_multicast")
public func finch_nw_group_descriptor_create_multicast(_ e: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    guard let endpoint = nwEndpoint(e) else { return nil }
    return nwRetained(NWConcreteGroupDescriptor(members: [endpoint], multicast: true))
}

@_cdecl("nw_group_descriptor_create_multiplex")
public func finch_nw_group_descriptor_create_multiplex(_ e: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    guard let endpoint = nwEndpoint(e) else { return nil }
    return nwRetained(NWConcreteGroupDescriptor(members: [endpoint], multicast: false))
}

@_cdecl("nw_group_descriptor_add_endpoint")
public func finch_nw_group_descriptor_add_endpoint(_ d: nw_group_descriptor_t, _ e: nw_endpoint_t) -> Bool {
    guard let descriptor = nwGroupDescriptor(d), descriptor.multicast, let endpoint = nwEndpoint(e) else { return false }
    descriptor.members.append(endpoint)
    return true
}

@_cdecl("nw_group_descriptor_enumerate_endpoints")
public func finch_nw_group_descriptor_enumerate_endpoints(_ d: nw_group_descriptor_t, _ block: @convention(block) (nw_endpoint_t) -> Bool) {
    for e in nwGroupDescriptor(d)?.members ?? [] where !block(NWConcreteEndpoint(e)) { break }
}

@_cdecl("nw_multicast_group_descriptor_set_specific_source")
public func finch_nw_multicast_group_descriptor_set_specific_source(_ d: nw_group_descriptor_t, _ e: nw_endpoint_t) {
    nwGroupDescriptor(d)?.source = nwEndpoint(e)
}

@_cdecl("nw_multicast_group_descriptor_set_disable_unicast_traffic")
public func finch_nw_multicast_group_descriptor_set_disable_unicast_traffic(_ d: nw_group_descriptor_t, _ v: Bool) {
    nwGroupDescriptor(d)?.disableUnicast = v
}

@_cdecl("nw_multicast_group_descriptor_get_disable_unicast_traffic")
public func finch_nw_multicast_group_descriptor_get_disable_unicast_traffic(_ d: nw_group_descriptor_t) -> Bool {
    nwGroupDescriptor(d)?.disableUnicast ?? false
}

@objc(NWConcrete_nw_connection_group)
final class NWConcreteConnectionGroup: NSObject, OS_nw_connection_group {
    let group: NWConnectionGroup?
    let failure: NWError?
    var descriptorObject: NWConcreteGroupDescriptor?
    var parametersObject: NWConcreteParameters
    var queue: DispatchQueue?
    var stateHandler: ((nw_connection_group_state_t, nw_error_t?) -> Void)?

    init(_ group: NWConnectionGroup) {
        self.group = group
        failure = nil
        parametersObject = NWConcreteParameters(group.parameters)
        super.init()
    }

    init(failure: NWError, descriptor: NWConcreteGroupDescriptor?, parameters: NWParameters) {
        group = nil
        self.failure = failure
        descriptorObject = descriptor
        parametersObject = NWConcreteParameters(parameters)
        super.init()
    }
}

func nwGroup(_ g: nw_connection_group_t) -> NWConcreteConnectionGroup? { g as AnyObject as? NWConcreteConnectionGroup }

/* A group message's context, as a content context carrying the message. */
@objc(NWConcrete_nw_group_message)
final class NWConcreteGroupMessage: NSObject {}

final class NWGroupMessageContext {
    static var key = 0
}

func nwMessageContext(_ message: NWConnectionGroup.Message) -> NWConcreteContentContext {
    let context = NWConcreteContentContext(message)
    objc_setAssociatedObject(context, &NWGroupMessageContext.key, message, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return context
}

func nwMessage(_ c: nw_content_context_t?) -> NWConnectionGroup.Message? {
    (c as AnyObject?).flatMap { objc_getAssociatedObject($0, &NWGroupMessageContext.key) as? NWConnectionGroup.Message }
}

@_cdecl("nw_connection_group_create")
public func finch_nw_connection_group_create(_ d: nw_group_descriptor_t, _ p: nw_parameters_t) -> UnsafeMutableRawPointer? {
    guard let descriptorObject = nwGroupDescriptor(d), let parameters = nwParameters(p)?.copy() else { return nil }
    guard let descriptor = descriptorObject.descriptor else {
        return nwRetained(NWConcreteConnectionGroup(failure: .posix(.EINVAL), descriptor: descriptorObject, parameters: parameters))
    }
    let group = NWConcreteConnectionGroup(NWConnectionGroup(with: descriptor, using: parameters))
    group.descriptorObject = descriptorObject
    return nwRetained(group)
}

@_cdecl("nw_connection_group_copy_descriptor")
public func finch_nw_connection_group_copy_descriptor(_ g: nw_connection_group_t) -> UnsafeMutableRawPointer? { nwRetained(nwGroup(g)?.descriptorObject) }

@_cdecl("nw_connection_group_copy_parameters")
public func finch_nw_connection_group_copy_parameters(_ g: nw_connection_group_t) -> UnsafeMutableRawPointer? { nwRetained(nwGroup(g)?.parametersObject) }

@_cdecl("nw_connection_group_set_queue")
public func finch_nw_connection_group_set_queue(_ g: nw_connection_group_t, _ queue: DispatchQueue) { nwGroup(g)?.queue = queue }

@_cdecl("nw_connection_group_set_state_changed_handler")
public func finch_nw_connection_group_set_state_changed_handler(_ g: nw_connection_group_t,
                                                               _ handler: (@convention(block) (nw_connection_group_state_t, nw_error_t?) -> Void)?) {
    guard let group = nwGroup(g) else { return }
    group.stateHandler = handler.map { h in { h($0, $1) } }
    group.group?.stateUpdateHandler = handler.map { h in
        { state in
            switch state {
            case .setup: break
            case let .waiting(error): h(nw_connection_group_state_waiting, NWConcreteError(error))
            case .ready: h(nw_connection_group_state_ready, nil)
            case let .failed(error): h(nw_connection_group_state_failed, NWConcreteError(error))
            case .cancelled: h(nw_connection_group_state_cancelled, nil)
            }
        }
    }
}

@_cdecl("nw_connection_group_set_receive_handler")
public func finch_nw_connection_group_set_receive_handler(_ g: nw_connection_group_t, _ maximum: UInt32, _ reject: Bool,
                                                         _ handler: (@convention(block) (__DispatchData?, nw_content_context_t, Bool) -> Void)?) {
    nwGroup(g)?.group?.setReceiveHandler(maximumMessageSize: Int(maximum), rejectOversizedMessages: reject,
                                         handler: handler.map { h in { message, data, complete in h(nwDispatchData(data), nwMessageContext(message), complete) } })
}

@_cdecl("nw_connection_group_set_new_connection_handler")
public func finch_nw_connection_group_set_new_connection_handler(_ g: nw_connection_group_t, _ handler: (@convention(block) (nw_connection_t) -> Void)?) {
    nwGroup(g)?.group?.newConnectionHandler = handler.map { h in { h(NWConcreteConnection($0)) } }
}

@_cdecl("nw_connection_group_start")
public func finch_nw_connection_group_start(_ g: nw_connection_group_t) {
    guard let group = nwGroup(g) else { return }
    let queue = group.queue ?? DispatchQueue(label: "nw_connection_group")
    if let failure = group.failure {
        let handler = group.stateHandler
        queue.async { handler?(nw_connection_group_state_failed, NWConcreteError(failure)) }
        return
    }
    group.group?.start(queue: queue)
}

@_cdecl("nw_connection_group_cancel")
public func finch_nw_connection_group_cancel(_ g: nw_connection_group_t) {
    guard let group = nwGroup(g) else { return }
    if group.group == nil {
        let handler = group.stateHandler
        (group.queue ?? .global()).async { handler?(nw_connection_group_state_cancelled, nil) }
    }
    group.group?.cancel()
}

@_cdecl("nw_connection_group_send_message")
public func finch_nw_connection_group_send_message(_ g: nw_connection_group_t, _ content: __DispatchData?, _ e: nw_endpoint_t?,
                                                  _ context: nw_content_context_t,
                                                  _ completion: @escaping @convention(block) (nw_error_t?) -> Void) {
    guard let group = nwGroup(g)?.group else { completion(NWConcreteError(.posix(.ENOTCONN))); return }
    group.send(content: nwData(content), to: nwEndpoint(e), message: nwMessage(context) ?? .default) { completion(nwErrorObject($0)) }
}

@_cdecl("nw_connection_group_reply")
public func finch_nw_connection_group_reply(_ g: nw_connection_group_t, _ inbound: nw_content_context_t, _ outbound: nw_content_context_t,
                                            _ content: __DispatchData?) {
    nwMessage(inbound)?.reply(content: nwData(content), message: nwMessage(outbound) ?? .default)
}

@_cdecl("nw_connection_group_extract_connection")
public func finch_nw_connection_group_extract_connection(_ g: nw_connection_group_t, _ e: nw_endpoint_t?,
                                                        _ o: nw_protocol_options_t?) -> UnsafeMutableRawPointer? {
    let options = (o as AnyObject? as? NWConcreteProtocolOptions)?.options
    return nwRetained(nwGroup(g)?.group?.extract(connectionTo: nwEndpoint(e), using: options).map { NWConcreteConnection($0) })
}

@_cdecl("nw_connection_group_extract_connection_for_message")
public func finch_nw_connection_group_extract_connection_for_message(_ g: nw_connection_group_t, _ c: nw_content_context_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwMessage(c)?.extractConnection().map { NWConcreteConnection($0) })
}

@_cdecl("nw_connection_group_reinsert_extracted_connection")
public func finch_nw_connection_group_reinsert_extracted_connection(_ g: nw_connection_group_t, _ c: nw_connection_t) -> Bool {
    guard let connection = nwConnection(c)?.connection else { return false }
    return nwGroup(g)?.group?.reinsert(connection: connection) ?? false
}

@_cdecl("nw_connection_group_copy_remote_endpoint_for_message")
public func finch_nw_connection_group_copy_remote_endpoint_for_message(_ g: nw_connection_group_t, _ c: nw_content_context_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwMessage(c)?.remoteEndpoint.map { NWConcreteEndpoint($0) })
}

@_cdecl("nw_connection_group_copy_local_endpoint_for_message")
public func finch_nw_connection_group_copy_local_endpoint_for_message(_ g: nw_connection_group_t, _ c: nw_content_context_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwMessage(c)?.localEndpoint.map { NWConcreteEndpoint($0) })
}

@_cdecl("nw_connection_group_copy_path_for_message")
public func finch_nw_connection_group_copy_path_for_message(_ g: nw_connection_group_t, _ c: nw_content_context_t) -> UnsafeMutableRawPointer? {
    nwRetained(nwMessage(c)?.path.map { NWConcretePath($0) })
}

@_cdecl("nw_connection_group_copy_protocol_metadata")
public func finch_nw_connection_group_copy_protocol_metadata(_ g: nw_connection_group_t, _ d: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let definition = (d as AnyObject as? NWConcreteProtocolDefinition)?.definition else { return nil }
    return nwRetained(nwGroup(g)?.group?.metadata(definition: definition).map { NWConcreteProtocolMetadata($0) })
}

@_cdecl("nw_connection_group_copy_protocol_metadata_for_message")
public func finch_nw_connection_group_copy_protocol_metadata_for_message(_ g: nw_connection_group_t, _ c: nw_content_context_t,
                                                                        _ d: nw_protocol_definition_t) -> UnsafeMutableRawPointer? {
    guard let definition = (d as AnyObject as? NWConcreteProtocolDefinition)?.definition else { return nil }
    return nwRetained(nwMessage(c)?.metadata(definition: definition).map { NWConcreteProtocolMetadata($0) })
}

// MARK: - Privacy contexts, proxies and resolvers

@objc(NWConcrete_nw_privacy_context)
final class NWConcretePrivacyContext: NSObject, OS_nw_privacy_context {
    let name: String
    var proxies: [NWConcreteProxyConfig] = []
    var loggingDisabled = false
    var requireEncryptedResolution = false
    var fallbackResolver: NWConcreteResolverConfig?
    init(name: String) {
        self.name = name
        super.init()
    }
}

let nwDefaultPrivacyContext = NWConcretePrivacyContext(name: "default")

@_cdecl("finch_nw_default_privacy_context")
public func finch_nw_default_privacy_context() -> UnsafeMutableRawPointer? { nwRetained(nwDefaultPrivacyContext) }

func nwPrivacy(_ c: nw_privacy_context_t) -> NWConcretePrivacyContext? { c as AnyObject as? NWConcretePrivacyContext }

@_cdecl("nw_privacy_context_create")
public func finch_nw_privacy_context_create(_ description: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcretePrivacyContext(name: String(cString: description)))
}
@_cdecl("nw_privacy_context_flush_cache")
public func finch_nw_privacy_context_flush_cache(_ c: nw_privacy_context_t) {}
@_cdecl("nw_privacy_context_disable_logging")
public func finch_nw_privacy_context_disable_logging(_ c: nw_privacy_context_t) { nwPrivacy(c)?.loggingDisabled = true }
@_cdecl("nw_privacy_context_require_encrypted_name_resolution")
public func finch_nw_privacy_context_require_encrypted_name_resolution(_ c: nw_privacy_context_t, _ require: Bool, _ fallback: nw_resolver_config_t?) {
    nwPrivacy(c)?.requireEncryptedResolution = require
    nwPrivacy(c)?.fallbackResolver = fallback as AnyObject? as? NWConcreteResolverConfig
}
@_cdecl("nw_privacy_context_add_proxy")
public func finch_nw_privacy_context_add_proxy(_ c: nw_privacy_context_t, _ p: nw_proxy_config_t) {
    if let proxy = p as AnyObject as? NWConcreteProxyConfig { nwPrivacy(c)?.proxies.append(proxy) }
}
@_cdecl("nw_privacy_context_clear_proxies")
public func finch_nw_privacy_context_clear_proxies(_ c: nw_privacy_context_t) { nwPrivacy(c)?.proxies = [] }

@objc(NWConcrete_nw_resolver_config)
final class NWConcreteResolverConfig: NSObject, OS_nw_resolver_config {
    let url: NWEndpoint?
    let server: NWEndpoint?
    var addresses: [NWEndpoint] = []
    init(url: NWEndpoint?, server: NWEndpoint?) {
        self.url = url
        self.server = server
        super.init()
    }
}

@_cdecl("nw_resolver_config_create_https")
public func finch_nw_resolver_config_create_https(_ e: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteResolverConfig(url: nwEndpoint(e), server: nil))
}
@_cdecl("nw_resolver_config_create_tls")
public func finch_nw_resolver_config_create_tls(_ e: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteResolverConfig(url: nil, server: nwEndpoint(e)))
}
@_cdecl("nw_resolver_config_add_server_address")
public func finch_nw_resolver_config_add_server_address(_ c: nw_resolver_config_t, _ e: nw_endpoint_t) {
    if let endpoint = nwEndpoint(e) { (c as AnyObject as? NWConcreteResolverConfig)?.addresses.append(endpoint) }
}

@objc(NWConcrete_nw_relay_hop)
final class NWConcreteRelayHop: NSObject, OS_nw_relay_hop {
    let http3: NWEndpoint?, http2: NWEndpoint?
    let tls: NWProtocolOptions?
    var headers: [(String, String)] = []
    init(http3: NWEndpoint?, http2: NWEndpoint?, tls: NWProtocolOptions?) {
        self.http3 = http3
        self.http2 = http2
        self.tls = tls
        super.init()
    }
}

@_cdecl("nw_relay_hop_create")
public func finch_nw_relay_hop_create(_ h3: nw_endpoint_t?, _ h2: nw_endpoint_t?, _ tls: nw_protocol_options_t?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteRelayHop(http3: nwEndpoint(h3), http2: nwEndpoint(h2), tls: (tls as AnyObject? as? NWConcreteProtocolOptions)?.options))
}
@_cdecl("nw_relay_hop_add_additional_http_header_field")
public func finch_nw_relay_hop_add_additional_http_header_field(_ h: nw_relay_hop_t, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
    (h as AnyObject as? NWConcreteRelayHop)?.headers.append((String(cString: name), String(cString: value)))
}

@objc(NWConcrete_nw_proxy_config)
final class NWConcreteProxyConfig: NSObject, OS_nw_proxy_config {
    var configuration: ProxyConfiguration?
    var failoverAllowed = false
    var matchDomains: [String] = []
    var excludedDomains: [String] = []
    init(_ configuration: ProxyConfiguration?) {
        self.configuration = configuration
        super.init()
    }
}

func nwProxy(_ p: nw_proxy_config_t) -> NWConcreteProxyConfig? { p as AnyObject as? NWConcreteProxyConfig }

@_cdecl("nw_proxy_config_create_socksv5")
public func finch_nw_proxy_config_create_socksv5(_ e: nw_endpoint_t) -> UnsafeMutableRawPointer? {
    guard let endpoint = nwEndpoint(e) else { return nil }
    return nwRetained(NWConcreteProxyConfig(ProxyConfiguration(socksv5Proxy: endpoint)))
}
@_cdecl("nw_proxy_config_create_http_connect")
public func finch_nw_proxy_config_create_http_connect(_ e: nw_endpoint_t, _ tls: nw_protocol_options_t?) -> UnsafeMutableRawPointer? {
    guard let endpoint = nwEndpoint(e) else { return nil }
    return nwRetained(NWConcreteProxyConfig(ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nwOptions(tls, NWProtocolTLS.Options.self))))
}
@_cdecl("nw_proxy_config_create_relay")
public func finch_nw_proxy_config_create_relay(_ first: nw_relay_hop_t, _ second: nw_relay_hop_t?) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteProxyConfig(nil))
}
@_cdecl("nw_proxy_config_create_oblivious_http")
public func finch_nw_proxy_config_create_oblivious_http(_ relay: nw_relay_hop_t, _ path: UnsafePointer<CChar>, _ key: UnsafePointer<UInt8>,
                                                       _ length: Int) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteProxyConfig(nil))
}
@_cdecl("nw_proxy_config_set_username_and_password")
public func finch_nw_proxy_config_set_username_and_password(_ p: nw_proxy_config_t, _ user: UnsafePointer<CChar>, _ password: UnsafePointer<CChar>?) {
    nwProxy(p)?.configuration?.applyCredential(username: String(cString: user), password: nwString(password) ?? "")
}
@_cdecl("nw_proxy_config_set_failover_allowed")
public func finch_nw_proxy_config_set_failover_allowed(_ p: nw_proxy_config_t, _ v: Bool) { nwProxy(p)?.failoverAllowed = v }
@_cdecl("nw_proxy_config_get_failover_allowed")
public func finch_nw_proxy_config_get_failover_allowed(_ p: nw_proxy_config_t) -> Bool { nwProxy(p)?.failoverAllowed ?? false }
@_cdecl("nw_proxy_config_add_match_domain")
public func finch_nw_proxy_config_add_match_domain(_ p: nw_proxy_config_t, _ d: UnsafePointer<CChar>) { nwProxy(p)?.matchDomains.append(String(cString: d)) }
@_cdecl("nw_proxy_config_clear_match_domains")
public func finch_nw_proxy_config_clear_match_domains(_ p: nw_proxy_config_t) { nwProxy(p)?.matchDomains = [] }
@_cdecl("nw_proxy_config_add_excluded_domain")
public func finch_nw_proxy_config_add_excluded_domain(_ p: nw_proxy_config_t, _ d: UnsafePointer<CChar>) { nwProxy(p)?.excludedDomains.append(String(cString: d)) }
@_cdecl("nw_proxy_config_clear_excluded_domains")
public func finch_nw_proxy_config_clear_excluded_domains(_ p: nw_proxy_config_t) { nwProxy(p)?.excludedDomains = [] }
@_cdecl("nw_proxy_config_enumerate_match_domains")
public func finch_nw_proxy_config_enumerate_match_domains(_ p: nw_proxy_config_t, _ block: @convention(block) (UnsafePointer<CChar>) -> Void) {
    for d in nwProxy(p)?.matchDomains ?? [] { d.withCString { block($0) } }
}
@_cdecl("nw_proxy_config_enumerate_excluded_domains")
public func finch_nw_proxy_config_enumerate_excluded_domains(_ p: nw_proxy_config_t, _ block: @convention(block) (UnsafePointer<CChar>) -> Void) {
    for d in nwProxy(p)?.excludedDomains ?? [] { d.withCString { block($0) } }
}

// MARK: - Ethernet channels

/* Raw Ethernet needs a kernel channel Finch doesn't provide: a channel reports itself
   failed with EOPNOTSUPP when started. */
@objc(NWConcrete_nw_ethernet_channel)
final class NWConcreteEthernetChannel: NSObject, OS_nw_ethernet_channel {
    var queue: DispatchQueue?
    var stateHandler: ((nw_ethernet_channel_state_t, nw_error_t?) -> Void)?
}

func nwEthernet(_ c: nw_ethernet_channel_t) -> NWConcreteEthernetChannel? { c as AnyObject as? NWConcreteEthernetChannel }

@_cdecl("nw_ethernet_channel_create")
public func finch_nw_ethernet_channel_create(_ type: UInt16, _ i: nw_interface_t) -> UnsafeMutableRawPointer? { nwRetained(NWConcreteEthernetChannel()) }
@_cdecl("nw_ethernet_channel_create_with_parameters")
public func finch_nw_ethernet_channel_create_with_parameters(_ type: UInt16, _ i: nw_interface_t, _ p: nw_parameters_t) -> UnsafeMutableRawPointer? {
    nwRetained(NWConcreteEthernetChannel())
}
@_cdecl("nw_ethernet_channel_set_queue")
public func finch_nw_ethernet_channel_set_queue(_ c: nw_ethernet_channel_t, _ q: DispatchQueue) { nwEthernet(c)?.queue = q }
@_cdecl("nw_ethernet_channel_set_state_changed_handler")
public func finch_nw_ethernet_channel_set_state_changed_handler(_ c: nw_ethernet_channel_t,
                                                               _ h: (@convention(block) (nw_ethernet_channel_state_t, nw_error_t?) -> Void)?) {
    nwEthernet(c)?.stateHandler = h.map { block in { block($0, $1) } }
}
@_cdecl("nw_ethernet_channel_set_receive_handler")
public func finch_nw_ethernet_channel_set_receive_handler(_ c: nw_ethernet_channel_t, _ h: UnsafeRawPointer?) {}
@_cdecl("nw_ethernet_channel_start")
public func finch_nw_ethernet_channel_start(_ c: nw_ethernet_channel_t) {
    guard let channel = nwEthernet(c) else { return }
    let handler = channel.stateHandler
    (channel.queue ?? .global()).async { handler?(nw_ethernet_channel_state_failed, NWConcreteError(.posix(.EOPNOTSUPP))) }
}
@_cdecl("nw_ethernet_channel_cancel")
public func finch_nw_ethernet_channel_cancel(_ c: nw_ethernet_channel_t) {
    guard let channel = nwEthernet(c) else { return }
    let handler = channel.stateHandler
    (channel.queue ?? .global()).async { handler?(nw_ethernet_channel_state_cancelled, nil) }
}
@_cdecl("nw_ethernet_channel_send")
public func finch_nw_ethernet_channel_send(_ c: nw_ethernet_channel_t, _ content: __DispatchData, _ vlan: UInt16, _ address: UnsafePointer<UInt8>,
                                           _ completion: @escaping @convention(block) (nw_error_t?) -> Void) {
    (nwEthernet(c)?.queue ?? .global()).async { completion(NWConcreteError(.posix(.EOPNOTSUPP))) }
}
@_cdecl("nw_ethernet_channel_get_maximum_payload_size")
public func finch_nw_ethernet_channel_get_maximum_payload_size(_ c: nw_ethernet_channel_t) -> UInt32 { 1500 }

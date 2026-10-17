// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Table column alignment and customization settings.

public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(OpenSwiftUI_v3_0, *)
public struct TableColumnAlignment: Hashable, Sendable {
    enum Kind: UInt8, Sendable {
        case automatic, leading, center, trailing, numeric
    }

    var kind: Kind
    var numberingSystem: String?

    private init(_ kind: Kind, numberingSystem: String? = nil) {
        self.kind = kind
        self.numberingSystem = numberingSystem
    }

    public static var automatic: Self { Self(.automatic) }
    public static var leading: Self { Self(.leading) }
    public static var center: Self { Self(.center) }
    public static var trailing: Self { Self(.trailing) }
    public static var numeric: Self { Self(.numeric) }

    public static func numeric(_ numberingSystem: Locale.NumberingSystem) -> Self {
        Self(.numeric, numberingSystem: numberingSystem.identifier)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.numberingSystem == rhs.numberingSystem
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(numberingSystem)
    }

    public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct TableColumnCustomizationBehavior: SetAlgebra, Sendable {
    public typealias Element = TableColumnCustomizationBehavior

    private var rawValue: UInt8 = 0

    public init() {}

    private init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static var all: Self { Self(rawValue: 0b111) }
    public static let reorder = Self(rawValue: 0b001)
    public static let resize = Self(rawValue: 0b010)
    public static let visibility = Self(rawValue: 0b100)

    public func contains(_ member: Self) -> Bool {
        rawValue & member.rawValue == member.rawValue
    }

    public func union(_ other: Self) -> Self { Self(rawValue: rawValue | other.rawValue) }
    public func intersection(_ other: Self) -> Self { Self(rawValue: rawValue & other.rawValue) }
    public func symmetricDifference(_ other: Self) -> Self { Self(rawValue: rawValue ^ other.rawValue) }

    @discardableResult
    public mutating func insert(_ newMember: Self) -> (inserted: Bool, memberAfterInsert: Self) {
        let inserted = !contains(newMember)
        formUnion(newMember)
        return (inserted, newMember)
    }

    @discardableResult
    public mutating func remove(_ member: Self) -> Self? {
        guard contains(member) else { return nil }
        rawValue &= ~member.rawValue
        return member
    }

    @discardableResult
    public mutating func update(with newMember: Self) -> Self? {
        let old = contains(newMember) ? newMember : nil
        formUnion(newMember)
        return old
    }

    public mutating func formUnion(_ other: Self) { rawValue |= other.rawValue }
    public mutating func formIntersection(_ other: Self) { rawValue &= other.rawValue }
    public mutating func formSymmetricDifference(_ other: Self) { rawValue ^= other.rawValue }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

    public var hashValue: Int { Int(rawValue) }
}

@available(OpenSwiftUI_v3_0, *)
public struct TableColumnCustomization<RowValue>: Equatable, Sendable, Codable where RowValue: Identifiable {
    private var visibilityValues: [String: UInt8] = [:]
    var columnOrder: [String]?

    public init() {}

    public subscript(visibility id: String) -> Visibility {
        get {
            switch visibilityValues[id] ?? 0 {
            case 1: .visible
            case 2: .hidden
            default: .automatic
            }
        }
        set {
            switch newValue {
            case .visible: visibilityValues[id] = 1
            case .hidden: visibilityValues[id] = 2
            case .automatic: visibilityValues.removeValue(forKey: id)
            @unknown default: visibilityValues.removeValue(forKey: id)
            }
        }
    }

    public mutating func resetOrder() { columnOrder = nil }

    mutating func moveColumn(_ id: String, before destinationID: String, defaultOrder: [String]) {
        var order = columnOrder ?? defaultOrder
        guard let source = order.firstIndex(of: id), let destination = order.firstIndex(of: destinationID), source != destination else { return }
        let moved = order.remove(at: source)
        let target = order.firstIndex(of: destinationID) ?? destination
        order.insert(moved, at: target)
        columnOrder = order
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibilityValues == rhs.visibilityValues && lhs.columnOrder == rhs.columnOrder
    }

    private enum CodingKeys: String, CodingKey {
        case visibilityValues
        case columnOrder
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visibilityValues, forKey: .visibilityValues)
        try container.encodeIfPresent(columnOrder, forKey: .columnOrder)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibilityValues = try container.decodeIfPresent([String: UInt8].self, forKey: .visibilityValues) ?? [:]
        columnOrder = try container.decodeIfPresent([String].self, forKey: .columnOrder)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumnAlignment {
    var _finchHorizontalAlignment: Alignment {
        switch kind {
        case .center: .center
        case .trailing, .numeric: .trailing
        case .automatic, .leading: .leading
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
struct _FinchTableColumnMetadata {
    var alignment: TableColumnAlignment?
    var customizationID: String?
    var defaultVisibility: Visibility?
    var disabledCustomizationBehavior: TableColumnCustomizationBehavior?
}

@available(OpenSwiftUI_v3_0, *)
struct _FinchModifiedTableColumn<Content: TableColumnContent>: TableColumnContent {
    typealias TableRowValue = Content.TableRowValue
    typealias TableColumnSortComparator = Content.TableColumnSortComparator
    typealias TableColumnBody = Never

    var content: Content
    var metadata: _FinchTableColumnMetadata

    nonisolated static func _makeContent(content: _GraphValue<Self>, inputs: _TableColumnInputs) -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? {
        Content._tableColumnCount(inputs: inputs)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension _FinchModifiedTableColumn: _FinchTableColumns {
    @MainActor
    func _finchColumns<Value>(of type: Value.Type) -> [_FinchTableColumn<Value>] {
        _finchTableColumnsOf(content, type).map { column in
            var column = column
            if let alignment = metadata.alignment { column.alignment = alignment }
            if let customizationID = metadata.customizationID { column.customizationID = customizationID }
            if let defaultVisibility = metadata.defaultVisibility { column.defaultVisibility = defaultVisibility }
            if let behavior = metadata.disabledCustomizationBehavior { column.disabledCustomizationBehavior = behavior }
            return column
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
extension TableColumnContent {
    public func alignment(_ alignment: TableColumnAlignment) -> some TableColumnContent<Self.TableRowValue, Self.TableColumnSortComparator> {
        _finchModifiedTableColumn { $0.alignment = alignment }
    }

    public func defaultVisibility(_ visibility: Visibility) -> some TableColumnContent<Self.TableRowValue, Self.TableColumnSortComparator> {
        _finchModifiedTableColumn { $0.defaultVisibility = visibility }
    }

    public func customizationID(_ id: String) -> some TableColumnContent<Self.TableRowValue, Self.TableColumnSortComparator> {
        _finchModifiedTableColumn { $0.customizationID = id }
    }

    public func disabledCustomizationBehavior(_ behavior: TableColumnCustomizationBehavior) -> some TableColumnContent<Self.TableRowValue, Self.TableColumnSortComparator> {
        _finchModifiedTableColumn { $0.disabledCustomizationBehavior = behavior }
    }

    private func _finchModifiedTableColumn(_ update: (inout _FinchTableColumnMetadata) -> Void) -> _FinchModifiedTableColumn<Self> {
        var metadata = _FinchTableColumnMetadata()
        update(&metadata)
        return _FinchModifiedTableColumn(content: self, metadata: metadata)
    }
}

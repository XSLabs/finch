// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Repeated table columns built from a collection.

public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 14.4, *)
@MainActor
@preconcurrency
public struct TableColumnForEach<Data, ID, RowValue, Sort, Content>: TableColumnContent
where Data: RandomAccessCollection, ID: Hashable, RowValue: Identifiable,
      RowValue == Content.TableRowValue, Sort == Content.TableColumnSortComparator,
      Content: TableColumnContent {
    public typealias TableRowValue = RowValue
    public typealias TableColumnSortComparator = Sort
    public typealias TableColumnBody = Never

    public var data: Data
    public var content: (Data.Element) -> Content

    public init(_ data: Data, @TableColumnBuilder<RowValue, Sort> content: @escaping (Data.Element) -> Content)
        where ID == Data.Element.ID, Data.Element: Identifiable {
        self.data = data
        self.content = content
    }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                @TableColumnBuilder<RowValue, Sort> content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    @_semantics("swiftui.requires_constant_range")
    public init(_ data: Range<Int>, @TableColumnBuilder<RowValue, Sort> content: @escaping (Int) -> Content)
        where Data == Range<Int>, ID == Int {
        self.data = data
        self.content = content
    }

    nonisolated public static func _makeContent(content: _GraphValue<Self>, inputs: _TableColumnInputs)
        -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { nil }
}

@available(*, unavailable) extension TableColumnForEach: Sendable {}

@available(macOS 14.4, *)
@MainActor
extension TableColumnForEach: _FinchTableColumns {
    func _finchColumns<Value>(of type: Value.Type) -> [_FinchTableColumn<Value>] {
        data.flatMap { _finchTableColumnsOf(content($0), type) }
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// OutlineGroup and lists of hierarchical data, to Apple's interface: each element's row,
// and for an element with children a disclosure group whose content is the children's
// outline, as Apple's outline lists show on macOS.

public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v2_0, *)
public struct OutlineGroup<Data, ID, Parent, Leaf, Subgroup> where Data: RandomAccessCollection, ID: Hashable {
    /// The rows, built when the group's body is asked for.
    var rows: () -> AnyView
}

@available(*, unavailable) extension OutlineGroup: Sendable {}

/// The children of an outline subgroup (a disclosure group's content).
@available(OpenSwiftUI_v2_0, *)
public struct OutlineSubgroupChildren: View {
    var children: AnyView

    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        AnyView._makeView(view: view[offset: { .of(&$0.children) }], inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        AnyView._makeViewList(view: view[offset: { .of(&$0.children) }], inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? { nil }

    public typealias Body = Never
    public var body: Never { fatalError("\(Self.self) has no body") }
}

@available(OpenSwiftUI_v2_0, *)
extension OutlineGroup: View where Parent: View, Leaf: View, Subgroup: View {
    @MainActor
    @preconcurrency
    public var body: some View { rows() }
}

/// An element's row, disclosing its children's rows when it has any.
@MainActor
func _finchOutlineRows<Rows: Sequence, Element, ElementID: Hashable, Children: RandomAccessCollection, Row: View>(
    _ data: Rows, id: KeyPath<Element, ElementID>, children: KeyPath<Element, Children?>,
    content: @escaping (Element) -> Row
) -> AnyView where Rows.Element == Element, Children.Element == Element {
    AnyView(ForEach(Array(data), id: id) { element in
        if let kids = element[keyPath: children] {
            DisclosureGroup {
                OutlineSubgroupChildren(children: _finchOutlineRows(kids, id: id, children: children, content: content))
            } label: {
                content(element)
            }
        } else {
            content(element)
        }
    })
}

@available(OpenSwiftUI_v2_0, *)
extension OutlineGroup where ID == Data.Element.ID, Parent: View, Parent == Leaf,
    Subgroup == DisclosureGroup<Parent, OutlineSubgroupChildren>, Data.Element: Identifiable {
    public init<DataElement>(_ root: DataElement, children: KeyPath<DataElement, Data?>,
                             @ViewBuilder content: @escaping (DataElement) -> Leaf)
        where ID == DataElement.ID, DataElement: Identifiable, DataElement == Data.Element {
        rows = { MainActor.assumeIsolated { _finchOutlineRows([root], id: \.id, children: children, content: content) } }
    }

    public init<DataElement>(_ data: Data, children: KeyPath<DataElement, Data?>,
                             @ViewBuilder content: @escaping (DataElement) -> Leaf)
        where ID == DataElement.ID, DataElement: Identifiable, DataElement == Data.Element {
        rows = { MainActor.assumeIsolated { _finchOutlineRows(data, id: \.id, children: children, content: content) } }
    }
}

@available(OpenSwiftUI_v2_0, *)
extension OutlineGroup where Parent: View, Parent == Leaf, Subgroup == DisclosureGroup<Parent, OutlineSubgroupChildren> {
    public init<DataElement>(_ root: DataElement, id: KeyPath<DataElement, ID>, children: KeyPath<DataElement, Data?>,
                             @ViewBuilder content: @escaping (DataElement) -> Leaf) where DataElement == Data.Element {
        rows = { MainActor.assumeIsolated { _finchOutlineRows([root], id: id, children: children, content: content) } }
    }

    public init<DataElement>(_ data: Data, id: KeyPath<DataElement, ID>, children: KeyPath<DataElement, Data?>,
                             @ViewBuilder content: @escaping (DataElement) -> Leaf) where DataElement == Data.Element {
        rows = { MainActor.assumeIsolated { _finchOutlineRows(data, id: id, children: children, content: content) } }
    }
}

// MARK: - Lists of hierarchical data

@available(OpenSwiftUI_v2_0, *)
extension List where SelectionValue == Never {
    nonisolated public init<Data, RowContent>(_ data: Data, children: KeyPath<Data.Element, Data?>,
                                              @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
        Data: RandomAccessCollection, RowContent: View, Data.Element: Identifiable {
        self.init(selection: .none, content: OutlineGroup(data, children: children, content: rowContent))
    }

    nonisolated public init<Data, ID, RowContent>(_ data: Data, id: KeyPath<Data.Element, ID>, children: KeyPath<Data.Element, Data?>,
                                                  @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
        Data: RandomAccessCollection, ID: Hashable, RowContent: View {
        self.init(selection: .none, content: OutlineGroup(data, id: id, children: children, content: rowContent))
    }
}

@available(OpenSwiftUI_v2_0, *)
extension List {
    nonisolated public init<Data, RowContent>(_ data: Data, children: KeyPath<Data.Element, Data?>,
                                              selection: Binding<Set<SelectionValue>>?,
                                              @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
        Data: RandomAccessCollection, RowContent: View, Data.Element: Identifiable {
        self.init(selection: _FinchListSelection(selection), content: OutlineGroup(data, children: children, content: rowContent))
    }

    nonisolated public init<Data, RowContent>(_ data: Data, children: KeyPath<Data.Element, Data?>,
                                              selection: Binding<SelectionValue?>?,
                                              @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
        Data: RandomAccessCollection, RowContent: View, Data.Element: Identifiable {
        self.init(selection: _FinchListSelection(selection), content: OutlineGroup(data, children: children, content: rowContent))
    }
}

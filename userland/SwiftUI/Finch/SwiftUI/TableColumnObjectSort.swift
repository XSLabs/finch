// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Table columns that sort NSObject-backed rows with Foundation sort descriptors.

public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(OpenSwiftUI_v3_0, *)
extension TableColumn where RowValue: NSObject, Sort == SortDescriptor<RowValue>, Label == Text {
    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Bool>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Bool>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Bool>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Bool>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Bool?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Bool?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Bool?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Bool?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Double>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Double>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Double>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Double>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Double?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Double?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Double?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Double?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Float>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Float>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Float>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Float>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Float?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Float?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Float?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Float?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int8>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int8?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int16>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int16?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int32>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int32?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int64>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int64?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.Int?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.Int?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.Int?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.Int?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt8>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt8>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt8?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt8?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt16>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt16>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt16?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt16?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt32>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt32>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt32?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt32?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt64>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt64>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt64?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt64?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Swift.UInt?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Swift.UInt?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Swift.UInt?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Swift.UInt?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Foundation.Date>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Foundation.Date>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Foundation.Date>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Foundation.Date>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Foundation.Date?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Foundation.Date?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Foundation.Date?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Foundation.Date?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Foundation.UUID>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Foundation.UUID>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Foundation.UUID>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Foundation.UUID>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, Foundation.UUID?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, Foundation.UUID?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, Foundation.UUID?>, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, Foundation.UUID?>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String?>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, String?>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, String?>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, String?>, comparator: String.StandardComparator = .localizedStandard, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard) where Content == Text {
        self.init(label: Text(titleKey), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: { Text($0[keyPath: value]) })
    }

    @available(macOS 13.5, *)
    public init(_ titleResource: LocalizedStringResource, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard) where Content == Text {
        self.init(label: Text(titleResource), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: { Text($0[keyPath: value]) })
    }

    @available(macOS 13.5, *)
    @_disfavoredOverload public init<S>(_ title: S, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard) where Content == Text, S: StringProtocol {
        self.init(label: Text(title), comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: { Text($0[keyPath: value]) })
    }

    @available(macOS 13.5, *)
    public init(_ text: Text, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard) where Content == Text {
        self.init(label: text, comparator: SortDescriptor<RowValue>(value, comparator: comparator), content: { Text($0[keyPath: value]) })
    }

}

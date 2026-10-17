// SPDX-License-Identifier: MIT OR Apache-2.0
//
// DatePicker, using AppKit's date picker so its displayed parts, bounds and selected date
// stay connected to SwiftUI's binding.

import AppKit
public import Foundation
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let date = DatePickerComponents(rawValue: 1 << 0)
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 1)
}

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct DatePicker<Label>: View where Label: View {
    public typealias Components = DatePickerComponents

    private var selection: Binding<Date>
    private var minimumDate: Date?
    private var maximumDate: Date?
    private var displayedComponents: DatePickerComponents
    private var label: Label
    @Environment(\._finchDatePickerStyles) private var styles

    private init(selection: Binding<Date>, minimumDate: Date?, maximumDate: Date?,
                 displayedComponents: DatePickerComponents, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.minimumDate = minimumDate
        self.maximumDate = maximumDate
        self.displayedComponents = displayedComponents
        self.label = label()
    }

    public var body: some View {
        let configuration = DatePickerStyleConfiguration(
            label: DatePickerStyleConfiguration.Label(), selection: selection,
            minimumDate: minimumDate, maximumDate: maximumDate,
            displayedComponents: displayedComponents)
        let style = styles.last ?? _FinchAnyDatePickerStyle(DefaultDatePickerStyle())
        style.body(configuration)
            .environment(\._finchDatePickerStyles, Array(styles.dropLast()))
            .viewAlias(DatePickerStyleConfiguration.Label.self) { label }
    }
}

@available(*, unavailable) extension DatePicker: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension DatePicker {
    nonisolated public init(selection: Binding<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
                            @ViewBuilder label: () -> Label) {
        self.init(selection: selection, minimumDate: nil, maximumDate: nil,
                  displayedComponents: displayedComponents, label: label)
    }

    nonisolated public init(selection: Binding<Date>, in bounds: ClosedRange<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
                            @ViewBuilder label: () -> Label) {
        self.init(selection: selection, minimumDate: bounds.lowerBound, maximumDate: bounds.upperBound,
                  displayedComponents: displayedComponents, label: label)
    }

    nonisolated public init(selection: Binding<Date>, in bounds: PartialRangeFrom<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
                            @ViewBuilder label: () -> Label) {
        self.init(selection: selection, minimumDate: bounds.lowerBound, maximumDate: nil,
                  displayedComponents: displayedComponents, label: label)
    }

    nonisolated public init(selection: Binding<Date>, in bounds: PartialRangeThrough<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
                            @ViewBuilder label: () -> Label) {
        self.init(selection: selection, minimumDate: nil, maximumDate: bounds.upperBound,
                  displayedComponents: displayedComponents, label: label)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension DatePicker where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(titleKey) }
    }

    nonisolated public init(_ title: LocalizedStringResource, selection: Binding<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<Date>,
                               displayedComponents: DatePickerComponents = [.date, .hourAndMinute])
        where S: StringProtocol {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: ClosedRange<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(titleKey) }
    }

    nonisolated public init(_ title: LocalizedStringResource, selection: Binding<Date>, in bounds: ClosedRange<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<Date>, in bounds: ClosedRange<Date>,
                               displayedComponents: DatePickerComponents = [.date, .hourAndMinute])
        where S: StringProtocol {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: PartialRangeFrom<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(titleKey) }
    }

    nonisolated public init(_ title: LocalizedStringResource, selection: Binding<Date>, in bounds: PartialRangeFrom<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<Date>, in bounds: PartialRangeFrom<Date>,
                               displayedComponents: DatePickerComponents = [.date, .hourAndMinute])
        where S: StringProtocol {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: PartialRangeThrough<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(titleKey) }
    }

    nonisolated public init(_ title: LocalizedStringResource, selection: Binding<Date>, in bounds: PartialRangeThrough<Date>,
                            displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<Date>, in bounds: PartialRangeThrough<Date>,
                               displayedComponents: DatePickerComponents = [.date, .hourAndMinute])
        where S: StringProtocol {
        self.init(selection: selection, in: bounds, displayedComponents: displayedComponents) { Text(title) }
    }
}

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public protocol DatePickerStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = DatePickerStyleConfiguration
}

@available(OpenSwiftUI_v1_0, *)
public struct DatePickerStyleConfiguration {
    public struct Label: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    public let label: DatePickerStyleConfiguration.Label
    @Binding public var selection: Date
    public var minimumDate: Date?
    public var maximumDate: Date?
    public var displayedComponents: DatePickerComponents

    init(label: Label, selection: Binding<Date>, minimumDate: Date?, maximumDate: Date?,
         displayedComponents: DatePickerComponents) {
        self.label = label
        _selection = selection
        self.minimumDate = minimumDate
        self.maximumDate = maximumDate
        self.displayedComponents = displayedComponents
    }
}

@available(*, unavailable) extension DatePickerStyleConfiguration: Sendable {}
@available(*, unavailable) extension DatePickerStyleConfiguration.Label: Sendable {}

private struct _FinchDatePickerStylesKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyDatePickerStyle] { [] }
}

extension EnvironmentValues {
    var _finchDatePickerStyles: [_FinchAnyDatePickerStyle] {
        get { self[_FinchDatePickerStylesKey.self] }
        set { self[_FinchDatePickerStylesKey.self] = newValue }
    }
}

struct _FinchAnyDatePickerStyle: @unchecked Sendable {
    let body: (DatePickerStyleConfiguration) -> AnyView

    @MainActor
    init<S: DatePickerStyle>(_ style: S) {
        body = { configuration in
            AnyView(_FinchStyleView(style: style, configuration: configuration) { style, configuration in
                MainActor.assumeIsolated { AnyView(style.makeBody(configuration: configuration)) }
            })
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func datePickerStyle<S>(_ style: S) -> some View where S: DatePickerStyle {
        let box = MainActor.assumeIsolated { _FinchAnyDatePickerStyle(style) }
        return transformEnvironment(\._finchDatePickerStyles) { $0.append(box) }
    }
}

private enum _FinchDatePickerControlStyle {
    case compact, field, stepperField, graphical
}

private struct _FinchDatePickerContent: View {
    let configuration: DatePickerStyleConfiguration
    let style: _FinchDatePickerControlStyle

    var body: some View {
        HStack(spacing: 6) {
            _FinchControlLabel(label: configuration.label)
            _FinchNativeDatePicker(selection: configuration.$selection,
                                   minimumDate: configuration.minimumDate,
                                   maximumDate: configuration.maximumDate,
                                   displayedComponents: configuration.displayedComponents,
                                   style: style)
                .fixedSize()
        }
    }
}

private struct _FinchNativeDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    var minimumDate: Date?
    var maximumDate: Date?
    var displayedComponents: DatePickerComponents
    var style: _FinchDatePickerControlStyle
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker(frame: .zero)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        updateNSView(picker, context: context)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.datePickerMode = .single
        picker.datePickerStyle = switch style {
        case .field: .textField
        case .stepperField: .textFieldAndStepper
        case .graphical: .clockAndCalendar
        case .compact: .textFieldAndStepper
        }
        var elements: NSDatePicker.ElementFlags = []
        if displayedComponents.contains(.date) { elements.insert(.yearMonthDay) }
        if displayedComponents.contains(.hourAndMinute) { elements.insert(.hourMinute) }
        picker.datePickerElements = elements.isEmpty ? [.yearMonthDay] : elements
        picker.minDate = minimumDate
        picker.maxDate = maximumDate
        picker.isEnabled = isEnabled
        picker.locale = context.environment.locale
        picker.timeZone = context.environment.timeZone
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchNativeDatePicker
        init(_ parent: _FinchNativeDatePicker) { self.parent = parent }

        @objc func changed(_ sender: NSDatePicker) {
            parent.selection = sender.dateValue
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DefaultDatePickerStyle: DatePickerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchDatePickerContent(configuration: configuration, style: .compact)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct StepperFieldDatePickerStyle: DatePickerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchDatePickerContent(configuration: configuration, style: .stepperField)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct FieldDatePickerStyle: DatePickerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchDatePickerContent(configuration: configuration, style: .field)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct GraphicalDatePickerStyle: DatePickerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchDatePickerContent(configuration: configuration, style: .graphical)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct CompactDatePickerStyle: DatePickerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchDatePickerContent(configuration: configuration, style: .compact)
    }
}

@available(*, unavailable) extension DefaultDatePickerStyle: Sendable {}
@available(*, unavailable) extension StepperFieldDatePickerStyle: Sendable {}
@available(*, unavailable) extension FieldDatePickerStyle: Sendable {}
@available(*, unavailable) extension GraphicalDatePickerStyle: Sendable {}
@available(*, unavailable) extension CompactDatePickerStyle: Sendable {}

extension DatePickerStyle where Self == DefaultDatePickerStyle {
    public static var automatic: DefaultDatePickerStyle { .init() }
}

extension DatePickerStyle where Self == StepperFieldDatePickerStyle {
    public static var stepperField: StepperFieldDatePickerStyle { .init() }
}

extension DatePickerStyle where Self == FieldDatePickerStyle {
    public static var field: FieldDatePickerStyle { .init() }
}

extension DatePickerStyle where Self == GraphicalDatePickerStyle {
    public static var graphical: GraphicalDatePickerStyle { .init() }
}

extension DatePickerStyle where Self == CompactDatePickerStyle {
    public static var compact: CompactDatePickerStyle { .init() }
}

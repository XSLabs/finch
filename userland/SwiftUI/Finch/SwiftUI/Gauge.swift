// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Gauges show a value against its range. Finch draws linear gauges with ProgressView and the
// accessory circular styles as a small, trimmed circle.

import SwiftUICore

@available(macOS 13.0, *)
@MainActor
@preconcurrency
public protocol GaugeStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = GaugeStyleConfiguration
}

@available(macOS 13.0, *)
public struct GaugeStyleConfiguration {
    @MainActor @preconcurrency
    public struct Label: View {
        var content: AnyView
        public var body: some View { content }
    }

    @MainActor @preconcurrency
    public struct CurrentValueLabel: View {
        var content: AnyView
        public var body: some View { content }
    }

    @MainActor @preconcurrency
    public struct MinimumValueLabel: View {
        var content: AnyView
        public var body: some View { content }
    }

    @MainActor @preconcurrency
    public struct MaximumValueLabel: View {
        var content: AnyView
        public var body: some View { content }
    }

    @MainActor @preconcurrency
    public struct MarkedValueLabel: View {
        var content: AnyView
        public var body: some View { content }
    }

    public let value: Double
    public let label: Label
    public let currentValueLabel: CurrentValueLabel?
    public let minimumValueLabel: MinimumValueLabel?
    public let maximumValueLabel: MaximumValueLabel?

    init(value: Double, label: AnyView, currentValueLabel: AnyView?,
         minimumValueLabel: AnyView?, maximumValueLabel: AnyView?) {
        self.value = value
        self.label = Label(content: label)
        self.currentValueLabel = currentValueLabel.map(CurrentValueLabel.init(content:))
        self.minimumValueLabel = minimumValueLabel.map(MinimumValueLabel.init(content:))
        self.maximumValueLabel = maximumValueLabel.map(MaximumValueLabel.init(content:))
    }
}

fileprivate struct _FinchAnyGaugeStyle {
    var makeBody: (GaugeStyleConfiguration) -> AnyView

    init<S: GaugeStyle>(_ style: S) {
        makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
}

@available(macOS 13.0, *)
private struct _FinchGaugeStyleKey: EnvironmentKey {
    static let defaultValue = _FinchAnyGaugeStyle(DefaultGaugeStyle())
}

@available(macOS 13.0, *)
extension EnvironmentValues {
    fileprivate var _finchGaugeStyle: _FinchAnyGaugeStyle {
        get { self[_FinchGaugeStyleKey.self] }
        set { self[_FinchGaugeStyleKey.self] = newValue }
    }
}

@available(macOS 13.0, *)
extension View {
    nonisolated public func gaugeStyle<S>(_ style: S) -> some View where S: GaugeStyle {
        environment(\._finchGaugeStyle, _FinchAnyGaugeStyle(style))
    }
}

@available(macOS 13.0, *)
@MainActor
public struct Gauge<Label, CurrentValueLabel, BoundsLabel, MarkedValueLabels>: View
    where Label: View, CurrentValueLabel: View, BoundsLabel: View, MarkedValueLabels: View {
    private let value: Double
    private let bounds: ClosedRange<Double>
    private let label: Label
    private let currentValueLabel: CurrentValueLabel
    private let minimumValueLabel: BoundsLabel
    private let maximumValueLabel: BoundsLabel
    @Environment(\._finchGaugeStyle) private var style

    nonisolated public init<V>(value: V, in bounds: ClosedRange<V> = 0...1,
                               @ViewBuilder label: () -> Label)
        where CurrentValueLabel == EmptyView, BoundsLabel == EmptyView,
              MarkedValueLabels == EmptyView, V: BinaryFloatingPoint {
        self.value = Double(value)
        self.bounds = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.label = label()
        self.currentValueLabel = EmptyView()
        self.minimumValueLabel = EmptyView()
        self.maximumValueLabel = EmptyView()
    }

    nonisolated public init<V>(value: V, in bounds: ClosedRange<V> = 0...1,
                               @ViewBuilder label: () -> Label,
                               @ViewBuilder currentValueLabel: () -> CurrentValueLabel)
        where BoundsLabel == EmptyView, MarkedValueLabels == EmptyView, V: BinaryFloatingPoint {
        self.value = Double(value)
        self.bounds = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        self.minimumValueLabel = EmptyView()
        self.maximumValueLabel = EmptyView()
    }

    nonisolated public init<V>(value: V, in bounds: ClosedRange<V> = 0...1,
                               @ViewBuilder label: () -> Label,
                               @ViewBuilder currentValueLabel: () -> CurrentValueLabel,
                               @ViewBuilder minimumValueLabel: () -> BoundsLabel,
                               @ViewBuilder maximumValueLabel: () -> BoundsLabel)
        where MarkedValueLabels == EmptyView, V: BinaryFloatingPoint {
        self.value = Double(value)
        self.bounds = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        self.minimumValueLabel = minimumValueLabel()
        self.maximumValueLabel = maximumValueLabel()
    }

    @MainActor @preconcurrency
    public var body: some View {
        let span = bounds.upperBound - bounds.lowerBound
        let fraction = span == 0 ? 0 : min(max((value - bounds.lowerBound) / span, 0), 1)
        style.makeBody(GaugeStyleConfiguration(
            value: fraction,
            label: AnyView(label),
            currentValueLabel: currentValueLabel is EmptyView ? nil : AnyView(currentValueLabel),
            minimumValueLabel: minimumValueLabel is EmptyView ? nil : AnyView(minimumValueLabel),
            maximumValueLabel: maximumValueLabel is EmptyView ? nil : AnyView(maximumValueLabel)))
    }
}

@available(*, unavailable) extension Gauge: Sendable {}

@available(macOS 13.0, *)
private struct _FinchLinearGaugeBody: View {
    let configuration: GaugeStyleConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            configuration.label
            ProgressView(value: configuration.value)
            HStack {
                configuration.minimumValueLabel
                Spacer(minLength: 4)
                configuration.currentValueLabel
                Spacer(minLength: 4)
                configuration.maximumValueLabel
            }
        }
    }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct DefaultGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FinchLinearGaugeBody(configuration: configuration) }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct LinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FinchLinearGaugeBody(configuration: configuration) }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct AccessoryLinearGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FinchLinearGaugeBody(configuration: configuration) }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct AccessoryLinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FinchLinearGaugeBody(configuration: configuration) }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct AccessoryCircularGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        _FinchCircularGaugeBody(configuration: configuration)
    }
}

@available(macOS 13.0, *)
@MainActor @preconcurrency
public struct AccessoryCircularCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        _FinchCircularGaugeBody(configuration: configuration)
    }
}

@available(macOS 13.0, *)
private struct _FinchCircularGaugeBody: View {
    let configuration: GaugeStyleConfiguration

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: configuration.value)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let value = configuration.currentValueLabel { value }
            }
            .frame(width: 26, height: 26)
            configuration.label
        }
    }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == DefaultGaugeStyle {
    public static var automatic: DefaultGaugeStyle { .init() }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == LinearCapacityGaugeStyle {
    public static var linearCapacity: LinearCapacityGaugeStyle { .init() }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == AccessoryLinearGaugeStyle {
    public static var accessoryLinear: AccessoryLinearGaugeStyle { .init() }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == AccessoryLinearCapacityGaugeStyle {
    public static var accessoryLinearCapacity: AccessoryLinearCapacityGaugeStyle { .init() }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == AccessoryCircularGaugeStyle {
    public static var accessoryCircular: AccessoryCircularGaugeStyle { .init() }
}

@available(macOS 13.0, *)
extension GaugeStyle where Self == AccessoryCircularCapacityGaugeStyle {
    public static var accessoryCircularCapacity: AccessoryCircularCapacityGaugeStyle { .init() }
}

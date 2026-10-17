// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Stepper, using AppKit's native stepper control and changing the bound value by its stride.

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Stepper<Label>: View where Label: View {
    private var label: Label
    private var value: Double
    private var step: Double
    private var minimum: Double?
    private var maximum: Double?
    private var change: (Int) -> Void
    private var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    nonisolated public init(onIncrement: (() -> Void)?, onDecrement: (() -> Void)?,
                            onEditingChanged: @escaping (Bool) -> Void = { _ in },
                            @ViewBuilder label: () -> Label) {
        self.label = label()
        value = 0
        step = 1
        minimum = nil
        maximum = nil
        self.onEditingChanged = onEditingChanged
        change = { direction in
            if direction > 0 { onIncrement?() } else if direction < 0 { onDecrement?() }
        }
    }

    private init<V>(value: Binding<V>, step: V.Stride, bounds: ClosedRange<V>?,
                    onEditingChanged: @escaping (Bool) -> Void,
                    @ViewBuilder label: () -> Label) where V: Strideable {
        self.label = label()
        self.value = _finchNumber(value.wrappedValue) ?? 0
        self.step = max(abs(_finchNumber(step) ?? 1), Double.leastNonzeroMagnitude)
        self.minimum = bounds.flatMap { _finchNumber($0.lowerBound) }
        self.maximum = bounds.flatMap { _finchNumber($0.upperBound) }
        self.onEditingChanged = onEditingChanged
        self.change = { direction in
            let stride = direction > 0 ? step : -step
            let next = value.wrappedValue.advanced(by: stride)
            if bounds?.contains(next) != false {
                value.wrappedValue = next
            }
        }
    }

    public init<V>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
                   onEditingChanged: @escaping (Bool) -> Void = { _ in },
                   @ViewBuilder label: () -> Label)
        where V: Strideable {
        self.init(value: value, step: step, bounds: bounds, onEditingChanged: onEditingChanged, label: label)
    }

    public init<V>(value: Binding<V>, step: V.Stride = 1,
                   onEditingChanged: @escaping (Bool) -> Void = { _ in },
                   @ViewBuilder label: () -> Label) where V: Strideable {
        self.init(value: value, step: step, bounds: nil, onEditingChanged: onEditingChanged, label: label)
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        HStack(spacing: 8) {
            label
            _FinchStepperControl(value: value, step: step, minimum: minimum, maximum: maximum,
                                 isEnabled: isEnabled, change: change, onEditingChanged: onEditingChanged)
                .fixedSize()
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Stepper where Label == Text {
    public init<V>(_ titleKey: LocalizedStringKey, value: Binding<V>, in bounds: ClosedRange<V>,
                   step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V: Strideable {
        self.init(value: value, in: bounds, step: step, onEditingChanged: onEditingChanged) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S, V>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>,
                       step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in })
        where S: StringProtocol, V: Strideable {
        self.init(value: value, in: bounds, step: step, onEditingChanged: onEditingChanged) { Text(title) }
    }
}

private func _finchNumber<T>(_ value: T) -> Double? {
    (value as? NSNumber)?.doubleValue
}

@MainActor
private struct _FinchStepperControl: NSViewRepresentable {
    var value: Double
    var step: Double
    var minimum: Double?
    var maximum: Double?
    var isEnabled: Bool
    var change: (Int) -> Void
    var onEditingChanged: (Bool) -> Void

    final class NativeStepper: NSStepper {
        var onEditingChanged: (Bool) -> Void = { _ in }

        override func mouseDown(with event: NSEvent) {
            onEditingChanged(true)
            super.mouseDown(with: event)
            onEditingChanged(false)
        }

        override func keyDown(with event: NSEvent) {
            onEditingChanged(true)
            super.keyDown(with: event)
            onEditingChanged(false)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var previousValue: Double
        var change: (Int) -> Void

        init(value: Double, change: @escaping (Int) -> Void) {
            previousValue = value
            self.change = change
        }

        @objc func step(_ sender: NSStepper) {
            let newValue = sender.doubleValue
            let oldValue = previousValue
            previousValue = newValue
            if newValue > oldValue {
                change(1)
            } else if newValue < oldValue {
                change(-1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: value, change: change)
    }

    func makeNSView(context: Context) -> NSStepper {
        let view = NativeStepper()
        view.target = context.coordinator
        view.action = #selector(Coordinator.step(_:))
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSStepper, context: Context) {
        context.coordinator.previousValue = value
        context.coordinator.change = change
        (view as? NativeStepper)?.onEditingChanged = onEditingChanged
        view.doubleValue = value
        view.increment = step
        view.minValue = minimum ?? -Double.greatestFiniteMagnitude
        view.maxValue = maximum ?? Double.greatestFiniteMagnitude
        view.isEnabled = isEnabled
    }
}

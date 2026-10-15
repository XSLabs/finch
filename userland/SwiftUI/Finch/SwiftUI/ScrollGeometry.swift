// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Reports the geometry of Finch's in-graph scroll views when the selected value changes.

import SwiftUICore

struct _FinchScrollGeometryObserver {
    var report: (ScrollGeometry) -> Void
}

private struct _FinchScrollGeometryObserversKey: EnvironmentKey {
    static let defaultValue: [_FinchScrollGeometryObserver] = []
}

extension EnvironmentValues {
    var _finchScrollGeometryObservers: [_FinchScrollGeometryObserver] {
        get { self[_FinchScrollGeometryObserversKey.self] }
        set { self[_FinchScrollGeometryObserversKey.self] = newValue }
    }
}

private final class _FinchScrollGeometryChange<Value: Equatable> {
    var transform: (ScrollGeometry) -> Value
    var action: (Value, Value) -> Void
    var previous: Value?
    var hasPrevious = false

    init(transform: @escaping (ScrollGeometry) -> Value,
         action: @escaping (Value, Value) -> Void) {
        self.transform = transform
        self.action = action
    }

    func report(_ geometry: ScrollGeometry) {
        let next = transform(geometry)
        if hasPrevious, let previous, previous != next {
            action(previous, next)
        }
        previous = next
        hasPrevious = true
    }
}

@available(OpenSwiftUI_v6_0, *)
private struct _FinchScrollGeometryChangeModifier<Value: Equatable>: ViewModifier {
    let transform: (ScrollGeometry) -> Value
    let action: (Value, Value) -> Void
    @State private var change: _FinchScrollGeometryChange<Value>

    init(transform: @escaping (ScrollGeometry) -> Value,
         action: @escaping (Value, Value) -> Void) {
        self.transform = transform
        self.action = action
        _change = State(initialValue: _FinchScrollGeometryChange(transform: transform, action: action))
    }

    func body(content: Content) -> some View {
        change.transform = transform
        change.action = action
        let change = change
        return content.transformEnvironment(\._finchScrollGeometryObservers) {
            $0.append(_FinchScrollGeometryObserver { geometry in
                MainActor.assumeIsolated { change.report(geometry) }
            })
        }
    }
}

@available(OpenSwiftUI_v6_0, *)
extension View {
    @preconcurrency
    nonisolated public func onScrollGeometryChange<Value>(
        for type: Value.Type,
        of transform: @escaping (ScrollGeometry) -> Value,
        action: @escaping (Value, Value) -> Void
    ) -> some View where Value: Equatable {
        modifier(_FinchScrollGeometryChangeModifier(transform: transform, action: action))
    }
}

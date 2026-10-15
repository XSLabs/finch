// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Scroll bounce settings for Finch's scroll view, which applies a short elastic overscroll
// and springs back when scrolling stops.

import SwiftUICore

enum _FinchScrollBounceKind: UInt8, Sendable {
    case automatic
    case always
    case basedOnSize
}

@available(macOS 13.3, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
public struct ScrollBounceBehavior: Sendable {
    private let rawValue: UInt8

    private init(_ kind: _FinchScrollBounceKind) {
        rawValue = kind.rawValue
    }

    var _finchKind: _FinchScrollBounceKind {
        _FinchScrollBounceKind(rawValue: rawValue) ?? .automatic
    }

    public static var automatic: Self { Self(.automatic) }
    public static var always: Self { Self(.always) }
    public static var basedOnSize: Self { Self(.basedOnSize) }
}

private struct _FinchScrollBounceValues {
    var horizontal: ScrollBounceBehavior = .automatic
    var vertical: ScrollBounceBehavior = .automatic
}

private struct _FinchScrollBounceKey: EnvironmentKey {
    static var defaultValue = _FinchScrollBounceValues()
}

@available(macOS 13.3, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
extension EnvironmentValues {
    public var verticalScrollBounceBehavior: ScrollBounceBehavior {
        get { self[_FinchScrollBounceKey.self].vertical }
        set { self[_FinchScrollBounceKey.self].vertical = newValue }
    }

    public var horizontalScrollBounceBehavior: ScrollBounceBehavior {
        get { self[_FinchScrollBounceKey.self].horizontal }
        set { self[_FinchScrollBounceKey.self].horizontal = newValue }
    }
}

@available(macOS 13.3, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
extension View {
    nonisolated public func scrollBounceBehavior(
        _ behavior: ScrollBounceBehavior,
        axes: Axis.Set = [.vertical]
    ) -> some View {
        transformEnvironment(\.verticalScrollBounceBehavior) {
            if axes.contains(.vertical) { $0 = behavior }
        }
        .transformEnvironment(\.horizontalScrollBounceBehavior) {
            if axes.contains(.horizontal) { $0 = behavior }
        }
    }
}

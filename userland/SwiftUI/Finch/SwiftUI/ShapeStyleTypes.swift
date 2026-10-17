// SPDX-License-Identifier: MIT OR Apache-2.0
//
// System shape styles resolve to the matching dynamic AppKit colors.

import AppKit
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 14.0, *)
@frozen
public struct FillShapeStyle: ShapeStyle {
    public init() {}

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        shape.result = .color(.primary)
    }

    public typealias Resolved = Never
}

@available(macOS 14.0, *)
@frozen
public struct PlaceholderTextShapeStyle: ShapeStyle {
    public init() {}

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        shape.result = .color(Color(nsColor: .placeholderTextColor))
    }

    public typealias Resolved = Never
}

@available(macOS 14.0, *)
@frozen
public struct LinkShapeStyle: ShapeStyle {
    public init() {}

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        shape.result = .color(Color(nsColor: .linkColor))
    }

    public typealias Resolved = Never
}

@available(macOS 12.0, *)
public struct SelectionShapeStyle: ShapeStyle {
    public init() {}

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        shape.result = .color(Color(nsColor: .selectedTextBackgroundColor))
    }

    @available(macOS 14.0, *)
    public typealias Resolved = Never
}

@available(macOS 14.0, *)
@frozen
public struct WindowBackgroundShapeStyle: ShapeStyle {
    public init() {}

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        shape.result = .color(Color(nsColor: .windowBackgroundColor))
    }

    public typealias Resolved = Never
}

@available(macOS 14.0, *)
extension ShapeStyle where Self == FillShapeStyle {
    public static var fill: FillShapeStyle { .init() }
}

@available(macOS 14.0, *)
extension ShapeStyle where Self == PlaceholderTextShapeStyle {
    public static var placeholder: PlaceholderTextShapeStyle { .init() }
}

@available(macOS 14.0, *)
extension ShapeStyle where Self == LinkShapeStyle {
    public static var link: LinkShapeStyle { .init() }
}

@available(macOS 12.0, *)
extension ShapeStyle where Self == SelectionShapeStyle {
    public static var selection: SelectionShapeStyle { .init() }
}

@available(macOS 14.0, *)
extension ShapeStyle where Self == WindowBackgroundShapeStyle {
    public static var windowBackground: WindowBackgroundShapeStyle { .init() }
}

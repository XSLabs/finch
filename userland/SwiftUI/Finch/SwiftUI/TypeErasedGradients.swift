// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Shape styles that keep their geometry when a gradient is type-erased.

@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 13.0, *)
@frozen
public struct _AnyLinearGradient: ShapeStyle {
    @usableFromInline var gradient: AnyGradient
    @usableFromInline var startPoint: UnitPoint
    @usableFromInline var endPoint: UnitPoint

    @usableFromInline
    internal init(gradient: AnyGradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public typealias Resolved = Never

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        LinearGradient(gradient: gradient.gradient, startPoint: startPoint, endPoint: endPoint)._apply(to: &shape)
    }
}

@available(macOS 13.0, *)
@frozen
public struct _AnyRadialGradient: ShapeStyle {
    @usableFromInline var gradient: AnyGradient
    @usableFromInline var center: UnitPoint
    @usableFromInline var startRadius: CGFloat
    @usableFromInline var endRadius: CGFloat

    @usableFromInline
    internal init(gradient: AnyGradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }

    public typealias Resolved = Never

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        RadialGradient(gradient: gradient.gradient, center: center,
                       startRadius: startRadius, endRadius: endRadius)._apply(to: &shape)
    }
}

@available(macOS 13.0, *)
@frozen
public struct _AnyEllipticalGradient: ShapeStyle {
    @usableFromInline var gradient: AnyGradient
    @usableFromInline var center: UnitPoint
    @usableFromInline var startRadiusFraction: CGFloat
    @usableFromInline var endRadiusFraction: CGFloat

    @usableFromInline
    internal init(gradient: AnyGradient, center: UnitPoint = .center,
                  startRadiusFraction: CGFloat, endRadiusFraction: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadiusFraction = startRadiusFraction
        self.endRadiusFraction = endRadiusFraction
    }

    public typealias Resolved = Never

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        EllipticalGradient(gradient: gradient.gradient, center: center,
                           startRadiusFraction: startRadiusFraction,
                           endRadiusFraction: endRadiusFraction)._apply(to: &shape)
    }
}

@available(macOS 13.0, *)
@frozen
public struct _AnyAngularGradient: ShapeStyle {
    @usableFromInline var gradient: AnyGradient
    @usableFromInline var center: UnitPoint
    @usableFromInline var startAngle: Angle
    @usableFromInline var endAngle: Angle

    @usableFromInline
    internal init(gradient: AnyGradient, center: UnitPoint, startAngle: Angle, endAngle: Angle) {
        self.gradient = gradient
        self.center = center
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    public typealias Resolved = Never

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        AngularGradient(gradient: gradient.gradient, center: center,
                       startAngle: startAngle, endAngle: endAngle)._apply(to: &shape)
    }
}

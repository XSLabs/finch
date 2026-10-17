// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftUI's ShapeStyle names forward to the working styles in SwiftUICore.

@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == Color {
    public static var red: Color { Color._finchSwiftUIRed }
    public static var orange: Color { Color._finchSwiftUIOrange }
    public static var yellow: Color { Color._finchSwiftUIYellow }
    public static var green: Color { Color._finchSwiftUIGreen }
    public static var mint: Color { Color._finchSwiftUIMint }
    public static var teal: Color { Color._finchSwiftUITeal }
    public static var cyan: Color { Color._finchSwiftUICyan }
    public static var blue: Color { Color._finchSwiftUIBlue }
    public static var indigo: Color { Color._finchSwiftUIIndigo }
    public static var purple: Color { Color._finchSwiftUIPurple }
    public static var pink: Color { Color._finchSwiftUIPink }
    public static var brown: Color { Color._finchSwiftUIBrown }
    public static var white: Color { Color._finchSwiftUIWhite }
    public static var gray: Color { Color._finchSwiftUIGray }
    public static var black: Color { Color._finchSwiftUIBlack }
    public static var clear: Color { Color._finchSwiftUIClear }
}

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { ._finchSwiftUIPrimary }
    public static var secondary: HierarchicalShapeStyle { ._finchSwiftUISecondary }
    public static var tertiary: HierarchicalShapeStyle { ._finchSwiftUITertiary }
    public static var quaternary: HierarchicalShapeStyle { ._finchSwiftUIQuaternary }
    public static var quinary: HierarchicalShapeStyle { ._finchSwiftUIQuinary }
}

extension ShapeStyle where Self == SeparatorShapeStyle {
    public static var separator: SeparatorShapeStyle { .init() }
}

@available(OpenSwiftUI_v2_0, *)
extension ShapeStyle where Self == BackgroundStyle {
    public static var background: BackgroundStyle { .init() }
}

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == ForegroundStyle {
    public static var foreground: ForegroundStyle { .init() }
}

@available(OpenSwiftUI_v3_0, *)
extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { .init() }
}

@available(OpenSwiftUI_v3_0, *)
extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { ._finchSwiftUIRegular }
    public static var thickMaterial: Material { ._finchSwiftUIThick }
    public static var thinMaterial: Material { ._finchSwiftUIThin }
    public static var ultraThinMaterial: Material { ._finchSwiftUIUltraThin }
    public static var ultraThickMaterial: Material { ._finchSwiftUIUltraThick }
    public static var bar: Material { ._finchSwiftUIBar }
}

@available(OpenSwiftUI_v4_0, *)
extension ShapeStyle {
    public static var secondary: some ShapeStyle { HierarchicalShapeStyle._finchSwiftUISecondary }
    public static var tertiary: some ShapeStyle { HierarchicalShapeStyle._finchSwiftUITertiary }
    public static var quaternary: some ShapeStyle { HierarchicalShapeStyle._finchSwiftUIQuaternary }
    public static var quinary: some ShapeStyle { HierarchicalShapeStyle._finchSwiftUIQuinary }

    public static func opacity(_ opacity: Double) -> some ShapeStyle {
        _finchSwiftUIOpacity(opacity)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == LinearGradient {
    public static func linearGradient(_ gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }

    public static func linearGradient(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
    }

    public static func linearGradient(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(stops: stops, startPoint: startPoint, endPoint: endPoint)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == RadialGradient {
    public static func radialGradient(_ gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(gradient: gradient, center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public static func radialGradient(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(colors: colors, center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public static func radialGradient(stops: [Gradient.Stop], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(stops: stops, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension ShapeStyle where Self == EllipticalGradient {
    public static func ellipticalGradient(_ gradient: Gradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(gradient: gradient, center: center, startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }

    public static func ellipticalGradient(colors: [Color], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(colors: colors, center: center, startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }

    public static func ellipticalGradient(stops: [Gradient.Stop], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(stops: stops, center: center, startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension ShapeStyle where Self == AngularGradient {
    public static func angularGradient(_ gradient: Gradient, center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(gradient: gradient, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func angularGradient(colors: [Color], center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(colors: colors, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func angularGradient(stops: [Gradient.Stop], center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(stops: stops, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func conicGradient(_ gradient: Gradient, center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(gradient: gradient, center: center, angle: angle)
    }

    public static func conicGradient(colors: [Color], center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(colors: colors, center: center, angle: angle)
    }

    public static func conicGradient(stops: [Gradient.Stop], center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(stops: stops, center: center, angle: angle)
    }
}

@available(macOS 13.0, *)
extension ShapeStyle where Self == LinearGradient {
    public static func linearGradient(_ gradient: AnyGradient, startPoint: UnitPoint, endPoint: UnitPoint) -> some ShapeStyle {
        _AnyLinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }
}

@available(macOS 13.0, *)
extension ShapeStyle where Self == RadialGradient {
    public static func radialGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startRadius: CGFloat = 0, endRadius: CGFloat) -> some ShapeStyle {
        _AnyRadialGradient(gradient: gradient, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

@available(macOS 13.0, *)
extension ShapeStyle where Self == EllipticalGradient {
    public static func ellipticalGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) -> some ShapeStyle {
        _AnyEllipticalGradient(gradient: gradient, center: center,
                               startRadiusFraction: startRadiusFraction,
                               endRadiusFraction: endRadiusFraction)
    }
}

@available(macOS 13.0, *)
extension ShapeStyle where Self == AngularGradient {
    public static func angularGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startAngle: Angle, endAngle: Angle) -> some ShapeStyle {
        _AnyAngularGradient(gradient: gradient, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func conicGradient(_ gradient: AnyGradient, center: UnitPoint = .center, angle: Angle = .zero) -> some ShapeStyle {
        _AnyAngularGradient(gradient: gradient, center: center,
                            startAngle: angle, endAngle: angle + .radians(2 * .pi))
    }
}

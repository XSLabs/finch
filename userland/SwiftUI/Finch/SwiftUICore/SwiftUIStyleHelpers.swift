// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Named entry points used by SwiftUI's public style helpers.

public import Foundation
public import OpenCoreGraphicsShims

@_spi(ForOpenSwiftUIOnly)
public extension Color {
    static var _finchSwiftUIRed: Color { .red }
    static var _finchSwiftUIOrange: Color { .orange }
    static var _finchSwiftUIYellow: Color { .yellow }
    static var _finchSwiftUIGreen: Color { .green }
    static var _finchSwiftUIMint: Color { .mint }
    static var _finchSwiftUITeal: Color { .teal }
    static var _finchSwiftUICyan: Color { .cyan }
    static var _finchSwiftUIBlue: Color { .blue }
    static var _finchSwiftUIIndigo: Color { .indigo }
    static var _finchSwiftUIPurple: Color { .purple }
    static var _finchSwiftUIPink: Color { .pink }
    static var _finchSwiftUIBrown: Color { .brown }
    static var _finchSwiftUIWhite: Color { .white }
    static var _finchSwiftUIGray: Color { .gray }
    static var _finchSwiftUIBlack: Color { .black }
    static var _finchSwiftUIClear: Color { .clear }
    static var _finchSwiftUIPrimary: Color { .primary }
    static var _finchSwiftUISecondary: Color { .secondary }

    static func _finchSwiftUIFromRGB(_ space: RGBColorSpace, red: Double, green: Double,
                                     blue: Double, opacity: Double) -> Color {
        Color(space, red: red, green: green, blue: blue, opacity: opacity)
    }

    static func _finchSwiftUIFromWhite(_ space: RGBColorSpace, white: Double, opacity: Double) -> Color {
        Color(space, white: white, opacity: opacity)
    }

    static func _finchSwiftUIFromHSB(hue: Double, saturation: Double, brightness: Double,
                                     opacity: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }

    static func _finchSwiftUIFromCGColor(_ color: CGColor) -> Color { Color(color) }
    var _finchSwiftUICGColor: CGColor? { cgColor }
    var _finchSwiftUIDescription: String { description }
}

@_spi(ForOpenSwiftUIOnly)
public extension HierarchicalShapeStyle {
    static var _finchSwiftUIPrimary: HierarchicalShapeStyle { .primary }
    static var _finchSwiftUISecondary: HierarchicalShapeStyle { .secondary }
    static var _finchSwiftUITertiary: HierarchicalShapeStyle { .tertiary }
    static var _finchSwiftUIQuaternary: HierarchicalShapeStyle { .quaternary }
    static var _finchSwiftUIQuinary: HierarchicalShapeStyle { .init(id: 4) }
}

@_spi(ForOpenSwiftUIOnly)
public extension Material {
    static var _finchSwiftUIUltraThin: Material { .ultraThin }
    static var _finchSwiftUIThin: Material { .thin }
    static var _finchSwiftUIRegular: Material { .regular }
    static var _finchSwiftUIThick: Material { .thick }
    static var _finchSwiftUIUltraThick: Material { .init(id: .ultraThick) }
    static var _finchSwiftUIBar: Material { .init(id: .systemBars) }
}

@_spi(ForOpenSwiftUIOnly)
public extension ShapeStyle {
    static func _finchSwiftUIOpacity(_ opacity: Double) -> some ShapeStyle {
        AnyShapeStyle.opacity(opacity)
    }
}

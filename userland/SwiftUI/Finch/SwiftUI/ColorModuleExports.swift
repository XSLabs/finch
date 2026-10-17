// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftUI's Color entry points forward to the color implementation in SwiftUICore.

public import CoreGraphics
public import Foundation
import AppKit
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

private func _finchSwiftUIColor(named name: String, bundle: Bundle?) -> Color {
    guard let color = NSColor(named: NSColor.Name(name), bundle: bundle) else { return .clear }
    return Color(nsColor: color)
}

public extension Color {
    static var red: Color { _finchSwiftUIRed }
    static var orange: Color { _finchSwiftUIOrange }
    static var yellow: Color { _finchSwiftUIYellow }
    static var green: Color { _finchSwiftUIGreen }
    static var mint: Color { _finchSwiftUIMint }
    static var teal: Color { _finchSwiftUITeal }
    static var cyan: Color { _finchSwiftUICyan }
    static var blue: Color { _finchSwiftUIBlue }
    static var indigo: Color { _finchSwiftUIIndigo }
    static var purple: Color { _finchSwiftUIPurple }
    static var pink: Color { _finchSwiftUIPink }
    static var brown: Color { _finchSwiftUIBrown }
    static var white: Color { _finchSwiftUIWhite }
    static var gray: Color { _finchSwiftUIGray }
    static var black: Color { _finchSwiftUIBlack }
    static var clear: Color { _finchSwiftUIClear }
    static var primary: Color { _finchSwiftUIPrimary }
    static var secondary: Color { _finchSwiftUISecondary }

    nonisolated public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double,
                            blue: Double, opacity: Double = 1) {
        self = Self._finchSwiftUIFromRGB(colorSpace, red: red, green: green, blue: blue, opacity: opacity)
    }

    nonisolated public init(_ colorSpace: RGBColorSpace = .sRGB, white: Double, opacity: Double = 1) {
        self = Self._finchSwiftUIFromWhite(colorSpace, white: white, opacity: opacity)
    }

    nonisolated public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        self = Self._finchSwiftUIFromHSB(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }

    nonisolated public init(_ color: CGColor) {
        self = Self._finchSwiftUIFromCGColor(color)
    }

    nonisolated public init(cgColor: CGColor) {
        self = Self._finchSwiftUIFromCGColor(cgColor)
    }

    nonisolated public init(_ name: String, bundle: Bundle? = nil) {
        self = _finchSwiftUIColor(named: name, bundle: bundle)
    }

    public var cgColor: CGColor? { _finchSwiftUICGColor }
    public var description: String { _finchSwiftUIDescription }

    @available(macOS 13.0, *)
    public var gradient: AnyGradient { AnyGradient(Gradient(colors: [self])) }
}

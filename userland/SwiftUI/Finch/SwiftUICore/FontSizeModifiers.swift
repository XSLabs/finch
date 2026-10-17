// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Size modifiers keep the selected font and adjust only its resolved point size.

public import CoreFoundation
import CoreText
import Foundation

private enum _FinchFontSizeChange: Hashable {
    case fixed(CGFloat)
    case scaled(CGFloat)
}

private struct _FinchFontSizeProvider: FontProvider {
    var base: Font
    var change: _FinchFontSizeChange

    func resolve(in context: Font.Context) -> CTFontDescriptor {
        let descriptor = base.resolve(in: context)
        let traits = base.resolveTraits(in: context)
        let size: CGFloat
        switch change {
        case let .fixed(value):
            size = value
        case let .scaled(factor):
            size = traits.pointSize * factor
        }
        let attributes = [kCTFontSizeAttribute: size] as CFDictionary
        return CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
    }

    func resolveTraits(in context: Font.Context) -> Font.ResolvedTraits {
        var traits = base.resolveTraits(in: context)
        switch change {
        case let .fixed(value):
            traits.pointSize = value
        case let .scaled(factor):
            traits.pointSize *= factor
        }
        return traits
    }
}

@_spi(ForOpenSwiftUIOnly)
public extension Font {
    func _finchSwiftUIPointSize(_ size: CoreFoundation.CGFloat) -> Font {
        Font(provider: _FinchFontSizeProvider(base: self, change: .fixed(size)))
    }

    func _finchSwiftUIScaled(by factor: CoreFoundation.CGFloat) -> Font {
        Font(provider: _FinchFontSizeProvider(base: self, change: .scaled(factor)))
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftUI font modifiers forward to the font's existing trait-preserving operations.

public import Foundation
@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(OpenSwiftUI_v6_0, *)
public extension Font {
    func italic(_ isActive: Bool) -> Font {
        isActive ? italic() : self
    }

    func smallCaps(_ isActive: Bool) -> Font {
        isActive ? smallCaps() : self
    }

    func lowercaseSmallCaps(_ isActive: Bool) -> Font {
        isActive ? lowercaseSmallCaps() : self
    }

    func uppercaseSmallCaps(_ isActive: Bool) -> Font {
        isActive ? uppercaseSmallCaps() : self
    }

    func bold(_ isActive: Bool) -> Font {
        isActive ? bold() : self
    }

    func monospaced(_ isActive: Bool) -> Font {
        isActive ? monospaced() : self
    }

    func pointSize(_ size: CGFloat) -> Font {
        _finchSwiftUIPointSize(size)
    }

    func scaled(by factor: CGFloat) -> Font {
        _finchSwiftUIScaled(by: factor)
    }
}

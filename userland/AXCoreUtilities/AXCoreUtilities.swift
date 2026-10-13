// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AXCoreUtilities (private): accessibility helpers. Calculator uses one: a region's name
// as ICU gives it, in the current locale.

import Foundation

extension Locale.Region {
    public var icuDisplayName: String? {
        Locale.current.localizedString(forRegionCode: identifier)
    }
}

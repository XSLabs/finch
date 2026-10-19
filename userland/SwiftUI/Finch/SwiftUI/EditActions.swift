// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Edit action sets, to Apple's interface. A move or delete action is a bit in the set, so
// callers can combine and test the actions their collection supports.

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct EditActions<Collection>: OptionSet {
    public let rawValue: Int

    @inlinable
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static var all: Self { Self(rawValue: 3) }
}

@available(OpenSwiftUI_v4_0, *)
extension EditActions where Collection: SetAlgebra {
    public static var delete: Self { Self(rawValue: 1) }
    public static var all: Self { .delete }
}

@available(OpenSwiftUI_v4_0, *)
extension EditActions where Collection: MutableCollection {
    public static var move: Self { Self(rawValue: 2) }
    public static var all: Self { .move }
}

@available(OpenSwiftUI_v4_0, *)
extension EditActions where Collection: MutableCollection & SetAlgebra {
    public static var all: Self { [.move, .delete] }
}

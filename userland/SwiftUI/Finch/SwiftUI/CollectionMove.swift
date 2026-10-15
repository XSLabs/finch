// SPDX-License-Identifier: MIT OR Apache-2.0
//
// SwiftUI's collection reordering helper used by editable lists.

public import Foundation

@available(OpenSwiftUI_v1_0, *)
extension MutableCollection {
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty, destination >= 0, destination <= count else { return }

        let offsets = source.filter { $0 >= 0 && $0 < count }
        guard !offsets.isEmpty else { return }

        let elements = Array(self)
        let moved = offsets.map { elements[$0] }
        let movedOffsets = Set(offsets)
        var reordered = elements.enumerated().compactMap { item in
            movedOffsets.contains(item.offset) ? nil : item.element
        }
        let insertionOffset = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moved, at: insertionOffset)

        var index = startIndex
        for element in reordered {
            self[index] = element
            formIndex(after: &index)
        }
    }
}

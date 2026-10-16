// SPDX-License-Identifier: MIT OR Apache-2.0
import CoreGraphics
import Foundation

@main
struct CoreGraphicsOverlayTest {
    static func main() {
        print("CoreGraphics Swift overlay")
        let a = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        let b = CGPath(rect: CGRect(x: 5, y: 0, width: 10, height: 10), transform: nil)
        let united = a.union(b, using: CGPathFillRule.winding)
        let crossed = a.intersection(b, using: CGPathFillRule.winding)
        let cut = a.subtracting(b, using: CGPathFillRule.winding)
        print("union \(Int(united.boundingBoxOfPath.width.rounded())) \(united.contains(CGPoint(x: 12, y: 5)))")
        print("intersection \(Int(crossed.boundingBoxOfPath.width.rounded())) \(crossed.contains(CGPoint(x: 7, y: 5)))")
        print("subtract \(Int(cut.boundingBoxOfPath.width.rounded())) \(cut.contains(CGPoint(x: 2, y: 5))) \(cut.contains(CGPoint(x: 7, y: 5)))")

        let rects: Set<CGRect> = [CGRect(x: 0, y: 0, width: -2, height: 4), CGRect(x: -2, y: 0, width: 2, height: 4)]
        let sizes: Set<CGSize> = [CGSize(width: 2, height: 3), CGSize(width: 2, height: 3)]
        print("hashable \(rects.count) \(sizes.count)")
    }
}

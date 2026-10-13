// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Grid and GridRow, to Apple's interface (Grid is frozen: its tree of GridLayout over its
// content is built in the app). A grid's rows share their columns: each column is as wide as
// its widest cell, each row as tall as its tallest, and cells that can grow (a button with an
// infinite maximum width, say) share what the grid is offered beyond that, as Apple's do. A
// GridRow's views are cells of one row (a cell can span columns, gridCellColumns); any other
// view in a grid is a row of its own across every column. Cells sit in their space by the
// cell's anchor, else the column's alignment (gridColumnAlignment), else the row's and the
// grid's alignment.
//
// The cells tell the layout where they belong through layout values: a GridRow marks its
// views with its row (the row's graph attribute, unique while the row exists) and alignment.

import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - What cells tell the layout

struct _FinchGridRowInfo: Equatable {
    var id: AnyAttribute
    var alignment: VerticalAlignment?
}

struct _FinchGridRowKey: LayoutValueKey {
    static let defaultValue: _FinchGridRowInfo? = nil
}

struct _FinchGridSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

struct _FinchGridColumnAlignmentKey: LayoutValueKey {
    static let defaultValue: HorizontalAlignment? = nil
}

struct _FinchGridAnchorKey: LayoutValueKey {
    static let defaultValue: UnitPoint? = nil
}

struct _FinchGridUnsizedKey: LayoutValueKey {
    static let defaultValue: Axis.Set = []
}

// MARK: - Grid

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct Grid<Content> where Content: View {
    @usableFromInline
    var _tree: _VariadicView.Tree<GridLayout, Content>

    @inlinable
    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
                @ViewBuilder content: () -> Content) {
        let root = GridLayout(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
        _tree = .init(root) { content() }
    }

    nonisolated public static func _makeView(view: _GraphValue<Grid<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        _VariadicView.Tree<GridLayout, Content>._makeView(view: view[offset: { .of(&$0._tree) }], inputs: inputs)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v4_0, *)
extension Grid: View, PrimitiveView {}

@available(*, unavailable)
extension Grid: Sendable {}

// MARK: - GridRow

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct GridRow<Content> where Content: View {
    @usableFromInline
    var alignment: VerticalAlignment?
    @usableFromInline
    var content: Content

    @inlinable
    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    typealias Cells = ModifiedContent<Content, _TraitWritingModifier<_LayoutTrait<_FinchGridRowKey>>>

    /// The row's views, each marked as a cell of this row.
    private struct RowCells: Rule {
        @Attribute var row: GridRow
        var id: AnyAttribute

        var value: Cells {
            row.content.modifier(_TraitWritingModifier(value: _FinchGridRowInfo(id: id, alignment: row.alignment)))
        }
    }

    /// Outside a grid, a row's views stand side by side.
    private struct Stack: Rule {
        @Attribute var row: GridRow

        var value: HStack<Content> {
            HStack(alignment: row.alignment ?? .center) { row.content }
        }
    }

    nonisolated public static func _makeView(view: _GraphValue<GridRow<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        HStack<Content>._makeView(view: _GraphValue(Stack(row: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<GridRow<Content>>, inputs: _ViewListInputs) -> _ViewListOutputs {
        Cells._makeViewList(view: _GraphValue(RowCells(row: view.value, id: view.value.identifier)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        Content._viewListCount(inputs: inputs)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v4_0, *)
extension GridRow: View, PrimitiveView {}

@available(*, unavailable)
extension GridRow: Sendable {}

// MARK: - Cell modifiers

@available(OpenSwiftUI_v4_0, *)
extension View {
    @inlinable
    nonisolated public func gridCellColumns(_ count: Int) -> some View {
        modifier(_GridCellSizeModifier(count: count, axis: .horizontal))
    }

    @inlinable
    nonisolated public func gridCellAnchor(_ anchor: UnitPoint) -> some View {
        modifier(_GridAnchorModifier(anchor: anchor))
    }

    @inlinable
    nonisolated public func gridColumnAlignment(_ guide: HorizontalAlignment) -> some View {
        modifier(_GridAlignmentModifier(alignment: guide.key))
    }

    @inlinable
    nonisolated public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View {
        modifier(_GridUnsizedAxesModifier(axes: axes))
    }
}

/// A cell modifier: the cell as it is, with a layout value for the grid.
protocol _FinchGridCellModifier: PrimitiveViewModifier {
    associatedtype Key: LayoutValueKey
    var layoutValue: Key.Value { get }
}

private struct _FinchGridCellTrait<M: _FinchGridCellModifier>: Rule {
    @Attribute var modifier: M

    var value: _TraitWritingModifier<_LayoutTrait<M.Key>> {
        _TraitWritingModifier(value: modifier.layoutValue)
    }
}

extension _FinchGridCellModifier {
    static func makeCellView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        _TraitWritingModifier<_LayoutTrait<Key>>._makeView(
            modifier: _GraphValue(_FinchGridCellTrait(modifier: modifier.value)), inputs: inputs, body: body)
    }

    static func makeCellViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        _TraitWritingModifier<_LayoutTrait<Key>>._makeViewList(
            modifier: _GraphValue(_FinchGridCellTrait(modifier: modifier.value)), inputs: inputs, body: body)
    }
}

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct _GridCellSizeModifier: ViewModifier, _FinchGridCellModifier {
    @usableFromInline
    var count: Int
    @usableFromInline
    var axis: Axis

    @inlinable
    init(count: Int, axis: Axis) {
        self.count = count
        self.axis = axis
    }

    typealias Key = _FinchGridSpanKey
    var layoutValue: Int { axis == .horizontal ? max(1, count) : 1 }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        makeCellView(modifier: modifier, inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        makeCellViewList(modifier: modifier, inputs: inputs, body: body)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct _GridAnchorModifier: ViewModifier, _FinchGridCellModifier {
    @usableFromInline
    var anchor: UnitPoint

    @inlinable
    init(anchor: UnitPoint) { self.anchor = anchor }

    typealias Key = _FinchGridAnchorKey
    var layoutValue: UnitPoint? { anchor }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        makeCellView(modifier: modifier, inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        makeCellViewList(modifier: modifier, inputs: inputs, body: body)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct _GridAlignmentModifier: ViewModifier, _FinchGridCellModifier {
    @usableFromInline
    var alignment: AlignmentKey

    @inlinable
    init(alignment: AlignmentKey) { self.alignment = alignment }

    typealias Key = _FinchGridColumnAlignmentKey
    var layoutValue: HorizontalAlignment? { HorizontalAlignment(alignment.id) }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        makeCellView(modifier: modifier, inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        makeCellViewList(modifier: modifier, inputs: inputs, body: body)
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct _GridUnsizedAxesModifier: ViewModifier, _FinchGridCellModifier {
    @usableFromInline
    var axes: Axis.Set

    @inlinable
    init(axes: Axis.Set) { self.axes = axes }

    typealias Key = _FinchGridUnsizedKey
    var layoutValue: Axis.Set { axes }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        makeCellView(modifier: modifier, inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs,
                                                 body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        makeCellViewList(modifier: modifier, inputs: inputs, body: body)
    }

    public typealias Body = Never
}

extension _GridCellSizeModifier: Sendable, BitwiseCopyable {}
extension _GridAnchorModifier: Sendable, BitwiseCopyable {}
extension _GridAlignmentModifier: Sendable, BitwiseCopyable {}
extension _GridUnsizedAxesModifier: Sendable, BitwiseCopyable {}

// MARK: - GridLayout

@available(OpenSwiftUI_v4_0, *)
@frozen
public struct GridLayout: _VariadicView.UnaryViewRoot {
    public var alignment: Alignment
    public var horizontalSpacing: CGFloat?
    public var verticalSpacing: CGFloat?

    @inlinable
    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    nonisolated public static func _makeView(root: _GraphValue<GridLayout>, inputs: _ViewInputs,
                                             body: (_Graph, _ViewInputs) -> _ViewListOutputs) -> _ViewOutputs {
        _makeLayoutView(root: root, inputs: inputs, body: body)
    }

    public typealias Body = Never
}

extension GridLayout: BitwiseCopyable {}

@available(OpenSwiftUI_v4_0, *)
extension GridLayout {
    public struct Cache {
        /// The rows, each its cells (subview indexes, first column, span); nil for a row
        /// that's one view across the grid.
        var rows: [Row] = []
        var columnCount = 0

        struct Cell {
            var index: Int
            var column: Int
            var span: Int
        }

        struct Row {
            var cells: [Cell]
            var spansGrid: Bool
            var alignment: VerticalAlignment?
        }
    }
}

@available(*, unavailable)
extension GridLayout.Cache: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension GridLayout: Layout {
    public typealias AnimatableData = EmptyAnimatableData

    private static let defaultSpacing: CGFloat = 8

    public func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        updateCache(&cache, subviews: subviews)
        return cache
    }

    /// The rows: consecutive cells of one GridRow, and every other view alone.
    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        var rows: [Cache.Row] = []
        var currentID: AnyAttribute?
        for index in subviews.indices {
            let subview = subviews[index]
            if let info = subview[_FinchGridRowKey.self] {
                let span = subview[_FinchGridSpanKey.self]
                if currentID == info.id, var row = rows.popLast() {
                    let column = row.cells.last.map { $0.column + $0.span } ?? 0
                    row.cells.append(Cache.Cell(index: index, column: column, span: span))
                    rows.append(row)
                } else {
                    rows.append(Cache.Row(cells: [Cache.Cell(index: index, column: 0, span: span)], spansGrid: false,
                                          alignment: info.alignment))
                }
                currentID = info.id
            } else {
                rows.append(Cache.Row(cells: [Cache.Cell(index: index, column: 0, span: 1)], spansGrid: true, alignment: nil))
                currentID = nil
            }
        }
        cache.rows = rows
        cache.columnCount = rows.filter { !$0.spansGrid }.map { $0.cells.last.map { $0.column + $0.span } ?? 0 }.max() ?? 0
    }

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        ViewSpacing()
    }

    private var hSpacing: CGFloat { horizontalSpacing ?? Self.defaultSpacing }
    private var vSpacing: CGFloat { verticalSpacing ?? Self.defaultSpacing }

    /// The columns' widths and the rows' heights for a proposal.
    private func tracks(_ proposal: ProposedViewSize, subviews: Subviews, cache: Cache) -> (columns: [CGFloat], rows: [CGFloat]) {
        let columnCount = cache.columnCount
        // each column: as wide as its widest single cell; how far its cells can grow
        var ideal = [CGFloat](repeating: 0, count: columnCount)
        var maximum = [CGFloat](repeating: 0, count: columnCount)
        for row in cache.rows where !row.spansGrid {
            for cell in row.cells where cell.span == 1 && cell.column < columnCount {
                let subview = subviews[cell.index]
                if subview[_FinchGridUnsizedKey.self].contains(.horizontal) { continue }
                ideal[cell.column] = max(ideal[cell.column], subview.sizeThatFits(.unspecified).width)
                maximum[cell.column] = max(maximum[cell.column], subview.sizeThatFits(ProposedViewSize(width: .infinity, height: nil)).width)
            }
        }
        // a spanning cell wider than its columns widens them evenly
        for row in cache.rows where !row.spansGrid {
            for cell in row.cells where cell.span > 1 {
                let end = min(columnCount, cell.column + cell.span)
                guard cell.column < end else { continue }
                let need = subviews[cell.index].sizeThatFits(.unspecified).width - hSpacing * CGFloat(end - cell.column - 1)
                let have = ideal[cell.column ..< end].reduce(0, +)
                if need > have {
                    let extra = (need - have) / CGFloat(end - cell.column)
                    for c in cell.column ..< end { ideal[c] += extra }
                }
            }
        }
        var columns = ideal
        if let width = proposal.width, width.isFinite, columnCount > 0 {
            let spacing = hSpacing * CGFloat(columnCount - 1)
            var extra = width - spacing - columns.reduce(0, +)
            // what's left shared by the columns that can grow, up to their maximums
            var growing = (0 ..< columnCount).filter { maximum[$0] > ideal[$0] + 0.5 }
            while extra > 0.5, !growing.isEmpty {
                let share = extra / CGFloat(growing.count)
                var used: CGFloat = 0
                var stillGrowing: [Int] = []
                for c in growing {
                    let add = min(share, maximum[c] - columns[c])
                    columns[c] += add
                    used += add
                    if maximum[c] - columns[c] > 0.5 { stillGrowing.append(c) }
                }
                extra -= used
                if used < 0.5 { break }
                growing = stillGrowing
            }
            // too little: the columns that can shrink, shrink
            if extra < -0.5 {
                let shrinking = (0 ..< columnCount).filter { c in
                    cache.rows.contains { !$0.spansGrid && $0.cells.contains { $0.column == c && subviews[$0.index].sizeThatFits(.zero).width < columns[c] } }
                }
                if !shrinking.isEmpty {
                    let cut = -extra / CGFloat(shrinking.count)
                    for c in shrinking { columns[c] = max(0, columns[c] - cut) }
                }
            }
        }
        let gridWidth = columns.reduce(0, +) + hSpacing * CGFloat(max(0, columnCount - 1))

        // each row: as tall as its tallest cell at its width; then the rows that can grow share the height
        var rowIdeal: [CGFloat] = []
        var rowMax: [CGFloat] = []
        for row in cache.rows {
            var h: CGFloat = 0, hm: CGFloat = 0
            for cell in row.cells {
                let subview = subviews[cell.index]
                if subview[_FinchGridUnsizedKey.self].contains(.vertical) { continue }
                let w = row.spansGrid ? (columnCount > 0 ? gridWidth : proposal.width) : cellWidth(cell, columns)
                h = max(h, subview.sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
                hm = max(hm, subview.sizeThatFits(ProposedViewSize(width: w, height: .infinity)).height)
            }
            rowIdeal.append(h)
            rowMax.append(hm)
        }
        var rows = rowIdeal
        if let height = proposal.height, height.isFinite, !rows.isEmpty {
            var extra = height - vSpacing * CGFloat(rows.count - 1) - rows.reduce(0, +)
            var growing = rows.indices.filter { rowMax[$0] > rowIdeal[$0] + 0.5 }
            while extra > 0.5, !growing.isEmpty {
                let share = extra / CGFloat(growing.count)
                var used: CGFloat = 0
                var stillGrowing: [Int] = []
                for r in growing {
                    let add = min(share, rowMax[r] - rows[r])
                    rows[r] += add
                    used += add
                    if rowMax[r] - rows[r] > 0.5 { stillGrowing.append(r) }
                }
                extra -= used
                if used < 0.5 { break }
                growing = stillGrowing
            }
        }
        return (columns, rows)
    }

    private func cellWidth(_ cell: Cache.Cell, _ columns: [CGFloat]) -> CGFloat {
        let end = min(columns.count, cell.column + cell.span)
        guard cell.column < end else { return 0 }
        return columns[cell.column ..< end].reduce(0, +) + hSpacing * CGFloat(end - cell.column - 1)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let (columns, rows) = tracks(proposal, subviews: subviews, cache: cache)
        var width = columns.reduce(0, +) + hSpacing * CGFloat(max(0, columns.count - 1))
        // a row across the grid can make it wider
        for row in cache.rows where row.spansGrid {
            width = max(width, subviews[row.cells[0].index].sizeThatFits(ProposedViewSize(width: columns.isEmpty ? proposal.width : width, height: nil)).width)
        }
        let height = rows.reduce(0, +) + vSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (columns, rows) = tracks(ProposedViewSize(bounds.size), subviews: subviews, cache: cache)
        var xs: [CGFloat] = []
        var x = bounds.minX
        for width in columns {
            xs.append(x)
            x += width + hSpacing
        }
        var y = bounds.minY
        for (r, row) in cache.rows.enumerated() {
            let height = rows[r]
            for cell in row.cells {
                let subview = subviews[cell.index]
                let frame: CGRect
                if row.spansGrid || columns.isEmpty {
                    frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: height)
                } else {
                    frame = CGRect(x: cell.column < xs.count ? xs[cell.column] : bounds.minX, y: y,
                                   width: cellWidth(cell, columns), height: height)
                }
                let unsized = subview[_FinchGridUnsizedKey.self]
                let size = subview.sizeThatFits(ProposedViewSize(width: frame.width, height: frame.height))
                let w = unsized.contains(.horizontal) ? frame.width : min(size.width, frame.width)
                let h = unsized.contains(.vertical) ? frame.height : min(size.height, frame.height)
                // where in its space: the cell's anchor, the column's alignment, the row's and the grid's
                let anchor: UnitPoint
                if let a = subview[_FinchGridAnchorKey.self] {
                    anchor = a
                } else {
                    let horizontal = subview[_FinchGridColumnAlignmentKey.self] ?? columnAlignment(cell.column, cache: cache, subviews: subviews) ?? alignment.horizontal
                    let vertical = row.alignment ?? alignment.vertical
                    anchor = UnitPoint(x: Self.fraction(horizontal), y: Self.fraction(vertical))
                }
                let origin = CGPoint(x: frame.minX + (frame.width - w) * anchor.x, y: frame.minY + (frame.height - h) * anchor.y)
                subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: w, height: h))
            }
            y += height + vSpacing
        }
    }

    /// A column's alignment: any of its cells' gridColumnAlignment applies to the whole column.
    private func columnAlignment(_ column: Int, cache: Cache, subviews: Subviews) -> HorizontalAlignment? {
        for row in cache.rows where !row.spansGrid {
            for cell in row.cells where cell.column == column {
                if let a = subviews[cell.index][_FinchGridColumnAlignmentKey.self] { return a }
            }
        }
        return nil
    }

    private static func fraction(_ a: HorizontalAlignment) -> CGFloat {
        a == .leading ? 0 : a == .trailing ? 1 : 0.5
    }

    private static func fraction(_ a: VerticalAlignment) -> CGFloat {
        a == .top || a == .firstTextBaseline ? 0 : a == .bottom || a == .lastTextBaseline ? 1 : 0.5
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        nil
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        nil
    }
}

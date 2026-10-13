// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The keys. Each acts on the row the cursor is in (State.swift): edit(_:) walks into the
// innermost open container, runs the key there, and when the key leaves that row (an
// operator after an exponent, ")" in a group) closes the container and runs it again
// outside. Delete and clear take an empty row's container out.

import Foundation

extension CalculatorState {
    typealias Key = CalculateExpression.Operation.Key

    mutating func apply(_ operation: CalculateExpression.Operation) -> Bool {
        let key = operation.key
        guard key == .custom || isPermitted(key) else { return false }
        let before = row
        let applied: Bool
        if isRPN {
            applied = applyRPN(operation)
        } else {
            applied = applyKey(operation)
        }
        if applied {
            sourceText = nil
            if key != .clear && key != .allClear && key != .delete { removedTokens = nil }
            if key != .equals { repeated = false }
            let binaryKeys: Set<Key> = [.add, .subtract, .multiply, .divide]
            if key == .clear || key == .allClear || (key == .delete && ((isRPN && row.isEmpty) || activeOperation?.key == .power)) {
                cleared = true
            } else if before.isEmpty && binaryKeys.contains(key) {
                // an operator first: what it starts from is implied
            } else if isRPN {
                cleared = false
            } else if row != before || key == .equals || key == .negate {
                cleared = row.isEmpty && key != .negate
            }
            reevaluate()
        }
        return applied
    }

    /// Whether a key works at all now (allowedOperations is what a calculator shows; a key
    /// left out of it may work all the same).
    func isPermitted(_ key: Key) -> Bool {
        let programmerOnly: Set<Key> = [.mod, .and, .or, .xor, .nor, .not, .neg, .leftShift, .rightShift,
                                        .leftShiftCustom, .rightShiftCustom, .leftRotate, .rightRotate,
                                        .byteFlip, .wordFlip]
        let rpnOnly: Set<Key> = [.enter, .swap, .drop, .rollIn, .rollOut]
        if programmerOnly.contains(key) || key.digitValue != nil { return isAllowed(key) }
        if rpnOnly.contains(key) { return isRPN }
        return isAllowed(key) || key == .reverseRoot
    }

    private mutating func applyKey(_ operation: CalculateExpression.Operation) -> Bool {
        let key = operation.key
        if let custom = operation as? CalculateExpression.CustomOperandOperation {
            let operand = literal(for: custom.operand.doubleValue)
            return run { row, _ in
                Self.appendOperand(&row, .literal(operand))
                return .done(true)
            }
        }
        if let text = key.digitText {
            let radix = isProgrammer ? UInt64(base.rawValue) : nil
            return run { row, _ in .done(Self.enterDigits(&row, text, radix: radix)) }
        }
        switch key {
        case .decimal:
            return run { row, _ in
                if case .literal(let s)? = row.last {
                    guard !s.contains("."), !s.contains("e"), !s.contains("E") else { return .done(false) }
                    row[row.count - 1] = .literal(s + ".")
                } else {
                    Self.appendOperand(&row, .literal("0."))
                }
                return .done(true)
            }
        case .ee:
            return run { row, _ in
                guard case .literal(let s)? = row.last, !s.contains("e"), !s.contains("E") else { return .done(false) }
                row[row.count - 1] = .literal(s + "e")
                return .done(true)
            }
        case .add: return binary(.add)
        case .subtract: return binary(.subtract)
        case .multiply: return binary(.multiply)
        case .divide: return binary(.divide)
        case .mod: return binary(.mod)
        case .and: return binary(.and)
        case .or: return binary(.or)
        case .xor: return binary(.xor)
        case .nor: return binary(.nor)
        case .leftShiftCustom: return binary(.leftShift)
        case .rightShiftCustom: return binary(.rightShift)
        case .leftShift: return byOne(.leftShift)
        case .rightShift: return byOne(.rightShift)
        case .leftRotate: return byOne(.leftRotate)
        case .rightRotate: return byOne(.rightRotate)
        case .power:
            return withOperand { row, operand in
                guard let operand else { return false }
                row += Self.decoratable(operand) + [.power(base: nil, exponent: [], open: true)]
                return true
            }
        case .square, .cube:
            return withOperand { row, operand in
                guard let operand else { return false }
                row += Self.decoratable(operand) + [.power(base: nil, exponent: [.literal(key == .square ? "2" : "3")], open: false)]
                return true
            }
        case .exponentialBaseCustom:
            return withOperand { row, operand in
                guard let operand else { return false }
                row.append(.power(base: [], exponent: operand, open: true))
                return true
            }
        case .exponentialBaseEuler: return exponential(.constant(.e))
        case .exponentialBase10: return exponential(.literal("10"))
        case .exponentialBase2: return exponential(.literal("2"))
        case .reciprocal:
            return withOperand { row, operand in
                guard let operand else { return false }
                row.append(.group([.literal("1"), .op(.divide)] + operand, closed: true))
                return true
            }
        case .not where row.isEmpty, .neg where row.isEmpty:
            row = [.function(key == .not ? .not : .neg, [.literal("0")], closed: false)]
            return true
        case .sine: return function(.sin)
        case .cosine: return function(.cos)
        case .tangent: return function(.tan)
        case .inverseSine: return function(.asin)
        case .inverseCosine: return function(.acos)
        case .inverseTangent: return function(.atan)
        case .hyperbolicSine: return function(.sinh)
        case .hyperbolicCosine: return function(.cosh)
        case .hyperbolicTangent: return function(.tanh)
        case .inverseHyperbolicSine: return function(.asinh)
        case .inverseHyperbolicCosine: return function(.acosh)
        case .inverseHyperbolicTangent: return function(.atanh)
        case .logarithmNatural: return function(.ln)
        case .not: return function(.not)
        case .neg: return function(.neg)
        case .byteFlip: return function(.byteFlip)
        case .wordFlip: return function(.wordFlip)
        case .squareRoot: return root(nil)
        case .cubeRoot: return root([.literal("3")])
        case .root, .reverseRoot:
            return withOperand { row, operand in
                guard let operand else { return false }
                row.append(.root(index: [], operand, closed: true, indexOpen: true))
                return true
            }
        case .logarithmBase10: return log([.literal("10")])
        case .logarithmBase2: return log([.literal("2")])
        case .logarithmBaseCustom:
            return withOperand { row, operand in
                guard let operand else { return false }
                row.append(.log(base: [], operand, closed: true, baseOpen: true))
                return true
            }
        case .percent: return postfix(.percent)
        case .factorial: return postfix(.factorial)
        case .pi: return constant(.pi)
        case .eulerNumber: return constant(.e)
        case .random:
            let r = String(format: "%.8g", Double.random(in: 0 ..< 1))
            return run { row, _ in
                Self.appendOperand(&row, .literal(r))
                return .done(true)
            }
        case .negate:
            if row.isEmpty {
                row = [.literal("0")]
                return true
            }
            return negate()
        case .openParenthesis:
            return run { row, _ in
                Self.appendOperand(&row, .group([], closed: false))
                return .done(true)
            }
        case .closeParenthesis:
            return run(closesParen: true) { _, kind in
                kind == .top ? .done(false) : .leave
            }
        case .equals:
            return true
        case .delete:
            return deleteLast()
        case .clear:
            return clearEntry()
        case .allClear:
            clearAll()
            return true
        default:
            return false
        }
    }

    // MARK: The cursor's row

    /// Runs an action in the row the cursor is in.
    mutating func run(closesParen: Bool = false, _ action: (inout Row, RowKind) -> Edit) -> Bool {
        var top = row
        var removedContainer: Node?
        let result = Self.edit(&top, kind: .top, closesParen: closesParen, removed: &removedContainer, action)
        if let removedContainer { removedTokens = Self.openingTokens(removedContainer) }
        switch result {
        case .done(let applied):
            row = top
            return applied
        case .leave:
            row = top
            return false
        case .remove:
            row = top
            return false
        }
    }

    /// The row a container's cursor is in, and its kind.
    static func openChild(_ node: Node) -> (Row, RowKind)? {
        switch node {
        case .power(let base, let exponent, true):
            if let base { return (base, .tight) }
            return (exponent, .tight)
        case .group(let r, false):
            return (r, .paren)
        case .function(let f, let r, false):
            return (r, f.isPrefix ? .tight : .paren)
        case .root(let index, let r, let closed, let indexOpen):
            if indexOpen, let index { return (index, .tight) }
            return closed ? nil : (r, .paren)
        case .log(let base, let r, let closed, let baseOpen):
            if baseOpen { return (base, .tight) }
            return closed ? nil : (r, .paren)
        default:
            return nil
        }
    }

    static func replacingOpenChild(_ node: Node, with r: Row) -> Node {
        switch node {
        case .power(let base, let exponent, let open):
            return base != nil ? .power(base: r, exponent: exponent, open: open) : .power(base: nil, exponent: r, open: open)
        case .group(_, let closed):
            return .group(r, closed: closed)
        case .function(let f, _, let closed):
            return .function(f, r, closed: closed)
        case .root(let index, let radicand, let closed, let indexOpen):
            return indexOpen ? .root(index: r, radicand, closed: closed, indexOpen: true) : .root(index: index, r, closed: closed, indexOpen: false)
        case .log(let base, let arg, let closed, let baseOpen):
            return baseOpen ? .log(base: r, arg, closed: closed, baseOpen: true) : .log(base: base, r, closed: closed, baseOpen: false)
        default:
            return node
        }
    }

    /// The container with its cursor's row closed.
    static func closing(_ node: Node) -> Node {
        switch node {
        case .power(let base, let exponent, _): .power(base: base, exponent: exponent, open: false)
        case .group(let r, _): .group(r, closed: true)
        case .function(let f, let r, _): .function(f, r, closed: true)
        case .root(let index, let r, let closed, let indexOpen):
            indexOpen ? .root(index: index, r, closed: closed, indexOpen: false) : .root(index: index, r, closed: true, indexOpen: false)
        case .log(let base, let r, let closed, let baseOpen):
            baseOpen ? .log(base: base, r, closed: closed, baseOpen: false) : .log(base: base, r, closed: true, baseOpen: false)
        default: node
        }
    }

    static func edit(_ row: inout Row, kind: RowKind, closesParen: Bool, removed: inout Node?,
                     _ action: (inout Row, RowKind) -> Edit) -> Edit {
        if let last = row.last, let (child, childKind) = openChild(last) {
            var inner = child
            let result = edit(&inner, kind: childKind, closesParen: closesParen, removed: &removed, action)
            row[row.count - 1] = replacingOpenChild(last, with: inner)
            switch result {
            case .done:
                return result
            case .leave:
                row[row.count - 1] = closing(row[row.count - 1])
                if closesParen && childKind == .paren { return .done(true) }
            case .remove:
                removed = row[row.count - 1]
                row[row.count - 1 ..< row.count] = ArraySlice(removingContainer(row[row.count - 1]))
                return .done(true)
            }
        }
        return action(&row, kind)
    }

    /// The tokens a container starts with (what deleting its empty row takes out).
    static func openingTokens(_ node: Node) -> [CalculateExpression.RichToken] {
        typealias T = CalculateExpression.RichToken
        let placeholder = CalculateExpression.RichExpression([T(type: .placeholder, text: "")])
        switch node {
        case .power(let base, let exponent, _):
            return [T(type: .exponentiate, text: "", left: base == nil ? nil : placeholder,
                      right: exponent.isEmpty ? placeholder : CalculateExpression.RichExpression(exponent.richTokens()))]
        case .group:
            return [T(type: .openParenthesis, text: "(")]
        default:
            return Array(([node].richTokens()).prefix(2))
        }
    }

    /// What's left of a container whose cursor's row is taken out: nothing, or (a base,
    /// index or log base being typed) the operand it applied to.
    static func removingContainer(_ node: Node) -> Row {
        switch node {
        case .power(let base?, let exponent, _) where base.isEmpty: exponent
        case .root(let index?, let r, _, true) where index.isEmpty: r
        case .log(let base, let r, _, true) where base.isEmpty: r
        default: []
        }
    }

    // MARK: Operands

    /// Where the last operand starts: its atom, with the power or postfix on it.
    static func operandStart(_ row: Row) -> Int? {
        guard let last = row.last, last.isOperand else { return nil }
        var i = row.count - 1
        if last.isDecoration {
            guard i > 0, row[i - 1].isAtom else { return nil }
            i -= 1
        }
        return i
    }

    /// An operand that will take a power or postfix: in parentheses if it has one already.
    static func decoratable(_ operand: Row) -> Row {
        operand.count > 1 ? [.group(operand, closed: true)] : operand
    }

    /// Appends an operand, with a × after another operand.
    static func appendOperand(_ row: inout Row, _ node: Node) {
        if let last = row.last, last.isOperand, last != .postfix(.percent) {
            row.append(.op(.multiply))
        }
        row.append(node)
    }

    /// Runs an action on the last operand, taken out of the row (nil when there is none).
    mutating func withOperand(_ action: @escaping (inout Row, Row?) -> Bool) -> Bool {
        run { row, _ in
            if let start = Self.operandStart(row) {
                let operand = Array(row[start...])
                row.removeSubrange(start...)
                let ok = action(&row, operand)
                if !ok { row += operand }
                return .done(ok)
            }
            return .done(action(&row, nil))
        }
    }

    // MARK: Keys

    /// Digits typed: onto the number being typed, or a new one. In programmer mode (with a
    /// radix), the number's value in decimal.
    private static func enterDigits(_ row: inout Row, _ text: String, radix: UInt64?) -> Bool {
        if radix != nil {
            if case .literal(let s)? = row.last {
                row[row.count - 1] = .literal(s == "0" ? (text == "00" ? "0" : text) : s + text)
            } else {
                appendOperand(&row, .literal(text == "00" ? "0" : text))
            }
            return true
        }
        if case .literal(let s)? = row.last {
            if s == "0" {
                row[row.count - 1] = .literal(text == "00" ? "0" : text)
            } else if s.contains("E") {
                // a result's literal: a new number
                row.append(.op(.multiply))
                row.append(.literal(text == "00" ? "0" : text))
            } else if let e = s.firstIndex(of: "e") {
                // an exponent: three digits at most
                guard s[s.index(after: e)...].filter(\.isNumber).count + text.count <= 3 else { return false }
                row[row.count - 1] = .literal(s + text)
            } else {
                row[row.count - 1] = .literal(s + text)
            }
            return true
        }
        appendOperand(&row, .literal(text == "00" ? "0" : text))
        return true
    }

    private mutating func binary(_ op: Binary) -> Bool {
        run { row, kind in
            if kind == .tight && !row.isEmpty { return .leave }
            guard let last = row.last else {
                switch kind {
                case .top:
                    row = op == .subtract ? [.op(.subtract)] : [.literal("0"), .op(op)]
                    return .done(true)
                default:
                    guard op == .subtract else { return .done(false) }
                    row = [.op(.subtract)]
                    return .done(true)
                }
            }
            if op == .subtract, kind == .top, row == [.literal("0")] {
                row = [.op(.subtract)]
                return .done(true)
            }
            if case .literal(let s) = last, s.hasSuffix("e") {
                guard op == .subtract else { return .done(false) }
                row[row.count - 1] = .literal(s + "-")
                return .done(true)
            }
            if case .op(let previous) = last {
                if op == .subtract && (previous == .multiply || previous == .divide) {
                    row.append(.op(.subtract))
                    return .done(true)
                }
                if row.count == 1 {
                    // a leading sign: an operator other than minus starts from zero
                    row = op == .subtract ? [.op(.subtract)] : [.literal("0"), .op(op)]
                } else {
                    row[row.count - 1] = .op(op)
                }
                return .done(true)
            }
            row.append(.op(op))
            return .done(true)
        }
    }

    private mutating func byOne(_ op: Binary) -> Bool {
        run { row, _ in
            guard let last = row.last, last.isOperand else { return .done(false) }
            row += [.op(op), .literal("1")]
            return .done(true)
        }
    }

    private mutating func exponential(_ base: Node) -> Bool {
        withOperand { row, operand in
            if let operand {
                row += [base, .power(base: nil, exponent: operand, open: false)]
            } else {
                Self.appendOperand(&row, base)
                row.append(.power(base: nil, exponent: [], open: true))
            }
            return true
        }
    }

    private mutating func function(_ f: Function) -> Bool {
        withOperand { row, operand in
            if let operand {
                row.append(.function(f, operand, closed: true))
            } else {
                row.append(.function(f, [], closed: false))
            }
            return true
        }
    }

    private mutating func root(_ index: Row?) -> Bool {
        withOperand { row, operand in
            if let operand {
                row.append(.root(index: index, operand, closed: true, indexOpen: false))
            } else {
                row.append(.root(index: index, [], closed: false, indexOpen: false))
            }
            return true
        }
    }

    private mutating func log(_ base: Row) -> Bool {
        withOperand { row, operand in
            if let operand {
                row.append(.log(base: base, operand, closed: true, baseOpen: false))
            } else {
                row.append(.log(base: base, [], closed: false, baseOpen: false))
            }
            return true
        }
    }

    private mutating func postfix(_ p: Postfix) -> Bool {
        run { row, kind in
            if kind == .tight && !row.isEmpty { return .leave }
            guard let start = Self.operandStart(row) else { return .done(false) }
            let operand = Array(row[start...])
            // a second postfix goes on the first's operand in parentheses; one after a power doesn't
            let wrap: Row = if case .postfix? = operand.last, operand.count > 1 { [.group(operand, closed: true)] } else { operand }
            row.replaceSubrange(start..., with: wrap + [.postfix(p)])
            return .done(true)
        }
    }

    private mutating func constant(_ c: Constant) -> Bool {
        run { row, _ in
            if case .literal(let s)? = row.last, !s.hasSuffix("e") {
                // 2π: a number's multiple
                row.append(.constant(c))
            } else {
                Self.appendOperand(&row, .constant(c))
            }
            return .done(true)
        }
    }

    /// ±: the operand's sign, as (-x), or an exponent's.
    private mutating func negate() -> Bool {
        if row.isEmpty { return true }
        return run { row, _ in
            if case .literal(let s)? = row.last, let e = s.firstIndex(of: "e") {
                let mantissa = s[..<e], exponent = s[s.index(after: e)...]
                if exponent.filter(\.isNumber).isEmpty { return .done(true) }
                row[row.count - 1] = .literal(mantissa + "e" + (exponent.hasPrefix("-") ? String(exponent.dropFirst()) : "-" + exponent))
                return .done(true)
            }
            guard let start = Self.operandStart(row) else { return .done(false) }
            let operand = Array(row[start...])
            if operand.count == 1, case .group(let inner, true) = operand[0], inner.first == .op(.subtract) {
                row.replaceSubrange(start..., with: inner.dropFirst())
            } else {
                row.replaceSubrange(start..., with: [.group([.op(.subtract)] + operand, closed: true)])
            }
            return .done(true)
        }
    }

    private mutating func deleteLast() -> Bool {
        guard !row.isEmpty else { return false }
        var removed: [CalculateExpression.RichToken] = []
        removedTokens = nil
        let radix = radix
        let ok = run { row, kind in
            Self.deleteIn(&row, kind: kind, radix: radix, removed: &removed)
        }
        if ok && removedTokens == nil { removedTokens = removed }
        return ok
    }

    static func deleteIn(_ row: inout Row, kind: RowKind, radix: Int?, removed: inout [CalculateExpression.RichToken]) -> Edit {
        typealias T = CalculateExpression.RichToken
        guard let last = row.last else {
            return kind == .top ? .done(false) : .remove
        }
        let close = [T(type: .closeParenthesis, text: ")")]
        switch last {
        case .literal(var s):
            let c = s.removeLast()
            removed = [Node.literal(String(c))].richTokens(radix)
            if s.isEmpty || s == "-" {
                row.removeLast()
            } else {
                row[row.count - 1] = .literal(s)
            }
        case .power(nil, let exponent, false):
            // back into the exponent
            var inner = exponent
            let r = deleteIn(&inner, kind: .tight, radix: radix, removed: &removed)
            if case .remove = r {
                removed = openingTokens(last)
                row.removeLast()
            } else {
                row[row.count - 1] = .power(base: nil, exponent: inner, open: true)
            }
        case .group(let r, true):
            row[row.count - 1] = .group(r, closed: false)
            removed = close
        case .function(let f, let r, true) where !f.isPrefix:
            row[row.count - 1] = .function(f, r, closed: false)
            removed = close
        case .root(let index, let r, true, false):
            row[row.count - 1] = .root(index: index, r, closed: false, indexOpen: false)
            removed = close
        case .log(let base, let r, true, false):
            row[row.count - 1] = .log(base: base, r, closed: false, baseOpen: false)
            removed = close
        default:
            removed = [last].richTokens(radix)
            row.removeLast()
        }
        return .done(true)
    }

    /// C: the number being entered (or the last operand) goes; an empty function goes.
    private mutating func clearEntry() -> Bool {
        guard !row.isEmpty else { return true }
        var removed: [CalculateExpression.RichToken] = []
        removedTokens = nil
        let radix = radix
        let ok = run { row, kind in
            guard !row.isEmpty else { return kind == .paren ? .remove : .done(true) }
            if let start = Self.operandStart(row) {
                removed = Array(row[start...]).richTokens(radix)
                row.removeSubrange(start...)
            }
            return .done(true)
        }
        if removedTokens == nil { removedTokens = removed }
        return ok
    }

    // MARK: RPN

    private mutating func applyRPN(_ operation: CalculateExpression.Operation) -> Bool {
        let key = operation.key
        func startEntry() {
            if liftNext {
                stack.append(row)
                row = []
            } else if replaceNext {
                row = []
            }
            liftNext = false
            replaceNext = false
        }
        func xValue() -> Double? { try? Evaluator(state: self).value(shownRow) }
        func setX(_ v: Double) {
            row = resultRow(v)
            liftNext = true
            replaceNext = false
        }
        if key.digitText != nil || key == .decimal || key == .ee {
            startEntry()
            return applyKey(operation)
        }
        switch key {
        case .pi, .eulerNumber, .random:
            startEntry()
            row = []
            return applyKey(operation)
        case .enter:
            stack.append(row)
            liftNext = false
            replaceNext = true
            cleared = false
            return true
        case .add, .subtract, .multiply, .divide, .power, .root, .exponentialBaseCustom, .reverseRoot,
             .logarithmBaseCustom:
            guard let y = stack.last.flatMap({ try? Evaluator(state: self).value($0.isEmpty ? [.literal("0")] : $0) }),
                  let x = xValue() else { return false }
            let ev = Evaluator(state: self)
            let v: Double
            do {
                switch key {
                case .add: v = try ev.binary(.add, y, x)
                case .subtract: v = try ev.binary(.subtract, y, x)
                case .multiply: v = try ev.binary(.multiply, y, x)
                case .divide: v = try ev.binary(.divide, y, x)
                case .power: v = try ev.power(x, y)
                case .exponentialBaseCustom: v = try ev.power(y, x)
                case .root, .reverseRoot: v = try ev.root(x, index: y)
                default: v = try ev.log(x, base: y)
                }
            } catch {
                // an error leaves zero
                stack.removeLast()
                row = []
                liftNext = true
                return true
            }
            stack.removeLast()
            setX(v)
            return true
        case .swap:
            guard let y = stack.popLast() else { return false }
            stack.append(row)
            row = y
            liftNext = true
            return true
        case .drop:
            row = stack.popLast() ?? []
            liftNext = true
            return true
        case .rollIn, .rollOut:
            var all = stack + [row]
            if key == .rollIn {
                all.insert(all.removeLast(), at: 0)
            } else {
                all.append(all.removeFirst())
            }
            row = all.removeLast()
            stack = all
            liftNext = true
            return true
        case .clear, .delete:
            removedTokens = shownRow.richTokens(radix)
            if key == .delete, case .literal(let s)? = row.last, row.count == 1, !liftNext, s.count > 1 {
                row = [.literal(String(s.dropLast()))]
                removedTokens = [CalculateExpression.RichToken(type: .literal, text: String(s.last!))]
                return true
            }
            row = []
            liftNext = false
            replaceNext = false
            return true
        case .allClear:
            clearAll()
            return true
        case .negate:
            if row.count == 2, row[0] == .op(.subtract) {
                row.removeFirst()
                return true
            }
            if case .literal? = row.last, row.count == 1 {
                row.insert(.op(.subtract), at: 0)
                return true
            }
            guard let x = xValue() else { return false }
            setX(-x)
            return true
        default:
            // a function of X
            guard let x = xValue() else { return false }
            var scratch = self
            scratch.row = resultRow(x)
            scratch.stack = []
            guard scratch.applyKey(operation), let v = try? Evaluator(state: scratch).value(scratch.row) else {
                return false
            }
            setX(v)
            return true
        }
    }

    /// RPN: the stack's entries, X last.
    var rpnEntries: [Row] {
        isRPN ? stack + [shownRow] : []
    }
}

extension CalculateExpression.Operation.Key {
    static var allKeys: [Self] {
        [.add, .allClear, .and, .byteFlip, .clear, .closeParenthesis, .cosine, .cube, .cubeRoot, .decimal, .delete,
         .digit0, .digit00, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9,
         .digitA, .digitB, .digitC, .digitD, .digitE, .digitF, .digitFF, .divide, .drop, .ee, .enter, .equals,
         .eulerNumber, .exponentialBase10, .exponentialBase2, .exponentialBaseCustom, .exponentialBaseEuler,
         .factorial, .hyperbolicCosine, .hyperbolicSine, .hyperbolicTangent, .inverseCosine,
         .inverseHyperbolicCosine, .inverseHyperbolicSine, .inverseHyperbolicTangent, .inverseSine,
         .inverseTangent, .leftRotate, .leftShift, .leftShiftCustom, .logarithmBase10, .logarithmBase2,
         .logarithmBaseCustom, .logarithmNatural, .mod, .multiply, .neg, .negate, .nor, .not, .openParenthesis,
         .or, .percent, .pi, .power, .random, .reciprocal, .reverseRoot, .rightRotate, .rightShift,
         .rightShiftCustom, .rollIn, .rollOut, .root, .sine, .square, .squareRoot, .subtract, .swap, .tangent,
         .wordFlip, .xor]
    }

    /// The digit a digit key enters (the last of 00 and FF).
    var digitValue: Int? {
        switch self {
        case .digit0, .digit00: 0
        case .digit1: 1
        case .digit2: 2
        case .digit3: 3
        case .digit4: 4
        case .digit5: 5
        case .digit6: 6
        case .digit7: 7
        case .digit8: 8
        case .digit9: 9
        case .digitA: 10
        case .digitB: 11
        case .digitC: 12
        case .digitD: 13
        case .digitE: 14
        case .digitF, .digitFF: 15
        default: nil
        }
    }

    var digitText: String? {
        switch self {
        case .digit00: "00"
        case .digitFF: "FF"
        default: digitValue.map { String($0, radix: 16).uppercased() }
        }
    }
}

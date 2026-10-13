// SPDX-License-Identifier: MIT OR Apache-2.0
//
// What a CalculateExpression holds and how the keys edit it, as Apple's Calculate does:
//
// - Keys edit the row the cursor is in: the innermost one still open (an exponent being
//   typed, a function's argument, an open parenthesis). An operator ends an exponent (it
//   goes after it); ")" closes the innermost group.
// - A function, root, power or percentage applies to the operand before the cursor (9 √ is
//   √9), or opens on its own when there is none (√ 9 + 1 is √(9+1)).
// - "=" changes nothing: Calculator takes the result and starts a new expression from it
//   (init(result:)), and repeats an operation with setRepeatableOperation(from:).
// - With the RPN format, the expression is the stack's X register: enter pushes it, an
//   operator combines it with Y.
// - With the programmer engine, numbers are 64-bit integers typed in the base, written in
//   decimal, and the operators are bitwise.

import Foundation

enum RowKind {
    case top
    /// A group's, function's or root's argument: ")" closes it.
    case paren
    /// An exponent, or a base or index being typed: an operator ends it.
    case tight
}

/// What an action did in the row the cursor is in.
enum Edit {
    case done(Bool)
    /// Leave the row: its container closes and the action goes on outside it.
    case leave
    /// Take out the (empty) row's container.
    case remove
}

struct CalculatorState {
    var options: [CalculateKey: Any]
    var base: CalculateExpression.Base
    var row: Row = []
    /// Text as given (init(_:), `expression`), until a key edits it.
    var sourceText: String?
    /// RPN: the entries under X, bottom first.
    var stack: [Row] = []
    /// RPN: the next number pushes X first (after an operation) or replaces it (after enter).
    var liftNext = false
    var replaceNext = false
    var removedTokens: [CalculateExpression.RichToken]?
    var cleared = true
    /// What a repeated "=" appends (an operator and its operand).
    var repeatable: Row?
    var repeated = false
    var assumeDegrees: Bool
    var format: CalculateFormat = []
    var engine: CalculateEngine = []
    var locales: [Locale] = [Locale.current]
    var numberFormatter: NumberFormatter?
    var allowsArabicMath = false
    var result: CalculateResult?
    var error: Error?

    init(options: [CalculateKey: Any], base: CalculateExpression.Base) {
        self.options = options
        self.base = base
        self.assumeDegrees = (options[.assumeDegrees] as? Bool) ?? false
        if let locales = options[.locales] as? [Locale], !locales.isEmpty {
            self.locales = locales
        }
        self.numberFormatter = options[.numberFormatter] as? NumberFormatter
    }

    var isProgrammer: Bool { engine.rawValue & 1 != 0 }
    /// Programmer mode's base, for its tokens.
    var radix: Int? { isProgrammer ? base.rawValue : nil }
    var isRPN: Bool { format.rawValue & 2 != 0 }

    // MARK: Reading

    var writer: Writer {
        Writer(locales: locales, numberFormatter: numberFormatter, radix: radix)
    }

    /// The row as shown: "0" when empty.
    var shownRow: Row { row.isEmpty ? [.literal("0")] : row }

    var expressionText: String {
        if let sourceText { return sourceText }
        return writer.text(shownRow)
    }

    var debugText: String {
        var w = writer
        w.debug = true
        return w.text(shownRow)
    }

    /// The tokens shown: in RPN, every entry of the stack.
    private var displayRows: [Row] { isRPN ? stack.map { $0.isEmpty ? [.literal("0")] : $0 } + [shownRow] : [shownRow] }

    var plain: CalculateExpression.PlainExpression {
        CalculateExpression.PlainExpression(writer.pieces(shownRow).map { CalculateExpression.Token(type: $0.type, text: $0.text) })
    }

    var rich: CalculateExpression.RichExpression {
        CalculateExpression.RichExpression(displayRows.flatMap { $0.richTokens(radix) },
                                           isZero: displayRows.allSatisfy { $0 == [.literal("0")] })
    }

    var removed: CalculateExpression.RichExpression? {
        removedTokens.map { CalculateExpression.RichExpression($0) }
    }

    var prefersClear: Bool { !cleared && (isRPN || !row.isEmpty) }

    var activeOperation: CalculateExpression.Operation? {
        var current = row
        var kindOperation: CalculateExpression.Operation?
        while let last = current.last {
            switch last {
            case .literal(let s) where s.hasSuffix("e") || s.hasSuffix("e-"):
                return CalculateExpression.Operation.ee
            case .power(let b, let e, true):
                if let b {
                    kindOperation = CalculateExpression.Operation.exponentialBaseCustom
                    current = b
                } else {
                    kindOperation = e.isEmpty ? CalculateExpression.Operation.power : nil
                    current = e
                }
                continue
            case .group(let r, false), .function(_, let r, false):
                kindOperation = nil
                current = r
                continue
            case .root(let i, let r, let closed, let indexOpen):
                if indexOpen, let i {
                    kindOperation = nil
                    current = i
                    continue
                }
                if !closed {
                    kindOperation = nil
                    current = r
                    continue
                }
            case .log(let b, let r, let closed, let baseOpen):
                if baseOpen {
                    kindOperation = nil
                    current = b
                    continue
                }
                if !closed {
                    kindOperation = nil
                    current = r
                    continue
                }
            default:
                break
            }
            break
        }
        return kindOperation
    }

    var allowedOperations: Set<CalculateExpression.Operation> {
        Set(CalculateExpression.Operation.Key.allKeys.filter(isAllowed).map { CalculateExpression.Operation($0) })
    }

    func isAllowed(_ key: CalculateExpression.Operation.Key) -> Bool {
        typealias K = CalculateExpression.Operation.Key
        let programmerOnly: Set<K> = [.mod, .and, .or, .xor, .nor, .not, .neg, .leftShift, .rightShift,
                                      .leftShiftCustom, .rightShiftCustom, .leftRotate, .rightRotate,
                                      .byteFlip, .wordFlip]
        let rpnOnly: Set<K> = [.enter, .swap, .drop, .rollIn, .rollOut]
        let hexDigits: Set<K> = [.digitA, .digitB, .digitC, .digitD, .digitE, .digitF, .digitFF]
        if isProgrammer {
            let scientific: Set<K> = [.decimal, .percent, .negate, .sine, .cosine, .tangent, .inverseSine,
                                      .inverseCosine, .inverseTangent, .hyperbolicSine, .hyperbolicCosine,
                                      .hyperbolicTangent, .inverseHyperbolicSine, .inverseHyperbolicCosine,
                                      .inverseHyperbolicTangent, .squareRoot, .cubeRoot, .root, .reverseRoot,
                                      .square, .cube, .reciprocal, .factorial, .pi, .eulerNumber,
                                      .logarithmNatural, .logarithmBase10, .logarithmBase2, .logarithmBaseCustom,
                                      .power, .exponentialBaseCustom, .exponentialBaseEuler, .exponentialBase10,
                                      .exponentialBase2, .ee, .random]
            if scientific.contains(key) || rpnOnly.contains(key) { return false }
            if let digit = key.digitValue { return digit < base.rawValue && (base == .base16 || !hexDigits.contains(key)) }
            return true
        }
        if key == .digit00 || hexDigits.contains(key) || programmerOnly.contains(key) { return false }
        if isRPN {
            return ![.equals, .openParenthesis, .closeParenthesis].contains(key)
        }
        return !rpnOnly.contains(key) && key != .reverseRoot
    }

    // MARK: Results

    mutating func reevaluate() {
        if let sourceText {
            do {
                if let parsed = try? programmerDigits(Parser.parse(sourceText, programmer: isProgrammer)) {
                    setResult(try Evaluator(state: self).value(parsed), trivial: isTrivialRow(parsed))
                } else {
                    // a unit or a conversion ("3 ft in m")
                    var evaluator = Evaluator(state: self)
                    evaluator.numberFormatter = numberFormatter
                    result = try evaluator.evaluate(sourceText)
                    error = nil
                }
            } catch {
                result = nil
                self.error = error
            }
            return
        }
        do {
            setResult(try Evaluator(state: self).value(shownRow), trivial: isTrivialRow(shownRow))
        } catch {
            result = nil
            self.error = error
        }
    }

    /// A number on its own (or negated): nothing to calculate.
    private func isTrivialRow(_ row: Row) -> Bool {
        if row.count == 2, row[0] == .op(.subtract) { return !isProgrammer && isTrivialRow([row[1]]) }
        guard row.count == 1 else { return false }
        switch row[0] {
        case .literal: return true
        case .group(let inner, _): return isTrivialRow(inner)
        default: return false
        }
    }

    private mutating func setResult(_ value: Double, trivial: Bool) {
        result = makeResult(value, trivial: trivial)
        error = nil
    }

    func makeResult(_ value: Double, trivial: Bool = true) -> CalculateResult {
        let r = CalculateResult(double: value)
        r.numberFormatter = numberFormatter
        r.locales = locales
        r.autoScientificNotation = (options[.autoScientificNotation] as? Bool) ?? true
        r.scientificNotationFormat = (options[.scientificNotationFormat] as? UInt) ?? 1
        r.finchSetExpression(expressionText, base: 10, integer: false)
        r.finchSetTrivial(trivial)
        r.finchSetFlexibleFractionDigits(true)
        return r
    }

    /// A result as a row: its literal, after a minus when negative.
    func resultRow(_ value: Double) -> Row {
        if value < 0 && !isProgrammer { return [.op(.subtract), .literal(literal(for: -value))] }
        return [.literal(literal(for: value))]
    }

    /// A value as a literal, as results are written into expressions ("3E+0", "5E-1").
    func literal(for value: Double) -> String {
        if isProgrammer {
            let t = value.rounded(.towardZero)
            let w = t < 0 ? UInt64(bitPattern: Int64(Swift.max(t, -9.2e18))) : t >= 1.8446744073709552e19 ? UInt64.max : UInt64(t)
            return String(w, radix: base.rawValue).uppercased()
        }
        guard value.isFinite else { return "0E+0" }
        if value == 0 { return "0E+0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) + "E+0" }
        // the shortest digits that read back as the value
        var s = "\(abs(value))"
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(s[s.index(after: e)...]) ?? 0
            s = String(s[..<e])
        }
        var digits = s
        if let dot = s.firstIndex(of: ".") {
            let fraction = s[s.index(after: dot)...]
            digits = String(s[..<dot]) + fraction
            exponent -= fraction.count
        }
        while digits.hasSuffix("0"), digits.count > 1 {
            digits.removeLast()
            exponent += 1
        }
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
        }
        return (value < 0 ? "-" : "") + digits + "E" + (exponent >= 0 ? "+" : "") + String(exponent)
    }

    // MARK: Setting

    mutating func setExpression(_ text: String) {
        sourceText = text
        row = (try? programmerDigits(Parser.parse(text, programmer: isProgrammer))) ?? []
        cleared = false
        reevaluate()
    }

    mutating func setResult(_ value: CalculateResult?, error: Error?) {
        sourceText = nil
        if let value {
            row = resultRow(value.doubleValue)
            cleared = false
        }
        reevaluate()
        if value == nil {
            result = nil
            self.error = error
        }
    }

    var integerValue: UInt64 {
        guard let v = result?.doubleValue, v.isFinite else { return 0 }
        if v < 0 { return UInt64(bitPattern: Int64(max(v, -9.2e18).rounded(.towardZero))) }
        return v >= 1.8446744073709552e19 ? UInt64.max : UInt64(v.rounded(.towardZero))
    }

    var bits: [Bool] {
        let v = integerValue
        return (0 ..< 64).map { (v >> UInt64($0)) & 1 == 1 }
    }

    mutating func setBits(_ bits: [Bool]) {
        var v: UInt64 = 0
        for (i, bit) in bits.prefix(64).enumerated() where bit {
            v |= 1 << UInt64(i)
        }
        sourceText = nil
        row = [.literal(String(v, radix: base.rawValue).uppercased())]
        cleared = false
        reevaluate()
    }

    /// Programmer mode: a parsed row's (decimal) numbers as digits in the base.
    func programmerDigits(_ row: Row) -> Row {
        guard isProgrammer else { return row }
        return row.mapLiterals { s in
            guard let v = UInt64(s) else { return s }
            return String(v, radix: base.rawValue).uppercased()
        }
    }

    mutating func setBase(_ newBase: CalculateExpression.Base) {
        if isProgrammer && newBase != base {
            // the numbers keep their values
            let old = base.rawValue
            row = row.mapLiterals { String(programmerValue($0, radix: old), radix: newBase.rawValue).uppercased() }
            stack = stack.map { $0.mapLiterals { String(programmerValue($0, radix: old), radix: newBase.rawValue).uppercased() } }
        }
        base = newBase
        reevaluate()
    }

    // MARK: Whole-expression operations

    mutating func clearAll() {
        row = []
        stack = []
        sourceText = nil
        removedTokens = nil
        repeatable = nil
        repeated = false
        liftNext = false
        replaceNext = false
        cleared = true
        reevaluate()
    }

    /// The expression becomes its result.
    mutating func inlineEvaluate() {
        reevaluate()
        guard let result else { return }
        sourceText = nil
        row = resultRow(result.doubleValue)
        cleared = true
        reevaluate()
    }

    /// The expression becomes another's result.
    mutating func inlineEvaluate(_ other: CalculatorState) {
        guard let r = other.result else { return }
        sourceText = nil
        row = resultRow(r.doubleValue)
        cleared = true
        reevaluate()
    }

    /// The last operator of the expression and what follows it ("+2" of "1+2").
    func lastOperation() -> Row? {
        guard let i = row.lastIndex(where: { if case .op = $0 { return true }; return false }), i + 1 < row.count else {
            return nil
        }
        return Array(row[i...])
    }

    mutating func repeatOperation() {
        guard let repeatable, !repeated else { return }
        row += repeatable
        sourceText = nil
        repeated = true
        cleared = false
        reevaluate()
    }
}


extension Row {
    /// The row with every number (in every nested row) changed.
    func mapLiterals(_ f: (String) -> String) -> Row {
        map { node in
            switch node {
            case .literal(let s): .literal(f(s))
            case .power(let base, let exponent, let open):
                .power(base: base?.mapLiterals(f), exponent: exponent.mapLiterals(f), open: open)
            case .group(let r, let closed): .group(r.mapLiterals(f), closed: closed)
            case .function(let fn, let r, let closed): .function(fn, r.mapLiterals(f), closed: closed)
            case .root(let index, let r, let closed, let indexOpen):
                .root(index: index?.mapLiterals(f), r.mapLiterals(f), closed: closed, indexOpen: indexOpen)
            case .log(let base, let r, let closed, let baseOpen):
                .log(base: base.mapLiterals(f), r.mapLiterals(f), closed: closed, baseOpen: baseOpen)
            default: node
            }
        }
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Evaluating a row: operators by precedence (products before sums, then the programmer
// mode's shifts and bitwise operators), adjacent operands multiplied (2π), a percentage of
// the sum it's added to ("50+10%" is 55, "50×10%" is 5). In programmer mode values are
// unsigned 64-bit integers. Errors are Calculate's: a math error (an incomplete expression),
// undefined, indeterminate (0÷0), overflow.
//
// Text (init(_:), `expression`, evaluate(_:options:)) becomes a row through the parser, which
// reads what the expressions write and the usual spellings, and a unit conversion
// ("3 ft in m").

import Foundation

enum CalculateErrorCode: Int {
    case math = -1000
    case overflow = -2000
    case undefined = -2003
    case divisionByZero = -2004
    case indeterminate = -2008

    var error: NSError {
        var info: [String: Any] = [:]
        switch self {
        case .math:
            info[NSLocalizedDescriptionKey] = "Math error"
            info[NSLocalizedFailureReasonErrorKey] = "Check the expression for math errors and spelling mistakes"
        case .overflow: info[NSLocalizedDescriptionKey] = "Overflow"
        case .undefined, .divisionByZero: info[NSLocalizedDescriptionKey] = "Undefined"
        case .indeterminate: info[NSLocalizedDescriptionKey] = "Indeterminate"
        }
        return NSError(domain: CalculateErrorDomain, code: rawValue, userInfo: info)
    }
}

struct Evaluator {
    var degrees = false
    var integer = false
    var radix = 10
    var numberFormatter: NumberFormatter?

    init(state: CalculatorState) {
        degrees = state.assumeDegrees
        integer = state.isProgrammer
        radix = state.base.rawValue
    }

    init(options: [CalculateKey: Any]) {
        degrees = (options[.assumeDegrees] as? Bool) ?? false
        numberFormatter = options[.numberFormatter] as? NumberFormatter
    }

    func value(_ row: Row) throws -> Double {
        var index = 0
        let v = try expression(row, &index, minPrecedence: 0).value
        guard index == row.count else { throw CalculateErrorCode.math.error }
        return try checked(v)
    }

    func checked(_ v: Double) throws -> Double {
        if v.isNaN { throw CalculateErrorCode.undefined.error }
        if v.isInfinite { throw CalculateErrorCode.overflow.error }
        // what a decimal calculator would show: 0.1+0.2 is 0.3
        if v != 0 && !integer {
            let rounded = Double(String(format: "%.15g", v)) ?? v
            return rounded
        }
        return v
    }

    // MARK: Rows

    private func expression(_ row: Row, _ i: inout Int, minPrecedence: Int) throws -> (value: Double, percent: Bool) {
        var lhs = try product(row, &i)
        while i < row.count, case .op(let op) = row[i], op.precedence >= minPrecedence {
            i += 1
            let rhs = try expression(row, &i, minPrecedence: op.precedence + 1)
            // "a + b%" adds b percent of a
            let b = rhs.percent && (op == .add || op == .subtract) ? lhs.value * rhs.value : rhs.value
            lhs = (try binary(op, lhs.value, b), false)
        }
        return lhs
    }

    /// Adjacent operands (2π, 2(3)) multiplied; a leading minus negates.
    private func product(_ row: Row, _ i: inout Int) throws -> (value: Double, percent: Bool) {
        guard i < row.count else { throw CalculateErrorCode.math.error }
        if case .op(.subtract) = row[i] {
            i += 1
            if i < row.count, case .op = row[i] { throw CalculateErrorCode.math.error }
            let v = try product(row, &i)
            return (integer ? signed(0 &- word(v.value)) : -v.value, v.percent)
        }
        var result = try operand(row, &i)
        while i < row.count, row[i].isAtom {
            // a percentage followed by a number: the remainder ("5%2" is 1)
            let modulo = i > 0 && row[i - 1] == .postfix(.percent)
            let next = try operand(row, &i)
            if modulo {
                let a = result.value * 100
                if next.value == 0 { throw CalculateErrorCode.divisionByZero.error }
                result = (fmod(a, next.value), next.percent)
            } else {
                result = (try binary(.multiply, result.value, next.value), next.percent)
            }
        }
        return result
    }

    private func operand(_ row: Row, _ i: inout Int) throws -> (value: Double, percent: Bool) {
        guard i < row.count, row[i].isAtom else { throw CalculateErrorCode.math.error }
        var v = try atom(row[i])
        i += 1
        var percent = false
        while i < row.count, row[i].isDecoration {
            switch row[i] {
            case .power(nil, let exponent, _):
                v = try power(v, try value(exponent))
            case .postfix(.percent):
                v = v / 100
                percent = true
            case .postfix(.factorial):
                v = try factorial(v)
            default:
                break
            }
            i += 1
        }
        return (v, percent)
    }

    private func atom(_ node: Node) throws -> Double {
        switch node {
        case .literal(let s): return try number(s)
        case .constant(let c): return c.value
        case .group(let inner, _): return try value(inner)
        case .power(let base?, let exponent, _): return try power(try value(base), try value(exponent))
        case .function(let f, let inner, _): return try apply(f, try value(inner))
        case .root(let index, let inner, _, _): return try root(try value(inner), index: try index.map(value) ?? 2)
        case .log(let base, let inner, _, _): return try log(try value(inner), base: try value(base))
        default: throw CalculateErrorCode.math.error
        }
    }

    func number(_ s: String) throws -> Double {
        if integer { return Double(programmerValue(s, radix: radix)) }
        var t = s
        if t.hasSuffix(".") { t.removeLast() }
        if t.hasSuffix("e") || t.hasSuffix("e-") { t = String(t[..<t.firstIndex(of: "e")!]) }
        guard let v = Double(t) else { throw CalculateErrorCode.math.error }
        return v
    }

    // MARK: Operations

    func word(_ v: Double) -> UInt64 {
        guard v.isFinite else { return 0 }
        if v < 0 { return UInt64(bitPattern: Int64(max(v, -9.2e18).rounded(.towardZero))) }
        return v >= 1.8446744073709552e19 ? UInt64.max : UInt64(v.rounded(.towardZero))
    }

    func signed(_ w: UInt64) -> Double { Double(w) }

    func binary(_ op: Binary, _ a: Double, _ b: Double) throws -> Double {
        switch op {
        case .add: return integer ? signed(word(a) &+ word(b)) : a + b
        case .subtract: return integer ? signed(word(a) &- word(b)) : a - b
        case .multiply: return integer ? signed(word(a) &* word(b)) : a * b
        case .divide:
            if b == 0 { throw (a == 0 ? CalculateErrorCode.indeterminate : .divisionByZero).error }
            return integer ? signed(word(a) / word(b)) : a / b
        case .mod:
            // a remainder by zero leaves the number
            if word(b) == 0 { return a }
            return signed(word(a) % word(b))
        case .and: return signed(word(a) & word(b))
        case .or: return signed(word(a) | word(b))
        case .xor: return signed(word(a) ^ word(b))
        case .nor: return signed(~(word(a) | word(b)))
        case .leftShift: return signed(word(b) >= 64 ? 0 : word(a) << word(b))
        case .rightShift: return signed(word(b) >= 64 ? 0 : word(a) >> word(b))
        case .leftRotate:
            let n = word(b) % 64
            return signed(n == 0 ? word(a) : (word(a) << n) | (word(a) >> (64 - n)))
        case .rightRotate:
            let n = word(b) % 64
            return signed(n == 0 ? word(a) : (word(a) >> n) | (word(a) << (64 - n)))
        }
    }

    func power(_ a: Double, _ b: Double) throws -> Double {
        if a == 0 && b == 0 { throw CalculateErrorCode.undefined.error }
        if a == 0 && b < 0 { throw CalculateErrorCode.divisionByZero.error }
        let r = pow(a, b)
        if r.isNaN { throw CalculateErrorCode.undefined.error }
        if r.isInfinite { throw CalculateErrorCode.overflow.error }
        return r
    }

    func root(_ a: Double, index n: Double) throws -> Double {
        if n == 0 { throw CalculateErrorCode.undefined.error }
        if a < 0 {
            // odd roots of negative numbers are real
            if n == n.rounded(), Int(n) % 2 != 0 { return -pow(-a, 1 / n) }
            throw CalculateErrorCode.undefined.error
        }
        return n == 2 ? sqrt(a) : n == 3 ? cbrt(a) : pow(a, 1 / n)
    }

    func log(_ a: Double, base: Double) throws -> Double {
        if a == 0 { throw CalculateErrorCode.divisionByZero.error }
        if a < 0 || base <= 0 || base == 1 { throw CalculateErrorCode.undefined.error }
        if base == 10 { return log10(a) }
        if base == 2 { return log2(a) }
        return Foundation.log(a) / Foundation.log(base)
    }

    func factorial(_ x: Double) throws -> Double {
        guard x >= 0 else { throw CalculateErrorCode.undefined.error }
        if x > 100 { throw CalculateErrorCode.overflow.error }
        if x == x.rounded() {
            var r = 1.0
            var i = 2.0
            while i <= x {
                r *= i
                i += 1
            }
            return r
        }
        return tgamma(x + 1)
    }

    func apply(_ f: Function, _ x: Double) throws -> Double {
        let toRadians = degrees ? Double.pi / 180 : 1
        let fromRadians = degrees ? 180 / Double.pi : 1
        func exact(_ v: Double) -> Double { abs(v) < 1e-15 ? 0 : v }
        let r: Double
        switch f {
        case .sin: r = exact(Foundation.sin(x * toRadians))
        case .cos: r = exact(Foundation.cos(x * toRadians))
        case .tan:
            if degrees, x.truncatingRemainder(dividingBy: 180).magnitude == 90 { throw CalculateErrorCode.undefined.error }
            r = exact(Foundation.tan(x * toRadians))
        case .asin: r = Foundation.asin(x) * fromRadians
        case .acos: r = Foundation.acos(x) * fromRadians
        case .atan: r = Foundation.atan(x) * fromRadians
        case .sinh: r = Foundation.sinh(x)
        case .cosh: r = Foundation.cosh(x)
        case .tanh: r = Foundation.tanh(x)
        case .asinh: r = Foundation.asinh(x)
        case .acosh: r = Foundation.acosh(x)
        case .atanh: r = Foundation.atanh(x)
        case .ln:
            if x == 0 { throw CalculateErrorCode.divisionByZero.error }
            r = Foundation.log(x)
        case .not: r = signed(~word(x))
        case .neg: r = signed(0 &- word(x))
        case .byteFlip, .wordFlip:
            // the bytes (16-bit words) in reverse, over as many as the number has
            let w = word(x), size: UInt64 = f == .byteFlip ? 8 : 16, mask: UInt64 = f == .byteFlip ? 0xFF : 0xFFFF
            var parts: [UInt64] = []
            var rest = w
            repeat {
                parts.append(rest & mask)
                rest = size == 64 ? 0 : rest >> size
            } while rest != 0
            var out: UInt64 = 0
            for part in parts {
                out = (out << size) | part
            }
            r = signed(out)
        }
        if r.isNaN { throw CalculateErrorCode.undefined.error }
        if r.isInfinite { throw CalculateErrorCode.overflow.error }
        return r
    }

    // MARK: Text

    /// A text expression's result, with a unit conversion when it asks for one.
    func evaluate(_ text: String) throws -> CalculateResult {
        var expression = text.trimmingCharacters(in: .whitespaces)
        if expression.hasSuffix("=") { expression.removeLast() }
        if let converted = try convert(expression) { return converted }
        let row = try Parser.parse(expression, programmer: false)
        guard !row.isEmpty else { throw CalculateErrorCode.math.error }
        let v = try value(row)
        let r = CalculateResult(double: v)
        r.numberFormatter = numberFormatter
        r.autoScientificNotation = true
        r.scientificNotationFormat = 1
        r.finchSetExpression(text, base: 10, integer: false)
        r.finchSetTrivial(row.count == 1 || (row.count == 2 && row[0] == .op(.subtract)))
        r.finchSetFlexibleFractionDigits(true)
        return r
    }

    /// "3 ft in m", "100 km to mi": the value in the second unit.
    private func convert(_ text: String) throws -> CalculateResult? {
        let lower = text.lowercased()
        var split: Range<String.Index>?
        for word in [" in ", " to ", " as "] {
            if let r = lower.range(of: word, options: .backwards) { split = r; break }
        }
        let left = (split.map { String(text[..<$0.lowerBound]) } ?? text).trimmingCharacters(in: .whitespaces)
        let right = split.map { text[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
        let collection = CalculateUnitCollection(locales: nil)
        func unit(_ name: String) -> CalculateUnit? {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            let aliases = ["feet": "foot", "ft": "foot", "inches": "inch", "in": "inch", "metres": "meter", "metre": "meter",
                           "meters": "meter", "m": "meter", "km": "kilometer", "mi": "mile", "miles": "mile",
                           "kg": "kilogram", "lb": "pound", "lbs": "pound", "g": "gram", "c": "celsius", "f": "fahrenheit",
                           "°c": "celsius", "°f": "fahrenheit", "l": "liter", "ml": "milliliter", "gal": "gallon"]
            let key = aliases[n.lowercased()] ?? n
            if let u = collection.findUnit(withName: key) { return u }
            if key.hasSuffix("s"), let u = collection.findUnit(withName: String(key.dropLast())) { return u }
            return nil
        }
        // the value's unit: the words after its number
        guard let unitStart = left.lastIndex(where: { $0.isNumber || $0 == ")" || $0 == "." }) else { return nil }
        let valueText = String(left[...unitStart])
        let fromText = String(left[left.index(after: unitStart)...]).trimmingCharacters(in: .whitespaces)
        guard let from = unit(fromText) else { return nil }
        let targetText = right ?? fromText
        guard let to = unit(targetText) else { return nil }
        let v = try value(try Parser.parse(valueText, programmer: false))
        let source = CalculateResult(double: v)
        source.numberFormatter = numberFormatter
        source.finchSetExpression(text, base: 10, integer: false)
        guard let converted = source.converted(to: to, from: from) else { return nil }
        // the unit as typed (a temperature's as its symbol)
        if to.unitType != 12 { converted.finchSetUnitText(targetText) }
        converted.finchSetFlexibleFractionDigits(true)
        converted.finchSetTrivial(right == nil)
        return converted
    }
}

/// Text to a row.
struct Parser {
    let chars: [Character]
    let programmer: Bool
    var i = 0

    init(_ text: String, programmer: Bool) {
        chars = Array(text)
        self.programmer = programmer
    }

    private func rest(_ s: String) -> Bool {
        let n = Array(s)
        guard i + n.count <= chars.count else { return false }
        return String(chars[i ..< i + n.count]).lowercased() == s.lowercased()
    }

    static func parse(_ text: String, programmer: Bool) throws -> Row {
        var parser = Parser(text, programmer: programmer)
        return try parser.row()
    }

    mutating func row() throws -> Row {
        let r = try parseRow(closing: false)
        guard i == chars.count else { throw CalculateErrorCode.math.error }
        return r
    }

    private static let functions: [(String, Function)] = [
        ("sinh^-1", .asinh), ("cosh^-1", .acosh), ("tanh^-1", .atanh), ("sin^-1", .asin), ("cos^-1", .acos),
        ("tan^-1", .atan), ("sinh⁻¹", .asinh), ("cosh⁻¹", .acosh), ("tanh⁻¹", .atanh), ("sin⁻¹", .asin),
        ("cos⁻¹", .acos), ("tan⁻¹", .atan), ("asinh", .asinh), ("acosh", .acosh), ("atanh", .atanh),
        ("asin", .asin), ("acos", .acos), ("atan", .atan), ("sinh", .sinh), ("cosh", .cosh), ("tanh", .tanh),
        ("sin", .sin), ("cos", .cos), ("tan", .tan), ("ln", .ln), ("flip8", .byteFlip), ("flip16", .wordFlip),
    ]

    private mutating func parseRow(closing: Bool) throws -> Row {
        var row: Row = []
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c == ")" {
                if closing { return row }
                throw CalculateErrorCode.math.error
            }
            if let op = binaryOperator() {
                row.append(.op(op))
                continue
            }
            switch c {
            case "%": row.append(.postfix(.percent)); i += 1; continue
            case "!": row.append(.postfix(.factorial)); i += 1; continue
            case "²", "³":
                row.append(.power(base: nil, exponent: [.literal(c == "²" ? "2" : "3")], open: false))
                i += 1
                continue
            case "^":
                i += 1
                row.append(.power(base: nil, exponent: try exponent(), open: false))
                continue
            default:
                break
            }
            row.append(try atom())
        }
        return row
    }

    private mutating func binaryOperator() -> Binary? {
        let words: [(String, Binary)] = [(" AND ", .and), (" OR ", .or), (" XOR ", .xor), (" NOR ", .nor),
                                         (" RoL ", .leftRotate), (" RoR ", .rightRotate), (" mod ", .mod),
                                         ("<<", .leftShift), (">>", .rightShift)]
        for (w, op) in words where rest(w) {
            i += w.count
            return op
        }
        let c = chars[i]
        let op: Binary? = switch c {
        case "+": .add
        case "-", "−", "–": .subtract
        case "*", "×", "·": .multiply
        case "/", "÷": .divide
        default: nil
        }
        if op != nil { i += 1 }
        return op
    }

    /// An exponent: a signed operand (and its own exponent).
    private mutating func exponent() throws -> Row {
        var r: Row = []
        while i < chars.count, chars[i] == " " { i += 1 }
        if i < chars.count, chars[i] == "-" || chars[i] == "−" {
            r.append(.op(.subtract))
            i += 1
        }
        r.append(try atom())
        if i < chars.count, chars[i] == "^" {
            i += 1
            r.append(.power(base: nil, exponent: try exponent(), open: false))
        }
        return r
    }

    private mutating func group() throws -> Row {
        let r = try parseRow(closing: true)
        if i < chars.count, chars[i] == ")" { i += 1 }
        return r
    }

    private mutating func atom() throws -> Node {
        guard i < chars.count else { throw CalculateErrorCode.math.error }
        let c = chars[i]
        if c.isNumber || c == "." {
            var s = ""
            while i < chars.count {
                let d = chars[i]
                if d.isNumber || d == "." {
                    s.append(d)
                } else if d == ",", i + 1 < chars.count, chars[i + 1].isNumber {
                    // a group separator
                } else if (d == "e" || d == "E"), i + 1 < chars.count,
                          chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
                    s.append(d)
                    if chars[i + 1] == "-" || chars[i + 1] == "+" {
                        s.append(chars[i + 1])
                        i += 1
                    }
                } else {
                    break
                }
                i += 1
            }
            return .literal(s)
        }
        if c == "(" {
            i += 1
            return .group(try group(), closed: true)
        }
        if c == "π" || rest("pi") {
            i += c == "π" ? 1 : 2
            return .constant(.pi)
        }
        if c == "√" || c == "∛" || c == "∜" || rest("sqrt") || rest("cbrt") {
            let index: Row? = c == "∛" || rest("cbrt") ? [.literal("3")] : c == "∜" ? [.literal("4")] : nil
            i += c == "√" || c == "∛" || c == "∜" ? 1 : 4
            if i < chars.count, chars[i] == "(" {
                i += 1
                return .root(index: index, try group(), closed: true, indexOpen: false)
            }
            return .root(index: index, [try atom()], closed: true, indexOpen: false)
        }
        if rest("log") {
            i += 3
            var base: Row = [.literal("10")]
            if rest("₂") || rest("2(") { base = [.literal("2")]; i += 1 }
            else if rest("₁₀") || rest("10(") { i += 2 }
            guard i < chars.count, chars[i] == "(" else { throw CalculateErrorCode.math.error }
            i += 1
            return .log(base: base, try group(), closed: true, baseOpen: false)
        }
        if rest("NOT ") || rest("NEG ") {
            let f: Function = rest("NOT ") ? .not : .neg
            i += 4
            return .function(f, [try atom()], closed: true)
        }
        for (name, f) in Self.functions where rest(name) {
            i += name.count
            guard i < chars.count, chars[i] == "(" else { throw CalculateErrorCode.math.error }
            i += 1
            return .function(f, try group(), closed: true)
        }
        if c == "𝑒" || c == "e" {
            i += 1
            return .constant(.e)
        }
        throw CalculateErrorCode.math.error
    }
}

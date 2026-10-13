// SPDX-License-Identifier: MIT OR Apache-2.0
//
// An expression as Calculate holds it: a row of nodes, some of which hold rows of their own
// (an exponent, a function's argument, a root's index and radicand, a parenthesized group).
// The keys edit the row the cursor is in, the innermost one still open. Parentheses close
// implicitly: an open group shows its ")" all the same.
//
// The row reads three ways: as the expression's text ("1+2×(3−1)", numbers grouped), as
// rich tokens (an exponent's row as the token's right side, a root's index as its left, for
// typeset display), and as a value (Evaluate.swift).

import Foundation

typealias Row = [Node]

indirect enum Node: Equatable {
    /// A number as typed ("1000.", "1e-3"), or a result's ("3E+0"). In programmer mode, the
    /// digits typed in the base.
    case literal(String)
    case op(Binary)
    case postfix(Postfix)
    /// An exponent on the operand before it, or (x^y's key) with a base of its own; `open`
    /// while the cursor is in it (the base, when it has one).
    case power(base: Row?, exponent: Row, open: Bool)
    /// ( … ); a negation ((-x)) is a group starting with a minus.
    case group(Row, closed: Bool)
    case function(Function, Row, closed: Bool)
    /// √( … ), with an index (∛) when it has one; `indexOpen` while the index is typed.
    case root(index: Row?, Row, closed: Bool, indexOpen: Bool)
    /// log( … ) in a base; `baseOpen` while the base is typed.
    case log(base: Row, Row, closed: Bool, baseOpen: Bool)
    case constant(Constant)

    var isOperand: Bool {
        switch self {
        case .op: false
        default: true
        }
    }

    /// An operand's own start (not a power or postfix on the operand before it).
    var isAtom: Bool {
        switch self {
        case .op, .postfix: false
        case .power(let base, _, _): base != nil
        default: true
        }
    }

    var isDecoration: Bool {
        switch self {
        case .postfix: true
        case .power(let base, _, _): base == nil
        default: false
        }
    }
}

enum Binary: Equatable {
    case add, subtract, multiply, divide, mod
    case and, or, xor, nor, leftShift, rightShift, leftRotate, rightRotate

    var precedence: Int {
        switch self {
        case .or, .nor: 1
        case .xor: 2
        case .and: 3
        case .leftShift, .rightShift, .leftRotate, .rightRotate: 4
        case .add, .subtract: 5
        case .multiply, .divide, .mod: 6
        }
    }

    var text: String {
        switch self {
        case .add: "+"
        case .subtract: "-"
        case .multiply: "×"
        case .divide: "÷"
        case .mod: " mod "
        case .and: " AND "
        case .or: " OR "
        case .xor: " XOR "
        case .nor: " NOR "
        case .leftShift: "<<"
        case .rightShift: ">>"
        case .leftRotate: " RoL "
        case .rightRotate: " RoR "
        }
    }

    var tokenType: CalculateExpression.TokenType {
        switch self {
        case .add: .add
        case .subtract: .subtract
        case .multiply: .multiply
        case .divide: .divide
        case .mod: .symbol
        case .and: .and
        case .or: .or
        case .xor: .xor
        case .nor: .nor
        case .leftShift: .leftShift
        case .rightShift: .rightShift
        case .leftRotate: .leftRotate
        case .rightRotate: .rightRotate
        }
    }
}

enum Function: Hashable {
    case sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh, ln
    case not, neg, byteFlip, wordFlip

    /// The rich token's text.
    var name: String {
        switch self {
        case .sin: "sin"
        case .cos: "cos"
        case .tan: "tan"
        case .asin: "asin"
        case .acos: "acos"
        case .atan: "atan"
        case .sinh: "sinh"
        case .cosh: "cosh"
        case .tanh: "tanh"
        case .asinh: "asinh"
        case .acosh: "acosh"
        case .atanh: "atanh"
        case .ln: "ln"
        case .not: "NOT"
        case .neg: "NEG"
        case .byteFlip: "flip8"
        case .wordFlip: "flip16"
        }
    }

    /// As the expression's text writes it.
    var written: String {
        switch self {
        case .asin: "sin^-1"
        case .acos: "cos^-1"
        case .atan: "tan^-1"
        case .asinh: "sinh^-1"
        case .acosh: "cosh^-1"
        case .atanh: "tanh^-1"
        default: name
        }
    }

    /// NOT and NEG precede their operand without parentheses.
    var isPrefix: Bool { self == .not || self == .neg }

    var tokenType: CalculateExpression.TokenType {
        switch self {
        case .not: .not
        case .neg: .neg
        default: .function
        }
    }
}

enum Postfix: Equatable {
    case percent, factorial

    var text: String { self == .percent ? "%" : "!" }
}

enum Constant: Equatable {
    case pi, e

    var value: Double { self == .pi ? Double.pi : M_E }
}

// MARK: - Text

/// Programmer mode's digits as a number: the largest when they don't fit.
func programmerValue(_ digits: String, radix: Int) -> UInt64 {
    var value: UInt64 = 0
    for c in digits {
        guard let d = c.hexDigitValue, d < radix else { continue }
        let (product, o1) = value.multipliedReportingOverflow(by: UInt64(radix))
        let (sum, o2) = product.addingReportingOverflow(UInt64(d))
        if o1 || o2 { return UInt64.max }
        value = sum
    }
    return value
}

struct Writer {
    var grouping = ","
    var decimal = "."
    /// Programmer mode's base: numbers are typed in it and written in decimal.
    var radix: Int?
    /// debugDescription's form: numbers as <number>.
    var debug = false

    init(locales: [Locale], numberFormatter: NumberFormatter?, radix: Int? = nil) {
        let locale = numberFormatter?.locale ?? locales.first ?? Locale.current
        grouping = numberFormatter?.groupingSeparator ?? locale.groupingSeparator ?? ","
        decimal = numberFormatter?.decimalSeparator ?? locale.decimalSeparator ?? "."
        self.radix = radix
    }

    typealias Piece = (type: CalculateExpression.TokenType, text: String)

    func text(_ row: Row) -> String {
        pieces(row).map(\.text).joined()
    }

    /// The row as the text's pieces, each with its token type: the plain tokens.
    func pieces(_ row: Row) -> [Piece] {
        row.flatMap(pieces)
    }

    func pieces(_ node: Node) -> [Piece] {
        let open: Piece = (.openParenthesis, "("), close: Piece = (.closeParenthesis, ")")
        switch node {
        case .literal(let s):
            return [(.literal, debug ? (s.contains("E") && radix == nil ? "<number…>" : "<number>") : number(s))]
        case .op(let b):
            let word = b.text.trimmingCharacters(in: .whitespaces)
            let type: CalculateExpression.TokenType = b == .mod ? .percent : b.tokenType
            if word != b.text { return [(.whitespace, " "), (type, word), (.whitespace, " ")] }
            return [(type, word)]
        case .postfix(let p):
            return [(p == .percent ? .percent : .factorial, p.text)]
        case .power(let base, let exponent, _):
            let e = exponent.isEmpty ? [(CalculateExpression.TokenType.placeholder, "")] : operand(exponent)
            return (base.map(operand) ?? []) + [(.exponentiate, "^")] + e
        case .group(let inner, _):
            return [open] + pieces(inner) + [close]
        case .function(let f, let inner, _):
            if f.isPrefix {
                return [(f.tokenType, f.written)] + (inner.isEmpty ? [] : [(.whitespace, " ")] + pieces(inner))
            }
            if f == .byteFlip || f == .wordFlip {
                return [(.function, "flip"), (.literal, debug ? "<number>" : f == .byteFlip ? "8" : "16"), open] + pieces(inner) + [close]
            }
            return [(.function, f.written), open] + pieces(inner) + [close]
        case .root(let index, let inner, _, _):
            var sign: [Piece] = [(.function, "√")]
            if let index {
                switch index {
                case [.literal("3")]: sign = [(.function, "∛")]
                case [.literal("4")]: sign = [(.function, "∜")]
                case [.literal("2")]: break
                default: sign = [(.function, superscript(text(index)) + "√")]
                }
            }
            return sign + operand(inner)
        case .log(let base, let inner, _, _):
            let b = base == [.literal("10")] ? [] : pieces(base)
            return [(.function, "log")] + b + [open] + pieces(inner) + [close]
        case .constant(let c):
            return [(c == .pi ? .pi : .eulerNumber, debug ? "<number>" : c == .pi ? "π" : "𝑒")]
        }
    }

    func text(_ node: Node) -> String {
        pieces(node).map(\.text).joined()
    }

    /// A row as an operand: as is when it's one atom, otherwise in parentheses.
    func operand(_ row: Row) -> [Piece] {
        if row.isEmpty { return [] }
        if row.count == 1 || (row.count == 2 && row[1].isDecoration) { return pieces(row) }
        if row.count == 2 && row[0] == .op(.subtract) && row[1].isAtom { return pieces(row) }
        return [(.openParenthesis, "(")] + pieces(row) + [(.closeParenthesis, ")")]
    }

    func operandText(_ row: Row) -> String {
        operand(row).map(\.text).joined()
    }

    /// A typed number as shown: its integer digits grouped.
    func number(_ s: String) -> String {
        if let radix {
            let value = String(programmerValue(s, radix: radix))
            return radix == 10 ? Writer(grouping: grouping).number(value) : value
        }
        // an exponent still to be typed isn't shown
        if s.hasSuffix("e") { return number(String(s.dropLast())) }
        if s.hasSuffix("e-") { return number(String(s.dropLast(2))) }
        // results' literals ("3E+0") and exponents ("1e3") as they are
        if s.contains("E") { return s }
        var mantissa = s, exponent = ""
        if let e = s.firstIndex(of: "e") {
            mantissa = String(s[..<e])
            exponent = String(s[e...])
        }
        var integer = mantissa, fraction = ""
        if let dot = mantissa.firstIndex(of: ".") {
            integer = String(mantissa[..<dot])
            fraction = String(mantissa[mantissa.index(after: dot)...])
        }
        let sign = integer.hasPrefix("-") ? "-" : ""
        if !sign.isEmpty { integer.removeFirst() }
        var grouped = ""
        for (i, c) in integer.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped += String(grouping.reversed()) }
            grouped.append(c)
        }
        let groupedInteger = String(grouped.reversed())
        return sign + groupedInteger + (fraction.isEmpty ? "" : decimal + fraction) + exponent
    }

    private init(grouping: String) {
        self.grouping = grouping
    }

    func superscript(_ s: String) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
                                           "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻", "+": "⁺", ".": "·"]
        return String(s.map { map[$0] ?? $0 })
    }
}

// MARK: - Rich tokens

extension Row {
    /// The rich tokens; in programmer mode (a radix), numbers in the base with it as a subscript.
    func richTokens(_ radix: Int? = nil) -> [CalculateExpression.RichToken] {
        typealias T = CalculateExpression.RichToken
        func sub(_ row: Row) -> CalculateExpression.RichExpression {
            CalculateExpression.RichExpression(row.isEmpty ? [T(type: .placeholder, text: "")] : row.richTokens(radix))
        }
        var out: [T] = []
        for node in self {
            switch node {
            case .literal(let s):
                if let radix {
                    let digits = s.uppercased()
                    let subscriptBase = radix == 10 ? nil : CalculateExpression.RichExpression([T(type: .literal, text: String(radix))])
                    out.append(T(type: .literal, text: digits, right: subscriptBase))
                } else {
                    out.append(T(type: .literal, text: s))
                }
            case .op(.mod): out.append(T(type: .percent, text: "%"))
            case .op(let b): out.append(T(type: b.tokenType, text: b.text.trimmingCharacters(in: .whitespaces)))
            case .postfix(let p): out.append(T(type: p == .percent ? .percent : .factorial, text: p.text))
            case .power(let base, let exponent, _):
                out.append(T(type: .exponentiate, text: "", left: base.map(sub), right: sub(exponent)))
            case .group(let inner, _):
                out.append(T(type: .openParenthesis, text: "("))
                out += inner.richTokens(radix)
                out.append(T(type: .closeParenthesis, text: ")"))
            case .function(let f, let inner, _):
                if f == .byteFlip || f == .wordFlip {
                    let width = CalculateExpression.RichExpression([T(type: .literal, text: f == .byteFlip ? "8" : "16")])
                    out.append(T(type: .function, text: "flip", right: width))
                } else {
                    out.append(T(type: f.tokenType, text: f.name))
                }
                if f.isPrefix {
                    out += inner.richTokens(radix)
                } else {
                    out.append(T(type: .openParenthesis, text: "("))
                    out += inner.richTokens(radix)
                    out.append(T(type: .closeParenthesis, text: ")"))
                }
            case .root(let index, let inner, _, _):
                out.append(T(type: .function, text: "√", left: index.map(sub), isRoot: true))
                out.append(T(type: .openParenthesis, text: "("))
                out += inner.richTokens(radix)
                out.append(T(type: .closeParenthesis, text: ")"))
            case .log(let base, let inner, _, _):
                out.append(T(type: .function, text: "log", right: sub(base), isLog: true))
                out.append(T(type: .openParenthesis, text: "("))
                out += inner.richTokens(radix)
                out.append(T(type: .closeParenthesis, text: ")"))
            case .constant(let c):
                out.append(T(type: c == .pi ? .pi : .eulerNumber, text: c == .pi ? "π" : "e"))
            }
        }
        return out
    }

}

// MARK: - Accessibility

extension Row {
    /// The expression as an accessibility math equation (AXM… dictionaries).
    var accessibilityMath: [AnyHashable: Any] {
        let children = accessibilityChildren
        if children.count == 1 { return children[0] }
        return ["AXMType": "Row", "AXMChildren": children, "AXMIsNumberOverride": true]
    }

    var accessibilityChildren: [[AnyHashable: Any]] {
        var out: [[AnyHashable: Any]] = []
        let writer = Writer(locales: [Locale.current], numberFormatter: nil)
        func fenced(_ row: Row) -> [AnyHashable: Any] {
            ["AXMType": "Fenced", "AXMOpenOperator": "(", "AXMCloseOperator": ")",
             "AXMChildren": row.accessibilityChildren, "AXMIsNumberOverride": true]
        }
        for node in self {
            switch node {
            case .literal(let s):
                out.append(["AXMType": "Number", "AXMContent": writer.number(s)])
            case .op(let b):
                let t = b.text.trimmingCharacters(in: .whitespaces)
                out.append(["AXMType": "Operator", "AXMContent": t, "AXMIsNumberOverride": true,
                            "AXMUnichar": Int(t.unicodeScalars.first?.value ?? 0)])
            case .postfix(let p):
                out.append(["AXMType": "Operator", "AXMContent": p.text, "AXMIsNumberOverride": true,
                            "AXMUnichar": Int(p.text.unicodeScalars.first!.value)])
            case .power(let base, let exponent, _):
                let b: [AnyHashable: Any] = base.map { $0.accessibilityMath } ?? (out.popLast() ?? [:])
                out.append(["AXMType": "SubSuperScript", "AXMBaseObject": b,
                            "AXMSuperscriptObject": exponent.accessibilityMath, "AXMIsNumberOverride": true])
            case .group(let inner, _):
                out.append(fenced(inner))
            case .function(let f, let inner, _):
                out.append(["AXMType": "Identifier", "AXMContent": f.name, "AXMIsNumberOverride": true])
                out.append(f.isPrefix ? inner.accessibilityMath : fenced(inner))
            case .root(let index, let inner, _, _):
                if let index {
                    out.append(["AXMType": "RootOperation", "AXMRootIndexObject": index.accessibilityMath,
                                "AXMRadicandObject": fenced(inner), "AXMIsNumberOverride": true])
                } else {
                    out.append(["AXMType": "Identifier", "AXMContent": "√", "AXMIsNumberOverride": true])
                    out.append(fenced(inner))
                }
            case .log(let base, let inner, _, _):
                out.append(["AXMType": "SubSuperScript",
                            "AXMBaseObject": ["AXMType": "Identifier", "AXMContent": "log", "AXMIsNumberOverride": true],
                            "AXMSubscriptObject": base.accessibilityMath, "AXMIsNumberOverride": true])
                out.append(fenced(inner))
            case .constant(let c):
                out.append(["AXMType": "Identifier", "AXMContent": c == .pi ? "π" : "e", "AXMIsNumberOverride": true])
            }
        }
        return out
    }

    /// How VoiceOver reads it: "1 + (, negative 2, )", "sine (, 30, )".
    var spoken: String {
        var words: [String] = []
        let writer = Writer(locales: [Locale.current], numberFormatter: nil)
        func fenced(_ inner: Row, closed: Bool) -> String {
            let body = inner.spoken
            return "(, " + (body.isEmpty ? "" : body + ", ") + (closed ? ")" : "implicit )")
        }
        for (i, node) in enumerated() {
            switch node {
            case .literal(let s):
                let t = writer.number(s)
                if let e = t.firstIndex(of: "e") {
                    words.append(String(t[..<e]) + " exponent " + String(t[t.index(after: e)...]))
                } else {
                    words.append(t)
                }
            case .op(.subtract) where i == 0 && count > 1:
                if case .literal(let s) = self[1] {
                    words.append("negative " + writer.number(s))
                    return (words + Array(self[2...]).spoken.split(separator: " ").map(String.init)).joined(separator: " ")
                }
                words.append("-")
            case .op(let b): words.append(b.text.trimmingCharacters(in: .whitespaces))
            case .postfix(let p): words.append(p.text)
            case .power(let base, let exponent, _):
                if let base { words.append(base.spoken) }
                switch exponent {
                case [.literal("2")]: words.append("squared")
                case [.literal("3")]: words.append("cubed")
                default: words.append("to the power of " + exponent.spoken)
                }
            case .group(let inner, let closed):
                words.append(fenced(inner, closed: closed))
            case .function(let f, let inner, let closed):
                let names: [Function: String] = [
                    .sin: "sine", .cos: "cosine", .tan: "tangent", .asin: "inverse sine", .acos: "inverse cosine",
                    .atan: "inverse tangent", .sinh: "hyperbolic sine", .cosh: "hyperbolic cosine",
                    .tanh: "hyperbolic tangent", .asinh: "inverse hyperbolic sine",
                    .acosh: "inverse hyperbolic cosine", .atanh: "inverse hyperbolic tangent", .ln: "natural log",
                ]
                words.append((names[f] ?? f.name) + " " + fenced(inner, closed: closed))
            case .root(let index, let inner, let closed, _):
                switch index {
                case nil: words.append("√ " + fenced(inner, closed: closed))
                case [.literal("3")]?: words.append("cube root of " + fenced(inner, closed: closed) + ", end of root")
                case let index?: words.append("root \(index.spoken) of " + fenced(inner, closed: closed) + ", end of root")
                }
            case .log(let base, let inner, let closed, _):
                words.append("log base \(base.spoken) of " + fenced(inner, closed: closed))
            case .constant(let c):
                words.append(c == .pi ? "pi" : "e")
            }
        }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

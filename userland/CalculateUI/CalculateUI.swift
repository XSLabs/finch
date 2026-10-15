// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CalculateUI: the views Calculator shows expressions in, to the interface of Apple's private
// framework. An expression is typeset from its rich tokens: numbers grouped, an exponent
// raised and smaller, a root's index small before its sign, a logarithm's base lowered. The
// line fits its width, its font shrinking to a minimum ratio. The RPN stack shows its
// entries a row each. Button labels name each key, with symbols where Calculator's keys have
// them.

import AppKit
import Calculate
import SwiftUI

// MARK: - Typesetting

/// The rich tokens as one Text: exponents raised, indexes and bases small.
struct Typesetter {
    var fontSize: CGFloat
    var expression: CalculateExpression
    var weight: Font.Weight = .light

    private var formatter: NumberFormatter {
        if let f = expression.numberFormatter { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 16
        return f
    }

    func text(_ rich: CalculateExpression.RichExpression, size: CGFloat? = nil, raise: CGFloat = 0) -> Text {
        let size = size ?? fontSize
        var out = Text("")
        for token in rich.tokens {
            out = out + piece(token, size: size, raise: raise)
        }
        return out
    }

    private func plain(_ s: String, size: CGFloat, raise: CGFloat) -> Text {
        Text(s).font(.system(size: size, weight: weight)).baselineOffset(raise)
    }

    private func piece(_ token: CalculateExpression.RichToken, size: CGFloat, raise: CGFloat) -> Text {
        let small = size * 0.6
        switch token.type {
        case .literal:
            var t = plain(number(token.text), size: size, raise: raise)
            if let base = token.right {
                t = t + text(base, size: small, raise: raise - size * 0.2)
            }
            return t
        case .exponentiate:
            var t = Text("")
            if let base = token.left { t = t + text(base, size: size, raise: raise) }
            if let exponent = token.right { t = t + text(exponent, size: small, raise: raise + size * 0.4) }
            return t
        case .placeholder:
            return plain("◻︎", size: size * 0.8, raise: raise)
        case .function where token.isRoot:
            var t = Text("")
            if let index = token.left { t = t + text(index, size: small * 0.8, raise: raise + size * 0.45) }
            return t + plain("√", size: size, raise: raise)
        case .function where token.isLog:
            var t = plain("log", size: size, raise: raise)
            if let base = token.right, !(base.tokens.count == 1 && base.tokens[0].text == "10") {
                t = t + text(base, size: small, raise: raise - size * 0.2)
            }
            return t
        case .function:
            if let width = token.right { return plain(token.text, size: size, raise: raise) + text(width, size: small, raise: raise - size * 0.2) }
            return plain(displayName(token.text), size: size, raise: raise)
        case .eulerNumber:
            return Text("e").font(.system(size: size, weight: weight).italic()).baselineOffset(raise)
        case .subtract:
            return plain("−", size: size, raise: raise)
        default:
            return plain(token.text, size: size, raise: raise)
        }
    }

    /// A function's name as shown (sin⁻¹ for asin).
    private func displayName(_ name: String) -> String {
        switch name {
        case "asin", "acos", "atan", "asinh", "acosh", "atanh": String(name.dropFirst()) + "⁻¹"
        default: name
        }
    }

    /// A number as shown: typed digits grouped; a result's literal ("3E+0") formatted.
    func number(_ s: String) -> String {
        if s.contains("E"), let v = Double(s) {
            return formatter.string(from: NSNumber(value: v)) ?? s
        }
        if s.contains("e") || s.contains(where: { $0.isLetter }) { return s }
        let grouping = formatter.groupingSeparator ?? ","
        let decimal = formatter.decimalSeparator ?? "."
        var integer = s, fraction: String?
        if let dot = s.firstIndex(of: ".") {
            integer = String(s[..<dot])
            fraction = String(s[s.index(after: dot)...])
        }
        var grouped = ""
        for (i, c) in integer.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped += String(grouping.reversed()) }
            grouped.append(c)
        }
        return String(grouped.reversed()) + (fraction.map { decimal + $0 } ?? "")
    }
}

// MARK: - Expression views

/// An expression on one line, typeset, fitting its width.
public struct CalculateExpressionView: View {
    let expression: CalculateExpression
    let isEditable: Bool
    let fontSize: CGFloat
    let minFontSizeRatio: CGFloat
    let textAlignment: TextAlignment
    let textColor: Color
    let truncationMode: Text.TruncationMode?
    let operationCallback: ((CalculateExpression.Operation) -> Void)?

    public init(expression: CalculateExpression, isEditable: Bool, fontSize: CGFloat?, minFontSizeRatio: CGFloat?,
                textAlignment: TextAlignment, textColor: Color, truncationMode: Text.TruncationMode?,
                operationCallback: ((CalculateExpression.Operation) -> Void)?) {
        self.expression = expression
        self.isEditable = isEditable
        self.fontSize = fontSize ?? 48
        self.minFontSizeRatio = minFontSizeRatio ?? 0.5
        self.textAlignment = textAlignment
        self.textColor = textColor
        self.truncationMode = truncationMode
        self.operationCallback = operationCallback
    }

    /// The line's height decides its font: the digits fill most of it.
    public init(expression: CalculateExpression, isEditable: Bool, height: CGFloat, minFontSizeRatio: CGFloat?,
                textAlignment: TextAlignment, textColor: Color, truncationMode: Text.TruncationMode?,
                operationCallback: ((CalculateExpression.Operation) -> Void)?) {
        self.init(expression: expression, isEditable: isEditable, fontSize: height * 0.82, minFontSizeRatio: minFontSizeRatio,
                  textAlignment: textAlignment, textColor: textColor, truncationMode: truncationMode,
                  operationCallback: operationCallback)
    }

    private var frameAlignment: Alignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        default: .trailing
        }
    }

    public var body: some View {
        if getenv("FINCH_CALCULATE_DEBUG") != nil {
            fputs("CalculateExpressionView: [\(expression.expression)] size \(fontSize)\n", stderr)
        }
        return Typesetter(fontSize: fontSize, expression: expression).text(expression.rich)
            .foregroundStyle(textColor)
            .lineLimit(1)
            .minimumScaleFactor(minFontSizeRatio)
            .truncationMode(truncationMode ?? .head)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .accessibilityLabel(Text(String(expression.accessibilityMathEquationDescription.characters)))
            .background {
                if isEditable {
                    _ExpressionKeys(expression: expression, callback: operationCallback)
                }
            }
    }
}

/// An editable expression takes what's typed in its window, as Apple's: each key that names a
/// calculator key is that key's operation, applied to the expression and then reported to the
/// calculator. It is the window's first responder when nothing else is (so Edit > Copy copies
/// the expression's result), and otherwise hears the keys nothing took, as key equivalents.
struct _ExpressionKeys: NSViewRepresentable {
    var expression: CalculateExpression
    var callback: ((CalculateExpression.Operation) -> Void)?

    final class KeyView: NSView {
        var expression: CalculateExpression?
        var callback: ((CalculateExpression.Operation) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.firstResponder === window {
                window.makeFirstResponder(self)
            }
        }

        /// The calculator key a key-down names, applied; false for any other key.
        private func apply(_ event: NSEvent) -> Bool {
            guard window != nil, !isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let typed = event.characters, typed.count == 1,
                  let operation = _ExpressionKeys.operation(for: typed.first!), let expression
            else { return false }
            if expression.update(operation) {
                callback?(operation)
            }
            return true
        }

        override func keyDown(with event: NSEvent) {
            if !apply(event) {
                super.keyDown(with: event)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            apply(event) || super.performKeyEquivalent(with: event)
        }

        @objc func copy(_ sender: Any?) {
            expression?.copyToClipboard(overridePlaintext: nil)
        }
    }

    static func operation(for c: Character) -> CalculateExpression.Operation? {
        switch c {
        case "0": .digit0
        case "1": .digit1
        case "2": .digit2
        case "3": .digit3
        case "4": .digit4
        case "5": .digit5
        case "6": .digit6
        case "7": .digit7
        case "8": .digit8
        case "9": .digit9
        case ".", ",": .decimal
        case "+": .add
        case "-": .subtract
        case "*": .multiply
        case "/": .divide
        case "%": .percent
        case "^": .power
        case "(": .openParenthesis
        case ")": .closeParenthesis
        case "!": .factorial
        case "=", "\r", "\u{3}": .equals
        case "\u{7F}", "\u{8}": .delete
        case "\u{1B}": .clear
        default: nil
        }
    }

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.expression = expression
        view.callback = callback
    }
}

/// The RPN stack: its last entries a row each, X at the bottom.
public struct CalculateExpressionStackView: View {
    let expression: CalculateExpression
    let textAlignment: TextAlignment
    let textColor: Color
    let rowCount: Int
    let separatorColor: Color
    let operationCallback: ((CalculateExpression.Operation) -> Void)?

    public init(expression: CalculateExpression, textAlignment: TextAlignment, textColor: Color, rowCount: Int,
                separatorColor: Color, operationCallback: ((CalculateExpression.Operation) -> Void)?) {
        self.expression = expression
        self.textAlignment = textAlignment
        self.textColor = textColor
        self.rowCount = rowCount
        self.separatorColor = separatorColor
        self.operationCallback = operationCallback
    }

    public var body: some View {
        let _ = getenv("FINCH_CALCULATE_DEBUG") != nil
            ? fputs("CalculateExpressionStackView: \(rowCount) rows, text \(textColor), separator \(separatorColor)\n", stderr) : 0
        let entries = Array(expression.postfixStack.suffix(max(1, rowCount)))
        let blanks = max(0, rowCount - entries.count)
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / CGFloat(max(1, rowCount))
            VStack(spacing: 0) {
                ForEach(0 ..< blanks, id: \.self) { _ in
                    separatorColor.frame(height: 1).frame(maxHeight: rowHeight, alignment: .bottom)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(spacing: 0) {
                        CalculateExpressionView(expression: entry, isEditable: false, height: rowHeight * 0.8,
                                                minFontSizeRatio: 0.4, textAlignment: textAlignment, textColor: textColor,
                                                truncationMode: .head, operationCallback: operationCallback)
                            .frame(maxHeight: .infinity)
                        separatorColor.frame(height: 1)
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }
}

/// An expression typeset, with its result after "=" when asked for.
public struct CalculateExpressionTypesetView: View {
    let expression: CalculateExpression
    let result: String?
    let showResult: Bool
    let fontSize: CGFloat

    public init(expression: CalculateExpression) {
        self.init(expression: expression, result: nil, showResult: false, fontSize: 17)
    }

    public init(expression: CalculateExpression, fontSize: CGFloat) {
        self.init(expression: expression, result: nil, showResult: false, fontSize: fontSize)
    }

    public init(expression: CalculateExpression, result: String?, showResult: Bool) {
        self.init(expression: expression, result: result, showResult: showResult, fontSize: 17)
    }

    public init(expression: CalculateExpression, result: String?, showResult: Bool, fontSize: CGFloat) {
        self.expression = expression
        self.result = result
        self.showResult = showResult
        self.fontSize = fontSize
    }

    public var body: some View {
        let setter = Typesetter(fontSize: fontSize, expression: expression, weight: .regular)
        var text = setter.text(expression.rich)
        if showResult, let r = result ?? expression.result?.formattedResult {
            text = text + Text(" = " + r).font(.system(size: fontSize))
        }
        return text.lineLimit(1)
    }
}

// MARK: - Keys

extension CalculateExpression {
    /// Calculator's keys that aren't operations on the expression.
    public enum CalculatorButton: Hashable {
        case memoryClear, memoryAdd, memorySubtract, memoryRecall, second, degrees, radians
    }

    /// A key's face.
    public struct Label: View {
        let text: AttributedString?
        let symbol: String?
        let fontSize: CGFloat
        public let caption: AttributedString?

        init(text: AttributedString? = nil, symbol: String? = nil, fontSize: CGFloat, caption: AttributedString?) {
            self.text = text
            self.symbol = symbol
            self.fontSize = fontSize
            self.caption = caption
        }

        public var body: some View {
            if let symbol {
                Image(systemName: symbol).font(.system(size: fontSize, weight: .medium))
            } else {
                Text(text ?? AttributedString("")).font(.system(size: fontSize))
            }
        }
    }

    public func label(for button: CalculatorButton, fontSize: CGFloat) -> Label {
        Label(text: Self.face(for: button), fontSize: fontSize, caption: caption(for: button, fontSize: fontSize))
    }

    public func caption(for button: CalculatorButton, fontSize: CGFloat) -> AttributedString {
        let names: [CalculatorButton: String] = [
            .memoryClear: "Memory Clear", .memoryAdd: "Memory Add", .memorySubtract: "Memory Subtract",
            .memoryRecall: "Memory Recall", .second: "Second Function", .degrees: "Degrees", .radians: "Radians",
        ]
        return AttributedString(names[button] ?? "")
    }

    static func face(for button: CalculatorButton) -> AttributedString {
        switch button {
        case .memoryClear: AttributedString("mc")
        case .memoryAdd: AttributedString("m+")
        case .memorySubtract: AttributedString("m−")
        case .memoryRecall: AttributedString("mr")
        case .second: superscripted("2", "nd")
        case .degrees: AttributedString("Deg")
        case .radians: AttributedString("Rad")
        }
    }

    /// Text with a raised part (x², 2ⁿᵈ).
    static func superscripted(_ base: String, _ raised: String, after: String = "") -> AttributedString {
        var a = AttributedString(base)
        var r = AttributedString(raised)
        r.baselineOffset = 6
        r.font = .system(size: 11)
        a.append(r)
        a.append(AttributedString(after))
        return a
    }

    static func subscripted(_ base: String, _ lowered: String) -> AttributedString {
        var a = AttributedString(base)
        var l = AttributedString(lowered)
        l.baselineOffset = -4
        l.font = .system(size: 11)
        a.append(l)
        return a
    }

    public func label(for operation: Operation, fontSize: CGFloat) -> Label {
        let caption = AttributedString(Self.spokenName(operation))
        if let symbol = Self.symbol(for: operation) {
            return Label(symbol: symbol, fontSize: fontSize, caption: caption)
        }
        return Label(text: face(for: operation), fontSize: fontSize, caption: caption)
    }

    /// Keys drawn as symbols, as Calculator's are.
    static func symbol(for operation: Operation) -> String? {
        switch operation {
        case .add: "plus"
        case .subtract: "minus"
        case .multiply: "multiply"
        case .divide: "divide"
        case .equals: "equal"
        case .percent: "percent"
        case .negate: "plus.forwardslash.minus"
        case .delete: "delete.left"
        default: nil
        }
    }

    func face(for operation: Operation) -> AttributedString {
        let s = Self.superscripted, l = Self.subscripted
        let plain: [Operation: String] = [
            .digit0: "0", .digit1: "1", .digit2: "2", .digit3: "3", .digit4: "4", .digit5: "5", .digit6: "6",
            .digit7: "7", .digit8: "8", .digit9: "9", .digitA: "A", .digitB: "B", .digitC: "C", .digitD: "D",
            .digitE: "E", .digitF: "F", .digit00: "00", .digitFF: "FF", .decimal: Locale.current.decimalSeparator ?? ".",
            .allClear: "AC", .clear: "C", .openParenthesis: "(", .closeParenthesis: ")", .pi: "π", .eulerNumber: "e",
            .ee: "EE", .random: "Rand", .sine: "sin", .cosine: "cos", .tangent: "tan", .hyperbolicSine: "sinh",
            .hyperbolicCosine: "cosh", .hyperbolicTangent: "tanh", .logarithmNatural: "ln", .factorial: "x!",
            .mod: "mod", .and: "AND", .or: "OR", .xor: "XOR", .nor: "NOR", .not: "NOT", .neg: "NEG",
            .leftShift: "<<", .rightShift: ">>", .leftRotate: "RoL", .rightRotate: "RoR", .enter: "enter",
            .swap: "x⇆y", .drop: "drop", .rollIn: "R↓", .rollOut: "R↑", .byteFlip: "byte flip", .wordFlip: "word flip",
        ]
        if let p = plain[operation] {
            if operation == .clear || operation == .allClear { return AttributedString(prefersClear ? "C" : "AC") }
            return AttributedString(p)
        }
        switch operation {
        case .square: return s("x", "2", "")
        case .cube: return s("x", "3", "")
        case .power: return s("x", "y", "")
        case .exponentialBaseCustom: return s("y", "x", "")
        case .exponentialBaseEuler: return s("e", "x", "")
        case .exponentialBase10: return s("10", "x", "")
        case .exponentialBase2: return s("2", "x", "")
        case .reciprocal: return AttributedString("1/x")
        case .squareRoot: return s("", "2", "√x")
        case .cubeRoot: return s("", "3", "√x")
        case .root: return s("", "y", "√x")
        case .reverseRoot: return s("", "x", "√y")
        case .logarithmBase10: return l("log", "10")
        case .logarithmBase2: return l("log", "2")
        case .logarithmBaseCustom: return l("log", "y")
        case .inverseSine: return s("sin", "-1", "")
        case .inverseCosine: return s("cos", "-1", "")
        case .inverseTangent: return s("tan", "-1", "")
        case .inverseHyperbolicSine: return s("sinh", "-1", "")
        case .inverseHyperbolicCosine: return s("cosh", "-1", "")
        case .inverseHyperbolicTangent: return s("tanh", "-1", "")
        case .leftShiftCustom: return s("x<<", "y", "")
        case .rightShiftCustom: return s("x>>", "y", "")
        default: return AttributedString("")
        }
    }

    static func spokenName(_ operation: Operation) -> String {
        let names: [Operation: String] = [
            .add: "Add", .subtract: "Subtract", .multiply: "Multiply", .divide: "Divide", .equals: "Equals",
            .percent: "Percent", .negate: "Negate", .delete: "Delete", .allClear: "All Clear", .clear: "Clear",
            .decimal: "Decimal", .squareRoot: "Square Root", .cubeRoot: "Cube Root", .square: "Squared",
            .cube: "Cubed", .reciprocal: "Reciprocal", .factorial: "Factorial", .pi: "Pi", .eulerNumber: "e",
            .random: "Random", .openParenthesis: "Open Parenthesis", .closeParenthesis: "Close Parenthesis",
        ]
        if let n = names[operation] { return n }
        return ""
    }

    /// Copies the expression (or the text given) to the general pasteboard.
    public func copyToClipboard(overridePlaintext: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let text = overridePlaintext ?? result?.formattedResult ?? copyableExpression
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Currency

extension StocksKitCurrencyCache {
    /// Where exchange rates come from. Finch has no rate service, so no provider.
    public struct Provider {
        public let name: String
        public let logo: Image?
        public let destination: URL?
    }

    public var provider: Provider? {
        get async { nil }
    }
}

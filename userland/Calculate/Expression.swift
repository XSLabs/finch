// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CalculateExpression, to the interface of Apple's Calculate: the expression a calculator
// edits, key by key (update(_:)), with its evaluated result, the tokens it shows (plain, and
// rich for typeset display), its RPN stack and its programmer-mode base and bits.

import Foundation
import Observation

public final class CalculateExpression: Hashable, CustomDebugStringConvertible, Observable {
    // MARK: Nested types

    /// The base programmer mode writes numbers in.
    public enum Base: Int {
        case base8 = 8
        case base10 = 10
        case base16 = 16
    }

    /// What a token is.
    public enum TokenType: Hashable {
        case add, and, ans, closeBracket, closeCeil, closeCurlyBrace, closeFloor, closeParenthesis, comma
        case divide, equal, eulerNumber, exponentiate, factorial, function, laTeX, leftRotate, leftShift
        case literal, multiply, neg, nor, not, openBracket, openCeil, openCurlyBrace, openFloor
        case openParenthesis, or, percent, pi, placeholder, punctuation, rightRotate, rightShift, subtract
        case symbol, texCloseAbs, texCloseCeil, texCloseFloor, texCloseParenthesis, texFrac, texOpenAbs
        case texOpenCeil, texOpenFloor, texOpenParenthesis, texVerticalBegin, texVerticalEnd, unit, unknown
        case variable, whitespace, xor

        public var isOperator: Bool {
            switch self {
            case .add, .subtract, .multiply, .divide, .exponentiate, .percent, .factorial, .and, .or, .xor, .nor,
                 .not, .neg, .leftShift, .rightShift, .leftRotate, .rightRotate, .equal:
                true
            default:
                false
            }
        }

        public var isFunction: Bool { self == .function }
        public var isConstant: Bool { self == .pi || self == .eulerNumber }
    }

    /// A key a calculator sends (update(_:)).
    public class Operation: Hashable {
        let key: Key

        init(_ key: Key) {
            self.key = key
        }

        public static func == (lhs: Operation, rhs: Operation) -> Bool {
            lhs.key == rhs.key
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(key)
        }
    }

    /// An operand given as a result (a memory recall, a conversion).
    public class CustomOperandOperation: Operation {
        let operand: CalculateResult

        public init(_ operand: CalculateResult) {
            self.operand = operand
            super.init(.custom)
        }
    }

    /// A token of the plain expression.
    public class Token {
        public final let type: TokenType
        let text: String

        init(type: TokenType, text: String) {
            self.type = type
            self.text = text
        }
    }

    /// A token of the rich expression: its text, or (a root, a logarithm) the expressions
    /// it is typeset around.
    public class RichToken {
        public final let type: TokenType
        let storedText: String
        let storedLeft: RichExpression?
        let storedRight: RichExpression?
        let storedIsLog: Bool
        let storedIsRoot: Bool

        let isImplicit: Bool

        init(type: TokenType, text: String, left: RichExpression? = nil, right: RichExpression? = nil,
             isLog: Bool = false, isRoot: Bool = false, isImplicit: Bool = false) {
            self.type = type
            self.storedText = text
            self.storedLeft = left
            self.storedRight = right
            self.storedIsLog = isLog
            self.storedIsRoot = isRoot
            self.isImplicit = isImplicit
        }

        public required init(text: String?, type: TokenType, isImplicit: Bool) {
            self.type = type
            self.storedText = text ?? ""
            self.storedLeft = nil
            self.storedRight = nil
            self.storedIsLog = false
            self.storedIsRoot = false
            self.isImplicit = isImplicit
        }

        public var text: String { storedText }
        public var left: RichExpression? { storedLeft }
        public var right: RichExpression? { storedRight }
        public var isLog: Bool { storedIsLog }
        public var isRoot: Bool { storedIsRoot }
    }

    /// The expression as plain tokens.
    public class PlainExpression {
        let storedTokens: [Token]

        init(_ tokens: [Token]) {
            self.storedTokens = tokens
        }

        public var tokens: [Token] { storedTokens }
    }

    /// The expression as rich tokens, for typeset display.
    public class RichExpression {
        let storedTokens: [RichToken]
        let zero: Bool

        init(_ tokens: [RichToken], isZero: Bool = false) {
            self.storedTokens = tokens
            self.zero = isZero
        }

        public var tokens: [RichToken] { storedTokens }
        public var isEmpty: Bool { storedTokens.isEmpty }
        public var isZero: Bool { zero }
    }

    // MARK: State

    let id: UUID
    private var _state: CalculatorState
    private let registrar = ObservationRegistrar()

    /// Everything the expression holds; reading it is observed, as Apple's expression is
    /// observable (a calculator's display follows its expression).
    var state: CalculatorState {
        get {
            registrar.access(self, keyPath: \.state)
            return _state
        }
        set {
            registrar.withMutation(of: self, keyPath: \.state) { _state = newValue }
        }
    }

    public init(_ expression: String, options: [CalculateKey: Any], base: Base, id: UUID) {
        self.id = id
        self._state = CalculatorState(options: options, base: base)
        if expression.isEmpty {
            self.state.reevaluate()
        } else {
            self.state.setExpression(expression)
        }
    }

    public convenience init(options: [CalculateKey: Any], base: Base, id: UUID) {
        self.init("", options: options, base: base, id: id)
    }

    public convenience init(result: CalculateResult?, error: Error?, options: [CalculateKey: Any], base: Base, id: UUID) {
        self.init("", options: options, base: base, id: id)
        state.setResult(result, error: error)
    }

    public static func == (lhs: CalculateExpression, rhs: CalculateExpression) -> Bool {
        lhs === rhs || (lhs.id == rhs.id && lhs.state.expressionText == rhs.state.expressionText)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: The expression and its result

    public var expression: String {
        get { state.expressionText }
        set { state.setExpression(newValue) }
    }

    public var options: [CalculateKey: Any] { state.options }
    public var result: CalculateResult? { state.result }
    public var error: Error? { state.error }
    public var activeError: Error? { nil }
    public var activeOperation: Operation? { state.activeOperation }
    public var allowedOperations: Set<Operation> { state.allowedOperations }
    public var prefersClear: Bool { state.prefersClear }
    public var prefersRTL: Bool { false }

    /// RPN: the stack's entries, X last.
    public var postfixStack: [CalculateExpression] {
        state.rpnEntries.map { entry in
            let e = CalculateExpression(options: state.options, base: state.base, id: UUID())
            e.state.engine = state.engine
            e.state.format = state.format
            e.state.numberFormatter = state.numberFormatter
            e.state.locales = state.locales
            e.state.row = entry
            e.state.cleared = false
            e.state.reevaluate()
            return e
        }
    }

    public var plain: PlainExpression { state.plain }
    public var rich: RichExpression { state.rich }
    public var removed: RichExpression? { state.removed }
    public var copyableExpression: String { state.expressionText }
    public var debugDescription: String { state.debugText }

    /// The integer part of the result as bytes (ASCII) and as a character (Unicode).
    public var ascii: String {
        guard let v = state.result?.doubleValue, v.isFinite, v >= 1 else { return "" }
        var n = v >= 1.8e19 ? UInt64.max : UInt64(v)
        var bytes: [UInt8] = []
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public var unicode: String {
        guard let v = state.result?.doubleValue, v.isFinite, v >= 0, v < 0x110000,
              let scalar = Unicode.Scalar(UInt32(v)) else { return "\u{0}" }
        return String(Character(scalar))
    }

    public var accessibilityMathEquation: [AnyHashable: Any] { state.shownRow.accessibilityMath }
    public var accessibilityMathEquationDescription: AttributedString { AttributedString(state.shownRow.spoken) }

    // MARK: Settings

    public var base: Base {
        get { state.base }
        set { state.setBase(newValue) }
    }

    public var bits: [Bool] {
        get { state.bits }
        set { state.setBits(newValue) }
    }

    public var assumeDegrees: Bool {
        get { state.assumeDegrees }
        set { state.assumeDegrees = newValue; state.reevaluate() }
    }

    public var format: CalculateFormat {
        get { state.format }
        set {
            let wasRPN = state.isRPN
            state.format = newValue
            if state.isRPN && !wasRPN {
                // the expression's value becomes X
                state.reevaluate()
                state.row = state.resultRow(state.result?.doubleValue ?? 0)
                state.stack = []
                state.liftNext = false
                state.replaceNext = true
            }
            state.reevaluate()
        }
    }

    public var engine: CalculateEngine {
        get { state.engine }
        set { state.engine = newValue; state.reevaluate() }
    }

    public var locales: [Locale] {
        get { state.locales }
        set { state.locales = newValue; state.reevaluate() }
    }

    public var numberFormatter: NumberFormatter? {
        get { state.numberFormatter }
        set { state.numberFormatter = newValue; state.reevaluate() }
    }

    public var allowsArabicMath: Bool {
        get { state.allowsArabicMath }
        set { state.allowsArabicMath = newValue }
    }

    // MARK: Editing

    /// Applies a key; whether it applied.
    @discardableResult
    public func update(_ operation: Operation) -> Bool {
        let applied = state.apply(operation)
        if Self.debug {
            fputs("Calculate: \(operation.key) \(applied ? "applied" : "refused") -> [\(state.expressionText)]\n", stderr)
        }
        return applied
    }

    /// FINCH_CALCULATE_DEBUG=1: each key on stderr, with the expression it leaves.
    static let debug = getenv("FINCH_CALCULATE_DEBUG") != nil

    /// Clears the expression, the stack and any pending operation.
    public func clearAll() {
        state.clearAll()
    }

    /// Replaces the expression with its result.
    public func inlineEvaluate() {
        state.inlineEvaluate()
    }

    /// Replaces the expression with another's result.
    public func inlineEvaluate(_ other: CalculateExpression) {
        state.inlineEvaluate(other.state)
    }

    /// Repeats the operation taken from another expression (a second "=": "+2" again).
    public func repeatOperation() {
        state.repeatOperation()
    }

    /// Takes the operation another expression would repeat: its last operator and operand.
    public func setRepeatableOperation(from other: CalculateExpression) {
        state.repeatable = other.state.repeatable ?? other.state.lastOperation()
        state.repeated = false
    }
}

/// Evaluates an expression with options: its result, or nil when it doesn't evaluate.
public func evaluate(_ expression: String, options: [CalculateKey: Any]) -> CalculateResult? {
    try? evaluateError(expression, options: options)
}

/// Evaluates an expression with options, throwing why it doesn't evaluate.
public func evaluateError(_ expression: String, options: [CalculateKey: Any]) throws -> CalculateResult {
    try Evaluator(options: options).evaluate(expression)
}

extension CalculateResult {
    /// The result in another unit, as from a given unit.
    public func converted(to unit: CalculateUnit, from: CalculateUnit) -> CalculateResult? {
        __converted(to: unit, from: from)
    }
}

extension CalculateUnit: Identifiable {
    public var id: String { name }
}

extension CalculateUnitCategory: Identifiable {
    public var id: String { name }
}

/// Exchange rates for currency conversion. Finch has no rate service: the cache never fills.
public class StocksKitCurrencyCache: NSObject {
    public static let shared = StocksKitCurrencyCache()

    public static var isEnabled: Bool { false }

    public var needsRefresh: Bool { CalculateCurrencyCache.shared.needsRefresh }

    public var lastRefreshDate: Date? {
        get async { CalculateCurrencyCache.shared.lastRefreshDate }
    }

    public func refresh() async -> Bool {
        CalculateCurrencyCache.shared.refresh()
    }
}

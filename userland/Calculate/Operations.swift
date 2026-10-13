// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The keys a calculator sends a CalculateExpression, as Apple's Calculate names them.

extension CalculateExpression.Operation {
    /// Which key an operation is.
    enum Key: Hashable {
        case add, allClear, and, byteFlip, clear, closeParenthesis, cosine, cube, cubeRoot, decimal, delete, digit0, digit00, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, digitA, digitB, digitC, digitD, digitE, digitF, digitFF, divide, drop, ee, enter, equals, eulerNumber, exponentialBase10, exponentialBase2, exponentialBaseCustom, exponentialBaseEuler, factorial, hyperbolicCosine, hyperbolicSine, hyperbolicTangent, inverseCosine, inverseHyperbolicCosine, inverseHyperbolicSine, inverseHyperbolicTangent, inverseSine, inverseTangent, leftRotate, leftShift, leftShiftCustom, logarithmBase10, logarithmBase2, logarithmBaseCustom, logarithmNatural, mod, multiply, neg, negate, nor, not, openParenthesis, or, percent, pi, power, random, reciprocal, reverseRoot, rightRotate, rightShift, rightShiftCustom, rollIn, rollOut, root, sine, square, squareRoot, subtract, swap, tangent, wordFlip, xor, custom
    }

    public static var add: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.add) }
    public static var allClear: CalculateExpression.AllClearOperation { CalculateExpression.AllClearOperation(.allClear) }
    public static var `and`: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.`and`) }
    public static var byteFlip: CalculateExpression.FlipOperation { CalculateExpression.FlipOperation(.byteFlip) }
    public static var clear: CalculateExpression.ClearOperation { CalculateExpression.ClearOperation(.clear) }
    public static var closeParenthesis: CalculateExpression.CloseParenthesisOperation { CalculateExpression.CloseParenthesisOperation(.closeParenthesis) }
    public static var cosine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.cosine) }
    public static var cube: CalculateExpression.PowerOperation { CalculateExpression.PowerOperation(.cube) }
    public static var cubeRoot: CalculateExpression.RootOperation { CalculateExpression.RootOperation(.cubeRoot) }
    public static var decimal: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.decimal) }
    public static var delete: CalculateExpression.DeleteOperation { CalculateExpression.DeleteOperation(.delete) }
    public static var digit0: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit0) }
    public static var digit00: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit00) }
    public static var digit1: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit1) }
    public static var digit2: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit2) }
    public static var digit3: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit3) }
    public static var digit4: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit4) }
    public static var digit5: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit5) }
    public static var digit6: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit6) }
    public static var digit7: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit7) }
    public static var digit8: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit8) }
    public static var digit9: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digit9) }
    public static var digitA: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitA) }
    public static var digitB: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitB) }
    public static var digitC: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitC) }
    public static var digitD: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitD) }
    public static var digitE: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitE) }
    public static var digitF: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitF) }
    public static var digitFF: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.digitFF) }
    public static var divide: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.divide) }
    public static var drop: CalculateExpression.DropOperation { CalculateExpression.DropOperation(.drop) }
    public static var ee: CalculateExpression.LiteralOperation { CalculateExpression.LiteralOperation(.ee) }
    public static var enter: CalculateExpression.EnterOperation { CalculateExpression.EnterOperation(.enter) }
    public static var equals: CalculateExpression.EqualsOperation { CalculateExpression.EqualsOperation(.equals) }
    public static var eulerNumber: CalculateExpression.ConstantOperation { CalculateExpression.ConstantOperation(.eulerNumber) }
    public static var exponentialBase10: CalculateExpression.ExponentialOperation { CalculateExpression.ExponentialOperation(.exponentialBase10) }
    public static var exponentialBase2: CalculateExpression.ExponentialOperation { CalculateExpression.ExponentialOperation(.exponentialBase2) }
    public static var exponentialBaseCustom: CalculateExpression.ExponentialOperation { CalculateExpression.ExponentialOperation(.exponentialBaseCustom) }
    public static var exponentialBaseEuler: CalculateExpression.ExponentialOperation { CalculateExpression.ExponentialOperation(.exponentialBaseEuler) }
    public static var factorial: CalculateExpression.FactorialOperation { CalculateExpression.FactorialOperation(.factorial) }
    public static var hyperbolicCosine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.hyperbolicCosine) }
    public static var hyperbolicSine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.hyperbolicSine) }
    public static var hyperbolicTangent: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.hyperbolicTangent) }
    public static var inverseCosine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseCosine) }
    public static var inverseHyperbolicCosine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseHyperbolicCosine) }
    public static var inverseHyperbolicSine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseHyperbolicSine) }
    public static var inverseHyperbolicTangent: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseHyperbolicTangent) }
    public static var inverseSine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseSine) }
    public static var inverseTangent: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.inverseTangent) }
    public static var leftRotate: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.leftRotate) }
    public static var leftShift: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.leftShift) }
    public static var leftShiftCustom: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.leftShiftCustom) }
    public static var logarithmBase10: CalculateExpression.LogOperation { CalculateExpression.LogOperation(.logarithmBase10) }
    public static var logarithmBase2: CalculateExpression.LogOperation { CalculateExpression.LogOperation(.logarithmBase2) }
    public static var logarithmBaseCustom: CalculateExpression.LogOperation { CalculateExpression.LogOperation(.logarithmBaseCustom) }
    public static var logarithmNatural: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.logarithmNatural) }
    public static var mod: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.mod) }
    public static var multiply: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.multiply) }
    public static var neg: CalculateExpression.NegOperation { CalculateExpression.NegOperation(.neg) }
    public static var negate: CalculateExpression.NegateOperation { CalculateExpression.NegateOperation(.negate) }
    public static var nor: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.nor) }
    public static var `not`: CalculateExpression.NotOperation { CalculateExpression.NotOperation(.`not`) }
    public static var openParenthesis: CalculateExpression.OpenParenthesisOperation { CalculateExpression.OpenParenthesisOperation(.openParenthesis) }
    public static var `or`: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.`or`) }
    public static var percent: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.percent) }
    public static var pi: CalculateExpression.ConstantOperation { CalculateExpression.ConstantOperation(.pi) }
    public static var power: CalculateExpression.PowerOperation { CalculateExpression.PowerOperation(.power) }
    public static var random: CalculateExpression.RandOperation { CalculateExpression.RandOperation(.random) }
    public static var reciprocal: CalculateExpression.ReciprocalOperation { CalculateExpression.ReciprocalOperation(.reciprocal) }
    public static var reverseRoot: CalculateExpression.RootOperation { CalculateExpression.RootOperation(.reverseRoot) }
    public static var rightRotate: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.rightRotate) }
    public static var rightShift: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.rightShift) }
    public static var rightShiftCustom: CalculateExpression.ShiftOperation { CalculateExpression.ShiftOperation(.rightShiftCustom) }
    public static var rollIn: CalculateExpression.RollInOperation { CalculateExpression.RollInOperation(.rollIn) }
    public static var rollOut: CalculateExpression.RollOutOperation { CalculateExpression.RollOutOperation(.rollOut) }
    public static var root: CalculateExpression.RootOperation { CalculateExpression.RootOperation(.root) }
    public static var sine: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.sine) }
    public static var square: CalculateExpression.PowerOperation { CalculateExpression.PowerOperation(.square) }
    public static var squareRoot: CalculateExpression.RootOperation { CalculateExpression.RootOperation(.squareRoot) }
    public static var subtract: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.subtract) }
    public static var swap: CalculateExpression.SwapOperation { CalculateExpression.SwapOperation(.swap) }
    public static var tangent: CalculateExpression.FunctionOperation { CalculateExpression.FunctionOperation(.tangent) }
    public static var wordFlip: CalculateExpression.FlipOperation { CalculateExpression.FlipOperation(.wordFlip) }
    public static var xor: CalculateExpression.BasicOperatorOperation { CalculateExpression.BasicOperatorOperation(.xor) }
}

extension CalculateExpression {
    // What kind of key an operation is, as Apple's Calculate types them.
    public class AllClearOperation: Operation {}
    public class BasicOperatorOperation: Operation {}
    public class ClearOperation: Operation {}
    public class CloseParenthesisOperation: Operation {}
    public class ConstantOperation: Operation {}
    public class DeleteOperation: Operation {}
    public class DropOperation: Operation {}
    public class EnterOperation: Operation {}
    public class EqualsOperation: Operation {}
    public class ExponentialOperation: Operation {}
    public class FactorialOperation: Operation {}
    public class FlipOperation: Operation {}
    public class FunctionOperation: Operation {}
    public class LiteralOperation: Operation {}
    public class LogOperation: Operation {}
    public class NegOperation: Operation {}
    public class NegateOperation: Operation {}
    public class NotOperation: Operation {}
    public class OpenParenthesisOperation: Operation {}
    public class PowerOperation: Operation {}
    public class RandOperation: Operation {}
    public class ReciprocalOperation: Operation {}
    public class RollInOperation: Operation {}
    public class RollOutOperation: Operation {}
    public class RootOperation: Operation {}
    public class ShiftOperation: Operation {}
    public class SwapOperation: Operation {}
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Calculate (Calculator's engine): key sequences in the plain, RPN and programmer modes and
// text expressions, each printed as its expression text, tokens, result and state, to compare
// Finch's Calculate with Apple's. (Random numbers and digits past a double's are left out:
// Apple's engine keeps 34 decimal digits.)
//
//   build/userland/finch-calculate-test

import Calculate
import Foundation

typealias Op = CalculateExpression.Operation

let named: [(String, Op)] = [
    ("0", .digit0), ("1", .digit1), ("2", .digit2), ("3", .digit3), ("4", .digit4), ("5", .digit5),
    ("6", .digit6), ("7", .digit7), ("8", .digit8), ("9", .digit9), ("A", .digitA), ("hB", .digitB),
    ("hC", .digitC), ("hD", .digitD), ("hE", .digitE), ("F", .digitF), ("00", .digit00), ("FF", .digitFF),
    (".", .decimal), ("+", .add), ("-", .subtract), ("*", .multiply), ("/", .divide), ("=", .equals),
    ("%", .percent), ("neg", .negate), ("C", .clear), ("AC", .allClear), ("del", .delete),
    ("(", .openParenthesis), (")", .closeParenthesis), ("sin", .sine), ("cos", .cosine), ("tan", .tangent),
    ("asin", .inverseSine), ("sinh", .hyperbolicSine), ("asinh", .inverseHyperbolicSine),
    ("sqrt", .squareRoot), ("cbrt", .cubeRoot), ("root", .root), ("rroot", .reverseRoot), ("x2", .square),
    ("x3", .cube), ("1/x", .reciprocal), ("!", .factorial), ("pi", .pi), ("e", .eulerNumber),
    ("ln", .logarithmNatural), ("log", .logarithmBase10), ("log2", .logarithmBase2),
    ("logy", .logarithmBaseCustom), ("^", .power), ("^y", .exponentialBaseCustom),
    ("exp", .exponentialBaseEuler), ("10^", .exponentialBase10), ("2^", .exponentialBase2), ("EE", .ee),
    ("mod", .mod), ("enter", .enter), ("swap", .swap), ("drop", .drop), ("rollin", .rollIn),
    ("rollout", .rollOut), ("and", .and), ("or", .or), ("xor", .xor), ("nor", .nor), ("not", .not),
    ("negp", .neg), ("<<", .leftShift), (">>", .rightShift), ("<<y", .leftShiftCustom),
    (">>y", .rightShiftCustom), ("rol", .leftRotate), ("ror", .rightRotate), ("flipb", .byteFlip),
    ("flipw", .wordFlip),
]
let byName = Dictionary(uniqueKeysWithValues: named)

func name(_ o: Op?) -> String {
    guard let o else { return "nil" }
    return named.first { $0.1 == o }?.0 ?? "?"
}

func rich(_ r: CalculateExpression.RichExpression?) -> String {
    guard let r else { return "nil" }
    return "{" + r.tokens.map { t in
        "\(t.type):'\(t.text)'" + (t.left != nil ? " L\(rich(t.left))" : "") + (t.right != nil ? " R\(rich(t.right))" : "")
            + (t.isLog ? " log" : "") + (t.isRoot ? " root" : "")
    }.joined(separator: ",") + "}"
}

func code(_ e: Error?) -> String {
    e.map { "\(($0 as NSError).domain) \(($0 as NSError).code) \($0.localizedDescription)" } ?? "-"
}

func keys(_ title: String, _ lines: [String], base: CalculateExpression.Base = .base10, engine: UInt = 0, format: UInt = 0) {
    print("== \(title)")
    for line in lines {
        let e = CalculateExpression(options: [:], base: base, id: UUID())
        if engine != 0 { e.engine = CalculateEngine(rawValue: engine) }
        if format != 0 { e.format = CalculateFormat(rawValue: format) }
        var applied = ""
        for k in line.split(separator: " ") {
            applied += byName[String(k)].map { e.update($0) ? "y" : "n" } ?? "?"
        }
        let allowed = named.filter { e.allowedOperations.contains($0.1) }.count
        print("\(line) | \(applied) | [\(e.expression)] \(e.debugDescription) res=\(e.result?.formattedResult ?? "nil") "
            + "triv=\(e.result?.isTrivial ?? false) err=\(code(e.error)) clear=\(e.prefersClear) zero=\(e.rich.isZero) "
            + "active=\(name(e.activeOperation)) allowed=\(allowed) stack=\(e.postfixStack.map(\.expression))")
        print("    rich=\(rich(e.rich)) removed=\(rich(e.removed))")
        print("    plain=\(e.plain.tokens.map { "\($0.type)" }.joined(separator: " "))")
    }
}

var info = Dl_info()
dladdr(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "OBJC_CLASS_$_CalculateResult"), &info)
print(info.dli_fname.map { String(cString: $0) } ?? "?")
setvbuf(stdout, nil, _IOLBF, 0)

keys("keys", [
    "2 ^ 3 + 1",
    "2 ^ 3 2",
    "2 ^ ( 1 + 2",
    "2 ^ ( 1 + 2 ) + 1",
    "2 ^ 3 )",
    "2 ^ 3 x2",
    "2 ^ 3 sqrt",
    "2 ^ sin 3",
    "sin 3 0 + 1",
    "sin 3 0 ) + 1",
    "1 + 2 sqrt",
    "( 1 + 2 ) sqrt",
    "1 + 2 x2",
    "2 ^ 3 del",
    "2 ^ 3 del del",
    "2 ^ 3 del del del",
    "sin del",
    "sin 3 del",
    "sin 3 del del",
    "9 sqrt del",
    "( 1 + 2 ) del",
    "3 neg del",
    "2 ^ 3 C",
    "sin 3 C",
    "1 + 2 neg neg",
    "1 0 0 0 . 5",
    "0 . 0 0",
    "1 / 0",
    "0 / 0",
    "5 asin",
    "2 0 0 !",
    "pi 2",
    ") 2",
    "( 1 ) 2",
    "2 sin",
    "1 + sin 3",
    "2 pi",
    "pi pi",
    "2 e",
    "e 2",
    "5 % 2",
    "5 ! 2",
    "1 + 2 1/x",
    "2 x2 ^ 3",
    "1 + 2 ^y 3",
    "1 + 2 root 3",
    "1 . 5 neg",
    "1 EE 3 neg",
    "1 EE neg 3",
    "3 log",
    "2 exp exp",
    "1 + del",
    "1 2 . del",
    "0 1",
    "neg 5",
    "- neg",
    "1 + 2 % %",
    "5 ! !",
    "",
    "1 +",
    "( 1",
    "sin",
    "2 ^",
    "1 .",
    "1 EE",
    "AC",
    "1 + 2 C",
    "1 + 2 C C",
    "1 + 2 C del",
    "1 * - 2",
    "( - 2",
    "( + 2",
    "2 ^ - 3",
    "2 ^ ( - 3",
    "sqrt sqrt 1 6",
    "1 6 sqrt sqrt",
    "2 ^ 3 ^ 2",
    "2 ^ 3 neg",
    "2 ^ 3 %",
    "1 / 3 * 3",
    "1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0",
    "0 . 1 + 0 . 2",
    "1 EE 3 0 0 0",
    "9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 * 9 9 9 9 9 9 9 9 9 9",
    "2 cbrt",
    "3 x3",
    "1 0 log2",
    "4 2^",
    "5 0 + 1 0 % =",
    "1 + ( 2 C",
    "1 + sin C",
    "2 ^ C",
    "pi C",
    "1 + pi del",
    "2 pi del",
    "sin 3 ) del",
    "sin 3 ) del del",
])
keys("rpn", [
    "1",
    "1 enter",
    "1 enter 2",
    "1 enter 2 +",
    "1 enter 2 + 3",
    "1 enter 2 enter 3 + *",
    "1 enter 2 swap",
    "1 enter 2 drop",
    "1 enter drop",
    "1 enter 2 enter 3 rollin",
    "1 enter 2 enter 3 rollout",
    "1 enter enter",
    "5 x2",
    "1 enter 2 /",
    "1 enter 2 ^",
    "1 enter 2 C",
    "1 enter 2 AC",
    "1 enter 2 del",
    "1 2 del",
    "1 enter 2 neg",
    "1 enter 2 %",
    "pi",
    "1 enter 2 - 3 *",
    "2 enter 3 ^y",
    "1 0 0 enter 1 0 logy",
    "5 !",
    "1 enter 2 + neg",
    "4 1/x",
    "1 enter 0 /",
    "",
    "+",
    "enter",
    "1 + 2",
], format: 2)
for base in [CalculateExpression.Base.base16, .base10, .base8] {
    keys("programmer, base \(base.rawValue)", [
    "F F",
    "F F and 1 0",
    "F F not",
    "1 <<",
    "A <<y 4",
    "F F flipb",
    "F F flipw",
    "1 0 0 / 3",
    "5 mod 3",
    "F negp",
    "1 rol",
    "1 ror",
    "1 >>",
    "F F FF",
    "0 0",
    "1 2 3 4 5 6 7 8 9 A hB hC hD hE F 0 1",
    "F F neg",
    "( 1 + 2 ) * 3",
    "1 2 del",
    "1 + 2 C",
    "F F xor F 0",
    "F F or 1 0 0",
    "F F nor 0",
    "not",
    "not F F",
    "1 - 2",
    "0 - 1",
    "F F F F F F F F F F F F F F F F",
    "F F F F F F F F F F F F F F F F 1",
    "1 + not",
    "F F and not 0",
    ". ",
    "%",
    "sin",
    "2 >>y 1",
    "1 0 mod 0",
], base: base, engine: 1)
}

print("== text")
for s in [
    "100!",
    "120!",
    "150!",
    "170!",
    "69!",
    "70!",
    "1.0002",
    "1.00021",
    "0.000000123",
    "1/7",
    "22/7",
    "1000/7",
    "123456.789",
    "1234567.891",
    "12345678.9",
    "123456789.1",
    "1234567890.1",
    "12345678901.5",
    "1e11",
    "99999999999",
    "0.5",
    "-0.0004",
    "1+2*3",
    "2^10",
    "3!",
    "5%2",
    "2(3)",
    "(1+2)(3+4)",
    "2π",
    "sin(30)",
    "cos(0)",
    "log(100)",
    "ln(e)",
    "√16",
    "∛27",
    "10 km in mi",
    "3 ft in m",
    "32 f in c",
    "100 c to f",
    "1 kg in lb",
    "1 gallon in liters",
    "2 hours in minutes",
    "5 miles to km",
    "1 mi",
    "1,000+1",
    "1 000",
    "-5",
    "--5",
    "2^-1",
] {
    let e = CalculateExpression(s, options: [:], base: .base10, id: UUID())
    var thrown = "-"
    var r: CalculateResult?
    do { r = try evaluateError(s, options: [:]) } catch { thrown = code(error) }
    print("\(s) | [\(e.expression)] res=\(e.result?.formattedResult ?? "nil") err=\(code(e.error)) "
        + "triv=\(e.result?.isTrivial ?? false) | evaluate: \(r?.formattedResult ?? "nil") \(thrown) "
        + "units=\(r?.terms.first?.units.map(\.name) ?? [])")
}

print("== results")
let sum = CalculateExpression(options: [:], base: .base10, id: UUID())
for o in [Op.digit1, .add, .digit2] { sum.update(o) }
let next = CalculateExpression(result: sum.result, error: nil, options: [:], base: .base10, id: UUID())
print("init(result:) [\(next.expression)] clear=\(next.prefersClear)")
next.setRepeatableOperation(from: sum)
next.repeatOperation()
print("repeat [\(next.expression)] \(next.result?.formattedResult ?? "nil")")
next.repeatOperation()
print("repeat again [\(next.expression)]")
sum.inlineEvaluate()
print("inlineEvaluate [\(sum.expression)] clear=\(sum.prefersClear)")
let degrees = CalculateExpression("sin(90)", options: [.assumeDegrees: true], base: .base10, id: UUID())
print("degrees \(degrees.result?.formattedResult ?? "nil")")
let collection = CalculateUnitCollection(locales: [Locale(identifier: "en_US")])
for category in collection.categories where category.name != "Currency" {
    print("\(category.name) \(category.unitType) \(category.preferredFromUnit?.name ?? "-") \(category.preferredToUnit?.name ?? "-"): "
        + category.units.map { "\($0.name)/\($0.shortName)" }.sorted().joined(separator: ", "))
}

// SPDX-License-Identifier: MIT OR Apache-2.0
// Measurement.FormatStyle: use Finch's ICU-backed MeasurementFormatter for
// locale rules, unit conversion and localized unit names.

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif
internal import Foundation_Private

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public struct MeasurementFormatUnitUsage<UnitType: Dimension>: Codable, Hashable, Sendable {
    fileprivate var identifier: String?
    fileprivate var usesProvidedUnit: Bool

    private init(_ identifier: String?, usesProvidedUnit: Bool = false) {
        self.identifier = identifier
        self.usesProvidedUnit = usesProvidedUnit
    }

    public static var general: Self { Self(nil) }
    public static var asProvided: Self { Self(nil, usesProvidedUnit: true) }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitTemperature {
    public static var weather: Self { Self("weather") }
    public static var person: Self { Self("person") }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitLength {
    public static var person: Self { Self("person") }
    public static var road: Self { Self("road") }
    public static var personHeight: Self { Self("person-height") }
}

@available(macOS 14.0, iOS 16.0, tvOS 17.0, watchOS 9.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitLength {
    public static var visibility: Self { Self("visiblty") }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitLength {
    public static var focalLength: Self { Self("focal-length") }
    public static var rainfall: Self { Self("rainfall") }
    public static var snowfall: Self { Self("snowfall") }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitEnergy {
    public static var food: Self { Self("food") }
    public static var workout: Self { Self("workout") }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitMass {
    public static var personWeight: Self { Self("person") }
}

@available(macOS 14.0, iOS 16.0, tvOS 17.0, watchOS 9.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitSpeed {
    public static var wind: Self { Self("wind") }
}

@available(macOS 14.0, iOS 16.0, tvOS 17.0, watchOS 9.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitPressure {
    public static var barometric: Self { Self("baromtrc") }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension MeasurementFormatUnitUsage where UnitType == UnitVolume {
    public static var liquid: Self { Self("fluid") }
}

private func _measurementNumberPrefix(in text: String, locale: Locale) -> (end: String.Index, value: Double)? {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    let separators = [formatter.decimalSeparator ?? ".", formatter.groupingSeparator ?? ",",
                      formatter.plusSign ?? "+", formatter.minusSign ?? "-", "−", "e", "E",
                      "\u{200e}", "\u{200f}"]
    var numberCharacters = CharacterSet.decimalDigits
    for separator in separators {
        numberCharacters.formUnion(CharacterSet(charactersIn: separator))
    }
    var end = text.startIndex
    while end < text.endIndex,
          text[end].unicodeScalars.allSatisfy({ numberCharacters.contains($0) }) {
        end = text.index(after: end)
    }
    guard end > text.startIndex,
          let value = formatter.number(from: String(text[..<end]))?.doubleValue else { return nil }
    return (end, value)
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension Measurement where UnitType: Dimension {
    @dynamicMemberLookup
    public struct AttributedStyle: Foundation.FormatStyle, Codable, Hashable, Sendable {
        fileprivate var innerStyle: FormatStyle

        fileprivate init(innerStyle: FormatStyle) { self.innerStyle = innerStyle }

        public func format(_ measurement: Measurement<UnitType>) -> AttributedString {
            let text = innerStyle.format(measurement)
            var result = AttributedString(text)
            guard let numberPrefix = _measurementNumberPrefix(in: text, locale: innerStyle.locale) else { return result }
            let numberFormatter = NumberFormatter()
            numberFormatter.locale = innerStyle.locale
            let decimalSeparator = numberFormatter.decimalSeparator ?? "."
            let groupingSeparator = numberFormatter.groupingSeparator ?? ","
            let plusSign = numberFormatter.plusSign ?? "+"
            let minusSign = numberFormatter.minusSign ?? "-"
            let numberEnd = numberPrefix.end
            var numberPart: AttributeScopes.FoundationAttributes.NumberFormatAttributes.NumberPartAttribute.NumberPart = .integer
            var numberIndex = text.startIndex
            while numberIndex < numberEnd {
                let next = text.index(after: numberIndex)
                if let range = Range<AttributedString.Index>(numberIndex..<next, in: result) {
                    result[range].measurement = .value
                    let character = String(text[numberIndex])
                    if character == decimalSeparator {
                        numberPart = .fraction
                        result[range].numberSymbol = .decimalSeparator
                    } else if character == groupingSeparator {
                        result[range].numberSymbol = .groupingSeparator
                    } else if character == plusSign || character == minusSign || character == "−" {
                        result[range].numberSymbol = .sign
                    } else if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                        result[range].numberPart = numberPart
                    }
                }
                numberIndex = next
            }

            var unitStart = numberEnd
            while unitStart < text.endIndex && text[unitStart].isWhitespace {
                unitStart = text.index(after: unitStart)
            }
            if unitStart < text.endIndex,
               let range = Range<AttributedString.Index>(unitStart..<text.endIndex, in: result) {
                result[range].measurement = .unit
            }
            return result
        }

        public func locale(_ locale: Locale) -> Self {
            Self(innerStyle: innerStyle.locale(locale))
        }

        public typealias FormatInput = Measurement<UnitType>
        public typealias FormatOutput = AttributedString
    }

    public struct FormatStyle: Foundation.FormatStyle, Codable, Hashable, Sendable {
        public struct UnitWidth: Codable, Hashable, Sendable {
            public static var wide: Self { Self(option: .wide) }
            public static var abbreviated: Self { Self(option: .abbreviated) }
            public static var narrow: Self { Self(option: .narrow) }

            enum Option: Int, Codable, Hashable, Sendable {
                case wide
                case abbreviated
                case narrow
            }

            var option: Option
            var skeleton: String {
                switch option {
                case .wide: return "unit-width-full-name"
                case .abbreviated: return "unit-width-short"
                case .narrow: return "unit-width-narrow"
                }
            }
        }

        public var width: UnitWidth
        public var locale: Locale
        public var numberFormatStyle: FloatingPointFormatStyle<Double>?
        public var usage: MeasurementFormatUnitUsage<UnitType>?
        fileprivate var hidesScaleNameOption: Bool

        public init(width: UnitWidth, locale: Locale = .autoupdatingCurrent,
                    usage: MeasurementFormatUnitUsage<UnitType> = .general,
                    numberFormatStyle: FloatingPointFormatStyle<Double>? = nil) {
            self.width = width
            self.locale = locale
            self.usage = usage
            self.numberFormatStyle = numberFormatStyle
            hidesScaleNameOption = false
        }

        public func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        public var attributed: AttributedStyle { AttributedStyle(innerStyle: self) }

        public func format(_ measurement: Measurement<UnitType>) -> String {
            let formatter = MeasurementFormatter()
            formatter.locale = locale
            formatter._setFinchAllowsMultipleUnits(true)
            switch width.option {
            case .wide: formatter.unitStyle = .long
            case .abbreviated: formatter.unitStyle = .medium
            case .narrow: formatter.unitStyle = .short
            }

            formatter.unitOptions = .naturalScale
            if let usage {
                if usage.usesProvidedUnit {
                    formatter.unitOptions = .providedUnit
                } else if let identifier = usage.identifier {
                    formatter._setFinchUsageOverride(identifier)
                    if identifier == "person-height" {
                        var numberFormatter = formatter.numberFormatter ?? NumberFormatter()
                        numberFormatter.maximumFractionDigits = 1
                        formatter.numberFormatter = numberFormatter
                    }
                }
            }
            if hidesScaleNameOption {
                formatter.unitOptions = formatter.unitOptions.union(.temperatureWithoutUnit)
            }

            let output = formatter.string(from: measurement)
            guard let numberFormatStyle else { return output }
            guard let numberPrefix = _measurementNumberPrefix(in: output, locale: locale) else { return output }
            return numberFormatStyle.format(numberPrefix.value) + String(output[numberPrefix.end...])
        }

        public typealias FormatInput = Measurement<UnitType>
        public typealias FormatOutput = String
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension Measurement.FormatStyle where UnitType == UnitTemperature {
    public var hidesScaleName: Bool {
        get { hidesScaleNameOption }
        set { hidesScaleNameOption = newValue }
    }

    public init(width: UnitWidth = .abbreviated, locale: Locale = .autoupdatingCurrent,
                usage: MeasurementFormatUnitUsage<UnitType> = .general, hidesScaleName: Bool = false,
                numberFormatStyle: FloatingPointFormatStyle<Double>? = nil) {
        self.init(width: width, locale: locale, usage: usage, numberFormatStyle: numberFormatStyle)
        self.hidesScaleName = hidesScaleName
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
extension Measurement.AttributedStyle {
    public subscript<T>(dynamicMember keyPath: KeyPath<Measurement<UnitType>.FormatStyle, T>) -> T {
        innerStyle[keyPath: keyPath]
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Measurement<UnitType>.FormatStyle, T>) -> T {
        get { innerStyle[keyPath: keyPath] }
        set { innerStyle[keyPath: keyPath] = newValue }
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension Measurement where UnitType: Dimension {
    public func formatted<S>(_ style: S) -> S.FormatOutput
    where S: Foundation.FormatStyle, S.FormatInput == Measurement<UnitType> {
        style.format(self)
    }

    public func formatted() -> String {
        FormatStyle(width: .abbreviated).format(self)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension FormatStyle {
    public static func measurement<UnitType>(width: Measurement<UnitType>.FormatStyle.UnitWidth,
                                             usage: MeasurementFormatUnitUsage<UnitType> = .general,
                                             numberFormatStyle: FloatingPointFormatStyle<Double>? = nil) -> Self
    where Self == Measurement<UnitType>.FormatStyle, UnitType: Dimension {
        Measurement<UnitType>.FormatStyle(width: width, usage: usage, numberFormatStyle: numberFormatStyle)
    }

    public static func measurement(width: Measurement<UnitTemperature>.FormatStyle.UnitWidth = .abbreviated,
                                   usage: MeasurementFormatUnitUsage<UnitTemperature> = .general,
                                   hidesScaleName: Bool = false,
                                   numberFormatStyle: FloatingPointFormatStyle<Double>? = nil) -> Self
    where Self == Measurement<UnitTemperature>.FormatStyle {
        Measurement<UnitTemperature>.FormatStyle(width: width, usage: usage, hidesScaleName: hidesScaleName,
                                                 numberFormatStyle: numberFormatStyle)
    }
}

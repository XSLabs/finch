// SPDX-License-Identifier: MIT OR Apache-2.0
// AttributedString(markdown:) and the Objective-C constructors share Finch's
// Foundation Markdown parser and therefore produce the same attributes.

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributedString {
    public struct MarkdownParsingOptions: Sendable {
        public enum FailurePolicy: Int, Sendable {
            case throwError
            case returnPartiallyParsedIfPossible
        }
        public enum InterpretedSyntax: Int, Sendable {
            case full
            case inlineOnly
            case inlineOnlyPreservingWhitespace
        }
        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy
        public var languageCode: String?
        fileprivate var _appliesSourcePositionAttributes = false
        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        public var appliesSourcePositionAttributes: Bool {
            get { _appliesSourcePositionAttributes }
            set { _appliesSourcePositionAttributes = newValue }
        }

        public init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
                    failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
            self.languageCode = languageCode
        }

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        public init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
                    failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil,
                    appliesSourcePositionAttributes: Bool = false) {
            self.init(allowsExtendedAttributes: allowsExtendedAttributes, interpretedSyntax: interpretedSyntax,
                      failurePolicy: failurePolicy, languageCode: languageCode)
            self._appliesSourcePositionAttributes = appliesSourcePositionAttributes
        }
    }

    public init<S: AttributeScope>(markdown: String, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init(markdown: String, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: String, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: Data, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init(markdown: Data, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: Data, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(contentsOf url: URL, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
    public init(contentsOf url: URL, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
    public init<S: AttributeScope>(contentsOf url: URL, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension InlinePresentationIntent: Hashable, Codable {}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension NSAttributedString {
    public convenience init(markdown: String, options: AttributedString.MarkdownParsingOptions = .init(),
                            baseURL: URL? = nil) throws {
        var error: NSError?
        let parsed = _finchAttributedStringFromMarkdownString(
            markdown as NSString, Int(options.interpretedSyntax.rawValue), Int(options.failurePolicy.rawValue),
            options.allowsExtendedAttributes, options.languageCode as NSString?,
            options._appliesSourcePositionAttributes, baseURL as NSURL?, &error
        )?.takeRetainedValue()
        guard let parsed else {
            throw error ?? CocoaError(.fileReadUnknown)
        }
        self.init(attributedString: parsed)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
internal enum _FinchMarkdown {
    static func text(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    static func parse(_ source: String, options: AttributedString.MarkdownParsingOptions,
                      baseURL: URL?) throws -> AttributedString {
        var error: NSError?
        let parsed = _finchAttributedStringFromMarkdownString(
            source as NSString, Int(options.interpretedSyntax.rawValue), Int(options.failurePolicy.rawValue),
            options.allowsExtendedAttributes, options.languageCode as NSString?,
            options._appliesSourcePositionAttributes, baseURL as NSURL?, &error
        )?.takeRetainedValue()
        guard let parsed else {
            throw error ?? CocoaError(.fileReadUnknown)
        }
        return attributedString(from: parsed)
    }

    private static func attributedString(from source: NSAttributedString) -> AttributedString {
        var result = AttributedString(source)
        guard source.length > 0 else { return result }

        let presentationKey = NSAttributedString.Key(rawValue: "NSPresentationIntent")
        source.enumerateAttribute(presentationKey, in: NSRange(location: 0, length: source.length), options: []) {
            value, range, _ in
            guard let value = value as? __NSPresentationIntent,
                  let target = Range(range, in: result) else { return }
            result[target].presentationIntent = presentationIntent(from: value)
        }

        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            let sourcePositionKey = NSAttributedString.Key(rawValue: "NSMarkdownSourcePosition")
            source.enumerateAttribute(sourcePositionKey, in: NSRange(location: 0, length: source.length), options: []) {
                value, range, _ in
                guard let value = value as? __NSAttributedStringMarkdownSourcePosition,
                      let target = Range(range, in: result) else { return }
                result[target].markdownSourcePosition = AttributedString.MarkdownSourcePosition(
                    startLine: Int(value.startLine), startColumn: Int(value.startColumn),
                    endLine: Int(value.endLine), endColumn: Int(value.endColumn)
                )
            }
        }
        return result
    }

    private static func presentationIntent(from source: __NSPresentationIntent) -> PresentationIntent {
        var components: [PresentationIntent.IntentType] = []
        var intent: __NSPresentationIntent? = source
        while let current = intent {
            components.append(PresentationIntent.IntentType(kind: presentationKind(current),
                                                            identity: Int(current.identity)))
            intent = current.parent
        }
        return PresentationIntent(types: components)
    }

    private static func presentationKind(_ intent: __NSPresentationIntent) -> PresentationIntent.Kind {
        switch intent.intentKind.rawValue {
        case 0: return .paragraph
        case 1: return .header(level: Int(intent.headerLevel))
        case 2: return .orderedList
        case 3: return .unorderedList
        case 4: return .listItem(ordinal: Int(intent.ordinal))
        case 5: return .codeBlock(languageHint: intent.languageHint)
        case 6: return .blockQuote
        case 7: return .thematicBreak
        case 8:
            let values = intent.columnAlignments ?? []
            let count = max(Int(intent.columnCount), values.count)
            let columns = (0..<count).map { index in
                let alignment = index < values.count ? values[index].intValue : 0
                return PresentationIntent.TableColumn(
                    alignment: PresentationIntent.TableColumn.Alignment(rawValue: alignment) ?? .left
                )
            }
            return .table(columns: columns)
        case 9: return .tableHeaderRow
        case 10: return .tableRow(rowIndex: Int(intent.row))
        case 11: return .tableCell(columnIndex: Int(intent.column))
        default: return .paragraph
        }
    }
}

@_silgen_name("_FinchAttributedStringFromMarkdownString")
private func _finchAttributedStringFromMarkdownString(
    _ markdown: NSString, _ interpretedSyntax: Int, _ failurePolicy: Int,
    _ allowsExtendedAttributes: Bool, _ languageCode: NSString?,
    _ appliesSourcePositionAttributes: Bool, _ baseURL: NSURL?,
    _ error: UnsafeMutablePointer<NSError?>
) -> Unmanaged<NSAttributedString>?

/// Inline Markdown for Foundation's Objective-C NSBundle localization bridge.
/// The result is retained for the C caller.
@_cdecl("_FinchAttributedStringFromInlineMarkdown")
func _FinchAttributedStringFromInlineMarkdown(_ string: NSString) -> Unmanaged<NSAttributedString>? {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: string as String, options: options) else { return nil }
    return Unmanaged.passRetained(NSAttributedString(parsed))
}

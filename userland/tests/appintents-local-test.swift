// SPDX-License-Identifier: MIT OR Apache-2.0
// The SDK hides several AppIntents view helpers, so build this comparison against Finch's
// interface and run the same binary once with Apple and once with Finch's frameworks.

import AppIntents
import AppKit
import _AppIntents_AppKit
import Darwin

struct LocalEntity: AppEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "record" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Record \(id)", subtitle: "Local",
            image: DisplayRepresentation.Image(systemName: "circle", tintColor: nil, symbolConfiguration: nil)
        )
    }
    static var defaultQuery = LocalEntityQuery()
}

struct LocalEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LocalEntity] {
        identifiers.map(LocalEntity.init(id:))
    }

    func suggestedEntities() async throws -> [LocalEntity] {
        [LocalEntity(id: "one")]
    }
}

struct AssistantMetadataIntent: AppIntent {
    static var title: LocalizedStringResource { "Metadata" }
    @Parameter var message: String

    func perform() async throws -> some IntentResult { .result() }
}

struct PlaybackMarkerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Playback marker" }

    func perform() async throws -> some IntentResult { .result() }
}

struct AssistantMetadata: _AssistantIntentsProvider {
    static var intents: [_AssistantIntent] {
        let phrase: _AssistantIntent.Phrase<AssistantMetadataIntent> =
            "Repeat \(.applicationName) \(\.$message)"
        _AssistantIntent(
            AssistantMetadataIntent(),
            phrases: { _ in phrase },
            parameterValues: { _ in
                _AssistantIntent.Value(for: \AssistantMetadataIntent.message) { "hello" }
            }
        )
    }

    static var negativePhrases: [_AssistantIntent.NegativeAssistantIntentPhrases] {
        _AssistantIntent.NegativeAssistantIntentPhrases(for: AssistantMetadataIntent.self) {
            "skip this"
        }
    }
}

@main
struct AppIntentsLocalTest {
    static func main() async throws {
        var info = Dl_info()
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s10AppIntents16EntityIdentifierVMn")
        dladdr(symbol, &info)
        print(info.dli_fname.map { String(cString: $0) } ?? "?")

        let entity = LocalEntity(id: "one")
        let text = await entity.displayRepresentation(with: .text)
        let representations = try await LocalEntity.defaultQuery.displayRepresentations(
            for: ["two", "one"], requestedComponents: .text
        )
        print("display", text.title.key, text.subtitle?.key ?? "-", text.image == nil)
        print("query", representations["two"]?.title.key ?? "-", representations["one"]?.title.key ?? "-")

        let state: AppEntityVisualState = [.selected, .focused]
        print("visual", AppEntityVisualState.selected.rawValue, AppEntityVisualState.focused.rawValue, state.rawValue)

        let bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
        let context = AppEntityUIElementsContext(
            bounds: bounds,
            requests: [.selected]
        )
        let element = AppEntityUIElement(
            entity, bounds: bounds, state: .selected, subelements: []
        )
        print("ui", context.queryRect.origin.x, context.queryRect.origin.y, context.queryRect.width,
              context._includeAllSelectedUIElements, element.identifier.identifier, element.state.isSelected)

        let view = NSView(frame: bounds)
        view.appEntityIdentifier = EntityIdentifier(for: entity)
        print("view-id", view.appEntityIdentifier?.identifier ?? "-")
        view.annotate(with: AppEntityViewAnnotation(entity: entity, state: .selected))
        view.updateAppEntityAnnotation(with: .focused)
        view.appEntityUIElementProvider = { _, context in
            [AppEntityUIElement(entity, bounds: context.queryRect, state: .selected, subelements: [])]
        }
        let provided = view.appEntityUIElementProvider?(view, context) ?? []
        print("view", view.appEntityIdentifier?.identifier ?? "-", provided.count,
              provided.first?.bounds.width ?? 0)

        let image = DisplayRepresentation.Image(systemName: "circle", tintColor: nil, symbolConfiguration: nil)
        print("symbol", image == nil ? "missing" : "present")

        let visualState = AppEntityVisualState(
            isSelected: true, isHighlighted: false, isFocused: true,
            isDisabled: false, isEditing: false, isPrimary: true
        )
        print("visual-init", visualState.rawValue)
        print("assistant-metadata", AssistantMetadata.intents.count,
              AssistantMetadata.negativePhrases.count, AssistantMetadata.uniqueEntities.count)
        let systemContext = AssistantMetadataIntent().systemContext
        print("assistant-context", systemContext.source == nil, systemContext.kind == nil, systemContext.preciseTimestamp == nil)

        let legacyResult: IntentResultContainer<String, Never, Never, Never> =
            .result(value: "finished", opensIntent: AssistantMetadataIntent())
        print("legacy-result", legacyResult.value ?? "-")

        let file = IntentFile(data: Data([65]), filename: "note.txt")
        let fileParameter = IntentParameter<IntentFile>(
            title: "File", default: file, supportedContentTypes: [.plainText]
        )
        print("file-parameter", fileParameter.title.key, fileParameter.defaultValue?.filename ?? "-",
              fileParameter.isOptional)

        let searchParameter = IntentParameter<StringSearchCriteria>(title: "Search")
        print("search-parameter", searchParameter.title.key, searchParameter.defaultValue == nil)

        print("audio-marker", PlaybackMarkerIntent.title.key, PlaybackMarkerIntent.openAppWhenRun)

        let urlText: any CustomURLRepresentationParameterConvertible = "a song"
        let urlNumber: any CustomURLRepresentationParameterConvertible = 42
        let urlValue: any CustomURLRepresentationParameterConvertible = URL(string: "https://example.com/item")!
        print("url-values", await urlText.urlRepresentationParameter ?? "-",
              await urlNumber.urlRepresentationParameter ?? "-",
              await urlValue.urlRepresentationParameter ?? "-")

    }
}

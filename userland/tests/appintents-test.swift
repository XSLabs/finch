// SPDX-License-Identifier: MIT OR Apache-2.0
// AppIntents metadata, a local entity query, and an intent run without a system service.

import AppIntents
import Darwin
import Foundation
import UniformTypeIdentifiers

struct LocalDependency: Sendable {
    let value: String
}

struct LocalDependencyReader: _SupportsAppDependencies {
    @AppDependency(key: "appintents-test") var dependency: LocalDependency
}

struct LocalRecord: IndexedEntity, AssistantEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "record" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Record \(id)") }
    static var defaultQuery = LocalRecordQuery()
}

struct LocalRecordQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LocalRecord] {
        identifiers.map(LocalRecord.init(id:))
    }

    func suggestedEntities() async throws -> [LocalRecord] {
        [LocalRecord(id: "one"), LocalRecord(id: "two")]
    }
}

struct LocalRecordOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [LocalRecord] { [LocalRecord(id: "provided")] }
}

struct DefaultRecord: AppEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "default record" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id)) }
    static var defaultQuery = DefaultRecordQuery()
}

struct DefaultRecordQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DefaultRecord] {
        identifiers.map(DefaultRecord.init(id:))
    }
}

struct RepeatIntent: AssistantIntent {
    static var title: LocalizedStringResource { "Repeat" }
    @Parameter(title: "Message", default: "hello") var message: String
    @Parameter(title: "Record", default: LocalRecord(id: "one")) var record: LocalRecord
    @Parameter(title: "Enabled", default: true, displayName: .init(true: "On", false: "Off")) var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        IntentParameterSummary<RepeatIntent>("Repeat \(\.$message)")
    }

    func perform() async throws -> some IntentResult {
        .result(value: message.uppercased())
    }
}

struct SummaryIntent: AppIntent {
    static var title: LocalizedStringResource { "Summary" }
    @Parameter var value: String

    static var parameterSummary: some ParameterSummary {
        Switch(\.$value) {
            Case("first") { Summary("First value") }
            Case(["second", "third"]) { Summary("Other values") }
            DefaultCase { Summary("Any value") }
        }
    }

    func perform() async throws -> some IntentResult { .result() }
}

struct ConditionalSummaryIntent: AppIntent {
    static var title: LocalizedStringResource { "Conditional summary" }
    @Parameter var value: String

    static var parameterSummary: some ParameterSummary {
        When(\.$value, .hasAnyValue) {
            Summary("Has a value")
        } otherwise: {
            Summary("Has no value")
        }
    }

    func perform() async throws -> some IntentResult { .result() }
}

enum LocalMode: String, AssistantSchemaEnum {
    case compact

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "mode" }
    static var caseDisplayRepresentations: [LocalMode: DisplayRepresentation] { [.compact: "Compact"] }
}

struct LocalSchemaIntent: AssistantSchemaIntent {
    func perform() async throws -> some IntentResult { .result() }
}

struct LocalSchemaEntity: AssistantSchemaEntity {
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id))
    }
    static var defaultQuery = LocalSchemaEntityQuery()
}

struct LocalSchemaEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LocalSchemaEntity] {
        identifiers.map(LocalSchemaEntity.init(id:))
    }

    func suggestedEntities() async throws -> [LocalSchemaEntity] { [] }
}

struct URLRecordEntity: URLRepresentableEntity {
    let id: String
    @EntityProperty(title: "Slug") var slug: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "URL record" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "URL record") }
    static var defaultQuery = URLRecordEntityQuery()
    static var urlRepresentation: URLRepresentation {
        "https://example.com/item/\(\.$slug)"
    }

    init(id: String, slug: String) {
        self.id = id
        _slug = EntityProperty(title: "Slug")
        _slug.wrappedValue = slug
    }
}

struct URLRecordEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [URLRecordEntity] {
        identifiers.map { URLRecordEntity(id: $0, slug: $0) }
    }
}

struct URLPageIntent: AppIntent, URLRepresentableIntent {
    static var title: LocalizedStringResource { "URL page" }
    @Parameter var page: String

    static var urlRepresentation: URLRepresentation {
        "https://example.com/page/\(\.$page)"
    }

    func perform() async throws -> some IntentResult { .result() }
}

struct OpenURLRecordIntent: OpenIntent, URLRepresentableIntent {
    static var title: LocalizedStringResource { "Open URL record" }
    var target = URLRecordEntity(id: "open", slug: "hello world")
}

struct LocalFileEntity: FileEntity {
    let id: FileEntityIdentifier

    static var supportedContentTypes: [UTType] { [.plainText] }
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "file" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Local file") }
    static var defaultQuery = LocalFileEntityQuery()
}

struct LocalFileEntityQuery: EntityQuery {
    func entities(for identifiers: [FileEntityIdentifier]) async throws -> [LocalFileEntity] { [] }
}

struct PropertyQueryRecord: AppEntity {
    let id: String
    @EntityProperty(title: "Name") var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Query record" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Query record") }
    static var defaultQuery = PropertyQueryRecordQuery()

    init(id: String, name: String) {
        self.id = id
        _name = EntityProperty(title: "Name")
        _name.wrappedValue = name
    }
}

enum PropertyQueryComparator: Equatable {
    case nameContains(String)
    case nameEquals(String)
}

struct PropertyQueryRecordQuery: EntityPropertyQuery {
    static let records = [
        PropertyQueryRecord(id: "one", name: "first record"),
        PropertyQueryRecord(id: "two", name: "second record")
    ]

    static var properties: QueryProperties {
        QueryProperties {
            Property(\.$name) {
                ContainsComparator(mappingTransform: PropertyQueryComparator.nameContains)
                EqualToComparator(mappingTransform: PropertyQueryComparator.nameEquals)
            }
        }
    }

    static var sortingOptions: SortingOptions {
        SortingOptions {
            SortableBy(\.$name)
        }
    }

    func entities(for identifiers: [String]) async throws -> [PropertyQueryRecord] {
        Self.records.filter { identifiers.contains($0.id) }
    }

    func entities(matching comparators: [PropertyQueryComparator], mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<PropertyQueryRecord>], limit: Int?) async throws -> [PropertyQueryRecord] {
        _ = sortedBy
        let matches: (PropertyQueryRecord) -> Bool = { record in
            let results = comparators.map { comparator in
                switch comparator {
                case .nameContains(let fragment): record.name.localizedCaseInsensitiveContains(fragment)
                case .nameEquals(let name): record.name == name
                }
            }
            return mode == .and ? results.allSatisfy { $0 } : results.contains { $0 }
        }
        let found = Self.records.filter(matches)
        return limit.map { Array(found.prefix(max(0, $0))) } ?? found
    }
}

struct DeleteLocalRecordsIntent: DeleteIntent {
    static var title: LocalizedStringResource { "Delete Records" }
    let entities: [LocalRecord]

    init() { entities = [LocalRecord(id: "one"), LocalRecord(id: "two")] }

    func perform() async throws -> some IntentResult {
        .result(value: entities.map(\.id).joined(separator: ","))
    }
}

struct OpenLocalRecordIntent: OpenIntent {
    static var title: LocalizedStringResource { "Open record" }
    var target = LocalRecord(id: "one")
}

struct SearchIntent: ShowInAppSearchResultsIntent {
    static var title: LocalizedStringResource { "Search" }
    static var searchScopes: [StringSearchScope] { [.general, .movies] }
    var criteria = StringSearchCriteria(term: "books")

    func perform() async throws -> some IntentResult {
        .result(value: criteria.term)
    }
}

struct LocalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RepeatIntent(), phrases: ["Repeat a message"], shortTitle: "Repeat", systemImageName: "quote.bubble")
    }
}

struct LocalOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] { ["first", "second"] }
}

@main
struct AppIntentsTest {
    static func main() async throws {
        setbuf(stdout, nil)
        var info = Dl_info()
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s10AppIntents21IntentResultContainerVMn")
        dladdr(symbol, &info)
        print(info.dli_fname.map { String(cString: $0) } ?? "?")

        print("intent", RepeatIntent.title.key, RepeatIntent.persistentIdentifier, RepeatIntent.openAppWhenRun)
        let person = IntentPerson(
            identifier: .contact("person-1"), name: .displayName("Ada Lovelace"),
            handle: IntentPerson.Handle(emailAddress: "ada@example.com", label: .work),
            aliases: [IntentPerson.Handle(phoneNumber: "555-0100", label: .mobile)], isMe: true
        )
        let personData = try JSONEncoder().encode(person)
        let personCopy = try JSONDecoder().decode(IntentPerson.self, from: personData)
        print("person", person.displayRepresentation.title.key, person.identifier == .contact("person-1"),
              person.handle?.value == .emailAddress("ada@example.com"), person.aliases.count,
              person.isMe, personCopy == person)
        let personFromHandle = IntentPerson(handle: IntentPerson.Handle(applicationDefined: "contact-token", label: "CRM"))
        print("person-handle", personFromHandle.name == .unknown, personFromHandle.identifier == .unknown,
              personFromHandle.displayRepresentation.title.key)
        let foregroundModes: [IntentModes] = [
            .foreground(.immediate), .foreground(.dynamic), .foreground(.deferred)
        ]
        print("foreground-modes", foregroundModes.map(\.rawValue).map(String.init).joined(separator: ","))
        print("summary", String(reflecting: SummaryIntent.parameterSummary))
        print("conditionalSummary", String(reflecting: ConditionalSummaryIntent.parameterSummary))
        print("assistant", LocalRecord.typeDisplayRepresentation.name.key, LocalMode.compact.rawValue,
              LocalMode.isAssistantOnly, LocalSchemaIntent.title.key, LocalSchemaIntent.isAssistantOnly,
              LocalSchemaEntity.typeDisplayRepresentation.name.key, LocalSchemaEntity.isAssistantOnly)
        print("parameter", RepeatIntent().$message.title.key, RepeatIntent().$message.defaultValue ?? "-",
              RepeatIntent().$message.isOptional)
        print("entityParameter", RepeatIntent().$record.title.key, RepeatIntent().$record.defaultValue?.id ?? "-",
              RepeatIntent().$record.isOptional)
        let entityQueryParameter = IntentParameter<LocalRecord>(title: "Query record", query: LocalRecordQuery())
        let entityOptionsParameter = IntentParameter<LocalRecord>(
            title: "Option record", optionsProvider: LocalRecordOptionsProvider()
        )
        print("entity-parameter-sources", entityQueryParameter.title.key, entityOptionsParameter.title.key)
        let displayName = RepeatIntent().$enabled.displayName
        print("boolParameter", RepeatIntent().$enabled.defaultValue ?? false,
              displayName?.true.key ?? "-", displayName?.false.key ?? "-")
        print("entity", LocalRecord.typeDisplayRepresentation.name.key, LocalRecord(id: "one").displayRepresentation.title.key)
        let found = try await LocalRecord.defaultQuery.entities(for: ["b", "a"])
        let suggestions = try await LocalRecord.defaultQuery.suggestedEntities()
        print("query", found.map(\.id).joined(separator: ","), suggestions.map(\.id).joined(separator: ","))
        let defaultSuggestions = try await DefaultRecordQuery().suggestedEntities()
        print("query-default", defaultSuggestions.count)
        let collection = [LocalRecord(id: "one")]
        print("collection", collection.items.map(\.id).joined(separator: ","),
              collection.promptLabel?.key ?? "-", collection.usesIndexedCollation, [LocalRecord].empty.count)
        print("indexed", LocalRecord(id: "one").hideInSpotlight,
              LocalRecord(id: "one").defaultAttributeSet.title ?? "-")
        print("shortcuts", LocalShortcuts.appShortcuts.count, LocalShortcuts.shortcutTileColor)
        let optionsCollection = AppShortcutOptionsCollection(
            LocalOptionsProvider(), title: "Words", systemImageName: "text.alignleft"
        )
        print("shortcut-options", optionsCollection.title.key, optionsCollection.systemImageName ?? "-",
              try await optionsCollection.dynamicOptionsProvider.results().joined(separator: ","))
        let shortcutPhrase: AppShortcutPhrase<RepeatIntent> = "Repeat \(.applicationName) \(\.$message)"
        let phraseFields = Mirror(reflecting: shortcutPhrase).children
        print("phrase", phraseFields.compactMap(\.label).joined(separator: ","),
              phraseFields.compactMap { $0.value as? String }.first ?? "-")

        print("search", SearchIntent.searchScopes.map(\.rawValue).joined(separator: ","),
              SearchIntent.openAppWhenRun, SearchIntent().criteria.term)
        let searchResult = try await SearchIntent().perform()
        print("searchPerform", searchResult.value ?? "-")
        let deleteResult = try await DeleteLocalRecordsIntent().perform()
        print("delete", DeleteLocalRecordsIntent().entities.map(\.id).joined(separator: ","), deleteResult.value ?? "-")
        print("open-intent", OpenLocalRecordIntent.openAppWhenRun, OpenLocalRecordIntent().target.id)

        let intent = RepeatIntent()
        intent.$message.wrappedValue = "Finch"
        let result = try await intent.perform()
        print("perform", result.value ?? "-")
        let context = intent.systemContext
        print("system-context", context.preciseTimestamp == nil)
        let followup: IntentResultContainer<String, RepeatIntent, Never, Never> =
            .result(value: "follow up", opensIntent: RepeatIntent())
        print("result-followup", followup.value ?? "-", followup.opensIntent?.message ?? "-")
        let resultWithDialog: IntentResultContainer<String, Never, Never, IntentDialog> =
            .result(value: "completed", dialog: "Finished")
        print("result-dialog", resultWithDialog.value ?? "-", resultWithDialog.dialog != nil)
        print("confirmation", ConfirmationConditions.lowConfidenceSource.rawValue,
              ConfirmationConditions(rawValue: 1).contains(.lowConfidenceSource),
              type(of: ConfirmationActionName.continue) == ConfirmationActionName.self)

        AppDependencyManager.shared.add(key: "appintents-test", dependency: LocalDependency(value: "ready"))
        let dependencyReader = LocalDependencyReader()
        dependencyReader.dependency = LocalDependency(value: "ready")
        print("dependency", dependencyReader.dependency.value)

        let property = EntityProperty<String>(title: "Name")
        property.wrappedValue = "Finch"
        print("property", property.title.key, property.wrappedValue, property.isOptional)

        let linkedRecord = EntityProperty<LocalRecord>(title: "Linked record")
        linkedRecord.wrappedValue = LocalRecord(id: "linked")
        let unnamedLinkedRecord = EntityProperty<LocalRecord>()
        unnamedLinkedRecord.wrappedValue = LocalRecord(id: "unnamed")
        print("entity-property", linkedRecord.title.key, linkedRecord.wrappedValue.id,
              unnamedLinkedRecord.title.key, unnamedLinkedRecord.wrappedValue.id)

        let file = IntentFile(data: Data([65, 66]), filename: "note.txt")
        let fileProperty = EntityProperty<IntentFile>(title: "Attachment")
        fileProperty.wrappedValue = file
        let unnamedFileProperty = EntityProperty<IntentFile>()
        unnamedFileProperty.wrappedValue = file
        print("file-property", fileProperty.title.key, fileProperty.wrappedValue.filename,
              unnamedFileProperty.title.key, unnamedFileProperty.wrappedValue.filename)

        let richText = AttributedString("Rich text")
        let richProperty = EntityProperty<AttributedString>(title: "Details")
        richProperty.wrappedValue = richText
        let unnamedRichProperty = EntityProperty<AttributedString>()
        unnamedRichProperty.wrappedValue = richText
        print("attributed-property", richProperty.title.key, String(richProperty.wrappedValue.characters),
              unnamedRichProperty.title.key, String(unnamedRichProperty.wrappedValue.characters))
        print("file", file.filename, file.data.count, file.type?.identifier ?? "-")

        let fileIdentifier = try FileEntityIdentifier.file(url: URL(fileURLWithPath: "/tmp/finch-appintents-file.txt"))
        print("file-entity-identifier", fileIdentifier.entityIdentifierString, fileIdentifier.isDraft,
              fileIdentifier.draftIdentifier ?? "-",
              try await fileIdentifier.fileURL?.absoluteString ?? "-")
        let draftIdentifier = FileEntityIdentifier.draft(identifier: "draft-1")
        let draftRoundTrip = FileEntityIdentifier.entityIdentifier(for: draftIdentifier.entityIdentifierString)
        print("draft-entity-identifier", draftIdentifier.entityIdentifierString, draftIdentifier.isDraft,
              draftIdentifier.draftIdentifier ?? "-", try await draftIdentifier.fileURL == nil,
              draftRoundTrip?.draftIdentifier ?? "-")
        print("file-entity", LocalFileEntity.supportedContentTypes.map(\.identifier).joined(separator: ","))

        let openURL = await OpenURLRecordIntent().urlRepresentation
        print("open-url-intent", OpenURLRecordIntent.openAppWhenRun, openURL?.absoluteString ?? "-")

        let url = URL(string: "https://example.com/search")!
        let urlParameter = IntentParameter<URL>(title: "Destination", default: url)
        print("url-parameter", urlParameter.title.key, urlParameter.defaultValue?.absoluteString ?? "-")
        let descriptiveURLParameter = IntentParameter<URL>(description: "Where to go", default: url)
        print("url-parameter-description", descriptiveURLParameter.title.key,
              descriptiveURLParameter.defaultValue?.absoluteString ?? "-")

        let dateParameter = IntentParameter<Date>(title: "Date", kind: .date)
        let dateComponentsParameter = IntentParameter<DateComponents>(description: "Time", kind: .time)
        print("date-kind", dateParameter.dateKind == .date, dateComponentsParameter.dateKind == .time)

        let richTextParameter = IntentParameter<AttributedString>(
            title: "Details", description: "Text with formatting", default: "Rich text"
        )
        let descriptiveRichTextParameter = IntentParameter<AttributedString>(
            description: "More details", default: "Rich text"
        )
        print("attributed-parameter", richTextParameter.title.key,
              richTextParameter.defaultValue.map { String($0.characters) } ?? "-",
              descriptiveRichTextParameter.title.key,
              descriptiveRichTextParameter.defaultValue.map { String($0.characters) } ?? "-")

        let propertyQuery = PropertyQueryRecordQuery()
        let propertyMatches = try await propertyQuery.entities(
            matching: [.nameContains("record")], mode: .and, sortedBy: [], limit: 1
        )
        let queryProperties = PropertyQueryRecordQuery.properties
        let querySorts = PropertyQueryRecordQuery.sortingOptions
        print("property-query", propertyMatches.map(\.id).joined(separator: ","),
              type(of: queryProperties[0]) == EntityQueryProperty<
                PropertyQueryRecord, PropertyQueryRecord, EntityProperty<String>, String, PropertyQueryComparator
              >.self,
              type(of: querySorts[0]) == EntityQuerySortableByProperty<PropertyQueryRecord>.self,
              PropertyQueryComparator.nameContains("x") != PropertyQueryComparator.nameEquals("x"))

        let intentError = AppIntentError.restartPerform
        let permissionError = AppIntentError.PermissionRequired.location(precise: true)
        print("intentError", intentError.description, intentError.localizedDescription, (intentError as NSError).code)
        print("permissionError", permissionError.description)
        print("parameterErrors", RepeatIntent().$message.needsValueError().description,
              RepeatIntent().$record.needsDisambiguationError(among: [LocalRecord(id: "one"), LocalRecord(id: "two")]).description)

        let urlEntity = URLRecordEntity(id: "one", slug: "hello world")
        print("url-entity", await urlEntity.urlRepresentation?.absoluteString ?? "-",
              urlEntity.urlRepresentationParameter ?? "-")
        let urlIntent = URLPageIntent()
        urlIntent.$page.wrappedValue = "about"
        print("url-intent", await urlIntent.urlRepresentation?.absoluteString ?? "-")
    }
}

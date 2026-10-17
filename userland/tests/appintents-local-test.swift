// SPDX-License-Identifier: MIT OR Apache-2.0
// The SDK hides several AppIntents view helpers, so build this comparison against Finch's
// interface and run the same binary once with Apple and once with Finch's frameworks.

import AppIntents
import AppKit
import _AppIntents_AppKit
import Darwin
import Foundation

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

enum LocalSetting: String, AppEnum, CaseIterable {
    case enabled

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Setting" }
    static var caseDisplayRepresentations: [LocalSetting: DisplayRepresentation] { [.enabled: "Enabled"] }
}

struct EmptyEntityQuery<Value: AppEntity>: EntityQuery {
    typealias Entity = Value
    init() {}
    func entities(for identifiers: [Value.ID]) async throws -> [Value] { [] }
}

struct MailAddress: MailAddressee {
    var id: String
    var displayName: String?
    var emailAddress: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mail address" }
    static var defaultQuery = EmptyEntityQuery<MailAddress>()

    init(displayName: String?, emailAddress: String) {
        self.id = emailAddress
        self.displayName = displayName
        self.emailAddress = emailAddress
    }
}

struct MailAccountRecord: MailAccount {
    var id: String
    var displayName: String?
    var emailAddress: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mail account" }
    static var defaultQuery = EmptyEntityQuery<MailAccountRecord>()
}

struct MailboxRecord: Mailbox {
    var id: String
    var name: String
    var account: MailAccountRecord?

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mailbox" }
    static var defaultQuery = EmptyEntityQuery<MailboxRecord>()
}

struct MailMessageRecord: MailMessage {
    typealias Addressee = MailAddress
    typealias Account = MailAccountRecord
    typealias Mailbox = MailboxRecord

    var id: String
    var attributes: [MailMessageAttribute] = []
    var dateReceived = Date(timeIntervalSince1970: 1)
    var dateSent = Date(timeIntervalSince1970: 2)
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var body: AttributedString? = nil
    var isJunk = false
    var isRead = false
    var sender: MailAddress
    var account: MailAccountRecord? = nil
    var mailbox: MailboxRecord? = nil
    var replyTo: [MailAddress] = []
    var subject: String? = "Subject"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mail message" }
    static var defaultQuery = EmptyEntityQuery<MailMessageRecord>()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: subject ?? ""))
    }

    init(id: String) {
        self.id = id
        sender = MailAddress(displayName: "Ada", emailAddress: "ada@example.com")
    }
}

struct SendMailAction: SendMailIntent {
    typealias Addressee = MailAddress
    typealias Account = MailAccountRecord
    typealias ReplyMessage = MailMessageRecord

    static var title: LocalizedStringResource { "Send mail" }
    var attachments: [IntentFile] = []
    var cc: [MailAddress] = []
    var to = [MailAddress(displayName: "Ada", emailAddress: "ada@example.com")]
    var bcc: [MailAddress] = []
    var body: AttributedString? = AttributedString("Hello")
    var account: MailAccountRecord? = nil
    var subject: String? = "Hello"
    var inReplyTo: MailMessageRecord? = nil

    func perform() async throws -> some IntentResult { .result(value: subject ?? "") }
}

struct MarkMailReadAction: SetMailMessageIsReadIntent {
    typealias Message = MailMessageRecord
    static var title: LocalizedStringResource { "Mark mail read" }
    var read = true
    var message = MailMessageRecord(id: "message-1")

    func perform() async throws -> some IntentResult { .result(value: read) }
}

struct SearchAction: SearchIntent {
    static var title: LocalizedStringResource { "Search" }
    var searchPhrase = "letters"
    func perform() async throws -> some IntentResult { .result(value: searchPhrase) }
}

struct CreateAction: CreateIntent {
    typealias Entity = LocalEntity
    static var title: LocalizedStringResource { "Create" }
    var name: String? = "new record"
    func perform() async throws -> some IntentResult { .result(value: LocalEntity(id: name ?? "new")) }
}

struct ToggleAction: ChangeBinarySettingIntent {
    typealias Setting = LocalSetting
    static var title: LocalizedStringResource { "Toggle" }
    var setting = LocalSetting.enabled
    var changeOperation = ChangeOperation.toggle
    func perform() async throws -> some IntentResult { .result() }

    init() {}

    init(changeOperation: ChangeOperation) {
        self.changeOperation = changeOperation
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

        let address = MailAddress(displayName: "Ada", emailAddress: "ada@example.com")
        let account = MailAccountRecord(id: "account-1", displayName: "Work", emailAddress: "work@example.com")
        let mailbox = MailboxRecord(id: "inbox", name: "Inbox", account: account)
        var message = MailMessageRecord(id: "message-1")
        message.to = [address]
        message.account = account
        message.mailbox = mailbox
        let send = SendMailAction(account: account, inReplyTo: message)
        try await send.prepare()
        let sendResult = try await send.perform()
        let markRead = MarkMailReadAction(message: message)
        try await markRead.prepare()
        let readResult = try await markRead.perform()
        print("mail-contract", address.displayRepresentation.title.key,
              account.displayRepresentation.title.key, mailbox.displayRepresentation.title.key,
              message.to.first?.emailAddress ?? "-", send.attachments.count,
              sendResult.value ?? "-", readResult.value ?? false)

        let search = SearchAction(searchPhrase: "finch")
        let searchResult = try await search.perform()
        let create = CreateAction(name: "new item")
        let createResult = try await create.perform()
        let toggle = ToggleAction(changeOperation: .disable)
        print("system-intent-contracts", search.searchPhrase, searchResult.value ?? "-",
              create.name ?? "-", createResult.value != nil, toggle.changeOperation.rawValue,
              toggle.setting.rawValue, NavigateSequentiallyDirection.next.rawValue)

        let urlText: any CustomURLRepresentationParameterConvertible = "a song"
        let urlNumber: any CustomURLRepresentationParameterConvertible = 42
        let urlValue: any CustomURLRepresentationParameterConvertible = URL(string: "https://example.com/item")!
        print("url-values", await urlText.urlRepresentationParameter ?? "-",
              await urlNumber.urlRepresentationParameter ?? "-",
              await urlValue.urlRepresentationParameter ?? "-")

    }
}

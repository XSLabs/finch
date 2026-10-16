// SPDX-License-Identifier: MIT OR Apache-2.0
// AppIntents' SwiftUI modifiers and intent-backed controls, compared with Apple's.

import AppIntents
import Foundation
@_spi(AppIntents) import SwiftUI
import _AppIntents_SwiftUI
import Darwin

struct ViewActionIntent: AppIntent {
    static var title: LocalizedStringResource { "View Action" }

    func perform() async throws -> some IntentResult { .result() }
}

struct ViewEntity: AppEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "View Entity" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id))
    }
    static var defaultQuery = ViewEntityQuery()
}

struct ViewEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ViewEntity] {
        identifiers.map(ViewEntity.init(id:))
    }

    func suggestedEntities() async throws -> [ViewEntity] { [ViewEntity(id: "one")] }
}

@main
struct AppIntentsSwiftUITest {
    static func main() {
        var info = Dl_info()
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s10AppIntents16EntityIdentifierVMn")
        dladdr(symbol, &info)
        print(info.dli_fname.map { String(cString: $0) } ?? "?")

        let entity = ViewEntity(id: "one")
        let identified = Text("Entity").appEntityIdentifier(EntityIdentifier(for: entity))
        let annotated = Text("Selected").appEntity(entity, state: .selected)
        let accessibilityAction = Text("Play").accessibilityAction(named: "Play", intent: ViewActionIntent())
        let toggle = Toggle(isOn: true, intent: ViewActionIntent()) { Text("Play") }
        let playback = PlaybackButton(state: .playing, intent: ViewActionIntent())
        withExtendedLifetime((identified, annotated, accessibilityAction, toggle, playback)) {}
        print("views", "created")
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
// AppIntents' local SwiftUI metadata and controls.

@_exported import AppIntents
public import Foundation
@_spi(AppIntents) import SwiftUI

private struct AppEntityIdentifierKey: EnvironmentKey {
    static let defaultValue: EntityIdentifier? = nil
}

private struct AppEntityVisualStateKey: EnvironmentKey {
    static let defaultValue: AppEntityVisualState = []
}

private extension EnvironmentValues {
    var appEntityIdentifier: EntityIdentifier? {
        get { self[AppEntityIdentifierKey.self] }
        set { self[AppEntityIdentifierKey.self] = newValue }
    }

    var appEntityVisualState: AppEntityVisualState {
        get { self[AppEntityVisualStateKey.self] }
        set { self[AppEntityVisualStateKey.self] = newValue }
    }
}

private struct AppEntityIdentifierModifier: ViewModifier {
    let identifier: EntityIdentifier?

    func body(content: Content) -> some View {
        content.environment(\.appEntityIdentifier, identifier)
    }
}

private struct AppEntityModifier: ViewModifier {
    let identifier: EntityIdentifier
    let state: AppEntityVisualState

    func body(content: Content) -> some View {
        content
            .environment(\.appEntityIdentifier, identifier)
            .environment(\.appEntityVisualState, state)
    }
}

extension View {
    public func appEntityIdentifier(_ identifier: EntityIdentifier?) -> some View {
        modifier(AppEntityIdentifierModifier(identifier: identifier))
    }

    public func appEntity<Entity: AppEntity>(_ entity: Entity, state: AppEntityVisualState) -> some View {
        modifier(AppEntityModifier(identifier: EntityIdentifier(for: entity), state: state))
    }

    public func appEntity<Entity: AppEntity>(entityType: Entity.Type, identifier: Entity.ID,
                                              state: AppEntityVisualState) -> some View {
        modifier(AppEntityModifier(identifier: EntityIdentifier(for: entityType, identifier: identifier), state: state))
    }

    public func accessibilityAction<Name: StringProtocol, Intent: AppIntent>(named name: Name, intent: Intent)
        -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        accessibilityAction(named: name) {
            Task { _ = try? await intent.perform() }
        }
    }
}

extension Toggle {
    nonisolated public init<Intent: AppIntent>(isOn: Bool, intent: Intent, @ViewBuilder label: () -> Label) {
        let value = Binding<Bool>(
            get: { isOn },
            set: { _ in Task { _ = try? await intent.perform() } }
        )
        self.init(isOn: value, label: label)
    }
}

extension PlaybackButton {
    public init<Intent: AppIntent>(interval: ClosedRange<Date>? = nil, state: PlaybackButton.State, intent: Intent,
                                   systemImage: String? = nil, alignment: Alignment = .center) {
        self.init(interval: interval, state: state, systemImage: systemImage, alignment: alignment,
                  lnAction: NSObject(), perform: { Task { _ = try? await intent.perform() } })
    }

    public init<Intent: AppIntent>(interval: ClosedRange<Date>, state: PlaybackButton.State, intent: Intent,
                                   playSystemImage: String? = nil, pauseSystemImage: String? = nil) {
        let image = state == .playing ? pauseSystemImage : playSystemImage
        self.init(interval: interval, state: state, systemImage: image, alignment: .center,
                  lnAction: NSObject(), perform: { Task { _ = try? await intent.perform() } })
    }
}

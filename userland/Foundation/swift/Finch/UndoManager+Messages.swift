// SPDX-License-Identifier: MIT OR Apache-2.0
// The typed notification-center messages for UndoManager's and HTTPCookieStorage's
// notifications (Apple's overlay API since macOS 26): each message is its
// notification's name and, where the notification carries it, whether the undo
// group is discardable.

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension HTTPCookieStorage {
    public struct CookiesChangedMessage: NotificationCenter.AsyncMessage {
        public typealias Subject = HTTPCookieStorage
        public static var name: Notification.Name { Notification.Name("NSHTTPCookieManagerCookiesChangedNotification") }
        public init() {}
        public static func makeMessage(_ notification: Notification) -> CookiesChangedMessage? { .init() }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
private func finchGroupIsDiscardable(_ n: Notification) -> Bool {
    (n.userInfo?["NSUndoManagerGroupIsDiscardableKey"] as? Bool) ?? false
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
private func finchNotification(_ name: Notification.Name, discardable: Bool) -> Notification {
    Notification(name: name, object: nil, userInfo: ["NSUndoManagerGroupIsDiscardableKey": discardable])
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
extension UndoManager {
    public struct WillUndoChangeMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerWillUndoChangeNotification") }
        public init() {}
        @MainActor public static func makeMessage(_ notification: Notification) -> WillUndoChangeMessage? { .init() }
    }

    public struct DidUndoChangeMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerDidUndoChangeNotification") }
        public var groupIsDiscardable: Bool
        public init(groupIsDiscardable: Bool) { self.groupIsDiscardable = groupIsDiscardable }
        @MainActor public static func makeMessage(_ notification: Notification) -> DidUndoChangeMessage? {
            .init(groupIsDiscardable: finchGroupIsDiscardable(notification))
        }
        @MainActor public static func makeNotification(_ message: DidUndoChangeMessage) -> Notification {
            finchNotification(name, discardable: message.groupIsDiscardable)
        }
    }

    public struct WillRedoChangeMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerWillRedoChangeNotification") }
        public init() {}
        @MainActor public static func makeMessage(_ notification: Notification) -> WillRedoChangeMessage? { .init() }
    }

    public struct DidRedoChangeMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerDidRedoChangeNotification") }
        public var groupIsDiscardable: Bool
        public init(groupIsDiscardable: Bool) { self.groupIsDiscardable = groupIsDiscardable }
        @MainActor public static func makeMessage(_ notification: Notification) -> DidRedoChangeMessage? {
            .init(groupIsDiscardable: finchGroupIsDiscardable(notification))
        }
        @MainActor public static func makeNotification(_ message: DidRedoChangeMessage) -> Notification {
            finchNotification(name, discardable: message.groupIsDiscardable)
        }
    }

    public struct CheckpointMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerCheckpointNotification") }
        public init() {}
        @MainActor public static func makeMessage(_ notification: Notification) -> CheckpointMessage? { .init() }
    }

    public struct DidOpenUndoGroupMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerDidOpenUndoGroupNotification") }
        public init() {}
        @MainActor public static func makeMessage(_ notification: Notification) -> DidOpenUndoGroupMessage? { .init() }
    }

    public struct DidCloseUndoGroupMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerDidCloseUndoGroupNotification") }
        public var groupIsDiscardable: Bool
        public init(groupIsDiscardable: Bool) { self.groupIsDiscardable = groupIsDiscardable }
        @MainActor public static func makeMessage(_ notification: Notification) -> DidCloseUndoGroupMessage? {
            .init(groupIsDiscardable: finchGroupIsDiscardable(notification))
        }
        @MainActor public static func makeNotification(_ message: DidCloseUndoGroupMessage) -> Notification {
            finchNotification(name, discardable: message.groupIsDiscardable)
        }
    }

    public struct WillCloseUndoGroupMessage: NotificationCenter.MainActorMessage, Sendable {
        public typealias Subject = UndoManager
        public static var name: Notification.Name { Notification.Name("NSUndoManagerWillCloseUndoGroupNotification") }
        public init() {}
        @MainActor public static func makeMessage(_ notification: Notification) -> WillCloseUndoGroupMessage? { .init() }
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Sidebar row sizing changes the minimum height of Finch's sidebar list rows.

public import SwiftUICore

@available(macOS 13.0, *)
public enum SidebarRowSize: Equatable, Sendable {
    case small
    case medium
    case large
}

@available(macOS 13.0, *)
private struct _FinchSidebarRowSizeKey: EnvironmentKey {
    static let defaultValue = SidebarRowSize.medium
}

@available(macOS 13.0, *)
extension EnvironmentValues {
    public var sidebarRowSize: SidebarRowSize {
        get { self[_FinchSidebarRowSizeKey.self] }
        set { self[_FinchSidebarRowSizeKey.self] = newValue }
    }
}

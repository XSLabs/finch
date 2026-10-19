// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScrollPosition, to Apple's interface. Identified children report their frames into the
// scroll view; an ID, edge or point update moves that scroll view, and user scrolling updates
// the bound position to the first visible identified child.

import Foundation
import SwiftUICore

public extension ScrollPosition {
    init<ID>(id: ID, anchor: UnitPoint? = nil) where ID: Hashable & Sendable {
        self.init(idType: ID.self)
        scrollTo(id: id, anchor: anchor)
    }

    init<ID>(idType: ID.Type = Never.self) where ID: Hashable & Sendable {
        self.init()
        _idType = ObjectIdentifier(ID.self)
    }

    init<ID>(idType: ID.Type = Never.self, edge: Edge) where ID: Hashable & Sendable {
        self.init(idType: idType)
        scrollTo(edge: edge)
    }

    init<ID>(idType: ID.Type = Never.self, point: CGPoint) where ID: Hashable & Sendable {
        self.init(idType: idType)
        scrollTo(point: point)
    }

    init<ID>(idType: ID.Type = Never.self, x: CGFloat, y: CGFloat) where ID: Hashable & Sendable {
        self.init(idType: idType)
        scrollTo(x: x, y: y)
    }

    init<ID>(idType: ID.Type = Never.self, x: CGFloat) where ID: Hashable & Sendable {
        self.init(idType: idType)
        scrollTo(x: x)
    }

    init<ID>(idType: ID.Type = Never.self, y: CGFloat) where ID: Hashable & Sendable {
        self.init(idType: idType)
        scrollTo(y: y)
    }

    mutating func scrollTo<ID>(id: ID, anchor: UnitPoint? = nil) where ID: Hashable & Sendable {
        _finchScrollTo(id: id, anchor: anchor)
    }

    // (scrollPosition(id:anchor:) takes any Hashable ID, as Apple's does)
    package mutating func _finchScrollTo<ID>(id: ID, anchor: UnitPoint?) where ID: Hashable {
        _viewID = AnyHashable(id)
        _idType = ObjectIdentifier(ID.self)
        _edge = nil
        _point = nil
        _x = nil
        _y = nil
        _anchor = anchor
        _isPositionedByUser = false
    }

    mutating func scrollTo(edge: Edge) {
        _viewID = nil
        _edge = edge
        _point = nil
        _x = nil
        _y = nil
        _anchor = nil
        _isPositionedByUser = false
    }

    mutating func scrollTo(point: CGPoint) {
        _viewID = nil
        _edge = nil
        _point = point
        _x = point.x
        _y = point.y
        _anchor = nil
        _isPositionedByUser = false
    }

    mutating func scrollTo(x: CGFloat, y: CGFloat) {
        _viewID = nil
        _edge = nil
        _point = nil
        _x = x
        _y = y
        _anchor = nil
        _isPositionedByUser = false
    }

    mutating func scrollTo(x: CGFloat) {
        _viewID = nil
        _edge = nil
        _point = nil
        _x = x
        _y = nil
        _anchor = nil
        _isPositionedByUser = false
    }

    mutating func scrollTo(y: CGFloat) {
        _viewID = nil
        _edge = nil
        _point = nil
        _x = nil
        _y = y
        _anchor = nil
        _isPositionedByUser = false
    }

    var isPositionedByUser: Bool {
        get { _isPositionedByUser }
        set { _isPositionedByUser = newValue }
    }

    var edge: Edge? { _edge }

    var point: CGPoint? {
        if let _point { return _point }
        guard _x != nil || _y != nil else { return nil }
        return CGPoint(x: _x ?? 0, y: _y ?? 0)
    }

    @available(macOS 26.0, *)
    var x: CGFloat? { _x ?? _point?.x }

    @available(macOS 26.0, *)
    var y: CGFloat? { _y ?? _point?.y }

    var viewID: (any Hashable & Sendable)? {
        guard let id = _viewID?.base else { return nil }
        return id as! (any Hashable & Sendable)
    }

    func viewID<ID>(type: ID.Type) -> ID? where ID: Hashable & Sendable {
        _viewID?.base as? ID
    }

    package mutating func _finchSetIDType<ID>(_ type: ID.Type) where ID: Hashable {
        _idType = ObjectIdentifier(type)
    }

    package func _finchViewID<ID>(type: ID.Type) -> ID? where ID: Hashable {
        _viewID?.base as? ID
    }

    package mutating func _finchSetVisibleID(_ id: AnyHashable) {
        _viewID = id
        _edge = nil
        _point = nil
        _x = nil
        _y = nil
        _anchor = nil
        _isPositionedByUser = true
    }
}

extension ScrollPosition: Equatable {
    public static func == (lhs: ScrollPosition, rhs: ScrollPosition) -> Bool {
        lhs._viewID == rhs._viewID && lhs._idType == rhs._idType && lhs._edge == rhs._edge &&
            lhs._point == rhs._point && lhs._x == rhs._x && lhs._y == rhs._y &&
            lhs._anchor == rhs._anchor && lhs._isPositionedByUser == rhs._isPositionedByUser
    }
}

@available(macOS 15.0, *)
public struct ScrollAnchorRole: Hashable, Sendable {
    private enum Kind: Hashable, Sendable { case initialOffset, sizeChanges, alignment }
    private var kind: Kind

    private init(_ kind: Kind) { self.kind = kind }

    public static var initialOffset: Self { .init(.initialOffset) }
    public static var sizeChanges: Self { .init(.sizeChanges) }
    public static var alignment: Self { .init(.alignment) }

    fileprivate var finchRole: _FinchScrollAnchorRole {
        switch kind {
        case .initialOffset: .initialOffset
        case .sizeChanges: .sizeChanges
        case .alignment: .alignment
        }
    }
}

enum _FinchScrollAnchorRole: Hashable {
    case initialOffset, sizeChanges, alignment
}

private struct _FinchScrollPositionKey: EnvironmentKey {
    static var defaultValue: Binding<ScrollPosition>? { nil }
}

private struct _FinchScrollPositionAnchorKey: EnvironmentKey {
    static var defaultValue: UnitPoint? { nil }
}

private struct _FinchScrollClipDisabledKey: EnvironmentKey {
    static var defaultValue = false
}

private struct _FinchDefaultScrollAnchorKey: EnvironmentKey {
    static var defaultValue: UnitPoint? { nil }
}

private struct _FinchDefaultScrollAnchorRolesKey: EnvironmentKey {
    static var defaultValue: [_FinchScrollAnchorRole: UnitPoint] { [:] }
}

extension EnvironmentValues {
    var _finchScrollPosition: Binding<ScrollPosition>? {
        get { self[_FinchScrollPositionKey.self] }
        set { self[_FinchScrollPositionKey.self] = newValue }
    }

    var _finchScrollPositionAnchor: UnitPoint? {
        get { self[_FinchScrollPositionAnchorKey.self] }
        set { self[_FinchScrollPositionAnchorKey.self] = newValue }
    }

    var _finchScrollClipDisabled: Bool {
        get { self[_FinchScrollClipDisabledKey.self] }
        set { self[_FinchScrollClipDisabledKey.self] = newValue }
    }

    var _finchDefaultScrollAnchor: UnitPoint? {
        get { self[_FinchDefaultScrollAnchorKey.self] }
        set { self[_FinchDefaultScrollAnchorKey.self] = newValue }
    }

    var _finchDefaultScrollAnchors: [_FinchScrollAnchorRole: UnitPoint] {
        get { self[_FinchDefaultScrollAnchorRolesKey.self] }
        set { self[_FinchDefaultScrollAnchorRolesKey.self] = newValue }
    }
}

extension View {
    nonisolated public func scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint? = nil) -> some View {
        environment(\._finchScrollPosition, position)
            .environment(\._finchScrollPositionAnchor, anchor)
    }

    nonisolated public func scrollPosition<ID>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View
        where ID: Hashable {
        let position = Binding<ScrollPosition>(get: {
            var value = ScrollPosition()
            value._finchSetIDType(ID.self)
            if let id = id.wrappedValue { value._finchScrollTo(id: id, anchor: anchor) }
            return value
        }, set: { value in
            id.wrappedValue = value._finchViewID(type: ID.self)
        })
        return scrollPosition(position, anchor: anchor)
    }

    nonisolated public func scrollTargetLayout(isEnabled: Bool = true) -> some View {
        environment(\._finchReportsScrollTargets, isEnabled)
    }

    nonisolated public func scrollClipDisabled(_ disabled: Bool = true) -> some View {
        environment(\._finchScrollClipDisabled, disabled)
    }

    @available(macOS 14.0, *)
    nonisolated public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        environment(\._finchDefaultScrollAnchor, anchor)
    }

    @available(macOS 15.0, *)
    nonisolated public func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View {
        transformEnvironment(\._finchDefaultScrollAnchors) { anchors in
            if let anchor {
                anchors[role.finchRole] = anchor
            } else {
                anchors.removeValue(forKey: role.finchRole)
            }
        }
    }
}

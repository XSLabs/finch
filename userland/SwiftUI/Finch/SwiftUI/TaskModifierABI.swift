// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Apps built with the current SDK call the sendable async form of _TaskValueModifier.init.
// OpenSwiftUI exports the same initializer without the sendable function-type ABI marker.
// This entry point keeps Apple's symbol name and forwards to the real modifier initializer.

@_silgen_name("$s7SwiftUI18_TaskValueModifierV5value8priority6actionACyxGx_ScPyyYaYbctcfC")
public func _finchTaskValueModifierSendableInit<Value>(
    value: Value,
    priority: TaskPriority,
    action: @escaping @Sendable () async -> Void
) -> _TaskValueModifier<Value> where Value: Equatable {
    _TaskValueModifier(value: value, priority: priority, action: action)
}

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Sizing rules for sheets and popovers. The presenter measures the content, then applies
// the rule's proposed size before it opens or updates the window.

@_spi(ForOpenSwiftUIOnly) import SwiftUICore

@available(macOS 15.0, *)
public protocol PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize
}

@available(macOS 15.0, *)
public struct PresentationSizingRoot {
    private var measure: (ProposedViewSize) -> CGSize

    init(measure: @escaping (ProposedViewSize) -> CGSize) {
        self.measure = measure
    }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        measure(proposal)
    }
}

@available(macOS 15.0, *)
public struct PresentationSizingContext {}

@available(macOS 15.0, *)
public struct FittedPresentationSizing: PresentationSizing, Sendable {
    public init() {}

    public func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let size = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        return ProposedViewSize(width: size.width, height: size.height)
    }
}

@available(macOS 15.0, *)
extension PresentationSizing where Self == FittedPresentationSizing {
    public static var fitted: FittedPresentationSizing { FittedPresentationSizing() }
}

struct _FinchPresentationSizingPolicy {
    var sizeThatFits: (@escaping (ProposedViewSize) -> CGSize) -> CGSize
}

private struct _FinchPresentationSizingKey: EnvironmentKey {
    static var defaultValue: _FinchPresentationSizingPolicy? { nil }
}

extension EnvironmentValues {
    var _finchPresentationSizing: _FinchPresentationSizingPolicy? {
        get { self[_FinchPresentationSizingKey.self] }
        set { self[_FinchPresentationSizingKey.self] = newValue }
    }
}

@available(macOS 15.0, *)
extension View {
    nonisolated public func presentationSizing(_ sizing: some PresentationSizing) -> some View {
        let policy = _FinchPresentationSizingPolicy { measure in
            let root = PresentationSizingRoot { measure($0) }
            let naturalSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let proposal = sizing.proposedSize(for: root, context: PresentationSizingContext())
            return root.sizeThatFits(ProposedViewSize(width: proposal.width ?? naturalSize.width,
                                                     height: proposal.height ?? naturalSize.height))
        }
        return environment(\._finchPresentationSizing, policy)
    }
}

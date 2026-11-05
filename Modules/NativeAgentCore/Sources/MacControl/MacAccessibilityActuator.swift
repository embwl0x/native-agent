import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import NativeAgentShared
#endif
// Blueprint: | `MacAccessibilityActuator.swift` | Requested AX mutation only; unsupported outcomes stop without substitution |
/// Choose the requested AX value write or advertised action before emission. Unsupported operations stop; physical gestures require their own explicit request.
public enum MacAccessibilityActuator {
    public static let pathNotFoundError = "ax_path_not_found"
    public static let defaultAction = "AXPress"

    public struct ActResult: Sendable, Equatable {
        public let ok: Bool
        public let method: String
        public let requestedAction: String
        public let outcome: MacAXActOutcome

        public let target: MacAXActTarget
        public let postState: MacAXActTarget?
        public let error: String?
    }

    /// Preserve the caller's live drift check on its resolved target.
    public nonisolated(nonsending) static func act(
        source: any MacAXActSource,
        target: MacAXActTarget,
        action requestedAction: String?,
        value: String?,
        turn: Turn, context: MacOperationContext
    ) async -> ActResult {
        let action = (requestedAction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultAction
        guard target.enabled else {
            return ActResult(ok: false, method: "none", requestedAction: action,
                outcome: .unsupported, target: target,
                postState: source.reread(target, context: context), error: "element_disabled")
        }
        if let value {
            let outcome = source.setValue(target, value: value, turn: turn, context: context)
            // A refused value write stops here; clicking would be a different effect.
            return ActResult(
                ok: outcome == .performed,
                method: outcome.emissionAttempted ? "ax_set_value" : "none",
                requestedAction: "AXSetValue",
                outcome: outcome,
                target: target,
                postState: source.reread(target, context: context),
                error: outcome == .performed ? nil : "ax_set_value_\(outcome.rawValue)"
            )
        }

        if target.actions.contains(action) {
            let outcome = source.perform(target, action: action, turn: turn, context: context)
            // A failed reply does not prove the handler had no effect. Return its readback; never post another mutation after this attempt.
            return ActResult(ok: outcome == .performed, method: "ax_action",
                requestedAction: action, outcome: outcome, target: target, postState: source.reread(target, context: context),
                error: outcome == .performed ? nil : "ax_action_\(outcome.rawValue)")
        }

        return ActResult(ok: false, method: "none", requestedAction: action,
            outcome: .unsupported, target: target,
            postState: source.reread(target, context: context), error: "unsupported_explicit_ax_action")
    }
}

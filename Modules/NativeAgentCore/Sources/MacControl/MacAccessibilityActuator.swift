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
// Blueprint: | `MacAccessibilityActuator.swift` | Performs the requested AX value/action only, preserving unsupported outcomes, source rereads and result receipts |
/// The semantic act (`ax_act`), as pure logic over the two seams.
///
/// Select one implementation before attempting the effect:
///   1. `value` given → try `AXSetValue`. That is how you fill a text field
///      without simulating 40 keystrokes.
///   2. otherwise → the requested AX action (default `AXPress`) if the element
///      advertises it. The APP runs its real handler; works occluded/off-screen.
/// Unsupported AX operations stop here. Physical gestures have their own
/// explicitly requested operations; they never replace a semantic action.
public enum MacAccessibilityActuator {
    public static let pathNotFoundError = "ax_path_not_found"
    public static let defaultAction = "AXPress"

    public struct ActResult: Sendable, Equatable {
        public let ok: Bool
        /// `ax_set_value` | `ax_action` | `none`
        public let method: String
        public let requestedAction: String
        public let outcome: MacAXActOutcome

        public let target: MacAXActTarget
        public let postState: MacAXActTarget?
        public let error: String?
    }

    /// Act on the caller's resolved target, preserving any live drift check.
    public nonisolated(nonsending) static func act(
        source: any MacAXActSource,
        target: MacAXActTarget,
        action requestedAction: String?,
        value: String?
    ) async -> ActResult {
        let action = (requestedAction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultAction
        guard target.enabled else {
            return ActResult(ok: false, method: "none", requestedAction: action,
                outcome: .unsupported, target: target,
                postState: source.reread(target), error: "element_disabled")
        }
        if let value {
            let outcome = source.setValue(target, value: value)
            // A refused value write stops here; clicking would be a different effect.
            return ActResult(
                ok: outcome == .performed,
                method: outcome.emissionAttempted ? "ax_set_value" : "none",
                requestedAction: "AXSetValue",
                outcome: outcome,
                target: target,
                postState: source.reread(target),
                error: outcome == .performed ? nil : "ax_set_value_\(outcome.rawValue)"
            )
        }

        if target.actions.contains(action) {
            let outcome = source.perform(target, action: action)
            // A failed reply does not prove the handler had no effect. Return
            // its readback; never post another mutation after this attempt.
            return ActResult(ok: outcome == .performed, method: "ax_action",
                requestedAction: action, outcome: outcome, target: target, postState: source.reread(target),
                error: outcome == .performed ? nil : "ax_action_\(outcome.rawValue)")
        }

        return ActResult(ok: false, method: "none", requestedAction: action,
            outcome: .unsupported, target: target,
            postState: source.reread(target), error: "unsupported_explicit_ax_action")
    }
}

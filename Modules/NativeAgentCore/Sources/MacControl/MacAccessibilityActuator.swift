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
// Blueprint: | `MacAccessibilityActuator.swift` | Selects and reports AX value/action or explicitly admitted synthetic click, preserving source rereads and result receipts |
/// The semantic act (`ax_act`), as pure logic over the two seams.
///
/// Select one implementation before attempting the effect:
///   1. `value` given → try `AXSetValue`. That is how you fill a text field
///      without simulating 40 keystrokes.
///   2. otherwise → the requested AX action (default `AXPress`) if the element
///      advertises it. The APP runs its real handler; works occluded/off-screen.
///   3. AXPress unavailable → synthesize a click at the element's frame centre,
///      and SAY SO in `method` + `fallback_reason`. A caller must always be
///      able to tell which of the two mechanisms actually fired.
public enum MacAccessibilityActuator {
    public static let pathNotFoundError = "ax_path_not_found"
    public static let defaultAction = "AXPress"

    public struct ActResult: Sendable, Equatable {
        public let ok: Bool
        /// `ax_set_value` | `ax_action` | `cgevent_click_fallback` | `none`
        public let method: String
        public let requestedAction: String
        public let outcome: MacAXActOutcome
        public let fallbackReason: String?
        public let target: MacAXActTarget
        public let postState: MacAXActTarget?
        public let error: String?
    }

    /// Act on the caller's resolved target, preserving any live drift check.
    public nonisolated(nonsending) static func act(
        source: any MacAXActSource,
        sink: any MacEventSink,
        target: MacAXActTarget,
        action requestedAction: String?,
        value: String?,
        /// Admit the preselected synthetic click immediately before input.
        syntheticFallbackGate: (() -> Bool)? = nil,
        emit: ([MacHandStep]) async -> String?
    ) async -> ActResult {
        let action = (requestedAction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultAction
        if let value {
            let outcome = source.setValue(target, value: value)
            // A refused value write stops here; clicking would be a different effect.
            return ActResult(
                ok: outcome == .performed,
                method: outcome == .performed ? "ax_set_value" : "none",
                requestedAction: "AXSetValue",
                outcome: outcome,
                fallbackReason: nil,
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
                requestedAction: action, outcome: outcome, fallbackReason: nil,
                target: target, postState: source.reread(target),
                error: outcome == .performed ? nil : "ax_action_\(outcome.rawValue)")
        }

        guard action == defaultAction else {
            return ActResult(ok: false, method: "none", requestedAction: action,
                outcome: .unsupported, fallbackReason: nil, target: target,
                postState: source.reread(target), error: "unsupported_explicit_ax_action")
        }
        return await fallbackClick(
            source: source,
            sink: sink,
            target: target,
            action: action,
            reason: "element_does_not_advertise_\(action)",
            gate: syntheticFallbackGate,
            emit: emit
        )
    }

    private nonisolated(nonsending) static func fallbackClick(
        source: any MacAXActSource,
        sink: any MacEventSink,
        target: MacAXActTarget,
        action: String,
        reason: String,
        gate: (() -> Bool)? = nil,
        emit: ([MacHandStep]) async -> String?
    ) async -> ActResult {
        guard sink.isAvailable else {
            return ActResult(
                ok: false,
                method: "none",
                requestedAction: action,
                outcome: .unsupported,
                fallbackReason: reason,
                target: target,
                postState: source.reread(target),
                error: "event_injection_unavailable"
            )
        }
        guard let centre = target.centre else {
            return ActResult(
                ok: false,
                method: "none",
                requestedAction: action,
                outcome: .unsupported,
                fallbackReason: reason,
                target: target,
                postState: source.reread(target),
                error: "no_ax_action_and_no_frame"
            )
        }
        // LAST THING BEFORE THE FIRST EVENT. After the availability and frame
        // checks (a gate that fires for a call which was never going to post
        // anything would refuse for the wrong reason) and before the post.
        if let gate, !gate() {
            return ActResult(
                ok: false,
                method: "none",
                requestedAction: action,
                outcome: .unsupported,
                fallbackReason: reason,
                target: target,
                postState: source.reread(target),
                error: "synthetic_fallback_refused"
            )
        }
        let error = await emit(MacHandRepertoire.click(button: .left, at: centre))
        return ActResult(
            ok: error == nil,
            method: "cgevent_click_fallback",
            requestedAction: action,
            outcome: .performed,
            fallbackReason: reason,
            target: target,
            postState: source.reread(target),
            error: error
        )
    }
}

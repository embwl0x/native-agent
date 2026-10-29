import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
// Blueprint: | `MacControlAdmission.swift` | Canonical desktop policy and input admission; passive observation carries no motor authority |

extension SwiftNativeMacControl {
    // MARK: gate pre-flight

    /// A refusal returns its shaped result; proceed continues native dispatch.
    enum GatePreflightOutcome {
        case refuse(MacControlResult)
        case proceed
    }

    /// Check master, remote, and category gates before the file-policy layer. Execution, approval, and operation receipts remain with their owners.
    func gatePreflightOutcome(
        action: String,
        body: [String: JSONValue]
    ) async -> GatePreflightOutcome {
        // The entry point validates explicit replay capabilities. Every call reaches this policy preflight, with or without a replay capability.  No provider configured: tests and direct library callers can exercise handlers in isolation.
        // Production wires a Swift TrustCenter provider.
        guard let provider = policyProvider else { return .proceed }
        guard let category = macControlGateCategory(forAction: action) else {
            // self_test / unmapped: no single category to pre-gate. Unsupported actions fail closed after this pre-flight.
            return .proceed
        }
        guard let policy = await provider.currentPolicy() else {
            return .refuse(Self.refusalResult(
                action: action,
                reason: "mac_control_policy_unavailable: Swift trust policy could not be resolved",
                now: now
            ))
        }
        let trigger = body["trigger"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "user"

        let decision = MacControlGate.gate(policy, category: category, trigger: trigger)
        if !decision.allowed {
            let result = Self.refusalResult(action: action, reason: decision.reason, now: now, remedy: decision.remedy)
            await emitBlockedAudit(action: action, category: category, reason: decision.reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // Accessibility category permission alone is insufficient: reads, input, clipboard, document access and nudge also require an active Full Mac window, including calls entering through remote surfaces.
        if macControlAccessibilityReadActions.contains(action)
            || macControlAccessibilityNudgeActions.contains(action)
            || macControlClipboardActions.contains(action)
            || macControlDocumentReadActions.contains(action)
            || macControlAccessibilityInjectionActions.contains(action),
           !(policy.trustPolicy.map { MacControlGate.fullMacActive($0) } ?? false) {
            let reason = "full_mac_inactive: \(action) requires Full Mac access enabled in Trust"
            let result = Self.refusalResult(action: action, reason: reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // Let each native handler report its authoritative sensitive-path refusal before the workspace policy refusal. For other paths, run the workspace-root and Full Mac checks here.
        let pathKeys = macControlFilePolicyPathKeys(forAction: action)
        // A command line is a write on his side whatever it says: it runs only on the one authorization decision (posture × that declared class), never on its text. Full Mac runs, Work asks, Safe refuses. Every action meets "Pause
        // everything" here.
        if let answer = await provider.authorize(tool: action, input: body), answer.level != "auto" {
            let reason = (answer.level == "confirm" ? "needs_approval: " : "blocked: ") + answer.reason
            let result = Self.refusalResult(action: action, reason: reason, now: now, remedy: answer.remedy)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        if !pathKeys.isEmpty {
            let paths: [String] = pathKeys.compactMap { key in
                guard let v = body[key]?.stringValue, !v.isEmpty else { return nil }
                return v
            }
            let anySensitive = paths.contains { MacControlSensitivePathFence.reason(forPath: $0) != nil }
            if !anySensitive, !paths.isEmpty,
               let reason = MacControlGate.fileReason(policy, forPaths: paths) {
                let result = Self.refusalResult(action: action, reason: reason, now: now)
                await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
                return .refuse(result)
            }
        }
        return .proceed
    }

    /// Preserve `httpStatus:403` and the verbatim gate reason for callers rendering a refusal.
    private static func refusalResult(
        action: String,
        reason: String,
        now: @Sendable () -> Date,
        remedy: JSONValue? = nil
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("blocked"),
                "error": .string(reason),
                "block_reason": .string(reason),
                "blocked_by": .string("swift_gate_preflight"),
                "remedy": remedy ?? .null,
            ]),
            error: reason,
            durationMs: 0,
            httpStatus: 403
        )
    }

    static func unsupportedResult(action: String) -> MacControlResult {
        let error = "unsupported_mac_control_action: \(action) is not implemented in Swift"
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("unsupported"),
                "error": .string(error),
                "dispatched_via": .string("swift"),
            ]),
            error: error,
            durationMs: 0,
            httpStatus: 501
        )
    }


    // MARK: accessibility perception (read-only)

    /// Resolve the caller-supplied bounds, clamped to the hard ceilings by `MacAXLimits.init`. A caller CANNOT raise the caps, only lower them.
    static func axLimits(from body: [String: JSONValue]) -> MacAXLimits {
        return MacAXLimits(
            maxNodes: body["max_nodes"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacAXLimits.hardMaxNodes,
            maxDepth: body["max_depth"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacAXLimits.hardMaxDepth,
            maxMatches: body["limit"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacAXLimits.hardMaxMatches
        )
    }

    func axUntrustedResult(action: String) -> MacControlResult {
        let error = "accessibility_not_trusted"
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(false),
                "status": .string("not_trusted"),
                "error": .string(error),
                "note": .string(MacAccessibilityReader.notTrustedNote),
            ]),
            error: error,
            durationMs: 0
        )
    }


    // MARK: accessibility injection
    // Policy and approved replay admission do not grant macOS Accessibility; each handler rechecks the system grant.

    func injectionRefusal(
        action: String,
        error: String,
        status: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) -> MacControlResult {
        var output: [String: JSONValue] = [
            "ok": .bool(false),
            "status": .string("failed"),
            "error": .string(error),
        ]
        for (key, value) in extra { output[key] = value }
        return MacControlResult(
            ok: false,
            action: action,
            output: .object(output),
            error: error,
            durationMs: 0,
            httpStatus: status
        )
    }

    /// Injection requires trust from the act source, never the read source, plus an available sink when posting events.
    func injectionPreconditions(action: String, requiresSink: Bool) -> MacControlResult? {
        guard accessibilityActSource.isTrusted() else {
            return injectionRefusal(
                action: action,
                error: "accessibility_not_trusted",
                extra: ["note": .string(MacAccessibilityReader.notTrustedNote)]
            )
        }
        if requiresSink, !eventSink.isAvailable {
            return injectionRefusal(action: action, error: "event_injection_unavailable")
        }
        return nil
    }

    /// Shared refusal for an injection call that failed the approval gate. Mirrors the shape the old in-band check produced (403 + block receipt) so nothing downstream has to learn a new refusal form.
    func injectionApprovalRefusal(
        action: String,
        reason: String,
        body: [String: JSONValue]
    ) async -> MacControlResult {
        let result = Self.refusalResult(action: action, reason: reason, now: now)
        if let provider = policyProvider, let policy = await provider.currentPolicy() {
            await emitBlockedAudit(
                action: action,
                category: macControlGateCategory(forAction: action) ?? "accessibility",
                reason: reason,
                trigger: body["trigger"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "user",
                policy: policy,
                body: body
            )
        }
        return result
    }

    static func handWaitMilliseconds(seconds: Double?) -> Int {
        let finiteSeconds = seconds.flatMap { $0.isFinite ? $0 : nil } ?? 0.6
        // Clamp while still floating point, before multiplication or Int conversion can overflow. The existing hand range stays 0...10s.
        return Int(max(0, min(finiteSeconds, 10)) * 1000)
    }

    static func handDragMilliseconds(seconds: Double?) -> Int {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 240 }
        return Int(max(0.08, min(seconds, 2)) * 1000)
    }

    /// Effect-time human-takeover check shared by every motor sibling.
    func attentionActionRefusal(
        action: String,
        body: [String: JSONValue]
    ) async -> MacControlResult? {
        if let refusal = MacWorkContinuation.current?.refusal() {
            return MacControlResult(ok: false, action: action,
                output: .object(["message": .string(refusal)]), error: "continuation_unavailable",
                durationMs: 0)
        }
        let sessionId = body["attention_session"]?.stringValue
        let userSequence = body["attention_user_sequence"]?.integerValue.flatMap(Int.init(exactly:)).map(Int64.init)
        switch await attentionStore.permissionForAction(
            sessionId: sessionId,
            observedUserSequence: userSequence,
            now: now()
        ) {
        case .allowed:
            return nil
        case .refused(let reason, let current):
            let status: String
            if reason.hasPrefix("human_takeover:") {
                status = "yielded_to_user"
            } else if reason.hasPrefix("scene_changed:") {
                status = "refresh_required"
            } else {
                status = "attention_session_required"
            }
            return MacControlResult(
                ok: false,
                action: action,
                output: .object([
                    "ok": .bool(false),
                    "status": .string(status),
                    "error": .string(reason),
                    "attention": current?.toJSON() ?? .null,
                ]),
                error: reason,
                durationMs: 0,
                httpStatus: 409
            )
        }
    }


}

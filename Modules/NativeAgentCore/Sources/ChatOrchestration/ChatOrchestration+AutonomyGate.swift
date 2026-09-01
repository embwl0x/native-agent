import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox
import MacControl

// MARK: - Autonomy auto-gating for tool dispatch
//
// AutonomyGate sits between SwiftNativeTurnEngine's tool dispatch path and
// the concrete ToolDispatchClient. For each tool call:
//   1. Resolve the autonomy level via TrustCenter.
//   2. Map level → allow / requireApproval / deny.
//   3. If requireApproval and an ApprovalFiler is wired, file a request
//      and await the user's decision (with timeout).
//
// CARVES:
//   * This gate depends on a narrow ApprovalFiler protocol so dispatch code
//     does not need to know which app/core component staged the durable
//     approval record. NativeAgent.app wires the real Swift approval queue and
//     follow-up executor; tests use mocks.
//   * AutonomyResolver protocol lets tests substitute a mock for
//     SwiftNativeTrustCenter; the concrete actor conforms via an extension.

// MARK: - AutonomyDecision

public enum AutonomyDecision: Sendable, Equatable {
    case allow
    case requireApproval(reason: String)
    case deny(reason: String)
}

// MARK: - Errors

public enum AutonomyGateError: Error, LocalizedError, Equatable {
    case toolDenied(reason: String)
    case noApprovalInboxWired
    case approvalTimeout(toolName: String, seconds: Double)
    case approvalFilingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolDenied(let r): return "tool denied: \(r)"
        case .noApprovalInboxWired: return "approval required but no ApprovalFiler wired"
        case .approvalTimeout(let t, let s): return "approval for \(t) timed out after \(s)s"
        case .approvalFilingFailed(let m): return "approval filing failed: \(m)"
        }
    }
}

// MARK: - AutonomyResolver

/// Narrow protocol so tests can substitute the trust source without
/// constructing a full SwiftNativeTrustCenter actor.
public protocol AutonomyResolver: Sendable {
    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String
}

/// Optional trust-aware refinement used only after SecurityCenter has
/// authenticated the concrete conversation origin. Keeping this separate from
/// `AutonomyResolver` preserves lightweight test/custom resolvers while letting
/// Full Mac YOLO distinguish an allowlisted Telegram/iOS/Slack caller from an
/// untrusted caller on the same nominal surface.
public protocol OriginAwareAutonomyResolver: AutonomyResolver {
    func autonomyLevel(
        forTool toolName: String,
        surface: String,
        originTrusted: Bool
    ) async throws -> String
}

extension SwiftNativeTrustCenter: OriginAwareAutonomyResolver {
    public func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        try await autonomyLevel(forTool: toolName, surface: surface, originTrusted: false)
    }

    public func autonomyLevel(
        forTool toolName: String,
        surface: String,
        originTrusted: Bool
    ) async throws -> String {
        // Resolve the normalized policy and raw user-only overrides from one
        // checked authority generation. Two independent reads could otherwise
        // splice a just-revoked override with the prior broad posture.
        let authorization = try await self.loadAuthorizationSnapshotChecked()
        let policy = authorization.policy
        // 2026-07-21 audit fix: an explicit USER-SET "blocked" entry
        // OUTRANKS the broad yolo/full-Mac posture — previously an active
        // yolo window silently flattened even a deliberate user-set
        // "blocked". confirm/send_approval stay flattened (pinned behavior);
        // consult the RAW user file, NOT the merged policy: merged code
        // defaults would masquerade as explicit entries.
        let yoloAuthority = SwiftNativeSecurityCenter.fullMacYoloAuthority(
            tool: toolName,
            surface: surface,
            originTrusted: originTrusted,
            snapshot: authorization
        )
        if yoloAuthority.admitted {
            return "auto"
        }
        // SwiftNativeTrustCenter stores tool autonomy under `toolAutonomy`;
        // autonomyForTool reads overrides from `autonomyOverrides`. Bridge.
        var bundle: [String: JSONValue] = [:]
        if case .object(let ta)? = policy["toolAutonomy"] {
            bundle["autonomyOverrides"] = .object(ta)
        }
        if case .string(let def)? = policy["autonomyDefault"] {
            bundle["autonomyDefault"] = .string(def)
        }
        return self.autonomyForTool(toolName, policy: bundle)
    }
}

// MARK: - ApprovalFiler

/// Narrow protocol for staging an approval request and awaiting the user's
/// decision. Kept separate from ApprovalInboxProtocol because the latter
/// only exposes list/get/resolve/archive on the SwiftNative side today.
public protocol ApprovalFiler: Sendable {
    /// Stage an approval request. Returns the new record's id.
    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String

    /// Poll/await resolution for the given approval id.
    func awaitResolution(id: String) async throws -> ApprovalDecision
}

/// Optional extension point for surfaces that cannot safely block their
/// transport loop while waiting for a human decision. The filer still stages a
/// durable approval request, but the dispatcher returns this tool result
/// immediately instead of awaiting resolution in the current turn.
public protocol NonBlockingApprovalFiler: ApprovalFiler {
    func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue
}

// MARK: - AutonomyGate

public actor AutonomyGate {
    private let trust: any AutonomyResolver
    private let filer: (any ApprovalFiler)?

    public init(
        trust: any AutonomyResolver,
        approvalFiler: (any ApprovalFiler)? = nil
    ) {
        self.trust = trust
        self.filer = approvalFiler
    }

    public func decide(toolName: String, surface: String) async throws -> AutonomyDecision {
        let level = try await trust.autonomyLevel(forTool: toolName, surface: surface)
        return Self.map(level: level)
    }

    public func autonomyLevel(toolName: String, surface: String) async throws -> String {
        try await trust.autonomyLevel(forTool: toolName, surface: surface)
    }

    public func autonomyLevel(
        toolName: String,
        surface: String,
        originTrusted: Bool
    ) async throws -> String {
        if let originAware = trust as? any OriginAwareAutonomyResolver {
            return try await originAware.autonomyLevel(
                forTool: toolName,
                surface: surface,
                originTrusted: originTrusted
            )
        }
        return try await trust.autonomyLevel(forTool: toolName, surface: surface)
    }

    /// File an approval request and await its resolution. Returns the final
    /// decision (allow on approved, deny on denied/canceled). On timeout,
    /// returns .deny (NOT throws) — matches spec.
    public func resolveWithApproval(
        toolName: String,
        surface: String,
        requestPayload: JSONValue,
        timeoutSeconds: Double = 300,
        reason: String? = nil
    ) async throws -> AutonomyDecision {
        try await resolveWithApprovalDetailed(
            toolName: toolName,
            surface: surface,
            requestPayload: requestPayload,
            timeoutSeconds: timeoutSeconds,
            reason: reason
        ).decision
    }

    /// Same flow, but also hands back the APPROVAL RECORD ID.
    ///
    /// W2/W3-FIX 1/2 need it: a `MacInjectionCapability` is minted from a
    /// specific resolved approval, and "which approval authorized this
    /// keystroke" has to be answerable from the capability itself, not inferred.
    /// `resolveWithApproval` above keeps its original signature so no existing
    /// caller changes.
    public func resolveWithApprovalDetailed(
        toolName: String,
        surface: String,
        requestPayload: JSONValue,
        timeoutSeconds: Double = 300,
        reason: String? = nil
    ) async throws -> (decision: AutonomyDecision, approvalID: String?) {
        guard let filer else {
            throw AutonomyGateError.noApprovalInboxWired
        }
        let level = try await trust.autonomyLevel(forTool: toolName, surface: surface)
        // 2026-07-21 gpt-5.5 review: carry the CALLER's reason (a security
        // .ask's injection-shield reason, a PersonaWriteGuard reason) into
        // the filed record — composing "autonomy=\(level)" here erased it.
        let resolvedReason = reason ?? "autonomy=\(level)"
        let id: String
        do {
            id = try await filer.fileApprovalRequest(
                toolName: toolName,
                surface: surface,
                payload: requestPayload,
                reason: resolvedReason
            )
        } catch {
            throw AutonomyGateError.approvalFilingFailed(String(describing: error))
        }

        let nanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let decision = await withTaskGroup(of: AutonomyDecision?.self) { group in
            group.addTask {
                do {
                    let decision = try await filer.awaitResolution(id: id)
                    switch decision {
                    case .approved: return .allow
                    case .denied:   return .deny(reason: "approval denied")
                    case .canceled: return .deny(reason: "approval canceled")
                    }
                } catch {
                    return .deny(reason: "approval await failed: \(error)")
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil  // timeout sentinel
            }
            var result: AutonomyDecision = .deny(reason: "approval timeout")
            if let first = await group.next(), let decided = first {
                result = decided
            }
            group.cancelAll()
            return result
        }
        return (decision, id)
    }

    // MARK: - level mapping

    nonisolated static func map(level: String) -> AutonomyDecision {
        let allowed: Set<String> = ["auto", "app_data_autonomous", "workspace_autonomous"]
        let approval: Set<String> = ["supervised", "confirm", "send_approval", "destructive_strong"]
        let denied: Set<String> = ["deny", "blocked"]
        if allowed.contains(level) { return .allow }
        if approval.contains(level) { return .requireApproval(reason: "autonomy=\(level)") }
        if denied.contains(level) { return .deny(reason: "autonomy=\(level)") }
        return .requireApproval(reason: "autonomy=\(level) (unknown level — safe default)")
    }
}

// MARK: - SwiftNativeTurnEngine extension
//
// The engine stores its ToolDispatchClient privately. To avoid touching
// ChatOrchestration+TurnEngine.swift we expose a variant that accepts the
// dispatch client explicitly — callers construct the gate, pass both, and
// the engine routes through the gate's decision.

extension SwiftNativeTurnEngine {
    public func dispatchToolWithAutonomyGate(
        toolName: String,
        toolInput: [String: JSONValue],
        surface: String,
        tools: any ToolDispatchClient,
        gate: AutonomyGate
    ) async throws -> JSONValue {
        let decision = try await gate.decide(toolName: toolName, surface: surface)
        switch decision {
        case .allow:
            return try await tools.dispatch(tool: toolName, input: toolInput, surface: surface)
        case .deny(let reason):
            throw AutonomyGateError.toolDenied(reason: reason)
        case .requireApproval:
            let resolved = try await gate.resolveWithApproval(
                toolName: toolName,
                surface: surface,
                requestPayload: .object(toolInput)
            )
            switch resolved {
            case .allow:
                return try await tools.dispatch(tool: toolName, input: toolInput, surface: surface)
            case .deny(let reason):
                throw AutonomyGateError.toolDenied(reason: reason)
            case .requireApproval(let reason):
                throw AutonomyGateError.toolDenied(reason: reason)
            }
        }
    }
}

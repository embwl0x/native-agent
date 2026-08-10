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
        let policy = await self.loadTrustPolicy()
        // 2026-07-21 audit fix: an explicit USER-SET "blocked" entry
        // OUTRANKS the broad yolo/full-Mac posture — previously an active
        // yolo window silently flattened even a deliberate user-set
        // "blocked". confirm/send_approval stay flattened (pinned behavior);
        // consult the RAW user file, NOT the merged policy: merged code
        // defaults would masquerade as explicit entries.
        let userOverrides = await self.userConfiguredAutonomyOverrides()
        let hasExplicitBlock = Self.hasExplicitBlockOverride(toolName, overrides: userOverrides)
        if !hasExplicitBlock,
           Self.fullMacPolicyAllows(
            toolName: toolName,
            surface: surface,
            originTrusted: originTrusted,
            policy: policy
        ) {
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

    private nonisolated static func fullMacPolicyAllows(
        toolName: String,
        surface: String,
        originTrusted: Bool,
        policy: [String: JSONValue]
    ) -> Bool {
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policy)
        guard let trust = macPolicy.trustPolicy,
              MacControlGate.fullMacActive(trust) else {
            return false
        }
        guard !isFullMacYoloAutonomyExcludedTool(toolName) else {
            return false
        }

        // Do not let category-specific MacControl policy accidentally promote
        // an unauthenticated remote caller before the broad fallback below.
        // SecurityCenter supplies this proof from the concrete transport
        // identity; the string "telegram"/"ios"/"slack" is never sufficient.
        if ConversationSurfaceProfile(surface).isRemote && !originTrusted {
            return false
        }

        let normalizedTool = normalizedFullMacToolName(toolName)

        // App lifecycle tools (restart_app / install_app) are how Agent applies
        // a completed Swift fix to the running Mac app. In production this
        // autonomy resolver runs AFTER SecurityCenter has proven remote chat
        // origins (Telegram allowlist / paired iOS/iCloud family) and blocked
        // strangers. The resolver itself only sees `surface`, so keep this
        // chat-surface bypass narrow to lifecycle tools; builder shells still
        // follow the local/team surface rule below unless policy explicitly
        // promotes them.
        if isAppLifecycleTool(normalizedTool) {
            return isYoloEligibleSurface(surface, originTrusted: originTrusted)
        }

        // Builder process tools (shell/bash/git/apply_patch/run_tests +
        // fixed-argv swift_build/swift_test) follow the same active Full Mac
        // posture on local surfaces and on remote origins already authenticated
        // by SecurityCenter. The origin proof is mandatory; a surface label by
        // itself never unlocks a process tool.
        //
        // Self-modification tools (self_install / evolution_*) are NOT builder
        // tools, never hit this branch, and stay confirm at L5.
        if isBuilderProcessTool(toolName) {
            return isYoloEligibleSurface(surface, originTrusted: originTrusted)
        }

        let category = fullMacCategory(forToolName: normalizedTool)
        if let category,
           MacControlGate.gate(
               macPolicy,
               category: category,
               trigger: fullMacTrigger(forSurface: surface)
           ).allowed {
            return true
        }

        // Full Mac yolo is the local/team trust posture, not a fragile
        // per-tool allowlist. If the active yolo window is present and the tool
        // is not one of the deliberate approval floors above, avoid falling
        // back to stale/missing toolAutonomy entries.
        return isYoloEligibleSurface(surface, originTrusted: originTrusted)
    }

    /// Full Mac YOLO is a user-selected autonomy posture, not a Mac-window-only
    /// transport feature. Local/team surfaces are eligible directly. Remote
    /// conversation surfaces are eligible only when SecurityCenter has already
    /// authenticated the exact origin (Telegram allowlist, paired mobile
    /// identity, verified Slack origin, and so on). Unknown or untrusted remote
    /// callers still fall through to per-tool policy and approval.
    private nonisolated static func isYoloEligibleSurface(
        _ surface: String,
        originTrusted: Bool
    ) -> Bool {
        if isLocalInteractiveSurface(surface) { return true }
        return originTrusted && isInteractiveChatSurface(surface)
    }

    /// True iff `toolName` is one of the Process-spawn builder tools
    /// (`SwiftToolDispatcher.fullMacBuilderToolNames`), tolerant of the
    /// `mac.` / `mac_` catalog-prefix variants — the same catalog-drift
    /// normalization used elsewhere. Single source of truth is the
    /// dispatcher's own list, so adding a builder tool there auto-covers
    /// this elevation path.
    private nonisolated static func isBuilderProcessTool(_ toolName: String) -> Bool {
        let lower = toolName.lowercased()
        let base = (lower.hasPrefix("mac.") || lower.hasPrefix("mac_"))
            ? String(lower.dropFirst(4))
            : lower
        return SwiftToolDispatcher.fullMacBuilderToolNames.contains(base)
    }

    /// Surfaces that may use an active Full Mac yolo window as a broad builder
    /// autonomy-auto posture. Remote chat surfaces and any other/unknown
    /// surface return false for builder tools — fail-safe to confirm — so
    /// arbitrary shell can't auto-fire from the phone, Telegram, or an
    /// unrecognized caller.
    private nonisolated static func isLocalInteractiveSurface(_ surface: String) -> Bool {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chat", "codex-bridge", "claude-bridge":
            return true
        // Wave 5b: the three Workshop spellings now come from
        // `WorkshopSurfaceVocabulary.gateSpellings` instead of being open-coded.
        // Identical membership ("workshop"/"missions"/"mission"), identical
        // result — the surface is already trimmed+lowercased by the switch
        // subject, and `isWorkshopGateSurface` trims+lowercases again.
        case let s where WorkshopSurfaceVocabulary.isWorkshopGateSurface(s):
            // Executions run LOCALLY on the Mac and only when the execution
            // executor's own gate is on (enableAutonomy + missionPolicy via
            // workshopExecutorGate), AND builder elevation here is already
            // behind MacControlGate.fullMacActive (yolo) above. So an execution
            // builder step (shell/git/apply_patch/run_tests/swift_build/
            // swift_test) under full-mac
            // yolo is the SAME trust surface as local chat — elevate it. This
            // is NOT a remote surface (remote chat stays confirm-class for
            // builder shell tools), so it can't let a remote message spawn a
            // shell (2026-06-15, the user: full-mac yolo, "executions do everything").
            return true
        default:
            return false
        }
    }

    private nonisolated static func isInteractiveChatSurface(_ surface: String) -> Bool {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "chat", "codex-bridge", "claude-bridge",
             "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile", "watch", "remote":
            return true
        // Wave 5b: Workshop spellings via the vocabulary (same three strings).
        case let s where WorkshopSurfaceVocabulary.isWorkshopGateSurface(s):
            return true
        default:
            return false
        }
    }

    private nonisolated static func isAppLifecycleTool(_ toolName: String) -> Bool {
        toolName == "restart_app" || toolName == "install_app"
    }

    private nonisolated static func isFullMacYoloAutonomyExcludedTool(_ toolName: String) -> Bool {
        let normalized = normalizedFullMacToolName(toolName)
        if [
            "self_install",
            "evolution_propose",
            "evolution_status",
            // A trusted remote node is a separate effect domain. Full-Mac
            // posture on this Mac must never silently authorize execution on
            // that host; the exact command keeps its explicit approval floor.
            "remote_node_execute",
        ].contains(normalized) {
            return true
        }

        let externalAccountWriteTools: Set<String> = [
            "gmail.send",
            "email.send",
            "agentmail.send",
            "agentmail_send",
            "slack.post_message",
            "slack_post_message",
            "x.post_tweet",
            "calendar.cancel_event",
            "github.set_repo_visibility",
            "github_set_repo_visibility",
            "github.mutate",
            "github_mutate",
        ]
        return externalAccountWriteTools.contains(normalized)
    }

    private nonisolated static func normalizedFullMacToolName(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private nonisolated static func fullMacTrigger(forSurface surface: String) -> String {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "icloud", "iphone", "ipad", "mobile", "watch":
            return "ios"
        default:
            return "user"
        }
    }

    private nonisolated static func fullMacCategory(forToolName toolName: String) -> String? {
        switch toolName {
        case "read_file", "list_dir", "file_excerpt", "write_file", "grep",
             "git_status", "git_diff", "git_log", "repo_dirty_summary",
             "mac.read_file", "mac.list_directory", "mac.write_file":
            return "file_ops"
        case "system_info":
            return "system"
        case "mac_focus_app", "mac_quit_app":
            return "accessibility"
        default:
            return nil
        }
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
        return await withTaskGroup(of: AutonomyDecision?.self) { group in
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

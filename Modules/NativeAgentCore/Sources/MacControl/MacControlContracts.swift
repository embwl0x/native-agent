import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// Blueprint: | `MacControlContracts.swift` | `MacControlResult`, `MacControlClient`, `MacMotorCount` and action families: dispatch receipts, read/effect classification, shared policy categories and policy-provider contract |

public struct MacControlResult: Sendable, Equatable {
    public let ok: Bool
    public let action: String
    public let output: JSONValue
    public let error: String?
    public let durationMs: Int
    /// Status code hint for refusal/unsupported results. Successful native
    /// in-process results leave this nil.
    public let httpStatus: Int?
    /// Durable payload-free operation identity. Present when a canonical
    /// MacControlOperationStore owns this dispatch.
    public let operationId: String?
    public let operationState: MacControlOperationState?
    public let verification: MotorVerificationState?
    public let nativePage: NativePage?

    public init(
        ok: Bool,
        action: String,
        output: JSONValue,
        error: String?,
        durationMs: Int,
        httpStatus: Int? = nil,
        operationId: String? = nil,
        operationState: MacControlOperationState? = nil,
        verification: MotorVerificationState? = nil,
        nativePage: NativePage? = nil
    ) {
        self.ok = ok
        self.action = action
        self.output = output
        self.error = error
        self.durationMs = durationMs
        self.httpStatus = httpStatus
        self.operationId = operationId
        self.operationState = operationState
        self.verification = verification ?? output.objectValue?["verification"]?.stringValue.flatMap(MotorVerificationState.init(rawValue:))
        self.nativePage = nativePage
    }

    public func toJSON() -> JSONValue {
        var fields: [String: JSONValue] = [
            "status": .string(!ok ? "failed" : output.objectValue?["partial"] == .bool(true) ? "partial" : "completed"),
            "partial": .bool(output.objectValue?["partial"] == .bool(true)),
            "ok": .bool(ok),
            "action": .string(action),
            "output": output,
            "error": error.map { .string($0) } ?? .null,
            "durationMs": .int(Int64(durationMs)),
            "httpStatus": httpStatus.map { .int(Int64($0)) } ?? .null,
            "operationId": operationId.map { .string($0) } ?? .null,
            "operationState": operationState.map { .string($0.rawValue) } ?? .null,
            "verification": verification.map { .string($0.rawValue) } ?? .null,
        ]
        if !ok, case .object(let output) = output, let remedy = output["remedy"] { fields["remedy"] = remedy }
        let result = JSONValue.object(fields)
        OwnedProgramRunner.ReadContent.current?.record(result,
            content: .object(fields.filter { !["durationMs", "operationId"].contains($0.key) }))
        return result
    }
}

public struct MacControlCancellationResult: Sendable, Equatable {
    public let operationId: String
    public let state: MacControlOperationState
    /// True only once the underlying work has stopped. A mere signal/request
    /// returns false and remains `cancel_requested`.
    public let acknowledged: Bool

    public init(operationId: String, state: MacControlOperationState, acknowledged: Bool) {
        self.operationId = operationId
        self.state = state
        self.acknowledged = acknowledged
    }
}

// MARK: - Errors

public enum MacControlError: Error, Sendable, Equatable, LocalizedError {
    case unknownAction(String)
    case missingField(String)
    case sensitivePathDenied(String)
    case appControlFailed(String)
    case applescriptFailed(String)
    case notificationFailed(String)
    case malformedResponse(String)
    case ioFailure(String)
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let a): return "unknown_mac_action: \(a). Choose a supported action from app {find:\"Mac\"}."
        case .missingField(let f): return "missing_field: \(f). Supply this field in the action's args; use app {find:\"Mac\"} for its accepted shape."
        case .sensitivePathDenied(let p): return "sensitive_path_denied: \(p). Choose a path outside protected app data in the action's path argument; this boundary cannot be bypassed."
        case .appControlFailed(let s): return "app_control_failed: \(s). Inspect the affected app with mac.look before another action."
        case .applescriptFailed(let s): return "applescript_failed: \(s). Correct the reported script or per-app Automation grant before execution; inspect the affected app with mac.look for possible effects."
        case .notificationFailed(let s): return "notification_failed: \(s). Inspect NativeAgent's notification settings in System Settings > Notifications > NativeAgent before deciding whether another send is appropriate."
        case .malformedResponse(let s): return "malformed_mac_response: \(s). Inspect the affected app with mac.look; repair the response producer before another action."
        case .ioFailure(let s): return "mac_io_failed: \(s). Inspect the named path with files.info and correct the reported file-access cause before another write."
        case .operation(let s): return "mac_operation_failed: \(s). Inspect the affected app with mac.look before another action; preserve mac_control/operations.json while repairing the reported operation-store cause."
        }
    }
}

// MARK: - Protocol

public protocol MacControlClient: MotorActionReadModelProviding, Sendable {
    /// Dispatch a MacControl action with the shared JSON body accepted by native and iOS callers.
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult
    func cancel(operationId: String) async throws -> MacControlCancellationResult

    /// Explicit approved injection carries capability authority separately from ordinary dispatch.
    func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability
    ) async throws -> MacControlResult
}

/// A client that counts what it let out that can change the world: every
/// action outside the reads that the gate did not refuse before it ran. A
/// verb that failed with none counted changed nothing, whatever its error
/// says; one counted may have. A read that woke a covered screen or stepped
/// her own windows aside changed nothing, as every read says.
public final class MacMotorCount: MacControlClient, @unchecked Sendable {
    private let host: any MacControlClient
    private let lock = NSLock()
    private var count = 0
    public init(_ host: any MacControlClient) { self.host = host }
    public var started: Int { lock.withLock { count } }

    public func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        try await counted(action) { try await self.host.dispatch(action: action, body: body) }
    }

    public func dispatchApprovedInjection(
        action: String, body: [String: JSONValue], capability: MacInjectionCapability
    ) async throws -> MacControlResult {
        try await counted(action) { try await self.host.dispatchApprovedInjection(action: action, body: body, capability: capability) }
    }

    public func cancel(operationId: String) async throws -> MacControlCancellationResult {
        try await host.cancel(operationId: operationId)
    }

    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        try await host.motorActionReadModel(actionId: actionId)
    }

    private func counted(_ action: String, _ run: () async throws -> MacControlResult) async throws -> MacControlResult {
        let name = action.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !macControlLiveReadActions.contains(name) else { return try await run() }
        do {
            let result = try await run()
            if result.operationState != .refused, result.operationState != .blocked { lock.withLock { count += 1 } }
            return result
        } catch {
            lock.withLock { count += 1 }
            throw error
        }
    }
}

// MARK: - Sub-action classification

/// Every accepted route, including known unsupported routes that return 501.
public let macControlDispatchableActions: Set<String> = Set([
    "notify",
    "applescript",
    "volume",
    "media",
    "file/read",
    "file/write",
    "file/list",
    "file/move",
    "file/trash",
    "focus_app",
    "quit_app",
    "spotlight",
    "shell",
    "keystroke",
    "click",
])
    .union(macControlUnsupportedActions)
    .union(macControlAccessibilityReadActions)
    .union(macControlAccessibilityActActions)
    .union(macControlAppNavigationActions)
    .union(macControlAccessibilityNudgeActions)
    .union(macControlClipboardActions)
    .union(macControlDocumentReadActions)

/// Live reads share dispatch and motor-count classification; policy admission
/// remains with each action's existing category.
public var macControlLiveReadActions: Set<String> {
    macControlAccessibilityReadActions.union(macControlClipboardReadActions)
        .union(macControlDocumentReadActions).union(["file/read", "file/list", "spotlight"])
}

/// Known MacControl actions that are intentionally not implemented in Swift
/// yet. They fail closed with a Swift 501 result rather than proxying.
public let macControlUnsupportedActions: Set<String> = [
    "jxa",
    "shortcut",
    "shortcut/run",
    "system",
    "self_test",
]

/// Read-only accessibility perception actions.
///
/// They are perception only: no CGEvent, no AXUIElementPerformAction, no
/// attribute writes. Gate category is `accessibility` (same category as
/// keystroke/click) but they are READ tier — no approval, mirroring how
/// `spotlight` reads are gated but unapproved.
/// The client may first clear a covering saver with the shared inert wake;
/// the read handlers themselves still emit no input or app mutation.
public let macControlAccessibilityReadActions: Set<String> = [
    "ax_status",
    "ax_tree",
    "ax_find",
    // Fused AX/pixel perception is read tier; Screen Recording is a separate system grant.
    "view",
    // Semantic perception is read tier and requires no Screen Recording grant.
    "look",
    // Explicit, bounded continuity over the same fused view. It passively
    // notices coarse physical input and scene changes while active, never key
    // contents, and returns a fresh redacted fused view on start/next.
    "attention",
    // Menu discovery reads AXMenuBar without opening or pressing any item.
    "menu",
]

/// Accessibility actions beyond basic keystroke/click. The injection predicate
/// below includes those two physical actions as well.
public let macControlAccessibilityActActions: Set<String> = [
    "scroll",
    "ax_act",
    // Closed-loop acts mutate through the same actuator; returning perception does not make an act read tier.
    "act",
    // Internal physical owner for the four-verb surface. `act` resolves a
    // fresh name/ordinal first; `hand` executes the resulting bounded plan.
    "hand",
    // Explicit wake emits inert HID input and remains in the injection action family.
    "wake",
    // Pressing a menu item invokes its handler and stays separate from menu discovery's read authority.
    "menu_press",
]

/// App navigation changes presentation without synthesizing input; Full Mac app-control policy and canonical operation ownership still apply.
public let macControlAppNavigationActions: Set<String> = [
    "open_target",
]

/// EVERY action that synthesizes input or mutates another app's UI state.
/// Policy, Full Mac, TCC and driver admission apply. Explicit approved replays
/// also validate and consume their body-bound single-use capability.
/// Adding an action here is what makes it injection; forgetting to would let a
/// new act slip in at read tier.
public let macControlAccessibilityInjectionActions: Set<String> =
    macControlAccessibilityActActions.union(["keystroke", "click"])

/// A nudge posts one bare pointer move, without buttons, keys or app mutation.
/// It shares the reads' Accessibility/Full Mac gate, but not their no-input
/// contract or the mutation set's explicit approved-replay capability path.
/// A nudge that grows a button or key belongs in the injection set.
public let macControlAccessibilityNudgeActions: Set<String> = [
    "nudge",
]

/// Every action that can move his cursor, keys, focus or screen: it yields to
/// him at entry and on its result. A script is here because a script can
/// drive the GUI; its whole run is tracked by `handleAppleScript`.
public let macControlTakeoverActions: Set<String> = macControlAccessibilityInjectionActions
    .union(macControlAccessibilityNudgeActions)
    .union(["focus_app", "quit_app", "open_target", "applescript"])

/// Clipboard reads emit no input, redact their contents and share the Accessibility category without claiming an AX walk.
public let macControlClipboardReadActions: Set<String> = [
    "clipboard_read",
]

/// The WRITE half. It synthesizes no input and mutates no other app's UI
/// state, so it is deliberately not in `macControlAccessibilityInjectionActions`
/// (it needs no `MacInjectionCapability`) — but it does change the world: the
/// next ⌘V in any app pastes what it put there. So it goes through the durable
/// motor-operation lane like every other action that changes something, and
/// the tool layer gates it on app-control authority rather than on read.
public let macControlClipboardWriteActions: Set<String> = [
    "clipboard_write",
]

public let macControlClipboardActions: Set<String> =
    macControlClipboardReadActions.union(macControlClipboardWriteActions)

/// Document accumulation may aim the cursor and scroll vertically with observed restoration; presses, keys, AX actions or arbitrary scrolling require injection authority. Named-file reads also clear file policy.
public let macControlDocumentReadActions: Set<String> = [
    "read",
]

/// Existing action families supply their shared policy category.
public func macControlGateCategory(forAction action: String) -> String? {
    if macControlAccessibilityReadActions.contains(action)
        || macControlAccessibilityInjectionActions.contains(action)
        || macControlAccessibilityNudgeActions.contains(action)
        || macControlAppNavigationActions.contains(action)
        || macControlClipboardActions.contains(action)
        || macControlDocumentReadActions.contains(action) { return "accessibility" }
    switch action {
    case "applescript":                                   return "applescript"
    case "jxa":                                           return "jxa"
    case "shortcut", "shortcut/run":                      return "shortcuts"
    case "focus_app", "quit_app":                          return "accessibility"
    case "system", "volume", "media":                     return "system"
    case "file/read", "file/write", "file/list",
         "file/move", "file/trash":                       return "file_ops"
    case "notify":                                        return "notifications"
    case "shell":                                         return "shell"
    case "spotlight":                                     return "spotlight"
    default:                                              return nil
    }
}

/// Return the file path body keys the gate must check, or an empty array for non-file actions.
public func macControlFilePolicyPathKeys(forAction action: String) -> [String] {
    switch action {
    case "file/read", "file/write", "file/list", "file/trash": return ["path"]
    case "file/move": return ["src", "dst"]
    // A document read naming a file shares file/read's workspace-root policy and sensitive-path precedence.
    case "read": return ["path"]
    default: return []
    }
}

// MARK: - Live policy

/// Production dispatch reads TrustCenter policy before native execution; direct library callers may omit the provider.
public protocol MacControlPolicyProvider: Sendable {
    /// Return the current policy, or nil if it can't be resolved (in which
    /// case production callers fail closed before any side effect. Tests can
    /// omit the provider when they need to exercise a handler directly.
    func currentPolicy() async -> MacControlPolicy?
    /// The one authorization decision for a raw dispatch of `tool` (the
    /// action): the level (`auto`, `confirm`, `blocked`), reason and lever.
    /// Nil: nothing more to decide, or the door that built this provider
    /// already consumed that decision.
    func authorize(tool: String, input: [String: JSONValue]) async -> (level: String, reason: String, remedy: JSONValue?)?
}

public extension MacControlPolicyProvider {
    func authorize(tool: String, input: [String: JSONValue]) async -> (level: String, reason: String, remedy: JSONValue?)? { nil }
}

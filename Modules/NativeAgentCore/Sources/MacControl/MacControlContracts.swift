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

// Blueprint: | `MacControlContracts.swift` | `MacControlResult`, `MacControlClient`, `MacMotorCount`: Dispatch receipts and policy categories |

public struct MacControlResult: Sendable, Equatable {
    public let ok: Bool
    public let action: String
    public let output: JSONValue
    public let error: String?
    public let durationMs: Int
    /// Status code hint for refusal/unsupported results. Successful native in-process results leave this nil.
    public let httpStatus: Int?
    /// Durable payload-free operation identity. Present when a canonical MacControlOperationStore owns this dispatch.
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

    public func toJSON(readContent: OwnedProgramRunner.ReadContent?) -> JSONValue {
        let outputFields = output.objectValue ?? [:]
        var fields: [String: JSONValue] = [
            "status": outputFields["status"] ?? .string(!ok ? "failed" : outputFields["partial"] == .bool(true) ? "partial" : "completed"),
            "partial": .bool(outputFields["partial"] == .bool(true)),
            "ok": .bool(ok),
            "action": .string(action),
            "output": output,
            "durationMs": .int(Int64(durationMs)),
            "httpStatus": httpStatus.map { .int(Int64($0)) } ?? .null,
            "operationId": operationId.map { .string($0) } ?? .null,
            "operationState": operationState.map { .string($0.rawValue) } ?? .null,
            "verification": verification.map { .string($0.rawValue) } ?? .null,
        ]
        fields["error"] = error.map(JSONValue.string)
        // Owners supply receipt facts through the same projection for every action.
        for key in ["delivery", "effects", "recorded", "delivered", "posted", "deferredUntil", "message", "notificationId"] {
            fields[key] = outputFields[key]
        }
        if !ok, case .object(let output) = output, let remedy = output["remedy"] { fields["remedy"] = remedy }
        let result = JSONValue.object(fields)
        readContent?.record(result,
            content: .object(fields.filter { !["durationMs", "operationId"].contains($0.key) }))
        return result
    }
}

public struct MacControlCancellationResult: Sendable, Equatable {
    public let operationId: String
    public let state: MacControlOperationState
    /// True only once the underlying work has stopped. A mere signal/request returns false and remains `cancel_requested`.
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
        case .sensitivePathDenied(let p): return """
            sensitive_path_denied: \(p). Choose a path outside protected app data in the action's path argument; this boundary cannot be bypassed.
            """
        case .appControlFailed(let s): return "app_control_failed: \(s). Inspect the affected app with mac.look before another action."
        case .applescriptFailed(let s): return """
            applescript_failed: \(s). Correct the reported script or per-app Automation grant before execution; inspect the affected app with mac.look for \
            possible effects.
            """
        case .notificationFailed(let s): return """
            notification_failed: \(s). Inspect NativeAgent's notification settings in System Settings > Notifications > NativeAgent before deciding whether \
            another send is appropriate.
            """
        case .malformedResponse(let s):
            return "malformed_mac_response: \(s). Inspect the affected app with mac.look; repair the response producer before another action."
        case .ioFailure(let s):
            return "mac_io_failed: \(s). Inspect the named path with files.info and correct the reported file-access cause before another write."
        case .operation(let s): return """
            mac_operation_failed: \(s). Inspect the affected app with mac.look before another action; preserve mac_control/operations.json while repairing \
            the reported operation-store cause.
            """
        }
    }
}

// MARK: - Protocol

public protocol MacControlClient: MotorActionReadModelProviding, Sendable {
    /// Native and iOS callers share one body contract so remote dispatch cannot reinterpret actions.
    func dispatch(action: String, body: [String: JSONValue], turn: Turn, context: MacOperationContext) async throws -> MacControlResult
    func cancel(operationId: String) async throws -> MacControlCancellationResult

    /// Explicit approved injection carries capability authority separately from ordinary dispatch.
    func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult
}

/// Count only admitted nonread effects. An uncounted refused action changed nothing; a counted attempt may have. Inert read preparation does not count as an
/// act.
public final class MacMotorCount: MacControlClient, @unchecked Sendable {
    private let host: any MacControlClient
    private let lock = NSLock()
    private var count = 0
    public init(_ host: any MacControlClient) { self.host = host }
    public var started: Int { lock.withLock { count } }

    @concurrent public func dispatch(action: String, body: [String: JSONValue], turn: Turn, context: MacOperationContext) async throws -> MacControlResult {
        try await counted(action) { try await self.host.dispatch(action: action, body: body, turn: turn, context: context) }
    }

    @concurrent public func dispatchApprovedInjection(
        action: String, body: [String: JSONValue], capability: MacInjectionCapability,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult {
        try await counted(action) { try await self.host.dispatchApprovedInjection(action: action, body: body, capability: capability, turn: turn,
            context: context) }
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
        } catch let error as ToolFailureError where error.effects == .none {
            // The owner refused admission, including unavailable launch recovery. Preserve that evidence instead of counting an effect that never ran.
            throw error
        } catch {
            lock.withLock { count += 1 }
            throw error
        }
    }
}

// MARK: - Sub-action classification

/// Include accepted unsupported routes so they return a shaped 501 instead of disappearing at dispatch.
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

/// Live reads share dispatch and motor-count classification; policy admission remains with each action's existing category.
public var macControlLiveReadActions: Set<String> {
    macControlAccessibilityReadActions.union(macControlClipboardReadActions)
        .union(macControlDocumentReadActions).union(["file/read", "file/list", "spotlight"])
}

/// Known unsupported actions fail closed with 501 instead of proxying to another implementation.
public let macControlUnsupportedActions: Set<String> = [
    "jxa",
    "shortcut",
    "shortcut/run",
    "system",
    "self_test",
]

/// AX reads emit no input or actions and remain read tier under the Accessibility category. Active reads may prepare advertised renderer modes and clear a
/// covering saver with the shared inert wake; passive reads never write flags.
public let macControlAccessibilityReadActions: Set<String> = [
    "ax_status",
    "ax_tree",
    "ax_find",
    // Fused AX/pixel perception is read tier; Screen Recording is a separate system grant.
    "view",
    // Semantic perception is read tier and requires no Screen Recording grant.
    "look",
    // Bound observation lifetime and retain only coarse input/scene changes, never key contents; start/next returns a fresh redacted view.
    "attention",
    // Menu discovery reads AXMenuBar without opening or pressing any item.
    "menu",
]

/// Include basic click/keystroke alongside extended AX mutations in injection classification.
public let macControlAccessibilityActActions: Set<String> = [
    "scroll",
    "ax_act",
    // Closed-loop acts mutate through the same actuator; returning perception does not make an act read tier.
    "act",
    // Internal physical owner for the four-verb surface. `act` resolves a fresh name/ordinal first; `hand` executes the resulting bounded plan.
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

/// Every synthesized-input or UI-mutation action belongs here so new acts cannot slip through at read tier. Policy, Full Mac, TCC and driver gates apply;
/// replays also consume their bound capability.
public let macControlAccessibilityInjectionActions: Set<String> =
    macControlAccessibilityActActions.union(["keystroke", "click"])

/// A nudge emits only a bare pointer move and shares read admission without claiming no input. Adding buttons or keys requires injection classification.
public let macControlAccessibilityNudgeActions: Set<String> = [
    "nudge",
]

/// Yield every cursor, keyboard, focus or screen effect to the person. Scripts belong here because they can drive GUI state.
public let macControlTakeoverActions: Set<String> = macControlAccessibilityInjectionActions
    .union(macControlAccessibilityNudgeActions)
    .union(["focus_app", "quit_app", "open_target", "applescript"])

/// Clipboard reads emit no input, redact their contents and share the Accessibility category without claiming an AX walk.
public let macControlClipboardReadActions: Set<String> = [
    "clipboard_read",
]

/// Clipboard writes need durable motor ownership and app-control admission because they change the next paste, even without synthesizing input or mutating
/// another app's UI.
public let macControlClipboardWriteActions: Set<String> = [
    "clipboard_write",
]

public let macControlClipboardActions: Set<String> =
    macControlClipboardReadActions.union(macControlClipboardWriteActions)

/// Document accumulation may aim the cursor and scroll vertically with observed restoration; presses, keys, AX actions or arbitrary scrolling require injection
/// authority. Named-file reads also clear file policy.
public let macControlDocumentReadActions: Set<String> = [
    "read",
]

/// Share category ownership across action families so policy classification cannot drift per caller.
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

/// Return no path keys for nonfile actions so unrelated body fields cannot enter file-policy checks.
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
    /// Return checked current policy; preserve authority failures as errors.
    func currentPolicy(turn: Turn) async throws -> MacControlPolicy
    /// Use one raw-dispatch authorization decision for level, reason and remedy. Nil means no further decision is owed or the supplying door already consumed
    /// it.
    func authorize(tool: String, input: [String: JSONValue], turn: Turn) async -> (level: String, reason: String, remedy: JSONValue?)?
}

public extension MacControlPolicyProvider {
    func authorize(tool: String, input: [String: JSONValue], turn: Turn) async -> (level: String, reason: String, remedy: JSONValue?)? { nil }
}

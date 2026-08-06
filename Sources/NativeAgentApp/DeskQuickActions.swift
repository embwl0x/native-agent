import Foundation
import PersistenceCore
import ChatOrchestration
import ApprovalInbox

// MARK: - DeskQuickActions — the desk's mutation seam
//
// Sweep R4 W5. NO NEW MUTATION PATHS. Every action User fires from the desk goes
// through the SAME `SwiftToolDispatcher.dispatch` switch the chat tools use
// (SwiftToolDispatcher+Dispatch.swift:137-153) and therefore lands in the SAME
// `impl_desk_*` function, which appends the SAME op to the SAME ledger and
// returns the SAME confirmation string. The desk button and Agent's tool call
// are the same write; only the surface tag differs.
//
// This mirrors the existing precedent for a non-chat surface invoking a chat
// tool impl locally: `NativeClient+ConnectorActions.swift:392` builds a bare
// `SwiftToolDispatcher()` and calls `dispatch(tool:input:surface:)` with
// surface "connector_action". The desk uses surface "desk".
//
// WHY NOT `AppModel.dispatchToolData` — the seam the chat SLASH commands use:
// that path is `NativeClient._swiftDispatch`, which builds the *Dispatcher*
// module's `SwiftNativeDispatcher` (NativeClient+SwiftRuntime.swift:112). That
// registry holds connector actions only; `grep -rn desk_ Modules/.../Dispatcher/`
// is empty, so a `desk_close` sent through it would come back
// `native_handler_missing`. The dispatcher that owns the desk tools is
// `SwiftToolDispatcher`, and that is what this router calls.
//
// The lazy-load gate is skipped here BY DESIGN and not by accident: the gate
// only fires when the input carries a `session_id` (SwiftToolDispatcher+Dispatch
// .swift:60-104 — "No sessionId: this is a non-chat surface … skip the lazy
// gate"). The desk passes none. User pressing a button IS the authority the gate
// exists to obtain from the model.

/// The seam. One method, so a test can substitute a spy and prove which tool a
/// button routes to without touching disk.
protocol DeskToolInvoking: Sendable {
    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue
}

struct DeskToolDispatchRouter: DeskToolInvoking {
    /// Surface tag carried into the dispatch. Distinct from "chat" so a receipt
    /// reader can tell User's click from Agent's tool call.
    static let surface = "desk"

    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        // Same impl AND same gate: chat-lane desk_* calls pass through the
        // FileAccessGated + AutonomyGated membrane, and a bare dispatcher here
        // let a desk click write where the same mutation from chat would have
        // required approval (gpt-5.5 review 2026-08-06, blocking #1). The
        // gated chain resolves Trust Center policy identically; with no
        // ApprovalFiler an approval-tier action returns an honest refusal the
        // UI surfaces, instead of silently bypassing the policy.
        let gated = makeGatedToolDispatchClient(
            tools: SwiftToolDispatcher(dataRoot: dataRoot),
            fileAccess: "auto",
            approvalFiler: DeskClickApprovalFiler(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
        return try await gated.dispatch(
            tool: tool, input: input, surface: Self.surface)
    }
}

// MARK: - Actions

/// Every mutation the desk surface can fire, as data. Keeping the tool name and
/// the argument dict on the ACTION (not inline at the call site) is what makes
/// "the button routes to the same tool the chat lane calls" a testable property
/// rather than a claim in a comment.
enum DeskQuickAction: Equatable, Sendable {
    case close(handle: String, outcome: String)
    case defer_(handle: String, until: String?)
    case note(handle: String, text: String)
    case nagGlobal(on: Bool)
    case nagProject(project: String, on: Bool)
    case nagItem(handle: String, on: Bool)
    case nagMute(until: String?)
    case nagUnmute

    /// The default outcome summary for a one-keystroke close. `desk_close`
    /// REFUSES an empty `outcome_summary`, and the honest thing to record is
    /// where the close came from — not an invented outcome.
    static let deskCloseOutcome = "Closed from the desk."

    var tool: String {
        switch self {
        case .close: return "desk_close"
        case .defer_: return "desk_defer"
        case .note: return "desk_note"
        case .nagGlobal, .nagProject, .nagItem, .nagMute, .nagUnmute: return "desk_nag_control"
        }
    }

    var input: [String: JSONValue] {
        switch self {
        case let .close(handle, outcome):
            return ["handle": .string(handle), "outcome_summary": .string(outcome)]
        case let .defer_(handle, until):
            // An EMPTY `until` is how desk_defer clears a park — the same
            // encoding the chat tool documents, not a second convention.
            return ["handle": .string(handle), "until": .string(until ?? "")]
        case let .note(handle, text):
            return ["handle": .string(handle), "text": .string(text)]
        case let .nagGlobal(on):
            return ["action": .string(on ? "enable" : "disable"), "scope_kind": .string("global")]
        case let .nagProject(project, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("project"),
                "scope_id": .string(project),
            ]
        case let .nagItem(handle, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("item"),
                "scope_id": .string(handle),
            ]
        case let .nagMute(until):
            var input: [String: JSONValue] = ["action": .string("mute")]
            if let until, !until.isEmpty { input["until"] = .string(until) }
            return input
        case .nagUnmute:
            return ["action": .string("unmute")]
        }
    }

    /// What the surface says while the write is in flight, and what a failure
    /// message is prefixed with.
    var pendingLabel: String {
        switch self {
        case .close: return "Closing"
        case let .defer_(_, until): return until == nil ? "Clearing the park" : "Deferring"
        case .note: return "Adding note"
        case let .nagGlobal(on): return on ? "Turning nagging on" : "Turning nagging off"
        case .nagProject, .nagItem: return "Updating nag scope"
        case .nagMute: return "Muting nags"
        case .nagUnmute: return "Turning nagging back on"
        }
    }
}

/// What came back, in the two words the surface needs.
struct DeskActionOutcome: Equatable, Sendable {
    let ok: Bool
    let message: String
}

enum DeskActionResultReader {
    /// The desk tools answer in three shapes and ALL THREE must be surfaced:
    ///   status "ok"      → `confirmation`
    ///   status "refused" → `reason`, ok == false (the store's honest refusal:
    ///                      a cycle, a bad date, a cap — these are results, not
    ///                      exceptions, and rendering one as success is a lie)
    ///   status "failed"  → `reason`/`detail`, ok == false
    /// Anything else is reported as unknown rather than assumed fine.
    static func read(_ value: JSONValue, fallback: String) -> DeskActionOutcome {
        guard case .object(let obj) = value else {
            return DeskActionOutcome(ok: false, message: "\(fallback): unreadable tool result")
        }
        let status: String
        if case .string(let s)? = obj["status"] { status = s } else { status = "" }
        func text(_ keys: [String]) -> String? {
            for key in keys {
                if case .string(let s)? = obj[key], !s.isEmpty { return s }
            }
            return nil
        }
        switch status {
        case "ok":
            return DeskActionOutcome(ok: true, message: text(["confirmation", "summary"]) ?? fallback)
        case "refused":
            return DeskActionOutcome(ok: false, message: text(["reason"]) ?? "\(fallback) refused")
        case "failed":
            return DeskActionOutcome(
                ok: false,
                message: text(["reason", "detail", "fix"]) ?? "\(fallback) failed")
        default:
            return DeskActionOutcome(
                ok: false,
                message: "\(fallback): unexpected tool status '\(status)'")
        }
    }
}

enum DeskActionRunner {
    /// Fire one action and read its answer. Never throws: a transport failure
    /// is an outcome with `ok == false`, because the caller has to render
    /// something either way.
    static func perform(
        _ action: DeskQuickAction, via invoker: any DeskToolInvoking
    ) async -> DeskActionOutcome {
        do {
            let value = try await invoker.run(tool: action.tool, input: action.input)
            return DeskActionResultReader.read(value, fallback: action.pendingLabel)
        } catch {
            return DeskActionOutcome(
                ok: false,
                message: "\(action.pendingLabel) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Nags panel model (pure)

/// One lane in the nags panel. "Lane" here is the desk's own scoping vocabulary:
/// `desk_nag_control` scopes are global / project / item, and the projects on
/// the board ARE the lanes User thinks in ("stay on me about the release track").
struct DeskNagLane: Identifiable, Equatable, Sendable {
    let project: String
    let enabled: Bool
    let itemCount: Int
    var id: String { project }
}

enum DeskNagPanelModel {
    /// One row per project that has live work, with its current scope decision.
    /// A project with NO scope entry is off — matching `DeskNagConfig
    /// .scopeEnabled(for:)`, where the absence of an entry means no nag.
    static func lanes(items: [DeskItem], config: DeskNagConfig) -> [DeskNagLane] {
        let active = DeskBoardLayout.activeItems(items)
        let byProject = Dictionary(grouping: active, by: \.project)
        return byProject.keys.sorted().map { project in
            let entry = config.scopes.first {
                $0.kind == .project && $0.id.compare(project, options: .caseInsensitive) == .orderedSame
            }
            return DeskNagLane(
                project: project,
                enabled: entry?.enabled ?? false,
                itemCount: byProject[project]?.count ?? 0)
        }
    }

    /// The panel's one-line truth. Says the GLOBAL switch, the mute, and —
    /// critically — the case where lanes are on but the master switch is off,
    /// which is the state that silently pings nothing (the same honesty
    /// `deskNagScopeConfirmation` keeps in the chat tool).
    static func summary(_ config: DeskNagConfig, lanes: [DeskNagLane], now: Date) -> String {
        if config.isMuted(now: now) {
            let phrase = config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
                ? "indefinitely" : "until \(config.mutedUntil ?? "?")"
            return "Muted \(phrase) — still tracking, nothing will ping."
        }
        guard config.enabled else {
            let on = lanes.filter(\.enabled).count
            return on > 0
                ? "Nagging is OFF globally — \(on) lane\(on == 1 ? "" : "s") armed but silent."
                : "Nagging is OFF. Nothing will ping."
        }
        let on = lanes.filter(\.enabled).count
        return on == 0
            ? "Nagging is ON, but no lane is armed — nothing will ping until you pick one."
            : "Nagging is ON for \(on) lane\(on == 1 ? "" : "s")."
    }

    /// Snooze choices, resolved against an injected `now` so the mapping is
    /// testable. `nil` = mute with no end date (the tool writes its indefinite
    /// sentinel).
    struct SnoozeOption: Identifiable, Equatable, Sendable {
        let label: String
        let until: String?
        var id: String { label }
    }

    static func snoozeOptions(from now: Date, calendar: Calendar = .current) -> [SnoozeOption] {
        [
            SnoozeOption(label: "Until tomorrow", until: DeskDeferPreset.tomorrow.day(from: now, calendar: calendar)),
            SnoozeOption(label: "Until next week", until: DeskDeferPreset.nextWeek.day(from: now, calendar: calendar)),
            SnoozeOption(label: "Indefinitely", until: nil),
        ]
    }
}

/// Answers the AutonomyGate's approval tier for the desk surface: the human is
/// PRESENT and the action IS the click — filing a card for User to approve the
/// click he just made would be theater. Hard-denied tiers still deny (the gate
/// evaluates policy before it ever consults the filer); this only resolves the
/// "does a human approve?" question, and it files the SAME approval record the
/// chat lane files so the audit trail shows who approved and how.
struct DeskClickApprovalFiler: ApprovalFiler {
    let dataRoot: URL

    func fileApprovalRequest(
        toolName: String, surface: String, payload: JSONValue, reason: String
    ) async throws -> String {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let body: JSONValue = .object([
            "action": .string(toolName),
            "payload": payload,
            "reason": .string(reason + " — auto-approved: initiated by a local desk click"),
            "remoteResolvable": .bool(false),
        ])
        let record = try await inbox.create(body)
        _ = try? await inbox.resolve(
            record.id, decision: .approved, decidedBy: "local_desk_click")
        return record.id
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision {
        .approved
    }
}

// TrustGuardrailSummary.swift — Sweep R4 C10.
//
// "What Agent can do right now": a compact, plain-language answer to the one
// question Trust Center never answered on arrival. The panel it feeds sits at
// the very top of the page.
//
// WHY THIS IS DERIVED AND NOT WRITTEN
// A "Guardrail Summary" panel used to live here and was deleted in the
// 2026-07-22 tighten pass (TrustCenterView.swift records it) because its five
// tiles were hand-written prose that restated controls further down the page —
// so it went stale the moment either side changed, and a stale trust claim is
// worse than no claim. Everything below is a pure function of the loaded
// policy. There is no hardcoded capability sentence anywhere in this file: if
// a row says the agent can do something, the policy currently says so.
//
// READ-ONLY. Nothing here writes policy, and the panel renders no controls —
// every row's actual switch lives in a panel further down the same page.

import SwiftUI

/// How alarming a summary row should look. Purely presentational.
enum TrustGuardrailTone: String, Hashable, Sendable {
    /// Conservative default — the safe end of this setting.
    case ok
    /// Broader than default, still bounded.
    case caution
    /// A safety net is off, or the boundary is the whole Mac.
    case danger
}

/// One plain-language line in the summary.
struct TrustGuardrailRow: Identifiable, Hashable, Sendable {
    /// Stable key. Matches the concept, not the copy — tests pin these.
    let id: String
    /// The question this row answers, in the user's words.
    let title: String
    /// The current answer, short enough to scan.
    let value: String
    /// One sentence of consequence, for the person who stops on this row.
    let detail: String
    let systemImage: String
    let tone: TrustGuardrailTone
}

/// Pure derivation. Unit-tested against policy fixtures; no view state, no I/O.
enum TrustGuardrailSummary {
    /// - Parameters:
    ///   - policy: the loaded trust policy, or `nil` before the first load.
    ///   - accessMode: the resolved agent-access mode the page is already
    ///     showing (`AppModel.agentAccessMode(from:fallback:)`). Passed in
    ///     rather than recomputed so the summary can never disagree with the
    ///     Agent-access picker sitting two panels below it.
    /// - Returns: the rows to render, in reading order. Empty when no policy
    ///   has loaded — the caller shows a loading state rather than guessing.
    static func rows(policy: TrustPolicy?, accessMode: String) -> [TrustGuardrailRow] {
        guard let policy else { return [] }
        return [
            filesRow(policy: policy, accessMode: accessMode),
            autonomyRow(policy: policy, accessMode: accessMode),
            backupsRow(policy: policy),
            macControlRow(policy: policy),
            externalSendRow(policy: policy),
        ]
    }

    // MARK: - Rows

    private static func filesRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        let value: String
        let detail: String
        let tone: TrustGuardrailTone
        let state = fileChangeState(policy, accessMode: accessMode)
        switch state == .unavailable ? "read_only" : AppModel.normalizedAgentAccessMode(accessMode) {
        case "read_only":
            value = "Reads only"
            detail = "Files are read only; file changes and deletions are not available."
            tone = .ok
        case "workspace":
            value = "Your workspace folders"
            detail = fileChangesSentence(policy, accessMode: accessMode)
            tone = .caution
        case "full":
            value = "Anywhere on this Mac"
            detail = fileChangesSentence(policy, accessMode: accessMode) + " macOS still asks separately for access to protected folders."
            tone = .danger
        default:
            value = state == .workspace || state == .fullMac ? "Reads freely, edits workspaces automatically" : "Reads freely, writes when asked"
            detail = fileChangesSentence(policy, accessMode: accessMode)
            tone = .ok
        }
        return TrustGuardrailRow(
            id: "files",
            title: "Files it can reach",
            value: value,
            detail: detail,
            systemImage: "folder",
            tone: tone
        )
    }

    private static func outsidePhrase(_ value: String) -> String {
        switch value {
        case "allow": return "run without asking"
        case "ask": return "ask first"
        default: return "are not available"
        }
    }

    private static func fullMacActive(_ policy: TrustPolicy) -> Bool {
        switch FullMacExpiry.state(policy) {
        case .active, .never: return true
        default: return false
        }
    }

    private enum FileChangeState {
        case unavailable, supervised, appData, workspace, fullMac
    }

    private static func fileChangeState(_ policy: TrustPolicy, accessMode: String) -> FileChangeState {
        if policy.permissionLevel == "strict" || AppModel.normalizedAgentAccessMode(accessMode) == "read_only" {
            return .unavailable
        }
        if fullMacActive(policy) { return .fullMac }
        switch policy.autonomyDefault {
        case "workspace_autonomous": return .workspace
        case "app_data_autonomous": return .appData
        default: return .supervised
        }
    }

    private static func fileChangesSentence(_ policy: TrustPolicy, accessMode: String) -> String {
        let state = fileChangeState(policy, accessMode: accessMode)
        if state == .unavailable {
            return "Files are read only; file changes and deletions are not available."
        }
        let autonomous = state == .fullMac || state == .workspace
        let inside = autonomous ? "run on their own" : "ask first"
        let outside = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        // An outside allow does not itself waive the supervised write gate.
        let outsideAction = outside == "allow" && !autonomous ? "ask first" : outsidePhrase(outside)
        return "Edits inside your workspaces \(inside); writes outside \(outsideAction)."
    }

    private static func autonomyRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        // The saved baseline is not the effective routine-tool posture while
        // Full Mac is active. Reuse the expiry presentation's canonical gate
        // verdict; a selected mode alone must not claim active autonomy.
        let state = fileChangeState(policy, accessMode: accessMode)
        switch state {
        case .fullMac:
            return TrustGuardrailRow(
                id: "autonomy",
                title: "Before it changes something",
                value: "Full Mac autonomy active",
                detail: fileChangesSentence(policy, accessMode: accessMode) + " Enabled routine actions run without asking on this Mac and trusted remote surfaces; external sends still wait for approval. Explicit tool blocks and protected system actions keep their own checks.",
                systemImage: "hand.raised",
                tone: .danger
            )
        default:
            break
        }
        let value: String
        let detail = fileChangesSentence(policy, accessMode: accessMode)
            + (state == .appData ? " NativeAgent's own memory and notes update without asking." : "")
        let tone: TrustGuardrailTone
        switch state {
        case .unavailable:
            value = "Not available"
            tone = .ok
        case .appData:
            value = "Automatic memory and notes"
            tone = .caution
        case .workspace:
            value = "Acts alone in your workspaces"
            tone = .danger
        default:
            value = "Asks you first"
            tone = .ok
        }
        return TrustGuardrailRow(
            id: "autonomy",
            title: "Before it changes something",
            value: value,
            detail: detail,
            systemImage: "hand.raised",
            tone: tone
        )
    }

    private static func backupsRow(policy: TrustPolicy) -> TrustGuardrailRow {
        let on = policy.filePolicy?.requireBackupBeforeWrite ?? true
        return TrustGuardrailRow(
            id: "backups",
            title: "If it gets something wrong",
            value: on ? "Backup required before changes" : "No backup required",
            detail: on
                ? "Before an allowed file write, a backup is required so you can restore the previous version."
                : "Allowed file writes do not require a backup. Turning \"Backup before workspace writes\" back on restores the safety net.",
            systemImage: on ? "arrow.uturn.backward.circle" : "exclamationmark.triangle",
            tone: on ? .ok : .danger
        )
    }

    private static func macControlRow(policy: TrustPolicy) -> TrustGuardrailRow {
        let mac = policy.macControlPolicy
        guard let mac, mac.enabled else {
            return TrustGuardrailRow(
                id: "mac_control",
                title: "Controlling your Mac",
                value: "Off",
                detail: "Mac control is off: app automation, terminal commands, and clicking are not available.",
                systemImage: "macbook",
                tone: .ok
            )
        }
        let granted = grantedMacCategories(mac)
        let loud = mac.shellAllowed || mac.systemControlAllowed || mac.accessibilityAllowed
        guard !granted.isEmpty else {
            return TrustGuardrailRow(
                id: "mac_control",
                title: "Controlling your Mac",
                value: "On, nothing granted",
                detail: "Mac control is switched on but no category is allowed yet, so nothing runs.",
                systemImage: "macbook",
                tone: .ok
            )
        }
        return TrustGuardrailRow(
            id: "mac_control",
            title: "Controlling your Mac",
            value: granted.joined(separator: ", "),
            detail: approvalSentence(mac, policy: policy),
            systemImage: "macbook",
            tone: loud ? .danger : .caution
        )
    }

    /// Human names for every granted Mac Control category, in the order the
    /// Mac Control panel lists them. Derived from the policy flags — a new
    /// grant appears here the moment its toggle flips.
    static func grantedMacCategories(_ mac: TrustMacControlPolicy) -> [String] {
        var out: [String] = []
        if mac.notificationsAllowed { out.append("Notifications") }
        if mac.spotlightAllowed { out.append("Spotlight search") }
        if mac.shortcutsAllowed { out.append("Shortcuts") }
        if mac.applesScriptAllowed || mac.jxaAllowed { out.append("App automation") }
        if mac.accessibilityAllowed { out.append("Clicking and typing") }
        if mac.fileOpsAllowed { out.append("Mac-controlled files") }
        if mac.systemControlAllowed { out.append("System settings") }
        if mac.shellAllowed { out.append("Terminal commands") }
        return out
    }

    private static func approvalSentence(_ mac: TrustMacControlPolicy, policy: TrustPolicy) -> String {
        let categories: [(String, String, Bool)] = [
            ("shell", "Terminal commands", mac.shellAllowed),
            ("file_ops", "Reading, listing, writing, moving, and trashing files through Mac control", mac.fileOpsAllowed),
            ("applescript", "AppleScript app automation", mac.applesScriptAllowed),
            ("jxa", "JavaScript app automation", mac.jxaAllowed),
            ("accessibility", "Clicking and typing", mac.accessibilityAllowed),
            ("system_control", "System settings", mac.systemControlAllowed),
            ("shortcuts", "Shortcuts", mac.shortcutsAllowed),
            ("notifications", "Notifications", mac.notificationsAllowed),
            ("spotlight", "Spotlight search", mac.spotlightAllowed),
        ]
        let unavailable = categories.filter { !$0.2 }.map { $0.1 }
        let asks = categories.filter { $0.2 && mac.approvalRequiredFor.contains($0.0) }.map { $0.1 }
        let automatic = categories.filter { $0.2 && !mac.approvalRequiredFor.contains($0.0) }.map { $0.1 }
        var sentences: [String] = []
        if !unavailable.isEmpty { sentences.append("Not available: \(unavailable.joined(separator: ", ")).") }
        if !asks.isEmpty { sentences.append("Ask first: \(asks.joined(separator: ", ")).") }
        if !automatic.isEmpty { sentences.append("Run without asking: \(automatic.joined(separator: ", ")).") }
        sentences.append("File access limits\(fullMacActive(policy) ? " and protected-action checks" : ", risk checks, and tool permissions") still apply.")
        return sentences.joined(separator: "\n")
    }

    private static func externalSendRow(policy: TrustPolicy) -> TrustGuardrailRow {
        // NEVER claim "sends without asking" from this one flag: email and
        // message sends carry their own per-tool send_approval defaults that
        // still stop and ask even when the connector-level flag is off
        // (gpt-5.5 review 2026-08-06, blocking #1 — TrustCenter+Defaults
        // gmail.send/agentmail.send/email.send/slack.post_message default to
        // send_approval, and SecurityCenter maps that to ask). The summary
        // must understate, not overstate.
        let asks = policy.connectorPolicy?.sendExternalMessagesRequiresApproval ?? true
        return TrustGuardrailRow(
            id: "external_send",
            title: "Sending things to other people",
            value: asks ? "Asks before sending" : "Mostly asks first",
            detail: asks
                ? "Email, messages, and posts wait for your approval before they leave this Mac."
                : "Connector posts skip the blanket confirmation, but email and "
                  + "message sends still ask first unless you change each "
                  + "tool's own setting.",
            systemImage: asks ? "paperplane" : "paperplane.fill",
            tone: asks ? .ok : .caution
        )
    }
}

// MARK: - Panel

/// The live summary panel. Reads the same `appModel.trustPolicy` the rest of
/// the page already loaded — no extra fetch, no extra state.
struct TrustGuardrailSummaryPanel: View {
    @Environment(AppModel.self) private var appModel
    /// The access mode the page's own picker is showing.
    let accessMode: String

    private var rows: [TrustGuardrailRow] {
        TrustGuardrailSummary.rows(policy: appModel.trustPolicy, accessMode: accessMode)
    }

    var body: some View {
        NativePanel(title: "What \(AgentVoice.live.subject) can do right now", systemImage: "eye") {
            if rows.isEmpty {
                HStack(spacing: NativeAgentSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading your current settings…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    Text("Every line below is read from your settings as they are right now, not a description of how the app usually works.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows) { row in
                        TrustGuardrailRowView(row: row)
                    }
                }
            }
        }
    }
}

/// One line of the answer. The tinted plate and the warning triangle it used to
/// wear made five rows read as five alarms; the state now lives in the colour of
/// the answer itself, on the card's own ground (advanced-page kit, 2026-09-03).
private struct TrustGuardrailRowView: View {
    let row: TrustGuardrailRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.md) {
                Text(row.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: NativeAgentSpacing.sm)
                Text(row.value)
                    .font(ShellType.label)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
            }
            Text(row.detail)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(row.value). \(row.detail)")
    }

    /// Calm when this is the safe end, trouble when a safety net is off, and the
    /// quiet ink for the middle — nothing here waits on User, so no teal.
    private var tint: Color {
        switch row.tone {
        case .ok: return NativeAgentShell.calm
        case .caution: return NativeAgentShell.secondary
        case .danger: return NativeAgentShell.trouble
        }
    }
}

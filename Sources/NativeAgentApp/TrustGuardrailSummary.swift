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
            autonomyRow(policy: policy),
            backupsRow(policy: policy),
            macControlRow(policy: policy),
            externalSendRow(policy: policy),
        ]
    }

    // MARK: - Rows

    private static func filesRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        let outside = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        let value: String
        let detail: String
        let tone: TrustGuardrailTone
        switch AppModel.normalizedAgentAccessMode(accessMode) {
        case "read_only":
            value = "Reads only"
            detail = "It can look at files but cannot change or delete anything."
            tone = .ok
        case "workspace":
            value = "Your workspace folders"
            detail = "It can create and change files inside the workspaces you added. Everywhere else on your Mac is \(outsidePhrase(outside))."
            tone = .caution
        case "full":
            value = "Anywhere on this Mac"
            detail = "Full Mac is active, so it can reach files outside your workspaces. macOS still asks separately before it touches Documents, Desktop, or Downloads."
            tone = .danger
        default:
            value = "Reads freely, writes when asked"
            detail = "It reads by default and only steps up to writing when your message clearly needs it. Outside your workspaces, writes are \(outsidePhrase(outside))."
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
        case "allow": return "allowed without asking"
        case "ask": return "allowed only when you say yes"
        default: return "off limits"
        }
    }

    private static func autonomyRow(policy: TrustPolicy) -> TrustGuardrailRow {
        let value: String
        let detail: String
        let tone: TrustGuardrailTone
        switch policy.autonomyDefault ?? "supervised" {
        case "app_data_autonomous":
            value = "Acts alone on its own data"
            detail = "It updates NativeAgent's own memory and notes without asking. Anything touching your files still waits for you."
            tone = .caution
        case "workspace_autonomous":
            value = "Acts alone in your workspaces"
            detail = "It can change files in your workspaces without stopping to ask first."
            tone = .danger
        default:
            value = "Asks you first"
            detail = "Anything that changes something waits for your approval before it runs."
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
            value: on ? "Backup taken first" : "No backup taken",
            detail: on
                ? "A restore point is written before it changes your files, so you can put them back."
                : "Nothing is saved before it changes your files. Turning \"Backup before workspace writes\" back on restores the safety net.",
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
                detail: "It cannot drive other apps, run commands, or click anything on your behalf.",
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
            detail: approvalSentence(mac),
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
        if mac.fileOpsAllowed { out.append("File changes") }
        if mac.systemControlAllowed { out.append("System settings") }
        if mac.shellAllowed { out.append("Terminal commands") }
        return out
    }

    private static func approvalSentence(_ mac: TrustMacControlPolicy) -> String {
        let asked = MacControlApprovalCategory.all
            .filter { mac.approvalRequiredFor.contains($0.key) }
        if asked.isEmpty {
            return "Of the abilities that are switched on above, none stop to ask you first."
        }
        if asked.count == MacControlApprovalCategory.all.count {
            return "Every risky one of these — commands, file changes, app automation, and clicking — stops and asks you first."
        }
        return "It asks you first before: \(asked.map(\.title).joined(separator: "; "))."
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
        NativePanel(title: "What Agent can do right now", systemImage: "eye", tint: .blue) {
            if rows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your current settings…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every line below is read from your settings as they are right now, not a description of how the app usually works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows) { row in
                        TrustGuardrailRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct TrustGuardrailRowView: View {
    let row: TrustGuardrailRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.body)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    Text(row.value)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(row.value). \(row.detail)")
    }

    private var tint: Color {
        switch row.tone {
        case .ok: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }

    /// The row carries its own glyph; tone only overrides it when the row is
    /// at the alarming end, so a scan down the column reads as a column.
    private var iconName: String {
        row.tone == .danger ? "exclamationmark.triangle.fill" : row.systemImage
    }
}

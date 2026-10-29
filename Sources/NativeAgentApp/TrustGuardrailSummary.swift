import SwiftUI
import NativeAgentShared
import TrustCenter

// Blueprint: | `TrustGuardrailSummary.swift` | `TrustGuardrailSummary`: derived plain-language effective file/autonomy/backup/Mac/send reach, never another saved policy |

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
    /// Stable key matching the concept, not the copy.
    let id: String
    /// The question this row answers, in the user's words.
    let title: String
    /// The current answer, short enough to scan.
    let value: String
    /// One sentence of consequence, for the person who stops on this row.
    let detail: String
    let tone: TrustGuardrailTone
}

/// Policy-derived rows; no view state or I/O.
enum TrustGuardrailSummary {
    /// - Parameters:
    ///   - policy: the loaded trust policy, or `nil` before the first load.
    ///   - accessMode: the resolved agent-access mode the page is already
    ///     showing (`TrustAccessModeCapabilityCatalog.agentAccessMode(from:fallback:)`). Passed in
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

    // Each row states one fact: file reach, approval, or granted categories.

    private static func filesRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        let value: String
        let tone: TrustGuardrailTone
        let state = TrustAccessModeCapabilityCatalog.fileChangeState(policy, accessMode: accessMode)
        // The badge and the sentence answer the same question, so they read the
        // same gate: an outside-workspace "allow" IS the Full Mac file posture
        // whatever the picker says, and the badge must not claim otherwise.
        let mode = state == .unavailable ? "read_only"
            : state == .fullMac ? "full"
            : TrustAccessModeCapabilityCatalog.normalizedMode(accessMode)
        switch mode {
        case "read_only":
            value = "Reads only"
            tone = .ok
        case "workspace":
            value = "Your workspace folders"
            tone = .caution
        case "full":
            value = "Anywhere on this Mac"
            tone = .danger
        default:
            value = "Reads anywhere, writes in workspaces"
            tone = .ok
        }
        return TrustGuardrailRow(
            id: "files",
            title: "Files I can reach",
            value: value,
            detail: fileReachSentence(policy, accessMode: accessMode),
            tone: tone
        )
    }

    /// Where the agent can reach. Reach only — approval belongs to the autonomy
    /// row directly beneath it.
    private static func fileReachSentence(_ policy: TrustPolicy, accessMode: String) -> String {
        let state = TrustAccessModeCapabilityCatalog.fileChangeState(policy, accessMode: accessMode)
        if state == .unavailable {
            return "I can read the files and folders you point me at."
        }
        if state == .fullMac || TrustAccessModeCapabilityCatalog.normalizedMode(accessMode) == "full" {
            return "I can reach files anywhere on this Mac, inside and outside your workspaces. "
                + "macOS still asks separately for access to protected folders."
        }
        let head = TrustAccessModeCapabilityCatalog.normalizedMode(accessMode) == "workspace"
            ? "I can reach files in your workspace folders"
            : "I can read files you point me at and change files in your workspace folders"
        switch policy.filePolicy?.outsideWorkspaceDefault ?? "deny" {
        case "allow": return head + ", and files outside them too."
        case "ask": return head + "; files outside them need your approval."
        default: return head + ". Files outside them are off limits."
        }
    }

    /// What runs without asking, and what still waits.
    private static func outsideWriteClause(_ policy: TrustPolicy) -> String {
        switch policy.filePolicy?.outsideWorkspaceDefault ?? "deny" {
        case "allow": return "writes outside them run without asking."
        case "ask": return "writes outside them wait for your approval."
        default: return "writes outside them are not available."
        }
    }

    private static func autonomyRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        // The saved baseline is not the effective routine-tool posture while
        // Full Mac is on. Reuse the canonical gate verdict; a selected mode
        // alone must not claim active autonomy.
        let state = TrustAccessModeCapabilityCatalog.fileChangeState(policy, accessMode: accessMode)
        let value: String
        let detail: String
        let tone: TrustGuardrailTone
        switch state {
        case .fullMac:
            value = "Changes without asking"
            detail = PermissionLaw.fullMacContract
            tone = .danger
        case .unavailable:
            value = "Not available"
            detail = "Nothing changes on its own: file changes and deletions are not available."
            tone = .ok
        case .workspace:
            value = "Acts alone in your workspaces"
            detail = "Edits inside your workspaces run on their own; " + outsideWriteClause(policy)
            tone = .danger
        case .appData:
            value = "Automatic memory and notes"
            detail = "NativeAgent's own memory and notes update without asking; file changes ask you first."
            tone = .caution
        case .supervised:
            value = "Asks you first"
            detail = "I ask you before I change or delete a file."
            tone = .ok
        }
        return TrustGuardrailRow(
            id: "autonomy",
            title: "Before I change something",
            value: value,
            detail: detail,
            tone: tone
        )
    }

    private static func backupsRow(policy: TrustPolicy) -> TrustGuardrailRow {
        let on = policy.filePolicy?.requireBackupBeforeWrite ?? true
        return TrustGuardrailRow(
            id: "backups",
            title: "If I get something wrong",
            value: on ? "Backup required before changes" : "No backup required",
            detail: on
                ? "Before an allowed file write, a backup is required so you can restore the previous version."
                : "Allowed file writes do not require a backup. Turning \"Backup before workspace writes\" back on restores the safety net.",
            tone: on ? .ok : .danger
        )
    }

    private static func macControlRow(policy: TrustPolicy) -> TrustGuardrailRow {
        let mac = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
        guard let mac, mac.enabled else {
            return TrustGuardrailRow(
                id: "mac_control",
                title: "Controlling your Mac",
                value: "Off",
                detail: "Mac control is off: app automation, terminal commands, and clicking are not available.",
                tone: .ok
            )
        }
        let loud = mac.shellAllowed || mac.systemControlAllowed || mac.accessibilityAllowed
        let granted = TrustAccessModeCapabilityCatalog.grantedMacCategories(mac)
        guard !granted.isEmpty else {
            return TrustGuardrailRow(
                id: "mac_control",
                title: "Controlling your Mac",
                value: "On, nothing granted",
                detail: "Mac control is switched on but no category is allowed yet, so nothing runs.",
                tone: .ok
            )
        }
        return TrustGuardrailRow(
            id: "mac_control",
            title: "Controlling your Mac",
            value: "On",
            detail: "\(sentenceList(granted)).\nYour access mode decides when I ask; file limits and tool permissions still apply.",
            tone: loud ? .danger : .caution
        )
    }

    /// Category names joined into a sentence: the first keeps its capital, the
    /// rest go lowercase unless they are names (Mac, Shortcuts, Spotlight).
    static func sentenceList(_ names: [String]) -> String {
        names.enumerated().map { index, name in
            guard index > 0, !["Mac", "Shortcuts", "Spotlight"].contains(where: name.hasPrefix) else { return name }
            return name.prefix(1).lowercased() + name.dropFirst()
        }.joined(separator: ", ")
    }

    private static func externalSendRow(policy: TrustPolicy) -> TrustGuardrailRow {
        if TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy) {
            return TrustGuardrailRow(
                id: "external_send", title: "Sending things to other people",
                value: "Sends without asking",
                detail: "Under Full Mac I can send through your connected accounts without an additional app approval. Agents you enabled in Trust inherit your authority. Other agents do not, and their requests can require approval.",
                // As loud as file reach: this is the one that reaches other
                // people, so it never wears a quieter word than the files row.
                tone: .danger
            )
        }
        // A send is a write on the person's side: Work asks, Safe sends nothing.
        let safe = TrustAccessModeCapabilityCatalog.posture(policy) == .readOnly
        return TrustGuardrailRow(
            id: "external_send",
            title: "Sending things to other people",
            value: safe ? "Doesn't send" : "Asks before sending",
            detail: safe
                ? "Safe sends nothing to other people."
                : "Email, messages, and posts wait for your approval before they leave this Mac.",
            tone: .ok
        )
    }
}

// MARK: - Panel

/// The live summary panel. Reads the same `appModel.engine.trust.policy` the rest of
/// the page already loaded — no extra fetch, no extra state.
struct TrustGuardrailSummaryPanel: View {
    @Environment(AppModel.self) private var appModel
    /// The access mode the page's own picker is showing.
    let accessMode: String

    private var policyReadFailed: Bool {
        appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "trust policy"
        } == true
    }

    private var rows: [TrustGuardrailRow] {
        TrustGuardrailSummary.rows(policy: appModel.engine.trust.policy, accessMode: accessMode)
    }

    var body: some View {
        NativePanel(title: policyReadFailed ? "Permissions unavailable" : "What I can do right now") {
            if policyReadFailed {
                Text("Your saved permissions could not be checked. Reload Trust to try again.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if rows.isEmpty {
                HStack(spacing: NativeAgentSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading your current settings…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    Text("Live from your settings.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows) { row in
                        TrustGuardrailRowView(row: row)
                        // The one control on this card: a manual backup sits
                        // with the row that answers "if I get something wrong".
                        if row.id == "backups" {
                            backupNowButton
                        }
                    }
                }
            }
        }
    }
}

extension TrustGuardrailSummaryPanel {
    /// What `TrustBackupPersistence.createBackup` copies: the app's own data under its
    /// data root (settings, memory, chats, skills, tools, connectors, jobs,
    /// persona), never files in the person's folders.
    fileprivate var backupNowButton: some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.md) {
            Text("Copies what I keep on this Mac: settings, memory, chats, skills, connectors and scheduled jobs. Your own files are not part of it. Restore from Advanced → Backups.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NativeAgentSpacing.sm)
            Button("Back up now") {
                Task { await appModel.createBackup(reason: "manual Trust Center backup") }
            }
            .controlSize(.small)
            .accessibilityIdentifier("trust.backup-now")
        }
    }
}

/// Guardrail state appears in the answer's colour on the card's own ground.
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
        // macOS 27: selectable text + a custom accessibility label loops SwiftUI AX and crashes the app.
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

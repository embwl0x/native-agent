import Foundation
import NativeAgentShared
import TrustCenter

// Blueprint: | `TrustFaceGuardrails.swift` | Policy-derived guardrail rows used by Trust’s shared face |

/// Tone is presentation only and must never become authority.
enum TrustGuardrailTone: String, Hashable, Sendable {
    case ok
    case caution
    case danger
}

struct TrustGuardrailRow: Identifiable, Hashable, Sendable {
    /// Key by concept so copy edits cannot change row identity.
    let id: String
    let title: String
    let value: String
    let detail: String
    let tone: TrustGuardrailTone
}

/// Derive rows from policy without keeping another state owner.
enum TrustGuardrailSummary {
    /// Use the page's resolved access mode so the summary cannot disagree with its picker.
    /// Before policy loads, return no rows; the caller shows loading instead of guessing.
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
        let tone: TrustGuardrailTone
        let state = TrustAccessModeCapabilityCatalog.fileChangeState(policy, accessMode: accessMode)
        // Derive badge and sentence from the same file gate so they cannot contradict each other.
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

    /// Keep reach separate from approval, which belongs to the autonomy row.
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

    private static func outsideWriteClause(_ policy: TrustPolicy) -> String {
        switch policy.filePolicy?.outsideWorkspaceDefault ?? "deny" {
        case "allow": return "writes outside them run without asking."
        case "ask": return "writes outside them wait for your approval."
        default: return "writes outside them are not available."
        }
    }

    private static func autonomyRow(policy: TrustPolicy, accessMode: String) -> TrustGuardrailRow {
        // Full Mac changes effective autonomy; read the canonical verdict instead of the saved baseline.
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

    /// Preserve proper-name capitals when joining category names into a sentence.
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
                detail: """
                    Under Full Mac I can send through your connected accounts without an additional app approval. Agents you enabled in \
                    Trust inherit your authority. Other agents do not, and their requests can require approval.
                    """,
                // Sending reaches other people, so its scope must be at least as visible as file reach.
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

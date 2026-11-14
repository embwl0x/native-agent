import Foundation
import NativeAgentShared
import TrustCenter

// Blueprint: | `TrustFaceGuardrails.swift` | Policy-derived guardrail rows and the lock rows read from `PermissionLaw` and levers for Trust’s shared face |

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
            backupsRow(policy: policy),
            macControlRow(policy: policy),
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

    /// Keep reach separate from approval, which belongs to the lock rows (`TrustLockCard`).
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
}

/// What asks the person first, as the Trust card draws it: a locked row for each kind of act the permission law makes ask at the saved
/// posture, then one folded row holding the kinds that run on their own, the kinds this standing leaves out and what only the person can
/// do. Which row is locked comes only from `PermissionLaw.verdict`, the table the gate reads for every call; lever names come from their
/// declarations (`AppAction.Owner.person`). Deciders that answer from a call's own input are not drawn as locks: the fold names their kinds.
enum TrustLockCard {
    /// `levers`: every lever as its declaration names it, in declaration order, and whether a card can carry the agent's ask for it.
    static func rows(posture: PermissionPosture, levers: Result<[(name: String, asks: Bool)], Error>) -> [PartFace.Row] {
        var locked: [PartFace.Row] = [], runs: [PartFace.Row] = [], out: [PartFace.Row] = []
        for act in PermissionLaw.Act.allCases {
            let level = PermissionLaw.verdict(act, posture: posture)
            let (title, written) = words(act)
            var detail = written, tone: PartFace.Tone? = nil
            if act == .lever {
                switch levers {
                case .success(let levers): detail = list(levers.filter { $0.asks }.map { $0.name })
                case .failure(let error):
                    detail = "What is yours to decide could not be read: " + error.localizedDescription
                    tone = .failed
                }
            }
            func row(_ value: String, symbol: String? = nil) -> PartFace.Row {
                .init(id: "lock." + act.rawValue, title: title, detail: detail, value: value, symbol: symbol, tone: tone)
            }
            switch level {
            case "confirm": locked.append(row("I ask you first", symbol: "lock"))
            case "auto": runs.append(row("I don't ask first"))
            // Left out is neither locked nor on: it sits in the fold, "Not available" as the page has always said it.
            default: out.append(row("Not available"))
            }
        }
        // What no card can carry is the person's alone at every standing: no lock, no "On".
        let onlyYours = ((try? levers.get()) ?? []).filter { !$0.asks }.map { $0.name }
        let only: [PartFace.Row] = onlyYours.isEmpty ? [] : [.init(id: "lock.only_you", title: "Only you can do these", detail: list(onlyYours))]
        // The card says who decides, never whether a thing can be done at all (an app's own Write switch, what the standing reaches):
        // "on" would claim that, so the fold and its rows speak only of asking.
        let fold = locked.isEmpty ? "Nothing asks you first" : "Nothing else asks you first"
        return locked + [PartFace.Row(id: "lock.rest", title: fold, detail: caseByCase, rows: runs + out + only)]
    }

    /// The deciders that answer from a call's own input (where it came from, which limit it widens, which ability it keeps), by kind. True
    /// at every setting; their owners are named in the Trust doc.
    static let caseByCase = "A few things can still ask case by case: a request from another device, chat or agent; a change that widens "
        + "my own limits; and keeping an ability, my turn program included."

    /// Names in one sentence, as they are declared.
    private static func list(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return ([first] + names.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }).joined(separator: ", ") + "."
    }

    /// The person's words for each kind of act, first person as the page speaks. The lever kind's detail is its declarations' names.
    static func words(_ act: PermissionLaw.Act) -> (title: String, detail: String) {
        switch act {
        case .send:
            ("Sending things to other people", "Mail, messages, replies in your conversations, and messages to other agents. "
                + "Whether I can send through an app at all is that app's own Write switch.")
        case .delete:
            ("Deleting for good", "Deleting files, contacts, events or reminders, commands that cannot be undone, and resetting macOS privacy grants. "
                + "Moving something to the Trash is a change, not this.")
        case .change:
            ("Changing things on your side", "Your files and apps, controlling your Mac, terminal commands and other machines. "
                + "What I can reach at all is under Standing.")
        case .lever:
            ("Changing what is yours to decide", "")
        case .own:
            ("Working in my own space", "My memory and notes, and the workspace folders you gave me.")
        case .read:
            ("Reading and looking things up", "Files, the web and your apps, wherever I can reach and you have let me read.")
        }
    }
}

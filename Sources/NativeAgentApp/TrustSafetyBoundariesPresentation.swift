import Foundation

/// Visual severity for a boundary receipt. These values describe the loaded
/// policy only; they do not authorize an action or replace effect-time gates.
enum TrustSafetyBoundaryTone: Equatable {
    case neutral
    case caution
    case danger
    case unavailable
}

struct TrustSafetyBoundaryRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tone: TrustSafetyBoundaryTone
}

/// Derives the Safety Boundaries panel from the same loaded `TrustPolicy` used
/// by the rest of Trust Center. Static reassurance is intentionally avoided:
/// a missing policy produces an unavailable receipt, never default-safe prose.
enum TrustSafetyBoundariesPresentation {
    struct State: Equatable {
        let rows: [TrustSafetyBoundaryRow]
        let unavailableMessage: String?
    }

    static func state(policy: TrustPolicy?, accessMode: String) -> State {
        guard let policy else {
            return State(
                rows: [],
                unavailableMessage: "Safety boundaries are not confirmed until the current Trust policy loads."
            )
        }
        return State(
            rows: [
                fileAccessRow(accessMode: accessMode),
                toolsRow(policy.toolPolicy),
                externalSendRow(policy.connectorPolicy),
                macControlRow(policy.macControlPolicy),
                receiptsRow(policy.workshopPolicy),
            ],
            unavailableMessage: nil
        )
    }

    private static func fileAccessRow(accessMode: String) -> TrustSafetyBoundaryRow {
        switch AppModel.normalizedAgentAccessMode(accessMode) {
        case "read_only":
            TrustSafetyBoundaryRow(
                id: "files", title: "File changes", detail: "Read-only access is active; the agent cannot change or delete files.",
                systemImage: "folder.badge.minus", tone: .neutral
            )
        case "workspace":
            TrustSafetyBoundaryRow(
                id: "files", title: "File changes", detail: "Changes are limited to the workspaces you added; access outside them stays gated.",
                systemImage: "folder.badge.gearshape", tone: .caution
            )
        case "full":
            TrustSafetyBoundaryRow(
                id: "files", title: "File changes", detail: "Full Mac access is active. Files outside configured workspaces can be reached, subject to macOS permission prompts.",
                systemImage: "exclamationmark.triangle.fill", tone: .danger
            )
        default:
            TrustSafetyBoundaryRow(
                id: "files", title: "File changes", detail: "Automatic access is active: changes step up through the current Trust policy when needed.",
                systemImage: "folder", tone: .neutral
            )
        }
    }

    private static func toolsRow(_ tools: TrustToolPolicy?) -> TrustSafetyBoundaryRow {
        guard let tools,
              let autoRun = tools.autoRunSafeTools,
              let riskyApproval = tools.riskyToolApproval else {
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: "Tool execution policy is unavailable, so automatic tool boundaries are not confirmed.",
                systemImage: "hammer", tone: .unavailable
            )
        }

        guard autoRun else {
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: "Automatic runs for safe tools are off.",
                systemImage: "hammer", tone: .neutral
            )
        }

        let promotion = tools.autoPromoteSafeTools == true
            ? "Validated safe tools may be promoted and run automatically."
            : "Already-approved safe tools may run automatically."
        switch riskyApproval.lowercased() {
        case "deny":
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: promotion + " Risky tools are refused.",
                systemImage: "hammer", tone: .caution
            )
        case "ask", "approval", "approve":
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: promotion + " Risky tools stop for approval.",
                systemImage: "hammer", tone: .caution
            )
        case "allow":
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: promotion + " Risky tools may also run without an approval stop.",
                systemImage: "hammer.fill", tone: .danger
            )
        default:
            return TrustSafetyBoundaryRow(
                id: "tools", title: "Runnable tools", detail: "Risky-tool approval policy \(riskyApproval) is not recognized; automatic boundaries are not confirmed.",
                systemImage: "hammer", tone: .unavailable
            )
        }
    }

    private static func externalSendRow(_ connectors: TrustConnectorPolicy?) -> TrustSafetyBoundaryRow {
        guard let requiresApproval = connectors?.sendExternalMessagesRequiresApproval else {
            return TrustSafetyBoundaryRow(
                id: "external_send", title: "External messages", detail: "External-send approval policy is unavailable.",
                systemImage: "paperplane", tone: .unavailable
            )
        }
        return TrustSafetyBoundaryRow(
            id: "external_send",
            title: "External messages",
            detail: requiresApproval
                ? "Connector messages require approval before they are sent."
                : "The connector-wide send confirmation is off; individual message tools can still require approval.",
            systemImage: requiresApproval ? "paperplane" : "paperplane.fill",
            tone: requiresApproval ? .neutral : .caution
        )
    }

    private static func macControlRow(_ mac: TrustMacControlPolicy?) -> TrustSafetyBoundaryRow {
        guard let mac else {
            return TrustSafetyBoundaryRow(
                id: "mac_control", title: "Mac control", detail: "Mac-control policy is unavailable, so its action boundary is not confirmed.",
                systemImage: "macbook", tone: .unavailable
            )
        }
        guard mac.enabled else {
            return TrustSafetyBoundaryRow(
                id: "mac_control", title: "Mac control", detail: "Mac control is off.",
                systemImage: "macbook", tone: .neutral
            )
        }

        let granted = TrustGuardrailSummary.grantedMacCategories(mac)
        guard !granted.isEmpty else {
            return TrustSafetyBoundaryRow(
                id: "mac_control", title: "Mac control", detail: "Mac control is on, but no action category is granted.",
                systemImage: "macbook", tone: .neutral
            )
        }

        let unguarded = grantedRiskCategories(mac).filter { !mac.approvalRequiredFor.contains($0.key) }
        if unguarded.isEmpty {
            return TrustSafetyBoundaryRow(
                id: "mac_control", title: "Mac control", detail: "Enabled categories: \(granted.joined(separator: ", ")). Every enabled risky category requires approval.",
                systemImage: "macbook", tone: .caution
            )
        }
        return TrustSafetyBoundaryRow(
            id: "mac_control", title: "Mac control", detail: "Enabled categories: \(granted.joined(separator: ", ")). These can run without an approval stop: \(unguarded.map(\.title).joined(separator: "; ")).",
            systemImage: "macbook.badge.exclamationmark", tone: .danger
        )
    }

    private static func grantedRiskCategories(_ mac: TrustMacControlPolicy) -> [MacControlApprovalCategory] {
        MacControlApprovalCategory.all.filter { category in
            switch category.key {
            case "shell": mac.shellAllowed
            case "file_ops": mac.fileOpsAllowed
            case "applescript": mac.applesScriptAllowed
            case "jxa": mac.jxaAllowed
            case "accessibility": mac.accessibilityAllowed
            default: false
            }
        }
    }

    private static func receiptsRow(_ workshop: TrustWorkshopPolicy?) -> TrustSafetyBoundaryRow {
        guard let required = workshop?.requireReceipts else {
            return TrustSafetyBoundaryRow(
                id: "receipts", title: "Workshop receipts", detail: "The workflow receipt policy is unavailable.",
                systemImage: "doc.text.magnifyingglass", tone: .unavailable
            )
        }
        return TrustSafetyBoundaryRow(
            id: "receipts",
            title: "Workshop receipts",
            detail: required
                ? "Workshop executions must leave receipts for later review."
                : "Workshop executions are not required to leave receipts.",
            systemImage: "doc.text.magnifyingglass",
            tone: required ? .neutral : .danger
        )
    }
}

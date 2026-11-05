import DoctorChecks
import Foundation
import NativeAgentShared
// Blueprint: | `DiagnosticsFaceCopy.swift` | Shared diagnostics severity, check counts, malformed-time evidence and run outcome words |

enum DiagnosticsFaceCopy {
    static func ownerPage(_ check: CheckResult) -> String? {
        switch check.checkID {
        case "live.providers", "oauth_token_expiry": return "page:providers"
        case "live.telegram": return "page:telegram"
        case "status.desk_attention": return "page:desk"
        default: return nil
        }
    }

    static func tone(_ status: String) -> PartFace.Tone {
        switch status.lowercased() {
        case "running", "active": return .live
        case "queued", "pending", "info": return .quiet
        default:
            switch DoctorPlainCopy.bucket(for: status) {
            case "healthy": return .done
            case "failing": return .failed
            case "off", "not needed": return .quiet
            default: return .attention
            }
        }
    }

    static func counts(_ summary: DoctorPlainCopy.Summary) -> String {
        [(summary.healthy, "ok"), (summary.warning, "warn"), (summary.failing, "failed"), (summary.off, "off"),
            (summary.notNeeded, "not needed"), (summary.reading, "readings"), (summary.unclear, "unclear")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    static func datedDetail(_ detail: String?, at: String) -> String? {
        guard UserDisplayFormatters.parseISOTimestamp(at) == nil else { return detail }
        let evidence = at.isEmpty ? "Time was not recorded." : "Unreadable time: " + at
        return [detail, evidence].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Unknown writer vocabulary must stay visibly distinct so failure-like outcomes cannot look neutral.
public enum RunStatusBadgePresentation {
    public struct Badge: Equatable, Sendable {
        public let label: String
        /// Use NativeAgentTheme.statusColor vocabulary so badges share the same meaning.
        public let themeStatus: String
        public let sourceStatus: String
    }

    public static func badge(for rawStatus: String) -> Badge {
        let sourceStatus = boundedRawStatus(rawStatus)
        let key = normalizedKey(rawStatus)
        switch key {
        case "succeeded", "completed", "done":
            return Badge(label: "Succeeded", themeStatus: "ok", sourceStatus: sourceStatus)
        case "queued", "pending":
            return Badge(label: "Queued", themeStatus: "info", sourceStatus: sourceStatus)
        case "running", "active":
            return Badge(label: "Running", themeStatus: "running", sourceStatus: sourceStatus)
        case "failed", "failed_pre_dispatch":
            return Badge(label: "Failed", themeStatus: "failed", sourceStatus: sourceStatus)
        case "partial":
            return Badge(label: "Partially completed", themeStatus: "warn", sourceStatus: sourceStatus)
        case "timeout", "timed_out":
            return Badge(label: "Timed out", themeStatus: "timeout", sourceStatus: sourceStatus)
        case "stopped", "canceled", "cancelled":
            return Badge(label: "Stopped", themeStatus: "interrupted", sourceStatus: sourceStatus)
        case "interrupted":
            return Badge(label: "Interrupted", themeStatus: "interrupted", sourceStatus: sourceStatus)
        case "blocked":
            return Badge(label: "Blocked", themeStatus: "blocked", sourceStatus: sourceStatus)
        case "waiting_approval":
            return Badge(label: "Waiting for approval", themeStatus: "blocked", sourceStatus: sourceStatus)
        case "rolled_back":
            return Badge(label: "Rolled back", themeStatus: "warn", sourceStatus: sourceStatus)
        case "skipped":
            return Badge(label: "Skipped", themeStatus: "warn", sourceStatus: sourceStatus)
        case "disabled":
            return Badge(label: "Disabled", themeStatus: "warn", sourceStatus: sourceStatus)
        case "unknown":
            return Badge(label: "Outcome unknown", themeStatus: "warn", sourceStatus: sourceStatus)
        case "":
            return Badge(label: "Status unavailable", themeStatus: "warn", sourceStatus: sourceStatus)
        default:
            return Badge(
                label: "Unrecognized status: \(sourceStatus)",
                themeStatus: "warn",
                sourceStatus: sourceStatus
            )
        }
    }

    private static func normalizedKey(_ rawStatus: String) -> String {
        rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func boundedRawStatus(_ rawStatus: String) -> String {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(missing)" }
        let compact = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 80 ? String(compact.prefix(80)) + "…" : compact
    }
}

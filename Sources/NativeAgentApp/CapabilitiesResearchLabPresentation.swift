import Foundation

/// Result of sending a Research Lab request through the native research owner.
/// A returned run can still describe an unavailable connector, so callers must
/// inspect the receipt rather than treating a non-throwing call as success.
enum ResearchLabActionOutcome: Equatable {
    case rejected(String)
    case recorded(ResearchLabRun)
    case failed(String)
}

enum CapabilitiesResearchLabPresentation {
    enum Tone: Equatable {
        case neutral
        case progress
        case success
        case warning
        case failure
    }

    struct Message: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        let systemImage: String
    }

    enum RunList: Equatable {
        case loading
        case empty
        case loaded([ResearchLabRun])
        case unavailable(detail: String, retained: [ResearchLabRun])
    }

    static func message(for outcome: ResearchLabActionOutcome) -> Message {
        switch outcome {
        case .rejected(let detail):
            Message(text: "Research objective required", detail: detail, tone: .warning,
                    systemImage: "exclamationmark.triangle.fill")
        case .failed(let detail):
            Message(text: "Research lab failed", detail: detail, tone: .failure,
                    systemImage: "exclamationmark.triangle.fill")
        case .recorded(let run):
            message(for: run)
        }
    }

    static func message(for run: ResearchLabRun) -> Message {
        let status = run.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = meaningfulDetail(for: run)
        switch status {
        case "completed":
            if let error = nonempty(run.error) {
                return Message(text: "Research lab reported an error", detail: error, tone: .failure,
                               systemImage: "exclamationmark.triangle.fill")
            }
            return Message(
                text: "Research run completed",
                detail: "\(run.sources.count) source\(run.sources.count == 1 ? "" : "s") recorded.",
                tone: .success,
                systemImage: "checkmark.circle.fill"
            )
        case "needs_connector":
            return Message(
                text: "Research needs a connector",
                detail: detail ?? "Configure a research connector before this objective can return sources.",
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill"
            )
        case "failed", "error":
            return Message(
                text: "Research lab failed",
                detail: detail ?? "The research owner returned a failed receipt.",
                tone: .failure,
                systemImage: "exclamationmark.triangle.fill"
            )
        default:
            return Message(
                text: "Research result needs review",
                detail: detail ?? "The research owner returned the unrecognized status \(run.status).",
                tone: .warning,
                systemImage: "questionmark.diamond"
            )
        }
    }

    static func list(rows: [ResearchLabRun]) -> RunList {
        rows.isEmpty ? .empty : .loaded(rows)
    }

    static func unavailableList(detail: String, retained: [ResearchLabRun]) -> RunList {
        .unavailable(detail: bounded(detail), retained: retained)
    }

    private static func meaningfulDetail(for run: ResearchLabRun) -> String? {
        nonempty(run.error) ?? nonempty(run.brief)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed)
    }

    private static func bounded(_ text: String) -> String {
        let limit = 240
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

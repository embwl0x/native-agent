import AppIntents
import Foundation
import MemoryV2
import NativeAgentCore

extension SwiftNativeMemoryV2 {
    /// Sentinel-marker path written by the `MemoryV2Migrator` on a successful
    /// JSON→SQLite migration. UI checks this to render a `migrated` badge.
    public static var migrationMarkerURL: URL {
        NativeAgentPaths.dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".migrated_to_sqlite_v1", isDirectory: false)
    }
}

private func formatMemoryUnavailable(_ error: Error) -> String {
    if let mv2 = error as? MemoryV2Error {
        return "Memory unavailable: \(mv2.errorDescription ?? "unknown")"
    }
    return "Memory unavailable: \(error.localizedDescription)"
}

struct QueryMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Query Assistant Memory"
    static let description: IntentDescription = IntentDescription("Search the assistant's accumulated memory for relevant context.")
    static let openAppWhenRun = false

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask the assistant about \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "Empty query.", dialog: "Empty query.")
        }
        do {
            let response = try await SwiftNativeMemoryV2.shared.recall(
                MemoryV2RecallRequest(text: trimmed, topK: 5, persona: nil)
            )
            if response.hits.isEmpty {
                let msg = "No memories found for \"\(trimmed)\"."
                return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
            }
            let lines = response.hits.prefix(5).enumerated().map { (i, hit) -> String in
                let score = String(format: "%.2f", hit.score)
                return "\(i + 1). [\(score)] \(hit.preview)"
            }
            let text = lines.joined(separator: "\n")
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        } catch {
            let msg = formatMemoryUnavailable(error)
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
    }
}

struct StoreMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember"
    static let description: IntentDescription = IntentDescription("Store a new memory in the assistant's accumulated memory.")
    static let openAppWhenRun = false

    @Parameter(title: "Content")
    var content: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell the assistant to remember \(\.$content)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "Empty content.", dialog: "Nothing to remember.")
        }
        do {
            let record = try await SwiftNativeMemoryV2.shared.store(
                content: trimmed,
                source: "AppIntent.StoreMemoryIntent",
                metadata: nil
            )
            let msg = "Stored memory \(record.id)."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        } catch {
            let msg = formatMemoryUnavailable(error)
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
    }
}

struct ListPendingMemoryProposalsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Pending Memory Proposals"
    static let description: IntentDescription = IntentDescription("Return the count and list of the assistant's pending memory proposals.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let pending = try await SwiftNativeMemoryV2.shared.listProposals(status: "pending")
            if pending.isEmpty {
                return .result(value: "0 pending proposals.", dialog: "No pending memory proposals.")
            }
            let lines = pending.prefix(20).enumerated().map { (i, p) -> String in
                "\(i + 1). \(p.content)"
            }
            let header = "\(pending.count) pending proposal\(pending.count == 1 ? "" : "s"):"
            let text = ([header] + lines).joined(separator: "\n")
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        } catch {
            let msg = formatMemoryUnavailable(error)
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
    }
}

struct MemoryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QueryMemoryIntent(),
            phrases: [
                "Ask the assistant what it knows about \(\.$query)",
                "Ask \(.applicationName) what it knows about \(\.$query)",
            ],
            shortTitle: "Query Memory",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: StoreMemoryIntent(),
            phrases: [
                "Tell the assistant to remember \(\.$content)",
                "Tell \(.applicationName) to remember \(\.$content)",
            ],
            shortTitle: "Remember",
            systemImageName: "pencil.and.list.clipboard"
        )
        AppShortcut(
            intent: ListPendingMemoryProposalsIntent(),
            phrases: [
                "List the assistant's pending memory proposals",
                "List \(.applicationName) pending memory proposals",
            ],
            shortTitle: "Pending Proposals",
            systemImageName: "tray.full"
        )
    }
}

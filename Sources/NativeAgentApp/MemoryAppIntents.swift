import AppIntents
import Foundation
import MemoryV2

private func formatMemoryUnavailable(_ error: Error) -> String {
    if let mv2 = error as? MemoryV2Error {
        return "Memory unavailable: \(mv2.errorDescription ?? "unknown")"
    }
    return UserFacingError.message(error, action: "reach memory")
}

struct QueryMemoryIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

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
        let message = "What do you remember about \(trimmed)?"
        let reply: String
        if #available(macOS 27, *) {
            reply = try await performBackgroundTask {
                try await NativeAgentChatIntent.reply(to: message)
            }
        } else {
            reply = try await NativeAgentChatIntent.reply(to: message)
        }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

struct StoreMemoryIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

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
        let message = "Please remember this: \(content)"
        let reply: String
        if #available(macOS 27, *) {
            reply = try await performBackgroundTask {
                try await NativeAgentChatIntent.reply(to: message)
            }
        } else {
            reply = try await NativeAgentChatIntent.reply(to: message)
        }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

@available(macOS 27, *)
extension QueryMemoryIntent: LongRunningIntent {}

@available(macOS 27, *)
extension StoreMemoryIntent: LongRunningIntent {}

struct ListPendingMemoryProposalsIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "List Pending Memory Proposals"
    static let description: IntentDescription = IntentDescription("Return the count and list of the assistant's pending memory proposals.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let pending = try await SwiftNativeMemoryV2.shared.listProposals(status: "pending")
            if pending.isEmpty {
                return .result(value: "0 pending proposals.", dialog: "No pending memory proposals.")
            }
            let lines = pending.enumerated().map { (i, p) -> String in
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

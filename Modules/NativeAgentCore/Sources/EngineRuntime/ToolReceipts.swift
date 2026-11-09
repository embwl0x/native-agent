import ChatToolParsing
import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import ToolRegistry
// Blueprint: | `ToolReceipts.swift` | Frozen tool facts, shared status and exact successful persona-write receipts |

public extension TranscriptsFacade {
    @discardableResult
    @concurrent nonisolated func prepareToolFold(_ messages: [ChatMessage], expanded: Bool = false) async -> String {
        let statuses = messages.map {
            ChatShellToolSummary.status(kind: $0.metadata?.kind, ok: $0.metadata?.ok,
                resultSummary: $0.metadata?.resultSummary, resultStatus: $0.metadata?.resultStatus,
                interactionState: $0.metadata?.interactionState)
        }
        let headline = await presentation.prepare("headline:" + (messages.first?.id ?? "empty"),
            input: ChatShellToolSummary.headlineInput(count: messages.count,
                failed: statuses.filter { $0 == .failed }.count, needsYou: statuses.filter { $0 == .needsYou }.count))
        if expanded {
            for (message, status) in zip(messages, statuses).prefix(ChatShellToolSummary.detailLimit) {
                await presentation.prepare("detail:" + message.id,
                    input: ChatShellToolSummary.detailInput(toolName: message.metadata?.toolName,
                        inputJSON: message.metadata?.inputJSON, status: status))
            }
        }
        return headline
    }
}

public enum ChatShellToolSummary {
    public static let detailLimit = 4

    public typealias Status = ChatToolOutcome.FoldStatus

    /// Share metadata precedence with expanded receipts.
    public static func status(
        kind: String?, ok: Bool?, resultSummary: String?, resultStatus: String? = nil,
        interactionState: String? = nil
    ) -> Status {
        ChatToolOutcome.projection(kind: kind, ok: ok, result: resultSummary.flatMap { try? JSONValue.parse(Data($0.utf8)) }, hasResult: resultSummary != nil,
            resultStatus: resultStatus, interactionState: interactionState).status
    }

    public static func headlineInput(count: Int, failed: Int = 0, needsYou: Int = 0) -> JSONValue {
        let failed = max(0,min(failed,count))
        return .object(["kind":.string("headline"),"count":.int(Int64(count)),"failed":.int(Int64(failed)),
            "needsYou":.int(Int64(max(0,min(needsYou,count-failed))))])
    }

    /// Show only the filename; absolute paths do not belong in conversation copy.
    public static func touchedFile(inputJSON: String?) -> String? {
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["path", "file", "file_path", "filename", "target"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (value as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// Freeze tool facts and recorded outcome before authored presentation.
    public static func detailInput(toolName: String?, inputJSON: String?, status: Status = .plain) -> JSONValue {
        let call=toolName.map { ToolNameAliases.shown($0,inputJSON:inputJSON) }
        let name=(call?.name ?? toolName ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let state: String = switch status {
        case .failed: "failed"
        case .needsYou: "needsYou"
        case .asked: "asked"
        case .plain: "plain"
        }
        let title=ToolActivityPresentation.title(name)
        let lower=title.prefix(1).lowercased()+title.dropFirst()
        return .object(["kind":.string("tool"),"tool":.string(name),"status":.string(state),
            "nameCharacters":.array(title.map { .string(String($0)) }),
            "lowerCharacters":.array(lower.map { .string(String($0)) }),
            "file":touchedFile(inputJSON:call?.inputJSON ?? inputJSON).map(JSONValue.string) ?? .null,
            "subject":.string(AgentVoice.live.subject),"remember":.string(AgentVoice.live.verb("remember")),
            "possessive":.string(AgentVoice.live.possessive)])
    }

    /// Quote only successful persona writes; failures retain tool rows and unanswered writes retain cards.
    public static func personaReceipt(
        toolName: String?, inputJSON: String?, resultSummary: String?, requiredTitle: String
    ) -> (outcome: String, meta: String)? {
        guard toolName == "persona_append_section" || toolName == "app",
              let resultSummary, let result = try? JSONValue.parse(Data(resultSummary.utf8)) else { return nil }
        let reply = ToolResult(result)
        guard (ChatToolOutcome.recordedResultClass(reply.payload) ?? reply.outcome) == .succeeded,
              let path = ChatTranscriptEvidenceRendering.receiptField("path", in: reply.payload)?.stringValue, !path.isEmpty else { return nil }
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // The app door nests `persona.append` input under args.
              let object = toolName == "app"
                ? (call["action"] as? String == "persona.append" ? call["args"] as? [String: Any] : nil) : call,
              let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let content = (object["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, !content.isEmpty
        else { return nil }
        // Match the conversation’s exact progression-title write.
        guard title == requiredTitle else { return nil }
        // Quote written words verbatim.
        let line = content.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? content
        return (line, "Written to \((path as NSString).lastPathComponent) · \(title)")
    }
}

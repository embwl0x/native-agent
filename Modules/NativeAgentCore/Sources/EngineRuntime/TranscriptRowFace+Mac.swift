import Foundation
import ChatSessionWork
import ChatToolParsing
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import Transcripts
// Blueprint: | `TranscriptRowFace+Mac.swift` | The Mac's one reading of a transcript row into its face (seat, tag, bridge line, tool line and outcome, persona receipt, owed decision), for its own chat and for the phone's |

extension ChatMessage: TranscriptRow {}

extension TranscriptRowFace {
    /// What a row shows, read by the owner of the knowledge. `receiptTitle` is the conversation's persona progression title: a write under it
    /// draws as its receipt.
    public static func read(_ message: ChatMessage, receiptTitle: String?) -> TranscriptRowFace {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let metadata = message.metadata
        if role == "tool" {
            var face = TranscriptRowFace(seat: .left)
            if metadata?.isPendingApproval == true {
                face.asks = true
                return face
            }
            if let title = receiptTitle, !title.isEmpty,
               let receipt = ChatShellToolSummary.personaReceipt(toolName: metadata?.toolName, inputJSON: metadata?.inputJSON,
                                                                 resultSummary: metadata?.resultSummary, requiredTitle: title) {
                face.receipt = receipt.outcome + " · " + receipt.meta
                return face
            }
            face.failed = ChatShellToolSummary.status(kind: metadata?.kind, ok: metadata?.ok, resultSummary: metadata?.resultSummary,
                                                      resultStatus: metadata?.resultStatus,
                                                      interactionState: metadata?.interactionState) == .failed ? true : nil
            face.line = toolLine(metadata)
            return face
        }
        let words = TranscriptSearch.visibleText(of: message)
        var face = TranscriptRowFace(seat: .left, words: words == message.content ? nil : words)
        guard role == "user" else { return face }
        let bridged = ChatShellConversationRow.isBridgeRouted(metadata?.origin)
        if bridged, ChatShellEnvelope.isEnvelope(message.content, envelope: metadata?.envelope) {
            face.seat = .envelope
            return face
        }
        let isPeer = ["agent-bridge", "bot"].contains(metadata?.origin?.surface?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        let bridgeTag = bridged && !isPeer ? ChatShellConversationRow.bridgeAgentTag(message.content) : nil
        let provenance = bridgeTag == nil
            ? MacChatMessageProvenance.make(role: message.role, source: message.source, envelope: metadata?.envelope) : nil
        if bridgeTag == nil, !isPeer {
            face.seat = .right
            face.tag = provenance.map { Tag(symbol: $0.symbol, label: $0.label, automated: $0.isAutomated) }
        } else {
            face.quiet = true
            face.label = bridgeTag ?? provenance?.label
        }
        return face
    }

    /// A tool row's line before the agent's words for it are prepared: the tool's title, then its target.
    public static func toolLine(_ metadata: ChatMessageMetadata?) -> String {
        let call = ToolNameAliases.shown(metadata?.toolName ?? "tool", inputJSON: metadata?.inputJSON)
        let title = ToolActivityPresentation.title(call.name)
        let target = boundedLine(toolTarget(call.inputJSON.flatMap { try? JSONValue.parse(Data($0.utf8)) }), limit: 180)
        return target.isEmpty ? title : title + " · " + target
    }

    /// What a tool call works on, from its input's naming fields and its children's titles.
    public static func toolTarget(_ input: JSONValue?) -> String {
        guard case .object(let fields)? = input else { return "" }
        var values = ["path", "file", "file_path", "target", "task", "task_id", "parent", "title", "query", "id"]
            .compactMap { fields[$0]?.stringValue }
        if case .array(let children)? = fields["children"] {
            values += children.compactMap { child in
                guard case .object(let fields) = child else { return nil }
                return fields["title"]?.stringValue
            }
        }
        return values.joined(separator: " · ")
    }

    public static func boundedLine(_ text: String, limit: Int) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").truncated(to: limit, suffix: "…")
    }
}

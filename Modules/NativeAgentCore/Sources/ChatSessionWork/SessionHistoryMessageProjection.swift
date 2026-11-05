import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `SessionHistoryMessageProjection.swift` | `admission`, `project`. |

/// Replay the retained tail in order without rewriting its words.
/// Prior tool rounds lack provider call IDs, so render text evidence rather than inventing executable tool pairs.
/// Merge consecutive roles and preserve orphaned assistant/tool history behind a user-side historical header.
package enum SessionHistoryMessages {
    package struct Result: Sendable {
        /// A nonempty prefix must start with a user message.
        package let messages: [LLMMessage]
        /// Measure only the final rendered messages after every omission.
        package var characters: Int {
            LLMMessage.inputCharacters(messages, system: nil, tools: [])
        }
        package let replayedRunIds: Set<String>
        package var historyIdentities: Set<String> = []
        package var rowCharacters: [String: Int] = [:]
        package var replayedContexts: [SentTurnContext] = []
        package var contextWindow: String = "0:"

        package static let empty = Result(
            messages: [], replayedRunIds: []
        )
    }

    package struct Admission: Sendable {
        let renderables: [(row: SessionHistoryPromptRenderer.Renderable, body: String)]
    }

    /// Admit exact sent user blocks and whole speech rows; nonpositive history limits disable admission.
    /// A checked model budget is required even when the range is empty or disabled.
    package static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved,
        unboundedUserIdentities: Set<String> = []
    ) -> Admission? {
        admission(
            renderables: messages.compactMap(SessionHistoryPromptRenderer.renderable),
            historyLimit: historyLimit, budget: budget,
            unboundedUserIdentities: unboundedUserIdentities
        )
    }

    package static func admission(
        renderables: [SessionHistoryPromptRenderer.Renderable],
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved,
        unboundedUserIdentities: Set<String> = []
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        guard !renderables.isEmpty else { return nil }
        let rendered = renderables.map { row in
            (row: row, body: row.sentContext?.userText
                ?? (unboundedUserIdentities.contains(row.historyIdentity)
                    ? row.structuredDisplayContent : SessionHistoryPromptRenderer.projectedHistoryText(row, budget: budget)))
        }
        return Admission(renderables: rendered)
    }

    package static func project(
        messages: [ChatMessage],
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved
    ) -> Result {
        guard let admission = admission(
            messages: messages,
            historyLimit: historyLimit,
            budget: budget
        ) else { return .empty }
        return project(admission)
    }

    /// Replay stored context inside its original user block; never rebuild it or promote it to system authority.
    package static func project(
        _ admission: Admission
    ) -> Result {
        let admitted = admission.renderables
        guard !admitted.isEmpty else { return .empty }

        var out: [(role: LLMMessage.Role, content: [LLMContentBlock], identities: Set<String>)] = []
        var rowCharacters: [String: Int] = [:]
        var replayedRunIds = Set<String>()
        var replayedContexts: [SentTurnContext] = []

        func append(_ role: LLMMessage.Role, _ blocks: [LLMContentBlock], identities: Set<String>) {
            guard !blocks.isEmpty else { return }
            if out.last?.role == role {
                out[out.count - 1].content.append(contentsOf: blocks)
                out[out.count - 1].identities.formUnion(identities)
            } else {
                out.append((role, blocks, identities))
            }
        }

        for (row, body) in admitted {
            if body.isEmpty && row.sentContext?.block.isEmpty != false { continue }
            if out.isEmpty, row.isTool || row.role == "assistant" {
                append(.user, [.text("[Earlier conversation; retained assistant and tool messages follow.]")], identities: [])
            }
            if row.isTool {
                rowCharacters[row.historyIdentity] = body.count
                append(.assistant, [.text(body)], identities: [row.historyIdentity])
                continue
            }
            switch row.role {
            case "user":
                var blocks: [LLMContentBlock] = []
                if let sent = row.sentContext {
                    replayedContexts.append(sent)
                    if !sent.block.isEmpty { blocks.append(.text(sent.block)) }
                }
                // Replay only text-bearing image blocks; nonempty sent words retain exact bytes, including whitespace-only content.
                if !body.isEmpty { blocks.append(.text(body)) }
                rowCharacters[row.historyIdentity] = body.count + (row.sentContext?.block.count ?? 0)
                append(.user, blocks, identities: [row.historyIdentity])
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                }
            case "assistant":
                let text = body
                if !text.isEmpty {
                    rowCharacters[row.historyIdentity] = text.count
                    append(.assistant, [.text(text)], identities: [row.historyIdentity])
                }
            default:
                // Fold non-conversation rows into the user side rather than inventing provider roles.
                rowCharacters[row.historyIdentity] = row.role.count + 3 + body.count
                append(.user, [.text("[\(row.role)] " + body)], identities: [row.historyIdentity])
            }
        }

        let delivered = out.reduce(into: Set<String>()) { $0.formUnion($1.identities) }
        return Result(
            messages: out.map { LLMMessage(role: $0.role, content: $0.content) },
            replayedRunIds: replayedRunIds,
            historyIdentities: delivered,
            rowCharacters: rowCharacters.filter { delivered.contains($0.key) },
            replayedContexts: replayedContexts,
            contextWindow: admitted.first?.row.historyIdentity ?? "0:"
        )
    }

}

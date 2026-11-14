import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `SessionHistoryMessageProjection.swift` | `admission`, `project`. |

/// Replay the held conversation in order, each row as it was sent through the history boundaries; a moment's context block stays on its row
/// and never replays.
/// Prior tool rounds lack provider call IDs, so render text evidence rather than inventing executable tool pairs.
/// Rows that share a role join into one text block, so an exchange is two blocks whatever its tool count and the provider's
/// lookback from the boundary before the current message always reaches the previous boundary.
/// Preserve orphaned assistant/tool history behind a user-side historical header.
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
        package var contextWindow: String = "0:"

        package static let empty = Result(
            messages: [], replayedRunIds: []
        )
    }

    package struct Admission: Sendable {
        let renderables: [(row: SessionHistoryPromptRenderer.Renderable, body: String)]
        package var heldRows: Int { renderables.count }
    }

    /// Admit the whole conversation with exact sent words and whole speech; request fitting owns its input budget.
    /// Nonpositive history limits disable admission; a checked model budget is required even when the range is empty or disabled.
    package static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved
    ) -> Admission? {
        admission(
            renderables: messages.compactMap(SessionHistoryPromptRenderer.renderable),
            historyLimit: historyLimit, budget: budget
        )
    }

    /// Each row's body is its one replayed form (`Renderable.replay(words:)`), whichever source its words come from.
    package static func admission(
        renderables: [SessionHistoryPromptRenderer.Renderable],
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        guard !renderables.isEmpty else { return nil }
        return Admission(renderables: renderables.map { (row: $0, body: $0.replayed) })
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

    /// A person's row opens with its own saved time; words and receipts keep their bytes; nothing is promoted to system authority.
    package static func project(
        _ admission: Admission
    ) -> Result {
        let admitted = admission.renderables
        guard !admitted.isEmpty else { return .empty }

        var out: [(role: LLMMessage.Role, texts: [String], identities: Set<String>)] = []
        var rowCharacters: [String: Int] = [:]
        var replayedRunIds = Set<String>()

        func append(_ role: LLMMessage.Role, _ text: String, identity: String?) {
            let identities: Set<String> = identity.map { [$0] } ?? []
            if out.last?.role == role {
                out[out.count - 1].texts.append(text)
                out[out.count - 1].identities.formUnion(identities)
            } else {
                out.append((role, [text], identities))
            }
        }

        for (row, body) in admitted {
            // Nonempty bodies retain exact bytes, including whitespace-only content; an image-only row's body is its attachment evidence.
            if body.isEmpty { continue }
            if out.isEmpty, row.isTool || row.role == "assistant" {
                append(.user, "[Earlier conversation; your retained replies and call results follow.]", identity: nil)
            }
            if row.isTool {
                rowCharacters[row.historyIdentity] = body.count
                append(.assistant, body, identity: row.historyIdentity)
                continue
            }
            switch row.role {
            case "user":
                let text = row.stamp.map { $0 + "\n" + body } ?? body
                rowCharacters[row.historyIdentity] = text.count
                append(.user, text, identity: row.historyIdentity)
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                }
            case "assistant":
                rowCharacters[row.historyIdentity] = body.count
                append(.assistant, body, identity: row.historyIdentity)
            default:
                // Fold non-conversation rows into the user side rather than inventing provider roles.
                let text = "[\(row.role)] " + body
                rowCharacters[row.historyIdentity] = text.count
                append(.user, text, identity: row.historyIdentity)
            }
        }

        let delivered = out.reduce(into: Set<String>()) { $0.formUnion($1.identities) }
        return Result(
            messages: out.map { LLMMessage(role: $0.role, content: [.text($0.texts.joined(separator: "\n\n"))]) },
            replayedRunIds: replayedRunIds,
            historyIdentities: delivered,
            rowCharacters: rowCharacters.filter { delivered.contains($0.key) },
            contextWindow: admitted.first?.row.historyIdentity ?? "0:"
        )
    }

}

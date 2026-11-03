import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `SessionHistoryMessageProjection.swift` | `admission` counts exact sent user text and context blocks; `project` replays nonempty blocks on their user rows without rewriting their bytes, omits empty text for captionless images and returns delivered row identities, retained keyframes and the window identity |

/// Prior turns become an oldest-first message prefix whose bytes can be cached.
///
/// Admission shares the renderer's row filtering and role caps. The transcript
/// owns the replayed head: only a fold into recollection moves it.
///
/// Mapping (deliberately conservative — prior tool rounds have NO provider
/// call ids, so inventing `tool_use`/`tool_result` pairs would be a lie the
/// provider would reject or, worse, accept):
///   - user      → exact sent leading block + words from row metadata;
///                 legacy rows retain their existing text projection
///   - assistant → `.assistant` text, with `<tool_use>` markers STRIPPED
///                 (text-compat transcripts retain literal markers; replaying
///                 one re-injects a call)
///   - tool row  → an extra text block `[tool <name> <status>] <projection>`
///                 appended to the immediately preceding assistant message
///                 (a synthetic assistant message when there is none)
///   - compaction summary → a leading `[session recollection] …` text block on
///                 the OLDEST replayed user message
/// Consecutive same-role rows merge; a historical header preserves leading
/// assistant/tool rows while keeping `messages[0]` on the user side.
package enum SessionHistoryMessages {
    package struct Result: Sendable {
        /// Oldest → newest. Always starts with a `.user` message (or is empty).
        package let messages: [LLMMessage]
        /// Measured from the final messages produced below, after every omission.
        package var characters: Int {
            LLMMessage.inputCharacters(messages, system: nil, tools: [])
        }
        /// Run ids of the user turns this prefix actually replays.
        package let replayedRunIds: Set<String>
        package var historyIdentities: Set<String> = []
        package var rowCharacters: [String: Int] = [:]
        package var replayedContexts: [SentTurnContext] = []
        package var contextWindow: String = "0:"

        package static let empty = Result(
            messages: [], replayedRunIds: []
        )
    }

    /// Admission carries every rendered body into replay.
    package struct Admission {
        let renderables: [(row: SessionHistoryPromptRenderer.Renderable, body: String)]
    }

    /// Admission retains the contiguous range the reader returned, rendered
    /// with legacy per-row caps and exact sent user blocks/words, with
    /// compaction recollections pinned. The measured request fit folds old
    /// turns into recollection; neither a row count nor a character cap drops them.
    /// Nonpositive history limits explicitly disable admission.
    package static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        windowTokens: Int? = nil,
        unboundedUserIdentities: Set<String> = []
    ) throws -> Admission? {
        try admission(
            renderables: messages.compactMap(SessionHistoryPromptRenderer.renderable),
            historyLimit: historyLimit, windowTokens: windowTokens,
            unboundedUserIdentities: unboundedUserIdentities
        )
    }

    package static func admission(
        renderables: [SessionHistoryPromptRenderer.Renderable],
        historyLimit: Int,
        windowTokens: Int?,
        unboundedUserIdentities: Set<String> = []
    ) throws -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        guard !renderables.isEmpty else { return nil }
        let budget = try ContextBudgetPolicy.resolve(windowTokens: windowTokens)
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
        windowTokens: Int? = nil
    ) throws -> Result {
        guard let admission = try admission(
            messages: messages,
            historyLimit: historyLimit,
            windowTokens: windowTokens
        ) else { return .empty }
        return project(admission)
    }

    /// Stored context is replayed in its original user content block, never
    /// rebuilt or promoted to a system message. A new window gets a keyframe.
    package static func project(
        _ admission: Admission
    ) -> Result {
        let admitted = admission.renderables
        guard !admitted.isEmpty else { return .empty }

        var out: [(role: LLMMessage.Role, content: [LLMContentBlock], identities: Set<String>)] = []
        var rowCharacters: [String: Int] = [:]
        var pendingRecollection: String?
        var recollectionIdentities = Set<String>()
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
            if row.isCompactionSummary {
                // Held for the oldest replayed USER message rather than
                // emitted as its own turn: a synthetic role here would read as
                // a real exchange that never happened.
                rowCharacters[row.historyIdentity] = row.recollectionLabel.count + 1 + body.count
                recollectionIdentities.insert(row.historyIdentity)
                let recollection = row.recollectionLabel + " " + body
                pendingRecollection = pendingRecollection.map { $0 + "\n\n" + recollection } ?? recollection
                continue
            }
            // An orphaned assistant/tool row is still retained history. Open
            // with its recollection or an explicit history header, never drop it.
            if out.isEmpty, row.isTool || row.role == "assistant" {
                let heading = pendingRecollection ?? "[Earlier conversation; retained assistant and tool messages follow.]"
                pendingRecollection = nil
                append(.user, [.text(heading)], identities: [])
            }
            if row.isTool {
                rowCharacters[row.historyIdentity] = body.count
                append(.assistant, [.text(body)], identities: [row.historyIdentity])
                continue
            }
            switch row.role {
            case "user":
                var blocks: [LLMContentBlock] = []
                if let recollection = pendingRecollection {
                    pendingRecollection = nil
                    blocks.append(.text(recollection))
                }
                if let sent = row.sentContext {
                    replayedContexts.append(sent)
                    if !sent.block.isEmpty { blocks.append(.text(sent.block)) }
                }
                // Captionless images have no user text. Replay only blocks
                // that carry text; nonempty sent words keep their exact bytes
                // and boundary, including whitespace-only words.
                if !body.isEmpty { blocks.append(.text(body)) }
                rowCharacters[row.historyIdentity] = body.count + (row.sentContext?.block.count ?? 0)
                append(.user, blocks, identities: [row.historyIdentity])
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                }
            case "assistant":
                // A replayed assistant turn that still carries a literal
                // `<tool_use>` marker would re-issue that call on the next
                // provider read. Strip before it ever reaches the wire.
                let text = ToolCallParser.stripToolUseMarkers(body)
                if !text.isEmpty {
                    rowCharacters[row.historyIdentity] = text.count
                    append(.assistant, [.text(text)], identities: [row.historyIdentity])
                }
            default:
                // system/summary/unknown rows are not a two-party turn; fold
                // them into the user side rather than inventing a role.
                rowCharacters[row.historyIdentity] = row.role.count + 3 + body.count
                append(.user, [.text("[\(row.role)] " + body)], identities: [row.historyIdentity])
            }
        }

        // A recollection-only history still reaches the conversation as a user message.
        if out.isEmpty {
            guard let recollection = pendingRecollection else { return .empty }
            pendingRecollection = nil
            append(.user, [.text(recollection)], identities: [])
        }
        // A recollection with no surviving user row to lead still has to be
        // said: prepend it to the first message rather than dropping it.
        if let recollection = pendingRecollection, !out.isEmpty {
            out[0].content.insert(.text(recollection), at: 0)
        }
        let delivered = out.reduce(into: recollectionIdentities) { $0.formUnion($1.identities) }
        return Result(
            messages: out.map { LLMMessage(role: $0.role, content: $0.content) },
            replayedRunIds: replayedRunIds,
            historyIdentities: delivered,
            rowCharacters: rowCharacters.filter { delivered.contains($0.key) },
            replayedContexts: replayedContexts,
            contextWindow: ([""] + admitted.filter { $0.row.isCompactionSummary }.map { $0.row.historyIdentity })
                .map { "\($0.utf8.count):\($0)" }.joined()
        )
    }

}

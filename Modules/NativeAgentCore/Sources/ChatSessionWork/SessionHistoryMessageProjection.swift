import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `SessionHistoryMessageProjection.swift` | `admission` counts exact sent user text and context blocks; `project` replays nonempty blocks on their user rows without rewriting their bytes, omits empty text for captionless images and returns delivered row identities, retained keyframes and the window identity |

/// Prior turns become an oldest-first message prefix whose bytes can be cached.
///
/// Admission shares the renderer's row filtering, role caps and budgets;
/// the window cursor owns the replayed head.
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
/// Consecutive same-role rows merge; leading assistant rows are trimmed so
/// `messages[0]` is always `.user`.
package enum SessionHistoryMessages {
    package struct Result: Sendable {
        /// Oldest → newest. Always starts with a `.user` message (or is empty).
        package let messages: [LLMMessage]
        /// Run ids of the user turns this prefix actually replays.
        package let replayedRunIds: Set<String>
        package var historyIdentities: Set<String> = []
        package var replayedContexts: [SentTurnContext] = []
        package var contextWindow: String = "0:"

        package static let empty = Result(
            messages: [], replayedRunIds: []
        )
    }

    /// Admission carries the measured bodies through cursor selection into replay.
    package struct Admission {
        let renderables: [(row: SessionHistoryPromptRenderer.Renderable, body: String)]
        package let budget: ContextBudgetPolicy.Resolved
        package let rows: [HistoryWindowRow]
    }

    /// Admission retains the contiguous range the reader returned, rendered
    /// with legacy per-row caps and exact sent user blocks/words, with
    /// compaction recollections pinned. Size is enforced downstream, and only
    /// by the cursor's hysteresis — rarely, at a turn boundary, oldest-first.
    /// Nonpositive history limits disable admission; the cursor owns window sizing.
    package static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        windowTokens: Int? = nil
    ) -> Admission? {
        admission(
            renderables: messages.compactMap(SessionHistoryPromptRenderer.renderable),
            historyLimit: historyLimit, windowTokens: windowTokens
        )
    }

    package static func admission(
        renderables: [SessionHistoryPromptRenderer.Renderable],
        historyLimit: Int,
        windowTokens: Int?
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        guard !renderables.isEmpty else { return nil }
        let budget = ContextBudgetPolicy.resolve(windowTokens: windowTokens)
        let rendered = renderables.map { row in
            (row: row, body: row.sentContext?.userText ?? SessionHistoryPromptRenderer.projectedHistoryText(row, budget: budget))
        }
        let rows = rendered.map { row, body in
            HistoryWindowRow(
                identity: row.historyIdentity,
                role: row.isTool ? "tool" : row.role,
                length: body.utf8.count + (row.sentContext?.block.utf8.count ?? 0),
                isCompactionSummary: row.isCompactionSummary
            )
        }
        return Admission(renderables: rendered, budget: budget, rows: rows)
    }

    package static func project(
        messages: [ChatMessage],
        historyLimit: Int,
        windowTokens: Int? = nil,
        cursor: HistoryWindowCursor? = nil
    ) -> Result {
        guard let admission = admission(
            messages: messages,
            historyLimit: historyLimit,
            windowTokens: windowTokens
        ) else { return .empty }
        return project(
            admission, cursor: cursor
        )
    }

    /// Stored context is replayed in its original user content block, never
    /// rebuilt or promoted to a system message. A new window gets a keyframe.
    package static func project(
        _ admission: Admission,
        cursor: HistoryWindowCursor?
    ) -> Result {
        var admitted = admission.renderables
        let rows = admission.rows
        let identities = rows.map(\.identity)

        // Window cursor: drop the oldest admitted rows through (and including)
        // the recorded boundary, preserving compaction summaries. A boundary
        // that is not present (compaction rewrote the transcript) drops nothing:
        // fail-open is a bigger prompt, never a lost row.
        if let boundary = cursor?.dropBoundaryIdentity,
           let boundaryOffset = identities.firstIndex(of: boundary) {
            admitted = admitted.enumerated().compactMap { offset, row in
                offset <= boundaryOffset && !rows[offset].isCompactionSummary ? nil : row
            }
        }
        guard !admitted.isEmpty else { return .empty }

        var out: [(role: LLMMessage.Role, content: [LLMContentBlock], identities: Set<String>)] = []
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
                recollectionIdentities.insert(row.historyIdentity)
                let recollection = row.recollectionLabel + " " + body
                pendingRecollection = pendingRecollection.map { $0 + "\n\n" + recollection } ?? recollection
                continue
            }
            // Her kept rows lead the tail: the recollection opens as a user
            // message so the tail survives the user-first trim below.
            if out.isEmpty, row.isTool || row.role == "assistant",
               let recollection = pendingRecollection {
                pendingRecollection = nil
                append(.user, [.text(recollection)], identities: [])
            }
            if row.isTool {
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
                append(.user, blocks, identities: [row.historyIdentity])
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                }
            case "assistant":
                // A replayed assistant turn that still carries a literal
                // `<tool_use>` marker would re-issue that call on the next
                // provider read. Strip before it ever reaches the wire.
                let text = ToolCallParser.stripToolUseMarkers(body)
                if !text.isEmpty { append(.assistant, [.text(text)], identities: [row.historyIdentity]) }
            default:
                // system/summary/unknown rows are not a two-party turn; fold
                // them into the user side rather than inventing a role.
                append(.user, [.text("[\(row.role)] " + body)], identities: [row.historyIdentity])
            }
        }

        // Every provider's replay prefix opens on a user turn.
        if let recollection = pendingRecollection, out.first?.role == .assistant {
            pendingRecollection = nil
            out.insert((.user, [.text(recollection)], []), at: 0)
        }
        while let first = out.first, first.role != .user {
            out.removeFirst()
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
        return Result(
            messages: out.map { LLMMessage(role: $0.role, content: $0.content) },
            replayedRunIds: replayedRunIds,
            historyIdentities: out.reduce(into: recollectionIdentities) { $0.formUnion($1.identities) },
            replayedContexts: replayedContexts,
            contextWindow: ([cursor?.dropBoundaryIdentity ?? ""] + admitted.filter { $0.row.isCompactionSummary }.map { $0.row.historyIdentity })
                .map { "\($0.utf8.count):\($0)" }.joined()
        )
    }

}

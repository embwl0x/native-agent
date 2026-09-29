import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - SessionHistoryMessageProjection (v2Prefix conversation prefix)

/// Prior turns → `[LLMMessage]`, oldest→newest, for the `v2Prefix`
/// conversation shape.
///
/// The whole point of v2 is that the transcript stops riding the DYNAMIC
/// system segment (which churns every turn and therefore can never be cached
/// across turns) and becomes a real message prefix that a provider cache can
/// match byte-for-byte from one turn to the next.
///
/// ADMISSION IS NOT RE-DERIVED. This replays EXACTLY the rows
/// `SessionHistoryPromptRenderer.conversationHistory` admits — same
/// `renderable` filter, same `capForRole`, same
/// `budget(for:windowTokens:)`, same newest-first fill including the
/// compaction-summary reservation — by calling the renderer's own internal
/// helpers. A second, drifting copy of that rule is the one way this change
/// could silently change what the model sees.
///
/// Mapping (deliberately conservative — prior tool rounds have NO provider
/// call ids, so inventing `tool_use`/`tool_result` pairs would be a lie the
/// provider would reject or, worse, accept):
///   - user      → `.user` text
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
package enum SessionHistoryMessageProjection {
    package struct Result: Sendable {
        /// Oldest → newest. Always starts with a `.user` message (or is empty).
        package let messages: [LLMMessage]
        /// Every admitted row reduced to what the window cursor needs —
        /// identity, role, rendered length, anchor/recollection exemption.
        /// Payload-free by construction: no transcript content leaves here.
        package let rows: [HistoryWindowRow]
        /// Sum of every rendered row's v1 line length — the number the window
        /// cursor compares against `budget.historyChars`.
        package let usedChars: Int
        /// Rows the cursor skipped this turn (already outside the window).
        package let droppedRowCount: Int
        /// Run ids of the user turns this prefix actually replays. The volatile
        /// archive is pruned to exactly this set: a block whose position is no
        /// longer in the prefix cannot be replayed into it.
        package let replayedRunIds: Set<String>

        package var admittedIdentities: [String] { rows.map(\.identity) }

        package static let empty = Result(
            messages: [], rows: [], usedChars: 0, droppedRowCount: 0, replayedRunIds: []
        )
    }

    /// How a REPLAYED tool row announces itself to the model.
    ///
    /// 2026-09-13: this used to read `[tool <name> <status>]`, which looks
    /// exactly like a receipt the app prints. A model that had just run
    /// `tool_load` reproduced that shape verbatim in ordinary prose —
    /// "[tool bot_create ran] bot_create ok after approval: {...}" — for a call
    /// it never made, and the text read as a real receipt. The information is
    /// unchanged (tool name, status, projected result); only the shape is, so
    /// the prefix no longer teaches a receipt template. The UI never trusts
    /// this string either way — a receipt renders only from a real tool row.
    static func replayedToolLabel(name: String?, status: String?) -> String {
        "Earlier this session \(name ?? "a tool") \(status ?? "ran") and returned:"
    }

    /// Rows pinned at the HEAD regardless of the window cursor. Mirrors the
    /// reader's `anchorLimit: 3` — the opening of a session is what makes the
    /// rest of it legible, so sliding the window never eats it.
    static let anchorLimit = 3

    /// The admitted rows ALONE, without building any message. The window
    /// cursor needs the rows to decide whether to advance, and the projection
    /// needs the cursor's answer — so the admission runs once here and both
    /// halves read it, rather than the projection running twice per turn.
    package struct Admission {
        let renderables: [SessionHistoryPromptRenderer.Renderable]
        package let budget: ContextBudgetPolicy.Resolved
        package let rows: [HistoryWindowRow]
        package var usedChars: Int { rows.reduce(0) { $0 + $1.length + 1 } }
    }

    /// v2 ADMISSION — deliberately NOT the v1 rule.
    ///
    /// v1 fills newest-first against `budget.historyChars` and re-runs that
    /// fill every turn. Both halves of that are per-turn moving parts: the
    /// `suffix(historyLimit)` head slides as the session grows, and the
    /// budget fill re-decides where the block starts every time a row's size
    /// changes. Either one rewrites the head of the replayed prefix, which is
    /// precisely what a provider cache cannot survive — so on v2 they are both
    /// gone and the cursor is the ONLY head.
    ///
    /// What remains here: the contiguous range the reader returned, rendered
    /// under the SAME per-row caps (`capForRole`), with the anchors and the
    /// compaction recollection pinned. Size is enforced downstream, and only
    /// by the cursor's hysteresis — rarely, at a turn boundary, oldest-first.
    ///
    /// `historyLimit == 0` still means "no history"; it is the disable switch,
    /// not a window.
    package static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        let renderables = messages.compactMap(SessionHistoryPromptRenderer.renderable)
        guard !renderables.isEmpty else { return nil }
        let budget = SessionHistoryPromptRenderer.budget(
            for: surface, windowTokens: windowTokens
        )
        let anchorIdentities = Set(
            renderables
                .filter { $0.role == "user" || $0.role == "assistant" }
                .prefix(anchorLimit)
                .map(\.historyIdentity)
        )
        let rows = renderables.map { row in
            HistoryWindowRow(
                identity: row.historyIdentity,
                role: row.isTool ? "tool" : row.role,
                length: SessionHistoryPromptRenderer
                    .renderedHistoryLine(row, budget: budget).count,
                isAnchor: anchorIdentities.contains(row.historyIdentity),
                isCompactionSummary: row.isCompactionSummary
            )
        }
        return Admission(renderables: renderables, budget: budget, rows: rows)
    }

    package static func project(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil,
        cursor: HistoryWindowCursor? = nil,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        guard let admission = admission(
            messages: messages,
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: windowTokens
        ) else { return .empty }
        return project(
            admission, cursor: cursor, archivedTurnMessages: archivedTurnMessages
        )
    }

    /// `archivedTurnMessages` (run id → the messages that turn sent after its
    /// user turn, in order) replays each earlier turn's mid-conversation system
    /// messages at THEIR ORIGINAL POSITIONS: immediately after the user message
    /// they followed, before that turn's assistant reply.
    ///
    /// Two kinds ride here and both must stay. The turn-scoped volatile block
    /// is cleared once a later user message arrives — 0 input tokens — but must
    /// remain in `messages`. The `tool_addition`/`tool_removal` message is NOT
    /// turn-scoped at all, and removing an already-sent one invalidates the
    /// prefix from that point.
    ///
    /// This is not an optimization, it is the contract. A cleared turn-scoped
    /// message costs 0 input tokens but must STAY in `messages` byte-for-byte;
    /// omitting it makes turn N+1's prefix diverge from turn N's at the element
    /// right after `user(N)`, so everything from there — the previous turn's
    /// tool rounds and reply included — is re-created at full price.
    ///
    /// Empty by default, so every non-clear_at lane is unchanged.
    package static func project(
        _ admission: Admission,
        cursor: HistoryWindowCursor?,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        var admitted = admission.renderables
        let budget = admission.budget
        let rows = admission.rows
        let usedChars = admission.usedChars
        let identities = rows.map(\.identity)

        // Window cursor: drop the oldest admitted rows through (and including)
        // the recorded boundary. Anchors and the compaction summary are exempt
        // — they are the two row classes whose loss is not recoverable from
        // what remains. A boundary that is not present (compaction rewrote the
        // transcript, or the window already slid past it) drops nothing:
        // fail-open is a bigger prompt, never a lost row.
        var droppedRowCount = 0
        if let boundary = cursor?.dropBoundaryIdentity,
           let boundaryOffset = identities.firstIndex(of: boundary) {
            // THE HEAD IS THE BOUNDARY — nothing is pinned in front of it.
            //
            // Anchors used to be exempt, which produced `anchors ‖ GAP ‖ live
            // window`. The anchors themselves are deterministic (the reader
            // takes the first lines of the transcript file, not
            // relevance-chosen rows), but the row immediately AFTER them is
            // whatever the reader's sliding tail happened to reach back to, so
            // the joint between the two moved as the session grew — and the
            // merge of a trailing anchor into that first live row changed with
            // it. That is a head that differs between requests even while the
            // cursor reports stable.
            //
            // Now the emitted head is exactly the first row after the persisted
            // boundary, so `messages[0]` is a pure function of the cursor. The
            // opening of the session is not lost: `continuityState` carries
            // "Initial anchors: …" in the volatile block, which is where
            // per-turn relevance material belongs anyway.
            //
            // The compaction recollection is the one exception — it is the only
            // surviving record of everything already elided, and it leads the
            // oldest replayed user message rather than standing as a row.
            var kept: [SessionHistoryPromptRenderer.Renderable] = []
            for (offset, row) in admitted.enumerated() {
                if offset <= boundaryOffset, !rows[offset].isCompactionSummary {
                    droppedRowCount += 1
                    continue
                }
                kept.append(row)
            }
            admitted = kept
        }
        guard !admitted.isEmpty else { return .empty }

        var out: [LLMMessage] = []
        var pendingRecollection: String?
        var replayedRunIds = Set<String>()
        // A replayed block is HELD until the turn's assistant reply is emitted.
        // The same wire rule that governs the current turn governs a replayed
        // one: a system message may end the array or precede an assistant turn,
        // never precede a user turn. A turn whose reply is not in the prefix
        // (transient failure, filtered by `renderable`) has no intact position
        // to replay into, and the tail block would sit directly before the
        // CURRENT user message — so both cases drop the block rather than
        // emit an array the provider rejects.
        var pendingReplay: (runId: String, messages: [LLMMessage])?

        func flushPendingReplay() {
            guard let pending = pendingReplay else { return }
            pendingReplay = nil
            out.append(contentsOf: pending.messages)
        }

        func appendText(_ role: LLMMessage.Role, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.role == role {
                out[out.count - 1] = LLMMessage(role: role, content: last.content + [.text(text)])
            } else {
                out.append(LLMMessage(role: role, content: [.text(text)]))
            }
        }

        for row in admitted {
            let body = SessionHistoryPromptRenderer.projectedHistoryText(row, budget: budget)
            if body.isEmpty { continue }
            if row.isCompactionSummary {
                // Held for the oldest replayed USER message rather than
                // emitted as its own turn: a synthetic role here would read as
                // a real exchange that never happened.
                pendingRecollection = row.recollectionLabel + " " + body
                continue
            }
            // Her kept rows lead the tail: the recollection opens as a user
            // message so the tail survives the user-first trim below.
            if out.isEmpty, row.isTool || row.role == "assistant",
               let recollection = pendingRecollection {
                pendingRecollection = nil
                out.append(LLMMessage(role: .user, content: [.text(recollection)]))
            }
            if row.isTool {
                flushPendingReplay()
                let label = Self.replayedToolLabel(
                    name: row.toolName, status: row.toolStatus
                )
                if let last = out.last, last.role == .assistant {
                    out[out.count - 1] = LLMMessage(
                        role: .assistant,
                        content: last.content + [.text("\(label) \(body)")]
                    )
                } else {
                    out.append(LLMMessage(
                        role: .assistant, content: [.text("\(label) \(body)")]
                    ))
                }
                continue
            }
            switch row.role {
            case "user":
                pendingReplay = nil
                if let recollection = pendingRecollection {
                    pendingRecollection = nil
                    if let last = out.last, last.role == .user {
                        out[out.count - 1] = LLMMessage(
                            role: .user, content: last.content + [.text(recollection), .text(body)]
                        )
                    } else {
                        out.append(LLMMessage(
                            role: .user, content: [.text(recollection), .text(body)]
                        ))
                    }
                } else {
                    appendText(.user, body)
                }
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                    // Byte-for-byte, in position, exactly once — held until the
                    // reply proves the position is intact.
                    if let replay = archivedTurnMessages[runId], !replay.isEmpty,
                       pendingReplay == nil {
                        pendingReplay = (runId, replay)
                    }
                }
            case "assistant":
                flushPendingReplay()
                // A replayed assistant turn that still carries a literal
                // `<tool_use>` marker would re-issue that call on the next
                // provider read. Strip before it ever reaches the wire.
                appendText(.assistant, ToolCallParser.stripToolUseMarkers(body))
            default:
                // system/summary/unknown rows are not a two-party turn; fold
                // them into the user side rather than inventing a role.
                pendingReplay = nil
                appendText(.user, "[\(row.role)] " + body)
            }
        }

        // The tail block is deliberately dropped: `seed` appends the CURRENT
        // user message next, and a system message directly before it is the
        // exact 400 this shape has to avoid.
        pendingReplay = nil
        // A conversation must open on a user turn: an assistant-first prefix is
        // rejected outright by the Anthropic wire and reads as a hallucinated
        // opening everywhere else. A leading system row would be equally
        // invalid, and the same loop removes it.
        // 2026-09-23: unless a recollection is waiting — then IT opens the
        // conversation as a user message. Dropping her kept rows here left the
        // recollection alone and she confabulated the lost stretch (00:51).
        if let recollection = pendingRecollection, out.first?.role == .assistant {
            pendingRecollection = nil
            out.insert(LLMMessage(role: .user, content: [.text(recollection)]), at: 0)
        }
        while let first = out.first, first.role != .user {
            out.removeFirst()
        }
        // User, 2026-09-06: a summary-only history dropped the WHOLE
        // recollection here. A backstop compaction can leave the newest raw
        // message as the only survivor, and at turn start that is the current
        // user row, which history reading excludes by run id — so projection
        // sees the summary alone, holds it in pendingRecollection, produces no
        // ordinary message, and returned `.empty` BEFORE the preservation
        // fallback two lines below. The recollection is the session's entire
        // memory of itself; it goes out on a user message of its own.
        if out.isEmpty {
            guard let recollection = pendingRecollection else { return .empty }
            pendingRecollection = nil
            out = [LLMMessage(role: .user, content: [.text(recollection)])]
        }
        // A recollection with no surviving user row to lead still has to be
        // said: prepend it to the first message rather than dropping it.
        if let recollection = pendingRecollection, let first = out.first {
            out[0] = LLMMessage(role: first.role, content: [.text(recollection)] + first.content)
        }
        return Result(
            messages: out,
            rows: rows,
            usedChars: usedChars,
            droppedRowCount: droppedRowCount,
            replayedRunIds: replayedRunIds
        )
    }
}

import ChatToolParsing
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting

// Blueprint: | `IntraTurnContextCompaction.swift` | `IntraTurnContextCompaction`: context measurement and pressure receipts; working notes cover the complete rendered span in bounded consecutive chunks before replacement, with explicit output allowance and oversized-note rejection |

// MARK: - Intra-turn context compaction
//
// Measure the in-flight conversation and shrink overflow before retrying the provider.
// Under pressure, stub results before the retained recent rounds, then fold the turn's middle into first-person working notes.
// Folds replace their span with an assistant note followed by a user continuation.
// Only the in-flight array changes; persisted history comes from dispatch records and progress events.
// Folding preserves the seeded request and leading context through turnStartIndex; ChatCompactionDistiller owns prior turns.
public enum IntraTurnContextCompaction {

    // MARK: - Tuning constants

    /// Window assumed when the model id resolves to nothing. Matches
    /// `ProviderRouting`'s own pessimistic default for an unrecognized id, so an
    /// unknown model gets the same gauge here as everywhere else.
    static let defaultWindowTokens = 128_000

    /// Where compaction aims: 70% of the window. Leaves room for the system
    /// prompt, the tool schemas, and the reply the model still has to write —
    /// none of which live in `conversation`.
    static let targetFraction = 0.70

    /// Where compaction TRIGGERS on the proactive path: 80% of the window. The
    /// gap between this and `targetFraction` is deliberate hysteresis — trimming
    /// to 70% means the next few rounds do not re-trigger.
    static let pressureFraction = 0.80

    /// Ceiling on what the distiller is ASKED to read. The rendered span is
    /// post-stub and therefore small in the normal case; this is the guard for
    /// the case where it is not, so the working-notes call can never itself
    /// overflow the window it exists to protect.
    static let distillInputMaxChars = 120_000

    /// The one line a surface shows while a compaction is in flight, and the
    /// notice kind both surfaces match on.
    static let noticeKind = "context_compaction"
    static let noticeText = "Trimming my working context to keep going…"

    // MARK: - Receipt

    /// What one compaction pass actually did. `mode` is the closed vocabulary
    /// the trace and the reactive caller both read: "none" means there was
    /// nothing left to trim, so the provider's refusal is her part's input.
    struct Receipt: Sendable {
        let charsBefore: Int
        let charsAfter: Int
        /// "stub" | "fold_llm" | "cap" | "none"
        let mode: String
        /// Why no working notes were written, when they were needed and are not.
        var failure: ToolFailureError?
    }
    /// Working notes, or the receipt of why there are none.
    typealias Distill = @Sendable (String) async throws -> Result<String, ToolFailureError>

    // MARK: - Measurement

    /// Characters the in-flight conversation contributes to the request body.
    /// Text, tool-use (id + name + input JSON) and tool-result (id + body)
    /// blocks only: image blocks ride the CURRENT user message, are never
    /// re-sent, and so are not part of the mass that grows round over round.
    static func estimatedChars(_ conversation: [LLMMessage]) -> Int {
        conversation.reduce(0) { total, message in
            total + message.content.reduce(0) { blockTotal, block in
                switch block {
                case .text(let text):
                    return blockTotal + text.count
                case .toolUse(let id, let name, let inputJSON):
                    return blockTotal + id.count + name.count + inputJSON.count
                case .toolResult(let toolUseId, let content, _):
                    return blockTotal + toolUseId.count + content.count
                case .image:
                    return blockTotal
                }
            }
        }
    }

    static func targetChars(windowTokens: Int?) -> Int {
        chars(windowTokens: windowTokens, fraction: targetFraction)
    }

    static func pressureChars(windowTokens: Int?) -> Int {
        chars(windowTokens: windowTokens, fraction: pressureFraction)
    }

    /// Align proactive pressure with ContextBudgetPolicy's window, bounded by model room after persona, tools and output.
    /// Unknown models use the saved threshold within the default 128k window.
    static func effectiveWindowTokens(_ windowTokens: Int?) -> Int {
        let trimPoint: Int
        if let window = windowTokens, window > 0 {
            let requestRoom = Int(Double(window) * 1.5) - 72_000
            trimPoint = max(window / 2, min(window, requestRoom))
        } else {
            trimPoint = min(
                Int(Double(defaultWindowTokens) * pressureFraction),
                ChatSessionAutocompactionConfig.productionDefault().thresholdTokens
            )
        }
        return max(1, Int(Double(trimPoint) / pressureFraction))
    }

    private static func chars(windowTokens: Int?, fraction: Double) -> Int {
        let tokens = effectiveWindowTokens(windowTokens)
        return Int(Double(tokens) * ContextBudgetPolicy.charactersPerToken * fraction)
    }

    // MARK: - Compaction

    /// Proactive compaction keeps the recent tail whole; confirmed overflow may shrink it and cap result bodies.
    enum Pressure: Sendable { case proactive, overflow }
    static let overflowResultCapChars = 4_000
    static let priorNoteMarker = "[Working notes from earlier in this turn]"
    /// Reserve at most one tenth of the input ceiling for carried notes, so
    /// later chunks retain most of their source room. Notes are carried whole.
    static let noteCapChars = distillInputMaxChars / 10

    /// Measure and trim before the next provider call, publishing changed receipts.
    /// Returns the pass's receipt when pressure was exceeded, nil when not.
    static func compactProactivelyIfNeeded(
        conversation: inout [LLMMessage],
        turnStartIndex: Int,
        windowTokens: Int?,
        distill: Distill,
        surface: String,
        progress: TurnEventSink?
    ) async throws -> Receipt? {
        guard estimatedChars(conversation) > pressureChars(windowTokens: windowTokens) else {
            return nil
        }
        let receipt = try await IntraTurnContextCompaction.compact(
            conversation: &conversation,
            turnStartIndex: turnStartIndex,
            windowTokens: windowTokens,
            distill: distill
        )
        if receipt.mode != "none" {
            TurnTraceBus.fireFromContext(
                kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                surface: surface,
                payload: IntraTurnContextCompaction.tracePayload(
                    receipt, trigger: "pressure"
                )
            )
            await progress?(.notice(
                kind: IntraTurnContextCompaction.noticeKind,
                text: IntraTurnContextCompaction.noticeText
            ))
        }
        return receipt
    }

    static func compact(
        conversation: inout [LLMMessage],
        turnStartIndex: Int,
        windowTokens: Int?,
        keepRecentRounds: Int = 5,
        pressure: Pressure = .proactive,
        distill: Distill
    ) async throws -> Receipt {
        let charsBefore = estimatedChars(conversation)
        // Confirmed overflow requires a body strictly smaller than the refused request, regardless of the estimate.
        let target = pressure == .overflow
            ? min(targetChars(windowTokens: windowTokens), Int(Double(charsBefore) * 0.7))
            : targetChars(windowTokens: windowTokens)

        // Where the keep tail begins: the start of the last `keepRecentRounds`
        // rounds of THIS turn (a round = one assistant message carrying
        // tool_use blocks — or, on the marker protocol, tool markers in its
        // text — plus the tool-result user message that answers it).
        let foldStart = min(max(turnStartIndex + 1, 0), conversation.count)
        let rounds = conversation.indices.filter { idx in
            idx >= foldStart
                && conversation[idx].role == .assistant
                && conversation[idx].content.contains { block in
                    switch block {
                    case .toolUse: return true
                    case .text(let text): return !ToolCallParser.parse(text, parseInvoke: true, recordShims: false).isEmpty
                    default: return false
                    }
                }
        }
        let keepTailStart: Int = {
            guard !rounds.isEmpty, keepRecentRounds > 0 else { return conversation.count }
            guard rounds.count > keepRecentRounds else { return rounds[0] }
            return rounds[rounds.count - keepRecentRounds]
        }()

        // Stub results before the keep tail, including the prefix; retain heads and recovery markers without repeating effects.
        // Render working notes from pre-stub messages while the provider receives the stubbed array.
        let preStub = conversation
        var stubbed = false
        for idx in conversation.indices where idx < keepTailStart {
            guard conversation[idx].role == .user else { continue }
            var changed = false
            let blocks = conversation[idx].content.map { block -> LLMContentBlock in
                guard case .toolResult(let toolUseId, let content, let isError) = block,
                      let stub = IntraTurnToolResultClearing.stub(content) else {
                    return block
                }
                changed = true
                return .toolResult(toolUseId: toolUseId, content: stub, isError: isError)
            }
            if changed {
                conversation[idx] = LLMMessage(role: .user, content: blocks)
                stubbed = true
            }
        }
        if estimatedChars(conversation) <= target {
            return Receipt(
                charsBefore: charsBefore,
                charsAfter: estimatedChars(conversation),
                mode: stubbed ? "stub" : "none"
            )
        }

        // STEP B — fold the span between the seeded prefix and the keep tail
        // into one working-notes message.
        guard keepTailStart > foldStart else {
            return try await overflowFallback(
                conversation: &conversation, foldStart: foldStart, target: target,
                charsBefore: charsBefore, mode: stubbed ? "stub" : "none",
                turnStartIndex: turnStartIndex, windowTokens: windowTokens,
                keepRecentRounds: keepRecentRounds, pressure: pressure, distill: distill
            )
        }
        // Pin the previous fold's note as the distiller's earlier notes, preserving it when older steps are removed.
        var spanStart = foldStart
        var priorNote = ""
        if case .text(let text)? = conversation[foldStart].content.first,
           conversation[foldStart].role == .assistant,
           text.hasPrefix(priorNoteMarker) {
            priorNote = String(text.dropFirst(priorNoteMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            spanStart = min(foldStart + 2, keepTailStart)   // note + its continuation line
        }
        // Rendered from the PRE-STUB messages (step A only replaced bodies in
        // place, so the indices are the same array positions).
        let rendered = render(preStub[spanStart..<keepTailStart])
        // Empty source must not distill a note from itself; overflow handling can widen the fold span to include real steps.
        guard !rendered.isEmpty else {
            return try await overflowFallback(
                conversation: &conversation, foldStart: foldStart, target: target,
                charsBefore: charsBefore, mode: stubbed ? "stub" : "none",
                turnStartIndex: turnStartIndex, windowTokens: windowTokens,
                keepRecentRounds: keepRecentRounds, pressure: pressure, distill: distill
            )
        }
        // Read the WHOLE rendered span, oldest first. Each accepted note carries
        // the preceding chunks into the next; no source is removed until all
        // chunks succeed. Never suffix-cut source or truncate a returned note.
        var remaining = rendered[...]
        var body = priorNote
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let pinned = try (body.isEmpty ? "" : completionPolicy("working-notes", section: "prior") + body + "\n\n")
            let instructions = try completionPolicy("working-notes", section: "prompt", arguments: [String(noteCapChars)])
            let steps = try completionPolicy("working-notes", section: "steps")
            let room = distillInputMaxChars - pinned.count - instructions.count - steps.count
            guard room > 0 else {
                return Receipt(charsBefore: charsBefore, charsAfter: estimatedChars(conversation), mode: stubbed ? "stub" : "none",
                               failure: ToolFailureError("The earlier working notes leave no room for the next source chunk.", effects: .none))
            }
            let piece = String(remaining.prefix(room))
            switch try await distill(instructions + pinned + steps + piece) {
            case .success(let text):
                guard text.count <= noteCapChars else {
                    return Receipt(charsBefore: charsBefore, charsAfter: estimatedChars(conversation), mode: stubbed ? "stub" : "none",
                                   failure: ToolFailureError("The working-notes model exceeded its \(noteCapChars)-character output allowance; the source span was kept.", effects: .none))
                }
                body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else {
                    return Receipt(charsBefore: charsBefore, charsAfter: estimatedChars(conversation), mode: stubbed ? "stub" : "none",
                                   failure: ToolFailureError("The working-notes model returned no text.", effects: .none))
                }
            case .failure(let failure):
                return Receipt(charsBefore: charsBefore, charsAfter: estimatedChars(conversation), mode: stubbed ? "stub" : "none",
                               failure: failure)
            }
            remaining = remaining.dropFirst(piece.count)
        }
        try Task.checkCancellation()
        let mode = "fold_llm"
        var continuation = "[Continue the task from these notes; earlier tool results were folded into them.]"
        if let turnId = TurnTraceContext.turnId,
           let read = try? JSONValue.object(["action": .string("trace.recent"), "args": .object([
                "turn_id": .string(turnId), "kind": .string("tool.dispatch"), "fields": .array([.string("receipt")]),
           ])]).serialize(pretty: false) {
            continuation += "\n[Source: working notes. Recorded dispatch receipts: app \(read). Previews are not execution; dispatch is not verified effect.]"
        }
        conversation.replaceSubrange(foldStart..<keepTailStart, with: [
            .assistantText("\(priorNoteMarker)\n\(body)"),
            .user(continuation),
        ])
        return try await overflowFallback(
            conversation: &conversation, foldStart: foldStart, target: target,
            charsBefore: charsBefore, mode: mode,
            turnStartIndex: turnStartIndex, windowTokens: windowTokens,
            keepRecentRounds: keepRecentRounds, pressure: pressure, distill: distill
        )
    }

    /// Under a confirmed overflow, keep going until the body fits: fold more
    /// of the tail (5 → 2 → 0 recent rounds kept), then cap every remaining
    /// tool-result body. Proactive trims stop after one pass.
    private static func overflowFallback(
        conversation: inout [LLMMessage],
        foldStart: Int,
        target: Int,
        charsBefore: Int,
        mode: String,
        turnStartIndex: Int,
        windowTokens: Int?,
        keepRecentRounds: Int,
        pressure: Pressure,
        distill: Distill
    ) async throws -> Receipt {
        let after = estimatedChars(conversation)
        guard pressure == .overflow, after > target else {
            return Receipt(charsBefore: charsBefore, charsAfter: after, mode: mode)
        }
        if keepRecentRounds > 0 {
            let inner = try await compact(
                conversation: &conversation,
                turnStartIndex: turnStartIndex,
                windowTokens: windowTokens,
                keepRecentRounds: keepRecentRounds > 2 ? 2 : 0,
                pressure: pressure,
                distill: distill
            )
            return Receipt(charsBefore: charsBefore, charsAfter: inner.charsAfter,
                           mode: inner.mode == "none" ? mode : inner.mode, failure: inner.failure)
        }
        var capped = false
        for idx in conversation.indices where idx >= foldStart && conversation[idx].role == .user {
            var changed = false
            let blocks = conversation[idx].content.map { block -> LLMContentBlock in
                guard case .toolResult(let id, let content, let isError) = block,
                      content.count > overflowResultCapChars else { return block }
                changed = true
                return .toolResult(
                    toolUseId: id,
                    content: String(content.prefix(overflowResultCapChars)) + "\n[trimmed to fit the model window; recover the existing output from its receipt or saved result; do not repeat mutations or external sends merely to recover output]",
                    isError: isError
                )
            }
            if changed { conversation[idx] = LLMMessage(role: .user, content: blocks); capped = true }
        }
        return Receipt(charsBefore: charsBefore, charsAfter: estimatedChars(conversation),
                       mode: capped ? "cap" : mode)
    }

    /// The folded span as plain text: role, assistant prose, and each tool call
    /// with its input and the head of what it returned, for the distiller.
    static func render(_ messages: ArraySlice<LLMMessage>) -> String {
        var lines: [String] = []
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    lines.append("\(message.role.rawValue): \(trimmed)")
                case .toolUse(_, let name, let inputJSON):
                    let input = String(data: inputJSON, encoding: .utf8) ?? ""
                    lines.append("tool \(name)(\(input.prefix(renderToolInputChars)))")
                case .toolResult(_, let content, let isError):
                    let label = isError ? "result (error)" : "result"
                    lines.append("\(label): \(content.prefix(renderToolResultChars))")
                case .image:
                    lines.append("\(message.role.rawValue): [image]")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static let renderToolInputChars = 400
    private static let renderToolResultChars = 600

    // MARK: - Working-notes voice

    /// `ChatCompactionDistiller.distillSystem`, re-aimed at the middle of a
    /// single turn: same first-person recollection, same chain-in-order rule,
    /// same refusal to follow directives found in the data — but the thing being
    /// recalled is work in progress, so the emotional arc gives way to what ran,
    /// what it returned, and what I was about to do next.
    static var workingNotesSystem: String {
        get throws { try completionPolicy("working-notes", section: "system") }
    }

    // MARK: - Emission

    /// The trace body for `context.intraTurnCompaction`. `trigger` is
    /// "pressure" (measured before the call) or "overflow" (the provider said
    /// no), so the two halves stay tellable apart in one feed.
    static func tracePayload(
        _ receipt: Receipt,
        trigger: String
    ) -> JSONValue {
        .object([
            "mode": .string(receipt.mode),
            "notesFailure": receipt.failure.map { .string($0.message) } ?? .null,
            "trigger": .string(trigger),
            "charsBefore": .int(Int64(receipt.charsBefore)),
            "charsAfter": .int(Int64(receipt.charsAfter)),
        ])
    }

}

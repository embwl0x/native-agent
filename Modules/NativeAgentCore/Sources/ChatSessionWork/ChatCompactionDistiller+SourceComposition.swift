import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
import ProviderRouting
import Transcripts
import TurnTrace
// Blueprint: | `ChatCompactionDistiller+SourceComposition.swift` | Consecutive source chunks and proportional output allowances; verified-window prompt budget and first-person recollection prompt composition |

extension ChatCompactionDistiller {
    /// First-person chronological recollection with attributed verbatim lines.
    public static var distillSystem: String {
        get throws { try completionPolicy("transcript-recollection", section: "system") }
    }

    /// Window share for source; the rest covers instructions, reasoning and output.
    private static let promptWindowFraction = 0.45

    /// ContextBudgetPolicy owns the verified window and chars-per-token convention.
    /// Unknown windows allow 32k source characters; known windows reserve instructions.
    static func promptBudgetChars(forModel model: String, providerID: String?, dataRoot: URL) throws -> Int {
        guard let windowTokens = ContextBudgetPolicy.windowTokens(
            forModel: model, providerID: providerID, dataRoot: dataRoot
        ) else { return maxSourceChunkChars }
        let derived = Int(
            Double(windowTokens) * ContextBudgetPolicy.charactersPerToken * promptWindowFraction
        )
        return try max(0, min(maxSourceChunkChars, derived - distillSystem.count - 1_024))
    }

    /// Consecutive oldest-first chunks of the caller's selected source.
    struct PromptPlan: Sendable, Equatable {
        var chunks: [SourceChunk]
    }

    struct SourceChunk: Sendable, Equatable {
        let body: String
        let source: [JSONValue]
        var joinsPreviousRow = false
        var targetBlockChars: Int {
            let ratio = ChatCompactionDistiller.sourceToBlockRatio
            return max(1, body.count / ratio + (body.count % ratio == 0 ? 0 : 1))
        }
        var minimumBlockChars: Int {
            let ratio = ChatCompactionDistiller.sourceToBlockMinimumRatio
            return max(1, body.count / ratio + (body.count % ratio == 0 ? 0 : 1))
        }
        var maximumBlockChars: Int {
            let ratio = ChatCompactionDistiller.sourceToBlockCapRatio
            return min(ChatCompactionDistiller.maxBlockChars,
                       max(1, body.count / ratio + (body.count % ratio == 0 ? 0 : 1)))
        }
    }

    static func composePrompt(chunk: SourceChunk, index: Int, count: Int) throws -> String {
        let openingRole: String
        if case .object(let row)? = chunk.source.first, case .string(let role)? = row["role"] {
            openingRole = role
        } else { openingRole = "message" }
        return try completionPolicy("transcript-recollection", section: "prompt", arguments: [
            String(index + 1),
            String(count),
            String(chunk.body.count),
            String(chunk.targetBlockChars),
            String(sourceToBlockRatio),
            String(chunk.minimumBlockChars),
            String(sourceToBlockMinimumRatio),
            String(chunk.maximumBlockChars),
            String(sourceToBlockCapRatio),
            openingRole,
            chunk.body
        ])
    }

    /// Stored recollections enter only when selected for a rollup or pending work.
    static func buildPlan(
        from rows: [JSONValue], budget: Int
    ) -> PromptPlan {
        let maximum = min(maxSourceChunkChars, budget)
        guard maximum > 0 else { return PromptPlan(chunks: []) }
        var renderedRows: [(row: JSONValue, line: String)] = []
        for row in rows {
            guard case .object(let obj) = row,
                  let rendered = ChatCompactionRowRendering.summaryBody(
                    obj, collapseNewlines: false,
                    toolSummaryCap: ChatCompactionRowRendering.distillerToolResultSummaryMaximumCharacters
                  ) else { continue }
            let role: String
            if case .string(let value)? = obj["role"] { role = value }
            else { role = "message" }
            renderedRows.append((row, "\(role): \(rendered)"))
        }
        // Balance chunk sizes so a wide row cannot leave a nearly empty tail.
        let total = renderedRows.reduce(0) { total, row in
            row.line.count < Int.max - total ? total + row.line.count + 1 : Int.max
        }
        let count = max(1, total / maximum + (total % maximum == 0 ? 0 : 1))
        let chunkBudget = max(1, min(maximum, total / count + (total % count == 0 ? 0 : 1)))
        var chunks: [SourceChunk] = []
        var body = ""
        var source: [JSONValue] = []
        var joinsPreviousRow = false
        func flush() {
            guard !body.isEmpty else { return }
            chunks.append(SourceChunk(body: body, source: source, joinsPreviousRow: joinsPreviousRow))
            body = ""
            source = []
            joinsPreviousRow = false
        }
        for (row, line) in renderedRows {
            // Prefer whole rows. A wider row is split losslessly, with the
            // original row attached to each piece for coverage and receipts.
            if !body.isEmpty, body.count >= chunkBudget || line.count >= chunkBudget - body.count { flush() }
            var remaining = line[...]
            while !remaining.isEmpty {
                let piece = String(remaining.prefix(chunkBudget))
                remaining = remaining.dropFirst(piece.count)
                if !body.isEmpty { body += "\n" }
                body += piece
                source.append(row)
                if !remaining.isEmpty {
                    flush()
                    joinsPreviousRow = true
                }
            }
        }
        flush()
        // Merge a tail below half the nominal budget when the source ceiling permits.
        // Otherwise quotes still yield to the proportional output allowance.
        if chunks.count > 1, let tail = chunks.last, tail.body.count < chunkBudget / 2 {
            let previous = chunks[chunks.count - 2]
            let combined = previous.body + (tail.joinsPreviousRow ? "" : "\n") + tail.body
            let covered = previous.source + (tail.joinsPreviousRow ? Array(tail.source.dropFirst()) : tail.source)
            if combined.count <= maximum {
                chunks.removeLast(2)
                chunks.append(SourceChunk(body: combined, source: covered, joinsPreviousRow: previous.joinsPreviousRow))
            }
        }
        return PromptPlan(chunks: chunks)
    }
}

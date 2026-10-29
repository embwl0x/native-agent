import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionSelection.swift` | Compaction pass selection and recollection fold |
extension ChatSessionAutocompactor {
    func begin(
        rawSessionId: String,
        model: String,
        providerID: String?,
        trigger: String,
        thresholdTokensOverride: Int?,
        force: Bool
    ) -> Begin {
        guard let sessionId = NativeAgentChatSessionID.normalizedPathComponent(rawSessionId) else {
            return .skip(skipped(
                sessionId: rawSessionId,
                reason: "invalid session id",
                trigger: trigger
            ))
        }
        let messagesPath = messagesPath(sessionId: sessionId)
        let sourceBytesBefore = Self.fileSize(messagesPath)
        guard sourceBytesBefore > 0 else {
            return .skip(skipped(
                sessionId: sessionId,
                reason: "missing or empty transcript",
                trigger: trigger
            ))
        }
        let modelThresholdTokens = config.effectiveThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        return .pass(Pass(
            sessionId: sessionId,
            messagesPath: messagesPath,
            sourceBytesBefore: sourceBytesBefore,
            thresholdTokens: thresholdTokensOverride
                .map { max(1, min($0, modelThresholdTokens)) } ?? modelThresholdTokens,
            windowTokens: modelThresholdTokens,
            divisor: ContextBudgetPolicy.transcriptCharactersPerToken
        ))
    }
    /// One prefix replacement, split the way the durable write needs it.
    struct Fold {
        let replaced: [JSONValue]
        let kept: [JSONValue]
        let retainedRows: [JSONValue]
        let foldingRows: [JSONValue]
        let pendingResults: [JSONValue]
        let preservedCards: [JSONValue]
        let removableRows: [JSONValue]
        let preservedCount: Int
        let rollsUpRecollections: Bool
        init(rows: [JSONValue], replaceCount: Int, preserving preservedCount: Int = 0,
             rollsUpRecollections: Bool = false) {
            self.preservedCount = preservedCount
            self.rollsUpRecollections = rollsUpRecollections
            replaced = Array(rows.prefix(replaceCount))
            kept = Array(rows.suffix(rows.count - replaceCount))
            func retain(_ row: JSONValue) -> Bool {
                ChatSessionAutocompactor.hasPendingDistillation(row)
                    || (!rollsUpRecollections && ChatSessionAutocompactor.isRecollection(row))
            }
            retainedRows = Array(replaced.prefix(preservedCount))
                + replaced.dropFirst(preservedCount).filter(retain)
            foldingRows = replaced.dropFirst(preservedCount).filter { !retain($0) }
            // Preserve unanswered, retryable and resumable inline cards verbatim.
            let (results, compactible) = InlineInteractionCompactionRetention.splitPendingResults(foldingRows)
            let (cards, removable) = InlineInteractionCompactionRetention.split(compactible)
            pendingResults = results
            preservedCards = cards
            removableRows = removable
        }
        /// Ordinary folds need new source after holding back earlier blocks
        /// and live cards. An explicit size-triggered rollup may instead
        /// replace an oversized recollection, even a single legacy block.
        var worthCompacting: Bool {
            !removableRows.isEmpty
                && (rollsUpRecollections || removableRows.count > 1
                    || ChatSessionAutocompactor.containsRawTurn(removableRows))
        }
    }
    enum Selection {
        case skip(ChatSessionCompactionOutcome)
        case fold(Fold)
    }
    /// What this pass would fold from `rows`, or why it folds nothing.
    func select(
        _ pass: Pass,
        rows: [JSONValue],
        trigger: String,
        force: Bool
    ) throws -> Selection {
        let sessionId = pass.sessionId
        let effectiveThresholdTokens = pass.thresholdTokens
        let divisor = pass.divisor
        let before = rows.count
        let transcriptChars = Self.transcriptCharacterCount(rows)
        let estimatedTokens = max(0, Int((Double(transcriptChars) / divisor).rounded()))
        func skip(_ reason: String) -> Selection {
            .skip(skipped(
                sessionId: sessionId,
                reason: reason,
                trigger: trigger,
                thresholdTokens: effectiveThresholdTokens,
                estimatedTokensBefore: estimatedTokens,
                transcriptCharsBefore: transcriptChars,
                messagesBefore: before,
                messagesAfter: before,
                sourceBytesBefore: pass.sourceBytesBefore
            ))
        }
        guard force || estimatedTokens >= effectiveThresholdTokens else {
            return skip("below threshold")
        }
        let mark = try ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
        if let rollup = Self.recollectionRollup(rows: rows, pass: pass, mark: mark) {
            return .fold(rollup)
        }
        // At a 240k threshold, the first 85% crossing has about 204k raw
        // tokens: fold about 72k and leave 132k verbatim. Earlier blocks do
        // not spend this raw-history allowance. Turn/card and dream boundaries
        // can leave more raw history; never shrink to a fixed recent row count.
        let candidateReplaceCount = Self.rawHistoryReplacementCount(
            rows: rows, windowTokens: pass.windowTokens, divisor: divisor, force: force
        )
        // Earlier blocks are not source for this fold, even when their old
        // coverage straddles today's dream mark. Apply the mark to ONLY the
        // new material, then translate its cut back to transcript positions.
        let sourceOffsets = rows.prefix(candidateReplaceCount).indices.filter {
            !Self.isRecollection(rows[$0])
        }
        let sourceRows = sourceOffsets.map { rows[$0] }
        let safeSourceCount = Self.markSafeReplacementCount(
            rows: sourceRows, replaceCount: sourceRows.count, mark: mark
        )
        guard safeSourceCount > 0 else {
            return skip("not enough new messages to compact")
        }
        let replaceCount = Self.keepingLastUserRow(
            rows: rows,
            replaceCount: safeSourceCount == sourceRows.count
                ? candidateReplaceCount : sourceOffsets[safeSourceCount]
        )
        guard replaceCount > 0 else {
            return skip("not enough messages to compact")
        }
        let fold = Fold(rows: rows, replaceCount: replaceCount)
        guard fold.worthCompacting else {
            return skip("nothing compactible beside preserved inline cards")
        }
        return .fold(fold)
    }
    /// Earlier blocks stay verbatim unless their own mass exceeds 10% of the
    /// effective window (and 8,000 characters). Roll up one side of the dream
    /// mark at a time; newer raw turns are never included in that rewrite.
    private static func recollectionRollup(rows: [JSONValue], pass: Pass, mark: Date?) -> Fold? {
        let count = rows.prefix { isRecollection($0) && !hasPendingDistillation($0) }.count
        guard count > 0,
              Double(transcriptCharacterCount(Array(rows.prefix(count))))
                > max(Double(minimumRollupSourceChars),
                      Double(pass.windowTokens) * pass.divisor * recollectionWindowFraction)
        else { return nil }
        let safeCount = markSafeReplacementCount(rows: rows, replaceCount: count, mark: mark)
        func fold(_ end: Int, preserving: Int = 0) -> Fold? {
            guard end > preserving else { return nil }
            let candidate = Fold(rows: rows, replaceCount: end, preserving: preserving,
                                 rollsUpRecollections: true)
            guard transcriptCharacterCount(candidate.removableRows)
                > minimumRollupSourceChars else { return nil }
            return candidate
        }
        if let beforeMark = fold(safeCount) { return beforeMark }
        guard safeCount > 0, safeCount < count else { return nil }
        // The small already-dreamed prefix stays; only the newer blocks fold.
        let newer = Array(rows.dropFirst(safeCount))
        let newerCount = markSafeReplacementCount(rows: newer, replaceCount: count - safeCount, mark: mark)
        return fold(safeCount + newerCount, preserving: safeCount)
    }
    /// The durable replacement, under the caller's transcript lock. With no
    /// `recollection` the summary row is written pending, for the caller to
    /// distill from the verified backup; with one, it is written finished.
}

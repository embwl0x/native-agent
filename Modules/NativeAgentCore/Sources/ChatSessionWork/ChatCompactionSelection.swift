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
    ) async throws -> Begin {
        guard let sessionId = NativeAgentChatSessionID.normalizedPathComponent(rawSessionId) else {
            return .skip(skipped(
                sessionId: rawSessionId,
                reason: "invalid session id",
                trigger: trigger
            ))
        }
        let messagesPath = messagesPath(sessionId: sessionId)
        let sourceBytesBefore = try Self.fileSize(messagesPath)
        guard sourceBytesBefore > 0 else {
            return .skip(skipped(
                sessionId: sessionId,
                reason: "missing or empty transcript",
                trigger: trigger
            ))
        }
        let modelThresholdTokens = try await config.effectiveThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        guard let window = config.effectiveWindowTokens(forModel: model, providerID: providerID, dataRoot: dataRoot) else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable.")
        }
        return .pass(Pass(
            sessionId: sessionId,
            messagesPath: messagesPath,
            sourceBytesBefore: sourceBytesBefore,
            thresholdTokens: thresholdTokensOverride
                .map { max(0, min($0, modelThresholdTokens)) } ?? modelThresholdTokens,
            windowTokens: window,
            model: model, providerID: providerID
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
        let preservedRows: Set<JSONValue>
        let rollsUpRecollections: Bool
        init(rows: [JSONValue], replaceCount: Int, preserving preservedRows: Set<JSONValue> = [],
             rollsUpRecollections: Bool = false) {
            self.preservedRows = preservedRows
            self.rollsUpRecollections = rollsUpRecollections
            replaced = Array(rows.prefix(replaceCount))
            kept = Array(rows.suffix(rows.count - replaceCount))
            func retain(_ row: JSONValue) -> Bool {
                preservedRows.contains(row) || ChatSessionAutocompactor.hasPendingDistillation(row)
                    || (!rollsUpRecollections && ChatSessionAutocompactor.isRecollection(row))
            }
            retainedRows = replaced.filter(retain)
            foldingRows = replaced.filter { !retain($0) }
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
        rows storedRows: [JSONValue],
        trigger: String,
        force: Bool
    ) async throws -> Selection {
        let sessionId = pass.sessionId
        let before = storedRows.count
        let transcriptChars = try Self.transcriptCharacterCount(storedRows)
        let measurement = try await SessionContextMeasurement.read(rows: storedRows, sessionId: sessionId,
            model: pass.model, providerID: pass.providerID, dataRoot: dataRoot, windowTokens: pass.windowTokens, requestBuilder: requestBuilder)
        let effectiveThresholdTokens = min(pass.thresholdTokens, config.triggerTokens(in: pass.windowTokens, outputTokens: measurement.outputTokens))
        let estimatedTokens = measurement.tokens
        await emitContextSizeTrace(kind: "context.measurement", sessionId: sessionId,
            payload: ["model": .string(pass.model), "source": .string(measurement.source),
                "inputTokens": .int(Int64(estimatedTokens)), "outputTokens": .int(Int64(measurement.outputTokens)), "windowTokens": .int(Int64(pass.windowTokens)),
                "thresholdTokens": .int(Int64(effectiveThresholdTokens)),
                "targetTokens": .int(Int64(config.targetTokens(in: pass.windowTokens, outputTokens: measurement.outputTokens))),
                "renderedCharacters": .int(Int64(measurement.renderedCharacters)),
                "requestCharacters": .int(Int64(measurement.requestCharacters)),
                "charactersPerToken": .double(measurement.charactersPerToken)])
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
        guard force || requestBuilder != nil || measurement.hasReceipt else {
            return skip("built request measurement unavailable; awaiting an admitted request")
        }
        guard force || estimatedTokens >= effectiveThresholdTokens else {
            return skip("below threshold")
        }
        let mark = try ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
        // Select every kind of fold from the same replay-visible rows. Hidden
        // raw rows must neither become source nor hide a later recollection.
        let offsets = storedRows.indices.filter { measurement.characters(in: [storedRows[$0]]) > 0 }
        let rows = offsets.map { storedRows[$0] }
        func selected(_ candidate: Fold) -> Selection {
            let end = offsets[candidate.replaced.count - 1] + 1
            let source = Set(candidate.foldingRows)
            let preserved = Set(storedRows.prefix(end).filter { !source.contains($0) })
            return .fold(Fold(rows: storedRows, replaceCount: end, preserving: preserved,
                              rollsUpRecollections: candidate.rollsUpRecollections))
        }
        // Reduce raw history first. A recollection-only rollup cannot consume
        // this pass while reducible raw history still keeps the request over target.
        let visibleReplaceCount = try Self.rawHistoryReplacementCount(
            rows: rows, targetTokens: config.targetTokens(in: pass.windowTokens, outputTokens: measurement.outputTokens), measurement: measurement, force: force
        )
        // The full transcript still owns live-row barriers even when such a
        // row is not part of replay. Bound the visible selection at that cut.
        let storedEnd = visibleReplaceCount > 0 ? offsets[visibleReplaceCount - 1] + 1 : 0
        let allowedEnd = Self.keepingLastUserRow(rows: storedRows, replaceCount: storedEnd)
        let candidateReplaceCount = offsets.prefix { $0 < allowedEnd }.count
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
        if safeSourceCount > 0 {
            let replaceCount = Self.keepingLastUserRow(
                rows: rows,
                replaceCount: safeSourceCount == sourceRows.count
                    ? candidateReplaceCount : sourceOffsets[safeSourceCount]
            )
            if replaceCount > sourceOffsets[0] {
                let fold = Fold(rows: rows, replaceCount: replaceCount)
                if fold.worthCompacting, measurement.characters(in: fold.removableRows) > 0 { return selected(fold) }
            }
        }
        let rollupEnd = Self.keepingLastUserRow(rows: storedRows, replaceCount: storedRows.count)
        let rollupCount = offsets.prefix { $0 < rollupEnd }.count
        if let rollup = try Self.recollectionRollup(rows: Array(rows.prefix(rollupCount)), pass: pass, mark: mark,
                                                   divisor: measurement.charactersPerToken) {
            return selected(rollup)
        }
        return skip("no reducible history beside protected turns/cards and the dream boundary")
    }
    /// Earlier blocks stay verbatim unless their own mass exceeds 10% of the
    /// effective window (and 8,000 characters). Roll up one side of the dream
    /// mark at a time; newer raw turns are never included in that rewrite.
    private static func recollectionRollup(rows: [JSONValue], pass: Pass, mark: Date?, divisor: Double) throws -> Fold? {
        let count = rows.prefix { isRecollection($0) && !hasPendingDistillation($0) }.count
        guard count > 0,
              Double(try transcriptCharacterCount(Array(rows.prefix(count))))
                > max(Double(minimumRollupSourceChars),
                      Double(pass.windowTokens) * divisor * recollectionWindowFraction)
        else { return nil }
        let safeCount = markSafeReplacementCount(rows: rows, replaceCount: count, mark: mark)
        func fold(_ end: Int, preserving: Int = 0) throws -> Fold? {
            guard end > preserving else { return nil }
            let candidate = Fold(rows: rows, replaceCount: end, preserving: Set(rows.prefix(preserving)),
                                 rollsUpRecollections: true)
            guard try transcriptCharacterCount(candidate.removableRows)
                > minimumRollupSourceChars else { return nil }
            return candidate
        }
        if let beforeMark = try fold(safeCount) { return beforeMark }
        guard safeCount > 0, safeCount < count else { return nil }
        // The small already-dreamed prefix stays; only the newer blocks fold.
        let newer = Array(rows.dropFirst(safeCount))
        let newerCount = markSafeReplacementCount(rows: newer, replaceCount: count - safeCount, mark: mark)
        return try fold(safeCount + newerCount, preserving: safeCount)
    }
    /// The durable replacement, under the caller's transcript lock. With no
    /// `recollection` the summary row is written pending, for the caller to
    /// distill from the verified backup; with one, it is written finished.
}

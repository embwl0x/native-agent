import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatSessionAutocompactor.swift` | Aging at 85% folds oldest raw history toward 55% of the effective threshold, retaining earlier blocks and live cards; rare dream-safe rollups above 10% of the effective window; ContactThread owns verified-backup replacements and original-history bytes; config owns `effectiveWindowTokens` and `contextWindowReadout` |
public struct ChatSessionAutocompactor: Sendable {
    static let maximumCompactBackups = 5
    /// Only a needed compaction pass may roll up earlier blocks. The floor
    /// keeps tiny windows from repeatedly rewriting one already-short block.
    static let recollectionWindowFraction = 0.10
    static let minimumRollupSourceChars = 8_000
    let dataRoot: URL
    let config: ChatSessionAutocompactionConfig
    let now: @Sendable () -> Date
    public init(
        dataRoot: URL,
        config: ChatSessionAutocompactionConfig = .productionDefault(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.config = config
        self.now = now
    }
    public func compactIfNeeded(
        sessionId rawSessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String? = nil,
        trigger: String = "auto_threshold",
        force: Bool = false,
        pendingOnly: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        let pass: Pass
        switch begin(
            rawSessionId: rawSessionId, model: model, providerID: providerID, trigger: trigger,
            thresholdTokensOverride: nil, force: force
        ) {
        case .skip(let outcome): return outcome
        case .pass(let begun): pass = begun
        }
        return try await SwiftNativePersistenceCore.withFileLock(pass.messagesPath) {
            var (rows, transcript) = try await readJSONLHonest(pass.messagesPath)
            let pending = try await pendingDistillationOutcome(
                    sessionId: pass.sessionId, messagesPath: pass.messagesPath, rows: &rows, transcript: &transcript,
                    trigger: trigger, sourceBytes: pass.sourceBytesBefore
                )?.carrying(transcript)
            if let pending { return pending }
            if pendingOnly {
                return skipped(sessionId: pass.sessionId, reason: "recollections ready", trigger: trigger).carrying(transcript)
            }
            if let below = belowFileThreshold(pass, trigger: trigger, force: force) {
                return below.carrying(transcript)
            }
            switch try select(pass, rows: rows, trigger: trigger, force: force) {
            case .skip(let outcome):
                return outcome.carrying(transcript)
            case .fold(let fold):
                return try await replace(
                    fold, in: pass, rows: rows, sourceBytes: transcript, trigger: trigger, model: model,
                    surface: surface, runId: runId, recollection: nil
                )
            }
        }
    }
    /// The aging lane's fold, chosen under the transcript lock but not yet
    /// written. Its recollection is distilled from `source` with the lock
    /// released and the live transcript untouched, so a turn arriving
    /// meanwhile reads its history as it is and waits on nothing. The lock is
    /// taken again only for the durable replacement, which first checks the
    /// replaced prefix is still exactly `source`.
    public struct AgingFold: Sendable {
        public let sessionId: String
        let thresholdTokens: Int
        /// Exactly what this block folds: ordinary passes exclude all earlier
        /// blocks and retained cards/results. Replacement verifies the whole prefix.
        public let source: [JSONValue]
        let replaced: [JSONValue]
        let preservedCount: Int
        let rollsUpRecollections: Bool
    }
    public enum AgingStart: Sendable {
        /// Below the boundary, or nothing worth folding.
        case nothing(ChatSessionCompactionOutcome)
        /// A foreground compaction left a recollection owed in the transcript.
        case pending(ChatSessionCompactionOutcome)
        case fold(AgingFold)
    }
    /// Choose what aging would fold. Never writes, except the same repair of
    /// a pending recollection's metadata every pass performs.
    public func startAging(
        sessionId rawSessionId: String,
        model: String,
        providerID: String?,
        trigger: String,
        thresholdTokens: Int
    ) async throws -> AgingStart {
        let pass: Pass
        switch begin(
            rawSessionId: rawSessionId, model: model, providerID: providerID, trigger: trigger,
            thresholdTokensOverride: thresholdTokens, force: false
        ) {
        case .skip(let outcome): return .nothing(outcome)
        case .pass(let begun): pass = begun
        }
        return try await SwiftNativePersistenceCore.withFileLock(pass.messagesPath) {
            var (rows, transcript) = try await readJSONLHonest(pass.messagesPath)
            if let pending = try await pendingDistillationOutcome(
                sessionId: pass.sessionId, messagesPath: pass.messagesPath, rows: &rows, transcript: &transcript,
                trigger: trigger, sourceBytes: pass.sourceBytesBefore
            ) {
                return .pending(pending)
            }
            if let below = belowFileThreshold(pass, trigger: trigger, force: false) {
                return .nothing(below)
            }
            switch try select(pass, rows: rows, trigger: trigger, force: false) {
            case .skip(let outcome):
                return .nothing(outcome)
            case .fold(let fold):
                return .fold(AgingFold(
                    sessionId: pass.sessionId,
                    thresholdTokens: pass.thresholdTokens,
                    source: fold.removableRows,
                    replaced: fold.replaced,
                    preservedCount: fold.preservedCount,
                    rollsUpRecollections: fold.rollsUpRecollections
                ))
            }
        }
    }
    /// True while the transcript still opens with exactly the replaced prefix
    /// and the dream's mark still lets the new source fold whole. Checked before each
    /// distill pass, so a source that moved on stops costing completions.
    public func agingFoldIsCurrent(_ fold: AgingFold) async throws -> Bool {
        let path = messagesPath(sessionId: fold.sessionId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let (rows, _) = try await readJSONLHonest(path)
            return try isCurrent(fold, rows: rows)
        }
    }
    /// The durable half of an aging pass: under the lock, verify the replaced
    /// prefix is unchanged, then back up and replace it with the finished
    /// recollection. A prefix that changed while the model worked (a backstop
    /// or manual compaction, an answered card, a dream that moved its mark)
    /// drops the pass with nothing written; the next append past the boundary
    /// schedules a fresh one.
    package func commitAging(
        _ fold: AgingFold,
        recollection: [ChatCompactionDistiller.Block],
        distillModel: String,
        model: String,
        surface: String,
        runId: String?,
        trigger: String
    ) async throws -> ChatSessionCompactionOutcome {
        let path = messagesPath(sessionId: fold.sessionId)
        let pass = Pass(
            sessionId: fold.sessionId,
            messagesPath: path,
            sourceBytesBefore: Self.fileSize(path),
            thresholdTokens: fold.thresholdTokens,
            windowTokens: config.effectiveThresholdTokens(forModel: model, dataRoot: dataRoot),
            divisor: ContextBudgetPolicy.transcriptCharactersPerToken
        )
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let (rows, transcript) = try await readJSONLHonest(path)
            guard try isCurrent(fold, rows: rows) else {
                return skipped(
                    sessionId: fold.sessionId,
                    reason: "source changed while distilling",
                    trigger: trigger,
                    thresholdTokens: fold.thresholdTokens,
                    messagesBefore: rows.count,
                    messagesAfter: rows.count,
                    sourceBytesBefore: pass.sourceBytesBefore
                )
            }
            return try await replace(
                Fold(rows: rows, replaceCount: fold.replaced.count, preserving: fold.preservedCount,
                     rollsUpRecollections: fold.rollsUpRecollections), in: pass, rows: rows, sourceBytes: transcript,
                trigger: trigger, model: model, surface: surface, runId: runId,
                recollection: (recollection, distillModel)
            )
        }
    }
    private func isCurrent(_ fold: AgingFold, rows: [JSONValue]) throws -> Bool {
        let count = fold.replaced.count
        return try count > 0 && rows.count >= count
            && Array(rows.prefix(count)) == fold.replaced
            && Self.markSafeReplacementCount(
                rows: fold.source,
                replaceCount: fold.source.count,
                mark: ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
            ) == fold.source.count
    }
    /// One pass's fixed facts, read before the transcript lock.
    struct Pass {
        let sessionId: String
        let messagesPath: URL
        let sourceBytesBefore: Int64
        let thresholdTokens: Int
        let windowTokens: Int
        let divisor: Double
    }
    /// The file-size prefilter: well under the boundary, nothing to measure.
    private func belowFileThreshold(_ pass: Pass, trigger: String, force: Bool) -> ChatSessionCompactionOutcome? {
        guard !force, Double(pass.sourceBytesBefore) < Double(pass.thresholdTokens) * pass.divisor else { return nil }
        return skipped(
            sessionId: pass.sessionId,
            reason: "below threshold by file size",
            trigger: trigger,
            thresholdTokens: pass.thresholdTokens,
            sourceBytesBefore: pass.sourceBytesBefore
        )
    }
    enum Begin {
        case skip(ChatSessionCompactionOutcome)
        case pass(Pass)
    }
}

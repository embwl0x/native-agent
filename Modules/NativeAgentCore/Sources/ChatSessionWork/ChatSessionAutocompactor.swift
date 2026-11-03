import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatSessionAutocompactor.swift` | Shared actual-request-builder measurement; configured Compact at trigger and proportional aging/verified target; raw folds select visible dream-safe source before needed recollection rollups; ContactThread owns verified-backup replacement; config owns detected/Custom windows |
public struct ChatSessionAutocompactor: Sendable {
    static let maximumCompactBackups = 5
    /// Only a needed compaction pass may roll up earlier blocks. The floor
    /// keeps tiny windows from repeatedly rewriting one already-short block.
    static let recollectionWindowFraction = 0.10
    static let minimumRollupSourceChars = 8_000
    let dataRoot: URL
    let config: ChatSessionAutocompactionConfig
    let now: @Sendable () -> Date
    /// Live turns supply their composed builder. Between turns, measurement
    /// owns saved-plan replay or the explicitly labelled history estimate.
    let requestBuilder: SessionContextRequest.Builder?
    public init(
        dataRoot: URL,
        config: ChatSessionAutocompactionConfig = .productionDefault(),
        requestBuilder: SessionContextRequest.Builder? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.config = config
        self.requestBuilder = requestBuilder
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
        pendingOnly: Bool = false,
        towardTarget: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        let pass: Pass
        switch try await begin(
            rawSessionId: rawSessionId, model: model, providerID: providerID, trigger: trigger,
            thresholdTokensOverride: towardTarget ? try await targetTokens(model: model, providerID: providerID) + 1 : nil, force: force
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
                return skipped(sessionId: pass.sessionId, reason: "recollections ready", trigger: trigger,
                    thresholdTokens: pass.thresholdTokens, messagesBefore: rows.count, messagesAfter: rows.count,
                    sourceBytesBefore: Int64(transcript.count)).carrying(transcript)
            }
            switch try await select(pass, rows: rows, trigger: trigger, force: force) {
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
        /// The exact admitted room used when this immutable fold was selected.
        let windowTokens: Int
        /// Exactly what this block folds: ordinary passes exclude all earlier
        /// blocks and retained cards/results. Replacement verifies the whole prefix.
        public let source: [JSONValue]
        let replaced: [JSONValue]
        let preservedRows: Set<JSONValue>
        let rollsUpRecollections: Bool
        let model: String
        let providerID: String?
        let measuredTokensBefore: Int
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
        thresholdTokens: Int,
        towardTarget: Bool = false
    ) async throws -> AgingStart {
        let pass: Pass
        switch try await begin(
            rawSessionId: rawSessionId, model: model, providerID: providerID, trigger: trigger,
            thresholdTokensOverride: towardTarget ? try await targetTokens(model: model, providerID: providerID) + 1 : thresholdTokens, force: false
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
            switch try await select(pass, rows: rows, trigger: trigger, force: false) {
            case .skip(let outcome):
                return .nothing(outcome)
            case .fold(let fold):
                return .fold(AgingFold(
                    sessionId: pass.sessionId,
                    thresholdTokens: pass.thresholdTokens,
                    windowTokens: pass.windowTokens,
                    source: fold.removableRows,
                    replaced: fold.replaced,
                    preservedRows: fold.preservedRows,
                    rollsUpRecollections: fold.rollsUpRecollections,
                    model: model, providerID: providerID,
                    measuredTokensBefore: try await SessionContextMeasurement.read(rows: rows, sessionId: pass.sessionId,
                        model: model, providerID: providerID, dataRoot: dataRoot, windowTokens: pass.windowTokens, requestBuilder: requestBuilder).tokens
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
            sourceBytesBefore: try Self.fileSize(path),
            thresholdTokens: fold.thresholdTokens,
            windowTokens: fold.windowTokens,
            model: fold.model, providerID: fold.providerID
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
                Fold(rows: rows, replaceCount: fold.replaced.count, preserving: fold.preservedRows,
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
        let model: String
        let providerID: String?
    }
    public func targetTokens(model: String, providerID: String?) async throws -> Int {
        if let failure = config.configurationFailure { throw ProviderRoutingError.configurationFailed(failure) }
        guard let window = config.effectiveWindowTokens(forModel: model, providerID: providerID, dataRoot: dataRoot) else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable.")
        }
        let output = try await SessionContextMeasurement.outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot)
        return config.targetTokens(in: window, outputTokens: output)
    }

    /// The finished fold is judged by its actual rendered size. The ask in the
    /// distiller is not an output guarantee; no-progress is an owned failure,
    /// never another unbounded series of rewrites.
    public func targetReached(sessionId: String, model: String, providerID: String?,
                              previousTokens: Int? = nil) async throws -> Bool {
        let target = try await targetTokens(model: model, providerID: providerID)
        guard let window = config.effectiveWindowTokens(forModel: model, providerID: providerID, dataRoot: dataRoot) else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable.")
        }
        let measurement = try await SessionContextMeasurement.read(sessionId: sessionId, model: model,
            providerID: providerID, dataRoot: dataRoot, windowTokens: window, requestBuilder: requestBuilder)
        guard measurement.messageCount > 0 else {
            throw ProviderRoutingError.configurationFailed("The transcript is missing or empty after compaction; its target cannot be verified. Restore its retained source before compacting again.")
        }
        guard requestBuilder != nil || measurement.hasReceipt else {
            // A manual fold with no request measured on this route yet: the fold stands and the
            // next turn measures it (and folds again if it is still over the trigger).
            await emitContextSizeTrace(kind: "context.compact.target", sessionId: sessionId,
                payload: ["targetTokens": .int(Int64(target)), "windowTokens": .int(Int64(window)),
                    "status": .string("measured_next_turn")])
            return true
        }
        let reached = measurement.tokens <= target
        let stalled = !reached && previousTokens.map { measurement.tokens >= $0 } == true
        await emitContextSizeTrace(kind: "context.compact.target", sessionId: sessionId,
            payload: ["inputTokens": .int(Int64(measurement.tokens)), "targetTokens": .int(Int64(target)),
                "source": .string(measurement.source), "windowTokens": .int(Int64(window)),
                "requestCharacters": .int(Int64(measurement.requestCharacters)),
                "status": .string(reached ? "reached" : (stalled ? "no_progress" : "continuing"))])
        if stalled {
            throw ProviderRoutingError.configurationFailed("Compaction did not reduce the measured request toward its \(target)-token target (\(measurement.tokens) tokens remain). The recollection is retained; repair the fold before compacting again.")
        }
        return reached
    }
    enum Begin {
        case skip(ChatSessionCompactionOutcome)
        case pass(Pass)
    }
}

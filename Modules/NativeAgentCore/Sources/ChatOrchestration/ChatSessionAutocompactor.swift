import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

public struct ChatSessionAutocompactionConfig: Sendable, Equatable {
    public static let defaultsKey = "nativeagent.compactionThresholdTokens"
    public static let distillEnabledKey = "nativeagent.compactionDistillEnabled"
    public static let agingEnabledKey = "nativeagent.compactionAgingEnabled"
    public static let defaultThresholdTokens = 200_000
    public static let defaultKeepCount = 20
    public static let maximumContextWindowFraction = 0.40
    /// Fraction of the threshold at which older turns start aging into
    /// recollection — the continuous lane (NORTHSTAR clause 4, sweep item 45).
    /// A quarter is deliberately far below the backstop: by the time a session
    /// could reach the stop-the-world threshold, aging has already folded its
    /// older turns away several times, so the synchronous check finds nothing.
    public static let defaultAgingFraction = 0.25

    public var enabled: Bool
    public var thresholdTokens: Int
    public var keepCount: Int
    /// When true (and a pre-compaction backup exists), the autocompactor's
    /// caller spawns a fire-and-forget LLM pass that swaps the mechanical
    /// compaction summary for a richer, recollection-voice distillation. Any
    /// distill failure leaves the mechanical summary untouched (fail-safe).
    public var distillEnabled: Bool
    /// The continuous lane. When true, the append that crosses the aging
    /// boundary schedules a background distillation of the session's older
    /// turns. Off → the pre-turn threshold is the only lane, exactly as before.
    public var agingEnabled: Bool
    public var agingFraction: Double

    public init(
        enabled: Bool = true,
        thresholdTokens: Int = Self.defaultThresholdTokens,
        keepCount: Int = Self.defaultKeepCount,
        distillEnabled: Bool = true,
        agingEnabled: Bool = true,
        agingFraction: Double = Self.defaultAgingFraction
    ) {
        self.enabled = enabled
        self.thresholdTokens = max(1, thresholdTokens)
        self.keepCount = max(1, keepCount)
        self.distillEnabled = distillEnabled
        self.agingEnabled = agingEnabled
        self.agingFraction = min(0.95, max(0.01, agingFraction))
    }

    /// Reads the app preference at the production boundary.  The defaults
    /// instance is injectable solely so callers can exercise the same reader
    /// against an isolated persistent domain; production still uses `.standard`.
    public static func productionDefault(
        defaults: UserDefaults = .standard
    ) -> ChatSessionAutocompactionConfig {
        let stored = defaults.integer(forKey: defaultsKey)
        // Absent key → distill on by default; explicit false → off.
        let distill = defaults.object(forKey: distillEnabledKey) == nil
            ? true
            : defaults.bool(forKey: distillEnabledKey)
        // Absent key → aging on by default; explicit false → off (the pre-turn
        // threshold then behaves exactly as it did before the aging lane).
        let aging = defaults.object(forKey: agingEnabledKey) == nil
            ? true
            : defaults.bool(forKey: agingEnabledKey)
        return ChatSessionAutocompactionConfig(
            enabled: true,
            thresholdTokens: stored > 0 ? stored : defaultThresholdTokens,
            keepCount: defaultKeepCount,
            distillEnabled: distill,
            agingEnabled: aging
        )
    }

    /// The configured threshold is an upper bound. Smaller-window models
    /// compact sooner so a global 200k preference cannot exceed a 128k model's
    /// usable request window. Forty percent leaves room for persona, Fluid
    /// Context, cognition, tool schemas, the current turn, and model output.
    public func effectiveThresholdTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int {
        guard let contextWindow = ProviderRouting.verifiedContextLength(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        ) else {
            return thresholdTokens
        }
        let modelPressureThreshold = max(
            1,
            Int(Double(contextWindow) * Self.maximumContextWindowFraction)
        )
        return min(thresholdTokens, modelPressureThreshold)
    }

    /// The boundary at which a session's OLDER turns start aging into
    /// recollection, in the background. Always below the pre-turn threshold —
    /// that one is the backstop.
    public func effectiveAgingThresholdTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int {
        let ceiling = effectiveThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        return max(1, min(ceiling, Int(Double(ceiling) * agingFraction)))
    }
}

public struct ChatSessionCompactionOutcome: Sendable, Equatable {
    public let sessionId: String
    public let compacted: Bool
    public let reason: String
    public let trigger: String
    public let thresholdTokens: Int
    public let estimatedTokensBefore: Int
    public let transcriptCharsBefore: Int
    public let messagesBefore: Int
    public let messagesAfter: Int
    public let messagesReplaced: Int
    public let summaryChars: Int
    public let sourceBytesBefore: Int64
    public let sourceBytesAfter: Int64
    /// Id of the mechanical `compaction_summary` row just written, present ONLY
    /// when a backup exists AND distill is enabled — i.e. when the caller should
    /// spawn the async distiller. `nil` on skips / distill-off / missing backup.
    public let summaryRowId: String?
    /// Filesystem path of the pre-compaction backup the distiller reads, present
    /// under the same condition as `summaryRowId`.
    public let backupPath: String?

    /// WHICH lane consolidated this session, derived from the trigger so the
    /// receipt never has to be guessed at from a timestamp. `aging` is the
    /// continuous background lane; `backstop` is the pre-turn threshold that
    /// should now be rare; `manual` is an explicit user request.
    /// (NORTHSTAR clause 2 — a receipt records what actually ran.)
    public var lane: String { Self.lane(forTrigger: trigger) }

    public static func lane(forTrigger trigger: String) -> String {
        if trigger.hasPrefix("aging") { return "aging" }
        if trigger.hasPrefix("manual") { return "manual" }
        return "backstop"
    }

    public init(
        sessionId: String,
        compacted: Bool,
        reason: String,
        trigger: String,
        thresholdTokens: Int,
        estimatedTokensBefore: Int,
        transcriptCharsBefore: Int,
        messagesBefore: Int,
        messagesAfter: Int,
        messagesReplaced: Int,
        summaryChars: Int,
        sourceBytesBefore: Int64,
        sourceBytesAfter: Int64,
        summaryRowId: String? = nil,
        backupPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.compacted = compacted
        self.reason = reason
        self.trigger = trigger
        self.thresholdTokens = thresholdTokens
        self.estimatedTokensBefore = estimatedTokensBefore
        self.transcriptCharsBefore = transcriptCharsBefore
        self.messagesBefore = messagesBefore
        self.messagesAfter = messagesAfter
        self.messagesReplaced = messagesReplaced
        self.summaryChars = summaryChars
        self.sourceBytesBefore = sourceBytesBefore
        self.sourceBytesAfter = sourceBytesAfter
        self.summaryRowId = summaryRowId
        self.backupPath = backupPath
    }
}

struct ChatSessionAutocompactor: Sendable {
    static let maximumCompactBackups = 5
    typealias BackupFileCopy = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    let dataRoot: URL
    let config: ChatSessionAutocompactionConfig
    let persistence: SwiftNativePersistenceCore
    let now: @Sendable () -> Date
    let backupFileCopy: BackupFileCopy

    init(
        dataRoot: URL,
        config: ChatSessionAutocompactionConfig = .productionDefault(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() },
        backupFileCopy: @escaping BackupFileCopy = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) {
        self.dataRoot = dataRoot
        self.config = config
        self.persistence = persistence
        self.now = now
        self.backupFileCopy = backupFileCopy
    }

    func compactIfNeeded(
        sessionId rawSessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String? = nil,
        trigger: String = "auto_threshold",
        force: Bool = false,
        // The continuous aging lane runs the SAME body at a lower boundary.
        // Nothing about the contract changes: validator, verified backup,
        // keep-tail, durable write and receipts are one implementation.
        thresholdTokensOverride: Int? = nil,
        // Aging folds everything older than the keep-tail and stops there. The
        // backstop additionally shrinks the tail until the result fits under
        // the threshold — correct when the alternative is a context-length
        // failure, wrong for a routine background pass, which would otherwise
        // strip a busy session down to a summary plus one message.
        keepTailFixed: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        // Manual compaction is an explicit user action. It bypasses the
        // automatic enable/threshold gates, but never the transcript validator,
        // verified backup, keep-tail, or durable-write contracts below.
        guard config.enabled || force else {
            return skipped(
                sessionId: rawSessionId,
                reason: "autocompaction disabled",
                trigger: trigger
            )
        }
        guard let sessionId = NativeAgentChatSessionID.normalizedPathComponent(rawSessionId) else {
            return skipped(
                sessionId: rawSessionId,
                reason: "invalid session id",
                trigger: trigger
            )
        }

        let messagesPath = messagesPath(sessionId: sessionId)
        let sourceBytesBefore = Self.fileSize(messagesPath)
        guard sourceBytesBefore > 0 else {
            return skipped(
                sessionId: sessionId,
                reason: "missing or empty transcript",
                trigger: trigger
            )
        }

        let modelThresholdTokens = config.effectiveThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        let effectiveThresholdTokens = thresholdTokensOverride
            .map { max(1, min($0, modelThresholdTokens)) } ?? modelThresholdTokens
        let divisor = Self.tokenDivisor(forModel: model)
        if !force,
           Double(sourceBytesBefore) < Double(effectiveThresholdTokens) * divisor {
            return skipped(
                sessionId: sessionId,
                reason: "below threshold by file size",
                trigger: trigger,
                thresholdTokens: effectiveThresholdTokens,
                sourceBytesBefore: sourceBytesBefore
            )
        }

        return try await persistence.withFileLock(messagesPath) {
            let rows = try await readJSONLHonest(messagesPath, context: "autocompact")
            let before = rows.count
            let transcriptChars = Self.transcriptCharacterCount(rows)
            let estimatedTokens = max(0, Int((Double(transcriptChars) / divisor).rounded()))
            guard force || estimatedTokens >= effectiveThresholdTokens else {
                return skipped(
                    sessionId: sessionId,
                    reason: "below threshold",
                    trigger: trigger,
                    thresholdTokens: effectiveThresholdTokens,
                    estimatedTokensBefore: estimatedTokens,
                    transcriptCharsBefore: transcriptChars,
                    messagesBefore: before,
                    messagesAfter: before,
                    sourceBytesBefore: sourceBytesBefore
                )
            }

            let candidateReplaceCount = keepTailFixed
                ? Self.fixedKeepTailReplacementCount(rows: rows, keepCount: config.keepCount)
                : Self.replacementCount(
                    rows: rows,
                    keepCount: config.keepCount,
                    thresholdTokens: effectiveThresholdTokens,
                    divisor: divisor
                )
            // A recollection must never STRADDLE the dream lane's high-water
            // mark. The reader admits a row whose coverage ENDS after the mark,
            // whole — so a row covering T1..T10 written after the dream already
            // consumed T1..T6 raw gets T1..T6 dreamed a second time. Once the
            // row exists the split is impossible (the raw turns are gone), so
            // the fix belongs here: fold only what the dream has already passed
            // and leave the post-mark turns raw for the next pass.
            let replaceCount = Self.markSafeReplacementCount(
                rows: rows,
                replaceCount: candidateReplaceCount,
                mark: ChatSessionRecollections.dreamConsolidationMark(dataRoot: dataRoot)
            )
            // Clamped to a prefix with no raw turn left in it → this pass would
            // only rewrite an existing recollection into an identical-coverage
            // one. Skip honestly instead of churning the transcript.
            if replaceCount < candidateReplaceCount,
               !Self.containsRawTurn(Array(rows.prefix(replaceCount))) {
                return skipped(
                    sessionId: sessionId,
                    reason: "clamped by dream consolidation mark",
                    trigger: trigger,
                    thresholdTokens: effectiveThresholdTokens,
                    estimatedTokensBefore: estimatedTokens,
                    transcriptCharsBefore: transcriptChars,
                    messagesBefore: before,
                    messagesAfter: before,
                    sourceBytesBefore: sourceBytesBefore
                )
            }
            guard replaceCount > 0 else {
                return skipped(
                    sessionId: sessionId,
                    reason: "not enough messages to compact",
                    trigger: trigger,
                    thresholdTokens: effectiveThresholdTokens,
                    estimatedTokensBefore: estimatedTokens,
                    transcriptCharsBefore: transcriptChars,
                    messagesBefore: before,
                    messagesAfter: before,
                    sourceBytesBefore: sourceBytesBefore
                )
            }

            let replaced = Array(rows.prefix(replaceCount))
            let kept = Array(rows.suffix(before - replaceCount))
            let summary = Self.compactionSummary(for: replaced)
            let nowISO = ISO8601DateFormatter().string(from: now())
            let summaryId = "compact-\(UUID().uuidString.lowercased())"
            // A verified backup is mandatory before destructive compaction. It
            // also gives the optional distiller the exact replaced source.
            let backupURL = try backupCurrentMessages(sessionId: sessionId, messagesPath: messagesPath)
            let willDistill = config.distillEnabled
            // WHICH stretch of life this recollection stands for. Recorded so a
            // second consolidation owner (the dream lane) can tell whether it
            // has already consumed this material, without re-reading the backup
            // or re-summarizing the same turns. See ChatSessionRecollections.
            let coverage = Self.coverageRange(replaced)
            var summaryMetadata: [String: JSONValue] = [
                "kind": .string(ChatSessionRecollections.rowKind),
                "messages_replaced": .int(Int64(replaceCount)),
                "trigger": .string(trigger),
                "lane": .string(ChatSessionCompactionOutcome.lane(forTrigger: trigger)),
            ]
            if let from = coverage.from {
                summaryMetadata[ChatSessionRecollections.coversFromKey] = .string(from)
            }
            if let until = coverage.until {
                summaryMetadata[ChatSessionRecollections.coversUntilKey] = .string(until)
            }
            let incorporated = Self.incorporatedRange(replaced)
            if let from = incorporated.from {
                summaryMetadata[ChatSessionRecollections.incorporatedFromKey] = .string(from)
            }
            if let until = incorporated.until {
                summaryMetadata[ChatSessionRecollections.incorporatedUntilKey] = .string(until)
            }
            if willDistill {
                summaryMetadata["distill"] = .string("pending")
            }
            let summaryRow: JSONValue = .object([
                "id": .string(summaryId),
                "sessionId": .string(sessionId),
                "role": .string("system"),
                "content": .string(summary),
                "createdAt": .string(nowISO),
                "source": .string("native_autocompaction"),
                "metadata": .object(summaryMetadata),
            ])
            let nextRows = [summaryRow] + kept
            try writeRows(nextRows, to: messagesPath)
            let sourceBytesAfter = Self.fileSize(messagesPath)
            let outcome = ChatSessionCompactionOutcome(
                sessionId: sessionId,
                compacted: true,
                reason: "swift-native-autocompaction",
                trigger: trigger,
                thresholdTokens: effectiveThresholdTokens,
                estimatedTokensBefore: estimatedTokens,
                transcriptCharsBefore: transcriptChars,
                messagesBefore: before,
                messagesAfter: nextRows.count,
                messagesReplaced: replaceCount,
                summaryChars: summary.count,
                sourceBytesBefore: sourceBytesBefore,
                sourceBytesAfter: sourceBytesAfter,
                summaryRowId: willDistill ? summaryId : nil,
                backupPath: willDistill ? backupURL.path : nil
            )
            await emitCompactionTrace(
                outcome,
                model: model,
                surface: surface,
                runId: runId,
                status: "ok"
            )
            emitTurnTrace(outcome, model: model, surface: surface, runId: runId)
            return outcome
        }
    }

    private func skipped(
        sessionId: String,
        reason: String,
        trigger: String,
        thresholdTokens: Int? = nil,
        estimatedTokensBefore: Int = 0,
        transcriptCharsBefore: Int = 0,
        messagesBefore: Int = 0,
        messagesAfter: Int = 0,
        sourceBytesBefore: Int64 = 0
    ) -> ChatSessionCompactionOutcome {
        ChatSessionCompactionOutcome(
            sessionId: sessionId,
            compacted: false,
            reason: reason,
            trigger: trigger,
            thresholdTokens: thresholdTokens ?? config.thresholdTokens,
            estimatedTokensBefore: estimatedTokensBefore,
            transcriptCharsBefore: transcriptCharsBefore,
            messagesBefore: messagesBefore,
            messagesAfter: messagesAfter,
            messagesReplaced: 0,
            summaryChars: 0,
            sourceBytesBefore: sourceBytesBefore,
            sourceBytesAfter: sourceBytesBefore
        )
    }

    private func messagesPath(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func sessionDir(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    private func readJSONLHonest(_ path: URL, context: String) async throws -> [JSONValue] {
        let data = try Data(contentsOf: path)
        var rows: [JSONValue] = []

        for (index, rawLine) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard rawLine.contains(where: { byte in
                byte != 0x20 && byte != 0x09 && byte != 0x0D
            }) else { continue }

            do {
                let row = try JSONValue.parse(Data(rawLine))
                guard case .object = row else {
                    throw NSError(
                        domain: "NativeAgent.ChatSessionAutocompactor",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "expected a JSON object"]
                    )
                }
                rows.append(row)
            } catch {
                throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(context): \(path.lastPathComponent) line \(index + 1) is not a valid JSON object; "
                        + "refusing to compact corrupt transcript",
                    NSUnderlyingErrorKey: error,
                ])
            }
        }
        return rows
    }

    /// Copies the live transcript aside and verifies it byte-for-byte before
    /// permitting the destructive rewrite.
    @discardableResult
    private func backupCurrentMessages(sessionId: String, messagesPath: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: messagesPath.path) else {
            throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "pre-compaction transcript disappeared; refusing to compact"
            ])
        }
        let dir = sessionDir(sessionId: sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Unique suffix: two compactions in the same second must not collide —
        // a copy failing onto an existing name would otherwise report the STALE
        // backup as fresh and the distiller would distill the wrong prefix.
        // Success = THIS copy succeeded, never "a file with that name exists".
        let suffix = "\(Self.fileSafeTimestamp(now())).\(UUID().uuidString.lowercased().prefix(8))"
        let backup = dir.appendingPathComponent("messages.compact.\(suffix).jsonl")
        do {
            try backupFileCopy(messagesPath, backup)
            let sourceData = try Data(contentsOf: messagesPath)
            let backupData = try Data(contentsOf: backup)
            guard backupData == sourceData else {
                throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "pre-compaction backup verification failed"
                ])
            }
            Self.pruneCompactBackups(
                in: dir,
                keeping: Self.maximumCompactBackups,
                preserving: backup
            )
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "could not create a verified pre-compaction backup; refusing to compact",
                NSUnderlyingErrorKey: error,
            ])
        }
        return backup
    }

    /// Keep a bounded recovery window without letting every compaction leave a
    /// permanent full-transcript copy. Cleanup is best-effort: preserving an
    /// extra old backup is safer than invalidating the verified fresh one.
    @discardableResult
    static func pruneCompactBackups(
        in directory: URL,
        keeping: Int,
        preserving protected: URL? = nil
    ) -> [URL] {
        guard keeping >= 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }
        let backups = entries
            .filter {
                $0.lastPathComponent.hasPrefix("messages.compact.")
                    && $0.pathExtension == "jsonl"
            }
            .sorted { lhs, rhs in
                if lhs == protected { return true }
                if rhs == protected { return false }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
        var removed: [URL] = []
        for stale in backups.dropFirst(keeping) {
            do {
                try FileManager.default.removeItem(at: stale)
                removed.append(stale)
            } catch {
                // Best effort: a retained recovery copy is safer than making
                // transcript compaction fail after its fresh backup verified.
            }
        }
        return removed
    }

    private func writeRows(_ rows: [JSONValue], to path: URL) throws {
        var payload = Data()
        for row in rows {
            payload.append(Data((try row.serialize(pretty: false)).utf8))
            payload.append(0x0A)
        }
        // Transcript REPLACEMENT is the one write that destroys its own source.
        // `Data.write(.atomic)` renames without fsync, so a power loss between
        // rename and writeback can leave the transcript truncated with the raw
        // turns already gone. The durable writer fsyncs the temp file AND the
        // parent directory before returning, and chmods 0600 exactly as before.
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload, to: path)
    }

    private func emitCompactionTrace(
        _ outcome: ChatSessionCompactionOutcome,
        model: String,
        surface: String,
        runId: String?,
        status: String
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        var payload: [String: JSONValue] = [
            "schema": .string("context.compact.v1"),
            "sessionId": .string(outcome.sessionId),
            "surface": .string(surface),
            "trigger": .string(outcome.trigger),
            "lane": .string(outcome.lane),
            "reason": .string(outcome.reason),
            "model": .string(model),
            "thresholdTokens": .int(Int64(outcome.thresholdTokens)),
            "estimatedTokensBefore": .int(Int64(outcome.estimatedTokensBefore)),
            "transcriptCharsBefore": .int(Int64(outcome.transcriptCharsBefore)),
            "messagesBefore": .int(Int64(outcome.messagesBefore)),
            "messagesAfter": .int(Int64(outcome.messagesAfter)),
            "messagesReplaced": .int(Int64(outcome.messagesReplaced)),
            "summaryChars": .int(Int64(outcome.summaryChars)),
            "sourceBytesBefore": .int(outcome.sourceBytesBefore),
            "sourceBytesAfter": .int(outcome.sourceBytesAfter),
        ]
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("context.compact"),
            "title": .string(outcome.sessionId),
            "status": .string(status),
            "payload": .object(payload),
            "createdAt": .string(ISO8601DateFormatter().string(from: now())),
        ])
        do {
            try await appendPathOwnedJSONL(
                row,
                to: tracesPath,
                using: persistence,
                logLabel: "ChatSessionAutocompactor"
            )
        } catch {
            FileHandle.standardError.write(
                Data("ChatSessionAutocompactor: trace append failed for \(outcome.sessionId): \(error)\n".utf8)
            )
        }
    }

    private func emitTurnTrace(
        _ outcome: ChatSessionCompactionOutcome,
        model: String,
        surface: String,
        runId: String?
    ) {
        var payload: [String: JSONValue] = [
            "sessionId": .string(outcome.sessionId),
            "trigger": .string(outcome.trigger),
            "lane": .string(outcome.lane),
            "model": .string(model),
            "thresholdTokens": .int(Int64(outcome.thresholdTokens)),
            "estimatedTokensBefore": .int(Int64(outcome.estimatedTokensBefore)),
            "messagesBefore": .int(Int64(outcome.messagesBefore)),
            "messagesAfter": .int(Int64(outcome.messagesAfter)),
            "messagesReplaced": .int(Int64(outcome.messagesReplaced)),
            "sourceBytesBefore": .int(outcome.sourceBytesBefore),
            "sourceBytesAfter": .int(outcome.sourceBytesAfter),
        ]
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        TurnTraceBus.fireFromContext(
            kind: "context.compact",
            surface: surface,
            payload: .object(payload)
        )
    }

    private static func replacementCount(
        rows: [JSONValue],
        keepCount: Int,
        thresholdTokens: Int,
        divisor: Double
    ) -> Int {
        let messageCount = rows.count
        guard messageCount > 1 else { return 0 }
        let preferredTailCount = preferredTailCount(
            messageCount: messageCount,
            keepCount: keepCount
        )
        guard preferredTailCount < messageCount else { return 0 }

        var tailCount = preferredTailCount
        while tailCount > 1 {
            let replaceCount = messageCount - tailCount
            let summary = compactionSummary(for: Array(rows.prefix(replaceCount)))
            let tail = Array(rows.suffix(tailCount))
            let postCompactionChars = summary.count + transcriptCharacterCount(tail)
            let postCompactionTokens = max(0, Int((Double(postCompactionChars) / divisor).rounded()))
            if postCompactionTokens < thresholdTokens {
                return replaceCount
            }
            tailCount -= 1
        }

        // If even the preferred tail would stay over threshold, compact as much
        // as possible while preserving the newest raw message for continuity.
        return messageCount - 1
    }

    /// The aging lane's replacement count: everything older than the keep-tail,
    /// and nothing more. No shrink loop — a background pass must never eat into
    /// the recent stretch of a session just because that stretch is large.
    static func fixedKeepTailReplacementCount(rows: [JSONValue], keepCount: Int) -> Int {
        let messageCount = rows.count
        guard messageCount > 1 else { return 0 }
        let tail = preferredTailCount(messageCount: messageCount, keepCount: keepCount)
        var count = max(0, messageCount - tail)
        // User, 2026-09-06: aging must not eat a recollection the distiller is
        // still writing. The backstop lane compacts, schedules aging, and hands
        // the distiller a row id; with one summary plus the retained tail this
        // count came back as 1 and selected that very summary, so aging
        // replaced S1 with S2 and the in-flight distillation landed on
        // `row_missing` — its whole pass thrown away. Stop the prefix before
        // the first row still marked `distill: pending`.
        if let pending = rows.prefix(count).firstIndex(where: hasPendingDistillation) {
            count = pending
        }
        // And never rewrite a prefix that holds nothing but recollections:
        // that pass buys identical coverage in new bytes. The threshold lane
        // already refuses this when the dream mark clamps it; the background
        // lane, which has no obligation to get under anything, refuses it
        // always.
        guard count > 0, containsRawTurn(Array(rows.prefix(count))) else { return 0 }
        return count
    }

    /// True when the row is a recollection whose LLM distillation was started
    /// and has not been swapped in yet (`metadata.distill == "pending"`, set by
    /// the pass that wrote the row and rewritten to `llm` on success).
    static func hasPendingDistillation(_ row: JSONValue) -> Bool {
        guard case .object(let obj) = row,
              case .object(let metadata)? = obj["metadata"],
              case .string("pending")? = metadata["distill"]
        else { return false }
        return true
    }

    /// The ISO timestamps bounding the material a recollection stands for.
    /// A replaced row that is ITSELF a recollection contributes its own
    /// coverage, so a session consolidated repeatedly keeps an honest span
    /// rather than collapsing to the last compaction's clock.
    static func coverageRange(_ rows: [JSONValue]) -> (from: String?, until: String?) {
        func createdAt(_ row: JSONValue) -> String? {
            guard case .object(let obj) = row,
                  case .string(let value)? = obj["createdAt"] else { return nil }
            return value
        }
        func metadataString(_ row: JSONValue, _ key: String) -> String? {
            guard case .object(let obj) = row,
                  case .object(let metadata)? = obj["metadata"],
                  case .string(let value)? = metadata[key] else { return nil }
            return value
        }
        func isRecollection(_ row: JSONValue) -> Bool {
            metadataString(row, "kind") == ChatSessionRecollections.rowKind
        }
        var until: String?
        for row in rows.reversed() {
            if let value = metadataString(row, ChatSessionRecollections.coversUntilKey)
                ?? createdAt(row) {
                until = value
                break
            }
        }
        // `from` must describe the WHOLE text this row will carry. A prior
        // recollection at the head of the prefix is pinned into the summary in
        // full (see `compactionSummary`), so the span starts where THAT row's
        // coverage started — anything else understates the material and lets
        // the dream lane re-admit turns it already consumed (Astra audit
        // 2026-09-11, finding 2). What this pass newly folded in is recorded
        // separately by `incorporatedRange`.
        var from: String?
        for row in rows {
            if isRecollection(row),
               let value = metadataString(row, ChatSessionRecollections.coversFromKey) {
                from = value
                break
            }
            if let value = createdAt(row) {
                from = value
                break
            }
        }
        if from == nil {
            for row in rows.reversed() {
                if let value = metadataString(row, ChatSessionRecollections.coversUntilKey)
                    ?? createdAt(row) {
                    from = value
                    break
                }
            }
        }
        // A prefix can end on a recollection whose covers_until predates the
        // raw turn that opened the span; never hand out an inverted window.
        if let fromValue = from, let untilValue = until,
           let fromDate = ChatSessionRecollections.parseTimestamp(.string(fromValue)),
           let untilDate = ChatSessionRecollections.parseTimestamp(.string(untilValue)),
           fromDate > untilDate {
            from = untilValue
        }
        return (from, until)
    }

    /// The interval this pass NEWLY folded in: the first raw turn being
    /// replaced through the end of the span. Informational — the dream lane's
    /// admission decision uses `coverageRange`, which covers the whole text.
    static func incorporatedRange(_ rows: [JSONValue]) -> (from: String?, until: String?) {
        func createdAt(_ row: JSONValue) -> String? {
            guard case .object(let obj) = row,
                  case .string(let value)? = obj["createdAt"] else { return nil }
            return value
        }
        func isRecollection(_ row: JSONValue) -> Bool {
            guard case .object(let obj) = row,
                  case .object(let metadata)? = obj["metadata"],
                  case .string(let kind)? = metadata["kind"] else { return false }
            return kind == ChatSessionRecollections.rowKind
        }
        let until = coverageRange(rows).until
        var from: String?
        for row in rows where !isRecollection(row) {
            if let value = createdAt(row) {
                from = value
                break
            }
        }
        // Nothing raw in the prefix: this pass incorporated no new material.
        guard let fromValue = from else { return (nil, until) }
        if let untilValue = until,
           let fromDate = ChatSessionRecollections.parseTimestamp(.string(fromValue)),
           let untilDate = ChatSessionRecollections.parseTimestamp(.string(untilValue)),
           fromDate > untilDate {
            return (untilValue, untilValue)
        }
        return (fromValue, until)
    }

    /// Shrink `replaceCount` so the recollection it produces never straddles
    /// the dream lane's high-water mark. A span wholly at-or-before the mark is
    /// already safe (the dream skips it); a span wholly after it is safe too
    /// (the dream reads all of it, once). Only a straddling span is a double
    /// count — clamp it to the leading rows whose material ENDS at or before
    /// the mark and leave the rest raw. No mark → nothing to respect.
    static func markSafeReplacementCount(
        rows: [JSONValue],
        replaceCount: Int,
        mark: Date?
    ) -> Int {
        guard replaceCount > 0, let mark else { return replaceCount }
        let replaced = Array(rows.prefix(replaceCount))
        let span = coverageRange(replaced)
        guard let until = ChatSessionRecollections.parseTimestamp(span.until.map { .string($0) }),
              until > mark
        else { return replaceCount }
        guard let from = ChatSessionRecollections.parseTimestamp(span.from.map { .string($0) }),
              from <= mark
        else { return replaceCount }
        var safe = 0
        for row in replaced {
            guard let rowUntil = ChatSessionRecollections.parseTimestamp(
                      coverageRange([row]).until.map { .string($0) }
                  ),
                  rowUntil <= mark
            else { break }
            safe += 1
        }
        return safe
    }

    /// True when at least one row is an ordinary turn rather than a recollection
    /// the earlier passes already folded.
    static func containsRawTurn(_ rows: [JSONValue]) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row,
                  case .object(let metadata)? = obj["metadata"],
                  case .string(let kind)? = metadata["kind"]
            else { return true }
            return kind != ChatSessionRecollections.rowKind
        }
    }

    private static func preferredTailCount(messageCount: Int, keepCount: Int) -> Int {
        if messageCount > keepCount {
            return keepCount
        }
        return min(4, messageCount - 1)
    }

    private static func transcriptCharacterCount(_ rows: [JSONValue]) -> Int {
        var total = 0
        for row in rows {
            guard case .object(let obj) = row else { continue }
            total += ChatCompactionRowRendering.characterCount(obj)
        }
        return total
    }

    private static func tokenDivisor(forModel model: String) -> Double {
        model.lowercased().contains("claude") ? 3.5 : 4.0
    }

    private static func fileSize(_ path: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func compactionSummary(for rows: [JSONValue]) -> String {
        let header = "[NativeAgent compacted \(rows.count) earlier message(s).]"
        var lines: [String] = [header]
        // 2026-09-05: a PRIOR recollection at the head of the replaced range is
        // the only carrier of everything that happened before it; the 500-char
        // per-row cap truncated it to its first paragraph, so when the distill
        // failed the fallback silently amputated the session's earlier arc.
        // The leading recollection row(s) keep their full body (their own
        // maxSummaryChars); the raw turns after them are capped exactly as
        // before.
        var pinnedLines: [String] = []
        var restLines: [String] = []
        var pinning = true
        for row in rows {
            guard case .object(let obj) = row else { continue }
            let role: String = {
                if case .string(let s)? = obj["role"] { return s }
                return "message"
            }()
            guard let body = ChatCompactionRowRendering.summaryBody(
                obj,
                collapseNewlines: true
            ) else { continue }
            if pinning, ChatCompactionRowRendering.isRecollection(obj) {
                pinnedLines.append("\(role): \(body)")
                continue
            }
            pinning = false
            restLines.append("\(role): \(String(body.prefix(500)))")
        }
        // User, 2026-09-06: one bounded rolling window, the shape
        // `IntraTurnContextCompaction`'s mechanical fold already uses. This
        // used to keep up to 12 000 characters of the prior recollection PLUS
        // another 12 000 of the newly replaced rows — about 24 000 — and the
        // next pass read that row back with `prefix(12 000)`, so every repeat
        // mechanical compaction threw away exactly the material it had just
        // summarised. The caps now COMPOSE inside one budget, and the prior
        // note contributes its TAIL: the oldest material is what ages out, not
        // the newest. Recency retention by design, as in the in-turn lane.
        // User, 2026-09-06: the cap is on the WHOLE stored value. The header
        // and its newline used to sit OUTSIDE it, so the row written here was
        // reliably longer than the `prefix(maxSummaryChars)` the next pass
        // reads it back with — the overflow was silently dropped on re-read.
        let cap = max(0, ChatCompactionDistiller.maxSummaryChars - header.count - 1)
        let prior = pinnedLines.joined(separator: "\n")
        let rest = restLines.joined(separator: "\n")
        // The prior note may claim at most two thirds; whatever it does not use
        // goes to the new rows, so a short recollection never strands budget.
        var body = prior.isEmpty ? "" : String(prior.suffix(cap * 2 / 3))
        if !rest.isEmpty {
            let separator = body.isEmpty ? "" : "\n"
            let room = max(0, cap - body.count - separator.count)
            if room > 0 { body += separator + String(rest.suffix(room)) }
        }
        if !body.isEmpty { lines.append(String(body.prefix(cap))) }
        return lines.joined(separator: "\n")
    }
}

/// The one place that knows how to READ a tool row during compaction.
///
/// Tool rows persist with `content: ""` and their whole payload under
/// `metadata` (see `ChatOrchestrationClient+MessagePersistence.swift`). Both
/// compaction paths used to look only at `content`, which produced a matched
/// pair of defects: a tool-heavy transcript measured as ~zero characters and so
/// never reached the token threshold (the session died on a provider
/// context-length error instead of compacting), and — once it did compact —
/// every record of which tools ran was dropped from the summary and from the
/// distiller prompt.
enum ChatCompactionRowRendering {
    /// Characters this row contributes to the transcript size estimate. When
    /// `content` is empty the payload lives in `metadata`, so the serialized
    /// metadata length stands in for it.
    static func characterCount(_ obj: [String: JSONValue]) -> Int {
        if let content = obj["content"] {
            if case .string(let text) = content {
                if !text.isEmpty { return text.count }
            } else {
                return ((try? content.serialize(pretty: false)) ?? "").count
            }
        }
        guard let metadata = obj["metadata"] else { return 0 }
        return ((try? metadata.serialize(pretty: false)) ?? "").count
    }

    /// The transcript line body for a row, or nil when the row carries nothing
    /// worth preserving. Falls back to a compact `toolName + resultSummary`
    /// when `content` is empty so post-compaction continuity keeps a record of
    /// the tool activity.
    static func summaryBody(_ obj: [String: JSONValue], collapseNewlines: Bool) -> String? {
        let content: String = {
            if case .string(let text)? = obj["content"] { return text }
            if let value = obj["content"] { return (try? value.serialize(pretty: false)) ?? "" }
            return ""
        }()
        let normalized = normalize(content, collapseNewlines: collapseNewlines)
        let metadata: [String: JSONValue]?
        if case .object(let value)? = obj["metadata"] { metadata = value } else { metadata = nil }
        let body = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            normalized.isEmpty ? toolFallbackLine(obj) ?? "" : normalized,
            attachments: metadata?["attachments"])
        guard !body.isEmpty else { return nil }
        let role: String
        if case .string(let value)? = obj["role"] {
            role = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else { role = "" }
        let isCompactionSummary: Bool
        if case .string("compaction_summary")? = metadata?["kind"] { isCompactionSummary = true }
        else { isCompactionSummary = false }
        return ChatTranscriptEvidenceRendering.displayContent(
            body,
            originLabel: role == "user" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(metadata?["origin"]) : nil,
            incompleteReplyLabel: role == "assistant" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: obj, metadata: metadata) : nil)
    }

    /// True when this row is a consolidated recollection a PRIOR compaction
    /// wrote, rather than an ordinary turn. The one place that knows the shape
    /// for both compaction paths (see `ChatSessionRecollections.rowKind`).
    static func isRecollection(_ obj: [String: JSONValue]) -> Bool {
        guard case .object(let metadata)? = obj["metadata"],
              case .string(let kind)? = metadata["kind"]
        else { return false }
        return kind == ChatSessionRecollections.rowKind
    }

    /// `toolName (ok): result summary` — nil when the row has no tool metadata.
    static func toolFallbackLine(_ obj: [String: JSONValue]) -> String? {
        guard case .object(let metadata)? = obj["metadata"] else { return nil }
        guard case .string(let toolName)? = metadata["toolName"],
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recordedStatus = ChatTranscriptEvidenceRendering.recordedToolStatus(metadata)
        var line = recordedStatus.map { "\($0): \(toolName)" } ?? toolName
        if recordedStatus == nil, case .bool(let ok)? = metadata["ok"] {
            line += ok ? " (ok)" : " (failed)"
        }
        if case .string(let summary)? = metadata["resultSummary"] {
            let normalized = normalize(summary, collapseNewlines: true)
            if !normalized.isEmpty {
                line += ": \(String(normalized.prefix(toolResultSummaryMaximumCharacters)))"
            }
        }
        return line
    }

    /// A tool receipt is context, not content — keep it short enough that a
    /// long run of tool calls cannot crowd the conversation out of the summary.
    static let toolResultSummaryMaximumCharacters = 200

    private static func normalize(_ text: String, collapseNewlines: Bool) -> String {
        let flattened = collapseNewlines
            ? text.replacingOccurrences(of: "\n", with: " ")
            : text
        return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

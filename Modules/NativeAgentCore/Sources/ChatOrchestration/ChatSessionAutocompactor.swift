import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

public struct ChatSessionAutocompactionConfig: Sendable, Equatable {
    public static let defaultsKey = "nativeagent.compactionThresholdTokens"
    public static let distillEnabledKey = "nativeagent.compactionDistillEnabled"
    public static let defaultThresholdTokens = 200_000
    public static let defaultKeepCount = 20
    public static let maximumContextWindowFraction = 0.40

    public var enabled: Bool
    public var thresholdTokens: Int
    public var keepCount: Int
    /// When true (and a pre-compaction backup exists), the autocompactor's
    /// caller spawns a fire-and-forget LLM pass that swaps the mechanical
    /// compaction summary for a richer, recollection-voice distillation. Any
    /// distill failure leaves the mechanical summary untouched (fail-safe).
    public var distillEnabled: Bool

    public init(
        enabled: Bool = true,
        thresholdTokens: Int = Self.defaultThresholdTokens,
        keepCount: Int = Self.defaultKeepCount,
        distillEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.thresholdTokens = max(1, thresholdTokens)
        self.keepCount = max(1, keepCount)
        self.distillEnabled = distillEnabled
    }

    public static func productionDefault() -> ChatSessionAutocompactionConfig {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        // Absent key → distill on by default; explicit false → off.
        let distill = UserDefaults.standard.object(forKey: distillEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: distillEnabledKey)
        return ChatSessionAutocompactionConfig(
            enabled: true,
            thresholdTokens: stored > 0 ? stored : defaultThresholdTokens,
            keepCount: defaultKeepCount,
            distillEnabled: distill
        )
    }

    /// The configured threshold is an upper bound. Smaller-window models
    /// compact sooner so a global 200k preference cannot exceed a 128k model's
    /// usable request window. Forty percent leaves room for persona, Fluid
    /// Context, cognition, tool schemas, the current turn, and model output.
    public func effectiveThresholdTokens(forModel model: String) -> Int {
        let contextWindow = ProviderRouting.contextLength(forModel: model)
        let modelPressureThreshold = max(
            1,
            Int(Double(contextWindow) * Self.maximumContextWindowFraction)
        )
        return min(thresholdTokens, modelPressureThreshold)
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
        trigger: String = "auto_threshold"
    ) async throws -> ChatSessionCompactionOutcome {
        guard config.enabled else {
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

        let effectiveThresholdTokens = config.effectiveThresholdTokens(forModel: model)
        let divisor = Self.tokenDivisor(forModel: model)
        if Double(sourceBytesBefore) < Double(effectiveThresholdTokens) * divisor {
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
            guard estimatedTokens >= effectiveThresholdTokens else {
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

            let replaceCount = Self.replacementCount(
                rows: rows,
                keepCount: config.keepCount,
                thresholdTokens: effectiveThresholdTokens,
                divisor: divisor
            )
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
            var summaryMetadata: [String: JSONValue] = [
                "kind": .string("compaction_summary"),
                "messages_replaced": .int(Int64(replaceCount)),
                "trigger": .string(trigger),
            ]
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
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "could not create a verified pre-compaction backup; refusing to compact",
                NSUnderlyingErrorKey: error,
            ])
        }
        return backup
    }

    private func writeRows(_ rows: [JSONValue], to path: URL) throws {
        var payload = Data()
        for row in rows {
            payload.append(Data((try row.serialize(pretty: false)).utf8))
            payload.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: path, options: .atomic)
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
            try await appendJSONLCapped(
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
        var lines: [String] = []
        lines.append("[NativeAgent compacted \(rows.count) earlier message(s).]")
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
            lines.append("\(role): \(String(body.prefix(500)))")
            if lines.joined(separator: "\n").count > 12_000 { break }
        }
        return String(lines.joined(separator: "\n").prefix(12_000))
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
        if !normalized.isEmpty { return normalized }
        return toolFallbackLine(obj)
    }

    /// `toolName (ok): result summary` — nil when the row has no tool metadata.
    static func toolFallbackLine(_ obj: [String: JSONValue]) -> String? {
        guard case .object(let metadata)? = obj["metadata"] else { return nil }
        guard case .string(let toolName)? = metadata["toolName"],
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var line = toolName
        if case .bool(let ok)? = metadata["ok"] {
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

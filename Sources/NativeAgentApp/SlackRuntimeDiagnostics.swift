import Foundation
import PersistenceCore

/// Result of patching the loop's diagnostic state. State is observational, but
/// an existing unreadable file is still evidence: it must not be overwritten
/// and then misrepresented as a fresh healthy state.
enum SlackRuntimeStateWriteOutcome: Sendable, Equatable {
    case stored
    case unavailableMalformedExistingState
    case unavailableWriteFailure
}

enum SlackRuntimeStateStore {
    static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func apply(
        _ patch: [String: JSONValue],
        dataRoot: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: Date = Date()
    ) async -> SlackRuntimeStateWriteOutcome {
        let statePath = path(dataRoot: dataRoot)
        do {
            return try await persistence.withFileLock(statePath) {
                var object: [String: JSONValue] = [:]
                if FileManager.default.fileExists(atPath: statePath.path) {
                    let bytes = try Data(contentsOf: statePath)
                    let decoded: JSONValue
                    do {
                        decoded = try JSONValue.parse(bytes)
                    } catch {
                        return .unavailableMalformedExistingState
                    }
                    guard case .object(let existing) = decoded else {
                        return .unavailableMalformedExistingState
                    }
                    object = existing
                }
                for (key, value) in patch {
                    object[key] = value
                }
                // `state.json` is a runtime feed, not merely an accumulation
                // of diagnostic keys. Its update time lets readers distinguish
                // a quiet-but-live socket (kept fresh by ping) from a bridge
                // that stopped reporting altogether.
                object["updatedAt"] = .string(timestamp(now))
                try await persistence.writeJSON(.object(object), to: statePath)
                return .stored
            }
        } catch {
            return .unavailableWriteFailure
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Typed reader for the Socket Mode runtime feed. Missing evidence, malformed
/// state, and a stale heartbeat are intentionally separate from a fresh
/// disconnected state: none of the former can safely be rendered as a healthy
/// Slack bridge.
enum SlackRuntimeStateFeed {
    static let staleAfter: TimeInterval = 90

    struct Snapshot: Equatable, Sendable {
        let connected: Bool
        let updatedAt: String
        let hasReportedError: Bool
    }

    enum Observation: Equatable, Sendable {
        case absent
        case current(Snapshot)
        case stale(Snapshot)
        case unavailable(String)
    }

    static func read(
        dataRoot: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = SlackRuntimeStateFeed.staleAfter
    ) -> Observation {
        let path = SlackRuntimeStateStore.path(dataRoot: dataRoot)
        var stateDirectoryIsDirectory = ObjCBool(false)
        let stateDirectory = path.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: stateDirectory.path,
            isDirectory: &stateDirectoryIsDirectory
        ), !stateDirectoryIsDirectory.boolValue {
            return .unavailable("Slack runtime state root is not a directory")
        }
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        do {
            let bytes = try Data(contentsOf: path)
            guard case .object(let object) = try JSONValue.parse(bytes) else {
                return .unavailable("Slack runtime state is not a JSON object")
            }
            guard case .bool(let connected)? = object["connected"] else {
                return .unavailable("Slack runtime state has no boolean connection flag")
            }
            guard case .string(let updatedAt)? = object["updatedAt"],
                  let date = parseTimestamp(updatedAt) else {
                return .unavailable("Slack runtime state has no valid update timestamp")
            }
            guard date <= now else {
                return .unavailable("Slack runtime state timestamp is in the future")
            }

            let hasReportedError: Bool
            if let errorValue = object["lastError"] {
                switch errorValue {
                case .null:
                    hasReportedError = false
                case .string(let error):
                    hasReportedError = !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default:
                    return .unavailable("Slack runtime state has an invalid error field")
                }
            } else {
                hasReportedError = false
            }

            let snapshot = Snapshot(
                connected: connected,
                updatedAt: updatedAt,
                hasReportedError: hasReportedError
            )
            return now.timeIntervalSince(date) > max(0, staleAfter)
                ? .stale(snapshot)
                : .current(snapshot)
        } catch {
            return .unavailable("Slack runtime state could not be read")
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

/// Bounded receipts/errors ownership for the Socket Mode bridge. These feeds
/// are diagnostic evidence, but they are also the only way to distinguish a
/// healthy outbound reply path from a connector that is repeatedly failing.
enum SlackReceiptErrorFeed {
    struct Retention: Equatable, Sendable {
        let maxLines: Int
        let maxBytes: Int
        let trimToBytes: Int

        init(maxLines: Int, maxBytes: Int, trimToBytes: Int) {
            self.maxLines = max(1, maxLines)
            self.maxBytes = max(1, maxBytes)
            self.trimToBytes = min(max(1, trimToBytes), self.maxBytes)
        }

        static let production = Retention(
            maxLines: JSONLLineCaps.slackReceipts,
            maxBytes: 1_048_576,
            trimToBytes: 786_432
        )
    }

    struct Report: Equatable, Sendable {
        struct ContextRate: Equatable, Sendable {
            let context: String
            let rows: Int
            let ratePerDay: Double
        }

        struct RankedErrorLead: Equatable, Sendable {
            let context: String
            let errorClass: String
            let rows: Int
        }

        let receiptCount: Int
        let errorCount: Int
        let receiptRowsInWindow: Int
        let errorRowsInWindow: Int
        let receiptBytes: Int
        let errorBytes: Int
        let receiptMalformedLineCount: Int
        let errorMalformedLineCount: Int
        let receiptHasTrailingPartialLine: Bool
        let errorHasTrailingPartialLine: Bool
        let newestReceiptAt: String?
        let newestErrorAt: String?
        let errorToReceiptRatio: Double?
        /// A full ring has intentionally evicted older rows; it is not a
        /// claim that the file is still growing.
        let errorsAreAtRetentionCap: Bool
        let contextRates: [ContextRate]
        let rankedErrorLeads: [RankedErrorLead]
        let rankedLeads: [String]
    }

    enum Observation: Equatable, Sendable {
        case absent
        case measured(Report)
        /// Decoded rows are available, but at least one physical row was
        /// malformed or torn. This is evidence, not a healthy zero-loss feed.
        case partial(Report)
        case unavailable(String)
    }

    static let errorToReceiptRatioCeiling = 3.0
    static let minimumErrorsForRatioLead = 3

    static func append(
        _ row: JSONValue,
        to path: URL,
        using persistence: any PersistenceCoreProtocol,
        retention: Retention,
        label: String
    ) async throws {
        try await appendJSONLCapped(
            row,
            to: path,
            using: persistence,
            maxLines: retention.maxLines,
            logLabel: label,
            maxBytes: retention.maxBytes,
            trimToBytes: retention.trimToBytes
        )
    }

    static func read(
        dataRoot: URL,
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60,
        retention: Retention = .production,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> Observation {
        let directory = dataRoot.appendingPathComponent("slack", isDirectory: true)
        let receiptsPath = directory.appendingPathComponent("receipts.jsonl")
        let errorsPath = directory.appendingPathComponent("errors.jsonl")
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .unavailable("Slack feed root is not a directory")
        }
        let receiptsExist = fileManager.fileExists(atPath: receiptsPath.path)
        let errorsExist = fileManager.fileExists(atPath: errorsPath.path)
        guard receiptsExist || errorsExist else { return .absent }
        do {
            let receiptRead = receiptsExist
                ? try await persistence.readJSONLReporting(receiptsPath)
                : (rows: [], report: .clean)
            let errorRead = errorsExist
                ? try await persistence.readJSONLReporting(errorsPath)
                : (rows: [], report: .clean)
            let receiptBytes = byteCount(at: receiptsPath, exists: receiptsExist)
            let errorBytes = byteCount(at: errorsPath, exists: errorsExist)
            guard let receiptBytes, let errorBytes else {
                return .unavailable("Slack feed size could not be read")
            }
            let measured = report(
                receiptRows: receiptRead.rows,
                errorRows: errorRead.rows,
                receiptBytes: receiptBytes,
                errorBytes: errorBytes,
                now: now,
                window: window,
                retention: retention,
                receiptReadReport: receiptRead.report,
                errorReadReport: errorRead.report
            )
            return receiptRead.report.isClean && errorRead.report.isClean
                ? .measured(measured)
                : .partial(measured)
        } catch {
            return .unavailable("Slack feed could not be read: \(error.localizedDescription)")
        }
    }

    static func report(
        receiptRows: [JSONValue],
        errorRows: [JSONValue],
        receiptBytes: Int,
        errorBytes: Int,
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60,
        retention: Retention = .production,
        receiptReadReport: JSONLReadReport = .clean,
        errorReadReport: JSONLReadReport = .clean
    ) -> Report {
        let receipts = receiptRows.count
        let errors = errorRows.count
        let windowStart = now.addingTimeInterval(-max(0, window))
        let newestReceiptAt = newestTimestamp(in: receiptRows)
        let newestErrorAt = newestTimestamp(in: errorRows)
        let ratio = receipts > 0 ? Double(errors) / Double(receipts) : nil
        var leads: [String] = []
        if receiptBytes > retention.maxBytes {
            leads.append("receipts_feed_over_byte_envelope")
        }
        if errorBytes > retention.maxBytes {
            leads.append("errors_feed_over_byte_envelope")
        }
        if errors >= retention.maxLines {
            leads.append("errors_feed_at_retention_cap_ring")
        }
        if !receiptReadReport.isClean {
            leads.append("receipts_feed_incomplete")
        }
        if !errorReadReport.isClean {
            leads.append("errors_feed_incomplete")
        }
        if errors >= minimumErrorsForRatioLead,
           (ratio ?? .infinity) > errorToReceiptRatioCeiling {
            leads.append("errors_to_receipts_ratio_exceeds_envelope")
        }
        if errors > 0,
           receipts == 0 || (newestErrorAt ?? "") > (newestReceiptAt ?? "") {
            leads.append("receipts_frozen_while_errors_grow")
        }
        return Report(
            receiptCount: receipts,
            errorCount: errors,
            receiptRowsInWindow: rowCount(in: receiptRows, since: windowStart),
            errorRowsInWindow: rowCount(in: errorRows, since: windowStart),
            receiptBytes: receiptBytes,
            errorBytes: errorBytes,
            receiptMalformedLineCount: receiptReadReport.malformedLineCount,
            errorMalformedLineCount: errorReadReport.malformedLineCount,
            receiptHasTrailingPartialLine: receiptReadReport.trailingPartialLine,
            errorHasTrailingPartialLine: errorReadReport.trailingPartialLine,
            newestReceiptAt: newestReceiptAt,
            newestErrorAt: newestErrorAt,
            errorToReceiptRatio: ratio,
            errorsAreAtRetentionCap: errors >= retention.maxLines,
            contextRates: contextRates(in: errorRows, since: windowStart, window: window),
            rankedErrorLeads: rankedErrorLeads(in: errorRows, since: windowStart),
            rankedLeads: leads
        )
    }

    private static func byteCount(at path: URL, exists: Bool) -> Int? {
        guard exists else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
    }

    private static func newestTimestamp(in rows: [JSONValue]) -> String? {
        rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let timestamp)? = object["at"] else { return nil }
            return timestamp
        }.max()
    }

    private static func rowCount(in rows: [JSONValue], since windowStart: Date) -> Int {
        let formatter = timestampFormatter()
        return rows.reduce(into: 0) { count, row in
            guard case .object(let object) = row,
                  case .string(let timestamp)? = object["at"],
                  let date = formatter.date(from: timestamp),
                  date >= windowStart else { return }
            count += 1
        }
    }

    private static func contextRates(
        in rows: [JSONValue],
        since windowStart: Date,
        window: TimeInterval
    ) -> [Report.ContextRate] {
        let formatter = timestampFormatter()
        var counts: [String: Int] = [:]
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let timestamp)? = object["at"],
                  let date = formatter.date(from: timestamp),
                  date >= windowStart else { continue }
            counts[normalizedString(object["context"], fallback: "unknown_context"), default: 0] += 1
        }
        let days = max(window / (24 * 60 * 60), 1.0 / 24.0)
        return counts.map { context, rows in
            Report.ContextRate(context: context, rows: rows, ratePerDay: Double(rows) / days)
        }.sorted { $0.rows == $1.rows ? $0.context < $1.context : $0.rows > $1.rows }
    }

    private static func rankedErrorLeads(
        in rows: [JSONValue],
        since windowStart: Date
    ) -> [Report.RankedErrorLead] {
        let formatter = timestampFormatter()
        var counts: [String: Int] = [:]
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let timestamp)? = object["at"],
                  let date = formatter.date(from: timestamp),
                  date >= windowStart else { continue }
            let context = normalizedString(object["context"], fallback: "unknown_context")
            let errorClass = normalizedString(object["errorClass"], fallback: "legacy_unclassified")
            counts["\(context)\u{1F}\(errorClass)", default: 0] += 1
        }
        return counts.compactMap { key, rows -> Report.RankedErrorLead? in
            let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return Report.RankedErrorLead(context: parts[0], errorClass: parts[1], rows: rows)
        }.sorted {
            if $0.rows != $1.rows { return $0.rows > $1.rows }
            if $0.context != $1.context { return $0.context < $1.context }
            return $0.errorClass < $1.errorClass
        }
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func normalizedString(_ value: JSONValue?, fallback: String) -> String {
        guard case .string(let raw)? = value else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

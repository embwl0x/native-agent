import CryptoKit
import Foundation
import PersistenceCore
import ProviderRouting

/// The durable, last-observed result of a user-initiated native provider
/// reachability check. This is intentionally a single bounded record rather
/// than a claim that every configured provider is continuously monitored.
/// A failed or unavailable probe must replace an earlier green row.
enum LLMProviderStatusFeed {
    static let relativePath = "llm/provider_status.json"
    static let staleAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Small wall-clock disagreement is normal across a recovered process or
    /// filesystem timestamp boundary. A materially future check, however,
    /// cannot be evidence that has happened and must not read as current.
    static let allowedClockSkew: TimeInterval = 5 * 60

    enum Status: String, Sendable, Equatable {
        case ok
        case unavailable
        case error
    }

    struct Record: Sendable, Equatable {
        let status: Status
        let checkedAt: Date
        let detail: String
        let providerID: String?
        let model: String?
        let tested: Bool
    }

    enum Reading: Sendable, Equatable {
        case current(Record)
        case stale(Record)
        case unavailable(String)
        case failed(String)
    }

    static func path(in dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(relativePath)
    }

    static func record(for result: ProviderTestResult, checkedAt: Date = Date()) -> Record {
        let rawStatus = result.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status: Status
        switch rawStatus {
        case "ok" where result.tested:
            status = .ok
        case "ok", "unknown":
            // A provider without a native probe may be configured, but that is
            // not a reachability assertion. Preserve the observation without
            // pretending the provider was checked.
            status = .unavailable
        default:
            status = .error
        }
        let fallbackDetail: String
        switch status {
        case .ok: fallbackDetail = "Provider reachability check passed."
        case .unavailable: fallbackDetail = "No native reachability probe is available for this provider."
        case .error: fallbackDetail = "Provider reachability check failed."
        }
        return Record(
            status: status,
            checkedAt: checkedAt,
            detail: bounded(result.error ?? result.detail, maximum: 240) ?? fallbackDetail,
            providerID: bounded(result.provider_id, maximum: 120),
            model: bounded(result.model_used, maximum: 160),
            tested: result.tested
        )
    }

    static func write(
        _ result: ProviderTestResult,
        dataRoot: URL,
        checkedAt: Date = Date()
    ) async throws {
        try await write(record(for: result, checkedAt: checkedAt), to: path(in: dataRoot),
                        credential: credentialFingerprint(providerID: result.provider_id, dataRoot: dataRoot))
    }

    /// A short hash of the key a test ran against, so only a new key clears
    /// that test's failure, never another save of the account's file.
    static func credentialFingerprint(providerID: String, dataRoot: URL) -> String? {
        guard let key = LLMCredentialResolver.resolveAPIKey(providerConfigFile: "\(providerID).json", dataRoot: dataRoot),
              !key.isEmpty else { return nil }
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ record: Record, to url: URL, credential: String? = nil) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(url) {
            let iso = ISO8601DateFormatter()
            var object: [String: JSONValue] = [
                "schema": .string("llm.provider_status.v2"),
                "status": .string(record.status.rawValue),
                "checkedAt": .string(iso.string(from: record.checkedAt)),
                "detail": .string(bounded(record.detail, maximum: 240) ?? "Provider check produced no detail."),
                "providerId": record.providerID.map { .string($0) } ?? .null,
                "model": record.model.map { .string($0) } ?? .null,
                "tested": .bool(record.tested),
            ]
            if let credential { object["credential"] = .string(credential) }
            // Each provider's own last check too, so a failed one stays on its
            // row after another provider is checked.
            var byProvider: [String: JSONValue] = [:]
            if case .object(let previous)? = (try? Data(contentsOf: url)).flatMap({ try? JSONValue.parse($0) }),
               case .object(let rows)? = previous["byProvider"] {
                byProvider = rows
            }
            if let id = record.providerID { byProvider[id] = .object(object.filter { $0.key != "schema" }) }
            object["byProvider"] = .object(byProvider)
            try await persistence.writeJSON(.object(object), to: url)
        }
    }

    /// What this provider's own last test found, when the test ran and failed
    /// ("key rejected", "HTTP 500"). Nil once a test passes, or once its key
    /// is not the one that test ran against: a reconnect is a new key.
    static func failedTest(providerID: String, dataRoot: URL) -> String? {
        failedTests(providerIDs: [providerID], dataRoot: dataRoot)[providerID]
    }

    /// `failedTest` for each account, from one read of the status file.
    static func failedTests(providerIDs: [String], dataRoot: URL) -> [String: String] {
        guard case .object(let file)? = (try? Data(contentsOf: path(in: dataRoot))).flatMap({ try? JSONValue.parse($0) })
        else { return [:] }
        var failed: [String: String] = [:]
        for id in providerIDs {
            if let detail = failedTest(providerID: id, file: file, dataRoot: dataRoot) { failed[id] = detail }
        }
        return failed
    }

    private static func failedTest(providerID: String, file: [String: JSONValue], dataRoot: URL) -> String? {
        // Its own row, or the file's last check when that was this provider's
        // and was written before rows were kept, so a launch keeps it.
        let own: [String: JSONValue]? = if case .object(let rows)? = file["byProvider"], case .object(let row)? = rows[providerID] {
            row
        } else if file["providerId"] == .string(providerID) { file } else { nil }
        guard let row = own,
              row["status"] == .string(Status.error.rawValue), row["tested"] == .bool(true),
              case .string(let detail)? = row["detail"],
              case .string(let rawCheckedAt)? = row["checkedAt"], let checkedAt = parseTimestamp(rawCheckedAt)
        else { return nil }
        if case .string(let tested)? = row["credential"] {
            return credentialFingerprint(providerID: providerID, dataRoot: dataRoot) == tested ? detail : nil
        }
        // A row from before the key's hash was kept: a save after it is a new key.
        let credential = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(providerID).json")
        if let saved = (try? FileManager.default.attributesOfItem(atPath: credential.path))?[.modificationDate] as? Date,
           saved > checkedAt {
            return nil
        }
        return detail
    }

    static func read(dataRoot: URL, now: Date = Date()) -> Reading {
        let url = path(in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable("Provider status has not been written yet.")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failed("Provider status could not be read.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Provider status is not valid JSON.")
        }
        guard let rawStatus = object["status"] as? String,
              let status = Status(rawValue: rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return .failed("Provider status has an unknown or missing status.")
        }
        guard let rawCheckedAt = object["checkedAt"] as? String,
              let checkedAt = parseTimestamp(rawCheckedAt)
        else {
            return .failed("Provider status has no valid check timestamp.")
        }
        let record = Record(
            status: status,
            checkedAt: checkedAt,
            detail: bounded(object["detail"] as? String, maximum: 240) ?? "Provider check produced no detail.",
            providerID: bounded(object["providerId"] as? String, maximum: 120),
            model: bounded(object["model"] as? String, maximum: 160),
            tested: object["tested"] as? Bool ?? false
        )
        if record.checkedAt.timeIntervalSince(now) > allowedClockSkew {
            return .failed("Provider status check timestamp is too far in the future.")
        }
        switch record.status {
        case .error:
            return .failed(record.detail)
        case .unavailable:
            return .unavailable(record.detail)
        case .ok:
            return now.timeIntervalSince(record.checkedAt) > staleAfter
                ? .stale(record)
                : .current(record)
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        UserDisplayFormatters.parseFoundationISOTimestamp(raw)
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max(0, maximum)))
    }
}

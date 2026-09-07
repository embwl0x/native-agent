import Foundation
import PersistenceCore

/// The durable, last-observed result of a user-initiated native provider
/// reachability check. This is intentionally a single bounded record rather
/// than a claim that every configured provider is continuously monitored.
/// `agent_instrument.swift` reads the same file as the provider lane's last
/// check, so a failed or unavailable probe must replace an earlier green row.
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
        try await write(record(for: result, checkedAt: checkedAt), to: path(in: dataRoot))
    }

    static func write(_ record: Record, to url: URL) async throws {
        let iso = ISO8601DateFormatter()
        let object: [String: JSONValue] = [
            "schema": .string("llm.provider_status.v2"),
            "status": .string(record.status.rawValue),
            "checkedAt": .string(iso.string(from: record.checkedAt)),
            "detail": .string(bounded(record.detail, maximum: 240) ?? "Provider check produced no detail."),
            "providerId": record.providerID.map { .string($0) } ?? .null,
            "model": record.model.map { .string($0) } ?? .null,
            "tested": .bool(record.tested),
        ]
        try await SwiftNativePersistenceCore().writeJSON(.object(object), to: url)
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

/// Fresh provider-path evidence already owned by the resident organism. This
/// is stronger for runtime health than the user-initiated probe above, while
/// the probe remains useful when the organism has no recent observation.
enum ProviderRuntimeHealthFeed {
    static let staleAfter: TimeInterval = 10 * 60
    static let allowedClockSkew: TimeInterval = 5 * 60

    enum Reading: Sendable, Equatable {
        case healthy(savedAt: Date)
        case unhealthy(savedAt: Date, detail: String)
        case unavailable(String)
    }

    static func read(dataRoot: URL, now: Date = Date()) -> Reading {
        let path = dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSavedAt = object["savedAt"] as? String,
              let savedAt = parseTimestamp(rawSavedAt),
              let body = object["bodySchema"] as? [String: Any],
              let available = body["providersAvailable"] as? Bool,
              let healthy = body["providersHealthy"] as? Bool
        else {
            return .unavailable("Recent organism provider health is unavailable.")
        }
        if savedAt.timeIntervalSince(now) > allowedClockSkew {
            return .unavailable("Organism provider health is dated in the future.")
        }
        if now.timeIntervalSince(savedAt) > staleAfter {
            return .unavailable("Organism provider health is stale.")
        }
        guard available else {
            return .unhealthy(savedAt: savedAt, detail: "The organism reports no provider path available.")
        }
        guard healthy else {
            return .unhealthy(savedAt: savedAt, detail: "The organism reports the live provider path needs attention.")
        }
        return .healthy(savedAt: savedAt)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        UserDisplayFormatters.parseFoundationISOTimestamp(raw)
    }
}

import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import os
// Blueprint: | `LLMProviderStatusFeed.swift` | live provider status feed; byte-checked receipt decode reuse, verdict age checked at use |

/// The durable, last-observed result of a user-initiated native provider
/// reachability check. This is intentionally a single bounded record rather
/// than a claim that every configured provider is continuously monitored.
/// A failed or unavailable probe must replace an earlier green row.
public enum LLMProviderStatusFeed {
    public static let relativePath = "llm/provider_status.json"
    public static let staleAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Small wall-clock disagreement is normal across a recovered process or
    /// filesystem timestamp boundary. A materially future check, however,
    /// cannot be evidence that has happened and must not read as current.
    public static let allowedClockSkew: TimeInterval = 5 * 60

    public enum Status: String, Sendable, Equatable {
        case ok
        case unavailable
        case error
    }

    public struct Record: Sendable, Equatable {
        public let status: Status
        public let checkedAt: Date
        public let detail: String
        public let providerID: String?
        public let model: String?
        public let tested: Bool
        /// The typed cause of a failed check, as the probe encoded it.
        public var cause: String? = nil
        public var credential: String? = nil
        // Readiness preserves the saved spelling and unbounded failure detail.
        var savedStatus: String? = nil
        var savedDetail: String? = nil
        var savedCausePresent = false
    }

    public enum Reading: Sendable, Equatable {
        case current(Record)
        case stale(Record)
        case unavailable(String)
        case failed(String)
    }

    /// The probe's verdict on a key the provider refused (401, Anthropic's 403).
    public static let keyRejected = "key rejected"

    public static func path(in dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(relativePath)
    }

    public static func record(for result: NativeAgentShared.ProviderTestResult, checkedAt: Date = Date()) -> Record {
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
            tested: result.tested,
            cause: result.cause
        )
    }

    public static func write(
        _ result: NativeAgentShared.ProviderTestResult,
        dataRoot: URL,
        checkedAt: Date = Date()
    ) async throws {
        // The key the check sent, hashed before it was sent: a key saved while
        // the check ran is never bound to that check's verdict.
        try await write(record(for: result, checkedAt: checkedAt), to: path(in: dataRoot), credential: result.credential)
    }

    /// A short hash of the credential a test ran against (a sign-in's access
    /// token, else the saved key), so only a new credential clears that test's
    /// failure, never another save of the account's file.
    public static func credentialFingerprint(providerID: String, dataRoot: URL) -> String? {
        guard let key = SwiftNativeProviderRouting.signedInAccessToken(providerID: providerID, dataRoot: dataRoot)
                ?? LLMCredentialResolver.resolveAPIKey(providerConfigFile: "\(providerID).json", dataRoot: dataRoot),
              !key.isEmpty else { return nil }
        return fingerprint(key)
    }

    public static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// One checked read of the checks file, made once per routing snapshot;
    /// every readiness branch asks it, never the file. Only the decoded source
    /// is reused by exact bytes; verdict age is evaluated at each use.
    public struct Receipts: Sendable {
        let rows: [String: Reading]
        var legacy: [String: Reading] = [:]
        var diagnostic: Reading? = nil
        /// Why the file could not be read; nil when it was read or is absent.
        public let unreadable: String?

        public enum Verdict: Equatable, Sendable {
            case unchecked
            case proven(Date)
            case rejected
            case failed(String)
        }

        /// What this provider's last check found for exactly `key`. A row
        /// that kept no key hash, or hashed another key, proves nothing here.
        public func verdict(providerID: String, key: String) -> Verdict {
            guard case .current(let record)? = rows[providerID], record.tested,
                  record.credential == fingerprint(key) else { return .unchecked }
            switch record.savedStatus {
            case "ok"?:
                return Date().timeIntervalSince(record.checkedAt) > staleAfter ? .unchecked : .proven(record.checkedAt)
            case "error"?:
                let cause = record.cause.flatMap(ProviderFailure.decoded)
                if cause == .authExpired || (!record.savedCausePresent && record.savedDetail == keyRejected) { return .rejected }
                return .failed(record.savedDetail ?? "the check failed")
            default: return .unchecked
            }
        }
    }

    private static let receiptGeneration = OSAllocatedUnfairLock<(
        path: URL, bytes: Data, receipts: Receipts
    )?>(initialState: nil)

    public static func receipts(dataRoot: URL) -> Receipts {
        let url = path(in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Receipts(rows: [:], diagnostic: .unavailable("Provider status has not been written yet."), unreadable: nil)
        }
        guard let data = try? Data(contentsOf: url) else {
            return Receipts(rows: [:], diagnostic: .failed("Provider status file \(url.path) could not be read."), unreadable: "\(url.path) could not be read")
        }
        return receiptGeneration.withLock { generation in
            if let generation, generation.path == url, generation.bytes == data { return generation.receipts }
            guard case .object(let file)? = try? JSONValue.parse(data) else {
                return Receipts(rows: [:], diagnostic: .failed("Provider status file \(url.path) is not valid JSON."), unreadable: "\(url.path) could not be read")
            }
            func decode(_ row: [String: JSONValue]) -> Reading {
                let strings = row.compactMapValues { if case .string(let value) = $0 { value } else { nil as String? } }
                guard let raw = strings["status"],
                      let status = Status(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return .failed("Provider status file \(url.path) has an unknown or missing status.")
                }
                guard let checked = strings["checkedAt"], let date = NativeTimestampFormat.parseISO8601FractionalFirst(checked) else {
                    return .failed("Provider status file \(url.path) has no valid check timestamp.")
                }
                return .current(Record(status: status, checkedAt: date,
                    detail: bounded(strings["detail"], maximum: 240) ?? "Provider check produced no detail.",
                    providerID: bounded(strings["providerId"], maximum: 120),
                    model: bounded(strings["model"], maximum: 160), tested: row["tested"] == .bool(true),
                    cause: strings["cause"], credential: strings["credential"],
                    savedStatus: raw, savedDetail: strings["detail"], savedCausePresent: row["cause"] != nil))
            }
            var rows: [String: Reading] = [:]
            if case .object(let byProvider)? = file["byProvider"] {
                for (id, value) in byProvider { if case .object(let row) = value { rows[id] = decode(row) } }
            }
            let legacy: [String: Reading]
            if case .string(let id)? = file["providerId"], rows[id] == nil { legacy = [id: decode(file)] } else { legacy = [:] }
            let receipts = Receipts(rows: rows, legacy: legacy, unreadable: nil)
            generation = (url, data, receipts)
            return receipts
        }
    }

    public static func write(_ record: Record, to url: URL, credential: String? = nil) async throws {
        try await SwiftNativePersistenceCore.withFileLock(url) {
            var object: [String: JSONValue] = [
                "schema": .string("llm.provider_status.v2"),
                "status": .string(record.status.rawValue),
                "checkedAt": .string(NativeTimestampFormat.plainZulu(record.checkedAt)),
                "detail": .string(bounded(record.detail, maximum: 240) ?? "Provider check produced no detail."),
                "providerId": record.providerID.map { .string($0) } ?? .null,
                "model": record.model.map { .string($0) } ?? .null,
                "tested": .bool(record.tested),
            ]
            if let credential { object["credential"] = .string(credential) }
            if let cause = record.cause { object["cause"] = .string(cause) }
            // Each provider's own last check too, so a failed one stays on its
            // row after another provider is checked.
            var byProvider: [String: JSONValue] = [:]
            if case .object(let previous)? = (try? Data(contentsOf: url)).flatMap({ try? JSONValue.parse($0) }),
               case .object(let rows)? = previous["byProvider"] {
                byProvider = rows
            }
            if let id = record.providerID { byProvider[id] = .object(object.filter { $0.key != "schema" }) }
            object["byProvider"] = .object(byProvider)
            try await SwiftNativePersistenceCore.writeJSON(.object(object), to: url)
        }
    }

    private static func credentialMatches(providerID: String, tested: String?, checkedAt: Date, dataRoot: URL) -> Bool {
        if let tested { return credentialFingerprint(providerID: providerID, dataRoot: dataRoot) == tested }
        // A row from before the key's hash was kept: a save after it is a new key.
        let credential = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(providerID).json")
        if let saved = (try? FileManager.default.attributesOfItem(atPath: credential.path))?[.modificationDate] as? Date,
           saved > checkedAt {
            return false
        }
        return true
    }

    public static func read(providerID: String, dataRoot: URL, now: Date = Date()) -> Reading {
        let url = path(in: dataRoot)
        let saved = receipts(dataRoot: dataRoot)
        if let diagnostic = saved.diagnostic { return diagnostic }
        guard let own = saved.rows[providerID] ?? saved.legacy[providerID] else {
            return .unavailable("The active provider has no saved connection check.")
        }
        guard case .current(let record) = own else { return own }
        guard credentialMatches(providerID: providerID, tested: record.credential, checkedAt: record.checkedAt, dataRoot: dataRoot) else {
            return .unavailable("The active provider's credential changed after its connection check.")
        }
        if record.checkedAt.timeIntervalSince(now) > allowedClockSkew {
            return .failed("Provider status file \(url.path) has a check timestamp too far in the future.")
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

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max(0, maximum)))
    }
}

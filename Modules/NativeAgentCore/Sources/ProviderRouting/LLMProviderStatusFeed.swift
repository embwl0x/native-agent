import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import os
// Blueprint: | `LLMProviderStatusFeed.swift` | checked, credential-bound observation |

/// A check is one bounded observation of one credential: a connection check, or a model call its provider answered. Failure must replace an earlier green
/// row.
public enum LLMProviderStatusFeed {
    public static let relativePath = "llm/provider_status.json"
    public static let staleAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Tolerate small clock disagreement, but materially future evidence cannot establish current health.
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
        public var cause: String? = nil
        public var credential: String? = nil
        // Readiness preserves the saved spelling and unbounded failure detail.
        var savedStatus: String? = nil
        var savedDetail: String? = nil
    }

    public enum Reading: Sendable, Equatable {
        case current(Record)
        case stale(Record)
        case unavailable(String)
        case failed(String)
    }

    /// Only a check's explicit credential-rejection verdict rejects the key.
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
            // A provider without a native probe may be configured, but that is not a reachability assertion. Preserve the observation without pretending
            // the provider was checked.
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
        // The key the check sent, hashed before it was sent: a key saved while the check ran is never bound to that check's verdict.
        try await write(record(for: result, checkedAt: checkedAt), to: path(in: dataRoot), credential: result.credential)
    }

    /// What a model call's provider said about the credential the call sent.
    public enum Answer: Sendable {
        case answered
        /// The call path classified the provider's reply as a rejection of that credential; the words are its redacted diagnostic.
        case rejected(String)
    }

    /// The receipt names a proof's day and time, not every call, so one credential's answered calls re-prove it at most this often.
    static let answerProofInterval: TimeInterval = 60 * 60

    /// A model call its provider answered checks the credential it sent, as a connection check does, and leaves the same receipt. Proof is written only
    /// when this credential has none from the last hour, a rejection only when its row does not already say so.
    public static func recordAnswer(_ answer: Answer, providerID: String, model: String, credential: String, dataRoot: URL,
                                    answeredAt: Date = Date()) async {
        let saved = receipts(dataRoot: dataRoot)
        // Unreadable checks are already every account's stated failure, and the merge refuses to write through them.
        guard saved.unreadable == nil else { return }
        let verdict = saved.verdict(providerID: providerID, credential: credential)
        let result: NativeAgentShared.ProviderTestResult
        switch answer {
        case .answered:
            if case .proven(let checkedAt) = verdict, answeredAt.timeIntervalSince(checkedAt) < answerProofInterval { return }
            result = .init(provider_id: providerID, status: "ok", tested: true, model_used: model,
                           detail: "A model call was answered.", credential: credential)
        case .rejected(let why):
            if verdict == .rejected { return }
            result = .init(provider_id: providerID, status: "error", tested: true, model_used: model,
                           error: why, cause: ProviderFailure.authExpired.encoded, credential: credential)
        }
        do {
            try await write(result, dataRoot: dataRoot, checkedAt: answeredAt)
        } catch {
            nativeLog("provider_status: %@'s answered call left no receipt: %@", providerID, ProviderFailure.diagnosticDescription(error))
        }
    }

    /// Hash the checked credential so only a new credential clears its failure, never a metadata save.
    public static func credentialFingerprint(providerID: String, dataRoot: URL) throws -> String? {
        let key: String?
        switch SwiftNativeProviderRouting.connectionProbe(providerID, authMode: nil) {
        // The Codex CLI has no connection check, yet the calls it answers bind receipts to its sign-in's token.
        case .oauth, .unsupported:
            key = try SwiftNativeProviderRouting.signedInAccessToken(providerID: providerID, dataRoot: dataRoot)
        case .apiKey:
            key = try LLMCredentialResolver.checkedAPIKey(providerConfigFile: "\(providerID).json", dataRoot: dataRoot)
        }
        guard let key, !key.isEmpty else { return nil }
        return fingerprint(key)
    }

    public static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Snapshots reuse exact checked source bytes; verdict age is evaluated on every use.
    public struct Receipts: Sendable {
        let rows: [String: Reading]
        var diagnostic: Reading? = nil
        /// Missing and unreadable check storage must remain distinguishable.
        public let unreadable: String?

        public enum Verdict: Equatable, Sendable {
            case unchecked
            case proven(Date)
            case rejected
            case failed(String)
        }

        /// A check without the same credential fingerprint proves nothing about this credential.
        public func verdict(providerID: String, credential: String) -> Verdict {
            if case .failed(let why)? = rows[providerID] { return .failed(why) }
            guard case .current(let record)? = rows[providerID], record.tested,
                  record.credential == credential else { return .unchecked }
            guard record.checkedAt.timeIntervalSinceNow <= allowedClockSkew else {
                return .failed("Provider check timestamp is too far in the future.")
            }
            switch record.savedStatus {
            case "ok"?:
                return Date().timeIntervalSince(record.checkedAt) > staleAfter ? .unchecked : .proven(record.checkedAt)
            case "error"?:
                let cause = record.cause.flatMap(ProviderFailure.decoded)
                if cause == .authExpired { return .rejected }
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
        let data: Data
        do {
            guard let present = try ProviderStateValidation.dataIfPresent(at: url) else {
                return Receipts(rows: [:], diagnostic: .unavailable("Provider status has not been written yet."), unreadable: nil)
            }
            data = present
        } catch {
            let why = "Provider status file \(url.path): \(error.localizedDescription)"
            return Receipts(rows: [:], diagnostic: .failed(why), unreadable: why)
        }
        return receiptGeneration.withLock { generation in
            if let generation, generation.path == url, generation.bytes == data { return generation.receipts }
            do {
                let envelope = try envelope(data, at: url)
                var rows: [String: Reading] = [:]
                for (id, value) in envelope {
                    do { rows[id] = .current(try decode(value, at: url, providerID: id)) }
                    catch { rows[id] = .failed(error.localizedDescription) }
                }
                let receipts = Receipts(rows: rows, unreadable: nil)
                generation = (url, data, receipts)
                return receipts
            } catch {
                let why = error.localizedDescription
                return Receipts(rows: [:], diagnostic: .failed(why), unreadable: why)
            }
        }
    }

    /// Validate the shared channel only. Each provider owns its row's damage; the latest-check copy must not gate reads or writes of sibling rows.
    private static func envelope(_ data: Data, at url: URL) throws -> [String: JSONValue] {
        guard case .object(let file) = try JSONValue.parse(data),
              file["schema"] == .string("llm.provider_status.v2"),
              case .object(let rows)? = file["byProvider"] else {
            throw invalid(url, "requires schema llm.provider_status.v2 and a byProvider object")
        }
        return rows
    }

    private static func invalid(_ url: URL, _ why: String) -> ProviderRoutingError {
        .underlying("Provider status at \(url.path) \(why); repair the saved checks before replacing them.")
    }

    private static func decode(_ value: JSONValue, at url: URL, providerID: String? = nil) throws -> Record {
        let location = providerID.map { "row \($0)" } ?? "latest check"
        guard case .object(let row) = value,
              case .string(let raw)? = row["status"], let status = Status(rawValue: raw),
              case .string(let checked)? = row["checkedAt"],
              let date = NativeTimestampFormat.parseISO8601FractionalFirst(checked),
              case .string(let detail)? = row["detail"], !detail.isEmpty,
              case .bool(let tested)? = row["tested"] else {
            throw invalid(url, "has an invalid \(location) (status, checkedAt, detail or tested)")
        }
        func optionalString(_ key: String, nullable: Bool = false) throws -> String? {
            guard let value = row[key] else { return nil }
            if nullable && value == .null { return nil }
            guard case .string(let text) = value, !text.isEmpty else {
                throw invalid(url, "has an invalid \(location).\(key)")
            }
            return text
        }
        let id = try optionalString("providerId", nullable: true)
        if let providerID, providerID.isEmpty || id != providerID {
            throw invalid(url, "has a mismatched \(location).providerId")
        }
        return Record(status: status, checkedAt: date, detail: String(detail.prefix(240)),
            providerID: id, model: try optionalString("model", nullable: true), tested: tested,
            cause: try optionalString("cause"), credential: try optionalString("credential"),
            savedStatus: raw, savedDetail: detail)
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
            // Each provider's own last check too, so a failed one stays on its row after another provider is checked.
            var byProvider: [String: JSONValue] = [:]
            if let data = try ProviderStateValidation.dataIfPresent(at: url) {
                byProvider = try envelope(data, at: url)
            }
            // An untested row observed no credential, so it never replaces a check that did.
            if !record.tested, let id = record.providerID, case .object(let saved)? = byProvider[id], saved["tested"] == .bool(true) { return }
            let row = JSONValue.object(object.filter { $0.key != "schema" })
            _ = try decode(row, at: url, providerID: record.providerID)
            if let id = record.providerID { byProvider[id] = row }
            object["byProvider"] = .object(byProvider)
            try await SwiftNativePersistenceCore.writeJSON(.object(object), to: url)
        }
    }

    public static func read(providerID: String, dataRoot: URL, now: Date = Date()) -> Reading {
        let url = path(in: dataRoot)
        let saved = receipts(dataRoot: dataRoot)
        if let diagnostic = saved.diagnostic { return diagnostic }
        guard let own = saved.rows[providerID] else {
            return .unavailable("The active provider has no saved connection check.")
        }
        guard case .current(let record) = own else { return own }
        guard let tested = record.credential else {
            return .unavailable("The active provider has no credential-bound connection check.")
        }
        do {
            guard try credentialFingerprint(providerID: providerID, dataRoot: dataRoot) == tested else {
                return .unavailable("The active provider's credential changed after its connection check.")
            }
        } catch {
            return .failed(ProviderFailure.diagnosticDescription(error))
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

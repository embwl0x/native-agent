import Foundation
import NativeAgentCore
import PersistenceCore

enum TelegramUpdateClaimPhase: String, Sendable, Equatable, Codable {
    case pending
    case processing
    case queued
    case completed
    case outcomeUnknown = "outcome_unknown"
}

struct TelegramUpdateClaim: Sendable, Equatable {
    let updateId: Int
    let update: TelegramUpdate
    let phase: TelegramUpdateClaimPhase
    let queueAcknowledgementMessageId: Int?
    /// 2026-09-06: for a queued `/retry`, the message text the retry resolved
    /// to at queue time. `/retry` reads the last user message from the
    /// coordinator's in-memory map; after a restart that map is empty, so a
    /// queued retry replayed from this inbox answered "nothing to retry" and
    /// settled its claim. Nil for every other update.
    let resolvedRetryText: String?
    let claimedAt: String
    let updatedAt: String
}

enum TelegramUpdateInboxError: Error, LocalizedError, Equatable {
    case malformedClaim(String)
    case mismatchedUpdateId(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .malformedClaim(let name):
            return "Telegram durable inbox claim is malformed: \(name)"
        case .mismatchedUpdateId(let expected, let actual):
            return "Telegram durable inbox claim id mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Telegram-owned durable admission state. A fetched update is written here
/// before its upstream offset advances. Pending work can therefore survive a
/// crash after acknowledgement; a prior-run `processing` claim is quarantined
/// as outcome-unknown rather than replaying possibly-effecting work. Queued
/// claims also retain their acknowledgement message id so restart recovery
/// reclaims the original controls instead of creating a shadow queue card.
struct TelegramUpdateInbox: Sendable {
    let directory: URL
    private let persistence = SwiftNativePersistenceCore()

    enum ClaimReadKind: Sendable, Equatable, Hashable {
        case recovery
        case mutation
        case diagnosticSnapshot
    }

    @TaskLocal static var claimReadObserver: (@Sendable (ClaimReadKind) -> Void)?

    init(offsetURL: URL) {
        let parent = offsetURL.deletingLastPathComponent()
        if parent.lastPathComponent == "telegram" {
            self.directory = parent.appendingPathComponent("update_inbox", isDirectory: true)
        } else {
            self.directory = parent.appendingPathComponent(
                offsetURL.lastPathComponent + ".inbox",
                isDirectory: true
            )
        }
    }

    func snapshots() async throws -> [TelegramUpdateClaim] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var claims: [TelegramUpdateClaim] = []
        var seenUpdateIDs: Set<Int> = []
        for url in urls where url.pathExtension == "json"
            && Int(url.deletingPathExtension().lastPathComponent) != nil {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            let claim = try decodeClaim(at: url, kind: .diagnosticSnapshot)
            guard url.deletingPathExtension().lastPathComponent == String(claim.updateId),
                  seenUpdateIDs.insert(claim.updateId).inserted else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            claims.append(claim)
        }
        return claims.sorted { $0.updateId < $1.updateId }
    }

    @discardableResult
    func ensurePending(_ update: TelegramUpdate) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: update.updateId)
        return try await withClaimMutationLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                let existing = try decodeClaim(at: path, kind: .mutation)
                try await upsertIndex(existing)
                return existing
            }
            let now = _tgNowString()
            let claim = TelegramUpdateClaim(
                updateId: update.updateId,
                update: update,
                phase: .pending,
                queueAcknowledgementMessageId: nil,
                resolvedRetryText: nil,
                claimedAt: now,
                updatedAt: now
            )
            try await write(claim, to: path)
            try await upsertIndex(claim)
            return claim
        }
    }

    /// 2026-09-06: `resolvedRetryText` rides the phase write. A queued
    /// `/retry` used to become `.queued` first and pin its text in a second
    /// write, so a crash in between left exactly the claim recovery cannot
    /// resolve — the bug the pin was added to fix. Nil keeps whatever the
    /// claim already carries.
    @discardableResult
    func transition(
        updateId: Int,
        from allowed: Set<TelegramUpdateClaimPhase>,
        to phase: TelegramUpdateClaimPhase,
        resolvedRetryText: String? = nil
    ) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            let current = try decodeClaim(at: path, kind: .mutation)
            guard allowed.contains(current.phase) else { return current }
            let next = TelegramUpdateClaim(
                updateId: current.updateId,
                update: current.update,
                phase: phase,
                queueAcknowledgementMessageId: phase == .queued
                    ? current.queueAcknowledgementMessageId
                    : nil,
                resolvedRetryText: resolvedRetryText ?? current.resolvedRetryText,
                claimedAt: current.claimedAt,
                updatedAt: _tgNowString()
            )
            try await write(next, to: path)
            try await upsertIndex(next)
            return next
        }
    }

    @discardableResult
    func recordQueueAcknowledgement(
        updateId: Int,
        messageId: Int
    ) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            let current = try decodeClaim(at: path, kind: .mutation)
            guard current.phase == .queued else { return current }
            let next = TelegramUpdateClaim(
                updateId: current.updateId,
                update: current.update,
                phase: current.phase,
                queueAcknowledgementMessageId: messageId,
                resolvedRetryText: current.resolvedRetryText,
                claimedAt: current.claimedAt,
                updatedAt: _tgNowString()
            )
            try await write(next, to: path)
            try await upsertIndex(next)
            return next
        }
    }

    /// The pinned retry text for this update, or nil when the claim is gone,
    /// unreadable, or was never a queued retry.
    func resolvedRetryText(updateId: Int) async -> String? {
        guard let claim = try? decodeClaim(
            at: claimPath(updateId: updateId),
            kind: .mutation
        ) else { return nil }
        let trimmed = claim.resolvedRetryText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Recovery reads the maintained index, then opens only pending,
    /// processing, or queued claim files. Terminal retention never makes an idle Telegram
    /// tick reread hundreds of historical update payloads.
    func recoverableClaims() async throws -> [TelegramUpdateClaim] {
        try await persistence.withFileLock(indexPath) {
            try await recoverableClaimsLocked()
        }
    }

    private func recoverableClaimsLocked() async throws -> [TelegramUpdateClaim] {
        var index = try await loadIndex()
        var recovered: [TelegramUpdateClaim] = []
        var repairedIndex = false
        for entry in index.entries.values.sorted(by: { $0.updateId < $1.updateId })
        where entry.phase == .pending || entry.phase == .processing || entry.phase == .queued {
            let claim = try decodeClaim(at: claimPath(updateId: entry.updateId), kind: .recovery)
            recovered.append(claim)
            if claim.phase != entry.phase {
                index.entries[entry.updateId] = InboxClaimIndex.Entry(
                    updateId: claim.updateId,
                    phase: claim.phase
                )
                repairedIndex = true
            }
        }
        if repairedIndex { try await writeIndex(index) }
        return recovered
    }

    func pruneTerminalClaims(keepingNewest keep: Int = 256) async {
        try? await persistence.withFileLock(indexPath) {
            await pruneTerminalClaimsLocked(keepingNewest: keep)
        }
    }

    private func pruneTerminalClaimsLocked(keepingNewest keep: Int) async {
        guard var index = try? await loadIndex() else { return }
        let terminal = index.entries.values
            .filter { $0.phase == .completed || $0.phase == .outcomeUnknown }
            .sorted { $0.updateId < $1.updateId }
        guard terminal.count > keep else { return }
        var changed = false
        for entry in terminal.prefix(terminal.count - keep) {
            let path = claimPath(updateId: entry.updateId)
            try? FileManager.default.removeItem(at: path)
            if !FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: path.appendingPathExtension("lock"))
                index.entries.removeValue(forKey: entry.updateId)
                changed = true
            }
        }
        if changed { try? await writeIndex(index) }
    }

    private func claimPath(updateId: Int) -> URL {
        directory.appendingPathComponent("\(updateId).json", isDirectory: false)
    }

    private var indexPath: URL {
        directory.appendingPathComponent("claims_index.json", isDirectory: false)
    }

    // Index ownership precedes claim ownership and spans both durable writes.
    // Recovery, migration, and pruning hold this same index lock, so none can
    // replace another topic's index entry or remove an in-flight claim.
    private func withClaimMutationLock<T: Sendable>(
        _ path: URL,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await persistence.withFileLock(indexPath) {
            try await persistence.withFileLock(path, body)
        }
    }

    private func decodeClaim(at path: URL, kind: ClaimReadKind) throws -> TelegramUpdateClaim {
        Self.claimReadObserver?(kind)
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard case .object(let object) = try? JSONValue.parse(data),
              case .int(let schema)? = object["schemaVersion"], schema == 1,
              case .int(let rawUpdateId)? = object["updateId"],
              let updateId = Int(exactly: rawUpdateId),
              case .string(let rawPhase)? = object["phase"],
              let phase = TelegramUpdateClaimPhase(rawValue: rawPhase),
              case .string(let claimedAt)? = object["claimedAt"], !claimedAt.isEmpty,
              case .string(let updatedAt)? = object["updatedAt"], !updatedAt.isEmpty,
              let updateValue = object["update"],
              let updateData = try? updateValue.serializedData(pretty: false),
              let update = try? JSONDecoder().decode(TelegramUpdate.self, from: updateData) else {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard update.updateId == updateId else {
            throw TelegramUpdateInboxError.mismatchedUpdateId(expected: updateId, actual: update.updateId)
        }
        return TelegramUpdateClaim(
            updateId: updateId,
            update: update,
            phase: phase,
            queueAcknowledgementMessageId: Self.optionalInt(
                object["queueAcknowledgementMessageId"]
            ),
            resolvedRetryText: Self.optionalString(object["resolvedRetryText"]),
            claimedAt: claimedAt,
            updatedAt: updatedAt
        )
    }

    private func write(_ claim: TelegramUpdateClaim, to path: URL) async throws {
        let updateData = try JSONEncoder().encode(claim.update)
        let updateValue = try JSONValue.parse(updateData)
        let value: JSONValue = .object([
            "schemaVersion": .int(1),
            "updateId": .int(Int64(claim.updateId)),
            "phase": .string(claim.phase.rawValue),
            "claimedAt": .string(claim.claimedAt),
            "updatedAt": .string(claim.updatedAt),
            "queueAcknowledgementMessageId": claim.queueAcknowledgementMessageId
                .map { .int(Int64($0)) } ?? .null,
            "resolvedRetryText": claim.resolvedRetryText.map { .string($0) } ?? .null,
            "update": updateValue,
        ])
        try await persistence.writeDataAtomicDurable(
            value.serializedData(pretty: true),
            to: path
        )
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        return raw.isEmpty ? nil : raw
    }

    private static func optionalInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let raw)?: return Int(exactly: raw)
        case .double(let raw)?: return Int(exactly: raw)
        case .string(let raw)?: return Int(raw)
        default: return nil
        }
    }

    private func loadIndex() async throws -> InboxClaimIndex {
        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            // One-time migration for pre-index installs. This may scan retained
            // claims once, but every later tick reads this bounded index first.
            let migrated = InboxClaimIndex(claims: try await snapshots())
            try await writeIndex(migrated)
            return migrated
        }
        let data: Data
        do {
            data = try Data(contentsOf: indexPath)
        } catch {
            throw TelegramUpdateInboxError.malformedClaim(indexPath.lastPathComponent)
        }
        guard let index = try? JSONDecoder().decode(InboxClaimIndex.self, from: data),
              index.isValid else {
            throw TelegramUpdateInboxError.malformedClaim(indexPath.lastPathComponent)
        }
        return index
    }

    private func writeIndex(_ index: InboxClaimIndex) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await persistence.writeDataAtomicDurable(
            JSONEncoder().encode(index),
            to: indexPath
        )
    }

    private func upsertIndex(_ claim: TelegramUpdateClaim) async throws {
        var index = try await loadIndex()
        index.entries[claim.updateId] = InboxClaimIndex.Entry(
            updateId: claim.updateId,
            phase: claim.phase
        )
        try await writeIndex(index)
    }
}

private struct InboxClaimIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let updateId: Int
        let phase: TelegramUpdateClaimPhase
    }

    let schemaVersion: Int
    var entries: [Int: Entry]

    init(claims: [TelegramUpdateClaim] = []) {
        self.schemaVersion = 1
        self.entries = Dictionary(uniqueKeysWithValues: claims.map {
            ($0.updateId, Entry(updateId: $0.updateId, phase: $0.phase))
        })
    }

    var isValid: Bool {
        schemaVersion == 1
            && entries.allSatisfy { id, entry in id == entry.updateId }
    }
}

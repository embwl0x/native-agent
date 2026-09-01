import CryptoKit
import Foundation

enum SlackInboundDeliveryPhase: String, Codable, Sendable {
    case claimed
    case generating
    case prepared
    case dispatching
    case delivered
    case outcomeUnknown = "outcome_unknown"
}

struct SlackPreparedUpload: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let mime: String
}

struct SlackPreparedReply: Codable, Equatable, Sendable {
    let text: String
    let uploads: [SlackPreparedUpload]
    let fingerprint: String

    static func make(text: String, uploads: [SlackPreparedUpload]) -> SlackPreparedReply {
        let uploadIdentity = uploads
            .map { "\($0.path)\u{1F}\($0.name)\u{1F}\($0.mime)" }
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data("\(text)\u{1D}\(uploadIdentity)".utf8))
        return SlackPreparedReply(
            text: text,
            uploads: uploads,
            fingerprint: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

struct SlackDurableInboundPayload: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let downloadURL: String
        let mimeType: String
        let name: String?
        let byteSize: Int?
    }

    let eventId: String
    let teamId: String
    let channelId: String
    let userId: String
    let eventType: String
    let text: String
    let ts: String
    let threadTs: String?
    let channelType: String?
    let isDirectMessage: Bool
    let files: [File]

    init(_ inbound: SlackInboundMessage) {
        eventId = inbound.eventId
        teamId = inbound.teamId
        channelId = inbound.channelId
        userId = inbound.userId
        eventType = inbound.eventType
        text = inbound.text
        ts = inbound.ts
        threadTs = inbound.threadTs
        channelType = inbound.channelType
        isDirectMessage = inbound.isDirectMessage
        files = inbound.files.map {
            File(downloadURL: $0.downloadURL, mimeType: $0.mimeType, name: $0.name, byteSize: $0.byteSize)
        }
    }

    var inbound: SlackInboundMessage {
        SlackInboundMessage(
            eventId: eventId,
            teamId: teamId,
            channelId: channelId,
            userId: userId,
            eventType: eventType,
            text: text,
            ts: ts,
            threadTs: threadTs,
            channelType: channelType,
            isDirectMessage: isDirectMessage,
            files: files.map {
                SlackInboundFile(
                    downloadURL: $0.downloadURL,
                    mimeType: $0.mimeType,
                    name: $0.name,
                    byteSize: $0.byteSize
                )
            }
        )
    }
}

struct SlackInboundDeliveryRecord: Codable, Equatable, Sendable {
    let inbound: SlackDurableInboundPayload
    var phase: SlackInboundDeliveryPhase
    var prepared: SlackPreparedReply?
    var dispatchStartedAt: Date?
    var updatedAt: Date
    var outcomeDetail: String?
}

enum SlackInboundClaimOutcome: Sendable, Equatable {
    case claimed(SlackInboundDeliveryRecord)
    case alreadyDelivered
}

enum SlackInboundJournalError: Error, CustomStringConvertible {
    case malformed
    case saturated(Int)
    case missingClaim(String)

    var description: String {
        switch self {
        case .malformed:
            return "Slack inbound journal is malformed"
        case .saturated(let cap):
            return "Slack inbound journal has reached its pending limit (\(cap))"
        case .missingClaim(let eventId):
            return "Slack inbound journal has no claim for \(eventId)"
        }
    }
}

/// Durable handoff between Socket Mode acknowledgement, local generation, and
/// Slack delivery. Terminal rows are bounded. Pending/ambiguous rows are never
/// evicted: once their cap is reached, admission fails before ACK so Slack can
/// retain and retry the envelope instead of NativeAgent silently dropping it.
actor SlackInboundDeliveryJournal {
    struct RecoverySummary: Sendable, Equatable {
        let pendingCount: Int
        let unknownCount: Int
        let pendingLimit: Int
        /// Damaged journals renamed aside (`…json.stale-<ts>`) rather than
        /// deleted. Non-zero means accepted-but-undelivered rows may have been
        /// lost from the live journal and are only readable in those files.
        var quarantinedCount: Int = 0
        var isAtCapacity: Bool { pendingCount >= pendingLimit }
        var hasQuarantinedEvidence: Bool { quarantinedCount > 0 }
    }

    private struct File: Codable {
        var version = 1
        var records: [SlackInboundDeliveryRecord] = []
        var pendingLimit: Int?
    }

    private let path: URL
    private let terminalCap: Int
    private let pendingCap: Int
    private let encoder: JSONEncoder
    private var activeHandlers: Set<String> = []

    init(dataRoot: URL, terminalCap: Int = 500, pendingCap: Int = 100) {
        path = Self.path(dataRoot: dataRoot)
        self.terminalCap = max(1, terminalCap)
        self.pendingCap = max(1, pendingCap)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    nonisolated static func path(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("inbound_delivery_journal.json")
    }

    /// Counts only, never raw messages or private attachment URLs. The mounted
    /// Connectors status reader uses this independent durable evidence so a
    /// fresh socket hello cannot hide a queue requiring human recovery.
    nonisolated static func recoverySummary(dataRoot: URL) throws -> RecoverySummary? {
        let path = path(dataRoot: dataRoot)
        let existed = FileManager.default.fileExists(atPath: path.path)
        // loadFile may quarantine, so count the evidence files afterwards.
        let file = existed ? try loadFile(path: path) : File()
        let quarantined = quarantinedEvidencePaths(dataRoot: dataRoot).count
        guard existed || quarantined > 0 else { return nil }
        return RecoverySummary(
            pendingCount: file.records.filter { $0.phase != .delivered }.count,
            unknownCount: file.records.filter { $0.phase == .outcomeUnknown }.count,
            pendingLimit: max(1, file.pendingLimit ?? 100),
            quarantinedCount: quarantined
        )
    }

    /// Damaged journals this actor renamed aside, newest last. Never deleted:
    /// they hold accepted message bodies whose delivery is unproven.
    nonisolated static func quarantinedEvidencePaths(dataRoot: URL) -> [URL] {
        let journal = path(dataRoot: dataRoot)
        let directory = journal.deletingLastPathComponent()
        let prefix = journal.lastPathComponent + quarantineSuffixPrefix
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static let quarantineSuffixPrefix = ".stale-"

    func claim(_ inbound: SlackInboundMessage, now: Date = Date()) throws -> SlackInboundClaimOutcome {
        var file = try load()
        if let existing = file.records.first(where: { $0.inbound.eventId == inbound.eventId }) {
            return existing.phase == .delivered ? .alreadyDelivered : .claimed(existing)
        }
        let pending = file.records.filter { $0.phase != .delivered }.count
        guard pending < pendingCap else { throw SlackInboundJournalError.saturated(pendingCap) }
        let record = SlackInboundDeliveryRecord(
            inbound: SlackDurableInboundPayload(inbound),
            phase: .claimed,
            prepared: nil,
            dispatchStartedAt: nil,
            updatedAt: now,
            outcomeDetail: nil
        )
        file.records.append(record)
        try save(file)
        return .claimed(record)
    }

    func acquireHandler(eventId: String) -> Bool {
        activeHandlers.insert(eventId).inserted
    }

    func releaseHandler(eventId: String) {
        activeHandlers.remove(eventId)
    }

    func prepare(eventId: String, reply: SlackPreparedReply, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .prepared
            record.prepared = reply
            record.dispatchStartedAt = nil
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func beginGeneration(eventId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .generating
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func beginDispatch(eventId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .dispatching
            record.dispatchStartedAt = now
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func retryPrepared(eventId: String, detail: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .prepared
            record.dispatchStartedAt = nil
            record.updatedAt = now
            record.outcomeDetail = detail
        }
    }

    func markDelivered(eventId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .delivered
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func markOutcomeUnknown(eventId: String, detail: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .outcomeUnknown
            record.updatedAt = now
            record.outcomeDetail = detail
        }
    }

    func unresolved() throws -> [SlackInboundDeliveryRecord] {
        try load().records
            .filter { $0.phase != .delivered }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    func record(eventId: String) throws -> SlackInboundDeliveryRecord? {
        try load().records.first { $0.inbound.eventId == eventId }
    }

    private func mutate(
        eventId: String,
        update: (inout SlackInboundDeliveryRecord) -> Void
    ) throws -> SlackInboundDeliveryRecord {
        var file = try load()
        guard let index = file.records.firstIndex(where: { $0.inbound.eventId == eventId }) else {
            throw SlackInboundJournalError.missingClaim(eventId)
        }
        update(&file.records[index])
        let result = file.records[index]
        try save(file)
        return result
    }

    private func load() throws -> File {
        try Self.loadFile(path: path)
    }

    nonisolated private static func loadFile(path: URL) throws -> File {
        guard FileManager.default.fileExists(atPath: path.path) else { return File() }
        // A read failure (permissions, I/O) says nothing about the CONTENT and
        // must never quarantine a healthy journal; it stays a hard error.
        let data = try Data(contentsOf: path)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: data)
            guard file.version == 1,
                  Set(file.records.map { $0.inbound.eventId }).count == file.records.count,
                  file.records.allSatisfy({
                      !$0.inbound.eventId.isEmpty
                        && ($0.phase == .claimed || $0.phase == .generating
                            || $0.phase == .outcomeUnknown || $0.prepared != nil)
                  }) else { throw SlackInboundJournalError.malformed }
            return file
        } catch {
            // Damaged bytes used to be terminal: every later load threw
            // `.malformed`, so inbound admission AND recovery stayed dead until
            // a human deleted the file. The bytes are evidence and are kept —
            // renamed aside, never deleted — but they no longer hold the
            // connector down. If the rename fails the old refusal stands,
            // because starting fresh would then overwrite that evidence.
            guard quarantine(path: path) else {
                throw SlackInboundJournalError.malformed
            }
            return File()
        }
    }

    @discardableResult
    nonisolated private static func quarantine(path: URL) -> Bool {
        let directory = path.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        var destination = directory
            .appendingPathComponent(path.lastPathComponent + "\(quarantineSuffixPrefix)\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path), attempt < 100 {
            destination = directory
                .appendingPathComponent(path.lastPathComponent + "\(quarantineSuffixPrefix)\(stamp)-\(attempt)")
            attempt += 1
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        do {
            try FileManager.default.moveItem(at: path, to: destination)
            return true
        } catch {
            // A concurrent owner may already have moved it aside; that is a
            // healed journal, not a failure. Anything else keeps the refusal.
            return !FileManager.default.fileExists(atPath: path.path)
        }
    }

    private func save(_ source: File) throws {
        var file = source
        let delivered = file.records
            .filter { $0.phase == .delivered }
            .sorted { $0.updatedAt > $1.updatedAt }
        let unresolved = file.records.filter { $0.phase != .delivered }
        file.records = unresolved + delivered.prefix(terminalCap)
        file.pendingLimit = pendingCap
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Creation-time 0600, not chmod after publication: the existing slack
        // directory may be 0755 and these rows contain private message bodies.
        guard NativePrivateFile.write(try encoder.encode(file), to: path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

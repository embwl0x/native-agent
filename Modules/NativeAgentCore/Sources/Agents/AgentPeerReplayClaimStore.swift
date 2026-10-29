import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Darwin

// Blueprint: | `AgentPeerReplayClaimStore.swift` | `AgentPeerReplayClaimStore`: principal/protocol/message digest claims and retained receipts; conflicting bytes refuse and prior-life unfinished claims do not resume |

/// At-most-once inbound messages: claim `(principal, protocol, id)` and its
/// digest before transcript admission. Identical bytes return their retained
/// receipt; different bytes conflict. Receipt-less claims resume only in their life.
public struct AgentPeerReplayClaimStore: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// This message is new; the caller owns it and must record a receipt.
        case claimed
        /// The original serialized receipt; no new turn.
        case replay(String)
        /// The id was already used for DIFFERENT bytes.
        case conflict
        /// An identical message is still in flight (no receipt recorded yet).
        case inFlight
        case stopped
    }

    static let maximumClaimAgeSeconds: TimeInterval = 7 * 24 * 3600
    /// Live claims exclude expired tombstones.
    static let maximumClaims = 4096
    /// Capacity refuses new admission; it never evicts replay protection.
    static let maximumTombstones = 1_000_000

    let directory: URL

    public init(dataRoot: URL) {
        directory = dataRoot.appendingPathComponent("agents/peer-claims")
    }

    public static func digest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// An authenticated principal cannot consume another peer's ids.
    public static func key(principal: String, protocolName: String, messageID: String) -> String {
        "\(principal)\u{1F}\(protocolName)\u{1F}\(messageID)"
    }

    private func fileURL(for key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hashed).json")
    }

    public func claim(key: String, digest: String) throws -> Outcome {
        try prepareDirectory()
        let url = fileURL(for: key)
        return try withStoreLock {
            if let existing = try read(url) {
                guard existing.digest == digest else { return .conflict }
                guard let receipt = existing.receipt else {
                    return try DataRootLife.isCurrent(existing.lifeID, in: directory.deletingLastPathComponent().deletingLastPathComponent()) ? .inFlight : .stopped
                }
                return .replay(receipt)
            }
            try makeRoomForClaim()
            try write(Record(lifeID: try DataRootLife.current(in: directory.deletingLastPathComponent().deletingLastPathComponent()),
                             key: key, digest: digest, receipt: nil, at: Date()), to: url)
            return .claimed
        }
    }

    /// A failed receipt write leaves the claim closed to another execution.
    public func recordReceipt(key: String, digest: String, receipt: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let url = fileURL(for: key)
        try? withStoreLock {
            guard let existing = try read(url), existing.digest == digest else { return }
            try write(Record(lifeID: existing.lifeID, key: key, digest: digest, receipt: json, at: existing.at), to: url)
        }
    }

    /// Only validation before a turn starts may release its current-life claim.
    public func release(key: String) {
        let url = fileURL(for: key)
        try? withStoreLock {
            if let existing = try read(url), existing.receipt == nil,
               try DataRootLife.isCurrent(existing.lifeID, in: directory.deletingLastPathComponent().deletingLastPathComponent()),
               Date().timeIntervalSince(existing.at) < Self.maximumClaimAgeSeconds {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Storage

    private struct Record: Codable {
        let lifeID: String?
        let key: String
        let digest: String
        let receipt: String?
        let at: Date
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Claim, receipt, release and pruning share the directory lock.
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try CredentialFileLock.withLock(directory.appendingPathComponent("claims"), body)
    }

    private func read(_ url: URL) throws -> Record? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let maximumBytes = 1_048_576
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumBytes else { throw POSIXError(.EIO) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw POSIXError(.EFBIG) }
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard fileURL(for: record.key) == url else { throw POSIXError(.EIO) }
        // Expire only receipt bytes. The identity/digest tombstone still refuses replay.
        guard Date().timeIntervalSince(record.at) < Self.maximumClaimAgeSeconds else {
            guard record.receipt != nil else { return record }
            let tombstone = Record(lifeID: record.lifeID, key: record.key, digest: record.digest, receipt: nil, at: record.at)
            try? write(tombstone, to: url)
            return tombstone
        }
        return record
    }

    private func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(record), to: url)
    }

    private func makeRoomForClaim() throws {
        let names = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        // Count records, never the live lock or a writer's temporary file.
        let claims = names.filter { Self.isClaimRecordName($0.lastPathComponent) }
        guard claims.count >= Self.maximumClaims else { return }
        var live = 0
        var tombstones = 0
        for url in claims {
            guard let record = try read(url) else { continue }
            if record.receipt == nil,
               Date().timeIntervalSince(record.at) >= Self.maximumClaimAgeSeconds {
                tombstones += 1
            } else {
                live += 1
            }
        }
        guard live < Self.maximumClaims else { throw POSIXError(.ENOSPC) }
        guard tombstones < Self.maximumTombstones else { throw POSIXError(.ENOSPC) }
    }

    /// `<64 lowercase hex>.json` — exactly what `fileURL(for:)` writes.
    static func isClaimRecordName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return stem.count == 64 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

extension AgentPeerReplayClaimStore.Outcome {
    /// The cached receipt, decoded back to the bridge's response shape.
    public var cachedReceipt: [String: Any]? {
        guard case .replay(let json) = self,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

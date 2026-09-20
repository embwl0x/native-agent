import Foundation
import CryptoKit
import PersistenceCore
import Darwin

/// AT-MOST-ONCE FOR INBOUND PEER MESSAGES.
///
/// The MCP wire says its `request_id` is "correlation, not replay protection",
/// and the A2A wire validates a `messageId` and then throws it away for a fresh
/// UUID — so the same signed-looking peer message, re-sent, used to append a
/// second turn and run it again. That is replay, and on a lane that can start
/// work it matters more than the duplicate row.
///
/// So the identity the protocol already carries is CLAIMED durably, before the
/// transcript append, together with a digest of the bytes:
///
///   * a fresh `(principal, protocol, id)` claims and runs;
///   * the same triple with the same bytes returns the ORIGINAL receipt and
///     appends nothing;
///   * the same triple with different bytes is rejected — an id is being
///     reused, and guessing which body the caller meant is not available.
///
/// One small atomic file per claim under `<dataRoot>/agents/peer-claims`,
/// written through the canonical sidecar lock, the same shape
/// `CodexCompletionLifecycle` uses for delivery claims.
struct AgentPeerReplayClaimStore: Sendable {
    enum Outcome: Sendable, Equatable {
        /// This message is new; the caller owns it and must record a receipt.
        case claimed
        /// An identical message was already handled; answer with the original
        /// receipt, carried as its serialized JSON (Sendable across the claim
        /// boundary, where the bridge's own receipts are `[String: Any]`).
        case replay(String)
        /// The id was already used for DIFFERENT bytes.
        case conflict
        /// An identical message is still in flight (no receipt recorded yet).
        case inFlight
    }

    static let maximumClaimAgeSeconds: TimeInterval = 7 * 24 * 3600
    /// The cap on LIVE claims — records still carrying a receipt, or still in
    /// flight. Expired tombstones are not counted against it.
    static let maximumClaims = 4096
    /// The bound on retained tombstones. Each is a key and a digest and nothing
    /// else, so this is a "something is very wrong" ceiling, not a working
    /// limit: it is never reached by real peer traffic, and it refuses
    /// admission rather than deleting replay protection.
    static let maximumTombstones = 1_000_000

    let directory: URL

    init(dataRoot: URL) {
        directory = dataRoot.appendingPathComponent("agents/peer-claims")
    }

    static func digest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// The claim key. The protocol's own id is namespaced by the AUTHENTICATED
    /// principal so one peer cannot burn or probe another's ids.
    static func key(principal: String, protocolName: String, messageID: String) -> String {
        "\(principal)\u{1F}\(protocolName)\u{1F}\(messageID)"
    }

    private func fileURL(for key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hashed).json")
    }

    func claim(key: String, digest: String) throws -> Outcome {
        try prepareDirectory()
        let url = fileURL(for: key)
        return try withStoreLock {
            if let existing = try read(url) {
                guard existing.digest == digest else { return .conflict }
                guard let receipt = existing.receipt else { return .inFlight }
                return .replay(receipt)
            }
            try makeRoomForClaim()
            try write(Record(key: key, digest: digest, receipt: nil, at: Date()), to: url)
            return .claimed
        }
    }

    /// Record the receipt this claim answered with, so an identical replay can
    /// be answered from it. Best effort: a failure here loses idempotency for
    /// that one id, never correctness of the turn that already ran.
    func recordReceipt(key: String, digest: String, receipt: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let url = fileURL(for: key)
        try? withStoreLock {
            guard let existing = try read(url), existing.digest == digest else { return }
            try write(Record(key: key, digest: digest, receipt: json, at: existing.at), to: url)
        }
    }

    /// Release a claim whose turn never started (a validation failure after the
    /// claim), so an honest retry is not permanently answered with `inFlight`.
    func release(key: String) {
        let url = fileURL(for: key)
        try? withStoreLock {
            // A receipt-less record is either a claim still in flight or an
            // expired TOMBSTONE. Only the first may be released; deleting a
            // tombstone would hand the id back to a replay.
            if let existing = try read(url), existing.receipt == nil,
               Date().timeIntervalSince(existing.at) < Self.maximumClaimAgeSeconds {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Storage

    private struct Record: Codable {
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

    /// ONE lock for the whole claim directory.
    ///
    /// Per-claim sidecar locks left `pruneIfNeeded` — which runs inside one
    /// claim's lock but deletes OTHER claims' files — excluding nobody: it
    /// could unlink a claim another caller had just written and was about to
    /// run. The critical sections are a small read plus a rename, so one
    /// directory lock costs nothing and makes claim, receipt, release and
    /// prune mutually exclusive.
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
        // AN EXPIRED CLAIM BECOMES A TOMBSTONE, NOT A DELETION. Deleting it made
        // the id fresh again, so a captured signed peer message re-sent after
        // the retention window ran a second time — the replay this store
        // exists to stop, merely delayed a week. The key and the digest are
        // what refuse the replay, so they are kept; only the RECEIPT is
        // dropped, which is the part that costs space and the part nobody can
        // still be waiting on. A replay of the same bytes now answers
        // `inFlight` rather than re-running the turn.
        guard Date().timeIntervalSince(record.at) < Self.maximumClaimAgeSeconds else {
            guard record.receipt != nil else { return record }
            let tombstone = Record(key: record.key, digest: record.digest, receipt: nil, at: record.at)
            try? write(tombstone, to: url)
            return tombstone
        }
        return record
    }

    private func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        // rename(2), not `replaceItemAt`: a FIRST claim's destination does not
        // exist yet, and `replaceItemAt` documents its original as
        // expected-to-exist — it failed, the failure was discarded, the temp
        // was deleted, and the claim file was never created. Every "claimed"
        // request could then run again, which is the replay this store exists
        // to stop. `rename` creates-or-replaces, atomically, in both cases.
        let renamed = url.withUnsafeFileSystemRepresentation { destination -> Int32 in
            guard let destination else { return -1 }
            return temporary.withUnsafeFileSystemRepresentation { source -> Int32 in
                guard let source else { return -1 }
                return rename(source, destination)
            }
        }
        guard renamed == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "could not record peer claim at \(url.lastPathComponent): \(String(cString: strerror(errno)))"]
            )
        }
    }

    /// Capacity cannot evict live replay protection. Expire old records, then
    /// refuse new admission if the retained window is full.
    private func makeRoomForClaim() throws {
        let names = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        // Claim records ONLY. The directory also holds the `claims.lock`
        // sidecar and, briefly, a `.<uuid>.tmp`; counting those inflated the
        // total, and deleting one would take out a live lock or a writer's
        // half-written record.
        let claims = names.filter { Self.isClaimRecordName($0.lastPathComponent) }
        guard claims.count >= Self.maximumClaims else { return }
        // A TOMBSTONE IS NEVER EVICTED. Evicting one hands its id back to a
        // replay, which is the whole thing this store exists to stop — so the
        // cap is enforced over LIVE claims only and tombstones are simply not
        // counted against it. A store full of live claims still refuses
        // admission rather than forgetting a decision.
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
        // Tombstones are a key and a digest — about 200 bytes each — so the
        // bound exists only so the directory cannot grow without limit. At
        // `maximumTombstones` (1,000,000, which is ~200 MB and far above any
        // real peer traffic) admission is REFUSED rather than a tombstone
        // forgotten; reaching it means something is wrong upstream.
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
    var cachedReceipt: [String: Any]? {
        guard case .replay(let json) = self,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

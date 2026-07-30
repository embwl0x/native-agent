import Foundation
import PersistenceCore

/// Latest authenticated observation of the paired iOS peer.
///
/// This is derived body evidence, not a transport queue or another message
/// ledger. Writers may call it only after the originating envelope has passed
/// HMAC and freshness validation. No payload, token, user text, or signature is
/// retained; the signed event identity is enough to correlate the observation.
struct SignedPeerEvidence: Codable, Equatable, Sendable {
    enum Channel: String, Codable, Sendable {
        case chat
        case inboxAction = "inbox_action"
    }

    var eventID: String
    var channel: Channel
    var peerCreatedAt: Date
    var observedAt: Date
}

enum SignedPeerEvidenceStore {
    static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("mobile", isDirectory: true)
            .appendingPathComponent("signed_peer_evidence.json")
    }

    static func load(dataRoot: URL) -> SignedPeerEvidence? {
        let url = path(dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SignedPeerEvidence.self, from: data)
    }

    static func record(
        eventID: String,
        channel: SignedPeerEvidence.Channel,
        peerCreatedAt: Date,
        observedAt: Date = Date(),
        dataRoot: URL
    ) async throws {
        let cleanID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, cleanID.utf8.count <= 128 else { return }
        let url = path(dataRoot: dataRoot)
        let candidate = SignedPeerEvidence(
            eventID: cleanID,
            channel: channel,
            peerCreatedAt: peerCreatedAt,
            observedAt: observedAt
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(url) {
            if let current = load(dataRoot: dataRoot), current.observedAt > candidate.observedAt {
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(candidate)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}

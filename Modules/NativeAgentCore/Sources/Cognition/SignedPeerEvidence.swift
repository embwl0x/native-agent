import Foundation
import PersistenceCore
import Experiences
// Blueprint: | `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |

/// Record paired-phone evidence only after HMAC and freshness validation; retain no payload, token, speech or signature.
/// A shared iCloud status cannot establish device identity because any account installation can rewrite it.
/// Keep this derived observation separate from transport queues and message ledgers.
public struct SignedPeerEvidence: Codable, Equatable, Sendable {
    public enum Channel: String, Codable, Sendable {
        case chat
        case inboxAction = "inbox_action"
    }

    public var eventID: String
    public var channel: Channel
    public var peerCreatedAt: Date
    public var observedAt: Date
    /// Clamp phone event time to Mac receipt time so draining an old backlog cannot make the phone seem freshly present.
    public var contactAt: Date { min(peerCreatedAt, observedAt) }
}

public enum SignedPeerEvidenceStore {
    public static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("mobile", isDirectory: true)
            .appendingPathComponent("signed_peer_evidence.json")
    }

    public static func load(dataRoot: URL) throws -> SignedPeerEvidence? {
        let url = path(dataRoot: dataRoot)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SignedPeerEvidence.self, from: data)
    }

    public static func record(
        eventID: String,
        channel: SignedPeerEvidence.Channel,
        peerCreatedAt: Date,
        observedAt: Date = Date(),
        dataRoot: URL
    ) async throws {
        let cleanID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, cleanID.utf8.count <= 128 else {
            throw PersistenceCoreError.ioFailure("Signed phone evidence needs its authenticated event ID (1–128 UTF-8 bytes).")
        }
        let url = path(dataRoot: dataRoot)
        let candidate = SignedPeerEvidence(
            eventID: cleanID,
            channel: channel,
            peerCreatedAt: peerCreatedAt,
            observedAt: observedAt
        )
        do {
            try await SwiftNativePersistenceCore.withFileLock(url) {
                if let current = try load(dataRoot: dataRoot), current.contactAt > candidate.contactAt {
                    return
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(candidate)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
            }
        } catch {
            RepairOwed.owe(dataRoot, id: "signed-peer:" + cleanID, kind: .run,
                operation: "mobile.signed_peer_evidence", owner: url.path,
                words: "The authenticated phone contact could not be saved: " + error.localizedDescription,
                tap: "Repair mobile/signed_peer_evidence.json and its access, preserving existing evidence, then reconnect.")
            throw error
        }
    }
}

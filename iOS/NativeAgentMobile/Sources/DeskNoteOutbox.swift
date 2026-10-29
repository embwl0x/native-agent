import Foundation
import SwiftUI
import Observation

/// Save a submitted note with its signed action identity and reuse that identity until Mac confirmation.
struct MobileDeskPendingNote: Codable, Identifiable, Sendable {
    /// Stable across a pre-execution replacement of `submission`.
    let localID: UUID
    var id: String { localID.uuidString }
    let handle: String
    let text: String
    let createdAt: Date
    /// The exact signed envelope this note will be (re)submitted as.
    var submission: InboxAction
    /// Last delivery problem, kept for honesty. A note that has not reached the
    /// Mac yet is still waiting — it is never described as lost.
    var lastError: String?
    var rejectedByMac: Bool? = nil
    /// Missing legacy provenance stays held; a new pairing never adopts it.
    var pairingFingerprint: String? = nil

    var statusLine: String {
        if rejectedByMac == true { return "Your Mac did not add this note" }
        if lastError != nil { return "Delivery is unconfirmed" }
        return "Waiting to reach your Mac"
    }
}

/// Drafts (unsubmitted text) and pending notes (submitted, unconfirmed), both
/// durable and both keyed by Desk handle.
@MainActor
@Observable
final class MobileDeskNoteOutbox {
    static let shared = MobileDeskNoteOutbox()

    private(set) var drafts: [String: String] = [:] {
        didSet { persist(drafts, key: Self.draftsKey) }
    }
    private(set) var pending: [MobileDeskPendingNote] = [] {
        didSet { persist(pending, key: Self.pendingKey) }
    }

    private static let draftsKey = "NativeAgentMobile.deskNoteDrafts.v1"
    private static let pendingKey = "NativeAgentMobile.deskPendingNotes.v1"
    private let defaults: UserDefaults
    private let storage: MobileLocalStorage
    private var inFlight: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = MobileLocalStorage(defaults: defaults)
        if let data = defaults.data(forKey: Self.draftsKey),
           let restored = try? JSONDecoder().decode([String: String].self, from: data) {
            drafts = restored
        }
        if let data = defaults.data(forKey: Self.pendingKey),
           let restored = try? JSONDecoder().decode([MobileDeskPendingNote].self, from: data) {
            pending = restored
        }
    }

    private func persist<Value: Encodable & Sendable>(_ value: Value, key: String) {
        storage.save(key: key, value: { value }) { error in
            NSLog("[DeskNoteOutbox] Could not save note: %@", error.localizedDescription)
        }
    }

    func flushDrafts() {
        Task {
            do { try await storage.flush() }
            catch { NSLog("[DeskNoteOutbox] Could not save draft: %@", error.localizedDescription) }
        }
    }

    // MARK: - Drafts

    func draft(for handle: String) -> String { drafts[handle] ?? "" }

    /// A half-written note belongs to the item, not to the sheet that happened
    /// to be open. Closing the sheet keeps it.
    func setDraft(_ text: String, for handle: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: handle)
        } else {
            drafts[handle] = text
        }
    }

    // MARK: - Pending notes

    func pendingNotes(for handle: String) -> [MobileDeskPendingNote] {
        pending.filter { $0.handle == handle }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Saves the note immediately under a durable signed identity and starts
    /// delivering it. The caller is free to dismiss straight away.
    func submit(handle: String, text: String, engine: iCloudSyncEngine = .shared) {
        guard let pairing = AgentNameCache.fingerprint(engine.pairingStore?.iCloudPairingSecret) else { return }
        let note = MobileDeskPendingNote(
            localID: UUID(),
            handle: handle,
            text: text,
            createdAt: Date(),
            submission: .make(action: "appendDeskItemNote", payload: ["handle": handle, "text": text]),
            lastError: nil,
            pairingFingerprint: pairing
        )
        pending.append(note)
        drafts.removeValue(forKey: handle)
        deliver(note, engine: engine)
    }

    /// Re-attempts every note still waiting, under its retained identity.
    func deliverPending(engine: iCloudSyncEngine = .shared) {
        for note in pending { deliver(note, engine: engine) }
    }

    private func deliver(_ note: MobileDeskPendingNote, engine: iCloudSyncEngine) {
        guard note.rejectedByMac != true, !inFlight.contains(note.id) else { return }
        guard let pairing = note.pairingFingerprint,
              pairing == AgentNameCache.fingerprint(engine.pairingStore?.iCloudPairingSecret) else {
            noteFailure(id: note.id, message: "Saved for another pairing. Submit a new note to send it to this Mac.", rejected: false)
            return
        }
        inFlight.insert(note.id)
        Task { @MainActor in
            defer { inFlight.remove(note.id) }
            do {
                try await storage.flush()
                guard pairing == AgentNameCache.fingerprint(engine.pairingStore?.iCloudPairingSecret) else {
                    throw SyncError.sendFailed("This note belongs to another pairing. Submit a new note to send it here.")
                }
                _ = try await engine.appendDeskItemNote(
                    handle: note.handle,
                    text: note.text,
                    submission: note.submission,
                    intentionalNewRequest: true,
                    onReplacement: { [weak self = self] replacement in
                        // Persist the replacement before its first send so an
                        // uncertain delivery is retried under the same identity.
                        guard let self else { throw CancellationError() }
                        self.replaceSubmission(id: note.id, with: replacement)
                        try await self.storage.flush()
                    }
                )
                // The Mac owns the Desk: its confirmation is what retires this
                // copy, and the refreshed snapshot is what shows the real note.
                resolve(id: note.id)
                await engine.refreshDeskSnapshot()
            } catch {
                let rejected: Bool
                if let syncError = error as? SyncError, case .macRejected = syncError {
                    rejected = true
                } else {
                    rejected = false
                }
                noteFailure(id: note.id, message: error.localizedDescription, rejected: rejected)
            }
        }
    }

    private func replaceSubmission(id: String, with replacement: InboxAction) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].submission = replacement
    }

    private func resolve(id: String) {
        pending.removeAll { $0.id == id }
    }

    private func noteFailure(id: String, message: String, rejected: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].lastError = message
        pending[index].rejectedByMac = rejected
    }
}

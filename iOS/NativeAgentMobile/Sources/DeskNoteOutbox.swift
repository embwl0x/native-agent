import Foundation
import SwiftUI
import Observation

/// Save a submitted note with its signed action identity and reuse that identity until Mac confirmation.
struct MobileDeskPendingNote: Codable, Identifiable, Sendable {
    /// Stable while the original submission awaits Mac confirmation.
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
    var rejectedByMac: Bool = false
    /// Captured on acceptance; a new pairing never adopts it.
    var pairingFingerprint: String

    var statusLine: String {
        if rejectedByMac { return "Your Mac did not add this note" }
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
    private(set) var storageErrors: [String: String] = [:]
    var storageError: String? { storageErrors.values.sorted().first }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = MobileLocalStorage(defaults: defaults)
        do { drafts = try MobileLocalStorage.restore([String: String].self, key: Self.draftsKey, defaults: defaults) ?? [:] }
        catch { storageErrors[Self.draftsKey] = "Saved Desk drafts could not be read: \(error.localizedDescription). The saved bytes are retained; repair this iPhone's saved Desk drafts before editing notes." }
        do { pending = try MobileLocalStorage.restore([MobileDeskPendingNote].self, key: Self.pendingKey, defaults: defaults) ?? [] }
        catch { storageErrors[Self.pendingKey] = "Submitted Desk notes could not be read: \(error.localizedDescription). The saved bytes are retained; repair this iPhone's saved notes before submitting or delivering notes." }
    }

    private func persist<Value: Encodable & Sendable>(_ value: Value, key: String) {
        guard storageErrors[key] == nil else { return }
        storage.save(key: key, value: { value }) { error in
            NSLog("[DeskNoteOutbox] Could not save note: %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.storageErrors[key] = "Could not save Desk notes: \(error.localizedDescription). Keep this screen open and repair iPhone storage before submitting." }
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
        guard storageErrors[Self.draftsKey] == nil else { return }
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

    /// Checkpoint acceptance before the caller clears or dismisses its draft.
    func submit(handle: String, text: String, engine: iCloudSyncEngine = .shared) async throws {
        if let storageError { throw SyncError.persistence(storageError) }
        guard let pairing = AgentNameCache.fingerprint(engine.pairingStore?.iCloudPairingSecret) else {
            throw SyncError.sendFailed("Connect this iPhone to a Mac before adding a note. Your draft is retained.")
        }
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
        do { try await storage.flush() }
        catch {
            storageErrors[Self.pendingKey] = "Submitted Desk notes could not be saved: \(error.localizedDescription). Keep the draft and repair iPhone storage before submitting again."
            throw error
        }
        drafts.removeValue(forKey: handle)
        deliver(note, engine: engine)
    }

    /// Re-attempts every note still waiting, under its retained identity.
    func deliverPending(engine: iCloudSyncEngine = .shared) {
        guard storageErrors[Self.pendingKey] == nil else { return }
        for note in pending { deliver(note, engine: engine) }
    }

    private func deliver(_ note: MobileDeskPendingNote, engine: iCloudSyncEngine) {
        guard !note.rejectedByMac, !inFlight.contains(note.id) else { return }
        let pairing = note.pairingFingerprint
        guard pairing == AgentNameCache.fingerprint(engine.pairingStore?.iCloudPairingSecret) else {
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
                    intentionalNewRequest: true
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

    private func resolve(id: String) {
        pending.removeAll { $0.id == id }
    }

    private func noteFailure(id: String, message: String, rejected: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].lastError = message
        pending[index].rejectedByMac = rejected
    }
}

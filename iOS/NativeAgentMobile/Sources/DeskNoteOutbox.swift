import Foundation
import SwiftUI

/// A Desk note written on the phone, held until the Mac confirms it.
///
/// 2026-09-13: writing a note used to mean standing still with the sheet open
/// until an iCloud round trip came back. Away from the desk that is the whole
/// interaction — you have a thought, you want it on the item, you want to put
/// the phone away. The note is therefore saved the moment it is submitted,
/// carries the SIGNED action identity it will be delivered under, and is
/// reconciled when the Mac confirms. Delivery is retried only under that same
/// retained identity, so a Desk item can never collect the same note twice.
struct MobileDeskPendingNote: Codable, Identifiable, Sendable {
    /// Stable across a signature re-sign, which replaces `submission`.
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

    var statusLine: String { "Waiting to reach your Mac" }
}

/// Drafts (unsubmitted text) and pending notes (submitted, unconfirmed), both
/// durable and both keyed by Desk handle.
@MainActor
final class MobileDeskNoteOutbox: ObservableObject {
    static let shared = MobileDeskNoteOutbox()

    @Published private(set) var drafts: [String: String] = [:] {
        didSet { persist(drafts, key: Self.draftsKey) }
    }
    @Published private(set) var pending: [MobileDeskPendingNote] = [] {
        didSet { persist(pending, key: Self.pendingKey) }
    }

    private static let draftsKey = "NativeAgentMobile.deskNoteDrafts.v1"
    private static let pendingKey = "NativeAgentMobile.deskPendingNotes.v1"
    private let defaults: UserDefaults
    private var inFlight: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.draftsKey),
           let restored = try? JSONDecoder().decode([String: String].self, from: data) {
            drafts = restored
        }
        if let data = defaults.data(forKey: Self.pendingKey),
           let restored = try? JSONDecoder().decode([MobileDeskPendingNote].self, from: data) {
            pending = restored
        }
    }

    private func persist<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
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
        let note = MobileDeskPendingNote(
            localID: UUID(),
            handle: handle,
            text: text,
            createdAt: Date(),
            submission: .make(action: "appendDeskItemNote", payload: ["handle": handle, "text": text]),
            lastError: nil
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
        guard !inFlight.contains(note.id) else { return }
        inFlight.insert(note.id)
        Task { @MainActor in
            defer { inFlight.remove(note.id) }
            do {
                _ = try await engine.appendDeskItemNote(
                    handle: note.handle,
                    text: note.text,
                    submission: note.submission,
                    onReplacement: { [weak self] replacement in
                        // Signature recovery re-signs under a new identity; the
                        // retained record must name the one actually in flight.
                        Task { @MainActor in self?.replaceSubmission(id: note.id, with: replacement) }
                    }
                )
                // The Mac owns the Desk: its confirmation is what retires this
                // copy, and the refreshed snapshot is what shows the real note.
                resolve(id: note.id)
                await engine.refreshDeskSnapshot()
            } catch {
                noteFailure(id: note.id, message: error.localizedDescription)
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

    private func noteFailure(id: String, message: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].lastError = message
    }
}

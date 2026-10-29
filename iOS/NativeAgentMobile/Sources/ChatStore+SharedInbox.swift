import Foundation
import NativeAgentShared

extension ChatStore {
    /// Retain the existing composer queue before deleting the extension's
    /// handoff. Receipts cover a crash between checkpoint and file deletion.
    func importSharedItems(controls: ChatRuntimeControls) {
        sharedInboxControls = controls
        guard !isSwitchingSession, sharedInboxImportTask == nil else { return }
        let generation = sessionSwitchGeneration
        sharedInboxImportTask = Task { [self] in
            defer {
                sharedInboxImportTask = nil
                sharedInboxReadTask = nil
                scheduleQueuedSendDrain()
            }
            do {
                let batch = try await readSharedInbox()
                guard generation == sessionSwitchGeneration else { return }
                if !batch.errors.isEmpty { errorBanner = batch.errors.joined(separator: "\n") }
                let receiptKey = "NativeAgentMobile.importedShareIDs"
                var receipts = Set(defaults.stringArray(forKey: receiptKey) ?? [])
                for (url, item) in batch.items {
                    guard generation == sessionSwitchGeneration else { return }
                    let retainedReceipt = receipts.contains(item.id.uuidString)
                    if !retainedReceipt {
                        if !queuedSends.contains(where: { $0.id == item.id }) {
                            guard enqueueSend(QueuedChatSend(id: item.id, sessionID: selectedSessionID,
                                text: item.text, controls: controls, attachments: item.attachments,
                                createdAt: item.createdAt, pairingFingerprint: item.pairingFingerprint)) else { return }
                        }
                        receipts.insert(item.id.uuidString)
                        let savedReceipts = Array(receipts)
                        storage.save(key: receiptKey, value: { savedReceipts }) { [weak self] error in
                            Task { @MainActor in self?.errorBanner = error.localizedDescription }
                        }
                        do {
                            try await checkpointQueuedSend(item.id)
                        } catch {
                            pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
                            throw error
                        }
                    }
                    // A previous checkpoint may have reported a disk failure.
                    // Keep both receipt and queue, and require a successful flush
                    // before consuming its still-present handoff on a later entry.
                    if retainedReceipt { try await storage.flush() }
                    try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: url) }.value
                    receipts.remove(item.id.uuidString)
                    let savedReceipts = Array(receipts)
                    storage.save(key: receiptKey, value: { savedReceipts }) { [weak self] error in
                        Task { @MainActor in self?.errorBanner = error.localizedDescription }
                    }
                }
            } catch { errorBanner = "Shared item is still waiting: \(error.localizedDescription)" }
        }
    }

    func readSharedInbox() async throws -> (items: [(URL, SharedChatItem)], errors: [String]) {
        if let sharedInboxReadTask { return try await sharedInboxReadTask.value }
        let task = Task.detached(priority: .utility) { try SharedChatInbox.readPendingItems() }
        sharedInboxReadTask = task
        do {
            let batch = try await task.value
            if batch.items.isEmpty { sharedInboxReadTask = nil }
            return batch
        } catch { sharedInboxReadTask = nil; throw error }
    }

    func scheduleSharedInboxRetry() {
        guard sharedInboxControls != nil else { return }
        Task { @MainActor [weak self] in
            // Finish the queue mutation (including a remove/reinsert promotion)
            // before checking capacity or importing another handoff.
            await Task.yield()
            guard let self, let controls = self.sharedInboxControls,
                  self.queuedSendsForSelectedSession.count < QueuedChatSend.maxPerSession else { return }
            self.importSharedItems(controls: controls)
        }
    }
}

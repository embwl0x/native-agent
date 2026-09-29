import Foundation
import NativeAgentShared

extension ChatStore {
    /// Retain the existing composer queue before deleting the extension's
    /// handoff. Receipts cover a crash between checkpoint and file deletion.
    func importSharedItems(controls: ChatRuntimeControls) {
        sharedInboxControls = controls
        guard !isSwitchingSession else { return }
        var unreadableFiles: [String] = []
        defer {
            if !unreadableFiles.isEmpty {
                errorBanner = unreadableFiles.joined(separator: "\n")
            }
            scheduleQueuedSendDrain()
        }
        let receiptKey = "NativeAgentMobile.importedShareIDs"
        var receipts = Set(defaults.stringArray(forKey: receiptKey) ?? [])
        do {
            var items: [(URL, SharedChatItem)] = []
            for url in try SharedChatInbox.pendingFiles() {
                do {
                    items.append((url, try JSONDecoder().decode(SharedChatItem.self, from: Data(contentsOf: url))))
                } catch {
                    do {
                        let directory = url.deletingLastPathComponent().appendingPathComponent("Unreadable", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
                        unreadableFiles.append("A shared item could not be read. Its original file was kept in ChatShareInbox/Unreadable: \(url.lastPathComponent)")
                    } catch {
                        unreadableFiles.append("A shared item could not be moved aside and is still waiting: \(url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
            }
            for (url, item) in items.sorted(by: { $0.1.createdAt < $1.1.createdAt }) {
                if !receipts.contains(item.id.uuidString) {
                    if !queuedSends.contains(where: { $0.id == item.id }) {
                        guard enqueueSend(QueuedChatSend(id: item.id, sessionID: selectedSessionID,
                            text: item.text, controls: controls, attachments: item.attachments,
                            createdAt: item.createdAt)) else { return }
                    }
                    receipts.insert(item.id.uuidString)
                    defaults.set(Array(receipts), forKey: receiptKey)
                    do {
                        try checkpointQueuedSend(item.id)
                    } catch {
                        pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
                        throw error
                    }
                }
                // A previous checkpoint may have reported a disk failure.
                // Keep both receipt and queue, and require a successful flush
                // before consuming its still-present handoff on a later entry.
                guard defaults.synchronize() else {
                    pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
                    throw SharedChatInbox.failure("Could not save the chat queue.")
                }
                try FileManager.default.removeItem(at: url)
                receipts.remove(item.id.uuidString)
                defaults.set(Array(receipts), forKey: receiptKey)
            }
        } catch {
            errorBanner = "Shared item is still waiting: \(error.localizedDescription)"
        }
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

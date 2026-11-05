import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `ICloudDriveOutbox.swift` | Coordinated Drive outbox scanning, consumption and observation |
extension iCloudBridge {
    func checkIosOutbox() {
        guard isSetUp, let docsURL = driveURL else { return }
        guard messageHandler != nil else {
            syncStatus = "iPhone message waiting — starting Mac receiver"
            return
        }
        if outboxScanTask != nil {
            outboxScanQueued = true
            return
        }
        let seenSnapshot = seenMessageIDs
        let inFlightSnapshot = inFlightIncomingMessageIDs
        let secret: Data
        do {
            secret = try PairingSecret.loadOrGenerateSecret()
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] pairing authority unavailable during Drive scan: %@", error.localizedDescription)
            return
        }
        outboxScanGeneration &+= 1
        let scanGeneration = outboxScanGeneration
        let lifecycle = setupGeneration
        outboxScanTask = Task.detached(priority: .utility) { [docsURL, seenSnapshot, inFlightSnapshot, secret] in
            let result = await VolumeIO.result {
                try Self.scanIosOutboxFiles(docsURL: docsURL, seenMessageIDs: seenSnapshot,
                    inFlightMessageIDs: inFlightSnapshot, secret: secret)
            }
            await MainActor.run {
                self.outboxScanTask = nil
                defer {
                    if self.outboxScanQueued, self.isSetUp {
                        self.outboxScanQueued = false
                        self.checkIosOutbox()
                    }
                }
                guard !Task.isCancelled, self.isSetUp, self.outboxScanGeneration == scanGeneration,
                      lifecycle == self.setupGeneration else { return }
                let scan: [PendingOutboxMessage]
                switch result {
                case .success(let messages): scan = messages
                case .failure(let error):
                    self.syncStatus = """
                        Retained Drive messages could not be read: \(error.localizedDescription). Restore the Drive folder's access before resuming them.
                        """
                    return
                }
                if !scan.isEmpty {
                    self.lastSyncAt = Date()
                    self.syncStatus = "Received message from iOS"
                }
                // Process backlog messages serially; claim each only when its turn starts.
                let handoffs = scan.filter { UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let ordinary = scan.filter { !UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let backlog = handoffs + ordinary
                let backlogID = UUID()
                self.outboxBacklogTasks[backlogID] = Task { @MainActor in
                    defer { self.outboxBacklogTasks.removeValue(forKey: backlogID) }
                    for pending in backlog {
                        guard self.isSetUp, lifecycle == self.setupGeneration else { return }
                        guard !self.seenMessageIDs.contains(pending.message.id),
                              !self.inFlightIncomingMessageIDs.contains(pending.message.id) else { continue }
                        self.notePhoneContact(at: pending.message.timestamp)
                        do {
                            try await SignedPeerEvidenceStore.record(
                                eventID: pending.message.id,
                                channel: .chat,
                                peerCreatedAt: pending.message.timestamp,
                                dataRoot: PersistenceCore.defaultDataRoot()
                            )
                        } catch {
                            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                                  pending.message.id, error.localizedDescription)
                        }
                        guard self.isSetUp, lifecycle == self.setupGeneration else { return }
                        let delivery = await self.deliverIncomingChat(pending.message)
                        if delivery != .deferred {
                            if delivery == .delivered || delivery == .handled {
                                guard await Self.appendInboundSuccessReceipt(
                                    pending.message,
                                    transport: "icloud_drive",
                                    secret: secret,
                                    dataRoot: PersistenceCore.defaultDataRoot()
                                ) else {
                                    self.syncStatus = "iPhone request was handled; its required receipt remains owed. The original message remains pending."
                                    continue
                                }
                            }
                            await self.markIosMessageProcessed(pending, docsURL: docsURL, recordIdentity: delivery != .rejected)
                        } else if self.isSetUp, lifecycle == self.setupGeneration {
                            self.markMacRuntimeUnavailable()
                        }
                    }
                }
            }
        }
    }
    struct PendingOutboxMessage: Sendable {
        var message: BridgeMessage
        var fileURL: URL
    }
    nonisolated static func processedMessageIDsURL(docsURL: URL) -> URL {
        docsURL
            .appendingPathComponent(DriveFolder.processed)
            .appendingPathComponent("ios_chat_processed_ids.json")
    }
    nonisolated static func loadProcessedMessageIDs(docsURL: URL) throws -> [String] {
        let url = processedMessageIDsURL(docsURL: docsURL)
        do { return try JSONDecoder().decode([String].self, from: VolumeIO.contents(of: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }
    nonisolated static func saveProcessedMessageIDs(_ ids: [String], docsURL: URL) throws {
        let url = processedMessageIDsURL(docsURL: docsURL)
        let capped = Array(ids.suffix(seenMessageIDsCap))
        let data = try JSONEncoder().encode(capped)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
    }
    private func markIosMessageProcessed(_ pending: PendingOutboxMessage, docsURL: URL, recordIdentity: Bool) async {
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        if recordIdentity { recordSeenMessageID(pending.message.id) }
        let dest = processedDir.appendingPathComponent(pending.fileURL.lastPathComponent)
        let idsSnapshot = seenMessageIDsOrdered
        let sourceURL = pending.fileURL
        let result = await VolumeIO.result { [idsSnapshot, docsURL, dest, sourceURL] in
            try Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
            if FileManager.default.fileExists(atPath: dest.path) {
                guard try VolumeIO.contents(of: dest) == VolumeIO.contents(of: sourceURL) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.removeItem(at: sourceURL)
            } else {
                try FileManager.default.moveItem(at: sourceURL, to: dest)
            }
        }
        switch result {
        case .success:
            lastSyncAt = Date()
            syncStatus = "iPhone request processed"
        case .failure(let error):
            syncStatus = """
                The iPhone request ran, but its Drive completion could not be retained: \(error.localizedDescription). Repair the processed-message store; \
                do not repeat the request.
                """
        }
    }
    nonisolated static func scanIosOutboxFiles(
        docsURL: URL,
        seenMessageIDs: Set<String>,
        inFlightMessageIDs: Set<String>,
        secret: Data
    ) throws -> [PendingOutboxMessage] {
        let iosOutbox = docsURL.appendingPathComponent(DriveFolder.outboxIos)
        let processingDir = docsURL.appendingPathComponent(DriveFolder.processing)
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        let fm = FileManager.default
        var messages: [PendingOutboxMessage] = []
        try? fm.startDownloadingUbiquitousItem(at: iosOutbox)
        try fm.createDirectory(at: processingDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: processedDir, withIntermediateDirectories: true)
        let outboxFiles = try fm.contentsOfDirectory(
            at: iosOutbox, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        let processingFiles = try fm.contentsOfDirectory(
            at: processingDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        let jsonFiles = (outboxFiles + processingFiles).filter { $0.pathExtension == "json" }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }
        func quarantine(_ url: URL, data: Data, reason: String) {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let dest = processedDir.appendingPathComponent("\(reason)_\(digest).done")
            do {
                if fm.fileExists(atPath: dest.path) {
                    guard try VolumeIO.contents(of: dest) == data else { throw CocoaError(.fileReadCorruptFile) }
                    try fm.removeItem(at: url)
                } else {
                    try fm.moveItem(at: url, to: dest)
                }
                nativeLog("[iCloudBridge] preserved %@ Drive envelope under digest %@", reason, digest)
            } catch {
                nativeLog("[iCloudBridge] Drive quarantine unavailable: %@", error.localizedDescription)
            }
        }
        var admittedPaths = Set<URL>()
        for fileURL in jsonFiles {
            let data = try VolumeIO.contents(of: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let msg = try? decoder.decode(BridgeMessage.self, from: data) else {
                quarantine(fileURL, data: data, reason: "malformed")
                continue
            }
            // Authenticate before touching a claim or accepting its identity.
            guard msg.sender == "ios", msg.signature != nil, msg.verifySignature(secret: secret) else {
                quarantine(fileURL, data: data, reason: "rejected_envelope")
                continue
            }
            var currentURL = fileURL
            if fileURL.deletingLastPathComponent().path != processingDir.path {
                let claimed = processingDir.appendingPathComponent(fileURL.lastPathComponent)
                if fm.fileExists(atPath: claimed.path) {
                    do {
                        if try VolumeIO.contents(of: claimed) == data {
                            // The existing handler owns these authenticated claimed bytes, even while queued.
                            try fm.removeItem(at: fileURL)
                        } else {
                            nativeLog("[iCloudBridge] conflicting Drive claim preserved: %@", fileURL.lastPathComponent)
                            quarantine(fileURL, data: data, reason: "conflicting_claim")
                        }
                    } catch {
                        nativeLog("[iCloudBridge] Drive claim comparison failed: %@", error.localizedDescription)
                    }
                    continue
                }
                do {
                    try fm.moveItem(at: fileURL, to: claimed)
                    currentURL = claimed
                } catch {
                    continue
                }
            }
            guard admittedPaths.insert(currentURL).inserted else { continue }
            // Keep in-flight files claimed during rescans so a transient handler failure remains retryable.
            if inFlightMessageIDs.contains(msg.id) {
                continue
            }
            if seenMessageIDs.contains(msg.id) {
                let dest = processedDir.appendingPathComponent("duplicate_\(currentURL.lastPathComponent).done")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }
            messages.append(PendingOutboxMessage(message: msg, fileURL: currentURL))
        }
        messages.sort {
            if $0.message.timestamp != $1.message.timestamp {
                return $0.message.timestamp < $1.message.timestamp
            }
            return $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent
        }
        return messages
    }
    func startMetadataQuery(docsURL: URL) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            docsURL.appendingPathComponent(DriveFolder.outboxIos).path
        )
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery = q
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )
        q.start()
    }
    // Notification callbacks enter the main actor before touching bridge state.
    @objc private nonisolated func metadataQueryDidUpdate(_ note: Notification) {
        let queryID = note.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor in
            guard self.isSetUp, let query = self.metadataQuery,
                  ObjectIdentifier(query) == queryID else { return }
            query.disableUpdates()
            self.checkIosOutbox()
            query.enableUpdates()
        }
    }
}

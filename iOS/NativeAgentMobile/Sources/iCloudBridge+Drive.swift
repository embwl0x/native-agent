import Foundation
import NativeAgentShared
import CryptoKit
import SwiftUI
import UIKit
// Blueprint: | `iCloudBridge+Drive.swift` | Drive acquisition, outbox scanning, consumed-reply archive retention and deadline-bound staged publication on iCloudBridge |

private enum ICloudBridgeIOError: LocalizedError, Sendable {
    case timeout(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timeout(let operation, let seconds):
            return "\(operation) timed out after \(Int(seconds))s. Check iCloud Drive connectivity and try again."
        }
    }
}

enum ICloudLegacyReplyArchive {
    static let folderName = "ios-consumed"
    static let maximumFileCount = 200
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func archive(
        _ fileURL: URL,
        processedRoot: URL,
        fileManager: FileManager = .default
    ) {
        let archiveDirectory = processedRoot.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let destination = archiveDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            // Seen-message persistence remains the delivery guard. Archive
            // maintenance must never prevent a verified reply from reaching Chat.
            NSLog("[iCloudBridge] could not archive consumed legacy reply %@: %@", fileURL.lastPathComponent, error.localizedDescription)
        }
    }

    @discardableResult
    static func prune(
        archiveDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: archiveDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let files = candidates.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }
        let cutoff = now.addingTimeInterval(-maximumAge)
        var survivors: [(url: URL, date: Date)] = []
        var removed = 0
        for file in files {
            if file.date < cutoff {
                if (try? fileManager.removeItem(at: file.url)) != nil { removed += 1 }
            } else {
                survivors.append(file)
            }
        }

        if survivors.count > maximumFileCount {
            let oldestFirst = survivors.sorted {
                if $0.date == $1.date { return $0.url.lastPathComponent < $1.url.lastPathComponent }
                return $0.date < $1.date
            }
            for file in oldestFirst.prefix(survivors.count - maximumFileCount) {
                if (try? fileManager.removeItem(at: file.url)) != nil { removed += 1 }
            }
        }
        return removed
    }
}

private final class ICloudBridgeWriteContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func publishAndResume(
        _ continuation: CheckedContinuation<Void, Error>,
        publish: () throws -> Void
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        do {
            try publish()
            didResume = true
            lock.unlock()
            continuation.resume()
        } catch {
            didResume = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

extension iCloudBridge {
    /// Applies the container lookup only to the setup lifecycle that requested it.
    @MainActor
    func applyContainerResult(_ containerURL: URL?, generation: Int) async {
        guard generation == setupGeneration, isSetUp else { return }
        defer { if generation == setupGeneration { setupTask = nil } }
        guard let containerURL else {
            available = false
            syncStatus = "iCloud unavailable — sign into iCloud in Settings → Apple Account"
            isSetUp = false  // allow retry
            return
        }
        let docsURL = containerURL.appendingPathComponent("Documents")
        do {
            try await VolumeIO.run { try Self.createDriveDirectories(docsURL: docsURL) }
        } catch { available = false; syncStatus = error.localizedDescription; isSetUp = false; return }
        guard generation == setupGeneration, isSetUp else { return }
        driveURL = docsURL
        await iCloudSyncEngine.shared.setup(docsURL: docsURL)
        guard generation == setupGeneration, isSetUp else { return }
        available = true
        syncStatus = "iCloud ready"

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        Task { await PairingStore.synchronizeKVSWithTimeout() }

        startMetadataQuery(docsURL: docsURL)
    }

    nonisolated private static func createDriveDirectories(docsURL: URL) throws {
        let fm = FileManager.default
        for folder in [DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processed] {
            let url = docsURL.appendingPathComponent(folder)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Poll / flush Mac outbox

    func checkMacOutbox() async {
        guard let docsURL = driveURL else { return }
        guard pairingStore?.iCloudPairingSecret != nil else { return }
        guard !isCheckingMacOutbox else {
            macOutboxScanQueued = true
            return
        }
        isCheckingMacOutbox = true
        let generation = setupGeneration
        defer {
            isCheckingMacOutbox = false
            if macOutboxScanQueued {
                macOutboxScanQueued = false
                Task { @MainActor in await self.checkMacOutbox() }
            }
        }

        let messages = await Self.scanMacOutbox(docsURL: docsURL, seenIDs: seenMessageIDs)
        for (fileURL, message) in messages {
            guard generation == setupGeneration else { return }
            _ = await handleIncomingFromTransport(message, archiveDriveFile: {
                await VolumeIO.run {
                    ICloudLegacyReplyArchive.archive(fileURL,
                        processedRoot: docsURL.appendingPathComponent(DriveFolder.processed), fileManager: .default)
                }
            })
        }
    }

    // MARK: - NSMetadataQuery (watches Mac outbox for new iCloud files)

    private func startMetadataQuery(docsURL: URL) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            docsURL.appendingPathComponent(DriveFolder.outboxMac).path
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

    @objc private nonisolated func metadataQueryDidUpdate(_ note: Notification) {
        Task { @MainActor in
            self.metadataQuery?.disableUpdates()
            await self.checkMacOutbox()
            self.metadataQuery?.enableUpdates()
        }
    }

    nonisolated static func writeDataOffMain(
        _ data: Data,
        to url: URL,
        timeoutSeconds: TimeInterval,
        operation: String
    ) async throws {
        guard timeoutSeconds.isFinite, timeoutSeconds >= 0,
              let delay = UInt64(exactly: (timeoutSeconds * 1_000_000_000).rounded(.towardZero)) else {
            throw SyncError.persistence("Invalid timeout for \(operation).")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ICloudBridgeWriteContinuation()
            let writeTask = Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let parent = url.deletingLastPathComponent()
                let stagedURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: stagedURL) }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordError: NSError?
                var writeError: Error?
                coordinator.coordinate(writingItemAt: stagedURL, options: [.forReplacing], error: &coordError) { writeURL in
                    do {
                        try data.write(to: writeURL, options: .atomic)
                    } catch {
                        writeError = error
                    }
                }
                if let coordError {
                    gate.resume(continuation, with: .failure(coordError))
                } else if let writeError {
                    gate.resume(continuation, with: .failure(writeError))
                } else {
                    gate.publishAndResume(continuation) {
                        if fm.fileExists(atPath: url.path) {
                            try fm.removeItem(at: url)
                        }
                        try fm.moveItem(at: stagedURL, to: url)
                    }
                }
            }
            Task.detached {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                writeTask.cancel()
                gate.resume(continuation, with: .failure(ICloudBridgeIOError.timeout(operation, timeoutSeconds)))
            }
        }
    }

    private nonisolated static func scanMacOutbox(
        docsURL: URL,
        seenIDs: Set<String>
    ) async -> [(URL, BridgeMessage)] {
        await VolumeIO.run { () -> [(URL, BridgeMessage)] in
            let macOutbox = docsURL.appendingPathComponent(DriveFolder.outboxMac)
            let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
            let fm = FileManager.default
            try? fm.startDownloadingUbiquitousItem(at: macOutbox)
            guard let files = try? fm.contentsOfDirectory(
                at: macOutbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
            ) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var messages: [(URL, BridgeMessage)] = []
            for fileURL in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Metadata size does not prove that iCloud has downloaded bytes.
                let status = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                guard status == .current else {
                    try? fm.startDownloadingUbiquitousItem(at: fileURL)
                    continue
                }
                guard let data = try? Data(contentsOf: fileURL),
                      let message = try? decoder.decode(BridgeMessage.self, from: data),
                      !seenIDs.contains(message.id) else { continue }
                messages.append((fileURL, message))
            }
            ICloudLegacyReplyArchive.prune(
                archiveDirectory: processedDir.appendingPathComponent(ICloudLegacyReplyArchive.folderName), fileManager: fm)
            return messages
        }
    }
}

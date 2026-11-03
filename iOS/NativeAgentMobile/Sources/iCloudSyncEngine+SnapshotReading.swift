import Foundation
import os
import NativeAgentShared
import CryptoKit
import AppIntents
import SwiftUI
import Observation
// Blueprint: | `iCloudSyncEngine+SnapshotReading.swift` | Snapshot replica freshness, bounded checked acquisition, whole-document decoding and read-health reporting on iCloudSyncEngine |

/// Health belongs to the read that produced it.
enum SnapshotReadHealth: Equatable, Sendable {
    case fine
    case unreadable
    case readFailed(reason: String)

    var failed: Bool {
        if case .readFailed = self { return true }
        return false
    }
}

/// Nil health means acquisition did not finish; retain the accepted diagnostics.
typealias SnapshotReading<Value> = (value: Value?, health: SnapshotReadHealth?)

extension Dictionary where Key == String, Value == SnapshotReadHealth {
    /// Names damaged views and read failures; absent or still-arriving files report no damage.
    func damageSentence(for filenames: Set<String>? = nil) -> String? {
        let damaged = keys.sorted().filter { filenames?.contains($0) ?? true }
        guard !damaged.isEmpty else { return nil }
        let failures = damaged.compactMap { filename -> String? in
            guard case .readFailed(let reason) = self[filename] else { return nil }
            return "\(NAMobileSnapshotGroup.snapshotPageName(filename)) couldn't be read: \(reason)"
        }
        if !failures.isEmpty { return failures.joined(separator: ". ") }
        let names = damaged.map(NAMobileSnapshotGroup.snapshotPageName)
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) couldn't be read - that copy arrived damaged, not late. "
            + "Refresh rereads the received copy. On the Mac, ask your agent to run doctor.repair for icloud_bridge_state to rebuild and publish phone views."
    }
}

extension iCloudSyncEngine {
    /// Data and diagnostics cross the owner's publication boundary together.
    func acceptSnapshot<T>(_ read: SnapshotReading<T>, named filename: String) -> T? {
        if let state = read.health {
            if state == .fine { snapshotHealth.removeValue(forKey: filename) }
            else { snapshotHealth[filename] = state }
        }
        return read.value
    }

    nonisolated static func loadSnapshotArrayOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> SnapshotReading<[T]> {
        do { guard try await awaitCurrentVersion(of: dir.appendingPathComponent(filename)), !Task.isCancelled else { return (nil, nil) } }
        catch { return (nil, .readFailed(reason: error.localizedDescription)) }
        do {
            let result: SnapshotReading<[T]> = try await VolumeIO.run {
                let read = loadSnapshotData(named: filename, in: dir)
                guard let data = read.value else { return (nil, read.health) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do { return (try decoder.decode([T].self, from: data), .fine) }
                catch { return (nil, .readFailed(reason: "The published snapshot is invalid: \(error.localizedDescription). Refresh rereads the received copy; ask your agent on the Mac to run doctor.repair for icloud_bridge_state.")) }
            }
            return Task.isCancelled ? (nil, nil) : result
        } catch is CancellationError { return (nil, nil) }
        catch { return (nil, .readFailed(reason: error.localizedDescription)) }
    }

    nonisolated static func loadSnapshotObjectOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> SnapshotReading<T> {
        do { guard try await awaitCurrentVersion(of: dir.appendingPathComponent(filename)), !Task.isCancelled else { return (nil, nil) } }
        catch { return (nil, .readFailed(reason: error.localizedDescription)) }
        do {
            let result: SnapshotReading<T> = try await VolumeIO.run {
                let read = loadSnapshotData(named: filename, in: dir)
                guard let data = read.value else { return (nil, read.health) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let value = try? decoder.decode(T.self, from: data) else { return (nil, .unreadable) }
                return (value, .fine)
            }
            return Task.isCancelled ? (nil, nil) : result
        } catch is CancellationError { return (nil, nil) }
        catch { return (nil, .readFailed(reason: error.localizedDescription)) }
    }

    private nonisolated static func loadSnapshotData(named filename: String, in dir: URL) -> SnapshotReading<Data> {
        let url = dir.appendingPathComponent(filename)
        let maxBytes = snapshotReadLimitBytes(named: filename)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attrs[.size] as? NSNumber, fileSize.uint64Value > UInt64(maxBytes) {
                return (nil, .readFailed(reason: "The snapshot exceeds its \(maxBytes)-byte read limit. Ask your agent on the Mac to run doctor.repair for icloud_bridge_state; Refresh only rereads the received copy."))
            }
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) { return (nil, nil) }
            return (nil, .readFailed(reason: error.localizedDescription))
        }
        let data: Data
        do { data = try coordinatedRead(url) }
        catch {
            return (nil, .readFailed(reason: error.localizedDescription))
        }
        if data.count > maxBytes {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%d limit=%d", filename, data.count, maxBytes)
            return (nil, .readFailed(reason: "The snapshot exceeds its \(maxBytes)-byte read limit. Ask your agent on the Mac to run doctor.repair for icloud_bridge_state; Refresh only rereads the received copy."))
        }
        return (data, .fine)
    }

    /// Requests current iCloud bytes with a bounded, cancellation-aware wait.
    nonisolated static func awaitCurrentVersion(
        of url: URL,
        timeout: TimeInterval = 2.5
    ) async throws -> Bool {
        guard !Task.isCancelled else { return false }
        let fm = FileManager.default
        let isUbiquitous = fm.isUbiquitousItem(at: url)
        guard isUbiquitous else { return true }
        try fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            let values = try url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            )
            guard let status = values.ubiquitousItemDownloadingStatus else {
                throw SyncError.persistence("iCloud did not provide the snapshot download status. Refresh after checking iCloud connectivity.")
            }
            if acceptsSnapshotReplica(
                isUbiquitous: isUbiquitous,
                hasCurrentVersion: status == .current
            ) {
                return true
            }
            do { try await Task.sleep(for: .seconds(min(0.15, max(0, deadline.timeIntervalSinceNow)))) }
            catch { return false }
        }
        NSLog("[iCloudSync] snapshot %@ still not current after %.1fs — retaining last proven value", url.lastPathComponent, timeout)
        return false
    }

    /// iCloud replicas require a current version; local roots are authoritative at their URL.
    nonisolated static func acceptsSnapshotReplica(
        isUbiquitous: Bool,
        hasCurrentVersion: Bool?
    ) -> Bool {
        !isUbiquitous || hasCurrentVersion == true
    }

    /// Coordinated reads avoid torn bytes; failure preserves publication and reports its cause.
    nonisolated static func coordinatedRead(_ url: URL, options: NSFileCoordinator.ReadingOptions = []) throws -> Data {
        try VolumeIO.requireReadyForReading(url)
        var coordError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: options, error: &coordError
        ) { readURL in
            result = Result { try VolumeIO.contents(of: readURL) }
        }
        if let coordError { throw coordError }
        guard let result else { throw SyncError.persistence("File coordination returned no read result.") }
        return try result.get()
    }

    private nonisolated static func snapshotReadLimitBytes(named filename: String) -> Int {
        switch filename {
        case "chat_transcripts.json":
            return 6 * 1024 * 1024
        case "knowledge_graph.json", "runs.json":
            // Up to 50 full run prompt/output pairs need the same headroom as the graph.
            return 8 * 1024 * 1024
        case "turn_summaries.json":
            // Mac limits this to 256KB; the 512KB read cap allows headroom.
            return 512 * 1024
        default:
            return 4 * 1024 * 1024
        }
    }

    // Async loaders own cancellation-aware replica freshness and off-main coordinated reads.
    func loadSnapshotObjectAsync<T: Decodable & Sendable>(named filename: String, as type: T.Type = T.self) async -> SnapshotReading<T> {
        guard let snapshotDir else { return (nil, nil) }
        return await Self.loadSnapshotObjectOnly(named: filename, in: snapshotDir)
    }
}

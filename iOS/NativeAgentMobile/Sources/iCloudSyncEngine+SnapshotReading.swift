import Foundation
import os
import NativeAgentShared
import CryptoKit
import AppIntents
import SwiftUI
import Observation
// Blueprint: | `iCloudSyncEngine+SnapshotReading.swift` | Snapshot replica freshness, bounded coordinated byte reads, tolerant decoding and read-health reporting on iCloudSyncEngine |

/// Health belongs to the read that produced it.
enum SnapshotReadHealth: Equatable, Sendable {
    case fine
    case unreadable
    case partial(dropped: Int)
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
            + "The Mac's own data is untouched; Refresh asks it for a fresh copy of \(names.count == 1 ? "that view" : "those views")."
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
        guard await awaitCurrentVersion(of: dir.appendingPathComponent(filename)), !Task.isCancelled else { return (nil, nil) }
        let result: SnapshotReading<[T]> = await VolumeIO.run {
            let read = loadSnapshotData(named: filename, in: dir)
            guard let data = read.value else { return (nil, read.health) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let rows = try? decoder.decode([T].self, from: data) { return (rows, .fine) }
            // Decode valid entries independently; dropped records make the snapshot explicitly partial.
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return (nil, .unreadable) }
            let rows = raw.compactMap { item -> T? in
                guard JSONSerialization.isValidJSONObject(item),
                      let bytes = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? decoder.decode(T.self, from: bytes)
            }
            guard !rows.isEmpty else { return (nil, .unreadable) }
            return (rows, rows.count == raw.count ? .fine : .partial(dropped: raw.count - rows.count))
        }
        return Task.isCancelled ? (nil, nil) : result
    }

    nonisolated static func loadSnapshotObjectOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> SnapshotReading<T> {
        guard await awaitCurrentVersion(of: dir.appendingPathComponent(filename)), !Task.isCancelled else { return (nil, nil) }
        let result: SnapshotReading<T> = await VolumeIO.run {
            let read = loadSnapshotData(named: filename, in: dir)
            guard let data = read.value else { return (nil, read.health) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(T.self, from: data) else { return (nil, .unreadable) }
            return (value, .fine)
        }
        return Task.isCancelled ? (nil, nil) : result
    }

    private nonisolated static func loadSnapshotData(named filename: String, in dir: URL) -> SnapshotReading<Data> {
        let url = dir.appendingPathComponent(filename)
        let maxBytes = snapshotReadLimitBytes(named: filename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? NSNumber,
           fileSize.uint64Value > UInt64(maxBytes) {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%llu limit=%d", filename, fileSize.uint64Value, maxBytes)
            return (nil, nil)
        }
        let data: Data
        do { data = try coordinatedRead(url) }
        catch {
            return (nil, FileManager.default.fileExists(atPath: url.path) ? .readFailed(reason: error.localizedDescription) : .fine)
        }
        if data.count > maxBytes {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%d limit=%d", filename, data.count, maxBytes)
            return (nil, nil)
        }
        return (data, .fine)
    }

    /// Requests current iCloud bytes with a bounded, cancellation-aware wait.
    nonisolated static func awaitCurrentVersion(
        of url: URL,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let fm = FileManager.default
        let isUbiquitous = fm.isUbiquitousItem(at: url)
        guard isUbiquitous else { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            guard let values = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ), let status = values.ubiquitousItemDownloadingStatus else { return false }
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
        var coordError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: options, error: &coordError
        ) { readURL in
            result = Result { try Data(contentsOf: readURL) }
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

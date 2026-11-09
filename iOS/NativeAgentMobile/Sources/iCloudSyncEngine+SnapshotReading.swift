import Foundation
import os
import NativeAgentShared
import CryptoKit
import AppIntents
import SwiftUI
import Observation
// Blueprint: | `iCloudSyncEngine+SnapshotReading.swift` | Local CloudKit cache reads, strict document decoding and per-file read health |

/// Keep health with the read that produced it.
enum SnapshotReadHealth: Equatable, Sendable {
    case fine
    case unreadable
    case readFailed(reason: String)

    var failed: Bool {
        if case .readFailed = self { return true }
        return false
    }
}

/// Unfinished acquisition has nil health; retain accepted diagnostics.
typealias SnapshotReading<Value> = (value: Value?, health: SnapshotReadHealth?)

extension Dictionary where Key == String, Value == SnapshotReadHealth {
    /// Report damage only with read/decode evidence; absent or arriving files are not damaged.
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
    /// Publish data and diagnostics together through the owner's boundary.
    func acceptSnapshot<T>(_ read: SnapshotReading<T>, named filename: String) -> T? {
        if let state = read.health {
            if state == .fine { snapshotHealth.removeValue(forKey: filename) }
            else { snapshotHealth[filename] = state }
        }
        return read.value
    }

    nonisolated static func loadSnapshotArrayOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> SnapshotReading<[T]> {
        guard !Task.isCancelled else { return (nil, nil) }
        do {
            let result: SnapshotReading<[T]> = try await VolumeIO.run {
                let read = loadSnapshotData(named: filename, in: dir)
                guard let data = read.value else { return (nil, read.health) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do { return (try decoder.decode([T].self, from: data), .fine) }
                catch { return (nil, .readFailed(reason: """
                    The published snapshot is invalid: \(error.localizedDescription). Refresh rereads the received copy; ask your agent on the Mac to run \
                    doctor.repair for icloud_bridge_state.
                    """)) }
            }
            return Task.isCancelled ? (nil, nil) : result
        } catch is CancellationError { return (nil, nil) }
        catch { return (nil, .readFailed(reason: error.localizedDescription)) }
    }

    nonisolated static func loadSnapshotObjectOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> SnapshotReading<T> {
        guard !Task.isCancelled else { return (nil, nil) }
        do {
            let result: SnapshotReading<T> = try await VolumeIO.run {
                let read = loadSnapshotData(named: filename, in: dir)
                guard let data = read.value else { return (nil, read.health) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do { return (try decoder.decode(T.self, from: data), .fine) }
                catch { return (nil, .readFailed(reason: error.localizedDescription)) }
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
                return (nil, .readFailed(reason: """
                    The snapshot exceeds its \(maxBytes)-byte read limit. Ask your agent on the Mac to run doctor.repair for icloud_bridge_state; Refresh \
                    only rereads the received copy.
                    """))
            }
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) {
                return (nil, nil)
            }
            return (nil, .readFailed(reason: error.localizedDescription))
        }
        let data: Data
        do { data = try coordinatedRead(url) }
        catch {
            return (nil, .readFailed(reason: error.localizedDescription))
        }
        if data.count > maxBytes {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%d limit=%d", filename, data.count, maxBytes)
            return (nil, .readFailed(reason: """
                The snapshot exceeds its \(maxBytes)-byte read limit. Ask your agent on the Mac to run doctor.repair for icloud_bridge_state; Refresh only \
                rereads the received copy.
                """))
        }
        return (data, .fine)
    }

    /// Coordinate reads to avoid torn bytes; failures preserve publication and report their cause.
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

    func loadSnapshotObjectAsync<T: Decodable & Sendable>(named filename: String, as type: T.Type = T.self) async -> SnapshotReading<T> {
        guard let snapshotDir else { return (nil, nil) }
        return await Self.loadSnapshotObjectOnly(named: filename, in: snapshotDir)
    }
}

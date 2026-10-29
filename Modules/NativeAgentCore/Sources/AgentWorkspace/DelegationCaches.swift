import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
import AppKit
import MacControl
import Desk
import StandingBots
import Transcripts
import ChatToolParsing
// Blueprint: | `DelegationCaches.swift` | Read acceleration over authoritative delivery ledgers and unchanged file stamps |

/// Process-local read acceleration only. The ledger remains authoritative. One lock covers stamp validation, append reads and publication across tool observations and the outcome loop. Terminal projections have no clock input.
final class DelegationDeliveryCache: @unchecked Sendable {
    struct Snapshot {
        var byID: [String: DelegationReadout] = [:]
        var ordered: [DelegationReadout] = []
        var deliveredIDs: Set<String> = []
        var availability = DelegationSourceAvailability(source: "codex_deliveries", agent: "codex")
    }
    struct Stamp: Equatable {
        let inode: UInt64
        let device: UInt64
        let modified: Date
        let created: Date
        let size: UInt64
        let permissions: UInt16

        init?(_ a: [FileAttributeKey: Any]) {
            guard let inode = a[.systemFileNumber] as? NSNumber,
                  let device = a[.systemNumber] as? NSNumber,
                  let modified = a[.modificationDate] as? Date,
                  let created = a[.creationDate] as? Date,
                  let size = a[.size] as? NSNumber else { return nil }
            self.inode = inode.uint64Value; self.device = device.uint64Value
            self.modified = modified; self.created = created; self.size = size.uint64Value
            self.permissions = (a[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        }

        func sameFile(as other: Stamp) -> Bool {
            inode == other.inode && device == other.device && created == other.created
        }
    }
    private struct Entry {
        var stamp: Stamp
        var offset: UInt64 = 0
        var committed = Snapshot()
        var visible = Snapshot()
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private static func stamp(_ url: URL) throws -> Stamp? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
        return Stamp(attributes)
    }

    func read(_ url: URL) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let key = url.standardizedFileURL.path
        do {
            guard let stamp = try Self.stamp(url) else { throw CocoaError(.fileReadUnknown) }
            if let entry = entries[key], entry.stamp == stamp { return entry.visible }
            var entry: Entry
            if let previous = entries[key], stamp.sameFile(as: previous.stamp), stamp.size > previous.stamp.size {
                entry = previous
            } else {
                entry = Entry(stamp: stamp)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: entry.offset)
            let data = try file.readToEnd() ?? Data()
            // A moving/replaced file is unavailable for this observation. Never publish a mixed generation or advance its cursor.
            guard try Self.stamp(url) == stamp, UInt64(data.count) == stamp.size - entry.offset else {
                throw CocoaError(.fileReadUnknown)
            }
            let completeEnd = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            for line in data[..<completeEnd].split(separator: 0x0A) {
                consume(Data(line), into: &entry.committed)
            }
            entry.offset += UInt64(completeEnd - data.startIndex)
            entry.visible = entry.committed
            // Preserve legacy files with a final JSON object but no newline. This suffix is provisional: a later append re-reads it from the last complete-line offset, without double-counting malformed rows.
            if completeEnd < data.endIndex { consume(Data(data[completeEnd...]), into: &entry.visible) }
            entry.visible.ordered = entry.visible.byID.values.sorted(by: DelegationStatusProjector.newestFirst)
            if entry.visible.availability.malformedRecords > 0 { entry.visible.availability.status = "partial" }
            entry.stamp = stamp
            entries[key] = entry
            return entry.visible
        } catch {
            entries.removeValue(forKey: key)
            var result = Snapshot()
            let error = error as NSError
            let absent = error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
            result.availability.status = absent ? "absent" : "unavailable"
            result.availability.unreadableFiles = absent ? 0 : 1
            return result
        }
    }

    private func consume(_ line: Data, into snapshot: inout Snapshot) {
        guard !line.allSatisfy({ [0x20, 0x09, 0x0D].contains($0) }) else { return }
        guard let parsed = try? JSONValue.parse(line), case .object(let object) = parsed,
              case .array(let ids)? = object["messageIds"], ids.contains(where: {
                  if case .string(let id) = $0 { return !id.isEmpty }; return false
              }) else {
            snapshot.availability.malformedRecords += 1
            return
        }
        snapshot.availability.readableRecords += 1
        for row in DelegationStatusProjector.projectCodexDeliveries(objects: [object]) {
            if let previous = snapshot.byID[row.id], previous.deliveryOutcome == "delivered",
               previous.recordedThreadID == row.recordedThreadID,
               previous.recordedTurnID == row.recordedTurnID, row.deliveryOutcome != "delivered",
               object["settlement"] == nil { continue }
            snapshot.byID[row.id] = row
            if row.deliveryOutcome == "delivered" { snapshot.deliveredIDs.insert(row.id) }
            else if object["settlement"] != nil { snapshot.deliveredIDs.remove(row.id) }
        }
    }
}

/// An unchanged regular-file stamp reuses job parses and inbox tails; projection (which depends on `now`) still runs on every read.
final class DelegationFileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])]] = [:]
    private var tails: [String: (stamp: SnapshotTailOpLog.FileStamp, found: [String: [String: String]])] = [:]

    static func stamp(_ url: URL) throws -> SnapshotTailOpLog.FileStamp {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        return SnapshotTailOpLog.FileStamp(info)
    }

    func jobSnapshot(_ directory: String) -> [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])] {
        lock.withLock { jobs[directory] ?? [:] }
    }
    func putJobs(_ directory: String, _ files: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])]) {
        lock.withLock { jobs[directory] = files }
    }
    func tail(_ key: String, stamp: SnapshotTailOpLog.FileStamp) -> [String: [String: String]]? {
        lock.withLock { tails[key].flatMap { $0.stamp == stamp ? $0.found : nil } }
    }
    func putTail(_ key: String, stamp: SnapshotTailOpLog.FileStamp, _ found: [String: [String: String]]) {
        lock.withLock { tails[key] = (stamp, found) }
    }
}

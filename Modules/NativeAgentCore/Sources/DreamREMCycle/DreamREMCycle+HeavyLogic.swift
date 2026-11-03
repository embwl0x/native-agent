import Foundation
import CryptoKit
import PersistenceCore
import PersonaEngine
import NativeAgentCore
import MemoryV2

// Blueprint: | `DreamREMCycle+HeavyLogic.swift` | REM stateless helpers: checked persona reads and rendering; durable denial tombstones; archival shares the dream reservation and retains damaged claim sections for repair, preserving live UUID collision copies |

// REM tombstones and diary archival retain their persisted formats.

/// Use the live compiler's checked active-persona selection while preserving
/// Dream/REM's selected SOUL, VOICE, GROWTH and AGENTS documents and USER projection.
func readDreamPersonaDocs(
    dataRoot: URL, personaRoot: URL, surface: String
) async throws -> [String: String] {
    let compiler = PersonaCompiler(
        engine: SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    )
    let snapshot = try await compiler.contextSourceSnapshot(surface: surface)
    // USER carries the pinned core; dreams receive new memories separately.
    let userCore: [String]?
    if try !MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) {
        userCore = []
    } else if LLMCallContext.preview {
        // A preview cannot call unreadable input an empty self-half. The
        // admitted prompt is identical when the same canonical read succeeds.
        userCore = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).userPromptCore(surface: "chat")
    } else {
        userCore = try await SwiftNativeMemoryV2.userCoreForBackground(dataRoot: dataRoot)
    }
    var docs: [String: String] = [:]
    for id in ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"] {
        let raw = snapshot.packet.activeDocs[id] ?? ""
        switch id {
        case "USER": docs["\(id).md"] = UserMDAutogenMarkers.promptText(raw, pinnedCore: userCore)
        default: docs["\(id).md"] = raw
        }
    }
    return docs
}

/// The selected persona documents in their shared dream/REM order.
func renderDreamPersonaDocs(_ docs: [String: String]) -> String {
    ["SOUL.md", "VOICE.md", "GROWTH.md", "USER.md", "AGENTS.md"].map { name in
        let raw = docs[name] ?? ""
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : raw
        return "--- \(name) ---\n\(body)"
    }.joined(separator: "\n\n")
}

// MARK: - REMTombstoneStore

/// Persisted fingerprint: lowercase, collapse whitespace, then the first 16 SHA256 hex characters.
public func _tombstone_fp(_ text: String) -> String {
    let pieces = text.lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    let normalized = pieces.joined(separator: " ")
    let digest = sha256Hex(normalized)
    return String(digest.prefix(16))
}

/// SHA256 without narrowing the input byte count.
private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Persisted tombstone fields retain their snake_case JSON keys.
public struct REMTombstoneRecord: Codable, Sendable, Equatable {
    public let rejected_at: String
    public let target_doc: String
    public let reason: String
    public let preview: String

    public init(rejected_at: String, target_doc: String, reason: String, preview: String) {
        self.rejected_at = rejected_at
        self.target_doc = target_doc
        self.reason = reason
        self.preview = preview
    }
}

/// A nonempty tombstone file is durable rejection state. Do not reinterpret an
/// unreadable or malformed file as an empty denylist: callers must abort so a
/// rejected proposal cannot return and a subsequent write cannot erase it.
public enum REMTombstoneStoreError: Error, LocalizedError, Equatable, Sendable {
    case unreadable(path: String)
    case malformed(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "REM tombstones at \(path) could not be read; preserving the file and aborting the pass"
        case .malformed(let path):
            return "REM tombstones at \(path) are malformed; preserving the file and aborting the pass"
        }
    }
}

public actor REMTombstoneStore {
    private let path: URL
    private let fm = FileManager.default

    /// Tombstones are a JSON dictionary keyed by the first 16 SHA256 fingerprint characters.
    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        let dir = dataRoot.appendingPathComponent("harness", isDirectory: true)
        self.path = dir.appendingPathComponent(".rem_tombstones.json")
    }

    /// Read the current fingerprint dictionary. Only a missing file means no
    /// tombstones; unreadable or malformed state preserves its rejection authority.
    public func loadAll() throws -> [String: REMTombstoneRecord] {
        guard fm.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileNoSuchFile.rawValue {
                return [:]
            }
            throw REMTombstoneStoreError.unreadable(path: path.path)
        }
        do { return try JSONDecoder().decode([String: REMTombstoneRecord].self, from: data) }
        catch { throw REMTombstoneStoreError.malformed(path: path.path) }
    }

    private func saveAll(_ dict: [String: REMTombstoneRecord]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(dict)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }

    public func record(_ proposal: REMProposalRow, reason: String) async throws {
        let proposedText = proposal.proposalText
        let fp = _tombstone_fp(proposedText)
        let isoNow = ISO8601DateFormatter().string(from: Date())
        let record = REMTombstoneRecord(
            rejected_at: isoNow,
            target_doc: proposal.targetDoc,
            reason: reason,
            preview: String(proposedText.prefix(200))
        )
        // The sibling <path>.lock covers the whole read-modify-write.
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var dict = try await self.loadAll()
            dict[fp] = record
            try await self.saveAll(dict)
        }
    }

    /// Reload after distillation so denials committed during the LLM call apply
    /// to the whole batch; never reuse the pre-run authority validation.
    public func filterTombstoned(_ proposals: [REMProposalRow]) throws -> [REMProposalRow] {
        guard !proposals.isEmpty else { return [] }
        let dict = try loadAll()
        return proposals.filter { dict[_tombstone_fp($0.proposalText)] == nil }
    }
}

// MARK: - DreamArchiver

public actor DreamArchiver {
    private let dataRoot: URL
    private let fm = FileManager.default

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func archiveOlderThan(daysOld: Int = 14, now: Date = Date()) async throws -> Int {
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard daysOld >= 0,
              let cutoff = DreamREMSchedule.localCalendar().date(byAdding: .day, value: -daysOld, to: now),
              cutoff.timeIntervalSinceReferenceDate.isFinite else {
            throw NSError(domain: "DreamArchiver", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dream archive age must be a representable nonnegative day count."])
        }
        let files = try FileBackedDreamDiary(dataRoot: dataRoot).discover(in: .active, matching: .dated)
        guard !files.isEmpty else { return 0 }
        guard let reservation = try DreamRunReservation.acquire(at: diary.appendingPathComponent(".dream_run.lock")) else {
            throw DreamREMCycleError.underlying("dream settlement holds the diary; archival remains owed")
        }
        defer { reservation.release() }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate]
        var moved = 0
        for file in files where file.name.hasSuffix(".md") {
            let name = file.name
            let stem = file.stem
            guard let dateStr = file.day else { continue }
            guard let parsed = dateFmt.date(from: dateStr) else { continue }
            if parsed >= cutoff { continue }
            let year = String(dateStr.prefix(4))
            let archiveDir = diary.appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(year, isDirectory: true)
            if !fm.fileExists(atPath: archiveDir.path) {
                try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            }
            let src = diary.appendingPathComponent(name)
            // Unavailable claim sections stay active until repaired, even past the age cutoff.
            let content = try String(contentsOf: src, encoding: .utf8)
            guard DreamClaim.read(in: content).allSatisfy({ $0.unavailable == nil }) else { continue }
            var dst = archiveDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                if try Data(contentsOf: src) == Data(contentsOf: dst) {
                    try fm.removeItem(at: src)
                    moved += 1
                    continue
                }
                // A restored copy may be older than the archive. Keep both
                // readable under their original date; never replace writing.
                dst = archiveDir.appendingPathComponent("\(stem)_\(UUID().uuidString).md")
            }
            try fm.moveItem(at: src, to: dst)
            moved += 1
        }
        return moved
    }
}

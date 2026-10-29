import Foundation
#if canImport(Darwin)
import Darwin
#endif
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatChecks.swift` | ChatSessionsCheck and ChatMessagesIntegrityCheck read session and transcript stores without mutation; ChatMessagesScanCache memoizes canonical-path fingerprints and scan counts |

/// Read `chat/sessions.json` without mutation: absence is ok/zero; unreadable, empty or non-array data fails.
public struct ChatSessionsCheck: DoctorCheck {
    public let id: String = "chat_sessions"
    public let title: String = "Persistent Chat Sessions"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsPath.path, isDirectory: &isDir) else {
            // Fresh install: no sessions.json yet.
            return CheckResult(source: "chat/sessions.json",
                id: id, title: title, status: "ok",
                detail: "Chat session storage is available with 0 session(s).",
                repair: nil
            )
        }
        if isDir.boolValue {
            return failResult("sessions.json is a directory, not a file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: sessionsPath)
        } catch {
            return failResult("could not read sessions.json: \(error.localizedDescription)")
        }
        if data.isEmpty {
            return failResult("sessions.json is empty (not valid JSON)")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return failResult("sessions.json is not valid JSON")
        }
        guard let list = parsed as? [Any] else {
            return failResult("sessions.json is not a JSON list")
        }
        // Count only objects with nonempty string IDs.
        let count = list.reduce(into: 0) { acc, row in
            if let dict = row as? [String: Any],
               let sid = dict["id"] as? String, !sid.isEmpty {
                acc += 1
            }
        }
        return CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: "ok",
            detail: "Chat session storage is available with \(count) session(s).",
            repair: nil
        )
    }

    private func failResult(_ reason: String) -> CheckResult {
        CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: "fail",
            detail: "Chat session store failed: \(reason)",
            harm: "Saved conversations cannot be found or reopened.",
            human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent("chat/sessions.json"),
                shape: "This is a JSON array of saved chat session objects, each with its original nonempty id and saved metadata."))
    }
}

/// Process-wide canonical-path scan memo; matching fingerprints reuse counts, while each run recomputes its verdict.
actor ChatMessagesScanCache {
    struct Entry: Sendable, Equatable {
        let stamp: SnapshotTailOpLog.FileStamp
        let totalLines: Int
        let malformedLines: Int
        let unreadable: Bool
    }

    private var entries: [String: Entry] = [:]

    func lookup(path: String, stamp: SnapshotTailOpLog.FileStamp?) -> Entry? {
        guard let stamp, let entry = entries[path], entry.stamp == stamp else { return nil }
        return entry
    }

    func store(path: String, entry: Entry) {
        entries[path] = entry
    }

    /// Evict missing files only beneath the scanned directory's canonical prefix.
    func retain(paths: Set<String>, under prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) || paths.contains($0.key) }
    }
}

public struct ChatMessagesIntegrityCheck: DoctorCheck {
    public let id: String = "chat_messages"
    public let title: String = "Chat Message Logs"
    private let root: URL

    /// Process-wide fingerprint memo.
    static let sharedScanCache = ChatMessagesScanCache()

    /// Resolve symlinks for shared memo identity and directory-scoped eviction.
    static func cacheKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return CheckResult(source: "chat/messages/",
                id: id,
                title: title,
                status: "warn",
                detail: "Chat message directory is missing at \(dir.path).",
                harm: "New conversation messages cannot be saved.",
                repair: nil
            )
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jsonl" }
        } catch {
            return CheckResult(source: "chat/messages/",
                id: id,
                title: title,
                status: "fail",
                detail: "Could not list chat message directory: \(error.localizedDescription)",
                harm: "Saved conversation messages cannot be read.",
                human_action: StorageCheck.accessStep(dir.path), ask: .permission
            )
        }

        var totalLines = 0
        var malformedLines = 0
        var malformedFiles: [URL] = []

        var scannedPaths: Set<String> = []

        for file in files {
            let cacheKey = Self.cacheKey(file)
            scannedPaths.insert(cacheKey)
            let fingerprint = SnapshotTailOpLog.fileStamp(file).flatMap { $0 == .absent ? nil : $0 }
            if let memo = await Self.sharedScanCache.lookup(path: cacheKey, stamp: fingerprint) {
                totalLines += memo.totalLines
                malformedLines += memo.malformedLines
                if memo.unreadable || memo.malformedLines > 0 { malformedFiles.append(file) }
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                malformedFiles.append(file)
                if let fingerprint {
                    await Self.sharedScanCache.store(
                        path: cacheKey,
                        entry: .init(
                            stamp: fingerprint,
                            totalLines: 0, malformedLines: 0, unreadable: true
                        )
                    )
                }
                continue
            }
            var fileMalformed = 0
            var fileTotal = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                fileTotal += 1
                if (try? JSONValue.parse(Data(line.utf8))) == nil {
                    fileMalformed += 1
                }
            }
            totalLines += fileTotal
            if let fingerprint {
                await Self.sharedScanCache.store(
                    path: cacheKey,
                    entry: .init(
                        stamp: fingerprint,
                        totalLines: fileTotal, malformedLines: fileMalformed, unreadable: false
                    )
                )
            }
            if fileMalformed > 0 {
                malformedLines += fileMalformed
                malformedFiles.append(file)
            }
        }

        await Self.sharedScanCache.retain(
            paths: scannedPaths, under: Self.cacheKey(dir) + "/"
        )

        if malformedLines > 0 || !malformedFiles.isEmpty {
            return CheckResult(source: malformedFiles.map { "chat/messages/" + $0.lastPathComponent }.joined(separator: ", "),
                id: id,
                title: title,
                status: "fail",
                detail: "\(malformedLines) malformed chat JSONL row(s) across \(malformedFiles.count) file(s).",
                harm: "Parts of saved conversations cannot be read.",
                repair: nil,
                human_action: malformedLines == 0 ? malformedFiles.first.map { ToolFailureError.fileRepairInstruction($0,
                    shape: "This transcript holds one saved chat message JSON object per line, retaining the original message identities, roles, content and ordering.") } : nil)
        }
        return CheckResult(source: "chat/messages/",
            id: id,
            title: title,
            status: "ok",
            detail: "Chat message logs are valid (\(files.count) file(s), \(totalLines) row(s))."
        )
    }
}

import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
// Blueprint: | `AgentContactTaskReceipts.swift` | Retained task receipts, checked archive and payload compaction |
extension AgentContactTasks {
    private func taskKey(id: String, owner: String) -> String {
        AgentPeerReplayClaimStore.digest(Data((owner + "\u{1f}" + id).utf8))
    }
    func retain(_ task: AgentContactTask) throws {
        var task = task
        if task.state.terminal, !task.owesCallbacks, !task.hasReplyPayload { task.replyPayloadExpired = true }
        try saveTasks([task])
        if task.state.terminal, task.hasReplyPayload {
            terminalPayloadWrites += 1
            if terminalPayloadWrites >= 32 {
                try compactReplyPayloads()
                terminalPayloadWrites = 0
            }
        }
    }
    private func compactReplyPayloads() throws {
        let retained = try retainedTasks().filter { $0.state.terminal && !$0.owesCallbacks && $0.replyPayloadExpired != true && $0.hasReplyPayload }
        var expired: [AgentContactTask] = []
        for saved in retained.sorted(by: { $0.updated < $1.updated }).prefix(max(0, retained.count - capacity)) {
            var compact = saved
            var digests = saved.delegatedCompletionDigests ?? [:]
            for (id, part) in saved.delegatedCompletions ?? [:] {
                digests[id] = try Self.completionDigest(part)
            }
            compact.delegatedCompletionDigests = digests
            compact.text = ""; compact.parts = []; compact.toolResult = nil; compact.delegatedCompletions = nil
            compact.failure = nil
            compact.replyPayloadExpired = true
            compact.detail = "The saved reply has expired. This task's outcome is retained; do not resend automatically."
            expired.append(compact)
        }
        if !expired.isEmpty {
            try saveTasks(expired)
            for task in expired { records[task.id]?.task = task }
        }
    }
    private func withTaskDatabase<Value>(_ body: (OpaquePointer) throws -> Value) throws -> Value {
        let directory = dataRoot.appendingPathComponent("agents/a2a-receipts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("outcomes.sqlite")
        var info = stat()
        let exists = Darwin.lstat(url.path, &info) == 0
        guard exists ? info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 : errno == ENOENT else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | (exists ? 0 : SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        defer { sqlite3_close(database) }
        if !exists {
            guard sqlite3_exec(database, "CREATE TABLE outcomes (key TEXT PRIMARY KEY, receipt BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
        }
        var schema: OpaquePointer?
        defer { sqlite3_finalize(schema) }
        guard sqlite3_prepare_v2(database, "SELECT key, receipt FROM outcomes LIMIT 0", -1, &schema, nil) == SQLITE_OK,
              sqlite3_step(schema) == SQLITE_DONE else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard sqlite3_exec(database, "PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        return try body(database)
    }
    func retainedTasks(id: String? = nil, owner: String? = nil) throws -> [AgentContactTask] {
        let key = id.flatMap { id in owner.map { taskKey(id: id, owner: $0) } }
        let directory = dataRoot.appendingPathComponent("agents/a2a-replies")
        let urls: [URL]
        var info = stat()
        if let key { urls = [directory.appendingPathComponent(key + ".json")] }
        else if Darwin.lstat(directory.path, &info) != 0, errno == ENOENT { urls = [] }
        else { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" } }
        var unavailable: Set<String> = []
        // Import file-first evidence durably before removing it; an interrupted import repeats safely.
        for url in urls {
            do {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if fd < 0, errno == ENOENT { continue }
                guard fd >= 0 else { throw AgentContactFailure(code: -32603, message: "Retained task could not be opened at \(url.path). Existing bytes were preserved.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                let limit = AgentContactPart.maximumOutputBytes * 2
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit,
                      let data = try handle.read(upToCount: limit + 1), data.count <= limit,
                      let task = try? JSONDecoder().decode(AgentContactTask.self, from: data),
                      NativeAgentA2AWire.locator(task.id) != nil, taskKey(id: task.id, owner: task.owner) == url.deletingPathExtension().lastPathComponent else {
                    throw AgentContactFailure(code: -32603, message: "Retained task is invalid at \(url.path). Existing bytes were preserved.")
                }
                try saveTasks([task])
                try FileManager.default.removeItem(at: url)
            } catch {
                if key != nil { throw error }
                unavailable.insert(url.deletingPathExtension().lastPathComponent)
                nativeLog("AgentContactTasks: retained task remains unavailable at %@: %@", url.path, error.localizedDescription)
            }
        }
        return try withTaskDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, key == nil ? "SELECT key, receipt FROM outcomes" : "SELECT key, receipt FROM outcomes WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if let key, sqlite3_bind_text(statement, 1, key, -1, transient) != SQLITE_OK {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
            var tasks: [AgentContactTask] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return tasks }
                guard result == SQLITE_ROW, let rawKey = sqlite3_column_text(statement, 0) else {
                    throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
                }
                let storedKey = String(cString: rawKey)
                if unavailable.contains(storedKey) { continue }
                let count = Int(sqlite3_column_bytes(statement, 1))
                guard count > 0, count <= AgentContactPart.maximumOutputBytes * 2,
                      let bytes = sqlite3_column_blob(statement, 1),
                      let task = try? JSONDecoder().decode(AgentContactTask.self, from: Data(bytes: bytes, count: count)),
                      NativeAgentA2AWire.locator(task.id) != nil,
                      taskKey(id: task.id, owner: task.owner) == storedKey,
                      key == nil || (task.id == id && task.owner == owner) else {
                    if key != nil { throw AgentContactFailure(code: -32603, message: "The retained task is invalid. Existing bytes were preserved.") }
                    nativeLog("AgentContactTasks: invalid retained task at %@; existing bytes were preserved", storedKey)
                    continue
                }
                tasks.append(task)
            }
        }
    }
    private func saveTasks(_ tasks: [AgentContactTask]) throws {
        try withTaskDatabase { database in
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            var committed = false
            defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO outcomes (key, receipt) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET receipt = excluded.receipt", -1, &statement, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for task in tasks {
                let key = taskKey(id: task.id, owner: task.owner)
                let data = try JSONEncoder().encode(task)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let bound = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
                }
                guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
                      bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                    throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
                }
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            committed = true
        }
    }
    static func completionDigest(_ part: AgentContactPart) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AgentPeerReplayClaimStore.digest(try encoder.encode(part))
    }
}

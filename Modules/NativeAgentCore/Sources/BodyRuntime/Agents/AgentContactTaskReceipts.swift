import Foundation
import NativeAgentShared
import MacNerves
import ProviderRouting
import NativeAgentCore
import PersistenceCore
import Darwin
import CoreFoundation
import SQLite3
// Blueprint: | `AgentContactTaskReceipts.swift` | SQLite owns checked task receipts and payload debt. |
extension AgentContactTasks {
    private func taskKey(id: String, owner: String) -> String {
        SHA256Hex.of(Data((owner + "\u{1f}" + id).utf8))
    }
    func retain(_ task: AgentContactTask) throws {
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
        let retained = try retainedTasks().filter { $0.state.terminal && $0.replyRecovery == nil && !$0.owesCallbacks && $0.hasReplyPayload }
        var expired: [AgentContactTask] = []
        for saved in retained.sorted(by: { $0.updated < $1.updated }).prefix(max(0, retained.count - capacity)) {
            var compact = saved
            var digests = saved.delegatedCompletionDigests ?? [:]
            for (id, part) in saved.delegatedCompletions ?? [:] {
                digests[id] = try Self.completionDigest(part)
            }
            compact.delegatedCompletionDigests = digests
            compact.toolExecutionResultClass = saved.retainedToolExecution
            compact.text = ""; compact.parts = []; compact.toolResult = nil; compact.delegatedCompletions = nil
            compact.failure = nil
            compact.replyPayloadExpired = true
            compact.detail = AgentContactTask.expiredReplyDetail
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
        let exists = unsafe Darwin.lstat(url.path, &info) == 0
        guard exists ? info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 : errno == ENOENT else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | (exists ? 0 : SQLITE_OPEN_CREATE)
        guard unsafe sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let database = handle else {
            if let handle = unsafe handle { unsafe sqlite3_close(handle) }
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        defer { unsafe sqlite3_close(database) }
        if !exists {
            guard unsafe sqlite3_exec(database, "CREATE TABLE outcomes (key TEXT PRIMARY KEY, receipt BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
        }
        var schema: OpaquePointer?
        defer { unsafe sqlite3_finalize(schema) }
        guard unsafe sqlite3_prepare_v2(database, "SELECT key, receipt FROM outcomes LIMIT 0", -1, &schema, nil) == SQLITE_OK,
              unsafe sqlite3_step(schema) == SQLITE_DONE else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard unsafe sqlite3_exec(database, "PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
        }
        return try unsafe body(database)
    }
    func retainedTasks(id: String? = nil, owner: String? = nil, requireComplete: Bool = false) throws -> [AgentContactTask] {
        let key = id.flatMap { id in owner.map { taskKey(id: id, owner: $0) } }
        return try unsafe withTaskDatabase { database in
            var statement: OpaquePointer?
            guard unsafe sqlite3_prepare_v2(database, key == nil ? "SELECT key, receipt FROM outcomes" : "SELECT key, receipt FROM outcomes WHERE key = ?",
                -1, &statement, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
            defer { unsafe sqlite3_finalize(statement) }
            let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if let key, unsafe sqlite3_bind_text(statement, 1, key, -1, transient) != SQLITE_OK {
                throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
            }
            var tasks: [AgentContactTask] = []
            while true {
                let result = unsafe sqlite3_step(statement)
                if result == SQLITE_DONE { return tasks }
                guard result == SQLITE_ROW, let rawKey = unsafe sqlite3_column_text(statement, 0) else {
                    throw AgentContactFailure(code: -32603, message: "The conversation could not be read")
                }
                let storedKey = unsafe String(cString: rawKey)
                let count = Int(unsafe sqlite3_column_bytes(statement, 1))
                // Older writers committed larger valid receipts. The write budget does not invalidate existing rows.
                guard count > 0,
                      let bytes = unsafe sqlite3_column_blob(statement, 1),
                      let task = try? JSONDecoder().decode(AgentContactTask.self, from: unsafe Data(bytes: bytes, count: count)),
                      NativeAgentA2AWire.locator(task.id) != nil,
                      taskKey(id: task.id, owner: task.owner) == storedKey,
                      key == nil || (task.id == id && task.owner == owner) else {
                    if key != nil || requireComplete { throw AgentContactFailure(code: -32603,
                        message: "The retained task at key \(storedKey) is invalid. Existing bytes were preserved.") }
                    nativeLog("AgentContactTasks: invalid retained task at %@; existing bytes were preserved", storedKey)
                    continue
                }
                tasks.append(task)
            }
        }
    }
    private func saveTasks(_ tasks: [AgentContactTask]) throws {
        try unsafe withTaskDatabase { database in
            guard unsafe sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            var committed = false
            defer { if !committed { unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
            var statement: OpaquePointer?
            guard unsafe sqlite3_prepare_v2(database,
                "INSERT INTO outcomes (key, receipt) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET receipt = excluded.receipt", -1, &statement,
                nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            defer { unsafe sqlite3_finalize(statement) }
            let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for task in tasks {
                let key = taskKey(id: task.id, owner: task.owner)
                let data = try JSONEncoder().encode(task)
                guard data.count <= AgentContactTask.maximumReceiptBytes else {
                    throw AgentContactFailure(code: -32602, message: "The retained reply reached its size limit")
                }
                unsafe sqlite3_reset(statement)
                unsafe sqlite3_clear_bindings(statement)
                let bound = unsafe data.withUnsafeBytes { bytes in
                    unsafe sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
                }
                guard unsafe sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
                      bound == SQLITE_OK, unsafe sqlite3_step(statement) == SQLITE_DONE else {
                    throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
                }
            }
            guard unsafe sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw AgentContactFailure(code: -32603, message: "The reply could not be saved. Do not resend automatically.")
            }
            committed = true
        }
    }
    static func completionDigest(_ part: AgentContactPart) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Hex.of(try encoder.encode(part))
    }
}

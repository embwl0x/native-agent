import Foundation
import Darwin

// Blueprint: | `ProcessTreeReaper.swift` | `ProcessTreeReaper`, `OwnedProcessGroup`: identity-bound process evidence |

public struct ProcessTreeIdentity: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}

/// Inspection is evidence for resource accounting, never a containment or termination mechanism. Failed inspection cannot establish an empty tree.
public struct ProcessTreeSnapshot: Sendable, Equatable {
    public let rootPID: Int32
    public let rootIdentity: ProcessTreeIdentity?
    public let descendants: [ProcessTreeIdentity]
    public let inspectionFailure: String?
    public let groupOwnerID: UUID?
    public init(rootPID: Int32, rootIdentity: ProcessTreeIdentity?, descendants: [ProcessTreeIdentity], inspectionFailure: String? = nil,
        groupOwnerID: UUID? = nil) {
        self.rootPID = rootPID; self.rootIdentity = rootIdentity
        self.descendants = descendants; self.inspectionFailure = inspectionFailure
        self.groupOwnerID = groupOwnerID
    }
}

public enum ProcessTreeReaper {
    public static func snapshot(rootPID: Int32, retaining prior: ProcessTreeSnapshot? = nil) -> ProcessTreeSnapshot {
        var descendants: [ProcessTreeIdentity] = []
        var root: ProcessTreeIdentity?
        let ownerID = prior == nil ? OwnedProcessGroup.owner(rootPID)?.identity : prior?.groupOwnerID
        do {
            guard rootPID > 0 else { throw POSIXError(.EINVAL) }
            root = try currentIdentity(for: rootPID)
            if let previous = prior?.rootIdentity, root != previous {
                // Root exit is not permission to inspect a replacement PID.
                return ProcessTreeSnapshot(rootPID: rootPID, rootIdentity: nil,
                    descendants: try (prior?.descendants ?? []).filter { try currentIdentity(for: $0.pid) == $0 }, groupOwnerID: ownerID)
            }
            var visited = Set<Int32>()
            func walk(_ parent: ProcessTreeIdentity) throws {
                for pid in try immediateChildren(of: parent.pid) where pid > 0 && pid != rootPID {
                    guard visited.insert(pid).inserted, let child = try currentIdentity(for: pid) else { continue }
                    try walk(child)
                    descendants.append(child)
                }
            }
            if let root { try walk(root) }
            for retained in prior?.descendants ?? [] where !visited.contains(retained.pid) {
                if try currentIdentity(for: retained.pid) == retained {
                    try walk(retained); descendants.append(retained)
                }
            }
            return ProcessTreeSnapshot(rootPID: rootPID, rootIdentity: root, descendants: descendants, groupOwnerID: ownerID)
        } catch {
            return ProcessTreeSnapshot(rootPID: rootPID, rootIdentity: root, descendants: descendants,
                inspectionFailure: """
                    Process tree \(rootPID) could not be inspected: \(error.localizedDescription). Its descendants are unknown.
                    """, groupOwnerID: ownerID)
        }
    }

    /// Only a still-owned unreaped child grants permission to signal a PGID. No descendant enumeration, direct PID, or second mechanism is used.
    @discardableResult public static func signal(_ snapshot: ProcessTreeSnapshot, signal: Int32) -> Bool {
        guard let owner = OwnedProcessGroup.owner(snapshot.rootPID), owner.identity == snapshot.groupOwnerID else { return false }
        return owner.send(signal)
    }

    @discardableResult public static func quiesceAndKill(_ snapshot: ProcessTreeSnapshot) -> ProcessTreeSnapshot {
        guard let owner = OwnedProcessGroup.owner(snapshot.rootPID), owner.identity == snapshot.groupOwnerID else {
            return ProcessTreeSnapshot(rootPID: snapshot.rootPID, rootIdentity: snapshot.rootIdentity,
                descendants: snapshot.descendants,
                inspectionFailure: """
                    No retained child owns process group \(snapshot.rootPID); termination was not attempted.
                    """, groupOwnerID: snapshot.groupOwnerID)
        }
        guard owner.send(SIGSTOP) else { return snapshot }
        if owner.send(SIGKILL) { owner.observeStop() }
        return snapshot
    }

    private static func currentIdentity(for pid: Int32) throws -> ProcessTreeIdentity? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        if read == 0, errno == ESRCH { return nil }
        guard read == expected, Int32(bitPattern: info.pbi_pid) == pid else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return ProcessTreeIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private static func immediateChildren(of parent: Int32) throws -> [Int32] {
        var capacity = 16
        while capacity <= 16_384 {
            var values = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let count = proc_listchildpids(parent, &values, Int32(values.count * MemoryLayout<pid_t>.stride))
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0, errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if Int(count) < capacity { return Array(values.prefix(Int(count))) }
            capacity *= 2
        }
        throw POSIXError(.EOVERFLOW)
    }
}

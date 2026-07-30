import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// PID plus immutable process-start identity. A retained PID is signaled only
/// while its current BSD identity still matches this value, preventing a PID
/// reused during the escalation grace window from receiving a stale kill.
public struct ProcessTreeIdentity: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// A payload-free snapshot of one subprocess tree. Descendants are kept
/// leaf-first so fallback signals reach grandchildren before their parent can
/// exit and reparent them out of the original tree.
public struct ProcessTreeSnapshot: Sendable, Equatable {
    public let rootPID: Int32
    public let rootIdentity: ProcessTreeIdentity?
    public let descendants: [ProcessTreeIdentity]

    public var descendantPIDs: [Int32] { descendants.map(\.pid) }

    public init(
        rootPID: Int32,
        rootIdentity: ProcessTreeIdentity?,
        descendants: [ProcessTreeIdentity]
    ) {
        self.rootPID = rootPID
        self.rootIdentity = rootIdentity
        self.descendants = descendants
    }
}

/// Darwin subprocess-tree lifecycle support shared by Mac Control and custom
/// tool execution. Process groups remain the fast path, but a parent-side
/// `setpgid` is necessarily best-effort after `exec`. The explicit descendant
/// snapshot is the fallback that prevents a shell's background child from
/// surviving cancellation when group ownership was not established.
public enum ProcessTreeReaper {
    /// Best-effort process-group ownership. Foundation normally creates a new
    /// group for Process children on Darwin; this also wins the pre-exec race
    /// on runtimes that do not.
    public static func ensureChildLeadsOwnProcessGroup(_ pid: Int32) {
        #if canImport(Darwin)
        guard pid > 0 else { return }
        for _ in 0..<10 {
            if setpgid(pid, pid) == 0 { return }
            let group = getpgid(pid)
            if group == pid || group == -1 { return }
            usleep(5_000)
        }
        #else
        _ = pid
        #endif
    }

    /// Captures the currently reachable descendant tree. Supplying a prior
    /// snapshot retains already-observed identities after their parent exits
    /// and scans any verified survivors for newly forked children.
    public static func snapshot(
        rootPID: Int32,
        retaining prior: ProcessTreeSnapshot? = nil
    ) -> ProcessTreeSnapshot {
        #if canImport(Darwin)
        guard rootPID > 0 else {
            return ProcessTreeSnapshot(
                rootPID: rootPID, rootIdentity: nil, descendants: []
            )
        }

        // A refresh must stay bound to the original root identity. If that PID
        // was reused, do not traverse or signal the replacement process.
        let rootIdentity: ProcessTreeIdentity?
        if let prior {
            rootIdentity = identityStillMatches(prior.rootIdentity) ? prior.rootIdentity : nil
        } else {
            rootIdentity = currentIdentity(for: rootPID)
        }

        var visited = Set<Int32>()
        var leafFirst: [ProcessTreeIdentity] = []

        func walk(_ parent: ProcessTreeIdentity) {
            for childPID in immediateChildren(of: parent.pid)
            where childPID > 0 && childPID != rootPID {
                guard visited.insert(childPID).inserted,
                      let child = currentIdentity(for: childPID)
                else { continue }
                walk(child)
                leafFirst.append(child)
            }
        }

        if let rootIdentity { walk(rootIdentity) }
        if let prior {
            for retained in prior.descendants where retained.pid != rootPID {
                guard identityStillMatches(retained) else { continue }
                if visited.insert(retained.pid).inserted {
                    walk(retained)
                    leafFirst.append(retained)
                } else {
                    // It was reached from the live root, but may have forked
                    // after that traversal. Scan it once more before escalation.
                    walk(retained)
                }
            }
        }
        return ProcessTreeSnapshot(
            rootPID: rootPID,
            rootIdentity: rootIdentity,
            descendants: leafFirst
        )
        #else
        _ = prior
        return ProcessTreeSnapshot(
            rootPID: rootPID, rootIdentity: nil, descendants: []
        )
        #endif
    }

    /// Signals the verified leaf-first tree, then the process group, then the
    /// direct PID. The redundant paths are intentional; process start identity
    /// is revalidated immediately before every individual/group signal.
    public static func signal(_ snapshot: ProcessTreeSnapshot, signal: Int32) {
        #if canImport(Darwin)
        for identity in snapshot.descendants where identityStillMatches(identity) {
            _ = kill(identity.pid, signal)
        }
        guard let root = snapshot.rootIdentity, identityStillMatches(root) else { return }
        _ = killpg(root.pid, signal)
        // Revalidate after killpg as well: a group signal may have terminated
        // the root before this direct-PID fallback executes.
        if identityStillMatches(root) {
            _ = kill(root.pid, signal)
        }
        #else
        _ = snapshot
        _ = signal
        #endif
    }

    /// Stops a verified tree before the final kill, then rescans while the
    /// root and all already-observed descendants are unable to fork. This
    /// closes the scan-vs-fork race present in a single leaf-first SIGKILL:
    /// a shell can create a new background process after the snapshot but
    /// before its own signal, allowing that child to be reparented and escape.
    ///
    /// The returned snapshot retains every identity observed before and after
    /// quiescence so callers can verify settlement without trusting naked PIDs.
    @discardableResult
    public static func quiesceAndKill(_ snapshot: ProcessTreeSnapshot) -> ProcessTreeSnapshot {
        #if canImport(Darwin)
        signal(snapshot, signal: SIGSTOP)
        let frozen = self.snapshot(rootPID: snapshot.rootPID, retaining: snapshot)
        signal(frozen, signal: SIGKILL)
        return frozen
        #else
        return snapshot
        #endif
    }

    /// True while any previously observed descendant with the same start
    /// identity remains alive.
    public static func hasLiveDescendant(in snapshot: ProcessTreeSnapshot) -> Bool {
        #if canImport(Darwin)
        snapshot.descendants.contains(where: identityStillMatches)
        #else
        _ = snapshot
        return false
        #endif
    }

    #if canImport(Darwin)
    private static func currentIdentity(for pid: Int32) -> ProcessTreeIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard read == expected, Int32(bitPattern: info.pbi_pid) == pid else { return nil }
        return ProcessTreeIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func identityStillMatches(_ identity: ProcessTreeIdentity?) -> Bool {
        guard let identity else { return false }
        return currentIdentity(for: identity.pid) == identity
    }

    private static func immediateChildren(of parent: Int32) -> [Int32] {
        var capacity = 16
        while capacity <= 16_384 {
            var values = [pid_t](repeating: 0, count: capacity)
            let count = proc_listchildpids(
                parent,
                &values,
                Int32(values.count * MemoryLayout<pid_t>.stride)
            )
            guard count > 0 else { return [] }
            let childCount = Int(count)
            if childCount < capacity {
                return Array(values.prefix(childCount))
            }
            capacity *= 2
        }
        return []
    }
    #endif
}

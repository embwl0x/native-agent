import Darwin
import Foundation

// Blueprint: | `ManagedProcess.swift` | `ManagedProcess` starts one checked process group before exec, including descriptor-pinned cwd/inheritance, owns optional capture deadlines, retains its waitable leader through group settlement, and reports incomplete termination separately from exit; `OwnedProcessGroup` is the one group-signal owner shared with ACP |

/// A child whose process group is established by posix_spawn, before any child
/// code runs. The waitable leader reserves the PID/PGID until settlement ends.
public final class ManagedProcess: @unchecked Sendable {
    /// These are the two process QoS classes accepted by Darwin's spawn API.
    public enum Priority: Sendable, Equatable { case utility, background }
    public var executableURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    /// Borrowed until run returns; fchdir binds launch to this verified inode.
    public var currentDirectoryDescriptor: Int32?
    public var inheritedDescriptor: (source: Int32, target: Int32)?
    public var standardInput: Any?
    public var standardOutput: Any?
    public var standardError: Any?
    public var qualityOfService: Priority?
    /// An explicit launch that hands a background app to the person may
    /// relinquish descendants on ordinary exit. Stop always closes the group.
    public var reapDescendantsOnExit = true
    public var terminationHandler: (@Sendable (ManagedProcess) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    private struct State {
        var group: OwnedProcessGroup?
        var exited = false
        var announced = false
        var status: Int32 = -1
        var deadline: DispatchSourceTimer?
        var timedOut = false
        var handler: (@Sendable (ManagedProcess) -> Void)?
    }
    private let state = NSLockedState(State())
    private let finished = DispatchGroup()

    public init() {}
    public var processIdentifier: Int32 { state.withLock { $0.group?.pid ?? 0 } }
    public var isRunning: Bool { state.withLock { $0.group != nil && !$0.exited } }
    public var terminationStatus: Int32 { terminationError == nil ? state.withLock { $0.status } : -1 }
    public var terminationError: String? { state.withLock { $0.group }?.failure }
    public var timedOut: Bool { state.withLock { $0.timedOut } }
    /// The original lease survives PID reuse; cancellation never reacquires a
    /// different process's authority from its numeric PID.
    public var groupSnapshot: ProcessTreeSnapshot {
        let group = state.withLock { $0.group }
        return ProcessTreeSnapshot(rootPID: group?.pid ?? 0, rootIdentity: nil,
            descendants: [], groupOwnerID: group?.identity)
    }

    public func run(timeout: TimeInterval? = nil) throws {
        guard let executableURL else { throw POSIXError(.EINVAL) }
        if let timeout, !timeout.isFinite || timeout <= 0 { throw POSIXError(.EINVAL) }
        guard currentDirectoryDescriptor == nil || currentDirectoryURL == nil else { throw POSIXError(.EINVAL) }
        guard state.withLock({ $0.group == nil }) else { throw POSIXError(.EALREADY) }
        let group = try OwnedProcessGroup.spawn(executable: executableURL.path,
            arguments: arguments ?? [], directory: currentDirectoryURL,
            environment: environment ?? ProcessInfo.processInfo.environment,
            input: standardInput, output: standardOutput, errors: standardError,
            qualityOfService: qualityOfService, directoryDescriptor: currentDirectoryDescriptor,
            inheritedDescriptor: inheritedDescriptor)
        finished.enter()
        state.withLock { $0.group = group }
        group.onFailure = { [weak self] in self?.announce() }
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.expire() }
            state.withLock { $0.deadline = timer }
            timer.resume()
        }
        // The parent must not retain the child's side of a pipe: otherwise
        // physical exit can never produce EOF for the existing capture owner.
        var closed = Set<ObjectIdentifier>()
        for (value, isInput) in [(standardInput, true), (standardOutput, false), (standardError, false)] {
            guard let pipe = value as? Pipe else { continue }
            let handle = isInput ? pipe.fileHandleForReading : pipe.fileHandleForWriting
            guard closed.insert(ObjectIdentifier(handle)).inserted else { continue }
            do { try handle.close() }
            catch {
                // A capture setup failure cannot retire its only deadline while
                // leaving the launched effect running. Close this same lease.
                if group.send(SIGSTOP), group.send(SIGKILL) { group.observeStop() }
                group.recordFailure("The parent's child-side pipe could not close after spawn: \(error.localizedDescription). The process launched; effects are unknown.")
            }
        }
        let reapDescendants = reapDescendantsOnExit
        DispatchQueue.global(qos: .utility).async { [self, group] in
            var info = siginfo_t()
            var result: Int32
            var stopped = false
            // Darwin's waitid also answers WEXITED for a stopped child and WNOWAIT repeats it; end and expiry
            // stop the group before the kill. A stop is not an exit: look again until the leader is a zombie.
            repeat {
                result = waitid(P_PID, id_t(group.pid), &info, WEXITED | WNOWAIT)
                stopped = result == 0 && (info.si_code == CLD_STOPPED || info.si_code == CLD_TRAPPED)
                if stopped { Thread.sleep(forTimeInterval: 0.005) }
            } while stopped || (result == -1 && errno == EINTR)
            if result == -1 {
                group.recordFailure("Child exit observation failed: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)")
                announce()
                return // The owner is retained; unavailable observation cannot permit reaping or another PID signal.
            }
            state.withLock { $0.exited = true; $0.status = info.si_status }
            let settled = (!reapDescendants && !group.terminationRequested) || group.closeExitedGroup()
            if settled { group.reapExitedLeader() }
            announce()
        }
    }

    /// Joins the owner's terminal observation, which can explicitly report an
    /// incomplete stop. A failed signal never pretends that the child exited.
    public func waitForSettlement() { finished.wait() }

    private func expire() {
        let group = state.withLock { state -> OwnedProcessGroup? in
            guard !state.announced, let group = state.group else { return nil }
            state.timedOut = true
            return group
        }
        // The lease itself serializes signals against reaping. Call outside
        // the state lock: signal failures announce through this process owner.
        if let group, group.send(SIGSTOP), group.send(SIGKILL) { group.observeStop() }
    }

    private func announce() {
        let (first, handler): (Bool, (@Sendable (ManagedProcess) -> Void)?) = state.withLock {
            guard !$0.announced else { return (false, nil) }
            $0.announced = true
            $0.deadline?.cancel()
            $0.deadline = nil
            return (true, $0.handler)
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            finished.leave()
            handler?(self)
        }
    }
}

/// Internal locking is independent of callers' actors and callbacks.
private final class NSLockedState<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

/// A PGID is signalable only while this owner still holds its unreaped child.
/// No tree or root-PID signal substitutes for a failed group operation.
public final class OwnedProcessGroup: @unchecked Sendable {
    public let pid: Int32
    public let identity = UUID()
    private let lock = NSRecursiveLock()
    private var reaped = false
    private var signalled = false
    private var stopObservationStarted = false
    private var error: String?
    public var onFailure: (@Sendable () -> Void)?
    private static let registry = NSLockedState<[Int32: OwnedProcessGroup]>([:])
    public var failure: String? { lock.withLock { error } }
    public var terminationRequested: Bool { lock.withLock { signalled } }
    private init(pid: Int32) { self.pid = pid }
    public static func owner(_ pid: Int32) -> OwnedProcessGroup? { registry.withLock { $0[pid] } }

    public static func spawn(executable: String, arguments: [String], directory: URL?,
                             environment: [String: String], input: Any?, output: Any?, errors: Any?,
                             qualityOfService: ManagedProcess.Priority? = nil,
                             directoryDescriptor: Int32? = nil,
                             inheritedDescriptor: (source: Int32, target: Int32)? = nil) throws -> OwnedProcessGroup {
        // C argv/env/path strings cannot carry NUL. Refuse rather than exec a
        // truncated argument or a different environment entry/path.
        guard !executable.isEmpty, !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              directory.map({ !$0.path.contains("\0") }) != false,
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=")
                  && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw POSIXError(.EINVAL) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws {
            guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        if let qualityOfService {
            let qos: qos_class_t = qualityOfService == .utility ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND
            try checked(posix_spawnattr_set_qos_class_np(&attributes, qos))
        }
        guard directory == nil || directoryDescriptor == nil else { throw POSIXError(.EINVAL) }
        if let directoryDescriptor {
            guard directoryDescriptor >= 0 else { throw POSIXError(.EBADF) }
            try checked(posix_spawn_file_actions_addfchdir(&actions, directoryDescriptor))
        }
        if let directory { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        for (value, target) in [(input, STDIN_FILENO), (output, STDOUT_FILENO), (errors, STDERR_FILENO)] {
            guard let value else {
                try checked(posix_spawn_file_actions_addinherit_np(&actions, target))
                continue
            }
            let descriptor: Int32
            if let pipe = value as? Pipe {
                descriptor = target == STDIN_FILENO ? pipe.fileHandleForReading.fileDescriptor : pipe.fileHandleForWriting.fileDescriptor
            } else if let handle = value as? FileHandle { descriptor = handle.fileDescriptor }
            else { throw POSIXError(.EINVAL) }
            // FileHandle.nullDevice has no descriptor (-1); the child gets /dev/null itself.
            if descriptor < 0, (value as? FileHandle) === FileHandle.nullDevice {
                try checked(posix_spawn_file_actions_addopen(&actions, target, "/dev/null",
                    target == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
                continue
            }
            try checked(posix_spawn_file_actions_adddup2(&actions, descriptor, target))
        }
        // dup removes CLOEXEC on the verified source. The shared spawn owner
        // makes the requested child FD inheritable and closes the parent's dup.
        var inherited: Int32 = -1
        defer { if inherited >= 0 { _ = Darwin.close(inherited) } }
        if let inheritedDescriptor {
            guard inheritedDescriptor.source >= 0, inheritedDescriptor.target > STDERR_FILENO,
                  inheritedDescriptor.target < Int32.max else { throw POSIXError(.EINVAL) }
            inherited = fcntl(inheritedDescriptor.source, F_DUPFD, inheritedDescriptor.target + 1)
            guard inherited >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try checked(posix_spawn_file_actions_adddup2(&actions, inherited, inheritedDescriptor.target))
        }
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        let args = argv + [nil], env = envp + [nil]
        var pid: pid_t = 0
        let result = args.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try checked(result)
        let owner = OwnedProcessGroup(pid: pid)
        registry.withLock { $0[pid] = owner }
        return owner
    }

    @discardableResult public func send(_ signal: Int32) -> Bool {
        let result: Bool = lock.withLock {
            guard !reaped else { return true }
            if signal != 0 { signalled = true }
            guard killpg(pid, signal) != 0 else { return true }
            let refusal = errno
            if refusal == ESRCH { return true }
            // Darwin answers EPERM, not ESRCH, when every member has exited and the
            // waitable leader is held unreaped: nothing is left to signal. A live
            // member this owner may not signal is a real failure.
            if refusal == EPERM {
                do { if try !hasLiveGroupMembers() { return true } }
                catch {
                    recordFailure("Process group \(pid) termination could not be verified: \(error.localizedDescription). The waitable leader remains owned.")
                    return false
                }
            }
            recordFailure("Process group \(pid) signal \(signal) failed: \(POSIXError(POSIXErrorCode(rawValue: refusal) ?? .EIO).localizedDescription). Termination is incomplete; do not repeat its work.")
            return false
        }
        return result
    }

    public func recordFailure(_ detail: String) {
        lock.withLock { if error == nil { error = detail } }
        onFailure?()
    }

    /// A bounded checked group observation must establish that every remaining
    /// member is exited before the caller may release its waitable leader.
    /// Unavailable inspection or a surviving member retains the leader/PGID.
    public func closeExitedGroup() -> Bool {
        guard send(SIGKILL) else { return false }
        return verifyStoppedGroup()
    }

    /// SIGKILL itself is not terminal proof. This bounded observation also
    /// covers a leader that never reaches waitid's exited state.
    public func observeStop() {
        let start = lock.withLock { () -> Bool in
            guard !stopObservationStarted, !reaped else { return false }
            stopObservationStarted = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in _ = verifyStoppedGroup() }
    }

    private func verifyStoppedGroup() -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(500)
        do {
            while true {
                let settled = try lock.withLock { () throws -> Bool in
                    if reaped { return true }
                    return try !hasLiveGroupMembers()
                }
                if settled { return true }
                guard DispatchTime.now() < deadline else {
                    recordFailure("Process group \(pid) still has live members after SIGKILL. Termination is incomplete; the waitable leader remains owned.")
                    return false
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        } catch {
            recordFailure("Process group \(pid) termination could not be verified: \(error.localizedDescription). The waitable leader remains owned.")
            return false
        }
    }

    private func hasLiveGroupMembers() throws -> Bool {
        var capacity = 16
        while capacity <= 16_384 {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let used = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            guard used > 0, used % Int32(MemoryLayout<pid_t>.stride) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if Int(used) >= pids.count * MemoryLayout<pid_t>.stride { capacity *= 2; continue }
            for member in pids.prefix(Int(used) / MemoryLayout<pid_t>.stride) where member > 0 {
                var info = proc_bsdinfo()
                let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
                errno = 0
                let read = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, expected)
                if read == 0, errno == ESRCH { continue }
                guard read == expected else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard info.pbi_pgid == UInt32(pid) else { continue }
                // BSD's SZOMB is the kernel's exited, not-yet-reaped state.
                if info.pbi_status != UInt32(SZOMB) { return true }
            }
            return false
        }
        throw POSIXError(.EOVERFLOW)
    }

    /// Call only after waitid established exit, or after the ACP owner closed
    /// its group. The one leader stays waitable until all group signals end.
    public func reapExitedLeader() {
        lock.withLock {
            guard !reaped else { return }
            var info = siginfo_t()
            var observed: Int32
            // A closed group's leader is exiting: sample until it is waitable, as the group closure samples (5ms, 500ms).
            let deadline = ContinuousClock.now + .milliseconds(500)
            while true {
                repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) }
                while observed == -1 && errno == EINTR
                if observed != 0 || info.si_pid == pid || ContinuousClock.now >= deadline { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard observed == 0, info.si_pid == pid else {
                recordFailure("Process group leader \(pid) has no checked exit observation. Termination remains incomplete; it was not reaped.")
                return
            }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            guard result == pid else {
                recordFailure("Process group leader \(pid) could not be reaped: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)")
                return
            }
            reaped = true
            Self.registry.withLock { $0[pid] = nil }
        }
    }
}

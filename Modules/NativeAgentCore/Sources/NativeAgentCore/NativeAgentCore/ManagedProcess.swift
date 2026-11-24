import Synchronization
import Darwin
import Foundation
@unsafe @preconcurrency import Dispatch

// Blueprint: | `ManagedProcess.swift` | `ManagedProcess`, `OwnedProcessGroup`: checked process groups and settlement |

/// A child whose process group is established by posix_spawn, before any child code runs. The waitable leader reserves the PID/PGID until settlement ends.
// The launch configuration accepts Any pipe and file-handle values for standard I/O.
public final class ManagedProcess: @unchecked Sendable {
    /// Child processes receive user identity, locale, executable lookup and Docker daemon selectors, never app credentials.
    public static func agentEnvironment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let names: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "PATH", "DOCKER_HOST", "DOCKER_CONTEXT"]
        return source.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") }
    }

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
    /// An explicit launch that hands a background app to the person may relinquish descendants on ordinary exit. Stop always closes the group.
    public var reapDescendantsOnExit = true
    public var terminationHandler: (@Sendable (ManagedProcess) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }
    /// The watch of the call that waits on this process: launch attaches the process as what the call waits on, its output is the call's
    /// life (the capture owner reports it), and exit detaches it. A running process is alive however quiet it is.
    public var life: TurnDeadline? {
        get { state.withLock { $0.life } }
        set { state.withLock { $0.life = newValue } }
    }
    /// What a call waits on when it waits on this running process; nil before launch.
    public func callLife(what: String) -> CallLife? { state.withLock { $0.group }?.callLife(what: what) }

    private struct State {
        var group: OwnedProcessGroup?
        var exited = false
        var announced = false
        var status: Int32 = -1
        var deadline: DispatchSourceTimer?
        var timedOut = false
        var handler: (@Sendable (ManagedProcess) -> Void)?
        var life: TurnDeadline?
        var lifeID: UUID?
    }
    private let state = Mutex(State())
    private let finished = DispatchGroup()

    public init() {}
    public var processIdentifier: Int32 { state.withLock { $0.group?.pid ?? 0 } }
    public var isRunning: Bool { state.withLock { $0.group != nil && !$0.exited } }
    public var terminationStatus: Int32 { terminationError == nil ? state.withLock { $0.status } : -1 }
    public var terminationError: String? { state.withLock { $0.group }?.failure }
    public var timedOut: Bool { state.withLock { $0.timedOut } }
    /// The original lease survives PID reuse; cancellation never reacquires a different process's authority from its numeric PID.
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
            environment: environment ?? Self.agentEnvironment(),
            input: standardInput, output: standardOutput, errors: standardError,
            qualityOfService: qualityOfService, directoryDescriptor: currentDirectoryDescriptor,
            inheritedDescriptor: inheritedDescriptor)
        finished.enter()
        state.withLock { $0.group = group }
        if let life = self.life {
            let id = life.attach(group.callLife(what: "the process \(executableURL.lastPathComponent)"))
            state.withLock { $0.lifeID = id }
        }
        group.onFailure = { [weak self] in self?.announce() }
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.expire() }
            state.withLock { $0.deadline = timer }
            timer.resume()
        }
        // The parent must not retain the child's side of a pipe: otherwise physical exit can never produce EOF for the existing capture owner.
        var closed = Set<ObjectIdentifier>()
        for (value, isInput) in [(standardInput, true), (standardOutput, false), (standardError, false)] {
            guard let pipe = value as? Pipe else { continue }
            let handle = isInput ? pipe.fileHandleForReading : pipe.fileHandleForWriting
            guard closed.insert(ObjectIdentifier(handle)).inserted else { continue }
            do { try handle.close() }
            catch {
                // A capture setup failure cannot retire its only deadline while leaving the launched effect running. Close this same lease.
                if group.send(SIGSTOP), group.send(SIGKILL) { group.observeStop() }
                group.recordFailure("""
                    The parent's child-side pipe could not close after spawn: \(error.localizedDescription). The process launched; effects are unknown.
                    """)
            }
        }
        let reapDescendants = reapDescendantsOnExit
        DispatchQueue.global(qos: .utility).async { [self, group] in
            do { try ProcessExitObservation.wait(pid: group.pid) }
            catch {
                group.recordFailure("Child exit observation failed: \(error.localizedDescription)")
                announce()
                return
            }
            var info = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(group.pid), &info, WEXITED | WNOWAIT)
            } while result == -1 && errno == EINTR
            guard result == 0 else {
                group.recordFailure("Child exit read failed: \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)")
                announce()
                return
            }
            guard info.si_pid == group.pid,
                  info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED else {
                group.recordFailure("Child exit state could not be read after its kernel exit event. The waitable leader remains owned.")
                announce()
                return
            }
            state.withLock { $0.exited = true; $0.status = info.si_status }
            let settled = (!reapDescendants && !group.terminationRequested) || group.closeExitedGroup()
            if settled { group.reapExitedLeader() }
            announce()
        }
    }

    /// Joins the owner's terminal observation, which can explicitly report an incomplete stop. A failed signal never pretends that the child exited.
    public func waitForSettlement() { finished.wait() }

    private func expire() {
        let group = state.withLock { state -> OwnedProcessGroup? in
            guard !state.announced, let group = state.group else { return nil }
            state.timedOut = true
            return group
        }
        // The lease itself serializes signals against reaping. Call outside the state lock: signal failures announce through this process owner.
        if let group, group.send(SIGSTOP), group.send(SIGKILL) { group.observeStop() }
    }

    private func announce() {
        let (first, handler, watched): (Bool, (@Sendable (ManagedProcess) -> Void)?, (TurnDeadline, UUID)?) = state.withLock {
            guard !$0.announced else { return (false, nil, nil) }
            $0.announced = true
            $0.deadline?.cancel()
            $0.deadline = nil
            var watched: (TurnDeadline, UUID)?
            if let life = $0.life, let id = $0.lifeID { watched = (life, id) }
            $0.lifeID = nil
            return (true, $0.handler, watched)
        }
        guard first else { return }
        if case let (life, id)? = watched { life.detach(id) }
        DispatchQueue.global(qos: .utility).async { [self] in
            finished.leave()
            handler?(self)
        }
    }
}

package struct OwnedFD: ~Copyable, Sendable {
    package let raw: Int32
    package init?(raw: Int32) {
        guard raw >= 0 else { return nil }
        self.raw = raw
    }
    deinit { _ = Darwin.close(raw) }
}

/// Register before checking identity so an exit between observation and parking cannot be lost.
private enum ProcessExitObservation {
    static func wait(pid: pid_t, isCurrent: () throws -> Bool = { true }) throws {
        guard pid > 0 else { throw POSIXError(.EINVAL) }
        guard let descriptor = OwnedFD(raw: kqueue()) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fcntl(descriptor.raw, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var registration = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                                  flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT | EV_RECEIPT),
                                  fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        let registered = kevent(descriptor.raw, &registration, 1, &event, 1, nil)
        guard registered >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard registered == 1, event.flags & UInt16(EV_ERROR) != 0 else {
            throw NSError(domain: "NativeAgent.ProcessExit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The kernel did not acknowledge the process-exit observation."])
        }
        if event.data == Int(ESRCH) { return }
        guard event.data == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: event.data) }
        guard try isCurrent() else { return }
        var observed: Int32
        repeat { observed = kevent(descriptor.raw, nil, 0, &event, 1, nil) }
        while observed == -1 && errno == EINTR
        guard observed >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard observed == 1, event.filter == Int16(EVFILT_PROC), event.ident == UInt(pid),
              event.fflags & UInt32(NOTE_EXIT) != 0, event.flags & UInt16(EV_ERROR) == 0 else {
            throw NSError(domain: "NativeAgent.ProcessExit", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The kernel returned an invalid process-exit event."])
        }
    }
}

/// A PGID is signalable only while this owner still holds its unreaped child. No tree or root-PID signal substitutes for a failed group operation.
public final class OwnedProcessGroup: Sendable {
    public let pid: Int32
    public let identity = UUID()
    private struct UnreapedLeader: ~Copyable, Sendable {
        let pid: pid_t
        func signal(_ value: Int32) -> Int32 { killpg(pid, value) }
        consuming func reap(error: inout Int32) -> Self? {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            if result == pid { return nil }
            error = errno
            return self
        }
    }
    private struct State: ~Copyable {
        var leader: UnreapedLeader?
        var signalled = false
        var stopObservationStarted = false
        var error: String?
        var onFailure: (@Sendable () -> Void)?
    }
    private let state: Mutex<State>
    public var onFailure: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFailure } }
        set { state.withLock { $0.onFailure = newValue } }
    }
    private static let registry = Mutex<[Int32: OwnedProcessGroup]>([:])
    public var failure: String? { state.withLock { $0.error } }
    public var terminationRequested: Bool { state.withLock { $0.signalled } }
    private init(pid: Int32) { self.pid = pid; state = Mutex(State(leader: UnreapedLeader(pid: pid))) }
    public static func owner(_ pid: Int32) -> OwnedProcessGroup? { registry.withLock { $0[pid] } }

    public static func spawn(executable: String, arguments: [String], directory: URL?,
                             environment: [String: String], input: Any?, output: Any?, errors: Any?,
                             qualityOfService: ManagedProcess.Priority? = nil,
                             directoryDescriptor: Int32? = nil,
                             inheritedDescriptor: (source: Int32, target: Int32)? = nil) throws -> OwnedProcessGroup {
        // C argv/env/path strings cannot carry NUL. Refuse rather than exec a truncated argument or a different environment entry/path.
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
        try checked(unsafe posix_spawn_file_actions_init(&actions))
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        try checked(unsafe posix_spawnattr_init(&attributes))
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        try checked(unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(unsafe posix_spawnattr_setpgroup(&attributes, 0))
        if let qualityOfService {
            let qos: qos_class_t = qualityOfService == .utility ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND
            try checked(unsafe posix_spawnattr_set_qos_class_np(&attributes, qos))
        }
        guard directory == nil || directoryDescriptor == nil else { throw POSIXError(.EINVAL) }
        if let directoryDescriptor {
            guard directoryDescriptor >= 0 else { throw POSIXError(.EBADF) }
            try checked(unsafe posix_spawn_file_actions_addfchdir(&actions, directoryDescriptor))
        }
        if let directory { try checked(unsafe posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        for (value, target) in [(input, STDIN_FILENO), (output, STDOUT_FILENO), (errors, STDERR_FILENO)] {
            guard let value else {
                try checked(unsafe posix_spawn_file_actions_addinherit_np(&actions, target))
                continue
            }
            let descriptor: Int32
            if let pipe = value as? Pipe {
                descriptor = target == STDIN_FILENO ? pipe.fileHandleForReading.fileDescriptor : pipe.fileHandleForWriting.fileDescriptor
            } else if let handle = value as? FileHandle { descriptor = handle.fileDescriptor }
            else { throw POSIXError(.EINVAL) }
            // FileHandle.nullDevice has no descriptor (-1); the child gets /dev/null itself.
            if descriptor < 0, (value as? FileHandle) === FileHandle.nullDevice {
                try checked(unsafe posix_spawn_file_actions_addopen(&actions, target, "/dev/null",
                    target == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
                continue
            }
            try checked(unsafe posix_spawn_file_actions_adddup2(&actions, descriptor, target))
        }
        // dup removes CLOEXEC on the verified source. The shared spawn owner makes the requested child FD inheritable and closes the parent's dup.
        var inherited: Int32 = -1
        defer { if inherited >= 0 { _ = Darwin.close(inherited) } }
        if let inheritedDescriptor {
            guard inheritedDescriptor.source >= 0, inheritedDescriptor.target > STDERR_FILENO,
                  inheritedDescriptor.target < Int32.max else { throw POSIXError(.EINVAL) }
            inherited = fcntl(inheritedDescriptor.source, F_DUPFD, inheritedDescriptor.target + 1)
            guard inherited >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try checked(unsafe posix_spawn_file_actions_adddup2(&actions, inherited, inheritedDescriptor.target))
        }
        let argv = ([executable] + arguments).map { unsafe strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { unsafe strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { unsafe free($0) }; envp.forEach { unsafe free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        let args = argv + [nil], env = envp + [nil]
        var pid: pid_t = 0
        let result = args.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { env in
                guard let arguments = unsafe args.baseAddress, let environment = unsafe env.baseAddress else { return EINVAL }
                return unsafe posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
            }
        }
        try checked(result)
        let owner = OwnedProcessGroup(pid: pid)
        registry.withLock { $0[pid] = owner }
        return owner
    }

    @discardableResult public func send(_ signal: Int32) -> Bool {
        checked { state in
            guard let result = state.leader?.signal(signal) else { return nil }
            if signal != 0 { state.signalled = true }
            guard result != 0 else { return nil }
            let refusal = errno
            if refusal == ESRCH { return nil }
            // Darwin answers EPERM, not ESRCH, when every member has exited and the waitable leader is held unreaped: nothing is left to signal. A live member
            // this owner may not signal is a real failure.
            if refusal == EPERM {
                do { if try !hasLiveGroupMembers() { return nil } }
                catch {
                    return "Process group \(pid) termination could not be verified: \(error.localizedDescription). The waitable leader remains owned."
                }
            }
            return """
                Process group \(pid) signal \(signal) failed: \(POSIXError(POSIXErrorCode(rawValue: refusal) ?? .EIO).localizedDescription). Termination is \
                incomplete; do not repeat its work.
                """
        }
    }

    @discardableResult private func checked(_ operation: (inout State) -> String?) -> Bool {
        let (ok, announce) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard let detail = operation(&state) else { return (true, nil) }
            if state.error == nil { state.error = detail }
            return (false, state.onFailure)
        }
        announce?()
        return ok
    }

    public func recordFailure(_ detail: String) { checked { _ in detail } }

    /// Every member must exit before the caller may release its waitable leader and PGID.
    public func closeExitedGroup() -> Bool {
        guard send(SIGKILL) else { return false }
        return verifyStoppedGroup()
    }

    /// SIGKILL is a request; kernel exit events establish that the group stopped.
    public func observeStop() {
        let start = state.withLock { state in
            guard !state.stopObservationStarted, state.leader != nil else { return false }
            state.stopObservationStarted = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in _ = verifyStoppedGroup() }
    }

    private func verifyStoppedGroup() -> Bool {
        do {
            while true {
                let members = try state.withLock { state -> [GroupMember] in
                    if state.leader == nil { return [] }
                    return try liveGroupMembers()
                }
                if members.isEmpty { return true }
                for member in members {
                    try ProcessExitObservation.wait(pid: member.pid) {
                        try self.isCurrent(member)
                    }
                }
            }
        } catch {
            recordFailure("Process group \(pid) termination could not be verified: \(error.localizedDescription). The waitable leader remains owned.")
            return false
        }
    }

    /// What a call waits on when it waits on this group: alive while any member runs, quiet or busy; dead only when the whole group has exited.
    public func callLife(what: String) -> CallLife {
        CallLife(what: what) { [self] in
            state.withLock { state -> CallLife.Answer in
                guard state.leader != nil else { return .dead("\(what) has exited") }
                do {
                    return try liveGroupMembers().isEmpty ? .dead("\(what) has exited") : .alive
                } catch {
                    return .unknown
                }
            }
        }
    }

    private func hasLiveGroupMembers() throws(POSIXError) -> Bool {
        try !liveGroupMembers().isEmpty
    }

    private struct GroupMember {
        let pid: pid_t
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
    }

    private func isCurrent(_ member: GroupMember) throws(NSError) -> Bool {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let read = unsafe proc_pidinfo(member.pid, PROC_PIDTBSDINFO, 0, &info, expected)
        if read == 0, errno == ESRCH { return false }
        guard read == expected else {
            throw NSError(domain: "NativeAgent.ProcessExit", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Could not inspect process \(member.pid): proc_pidinfo returned \(read) of \(expected) bytes (errno \(errno))."])
        }
        return info.pbi_pgid == UInt32(pid) && info.pbi_status != UInt32(SZOMB)
            && info.pbi_start_tvsec == member.startedSeconds && info.pbi_start_tvusec == member.startedMicroseconds
    }

    private func liveGroupMembers() throws(POSIXError) -> [GroupMember] {
        var capacity = 16
        while capacity <= 16_384 {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let used = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            guard used > 0, used % Int32(MemoryLayout<pid_t>.stride) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if Int(used) >= pids.count * MemoryLayout<pid_t>.stride { capacity *= 2; continue }
            var members: [GroupMember] = []
            for member in pids.prefix(Int(used) / MemoryLayout<pid_t>.stride) where member > 0 {
                var info = proc_bsdinfo()
                let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
                errno = 0
                let read = unsafe proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, expected)
                if read == 0, errno == ESRCH { continue }
                guard read == expected else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard info.pbi_pgid == UInt32(pid) else { continue }
                if info.pbi_status != UInt32(SZOMB) {
                    members.append(GroupMember(pid: member, startedSeconds: info.pbi_start_tvsec,
                                               startedMicroseconds: info.pbi_start_tvusec))
                }
            }
            return members
        }
        throw POSIXError(.EOVERFLOW)
    }

    /// Call only after waitid established exit, or after the ACP owner closed its group. The one leader stays waitable until all group signals end.
    public func reapExitedLeader() {
        do { try ProcessExitObservation.wait(pid: pid) { self.state.withLock { $0.leader != nil } } }
        catch {
            recordFailure("Process group leader \(pid) exit could not be observed: \(error.localizedDescription). It remains owned.")
            return
        }
        checked { state in
            guard state.leader != nil else { return nil }
            var info = siginfo_t()
            var observed: Int32
            repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) }
            while observed == -1 && errno == EINTR
            guard observed == 0 else {
                let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                return "Process group leader \(pid) exit read failed: \(cause). It remains owned."
            }
            guard info.si_pid == pid,
                  info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED else {
                return "Process group leader \(pid) has no checked exit observation. Termination remains incomplete; it was not reaped."
            }
            var code: Int32 = 0
            let owned = state.leader.take()!
            state.leader = owned.reap(error: &code)
            guard state.leader == nil else {
                let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
                return "Process group leader \(pid) could not be reaped: \(cause)"
            }
            Self.registry.withLock { if $0[pid] === self { $0[pid] = nil } }
            return nil
        }
    }
}

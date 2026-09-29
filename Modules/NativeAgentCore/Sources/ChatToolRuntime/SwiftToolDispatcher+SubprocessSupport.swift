import Foundation
import NativeAgentCore

extension SwiftToolDispatcher {
    /// Identical bounded pipe capture for both synchronous builder invokes.
    /// Final drain must not wait for a descendant that inherited a write FD.
    final class InvokeOutputCapture: @unchecked Sendable {
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let stdoutBuffer = BoundedBuffer(cap: 512 * 1024)
        private let stderrBuffer = BoundedBuffer(cap: 128 * 1024)

        init(process: Process) {
            process.standardOutput = stdout
            process.standardError = stderr
            for (pipe, buffer) in [(stdout, stdoutBuffer), (stderr, stderrBuffer)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        buffer.append(data)
                    }
                }
            }
        }

        func stopReading() {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        func finish() -> (stdout: String, stderr: String) {
            stopReading()
            SwiftToolDispatcher.drainPipeNonBlocking(stdout.fileHandleForReading, into: stdoutBuffer)
            SwiftToolDispatcher.drainPipeNonBlocking(stderr.fileHandleForReading, into: stderrBuffer)
            var stdoutText = String(decoding: stdoutBuffer.data, as: UTF8.self)
            var stderrText = String(decoding: stderrBuffer.data, as: UTF8.self)
            if stdoutBuffer.truncated {
                stdoutText += "\n[stdout truncated]"
            }
            if stderrBuffer.truncated {
                stderrText += "\n[stderr truncated]"
            }
            return (stdoutText, stderrText)
        }
    }

    /// Launch and cancellation share a lock so Stop cannot miss a child that
    /// is between admission and Process.run(). Foundation reaps the direct
    /// child and delivers its termination handler after the tree is killed.
    final class InvokeCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var tree: ProcessTreeSnapshot?

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func launch(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(process.processIdentifier)
            tree = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let launchedTree = tree
            lock.unlock()
            if let launchedTree {
                let current = ProcessTreeReaper.snapshot(
                    rootPID: launchedTree.rootPID, retaining: launchedTree
                )
                _ = ProcessTreeReaper.quiesceAndKill(current)
            }
        }
    }

    /// Single-fire latch for `withCheckedContinuation` paths where multiple
    /// callbacks could race to resume the continuation (subprocess
    /// terminationHandler + timeout watchdog + spawn-error early-return).
    /// Resuming a continuation more than once is undefined behavior +
    /// triggers a fatalError in DEBUG.
    package final class ResumeGuard: @unchecked Sendable {
        package init() {}
        private var fired = false
        private let lock = NSLock()
        package func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    static func armSubprocessTimeout(
        process: Process,
        timeoutSeconds: Int,
        onTimeout: (@Sendable () -> Void)? = nil
    ) {
        let childPid = process.processIdentifier
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(childPid)
        let launchedTree = ProcessTreeReaper.snapshot(rootPID: childPid)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
            let timeoutTree = ProcessTreeReaper.snapshot(rootPID: childPid, retaining: launchedTree)
            if process.isRunning || ProcessTreeReaper.hasLiveDescendant(in: timeoutTree) {
                // Mark BEFORE killing so the terminationHandler can tell a
                // watchdog timeout (exit 143/SIGTERM) apart from a crash or an
                // external kill — Agent hit exactly this ambiguity (2026-06-09).
                onTimeout?()
                ProcessTreeReaper.signal(timeoutTree, signal: SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                    // Re-scan even if the direct child already exited: a
                    // background descendant may have escaped the group and
                    // inherited its pipe descriptors.
                    let survivorTree = ProcessTreeReaper.snapshot(
                        rootPID: childPid, retaining: timeoutTree
                    )
                    if process.isRunning || ProcessTreeReaper.hasLiveDescendant(in: survivorTree) {
                        ProcessTreeReaper.quiesceAndKill(survivorTree)
                    }
                }
            }
        }
    }

    /// agent_cancel's stop for a run this app launched: SIGINT (what a person
    /// at the terminal sends), SIGTERM 3 s later if it is still going, then the
    /// quiesced kill 2 s after that. A snapshot without a root identity
    /// reaches only the listed descendants, never the root process.
    static func interruptThenTerminate(_ tree: ProcessTreeSnapshot,
                                       stillRunning: @escaping @Sendable () -> Bool = { false }) {
        ProcessTreeReaper.signal(tree, signal: SIGINT)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let later = ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: tree)
            guard stillRunning() || ProcessTreeReaper.hasLiveDescendant(in: later) else { return }
            ProcessTreeReaper.signal(later, signal: SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                let survivors = ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: later)
                if stillRunning() || ProcessTreeReaper.hasLiveDescendant(in: survivors) {
                    ProcessTreeReaper.quiesceAndKill(survivors)
                }
            }
        }
    }

    /// SETTLE A FINISHED RUN'S PROCESS GROUP. The direct child exiting says
    /// nothing about what it backgrounded, and a stranger's command must not
    /// leave a process alive past its turn or past the temp directory it was
    /// given. TERM the verified tree, then, after the same grace the watchdog
    /// uses, KILL whatever is still there. Used by the agent-host command
    /// adapter only; the builder tools' own runs are unchanged.
    static func reapLaunchedTree(_ tree: ProcessTreeSnapshot) {
        guard ProcessTreeReaper.hasLiveDescendant(in: tree) else { return }
        ProcessTreeReaper.signal(tree, signal: SIGTERM)
        Thread.sleep(forTimeInterval: 2)
        let survivors = ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: tree)
        if ProcessTreeReaper.hasLiveDescendant(in: survivors) {
            ProcessTreeReaper.quiesceAndKill(survivors)
        }
    }

    /// The tree as it was at launch, handed from the spawn site to the
    /// termination handler. Taken while the child is alive, because once it
    /// exits its descendants are reparented and can no longer be found from it.
    final class LaunchedTreeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: ProcessTreeSnapshot?
        func set(_ value: ProcessTreeSnapshot) { lock.lock(); tree = value; lock.unlock() }
        var value: ProcessTreeSnapshot? { lock.lock(); defer { lock.unlock() }; return tree }
    }

    /// Tiny thread-safe latch — set from the timeout-watchdog thread, read from
    /// the Process terminationHandler thread (2026-06-09: lets the audit + the
    /// failure envelope distinguish watchdog-timeout from crash/external kill).
    final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // Bounded thread-safe Data accumulator for pipe drain.
    // FileHandle.readabilityHandler is `@Sendable` and fires on a private
    // queue, so the buffer must be safe to mutate from any thread.
    final class BoundedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private let cap: Int
        private var _truncated = false
        /// Each complete line as it arrives, called outside the lock.
        private let onLine: (@Sendable (String) -> Void)?
        private var pendingLine = Data()
        private var discardingLine = false
        init(cap: Int, onLine: (@Sendable (String) -> Void)? = nil) { self.cap = cap; self.onLine = onLine }
        func append(_ chunk: Data) {
            for line in store(chunk) { onLine?(line) }
        }
        /// The last line, when the output did not end with a newline.
        func finishLines() {
            lock.lock()
            let rest = pendingLine
            pendingLine = Data()
            lock.unlock()
            if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        }
        private func store(_ chunk: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            var lines: [String] = []
            if onLine != nil {
                pendingLine.append(chunk)
                while let newline = pendingLine.firstIndex(of: 0x0A) {
                    if !discardingLine, pendingLine.distance(from: pendingLine.startIndex, to: newline) <= cap {
                        lines.append(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                    }
                    pendingLine.removeSubrange(pendingLine.startIndex...newline)
                    discardingLine = false
                }
                if discardingLine || pendingLine.count > cap {
                    pendingLine.removeAll()
                    discardingLine = true
                }
            }
            if storage.count >= cap { _truncated = true; return lines }
            let room = cap - storage.count
            if chunk.count <= room {
                storage.append(chunk)
            } else {
                storage.append(chunk.prefix(room))
                _truncated = true
            }
            return lines
        }
        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        var truncated: Bool {
            lock.lock(); defer { lock.unlock() }
            return _truncated
        }
    }

    /// Head+tail preserving truncation for tool output that lands in the model's
    /// context. Build/test/shell FAILURES put the lines that matter (compiler
    /// errors, "N tests failed", exit status) at the END of the stream — a
    /// head-only `.prefix(cap)` keeps the leading progress noise and DROPS those
    /// trailing errors, blinding the agent to WHY a build failed. This keeps the
    /// first `headBudget` and last `tailBudget` characters with an explicit
    /// elision marker between, so the first (often root-cause) error AND the
    /// final summary both survive. Total kept ≈ headBudget + tailBudget.
    /// Returns (text, wasTruncated).
    static func headTailPreserve(
        _ text: String,
        headBudget: Int,
        tailBudget: Int
    ) -> (String, Bool) {
        let total = headBudget + tailBudget
        guard text.count > total else { return (text, false) }
        let head = String(text.prefix(headBudget))
        let tail = String(text.suffix(tailBudget))
        let elided = text.count - total
        let marker = "\n… [\(elided) chars elided from middle — head+tail kept so trailing build errors survive] …\n"
        return (head + marker + tail, true)
    }

    // Final pipe drain for subprocess terminationHandlers. availableData /
    // readToEnd block until EOF, and EOF requires EVERY holder of the write
    // end to close it — a backgrounded grandchild (`sh -c 'server &'`)
    // inherits the FD and keeps it open after the direct child exits, which
    // would pin the terminationHandler (and the chat turn awaiting its
    // continuation) forever. O_NONBLOCK read grabs whatever is already
    // buffered and stops at EAGAIN instead of waiting for an EOF that may
    // never come. (Audit 2026-06-09.)
    nonisolated static func drainPipeNonBlocking(_ handle: FileHandle, into buffer: BoundedBuffer) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break } // 0 = EOF, <0 = EAGAIN/error: stop
            buffer.append(Data(bytes: chunk, count: n))
        }
    }

    final class PipeDrainLoop: @unchecked Sendable {
        private let fd: Int32
        private let buffer: BoundedBuffer
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false
        private var started = false

        init(fileDescriptor: Int32, buffer: BoundedBuffer) {
            self.fd = fileDescriptor
            self.buffer = buffer
        }

        func start() {
            lock.lock()
            guard !started else {
                lock.unlock()
                return
            }
            started = true
            lock.unlock()

            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

            let thread = Thread { [self] in
                defer { done.signal() }
                var chunk = [UInt8](repeating: 0, count: 65_536)
                while true {
                    var madeProgress = false
                    while true {
                        let n = read(fd, &chunk, chunk.count)
                        if n > 0 {
                            madeProgress = true
                            buffer.append(Data(bytes: chunk, count: n))
                            continue
                        }
                        if n == 0 { return }
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        return
                    }

                    if isStopped() { return }
                    usleep(madeProgress ? 1_000 : 5_000)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stopAndWait() {
            lock.lock()
            stopped = true
            let wasStarted = started
            lock.unlock()
            if wasStarted {
                _ = done.wait(timeout: .now() + .seconds(5))
            }
        }

        private func isStopped() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

}

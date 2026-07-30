import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    /// Single-fire latch for `withCheckedContinuation` paths where multiple
    /// callbacks could race to resume the continuation (subprocess
    /// terminationHandler + timeout watchdog + spawn-error early-return).
    /// Resuming a continuation more than once is undefined behavior +
    /// triggers a fatalError in DEBUG.
    final class ResumeGuard: @unchecked Sendable {
        private var fired = false
        private let lock = NSLock()
        func tryResume() -> Bool {
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
        _ = setpgid(childPid, childPid)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
            if process.isRunning {
                // Mark BEFORE killing so the terminationHandler can tell a
                // watchdog timeout (exit 143/SIGTERM) apart from a crash or an
                // external kill — Agent hit exactly this ambiguity (2026-06-09).
                onTimeout?()
                if killpg(childPid, SIGTERM) != 0 {
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                    if process.isRunning {
                        if killpg(childPid, SIGKILL) != 0 {
                            kill(childPid, SIGKILL)
                        }
                    }
                }
            }
        }
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
        init(cap: Int) { self.cap = cap }
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if storage.count >= cap { _truncated = true; return }
            let room = cap - storage.count
            if chunk.count <= room {
                storage.append(chunk)
            } else {
                storage.append(chunk.prefix(room))
                _truncated = true
            }
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

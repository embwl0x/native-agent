import Foundation
import NativeAgentCore
// Blueprint: | `SwiftToolDispatcher+SubprocessSupport.swift` | `SubprocessWork` owns launch admission, verified process tree, timeout and physical exit; Stop freezes and kills the effect tree immediately, then `settle` releases descendants and runs the adapter's one output/audit settlement; shared bounded invoke/image pipe capture with adapter-specific limits and decoding |

extension SwiftToolDispatcher {
    /// Bounded pipe capture shared by builder and image subprocess adapters.
    /// Final drain must not wait for a descendant that inherited a write FD.
    final class InvokeOutputCapture: @unchecked Sendable {
        private let stdoutBuffer: BoundedBuffer
        private let stderrBuffer: BoundedBuffer
        private let stdoutDrain: ProcessPipeDrain
        private let stderrDrain: ProcessPipeDrain

        init(process: Process, stderrCap: Int = 128 * 1024) throws {
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = BoundedBuffer(cap: 512 * 1024)
            let stderrBuffer = BoundedBuffer(cap: stderrCap)
            self.stdoutBuffer = stdoutBuffer
            self.stderrBuffer = stderrBuffer
            process.standardOutput = stdout
            process.standardError = stderr
            let stdoutDrain = try ProcessPipeDrain(handle: stdout.fileHandleForReading) { stdoutBuffer.append($0) }
            do {
                stderrDrain = try ProcessPipeDrain(handle: stderr.fileHandleForReading) { stderrBuffer.append($0) }
            } catch {
                stdoutDrain.stopAndWait()
                throw error
            }
            self.stdoutDrain = stdoutDrain
        }

        func stopReading() {
            // Settle queued reads and their appends before any output snapshot.
            stdoutDrain.stopAndWait()
            stderrDrain.stopAndWait()
        }

        func finish(strictUTF8: Bool = false) -> (stdout: String, stderr: String) {
            stopReading()
            let decode: (Data) -> String = strictUTF8
                ? { String(data: $0, encoding: .utf8) ?? "" }
                : { String(decoding: $0, as: UTF8.self) }
            var stdoutText = decode(stdoutBuffer.data)
            var stderrText = decode(stderrBuffer.data)
            if stdoutBuffer.truncated {
                stdoutText += "\n[stdout truncated]"
            }
            if stderrBuffer.truncated {
                stderrText += "\n[stderr truncated]"
            }
            return (stdoutText, stderrText)
        }
    }

    /// One effect owner, one settlement. Launch and Stop share admission;
    /// Stop freezes the tree before killing it, leaving no grace in which it
    /// can fork work. Only physical exit releases the waiter to settlement.
    final class SubprocessWork: @unchecked Sendable {
        struct Exit: Sendable {
            let code: Int32
            let stopped: Bool
            let timedOut: Bool
            let launchError: String?
            let launched: Bool
        }
        private let process: Process
        private let lock = NSLock()
        private var tree: ProcessTreeSnapshot?
        private var deadline: DispatchSourceTimer?
        private var stopped = false
        private var timedOut = false
        private var exited = false

        init(_ process: Process) { self.process = process }

        func stop(timedOut: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            if exited || stopped { return }
            stopped = true
            self.timedOut = timedOut
            deadline?.cancel()
            if let tree {
                self.tree = ProcessTreeReaper.quiesceAndKill(
                    ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: tree))
            }
        }

        func run<T: Sendable>(
            timeoutSeconds: Int? = nil, reapDescendantsOnExit: Bool = true,
            settlement: @escaping @Sendable (Exit) async -> T
        ) async -> T {
            await withTaskCancellationHandler {
                let error: String? = await withCheckedContinuation { continuation in
                    lock.lock(); defer { lock.unlock() }
                    if stopped {
                        exited = true
                        continuation.resume(returning: nil)
                        return
                    }
                    process.terminationHandler = { [self] _ in
                        lock.lock()
                        exited = true
                        deadline?.cancel()
                        deadline = nil
                        lock.unlock()
                        continuation.resume(returning: nil)
                    }
                    do {
                        try process.run()
                        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(process.processIdentifier)
                        tree = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
                        if let timeoutSeconds {
                            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                            timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                            timer.setEventHandler { [self] in stop(timedOut: true) }
                            deadline = timer
                            timer.resume()
                        }
                    } catch {
                        exited = true
                        continuation.resume(returning: String(describing: error))
                    }
                }
                return await settle { [self] in
                    // The effect has exited; its owner alone now holds the
                    // immutable tree, output and terminal record.
                    if let tree, reapDescendantsOnExit || stopped {
                        ProcessTreeReaper.quiesceAndKill(
                            ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: tree))
                    }
                    process.terminationHandler = nil
                    return await settlement(Exit(
                        code: tree == nil ? 127 : process.terminationStatus,
                        stopped: stopped, timedOut: timedOut, launchError: error, launched: tree != nil))
                }
            } onCancel: { self.stop() }
        }
    }

    // Bounded thread-safe Data accumulator for subprocess pipe capture.
    final class BoundedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var head = Data()
        private var tail = Data()
        private var tailStart = 0
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
            let headCount = min(chunk.count, max(0, cap / 2 - head.count))
            head.append(chunk.prefix(headCount))
            let rest = chunk.dropFirst(headCount)
            let tailBudget = cap - cap / 2
            guard !rest.isEmpty else { return lines }
            _truncated = _truncated || rest.count > tailBudget - tail.count
            guard tailBudget > 0 else { return lines }
            if rest.count >= tailBudget {
                tail = Data(rest.suffix(tailBudget))
                tailStart = 0
            } else {
                let fill = min(rest.count, tailBudget - tail.count)
                tail.append(rest.prefix(fill))
                let overflow = rest.dropFirst(fill)
                if !overflow.isEmpty {
                    tail.withUnsafeMutableBytes { destination in
                        overflow.withUnsafeBytes { source in
                            let first = min(overflow.count, tailBudget - tailStart)
                            memcpy(destination.baseAddress!.advanced(by: tailStart), source.baseAddress!, first)
                            if first < overflow.count {
                                memcpy(destination.baseAddress!, source.baseAddress!.advanced(by: first), overflow.count - first)
                            }
                        }
                    }
                    tailStart = (tailStart + overflow.count) % tailBudget
                }
            }
            return lines
        }
        var data: Data {
            lock.lock(); defer { lock.unlock() }
            var output = head
            if _truncated { output.append(Data("\n[output truncated; head and tail retained]\n".utf8)) }
            output.append(tail.suffix(from: tailStart))
            output.append(tail.prefix(tailStart))
            return output
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

}

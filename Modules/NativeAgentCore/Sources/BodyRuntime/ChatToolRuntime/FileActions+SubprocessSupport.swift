import Foundation
import Synchronization
import NativeAgentCore
// Blueprint: | `FileActions+SubprocessSupport.swift` | `SubprocessWork`, `settle`; one process owner; output/audit settlement |

extension SwiftToolDispatcher {
    /// Bounded pipe capture shared by builder and image subprocess adapters. Final drain must not wait for a descendant that inherited a write FD.
    final class InvokeOutputCapture: Sendable {
        private let stdoutBuffer: BoundedBuffer
        private let stderrBuffer: BoundedBuffer
        private let stdoutDrain: ProcessPipeDrain
        private let stderrDrain: ProcessPipeDrain
        private let stdout: Pipe
        private let stderr: Pipe
        private let process: ManagedProcess

        init(process: ManagedProcess, stdoutCap: Int = 512 * 1024, stderrCap: Int = 128 * 1024,
             onStdoutLine: (@Sendable (String) -> Void)? = nil) throws {
            let stdout = Pipe(), stderr = Pipe()
            self.stdout = stdout
            self.stderr = stderr
            self.process = process
            let stdoutBuffer = BoundedBuffer(cap: stdoutCap, onLine: onStdoutLine)
            let stderrBuffer = BoundedBuffer(cap: stderrCap)
            self.stdoutBuffer = stdoutBuffer
            self.stderrBuffer = stderrBuffer
            process.standardOutput = stdout
            process.standardError = stderr
            // Output is life of the call waiting on this process.
            let stdoutDrain = try ProcessPipeDrain(handle: stdout.fileHandleForReading) { stdoutBuffer.append($0); process.life?.moved() }
            do {
                stderrDrain = try ProcessPipeDrain(handle: stderr.fileHandleForReading) { stderrBuffer.append($0); process.life?.moved() }
            } catch {
                stdoutDrain.stopAndWait()
                throw error
            }
            self.stdoutDrain = stdoutDrain
        }

        private func stopReading() {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            // Settle queued reads and their appends before any output snapshot.
            stdoutDrain.stopAndWait()
            stderrDrain.stopAndWait()
            stdoutBuffer.finishLines()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }

        var truncated: Bool { stdoutBuffer.truncated || stderrBuffer.truncated }

        func finish(strictUTF8: Bool = false, appendTruncationNotes: Bool = true) -> (stdout: String, stderr: String) {
            stopReading()
            let decode: (Data) -> String = strictUTF8
                ? { String(data: $0, encoding: .utf8) ?? "" }
                : { String(decoding: $0, as: UTF8.self) }
            var stdoutText = decode(stdoutBuffer.data)
            var stderrText = decode(stderrBuffer.data)
            if let failure = process.terminationError { stderrText += "\n" + failure }
            if appendTruncationNotes, stdoutBuffer.truncated {
                stdoutText += "\n[stdout truncated]"
            }
            if appendTruncationNotes, stderrBuffer.truncated {
                stderrText += "\n[stderr truncated]"
            }
            return (stdoutText, stderrText)
        }
    }

    /// One effect owner, one settlement. Launch and Stop share admission; Stop freezes the tree before killing it, leaving no grace in which it can fork work.
    /// Only physical exit releases the waiter to settlement.
    final class SubprocessWork: Sendable {
        struct Exit: Sendable {
            let code: Int32
            let stopped: Bool
            let timedOut: Bool
            let launchError: String?
            let terminationError: String?
            let launched: Bool
        }
        private let process: ManagedProcess
        private struct State {
            var tree: ProcessTreeSnapshot?
            var deadline: DispatchSourceTimer?
            var stopped = false
            var timedOut = false
            var exited = false
        }
        private let state = Mutex(State())

        init(_ process: ManagedProcess) { self.process = process }

        func stop(timedOut: Bool = false) {
            state.withLock { state in
                if state.exited || state.stopped { return }
                state.stopped = true
                state.timedOut = timedOut
                state.deadline?.cancel()
                if let tree = state.tree {
                    state.tree = ProcessTreeReaper.quiesceAndKill(
                        ProcessTreeReaper.snapshot(rootPID: tree.rootPID, retaining: tree))
                }
            }
        }

        func run<T: Sendable>(
            timeoutSeconds: Int? = nil, reapDescendantsOnExit: Bool = true,
            settlement: @escaping @Sendable (Exit) async -> T
        ) async -> T {
            await withTaskCancellationHandler {
                let error: String? = await withCheckedContinuation { continuation in
                    state.withLock { state in
                        if state.stopped {
                            state.exited = true
                            continuation.resume(returning: nil)
                            return
                        }
                        process.terminationHandler = { [self] _ in
                            self.state.withLock { state in
                                state.exited = true
                                state.deadline?.cancel()
                                state.deadline = nil
                            }
                            continuation.resume(returning: nil)
                        }
                        do {
                            process.reapDescendantsOnExit = reapDescendantsOnExit
                            try process.run()
                            state.tree = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
                            if let timeoutSeconds {
                                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                                timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                                timer.setEventHandler { [self] in stop(timedOut: true) }
                                state.deadline = timer
                                timer.resume()
                            }
                        } catch {
                            state.exited = true
                            continuation.resume(returning: String(describing: error))
                        }
                    }
                }
                return await settle { [self] in
                    // The effect has exited; its owner alone now holds the immutable tree, output and terminal record.
                    process.terminationHandler = nil
                    let exit = state.withLock { state in
                        Exit(code: state.tree == nil ? 127 : process.terminationStatus,
                             stopped: state.stopped && process.terminationError == nil,
                             timedOut: state.timedOut, launchError: error,
                             terminationError: process.terminationError, launched: state.tree != nil)
                    }
                    return await settlement(exit)
                }
            } onCancel: { self.stop() }
        }
    }

    final class BoundedBuffer: Sendable {
        private struct State {
            var head = Data()
            var tail = Data()
            var tailStart = 0
            var truncated = false
            var pendingLine = Data()
            var discardingLine = false
        }
        private let state = Mutex(State())
        private let cap: Int
        private let onLine: (@Sendable (String) -> Void)?
        init(cap: Int, onLine: (@Sendable (String) -> Void)? = nil) { self.cap = cap; self.onLine = onLine }
        func append(_ chunk: Data) {
            for line in store(chunk) { onLine?(line) }
        }
        func finishLines() {
            let rest = state.withLock { state in
                defer { state.pendingLine = Data() }
                return state.pendingLine
            }
            if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        }
        private func store(_ chunk: Data) -> [String] {
            state.withLock { state in
                var lines: [String] = []
                if onLine != nil {
                    state.pendingLine.append(chunk)
                    while let newline = state.pendingLine.firstIndex(of: 0x0A) {
                        if !state.discardingLine, state.pendingLine.distance(from: state.pendingLine.startIndex, to: newline) <= cap {
                            lines.append(String(decoding: state.pendingLine[state.pendingLine.startIndex..<newline], as: UTF8.self))
                        }
                        state.pendingLine.removeSubrange(state.pendingLine.startIndex...newline)
                        state.discardingLine = false
                    }
                    if state.discardingLine || state.pendingLine.count > cap {
                        state.pendingLine.removeAll()
                        state.discardingLine = true
                    }
                }
                let headCount = min(chunk.count, max(0, cap / 2 - state.head.count))
                state.head.append(chunk.prefix(headCount))
                let rest = chunk.dropFirst(headCount)
                let tailBudget = cap - cap / 2
                guard !rest.isEmpty else { return lines }
                state.truncated = state.truncated || rest.count > tailBudget - state.tail.count
                guard tailBudget > 0 else { return lines }
                if rest.count >= tailBudget {
                    state.tail = Data(rest.suffix(tailBudget))
                    state.tailStart = 0
                } else {
                    let fill = min(rest.count, tailBudget - state.tail.count)
                    state.tail.append(rest.prefix(fill))
                    let overflow = rest.dropFirst(fill)
                    if !overflow.isEmpty {
                        let first = min(overflow.count, tailBudget - state.tailStart)
                        state.tail.replaceSubrange(state.tailStart..<(state.tailStart + first), with: overflow.prefix(first))
                        if first < overflow.count {
                            state.tail.replaceSubrange(0..<(overflow.count - first), with: overflow.dropFirst(first))
                        }
                        state.tailStart = (state.tailStart + overflow.count) % tailBudget
                    }
                }
                return lines
            }
        }
        var data: Data {
            state.withLock { state in
                var output = state.head
                if state.truncated { output.append(Data("\n[output truncated; head and tail retained]\n".utf8)) }
                output.append(state.tail.suffix(from: state.tailStart))
                output.append(state.tail.prefix(state.tailStart))
                return output
            }
        }
        var truncated: Bool {
            state.withLock { $0.truncated }
        }
    }

    /// Keep head and tail so both initial errors and terminal summaries survive bounded tool output. An explicit elision marker discloses the cut; head-only
    /// truncation can hide the cause of failure.
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

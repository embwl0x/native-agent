import Foundation
import Darwin

public final class MacControlBridgeProcesses: @unchecked Sendable {
    public init() {}

    private let execOutputLimitBytes = 1_048_576
    private final class ExecState: @unchecked Sendable {
        let lock = NSLock()
        var activeProcesses: [String: Process] = [:]
        var cancelRequested: Set<String> = []
        var cancelSignalled: Set<String> = []
        var processExited: Set<String> = []
    }
    private let execState = ExecState()
    private func registerProcess(_ proc: Process, operationId: String) {
        execState.lock.lock()
        execState.activeProcesses[operationId] = proc
        execState.lock.unlock()
    }

    private func unregisterProcess(operationId: String) {
        execState.lock.lock()
        execState.activeProcesses.removeValue(forKey: operationId)
        execState.processExited.insert(operationId)
        execState.lock.unlock()
    }

    public func requestCancellation(operationId: String) -> Bool {
        execState.lock.lock()
        if execState.processExited.contains(operationId) {
            execState.lock.unlock()
            return false
        }
        execState.cancelRequested.insert(operationId)
        guard let process = execState.activeProcesses[operationId] else {
            execState.lock.unlock()
            return false
        }
        let pid = process.processIdentifier
        let running = process.isRunning
        if running { execState.cancelSignalled.insert(operationId) }
        execState.lock.unlock()
        guard running else { return true }
        if killpg(pid, SIGTERM) != 0 { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning, killpg(pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
        return true
    }

    private func cancellationWasRequested(operationId: String) -> Bool {
        execState.lock.lock()
        defer { execState.lock.unlock() }
        return execState.cancelRequested.contains(operationId)
    }

    public func consumeCancellation(operationId: String) -> (requested: Bool, signalled: Bool) {
        execState.lock.lock()
        defer { execState.lock.unlock() }
        execState.processExited.remove(operationId)
        return (
            execState.cancelRequested.remove(operationId) != nil,
            execState.cancelSignalled.remove(operationId) != nil
        )
    }

    public func stopAllProcesses() -> Int {
        execState.lock.lock()
        let processes = execState.activeProcesses
        execState.cancelRequested.formUnion(processes.keys)
        execState.cancelSignalled.formUnion(processes.compactMap { key, process in
            process.isRunning ? key : nil
        })
        execState.activeProcesses.removeAll()
        // fix-emergency-stop-race: do NOT try to zero the exec slot count here.
        // Every admitted exec still holds a live `ScopedSlot` handle whose
        // deinit releases it when the background block unwinds. Forcing the
        // count to zero on top of that would double-count each release, driving
        // it below the true number of live slots and letting the next burst
        // over-admit past execLimit. `ScopedSlotCounter` keeps the count private
        // precisely so this shortcut is not expressible.
        execState.lock.unlock()
        final class ProcessSnapshot: @unchecked Sendable {
            let processes: [String: Process]
            init(_ processes: [String: Process]) {
                self.processes = processes
            }
        }
        let snapshot = ProcessSnapshot(processes)
        for (_, proc) in processes where proc.isRunning {
            let pid = proc.processIdentifier
            if killpg(pid, SIGTERM) != 0 {
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for (_, proc) in snapshot.processes where proc.isRunning {
                let pid = proc.processIdentifier
                if killpg(pid, SIGKILL) != 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        return processes.count
    }

    // PATCH-2026-05-07: mac-control-bridge Process spawn UNDER the SwiftUI app
    // process (NativeAgent.app), so any TCC requests the child triggers
    // (osascript controlling another app, Accessibility, Full Disk Access)
    // are attributed to NativeAgent's responsible-app bundle ID.
    /// Project before releasing the process registration so cancellation
    /// acknowledgement still covers response interpretation.
    public func runProcess(
        argv: [String],
        stdin stdinStr: String?,
        timeout: Double,
        operationId: String,
        project: (MacControlBridgeProcessResult) -> [String: Any]
    ) -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if stdinStr != nil {
            proc.standardInput = Pipe()
        }

        let outBuffer = SystemProcessAdapter._Buffer(byteLimit: execOutputLimitBytes)
        let errBuffer = SystemProcessAdapter._Buffer(byteLimit: execOutputLimitBytes)
        let stdoutDrain: SystemProcessAdapter.PipeDrain
        let stderrDrain: SystemProcessAdapter.PipeDrain
        do {
            stdoutDrain = try SystemProcessAdapter.PipeDrain(handle: stdoutPipe.fileHandleForReading) {
                outBuffer.append($0)
            }
            do {
                stderrDrain = try SystemProcessAdapter.PipeDrain(handle: stderrPipe.fileHandleForReading) {
                    errBuffer.append($0)
                }
            } catch {
                stdoutDrain.stopAndWait()
                throw error
            }
        } catch {
            return project(.spawnFailed(error.localizedDescription))
        }
        defer {
            stdoutDrain.stopAndWait()
            stderrDrain.stopAndWait()
        }

        do {
            try proc.run()
            setpgid(proc.processIdentifier, proc.processIdentifier)
            registerProcess(proc, operationId: operationId)
            if cancellationWasRequested(operationId: operationId) {
                _ = requestCancellation(operationId: operationId)
            }
        } catch {
            return project(.spawnFailed(error.localizedDescription))
        }
        defer { unregisterProcess(operationId: operationId) }

        // Drop our copy of the stdin read end now that the child owns its own:
        // without this a stalled write below could never fail with EPIPE, even
        // after the child exits, because the parent still held the pipe open.
        // Safe because NativeAgentApp.init installs SIGPIPE=SIG_IGN before any
        // spawn, so the doomed write throws instead of killing the app.
        if let pipe = proc.standardInput as? Pipe {
            try? pipe.fileHandleForReading.close()
        }

        // Timeout watchdog. TimeoutFlag is a class so the watchdog block can
        // safely mutate it across thread boundaries without tripping Swift's
        // sendable-closure-capture warning.
        final class TimeoutFlag: @unchecked Sendable {
            let lock = NSLock()
            private var _fired = false
            var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
            public func fire() { lock.lock(); _fired = true; lock.unlock() }
        }
        let timeoutFlag = TimeoutFlag()
        let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak proc] in
            guard let proc, proc.isRunning else { return }
            timeoutFlag.fire()
            if killpg(proc.processIdentifier, SIGTERM) != 0 {
                proc.terminate()
            }
            // Hard kill after 2s grace
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak proc] in
                guard let proc, proc.isRunning else { return }
                if killpg(proc.processIdentifier, SIGKILL) != 0 {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        // fix-stdin-wedge: write stdin on its own queue, and only once the
        // drains above are running. A stdin payload larger than the ~64 KB
        // pipe buffer blocks the writer until the child reads it — and the
        // child may itself be blocked writing stdout. Writing synchronously
        // here deadlocked both sides until the watchdog killed the process.
        let stdinGroup = DispatchGroup()
        if let stdinStr, let pipe = proc.standardInput as? Pipe {
            stdinGroup.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForWriting
                if let data = stdinStr.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
                stdinGroup.leave()
            }
        }

        proc.waitUntilExit()
        var stdoutStopped = false
        var stderrStopped = false
        let drainDeadline = DispatchTime.now() + .seconds(2)
        if stdoutDrain.wait(timeout: drainDeadline) == .timedOut
            || stderrDrain.wait(timeout: drainDeadline) == .timedOut {
            timeoutFlag.fire()
            // Descendants can keep the pipes open after their parent exits.
            let pid = proc.processIdentifier
            killpg(pid, SIGTERM)
            let terminationDeadline = DispatchTime.now() + .seconds(2)
            _ = stdoutDrain.wait(timeout: terminationDeadline)
            _ = stderrDrain.wait(timeout: terminationDeadline)
            killpg(pid, SIGKILL)
            stdoutStopped = stdoutDrain.wait(timeout: .now()) == .timedOut
            stderrStopped = stderrDrain.wait(timeout: .now()) == .timedOut
        }
        stdoutDrain.stopAndWait()
        stderrDrain.stopAndWait()
        // A descendant can also retain stdin. Keep its writer wait bounded.
        _ = stdinGroup.wait(timeout: .now() + 5)
        let isTimeout = timeoutFlag.fired
        return project(.exited(
            stdout: outBuffer.snapshot(), stderr: errBuffer.snapshot(), exit: Int(proc.terminationStatus), timedOut: isTimeout,
            stdoutTruncated: outBuffer.truncated || stdoutStopped, stderrTruncated: errBuffer.truncated || stderrStopped
        ))
    }

}

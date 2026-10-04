import Foundation
import Darwin
import MacControl

final class MacControlBridgeProcesses: MacControlBridgeProcessPort, @unchecked Sendable {
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

    func requestCancellation(operationId: String) -> Bool {
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

    func consumeCancellation(operationId: String) -> (requested: Bool, signalled: Bool) {
        execState.lock.lock()
        defer { execState.lock.unlock() }
        execState.processExited.remove(operationId)
        return (
            execState.cancelRequested.remove(operationId) != nil,
            execState.cancelSignalled.remove(operationId) != nil
        )
    }

    func stopAllProcesses() -> Int {
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
    func runProcess(
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
            func fire() { lock.lock(); _fired = true; lock.unlock() }
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

        // Drain pipes concurrently BEFORE calling waitUntilExit to prevent
        // deadlock when a subprocess emits more than the pipe buffer (~64 KB).
        // Use a class box so Swift's Sendable checker doesn't flag mutation of
        // captured vars across concurrently-executing closures.
        final class DataBox: @unchecked Sendable {
            var value = Data()
            var truncated = false
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let stopDraining = TimeoutFlag()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async {
            let capped = self.readCapped(stdoutPipe.fileHandleForReading, maxBytes: self.execOutputLimitBytes,
                                        shouldStop: { stopDraining.fired })
            outBox.value = capped.data
            outBox.truncated = capped.truncated
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            let capped = self.readCapped(stderrPipe.fileHandleForReading, maxBytes: self.execOutputLimitBytes,
                                        shouldStop: { stopDraining.fired })
            errBox.value = capped.data
            errBox.truncated = capped.truncated
            drainGroup.leave()
        }

        // fix-stdin-wedge: write stdin on its own queue, and only once the
        // drains above are enqueued. A stdin payload larger than the ~64 KB
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
        if drainGroup.wait(timeout: .now() + 2) == .timedOut {
            timeoutFlag.fire()
            // Descendants can keep the pipes open after their parent exits.
            let pid = proc.processIdentifier
            killpg(pid, SIGTERM)
            _ = drainGroup.wait(timeout: .now() + 2)
            killpg(pid, SIGKILL)
            stopDraining.fire()
            drainGroup.wait()
        }
        // A descendant can also retain stdin. Keep its writer wait bounded.
        _ = stdinGroup.wait(timeout: .now() + 5)
        let outData = outBox.value
        let errData = errBox.value
        let isTimeout = timeoutFlag.fired
        return project(.exited(
            stdout: outData, stderr: errData, exit: Int(proc.terminationStatus), timedOut: isTimeout,
            stdoutTruncated: outBox.truncated, stderrTruncated: errBox.truncated
        ))
    }

    private func readCapped(_ handle: FileHandle, maxBytes: Int,
                            shouldStop: () -> Bool) -> (data: Data, truncated: Bool) {
        defer { try? handle.close() }
        var collected = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if shouldStop() { truncated = true; break }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            let remaining = max(0, maxBytes - collected.count)
            if remaining > 0 {
                collected.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
            if count > remaining {
                truncated = true
            }
        }
        return (collected, truncated)
    }

}

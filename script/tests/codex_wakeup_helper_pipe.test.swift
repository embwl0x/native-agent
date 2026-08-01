// BRIDGES-5 negative control, runnable headlessly:
//
//   swift script/tests/codex_wakeup_helper_pipe.test.swift
//
// `runCodexWakeupHelper` is `private static` inside the ChatOrchestration
// module, so this file cannot call the shipped symbol. It proves the MECHANISM
// instead: the pre-fix pipe pattern (read only after the wait loop) versus the
// shipped pattern (readabilityHandler armed before run()), both driven against
// a child that emits far more than one macOS pipe buffer (~64KB).
//
// Drift guard: the node suite asserts that the shipped
// SwiftToolDispatcher+AgentBridgeTools.swift still uses the pattern this file
// proves correct ("shipped helper arms pipe drains before process.run"), so a
// revert of the real fix fails there even though this file keeps passing.

import Foundation

let payloadBytes = 256 * 1024      // 4x a 64KB pipe buffer
let deadlineSeconds = 6.0

func makeChild() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Emit >64KB on stdout AND stderr, then exit 0.
    process.arguments = [
        "node", "-e",
        """
        const n = \(payloadBytes);
        process.stderr.write('E'.repeat(n));
        process.stdout.write(JSON.stringify({ status: 'completed', pad: 'X'.repeat(n) }));
        """,
    ]
    return process
}

/// PRE-FIX shape, verbatim in structure: run, write stdin, poll until exit or
/// deadline, and only then readDataToEndOfFile.
func preFixRun() -> (timedOut: Bool, stdoutBytes: Int) {
    let process = makeChild()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try! process.run()
    stdin.fileHandleForWriting.write(Data("{}".utf8))
    try? stdin.fileHandleForWriting.close()

    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // This is the shipped lie: "helper_timeout" for a healthy child that
        // was blocked writing to a pipe nobody was reading.
        return (true, 0)
    }
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    return (false, out.count)
}

/// SHIPPED shape: accumulators attached to both pipes before run(), stdin
/// written off-thread, bounded EOF wait after exit.
final class Drain: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var didFinish = false

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                self.finish()
                return
            }
            self.lock.lock(); self.buffer.append(chunk); self.lock.unlock()
        }
    }
    private func finish() {
        lock.lock(); let already = didFinish; didFinish = true; lock.unlock()
        if !already { finished.signal() }
    }
    func waitForEOF(timeout: TimeInterval, handle: FileHandle) {
        _ = finished.wait(timeout: .now() + timeout)
        handle.readabilityHandler = nil
        finish()
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

func fixedRun() -> (timedOut: Bool, stdoutBytes: Int, stderrBytes: Int) {
    let process = makeChild()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let outDrain = Drain(), errDrain = Drain()
    outDrain.attach(to: stdout.fileHandleForReading)
    errDrain.attach(to: stderr.fileHandleForReading)

    try! process.run()
    DispatchQueue.global(qos: .utility).async {
        let handle = stdin.fileHandleForWriting
        try? handle.write(contentsOf: Data("{}".utf8))
        try? handle.close()
    }

    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return (true, 0, 0)
    }
    outDrain.waitForEOF(timeout: 5.0, handle: stdout.fileHandleForReading)
    errDrain.waitForEOF(timeout: 5.0, handle: stderr.fileHandleForReading)
    return (false, outDrain.data.count, errDrain.data.count)
}

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok - \(label)")
    } else {
        failures += 1
        print("not ok - \(label)")
    }
}

let pre = preFixRun()
check(pre.timedOut,
      "pre-fix pattern wedges on \(payloadBytes)-byte helper output and reports helper_timeout")

let fixed = fixedRun()
check(!fixed.timedOut, "shipped pattern completes without hitting the deadline")
check(fixed.stdoutBytes >= payloadBytes,
      "shipped pattern captured full stdout (\(fixed.stdoutBytes) bytes >= \(payloadBytes))")
check(fixed.stderrBytes >= payloadBytes,
      "shipped pattern captured full stderr (\(fixed.stderrBytes) bytes >= \(payloadBytes))")
print(failures == 0 ? "\n# swift pipe tests: PASS" : "\n# swift pipe tests: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)

import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
import CoreWLAN
import SystemConfiguration
#if canImport(Darwin)
import Darwin
#endif
// Blueprint: | `ProcessCapture.swift` | `runProcess` Foundation and descriptor-pinned launches share bounded capture and settlement; executable lookup, result flags, pipe capture and condition-based timeout ownership |

// MARK: - Process launch and capture

/// Resolve executable paths verbatim or bare names through inherited PATH only.
func which(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    // An unset PATH uses /bin:/usr/bin.
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/bin:/usr/bin"
    for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
        // Empty PATH entries must not admit bare names from the working directory.
        if dir.isEmpty { continue }
        let candidate = (String(dir) as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Launch, timeout and capture completeness remain distinct from the exit status.
package struct FileSystemProcessRunResult {
    package var launched: Bool
    package var timedOut: Bool
    package var status: Int32
    package var stdout: String
    var stderr: String
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
    package var captureReadFailed: Bool = false
}

package func runProcess(
    _ launchPath: String,
    _ args: [String],
    cwd: URL? = nil,
    timeout: TimeInterval,
    environment: [String: String]? = nil,
    captureByteLimit: Int? = nil
) -> FileSystemProcessRunResult {
    guard FileManager.default.isExecutableFile(atPath: launchPath) else {
        return FileSystemProcessRunResult(launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    // nil inherits the environment; a supplied dictionary replaces it wholesale.
    if let environment { proc.environment = environment }
    if let cwd { proc.currentDirectoryURL = cwd }
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        return FileSystemProcessRunResult(launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    }
    return captureProcessOutput(outPipe, errPipe, timeout: timeout, captureByteLimit: captureByteLimit,
        signalChild: { signal, timedOut in
            guard proc.isRunning else { return }
            timedOut.set()
            if signal == SIGTERM { proc.terminate() }
            else { kill(proc.processIdentifier, signal) }
        }, waitForExit: {
            proc.waitUntilExit()
            return proc.terminationStatus
        })
}

private func captureProcessOutput(
    _ outPipe: Pipe,
    _ errPipe: Pipe,
    timeout: TimeInterval,
    captureByteLimit: Int?,
    signalChild: @escaping @Sendable (Int32, ProcessTimeoutFlag) -> Void,
    waitForExit: () -> Int32
) -> FileSystemProcessRunResult {
    let timedOut = ProcessTimeoutFlag()
    let capturedOut = ProcessPipeCapture()
    let capturedErr = ProcessPipeCapture()
    let outDrain = try? ProcessPipeDrain(handle: outPipe.fileHandleForReading) {
        capturedOut.append($0, byteLimit: captureByteLimit)
    }
    let errDrain = try? ProcessPipeDrain(handle: errPipe.fileHandleForReading) {
        capturedErr.append($0, byteLimit: captureByteLimit)
    }
    if outDrain == nil { try? outPipe.fileHandleForReading.close() }
    if errDrain == nil { try? errPipe.fileHandleForReading.close() }

    // TERM then KILL bounds the child wait; pipe settlement separately bounds
    // descendants retaining writers. Keep the watchdog pool-independent too.
    let watchdogDone = ProcessTimeoutFlag()
    let watchdogRetired = DispatchSemaphore(value: 0)
    let watchdog = Thread {
        defer { watchdogRetired.signal() }
        // Actual exit wakes the deadline owner; no sampling of completion.
        let deadline = Date().addingTimeInterval(timeout)
        guard !watchdogDone.wait(until: deadline) else { return }
        signalChild(SIGTERM, timedOut)
        guard !watchdogDone.wait(until: deadline.addingTimeInterval(2)) else { return }
        signalChild(SIGKILL, timedOut)
    }
    watchdog.start()

    let status = waitForExit()
    watchdogDone.set()
    watchdogRetired.wait()
    // Descendants may retain the pipes after the child exits. Stop the
    // nonblocking readers after a shared grace; closing a descriptor from
    // another thread does not reliably interrupt a blocking read.
    let drainGrace: DispatchTime = .now() + 2.0
    let outOK = outDrain?.wait(until: drainGrace) ?? true
    let errOK = errDrain?.wait(until: drainGrace) ?? true
    if !outOK || !errOK {
        timedOut.set()
        outDrain?.stop()
        errDrain?.stop()
    }
    outDrain?.stopAndWait()
    errDrain?.stopAndWait()
    let to = timedOut.get()
    return FileSystemProcessRunResult(
        launched: true,
        timedOut: to,
        status: status,
        stdout: decodeUTF8Replacing(capturedOut.data),
        stderr: decodeUTF8Replacing(capturedErr.data),
        stdoutTruncated: capturedOut.truncated,
        stderrTruncated: capturedErr.truncated,
        captureReadFailed: outDrain == nil || errDrain == nil
            || outDrain?.captureReadFailed == true || errDrain?.captureReadFailed == true
    )
}

#if canImport(Darwin)
/// Spawn in the verified directory inode, sharing capture and settlement with Foundation launches.
func runProcess(
    _ launchPath: String,
    _ args: [String],
    cwdDescriptor: Int32,
    inheritDescriptor: (source: Int32, target: Int32)? = nil,
    timeout: TimeInterval,
    environment: [String: String]? = nil,
    captureByteLimit: Int? = nil
) -> FileSystemProcessRunResult {
    let failed = FileSystemProcessRunResult(
        launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    guard cwdDescriptor >= 0, FileManager.default.isExecutableFile(atPath: launchPath) else {
        return failed
    }
    let outPipe = Pipe()
    let errPipe = Pipe()

    // Darwin spawn dup2 preserves O_CLOEXEC; dup makes the verified vnode inheritable.
    var inheritable: Int32 = -1
    defer { if inheritable >= 0 { _ = Darwin.close(inheritable) } }
    if let inheritDescriptor {
        inheritable = dup(inheritDescriptor.source)
        guard inheritable >= 0 else { return failed }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_addfchdir(&actions, cwdDescriptor) == 0,
          posix_spawn_file_actions_adddup2(
            &actions, outPipe.fileHandleForWriting.fileDescriptor, 1) == 0,
          posix_spawn_file_actions_adddup2(
            &actions, errPipe.fileHandleForWriting.fileDescriptor, 2) == 0
    else { return failed }
    if let inheritDescriptor {
        guard posix_spawn_file_actions_adddup2(
            &actions, inheritable, inheritDescriptor.target) == 0 else { return failed }
    }

    var argv: [UnsafeMutablePointer<CChar>?] = ([launchPath] + args).map { strdup($0) }
    argv.append(nil)
    defer { for argument in argv { free(argument) } }

    var childEnvironment: [UnsafeMutablePointer<CChar>?] =
        (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
    childEnvironment.append(nil)
    defer { for entry in childEnvironment { free(entry) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, launchPath, &actions, nil, argv, childEnvironment)
    // The child owns the write ends now; this side must let go of them or the
    // drains below never see EOF.
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    guard spawned == 0 else { return failed }

    let childPID = pid
    return captureProcessOutput(outPipe, errPipe, timeout: timeout, captureByteLimit: captureByteLimit,
        signalChild: { signal, timedOut in
            timedOut.set()
            kill(childPID, signal)
        }, waitForExit: {
            var waitStatus: Int32 = 0
            while waitpid(childPID, &waitStatus, 0) < 0 && errno == EINTR {}
            // WIFEXITED/WEXITSTATUS macros are not imported into Swift.
            return (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : -1
        })
}
#endif

/// One drain writes; readback follows its completion.
private final class ProcessPipeCapture: @unchecked Sendable {
    var data = Data()
    var truncated = false
    func append(_ chunk: Data, byteLimit: Int?) {
        let retained = min(chunk.count, max(0, (byteLimit ?? Int.max) - data.count))
        data.append(chunk.prefix(retained))
        if retained < chunk.count { truncated = true }
    }
}

/// Thread-safe one-shot flag for the process watchdog and pipe shutdown.
private final class ProcessTimeoutFlag: @unchecked Sendable {
    private let lock = NSCondition()
    private var value = false
    func set() { lock.lock(); value = true; lock.broadcast(); lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func wait(until deadline: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        while !value {
            if !lock.wait(until: deadline) { break }
        }
        return value
    }
}

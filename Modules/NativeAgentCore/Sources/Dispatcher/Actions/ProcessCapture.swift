import Foundation
import NativeAgentCore
// Blueprint: | `ProcessCapture.swift` | `runProcess`: `ManagedProcess` lifetime/group settlement; strict UTF-8 or caller-owned bytes |

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
    /// Present only when the caller owns record decoding. No lossy text copy.
    var rawOutput: (stdout: Data, stderr: Data)? = nil
}

package func runProcess(
    _ launchPath: String, _ args: [String], cwd: URL? = nil,
    timeout: TimeInterval, environment: [String: String]? = nil, captureByteLimit: Int? = nil,
    captureAsBytes: Bool = false
) -> FileSystemProcessRunResult {
    let process = ManagedProcess()
    process.currentDirectoryURL = cwd
    return captureProcessOutput(process, launchPath, args, timeout: timeout,
        environment: environment, captureByteLimit: captureByteLimit, captureAsBytes: captureAsBytes)
}

func runProcess(
    _ launchPath: String, _ args: [String], cwdDescriptor: Int32,
    inheritDescriptor: (source: Int32, target: Int32)? = nil,
    timeout: TimeInterval, environment: [String: String]? = nil, captureByteLimit: Int? = nil,
    captureAsBytes: Bool = false
) -> FileSystemProcessRunResult {
    let process = ManagedProcess()
    process.currentDirectoryDescriptor = cwdDescriptor
    process.inheritedDescriptor = inheritDescriptor
    return captureProcessOutput(process, launchPath, args, timeout: timeout,
        environment: environment, captureByteLimit: captureByteLimit, captureAsBytes: captureAsBytes)
}

private func captureProcessOutput(
    _ process: ManagedProcess, _ launchPath: String, _ args: [String],
    timeout: TimeInterval, environment: [String: String]?, captureByteLimit: Int?, captureAsBytes: Bool
) -> FileSystemProcessRunResult {
    let outPipe = Pipe(), errPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    process.environment = environment
    process.standardOutput = outPipe
    process.standardError = errPipe
    let capturedOut = ProcessPipeCapture(), capturedErr = ProcessPipeCapture()
    let outDrain: ProcessPipeDrain
    let errDrain: ProcessPipeDrain
    do {
        outDrain = try ProcessPipeDrain(handle: outPipe.fileHandleForReading) {
            capturedOut.append($0, byteLimit: captureByteLimit)
        }
        do {
            errDrain = try ProcessPipeDrain(handle: errPipe.fileHandleForReading) {
                capturedErr.append($0, byteLimit: captureByteLimit)
            }
        } catch { outDrain.stopAndWait(); throw error }
    } catch {
        return FileSystemProcessRunResult(launched: false, timedOut: false, status: -1,
            stdout: "", stderr: "Process capture could not start: \(error.localizedDescription)", captureReadFailed: true)
    }
    defer { outDrain.stopAndWait(); errDrain.stopAndWait() }
    do { try process.run(timeout: timeout) }
    catch {
        return FileSystemProcessRunResult(launched: false, timedOut: false, status: -1,
            stdout: "", stderr: "Process launch failed: \(error.localizedDescription)")
    }
    process.waitForSettlement()
    // Once group settlement completes, a pipe held outside that group cannot extend the capture wait indefinitely.
    let drainDeadline: DispatchTime = .now() + 2
    let outComplete = outDrain.wait(until: drainDeadline)
    let errComplete = errDrain.wait(until: drainDeadline)
    outDrain.stopAndWait()
    errDrain.stopAndWait()
    let stdout = captureAsBytes ? nil : String(data: capturedOut.data, encoding: .utf8)
    let stderr = captureAsBytes ? nil : String(data: capturedErr.data, encoding: .utf8)
    var problems: [String] = []
    if let failure = process.terminationError { problems.append(failure) }
    if !outComplete || !errComplete || outDrain.captureReadFailed || errDrain.captureReadFailed {
        problems.append("Process output could not be read completely.")
    }
    if !captureAsBytes && (stdout == nil || stderr == nil) { problems.append("Process output is not valid UTF-8.") }
    // Undecodable output is unavailable, never replacement text or a successful empty read.
    return FileSystemProcessRunResult(launched: true, timedOut: process.timedOut,
        status: process.terminationStatus, stdout: stdout ?? "",
        stderr: ([stderr].compactMap { $0 } + problems).joined(separator: "\n"),
        stdoutTruncated: capturedOut.truncated, stderrTruncated: capturedErr.truncated,
        captureReadFailed: !problems.isEmpty,
        rawOutput: captureAsBytes ? (capturedOut.data, capturedErr.data) : nil)
}

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

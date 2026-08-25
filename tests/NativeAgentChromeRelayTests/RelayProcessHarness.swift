import Darwin
import Foundation
import Testing

@testable import NativeAgentChromeRelayCore

// MARK: - Hang-proof harness for spawning the real NativeAgentChromeRelay binary
//
// Everything in the relay executable — the env read, the AF_UNIX connect, the
// dup, the two pumps, the teardown latch, the exit code, the stderr
// diagnostic — is compile-checked and, before this file, never executed by any
// eval (Package.swift:210-212 pins NativeAgentChromeRelayTests to
// NativeAgentChromeRelayCore only). This harness is the missing seam.
//
// Discipline copied from Modules/NativeAgentCore/Tests/SelfImprovementTests/
// SubprocessTestSupport.swift (that helper lives in a different test target, so
// it cannot be imported here; the hazards it exists for are the same):
//   * every wait is bounded — poll `isRunning` to a deadline, then
//     SIGTERM -> grace -> SIGKILL through the live Process object, never a
//     stored raw pid and never `waitUntilExit()`;
//   * pipes are drained CONCURRENTLY on dedicated Threads (not GCD, which
//     starves under concurrent subprocess load) so a child that outruns the
//     64 KB pipe buffer cannot wedge the suite;
//   * drains work on raw descriptors, not FileHandle.availableData, so a test
//     that deliberately closes a descriptor (the SIGPIPE eval) cannot trip an
//     ObjC exception in the drain thread.

// MARK: Paths

private final class RelayTestsAnchor {}

enum RelayTestPaths {
    /// tests/NativeAgentChromeRelayTests/<this file> -> repo root.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8
        )
    }

    struct MissingRelayBinary: Error, CustomStringConvertible {
        let candidates: [String]
        var description: String {
            "built NativeAgentChromeRelay not found; looked in:\n  "
                + candidates.joined(separator: "\n  ")
                + "\n(swift build/swift test builds every product in the package —"
                + " a missing binary is a real failure, not a reason to skip)"
        }
    }

    /// The built relay executable. `swift test` builds every product in the
    /// package, so the binary sits next to the .xctest bundle. Resolution
    /// failure THROWS: a spawned-relay eval must never pass vacuously because
    /// the thing it claims to exercise was not found.
    static func relayBinary() throws -> URL {
        var candidates: [URL] = []
        let bundleDirectory = Bundle(for: RelayTestsAnchor.self)
            .bundleURL.deletingLastPathComponent()
        candidates.append(bundleDirectory.appendingPathComponent("NativeAgentChromeRelay"))
        candidates.append(repoRoot.appendingPathComponent(".build/debug/NativeAgentChromeRelay"))
        candidates.append(repoRoot.appendingPathComponent(".build/release/NativeAgentChromeRelay"))
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw MissingRelayBinary(candidates: candidates.map(\.path))
    }
}

// MARK: Byte sink

/// Drains one descriptor to EOF on a dedicated Thread, publishing bytes
/// incrementally so a timeout diagnostic can still see partial output.
final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var reachedEOF = false

    init(descriptor: Int32) {
        let thread = Thread { [self] in
            var scratch = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = scratch.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    lock.lock()
                    buffer.append(contentsOf: scratch[0..<count])
                    lock.unlock()
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Never mistake "no bytes yet" for EOF — that is exactly
                    // the silent-empty-stream failure this sink exists to
                    // rule out.
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                lock.lock()
                reachedEOF = true
                lock.unlock()
                break
            }
        }
        thread.name = "RelayProcessHarness.ByteSink"
        thread.start()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func isAtEOF() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEOF
    }

    /// Returns the buffer once it holds at least `count` bytes, else nil.
    func awaitBytes(_ count: Int, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = snapshot()
            if current.count >= count { return current }
            if isAtEOF() { return current.count >= count ? current : nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    /// Returns everything read once the writer side is gone, else nil.
    func awaitEOF(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAtEOF() { return snapshot() }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}

// MARK: Low-level helpers

@discardableResult
func writeAllBytes(_ descriptor: Int32, _ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    var success = true
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(
                descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset
            )
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                success = false
                return
            }
        }
    }
    return success
}

private func fillSocketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { pointer in
            for (index, byte) in pathBytes.enumerated() { pointer[index] = byte }
        }
    }
    return address
}

/// Bounded replacement for waitUntilExit(). Returns true iff the child exited
/// on its own before the deadline; otherwise SIGTERM -> 2s grace -> SIGKILL.
@discardableResult
func waitForExitBounded(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if !process.isRunning { return true }
    process.terminate()
    let grace = Date().addingTimeInterval(2)
    while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    return false
}

// MARK: Harness

/// One relay process wired to a test-owned AF_UNIX listener in a temp root.
/// Nothing here touches the user's real socket path or data root: the relay is
/// always launched with NATIVEAGENT_CHROME_SOCKET_PATH and a temp HOME.
final class RelayHarness {
    struct SpawnFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    let root: URL
    let socketPath: String
    let process = Process()

    private let listenerDescriptor: Int32
    private(set) var connectionDescriptor: Int32 = -1
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutReadClosed = false
    private var cleaned = false

    /// Bytes the relay wrote to its stdout (the Chrome native-messaging frame
    /// channel). nil when the test asked for the read end to be closed.
    private(set) var chromeChannel: ByteSink?
    /// Bytes the relay wrote to the app-side Unix socket.
    private(set) var appChannel: ByteSink!
    private(set) var diagnostics: ByteSink!

    init(arguments: [String] = [], captureStdout: Bool = true) throws {
        root = URL(fileURLWithPath: "/tmp/na-relay-evals", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        // Short temp root on purpose: sun_path is 104 bytes on Darwin and the
        // system temp dir plus a UUID can crowd it.
        socketPath = root.appendingPathComponent("s.sock").path

        listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerDescriptor >= 0 else {
            throw SpawnFailure(reason: "socket() failed errno \(errno)")
        }
        _ = fcntl(listenerDescriptor, F_SETFD, FD_CLOEXEC)
        guard var address = fillSocketAddress(socketPath) else {
            throw SpawnFailure(reason: "test socket path too long: \(socketPath)")
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerDescriptor, $0, length)
            }
        }
        guard bound == 0 else { throw SpawnFailure(reason: "bind() failed errno \(errno)") }
        guard listen(listenerDescriptor, 4) == 0 else {
            throw SpawnFailure(reason: "listen() failed errno \(errno)")
        }
        _ = fcntl(listenerDescriptor, F_SETFL, O_NONBLOCK)

        process.executableURL = try RelayTestPaths.relayBinary()
        process.arguments = arguments
        process.environment = RelayHarness.hermeticEnvironment(
            socketPath: socketPath, home: root
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // No SIGPIPE in the TEST process if the relay dies mid-write.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        if captureStdout {
            chromeChannel = ByteSink(descriptor: stdoutPipe.fileHandleForReading.fileDescriptor)
        } else {
            try stdoutPipe.fileHandleForReading.close()
            stdoutReadClosed = true
        }
        diagnostics = ByteSink(descriptor: stderrPipe.fileHandleForReading.fileDescriptor)

        connectionDescriptor = try acceptBounded(timeout: 10)
        // On Darwin an accepted socket INHERITS O_NONBLOCK from the listener
        // (a BSD/Linux difference). Left set, every drain read returns
        // EAGAIN instantly and the sink would report a silent empty stream.
        _ = fcntl(connectionDescriptor, F_SETFL, 0)
        _ = fcntl(connectionDescriptor, F_SETNOSIGPIPE, 1)
        appChannel = ByteSink(descriptor: connectionDescriptor)
    }

    /// A HOME the relay cannot pollute and a socket override so no eval can
    /// reach ~/Library/Application Support/NativeAgent/chrome-control.sock.
    static func hermeticEnvironment(socketPath: String, home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["NATIVEAGENT_CHROME_SOCKET_PATH"] = socketPath
        environment["HOME"] = home.path
        return environment
    }

    private func acceptBounded(timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let accepted = Darwin.accept(listenerDescriptor, nil, nil)
            if accepted >= 0 { return accepted }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if !process.isRunning {
                    throw SpawnFailure(
                        reason: "relay exited before connecting: status "
                            + "\(process.terminationStatus) stderr "
                            + (String(data: diagnostics.snapshot(), encoding: .utf8) ?? "")
                    )
                }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            throw SpawnFailure(reason: "accept() failed errno \(errno)")
        }
        throw SpawnFailure(reason: "relay never connected within \(timeout)s")
    }

    // MARK: Driving the two sides

    /// Write raw bytes into the relay's stdin — the Chrome side.
    @discardableResult
    func sendFromChrome(_ data: Data) -> Bool {
        writeAllBytes(stdinPipe.fileHandleForWriting.fileDescriptor, data)
    }

    /// Write raw bytes into the app-side socket.
    @discardableResult
    func sendFromApp(_ data: Data) -> Bool {
        writeAllBytes(connectionDescriptor, data)
    }

    func closeChromeStdin() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    func closeAppSocket() {
        if connectionDescriptor >= 0 {
            Darwin.shutdown(connectionDescriptor, SHUT_RDWR)
        }
    }

    var stderrText: String {
        String(data: diagnostics.snapshot(), encoding: .utf8) ?? ""
    }

    func awaitStderr(timeout: TimeInterval) -> String {
        _ = diagnostics.awaitEOF(timeout: timeout)
        return stderrText
    }

    struct Exit {
        let exitedOnItsOwn: Bool
        let status: Int32
        let reason: Process.TerminationReason
    }

    @discardableResult
    func waitForExit(timeout: TimeInterval = 10) -> Exit {
        let exited = waitForExitBounded(process, timeout: timeout)
        return Exit(
            exitedOnItsOwn: exited,
            status: process.terminationStatus,
            reason: process.terminationReason
        )
    }

    func isStillRunning() -> Bool { process.isRunning }

    func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        waitForExitBounded(process, timeout: 3)
        if connectionDescriptor >= 0 { Darwin.close(connectionDescriptor) }
        Darwin.close(listenerDescriptor)
        try? stdinPipe.fileHandleForWriting.close()
        if !stdoutReadClosed { try? stdoutPipe.fileHandleForReading.close() }
        try? stderrPipe.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }

    deinit { cleanup() }
}

// MARK: Failure-path runner (no listener bound)

struct RelayFailureRun {
    let status: Int32
    let reason: Process.TerminationReason
    let exitedOnItsOwn: Bool
    let stdout: Data
    let stderr: String
    /// What the relay left behind under its (temp) HOME. The relay owns no
    /// file, feed or row today, so this must stay empty.
    let homeContents: [String]
}

/// Spawn the relay with an explicit socket-path override and NO listener, then
/// collect exit status + both streams under a bounded wait. HOME is a fresh
/// temp dir whose contents are captured (so a caller can assert the relay
/// wrote nothing anywhere) and then removed HERE — a per-call temp root the
/// caller had to remember to delete is exactly the lifecycle leak these evals
/// exist to catch.
func runRelayExpectingFailure(
    socketPath: String,
    arguments: [String] = [],
    timeout: TimeInterval = 10
) throws -> RelayFailureRun {
    let home = URL(fileURLWithPath: "/tmp/na-relay-evals", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = try RelayTestPaths.relayBinary()
    process.arguments = arguments
    process.environment = RelayHarness.hermeticEnvironment(socketPath: socketPath, home: home)
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let outSink = ByteSink(descriptor: stdoutPipe.fileHandleForReading.fileDescriptor)
    let errSink = ByteSink(descriptor: stderrPipe.fileHandleForReading.fileDescriptor)
    let exited = waitForExitBounded(process, timeout: timeout)
    _ = errSink.awaitEOF(timeout: 2)
    _ = outSink.awaitEOF(timeout: 2)
    try? stdinPipe.fileHandleForWriting.close()
    try? stdoutPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForReading.close()
    let homeContents =
        (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
    try? FileManager.default.removeItem(at: home)
    return RelayFailureRun(
        status: process.terminationStatus,
        reason: process.terminationReason,
        exitedOnItsOwn: exited,
        stdout: outSink.snapshot(),
        stderr: String(data: errSink.snapshot(), encoding: .utf8) ?? "",
        homeContents: homeContents.sorted()
    )
}

// MARK: Frame helpers

let relayDiagnosticPrefix = "[NativeAgentChromeRelay] "

func framedJSON(_ json: String) throws -> Data {
    try NativeMessagingFramer().encode(Data(json.utf8))
}

import CryptoKit
import Darwin
import Foundation
import NativeAgentCore

/// The executable the person saw. Never resolve PATH again when sending.
public struct AgentACPExecutable: Codable, Sendable, Equatable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let digest: String
    public var version: String?

    public static func capture(path: String) throws -> Self {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let handle = try openFile(path: url.path)
        defer { try? handle.close() }
        return try capture(path: url.path, handle: handle)
    }

    private static func openFile(path: String) throws -> FileHandle {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentACPClient.Failure.unavailable }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func capture(path: String, handle: FileHandle) throws -> Self {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0 else { throw AgentACPClient.Failure.unavailable }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0,
              info.st_size == after.st_size, info.st_mode == after.st_mode,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw AgentACPClient.Failure.unavailable }
        try handle.seek(toOffset: 0)
        return Self(path: path, device: info.st_dev, inode: info.st_ino,
                    digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Recheck the approved absolute path immediately before a normal Mac launch.
    func verify() throws {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == path
        else { throw AgentACPClient.Failure.executableChanged }
        let handle = try Self.openFile(path: path)
        defer { try? handle.close() }
            var current = try Self.capture(path: path, handle: handle)
            current.version = version
            guard current == self, access(path, X_OK) == 0 else { throw AgentACPClient.Failure.executableChanged }
    }

    public var isCurrent: Bool {
        do { try verify(); return true } catch { return false }
    }

    /// A bounded --version probe, without a shell or inherited app credentials.
    /// No agent conversation or configuration command is run.
    func reportedVersion() async throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-version-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = Pipe(), output = Pipe()
        let pid: pid_t
        do {
            pid = try AgentACPProcess.spawn(executable: path, arguments: ["--version"], directory: directory,
                environment: AgentHostCommandLines.scrubbedEnvironment(), input: input, output: output,
                approvedExecutable: self)
        } catch AgentACPClient.Failure.unavailable {
            // A program may not implement a version probe.
            return nil
        }
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
        // Stop the probe before taking its buffered output. A descendant can
        // retain stdout after the group exits, so never wait for pipe EOF.
        await Task.detached { await AgentACPProcess.finish(pid, grace: .seconds(3)) }.value
        defer { try? output.fileHandleForReading.close() }
        try Task.checkCancellation()
        guard isCurrent else { throw AgentACPClient.Failure.unavailable }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AgentACPClient.Failure.unavailable
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, let text = String(bytes: bytes.prefix(count), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(512))
    }
}

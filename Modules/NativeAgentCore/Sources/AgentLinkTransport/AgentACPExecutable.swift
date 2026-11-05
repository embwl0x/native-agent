import CryptoKit
import Darwin
import Foundation
import NativeAgentCore
import os
import PersistenceCore
// Blueprint: | `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |

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

    package static let maximumBytes: Int64 = 1 << 31

    private static func capture(path: String, handle: FileHandle) throws -> Self {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0, info.st_size <= maximumBytes else { throw AgentACPClient.Failure.unavailable }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        // Drain autoreleased chunks to bound memory; the initial size also detects a growing executable.
        var left = Int(info.st_size)
        while left > 0, let bytes = try autoreleasepool(invoking: { try handle.read(upToCount: min(65536, left)) }), !bytes.isEmpty {
            hash.update(data: bytes)
            left -= bytes.count
        }
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

    public func verify() throws {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == path
        else { throw AgentACPClient.Failure.executableChanged }
        let handle = try Self.openFile(path: path)
        defer { try? handle.close() }
        let current = try Self.capture(path: path, handle: handle)
        // Mount IDs can change across reboots; approval instead requires exact path, inode and bytes immediately before spawn.
        guard current.path == path, current.inode == inode, current.digest == digest,
              access(path, X_OK) == 0 else { throw AgentACPClient.Failure.executableChanged }
    }

    /// Display reads reuse a hash only while stat is unchanged; launch still verifies in full.
    public var isCurrent: Bool {
        let key = "\(path)\n\(inode)\n\(digest)"
        let before = Self.fileStamp(path)
        if let before, Self.verifiedStamps.withLock({ $0[key] }) == before, access(path, X_OK) == 0 { return true }
        do { try verify() } catch { return false }
        if let before, Self.fileStamp(path) == before { Self.verifiedStamps.withLock { $0[key] = before } }
        return true
    }

    private static let verifiedStamps = OSAllocatedUnfairLock(initialState: [String: SnapshotTailOpLog.FileStamp]())

    private static func fileStamp(_ path: String) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// Probe without a shell, inherited credentials or conversation commands; all exits stop the whole process tree. Output close, byte limit or grace ends the
    /// probe; the caller's launch rule owns any wrapper.
    package func reported(environment: [String: String], command: [String]? = nil,
                          errors: Bool = false, grace: Duration = .seconds(3), limit: Int = 512) async throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-version-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = Pipe(), output = Pipe()
        let argv = command ?? [path, "--version"]
        let pid: pid_t
        do {
            pid = try AgentACPProcess.spawn(executable: argv[0], arguments: Array(argv.dropFirst()), directory: directory,
                environment: environment, input: input, output: output,
                approvedExecutable: self, errorsToOutput: errors)
        } catch AgentACPClient.Failure.unavailable {
            // A program may not implement a version probe.
            return nil
        }
        let tree = ProcessTreeReaper.snapshot(rootPID: pid)
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        guard let reader = try? AgentACPPipeReader(handle: output.fileHandleForReading) else {
            if let failure = await AgentACPProcess.finish(pid, snapshot: tree, grace: .zero) {
                throw ToolFailureError(failure, effects: .unknown, owner: "ACP version probe process group",
                    code: "process_termination_incomplete", instruction: "Repair the retained probe process before reconnecting.", recovery: .repair)
            }
            throw AgentACPClient.Failure.unavailable
        }
        // Reader completion cancels the ceiling; the ceiling stops descendants holding output open.
        let terminationFailure = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let bytes = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                let failure = await AgentACPProcess.finish(pid, snapshot: tree, grace: grace)
                terminationFailure.withLock { $0 = failure }
                return nil
            }
            group.addTask {
                var bytes = Data()
                do {
                    for try await chunk in reader.chunks {
                        reader.consumed()
                        bytes += chunk
                        if bytes.count >= limit { break }
                    }
                } catch {}
                return bytes
            }
            var read = Data()
            for await result in group {
                if let result { read = result }
                group.cancelAll()
            }
            return read
        }
        reader.cancel()
        if let failure = terminationFailure.withLock({ $0 }) {
            throw ToolFailureError(failure, effects: .unknown, owner: "ACP version probe process group",
                code: "process_termination_incomplete", instruction: "Repair the retained probe process before reconnecting.", recovery: .repair)
        }
        try Task.checkCancellation()
        guard isCurrent else { throw AgentACPClient.Failure.unavailable }
        let text = String(decoding: bytes.prefix(limit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

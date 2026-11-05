import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentLineProcess.swift` | `AgentLineProcess`: one approved program speaking line-delimited JSON over stdio, in its own process group |

/// One approved program speaking line-delimited JSON over stdio, in its own process group: the wire under the job doors of command-line agents. It has
/// no deadline: the program runs until it ends, its owner stops it, or the app quits and its input closes.
package actor AgentLineProcess {
    package enum Failure: Error, LocalizedError {
        case tooLarge
        case unreadable(String)
        case notReading

        package var errorDescription: String? {
            switch self {
            case .tooLarge: "The program wrote a line over 16 MiB; its output was not read further."
            case .unreadable(let detail): "The program wrote a line that is not JSON: \(detail)"
            case .notReading: "The program stopped reading its input, so the message did not reach it."
            }
        }
    }

    static let lineLimit = 16 * 1_048_576

    /// Each JSON value the program writes, in order. Finishes when its output closes; throws when a line cannot be read.
    package nonisolated let lines: AsyncThrowingStream<JSONValue, Error>
    private let input: Pipe
    private let pid: pid_t
    private let tree: ProcessTreeSnapshot
    private var stopped: String??

    /// Spawns only the approved bytes; a program that changed since approval does not start.
    package init(executable: String, arguments: [String], directory: URL, environment: [String: String],
                 approved: AgentACPExecutable) throws {
        let input = Pipe(), output = Pipe()
        let pid = try AgentACPProcess.spawn(executable: executable, arguments: arguments, directory: directory,
            environment: environment, input: input, output: output, approvedExecutable: approved)
        let tree = ProcessTreeReaper.snapshot(rootPID: pid)
        // Close parent copies of child ends so EOF is observable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let reader: AgentACPPipeReader
        do { reader = try AgentACPPipeReader(handle: output.fileHandleForReading) }
        catch {
            try? input.fileHandleForWriting.close()
            Task.detached { await AgentACPProcess.finish(pid, snapshot: tree) }
            throw error
        }
        try? output.fileHandleForReading.close()
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .unbounded)
        self.input = input
        self.pid = pid
        self.tree = tree
        lines = pair.stream
        let continuation = pair.continuation
        Task.detached {
            var line = Data()
            do {
                for try await chunk in reader.chunks {
                    reader.consumed()
                    var rest = chunk[...]
                    while let end = rest.firstIndex(of: 10) {
                        line.append(contentsOf: rest[..<end])
                        if let value = try Self.parse(line) { continuation.yield(value) }
                        line.removeAll(keepingCapacity: true)
                        rest = rest[rest.index(after: end)...]
                    }
                    line.append(contentsOf: rest)
                    guard line.count <= Self.lineLimit else { throw Failure.tooLarge }
                }
                if let value = try Self.parse(line) { continuation.yield(value) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }

    /// A blank line carries nothing; any other line is the protocol and must be JSON.
    private static func parse(_ line: Data) throws -> JSONValue? {
        guard line.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return nil }
        do { return try JSONValue.parse(line) }
        catch { throw Failure.unreadable(String(decoding: line.prefix(200), as: UTF8.self)) }
    }

    /// Writes one value and a newline. Never blocks the actor past a few seconds: a program that stops reading its input is reported, not waited on.
    package func send(_ value: JSONValue) throws {
        var bytes = try value.serializedData(pretty: false)
        bytes.append(10)
        let fd = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.notReading }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ContinuousClock.now < end else { throw Failure.notReading }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN else { throw Failure.notReading }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 20) < 0, errno != EINTR { throw Failure.notReading }
            }
        }
    }

    /// End of input: a program that reads until EOF ends its session on its own terms.
    package func closeInput() {
        // stop() ends the group whether or not the program saw end of input.
        try? input.fileHandleForWriting.close()
    }

    /// Ends the program's process group after `grace`. Returns why termination is unconfirmed, or nil. The first stop's answer is every stop's answer.
    @discardableResult
    package func stop(grace: Duration = .milliseconds(200)) async -> String? {
        if let stopped { return stopped }
        closeInput()
        let failure = await AgentACPProcess.finish(pid, snapshot: tree, grace: grace)
        stopped = .some(failure)
        return failure
    }
}

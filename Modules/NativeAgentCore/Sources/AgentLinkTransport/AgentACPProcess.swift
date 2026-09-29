import Foundation
import NativeAgentCore
import Synchronization

/// The app supplies process launch and bounded cleanup; Core owns the connection.
public protocol AgentACPProcessHosting: Sendable {
    func spawn(executable: String, arguments: [String], directory: URL,
               environment: [String: String], input: Pipe, output: Pipe,
               approvedExecutable: AgentACPExecutable?) throws -> Int32
    func finish(_ pid: Int32, snapshot: ProcessTreeSnapshot?, grace: Duration) async
}

public enum AgentACPProcess {
    private static let host = Mutex<(any AgentACPProcessHosting)?>(nil)

    public static func installHost(_ value: any AgentACPProcessHosting) {
        host.withLock { $0 = value }
    }

    static func spawn(executable: String, arguments: [String], directory: URL,
                      environment: [String: String], input: Pipe, output: Pipe,
                      approvedExecutable: AgentACPExecutable? = nil) throws -> Int32 {
        guard let host = host.withLock({ $0 }) else { throw AgentACPClient.Failure.unavailable }
        return try host.spawn(executable: executable, arguments: arguments, directory: directory,
                              environment: environment, input: input, output: output,
                              approvedExecutable: approvedExecutable)
    }

    static func finish(_ pid: Int32, snapshot: ProcessTreeSnapshot? = nil,
                       grace: Duration = .milliseconds(200)) async {
        guard let host = host.withLock({ $0 }) else {
            preconditionFailure("ACP process host must be installed before use")
        }
        await host.finish(pid, snapshot: snapshot, grace: grace)
    }
}

import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `AgentACPProcess.swift` | `AgentACPProcess` verifies approval then uses `OwnedProcessGroup` for before-exec containment, one group-only TERM/KILL settlement, checked termination and retained leader reap |

public enum AgentACPProcess {
    static func spawn(executable: String, arguments: [String], directory: URL,
                      environment: [String: String], input: Pipe, output: Pipe,
                      approvedExecutable: AgentACPExecutable? = nil, errorsToOutput: Bool = false) throws -> pid_t {
        if let approvedExecutable {
            do { try approvedExecutable.verify() }
            catch { throw AgentACPClient.Failure.executableChanged }
        }
        do {
            return try OwnedProcessGroup.spawn(executable: executable, arguments: arguments,
                directory: directory, environment: environment, input: input, output: output,
                errors: errorsToOutput ? output : FileHandle.nullDevice).pid
        } catch { throw AgentACPClient.Failure.unavailable }
    }

    @discardableResult static func finish(_ pid: pid_t, snapshot: ProcessTreeSnapshot? = nil,
                       grace: Duration = .milliseconds(200)) async -> String? {
        guard pid > 0 else { return nil } // No child was launched.
        guard let owner = OwnedProcessGroup.owner(pid), owner.identity == snapshot?.groupOwnerID else {
            return "ACP process group \(pid) has no retained child owner. Termination is unconfirmed; no process was signalled."
        }
        // Cancellation ends this optional grace, not the group's settlement.
        try? await Task.sleep(for: grace)
        guard owner.send(SIGTERM) else { return owner.failure }
        try? await Task.sleep(for: .milliseconds(500))
        guard owner.closeExitedGroup() else { return owner.failure }
        owner.reapExitedLeader()
        return owner.failure
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import ToolExecution
// Blueprint: | `SwiftToolDispatcher+Reach.swift` | `performReach`: `programReach`, a part program's shell access check and launch plan |

extension SwiftToolDispatcher {
    public func performReach(turn: Turn, _ operation: String, arguments: JSONValue, surface: String) async throws -> JSONValue {
        guard case .object(let args) = arguments else {
            throw SenseFailure(code: "bad_input", message: "Reach takes one named argument object.")
        }
        guard operation.hasPrefix("program.") else {
            throw SenseFailure(code: "unsupported", message: "Unknown reach \(operation).")
        }
        return try await programReach(turn: turn, operation, args, surface: surface)
    }

    /// Share shell admission and launch; program.access rechecks authority at each talk.
    func programReach(turn: Turn, _ operation: String, _ args: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed else {
            throw SenseFailure(code: "trust_center_full_mac_required",
                message: "A program is a command line: Full Mac with file operations on must be active, as for the shell. Turn on Full Mac in Trust.")
        }
        guard operation == "program.launch" else { return .object([:]) }
        let cwd = JSONValue.object(args).stringFields["cwd"] ?? Self.builderWorkspaceRoot(dataRoot: dataRoot).path
        guard case .string(let executable)? = args["executable"], case .array(let rows)? = args["args"] ?? .array([]),
              let launch = try await Self.builderLaunch(turn: turn, executable: executable, args: rows.compactMap { if case .string(
                  let text) = $0 { text } else { nil } },
                                                    cwd: cwd, dataRoot: dataRoot) else {
            throw SenseFailure(code: "bad_input", message: """
                cwd must be a folder a command may start in: inside \(Self.builderWorkspaceRoot(dataRoot: dataRoot).path) unless Full Mac lifts \
                the sandbox.
                """)
        }
        return .object(["executable": .string(launch.executable), "arguments": .array(launch.arguments.map(JSONValue.string)),
                        "cwd": .string(launch.cwd), "path_prefix": launch.pathPrefix.map(JSONValue.string) ?? .null])
    }
}

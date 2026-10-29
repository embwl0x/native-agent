import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `dispatchNativeAction` uses `LocalConnectorActions.nativeReadOnly` |

public enum NativeActionDispatch {
    public static func dispatchNativeAction(
        tool: String,
        input: [String: JSONValue],
        dryRun: Bool,
        dataRoot: URL? = nil
    ) async throws -> Dispatcher.DispatchResult {
        let dispatcher = SwiftNativeDispatcher(
            ledgerPath: (dataRoot ?? PersistenceCore.defaultDataRoot()).appendingPathComponent("traces/events.jsonl"),
            localActions: .nativeReadOnly
        )
        let ctx = try strictDispatchContextForTool(tool, surface: "native_actions", dataRoot: dataRoot)
        return try await dispatcher.dispatch(tool: tool, input: input, ctx: ctx, dryRun: dryRun)
    }

    public static func strictDispatchContextForTool(_ tool: String, surface: String, dataRoot: URL? = nil) throws -> DispatchContext {
        guard tool == "read_file" || tool == "file_excerpt" else {
            var context = DispatchContext.defaultForSurface(surface)
            // Ordinary clients retain the established persona/workspace
            // resolver. Only an explicit isolated root overrides those reads.
            if let dataRoot {
                context.dataRoot = dataRoot
                context.workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot, environment: [:])
            }
            return context
        }
        let dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
            throw NSError(domain: "NativeAgentNativeActions", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Cannot run \(tool): Swift file sandbox root is unavailable"
            ])
        }
        let extra: [String: JSONValue] = [
            "file_access": .object([
                "mode": .string("read_only"),
                "sandbox": .string("read_only"),
            ]),
        ]
        return DispatchContext(
            repoRoot: repoRootURL,
            surface: surface,
            persona: "",
            extra: extra,
            dataRoot: dataRoot
        )
    }

}


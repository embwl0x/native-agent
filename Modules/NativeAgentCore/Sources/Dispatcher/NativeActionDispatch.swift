import Foundation
import NativeAgentCore
import PersistenceCore

public enum NativeActionDispatch {
    public static func swiftNativeDispatcherActions() -> LocalConnectorActions {
        var handlers: [String: ConnectorActionHandler] = [:]
        var sideEffecting: Set<String> = []
        var trivialVerify: Set<String> = []
        func merge(_ reg: LocalConnectorActions) {
            for name in reg.toolNames {
                handlers[name] = { input, ctx in reg.run(name, input: input, ctx: ctx) ?? .null }
                if reg.isSideEffecting(name) { sideEffecting.insert(name) }
                if reg.isTrivialVerify(name) { trivialVerify.insert(name) }
            }
        }
        merge(.personaReadOnly)
        merge(.workspaceListReadOnly)
        merge(.timeNowReadOnly)
        merge(.personaListSkillsReadOnly)
        merge(.readFileReadOnly)
        merge(.fileExcerptReadOnly)
        merge(.systemInfoReadOnly)
        return LocalConnectorActions(
            handlers: handlers,
            sideEffecting: sideEffecting,
            trivialVerify: trivialVerify
        )
    }

    public static func dispatchNativeAction(
        tool: String,
        input: [String: JSONValue],
        dryRun: Bool,
        dataRoot: URL? = nil
    ) async throws -> Dispatcher.DispatchResult {
        let ledger = DispatchLedger(ledgerPath: DispatchLedger.defaultLedgerPath(
            dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()
        ))
        let dispatcher = makeDispatcher(ledger: ledger, localActions: swiftNativeDispatcherActions())
        let ctx = try strictDispatchContextForTool(tool, surface: "native_actions", dataRoot: dataRoot)
        return try await dispatcher.dispatch(tool: tool, input: input, ctx: ctx, dryRun: dryRun)
    }

    public static func strictDispatchContextForTool(_ tool: String, surface: String, dataRoot: URL? = nil) throws -> DispatchContext {
        guard tool == "read_file" || tool == "file_excerpt" else {
            var context = DispatchContext.defaultForSurface(surface)
            // Ordinary clients retain the established persona/workspace
            // resolver. Only an explicit isolated root overrides those reads.
            if let dataRoot {
                context.extra["_na_data_root"] = .string(dataRoot.path)
                context.extra["_na_workspace_root"] = .string(
                    NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot, environment: [:]).path
                )
            }
            return context
        }
        let dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
            throw NSError(domain: "NativeAgentNativeActions", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Cannot run \(tool): Swift file sandbox root is unavailable"
            ])
        }
        let repoRoot = repoRootURL.path
        var extra: [String: JSONValue] = [
            "file_access": .object([
                "mode": .string("read_only"),
                "sandbox": .string("read_only"),
            ]),
        ]
        let dataRootPath = dataRoot.path
        if !dataRootPath.isEmpty {
            extra["_na_data_root"] = .string(dataRootPath)
        }
        return DispatchContext(
            repoRoot: repoRoot,
            cwd: repoRoot,
            surface: surface,
            sessionId: "",
            persona: "",
            activeProvider: "",
            extra: extra
        )
    }

}


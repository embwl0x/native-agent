import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Dispatcher
import AppToolRuntime

extension NativeClient {
    func runNativeAction(id: String, dryRun: Bool) async throws -> NativeActionReceipt {
        try await runNativeAction(id: id, dryRun: dryRun, input: [:])
    }

    func runNativeAction(id: String, dryRun: Bool, input: [String: Any]) async throws -> NativeActionReceipt {
        try await NativeActionRoutes.runNativeAction(
            id: id, dryRun: dryRun, input: input, dataRoot: dataRootOverride
        ) { action, dryRun, input in
            try await self.runBrowserNativeAction(action: action, dryRun: dryRun, input: input)
        }
    }

    static func swiftNativeActionRecords() -> [NativeActionRecord] {
        NativeActionRoutes.swiftNativeActionRecords()
    }

    static func nativeActionReceiptsPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        NativeActionRoutes.nativeActionReceiptsPath(dataRoot: dataRoot)
    }

    static func appendNativeActionReceipt(
        action: NativeActionRecord, status: String, dryRun: Bool, output: JSONValue,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> NativeActionReceipt {
        try await NativeActionRoutes.appendNativeActionReceipt(
            action: action, status: status, dryRun: dryRun, output: output, dataRoot: dataRoot
        )
    }

    // 2026-09-01: `workflow.launch` and `runWorkflowNativeAction` were retired
    // with the workflow run engine (User authorized). The action's only job was
    // to start a run.

    func runBrowserNativeAction(action: NativeActionRecord, dryRun: Bool, input: [String: Any]) async throws -> NativeActionReceipt {
        try await Self.browserActionRoutes.runBrowserNativeAction(
            action: action, dryRun: dryRun, input: input,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            decode: Self.decodeBrowserRouteRun
        )
    }

}

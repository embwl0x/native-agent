import Foundation
import Senses
import AppToolRuntime
import PersistenceCore
import NativeAgentCore
import EngineRuntime
import ChatOrchestration
import MemoryV2
import MacControl
import TrustCenter

/// Launch composition only. Runtime callers go through the shared hub.
enum SensesAssembly {
    private static let storage = Storage()
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var installation: Task<Void, Error>?
    }

    static func install(dataRoot: URL) {
        storage.lock.withLock {
            guard storage.installation == nil else { return }
            let registry = FileSenseRegistry(dataRoot: dataRoot)
            let runner = HelperSenseRunner(dataRoot: dataRoot, helperURL: SenseHostLocator.helperURL,
                sandboxProfile: { record, _, scratch in
                    try SenseSandboxProfile.build(reach: record.reach,
                        helperURL: SenseHostLocator.helperURL, scratch: scratch,
                        dataRoot: dataRoot, personaRoot: defaultPersonaRoot(dataRoot: dataRoot))
                }, apps: { arguments, targets in
                    guard case .object(let args) = arguments, AuthoredToolEffects.appReadOnly(args),
                          case .string(let bundleID)? = args["bundle_id"], targets[bundleID] == "read" else {
                        throw SenseFailure(code: "read_only", message: "A sense reads only its declared apps using dictionary or standard core read events.")
                    }
                    let admission = try await AuthoredToolEffects.$admissionOnly.withValue(true) {
                        try await rawRead(tool: "apps.call", input: args, dataRoot: dataRoot)
                    }
                    guard case .object(let fields) = admission, fields["status"] == .string("admitted") else {
                        throw SenseFailure(code: "trust_refused", message: "App read refused by Trust: \(try admission.serialize(pretty: false))")
                    }
                    return try await SystemAppleScriptAdapter().callApp(arguments, targets: targets)
                })
            let source = ExistingCornersSourceProvider(rawRead: { tool, input in
                try await rawRead(tool: tool, input: input, dataRoot: dataRoot)
            }, dataRoot: dataRoot, chrome: { NativeAgentEngine.live.chrome })
            // No background growth: she makes a place's sense in her own turn
            // (app sense.make), and then it's built.
            SensesHub.shared.install(registry: registry, runner: runner, source: source)
            storage.installation = Task {
                await SenseNewsBoard.shared.configure(dataRoot: dataRoot)
                do {
                    let memory = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                    SensesHub.shared.installMemoryProvenanceSink(memory)
                    try await BuiltInSenses.registerAll(dataRoot: dataRoot)
                } catch {
                    ModuleLog.app("[senses] Registration failed: %@", error.localizedDescription)
                    throw error
                }
            }
        }
    }

    static func waitUntilReady() async throws {
        let installation = storage.lock.withLock { storage.installation }
        try await installation?.value
    }

    static func shutdown() async {
        let installation = storage.lock.withLock { storage.installation }
        installation?.cancel()
        _ = try? await installation?.value
        await (SensesHub.shared.runner as? HelperSenseRunner)?.shutdown()
    }

    /// Re-enter the existing gates with the invoking turn's identity. Quiet
    /// background reads have no borrowed session, filer or write permission.
    private static func rawRead(tool: String, input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue {
        try Task.checkCancellation()
        if case .string(let path)? = input["path"] {
            try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot,
                personaRoot: defaultPersonaRoot(dataRoot: dataRoot))
        }
        let surface = ChatToolSessionContext.envelope?.surface ?? ChatTurnRuntimeContext.current?.surface ?? "chat"
        let profile = surface == "chat" ? NativeAgentAppChatSurfaceProfile.mac
            : NativeAgentAppChatSurfaceProfile(rawValue: surface)
        // Construction policy does not determine whether a turn can read.
        let sessionID = ChatToolSessionContext.verifiedSessionId
        let filer = sessionID != nil && profile != .background
            ? NativeAgentChatApprovalFiler(dataRoot: dataRoot) : nil
        let dispatcher = makeGatedToolDispatchClient(
            tools: NativeAgentEngine.live.toolDispatchClient(
                enforceAppAutonomy: false,
                swarmApprovalFiler: filer),
            fileAccess: ChatToolSessionContext.fileAccess ?? "read_only", approvalFiler: filer,
            dataRoot: dataRoot, verifiedSessionId: sessionID)
        return try await dispatcher.dispatch(tool: tool, input: input, surface: surface)
    }
}

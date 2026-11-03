import Foundation
import NativeAgentShared
import Synchronization
import ApprovalTransactions
import Senses
import AppToolRuntime
import PersistenceCore
import NativeAgentCore
import EngineRuntime
import ChatTurnRuntime
import ChatTurnContracts
import MemoryV2
import MacControl
import TrustCenter
import AuthoredCapabilities
import Cognition
import DoctorChecks

// Blueprint: | `SensesAssembly.swift` | `SensesAssembly`: shared hub installation and gated raw-read bindings; checked readiness belongs to dependent reads and subscriptions, never global loop launch; successful registration publishes its repair edge, repair retries only on canonical ability/resource/memory-file changes; quiet reads borrow no turn authority |

/// Launch composition only. Runtime callers go through the shared hub.
enum SensesAssembly {
    private static let installation = Mutex<Task<Void, Error>?>(nil)
    private static let installationFinished = ScopedWaiter()

    static func install(dataRoot: URL) {
        installation.withLock { installation in
            guard installation == nil else { return }
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
                    return try await AppleScriptExecution().callApp(arguments, targets: targets)
                })
            let source = ExistingCornersSourceProvider(rawRead: { tool, input in
                try await rawRead(tool: tool, input: input, dataRoot: dataRoot)
            }, dataRoot: dataRoot, chrome: { NativeAgentEngine.live.chrome })
            // No background growth: she makes a place's sense in her own turn
            // (app sense.make), and then it's built.
            SensesHub.shared.install(registry: registry, runner: runner, source: source)
            installation = Task {
                defer { installationFinished.resume() }
                let resources = Bundle.main.resourceURL?.appendingPathComponent("Senses")
                var paths = [dataRoot.appendingPathComponent("memory/memory.sqlite"), dataRoot.appendingPathComponent("senses/news/unread.json")]
                if let resources { paths.append(resources.appendingPathComponent("builtin.json")) }
                let repairs = EventDeadlinePhysiology.storeAndFileEvents(paths: paths, notifications: [AbilityStore.didChange])
                var changes = repairs.makeAsyncIterator()
                while !Task.isCancelled {
                    do {
                        guard await SenseNewsBoard.shared.configure(dataRoot: dataRoot) else {
                            let detail = await SenseNewsBoard.shared.storageFailure
                            throw SenseFailure(code: "news_unavailable", message: "Private sense news storage could not be installed: " + (detail ?? "binding unavailable"))
                        }
                        let memory = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                        SensesHub.shared.installMemoryProvenanceSink(memory)
                        try await BuiltInSenses.registerAll(dataRoot: dataRoot)
                        try Task.checkCancellation()
                        await DoctorReadout.recordReadings([CheckResult(source: "Senses installation",
                            id: "launch.senses", title: "Senses installation", status: "ok", detail: "Senses registered; dependent reads and file subscriptions may proceed.")], dataRoot: dataRoot)
                        NotificationCenter.default.post(name: SensesHub.didBecomeReady, object: nil)
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let detail = "Senses registration unavailable; dependent reads are unavailable until a source repair/change: " + error.localizedDescription
                        ModuleLog.app("[senses] %@", detail)
                        await DoctorReadout.recordReadings([CheckResult(source: "Senses installation",
                            id: "launch.senses", title: "Senses installation", status: "fail", detail: detail,
                            human_action: "Preserve the failed source named in this reading; repair it at its owner. A canonical ability/resource/memory-file change rechecks registration; otherwise relaunch after repair. Only dependent sense reads and subscriptions are unavailable; other resident work continues.")], dataRoot: dataRoot)
                    }
                    // No repair edge means still unavailable, never ready.
                    guard await changes.next() != nil else { throw CancellationError() }
                }
                throw CancellationError()
            }
            if let installation { SensesHub.shared.installReadiness(installation, finished: installationFinished) }
        }
    }

    static func shutdown() async {
        let installation = Self.installation.withLock { $0 }
        installation?.cancel()
        _ = try? await installation?.value
        await SensesHub.shared.runner?.shutdown()
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

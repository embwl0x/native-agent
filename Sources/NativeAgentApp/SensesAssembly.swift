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

// Blueprint: | `SensesAssembly.swift` | `SensesAssembly`: gated hub bindings; scoped readiness and repair; quiet reads borrow no authority |

/// Compose at launch; runtime callers must use the shared hub.
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
                }, apps: { arguments, targets, operation in
                    guard case .object(let args) = arguments, AuthoredToolEffects.appReadOnly(args),
                          case .string(let bundleID)? = args["bundle_id"], targets[bundleID] == "read" else {
                        throw SenseFailure(code: "read_only", message: "A sense reads only its declared apps using dictionary or standard core read events.")
                    }
                    let admission = try await rawRead(tool: "apps.call", input: args, dataRoot: dataRoot,
                        turn: operation.turn, operation: .init(sense: operation), admissionOnly: true)
                    guard case .object(let fields) = admission, fields["status"] == .string("admitted") else {
                        throw SenseFailure(code: "trust_refused", message: "App read refused by Trust: \(try admission.serialize(pretty: false))")
                    }
                    var context = MacOperationContext(dataRoot: dataRoot, deadline: operation.deadline,
                        observationMode: operation.passive ? .passive : .interactive)
                    context.appCapture = operation.appCapture
                    context.readContent = operation.readContent
                    return try await AppleScriptExecution().callApp(arguments, targets: targets, context: context)
                })
            let source = ExistingCornersSourceProvider(rawRead: { tool, input, turn, operation in
                try await rawRead(tool: tool, input: input, dataRoot: dataRoot, turn: turn, operation: operation)
            }, dataRoot: dataRoot, chrome: { NativeAgentEngine.live.chrome })
            // Sense growth belongs to the agent's turn, never background construction.
            SensesHub.shared.install(registry: registry, runner: runner, source: source)
            installation = Task {
                defer { installationFinished.resume() }
                do {
                    guard await SenseNewsBoard.shared.configure(dataRoot: dataRoot) else {
                        let detail = await SenseNewsBoard.shared.storageFailure
                        throw SenseFailure(
                            code: "news_unavailable",
                            message: "Private sense news storage could not be installed: " + (detail ?? "binding unavailable"))
                    }
                    let memory = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                    SensesHub.shared.installMemoryProvenanceSink(memory)
                    try await BuiltInSenses.registerAll(dataRoot: dataRoot)
                    try Task.checkCancellation()
                    await DoctorReadout.recordReadings([CheckResult(source: "Senses installation",
                        id: "launch.senses", title: "Senses installation", status: "ok",
                        detail: "Senses registered; dependent reads and file subscriptions may proceed.")], dataRoot: dataRoot)
                    NotificationCenter.default.post(name: SensesHub.didBecomeReady, object: nil)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let detail = "Senses registration failed: " + error.localizedDescription
                    ModuleLog.app("[senses] %@", detail)
                    await DoctorReadout.recordReadings([CheckResult(source: "Senses installation",
                        id: "launch.senses", title: "Senses installation", status: "fail", detail: detail,
                        human_action: """
                            Preserve the failed source named in this reading; repair it at its owner and relaunch. Only dependent sense reads \
                            and subscriptions are unavailable; other resident work continues.
                            """)], dataRoot: dataRoot)
                    throw error
                }
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

    /// Re-enter gates with the invoking turn; quiet reads borrow no session, filer or write permission.
    private static func rawRead(tool: String, input: [String: JSONValue], dataRoot: URL,
        turn: Turn?, operation: ExistingCornerReadOperation, admissionOnly: Bool = false) async throws -> JSONValue {
        try Task.checkCancellation()
        if case .string(let path)? = input["path"] {
            try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot,
                personaRoot: defaultPersonaRoot(dataRoot: dataRoot))
        }
        return try await NativeAgentEngine.forRoot(dataRoot).tools.readSense(tool: tool, input: input,
            turn: turn, operation: operation, admissionOnly: admissionOnly)
    }
}

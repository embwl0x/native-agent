import SwarmRuns
import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `WorkshopExecution+PlannerLLM.swift` | `SwiftNativeWorkshopPlannerLLM`: checked executions routing admission, live catalog binding and provider planner calls |

// MARK: - Swift-native planner LLM

/// Shared planner catalog configured by EngineLaunch from the app's live schemas; unconfigured means synthesis-only.
public enum WorkshopPlannerCatalog {
    private static let provider = OSAllocatedUnfairLock<@Sendable () async -> [JSONValue]>(initialState: { [] })

    public static func configure(_ p: @escaping @Sendable () async -> [JSONValue]) {
        provider.withLock { $0 = p }
    }

    public static func current() async -> [JSONValue] {
        let current = provider.withLock { $0 }
        return await current()
    }
}

/// Checked execution routing carries provider/model/effort/tier through the final call; transport termination or caller cancellation bounds it.
/// Cancellation propagates distinctly and never queues a substitute plan.
public struct SwiftNativeWorkshopPlannerLLM: WorkshopPlannerLLM {
    private let llm: any LLMClient
    private let router: SwiftNativeProviderRouting
    /// Where the per-run RunLedger row lands (<root>/runs/runs.json). nil
    /// disables ledger writes — the hermetic-test posture, so a mock-LLM
    /// planner test never appends rows to the developer's live ledger.
    private let runLedgerDataRoot: URL?
    /// Injected tool schemas; the shared live catalog is the default and an empty menu permits synthesis only.
    private let connectorActionsProvider: @Sendable () async -> [JSONValue]

    /// A secondary data root is a separate runtime body. It may use the
    /// executable-search and locale portions of the parent process environment,
    /// but it must not inherit provider credentials, agent state selectors, or
    /// the caller's home directory. The canonical app root keeps the complete
    /// environment for backwards-compatible production login behavior.
    nonisolated static func codexEnvironment(
        dataRoot: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        defaultDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [String: String] {
        var environment: [String: String]
        if dataRoot.standardizedFileURL == defaultDataRoot.standardizedFileURL {
            environment = processEnvironment
        } else {
            environment = [:]
            for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
                if let value = processEnvironment[key], !value.isEmpty {
                    environment[key] = value
                }
            }
            environment["HOME"] = dataRoot.standardizedFileURL.path
        }
        // Credential selection belongs to CodexProcess, using this same root
        // and the same process overrides that readiness evaluates.
        return environment
    }

    /// Root-confined construction for tests and secondary runtimes. Unlike the
    /// compatibility initializer below, every credential path, provider
    /// registry read, telemetry append, and RunLedger write is derived from the
    /// supplied root. This is the construction used by `makeWorkshopRunner`.
    public init(
        dataRoot: URL,
        connectorActionsProvider: @escaping @Sendable () async -> [JSONValue] = { await WorkshopPlannerCatalog.current() },
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) {
        let rootedRouter = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let rootedLLM = makeResidentProviderLLMClient(
            dataRoot: dataRoot, providersRoot: dataRoot, router: rootedRouter,
            lifecycleObserver: lifecycleObserver,
            processEnvironmentOverride: Self.codexEnvironment(dataRoot: dataRoot),
            stallOnlyTransport: true
        )
        self.init(
            llm: rootedLLM,
            router: rootedRouter,
            connectorActionsProvider: connectorActionsProvider,
            lifecycleObserver: lifecycleObserver,
            runLedgerDataRoot: dataRoot
        )
    }

    public init(
        llm: (any LLMClient)? = nil,
        router: SwiftNativeProviderRouting? = nil,
        // Every planner uses the app-configured catalog unless one is supplied.
        connectorActionsProvider: @escaping @Sendable () async -> [JSONValue] = { await WorkshopPlannerCatalog.current() },
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        // Default ON at the real data root so every production construction
        // records runs without a call-site change. Tests that drive plan
        // with a mock LLM pass nil so they never touch the live ledger.
        runLedgerDataRoot: URL? = PersistenceCore.defaultDataRoot()
    ) {
        self.connectorActionsProvider = connectorActionsProvider
        self.runLedgerDataRoot = runLedgerDataRoot
        let resolvedRouter: SwiftNativeProviderRouting = router ?? SwiftNativeProviderRouting()
        self.router = resolvedRouter
        // Default adapters use the same credential resolver as the default
        // router. Explicit secondary roots use the rooted initializer above.
        self.llm = llm ?? makeResidentProviderLLMClient(
            router: resolvedRouter, lifecycleObserver: lifecycleObserver,
            stallOnlyTransport: true
        )
    }

    private func admissionFailure(_ error: Error, surface: String) -> Error {
        if error is ToolFailureError { return error }
        if case .invalidRequest = error as? ProviderRoutingError { return error }
        if case .invalidResponse = error as? ProviderRoutingError { return error }
        let cause = ProviderFailure.classify(error)
        guard [.authExpired, .codexCLISessionExpired, .routingUnavailable, .modelUnavailable].contains(cause) else { return error }
        let detail = ProviderFailure.diagnosticDescription(error)
        guard let root = runLedgerDataRoot else { return error }
        let owner = root.appendingPathComponent("providers").path + " > surfaces.json (\(surface).model), active.json (\(surface)), pending-surface-configuration.json, registry.json"
        return ToolFailureError(detail, effects: .none, owner: owner,
            nextCall: ToolFailureError.call("app", ["action": .string("setting.get"),
                "args": .object(["setting": .string("providers.routing_repair")])]),
            tap: "Providers", instruction: "Inspect providers.routing_repair; ask the person to resolve the reported provider configuration failure in Providers.")
    }

    public func plan(spec: WorkshopExecutionSpec, dataRoot: URL, now: Date) async throws
        -> (steps: [WorkshopExecutionStep], providerCallCount: Int?, binding: WorkshopCompiledFileCopyBinding?) {
        try Task.checkCancellation()
        let workspaceDirectory = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot).path

        // Build tools_summary. Always include chat.synthesize.
        let connectorActions = await connectorActionsProvider()
        try Task.checkCancellation()
        var availableTools: [(id: String, description: String)] = []
        var schemas: [String: JSONValue] = [:]
        for action in connectorActions {
            guard case .object(let obj) = action,
                  case .string(let aid) = obj["id"] ?? .null,
                  !aid.isEmpty else { continue }
            let desc: String = {
                if case .string(let s) = obj["description"] ?? .null { return s }
                return aid
            }()
            if case .object? = obj["parameters"] { schemas[aid] = obj["parameters"] }
            availableTools.append((id: aid, description: desc))
        }
        if !availableTools.contains(where: { $0.id == "chat.synthesize" }) {
            availableTools.append((
                id: "chat.synthesize",
                description: "Use the AI to synthesize, draft, analyze, or reason over text"
            ))
        }
        // Include the tool menu up to the 200-tool prompt-size bound.
        let toolsSummary = availableTools.prefix(200).map { t in
            let schema = schemas[t.id].flatMap { try? $0.serialize(pretty: false) }
            return "  - \(t.id): \(t.description)" + (schema.map { " [schema=\($0)]" } ?? "")
        }.joined(separator: "\n")

        // Both date renderings use the injected clock and local timezone.
        let nowDate = now
        let humanDateFmt = DateFormatter()
        humanDateFmt.locale = Locale(identifier: "en_US_POSIX")
        humanDateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        let humanDate = humanDateFmt.string(from: nowDate)
        let isoDateFmt = DateFormatter()
        isoDateFmt.locale = Locale(identifier: "en_US_POSIX")
        isoDateFmt.dateFormat = "yyyy-MM-dd"
        let isoDate = isoDateFmt.string(from: nowDate)

        let prompt = try completionPolicy("workshop-plan", section: "prompt", arguments: [
            humanDate,
            isoDate,
            spec.title,
            spec.objective,
            workspaceDirectory,
            (spec.expectedOutputs ?? []).joined(separator: "\n"),
            toolsSummary
        ])

        // Freeze the checked provider/model/Think/Fast tuple for this plan.
        let routingSurface = canonicalRoutingSurface(WorkshopSurfaceVocabulary.canonical)
        let routingSnapshot: ProviderRoutingSnapshot
        do {
            routingSnapshot = try await router.checkedRoutingSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw admissionFailure(error, surface: routingSurface)
        }
        let route: TurnRouteAdmission
        do { route = try routingSnapshot.routeAdmission(for: routingSurface, choice: nil) }
        catch { throw admissionFailure(ProviderFailure.routingUnavailable, surface: routingSurface) }
        let resolvedModel = route.modelId
        // Re-check cancellation between router-prefs resolution and the LLM
        // call — both are `await` points and either could have been cancelled
        // without throwing CancellationError directly.
        try Task.checkCancellation()
        let modelForCall = resolvedModel
        let localLLM = llm
        // Success and failure write the run ledger; cancellation writes no row.
        let ledgerStarted = Date()
        let terminal: Result<String, Error>
        do {
            terminal = .success(try await route.withModelContext {
                try await LLMCallContext.$traceDataRootOverride.withValue(
                    runLedgerDataRoot ?? LLMCallContext.traceDataRootOverride
                ) {
                    try await localLLM.complete(
                        prompt: prompt,
                        system: try completionPolicy("workshop-plan", section: "system"),
                        model: modelForCall,
                        surface: routingSurface, purpose: "workshop", tools: nil
                    )
                }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            terminal = .failure(error)
        }
        let (output, failure): (String?, Error?) = switch terminal {
        case .success(let output): (output, nil)
        case .failure(let error): (nil, error)
        }
        if let ledgerRoot = runLedgerDataRoot {
            await RunLedger.append(
                kind: "mission",
                status: failure == nil ? "succeeded" : "failed",
                model: resolvedModel,
                prompt: prompt,
                output: output,
                error: failure.map { String(describing: $0) },
                createdAt: ledgerStarted,
                durationSeconds: Date().timeIntervalSince(ledgerStarted),
                dataRoot: ledgerRoot
            )
        }
        switch terminal {
        case .success(let output):
            try Task.checkCancellation()
            let raw = Self.stripMarkdownFences(output).trimmingCharacters(in: .whitespacesAndNewlines)
            let object = try JSONValue.parse(Data(raw.utf8))
            let directory = try JSONRow(object).string("working_directory")
            if directory.isEmpty { throw JSONRow.Malformed.field("working_directory") }
            let workingDirectory = NativeAgentWorkspaceRoot.resolveFileMutationPath(directory, dataRoot: dataRoot).path
            let steps = try Self.parsePlanJSON(object, validTools: Set(availableTools.map(\.id)), schemas: schemas)
            guard !steps.isEmpty else {
                throw WorkshopExecutionError.plannerFailure("planner returned no steps")
            }
            let boundSteps = steps.map { step in
                var step = step
                if case .object(let schema)? = schemas[step.toolOrAction],
                   case .object(let properties)? = schema["properties"],
                   case .object(var args) = step.args {
                    for key in ["cwd", "package_path"] where properties[key] != nil && args[key] == nil {
                        args[key] = .string(workingDirectory)
                    }
                    step.args = .object(args)
                }
                return step
            }
            return (boundSteps, 1, nil)
        case .failure(let error):
            if error is WorkshopExecutionError { throw error }
            if let repair = (error as? ProviderFailure.Diagnostic)?.repair { throw repair }
            throw error
        }
    }
    // MARK: parse helpers

    /// Strip leading and trailing Markdown fences.
    private static func stripMarkdownFences(_ s: String) -> String {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.hasPrefix("```") { return stripped }
        let lines = stripped.components(separatedBy: "\n")
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validate at most eight steps; unknown autonomy hints become auto.
    private static func parsePlanJSON(_ parsed: JSONValue, validTools: Set<String>, schemas: [String: JSONValue] = [:]) throws -> [WorkshopExecutionStep] {
        guard case .object(let obj) = parsed,
              case .array(let stepsRaw) = obj["steps"] ?? .null else {
            throw WorkshopExecutionError.plannerFailure("plan missing 'steps' list")
        }
        var out: [WorkshopExecutionStep] = []
        for (i, s) in stepsRaw.prefix(8).enumerated() {
            guard case .object(let sobj) = s else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1) must be a JSON object")
            }
            guard case .string(let tool)? = sobj["tool_or_action"], !tool.isEmpty else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1).tool_or_action is missing")
            }
            guard validTools.contains(tool) || tool == "chat.synthesize" else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1).tool_or_action '\(tool)' is unavailable; the intended action was not replaced")
            }
            var hint: String = {
                if case .string(let v) = sobj["autonomy_hint"] ?? .null { return v }
                return "auto"
            }()
            if hint != "auto" && hint != "needs_approval" {
                hint = "auto"
            }
            // Missing or empty IDs receive their one-based step name.
            let id: String = {
                if case .string(let v) = sobj["id"] ?? .null, !v.isEmpty { return v }
                return "step-\(i + 1)"
            }()
            let desc: String = {
                if case .string(let v) = sobj["description"] ?? .null, !v.isEmpty { return v }
                return "Step \(i + 1)"
            }()
            // Null/missing args become {}; every other non-object refuses the plan.
            let args: JSONValue
            switch sobj["args"] ?? .null {
            case .null:
                args = .object([:])
            case .object(let o):
                args = .object(o)
            default:
                throw WorkshopExecutionError.plannerFailure("step args must be a JSON object")
            }
            let optional: Bool
            switch sobj["optional"] {
            case .bool(let value)?: optional = value
            case nil: optional = false // Existing callers without this extension remain required.
            default: throw WorkshopExecutionError.plannerFailure("step optional must be a boolean")
            }
            out.append(WorkshopExecutionStep(
                id: id,
                description: desc,
                toolOrAction: tool,
                args: args,
                autonomy: hint,
                argumentSchema: schemas[tool],
                optional: optional
            ))
        }
        try SwiftNativeWorkshopRunner.validateStepIDs(out)
        return out
    }

}

// MARK: - Factory

public func makeWorkshopRunner(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
) -> SwiftNativeWorkshopRunner {
    return SwiftNativeWorkshopRunner(
        root: dataRoot,
        planner: SwiftNativeWorkshopPlannerLLM(
            dataRoot: dataRoot,
            lifecycleObserver: lifecycleObserver
        )
    )
}

import Foundation
import NativeAgentCore
import ChatToolRuntime
import PersonaEngine
import MemoryV2
import PersistenceCore
import ProviderRouting
import Cognition
import DreamREMCycle
// Blueprint: | `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `completeMessages`; task-only context for `recall_judge`, `memory_interpret`, `memory_held`, and `kind_backfill`; other work honors caller-bound context assembly |

// MARK: - Execution planner tool catalog injection
//
// The Executions module cannot import ChatTurnRuntime (it would create a
// dependency cycle / pull the whole tool stack into the planner), so the real
// tool catalog that makes the planner TOOL-AWARE is injected from the app
// layer here. Without this the planner's availableConnectorActions() returns
// `[]` and executions can ONLY ever emit chat.synthesize steps — they can
// describe work but never DO it (root cause fixed 2026-06-15).
//
// Each entry is `{id, description}` exactly as planWorkshopExecution reads it
// (WorkshopExecution.swift ~L900). Source is SwiftToolDispatcher's own tool schemas —
// the same catalog the chat tool loop sees. Capped to 40 to bound prompt size
// (the planner itself prefixes 30 before rendering the menu).
public func makeWorkshopPlannerConnectorActionsProvider(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> @Sendable () async -> [JSONValue] {
    // The dispatcher owns a policy-keyed schema cache and root-exact MemoryV2
    // / knowledge-graph bindings. Rebuilding that graph for every plan threw
    // away the cache and repeated all of the binding work. One captured
    // dispatcher is safe here: schema enumeration still rechecks the current
    // Full Mac access flags and dispatch authority remains effect-time owned.
    //
    // A5.3 (W5#P1-4): building the dispatcher forces the MemoryV2 GRDB sqlite
    // open+migrate+prune (via SwiftNativeMemoryV2.shared). This factory is
    // called SYNCHRONOUSLY from applicationDidFinishLaunching, so constructing
    // eagerly here paid that sqlite cost on the MAIN THREAD at launch. Defer it
    // to a LazyDispatcherHolder: the first (background, async) invocation of the
    // provider builds and caches the one dispatcher off-main, keeping launch's
    // main thread clear. Schema-cache reuse is preserved — the holder returns
    // the same dispatcher on every later call.
    let holder = LazyDispatcherHolder(dataRoot: dataRoot)
    return {
        let dispatcher = await holder.dispatcher()
        let schemas = (try? await dispatcher.listAvailableToolSchemas()) ?? []
        return schemas.prefix(200).map { schema in
            JSONValue.object([
                "id": .string(schema.name),
                "description": .string(workshopPlannerToolDescription(schema)),
                "parameters": (try? JSONValue.parse(schema.parametersJSON)) ?? .null,
            ])
        }
    }
}

/// Lazily builds + caches one `SwiftToolDispatcher` on first use. Isolating the
/// build behind an actor moves the MemoryV2 sqlite open+migrate off the main
/// thread (A5.3): the provider factory can be called at launch on the main
/// actor, but the actual construction runs the first time the (async) provider
/// closure is invoked from a background loop/trigger.
private actor LazyDispatcherHolder {
    private let dataRoot: URL
    private var cached: SwiftToolDispatcher?

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    func dispatcher() -> SwiftToolDispatcher {
        if let cached { return cached }
        let built = SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot(),
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        )
        cached = built
        return built
    }
}

/// Append the tool's arg names to its description so the execution planner fills
/// the RIGHT args (e.g. shell needs `cmd` — without this the planner emitted a
/// shell step with no cmd → "missing_cmd" failure; 2026-06-15). `*` marks
/// required args.
public func workshopPlannerToolDescription(_ schema: LLMToolSchema) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any],
          let props = obj["properties"] as? [String: Any], !props.isEmpty else {
        return schema.description
    }
    let required = Set((obj["required"] as? [String]) ?? [])
    let args = props.keys.sorted().map { required.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
    return "\(schema.description) [args: \(args)]"
}

public struct PersonaBackedBackgroundLLMClient: LLMClient {
    let inner: any LLMClient
    let dataRoot: URL
    let cognitionRuntime: NativeCognitionRuntime

    public init(inner: any LLMClient, dataRoot: URL, cognitionRuntime: NativeCognitionRuntime) {
        self.inner = inner
        self.dataRoot = dataRoot
        self.cognitionRuntime = cognitionRuntime
    }

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: "background"),
            model: model
        )
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: surface),
            model: model,
            surface: surface
        )
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: "background"),
            model: model,
            tools: tools
        )
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await inner.completeMessages(
            messages: messages,
            system: try await personaSystem(existing: system, surface: surface),
            model: model,
            surface: surface,
            tools: tools
        )
    }

    public func servingProviderID(model: String?, surface: String) async -> String? {
        await inner.servingProviderID(model: model, surface: surface)
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolvedSystem = try await personaSystem(existing: system, surface: surface)
                    try Task.checkCancellation()
                    for try await event in inner.streamMessages(
                        messages: messages,
                        system: resolvedSystem,
                        model: model,
                        surface: surface,
                        tools: tools
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func personaSystem(existing: String?, surface: String) async throws -> String {
        let trimmedExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Memory judgment and classification are task-only by purpose. Reflection
        // callers bind suppliedPersona where they actually assemble context.
        let assembly: PrivateWorkContextAssembly = switch LLMCallContext.purpose {
        case "recall_judge", "memory_interpret", "memory_held", "kind_backfill":
            .taskOnly
        default:
            PrivateWorkContextAssembly.current
        }
        switch assembly {
        case .suppliedPersona, .taskOnly:
            return trimmedExisting
        case .compilePersona:
            break
        }

        let persona = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
        let userMemoryCore = MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot)
            ? await SwiftNativeMemoryV2.userCoreForBackground(dataRoot: dataRoot)
            : []
        let packet = try await PersonaCompiler(engine: persona).compile(
            surface: surface, userMemoryCore: userMemoryCore
        )
        let compiled = packet.compiledSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compiled.isEmpty else {
            throw BackgroundPersonaContextError.emptyCompiledPrompt(surface: surface)
        }
        let organismPosture = await cognitionRuntime.organismBehaviorPosture()?
            .privateRuntimeContext()
        let boundary = """
        # Private background work
        Work as yourself, with the same identity, voice, care and boundaries as in conversation. Follow the task below; this is not a message to the person. Do not dispatch actions or change identity; stage proposals only where the task permits.
        """
        var sections = [compiled, boundary]
        if let organismPosture, !organismPosture.isEmpty {
            sections.append(organismPosture)
        }
        if !trimmedExisting.isEmpty {
            sections.append(trimmedExisting)
        }
        return sections.joined(separator: "\n\n")
    }

}

/// Secondary/test roots have no authority to borrow the process-global
/// provider credentials, Codex home, or telemetry owners. They may assemble
/// loops for deterministic inspection, but any unexpected model spend fails
/// loudly at the provider boundary.
public struct AlternateRootUnavailableBackgroundLLMClient: LLMClient {
    public init() {}
    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw NSError(
            domain: "BackgroundLoopsAssembly",
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "background providers are unavailable for an alternate data root",
            ]
        )
    }
}

private enum BackgroundPersonaContextError: Error, Sendable, CustomStringConvertible {
    case emptyCompiledPrompt(surface: String)

    var description: String {
        switch self {
        case .emptyCompiledPrompt(let surface):
            return "emptyCompiledPrompt(surface: \(surface))"
        }
    }
}

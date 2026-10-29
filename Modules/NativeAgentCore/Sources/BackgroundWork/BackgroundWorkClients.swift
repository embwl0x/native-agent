import Foundation
import NativeAgentCore
import ChatToolRuntime
import PersonaEngine
import MemoryV2
import PersistenceCore
import ProviderRouting
import Cognition
import DreamREMCycle
// Blueprint: | `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `streamMessages`; task-only context for `recall_judge`, `memory_interpret`, `memory_held`, and `kind_backfill`; other work honors caller-bound context assembly |

// MARK: - Execution planner tool catalog injection
//
// Inject the dispatcher's tool catalog so Executions avoids a ChatTurnRuntime dependency cycle.
public func makeWorkshopPlannerConnectorActionsProvider(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> @Sendable () async -> [JSONValue] {
    // Reuse one dispatcher; schema reads recheck Full Mac flags and effects check authority.
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

/// Build and cache the dispatcher on first use, keeping MemoryV2 setup off the main actor.
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

/// Append argument names to the planner's tool description; `*` marks required arguments.
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

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String,
        purpose: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMCallContext.$purpose.withValue(purpose) {
            try await inner.complete(
                prompt: prompt,
                system: try await personaSystem(existing: system, surface: surface),
                model: model, surface: surface, purpose: purpose, tools: tools
            )
        }
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
        guard case .compilePersona = PrivateWorkContextAssembly.current else { return trimmedExisting }

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

private enum BackgroundPersonaContextError: Error, Sendable, CustomStringConvertible {
    case emptyCompiledPrompt(surface: String)

    var description: String {
        switch self {
        case .emptyCompiledPrompt(let surface):
            return "emptyCompiledPrompt(surface: \(surface))"
        }
    }
}

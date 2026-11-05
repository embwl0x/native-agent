import Foundation
import NativeAgentCore
import ChatToolRuntime
import ChatTurnRuntime
import PersonaEngine
import MemoryV2
import PersistenceCore
import ProviderRouting
import Cognition
import DreamREMCycle
// Blueprint: | `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient`, `complete`, `streamMessages`, `servingProviderID`, `recall_judge`, `memory_interpret`, `memory_held`, `kind_backfill` |

public struct PersonaBackedBackgroundLLMClient: LLMClient {
    let inner: any LLMClient
    let dataRoot: URL
    let cognitionRuntime: NativeCognitionRuntime
    /// The caller chooses the assembly for this operation's client explicitly.
    let assembly: PrivateWorkContextAssembly

    public init(inner: any LLMClient, dataRoot: URL, cognitionRuntime: NativeCognitionRuntime,
                assembly: PrivateWorkContextAssembly) {
        self.inner = inner
        self.dataRoot = dataRoot
        self.cognitionRuntime = cognitionRuntime
        self.assembly = assembly
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: call.surface),
            model: model, tools: tools, call: call
        )
    }

    public func servingProviderID(model: String?, call: LLMCall) async throws -> String {
        try await inner.servingProviderID(model: model, call: call)
    }

    public func requestOutputTokens(model: String, call: LLMCall) async throws -> Int {
        try await inner.requestOutputTokens(model: model, call: call)
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolvedSystem = try await personaSystem(existing: system, surface: call.surface)
                    try Task.checkCancellation()
                    for try await event in inner.streamMessages(
                        messages: messages,
                        system: resolvedSystem,
                        model: model,
                        tools: tools,
                        call: call
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
        guard case .compilePersona = assembly else { return trimmedExisting }

        let persona = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
        let userMemoryCore = try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot)
            ? try await SwiftNativeMemoryV2.userCoreForBackground(dataRoot: dataRoot)
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
        Work as yourself, with the same identity, voice, care and boundaries as in conversation. Follow the task below; \
        this is not a message to the person. Do not dispatch actions or change identity; stage proposals only where the task permits.
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

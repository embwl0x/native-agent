@_exported import ChatSessionWork

extension SwiftNativeChatOrchestrationClient {
    func scheduleTranscriptAgingIfNeeded(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?
    ) {
        ChatSessionAgingConsolidation(
            dataRoot: dataRoot,
            autocompactionConfig: autocompactionConfig,
            llm: llm,
            clock: clock
        ).scheduleTranscriptAgingIfNeeded(
            sessionId: sessionId, model: model, surface: surface, runId: runId
        )
    }
}

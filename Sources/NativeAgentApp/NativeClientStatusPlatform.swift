import EngineRuntime

struct NativeClientStatusPlatform: ConnectorStatusPlatform {
    func calendarEventKitReadState() -> String {
        NativeClient.calendarEventKitReadState()
    }

    var agentSubject: String { AgentVoice.live.subject }
}

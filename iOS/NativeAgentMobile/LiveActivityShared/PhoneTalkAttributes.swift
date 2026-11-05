import ActivityKit
import AppIntents
import Foundation
// Blueprint: | `PhoneTalkAttributes.swift` | Call identity and Live Activity state; intents reach the live app owner without copied commands |

struct PhoneTalkAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let muted: Bool
        let status: String
    }
    let callID: String
    let agentName: String
    let startedAt: Date
}

/// LiveActivityIntent executes in the app; the extension has neither microphone access nor copied call state.
@MainActor enum PhoneTalkCommands {
    enum Command { case mute, end }
    static var handle: ((String, Command) -> Bool)?
    static func perform(_ command: Command, callID: String) throws {
        guard handle?(callID, command) == true else {
            throw NSError(domain: "NativeAgentTalk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This talk session has ended. Open NativeAgent to start another."])
        }
    }
}

struct PhoneTalkMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Talk"
    @Parameter(title: "Call") var callID: String
    init() {}
    init(callID: String) { self.callID = callID }
    @MainActor func perform() async throws -> some IntentResult {
        try PhoneTalkCommands.perform(.mute, callID: callID)
        return .result()
    }
}

struct PhoneTalkEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Talk"
    @Parameter(title: "Call") var callID: String
    init() {}
    init(callID: String) { self.callID = callID }
    @MainActor func perform() async throws -> some IntentResult {
        try PhoneTalkCommands.perform(.end, callID: callID)
        return .result()
    }
}

struct PhoneTalkResumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Return to Talk"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { .result() }
}
